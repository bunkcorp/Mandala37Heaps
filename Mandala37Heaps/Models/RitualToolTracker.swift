import Foundation
import RealityKit
import simd
import UIKit

#if os(visionOS)
import ARKit
#endif

/// Tracks a ritual scoop: right-hand phalanx capsules when available, else a draggable tool.
@MainActor
final class RitualToolTracker {
    private(set) var toolEntity = Entity()
    private(set) var localPositionInMandala: SIMD3<Float>?
    private(set) var isTrackingHand = false

    /// Latest mandala-local contact capsules (scoop or finger phalanges).
    private(set) var mandalaCapsules: [MPMCapsuleSDF] = []

#if os(visionOS)
    private let session = ARKitSession()
    private let handTracking = HandTrackingProvider()
#endif
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
#if os(visionOS)
        toolEntity.components.set(HoverEffectComponent())
#endif

        // Rest pose near the palette.
        toolEntity.position = SIMD3(0.28, 0.02, 0.52)
        if toolEntity.parent !== mandalaRoot {
            mandalaRoot.addChild(toolEntity)
        }
        refreshScoopCapsule()
    }

    func startHandTracking() {
#if os(visionOS)
        handTask?.cancel()
        handTask = Task { @MainActor in
            guard HandTrackingProvider.isSupported else {
                isTrackingHand = false
                refreshScoopCapsule()
                return
            }
            do {
                try await session.run([handTracking])
                isTrackingHand = true
                for await update in handTracking.anchorUpdates {
                    guard !Task.isCancelled else { return }
                    guard update.anchor.chirality == .right,
                          let skeleton = update.anchor.handSkeleton else { continue }
                    guard let root = mandalaRoot else { continue }

                    let tip = skeleton.joint(.indexFingerTip)
                    guard tip.isTracked else { continue }

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

                    mandalaCapsules = Self.phalanxCapsules(
                        skeleton: skeleton,
                        anchor: update.anchor,
                        mandalaRoot: root
                    )
                }
            } catch {
                isTrackingHand = false
                refreshScoopCapsule()
                print("[RitualTool] hand tracking unavailable: \(error)")
            }
        }
#else
        // iOS: drag the scoop with touch; no hand skeleton tracking.
        isTrackingHand = false
        refreshScoopCapsule()
#endif
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
        refreshScoopCapsule()
    }

    /// Tool position in a tier's local space, if the tool is near that tier's deck.
    func toolPosition(in tierEntity: Entity) -> SIMD3<Float>? {
        guard let local = localPositionInMandala ?? Optional(toolEntity.position) else {
            return nil
        }
        guard let root = mandalaRoot else { return nil }
        let world = root.convert(position: local, to: nil)
        return tierEntity.convert(position: world, from: nil)
    }

    /// Phalanx / scoop capsules expressed in a tier's local space for MPM SDF contact.
    func contactCapsules(in tierEntity: Entity) -> [MPMCapsuleSDF] {
        guard let root = mandalaRoot else { return [] }
        let source = mandalaCapsules.isEmpty ? [scoopCapsuleMandala()] : mandalaCapsules
        return source.map { capsule in
            let p0World = root.convert(position: capsule.p0, to: nil)
            let p1World = root.convert(position: capsule.p1, to: nil)
            return MPMCapsuleSDF(
                p0: tierEntity.convert(position: p0World, from: nil),
                p1: tierEntity.convert(position: p1World, from: nil),
                radius: capsule.radius
            )
        }
    }

    // MARK: - Capsules

    private func refreshScoopCapsule() {
        mandalaCapsules = [scoopCapsuleMandala()]
    }

    private func scoopCapsuleMandala() -> MPMCapsuleSDF {
        let p = localPositionInMandala ?? toolEntity.position
        return MPMCapsuleSDF(
            p0: p + SIMD3(0, -0.008, 0),
            p1: p + SIMD3(0, 0.012, 0),
            radius: 0.022
        )
    }

#if os(visionOS)
    private static func phalanxCapsules(
        skeleton: HandSkeleton,
        anchor: HandAnchor,
        mandalaRoot: Entity
    ) -> [MPMCapsuleSDF] {
        let chains: [(HandSkeleton.JointName, HandSkeleton.JointName, Float)] = [
            (.indexFingerKnuckle, .indexFingerIntermediateBase, 0.012),
            (.indexFingerIntermediateBase, .indexFingerIntermediateTip, 0.011),
            (.indexFingerIntermediateTip, .indexFingerTip, 0.010),
            (.middleFingerIntermediateTip, .middleFingerTip, 0.010),
            (.thumbIntermediateTip, .thumbTip, 0.012)
        ]

        var capsules: [MPMCapsuleSDF] = []
        for (a, b, radius) in chains {
            let ja = skeleton.joint(a)
            let jb = skeleton.joint(b)
            guard ja.isTracked, jb.isTracked else { continue }
            let wa = worldPosition(joint: ja, anchor: anchor)
            let wb = worldPosition(joint: jb, anchor: anchor)
            capsules.append(
                MPMCapsuleSDF(
                    p0: mandalaRoot.convert(position: wa, from: nil),
                    p1: mandalaRoot.convert(position: wb, from: nil),
                    radius: radius
                )
            )
        }
        return capsules
    }

    private static func worldPosition(
        joint: HandSkeleton.Joint,
        anchor: HandAnchor
    ) -> SIMD3<Float> {
        let t = anchor.originFromAnchorTransform * joint.anchorFromJointTransform
        return SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
    }
#endif
}
