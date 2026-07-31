import SwiftUI

@main
struct Mandala37HeapsApp: App {
    @State private var appModel = AppModel()

    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase

    init() {
        HeapSlotComponent.register()
        PaletteItemComponent.register()
        GrainFillComponent.register()
        PhysicalGrainComponent.register()
    }

    var body: some Scene {
        makeVisionScenes()
            .environment(appModel)
            .onChange(of: appModel.viewState) { _, toState in
                Task { @MainActor in
                    switch toState {
                    case .immersive:
                        await enterImmersivePresentation()
                    case .portal:
                        await exitImmersivePresentation()
                    }
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .background {
                    appModel.handleBackground()
                }
            }
    }

    @SceneBuilder
    private func makeVisionScenes() -> some Scene {
        ContentWindow()
        ImmersiveScene()
    }

    private func enterImmersivePresentation() async {
        guard appModel.immersiveSpaceState == .closed else { return }
        appModel.immersiveSpaceState = .inTransition
        switch await openImmersiveSpace(id: ImmersiveScene.sceneID) {
        case .opened:
            appModel.immersiveSpaceState = .open
            // Keep ContentWindow open for gameplay controls — ornaments are not
            // supported inside ImmersiveSpace.
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
}
