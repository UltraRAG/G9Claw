import Foundation

struct AgentPermissionRequest: Sendable, Equatable {
    var id: UUID
    var sessionId: String
    var toolName: String
    var inputJSON: String
    var reason: String
    var scope: PermissionScope
    var kind: PermissionRequestKind = .tool
    var interactivePayload: AgentInteractivePayload? = nil
}

enum AgentPermissionDecision: Sendable, Equatable {
    case allow(remember: Bool, updatedInputJSON: String?)
    case deny
}

struct AgentRequest: Sendable {
    var sessionId: String
    var projectPath: String
    var prompt: String
    var attachments: [FileAttachment] = []
    var providerConfig: ProviderConfig
    var apiKey: String
    var priorMessages: [ChatMessage]
    var timeoutMs: Int
    var contextWindow: Int
    var permissionMode: ComposerPermissionMode
    var runMode: ChatRunMode
    var workspaceContext: WorkspaceContext?
    var toolSettings: ToolPermissionSettings
    var routerRoute: String
    var permissionHandler: (@MainActor @Sendable (AgentPermissionRequest) async -> AgentPermissionDecision)?
}

struct AgentToolCall: Sendable, Equatable {
    var id: String
    var name: String
    var inputJSON: String

    var signature: String {
        "\(name):\(Self.canonicalJSON(inputJSON))"
    }

    private static func canonicalJSON(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let canonicalData = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let canonical = String(data: canonicalData, encoding: .utf8) else {
            return json.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return canonical
    }
}

struct ToolArgumentNormalizer {
    struct NormalizationError: Error, Sendable, Equatable {
        var message: String
    }

    struct NormalizedInvocation: Sendable, Equatable {
        var call: AgentToolCall
        var recoveryResult: AgentToolResult?
    }

    static let invalidJSONRecoveryMessage = "Tool input was invalid JSON. Retry with a JSON object using double-quoted keys and strings."

    static func normalize(_ calls: [AgentToolCall]) -> [NormalizedInvocation] {
        calls.map(normalize)
    }

    static func normalize(_ call: AgentToolCall) -> NormalizedInvocation {
        switch canonicalObjectJSONString(call.inputJSON) {
        case .success(let canonical):
            return NormalizedInvocation(
                call: AgentToolCall(id: call.id, name: call.name, inputJSON: canonical),
                recoveryResult: nil
            )
        case .failure(let error):
            let safeCall = AgentToolCall(id: call.id, name: call.name, inputJSON: "{}")
            let output = "\(invalidJSONRecoveryMessage)\n\nTool: \(call.name)\nError: \(error.message)"
            return NormalizedInvocation(
                call: safeCall,
                recoveryResult: AgentToolResult(
                    callId: call.id,
                    toolName: call.name,
                    output: output,
                    isError: true
                )
            )
        }
    }

    static func providerSafeInputJSON(_ inputJSON: String) -> String {
        switch canonicalObjectJSONString(inputJSON) {
        case .success(let canonical):
            return canonical
        case .failure:
            return "{}"
        }
    }

    static func canonicalObjectJSONString(_ inputJSON: String) -> Result<String, NormalizationError> {
        let trimmed = inputJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? "{}" : trimmed
        guard let data = value.data(using: .utf8) else {
            return .failure(NormalizationError(message: "Input was not valid UTF-8."))
        }
        do {
            let parsed = try JSONSerialization.jsonObject(with: data)
            guard let object = parsed as? [String: Any] else {
                return .failure(NormalizationError(message: "Tool arguments must be a JSON object."))
            }
            guard JSONSerialization.isValidJSONObject(object) else {
                return .failure(NormalizationError(message: "Tool arguments contain a value that cannot be encoded as JSON."))
            }
            let canonicalData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            guard let canonical = String(data: canonicalData, encoding: .utf8) else {
                return .failure(NormalizationError(message: "Canonical JSON could not be encoded as UTF-8."))
            }
            return .success(canonical)
        } catch {
            return .failure(NormalizationError(message: error.localizedDescription))
        }
    }
}

struct AgentToolResult: Sendable, Equatable {
    var callId: String
    var toolName: String
    var output: String
    var isError: Bool
}

final class AgentRunContext: @unchecked Sendable {
    var sessionId: String
    var workspacePath: String
    var runMode: ChatRunMode
    var permissionMode: ComposerPermissionMode
    var toolSettings: ToolPermissionSettings
    var planExited: Bool
    var todosJSON: String
    var continuationNudgeCount: Int
    var toolExecutionCount: Int
    var successfulToolExecutionCount: Int
    var exploratoryToolCount: Int
    var mutatingToolCount: Int
    var failedToolCount: Int
    var recoverableProtocolErrorCount: Int
    var lastExecutedToolName: String?
    var lastToolResultWasError: Bool
    private var executedToolSignatures: Set<String>

    init(request: AgentRequest) {
        sessionId = request.sessionId
        workspacePath = request.projectPath
        runMode = request.runMode
        permissionMode = request.permissionMode
        toolSettings = request.toolSettings
        planExited = request.runMode == .agent
        todosJSON = "[]"
        continuationNudgeCount = 0
        toolExecutionCount = 0
        successfulToolExecutionCount = 0
        exploratoryToolCount = 0
        mutatingToolCount = 0
        failedToolCount = 0
        recoverableProtocolErrorCount = 0
        lastExecutedToolName = nil
        lastToolResultWasError = false
        executedToolSignatures = []
    }

    func markToolCallIfNeeded(_ call: AgentToolCall) -> Bool {
        executedToolSignatures.insert(call.signature).inserted
    }

    func recordToolResult(_ result: AgentToolResult, call: AgentToolCall) {
        toolExecutionCount += 1
        lastExecutedToolName = result.toolName
        lastToolResultWasError = result.isError
        if !result.isError {
            successfulToolExecutionCount += 1
        } else {
            failedToolCount += 1
            if result.output.contains(ToolArgumentNormalizer.invalidJSONRecoveryMessage) {
                recoverableProtocolErrorCount += 1
            }
        }
        switch result.toolName {
        case "Read", "Glob", "Grep", "TodoRead":
            exploratoryToolCount += 1
        case "Write", "Edit", "MultiEdit", "Bash":
            if result.isError {
                break
            } else if result.toolName == "Bash", Self.isReadOnlyBash(call.inputJSON) {
                exploratoryToolCount += 1
            } else {
                mutatingToolCount += 1
            }
        default:
            break
        }
    }

