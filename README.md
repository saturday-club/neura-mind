# AutoLog

Your screen, understood.

```bash
brew install --cask AmitSubhash/tap/autolog
```

AutoLog is a macOS menu bar app that watches what you do on your computer and builds a searchable activity knowledge graph from it. It captures your screen via OCR, infers what you're working on using an LLM, connects related activities across apps, and syncs everything to an Obsidian vault as linked notes.

Think of it as ambient memory for your workday -- not a surveillance tool, but a personal context engine that remembers what you were doing, in which apps, with which files, so you never lose track.

---

## Table of Contents

- [What it captures](#what-it-captures)
- [Capture pipeline](#capture-pipeline)
- [The knowledge graph](#the-knowledge-graph)
- [Summarization](#summarization)
- [Prompt enrichment](#prompt-enrichment)
- [Obsidian integration](#obsidian-integration)
- [Focus workflow](#focus-workflow)
- [Supporting scripts](#supporting-scripts)
- [Menu bar UI](#menu-bar-ui)
- [Architecture](#architecture)
- [API reference](#api-reference)
- [LLM proxy](#llm-proxy)
- [MCP bridge](#mcp-bridge)
- [Shell hooks](#shell-hooks)
- [Setup](#setup)
- [Configuration](#configuration)
- [Background services](#background-services)
- [Cost](#cost)
- [Privacy](#privacy)
- [Credits](#credits)

---

## What it captures

Every few seconds, AutoLog takes a screenshot, runs full-screen OCR, and extracts:

- **Screen text** -- everything visible, not just the active window
- **App metadata** -- which app is frontmost, its window title, document path, browser URL
- **All visible windows** -- every app with a window open, via Accessibility API
- **Focused element** -- what UI element has keyboard focus (text field, web area, etc.)

This raw data flows through a pipeline:

```
screenshot --> OCR --> capture record --> summarization (Haiku) --> activity inference --> Obsidian sync
                                              |                          |
                                         app sessions              knowledge graph
                                       (time per app)          (cross-activity links)
```

---

## Capture pipeline

AutoLog uses a five-stage pipeline to turn screenshots into structured records efficiently.

### Stage 1: Screenshot

`ScreenCapture.swift` takes a screenshot using `CGDisplayCreateImage` (CoreGraphics) -- not ScreenCaptureKit -- to avoid macOS permission re-prompts on every launch. Images wider than 1920px are automatically downscaled before processing.

### Stage 2: Accessibility metadata

`AccessibilityReader.swift` reads app context in parallel with the screenshot:
- Frontmost app name and bundle ID
- Active window title (requires Accessibility permission)
- All visible windows across all apps
- Focused UI element and its role (text field, web area, button, etc.)

`AppMetadataReader.swift` reads document paths, browser URLs, and focused element info from the same Accessibility tree.

### Stage 3: Pixel diffing

`ImageDiffer.swift` uses SIMD-accelerated comparison to decide whether the new frame is worth processing:

- Divides the screen into 32×32 pixel tiles
- 4% per-channel noise threshold filters out cursor blink and sub-pixel rendering
- Changed tile regions are merged into bounding boxes
- Returns the ratio of changed pixels vs. total pixels

Frame classification:
| Frame type | Condition | OCR scope |
|-----------|-----------|-----------|
| **KEYFRAME** | First capture, app switch, 60s time cap, or ≥50% pixel change | Full screen |
| **DELTA** | < 50% pixel change, same app | Changed regions only |
| **SKIP** | 0% change | None (triggers adaptive backoff) |

This compression means AutoLog avoids redundant OCR when you're reading a static page -- it only processes what actually changed.

### Stage 4: OCR

`OCRProcessor.swift` uses Apple's Vision framework (`VNRecognizeTextRequest`) to extract text:
- Full-screen OCR on keyframes
- Region-limited OCR on deltas (only the changed bounding boxes)
- Text is normalized: lowercase, collapsed whitespace, deduplicated by hash

### Stage 5: App session detection

`AppSessionDetector.swift` (actor) watches for app switches and time gaps to emit session boundaries. Contiguous use of the same app is grouped into a single session with aggregated metadata (all window titles, paths, and URLs seen during the session).

### Adaptive interval

When SKIP frames are returned consecutively, the capture interval backs off exponentially (up to a configured maximum). This keeps CPU usage low when you're idle or reading without scrolling. The interval resets immediately on the next DELTA or KEYFRAME.

---

## The knowledge graph

AutoLog doesn't just store flat summaries. It builds structure across four layers:

**App Sessions** -- contiguous stretches of using one app, with aggregated metadata (all window titles, document paths, URLs seen during the session).

**Activities** -- LLM-inferred tasks that span one or more app sessions. "Debugging the capture pipeline" might involve Terminal (building), Safari (reading docs), and Xcode (editing code) -- AutoLog groups these into one coherent activity with a human-readable name.

**Entities** -- files, URLs, and topics extracted from activities, queryable independently ("show me everything involving this file").

**Cross-activity links** -- activities connected by shared files, URLs, or topics. If you edited `CaptureEngine.swift` in two different sessions hours apart, AutoLog links those two activities together so you can reconstruct your whole context.

### Activity inference

`ActivityInferenceEngine.swift` runs in the background every 5 minutes. It:
1. Fetches uninferred app sessions in 2-hour windows
2. Batches 2–15 sessions per LLM call
3. Uses Haiku to group sessions into named activities and extract entities
4. Persists activities, entities, and cross-links into the database
5. Rebuilds cross-activity links via `ActivityGraphBuilder.swift`

---

## Summarization

`SummarizationEngine.swift` runs in the background every 60 seconds. It:
1. Finds capture records that are at least 5 minutes old and not yet summarized
2. Chunks them into 5-minute windows, splitting on app boundaries
3. Calls Haiku via the local LLM proxy to generate a short summary per chunk
4. Stores each summary with activity type, files, URLs, and topics
5. Marks processed captures for pruning after 72 hours

`Chunker.swift` handles grouping: captures within the same 5-minute window stay together, but an app switch always forces a new chunk so summaries don't mix unrelated context.

---

## Prompt enrichment

The enrichment panel lets you paste any prompt and get relevant screen context injected as footnotes before you send it to an LLM.

**How to open it:** `Cmd+Shift+Space` (configurable) -- opens a floating panel anywhere on screen.

**How it works:**
1. You type or paste a prompt
2. AutoLog runs a retrieval strategy against stored summaries and activities
3. Relevant context is appended as footnotes with citations
4. You paste the enriched prompt into any chat interface

**Two retrieval strategies:**

| Strategy | Description |
|----------|-------------|
| **Single-pass** | Direct semantic search over summaries using TF-IDF similarity |
| **Two-pass LLM** | First pass: candidate retrieval. Second pass: Haiku re-ranks candidates by relevance to the query |

The two-pass strategy is more accurate for complex queries but slightly slower.

---

## Obsidian integration

AutoLog syncs to an Obsidian vault with `[[wikilinks]]` so you can explore your work history in Obsidian's graph view.

```bash
# Sync last 4 hours to vault
python3 scripts/obsidian-sync.py 4
```

The sync script generates four types of notes:

**Activity notes** -- named by what you did, not when. Each note includes:
- Apps used and duration
- Files touched, URLs visited
- Extracted topics
- Links to related activities

**App notes** -- per-app stats:
- Total usage time
- Recent window titles
- Files and URLs seen in this app
- Which activities involved this app

**Topic notes** -- one note per extracted entity (file, URL, or topic), linking back to every activity where it appeared.

**Daily notes** -- per-day summary:
- App usage table (time per app)
- Activity list for the day
- Focus block entries (if focus integration is active)

All notes use wikilinks so Obsidian's graph view shows how activities connect through shared files, topics, and time.

### Vault maintenance scripts

```bash
# Remove duplicate notes and stale links
python3 scripts/consolidate-vault.py

# Rebuild missing summaries from raw captures
python3 scripts/backfill_summaries.py
```

---

## Focus workflow

AutoLog can also track declared focus blocks, not just passive activity. The model is:

- **Emacs/Org owns intent** -- what you said you were trying to do
- **AutoLog owns evidence** -- what apps, sessions, and artifacts actually happened

This creates a useful separation: planning lives in Org, but productivity and drift are judged from captured behavior.

### File contract

Focus blocks are stored as small local files:

- `~/.config/autolog/focus-state.json` -- the current active block
- `~/.config/autolog/focus-blocks.jsonl` -- completed/interrupted block history
- `~/org/today.org` -- daily dashboard
- `~/org/autolog-scorecard.org` -- review log

When you start a block, Emacs writes the declared task, done condition, artifact goal, and drift budget. When you stop a block, AutoLog appends the finalized block to the log and writes a compact Org review entry to the scorecard.

### Emacs commands

The helper script lives at `scripts/autolog-focus.el` and is intended to be loaded from your Doom config. The default keybindings are:

```text
SPC n z s  start focus block
SPC n z e  stop focus block
SPC n z t  show current active block
SPC n z l  show recent blocks
SPC n z p  show productivity summary
SPC n z c  open scorecard
SPC n z d  open today dashboard
```

Starting a block prompts for:
- task
- done condition
- artifact goal
- drift budget in minutes

Stopping a block prompts for:
- actual artifact produced
- self-score `/10`
- notes on drift or execution

### Focus block CLI

```bash
# Start a block
python3 scripts/focus_state.py start \
  --task "Write preprocessing note" \
  --done-when "one final draft exists" \
  --artifact-goal "saved note" \
  --drift-budget 10

# Show current block
python3 scripts/focus_state.py status

# Show recent blocks
python3 scripts/focus_state.py list --include-open --limit 10

# Show 7-day productivity summary
python3 scripts/focus_state.py productivity --days 7
```

### Productivity metrics

Recent productivity is computed directly from focus-block history. The report tracks:

| Metric | Description |
|--------|-------------|
| Total blocks | All blocks in the window |
| Completion rate | % of blocks marked done |
| Artifact rate | % of blocks that produced an artifact |
| Total focus time | Sum of all block durations |
| Completed focus time | Sum of completed block durations only |
| Average block length | Mean duration per block |
| Deep blocks | Blocks ≥ 60 minutes |
| Average self-score | Mean of all `/10` self-ratings |
| Completed-day streak | Consecutive days with ≥1 completed block |
| Daily breakdown | Per-day block counts and focus time |

---

## Supporting scripts

A set of Python scripts extend AutoLog with LLM-driven reflection and synthesis.

### Nightly digest (`scripts/nightly-digest.py`)

Generates a short written digest of the past 24 hours using Haiku. Run via launchd nightly:

```bash
python3 scripts/nightly-digest.py
```

Output is saved to the Obsidian vault as a dated note.

### Daily reflection (`scripts/daily-reflection.py`)

Uses Claude Opus to write a deeper reflection on the day's activities, highlighting patterns, progress, and next-day priorities:

```bash
python3 scripts/daily-reflection.py
```

### Mental map (`scripts/mental-map.py`)

Synthesizes a "thinking map" from recent activities -- a structured view of what projects and topics you've been mentally active in:

```bash
python3 scripts/mental-map.py
```

---

## Menu bar UI

AutoLog lives entirely in the macOS menu bar. The icon reflects capture state:

| Icon | State |
|------|-------|
| `eye` | Recording (idle, no recent capture) |
| `eye.fill` | Recording (just captured a frame) |
| `eye.slash` | Paused |
| `lock.shield` | Privacy mode (excluded app is frontmost) |
| `moon` | System sleep / display off |
| `exclamation` | Error (permission denied, LLM failure) |

The eye "winks" briefly on each successful capture so you can see it's working.

Clicking the menu bar icon opens a popover with:
- Current capture status and last capture time
- Recent summaries (scrollable)
- App usage breakdown for the current session
- Toggle to pause/resume capture
- Button to open the enrichment panel
- Links to settings and debug timeline

### Settings

The settings window has two tabs:

**General:**
- LLM endpoint URL
- Capture speed: `fast` (5s), `medium` (10s), `slow` (30s)
- Adaptive interval toggle
- API server port

**Privacy:**
- Permission status for Screen Recording and Accessibility
- App demotion list (apps whose captures are deprioritized or skipped)

### Debug timeline

The debug window shows an interactive timeline of captured frames:
- Keyframe vs. delta vs. skip classification per frame
- Pixel diff percentage and changed-region bounding boxes
- OCR text preview per frame
- Database record inspection

### Onboarding

First launch shows a permission grant flow:
1. Screen Recording permission (required for screenshots)
2. Accessibility permission (required for window titles and app metadata)

AutoLog blocks capture until both permissions are granted, then proceeds automatically.

---

## Architecture

| Component | What it does |
|-----------|-------------|
| `ScreenCapture.swift` | Screenshots via CoreGraphics `CGDisplayCreateImage` |
| `OCRProcessor.swift` | Full-screen and regional text recognition via Apple Vision |
| `AccessibilityReader.swift` | Window titles and app metadata via AXUIElement + NSWorkspace |
| `AppMetadataReader.swift` | Document paths, URLs, focused element role via Accessibility API |
| `ImageDiffer.swift` | SIMD-accelerated pixel diffing with tile-based comparison |
| `AppSessionDetector.swift` | Real-time app session boundary detection (actor) |
| `SummarizationEngine.swift` | 5-min chunk summarization via Haiku LLM |
| `ActivityInferenceEngine.swift` | Batched LLM inference to group sessions into named activities |
| `ActivityGraphBuilder.swift` | Entity extraction and cross-activity link discovery |
| `EnrichmentEngine.swift` | Real-time prompt enrichment with retrieval strategies |
| `APIServer.swift` | Embedded HTTP API via Hummingbird on port 21890 |
| `obsidian-sync.py` | Vault sync with rich activity/app/topic/daily notes |

### Database

SQLite via GRDB with 10 migrations, WAL mode for concurrent reads, and FTS5 full-text search:

| Table | Purpose |
|-------|---------|
| `captures` | Raw OCR text + metadata per screenshot |
| `summaries` | LLM-generated summaries with activity type, files, URLs |
| `app_sessions` | Contiguous app usage stretches |
| `activities` | LLM-inferred named tasks |
| `activity_sessions` | M:N link between activities and sessions |
| `activity_entities` | Files, URLs, topics per activity |
| `activity_links` | Cross-activity connections (shared files or topics) |
| `token_usage` | Per-call LLM token tracking |
| `captures_fts` | FTS5 index over capture text |
| `summaries_fts` | FTS5 index over summary text |

Database location: `~/Library/Application Support/ContextD/autolog.db`

---

## API reference

Local HTTP API on port 21890. All endpoints except `/health` require a bearer token.

```
GET  /v1/summaries                  -- recent summaries (filter by app, time range)
GET  /v1/sessions                   -- app sessions with metadata
GET  /v1/app-usage                  -- time-per-app breakdown
GET  /v1/activities                 -- inferred activities
GET  /v1/activities/:id/sessions    -- sessions belonging to an activity
GET  /v1/activities/:id/related     -- activities linked via shared entities
GET  /v1/graph                      -- full activity graph (nodes + edges)
GET  /v1/entities                   -- query entities by type (file, url, topic) or value
GET  /v1/focus/current              -- active focus block + live drift snapshot
GET  /v1/focus/blocks               -- recent focus block history
POST /v1/search                     -- full-text search across summaries and captures
POST /v1/semantic-search            -- TF-IDF similarity search
GET  /health                        -- health check (no auth required)
GET  /openapi.json                  -- OpenAPI 3.1 spec
GET  /docs                          -- interactive Scalar API docs
```

---

## LLM proxy

`llm-proxy/` is a small Python HTTP server that wraps `claude -p` (Claude Code's headless CLI) and exposes it as an OpenAI-compatible chat completions endpoint. AutoLog uses this instead of calling the Anthropic API directly, so LLM calls stay local and go through your existing Claude Code auth.

### Features

- OpenAI `chat.completions` format (drop-in replacement)
- Priority queue: Sonnet/Opus requests (interactive) are served before Haiku requests (background)
- In-memory response caching for repeated prompts
- Up to 5 concurrent `claude -p` subprocesses
- Token usage tracking with a `/stats` endpoint
- Graceful shutdown

### Running the proxy

```bash
cd llm-proxy
pip install -e .
python -m claude_proxy
```

The proxy binds to `0.0.0.0` on a configurable port. Set `llmEndpointURL` in AutoLog settings to point at it.

### Supported models

| Model alias | Underlying model |
|-------------|-----------------|
| `haiku` | Claude Haiku (used for background summarization) |
| `sonnet` | Claude Sonnet (used for enrichment) |
| `opus` | Claude Opus (used for daily reflection) |

---

## MCP bridge

`mcp-bridge/` is a FastMCP server that exposes the AutoLog HTTP API as MCP tools, so Claude Code can read your screen context directly in its context window.

### Setup

```bash
cd mcp-bridge
pip install -e .
python contextd_mcp.py
```

Add the MCP server to your Claude Code config to enable it.

### Available tools

| Tool | Description |
|------|-------------|
| `search_screen_context` | Full-text or semantic search over summaries and captures |
| `get_recent_activities` | Fetch inferred activities with entities |
| `get_app_usage` | Time-per-app breakdown for a time range |
| `browse_by_time` | Retrieve summaries around a specific timestamp |
| `query_entities` | Look up all activities involving a file, URL, or topic |
| `get_focus_block` | Current active focus block and drift |
| `health_check` | Verify AutoLog is running and reachable |

---

## Shell hooks

`hooks/` contains shell integration scripts that inject your recent screen context into shell sessions and tool invocations:

- **zsh hook** -- adds a precmd that annotates shell prompts with the current focus block name
- **git hook** -- prepends active activity context to commit message templates
- **tmux hook** -- updates the tmux status bar with current activity and focus block

Source the relevant hook from your shell config:

```bash
source ~/autolog/hooks/autolog.zsh
```

---

## Setup

### Requirements

- macOS 14+ (Sonoma or later)
- Swift 6.0+
- Python 3.11+ (for proxy, sync scripts, MCP bridge)
- Screen Recording permission
- Accessibility permission
- `claude` CLI installed and authenticated (for LLM calls)

### Build and run

```bash
# Debug build
swift build

# Optimized release build
make release

# Create app bundle with icon and entitlements
make bundle

# Install to /Applications/AutoLog.app (preserves TCC permissions)
make install-app

# Run directly
make run
```

Grant Accessibility permission when prompted on first launch. Screen Recording permission is requested via the onboarding flow.

### Other build targets

```bash
make test        # Run Swift unit tests
make benchmark   # Run ImageDiffer SIMD benchmarks
make watch       # Rebuild automatically on file changes
make clean       # Remove build artifacts
```

### LLM proxy setup

```bash
cd llm-proxy
pip install -e .
python -m claude_proxy &
```

Then set `llmEndpointURL` in AutoLog settings to `http://127.0.0.1:<port>/v1/chat/completions`.

### MCP bridge setup

```bash
cd mcp-bridge
pip install -e .
python contextd_mcp.py &
```

Then add the MCP server URL to your Claude Code settings.

### Obsidian sync

```bash
# Sync last 4 hours
python3 scripts/obsidian-sync.py 4

# Sync last 24 hours
python3 scripts/obsidian-sync.py 24
```

Set up as a launchd agent for automatic hourly sync (plist templates in `launchd/`).

---

## Configuration

AutoLog uses `UserDefaults` for persistent configuration. All settings are exposed in the Settings window and can also be set via `defaults write`.

| Setting | Default | What it controls |
|---------|---------|-----------------|
| `llmEndpointURL` | -- | LLM proxy URL (e.g., `http://127.0.0.1:11434/v1/chat/completions`) |
| `captureSpeed` | `medium` | Capture frequency: `fast` (5s), `medium` (10s), `slow` (30s) |
| `adaptiveIntervalEnabled` | `true` | Back off capture rate when screen is idle |
| `apiServerPort` | `21890` | Local API server port |
| `hasCompletedOnboarding` | `false` | Whether the permission grant flow has been completed |

Privacy exclusions (apps skipped during capture) are managed in the Privacy tab of Settings. Password managers and System Settings are excluded by default. AutoLog's own windows are always excluded.

---

## Background services

`launchd/` contains plist templates for 7 background services. Install them with `launchctl load`:

| Service | Schedule | Purpose |
|---------|----------|---------|
| `com.contextd.app` | At login | AutoLog app itself |
| `com.contextd.llm-proxy` | At login | LLM proxy server |
| `com.contextd.obsidian-sync` | Hourly | Vault sync |
| `com.contextd.nightly-digest` | Nightly | Haiku digest generation |
| `com.contextd.daily-reflection` | Daily | Opus reflection |
| `com.contextd.consolidate` | Weekly | Vault deduplication |
| `com.contextd.mental-map` | Daily | Thinking map synthesis |

Edit the plist files to set the correct paths for your environment before loading.

---

## Cost

LLM calls go through the local `claude -p` proxy using Haiku for background tasks:

| Task | Cost/call | Frequency | Daily cost |
|------|-----------|-----------|-----------|
| Summarization | ~$0.002 | ~12/hour | ~$0.58 |
| Activity inference | ~$0.002 | ~4/hour | ~$0.19 |
| **Total** | | | **~$0.77** |

Nightly digest and daily reflection use Haiku and Opus respectively and run once per day -- cost is negligible.

---

## Privacy

- All data stays local (SQLite database in `~/Library/Application Support/ContextD/`)
- Password managers and System Settings are excluded from capture by default
- AutoLog's own windows are excluded from screenshots
- LLM calls go through your local `claude -p` proxy -- no data sent to third-party APIs
- Raw captures are pruned after 72 hours; summaries and activities persist indefinitely
- No telemetry, no analytics, no network calls except to your local LLM proxy

---

## Credits

Forked from [thesophiaxu/contextd](https://github.com/thesophiaxu/contextd). Activity knowledge graph, enhanced OCR pipeline, Obsidian integration, LLM proxy, MCP bridge, focus workflow, and ScreenCaptureKit migration by [Amit Subhash](https://github.com/AmitSubhash).

## License

MIT
