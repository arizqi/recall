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
        .onDrop(of: [.fileURL], isTargeted: nil, perform: handleDrop)
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
        }
        .padding(16)
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
                if store.results.isEmpty { emptyState }
                ForEach(store.results) { group in
                    resultRow(group)
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

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: store.query.isEmpty ? "magnifyingglass" : "questionmark.folder")
                .font(.system(size: 26)).foregroundStyle(.tertiary)
            Text(store.query.isEmpty ? "Search your Claude Code, Cowork, Room, inbox and ChatGPT history."
                                     : "No matches for “\(store.query)”.")
                .font(.callout).foregroundStyle(.secondary)
            if !store.missingSources.isEmpty {
                Text("Not on this Mac: " + store.missingSources.joined(separator: ", "))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Text("Drop a ChatGPT export .zip here to import it.")
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
                VStack(alignment: .leading, spacing: 14) {
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
                        Button { store.copySelection() } label: { Label("Copy bundle", systemImage: "doc.on.doc") }
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

                    Text("Matched fragments").font(.subheadline.weight(.semibold))
                    ForEach(group.hits.prefix(5)) { hit in
                        Text(RecallText.clipped(hit.chunk.text, length: 600))
                            .font(.system(size: 11.5, design: .monospaced))
                            .padding(9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.09)))
                    }

                    Text("Transcript").font(.subheadline.weight(.semibold))
                    Text(transcript.text)
                        .font(.system(size: 11.5, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
        }
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
            Button { store.copySelection() } label: { Label("Copy ⇧⌘C", systemImage: "doc.on.doc") }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .buttonStyle(.borderedProminent)
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

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, ["zip", "json"].contains(url.pathExtension.lowercased()) else { return }
            Task { @MainActor in store.importChatGPTExport(at: url) }
        }
        return true
    }
}