    private static func isReadOnlyBash(_ inputJSON: String) -> Bool {
        guard let data = inputJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = object["command"] as? String else {
            return false
        }
        let trimmed = command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !trimmed.isEmpty else { return false }
        let writeMarkers = [">", ">>", "| tee", "rm ", "mv ", "cp ", "mkdir ", "touch ", "sed -i", "perl -pi", "python ", "node ", "npm ", "bun ", "swift "]
        if writeMarkers.contains(where: { trimmed.contains($0) }) {
            return false
        }
        let readPrefixes = ["ls", "find", "grep", "rg", "cat", "pwd", "wc", "head", "tail", "stat", "git status", "git diff", "git log"]
        return readPrefixes.contains { trimmed == $0 || trimmed.hasPrefix($0 + " ") }
    }
}

enum AgentLoopState: Sendable, Equatable {
    case thinking
    case runningTool(String)
    case waitingForPermission(String)
    case complete
    case error(String)
}

enum ContinuationPolicy {
    static let maxNudges = 3
    static let maxRecoverableProtocolErrors = 3
}

enum CompletionGate {
    static func canFinish(request: AgentRequest, context: AgentRunContext, assistantContent: String) -> Bool {
        if context.lastToolResultWasError {
            return false
        }
        guard NativeAgentRuntime.isWorkspaceMutationRequest(request.prompt.lowercased()) else {
            return true
        }
        if context.runMode == .plan, !context.planExited {
            return false
        }
        if context.mutatingToolCount == 0 {
            return false
        }
        let content = assistantContent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if content.isEmpty || content == "bash" || content == "json" {
            return false
        }
        return true
    }
}

enum AgentEvent: Sendable, Equatable {
    case turnStarted(AgentTurn)
    case turnItemStarted(AgentTurnItem)
    case turnItemUpdated(AgentTurnItem)
    case turnItemCompleted(AgentTurnItem)
    case turnCompleted(AgentTurn)
    case sessionCreated(sessionId: String)
    case contentDelta(String)
    case toolUse(id: String, name: String, inputJSON: String)
    case toolResult(id: String, output: String, isError: Bool)
    case permissionRequest(AgentPermissionRequest)
    case status(String)
    case tokenBudget(used: Int, total: Int)
    case streamEnd
    case complete(sessionId: String)
    case aborted(sessionId: String)
    case error(String)
}

extension AgentEvent {
    var isTerminal: Bool {
        switch self {
        case .complete, .aborted, .error:
            return true
        default:
            return false
        }
    }
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
    case streamInterruptedAfterPartialOutput(String)
    case toolExecution(String)

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
        case .streamInterruptedAfterPartialOutput(let message):
            "Provider response stream disconnected after partial output: \(message)"
        case .toolExecution(let message): message
        }
    }
}

struct ProviderRetryPolicy: Sendable, Equatable {
    var requestMaxRetries: Int
    var streamMaxRetries: Int
    var baseDelayMs: Int
    var retry429: Bool
    var retry5xx: Bool
    var retryTransport: Bool

    static let codexDefault = ProviderRetryPolicy(
        requestMaxRetries: 4,
        streamMaxRetries: 5,
        baseDelayMs: 200,
        retry429: false,
        retry5xx: true,
        retryTransport: true
    )
}

struct ProviderRetryDecision: Sendable, Equatable {
    var shouldRetry: Bool
    var delay: TimeInterval
    var reason: String

    static let noRetry = ProviderRetryDecision(shouldRetry: false, delay: 0, reason: "")
}

struct NativeAgentRuntime: Sendable {
    private static let maxAgentIterations = 24
    private static let threadManager = NativeThreadManager()

    func stream(request: AgentRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let nativeSession = await Self.threadManager.session(for: request)
                let turnController = await nativeSession.startTurn(request: request)
                do {
                    let startedTurn = await turnController.snapshot()
                    continuation.yield(.turnStarted(startedTurn))
                    let userItem = await turnController.recordUserMessage(request.prompt)
                    continuation.yield(.turnItemCompleted(userItem))
                    continuation.yield(.sessionCreated(sessionId: request.sessionId))
                    let connectingItem = await turnController.recordStatus("connecting")
                    continuation.yield(.turnItemStarted(connectingItem))
                    continuation.yield(.status("connecting"))

                    switch request.providerConfig.provider {
                    case .nineGClaw:
                        try await Self.streamNineGClawAgent(
                            request: request,
                            continuation: continuation,
                            turnController: turnController
                        )
                    case .claude, .cursor, .codex, .gemini:
                        throw ProviderClientError.unsupportedProvider(request.providerConfig.provider)
                    }

                    continuation.yield(.streamEnd)
                    await turnController.finish()
                    await nativeSession.recordSnapshot(from: turnController)
                    continuation.yield(.turnCompleted(await turnController.snapshot()))
                    continuation.yield(.complete(sessionId: request.sessionId))
                    continuation.finish()
                } catch is CancellationError {
                    await turnController.interrupt(reason: "Cancelled.")
                    await nativeSession.recordSnapshot(from: turnController)
                    continuation.yield(.turnCompleted(await turnController.snapshot()))
                    continuation.yield(.aborted(sessionId: request.sessionId))
                    continuation.finish()
                } catch {
                    await turnController.fail(reason: error.localizedDescription)
                    await nativeSession.recordSnapshot(from: turnController)
                    continuation.yield(.turnCompleted(await turnController.snapshot()))
                    continuation.yield(.error(error.localizedDescription))
                    continuation.finish()
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private static func streamNineGClawAgent(
        request: AgentRequest,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation,
        turnController: NativeTurnController
    ) async throws {
        let config = request.providerConfig
        guard !config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderClientError.missingBaseURL
        }
        guard !config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderClientError.missingModel
        }
        guard config.apiType == .openAIChat else {
            throw ProviderClientError.unsupportedProvider(config.provider)
        }

        let context = AgentRunContext(request: request)
        var messages = openAIInitialMessages(request: request)
        var didForceWorkspaceBootstrap = false

        for iteration in 1...maxAgentIterations {
            if Task.isCancelled { throw CancellationError() }
            let statusItem = await turnController.recordStatus(iteration == 1 ? "thinking" : "processing")
            continuation.yield(.turnItemStarted(statusItem))
            continuation.yield(.status(iteration == 1 ? "thinking" : "processing"))
            let turn = try await performOpenAIChatTurnWithRetry(
                request: request,
                messages: messages,
                continuation: continuation
            )
            if let assistantItem = await turnController.recordAssistantText(turn.assistantContent) {
                continuation.yield(.turnItemCompleted(assistantItem))
            }

            var rawToolCalls = turn.toolCalls
            if rawToolCalls.isEmpty {
                rawToolCalls = fallbackToolCalls(in: turn.assistantContent)
            }
            var toolInvocations = ToolArgumentNormalizer
                .normalize(rawToolCalls)
                .filter { context.markToolCallIfNeeded($0.call) }
            if toolInvocations.isEmpty,
               !didForceWorkspaceBootstrap,
               shouldForceWorkspaceBootstrap(request: request, context: context, assistantContent: turn.assistantContent) {
                didForceWorkspaceBootstrap = true
                let call = forcedWorkspaceBootstrapToolCall()
                let invocation = ToolArgumentNormalizer.normalize(call)
                if context.markToolCallIfNeeded(invocation.call) {
                    let exploreItem = await turnController.recordStatus("exploring workspace")
                    continuation.yield(.turnItemStarted(exploreItem))
                    continuation.yield(.status("exploring workspace"))
                    toolInvocations = [invocation]
                }
            }

            if toolInvocations.isEmpty {
                if let nudge = continuationNudge(request: request, context: context, assistantContent: turn.assistantContent) {
                    appendAssistantContentIfNeeded(turn.assistantContent, to: &messages)
                    messages.append([
                        "role": "user",
                        "content": nudge,
                    ])
                    context.continuationNudgeCount += 1
                    let nudgeItem = await turnController.recordStatus("continuing")
                    continuation.yield(.turnItemStarted(nudgeItem))
                    continuation.yield(.status("continuing"))
                    continue
                }
                if !CompletionGate.canFinish(request: request, context: context, assistantContent: turn.assistantContent) {
                    throw ProviderClientError.transport(
                        "Agent stopped before completing the requested workspace change. No pending tool call was returned after \(context.toolExecutionCount) tool step(s)."
                    )
                }
                return
            }
            let assistantToolContent = isHiddenToolProtocol(turn.assistantContent) ? "" : turn.assistantContent
            let toolCalls = toolInvocations.map(\.call)
            messages.append(openAIAssistantToolMessage(content: assistantToolContent, toolCalls: toolCalls))

            for invocation in toolInvocations {
                let call = invocation.call
                if Task.isCancelled { throw CancellationError() }
                let runningItem = await turnController.recordStatus(invocation.recoveryResult == nil ? "running \(call.name)" : "recovering \(call.name)")
                continuation.yield(.turnItemStarted(runningItem))
                continuation.yield(.status(invocation.recoveryResult == nil ? "running \(call.name)" : "recovering \(call.name)"))
                let toolItem = await turnController.recordToolCall(call)
                continuation.yield(.turnItemStarted(toolItem))
                continuation.yield(.toolUse(id: call.id, name: call.name, inputJSON: call.inputJSON))
                let result: AgentToolResult
                if let recoveryResult = invocation.recoveryResult {
                    result = recoveryResult
                } else {
                    result = await executeToolWithPolicy(
                        call: call,
                        context: context,
                        request: request,
                        continuation: continuation
                    )
                }
                let recorded = await turnController.recordToolResult(result)
                if let callItem = recorded.callItem {
                    continuation.yield(.turnItemUpdated(callItem))
                }
                continuation.yield(.turnItemCompleted(recorded.resultItem))
                continuation.yield(.toolResult(id: call.id, output: result.output, isError: result.isError))
                context.recordToolResult(result, call: call)
                if result.toolName == "ExitPlanMode" || result.toolName == "ExitPlanModeV2" || result.toolName == "exit_plan_mode" {
                    await turnController.markPlanExited()
                    let executeItem = await turnController.recordStatus("executing plan")
                    continuation.yield(.turnItemStarted(executeItem))
                    continuation.yield(.status("executing plan"))
                }
                messages.append(openAIToolResultMessage(result))
                if !result.isError,
                   result.toolName == "ExitPlanMode" || result.toolName == "ExitPlanModeV2" || result.toolName == "exit_plan_mode" {
                    messages.append([
                        "role": "user",
                        "content": "The plan was approved. Continue executing it now in agent mode. Use concrete file/search/shell tools and do not stop after restating the plan.",
                    ])
                    context.continuationNudgeCount += 1
                }
            }
        }

        throw ProviderClientError.transport("Agent loop reached the maximum iteration limit.")
    }

