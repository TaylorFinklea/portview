// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// Collapsed-by-default inline settings disclosure for the menu-bar popover. Privacy toggles call the
/// model's LAContext-gated methods and render the REAL stored state, so a cancelled/failed
/// authentication leaves the toggle off. Port/display apply at the next host start.
struct MenuBarSettingsView: View {
    let model: HostAppModel
    @ObservedObject var settings: HostSettingsCoordinator
    @ObservedObject var store: HostPreferencesStore
    @State private var expanded = false
    @State private var portText = ""
    @FocusState private var portFocused: Bool

    init(model: HostAppModel) {
        self.model = model
        settings = model.settings
        store = model.preferencesStore
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Settings").font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(Glass.text1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                launchAtLoginRow
                portRow
                displayRow
                Text("Port and display apply next time hosting starts.")
                    .font(.mono(9)).foregroundStyle(Glass.text3)
                toggleRow("Clipboard sync", on: store.preferences.clipboardEnabled,
                          set: model.setClipboardEnabled)
                toggleRow("File transfer", on: store.preferences.fileTransferEnabled,
                          set: model.setFileTransferEnabled)
                Text("Turning these on asks for your Mac password or Touch ID.")
                    .font(.mono(9)).foregroundStyle(Glass.text3)
            }
        }
        .onAppear {
            settings.refreshLaunchAtLogin()
            resetPortText()
        }
        // The popover closes on resign-key, so an edit that was typed but not submitted would be
        // lost silently: commit on disappear too (validation stays in the coordinator).
        .onDisappear { commitPortEdit() }
    }

    private func resetPortText() {
        portText = store.preferences.preferredPort.map(String.init) ?? ""
    }

    /// Commit the typed port; after a rejected value the inline error stays but the field reverts
    /// to the stored value so it never shows a port that is not in effect.
    private func commitPortEdit() {
        if !settings.commitPort(text: portText) { resetPortText() }
    }

    private var launchAtLoginRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { settings.launchAtLogin == .enabled },
                set: { settings.setLaunchAtLogin($0) })) {
                Text("Launch at login").font(.system(size: 12)).foregroundStyle(Glass.text1)
            }
            .toggleStyle(.switch).controlSize(.small)
            if settings.launchAtLogin == .requiresApproval {
                HStack {
                    Text("Needs approval in System Settings")
                        .font(.mono(10)).foregroundStyle(Glass.degraded)
                    Spacer()
                    Button("Open") { SMAppServiceLaunchAtLogin.openLoginItemsSettings() }
                        .buttonStyle(OutlineButtonStyle(tint: Glass.degraded))
                }
            }
            if let error = settings.launchAtLoginError {
                Text(error).font(.mono(9)).foregroundStyle(Glass.dangerText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var portRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Port").font(.system(size: 12)).foregroundStyle(Glass.text1)
                Spacer()
                TextField("Automatic", text: $portText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .multilineTextAlignment(.trailing)
                    .focused($portFocused)
                    .onSubmit { settings.commitPort(text: portText) }
                    .onChange(of: portFocused) { _, focused in
                        if !focused { commitPortEdit() }
                    }
            }
            if let error = settings.portError {
                Text(error).font(.mono(9)).foregroundStyle(Glass.dangerText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var displayRow: some View {
        let selection = HostSettingsCoordinator.displaySelection(
            preferred: store.preferences.preferredDisplayID,
            available: model.availableDisplays.map(\.id))
        return HStack {
            Text("Display").font(.system(size: 12)).foregroundStyle(Glass.text1)
            Spacer()
            Picker("Display", selection: Binding<UInt32?>(
                get: { selection },
                set: { store.preferences.preferredDisplayID = $0 })) {
                Text("Automatic").tag(UInt32?.none)
                ForEach(model.availableDisplays, id: \.id) { display in
                    Text("\(display.width)×\(display.height)").tag(UInt32?.some(display.id))
                }
            }
            .labelsHidden()
            .frame(width: 130)
        }
    }

    private func toggleRow(_ title: String, on: Bool, set: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { on }, set: set)) {
            Text(title).font(.system(size: 12)).foregroundStyle(Glass.text1)
        }
        .toggleStyle(.switch).controlSize(.small)
    }
}

/// "Send a file" — shown only while file transfer is on (UX only; the policy enforces it). A separate
/// view so it observes the preferences store, which the `@Observable` model does not track.
struct SendFileButton: View {
    let model: HostAppModel
    @ObservedObject private var store: HostPreferencesStore

    init(model: HostAppModel) {
        self.model = model
        store = model.preferencesStore
    }

    var body: some View {
        if store.preferences.fileTransferEnabled {
            Button { model.sendFileToClient() } label: {
                Label("Send a file", systemImage: "arrow.up.doc")
            }
            .buttonStyle(NeutralButtonStyle())
        }
    }
}
