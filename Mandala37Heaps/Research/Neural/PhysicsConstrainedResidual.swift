import Foundation
import RealityKit
import simd
import UIKit

struct ResidualCorrectionStats: Equatable, Sendable {
    var enabled: Bool = false
    var trainSteps: Int = 0
    var lastLoss: Float = 0
    var meanAbsResidual: Float = 0
    var maxAbsResidual: Float = 0
    var massDrift: Float = 0
    var reposeViolations: Int = 0

    var hudLine: String {
        guard enabled else { return "Neural residual idle" }
        return String(
            format: "Neural L=%.3f  |δh̄|=%.2fmm  Δm=%.2e  repose✗=%d  n=%d",
            Double(lastLoss),
            Double(meanAbsResidual * 1000),
            Double(massDrift),
            reposeViolations,
            trainSteps
        )
    }

    func jsonDictionary() -> [String: Any] {
        [
            "enabled": enabled,
            "trainSteps": trainSteps,
            "lastLoss": lastLoss,
            "meanAbsResidual": meanAbsResidual,
            "maxAbsResidual": maxAbsResidual,
            "massDrift": massDrift,
            "reposeViolations": reposeViolations
        ]
    }
}

/// Physics-constrained residual corrector for settled pack surfaces.
@MainActor
final class PhysicsConstrainedResidualCorrector {
    static let resolution = 24
    static let maxDelta: Float = 0.012

    private var mlp = TinyMLP()
    private(set) var stats = ResidualCorrectionStats()
    private(set) var correctedHeights: [Float] = []
    private(set) var physicsHeights: [Float] = []
    private(set) var residualField: [Float] = []

    var enabled: Bool = false
    var isTraining: Bool = false
    var trainEveryNFrames: Int = 6
    private var frameCounter: Int = 0

    func reset() {
        mlp = TinyMLP()
        stats = ResidualCorrectionStats(enabled: enabled)
        correctedHeights = []
        physicsHeights = []
        residualField = []
        frameCounter = 0
    }

    /// Evaluate residual field; optionally train against DEM teacher heights.
    @discardableResult
    func tick(
        mpm: MPMSimulator,
        demHeights: [Float]?,
        params: ConstitutiveParams,
        fillRadius: Float,
        maxHeight: Float
    ) -> ResidualCorrectionStats {
        stats.enabled = enabled
        guard enabled else { return stats }
        frameCounter += 1

        let res = Self.resolution
        var phys = [Float](repeating: 0, count: res * res)
        _ = mpm.binSurfaceHeights(resolution: res, fillRadius: fillRadius, into: &phys)
        physicsHeights = phys

        let teacher = demHeights.flatMap { resampleHeightField($0, to: res) } ?? synthesizeTeacher(from: phys, params: params)

        if isTraining, frameCounter % max(trainEveryNFrames, 1) == 0 {
            trainBatch(physics: phys, teacher: teacher, params: params, fillRadius: fillRadius, maxHeight: maxHeight)
        }

        let (corrected, residual, massDrift, reposeBad) = applyWithConstraints(
            physics: phys,
            params: params,
            fillRadius: fillRadius,
            maxHeight: maxHeight
        )
        correctedHeights = corrected
        residualField = residual

        let absMean = residual.reduce(Float(0)) { $0 + abs($1) } / Float(max(residual.count, 1))
        let absMax = residual.map { abs($0) }.max() ?? 0
        stats.meanAbsResidual = absMean
        stats.maxAbsResidual = absMax
        stats.massDrift = massDrift
        stats.reposeViolations = reposeBad
        return stats
    }

    // MARK: - Network I/O

    private func features(
        height: Float,
        ix: Int,
        jz: Int,
        resolution: Int,
        fillRadius: Float,
        maxHeight: Float,
        params: ConstitutiveParams
    ) -> [Float] {
        let u = (Float(ix) + 0.5) / Float(resolution) * 2 - 1
        let v = (Float(jz) + 0.5) / Float(resolution) * 2 - 1
        let x = u * fillRadius
        let z = v * fillRadius
        let r = hypot(x, z)
        let ringProx = max(0, 1 - abs(r - fillRadius * 0.92) / 0.08)
        return [
            height / max(maxHeight, 1e-3),
            r / max(fillRadius, 1e-3),
            params.phiDegrees / 45,
            log(max(params.youngsModulus, 1e3)) / 15,
            ringProx,
            height > maxHeight * 0.2 ? Float(1) : Float(0) // settled pack flag proxy
        ]
    }

