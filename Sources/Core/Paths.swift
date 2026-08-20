import Foundation

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static var applicationSupport: URL {
        home.appendingPathComponent("Library/Application Support/Recall")
    }

    /// Where any tool can drop normalized Recall JSONL. Documented in the README as
    /// the bus protocol.
    static var inbox: URL { applicationSupport.appendingPathComponent("inbox") }
    static var imports: URL { applicationSupport.appendingPathComponent("imports") }
    static var indexDatabase: URL { applicationSupport.appendingPathComponent("index.db") }

    static var claudeCodeProjects: URL { home.appendingPathComponent(".claude/projects") }
    static var coworkSessions: URL {
        home.appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions")
    }
    static var companyRooms: URL {
        home.appendingPathComponent(".company-os/hermes-home/company/rooms")
    }

    static func ensureDirectories() {
        for url in [applicationSupport, inbox, imports] {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    /// The default source set. Missing directories are kept in the list so the UI can
    /// report "not present" rather than silently omitting a source.
    static func defaultSources() -> [any EventSource] {
        [
            ClaudeCodeSource(),
            CoworkSource(),
            RoomSource(),
            NormalizedJSONLSource(id: RecallSource.inbox, root: inbox),
            NormalizedJSONLSource(id: RecallSource.imports, root: imports),
        ]
    }
}
