import Foundation
import simd

/// 2D Gaussian posterior over constitutive parameters `(φ°, log E)`.
struct ParameterPosteriorState: Equatable, Sendable {
    /// Mean in natural coordinates: x0 = φ (degrees), x1 = log(E).
    var mean: SIMD2<Float> = SIMD2(34, log(3.5e5))
    /// Covariance (2×2, row-major: c00, c01, c10, c11).
    var cov00: Float = 16
    var cov01: Float = 0
    var cov10: Float = 0
    var cov11: Float = 0.25
    var observationCount: Int = 0

    var meanParams: ConstitutiveParams {
        var p = ConstitutiveParams.defaultRice
        p.phiDegrees = mean.x
        p.youngsModulus = exp(mean.y)
        return p
    }

    /// Marginal 1σ on φ (degrees).
    var phiSigma: Float { sqrt(max(cov00, 1e-8)) }

    /// Marginal 1σ on E (Pa), delta-method through exp.
    var youngsSigma: Float {
        let e = exp(mean.y)
        return e * sqrt(max(cov11, 1e-8))
    }

    var hudLine: String {
        String(
            format: "Post φ=%.1f±%.1f°  E=%.2e±%.1e  n=%d",
            Double(mean.x),
            Double(phiSigma),
            Double(exp(mean.y)),
            Double(youngsSigma),
            observationCount
        )
    }

    func jsonDictionary() -> [String: Any] {
        [
            "mean_phi": mean.x,
            "mean_logE": mean.y,
            "mean_E": exp(mean.y),
            "cov": [cov00, cov01, cov10, cov11],
            "phi_sigma": phiSigma,
            "E_sigma": youngsSigma,
            "observationCount": observationCount
        ]
    }

    /// Draw `count` parameter samples (Box–Muller + Cholesky of 2×2 cov).
    func sample(count: Int, rng: inout SeededRNG) -> [ConstitutiveParams] {
        let chol = cholesky2x2()
        var out: [ConstitutiveParams] = []
        out.reserveCapacity(count)
        for _ in 0..<count {
            let z = SIMD2(rng.nextGaussian(), rng.nextGaussian())
            let x = mean + SIMD2(
                chol.0 * z.x,
                chol.1 * z.x + chol.2 * z.y
            )
            var p = ConstitutiveParams.defaultRice
            p.phiDegrees = min(max(x.x, 18), 48)
            p.youngsModulus = min(max(exp(x.y), 5e4), 1.5e6)
            out.append(p)
        }
        return out
    }

    /// Cholesky L such that Σ = L Lᵀ; returns (L00, L10, L11).
    private func cholesky2x2() -> (Float, Float, Float) {
        let a = max(cov00, 1e-8)
        let l00 = sqrt(a)
        let l10 = cov10 / l00
        let l11 = sqrt(max(cov11 - l10 * l10, 1e-8))
        return (l00, l10, l11)
    }
}

/// Tiny deterministic RNG for reproducible posterior draws on-device.
struct SeededRNG: Sendable {
    private var state: UInt64

    init(seed: UInt64 = 0xC0FFEE) {
        state = seed == 0 ? 0xDEADBEEF : seed
    }

    mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func nextFloat() -> Float {
        Float(nextUInt64() >> 40) / Float(1 << 24)
    }

    mutating func nextGaussian() -> Float {
        // Box–Muller
        let u1 = max(nextFloat(), 1e-7)
        let u2 = nextFloat()
        return sqrt(-2 * log(u1)) * cos(2 * Float.pi * u2)
    }
}

/// Online Laplace / Gauss–Newton posterior over `(φ, log E)`.
@MainActor
final class ParameterPosterior {
    private(set) var state = ParameterPosteriorState()

    /// Prior std: φ ~ 6°, log E ~ 0.5.
    var priorPrecisionPhi: Float = 1 / (6 * 6)
    var priorPrecisionLogE: Float = 1 / (0.5 * 0.5)
    /// Observation noise scale on loss-gradient information.
    var gradientNoiseScale: Float = 1.0

    private var fisher00: Float = 0
    private var fisher01: Float = 0
    private var fisher11: Float = 0
    private var infoMean: SIMD2<Float> = .zero
    private var totalWeight: Float = 0

    func reset(to params: ConstitutiveParams = .defaultRice) {
        state = ParameterPosteriorState(
            mean: SIMD2(params.phiDegrees, log(max(params.youngsModulus, 1e3))),
            cov00: 16,
            cov01: 0,
            cov10: 0,
            cov11: 0.25,
            observationCount: 0
        )
        fisher00 = 0
        fisher01 = 0
        fisher11 = 0
        infoMean = .zero
        totalWeight = 0
        recomputeCovariance()
    }

    /// Ingest one Phase-2 FD gradient observation at the current MAP / iterate.
    func observe(
        params: ConstitutiveParams,
        gradients: [IdentifiableParameter: Float],
        loss: Float
    ) {
        let p = params.sanitized()
        guard loss.isFinite,
              gradients.values.allSatisfy(\.isFinite) else { return }

        let gPhi = gradients[.phiDegrees] ?? 0
        // Chain rule: ∂L/∂logE = (∂L/∂E) * E
        let gE = gradients[.youngsModulus] ?? 0
        let e = max(p.youngsModulus, 1e3)
        let gLogE = gE * e
        guard gPhi.isFinite, gLogE.isFinite else { return }

        // Weight: stronger when loss is moderate (informative), weaker when huge/unstable.
        let w = 1 / max(gradientNoiseScale * max(loss, 0.05), 0.05)
        guard w.isFinite else { return }

        fisher00 += w * gPhi * gPhi
        fisher01 += w * gPhi * gLogE
        fisher11 += w * gLogE * gLogE

        let x = SIMD2(p.phiDegrees, log(e))
        // Soft mean tracking toward latest MAP iterate.
        let alpha: Float = 0.35
        if totalWeight <= 0 {
            infoMean = x
        } else {
            infoMean = (1 - alpha) * infoMean + alpha * x
        }
        totalWeight += w
        state.mean = infoMean
        state.observationCount += 1
        recomputeCovariance()
    }

    /// Also allow setting mean from identifier without a gradient (e.g. seed).
    func setMean(from params: ConstitutiveParams) {
        let p = params.sanitized()
        state.mean = SIMD2(p.phiDegrees, log(max(p.youngsModulus, 1e3)))
        recomputeCovariance()
    }

    private func recomputeCovariance() {
        // Precision Λ = Fisher + Prior
        let p00 = fisher00 + priorPrecisionPhi
        let p01 = fisher01
        let p11 = fisher11 + priorPrecisionLogE
        let det = max(p00 * p11 - p01 * p01, 1e-10)
        // Σ = Λ^{-1}
        state.cov00 = p11 / det
        state.cov01 = -p01 / det
        state.cov10 = -p01 / det
        state.cov11 = p00 / det
    }
}
