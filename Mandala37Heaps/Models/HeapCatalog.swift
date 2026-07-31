import Foundation
import RealityKit
import UIKit

/// Physical offering-set tier matching the traditional stacked-ring mandala.
///
/// Angle convention (local XZ, `x = r·cosθ`, `z = r·sinθ`):
/// East = bottom of the reference diagram = toward viewer (+Z) = **90°**.
/// Right = +X = 0°, Left = −X = 180°, Top (away) = −Z = 270°.
enum MandalaTier: Int, CaseIterable, Identifiable {
    /// Base plate + largest ring: Meru, continents, subcontinents, four treasures (heaps 1–17).
    case universe = 0
    /// Second ring: seven royal emblems + vase (18–25).
    case treasures = 1
    /// Third ring: eight offering goddesses (26–33).
    case goddesses = 2
    /// Upper section: sun, moon, parasol, victory banner (34–37); centerpiece last.
    case celestial = 3

    var id: Int { rawValue }

    /// Inclusive 1-based heap numbers on this tier.
    var heapNumbers: ClosedRange<Int> {
        switch self {
        case .universe: return 1...17
        case .treasures: return 18...25
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
        case .universe: return 0.52
        case .treasures: return 0.34
        case .goddesses: return 0.24
        case .celestial: return 0.15
        }
    }

    /// Usable inner deck radius for placing heaps (base ring uses more of the plate).
    var deckRadius: Float {
        switch self {
        case .universe: return ringRadius * 0.90
        default: return ringRadius * 0.82
        }
    }

    /// Local Y of this tier band's bottom (ring wall bottom) relative to the mandala root.
    ///
    /// Geometry (see `MandalaBuilder.makeTier`):
    /// - Ring wall is a box fence of height `ringWallHeight`, centered at local Y = h/2,
    ///   so it spans **[0, ringWallHeight]** (bottom on the band origin, not half below it).
    /// - Fill deck is `deckThickness` tall with its top near the rim (not a 1.2 cm wafer at Y=0).
    /// - Next tier root sits at `surfaceY + tierStep`, where `tierStep` is wall height minus an
    ///   8 mm overlap so rims bite instead of showing a hairline gap under perspective.
    var surfaceY: Float {
        Self.baseSurfaceY + Float(rawValue) * Self.tierStep
    }

    /// First-ring band origin above mandala root (plate rim top ≈ 0.041).
    static let baseSurfaceY: Float = 0.041

    /// Metal fence wall height.
    var ringHeight: Float { Self.ringWallHeight }

    static let ringWallHeight: Float = 0.075

    /// Negative stack overlap so upper wall bottom bites into lower wall/deck (~8 mm).
    /// Prior 0–2 mm still read as a float under perspective + grounding shadows.
    static let stackOverlap: Float = 0.008

    /// Vertical advance per tier (= wall height − overlap).
    static let tierStep: Float = ringWallHeight - stackOverlap

    /// Grain fill thickness — flush with the wall rim so the next ring sits on the deck.
    static let deckThickness: Float = ringWallHeight

    /// Local Y of the fill top / heap seat plane relative to the tier band origin.
    var deckTopY: Float { Self.deckThickness }

    /// Local Y for `TierSlots` (just above the fill top).
    var slotsY: Float { Self.deckThickness + 0.001 }

    /// Fill mesh radius: out to the inner face of the metal wall (no annular trench).
    var fillRadius: Float { max(deckRadius, ringRadius - 0.010) }

    var next: MandalaTier? {
        MandalaTier(rawValue: rawValue + 1)
    }
}

