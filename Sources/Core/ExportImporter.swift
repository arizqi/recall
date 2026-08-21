import Foundation

enum ExportImportError: LocalizedError {
    case archiveUnreadable(String)
    case conversationsMissing
    case unrecognizedFormat
    case nothingToImport(String)

    var errorDescription: String? {
        switch self {
        case let .archiveUnreadable(detail): "Could not read the export archive: \(detail)"
        case .conversationsMissing: "No conversations.json or design_chats/ inside the export."
        case .unrecognizedFormat: "conversations.json is neither a ChatGPT nor a claude.ai export."
        case let .nothingToImport(detail): detail
        }
    }
}

enum ExportKind: String, Sendable {
    /// OpenAI export: messages hang off a `mapping` graph.
    case chatgpt
    /// Anthropic account export: `chat_messages`, plus `design_chats/` and
    /// `projects/` when the export is batched. Includes Cowork and web chats.
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
/// archive locally and every parser below is a pure function over JSON.
///
/// One importer for both vendors because the user-facing action is the same — "I
/// downloaded my data, index it".
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
        /// Conversations present in the export with no message text at all.
        let skippedEmpty: Int
        /// Conversations already imported from an earlier batch.
        let duplicates: Int
        /// Which parts of the archive contributed, for the success message.
        let breakdown: [String: Int]

        var headline: String {
            "\(conversations.formatted()) conversation\(conversations == 1 ? "" : "s") imported"
        }

