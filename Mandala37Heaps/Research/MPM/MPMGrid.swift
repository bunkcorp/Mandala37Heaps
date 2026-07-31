import Foundation
import simd

/// Background Eulerian grid for one-tier active-region MLS/APIC-MPM.
struct MPMGridConfig: Equatable, Sendable {
    /// Grid resolution (includes ghost padding).
    var nx: Int
    var ny: Int
    var nz: Int
    /// Cell size (m).
    var dx: Float
    /// World/tier-local origin of cell (0,0,0) corner.
    var origin: SIMD3<Float>

    var nodeCount: Int { nx * ny * nz }

    /// Preferred layout for a mandala tier deck.
    static func forTier(_ tier: MandalaTier) -> MPMGridConfig {
        let nx = 40
        let ny = 16
        let nz = 40
        let margin: Float = 0.02
        let extentXZ = tier.fillRadius * 2 + margin * 2
        let extentY = tier.ringHeight + margin
        let dx = max(extentXZ / Float(nx - 4), extentY / Float(ny - 4), 0.004)
        let origin = SIMD3(
            -Float(nx) * dx * 0.5,
            -dx,
            -Float(nz) * dx * 0.5
        )
        return MPMGridConfig(nx: nx, ny: ny, nz: nz, dx: dx, origin: origin)
    }

    func clampParticle(to x: SIMD3<Float>) -> SIMD3<Float> {
        let minB = origin + SIMD3(repeating: dx * 1.5)
        let maxB = origin + SIMD3(
            Float(nx - 2) * dx,
            Float(ny - 2) * dx,
            Float(nz - 2) * dx
        )
        return SIMD3(
            min(max(x.x, minB.x), maxB.x),
            min(max(x.y, minB.y), maxB.y),
            min(max(x.z, minB.z), maxB.z)
        )
    }
}

/// Must match `MPMUniforms` in Metal field-for-field.
struct MPMUniforms {
    var dt: Float
    var dx: Float
    var invDx: Float
    var gravityY: Float
    var originX: Float
    var originY: Float
    var originZ: Float
    var fillRadius: Float
    var plateY: Float
    var maxHeight: Float
    var nx: UInt32
    var ny: UInt32
    var nz: UInt32
    var particleCount: UInt32
    var density: Float
    var youngs: Float
    var poisson: Float
    var alphaFriction: Float
    var cohesion: Float
    var capPressure: Float
    var sleepDepth: Float
    var capsuleCount: UInt32
}
