// SPDX-License-Identifier: Apache-2.0
import PortviewProtocol

enum ClipboardSendPolicy {
    static func outboundMessage(text: String, hostLocked: Bool) -> AnyMessage? {
        guard !hostLocked, !text.isEmpty, Frame.shouldSendClipboard(text) else { return nil }
        return .clipboardUpdate(ClipboardUpdate(text: text))
    }
}
