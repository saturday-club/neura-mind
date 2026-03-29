import Foundation

/// OpenRouter API client.
/// Posts to https://openrouter.ai/api/v1/chat/completions using the OpenAI-compatible format.
final class OpenRouterClient: LLMClient, Sendable {

    private static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    private let logger = DualLogger(category: "OpenRouterClient")
    private let maxRetries = 3

    // MARK: - API Key (file-based)

    private static let apiKeyFile = "openrouter_api_key"

    static func readAPIKey() -> String? {
        KeychainHelper.read(key: apiKeyFile)
    }

    static func saveAPIKey(_ key: String) throws {
        try KeychainHelper.save(key: apiKeyFile, value: key.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func hasAPIKey() -> Bool {
        KeychainHelper.exists(key: apiKeyFile)
    }

    static func deleteAPIKey() {
        KeychainHelper.delete(key: apiKeyFile)
    }

    // MARK: - LLMClient

    func complete(
        messages: [LLMMessage],
        model: String,
        maxTokens: Int,
        systemPrompt: String?,
        temperature: Double,
        responseFormat: String?
    ) async throws -> String {
        try await completeWithUsage(
            messages: messages, model: model, maxTokens: maxTokens,
            systemPrompt: systemPrompt, temperature: temperature,
            responseFormat: responseFormat
        ).text
    }

    func completeWithUsage(
        messages: [LLMMessage],
        model: String,
        maxTokens: Int,
        systemPrompt: String?,
        temperature: Double,
        responseFormat: String?
    ) async throws -> LLMResponse {
        guard let apiKey = Self.readAPIKey() else {
            throw LLMError.noAPIKey
        }

        let body = buildRequestBody(
            messages: messages, model: model, maxTokens: maxTokens,
            systemPrompt: systemPrompt, temperature: temperature,
            responseFormat: responseFormat
        )

        var lastError: Error = LLMError.invalidResponse

        for attempt in 0..<maxRetries {
            do {
                return try await sendRequest(body: body, apiKey: apiKey)
            } catch LLMError.rateLimited(let retryAfter) {
                let delay = retryAfter ?? Double(pow(2.0, Double(attempt)))
                logger.warning("Rate limited, retrying in \(delay)s (attempt \(attempt + 1)/\(maxRetries))")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                lastError = LLMError.rateLimited(retryAfter: retryAfter)
            } catch LLMError.httpError(let code, let body) where code >= 500 {
                let delay = Double(pow(2.0, Double(attempt)))
                logger.warning("Server error \(code), retrying in \(delay)s (attempt \(attempt + 1)/\(maxRetries))")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                lastError = LLMError.httpError(statusCode: code, body: body)
            } catch {
                throw error
            }
        }

        throw lastError
    }

    // MARK: - Private

    private func buildRequestBody(
        messages: [LLMMessage],
        model: String,
        maxTokens: Int,
        systemPrompt: String?,
        temperature: Double,
        responseFormat: String?
    ) -> [String: Any] {
        var allMessages: [[String: String]] = []
        if let system = systemPrompt {
            allMessages.append(["role": "system", "content": system])
        }
        allMessages.append(contentsOf: messages.map { ["role": $0.role, "content": $0.content] })

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "temperature": temperature,
            "messages": allMessages,
        ]
        if let format = responseFormat {
            body["response_format"] = ["type": format]
        }
        return body
    }

    private func sendRequest(body: [String: Any], apiKey: String) async throws -> LLMResponse {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw LLMError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }

        let responseBody = String(data: data, encoding: .utf8) ?? ""

        switch http.statusCode {
        case 200:
            return try parseResponse(data: data)
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init)
            throw LLMError.rateLimited(retryAfter: retryAfter)
        default:
            throw LLMError.httpError(statusCode: http.statusCode, body: responseBody)
        }
    }

    private func parseResponse(data: Data) throws -> LLMResponse {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw LLMError.invalidResponse
        }

        var usage: LLMTokenUsage? = nil
        if let u = json["usage"] as? [String: Any],
           let input = u["prompt_tokens"] as? Int,
           let output = u["completion_tokens"] as? Int {
            usage = LLMTokenUsage(inputTokens: input, outputTokens: output)
        }

        return LLMResponse(text: text, usage: usage)
    }
}
