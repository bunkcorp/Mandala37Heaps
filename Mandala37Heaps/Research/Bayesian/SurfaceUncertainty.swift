import Foundation
import RealityKit
import simd
import UIKit

/// Coarse pile-surface mean / std field from posterior ensemble propagation.
struct SurfaceUncertaintyField: Equatable, Sendable {
    var resolution: Int
    var fillRadius: Float
    var meanHeight: [Float]
    var stdHeight: [Float]
    var sampleCount: Int

    static func empty(resolution: Int = 32, fillRadius: Float) -> SurfaceUncertaintyField {
        let n = resolution * resolution
        return SurfaceUncertaintyField(
            resolution: resolution,
            fillRadius: fillRadius,
            meanHeight: Array(repeating: 0, count: n),
            stdHeight: Array(repeating: 0, count: n),
            sampleCount: 0
        )
    }

    var meanSigma: Float {
        guard !stdHeight.isEmpty else { return 0 }
        let sum = stdHeight.reduce(Float(0), +)
        return sum / Float(stdHeight.count)
    }

    var maxSigma: Float {
        stdHeight.max() ?? 0
    }

    var hudLine: String {
        String(
            format: "Surf σ̄=%.1fmm  σmax=%.1fmm  ens=%d",
            Double(meanSigma * 1000),
            Double(maxSigma * 1000),
            sampleCount
        )
    }
}

/// Propagates parameter posterior samples through shadow MPM → height uncertainty.
@MainActor
final class SurfaceUncertaintyEngine {
    static let fieldResolution = 32
    static let ensembleCount = 5
    static let rolloutSteps = 3

    private let shadow: MPMSimulator
    private var rng = SeededRNG(seed: 0xBA5E_5001)
    private(set) var field: SurfaceUncertaintyField

    init?(tier: MandalaTier) {
        guard let shadow = MPMSimulator(tier: tier) else { return nil }
        self.shadow = shadow
        self.field = .empty(resolution: Self.fieldResolution, fillRadius: tier.fillRadius)
    }

    func reset(fillRadius: Float) {
        field = .empty(resolution: Self.fieldResolution, fillRadius: fillRadius)
        rng = SeededRNG(seed: 0xBA5E_5001)
    }

    /// Rebuild uncertainty field from a live particle checkpoint + posterior.
    func update(
        checkpoint: Data,
        capsules: [MPMCapsuleSDF],
        posterior: ParameterPosteriorState,
        fillRadius: Float
    ) {
        let samples = posterior.sample(count: Self.ensembleCount, rng: &rng)
        guard !samples.isEmpty else { return }

        let res = Self.fieldResolution
        let n = res * res
        var sum = [Float](repeating: 0, count: n)
        var sumSq = [Float](repeating: 0, count: n)
        var used = 0

        for params in samples {
            shadow.setContactCapsules(capsules)
            shadow.restoreParticleCheckpoint(checkpoint)
            shadow.setConstitutive(params)
            for _ in 0..<Self.rolloutSteps {
                shadow.stepPhysicsOnly(dt: 1 / 60)
            }
            let heights = histogramHeights(
                from: shadow,
                resolution: res,
                fillRadius: fillRadius
            )
            for i in 0..<n {
                let h = heights[i]
                sum[i] += h
                sumSq[i] += h * h
            }
            used += 1
        }

        guard used > 0 else { return }
        let inv = 1 / Float(used)
        var mean = [Float](repeating: 0, count: n)
        var std = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let m = sum[i] * inv
            mean[i] = m
            let v = max(0, sumSq[i] * inv - m * m)
            std[i] = sqrt(v)
        }

        field = SurfaceUncertaintyField(
            resolution: res,
            fillRadius: fillRadius,
            meanHeight: mean,
            stdHeight: std,
            sampleCount: used
        )
    }

    /// Deposit active particle heights into a polar-clamped XY grid (max height).
    private func histogramHeights(
        from sim: MPMSimulator,
        resolution: Int,
        fillRadius: Float
    ) -> [Float] {
        var heights = [Float](repeating: 0, count: resolution * resolution)
        if sim.binSurfaceHeights(resolution: resolution, fillRadius: fillRadius, into: &heights) {
            return heights
        }
        return fallbackCone(
            resolution: resolution,
            fillRadius: fillRadius,
            observation: sim.sampleObservation()
        )
    }

    private func fallbackCone(
        resolution: Int,
        fillRadius: Float,
        observation: GranularObservation
    ) -> [Float] {
        var heights = [Float](repeating: 0, count: resolution * resolution)
        let peak = max(observation.peakHeight, observation.meanHeight)
        let baseR = max(observation.peakRadius, observation.meanRadius, 0.02)
        for jz in 0..<resolution {
            for ix in 0..<resolution {
                let u = (Float(ix) + 0.5) / Float(resolution) * 2 - 1
                let v = (Float(jz) + 0.5) / Float(resolution) * 2 - 1
                let x = u * fillRadius
                let z = v * fillRadius
                let r = hypot(x, z)
                guard r <= fillRadius else { continue }
                let h = max(0, peak * (1 - r / baseR))
                heights[jz * resolution + ix] = h
            }
        }
        return heights
    }
}