    private static func performOpenAIChatTurnWithRetry(
        request: AgentRequest,
        messages: [[String: Any]],
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation,
        policy: ProviderRetryPolicy = .codexDefault
    ) async throws -> ModelTurn {
        var failedAttempts = 0
        while true {
            do {
                return try await performOpenAIChatTurn(
                    request: request,
                    messages: messages,
                    continuation: continuation
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let decision = retryDecision(for: error, failedAttempts: failedAttempts, policy: policy)
                guard decision.shouldRetry else {
                    if isRetryableProviderError(error, policy: policy) != nil, failedAttempts >= policy.streamMaxRetries {
                        throw ProviderClientError.transport(
                            "Provider request failed after \(failedAttempts + 1) attempts: \(error.localizedDescription)"
                        )
                    }
                    throw error
                }

                failedAttempts += 1
                continuation.yield(.status("Reconnecting... \(failedAttempts)/\(policy.streamMaxRetries)"))
                AppLog.write("provider retry \(failedAttempts)/\(policy.streamMaxRetries): \(decision.reason)")
                try await sleepForRetryDelay(decision.delay)
            }
        }
    }

    private static func performOpenAIChatTurn(
        request: AgentRequest,
        messages: [[String: Any]],
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async throws -> ModelTurn {
        let endpoint = try endpointURL(baseURL: request.providerConfig.baseURL, suffix: "chat/completions")
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeoutInterval(from: request.timeoutMs)
        try applyHeaders(to: &urlRequest, request: request)
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": request.providerConfig.model,
            "messages": messages,
            "stream": true,
            "stream_options": [
                "include_usage": true,
            ],
            "tools": NativeToolRouter.openAITools(),
            "tool_choice": "auto",
        ])

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

        var content = ""
        var heldContent = ""
        var shouldStreamContent = false
        var didYieldVisibleContent = false
        var accumulators: [Int: OpenAIToolCallAccumulator] = [:]
        continuation.yield(.status("streaming"))

        do {
            for try await line in bytes.lines {
                if Task.isCancelled { throw CancellationError() }
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
                if payload == "[DONE]" { break }
                guard let data = payload.data(using: .utf8),
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }
                for event in openAIChatEvents(from: object, contextWindow: request.contextWindow) {
                    if case .contentDelta(let delta) = event {
                        content += delta
                        if shouldStreamContent {
                            continuation.yield(event)
                            didYieldVisibleContent = true
                        } else {
                            heldContent += delta
                            let sample = heldContent.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !sample.isEmpty, !looksLikeProtocolPrefix(sample) {
                                shouldStreamContent = true
                                continuation.yield(.contentDelta(heldContent))
                                didYieldVisibleContent = true
                                heldContent = ""
                            }
                        }
                    } else {
                        continuation.yield(event)
                    }
                }
                if let choices = object["choices"] as? [[String: Any]],
                   let delta = choices.first?["delta"] as? [String: Any],
                   let rawCalls = delta["tool_calls"] as? [[String: Any]] {
                    for rawCall in rawCalls {
                        let index = rawCall["index"] as? Int ?? 0
                        var accumulator = accumulators[index] ?? OpenAIToolCallAccumulator(index: index)
                        accumulator.apply(delta: rawCall)
                        accumulators[index] = accumulator
                    }
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let mapped = mapTransportError(error)
            if didYieldVisibleContent {
                throw ProviderClientError.streamInterruptedAfterPartialOutput(mapped.localizedDescription)
            }
            throw mapped
        }

        if !heldContent.isEmpty, !isHiddenToolProtocol(content) {
            continuation.yield(.contentDelta(heldContent))
        }

        let calls = accumulators.keys.sorted().compactMap { accumulators[$0]?.toolCall }
        return ModelTurn(assistantContent: content, toolCalls: calls)
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

    static func fallbackToolCalls(in text: String) -> [AgentToolCall] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if let json = wholeFencedJSONEnvelope(in: trimmed) {
            return jsonFallbackToolCalls(in: json)
        }
        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
            return jsonFallbackToolCalls(in: trimmed)
        }
        if let responseJSON = wholeXMLEnvelope(named: "response", in: trimmed) {
            return jsonFallbackToolCalls(in: responseJSON)
        }
        let compactCalls = compactXMLFallbackToolCalls(in: trimmed)
        if !compactCalls.isEmpty {
            return compactCalls
        }
        if trimmed.hasPrefix("<tool_call"), trimmed.hasSuffix("</tool_call>") {
            return xmlFallbackToolCalls(in: trimmed)
        }
        if let call = legacyCommandFallbackToolCall(in: trimmed) {
            return [call]
        }
        return []
    }

    private static func looksLikeProtocolPrefix(_ text: String) -> Bool {
        text.hasPrefix("<") || text.hasPrefix("{") || text.hasPrefix("```")
    }

    private static func isHiddenToolProtocol(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if trimmed.range(of: #"^<CALL_[A-Z_]+>"#, options: .regularExpression) != nil {
            return true
        }
        if lower.hasPrefix("<call") || lower.hasPrefix("<response") || lower.hasPrefix("<command") || lower.hasPrefix("<bash") || lower.hasPrefix("<tool") {
            return true
        }
        return !fallbackToolCalls(in: trimmed).isEmpty
    }

    private static func openAIInitialMessages(request: AgentRequest) -> [[String: Any]] {
        var messages: [[String: Any]] = [
            [
                "role": "system",
                "content": nativeAgentSystemPrompt(request: request),
            ],
        ]
        for message in request.priorMessages {
            guard let converted = openAIMessage(message) else { continue }
            messages.append(converted)
        }
        messages.append(openAIUserMessage(prompt: request.prompt, attachments: request.attachments))
        return messages
    }

