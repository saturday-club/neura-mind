# Phase 1 — Focus State Engine + Border Overlay

## Problem

ADHD brains do not check dashboards. Opening an app, glancing at a widget, or reading a status line all require a deliberate attention switch that doesn't happen reliably mid-work. The result: you don't notice you've been drifting for 40 minutes until it's too late.

Peripheral vision is different. Color at the edges of your screen is processed pre-attentively — you don't decide to notice it, you just do. A thin colored frame around the entire screen changes meaning as your focus state changes, and registers without demanding a context switch.

This is the entire thesis of Phase 1: make the current focus state ambient, not queryable.

---

## What we're building

Two tightly coupled components:

**1. FocusScoreEngine** — A `@MainActor` class that polls every 10 seconds, reads recent app session data directly from `StorageManager` (no LLM, no API calls), and produces a normalized `focusScore: Double` (0.0–1.0) plus a derived `FocusOverlayState` enum value. Runs locally, works offline, zero latency.

**2. BorderOverlayWindowController** — A `@MainActor` class that owns a full-screen, click-through `NSWindow` (one per display) positioned above every other window. It hosts a SwiftUI view that draws a 6px colored line along all four screen edges. Color and visibility respond to `FocusOverlayState` changes with a 0.6s animated crossfade.

---

## Score Calculation — No LLM

The score is computed entirely from behavioral signals already in the SQLite database. Every 10 seconds, `FocusScoreEngine` reads app sessions from the last 5 minutes and does arithmetic. No network calls, no subprocess, no Claude.

### Inputs

Query `StorageManager.appSessions(from: now-5min, to: now)` to get recent sessions. Also read the current frontmost app session start time from `AppSessionDetector`.

| Signal | How it's read | What it measures |
|--------|---------------|-----------------|
| `switchCount` | `sessions.count - 1` | How fragmented attention has been |
| `uniqueApps` | `Set(sessions.map(\.appName)).count` | How many different contexts were touched |
| `currentSessionMinutes` | `Date().timeIntervalSince(currentSessionStart) / 60` | How long sustained the current run is |

### Formula

```
switchPenalty    = min(Double(switchCount) / 10.0, 1.0)
                   // 0 switches → 0.0,  10+ switches → 1.0

diversityPenalty = min(Double(uniqueApps - 1) / 4.0, 1.0)
                   // 1 app → 0.0,  5+ apps → 1.0

depthScore       = min(currentSessionMinutes / 15.0, 1.0)
                   // 0 min → 0.0,  15+ min → 1.0

focusScore       = (0.40 * (1.0 - switchPenalty))
                 + (0.35 * (1.0 - diversityPenalty))
                 + (0.25 * depthScore)
```

Output is always in [0.0, 1.0].

### Why these weights

- **Switching rate (0.40)** is the dominant ADHD signal. Fragmented attention shows up immediately in app switches, even within the same task.
- **App diversity (0.35)** catches "many things open at once" without penalizing legitimate multi-app focused work (Xcode + docs browser is fine; Xcode + Slack + Twitter + email is not).
- **Session depth (0.25)** rewards sustained presence but is the weakest signal — you can be deeply unfocused in a single app (doomscrolling).

### What this replaces

`FocusStateStore.computeDrift()` already does something similar: it produces a `fragmentationScore` (0–100 integer, higher = worse) from the same session data. `FocusScoreEngine` is a cleaner, normalized version of the same idea, extended with hyperfocus detection and the drift→activeDrift time escalation. The existing drift computation stays untouched — it's still used by the API and Emacs integration.

---

## State Machine

Five states. Evaluated on every 10s tick.

```
currentSessionMinutes >= 90  ──────────────────────────────► hyperfocus  (overrides all)

score >= 0.7                 ──────────────────────────────► focus
0.4 <= score < 0.7           ──────────────────────────────► transitioning
score < 0.4, dipping < 5min  ──────────────────────────────► drift
score < 0.4, dipping >= 5min ──────────────────────────────► activeDrift
```

