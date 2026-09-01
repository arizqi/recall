import Foundation

/// `recall` — the same core the app uses, driven from a terminal so Recall can join
/// shell pipelines and scripts.
@main
struct RecallCLI {
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        let command = arguments.first ?? "help"
        if !arguments.isEmpty { arguments.removeFirst() }
        let options = Options(arguments)

        Paths.ensureDirectories()
        do {
            switch command {
            case "index": try await index(options)
            case "search": try await search(options)
            case "export": try await export(options)
            case "status": try status(options)
            case "recent": try recent(options)
            case "import", "import-chatgpt", "import-claude": try await importExport(options)
            case "help", "--help", "-h": print(usage)
            default:
                FileHandle.standardError.write(Data("Unknown command: \(command)\n\n\(usage)\n".utf8))
                exit(2)
            }
        } catch {
            FileHandle.standardError.write(Data("recall: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static let usage = """
    recall — local search over your AI chat history

      recall index [--force] [--no-embeddings] [--max-files N] [--source ID]
      recall search <query> [--limit N] [--source ID] [--since D] [--until D]
                            [--sort date|relevance] [--json]
      recall recent [--limit N] [--source ID] [--since D] [--until D] [--json]
      recall export <conversation-id> [--summary] [--out FILE]
      recall status
      recall import <export.zip> [more.zip …] [--to DIR]
                            ChatGPT or claude.ai account export.
                            Accepts the per-category zips (conversations-000.zip,
                            projects-000.zip, memories-000.zip, …), a folder of them,
                            or a bare conversations.json.
      recall import <manifest.json> [--download] [--downloads DIR] [--timeout SEC]
                            A claude.ai download manifest. Lists the files; with
                            --download, opens each single-use link in your browser
                            one at a time and imports each zip as it lands.

    Dates are `2026-08-19` or a relative span: `7d`, `2w`, `3m`, `1y`.
    Results are newest-first unless you pass `--sort relevance`.

    Everything runs locally. Embeddings and summaries come from Ollama on 127.0.0.1:11434.
    """

    // MARK: - Commands

    static func index(_ options: Options) async throws {
        let store = try IndexStore()
        let embedder = OllamaEmbedder()
        let skip = options.flag("no-embeddings")
        if !skip, await !embedder.isReachable() {
            throw EmbedderError.unavailable
        }
        var sources = Paths.defaultSources()
        if let only = options.value("source") {
            sources = sources.filter { $0.id == only }
            guard !sources.isEmpty else { throw IndexError.sql("no source named \(only)") }
        }
        let report = await Indexer(store: store, embedder: embedder).run(
            sources: sources,
            options: IndexOptions(
                force: options.flag("force"),
                skipEmbeddings: skip,
                maxFiles: options.value("max-files").flatMap(Int.init)
            ),
            progress: { progress in
                let line = "  [\(progress.source)] \(progress.filesDone)/\(progress.filesTotal) \(progress.file)"
                FileHandle.standardError.write(Data((line + "\n").utf8))
            }
        )
        print(report.summary)
        for error in report.errors.prefix(10) { print("  ! \(error)") }
    }

    static func search(_ options: Options) async throws {
        guard !options.positional.isEmpty else { throw CLIError.usage("search needs a query") }
        let query = options.positional.joined(separator: " ")
        let store = try IndexStore()
        let embedder = OllamaEmbedder()
        let engine = SearchEngine(store: store, embedder: embedder)
        var searchOptions = SearchOptions(limit: options.value("limit").flatMap(Int.init) ?? 10)
        if let source = options.value("source") { searchOptions.sources = [source] }
        searchOptions.window = try window(options)
        if let raw = options.value("sort") {
            guard let sort = SearchSort(rawValue: raw.lowercased()) else {
                throw CLIError.usage("--sort must be date or relevance")
            }
            searchOptions.sort = sort
        }

        let started = Date()
        let results = await embedder.isReachable()
            ? await engine.search(query, options: searchOptions)
            : engine.keywordOnlySearch(query, options: searchOptions)
        let elapsed = Date().timeIntervalSince(started)

        if options.flag("json") {
            let payload = results.map { group -> [String: Any] in
                [
                    "conversationId": group.id,
                    "source": group.source,
                    "title": group.title,
                    "date": Timestamps.iso8601(group.date),
                    "score": group.score,
                    "excerpt": RecallText.clipped(group.best.chunk.text, length: 400),
                    "file": group.best.chunk.filePath,
                ]
            }
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            return
        }

        guard !results.isEmpty else {
            print("No matches. (\(String(format: "%.0f", elapsed * 1000))ms)")
            return
        }
        for (rank, group) in results.enumerated() {
            print("\(rank + 1). [\(RecallSource.label(group.source))] \(group.title)")
            print("   \(DateFormatter.minute.string(from: group.date))  ·  \(group.hits.count) fragment(s)  ·  \(group.best.matchKind)  ·  score \(String(format: "%.4f", group.score))")
            print("   id: \(group.id)")
            print("   \(RecallText.clipped(group.best.chunk.text, length: 260))")
            print("")
        }
        let window = searchOptions.window.isAny ? "" : " · \(searchOptions.window.label)"
        print("\(results.count) conversation(s) in \(String(format: "%.0f", elapsed * 1000))ms "
            + "· sorted by \(searchOptions.sort.label.lowercased())\(window)")
    }

    static func export(_ options: Options) async throws {
        guard let id = options.positional.first else { throw CLIError.usage("export needs a conversation id") }
        let store = try IndexStore()
        guard let transcript = TranscriptProvider(store: store).transcript(for: id) else {
            throw CLIError.usage("no conversation \(id) in the index")
        }
        var body = ExportBody.transcript
        if options.flag("summary") {
            let summary = try await LocalSummarizer().summarize(
                title: transcript.conversation.title,
                transcript: transcript.text
            )
            body = .summary(summary.markdown)
        }
        let markdown = ExportFormatter.bundle(for: transcript, body: body)
        if let out = options.value("out") {
            let url = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
            try Data(markdown.utf8).write(to: url)
            print("Wrote \(url.path) (\(markdown.count) characters)")
        } else {
            print(markdown)
        }
    }

    static func status(_ options: Options) throws {
        let store = try IndexStore()
        let stats = store.stats()
        print("Index: \(store.url.path)")
        print(String(format: "Size:  %.1f MB", Double(stats.bytes) / 1_048_576))
        print("Model: \(stats.model) (\(stats.dimensions)d)")
        print("Total: \(stats.conversations) conversations · \(stats.chunks) chunks · \(stats.embedded) embedded")
        print("")
        for source in stats.sources {
            let stamp = source.lastIndexed.map { DateFormatter.minute.string(from: $0) } ?? "never"
            print("  \(RecallSource.label(source.source).padding(toLength: 14, withPad: " ", startingAt: 0)) "
                + "\(source.files) files · \(source.conversations) conversations · \(source.chunks) chunks · \(stamp)")
        }
        for source in Paths.defaultSources() where !stats.sources.contains(where: { $0.source == source.id }) {
            let files = store.indexedFilePaths(source: source.id).count
            let detail: String
            if files > 0 {
                // Bus files are filed under the source that found them, but their
                // chunks carry whatever source each event declared.
                detail = "\(files) file(s) indexed under declared sources"
            } else {
                detail = FileManager.default.fileExists(atPath: source.root.path)
                    ? "no conversations yet"
                    : "no directory at \(source.root.path)"
            }
            print("  \(source.displayName.padding(toLength: 14, withPad: " ", startingAt: 0)) \(detail)")
        }
    }

    /// Accepts one export, several category zips, or the folder holding them. A
    /// claude.ai download manifest is recognized and, by default, only described:
    /// its links are single-use, so opening them is an explicit `--download`.
    static func importExport(_ options: Options) async throws {
        guard !options.positional.isEmpty else {
            throw CLIError.usage("import needs a path to an export")
        }
        let urls = options.positional.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }

        if urls.count == 1, let manifest = ExportManifest.parse(contentsOf: urls[0]) {
            try await runManifest(manifest, options: options)
            return
        }

        // `--to` keeps a trial import out of the real bus directory.
        let destination = options.value("to").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? Paths.imports
        let result = try ExportImporter(destination: destination).importArchives(at: urls)
        guard let file = result.file else {
            print(result.headline)
            print(result.detail)
            return
        }
        print("Imported \(result.conversations) \(RecallSource.label(result.kind.source)) conversations "
            + "(\(result.events) events) → \(file.path)")
        print(result.detail)
        print("Run `recall index` to embed them.")
    }

    /// Walks a manifest one link at a time: open in the browser, wait for the zip to
    /// land in Downloads, import it, then the next. Never in parallel and never
    /// retried — each URL works exactly once, and opening the next one while a
    /// download is still running kills it.
    static func runManifest(_ manifest: ExportManifest, options: Options) async throws {
        print("claude.ai export manifest · \(manifest.files.count) file(s)"
            + (manifest.createdAt.map { " · created \(DateFormatter.minute.string(from: $0))" } ?? ""))
        for file in manifest.files {
            print("  \(file.filename)\(file.isIndexable ? "" : "   (account settings — not indexed)")")
        }
        guard options.flag("download") else {
            print("")
            print("Each link can be used once. Pass --download to open them in your default")
            print("browser, one at a time, and import each zip as it lands in Downloads.")
            return
        }

        let downloads = options.value("downloads").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? Paths.downloads
        let importer = ManifestImporter(
            manifest: manifest,
            downloads: downloads,
            destination: Paths.imports,
            watcher: DownloadWatcher(
                directory: downloads,
                timeout: options.value("timeout").flatMap(TimeInterval.init) ?? 300
            ),
            opener: { url in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = [url.absoluteString]
                try? process.run()
            }
        )
        print("")
        let summary = await importer.run { progress in
            let detail = progress.state.detail.map { " — \($0)" } ?? ""
            print("  [\(progress.state.label)] \(progress.file.filename)\(detail)")
        }
        print("")
        print("\(summary.headline) · \(summary.detail)")
        if !summary.failed.isEmpty {
            print("Failed: \(summary.failed.joined(separator: ", "))")
            print("Those links are single-use and may now be burned — request a new export.")
        }
        print("Run `recall index` to embed what landed.")
    }

    static func recent(_ options: Options) throws {
        let store = try IndexStore()
        let conversations = store.recentConversations(
            limit: options.value("limit").flatMap(Int.init) ?? 20,
            window: try window(options),
            sources: options.value("source").map { [$0] } ?? []
        )
        if options.flag("json") {
            let payload = conversations.map { record -> [String: Any] in
                [
                    "conversationId": record.id,
                    "source": record.source,
                    "title": record.title,
                    "startedAt": Timestamps.iso8601(record.startedAt),
                    "endedAt": Timestamps.iso8601(record.endedAt),
                    "file": record.filePath,
                ]
            }
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            return print(String(decoding: data, as: UTF8.self))
        }
        for record in conversations {
            print("\(DateFormatter.minute.string(from: record.endedAt))  "
                + "[\(RecallSource.label(record.source))] \(record.title)")
            print("   id: \(record.id)")
        }
        print("\(conversations.count) conversation(s)")
    }

    /// Shared `--since` / `--until` parsing. A date we cannot parse is an error, not
    /// a silent "any time" — searching the wrong window looks like missing data.
    static func window(_ options: Options) throws -> DateWindow {
        var window = DateWindow()
        if let raw = options.value("since") {
            guard let date = DateWindow.date(from: raw) else {
                throw CLIError.usage("could not read --since \(raw)")
            }
            window.since = date
        }
        if let raw = options.value("until") {
            guard let date = DateWindow.date(from: raw) else {
                throw CLIError.usage("could not read --until \(raw)")
            }
            window.until = date
        }
        return window
    }

    // MARK: - Argument parsing

    struct Options {
        var positional: [String] = []
        private var flags = Set<String>()
        private var values: [String: String] = [:]

        init(_ arguments: [String]) {
            var iterator = arguments.makeIterator()
            while let argument = iterator.next() {
                guard argument.hasPrefix("--") else {
                    positional.append(argument)
                    continue
                }
                let name = String(argument.dropFirst(2))
                if let equals = name.firstIndex(of: "=") {
                    values[String(name[name.startIndex..<equals])] = String(name[name.index(after: equals)...])
                } else if Self.valued.contains(name), let next = iterator.next() {
                    values[name] = next
                } else {
                    flags.insert(name)
                }
            }
        }

        private static let valued: Set<String> = [
            "limit", "source", "out", "max-files", "since", "until", "sort", "downloads", "timeout", "to",
        ]

        func flag(_ name: String) -> Bool { flags.contains(name) }
        func value(_ name: String) -> String? { values[name] }
    }

    enum CLIError: LocalizedError {
        case usage(String)
        var errorDescription: String? {
            switch self { case let .usage(detail): "\(detail)\n\n\(RecallCLI.usage)" }
        }
    }
}
