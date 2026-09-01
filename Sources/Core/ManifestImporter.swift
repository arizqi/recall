import Foundation

/// Where one manifest entry has got to.
enum ManifestFileState: Sendable, Equatable {
    case waiting
    /// The URL is open in the browser; the server is building the zip, or the
    /// browser is writing it.
    case downloading
    case imported(String)
    /// Recognized and deliberately not indexed (light_metadata), or already imported.
    case skipped(String)
    case failed(String)

    var isTerminal: Bool {
        switch self {
        case .waiting, .downloading: false
        case .imported, .skipped, .failed: true
        }
    }

    var label: String {
        switch self {
        case .waiting: "waiting"
        case .downloading: "downloading"
        case .imported: "imported"
        case .skipped: "skipped"
        case .failed: "failed"
        }
    }

    var detail: String? {
        switch self {
        case .waiting, .downloading: nil
        case let .imported(text), let .skipped(text), let .failed(text): text
        }
    }
}

struct ManifestFileProgress: Sendable, Equatable, Identifiable {
    var file: ExportManifest.DataFile
    var state: ManifestFileState
    var id: Int { file.batchIndex }
}

struct ManifestRunSummary: Sendable, Equatable {
    var conversations = 0
    var designChats = 0
    var projects = 0
    var memories = 0
    var events = 0
    var duplicates = 0
    var skipped: [String] = []
    var failed: [String] = []
    var cancelled = false

    var indexedAnything: Bool { events > 0 }

    var headline: String {
        if cancelled { return "Download stopped" }
        if !failed.isEmpty && !indexedAnything { return "Nothing was imported" }
        return "\(conversations.formatted()) conversation\(conversations == 1 ? "" : "s") imported"
    }

    var detail: String {
        var parts: [String] = []
        if conversations > 0 { parts.append("\(conversations) conversations") }
        if designChats > 0 { parts.append("\(designChats) design chats") }
        if projects > 0 { parts.append("\(projects) projects") }
        if memories > 0 { parts.append("\(memories) memory set\(memories == 1 ? "" : "s")") }
        if events > 0 { parts.append("\(events.formatted()) messages") }
        if duplicates > 0 { parts.append("\(duplicates) already imported") }
        if !skipped.isEmpty { parts.append("\(skipped.count) skipped") }
        if !failed.isEmpty { parts.append("\(failed.count) failed") }
        return parts.isEmpty ? "Nothing to index." : parts.joined(separator: " · ")
    }

    mutating func absorb(_ result: ExportImporter.Result) {
        conversations += result.breakdown[ExportPart.conversations] ?? 0
        designChats += result.breakdown[ExportPart.designChats] ?? 0
        projects += result.breakdown[ExportPart.projectDocs] ?? 0
        memories += result.breakdown[ExportPart.memories] ?? 0
        events += result.events
        duplicates += result.duplicates
    }
}

enum DownloadWatchError: LocalizedError, Equatable {
    /// The file never appeared, or never stopped growing, inside the timeout.
    case timedOut(filename: String, appeared: Bool, waited: TimeInterval)

    var errorDescription: String? {
        switch self {
        case let .timedOut(filename, appeared, waited):
            let minutes = max(1, Int((waited / 60).rounded()))
            let what = appeared
                ? "\(filename) started downloading but never finished"
                : "\(filename) never arrived in your Downloads folder"
            return "\(what) after \(minutes) minute\(minutes == 1 ? "" : "s"). "
                + "The download link is single-use, so it may now be burned — "
                + "request a new export from claude.ai rather than retrying this one."
        }
    }
}

/// Waits for a browser download to land and go quiet.
///
/// Recall never fetches anything itself: the browser holds the claude.ai session, so
/// the browser does the download and Recall watches the folder. "Landed" means the
/// file exists, has no in-progress sibling (`.crdownload`, `.download`, …), and its
/// size has not changed across consecutive polls. Anything looser and the next
/// single-use URL gets opened on top of a download still in flight, which kills it.
struct DownloadWatcher: Sendable {
    var directory: URL
    /// Generous on purpose: the server spends 60–120s building the zip before a
    /// single byte moves, and a large conversations export is not small.
    var timeout: TimeInterval = 300
    var pollInterval: TimeInterval = 2
    /// How many consecutive equal-size polls count as "finished".
    var settleChecks = 2

    /// Extensions browsers use for a download that is still running.
    static let partialExtensions: Set<String> = ["crdownload", "download", "part", "partial", "opdownload"]

    func wait(for filename: String, startedAt: Date) async throws -> URL {
        let deadline = Date().addingTimeInterval(timeout)
        var lastSize: Int64 = -1
        var stable = 0
        var appeared = false

        while true {
            try Task.checkCancellation()
            if let candidate = newestCandidate(for: filename, notBefore: startedAt) {
                appeared = true
                if hasPartialSibling(for: filename) {
                    stable = 0
                    lastSize = -1
                } else {
                    let size = Self.size(of: candidate)
                    if size > 0, size == lastSize {
                        stable += 1
                        if stable >= settleChecks { return candidate }
                    } else {
                        stable = 0
                        lastSize = size
                    }
                }
            }
            guard Date() < deadline else {
                throw DownloadWatchError.timedOut(filename: filename, appeared: appeared, waited: timeout)
            }
            try await Task.sleep(nanoseconds: UInt64(max(pollInterval, 0.01) * 1_000_000_000))
        }
    }

