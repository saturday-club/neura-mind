import Foundation

/// Manages the Wind Down flow: queries today's summaries from the DB, compares
/// them against morning goals (if set), and generates an end-of-day recap via Sonnet.
@MainActor
final class WindDownEngine: ObservableObject {
    @Published private(set) var isProcessing = false
    @Published private(set) var currentRecap: String?
    @Published private(set) var error: String?

    private let storageManager: StorageManager
    private let llmClient: any LLMClient
    private let model = "anthropic/claude-sonnet-4-6"

    init(storageManager: StorageManager, llmClient: any LLMClient) {
        self.storageManager = storageManager
        self.llmClient = llmClient
    }

    func generateRecap() async {
        isProcessing = true
        error = nil

        let today = Calendar.current.startOfDay(for: Date())
        let summaries = (try? storageManager.summaries(from: today, to: Date(), limit: 50)) ?? []

        let tf = DateFormatter()
        tf.dateStyle = .none
        tf.timeStyle = .short

        let activityText: String
        if summaries.isEmpty {
            activityText = "No activity recorded today."
        } else {
            activityText = summaries.map { s in
                "[\(tf.string(from: s.startDate))] \(s.summary)"
            }.joined(separator: "\n")
        }

        var userMessage = "Today's activity:\n\n\(activityText)"
        let goals = MorningPlanEngine.savedGoals()
        if !goals.isEmpty {
            userMessage += "\n\nMy goals for today were:\n\(goals)"
        }

        let systemPrompt = """
        You are an ADHD-aware productivity coach helping the user close out their day.
        Review their activity and goals (if provided), then give a brief, honest, kind recap.
        Format your response with:
        **Accomplished** (2-3 bullets of what actually got done)
        **Focus patterns** (what pulled attention, how focused overall)
        **Tomorrow** (one sentence — a single intention to carry forward)
        Keep it under 200 words. Be encouraging, not critical.
        """

        do {
            let response = try await llmClient.completeWithUsage(
                messages: [LLMMessage(role: "user", content: userMessage)],
                model: model,
                maxTokens: 400,
                systemPrompt: systemPrompt,
                temperature: 0.3
            )
            if let usage = response.usage {
                _ = try? storageManager.insertTokenUsage(TokenUsageRecord(
                    id: nil, timestamp: Date().timeIntervalSince1970,
                    caller: "wind-down", model: model,
                    inputTokens: usage.inputTokens, outputTokens: usage.outputTokens
                ))
            }
            currentRecap = response.content
        } catch {
            self.error = error.localizedDescription
        }

        isProcessing = false
    }
}
