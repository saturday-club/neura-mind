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

### `ContextD/Focus/FocusOverlayState.swift`

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

### `ContextD/Focus/FocusScoreEngine.swift`

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

### `ContextD/UI/BorderOverlayView.swift`

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

### `ContextD/UI/BorderOverlayWindowController.swift`

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

### `ContextD/App/ServiceContainer.swift`

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

### `ContextD/App/AppDelegate.swift`

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

### `ContextD/UI/MenuBarView.swift`

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
