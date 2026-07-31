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
