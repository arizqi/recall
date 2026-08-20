import Foundation

/// What Recall can and cannot see for a source, so the UI can say "this is missing
/// and here is why" instead of quietly returning less than the user expects.
struct SourceCoverage: Hashable, Sendable, Identifiable {
    var id: String { source }
    let source: String
    let state: State
    let detail: String

    enum State: Hashable, Sendable {
        case complete
        case notPresent
        /// The app is still in use but stopped writing transcripts locally.
        case transcriptsStopped(lastLocal: Date)
    }

    var isProblem: Bool { state != .complete }
}

enum CoworkCoverage {
    /// Cowork stopped writing local transcripts when Claude Desktop moved to remote
    /// sessions: `remote-session-spaces.json` keeps being rewritten with server-side
    /// session ids while the newest `audit.jsonl` stays frozen. The gap between "the
    /// directory is alive" and "the newest transcript" is the signal.
    static let staleAfterDays = 3.0

    static let cloudOnlyDetail =
        "Cowork sessions after %@ are cloud-only — Claude Desktop moved to remote "
        + "sessions and no longer writes local transcripts. Import a claude.ai export "
        + "ZIP to search them."

    /// - Parameters:
    ///   - lastIndexed: newest Cowork conversation in the index.
    ///   - directoryTouched: newest mtime anywhere in the Cowork session directory.
    static func coverage(
        directoryExists: Bool,
        lastIndexed: Date?,
        directoryTouched: Date?,
        now: Date = Date()
    ) -> SourceCoverage {
        guard directoryExists else {
            return SourceCoverage(
                source: RecallSource.cowork,
                state: .notPresent,
                detail: "No Cowork session directory on this Mac."
            )
        }
        guard let lastIndexed, let directoryTouched else {
            return SourceCoverage(source: RecallSource.cowork, state: .complete, detail: "")
        }
        let gap = directoryTouched.timeIntervalSince(lastIndexed) / 86_400
        guard gap > staleAfterDays else {
            return SourceCoverage(source: RecallSource.cowork, state: .complete, detail: "")
        }
        return SourceCoverage(
            source: RecallSource.cowork,
            state: .transcriptsStopped(lastLocal: lastIndexed),
            detail: String(format: cloudOnlyDetail, DateFormatter.day.string(from: lastIndexed))
        )
    }

    /// Claude rewrites these payloads on every launch; counting them would report a
    /// cloud-only gap on a machine that merely opened the app.
    private static let refreshedOnLaunch: Set<String> = ["skills", "skills-plugin", "rpm"]

    /// Newest mtime anywhere below the Cowork directory, ignoring the bundled skill
    /// and package payloads the app refreshes on every launch.
    static func directoryTouched(at root: URL) -> Date? {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        var newest: Date?
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            // Directory mtimes move for reasons that have nothing to do with
            // transcripts, so only real files count.
            guard values?.isRegularFile == true, let modified = values?.contentModificationDate else { continue }
            if url.pathComponents.contains(where: Self.refreshedOnLaunch.contains) {
                enumerator.skipDescendants()
                continue
            }
            if newest == nil || modified > newest! { newest = modified }
        }
        return newest
    }
}
