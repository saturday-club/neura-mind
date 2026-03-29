import Foundation

/// Available email/calendar providers.
enum EmailProvider: String, CaseIterable {
    case none    = "none"
    case gmail   = "gmail"
    case outlook = "outlook"

    var displayName: String {
        switch self {
        case .none:    return "None"
        case .gmail:   return "Gmail"
        case .outlook: return "Outlook"
        }
    }

    static var current: EmailProvider {
        let raw = UserDefaults.standard.string(forKey: "emailProvider") ?? Self.none.rawValue
        return EmailProvider(rawValue: raw) ?? .none
    }
}

/// Errors from email context fetching.
enum EmailContextError: LocalizedError {
    case notImplemented
    case notConnected

    var errorDescription: String? {
        switch self {
        case .notImplemented:
            return "Email integration coming soon. Gmail OAuth2 will be added in a future update."
        case .notConnected:
            return "Not connected to an email provider."
        }
    }
}

/// Fetches and summarizes email/calendar context for the morning planning flow.
///
/// OAuth2 flows (Gmail, Outlook) are not yet implemented — the connect/fetch
/// calls return `notImplemented` until the auth layer is added.
/// This class is intentionally kept as a stub so the rest of Phase 3 UI works
/// end-to-end today; OAuth integration will be wired in a follow-up.
@MainActor
final class EmailContextFetcher: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var context: String?
    @Published private(set) var error: String?

    private let llmClient: any LLMClient

    init(llmClient: any LLMClient) {
        self.llmClient = llmClient
    }

    /// Attempt to fetch context from the given provider.
    /// Currently surfaces a "coming soon" message for all non-none providers.
    func fetch(provider: EmailProvider) async {
        guard provider != .none else {
            context = nil
            error = nil
            return
        }
        isLoading = true
        error = nil
        // OAuth2 not yet implemented.
        error = EmailContextError.notImplemented.errorDescription
        isLoading = false
    }

    func clear() {
        context = nil
        error = nil
    }
}
