import AppKit
import Foundation

@MainActor
final class RecallStore: ObservableObject {
    @Published var query = ""
    @Published var sourceFilter: String?
    @Published var sort: SearchSort = .date
    @Published var datePreset: DateWindow.Preset = .any
    /// Newest conversations, shown when there is no query — the browse view.
    @Published private(set) var recent: [ConversationRecord] = []
    @Published private(set) var coverage: [SourceCoverage] = []
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
    /// Precomputed display slices; the view never sees a whole-transcript string.
    @Published private(set) var rows: [TranscriptRow] = []
    @Published var expandedRowIDs = Set<Int>()
    @Published private(set) var isExporting = false
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
        refreshRecent()
        refreshCoverage()
    }

    func refreshRecent() {
        guard let store else { return }
        recent = store.recentConversations(
            limit: 40,
            window: datePreset.window(),
            sources: sourceFilter.map { [$0] } ?? []
        )
    }

    /// Coverage is checked off the main thread: it walks the Cowork session tree.
    private func refreshCoverage() {
        guard let store else { return }
        let coworkRoot = Paths.coworkSessions
        let lastIndexed = store.recentConversations(limit: 1, sources: [RecallSource.cowork]).first?.endedAt
        Task.detached(priority: .utility) {
            let exists = FileManager.default.fileExists(atPath: coworkRoot.path)
            let touched = exists ? CoworkCoverage.directoryTouched(at: coworkRoot) : nil
            let coverage = CoworkCoverage.coverage(
                directoryExists: exists,
                lastIndexed: lastIndexed,
                directoryTouched: touched
            )
            await MainActor.run {
                self.coverage = coverage.isProblem ? [coverage] : []
            }
        }
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

    /// Drag in either vendor's account export; the format is detected from the file.
    func importExport(at url: URL) {
        do {
            let result = try ExportImporter().importArchive(at: url)
            note("Imported \(result.conversations) \(RecallSource.label(result.kind.source)) conversations — indexing…")
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
        options.window = datePreset.window()
        options.sort = sort

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

    @discardableResult
    func open(_ group: ConversationHits) -> Task<Void, Never>? {
        guard let store else { return nil }
        selected = group
        expandedRowIDs = []
        rows = []
        // Reading and slicing happen off the main thread: a large session is several
        // megabytes of JSONL, and the click that opens it must not block the UI.
        return Task.detached(priority: .userInitiated) {
            let transcript = TranscriptProvider(store: store).transcript(for: group.id)
            let rows = transcript.map { TranscriptRows.rows(for: $0) } ?? []
            await MainActor.run {
                guard self.selected?.id == group.id else { return }
                self.transcript = transcript
                self.rows = rows
            }
        }
    }

    /// Opening from the browse list: there are no matched fragments, so the detail
    /// view shows the transcript alone.
    @discardableResult
    func openRecent(_ record: ConversationRecord) -> Task<Void, Never>? {
        open(ConversationHits(
            id: record.id,
            source: record.source,
            title: record.title,
            date: record.endedAt,
            score: 0,
            hits: []
        ))
    }

    func closeDetail() {
        selected = nil
        transcript = nil
        rows = []
        expandedRowIDs = []
    }

    func toggleExpansion(_ row: TranscriptRow) {
        if expandedRowIDs.contains(row.id) {
            expandedRowIDs.remove(row.id)
        } else {
            expandedRowIDs.insert(row.id)
        }
    }

    // MARK: - Export

    /// ⇧⌘C: the whole point of the app — one keystroke from "I remember discussing
    /// this" to a pasteable bundle.
    /// Assembling a bundle concatenates the whole conversation, which is exactly the
    /// work the display path refuses to do — so it happens off the main thread with
    /// a spinner rather than on it with a beachball.
    func copySelection() {
        guard !isExporting else { return }
        let request = exportRequest()
        isExporting = true
        Task.detached(priority: .userInitiated) {
            let markdown = RecallStore.markdown(for: request)
            await MainActor.run {
                self.isExporting = false
                guard let markdown else { return self.note("Nothing selected to copy.") }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(markdown, forType: .string)
                self.note("Copied \(markdown.count.formatted()) characters.")
            }
        }
    }

    func saveSelection() {
        guard !isExporting, let transcript else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ExportFormatter.filename(for: transcript)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let request = exportRequest()
        isExporting = true
        Task.detached(priority: .userInitiated) {
            let markdown = RecallStore.markdown(for: request)
            await MainActor.run {
                self.isExporting = false
                guard let markdown else { return }
                do {
                    try Data(markdown.utf8).write(to: url)
                    self.note("Saved \(url.lastPathComponent).")
                } catch {
                    self.failure = error.localizedDescription
                }
            }
        }
    }

    func markdownForSelection() -> String? {
        RecallStore.markdown(for: exportRequest())
    }

    /// Everything the bundle needs, snapshotted on the main actor so the assembly
    /// itself can run anywhere.
    struct ExportRequest: Sendable {
        var transcript: Transcript?
        var summary: String?
        var groupIDs: [String] = []
        var fallbacks: [String: ConversationRecord] = [:]
        var query = ""
        var store: IndexStore?
        var sources: [any EventSource] = []
    }

    private func exportRequest() -> ExportRequest {
        var request = ExportRequest(query: query, store: store)
        request.sources = Paths.defaultSources()
        if let transcript {
            request.transcript = transcript
            request.summary = summaries[transcript.conversation.id]?.markdown
            return request
        }
        // A search-selection export takes the top few conversations.
        let groups = Array(results.prefix(5))
        request.groupIDs = groups.map(\.id)
        for group in groups { request.fallbacks[group.id] = Self.placeholder(group) }
        return request
    }

    nonisolated static func markdown(for request: ExportRequest) -> String? {
        if let transcript = request.transcript {
            return ExportFormatter.bundle(
                for: transcript,
                body: request.summary.map { ExportBody.summary($0) } ?? .transcript
            )
        }
        guard let store = request.store, !request.groupIDs.isEmpty else { return nil }
        let provider = TranscriptProvider(store: store, sources: request.sources)
        let bundles = request.groupIDs.map { id in
            (
                provider.transcript(for: id)
                    ?? Transcript(
                        conversation: request.fallbacks[id]!,
                        events: [],
                        reconstructed: true
                    ),
                ExportBody.transcript
            )
        }
        return ExportFormatter.bundle(for: bundles, query: request.query)
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

    private static func placeholder(_ group: ConversationHits) -> ConversationRecord {
        ConversationRecord(
            id: group.id, source: group.source, title: group.title,
            startedAt: group.date, endedAt: group.date, filePath: "",
            chunkCount: group.hits.count, artifactPaths: []
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
