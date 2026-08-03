import SwiftUI

@main
struct Mandala37HeapsApp: App {
    @State private var appModel = AppModel()

#if os(visionOS)
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.openWindow) private var openWindow
#endif
    @Environment(\.scenePhase) private var scenePhase

    init() {
        HeapSlotComponent.register()
        PaletteItemComponent.register()
        GrainFillComponent.register()
        PhysicalGrainComponent.register()
    }

    var body: some Scene {
        WindowGroup(id: ContentWindow.sceneID) {
            ContentView()
        }
#if os(visionOS)
        .windowStyle(.plain)
        .defaultSize(width: 560, height: 640)
#endif
        .environment(appModel)
        .onChange(of: appModel.viewState) { _, toState in
            Task { @MainActor in
                switch toState {
                case .immersive:
#if os(visionOS)
                    await enterImmersivePresentation()
#endif
                case .portal:
#if os(visionOS)
                    await exitImmersivePresentation()
#endif
                    break
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                appModel.handleBackground()
            }
        }

#if os(visionOS)
        ImmersiveScene()
            .environment(appModel)
#endif
    }

#if os(visionOS)
    private func enterImmersivePresentation() async {
        guard appModel.immersiveSpaceState == .closed else { return }
        appModel.immersiveSpaceState = .inTransition
        switch await openImmersiveSpace(id: ImmersiveScene.sceneID) {
        case .opened:
            appModel.immersiveSpaceState = .open
        case .userCancelled, .error:
            fallthrough
        @unknown default:
            appModel.immersiveSpaceState = .closed
            appModel.viewState = .portal
        }
    }

    private func exitImmersivePresentation() async {
        guard appModel.immersiveSpaceState == .open else { return }
        appModel.immersiveSpaceState = .inTransition
        await dismissImmersiveSpace()
        appModel.immersiveSpaceState = .closed
        openWindow(id: ContentWindow.sceneID)
    }
#endif
}
