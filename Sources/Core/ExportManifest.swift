import Foundation

/// claude.ai's 2026-08 export handoff.
///
/// The account page no longer hands over one big zip. It hands over a small JSON
/// manifest that points at one download URL per category — conversations, projects,
/// memories, design chats, and the account's `light_metadata`. Each URL works
/// **once**, and the server spends 60–120s building the zip before the download even
/// starts. That is why this type exists separately from `ExportImporter`: the file a
/// user drops is not data, it is a plan for fetching data, and acting on it has to be
/// deliberate, sequential, and never retried.
struct ExportManifest: Sendable, Equatable {
    /// The category that holds `users.json` + `login_history.json`. Downloaded so the
    /// user keeps a complete export, never indexed.
    static let accountMetadataCategory = "light_metadata"

    struct DataFile: Sendable, Equatable, Identifiable {
        var batchIndex: Int
        var exportURL: URL
        var category: String
        var part: Int
        var filename: String

        var id: Int { batchIndex }
        var isIndexable: Bool { category != ExportManifest.accountMetadataCategory }

        /// "Conversations · part 2" — the category as a person would read it, and a
        /// plain warning for the one category that will not be indexed.
        var label: String {
            guard isIndexable else { return "Account settings — downloaded, not indexed" }
            let name = category
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
            return part > 0 ? "\(name) · part \(part + 1)" : name
        }
    }

    var version: String
    var createdAt: Date?
    var instructions: String?
    var totalFiles: Int
    var files: [DataFile]
    /// Where the manifest itself was read from, for the confirmation UI.
    var sourceURL: URL?

    var indexableCount: Int { files.filter(\.isIndexable).count }

    /// Recognizes a manifest by its shape, not its filename: a `version` string plus
    /// a `data_files` array whose entries carry an `export_url` and a `category`.
    /// Only http(s) URLs are accepted — this file decides what Recall will hand to
    /// the browser, so a `file:` or custom-scheme entry is dropped rather than opened.
    static func parse(_ data: Data) -> ExportManifest? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = root["version"] as? String,
              let rawFiles = root["data_files"] as? [[String: Any]],
              !rawFiles.isEmpty
        else { return nil }

        var files: [DataFile] = []
        for (offset, raw) in rawFiles.enumerated() {
            guard let link = raw["export_url"] as? String,
                  let url = URL(string: link),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "https" || scheme == "http",
                  let category = raw["category"] as? String
            else { continue }
            let part = (raw["part"] as? Int) ?? 0
            let filename = (raw["filename"] as? String) ?? "\(category)-\(String(format: "%03d", part)).zip"
            files.append(DataFile(
                batchIndex: (raw["batch_index"] as? Int) ?? offset,
                exportURL: url,
                category: category,
                part: part,
                // Defend the download watcher from a path in the filename field.
                filename: (filename as NSString).lastPathComponent
            ))
        }
        guard !files.isEmpty else { return nil }

        return ExportManifest(
            version: version,
            createdAt: Timestamps.date(root["created_at"]),
            instructions: root["instructions"] as? String,
            totalFiles: (root["total_files"] as? Int) ?? files.count,
            files: files.sorted { $0.batchIndex < $1.batchIndex },
            sourceURL: nil
        )
    }

    /// Reads a manifest off disk. Big files are not manifests, so anything over a
    /// megabyte is rejected without being parsed — a conversations.json is not a plan.
    static func parse(contentsOf url: URL) -> ExportManifest? {
        guard url.pathExtension.lowercased() == "json" else { return nil }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= 1_048_576 else { return nil }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        var manifest = parse(data)
        manifest?.sourceURL = url
        return manifest
    }
}
