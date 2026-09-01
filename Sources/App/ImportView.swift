import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The contents of the standalone Import window: a drop zone, a Choose file button,
/// and live progress. Because this lives in a real window rather than the menu-bar
/// popover, dropping a file and opening the picker both behave normally.
struct ImportView: View {
    @ObservedObject var store: RecallStore
    let onClose: () -> Void
    @State private var isTargeted = false
    private let accent = Color(red: 0.30, green: 0.45, blue: 0.85)

    var body: some View {
        VStack(spacing: 16) {
            // A dropped manifest takes the window over: it needs a yes/no, and the
            // drop zone would only invite a second irreversible action.
            if let manifest = store.pendingManifest {
                ManifestImportView(store: store, manifest: manifest, onClose: onClose)
            } else {
                header
                dropZone
                if let result = store.lastImport {
                    importedSummary(result)
                } else if store.isImporting {
                    progress
                } else if let failure = store.failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer()
                footer
            }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("Import export").font(.title2.weight(.semibold))
            Text("ChatGPT or claude.ai account export — the category zips, a download "
                + "manifest, a bare conversations.json, or the folder holding them")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isTargeted ? accent.opacity(0.12) : Color(nsColor: .controlBackgroundColor).opacity(0.5))
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isTargeted ? accent : Color.secondary.opacity(0.35),
                              style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(accent)
                Text("Drop the export here")
                    .font(.headline)
                Button {
                    store.chooseExportSheet(on: importWindow)
                } label: {
                    Label("Choose file…", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isImporting)
            }
        }
        .frame(height: 200)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            store.acceptDrop(providers)
        }
    }

    private var progress: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(store.status ?? "Importing…").font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func importedSummary(_ result: ExportImporter.Result) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // An account-metadata-only zip is a recognized part of the export with
            // nothing in it to index — reported, not celebrated and not an error.
            Label(result.headline, systemImage: result.isMetadataOnly ? "minus.circle" : "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(result.isMetadataOnly ? Color.secondary : Color.green)
            Text(result.detail).font(.caption).foregroundStyle(.secondary)
            HStack {
                if let file = result.file {
                    Button("Show imported") {
                        NSWorkspace.shared.activateFileViewerSelecting([file])
                    }
                }
                if store.isIndexing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Indexing…").font(.caption)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.08)))
    }

    private var footer: some View {
        HStack {
            Text("Everything stays on this Mac.").font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            Button("Done") { onClose() }.keyboardShortcut(.defaultAction)
        }
    }

    /// The hosting window, so the open panel can be a sheet on this exact window.
    private var importWindow: NSWindow? {
        NSApp.windows.first { $0.title == "Import export" && $0.isVisible }
    }
}
