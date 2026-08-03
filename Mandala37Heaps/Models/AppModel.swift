import Foundation
import Observation
import QuartzCore
import RealityKit
import UIKit

enum ViewState {
    case portal
    case immersive
}

enum ImmersiveSpaceState {
    case closed
    case inTransition
    case open
}

@Observable
@MainActor
final class AppModel {
    var viewState: ViewState = .portal
    var immersiveSpaceState: ImmersiveSpaceState = .closed
    var playMode: PlayMode = .guided
    var selectedMaterial: HeapMaterialKind = .gold
    var filledCount: Int = 0
    var isComplete: Bool = false
    var unlockedTier: MandalaTier = .universe
    var statusMessage: String = "Level 1 · Tap the glowing beacon for Mount Meru."
    var isMandalaBuilt = false
    var isAutoPlaying = false
    var didProcessDebugLaunchArguments = false
    var didRunDebugGameplay = false
    /// Dual-solver: DEM baseline or MPM active-region continuum (default MPM for research stack).
    var solverMode: SolverMode = .mpmActive
    /// Latest conservation / contact diagnostics (MPM path).
    var diagnosticsHUD: String = "Solver: MPM"
    var showDiagnosticsHUD: Bool = false
    /// Phase 2 online constitutive identification (FD Adam).
    var isIdentifying: Bool = false
    var identificationHUD: String = "ID idle"
    /// Phase 3 Bayesian posterior + surface uncertainty bands.
    var showUncertaintyBands: Bool = true
    var posteriorHUD: String = "Post idle"
    var surfaceUncertaintyHUD: String = "Surf σ idle"
    /// Phase 4 adaptive multiresolution.
    var isAdaptivityEnabled: Bool = true
    var showAdaptivityHeatmap: Bool = false
    var adaptivityHUD: String = "Adapt idle"
    /// Phase 5 physics-constrained neural residual.
    var isNeuralResidualEnabled: Bool = true
    var showNeuralResidualSurface: Bool = true
    var neuralResidualHUD: String = "Neural residual idle"

    let mandalaRoot = Entity()

    private var slotEntities: [Entity] = []
    private var heapEntities: [Entity?] = Array(repeating: nil, count: 37)
    private var filled: [Bool] = Array(repeating: false, count: 37)
    private var tierRoots: [MandalaTier: Entity] = [:]
    private var tierSlotsParents: [MandalaTier: Entity] = [:]
    private var paletteRoot = Entity()
    private var crownEntity: Entity?
    private var celebrationEntity: Entity?
    private var pulseTask: Task<Void, Never>?
    private var highlightPulseTask: Task<Void, Never>?
    private var autoPlayTask: Task<Void, Never>?
    private var grainSimTask: Task<Void, Never>?
    private var grainSims: [MandalaTier: GrainGPUSimulator] = [:]
    private var mpmSims: [MandalaTier: MPMSimulator] = [:]
    private let parameterIdentifier = ParameterIdentifier()
    private let parameterPosterior = ParameterPosterior()
    private var surfaceUncertainty: SurfaceUncertaintyEngine?
    private var uncertaintyVisualizers: [MandalaTier: UncertaintyBandVisualizer] = [:]
    private var uncertaintyFrameCounter: Int = 0
    private let adaptivityController = AdaptiveResolutionController()
    private var adaptivityVisualizers: [MandalaTier: AdaptivityVisualizer] = [:]
    private let neuralResidual = PhysicsConstrainedResidualCorrector()
    private var neuralVisualizers: [MandalaTier: ResidualSurfaceVisualizer] = [:]
    /// Continuous slow spin angle (radians) for each metal ring.
    private var ringSpinAngles: [MandalaTier: Float] = [:]
    /// ~one revolution per 55s; sign alternates CW / CCW per tier.
    private let ringSpinSpeed: Float = (.pi * 2) / 55
    /// Shared clock for subtle heap idle motion.
    private var heapIdleTime: Float = 0
    /// Previous bob height per heap — used to detect bounce landings.
    private var heapPrevBob: [Float] = Array(repeating: 0, count: 37)
    /// Cooldown so each heap doesn’t spark every frame.
    private var heapBounceCooldown: [Float] = Array(repeating: 0, count: 37)
    /// Active bounce pulse strength 0…1 per heap.
    private var heapBouncePulse: [Float] = Array(repeating: 0, count: 37)
    private let heapFractals = HeapFractalAnimator()
    let ritualTool = RitualToolTracker()

    var nextGuidedIndex: Int? {
        filled.firstIndex(of: false)
    }

    var progressLabel: String {
        if isComplete {
            return "Mandala Complete — centerpiece placed"
        }
        return "\(unlockedTier.title) · Heap \(filledCount + 1) of 37"
    }

    var nextHeapName: String? {
        guard let index = nextGuidedIndex else { return nil }
        return HeapDefinition.all[index].name
    }

    func prepareMandalaIfNeeded() {
        guard !isMandalaBuilt else { return }
        buildMandala()
        isMandalaBuilt = true
        refreshHighlights()
        rebuildPalette()
        updateStatus()
        GrainAudio.shared.prepare()
        ritualTool.attach(to: mandalaRoot)
        ritualTool.startHandTracking()
        startGrainSimulationLoop()
        applyPreferredResearchDefaults()
    }

    /// Preferred research stack at launch / reset: MPM + Adapt + σ + Neural + δh + Target/Teacher.
    private func applyPreferredResearchDefaults() {
        solverMode = .mpmActive
        for tier in MandalaTier.allCases {
            mpmSims[tier]?.setEnabled(true)
        }
        setAdaptivityEnabled(true)
        setUncertaintyBandsVisible(true)
        setNeuralResidualEnabled(true)
        setNeuralResidualSurfaceVisible(true)
        // Live target if particles exist; synthetic teacher ensures a usable ID target either way.
        captureIdentificationTarget()
        captureSyntheticTeacherTarget()
        refreshDiagnosticsHUD()
    }

