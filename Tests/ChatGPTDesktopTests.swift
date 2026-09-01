import XCTest
@testable import Recall

/// Fixtures for the ChatGPT desktop app's rollout store. Synthetic throughout — no
/// real session ever lands in the repo — and shaped after what
/// `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` actually contains.
final class ChatGPTDesktopTests: XCTestCase {
    private var root: URL!
    private var imports: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        imports = root.appendingPathComponent("imports")
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var sessions: URL { root.appendingPathComponent("sessions") }

    private func source() -> ChatGPTDesktopSource {
        ChatGPTDesktopSource(root: sessions, imports: imports)
    }

    @discardableResult
    private func write(_ name: String, _ contents: String, day: String = "2026/08/01") throws -> URL {
        let directory = sessions.appendingPathComponent(day)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: file)
        return file
    }

    func testReadsDesktopSessionAndLeavesTheFileUntouched() throws {
        let file = try write("rollout-2026-08-01T19-29-44-sess-1.jsonl", #"""
        {"timestamp":"2026-08-01T19:29:44.000Z","type":"session_meta","payload":{"session_id":"sess-1","id":"sess-1","timestamp":"2026-08-01T19:29:44.000Z","cwd":"/Users/example/widget","originator":"Codex Desktop","source":"vscode"}}
        {"timestamp":"2026-08-01T19:29:45.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Build a pricing model in /Users/example/widget/pricing.md"}]}}
        {"timestamp":"2026-08-01T19:29:46.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"I wrote the model into a markdown report."}]}}
        {"timestamp":"2026-08-01T19:29:46.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total":12}}}

        """#)
        let before = try Data(contentsOf: file)

        let events = source().events(in: file)

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.map(\.role), [.user, .assistant])
        XCTAssertEqual(events[0].source, "chatgpt")
        XCTAssertEqual(events[0].conversationId, "chatgpt:sess-1")
        XCTAssertEqual(events[0].title, "Build a pricing model in /Users/example/widget/pricing")
        XCTAssertEqual(events[1].title, events[0].title, "later turns inherit the conversation title")
        XCTAssertEqual(events[0].artifactPaths, ["/Users/example/widget/pricing.md"])
        XCTAssertEqual(try Data(contentsOf: file), before, "sources are read-only")
    }

    /// Both streams carry the same turns; indexing both would double every message.
    func testUIEventStreamDoesNotDuplicateTheMessageList() throws {
        let file = try write("rollout-2026-08-01T19-30-00-sess-dup.jsonl", #"""
        {"type":"session_meta","payload":{"session_id":"sess-dup","timestamp":"2026-08-01T19:30:00.000Z","cwd":"/Users/example/app","source":"vscode"}}
        {"type":"event_msg","payload":{"type":"user_message","message":"Reconcile the July accounts."}}
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Reconcile the July accounts."}]}}
        {"type":"event_msg","payload":{"type":"agent_message","message":"Done — two entries differed."}}
        {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Done — two entries differed."}]}}

        """#)

        let events = source().events(in: file)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.map(\.text), ["Reconcile the July accounts.", "Done — two entries differed."])
    }

    /// Older desktop builds only wrote the UI event stream.
    func testFallsBackToTheEventStreamWhenThereIsNoMessageList() throws {
        let file = try write("rollout-2026-08-01T09-00-00-sess-3.jsonl", #"""
        {"type":"session_meta","payload":{"session_id":"sess-3","timestamp":"2026-08-01T09:00:00.000Z","cwd":"/Users/example/legacy","source":"vscode"}}
        {"timestamp":"2026-08-01T09:00:01.000Z","type":"event_msg","payload":{"type":"user_message","message":"Summarize the quarterly numbers."}}
        {"timestamp":"2026-08-01T09:00:02.000Z","type":"event_msg","payload":{"type":"agent_message","message":"Revenue grew nineteen percent."}}

        """#)

        let events = source().events(in: file)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].title, "Summarize the quarterly numbers")
        XCTAssertEqual(events[1].text, "Revenue grew nineteen percent.")
    }

    /// The desktop app injects a whole preamble of machine turns — plugin catalogue,
    /// skill manifest, environment block, file digest — before the first thing the
    /// person actually typed.
    func testDropsTheInjectedPreamble() throws {
        let file = try write("rollout-2026-08-10T07-48-29-sess-4.jsonl", #"""
        {"type":"session_meta","payload":{"session_id":"sess-4","timestamp":"2026-08-10T07:48:29.000Z","cwd":"/Users/example/tools","source":"vscode"}}
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<recommended_plugins>\nHere is a list of plugins that are available but not installed.\n</recommended_plugins>"}]}}
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"[$caveman:caveman](/Users/example/.codex/plugins/cache/caveman/skills/caveman/SKILL.md)"}]}}
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>cwd is /Users/example/tools</environment_context>"}]}}
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# Files mentioned by the user:\n\n## Design brief"}]}}
        {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"[external_agent_tool_call: Read]\nfile: /Users/example/tools/notes.md\n[/external_agent_tool_call]"}]}}
        {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"[external_agent_tool_result]\nnotes.md: 40 lines\n[/external_agent_tool_result]"}]}}
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Extend the history copier with a ChatGPT reader."}]}}
        {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Added the reader and its fixture tests."}]}}

        """#)

        let events = source().events(in: file)
        XCTAssertEqual(events.count, 2, "only the real turns survive")
        XCTAssertEqual(events[0].title, "Extend the history copier with a ChatGPT reader")
        XCTAssertFalse(events.contains { $0.text.contains("environment_context") })
    }

    func testMachineTurnDetectionKeepsRealMessages() {
        XCTAssertTrue(ChatGPTDesktopSource.isMachineTurn("<environment_context>\ncwd\n</environment_context>"))
        XCTAssertTrue(ChatGPTDesktopSource.isMachineTurn("<recommended_plugins>\nlist\n</recommended_plugins>"))
        XCTAssertTrue(ChatGPTDesktopSource.isMachineTurn("# Files mentioned by the user:\n\n## Brief"))
        XCTAssertTrue(ChatGPTDesktopSource.isMachineTurn("# AGENTS.md instructions for /Users/example"))
        XCTAssertTrue(ChatGPTDesktopSource.isMachineTurn("[external_agent_tool_call: Bash]\ncommand: ls"))
        XCTAssertTrue(ChatGPTDesktopSource.isMachineTurn("[external_agent_tool_result]\n=== ls ===\n"))
        XCTAssertTrue(ChatGPTDesktopSource.isMachineTurn("[$plugin](/Users/example/.codex/plugins/cache/x/SKILL.md)"))
        XCTAssertFalse(ChatGPTDesktopSource.isMachineTurn("Why does <div> render twice in my app?"))
        XCTAssertFalse(ChatGPTDesktopSource.isMachineTurn("[the docs](https://example.com) say otherwise"))
        XCTAssertFalse(ChatGPTDesktopSource.isMachineTurn("Draft the launch note."))
    }

    /// Delegated threads are the ChatGPT equivalent of Claude Code's nested
    /// `subagents/` transcripts: the work is already reported in the parent.
    func testSkipsSubagentThreads() throws {
        try write("rollout-2026-08-01T10-00-00-main-1.jsonl", #"""
        {"type":"session_meta","payload":{"session_id":"main-1","timestamp":"2026-08-01T10:00:00.000Z","cwd":"/Users/example/app","source":"vscode"}}
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Plan the migration."}]}}
        {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Here is the plan."}]}}

        """#)
        let delegated = try write("rollout-2026-08-01T10-05-00-sub-1.jsonl", #"""
        {"type":"session_meta","payload":{"session_id":"sub-1","timestamp":"2026-08-01T10:05:00.000Z","cwd":"/Users/example/app","source":{"subagent":{"other":"guardian"}},"thread_source":"subagent"}}
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Delegated request."}]}}
        {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Delegated answer."}]}}

        """#)

        XCTAssertTrue(source().events(in: delegated).isEmpty)
        let all = source().discover().flatMap { source().events(in: $0.url) }
        XCTAssertEqual(Set(all.map(\.conversationId)), ["chatgpt:main-1"])
    }

    /// A forked thread replays its parent's `session_meta`, so the second one must not
    /// overwrite the identity of the session actually being read.
    func testForkedSessionKeepsItsOwnIdentity() throws {
        let file = try write("rollout-2026-08-01T12-00-00-fork-child.jsonl", #"""
        {"type":"session_meta","payload":{"session_id":"fork-child","timestamp":"2026-08-01T12:00:00.000Z","forked_from_id":"fork-parent","cwd":"/Users/example/child","source":"vscode"}}
        {"type":"session_meta","payload":{"session_id":"fork-parent","timestamp":"2026-07-13T18:08:21.000Z","cwd":"/Users/example/parent","source":"vscode"}}
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Continue where we left off."}]}}
        {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Resuming the migration."}]}}

        """#)

        let events = source().events(in: file)
        XCTAssertEqual(events.first?.conversationId, "chatgpt:fork-child")
    }

    /// A rollout with no readable turns falls back to the project name rather than
    /// being titled by whatever machine block came first.
    func testFallbackTitleUsesTheProjectDirectory() throws {
        let file = try write("rollout-2026-08-01T13-00-00-sess-5.jsonl", #"""
        {"type":"session_meta","payload":{"session_id":"sess-5","timestamp":"2026-08-01T13:00:00.000Z","cwd":"/Users/example/widget","source":"vscode"}}
        {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Picking up where the last thread stopped."}]}}

        """#)

        let events = source().events(in: file)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].title, "ChatGPT — widget")
    }

    // MARK: - Discovery

    func testDiscoveryTakesRolloutFilesOnlyAndNeverLeavesSessions() throws {
        try write("rollout-2026-08-01T10-00-00-main-1.jsonl", "{}\n")
        try write("notes.jsonl", "{}\n")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        // Credentials live one level up from the root and must stay unreachable.
        try Data(#"{"tokens":{"access_token":"secret"}}"#.utf8)
            .write(to: root.appendingPathComponent("auth.json"))

        let discovered = source().discover()
        XCTAssertEqual(discovered.map(\.url.lastPathComponent), ["rollout-2026-08-01T10-00-00-main-1.jsonl"])
        XCTAssertEqual(source().root.lastPathComponent, "sessions")
        XCTAssertFalse(discovered.contains { $0.url.path.contains("auth.json") })
    }

    func testMissingSessionsDirectoryIsNotAnError() {
        let missing = ChatGPTDesktopSource(
            root: root.appendingPathComponent("nope"),
            imports: imports
        )
        XCTAssertTrue(missing.discover().isEmpty)
    }

    func testDefaultRootIsTheDesktopAppSessionStore() {
        XCTAssertTrue(Paths.chatgptSessions.path.hasSuffix("/.codex/sessions"))
        XCTAssertTrue(Paths.defaultSources().contains { $0.id == RecallSource.chatgpt })
    }

    // MARK: - Dedupe against the account export

    func testConversationAlreadyImportedFromAnExportIsNotIndexedAgain() throws {
        let file = try write("rollout-2026-08-01T14-00-00-shared-1.jsonl", #"""
        {"type":"session_meta","payload":{"session_id":"shared-1","timestamp":"2026-08-01T14:00:00.000Z","cwd":"/Users/example/app","source":"vscode"}}
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Draft the launch note."}]}}
        {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Drafted."}]}}

        """#)
        XCTAssertEqual(source().events(in: file).count, 2, "indexed while the export is absent")

        let imported = RecallEvent(
            source: RecallSource.chatgpt,
            conversationId: "chatgpt:shared-1",
            title: "Draft the launch note",
            ts: Date(),
            role: .user,
            text: "Draft the launch note."
        )
        try RecallEventCodec.encode([imported])
            .write(to: imports.appendingPathComponent("chatgpt-2026-08-02.jsonl"))

        XCTAssertTrue(source().events(in: file).isEmpty, "the export copy already covers it")
    }

    func testAnUnrelatedImportDoesNotSuppressDesktopSessions() throws {
        let file = try write("rollout-2026-08-01T15-00-00-solo-1.jsonl", #"""
        {"type":"session_meta","payload":{"session_id":"solo-1","timestamp":"2026-08-01T15:00:00.000Z","cwd":"/Users/example/app","source":"vscode"}}
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Draft the launch note."}]}}

        """#)
        let other = RecallEvent(
            source: RecallSource.claudeAI,
            conversationId: "claude-ai:something-else",
            title: "Other",
            ts: Date(),
            role: .user,
            text: "Unrelated."
        )
        try RecallEventCodec.encode([other])
            .write(to: imports.appendingPathComponent("claude-ai-2026-08-02.jsonl"))

        XCTAssertEqual(source().events(in: file).count, 1)
    }

    /// The desktop rollout and an account export share the `chatgpt` source id but
    /// not a reader: the transcript view has to pick by where the file lives.
    func testTranscriptOfAnImportedChatGPTConversationStillReadsAsBusJSONL() throws {
        let store = try IndexStore(url: root.appendingPathComponent("index.db"))
        let busFile = imports.appendingPathComponent("chatgpt-2026-08-03.jsonl")
        let event = RecallEvent(
            source: RecallSource.chatgpt,
            conversationId: "chatgpt:web-1",
            title: "Exported thread",
            ts: Date(timeIntervalSince1970: 1_786_000_000),
            role: .user,
            text: "This body only exists in the account export."
        )
        try RecallEventCodec.encode([event]).write(to: busFile)
        let sourceFile = SourceFile(url: busFile, source: RecallSource.imports)
        let chunks = Chunker().chunks(for: [event])
        try store.replaceFile(
            sourceFile,
            conversations: Indexer.conversations(from: [event], chunks: chunks, filePath: busFile.path),
            chunks: chunks.map { (chunk: $0, embedding: nil) }
        )

        let provider = TranscriptProvider(
            store: store,
            sources: [source(), NormalizedJSONLSource(id: RecallSource.imports, root: imports)]
        )
        let transcript = try XCTUnwrap(provider.transcript(for: "chatgpt:web-1"))
        XCTAssertFalse(transcript.reconstructed, "the bus file is still the authority")
        XCTAssertTrue(transcript.text.contains("only exists in the account export"))
    }
}
