import Foundation

struct SearchHit: Hashable, Sendable, Identifiable {
    var id: Int64 { chunk.id }
    let chunk: IndexedChunk
    let score: Double
    let vectorRank: Int?
    let keywordRank: Int?

    var matchKind: String {
        switch (vectorRank, keywordRank) {
        case (.some, .some): "vector + keyword"
        case (.some, .none): "vector"
        case (.none, .some): "keyword"
        default: "—"
        }
    }
}

/// Search results grouped the way they are actually read: by conversation, best
/// fragment first.
struct ConversationHits: Hashable, Sendable, Identifiable {
    let id: String
    let source: String
    let title: String
    let date: Date
    let score: Double
    let hits: [SearchHit]

    var best: SearchHit { hits[0] }
}

struct SearchOptions: Sendable {
    var limit: Int = 25
    var candidates: Int = 200
    var sources: Set<String> = []
    /// Weights for reciprocal-rank fusion. Vector leads; keyword is the safety net
    /// for exact identifiers the embedding blurs away.
    var vectorWeight: Double = 1.0
    var keywordWeight: Double = 0.8

    init(limit: Int = 25, candidates: Int = 200, sources: Set<String> = []) {
        self.limit = limit
        self.candidates = candidates
        self.sources = sources
    }
}

/// Hybrid retrieval. Vector and keyword lists are fused with reciprocal rank fusion
/// (k = 60) rather than by mixing raw scores: cosine similarity and bm25 are not on
/// a comparable scale, and RRF only needs the orderings.
struct SearchEngine: Sendable {
    static let rrfK = 60.0

    let store: IndexStore
    let embedder: any Embedder

    init(store: IndexStore, embedder: any Embedder) {
        self.store = store
        self.embedder = embedder
    }

    func search(_ query: String, options: SearchOptions = SearchOptions()) async -> [ConversationHits] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let keyword = store.keywordSearch(trimmed, limit: options.candidates)
        var vector: [(id: Int64, score: Double)] = []
        if let embedding = try? await embedder.embed([trimmed]).first {
            vector = store.vectorSearch(embedding, limit: options.candidates)
        }
        return group(fuse(vector: vector, keyword: keyword, options: options), options: options)
    }

    /// Keyword-only search. Used when Ollama is unreachable so the app degrades to
    /// full-text search instead of returning nothing.
    func keywordOnlySearch(_ query: String, options: SearchOptions = SearchOptions()) -> [ConversationHits] {
        let keyword = store.keywordSearch(query, limit: options.candidates)
        return group(fuse(vector: [], keyword: keyword, options: options), options: options)
    }

    func fuse(
        vector: [(id: Int64, score: Double)],
        keyword: [(id: Int64, score: Double)],
        options: SearchOptions = SearchOptions()
    ) -> [(id: Int64, score: Double, vectorRank: Int?, keywordRank: Int?)] {
        var scores: [Int64: Double] = [:]
        var vectorRanks: [Int64: Int] = [:]
        var keywordRanks: [Int64: Int] = [:]

        for (index, entry) in vector.enumerated() {
            vectorRanks[entry.id] = index + 1
            scores[entry.id, default: 0] += options.vectorWeight / (Self.rrfK + Double(index + 1))
        }
        for (index, entry) in keyword.enumerated() {
            keywordRanks[entry.id] = index + 1
            scores[entry.id, default: 0] += options.keywordWeight / (Self.rrfK + Double(index + 1))
        }

        return scores
            .map { (id: $0.key, score: $0.value, vectorRank: vectorRanks[$0.key], keywordRank: keywordRanks[$0.key]) }
            .sorted {
                // Ties broken by id so results are stable between identical queries.
                $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score
            }
    }

    private func group(
        _ fused: [(id: Int64, score: Double, vectorRank: Int?, keywordRank: Int?)],
        options: SearchOptions
    ) -> [ConversationHits] {
        guard !fused.isEmpty else { return [] }
        let hydrated = store.chunks(ids: fused.map(\.id))
        var byConversation: [String: [SearchHit]] = [:]
        var order: [String] = []
        var totals: [String: Double] = [:]

        for entry in fused {
            guard let chunk = hydrated[entry.id] else { continue }
            if !options.sources.isEmpty, !options.sources.contains(chunk.source) { continue }
            let hit = SearchHit(
                chunk: chunk,
                score: entry.score,
                vectorRank: entry.vectorRank,
                keywordRank: entry.keywordRank
            )
            if byConversation[chunk.conversationId] == nil { order.append(chunk.conversationId) }
            byConversation[chunk.conversationId, default: []].append(hit)
            // A conversation with several good fragments outranks one lucky fragment,
            // but with diminishing returns so one long thread cannot dominate.
            let rank = byConversation[chunk.conversationId]!.count
            totals[chunk.conversationId, default: 0] += entry.score / Double(rank)
        }

        return order
            .compactMap { id -> ConversationHits? in
                guard let hits = byConversation[id], let first = hits.first else { return nil }
                return ConversationHits(
                    id: id,
                    source: first.chunk.source,
                    title: first.chunk.title,
                    date: hits.map(\.chunk.endsAt).max() ?? first.chunk.endsAt,
                    score: totals[id] ?? first.score,
                    hits: hits
                )
            }
            .sorted { $0.score == $1.score ? $0.date > $1.date : $0.score > $1.score }
            .prefix(options.limit)
            .map { $0 }
    }
}
