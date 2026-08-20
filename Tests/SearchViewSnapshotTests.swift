import AppKit
import SwiftUI
import XCTest
@testable import Recall

/// Renders the real view against a real (temporary) index, so a change that breaks
/// layout or the store wiring fails here rather than in the menu bar.
final class SearchViewSnapshotTests: XCTestCase {
    @MainActor
    func testRendersSearchResultsFromARealIndex() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let inbox = root.appendingPathComponent("inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let date = Date(timeIntervalSince1970: 1_786_360_000)
        func event(_ text: String, conversation: String, title: String, source: String, role: RecallEvent.Role, offset: TimeInterval) -> RecallEvent {
            RecallEvent(
                source: source, conversationId: conversation, title: title,
                ts: date.addingTimeInterval(offset), role: role, text: text
            )
        }
        try RecallEventCodec.encode([
            event("replace the builder model with deepseek v4 pro", conversation: "room:company",
                  title: "Room — company", source: RecallSource.room, role: .user, offset: 0),
            event("Rebound the builder; deepseek v4 pro returned 404 so we stayed on qwen.",
                  conversation: "room:company", title: "Room — company", source: RecallSource.room,
                  role: .assistant, offset: 60),
            event("Wire the deepseek rebind into the roadmap at /tmp/roadmap.md",
                  conversation: "claude-code:abc", title: "Roadmap update", source: RecallSource.claudeCode,
                  role: .user, offset: -86_400),
            event("Unrelated notes on espresso grind size", conversation: "cowork:local_9",
                  title: "Coffee", source: RecallSource.cowork, role: .user, offset: -172_800),
        ]).write(to: inbox.appendingPathComponent("fixture.jsonl"))

        let embedder = HashingEmbedder(dimensions: 64)
        let store = RecallStore(indexURL: root.appendingPathComponent("index.db"), embedder: embedder)
        let indexStore = try XCTUnwrap(store.indexStore)
        let report = await Indexer(store: indexStore, embedder: embedder).run(
            sources: [NormalizedJSONLSource(id: RecallSource.inbox, root: inbox)]
        )
        XCTAssertEqual(report.errors, [])
        store.refreshStats()

        store.query = "deepseek rebind"
        await store.search()?.value
        // Ranking between the two relevant conversations is the embedder's business
        // (a hashing stand-in here); what the view contract needs is that both
        // surface and the irrelevant one does not lead.
        XCTAssertTrue(store.results.map(\.id).contains("room:company"))
        XCTAssertTrue(store.results.map(\.id).contains("claude-code:abc"))
        XCTAssertNotEqual(store.results.first?.id, "cowork:local_9")
        XCTAssertEqual(store.searchMode, "vector + keyword")

        let hostingView = NSHostingView(rootView: SearchView(store: store))
        hostingView.frame = NSRect(x: 0, y: 0, width: 700, height: 720)
        hostingView.layoutSubtreeIfNeeded()
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            return XCTFail("Could not create snapshot bitmap")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            return XCTFail("Could not encode snapshot")
        }
        try png.write(to: URL(fileURLWithPath: "/tmp/RecallPreview.png"))
        XCTAssertGreaterThan(png.count, 20_000)
    }

    @MainActor
    func testTranscriptViewAndCopyProduceABundle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let inbox = root.appendingPathComponent("inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        try RecallEventCodec.encode([
            RecallEvent(source: RecallSource.inbox, conversationId: "inbox:1", title: "Export me",
                        ts: Date(timeIntervalSince1970: 1_786_360_000), role: .user,
                        text: "index the rooms directory", artifactPaths: ["/nope/gone.swift"]),
        ]).write(to: inbox.appendingPathComponent("fixture.jsonl"))

        let embedder = HashingEmbedder(dimensions: 64)
        let store = RecallStore(indexURL: root.appendingPathComponent("index.db"), embedder: embedder)
        let indexStore = try XCTUnwrap(store.indexStore)
        _ = await Indexer(store: indexStore, embedder: embedder).run(
            sources: [NormalizedJSONLSource(id: RecallSource.inbox, root: inbox)]
        )

        store.query = "rooms directory"
        await store.search()?.value
        let group = try XCTUnwrap(store.results.first)
        await store.open(group)?.value

        let transcript = try XCTUnwrap(store.transcript)
        XCTAssertFalse(transcript.reconstructed)
        let markdown = try XCTUnwrap(store.markdownForSelection())
        XCTAssertTrue(markdown.contains("# Export me"))
        XCTAssertTrue(markdown.contains("`/nope/gone.swift`  _(missing)_"))
    }
}
