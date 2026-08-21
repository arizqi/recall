import AppKit
import SwiftUI
import XCTest
@testable import Recall

/// The fix for the vanishing picker is structural: Import must run from a real
/// window, not the menu-bar popover, and the panel must be a sheet on that window.
/// These assert the wiring that guarantees it, since the panel itself can't be
/// driven headlessly.
@MainActor
final class ImportWindowTests: XCTestCase {
    private func makeStore() -> RecallStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = RecallStore(
            indexURL: root.appendingPathComponent("index.db"),
            embedder: HashingEmbedder(dimensions: 64),
            importsDirectory: root.appendingPathComponent("imports")
        )
        store.showsDialogs = false
        return store
    }

    func testOpenImportWindowCreatesARealTitledWindow() {
        let store = makeStore()
        XCTAssertFalse(hasImportWindow, "no import window before the button is pressed")

        store.openImportWindow()
        defer { ImportWindowController.shared.close() }

        let window = try? XCTUnwrap(importWindow)
        XCTAssertNotNil(window)
        // A real window, not a popover: titled and not auto-dismissing on focus loss.
        XCTAssertTrue(window?.styleMask.contains(.titled) == true)
        XCTAssertTrue(window?.styleMask.contains(.closable) == true)
        XCTAssertFalse(window?.isReleasedWhenClosed == true)
        XCTAssertEqual(window?.title, "Import export")
    }

    func testTheAppBecomesRegularWhileTheWindowIsOpenSoItComesToFront() {
        let store = makeStore()
        NSApp.setActivationPolicy(.accessory)
        store.openImportWindow()
        defer {
            ImportWindowController.shared.close()
            NSApp.setActivationPolicy(.accessory)
        }
        // A menu-bar-only app cannot front a window while it stays .accessory.
        XCTAssertEqual(NSApp.activationPolicy(), .regular)
    }

    func testClosingTheWindowTearsItDown() {
        let store = makeStore()
        store.openImportWindow()
        XCTAssertTrue(hasImportWindow)
        ImportWindowController.shared.close()
        XCTAssertFalse(hasImportWindow)
    }

    func testImportViewHostsADropTargetAndAChooseButton() throws {
        let store = makeStore()
        let view = ImportView(store: store, onClose: {})
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: 460, height: 420)
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 10_000, "the import window renders its drop zone")
        try png.write(to: URL(fileURLWithPath: "/tmp/RecallImportWindow.png"))
    }

    // MARK: -

    // The window is not released when closed, so it lingers in NSApp.windows after
    // close; visibility is what "open" means.
    private var hasImportWindow: Bool { importWindow != nil }
    private var importWindow: NSWindow? {
        NSApp.windows.first { $0.title == "Import export" && $0.isVisible }
    }
}
