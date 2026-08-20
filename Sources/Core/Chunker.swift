import Foundation

struct Chunk: Hashable, Sendable {
    let conversationId: String
    let source: String
    let title: String
    let ordinal: Int
    let startsAt: Date
    let endsAt: Date
    let text: String
    let artifactPaths: [String]
}

/// Turns a conversation's events into embeddable chunks.
///
/// Sized in characters rather than tokens on purpose: a tokenizer would be another
/// dependency and another thing to keep in sync with the embedding model. 4 chars
/// per token is the standard English approximation, so the default 4,000 characters
/// is ~1k tokens — comfortably inside nomic-embed-text's 2k context window even when
/// the text is code-heavy and tokenizes worse than prose.
struct Chunker: Sendable {
    var targetCharacters: Int = 4_000
    var overlapCharacters: Int = 400
    /// Never split a message smaller than this out of its neighbours.
    var minimumCharacters: Int = 200

    init(targetCharacters: Int = 4_000, overlapCharacters: Int = 400) {
        self.targetCharacters = targetCharacters
        self.overlapCharacters = min(overlapCharacters, max(0, targetCharacters - 1))
    }

    func chunks(for events: [RecallEvent]) -> [Chunk] {
        guard !events.isEmpty else { return [] }
        var byConversation: [String: [RecallEvent]] = [:]
        var order: [String] = []
        for event in events {
            if byConversation[event.conversationId] == nil { order.append(event.conversationId) }
            byConversation[event.conversationId, default: []].append(event)
        }
        return order.flatMap { chunksForOne(byConversation[$0] ?? []) }
    }

    private func chunksForOne(_ events: [RecallEvent]) -> [Chunk] {
        guard let first = events.first else { return [] }
        let title = events.first(where: { !$0.title.isEmpty })?.title ?? first.title
        var chunks: [Chunk] = []

        var buffer = ""
        var bufferStart = first.ts
        var bufferEnd = first.ts
        var artifacts: [String] = []
        var ordinal = 0

        func flush() {
            let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { buffer = ""; artifacts = []; return }
            chunks.append(Chunk(
                conversationId: first.conversationId,
                source: first.source,
                title: title,
                ordinal: ordinal,
                startsAt: bufferStart,
                endsAt: bufferEnd,
                text: trimmed,
                artifactPaths: uniqued(artifacts)
            ))
            ordinal += 1
            buffer = tail(of: trimmed)
            artifacts = []
        }

        for event in events {
            // Role headers stay in the chunk text: they cost few tokens and they are
            // what makes a retrieved fragment readable on its own.
            let piece = "\(event.role.transcriptLabel): \(event.text)\n\n"
            for segment in split(piece) {
                if buffer.isEmpty { bufferStart = event.ts }
                if buffer.count + segment.count > targetCharacters, buffer.count >= minimumCharacters {
                    flush()
                    if buffer.isEmpty { bufferStart = event.ts }
                }
                buffer += segment
                bufferEnd = event.ts
                artifacts.append(contentsOf: event.artifactPaths)
            }
        }
        // The final flush leaves an overlap tail behind; drop it, it is already indexed.
        let pending = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pending.isEmpty, !chunks.contains(where: { $0.text == pending }) {
            buffer = pending
            flush()
        }
        return chunks
    }

    /// A single message can be larger than a whole chunk; break it on line
    /// boundaries so code blocks survive mostly intact.
    private func split(_ text: String) -> [String] {
        guard text.count > targetCharacters else { return [text] }
        var pieces: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let limit = text.index(start, offsetBy: targetCharacters, limitedBy: text.endIndex) ?? text.endIndex
            var end = limit
            if limit < text.endIndex,
               let boundary = text[start..<limit].lastIndex(of: "\n"),
               text.distance(from: start, to: boundary) > targetCharacters / 2 {
                end = text.index(after: boundary)
            }
            pieces.append(String(text[start..<end]))
            start = end
        }
        return pieces
    }

    private func tail(of text: String) -> String {
        guard overlapCharacters > 0, text.count > overlapCharacters else { return "" }
        let start = text.index(text.endIndex, offsetBy: -overlapCharacters)
        let slice = text[start...]
        if let boundary = slice.firstIndex(of: "\n") {
            return String(slice[text.index(after: boundary)...])
        }
        return String(slice)
    }

    private func uniqued(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
