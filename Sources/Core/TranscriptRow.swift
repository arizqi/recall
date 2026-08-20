import Foundation

/// One displayable slice of a conversation.
///
/// The view must never be handed a whole conversation as a single string: SwiftUI
/// typesets `Text` eagerly through CoreText, so one attributed string holding a
/// megabyte of transcript pins the main thread inside
/// `CTLineCreateWithAttributedString` for minutes. Rows exist so every message is
/// its own small `Text`, and so no single row can be large enough to stall layout
/// either — an oversized message is split rather than truncated, so nothing on
/// screen is ever a lie about what the conversation contains.
struct TranscriptRow: Identifiable, Hashable, Sendable {
    let id: Int
    let role: RecallEvent.Role
    let ts: Date
    /// What renders while the row is collapsed. Never longer than `collapsedLimit`.
    let preview: String
    /// The row's full text, itself capped at `segmentLimit` by construction. Cheap
    /// to hold: Swift strings are copy-on-write and this text is already resident.
    let text: String
    let characters: Int
    /// Set when this row is one piece of a message that was too large for one row.
    let continuation: Bool

    static let collapsedLimit = 4_000
    /// The most text one `Text` is ever asked to typeset. Twenty thousand characters
    /// lays out in milliseconds; a megabyte does not lay out at all.
    static let segmentLimit = 20_000

    var isTruncated: Bool { characters > TranscriptRow.collapsedLimit }

    func displayText(expanded: Bool) -> String {
        isTruncated && !expanded ? preview : text
    }

    var truncationLabel: String { "Show more (\(characters.formatted()) characters)" }
}

enum TranscriptRows {
    /// Cost is O(messages × collapsedLimit) plus the split of oversized messages, not
    /// O(transcript rendered), so a multi-megabyte conversation opens as fast as a
    /// small one.
    static func rows(for transcript: Transcript) -> [TranscriptRow] {
        var rows: [TranscriptRow] = []
        for event in transcript.events {
            for (offset, segment) in segments(of: event.text).enumerated() {
                let characters = segment.count
                rows.append(TranscriptRow(
                    id: rows.count,
                    role: event.role,
                    ts: event.ts,
                    preview: characters > TranscriptRow.collapsedLimit
                        ? String(segment.prefix(TranscriptRow.collapsedLimit)) + "…"
                        : segment,
                    text: segment,
                    characters: characters,
                    continuation: offset > 0
                ))
            }
        }
        return rows
    }

    /// Splits on line boundaries so code blocks and command output stay readable.
    static func segments(of text: String) -> [String] {
        guard text.count > TranscriptRow.segmentLimit else { return [text] }
        var segments: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let limit = text.index(start, offsetBy: TranscriptRow.segmentLimit, limitedBy: text.endIndex)
                ?? text.endIndex
            var end = limit
            if limit < text.endIndex,
               let boundary = text[start..<limit].lastIndex(of: "\n"),
               text.distance(from: start, to: boundary) > TranscriptRow.segmentLimit / 2 {
                end = text.index(after: boundary)
            }
            segments.append(String(text[start..<end]))
            start = end
        }
        return segments
    }
}
