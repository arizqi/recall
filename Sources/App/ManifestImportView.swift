import AppKit
import SwiftUI

/// The confirmation and progress panel for a claude.ai download manifest.
///
/// It exists because the links inside a manifest are single-use and slow: opening one
/// is irreversible, and opening the next one too early kills the download in flight.
/// So the panel says exactly what it is about to do, does nothing until the button is
/// pressed, and then shows one row per file so an interrupted run is legible rather
/// than mysterious.
struct ManifestImportView: View {
    @ObservedObject var store: RecallStore
    let manifest: ExportManifest
    /// Closes the host window once the run is over, so "Done" means done.
    var onClose: () -> Void = {}
    private let accent = Color(red: 0.30, green: 0.45, blue: 0.85)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            fileList
            if let summary = store.manifestSummary {
                summaryBox(summary)
            } else {
                explanation
            }
            Spacer(minLength: 0)
            buttons
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Claude export manifest — \(manifest.files.count) file\(manifest.files.count == 1 ? "" : "s")")
                .font(.headline)
            Text(store.isRunningManifest
                ? "Downloading one at a time. Leave this window open."
                : "Download via your default browser?")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var fileList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(store.manifestProgress) { row in
                    ManifestRowView(row: row, accent: accent)
                    if row.id != store.manifestProgress.last?.id { Divider() }
                }
            }
        }
        .frame(maxHeight: 190)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor).opacity(0.6)))
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                "Each link works once. Recall opens them one at a time in your browser "
                    + "and waits for each file to finish before opening the next.",
                systemImage: "link"
            )
            Label(
                "Your browser holds the claude.ai session — Recall never sees your login. "
                    + "The zips stay in \(store.downloadsDirectory.lastPathComponent).",
                systemImage: "lock"
            )
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func summaryBox(_ summary: ManifestRunSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(summary.headline, systemImage: summary.failed.isEmpty
                ? "checkmark.circle.fill"
                : "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(summary.failed.isEmpty ? Color.green : Color.orange)
            Text(summary.detail).font(.caption).foregroundStyle(.secondary)
            if !summary.failed.isEmpty {
                Text("Failed links are single-use and may now be burned. "
                    + "Request a new export from claude.ai rather than retrying them.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if store.isIndexing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Indexing…").font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill((summary.failed.isEmpty ? Color.green : Color.orange).opacity(0.08)))
    }

    private var buttons: some View {
        HStack {
            if store.isRunningManifest {
                ProgressView().controlSize(.small)
                Text("Waiting for the current download…").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Stop") { store.stopManifestDownloads() }
            } else {
                Spacer()
                Button("Cancel") { store.dismissManifest() }
                    .keyboardShortcut(.cancelAction)
                Button(store.manifestSummary == nil
                    ? "Download \(manifest.files.count) file\(manifest.files.count == 1 ? "" : "s")"
                    : "Done") {
                    if store.manifestSummary == nil {
                        store.startManifestDownloads()
                    } else {
                        store.dismissManifest()
                        onClose()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// One manifest entry: what it is, and where it got to.
struct ManifestRowView: View {
    let row: ManifestFileProgress
    let accent: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon.frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.file.filename).font(.callout.monospaced())
                if let detail = row.state.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(row.file.label).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Text(row.state.label).font(.caption2).foregroundStyle(tint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var icon: some View {
        switch row.state {
        case .waiting: Image(systemName: "clock").foregroundStyle(.tertiary)
        case .downloading: ProgressView().controlSize(.small)
        case .imported: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private var tint: Color {
        switch row.state {
        case .waiting, .skipped: .secondary
        case .downloading: accent
        case .imported: .green
        case .failed: .orange
        }
    }
}
