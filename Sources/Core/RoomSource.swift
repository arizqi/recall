import Foundation

/// A directory of room-shaped JSONL transcripts, one file per room. Company OS
/// writes `~/.company-os/hermes-home/company/rooms/<room>.jsonl`, but nothing here
/// knows or cares about Company OS: this is a plain directory reader, and it works
/// whether or not that runtime is installed or running.
///
/// Row shape: `{"at": ISO8601, "kind": "human"|"turn"|…, "from": id, "name": display, "text": "…"}`
struct RoomSource: EventSource {
    let id = RecallSource.room
    let root: URL

    init(root: URL = Paths.companyRooms) {
        self.root = root
    }

    func discover() -> [SourceFile] {
        jsonlFiles(directDescendantsOnly: false)
    }

    func events(in file: URL) -> [RecallEvent] {
        let roomName = file.deletingPathExtension().lastPathComponent
        let title = "Room — \(roomName)"
        var events: [RecallEvent] = []

        JSONLReader.forEachLine(at: file) { data in
            guard let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = RecallText.messageText(row["text"] ?? row["message"] ?? row["content"]),
                  !RecallText.isNoise(text)
            else { return true }
            let kind = (row["kind"] as? String) ?? "turn"
            guard kind != "tool_result" else { return true }
            let speaker = (row["name"] as? String) ?? (row["from"] as? String) ?? kind
            let body = "[\(speaker)] \(text.trimmingCharacters(in: .whitespacesAndNewlines))"

            events.append(RecallEvent(
                source: id,
                conversationId: "\(id):\((row["room"] as? String) ?? roomName)",
                title: title,
                ts: Timestamps.date(row["at"] ?? row["ts"] ?? row["timestamp"]) ?? .distantPast,
                role: RecallEvent.Role(lenient: kind == "human" ? "user" : kind),
                text: body,
                artifactPaths: ArtifactScanner.paths(in: text)
            ))
            return true
        }

        return Normalization.finish(events, fallbackTitle: title, file: file)
    }
}

/// The bus entry point: any directory of already-normalized Recall JSONL. Used for
/// the drop-in inbox and for converted imports (ChatGPT). Events keep the `source`
/// they declare, so a tool dropping `"source":"linear"` shows up with its own badge.
struct NormalizedJSONLSource: EventSource {
    let id: String
    let root: URL

    init(id: String = RecallSource.inbox, root: URL = Paths.inbox) {
        self.id = id
        self.root = root
    }

    func discover() -> [SourceFile] {
        jsonlFiles(directDescendantsOnly: false)
    }

    func events(in file: URL) -> [RecallEvent] {
        var events: [RecallEvent] = []
        JSONLReader.forEachLine(at: file) { data in
            if var event = RecallEventCodec.decode(line: data) {
                if event.source.isEmpty { event.source = id }
                if event.artifactPaths.isEmpty {
                    event.artifactPaths = ArtifactScanner.paths(in: event.text)
                }
                events.append(event)
            }
            return true
        }
        return Normalization.finish(events, fallbackTitle: file.deletingPathExtension().lastPathComponent, file: file)
    }
}
