import XCTest
@testable import Recall

/// Guards the fix for the freeze: a 2 MB conversation used to reach SwiftUI as one
/// attributed string and pin the main thread inside CTLineCreateWithAttributedString
/// for minutes.
final class TranscriptRowTests: XCTestCase {
    private func transcript(messages: Int, charactersEach: Int) -> Transcript {
        let body = String(repeating: "the quick brown fox jumps over the lazy dog\n", count: max(1, charactersEach / 44))
        let record = ConversationRecord(
            id: "claude-code:big", source: RecallSource.claudeCode, title: "Big session",
            startedAt: Date(timeIntervalSince1970: 1_786_000_000),
            endedAt: Date(timeIntervalSince1970: 1_786_100_000),
            filePath: "/tmp/big.jsonl", chunkCount: messages, artifactPaths: []
        )
        let events = (0..<messages).map { index in
            RecallEvent(
                source: RecallSource.claudeCode, conversationId: record.id, title: record.title,
                ts: record.startedAt.addingTimeInterval(TimeInterval(index)),
                role: index.isMultiple(of: 2) ? .user : .assistant,
                text: "message \(index)\n" + body
            )
        }
        return Transcript(conversation: record, events: events, reconstructed: false)
    }

    func testTwoMegabyteConversationBuildsRowsQuickly() {
        let transcript = transcript(messages: 200, charactersEach: 11_000)
        XCTAssertGreaterThan(transcript.events.reduce(0) { $0 + $1.text.count }, 2_000_000)

        let started = ContinuousClock.now
        let rows = TranscriptRows.rows(for: transcript)
        let elapsed = started.duration(to: .now)

        XCTAssertLessThan(elapsed, .milliseconds(500), "opening a big conversation must feel instant")
        XCTAssertEqual(rows.count, 200)
        XCTAssertEqual(rows.map(\.id), Array(0..<200))
    }

    func testNoRowIsLargeEnoughToStallLayout() {
        let rows = TranscriptRows.rows(for: transcript(messages: 3, charactersEach: 900_000))
        XCTAssertTrue(rows.allSatisfy { $0.characters <= TranscriptRow.segmentLimit })
        XCTAssertTrue(rows.allSatisfy { $0.preview.count <= TranscriptRow.collapsedLimit + 1 })
        XCTAssertTrue(rows.allSatisfy { $0.displayText(expanded: true).count <= TranscriptRow.segmentLimit })
    }

    func testAnOversizedMessageIsSplitNotTruncated() {
        let text = (0..<5_000).map { "line \($0)" }.joined(separator: "\n")
        let segments = TranscriptRows.segments(of: text)
        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertEqual(segments.joined(), text, "splitting must not lose a character")
        XCTAssertTrue(segments.dropFirst().allSatisfy { !$0.isEmpty })

        let rows = TranscriptRows.rows(for: Transcript(
            conversation: ConversationRecord(
                id: "x", source: "inbox", title: "t",
                startedAt: .distantPast, endedAt: .distantPast,
                filePath: "", chunkCount: 1, artifactPaths: []
            ),
            events: [RecallEvent(source: "inbox", conversationId: "x", title: "t",
                                 ts: .distantPast, role: .user, text: text)],
            reconstructed: false
        ))
        XCTAssertEqual(rows.count, segments.count)
        XCTAssertFalse(rows[0].continuation)
        XCTAssertTrue(rows[1].continuation, "continued rows are labelled so the split is visible")
        XCTAssertEqual(rows.map(\.text).joined(), text)
    }

    func testShortMessagesRenderWholeAndNeedNoExpansion() {
        let rows = TranscriptRows.rows(for: transcript(messages: 2, charactersEach: 100))
        XCTAssertTrue(rows.allSatisfy { !$0.isTruncated })
        XCTAssertEqual(rows[0].displayText(expanded: false), rows[0].text)
    }

    func testPreviewClippingDoesNotScanAWholeHugeMessage() {
        let huge = String(repeating: "a b c d e f g ", count: 200_000) // ~2.8 MB
        let started = ContinuousClock.now
        let preview = RecallText.clipped(huge, length: 260)
        let elapsed = started.duration(to: .now)
        XCTAssertLessThanOrEqual(preview.count, 261)
        XCTAssertLessThan(elapsed, .milliseconds(100), "previews normalize a window, not the whole message")
    }
}
