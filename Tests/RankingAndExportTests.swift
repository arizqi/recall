import XCTest
@testable import Recall

final class RankingTests: XCTestCase {
    private func engine() throws -> SearchEngine {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).db")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return SearchEngine(store: try IndexStore(url: url), embedder: HashingEmbedder())
    }

    func testFusionPrefersChunksFoundByBothRetrievers() throws {
        let fused = try engine().fuse(
            vector: [(id: 1, score: 0.9), (id: 2, score: 0.8), (id: 3, score: 0.7)],
            keyword: [(id: 3, score: 5), (id: 4, score: 4)]
        )
        // 3 is rank 3 by vector and rank 1 by keyword; that beats a single first place.
        XCTAssertEqual(fused.first?.id, 3)
        XCTAssertEqual(fused.first?.vectorRank, 3)
        XCTAssertEqual(fused.first?.keywordRank, 1)
        XCTAssertEqual(fused.map(\.id).sorted(), [1, 2, 3, 4])
    }

    func testKeywordOnlyResultsStillRank() throws {
        let fused = try engine().fuse(vector: [], keyword: [(id: 7, score: 3), (id: 8, score: 2)])
        XCTAssertEqual(fused.map(\.id), [7, 8])
        XCTAssertNil(fused[0].vectorRank)
    }

    func testWeightsShiftTheBalanceTowardVector() throws {
        var options = SearchOptions()
        options.vectorWeight = 1
        options.keywordWeight = 0.1
        let fused = try engine().fuse(
            vector: [(id: 1, score: 0.9)],
            keyword: [(id: 2, score: 9), (id: 1, score: 1)],
            options: options
        )
        XCTAssertEqual(fused.first?.id, 1, "a weak keyword weight cannot outrank the vector hit")
    }

    func testFusionIsStableForIdenticalScores() throws {
        var options = SearchOptions()
        options.keywordWeight = options.vectorWeight
        let fused = try engine().fuse(
            vector: [(id: 9, score: 1)],
            keyword: [(id: 2, score: 1)],
            options: options
        )
        XCTAssertEqual(fused.map(\.id), [2, 9], "equal scores break by id, so repeat queries agree")
    }

    func testConversationScoreCapsHowMuchOneLongThreadCanPileUp() {
        let focused = SearchEngine.conversationScore([1.0, 0.9])
        let sprawling = SearchEngine.conversationScore(Array(repeating: 0.3, count: 40))
        XCTAssertGreaterThan(focused, sprawling, "40 passing mentions must not beat two real ones")
        XCTAssertEqual(
            SearchEngine.conversationScore(Array(repeating: 1.0, count: 40)),
            SearchEngine.conversationScore(Array(repeating: 1.0, count: SearchEngine.scoredFragmentsPerConversation)),
            accuracy: 1e-9,
            "fragments past the cap contribute nothing"
        )
    }

    func testTokenizerQuotesEveryTermSoPunctuationIsSafe() {
        XCTAssertEqual(IndexStore.ftsTokens("Sources/Core/Chunker.swift"), ["\"sources\"", "\"core\"", "\"chunker\"", "\"swift\""])
        XCTAssertTrue(IndexStore.ftsTokens("   ").isEmpty)
    }

    func testOverlapStitchingRemovesTheRepeatedTail() {
        let previous = String(repeating: "alpha beta gamma ", count: 10)
        let overlap = String(previous.suffix(120))
        let next = overlap + "DELTA"
        XCTAssertEqual(TranscriptProvider.withoutOverlap(next, following: previous), "DELTA")
    }
}

final class ExportFormatterTests: XCTestCase {
    private func transcript(reconstructed: Bool = false, artifacts: [String] = []) -> Transcript {
        let record = ConversationRecord(
            id: "room:company",
            source: RecallSource.room,
            title: "Room — company",
            startedAt: Date(timeIntervalSince1970: 1_786_365_000),
            endedAt: Date(timeIntervalSince1970: 1_786_368_600),
            filePath: "/tmp/company.jsonl",
            chunkCount: 3,
            artifactPaths: artifacts
        )
        let events = [
            RecallEvent(source: RecallSource.room, conversationId: record.id, title: record.title,
                        ts: record.startedAt, role: .user, text: "rebind the builder model",
                        artifactPaths: artifacts),
            RecallEvent(source: RecallSource.room, conversationId: record.id, title: record.title,
                        ts: record.endedAt, role: .assistant, text: "Done."),
        ]
        return Transcript(conversation: record, events: events, reconstructed: reconstructed)
    }

    func testTranscriptBundleCarriesProvenanceAndArtifacts() throws {
        let existing = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: existing)
        addTeardownBlock { try? FileManager.default.removeItem(at: existing) }

        let markdown = ExportFormatter.bundle(
            for: transcript(artifacts: [existing.path, "/nope/missing.swift"]),
            body: .transcript
        )

        XCTAssertTrue(markdown.hasPrefix("# Room — company"))
        XCTAssertTrue(markdown.contains("- Source: Room"))
        XCTAssertTrue(markdown.contains("- Messages: 2"))
        XCTAssertTrue(markdown.contains("- File: `/tmp/company.jsonl`"))
        XCTAssertTrue(markdown.contains("## Transcript"))
        XCTAssertTrue(markdown.contains("USER:\nrebind the builder model"))
        XCTAssertTrue(markdown.contains("## Artifacts"))
        XCTAssertTrue(markdown.contains("`\(existing.path)`"))
        XCTAssertTrue(markdown.contains("`/nope/missing.swift`  _(missing)_"), "dead paths are marked, not hidden")
        XCTAssertTrue(markdown.contains("Exported by Recall"))
    }

    func testSummaryBundleReplacesTheTranscriptBody() {
        let summary = ConversationSummary(
            overview: "Swapped the builder model.",
            keyPoints: ["deepseek v4 pro was unavailable"],
            decisions: ["stay on qwen"],
            artifacts: [],
            nextSteps: [],
            model: "gemma4:e4b",
            generatedAt: Date()
        )
        let markdown = ExportFormatter.bundle(for: transcript(), body: .summary(summary.markdown))
        XCTAssertTrue(markdown.contains("## Summary"))
        XCTAssertTrue(markdown.contains("### Key points"))
        XCTAssertFalse(markdown.contains("## Transcript"))
    }

    func testReconstructedBundleSaysSo() {
        let markdown = ExportFormatter.bundle(for: transcript(reconstructed: true), body: .transcript)
        XCTAssertTrue(markdown.contains("rebuilt from the Recall index"))
    }

    func testFilenameIsDatedAndSlugged() {
        XCTAssertEqual(
            ExportFormatter.filename(for: transcript()),
            "\(DateFormatter.day.string(from: Date(timeIntervalSince1970: 1_786_365_000)))-room-company.md"
        )
    }

    func testMultiConversationBundleKeepsTheQueryHeading() {
        let markdown = ExportFormatter.bundle(
            for: [(transcript(), .transcript), (transcript(), .transcript)],
            query: "deepseek rebind"
        )
        XCTAssertTrue(markdown.contains("# Recall export — “deepseek rebind”"))
        XCTAssertEqual(markdown.components(separatedBy: "## Transcript").count - 1, 2)
    }
}
