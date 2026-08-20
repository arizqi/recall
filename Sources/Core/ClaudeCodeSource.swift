import Foundation

/// Claude Code CLI transcripts: `~/.claude/projects/<project>/<session>.jsonl`.
/// Nested `subagents/` transcripts are skipped — their work is already reported in
/// the parent session, and indexing both doubles the corpus for no recall.
struct ClaudeCodeSource: EventSource {
    let id = RecallSource.claudeCode
    let root: URL

    init(root: URL = Paths.claudeCodeProjects) {
        self.root = root
    }

    func discover() -> [SourceFile] {
        jsonlFiles(directDescendantsOnly: true)
    }

    func events(in file: URL) -> [RecallEvent] {
        var events: [RecallEvent] = []
        var sessionID = file.deletingPathExtension().lastPathComponent
        var project: String?
        var title = ""

        JSONLReader.forEachLine(at: file) { data in
            guard let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return true }
            if let candidate = row["sessionId"] as? String, !candidate.isEmpty { sessionID = candidate }
            if project == nil, let cwd = row["cwd"] as? String {
                project = URL(fileURLWithPath: cwd).lastPathComponent
            }
            guard let type = row["type"] as? String,
                  type == "user" || type == "assistant",
                  (row["isSidechain"] as? Bool) != true,
                  row["toolUseResult"] == nil,
                  let message = row["message"] as? [String: Any],
                  let text = RecallText.messageText(message["content"]),
                  !RecallText.isNoise(text)
            else { return true }

            if title.isEmpty, type == "user" { title = RecallText.title(from: text) }
            events.append(RecallEvent(
                source: id,
                conversationId: "\(id):\(sessionID)",
                title: title,
                ts: Timestamps.date(row["timestamp"]) ?? .distantPast,
                role: RecallEvent.Role(lenient: type),
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                artifactPaths: ArtifactScanner.paths(in: text)
            ))
            return true
        }

        return Normalization.finish(events, fallbackTitle: project.map { "Claude Code — \($0)" } ?? "Claude Code session", file: file)
    }
}

enum Normalization {
    /// Backfills the title onto events emitted before the first user turn was seen,
    /// fills missing timestamps from neighbours, and drops empties.
    static func finish(_ events: [RecallEvent], fallbackTitle: String, file: URL) -> [RecallEvent] {
        guard !events.isEmpty else { return [] }
        var titlesByConversation: [String: String] = [:]
        for event in events where !event.title.isEmpty {
            if titlesByConversation[event.conversationId] == nil {
                titlesByConversation[event.conversationId] = event.title
            }
        }
        let fileDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast

        var lastTimestamp: [String: Date] = [:]
        return events.compactMap { event in
            var event = event
            if event.title.isEmpty {
                event.title = titlesByConversation[event.conversationId] ?? fallbackTitle
            }
            if event.ts == .distantPast {
                event.ts = lastTimestamp[event.conversationId] ?? fileDate
            }
            lastTimestamp[event.conversationId] = event.ts
            return event.text.isEmpty ? nil : event
        }
    }
}