**Drift escalation timer:** `FocusScoreEngine` tracks `scoreDippedAt: Date?` — set the first time score drops below 0.4, cleared when it rises back above. `drift` vs `activeDrift` is just `Date().timeIntervalSince(scoreDippedAt) >= 300`. No extra state, no separate timer.

**Hyperfocus** is checked before the score thresholds and overrides them. It is not inherently negative — it just surfaces awareness (break schedules blown, tunnel vision risk).

---

## Color Scheme

| State | Color | Hex |
|-------|-------|-----|
| `focus` | Green | `#30D158` |
| `transitioning` | Amber | `#FFD60A` |
| `drift` | Orange | `#FF9F0A` |
| `activeDrift` | Red | `#FF375F` |
| `hyperfocus` | Purple | `#BF5AF2` |

All from Apple's system color palette. Border renders at 85% opacity — perceptible in peripheral vision without being visually aggressive. Transitions animate at 0.6s ease-in-out.

---

## New Files

### `NeuraMind/Focus/FocusOverlayState.swift`

Types only, no logic.

```swift
enum FocusOverlayState: Equatable, Sendable {
    case focus
    case transitioning
    case drift
    case activeDrift
    case hyperfocus

    var color: Color { ... }    // hex values above
    var label: String { ... }   // e.g. "In flow", "Drifting", "Hyperfocus"
}

struct FocusScore: Sendable {
    let value: Double                  // 0.0–1.0
    let switchCount: Int
    let uniqueApps: Int
    let currentSessionMinutes: Double
    let state: FocusOverlayState
    let computedAt: Date
}
```

### `NeuraMind/Focus/FocusScoreEngine.swift`

```swift
@MainActor
final class FocusScoreEngine: ObservableObject {
    @Published private(set) var currentScore: FocusScore?
    @Published private(set) var overlayState: FocusOverlayState = .transitioning

    private let storageManager: StorageManager
    private let sessionDetector: AppSessionDetector
    private var scoreDippedAt: Date?
    private var timer: Timer?

    init(storageManager: StorageManager, sessionDetector: AppSessionDetector)

    func start()   // 10s repeating timer → tick()
    func stop()

    private func tick()
    // 1. Read appSessions(from: now-5min, to: now) synchronously (GRDB read is fast)
    // 2. Read currentSessionStart from sessionDetector
    // 3. Compute FocusScore via formula above
    // 4. Update scoreDippedAt
    // 5. Derive FocusOverlayState
    // 6. Publish to @Published properties
}
```

No async, no Task, no await. GRDB reads on the main thread complete in < 1ms for a 5-minute window. The 10s interval means there's zero perceptible blocking.

### `NeuraMind/UI/BorderOverlayView.swift`

```swift
struct BorderOverlayView: View {
    let state: FocusOverlayState
    private let thickness: CGFloat = 6

    var body: some View {
        let c = state.color.opacity(0.85)
        GeometryReader { _ in
            ZStack {
                Color.clear
                VStack { Rectangle().fill(c).frame(height: thickness); Spacer() }
                VStack { Spacer(); Rectangle().fill(c).frame(height: thickness) }
                HStack { Rectangle().fill(c).frame(width: thickness); Spacer() }
                HStack { Spacer(); Rectangle().fill(c).frame(width: thickness) }
            }
        }
        .animation(.easeInOut(duration: 0.6), value: state)
    }
}
```

`Color.clear` at the root combined with `ignoresMouseEvents = true` at the window level means zero interaction surface. The view is purely visual.

### `NeuraMind/UI/BorderOverlayWindowController.swift`