    private static func nativeAgentSystemPrompt(request: AgentRequest) -> String {
        let modeText = request.runMode == .plan
            ? "You are in plan mode. Read/search/todo tools are allowed. Do not edit files or run shell commands until ExitPlanMode is called."
            : "You are in agent mode. Use tools to inspect and modify the workspace."
        return """
        You are 9GClaw, a native macOS coding agent with a Claude Code style workflow.
        Workspace root: \(request.projectPath)
        \(modeText)

        Use the provided tools for all file reads, file writes, edits, searches, todos, and shell commands.
        Never claim that you created, edited, deleted, or inspected a file unless the corresponding tool result confirms it.
        Prefer small, verifiable steps: inspect files, make precise edits, run focused checks, then summarize.
        For shell commands, use Bash only when needed and keep commands scoped to the workspace.
        If OpenAI tool calling is unavailable, emit exactly one raw JSON fallback tool request and no other prose in that assistant turn.
        Example: {"tool":"Read","input":{"file_path":"README.md"}}
        Do not emit markdown fences, language labels such as "bash" or "json", or a prose explanation when requesting a tool.
        """
    }

    static func shouldForceWorkspaceBootstrap(request: AgentRequest, context: AgentRunContext, assistantContent: String) -> Bool {
        let prompt = request.prompt.lowercased()
        let content = assistantContent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let workspaceVerbs = [
            "网页", "网站", "项目", "文件", "代码", "实现", "生成", "修改", "优化", "修复", "完善",
            "create", "build", "edit", "modify", "fix", "optimize", "implement", "file", "website", "page", "code",
        ]
        guard workspaceVerbs.contains(where: { prompt.contains($0) }) else { return false }
        if content.contains("```") || content == "bash" || content == "json" {
            return true
        }
        let finalOnlyPhrases = ["cannot", "无法", "不能", "不支持", "没有权限"]
        return !finalOnlyPhrases.contains { content.contains($0) }
    }

    static func continuationNudge(request: AgentRequest, context: AgentRunContext, assistantContent: String) -> String? {
        guard context.continuationNudgeCount < ContinuationPolicy.maxNudges else { return nil }
        guard context.recoverableProtocolErrorCount < ContinuationPolicy.maxRecoverableProtocolErrors else { return nil }
        let content = assistantContent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let prompt = request.prompt.lowercased()
        guard isWorkspaceMutationRequest(prompt) else { return nil }
        let refusalPhrases = ["cannot", "can't", "unable", "无法", "不能", "没有权限", "不支持"]
        if refusalPhrases.contains(where: { content.contains($0) }) {
            return nil
        }
        if request.runMode == .plan, !context.planExited {
            return """
            Continue the planning turn. If the plan is concrete enough to execute, call ExitPlanMode with the plan so the same turn can proceed to implementation. Do not stop after prose only.
            """
        }
        if context.mutatingToolCount == 0 {
            return """
            Continue the workspace task. You have not completed the requested change yet.
            Use the available tools for the next concrete step. Inspect files if needed, then edit or write files before giving a final summary.
            Do not stop after describing the plan or after a single search result.
            """
        }
        if context.lastToolResultWasError {
            return """
            Continue debugging the failed tool step. Use another safe tool call or explain the concrete blocker only if no tool can make progress.
            """
        }
        return nil
    }

    static func isWorkspaceMutationRequest(_ prompt: String) -> Bool {
        let mutationVerbs = [
            "创建", "新建", "生成", "做一个", "帮我做", "修改", "优化", "修复", "完善", "继续", "实现", "重写", "调整", "编辑", "保存",
            "create", "build", "generate", "make", "write", "edit", "modify", "fix", "optimize", "implement", "rewrite", "update", "improve", "save",
        ]
        return mutationVerbs.contains { prompt.contains($0) }
    }

