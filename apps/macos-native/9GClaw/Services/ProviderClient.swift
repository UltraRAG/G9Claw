import Foundation
import PDFKit

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
    var nativeConfigValues: [String: String] = [:]
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

enum AgentToolNameCanonicalizer {
    static func canonical(_ rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("9gclaw-rag:") {
            return trimmed
        }
        switch lower {
        case "read": return "Read"
        case "write": return "Write"
        case "strreplace", "str_replace", "str-replace", "edit", "multiedit", "multi_edit", "multi-edit":
            return "StrReplace"
        case "delete", "remove", "unlink": return "Delete"
        case "editnotebook", "edit_notebook", "edit-notebook", "notebookedit", "notebook_edit", "notebook-edit":
            return "EditNotebook"
        case "glob": return "Glob"
        case "grep": return "Grep"
        case "semanticsearch", "semantic_search", "semantic-search": return "SemanticSearch"
        case "bash", "shell", "run_command", "runcommand": return "Shell"
        case "await", "taskoutput", "task_output", "task-output", "agentoutputtool", "bashoutputtool":
            return "Await"
        case "websearch", "web_search", "web-search": return "WebSearch"
        case "webfetch", "web_fetch", "web-fetch": return "WebFetch"
        case "readlints", "read_lints", "read-lints", "lints", "lint": return "ReadLints"
        case "skill", "loadskill", "load_skill": return "Skill"
        case "task", "taskcreate", "task_create", "task-create", "agent", "subagent", "sub_agent", "sub-agent":
            return "Task"
        case "todoread", "todo_read", "todo-read": return "TodoRead"
        case "todowrite", "todo_write", "todo-write": return "TodoWrite"
        case "switchmode", "switch_mode", "switch-mode", "exitplanmode", "exit_plan_mode", "exit-plan-mode", "exitplanmodev2":
            return "SwitchMode"
        case "askquestion", "ask_question", "ask-question", "askuserquestion", "ask_user_question", "ask-user-question":
            return "AskQuestion"
        default: return trimmed
        }
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
        let canonicalName = AgentToolNameCanonicalizer.canonical(call.name)
        switch canonicalObjectJSONString(call.inputJSON) {
        case .success(let canonical):
            let canonicalInput = canonicalToolInputJSON(toolName: canonicalName, inputJSON: canonical)
            return NormalizedInvocation(
                call: AgentToolCall(id: call.id, name: canonicalName, inputJSON: canonicalInput),
                recoveryResult: nil
            )
        case .failure(let error):
            let safeCall = AgentToolCall(id: call.id, name: canonicalName, inputJSON: "{}")
            let output = "\(invalidJSONRecoveryMessage)\n\nTool: \(canonicalName)\nError: \(error.message)"
            return NormalizedInvocation(
                call: safeCall,
                recoveryResult: AgentToolResult(
                    callId: call.id,
                    toolName: canonicalName,
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

    private static func canonicalToolInputJSON(toolName: String, inputJSON: String) -> String {
        guard let data = inputJSON.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return inputJSON
        }
        switch toolName {
        case "Shell":
            canonicalizeShellInput(&object)
        case "Skill":
            canonicalizeSkillInput(&object)
        case "Task":
            canonicalizeTaskInput(&object)
        case "StrReplace":
            canonicalizeStrReplaceInput(&object)
        case "Await":
            canonicalizeAwaitInput(&object)
        default:
            return inputJSON
        }
        guard JSONSerialization.isValidJSONObject(object),
              let canonicalData = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let canonical = String(data: canonicalData, encoding: .utf8) else {
            return inputJSON
        }
        return canonical
    }

    private static func canonicalizeShellInput(_ object: inout [String: Any]) {
        if let command = (object["command"] as? String).nilIfBlank {
            object["command"] = sanitizeXMLParameterWrapper(command)
        } else {
            let command = (object["input"] as? String).nilIfBlank
                ?? (object["input_command"] as? String).nilIfBlank
                ?? (object["cmd"] as? String).nilIfBlank
            if let command {
                object["command"] = sanitizeXMLParameterWrapper(command)
            }
        }
        object.removeValue(forKey: "input")
        object.removeValue(forKey: "input_command")
        object.removeValue(forKey: "cmd")
        if object["timeout"] == nil, let timeoutSeconds = object["timeout_seconds"] {
            object["timeout"] = timeoutSeconds
        }
        object.removeValue(forKey: "timeout_seconds")
    }

    private static func canonicalizeSkillInput(_ object: inout [String: Any]) {
        if let skill = (object["skill"] as? String).nilIfBlank {
            object["skill"] = sanitizeXMLParameterWrapper(skill)
        }
        if let args = (object["args"] as? String).nilIfBlank {
            object["args"] = sanitizeXMLParameterWrapper(args)
        }
    }

    private static func canonicalizeTaskInput(_ object: inout [String: Any]) {
        if object["prompt"] == nil {
            object["prompt"] = (object["description"] as? String)
                ?? (object["subject"] as? String)
                ?? (object["command"] as? String)
                ?? (object["input"] as? String)
                ?? ""
        }
        if object["type"] == nil, object["subagent_type"] != nil {
            object["type"] = object["subagent_type"]
        }
        object.removeValue(forKey: "subagent_type")
        object.removeValue(forKey: "input")
    }

    private static func canonicalizeStrReplaceInput(_ object: inout [String: Any]) {
        if object["old_string"] == nil, let value = object["oldString"] {
            object["old_string"] = value
        }
        if object["new_string"] == nil, let value = object["newString"] {
            object["new_string"] = value
        }
        object.removeValue(forKey: "oldString")
        object.removeValue(forKey: "newString")
    }

    private static func canonicalizeAwaitInput(_ object: inout [String: Any]) {
        if object["task_id"] == nil {
            object["task_id"] = object["id"] ?? object["taskId"]
        }
        object.removeValue(forKey: "id")
        object.removeValue(forKey: "taskId")
    }

    private static func sanitizeXMLParameterWrapper(_ value: String) -> String {
        var cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let regex = try? NSRegularExpression(pattern: #"(?is)^<parameter(?:\s+[^>]*)?>\s*"#),
           let match = regex.firstMatch(in: cleaned, range: NSRange(location: 0, length: (cleaned as NSString).length)),
           match.range.location == 0 {
            cleaned = (cleaned as NSString).substring(from: match.range.length)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if cleaned.range(of: #"(?is)</parameter>\s*$"#, options: .regularExpression) != nil {
            cleaned = cleaned.replacingOccurrences(
                of: #"(?is)</parameter>\s*$"#,
                with: "",
                options: .regularExpression
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
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
    var verificationAfterMutationCount: Int
    var failedToolCount: Int
    var recoverableProtocolErrorCount: Int
    var providerConfig: ProviderConfig
    var apiKey: String
    var timeoutMs: Int
    var contextWindow: Int
    var nativeConfigValues: [String: String]
    var invokedSkills: [String]
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
        verificationAfterMutationCount = 0
        failedToolCount = 0
        recoverableProtocolErrorCount = 0
        providerConfig = request.providerConfig
        apiKey = request.apiKey
        timeoutMs = request.timeoutMs
        contextWindow = request.contextWindow
        nativeConfigValues = request.nativeConfigValues
        invokedSkills = []
        lastExecutedToolName = nil
        lastToolResultWasError = false
        executedToolSignatures = []
    }

    func recordInvokedSkill(_ skill: String) {
        let trimmed = skill.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !invokedSkills.contains(trimmed) else { return }
        invokedSkills.append(trimmed)
    }

    var hasInvokedRAGSkill: Bool {
        invokedSkills.contains {
            $0.contains("9gclaw-rag:") ||
                $0.contains("glm-web-search") ||
                $0.contains("rag-research") ||
                $0.contains("local-knowledge")
        }
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
        case "Read", "Glob", "Grep", "SemanticSearch", "WebSearch", "WebFetch", "ReadLints", "TodoRead", "Skill", "TodoWrite", "AskQuestion", "Await":
            exploratoryToolCount += 1
            if !result.isError, mutatingToolCount > 0 {
                verificationAfterMutationCount += 1
            }
        case "Write", "StrReplace", "Delete", "EditNotebook", "Shell", "Task":
            if result.isError {
                break
            } else if result.toolName == "Shell", Self.isReadOnlyShell(call.inputJSON) {
                exploratoryToolCount += 1
                if mutatingToolCount > 0 {
                    verificationAfterMutationCount += 1
                }
            } else if result.toolName == "Task", Self.isReadOnlyTask(call.inputJSON) {
                exploratoryToolCount += 1
                if mutatingToolCount > 0 {
                    verificationAfterMutationCount += 1
                }
            } else {
                mutatingToolCount += 1
            }
        default:
            break
        }
    }

    static func isReadOnlyShell(_ inputJSON: String) -> Bool {
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

    static func isReadOnlyTask(_ inputJSON: String) -> Bool {
        guard let data = inputJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        let type = ((object["type"] as? String) ?? "generalPurpose")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return ["explore", "cursor-guide", "ci-investigator"].contains(type)
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
    static let maxNudges = 5
    static let maxRecoverableProtocolErrors = 3
}

enum CompletionGate {
    static func canFinish(request: AgentRequest, context: AgentRunContext, assistantContent: String) -> Bool {
        if context.lastToolResultWasError {
            return false
        }
        guard NativeAgentRuntime.isWorkspaceMutationRequest(request.prompt) else {
            return true
        }
        if context.runMode == .plan, !context.planExited {
            return false
        }
        if context.mutatingToolCount == 0 {
            return false
        }
        if NativeAgentRuntime.requiresPostMutationVerification(request.prompt),
           context.verificationAfterMutationCount == 0 {
            return false
        }
        let content = assistantContent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if content.isEmpty || content == "bash" || content == "json" {
            return false
        }
        if NativeAgentRuntime.looksLikeOngoingWorkspaceWork(content) {
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
            rawToolCalls = rawToolCalls.map(canonicalToolCall)
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
                if result.toolName == "SwitchMode" {
                    await turnController.markPlanExited()
                    let executeItem = await turnController.recordStatus("executing plan")
                    continuation.yield(.turnItemStarted(executeItem))
                    continuation.yield(.status("executing plan"))
                }
                messages.append(openAIToolResultMessage(result))
                if !result.isError, result.toolName == "SwitchMode" {
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

    static func runSubagent(inputJSON: String, context: AgentRunContext) async throws -> String {
        let input = try AgentToolExecutor.inputObject(from: inputJSON)
        let prompt = try AgentToolExecutor.requiredString("prompt", input: input)
        let description = (input["description"] as? String).nilIfBlank ?? "Subagent"
        let extraContext = (input["context"] as? String).nilIfBlank ?? ""

        let endpoint = try endpointURL(baseURL: context.providerConfig.baseURL, suffix: "chat/completions")
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeoutInterval(from: context.timeoutMs)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let apiKey = context.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw ProviderClientError.missingAPIKey
        }
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        for (key, value) in context.providerConfig.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        let content = """
        Workspace: \(context.workspacePath)
        Description: \(description)

        \(extraContext)

        Subtask:
        \(prompt)
        """
        let body: [String: Any] = [
            "model": context.providerConfig.model,
            "messages": [
                [
                    "role": "system",
                    "content": "You are a focused read-only subagent. Answer the delegated subtask concisely. Do not claim to edit files, run shell commands, or call tools.",
                ],
                [
                    "role": "user",
                    "content": content,
                ],
            ],
            "stream": false,
        ]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch {
            throw mapTransportError(error)
        }
        guard let statusCode = (response as? HTTPURLResponse)?.statusCode else {
            throw ProviderClientError.invalidResponse
        }
        guard 200..<300 ~= statusCode else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ProviderClientError.httpError(statusCode: statusCode, body: body)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let answer = message["content"] as? String,
              !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderClientError.invalidResponse
        }
        return jsonString(
            [
                "description": description,
                "prompt": prompt,
                "result": answer.trimmingCharacters(in: .whitespacesAndNewlines),
            ],
            pretty: true
        )
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
        let invokeCalls = xmlInvokeFallbackToolCalls(in: trimmed)
        if !invokeCalls.isEmpty {
            return invokeCalls
        }
        let inlineJSONCalls = inlineJSONFallbackToolCalls(in: trimmed)
        if !inlineJSONCalls.isEmpty {
            return inlineJSONCalls
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
        if lower.hasPrefix("<call") || lower.hasPrefix("<response") || lower.hasPrefix("<invoke") || lower.hasPrefix("<command") || lower.hasPrefix("<bash") || lower.hasPrefix("<tool") {
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
            ? "You are in plan mode. Read/search/todo/question tools are allowed. Do not edit files or run mutating shell commands until SwitchMode is called with mode=\"agent\" and a concrete plan."
            : "You are in agent mode. Use tools to inspect and modify the workspace."
        return """
        You are 9GClaw, a native macOS coding agent with a Claude Code style workflow.
        Workspace root: \(request.projectPath)
        \(modeText)

        Use the provided tools for all file reads, file writes, edits, searches, todos, and shell commands.
        Never claim that you created, edited, deleted, or inspected a file unless the corresponding tool result confirms it.
        Prefer small, verifiable steps: inspect files, make precise edits, run focused checks, then summarize.
        Prefer the canonical tool names: Read, Write, StrReplace, Delete, EditNotebook, Grep, Glob, SemanticSearch, Shell, Await, WebSearch, WebFetch, ReadLints, TodoWrite, AskQuestion, SwitchMode, and Task.
        For shell commands, use Shell only when needed and keep commands scoped to the workspace. Use run_in_background plus Await for long-running commands.
        Use WebSearch for current public web results and WebFetch for a specific URL. Use Task for delegated analysis or shell-focused background work.
        If OpenAI tool calling is unavailable, emit exactly one raw JSON fallback tool request and no other prose in that assistant turn.
        Example: {"tool":"Read","input":{"file_path":"README.md"}}
        Do not emit markdown fences, language labels such as "bash" or "json", or a prose explanation when requesting a tool.
        """
    }

    static func shouldForceWorkspaceBootstrap(request: AgentRequest, context: AgentRunContext, assistantContent: String) -> Bool {
        let prompt = primaryUserPrompt(from: request.prompt).lowercased()
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
        let prompt = primaryUserPrompt(from: request.prompt).lowercased()
        guard isWorkspaceMutationRequest(prompt) else { return nil }
        let refusalPhrases = ["cannot", "can't", "unable", "无法", "不能", "没有权限", "不支持"]
        if refusalPhrases.contains(where: { content.contains($0) }) {
            return nil
        }
        if request.runMode == .plan, !context.planExited {
            return """
            Continue the planning turn. If the plan is concrete enough to execute, call SwitchMode with mode="agent" and the plan so the same turn can proceed to implementation. Do not stop after prose only.
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
        if context.mutatingToolCount > 0,
           requiresPostMutationVerification(prompt),
           context.verificationAfterMutationCount == 0 {
            return """
            Continue the workspace task. You have changed files, but have not verified or read back the result yet.
            Run a focused read/search/check command, then continue with any remaining edits before giving the final summary.
            """
        }
        if context.mutatingToolCount > 0, looksLikeOngoingWorkspaceWork(content) {
            return """
            Continue the implementation. You have started changing the workspace, but the last assistant message still describes in-progress work.
            Keep using concrete file/search/shell tools until the requested task is actually complete, then give a concise final summary.
            """
        }
        return nil
    }

    static func looksLikeOngoingWorkspaceWork(_ content: String) -> Bool {
        let value = content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return true }
        let completionMarkers = [
            "已完成", "完成了", "优化完成", "创建完成", "修复完成", "实现完成", "总结", "下面是最终", "以下是最终",
            "done", "completed", "complete.", "finished", "final summary", "here is the final", "all set",
        ]
        if completionMarkers.contains(where: { value.contains($0) }) {
            return false
        }
        let inProgressMarkers = [
            "let me", "i'll", "i will", "now let", "next", "continue", "start implementing", "apply", "verify", "check",
            "我将", "我会", "我来", "让我", "现在", "接下来", "下一步", "继续", "开始执行", "开始修改", "先", "然后",
        ]
        return inProgressMarkers.contains { value.contains($0) }
    }

    static func requiresPostMutationVerification(_ prompt: String) -> Bool {
        let prompt = primaryUserPrompt(from: prompt).lowercased()
        let verificationVerbs = [
            "优化", "修复", "完善", "调整", "重构", "检查", "验证", "继续",
            "optimize", "fix", "improve", "refactor", "verify", "check", "continue",
        ]
        return verificationVerbs.contains { prompt.contains($0) }
    }

    static func isWorkspaceMutationRequest(_ prompt: String) -> Bool {
        let prompt = primaryUserPrompt(from: prompt).lowercased()
        let mutationVerbs = [
            "创建", "新建", "生成", "做一个", "帮我做", "修改", "优化", "修复", "完善", "实现", "重写", "调整", "编辑", "保存",
            "create", "build", "generate", "make", "write", "edit", "modify", "fix", "optimize", "implement", "rewrite", "update", "improve", "save",
        ]
        return mutationVerbs.contains { prompt.contains($0) }
    }

    static func primaryUserPrompt(from prompt: String) -> String {
        let separators = [
            "\n\nRelevant 9GClaw memory context:",
            "\n\nAttached files:",
            "\n\n附件:",
        ]
        var primary = prompt
        for separator in separators {
            if let range = primary.range(of: separator) {
                primary = String(primary[..<range.lowerBound])
            }
        }
        return primary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func appendAssistantContentIfNeeded(_ content: String, to messages: inout [[String: Any]]) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isHiddenToolProtocol(trimmed) else { return }
        messages.append([
            "role": "assistant",
            "content": trimmed,
        ])
    }

    private static func canonicalToolCall(_ call: AgentToolCall) -> AgentToolCall {
        let canonicalName = AgentToolNameCanonicalizer.canonical(call.name)
        guard canonicalName.lowercased().hasPrefix("9gclaw-rag:") else {
            return AgentToolCall(id: call.id, name: canonicalName, inputJSON: call.inputJSON)
        }
        let args: String
        if let data = call.inputJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            args = (object["args"] as? String)
                ?? (object["query"] as? String)
                ?? (object["prompt"] as? String)
                ?? ""
        } else {
            args = ""
        }
        return AgentToolCall(
            id: call.id,
            name: "Skill",
            inputJSON: jsonString([
                "skill": canonicalName,
                "args": args,
            ])
        )
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
        switch AgentToolNameCanonicalizer.canonical(toolName) {
        case "AskQuestion":
            return .askUserQuestion
        case "SwitchMode":
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

    private static func inlineJSONFallbackToolCalls(in text: String) -> [AgentToolCall] {
        guard !text.contains("```") else { return [] }
        let snippets = balancedJSONObjectSnippets(in: text)
        guard !snippets.isEmpty else { return [] }
        var seen = Set<String>()
        return snippets.flatMap(jsonFallbackToolCalls).compactMap { call in
            let signature = "\(call.name):\(call.inputJSON)"
            guard !seen.contains(signature) else { return nil }
            seen.insert(signature)
            return call
        }
    }

    private static func balancedJSONObjectSnippets(in text: String) -> [String] {
        var snippets: [String] = []
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                switch character {
                case "\"":
                    inString = true
                case "{":
                    if depth == 0 {
                        start = index
                    }
                    depth += 1
                case "}":
                    if depth > 0 {
                        depth -= 1
                        if depth == 0, let snippetStart = start {
                            snippets.append(String(text[snippetStart...index]))
                            start = nil
                        }
                    }
                default:
                    break
                }
            }
            index = text.index(after: index)
        }
        return snippets
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

    private static func xmlInvokeFallbackToolCalls(in text: String) -> [AgentToolCall] {
        let invokePattern = #"(?is)<invoke\s+name=\"([^\"]+)\"\s*>(.*?)</invoke>"#
        guard let invokeRegex = try? NSRegularExpression(pattern: invokePattern) else { return [] }
        let nsText = text as NSString
        return invokeRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).compactMap { match in
            guard match.numberOfRanges > 2 else { return nil }
            let rawName = nsText.substring(with: match.range(at: 1))
            let body = nsText.substring(with: match.range(at: 2))
            var input: [String: Any] = [:]
            let parameterPattern = #"(?is)<parameter\s+name=\"([^\"]+)\"\s*>(.*?)</parameter>"#
            guard let parameterRegex = try? NSRegularExpression(pattern: parameterPattern) else { return nil }
            let nsBody = body as NSString
            for parameterMatch in parameterRegex.matches(in: body, range: NSRange(location: 0, length: nsBody.length)) {
                guard parameterMatch.numberOfRanges > 2 else { continue }
                let key = nsBody.substring(with: parameterMatch.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = xmlUnescaped(nsBody.substring(with: parameterMatch.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines))
                if !key.isEmpty {
                    input[key] = value
                }
            }
            guard !input.isEmpty else { return nil }
            return canonicalToolCall(
                AgentToolCall(id: "fallback-\(UUID().uuidString)", name: rawName, inputJSON: jsonString(input))
            )
        }
    }

    private static func xmlUnescaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func compactXMLToolCall(name rawName: String, inputJSON rawInput: String) -> AgentToolCall? {
        let input = (try? AgentToolExecutor.inputObject(from: rawInput)) ?? [:]
        let lowerName = rawName.lowercased()
        let toolName: String
        let normalizedInput: [String: Any]
        switch lowerName {
        case "executebash", "bash", "shell", "runcommand":
            let command = (input["command"] as? String)
                ?? (input["input_command"] as? String)
                ?? (input["input"] as? String)
                ?? ""
            if command.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("ls") {
                toolName = "Glob"
                normalizedInput = ["pattern": "*", "path": "."]
            } else {
                toolName = "Shell"
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
        case "editfile", "edit", "strreplace":
            toolName = "StrReplace"
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
                toolName = "Shell"
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
        if let skill = object["skill"] as? String, !skill.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return canonicalToolCall(
                AgentToolCall(
                    id: object["id"] as? String ?? "fallback-\(UUID().uuidString)",
                    name: "Skill",
                    inputJSON: jsonString(object)
                )
            )
        }
        let rawName = object["tool"] as? String
            ?? object["name"] as? String
            ?? (object["function"] as? [String: Any])?["name"] as? String
        guard let rawName, !rawName.isEmpty else { return nil }
        let name = canonicalFallbackToolName(rawName)
        let rawInput = object["input"]
            ?? object["arguments"]
            ?? (object["function"] as? [String: Any])?["arguments"]
            ?? [:]
        if name == "Shell", let command = commandString(from: rawInput),
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
        return canonicalToolCall(
            AgentToolCall(
                id: object["id"] as? String ?? "fallback-\(UUID().uuidString)",
                name: name,
                inputJSON: inputJSON
            )
        )
    }

    private static func canonicalFallbackToolName(_ rawName: String) -> String {
        AgentToolNameCanonicalizer.canonical(rawName)
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
        "StrReplace",
        "Delete",
        "EditNotebook",
        "Grep",
        "Glob",
        "SemanticSearch",
        "Shell",
        "Await",
        "WebSearch",
        "WebFetch",
        "ReadLints",
        "TodoWrite",
        "AskQuestion",
        "SwitchMode",
        "Task",
    ]

    static func openAITools() -> [[String: Any]] {
        [
            functionTool(
                "Read",
                "Read text, image, PDF, or Jupyter notebook content from the workspace.",
                [
                    "file_path": stringProperty("Workspace-relative or absolute file path."),
                    "offset": integerProperty("Optional 1-based line offset."),
                    "limit": integerProperty("Optional maximum number of lines to return."),
                    "pages": stringProperty("Optional PDF page range such as 1-3."),
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
                "StrReplace",
                "Replace exact strings in a workspace file. Supports one replacement or an edits array.",
                [
                    "file_path": stringProperty("Workspace-relative or absolute file path."),
                    "old_string": stringProperty("Exact text to replace."),
                    "new_string": stringProperty("Replacement text."),
                    "replace_all": boolProperty("Replace every match instead of requiring one unique match."),
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
                required: ["file_path"]
            ),
            functionTool(
                "Delete",
                "Delete a file or, with recursive=true, a directory inside the workspace.",
                [
                    "path": stringProperty("Workspace-relative or absolute file or directory path."),
                    "recursive": boolProperty("Allow deleting directories recursively."),
                ],
                required: ["path"]
            ),
            functionTool(
                "EditNotebook",
                "Replace, insert, or delete a cell in a Jupyter notebook file.",
                [
                    "notebook_path": stringProperty("Workspace-relative or absolute .ipynb path."),
                    "cell_id": stringProperty("Optional notebook cell id."),
                    "cell_number": integerProperty("Optional 0-based cell index."),
                    "new_source": stringProperty("New source for replace or insert."),
                    "cell_type": [
                        "type": "string",
                        "enum": ["code", "markdown"],
                        "description": "Cell type for inserted cells or replacement metadata.",
                    ],
                    "edit_mode": [
                        "type": "string",
                        "enum": ["replace", "insert", "delete"],
                        "description": "Notebook edit mode. Defaults to replace.",
                    ],
                ],
                required: ["notebook_path"]
            ),
            functionTool(
                "Grep",
                "Search text files by regular expression under the workspace, preferring ripgrep.",
                [
                    "pattern": stringProperty("Regular expression to search for."),
                    "path": stringProperty("Optional directory or file to search."),
                    "glob": stringProperty("Optional glob filter such as *.swift."),
                    "include": stringProperty("Legacy alias for glob."),
                    "output_mode": [
                        "type": "string",
                        "enum": ["content", "files_with_matches", "count"],
                        "description": "Result mode. Defaults to files_with_matches.",
                    ],
                    "-B": integerProperty("Context lines before each match."),
                    "-A": integerProperty("Context lines after each match."),
                    "-C": integerProperty("Context lines before and after each match."),
                    "context": integerProperty("Alias for -C."),
                    "-n": boolProperty("Show line numbers in content mode."),
                    "-i": boolProperty("Case-insensitive search."),
                    "type": stringProperty("Optional ripgrep file type."),
                    "head_limit": integerProperty("Maximum returned lines or entries."),
                    "offset": integerProperty("Number of results to skip before limiting."),
                    "multiline": boolProperty("Enable multiline matching."),
                ],
                required: ["pattern"]
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
                "SemanticSearch",
                "Search code by meaning using a deterministic local workspace index.",
                [
                    "query": stringProperty("Natural-language or code concept query."),
                    "path": stringProperty("Optional directory or file to search."),
                    "limit": integerProperty("Maximum number of ranked results."),
                ],
                required: ["query"]
            ),
            functionTool(
                "Shell",
                "Run a shell command in the workspace.",
                [
                    "command": stringProperty("Command to run with /bin/zsh -lc."),
                    "description": stringProperty("Short reason for running the command."),
                    "timeout": integerProperty("Optional timeout in milliseconds."),
                    "run_in_background": boolProperty("Start the command in the background and return a task id."),
                ],
                required: ["command"]
            ),
            functionTool(
                "Await",
                "Wait for or read output from a background Shell or Task.",
                [
                    "task_id": stringProperty("Background task id."),
                    "block": boolProperty("Whether to block until completion. Defaults to true."),
                    "timeout": integerProperty("Maximum wait time in milliseconds."),
                ],
                required: ["task_id"]
            ),
            functionTool(
                "WebSearch",
                "Search the web using the configured 9GClaw GLM/RAG search provider.",
                [
                    "query": stringProperty("Search query."),
                    "allowed_domains": [
                        "type": "array",
                        "items": stringProperty("Allowed result domain."),
                    ],
                    "blocked_domains": [
                        "type": "array",
                        "items": stringProperty("Blocked result domain."),
                    ],
                ],
                required: ["query"]
            ),
            functionTool(
                "WebFetch",
                "Fetch and extract content from a URL.",
                [
                    "url": stringProperty("URL to fetch."),
                    "prompt": stringProperty("Prompt or extraction instruction to apply to fetched content."),
                ],
                required: ["url", "prompt"]
            ),
            functionTool(
                "ReadLints",
                "Read current workspace linter or diagnostic findings when available.",
                [
                    "path": stringProperty("Optional file or directory to scope diagnostics."),
                    "severity": stringProperty("Optional severity filter such as error or warning."),
                    "limit": integerProperty("Maximum number of diagnostics."),
                ],
                required: []
            ),
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
                "AskQuestion",
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
            functionTool(
                "SwitchMode",
                "Switch between plan and agent mode. Use mode=agent with a concrete plan to execute after planning.",
                [
                    "mode": [
                        "type": "string",
                        "enum": ["plan", "agent"],
                        "description": "Target run mode.",
                    ],
                    "plan": stringProperty("The plan to execute when switching to agent mode."),
                ],
                required: ["mode"]
            ),
            functionTool(
                "Task",
                "Start a delegated task or subagent.",
                [
                    "type": [
                        "type": "string",
                        "enum": ["generalPurpose", "explore", "shell", "cursor-guide", "ci-investigator", "best-of-n-runner"],
                        "description": "Task type. Defaults to generalPurpose.",
                    ],
                    "prompt": stringProperty("Concrete task prompt or shell command for type=shell."),
                    "description": stringProperty("Optional short label."),
                    "model": stringProperty("Optional model hint."),
                    "run_in_background": boolProperty("Run task asynchronously and return a task id."),
                    "cwd": stringProperty("Optional workspace-relative or absolute cwd."),
                    "isolation": [
                        "type": "string",
                        "enum": ["worktree"],
                        "description": "Optional isolation mode. best-of-n-runner uses worktree isolation.",
                    ],
                    "n": integerProperty("Number of isolated attempts for best-of-n-runner."),
                ],
                required: ["prompt"]
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
        "SemanticSearch",
        "WebSearch",
        "WebFetch",
        "ReadLints",
        "Skill",
        "TodoRead",
        "TodoWrite",
        "AskQuestion",
        "SwitchMode",
        "Await",
    ])

    static let mutatingTools = Set(["Write", "StrReplace", "Delete", "EditNotebook", "Shell"])
    static let interactiveTools = Set(["AskQuestion", "SwitchMode"])

    static func policy(for call: AgentToolCall, context: AgentRunContext) -> Result {
        let toolName = normalizedToolName(call.name)
        if context.runMode == .plan, !context.planExited, !isPlanModeSafe(toolName: toolName, call: call) {
            return .deny("\(toolName) is not allowed in plan mode. Call SwitchMode with mode=\"agent\" and a plan before mutating the workspace.")
        }
        if matchesAny(ruleSet: context.toolSettings.disallowedTools, call: call) {
            return .deny("\(toolName) is blocked by permissions settings.")
        }
        if context.permissionMode == .bypassPermissions {
            return .allow
        }
        if matchesAny(ruleSet: context.toolSettings.allowedTools, call: call) {
            return .allow
        }
        if toolRequiresPrompt(toolName: toolName, call: call) || interactiveTools.contains(toolName) {
            return .ask("9GClaw wants to run \(toolName).")
        }
        return .allow
    }

    private static func normalizedToolName(_ value: String) -> String {
        AgentToolNameCanonicalizer.canonical(value)
    }

    private static func matchesAny(ruleSet: [String], call: AgentToolCall) -> Bool {
        ruleSet.contains { rule in matches(rule: rule, call: call) }
    }

    private static func matches(rule: String, call: AgentToolCall) -> Bool {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let canonicalName = AgentToolNameCanonicalizer.canonical(call.name)
        if trimmed == canonicalName || AgentToolNameCanonicalizer.canonical(trimmed) == canonicalName { return true }
        guard canonicalName == "Shell" else {
            return false
        }
        let ruleName: String
        if trimmed.hasPrefix("Shell("), trimmed.hasSuffix(")") {
            ruleName = "Shell"
        } else if trimmed.hasPrefix("Bash("), trimmed.hasSuffix(")") {
            ruleName = "Bash"
        } else {
            return false
        }
        let inner = String(trimmed.dropFirst(ruleName.count + 1).dropLast())
        let input = (try? AgentToolExecutor.inputObject(from: call.inputJSON)) ?? [:]
        let command = input["command"] as? String ?? ""
        if inner == "*" { return true }
        if inner.hasSuffix("*") {
            return command.hasPrefix(String(inner.dropLast()))
        }
        return command == inner
    }

    private static func isPlanModeSafe(toolName: String, call: AgentToolCall) -> Bool {
        if planModeSafeTools.contains(toolName) { return true }
        if toolName == "Shell" {
            return AgentRunContext.isReadOnlyShell(call.inputJSON)
        }
        if toolName == "Task" {
            return AgentRunContext.isReadOnlyTask(call.inputJSON)
        }
        return false
    }

    private static func toolRequiresPrompt(toolName: String, call: AgentToolCall) -> Bool {
        if toolName == "Shell" {
            return true
        }
        if toolName == "Task" {
            return !AgentRunContext.isReadOnlyTask(call.inputJSON)
        }
        return mutatingTools.contains(toolName)
    }
}

struct ResolvedAgentSkill: Sendable, Equatable {
    var requestedName: String
    var canonicalName: String
    var skillFile: String
    var pluginRoot: String?
    var summary: String
    var allowedTools: [String]
    var content: String
}

enum SkillRuntimeService {
    static func load(inputJSON: String, context: AgentRunContext) throws -> String {
        let input = try AgentToolExecutor.inputObject(from: inputJSON)
        let requestedSkill = try AgentToolExecutor.requiredString("skill", input: input)
        let args = (input["args"] as? String).nilIfBlank ?? ""
        let resolved = try resolve(
            requestedSkill,
            workspacePath: context.workspacePath
        )
        context.recordInvokedSkill(resolved.canonicalName)
        let payload: [String: Any] = [
            "skill": resolved.canonicalName,
            "requestedSkill": resolved.requestedName,
            "args": args,
            "skillFile": resolved.skillFile,
            "pluginRoot": resolved.pluginRoot ?? "",
            "summary": resolved.summary,
            "allowedTools": resolved.allowedTools,
            "instructions": limitSkillContent(resolved.content),
        ]
        return jsonString(payload, pretty: true)
    }

    static func resolve(_ skill: String, workspacePath: String) throws -> ResolvedAgentSkill {
        let requested = skill.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else {
            throw ProviderClientError.toolExecution("Skill name is required.")
        }

        var candidates: [URL] = []
        if let rag = ragSkillDirectory(for: requested) {
            candidates.append(rag)
        }
        candidates.append(Self.userSkillsRoot().appendingPathComponent(slugCandidate(requested), isDirectory: true))
        candidates.append(Self.projectSkillsRoot(workspacePath).appendingPathComponent(slugCandidate(requested), isDirectory: true))
        if let pluginRoot = ragPluginRoot() {
            candidates.append(pluginRoot.appendingPathComponent("skills", isDirectory: true).appendingPathComponent(slugCandidate(requested), isDirectory: true))
        }

        for candidate in candidates {
            if let resolved = readSkill(at: candidate, requested: requested) {
                return resolved
            }
        }

        for root in searchableSkillRoots(workspacePath: workspacePath) {
            if let match = scan(root: root, requested: requested) {
                return match
            }
        }

        throw ProviderClientError.toolExecution("Skill not found: \(requested)")
    }

    static func environment(configValues: [String: String]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if let pluginRoot = ragPluginRoot() {
            environment["CLAUDE_PLUGIN_ROOT"] = pluginRoot.path
        }
        environment["EDGECLAW_RAG_ENABLED"] = configValues["rag.enabled"] ?? "false"
        environment["EDGECLAW_RAG_LOCAL_KNOWLEDGE_BASE_URL"] = configValues["rag.localKnowledge.baseUrl"]
        environment["EDGECLAW_RAG_LOCAL_KNOWLEDGE_API_KEY"] = configValues["rag.localKnowledge.apiKey"]
        environment["EDGECLAW_RAG_LOCAL_KNOWLEDGE_MODEL_NAME"] = configValues["rag.localKnowledge.modelName"]
        environment["EDGECLAW_RAG_LOCAL_KNOWLEDGE_DATABASE_URL"] = configValues["rag.localKnowledge.databaseUrl"]
        environment["EDGECLAW_RAG_LOCAL_KNOWLEDGE_TOP_K"] = configValues["rag.localKnowledge.defaultTopK"]
        environment["EDGECLAW_RAG_GLM_WEB_SEARCH_BASE_URL"] = configValues["rag.glmWebSearch.baseUrl"]
        environment["EDGECLAW_RAG_GLM_WEB_SEARCH_API_KEY"] = configValues["rag.glmWebSearch.apiKey"]
        environment["EDGECLAW_RAG_GLM_WEB_SEARCH_TOP_K"] = configValues["rag.glmWebSearch.defaultTopK"]
        let prefix = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = [prefix, environment["PATH"]].compactMap { $0 }.joined(separator: ":")
        return environment.compactMapValues { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : value
        }
    }

    private static func searchableSkillRoots(workspacePath: String) -> [URL] {
        var roots = [
            userSkillsRoot(),
            projectSkillsRoot(workspacePath),
        ]
        if let pluginRoot = ragPluginRoot() {
            roots.append(pluginRoot.appendingPathComponent("skills", isDirectory: true))
        }
        return roots
    }

    private static func readSkill(at directory: URL, requested: String) -> ResolvedAgentSkill? {
        let file = directory.appendingPathComponent("SKILL.md")
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let frontmatter = parseFrontmatter(content)
        let canonical = canonicalName(requested: requested, directory: directory, frontmatter: frontmatter)
        return ResolvedAgentSkill(
            requestedName: requested,
            canonicalName: canonical,
            skillFile: file.path,
            pluginRoot: pluginRoot(forSkillFile: file)?.path,
            summary: summary(from: content, frontmatter: frontmatter),
            allowedTools: parseAllowedTools(content),
            content: content
        )
    }

    private static func scan(root: URL, requested: String) -> ResolvedAgentSkill? {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let needle = requested.lowercased()
        for child in children {
            guard let resolved = readSkill(at: child, requested: requested) else { continue }
            let haystack = "\(child.lastPathComponent) \(resolved.canonicalName) \(resolved.summary) \(resolved.content.prefix(800))".lowercased()
            if haystack.contains(needle) {
                return resolved
            }
        }
        return nil
    }

    private static func ragSkillDirectory(for requested: String) -> URL? {
        guard let pluginRoot = ragPluginRoot() else { return nil }
        let normalized = requested.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let slug: String?
        switch normalized {
        case "9gclaw-rag:glm-web-search", "9gclaw-glm-web-search", "glm-web-search":
            slug = "glm-web-search"
        case "9gclaw-rag:rag-research", "9gclaw-rag-research", "rag-research":
            slug = "rag-research"
        case "9gclaw-rag:local-knowledge", "9gclaw-local-knowledge", "local-knowledge":
            slug = "local-knowledge"
        default:
            slug = nil
        }
        return slug.map { pluginRoot.appendingPathComponent("skills", isDirectory: true).appendingPathComponent($0, isDirectory: true) }
    }

    private static func ragPluginRoot() -> URL? {
        let manager = FileManager.default
        let envRoot = ProcessInfo.processInfo.environment["EDGECLAW_REPO_ROOT"].map {
            URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath)
                .appendingPathComponent("packages/edgeclaw-rag-plugin", isDirectory: true)
        }
        let bundleRoot = Bundle.main.resourceURL?.appendingPathComponent("edgeclaw-rag-plugin", isDirectory: true)
        let sourceRoot = repoRootFromSourceFile().map {
            $0.appendingPathComponent("packages/edgeclaw-rag-plugin", isDirectory: true)
        }
        let fixedRoot = URL(fileURLWithPath: "/Users/hx/Workspace/edgeclaw-opc/packages/edgeclaw-rag-plugin", isDirectory: true)
        for candidate in [envRoot, bundleRoot, sourceRoot, fixedRoot].compactMap({ $0 }) {
            if manager.fileExists(atPath: candidate.appendingPathComponent("skills", isDirectory: true).path) {
                return candidate
            }
        }
        return nil
    }

    private static func repoRootFromSourceFile() -> URL? {
        var current = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let marker = current.appendingPathComponent("packages/edgeclaw-rag-plugin", isDirectory: true)
            if FileManager.default.fileExists(atPath: marker.path) {
                return current
            }
            current.deleteLastPathComponent()
        }
        return nil
    }

    private static func pluginRoot(forSkillFile file: URL) -> URL? {
        var current = file.deletingLastPathComponent()
        for _ in 0..<6 {
            if current.lastPathComponent == "edgeclaw-rag-plugin" {
                return current
            }
            current.deleteLastPathComponent()
        }
        return nil
    }

    private static func userSkillsRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
    }

    private static func projectSkillsRoot(_ workspacePath: String) -> URL {
        URL(fileURLWithPath: NSString(string: workspacePath).expandingTildeInPath)
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
    }

    private static func slugCandidate(_ requested: String) -> String {
        let value = requested.split(separator: ":").last.map(String.init) ?? requested
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func canonicalName(requested: String, directory: URL, frontmatter: [String: String]) -> String {
        let slug = directory.lastPathComponent
        if requested.hasPrefix("9gclaw-rag:") {
            return requested
        }
        if let name = frontmatter["name"], name.hasPrefix("9gclaw-") {
            switch slug {
            case "glm-web-search": return "9gclaw-rag:glm-web-search"
            case "rag-research": return "9gclaw-rag:rag-research"
            case "local-knowledge": return "9gclaw-rag:local-knowledge"
            default: return name
            }
        }
        return frontmatter["name"]?.nilIfBlank ?? slug
    }

    private static func parseFrontmatter(_ content: String) -> [String: String] {
        let lines = content.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else { return [:] }
        var result: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespacesAndNewlines) == "---" { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value.removeFirst()
                value.removeLast()
            }
            result[key] = value
        }
        return result
    }

    private static func parseAllowedTools(_ content: String) -> [String] {
        var tools: [String] = []
        var inAllowedTools = false
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "allowed-tools:" {
                inAllowedTools = true
                continue
            }
            if inAllowedTools, trimmed.hasPrefix("- ") {
                var value = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                    value.removeFirst()
                    value.removeLast()
                }
                tools.append(value)
                continue
            }
            if inAllowedTools, !trimmed.isEmpty, !trimmed.hasPrefix("#") {
                break
            }
        }
        return tools
    }

    private static func summary(from content: String, frontmatter: [String: String]) -> String {
        if let description = frontmatter["description"].nilIfBlank {
            return description
        }
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !trimmed.hasPrefix("---"), !trimmed.hasPrefix("#") {
                return trimmed
            }
        }
        return ""
    }

    private static func limitSkillContent(_ content: String) -> String {
        if content.count <= 18_000 { return content }
        return String(content.prefix(18_000)) + "\n... skill content truncated ..."
    }
}

enum AgentToolExecutor {
    static func execute(call: AgentToolCall, context: AgentRunContext) async -> AgentToolResult {
        let toolName = AgentToolNameCanonicalizer.canonical(call.name)
        do {
            let output: String
            switch toolName {
            case "Read":
                output = try read(inputJSON: call.inputJSON, workspacePath: context.workspacePath)
            case "Write":
                output = try write(inputJSON: call.inputJSON, workspacePath: context.workspacePath)
            case "StrReplace":
                output = try strReplace(inputJSON: call.inputJSON, workspacePath: context.workspacePath)
            case "Delete":
                output = try delete(inputJSON: call.inputJSON, workspacePath: context.workspacePath)
            case "EditNotebook":
                output = try editNotebook(inputJSON: call.inputJSON, workspacePath: context.workspacePath)
            case "Grep":
                output = try grep(inputJSON: call.inputJSON, workspacePath: context.workspacePath)
            case "Glob":
                output = try glob(inputJSON: call.inputJSON, workspacePath: context.workspacePath)
            case "SemanticSearch":
                output = try semanticSearch(inputJSON: call.inputJSON, workspacePath: context.workspacePath)
            case "Shell":
                output = try await shell(inputJSON: call.inputJSON, context: context)
            case "Await":
                output = try await awaitTask(inputJSON: call.inputJSON)
            case "WebSearch":
                output = try await webSearch(inputJSON: call.inputJSON, context: context)
            case "WebFetch":
                output = try await webFetch(inputJSON: call.inputJSON, context: context)
            case "ReadLints":
                output = try await readLints(inputJSON: call.inputJSON, context: context)
            case "Skill":
                output = try SkillRuntimeService.load(inputJSON: call.inputJSON, context: context)
            case "Task":
                output = try await runTask(inputJSON: call.inputJSON, context: context)
            case "TodoRead":
                output = context.todosJSON
            case "TodoWrite":
                output = try todoWrite(inputJSON: call.inputJSON, context: context)
            case "SwitchMode":
                let input = try inputObject(from: call.inputJSON)
                let mode = ((input["mode"] as? String) ?? "agent").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if mode == "agent" {
                    context.planExited = true
                    context.runMode = .agent
                } else if mode == "plan" {
                    context.planExited = false
                    context.runMode = .plan
                }
                output = (input["plan"] as? String).nilIfBlank ?? "Mode switched to \(mode)."
            case "AskQuestion":
                output = askUserQuestionOutput(inputJSON: call.inputJSON)
            default:
                throw ProviderClientError.toolExecution("Unsupported tool: \(toolName)")
            }
            return AgentToolResult(callId: call.id, toolName: toolName, output: limitOutput(output), isError: false)
        } catch {
            return AgentToolResult(callId: call.id, toolName: toolName, output: error.localizedDescription, isError: true)
        }
    }

    static func askUserQuestionResult(call: AgentToolCall, updatedInputJSON: String) -> AgentToolResult {
        AgentToolResult(
            callId: call.id,
            toolName: AgentToolNameCanonicalizer.canonical(call.name),
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
        let ext = url.pathExtension.lowercased()
        if ext == "ipynb" {
            return try readNotebook(url: url, workspacePath: workspacePath)
        }
        if ext == "pdf" {
            return try readPDF(url: url, workspacePath: workspacePath, pages: (input["pages"] as? String).nilIfBlank)
        }
        if imageMimeType(for: url) != nil {
            return try readImage(url: url, workspacePath: workspacePath)
        }
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

    private static func strReplace(inputJSON: String, workspacePath: String) throws -> String {
        let input = try inputObject(from: inputJSON)
        let file = try requiredString("file_path", input: input)
        let url = try AgentPathResolver.resolve(file, workspacePath: workspacePath, mustExist: true)
        var content = try String(contentsOf: url, encoding: .utf8)
        let edits: [[String: Any]]
        if let batch = input["edits"] as? [[String: Any]], !batch.isEmpty {
            edits = batch
        } else {
            edits = [input]
        }
        for editInput in edits {
            let oldString = try requiredString("old_string", input: editInput)
            let newString = try requiredString("new_string", input: editInput)
            let replaceAll = editInput["replace_all"] as? Bool ?? false
            content = try applyEdit(content: content, oldString: oldString, newString: newString, replaceAll: replaceAll)
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
        let target = AgentPathResolver.relativePath(url, workspacePath: workspacePath)
        return edits.count == 1 ? "Edited \(target)." : "Applied \(edits.count) edits to \(target)."
    }

    private static func delete(inputJSON: String, workspacePath: String) throws -> String {
        let input = try inputObject(from: inputJSON)
        let rawPath = try requiredString("path", input: input)
        let recursive = input["recursive"] as? Bool ?? false
        let url = try AgentPathResolver.resolve(rawPath, workspacePath: workspacePath, mustExist: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ProviderClientError.toolExecution("Path does not exist: \(rawPath)")
        }
        if isDirectory.boolValue, !recursive {
            throw ProviderClientError.toolExecution("Refusing to delete directory without recursive=true: \(rawPath)")
        }
        try FileManager.default.removeItem(at: url)
        return "Deleted \(AgentPathResolver.relativePath(url, workspacePath: workspacePath))."
    }

    private static func editNotebook(inputJSON: String, workspacePath: String) throws -> String {
        let input = try inputObject(from: inputJSON)
        let notebookPath = try requiredString("notebook_path", input: input)
        let url = try AgentPathResolver.resolve(notebookPath, workspacePath: workspacePath, mustExist: true)
        guard url.pathExtension.lowercased() == "ipynb" else {
            throw ProviderClientError.toolExecution("EditNotebook requires a .ipynb file.")
        }
        let data = try Data(contentsOf: url)
        guard var object = try JSONSerialization.jsonObject(with: data, options: [.mutableContainers]) as? [String: Any],
              var cells = object["cells"] as? [[String: Any]] else {
            throw ProviderClientError.toolExecution("Notebook JSON must contain a cells array.")
        }
        let mode = ((input["edit_mode"] as? String) ?? "replace").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let index = try notebookCellIndex(input: input, cells: cells, allowEndForInsert: mode == "insert")
        switch mode {
        case "insert":
            let source = (input["new_source"] as? String) ?? ""
            var cell: [String: Any] = [
                "cell_type": (input["cell_type"] as? String).nilIfBlank ?? "code",
                "metadata": [:],
                "source": notebookSourceArray(source),
                "id": UUID().uuidString.prefix(8).lowercased(),
            ]
            if (cell["cell_type"] as? String) == "code" {
                cell["outputs"] = []
                cell["execution_count"] = NSNull()
            }
            cells.insert(cell, at: min(max(index, 0), cells.count))
        case "delete":
            guard cells.indices.contains(index) else {
                throw ProviderClientError.toolExecution("Notebook cell index out of range: \(index)")
            }
            cells.remove(at: index)
        case "replace":
            guard cells.indices.contains(index) else {
                throw ProviderClientError.toolExecution("Notebook cell index out of range: \(index)")
            }
            let source = try requiredString("new_source", input: input)
            cells[index]["source"] = notebookSourceArray(source)
            if let cellType = (input["cell_type"] as? String).nilIfBlank {
                cells[index]["cell_type"] = cellType
            }
        default:
            throw ProviderClientError.toolExecution("Unsupported notebook edit_mode: \(mode)")
        }
        object["cells"] = cells
        let updated = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try updated.write(to: url, options: .atomic)
        return "Notebook \(mode) applied to \(AgentPathResolver.relativePath(url, workspacePath: workspacePath)) at cell \(index)."
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
        if let rgOutput = try runRipgrep(input: input, pattern: pattern, root: root, workspacePath: workspacePath) {
            return rgOutput
        }
        let include = (input["glob"] as? String).nilIfBlank ?? (input["include"] as? String).nilIfBlank
        let includeRegex = try include.map { try AgentPathResolver.globRegex($0) }
        let options: NSRegularExpression.Options = (input["-i"] as? Bool ?? false) ? [.caseInsensitive] : []
        let regex = try NSRegularExpression(pattern: pattern, options: options)
        let outputMode = (input["output_mode"] as? String).nilIfBlank ?? "files_with_matches"
        let headLimit = input["head_limit"] as? Int ?? 250
        let offset = max(input["offset"] as? Int ?? 0, 0)
        let urls: [URL]
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            urls = [root]
        } else {
            urls = AgentPathResolver.walk(root)
        }
        var output: [String] = []
        var counts: [String: Int] = [:]
        var seenFiles = Set<String>()
        for url in urls {
            let relative = AgentPathResolver.relativePath(url, workspacePath: workspacePath)
            if let includeRegex,
               includeRegex.firstMatch(in: relative, range: NSRange(location: 0, length: (relative as NSString).length)) == nil {
                continue
            }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let lines = text.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                let nsLine = line as NSString
                if regex.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)) != nil {
                    counts[relative, default: 0] += 1
                    switch outputMode {
                    case "content":
                        output.append("\(relative):\(index + 1):\(line)")
                    case "count":
                        break
                    default:
                        if seenFiles.insert(relative).inserted {
                            output.append(relative)
                        }
                    }
                }
            }
        }
        if outputMode == "count" {
            output = counts.keys.sorted().map { "\($0):\(counts[$0] ?? 0)" }
        }
        let sliced = output.dropFirst(offset).prefix(headLimit == 0 ? output.count : max(headLimit, 1))
        return sliced.isEmpty ? "No matches for \(pattern)." : sliced.joined(separator: "\n")
    }

    private static func semanticSearch(inputJSON: String, workspacePath: String) throws -> String {
        let input = try inputObject(from: inputJSON)
        let query = try requiredString("query", input: input)
        let searchPath = (input["path"] as? String).nilIfBlank ?? "."
        let root = try AgentPathResolver.resolve(searchPath, workspacePath: workspacePath, mustExist: true)
        let limit = max(1, min(input["limit"] as? Int ?? 20, 100))
        let terms = semanticTerms(query)
        guard !terms.isEmpty else {
            throw ProviderClientError.toolExecution("SemanticSearch query did not contain searchable terms.")
        }
        var hits: [[String: Any]] = []
        for url in AgentPathResolver.walk(root) {
            guard let text = try? String(contentsOf: url, encoding: .utf8), text.count <= 300_000 else { continue }
            let relative = AgentPathResolver.relativePath(url, workspacePath: workspacePath)
            var bestScore = score(relative.lowercased(), terms: terms) * 4
            var bestLine = 1
            var bestSnippet = ""
            for (index, line) in text.components(separatedBy: .newlines).enumerated() {
                let lineScore = score(line.lowercased(), terms: terms)
                if lineScore > bestScore {
                    bestScore = lineScore
                    bestLine = index + 1
                    bestSnippet = line.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            if bestScore > 0 {
                hits.append([
                    "path": relative,
                    "line": bestLine,
                    "score": bestScore,
                    "snippet": bestSnippet.isEmpty ? relative : String(bestSnippet.prefix(500)),
                ])
            }
        }
        let sorted = hits.sorted {
            let leftScore = ($0["score"] as? Int) ?? 0
            let rightScore = ($1["score"] as? Int) ?? 0
            if leftScore != rightScore { return leftScore > rightScore }
            return (($0["path"] as? String) ?? "") < (($1["path"] as? String) ?? "")
        }.prefix(limit)
        return jsonString(["query": query, "results": Array(sorted)], pretty: true)
    }

    private static func shell(inputJSON: String, context: AgentRunContext) async throws -> String {
        let input = try inputObject(from: inputJSON)
        let command = try requiredString("command", input: input)
        let timeoutMs = shellTimeoutMilliseconds(input)
        let cwd = context.workspacePath
        let environment = SkillRuntimeService.environment(configValues: context.nativeConfigValues)
        if input["run_in_background"] as? Bool == true {
            let id = try AgentBackgroundTaskStore.shared.startShell(
                command: command,
                cwd: cwd,
                environment: environment,
                timeoutMs: timeoutMs,
                description: (input["description"] as? String).nilIfBlank ?? command
            )
            return jsonString(["task_id": id, "status": "running", "description": command], pretty: true)
        }
        let result = try await runShellCommand(command: command, cwd: cwd, environment: environment, timeoutMs: timeoutMs)
        return shellResultText(result)
    }

    private static func awaitTask(inputJSON: String) async throws -> String {
        let input = try inputObject(from: inputJSON)
        let taskId = try requiredString("task_id", input: input)
        let block = input["block"] as? Bool ?? true
        let timeoutMs = max(0, min(input["timeout"] as? Int ?? 30_000, 600_000))
        return try await AgentBackgroundTaskStore.shared.output(taskId: taskId, block: block, timeoutMs: timeoutMs)
    }

    private static func webSearch(inputJSON: String, context: AgentRunContext) async throws -> String {
        let input = try inputObject(from: inputJSON)
        let query = try requiredString("query", input: input)
        let env = SkillRuntimeService.environment(configValues: context.nativeConfigValues)
        guard let pluginRoot = env["CLAUDE_PLUGIN_ROOT"], !pluginRoot.isEmpty else {
            throw ProviderClientError.toolExecution("WebSearch requires the 9GClaw RAG plugin.")
        }
        let script = URL(fileURLWithPath: pluginRoot).appendingPathComponent("scripts/glm_web_search.py").path
        guard FileManager.default.fileExists(atPath: script) else {
            throw ProviderClientError.toolExecution("WebSearch script not found: \(script)")
        }
        var args = ["python3", script, "--query", query]
        for domain in stringArray(input["allowed_domains"]) {
            args.append(contentsOf: ["--allowed-domain", domain])
        }
        for domain in stringArray(input["blocked_domains"]) {
            args.append(contentsOf: ["--blocked-domain", domain])
        }
        let result = try await runProcess(
            executable: "/usr/bin/env",
            arguments: args,
            cwd: context.workspacePath,
            environment: env,
            timeoutMs: 30_000
        )
        if result.exitCode != 0 {
            throw ProviderClientError.toolExecution(shellResultText(result))
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func webFetch(inputJSON: String, context: AgentRunContext) async throws -> String {
        let input = try inputObject(from: inputJSON)
        let rawURL = try requiredString("url", input: input)
        let prompt = try requiredString("prompt", input: input)
        guard let url = URL(string: rawURL), let scheme = url.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) else {
            throw ProviderClientError.toolExecution("WebFetch requires an http, https, or file URL.")
        }
        let started = Date()
        let data: Data
        let statusCode: Int
        if scheme == "file" {
            data = try Data(contentsOf: url)
            statusCode = 200
        } else {
            let (fetched, response) = try await URLSession.shared.data(from: url)
            data = fetched
            statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        }
        let extracted = extractFetchedText(data: data, url: url)
        let result = applyFetchPrompt(prompt, content: extracted)
        return jsonString([
            "url": rawURL,
            "code": statusCode,
            "bytes": data.count,
            "durationMs": Int(Date().timeIntervalSince(started) * 1000),
            "result": result,
        ], pretty: true)
    }

    private static func readLints(inputJSON: String, context: AgentRunContext) async throws -> String {
        let input = try inputObject(from: inputJSON)
        let limit = max(1, min(input["limit"] as? Int ?? 100, 500))
        let severityFilter = (input["severity"] as? String).nilIfBlank?.lowercased()
        let scopedPath = (input["path"] as? String).nilIfBlank ?? "."
        _ = try AgentPathResolver.resolve(scopedPath, workspacePath: context.workspacePath, mustExist: true)
        guard let command = context.nativeConfigValues["lint.command"].nilIfBlank else {
            return jsonString(["diagnostics": [], "message": "No native lint.command is configured and no live LSP diagnostics are available."], pretty: true)
        }
        let result = try await runShellCommand(
            command: command,
            cwd: context.workspacePath,
            environment: SkillRuntimeService.environment(configValues: context.nativeConfigValues),
            timeoutMs: 120_000
        )
        let diagnostics = parseLintDiagnostics(result.stdout + "\n" + result.stderr, severity: severityFilter, limit: limit)
        return jsonString([
            "diagnostics": diagnostics,
            "exitCode": result.exitCode,
            "truncated": diagnostics.count >= limit,
        ], pretty: true)
    }

    private static func runTask(inputJSON: String, context: AgentRunContext) async throws -> String {
        let input = try inputObject(from: inputJSON)
        let prompt = try requiredString("prompt", input: input)
        let type = ((input["type"] as? String) ?? "generalPurpose").trimmingCharacters(in: .whitespacesAndNewlines)
        let description = (input["description"] as? String).nilIfBlank ?? type
        if input["run_in_background"] as? Bool == true {
            let n = input["n"] as? Int
            let timeout = input["timeout"] as? Int
            let cwd = (input["cwd"] as? String).nilIfBlank
            let isolation = (input["isolation"] as? String).nilIfBlank
            let id = AgentBackgroundTaskStore.shared.startAsync(description: description) {
                var taskInput: [String: Any] = ["description": description]
                if let n { taskInput["n"] = n }
                if let timeout { taskInput["timeout"] = timeout }
                if let cwd { taskInput["cwd"] = cwd }
                if let isolation { taskInput["isolation"] = isolation }
                return (try? await runTaskSynchronously(type: type, prompt: prompt, input: taskInput, context: context)) ?? "Task failed."
            }
            return jsonString(["task_id": id, "status": "running", "description": description], pretty: true)
        }
        return try await runTaskSynchronously(type: type, prompt: prompt, input: input, context: context)
    }

    private static func readImage(url: URL, workspacePath: String) throws -> String {
        let data = try Data(contentsOf: url)
        guard let mime = imageMimeType(for: url) else {
            throw ProviderClientError.toolExecution("Unsupported image type: \(url.pathExtension)")
        }
        return jsonString([
            "type": "image",
            "file": [
                "filePath": AgentPathResolver.relativePath(url, workspacePath: workspacePath),
                "mediaType": mime,
                "originalSize": data.count,
                "base64": data.base64EncodedString(),
            ],
        ], pretty: true)
    }

    private static func readPDF(url: URL, workspacePath: String, pages: String?) throws -> String {
        let data = try Data(contentsOf: url)
        guard let document = PDFDocument(data: data) else {
            throw ProviderClientError.toolExecution("Unable to parse PDF: \(url.lastPathComponent)")
        }
        let pageNumbers = parsePDFPages(pages, total: document.pageCount)
        var sections = [
            "PDF \(AgentPathResolver.relativePath(url, workspacePath: workspacePath))",
            "pages: \(document.pageCount)",
            "selected: \(pageNumbers.map(String.init).joined(separator: ","))",
            "",
        ]
        for number in pageNumbers {
            guard let page = document.page(at: number - 1) else { continue }
            sections.append("## Page \(number)")
            sections.append(page.string?.nilIfBlank ?? "(no extractable text)")
            sections.append("")
        }
        return sections.joined(separator: "\n")
    }

    private static func readNotebook(url: URL, workspacePath: String) throws -> String {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cells = object["cells"] as? [[String: Any]] else {
            throw ProviderClientError.toolExecution("Notebook JSON must contain a cells array.")
        }
        var output = ["Notebook \(AgentPathResolver.relativePath(url, workspacePath: workspacePath))", "cells: \(cells.count)", ""]
        for (index, cell) in cells.enumerated() {
            let type = cell["cell_type"] as? String ?? "unknown"
            let source = notebookSourceString(cell["source"])
            output.append("## Cell \(index) [\(type)]")
            output.append(source.isEmpty ? "(empty)" : String(source.prefix(4_000)))
            output.append("")
        }
        return output.joined(separator: "\n")
    }

    private static func imageMimeType(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return nil
        }
    }

    private static func parsePDFPages(_ value: String?, total: Int) -> [Int] {
        guard total > 0 else { return [] }
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return Array(1...min(total, 10)) }
        var pages = Set<Int>()
        for part in trimmed.split(separator: ",") {
            let bounds = part.split(separator: "-", maxSplits: 1).compactMap { Int(String($0).trimmingCharacters(in: .whitespaces)) }
            if bounds.count == 2 {
                for page in min(bounds[0], bounds[1])...max(bounds[0], bounds[1]) where page >= 1 && page <= total {
                    pages.insert(page)
                }
            } else if let page = bounds.first, page >= 1, page <= total {
                pages.insert(page)
            }
        }
        return Array(pages).sorted().prefix(10).map { $0 }
    }

    private static func notebookCellIndex(input: [String: Any], cells: [[String: Any]], allowEndForInsert: Bool) throws -> Int {
        if let cellID = (input["cell_id"] as? String).nilIfBlank,
           let index = cells.firstIndex(where: { ($0["id"] as? String) == cellID }) {
            return allowEndForInsert ? index + 1 : index
        }
        if let number = input["cell_number"] as? Int {
            if allowEndForInsert, number == cells.count { return number }
            guard cells.indices.contains(number) else {
                throw ProviderClientError.toolExecution("Notebook cell_number out of range: \(number)")
            }
            return number
        }
        if allowEndForInsert {
            return cells.count
        }
        throw ProviderClientError.toolExecution("EditNotebook requires cell_id or cell_number for replace/delete.")
    }

    private static func notebookSourceArray(_ source: String) -> [String] {
        let parts = source.components(separatedBy: "\n")
        guard !parts.isEmpty else { return [""] }
        return parts.enumerated().map { index, line in
            index == parts.count - 1 ? line : line + "\n"
        }
    }

    private static func notebookSourceString(_ source: Any?) -> String {
        if let value = source as? String { return value }
        if let lines = source as? [String] { return lines.joined() }
        return ""
    }

    private static func runRipgrep(input: [String: Any], pattern: String, root: URL, workspacePath: String) throws -> String? {
        guard let rg = executableURL(named: "rg") else { return nil }
        let outputMode = (input["output_mode"] as? String).nilIfBlank ?? "files_with_matches"
        var args = ["--color", "never"]
        switch outputMode {
        case "content":
            args.append("--line-number")
        case "count":
            args.append("--count")
        default:
            args.append("--files-with-matches")
        }
        if let glob = (input["glob"] as? String).nilIfBlank ?? (input["include"] as? String).nilIfBlank {
            args.append(contentsOf: ["--glob", glob])
        }
        if input["-i"] as? Bool == true { args.append("-i") }
        if input["multiline"] as? Bool == true { args.append(contentsOf: ["-U", "--multiline-dotall"]) }
        if let type = (input["type"] as? String).nilIfBlank { args.append(contentsOf: ["--type", type]) }
        if let context = input["context"] as? Int ?? input["-C"] as? Int { args.append(contentsOf: ["-C", "\(context)"]) }
        if let before = input["-B"] as? Int { args.append(contentsOf: ["-B", "\(before)"]) }
        if let after = input["-A"] as? Int { args.append(contentsOf: ["-A", "\(after)"]) }
        args.append(contentsOf: ["--", pattern, root.path])
        let result = try runProcessSync(
            executable: rg.path,
            arguments: args,
            cwd: workspacePath,
            environment: ProcessInfo.processInfo.environment,
            timeoutMs: 30_000
        )
        guard result.exitCode == 0 || result.exitCode == 1 else { return nil }
        let lines = result.stdout.components(separatedBy: .newlines).filter { !$0.isEmpty }
        let normalized = lines.map { line in
            line.replacingOccurrences(of: workspacePath + "/", with: "")
        }
        let offset = max(input["offset"] as? Int ?? 0, 0)
        let headLimit = input["head_limit"] as? Int ?? 250
        let sliced = normalized.dropFirst(offset).prefix(headLimit == 0 ? normalized.count : max(headLimit, 1))
        return sliced.isEmpty ? "No matches for \(pattern)." : sliced.joined(separator: "\n")
    }

    private static func executableURL(named name: String) -> URL? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":")
            .map(String.init)
        for path in paths {
            let url = URL(fileURLWithPath: path).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private static func semanticTerms(_ query: String) -> [String] {
        query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
    }

    private static func score(_ text: String, terms: [String]) -> Int {
        terms.reduce(0) { partial, term in
            partial + (text.contains(term) ? 1 : 0)
        }
    }

    private static func shellTimeoutMilliseconds(_ input: [String: Any]) -> Int {
        if let timeout = input["timeout"] as? Int {
            return max(1_000, min(timeout, 600_000))
        }
        if let timeoutSeconds = input["timeout_seconds"] as? Int {
            return max(1_000, min(timeoutSeconds * 1_000, 600_000))
        }
        return 120_000
    }

    private static func runShellCommand(command: String, cwd: String, environment: [String: String], timeoutMs: Int) async throws -> AgentShellRunResult {
        try await runProcess(
            executable: "/bin/zsh",
            arguments: ["-lc", command],
            cwd: cwd,
            environment: environment,
            timeoutMs: timeoutMs
        )
    }

    private static func runProcess(
        executable: String,
        arguments: [String],
        cwd: String,
        environment: [String: String],
        timeoutMs: Int
    ) async throws -> AgentShellRunResult {
        try await Task.detached {
            try runProcessSync(executable: executable, arguments: arguments, cwd: cwd, environment: environment, timeoutMs: timeoutMs)
        }.value
    }

    private static func runProcessSync(
        executable: String,
        arguments: [String],
        cwd: String,
        environment: [String: String],
        timeoutMs: Int
    ) throws -> AgentShellRunResult {
        let started = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        var timedOut = false
        let deadline = Date().addingTimeInterval(Double(max(timeoutMs, 1)) / 1_000.0)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            timedOut = true
            process.terminate()
        }
        process.waitUntilExit()
        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return AgentShellRunResult(
            stdout: out,
            stderr: err,
            exitCode: Int(process.terminationStatus),
            timedOut: timedOut,
            durationMs: Int(Date().timeIntervalSince(started) * 1000)
        )
    }

    static func shellResultText(_ result: AgentShellRunResult) -> String {
        var parts = ["exit code: \(result.exitCode)"]
        if result.timedOut { parts.append("timed out") }
        if !result.stdout.isEmpty { parts.append(result.stdout.trimmingCharacters(in: .newlines)) }
        if !result.stderr.isEmpty { parts.append(result.stderr.trimmingCharacters(in: .newlines)) }
        return parts.joined(separator: "\n")
    }

    private static func stringArray(_ value: Any?) -> [String] {
        (value as? [String]) ?? []
    }

    private static func extractFetchedText(data: Data, url: URL) -> String {
        if url.pathExtension.lowercased() == "pdf", let document = PDFDocument(data: data) {
            return (0..<document.pageCount)
                .compactMap { document.page(at: $0)?.string }
                .joined(separator: "\n\n")
        }
        let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        if raw.range(of: "<html", options: [.caseInsensitive]) != nil || raw.range(of: "<body", options: [.caseInsensitive]) != nil {
            return stripHTML(raw)
        }
        return raw
    }

    private static func stripHTML(_ html: String) -> String {
        html
            .replacingOccurrences(of: #"(?is)<script.*?</script>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)<style.*?</style>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?s)<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func applyFetchPrompt(_ prompt: String, content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = prompt.lowercased()
        let maxLength = lower.contains("full") || lower.contains("完整") ? 30_000 : 12_000
        return String(trimmed.prefix(maxLength))
    }

    private static func parseLintDiagnostics(_ output: String, severity: String?, limit: Int) -> [[String: Any]] {
        let pattern = #"^(.+?):(\d+):(?:(\d+):)?\s*(?:(error|warning|info|note):)?\s*(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        var diagnostics: [[String: Any]] = []
        for line in output.components(separatedBy: .newlines) {
            let nsLine = line as NSString
            guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)),
                  match.numberOfRanges >= 6 else { continue }
            let level = match.range(at: 4).location == NSNotFound ? "error" : nsLine.substring(with: match.range(at: 4)).lowercased()
            if let severity, level != severity { continue }
            diagnostics.append([
                "file": nsLine.substring(with: match.range(at: 1)),
                "line": Int(nsLine.substring(with: match.range(at: 2))) ?? 0,
                "column": match.range(at: 3).location == NSNotFound ? 0 : (Int(nsLine.substring(with: match.range(at: 3))) ?? 0),
                "severity": level,
                "message": nsLine.substring(with: match.range(at: 5)),
            ])
            if diagnostics.count >= limit { break }
        }
        return diagnostics
    }

    private static func runTaskSynchronously(type: String, prompt: String, input: [String: Any], context: AgentRunContext) async throws -> String {
        let normalizedType = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let scopedContext = try taskScopedContext(input: input, context: context)
        switch normalizedType {
        case "shell":
            return try await shell(
                inputJSON: jsonString([
                    "command": prompt,
                    "description": (input["description"] as? String) ?? "Task shell command",
                    "timeout": input["timeout"] as? Int ?? 120_000,
                ]),
                context: scopedContext
            )
        case "best-of-n-runner":
            let n = max(1, min(input["n"] as? Int ?? 3, 8))
            var results: [[String: Any]] = []
            for index in 1...n {
                let result = try await withIsolatedGitWorktree(workspacePath: scopedContext.workspacePath) { worktreePath in
                    let isolatedContext = childContext(from: scopedContext, workspacePath: worktreePath)
                    return try await NativeAgentRuntime.runSubagent(
                        inputJSON: jsonString([
                            "prompt": "\(prompt)\n\nAttempt \(index) of \(n). Use this isolated git worktree and return the best concise result.",
                            "description": "best-of-n \(index)",
                            "context": "Task isolation: git worktree at \(worktreePath)",
                        ]),
                        context: isolatedContext
                    )
                }
                results.append(["attempt": index, "worktree": result.worktreePath, "result": result.output])
            }
            return jsonString(["type": type, "attempts": results, "selectedAttempt": 1], pretty: true)
        case "explore", "cursor-guide", "ci-investigator", "generalpurpose", "general-purpose", "general_purpose":
            if ((input["isolation"] as? String) ?? "").lowercased() == "worktree" {
                let result = try await withIsolatedGitWorktree(workspacePath: scopedContext.workspacePath) { worktreePath in
                    let isolatedContext = childContext(from: scopedContext, workspacePath: worktreePath)
                    return try await NativeAgentRuntime.runSubagent(
                        inputJSON: jsonString([
                            "prompt": prompt,
                            "description": (input["description"] as? String) ?? type,
                            "context": "Task type: \(type)\nTask isolation: git worktree at \(worktreePath)",
                        ]),
                        context: isolatedContext
                    )
                }
                return jsonString(["type": type, "worktree": result.worktreePath, "result": result.output], pretty: true)
            }
            return try await NativeAgentRuntime.runSubagent(
                inputJSON: jsonString([
                    "prompt": prompt,
                    "description": (input["description"] as? String) ?? type,
                    "context": "Task type: \(type)",
                ]),
                context: scopedContext
            )
        default:
            throw ProviderClientError.toolExecution("Unsupported Task type: \(type)")
        }
    }

    private static func taskScopedContext(input: [String: Any], context: AgentRunContext) throws -> AgentRunContext {
        guard let cwd = (input["cwd"] as? String).nilIfBlank else { return context }
        let url = try AgentPathResolver.resolve(cwd, workspacePath: context.workspacePath, mustExist: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProviderClientError.toolExecution("Task cwd must be an existing directory: \(cwd)")
        }
        return childContext(from: context, workspacePath: url.path)
    }

    private static func childContext(from context: AgentRunContext, workspacePath: String) -> AgentRunContext {
        let request = AgentRequest(
            sessionId: context.sessionId,
            projectPath: workspacePath,
            prompt: "delegated task",
            providerConfig: context.providerConfig,
            apiKey: context.apiKey,
            priorMessages: [],
            timeoutMs: context.timeoutMs,
            contextWindow: context.contextWindow,
            permissionMode: context.permissionMode,
            runMode: context.runMode,
            workspaceContext: nil,
            toolSettings: context.toolSettings,
            routerRoute: "task",
            nativeConfigValues: context.nativeConfigValues,
            permissionHandler: nil
        )
        let child = AgentRunContext(request: request)
        child.planExited = context.planExited
        child.todosJSON = context.todosJSON
        return child
    }

    private static func withIsolatedGitWorktree(
        workspacePath: String,
        operation: (String) async throws -> String
    ) async throws -> (worktreePath: String, output: String) {
        let environment = SkillRuntimeService.environment(configValues: [:])
        let repoRoot = try gitOutput(
            arguments: ["-C", workspacePath, "rev-parse", "--show-toplevel"],
            cwd: workspacePath,
            environment: environment
        )
        _ = try gitOutput(
            arguments: ["-C", repoRoot, "rev-parse", "--verify", "HEAD"],
            cwd: repoRoot,
            environment: environment
        )
        let parent = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("9gclaw-worktrees", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let worktree = parent.appendingPathComponent("worktree-\(UUID().uuidString)", isDirectory: true)
        let add = try runProcessSync(
            executable: "/usr/bin/env",
            arguments: ["git", "-C", repoRoot, "worktree", "add", "--detach", worktree.path, "HEAD"],
            cwd: repoRoot,
            environment: environment,
            timeoutMs: 120_000
        )
        guard add.exitCode == 0 else {
            throw ProviderClientError.toolExecution(shellResultText(add))
        }
        defer {
            _ = try? runProcessSync(
                executable: "/usr/bin/env",
                arguments: ["git", "-C", repoRoot, "worktree", "remove", "--force", worktree.path],
                cwd: repoRoot,
                environment: environment,
                timeoutMs: 120_000
            )
            try? FileManager.default.removeItem(at: worktree)
        }
        let output = try await operation(worktree.path)
        return (worktree.path, output)
    }

    private static func gitOutput(arguments: [String], cwd: String, environment: [String: String]) throws -> String {
        let result = try runProcessSync(
            executable: "/usr/bin/env",
            arguments: ["git"] + arguments,
            cwd: cwd,
            environment: environment,
            timeoutMs: 30_000
        )
        guard result.exitCode == 0 else {
            throw ProviderClientError.toolExecution(shellResultText(result))
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func todoWrite(inputJSON: String, context: AgentRunContext) throws -> String {
        let input = try inputObject(from: inputJSON)
        guard let todos = input["todos"] else {
            throw ProviderClientError.toolExecution("TodoWrite requires todos.")
        }
        context.todosJSON = jsonString(todos, pretty: true)
        return "Updated todo list."
    }

    static func requiredString(_ key: String, input: [String: Any]) throws -> String {
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

struct AgentShellRunResult: Sendable, Equatable {
    var stdout: String
    var stderr: String
    var exitCode: Int
    var timedOut: Bool
    var durationMs: Int
}

final class AgentBackgroundTaskRecord: @unchecked Sendable {
    let id: String
    let description: String
    let startedAt: Date
    var status: String
    var output: String
    var stdout: String
    var stderr: String
    var exitCode: Int?
    var completedAt: Date?
    var process: Process?

    init(id: String, description: String, status: String = "running", process: Process? = nil) {
        self.id = id
        self.description = description
        self.startedAt = Date()
        self.status = status
        self.output = ""
        self.stdout = ""
        self.stderr = ""
        self.process = process
    }
}

final class AgentBackgroundTaskStore: @unchecked Sendable {
    static let shared = AgentBackgroundTaskStore()
    private let lock = NSLock()
    private var records: [String: AgentBackgroundTaskRecord] = [:]

    func startShell(command: String, cwd: String, environment: [String: String], timeoutMs: Int, description: String) throws -> String {
        let id = "task-\(UUID().uuidString)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let record = AgentBackgroundTaskRecord(id: id, description: description, process: process)
        lock.withLock { records[id] = record }
        try process.run()
        Task.detached { [weak self] in
            let started = Date()
            let deadline = Date().addingTimeInterval(Double(max(timeoutMs, 1)) / 1_000.0)
            var timedOut = false
            while process.isRunning, Date() < deadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            if process.isRunning {
                timedOut = true
                process.terminate()
            }
            process.waitUntilExit()
            let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let result = AgentShellRunResult(
                stdout: out,
                stderr: err,
                exitCode: Int(process.terminationStatus),
                timedOut: timedOut,
                durationMs: Int(Date().timeIntervalSince(started) * 1000)
            )
            self?.complete(
                id: id,
                output: AgentToolExecutor.shellResultText(result),
                stdout: result.stdout,
                stderr: result.stderr,
                exitCode: result.exitCode
            )
        }
        return id
    }

    func startAsync(description: String, operation: @escaping @Sendable () async -> String) -> String {
        let id = "task-\(UUID().uuidString)"
        let record = AgentBackgroundTaskRecord(id: id, description: description)
        lock.withLock { records[id] = record }
        Task.detached { [weak self] in
            let output = await operation()
            self?.complete(id: id, output: output, stdout: output, stderr: "", exitCode: 0)
        }
        return id
    }

    func output(taskId: String, block: Bool, timeoutMs: Int) async throws -> String {
        let deadline = Date().addingTimeInterval(Double(max(timeoutMs, 0)) / 1_000.0)
        while true {
            if let snapshot = snapshot(taskId) {
                if snapshot.status != "running" || !block || Date() >= deadline {
                    return jsonString([
                        "task_id": snapshot.id,
                        "description": snapshot.description,
                        "status": snapshot.status,
                        "exitCode": snapshot.exitCode.map { $0 as Any } ?? NSNull(),
                        "stdout": snapshot.stdout,
                        "stderr": snapshot.stderr,
                        "output": snapshot.output,
                    ], pretty: true)
                }
            } else {
                throw ProviderClientError.toolExecution("Background task not found: \(taskId)")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func terminate(sessionId: String? = nil) {
        lock.withLock {
            for record in records.values where record.status == "running" {
                record.process?.terminate()
                record.status = "cancelled"
                record.completedAt = Date()
            }
        }
    }

    private func complete(id: String, output: String, stdout: String, stderr: String, exitCode: Int?) {
        lock.withLock {
            guard let record = records[id] else { return }
            record.output = output
            record.stdout = stdout
            record.stderr = stderr
            record.exitCode = exitCode
            record.status = "completed"
            record.completedAt = Date()
            record.process = nil
        }
    }

    private func snapshot(_ id: String) -> AgentBackgroundTaskRecord? {
        lock.withLock {
            guard let record = records[id] else { return nil }
            let copy = AgentBackgroundTaskRecord(id: record.id, description: record.description)
            copy.status = record.status
            copy.output = record.output
            copy.stdout = record.stdout
            copy.stderr = record.stderr
            copy.exitCode = record.exitCode
            copy.completedAt = record.completedAt
            return copy
        }
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
