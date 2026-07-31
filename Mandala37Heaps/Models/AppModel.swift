import Foundation
import Observation
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
    }

    func enterMandala() {
        prepareMandalaIfNeeded()
        viewState = .immersive
    }

    func exitMandala() {
        stopAutoPlay()
        viewState = .portal
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

                // Allow heap settle + grain rise; longer pause when a new ring descends.
                let tierBoundary = index == 16 || index == 24 || index == 32
                try? await Task.sleep(for: .milliseconds(tierBoundary ? 1400 : 700))
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
        for i in 0..<37 {
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
        }

        refreshHighlights()
        updateStatus()
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
            heap = MandalaBuilder.makeMountMeru(scale: definition.heapScale)
        } else {
            heap = MandalaBuilder.makeHeap(
                kind: material,
                scale: definition.heapScale,
                heapNumber: definition.number
            )
        }
        heap.position = SIMD3(0, 0.005, 0)
        slotEntities[index].addChild(heap)
        heapEntities[index] = heap
        filled[index] = true
        filledCount = filled.filter { $0 }.count

        heap.scale = SIMD3(repeating: 0.2)
        let grown = Transform(scale: .one, rotation: heap.orientation, translation: heap.position)
        heap.move(to: grown, relativeTo: heap.parent, duration: 0.28, timingFunction: .easeOut)

        refreshHighlights()
        updateStatus()

        let tier = definition.tier
        let completedOnTier = tier.heapNumbers.filter { filled[$0 - 1] }.count
        let totalOnTier = tier.heapNumbers.count

        // Keep heap visible briefly, then merge into the common fill and raise the grain.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            guard heapEntities[index] === heap else { return }

            if definition.number == 1 {
                // Mount Meru stays proud; only the shared grain rises under it.
                if let tierEntity = tierRoots[tier] {
                    MandalaBuilder.setTierFillProgress(
                        tierEntity: tierEntity,
                        progress: grainFillProgress(completed: completedOnTier, total: totalOnTier)
                    )
                }
            } else {
                settleOfferingHeap(
                    heap,
                    into: tier,
                    completed: completedOnTier,
                    total: totalOnTier
                )
            }

            try? await Task.sleep(for: .milliseconds(480))
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

        if unlocked {
            if animate {
                if let lower = MandalaTier(rawValue: tier.rawValue - 1),
                   let lowerRoot = tierRoots[lower] {
                    MandalaBuilder.compressGrainUnderRing(lowerTier: lowerRoot)
                }

                // Descend into the packed grain of the ring below (not a tiny pop-in).
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
                }
            } else {
                root.transform = rest
                root.isEnabled = true
            }
        } else {
            root.isEnabled = false
            root.transform = rest
        }
    }

    /// Last placement: pedestal + flame/gem finial in the middle of the celestial (top) ring.
    private func placeTopCenterpiece() {
        isComplete = true
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
        // Burst above the finial tip (pedestal + flame ~0.20 × scale 0.72).
        burst.position = SIMD3(0, seatY + 0.28, 0)
        burst.scale = SIMD3(repeating: 0.28)
        host.addChild(burst)
        celebrationEntity = burst

        var expanded = burst.transform
        expanded.scale = SIMD3(repeating: 1.15)
        burst.move(to: expanded, relativeTo: host, duration: 1.2, timingFunction: .easeOut)

        pulseTask?.cancel()
        pulseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            statusMessage = "Mandala Complete — centerpiece placed"
            for _ in 0..<3 {
                guard !Task.isCancelled else { return }
                var bright = burst.transform
                bright.scale = SIMD3(repeating: 1.35)
                burst.move(to: bright, relativeTo: host, duration: 0.45, timingFunction: .easeInOut)
                try? await Task.sleep(for: .milliseconds(450))
                var dim = burst.transform
                dim.scale = SIMD3(repeating: 0.95)
                burst.move(to: dim, relativeTo: host, duration: 0.45, timingFunction: .easeInOut)
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
        tierRoots.removeAll()
        tierSlotsParents.removeAll()
        crownEntity = nil
        celebrationEntity = nil

        mandalaRoot.position = SIMD3(0, 1.05, -0.78)
        mandalaRoot.orientation = simd_quatf(angle: -0.22, axis: SIMD3(1, 0, 0))

        mandalaRoot.addChild(MandalaBuilder.makePlate())

        for tier in MandalaTier.allCases {
            let unlocked = (tier == .universe)
            let tierRoot = MandalaBuilder.makeTier(tier: tier, unlocked: unlocked)
            mandalaRoot.addChild(tierRoot)
            tierRoots[tier] = tierRoot

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
        paletteRoot.position = SIMD3(0, -0.02, 0.62)
        mandalaRoot.addChild(paletteRoot)
    }

    private func rebuildPalette() {
        paletteRoot.children.removeAll()

        let kinds = HeapMaterialKind.allCases
        let spacing: Float = 0.075
        let startX = -spacing * Float(kinds.count - 1) / 2

        var trayMat = SimpleMaterial()
        trayMat.color = .init(tint: UIColor(red: 0.25, green: 0.18, blue: 0.10, alpha: 1))
        trayMat.metallic = .float(0.2)
        trayMat.roughness = .float(0.6)
        let tray = ModelEntity(
            mesh: .generateBox(size: SIMD3(spacing * Float(kinds.count) + 0.04, 0.012, 0.08), cornerRadius: 0.01),
            materials: [trayMat]
        )
        tray.position = SIMD3(0, -0.02, 0)
        paletteRoot.addChild(tray)

        for (i, kind) in kinds.enumerated() {
            let orb = MandalaBuilder.makePaletteOrb(kind: kind, selected: kind == selectedMaterial)
            orb.position = SIMD3(startX + spacing * Float(i), 0.02, 0)
            paletteRoot.addChild(orb)
        }
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
                statusMessage = "\(tier.shortTitle) · \(name) · Tap the glowing beacon (or palette) · \(index + 1)/37"
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
            try? await Task.sleep(for: .milliseconds(tierBoundary ? 1400 : 700))
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
