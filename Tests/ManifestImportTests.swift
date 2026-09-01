import AppKit
import SwiftUI
import XCTest
@testable import Recall

/// The manifest flow. Every assertion here is about restraint: the links inside a
/// manifest work exactly once, and the failure mode observed in the field was
/// opening them in parallel — which cancelled the downloads in flight and burned
/// the links permanently.
final class ManifestParsingTests: XCTestCase {
    private let manifest = """
    {"instructions":"Download each file using the export_url. Note: Each export URL can only be used once.",
     "created_at":"2026-08-31T13:35:14.825208+00:00",
     "total_files":3,
     "data_files":[
       {"batch_index":2,"export_url":"https://claude.ai/export/abc/2","category":"conversations",
        "part":0,"filename":"conversations-000.zip"},
       {"batch_index":0,"export_url":"https://claude.ai/export/abc/0","category":"light_metadata",
        "part":0,"filename":"light_metadata-000.zip"},
       {"batch_index":1,"export_url":"https://claude.ai/export/abc/1","category":"conversations",
        "part":1,"filename":"conversations-001.zip"}],
     "version":"1.0"}
    """

    func testAManifestIsRecognizedByItsShape() throws {
        let parsed = try XCTUnwrap(ExportManifest.parse(Data(manifest.utf8)))
        XCTAssertEqual(parsed.version, "1.0")
        XCTAssertEqual(parsed.totalFiles, 3)
        // Sorted by batch_index: the order the server wants them fetched in.
        XCTAssertEqual(parsed.files.map(\.filename), [
            "light_metadata-000.zip", "conversations-001.zip", "conversations-000.zip",
        ])
        XCTAssertEqual(parsed.indexableCount, 2)
        XCTAssertFalse(parsed.files[0].isIndexable, "light_metadata is downloaded but never indexed")
        XCTAssertEqual(parsed.files[1].label, "Conversations · part 2")
    }