/// Traditional Tibetan 37-heap mandala offering definitions and tiered layout.
/// Layout matches the four-ring reference diagram (east = bottom / toward viewer).
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

        // —— Tier 0 / first ring: Meru, continents, subcontinents, four treasures (1–17) ——
        items.append(HeapDefinition(
            number: 1, name: "Mount Meru", preferredMaterial: .gold,
            tier: .universe, radiusFraction: 0, angleDegrees: 0, heapScale: 1.00
        ))

        // Outer rim continents — East at bottom (90°).
        let continents: [(String, HeapMaterialKind, Float)] = [
            ("Eastern Continent (Pūrvavideha)", .turquoise, 90),   // 2 bottom
            ("Southern Continent (Jambudvīpa)", .coral, 180),      // 3 left
            ("Western Continent (Aparagodānīya)", .pearl, 270),    // 4 top
            ("Northern Continent (Uttarakuru)", .jade, 0)          // 5 right
        ]
        for (i, c) in continents.enumerated() {
            items.append(HeapDefinition(
                number: 2 + i, name: c.0, preferredMaterial: c.1,
                tier: .universe, radiusFraction: 0.62, angleDegrees: c.2, heapScale: 0.88
            ))
        }

        // Subcontinents flanking each continent (outer rim).
        // East(2): left 6 / right 7; Left(3): above 8 / below 9;
        // Top(4): left 11 / right 10; Right(5): above 13 / below 12.
        let subs: [(String, Float)] = [
            ("East Subcontinent A", 112),   // 6 left flank of east
            ("East Subcontinent B", 68),    // 7 right flank of east
            ("South Subcontinent A", 202),  // 8 above left continent
            ("South Subcontinent B", 158),  // 9 below left continent
            ("West Subcontinent A", 292),   // 10 right flank of top
            ("West Subcontinent B", 248),   // 11 left flank of top
            ("North Subcontinent A", 22),   // 12 below right continent
            ("North Subcontinent B", 338)   // 13 above right continent
        ]
        for (i, s) in subs.enumerated() {
            items.append(HeapDefinition(
                number: 6 + i, name: s.0, preferredMaterial: .grain,
                tier: .universe, radiusFraction: 0.90, angleDegrees: s.1, heapScale: 0.72
            ))
        }

        // Inner cross between Meru and outer rim (still on base ring).
        let innerCross: [(String, HeapMaterialKind, Float)] = [
            ("Jewel Mountain", .gold, 90),                 // 14 bottom (east)
            ("Wish-Fulfilling Tree", .jade, 180),          // 15 left
            ("Wish-Fulfilling Cow", .pearl, 270),          // 16 top
            ("Harvest That Needs No Cultivation", .grain, 0) // 17 right
        ]
        for (i, t) in innerCross.enumerated() {
            items.append(HeapDefinition(
                number: 14 + i, name: t.0, preferredMaterial: t.1,
                tier: .universe, radiusFraction: 0.32, angleDegrees: t.2, heapScale: 0.78
            ))
        }

        // —— Tier 1 / second ring: royal emblems + vase (18–25) ——
        let emblems: [(String, HeapMaterialKind, Float)] = [
            ("Precious Wheel", .gold, 90),        // 18 bottom
            ("Precious Jewel", .turquoise, 180),  // 19 left
            ("Precious Queen", .coral, 270),      // 20 top
            ("Precious Minister", .pearl, 0),     // 21 right
            ("Precious Elephant", .jade, 135),    // 22 BL
            ("Precious Horse", .grain, 225),      // 23 TL
            ("Precious General", .gold, 315),     // 24 TR
            ("Great Treasure Vase", .turquoise, 45) // 25 BR
        ]
        for (i, e) in emblems.enumerated() {
            items.append(HeapDefinition(
                number: 18 + i, name: e.0, preferredMaterial: e.1,
                tier: .treasures, radiusFraction: 0.70, angleDegrees: e.2, heapScale: 0.68
            ))
        }

        // —— Tier 2 / third ring: eight offering goddesses (26–33) ——
        let goddesses: [(String, HeapMaterialKind, Float)] = [
            ("Goddess of Beauty", .coral, 90),       // 26 bottom
            ("Goddess of Garlands", .pearl, 180),    // 27 left
            ("Goddess of Song", .turquoise, 270),    // 28 top
            ("Goddess of Dance", .jade, 0),          // 29 right
            ("Goddess of Flowers", .coral, 135),     // 30 BL
            ("Goddess of Incense", .grain, 225),     // 31 TL
            ("Goddess of Light", .gold, 315),        // 32 TR
            ("Goddess of Perfume", .pearl, 45)       // 33 BR
        ]
        for (i, g) in goddesses.enumerated() {
            items.append(HeapDefinition(
                number: 26 + i, name: g.0, preferredMaterial: g.1,
                tier: .goddesses, radiusFraction: 0.68, angleDegrees: g.2, heapScale: 0.62
            ))
        }

        // —— Tier 3 / top ring: sun, moon, parasol, victory banner (34–37) ——
        // Centerpiece (38) is placed last in AppModel after all 37 heaps.
        let celestial: [(String, HeapMaterialKind, Float)] = [
            ("Sun", .gold, 180),                 // 34 left
            ("Moon", .pearl, 0),                 // 35 right
            ("Precious Parasol", .turquoise, 270), // 36 top
            ("Victory Banner", .coral, 90)       // 37 bottom (east)
        ]
        for (i, o) in celestial.enumerated() {
            items.append(HeapDefinition(
                number: 34 + i, name: o.0, preferredMaterial: o.1,
                tier: .celestial, radiusFraction: 0.68, angleDegrees: o.2, heapScale: 0.58
            ))
        }

        precondition(items.count == 37)
        // Offering order must stay 1…37 by number.
        precondition(items.map(\.number) == Array(1...37))
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
