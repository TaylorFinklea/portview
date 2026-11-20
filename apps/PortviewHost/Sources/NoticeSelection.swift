// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Pure selection/normalization of popover notices. Never drops a message: length and newlines are
/// handled visually (line limit + tooltip), not by filtering.
enum NoticeSelection {
    struct Notice: Equatable, Identifiable {
        /// Index into the source message list: stable while the window slides.
        let id: Int
        let text: String
    }

    static func latest(_ messages: [String], limit: Int = 3) -> [Notice] {
        let all = messages.enumerated().compactMap { index, message -> Notice? in
            let flat = message.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return flat.isEmpty ? nil : Notice(id: index, text: flat)
        }
        return Array(all.suffix(limit))
    }
}
