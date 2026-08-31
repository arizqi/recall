# Recall — session bootstrap

Read this first when starting a fresh AI session on this repo. It is the full
background; the git log is the detailed history.

## What this is

**Recall** is a native macOS menu-bar app + CLI giving local, private vector
search over ALL of Ashar's AI conversation history, with one-click export.
Built 2026-08-20/21 by Claude (Opus builders, PM'd by Claude Fable via the
Company OS Room), iterated through real daily use. Zero cloud calls: embeddings
via Ollama `nomic-embed-text`, summaries via `gemma4:e4b`, everything on disk.

## Why it exists (the bigger idea)

Ashar's realization: he needs "some kind of bus or communication protocol"
across all his AI tools. Recall's answer: **the bus is a directory of
normalized JSONL event files plus an index that watches them.** Any tool that
can append one JSON line joins the bus. The one-page event schema in README.md
IS the protocol: `{source, conversationId, title, ts, role, text,
artifactPaths[]}` dropped into `~/Library/Application Support/Recall/inbox/`.

## Sources it ingests

| Source | Path | Note |
|---|---|---|
| Claude Code | `~/.claude/projects/*/*.jsonl` | top-level sessions only |
| Cowork | `~/Library/Application Support/Claude/local-agent-mode-sessions/**/audit.jsonl` | **sessions after ~2026-08-14 are CLOUD-ONLY** — no transcript bytes land on disk (evidence in README); import the claude.ai export ZIP instead |
| Company OS rooms | `~/.company-os/hermes-home/company/rooms/*.jsonl` | works without Company OS running |
| Drop-in inbox | `~/Library/Application Support/Recall/inbox/` | the bus entry point |
| claude.ai export ZIP | file picker / drag-drop / `recall import` | auto-detected; parses conversations + `design_chats/` + `projects/`; ~3 convos in Ashar's export legitimately have no body |
| ChatGPT export ZIP | same importer | auto-detected by JSON shape |

Related, separate repo: `claude-history-copier` branch
`feature/chatgpt-and-artifacts` — found ChatGPT desktop is actually
`com.openai.codex`; its real transcripts live in
`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` (readable directly).

## Architecture decisions (deliberate, revisit-able)

- **No sqlite-vec.** Brute-force cosine (Accelerate) over BLOB embeddings is
  milliseconds at this scale; the Ollama embedding round-trip dominates query
  time (~55-70ms). Adding ANN later touches only the query path.
- **Hybrid ranking**: RRF over vector + FTS5 keyword. Known gap: literal
  proper nouns (e.g. "Laurel", 209 hits) can under-rank vs semantic matches —
  keyword weighting needs tuning.
- **Index**: `~/Library/Application Support/Recall/index.db`, plaintext
  (unencrypted — known gap). ~98MB for ~190 conversations / ~6.4k chunks.
  Incremental rescan by mtime+size: unchanged rescan ~0.2s; full index
  ~5min (embedding-bound, ~25 chunks/s).
- **UI is a MenuBarExtra(.window) popover** that dismisses on focus loss —
  this caused two shipped bugs (see history). Import therefore opens its own
  real NSWindow with the file picker as a sheet on it.
- Transcripts render as per-message lazy rows, collapsed at 4k chars, split
  (never truncated) at ~20k/row — a single whole-conversation `Text` pinned
  the main thread for minutes on MB-sized sessions (found via process sample).

## Battle scars already fixed (don't reintroduce)

1. Whole-transcript single `Text` → main-thread CoreText hang (4693858).
2. Menu-bar popover ate the NSOpenPanel → import from a real window (45f8c54).
3. Finder drags silently failed via `loadObject(ofClass:)` → file-URL type id.
4. Test fixtures wrote into the REAL imports dir (176-byte ghosts) → tests
   inject temp dirs; imports are loud (success modal with counts, error dialog
   on zero parses, never a silent empty file); uuid dedupe on re-import.

## Using it

```bash
export PATH=/opt/homebrew/bin:$PATH
cd ~/tools_I_want_to_build_and_opensource/recall
xcodegen generate
xcodebuild -project Recall.xcodeproj -scheme Recall -configuration Release -derivedDataPath DerivedData build
open DerivedData/Build/Products/Release/Recall.app
# CLI
DerivedData/Build/Products/Release/recall index
DerivedData/Build/Products/Release/recall search "deepseek rebind" --since 7d
DerivedData/Build/Products/Release/recall export <conversation-id> --out /tmp/x.md
DerivedData/Build/Products/Release/recall import ~/Downloads/export.zip
```

Tests: `xcodebuild test` (78+ green as of last session). Node 16 at
`/usr/local/bin/node` shadows Homebrew node — always prepend
`/opt/homebrew/bin` to PATH.

## Open gaps / natural next increments

- No filesystem watcher — indexing is manual/on-demand.
- Keyword-vs-vector weighting (the "Laurel" under-rank).
- Index is plaintext on disk.
- Artifact extraction (paths a conversation created) exists in
  claude-history-copier's `ArtifactExtractor`; porting into Recall was
  started and then **cancelled by Ashar** — do not re-add unasked.
- Two ranking heuristics tuned by eye, not measured.
