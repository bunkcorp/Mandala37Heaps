import RealityKit
import UIKit

enum MandalaBuilder {
    static func makePlate(radius: Float = 0.52) -> Entity {
        let root = Entity()
        root.name = "MandalaPlate"

        let baseMesh = MeshResource.generateCylinder(height: 0.028, radius: radius)
        var gold = SimpleMaterial()
        gold.color = .init(tint: UIColor(red: 0.78, green: 0.60, blue: 0.18, alpha: 1))
        gold.metallic = .float(0.88)
        gold.roughness = .float(0.32)
        let base = ModelEntity(mesh: baseMesh, materials: [gold])
        base.name = "PlateBase"
        base.position = SIMD3(0, 0.014, 0)
        base.components.set(GroundingShadowComponent(castsShadow: true))
        root.addChild(base)

        let rimMesh = MeshResource.generateCylinder(height: 0.018, radius: radius * 1.03)
        var rimMat = SimpleMaterial()
        rimMat.color = .init(tint: UIColor(red: 0.92, green: 0.74, blue: 0.28, alpha: 1))
        rimMat.metallic = .float(0.9)
        rimMat.roughness = .float(0.25)
        let rim = ModelEntity(mesh: rimMesh, materials: [rimMat])
        rim.name = "PlateRim"
        rim.position = SIMD3(0, 0.032, 0)
        root.addChild(rim)

        let inlayMesh = MeshResource.generateCylinder(height: 0.004, radius: radius * 0.92)
        var inlay = SimpleMaterial()
        inlay.color = .init(tint: UIColor(red: 0.18, green: 0.55, blue: 0.52, alpha: 1))
        inlay.metallic = .float(0.4)
        inlay.roughness = .float(0.45)
        let inlayEntity = ModelEntity(mesh: inlayMesh, materials: [inlay])
        inlayEntity.name = "PlateInlay"
        inlayEntity.position = SIMD3(0, 0.029, 0)
        root.addChild(inlayEntity)

        for (i, color) in [
            UIColor(red: 0.85, green: 0.25, blue: 0.22, alpha: 1),
            UIColor(red: 0.95, green: 0.85, blue: 0.25, alpha: 1),
            UIColor(red: 0.25, green: 0.55, blue: 0.85, alpha: 1),
            UIColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1)
        ].enumerated() {
            let angle = Float(i) * (.pi / 2)
            let marker = ModelEntity(
                mesh: .generateBox(size: SIMD3(0.035, 0.006, 0.012)),
                materials: [SimpleMaterial(color: color, isMetallic: true)]
            )
            marker.position = SIMD3(cos(angle) * radius * 0.96, 0.034, sin(angle) * radius * 0.96)
            marker.orientation = simd_quatf(angle: -angle, axis: SIMD3(0, 1, 0))
            root.addChild(marker)
        }