    /// Per-frame Metal grain integrate / deposit / height-field relax (and optional MPM).
    func startGrainSimulationLoop() {
        grainSimTask?.cancel()
        grainSimTask = Task { @MainActor in
            var last = CACurrentMediaTime()
            while !Task.isCancelled {
                let now = CACurrentMediaTime()
                let dt = Float(now - last)
                last = now
                let step = min(max(dt, 1 / 240), 1 / 30)
                for tier in MandalaTier.allCases {
                    guard tier.rawValue <= unlockedTier.rawValue else { continue }
                    if let tierRoot = tierRoots[tier] {
                        let capsules = ritualTool.contactCapsules(in: tierRoot)
                        if solverMode == .mpmActive {
                            mpmSims[tier]?.setContactCapsules(capsules)
                        }
                        if let toolLocal = ritualTool.toolPosition(in: tierRoot) {
                            grainSims[tier]?.disturbWithTool(at: toolLocal)
                        }
                    }
                    switch solverMode {
                    case .dem:
                        grainSims[tier]?.step(dt: step)
                    case .mpmActive:
                        // DEM height field stays as bulk backdrop; MPM owns active pour/contact.
                        mpmSims[tier]?.step(dt: step)
                        grainSims[tier]?.step(dt: step)
                        if tier == unlockedTier,
                           let live = mpmSims[tier],
                           let tierRoot = tierRoots[tier] {
                            let capsules = ritualTool.contactCapsules(in: tierRoot)
                            // Recover if a previous ID step poisoned constitutive params.
                            if !live.constitutive.isFinite {
                                live.setConstitutive(.defaultRice)
                                parameterIdentifier.seedParams(.defaultRice)
                                parameterPosterior.reset(to: .defaultRice)
                            }
                            if isIdentifying {
                                let tick = parameterIdentifier.tick(live: live, capsules: capsules)
                                if tick.didUpdate, tick.params.isFinite, tick.loss.isFinite {
                                    parameterPosterior.observe(
                                        params: tick.params,
                                        gradients: tick.gradients,
                                        loss: tick.loss
                                    )
                                    maybeUpdateSurfaceUncertainty(
                                        live: live,
                                        capsules: capsules,
                                        checkpoint: tick.checkpoint
                                    )
                                }
                            } else if showUncertaintyBands {
                                maybeUpdateSurfaceUncertainty(
                                    live: live,
                                    capsules: capsules,
                                    checkpoint: nil
                                )
                            }
                            if isAdaptivityEnabled || showAdaptivityHeatmap {
                                let stats = adaptivityController.tick(
                                    sim: live,
                                    capsules: capsules,
                                    applyAdaptation: isAdaptivityEnabled
                                )
                                if showAdaptivityHeatmap {
                                    ensureAdaptivityVisualizer(for: tier)
                                    adaptivityVisualizers[tier]?.update(with: stats.field)
                                    adaptivityVisualizers[tier]?.setEnabled(true)
                                }
                                adaptivityHUD = stats.hudLine
                            }
                            if isNeuralResidualEnabled || showNeuralResidualSurface {
                                let demH = grainSims[tier]?.sampleHeightFieldMeters()
                                let nStats = neuralResidual.tick(
                                    mpm: live,
                                    demHeights: demH,
                                    params: live.constitutive,
                                    fillRadius: tier.fillRadius,
                                    maxHeight: tier.ringHeight
                                )
                                neuralResidualHUD = nStats.hudLine
                                if showNeuralResidualSurface {
                                    ensureNeuralVisualizer(for: tier)
                                    neuralVisualizers[tier]?.update(
                                        heights: neuralResidual.correctedHeights,
                                        resolution: PhysicsConstrainedResidualCorrector.resolution,
                                        fillRadius: tier.fillRadius
                                    )
                                    neuralVisualizers[tier]?.setEnabled(true)
                                }
                            }
                        }
                    }
                }
                updateRingSpins(dt: step)
                updateHeapIdles(dt: step)
                heapFractals.tick(dt: step)
                refreshDiagnosticsHUD()
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    /// Slow continuous Y-spin on each unlocked metal ring; adjacent tiers reverse direction.
    private func updateRingSpins(dt: Float) {
        let clamped = min(max(dt, 0), 0.05)
        for tier in MandalaTier.allCases {
            guard tier.rawValue <= unlockedTier.rawValue,
                  let root = tierRoots[tier],
                  root.isEnabled,
                  let ring = root.findEntity(named: "MetalRing") else { continue }
            // Even tiers: clockwise (−Y); odd tiers: counterclockwise (+Y).
            let direction: Float = tier.rawValue % 2 == 0 ? -1 : 1
            let next = (ringSpinAngles[tier] ?? 0) + direction * ringSpinSpeed * clamped
            // Keep angle bounded for numerical comfort.
            var wrapped = next.truncatingRemainder(dividingBy: .pi * 2)
            if wrapped < 0 { wrapped += .pi * 2 }
            ringSpinAngles[tier] = wrapped
            ring.orientation = simd_quatf(angle: wrapped, axis: SIMD3(0, 1, 0))
        }
    }

    /// Soft bob / sway / breathe on placed heaps, with rainbow glow + shake/spin on land.
    private func updateHeapIdles(dt: Float) {
        let clamped = min(max(dt, 0), 0.05)
        heapIdleTime += clamped
        let baseY: Float = 0.005
        for (index, optionalHeap) in heapEntities.enumerated() {
            guard let heap = optionalHeap, heap.parent != nil else { continue }
            // Skip while the place-grow animation is still scaling up.
            let scaleY = heap.scale.y
            guard scaleY > 0.85 else { continue }

            let phase = Float(index) * 0.73
            let t = heapIdleTime
            let bob = sin(t * 1.35 + phase) * 0.0018
            let sway = sin(t * 0.95 + phase * 1.3) * 0.035
            let tip = cos(t * 1.1 + phase * 0.8) * 0.018
            let breathe = 1 + sin(t * 1.6 + phase * 1.1) * 0.012

            // Detect bounce landing: rising through the trough of the bob.
            let prev = heapPrevBob[index]
            heapPrevBob[index] = bob
            heapBounceCooldown[index] = max(0, heapBounceCooldown[index] - clamped)
            if bob < -0.0010, bob > prev, heapBounceCooldown[index] <= 0 {
                heapBouncePulse[index] = 1
                heapBounceCooldown[index] = 0.55
            }

            // Decay pulse and drive aura visuals.
            if heapBouncePulse[index] > 0 {
                heapBouncePulse[index] = max(0, heapBouncePulse[index] - clamped * 1.6)
            }
            let p = heapBouncePulse[index]

            // Soft land motion — keep it small so mounds stay inside the ring walls.
            let shakeAmp = p * p
            let shakeX = sin(t * 48 + phase * 9) * 0.0012 * shakeAmp
            let shakeZ = cos(t * 41 + phase * 7) * 0.0012 * shakeAmp
            let shakeY = abs(sin(t * 55 + phase)) * 0.0010 * shakeAmp

            let spinYaw = sway * 0.45 + sin(t * 22 + phase) * 0.18 * shakeAmp
            let spinPitch = tip * 0.45 + sin(t * 31 + phase * 1.4) * 0.10 * shakeAmp
            let spinRoll = cos(t * 27 + phase * 0.7) * 0.12 * shakeAmp

            heap.position = SIMD3(shakeX, baseY + bob + shakeY, shakeZ)
            heap.orientation =
                simd_quatf(angle: spinYaw, axis: SIMD3(0, 1, 0)) *
                simd_quatf(angle: spinPitch, axis: SIMD3(1, 0, 0)) *
                simd_quatf(angle: spinRoll, axis: SIMD3(0, 0, 1))
            let squash = 1 - 0.05 * shakeAmp
            let stretch = 1 + 0.04 * shakeAmp
            heap.scale = SIMD3(breathe * stretch, breathe * squash, breathe * stretch)

            updateHeapBounceAura(on: heap, index: index, pulse: p, time: t)
        }
    }

    private func updateHeapBounceAura(on heap: Entity, index: Int, pulse: Float, time: Float) {
        guard let aura = heap.findEntity(named: "HeapBounceAura") else { return }
        let p = max(0, min(1, pulse))

        if let glow = aura.findEntity(named: "BounceGlow") {
            // Keep glow smaller than the mound so it never spills past the ring wall.
            let s = 0.22 + p * 0.28
            glow.scale = SIMD3(s, 0.10, s)
            glow.position = SIMD3(0, 0.004, 0)
            glow.isEnabled = p > 0.04
            if let model = glow as? ModelEntity {
                let alpha = CGFloat(0.15 + p * 0.45)
                let hue = CGFloat((time * 0.35 + Float(index) * 0.11).truncatingRemainder(dividingBy: 1))
                model.model?.materials = [
                    UnlitMaterial(color: UIColor(hue: hue, saturation: 0.75, brightness: 1, alpha: alpha))
                ]
            }
        }

        if let lightAnchor = aura.findEntity(named: "BounceLight"),
           var light = lightAnchor.components[PointLightComponent.self] {
            let hue = CGFloat((time * 0.4 + Float(index) * 0.13).truncatingRemainder(dividingBy: 1))
            light.color = UIColor(hue: hue, saturation: 0.65, brightness: 1, alpha: 1)
            light.intensity = p > 0.04 ? (80 + p * 600) : 0
            light.attenuationRadius = 0.12 + p * 0.18
            lightAnchor.components.set(light)
            lightAnchor.position = SIMD3(0, 0.03 + p * 0.03, 0)
        }

        if let sparks = aura.findEntity(named: "BounceSparks") {
            let children = Array(sparks.children)
            for (i, spark) in children.enumerated() {
                let angle = Float(i) * (.pi * 2 / Float(max(1, children.count))) + time * 0.8
                let rise = p * (0.015 + Float(i % 4) * 0.008)
                let radial = 0.008 + p * (0.012 + Float(i % 3) * 0.004)
                spark.position = SIMD3(cos(angle) * radial, 0.008 + rise, sin(angle) * radial)
                spark.scale = SIMD3(repeating: p * (0.45 + Float(i % 3) * 0.15))
            }
        }

        if let arcs = aura.findEntity(named: "BounceArcs") {
            let children = Array(arcs.children)
            for (i, arc) in children.enumerated() {
                let angle = Float(i) * (.pi / 3) + time * 0.5
                let lift = p * (0.015 + Float(i % 2) * 0.008)
                arc.position = SIMD3(cos(angle) * (0.01 + p * 0.015), 0.01 + lift, sin(angle) * (0.01 + p * 0.015))
                arc.orientation = simd_quatf(angle: angle, axis: SIMD3(0, 1, 0))
                    * simd_quatf(angle: -0.35 - p * 0.35, axis: SIMD3(1, 0, 0))
                let s = p * (0.35 + Float(i % 3) * 0.1)
                arc.scale = SIMD3(s, s, 0.35 + p * 0.55)
            }
        }
    }

    func setSolverMode(_ mode: SolverMode) {
        solverMode = mode
        for tier in MandalaTier.allCases {
            mpmSims[tier]?.setEnabled(mode == .mpmActive)
        }
        if mode != .mpmActive {
            if isIdentifying { setIdentifying(false) }
            if isAdaptivityEnabled { setAdaptivityEnabled(false) }
            if showAdaptivityHeatmap { setAdaptivityHeatmapVisible(false) }
            if isNeuralResidualEnabled { setNeuralResidualEnabled(false) }
            if showNeuralResidualSurface { setNeuralResidualSurfaceVisible(false) }
        }
        refreshDiagnosticsHUD()
        statusMessage = mode == .mpmActive
            ? "MPM active region · continuum sand core"
            : "DEM + height field · interactive baseline"
    }

    func setAdaptivityEnabled(_ enabled: Bool) {
        guard solverMode == .mpmActive || !enabled else {
            statusMessage = "Switch to MPM before enabling adaptivity"
            return
        }
        isAdaptivityEnabled = enabled
        adaptivityController.enabled = enabled
        if enabled {
            ensureAdaptivityVisualizer(for: unlockedTier)
        }
        statusMessage = enabled
            ? "Adaptivity on · refine contact / coarsen bulk"
            : "Adaptivity off"
        refreshDiagnosticsHUD()
    }

    func setAdaptivityHeatmapVisible(_ visible: Bool) {
        showAdaptivityHeatmap = visible
        ensureAdaptivityVisualizer(for: unlockedTier)
        for (tier, viz) in adaptivityVisualizers {
            viz.setEnabled(visible && tier.rawValue <= unlockedTier.rawValue)
        }
        if visible, let live = mpmSims[unlockedTier], let tierRoot = tierRoots[unlockedTier] {
            let capsules = ritualTool.contactCapsules(in: tierRoot)
            let stats = adaptivityController.tick(
                sim: live,
                capsules: capsules,
                applyAdaptation: false
            )
            adaptivityVisualizers[unlockedTier]?.update(with: stats.field)
            adaptivityHUD = stats.hudLine
        }
        statusMessage = visible ? "Adaptivity heatmap shown" : "Adaptivity heatmap hidden"
        refreshDiagnosticsHUD()
    }

    private func ensureAdaptivityVisualizer(for tier: MandalaTier) {
        guard let tierRoot = tierRoots[tier] else { return }
        if adaptivityVisualizers[tier] == nil {
            let viz = AdaptivityVisualizer()
            viz.attach(to: tierRoot)
            adaptivityVisualizers[tier] = viz
        }
    }

    func setNeuralResidualEnabled(_ enabled: Bool) {
        guard solverMode == .mpmActive || !enabled else {
            statusMessage = "Switch to MPM before enabling neural residual"
            return
        }
        isNeuralResidualEnabled = enabled
        neuralResidual.enabled = enabled
        neuralResidual.isTraining = enabled
        if enabled {
            ensureNeuralVisualizer(for: unlockedTier)
        }
        statusMessage = enabled
            ? "Neural residual on · physics-constrained δh"
            : "Neural residual off"
        refreshDiagnosticsHUD()
    }

    func setNeuralResidualSurfaceVisible(_ visible: Bool) {
        showNeuralResidualSurface = visible
        ensureNeuralVisualizer(for: unlockedTier)
        for (tier, viz) in neuralVisualizers {
            viz.setEnabled(visible && tier.rawValue <= unlockedTier.rawValue)
        }
        statusMessage = visible ? "Neural corrected surface shown" : "Neural surface hidden"
        refreshDiagnosticsHUD()
    }

    private func ensureNeuralVisualizer(for tier: MandalaTier) {
        guard let tierRoot = tierRoots[tier] else { return }
        if neuralVisualizers[tier] == nil {
            let viz = ResidualSurfaceVisualizer()
            viz.attach(to: tierRoot)
            neuralVisualizers[tier] = viz
        }
    }

    func setIdentifying(_ enabled: Bool) {
        guard solverMode == .mpmActive || !enabled else {
            statusMessage = "Switch to MPM before running identification"
            return
        }
        isIdentifying = enabled
        parameterIdentifier.prepare(tier: unlockedTier)
        ensureBayesianEngines()
        if enabled {
            // Start from a deliberately wrong guess so FD fit has work to do.
            var guess = ConstitutiveParams.defaultRice
            guess.phiDegrees = 28
            guess.youngsModulus = 2.2e5
            for sim in mpmSims.values {
                sim.setConstitutive(guess)
            }
            parameterIdentifier.seedParams(guess)
            parameterPosterior.reset(to: guess)
        }
        parameterIdentifier.setRunning(enabled)
        identificationHUD = parameterIdentifier.status.hudLine
        statusMessage = enabled
            ? "Identifying φ, E via FD sensitivity"
            : "Identification paused"
        refreshDiagnosticsHUD()
    }

    func setUncertaintyBandsVisible(_ visible: Bool) {
        showUncertaintyBands = visible
        ensureBayesianEngines()
        for (tier, viz) in uncertaintyVisualizers {
            viz.setEnabled(visible && tier.rawValue <= unlockedTier.rawValue)
        }
        if visible, let live = mpmSims[unlockedTier], let tierRoot = tierRoots[unlockedTier] {
            let capsules = ritualTool.contactCapsules(in: tierRoot)
            maybeUpdateSurfaceUncertainty(
                live: live,
                capsules: capsules,
                checkpoint: live.captureParticleCheckpoint(),
                force: true
            )
        }
        statusMessage = visible
            ? "Uncertainty bands · mean ± σ surface"
            : "Uncertainty bands hidden"
        refreshDiagnosticsHUD()
    }

    private func ensureBayesianEngines() {
        if surfaceUncertainty == nil {
            surfaceUncertainty = SurfaceUncertaintyEngine(tier: unlockedTier)
        }
        for tier in MandalaTier.allCases {
            guard let tierRoot = tierRoots[tier] else { continue }
            if uncertaintyVisualizers[tier] == nil {
                let viz = UncertaintyBandVisualizer()
                viz.attach(to: tierRoot)
                uncertaintyVisualizers[tier] = viz
            }
        }
    }

    private func maybeUpdateSurfaceUncertainty(
        live: MPMSimulator,
        capsules: [MPMCapsuleSDF],
        checkpoint: Data?,
        force: Bool = false
    ) {
        guard showUncertaintyBands || isIdentifying else { return }
        uncertaintyFrameCounter += 1
        guard force || uncertaintyFrameCounter % 3 == 0 else { return }
        ensureBayesianEngines()
        guard let engine = surfaceUncertainty,
              let data = checkpoint ?? Optional(live.captureParticleCheckpoint()) else { return }

        // Keep posterior mean aligned with live constitutive even without new grads.
        parameterPosterior.setMean(from: live.constitutive)
        engine.update(
            checkpoint: data,
            capsules: capsules,
            posterior: parameterPosterior.state,
            fillRadius: unlockedTier.fillRadius
        )
        uncertaintyVisualizers[unlockedTier]?.update(with: engine.field)
        uncertaintyVisualizers[unlockedTier]?.setEnabled(showUncertaintyBands)
        posteriorHUD = parameterPosterior.state.hudLine
        surfaceUncertaintyHUD = engine.field.hudLine
    }

    func captureIdentificationTarget() {
        parameterIdentifier.prepare(tier: unlockedTier)
        guard let live = mpmSims[unlockedTier] else {
            identificationHUD = "ID: no MPM on unlocked tier"
            return
        }
        parameterIdentifier.captureTarget(from: live.sampleObservation())
        identificationHUD = parameterIdentifier.status.hudLine
        statusMessage = parameterIdentifier.status.lastMessage
    }

    func captureSyntheticTeacherTarget() {
        parameterIdentifier.prepare(tier: unlockedTier)
        guard let live = mpmSims[unlockedTier],
              let tierRoot = tierRoots[unlockedTier] else {
            identificationHUD = "ID: no MPM on unlocked tier"
            return
        }
        let capsules = ritualTool.contactCapsules(in: tierRoot)
        parameterIdentifier.captureSyntheticTeacherTarget(
            live: live,
            capsules: capsules,
            teacher: .defaultRice
        )
        identificationHUD = parameterIdentifier.status.hudLine
        statusMessage = parameterIdentifier.status.lastMessage
    }

    /// JSON snapshot for experiment logging (debug / protocol).
    func exportDiagnosticsSnapshot() -> String {
        var tiers: [[String: Any]] = []
        for tier in MandalaTier.allCases {
            guard let snap = mpmSims[tier]?.latestDiagnostics else { continue }
            var dict = snap.jsonDictionary()
            dict["tier"] = tier.shortTitle
            dict["solver"] = solverMode.rawValue
            if let obs = mpmSims[tier]?.sampleObservation() {
                dict["observation"] = obs.jsonDictionary()
            }
            tiers.append(dict)
        }
        let id = parameterIdentifier.status
        let payload: [String: Any] = [
            "solver": solverMode.rawValue,
            "filledCount": filledCount,
            "identification": [
                "running": id.isRunning,
                "iteration": id.iteration,
                "loss": id.loss,
                "gradientNorm": id.gradientNorm,
                "hasTarget": id.hasTarget,
                "phi_deg": id.params.phiDegrees,
                "youngs": id.params.youngsModulus
            ],
            "posterior": parameterPosterior.state.jsonDictionary(),
            "surfaceUncertainty": [
                "meanSigma": surfaceUncertainty?.field.meanSigma ?? 0,
                "maxSigma": surfaceUncertainty?.field.maxSigma ?? 0,
                "ensemble": surfaceUncertainty?.field.sampleCount ?? 0
            ],
            "adaptivity": [
                "enabled": isAdaptivityEnabled,
                "splitCount": adaptivityController.latest.splitCount,
                "coarsenedCount": adaptivityController.latest.coarsenedCount,
                "fineParticles": adaptivityController.latest.fineParticles,
                "baseParticles": adaptivityController.latest.baseParticles,
                "coarseParticles": adaptivityController.latest.coarseParticles,
                "field": adaptivityController.latest.field.jsonDictionary()
            ],
            "neuralResidual": neuralResidual.stats.jsonDictionary(),
            "tiers": tiers
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private func refreshDiagnosticsHUD() {
        guard showDiagnosticsHUD else { return }
        switch solverMode {
        case .dem:
            diagnosticsHUD = "Solver: DEM · height-field baseline"
        case .mpmActive:
            if let unlocked = mpmSims[unlockedTier]?.latestDiagnostics {
                diagnosticsHUD = unlocked.summaryLine
            } else {
                diagnosticsHUD = "Solver: MPM · waiting for particles"
            }
        }
        identificationHUD = parameterIdentifier.status.hudLine
        posteriorHUD = parameterPosterior.state.hudLine
        surfaceUncertaintyHUD = surfaceUncertainty?.field.hudLine ?? "Surf σ idle"
        adaptivityHUD = isAdaptivityEnabled || showAdaptivityHeatmap
            ? adaptivityController.latest.hudLine
            : "Adapt idle"
        neuralResidualHUD = isNeuralResidualEnabled || showNeuralResidualSurface
            ? neuralResidual.stats.hudLine
            : "Neural residual idle"
    }

    func stopGrainSimulationLoop() {
        grainSimTask?.cancel()
        grainSimTask = nil
        ritualTool.stop()
    }

    func dragRitualTool(translation: SIMD3<Float>) {
        let base = ritualTool.localPositionInMandala ?? ritualTool.toolEntity.position
        ritualTool.updateDraggedPosition(base + translation)
    }

    func isRitualTool(_ entity: Entity) -> Bool {
        var node: Entity? = entity
        while let current = node {
            if current === ritualTool.toolEntity || current.name == "RitualScoop" {
                return true
            }
            node = current.parent
        }
        return false
    }

    func enterMandala() {
        prepareMandalaIfNeeded()
        applyPlatformPresentation()
        viewState = .immersive
#if !os(visionOS)
        immersiveSpaceState = .open
#endif
    }

    func exitMandala() {
        stopAutoPlay()
        viewState = .portal
#if !os(visionOS)
        immersiveSpaceState = .closed
#endif
    }

    /// Platform-specific seating of the mandala root (immersive room vs phone tabletop).
    func applyPlatformPresentation() {
#if os(iOS)
        mandalaRoot.position = SIMD3(0, -0.08, -1.35)
#else
        mandalaRoot.position = SIMD3(0, 1.05, -0.78)
        mandalaRoot.orientation = simd_quatf(angle: -0.22, axis: SIMD3(1, 0, 0))
        mandalaRoot.scale = SIMD3(repeating: 1)
#endif
    }

    func toggleAutoPlay() {
        if isAutoPlaying {
            stopAutoPlay()
        } else {
            startAutoPlay()
        }
    }

    func startAutoPlay() {
        guard !isAutoPlaying, !isComplete else { return }
        prepareMandalaIfNeeded()
        isAutoPlaying = true
        statusMessage = "Playing… placing remaining heaps"
        autoPlayTask?.cancel()
        autoPlayTask = Task { @MainActor in
            defer {
                isAutoPlaying = false
                autoPlayTask = nil
                if !Task.isCancelled {
                    updateStatus()
                }
            }
            for index in 0..<37 {
                guard !Task.isCancelled else { return }
                if filled[index] { continue }
                if isComplete { break }

                placeHeapForAutoPlay(at: index)

                // Physics fall + bulk rise; longer pause when a new ring descends.
                let tierBoundary = index == 16 || index == 24 || index == 32
                try? await Task.sleep(for: .milliseconds(tierBoundary ? 2200 : 1600))
            }
        }
    }

    func stopAutoPlay() {
        guard isAutoPlaying || autoPlayTask != nil else { return }
        autoPlayTask?.cancel()
        autoPlayTask = nil
        isAutoPlaying = false
        updateStatus()
    }

    func handleBackground() {
        if immersiveSpaceState == .open {
            viewState = .portal
        }
    }

    func setPlayMode(_ mode: PlayMode) {
        playMode = mode
        refreshHighlights()
        updateStatus()
    }

    func selectMaterial(_ kind: HeapMaterialKind) {
        selectedMaterial = kind
        rebuildPalette()
        updateStatus()
    }

    func handleTap(on entity: Entity) {
        if paletteKind(from: entity) != nil {
            // Guided: any palette tap places the next heap (material is auto-chosen).
            if playMode == .guided, let next = nextGuidedIndex, !isComplete {
                placeHeap(at: next)
                return
            }
            if let kind = paletteKind(from: entity) {
                selectMaterial(kind)
            }
            return
        }
        if let index = heapSlotIndex(from: entity) {
            if playMode == .guided, let next = nextGuidedIndex {
                if index == next || isNearGuidedTarget(tappedIndex: index, nextIndex: next) {
                    placeHeap(at: next)
                    return
                }
            }
            placeHeap(at: index)
        }
    }

    func resetMandala() {
        stopAutoPlay()
        if isIdentifying {
            setIdentifying(false)
        }
        parameterIdentifier.reset()
        parameterPosterior.reset()
        surfaceUncertainty?.reset(fillRadius: unlockedTier.fillRadius)
        adaptivityController.reset()
        neuralResidual.reset()
        for viz in uncertaintyVisualizers.values {
            viz.setEnabled(false)
        }
        for viz in adaptivityVisualizers.values {
            viz.setEnabled(false)
        }
        for viz in neuralVisualizers.values {
            viz.setEnabled(false)
        }
        for i in 0..<37 {
            if filled[i] {
                heapFractals.detach(heapNumber: i + 1)
            }
            heapEntities[i]?.removeFromParent()
            heapEntities[i] = nil
            filled[i] = false
        }
        filledCount = 0
        isComplete = false
        unlockedTier = .universe
        celebrationEntity?.removeFromParent()
        celebrationEntity = nil
        pulseTask?.cancel()
        pulseTask = nil
        crownEntity?.removeFromParent()
        crownEntity = nil

        for tier in MandalaTier.allCases {
            applyTierUnlocked(tier, unlocked: tier == .universe, animate: false)
            mpmSims[tier]?.setConstitutive(.defaultRice)
        }

        GrainAudio.shared.resume()
        refreshHighlights()
        updateStatus()
        applyPreferredResearchDefaults()
    }

    // MARK: - Placement

    private func placeHeap(at index: Int) {
        placeHeap(at: index, bypassGuidedOrder: false, forcePreferredMaterial: false)
    }

    /// Autoplay placement: skips already-filled checks' guided-order gate and uses each heap's preferred material.
    private func placeHeapForAutoPlay(at index: Int) {
        placeHeap(at: index, bypassGuidedOrder: true, forcePreferredMaterial: true)
    }

    private func placeHeap(at index: Int, bypassGuidedOrder: Bool, forcePreferredMaterial: Bool) {
        guard HeapDefinition.all.indices.contains(index) else { return }
        let definition = HeapDefinition.all[index]

        guard !filled[index] else {
            statusMessage = "That heap is already offered."
            return
        }

        guard definition.tier.rawValue <= unlockedTier.rawValue else {
            statusMessage = "Finish \(unlockedTier.shortTitle) before the next ring can be placed."
            if let next = nextGuidedIndex {
                pulseSlot(at: next)
            }
            return
        }

        if !bypassGuidedOrder, playMode == .guided, let next = nextGuidedIndex, index != next {
            let name = HeapDefinition.all[next].name
            statusMessage = "\(name) · Tap the glowing beacon · Heap \(next + 1) of 37"
            pulseSlot(at: next)
            return
        }

        let material: HeapMaterialKind
        if playMode == .guided || forcePreferredMaterial {
            material = definition.preferredMaterial
            selectedMaterial = material
            rebuildPalette()
        } else {
            material = selectedMaterial
        }

        let heap: Entity
        if definition.number == 1 {
            heap = MandalaBuilder.makeMountMeru(scale: definition.containedHeapScale)
        } else {
            heap = MandalaBuilder.makeHeap(
                kind: material,
                scale: definition.containedHeapScale,
                heapNumber: definition.number
            )
        }
        heap.position = SIMD3(0, 0.005, 0)
        let aura = MandalaBuilder.makeHeapBounceAura(seed: definition.number)
        heap.addChild(aura)
        slotEntities[index].addChild(heap)
        heapEntities[index] = heap
        filled[index] = true
        filledCount = filled.filter { $0 }.count
        heapPrevBob[index] = 0
        heapBounceCooldown[index] = 0
        heapBouncePulse[index] = 0.85 // placement pop
        if MandalaBuilder.usesFractalShell(heapNumber: definition.number) {
            heapFractals.attach(to: heap, heapNumber: definition.number)
        }

        heap.scale = SIMD3(repeating: 0.2)
        let grown = Transform(scale: .one, rotation: heap.orientation, translation: heap.position)
        heap.move(to: grown, relativeTo: heap.parent, duration: 0.28, timingFunction: .easeOut)

        refreshHighlights()
        updateStatus()

        let tier = definition.tier
        let completedOnTier = tier.heapNumbers.filter { filled[$0 - 1] }.count
        let totalOnTier = tier.heapNumbers.count
        let slotXZ = SIMD2(definition.localPosition.x, definition.localPosition.z)

        // GPU pour → height-field settle; light rigid clusters for near-field contact spice.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard heapEntities[index] === heap,
                  let tierEntity = tierRoots[tier] else { return }

            let progress = grainFillProgress(completed: completedOnTier, total: totalOnTier)
            switch solverMode {
            case .dem:
                grainSims[tier]?.pour(at: slotXZ, ritualProgress: progress)
            case .mpmActive:
                mpmSims[tier]?.pour(at: slotXZ, ritualProgress: progress)
                // Light DEM pulse so the height-field bulk still rises with ritual progress.
                grainSims[tier]?.pour(at: slotXZ, ritualProgress: progress * 0.55)
            }

            // A few RealityKit clusters still collide with kinematic rings.
            GrainPhysics.emitClusters(
                into: tierEntity,
                tier: tier,
                at: slotXZ,
                count: 10
            )

            try? await Task.sleep(for: .milliseconds(900))
            GrainPhysics.freezeSettledGrains(in: tierEntity)
            grainSims[tier]?.setRitualFillFloor(progress)

            if definition.number == 1 {
                MandalaBuilder.setTierFillProgress(tierEntity: tierEntity, progress: progress)
            } else {
                settleOfferingHeap(heap, into: tier, completed: completedOnTier, total: totalOnTier)
            }

            try? await Task.sleep(for: .milliseconds(350))
            GrainPhysics.absorbBuriedAndExcess(in: tierEntity, fillProgress: progress)

            maybeUnlockNextTier()

            if filledCount >= 37 {
                placeTopCenterpiece()
            } else {
                updateStatus()
            }
        }
    }

    /// Non-linear fill: thin base early, then rises to the rim as the ring completes.
    private func grainFillProgress(completed: Int, total: Int) -> Float {
        guard total > 0 else { return 0.03 }
        let ritualProgress = Float(completed) / Float(total)
        return 0.05 + 0.95 * pow(ritualProgress, 0.72)
    }

    /// Spread / compress a placed heap so it contributes to the shared grain mass.
    private func settleOfferingHeap(
        _ heap: Entity,
        into tier: MandalaTier,
        completed: Int,
        total: Int
    ) {
        var settledTransform = heap.transform
        settledTransform.scale.x *= 1.22
        settledTransform.scale.z *= 1.22
        settledTransform.scale.y *= 0.48
        settledTransform.translation.y -= 0.012
        heap.move(
            to: settledTransform,
            relativeTo: heap.parent,
            duration: 0.55,
            timingFunction: .easeInOut
        )

        guard let tierEntity = tierRoots[tier] else { return }
        MandalaBuilder.setTierFillProgress(
            tierEntity: tierEntity,
            progress: grainFillProgress(completed: completed, total: total)
        )
    }

    private func maybeUnlockNextTier() {
        // Unlock the next ring once every heap on the current ring is filled
        // (1–17 → 18–25 → 26–33 → 34–37; centerpiece follows after 37).
        while let next = unlockedTier.next {
            let range = unlockedTier.heapNumbers
            let tierComplete = range.allSatisfy { filled[$0 - 1] }
            guard tierComplete else { break }

            // Ensure the completed ring's grain is packed to the rim before the next settles.
            if let lower = tierRoots[unlockedTier] {
                MandalaBuilder.setTierFillProgress(
                    tierEntity: lower,
                    progress: 1.0,
                    animated: true
                )
            }

            unlockedTier = next
            applyTierUnlocked(next, unlocked: true, animate: true)
            statusMessage = "Ring placed · \(next.title) unlocked"
        }
    }

    private func applyTierUnlocked(_ tier: MandalaTier, unlocked: Bool, animate: Bool) {
        guard let root = tierRoots[tier] else { return }
        let rest = Transform(translation: SIMD3(0, tier.surfaceY, 0))
        let metalRing = root.findEntity(named: "MetalRing")

        if unlocked {
            if animate {
                if let lower = MandalaTier(rawValue: tier.rawValue - 1),
                   let lowerRoot = tierRoots[lower] {
                    MandalaBuilder.compressGrainUnderRing(lowerTier: lowerRoot)
                    grainSims[lower]?.compressUnderRing()
                    grainSims[lower]?.setRitualFillFloor(1.0)
                    GrainPhysics.freezeSettledGrains(in: lowerRoot)
                }

                // Kinematic ring: collides with loose surface grains while we prescribe the drop.
                if let metalRing {
                    GrainPhysics.setRingPhysicsMode(metalRing, mode: .kinematic)
                }

                var starting = rest
                starting.translation.y += 0.09
                starting.scale = SIMD3(repeating: 1.015)
                root.transform = starting
                root.isEnabled = true
                root.move(
                    to: rest,
                    relativeTo: root.parent,
                    duration: 0.8,
                    timingFunction: .easeInOut
                )
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(850))
                    guard tierRoots[tier] === root else { return }
                    root.transform = rest
                    root.isEnabled = true
                    if let metalRing {
                        GrainPhysics.setRingPhysicsMode(metalRing, mode: .static)
                    }
                    if let lower = MandalaTier(rawValue: tier.rawValue - 1),
                       let lowerRoot = tierRoots[lower] {
                        GrainPhysics.freezeSettledGrains(in: lowerRoot)
                        GrainPhysics.absorbBuriedAndExcess(in: lowerRoot, fillProgress: 1.0)
                    }
                }
            } else {
                root.transform = rest
                root.isEnabled = true
                if let metalRing {
                    GrainPhysics.setRingPhysicsMode(metalRing, mode: .static)
                }
            }
        } else {
            root.isEnabled = false
            root.transform = rest
        }
    }

    /// Last placement: pedestal + flame/gem finial in the middle of the celestial (top) ring.
    private func placeTopCenterpiece() {
        isComplete = true
        // Grain sim loop keeps stepping filled tiers; stop cascading settle audio.
        GrainAudio.shared.stopAll()
        statusMessage = "Final piece · Centerpiece on the celestial ring"
        refreshHighlights()

        // Finish any in-flight unlock settle so parenting isn't mid-scale/mid-drop.
        if let celestialRoot = tierRoots[.celestial] {
            celestialRoot.transform = Transform(translation: SIMD3(0, MandalaTier.celestial.surfaceY, 0))
            celestialRoot.isEnabled = true
        }

        crownEntity?.removeFromParent()
        celebrationEntity?.removeFromParent()

        let crown = MandalaBuilder.makeTopOrnament()
        // Static ornament — never add PhysicsBody / PhysicsMotion (would fall through the deck).

        // Same host + Y as successful heaps: TierSlots sits on the fill, heaps rest at +0.005.
        // Center of the celestial deck (r=0); cardinals stay at r≈0.08.
        let host: Entity = tierSlotsParents[.celestial]
            ?? tierRoots[.celestial]?.findEntity(named: "TierSlots")
            ?? mandalaRoot
        let seatY: Float = (host === mandalaRoot)
            ? MandalaTier.celestial.surfaceY + MandalaTier.celestial.slotsY + 0.005
            : 0.005
        crown.position = SIMD3(0, seatY, 0)
        // Compact finial (~55% of prior visual size). Grow via transform.scale only —
        // never `rotation: simd_quatf()` (zero quat NaNs the move and the piece vanishes).
        crown.scale = SIMD3(repeating: 0.42)
        host.addChild(crown)
        crownEntity = crown

        var grown = crown.transform
        grown.scale = SIMD3(repeating: 0.72)
        crown.move(to: grown, relativeTo: host, duration: 0.55, timingFunction: .easeOut)

        let burst = MandalaBuilder.makeCelebrationBurst()
        // Sit on the finial tip (pedestal top 0.036 + flame tip ≈ 0.187) — no floating gap.
        burst.position = SIMD3(0, 0.036 + 0.175, 0)
        burst.scale = SIMD3(repeating: 0.55)
        crown.addChild(burst)
        celebrationEntity = burst

        var expanded = burst.transform
        expanded.scale = SIMD3(repeating: 1.05)
        burst.move(to: expanded, relativeTo: crown, duration: 1.2, timingFunction: .easeOut)

        pulseTask?.cancel()
        pulseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            statusMessage = "Mandala Complete — centerpiece placed"
            for _ in 0..<3 {
                guard !Task.isCancelled, burst.parent != nil else { return }
                var bright = burst.transform
                bright.scale = SIMD3(repeating: 1.18)
                burst.move(to: bright, relativeTo: crown, duration: 0.45, timingFunction: .easeInOut)
                try? await Task.sleep(for: .milliseconds(450))
                var dim = burst.transform
                dim.scale = SIMD3(repeating: 0.92)
                burst.move(to: dim, relativeTo: crown, duration: 0.45, timingFunction: .easeInOut)
                try? await Task.sleep(for: .milliseconds(450))
            }
        }
    }

    // MARK: - Build

    private func buildMandala() {
        mandalaRoot.name = "MandalaRoot"
        mandalaRoot.children.removeAll()
        slotEntities = (0..<37).map { _ in Entity() }
        heapEntities = Array(repeating: nil, count: 37)
        filled = Array(repeating: false, count: 37)
        filledCount = 0
        isComplete = false
        unlockedTier = .universe
        stopGrainSimulationLoop()
        grainSims.removeAll()
        mpmSims.removeAll()
        uncertaintyVisualizers.removeAll()
        adaptivityVisualizers.removeAll()
        neuralVisualizers.removeAll()
        surfaceUncertainty = nil
        adaptivityController.reset()
        neuralResidual.reset()
        tierRoots.removeAll()
        tierSlotsParents.removeAll()
        ringSpinAngles.removeAll()
        heapIdleTime = 0
        heapPrevBob = Array(repeating: 0, count: 37)
        heapBounceCooldown = Array(repeating: 0, count: 37)
        heapBouncePulse = Array(repeating: 0, count: 37)
        heapFractals.reset()
        crownEntity = nil
        celebrationEntity = nil

        mandalaRoot.position = SIMD3(0, 1.05, -0.78)
        mandalaRoot.orientation = simd_quatf(angle: -0.22, axis: SIMD3(1, 0, 0))
        applyPlatformPresentation()

        // Localized sim so gravity is "down" in mandala space (toward the plate).
        var simulation = PhysicsSimulationComponent()
        simulation.gravity = SIMD3(0, -9.81, 0)
        mandalaRoot.components.set(simulation)

        mandalaRoot.addChild(MandalaBuilder.makeTableCover())
        mandalaRoot.addChild(MandalaBuilder.makePlate())

        for tier in MandalaTier.allCases {
            let unlocked = (tier == .universe)
            let tierRoot = MandalaBuilder.makeTier(tier: tier, unlocked: unlocked)
            mandalaRoot.addChild(tierRoot)
            tierRoots[tier] = tierRoot

            if let sim = GrainGPUSimulator(tier: tier) {
                sim.attach(to: tierRoot)
                grainSims[tier] = sim
            }
            if let mpm = MPMSimulator(tier: tier) {
                mpm.attach(to: tierRoot)
                mpm.setEnabled(solverMode == .mpmActive)
                mpmSims[tier] = mpm
            }

            guard let slotsParent = tierRoot.findEntity(named: "TierSlots") else { continue }
            tierSlotsParents[tier] = slotsParent

            for definition in HeapDefinition.all where definition.tier == tier {
                let index = definition.number - 1
                let slot = MandalaBuilder.makeSlotMarker(
                    definition: definition,
                    highlighted: false,
                    interactive: unlocked
                )
                slot.position = definition.localPosition
                slotsParent.addChild(slot)
                slotEntities[index] = slot
            }
        }

        paletteRoot = Entity()
        paletteRoot.name = "Palette"
        paletteRoot.isEnabled = false
        mandalaRoot.addChild(paletteRoot)
    }

    private func rebuildPalette() {
        // Spatial material orbs removed — they cluttered the right side of the scene.
        // Guided mode still uses each heap's preferred material; free mode keeps selection.
        paletteRoot.children.removeAll()
        paletteRoot.isEnabled = false
    }

    private func refreshHighlights() {
        highlightPulseTask?.cancel()
        highlightPulseTask = nil

        let highlightIndex: Int? = {
            guard playMode == .guided, !isComplete else { return nil }
            return nextGuidedIndex
        }()

        for (i, oldSlot) in slotEntities.enumerated() {
            let definition = HeapDefinition.all[i]
            let parent = oldSlot.parent
            let position = oldSlot.position
            oldSlot.removeFromParent()

            let unlocked = definition.tier.rawValue <= unlockedTier.rawValue
            let highlighted = (highlightIndex == i) && !filled[i] && unlocked
            // Empty unlocked slots stay tappable; guided near-miss maps neighbors to the beacon.
            // Highlighted slot uses a much larger collision (see MandalaBuilder).
            let interactive = !filled[i] && unlocked
            let newSlot = MandalaBuilder.makeSlotMarker(
                definition: definition,
                highlighted: highlighted,
                interactive: interactive
            )
            // Filled slots keep a passive marker but no need to re-tap.
            if filled[i] {
                let filledMarker = MandalaBuilder.makeSlotMarker(
                    definition: definition,
                    highlighted: false,
                    interactive: false
                )
                filledMarker.position = position
                parent?.addChild(filledMarker)
                if let heap = heapEntities[i] {
                    filledMarker.addChild(heap)
                }
                slotEntities[i] = filledMarker
            } else {
                newSlot.position = position
                parent?.addChild(newSlot)
                slotEntities[i] = newSlot
            }
        }

        if let index = highlightIndex {
            pulseSlot(at: index)
        }
    }

    private func pulseSlot(at index: Int) {
        guard slotEntities.indices.contains(index),
              let beacon = slotEntities[index].findEntity(named: "ActiveTargetBeacon") else {
            return
        }

        highlightPulseTask?.cancel()
        let base = beacon.transform
        highlightPulseTask = Task { @MainActor in
            while !Task.isCancelled, beacon.parent != nil {
                var large = base
                large.scale = SIMD3(repeating: 1.35)
                beacon.move(to: large, relativeTo: beacon.parent, duration: 0.55, timingFunction: .easeInOut)
                try? await Task.sleep(for: .milliseconds(550))
                guard !Task.isCancelled else { return }
                var small = base
                small.scale = SIMD3(repeating: 0.82)
                beacon.move(to: small, relativeTo: beacon.parent, duration: 0.55, timingFunction: .easeInOut)
                try? await Task.sleep(for: .milliseconds(550))
            }
        }

        let slot = slotEntities[index]
        let up = Transform(scale: SIMD3(repeating: 1.12), rotation: slot.orientation, translation: slot.position)
        slot.move(to: up, relativeTo: slot.parent, duration: 0.22, timingFunction: .easeOut)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            guard slot.parent != nil else { return }
            let down = Transform(scale: .one, rotation: slot.orientation, translation: slot.position)
            slot.move(to: down, relativeTo: slot.parent, duration: 0.28, timingFunction: .easeInOut)
        }
    }

