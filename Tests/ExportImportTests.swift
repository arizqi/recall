import XCTest
@testable import Recall

/// Account-export import for both vendors. claude.ai's export is the only way to
/// search Cowork sessions created after Claude Desktop moved to remote sessions —
/// see the Cowork coverage note in the README.
final class ExportImportTests: XCTestCase {
    private let chatGPTExport = """
    [{"title":"Vector search","conversation_id":"c1","create_time":1786360000,
      "mapping":{
        "n0":{"message":{"author":{"role":"system"},"create_time":1786360000,"content":{"parts":["hidden"]}}},
        "n2":{"message":{"author":{"role":"assistant"},"create_time":1786360200,"content":{"parts":["Use cosine similarity."]}}},
        "n1":{"message":{"author":{"role":"user"},"create_time":1786360100,"content":{"parts":["How do I rank results?"]}}}
      }}]
    """

    private let claudeExport = """
    [{"uuid":"conv-1","name":"Cowork session","created_at":"2026-08-19T10:00:00.000000Z",
      "chat_messages":[
        {"uuid":"m1","sender":"human","created_at":"2026-08-19T10:00:00.000000Z",
         "text":"summarize the roadmap","content":[{"type":"text","text":"summarize the roadmap"}],
         "files":[{"file_name":"roadmap.pdf"}],"attachments":[]},
        {"uuid":"m2","sender":"assistant","created_at":"2026-08-19T10:00:30.000000Z",
         "text":"","content":[{"type":"text","text":"Here is the roadmap summary."}],"files":[],"attachments":[]}
      ]}]
    """

    func testDetectsAndParsesTheClaudeAIExport() {
        let parsed = ExportImporter.events(fromConversationsJSON: Data(claudeExport.utf8))
        XCTAssertEqual(parsed.kind, .claudeAI)
        XCTAssertEqual(parsed.events.count, 2)
        XCTAssertEqual(parsed.events.map(\.role), [.user, .assistant])
        XCTAssertEqual(parsed.events[0].source, RecallSource.claudeAI)
        XCTAssertEqual(parsed.events[0].conversationId, "claude-ai:conv-1")
        XCTAssertEqual(parsed.events[0].title, "Cowork session")
        XCTAssertTrue(parsed.events[0].artifactPaths.contains("roadmap.pdf"), "attachments are evidence too")
        XCTAssertEqual(parsed.events[1].text, "Here is the roadmap summary.",
                       "an empty flat text field falls back to the content blocks")
    }

    func testDetectsAndParsesTheChatGPTExport() {
        let parsed = ExportImporter.events(fromConversationsJSON: Data(chatGPTExport.utf8))
        XCTAssertEqual(parsed.kind, .chatgpt)
        XCTAssertEqual(parsed.events.map(\.role), [.user, .assistant])
        XCTAssertEqual(parsed.events[0].source, RecallSource.chatgpt)
    }

    func testUnknownJSONIsRejectedRatherThanImportedEmpty() {
        let parsed = ExportImporter.events(fromConversationsJSON: Data(#"[{"foo":"bar"}]"#.utf8))
        XCTAssertNil(parsed.kind)
        XCTAssertTrue(parsed.events.isEmpty)
    }

    func testImportWritesBusJSONLThatTheInboxReaderPicksUp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("conversations.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(claudeExport.utf8).write(to: source)

        let result = try ExportImporter(destination: root.appendingPathComponent("imports"))
            .importArchive(at: source)
        XCTAssertEqual(result.kind, .claudeAI)
        XCTAssertEqual(result.conversations, 1)
        XCTAssertEqual(result.events, 2)

        let file = try XCTUnwrap(result.file)
        let reread = NormalizedJSONLSource(id: RecallSource.imports, root: file.deletingLastPathComponent())
            .events(in: file)
        XCTAssertEqual(reread.map(\.text), ["summarize the roadmap", "Here is the roadmap summary."])
        XCTAssertEqual(reread[0].source, RecallSource.claudeAI, "the badge survives the round trip")
    }
}

final class CoworkCoverageTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_786_000_000)

    func testFreshTranscriptsReadAsComplete() {
        let coverage = CoworkCoverage.coverage(
            directoryExists: true,
            lastIndexed: base,
            directoryTouched: base.addingTimeInterval(3_600)
        )
        XCTAssertEqual(coverage.state, .complete)
        XCTAssertFalse(coverage.isProblem)
    }

    func testALiveDirectoryWithFrozenTranscriptsIsReportedAsCloudOnly() {
        // Exactly the observed situation: the session directory keeps being written
        // (remote-session-spaces.json) while the newest audit.jsonl stays put.
        let coverage = CoworkCoverage.coverage(
            directoryExists: true,
            lastIndexed: base,
            directoryTouched: base.addingTimeInterval(6 * 86_400)
        )
        XCTAssertEqual(coverage.state, .transcriptsStopped(lastLocal: base))
        XCTAssertTrue(coverage.detail.contains("cloud-only"))
        XCTAssertTrue(coverage.detail.contains("claude.ai export"))
    }

    func testAMissingDirectoryIsNotPresentRatherThanBroken() {
        let coverage = CoworkCoverage.coverage(directoryExists: false, lastIndexed: nil, directoryTouched: nil)
        XCTAssertEqual(coverage.state, .notPresent)
    }

    func testDirectoryWalkIgnoresBundledSkillPayloads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let session = root.appendingPathComponent("local_1")
        let skills = root.appendingPathComponent("skills-plugin/x/skills")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let audit = session.appendingPathComponent("audit.jsonl")
        try Data("{}\n".utf8).write(to: audit)
        try FileManager.default.setAttributes([.modificationDate: base], ofItemAtPath: audit.path)
        let skill = skills.appendingPathComponent("SKILL.md")
        try Data("x".utf8).write(to: skill)
        try FileManager.default.setAttributes(
            [.modificationDate: base.addingTimeInterval(30 * 86_400)], ofItemAtPath: skill.path
        )

        // Claude refreshes bundled skills on every launch; counting them would report
        // a cloud-only gap on a machine that simply opened the app.
        let touched = try XCTUnwrap(CoworkCoverage.directoryTouched(at: root))
        XCTAssertLessThan(touched.timeIntervalSince(base), 86_400)
    }
}
