import Foundation

enum ExportBody: Sendable {
    case transcript
    case summary(String)
}

/// The one-click bundle: a self-contained markdown file that can be pasted into any
/// other tool and still says where it came from and which real files it touched.
enum ExportFormatter {
    static func bundle(for transcript: Transcript, body: ExportBody) -> String {
        var out = ["# \(transcript.conversation.title)"]

        var facts = [
            "- Source: \(RecallSource.label(transcript.conversation.source))",
            "- Date: \(displayDate(transcript.conversation.startedAt)) → \(displayDate(transcript.conversation.endedAt))",
            "- Conversation: `\(transcript.conversation.id)`",
            "- Messages: \(transcript.messageCount)",
            "- File: `\(transcript.conversation.filePath)`",
        ]
        if transcript.reconstructed {
            facts.append("- Note: source file is gone; text rebuilt from the Recall index.")
        }
        out.append(facts.joined(separator: "\n"))

        switch body {
        case .transcript:
            out.append("## Transcript\n\n" + transcript.text)
        case let .summary(markdown):
            out.append(markdown)
        }

        out.append(artifactSection(for: transcript))
        out.append("---\nExported by Recall · local index, no cloud calls")
        return out.joined(separator: "\n\n") + "\n"
    }

    static func artifactSection(for transcript: Transcript) -> String {
        let artifacts = transcript.artifacts
        guard !artifacts.isEmpty else { return "## Artifacts\n\nNone referenced." }
        let lines = artifacts.map { artifact in
            "- `\(artifact.path)`" + (artifact.exists ? "" : "  _(missing)_")
        }
        return "## Artifacts\n\n" + lines.joined(separator: "\n")
    }

    /// Multiple conversations in one paste, for a search-selection export.
    static func bundle(for transcripts: [(Transcript, ExportBody)], query: String?) -> String {
        var out: [String] = []
        if let query, !query.isEmpty {
            out.append("# Recall export — “\(query)”\n\n\(transcripts.count) conversation(s)")
        }
        out.append(contentsOf: transcripts.map { bundle(for: $0.0, body: $0.1) })
        return out.joined(separator: "\n\n")
    }

    static func filename(for transcript: Transcript) -> String {
        let slug = transcript.conversation.title
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let stamp = DateFormatter.day.string(from: transcript.conversation.startedAt)
        return "\(stamp)-\(slug.isEmpty ? "conversation" : String(slug.prefix(60))).md"
    }

    private static func displayDate(_ date: Date) -> String {
        date == .distantPast ? "unknown" : DateFormatter.minute.string(from: date)
    }
}

extension DateFormatter {
    static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static let minute: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}
