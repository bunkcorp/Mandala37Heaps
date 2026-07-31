import Foundation
import simd

/// Runtime conservation / contact diagnostics for the MPM active region.
struct ConservationSnapshot: Equatable, Sendable {
    var frame: UInt64 = 0
    var activeParticles: Int = 0
    var sleepingParticles: Int = 0
    var gridNodes: Int = 0
    var totalMass: Float = 0
    var referenceMass: Float = 0
    /// Relative mass drift |m − m0| / max(m0, ε).
    var massDrift: Float = 0
    var momentum: SIMD3<Float> = .zero
    /// ‖Σp − ∫F_ext dt‖ proxy (gravity + contact impulse integral residual).
    var momentumResidual: Float = 0
    var maxPenetration: Float = 0
    var yieldViolations: Int = 0
    var ringContactImpulse: SIMD3<Float> = .zero
    var constitutive: ConstitutiveParams = .defaultRice

    var summaryLine: String {
        String(
            format: "MPM n=%d/%d  Δm=%.2e  |p|=%.2e  pen=%.1fmm  yield=%d",
            activeParticles,
            activeParticles + sleepingParticles,
            Double(massDrift),
            Double(momentumResidual),
            Double(maxPenetration * 1000),
            yieldViolations
        )
    }

    func jsonDictionary() -> [String: Any] {
        [
            "frame": frame,
            "activeParticles": activeParticles,
            "sleepingParticles": sleepingParticles,
            "gridNodes": gridNodes,
            "totalMass": totalMass,
            "referenceMass": referenceMass,
            "massDrift": massDrift,
            "momentum": [momentum.x, momentum.y, momentum.z],
            "momentumResidual": momentumResidual,
            "maxPenetration": maxPenetration,
            "yieldViolations": yieldViolations,
            "ringContactImpulse": [
                ringContactImpulse.x,
                ringContactImpulse.y,
                ringContactImpulse.z
            ],
            "phi_deg": constitutive.phiDegrees,
            "cohesion": constitutive.cohesion,
            "psi_deg": constitutive.psiDegrees,
            "density": constitutive.density
        ]
    }
}

/// Accumulates GPU diagnostic reads into conservation residuals.
@MainActor
final class ConservationProbe {
    private(set) var latest = ConservationSnapshot()
    private var referenceMass: Float = 0
    private var externalImpulseIntegral: SIMD3<Float> = .zero
    private var previousMomentum: SIMD3<Float> = .zero
    private var gravityImpulseIntegral: SIMD3<Float> = .zero

    func reset() {
        latest = ConservationSnapshot()
        referenceMass = 0
        externalImpulseIntegral = .zero
        previousMomentum = .zero
        gravityImpulseIntegral = .zero
    }

    func ingest(
        frame: UInt64,
        active: UInt32,
        sleeping: UInt32,
        mass: Float,
        momentum: SIMD3<Float>,
        maxPenetration: Float,
        yieldViolations: UInt32,
        ringImpulse: SIMD3<Float>,
        dt: Float,
        gravityY: Float,
        gridNodes: Int,
        constitutive: ConstitutiveParams
    ) {
        if referenceMass <= 0, mass > 0 {
            referenceMass = mass
        } else if mass > referenceMass {
            // Pour added mass — rebase reference.
            referenceMass = mass
        }

        let safeMass = mass.isFinite ? max(mass, 0) : 0
        let safeMom = SIMD3(
            momentum.x.isFinite ? momentum.x : 0,
            momentum.y.isFinite ? momentum.y : 0,
            momentum.z.isFinite ? momentum.z : 0
        )
        let safeImpulse = SIMD3(
            ringImpulse.x.isFinite ? ringImpulse.x : 0,
            ringImpulse.y.isFinite ? ringImpulse.y : 0,
            ringImpulse.z.isFinite ? ringImpulse.z : 0
        )
        let safePen = maxPenetration.isFinite ? max(0, maxPenetration) : 0

        externalImpulseIntegral += safeImpulse
        gravityImpulseIntegral += SIMD3(0, safeMass * gravityY * dt, 0)

        // Residual vs previous step + gravity + ring reaction (contact acts on material).
        let expected = previousMomentum + SIMD3(0, safeMass * gravityY * dt, 0) - safeImpulse
        var residual = length(safeMom - expected)
        if !residual.isFinite { residual = 0 }
        previousMomentum = safeMom

        let drift: Float
        if referenceMass > 1e-8 {
            drift = abs(safeMass - referenceMass) / referenceMass
        } else {
            drift = 0
        }

        latest = ConservationSnapshot(
            frame: frame,
            activeParticles: Int(active),
            sleepingParticles: Int(sleeping),
            gridNodes: gridNodes,
            totalMass: safeMass,
            referenceMass: referenceMass,
            massDrift: drift.isFinite ? drift : 0,
            momentum: safeMom,
            momentumResidual: residual,
            maxPenetration: min(safePen, 0.05),
            yieldViolations: Int(yieldViolations),
            ringContactImpulse: safeImpulse,
            constitutive: constitutive.sanitized()
        )
    }
}
