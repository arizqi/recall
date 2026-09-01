import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A real, standalone window for importing an export.
///
/// The bug this exists to fix: Recall's main UI is a `MenuBarExtra(.window)`, which
/// is an `NSPopover`. A popover dismisses the instant focus leaves it, so opening an
/// `NSOpenPanel` from inside it tore down the popover — and with it the panel's
/// presenting context — leaving the picker lost behind everything or gone entirely.
///
/// A genuine `NSWindow` does not auto-dismiss on focus loss, so both the file picker
/// (presented as a sheet on this window) and drag-and-drop work normally. The Import
/// controls in the popover open this window instead of acting inside the popover.
@MainActor
final class ImportWindowController {
    static let shared = ImportWindowController()

    private var window: NSWindow?

    func present(store: RecallStore) {
        // A menu-bar-only app (`LSUIElement`) cannot reliably bring a window to the
        // front without briefly becoming a regular app; restore accessory afterwards
        // so no Dock icon lingers.
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)

        if let window {
            window.makeKeyAndOrderFront(nil)
            window.center()
            return
        }

        let view = ImportView(store: store) { [weak self] in self?.close() }
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Import export"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 460, height: 420))
        window.isReleasedWhenClosed = false
        window.center()
        window.level = .normal
        window.delegate = ImportWindowController.delegate
        ImportWindowController.delegate.onClose = { [weak self] in self?.window = nil; self?.restorePolicy() }
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
        window = nil
        restorePolicy()
    }

    private func restorePolicy() {
        // Back to menu-bar-only once no window needs the Dock/menu bar.
        if NSApp.windows.allSatisfy({ !$0.isVisible || $0 === NSApp.keyWindow && window == nil }) {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private static let delegate = ImportWindowDelegate()
}

private final class ImportWindowDelegate: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?
    func windowWillClose(_ notification: Notification) { onClose?() }
}

/// Presents `NSOpenPanel` as a sheet on a given window. A sheet is owned by its
/// window and cannot slip behind it, which is the whole point.
enum ImportPanel {
    static func presentSheet(on window: NSWindow?, completion: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Import a ChatGPT or claude.ai export"
        panel.prompt = "Import"
        panel.message = "Choose an export .zip, a conversations.json, a download manifest, "
            + "or the folder holding the category zips"
        panel.allowedContentTypes = [.zip, .json]
        // claude.ai now ships one zip per category, and splits big categories into
        // numbered parts — so several files, or the folder holding them, is normal.
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true

        if let window {
            panel.beginSheetModal(for: window) { response in
                completion(response == .OK ? panel.urls : [])
            }
        } else {
            // No host window (e.g. the very first click): make the panel itself the
            // key, floating, app-modal window so it comes to front and stays.
            NSApp.activate(ignoringOtherApps: true)
            panel.level = .modalPanel
            panel.makeKeyAndOrderFront(nil)
            completion(panel.runModal() == .OK ? panel.urls : [])
        }
    }
}
