import XCTest
@testable import Recall

/// claude.ai's 2026-08 export shape: one zip per category rather than one zip for
/// everything, and each category split into numbered parts on a big account.
/// Fixtures mirror the real layouts (verified against a live export) with invented
/// content — no real user data lives in this repo.
final class CategoryExportTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Builds one category zip exactly as claude.ai ships it: the category's own
    /// files at the root of the archive, nothing else.
    @discardableResult
    private func makeCategoryZip(_ name: String, files: [String: String]) throws -> URL {
        let staging = root.appendingPathComponent("staging-\(name)-\(UUID().uuidString)")
        for (path, body) in files {
            let file = staging.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(body.utf8).write(to: file)
        }
        let zip = root.appendingPathComponent(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-r", zip.path, "."]
        process.currentDirectoryURL = staging
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return zip
    }

    private func conversationsJSON(uuid: String, name: String, updated: String, text: String) -> String {
        """
        [{"uuid":"\(uuid)","name":"\(name)","created_at":"2026-08-01T10:00:00.000000Z",
          "updated_at":"\(updated)",
          "chat_messages":[{"uuid":"m-\(uuid)","sender":"human",
                            "created_at":"2026-08-01T10:00:00.000000Z",
                            "text":"\(text)","content":[],"files":[],"attachments":[]}]}]
        """
    }

    private var memoriesJSON: String {
        """
        {"conversations_memory":"Prefers short answers and hates filler words.",
         "memory_files":[
           {"path":"/topics/tooling.md","content":"Uses a Mac and a local vector index.",
            "updated_at":"2026-08-10T09:00:00.000000+00:00"},
           {"path":"/profile.md","content":"Builds developer tools.",
            "updated_at":"2026-08-11T09:00:00.000000+00:00"}],
         "account_uuid":"acct-1"}
        """
    }

    // MARK: - One zip per category

    /// The bug this guards: `projects-000.zip` unpacks to a single `projects/`
    /// directory, which the old "the export is nested one level down" heuristic
    /// mistook for a wrapper folder and descended into, finding nothing.
    func testAProjectsOnlyZipIsRead() throws {
        let zip = try makeCategoryZip("projects-000.zip", files: [
            "projects/p-1.json": """
            {"uuid":"p-1","name":"Recall","description":"Local search over chat history.",
             "prompt_template":"Answer with file paths.",
             "created_at":"2026-02-20T14:34:25.354388+00:00",
             "docs":[{"uuid":"d1","filename":"notes.md","content":"Brute force cosine is fine.",
                      "created_at":"2026-02-20T14:34:25.354388+00:00"}]}
            """,
        ])
        let result = try ExportImporter(destination: root.appendingPathComponent("imports"))
            .importArchive(at: zip)
        XCTAssertEqual(result.kind, .claudeAI)
        XCTAssertEqual(result.conversations, 1)
        XCTAssertEqual(result.breakdown[ExportPart.projectDocs], 1)
        XCTAssertEqual(result.events, 3, "description, instructions, one doc")
    }

    func testAMemoriesZipBecomesSearchableBusEvents() throws {
        let zip = try makeCategoryZip("memories-000.zip", files: ["memories/acct-1.json": memoriesJSON])
        let destination = root.appendingPathComponent("imports")
        let result = try ExportImporter(destination: destination).importArchive(at: zip)
        XCTAssertEqual(result.kind, .claudeAI)
        XCTAssertEqual(result.breakdown[ExportPart.memories], 1)

        let events = NormalizedJSONLSource(id: RecallSource.imports, root: destination)
            .events(in: try XCTUnwrap(result.file))
        XCTAssertEqual(events.count, 3, "the narrative memory plus one event per memory file")
        XCTAssertTrue(events.allSatisfy { $0.conversationId == "claude-ai:memory:acct-1" })
        XCTAssertTrue(events.allSatisfy { $0.title == "Memory — claude.ai" })
        XCTAssertTrue(events[0].text.contains("hates filler words"))
        // The memory file's own path is its evidence, exactly like a project doc's
        // filename, so "which note said that" is answerable.
        XCTAssertTrue(events.contains { $0.artifactPaths == ["/topics/tooling.md"] })
        XCTAssertTrue(events.contains { $0.text.contains("local vector index") })
    }

    func testAConversationsZipStillParsesTheFamiliarSchema() throws {
        let zip = try makeCategoryZip("conversations-000.zip", files: [
            "conversations.json": conversationsJSON(
                uuid: "c-1", name: "Ranking", updated: "2026-08-02T10:00:00.000000Z", text: "how do I rank hits"
            ),
        ])
        let result = try ExportImporter(destination: root.appendingPathComponent("imports"))
            .importArchive(at: zip)
        XCTAssertEqual(result.conversations, 1)
        XCTAssertEqual(result.breakdown[ExportPart.conversations], 1)
    }

    /// light_metadata is a real part of the export with nothing in it to index.
    /// Importing it must be a calm no-op, not an "unrecognized format" error the
    /// user has to dismiss — the manifest flow imports all five categories blind.
    func testALightMetadataZipIsRecognizedAndSkippedWithoutError() throws {
        let zip = try makeCategoryZip("light_metadata-000.zip", files: [
            "users.json": #"[{"uuid":"u1","email_address":"someone@example.com"}]"#,
            "login_history.json": #"[{"ip":"127.0.0.1"}]"#,
        ])
        let destination = root.appendingPathComponent("imports")
        let result = try ExportImporter(destination: destination).importArchive(at: zip)

        XCTAssertTrue(result.isMetadataOnly)
        XCTAssertEqual(result.conversations, 0)
        XCTAssertNil(result.file, "nothing indexable means nothing written")
        XCTAssertEqual(result.skippedCategories, [ExportPart.accountMetadata])
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path),
                       "a skipped category leaves no ghost file behind")
    }

    // MARK: - Several categories, several parts

    func testAllFiveCategoryZipsImportAsOneExport() throws {
        let zips = [
            try makeCategoryZip("conversations-000.zip", files: [
                "conversations.json": conversationsJSON(
                    uuid: "c-1", name: "Ranking", updated: "2026-08-02T10:00:00.000000Z", text: "how do I rank hits"
                ),
            ]),
            try makeCategoryZip("design_chats-000.zip", files: [
                "design_chats/d-1.json": """
                {"uuid":"d-1","title":"Chat","project":{"uuid":"p-9","name":"lamp app"},
                 "created_at":"2026-04-24T00:33:00.000000+00:00",
                 "messages":[{"uuid":"dm1","role":"user","created_at":"2026-04-24T00:33:18.808357+00:00",
                              "content":{"role":"user","content":"Design a lamp configurator."}}]}
                """,
            ]),
            try makeCategoryZip("projects-000.zip", files: [
                "projects/p-1.json": """
                {"uuid":"p-1","name":"Recall","description":"Local search.",
                 "created_at":"2026-02-20T14:34:25.354388+00:00","docs":[]}
                """,
            ]),
            try makeCategoryZip("memories-000.zip", files: ["memories/acct-1.json": memoriesJSON]),
            try makeCategoryZip("light_metadata-000.zip", files: ["users.json": #"[{"uuid":"u1"}]"#]),
        ]

        let result = try ExportImporter(destination: root.appendingPathComponent("imports"))
            .importArchives(at: zips)
        XCTAssertEqual(result.conversations, 4, "light_metadata contributes nothing")
        XCTAssertEqual(result.inputs, 5)
        XCTAssertEqual(result.breakdown[ExportPart.conversations], 1)
        XCTAssertEqual(result.breakdown[ExportPart.designChats], 1)
        XCTAssertEqual(result.breakdown[ExportPart.projectDocs], 1)
        XCTAssertEqual(result.breakdown[ExportPart.memories], 1)
        XCTAssertEqual(result.skippedCategories, [ExportPart.accountMetadata])
    }

    /// A big account splits one category across parts, and the parts overlap. The
    /// same conversation must land once — the copy the export says is newer.
    func testOverlappingPartsOfACategoryAreMergedNewestWins() throws {
        let older = try makeCategoryZip("conversations-000.zip", files: [
            "conversations.json": conversationsJSON(
                uuid: "c-1", name: "Ranking", updated: "2026-08-02T10:00:00.000000Z", text: "first draft"
            ),
        ])
        let newer = try makeCategoryZip("conversations-001.zip", files: [
            "conversations.json": """
            [\(conversationsJSON(
                uuid: "c-1", name: "Ranking", updated: "2026-08-09T10:00:00.000000Z", text: "revised answer"
            ).dropFirst().dropLast()),
             \(conversationsJSON(
                uuid: "c-2", name: "Chunking", updated: "2026-08-09T11:00:00.000000Z", text: "only in part two"
            ).dropFirst().dropLast())]
            """,
        ])

        let destination = root.appendingPathComponent("imports")
        let result = try ExportImporter(destination: destination).importArchives(at: [older, newer])
        XCTAssertEqual(result.conversations, 2, "c-1 appears in both parts and lands once")

        let events = NormalizedJSONLSource(id: RecallSource.imports, root: destination)
            .events(in: try XCTUnwrap(result.file))
        let texts = Set(events.map(\.text))
        XCTAssertTrue(texts.contains("revised answer"), "the newer updated_at wins")
        XCTAssertFalse(texts.contains("first draft"))
        XCTAssertTrue(texts.contains("only in part two"))
    }

    /// Dropping the Downloads folder full of category zips has to behave the same as
    /// selecting them one by one — including ignoring the manifest sitting next to
    /// them, which is a plan for downloads, not data.
    func testAFolderOfCategoryZipsImportsAsOneExportAndIgnoresTheManifest() throws {
        let folder = root.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let conversations = try makeCategoryZip("conversations-000.zip", files: [
            "conversations.json": conversationsJSON(
                uuid: "c-1", name: "Ranking", updated: "2026-08-02T10:00:00.000000Z", text: "how do I rank hits"
            ),
        ])
        let memories = try makeCategoryZip("memories-000.zip", files: ["memories/acct-1.json": memoriesJSON])
        for zip in [conversations, memories] {
            try FileManager.default.moveItem(at: zip, to: folder.appendingPathComponent(zip.lastPathComponent))
        }
        try Data("""
        {"version":"1.0","total_files":2,"data_files":[
          {"batch_index":0,"export_url":"https://claude.ai/export/x/0","category":"conversations",
           "part":0,"filename":"conversations-000.zip"}]}
        """.utf8).write(to: folder.appendingPathComponent("manifest-abc.json"))

        let result = try ExportImporter(destination: root.appendingPathComponent("imports"))
            .importArchive(at: folder)
        XCTAssertEqual(result.inputs, 2, "the manifest is not an export")
        XCTAssertEqual(result.conversations, 2)
    }

    // MARK: - Legacy shapes still work

    func testTheLegacySingleProjectsJSONIsStillRead() throws {
        let export = root.appendingPathComponent("export")
        try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        try Data("""
        [{"uuid":"p-1","name":"Older export","description":"All projects in one array.",
          "created_at":"2026-02-20T14:34:25.354388+00:00","docs":[]}]
        """.utf8).write(to: export.appendingPathComponent("projects.json"))

        let parsed = ExportImporter.parseDirectory(export)
        XCTAssertEqual(parsed.kind, .claudeAI)
        XCTAssertEqual(parsed.breakdown[ExportPart.projectDocs], 1)
        XCTAssertEqual(parsed.events.first?.conversationId, "claude-ai:project:p-1")
    }

    /// The old single-zip export nested everything inside one wrapper directory; the
    /// fix for category zips must not have broken that.
    func testAWrapperDirectoryIsStillFollowed() throws {
        let inner = root.appendingPathComponent("staging/data-2026-08-01")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data(conversationsJSON(
            uuid: "c-1", name: "Wrapped", updated: "2026-08-02T10:00:00.000000Z", text: "still found"
        ).utf8).write(to: inner.appendingPathComponent("conversations.json"))

        let parsed = ExportImporter.parseDirectory(root.appendingPathComponent("staging"))
        XCTAssertEqual(parsed.events.first?.text, "still found")
    }
}
