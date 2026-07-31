import Foundation
import RealityKit
import UIKit

/// Physical offering-set tier matching the traditional stacked-ring mandala.
enum MandalaTier: Int, CaseIterable, Identifiable {
    /// Base plate + largest ring: Meru, continents, subcontinents (heaps 1–13).
    case universe = 0
    /// Second ring: continental treasures + seven royal emblems + vase (14–25).
    case treasures = 1
    /// Third ring: eight offering goddesses (26–33).
    case goddesses = 2
    /// Upper section: sun, moon, parasol, victory banner (34–37).
    case celestial = 3

    var id: Int { rawValue }

    /// Inclusive 1-based heap numbers on this tier.
    var heapNumbers: ClosedRange<Int> {
        switch self {
        case .universe: return 1...13
        case .treasures: return 14...25
        case .goddesses: return 26...33
        case .celestial: return 34...37
        }
    }

    var title: String {
        switch self {
        case .universe: return "Level 1 · Universe"
        case .treasures: return "Level 2 · Treasures"
        case .goddesses: return "Level 3 · Goddesses"
        case .celestial: return "Level 4 · Sun & Moon"
        }
    }

    var shortTitle: String {
        switch self {
        case .universe: return "Universe"
        case .treasures: return "Treasures"
        case .goddesses: return "Goddesses"
        case .celestial: return "Celestial"
        }
    }

    /// Outer radius of this tier's metal ring.
    var ringRadius: Float {
        switch self {
        case .universe: return 0.48
        case .treasures: return 0.34
        case .goddesses: return 0.24
        case .celestial: return 0.15
        }
    }

    /// Usable inner deck radius for placing heaps.
    var deckRadius: Float { ringRadius * 0.82 }

    /// Local Y of the fill surface relative to the mandala root (plate top ≈ 0.034).
    var surfaceY: Float {
        switch self {
        case .universe: return 0.055
        case .treasures: return 0.108
        case .goddesses: return 0.161
        case .celestial: return 0.214
        }
    }

    var ringHeight: Float { 0.042 }

    var next: MandalaTier? {
        MandalaTier(rawValue: rawValue + 1)
    }
}

/// Traditional Tibetan 37-heap mandala offering definitions and tiered layout.
struct HeapDefinition {
    let number: Int
    let name: String
    let preferredMaterial: HeapMaterialKind
    let tier: MandalaTier
    /// Polar radius as a fraction of the tier's deck radius (0…1).
    let radiusFraction: Float
    let angleDegrees: Float
    let heapScale: Float