    func testAConversationsExportIsNotMistakenForAManifest() {
        let export = #"[{"uuid":"c-1","chat_messages":[]}]"#
        XCTAssertNil(ExportManifest.parse(Data(export.utf8)))
        XCTAssertNil(ExportManifest.parse(Data(#"{"version":"1.0"}"#.utf8)))
        XCTAssertNil(ExportManifest.parse(Data(#"{"data_files":[{"category":"x"}]}"#.utf8)))
    }

    /// The manifest decides what Recall hands to the browser, so a non-web scheme in
    /// it is dropped rather than opened.
    func testNonWebURLsAreDropped() {
        let hostile = """
        {"version":"1.0","data_files":[
          {"batch_index":0,"export_url":"file:///etc/passwd","category":"conversations",
           "part":0,"filename":"conversations-000.zip"}]}
        """
        XCTAssertNil(ExportManifest.parse(Data(hostile.utf8)))
    }

    /// A filename is used to watch the Downloads folder; a path in it would point the
    /// watcher somewhere else entirely.
    func testAPathInTheFilenameIsReducedToItsLastComponent() throws {
        let sneaky = """
        {"version":"1.0","data_files":[
          {"batch_index":0,"export_url":"https://claude.ai/export/a/0","category":"conversations",
           "part":0,"filename":"../../Library/conversations-000.zip"}]}
        """
        let parsed = try XCTUnwrap(ExportManifest.parse(Data(sneaky.utf8)))
        XCTAssertEqual(parsed.files[0].filename, "conversations-000.zip")
    }
}

final class DownloadWatcherTests: XCTestCase {
    private var downloads: URL!

    override func setUpWithError() throws {
        downloads = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: downloads)
    }

    private func watcher(timeout: TimeInterval = 4) -> DownloadWatcher {
        DownloadWatcher(directory: downloads, timeout: timeout, pollInterval: 0.05, settleChecks: 2)
    }

    private func write(_ name: String, bytes: Int) throws {
        try Data(repeating: 0x41, count: bytes).write(to: downloads.appendingPathComponent(name))
    }

    /// The whole contract: the file is only "landed" once it has stopped growing.
    func testWaitsUntilTheFileStopsGrowing() async throws {
        let started = Date()
        let writer = Task {
            try await Task.sleep(nanoseconds: 60_000_000)
            try write("conversations-000.zip", bytes: 1_000)
            try await Task.sleep(nanoseconds: 60_000_000)
            try write("conversations-000.zip", bytes: 40_000)
        }
        let landed = try await watcher().wait(for: "conversations-000.zip", startedAt: started)
        try await writer.value
        XCTAssertEqual(landed.lastPathComponent, "conversations-000.zip")
        let size = try XCTUnwrap((try landed.resourceValues(forKeys: [.fileSizeKey])).fileSize)
        XCTAssertEqual(size, 40_000, "a download that was still being written is not finished")
    }

    /// A `.crdownload` sibling means the browser is still writing, whatever the
    /// size of the file next to it says.
    func testAnInProgressSiblingHoldsTheWatcherBack() async throws {
        try write("conversations-000.zip", bytes: 1_000)
        try write("conversations-000.zip.crdownload", bytes: 10)
        let outcome = await Task {
            try await watcher(timeout: 0.3).wait(for: "conversations-000.zip", startedAt: Date())
        }.result
        switch outcome {
        case .success: XCTFail("a download in flight must not count as landed")
        case let .failure(error):
            XCTAssertTrue(error.localizedDescription.contains("never finished"))
            XCTAssertTrue(error.localizedDescription.contains("single-use"))
        }
    }

    /// An export sitting in Downloads from last week is not this download.
    func testAnOlderFileWithTheSameNameIsIgnored() async throws {
        try write("conversations-000.zip", bytes: 5_000)
        let old = downloads.appendingPathComponent("conversations-000.zip")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-86_400)], ofItemAtPath: old.path
        )
        let outcome = await Task {
            try await watcher(timeout: 0.3).wait(for: "conversations-000.zip", startedAt: Date())
        }.result
        switch outcome {
        case .success: XCTFail("last week's export is not this download")
        case let .failure(error):
            XCTAssertEqual(
                error as? DownloadWatchError,
                .timedOut(filename: "conversations-000.zip", appeared: false, waited: 0.3)
            )
        }
    }

    /// Browsers rename a download that collides with a file already there.
    func testABrowserRenamedCopyIsAccepted() async throws {
        XCTAssertTrue(DownloadWatcher.isRenamedCopy("conversations-000 (1)", of: "conversations-000"))
        XCTAssertTrue(DownloadWatcher.isRenamedCopy("conversations-000-2", of: "conversations-000"))
        XCTAssertFalse(DownloadWatcher.isRenamedCopy("conversations-001", of: "conversations-000"))

        try write("conversations-000 (1).zip", bytes: 2_000)
        let landed = try await watcher().wait(for: "conversations-000.zip", startedAt: Date())
        XCTAssertEqual(landed.lastPathComponent, "conversations-000 (1).zip")
    }
}

final class ManifestImporterTests: XCTestCase {
    private var root: URL!
    private var downloads: URL!
    /// Stands in for the browser: writes the zip the manifest asked for into the
    /// fake Downloads folder. Value type, so the run's opener closure can hold it.
    private var browser: FakeBrowser!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        downloads = root.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        browser = FakeBrowser(downloads: downloads, staging: root.appendingPathComponent("staging"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func manifest(_ entries: [(String, String)]) -> ExportManifest {
        ExportManifest(
            version: "1.0",
            createdAt: Date(),
            instructions: nil,
            totalFiles: entries.count,
            files: entries.enumerated().map { offset, entry in
                ExportManifest.DataFile(
                    batchIndex: offset,
                    exportURL: URL(string: "https://claude.ai/export/test/\(offset)")!,
                    category: entry.0,
                    part: 0,
                    filename: entry.1
                )
            }
        )
    }

    private var conversationsFixture: [String: String] {
        ["conversations.json": """
        [{"uuid":"c-1","name":"Manifest run","created_at":"2026-08-01T10:00:00.000000Z",
          "chat_messages":[{"uuid":"m1","sender":"human","created_at":"2026-08-01T10:00:00.000000Z",
                            "text":"downloaded via the manifest","content":[],"files":[],"attachments":[]}]}]
        """]
    }

    private func makeImporter(_ manifest: ExportManifest, opener: @escaping @Sendable (URL) -> Void) -> ManifestImporter {
        ManifestImporter(
            manifest: manifest,
            downloads: downloads,
            destination: root.appendingPathComponent("imports"),
            watcher: DownloadWatcher(directory: downloads, timeout: 3, pollInterval: 0.05, settleChecks: 2),
            opener: opener
        )
    }

    /// The rule that cost a set of links in testing: the next URL is not opened until
    /// the current file has fully landed.
    func testURLsAreOpenedStrictlyOneAtATime() async throws {
        let plan = manifest([
            ("conversations", "conversations-000.zip"),
            ("memories", "memories-000.zip"),
        ])
        let log = EventLog()
        let browser = browser!
        let fixture = conversationsFixture
        let memories = ["memories/acct-1.json": """
        {"conversations_memory":"Likes plain language.","memory_files":[],"account_uuid":"acct-1"}
        """]

        let importer = makeImporter(plan) { url in
            let index = url.lastPathComponent
            log.append("open \(index)")
            // Deliver the file the browser was asked for, a beat later.
            Task.detached {
                try? await Task.sleep(nanoseconds: 100_000_000)
                browser.deliver(
                    index == "0" ? "conversations-000.zip" : "memories-000.zip",
                    files: index == "0" ? fixture : memories
                )
            }
        }

        let summary = await importer.run { progress in
            if progress.state.isTerminal { log.append("\(progress.state.label) \(progress.file.filename)") }
        }

        XCTAssertEqual(summary.conversations, 1)
        XCTAssertEqual(summary.memories, 1)
        XCTAssertTrue(summary.failed.isEmpty)

        let entries = log.entries
        let secondOpen = try XCTUnwrap(entries.firstIndex(of: "open 1"))
        let firstImported = try XCTUnwrap(entries.firstIndex(of: "imported conversations-000.zip"))
        XCTAssertLessThan(firstImported, secondOpen,
                          "the second single-use link must not be opened until the first file is imported")
    }

    /// A file that never lands fails loudly, is never retried, and does not stop the
    /// entries after it from being attempted.
    func testATimeoutFailsWithTheBurnedLinkWarningAndIsNotRetried() async throws {
        let plan = manifest([
            ("conversations", "conversations-000.zip"),
            ("projects", "projects-000.zip"),
        ])
        let log = EventLog()
        let states = StateLog()
        let browser = browser!
        let importer = makeImporter(plan) { url in
            log.append(url.absoluteString)
            guard url.lastPathComponent == "1" else { return }
            browser.deliver("projects-000.zip", files: [
                "projects/p-1.json": """
                {"uuid":"p-1","name":"Late project","description":"Arrived anyway.",
                 "created_at":"2026-02-20T14:34:25.354388+00:00","docs":[]}
                """,
            ])
        }

        let summary = await importer.run { progress in states.record(progress) }

        XCTAssertEqual(summary.failed, ["conversations-000.zip"])
        let failure = try XCTUnwrap(states.state(of: "conversations-000.zip")?.detail)
        XCTAssertTrue(failure.contains("single-use"))
        XCTAssertTrue(failure.contains("new export"))
        XCTAssertEqual(summary.projects, 1, "a later entry still gets its turn")
        XCTAssertEqual(log.entries.count, 2, "each URL is opened exactly once — never retried")
    }

    /// The account-settings category is downloaded so the user keeps a complete
    /// export, then skipped rather than reported as an error.
    func testLightMetadataIsDownloadedAndSkipped() async throws {
        let plan = manifest([("light_metadata", "light_metadata-000.zip")])
        let states = StateLog()
        let browser = browser!
        let importer = makeImporter(plan) { _ in
            browser.deliver("light_metadata-000.zip", files: ["users.json": #"[{"uuid":"u1"}]"#])
        }
        let summary = await importer.run { progress in states.record(progress) }

        XCTAssertTrue(summary.failed.isEmpty)
        XCTAssertEqual(summary.skipped, ["light_metadata-000.zip"])
        XCTAssertEqual(states.state(of: "light_metadata-000.zip")?.label, "skipped")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: downloads.appendingPathComponent("light_metadata-000.zip").path),
            "the zip is the user's file and stays in Downloads"
        )
    }
}

/// The window's side of the manifest flow: dropping one must ask, never act.
@MainActor
final class ManifestConfirmationTests: XCTestCase {
    private let manifestJSON = """
    {"version":"1.0","total_files":2,"created_at":"2026-08-31T13:35:14.825208+00:00",
     "instructions":"Each export URL can only be used once.",
     "data_files":[
       {"batch_index":0,"export_url":"https://claude.ai/export/abc/0","category":"light_metadata",
        "part":0,"filename":"light_metadata-000.zip"},
       {"batch_index":1,"export_url":"https://claude.ai/export/abc/1","category":"conversations",
        "part":0,"filename":"conversations-000.zip"}]}
    """

    /// The one that matters: a manifest arriving by drop or picker opens a
    /// confirmation and opens no URL at all. These links work once.
    func testDroppingAManifestAsksBeforeOpeningAnything() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("manifest-abc.json")
        try Data(manifestJSON.utf8).write(to: file)

        let opened = EventLog()
        let store = RecallStore(
            indexURL: root.appendingPathComponent("index.db"),
            embedder: HashingEmbedder(dimensions: 64),
            importsDirectory: root.appendingPathComponent("imports"),
            downloadsDirectory: root.appendingPathComponent("Downloads")
        )
        store.showsDialogs = false
        store.openURL = { url in opened.append(url.absoluteString) }
        defer { ImportWindowController.shared.close() }

        XCTAssertNil(store.receive(file), "a manifest is not an import")
        XCTAssertEqual(store.pendingManifest?.files.count, 2)
        XCTAssertEqual(store.manifestProgress.map(\.state.label), ["waiting", "waiting"])
        XCTAssertTrue(opened.entries.isEmpty, "nothing may be opened before the user says yes")
        XCTAssertFalse(store.isImporting)
        XCTAssertNil(store.failure)

        // And the window actually shows it, rather than the drop zone.
        let view = NSHostingView(rootView: ImportView(store: store, onClose: {}))
        view.frame = NSRect(x: 0, y: 0, width: 460, height: 420)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 10_000, "the confirmation panel renders")
        try png.write(to: URL(fileURLWithPath: "/tmp/RecallManifestConfirm.png"))

        store.dismissManifest()
        XCTAssertNil(store.pendingManifest)
        XCTAssertTrue(opened.entries.isEmpty)
    }

    /// And a normal export is still just imported, with no confirmation in the way.
    func testANormalExportIsNotMistakenForAManifest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("conversations.json")
        try Data("""
        [{"uuid":"c-1","name":"Real export","created_at":"2026-08-19T10:00:00.000000Z",
          "chat_messages":[{"uuid":"m1","sender":"human","created_at":"2026-08-19T10:00:00.000000Z",
                            "text":"not a manifest","content":[],"files":[],"attachments":[]}]}]
        """.utf8).write(to: file)

        let store = RecallStore(
            indexURL: root.appendingPathComponent("index.db"),
            embedder: HashingEmbedder(dimensions: 64),
            importsDirectory: root.appendingPathComponent("imports"),
            downloadsDirectory: root.appendingPathComponent("Downloads")
        )
        store.showsDialogs = false
        XCTAssertNotNil(store.receive(file))
        XCTAssertNil(store.pendingManifest)
    }
}

/// Writes a category zip into a fake Downloads folder, as a browser would.
private struct FakeBrowser: Sendable {
    let downloads: URL
    let staging: URL

    func deliver(_ filename: String, files: [String: String]) {
        let box = staging.appendingPathComponent(UUID().uuidString)
        for (path, body) in files {
            let file = box.appendingPathComponent(path)
            try? FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? Data(body.utf8).write(to: file)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-q", "-r", downloads.appendingPathComponent(filename).path, "."]
        process.currentDirectoryURL = box
        try? process.run()
        process.waitUntilExit()
    }
}

/// A thread-safe ordering log; the point of these tests is what happened when.
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ entry: String) {
        lock.lock()
        storage.append(entry)
        lock.unlock()
    }

    var entries: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// The last state each manifest entry reached.
private final class StateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: ManifestFileState] = [:]

    func record(_ progress: ManifestFileProgress) {
        guard progress.state.isTerminal else { return }
        lock.lock()
        storage[progress.file.filename] = progress.state
        lock.unlock()
    }

    func state(of filename: String) -> ManifestFileState? {
        lock.lock()
        defer { lock.unlock() }
        return storage[filename]
    }
}
