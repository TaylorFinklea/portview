// SPDX-License-Identifier: Apache-2.0
import SwiftUI

@main
struct PortviewClientApp: App {
    /// CloudKit re-wake needs a UIKit delegate seam (spec §2a.4): the adaptor is the only place
    /// the silent-push background callback can land in a pure-SwiftUI app.
    @UIApplicationDelegateAdaptor(ReWakeAppDelegate.self) private var reWakeDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
