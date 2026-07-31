import Foundation

/// Online constitutive parameter fit using FD gradients on a shadow MPM forward model.
@MainActor
final class ParameterIdentifier {
    struct Status: Equatable, Sendable {
        var isRunning: Bool = false
        var iteration: Int = 0
        var loss: Float = 0
        var gradientNorm: Float = 0
        var params: ConstitutiveParams = .defaultRice
        var hasTarget: Bool = false
        var lastMessage: String = "ID idle"

        var hudLine: String {
            guard hasTarget else { return "ID: capture a target observation first" }
            return String(
                format: "ID iter=%d  L=%.3f  |g|=%.2e  φ=%.1f°  E=%.2e",
                iteration,
                Double(loss),
                Double(gradientNorm),
                Double(params.phiDegrees),
                Double(params.youngsModulus)
            )
        }
    }

    struct TickResult: Equatable, Sendable {
        var didUpdate: Bool
        var loss: Float
        var params: ConstitutiveParams
        var gradients: [IdentifiableParameter: Float]
        var checkpoint: Data?
    }

    private(set) var status = Status()
    private(set) var lastTick = TickResult(
        didUpdate: false,
        loss: 0,
        params: .defaultRice,
        gradients: [:],
        checkpoint: nil
    )
    private var target: GranularObservation?
    private var engine: FDSensitivityEngine?
    private var m: [IdentifiableParameter: Float] = [:]
    private var v: [IdentifiableParameter: Float] = [:]
    private var adamT: Int = 0

    var learningRatePhi: Float = 0.35
    var learningRateYoungs: Float = 2.5e4
    var adamBeta1: Float = 0.9
    var adamBeta2: Float = 0.999
    var fitEveryNFrames: Int = 12
    private var frameCounter: Int = 0

    func prepare(tier: MandalaTier) {
        if engine == nil {
            engine = FDSensitivityEngine(tier: tier)
        }
        status.params = .defaultRice
        status.lastMessage = engine == nil ? "ID: shadow MPM unavailable" : "ID ready"
    }

    func reset() {
        target = nil
        m.removeAll()
        v.removeAll()
        adamT = 0
        frameCounter = 0
        let params = status.params
        status = Status(params: params)
        status.lastMessage = "ID reset"
    }

    func setRunning(_ running: Bool) {
        status.isRunning = running
        status.lastMessage = running ? "ID running (FD Adam)" : "ID paused"
    }

    func seedParams(_ params: ConstitutiveParams) {
        status.params = params
    }

    func captureTarget(from observation: GranularObservation) {
        guard observation.isValid else {
            status.lastMessage = "ID: target invalid (need active particles)"
            return
        }
        target = observation
        status.hasTarget = true
        status.lastMessage = String(
            format: "Target captured · repose≈%.1f°  H̄=%.3f",
            Double(observation.reposeDegrees),
            Double(observation.meanHeight)
        )
    }

    /// Synthetic teacher: roll shadow with ground-truth rice params from the live checkpoint.
    func captureSyntheticTeacherTarget(
        live: MPMSimulator,
        capsules: [MPMCapsuleSDF],
        teacher: ConstitutiveParams = .defaultRice
    ) {
        guard let engine else {
            status.lastMessage = "ID: no shadow engine"
            return
        }
        let checkpoint = live.captureParticleCheckpoint()
        let obs = engine.rolloutObservation(
            checkpoint: checkpoint,
            params: teacher,
            capsules: capsules
        )
        captureTarget(from: obs)
        if status.hasTarget {
            status.lastMessage = String(
                format: "Synthetic teacher · φ=%.1f° E=%.2e",
                Double(teacher.phiDegrees),
                Double(teacher.youngsModulus)
            )
        }
    }

    /// Called from the sim loop; may perform an expensive FD update every N frames.
    @discardableResult
    func tick(
        live: MPMSimulator,
        capsules: [MPMCapsuleSDF]
    ) -> TickResult {
        lastTick = TickResult(
            didUpdate: false,
            loss: status.loss,
            params: live.constitutive,
            gradients: [:],
            checkpoint: nil
        )
        guard status.isRunning, let target, let engine else { return lastTick }
        frameCounter += 1
        guard frameCounter % max(fitEveryNFrames, 1) == 0 else { return lastTick }
        guard live.sampleObservation().isValid else { return lastTick }

        let checkpoint = live.captureParticleCheckpoint()
        let base = live.constitutive
        let safeBase = base.sanitized()
        if !base.isFinite {
            live.setConstitutive(safeBase)
            status.params = safeBase
            status.lastMessage = "ID: reset non-finite constitutive params"
            return lastTick
        }

        guard let report = engine.estimateGradient(
            checkpoint: checkpoint,
            baseParams: safeBase,
            capsules: capsules,
            target: target
        ) else { return lastTick }

        guard report.loss.isFinite,
              report.gradientNorm.isFinite,
              report.gradients.values.allSatisfy(\.isFinite) else {
            status.lastMessage = "ID: skipped non-finite FD gradient"
            return lastTick
        }

        let updated = adamStep(params: safeBase, gradients: report.gradients).sanitized()
        live.setConstitutive(updated)

        status.iteration += 1
        status.loss = report.loss
        status.gradientNorm = report.gradientNorm
        status.params = updated
        status.lastMessage = report.summaryLine
        lastTick = TickResult(
            didUpdate: true,
            loss: report.loss,
            params: updated,
            gradients: report.gradients,
            checkpoint: checkpoint
        )
        return lastTick
    }

    private func adamStep(
        params: ConstitutiveParams,
        gradients: [IdentifiableParameter: Float]
    ) -> ConstitutiveParams {
        adamT += 1
        var next = params.sanitized()
        let eps: Float = 1e-8

        for param in IdentifiableParameter.allCases {
            let g = gradients[param] ?? 0
            guard g.isFinite else { continue }
            // Clip extreme FD gradients.
            let gClip = max(-1e3, min(1e3, g))
            let mPrev = (m[param] ?? 0).isFinite ? (m[param] ?? 0) : 0
            let vPrev = (v[param] ?? 0).isFinite ? (v[param] ?? 0) : 0
            let mT = adamBeta1 * mPrev + (1 - adamBeta1) * gClip
            let vT = adamBeta2 * vPrev + (1 - adamBeta2) * gClip * gClip
            m[param] = mT
            v[param] = vT

            let mHat = mT / (1 - pow(adamBeta1, Float(adamT)))
            let vHat = vT / (1 - pow(adamBeta2, Float(adamT)))
            guard mHat.isFinite, vHat.isFinite else { continue }
            let lr: Float
            switch param {
            case .phiDegrees: lr = learningRatePhi
            case .youngsModulus: lr = learningRateYoungs
            }
            let delta = lr * mHat / (sqrt(max(vHat, 0)) + eps)
            guard delta.isFinite else { continue }
            let theta = param.value(in: next) - delta
            guard theta.isFinite else { continue }
            next = param.applying(theta, to: next)
        }
        return next.sanitized()
    }
}
