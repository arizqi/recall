import Foundation

/// Streaming, bounded JSONL reader. Sources are read-only: Recall never writes back
/// into anything it indexes.
enum JSONLReader {
    /// Claude Code sessions reach hundreds of megabytes, almost all of it tool
    /// results that never get indexed — 134 MB of raw JSONL on this machine holds
    /// 0.3 MB of actual conversation. The limit is a runaway guard, not a budget, so
    /// it sits far above any real transcript.
    static let defaultByteLimit = 1_024 * 1_024 * 1_024

    /// Calls `body` with each non-empty line. Return false from `body` to stop early.
    static func forEachLine(
        at url: URL,
        byteLimit: Int = defaultByteLimit,
        _ body: (Data) -> Bool
    ) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        var buffer = Data()
        var total = 0
        while total < byteLimit {
            let allowance = min(256 * 1_024, byteLimit - total)
            guard let chunk = try? handle.read(upToCount: allowance), !chunk.isEmpty else { break }
            total += chunk.count
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                if !line.isEmpty, !body(line) { return }
            }
        }
        if !buffer.isEmpty { _ = body(buffer) }
    }

    static func rows(at url: URL, byteLimit: Int = defaultByteLimit) -> [[String: Any]] {
        var rows: [[String: Any]] = []
        forEachLine(at: url, byteLimit: byteLimit) { data in
            if let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                rows.append(row)
            }
            return true
        }
        return rows
    }
}

struct SourceFile: Hashable, Sendable {
    let url: URL
    let source: String
    let modified: Date
    let size: Int64

    init(url: URL, source: String) {
        self.url = url
        self.source = source
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        self.modified = values?.contentModificationDate ?? .distantPast
        self.size = Int64(values?.fileSize ?? 0)
    }
}

/// One ingestible source of conversation history. Every source resolves to a set of
/// files plus a pure file → events function, which is what makes fixture tests cheap
/// and incremental re-indexing (mtime + size) uniform across sources.
protocol EventSource: Sendable {
    var id: String { get }
    var displayName: String { get }
    var root: URL { get }
    func discover() -> [SourceFile]
    func events(in file: URL) -> [RecallEvent]
}

extension EventSource {
    var displayName: String { RecallSource.label(id) }

    func jsonlFiles(directDescendantsOnly: Bool) -> [SourceFile] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else { return [] }
        var files: [SourceFile] = []

        if directDescendantsOnly {
            let projects = (try? manager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            // Top-level sessions only: nested subagent transcripts are duplicates of
            // work already present in their parent session.
            for project in projects {
                let isDirectory = (try? project.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                let candidates = isDirectory
                    ? ((try? manager.contentsOfDirectory(
                        at: project,
                        includingPropertiesForKeys: [.isRegularFileKey],
                        options: [.skipsHiddenFiles]
                    )) ?? [])
                    : [project]
                for url in candidates where url.pathExtension.lowercased() == "jsonl" {
                    files.append(SourceFile(url: url, source: id))
                }
            }
            return files
        }

        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "jsonl" {
            files.append(SourceFile(url: url, source: id))
        }
        return files
    }
}
