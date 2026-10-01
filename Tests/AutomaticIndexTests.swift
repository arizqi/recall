import XCTest
@testable import Recall

final class AutomaticIndexTests: XCTestCase {
    @MainActor
    func testIndexesAtLaunchAndAgainOnTheConfiguredInterval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let inbox = root.appendingPathComponent("inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        try writeConversation("first", to: inbox.appendingPathComponent("first.jsonl"))
        let source = NormalizedJSONLSource(id: RecallSource.inbox, root: inbox)
        let store = RecallStore(
            indexURL: root.appendingPathComponent("index.db"),
            embedder: HashingEmbedder(dimensions: 64),
            importsDirectory: root.appendingPathComponent("imports"),
            downloadsDirectory: root.appendingPathComponent("downloads"),
            sources: [source],
            automaticIndexInterval: .milliseconds(50)
        )

        try await waitUntil { store.stats?.conversations == 1 }
        try writeConversation("second", to: inbox.appendingPathComponent("second.jsonl"))
        try await waitUntil { store.stats?.conversations == 2 }
    }

    private func writeConversation(_ id: String, to url: URL) throws {
        try RecallEventCodec.encode([
            RecallEvent(
                source: RecallSource.inbox,
                conversationId: "inbox:\(id)",
                title: id,
                ts: Date(),
                role: .user,
                text: "message \(id)"
            ),
        ]).write(to: url)
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                return XCTFail("automatic index did not complete before timeout")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
