// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// The menu bar IS the app (2026-07-28 ADR): no window scene, `LSUIElement` hides the Dock icon.
@main
struct PortviewHostApp: App {
    @State private var model: HostAppModel

    init() {
        // App-lifetime start, independent of the popover: a login-item launch must reach a listening
        // host and live permission status without anyone opening the menu. `start()` and
        // `startPermissionMonitoring()` are idempotent; App.init runs once per process.
        let model = HostAppModel()
        _model = State(initialValue: model)
        Task { @MainActor in
            model.start()
            model.startPermissionMonitoring()
            await model.refreshEnrolledDevices()
        }
    }

    var body: some Scene {
        MenuBarExtra("Portview Host", systemImage: model.menuBarSymbol) {
            MenuBarHostView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
