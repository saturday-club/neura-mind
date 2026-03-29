import Foundation

/// Manages the Good Morning flow: stores today's goals in UserDefaults and
/// generates a prioritized day plan via Sonnet.
@MainActor
final class MorningPlanEngine: ObservableObject {
    @Published private(set) var isProcessing = false
    @Published private(set) var currentPlan: String?
    @Published private(set) var error: String?
    @Published private(set) var todayGoals: String = ""

    private let storageManager: StorageManager
    private let llmClient: any LLMClient
    private let model = "anthropic/claude-sonnet-4-6"

    init(storageManager: StorageManager, llmClient: any LLMClient) {
        self.storageManager = storageManager
        self.llmClient = llmClient
        // Restore today's saved goals and plan on init
        todayGoals = UserDefaults.standard.string(forKey: goalsKey) ?? ""
        currentPlan = UserDefaults.standard.string(forKey: planKey)
    }

    // MARK: - UserDefaults Keys

    private var goalsKey: String { "morningGoals_\(Self.todayString())" }
    private var planKey: String  { "morningPlan_\(Self.todayString())" }

    static func todayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    // MARK: - Public API

    func saveGoals(_ goals: String) {
        todayGoals = goals
        UserDefaults.standard.set(goals, forKey: goalsKey)
    }

    /// Build a day plan from the user's goals, optional email context, and any
    /// summaries already recorded today.
    func generatePlan(goals: String, emailContext: String?) async {
        let trimmed = goals.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        saveGoals(trimmed)

        isProcessing = true
        error = nil

        let today = Calendar.current.startOfDay(for: Date())
        let summaries = (try? storageManager.summaries(from: today, to: Date(), limit: 10)) ?? []
        let activityContext = summaries.isEmpty
            ? "No activity recorded yet today."
            : summaries.map { "- \($0.summary)" }.joined(separator: "\n")

        var userMessage = """
        My goals for today:
        \(trimmed)

        Activity so far today:
        \(activityContext)
        """
        if let email = emailContext, !email.isEmpty {
            userMessage += "\n\nEmail/calendar context:\n\(email)"
        }

        let systemPrompt = """
        You are an ADHD-aware productivity coach. Turn the user's goals into a clear, actionable day plan.
        Format your response with:
        **Priorities** (max 5, most important first — one line each)
        **First step** (one concrete thing to do right now)
        **Watch out for** (one potential distraction or blocker, optional)
        Keep it under 200 words. Be specific and encouraging.
        """

        do {
            let result = try await llmClient.complete(
                messages: [LLMMessage(role: "user", content: userMessage)],
                model: model,
                maxTokens: 400,
                systemPrompt: systemPrompt,
                temperature: 0.3
            )
            currentPlan = result
            UserDefaults.standard.set(result, forKey: planKey)
        } catch {
            self.error = error.localizedDescription
        }

        isProcessing = false
    }

    // MARK: - Static helpers (usable from ConversationEngine / WindDownEngine)

    static func savedGoals() -> String {
        UserDefaults.standard.string(forKey: "morningGoals_\(todayString())") ?? ""
    }

    static func savedPlan() -> String? {
        UserDefaults.standard.string(forKey: "morningPlan_\(todayString())")
    }
}
