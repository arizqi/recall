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
    /// Anthropic account export: `chat_messages`, plus `design_chats/`, `projects/`
    /// and `memories/`. Includes Cowork and web chats.
    case claudeAI

    var source: String {
        switch self {
        case .chatgpt: RecallSource.chatgpt
        case .claudeAI: RecallSource.claudeAI
        }
    }
}

/// The parts of a claude.ai export, as the breakdown line names them. claude.ai's
/// 2026-08 export splits these across one zip per category
/// (`conversations-000.zip`, `projects-000.zip`, …); older exports packed all of
/// them into a single `data-…-batch-0000.zip`. Both shapes land here.
enum ExportPart {
    static let conversations = "conversations"
    static let designChats = "design chats"
    static let projectDocs = "project docs"
    static let memories = "memories"
    /// `users.json` + `login_history.json`. Recognized so an import of it is a
    /// deliberate skip rather than an "unrecognized format" error, never indexed.
    static let accountMetadata = "light_metadata"

    /// Directories that are themselves a category, so unpacking one category zip
    /// must not be mistaken for "the export is nested one level down".
    static let directories = ["conversations", "design_chats", "projects", "memories"]
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
        /// nil when the export was recognized but carried nothing to index — an
        /// account-metadata-only archive. No JSONL is written in that case.
        let file: URL?
        let kind: ExportKind
        let conversations: Int
        let events: Int
        /// Conversations present in the export with no message text at all.
        let skippedEmpty: Int
        /// Conversations already imported from an earlier batch.
        let duplicates: Int
        /// Which parts of the archive contributed, for the success message.
        let breakdown: [String: Int]
        /// Categories that were recognized and deliberately not indexed.
        let skippedCategories: [String]
        /// How many files (zips / json) were read into this one import.
        let inputs: Int

        init(
            file: URL?,
            kind: ExportKind,
            conversations: Int,
            events: Int,
            skippedEmpty: Int = 0,
            duplicates: Int = 0,
            breakdown: [String: Int] = [:],
            skippedCategories: [String] = [],
            inputs: Int = 1
        ) {
            self.file = file
            self.kind = kind
            self.conversations = conversations
            self.events = events
            self.skippedEmpty = skippedEmpty
            self.duplicates = duplicates
            self.breakdown = breakdown
            self.skippedCategories = skippedCategories
            self.inputs = inputs
        }

        /// True for an archive we understood but had nothing to add from.
        var isMetadataOnly: Bool { conversations == 0 && !skippedCategories.isEmpty }

        var headline: String {
            if isMetadataOnly { return "Account files only — nothing to index" }
            return "\(conversations.formatted()) conversation\(conversations == 1 ? "" : "s") imported"
        }

