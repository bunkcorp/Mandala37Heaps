import RealityKit
import simd
import UIKit

enum MandalaBuilder {
    /// Traditional square brocade table cover under the mandala (ground cloth).
    /// Royal-blue outer field with Ashtamangala (eight auspicious symbols) in gold,
    /// red + yellow borders, and a central triangle patchwork mosaic.
    static func makeTableCover(size: Float = 1.18) -> Entity {
        let root = Entity()
        root.name = "MandalaTableCover"
        // Sit just under the plate feet so the set rests on the cloth.
        root.position = SIMD3(0, -0.0015, 0)

        let clothY: Float = 0.0012

        // Outer royal-blue brocade field.
        var blueMat = SimpleMaterial()
        blueMat.color = .init(tint: UIColor(red: 0.08, green: 0.18, blue: 0.55, alpha: 1))
        blueMat.roughness = .float(0.72)
        blueMat.metallic = .float(0.08)
        let outer = ModelEntity(
            mesh: .generateBox(size: SIMD3(size, clothY, size), cornerRadius: 0.004),
            materials: [blueMat]
        )
        outer.name = "CoverBlueField"
        outer.position = SIMD3(0, clothY * 0.5, 0)
        root.addChild(outer)

        var motifGold = SimpleMaterial()
        motifGold.color = .init(tint: UIColor(red: 0.86, green: 0.78, blue: 0.42, alpha: 1))
        motifGold.metallic = .float(0.72)
        motifGold.roughness = .float(0.38)

        var motifSilver = SimpleMaterial()
        motifSilver.color = .init(tint: UIColor(red: 0.82, green: 0.84, blue: 0.88, alpha: 1))
        motifSilver.metallic = .float(0.65)
        motifSilver.roughness = .float(0.42)

        // Dense cloud / vine fill so the blue field reads as woven brocade.
        addCoverCloudFiligree(
            to: root,
            size: size,
            y: clothY + 0.0006,
            gold: motifGold,
            silver: motifSilver
        )

        // Eight Auspicious Symbols around the blue margin (outside the central square).
        let symbols = AshtamangalaSymbol.allCases
        let symbolRadius = size * 0.38
        let mosaicKeepout = size * 0.28
        for (i, symbol) in symbols.enumerated() {
            let angle = Float(i) * (.pi * 2 / Float(symbols.count)) - .pi / 2
            let x = cos(angle) * symbolRadius
            let z = sin(angle) * symbolRadius
            // Skip if somehow under mosaic (safety).
            if abs(x) < mosaicKeepout && abs(z) < mosaicKeepout { continue }
            let glyph = makeAshtamangalaSymbol(symbol, gold: motifGold, silver: motifSilver)
            glyph.name = "Ashtamangala_\(symbol.rawValue)"
            glyph.position = SIMD3(x, clothY + 0.0010, z)
            glyph.orientation = simd_quatf(angle: -angle + .pi / 2, axis: SIMD3(0, 1, 0))
            glyph.scale = SIMD3(repeating: 1.15)
            root.addChild(glyph)
        }

        // Smaller repeat of the eight symbols nearer the outer edge / corners.
        let cornerRadius = size * 0.46
        for (i, symbol) in symbols.enumerated() {
            let angle = Float(i) * (.pi * 2 / Float(symbols.count)) - .pi / 2 + .pi / 8
            let x = cos(angle) * cornerRadius
            let z = sin(angle) * cornerRadius
            let glyph = makeAshtamangalaSymbol(symbol, gold: motifGold, silver: motifSilver)
            glyph.name = "AshtamangalaMini_\(symbol.rawValue)"
            glyph.position = SIMD3(x, clothY + 0.0009, z)
            glyph.orientation = simd_quatf(angle: -angle + .pi / 2, axis: SIMD3(0, 1, 0))
            glyph.scale = SIMD3(repeating: 0.72)
            root.addChild(glyph)
        }

        // Nested borders + central mosaic occupy the inner square.
        let mosaicOuter = size * 0.52
        let redBorderWidth = size * 0.045
        let yellowBorderWidth = size * 0.038
        let mosaicSize = mosaicOuter - 2 * (redBorderWidth + yellowBorderWidth)

        addCoverBorderFrame(
            to: root,
            outer: mosaicOuter,
            width: redBorderWidth,
            y: clothY + 0.0006,
            color: UIColor(red: 0.82, green: 0.12, blue: 0.12, alpha: 1),
            name: "CoverRedBorder"
        )
        addCoverBorderFrame(
            to: root,
            outer: mosaicOuter - 2 * redBorderWidth,
            width: yellowBorderWidth,
            y: clothY + 0.0009,
            color: UIColor(red: 0.92, green: 0.78, blue: 0.18, alpha: 1),
            name: "CoverYellowBorder"
        )

        if let mosaic = makeTriangleMosaicEntity(extent: mosaicSize, divisions: 10) {
            mosaic.position = SIMD3(0, clothY + 0.0014, 0)
            root.addChild(mosaic)
        }

        return root
    }

    /// Tibetan Eight Auspicious Symbols (Ashtamangala).
    private enum AshtamangalaSymbol: String, CaseIterable {
        case parasol
        case conch
        case fish
        case endlessKnot
        case treasureVase
        case victoryBanner
        case lotus
        case dharmaWheel
    }

    private static func makeAshtamangalaSymbol(
        _ symbol: AshtamangalaSymbol,
        gold: SimpleMaterial,
        silver: SimpleMaterial
    ) -> Entity {
        switch symbol {
        case .parasol: return makeSymbolParasol(gold: gold, silver: silver)
        case .conch: return makeSymbolConch(gold: gold, silver: silver)
        case .fish: return makeSymbolTwinFish(gold: gold)
        case .endlessKnot: return makeSymbolEndlessKnot(gold: gold)
        case .treasureVase: return makeSymbolTreasureVase(gold: gold, silver: silver)
        case .victoryBanner: return makeSymbolVictoryBanner(gold: gold, silver: silver)
        case .lotus: return makeSymbolLotus(gold: gold, silver: silver)
        case .dharmaWheel: return makeSymbolDharmaWheel(gold: gold, silver: silver)
        }
    }