    /// The file the browser actually wrote. Chrome and Safari rename a download that
    /// collides with an existing file (`conversations-000-1.zip`,
    /// `conversations-000 (1).zip`), so the exact name is a starting point, not a
    /// requirement — but it must be newer than the moment we opened the URL, or an
    /// older export sitting in Downloads would be imported instead.
    func newestCandidate(for filename: String, notBefore: Date) -> URL? {
        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension.lowercased()
        let cutoff = notBefore.addingTimeInterval(-5)

        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return entries
            .filter { url in
                guard url.pathExtension.lowercased() == ext else { return false }
                let name = (url.lastPathComponent as NSString).deletingPathExtension
                guard name == stem || Self.isRenamedCopy(name, of: stem) else { return false }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return modified >= cutoff
            }
            .max { left, right in Self.modified(left) < Self.modified(right) }
    }

    /// `name (1)`, `name-1`, `name 1` — the shapes browsers use to avoid overwriting.
    static func isRenamedCopy(_ name: String, of stem: String) -> Bool {
        guard name.hasPrefix(stem), name != stem else { return false }
        var tail = String(name.dropFirst(stem.count))
        if tail.hasPrefix(" ") || tail.hasPrefix("-") || tail.hasPrefix("_") { tail.removeFirst() }
        if tail.hasPrefix("("), tail.hasSuffix(")") { tail = String(tail.dropFirst().dropLast()) }
        return !tail.isEmpty && tail.allSatisfy(\.isNumber)
    }

    func hasPartialSibling(for filename: String) -> Bool {
        let stem = (filename as NSString).deletingPathExtension
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        )) ?? []
        return entries.contains { url in
            guard Self.partialExtensions.contains(url.pathExtension.lowercased()) else { return false }
            return url.lastPathComponent.contains(stem)
        }
    }

    private static func size(of url: URL) -> Int64 {
        let value = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        return Int64(value ?? 0)
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }
}

/// Runs a manifest: for each entry, hand the single-use URL to the browser, wait for
/// the zip to land, import it, move on. Strictly one at a time.
///
/// The sequencing is the whole point. Opening two of these URLs at once — or opening
/// the next one while a download is still in flight — cancels the in-flight download
/// and burns the link permanently, because the server will not issue the same URL
/// twice. A failed entry is therefore never retried; the user is told to request a
/// fresh export instead.
struct ManifestImporter: Sendable {
    var manifest: ExportManifest
    var downloads: URL
    var destination: URL
    var watcher: DownloadWatcher
    /// Injected so Core stays free of AppKit — and so tests never open a real URL.
    var opener: @Sendable (URL) -> Void

    init(
        manifest: ExportManifest,
        downloads: URL,
        destination: URL,
        watcher: DownloadWatcher? = nil,
        opener: @escaping @Sendable (URL) -> Void
    ) {
        self.manifest = manifest
        self.downloads = downloads
        self.destination = destination
        self.watcher = watcher ?? DownloadWatcher(directory: downloads)
        self.opener = opener
    }

    func run(progress: @escaping @Sendable (ManifestFileProgress) -> Void) async -> ManifestRunSummary {
        var summary = ManifestRunSummary()
        for file in manifest.files {
            if Task.isCancelled {
                summary.cancelled = true
                break
            }
            progress(ManifestFileProgress(file: file, state: .downloading))
            let started = Date()
            opener(file.exportURL)

            let landed: URL
            do {
                landed = try await watcher.wait(for: file.filename, startedAt: started)
            } catch is CancellationError {
                summary.cancelled = true
                progress(ManifestFileProgress(file: file, state: .waiting))
                break
            } catch {
                summary.failed.append(file.filename)
                progress(ManifestFileProgress(file: file, state: .failed(error.localizedDescription)))
                // Do not open the next URL blind after a timeout: the download may
                // still be crawling, and opening the next one would kill it.
                continue
            }

            guard file.isIndexable else {
                let note = "account settings — kept in Downloads, not indexed"
                summary.skipped.append(file.filename)
                progress(ManifestFileProgress(file: file, state: .skipped(note)))
                continue
            }

            do {
                let result = try ExportImporter(destination: destination).importArchives(at: [landed])
                if result.conversations == 0 {
                    summary.skipped.append(file.filename)
                    progress(ManifestFileProgress(file: file, state: .skipped(result.detail)))
                } else {
                    summary.absorb(result)
                    progress(ManifestFileProgress(file: file, state: .imported(result.detail)))
                }
            } catch let error as ExportImportError {
                // "Everything here was already imported" is a fine outcome, not a
                // failure — re-running a manifest after a partial run must be calm.
                switch error {
                case let .nothingToImport(detail):
                    summary.skipped.append(file.filename)
                    progress(ManifestFileProgress(file: file, state: .skipped(detail)))
                default:
                    summary.failed.append(file.filename)
                    progress(ManifestFileProgress(file: file, state: .failed(error.localizedDescription)))
                }
            } catch {
                summary.failed.append(file.filename)
                progress(ManifestFileProgress(file: file, state: .failed(error.localizedDescription)))
            }
        }
        return summary
    }
}
