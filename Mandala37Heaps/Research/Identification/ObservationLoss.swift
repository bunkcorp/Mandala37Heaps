import Foundation
import simd

/// Reduced surface / kinematics features used for constitutive identification.
struct GranularObservation: Equatable, Sendable {
    var meanHeight: Float
    var peakHeight: Float
    var meanRadius: Float
    var peakRadius: Float
    var kineticEnergy: Float
    var reposeDegrees: Float
    var particleCount: Int
    var totalMass: Float

    static let empty = GranularObservation(
        meanHeight: 0,
        peakHeight: 0,
        meanRadius: 0,
        peakRadius: 0,
        kineticEnergy: 0,
        reposeDegrees: 0,
        particleCount: 0,
        totalMass: 0
    )

    var isValid: Bool {
        particleCount > 8
            && totalMass > 1e-6
            && meanHeight.isFinite
            && peakHeight.isFinite
            && meanRadius.isFinite
            && peakRadius.isFinite
            && kineticEnergy.isFinite
            && reposeDegrees.isFinite
            && totalMass.isFinite
    }

    func jsonDictionary() -> [String: Any] {
        [
            "meanHeight": meanHeight,
            "peakHeight": peakHeight,
            "meanRadius": meanRadius,
            "peakRadius": peakRadius,
            "kineticEnergy": kineticEnergy,
            "reposeDegrees": reposeDegrees,
            "particleCount": particleCount,
            "totalMass": totalMass
        ]
    }
}

/// Weights for surface–velocity style observation loss (Phase 2).
struct ObservationLossWeights: Equatable, Sendable {
    var meanHeight: Float = 4.0
    var peakHeight: Float = 1.5
    var meanRadius: Float = 3.0
    var kineticEnergy: Float = 0.35
    var reposeDegrees: Float = 2.0

    static let `default` = ObservationLossWeights()
}

enum ObservationLoss {
    /// Weighted MSE between prediction and target features.
    static func value(
        prediction: GranularObservation,
        target: GranularObservation,
        weights: ObservationLossWeights = .default
    ) -> Float {
        guard prediction.isValid, target.isValid else { return 1e3 }

        func term(_ a: Float, _ b: Float, _ scale: Float, _ w: Float) -> Float {
            guard a.isFinite, b.isFinite, scale.isFinite else { return 0 }
            let d = (a - b) / max(scale, 1e-4)
            let t = w * d * d
            return t.isFinite ? t : 0
        }

        let hScale = max(target.meanHeight, target.peakHeight, 0.01)
        let rScale = max(target.meanRadius, 0.02)
        let keScale = max(target.kineticEnergy, 1e-4)
        let reposeScale: Float = 10

        let loss = term(prediction.meanHeight, target.meanHeight, hScale, weights.meanHeight)
            + term(prediction.peakHeight, target.peakHeight, hScale, weights.peakHeight)
            + term(prediction.meanRadius, target.meanRadius, rScale, weights.meanRadius)
            + term(prediction.kineticEnergy, target.kineticEnergy, keScale, weights.kineticEnergy)
            + term(prediction.reposeDegrees, target.reposeDegrees, reposeScale, weights.reposeDegrees)
        return loss.isFinite ? min(loss, 1e4) : 1e3
    }
}

/// Free parameters identified in Phase 2 (FD-sensitive subset).
enum IdentifiableParameter: String, CaseIterable, Identifiable, Sendable {
    case phiDegrees
    case youngsModulus

    var id: String { rawValue }

    var shortTitle: String {
        switch self {
        case .phiDegrees: return "φ"
        case .youngsModulus: return "E"
        }
    }

    /// Relative FD step size.
    var relativeEpsilon: Float {
        switch self {
        case .phiDegrees: return 0.03
        case .youngsModulus: return 0.08
        }
    }

    func value(in params: ConstitutiveParams) -> Float {
        switch self {
        case .phiDegrees: return params.phiDegrees
        case .youngsModulus: return params.youngsModulus
        }
    }

    func applying(_ value: Float, to params: ConstitutiveParams) -> ConstitutiveParams {
        var next = params
        switch self {
        case .phiDegrees:
            next.phiDegrees = min(max(value, 18), 48)
        case .youngsModulus:
            next.youngsModulus = min(max(value, 5e4), 1.5e6)
        }
        return next
    }
}
