# NeuraMind — TODO

## Done

### 1. App name: rename everything from AutoLog/ContextD → NeuraMind
- [x] `scripts/gen-info-plist.sh` — CFBundleName, CFBundleDisplayName, CFBundleIdentifier, usage descriptions
- [x] `NeuraMind/App/NeuraMindApp.swift` — struct `NeuraMindApp` → `NeuraMindApp`
- [x] `NeuraMind/App/AppDelegate.swift` — window titles, notification name
- [x] `NeuraMind/App/ServiceContainer.swift` — debug log path
- [x] `NeuraMind/UI/MenuBarActions.swift` — "Quit autolog", obsidian vault URL
- [x] `NeuraMind/UI/MenuBarComponents.swift` — hardcoded "autolog" text, `AutoLogFocusState` type ref
- [x] `NeuraMind/UI/MenuBarView.swift` — `AutoLogFocusState` type ref
- [x] `NeuraMind/UI/SettingsView.swift` — comment and proxy hint text
- [x] `NeuraMind/Focus/FocusStateStore.swift` — `AutoLogFocusState` → `NeuraMindFocusState`, `AutoLogFocusBlock` → `NeuraMindFocusBlock`, config file paths
- [x] `NeuraMind/Server/APIRoutes+Focus.swift` — type refs
- [x] `NeuraMind/Server/OpenAPISpec.swift` — API title and description strings
- [x] `NeuraMind/Server/ScalarDocsPage.swift` — page title
- [x] `NeuraMind/Server/APIServer.swift` — log line
- [x] `NeuraMind/Server/APIServerMiddleware.swift` — auth token path (`~/.config/autolog/` → `~/.config/neuramind/`)
- [x] `NeuraMind/Permissions/OnboardingView.swift` — "Welcome to AutoLog" etc.
- [x] `NeuraMind/Permissions/PermissionManager.swift` — comment
- [x] `NeuraMind/Storage/Database.swift` — Application Support dir (`NeuraMind/` → `NeuraMind/`)
- [x] `NeuraMind/LLMClient/KeychainHelper.swift` — path ref
- [x] `NeuraMind/Utilities/DualLogger.swift` — log subsystem (`com.autolog.app` → `com.neuramind.app`)
- [x] `NeuraMind/Utilities/PromptTemplates.swift` — "AutoLog" in prompts
- [x] `NeuraMind/Capture/ScreenCapture.swift` — temp file name
- [x] `Makefile` — BUNDLE_ID, INSTALLED_APP, log predicates, display strings
- [x] `launch.sh` — BUNDLE_ID, SIGN_ID, INSTALLED_APP

---

## Backlog — Implementation bugs vs test_plan.md

### 2. FocusScoreEngine — wrong formula (`FocusScoreEngine.swift`)
Spec requires a 3-signal formula; current code uses a 2-signal approximation with wrong weights/divisors.

**Should be:**
```swift
let switchPenalty    = min(Double(switchCount) / 10.0, 1.0)
let diversityPenalty = min(Double(uniqueApps - 1) / 4.0, 1.0)
let depthScore       = min(currentSessionMinutes / 15.0, 1.0)
let value = (0.40 * (1.0 - switchPenalty))
          + (0.35 * (1.0 - diversityPenalty))
          + (0.25 * depthScore)
```

**Currently:**
```swift
let switchPenalty = min(Double(switchCount) / 3.0, 1.0)  // wrong divisor
let depthScore    = min(currentSessionMinutes / 3.0, 1.0) // wrong divisor
let value = (0.5 * (1.0 - switchPenalty)) + (0.5 * depthScore) // wrong weights, missing diversity term
```

### 3. FocusScoreEngine — wrong data source + compressed test timings
- Uses `captures` table with 1-min window instead of `appSessions` with 5-min window (labeled // TEST)
- Drift escalation: 30s instead of 300s (5 min) (labeled // TEST)
- Restore both to spec values once testing is done

### 4. FocusScoreEngine — async Task in tick()
Spec explicitly says "No async, no Task, no await." `tick()` currently wraps everything in `Task { @MainActor }`. Should be synchronous on main thread.

### 5. ContextRecoveryEngine — test cooldown (30s instead of 10 min)
```swift
private let cooldown: TimeInterval = 30  // TEST → should be 600
```

### 6. ContextRecoveryEngine — no explicit start() method
Spec defines `func start()` to begin subscriptions. Currently subscribes in `init()`.
`ServiceContainer` never calls `.start()` on it — works by accident, not by design.

### 7. ContextRecoveryEngine — user-visible error/debug strings
Spec: "skip silently. Never show an error to the user for this feature."
Currently shows `[DB error]`, `[LLM failed]`, `[No summary yet]` prefixed messages to the user.
All failure paths should be silent (no card shown).
