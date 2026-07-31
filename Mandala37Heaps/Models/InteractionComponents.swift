import Foundation
import RealityKit

struct HeapSlotComponent: Component, Codable {
    var index: Int

    static func register() {
        HeapSlotComponent.registerComponent()
    }
}

struct PaletteItemComponent: Component, Codable {
    var materialKindRaw: String

    static func register() {
        PaletteItemComponent.registerComponent()
    }
}

/// Tracks growing grain fill inside a metal ring (progress 0…1 maps to rim height).
struct GrainFillComponent: Component, Codable {
    var maximumHeight: Float
    var progress: Float

    static func register() {
        GrainFillComponent.registerComponent()
    }
}

/// A rigid-body grain cluster used for hybrid surface physics (not every rice grain).
struct PhysicalGrainComponent: Component, Codable {
    var tierRaw: Int
    var birthTime: TimeInterval
    var isFrozen: Bool

    static func register() {
        PhysicalGrainComponent.registerComponent()
    }
}
