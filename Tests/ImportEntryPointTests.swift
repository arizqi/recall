import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Recall

/// The import path is only useful if it can be found. These cover the two entry
/// points that do not require a modal: dropping a file, and the drop overlay that
/// tells you dropping is possible.
final class ImportEntryPointTests: XCTestCase {
    private let claudeExport = """
    [{"uuid":"conv-1","name":"Dropped session","created_at":"2026-08-19T10:00:00.000000Z",
      "chat_messages":[{"uuid":"m1","sender":"human","created_at":"2026-08-19T10:00:00.000000Z",
                        "text":"imported by drop","content":[],"files":[],"attachments":[]}]}]
    """

    /// Imports go to a temporary directory and dialogs are off: a test must never
    /// write into the real imports directory, which is exactly how nine fixture
    /// files once ended up in a real index.
    @MainActor
    private func makeStore(root: URL) -> RecallStore {
        let store = RecallStore(
            indexURL: root.appendingPathComponent("index.db"),
            embedder: HashingEmbedder(dimensions: 64),
            importsDirectory: root.appendingPathComponent("imports")
        )
        store.showsDialogs = false
        return store
    }

    @MainActor
    func testDroppingAFileURLStartsTheImport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let export = root.appendingPathComponent("conversations.json")
        try Data(claudeExport.utf8).write(to: export)

        let store = makeStore(root: root)
        // A provider carrying a file URL is accepted at all.
        let provider = NSItemProvider(contentsOf: export)!
        XCTAssertTrue(store.acceptDrop([provider]), "a file drop must be accepted")

        // And an export handed to the window starts an import: the spinner turns on
        // and the toast names the file straight away, rather than the window sitting
        // there looking like nothing happened.
        let task = store.receive(export)
        XCTAssertNotNil(task, "an export must be accepted")
        XCTAssertTrue(store.isImporting)
        XCTAssertTrue(store.status?.contains("conversations.json") == true)
        XCTAssertNil(store.failure)
        await task?.value
        XCTAssertEqual(store.lastImport?.conversations, 1)
        XCTAssertEqual(store.lastImport?.file?.deletingLastPathComponent().lastPathComponent, "imports")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("imports").path),
            "the import landed in the injected directory, not the real one"
        )
    }

    @MainActor
    func testDroppingSomethingThatIsNotAnExportExplainsItself() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let wrong = root.appendingPathComponent("holiday.png")
        try Data("x".utf8).write(to: wrong)

        let store = makeStore(root: root)
        XCTAssertNil(store.receive(wrong), "a screenshot is not an export")
        XCTAssertTrue(store.failure?.contains("holiday.png") == true)
        XCTAssertFalse(store.isImporting)
    }

    @MainActor
    func testDropOverlayRendersWhenAFileIsHovering() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let store = makeStore(root: root)
        let idle = try render(store)
        store.isDropTargeted = true
        let hovering = try render(store)

        XCTAssertNotEqual(idle, hovering, "the window must visibly say it accepts the drop")
        try hovering.write(to: URL(fileURLWithPath: "/tmp/RecallDropTarget.png"))
    }

    @MainActor
    private func render(_ store: RecallStore) throws -> Data {
        let view = NSHostingView(rootView: SearchView(store: store))
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 720)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

}