    private func updateStatus() {
        if isComplete {
            statusMessage = "Mandala Complete — centerpiece placed"
            return
        }
        if isAutoPlaying {
            if let name = nextHeapName, let index = nextGuidedIndex {
                statusMessage = "Playing… \(name) · \(index + 1)/37"
            } else {
                statusMessage = "Playing… placing remaining heaps"
            }
            return
        }
        switch playMode {
        case .guided:
            if let name = nextHeapName, let index = nextGuidedIndex {
                let tier = HeapDefinition.all[index].tier
                statusMessage = "\(tier.shortTitle) · \(name) · Tap the glowing beacon · \(index + 1)/37"
            }
        case .free:
            statusMessage = "Free · \(unlockedTier.title) — place on the unlocked ring only."
        }
    }

#if DEBUG
    func debugAutoPlay() async {
        print("[AUTOPLAY] begin — guided fill with tier unlocks")
        for step in 0..<37 {
            guard let slot = slotEntities[safe: step] else {
                print("[AUTOPLAY] missing slot \(step)")
                return
            }
            handleTap(on: slot)
            print("[AUTOPLAY] placed \(step + 1) unlocked=\(unlockedTier.shortTitle) filled=\(filledCount)")
            let tierBoundary = step + 1 == 17 || step + 1 == 25 || step + 1 == 33
            try? await Task.sleep(for: .milliseconds(tierBoundary ? 2200 : 1600))
        }
        if let crown = crownEntity {
            let p = crown.position(relativeTo: mandalaRoot)
            print("[AUTOPLAY] centerpiece parent=\(crown.parent?.name ?? "nil") pos=\(p) scale=\(crown.scale)")
        } else {
            print("[AUTOPLAY] ERROR: centerpiece missing after heap 37")
        }
        try? await Task.sleep(for: .seconds(12))
        resetMandala()
        print("[AUTOPLAY] done")
    }

