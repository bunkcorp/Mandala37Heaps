import Foundation
import RealityKit
import simd
import UIKit

/// Hybrid grain physics: a few hundred rigid clusters + procedural bulk fill.
enum GrainPhysics {
    static let clustersPerOffering = 18
    static let maxDynamicClusters = 150
    static let maxVisibleClusters = 520
    static let settleLinearSpeed: Float = 0.008
    static let settleAngularSpeed: Float = 0.08

    private static let grainMaterial = PhysicsMaterialResource.generate(
        staticFriction: 0.75,
        dynamicFriction: 0.65,
        restitution: 0.02
    )

    private static let structureMaterial = PhysicsMaterialResource.generate(
        staticFriction: 0.85,
        dynamicFriction: 0.75,
        restitution: 0.0
    )

    private static let riceMesh = MeshResource.generateCylinder(height: 1, radius: 0.28)
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

    // MARK: - Structure colliders

    static func attachPlateCollider(to plateRoot: Entity, radius: Float, topY: Float) {
        let floor = Entity()
        floor.name = "PlateCollider"
        floor.position = SIMD3(0, topY, 0)
        // ShapeResource has no cylinder helper — a thin box approximates the plate top.
        let shape = ShapeResource.generateBox(size: SIMD3(radius * 2, 0.012, radius * 2))
        floor.components.set(CollisionComponent(shapes: [shape]))
        floor.components.set(
            PhysicsBodyComponent(
                massProperties: .default,
                material: structureMaterial,
                mode: .static
            )
        )
        plateRoot.addChild(floor)
    }

    /// Open ring wall from narrow boxes — does not block the interior.
    static func makeRingCollisionShapes(
        radius: Float,
        wallHeight: Float,
        wallThickness: Float,
        segments: Int = 24
    ) -> [ShapeResource] {
        var shapes: [ShapeResource] = []
        let circumference = 2 * Float.pi * radius
        let segmentWidth = circumference / Float(segments)

        for index in 0..<segments {
            let angle = 2 * Float.pi * Float(index) / Float(segments)
            // MetalRing local origin is mid-wall (y = 0), matching visual box segments.
            let shape = ShapeResource
                .generateBox(
                    size: SIMD3(wallThickness, wallHeight, segmentWidth * 1.08)
                )
                .offsetBy(
                    rotation: simd_quatf(angle: -angle, axis: SIMD3(0, 1, 0)),
                    translation: SIMD3(cos(angle) * radius, 0, sin(angle) * radius)
                )
            shapes.append(shape)
        }
        return shapes
    }

    static func attachRingPhysics(
        to ring: Entity,
        radius: Float,
        height: Float,
        thickness: Float,
        mode: PhysicsBodyMode
    ) {
        let shapes = makeRingCollisionShapes(
            radius: radius,
            wallHeight: height,
            wallThickness: thickness
        )
        ring.components.set(CollisionComponent(shapes: shapes))
        ring.components.set(
            PhysicsBodyComponent(
                massProperties: .default,
                material: structureMaterial,
                mode: mode
            )
        )
    }

    static func setRingPhysicsMode(_ ring: Entity, mode: PhysicsBodyMode) {
        guard var body = ring.components[PhysicsBodyComponent.self] else { return }
        body.mode = mode
        ring.components.set(body)
    }

    /// Thin static disc that tracks the rising bulk so clusters rest on packed grain.
    static func makeGrainSurfaceCollider(radius: Float, atY: Float) -> Entity {
        let collider = Entity()
        collider.name = "GrainSurfaceCollider"
        collider.position = SIMD3(0, atY, 0)
        let diameter = radius * 0.98 * 2
        let shape = ShapeResource.generateBox(size: SIMD3(diameter, 0.01, diameter))
        collider.components.set(CollisionComponent(shapes: [shape]))
        collider.components.set(
            PhysicsBodyComponent(
                massProperties: .default,
                material: structureMaterial,
                mode: .static
            )
        )
        return collider
    }

