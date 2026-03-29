# NeuraMind

Your screen, understood.

```bash
# See installation instructions below
brew install --cask NeuraMind
```

NeuraMind is a macOS menu bar app that watches what you do on your computer and builds a searchable activity knowledge graph from it. It captures your screen via OCR, infers what you're working on using an LLM, connects related activities across apps, and syncs everything to an Obsidian vault as linked notes.

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

Every few seconds, NeuraMind takes a screenshot, runs full-screen OCR, and extracts:

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

NeuraMind uses a five-stage pipeline to turn screenshots into structured records efficiently.

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

This compression means NeuraMind avoids redundant OCR when you're reading a static page -- it only processes what actually changed.

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

NeuraMind doesn't just store flat summaries. It builds structure across four layers:

**App Sessions** -- contiguous stretches of using one app, with aggregated metadata (all window titles, document paths, URLs seen during the session).

**Activities** -- LLM-inferred tasks that span one or more app sessions. "Debugging the capture pipeline" might involve Terminal (building), Safari (reading docs), and Xcode (editing code) -- NeuraMind groups these into one coherent activity with a human-readable name.

**Entities** -- files, URLs, and topics extracted from activities, queryable independently ("show me everything involving this file").

**Cross-activity links** -- activities connected by shared files, URLs, or topics. If you edited `CaptureEngine.swift` in two different sessions hours apart, NeuraMind links those two activities together so you can reconstruct your whole context.

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
2. NeuraMind runs a retrieval strategy against stored summaries and activities
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

NeuraMind syncs to an Obsidian vault with `[[wikilinks]]` so you can explore your work history in Obsidian's graph view.

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

NeuraMind can also track declared focus blocks, not just passive activity. The model is:

- **Emacs/Org owns intent** -- what you said you were trying to do
- **NeuraMind owns evidence** -- what apps, sessions, and artifacts actually happened

This creates a useful separation: planning lives in Org, but productivity and drift are judged from captured behavior.

### File contract

Focus blocks are stored as small local files:

- `~/.config/neuramind/focus-state.json` -- the current active block
- `~/.config/neuramind/focus-blocks.jsonl` -- completed/interrupted block history
- `~/org/today.org` -- daily dashboard
- `~/org/neuramind-scorecard.org` -- review log

When you start a block, Emacs writes the declared task, done condition, artifact goal, and drift budget. When you stop a block, NeuraMind appends the finalized block to the log and writes a compact Org review entry to the scorecard.

### Emacs commands

The helper script lives at `scripts/neuramind-focus.el` and is intended to be loaded from your Doom config. The default keybindings are:

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
