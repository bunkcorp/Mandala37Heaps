import SwiftUI

@main
struct Mandala37HeapsApp: App {
    @State private var appModel = AppModel()

    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase

    init() {
        HeapSlotComponent.register()
        PaletteItemComponent.register()
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
            try? await Task.sleep(for: .milliseconds(250))
            dismissWindow(id: ContentWindow.sceneID)
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