    static func updateGrainSurfaceCollider(
        in fillRoot: Entity,
        maximumHeight: Float,
        progress: Float
    ) {
        let y = maximumHeight * progress
        if let collider = fillRoot.findEntity(named: "GrainSurfaceCollider") {
            collider.position.y = y
        }
    }

    // MARK: - Grain clusters

    static func physicalGrainsBucket(in tierEntity: Entity) -> Entity {
        let surface = tierEntity.findEntity(named: "TierSurface") ?? tierEntity
        if let existing = surface.findEntity(named: "PhysicalGrains") {
            return existing
        }
        let bucket = Entity()
        bucket.name = "PhysicalGrains"
        surface.addChild(bucket)
        return bucket
    }

    static func makePhysicalGrainCluster(tier: MandalaTier, seed: Int) -> Entity {
        let root = Entity()
        root.name = "GrainCluster_\(seed)"

        // Visual cluster: a few fused grains as one rigid body.
        for i in 0..<4 {
            let grain = ModelEntity(
                mesh: riceMesh,
                materials: [riceMaterials[(seed + i) % riceMaterials.count]]
            )
            let len: Float = 0.008 + Float(i % 3) * 0.0006
            grain.scale = SIMD3(0.0026, len, 0.0026)
            let a = Float(i) * 1.7 + Float(seed) * 0.11
            grain.position = SIMD3(
                cos(a) * 0.0018,
                Float(i) * 0.0011 - 0.0015,
                sin(a) * 0.0018
            )
            grain.orientation = simd_quatf(angle: a, axis: simd_normalize(SIMD3(0.3, 1, 0.2)))
            root.addChild(grain)
        }

        root.components.set(
            CollisionComponent(
                shapes: [.generateCapsule(height: 0.010, radius: 0.0024)]
            )
        )
        root.components.set(
            PhysicsBodyComponent(
                massProperties: .init(mass: 0.00015),
                material: grainMaterial,
                mode: .dynamic
            )
        )
        root.components.set(PhysicsMotionComponent())
        root.components.set(
            PhysicalGrainComponent(
                tierRaw: tier.rawValue,
                birthTime: Date().timeIntervalSinceReferenceDate,
                isFrozen: false
            )
        )
        return root
    }

    /// Drop 10–25 clusters above a slot so they fall into the ring.
    @discardableResult
    static func emitClusters(
        into tierEntity: Entity,
        tier: MandalaTier,
        at localXZ: SIMD2<Float>,
        count: Int = clustersPerOffering
    ) -> [Entity] {
        let bucket = physicalGrainsBucket(in: tierEntity)
        enforceBudgets(on: bucket, preferringFreeze: true)

        let fillProgress = tierEntity
            .findEntity(named: "TierFill")?
            .components[GrainFillComponent.self]?.progress ?? 0.03
        let maxH = tierEntity
            .findEntity(named: "TierFill")?
            .components[GrainFillComponent.self]?.maximumHeight ?? tier.ringHeight
        let surfaceY = maxH * fillProgress

        var spawned: [Entity] = []
        let emitCount = min(count, max(10, clustersPerOffering))
        for i in 0..<emitCount {
            enforceDynamicCap(on: bucket)
            let cluster = makePhysicalGrainCluster(tier: tier, seed: i &+ tier.rawValue &* 97)
            let angle = Float(i) * 2.39996323
            let radial = 0.008 + Float(i % 5) * 0.004
            cluster.position = SIMD3(
                localXZ.x + cos(angle) * radial,
                surfaceY + 0.055 + Float(i) * 0.007,
                localXZ.y + sin(angle) * radial
            )
            cluster.orientation = simd_quatf(
                angle: Float(i) * 0.7,
                axis: SIMD3(0, 1, 0)
            )
            bucket.addChild(cluster)
            spawned.append(cluster)
        }
        return spawned
    }

