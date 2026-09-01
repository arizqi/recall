import Foundation

struct Transcript: Sendable {
    let conversation: ConversationRecord
    let events: [RecallEvent]
    /// True when the source file was gone and the text came from the index instead.
    let reconstructed: Bool

    var text: String {
        events
            .map { "\($0.role.transcriptLabel):\n\($0.text)" }
            .joined(separator: "\n\n")
    }

    var messageCount: Int { events.count }

    /// Paths mentioned anywhere in the conversation, with a live existence check.
    var artifacts: [(path: String, exists: Bool)] {
        var seen = Set<String>()
        var out: [(String, Bool)] = []
        for path in events.flatMap(\.artifactPaths) where seen.insert(path).inserted {
            out.append((path, ArtifactScanner.exists(path)))
        }
        return out
    }
}

/// Rebuilds a full conversation on demand. The source file is authoritative and is
/// re-read (read-only) so the transcript is never a stale copy; if the file is gone,
/// the indexed chunks stand in.
struct TranscriptProvider: Sendable {
    let store: IndexStore
    let sources: [any EventSource]

    init(store: IndexStore, sources: [any EventSource] = Paths.defaultSources()) {
        self.store = store
        self.sources = sources
    }

    func transcript(for conversationId: String) -> Transcript? {
        guard let record = store.conversation(id: conversationId) else { return nil }
        return transcript(for: record)
    }

    func transcript(for record: ConversationRecord) -> Transcript {
        let url = URL(fileURLWithPath: record.filePath)
        if FileManager.default.fileExists(atPath: record.filePath) {
            let source = source(for: record, url: url)
            let events = source.events(in: url).filter { $0.conversationId == record.id }
            if !events.isEmpty {
                return Transcript(conversation: record, events: events, reconstructed: false)
            }
        }
        return Transcript(conversation: record, events: reconstruct(record), reconstructed: true)
    }

    private func source(for record: ConversationRecord, url: URL) -> any EventSource {
        // Matched on id *and* location: a ChatGPT conversation is either a desktop
        // rollout under `~/.codex/sessions` or normalized bus JSONL from an account
        // export, and the two share a source id but not a reader.
        if let match = sources.first(where: { $0.id == record.source && url.path.hasPrefix($0.root.path) }) {
            return match
        }
        // An inbox event can declare any source string it likes; its file is still
        // normalized JSONL, so read it with the bus reader.
        return NormalizedJSONLSource(id: record.source, root: url.deletingLastPathComponent())
    }

    /// Chunks overlap by design; stitching drops the repeated tail so the rebuilt
    /// transcript reads once through.
    private func reconstruct(_ record: ConversationRecord) -> [RecallEvent] {
        let chunks = store.chunks(conversationId: record.id)
        guard !chunks.isEmpty else { return [] }
        var text = ""
        for chunk in chunks {
            if text.isEmpty {
                text = chunk.text
                continue
            }
            text += "\n\n" + Self.withoutOverlap(chunk.text, following: text)
        }
        return [RecallEvent(
            source: record.source,
            conversationId: record.id,
            title: record.title,
            ts: record.startedAt,
            role: .assistant,
            text: text,
            artifactPaths: record.artifactPaths
        )]
    }

    static func withoutOverlap(_ text: String, following previous: String) -> String {
        let window = min(2_000, min(text.count, previous.count))
        guard window > 40 else { return text }
        let tail = String(previous.suffix(window))
        var length = window
        while length > 40 {
            let candidate = String(tail.suffix(length))
            if text.hasPrefix(candidate) {
                return String(text.dropFirst(length))
            }
            length -= 1
        }
        return text
    }
}
