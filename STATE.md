# Session State — NeuraMind

## What We're Building
NeuraMind — a Claude hackathon macOS menu bar app for ADHD focus tracking.
Based on AmitSubhash/autolog. Swift Package (not Xcode), macOS 14+.

---

## Completed This Session

### 1. Full rename: AutoLog/ContextD → NeuraMind
- Source folder renamed: `ContextD/` → `NeuraMind/`
- Package.swift: target `ContextD` → `NeuraMind`, test target `ContextDTests` → `NeuraMindTests`
- Binary name is now `NeuraMind`
- `CFBundleExecutable` → `NeuraMind`
- `Resources/ContextD.entitlements` → `Resources/NeuraMind.entitlements`
- All launchd plists renamed: `com.contextd.*` → `com.neuramind.*`
- `scripts/autolog-focus.el` → `scripts/neuramind-focus.el`
- `mcp-bridge/contextd_mcp.py` → `mcp-bridge/neuramind_mcp.py`
- All config paths `~/.config/autolog/` → `~/.config/neuramind/`
- DB path: `~/Library/Application Support/NeuraMind/neuramind.sqlite`
- Log subsystem: `com.neuramind.app`
- Signing ID in launch.sh + Makefile: `NeuraMind Dev`

### 2. launch.sh rewrote from scratch
- Removed hidden Unicode/CR characters that caused "unbound variable" errors
- Fixed `${BASH_SOURCE[0]:-$0}` for zsh compatibility
- `PRODUCT="NeuraMind"` (matches Swift target name)

### 3. Removed duplicate Context Recovery toggle
- `MenuBarView.swift` had a standalone toggle AND `IntervalIndicatorView` had one
- Removed the standalone one from `MenuBarView.swift`
- Kept the one inside `IntervalIndicatorView` (grouped with capture speed controls)

### 4. Code signing with Apple Developer cert
- Found existing cert: `Apple Development: saaivignesh20@gmail.com (F7Q59S24D2)`
- Updated `SIGN_ID` in both `launch.sh` and `Makefile`
- App now signs with stable identity → permissions persist across rebuilds

---

## In Progress (INTERRUPTED)

### LLM Strategy Refactor

**Goal:** Replace dependency on external Python `claude -p` proxy with two native Swift strategies.

**Context read:**
- Proxy docs at https://github.com/AmitSubhash/claude-llm-proxy — Python server that wraps `claude -p` subprocess as OpenAI-compatible HTTP API
- `NeuraMind/LLMClient/LLMClient.swift` — protocol + types (fully read)
- `NeuraMind/LLMClient/OpenRouterClient.swift` — current implementation (fully read)
- `NeuraMind/App/ServiceContainer.swift` — wiring (fully read)
- `NeuraMind/UI/SettingsView.swift` — provider UI (fully read)
- All engines use `LLMClient` protocol type (not `OpenRouterClient` directly) ✓

**Planned changes — NOT YET IMPLEMENTED:**

#### 1. `NeuraMind/LLMClient/LLMClient.swift`
- Add `LLMError.cliNotFound` case
- Add `LLMProvider` enum at bottom:
  ```swift
  enum LLMProvider: String, CaseIterable {
      case claude = "claude"       // direct shell: `claude -p`
      case openrouter = "openrouter"
      static var current: LLMProvider { ... UserDefaults "llmProvider" ... }
      func makeClient() -> any LLMClient
      var isReady: Bool
      var displayName: String
  }
  ```

#### 2. NEW: `NeuraMind/LLMClient/ClaudeShellClient.swift`
- `final class ClaudeShellClient: LLMClient, @unchecked Sendable`
- `static func findPath() -> String?` — checks `/usr/local/bin/claude`, `/opt/homebrew/bin/claude`, fallback via `zsh -l -c "which claude"`
- `static func isAvailable() -> Bool`
- Model → alias map: `"anthropic/claude-haiku-4-5"` → `"haiku"`, etc.
- Uses `Process` + `withCheckedThrowingContinuation` + `terminationHandler`
- Args: `["-p", "--model", alias, "--output-format", "json", "--max-turns", "1"]`
- System prompt via `--system-prompt` flag
- User content via stdin
- Parses `json["result"]` from claude's JSON output
- `json["is_error"] == true` → throw `LLMError.httpError`

#### 3. `NeuraMind/LLMClient/OpenRouterClient.swift`
- Remove `isUsingProxy` static var
- Remove proxy detection in `endpoint` (always `https://openrouter.ai/api/v1/chat/completions`)
- Remove proxy skip in `completeWithUsage` (always require API key)
- Keep retry logic, API key management, response parsing

#### 4. `NeuraMind/App/ServiceContainer.swift`
- `llmClient: any LLMClient` (was `let llmClient: OpenRouterClient`)
- `llmClient = LLMProvider.current.makeClient()`
- Replace `OpenRouterClient.hasAPIKey()` / `OpenRouterClient.isUsingProxy` with `LLMProvider.current.isReady`

#### 5. `NeuraMind/UI/SettingsView.swift`
- Remove local `LLMProvider` enum (use global one)
- Replace `@AppStorage("llmEndpointURL")` with `@AppStorage("llmProvider")`
- Remove: `proxyURL`, `proxyTesting`, `proxyTestResult` state
- Remove: `proxySettingsView`, `testProxyConnection()`, "Apply Proxy" button
- Add: `claudeSettingsView` showing CLI availability status
- Provider picker uses `onChange` to immediately persist selection
- Add note: "Restart app to apply provider change"

---

## Key File Locations

| Purpose | Path |
|---|---|
| LLM protocol | `NeuraMind/LLMClient/LLMClient.swift` |
| OpenRouter impl | `NeuraMind/LLMClient/OpenRouterClient.swift` |
| API key storage | `NeuraMind/LLMClient/KeychainHelper.swift` (file-based, not actual Keychain) |
| Service wiring | `NeuraMind/App/ServiceContainer.swift` |
| Settings UI | `NeuraMind/UI/SettingsView.swift` |
| Build & launch | `launch.sh`, `Makefile` |
| Entitlements | `Resources/NeuraMind.entitlements` |
| Signing cert | `Apple Development: saaivignesh20@gmail.com (F7Q59S24D2)` |

## TODO Backlog (from TODO.md)
2. FocusScoreEngine — wrong formula (missing diversityPenalty, wrong divisors/weights)
3. FocusScoreEngine — wrong data source (captures→appSessions) + compressed test timings
4. FocusScoreEngine — async Task in tick() (spec says no async)
5. ContextRecoveryEngine — cooldown 30s → 600s
6. ContextRecoveryEngine — no explicit start() method (subscribes in init)
7. ContextRecoveryEngine — shows [DB error]/[LLM failed] to user (should be silent)
