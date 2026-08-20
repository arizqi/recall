import Foundation

enum ExportImportError: LocalizedError {
    case archiveUnreadable(String)
    case conversationsMissing
    case unrecognizedFormat

    var errorDescription: String? {
        switch self {
        case let .archiveUnreadable(detail): "Could not read the export archive: \(detail)"
        case .conversationsMissing: "No conversations.json inside the export."
        case .unrecognizedFormat: "conversations.json is neither a ChatGPT nor a claude.ai export."
        }
    }
}

enum ExportKind: String, Sendable {
    /// OpenAI export: messages hang off a `mapping` graph.
    case chatgpt
    /// Anthropic account export: `chat_messages` in order. Includes Cowork and web chats.
    case claudeAI

    var source: String {
        switch self {
        case .chatgpt: RecallSource.chatgpt
        case .claudeAI: RecallSource.claudeAI
        }
    }
}

/// Turns an account export into normalized Recall JSONL under the imports directory,
/// where the ordinary bus reader picks it up. Nothing is uploaded: `unzip` reads the
/// archive locally and the parsers below are pure functions over `conversations.json`.
///
/// One importer for both vendors because the user-facing action is the same — "I
/// downloaded my data, index it" — and the file inside the zip has the same name.
struct ExportImporter {
    let destination: URL

    init(destination: URL = Paths.imports) {
        self.destination = destination
    }

    struct Result: Sendable {
        let file: URL
        let kind: ExportKind
        let conversations: Int
        let events: Int
    }

    @discardableResult
    func importArchive(at url: URL) throws -> Result {
        let data: Data
        if url.pathExtension.lowercased() == "zip" {
            data = try Self.extractConversationsJSON(fromZipAt: url)
        } else {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        }
        let parsed = Self.events(fromConversationsJSON: data)
        guard let kind = parsed.kind, !parsed.events.isEmpty else {
            throw ExportImportError.unrecognizedFormat
        }

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let out = destination.appendingPathComponent("\(kind.rawValue)-\(stamp).jsonl")
        try RecallEventCodec.encode(parsed.events).write(to: out)
        return Result(
            file: out,
            kind: kind,
            conversations: Set(parsed.events.map(\.conversationId)).count,
            events: parsed.events.count
        )
    }

    static func extractConversationsJSON(fromZipAt url: URL) throws -> Data {
        let listing = try run("/usr/bin/unzip", ["-Z", "-1", url.path])
        guard let entry = String(decoding: listing, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
            .first(where: { $0.hasSuffix("conversations.json") })
        else { throw ExportImportError.conversationsMissing }
        return try run("/usr/bin/unzip", ["-p", url.path, entry])
    }

    /// Detects the vendor from the shape of the first conversation rather than from
    /// the filename, because both vendors ship the same filename.
    static func events(fromConversationsJSON data: Data) -> (kind: ExportKind?, events: [RecallEvent]) {
        let records: [[String: Any]]
        if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            records = array
        } else if let single = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            records = [single]
        } else {
            return (nil, [])
        }
        guard let kind = kind(of: records) else { return (nil, []) }
        let events = records.flatMap { record in
            kind == .chatgpt ? chatGPTEvents(in: record) : claudeAIEvents(in: record)
        }
        return (kind, events)
    }

    static func kind(of records: [[String: Any]]) -> ExportKind? {
        for record in records {
            if record["mapping"] is [String: Any] { return .chatgpt }
            if record["chat_messages"] is [[String: Any]] { return .claudeAI }
        }
        return nil
    }

    // MARK: - ChatGPT

    /// `mapping` is a message graph; sorting by create_time restores reading order
    /// and keeps malformed exports usable.
    static func chatGPTEvents(in record: [String: Any]) -> [RecallEvent] {
        let conversationID = (record["conversation_id"] as? String)
            ?? (record["id"] as? String)
            ?? UUID().uuidString
        let title = RecallText.normalized((record["title"] as? String) ?? "")
        let created = Timestamps.date(record["create_time"]) ?? .distantPast
        guard let mapping = record["mapping"] as? [String: Any] else { return [] }

        var nodes: [(order: Double, event: RecallEvent)] = []
        for (_, raw) in mapping {
            guard let node = raw as? [String: Any],
                  let message = node["message"] as? [String: Any],
                  let author = message["author"] as? [String: Any],
                  let role = author["role"] as? String,
                  role != "system",
                  let text = RecallText.messageText(message["content"]),
                  !RecallText.isNoise(text)
            else { continue }
            let ts = Timestamps.date(message["create_time"]) ?? created
            nodes.append((ts.timeIntervalSince1970, event(
                source: RecallSource.chatgpt,
                conversationID: conversationID,
                title: title,
                role: role,
                text: text,
                ts: ts
            )))
        }
        return nodes.sorted { $0.order < $1.order }.map(\.event)
    }

    // MARK: - claude.ai

    /// Anthropic's export already stores messages in order. `text` is the flattened
    /// body; `content` blocks carry the same text split by type, so the flat field is
    /// preferred and the blocks are the fallback.
    static func claudeAIEvents(in record: [String: Any]) -> [RecallEvent] {
        let conversationID = (record["uuid"] as? String) ?? (record["id"] as? String) ?? UUID().uuidString
        let title = RecallText.normalized((record["name"] as? String) ?? (record["title"] as? String) ?? "")
        let created = Timestamps.date(record["created_at"]) ?? .distantPast
        guard let messages = record["chat_messages"] as? [[String: Any]] else { return [] }

        var events: [RecallEvent] = []
        for message in messages {
            let flat = message["text"] as? String
            let body = (flat?.isEmpty == false ? flat : nil) ?? RecallText.messageText(message["content"])
            guard let body, !RecallText.isNoise(body) else { continue }
            let ts = Timestamps.date(message["created_at"]) ?? created
            var attachments = ArtifactScanner.paths(in: body)
            for file in (message["files"] as? [[String: Any]]) ?? [] {
                if let name = file["file_name"] as? String { attachments.append(name) }
            }
            events.append(event(
                source: RecallSource.claudeAI,
                conversationID: conversationID,
                title: title,
                role: (message["sender"] as? String) ?? "assistant",
                text: body,
                ts: ts,
                artifacts: attachments
            ))
        }
        return events
    }

    private static func event(
        source: String,
        conversationID: String,
        title: String,
        role: String,
        text: String,
        ts: Date,
        artifacts: [String]? = nil
    ) -> RecallEvent {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return RecallEvent(
            source: source,
            conversationId: "\(source):\(conversationID)",
            title: title.isEmpty ? RecallText.title(from: trimmed) : RecallText.clipped(title, length: 82),
            ts: ts,
            role: RecallEvent.Role(lenient: role),
            text: trimmed,
            artifactPaths: artifacts ?? ArtifactScanner.paths(in: trimmed)
        )
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            throw ExportImportError.archiveUnreadable(error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ExportImportError.archiveUnreadable("unzip exited \(process.terminationStatus)")
        }
        return data
    }
}
