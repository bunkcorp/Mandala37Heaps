import ARKit
import Foundation
import RealityKit
import simd
import UIKit

/// Tracks a ritual scoop: right index tip when hands are available, else a draggable tool.
@MainActor
final class RitualToolTracker {
    private(set) var toolEntity = Entity()
    private(set) var localPositionInMandala: SIMD3<Float>?
    private(set) var isTrackingHand = false

    private let session = ARKitSession()
    private let handTracking = HandTrackingProvider()
    private var handTask: Task<Void, Never>?
    private var mandalaRoot: Entity?

    func attach(to mandalaRoot: Entity) {
        self.mandalaRoot = mandalaRoot
        toolEntity.name = "RitualScoop"
        toolEntity.children.removeAll()

        // Small gold scoop visual.
        var gold = SimpleMaterial()
        gold.color = .init(tint: .init(red: 0.9, green: 0.74, blue: 0.28, alpha: 1))
        gold.metallic = .float(0.9)
        gold.roughness = .float(0.28)

        let bowl = ModelEntity(
            mesh: .generateSphere(radius: 0.018),
            materials: [gold]
        )
        bowl.scale = SIMD3(1.1, 0.45, 1.1)
        toolEntity.addChild(bowl)

        let handle = ModelEntity(
            mesh: .generateCylinder(height: 0.07, radius: 0.004),
            materials: [gold]
        )
        handle.position = SIMD3(0, 0.03, 0)
        toolEntity.addChild(handle)

        // Interaction for drag fallback in simulator / without hands.
        let shape = ShapeResource.generateSphere(radius: 0.04)
        toolEntity.components.set(CollisionComponent(shapes: [shape]))
        toolEntity.components.set(InputTargetComponent())
        toolEntity.components.set(HoverEffectComponent())

        // Rest pose near the palette.
        toolEntity.position = SIMD3(0.28, 0.02, 0.52)
        if toolEntity.parent !== mandalaRoot {
            mandalaRoot.addChild(toolEntity)
        }
    }

    func startHandTracking() {
        handTask?.cancel()
        handTask = Task { @MainActor in
            guard HandTrackingProvider.isSupported else {
                isTrackingHand = false
                return
            }
            do {
                try await session.run([handTracking])
                isTrackingHand = true
                for await update in handTracking.anchorUpdates {
                    guard !Task.isCancelled else { return }
                    guard update.anchor.chirality == .right,
                          let skeleton = update.anchor.handSkeleton else { continue }
                    let tip = skeleton.joint(.indexFingerTip)
                    guard tip.isTracked, let root = mandalaRoot else { continue }

                    let jointToWorld = update.anchor.originFromAnchorTransform
                        * tip.anchorFromJointTransform
                    let worldPos = SIMD3(
                        jointToWorld.columns.3.x,
                        jointToWorld.columns.3.y,
                        jointToWorld.columns.3.z
                    )
                    let local = root.convert(position: worldPos, from: nil)
                    toolEntity.position = local
                    localPositionInMandala = local
                }
            } catch {
                isTrackingHand = false
                print("[RitualTool] hand tracking unavailable: \(error)")
            }
        }
    }

    func stop() {
        handTask?.cancel()
        handTask = nil
        isTrackingHand = false
    }

    /// Called when the user drags the scoop (simulator / no hands).
    func updateDraggedPosition(_ local: SIMD3<Float>) {
        toolEntity.position = local
        localPositionInMandala = local
    }

    /// Tool position in a tier's local space, if the tool is near that tier's deck.
    func toolPosition(in tierEntity: Entity) -> SIMD3<Float>? {
        guard let local = localPositionInMandala ?? Optional(toolEntity.position) else {
            return nil
        }
        guard let root = mandalaRoot else { return nil }
        // Convert mandala-local tool → tier-local.
        let world = root.convert(position: local, to: nil)
        return tierEntity.convert(position: world, from: nil)
    }
}
