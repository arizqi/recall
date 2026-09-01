import Foundation

/// The ChatGPT macOS desktop app's local session store.
///
/// The shipping desktop app is code-signed `com.openai.codex` and writes nothing
/// useful under `~/Library/Application Support`; its transcripts live in
/// `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`. Each file opens with one or more
/// `session_meta` rows — a forked or delegated thread replays its parent's meta, so
/// only the first one is this session's identity — then interleaves `response_item`
/// rows (the model-facing message list) with `event_msg` rows (the UI event stream).
/// The two streams carry the same turns, so only one of them is read.
///
/// Subagent threads are skipped for the same reason Claude Code's nested
/// `subagents/` transcripts are: their work is already reported in the parent.
///
/// Only `sessions/` is ever opened. `~/.codex/auth.json` holds credentials and sits
/// deliberately outside this source's root.
struct ChatGPTDesktopSource: EventSource {
    let id = RecallSource.chatgpt
    let root: URL
    private let alreadyImported: CachedIDs

    init(root: URL = Paths.chatgptSessions, imports: URL = Paths.imports) {
        self.root = root
        // Read at most once per index run, and only when a rollout actually needs
        // parsing, so an unchanged rescan never pays for it.
        self.alreadyImported = CachedIDs {
            ExportImporter(destination: imports).existingConversationIDs()
                .filter { $0.hasPrefix("\(RecallSource.chatgpt):") }
        }
    }

    /// Desktop sessions run far longer than a chat: this bounds one conversation's
    /// read the way `JSONLReader.defaultByteLimit` bounds a Claude Code session.
    static let byteLimit = 4 * 1_024 * 1_024

    func discover() -> [SourceFile] {
        jsonlFiles(directDescendantsOnly: false)
            .filter { $0.url.lastPathComponent.hasPrefix("rollout-") }
    }

    func events(in file: URL) -> [RecallEvent] {
        var conversationID: String?
        var project: String?
        var sawMeta = false
        var skip = false
        // `response_item` wins when both streams are present; older desktop builds
        // wrote only the UI stream, which is why it is collected too.
        var responseItems: [Turn] = []
        var uiStream: [Turn] = []

        JSONLReader.forEachLine(at: file, byteLimit: Self.byteLimit) { data in
            guard let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = row["type"] as? String,
                  let payload = row["payload"] as? [String: Any]
            else { return true }

            if type == "session_meta" {
                guard !sawMeta else { return true }
                sawMeta = true
                // A subagent thread records `source` as an object rather than the
                // string an interactive session writes.
                if payload["source"] is [String: Any] || payload["thread_source"] as? String == "subagent" {
                    skip = true
                    return false
                }
                let identifier = ((payload["session_id"] ?? payload["id"]) as? String)
                    ?? file.deletingPathExtension().lastPathComponent
                conversationID = "\(id):\(identifier)"
                // The same conversation arriving from an account-export ZIP is
                // already indexed; reading it again would double-index it.
                if alreadyImported.value.contains(conversationID!) {
                    skip = true
                    return false
                }
                if let cwd = payload["cwd"] as? String {
                    let name = URL(fileURLWithPath: cwd).lastPathComponent
                    project = name.isEmpty ? nil : name
                }
                return true
            }

            let ts = Timestamps.date(row["timestamp"] ?? payload["timestamp"]) ?? .distantPast
            switch type {
            case "response_item":
                guard payload["type"] as? String == "message",
                      let turn = Self.turn(role: payload["role"], text: payload["content"], ts: ts)
                else { return true }
                responseItems.append(turn)
            case "event_msg":
                let role: String
                switch payload["type"] as? String {
                case "user_message": role = "user"
                case "agent_message": role = "assistant"
                default: return true
                }
                guard let turn = Self.turn(role: role, text: payload["message"], ts: ts) else { return true }
                uiStream.append(turn)
            default:
                break
            }
            return true
        }

        guard !skip else { return [] }
        let turns = responseItems.isEmpty ? uiStream : responseItems
        let conversation = conversationID ?? "\(id):\(file.deletingPathExtension().lastPathComponent)"

        var title = ""
        var events: [RecallEvent] = []
        for turn in turns {
            if title.isEmpty, turn.role == .user { title = RecallText.title(from: turn.text) }
            events.append(RecallEvent(
                source: id,
                conversationId: conversation,
                title: title,
                ts: turn.ts,
                role: turn.role,
                text: turn.text,
                artifactPaths: ArtifactScanner.paths(in: turn.text)
            ))
        }

        return Normalization.finish(
            events,
            fallbackTitle: project.map { "ChatGPT — \($0)" } ?? "ChatGPT session",
            file: file
        )
    }

    private struct Turn {
        let role: RecallEvent.Role
        let text: String
        let ts: Date
    }

    private static func turn(role: Any?, text: Any?, ts: Date) -> Turn? {
        guard let raw = role as? String, raw == "user" || raw == "assistant",
              let body = RecallText.messageText(text)
        else { return nil }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isMachineTurn(trimmed) else { return nil }
        return Turn(role: RecallEvent.Role(lenient: raw), text: trimmed, ts: ts)
    }

    /// The desktop app prepends machine-generated turns before the real request —
    /// plugin catalogues, skill manifests, environment blocks, file digests — and
    /// records its agent plumbing as user turns. None of it is something a person
    /// said, and indexing it buries the conversation under boilerplate that matches
    /// every query. A turn opening with an XML-style tag is the reliable tell, which
    /// `RecallText.isNoise` already catches; the rest are shapes only this app emits.
    static func isMachineTurn(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if RecallText.isNoise(trimmed) { return true }
        // Plugin and skill catalogue entries arrive as bare markdown links.
        if trimmed.hasPrefix("["), trimmed.contains("/.codex/plugins/") { return true }
        // Tool calls and their results are recorded as ordinary turns here, unlike
        // Claude Code and Cowork which flag them on the row. On this Mac they are
        // four fifths of the message list — dropping them is what keeps the index
        // conversation rather than command output.
        return trimmed.hasPrefix("[external_agent_tool_call")
            || trimmed.hasPrefix("[external_agent_tool_result")
            || trimmed.hasPrefix("# AGENTS.md instructions for")
            || trimmed.hasPrefix("# Files mentioned by the user:")
    }
}

/// A set of ids computed on first use and then held. Lets a source consult state that
/// costs a directory walk without paying for it on a rescan that reads no files.
private final class CachedIDs: @unchecked Sendable {
    private let load: @Sendable () -> Set<String>
    private let lock = NSLock()
    private var cached: Set<String>?

    init(_ load: @escaping @Sendable () -> Set<String>) {
        self.load = load
    }

    var value: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let ids = load()
        cached = ids
        return ids
    }
}
