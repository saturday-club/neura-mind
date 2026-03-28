import Foundation
import Combine

/// Watches FocusScoreEngine for activeDrift → focus transitions.
/// When detected (and the toggle is on), queries the last productive summary
/// for the returned-to app, calls Haiku once, and shows a recovery card.
@MainActor
final class ContextRecoveryEngine {
    private let storageManager: StorageManager
    private let sessionDetector: AppSessionDetector
    private let llmClient: LLMClient
    private let cardController = ContextRecoveryCardController()

    private var cancellable: AnyCancellable?
    private var previousState: FocusOverlayState = .transitioning
    private var driftStartedAt: Date?
    private var lastShownPerApp: [String: Date] = [:]

    private let cooldown: TimeInterval = 30    // TEST: 30s cooldown
    private let model = "anthropic/claude-haiku-4-5-20251001"

    init(
        storageManager: StorageManager,
        sessionDetector: AppSessionDetector,
        llmClient: LLMClient,
        scoreEngine: FocusScoreEngine
    ) {
        self.storageManager = storageManager
        self.sessionDetector = sessionDetector
        self.llmClient = llmClient

        cancellable = scoreEngine.$overlayState
            .receive(on: RunLoop.main)
            .sink { [weak self] newState in
                self?.handleStateChange(newState)
            }
    }

    func stop() {
        cancellable?.cancel()
        cancellable = nil
        cardController.dismiss()
    }

    // MARK: - State Transition Handling

    private func handleStateChange(_ newState: FocusOverlayState) {
        defer { previousState = newState }

        // Record when we enter activeDrift
        if newState == .activeDrift && previousState != .activeDrift {
            driftStartedAt = Date()
            return
        }

        // Trigger only on activeDrift → focus or transitioning
        guard UserDefaults.standard.bool(forKey: "contextRecoveryEnabled"),
              previousState == .activeDrift,
              newState == .focus || newState == .transitioning,
              let driftStart = driftStartedAt else { return }

        driftStartedAt = nil

        Task {
            await trigger(driftStartedAt: driftStart)
        }
    }

    // MARK: - Trigger

    private func trigger(driftStartedAt: Date) async {
        guard let sessionInfo = await sessionDetector.currentSessionInfo() else { return }
        let appName = sessionInfo.appName

        // Cooldown: don't show again for the same app within 10 min
        if let lastShown = lastShownPerApp[appName],
           Date().timeIntervalSince(lastShown) < cooldown { return }

        // Find the last summary for this app before the drift started
        let summaryText: String?
        do {
            summaryText = try storageManager.lastProductiveSummary(for: appName, before: driftStartedAt)?.summary
        } catch {
            summaryText = nil
            cardController.show(message: "[DB error] \(error.localizedDescription)")
            return
        }

        // Generate one-liner via Haiku, or fall back with reason
        let message: String
        if let text = summaryText {
            if let generated = await generateRecoveryMessage(summary: text, appName: appName) {
                message = generated
            } else {
                message = "[LLM failed] Last worked in \(appName). Time to refocus."
            }
        } else {
            message = "[No summary yet] Working in \(appName). Time to refocus."
        }

        lastShownPerApp[appName] = Date()
        cardController.show(message: message)
    }

    // MARK: - Haiku Call

    private func generateRecoveryMessage(summary: String, appName: String) async -> String? {
        let prompt = """
        In one sentence (max 15 words), tell the user what they were last working on.
        Be specific — mention the actual content, not just the app name.
        Start with "You were".

        Summary: \(summary)
        App: \(appName)
        """

        do {
            let text = try await llmClient.complete(
                messages: [LLMMessage(role: "user", content: prompt)],
                model: model,
                maxTokens: 60,
                temperature: 0.0
            )
            let cleaned = text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\"", with: "")
            return cleaned.isEmpty ? nil : cleaned
        } catch {
            return nil
        }
    }
}
