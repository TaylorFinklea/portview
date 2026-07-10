// SPDX-License-Identifier: Apache-2.0
import SwiftUI

@main
struct PortviewHostApp: App {
    @State private var model = HostAppModel()
    static let mainWindowID = "main"

    var body: some Scene {
        WindowGroup("Portview Host", id: Self.mainWindowID) {
            ContentView(model: model)
        }
        .defaultSize(width: 820, height: 640)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)

        // Menu-bar presence: quick connect (QR / OTP-later) without the full window. Hosting now
        // outlives the window (no onDisappear stop) so closing it doesn't kill an active session.
        MenuBarExtra("Portview Host", systemImage: model.menuBarSymbol) {
            MenuBarHostView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
