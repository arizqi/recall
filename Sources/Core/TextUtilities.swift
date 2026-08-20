import Foundation

enum Timestamps {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let standard: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func iso8601(_ date: Date) -> String { fractional.string(from: date) }

    static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            guard raw > 0 else { return nil }
            // Anything past year 2286 in seconds is really milliseconds.
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1_000 : raw)
        }
        guard let string = value as? String, !string.isEmpty else { return nil }
        if let date = fractional.date(from: string) { return date }
        if let date = standard.date(from: string) { return date }
        if let seconds = Double(string) { return date(NSNumber(value: seconds)) }
        return nil
    }
}

enum RecallText {
    /// Content blocks come as a string, an array of blocks, or a dict with a
    /// `content` key, depending on which product wrote the line.
    static func messageText(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let dictionary = value as? [String: Any] {
            if let text = dictionary["text"] as? String { return text }
            // ChatGPT exports wrap message bodies in `content.parts`.
            if let parts = dictionary["parts"] { return messageText(parts) }
            return messageText(dictionary["content"])
        }
        guard let blocks = value as? [Any] else { return nil }
        let pieces = blocks.compactMap { block -> String? in
            if let string = block as? String { return string }
            guard let dictionary = block as? [String: Any] else { return nil }
            if let text = dictionary["text"] as? String { return text }
            if let parts = dictionary["parts"] as? [Any] { return messageText(parts) }
            if let content = dictionary["content"] as? String { return content }
            return nil
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: "\n")
    }

    static func normalized(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func clipped(_ text: String, length: Int) -> String {
        let clean = normalized(text)
        guard clean.count > length else { return clean }
        let end = clean.index(clean.startIndex, offsetBy: length)
        let prefix = String(clean[..<end])
        if let boundary = prefix.lastIndex(of: " ") {
            return String(prefix[..<boundary]) + "…"
        }
        return prefix + "…"
    }

    static func title(from text: String) -> String {
        let clean = normalized(text)
        guard !clean.isEmpty else { return "Untitled conversation" }
        let sentence = clean.split(whereSeparator: { ".!?\n".contains($0) }).first.map(String.init) ?? clean
        return clipped(sentence, length: 82)
    }

    /// Noise that Claude's own transports inject into transcripts. Indexing it
    /// buries real answers under boilerplate.
    static func isNoise(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        return trimmed.hasPrefix("<local-command-caveat>")
            || trimmed.hasPrefix("<local-command-stdout>")
            || trimmed.hasPrefix("<system-reminder>")
            || trimmed.hasPrefix("<command-name>")
            || trimmed.hasPrefix("Caveat: The messages below")
    }
}

/// Absolute filesystem paths mentioned in a message. These become the "Artifacts:"
/// list on export, existence-checked at display time rather than at index time so a
/// file created later still resolves.
enum ArtifactScanner {
    private static let pattern = try? NSRegularExpression(
        pattern: #"(?:/Users/[A-Za-z0-9._\-]+|~)(?:/[A-Za-z0-9._\-+@]+)+"#
    )

    private static let ignoredExtensions: Set<String> = ["", "com", "org", "net", "md5"]

    static func paths(in text: String) -> [String] {
        guard let pattern, !text.isEmpty else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var found: [String] = []
        var seen = Set<String>()
        for match in pattern.matches(in: text, range: range) {
            guard let matchRange = Range(match.range, in: text) else { continue }
            var candidate = String(text[matchRange])
            while let last = candidate.last, ".,;:)]}\"'".contains(last) {
                candidate.removeLast()
            }
            guard candidate.count > 6, candidate.contains("/") else { continue }
            let name = (candidate as NSString).lastPathComponent
            // Directory-ish paths are useful; bare hostnames caught by the regex are not.
            if name.contains("."), ignoredExtensions.contains((name as NSString).pathExtension) { continue }
            if seen.insert(candidate).inserted { found.append(candidate) }
        }
        return found
    }

    static func expand(_ path: String) -> String {
        path.hasPrefix("~") ? NSString(string: path).expandingTildeInPath : path
    }

    static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: expand(path))
    }
}