    func debugPlaceDemoHeaps() async {
        for index in 0..<3 {
            guard let slot = slotEntities[safe: index] else { return }
            handleTap(on: slot)
            try? await Task.sleep(for: .milliseconds(500))
        }
        print("[DEMO] placed 3 heaps; beacon on heap 4; tiers still on Universe")
    }
#endif

    private func heapSlotIndex(from entity: Entity) -> Int? {
        var current: Entity? = entity
        while let node = current {
            if let component = node.components[HeapSlotComponent.self] {
                return component.index
            }
            current = node.parent
        }
        return nil
    }

    /// Forgiving guided aim: a hit on a nearby empty slot still counts as the glowing target.
    private func isNearGuidedTarget(tappedIndex: Int, nextIndex: Int, radius: Float = 0.18) -> Bool {
        guard slotEntities.indices.contains(tappedIndex),
              slotEntities.indices.contains(nextIndex) else { return false }
        let tapped = slotEntities[tappedIndex].position(relativeTo: nil)
        let target = slotEntities[nextIndex].position(relativeTo: nil)
        let dx = tapped.x - target.x
        let dy = tapped.y - target.y
        let dz = tapped.z - target.z
        return sqrt(dx * dx + dy * dy + dz * dz) <= radius
    }

    private func paletteKind(from entity: Entity) -> HeapMaterialKind? {
        var current: Entity? = entity
        while let node = current {
            if let component = node.components[PaletteItemComponent.self] {
                return HeapMaterialKind(rawValue: component.materialKindRaw)
            }
            current = node.parent
        }
        return nil
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
