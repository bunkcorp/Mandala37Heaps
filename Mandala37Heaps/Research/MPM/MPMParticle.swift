import Foundation
import simd

/// CPU-side particle matching `MPMParticle` in `MPMSimulation.metal`.
///
/// Packed as float4s + 9+9 floats so Swift/`SIMD` padding cannot desync Metal.
struct MPMParticle {
    /// xyz = position, w = mass
    var xMass: SIMD4<Float> = .zero
    /// xyz = velocity, w = rest volume
    var vVol: SIMD4<Float> = .zero
    /// Deformation gradient, column-major (9 floats).
    var f0: Float = 1, f1: Float = 0, f2: Float = 0
    var f3: Float = 0, f4: Float = 1, f5: Float = 0
    var f6: Float = 0, f7: Float = 0, f8: Float = 1
    /// APIC affine C, column-major (9 floats).
    var c0: Float = 0, c1: Float = 0, c2: Float = 0
    var c3: Float = 0, c4: Float = 0, c5: Float = 0
    var c6: Float = 0, c7: Float = 0, c8: Float = 0
    /// 0 empty, 1 active, 2 sleeping.
    var state: UInt32 = 0
    /// Plastic volume ratio.
    var jp: Float = 1

    var position: SIMD3<Float> {
        get { SIMD3(xMass.x, xMass.y, xMass.z) }
        set { xMass = SIMD4(newValue.x, newValue.y, newValue.z, xMass.w) }
    }

    var mass: Float {
        get { xMass.w }
        set { xMass.w = newValue }
    }

    var velocity: SIMD3<Float> {
        get { SIMD3(vVol.x, vVol.y, vVol.z) }
        set { vVol = SIMD4(newValue.x, newValue.y, newValue.z, vVol.w) }
    }

    var volume0: Float {
        get { vVol.w }
        set { vVol.w = newValue }
    }

    static var stride: Int { MemoryLayout<MPMParticle>.stride }

    static func active(
        at x: SIMD3<Float>,
        velocity v: SIMD3<Float>,
        mass: Float,
        volume0: Float
    ) -> MPMParticle {
        var p = MPMParticle()
        p.xMass = SIMD4(x.x, x.y, x.z, mass)
        p.vVol = SIMD4(v.x, v.y, v.z, volume0)
        p.state = 1
        p.jp = 1
        return p
    }
}

/// Capsule SDF for kinematic tools / phalanges (tier-local).
struct MPMCapsuleSDF: Equatable, Sendable {
    var p0: SIMD3<Float>
    var p1: SIMD3<Float>
    var radius: Float

    /// Metal buffer element: p0.xyz, radius, p1.xyz, pad
    var packed: (SIMD4<Float>, SIMD4<Float>) {
        (
            SIMD4(p0.x, p0.y, p0.z, radius),
            SIMD4(p1.x, p1.y, p1.z, 0)
        )
    }

    static let inactive = MPMCapsuleSDF(
        p0: SIMD3(0, -10, 0),
        p1: SIMD3(0, -10, 0),
        radius: 0.001
    )
}