/// RealityKit presentation of mean surface + σ-tinted uncertainty band.
@MainActor
final class UncertaintyBandVisualizer {
    private var host: Entity?
    private var meanEntity: ModelEntity?
    private var bandEntity: ModelEntity?

    func attach(to tierEntity: Entity) {
        host?.removeFromParent()
        let root = Entity()
        root.name = "UncertaintyBands"
        let surface = tierEntity.findEntity(named: "TierSurface") ?? tierEntity
        surface.addChild(root)
        host = root
        root.isEnabled = false
    }

    func setEnabled(_ enabled: Bool) {
        host?.isEnabled = enabled
    }

    func update(with field: SurfaceUncertaintyField) {
        guard let host else { return }
        meanEntity?.removeFromParent()
        bandEntity?.removeFromParent()
        meanEntity = nil
        bandEntity = nil

        guard field.sampleCount > 0 else { return }

        if let meanMesh = makeHeightMesh(
            heights: field.meanHeight,
            resolution: field.resolution,
            fillRadius: field.fillRadius,
            yOffset: 0,
            color: UIColor(red: 0.35, green: 0.72, blue: 0.95, alpha: 0.55)
        ) {
            host.addChild(meanMesh)
            meanEntity = meanMesh
        }

        // Upper band = mean + σ
        let upper = zip(field.meanHeight, field.stdHeight).map { $0 + $1 }
        if let bandMesh = makeHeightMesh(
            heights: upper,
            resolution: field.resolution,
            fillRadius: field.fillRadius,
            yOffset: 0.0005,
            color: UIColor(red: 0.95, green: 0.55, blue: 0.25, alpha: 0.35)
        ) {
            host.addChild(bandMesh)
            bandEntity = bandMesh
        }
    }

    private func makeHeightMesh(
        heights: [Float],
        resolution: Int,
        fillRadius: Float,
        yOffset: Float,
        color: UIColor
    ) -> ModelEntity? {
        let res = resolution
        guard heights.count == res * res else { return nil }

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        positions.reserveCapacity(res * res)
        normals.reserveCapacity(res * res)

        for jz in 0..<res {
            for ix in 0..<res {
                let u = (Float(ix) + 0.5) / Float(res) * 2 - 1
                let v = (Float(jz) + 0.5) / Float(res) * 2 - 1
                let x = u * fillRadius
                let z = v * fillRadius
                let r = hypot(x, z)
                var h = heights[jz * res + ix] + yOffset
                if r > fillRadius {
                    h = 0
                }
                positions.append(SIMD3(x, h, z))
                normals.append(SIMD3(0, 1, 0))
            }
        }

        for jz in 0..<(res - 1) {
            for ix in 0..<(res - 1) {
                let i0 = UInt32(jz * res + ix)
                let i1 = i0 + 1
                let i2 = UInt32((jz + 1) * res + ix)
                let i3 = i2 + 1
                indices.append(contentsOf: [i0, i2, i1, i1, i2, i3])
            }
        }

        // Recompute rough normals.
        for jz in 1..<(res - 1) {
            for ix in 1..<(res - 1) {
                let i = jz * res + ix
                let dx = positions[i + 1].y - positions[i - 1].y
                let dz = positions[i + res].y - positions[i - res].y
                let cell = (2 * fillRadius) / Float(res)
                normals[i] = normalize(SIMD3(-dx / cell, 2, -dz / cell))
            }
        }

        var descriptor = MeshDescriptor(name: "UncertaintySurface")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)

        guard let resource = try? MeshResource.generate(from: [descriptor]) else { return nil }
        var mat = SimpleMaterial()
        mat.color = .init(tint: color)
        mat.roughness = .float(0.85)
        mat.metallic = .float(0.05)
        let entity = ModelEntity(mesh: resource, materials: [mat])
        entity.name = "UncertaintySurfaceMesh"
        return entity
    }
}
