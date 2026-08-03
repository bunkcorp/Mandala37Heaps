import CoreGraphics
import Metal
import RealityKit
import UIKit

/// Animated Mandelbrot zoom textures for offering heaps (Seahorse Valley style).
@MainActor
final class HeapFractalAnimator {
    private struct Slot {
        let heapNumber: Int
        /// Unique orbit center near Seahorse Valley.
        let center: SIMD2<Double>
        /// Phase offset so neighboring heaps aren't identical.
        let phase: Double
        /// Hue twist for palette variety.
        let hueShift: Float
        weak var shell: ModelEntity?
        var texture: TextureResource?
        var zoom: Double
        /// Time until next discrete zoom step.
        var stepAccum: Double
    }

    private var slots: [Int: Slot] = [:]
    private var time: Double = 0
    /// Balanced for snappy stepping on every heap.
    private let resolution = 144
    private let maxIter = 140
    /// Discrete zoom jump per step (clear “iteration” through the set).
    private let zoomStep: Double = 0.70
    /// How often each heap advances (~14 steps/sec).
    private let stepInterval: Double = 0.07
    private let minZoom: Double = 3e-5
    private let maxZoom: Double = 2.4
    /// Base Seahorse Valley focus (classic deep zoom locus).
    private let valley = SIMD2<Double>(-0.743643887037151, 0.131825904205330)

    private var textureOptions: TextureResource.CreateOptions {
        // No mipmaps — mips were washing out Mandelbrot edge detail on the dome.
        .init(semantic: .color, mipmapsMode: .none)
    }

    func attach(to heap: Entity, heapNumber: Int) {
        guard let shell = heap.findEntity(named: "FractalShell") as? ModelEntity else { return }
        let jitter = Double((heapNumber &* 2654435761) & 0xffff) / 65535.0
        let angle = Double(heapNumber) * 1.6180339887
        let center = valley + SIMD2(
            cos(angle) * 0.0008 * (0.4 + jitter),
            sin(angle * 1.3) * 0.0008 * (0.4 + jitter)
        )
        var slot = Slot(
            heapNumber: heapNumber,
            center: center,
            phase: Double(heapNumber) * 0.37,
            hueShift: Float(heapNumber % 12) / 12,
            shell: shell,
            texture: nil,
            zoom: maxZoom * pow(0.55, jitter * 3),
            // Stagger first step so heaps don't hitch in lockstep.
            stepAccum: Double(heapNumber % 7) * (stepInterval / 7)
        )
        if let image = renderFrame(center: slot.center, scale: slot.zoom, hueShift: slot.hueShift),
           let texture = try? TextureResource.generate(from: image, options: textureOptions) {
            slot.texture = texture
            apply(texture: texture, to: shell)
        }
        slots[heapNumber] = slot
    }

    func detach(heapNumber: Int) {
        slots.removeValue(forKey: heapNumber)
    }

    func reset() {
        slots.removeAll()
        time = 0
    }

    /// Advance zoom and refresh heap textures — fast discrete steps on every mound.
    func tick(dt: Float) {
        time += Double(dt)
        guard !slots.isEmpty else { return }

        let keys = slots.keys.sorted()
        for key in keys {
            guard var slot = slots[key], let shell = slot.shell else {
                slots.removeValue(forKey: key)
                continue
            }
            slot.stepAccum += Double(dt)
            guard slot.stepAccum >= stepInterval else {
                slots[key] = slot
                continue
            }
            slot.stepAccum = 0

            // Big discrete zoom jump so the fractal clearly steps through.
            slot.zoom *= zoomStep
            if slot.zoom < minZoom {
                slot.zoom = maxZoom
            }
            if let image = renderFrame(center: slot.center, scale: slot.zoom, hueShift: slot.hueShift) {
                if let existing = slot.texture {
                    do {
                        try existing.replace(withImage: image, options: textureOptions)
                        apply(texture: existing, to: shell)
                    } catch {
                        if let fresh = try? TextureResource.generate(from: image, options: textureOptions) {
                            slot.texture = fresh
                            apply(texture: fresh, to: shell)
                        }
                    }
                } else if let fresh = try? TextureResource.generate(from: image, options: textureOptions) {
                    slot.texture = fresh
                    apply(texture: fresh, to: shell)
                }
            }
            slots[key] = slot
        }
    }