    static func isSettled(_ entity: Entity) -> Bool {
        guard let motion = entity.components[PhysicsMotionComponent.self] else {
            return false
        }
        let linearSpeed = length(motion.linearVelocity)
        let angularSpeed = length(motion.angularVelocity)
        return linearSpeed < settleLinearSpeed && angularSpeed < settleAngularSpeed
    }

    static func freezeGrain(_ grain: Entity) {
        guard var body = grain.components[PhysicsBodyComponent.self] else { return }
        body.mode = .static
        grain.components.set(body)
        if var component = grain.components[PhysicalGrainComponent.self] {
            component.isFrozen = true
            grain.components.set(component)
        }
        // Clear residual velocity.
        if var motion = grain.components[PhysicsMotionComponent.self] {
            motion.linearVelocity = .zero
            motion.angularVelocity = .zero
            grain.components.set(motion)
        }
    }

    static func freezeSettledGrains(in tierEntity: Entity) {
        let bucket = physicalGrainsBucket(in: tierEntity)
        for child in bucket.children {
            guard let component = child.components[PhysicalGrainComponent.self],
                  !component.isFrozen,
                  isSettled(child) else { continue }
            freezeGrain(child)
        }
    }

    /// Remove buried / excess frozen clusters once the bulk has absorbed them visually.
    static func absorbBuriedAndExcess(
        in tierEntity: Entity,
        fillProgress: Float
    ) {
        let bucket = physicalGrainsBucket(in: tierEntity)
        let maxH = tierEntity
            .findEntity(named: "TierFill")?
            .components[GrainFillComponent.self]?.maximumHeight ?? MandalaTier.ringWallHeight
        let surfaceY = maxH * fillProgress
        let buryY = surfaceY - 0.012

        let frozen = bucket.children.filter {
            $0.components[PhysicalGrainComponent.self]?.isFrozen == true
        }
        // Absorb clusters clearly under the bulk surface.
        for grain in frozen where grain.position.y < buryY {
            grain.removeFromParent()
        }

        let remainingFrozen = bucket.children.filter {
            $0.components[PhysicalGrainComponent.self]?.isFrozen == true
        }
        .sorted {
            ($0.components[PhysicalGrainComponent.self]?.birthTime ?? 0)
                < ($1.components[PhysicalGrainComponent.self]?.birthTime ?? 0)
        }
        let overflow = remainingFrozen.count - maxVisibleClusters
        if overflow > 0 {
            for grain in remainingFrozen.prefix(overflow) {
                grain.removeFromParent()
            }
        }
    }

    private static func enforceBudgets(on bucket: Entity, preferringFreeze: Bool) {
        if preferringFreeze {
            for child in bucket.children {
                guard let component = child.components[PhysicalGrainComponent.self],
                      !component.isFrozen,
                      isSettled(child) else { continue }
                freezeGrain(child)
            }
        }
        enforceDynamicCap(on: bucket)

        let all = bucket.children.filter {
            $0.components[PhysicalGrainComponent.self] != nil
        }
        if all.count > maxVisibleClusters {
            let frozen = all
                .filter { $0.components[PhysicalGrainComponent.self]?.isFrozen == true }
                .sorted {
                    ($0.components[PhysicalGrainComponent.self]?.birthTime ?? 0)
                        < ($1.components[PhysicalGrainComponent.self]?.birthTime ?? 0)
                }
            let removeCount = all.count - maxVisibleClusters
            for grain in frozen.prefix(removeCount) {
                grain.removeFromParent()
            }
        }
    }

    private static func enforceDynamicCap(on bucket: Entity) {
        let dynamic = bucket.children.filter {
            $0.components[PhysicalGrainComponent.self]?.isFrozen == false
        }
        .sorted {
            ($0.components[PhysicalGrainComponent.self]?.birthTime ?? 0)
                < ($1.components[PhysicalGrainComponent.self]?.birthTime ?? 0)
        }
        let overflow = dynamic.count - maxDynamicClusters + 1
        guard overflow > 0 else { return }
        for grain in dynamic.prefix(overflow) {
            freezeGrain(grain)
        }
    }
}