    private static func appendAssistantContentIfNeeded(_ content: String, to messages: inout [[String: Any]]) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isHiddenToolProtocol(trimmed) else { return }
        messages.append([
            "role": "assistant",
            "content": trimmed,
        ])
    }

    private static func forcedWorkspaceBootstrapToolCall() -> AgentToolCall {
        AgentToolCall(
            id: "native-bootstrap-\(UUID().uuidString)",
            name: "Glob",
            inputJSON: jsonString([
                "pattern": "**/*",
                "path": ".",
            ])
        )
    }

    private static func openAIMessage(_ message: ChatMessage) -> [String: Any]? {
        let content = message.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }
        switch message.role {
        case .user:
            return ["role": "user", "content": content]
        case .assistant:
            return ["role": "assistant", "content": content]
        case .system:
            return ["role": "system", "content": content]
        case .tool:
            return nil
        }
    }

    private static func openAIUserMessage(prompt: String, attachments: [FileAttachment]) -> [String: Any] {
        let imageParts = attachments.compactMap(imageContentPart)
        guard !imageParts.isEmpty else {
            return ["role": "user", "content": prompt]
        }
        var content: [[String: Any]] = [
            [
                "type": "text",
                "text": prompt,
            ],
        ]
        content.append(contentsOf: imageParts)
        return ["role": "user", "content": content]
    }

    private static func imageContentPart(_ attachment: FileAttachment) -> [String: Any]? {
        guard attachment.isImage else { return nil }
        let url = URL(fileURLWithPath: attachment.path)
        guard
            let data = try? Data(contentsOf: url),
            !data.isEmpty,
            data.count <= 8_000_000
        else { return nil }
        let mimeType = attachment.mimeType ?? "image/png"
        return [
            "type": "image_url",
            "image_url": [
                "url": "data:\(mimeType);base64,\(data.base64EncodedString())",
            ],
        ]
    }

    private static func openAIAssistantToolMessage(content: String, toolCalls: [AgentToolCall]) -> [String: Any] {
        [
            "role": "assistant",
            "content": content.isEmpty ? NSNull() : content,
            "tool_calls": toolCalls.map { call in
                [
                    "id": call.id,
                    "type": "function",
                    "function": [
                        "name": call.name,
                        "arguments": ToolArgumentNormalizer.providerSafeInputJSON(call.inputJSON),
                    ],
                ]
            },
        ]
    }

    private static func openAIToolResultMessage(_ result: AgentToolResult) -> [String: Any] {
        [
            "role": "tool",
            "tool_call_id": result.callId,
            "content": result.output,
        ]
    }

    private static func executeToolWithPolicy(
        call: AgentToolCall,
        context: AgentRunContext,
        request: AgentRequest,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async -> AgentToolResult {
        let requestKind = permissionKind(for: call.name)
        let interactivePayload = requestKind == .askUserQuestion
            ? AgentInteractivePayload.askUserQuestion(from: call.inputJSON)
            : nil
        let policy = NativeToolRouter.permissionPolicy(for: call, context: context)
        switch policy {
        case .allow:
            break
        case .deny(let reason):
            return AgentToolResult(callId: call.id, toolName: call.name, output: reason, isError: true)
        case .ask(let reason):
            let permission = AgentPermissionRequest(
                id: UUID(),
                sessionId: context.sessionId,
                toolName: call.name,
                inputJSON: call.inputJSON,
                reason: reason,
                scope: .session,
                kind: requestKind,
                interactivePayload: interactivePayload
            )
            continuation.yield(.permissionRequest(permission))
            continuation.yield(.status("waiting for permission"))
            let decision = await request.permissionHandler?(permission) ?? .deny
            switch decision {
            case .allow(_, let updatedInputJSON):
                if requestKind == .askUserQuestion {
                    return AgentToolExecutor.askUserQuestionResult(
                        call: call,
                        updatedInputJSON: updatedInputJSON ?? call.inputJSON
                    )
                }
                if let updatedInputJSON {
                    return await NativeToolRouter.execute(
                        call: AgentToolCall(id: call.id, name: call.name, inputJSON: updatedInputJSON),
                        context: context
                    )
                }
            case .deny:
                return AgentToolResult(
                    callId: call.id,
                    toolName: call.name,
                    output: "Permission denied for \(call.name).",
                    isError: true
                )
            }
        }

        return await NativeToolRouter.execute(call: call, context: context)
    }

    private static func permissionKind(for toolName: String) -> PermissionRequestKind {
        switch toolName {
        case "AskUserQuestion":
            return .askUserQuestion
        case "ExitPlanMode", "ExitPlanModeV2", "exit_plan_mode":
            return .exitPlanMode
        default:
            return .tool
        }
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

    static func retryDecision(
        for error: Error,
        failedAttempts: Int,
        policy: ProviderRetryPolicy = .codexDefault
    ) -> ProviderRetryDecision {
        guard let reason = isRetryableProviderError(error, policy: policy),
              failedAttempts < policy.streamMaxRetries else {
            return .noRetry
        }
        return ProviderRetryDecision(
            shouldRetry: true,
            delay: retryBackoffDelay(failedAttempts: failedAttempts, baseDelayMs: policy.baseDelayMs),
            reason: reason
        )
    }

    static func isRetryableProviderError(_ error: Error, policy: ProviderRetryPolicy = .codexDefault) -> String? {
        if error is CancellationError {
            return nil
        }
        if case ProviderClientError.streamInterruptedAfterPartialOutput = error {
            return nil
        }
        if let providerError = error as? ProviderClientError {
            switch providerError {
            case .httpError(let statusCode, _):
                if statusCode == 429 {
                    return policy.retry429 ? "HTTP 429 rate limit" : nil
                }
                return policy.retry5xx && (500..<600).contains(statusCode) ? "HTTP \(statusCode)" : nil
            case .transport(let message):
                let lower = message.lowercased()
                if lower.contains("app transport security") {
                    return nil
                }
                return policy.retryTransport ? "transport failure" : nil
            default:
                return nil
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorCancelled, NSURLErrorAppTransportSecurityRequiresSecureConnection:
                return nil
            default:
                return policy.retryTransport ? "network \(nsError.code)" : nil
            }
        }
        return nil
    }

    static func retryBackoffDelay(failedAttempts: Int, baseDelayMs: Int) -> TimeInterval {
        let retryNumber = max(failedAttempts + 1, 1)
        let exponent = min(retryNumber - 1, 8)
        let multiplier = pow(2.0, Double(exponent))
        let jitter = Double.random(in: 0.9...1.1)
        return (Double(max(baseDelayMs, 1)) * multiplier * jitter) / 1_000.0
    }

    private static func sleepForRetryDelay(_ delay: TimeInterval) async throws {
        let clamped = min(max(delay, 0), 30)
        let nanoseconds = UInt64(clamped * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
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
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return CancellationError()
        }
        if nsError.domain == NSURLErrorDomain {
            return ProviderClientError.transport("Network request failed: \(nsError.localizedDescription)")
        }
        return error
    }

    private static func wholeFencedJSONEnvelope(in text: String) -> String? {
        let pattern = #"(?s)^```(?:json)?\s*(\{.*\})\s*```$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsText = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)),
              match.numberOfRanges > 1 else {
            return nil
        }
        return nsText.substring(with: match.range(at: 1))
    }

    private static func wholeXMLEnvelope(named name: String, in text: String) -> String? {
        let pattern = #"(?is)^<\#(name)>\s*(\{.*\})\s*</\#(name)>$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsText = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)),
              match.numberOfRanges > 1 else {
            return nil
        }
        return nsText.substring(with: match.range(at: 1))
    }

    private static func jsonFallbackToolCalls(in snippet: String) -> [AgentToolCall] {
        guard let data = snippet.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return toolCalls(fromJSONObject: object)
    }

    private static func xmlFallbackToolCalls(in text: String) -> [AgentToolCall] {
        let pattern = #"(?s)<tool_call\s+name=["']([^"']+)["']\s*>(.*?)</tool_call>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsText = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).compactMap { match in
            guard match.numberOfRanges > 2 else { return nil }
            let name = nsText.substring(with: match.range(at: 1))
            let body = nsText.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            let inputJSON = body.hasPrefix("{") ? body : jsonString(["input": body])
            return AgentToolCall(id: "fallback-\(UUID().uuidString)", name: name, inputJSON: inputJSON)
        }
    }

    private static func compactXMLFallbackToolCalls(in text: String) -> [AgentToolCall] {
        let pattern = #"<call=\"([^\"]+)\":(\{[^<]*?\})\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsText = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).compactMap { match in
            guard match.numberOfRanges > 2 else { return nil }
            let rawName = nsText.substring(with: match.range(at: 1))
            let rawInput = nsText.substring(with: match.range(at: 2))
            return compactXMLToolCall(name: rawName, inputJSON: rawInput)
        }
    }

    private static func compactXMLToolCall(name rawName: String, inputJSON rawInput: String) -> AgentToolCall? {
        let input = (try? AgentToolExecutor.inputObject(from: rawInput)) ?? [:]
        let lowerName = rawName.lowercased()
        let toolName: String
        let normalizedInput: [String: Any]
        switch lowerName {
        case "executebash", "bash", "runcommand":
            let command = (input["command"] as? String)
                ?? (input["input_command"] as? String)
                ?? (input["input"] as? String)
                ?? ""
            if command.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("ls") {
                toolName = "Glob"
                normalizedInput = ["pattern": "*", "path": "."]
            } else {
                toolName = "Bash"
                normalizedInput = ["command": command]
            }
        case "readfile", "read":
            toolName = "Read"
            normalizedInput = [
                "file_path": (input["file_path"] as? String)
                    ?? (input["path"] as? String)
                    ?? (input["input"] as? String)
                    ?? "",
            ]
        case "writefile", "write":
            toolName = "Write"
            normalizedInput = [
                "file_path": (input["file_path"] as? String) ?? (input["path"] as? String) ?? "",
                "content": (input["content"] as? String) ?? "",
            ]
        case "editfile", "edit":
            toolName = "Edit"
            normalizedInput = [
                "file_path": (input["file_path"] as? String) ?? (input["path"] as? String) ?? "",
                "old_string": (input["old_string"] as? String) ?? "",
                "new_string": (input["new_string"] as? String) ?? "",
            ]
        default:
            return nil
        }
        return AgentToolCall(
            id: "fallback-\(UUID().uuidString)",
            name: toolName,
            inputJSON: jsonString(normalizedInput)
        )
    }

    private static func legacyCommandFallbackToolCall(in text: String) -> AgentToolCall? {
        let patterns = [
            #"(?s)^<command>\s*(.*?)\s*</command>$"#,
            #"(?s)^<bash>\s*(.*?)\s*</bash>$"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsText = text as NSString
            guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)),
                  match.numberOfRanges > 1 else { continue }
            let body = nsText.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            let command: String
            let description: String
            if body.hasPrefix("{"),
               let data = body.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                command = (object["command"] as? String)
                    ?? (object["cmd"] as? String)
                    ?? (object["input"] as? String)
                    ?? ""
                description = (object["description"] as? String) ?? "Run workspace command"
            } else {
                command = body
                description = "Run workspace command"
            }
            let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedCommand.isEmpty else { return nil }
            let normalizedInput: [String: Any]
            let toolName: String
            if trimmedCommand == "ls" || trimmedCommand.hasPrefix("ls ") {
                toolName = "Glob"
                normalizedInput = ["pattern": "*", "path": "."]
            } else {
                toolName = "Bash"
                normalizedInput = ["command": trimmedCommand, "description": description]
            }
            return AgentToolCall(id: "fallback-\(UUID().uuidString)", name: toolName, inputJSON: jsonString(normalizedInput))
        }
        return nil
    }

    private static func toolCalls(fromJSONObject object: [String: Any]) -> [AgentToolCall] {
        if let rawCalls = object["tool_calls"] as? [[String: Any]] {
            return rawCalls.compactMap(toolCall(fromJSONObject:))
        }
        if let rawCalls = object["tools"] as? [[String: Any]] {
            return rawCalls.compactMap(toolCall(fromJSONObject:))
        }
        if let call = toolCall(fromJSONObject: object) {
            return [call]
        }
        return []
    }

    private static func toolCall(fromJSONObject object: [String: Any]) -> AgentToolCall? {
        let rawName = object["tool"] as? String
            ?? object["name"] as? String
            ?? (object["function"] as? [String: Any])?["name"] as? String
        guard let rawName, !rawName.isEmpty else { return nil }
        let name = canonicalFallbackToolName(rawName)
        let rawInput = object["input"]
            ?? object["arguments"]
            ?? (object["function"] as? [String: Any])?["arguments"]
            ?? [:]
        if name == "Bash", let command = commandString(from: rawInput),
           command.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("ls") {
            return AgentToolCall(
                id: object["id"] as? String ?? "fallback-\(UUID().uuidString)",
                name: "Glob",
                inputJSON: jsonString(["pattern": "*", "path": "."])
            )
        }
        let inputJSON: String
        if let input = rawInput as? String {
            let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
            inputJSON = trimmedInput.hasPrefix("{")
                ? trimmedInput
                : jsonString(["input": input])
        } else {
            inputJSON = jsonString(rawInput)
        }
        return AgentToolCall(
            id: object["id"] as? String ?? "fallback-\(UUID().uuidString)",
            name: name,
            inputJSON: inputJSON
        )
    }

    private static func canonicalFallbackToolName(_ rawName: String) -> String {
        switch rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "bash", "executebash", "runcommand":
            return "Bash"
        case "read", "readfile":
            return "Read"
        case "write", "writefile":
            return "Write"
        case "edit", "editfile":
            return "Edit"
        case "multiedit", "multi_edit":
            return "MultiEdit"
        case "glob":
            return "Glob"
        case "grep":
            return "Grep"
        default:
            return rawName
        }
    }

    private static func commandString(from rawInput: Any) -> String? {
        if let command = rawInput as? String {
            return command
        }
        if let object = rawInput as? [String: Any] {
            return object["command"] as? String
                ?? object["input_command"] as? String
                ?? object["input"] as? String
        }
        return nil
    }
}