    private func trainBatch(
        physics: [Float],
        teacher: [Float],
        params: ConstitutiveParams,
        fillRadius: Float,
        maxHeight: Float
    ) {
        let res = Self.resolution
        var lossSum: Float = 0
        var samples = 0
        // Stochastic subset for realtime budget.
        for _ in 0..<48 {
            let ix = Int.random(in: 0..<res)
            let jz = Int.random(in: 0..<res)
            let idx = jz * res + ix
            let u = (Float(ix) + 0.5) / Float(res) * 2 - 1
            let v = (Float(jz) + 0.5) / Float(res) * 2 - 1
            if hypot(u * fillRadius, v * fillRadius) > fillRadius { continue }

            let h = physics[idx]
            let targetDelta = (teacher[idx] - h) / Self.maxDelta
            let clampedTarget = max(-1, min(1, targetDelta))
            let x = features(
                height: h,
                ix: ix,
                jz: jz,
                resolution: res,
                fillRadius: fillRadius,
                maxHeight: maxHeight,
                params: params
            )
            let loss = mlp.trainStep(x: x, target: clampedTarget)
            lossSum += loss
            samples += 1
        }
        if samples > 0 {
            stats.lastLoss = lossSum / Float(samples)
            stats.trainSteps += samples
        }
    }

    private func applyWithConstraints(
        physics: [Float],
        params: ConstitutiveParams,
        fillRadius: Float,
        maxHeight: Float
    ) -> (corrected: [Float], residual: [Float], massDrift: Float, reposeViolations: Int) {
        let res = Self.resolution
        var raw = [Float](repeating: 0, count: res * res)
        var residual = [Float](repeating: 0, count: res * res)

        for jz in 0..<res {
            for ix in 0..<res {
                let idx = jz * res + ix
                let h = physics[idx]
                let x = features(
                    height: h,
                    ix: ix,
                    jz: jz,
                    resolution: res,
                    fillRadius: fillRadius,
                    maxHeight: maxHeight,
                    params: params
                )
                let unit = tanh(mlp.predict(x))
                // Gate: weaker correction on empty / very active surface edges.
                let gate: Float = h < 1e-4 ? 0.05 : 1.0
                let dh = unit * Self.maxDelta * gate
                residual[idx] = dh
                raw[idx] = max(0, h + dh)
            }
        }

        // Mass conservation: preserve Σh inside the disk.
        var sumPhys: Float = 0
        var sumCorr: Float = 0
        var maskCount = 0
        for jz in 0..<res {
            for ix in 0..<res {
                let u = (Float(ix) + 0.5) / Float(res) * 2 - 1
                let v = (Float(jz) + 0.5) / Float(res) * 2 - 1
                if hypot(u, v) > 1 { continue }
                let idx = jz * res + ix
                sumPhys += physics[idx]
                sumCorr += raw[idx]
                maskCount += 1
            }
        }
        let scale: Float
        if sumCorr > 1e-6 {
            scale = sumPhys / sumCorr
        } else {
            scale = 1
        }
        var corrected = raw.map { $0 * scale }

        // Soft repose: limit neighbor slopes to tan(φ).
        let tanPhi = tan(params.sanitized().phiDegrees * .pi / 180)
        let cell = (2 * fillRadius) / Float(res)
        var violations = 0
        for pass in 0..<2 {
            _ = pass
            for jz in 1..<(res - 1) {
                for ix in 1..<(res - 1) {
                    let u = (Float(ix) + 0.5) / Float(res) * 2 - 1
                    let v = (Float(jz) + 0.5) / Float(res) * 2 - 1
                    if hypot(u, v) > 1 { continue }
                    let idx = jz * res + ix
                    let h = corrected[idx]
                    for (dx, dz) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                        let j = (jz + dz) * res + (ix + dx)
                        let slope = abs(corrected[j] - h) / max(cell, 1e-4)
                        if slope > tanPhi * 1.15 {
                            violations += 1
                            let mid = 0.5 * (corrected[j] + h)
                            let maxDh = tanPhi * cell
                            if corrected[j] > h {
                                corrected[j] = mid + 0.5 * maxDh
                                corrected[idx] = mid - 0.5 * maxDh
                            } else {
                                corrected[j] = mid - 0.5 * maxDh
                                corrected[idx] = mid + 0.5 * maxDh
                            }
                            corrected[j] = max(0, corrected[j])
                            corrected[idx] = max(0, corrected[idx])
                        }
                    }
                }
            }
        }

