import XCTest
@testable import Recall

/// Fixtures mirror the real shape of a batched claude.ai export
/// (`data-…-batch-0000.zip`): `conversations.json` plus `design_chats/`, `projects/`,
/// and account files that are deliberately ignored. Content is invented.
final class BatchedExportTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("export/design_chats"), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("export/projects"), withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var exportRoot: URL { root.appendingPathComponent("export") }

    private func write(_ text: String, to relative: String) throws {
        try Data(text.utf8).write(to: exportRoot.appendingPathComponent(relative))
    }

    /// Two real conversations, and one whose messages carry no body at all — the
    /// shape that silently cost half the import.
    private func writeConversations() throws {
        try write("""
        [
          {"uuid":"c-1","name":"Pricing model","created_at":"2026-03-01T10:00:00.000000Z",
           "chat_messages":[
             {"uuid":"m1","sender":"human","created_at":"2026-03-01T10:00:00.000000Z",
              "text":"what should the pricing tiers be","content":[],"files":[],"attachments":[]},
             {"uuid":"m2","sender":"assistant","created_at":"2026-03-01T10:00:20.000000Z",
              "text":"","content":[{"type":"text","text":"Three tiers works best."}],"files":[],"attachments":[]}]},
          {"uuid":"c-2","name":"","summary":"","created_at":"2026-03-02T10:00:00.000000Z",
           "chat_messages":[
             {"uuid":"m3","sender":"human","created_at":"2026-03-02T10:00:00.000000Z",
              "text":"","content":[],"files":[],"attachments":[]},
             {"uuid":"m4","sender":"assistant","created_at":"2026-03-02T10:00:05.000000Z",
              "text":"","content":[],"files":[],"attachments":[]}]},
          {"uuid":"c-3","name":"Launch checklist","created_at":"2026-03-03T10:00:00.000000Z",
           "chat_messages":[
             {"uuid":"m5","sender":"human","created_at":"2026-03-03T10:00:00.000000Z",
              "text":"draft a launch checklist","content":[],"files":[],"attachments":[]}]}
        ]
        """, to: "conversations.json")
    }

    /// design_chats nest the body one level deeper, and every one is titled "Chat".
    private func writeDesignChat() throws {
        try write("""
        {"uuid":"d-1","title":"Chat","project":{"uuid":"p-9","name":"quran app"},
         "created_at":"2026-04-24T00:33:00.000000+00:00",
         "updated_at":"2026-04-24T01:00:00.000000+00:00",
         "messages":[
           {"uuid":"dm1","role":"user","created_at":"2026-04-24T00:33:18.808357+00:00",
            "content":{"role":"user","content":"","attachments":[
              {"id":"a1","name":"brief","type":"text","content":"Create a high-fidelity, polished design."}]}},
           {"uuid":"dm2","role":"assistant","created_at":"2026-04-24T00:34:00.000000+00:00",
            "content":{"role":"assistant","content":"I'll design Qurania, a Quran learning app for kids.",
                       "contentBlocks":[]}}
         ]}
        """, to: "design_chats/d-1.json")
    }

    private func writeProject() throws {
        try write("""
        {"uuid":"p-1","name":"How to use Claude","description":"An example project.",
         "created_at":"2026-02-20T14:34:25.354388+00:00","is_private":true,
         "docs":[{"uuid":"doc-1","filename":"prompting guide.md",
                  "content":"# Prompting guide\\n\\nBe clear and specific.",
                  "created_at":"2026-02-20T14:34:25.354388+00:00"}]}
        """, to: "projects/p-1.json")
    }

    private func writeIgnoredAccountFiles() throws {
        try write(#"{"memories":[{"text":"private note"}]}"#, to: "memories.json")
        try write(#"[{"email":"someone@example.com"}]"#, to: "users.json")
        try write(#"[{"ip":"127.0.0.1"}]"#, to: "login_history.json")
    }

    // MARK: - Parsing

    func testEveryPartOfABatchedExportIsRead() throws {
        try writeConversations()
        try writeDesignChat()
        try writeProject()
        try writeIgnoredAccountFiles()

        let parsed = ExportImporter.parseDirectory(exportRoot)
        XCTAssertEqual(parsed.kind, .claudeAI)
        XCTAssertEqual(parsed.breakdown["conversations"], 2)
        XCTAssertEqual(parsed.breakdown["design chats"], 1)
        XCTAssertEqual(parsed.breakdown["project docs"], 1)

        let ids = Set(parsed.events.map(\.conversationId))
        XCTAssertEqual(ids, [
            "claude-ai:c-1", "claude-ai:c-3",
            "claude-ai:design:d-1",
            "claude-ai:project:p-1",
        ])
    }

    func testConversationsWithNoMessageBodyAreCountedNotLost() throws {
        try writeConversations()
        let parsed = ExportImporter.parseDirectory(exportRoot)
        // c-2's messages have empty `text` and an empty `content` array — the export
        // carries no body for it, so there is nothing to index and the user is told.
        XCTAssertEqual(parsed.skippedEmpty, 1)
        XCTAssertFalse(parsed.events.contains { $0.conversationId == "claude-ai:c-2" })
    }

    func testDesignChatBodyComesFromNestedContentAndAttachments() throws {
        try writeDesignChat()
        let parsed = ExportImporter.parseDirectory(exportRoot)
        XCTAssertEqual(parsed.events.count, 2)
        XCTAssertEqual(parsed.events[0].role, .user)
        XCTAssertTrue(parsed.events[0].text.contains("high-fidelity"), "the brief lives in an attachment")
        XCTAssertTrue(parsed.events[1].text.contains("Qurania"))
        // Every design chat is titled "Chat"; the project name is the real identity.
        XCTAssertEqual(parsed.events[0].title, "Design — quran app")
    }

    func testProjectDocsBecomeSearchableWithTheirFilename() throws {
        try writeProject()
        let parsed = ExportImporter.parseDirectory(exportRoot)
        XCTAssertEqual(parsed.events.count, 2, "description plus one doc")
        XCTAssertEqual(parsed.events[0].title, "Project — How to use Claude")
        XCTAssertTrue(parsed.events[1].text.contains("prompting guide.md"))
        XCTAssertTrue(parsed.events[1].text.contains("Be clear and specific"))
        XCTAssertEqual(parsed.events[1].artifactPaths, ["prompting guide.md"])
    }

    func testAccountFilesAreNotIndexed() throws {
        try writeConversations()
        try writeIgnoredAccountFiles()
        let parsed = ExportImporter.parseDirectory(exportRoot)
        XCTAssertFalse(parsed.events.contains { $0.text.contains("private note") })
        XCTAssertFalse(parsed.events.contains { $0.text.contains("example.com") })
    }

    // MARK: - Import, batching, failure

    private func makeZip(named name: String) throws -> URL {
        let zip = root.appendingPathComponent(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-r", zip.path, "."]
        process.currentDirectoryURL = exportRoot
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return zip
    }

    func testImportingAZipWritesBusJSONLAndReportsTheBreakdown() throws {
        try writeConversations()
        try writeDesignChat()
        try writeProject()
        let zip = try makeZip(named: "batch-0000.zip")

        let destination = root.appendingPathComponent("imports")
        let result = try ExportImporter(destination: destination).importArchive(at: zip)
        XCTAssertEqual(result.kind, .claudeAI)
        XCTAssertEqual(result.conversations, 4)
        XCTAssertEqual(result.skippedEmpty, 1)
        XCTAssertTrue(result.detail.contains("design chats"))
        XCTAssertTrue(result.detail.contains("no message text"))

        let reread = NormalizedJSONLSource(id: RecallSource.imports, root: destination).events(in: result.file)
        XCTAssertEqual(reread.count, result.events)
        XCTAssertTrue(reread.allSatisfy { $0.source == RecallSource.claudeAI })
    }

    func testASecondBatchOnlyAddsWhatIsNew() throws {
        try writeConversations()
        let destination = root.appendingPathComponent("imports")
        let first = try ExportImporter(destination: destination)
            .importArchive(at: exportRoot.appendingPathComponent("conversations.json"))
        XCTAssertEqual(first.conversations, 2)

        // A later batch repeats c-1 and adds c-9. Batched exports overlap; only the
        // new conversation may land.
        try write("""
        [
          {"uuid":"c-1","name":"Pricing model","created_at":"2026-03-01T10:00:00.000000Z",
           "chat_messages":[{"uuid":"m1","sender":"human","created_at":"2026-03-01T10:00:00.000000Z",
                             "text":"what should the pricing tiers be","content":[]}]},
          {"uuid":"c-9","name":"Later thread","created_at":"2026-05-01T10:00:00.000000Z",
           "chat_messages":[{"uuid":"m9","sender":"human","created_at":"2026-05-01T10:00:00.000000Z",
                             "text":"anything new here","content":[]}]}
        ]
        """, to: "batch-0001.json")

        let second = try ExportImporter(destination: destination)
            .importArchive(at: exportRoot.appendingPathComponent("batch-0001.json"))
        XCTAssertEqual(second.conversations, 1)
        XCTAssertEqual(second.duplicates, 1)
        let ids = ExportImporter(destination: destination).existingConversationIDs()
        XCTAssertEqual(ids, ["claude-ai:c-1", "claude-ai:c-3", "claude-ai:c-9"])
    }

    func testAnExportWithNothingToAddFailsLoudlyAndWritesNoFile() throws {
        try writeConversations()
        let destination = root.appendingPathComponent("imports")
        _ = try ExportImporter(destination: destination)
            .importArchive(at: exportRoot.appendingPathComponent("conversations.json"))
        let before = try FileManager.default.contentsOfDirectory(atPath: destination.path)

        // Re-importing the same file must raise, not leave another empty file behind.
        XCTAssertThrowsError(
            try ExportImporter(destination: destination)
                .importArchive(at: exportRoot.appendingPathComponent("conversations.json"))
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("already imported"))
        }
        let after = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        XCTAssertEqual(before, after, "a failed import leaves nothing behind")
    }

    func testAnExportWhoseConversationsAreAllEmptySaysSo() throws {
        try write("""
        [{"uuid":"c-2","name":"","created_at":"2026-03-02T10:00:00.000000Z",
          "chat_messages":[{"uuid":"m3","sender":"human","created_at":"2026-03-02T10:00:00.000000Z",
                            "text":"","content":[]}]}]
        """, to: "conversations.json")
        XCTAssertThrowsError(
            try ExportImporter(destination: root.appendingPathComponent("imports"))
                .importArchive(at: exportRoot.appendingPathComponent("conversations.json"))
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("message text"))
        }
    }
}
