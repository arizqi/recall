import AppKit
import Foundation

@MainActor
final class RecallStore: ObservableObject {
    @Published var query = ""
    @Published var sourceFilter: String?
    @Published private(set) var results: [ConversationHits] = []
    @Published private(set) var isSearching = false
    @Published private(set) var lastSearchMilliseconds: Int?
    @Published private(set) var searchMode = "hybrid"

    @Published private(set) var stats: IndexStats?
    @Published private(set) var missingSources: [String] = []
    @Published private(set) var isIndexing = false
    @Published private(set) var indexProgress: String?
    @Published private(set) var indexReport: String?

    @Published var selected: ConversationHits?
    @Published private(set) var transcript: Transcript?
    @Published private(set) var summaries: [String: ConversationSummary] = [:]
    @Published private(set) var summarizingIDs = Set<String>()
    @Published private(set) var status: String?
    @Published private(set) var failure: String?

    private var store: IndexStore?
    private let embedder: any Embedder
    private var searchTask: Task<Void, Never>?
    private var indexTask: Task<Void, Never>?
    private var statusResetTask: Task<Void, Never>?

    /// The index location and embedder are injectable so tests can drive the real
    /// view against a temporary index without a model.
    init(indexURL: URL = Paths.indexDatabase, embedder: any Embedder = OllamaEmbedder()) {
        self.embedder = embedder
        Paths.ensureDirectories()
        do {
            store = try IndexStore(url: indexURL)
        } catch {
            failure = error.localizedDescription
        }
        refreshStats()
    }

    var indexStore: IndexStore? { store }

    // MARK: - Index

    func refreshStats() {
        guard let store else { return }
        stats = store.stats()
        missingSources = Paths.defaultSources()
            .filter { !FileManager.default.fileExists(atPath: $0.root.path) }
            .map(\.displayName)
    }

    func index(force: Bool = false) {
        guard let store, !isIndexing else { return }
        isIndexing = true
        indexReport = nil
        indexTask = Task { [embedder] in
            if let ollama = embedder as? OllamaEmbedder, await !ollama.isReachable() {
                OllamaEmbedder.startIfInstalled()
                for _ in 0..<20 where await !ollama.isReachable() {
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
            let indexer = Indexer(store: store, embedder: embedder)
            let report = await indexer.run(
                options: IndexOptions(force: force),
                progress: { [weak self] progress in
                    Task { @MainActor in
                        self?.indexProgress = "\(RecallSource.label(progress.source)) \(progress.filesDone)/\(progress.filesTotal) · \(progress.file)"
                    }
                }
            )
            await MainActor.run {
                self.isIndexing = false
                self.indexProgress = nil
                self.indexReport = report.errors.isEmpty
                    ? report.summary
                    : report.summary + " · \(report.errors.count) error(s): " + (report.errors.first ?? "")
                self.refreshStats()
                if !self.query.isEmpty { self.search() }
            }
        }
    }

    func cancelIndexing() {
        indexTask?.cancel()
        isIndexing = false
        indexProgress = nil
    }

    func importChatGPTExport(at url: URL) {
        do {
            let result = try ChatGPTImporter().importArchive(at: url)
            note("Imported \(result.conversations) ChatGPT conversations — indexing…")
            index()
        } catch {
            failure = error.localizedDescription
        }
    }

    // MARK: - Search

    @discardableResult
    func search() -> Task<Void, Never>? {
        guard let store else { return nil }
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        guard !text.isEmpty else {
            results = []
            lastSearchMilliseconds = nil
            return nil
        }
        isSearching = true
        var options = SearchOptions(limit: 40)
        if let sourceFilter { options.sources = [sourceFilter] }

        searchTask = Task { [embedder] in
            let engine = SearchEngine(store: store, embedder: embedder)
            let started = Date()
            // A non-Ollama embedder (tests) is always available.
            let reachable = await (embedder as? OllamaEmbedder)?.isReachable() ?? true
            let hits = reachable
                ? await engine.search(text, options: options)
                : engine.keywordOnlySearch(text, options: options)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.results = hits
                self.searchMode = reachable ? "vector + keyword" : "keyword only (Ollama offline)"
                self.lastSearchMilliseconds = Int(Date().timeIntervalSince(started) * 1_000)
                self.isSearching = false
            }
        }
        return searchTask
    }

    func open(_ group: ConversationHits) {
        guard let store else { return }
        selected = group
        transcript = TranscriptProvider(store: store).transcript(for: group.id)
    }

    func closeDetail() {
        selected = nil
        transcript = nil
    }

    // MARK: - Export

    /// ⇧⌘C: the whole point of the app — one keystroke from "I remember discussing
    /// this" to a pasteable bundle.
    func copySelection() {
        guard let markdown = markdownForSelection() else {
            note("Nothing selected to copy.")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
        note("Copied \(markdown.count) characters.")
    }

    func markdownForSelection() -> String? {
        if let transcript {
            let body: ExportBody = summaries[transcript.conversation.id].map { .summary($0.markdown) } ?? .transcript
            return ExportFormatter.bundle(for: transcript, body: body)
        }
        guard let store, !results.isEmpty else { return nil }
        let provider = TranscriptProvider(store: store)
        let bundles = results.prefix(5).map { group in
            (provider.transcript(for: group.id) ?? emptyTranscript(group), ExportBody.transcript)
        }
        return ExportFormatter.bundle(for: bundles, query: query)
    }

    func saveSelection() {
        guard let transcript, let markdown = markdownForSelection() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ExportFormatter.filename(for: transcript)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(markdown.utf8).write(to: url)
            note("Saved \(url.lastPathComponent).")
        } catch {
            failure = error.localizedDescription
        }
    }

    func summarize() {
        guard let transcript, !summarizingIDs.contains(transcript.conversation.id) else { return }
        let id = transcript.conversation.id
        summarizingIDs.insert(id)
        Task {
            do {
                let summary = try await LocalSummarizer().summarize(
                    title: transcript.conversation.title,
                    transcript: transcript.text
                )
                await MainActor.run {
                    self.summaries[id] = summary
                    self.summarizingIDs.remove(id)
                    self.note("Summary ready (\(summary.model)).")
                }
            } catch {
                await MainActor.run {
                    self.summarizingIDs.remove(id)
                    self.failure = error.localizedDescription
                }
            }
        }
    }

    func reveal(_ path: String) {
        let expanded = ArtifactScanner.expand(path)
        guard FileManager.default.fileExists(atPath: expanded) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: expanded)])
    }

    // MARK: - Helpers

    private func emptyTranscript(_ group: ConversationHits) -> Transcript {
        Transcript(
            conversation: ConversationRecord(
                id: group.id, source: group.source, title: group.title,
                startedAt: group.date, endedAt: group.date, filePath: "",
                chunkCount: group.hits.count, artifactPaths: []
            ),
            events: [],
            reconstructed: true
        )
    }

    private func note(_ message: String) {
        status = message
        statusResetTask?.cancel()
        statusResetTask = Task {
            try? await Task.sleep(for: .seconds(4))
            await MainActor.run { self.status = nil }
        }
    }

    func dismissFailure() { failure = nil }
}
