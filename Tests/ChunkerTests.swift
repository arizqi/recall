import XCTest
@testable import Recall

final class ChunkerTests: XCTestCase {
    private func event(_ text: String, role: RecallEvent.Role = .user, offset: TimeInterval = 0) -> RecallEvent {
        RecallEvent(
            source: "test",
            conversationId: "test:1",
            title: "Fixture",
            ts: Date(timeIntervalSince1970: 1_786_000_000 + offset),
            role: role,
            text: text
        )
    }

    func testShortConversationBecomesOneChunkWithRoleLabels() {
        let chunks = Chunker().chunks(for: [
            event("How do I rank hybrid results?"),
            event("Reciprocal rank fusion.", role: .assistant, offset: 60),
        ])
        XCTAssertEqual(chunks.count, 1)
        XCTAssertTrue(chunks[0].text.contains("USER: How do I rank"))
        XCTAssertTrue(chunks[0].text.contains("ASSISTANT: Reciprocal rank fusion."))
        XCTAssertEqual(chunks[0].ordinal, 0)
    }

    func testLongConversationSplitsWithOverlapAndKeepsOrder() {
        let chunker = Chunker(targetCharacters: 500, overlapCharacters: 100)
        let events = (0..<20).map { index in
            event(String(repeating: "sentence \(index) ", count: 12), offset: TimeInterval(index))
        }
        let chunks = chunker.chunks(for: events)

        XCTAssertGreaterThan(chunks.count, 3)
        XCTAssertEqual(chunks.map(\.ordinal), Array(0..<chunks.count))
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.text.count, 500 + 200, "chunks stay near the target size")
        }
        // Overlap: the tail of one chunk reappears at the head of the next.
        let tail = String(chunks[0].text.suffix(40))
        XCTAssertTrue(chunks[1].text.contains(tail.prefix(20)))
        // Nothing is lost: every event's marker text appears somewhere.
        let joined = chunks.map(\.text).joined()
        for index in 0..<20 {
            XCTAssertTrue(joined.contains("sentence \(index)"), "event \(index) survived chunking")
        }
    }

    func testOneHugeMessageIsSplitRatherThanTruncated() {
        let chunker = Chunker(targetCharacters: 400, overlapCharacters: 50)
        let body = (0..<200).map { "line \($0)" }.joined(separator: "\n")
        let chunks = chunker.chunks(for: [event(body)])
        XCTAssertGreaterThan(chunks.count, 3)
        let joined = chunks.map(\.text).joined()
        XCTAssertTrue(joined.contains("line 0"))
        XCTAssertTrue(joined.contains("line 199"))
    }

    func testChunksAreGroupedPerConversation() {
        let a = event("first conversation")
        var b = event("second conversation")
        b.conversationId = "test:2"
        let chunks = Chunker().chunks(for: [a, b])
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(Set(chunks.map(\.conversationId)), ["test:1", "test:2"])
        XCTAssertTrue(chunks.allSatisfy { $0.ordinal == 0 }, "ordinals restart per conversation")
    }

    func testArtifactPathsRideAlongWithTheirChunk() {
        var withPath = event("wrote it")
        withPath.artifactPaths = ["/Users/example/a.swift"]
        let chunks = Chunker().chunks(for: [withPath])
        XCTAssertEqual(chunks[0].artifactPaths, ["/Users/example/a.swift"])
    }

    func testEmptyInputProducesNoChunks() {
        XCTAssertTrue(Chunker().chunks(for: []).isEmpty)
    }
}
