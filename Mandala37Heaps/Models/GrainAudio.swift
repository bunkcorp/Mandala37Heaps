import AVFoundation
import Foundation

/// Procedural grain audio — no sample assets required.
@MainActor
final class GrainAudio {
    static let shared = GrainAudio()

    private let engine = AVAudioEngine()
    private let pourNode = AVAudioPlayerNode()
    private let thudNode = AVAudioPlayerNode()
    private var pourBuffer: AVAudioPCMBuffer?
    private var settleBuffer: AVAudioPCMBuffer?
    private var ringBuffer: AVAudioPCMBuffer?
    private var isReady = false
    private var isEnabled = true
    private var lastPourTime: TimeInterval = 0
    private var lastSettleTime: TimeInterval = 0

    func prepare() {
        guard !isReady else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, options: [.mixWithOthers])
        try? session.setActive(true)

        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        pourBuffer = Self.makeNoiseBurst(
            format: format,
            duration: 0.55,
            amplitude: 0.22,
            highPassBias: 0.65
        )
        settleBuffer = Self.makeNoiseBurst(
            format: format,
            duration: 0.28,
            amplitude: 0.14,
            highPassBias: 0.35
        )
        ringBuffer = Self.makeThud(
            format: format,
            duration: 0.35,
            amplitude: 0.28
        )

        engine.attach(pourNode)
        engine.attach(thudNode)
        engine.connect(pourNode, to: engine.mainMixerNode, format: format)
        engine.connect(thudNode, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.85
        try? engine.start()
        isReady = true
    }

    /// Mute and flush scheduled grain buffers (e.g. after mandala completion).
    func stopAll() {
        isEnabled = false
        pourNode.stop()
        thudNode.stop()
        engine.mainMixerNode.outputVolume = 0
    }

    func resume() {
        isEnabled = true
        if isReady {
            engine.mainMixerNode.outputVolume = 0.85
            try? engine.start()
        } else {
            prepare()
        }
    }

    func playPour(intensity: Float = 1) {
        guard isEnabled else { return }
        prepare()
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPourTime > 0.12 else { return }
        lastPourTime = now
        guard let pourBuffer else { return }
        pourNode.stop()
        pourNode.volume = min(1, max(0.25, intensity))
        pourNode.scheduleBuffer(pourBuffer, at: nil, options: [], completionHandler: nil)
        if !pourNode.isPlaying { pourNode.play() }
    }

    func playSettle(intensity: Float = 0.7) {
        guard isEnabled else { return }
        prepare()
        let now = ProcessInfo.processInfo.systemUptime
        // Avoid stacking settle buffers into a continuous hiss.
        guard now - lastSettleTime > 0.35 else { return }
        lastSettleTime = now
        guard let settleBuffer else { return }
        pourNode.volume = min(1, max(0.15, intensity * 0.6))
        pourNode.scheduleBuffer(settleBuffer, at: nil, options: [], completionHandler: nil)
        if !pourNode.isPlaying { pourNode.play() }
    }

    func playRingPress() {
        guard isEnabled else { return }
        prepare()
        guard let ringBuffer else { return }
        thudNode.stop()
        thudNode.volume = 1
        thudNode.scheduleBuffer(ringBuffer, at: nil, options: [], completionHandler: nil)
        if !thudNode.isPlaying { thudNode.play() }
        // Soft grain cascade after the thud.
        playSettle(intensity: 0.9)
    }

    // MARK: - Synthesis

    private static func makeNoiseBurst(
        format: AVAudioFormat,
        duration: Double,
        amplitude: Float,
        highPassBias: Float
    ) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(duration * format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        guard let data = buffer.floatChannelData?[0] else { return nil }

        var prev: Float = 0
        let hp = min(0.95, max(0.05, highPassBias))
        for i in 0..<Int(frames) {
            let t = Float(i) / Float(frames)
            let env = sin(Float.pi * min(1, t * 1.15)) * (1 - t * 0.55)
            let white = Float.random(in: -1...1)
            // Cheap high-pass-ish crackle for rice.
            let filtered = white - prev * hp
            prev = white
            // Occasional louder clicks.
            let click: Float = (Float.random(in: 0...1) < 0.02) ? Float.random(in: 0.4...1) : 0
            data[i] = (filtered * 0.7 + click * white) * amplitude * env
        }
        return buffer
    }

    private static func makeThud(
        format: AVAudioFormat,
        duration: Double,
        amplitude: Float
    ) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(duration * format.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        guard let data = buffer.floatChannelData?[0] else { return nil }
        let sr = Float(format.sampleRate)
        for i in 0..<Int(frames) {
            let t = Float(i) / sr
            let env = exp(-t * 9)
            let tone = sin(2 * Float.pi * (90 + t * 40) * t) * 0.55
            let body = sin(2 * Float.pi * 48 * t) * 0.85
            let grit = Float.random(in: -0.2...0.2) * exp(-t * 18)
            data[i] = (tone + body + grit) * amplitude * env
        }
        return buffer
    }
}
