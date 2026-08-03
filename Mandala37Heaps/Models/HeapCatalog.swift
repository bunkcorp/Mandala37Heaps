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
    /// Usable deck between this ring wall and the next smaller ring (or center).
    var heapAnnulusInner: Float {
        if let next = MandalaTier(rawValue: rawValue + 1) {
            return next.ringRadius + 0.016
        }
        return 0.035
    }

    var heapAnnulusOuter: Float {
        max(heapAnnulusInner + 0.02, ringRadius - 0.022)
    }

    var heapAnnulusWidth: Float { heapAnnulusOuter - heapAnnulusInner }

    /// Max mound radius that still fits inside the annulus with margin.
    var maxHeapFootprintRadius: Float { heapAnnulusWidth * 0.32 }
}

/// Traditional Tibetan 37-heap mandala offering definitions and tiered layout.
/// Layout matches the four-ring reference diagram (east = bottom / toward viewer).
struct HeapDefinition {
    let number: Int
    let name: String
    let preferredMaterial: HeapMaterialKind
    let tier: MandalaTier
    /// 0…1 across the tier annulus (0 = against inner wall, 1 = against outer rim).
    /// For universe inner-cross heaps (14–17), 0…1 across the center disk under the next ring.
    let radiusFraction: Float
    let angleDegrees: Float
    let heapScale: Float
    /// When true, place in the center disk inside the next ring instead of the outer annulus.
    let usesInnerDisk: Bool

    /// Canonical 37 heaps in offering order, assigned to stacked tiers.
    static let all: [HeapDefinition] = {
        var items: [HeapDefinition] = []

        // —— Tier 0 / first ring: Meru, continents, subcontinents, four treasures (1–17) ——
        items.append(HeapDefinition(
            number: 1, name: "Mount Meru", preferredMaterial: .gold,
            tier: .universe, radiusFraction: 0, angleDegrees: 0, heapScale: 0.55,
            usesInnerDisk: true
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
                tier: .universe, radiusFraction: 0.42, angleDegrees: c.2, heapScale: 0.85,
                usesInnerDisk: false
            ))
        }

        // Subcontinents flanking each continent (outer rim).
        let subs: [(String, Float)] = [
            ("East Subcontinent A", 112),
            ("East Subcontinent B", 68),
            ("South Subcontinent A", 202),
            ("South Subcontinent B", 158),
            ("West Subcontinent A", 292),
            ("West Subcontinent B", 248),
            ("North Subcontinent A", 22),
            ("North Subcontinent B", 338)
        ]
        for (i, s) in subs.enumerated() {
            items.append(HeapDefinition(
                number: 6 + i, name: s.0, preferredMaterial: .grain,
                tier: .universe, radiusFraction: 0.78, angleDegrees: s.1, heapScale: 0.65,
                usesInnerDisk: false
            ))
        }

        // Inner cross between Meru and outer rim (still on base ring, inside next ring).
        let innerCross: [(String, HeapMaterialKind, Float)] = [
            ("Jewel Mountain", .gold, 90),
            ("Wish-Fulfilling Tree", .jade, 180),
            ("Wish-Fulfilling Cow", .pearl, 270),
            ("Harvest That Needs No Cultivation", .grain, 0)
        ]
        for (i, t) in innerCross.enumerated() {
            items.append(HeapDefinition(
                number: 14 + i, name: t.0, preferredMaterial: t.1,
                tier: .universe, radiusFraction: 0.55, angleDegrees: t.2, heapScale: 0.70,
                usesInnerDisk: true
            ))
        }

        // —— Tier 1 / second ring: royal emblems + vase (18–25) ——
        let emblems: [(String, HeapMaterialKind, Float)] = [
            ("Precious Wheel", .gold, 90),
            ("Precious Jewel", .turquoise, 180),
            ("Precious Queen", .coral, 270),
            ("Precious Minister", .pearl, 0),
            ("Precious Elephant", .jade, 135),
            ("Precious Horse", .grain, 225),
            ("Precious General", .gold, 315),
            ("Great Treasure Vase", .turquoise, 45)
        ]
        for (i, e) in emblems.enumerated() {
            items.append(HeapDefinition(
                number: 18 + i, name: e.0, preferredMaterial: e.1,
                tier: .treasures, radiusFraction: 0.48, angleDegrees: e.2, heapScale: 0.80,
                usesInnerDisk: false
            ))
        }

        // —— Tier 2 / third ring: eight offering goddesses (26–33) ——
        let goddesses: [(String, HeapMaterialKind, Float)] = [
            ("Goddess of Beauty", .coral, 90),
            ("Goddess of Garlands", .pearl, 180),
            ("Goddess of Song", .turquoise, 270),
            ("Goddess of Dance", .jade, 0),
            ("Goddess of Flowers", .coral, 135),
            ("Goddess of Incense", .grain, 225),
            ("Goddess of Light", .gold, 315),
            ("Goddess of Perfume", .pearl, 45)
        ]
        for (i, g) in goddesses.enumerated() {
            items.append(HeapDefinition(
                number: 26 + i, name: g.0, preferredMaterial: g.1,
                tier: .goddesses, radiusFraction: 0.48, angleDegrees: g.2, heapScale: 0.78,
                usesInnerDisk: false
            ))
        }

        // —— Tier 3 / top ring: sun, moon, parasol, victory banner (34–37) ——
        let celestial: [(String, HeapMaterialKind, Float)] = [
            ("Sun", .gold, 180),
            ("Moon", .pearl, 0),
            ("Precious Parasol", .turquoise, 270),
            ("Victory Banner", .coral, 90)
        ]
        for (i, o) in celestial.enumerated() {
            items.append(HeapDefinition(
                number: 34 + i, name: o.0, preferredMaterial: o.1,
                tier: .celestial, radiusFraction: 0.55, angleDegrees: o.2, heapScale: 0.72,
                usesInnerDisk: false
            ))
        }

        precondition(items.count == 37)
        precondition(items.map(\.number) == Array(1...37))
        return items
    }()

    /// Local position on the tier's fill surface (y ≈ 0), constrained inside the ring deck.
    var localPosition: SIMD3<Float> {
        let rad = angleDegrees * .pi / 180
        let r: Float
        if number == 1 {
            r = 0
        } else if usesInnerDisk {
            let inner: Float = 0.07
            let outer = max(inner + 0.02, tier.heapAnnulusInner - 0.012)
            r = inner + (outer - inner) * min(1, max(0, radiusFraction))
        } else {
            let inner = tier.heapAnnulusInner
            let outer = tier.heapAnnulusOuter
            r = inner + (outer - inner) * min(1, max(0, radiusFraction))
        }
        return SIMD3(r * cos(rad), 0, r * sin(rad))
    }

    /// Scale clamped so the mound footprint fits the ring annulus / inner disk.
    var containedHeapScale: Float {
        let maxR = usesInnerDisk
            ? max(0.02, (tier.heapAnnulusInner - 0.08) * 0.35)
            : tier.maxHeapFootprintRadius
        // makeHeap uses ~0.058 * scale as footprint radius.
        let nominalFootprint: Float = 0.058
        let fit = maxR / nominalFootprint
        return min(heapScale, fit)
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
