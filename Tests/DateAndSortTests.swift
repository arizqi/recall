import XCTest
@testable import Recall

final class DateWindowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_786_000_000)

    func testRelativeSpansAreReadTheWayPeopleTypeThem() {
        XCTAssertEqual(DateWindow.date(from: "7d", now: now), now.addingTimeInterval(-7 * 86_400))
        XCTAssertEqual(DateWindow.date(from: "2w", now: now), now.addingTimeInterval(-14 * 86_400))
        XCTAssertEqual(DateWindow.date(from: "3m", now: now), now.addingTimeInterval(-90 * 86_400))
        XCTAssertEqual(DateWindow.date(from: "1y", now: now), now.addingTimeInterval(-365 * 86_400))
        XCTAssertEqual(DateWindow.date(from: " 7D ", now: now), now.addingTimeInterval(-7 * 86_400))
    }

    func testCalendarDatesAndISOTimestampsParse() {
        XCTAssertNotNil(DateWindow.date(from: "2026-08-19"))
        XCTAssertNotNil(DateWindow.date(from: "2026-08-19T13:29:50Z"))
    }

    func testUnparseableInputIsRejectedRatherThanGuessed() {
        // A silently ignored --since looks exactly like missing data.
        XCTAssertNil(DateWindow.date(from: "last tuesday"))
        XCTAssertNil(DateWindow.date(from: ""))
        XCTAssertNil(DateWindow.date(from: "d"))
    }

    func testContainsIsInclusiveAndOpenEnded() {
        let window = DateWindow(since: Date(timeIntervalSince1970: 100), until: Date(timeIntervalSince1970: 200))
        XCTAssertTrue(window.contains(Date(timeIntervalSince1970: 150)))
        XCTAssertTrue(window.contains(Date(timeIntervalSince1970: 100)))
        XCTAssertFalse(window.contains(Date(timeIntervalSince1970: 99)))
        XCTAssertFalse(window.contains(Date(timeIntervalSince1970: 201)))
        XCTAssertTrue(DateWindow.any.contains(Date()))
        XCTAssertTrue(DateWindow.any.isAny)
    }

    func testPresetsProduceTheExpectedSpans() {
        XCTAssertTrue(DateWindow.Preset.any.window(now: now).isAny)
        XCTAssertEqual(DateWindow.Preset.week.window(now: now).since, now.addingTimeInterval(-7 * 86_400))
        XCTAssertNil(DateWindow.Preset.week.window(now: now).until)
    }
}

/// Sorting and date filtering exercised through the real index.
final class SearchOrderingTests: XCTestCase {
    private var root: URL!
    private var inbox: URL!
    private var store: IndexStore!
    private let embedder = HashingEmbedder(dimensions: 64)
    private let day: TimeInterval = 86_400

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        inbox = root.appendingPathComponent("inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        store = try IndexStore(url: root.appendingPathComponent("index.db"))

        // "old" is the stronger match; "new" is the more recent one.
        let base = Date(timeIntervalSince1970: 1_786_000_000)
        let events = [
            RecallEvent(source: RecallSource.inbox, conversationId: "inbox:old", title: "Old and relevant",
                        ts: base, role: .user, text: "deepseek rebind deepseek rebind deepseek rebind"),
            RecallEvent(source: RecallSource.inbox, conversationId: "inbox:mid", title: "Middle",
                        ts: base.addingTimeInterval(10 * day), role: .user, text: "deepseek rebind mentioned once"),
            RecallEvent(source: RecallSource.inbox, conversationId: "inbox:new", title: "New and relevant",
                        ts: base.addingTimeInterval(30 * day), role: .user, text: "deepseek rebind briefly"),
        ]
        try RecallEventCodec.encode(events).write(to: inbox.appendingPathComponent("fixture.jsonl"))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func index() async {
        _ = await Indexer(store: store, embedder: embedder).run(
            sources: [NormalizedJSONLSource(id: RecallSource.inbox, root: inbox)]
        )
    }

    func testDefaultSortIsMostRecent() async throws {
        await index()
        XCTAssertEqual(SearchOptions().sort, .date, "most of the time the latest mention is the one you want")
        let results = await SearchEngine(store: store, embedder: embedder).search("deepseek rebind")
        XCTAssertEqual(results.map(\.id), ["inbox:new", "inbox:mid", "inbox:old"])
    }

    func testRelevanceSortPutsTheStrongestMatchFirst() async throws {
        await index()
        var options = SearchOptions()
        options.sort = .relevance
        let results = await SearchEngine(store: store, embedder: embedder).search("deepseek rebind", options: options)
        XCTAssertEqual(results.first?.id, "inbox:old")
    }

    func testSinceAndUntilNarrowTheResults() async throws {
        await index()
        let base = Date(timeIntervalSince1970: 1_786_000_000)
        var options = SearchOptions()
        options.window = DateWindow(since: base.addingTimeInterval(20 * day))
        var results = await SearchEngine(store: store, embedder: embedder).search("deepseek rebind", options: options)
        XCTAssertEqual(results.map(\.id), ["inbox:new"])

        options.window = DateWindow(since: base.addingTimeInterval(5 * day), until: base.addingTimeInterval(20 * day))
        results = await SearchEngine(store: store, embedder: embedder).search("deepseek rebind", options: options)
        XCTAssertEqual(results.map(\.id), ["inbox:mid"])
    }

    func testRecentConversationsRespectWindowAndSource() async throws {
        await index()
        let base = Date(timeIntervalSince1970: 1_786_000_000)
        XCTAssertEqual(
            store.recentConversations(limit: 10).map(\.id),
            ["inbox:new", "inbox:mid", "inbox:old"],
            "the browse list is newest first"
        )
        XCTAssertEqual(
            store.recentConversations(limit: 10, window: DateWindow(since: base.addingTimeInterval(20 * day))).map(\.id),
            ["inbox:new"]
        )
        XCTAssertTrue(store.recentConversations(limit: 10, sources: ["nope"]).isEmpty)
    }
}
