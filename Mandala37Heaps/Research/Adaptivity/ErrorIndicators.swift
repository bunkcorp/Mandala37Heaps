import Foundation
import simd

/// Discrete refinement tier for adaptive multiresolution.
enum RefinementTier: Int, CaseIterable, Sendable {
    case coarse = 0
    case base = 1
    case fine = 2

    var title: String {
        switch self {
        case .coarse: return "coarse"
        case .base: return "base"
        case .fine: return "fine"
        }
    }
}

/// Per-cell error indicator components on a coarse XZ lattice.
struct CellErrorSample: Equatable, Sendable {
    var contact: Float = 0
    var velocity: Float = 0
    var strain: Float = 0
    var combined: Float = 0
    var tier: RefinementTier = .base
    var particleCount: Int = 0
}

/// Coarse indicator field over the tier deck.
struct ErrorIndicatorField: Equatable, Sendable {
    var resolution: Int
    var fillRadius: Float
    var cells: [CellErrorSample]
    var fineCount: Int
    var baseCount: Int
    var coarseCount: Int
    var meanError: Float
    var maxError: Float

    static func empty(resolution: Int = 24, fillRadius: Float) -> ErrorIndicatorField {
        ErrorIndicatorField(
            resolution: resolution,
            fillRadius: fillRadius,
            cells: Array(repeating: CellErrorSample(), count: resolution * resolution),
            fineCount: 0,
            baseCount: 0,
            coarseCount: 0,
            meanError: 0,
            maxError: 0
        )
    }

    var hudLine: String {
        String(
            format: "Adapt fine=%d base=%d coarse=%d  ē=%.2f emax=%.2f",
            fineCount,
            baseCount,
            coarseCount,
            Double(meanError),
            Double(maxError)
        )
    }

    func jsonDictionary() -> [String: Any] {
        [
            "resolution": resolution,
            "fineCount": fineCount,
            "baseCount": baseCount,
            "coarseCount": coarseCount,
            "meanError": meanError,
            "maxError": maxError
        ]
    }
}

/// Builds local error indicators from MPM particles + kinematic contacts.
@MainActor
enum ErrorIndicatorBuilder {
    static let defaultResolution = 24

    /// Weights for combining normalized indicator channels.
    struct Weights: Equatable, Sendable {
        var contact: Float = 1.2
        var velocity: Float = 1.0
        var strain: Float = 0.85
        static let `default` = Weights()
    }

    static func build(
        from sim: MPMSimulator,
        capsules: [MPMCapsuleSDF],
        fillRadius: Float,
        resolution: Int = defaultResolution,
        weights: Weights = .default,
        fineThreshold: Float = 0.55,
        coarseThreshold: Float = 0.18
    ) -> ErrorIndicatorField {
        var field = ErrorIndicatorField.empty(resolution: resolution, fillRadius: fillRadius)
        let n = resolution * resolution
        var contactAcc = [Float](repeating: 0, count: n)
        var velAcc = [Float](repeating: 0, count: n)
        var strainAcc = [Float](repeating: 0, count: n)
        var counts = [Int](repeating: 0, count: n)

        sim.forEachParticle { _, p in
            guard p.state == 1 || p.state == 2 else { return }
            let x = p.position
            let r = hypot(x.x, x.z)
            guard r <= fillRadius * 1.02 else { return }
            guard let idx = cellIndex(x: x, resolution: resolution, fillRadius: fillRadius) else { return }

            let speed = length(p.velocity)
            let strain = deformationError(p)
            let contact = contactProximity(at: x, fillRadius: fillRadius, maxHeight: sim.tier.ringHeight, capsules: capsules)

            contactAcc[idx] = max(contactAcc[idx], contact)
            velAcc[idx] = max(velAcc[idx], speed)
            strainAcc[idx] = max(strainAcc[idx], strain)
            counts[idx] += 1
        }

        let maxVel = max(velAcc.max() ?? 0, 1e-4)
        let maxStrain = max(strainAcc.max() ?? 0, 1e-4)

        var sum: Float = 0
        var maxE: Float = 0
        var fine = 0, base = 0, coarse = 0

        for i in 0..<n {
            let c = contactAcc[i]
            let v = velAcc[i] / maxVel
            let s = strainAcc[i] / maxStrain
            let combined = weights.contact * c + weights.velocity * v + weights.strain * s
            let tier: RefinementTier
            if combined >= fineThreshold {
                tier = .fine
                fine += 1
            } else if combined <= coarseThreshold {
                tier = .coarse
                coarse += 1
            } else {
                tier = .base
                base += 1
            }
            field.cells[i] = CellErrorSample(
                contact: c,
                velocity: v,
                strain: s,
                combined: combined,
                tier: tier,
                particleCount: counts[i]
            )
            sum += combined
            maxE = max(maxE, combined)
        }

        field.fineCount = fine
        field.baseCount = base
        field.coarseCount = coarse
        field.meanError = sum / Float(max(n, 1))
        field.maxError = maxE
        return field
    }

    static func cellIndex(x: SIMD3<Float>, resolution: Int, fillRadius: Float) -> Int? {
        let u = (x.x / fillRadius + 1) * 0.5
        let v = (x.z / fillRadius + 1) * 0.5
        guard u >= 0, u <= 1, v >= 0, v <= 1 else { return nil }
        let ix = min(max(Int(u * Float(resolution)), 0), resolution - 1)
        let jz = min(max(Int(v * Float(resolution)), 0), resolution - 1)
        return jz * resolution + ix
    }

    /// 0…1 proximity to ring foot or tool capsules.
    private static func contactProximity(
        at x: SIMD3<Float>,
        fillRadius: Float,
        maxHeight: Float,
        capsules: [MPMCapsuleSDF]
    ) -> Float {
        let r = hypot(x.x, x.z)
        let ringDist = abs(r - fillRadius * 0.92)
        let ringScore = max(0, 1 - ringDist / 0.06)

        var toolScore: Float = 0
        for cap in capsules {
            let d = capsuleDistance(x, cap)
            toolScore = max(toolScore, max(0, 1 - d / 0.05))
        }

        // Surface band (not deep bulk).
        let surfaceScore: Float = x.y > maxHeight * 0.35 ? 0.25 : 0
        return min(Float(1), max(ringScore, toolScore) + surfaceScore * 0.5)
    }

    private static func capsuleDistance(_ x: SIMD3<Float>, _ c: MPMCapsuleSDF) -> Float {
        let pa = x - c.p0
        let ba = c.p1 - c.p0
        let denom = max(dot(ba, ba), Float(1e-8))
        let h = min(max(dot(pa, ba) / denom, Float(0)), Float(1))
        return length(pa - ba * h) - c.radius
    }

    private static func deformationError(_ p: MPMParticle) -> Float {
        // ‖F − I‖_F proxy from column-major components.
        let fDev =
            abs(p.f0 - 1) + abs(p.f4 - 1) + abs(p.f8 - 1)
            + abs(p.f1) + abs(p.f2) + abs(p.f3)
            + abs(p.f5) + abs(p.f6) + abs(p.f7)
        let cNorm =
            abs(p.c0) + abs(p.c1) + abs(p.c2)
            + abs(p.c3) + abs(p.c4) + abs(p.c5)
            + abs(p.c6) + abs(p.c7) + abs(p.c8)
        return fDev + 0.15 * cNorm
    }
}