```swift
@MainActor
final class BorderOverlayWindowController {
    private var windows: [NSWindow] = []   // one per NSScreen
    private let scoreEngine: FocusScoreEngine
    private var cancellable: AnyCancellable?

    init(scoreEngine: FocusScoreEngine)

    func start()            // createWindows() + subscribe to scoreEngine.$overlayState
    func stop()             // cancel subscription + close windows
    func rebuildWindows()   // called on NSApplication.didChangeScreenParametersNotification

    private func createWindows()
    private func createWindow(for screen: NSScreen) -> NSWindow
    private func update(state: FocusOverlayState)
}
```

**NSWindow configuration per screen:**

```swift
let win = NSWindow(
    contentRect: screen.frame,
    styleMask: .borderless,
    backing: .buffered,
    defer: false
)
win.level           = NSWindow.Level(Int(CGShieldingWindowLevel()) + 1)
win.backgroundColor = .clear
win.isOpaque        = false
win.hasShadow       = false
win.ignoresMouseEvents  = true
win.collectionBehavior  = [
    .canJoinAllSpaces,      // visible on every Space
    .stationary,            // doesn't move with Space transitions
    .ignoresCycle,          // excluded from Cmd-Tab / Cmd-`
    .fullScreenAuxiliary,   // stays visible when another app is full-screen
]
win.isReleasedWhenClosed = false
win.contentView = NSHostingView(rootView: BorderOverlayView(state: .transitioning))
```

`CGShieldingWindowLevel() + 1` sits above full-screen apps, the Dock, and the menu bar without conflicting with system-reserved levels. This is the correct level for always-visible overlays.

---

## Modified Files

### `NeuraMind/App/ServiceContainer.swift`

Add two properties:

```swift
let focusScoreEngine: FocusScoreEngine?
let borderOverlayController: BorderOverlayWindowController?
```

In `init()`, after `sessionDetector` is created:

```swift
let scoreEngine = FocusScoreEngine(
    storageManager: storage,
    sessionDetector: detector
)
focusScoreEngine = scoreEngine
borderOverlayController = BorderOverlayWindowController(scoreEngine: scoreEngine)
```

In `startServices()`, after `captureEngine?.start()`:

```swift
focusScoreEngine?.start()
borderOverlayController?.start()
```

In the error catch block: assign both to `nil`.

### `NeuraMind/App/AppDelegate.swift`

Register for display hot-plug in `applicationDidFinishLaunching`:

```swift
NotificationCenter.default.addObserver(
    self,
    selector: #selector(screensDidChange),
    name: NSApplication.didChangeScreenParametersNotification,
    object: nil
)

