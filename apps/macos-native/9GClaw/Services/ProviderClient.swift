import Foundation

struct AgentRequest: Sendable {
    var sessionId: String
    var projectPath: String
    var prompt: String
    var providerConfig: ProviderConfig
    var apiKey: String
    var priorMessages: [ChatMessage]
    var timeoutMs: Int
    var contextWindow: Int
    var permissionMode: ComposerPermissionMode
}

enum AgentEvent: Sendable, Equatable {
    case sessionCreated(sessionId: String)
    case contentDelta(String)
    case toolUse(id: String, name: String, inputJSON: String)
    case toolResult(id: String, output: String, isError: Bool)
    case status(String)
    case tokenBudget(used: Int, total: Int)
    case streamEnd
    case complete(sessionId: String)
    case aborted(sessionId: String)
    case error(String)
}

enum ProviderClientError: Error, LocalizedError {
    case missingBaseURL
    case missingModel
    case missingAPIKey
    case invalidURL(String)
    case httpError(statusCode: Int, body: String)
    case unsupportedProvider(SessionProvider)
    case invalidResponse
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .missingBaseURL: "Provider base URL is not configured."
        case .missingModel: "Provider model is not configured."
        case .missingAPIKey: "Provider API key is not configured. Add it in Settings or ~/.edgeclaw/config.yaml."
        case .invalidURL(let value): "Provider base URL is invalid: \(value)"
        case .httpError(let statusCode, let body):
            if body.isEmpty {
                "Provider request failed with HTTP \(statusCode)."
            } else {
                "Provider request failed with HTTP \(statusCode): \(body)"
            }
        case .unsupportedProvider(let provider): "\(provider.displayName) is not implemented yet in native AgentCore."
        case .invalidResponse: "Provider returned an invalid response."
        case .transport(let message): message
        }
    }
}

struct NativeAgentRuntime: Sendable {
    func stream(request: AgentRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.sessionCreated(sessionId: request.sessionId))
                    continuation.yield(.status("connecting"))

                    switch request.providerConfig.provider {
                    case .nineGClaw:
                        try await Self.streamNineGClaw(request: request, continuation: continuation)
                    case .claude, .cursor, .codex, .gemini:
                        throw ProviderClientError.unsupportedProvider(request.providerConfig.provider)
                    }

