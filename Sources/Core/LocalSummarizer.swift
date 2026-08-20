import Foundation

struct ConversationSummary: Codable, Hashable, Sendable {
    var overview: String
    var keyPoints: [String]
    var decisions: [String]
    var artifacts: [String]
    var nextSteps: [String]
    var model: String
    var generatedAt: Date

    var markdown: String {
        var sections = ["## Summary\n\n\(overview)"]
        append("Key points", keyPoints, to: &sections)
        append("Decisions", decisions, to: &sections)
        append("Artifacts mentioned", artifacts, to: &sections)
        append("Next steps", nextSteps, to: &sections)
        return sections.joined(separator: "\n\n")
    }

    private func append(_ title: String, _ items: [String], to sections: inout [String]) {
        guard !items.isEmpty else { return }
        sections.append("### \(title)\n" + items.map { "- \($0)" }.joined(separator: "\n"))
    }
}

/// Summaries run on the same local Ollama as the embeddings — `gemma4:e4b` by
/// default. Long transcripts are summarized in chunks and then synthesized, which
/// keeps the prompt inside the model's window without dropping the middle.
struct LocalSummarizer: Sendable {
    static let defaultModel = "gemma4:e4b"

    let model: String
    let baseURL: URL
    /// ~14k characters per chunk keeps prompt + output inside a small model's window.
    let chunkCharacters = 14_000
    let maximumChunks = 6

    init(model: String = LocalSummarizer.defaultModel, baseURL: URL = URL(string: "http://127.0.0.1:11434")!) {
        self.model = model
        self.baseURL = baseURL
    }

    func summarize(title: String, transcript: String) async throws -> ConversationSummary {
        let chunks = split(transcript)
        let content: String
        if chunks.count == 1 {
            content = chunks[0]
        } else {
            var briefs: [String] = []
            for (index, chunk) in chunks.enumerated() {
                briefs.append("Part \(index + 1):\n" + (try await brief(title: title, chunk: chunk)))
            }
            content = briefs.joined(separator: "\n\n")
        }
        return try await structured(title: title, content: content)
    }

    private func brief(title: String, chunk: String) async throws -> String {
        try await generate(
            system: "You summarize part of a work conversation. Six sentences at most. "
                + "Keep concrete names, file paths, decisions, and numbers. No preamble.",
            user: "Conversation: \(title)\n\n\(chunk)",
            format: nil
        )
    }

    private func structured(title: String, content: String) async throws -> ConversationSummary {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "overview": ["type": "string"],
                "keyPoints": ["type": "array", "items": ["type": "string"]],
                "decisions": ["type": "array", "items": ["type": "string"]],
                "artifacts": ["type": "array", "items": ["type": "string"]],
                "nextSteps": ["type": "array", "items": ["type": "string"]],
            ],
            "required": ["overview", "keyPoints", "decisions", "artifacts", "nextSteps"],
        ]
        let raw = try await generate(
            system: "You write handoff summaries of work conversations. Be specific and "
                + "concrete: real file paths, real decisions, real next steps. Never invent detail.",
            user: "Conversation: \(title)\n\n\(content)",
            format: schema
        )
        guard let data = extractJSON(from: raw),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return ConversationSummary(
                overview: RecallText.clipped(raw, length: 1_200),
                keyPoints: [], decisions: [], artifacts: [], nextSteps: [],
                model: model, generatedAt: Date()
            )
        }
        return ConversationSummary(
            overview: (object["overview"] as? String) ?? "",
            keyPoints: strings(object["keyPoints"]),
            decisions: strings(object["decisions"]),
            artifacts: strings(object["artifacts"]),
            nextSteps: strings(object["nextSteps"]),
            model: model,
            generatedAt: Date()
        )
    }

    private func generate(system: String, user: String, format: [String: Any]?) async throws -> String {
        var payload: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
            "options": ["temperature": 0.2, "num_predict": 1_200],
        ]
        if let format { payload["format"] = format }

        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 900
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw EmbedderError.unavailable
        }
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let detail = String(decoding: data, as: UTF8.self)
            if detail.contains("not found") { throw EmbedderError.modelMissing(model) }
            throw EmbedderError.server(RecallText.clipped(detail, length: 200))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["message"] as? [String: Any],
              let content = message["content"] as? String
        else { throw EmbedderError.server("unexpected /api/chat response") }
        return content
    }

    /// Small models fill required arrays with "None mentioned." rather than leaving
    /// them empty; that is a non-answer, and the section reads better absent.
    private static let emptyPhrases: Set<String> = [
        "none", "none.", "none mentioned", "none mentioned.", "n/a", "not applicable",
        "no decisions", "no next steps", "no artifacts",
    ]

    private func strings(_ value: Any?) -> [String] {
        ((value as? [Any]) ?? [])
            .compactMap { $0 as? String }
            .filter { item in
                let normalized = RecallText.normalized(item).lowercased()
                return !normalized.isEmpty && !Self.emptyPhrases.contains(normalized)
            }
    }

    /// Small models sometimes wrap JSON in prose or a code fence even under `format`.
    private func extractJSON(from raw: String) -> Data? {
        if let data = raw.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil { return data }
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end
        else { return nil }
        return String(raw[start...end]).data(using: .utf8)
    }

    private func split(_ transcript: String) -> [String] {
        guard transcript.count > chunkCharacters else { return [transcript] }
        var chunks: [String] = []
        var start = transcript.startIndex
        while start < transcript.endIndex {
            let limit = transcript.index(start, offsetBy: chunkCharacters, limitedBy: transcript.endIndex)
                ?? transcript.endIndex
            var end = limit
            if limit < transcript.endIndex, let boundary = transcript[start..<limit].lastIndex(of: "\n") {
                end = transcript.index(after: boundary)
            }
            chunks.append(String(transcript[start..<end]))
            start = end
        }
        guard chunks.count > maximumChunks else { return chunks }
        // Keep the head, the tail, and an even spread between: the shape of a work
        // conversation lives at its ends.
        let last = chunks.count - 1
        let picks = Set((0..<maximumChunks).map { last * $0 / (maximumChunks - 1) })
        return picks.sorted().map { chunks[$0] }
    }
}
