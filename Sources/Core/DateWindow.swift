import Foundation

/// A `--since`/`--until` window. Accepts what people actually type: an ISO date, or
/// a relative span like `7d` / `2w` / `3m` / `1y`.
struct DateWindow: Hashable, Sendable {
    var since: Date?
    var until: Date?

    static let any = DateWindow()

    var isAny: Bool { since == nil && until == nil }

    func contains(_ date: Date) -> Bool {
        if let since, date < since { return false }
        if let until, date > until { return false }
        return true
    }

    /// Named presets for the UI. `nil` span means "any time".
    enum Preset: String, CaseIterable, Identifiable, Sendable {
        case any = "Any time"
        case day = "Last 24 hours"
        case week = "Last 7 days"
        case month = "Last 30 days"
        case year = "Last 12 months"

        var id: String { rawValue }

        func window(now: Date = Date()) -> DateWindow {
            switch self {
            case .any: DateWindow()
            case .day: DateWindow(since: now.addingTimeInterval(-86_400))
            case .week: DateWindow(since: now.addingTimeInterval(-7 * 86_400))
            case .month: DateWindow(since: now.addingTimeInterval(-30 * 86_400))
            case .year: DateWindow(since: now.addingTimeInterval(-365 * 86_400))
            }
        }
    }

    /// `2026-08-19`, `2026-08-19T13:00:00Z`, or `7d` / `2w` / `3m` / `1y` meaning
    /// "that long ago". Returns nil for anything else so the caller can complain
    /// rather than silently searching the wrong window.
    static func date(from text: String, now: Date = Date()) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }

        if let last = trimmed.last, "dwmy".contains(last), let count = Int(trimmed.dropLast()) {
            let days: Double = switch last {
            case "d": 1
            case "w": 7
            case "m": 30
            default: 365
            }
            return now.addingTimeInterval(-Double(count) * days * 86_400)
        }

        if let iso = Timestamps.date(text) { return iso }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter.date(from: trimmed)
    }

    var label: String {
        switch (since, until) {
        case (nil, nil): "Any time"
        case let (since?, nil): "Since \(DateFormatter.day.string(from: since))"
        case let (nil, until?): "Until \(DateFormatter.day.string(from: until))"
        case let (since?, until?):
            "\(DateFormatter.day.string(from: since)) – \(DateFormatter.day.string(from: until))"
        }
    }
}
