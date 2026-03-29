import Foundation

/// A single message in a chat session.
struct ConversationMessage: Identifiable, Sendable {
    let id: UUID
    let role: String    // "user" or "assistant"
    let content: String
    let timestamp: Date

    init(role: String, content: String) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
    }
}

/// In-memory chat session with today's screen activity injected as system context.
/// Not persisted — cleared when reset() is called or the session ends.
/// Capped at 10 user turns to keep the context window bounded.
@MainActor
final class ConversationEngine: ObservableObject {
    @Published private(set) var messages: [ConversationMessage] = []
    @Published private(set) var isProcessing = false
    @Published private(set) var error: String?

    private let storageManager: StorageManager
    private let llmClient: any LLMClient
    private let model = "anthropic/claude-sonnet-4-6"

    let maxTurns = 10
    var turnCount: Int { messages.filter { $0.role == "user" }.count }
    var isAtLimit: Bool { turnCount >= maxTurns }

    init(storageManager: StorageManager, llmClient: any LLMClient) {
        self.storageManager = storageManager
        self.llmClient = llmClient
    }

    func send(message: String) async {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAtLimit else { return }

        messages.append(ConversationMessage(role: "user", content: trimmed))
        isProcessing = true
        error = nil

        let systemPrompt = buildSystemPrompt()
        let llmMessages = messages.map { LLMMessage(role: $0.role, content: $0.content) }

        do {
            let response = try await llmClient.completeWithUsage(
                messages: llmMessages,
                model: model,
                maxTokens: 600,
                systemPrompt: systemPrompt,
                temperature: 0.7
            )
            if let usage = response.usage {
                _ = try? storageManager.insertTokenUsage(TokenUsageRecord(
                    id: nil, timestamp: Date().timeIntervalSince1970,
                    caller: "conversation", model: model,
                    inputTokens: usage.inputTokens, outputTokens: usage.outputTokens
                ))
            }
            messages.append(ConversationMessage(role: "assistant", content: response.content))
        } catch {
            // Remove the user message that failed to get a response
            messages.removeLast()
            self.error = error.localizedDescription
        }

        isProcessing = false
    }

    func reset() {
        messages = []
        error = nil
    }

    // MARK: - System Prompt

    private func buildSystemPrompt() -> String {
        let today = Calendar.current.startOfDay(for: Date())
        let summaries = (try? storageManager.summaries(from: today, to: Date(), limit: 15)) ?? []

        var parts: [String] = [
            "You are an ADHD-aware productivity assistant for NeuraMind.",
            "You have access to the user's screen activity captured today.",
            "Be conversational, specific, and concise — ADHD brains don't need essays."
        ]

        if !summaries.isEmpty {
            let tf = DateFormatter()
            tf.dateStyle = .none
            tf.timeStyle = .short
            let context = summaries.prefix(12).map { s in
                "[\(tf.string(from: s.startDate))] \(s.summary)"
            }.joined(separator: "\n")
            parts.append("\nToday's activity (from screen capture):\n\(context)")
        }

        let goals = MorningPlanEngine.savedGoals()
        if !goals.isEmpty {
            parts.append("\nUser's goals for today:\n\(goals)")
        }

        if let score = ServiceContainer.shared.focusScoreEngine?.currentScore {
            parts.append("\nCurrent focus state: \(score.state.label) (\(Int(score.value * 100))%)")
        }

        return parts.joined(separator: "\n")
    }
}
