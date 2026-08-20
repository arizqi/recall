import Foundation

/// Claude Desktop Cowork sessions. Each session directory holds an `audit.jsonl`
/// transcript; the sibling `local_<id>.json` holds the title when one exists.
struct CoworkSource: EventSource {
    let id = RecallSource.cowork
    let root: URL

    init(root: URL = Paths.coworkSessions) {
        self.root = root
    }

    func discover() -> [SourceFile] {
        jsonlFiles(directDescendantsOnly: false).filter { $0.url.lastPathComponent == "audit.jsonl" }
    }

    func events(in file: URL) -> [RecallEvent] {
        let sessionID = file.deletingLastPathComponent().lastPathComponent
        var title = metadataTitle(for: file) ?? ""
        var events: [RecallEvent] = []
        var seenUUIDs = Set<String>()

        JSONLReader.forEachLine(at: file) { data in
            guard let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = row["type"] as? String,
                  type == "user" || type == "assistant",
                  (row["isReplay"] as? Bool) != true,
                  row["tool_use_result"] == nil,
                  row["toolUseResult"] == nil,
                  let message = row["message"] as? [String: Any],
                  let text = RecallText.messageText(message["content"]),
                  !RecallText.isNoise(text)
            else { return true }
            if let uuid = row["uuid"] as? String, !seenUUIDs.insert(uuid).inserted { return true }

            if title.isEmpty, type == "user" { title = RecallText.title(from: text) }
            events.append(RecallEvent(
                source: id,
                conversationId: "\(id):\(sessionID)",
                title: title,
                ts: Timestamps.date(row["timestamp"] ?? row["at"]) ?? .distantPast,
                role: RecallEvent.Role(lenient: type),
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                artifactPaths: ArtifactScanner.paths(in: text)
            ))
            return true
        }

        return Normalization.finish(events, fallbackTitle: "Cowork session", file: file)
    }

    private func metadataTitle(for auditFile: URL) -> String? {
        let directory = auditFile.deletingLastPathComponent()
        let metadata = directory.deletingLastPathComponent()
            .appendingPathComponent("\(directory.lastPathComponent).json")
        guard let data = try? Data(contentsOf: metadata, options: .mappedIfSafe),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let explicit = record["title"] as? String, !RecallText.normalized(explicit).isEmpty {
            return RecallText.clipped(explicit, length: 82)
        }
        if let initial = RecallText.messageText(record["initialMessage"]) {
            return RecallText.title(from: initial)
        }
        return nil
    }
}
