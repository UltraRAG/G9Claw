import Foundation

struct AgentRequest: Sendable {
    var sessionId: String
    var projectPath: String
    var prompt: String
    var providerConfig: ProviderConfig
    var apiKey: String
    var priorMessages: [ChatMessage]
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
    case unsupportedProvider(SessionProvider)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingBaseURL: "Provider base URL is not configured."
        case .missingModel: "Provider model is not configured."
        case .unsupportedProvider(let provider): "\(provider.displayName) is not implemented yet in native AgentCore."
        case .invalidResponse: "Provider returned an invalid response."
        }
    }
}

struct ProviderClient: Sendable {
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
                    continuation.finish(throwing: error)
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
        let endpoint = endpointURL(baseURL: request.providerConfig.baseURL, suffix: "chat/completions")
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        applyHeaders(to: &urlRequest, request: request)
        let messages = request.priorMessages.map(openAIMessage).filter { !$0.isEmpty } + [
            ["role": "user", "content": request.prompt]
        ]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": request.providerConfig.model,
            "messages": messages,
            "stream": true,
        ])

        try await streamSSE(urlRequest: urlRequest, continuation: continuation) { object in
            if let choices = object["choices"] as? [[String: Any]],
               let delta = choices.first?["delta"] as? [String: Any],
               let content = delta["content"] as? String,
               !content.isEmpty {
                continuation.yield(.contentDelta(content))
            }
            if let usage = object["usage"] as? [String: Any] {
                Self.yieldUsage(usage, continuation: continuation)
            }
        }
    }

    private static func streamOpenAIResponses(
        request: AgentRequest,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async throws {
        let endpoint = endpointURL(baseURL: request.providerConfig.baseURL, suffix: "responses")
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        applyHeaders(to: &urlRequest, request: request)
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
                Self.yieldUsage(usage, continuation: continuation)
            }
        }
    }

    private static func streamAnthropicMessages(
        request: AgentRequest,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async throws {
        let endpoint = endpointURL(baseURL: request.providerConfig.baseURL, suffix: "v1/messages")
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        applyHeaders(to: &urlRequest, request: request)
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
                Self.yieldUsage(usage, continuation: continuation)
            }
        }
    }

    private static func streamSSE(
        urlRequest: URLRequest,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation,
        handleObject: @escaping ([String: Any]) -> Void
    ) async throws {
        let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw ProviderClientError.invalidResponse
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

    private static func endpointURL(baseURL: String, suffix: String) -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.hasSuffix(suffix) {
            return URL(string: trimmed)!
        }
        return URL(string: "\(trimmed)/\(suffix)")!
    }

    private static func applyHeaders(to request: inout URLRequest, request agentRequest: AgentRequest) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(agentRequest.apiKey)", forHTTPHeaderField: "Authorization")
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
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) {
        let input = usage["input_tokens"] as? Int ?? usage["prompt_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? usage["completion_tokens"] as? Int ?? 0
        let total = usage["total_tokens"] as? Int ?? input + output
        if total > 0 {
            continuation.yield(.tokenBudget(used: total, total: 160_000))
        }
    }
}
