import Foundation

/// The one shape every source is normalized into. This is also the wire format
/// for the drop-in inbox: any tool that can write JSONL can feed Recall.
/// One JSON object per line, `\n` separated, UTF-8.
struct RecallEvent: Hashable, Sendable, Codable {
    var source: String
    var conversationId: String
    var title: String
    var ts: Date
    var role: Role
    var text: String
    var artifactPaths: [String]

    enum Role: String, Hashable, Sendable, Codable {
        case user
        case assistant
        case system
        case tool

        /// Unknown roles are kept rather than dropped: a bus event with a role we
        /// have never seen is still searchable text.
        init(lenient raw: String) {
            switch raw.lowercased() {
            case "user", "human", "you": self = .user
            case "assistant", "model", "ai", "turn", "agent": self = .assistant
            case "tool", "tool_use", "tool_result", "function": self = .tool
            default: self = .system
            }
        }

        var transcriptLabel: String { rawValue.uppercased() }
    }

    init(
        source: String,
        conversationId: String,
        title: String,
        ts: Date,
        role: Role,
        text: String,
        artifactPaths: [String] = []
    ) {
        self.source = source
        self.conversationId = conversationId
        self.title = title
        self.ts = ts
        self.role = role
        self.text = text
        self.artifactPaths = artifactPaths
    }
}

/// Stable source identifiers. Free-form strings are allowed from the inbox, so this
/// is a namespace of well-known values rather than a closed enum in the event.
enum RecallSource {
    static let claudeCode = "claude-code"
    static let cowork = "cowork"
    static let room = "room"
    static let inbox = "inbox"
    static let chatgpt = "chatgpt"

    static let known = [claudeCode, cowork, room, inbox, chatgpt]

    static func label(_ raw: String) -> String {
        switch raw {
        case claudeCode: "Claude Code"
        case cowork: "Cowork"
        case room: "Room"
        case inbox: "Inbox"
        case chatgpt: "ChatGPT"
        default: raw.capitalized
        }
    }
}

/// JSONL codec for the bus format. Dates are ISO-8601 strings; epoch seconds and
/// epoch milliseconds are also accepted on the way in because half the tools that
/// will write to the inbox emit numbers.
enum RecallEventCodec {
    static func encode(_ events: [RecallEvent]) -> Data {
        var out = Data()
        for event in events {
            guard let line = try? line(for: event) else { continue }
            out.append(line)
            out.append(0x0A)
        }
        return out
    }

    static func line(for event: RecallEvent) throws -> Data {
        let object: [String: Any] = [
            "source": event.source,
            "conversationId": event.conversationId,
            "title": event.title,
            "ts": Timestamps.iso8601(event.ts),
            "role": event.role.rawValue,
            "text": event.text,
            "artifactPaths": event.artifactPaths,
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Returns nil for lines that are not Recall events, so a mixed-content JSONL
    /// file degrades to "the events we understood" instead of failing outright.
    static func decode(line data: Data) -> RecallEvent? {
        guard let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return decode(row: row)
    }

    static func decode(row: [String: Any]) -> RecallEvent? {
        guard let source = row["source"] as? String,
              let conversationId = row["conversationId"] as? String,
              let text = row["text"] as? String
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return RecallEvent(
            source: source,
            conversationId: conversationId,
            title: (row["title"] as? String) ?? "",
            ts: Timestamps.date(row["ts"]) ?? .distantPast,
            role: RecallEvent.Role(lenient: (row["role"] as? String) ?? "assistant"),
            text: trimmed,
            artifactPaths: (row["artifactPaths"] as? [String]) ?? []
        )
    }
}
