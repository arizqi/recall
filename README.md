# Recall

Local vector search over every AI conversation on your Mac, with one-click export.

Native macOS menu-bar app plus a `recall` CLI. Everything runs on this machine:
embeddings and summaries come from Ollama on `127.0.0.1:11434`, the index is a
SQLite file in Application Support, and nothing is ever uploaded.

## What it does

- Indexes Claude Code, Cowork, agent rooms, a drop-in inbox, and ChatGPT exports
  into one searchable corpus.
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
| Cowork | `~/Library/Application Support/Claude/local-agent-mode-sessions/**/audit.jsonl` | Title comes from the sibling `local_*.json`. |
| Rooms | `~/.company-os/hermes-home/company/rooms/*.jsonl` | Just a directory of JSONL. Recall never talks to Company OS and does not care whether it is installed or running. |
| Inbox | `~/Library/Application Support/Recall/inbox/*.jsonl` | The bus: any tool can drop normalized events here. |
| ChatGPT | account export `.zip` | Converted to normalized JSONL under `~/Library/Application Support/Recall/imports/`. Drag the zip onto the window, or `recall import-chatgpt export.zip`. |

Every reader is isolated and covered by a fixture test. These are private storage
formats that change without notice; when one does, the failing fixture tells you
which reader to fix in a minute rather than an afternoon.

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

### sqlite-vec vs. brute force

Recall does **not** use sqlite-vec. Measured on this machine's real corpus — 154
conversations, 6.9k chunks, 768 dimensions — a full brute-force cosine scan with
Accelerate's `vDSP_dotpr` is a few milliseconds; end-to-end search including the
query embedding round-trip to Ollama is ~50-60 ms, and the embedding call dominates.
At 20 MB of vectors per 6.9k chunks, even a 100× larger corpus is a sub-100 ms scan.

An ANN index would buy nothing here and would cost a vendored native extension, a
code-signing story for it, and a second failure mode. The embeddings are stored as
plain BLOBs, so if a corpus ever outgrows the scan, adding sqlite-vec is a migration
of the query path only.

## Search

Vector and keyword results are fused with reciprocal rank fusion (k = 60, vector
weight 1.0, keyword 0.8) rather than by mixing raw scores — cosine similarity and
bm25 are not on a comparable scale, and RRF only needs the orderings. Conversations
rank by their fragments with diminishing returns, so one long thread cannot crowd
out everything else.

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
recall search "deepseek rebind" [--limit N] [--source ID] [--json]
recall export <conversation-id> [--summary] [--out FILE]
recall status
recall import-chatgpt ~/Downloads/export.zip
```

`--json` makes `recall search` scriptable. `--no-embeddings` indexes text only for
a fast first pass; a later run fills the vectors in.

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

## Privacy

- Source files are read, never written.
- Conversation text goes to the local Ollama process and nowhere else.
- No API keys, no accounts, no analytics, no cloud LLM calls — $0 to run.
- The clipboard changes only when you press Copy.
- Deliberately not sandboxed, so it can read the local history stores without a
  folder prompt for every source.
- The index holds your conversations in plaintext. It lives in your home directory
  under normal file permissions; treat `index.db` like the transcripts themselves.
