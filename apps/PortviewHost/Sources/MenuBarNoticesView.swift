// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// Compact inline notices for the popover: the latest few single-line runtime messages (port
/// unavailable, pairing-store repair result, revoke failures, ...) plus the accessibility warning,
/// with a dismiss control. Replaces the retired activity log as the only surface for
/// `model.messages`. Inline only — no alert/sheet/dialog.
struct MenuBarNoticesView: View {
    let model: HostAppModel
    private static let maxShown = 3

    private var recent: [String] {
        let lines = model.messages.filter {
            !$0.contains("\n") && $0.count < DeviceStatusCopy.activityLogCharacterLimit
        }
        return Array(lines.suffix(Self.maxShown))
    }

    var body: some View {
        let warning = model.accessibilityWarning
        let lines = recent
        if warning != nil || !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Notices").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Glass.text1)
                    Spacer()
                    Button("Dismiss") { model.clearNotices() }
                        .buttonStyle(.plain).font(.mono(10)).foregroundStyle(Glass.text3)
                }
                if let warning {
                    Text(warning).font(.mono(10)).foregroundStyle(Glass.degraded)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.mono(10)).foregroundStyle(Glass.text2)
                        .lineLimit(2).truncationMode(.tail)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: Glass.well, style: .continuous))
        }
    }
}
