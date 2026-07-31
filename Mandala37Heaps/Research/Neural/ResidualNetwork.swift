import Foundation

/// Minimal multilayer perceptron for on-device residual correction (no Core ML dependency).
struct TinyMLP: Sendable {
    /// Flattened parameters: W0, b0, W1, b1, W2, b2 (row-major weights).
    private var params: [Float]
    private var m: [Float]
    private var v: [Float]
    private var t: Int

    static let inputSize = 6
    static let h1 = 16
    static let h2 = 16
    static let outputSize = 1

    private let sizes: [(Int, Int)] = [
        (inputSize, h1),
        (h1, h2),
        (h2, outputSize)
    ]

    init(seed: UInt64 = 0xA11CE5) {
        var rng = SeededRNG(seed: seed)
        var p: [Float] = []
        for (inN, outN) in [(Self.inputSize, Self.h1), (Self.h1, Self.h2), (Self.h2, Self.outputSize)] {
            let scale = sqrt(2 / Float(inN)) * 0.5
            for _ in 0..<(outN * inN) {
                p.append(rng.nextGaussian() * scale)
            }
            for _ in 0..<outN {
                p.append(0)
            }
        }
        params = p
        m = [Float](repeating: 0, count: p.count)
        v = [Float](repeating: 0, count: p.count)
        t = 0
    }

    func predict(_ x: [Float]) -> Float {
        forward(x).output
    }

    /// Returns final scalar and cached activations for backprop: [x, a1, a2, y].
    private func forward(_ x: [Float]) -> (output: Float, acts: [[Float]]) {
        var acts: [[Float]] = [x]
        var cur = x
        var offset = 0
        for (layerIndex, size) in sizes.enumerated() {
            let (inN, outN) = size
            var z = [Float](repeating: 0, count: outN)
            for o in 0..<outN {
                var s = params[offset + outN * inN + o] // bias after weights
                let row = offset + o * inN
                for i in 0..<inN {
                    s += params[row + i] * cur[i]
                }
                z[o] = s
            }
            offset += outN * inN + outN
            if layerIndex < sizes.count - 1 {
                cur = z.map { tanh($0) }
            } else {
                cur = z
            }
            acts.append(cur)
        }
        return (cur[0], acts)
    }

    /// Adam step minimizing ½(pred − target)². Returns loss.
    mutating func trainStep(x: [Float], target: Float, learningRate: Float = 3e-3) -> Float {
        let (pred, acts) = forward(x)
        let err = pred - target
        let loss = 0.5 * err * err
        guard loss.isFinite, err.isFinite else { return 0 }

        var grads = [Float](repeating: 0, count: params.count)
        var dAct = [err] // dL/da for current layer output

        // Walk layers backward; track param block starts.
        var blockStarts: [Int] = []
        var off = 0
        for (inN, outN) in sizes {
            blockStarts.append(off)
            off += outN * inN + outN
        }

        for li in stride(from: sizes.count - 1, through: 0, by: -1) {
            let (inN, outN) = sizes[li]
            let start = blockStarts[li]
            let xIn = acts[li]
            let yOut = acts[li + 1]

            var dZ = [Float](repeating: 0, count: outN)
            if li == sizes.count - 1 {
                dZ = dAct
            } else {
                for o in 0..<outN {
                    let th = yOut[o]
                    dZ[o] = dAct[o] * (1 - th * th)
                }
            }

            for o in 0..<outN {
                grads[start + outN * inN + o] = dZ[o]
                let row = start + o * inN
                for i in 0..<inN {
                    grads[row + i] = dZ[o] * xIn[i]
                }
            }

            var dPrev = [Float](repeating: 0, count: inN)
            for i in 0..<inN {
                var s: Float = 0
                for o in 0..<outN {
                    s += params[start + o * inN + i] * dZ[o]
                }
                dPrev[i] = s
            }
            dAct = dPrev
        }

        t += 1
        let beta1: Float = 0.9
        let beta2: Float = 0.999
        let eps: Float = 1e-8
        for i in 0..<params.count {
            let g = grads[i]
            guard g.isFinite else { continue }
            m[i] = beta1 * m[i] + (1 - beta1) * g
            v[i] = beta2 * v[i] + (1 - beta2) * g * g
            let mHat = m[i] / (1 - pow(beta1, Float(t)))
            let vHat = v[i] / (1 - pow(beta2, Float(t)))
            let step = learningRate * mHat / (sqrt(max(vHat, 0)) + eps)
            if step.isFinite {
                params[i] -= step
            }
        }
        return loss
    }
}
