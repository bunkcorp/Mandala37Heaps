import Foundation
import simd

/// Drucker–Prager + simple volumetric cap parameters for rice-like granular media.
struct ConstitutiveParams: Equatable, Sendable {
    /// Internal friction angle (degrees).
    var phiDegrees: Float = 34
    /// Cohesion (Pa·normalized; kept small for dry rice).
    var cohesion: Float = 0
    /// Dilatancy angle (degrees).
    var psiDegrees: Float = 0
    /// Young's modulus (Pa), softened for real-time stability.
    var youngsModulus: Float = 3.5e5
    /// Poisson ratio.
    var poisson: Float = 0.2
    /// Cap pressure for compaction under rings (Pa).
    var capPressure: Float = 2.5e4
    /// Rest density (kg/m³).
    var density: Float = 1_400

    var frictionAngle: Float { phiDegrees * .pi / 180 }
    var dilatancyAngle: Float { psiDegrees * .pi / 180 }

    var bulkModulus: Float {
        youngsModulus / (3 * (1 - 2 * poisson))
    }

    var shearModulus: Float {
        youngsModulus / (2 * (1 + poisson))
    }

    /// α = √(2/3) * 2 sinφ / (3 − sinφ) in common sand DP forms.
    var alphaFriction: Float {
        let s = sin(frictionAngle)
        let a = sqrt(2.0 / 3.0) * (2 * s) / max(3 - s, 1e-4)
        return a.isFinite ? a : 0.3
    }

    var isFinite: Bool {
        phiDegrees.isFinite
            && cohesion.isFinite
            && psiDegrees.isFinite
            && youngsModulus.isFinite
            && poisson.isFinite
            && capPressure.isFinite
            && density.isFinite
            && youngsModulus > 0
            && density > 0
    }

    /// Clamp to a realtime-stable rice-like range; replace non-finite with defaults.
    func sanitized() -> ConstitutiveParams {
        guard isFinite else { return .defaultRice }
        var p = self
        p.phiDegrees = min(max(phiDegrees, 18), 48)
        p.cohesion = max(0, cohesion)
        p.psiDegrees = min(max(psiDegrees, 0), 20)
        p.youngsModulus = min(max(youngsModulus, 5e4), 1.0e6)
        p.poisson = min(max(poisson, 0.05), 0.45)
        p.capPressure = min(max(capPressure, 1e3), 1e6)
        p.density = min(max(density, 200), 3000)
        return p
    }

    static let defaultRice = ConstitutiveParams()
}