    private static func makeSymbolParasol(gold: SimpleMaterial, silver: SimpleMaterial) -> Entity {
        let root = Entity()
        let stem = ModelEntity(
            mesh: .generateCylinder(height: 0.055, radius: 0.0032),
            materials: [gold]
        )
        stem.position = SIMD3(0, 0.001, 0)
        root.addChild(stem)
        let canopy = ModelEntity(
            mesh: .generateSphere(radius: 0.028),
            materials: [gold]
        )
        canopy.scale = SIMD3(1.15, 0.28, 1.15)
        canopy.position = SIMD3(0, 0.001, -0.012)
        root.addChild(canopy)
        let finial = ModelEntity(mesh: .generateSphere(radius: 0.006), materials: [silver])
        finial.position = SIMD3(0, 0.001, -0.028)
        root.addChild(finial)
        // Flat on cloth (XZ plane): tip canopy toward -Z in local, then parent yaws.
        root.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3(1, 0, 0))
        return root
    }

    private static func makeSymbolConch(gold: SimpleMaterial, silver: SimpleMaterial) -> Entity {
        let root = Entity()
        let body = ModelEntity(mesh: .generateSphere(radius: 0.018), materials: [silver])
        body.scale = SIMD3(1.35, 0.55, 1.0)
        body.position = SIMD3(0, 0.001, 0)
        root.addChild(body)
        let spiral = ModelEntity(mesh: .generateSphere(radius: 0.010), materials: [gold])
        spiral.scale = SIMD3(1.1, 0.45, 1.1)
        spiral.position = SIMD3(0.012, 0.0012, 0.004)
        root.addChild(spiral)
        let mouth = ModelEntity(
            mesh: .generateCone(height: 0.016, radius: 0.008),
            materials: [gold]
        )
        mouth.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3(0, 0, 1))
        mouth.position = SIMD3(-0.018, 0.001, 0)
        root.addChild(mouth)
        return root
    }

    private static func makeSymbolTwinFish(gold: SimpleMaterial) -> Entity {
        let root = Entity()
        for (i, side) in [-1, 1].enumerated() {
            let fish = Entity()
            let body = ModelEntity(mesh: .generateSphere(radius: 0.012), materials: [gold])
            body.scale = SIMD3(1.8, 0.45, 0.85)
            fish.addChild(body)
            let tail = ModelEntity(
                mesh: .generateCone(height: 0.014, radius: 0.007),
                materials: [gold]
            )
            tail.orientation = simd_quatf(angle: .pi, axis: SIMD3(0, 0, 1))
            tail.position = SIMD3(-0.018, 0, 0)
            fish.addChild(tail)
            fish.position = SIMD3(0, 0.001, Float(side) * 0.012)
            fish.orientation = simd_quatf(
                angle: Float(i == 0 ? 0.35 : -0.35 + .pi),
                axis: SIMD3(0, 1, 0)
            )
            root.addChild(fish)
        }
        return root
    }

    private static func makeSymbolEndlessKnot(gold: SimpleMaterial) -> Entity {
        let root = Entity()
        // Interlaced diamond lattice approximating the eternal knot.
        let bars: [(SIMD3<Float>, Float)] = [
            (SIMD3(0.036, 0.0012, 0.008), 0),
            (SIMD3(0.036, 0.0012, 0.008), .pi / 2),
            (SIMD3(0.028, 0.0012, 0.007), .pi / 4),
            (SIMD3(0.028, 0.0012, 0.007), -.pi / 4),
            (SIMD3(0.022, 0.0012, 0.006), .pi / 2.5),
            (SIMD3(0.022, 0.0012, 0.006), -.pi / 2.5)
        ]
        for (size, yaw) in bars {
            let bar = ModelEntity(mesh: .generateBox(size: size, cornerRadius: 0.0015), materials: [gold])
            bar.orientation = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))
            bar.position = SIMD3(0, 0.001, 0)
            root.addChild(bar)
        }
        for corner in [SIMD3<Float>(0.014, 0.0012, 0.014), SIMD3(0.014, 0.0012, -0.014),
                       SIMD3(-0.014, 0.0012, 0.014), SIMD3(-0.014, 0.0012, -0.014)] {
            let bead = ModelEntity(mesh: .generateSphere(radius: 0.0045), materials: [gold])
            bead.scale = SIMD3(1, 0.4, 1)
            bead.position = corner
            root.addChild(bead)
        }
        return root
    }

    private static func makeSymbolTreasureVase(gold: SimpleMaterial, silver: SimpleMaterial) -> Entity {
        let root = Entity()
        let belly = ModelEntity(mesh: .generateSphere(radius: 0.016), materials: [gold])
        belly.scale = SIMD3(1.05, 0.55, 1.05)
        belly.position = SIMD3(0, 0.001, 0.002)
        root.addChild(belly)
        let neck = ModelEntity(
            mesh: .generateCylinder(height: 0.014, radius: 0.006),
            materials: [gold]
        )
        neck.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3(1, 0, 0))
        neck.position = SIMD3(0, 0.001, -0.012)
        root.addChild(neck)
        let rim = ModelEntity(
            mesh: .generateCylinder(height: 0.004, radius: 0.010),
            materials: [silver]
        )
        rim.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3(1, 0, 0))
        rim.position = SIMD3(0, 0.001, -0.020)
        root.addChild(rim)
        let jewel = ModelEntity(mesh: .generateSphere(radius: 0.005), materials: [silver])
        jewel.position = SIMD3(0, 0.0012, -0.024)
        root.addChild(jewel)
        return root
    }

    private static func makeSymbolVictoryBanner(gold: SimpleMaterial, silver: SimpleMaterial) -> Entity {
        let root = Entity()
        let pole = ModelEntity(
            mesh: .generateCylinder(height: 0.055, radius: 0.003),
            materials: [gold]
        )
        pole.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3(1, 0, 0))
        pole.position = SIMD3(0, 0.001, 0)
        root.addChild(pole)
        for i in 0..<3 {
            let t = Float(i) / 2.0
            let cylinder = ModelEntity(
                mesh: .generateCylinder(height: 0.010, radius: 0.014 - t * 0.003),
                materials: [i % 2 == 0 ? gold : silver]
            )
            cylinder.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3(1, 0, 0))
            cylinder.position = SIMD3(0, 0.001, -0.008 - Float(i) * 0.011)
            root.addChild(cylinder)
        }
        let top = ModelEntity(mesh: .generateSphere(radius: 0.006), materials: [gold])
        top.position = SIMD3(0, 0.001, -0.042)
        root.addChild(top)
        return root
    }

    private static func makeSymbolLotus(gold: SimpleMaterial, silver: SimpleMaterial) -> Entity {
        let root = Entity()
        let petalCount = 8
        for i in 0..<petalCount {
            let angle = Float(i) * (.pi * 2 / Float(petalCount))
            let petal = ModelEntity(mesh: .generateSphere(radius: 0.011), materials: [gold])
            petal.scale = SIMD3(0.55, 0.28, 1.35)
            petal.position = SIMD3(cos(angle) * 0.012, 0.001, sin(angle) * 0.012)
            petal.orientation = simd_quatf(angle: -angle, axis: SIMD3(0, 1, 0))
            root.addChild(petal)
        }
        let center = ModelEntity(mesh: .generateSphere(radius: 0.008), materials: [silver])
        center.scale = SIMD3(1, 0.35, 1)
        center.position = SIMD3(0, 0.0012, 0)
        root.addChild(center)
        return root
    }

    private static func makeSymbolDharmaWheel(gold: SimpleMaterial, silver: SimpleMaterial) -> Entity {
        let root = Entity()
        let hub = ModelEntity(mesh: .generateCylinder(height: 0.002, radius: 0.008), materials: [silver])
        hub.position = SIMD3(0, 0.001, 0)
        root.addChild(hub)
        let rim = ModelEntity(
            mesh: .generateCylinder(height: 0.0018, radius: 0.026),
            materials: [gold]
        )
        rim.position = SIMD3(0, 0.0009, 0)
        root.addChild(rim)
        // Hollow the rim visually with a blue-ish inner disc (thin dark ring read).
        var inner = SimpleMaterial()
        inner.color = .init(tint: UIColor(red: 0.08, green: 0.18, blue: 0.55, alpha: 1))
        let hole = ModelEntity(
            mesh: .generateCylinder(height: 0.0022, radius: 0.020),
            materials: [inner]
        )
        hole.position = SIMD3(0, 0.0011, 0)
        root.addChild(hole)
        for i in 0..<8 {
            let angle = Float(i) * (.pi / 4)
            let spoke = ModelEntity(
                mesh: .generateBox(size: SIMD3(0.048, 0.0014, 0.0045), cornerRadius: 0.001),
                materials: [gold]
            )
            spoke.orientation = simd_quatf(angle: angle, axis: SIMD3(0, 1, 0))
            spoke.position = SIMD3(0, 0.0013, 0)
            root.addChild(spoke)
        }
        return root
    }

    /// Dense gold/silver cloud-scroll fill for the blue silk field.
    private static func addCoverCloudFiligree(
        to parent: Entity,
        size: Float,
        y: Float,
        gold: SimpleMaterial,
        silver: SimpleMaterial
    ) {
        let keepout = size * 0.27
        let step = size / 9.5
        let extent = size * 0.48
        var idx = 0
        for iz in -5...5 {
            for ix in -5...5 {
                let x = Float(ix) * step + (iz % 2 == 0 ? step * 0.35 : 0)
                let z = Float(iz) * step
                if abs(x) > extent || abs(z) > extent { continue }
                if abs(x) < keepout && abs(z) < keepout { continue }
                let swirl = makeCoverCloudScroll(
                    material: idx % 3 == 0 ? silver : gold,
                    compact: idx % 2 == 0
                )
                swirl.position = SIMD3(x, y, z)
                swirl.orientation = simd_quatf(
                    angle: Float(idx % 4) * (.pi / 2) + 0.2,
                    axis: SIMD3(0, 1, 0)
                )
                swirl.scale = SIMD3(repeating: idx % 5 == 0 ? 0.85 : 0.65)
                parent.addChild(swirl)
                idx += 1
            }
        }
    }

    private static func makeCoverCloudScroll(material: SimpleMaterial, compact: Bool) -> Entity {
        let root = Entity()
        let a = ModelEntity(
            mesh: .generateBox(size: SIMD3(compact ? 0.022 : 0.030, 0.0009, 0.006), cornerRadius: 0.002),
            materials: [material]
        )
        root.addChild(a)
        let b = ModelEntity(
            mesh: .generateBox(size: SIMD3(0.006, 0.0009, compact ? 0.018 : 0.024), cornerRadius: 0.002),
            materials: [material]
        )
        b.position = SIMD3(0.008, 0, 0.006)
        root.addChild(b)
        let curl = ModelEntity(mesh: .generateSphere(radius: 0.006), materials: [material])
        curl.scale = SIMD3(1, 0.28, 1)
        curl.position = SIMD3(-0.010, 0, -0.004)
        root.addChild(curl)
        return root
    }

    private static func addCoverBorderFrame(
        to parent: Entity,
        outer: Float,
        width: Float,
        y: Float,
        color: UIColor,
        name: String
    ) {
        var mat = SimpleMaterial()
        mat.color = .init(tint: color)
        mat.roughness = .float(0.55)
        mat.metallic = .float(0.12)
        let frame = Entity()
        frame.name = name
        let half = outer * 0.5
        let inner = outer - 2 * width
        // Four strips around the square.
        let strips: [(SIMD3<Float>, SIMD3<Float>)] = [
            (SIMD3(outer, 0.0014, width), SIMD3(0, y, half - width * 0.5)),   // +Z
            (SIMD3(outer, 0.0014, width), SIMD3(0, y, -(half - width * 0.5))), // -Z
            (SIMD3(width, 0.0014, inner), SIMD3(half - width * 0.5, y, 0)),   // +X
            (SIMD3(width, 0.0014, inner), SIMD3(-(half - width * 0.5), y, 0))  // -X
        ]
        for (size, pos) in strips {
            let strip = ModelEntity(mesh: .generateBox(size: size), materials: [mat])
            strip.position = pos
            frame.addChild(strip)
        }
        parent.addChild(frame)
    }

    /// Concentric diamond patchwork from a square grid of split triangles.
    private static func makeTriangleMosaicEntity(extent: Float, divisions: Int) -> Entity? {
        let root = Entity()
        root.name = "CoverTriangleMosaic"
        let n = max(4, divisions)
        let cell = extent / Float(n)
        let origin = -extent * 0.5
        let center = Float(n - 1) * 0.5

        let palette: [UIColor] = [
            UIColor(red: 0.96, green: 0.94, blue: 0.90, alpha: 1), // center white/silver
            UIColor(red: 0.88, green: 0.18, blue: 0.16, alpha: 1), // red
            UIColor(red: 0.12, green: 0.55, blue: 0.28, alpha: 1), // green
            UIColor(red: 0.16, green: 0.32, blue: 0.78, alpha: 1), // blue
            UIColor(red: 0.92, green: 0.78, blue: 0.16, alpha: 1), // yellow
            UIColor(red: 0.75, green: 0.72, blue: 0.68, alpha: 1)  // silver brocade
        ]

        // Build one mesh per color bucket for fewer draw calls.
        var positionsByColor: [[SIMD3<Float>]] = Array(repeating: [], count: palette.count)
        var indicesByColor: [[UInt32]] = Array(repeating: [], count: palette.count)

        for jz in 0..<n {
            for ix in 0..<n {
                let ring = Int(max(abs(Float(ix) - center), abs(Float(jz) - center)))
                let colorIndex = min(ring, palette.count - 1)
                let x0 = origin + Float(ix) * cell
                let z0 = origin + Float(jz) * cell
                let x1 = x0 + cell
                let z1 = z0 + cell
                // Two triangles per cell; alternate split for a denser diamond read.
                let flip = (ix + jz) % 2 == 0
                let tris: [[SIMD3<Float>]]
                if flip {
                    tris = [
                        [SIMD3(x0, 0, z0), SIMD3(x1, 0, z0), SIMD3(x0, 0, z1)],
                        [SIMD3(x1, 0, z0), SIMD3(x1, 0, z1), SIMD3(x0, 0, z1)]
                    ]
                } else {
                    tris = [
                        [SIMD3(x0, 0, z0), SIMD3(x1, 0, z0), SIMD3(x1, 0, z1)],
                        [SIMD3(x0, 0, z0), SIMD3(x1, 0, z1), SIMD3(x0, 0, z1)]
                    ]
                }
                // Color each triangle slightly differently within the ring for shimmer.
                for (t, tri) in tris.enumerated() {
                    let cidx = (colorIndex + t) % palette.count
                    let base = UInt32(positionsByColor[cidx].count)
                    positionsByColor[cidx].append(contentsOf: tri)
                    indicesByColor[cidx].append(contentsOf: [base, base + 1, base + 2])
                }
            }
        }

        for (ci, color) in palette.enumerated() {
            let positions = positionsByColor[ci]
            let indices = indicesByColor[ci]
            guard !positions.isEmpty else { continue }
            let normals = [SIMD3<Float>](repeating: SIMD3(0, 1, 0), count: positions.count)
            var descriptor = MeshDescriptor(name: "Mosaic_\(ci)")
            descriptor.positions = MeshBuffers.Positions(positions)
            descriptor.normals = MeshBuffers.Normals(normals)
            descriptor.primitives = .triangles(indices)
            guard let mesh = try? MeshResource.generate(from: [descriptor]) else { continue }
            var mat = SimpleMaterial()
            mat.color = .init(tint: color)
            mat.roughness = .float(0.62)
            mat.metallic = .float(ci == 5 ? 0.35 : 0.06)
            let entity = ModelEntity(mesh: mesh, materials: [mat])
            root.addChild(entity)
        }
        return root
    }

    /// Base plate under the largest ring (heaps 1–17). Silver tray with gold accents.
    static func makePlate(radius: Float = 0.56) -> Entity {
        let root = Entity()
        root.name = "MandalaPlate"

        let gold = ringOrnamentGoldMaterial()

        let baseMesh = MeshResource.generateCylinder(height: 0.028, radius: radius)
        var silver = SimpleMaterial()
        silver.color = .init(tint: UIColor(red: 0.76, green: 0.78, blue: 0.82, alpha: 1))
        silver.metallic = .float(0.92)
        silver.roughness = .float(0.34)
        let base = ModelEntity(mesh: baseMesh, materials: [silver])
        base.name = "PlateBase"
        base.position = SIMD3(0, 0.014, 0)
        base.components.set(GroundingShadowComponent(castsShadow: true))
        root.addChild(base)

        let rimMesh = MeshResource.generateCylinder(height: 0.018, radius: radius * 1.03)
        let rim = ModelEntity(mesh: rimMesh, materials: [gold])
        rim.name = "PlateRim"
        rim.position = SIMD3(0, 0.032, 0)
        root.addChild(rim)

        // Upright gold lotus-petal fringe on the plate rim (reference base).
        let petalCount = 24
        for i in 0..<petalCount {
            let angle = Float(i) * (.pi * 2 / Float(petalCount))
            let petal = ModelEntity(
                mesh: .generateBox(size: SIMD3(0.004, 0.016, 0.012), cornerRadius: 0.004),
                materials: [gold]
            )
            petal.position = SIMD3(
                cos(angle) * radius * 1.01,
                0.042,
                sin(angle) * radius * 1.01
            )
            petal.orientation = simd_quatf(angle: -angle, axis: SIMD3(0, 1, 0))
            root.addChild(petal)
        }

        // Running key / fret band on the upper rim edge.
        let keyCount = 36
        for i in 0..<keyCount {
            let angle = Float(i) * (.pi * 2 / Float(keyCount))
            let bar = ModelEntity(
                mesh: .generateBox(size: SIMD3(0.002, 0.003, radius * 0.05)),
                materials: [gold]
            )
            let r = radius * (i % 2 == 0 ? 1.015 : 1.005)
            bar.position = SIMD3(cos(angle) * r, 0.038, sin(angle) * r)
            bar.orientation = simd_quatf(angle: -angle, axis: SIMD3(0, 1, 0))
            root.addChild(bar)
        }

        let inlayMesh = MeshResource.generateCylinder(height: 0.004, radius: radius * 0.92)
        var inlay = SimpleMaterial()
        inlay.color = .init(tint: UIColor(red: 0.18, green: 0.55, blue: 0.52, alpha: 1))
        inlay.metallic = .float(0.4)
        inlay.roughness = .float(0.45)
        let inlayEntity = ModelEntity(mesh: inlayMesh, materials: [inlay])
        inlayEntity.name = "PlateInlay"
        inlayEntity.position = SIMD3(0, 0.029, 0)
        root.addChild(inlayEntity)

        // Static floor so physical grain clusters rest on the plate top.
        GrainPhysics.attachPlateCollider(to: root, radius: radius, topY: 0.041)
        return root
    }

    /// One stacked offering level: empty metal ring + growing grain fill + heap slots.
    ///
    /// Tier root is placed at `tier.surfaceY`. Local band space:
    /// - Y = 0 → bottom of metal wall
    /// - Y = `ringHeight` → top of metal wall
    /// - Grain starts as a thin layer and rises as offerings are placed; slots follow the surface.
    static func makeTier(tier: MandalaTier, unlocked: Bool) -> Entity {
        let root = Entity()
        root.name = "Tier_\(tier.rawValue)_\(tier.shortTitle)"
        root.position = SIMD3(0, tier.surfaceY, 0)

        let surface = Entity()
        surface.name = "TierSurface"
        root.addChild(surface)

        // Grain initially begins as a thin layer at the bottom of the ring.
        // It grows upward as offering heaps are added.
        let initialProgress: Float = 0.03
        let fill = makeGrowingTierFill(
            radius: tier.fillRadius,
            maximumHeight: tier.ringHeight
        )
        fill.name = "TierFill"
        surface.addChild(fill)

        // Box segments are Y-centered on the entity, so offset by h/2 → wall spans [0, h].
        let ring = makeMetalRing(
            radius: tier.ringRadius,
            height: tier.ringHeight
        )
        ring.position = SIMD3(0, tier.ringHeight * 0.5, 0)
        surface.addChild(ring)

        let slots = Entity()
        slots.name = "TierSlots"
        // Seat markers on the initial thin grain layer (rise via setTierFillProgress).
        slots.position = SIMD3(0, tier.ringHeight * initialProgress + 0.004, 0)
        surface.addChild(slots)

        if !unlocked {
            root.isEnabled = false
        }

        return root
    }

    /// Growing rice-tone volume inside a ring (scaled in Y; bottom stays at local Y = 0).
    private static func makeGrowingTierFill(
        radius: Float,
        maximumHeight: Float
    ) -> Entity {
        let root = Entity()
        root.name = "GrowingGrainFill"

        var material = SimpleMaterial()
        material.color = .init(
            tint: UIColor(red: 0.97, green: 0.95, blue: 0.90, alpha: 1)
        )
        material.metallic = .float(0.02)
        material.roughness = .float(0.9)

        let bulk = ModelEntity(
            mesh: .generateCylinder(height: maximumHeight, radius: radius),
            materials: [material]
        )
        bulk.name = "GrainBulk"
        bulk.components.set(GroundingShadowComponent(castsShadow: true))

        let initialProgress: Float = 0.03
        bulk.scale.y = initialProgress
        bulk.position.y = maximumHeight * initialProgress * 0.5
        root.addChild(bulk)

        // Soft bulges only — loose surface detail comes from physical grain clusters.
        let surfaceGrains = makeTierSurfaceBulges(radius: radius)
        surfaceGrains.name = "SurfaceGrains"
        surfaceGrains.position.y = maximumHeight * initialProgress
        surfaceGrains.isEnabled = false
        root.addChild(surfaceGrains)

        let surfaceCollider = GrainPhysics.makeGrainSurfaceCollider(
            radius: radius,
            atY: maximumHeight * initialProgress
        )
        root.addChild(surfaceCollider)

        root.components.set(
            GrainFillComponent(maximumHeight: maximumHeight, progress: initialProgress)
        )
        return root
    }

    /// Uneven packed surface bulges (physical clusters provide the granular edge).
    private static func makeTierSurfaceBulges(radius: Float) -> Entity {
        let root = Entity()

        let bulges: [(SIMD2<Float>, Float, Float)] = [
            (SIMD2(0.00, 0.00), 0.72, 0.020),
            (SIMD2(0.22, 0.08), 0.46, 0.014),
            (SIMD2(-0.18, 0.12), 0.42, 0.013),
            (SIMD2(0.08, -0.20), 0.40, 0.012),
            (SIMD2(-0.20, -0.16), 0.38, 0.011)
        ]

        for (index, bulge) in bulges.enumerated() {
            let x = bulge.0.x * radius
            let z = bulge.0.y * radius
            let bulgeRadius = radius * bulge.1
            let bulgeHeight = bulge.2

            let mound = ModelEntity(
                mesh: .generateSphere(radius: 1),
                materials: [riceBulkMaterial]
            )
            mound.name = "SurfaceBulge_\(index)"
            mound.scale = SIMD3(bulgeRadius, bulgeHeight, bulgeRadius)
            mound.position = SIMD3(x, 0, z)
            root.addChild(mound)
        }

        return root
    }

    /// Raise / lower the grain bulk and keep slot markers on the rising surface.
    static func setTierFillProgress(
        tierEntity: Entity,
        progress rawProgress: Float,
        animated: Bool = true
    ) {
        let progress = max(0.03, min(rawProgress, 1.0))

        guard
            let fillRoot = tierEntity.findEntity(named: "TierFill"),
            let bulk = fillRoot.findEntity(named: "GrainBulk")
        else {
            return
        }

        let maximumHeight: Float
        if var component = fillRoot.components[GrainFillComponent.self] {
            maximumHeight = component.maximumHeight
            component.progress = progress
            fillRoot.components.set(component)
        } else if let model = bulk as? ModelEntity {
            maximumHeight = model.model?.mesh.bounds.extents.y ?? MandalaTier.ringWallHeight
        } else {
            maximumHeight = MandalaTier.ringWallHeight
        }

        var transform = bulk.transform
        transform.scale.y = progress
        transform.translation.y = maximumHeight * progress * 0.5

        if animated {
            bulk.move(
                to: transform,
                relativeTo: bulk.parent,
                duration: 0.45,
                timingFunction: .easeInOut
            )
        } else {
            bulk.transform = transform
        }

        if let surface = fillRoot.findEntity(named: "SurfaceGrains") {
            surface.isEnabled = progress > 0.12
            var surfaceTransform = surface.transform
            surfaceTransform.translation.y = maximumHeight * progress
            if animated {
                surface.move(
                    to: surfaceTransform,
                    relativeTo: surface.parent,
                    duration: 0.45,
                    timingFunction: .easeInOut
                )
            } else {
                surface.transform = surfaceTransform
            }
        }

        GrainPhysics.updateGrainSurfaceCollider(
            in: fillRoot,
            maximumHeight: maximumHeight,
            progress: progress
        )

        updateTierSlotHeight(
            tierEntity: tierEntity,
            ringHeight: maximumHeight,
            progress: progress,
            animated: animated
        )
    }

    /// Keep heap slots seated on the current grain surface.
    static func updateTierSlotHeight(
        tierEntity: Entity,
        ringHeight: Float,
        progress: Float,
        animated: Bool = true
    ) {
        guard let slots = tierEntity.findEntity(named: "TierSlots") else { return }

        var transform = slots.transform
        transform.translation.y = ringHeight * progress + 0.004

        if animated {
            slots.move(
                to: transform,
                relativeTo: slots.parent,
                duration: 0.45,
                timingFunction: .easeInOut
            )
        } else {
            slots.transform = transform
        }
    }

    /// Depress the packed surface slightly when the next ring settles into it.
    static func compressGrainUnderRing(lowerTier: Entity) {
        guard
            let fill = lowerTier.findEntity(named: "TierFill"),
            let surface = fill.findEntity(named: "SurfaceGrains")
        else {
            return
        }

        var compressed = surface.transform
        compressed.scale.y *= 0.72
        compressed.translation.y -= 0.003
        surface.move(
            to: compressed,
            relativeTo: surface.parent,
            duration: 0.35,
            timingFunction: .easeInOut
        )
    }

    /// Open metal hoop approximated with box segments around the circle,
    /// studded with jewel flowers and gold embossed plaques (reference mandala-set look).
    static func makeMetalRing(radius: Float, height: Float) -> Entity {
        let root = Entity()
        root.name = "MetalRing"

        // Silver filigree body (gold reserved for plaques / bezels).
        var mat = SimpleMaterial()
        mat.color = .init(tint: UIColor(red: 0.78, green: 0.80, blue: 0.84, alpha: 1))
        mat.metallic = .float(0.94)
        mat.roughness = .float(0.32)

        let segments = 28
        let thickness: Float = 0.016
        let chord = 2 * radius * sin(.pi / Float(segments))
        for i in 0..<segments {
            let angle = Float(i) * (.pi * 2 / Float(segments))
            let segment = ModelEntity(
                mesh: .generateBox(size: SIMD3(thickness, height, chord * 1.08)),
                materials: [mat]
            )
            segment.position = SIMD3(cos(angle) * radius, 0, sin(angle) * radius)
            segment.orientation = simd_quatf(angle: -angle, axis: SIMD3(0, 1, 0))
            root.addChild(segment)
        }

        decorateRingWall(root: root, radius: radius, height: height, thickness: thickness)
        GrainPhysics.attachRingPhysics(
            to: root,
            radius: radius,
            height: height,
            thickness: thickness,
            mode: .static
        )
        return root
    }

    // MARK: - Ring wall bedazzling

    private enum RingGemKind: CaseIterable {
        case turquoise, coral

        var color: UIColor {
            switch self {
            case .turquoise: return UIColor(red: 0.10, green: 0.72, blue: 0.68, alpha: 1)
            case .coral: return UIColor(red: 0.90, green: 0.26, blue: 0.22, alpha: 1)
            }
        }
    }

    /// Circumference-scaled motif slots (plaques + bead flowers interleaved).
    private static func ringMotifCount(forRadius radius: Float) -> Int {
        switch radius {
        case 0.45...: return 12
        case 0.28...: return 10
        case 0.18...: return 8
        default: return 6
        }
    }

    private static func decorateRingWall(
        root: Entity,
        radius: Float,
        height: Float,
        thickness: Float
    ) {
        let gems = Entity()
        gems.name = "RingJewels"
        root.addChild(gems)

        let ornaments = Entity()
        ornaments.name = "RingOrnaments"
        root.addChild(ornaments)

        let motifCount = ringMotifCount(forRadius: radius)
        let outerR = radius + thickness * 0.55
        let gemRadius = max(0.0065, min(0.0105, radius * 0.019))
        let gold = ringOrnamentGoldMaterial()
        let plaqueScale = max(0.75, min(1.35, radius / 0.34))

        // Interleave gold plaques and coral/turquoise bead flowers around the wall
        // (matches traditional silver mandala-set decoration).
        for i in 0..<motifCount {
            let angle = Float(i) * (.pi * 2 / Float(motifCount))
            let yaw = simd_quatf(angle: -angle, axis: SIMD3(0, 1, 0))
            let pos = SIMD3(cos(angle) * (outerR + 0.002), 0, sin(angle) * (outerR + 0.002))

            if i % 2 == 0 {
                let plaque: Entity
                switch (i / 2) % 3 {
                case 0:
                    plaque = makeOctagonalGoldPlaque(
                        content: .mantra(["ༀ", "ཨོཾ", "མཎི", "པདྨེ", "ཧཱུྃ"][(i / 2) % 5]),
                        scale: plaqueScale,
                        gold: gold
                    )
                case 1:
                    plaque = makeOctagonalGoldPlaque(content: .dharmaWheel, scale: plaqueScale, gold: gold)
                default:
                    plaque = makeOctagonalGoldPlaque(content: .lotus, scale: plaqueScale, gold: gold)
                }
                plaque.position = pos
                plaque.orientation = yaw
                ornaments.addChild(plaque)
            } else {
                // Alternate flower polarity: turquoise center / coral petals, then reverse.
                let turquoiseCenter = ((i / 2) % 2 == 0)
                let flower = makeBeadFlower(
                    center: turquoiseCenter ? .turquoise : .coral,
                    petal: turquoiseCenter ? .coral : .turquoise,
                    gemRadius: gemRadius,
                    gold: gold
                )
                flower.position = pos
                flower.orientation = yaw
                gems.addChild(flower)
            }
        }

        // Scalloped / lotus-petal gold rim accents along top and bottom edges.
        addScallopedRim(
            to: ornaments,
            radius: outerR,
            height: height,
            count: max(motifCount * 2, 12),
            gold: gold
        )

        // Fine key / fret band near the upper rim (reference lowest-tray motif, scaled).
        addKeyPatternBand(
            to: ornaments,
            radius: outerR + 0.0005,
            y: height * 0.38,
            count: max(motifCount * 3, 18),
            gold: gold
        )
    }

    private static func ringOrnamentGoldMaterial() -> SimpleMaterial {
        var gold = SimpleMaterial()
        gold.color = .init(tint: UIColor(red: 0.92, green: 0.76, blue: 0.28, alpha: 1))
        gold.metallic = .float(0.95)
        gold.roughness = .float(0.22)
        return gold
    }

    /// Coral / turquoise flower cluster: large center + six petal beads in a gold bezel.
    private static func makeBeadFlower(
        center: RingGemKind,
        petal: RingGemKind,
        gemRadius: Float,
        gold: SimpleMaterial
    ) -> Entity {
        let root = Entity()
        root.name = "BeadFlower_\(center)_\(petal)"

        let bezel = ModelEntity(
            mesh: .generateCylinder(height: gemRadius * 0.55, radius: gemRadius * 2.35),
            materials: [gold]
        )
        bezel.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3(0, 0, 1))
        bezel.position = SIMD3(gemRadius * 0.15, 0, 0)
        root.addChild(bezel)

        let centerGem = ModelEntity(
            mesh: .generateSphere(radius: gemRadius * 1.05),
            materials: [UnlitMaterial(color: center.color)]
        )
        centerGem.position = SIMD3(gemRadius * 0.55, 0, 0)
        root.addChild(centerGem)

        let petalR = gemRadius * 0.48
        let orbit = gemRadius * 1.35
        for i in 0..<6 {
            let a = Float(i) * (.pi * 2 / 6)
            let petalGem = ModelEntity(
                mesh: .generateSphere(radius: petalR),
                materials: [UnlitMaterial(color: petal.color)]
            )
            petalGem.position = SIMD3(
                gemRadius * 0.45,
                cos(a) * orbit,
                sin(a) * orbit
            )
            root.addChild(petalGem)
        }
        return root
    }

    private enum PlaqueContent {
        case mantra(String)
        case dharmaWheel
        case lotus
    }

    /// Raised octagonal gold plaque with embossed motif (reference wall plates).
    private static func makeOctagonalGoldPlaque(
        content: PlaqueContent,
        scale: Float,
        gold: SimpleMaterial
    ) -> Entity {
        let root = Entity()
        root.name = "GoldPlaque"

        let w = 0.028 * scale
        let h = 0.034 * scale
        let depth = 0.0045 * scale

        // Approximate octagon: square plate + corner cuts via slightly rounded box.
        let plate = ModelEntity(
            mesh: .generateBox(size: SIMD3(depth, h, w), cornerRadius: min(w, h) * 0.18),
            materials: [gold]
        )
        plate.position = SIMD3(depth * 0.55, 0, 0)
        root.addChild(plate)

        // Thin raised frame.
        let frame = ModelEntity(
            mesh: .generateBox(size: SIMD3(depth * 0.55, h * 1.08, w * 1.08), cornerRadius: min(w, h) * 0.2),
            materials: [gold]
        )
        frame.position = SIMD3(depth * 0.25, 0, 0)
        root.addChild(frame)

        switch content {
        case .mantra(let text):
            let glyph = makeMantraPlaque(text: text, scale: scale * 0.72, gold: gold)
            glyph.position = SIMD3(depth * 1.15, 0, 0)
            root.addChild(glyph)
        case .dharmaWheel:
            let wheel = makeDharmaWheelMedallion(scale: scale * 0.85, gold: gold)
            wheel.position = SIMD3(depth * 1.1, 0, 0)
            root.addChild(wheel)
        case .lotus:
            let lotus = makeLotusMedallion(scale: scale * 0.9, gold: gold)
            lotus.position = SIMD3(depth * 1.1, 0, 0)
            root.addChild(lotus)
        }
        return root
    }

    private static func addScallopedRim(
        to parent: Entity,
        radius: Float,
        height: Float,
        count: Int,
        gold: SimpleMaterial
    ) {
        let petalH = height * 0.09
        let petalW = max(0.006, radius * 0.028)
        for i in 0..<count {
            let angle = Float(i) * (.pi * 2 / Float(count))
            for sign: Float in [1, -1] {
                let petal = ModelEntity(
                    mesh: .generateBox(
                        size: SIMD3(0.003, petalH, petalW),
                        cornerRadius: petalW * 0.35
                    ),
                    materials: [gold]
                )
                petal.position = SIMD3(
                    cos(angle) * (radius + 0.001),
                    sign * (height * 0.48),
                    sin(angle) * (radius + 0.001)
                )
                petal.orientation = simd_quatf(angle: -angle, axis: SIMD3(0, 1, 0))
                parent.addChild(petal)
            }
        }
    }

    private static func addKeyPatternBand(
        to parent: Entity,
        radius: Float,
        y: Float,
        count: Int,
        gold: SimpleMaterial
    ) {
        let step = (.pi * 2) / Float(count)
        let barLen = radius * step * 0.55
        for i in 0..<count {
            let angle = Float(i) * step
            let bar = ModelEntity(
                mesh: .generateBox(size: SIMD3(0.0022, 0.0035, barLen)),
                materials: [gold]
            )
            // Stagger to suggest a running key / fret.
            let radial = radius + (i % 2 == 0 ? 0.0012 : 0.0004)
            bar.position = SIMD3(cos(angle) * radial, y, sin(angle) * radial)
            bar.orientation = simd_quatf(angle: -angle, axis: SIMD3(0, 1, 0))
            parent.addChild(bar)
        }
    }

    private static func makeGemStud(kind: RingGemKind, gemRadius: Float, gold: SimpleMaterial) -> Entity {
        let root = Entity()
        root.name = "GemStud_\(kind)"

        let bezel = ModelEntity(
            mesh: .generateSphere(radius: gemRadius * 1.35),
            materials: [gold]
        )
        bezel.scale = SIMD3(0.55, 1.05, 1.05)
        bezel.position = SIMD3(0, 0, 0)
        root.addChild(bezel)

        let gem = ModelEntity(
            mesh: .generateSphere(radius: gemRadius),
            materials: [UnlitMaterial(color: kind.color)]
        )
        gem.position = SIMD3(gemRadius * 0.35, 0, 0)
        gem.scale = SIMD3(0.72, 1.0, 1.0)
        root.addChild(gem)

        return root
    }

    /// Compact Wheel of Dharma: hub + open rim (box segments) + eight spokes.
    private static func makeDharmaWheelMedallion(scale: Float, gold: SimpleMaterial) -> Entity {
        let root = Entity()
        root.name = "DharmaWheel"

        let s = 0.007 * scale
        let hub = ModelEntity(
            mesh: .generateCylinder(height: s * 0.55, radius: s * 0.9),
            materials: [gold]
        )
        // Cylinder default axis is Y; rotate so face points radially (+X after parent yaw).
        hub.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3(0, 0, 1))
        hub.position = SIMD3(s * 0.15, 0, 0)
        root.addChild(hub)

        // Open rim — segment boxes in the medallion YZ plane (face along local +X).
        let rimRadius = s * 2.4
        let rimSegments = 16
        let rimThickness = s * 0.35
        let rimDepth = s * 0.28
        let rimChord = 2 * rimRadius * sin(.pi / Float(rimSegments))
        for i in 0..<rimSegments {
            let a = Float(i) * (.pi * 2 / Float(rimSegments))
            let segment = ModelEntity(
                mesh: .generateBox(size: SIMD3(rimDepth, rimThickness, rimChord * 1.1)),
                materials: [gold]
            )
            segment.position = SIMD3(s * 0.12, cos(a) * rimRadius, sin(a) * rimRadius)
            segment.orientation = simd_quatf(angle: -a, axis: SIMD3(1, 0, 0))
            root.addChild(segment)
        }

        for i in 0..<8 {
            let spokeAngle = Float(i) * (.pi / 4)
            let spoke = ModelEntity(
                mesh: .generateBox(size: SIMD3(s * 0.22, s * 0.35, s * 2.0)),
                materials: [gold]
            )
            spoke.position = SIMD3(s * 0.2, 0, 0)
            spoke.orientation = simd_quatf(angle: spokeAngle, axis: SIMD3(1, 0, 0))
            root.addChild(spoke)
        }

        return root
    }

    /// Raised lotus: center disc + petal buds.
    private static func makeLotusMedallion(scale: Float, gold: SimpleMaterial) -> Entity {
        let root = Entity()
        root.name = "LotusMedallion"

        let s = 0.0065 * scale
        let center = ModelEntity(
            mesh: .generateSphere(radius: s * 0.85),
            materials: [gold]
        )
        center.position = SIMD3(s * 0.2, 0, 0)
        center.scale = SIMD3(0.45, 1, 1)
        root.addChild(center)

        for i in 0..<6 {
            let a = Float(i) * (.pi * 2 / 6)
            let petal = ModelEntity(
                mesh: .generateSphere(radius: s * 0.7),
                materials: [gold]
            )
            petal.position = SIMD3(
                s * 0.15,
                cos(a) * s * 1.35,
                sin(a) * s * 1.35
            )
            petal.scale = SIMD3(0.35, 1.15, 0.55)
            root.addChild(petal)
        }

        return root
    }

    /// Gold plaque with extruded mantra syllable (system font; Tibetan Unicode).
    private static func makeMantraPlaque(text: String, scale: Float, gold: SimpleMaterial) -> Entity {
        let root = Entity()
        root.name = "MantraPlaque"

        // ~3.5–4× prior face size so Tibetan glyphs read clearly on the outer wall.
        let w: Float = 0.100 * scale
        let h: Float = 0.052 * scale
        let plaque = ModelEntity(
            mesh: .generateBox(size: SIMD3(0.0032, h, w), cornerRadius: 0.0034),
            materials: [gold]
        )
        plaque.position = SIMD3(0.0014, 0, 0)
        root.addChild(plaque)

        // Embossed border strip.
        let border = ModelEntity(
            mesh: .generateBox(size: SIMD3(0.0018, h * 1.08, w * 1.08), cornerRadius: 0.0030),
            materials: [gold]
        )
        border.position = SIMD3(0.0005, 0, 0)
        root.addChild(border)

        // Slightly darker raised glyphs so syllables separate from the gold plate.
        var glyphMat = gold
        glyphMat.color = .init(tint: UIColor(red: 0.55, green: 0.18, blue: 0.12, alpha: 1))
        glyphMat.metallic = .float(0.35)
        glyphMat.roughness = .float(0.45)

        if let textMesh = makeMantraTextMesh(text: text, fontSize: CGFloat(0.048 * Double(scale))) {
            // Holder at plaque center so uniform scale keeps glyphs optically centered.
            let holder = Entity()
            holder.position = SIMD3(0.0048, 0, 0)
            holder.scale = SIMD3(repeating: 1.45)
            let glyph = ModelEntity(mesh: textMesh, materials: [glyphMat])
            // generateText lies in XY facing +Z; yaw +90° so +Z faces outward (+X).
            // (−90° faced inward, so outside viewers saw mirrored backs of glyphs.)
            glyph.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3(0, 1, 0))
            let c = textMesh.bounds.center
            // Center after R(+90° Y): R*c = (c.z, c.y, −c.x) → position = −R*c.
            glyph.position = SIMD3(-c.z, -c.y, c.x)
            holder.addChild(glyph)
            root.addChild(holder)
        } else {
            // Fallback relief ticks if text mesh unavailable.
            for j in 0..<3 {
                let tick = ModelEntity(
                    mesh: .generateBox(size: SIMD3(0.0024, h * 0.5, w * 0.18)),
                    materials: [glyphMat]
                )
                tick.position = SIMD3(0.0034, 0, Float(j - 1) * w * 0.28)
                root.addChild(tick)
            }
        }

        return root
    }

    private static func makeMantraTextMesh(text: String, fontSize: CGFloat) -> MeshResource? {
        // Prefer a system face that covers Tibetan; fall back to system font.
        let font: UIFont
        if let tibetan = UIFont(name: "Kailasa", size: fontSize)
            ?? UIFont(name: "Kailasa-Bold", size: fontSize)
            ?? UIFont(name: "TibetanSangamMN", size: fontSize) {
            font = tibetan
        } else {
            font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        }
        return MeshResource.generateText(
            text,
            extrusionDepth: 0.0032,
            font: font,
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byTruncatingTail
        )
    }

    /// Traditional mandala-set finial: pedestal + flame plate with turquoise gem.
    /// Final centerpiece (heap 38) in the middle of the top ring after heaps 34–37.
    /// Origin is at the pedestal base (sits on the deck). No physics — static placement only.
    /// Compact footprint for celestial ring (r=0.15); cardinals near r≈0.08.
    static func makeTopOrnament() -> Entity {
        let root = Entity()
        root.name = "TopOrnament"

        var gold = SimpleMaterial()
        gold.color = .init(tint: UIColor(red: 0.92, green: 0.74, blue: 0.28, alpha: 1))
        gold.metallic = .float(0.95)
        gold.roughness = .float(0.22)

        // Compact pedestal — leaves room for sun/moon/parasol/banner at r≈0.08.
        // Three steps; top surface at Y = 0.006 + 2×0.012 + 0.006 = 0.036.
        let pedestalTopY: Float = 0.036
        for (i, radius) in ([0.032, 0.026, 0.020] as [Float]).enumerated() {
            let step = ModelEntity(
                mesh: .generateCylinder(height: 0.012, radius: radius),
                materials: [gold]
            )
            step.position = SIMD3(0, 0.006 + Float(i) * 0.012, 0)
            root.addChild(step)
        }

        // Flame / thog — seated on pedestal top (no pearl dome above).
        // Keep cornerRadius well below half-min-dimension or mesh collapses.
        let flameRoot = Entity()
        flameRoot.name = "FlameFinial"
        flameRoot.position = SIMD3(0, pedestalTopY, 0)

        for (i, yaw) in ([0, Float.pi / 2] as [Float]).enumerated() {
            let plate = ModelEntity(
                mesh: .generateBox(size: SIMD3(0.014, 0.14, 0.078), cornerRadius: 0.005),
                materials: [gold]
            )
            plate.name = "FlamePlate_\(i)"
            plate.position = SIMD3(0, 0.07, 0)
            plate.orientation = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))
            flameRoot.addChild(plate)
        }

        let flameTip = ModelEntity(
            mesh: .generateCone(height: 0.055, radius: 0.026),
            materials: [gold]
        )
        flameTip.position = SIMD3(0, 0.16, 0)
        flameRoot.addChild(flameTip)

        let gem = ModelEntity(
            mesh: .generateSphere(radius: 0.022),
            materials: [UnlitMaterial(color: UIColor(red: 0.90, green: 0.22, blue: 0.20, alpha: 1))]
        )
        gem.name = "FinialCenterGem"
        gem.position = SIMD3(0, 0.07, 0)
        flameRoot.addChild(gem)

        // Small Dharma wheel overlay on the flame face (reference finial).
        let wheel = makeDharmaWheelMedallion(scale: 2.4, gold: gold)
        wheel.position = SIMD3(0.012, 0.07, 0)
        flameRoot.addChild(wheel)

        // Four turquoise accent beads around the wheel.
        for i in 0..<4 {
            let a = Float(i) * (.pi / 2) + .pi / 4
            let bead = ModelEntity(
                mesh: .generateSphere(radius: 0.008),
                materials: [UnlitMaterial(color: UIColor(red: 0.10, green: 0.72, blue: 0.68, alpha: 1))]
            )
            bead.position = SIMD3(
                0.01,
                0.07 + cos(a) * 0.032,
                sin(a) * 0.032
            )
            flameRoot.addChild(bead)
        }

        let bezel = ModelEntity(
            mesh: .generateSphere(radius: 0.034),
            materials: [gold]
        )
        bezel.position = SIMD3(0, 0.07, 0)
        bezel.scale = SIMD3(1, 0.32, 1)
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
                mesh: .generateCylinder(height: 0.008, radius: max(0.09, markerRadius * 3.6)),
                materials: [UnlitMaterial(
                    color: UIColor(red: 0.05, green: 0.95, blue: 1.0, alpha: 0.82)
                )]
            )
            glowDisc.position = SIMD3(0, 0.014, 0)
            beacon.addChild(glowDisc)

            let column = ModelEntity(
                mesh: .generateCylinder(height: 0.12, radius: 0.012),
                materials: [UnlitMaterial(
                    color: UIColor(red: 0.18, green: 0.98, blue: 1.0, alpha: 0.9)
                )]
            )
            column.position = SIMD3(0, 0.075, 0)
            beacon.addChild(column)

            let orb = ModelEntity(
                mesh: .generateSphere(radius: 0.032),
                materials: [UnlitMaterial(
                    color: UIColor(red: 0.75, green: 1.0, blue: 1.0, alpha: 1)
                )]
            )
            orb.position = SIMD3(0, 0.145, 0)
            beacon.addChild(orb)

            let pointer = ModelEntity(
                mesh: .generateCone(height: 0.045, radius: 0.024),
                materials: [UnlitMaterial(color: UIColor.white)]
            )
            pointer.position = SIMD3(0, 0.110, 0)
            pointer.orientation = simd_quatf(angle: .pi, axis: SIMD3(1, 0, 0))
            beacon.addChild(pointer)

            root.addChild(beacon)
        }

        if interactive {
            // Guided beacon ≈ 3× prior (~28 cm); free slots ≈ 1.8× (~9 cm) to stay local on dense rings.
            let hitSize = highlighted ? max(0.28, markerRadius * 7.0) : max(0.09, markerRadius * 3.6)
            let hitHeight: Float = highlighted ? 0.32 : 0.22
            let shape = ShapeResource.generateBox(size: SIMD3(hitSize, hitHeight, hitSize))
                .offsetBy(translation: SIMD3(0, hitHeight * 0.45, 0))
            root.components.set(CollisionComponent(shapes: [shape], mode: .trigger))
            root.components.set(InputTargetComponent())
        }

        root.components.set(HeapSlotComponent(index: definition.number - 1))
        return root
    }

    /// Visual style for offering heaps 2–37 (Mount Meru / centerpiece stay special).
    enum OfferingMoundStyle {
        /// Continents/subcontinents (2–13): colorful grain mound (randomized jewel tints).
        case rice
        /// Precious mountain/tree/cow/harvest (14–17): grains with jewel accents.
        case mixedOffering
        /// Treasures/emblems (18–25): colorful gem pile.
        case crystal
        /// Goddesses (26–33): pastel/pearl gem pile.
        case pastelCrystal
        /// Sun/moon/parasol/banner (34–37): gems tinted by heap material.
        case tintedCrystal

        static func forHeapNumber(_ number: Int) -> OfferingMoundStyle {
            switch number {
            case 2...13: return .rice
            case 14...17: return .mixedOffering
            case 18...25: return .crystal
            case 26...33: return .pastelCrystal
            case 34...37: return .tintedCrystal
            default: return .rice
            }
        }
    }

    /// Saturated jewel / pigment pool for per-heap random color mixes.
    private static let jewelColorPool: [UIColor] = [
        UIColor(red: 0.92, green: 0.72, blue: 0.18, alpha: 1), // gold
        UIColor(red: 0.18, green: 0.72, blue: 0.68, alpha: 1), // turquoise
        UIColor(red: 0.90, green: 0.38, blue: 0.32, alpha: 1), // coral
        UIColor(red: 0.96, green: 0.94, blue: 0.90, alpha: 1), // pearl
        UIColor(red: 0.24, green: 0.68, blue: 0.42, alpha: 1), // jade
        UIColor(red: 0.88, green: 0.52, blue: 0.12, alpha: 1), // amber
        UIColor(red: 0.72, green: 0.14, blue: 0.22, alpha: 1), // ruby
        UIColor(red: 0.20, green: 0.38, blue: 0.86, alpha: 1), // sapphire
        UIColor(red: 0.58, green: 0.32, blue: 0.78, alpha: 1), // amethyst
        UIColor(red: 0.12, green: 0.58, blue: 0.48, alpha: 1), // emerald
        UIColor(red: 0.86, green: 0.62, blue: 0.72, alpha: 1), // rose
        UIColor(red: 0.95, green: 0.82, blue: 0.42, alpha: 1), // yellow grain
        UIColor(red: 0.78, green: 0.28, blue: 0.48, alpha: 1), // magenta
        UIColor(red: 0.35, green: 0.62, blue: 0.88, alpha: 1)  // sky lapis
    ]

    /// Fuller sector mounds: more fine grains baked into a few meshes.
    private static let riceParticleTarget = 140
    private static let riceParticleJitter = 12 // → 128…152
    private static let crystalParticleTarget = 130
    private static let crystalParticleJitter = 10 // → 120…140
    private static let paletteParticleCount = 22

    // Shared mesh for bulk dome under grain / crystal mounds.
    private static let particleMesh = MeshResource.generateSphere(radius: 1)

    /// White / cream matte rice — matches traditional offering photo (not yellow grain).
    private static let riceMaterials: [SimpleMaterial] = {
        let tints: [UIColor] = [
            UIColor(red: 0.99, green: 0.98, blue: 0.95, alpha: 1),
            UIColor(red: 0.97, green: 0.95, blue: 0.90, alpha: 1),
            UIColor(red: 0.94, green: 0.92, blue: 0.86, alpha: 1)
        ]
        return tints.map { tint in
            var mat = SimpleMaterial()
            mat.color = .init(tint: tint)
            mat.metallic = .float(0.02)
            mat.roughness = .float(0.88)
            return mat
        }
    }()

    /// Soft under-dome so the bulge reads solid even between grains (no per-grain shadows).
    private static let riceBulkMaterial: SimpleMaterial = {
        var mat = SimpleMaterial()
        mat.color = .init(tint: UIColor(red: 0.97, green: 0.95, blue: 0.90, alpha: 1))
        mat.metallic = .float(0.02)
        mat.roughness = .float(0.92)
        return mat
    }()

    private static let crystalGemMaterials: [any Material] = {
        gemPaletteMaterials(colors: [
            UIColor(red: 0.22, green: 0.72, blue: 0.70, alpha: 1), // turquoise
            UIColor(red: 0.90, green: 0.42, blue: 0.35, alpha: 1), // coral
            UIColor(red: 0.25, green: 0.45, blue: 0.88, alpha: 1), // sapphire
            UIColor(red: 0.92, green: 0.68, blue: 0.22, alpha: 1), // amber
            UIColor(red: 0.94, green: 0.93, blue: 0.90, alpha: 1)  // pearl
        ], unlitBias: false)
    }()

    private static let pastelGemMaterials: [any Material] = {
        gemPaletteMaterials(colors: [
            UIColor(red: 0.96, green: 0.90, blue: 0.92, alpha: 1),
            UIColor(red: 0.88, green: 0.94, blue: 0.96, alpha: 1),
            UIColor(red: 0.92, green: 0.88, blue: 0.98, alpha: 1),
            UIColor(red: 0.94, green: 0.93, blue: 0.88, alpha: 1),
            UIColor(red: 0.86, green: 0.94, blue: 0.90, alpha: 1)
        ], unlitBias: true)
    }()

    /// Cached per-kind materials (shared across every mound that uses that tint).
    private static let kindMaterials: [HeapMaterialKind: SimpleMaterial] = {
        var map: [HeapMaterialKind: SimpleMaterial] = [:]
        for kind in HeapMaterialKind.allCases {
            var mat = SimpleMaterial()
            mat.color = .init(tint: kind.tint)
            mat.metallic = .float(kind.metallic)
            mat.roughness = .float(kind.roughness)
            map[kind] = mat
        }
        return map
    }()

    private static let kindBrightMaterials: [HeapMaterialKind: SimpleMaterial] = {
        var map: [HeapMaterialKind: SimpleMaterial] = [:]
        for kind in HeapMaterialKind.allCases {
            var bright = SimpleMaterial()
            bright.color = .init(tint: kind.tint)
            bright.metallic = .float(min(0.95, kind.metallic + 0.15))
            bright.roughness = .float(max(0.12, kind.roughness - 0.1))
            map[kind] = bright
        }
        return map
    }()

    private static let mixedGrainMaterialsByKind: [HeapMaterialKind: [SimpleMaterial]] = {
        var map: [HeapMaterialKind: [SimpleMaterial]] = [:]
        for kind in HeapMaterialKind.allCases {
            var tinted = SimpleMaterial()
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            kind.tint.getRed(&r, green: &g, blue: &b, alpha: &a)
            tinted.color = .init(tint: UIColor(
                red: min(1, 0.72 * r + 0.28 * 0.94),
                green: min(1, 0.72 * g + 0.28 * 0.90),
                blue: min(1, 0.72 * b + 0.28 * 0.80),
                alpha: 1
            ))
            tinted.metallic = .float(0.08)
            tinted.roughness = .float(0.70)
            map[kind] = riceMaterials + [tinted]
        }
        return map
    }()

    private static func gemPaletteMaterials(colors: [UIColor], unlitBias: Bool) -> [any Material] {
        colors.enumerated().map { index, color in
            if unlitBias && index % 2 == 0 {
                return UnlitMaterial(color: color)
            }
            var mat = SimpleMaterial()
            mat.color = .init(tint: color)
            mat.metallic = .float(0.75)
            mat.roughness = .float(0.18)
            return mat
        }
    }

    private static func material(for kind: HeapMaterialKind) -> SimpleMaterial {
        kindMaterials[kind] ?? SimpleMaterial(color: kind.tint, isMetallic: kind.metallic > 0.5)
    }

    private static func particleCount(around target: Int, jitter: Int, rng: inout SeededRNG) -> Int {
        let span = max(0, jitter)
        guard span > 0 else { return target }
        return target - span + Int(rng.next() % UInt64(span * 2 + 1))
    }

    /// Per-heap random color mix: preferred tint + shuffled jewel accents (seeded by heap #).
    private static func randomizedHeapPalette(
        preferred: HeapMaterialKind,
        heapNumber: Int,
        rng: inout SeededRNG,
        grainLike: Bool
    ) -> (grains: [SimpleMaterial], gems: [any Material], bulk: SimpleMaterial) {
        var colors: [UIColor] = [preferred.tint]
        // Each heap picks a different subset so neighboring mounds don't match.
        let accentCount = 4 + Int(rng.next() % 3) // 4…6
        var pool = jewelColorPool
        for i in stride(from: pool.count - 1, through: 1, by: -1) {
            let j = Int(rng.next() % UInt64(i + 1))
            pool.swapAt(i, j)
        }
        for color in pool.prefix(accentCount) {
            // Mild per-heap hue jitter so repeats still read unique.
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            let jitter = CGFloat(rng.range(-0.06, 0.06))
            colors.append(UIColor(
                red: min(1, max(0, r + jitter)),
                green: min(1, max(0, g + jitter * 0.7)),
                blue: min(1, max(0, b - jitter * 0.5)),
                alpha: 1
            ))
        }

        let grains: [SimpleMaterial] = colors.map { color in
            var mat = SimpleMaterial()
            mat.color = .init(tint: color)
            if grainLike {
                mat.metallic = .float(rng.range(0.04, 0.22))
                mat.roughness = .float(rng.range(0.62, 0.88))
            } else {
                mat.metallic = .float(rng.range(0.45, 0.88))
                mat.roughness = .float(rng.range(0.16, 0.38))
            }
            return mat
        }

        let gems: [any Material] = colors.enumerated().map { index, color in
            if index % 3 == 2 {
                return UnlitMaterial(color: color)
            }
            var mat = SimpleMaterial()
            mat.color = .init(tint: color)
            mat.metallic = .float(0.78)
            mat.roughness = .float(0.18)
            return mat
        }

        var bulk = SimpleMaterial()
        bulk.color = .init(tint: colors[Int(rng.next() % UInt64(colors.count))])
        bulk.metallic = .float(grainLike ? 0.08 : 0.55)
        bulk.roughness = .float(grainLike ? 0.82 : 0.32)
        _ = heapNumber // seed already folded into rng
        return (grains, gems, bulk)
    }

    /// Procedural offering mound (rice and/or crystals) for heaps 2–37.
    static func makeHeap(kind: HeapMaterialKind, scale: Float, heapNumber: Int) -> Entity {
        let style = OfferingMoundStyle.forHeapNumber(heapNumber)
        let root = Entity()
        root.name = "Heap_\(heapNumber)_\(styleLabel(style))"

        var rng = SeededRNG(seed: UInt64(heapNumber) &* 2654435761 &+ 97)
        let isRiceStyle = style == .rice || style == .mixedOffering
        let total = particleCount(
            around: isRiceStyle ? riceParticleTarget : crystalParticleTarget,
            jitter: isRiceStyle ? riceParticleJitter : crystalParticleJitter,
            rng: &rng
        )
        let palette = randomizedHeapPalette(
            preferred: kind,
            heapNumber: heapNumber,
            rng: &rng,
            grainLike: isRiceStyle
        )

        switch style {
        case .rice:
            addRiceGrains(
                to: root,
                count: total,
                scale: scale,
                materials: palette.grains,
                bulkMaterial: palette.bulk,
                rng: &rng
            )
        case .mixedOffering:
            // Mostly colored grains with a few jewel accents.
            let jewelCount = min(14, max(8, total / 8))
            let grainCount = total - jewelCount
            addRiceGrains(
                to: root,
                count: grainCount,
                scale: scale,
                materials: palette.grains,
                bulkMaterial: palette.bulk,
                rng: &rng
            )
            addCrystalGems(
                to: root,
                count: jewelCount,
                scale: scale * 1.05,
                materials: palette.gems,
                rng: &rng,
                sizeRange: (0.0024, 0.0038),
                addBulkDome: false
            )
        case .crystal:
            addCrystalGems(
                to: root,
                count: total,
                scale: scale,
                materials: palette.gems,
                rng: &rng,
                sizeRange: (0.0022, 0.0036)
            )
        case .pastelCrystal:
            addCrystalGems(
                to: root,
                count: total,
                scale: scale,
                materials: pastelGemMaterials + palette.gems,
                rng: &rng,
                sizeRange: (0.0020, 0.0034)
            )
        case .tintedCrystal:
            let accent = material(for: kind)
            let bright = kindBrightMaterials[kind] ?? accent
            addCrystalGems(
                to: root,
                count: total,
                scale: scale,
                materials: [accent, bright] + palette.gems,
                rng: &rng,
                sizeRange: (0.0022, 0.0036),
                preferPrimaryMaterial: true
            )
        }

        // Single trigger collider covering the larger bulge (paired for targeted gestures).
        let hitRadius = 0.16 * scale
        let hitHeight: Float = 0.15 * scale
        let shape = ShapeResource.generateBox(size: SIMD3(hitRadius * 2, hitHeight, hitRadius * 2))
            .offsetBy(translation: SIMD3(0, hitHeight * 0.42, 0))
        root.components.set(CollisionComponent(shapes: [shape], mode: .trigger))
        root.components.set(InputTargetComponent())

        // One shadow caster for the whole pile — never on individual grains.
        if let bulk = root.children.first(where: { $0.name.hasPrefix("MoundBulk") }) as? ModelEntity {
            bulk.components.set(GroundingShadowComponent(castsShadow: true))
        }

        return root
    }

    /// Mini offering mound for the material palette (not a pawn/orb).
    static func makePaletteOrb(kind: HeapMaterialKind, selected: Bool) -> Entity {
        let root = Entity()
        root.name = "Palette_\(kind.rawValue)"

        let kindSeed: UInt64 = {
            switch kind {
            case .gold: return 1
            case .turquoise: return 2
            case .coral: return 3
            case .pearl: return 4
            case .jade: return 5
            case .grain: return 6
            }
        }()
        var rng = SeededRNG(seed: kindSeed &* 747796405 &+ 11)
        let isGrain = kind == .grain
        let paletteScale: Float = 0.85

        if isGrain {
            addRiceGrains(to: root, count: paletteParticleCount, scale: paletteScale, materials: riceMaterials, rng: &rng)
        } else {
            addCrystalGems(
                to: root,
                count: paletteParticleCount,
                scale: paletteScale,
                materials: [material(for: kind)] + crystalGemMaterials,
                rng: &rng,
                sizeRange: (0.0022, 0.0036),
                preferPrimaryMaterial: true
            )
        }

        if selected {
            let halo = ModelEntity(
                mesh: .generateSphere(radius: 0.045),
                materials: [UnlitMaterial(color: UIColor(white: 1, alpha: 0.35))]
            )
            halo.position = SIMD3(0, 0.022, 0)
            root.addChild(halo)
        }

        let shape = ShapeResource.generateSphere(radius: 0.08)
        root.components.set(CollisionComponent(shapes: [shape], mode: .trigger))
        root.components.set(InputTargetComponent())
        root.components.set(PaletteItemComponent(materialKindRaw: kind.rawValue))

        return root
    }

    private static func styleLabel(_ style: OfferingMoundStyle) -> String {
        switch style {
        case .rice: return "rice"
        case .mixedOffering: return "mixed"
        case .crystal: return "crystal"
        case .pastelCrystal: return "pastel"
        case .tintedCrystal: return "tinted"
        }
    }

    private static func addRiceGrains(
        to root: Entity,
        count: Int,
        scale: Float,
        materials: [SimpleMaterial],
        bulkMaterial: SimpleMaterial? = nil,
        rng: inout SeededRNG
    ) {
        // Wide overflowing footprint so each offering fills more of its sector.
        let baseRadius = 0.145 * scale
        let moundHeight = 0.125 * scale
        guard !materials.isEmpty, count > 0 else { return }

        addBulkDome(
            to: root,
            name: "MoundBulk_rice",
            radius: baseRadius * 0.92,
            height: moundHeight * 0.88,
            material: bulkMaterial ?? materials[0]
        )

        // Bake fine grains into a few tint meshes (simple + readable).
        let scatterCount = max(1, Int(Float(count) * 0.28 + 0.5))
        let moundCount = count - scatterCount
        let bucketCount = materials.count
        var positionsByBucket = Array(repeating: [SIMD3<Float>](), count: bucketCount)
        var indicesByBucket = Array(repeating: [UInt32](), count: bucketCount)

        for _ in 0..<moundCount {
            let (x, yNorm, z) = sampleHemispheroid(rng: &rng)
            let center = SIMD3(x * baseRadius, yNorm * moundHeight + 0.002 * scale, z * baseRadius)
            let len = rng.range(0.0028, 0.0046) * scale
            let thick = len * rng.range(0.32, 0.44)
            let half = SIMD3(thick * 0.5, len * rng.range(0.55, 0.70), thick * 0.5)
            let orient = riceOrientation(rng: &rng, lyingFlatBias: 0.40)
            let bucket = Int(rng.next() % UInt64(bucketCount))
            appendOrientedBox(
                center: center,
                halfExtents: half,
                orientation: orient,
                positions: &positionsByBucket[bucket],
                indices: &indicesByBucket[bucket]
            )
        }

        for _ in 0..<scatterCount {
            let angle = rng.unit() * (.pi * 2)
            let radial = rng.range(0.60, 1.65) * baseRadius
            let center = SIMD3(cos(angle) * radial, rng.range(0.001, 0.008) * scale, sin(angle) * radial)
            let len = rng.range(0.0024, 0.0040) * scale
            let thick = len * rng.range(0.30, 0.42)
            let half = SIMD3(thick * 0.5, len * rng.range(0.50, 0.65), thick * 0.5)
            let orient = riceOrientation(rng: &rng, lyingFlatBias: 0.90)
            let bucket = Int(rng.next() % UInt64(bucketCount))
            appendOrientedBox(
                center: center,
                halfExtents: half,
                orientation: orient,
                positions: &positionsByBucket[bucket],
                indices: &indicesByBucket[bucket]
            )
        }

        for bucket in 0..<bucketCount {
            guard let mesh = makeTriangleMesh(
                name: "RiceCloud_\(bucket)",
                positions: positionsByBucket[bucket],
                indices: indicesByBucket[bucket]
            ) else { continue }
            let cloud = ModelEntity(mesh: mesh, materials: [materials[bucket]])
            cloud.name = "RiceCloud_\(bucket)"
            root.addChild(cloud)
        }
    }

    /// Soft hemispheroid under grains so the bulge reads as a solid overflowing mound.
    private static func addBulkDome(
        to root: Entity,
        name: String,
        radius: Float,
        height: Float,
        material: SimpleMaterial
    ) {
        let bulk = ModelEntity(mesh: particleMesh, materials: [material])
        bulk.name = name
        bulk.scale = SIMD3(radius, height * 0.55, radius)
        bulk.position = SIMD3(0, height * 0.42, 0)
        root.addChild(bulk)
    }

    /// Uniform sample in the upper unit hemispheroid (x²+z²+y² ≤ 1, y ≥ 0).
    private static func sampleHemispheroid(rng: inout SeededRNG) -> (Float, Float, Float) {
        for _ in 0..<24 {
            let x = rng.range(-1, 1)
            let y = rng.range(0, 1)
            let z = rng.range(-1, 1)
            if x * x + y * y + z * z <= 1 {
                return (x, y, z)
            }
        }
        let angle = rng.unit() * (.pi * 2)
        let r = sqrt(rng.unit()) * 0.85
        return (cos(angle) * r, rng.range(0.05, 0.55), sin(angle) * r)
    }

    /// Random rice-grain orientation; `lyingFlatBias` near 1 prefers grains flat on the deck.
    private static func riceOrientation(rng: inout SeededRNG, lyingFlatBias: Float) -> simd_quatf {
        let yaw = rng.range(0, .pi * 2)
        let tipTowardFlat = rng.unit() < lyingFlatBias
        let pitch: Float = tipTowardFlat
            ? rng.range(.pi * 0.35, .pi * 0.55)
            : rng.range(0, .pi * 0.55)
        let roll = rng.range(-0.35, 0.35)
        let qYaw = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))
        let qPitch = simd_quatf(angle: pitch, axis: SIMD3(1, 0, 0))
        let qRoll = simd_quatf(angle: roll, axis: SIMD3(0, 0, 1))
        return qYaw * qPitch * qRoll
    }

    /// Append an oriented box (elongated rice capsule stand-in) into a triangle soup.
    private static func appendOrientedBox(
        center: SIMD3<Float>,
        halfExtents: SIMD3<Float>,
        orientation: simd_quatf,
        positions: inout [SIMD3<Float>],
        indices: inout [UInt32]
    ) {
        let corners: [SIMD3<Float>] = [
            SIMD3(-1, -1, -1), SIMD3(1, -1, -1), SIMD3(1, -1, 1), SIMD3(-1, -1, 1),
            SIMD3(-1, 1, -1), SIMD3(1, 1, -1), SIMD3(1, 1, 1), SIMD3(-1, 1, 1)
        ]
        let base = UInt32(positions.count)
        for corner in corners {
            let local = corner * halfExtents
            positions.append(center + simd_act(orientation, local))
        }
        let faces: [[UInt32]] = [
            [0, 2, 1, 0, 3, 2],
            [4, 5, 6, 4, 6, 7],
            [0, 1, 5, 0, 5, 4],
            [3, 7, 6, 3, 6, 2],
            [0, 4, 7, 0, 7, 3],
            [1, 2, 6, 1, 6, 5]
        ]
        for face in faces {
            for idx in face {
                indices.append(base + idx)
            }
        }
    }

    /// Builds a mesh with per-face normals (vertices duplicated per triangle) for SimpleMaterial lighting.
    private static func makeTriangleMesh(
        name: String,
        positions: [SIMD3<Float>],
        indices: [UInt32]
    ) -> MeshResource? {
        guard !positions.isEmpty, !indices.isEmpty, indices.count % 3 == 0 else { return nil }

        var expandedPositions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var expandedIndices: [UInt32] = []
        expandedPositions.reserveCapacity(indices.count)
        normals.reserveCapacity(indices.count)
        expandedIndices.reserveCapacity(indices.count)

        for t in stride(from: 0, to: indices.count, by: 3) {
            let p0 = positions[Int(indices[t])]
            let p1 = positions[Int(indices[t + 1])]
            let p2 = positions[Int(indices[t + 2])]
            let cross = simd_cross(p1 - p0, p2 - p0)
            let length = simd_length(cross)
            guard length > 1e-8 else { continue }
            let n = cross / length
            let base = UInt32(expandedPositions.count)
            expandedPositions.append(contentsOf: [p0, p1, p2])
            normals.append(contentsOf: [n, n, n])
            expandedIndices.append(contentsOf: [base, base + 1, base + 2])
        }

        guard !expandedPositions.isEmpty else { return nil }
        var descriptor = MeshDescriptor(name: name)
        descriptor.positions = MeshBuffer(expandedPositions)
        descriptor.normals = MeshBuffer(normals)
        descriptor.primitives = .triangles(expandedIndices)
        return try? MeshResource.generate(from: [descriptor])
    }

    private static func addCrystalGems(
        to root: Entity,
        count: Int,
        scale: Float,
        materials: [any Material],
        rng: inout SeededRNG,
        sizeRange: (Float, Float),
        preferPrimaryMaterial: Bool = false,
        addBulkDome: Bool = true
    ) {
        let baseRadius = 0.130 * scale
        let moundHeight = 0.115 * scale
        guard !materials.isEmpty, count > 0 else { return }
        let materialCount = materials.count

        if addBulkDome {
            if let primary = materials.first as? SimpleMaterial {
                self.addBulkDome(
                    to: root,
                    name: "MoundBulk_crystal",
                    radius: baseRadius * 0.90,
                    height: moundHeight * 0.84,
                    material: primary
                )
            } else {
                var fallback = SimpleMaterial()
                fallback.color = .init(tint: UIColor(red: 0.85, green: 0.75, blue: 0.55, alpha: 1))
                fallback.metallic = .float(0.55)
                fallback.roughness = .float(0.35)
                self.addBulkDome(
                    to: root,
                    name: "MoundBulk_crystal",
                    radius: baseRadius * 0.90,
                    height: moundHeight * 0.84,
                    material: fallback
                )
            }
        }

        // Bake fine gems into one mesh per material.
        var positionsByBucket = Array(repeating: [SIMD3<Float>](), count: materialCount)
        var indicesByBucket = Array(repeating: [UInt32](), count: materialCount)

        let scatterCount = max(1, Int(Float(count) * 0.26 + 0.5))
        let moundCount = count - scatterCount

        for i in 0..<moundCount {
            let (x, yNorm, z) = sampleHemispheroid(rng: &rng)
            let center = SIMD3(x * baseRadius, yNorm * moundHeight + 0.002 * scale, z * baseRadius)
            let r = rng.range(sizeRange.0, sizeRange.1) * scale
            let half = SIMD3(
                r * rng.range(0.85, 1.05),
                r * rng.range(0.75, 0.95),
                r * rng.range(0.85, 1.05)
            )
            let orient = simd_quatf(angle: rng.range(0, .pi), axis: SIMD3(0, 1, 0))
            let bucket: Int
            if preferPrimaryMaterial, i < moundCount / 2 {
                bucket = 0
            } else {
                bucket = Int(rng.next() % UInt64(materialCount))
            }
            appendOrientedBox(
                center: center,
                halfExtents: half,
                orientation: orient,
                positions: &positionsByBucket[bucket],
                indices: &indicesByBucket[bucket]
            )
        }

        for i in 0..<scatterCount {
            let angle = rng.unit() * (.pi * 2)
            let radial = rng.range(0.60, 1.55) * baseRadius
            let center = SIMD3(cos(angle) * radial, rng.range(0.001, 0.008) * scale, sin(angle) * radial)
            let r = rng.range(sizeRange.0, sizeRange.1) * scale * 0.9
            let half = SIMD3(r, r * rng.range(0.55, 0.8), r)
            let orient = simd_quatf(angle: rng.range(0, .pi), axis: SIMD3(0, 1, 0))
            let bucket: Int = preferPrimaryMaterial && i % 2 == 0
                ? 0
                : Int(rng.next() % UInt64(materialCount))
            appendOrientedBox(
                center: center,
                halfExtents: half,
                orientation: orient,
                positions: &positionsByBucket[bucket],
                indices: &indicesByBucket[bucket]
            )
        }

        for bucket in 0..<materialCount {
            guard let mesh = makeTriangleMesh(
                name: "CrystalCloud_\(bucket)",
                positions: positionsByBucket[bucket],
                indices: indicesByBucket[bucket]
            ) else { continue }
            let cloud = ModelEntity(mesh: mesh, materials: [materials[bucket]])
            cloud.name = "CrystalCloud_\(bucket)"
            root.addChild(cloud)
        }
    }

    /// Deterministic xorshift64* RNG so mound layouts stay stable per heap number.
    private struct SeededRNG {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed == 0 ? 0xC0FFEE : seed
        }

        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }

        mutating func unit() -> Float {
            Float(next() % 10_000) / 10_000
        }

        mutating func range(_ lo: Float, _ hi: Float) -> Float {
            lo + unit() * (hi - lo)
        }
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
