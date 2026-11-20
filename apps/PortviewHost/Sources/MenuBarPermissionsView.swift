// SPDX-License-Identifier: Apache-2.0
import SwiftUI
import PortviewHostCore

/// Inline permissions onboarding for the menu-bar popover (replaces the main window's permissions
/// card + guided banner). Inline rows only — no sheet/alert/dialog, which die with the popover.
struct MenuBarPermissionsView: View {
    let model: HostAppModel

    var body: some View {
        let onboarding = model.onboarding
        if !onboarding.allGranted {
            VStack(alignment: .leading, spacing: 8) {
                Text(onboarding.title)
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Glass.text1)
                Text(onboarding.body)
                    .font(.mono(10)).foregroundStyle(Glass.text2)
                    .fixedSize(horizontal: false, vertical: true)
                row("Screen Recording", granted: model.screenRecordingGranted,
                    open: model.openScreenRecordingSettings)
                row("Accessibility", granted: model.accessibilityGranted,
                    open: model.openAccessibilitySettings)
                HStack {
                    Button("Re-check") { model.refreshPermissions() }
                        .buttonStyle(NeutralButtonStyle())
                    Spacer()
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: Glass.well, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Glass.well, style: .continuous)
                .strokeBorder(Glass.degraded.opacity(0.3), lineWidth: 1))
        }
    }

    private func row(_ title: String, granted: Bool, open: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            StatusDot(kind: granted ? .signal : .amber, size: 6)
            Text(title).font(.system(size: 12)).foregroundStyle(Glass.text1)
            Spacer()
            if granted {
                Text("GRANTED").font(.mono(9, .semibold)).foregroundStyle(Glass.signal)
            } else {
                Button("Open Settings", action: open)
                    .buttonStyle(OutlineButtonStyle(tint: Glass.degraded))
            }
        }
    }
}
