import Foundation

enum ChatGPTImportError: LocalizedError {
    case archiveUnreadable(String)
    case conversationsMissing

    var errorDescription: String? {
        switch self {
        case let .archiveUnreadable(detail): "Could not read the export archive: \(detail)"
        case .conversationsMissing: "No conversations.json inside the export."
        }
    }
}

/// Converts an OpenAI account export into normalized Recall JSONL written to the
/// imports directory. Nothing is sent anywhere — `unzip` reads the archive locally
/// and the parse below is a pure function over `conversations.json`.
struct ChatGPTImporter {
    let destination: URL

    init(destination: URL = Paths.imports) {
        self.destination = destination
    }

    @discardableResult
    func importArchive(at url: URL) throws -> (file: URL, conversations: Int, events: Int) {
        let data: Data
        if url.pathExtension.lowercased() == "zip" {
            data = try Self.extractConversationsJSON(fromZipAt: url)
        } else {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        }
        let events = Self.events(fromConversationsJSON: data)
        guard !events.isEmpty else { throw ChatGPTImportError.conversationsMissing }

        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let out = destination.appendingPathComponent("chatgpt-\(stamp).jsonl")
        try RecallEventCodec.encode(events).write(to: out)
        let conversations = Set(events.map(\.conversationId)).count
        return (out, conversations, events.count)
    }

    static func extractConversationsJSON(fromZipAt url: URL) throws -> Data {
        let listing = try run("/usr/bin/unzip", ["-Z", "-1", url.path])
        guard let entry = String(decoding: listing, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
            .first(where: { $0.hasSuffix("conversations.json") })
        else { throw ChatGPTImportError.conversationsMissing }
        return try run("/usr/bin/unzip", ["-p", url.path, entry])
    }

    /// `conversations.json` is an array of conversations whose messages hang off a
    /// `mapping` graph. Walking the parent/child links restores the real order;
    /// falling back to create_time keeps malformed exports usable.
    static func events(fromConversationsJSON data: Data) -> [RecallEvent] {
        guard let conversations = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            if let single = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return events(inConversation: single)
            }
            return []
        }
        return conversations.flatMap { events(inConversation: $0) }
    }

    static func events(inConversation record: [String: Any]) -> [RecallEvent] {
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
            nodes.append((
                ts.timeIntervalSince1970,
                RecallEvent(
                    source: RecallSource.chatgpt,
                    conversationId: "\(RecallSource.chatgpt):\(conversationID)",
                    title: title.isEmpty ? RecallText.title(from: text) : RecallText.clipped(title, length: 82),
                    ts: ts,
                    role: RecallEvent.Role(lenient: role),
                    text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                    artifactPaths: ArtifactScanner.paths(in: text)
                )
            ))
        }
        return nodes.sorted { $0.order < $1.order }.map(\.event)
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            throw ChatGPTImportError.archiveUnreadable(error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ChatGPTImportError.archiveUnreadable("unzip exited \(process.terminationStatus)")
        }
        return data
    }
}
