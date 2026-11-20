// SPDX-License-Identifier: Apache-2.0
import SwiftUI

/// Compact inline notices for the popover: the latest few runtime messages (port unavailable,
/// pairing-store repair result, revoke failures, ...) plus the accessibility warning, with a
/// dismiss control. Messages are never dropped; newlines are flattened and long text is truncated
/// visually. Replaces the retired activity log as the only surface for
/// `model.messages`. Inline only — no alert/sheet/dialog.
struct MenuBarNoticesView: View {
    let model: HostAppModel
    private var recent: [NoticeSelection.Notice] { NoticeSelection.latest(model.messages) }

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
                ForEach(lines) { notice in
                    Text(notice.text).font(.mono(10)).foregroundStyle(Glass.text2)
                        .lineLimit(2).truncationMode(.tail)
                        .help(notice.text)
                        .textSelection(.enabled)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: Glass.well, style: .continuous))
        }
    }
}
