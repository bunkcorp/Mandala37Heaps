import SwiftUI

struct ContentWindow: Scene {
    static let sceneID = "ContentWindow"

    var body: some Scene {
        WindowGroup(id: Self.sceneID) {
            ContentView()
        }
        .windowStyle(.plain)
        .defaultSize(width: 560, height: 640)
    }
}