        var sumFinal: Float = 0
        for jz in 0..<res {
            for ix in 0..<res {
                let u = (Float(ix) + 0.5) / Float(res) * 2 - 1
                let v = (Float(jz) + 0.5) / Float(res) * 2 - 1
                if hypot(u, v) > 1 { continue }
                sumFinal += corrected[jz * res + ix]
            }
        }
        let drift = abs(sumFinal - sumPhys) / max(sumPhys, 1e-4)
        _ = maskCount
        return (corrected, residual, drift, violations / 2)
    }

    private func synthesizeTeacher(from physics: [Float], params: ConstitutiveParams) -> [Float] {
        // Mild synthetic bias: slightly steeper cone toward repose — something to fit.
        let res = Self.resolution
        let targetRepose = params.phiDegrees * .pi / 180
        return physics.enumerated().map { idx, h in
            let jz = idx / res
            let ix = idx % res
            let u = (Float(ix) + 0.5) / Float(res) * 2 - 1
            let v = (Float(jz) + 0.5) / Float(res) * 2 - 1
            let r = hypot(u, v)
            let boost = max(0, 0.004 * (1 - r) * sin(targetRepose))
            return max(0, h + boost)
        }
    }

    private func resampleHeightField(_ source: [Float], to resolution: Int) -> [Float]? {
        let srcRes = Int(sqrt(Double(source.count)))
        guard srcRes * srcRes == source.count, srcRes > 1 else { return nil }
        var out = [Float](repeating: 0, count: resolution * resolution)
        for jz in 0..<resolution {
            for ix in 0..<resolution {
                let u = (Float(ix) + 0.5) / Float(resolution)
                let v = (Float(jz) + 0.5) / Float(resolution)
                let sx = min(max(Int(u * Float(srcRes)), 0), srcRes - 1)
                let sz = min(max(Int(v * Float(srcRes)), 0), srcRes - 1)
                out[jz * resolution + ix] = source[sz * srcRes + sx]
            }
        }
        return out
    }
}

/// Visual overlay of neural-corrected surface.
@MainActor
final class ResidualSurfaceVisualizer {
    private var host: Entity?
    private var meshEntity: ModelEntity?

    func attach(to tierEntity: Entity) {
        host?.removeFromParent()
        let root = Entity()
        root.name = "NeuralResidualSurface"
        let surface = tierEntity.findEntity(named: "TierSurface") ?? tierEntity
        surface.addChild(root)
        host = root
        root.isEnabled = false
    }

    func setEnabled(_ enabled: Bool) {
        host?.isEnabled = enabled
    }

    func update(heights: [Float], resolution: Int, fillRadius: Float) {
        guard let host else { return }
        meshEntity?.removeFromParent()
        meshEntity = nil
        guard heights.count == resolution * resolution else { return }

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        for jz in 0..<resolution {
            for ix in 0..<resolution {
                let u = (Float(ix) + 0.5) / Float(resolution) * 2 - 1
                let v = (Float(jz) + 0.5) / Float(resolution) * 2 - 1
                let x = u * fillRadius
                let z = v * fillRadius
                let h = heights[jz * resolution + ix] + 0.001
                positions.append(SIMD3(x, h, z))
                normals.append(SIMD3(0, 1, 0))
            }
        }
        for jz in 0..<(resolution - 1) {
            for ix in 0..<(resolution - 1) {
                let i0 = UInt32(jz * resolution + ix)
                let i1 = i0 + 1
                let i2 = UInt32((jz + 1) * resolution + ix)
                let i3 = i2 + 1
                let c0 = positions[Int(i0)]
                if hypot(c0.x, c0.z) > fillRadius { continue }
                indices.append(contentsOf: [i0, i2, i1, i1, i2, i3])
            }
        }
        for jz in 1..<(resolution - 1) {
            for ix in 1..<(resolution - 1) {
                let i = jz * resolution + ix
                let cell = (2 * fillRadius) / Float(resolution)
                let dx = positions[i + 1].y - positions[i - 1].y
                let dz = positions[i + resolution].y - positions[i - resolution].y
                normals[i] = normalize(SIMD3(-dx / cell, 2, -dz / cell))
            }
        }

        var descriptor = MeshDescriptor(name: "NeuralCorrectedSurface")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)
        guard let resource = try? MeshResource.generate(from: [descriptor]) else { return }
        var mat = SimpleMaterial()
        mat.color = .init(tint: UIColor(red: 0.45, green: 0.85, blue: 0.55, alpha: 0.5))
        mat.roughness = .float(0.88)
        let entity = ModelEntity(mesh: resource, materials: [mat])
        entity.name = "NeuralCorrectedSurfaceMesh"
        host.addChild(entity)
        meshEntity = entity
    }
}
