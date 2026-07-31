import RealityKit
import SwiftUI

struct ImmersiveView: View {
    @Environment(AppModel.self) private var appModel

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
                    appModel.handleTap(on: value.entity)
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
