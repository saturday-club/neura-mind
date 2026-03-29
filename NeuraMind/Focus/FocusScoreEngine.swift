import Foundation
import Combine

/// Polls every 10 seconds, reads recent capture data from SQLite,
/// and produces a normalized focusScore (0.0–1.0) + FocusOverlayState.
/// No LLM calls. No network. Works offline.
///
/// Uses the captures table (written every 10s) NOT app_sessions (only written
/// when a session ends), so the score reflects real-time activity.
@MainActor
final class FocusScoreEngine: ObservableObject {
    @Published private(set) var currentScore: FocusScore?
    @Published private(set) var overlayState: FocusOverlayState = .transitioning

    private let storageManager: StorageManager
    private let sessionDetector: AppSessionDetector
    private let logger = DualLogger(category: "FocusScore")
    private var scoreDippedAt: Date?
    private var isComputing = false
    private var timer: Timer?

    init(storageManager: StorageManager, sessionDetector: AppSessionDetector) {
        self.storageManager = storageManager
        self.sessionDetector = sessionDetector
    }

    func start() {
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard !isComputing else { return }
        isComputing = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isComputing = false }

            let sessionInfo = await self.sessionDetector.currentSessionInfo()

            let now = Date()
            let windowStart = now.addingTimeInterval(-60)  // TEST: 1 min window

            // Use captures (written every 10s) — not app_sessions (only written on session end).
            // This gives an accurate picture of what happened in the last 3 minutes.
            guard let captures = try? self.storageManager.captures(from: windowStart, to: now) else { return }

            // Count app switches: each time appName changes in the sorted capture list
            let sortedApps = captures
                .sorted { $0.timestamp < $1.timestamp }
                .map(\.appName)
            var switchCount = 0
            if sortedApps.count > 1 {
                for i in 1..<sortedApps.count {
                    if sortedApps[i] != sortedApps[i - 1] { switchCount += 1 }
                }
            }
            let uniqueApps = Set(sortedApps).count

            let currentSessionMinutes: Double
            if let info = sessionInfo {
                currentSessionMinutes = (now.timeIntervalSince1970 - info.startTimestamp) / 60.0
            } else {
                currentSessionMinutes = 0
            }

            // Formula: 50% switch penalty + 50% depth (TEST: 3 switches = max penalty, 3 min = full depth)
            let switchPenalty = min(Double(switchCount) / 3.0, 1.0)
            let depthScore    = min(currentSessionMinutes / 3.0, 1.0)

            let value = (0.5 * (1.0 - switchPenalty))
                      + (0.5 * depthScore)

            // Drift escalation timer
            if value < 0.4 {
                if self.scoreDippedAt == nil { self.scoreDippedAt = now }
            } else {
                self.scoreDippedAt = nil
            }

            let state: FocusOverlayState
            if currentSessionMinutes >= 90 {
                state = .hyperfocus
            } else if value >= 0.7 {
                state = .focus
            } else if value >= 0.4 {
                state = .transitioning
            } else if let dippedAt = self.scoreDippedAt, now.timeIntervalSince(dippedAt) >= 30 {  // TEST: 30s
                state = .activeDrift
            } else {
                state = .drift
            }

            self.logger.info("score=\(String(format: "%.2f", value)) state=\(state) switches=\(switchCount) uniqueApps=\(uniqueApps) depth=\(String(format: "%.1f", currentSessionMinutes))min captures=\(captures.count)")

            let score = FocusScore(
                value: value,
                switchCount: switchCount,
                uniqueApps: uniqueApps,
                currentSessionMinutes: currentSessionMinutes,
                state: state,
                computedAt: now
            )

            self.currentScore = score
            self.overlayState = state
        }
    }
}