private struct ModelTurn {
    var assistantContent: String
    var toolCalls: [AgentToolCall]
}

private struct OpenAIToolCallAccumulator {
    var index: Int
    var id = ""
    var name = ""
    var arguments = ""

    mutating func apply(delta: [String: Any]) {
        if let id = delta["id"] as? String {
            self.id = id
        }
        if let function = delta["function"] as? [String: Any] {
            if let name = function["name"] as? String {
                self.name += name
            }
            if let arguments = function["arguments"] as? String {
                self.arguments += arguments
            }
        }
    }

    var toolCall: AgentToolCall? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return AgentToolCall(
            id: id.isEmpty ? "call-\(UUID().uuidString)" : id,
            name: name,
            inputJSON: arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}" : arguments
        )
    }
}

enum AgentToolRegistry {
    static let toolNames = [
        "Read",
        "Write",
        "Edit",
        "MultiEdit",
        "Glob",
        "Grep",
        "Bash",
        "TodoRead",
        "TodoWrite",
        "ExitPlanMode",
        "AskUserQuestion",
    ]

    static func openAITools() -> [[String: Any]] {
        [
            functionTool(
                "Read",
                "Read a UTF-8 text file from the workspace.",
                [
                    "file_path": stringProperty("Workspace-relative or absolute file path."),
                    "offset": integerProperty("Optional 1-based line offset."),
                    "limit": integerProperty("Optional maximum number of lines to return."),
                ],
                required: ["file_path"]
            ),
            functionTool(
                "Write",
                "Create or overwrite a UTF-8 file in the workspace.",
                [
                    "file_path": stringProperty("Workspace-relative or absolute file path."),
                    "content": stringProperty("Complete file contents to write."),
                ],
                required: ["file_path", "content"]
            ),
            functionTool(
                "Edit",
                "Replace an exact string in a workspace file.",
                [
                    "file_path": stringProperty("Workspace-relative or absolute file path."),
                    "old_string": stringProperty("Exact text to replace."),
                    "new_string": stringProperty("Replacement text."),
                    "replace_all": boolProperty("Replace every match instead of requiring one unique match."),
                ],
                required: ["file_path", "old_string", "new_string"]
            ),
            functionTool(
                "MultiEdit",
                "Apply multiple exact string replacements to one workspace file.",
                [
                    "file_path": stringProperty("Workspace-relative or absolute file path."),
                    "edits": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "old_string": stringProperty("Exact text to replace."),
                                "new_string": stringProperty("Replacement text."),
                                "replace_all": boolProperty("Replace every match."),
                            ],
                            "required": ["old_string", "new_string"],
                        ],
                    ],
                ],
                required: ["file_path", "edits"]
            ),
            functionTool(
                "Glob",
                "Find files by glob pattern under the workspace.",
                [
                    "pattern": stringProperty("Glob such as **/*.swift or *.md."),
                    "path": stringProperty("Optional directory to search."),
                ],
                required: ["pattern"]
            ),
            functionTool(
                "Grep",
                "Search text files by regular expression under the workspace.",
                [
                    "pattern": stringProperty("Regular expression to search for."),
                    "path": stringProperty("Optional directory or file to search."),
                    "include": stringProperty("Optional glob filter such as *.swift."),
                ],
                required: ["pattern"]
            ),
            functionTool(
                "Bash",
                "Run a shell command in the workspace.",
                [
                    "command": stringProperty("Command to run with /bin/zsh -lc."),
                    "description": stringProperty("Short reason for running the command."),
                    "timeout_seconds": integerProperty("Optional timeout in seconds."),
                ],
                required: ["command"]
            ),
            functionTool("TodoRead", "Read the current session todo list.", [:], required: []),
            functionTool(
                "TodoWrite",
                "Replace the current session todo list.",
                [
                    "todos": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "additionalProperties": true,
                        ],
                    ],
                ],
                required: ["todos"]
            ),
            functionTool(
                "ExitPlanMode",
                "Exit plan mode after presenting a concrete plan.",
                [
                    "plan": stringProperty("The plan to execute."),
                ],
                required: ["plan"]
            ),
            functionTool(
                "AskUserQuestion",
                "Ask the user one or more short blocking questions. Prefer the questions array shape.",
                [
                    "questions": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "header": stringProperty("Short section label."),
                                "question": stringProperty("Question to ask."),
                                "options": [
                                    "type": "array",
                                    "items": [
                                        "type": "object",
                                        "properties": [
                                            "label": stringProperty("Option label."),
                                            "description": stringProperty("Optional short description."),
                                        ],
                                        "required": ["label"],
                                    ],
                                ],
                                "multiSelect": boolProperty("Whether multiple options may be selected."),
                            ],
                            "required": ["question"],
                        ],
                    ],
                    "question": stringProperty("Legacy single question fallback."),
                    "options": [
                        "type": "array",
                        "items": stringProperty("Legacy option label."),
                    ],
                ],
                required: []
            ),
        ]
    }

    private static func functionTool(
        _ name: String,
        _ description: String,
        _ properties: [String: Any],
        required: [String]
    ) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": [
                    "type": "object",
                    "properties": properties,
                    "required": required,
                    "additionalProperties": false,
                ],
            ],
        ]
    }

    private static func stringProperty(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private static func integerProperty(_ description: String) -> [String: Any] {
        ["type": "integer", "description": description]
    }

    private static func boolProperty(_ description: String) -> [String: Any] {
        ["type": "boolean", "description": description]
    }
}