        var detail: String {
            if isMetadataOnly {
                return "\(skippedCategories.joined(separator: ", ")) carries account settings "
                    + "(users, login history). Recall deliberately does not index it."
            }
            var lines = breakdown
                .filter { $0.value > 0 }
                .sorted { $0.key < $1.key }
                .map { "\($0.value) from \($0.key)" }
            lines.append("\(events.formatted()) messages")
            if inputs > 1 { lines.append("\(inputs) files read") }
            if duplicates > 0 { lines.append("\(duplicates) already imported (skipped)") }
            if skippedEmpty > 0 { lines.append("\(skippedEmpty) with no message text (skipped)") }
            return lines.joined(separator: " · ")
        }
    }

    @discardableResult
    func importArchive(at url: URL) throws -> Result {
        try importArchives(at: [url])
    }

    /// Imports one or many export files as a single logical import.
    ///
    /// claude.ai now hands out one zip per category, and a large account splits each
    /// category across `-000`, `-001`, … parts. Selecting several zips, or the folder
    /// holding them, has to behave like importing one export: parts of a category are
    /// merged and a conversation that appears in two parts is kept once, newest
    /// `updated_at` winning.
    @discardableResult
    func importArchives(at urls: [URL]) throws -> Result {
        let inputs = Self.expand(urls)
        guard !inputs.isEmpty else {
            throw ExportImportError.nothingToImport("No export .zip or .json to read.")
        }

        var parts: [Parsed] = []
        var firstFailure: Error?
        for input in inputs {
            do {
                parts.append(try parse(input))
            } catch {
                firstFailure = firstFailure ?? error
            }
        }
        let parsed = Parsed.merged(parts)

        guard let kind = parsed.kind else {
            // A light_metadata zip is a real part of the export; importing it is a
            // no-op, not a failure the user has to dismiss.
            if !parsed.skippedCategories.isEmpty {
                return Result(
                    file: nil,
                    kind: .claudeAI,
                    conversations: 0,
                    events: 0,
                    skippedCategories: parsed.skippedCategories,
                    inputs: inputs.count
                )
            }
            if let firstFailure { throw firstFailure }
            throw ExportImportError.unrecognizedFormat
        }

        // Importing a later batch must not duplicate what an earlier one brought in.
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
            breakdown: breakdown,
            skippedCategories: parsed.skippedCategories,
            inputs: inputs.count
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

    // MARK: - Inputs

    /// Flattens what the user handed over into the list of files to read.
    ///
    /// A directory is either an already-unpacked export (read in place) or a folder
    /// of downloaded category zips (each read separately). Sorting by name puts
    /// `-000` before `-001`, which is the order the merge wants.
    static func expand(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            guard isDirectory.boolValue else {
                if isReadableInput(url) { out.append(url) }
                continue
            }
            if isUnpackedExport(url) {
                out.append(url)
                continue
            }
            let children = (try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            out += children.filter { isReadableInput($0) }
        }
        return out.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// A manifest is a pointer to downloads, not data — reading it as an export
    /// would find nothing, so it is never treated as one here.
    private static func isReadableInput(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard ext == "zip" || ext == "json" else { return false }
        if ext == "json", ExportManifest.parse(contentsOf: url) != nil { return false }
        return true
    }

    static func isUnpackedExport(_ directory: URL) -> Bool {
        let manager = FileManager.default
        if manager.fileExists(atPath: directory.appendingPathComponent("conversations.json").path) { return true }
        if manager.fileExists(atPath: directory.appendingPathComponent("projects.json").path) { return true }
        for name in ExportPart.directories {
            var isDirectory: ObjCBool = false
            if manager.fileExists(atPath: directory.appendingPathComponent(name).path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return true
            }
        }
        return false
    }

    private func parse(_ url: URL) throws -> Parsed {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if isDirectory.boolValue { return Self.parseDirectory(url) }
        if url.pathExtension.lowercased() == "zip" { return try readArchive(at: url) }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return Self.parseConversationsJSON(data)
    }

    // MARK: - Archive

    struct Parsed {
        var kind: ExportKind?
        var events: [RecallEvent] = []
        var skippedEmpty = 0
        var breakdown: [String: Int] = [:]
        /// Recognized-but-not-indexed categories, e.g. `light_metadata`.
        var skippedCategories: [String] = []
        /// Which part of the export each conversation came from, for the breakdown.
        var partOf: [String: String] = [:]
        /// The export's own `updated_at` per conversation. Decides the winner when
        /// the same conversation shows up in two parts of a split export.
        var updatedAt: [String: Date] = [:]

        /// Records one conversation's worth of events. Every parser below emits all
        /// of a conversation's events together, so the first one names the group.
        mutating func add(_ events: [RecallEvent], part: String, updatedAt stamp: Date?) {
            guard let first = events.first else { return }
            self.events += events
            partOf[first.conversationId] = part
            updatedAt[first.conversationId] = stamp ?? events.map(\.ts).max() ?? .distantPast
            kind = kind ?? .claudeAI
        }

        mutating func recomputeBreakdown() {
            var counts: [String: Int] = [:]
            for part in partOf.values { counts[part, default: 0] += 1 }
            breakdown = counts
        }

        /// Merges the parts of a split export. A conversation seen twice is kept
        /// once — the copy whose `updated_at` is newest.
        static func merged(_ parts: [Parsed]) -> Parsed {
            guard parts.count != 1 else { return parts[0] }
            var out = Parsed()
            var order: [String] = []
            var groups: [String: [RecallEvent]] = [:]

            for part in parts {
                out.kind = out.kind ?? part.kind
                out.skippedEmpty += part.skippedEmpty
                for category in part.skippedCategories where !out.skippedCategories.contains(category) {
                    out.skippedCategories.append(category)
                }

                var incoming: [String: [RecallEvent]] = [:]
                var incomingOrder: [String] = []
                for event in part.events {
                    if incoming[event.conversationId] == nil { incomingOrder.append(event.conversationId) }
                    incoming[event.conversationId, default: []].append(event)
                }
                for id in incomingOrder {
                    let stamp = part.updatedAt[id] ?? incoming[id]?.map(\.ts).max() ?? .distantPast
                    if let existing = out.updatedAt[id] {
                        // Equal stamps: the part read first wins, so the result does
                        // not depend on directory-listing order.
                        guard stamp > existing else { continue }
                    } else {
                        order.append(id)
                    }
                    groups[id] = incoming[id]
                    out.updatedAt[id] = stamp
                    out.partOf[id] = part.partOf[id]
                }
            }

            out.events = order.flatMap { groups[$0] ?? [] }
            out.recomputeBreakdown()
            return out
        }
    }

    /// Unpacks the whole archive rather than streaming one member, because a claude.ai
    /// export keeps most of its content outside conversations.json.
    func readArchive(at url: URL) throws -> Parsed {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("recall-import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        _ = try Self.run("/usr/bin/unzip", ["-q", "-o", url.path, "-d", staging.path])
        return Self.parseDirectory(staging)
    }

    /// Walks an unpacked export, whether it holds every category (the old single zip)
    /// or exactly one (a `<category>-000.zip`). Detection is by content: any of
    /// `conversations.json`, `projects.json`, `design_chats/`, `projects/`,
    /// `memories/` makes this a claude.ai export regardless of the file's name.
    /// `users.json` / `login_history.json` are recognized and deliberately skipped.
    static func parseDirectory(_ root: URL) -> Parsed {
        var parsed = Parsed()
        let manager = FileManager.default

        // Some exports nest everything one level down inside the zip. A single
        // directory that is itself a category (`projects/`) is not that case.
        var base = root
        if let entries = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]),
           entries.count == 1,
           (try? entries[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
           !ExportPart.directories.contains(entries[0].lastPathComponent),
           !manager.fileExists(atPath: root.appendingPathComponent("conversations.json").path) {
            base = entries[0]
        }

        let conversations = base.appendingPathComponent("conversations.json")
        if let data = try? Data(contentsOf: conversations, options: .mappedIfSafe) {
            let inner = parseConversationsJSON(data)
            parsed.kind = parsed.kind ?? inner.kind
            parsed.events += inner.events
            parsed.skippedEmpty += inner.skippedEmpty
            for (id, stamp) in inner.updatedAt { parsed.updatedAt[id] = stamp }
            for (id, part) in inner.partOf { parsed.partOf[id] = part }
        }
        // A split export can put conversations under `conversations/<uuid>.json`.
        for file in jsonFiles(in: base.appendingPathComponent("conversations")) {
            guard let record = object(at: file) else { continue }
            let events = claudeAIEvents(in: record)
            if events.isEmpty { parsed.skippedEmpty += 1; continue }
            parsed.add(events, part: ExportPart.conversations, updatedAt: Timestamps.date(record["updated_at"]))
        }

        for file in jsonFiles(in: base.appendingPathComponent("design_chats")) {
            guard let record = object(at: file) else { continue }
            let events = designChatEvents(in: record, fallbackID: file.deletingPathExtension().lastPathComponent)
            if events.isEmpty { parsed.skippedEmpty += 1; continue }
            parsed.add(events, part: ExportPart.designChats, updatedAt: Timestamps.date(record["updated_at"]))
        }

        for file in jsonFiles(in: base.appendingPathComponent("projects")) {
            guard let record = object(at: file) else { continue }
            let events = projectEvents(in: record, fallbackID: file.deletingPathExtension().lastPathComponent)
            guard !events.isEmpty else { continue }
            parsed.add(events, part: ExportPart.projectDocs, updatedAt: Timestamps.date(record["updated_at"]))
        }
        // Legacy layout: every project in one array.
        if let data = try? Data(contentsOf: base.appendingPathComponent("projects.json"), options: .mappedIfSafe),
           let records = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for (offset, record) in records.enumerated() {
                let events = projectEvents(in: record, fallbackID: "projects-\(offset)")
                guard !events.isEmpty else { continue }
                parsed.add(events, part: ExportPart.projectDocs, updatedAt: Timestamps.date(record["updated_at"]))
            }
        }

        for file in jsonFiles(in: base.appendingPathComponent("memories")) {
            guard let record = object(at: file) else { continue }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let events = memoryEvents(
                in: record,
                fallbackID: file.deletingPathExtension().lastPathComponent,
                fallbackDate: modified ?? Date()
            )
            guard !events.isEmpty else { continue }
            parsed.add(events, part: ExportPart.memories, updatedAt: events.map(\.ts).max())
        }

        if manager.fileExists(atPath: base.appendingPathComponent("users.json").path)
            || manager.fileExists(atPath: base.appendingPathComponent("login_history.json").path) {
            parsed.skippedCategories.append(ExportPart.accountMetadata)
        }

        parsed.recomputeBreakdown()
        return parsed
    }

    private static func object(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
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
            if events.isEmpty {
                parsed.skippedEmpty += 1
                continue
            }
            parsed.add(
                events,
                part: ExportPart.conversations,
                updatedAt: Timestamps.date(record["updated_at"] ?? record["update_time"])
            )
        }
        parsed.recomputeBreakdown()
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
        // The project's custom instructions are as searchable as its docs.
        if let template = record["prompt_template"] as? String, !RecallText.isNoise(template) {
            events.append(event(
                source: RecallSource.claudeAI,
                conversationID: "project:\(projectID)",
                title: title,
                role: "system",
                text: "Project instructions:\n\(template)",
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

    // MARK: - claude.ai memories

    /// `memories/<account-uuid>.json` — new in the 2026-08 export. Two things live
    /// here: `conversations_memory`, a written summary of what Claude has learned
    /// about the account, and `memory_files`, a small wiki of markdown notes. Both
    /// are indexed as one conversation, one message each, exactly like project docs,
    /// because "what does Claude remember about X" is the same question as "which
    /// doc said X".
    static func memoryEvents(in record: [String: Any], fallbackID: String, fallbackDate: Date) -> [RecallEvent] {
        let accountID = (record["account_uuid"] as? String) ?? fallbackID
        let files = (record["memory_files"] as? [[String: Any]]) ?? []
        let newest = files.compactMap { Timestamps.date($0["updated_at"]) }.max() ?? fallbackDate
        let title = "Memory — claude.ai"

        var events: [RecallEvent] = []
        if let narrative = record["conversations_memory"] as? String, !RecallText.isNoise(narrative) {
            events.append(event(
                source: RecallSource.claudeAI,
                conversationID: "memory:\(accountID)",
                title: title,
                role: "system",
                text: "Conversations memory:\n\(narrative)",
                ts: newest,
                artifacts: []
            ))
        }
        for file in files {
            guard let content = file["content"] as? String, !RecallText.isNoise(content) else { continue }
            let path = (file["path"] as? String) ?? "memory"
            events.append(event(
                source: RecallSource.claudeAI,
                conversationID: "memory:\(accountID)",
                title: title,
                role: "system",
                text: "\(path):\n\(content)",
                ts: Timestamps.date(file["updated_at"]) ?? newest,
                artifacts: [path]
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