                    continuation.yield(.streamEnd)
                    continuation.yield(.complete(sessionId: request.sessionId))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.aborted(sessionId: request.sessionId))
                    continuation.finish()
                } catch {
                    continuation.yield(.error(error.localizedDescription))
                    continuation.finish()
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private static func streamNineGClaw(
        request: AgentRequest,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async throws {
        let config = request.providerConfig
        guard !config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderClientError.missingBaseURL
        }
        guard !config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderClientError.missingModel
        }

        switch config.apiType {
        case .openAIChat:
            try await streamOpenAIChat(request: request, continuation: continuation)
        case .openAIResponses:
            try await streamOpenAIResponses(request: request, continuation: continuation)
        case .anthropicMessages:
            try await streamAnthropicMessages(request: request, continuation: continuation)
        }
    }

    private static func streamOpenAIChat(
        request: AgentRequest,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async throws {
        let endpoint = try endpointURL(baseURL: request.providerConfig.baseURL, suffix: "chat/completions")
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeoutInterval(from: request.timeoutMs)
        try applyHeaders(to: &urlRequest, request: request)
        let messages = request.priorMessages.map(openAIMessage).filter { !$0.isEmpty } + [
            ["role": "user", "content": request.prompt]
        ]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": request.providerConfig.model,
            "messages": messages,
            "stream": true,
            "stream_options": [
                "include_usage": true,
            ],
        ])

        try await streamSSE(urlRequest: urlRequest, continuation: continuation) { object in
            for event in Self.openAIChatEvents(from: object, contextWindow: request.contextWindow) {
                continuation.yield(event)
            }
        }
    }

    private static func streamOpenAIResponses(
        request: AgentRequest,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async throws {
        let endpoint = try endpointURL(baseURL: request.providerConfig.baseURL, suffix: "responses")
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeoutInterval(from: request.timeoutMs)
        try applyHeaders(to: &urlRequest, request: request)
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": request.providerConfig.model,
            "input": request.prompt,
            "stream": true,
        ])

        try await streamSSE(urlRequest: urlRequest, continuation: continuation) { object in
            let type = object["type"] as? String
            if type == "response.output_text.delta",
               let delta = object["delta"] as? String {
                continuation.yield(.contentDelta(delta))
            }
            if let usage = object["usage"] as? [String: Any] {
                Self.yieldUsage(usage, contextWindow: request.contextWindow, continuation: continuation)
            }
        }
    }

    private static func streamAnthropicMessages(
        request: AgentRequest,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async throws {
        let endpoint = try endpointURL(baseURL: request.providerConfig.baseURL, suffix: "v1/messages")
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeoutInterval(from: request.timeoutMs)
        try applyHeaders(to: &urlRequest, request: request)
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": request.providerConfig.model,
            "max_tokens": 4096,
            "messages": [["role": "user", "content": request.prompt]],
            "stream": true,
        ])

        try await streamSSE(urlRequest: urlRequest, continuation: continuation) { object in
            if object["type"] as? String == "content_block_delta",
               let delta = object["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String {
                continuation.yield(.contentDelta(text))
            }
            if let usage = object["usage"] as? [String: Any] {
                Self.yieldUsage(usage, contextWindow: request.contextWindow, continuation: continuation)
            }
        }
    }

    private static func streamSSE(
        urlRequest: URLRequest,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation,
        handleObject: @escaping ([String: Any]) -> Void
    ) async throws {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
        } catch {
            throw mapTransportError(error)
        }
        guard let statusCode = (response as? HTTPURLResponse)?.statusCode else {
            throw ProviderClientError.invalidResponse
        }
        guard 200..<300 ~= statusCode else {
            let body = try await readErrorBody(from: bytes)
            throw ProviderClientError.httpError(statusCode: statusCode, body: body)
        }

        continuation.yield(.status("streaming"))
        for try await line in bytes.lines {
            if Task.isCancelled { throw CancellationError() }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            handleObject(object)
        }
    }

    static func endpointURL(baseURL: String, suffix: String) throws -> URL {
        let trimmed = baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedSuffix = suffix
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let value: String
        if trimmed.hasSuffix("/\(normalizedSuffix)") || trimmed.hasSuffix(normalizedSuffix) {
            value = trimmed
        } else {
            value = "\(trimmed)/\(normalizedSuffix)"
        }
        guard let url = URL(string: value), let scheme = url.scheme, !scheme.isEmpty else {
            throw ProviderClientError.invalidURL(baseURL)
        }
        return url
    }

    static func openAIChatEvents(from object: [String: Any], contextWindow: Int) -> [AgentEvent] {
        var events: [AgentEvent] = []
        if let choices = object["choices"] as? [[String: Any]],
           let delta = choices.first?["delta"] as? [String: Any],
           let content = delta["content"] as? String,
           !content.isEmpty {
            events.append(.contentDelta(content))
        }
        if let usage = object["usage"] as? [String: Any],
           let budget = tokenBudget(from: usage, contextWindow: contextWindow) {
            events.append(.tokenBudget(used: budget.used, total: budget.total))
        }
        return events
    }

    private static func applyHeaders(to request: inout URLRequest, request agentRequest: AgentRequest) throws {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let apiKey = agentRequest.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw ProviderClientError.missingAPIKey
        }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        for (key, value) in agentRequest.providerConfig.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
    }

    private static func openAIMessage(_ message: ChatMessage) -> [String: String] {
        let content = message.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return [:] }
        return ["role": message.role.rawValue, "content": content]
    }

    private static func yieldUsage(
        _ usage: [String: Any],
        contextWindow: Int,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) {
        let input = usage["input_tokens"] as? Int ?? usage["prompt_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? usage["completion_tokens"] as? Int ?? 0
        let total = usage["total_tokens"] as? Int ?? input + output
        if let budget = tokenBudget(from: usage, contextWindow: contextWindow), total > 0 {
            continuation.yield(.tokenBudget(used: budget.used, total: budget.total))
        }
    }

    private static func tokenBudget(from usage: [String: Any], contextWindow: Int) -> TokenBudget? {
        let input = usage["input_tokens"] as? Int ?? usage["prompt_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? usage["completion_tokens"] as? Int ?? 0
        let total = usage["total_tokens"] as? Int ?? input + output
        guard total > 0 else { return nil }
        return TokenBudget(used: total, total: max(contextWindow, total))
    }

    private static func timeoutInterval(from milliseconds: Int) -> TimeInterval {
        TimeInterval(max(milliseconds, 1_000)) / 1_000.0
    }

    private static func readErrorBody(from bytes: URLSession.AsyncBytes) async throws -> String {
        var body = ""
        for try await line in bytes.lines {
            if !body.isEmpty { body += "\n" }
            body += line
            if body.count > 4_096 {
                return String(body.prefix(4_096)) + "..."
            }
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func mapTransportError(_ error: Error) -> Error {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorAppTransportSecurityRequiresSecureConnection {
            return ProviderClientError.transport(
                "App Transport Security blocked the HTTP provider request. Rebuild and launch the latest 9GClaw app bundle so NSAppTransportSecurity is included."
            )
        }
        if nsError.domain == NSURLErrorDomain {
            return ProviderClientError.transport("Network request failed: \(nsError.localizedDescription)")
        }
        return error
    }
}

typealias ProviderClient = NativeAgentRuntime
