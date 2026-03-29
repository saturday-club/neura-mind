import Foundation
import Combine

/// Polls every 10 seconds, reads recent capture data from SQLite,
/// and produces a normalized focusScore (0.0-1.0) + FocusOverlayState.
/// No LLM calls. No network. Works offline.
///
/// Score is primarily driven by app switching frequency.
/// Staying in one app = high score (calm). Rapid switching = low score (red).
@MainActor
final class FocusScoreEngine: ObservableObject {
    @Published private(set) var currentScore: FocusScore?
    @Published private(set) var overlayState: FocusOverlayState = .focus

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
            // 3-minute sliding window for smoother scoring
            let windowStart = now.addingTimeInterval(-180)

            guard let captures = try? self.storageManager.captures(from: windowStart, to: now) else { return }

            // Filter out NeuraMind's own captures (our panels shouldn't count as switching)
            let externalCaptures = captures.filter { capture in
                capture.appName != "NeuraMind" && capture.appName != "HocusPocus"
            }

            guard !externalCaptures.isEmpty else {
                // No external activity, assume focused
                self.updateScore(value: 0.9, switchCount: 0, uniqueApps: 0,
                               sessionMinutes: 0, now: now)
                return
            }

            // Count app switches
            let sortedApps = externalCaptures
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
                // If session detector fails, estimate from captures
                let span = externalCaptures.last!.timestamp - externalCaptures.first!.timestamp
                currentSessionMinutes = max(span / 60.0, 0.5)
            }

            // Score formula: primarily switch-based
            // 0 switches in 3 min = 1.0 (perfect focus)
            // 5+ switches in 3 min = 0.0 (heavy drift)
            // Depth gives a small bonus for sustained sessions
            let switchPenalty = min(Double(switchCount) / 5.0, 1.0)
            let depthBonus = min(currentSessionMinutes / 5.0, 1.0) * 0.15  // max 15% bonus

            let value = min((1.0 - switchPenalty) + depthBonus, 1.0)

            self.updateScore(value: value, switchCount: switchCount, uniqueApps: uniqueApps,
                           sessionMinutes: currentSessionMinutes, now: now)
        }
    }

    private func updateScore(value: Double, switchCount: Int, uniqueApps: Int,
                            sessionMinutes: Double, now: Date) {
        // Drift escalation timer
        if value < 0.3 {
            if scoreDippedAt == nil { scoreDippedAt = now }
        } else {
            scoreDippedAt = nil
        }

        let state: FocusOverlayState
        if sessionMinutes >= 90 {
            state = .hyperfocus
        } else if value >= 0.7 {
            state = .focus
        } else if value >= 0.4 {
            state = .transitioning
        } else if let dippedAt = scoreDippedAt, now.timeIntervalSince(dippedAt) >= 60 {
            state = .activeDrift
        } else {
            state = .drift
        }

        logger.info("score=\(String(format: "%.2f", value)) state=\(state) switches=\(switchCount) apps=\(uniqueApps) depth=\(String(format: "%.1f", sessionMinutes))min")

        let score = FocusScore(
            value: value,
            switchCount: switchCount,
            uniqueApps: uniqueApps,
            currentSessionMinutes: sessionMinutes,
            state: state,
            computedAt: now
        )

        currentScore = score
        overlayState = state
    }
}
