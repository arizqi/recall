import XCTest
@testable import Recall

/// One fixture per source. These are the canary tests: Claude and friends change
/// private storage formats without notice, and an isolated reader plus a fixture is
/// what makes that a five-minute diagnosis instead of a mystery.
final class NormalizationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testClaudeCodeSessionNormalizesAndLeavesTheFileUntouched() throws {
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("session.jsonl")
        let content = """
        {"type":"user","sessionId":"abc","timestamp":"2026-08-10T12:30:00.000Z","cwd":"/Users/example/widget","message":{"role":"user","content":"Wire up the importer in /Users/example/widget/App.swift"}}
        {"type":"assistant","sessionId":"abc","timestamp":"2026-08-10T12:30:01.000Z","message":{"content":[{"type":"text","text":"Done."}]}}
        {"type":"user","sessionId":"abc","timestamp":"2026-08-10T12:30:02.000Z","toolUseResult":{"ok":true},"message":{"content":"tool noise"}}
        {"type":"user","sessionId":"abc","isSidechain":true,"message":{"content":"subagent chatter"}}
        {"type":"user","sessionId":"abc","message":{"content":"<system-reminder>ignore me</system-reminder>"}}

        """
        try Data(content.utf8).write(to: file)
        let before = try Data(contentsOf: file)