    private func apply(texture: TextureResource, to shell: ModelEntity) {
        var mat = UnlitMaterial()
        let desc = MTLSamplerDescriptor()
        desc.minFilter = .linear
        desc.magFilter = .linear
        desc.mipFilter = .notMipmapped
        desc.sAddressMode = .clampToEdge
        desc.tAddressMode = .clampToEdge
        let sampler = MaterialParameters.Texture.Sampler(desc)
        mat.color = .init(texture: .init(texture, sampler: sampler))
        shell.model?.materials = [mat]
    }

    /// Mandelbrot escape-time image with Seahorse Valley palette (burgundy → cyan/gold → black).
    private func renderFrame(center: SIMD2<Double>, scale: Double, hueShift: Float) -> CGImage? {
        let w = resolution
        let h = resolution
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let aspect = Double(w) / Double(h)

        for y in 0..<h {
            let v = (Double(y) + 0.5) / Double(h)
            let imag = center.y + (v - 0.5) * scale
            for x in 0..<w {
                let u = (Double(x) + 0.5) / Double(w)
                let real = center.x + (u - 0.5) * scale * aspect
                let color = escapeColor(
                    cReal: real,
                    cImag: imag,
                    hueShift: hueShift
                )
                let i = (y * w + x) * 4
                pixels[i] = color.0
                pixels[i + 1] = color.1
                pixels[i + 2] = color.2
                pixels[i + 3] = 255
            }
        }

        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: w,
            height: h,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private func escapeColor(cReal: Double, cImag: Double, hueShift: Float) -> (UInt8, UInt8, UInt8) {
        var zr = 0.0
        var zi = 0.0
        var iter = 0
        while iter < maxIter {
            let zr2 = zr * zr
            let zi2 = zi * zi
            if zr2 + zi2 > 4 {
                // Smooth iteration for richer banding.
                let logZn = log(zr2 + zi2) / 2
                let nu = log(logZn / log(2)) / log(2)
                let t = (Double(iter) + 1 - nu) / Double(maxIter)
                return palette(t: max(0, min(1, t)), hueShift: hueShift)
            }
            zi = 2 * zr * zi + cImag
            zr = zr2 - zi2 + cReal
            iter += 1
        }
        // Interior — deep burgundy / black like the reference.
        return (28, 4, 12)
    }

    /// Burgundy core → cyan/white filaments → gold tips → black outer (reference look).
    private func palette(t: Double, hueShift: Float) -> (UInt8, UInt8, UInt8) {
        let shifted = (t + Double(hueShift) * 0.15).truncatingRemainder(dividingBy: 1)
        let stops: [(Double, SIMD3<Double>)] = [
            (0.00, SIMD3(0.45, 0.05, 0.10)), // burgundy
            (0.18, SIMD3(0.70, 0.12, 0.18)),
            (0.35, SIMD3(0.15, 0.55, 0.85)), // cyan-blue
            (0.55, SIMD3(0.55, 0.90, 1.00)), // pale cyan
            (0.72, SIMD3(1.00, 0.85, 0.25)), // gold
            (0.88, SIMD3(0.20, 0.08, 0.05)),
            (1.00, SIMD3(0.02, 0.02, 0.03))  // near black
        ]
        var a = stops[0]
        var b = stops[1]
        for i in 0..<(stops.count - 1) {
            if shifted >= stops[i].0 && shifted <= stops[i + 1].0 {
                a = stops[i]
                b = stops[i + 1]
                break
            }
        }
        let span = max(1e-6, b.0 - a.0)
        let u = (shifted - a.0) / span
        let c = a.1 + (b.1 - a.1) * u
        return (
            UInt8(min(255, max(0, c.x * 255))),
            UInt8(min(255, max(0, c.y * 255))),
            UInt8(min(255, max(0, c.z * 255)))
        )
    }
}
