import Foundation
import RealityKit
import simd
import UIKit

struct AdaptivityStats: Equatable, Sendable {
    var splitCount: Int = 0
    var coarsenedCount: Int = 0
    var fineParticles: Int = 0
    var baseParticles: Int = 0
    var coarseParticles: Int = 0
    var field: ErrorIndicatorField = .empty(fillRadius: 0.5)

    var hudLine: String {
        String(
            format: "Adapt Δ+/−=%d/%d · %@",
            splitCount,
            coarsenedCount,
            field.hudLine
        )
    }
}

/// Particle-level refine / coarsen driven by local error indicators.
@MainActor
final class AdaptiveResolutionController {
    private(set) var latest = AdaptivityStats()
    var enabled: Bool = false
    var evaluateEveryNFrames: Int = 8
    var maxSplitsPerTick: Int = 48
    var maxCoarsensPerTick: Int = 64
    private var frameCounter: Int = 0

    func reset() {
        latest = AdaptivityStats()
        frameCounter = 0
    }

    /// Evaluate indicators and optionally mutate particles.
    @discardableResult
    func tick(
        sim: MPMSimulator,
        capsules: [MPMCapsuleSDF],
        applyAdaptation: Bool
    ) -> AdaptivityStats {
        frameCounter += 1
        guard enabled else {
            latest.field = ErrorIndicatorBuilder.build(
                from: sim,
                capsules: capsules,
                fillRadius: sim.tier.fillRadius
            )
            return latest
        }
        guard frameCounter % max(evaluateEveryNFrames, 1) == 0 else { return latest }

        let field = ErrorIndicatorBuilder.build(
            from: sim,
            capsules: capsules,
            fillRadius: sim.tier.fillRadius
        )

        var splits = 0
        var coarsens = 0
        var fineP = 0, baseP = 0, coarseP = 0

        if applyAdaptation {
            let plan = planActions(sim: sim, field: field)
            splits = sim.splitParticles(indices: plan.splitIndices, maxCount: maxSplitsPerTick)
            coarsens = sim.coarsenParticles(indices: plan.coarsenIndices, maxCount: maxCoarsensPerTick)
        }

        sim.forEachParticle { _, p in
            guard p.state == 1 || p.state == 2 else { return }
            guard let idx = ErrorIndicatorBuilder.cellIndex(
                x: p.position,
                resolution: field.resolution,
                fillRadius: field.fillRadius
            ) else { return }
            switch field.cells[idx].tier {
            case .fine: fineP += 1
            case .base: baseP += 1
            case .coarse: coarseP += 1
            }
        }

        latest = AdaptivityStats(
            splitCount: splits,
            coarsenedCount: coarsens,
            fineParticles: fineP,
            baseParticles: baseP,
            coarseParticles: coarseP,
            field: field
        )
        return latest
    }

    private struct ActionPlan {
        var splitIndices: [Int]
        var coarsenIndices: [Int]
    }

    private func planActions(sim: MPMSimulator, field: ErrorIndicatorField) -> ActionPlan {
        var splitCandidates: [(Int, Float)] = []
        var coarsenCandidates: [(Int, Float)] = []

        sim.forEachParticle { index, p in
            guard p.state == 1 else { return }
            guard let cell = ErrorIndicatorBuilder.cellIndex(
                x: p.position,
                resolution: field.resolution,
                fillRadius: field.fillRadius
            ) else { return }
            let sample = field.cells[cell]
            switch sample.tier {
            case .fine:
                // Prefer heavier / faster particles for splitting.
                let score = sample.combined * (0.5 + min(p.mass, 1))
                splitCandidates.append((index, score))
            case .coarse:
                // Deep + slow → sleep/coarsen.
                if length(p.velocity) < 0.05, p.position.y < sim.tier.ringHeight * 0.35 {
                    coarsenCandidates.append((index, 1 - sample.combined))
                }
            case .base:
                break
            }
        }

        splitCandidates.sort { $0.1 > $1.1 }
        coarsenCandidates.sort { $0.1 > $1.1 }
        return ActionPlan(
            splitIndices: splitCandidates.map(\.0),
            coarsenIndices: coarsenCandidates.map(\.0)
        )
    }
}

