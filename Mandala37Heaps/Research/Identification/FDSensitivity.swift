import Foundation

/// Central finite-difference sensitivities of observation loss w.r.t. constitutive params.
@MainActor
final class FDSensitivityEngine {
    struct GradientReport: Equatable, Sendable {
        var loss: Float
        var gradients: [IdentifiableParameter: Float]
        var rolloutSteps: Int

        var gradientNorm: Float {
            sqrt(gradients.values.reduce(Float(0)) { $0 + $1 * $1 })
        }

        var summaryLine: String {
            let phi = gradients[.phiDegrees] ?? 0
            let e = gradients[.youngsModulus] ?? 0
            return String(format: "L=%.3f  ∂L/∂φ=%.2e  ∂L/∂E=%.2e", Double(loss), Double(phi), Double(e))
        }
    }

    private let shadow: MPMSimulator
    var rolloutSteps: Int = 4
    var rolloutDt: Float = 1 / 60
    var weights: ObservationLossWeights = .default

    init?(tier: MandalaTier) {
        guard let shadow = MPMSimulator(tier: tier) else { return nil }
        // Shadow never attaches to the scene graph.
        self.shadow = shadow
    }

    /// Estimate ∇_θ L via central differences on a shadow MPM rollout from `checkpoint`.
    func estimateGradient(
        checkpoint: Data,
        baseParams: ConstitutiveParams,
        capsules: [MPMCapsuleSDF],
        target: GranularObservation
    ) -> GradientReport? {
        guard target.isValid else { return nil }

        shadow.setContactCapsules(capsules)
        shadow.restoreParticleCheckpoint(checkpoint)
        shadow.setConstitutive(baseParams)
        for _ in 0..<rolloutSteps {
            shadow.stepPhysicsOnly(dt: rolloutDt)
        }
        let baseObs = shadow.sampleObservation()
        let baseLoss = ObservationLoss.value(prediction: baseObs, target: target, weights: weights)

        var grads: [IdentifiableParameter: Float] = [:]
        for param in IdentifiableParameter.allCases {
            let theta = param.value(in: baseParams)
            let eps = max(abs(theta) * param.relativeEpsilon, param == .phiDegrees ? 0.25 : 1e3)

            let plus = param.applying(theta + eps, to: baseParams)
            let lossPlus = rolloutLoss(
                checkpoint: checkpoint,
                params: plus,
                capsules: capsules,
                target: target
            )

            let minus = param.applying(theta - eps, to: baseParams)
            let lossMinus = rolloutLoss(
                checkpoint: checkpoint,
                params: minus,
                capsules: capsules,
                target: target
            )

            grads[param] = (lossPlus - lossMinus) / (2 * eps)
        }

        return GradientReport(loss: baseLoss, gradients: grads, rolloutSteps: rolloutSteps)
    }

    /// Shadow forward observation for synthetic teacher targets.
    func rolloutObservation(
        checkpoint: Data,
        params: ConstitutiveParams,
        capsules: [MPMCapsuleSDF]
    ) -> GranularObservation {
        shadow.setContactCapsules(capsules)
        shadow.restoreParticleCheckpoint(checkpoint)
        shadow.setConstitutive(params)
        for _ in 0..<rolloutSteps {
            shadow.stepPhysicsOnly(dt: rolloutDt)
        }
        return shadow.sampleObservation()
    }

    private func rolloutLoss(
        checkpoint: Data,
        params: ConstitutiveParams,
        capsules: [MPMCapsuleSDF],
        target: GranularObservation
    ) -> Float {
        let obs = rolloutObservation(checkpoint: checkpoint, params: params, capsules: capsules)
        return ObservationLoss.value(prediction: obs, target: target, weights: weights)
    }
}