enum AgentPermissionPolicy {
    enum Result: Equatable {
        case allow
        case ask(String)
        case deny(String)
    }

    static let planModeSafeTools = Set([
        "Read",
        "Glob",
        "Grep",
        "TodoRead",
        "TodoWrite",
        "AskUserQuestion",
        "ExitPlanMode",
        "ExitPlanModeV2",
        "exit_plan_mode",
    ])

    static let mutatingTools = Set(["Write", "Edit", "MultiEdit", "Bash"])
    static let interactiveTools = Set(["AskUserQuestion", "ExitPlanMode", "ExitPlanModeV2", "exit_plan_mode"])

    static func policy(for call: AgentToolCall, context: AgentRunContext) -> Result {
        let toolName = normalizedToolName(call.name)
        if context.runMode == .plan, !context.planExited, !planModeSafeTools.contains(toolName) {
            return .deny("\(toolName) is not allowed in plan mode. Call ExitPlanMode with a plan before mutating the workspace.")
        }
        if matchesAny(ruleSet: context.toolSettings.disallowedTools, call: call) {
            return .deny("\(toolName) is blocked by permissions settings.")
        }
        if interactiveTools.contains(toolName) {
            return .ask("9GClaw wants to run \(toolName).")
        }
        if context.permissionMode == .bypassPermissions {
            return .allow
        }
        if matchesAny(ruleSet: context.toolSettings.allowedTools, call: call) {
            return .allow
        }
        if mutatingTools.contains(toolName) || interactiveTools.contains(toolName) {
            return .ask("9GClaw wants to run \(toolName).")
        }
        return .allow
    }

    private static func normalizedToolName(_ value: String) -> String {
        switch value {
        case "exit_plan_mode", "ExitPlanModeV2":
            return "ExitPlanMode"
        default:
            return value
        }
    }

    private static func matchesAny(ruleSet: [String], call: AgentToolCall) -> Bool {
        ruleSet.contains { rule in matches(rule: rule, call: call) }
    }

    private static func matches(rule: String, call: AgentToolCall) -> Bool {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed == call.name { return true }
        guard call.name == "Bash", trimmed.hasPrefix("Bash("), trimmed.hasSuffix(")") else {
            return false
        }
        let inner = String(trimmed.dropFirst(5).dropLast())
        let input = (try? AgentToolExecutor.inputObject(from: call.inputJSON)) ?? [:]
        let command = input["command"] as? String ?? ""
        if inner == "*" { return true }
        if inner.hasSuffix("*") {
            return command.hasPrefix(String(inner.dropLast()))
        }
        return command == inner
    }
}

enum AgentToolExecutor {
    static func execute(call: AgentToolCall, context: AgentRunContext) async -> AgentToolResult {
        do {
            let output: String
            switch call.name {
            case "Read":
                output = try read(inputJSON: call.inputJSON, workspacePath: context.workspacePath)
            case "Write":
                output = try write(inputJSON: call.inputJSON, workspacePath: context.workspacePath)
            case "Edit":
                output = try edit(inputJSON: call.inputJSON, workspacePath: context.workspacePath)
            case "MultiEdit":
                output = try multiEdit(inputJSON: call.inputJSON, workspacePath: context.workspacePath)
            case "Glob":
                output = try glob(inputJSON: call.inputJSON, workspacePath: context.workspacePath)
            case "Grep":
                output = try grep(inputJSON: call.inputJSON, workspacePath: context.workspacePath)
            case "Bash":
                output = try await bash(inputJSON: call.inputJSON, workspacePath: context.workspacePath)
            case "TodoRead":
                output = context.todosJSON
            case "TodoWrite":
                output = try todoWrite(inputJSON: call.inputJSON, context: context)
            case "ExitPlanMode", "ExitPlanModeV2", "exit_plan_mode":
                context.planExited = true
                let input = try inputObject(from: call.inputJSON)
                output = (input["plan"] as? String).nilIfBlank ?? "Plan mode exited."
            case "AskUserQuestion":
                output = askUserQuestionOutput(inputJSON: call.inputJSON)
            default:
                throw ProviderClientError.toolExecution("Unsupported tool: \(call.name)")
            }
            return AgentToolResult(callId: call.id, toolName: call.name, output: limitOutput(output), isError: false)
        } catch {
            return AgentToolResult(callId: call.id, toolName: call.name, output: error.localizedDescription, isError: true)
        }
    }

    static func askUserQuestionResult(call: AgentToolCall, updatedInputJSON: String) -> AgentToolResult {
        AgentToolResult(
            callId: call.id,
            toolName: call.name,
            output: limitOutput(askUserQuestionOutput(inputJSON: updatedInputJSON)),
            isError: false
        )
    }

    static func askUserQuestionOutput(inputJSON: String) -> String {
        guard let data = inputJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = object["answers"] as? [String: Any] else {
            return #"{"answers":{}}"#
        }
        let normalized = answers.reduce(into: [String: String]()) { result, pair in
            if let value = pair.value as? String {
                result[pair.key] = value
            } else if let values = pair.value as? [String] {
                result[pair.key] = values.joined(separator: ", ")
            } else {
                result[pair.key] = String(describing: pair.value)
            }
        }
        return jsonString(["answers": normalized], pretty: true)
    }

