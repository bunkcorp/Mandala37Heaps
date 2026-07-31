import SwiftUI

struct ImmersiveScene: Scene {
    static let sceneID = "ImmersiveSpace"

    var body: some Scene {
        ImmersiveSpace(id: Self.sceneID) {
            ImmersiveView()
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