        var detail: String {
            var lines = breakdown
                .filter { $0.value > 0 }
                .sorted { $0.key < $1.key }
                .map { "\($0.value) from \($0.key)" }
            lines.append("\(events.formatted()) messages")
            if duplicates > 0 { lines.append("\(duplicates) already imported (skipped)") }
            if skippedEmpty > 0 { lines.append("\(skippedEmpty) with no message text (skipped)") }
            return lines.joined(separator: " · ")
        }
    }

    @discardableResult
    func importArchive(at url: URL) throws -> Result {
        let parsed: Parsed
        if url.pathExtension.lowercased() == "zip" {
            parsed = try readArchive(at: url)
        } else {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            parsed = Self.parseConversationsJSON(data)
        }
        guard let kind = parsed.kind else { throw ExportImportError.unrecognizedFormat }

        // Batched exports arrive as `…batch-0000.zip`, `…batch-0001.zip`. Importing
        // the next batch must not duplicate what the last one already brought in.
        let known = existingConversationIDs()
        var seen = Set<String>()
        var duplicates = 0
        var events: [RecallEvent] = []
        for event in parsed.events {
            if known.contains(event.conversationId) {
                if seen.insert(event.conversationId).inserted { duplicates += 1 }
                continue
            }
            events.append(event)
        }

        let conversations = Set(events.map(\.conversationId)).count
        guard conversations > 0 else {
            // Never leave an empty file behind pretending something happened.
            throw ExportImportError.nothingToImport(nothingToImportMessage(parsed, duplicates: duplicates))
        }

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        // Second-resolution stamps collide when two batches are imported back to
        // back, and the second import would overwrite the first.
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        var out = destination.appendingPathComponent("\(kind.rawValue)-\(stamp).jsonl")
        var attempt = 2
        while FileManager.default.fileExists(atPath: out.path) {
            out = destination.appendingPathComponent("\(kind.rawValue)-\(stamp)-\(attempt).jsonl")
            attempt += 1
        }
        try RecallEventCodec.encode(events).write(to: out)

        var breakdown = parsed.breakdown
        for key in breakdown.keys where breakdown[key] == 0 { breakdown.removeValue(forKey: key) }
        return Result(
            file: out,
            kind: kind,
            conversations: conversations,
            events: events.count,
            skippedEmpty: parsed.skippedEmpty,
            duplicates: duplicates,
            breakdown: breakdown
        )
    }

    private func nothingToImportMessage(_ parsed: Parsed, duplicates: Int) -> String {
        if duplicates > 0 {
            return "Every conversation in this export was already imported "
                + "(\(duplicates) skipped). Nothing new to add."
        }
        if parsed.skippedEmpty > 0 {
            return "This export contains \(parsed.skippedEmpty) conversation(s), but none of them "
                + "carry any message text — the export has titles and timestamps only."
        }
        return "No conversations with message text were found in this export."
    }

    /// Conversation ids already on disk from earlier imports.
    func existingConversationIDs() -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: destination,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        var ids = Set<String>()
        for file in files where file.pathExtension.lowercased() == "jsonl" {
            JSONLReader.forEachLine(at: file) { data in
                if let event = RecallEventCodec.decode(line: data) { ids.insert(event.conversationId) }
                return true
            }
        }
        return ids
    }

    // MARK: - Archive

    struct Parsed {
        var kind: ExportKind?
        var events: [RecallEvent] = []
        var skippedEmpty = 0
        var breakdown: [String: Int] = [:]
    }

    /// Unpacks the whole archive rather than streaming one member, because a batched
    /// claude.ai export keeps most of its content outside conversations.json.
    func readArchive(at url: URL) throws -> Parsed {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("recall-import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        _ = try Self.run("/usr/bin/unzip", ["-q", "-o", url.path, "-d", staging.path])
        return Self.parseDirectory(staging)
    }

    /// Walks an unpacked export. Unknown members are ignored; `memories.json`,
    /// `users.json` and `login_history.json` are deliberately not indexed.
    static func parseDirectory(_ root: URL) -> Parsed {
        var parsed = Parsed()
        let manager = FileManager.default

        // Some exports nest everything one level down inside the zip.
        var base = root
        if let entries = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]),
           entries.count == 1,
           (try? entries[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
           !manager.fileExists(atPath: root.appendingPathComponent("conversations.json").path) {
            base = entries[0]
        }

        let conversations = base.appendingPathComponent("conversations.json")
        if let data = try? Data(contentsOf: conversations, options: .mappedIfSafe) {
            let inner = parseConversationsJSON(data)
            parsed.kind = inner.kind
            parsed.events += inner.events
            parsed.skippedEmpty += inner.skippedEmpty
            parsed.breakdown["conversations"] = Set(inner.events.map(\.conversationId)).count
        }

        let designChats = jsonFiles(in: base.appendingPathComponent("design_chats"))
        var designCount = 0
        for file in designChats {
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let events = designChatEvents(in: record, fallbackID: file.deletingPathExtension().lastPathComponent)
            if events.isEmpty {
                parsed.skippedEmpty += 1
            } else {
                designCount += 1
                parsed.events += events
                parsed.kind = parsed.kind ?? .claudeAI
            }
        }
        parsed.breakdown["design chats"] = designCount

        let projects = jsonFiles(in: base.appendingPathComponent("projects"))
        var projectCount = 0
        for file in projects {
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let events = projectEvents(in: record, fallbackID: file.deletingPathExtension().lastPathComponent)
            guard !events.isEmpty else { continue }
            projectCount += 1
            parsed.events += events
            parsed.kind = parsed.kind ?? .claudeAI
        }
        parsed.breakdown["project docs"] = projectCount

        return parsed
    }

    private static func jsonFiles(in directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? [])
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - conversations.json

    static func parseConversationsJSON(_ data: Data) -> Parsed {
        let records: [[String: Any]]
        if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            records = array
        } else if let single = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            records = [single]
        } else {
            return Parsed()
        }
        guard let kind = kind(of: records) else { return Parsed() }

        var parsed = Parsed(kind: kind)
        for record in records {
            let events = kind == .chatgpt ? chatGPTEvents(in: record) : claudeAIEvents(in: record)
            // A conversation whose messages are all empty is not a parse failure: the
            // export simply carries no body for it. Counted so the user is told.
            if events.isEmpty { parsed.skippedEmpty += 1 } else { parsed.events += events }
        }
        return parsed
    }

    /// Back-compatible entry point for callers that only want the events.
    static func events(fromConversationsJSON data: Data) -> (kind: ExportKind?, events: [RecallEvent]) {
        let parsed = parseConversationsJSON(data)
        return (parsed.kind, parsed.events)
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

    // MARK: - claude.ai conversations

    /// Anthropic's export stores messages in order. `text` is the flattened body;
    /// `content` blocks carry the same text split by type, so the flat field wins and
    /// the blocks are the fallback.
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

    // MARK: - claude.ai design chats

    /// `design_chats/<uuid>.json`. Every one of these is titled "Chat", so the
    /// project name carries the identity instead. The body is nested one level
    /// deeper than in conversations.json — `content.content`, plus attachment
    /// bodies, which is where the opening brief usually lives.
    static func designChatEvents(in record: [String: Any], fallbackID: String) -> [RecallEvent] {
        let conversationID = (record["uuid"] as? String) ?? fallbackID
        let project = ((record["project"] as? [String: Any])?["name"] as? String) ?? ""
        let rawTitle = RecallText.normalized((record["title"] as? String) ?? "")
        let created = Timestamps.date(record["created_at"]) ?? .distantPast
        guard let messages = record["messages"] as? [[String: Any]] else { return [] }

        var title = project.isEmpty ? "" : "Design — \(project)"
        if title.isEmpty, !rawTitle.isEmpty, rawTitle.lowercased() != "chat" { title = rawTitle }

        var events: [RecallEvent] = []
        for message in messages {
            let inner = message["content"] as? [String: Any]
            var pieces: [String] = []
            if let body = inner?["content"] as? String, !body.isEmpty { pieces.append(body) }
            for attachment in (inner?["attachments"] as? [[String: Any]]) ?? [] {
                if let body = attachment["content"] as? String, !body.isEmpty {
                    let name = (attachment["name"] as? String).map { "\($0):\n" } ?? ""
                    pieces.append(name + body)
                }
            }
            if pieces.isEmpty, let flat = RecallText.messageText(message["content"]) { pieces.append(flat) }
            let body = pieces.joined(separator: "\n\n")
            guard !RecallText.isNoise(body) else { continue }

            let ts = Timestamps.date(message["created_at"] ?? inner?["timestamp"]) ?? created
            events.append(event(
                source: RecallSource.claudeAI,
                conversationID: "design:\(conversationID)",
                title: title,
                role: (message["role"] as? String) ?? (inner?["role"] as? String) ?? "assistant",
                text: body,
                ts: ts
            ))
        }
        return events
    }

    // MARK: - claude.ai project docs

    /// A project's attached documents. One conversation per project, one message per
    /// document, because that is how they are searched for: "the doc in that project".
    static func projectEvents(in record: [String: Any], fallbackID: String) -> [RecallEvent] {
        let projectID = (record["uuid"] as? String) ?? fallbackID
        let name = RecallText.normalized((record["name"] as? String) ?? "")
        let created = Timestamps.date(record["created_at"]) ?? .distantPast
        let title = name.isEmpty ? "Project documents" : "Project — \(name)"

        var events: [RecallEvent] = []
        if let description = record["description"] as? String, !RecallText.isNoise(description) {
            events.append(event(
                source: RecallSource.claudeAI,
                conversationID: "project:\(projectID)",
                title: title,
                role: "system",
                text: "Project description:\n\(description)",
                ts: created
            ))
        }
        for doc in (record["docs"] as? [[String: Any]]) ?? [] {
            guard let content = doc["content"] as? String, !RecallText.isNoise(content) else { continue }
            let filename = (doc["filename"] as? String) ?? "document"
            events.append(event(
                source: RecallSource.claudeAI,
                conversationID: "project:\(projectID)",
                title: title,
                role: "system",
                text: "\(filename):\n\(content)",
                ts: Timestamps.date(doc["created_at"]) ?? created,
                artifacts: [filename]
            ))
        }
        return events
    }

    // MARK: - Helpers

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

    static func extractConversationsJSON(fromZipAt url: URL) throws -> Data {
        let listing = try run("/usr/bin/unzip", ["-Z", "-1", url.path])
        guard let entry = String(decoding: listing, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
            .first(where: { $0.hasSuffix("conversations.json") })
        else { throw ExportImportError.conversationsMissing }
        return try run("/usr/bin/unzip", ["-p", url.path, entry])
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        let errors = Pipe()
        process.standardOutput = pipe
        process.standardError = errors
        do { try process.run() } catch {
            throw ExportImportError.archiveUnreadable(error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let problem = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // unzip exits 1 for warnings it recovered from; only a real failure matters.
        guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
            let detail = String(decoding: problem, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ExportImportError.archiveUnreadable(
                detail.isEmpty ? "unzip exited \(process.terminationStatus)" : RecallText.clipped(detail, length: 200)
            )
        }
        return data
    }
}