        let events = ClaudeCodeSource(root: root).events(in: file)

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.map(\.role), [.user, .assistant])
        XCTAssertEqual(events[0].conversationId, "claude-code:abc")
        XCTAssertEqual(events[0].source, "claude-code")
        XCTAssertTrue(events[0].title.contains("Wire up the importer"))
        XCTAssertEqual(events[1].title, events[0].title, "later turns inherit the conversation title")
        XCTAssertEqual(events[0].artifactPaths, ["/Users/example/widget/App.swift"])
        XCTAssertEqual(try Data(contentsOf: file), before, "sources are read-only")
    }

    func testClaudeCodeDiscoveryTakesTopLevelSessionsOnly() throws {
        let project = root.appendingPathComponent("project")
        let subagents = project.appendingPathComponent("session/subagents")
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: project.appendingPathComponent("main.jsonl"))
        try Data("{}\n".utf8).write(to: subagents.appendingPathComponent("agent.jsonl"))

        let files = ClaudeCodeSource(root: root).discover()
        XCTAssertEqual(files.map(\.url.lastPathComponent), ["main.jsonl"])
    }

    func testCoworkAuditTranscriptUsesSiblingMetadataTitle() throws {
        let session = root.appendingPathComponent("local_42")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try Data(#"{"sessionId":"local_42","title":"Quarterly plan","createdAt":1786365000000}"#.utf8)
            .write(to: root.appendingPathComponent("local_42.json"))
        let audit = session.appendingPathComponent("audit.jsonl")
        try Data("""
        {"type":"user","uuid":"u1","timestamp":"2026-08-11T09:00:00Z","message":{"content":"Draft the plan"}}
        {"type":"assistant","uuid":"a1","timestamp":"2026-08-11T09:00:05Z","message":{"content":[{"type":"text","text":"Drafted."}]}}
        {"type":"assistant","uuid":"a1","isReplay":true,"message":{"content":[{"type":"text","text":"Drafted."}]}}

        """.utf8).write(to: audit)

        let events = CoworkSource(root: root).events(in: audit)
        XCTAssertEqual(events.count, 2, "replayed duplicates are dropped")
        XCTAssertEqual(events[0].title, "Quarterly plan")
        XCTAssertEqual(events[0].conversationId, "cowork:local_42")
        XCTAssertEqual(CoworkSource(root: root).discover().count, 1)
    }

    func testRoomTranscriptKeepsSpeakerAndMapsHumanToUser() throws {
        let file = root.appendingPathComponent("company.jsonl")
        try Data("""
        {"v":1,"room":"company","at":"2026-08-19T13:29:50.309Z","kind":"human","from":"human","name":"Ashar","text":"replace the builder model with deepseek v4 pro"}
        {"v":1,"room":"company","at":"2026-08-19T13:31:00.000Z","kind":"turn","from":"builder","name":"Builder","text":"Rebound the builder to deepseek."}

        """.utf8).write(to: file)

        let events = RoomSource(root: root).events(in: file)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].role, .user)
        XCTAssertEqual(events[1].role, .assistant)
        XCTAssertTrue(events[0].text.hasPrefix("[Ashar] "))
        let day = DateFormatter.day.string(from: events[0].ts)
        XCTAssertEqual(events[0].conversationId, "room:company#\(day)")
        XCTAssertEqual(events[0].title, "Room — company · \(day)")
        XCTAssertEqual(events[0].conversationId, events[1].conversationId)
    }

    func testRoomLogIsSplitPerDay() throws {
        let file = root.appendingPathComponent("company.jsonl")
        try Data("""
        {"room":"company","at":"2026-08-19T13:00:00Z","kind":"human","name":"Ashar","text":"day one question"}
        {"room":"company","at":"2026-08-22T13:00:00Z","kind":"turn","name":"Builder","text":"day two answer"}

        """.utf8).write(to: file)

        // A room is an append-only log; without the split, one day's work is a needle
        // in months of unrelated chatter and never ranks.
        let events = RoomSource(root: root).events(in: file)
        XCTAssertEqual(Set(events.map(\.conversationId)).count, 2)
        XCTAssertNotEqual(events[0].conversationId, events[1].conversationId)
    }

    func testInboxRoundTripsTheDocumentedBusFormat() throws {
        let original = RecallEvent(
            source: "linear",
            conversationId: "linear:ENG-1",
            title: "Ship the indexer",
            ts: Date(timeIntervalSince1970: 1_786_365_000),
            role: .assistant,
            text: "Indexer landed in /Users/example/recall/Sources/Core/Indexer.swift",
            artifactPaths: ["/Users/example/recall/Sources/Core/Indexer.swift"]
        )
        let file = root.appendingPathComponent("drop.jsonl")
        try RecallEventCodec.encode([original]).write(to: file)

        let events = NormalizedJSONLSource(id: RecallSource.inbox, root: root).events(in: file)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].source, "linear", "a bus event keeps the source it declares")
        XCTAssertEqual(events[0].conversationId, original.conversationId)
        XCTAssertEqual(events[0].text, original.text)
        XCTAssertEqual(events[0].artifactPaths, original.artifactPaths)
        XCTAssertEqual(
            Int(events[0].ts.timeIntervalSince1970),
            Int(original.ts.timeIntervalSince1970)
        )
    }

    func testInboxSkipsLinesThatAreNotRecallEvents() throws {
        let file = root.appendingPathComponent("mixed.jsonl")
        try Data("""
        {"hello":"world"}
        not json at all
        {"source":"inbox","conversationId":"inbox:1","title":"T","ts":1786365000,"role":"user","text":"real event"}

        """.utf8).write(to: file)
        let events = NormalizedJSONLSource(root: root).events(in: file)
        XCTAssertEqual(events.map(\.text), ["real event"])
    }

    func testChatGPTExportOrdersMessagesAndSkipsSystemTurns() throws {
        let json = """
        [{"title":"Vector search","conversation_id":"c1","create_time":1786360000,
          "mapping":{
            "n0":{"message":{"author":{"role":"system"},"create_time":1786360000,"content":{"parts":["hidden"]}}},
            "n2":{"message":{"author":{"role":"assistant"},"create_time":1786360200,"content":{"parts":["Use cosine similarity."]}}},
            "n1":{"message":{"author":{"role":"user"},"create_time":1786360100,"content":{"parts":["How do I rank results?"]}}}
          }}]
        """
        let parsed = ExportImporter.events(fromConversationsJSON: Data(json.utf8))
        XCTAssertEqual(parsed.kind, .chatgpt)
        let events = parsed.events
        XCTAssertEqual(events.map(\.role), [.user, .assistant])
        XCTAssertEqual(events[0].conversationId, "chatgpt:c1")
        XCTAssertEqual(events[0].title, "Vector search")
        XCTAssertEqual(events[1].text, "Use cosine similarity.")
    }

    func testMachineInjectedTurnsAreNotIndexed() throws {
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("session.jsonl")
        try Data("""
        {"type":"user","sessionId":"s","timestamp":"2026-08-19T10:00:00Z","message":{"content":"Real question about the room"}}
        {"type":"user","sessionId":"s","timestamp":"2026-08-19T10:00:01Z","message":{"content":"<task-notification><event>[human] noise</event></task-notification>"}}
        {"type":"user","sessionId":"s","timestamp":"2026-08-19T10:00:02Z","message":{"content":"</task-notification> trailing machine context"}}
        {"type":"user","sessionId":"s","timestamp":"2026-08-19T10:00:03Z","message":{"content":"Caveat: The messages below were generated by a command"}}
        {"type":"assistant","sessionId":"s","timestamp":"2026-08-19T10:00:04Z","message":{"content":[{"type":"text","text":"A real answer."}]}}

        """.utf8).write(to: file)

        let events = ClaudeCodeSource(root: root).events(in: file)
        XCTAssertEqual(events.map(\.text), ["Real question about the room", "A real answer."])
    }

    func testProseMentioningAngleBracketsIsStillIndexed() {
        XCTAssertFalse(RecallText.isNoise("Use <T> generics carefully — see the notes."))
        XCTAssertTrue(RecallText.isNoise("<system-reminder>hidden</system-reminder>"))
    }

    func testTimestampsAcceptSecondsMillisecondsAndISO() {
        XCTAssertEqual(Timestamps.date(1_786_365_000)?.timeIntervalSince1970, 1_786_365_000)
        XCTAssertEqual(Timestamps.date(1_786_365_000_000)?.timeIntervalSince1970, 1_786_365_000)
        XCTAssertNotNil(Timestamps.date("2026-08-19T13:29:50.309Z"))
        XCTAssertNotNil(Timestamps.date("2026-08-19T13:29:50Z"))
        XCTAssertNil(Timestamps.date("not a date"))
    }

    func testArtifactScannerFindsAbsolutePathsAndIgnoresProse() {
        let paths = ArtifactScanner.paths(in: """
        Wrote /Users/ashar/recall/Sources/Core/IndexStore.swift and ~/Library/Application/x.db.
        Visit example.com for details.
        """)
        XCTAssertTrue(paths.contains("/Users/ashar/recall/Sources/Core/IndexStore.swift"))
        XCTAssertTrue(paths.contains { $0.hasPrefix("~/Library/Application") })
        XCTAssertFalse(paths.contains { $0.contains("example.com") })
    }
}
