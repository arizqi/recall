import Foundation

enum EmbedderError: LocalizedError {
    case unavailable
    case modelMissing(String)
    case server(String)
    case dimensionMismatch(expected: Int, got: Int)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Ollama is not running on 127.0.0.1:11434. Start it with `ollama serve`."
        case let .modelMissing(model):
            "Ollama does not have `\(model)`. Run `ollama pull \(model)`."
        case let .server(detail):
            "Ollama returned an error: \(detail)"
        case let .dimensionMismatch(expected, got):
            "Embedding dimension changed (index holds \(expected), model returned \(got)). Reindex to switch models."
        }
    }
}

enum Vector {
    /// Unit-length so that a dot product is the cosine similarity.
    static func normalized(_ vector: [Float]) -> [Float] {
        var sum: Float = 0
        for value in vector { sum += value * value }
        guard sum > 0 else { return vector }
        let inverse = 1 / sum.squareRoot()
        return vector.map { $0 * inverse }
    }
}

protocol Embedder: Sendable {
    var model: String { get }
    var dimensions: Int { get }
    /// Returns one unit-length vector per input, in order.
    func embed(_ texts: [String]) async throws -> [[Float]]
}

/// Local embeddings via Ollama. No API key, no network beyond loopback, $0.
struct OllamaEmbedder: Embedder {
    static let defaultModel = "nomic-embed-text"

    let model: String
    let dimensions: Int
    let baseURL: URL
    /// Ollama parallelizes within one /api/embed call; 32 keeps the request under a
    /// few hundred KB while still saturating the GPU.
    let batchSize: Int

    init(
        model: String = OllamaEmbedder.defaultModel,
        dimensions: Int = 768,
        baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
        batchSize: Int = 32
    ) {
        self.model = model
        self.dimensions = dimensions
        self.baseURL = baseURL
        self.batchSize = batchSize
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        var out: [[Float]] = []
        out.reserveCapacity(texts.count)
        for start in stride(from: 0, to: texts.count, by: batchSize) {
            let slice = Array(texts[start..<min(start + batchSize, texts.count)])
            out.append(contentsOf: try await embedBatch(slice))
        }
        return out
    }

    private func embedBatch(_ texts: [String]) async throws -> [[Float]] {
        let body = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "input": texts,
        ])
        var request = URLRequest(url: baseURL.appendingPathComponent("api/embed"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw EmbedderError.unavailable
        }
        guard let http = response as? HTTPURLResponse else { throw EmbedderError.unavailable }
        guard 200..<300 ~= http.statusCode else {
            let detail = String(decoding: data, as: UTF8.self)
            if detail.contains("not found") { throw EmbedderError.modelMissing(model) }
            throw EmbedderError.server(RecallText.clipped(detail, length: 200))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["embeddings"] as? [[Double]]
        else { throw EmbedderError.server("unexpected /api/embed response") }
        return raw.map { Vector.normalized($0.map(Float.init)) }
    }

    func isReachable() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 3
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse
        else { return false }
        return 200..<300 ~= http.statusCode
    }

    func installedModels() async -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 5
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]]
        else { return [] }
        return models.compactMap { ($0["name"] ?? $0["model"]) as? String }
    }

    /// Starts `ollama serve` if the binary is installed but the server is down.
    static func startIfInstalled() {
        let paths = ["/usr/local/bin/ollama", "/opt/homebrew/bin/ollama"]
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["serve"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}

/// Deterministic hashing embedder. Tests use it to exercise the whole index and
/// ranking path without a model; it is never used by the app.
struct HashingEmbedder: Embedder {
    let model = "hashing-test"
    let dimensions: Int

    init(dimensions: Int = 64) {
        self.dimensions = dimensions
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { vector(for: $0) }
    }

    func vector(for text: String) -> [Float] {
        var values = [Float](repeating: 0, count: dimensions)
        for token in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            var hash: UInt64 = 5_381
            for byte in token.utf8 { hash = hash &* 33 &+ UInt64(byte) }
            values[Int(hash % UInt64(dimensions))] += 1
        }
        return Vector.normalized(values)
    }
}