/// Heatmap overlay for error-indicator tiers.
@MainActor
final class AdaptivityVisualizer {
    private var host: Entity?
    private var meshEntity: ModelEntity?

    func attach(to tierEntity: Entity) {
        host?.removeFromParent()
        let root = Entity()
        root.name = "AdaptivityIndicators"
        let surface = tierEntity.findEntity(named: "TierSurface") ?? tierEntity
        surface.addChild(root)
        host = root
        root.isEnabled = false
    }

    func setEnabled(_ enabled: Bool) {
        host?.isEnabled = enabled
    }

    func update(with field: ErrorIndicatorField) {
        guard let host else { return }
        meshEntity?.removeFromParent()
        meshEntity = nil
        guard field.cells.count == field.resolution * field.resolution else { return }

        let res = field.resolution
        var positions: [SIMD3<Float>] = []
        var colors: [SIMD4<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        positions.reserveCapacity(res * res)

        for jz in 0..<res {
            for ix in 0..<res {
                let u = (Float(ix) + 0.5) / Float(res) * 2 - 1
                let v = (Float(jz) + 0.5) / Float(res) * 2 - 1
                let x = u * field.fillRadius
                let z = v * field.fillRadius
                let sample = field.cells[jz * res + ix]
                let h: Float = 0.002 + sample.combined * 0.012
                positions.append(SIMD3(x, h, z))
                normals.append(SIMD3(0, 1, 0))
                colors.append(tierColor(sample.tier, error: sample.combined))
            }
        }

        for jz in 0..<(res - 1) {
            for ix in 0..<(res - 1) {
                let i0 = UInt32(jz * res + ix)
                let i1 = i0 + 1
                let i2 = UInt32((jz + 1) * res + ix)
                let i3 = i2 + 1
                // Skip cells mostly outside the ring.
                let c0 = positions[Int(i0)]
                if hypot(c0.x, c0.z) > field.fillRadius { continue }
                indices.append(contentsOf: [i0, i2, i1, i1, i2, i3])
            }
        }

        var descriptor = MeshDescriptor(name: "AdaptivityHeatmap")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        // RealityKit MeshDescriptor may not support vertex colors on all paths —
        // bake tier into a single material tint via average; use unlit-ish SimpleMaterial.
        descriptor.primitives = .triangles(indices)
        guard let resource = try? MeshResource.generate(from: [descriptor]) else { return }

        // Dominant tier tint from mean error.
        let tint: UIColor
        if field.meanError > 0.55 {
            tint = UIColor(red: 0.95, green: 0.35, blue: 0.25, alpha: 0.45)
        } else if field.meanError < 0.2 {
            tint = UIColor(red: 0.25, green: 0.55, blue: 0.95, alpha: 0.35)
        } else {
            tint = UIColor(red: 0.95, green: 0.78, blue: 0.25, alpha: 0.40)
        }
        var mat = SimpleMaterial()
        mat.color = .init(tint: tint)
        mat.roughness = .float(0.9)
        let entity = ModelEntity(mesh: resource, materials: [mat])
        entity.name = "AdaptivityHeatmapMesh"
        host.addChild(entity)
        meshEntity = entity
    }

    private func tierColor(_ tier: RefinementTier, error: Float) -> SIMD4<Float> {
        switch tier {
        case .fine: return SIMD4(0.95, 0.30, 0.22, 0.55)
        case .base: return SIMD4(0.95, 0.78, 0.25, 0.40)
        case .coarse: return SIMD4(0.25, 0.55, 0.95, 0.35)
        }
    }
}
