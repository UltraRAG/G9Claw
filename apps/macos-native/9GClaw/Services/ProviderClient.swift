import Foundation

struct AgentPermissionRequest: Sendable, Equatable {
    var id: UUID
    var sessionId: String
    var toolName: String
    var inputJSON: String
    var reason: String
    var scope: PermissionScope
}

enum AgentPermissionDecision: Sendable, Equatable {
    case allow(remember: Bool)
    case deny
}

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

    init(request: AgentRequest) {
        sessionId = request.sessionId
        workspacePath = request.projectPath
        runMode = request.runMode
        permissionMode = request.permissionMode
        toolSettings = request.toolSettings
        planExited = request.runMode == .agent
        todosJSON = "[]"
    }
}

enum AgentLoopState: Sendable, Equatable {
    case thinking
    case runningTool(String)
    case waitingForPermission(String)
    case complete
    case error(String)
}

enum AgentEvent: Sendable, Equatable {
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

enum ProviderClientError: Error, LocalizedError {
    case missingBaseURL
    case missingModel
    case missingAPIKey
    case invalidURL(String)
    case httpError(statusCode: Int, body: String)
    case unsupportedProvider(SessionProvider)
    case invalidResponse
    case transport(String)
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
        case .toolExecution(let message): message
        }
    }
}

struct NativeAgentRuntime: Sendable {
    private static let maxAgentIterations = 24

    func stream(request: AgentRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    continuation.yield(.sessionCreated(sessionId: request.sessionId))
                    continuation.yield(.status("connecting"))

                    switch request.providerConfig.provider {
                    case .nineGClaw:
                        try await Self.streamNineGClawAgent(request: request, continuation: continuation)
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

    private static func streamNineGClawAgent(
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
        guard config.apiType == .openAIChat else {
            throw ProviderClientError.unsupportedProvider(config.provider)
        }

        let context = AgentRunContext(request: request)
        var messages = openAIInitialMessages(request: request)

        for iteration in 1...maxAgentIterations {
            if Task.isCancelled { throw CancellationError() }
            continuation.yield(.status(iteration == 1 ? "thinking" : "processing"))
            let turn = try await performOpenAIChatTurn(
                request: request,
                messages: messages,
                continuation: continuation
            )

            var toolCalls = turn.toolCalls
            if toolCalls.isEmpty {
                toolCalls = fallbackToolCalls(in: turn.assistantContent)
            }

            guard !toolCalls.isEmpty else { return }
            messages.append(openAIAssistantToolMessage(content: turn.assistantContent, toolCalls: toolCalls))

            for call in toolCalls {
                if Task.isCancelled { throw CancellationError() }
                continuation.yield(.status("running \(call.name)"))
                continuation.yield(.toolUse(id: call.id, name: call.name, inputJSON: call.inputJSON))
                let result = await executeToolWithPolicy(
                    call: call,
                    context: context,
                    request: request,
                    continuation: continuation
                )
                continuation.yield(.toolResult(id: call.id, output: result.output, isError: result.isError))
                messages.append(openAIToolResultMessage(result))
            }
        }

        throw ProviderClientError.transport("Agent loop reached the maximum iteration limit.")
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
            "tools": AgentToolRegistry.openAITools(),
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
        var accumulators: [Int: OpenAIToolCallAccumulator] = [:]
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
            for event in openAIChatEvents(from: object, contextWindow: request.contextWindow) {
                if case .contentDelta(let delta) = event {
                    content += delta
                }
                continuation.yield(event)
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
        var calls: [AgentToolCall] = []
        calls.append(contentsOf: jsonFallbackToolCalls(in: text))
        calls.append(contentsOf: xmlFallbackToolCalls(in: text))
        return calls
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
        messages.append(["role": "user", "content": request.prompt])
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
        If OpenAI tool calling is unavailable, emit exactly one fallback tool request in a JSON code fence:
        ```json
        {"tool":"Read","input":{"file_path":"README.md"}}
        ```
        """
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
                        "arguments": call.inputJSON,
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
        let policy = AgentPermissionPolicy.policy(for: call, context: context)
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
                scope: .session
            )
            continuation.yield(.permissionRequest(permission))
            continuation.yield(.status("waiting for permission"))
            let decision = await request.permissionHandler?(permission) ?? .deny
            switch decision {
            case .allow:
                break
            case .deny:
                return AgentToolResult(
                    callId: call.id,
                    toolName: call.name,
                    output: "Permission denied for \(call.name).",
                    isError: true
                )
            }
        }

        return await AgentToolExecutor.execute(call: call, context: context)
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

    private static func jsonFallbackToolCalls(in text: String) -> [AgentToolCall] {
        var snippets: [String] = []
        let pattern = #"(?s)```(?:json)?\s*(\{.*?\})\s*```"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let nsText = text as NSString
            for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
                guard match.numberOfRanges > 1 else { continue }
                snippets.append(nsText.substring(with: match.range(at: 1)))
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
            snippets.append(trimmed)
        }

        return snippets.flatMap { snippet -> [AgentToolCall] in
            guard let data = snippet.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            return toolCalls(fromJSONObject: object)
        }
    }

    private static func xmlFallbackToolCalls(in text: String) -> [AgentToolCall] {
        let pattern = #"(?s)<tool_call\s+name=["']([^"']+)["']\s*>(.*?)</tool_call>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsText = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).compactMap { match in
            guard match.numberOfRanges > 2 else { return nil }
            let name = nsText.substring(with: match.range(at: 1))
            let body = nsText.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            let inputJSON: String
            if body.hasPrefix("{") {
                inputJSON = body
            } else {
                inputJSON = jsonString(["input": body])
            }
            return AgentToolCall(id: "fallback-\(UUID().uuidString)", name: name, inputJSON: inputJSON)
        }
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
        let name = object["tool"] as? String
            ?? object["name"] as? String
            ?? (object["function"] as? [String: Any])?["name"] as? String
        guard let name, !name.isEmpty else { return nil }
        let rawInput = object["input"]
            ?? object["arguments"]
            ?? (object["function"] as? [String: Any])?["arguments"]
            ?? [:]
        let inputJSON: String
        if let input = rawInput as? String {
            inputJSON = input.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
                ? input
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
                "Ask the user a short blocking question.",
                [
                    "question": stringProperty("Question to ask."),
                    "options": [
                        "type": "array",
                        "items": stringProperty("Option"),
                    ],
                ],
                required: ["question"]
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
        if context.permissionMode == .bypassPermissions {
            return .allow
        }
        if matchesAny(ruleSet: context.toolSettings.disallowedTools, call: call) {
            return .deny("\(toolName) is blocked by permissions settings.")
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
                let input = try inputObject(from: call.inputJSON)
                output = "Question acknowledged: \((input["question"] as? String).nilIfBlank ?? "No question provided.")"
            default:
                throw ProviderClientError.toolExecution("Unsupported tool: \(call.name)")
            }
            return AgentToolResult(callId: call.id, toolName: call.name, output: limitOutput(output), isError: false)
        } catch {
            return AgentToolResult(callId: call.id, toolName: call.name, output: error.localizedDescription, isError: true)
        }
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
