import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SearchView: View {
    @StateObject private var store: RecallStore
    private let accent = Color(red: 0.30, green: 0.45, blue: 0.85)

    @MainActor
    init() {
        _store = StateObject(wrappedValue: RecallStore())
    }

    @MainActor
    init(store: RecallStore) {
        _store = StateObject(wrappedValue: store)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.selected != nil {
                detail
            } else {
                resultsList
            }
            Divider()
            footer
        }
        .frame(width: 700, height: 720)
        .background(background)
        .tint(accent)
        // The whole window is the drop target: a small hidden one may as well not
        // exist in a menu-bar app you can only see for a moment.
        .onDrop(of: [.fileURL], isTargeted: dropBinding) { providers in
            store.acceptDrop(providers)
        }
        .overlay { if store.isDropTargeted { dropOverlay } }
    }

    private var dropBinding: Binding<Bool> {
        Binding(get: { store.isDropTargeted }, set: { store.isDropTargeted = $0 })
    }

    private var dropOverlay: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).opacity(0.92)
            VStack(spacing: 12) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(accent)
                Text("Drop claude.ai / ChatGPT export here")
                    .font(.title3.weight(.semibold))
                Text("A .zip account export, or a bare conversations.json")
                    .font(.caption).foregroundStyle(.secondary)
            }
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(accent, style: StrokeStyle(lineWidth: 3, dash: [9, 6]))
                .padding(10)
        }
        .ignoresSafeArea()
    }

    private var background: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [accent.opacity(0.06), .clear, Color.purple.opacity(0.03)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous).fill(accent.gradient)
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Recall").font(.headline)
                    Text(indexCaption).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { store.openImportWindow() } label: {
                    if store.isImporting {
                        Label("Importing…", systemImage: "hourglass")
                    } else {
                        Label("Import export ZIP…", systemImage: "arrow.down.doc")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(store.isImporting)
                .help("Import a ChatGPT or claude.ai account export")
                if store.isIndexing {
                    Button("Stop") { store.cancelIndexing() }
                        .buttonStyle(.bordered)
                } else {
                    Button {
                        store.index()
                    } label: {
                        Label("Index", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.bordered)
                }
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search everything you have ever discussed…", text: $store.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .onSubmit { store.search() }
                if store.isSearching { ProgressView().controlSize(.small) }
                if !store.query.isEmpty {
                    Button {
                        store.query = ""
                        store.search()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))

            sourceChips
            controls
        }
        .padding(16)
    }

    /// Sort and date live next to each other because they answer the same question:
    /// "which slice of history am I looking at, and in what order".
    private var controls: some View {
        HStack(spacing: 10) {
            Picker("", selection: sortBinding) {
                ForEach(SearchSort.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 170)

            Picker("", selection: dateBinding) {
                ForEach(DateWindow.Preset.allCases) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }
            .labelsHidden()
            .frame(width: 150)

            Spacer()
            if store.query.isEmpty {
                Text("Recent conversations").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var sortBinding: Binding<SearchSort> {
        Binding(get: { store.sort }, set: { store.sort = $0; store.search() })
    }

    private var dateBinding: Binding<DateWindow.Preset> {
        Binding(get: { store.datePreset }, set: {
            store.datePreset = $0
            store.refreshRecent()
            store.search()
        })
    }

    private var sourceChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip(label: "All", source: nil, count: store.stats?.chunks ?? 0)
                ForEach(store.stats?.sources ?? []) { status in
                    chip(label: RecallSource.label(status.source), source: status.source, count: status.chunks)
                }
            }
        }
        .frame(height: 26)
    }

    private func chip(label: String, source: String?, count: Int) -> some View {
        let isSelected = store.sourceFilter == source
        return Button {
            store.sourceFilter = source
            store.refreshRecent()
            store.search()
        } label: {
            Text("\(label) \(count)")
                .font(.caption)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(isSelected ? accent.opacity(0.9) : Color.secondary.opacity(0.12))
                )
                .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private var indexCaption: String {
        if store.isIndexing { return store.indexProgress ?? "Indexing…" }
        guard let stats = store.stats, stats.chunks > 0 else { return "No index yet — press Index" }
        return "\(stats.conversations) conversations · \(stats.chunks) chunks · "
            + String(format: "%.0f MB", Double(stats.bytes) / 1_048_576)
    }

    // MARK: - Results

    private var resultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let failure = store.failure { banner(failure, systemImage: "exclamationmark.triangle.fill") }
                ForEach(store.coverage) { coverage in
                    banner(coverage.detail, systemImage: "cloud.fill")
                }
                if store.query.isEmpty {
                    if store.recent.isEmpty { emptyState }
                    ForEach(store.recent) { record in
                        recentRow(record)
                    }
                } else {
                    if store.results.isEmpty { emptyState }
                    ForEach(store.results) { group in
                        resultRow(group)
                    }
                }
            }
            .padding(16)
        }
    }

    private func resultRow(_ group: ConversationHits) -> some View {
        Button { store.open(group) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(RecallSource.label(group.source))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(accent.opacity(0.15)))
                    Text(group.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Text(DateFormatter.minute.string(from: group.date))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text(RecallText.clipped(group.best.chunk.text, length: 260))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 10) {
                    Label("\(group.hits.count)", systemImage: "text.alignleft")
                    Label(group.best.matchKind, systemImage: "sparkle.magnifyingglass")
                    Text(String(format: "score %.3f", group.score))
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.7)))
        }
        .buttonStyle(.plain)
    }

    /// The browse list: newest first, no query needed.
    private func recentRow(_ record: ConversationRecord) -> some View {
        Button { store.openRecent(record) } label: {
            HStack(spacing: 8) {
                Text(RecallSource.label(record.source))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(accent.opacity(0.15)))
                Text(record.title).font(.system(size: 12.5)).lineLimit(1)
                Spacer()
                Text(DateFormatter.minute.string(from: record.endedAt))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6)))
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: store.query.isEmpty ? "magnifyingglass" : "questionmark.folder")
                .font(.system(size: 26)).foregroundStyle(.tertiary)
            Text(store.query.isEmpty ? "Search your Claude Code, Cowork, Room, inbox and imported history."
                                     : "No matches for “\(store.query)”.")
                .font(.callout).foregroundStyle(.secondary)
            if !store.missingSources.isEmpty {
                Text("Not on this Mac: " + store.missingSources.joined(separator: ", "))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Button { store.openImportWindow() } label: {
                Label("Import export ZIP…", systemImage: "arrow.down.doc")
            }
            .buttonStyle(.borderedProminent)
            Text("…or drop a ChatGPT / claude.ai export anywhere in this window.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let transcript = store.transcript, let group = store.selected {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Button { store.closeDetail() } label: { Label("Results", systemImage: "chevron.left") }
                            .buttonStyle(.plain)
                        Spacer()
                        Text(RecallSource.label(group.source)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(transcript.conversation.title).font(.title3.weight(.semibold))
                    Text("\(DateFormatter.minute.string(from: transcript.conversation.startedAt)) · "
                        + "\(transcript.messageCount) messages · \(transcript.conversation.filePath)")
                        .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)

                    if transcript.reconstructed {
                        banner("Source file is gone — this text was rebuilt from the index.",
                               systemImage: "clock.badge.exclamationmark")
                    }

                    HStack(spacing: 8) {
                        Button { store.copySelection() } label: {
                            if store.isExporting {
                                Label("Building bundle…", systemImage: "hourglass")
                            } else {
                                Label("Copy bundle", systemImage: "doc.on.doc")
                            }
                        }
                        .disabled(store.isExporting)
                        Button { store.summarize() } label: {
                            if store.summarizingIDs.contains(transcript.conversation.id) {
                                Label("Summarizing…", systemImage: "hourglass")
                            } else {
                                Label("Local summary", systemImage: "sparkles")
                            }
                        }
                        .disabled(store.summarizingIDs.contains(transcript.conversation.id))
                        Button { store.saveSelection() } label: { Label("Save…", systemImage: "square.and.arrow.down") }
                    }
                    .buttonStyle(.bordered)

                    if let summary = store.summaries[transcript.conversation.id] {
                        Text(summary.markdown)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 8).fill(accent.opacity(0.07)))
                    }

                    artifacts(for: transcript)

                    if !group.hits.isEmpty {
                        Text("Matched fragments").font(.subheadline.weight(.semibold))
                    }
                    ForEach(group.hits.prefix(5)) { hit in
                        Text(RecallText.clipped(hit.chunk.text, length: 600))
                            .font(.system(size: 11.5, design: .monospaced))
                            .padding(9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.09)))
                    }

                    HStack {
                        Text("Transcript").font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(store.rows.count) blocks").font(.caption2).foregroundStyle(.tertiary)
                    }
                    // One Text per row, lazily. A single Text holding the whole
                    // conversation typesets eagerly through CoreText and hangs the
                    // main thread for minutes on a large session.
                    ForEach(store.rows) { row in
                        transcriptRow(row)
                    }
                }
                .padding(16)
            }
        }
    }

    private func transcriptRow(_ row: TranscriptRow) -> some View {
        let expanded = store.expandedRowIDs.contains(row.id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(row.continuation ? "\(row.role.transcriptLabel) (cont.)" : row.role.transcriptLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(row.role == .user ? accent : Color.secondary)
                Text(DateFormatter.minute.string(from: row.ts))
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
            }
            Text(row.displayText(expanded: expanded))
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if row.isTruncated {
                Button(expanded ? "Show less" : row.truncationLabel) {
                    store.toggleExpansion(row)
                }
                .buttonStyle(.link)
                .font(.caption2)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func artifacts(for transcript: Transcript) -> some View {
        let artifacts = transcript.artifacts
        if !artifacts.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Artifacts").font(.subheadline.weight(.semibold))
                ForEach(artifacts.prefix(25), id: \.path) { artifact in
                    HStack(spacing: 6) {
                        Image(systemName: artifact.exists ? "doc.text.fill" : "doc.badge.ellipsis")
                            .foregroundStyle(artifact.exists ? accent : Color.secondary)
                        Text(artifact.path).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                        if artifact.exists {
                            Button("Reveal") { store.reveal(artifact.path) }
                                .buttonStyle(.link).font(.caption2)
                        } else {
                            Text("missing").font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if let status = store.status {
                Label(status, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(accent)
            } else if let report = store.indexReport {
                Text(report).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            } else if let milliseconds = store.lastSearchMilliseconds {
                Text("\(store.results.count) conversations · \(milliseconds)ms · \(store.searchMode)")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Local index · no cloud calls").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button { store.openImportWindow() } label: {
                Label("Import…", systemImage: "arrow.down.doc")
            }
            .buttonStyle(.bordered)
            .disabled(store.isImporting)
            Button { store.copySelection() } label: {
                if store.isExporting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Building…")
                    }
                } else {
                    Label("Copy ⇧⌘C", systemImage: "doc.on.doc")
                }
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .buttonStyle(.borderedProminent)
            .disabled(store.isExporting)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain).font(.caption)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func banner(_ message: String, systemImage: String) -> some View {
        Label(message, systemImage: systemImage)
            .font(.caption)
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }

}
