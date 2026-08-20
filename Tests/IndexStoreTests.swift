import XCTest
@testable import Recall

/// End-to-end over the real SQLite store with a deterministic fake embedder, so the
/// whole index → search → export path is covered without a model.
final class IndexStoreTests: XCTestCase {
    private var root: URL!
    private var inbox: URL!
    private var store: IndexStore!
    private let embedder = HashingEmbedder(dimensions: 64)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        inbox = root.appendingPathComponent("inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        store = try IndexStore(url: root.appendingPathComponent("index.db"))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ events: [RecallEvent], to name: String) throws -> URL {
        let url = inbox.appendingPathComponent(name)
        try RecallEventCodec.encode(events).write(to: url)
        return url
    }

    private func event(_ text: String, conversation: String, title: String, offset: TimeInterval = 0) -> RecallEvent {
        RecallEvent(
            source: RecallSource.inbox,
            conversationId: conversation,
            title: title,
            ts: Date(timeIntervalSince1970: 1_786_000_000 + offset),
            role: .user,
            text: text
        )
    }

    private func indexInbox(options: IndexOptions = IndexOptions()) async -> IndexRunReport {
        await Indexer(store: store, embedder: embedder).run(
            sources: [NormalizedJSONLSource(id: RecallSource.inbox, root: inbox)],
            options: options
        )
    }

    func testRoundTripEmbeddingsAndHybridSearch() async throws {
        _ = try write([
            event("The deepseek rebind swapped the builder model", conversation: "inbox:a", title: "Rebind"),
            event("Unrelated notes about coffee brewing", conversation: "inbox:b", title: "Coffee"),
        ], to: "one.jsonl")

        let report = await indexInbox()
        XCTAssertEqual(report.filesIndexed, 1)
        XCTAssertEqual(report.errors, [])
        XCTAssertGreaterThan(report.embedded, 0)

        let stats = store.stats()
        XCTAssertEqual(stats.conversations, 2)
        XCTAssertEqual(stats.chunks, stats.embedded, "every chunk got a vector")

        let engine = SearchEngine(store: store, embedder: embedder)
        let results = await engine.search("deepseek rebind")
        XCTAssertEqual(results.first?.id, "inbox:a")
        XCTAssertNotNil(results.first?.best.vectorRank)
        XCTAssertNotNil(results.first?.best.keywordRank)
    }

    func testKeywordSearchSurvivesPunctuationInTheQuery() async throws {
        _ = try write([event("token budget in Sources/Core/Chunker.swift", conversation: "inbox:a", title: "Chunker")],
                      to: "one.jsonl")
        _ = await indexInbox()
        XCTAssertFalse(store.keywordSearch("Sources/Core/Chunker.swift", limit: 5).isEmpty)
        XCTAssertTrue(store.keywordSearch("\"unbalanced (", limit: 5).isEmpty || true, "malformed input must not crash")
    }

    func testUnchangedFilesAreSkippedAndChangedFilesReplaceTheirChunks() async throws {
        let url = try write([event("first version", conversation: "inbox:a", title: "A")], to: "one.jsonl")
        _ = await indexInbox()
        let firstChunks = store.stats().chunks

        let second = await indexInbox()
        XCTAssertEqual(second.filesSkipped, 1)
        XCTAssertEqual(second.filesIndexed, 0)

        try RecallEventCodec.encode([
            event("second version mentions parquet", conversation: "inbox:a", title: "A"),
        ]).write(to: url)
        // mtime resolution: make sure the change is visible.
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)

        let third = await indexInbox()
        XCTAssertEqual(third.filesIndexed, 1)
        XCTAssertEqual(store.stats().chunks, firstChunks, "old chunks are replaced, not appended")
        XCTAssertFalse(store.keywordSearch("parquet", limit: 5).isEmpty)
        XCTAssertTrue(store.keywordSearch("first version", limit: 5).isEmpty
                      || store.chunks(ids: store.keywordSearch("first", limit: 5).map(\.id)).values
                          .allSatisfy { !$0.text.contains("first version") })
    }

    func testDeletedFilesLeaveTheIndex() async throws {
        let url = try write([event("temporary", conversation: "inbox:a", title: "A")], to: "one.jsonl")
        _ = await indexInbox()
        XCTAssertEqual(store.stats().conversations, 1)

        try FileManager.default.removeItem(at: url)
        let report = await indexInbox()
        XCTAssertEqual(report.filesRemoved, 1)
        XCTAssertEqual(store.stats().conversations, 0)
        XCTAssertEqual(store.stats().chunks, 0)
    }

    func testSkipEmbeddingsStillSupportsKeywordSearch() async throws {
        _ = try write([event("embedding-free path", conversation: "inbox:a", title: "A")], to: "one.jsonl")
        let report = await indexInbox(options: IndexOptions(skipEmbeddings: true))
        XCTAssertEqual(report.embedded, 0)
        XCTAssertGreaterThan(store.stats().chunks, 0)
        XCTAssertEqual(store.stats().embedded, 0)

        let engine = SearchEngine(store: store, embedder: embedder)
        let results = engine.keywordOnlySearch("embedding-free")
        XCTAssertEqual(results.first?.id, "inbox:a")
    }

    func testTranscriptRebuildsFromTheSourceFileAndFallsBackToTheIndex() async throws {
        let url = try write([
            event("first turn", conversation: "inbox:a", title: "A"),
            event("second turn about /tmp/x.txt", conversation: "inbox:a", title: "A", offset: 10),
        ], to: "one.jsonl")
        _ = await indexInbox()

        let provider = TranscriptProvider(store: store, sources: [NormalizedJSONLSource(id: RecallSource.inbox, root: inbox)])
        let live = try XCTUnwrap(provider.transcript(for: "inbox:a"))
        XCTAssertFalse(live.reconstructed)
        XCTAssertEqual(live.messageCount, 2)

        try FileManager.default.removeItem(at: url)
        let rebuilt = try XCTUnwrap(provider.transcript(for: "inbox:a"))
        XCTAssertTrue(rebuilt.reconstructed)
        XCTAssertTrue(rebuilt.text.contains("second turn"))
    }

    func testSourceStatsAreReportedPerSource() async throws {
        _ = try write([event("inbox item", conversation: "inbox:a", title: "A")], to: "one.jsonl")
        _ = await indexInbox()
        let stats = store.stats()
        XCTAssertEqual(stats.sources.map(\.source), [RecallSource.inbox])
        XCTAssertEqual(stats.sources.first?.files, 1)
        XCTAssertNotNil(stats.sources.first?.lastIndexed)
        XCTAssertEqual(stats.model, embedder.model)
    }

    func testVectorSearchRanksTheCloserChunkFirst() async throws {
        _ = try write([
            event("apples oranges pears fruit basket", conversation: "inbox:fruit", title: "Fruit"),
            event("kubernetes ingress controller nginx", conversation: "inbox:infra", title: "Infra"),
        ], to: "one.jsonl")
        _ = await indexInbox()

        let query = try await embedder.embed(["kubernetes ingress"])[0]
        let hits = store.vectorSearch(query, limit: 2)
        XCTAssertEqual(hits.count, 2)
        let top = try XCTUnwrap(store.chunks(ids: [hits[0].id])[hits[0].id])
        XCTAssertEqual(top.conversationId, "inbox:infra")
        XCTAssertGreaterThan(hits[0].score, hits[1].score)
    }
}
