import SwiftUI

@main
struct PortviewHostApp: App {
    @State private var model = HostAppModel()

    var body: some Scene {
        WindowGroup("Portview Host") {
            ContentView(model: model)
                .onDisappear { model.stop() }
        }
        .defaultSize(width: 640, height: 560)
        .windowResizability(.contentMinSize)
    }
}