        return root
    }

    /// One stacked offering level: metal fence ring + grain fill deck for heaps.
    static func makeTier(tier: MandalaTier, unlocked: Bool) -> Entity {
        let root = Entity()
        root.name = "Tier_\(tier.rawValue)_\(tier.shortTitle)"

        let surface = Entity()
        surface.name = "TierSurface"
        surface.position = SIMD3(0, tier.surfaceY, 0)
        root.addChild(surface)

        // Grain / gold fill disc that the next ring will rest on.
        var fillMat = SimpleMaterial()
        fillMat.color = .init(tint: UIColor(red: 0.88, green: 0.78, blue: 0.42, alpha: 1))
        fillMat.metallic = .float(0.15)
        fillMat.roughness = .float(0.65)
        let fill = ModelEntity(
            mesh: .generateCylinder(height: 0.012, radius: tier.deckRadius),
            materials: [fillMat]
        )
        fill.name = "TierFill"
        fill.position = SIMD3(0, 0.006, 0)
        fill.components.set(GroundingShadowComponent(castsShadow: true))
        surface.addChild(fill)

        let ring = makeMetalRing(
            radius: tier.ringRadius,
            height: tier.ringHeight
        )
        ring.position = SIMD3(0, tier.ringHeight * 0.5, 0)
        surface.addChild(ring)

        let slots = Entity()
        slots.name = "TierSlots"
        slots.position = SIMD3(0, 0.014, 0)
        surface.addChild(slots)

        if !unlocked {
            root.isEnabled = false
        }

        return root
    }

    /// Open metal hoop approximated with box segments around the circle.
    static func makeMetalRing(radius: Float, height: Float) -> Entity {
        let root = Entity()
        root.name = "MetalRing"

        var mat = SimpleMaterial()
        mat.color = .init(tint: UIColor(red: 0.85, green: 0.68, blue: 0.22, alpha: 1))
        mat.metallic = .float(0.92)
        mat.roughness = .float(0.28)

        let segments = 28
        let thickness: Float = 0.016
        let chord = 2 * radius * sin(.pi / Float(segments))
        for i in 0..<segments {
            let angle = Float(i) * (.pi * 2 / Float(segments))
            let segment = ModelEntity(
                mesh: .generateBox(size: SIMD3(thickness, height, chord * 1.08), cornerRadius: 0.002),
                materials: [mat]
            )
            segment.position = SIMD3(cos(angle) * radius, 0, sin(angle) * radius)
            segment.orientation = simd_quatf(angle: -angle, axis: SIMD3(0, 1, 0))
            root.addChild(segment)
        }

        return root
    }

    /// Traditional mandala-set finial: pearl dome + flame plate with turquoise gem.
    static func makeTopOrnament() -> Entity {
        let root = Entity()
        root.name = "TopOrnament"

        var gold = SimpleMaterial()
        gold.color = .init(tint: UIColor(red: 0.92, green: 0.74, blue: 0.28, alpha: 1))
        gold.metallic = .float(0.95)
        gold.roughness = .float(0.22)

        var pearl = SimpleMaterial()
        pearl.color = .init(tint: UIColor(red: 0.95, green: 0.94, blue: 0.90, alpha: 1))
        pearl.metallic = .float(0.55)
        pearl.roughness = .float(0.2)

        // Stepped pedestal
        for (i, radius) in ([0.07, 0.055, 0.04] as [Float]).enumerated() {
            let step = ModelEntity(
                mesh: .generateCylinder(height: 0.012, radius: radius),
                materials: [gold]
            )
            step.position = SIMD3(0, 0.006 + Float(i) * 0.012, 0)
            root.addChild(step)
        }

        // Pearl-covered dome (sphere nestled on the pedestal)
        let dome = ModelEntity(mesh: .generateSphere(radius: 0.055), materials: [pearl])
        dome.name = "PearlDome"
        dome.position = SIMD3(0, 0.078, 0)
        dome.components.set(GroundingShadowComponent(castsShadow: true))
        root.addChild(dome)

        // Stud the dome with pearl beads like a traditional set.
        for ring in 0..<3 {
            let count = 8 + ring * 4
            let ringRadius = 0.028 + Float(ring) * 0.014
            let ringY = 0.078 + Float(ring) * 0.012
            for i in 0..<count {
                let angle = Float(i) * (.pi * 2 / Float(count))
                let bead = ModelEntity(
                    mesh: .generateSphere(radius: 0.007),
                    materials: [pearl]
                )
                bead.position = SIMD3(
                    cos(angle) * ringRadius,
                    ringY,
                    sin(angle) * ringRadius
                )
                root.addChild(bead)
            }
        }

        // Vertical flame / thog: two crossed plates so it reads from any viewing angle.
        let flameRoot = Entity()
        flameRoot.name = "FlameFinial"
        flameRoot.position = SIMD3(0, 0.125, 0)

        for (i, yaw) in ([0, Float.pi / 2] as [Float]).enumerated() {
            let plate = ModelEntity(
                mesh: .generateBox(size: SIMD3(0.012, 0.13, 0.085), cornerRadius: 0.038),
                materials: [gold]
            )
            plate.name = "FlamePlate_\(i)"
            plate.position = SIMD3(0, 0.06, 0)
            plate.orientation = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))
            flameRoot.addChild(plate)
        }

        let flameTip = ModelEntity(
            mesh: .generateCone(height: 0.05, radius: 0.032),
            materials: [gold]
        )
        flameTip.position = SIMD3(0, 0.14, 0)
        flameRoot.addChild(flameTip)

        // Large bright turquoise gem — the signature centerpiece stone.
        let gem = ModelEntity(
            mesh: .generateSphere(radius: 0.022),
            materials: [UnlitMaterial(color: UIColor(red: 0.08, green: 0.88, blue: 0.42, alpha: 1))]
        )
        gem.name = "TurquoiseGem"
        gem.position = SIMD3(0, 0.062, 0)
        flameRoot.addChild(gem)

        let bezel = ModelEntity(
            mesh: .generateSphere(radius: 0.028),
            materials: [gold]
        )
        bezel.position = SIMD3(0, 0.062, 0)
        bezel.scale = SIMD3(1, 0.35, 1)
        flameRoot.addChild(bezel)

        root.addChild(flameRoot)
        return root
    }

    /// Distinctive Mount Meru: tiered cosmic mountain for the base-center heap.
    static func makeMountMeru(scale: Float = 1.45) -> Entity {
        let root = Entity()
        root.name = "Heap_MountMeru"

        var gold = SimpleMaterial()
        gold.color = .init(tint: UIColor(red: 0.90, green: 0.72, blue: 0.22, alpha: 1))
        gold.metallic = .float(0.9)
        gold.roughness = .float(0.3)

        let tiers: [(Float, Float, Float)] = [
            (0.045 * scale, 0.038 * scale, 0.019 * scale),
            (0.032 * scale, 0.032 * scale, 0.052 * scale),
            (0.020 * scale, 0.028 * scale, 0.080 * scale)
        ]
        for (radius, height, y) in tiers {
            let step = ModelEntity(
                mesh: .generateCylinder(height: height, radius: radius),
                materials: [gold]
            )
            step.position = SIMD3(0, y, 0)
            step.components.set(GroundingShadowComponent(castsShadow: true))
            root.addChild(step)
        }

        let peak = ModelEntity(
            mesh: .generateCone(height: 0.04 * scale, radius: 0.016 * scale),
            materials: [gold]
        )
        peak.position = SIMD3(0, 0.112 * scale, 0)
        root.addChild(peak)

        let jewel = ModelEntity(
            mesh: .generateSphere(radius: 0.01 * scale),
            materials: [UnlitMaterial(color: UIColor(red: 0.15, green: 0.8, blue: 0.5, alpha: 1))]
        )
        jewel.position = SIMD3(0, 0.135 * scale, 0)
        root.addChild(jewel)

        return root
    }

    static func makeSlotMarker(definition: HeapDefinition, highlighted: Bool, interactive: Bool) -> Entity {
        let root = Entity()
        root.name = "Slot_\(definition.number)"

        let markerRadius = 0.026 * definition.heapScale
        let diskMesh = MeshResource.generateCylinder(height: 0.004, radius: markerRadius)
        let diskMaterial: any Material
        if highlighted {
            diskMaterial = UnlitMaterial(
                color: UIColor(red: 0.05, green: 0.95, blue: 1.0, alpha: 1)
            )
        } else if interactive {
            var recess = SimpleMaterial()
            recess.color = .init(tint: UIColor(red: 0.55, green: 0.42, blue: 0.18, alpha: 1))
            recess.metallic = .float(0.35)
            recess.roughness = .float(0.55)
            diskMaterial = recess
        } else {
            var dim = SimpleMaterial()
            dim.color = .init(tint: UIColor(red: 0.45, green: 0.38, blue: 0.22, alpha: 0.45))
            dim.metallic = .float(0.2)
            dim.roughness = .float(0.7)
            diskMaterial = dim
        }
        let disk = ModelEntity(mesh: diskMesh, materials: [diskMaterial])
        disk.name = "SlotDisk"
        disk.position = SIMD3(0, 0.003, 0)
        root.addChild(disk)

        let pegMaterial: any Material
        if highlighted {
            pegMaterial = UnlitMaterial(color: UIColor.white)
        } else {
            pegMaterial = SimpleMaterial(
                color: UIColor(red: 0.75, green: 0.58, blue: 0.22, alpha: interactive ? 1 : 0.4),
                isMetallic: true
            )
        }
        let peg = ModelEntity(
            mesh: .generateCylinder(height: 0.008, radius: markerRadius * 0.22),
            materials: [pegMaterial]
        )
        peg.position = SIMD3(0, 0.008, 0)
        root.addChild(peg)

        if highlighted {
            let beacon = Entity()
            beacon.name = "ActiveTargetBeacon"

            let glowDisc = ModelEntity(
                mesh: .generateCylinder(height: 0.006, radius: max(0.045, markerRadius * 2.0)),
                materials: [UnlitMaterial(
                    color: UIColor(red: 0.05, green: 0.95, blue: 1.0, alpha: 0.82)
                )]
            )
            glowDisc.position = SIMD3(0, 0.014, 0)
            beacon.addChild(glowDisc)

            let column = ModelEntity(
                mesh: .generateCylinder(height: 0.10, radius: 0.007),
                materials: [UnlitMaterial(
                    color: UIColor(red: 0.18, green: 0.98, blue: 1.0, alpha: 0.9)
                )]
            )
            column.position = SIMD3(0, 0.065, 0)
            beacon.addChild(column)

            let orb = ModelEntity(
                mesh: .generateSphere(radius: 0.024),
                materials: [UnlitMaterial(
                    color: UIColor(red: 0.75, green: 1.0, blue: 1.0, alpha: 1)
                )]
            )
            orb.position = SIMD3(0, 0.125, 0)
            beacon.addChild(orb)

            let pointer = ModelEntity(
                mesh: .generateCone(height: 0.04, radius: 0.02),
                materials: [UnlitMaterial(color: UIColor.white)]
            )
            pointer.position = SIMD3(0, 0.095, 0)
            pointer.orientation = simd_quatf(angle: .pi, axis: SIMD3(1, 0, 0))
            beacon.addChild(pointer)

            root.addChild(beacon)
        }

        if interactive {
            let hitSize = highlighted ? max(0.09, markerRadius * 2.8) : max(0.05, markerRadius * 2.3)
            let shape = ShapeResource.generateBox(size: SIMD3(hitSize, 0.16, hitSize))
                .offsetBy(translation: SIMD3(0, 0.07, 0))
            root.components.set(CollisionComponent(shapes: [shape], mode: .trigger))
            root.components.set(InputTargetComponent())
        }

        root.components.set(HeapSlotComponent(index: definition.number - 1))
        return root
    }

    static func makeHeap(kind: HeapMaterialKind, scale: Float) -> Entity {
        let root = Entity()
        root.name = "Heap_\(kind.rawValue)"

        var mat = SimpleMaterial()
        mat.color = .init(tint: kind.tint)
        mat.metallic = .float(kind.metallic)
        mat.roughness = .float(kind.roughness)

        let mound = ModelEntity(
            mesh: .generateCone(height: 0.038 * scale, radius: 0.024 * scale),
            materials: [mat]
        )
        mound.position = SIMD3(0, 0.019 * scale, 0)
        mound.components.set(GroundingShadowComponent(castsShadow: true))
        root.addChild(mound)

        let jewel = ModelEntity(
            mesh: .generateSphere(radius: 0.012 * scale),
            materials: [mat]
        )
        jewel.position = SIMD3(0, 0.042 * scale, 0)
        root.addChild(jewel)

        for i in 0..<5 {
            let angle = Float(i) * (.pi * 2 / 5)
            let grain = ModelEntity(
                mesh: .generateSphere(radius: 0.005 * scale),
                materials: [mat]
            )
            grain.position = SIMD3(
                cos(angle) * 0.014 * scale,
                0.012 * scale,
                sin(angle) * 0.014 * scale
            )
            root.addChild(grain)
        }

        return root
    }

    static func makePaletteOrb(kind: HeapMaterialKind, selected: Bool) -> Entity {
        let root = Entity()
        root.name = "Palette_\(kind.rawValue)"

        var mat = SimpleMaterial()
        mat.color = .init(tint: kind.tint)
        mat.metallic = .float(kind.metallic)
        mat.roughness = .float(kind.roughness)

        let orb = ModelEntity(mesh: .generateSphere(radius: 0.028), materials: [mat])
        orb.components.set(GroundingShadowComponent(castsShadow: true))
        root.addChild(orb)

        if selected {
            let halo = ModelEntity(
                mesh: .generateSphere(radius: 0.038),
                materials: [UnlitMaterial(color: UIColor(white: 1, alpha: 0.35))]
            )
            root.addChild(halo)
        }

        let shape = ShapeResource.generateSphere(radius: 0.04)
        root.components.set(CollisionComponent(shapes: [shape], mode: .trigger))
        root.components.set(InputTargetComponent())
        root.components.set(PaletteItemComponent(materialKindRaw: kind.rawValue))

        return root
    }

    static func makeCelebrationBurst() -> Entity {
        let root = Entity()
        root.name = "CelebrationBurst"

        let colors: [UIColor] = [
            UIColor(red: 0.95, green: 0.8, blue: 0.3, alpha: 0.9),
            UIColor(red: 0.3, green: 0.8, blue: 0.75, alpha: 0.85),
            UIColor(red: 0.95, green: 0.45, blue: 0.4, alpha: 0.85),
            UIColor(red: 0.95, green: 0.95, blue: 0.9, alpha: 0.9)
        ]

        for i in 0..<12 {
            let angle = Float(i) * (.pi * 2 / 12)
            let sphere = ModelEntity(
                mesh: .generateSphere(radius: 0.018),
                materials: [UnlitMaterial(color: colors[i % colors.count])]
            )
            sphere.position = SIMD3(cos(angle) * 0.08, 0.05, sin(angle) * 0.08)
            root.addChild(sphere)
        }

        let core = ModelEntity(
            mesh: .generateSphere(radius: 0.06),
            materials: [UnlitMaterial(color: UIColor(red: 1, green: 0.95, blue: 0.7, alpha: 0.55))]
        )
        core.position = SIMD3(0, 0.08, 0)
        root.addChild(core)

        return root
    }
}
