import Accelerate
import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum IndexError: LocalizedError {
    case open(String)
    case sql(String)

    var errorDescription: String? {
        switch self {
        case let .open(detail): "Could not open the index: \(detail)"
        case let .sql(detail): "Index error: \(detail)"
        }
    }
}

struct IndexedChunk: Hashable, Sendable {
    let id: Int64
    let conversationId: String
    let source: String
    let title: String
    let ordinal: Int
    let startsAt: Date
    let endsAt: Date
    let text: String
    let artifactPaths: [String]
    let filePath: String
}

struct ConversationRecord: Hashable, Sendable, Identifiable {
    let id: String
    let source: String
    let title: String
    let startedAt: Date
    let endedAt: Date
    let filePath: String
    let chunkCount: Int
    let artifactPaths: [String]
}

struct SourceStatus: Hashable, Sendable, Identifiable {
    var id: String { source }
    let source: String
    let files: Int
    let conversations: Int
    let chunks: Int
    let lastIndexed: Date?
}

struct IndexStats: Sendable {
    let conversations: Int
    let chunks: Int
    let embedded: Int
    let bytes: Int64
    let model: String
    let dimensions: Int
    let sources: [SourceStatus]
}

/// SQLite-backed store: chunk text in FTS5 for keyword recall, unit-length float32
/// embeddings in a BLOB column for vector recall.
///
/// No sqlite-vec. See README — a brute-force scan with Accelerate is ~2 GB/s per
/// core, which puts a full pass over this machine's corpus well inside a keystroke's
/// budget, and it removes a native extension from the build, the code-signing story,
/// and the failure modes.
final class IndexStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.ashar.recall.index")
    private var cache: VectorCache?
    let url: URL

    /// Vectors are cached in RAM for repeat queries; past this many chunks Recall
    /// streams from SQLite instead of holding ~3 KB per chunk resident.
    private let cacheLimit = 200_000

    init(url: URL = Paths.indexDatabase) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            throw IndexError.open(handle.map { String(cString: sqlite3_errmsg($0)) } ?? url.path)
        }
        db = handle
        try migrate()
    }

    deinit { if let db { sqlite3_close_v2(db) } }

    // MARK: - Schema

    private func migrate() throws {
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA synchronous=NORMAL;")
        try exec("PRAGMA mmap_size=268435456;")
        try exec("""
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);

        CREATE TABLE IF NOT EXISTS files(
            path TEXT PRIMARY KEY,
            source TEXT NOT NULL,
            mtime REAL NOT NULL,
            size INTEGER NOT NULL,
            indexed_at REAL NOT NULL,
            chunk_count INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS conversations(
            id TEXT PRIMARY KEY,
            source TEXT NOT NULL,
            title TEXT NOT NULL,
            started_at REAL NOT NULL,
            ended_at REAL NOT NULL,
            file_path TEXT NOT NULL,
            chunk_count INTEGER NOT NULL,
            artifact_paths TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS chunks(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            conversation_id TEXT NOT NULL,
            source TEXT NOT NULL,
            title TEXT NOT NULL,
            ordinal INTEGER NOT NULL,
            starts_at REAL NOT NULL,
            ends_at REAL NOT NULL,
            text TEXT NOT NULL,
            artifact_paths TEXT NOT NULL,
            file_path TEXT NOT NULL,
            embedding BLOB,
            dim INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS chunks_conversation ON chunks(conversation_id, ordinal);
        CREATE INDEX IF NOT EXISTS chunks_file ON chunks(file_path);

        CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
            text,
            tokenize='porter unicode61'
        );
        """)
    }

    // MARK: - Metadata

    func meta(_ key: String) -> String? {
        queue.sync {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = ?;", -1, &statement, nil) == SQLITE_OK
            else { return nil }
            bind(statement, 1, key)
            guard sqlite3_step(statement) == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) else { return nil }
            return String(cString: raw)
        }
    }

    func setMeta(_ key: String, _ value: String) throws {
        try queue.sync {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(
                db, "INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value;",
                -1, &statement, nil
            ) == SQLITE_OK else { throw IndexError.sql(lastError) }
            bind(statement, 1, key)
            bind(statement, 2, value)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw IndexError.sql(lastError) }
        }
    }

    // MARK: - Incremental state

    /// Returns true when the file on disk matches what was indexed (mtime + size).
    func isCurrent(_ file: SourceFile) -> Bool {
        queue.sync {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, "SELECT mtime, size FROM files WHERE path = ?;", -1, &statement, nil) == SQLITE_OK
            else { return false }
            bind(statement, 1, file.url.path)
            guard sqlite3_step(statement) == SQLITE_ROW else { return false }
            let mtime = sqlite3_column_double(statement, 0)
            let size = sqlite3_column_int64(statement, 1)
            return abs(mtime - file.modified.timeIntervalSince1970) < 0.001 && size == file.size
        }
    }

    func indexedFilePaths(source: String) -> Set<String> {
        queue.sync {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            var paths = Set<String>()
            guard sqlite3_prepare_v2(db, "SELECT path FROM files WHERE source = ?;", -1, &statement, nil) == SQLITE_OK
            else { return paths }
            bind(statement, 1, source)
            while sqlite3_step(statement) == SQLITE_ROW {
                if let raw = sqlite3_column_text(statement, 0) { paths.insert(String(cString: raw)) }
            }
            return paths
        }
    }

    /// Replaces everything derived from one file, transactionally. A crash mid-index
    /// leaves the previous version of that file's chunks in place, never a half file.
    func replaceFile(
        _ file: SourceFile,
        conversations: [ConversationRecord],
        chunks: [(chunk: Chunk, embedding: [Float]?)]
    ) throws {
        try queue.sync {
            try execUnsynchronized("BEGIN IMMEDIATE;")
            do {
                try deleteFileRows(path: file.url.path)

                for record in conversations {
                    var statement: OpaquePointer?
                    defer { sqlite3_finalize(statement) }
                    guard sqlite3_prepare_v2(db, """
                    INSERT INTO conversations(id, source, title, started_at, ended_at, file_path, chunk_count, artifact_paths)
                    VALUES(?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        title = excluded.title,
                        started_at = min(conversations.started_at, excluded.started_at),
                        ended_at = max(conversations.ended_at, excluded.ended_at),
                        file_path = excluded.file_path,
                        chunk_count = excluded.chunk_count,
                        artifact_paths = excluded.artifact_paths;
                    """, -1, &statement, nil) == SQLITE_OK else { throw IndexError.sql(lastError) }
                    bind(statement, 1, record.id)
                    bind(statement, 2, record.source)
                    bind(statement, 3, record.title)
                    sqlite3_bind_double(statement, 4, record.startedAt.timeIntervalSince1970)
                    sqlite3_bind_double(statement, 5, record.endedAt.timeIntervalSince1970)
                    bind(statement, 6, record.filePath)
                    sqlite3_bind_int64(statement, 7, Int64(record.chunkCount))
                    bind(statement, 8, record.artifactPaths.joined(separator: "\n"))
                    guard sqlite3_step(statement) == SQLITE_DONE else { throw IndexError.sql(lastError) }
                }

                var insert: OpaquePointer?
                var insertFTS: OpaquePointer?
                defer { sqlite3_finalize(insert); sqlite3_finalize(insertFTS) }
                guard sqlite3_prepare_v2(db, """
                INSERT INTO chunks(conversation_id, source, title, ordinal, starts_at, ends_at, text, artifact_paths, file_path, embedding, dim)
                VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """, -1, &insert, nil) == SQLITE_OK,
                      sqlite3_prepare_v2(db, "INSERT INTO chunks_fts(rowid, text) VALUES(?, ?);", -1, &insertFTS, nil) == SQLITE_OK
                else { throw IndexError.sql(lastError) }

                for (chunk, embedding) in chunks {
                    sqlite3_reset(insert)
                    bind(insert, 1, chunk.conversationId)
                    bind(insert, 2, chunk.source)
                    bind(insert, 3, chunk.title)
                    sqlite3_bind_int64(insert, 4, Int64(chunk.ordinal))
                    sqlite3_bind_double(insert, 5, chunk.startsAt.timeIntervalSince1970)
                    sqlite3_bind_double(insert, 6, chunk.endsAt.timeIntervalSince1970)
                    bind(insert, 7, chunk.text)
                    bind(insert, 8, chunk.artifactPaths.joined(separator: "\n"))
                    bind(insert, 9, file.url.path)
                    if let embedding {
                        let data = Self.blob(from: embedding)
                        _ = data.withUnsafeBytes { raw in
                            sqlite3_bind_blob(insert, 10, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
                        }
                        sqlite3_bind_int64(insert, 11, Int64(embedding.count))
                    } else {
                        sqlite3_bind_null(insert, 10)
                        sqlite3_bind_int64(insert, 11, 0)
                    }
                    guard sqlite3_step(insert) == SQLITE_DONE else { throw IndexError.sql(lastError) }

                    let rowid = sqlite3_last_insert_rowid(db)
                    sqlite3_reset(insertFTS)
                    sqlite3_bind_int64(insertFTS, 1, rowid)
                    bind(insertFTS, 2, chunk.text)
                    guard sqlite3_step(insertFTS) == SQLITE_DONE else { throw IndexError.sql(lastError) }
                }

                var fileStatement: OpaquePointer?
                defer { sqlite3_finalize(fileStatement) }
                guard sqlite3_prepare_v2(db, """
                INSERT INTO files(path, source, mtime, size, indexed_at, chunk_count)
                VALUES(?, ?, ?, ?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET
                    source = excluded.source, mtime = excluded.mtime, size = excluded.size,
                    indexed_at = excluded.indexed_at, chunk_count = excluded.chunk_count;
                """, -1, &fileStatement, nil) == SQLITE_OK else { throw IndexError.sql(lastError) }
                bind(fileStatement, 1, file.url.path)
                bind(fileStatement, 2, file.source)
                sqlite3_bind_double(fileStatement, 3, file.modified.timeIntervalSince1970)
                sqlite3_bind_int64(fileStatement, 4, file.size)
                sqlite3_bind_double(fileStatement, 5, Date().timeIntervalSince1970)
                sqlite3_bind_int64(fileStatement, 6, Int64(chunks.count))
                guard sqlite3_step(fileStatement) == SQLITE_DONE else { throw IndexError.sql(lastError) }

                try execUnsynchronized("COMMIT;")
                cache = nil
            } catch {
                try? execUnsynchronized("ROLLBACK;")
                throw error
            }
        }
    }

    func forget(path: String) throws {
        try queue.sync {
            try execUnsynchronized("BEGIN IMMEDIATE;")
            do {
                try deleteFileRows(path: path)
                var statement: OpaquePointer?
                defer { sqlite3_finalize(statement) }
                guard sqlite3_prepare_v2(db, "DELETE FROM files WHERE path = ?;", -1, &statement, nil) == SQLITE_OK
                else { throw IndexError.sql(lastError) }
                bind(statement, 1, path)
                guard sqlite3_step(statement) == SQLITE_DONE else { throw IndexError.sql(lastError) }
                try execUnsynchronized("COMMIT;")
                cache = nil
            } catch {
                try? execUnsynchronized("ROLLBACK;")
                throw error
            }
        }
    }

    private func deleteFileRows(path: String) throws {
        var select: OpaquePointer?
        defer { sqlite3_finalize(select) }
        guard sqlite3_prepare_v2(db, "SELECT id FROM chunks WHERE file_path = ?;", -1, &select, nil) == SQLITE_OK
        else { throw IndexError.sql(lastError) }
        bind(select, 1, path)
        var ids: [Int64] = []
        while sqlite3_step(select) == SQLITE_ROW { ids.append(sqlite3_column_int64(select, 0)) }
        guard !ids.isEmpty else { return }

        var deleteFTS: OpaquePointer?
        defer { sqlite3_finalize(deleteFTS) }
        guard sqlite3_prepare_v2(db, "DELETE FROM chunks_fts WHERE rowid = ?;", -1, &deleteFTS, nil) == SQLITE_OK
        else { throw IndexError.sql(lastError) }
        for id in ids {
            sqlite3_reset(deleteFTS)
            sqlite3_bind_int64(deleteFTS, 1, id)
            guard sqlite3_step(deleteFTS) == SQLITE_DONE else { throw IndexError.sql(lastError) }
        }

        var deleteChunks: OpaquePointer?
        defer { sqlite3_finalize(deleteChunks) }
        guard sqlite3_prepare_v2(db, "DELETE FROM chunks WHERE file_path = ?;", -1, &deleteChunks, nil) == SQLITE_OK
        else { throw IndexError.sql(lastError) }
        bind(deleteChunks, 1, path)
        guard sqlite3_step(deleteChunks) == SQLITE_DONE else { throw IndexError.sql(lastError) }

        var orphans: OpaquePointer?
        defer { sqlite3_finalize(orphans) }
        _ = sqlite3_prepare_v2(db, """
        DELETE FROM conversations WHERE id NOT IN (SELECT DISTINCT conversation_id FROM chunks);
        """, -1, &orphans, nil)
        _ = sqlite3_step(orphans)
    }

    // MARK: - Retrieval

    /// Brute-force cosine over unit vectors. Both operands are normalized at write
    /// and query time, so the dot product is the cosine.
    func vectorSearch(_ query: [Float], limit: Int) -> [(id: Int64, score: Double)] {
        guard !query.isEmpty else { return [] }
        let normalized = Vector.normalized(query)
        return queue.sync {
            if cache == nil || cache?.dimensions != normalized.count {
                cache = loadCache(dimensions: normalized.count)
            }
            guard let cache, !cache.ids.isEmpty else { return [] }
            var scored: [(Int64, Double)] = []
            scored.reserveCapacity(cache.ids.count)
            let dimensions = cache.dimensions
            normalized.withUnsafeBufferPointer { queryBuffer in
                cache.values.withUnsafeBufferPointer { matrix in
                    for index in cache.ids.indices {
                        var dot: Float = 0
                        vDSP_dotpr(
                            matrix.baseAddress! + index * dimensions, 1,
                            queryBuffer.baseAddress!, 1,
                            &dot, vDSP_Length(dimensions)
                        )
                        scored.append((cache.ids[index], Double(dot)))
                    }
                }
            }
            return scored.sorted { $0.1 > $1.1 }.prefix(limit).map { (id: $0.0, score: $0.1) }
        }
    }

    private func loadCache(dimensions: Int) -> VectorCache {
        var ids: [Int64] = []
        var values: [Float] = []
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(
            db, "SELECT id, embedding FROM chunks WHERE embedding IS NOT NULL AND dim = ? LIMIT ?;",
            -1, &statement, nil
        ) == SQLITE_OK else { return VectorCache(dimensions: dimensions, ids: [], values: []) }
        sqlite3_bind_int64(statement, 1, Int64(dimensions))
        sqlite3_bind_int64(statement, 2, Int64(cacheLimit))
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let raw = sqlite3_column_blob(statement, 1) else { continue }
            let count = Int(sqlite3_column_bytes(statement, 1)) / MemoryLayout<Float>.size
            guard count == dimensions else { continue }
            ids.append(sqlite3_column_int64(statement, 0))
            values.append(contentsOf: UnsafeBufferPointer(
                start: raw.assumingMemoryBound(to: Float.self), count: count
            ))
        }
        return VectorCache(dimensions: dimensions, ids: ids, values: values)
    }

    /// FTS5 bm25 ranking. Scores are returned positive-is-better.
    func keywordSearch(_ query: String, limit: Int) -> [(id: Int64, score: Double)] {
        let tokens = Self.ftsTokens(query)
        guard !tokens.isEmpty else { return [] }
        let strict = tokens.joined(separator: " AND ")
        let loose = tokens.joined(separator: " OR ")
        let strictHits = rawKeywordSearch(strict, limit: limit)
        if strictHits.count >= min(limit, 5) || tokens.count == 1 { return strictHits }
        var merged = strictHits
        var seen = Set(strictHits.map(\.id))
        for hit in rawKeywordSearch(loose, limit: limit) where seen.insert(hit.id).inserted {
            merged.append(hit)
        }
        return Array(merged.prefix(limit))
    }

    private func rawKeywordSearch(_ expression: String, limit: Int) -> [(id: Int64, score: Double)] {
        queue.sync {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, """
            SELECT rowid, bm25(chunks_fts) FROM chunks_fts WHERE chunks_fts MATCH ? ORDER BY rank LIMIT ?;
            """, -1, &statement, nil) == SQLITE_OK else { return [] }
            bind(statement, 1, expression)
            sqlite3_bind_int64(statement, 2, Int64(limit))
            var hits: [(id: Int64, score: Double)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                hits.append((sqlite3_column_int64(statement, 0), -sqlite3_column_double(statement, 1)))
            }
            return hits
        }
    }

    /// FTS5 treats most punctuation as syntax; quoting each token keeps user input
    /// from becoming a malformed MATCH expression.
    static func ftsTokens(_ query: String) -> [String] {
        query
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { "\"\($0.lowercased())\"" }
    }

    func chunks(ids: [Int64]) -> [Int64: IndexedChunk] {
        guard !ids.isEmpty else { return [:] }
        return queue.sync {
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, """
            SELECT id, conversation_id, source, title, ordinal, starts_at, ends_at, text, artifact_paths, file_path
            FROM chunks WHERE id IN (\(placeholders));
            """, -1, &statement, nil) == SQLITE_OK else { return [:] }
            for (offset, id) in ids.enumerated() {
                sqlite3_bind_int64(statement, Int32(offset + 1), id)
            }
            var result: [Int64: IndexedChunk] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                let chunk = Self.chunk(from: statement)
                result[chunk.id] = chunk
            }
            return result
        }
    }

    func chunks(conversationId: String) -> [IndexedChunk] {
        queue.sync {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, """
            SELECT id, conversation_id, source, title, ordinal, starts_at, ends_at, text, artifact_paths, file_path
            FROM chunks WHERE conversation_id = ? ORDER BY ordinal;
            """, -1, &statement, nil) == SQLITE_OK else { return [] }
            bind(statement, 1, conversationId)
            var result: [IndexedChunk] = []
            while sqlite3_step(statement) == SQLITE_ROW { result.append(Self.chunk(from: statement)) }
            return result
        }
    }

    func conversation(id: String) -> ConversationRecord? {
        queue.sync {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, """
            SELECT id, source, title, started_at, ended_at, file_path, chunk_count, artifact_paths
            FROM conversations WHERE id = ?;
            """, -1, &statement, nil) == SQLITE_OK else { return nil }
            bind(statement, 1, id)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return Self.conversation(from: statement)
        }
    }

    func recentConversations(limit: Int) -> [ConversationRecord] {
        queue.sync {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, """
            SELECT id, source, title, started_at, ended_at, file_path, chunk_count, artifact_paths
            FROM conversations ORDER BY ended_at DESC LIMIT ?;
            """, -1, &statement, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_int64(statement, 1, Int64(limit))
            var result: [ConversationRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW { result.append(Self.conversation(from: statement)) }
            return result
        }
    }

    func stats() -> IndexStats {
        let sources: [SourceStatus] = queue.sync {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, """
            SELECT c.source,
                   (SELECT COUNT(*) FROM files f WHERE f.source = c.source),
                   COUNT(DISTINCT c.conversation_id),
                   COUNT(*),
                   (SELECT MAX(indexed_at) FROM files f WHERE f.source = c.source)
            FROM chunks c GROUP BY c.source ORDER BY c.source;
            """, -1, &statement, nil) == SQLITE_OK else { return [] }
            var result: [SourceStatus] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let stamp = sqlite3_column_type(statement, 4) == SQLITE_NULL
                    ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
                result.append(SourceStatus(
                    source: String(cString: sqlite3_column_text(statement, 0)),
                    files: Int(sqlite3_column_int64(statement, 1)),
                    conversations: Int(sqlite3_column_int64(statement, 2)),
                    chunks: Int(sqlite3_column_int64(statement, 3)),
                    lastIndexed: stamp
                ))
            }
            return result
        }
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
        return IndexStats(
            conversations: count("SELECT COUNT(*) FROM conversations;"),
            chunks: count("SELECT COUNT(*) FROM chunks;"),
            embedded: count("SELECT COUNT(*) FROM chunks WHERE embedding IS NOT NULL;"),
            bytes: bytes,
            model: meta("embedding_model") ?? "—",
            dimensions: Int(meta("embedding_dimensions") ?? "0") ?? 0,
            sources: sources
        )
    }

    private func count(_ sql: String) -> Int {
        queue.sync {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_ROW
            else { return 0 }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    // MARK: - Plumbing

    private struct VectorCache {
        let dimensions: Int
        let ids: [Int64]
        /// Row-major `ids.count × dimensions`.
        let values: [Float]
    }

    private static func chunk(from statement: OpaquePointer?) -> IndexedChunk {
        let artifacts = String(cString: sqlite3_column_text(statement, 8))
        return IndexedChunk(
            id: sqlite3_column_int64(statement, 0),
            conversationId: String(cString: sqlite3_column_text(statement, 1)),
            source: String(cString: sqlite3_column_text(statement, 2)),
            title: String(cString: sqlite3_column_text(statement, 3)),
            ordinal: Int(sqlite3_column_int64(statement, 4)),
            startsAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
            endsAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
            text: String(cString: sqlite3_column_text(statement, 7)),
            artifactPaths: artifacts.isEmpty ? [] : artifacts.components(separatedBy: "\n"),
            filePath: String(cString: sqlite3_column_text(statement, 9))
        )
    }

    private static func conversation(from statement: OpaquePointer?) -> ConversationRecord {
        let artifacts = String(cString: sqlite3_column_text(statement, 7))
        return ConversationRecord(
            id: String(cString: sqlite3_column_text(statement, 0)),
            source: String(cString: sqlite3_column_text(statement, 1)),
            title: String(cString: sqlite3_column_text(statement, 2)),
            startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
            endedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
            filePath: String(cString: sqlite3_column_text(statement, 5)),
            chunkCount: Int(sqlite3_column_int64(statement, 6)),
            artifactPaths: artifacts.isEmpty ? [] : artifacts.components(separatedBy: "\n")
        )
    }

    static func blob(from vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private var lastError: String { String(cString: sqlite3_errmsg(db)) }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
    }

    private func exec(_ sql: String) throws {
        try queue.sync { try execUnsynchronized(sql) }
    }

    private func execUnsynchronized(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw IndexError.sql(message)
        }
    }
}