@objc private func screensDidChange() {
    ServiceContainer.shared.borderOverlayController?.rebuildWindows()
}
```

### `NeuraMind/UI/MenuBarView.swift`

Add a focus state row at the top of the popover (small colored dot + state label + score percentage):

```swift
if let score = ServiceContainer.shared.focusScoreEngine?.currentScore {
    HStack(spacing: 6) {
        Circle()
            .fill(score.state.color)
            .frame(width: 8, height: 8)
        Text(score.state.label)
            .font(.caption)
            .foregroundStyle(.secondary)
        Spacer()
        Text(String(format: "%.0f%%", score.value * 100))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }
}
```

---

## API extension (no extra work)

Extend the existing `GET /v1/focus/current` response to include the new score. The handler already has access to `StorageManager` — just pass `focusScoreEngine` in when constructing `APIServer` and append to the response:

```json
{
  "current": { ... },
  "drift": { ... },
  "focus_score": {
    "value": 0.73,
    "state": "focus",
    "switch_count": 2,
    "unique_apps": 2,
    "current_session_minutes": 18.4
  }
}
```

---

## Implementation order

1. `FocusOverlayState.swift` — types only, zero dependencies
2. `FocusScoreEngine.swift` — pure logic, testable without UI
3. `BorderOverlayView.swift` — SwiftUI view, verify in Xcode canvas
4. `BorderOverlayWindowController.swift` — window lifecycle
5. Wire into `ServiceContainer.swift`
6. Screen-change notification in `AppDelegate.swift`
7. Score dot in `MenuBarView.swift`
8. Extend `/v1/focus/current` API response

Steps 1–4 are independently buildable and testable before any wiring.

---

## Out of scope for Phase 1

- Animated pulse / breathing effect on the border
- Per-app allowlist (exempt specific apps from drift scoring — e.g., Spotify)
- User-configurable score weights or thresholds in Settings UI
- Sound / notification on activeDrift transition
- Focus score history chart
- LLM-based task alignment scoring (does current activity match declared focus block task)

---
---

# Phase 2 — Context Recovery Card

## Problem

You drift for 15 minutes — Twitter, YouTube, whatever. You come back to your work. But now you've lost the thread completely. What were you writing? What was the next step? Reconstructing that context takes 5–10 minutes of cognitive effort, and for ADHD brains that re-entry tax is often enough to trigger another avoidance loop.

NeuraMind intercepts that moment. The instant you switch back to a productive app after a drift period, before you've had to reconstruct anything, a small card appears at the bottom of the screen:

> *"Welcome back. You were editing the Methods section — last working on the third paragraph about attention mechanisms."*

One line. Specific. Gone in 8 seconds if you don't interact.

---

## What we're building

**1. A toggle** — Context Recovery is opt-in, off by default. It lives in the same row as the existing Fast/Medium/Slow capture speed control in `SettingsView`. When off, nothing changes from Phase 1.

**2. `ContextRecoveryEngine`** — A `@MainActor` class that watches `FocusScoreEngine.$overlayState` for `activeDrift → focus/transitioning` transitions. When triggered, it finds the last summary for the app the user returned to, calls Claude Haiku once to generate a one-liner, and fires a notification to display the card.

**3. `ContextRecoveryCard`** — A lightweight floating `NSPanel` (no title bar, bottom-center, above all windows) hosting a SwiftUI view. Auto-dismisses after 8 seconds via a `Timer`. Dismisses immediately on tap.

---

## Toggle

Stored in `UserDefaults` key `"contextRecoveryEnabled"`, default `false`.

In `SettingsView`, in the same section as capture speed:

```swift
Toggle("Context Recovery", isOn: $contextRecoveryEnabled)
    .toggleStyle(.switch)
```

`ContextRecoveryEngine` checks this flag on every potential trigger — if false, it returns immediately. No wiring changes needed when toggled; the engine is always running, just gated.

---

## Drift → Focus Transition Detection

`ContextRecoveryEngine` subscribes to `FocusScoreEngine.$overlayState`:

```swift
private var previousState: FocusOverlayState = .transitioning

// On each state emission:
// Trigger if: previous == .activeDrift AND new == .focus OR .transitioning
// i.e. the user was drifting for 5+ min and just returned to something
```

**Cooldown:** 10 minutes per app. If the user already got a recovery card for Xcode in the last 10 minutes, skip. Stored in a `[String: Date]` dictionary keyed by app name.

**Minimum drift duration:** Only `activeDrift` (5+ min sustained drift) triggers recovery. Brief `drift` states do not. This is free — `activeDrift` is already a distinct enum case from Phase 1.

---

## Data: Finding the Last Context

When triggered, `ContextRecoveryEngine` has the current app name from `AppSessionDetector.currentSessionInfo()`.

Query: most recent summary whose `appNames` JSON array contains the returned-to app, older than the drift start time (so we don't accidentally surface a summary from the drift itself):

```swift
func lastProductiveSummary(for appName: String, before timestamp: Date) throws -> SummaryRecord?
```

Add this to `StorageManager` as a new query method on an extension.

If no summary found → skip silently. No card, no error.

---

## Haiku Call

Single call, small prompt:

```swift
let prompt = """
In one sentence (max 15 words), tell the user what they were last working on.
Be specific — mention the actual content, not just the app name.
Start with "You were".

Summary: \(summary.summary)
App: \(appName)
"""
```

Model: `anthropic/claude-haiku-4-5-20251001`
Max tokens: 60
Temperature: 0.0

If the call fails for any reason → skip silently. Never show an error to the user for this feature.

---

## Card UI

```swift
struct ContextRecoveryCard: View {
    let message: String         // Claude-generated one-liner
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .foregroundStyle(.blue)
                .font(.system(size: 16))
            Text("Welcome back. \(message)")
                .font(.system(size: 13))
                .lineLimit(2)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .frame(width: 400)
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
    }
}
```

**NSPanel config:**

```swift
// Bottom-center of main screen, 40px above dock
// level: .floating
// styleMask: .borderless, .nonactivatingPanel
// hidesOnDeactivate: false
// ignoresMouseEvents: false (user can tap X to dismiss)
// isReleasedWhenClosed: false
```

Position: `screen.visibleFrame.midX - 200`, `screen.visibleFrame.minY + 40`

---

## `ContextRecoveryEngine`

```swift
@MainActor
final class ContextRecoveryEngine {
    private let storageManager: StorageManager
    private let sessionDetector: AppSessionDetector
    private let llmClient: LLMClient
    private var cancellable: AnyCancellable?
    private var dismissTimer: Timer?
    private var panel: NSPanel?
    private var previousState: FocusOverlayState = .transitioning
    private var driftStartedAt: Date?
    private var lastShownPerApp: [String: Date] = [:]

