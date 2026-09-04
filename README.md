# Recall

Local vector search over every AI conversation on your Mac, with one-click export.

Native macOS menu-bar app plus a `recall` CLI. Everything runs on this machine:
embeddings and summaries come from Ollama on `127.0.0.1:11434`, the index is a
SQLite file in Application Support, and nothing is ever uploaded.

Recall is early-stage software for macOS 14 and later. Build it from source;
prebuilt, signed releases are not available yet.

## What it does

- Indexes Claude Code, the ChatGPT desktop app, Cowork, agent rooms, a drop-in
  inbox, and account exports into one searchable corpus.
- Hybrid search: vector similarity (nomic-embed-text) fused with FTS5 keyword
  search, grouped by conversation with a source badge and date.
- Full transcript view with artifact paths, existence-checked, revealable in Finder.
- One-click markdown export — full transcript or a local summary — with an
  `Artifacts:` list of real paths. `⇧⌘C` copies it.
- Incremental: only files whose mtime or size changed are re-read.

## Sources

| Source | Location | Notes |
| --- | --- | --- |
| Claude Code | `~/.claude/projects/*/*.jsonl` | Top-level sessions only; nested `subagents/` transcripts are skipped as duplicates. |
| Cowork | `~/Library/Application Support/Claude/local-agent-mode-sessions/**/audit.jsonl` | Title comes from the sibling `local_*.json`. Local transcripts stop after 2026-08-14 — see below. |
| Rooms | `~/.company-os/hermes-home/company/rooms/*.jsonl` | Just a directory of JSONL. Recall never talks to Company OS and does not care whether it is installed or running. A room is an append-only log, so it is indexed one conversation per day. |
| Inbox | `~/Library/Application Support/Recall/inbox/*.jsonl` | The bus: any tool can drop normalized events here. |
| ChatGPT desktop | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` | The ChatGPT macOS app is code-signed `com.openai.codex` and writes its full transcripts here, so they are indexed automatically like Claude Code — no export needed. Delegated (subagent) threads are skipped as duplicates of their parent, a forked thread keeps its own identity even though it replays its parent's `session_meta`, and the app's injected preamble (plugin catalogue, skill manifest, environment block, file digest) plus its `[external_agent_tool_call/result]` plumbing is dropped. Only `sessions/` is read: `~/.codex/auth.json` holds credentials and is outside the source root. |
| ChatGPT | account export `.zip` | Converted to normalized JSONL under `~/Library/Application Support/Recall/imports/`. Drag the zip onto the window, or `recall import export.zip`. A conversation already imported this way is skipped by the desktop reader, so the two never double-index. |
| claude.ai | account export `.zip` (one per category) | Same path. This is where Cowork and web chats live now. Since 2026-08 the export arrives as one zip per category — `conversations-000.zip`, `design_chats-000.zip`, `projects-000.zip`, `memories-000.zip`, `light_metadata-000.zip` — and a big account splits each category into numbered parts. Drop them all at once, or drop the folder; they are merged into one import and a conversation seen in two parts lands once (newest `updated_at` wins). Older single-zip exports (`…batch-0000.zip`) still work. Detection is by what is inside the archive, not by its name. `memories/` is indexed; `light_metadata` (users, login history) is recognized and skipped without an error. Re-importing is safe — conversations already imported are skipped by uuid. |
| claude.ai download manifest | `manifest-….json` | The small JSON the export page hands over, pointing at one **single-use** download URL per category. Drop it on the Import window and Recall shows what it would fetch; nothing is opened until you say yes. On yes it opens each link in your **default browser** — the browser holds the claude.ai session, Recall never touches a cookie or a credential — strictly one at a time, waits for each zip to finish landing in `~/Downloads`, imports it, then moves to the next. The server takes 60–120s to build each zip, so waits are long by design; opening links in parallel cancels the download in flight and burns the link for good. A link that times out is reported, never retried. The zips stay in `~/Downloads`. `recall import manifest-….json` lists the files; add `--download` to run the same flow from the terminal. |

Every reader is isolated and covered by a fixture test. These are private storage
formats that change without notice; when one does, the failing fixture tells you
which reader to fix in a minute rather than an afternoon.

### Cowork after 2026-08-14: cloud-only

Claude Desktop moved Cowork to remote sessions, and it no longer writes transcripts
to this Mac. Verified on 2026-08-20:

- the newest `audit.jsonl` anywhere under the session directory is dated 2026-08-14,
  while the directory itself is written every day;
- `remote-session-spaces.json` (current) records server-side `session_01…` ids and
  the folders each session may read — no message content;
- the Cowork VM image `vm_bundles/claudevm.bundle/sessiondata.img` contains no string
  newer than 2026-08-04, and the `.claude/projects/*.jsonl` paths inside it are from
  March–April;
- the `cowork-artifact` and `cowork-file-preview` partitions hold only Chromium
  caches, and the `claude.ai` IndexedDB `keyval-store` holds composer drafts, not
  transcripts;
- no other recent `.jsonl` exists anywhere under `~` outside the known sources.

A claude.ai export commonly contains conversations with no message body at all —
titles and timestamps only. Those are skipped and counted, and the count is reported
after the import, so "32 conversations in, 16 indexed" is an answer rather than a
mystery. An import that yields nothing raises an error and writes no file.

Recall detects this rather than asserting it: when the Cowork directory keeps being
written but the newest indexed transcript is more than three days older, the UI shows
a coverage row saying the sessions are cloud-only and pointing at the export. To
search them, request a claude.ai account export and import the zip.

Missing directories are reported, not hidden — a source you do not have shows as
"no directory at …" instead of silently contributing nothing.

## The bus protocol

The inbox is the integration point. Write UTF-8 JSONL — one JSON object per line —
into `~/Library/Application Support/Recall/inbox/`, and it becomes searchable on the
next index run. No API, no daemon, no schema registry.

```json
{"source":"linear","conversationId":"linear:ENG-412","title":"Ship the indexer","ts":"2026-08-19T13:29:50.309Z","role":"user","text":"Rebind the builder model","artifactPaths":["/Users/you/recall/Sources/Core/Indexer.swift"]}
```

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `source` | string | yes | Free-form origin id. Becomes the badge in the UI and the `--source` filter. Well-known values: `claude-code`, `cowork`, `room`, `inbox`, `chatgpt`. |
| `conversationId` | string | yes | Groups events into one conversation. Namespace it (`tool:id`) so ids never collide across sources. |
| `title` | string | no | Conversation title. Empty means "derive one from the first user turn". |
| `ts` | string \| number | no | ISO-8601, epoch seconds, or epoch milliseconds. Missing timestamps inherit from the previous event. |
| `role` | string | no | `user`, `assistant`, `system`, or `tool`. Synonyms (`human`, `model`, `agent`, `turn`, `function`) are mapped; anything unknown becomes `system` rather than being dropped. |
| `text` | string | yes | The message body. Empty text is skipped. |
| `artifactPaths` | string[] | no | Absolute paths this message produced or touched. If omitted, Recall scans the text for absolute paths. |

Rules the ingest side guarantees:

- A line that is not a Recall event is skipped, not fatal — mixed-content files still index.
- One file is one unit of work: reindexed atomically, and it can hold many conversations.
- Files are keyed by path. Rewrite the same file to update its events; delete it to
  remove them from the index on the next run.
- Recall only ever reads your source files.

## Index

SQLite at `~/Library/Application Support/Recall/index.db`:

- `chunks` — chunk text plus a unit-length float32 embedding BLOB.
- `chunks_fts` — FTS5 (`porter unicode61`) over the same text.
- `conversations`, `files` — grouping and incremental state (mtime + size).

Chunks are ~4,000 characters with 400 characters of overlap — roughly 1k tokens,
inside nomic-embed-text's window even for code-heavy text. Role labels stay in the
chunk text so a retrieved fragment reads on its own.

Indexing is resumable: each file commits in its own transaction and is only recorded
once its chunks are in, so an interrupted run resumes exactly where it stopped.

Throughput on an M-series Mac is ~22 chunks/second, embedding-bound: a first full
index of 155 files took 4m47s, and a rescan that finds nothing changed takes 0.2s.
Most of a Claude Code transcript never reaches the index — 134 MB of raw JSONL on
this machine held 0.3 MB of actual conversation, the rest being tool results.

### sqlite-vec vs. brute force

Recall does **not** use sqlite-vec. Measured on a real corpus — 157 conversations,
6.2k chunks, 768 dimensions, a 98 MB index — a full brute-force cosine scan with
Accelerate's `vDSP_dotpr` is a few milliseconds; end-to-end search including the
query's embedding round-trip to Ollama is 55-70 ms, and the embedding call dominates.
At 18 MB of vectors per 6.2k chunks, even a 100× larger corpus is a sub-second scan.

An ANN index would buy nothing here and would cost a vendored native extension, a
code-signing story for it, and a second failure mode. The embeddings are stored as
plain BLOBs, so if a corpus ever outgrows the scan, adding sqlite-vec is a migration
of the query path only.

## Search

Vector and keyword results are fused with reciprocal rank fusion (k = 60, vector
weight 1.0, keyword 0.8) rather than by mixing raw scores — cosine similarity and
bm25 are not on a comparable scale, and RRF only needs the orderings. A conversation
scores from its best five fragments with diminishing returns, so several good hits
beat one lucky hit while a sprawling thread that mentions the topic forty times in
passing cannot crowd out the short conversation that is actually about it.

Results are **newest first by default** — most of the time "what did I say about X"
means the most recent time you said it — with a visible Date ↔ Relevance toggle when
you want the strongest match instead. Either way the candidate pool is chosen by
relevance first, so date order ranks the relevant, not the merely recent.

A date filter narrows both search and the browse list: presets in the UI, and
`--since` / `--until` on the CLI taking either a calendar date (`2026-08-19`) or a
relative span (`7d`, `2w`, `3m`, `1y`). A date the CLI cannot parse is an error, not
a silent "any time" — searching the wrong window looks exactly like missing data.

With an empty query the window is a browse list of the newest conversations.

If Ollama is not running, search degrades to keyword-only instead of returning
nothing, and says so in the footer.

## Export

`⇧⌘C`, the Copy button, or `recall export`. The bundle is self-contained markdown:
title, source, dates, conversation id, source file path, then either the full
transcript or a local summary (`gemma4:e4b`), then an `## Artifacts` list where paths
that no longer exist are marked `_(missing)_` rather than quietly dropped.

## CLI

```bash
recall index [--force] [--no-embeddings] [--max-files N] [--source ID]
recall search "deepseek rebind" [--limit N] [--source ID] [--since 7d] [--until 2026-08-19]
                                [--sort date|relevance] [--json]
recall recent [--limit N] [--source ID] [--since 7d] [--json]
recall export <conversation-id> [--summary] [--out FILE]
recall status
recall import ~/Downloads/export.zip        # ChatGPT or claude.ai, detected from the file
recall import ~/Downloads/conversations-000.zip ~/Downloads/memories-000.zip [--to DIR]
recall import ~/Downloads                   # every export zip in a folder, merged
recall import ~/Downloads/manifest-….json [--download] [--downloads DIR] [--timeout SEC]
```

`--json` makes `recall search` and `recall recent` scriptable. `--no-embeddings`
indexes text only for a fast first pass; a later run fills the vectors in.

## Build

Requires Xcode 15+, XcodeGen, and Ollama with `nomic-embed-text` (embeddings) and
optionally `gemma4:e4b` (summaries).

```bash
brew install xcodegen
ollama pull nomic-embed-text

xcodegen generate
xcodebuild -project Recall.xcodeproj -scheme Recall \
  -configuration Release -derivedDataPath DerivedData build
open DerivedData/Build/Products/Release/Recall.app
```

The CLI:

```bash
xcodebuild -project Recall.xcodeproj -scheme RecallCLI \
  -configuration Release -derivedDataPath DerivedData build
cp DerivedData/Build/Products/Release/recall /usr/local/bin/recall
```

Tests:

```bash
xcodebuild -project Recall.xcodeproj -scheme Recall \
  -destination 'platform=macOS' -derivedDataPath DerivedData test
```

Recall is a menu-bar app (`LSUIElement`): it has no Dock icon. Click the clock icon
in the menu bar, or launch it at login via System Settings → General → Login Items.

## Importing from a menu-bar app

Recall's main UI is a menu-bar popover, which macOS dismisses the moment focus
leaves it. Opening a file picker straight from the popover therefore tore the
popover down and lost the picker behind everything. So **Import opens its own real
window** ("Import export") with a drop zone and a Choose file… button; the open
panel is presented as a sheet on that window, which cannot slip behind its host.
Drag-and-drop onto the main window still works too.

## Privacy

- Source files are read, never written.
- Conversation text goes to the local Ollama process and nowhere else.
- No API keys, no accounts, no analytics, no cloud LLM calls — $0 to run.
- The clipboard changes only when you press Copy.
- Deliberately not sandboxed, so it can read the local history stores without a
  folder prompt for every source.
- The index holds your conversations in plaintext. It lives in your home directory
  under normal file permissions; treat `index.db` like the transcripts themselves.

## Contributing and security

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) before opening
a pull request. Please report vulnerabilities privately as described in
[SECURITY.md](SECURITY.md), especially if a report could expose transcript data or
local filesystem paths.

Recall is available under the [MIT License](LICENSE).