    /// Canonical 37 heaps in offering order, assigned to stacked tiers.
    static let all: [HeapDefinition] = {
        var items: [HeapDefinition] = []

        // —— Tier 0: Mount Meru, continents, subcontinents ——
            items.append(HeapDefinition(
                number: 1, name: "Mount Meru", preferredMaterial: .gold,
                tier: .universe, radiusFraction: 0, angleDegrees: 0, heapScale: 1.75
            ))

        let continents: [(String, HeapMaterialKind, Float)] = [
            ("Eastern Continent (Pūrvavideha)", .turquoise, 0),
            ("Southern Continent (Jambudvīpa)", .coral, 90),
            ("Western Continent (Aparagodānīya)", .pearl, 180),
            ("Northern Continent (Uttarakuru)", .jade, 270)
        ]
        for (i, c) in continents.enumerated() {
            items.append(HeapDefinition(
                number: 2 + i, name: c.0, preferredMaterial: c.1,
                tier: .universe, radiusFraction: 0.42, angleDegrees: c.2, heapScale: 1.05
            ))
        }

        let subOffsets: [Float] = [-22, 22, 68, 112, 158, 202, 248, 292]
        let subNames = [
            "East Subcontinent A", "East Subcontinent B",
            "South Subcontinent A", "South Subcontinent B",
            "West Subcontinent A", "West Subcontinent B",
            "North Subcontinent A", "North Subcontinent B"
        ]
        for (i, angle) in subOffsets.enumerated() {
            items.append(HeapDefinition(
                number: 6 + i, name: subNames[i], preferredMaterial: .grain,
                tier: .universe, radiusFraction: 0.72, angleDegrees: angle, heapScale: 0.78
            ))
        }

        // —— Tier 1: treasures + royal emblems + vase ——
        let treasures: [(String, HeapMaterialKind, Float)] = [
            ("Jewel Mountain", .gold, 0),
            ("Wish-Fulfilling Tree", .jade, 90),
            ("Wish-Fulfilling Cow", .pearl, 180),
            ("Harvest That Needs No Cultivation", .grain, 270)
        ]
        for (i, t) in treasures.enumerated() {
            items.append(HeapDefinition(
                number: 14 + i, name: t.0, preferredMaterial: t.1,
                tier: .treasures, radiusFraction: 0.38, angleDegrees: t.2, heapScale: 0.92
            ))
        }

        let emblems: [(String, HeapMaterialKind)] = [
            ("Precious Wheel", .gold),
            ("Precious Jewel", .turquoise),
            ("Precious Queen", .coral),
            ("Precious Minister", .pearl),
            ("Precious Elephant", .jade),
            ("Precious Horse", .grain),
            ("Precious General", .gold),
            ("Great Treasure Vase", .turquoise)
        ]
        for (i, e) in emblems.enumerated() {
            let angle = Float(i) * 45 + 22.5
            items.append(HeapDefinition(
                number: 18 + i, name: e.0, preferredMaterial: e.1,
                tier: .treasures, radiusFraction: 0.72, angleDegrees: angle, heapScale: 0.74
            ))
        }

        // —— Tier 2: eight offering goddesses ——
        let goddesses = [
            "Goddess of Beauty", "Goddess of Garlands", "Goddess of Song", "Goddess of Dance",
            "Goddess of Flowers", "Goddess of Incense", "Goddess of Light", "Goddess of Perfume"
        ]
        let goddessMats: [HeapMaterialKind] = [.coral, .pearl, .turquoise, .jade, .coral, .grain, .gold, .pearl]
        for (i, name) in goddesses.enumerated() {
            let angle = Float(i) * 45
            items.append(HeapDefinition(
                number: 26 + i, name: name, preferredMaterial: goddessMats[i],
                tier: .goddesses, radiusFraction: 0.62, angleDegrees: angle, heapScale: 0.68
            ))
        }

        // —— Tier 3: sun, moon, parasol, victory banner ——
        let outer: [(String, HeapMaterialKind, Float)] = [
            ("Sun", .gold, 45),
            ("Moon", .pearl, 225),
            ("Precious Parasol", .turquoise, 135),
            ("Victory Banner", .coral, 315)
        ]
        for (i, o) in outer.enumerated() {
            items.append(HeapDefinition(
                number: 34 + i, name: o.0, preferredMaterial: o.1,
                tier: .celestial, radiusFraction: 0.68, angleDegrees: o.2, heapScale: 0.75
            ))
        }

        precondition(items.count == 37)
        return items
    }()

    /// Local position on the tier's fill surface (y ≈ 0).
    var localPosition: SIMD3<Float> {
        let rad = angleDegrees * .pi / 180
        let r = radiusFraction * tier.deckRadius
        return SIMD3(r * cos(rad), 0, r * sin(rad))
    }
}

enum HeapMaterialKind: String, CaseIterable, Identifiable {
    case gold
    case turquoise
    case coral
    case pearl
    case jade
    case grain

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gold: return "Gold"
        case .turquoise: return "Turquoise"
        case .coral: return "Coral"
        case .pearl: return "Pearl"
        case .jade: return "Jade"
        case .grain: return "Grain"
        }
    }

    var tint: UIColor {
        switch self {
        case .gold: return UIColor(red: 0.90, green: 0.72, blue: 0.22, alpha: 1)
        case .turquoise: return UIColor(red: 0.22, green: 0.72, blue: 0.70, alpha: 1)
        case .coral: return UIColor(red: 0.90, green: 0.42, blue: 0.35, alpha: 1)
        case .pearl: return UIColor(red: 0.94, green: 0.93, blue: 0.90, alpha: 1)
        case .jade: return UIColor(red: 0.28, green: 0.68, blue: 0.48, alpha: 1)
        case .grain: return UIColor(red: 0.92, green: 0.84, blue: 0.55, alpha: 1)
        }
    }

    var metallic: Float {
        switch self {
        case .gold: return 0.92
        case .turquoise, .jade: return 0.35
        case .coral: return 0.20
        case .pearl: return 0.55
        case .grain: return 0.05
        }
    }

    var roughness: Float {
        switch self {
        case .gold: return 0.28
        case .turquoise, .jade: return 0.40
        case .coral: return 0.45
        case .pearl: return 0.22
        case .grain: return 0.72
        }
    }
}

enum PlayMode: String, CaseIterable, Identifiable {
    case guided
    case free

    var id: String { rawValue }

    var title: String {
        switch self {
        case .guided: return "Guided"
        case .free: return "Free"
        }
    }
}
