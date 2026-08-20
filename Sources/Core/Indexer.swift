import Foundation

struct IndexProgress: Sendable {
    var source: String
    var file: String
    var filesDone: Int
    var filesTotal: Int
    var chunksEmbedded: Int
    var skipped: Int
}

struct IndexRunReport: Sendable {
    var filesScanned = 0
    var filesIndexed = 0
    var filesSkipped = 0
    var filesRemoved = 0
    var chunks = 0
    var embedded = 0
    var seconds: Double = 0
    var errors: [String] = []

    var summary: String {
        let rate = seconds > 0 ? Double(embedded) / seconds : 0
        return String(
            format: "%d files scanned · %d indexed · %d unchanged · %d removed · %d chunks (%d embedded) in %.1fs (%.1f chunks/s)",
            filesScanned, filesIndexed, filesSkipped, filesRemoved, chunks, embedded, seconds, rate
        )
    }
}

struct IndexOptions: Sendable {
    /// Re-index everything, ignoring mtime + size state.
    var force = false
    /// Store chunks without embeddings. Keyword search still works, and a later run
    /// fills the vectors in.
    var skipEmbeddings = false
    /// Cap on files per run, for a quick first index.
    var maxFiles: Int?

    init(force: Bool = false, skipEmbeddings: Bool = false, maxFiles: Int? = nil) {
        self.force = force
        self.skipEmbeddings = skipEmbeddings
        self.maxFiles = maxFiles
    }
}

/// Scan → normalize → chunk → embed → store.
///
/// Resumable at file granularity: each file commits in its own transaction and is
/// only recorded in `files` once its chunks are in, so an interrupted run picks up
/// exactly where it stopped.
struct Indexer: Sendable {
    let store: IndexStore
    let embedder: any Embedder
    let chunker: Chunker

    init(store: IndexStore, embedder: any Embedder, chunker: Chunker = Chunker()) {
        self.store = store
        self.embedder = embedder
        self.chunker = chunker
    }

    func run(
        sources: [any EventSource] = Paths.defaultSources(),
        options: IndexOptions = IndexOptions(),
        progress: (@Sendable (IndexProgress) -> Void)? = nil
    ) async -> IndexRunReport {
        let started = Date()
        var report = IndexRunReport()

        if store.meta("embedding_model") == nil {
            try? store.setMeta("embedding_model", embedder.model)
            try? store.setMeta("embedding_dimensions", String(embedder.dimensions))
        }

        for source in sources {
            let discovered = source.discover()
            report.filesScanned += discovered.count

            // Files indexed before but gone from disk now leave the index too.
            let known = store.indexedFilePaths(source: source.id)
            let present = Set(discovered.map(\.url.path))
            for stale in known.subtracting(present) {
                try? store.forget(path: stale)
                report.filesRemoved += 1
            }

            var done = 0
            for file in discovered {
                if Task.isCancelled { report.seconds = Date().timeIntervalSince(started); return report }
                if let cap = options.maxFiles, report.filesIndexed >= cap { break }
                done += 1
                if !options.force, store.isCurrent(file) {
                    report.filesSkipped += 1
                    continue
                }
                progress?(IndexProgress(
                    source: source.id,
                    file: file.url.lastPathComponent,
                    filesDone: done,
                    filesTotal: discovered.count,
                    chunksEmbedded: report.embedded,
                    skipped: report.filesSkipped
                ))
                do {
                    let counts = try await index(file: file, using: source, options: options)
                    report.filesIndexed += 1
                    report.chunks += counts.chunks
                    report.embedded += counts.embedded
                } catch {
                    report.errors.append("\(file.url.lastPathComponent): \(error.localizedDescription)")
                    // An unreachable model is fatal for the run; a bad file is not.
                    if error is EmbedderError {
                        report.seconds = Date().timeIntervalSince(started)
                        return report
                    }
                }
            }
        }

        report.seconds = Date().timeIntervalSince(started)
        return report
    }

    private func index(
        file: SourceFile,
        using source: any EventSource,
        options: IndexOptions
    ) async throws -> (chunks: Int, embedded: Int) {
        let events = source.events(in: file.url)
        guard !events.isEmpty else {
            try store.replaceFile(file, conversations: [], chunks: [])
            return (0, 0)
        }
        let chunks = chunker.chunks(for: events)
        guard !chunks.isEmpty else {
            try store.replaceFile(file, conversations: [], chunks: [])
            return (0, 0)
        }

        var embeddings: [[Float]?] = Array(repeating: nil, count: chunks.count)
        if !options.skipEmbeddings {
            let vectors = try await embedder.embed(chunks.map(\.text))
            guard vectors.count == chunks.count else {
                throw EmbedderError.server("expected \(chunks.count) vectors, got \(vectors.count)")
            }
            embeddings = vectors.map { $0 }
        }

        try store.replaceFile(
            file,
            conversations: Self.conversations(from: events, chunks: chunks, filePath: file.url.path),
            chunks: zip(chunks, embeddings).map { (chunk: $0, embedding: $1) }
        )
        return (chunks.count, options.skipEmbeddings ? 0 : chunks.count)
    }

    static func conversations(from events: [RecallEvent], chunks: [Chunk], filePath: String) -> [ConversationRecord] {
        var byID: [String: (source: String, title: String, start: Date, end: Date, artifacts: [String])] = [:]
        var order: [String] = []
        for event in events {
            if byID[event.conversationId] == nil {
                order.append(event.conversationId)
                byID[event.conversationId] = (event.source, event.title, event.ts, event.ts, event.artifactPaths)
            } else {
                var entry = byID[event.conversationId]!
                entry.start = min(entry.start, event.ts)
                entry.end = max(entry.end, event.ts)
                if entry.title.isEmpty { entry.title = event.title }
                for path in event.artifactPaths where !entry.artifacts.contains(path) {
                    entry.artifacts.append(path)
                }
                byID[event.conversationId] = entry
            }
        }
        var chunkCounts: [String: Int] = [:]
        for chunk in chunks { chunkCounts[chunk.conversationId, default: 0] += 1 }

        return order.compactMap { id in
            guard let entry = byID[id] else { return nil }
            return ConversationRecord(
                id: id,
                source: entry.source,
                title: entry.title.isEmpty ? "Untitled conversation" : entry.title,
                startedAt: entry.start,
                endedAt: entry.end,
                filePath: filePath,
                chunkCount: chunkCounts[id] ?? 0,
                // Cap the stored artifact list: a long session can mention hundreds of
                // paths, and the export only shows the ones that still exist anyway.
                artifactPaths: Array(entry.artifacts.prefix(200))
            )
        }
    }
}