    static func inputObject(from json: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderClientError.toolExecution("Tool input must be a JSON object.")
        }
        return object
    }

    static func applyEdit(content: String, oldString: String, newString: String, replaceAll: Bool) throws -> String {
        guard !oldString.isEmpty else {
            throw ProviderClientError.toolExecution("old_string must not be empty.")
        }
        let count = content.components(separatedBy: oldString).count - 1
        guard count > 0 else {
            throw ProviderClientError.toolExecution("old_string was not found.")
        }
        if !replaceAll, count != 1 {
            throw ProviderClientError.toolExecution("old_string matched \(count) times. Provide a unique string or set replace_all.")
        }
        if replaceAll {
            return content.replacingOccurrences(of: oldString, with: newString)
        }
        guard let range = content.range(of: oldString) else {
            throw ProviderClientError.toolExecution("old_string was not found.")
        }
        var updated = content
        updated.replaceSubrange(range, with: newString)
        return updated
    }

    private static func read(inputJSON: String, workspacePath: String) throws -> String {
        let input = try inputObject(from: inputJSON)
        let file = try requiredString("file_path", input: input)
        let url = try AgentPathResolver.resolve(file, workspacePath: workspacePath, mustExist: true)
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.components(separatedBy: .newlines)
        let offset = max((input["offset"] as? Int ?? 1) - 1, 0)
        let limit = input["limit"] as? Int ?? min(lines.count, 2_000)
        let selected = lines.dropFirst(offset).prefix(max(limit, 1))
        return selected.enumerated().map { index, line in
            "\(offset + index + 1): \(line)"
        }.joined(separator: "\n")
    }

    private static func write(inputJSON: String, workspacePath: String) throws -> String {
        let input = try inputObject(from: inputJSON)
        let file = try requiredString("file_path", input: input)
        let content = try requiredString("content", input: input)
        let url = try AgentPathResolver.resolve(file, workspacePath: workspacePath, mustExist: false)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return "Wrote \(content.utf8.count) bytes to \(AgentPathResolver.relativePath(url, workspacePath: workspacePath))."
    }

    private static func edit(inputJSON: String, workspacePath: String) throws -> String {
        let input = try inputObject(from: inputJSON)
        let file = try requiredString("file_path", input: input)
        let oldString = try requiredString("old_string", input: input)
        let newString = try requiredString("new_string", input: input)
        let replaceAll = input["replace_all"] as? Bool ?? false
        let url = try AgentPathResolver.resolve(file, workspacePath: workspacePath, mustExist: true)
        let content = try String(contentsOf: url, encoding: .utf8)
        let updated = try applyEdit(content: content, oldString: oldString, newString: newString, replaceAll: replaceAll)
        try updated.write(to: url, atomically: true, encoding: .utf8)
        return "Edited \(AgentPathResolver.relativePath(url, workspacePath: workspacePath))."
    }

    private static func multiEdit(inputJSON: String, workspacePath: String) throws -> String {
        let input = try inputObject(from: inputJSON)
        let file = try requiredString("file_path", input: input)
        guard let edits = input["edits"] as? [[String: Any]], !edits.isEmpty else {
            throw ProviderClientError.toolExecution("MultiEdit requires a non-empty edits array.")
        }
        let url = try AgentPathResolver.resolve(file, workspacePath: workspacePath, mustExist: true)
        var content = try String(contentsOf: url, encoding: .utf8)
        for edit in edits {
            let oldString = try requiredString("old_string", input: edit)
            let newString = try requiredString("new_string", input: edit)
            let replaceAll = edit["replace_all"] as? Bool ?? false
            content = try applyEdit(content: content, oldString: oldString, newString: newString, replaceAll: replaceAll)
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
        return "Applied \(edits.count) edits to \(AgentPathResolver.relativePath(url, workspacePath: workspacePath))."
    }

    private static func glob(inputJSON: String, workspacePath: String) throws -> String {
        let input = try inputObject(from: inputJSON)
        let pattern = try requiredString("pattern", input: input)
        let searchPath = (input["path"] as? String).nilIfBlank ?? "."
        let root = try AgentPathResolver.resolve(searchPath, workspacePath: workspacePath, mustExist: true)
        let regex = try AgentPathResolver.globRegex(pattern)
        var matches: [String] = []
        for url in AgentPathResolver.walk(root) {
            let relative = AgentPathResolver.relativePath(url, workspacePath: root.path)
            if regex.firstMatch(in: relative, range: NSRange(location: 0, length: (relative as NSString).length)) != nil {
                matches.append(AgentPathResolver.relativePath(url, workspacePath: workspacePath))
            }
            if matches.count >= 500 { break }
        }
        return matches.isEmpty ? "No files matched \(pattern)." : matches.sorted().joined(separator: "\n")
    }

    private static func grep(inputJSON: String, workspacePath: String) throws -> String {
        let input = try inputObject(from: inputJSON)
        let pattern = try requiredString("pattern", input: input)
        let searchPath = (input["path"] as? String).nilIfBlank ?? "."
        let root = try AgentPathResolver.resolve(searchPath, workspacePath: workspacePath, mustExist: true)
        let include = (input["include"] as? String).nilIfBlank
        let includeRegex = try include.map { try AgentPathResolver.globRegex($0) }
        let regex = try NSRegularExpression(pattern: pattern)
        let urls: [URL]
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            urls = [root]
        } else {
            urls = AgentPathResolver.walk(root)
        }
        var output: [String] = []
        for url in urls {
            let relative = AgentPathResolver.relativePath(url, workspacePath: workspacePath)
            if let includeRegex,
               includeRegex.firstMatch(in: url.lastPathComponent, range: NSRange(location: 0, length: (url.lastPathComponent as NSString).length)) == nil {
                continue
            }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let lines = text.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                let nsLine = line as NSString
                if regex.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)) != nil {
                    output.append("\(relative):\(index + 1):\(line)")
                    if output.count >= 500 {
                        return output.joined(separator: "\n")
                    }
                }
            }
        }
        return output.isEmpty ? "No matches for \(pattern)." : output.joined(separator: "\n")
    }

    private static func bash(inputJSON: String, workspacePath: String) async throws -> String {
        let input = try inputObject(from: inputJSON)
        let command = try requiredString("command", input: input)
        let timeout = max(1, min(input["timeout_seconds"] as? Int ?? 120, 600))
        return try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            process.currentDirectoryURL = URL(fileURLWithPath: workspacePath)
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
                if process.isRunning {
                    process.terminate()
                }
            }
            process.waitUntilExit()
            timeoutTask.cancel()
            let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let combined = [out, err].filter { !$0.isEmpty }.joined(separator: "\n")
            let prefix = "exit code: \(process.terminationStatus)"
            return combined.isEmpty ? prefix : "\(prefix)\n\(combined)"
        }.value
    }

    private static func todoWrite(inputJSON: String, context: AgentRunContext) throws -> String {
        let input = try inputObject(from: inputJSON)
        guard let todos = input["todos"] else {
            throw ProviderClientError.toolExecution("TodoWrite requires todos.")
        }
        context.todosJSON = jsonString(todos, pretty: true)
        return "Updated todo list."
    }

    private static func requiredString(_ key: String, input: [String: Any]) throws -> String {
        guard let value = input[key] as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderClientError.toolExecution("Missing required string: \(key)")
        }
        return value
    }

    private static func limitOutput(_ output: String) -> String {
        if output.count <= 20_000 { return output }
        return String(output.prefix(20_000)) + "\n... output truncated ..."
    }
}

enum AgentPathResolver {
    static let skippedDirectoryNames = Set([".git", "node_modules", "dist", "build", ".DS_Store"])

    static func resolve(_ rawPath: String, workspacePath: String, mustExist: Bool) throws -> URL {
        let root = URL(fileURLWithPath: NSString(string: workspacePath).expandingTildeInPath).standardizedFileURL
        let expanded = NSString(string: rawPath.trimmingCharacters(in: .whitespacesAndNewlines)).expandingTildeInPath
        let candidate: URL
        if expanded.hasPrefix("/") {
            candidate = URL(fileURLWithPath: expanded).standardizedFileURL
        } else {
            candidate = root.appendingPathComponent(expanded).standardizedFileURL
        }
        let rootPath = root.path
        let path = candidate.path
        guard path == rootPath || path.hasPrefix(rootPath + "/") else {
            throw ProviderClientError.toolExecution("Path escapes workspace: \(rawPath)")
        }
        if mustExist, !FileManager.default.fileExists(atPath: path) {
            throw ProviderClientError.toolExecution("Path does not exist: \(rawPath)")
        }
        for forbidden in WorkspaceService.forbiddenPaths where path == forbidden || path.hasPrefix(forbidden + "/") {
            throw ProviderClientError.toolExecution("Refusing to access system path: \(forbidden)")
        }
        return candidate
    }

    static func relativePath(_ url: URL, workspacePath: String) -> String {
        let root = URL(fileURLWithPath: workspacePath).standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == root ? "." : path.replacingOccurrences(of: root + "/", with: "")
    }

    static func walk(_ root: URL) -> [URL] {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var urls: [URL] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if skippedDirectoryNames.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true { continue }
            urls.append(url)
        }
        return urls
    }

    static func globRegex(_ pattern: String) throws -> NSRegularExpression {
        var regex = "^"
        let chars = Array(pattern)
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "*" {
                if index + 1 < chars.count, chars[index + 1] == "*" {
                    if index + 2 < chars.count, chars[index + 2] == "/" {
                        regex += "(?:.*/)?"
                        index += 3
                    } else {
                        regex += ".*"
                        index += 2
                    }
                } else {
                    regex += "[^/]*"
                    index += 1
                }
            } else if char == "?" {
                regex += "[^/]"
                index += 1
            } else {
                regex += NSRegularExpression.escapedPattern(for: String(char))
                index += 1
            }
        }
        regex += "$"
        return try NSRegularExpression(pattern: regex)
    }
}

private func jsonString(_ value: Any, pretty: Bool = false) -> String {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
          ),
          let string = String(data: data, encoding: .utf8) else {
        return "{}"
    }
    return string
}

private extension Optional where Wrapped == String {
    var nilIfBlank: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

typealias ProviderClient = NativeAgentRuntime
