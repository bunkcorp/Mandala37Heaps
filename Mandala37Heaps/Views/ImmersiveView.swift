import RealityKit
import SwiftUI

struct ImmersiveView: View {
    @Environment(AppModel.self) private var appModel
    @State private var toolDragStart: SIMD3<Float>?

    var body: some View {
        RealityView { content in
            appModel.prepareMandalaIfNeeded()
            if appModel.mandalaRoot.parent == nil {
                content.add(appModel.mandalaRoot)
            }
        } update: { content in
            if appModel.mandalaRoot.parent == nil {
                content.add(appModel.mandalaRoot)
            }
        }
        .gesture(
            SpatialTapGesture()
                .targetedToAnyEntity()
                .onEnded { value in
                    if appModel.isRitualTool(value.entity) { return }
                    appModel.handleTap(on: value.entity)
                }
        )
        .gesture(
            DragGesture()
                .targetedToAnyEntity()
                .onChanged { value in
                    guard appModel.isRitualTool(value.entity) else { return }
                    if toolDragStart == nil {
                        toolDragStart = appModel.ritualTool.toolEntity.position
                    }
                    let start = toolDragStart ?? .zero
                    // Map screen drag into a gentle mandala-local slide on the XZ plane.
                    let dx = Float(value.translation3D.x) * 0.0015
                    let dy = Float(value.translation3D.y) * 0.0012
                    let dz = Float(value.translation3D.z) * 0.0015
                    appModel.ritualTool.updateDraggedPosition(
                        start + SIMD3(dx, dy, dz)
                    )
                }
                .onEnded { _ in
                    toolDragStart = nil
                }
        )
#if DEBUG
        .task {
            guard !appModel.didRunDebugGameplay else { return }
            let arguments = ProcessInfo.processInfo.arguments
            guard arguments.contains("-autoPlay") || arguments.contains("-autoDemo") else { return }
            appModel.didRunDebugGameplay = true
            try? await Task.sleep(for: .seconds(2))
            if arguments.contains("-autoPlay") {
                // Use gameplay autoplay (no post-run reset) so stacked rings stay visible.
                appModel.startAutoPlay()
            } else {
                await appModel.debugPlaceDemoHeaps()
            }
        }
#endif
    }
}