    @AppStorage("contextRecoveryEnabled") private var isEnabled = false

    init(storageManager: StorageManager, sessionDetector: AppSessionDetector,
         llmClient: LLMClient, scoreEngine: FocusScoreEngine)

    func start()   // subscribe to scoreEngine.$overlayState
    func stop()    // cancel subscription, dismiss panel if shown

    private func handleTransition(from: FocusOverlayState, to: FocusOverlayState)
    private func trigger(returnedTo appName: String)  // async: query DB → Haiku → show card
    private func showCard(message: String)
    private func dismissCard()
}
```

---

## New StorageManager Method

Add to `StorageManager+Extensions.swift` (or a new `StorageManager+NeuraMind.swift`):

```swift
func lastProductiveSummary(for appName: String, before date: Date) throws -> SummaryRecord? {
    try database.dbPool.read { db in
        // appNames column stores JSON array — use LIKE for a simple match
        // Not perfect but fast and sufficient
        try SummaryRecord
            .filter(SummaryRecord.Columns.endTimestamp < date.timeIntervalSince1970)
            .filter(sql: "appNames LIKE ?", arguments: ["%\(appName)%"])
            .order(SummaryRecord.Columns.endTimestamp.desc)
            .fetchOne(db)
    }
}
```

---

## Modified Files

| File | Change |
|------|--------|
| `SettingsView.swift` | Add Context Recovery toggle |
| `ServiceContainer.swift` | Create + start `ContextRecoveryEngine` |
| `StorageManager+Extensions.swift` | Add `lastProductiveSummary(for:before:)` |

## New Files

| File | What |
|------|------|
| `NeuraMind/Focus/ContextRecoveryEngine.swift` | Engine: transition detection, DB query, Haiku call |
| `NeuraMind/UI/ContextRecoveryCard.swift` | SwiftUI card view + NSPanel controller |

---

## Implementation order

1. `ContextRecoveryCard.swift` — SwiftUI view + NSPanel wrapper, no dependencies, verify in canvas
2. `StorageManager+Extensions.swift` — add `lastProductiveSummary(for:before:)`, testable in isolation
3. `ContextRecoveryEngine.swift` — full engine, depends on both above
4. Wire into `ServiceContainer.swift`
5. Add toggle to `SettingsView.swift`

---

## Out of scope for Phase 2

- Showing the card for hyperfocus → drift transitions (different problem)
- Multiple lines of context (one line is the design constraint)
- User editing or saving the recovery message
- History of past recovery messages
- Per-app opt-out (e.g. "never show recovery for Spotify")
