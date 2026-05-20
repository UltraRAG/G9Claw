import AppKit
import XCTest
@testable import NineGClaw

final class ParityLogicTests: XCTestCase {
    func testWorkspacePathValidationCoversRootOutsideAndSystemPaths() {
        let service = WorkspaceService(workspaceRoot: URL(fileURLWithPath: "/Users/tester"))

        XCTAssertFalse(service.validateWorkspacePath("/").valid)
        XCTAssertFalse(service.validateWorkspacePath("/usr/bin").valid)
        XCTAssertFalse(service.validateWorkspacePath("/opt/homebrew").valid)
        XCTAssertFalse(service.validateWorkspacePath("/tmp/work").valid)

        let workspaceService = WorkspaceService(workspaceRoot: URL(fileURLWithPath: "/Users/tester/Workspace"))
        let outside = workspaceService.validateWorkspacePath("/Users/tester/Downloads/project")

        XCTAssertFalse(outside.valid)
        XCTAssertEqual(outside.error, "Workspace path must be within the allowed workspace root: /Users/tester/Workspace")

        let inside = service.validateWorkspacePath("/Users/tester/project")
        XCTAssertTrue(inside.valid)
        XCTAssertEqual(inside.resolvedPath, "/Users/tester/project")
    }

    func testProjectNameMatchesWebManualProjectSlugPolicy() {
        XCTAssertEqual(WorkspaceService.projectName(for: "/Users/tester/My_Project"), "-Users-tester-My-Project")
    }

    func testProjectSortingByNameMatchesSidebarPolicy() {
        let now = Date()
        let projects = [
            project(name: "zeta", displayName: "Zeta", date: now),
            project(name: "alpha", displayName: "Alpha", date: now),
        ]

        XCTAssertEqual(WorkspaceService.sortedProjects(projects, order: .name).map(\.displayName), ["Alpha", "Zeta"])
    }

    func testProjectSortingByDateUsesMostRecentSessionActivity() {
        let now = Date()
        let old = project(name: "old", displayName: "Old", date: now.addingTimeInterval(-5000))
        var recent = project(name: "recent", displayName: "Recent", date: now.addingTimeInterval(-9000))
        recent.sessions = [
            ProjectSession(
                id: "recent-session",
                provider: .nineGClaw,
                title: "Recent",
                summary: "",
                createdAt: now.addingTimeInterval(-9000),
                updatedAt: nil,
                lastActivity: now,
                state: .idle
            )
        ]

        XCTAssertEqual(WorkspaceService.sortedProjects([old, recent], order: .date).first?.name, "recent")
    }

    func testLegacyConfigLoaderReadsDefaultProviderSettings() {
        let yaml = """
        runtime:
          workspacesRoot: ~/Workspace
        gateway:
          runtimePaths:
            generalCwd: ~/Claude/general
        models:
          providers:
            edgeclaw:
              type: openai-chat
              baseUrl: http://example.local/v1
              apiKey: local-secret
          entries:
            default:
              provider: edgeclaw
              name: qwen3.6-27b
        """

        let snapshot = LegacyConfigLoader.snapshot(from: yaml)

        XCTAssertEqual(snapshot?.baseURL, "http://example.local/v1")
        XCTAssertEqual(snapshot?.apiKey, "local-secret")
        XCTAssertEqual(snapshot?.model, "qwen3.6-27b")
        XCTAssertEqual(snapshot?.workspacesRoot, "~/Workspace")
        XCTAssertEqual(snapshot?.generalWorkspacePath, "~/Claude/general")
    }

    func testNativeConfigServiceResolvesRouterDefaultEntry() {
        let yaml = """
        runtime:
          apiTimeoutMs: 90000
          contextWindow: 120000
          workspacesRoot: /Users/tester
        gateway:
          runtimePaths:
            generalCwd: /Users/tester/Claude/general
        models:
          providers:
            edgeclaw:
              type: openai-chat
              baseUrl: http://example.local/v1
              apiKey: local-secret
              headers:
                X-Test: enabled
            edgeclaw_router:
              type: openai-chat
              baseUrl: http://router.local/v1
              apiKey: router-secret
          entries:
            default:
              provider: edgeclaw
              name: qwen3.6-27b
              contextWindow: 160000
            router_small:
              provider: edgeclaw_router
              name: qwen3.6-35b-a3b
              contextWindow: 64000
        router:
          routes:
            default:
              model: router_small
        """

        let snapshot = NativeConfigService.snapshot(from: yaml)

        XCTAssertEqual(snapshot?.defaultEntryID, "router_small")
        XCTAssertEqual(snapshot?.providerConfig.baseURL, "http://router.local/v1")
        XCTAssertEqual(snapshot?.providerConfig.model, "qwen3.6-35b-a3b")
        XCTAssertEqual(snapshot?.apiKey, "router-secret")
        XCTAssertEqual(snapshot?.apiTimeoutMs, 90_000)
        XCTAssertEqual(snapshot?.contextWindow, 64_000)
    }

    func testNativeAgentRuntimeEndpointDoesNotDuplicateChatCompletions() throws {
        let full = try NativeAgentRuntime.endpointURL(
            baseURL: "https://openrouter.ai/api/v1/chat/completions",
            suffix: "chat/completions"
        )
        let base = try NativeAgentRuntime.endpointURL(
            baseURL: "http://example.local/v1/",
            suffix: "chat/completions"
        )

        XCTAssertEqual(full.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(base.absoluteString, "http://example.local/v1/chat/completions")
    }

    func testNativeAgentRuntimeNormalizesOpenAIChatStreamEvents() {
        let object: [String: Any] = [
            "choices": [
                [
                    "delta": ["content": "hello"],
                ],
            ],
            "usage": [
                "prompt_tokens": 3,
                "completion_tokens": 4,
                "total_tokens": 7,
            ],
        ]

        let events = NativeAgentRuntime.openAIChatEvents(from: object, contextWindow: 160_000)

        XCTAssertEqual(events, [
            .contentDelta("hello"),
            .tokenBudget(used: 7, total: 160_000),
        ])
    }

    func testProviderRetryPolicyMatchesCodexTransientDefaults() {
        let policy = ProviderRetryPolicy.codexDefault

        XCTAssertTrue(NativeAgentRuntime.retryDecision(
            for: ProviderClientError.transport("Network request failed: timed out"),
            failedAttempts: 0,
            policy: policy
        ).shouldRetry)
        XCTAssertTrue(NativeAgentRuntime.retryDecision(
            for: ProviderClientError.httpError(statusCode: 502, body: "bad gateway"),
            failedAttempts: 0,
            policy: policy
        ).shouldRetry)
        XCTAssertFalse(NativeAgentRuntime.retryDecision(
            for: ProviderClientError.httpError(statusCode: 429, body: "rate limited"),
            failedAttempts: 0,
            policy: policy
        ).shouldRetry)
        XCTAssertFalse(NativeAgentRuntime.retryDecision(
            for: ProviderClientError.httpError(statusCode: 400, body: "bad request"),
            failedAttempts: 0,
            policy: policy
        ).shouldRetry)
    }

    func testProviderRetryPolicyDoesNotReplayPartialVisibleStreams() {
        XCTAssertFalse(NativeAgentRuntime.retryDecision(
            for: ProviderClientError.streamInterruptedAfterPartialOutput("lost connection"),
            failedAttempts: 0
        ).shouldRetry)
        XCTAssertFalse(NativeAgentRuntime.retryDecision(
            for: ProviderClientError.transport("App Transport Security blocked the HTTP provider request."),
            failedAttempts: 0
        ).shouldRetry)
        XCTAssertFalse(NativeAgentRuntime.retryDecision(
            for: ProviderClientError.transport("Network request failed: timed out"),
            failedAttempts: ProviderRetryPolicy.codexDefault.streamMaxRetries
        ).shouldRetry)
    }

    func testProviderRetryBackoffUsesCodexBaseDelayWithJitter() {
        let first = NativeAgentRuntime.retryBackoffDelay(failedAttempts: 0, baseDelayMs: 200)
        let second = NativeAgentRuntime.retryBackoffDelay(failedAttempts: 1, baseDelayMs: 200)

        XCTAssertGreaterThanOrEqual(first, 0.18)
        XCTAssertLessThanOrEqual(first, 0.22)
        XCTAssertGreaterThanOrEqual(second, 0.36)
        XCTAssertLessThanOrEqual(second, 0.44)
    }

    func testNativeAgentRuntimeToolSchemasIncludeClaudeCodeCoreTools() {
        let tools = AgentToolRegistry.openAITools()
        let names = tools.compactMap { tool -> String? in
            guard let function = tool["function"] as? [String: Any] else { return nil }
            return function["name"] as? String
        }
        let canonicalToolSet: Set<String> = [
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
            "ReadLints",
            "Skill",
            "TodoWrite",
            "AskQuestion",
            "SwitchMode",
            "Task",
        ]

        XCTAssertEqual(Set(names), Set(AgentToolRegistry.toolNames))
        XCTAssertEqual(Set(names), canonicalToolSet)
        XCTAssertFalse(names.contains("Bash"))
        XCTAssertFalse(names.contains("Agent"))
        XCTAssertFalse(names.contains("Edit"))
        XCTAssertFalse(names.contains("ExitPlanMode"))
        XCTAssertFalse(names.contains("AskUserQuestion"))
        XCTAssertFalse(names.contains("WebSearch"))
        XCTAssertFalse(names.contains("WebFetch"))
        XCTAssertFalse(names.contains("Weather"))
    }

    func testAgentToolNameCanonicalizerKeepsClaudeCodeAndSubagentAliasesCompatible() {
        XCTAssertEqual(AgentToolNameCanonicalizer.canonical("Edit"), "StrReplace")
        XCTAssertEqual(AgentToolNameCanonicalizer.canonical("MultiEdit"), "StrReplace")
        XCTAssertEqual(AgentToolNameCanonicalizer.canonical("Bash"), "Shell")
        XCTAssertEqual(AgentToolNameCanonicalizer.canonical("run_command"), "Shell")
        XCTAssertEqual(AgentToolNameCanonicalizer.canonical("Agent"), "Task")
        XCTAssertEqual(AgentToolNameCanonicalizer.canonical("subagent"), "Task")
        XCTAssertEqual(AgentToolNameCanonicalizer.canonical("sub_agent"), "Task")
        XCTAssertEqual(AgentToolNameCanonicalizer.canonical("sub-agent"), "Task")
        XCTAssertEqual(AgentToolNameCanonicalizer.canonical("TaskCreate"), "Task")
        XCTAssertEqual(AgentToolNameCanonicalizer.canonical("TaskOutput"), "Await")
        XCTAssertEqual(AgentToolNameCanonicalizer.canonical("AskUserQuestion"), "AskQuestion")
        XCTAssertEqual(AgentToolNameCanonicalizer.canonical("ExitPlanMode"), "SwitchMode")
        XCTAssertEqual(AgentToolNameCanonicalizer.canonical("NotebookEdit"), "EditNotebook")
        XCTAssertEqual(AgentToolNameCanonicalizer.canonical("GetWeather"), "Weather")
    }

    func testNativeAgentRuntimeParsesFallbackJSONToolCall() {
        let text = """
        ```json
        {"tool":"Read","input":{"file_path":"README.md"}}
        ```
        """

        let calls = NativeAgentRuntime.fallbackToolCalls(in: text)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "Read")
        XCTAssertTrue(calls.first?.inputJSON.contains("README.md") == true)
    }

    func testNativeAgentRuntimeDoesNotParseMixedMarkdownFallbackToolCall() {
        let text = """
        I need to inspect the file.
        ```json
        {"tool":"Read","input":{"file_path":"README.md"}}
        ```
        """

        XCTAssertTrue(NativeAgentRuntime.fallbackToolCalls(in: text).isEmpty)
    }

    func testNativeAgentRuntimeParsesInlineSkillJSONFallback() throws {
        let text = """
        I will use RAG.
        {"skill":"9gclaw-rag:rag-research","args":"DARPA autonomous systems research"}
        """

        let calls = NativeAgentRuntime.fallbackToolCalls(in: text)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data((calls.first?.inputJSON ?? "{}").utf8)) as? [String: Any])

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "Skill")
        XCTAssertEqual(object["skill"] as? String, "9gclaw-rag:rag-research")
    }

    func testNativeAgentRuntimeMapsDirectRAGToolJSONToSkill() throws {
        let text = """
        {"tool":"9gclaw-rag:glm-web-search","input":{"query":"Beijing weather"}}
        """

        let calls = NativeAgentRuntime.fallbackToolCalls(in: text)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data((calls.first?.inputJSON ?? "{}").utf8)) as? [String: Any])

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "Skill")
        XCTAssertEqual(object["skill"] as? String, "9gclaw-rag:glm-web-search")
        XCTAssertEqual(object["args"] as? String, "Beijing weather")
    }

    func testLegacySearchAndWeatherCallsNormalizeToGLMSkill() throws {
        let search = ToolArgumentNormalizer.normalize(AgentToolCall(
            id: "search",
            name: "WebSearch",
            inputJSON: #"{"query":"Beijing weather"}"#
        ))
        let weather = ToolArgumentNormalizer.normalize(AgentToolCall(
            id: "weather",
            name: "GetWeather",
            inputJSON: #"{"location":"北京"}"#
        ))
        let missing = ToolArgumentNormalizer.normalize(AgentToolCall(
            id: "missing",
            name: "Weather",
            inputJSON: #"{"unit":"celsius"}"#
        ))

        XCTAssertEqual(search.call.name, "Skill")
        XCTAssertEqual(weather.call.name, "Skill")
        XCTAssertNil(search.recoveryResult)
        XCTAssertNil(weather.recoveryResult)

        let searchObject = try jsonObject(from: search.call.inputJSON)
        let weatherObject = try jsonObject(from: weather.call.inputJSON)
        XCTAssertEqual(searchObject["skill"] as? String, "9gclaw-rag:glm-web-search")
        XCTAssertEqual(searchObject["args"] as? String, "Beijing weather")
        XCTAssertEqual(weatherObject["skill"] as? String, "9gclaw-rag:glm-web-search")
        XCTAssertEqual(weatherObject["args"] as? String, "北京 weather")
        XCTAssertEqual(missing.call.name, "Skill")
        XCTAssertTrue(missing.recoveryResult?.isError == true)
        XCTAssertTrue(missing.recoveryResult?.output.contains("glm-web-search") == true)
    }

    func testNativeAgentRuntimeParsesLegacyCommandFallbackAsToolOnly() {
        let calls = NativeAgentRuntime.fallbackToolCalls(in: #"<command>{"input":"ls"}</command>"#)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "Glob")
        XCTAssertTrue(calls.first?.inputJSON.contains(#""pattern":"*""#) == true)
    }

    func testNativeAgentRuntimeParsesClaudeInvokeFallbackToolCall() {
        let text = """
        <invoke name="Skill">
        <parameter name="skill">9gclaw-rag:rag-research</parameter>
        <parameter name="args">DARPA autonomous systems research</parameter>
        </invoke>
        """

        let calls = NativeAgentRuntime.fallbackToolCalls(in: text)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "Skill")
        let object = try? JSONSerialization.jsonObject(with: Data((calls.first?.inputJSON ?? "{}").utf8)) as? [String: Any]
        XCTAssertEqual(object?["skill"] as? String, "9gclaw-rag:rag-research")
    }

    func testToolArgumentNormalizerCanonicalizesValidToolArguments() throws {
        let invocation = ToolArgumentNormalizer.normalize(
            AgentToolCall(id: "call-1", name: "Read", inputJSON: #"{"file_path":"README.md","offset":0}"#)
        )
        let data = try XCTUnwrap(invocation.call.inputJSON.data(using: .utf8))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNil(invocation.recoveryResult)
        XCTAssertEqual(object["file_path"] as? String, "README.md")
        XCTAssertEqual(object["offset"] as? Int, 0)
    }

    func testToolArgumentNormalizerTurnsMalformedArgumentsIntoRecoverableToolResult() {
        let invocation = ToolArgumentNormalizer.normalize(
            AgentToolCall(id: "call-bad", name: "Edit", inputJSON: #"{file_path:"index.html"}"#)
        )

        XCTAssertEqual(invocation.call.inputJSON, "{}")
        XCTAssertEqual(invocation.recoveryResult?.callId, "call-bad")
        XCTAssertEqual(invocation.recoveryResult?.toolName, "StrReplace")
        XCTAssertEqual(invocation.recoveryResult?.isError, true)
        XCTAssertTrue(invocation.recoveryResult?.output.contains("invalid JSON") == true)
        XCTAssertEqual(ToolArgumentNormalizer.providerSafeInputJSON(#"{file_path:"index.html"}"#), "{}")
    }

    func testToolArgumentNormalizerRejectsNonObjectArguments() {
        let invocation = ToolArgumentNormalizer.normalize(
            AgentToolCall(id: "call-string", name: "Read", inputJSON: #""README.md""#)
        )

        XCTAssertEqual(invocation.call.inputJSON, "{}")
        XCTAssertTrue(invocation.recoveryResult?.output.contains("JSON object") == true)
    }

    func testAskUserQuestionNormalizesWebAndLegacyQuestionShapes() throws {
        let webPayload = try XCTUnwrap(AgentInteractivePayload.askUserQuestion(from: """
        {"questions":[{"header":"Choose","question":"What should I build?","options":[{"label":"Landing Page","description":"Product page"},{"label":"Blog"}],"multiSelect":false}]}
        """))

        XCTAssertEqual(webPayload.questions.count, 1)
        XCTAssertEqual(webPayload.questions.first?.header, "Choose")
        XCTAssertEqual(webPayload.questions.first?.question, "What should I build?")
        XCTAssertEqual(webPayload.questions.first?.options.map(\.label), ["Landing Page", "Blog"])
        XCTAssertEqual(webPayload.questions.first?.options.first?.description, "Product page")
        XCTAssertEqual(webPayload.questions.first?.multiSelect, false)

        let legacyPayload = try XCTUnwrap(AgentInteractivePayload.askUserQuestion(from: """
        {"question":"Pick a style","options":["Minimal","Playful"]}
        """))

        XCTAssertEqual(legacyPayload.questions.count, 1)
        XCTAssertEqual(legacyPayload.questions.first?.question, "Pick a style")
        XCTAssertEqual(legacyPayload.questions.first?.options.map(\.label), ["Minimal", "Playful"])

        let repairedPayload = try XCTUnwrap(AgentInteractivePayload.askUserQuestion(from: """
        {"questions":[{"header":"计划问题","question":"**页面风格偏好？**","options":[]}]}
        """))
        XCTAssertEqual(repairedPayload.questions.first?.question, "页面风格偏好？")
        XCTAssertEqual(repairedPayload.questions.first?.options.count, 0)

        let manyOptionsPayload = try XCTUnwrap(AgentInteractivePayload.askUserQuestion(from: """
        {"questions":[{"question":"Pick features","options":["A","B","C","D","E","F"]}]}
        """))
        XCTAssertEqual(manyOptionsPayload.questions.first?.options.map(\.label), ["A", "B", "C", "D", "E", "F"])
    }

    func testAskUserQuestionUpdatedInputCarriesAnswers() throws {
        let updated = AgentInteractivePayload.updatedInputJSON(
            originalInputJSON: #"{"question":"Pick a style","options":["Minimal","Playful"]}"#,
            answers: ["Pick a style": "Minimal"]
        )
        let data = try XCTUnwrap(updated.data(using: .utf8))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let answers = try XCTUnwrap(object["answers"] as? [String: String])

        XCTAssertEqual(answers["Pick a style"], "Minimal")
    }

    func testAgentToolExecutorReturnsAskUserQuestionAnswers() {
        let call = AgentToolCall(
            id: "question-1",
            name: "AskUserQuestion",
            inputJSON: #"{"question":"Pick a style","answers":{"Pick a style":"Minimal"}}"#
        )

        let result = AgentToolExecutor.askUserQuestionResult(call: call, updatedInputJSON: call.inputJSON)

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("Pick a style"))
        XCTAssertTrue(result.output.contains("Minimal"))
        XCTAssertTrue(result.output.contains("SwitchMode"))
        XCTAssertTrue(result.output.contains("Do not stop after ordinary prose only"))
    }

    func testAgentToolExecutorRejectsEmptyAskUserQuestionAnswer() {
        let call = AgentToolCall(
            id: "question-empty",
            name: "AskQuestion",
            inputJSON: #"{"question":"确认删除吗？"}"#
        )

        let result = AgentToolExecutor.askUserQuestionResult(call: call, updatedInputJSON: call.inputJSON)

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("requires a user answer"))
    }

    func testAgentRunContextDedupesToolSignature() {
        let context = AgentRunContext(request: agentRequest(permissionMode: .bypassPermissions))
        let first = AgentToolCall(id: "call-1", name: "Read", inputJSON: #"{"file_path":"README.md"}"#)
        let repeated = AgentToolCall(id: "call-2", name: "Read", inputJSON: #"{"file_path":"README.md"}"#)

        XCTAssertTrue(context.markToolCallIfNeeded(first))
        XCTAssertFalse(context.markToolCallIfNeeded(repeated))
    }

    func testReadDeduplicationIsScopedToWorkspaceMutationEpoch() {
        let context = AgentRunContext(request: agentRequest(prompt: "fix the website", permissionMode: .bypassPermissions))
        let firstRead = AgentToolCall(id: "read-1", name: "Read", inputJSON: #"{"file_path":"index.html"}"#)
        let secondRead = AgentToolCall(id: "read-2", name: "Read", inputJSON: #"{"file_path":"index.html"}"#)

        XCTAssertNotNil(context.deduplicatedInvocation(.init(call: firstRead, recoveryResult: nil)))
        XCTAssertNil(context.deduplicatedInvocation(.init(call: secondRead, recoveryResult: nil)))

        let edit = AgentToolCall(id: "edit", name: "StrReplace", inputJSON: #"{"file_path":"index.html","old_string":"a","new_string":"b"}"#)
        context.recordToolResult(
            AgentToolResult(callId: "edit", toolName: "StrReplace", output: "Edited index.html", isError: false),
            call: edit
        )

        let thirdRead = AgentToolCall(id: "read-3", name: "Read", inputJSON: #"{"file_path":"index.html"}"#)
        XCTAssertEqual(context.workspaceMutationEpoch, 1)
        XCTAssertNotNil(context.deduplicatedInvocation(.init(call: thirdRead, recoveryResult: nil)))
    }

    func testDuplicateMutatingToolReturnsSoftPolicyResult() {
        let context = AgentRunContext(request: agentRequest(prompt: "fix the website", permissionMode: .bypassPermissions))
        let firstEdit = AgentToolCall(id: "edit-1", name: "StrReplace", inputJSON: #"{"file_path":"index.html","old_string":"a","new_string":"b"}"#)
        let repeatedEdit = AgentToolCall(id: "edit-2", name: "StrReplace", inputJSON: #"{"file_path":"index.html","old_string":"a","new_string":"b"}"#)

        XCTAssertNotNil(context.deduplicatedInvocation(.init(call: firstEdit, recoveryResult: nil)))
        let duplicate = context.deduplicatedInvocation(.init(call: repeatedEdit, recoveryResult: nil))

        XCTAssertEqual(duplicate?.recoveryResult?.isError, false)
        XCTAssertEqual(duplicate?.recoveryResult?.isPolicyBlock, true)
        XCTAssertTrue(duplicate?.recoveryResult?.output.contains("Duplicate tool request skipped") == true)
    }

    func testDuplicateTodoWriteUsesCurrentSnapshotAsNoOp() {
        let context = AgentRunContext(request: agentRequest(prompt: "fix the website", permissionMode: .bypassPermissions))
        context.todosJSON = #"[{"content":"Update HTML","status":"in_progress"}]"#
        let todo = AgentToolCall(id: "todo", name: "TodoWrite", inputJSON: #"{"todos":[{"content":"Update HTML","status":"in_progress"}]}"#)

        let duplicate = context.deduplicatedInvocation(.init(call: todo, recoveryResult: nil))

        XCTAssertEqual(duplicate?.recoveryResult?.isError, false)
        XCTAssertEqual(duplicate?.recoveryResult?.isPolicyBlock, true)
        XCTAssertTrue(duplicate?.recoveryResult?.output.contains("already up to date") == true)
    }

    func testAgentPathResolverRejectsTraversalOutsideWorkspace() throws {
        let root = repoRootURL()
            .appendingPathComponent("9gclaw-agent-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(
            try AgentPathResolver.resolve("../escape.txt", workspacePath: root.path, mustExist: false)
        )
    }

    func testAgentEditRequiresUniqueMatchUnlessReplaceAll() throws {
        XCTAssertThrowsError(
            try AgentToolExecutor.applyEdit(
                content: "one fish one fish",
                oldString: "one",
                newString: "two",
                replaceAll: false
            )
        )

        XCTAssertEqual(
            try AgentToolExecutor.applyEdit(
                content: "one fish one fish",
                oldString: "one",
                newString: "two",
                replaceAll: true
            ),
            "two fish two fish"
        )
    }

    func testAgentPermissionPolicySoftBlocksMutatingToolsInPlanMode() {
        let context = AgentRunContext(request: agentRequest(runMode: .plan, permissionMode: .bypassPermissions))
        let call = AgentToolCall(
            id: "call-1",
            name: "Write",
            inputJSON: #"{"file_path":"index.html","content":"hi"}"#
        )

        switch AgentPermissionPolicy.policy(for: call, context: context) {
        case .block(let reason):
            XCTAssertTrue(reason.contains("Plan mode skipped"))
        default:
            XCTFail("Write should be soft-blocked before SwitchMode in plan mode.")
        }
    }

    func testPlanModeAllowsMutatingToolsAfterExitPlanMode() async {
        let context = AgentRunContext(request: agentRequest(runMode: .plan, permissionMode: .bypassPermissions))
        let exit = AgentToolCall(
            id: "exit-plan",
            name: "SwitchMode",
            inputJSON: #"{"mode":"agent","plan":"Edit index.html."}"#
        )
        _ = await AgentToolExecutor.execute(call: exit, context: context)
        let write = AgentToolCall(
            id: "call-write",
            name: "Write",
            inputJSON: #"{"file_path":"index.html","content":"hi"}"#
        )

        switch AgentPermissionPolicy.policy(for: write, context: context) {
        case .allow:
            break
        default:
            XCTFail("Write should be allowed after ExitPlanMode.")
        }
    }

    func testAllowedToolBypassesGenericPermissionPrompt() {
        var permissions = ToolPermissionSettings.defaults
        permissions.allowedTools = ["write"]
        let context = AgentRunContext(
            request: agentRequest(permissionMode: .default, toolSettings: permissions)
        )
        let call = AgentToolCall(
            id: "call-write",
            name: "Write",
            inputJSON: #"{"file_path":"index.html","content":"hi"}"#
        )

        XCTAssertEqual(AgentPermissionPolicy.policy(for: call, context: context), .allow)
    }

    func testAllowedInteractiveSwitchModeStillRequiresPlanConfirmation() {
        var permissions = ToolPermissionSettings.defaults
        permissions.allowedTools = ["exit_plan_mode"]
        let context = AgentRunContext(
            request: agentRequest(runMode: .plan, permissionMode: .default, toolSettings: permissions)
        )
        context.planQuestionAnswered = true
        let call = AgentToolCall(
            id: "exit-plan",
            name: "SwitchMode",
            inputJSON: #"{"mode":"agent","plan":"Edit index.html."}"#
        )

        if case .ask(let reason) = AgentPermissionPolicy.policy(for: call, context: context) {
            XCTAssertTrue(reason.lowercased().contains("plan approval"))
        } else {
            XCTFail("Allowed tools must not bypass Plan exit confirmation.")
        }
    }

    func testPlanSwitchModeRequiresAskQuestionBeforeConfirmation() {
        let context = AgentRunContext(request: agentRequest(runMode: .plan, permissionMode: .bypassPermissions))
        let call = AgentToolCall(
            id: "exit-plan-before-question",
            name: "SwitchMode",
            inputJSON: #"{"mode":"agent","plan":"Edit index.html."}"#
        )

        if case .block(let reason) = AgentPermissionPolicy.policy(for: call, context: context) {
            XCTAssertTrue(reason.contains("AskQuestion"))
        } else {
            XCTFail("Plan mode must soft-block exit before AskQuestion is answered.")
        }

        context.planQuestionAnswered = true
        if case .ask(let reason) = AgentPermissionPolicy.policy(for: call, context: context) {
            XCTAssertTrue(reason.lowercased().contains("plan approval"))
        } else {
            XCTFail("Plan exit should ask after the planning question is answered.")
        }
    }

    func testAskQuestionRequiresUserInteractionEvenWithBypassPermissions() {
        let context = AgentRunContext(request: agentRequest(permissionMode: .bypassPermissions))
        let call = AgentToolCall(
            id: "ask-question",
            name: "AskQuestion",
            inputJSON: #"{"question":"确认删除吗？","options":["删除","取消"]}"#
        )

        if case .ask(let reason) = AgentPermissionPolicy.policy(for: call, context: context) {
            XCTAssertTrue(reason.lowercased().contains("question"))
        } else {
            XCTFail("AskQuestion must not be auto-answered in bypass mode.")
        }
    }

    func testDestructiveDeleteRequiresPlanApprovalInAgentMode() {
        let context = AgentRunContext(request: agentRequest(permissionMode: .bypassPermissions))
        let call = AgentToolCall(
            id: "delete-root",
            name: "Delete",
            inputJSON: #"{"path":".","recursive":true}"#
        )

        if case .ask(let reason) = AgentPermissionPolicy.policy(for: call, context: context) {
            XCTAssertTrue(reason.lowercased().contains("destructive"))
        } else {
            XCTFail("Delete should require destructive plan approval in Agent mode.")
        }

        context.planExecutionApproved = true
        XCTAssertEqual(AgentPermissionPolicy.policy(for: call, context: context), .allow)
    }

    func testDestructiveShellRequiresPlanApprovalInAgentMode() {
        let context = AgentRunContext(request: agentRequest(permissionMode: .bypassPermissions))
        let call = AgentToolCall(
            id: "rm-shell",
            name: "Shell",
            inputJSON: #"{"command":"rm -rf public"}"#
        )

        XCTAssertTrue(DestructiveToolClassifier.isDestructive(call: call))
        if case .ask(let reason) = AgentPermissionPolicy.policy(for: call, context: context) {
            XCTAssertTrue(reason.lowercased().contains("destructive"))
        } else {
            XCTFail("Deletion shell commands should require destructive plan approval.")
        }
    }

    func testBlockedToolOverridesAllowedAndBypassPermissionMode() {
        var permissions = ToolPermissionSettings.defaults
        permissions.allowedTools = ["Write"]
        permissions.disallowedTools = ["write"]
        let context = AgentRunContext(
            request: agentRequest(permissionMode: .bypassPermissions, toolSettings: permissions)
        )
        let call = AgentToolCall(
            id: "call-write",
            name: "Write",
            inputJSON: #"{"file_path":"index.html","content":"hi"}"#
        )

        switch AgentPermissionPolicy.policy(for: call, context: context) {
        case .deny(let reason):
            XCTAssertTrue(reason.lowercased().contains("blocked"))
        default:
            XCTFail("Blocked tool should deny before allowed tools or bypass mode.")
        }
    }

    func testWorkspaceMutationDoesNotCompleteAfterOneExploratoryTool() {
        let request = agentRequest(prompt: "帮我继续优化一下这个网页", permissionMode: .bypassPermissions)
        let context = AgentRunContext(request: request)
        let call = AgentToolCall(id: "glob", name: "Glob", inputJSON: #"{"pattern":"**/*","path":"."}"#)
        context.recordToolResult(
            AgentToolResult(callId: "glob", toolName: "Glob", output: "index.html", isError: false),
            call: call
        )

        let nudge = NativeAgentRuntime.continuationNudge(
            request: request,
            context: context,
            assistantContent: "I found index.html."
        )

        XCTAssertNotNil(nudge)
        XCTAssertTrue(nudge?.contains("not completed") == true)
    }

    func testWorkspaceMutationContinuationHasLimit() {
        let request = agentRequest(prompt: "fix the website", permissionMode: .bypassPermissions)
        let context = AgentRunContext(request: request)
        context.continuationNudgeCount = ContinuationPolicy.maxNudges

        XCTAssertNil(
            NativeAgentRuntime.continuationNudge(
                request: request,
                context: context,
                assistantContent: "I should continue."
            )
        )
    }

    func testSuccessfulToolProgressResetsContinuationBudget() {
        let request = agentRequest(prompt: "fix the website", permissionMode: .bypassPermissions)
        let context = AgentRunContext(request: request)
        context.continuationNudgeCount = ContinuationPolicy.maxNudges
        context.recoverableProtocolErrorCount = ContinuationPolicy.maxRecoverableProtocolErrors

        let call = AgentToolCall(id: "read", name: "Read", inputJSON: #"{"file_path":"index.html"}"#)
        context.recordToolResult(
            AgentToolResult(callId: "read", toolName: "Read", output: "<html></html>", isError: false),
            call: call
        )

        XCTAssertEqual(context.continuationNudgeCount, 0)
        XCTAssertEqual(context.recoverableProtocolErrorCount, 0)
        XCTAssertNotNil(
            NativeAgentRuntime.continuationNudge(
                request: request,
                context: context,
                assistantContent: "I should continue."
            )
        )
    }

    func testIncompleteTodosPreventPrematureCompletion() {
        let request = agentRequest(prompt: "帮我优化这个网页", permissionMode: .bypassPermissions)
        let context = AgentRunContext(request: request)
        context.mutatingToolCount = 1
        context.verificationAfterMutationCount = 1
        context.todosJSON = """
        [
          {"content":"Update HTML","status":"completed"},
          {"content":"Update CSS","status":"in_progress"},
          {"content":"Verify","status":"pending"}
        ]
        """

        XCTAssertTrue(context.hasIncompleteTodos)
        if case .continueWithNudge = CompletionGate.decision(
            request: request,
            context: context,
            assistantContent: "优化完成。"
        ) {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected incomplete todos to keep the workspace task running.")
        }

        context.todosJSON = """
        [
          {"content":"Update HTML","status":"completed"},
          {"content":"Update CSS","status":"done"}
        ]
        """
        XCTAssertFalse(context.hasIncompleteTodos)
        XCTAssertTrue(CompletionGate.canFinish(request: request, context: context, assistantContent: "优化完成。"))
    }

    func testDeletionVerificationErrorDoesNotBlockCompletion() {
        let request = agentRequest(prompt: "帮我删除一下这个个人网站", permissionMode: .bypassPermissions)
        let context = AgentRunContext(request: request)
        let deleteCall = AgentToolCall(id: "delete", name: "Delete", inputJSON: #"{"path":".","recursive":true}"#)
        context.recordToolResult(
            AgentToolResult(callId: "delete", toolName: "Delete", output: "Deleted .", isError: false),
            call: deleteCall
        )
        let globCall = AgentToolCall(id: "glob", name: "Glob", inputJSON: #"{"pattern":"**/*","path":"."}"#)
        context.recordToolResult(
            AgentToolResult(callId: "glob", toolName: "Glob", output: "Path does not exist: .", isError: true),
            call: globCall
        )

        XCTAssertTrue(context.hasSuccessfulDeletion)
        XCTAssertTrue(context.lastToolResultWasBenignDeletionVerification)
        XCTAssertFalse(context.lastToolResultWasError)
        XCTAssertEqual(context.verificationAfterMutationCount, 1)
        XCTAssertTrue(CompletionGate.canFinish(request: request, context: context, assistantContent: "确认删除完成，目录不存在。"))
    }

    func testDeletionVerificationRootGlobCanBeSuppressedInTranscript() {
        let deleteCall = ToolCall(id: "delete", name: "Delete", inputJSON: #"{"path":".","recursive":true}"#, status: .completed)
        let deleteResult = ToolResult(toolCallId: "delete", output: "Deleted .", isError: false)
        let globCall = ToolCall(id: "glob", name: "Glob", inputJSON: #"{"pattern":"**/*","path":"."}"#, status: .completed)
        let globResult = ToolResult(toolCallId: "glob", output: "Path does not exist: .", isError: true)

        XCTAssertTrue(DeletionVerificationClassifier.isSuccessfulDeletion(call: deleteCall, result: deleteResult))
        XCTAssertTrue(DeletionVerificationClassifier.shouldSuppressTranscriptPair(
            call: globCall,
            result: globResult,
            sawSuccessfulDeletion: true
        ))
        XCTAssertFalse(DeletionVerificationClassifier.shouldSuppressTranscriptPair(
            call: globCall,
            result: globResult,
            sawSuccessfulDeletion: false
        ))
    }

    func testPlanModeContinuationNudgesEvenForNonWorkspacePrompt() {
        let request = agentRequest(prompt: "北京天气怎么样？", runMode: .plan, permissionMode: .bypassPermissions)
        let context = AgentRunContext(request: request)

        let nudge = NativeAgentRuntime.continuationNudge(
            request: request,
            context: context,
            assistantContent: "北京今天晴。"
        )

        XCTAssertNotNil(nudge)
        XCTAssertTrue(nudge?.contains("AskQuestion") == true)
    }

    func testPlanModeProtocolRecoveryMessageIsNotWorkspaceMutationBanner() {
        XCTAssertTrue(NativeAgentRuntime.planModeProtocolRecoveryMessage.contains("AskQuestion"))
        XCTAssertTrue(NativeAgentRuntime.planModeProtocolRecoveryMessage.contains("SwitchMode"))
        XCTAssertFalse(NativeAgentRuntime.planModeProtocolRecoveryMessage.contains("workspace change"))
    }

    func testWorkspaceMutationIgnoresInjectedMemoryContext() {
        let prompt = """
        只回答一句：9GClaw smoke test ok。

        Relevant 9GClaw memory context:
        之前用户要求优化、创建、修改网页。
        """

        XCTAssertFalse(NativeAgentRuntime.isWorkspaceMutationRequest(prompt))
    }

    func testCompletionGateIgnoresInjectedMemoryContext() {
        let prompt = """
        只回答一句：smoke ok。

        Relevant 9GClaw memory context:
        之前用户要求优化、创建、修改网页。
        """
        let request = agentRequest(prompt: prompt, permissionMode: .default)
        let context = AgentRunContext(request: request)

        XCTAssertTrue(CompletionGate.canFinish(request: request, context: context, assistantContent: "smoke ok。"))
    }

    func testContinueAloneDoesNotMakeSimpleFollowupAWorkspaceMutation() {
        XCTAssertFalse(NativeAgentRuntime.isWorkspaceMutationRequest("继续用一句话回答：第二轮 ok。"))
        XCTAssertTrue(NativeAgentRuntime.isWorkspaceMutationRequest("继续优化这个网页"))
    }

    func testWorkspaceMutationDoesNotFinishOnInProgressTextAfterOneEdit() {
        let request = agentRequest(prompt: "继续优化这个网页", permissionMode: .bypassPermissions)
        let context = AgentRunContext(request: request)
        context.mutatingToolCount = 1
        context.planExited = true
        let content = "现在创建优化后的 HTML 文件："

        XCTAssertFalse(CompletionGate.canFinish(request: request, context: context, assistantContent: content))
        XCTAssertNotNil(NativeAgentRuntime.continuationNudge(request: request, context: context, assistantContent: content))
    }

    func testCompletionGateContinuesOrPausesInsteadOfWorkspaceBanner() {
        let request = agentRequest(prompt: "继续优化这个网页", permissionMode: .bypassPermissions)
        let context = AgentRunContext(request: request)
        context.mutatingToolCount = 1
        context.planExited = true
        let content = "Let me check the duplicate elements issue and fix it."

        if case .continueWithNudge(let nudge) = CompletionGate.decision(request: request, context: context, assistantContent: content) {
            XCTAssertTrue(nudge.contains("Continue"))
        } else {
            XCTFail("Expected continuation nudge for ongoing workspace work.")
        }

        context.continuationNudgeCount = ContinuationPolicy.maxNudges
        if case .pauseNeedsUser(let message) = CompletionGate.decision(request: request, context: context, assistantContent: content) {
            XCTAssertTrue(message.contains("continue") || message.contains("继续"))
        } else {
            XCTFail("Expected recoverable pause after nudge budget is exhausted.")
        }
    }

    func testReadOnlyShellDoesNotSatisfyWorkspaceMutation() {
        let request = agentRequest(prompt: "optimize this website", permissionMode: .bypassPermissions)
        let context = AgentRunContext(request: request)
        let call = AgentToolCall(id: "shell", name: "Shell", inputJSON: #"{"command":"find . -maxdepth 1 -type f"}"#)
        context.recordToolResult(
            AgentToolResult(callId: "shell", toolName: "Shell", output: "index.html", isError: false),
            call: call
        )

        XCTAssertNotNil(
            NativeAgentRuntime.continuationNudge(
                request: request,
                context: context,
                assistantContent: "I found index.html."
            )
        )
    }

    func testOptimizeTaskRequiresVerificationAfterMutation() {
        let request = agentRequest(prompt: "继续优化这个网页", permissionMode: .bypassPermissions)
        let context = AgentRunContext(request: request)
        let editCall = AgentToolCall(id: "edit", name: "StrReplace", inputJSON: #"{"file_path":"index.html","old_string":"a","new_string":"b"}"#)
        context.recordToolResult(
            AgentToolResult(callId: "edit", toolName: "StrReplace", output: "Updated index.html", isError: false),
            call: editCall
        )

        XCTAssertFalse(
            CompletionGate.canFinish(
                request: request,
                context: context,
                assistantContent: "优化完成。"
            )
        )
        XCTAssertNotNil(
            NativeAgentRuntime.continuationNudge(
                request: request,
                context: context,
                assistantContent: "优化完成。"
            )
        )

        let readCall = AgentToolCall(id: "read", name: "Read", inputJSON: #"{"file_path":"index.html"}"#)
        context.recordToolResult(
            AgentToolResult(callId: "read", toolName: "Read", output: "<html>...</html>", isError: false),
            call: readCall
        )

        XCTAssertTrue(
            CompletionGate.canFinish(
                request: request,
                context: context,
                assistantContent: "优化完成。"
            )
        )
    }

    func testAgentToolExecutorWritesInsideWorkspace() async throws {
        let root = repoRootURL()
            .appendingPathComponent("9gclaw-agent-write-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = AgentRunContext(request: agentRequest(projectPath: root.path, permissionMode: .bypassPermissions))
        let call = AgentToolCall(
            id: "call-write",
            name: "Write",
            inputJSON: #"{"file_path":"site/index.html","content":"<h1>Hello</h1>"}"#
        )

        let result = await AgentToolExecutor.execute(call: call, context: context)

        XCTAssertFalse(result.isError, result.output)
        let written = try String(contentsOf: root.appendingPathComponent("site/index.html"), encoding: .utf8)
        XCTAssertEqual(written, "<h1>Hello</h1>")
    }

    func testAgentToolExecutorReadsTextImagePDFAndNotebook() async throws {
        let root = try makeAgentWorkspace("9gclaw-agent-read")
        defer { try? FileManager.default.removeItem(at: root) }
        try "alpha\nbeta\ngamma".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try writeTinyPNG(to: root.appendingPathComponent("pixel.png"))
        try writeMinimalPDF(to: root.appendingPathComponent("empty.pdf"))
        try """
        {"cells":[{"cell_type":"code","id":"cell-a","metadata":{},"source":["print(1)\\n"],"outputs":[],"execution_count":null}],"metadata":{},"nbformat":4,"nbformat_minor":5}
        """.write(to: root.appendingPathComponent("lab.ipynb"), atomically: true, encoding: .utf8)
        let context = AgentRunContext(request: agentRequest(projectPath: root.path, permissionMode: .bypassPermissions))

        let text = await NativeToolRouter.execute(
            call: AgentToolCall(id: "read-text", name: "Read", inputJSON: #"{"file_path":"notes.txt","limit":2}"#),
            context: context
        )
        XCTAssertFalse(text.isError, text.output)
        XCTAssertTrue(text.output.contains("1: alpha"))
        XCTAssertTrue(text.output.contains("2: beta"))

        let image = await NativeToolRouter.execute(
            call: AgentToolCall(id: "read-image", name: "Read", inputJSON: #"{"file_path":"pixel.png"}"#),
            context: context
        )
        XCTAssertFalse(image.isError, image.output)
        let imageObject = try jsonObject(from: image.output)
        XCTAssertEqual(imageObject["type"] as? String, "image")
        let imageFile = try XCTUnwrap(imageObject["file"] as? [String: Any])
        XCTAssertEqual(imageFile["mediaType"] as? String, "image/png")

        let pdf = await NativeToolRouter.execute(
            call: AgentToolCall(id: "read-pdf", name: "Read", inputJSON: #"{"file_path":"empty.pdf","pages":"1"}"#),
            context: context
        )
        XCTAssertFalse(pdf.isError, pdf.output)
        XCTAssertTrue(pdf.output.contains("PDF empty.pdf"))
        XCTAssertTrue(pdf.output.contains("pages: 1"))

        let notebook = await NativeToolRouter.execute(
            call: AgentToolCall(id: "read-notebook", name: "Read", inputJSON: #"{"file_path":"lab.ipynb"}"#),
            context: context
        )
        XCTAssertFalse(notebook.isError, notebook.output)
        XCTAssertTrue(notebook.output.contains("Notebook lab.ipynb"))
        XCTAssertTrue(notebook.output.contains("print(1)"))
    }

    func testAgentToolExecutorEditsDeletesAndNotebookCells() async throws {
        let root = try makeAgentWorkspace("9gclaw-agent-edit")
        defer { try? FileManager.default.removeItem(at: root) }
        let context = AgentRunContext(request: agentRequest(projectPath: root.path, permissionMode: .bypassPermissions))
        try "one fish one fish".write(to: root.appendingPathComponent("story.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("scratch"), withIntermediateDirectories: true)
        try "temp".write(to: root.appendingPathComponent("scratch/temp.txt"), atomically: true, encoding: .utf8)
        try """
        {"cells":[{"cell_type":"markdown","id":"intro","metadata":{},"source":["# Old\\n"]}],"metadata":{},"nbformat":4,"nbformat_minor":5}
        """.write(to: root.appendingPathComponent("lab.ipynb"), atomically: true, encoding: .utf8)

        let replace = await NativeToolRouter.execute(
            call: AgentToolCall(id: "replace", name: "StrReplace", inputJSON: #"{"file_path":"story.txt","old_string":"one","new_string":"two","replace_all":true}"#),
            context: context
        )
        XCTAssertFalse(replace.isError, replace.output)
        let replaced = try String(contentsOf: root.appendingPathComponent("story.txt"), encoding: .utf8)
        XCTAssertEqual(replaced, "two fish two fish")

        let batch = await NativeToolRouter.execute(
            call: AgentToolCall(id: "batch", name: "MultiEdit", inputJSON: #"{"file_path":"story.txt","edits":[{"old_string":"two","new_string":"red","replace_all":true},{"old_string":"red fish red","new_string":"red fish blue"}]}"#),
            context: context
        )
        XCTAssertFalse(batch.isError, batch.output)
        let batchReplaced = try String(contentsOf: root.appendingPathComponent("story.txt"), encoding: .utf8)
        XCTAssertEqual(batchReplaced, "red fish blue fish")

        let notebookReplace = await NativeToolRouter.execute(
            call: AgentToolCall(
                id: "nb-replace",
                name: "EditNotebook",
                inputJSON: toolJSON([
                    "notebook_path": "lab.ipynb",
                    "cell_id": "intro",
                    "new_source": "# New\n",
                    "cell_type": "markdown",
                ])
            ),
            context: context
        )
        XCTAssertFalse(notebookReplace.isError, notebookReplace.output)
        let notebookInsert = await NativeToolRouter.execute(
            call: AgentToolCall(id: "nb-insert", name: "NotebookEdit", inputJSON: #"{"notebook_path":"lab.ipynb","cell_number":1,"edit_mode":"insert","cell_type":"code","new_source":"print(2)\n"}"#),
            context: context
        )
        XCTAssertFalse(notebookInsert.isError, notebookInsert.output)
        let notebookDelete = await NativeToolRouter.execute(
            call: AgentToolCall(id: "nb-delete", name: "EditNotebook", inputJSON: #"{"notebook_path":"lab.ipynb","cell_number":0,"edit_mode":"delete"}"#),
            context: context
        )
        XCTAssertFalse(notebookDelete.isError, notebookDelete.output)
        let notebook = try jsonObject(from: String(contentsOf: root.appendingPathComponent("lab.ipynb"), encoding: .utf8))
        let cells = try XCTUnwrap(notebook["cells"] as? [[String: Any]])
        XCTAssertEqual(cells.count, 1)
        XCTAssertEqual(cells.first?["cell_type"] as? String, "code")

        let blockedDelete = await NativeToolRouter.execute(
            call: AgentToolCall(id: "delete-dir-blocked", name: "Delete", inputJSON: #"{"path":"scratch"}"#),
            context: context
        )
        XCTAssertTrue(blockedDelete.isError)
        let delete = await NativeToolRouter.execute(
            call: AgentToolCall(id: "delete-dir", name: "Delete", inputJSON: #"{"path":"scratch","recursive":true}"#),
            context: context
        )
        XCTAssertFalse(delete.isError, delete.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("scratch").path))
    }

    func testAgentToolExecutorSearchShellAwaitAndLints() async throws {
        let root = try makeAgentWorkspace("9gclaw-agent-search")
        defer {
            AgentBackgroundTaskStore.shared.terminate()
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "func renderDashboard() {}\nlet title = \"alpha\"\n".write(
            to: root.appendingPathComponent("src/App.swift"),
            atomically: true,
            encoding: .utf8
        )
        let request = agentRequest(
            projectPath: root.path,
            permissionMode: .bypassPermissions,
            nativeConfigValues: ["lint.command": "printf 'src/App.swift:2:5: warning: lint warning\\n'"]
        )
        let context = AgentRunContext(request: request)

        let glob = await NativeToolRouter.execute(
            call: AgentToolCall(id: "glob", name: "Glob", inputJSON: #"{"pattern":"**/*.swift","path":"."}"#),
            context: context
        )
        XCTAssertFalse(glob.isError, glob.output)
        XCTAssertTrue(glob.output.contains("src/App.swift"))

        let grep = await NativeToolRouter.execute(
            call: AgentToolCall(id: "grep", name: "Grep", inputJSON: #"{"pattern":"renderDashboard","path":"src","output_mode":"content"}"#),
            context: context
        )
        XCTAssertFalse(grep.isError, grep.output)
        XCTAssertTrue(grep.output.contains("renderDashboard"))

        let semantic = await NativeToolRouter.execute(
            call: AgentToolCall(id: "semantic", name: "SemanticSearch", inputJSON: #"{"query":"renderDashboard","limit":3}"#),
            context: context
        )
        XCTAssertFalse(semantic.isError, semantic.output)
        let semanticObject = try jsonObject(from: semantic.output)
        let semanticResults = try XCTUnwrap(semanticObject["results"] as? [[String: Any]])
        XCTAssertEqual(semanticResults.first?["path"] as? String, "src/App.swift")

        let shell = await NativeToolRouter.execute(
            call: AgentToolCall(id: "shell", name: "Shell", inputJSON: #"{"command":"printf shell-ok","timeout":5000}"#),
            context: context
        )
        XCTAssertFalse(shell.isError, shell.output)
        XCTAssertTrue(shell.output.contains("shell-ok"))

        let background = await NativeToolRouter.execute(
            call: AgentToolCall(id: "shell-bg", name: "Shell", inputJSON: #"{"command":"printf bg-ok","run_in_background":true,"timeout":5000}"#),
            context: context
        )
        XCTAssertFalse(background.isError, background.output)
        let backgroundObject = try jsonObject(from: background.output)
        let taskID = try XCTUnwrap(backgroundObject["task_id"] as? String)
        let awaited = await NativeToolRouter.execute(
            call: AgentToolCall(id: "await", name: "Await", inputJSON: toolJSON(["task_id": taskID, "block": true, "timeout": 2_000])),
            context: context
        )
        XCTAssertFalse(awaited.isError, awaited.output)
        XCTAssertTrue(awaited.output.contains("bg-ok"))

        let lints = await NativeToolRouter.execute(
            call: AgentToolCall(id: "lints", name: "ReadLints", inputJSON: #"{"path":".","severity":"warning"}"#),
            context: context
        )
        XCTAssertFalse(lints.isError, lints.output)
        XCTAssertTrue(lints.output.contains("lint warning"))
    }

    func testLegacySearchAndWeatherExecutionsNormalizeToGLMSkillWhileWebFetchIsDisabled() async throws {
        let root = try makeAgentWorkspace("9gclaw-agent-disabled-search")
        defer { try? FileManager.default.removeItem(at: root) }
        let context = AgentRunContext(request: agentRequest(projectPath: root.path, permissionMode: .bypassPermissions))

        let search = await NativeToolRouter.execute(
            call: AgentToolCall(id: "web-search", name: "WebSearch", inputJSON: #"{"query":"Beijing weather"}"#),
            context: context
        )
        let weather = await NativeToolRouter.execute(
            call: AgentToolCall(id: "weather", name: "GetWeather", inputJSON: #"{"location":"北京"}"#),
            context: context
        )
        let fetch = await NativeToolRouter.execute(
            call: AgentToolCall(id: "web-fetch", name: "WebFetch", inputJSON: #"{"url":"https://example.com","prompt":"extract"}"#),
            context: context
        )

        XCTAssertFalse(search.isError, search.output)
        XCTAssertFalse(weather.isError, weather.output)
        XCTAssertEqual(search.toolName, "Skill")
        XCTAssertEqual(weather.toolName, "Skill")
        XCTAssertTrue(search.output.contains("9gclaw-rag:glm-web-search"))
        XCTAssertTrue(weather.output.contains("9gclaw-rag:glm-web-search"))
        XCTAssertTrue(context.invokedSkills.contains("9gclaw-rag:glm-web-search"))
        XCTAssertTrue(fetch.isError)
        XCTAssertTrue(fetch.output.contains("glm-web-search"))
    }

    func testAgentToolExecutorInteractionModeTodoAndTaskTools() async throws {
        let root = try makeAgentWorkspace("9gclaw-agent-interaction")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("subdir"), withIntermediateDirectories: true)
        let context = AgentRunContext(request: agentRequest(projectPath: root.path, runMode: .plan, permissionMode: .bypassPermissions))

        let todos = await NativeToolRouter.execute(
            call: AgentToolCall(id: "todos", name: "TodoWrite", inputJSON: #"{"todos":[{"content":"ship parity","status":"in_progress"}]}"#),
            context: context
        )
        XCTAssertFalse(todos.isError, todos.output)
        XCTAssertTrue(context.todosJSON.contains("ship parity"))
        XCTAssertTrue(todos.output.contains("continue to use the todo list"))

        let question = AgentToolExecutor.askUserQuestionResult(
            call: AgentToolCall(id: "ask", name: "AskQuestion", inputJSON: "{}"),
            updatedInputJSON: #"{"question":"Pick","answers":{"Pick":"A"}}"#
        )
        XCTAssertFalse(question.isError)
        XCTAssertEqual(question.toolName, "AskQuestion")
        XCTAssertTrue(question.output.contains("A"))

        let switchMode = await NativeToolRouter.execute(
            call: AgentToolCall(id: "switch", name: "SwitchMode", inputJSON: #"{"mode":"agent","plan":"Run task."}"#),
            context: context
        )
        XCTAssertFalse(switchMode.isError, switchMode.output)
        XCTAssertEqual(context.runMode, .agent)
        XCTAssertTrue(context.planExited)
        XCTAssertTrue(context.planExecutionApproved)

        let task = await NativeToolRouter.execute(
            call: AgentToolCall(id: "task", name: "Task", inputJSON: #"{"type":"shell","prompt":"pwd","cwd":"subdir","timeout":5000}"#),
            context: context
        )
        XCTAssertFalse(task.isError, task.output)
        XCTAssertTrue(task.output.contains(root.appendingPathComponent("subdir").path))
    }

    func testAgentPermissionPolicyClassifiesCanonicalTools() {
        let context = AgentRunContext(request: agentRequest(runMode: .plan, permissionMode: .bypassPermissions))
        XCTAssertEqual(
            AgentPermissionPolicy.policy(
                for: AgentToolCall(id: "read", name: "Read", inputJSON: #"{"file_path":"README.md"}"#),
                context: context
            ),
            .allow
        )
        XCTAssertEqual(
            AgentPermissionPolicy.policy(
                for: AgentToolCall(id: "shell-read", name: "Shell", inputJSON: #"{"command":"git status --short"}"#),
                context: context
            ),
            .allow
        )
        XCTAssertEqual(
            AgentPermissionPolicy.policy(
                for: AgentToolCall(id: "task-explore", name: "Task", inputJSON: #"{"type":"explore","prompt":"find usage"}"#),
                context: context
            ),
            .allow
        )

        if case .block(let reason) = AgentPermissionPolicy.policy(
            for: AgentToolCall(id: "delete", name: "Delete", inputJSON: #"{"path":"tmp.txt"}"#),
            context: context
        ) {
            XCTAssertTrue(reason.contains("Plan mode skipped"))
        } else {
            XCTFail("Delete must be soft-blocked in plan mode.")
        }

        if case .block = AgentPermissionPolicy.policy(
            for: AgentToolCall(id: "shell-write", name: "Shell", inputJSON: #"{"command":"touch tmp.txt"}"#),
            context: context
        ) {
            XCTAssertTrue(true)
        } else {
            XCTFail("Mutating Shell must be soft-blocked in plan mode.")
        }

        if case .block = AgentPermissionPolicy.policy(
            for: AgentToolCall(id: "task-full", name: "Task", inputJSON: #"{"type":"generalPurpose","prompt":"change files"}"#),
            context: context
        ) {
            XCTAssertTrue(true)
        } else {
            XCTFail("Mutating/full-agent Task must be soft-blocked in plan mode.")
        }
    }

    func testComposerPasteboardReaderParsesFinderFileAndMixedText() throws {
        let root = repoRootURL()
            .appendingPathComponent("9gclaw-paste-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("notes.txt")
        try "hello".write(to: fileURL, atomically: true, encoding: .utf8)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("9gclaw-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([fileURL as NSURL])
        pasteboard.setString("Please inspect the attached file.", forType: .string)

        let attachments = ComposerPasteboardReader.attachments(from: pasteboard) { _ in nil }

        XCTAssertEqual(attachments.map(\.fileName), ["notes.txt"])
        XCTAssertEqual(ComposerPasteboardReader.textPayload(from: pasteboard, attachments: attachments), "Please inspect the attached file.")
    }

    func testComposerPasteboardReaderParsesClipboardImage() throws {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("9gclaw-image-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        let savedURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pasted-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: savedURL) }

        let attachments = ComposerPasteboardReader.attachments(from: pasteboard) { _ in
            try? Data("png".utf8).write(to: savedURL)
            return savedURL
        }

        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments.first?.mimeType, "image/png")
        XCTAssertEqual(attachments.first?.path, savedURL.path)
    }

    func testAppLanguageSystemResolvesChineseAndEnglish() {
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["zh-Hans-US"]), .chineseSimplified)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["en-US"]), .english)
        XCTAssertEqual(AppLanguage.english.resolved(preferredLanguages: ["zh-Hans-US"]), .english)
        XCTAssertEqual(AppLanguage.chineseSimplified.resolved(preferredLanguages: ["en-US"]), .chineseSimplified)
    }

    func testLocalizationTablesCoverAllKeys() {
        let allKeys = Set(L10nKey.allCases)

        XCTAssertEqual(Set(LocalizationService.english.keys), allKeys)
        XCTAssertEqual(Set(LocalizationService.chineseSimplified.keys), allKeys)
    }

    func testAppSettingsStoreRoundTripsLanguage() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("9gclaw-settings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppSettingsStore(url: root.appendingPathComponent("settings.json"))
        var settings = AppSettings.defaults
        settings.language = .chineseSimplified
        settings.projectSortOrder = .date

        try store.save(settings)
        let loaded = try XCTUnwrap(store.load())

        XCTAssertEqual(loaded.language, .chineseSimplified)
        XCTAssertEqual(loaded.projectSortOrder, .date)
    }

    func testProcessTraceHidesCompletedStatusOnlyActivity() {
        let completedStatus = AgentActivity(
            id: "status",
            sessionId: "session",
            title: "Connecting",
            detail: "Opening model stream",
            phase: .status,
            state: .completed,
            createdAt: Date(),
            updatedAt: Date()
        )
        let runningStatus = AgentActivity(
            id: "status",
            sessionId: "session",
            title: "Connecting",
            detail: "Opening model stream",
            phase: .status,
            state: .running,
            createdAt: Date(),
            updatedAt: Date()
        )
        let completedTool = AgentActivity(
            id: "tool",
            sessionId: "session",
            title: "Read README.md",
            detail: #"{"file_path":"README.md"}"#,
            phase: .tool,
            state: .completed,
            createdAt: Date(),
            updatedAt: Date(),
            toolName: "Read"
        )

        XCTAssertFalse(AgentActivity.hasRenderableProcessTrace([completedStatus]))
        XCTAssertTrue(AgentActivity.hasRenderableProcessTrace([runningStatus]))
        XCTAssertTrue(AgentActivity.hasRenderableProcessTrace([completedStatus, completedTool]))
        XCTAssertEqual(AgentActivity.processTraceActivities([completedStatus, completedTool]).map(\.id), ["tool"])
    }

    func testRunHeaderActivitiesKeepCompletedStatusForTiming() {
        let assistantID = "assistant-run"
        let completedStatus = AgentActivity(
            id: "run",
            sessionId: "session",
            title: "正在接收响应",
            detail: "正在流式输出助手回复",
            phase: .status,
            state: .completed,
            createdAt: Date().addingTimeInterval(-3),
            updatedAt: Date(),
            anchorBlockID: assistantID
        )
        let unrelated = AgentActivity(
            id: "other",
            sessionId: "session",
            title: "Other",
            detail: "",
            phase: .status,
            state: .completed,
            createdAt: Date(),
            updatedAt: Date(),
            anchorBlockID: "other-assistant"
        )

        XCTAssertEqual(AgentActivity.processTraceActivities([completedStatus], anchoredTo: assistantID).map(\.id), [])
        XCTAssertEqual(AgentActivity.runHeaderActivities([completedStatus, unrelated], anchoredTo: assistantID).map(\.id), ["run"])
    }

    func testMemoryDashboardBuildsWorkspaceSnapshot() throws {
        let root = repoRootURL()
            .appendingPathComponent("9gclaw-memory-\(UUID().uuidString)", isDirectory: true)
        let memoryRoot = root.appendingPathComponent(".edgeclaw/memory", isDirectory: true)
        try FileManager.default.createDirectory(at: memoryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        ---
        name: Launch Plan
        description: Build the first native dashboard.
        type: project
        ---

        Ship the native Memory dashboard.
        """.write(to: memoryRoot.appendingPathComponent("launch-plan.md"), atomically: true, encoding: .utf8)

        let service = MemoryService()
        service.loadWorkspaceRecords(projectRoot: root.path, projectName: "Native")
        let snapshot = service.dashboard(projectName: "Native", projectRoot: root.path)

        XCTAssertEqual(snapshot.workspace.workspaceMode, "project")
        XCTAssertEqual(snapshot.workspace.totalProjects, 1)
        XCTAssertEqual(snapshot.workspace.projectEntries.first?.name, "launch-plan")
        XCTAssertEqual(snapshot.overview.totalEntries, 1)
    }

    func testMemoryDreamRollbackAndBundleRoundTrip() throws {
        let service = MemoryService()
        _ = service.upsert(name: "session-summary", summary: "Created the Swift agent shell.", projectName: "Native")

        var snapshot = service.runDream(projectName: "Native", projectRoot: nil)

        XCTAssertEqual(snapshot.dreamTraceRecords.count, 1)
        XCTAssertEqual(snapshot.lastDreamSnapshot?.rollbackReady, true)

        snapshot = try service.rollbackLastDream(projectName: "Native", projectRoot: nil)

        XCTAssertEqual(snapshot.dreamTraceRecords.count, 2)
        XCTAssertEqual(snapshot.lastDreamSnapshot?.rollbackReady, false)

        let exported = try service.exportBundle(projectName: "Native")
        let imported = MemoryService()
        try imported.importBundle(exported, projectName: "Native")
        let importedSnapshot = imported.dashboard(projectName: "Native")

        XCTAssertTrue(importedSnapshot.records.map(\.name).contains("session-summary"))
        XCTAssertGreaterThanOrEqual(importedSnapshot.overview.totalEntries, 1)
    }

    func testMemoryRecallRanksRelevantRecordsAndKeepsEmptyDiagnostics() {
        let service = MemoryService()
        _ = service.upsert(name: "router-cost", summary: "Router cost baseline and saved price are shown in route details.", projectName: "Native")
        _ = service.upsert(name: "theme-note", summary: "Use compact spacing in the memory page.", projectName: "Native")

        let context = service.recallForTurn(prompt: "How should router saved price display?", projectName: "Native", projectRoot: nil)
        XCTAssertTrue(context.split(separator: "\n").first?.contains("router-cost") == true)
        XCTAssertFalse(context.contains("theme-note"))

        let empty = service.recallForTurn(prompt: "completely-unmatched-term", projectName: "Native", projectRoot: nil)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(service.caseTraces(limit: 1).first?.reply, "No memory records matched this turn.")
    }

    @MainActor
    func testMemoryJobsPersistStateAndTraceIDsInSnapshot() async throws {
        let root = repoRootURL()
            .appendingPathComponent("9gclaw-memory-job-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "hello".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let service = MemoryService()
        let indexed = try await service.runIndexJob(projectRoot: root.path, projectName: "Native")

        XCTAssertEqual(indexed.jobStates[.index]?.phase, .completed)
        XCTAssertEqual(indexed.jobStates[.index]?.traceID, indexed.indexTraceRecords.first?.id)

        _ = service.recallForTurn(prompt: "What did we do?", projectName: "Native", projectRoot: root.path)
        let recalled = service.dashboard(projectName: "Native", projectRoot: root.path)
        XCTAssertEqual(recalled.jobStates[.recall]?.phase, .completed)
        XCTAssertEqual(recalled.jobStates[.recall]?.traceID, recalled.caseTraceRecords.first?.id)

        let dreamed = await service.runDreamJob(projectName: "Native", projectRoot: root.path)
        XCTAssertEqual(dreamed.jobStates[.dream]?.phase, .completed)
        XCTAssertEqual(dreamed.jobStates[.dream]?.traceID, dreamed.dreamTraceRecords.first?.id)
    }

    func testMarkdownParserHandlesTablesCodeAndTaskLists() {
        let blocks = NativeMarkdownParser.parse("""
        ### 视觉优化

        | 改进项 | 说明 |
        |---|---|
        | **动画** | 已加入 |

        - [x] 完成布局
        - [ ] 验证

        ```html
        <main>Hello</main>
        ```
        """)

        XCTAssertTrue(blocks.contains { block in
            if case .heading(let level, let title) = block {
                return level == 3 && title == "视觉优化"
            }
            return false
        })
        XCTAssertTrue(blocks.contains { block in
            if case .table(let header, let rows) = block {
                return header == ["改进项", "说明"] && rows.count == 1
            }
            return false
        })
        XCTAssertTrue(blocks.contains { block in
            if case .list(_, let items) = block {
                return items.map(\.checked) == [true, false]
            }
            return false
        })
        XCTAssertTrue(blocks.contains { block in
            if case .code(let language, let value) = block {
                return language == "html" && value.contains("<main>")
            }
            return false
        })
    }

    func testFileWorkspaceLayoutMetricsDoNotDependOnChatSplit() {
        XCTAssertEqual(FileWorkspaceLayoutMetrics.browserDefaultWidth, 330)
        XCTAssertGreaterThanOrEqual(FileWorkspaceLayoutMetrics.browserDefaultWidth, FileWorkspaceLayoutMetrics.browserMinWidth)
        XCTAssertLessThanOrEqual(FileWorkspaceLayoutMetrics.browserDefaultWidth, FileWorkspaceLayoutMetrics.browserMaxWidth)
        XCTAssertEqual(FileWorkspaceLayoutMetrics.treeRowHeight, 28)
    }

    func testYAMLScalarEditorUpdatesNestedScalarsWithoutReordering() {
        let yaml = """
        runtime:
          host: 0.0.0.0
          serverPort: 3001
        router:
          enabled: true
        """

        let updated = YAMLScalarEditor.set(path: "runtime.serverPort", value: "3002", in: yaml)

        XCTAssertTrue(updated.contains("runtime:"))
        XCTAssertTrue(updated.contains("  serverPort: 3002"))
        XCTAssertTrue(updated.contains("router:"))
    }

    func testConfigYAMLAPIKeyResolutionPrefersYAMLAndFallsBackToKeychainWhenBlank() {
        let yamlWithKey = """
        models:
          providers:
            edgeclaw:
              type: openai-chat
              baseUrl: http://example.local/v1
              apiKey: yaml-secret
          entries:
            default:
              provider: edgeclaw
              name: qwen3.6-27b
        """
        let snapshotWithKey = NativeConfigService.snapshot(from: yamlWithKey)

        let resolvedYAMLKey = NativeConfigService.resolvedAPIKey(
            routeEntryID: "default",
            nativeConfig: snapshotWithKey,
            keychainValue: "keychain-secret",
            apiKeyDraft: "draft-secret"
        )

        XCTAssertEqual(resolvedYAMLKey, "yaml-secret")

        let yamlBlankKey = """
        models:
          providers:
            edgeclaw:
              type: openai-chat
              baseUrl: http://example.local/v1
              apiKey: ""
          entries:
            default:
              provider: edgeclaw
              name: qwen3.6-27b
        """
        let snapshotBlankKey = NativeConfigService.snapshot(from: yamlBlankKey)

        let resolvedFallbackKey = NativeConfigService.resolvedAPIKey(
            routeEntryID: "default",
            nativeConfig: snapshotBlankKey,
            keychainValue: "keychain-secret",
            apiKeyDraft: "draft-secret"
        )

        XCTAssertEqual(resolvedFallbackKey, "keychain-secret")
    }

    func testSkillsSlugValidationRejectsTraversal() {
        XCTAssertTrue(SkillsService.isSafeSlug("review-helper"))
        XCTAssertTrue(SkillsService.isSafeSlug("team.skill_1"))
        XCTAssertFalse(SkillsService.isSafeSlug("../escape"))
        XCTAssertFalse(SkillsService.isSafeSlug("nested/path"))
        XCTAssertFalse(SkillsService.isSafeSlug(".."))
    }

    func testSkillValidationRequiresSkillMarkdownFrontmatter() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("9gclaw-skill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = SkillsService()
        var result = service.validate(source: root)
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.hardFails.contains { $0.code == "no_skill_md" })

        try """
        ---
        name: Reviewer
        description: Checks diffs for regressions before shipping changes.
        ---

        # Reviewer
        """.write(to: root.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        result = service.validate(source: root)
        XCTAssertTrue(result.ok)
        XCTAssertTrue(result.hardFails.isEmpty)
    }

    func testNativeTurnControllerRecordsOrderedTimelineItems() async {
        let controller = NativeTurnController(
            sessionId: "session-a",
            workspacePath: "/Users/tester/project",
            mode: .plan
        )

        let user = await controller.recordUserMessage("Optimize the page")
        let tool = await controller.recordToolCall(
            AgentToolCall(id: "call-1", name: "Grep", inputJSON: #"{"pattern":"index"}"#)
        )
        let recorded = await controller.recordToolResult(
            AgentToolResult(callId: "call-1", toolName: "Grep", output: "index.html", isError: false)
        )
        await controller.markPlanExited()
        await controller.finish()

        let snapshot = await controller.snapshot()
        XCTAssertEqual(snapshot.status, .completed)
        XCTAssertEqual(snapshot.mode, .agent)
        XCTAssertEqual(snapshot.items.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(user.kind, .userMessage)
        XCTAssertEqual(tool.kind, .webSearch)
        XCTAssertEqual(recorded.callItem?.status, .completed)
        XCTAssertEqual(recorded.resultItem.kind, .toolResult)
    }

    func testNativeThreadManagerInterruptsActiveTurn() async {
        let manager = NativeThreadManager()
        let request = agentRequest(prompt: "Build a page")
        let session = await manager.session(for: request)
        let turn = await session.startTurn(request: request)
        _ = await turn.recordStatus("thinking")

        await manager.interrupt(sessionId: request.sessionId)

        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.turns.last?.status, .interrupted)
        XCTAssertTrue(snapshot.turns.last?.items.contains { $0.status == .interrupted } == true)
    }

    func testNativeToolRouterUsesSharedToolRegistryAndPlanPolicy() {
        let tools = NativeToolRouter.openAITools()
        let names = tools.compactMap { tool -> String? in
            guard let function = tool["function"] as? [String: Any] else { return nil }
            return function["name"] as? String
        }
        XCTAssertTrue(names.contains("Read"))
        XCTAssertTrue(names.contains("Write"))

        let context = AgentRunContext(request: agentRequest(runMode: .plan))
        let editCall = AgentToolCall(id: "call-edit", name: "StrReplace", inputJSON: "{}")
        if case .block(let reason) = NativeToolRouter.permissionPolicy(for: editCall, context: context) {
            XCTAssertTrue(reason.contains("Plan mode skipped"))
        } else {
            XCTFail("Plan mode must soft-block mutating tools before SwitchMode.")
        }
    }

    func testPlanSwitchModeRequiresConfirmationEvenWithBypassAndAllowedTool() {
        var toolSettings = ToolPermissionSettings.defaults
        toolSettings.allowedTools = ["SwitchMode"]
        let context = AgentRunContext(request: agentRequest(
            runMode: .plan,
            permissionMode: .bypassPermissions,
            toolSettings: toolSettings
        ))
        context.planQuestionAnswered = true
        let call = AgentToolCall(
            id: "switch-plan",
            name: "SwitchMode",
            inputJSON: #"{"mode":"agent","plan":"Do the work."}"#
        )

        if case .ask(let reason) = NativeToolRouter.permissionPolicy(for: call, context: context) {
            XCTAssertTrue(reason.lowercased().contains("plan approval"))
        } else {
            XCTFail("SwitchMode must still ask in Plan mode.")
        }
    }

    func testAgentModeSwitchModeStillShowsPlanConfirmation() {
        let context = AgentRunContext(request: agentRequest(runMode: .agent, permissionMode: .bypassPermissions))
        let call = AgentToolCall(
            id: "switch-agent-plan",
            name: "SwitchMode",
            inputJSON: #"{"mode":"agent","plan":"Implement the change."}"#
        )

        if case .ask(let reason) = NativeToolRouter.permissionPolicy(for: call, context: context) {
            XCTAssertTrue(reason.lowercased().contains("plan approval"))
        } else {
            XCTFail("Agent-mode SwitchMode must still render the plan confirmation card.")
        }
    }

    func testInteractiveSwitchModeDefersVisiblePlanIntoConfirmationInput() throws {
        let assistantPlan = """
        ## 实施计划
        1. 检查现有天气页面结构。
        2. 优化搜索、定位和缓存逻辑。
        3. 运行验证并总结结果。
        """
        let call = AgentToolCall(id: "switch", name: "SwitchMode", inputJSON: #"{"mode":"agent"}"#)

        let result = InteractivePlanContentDeferrer.prepare(
            assistantContent: assistantPlan,
            toolCalls: [call]
        )

        XCTAssertTrue(result.suppressVisibleAssistantText)
        XCTAssertNil(result.visibleIntro)
        XCTAssertEqual(result.planMarkdown, assistantPlan)
        let data = try XCTUnwrap(result.toolCalls.first?.inputJSON.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["mode"] as? String, "agent")
        XCTAssertEqual(object["plan"] as? String, assistantPlan)
        XCTAssertEqual(object["assistantPlanMarkdown"] as? String, assistantPlan)
    }

    func testInteractiveSwitchModeKeepsShortIntroAndMovesPlanToConfirmationInput() throws {
        let assistantText = """
        好的，我先整理现有代码结构，然后给出可执行计划。

        ## 整理计划
        1. 统一文件命名和注释。
        2. 清理重复样式。
        """
        let call = AgentToolCall(id: "switch", name: "SwitchMode", inputJSON: #"{"mode":"agent"}"#)

        let result = InteractivePlanContentDeferrer.prepare(
            assistantContent: assistantText,
            toolCalls: [call]
        )

        XCTAssertTrue(result.suppressVisibleAssistantText)
        XCTAssertEqual(result.visibleIntro, "好的，我先整理现有代码结构，然后给出可执行计划。")
        XCTAssertTrue(result.planMarkdown?.contains("## 整理计划") == true)
        let data = try XCTUnwrap(result.toolCalls.first?.inputJSON.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue((object["assistantPlanMarkdown"] as? String)?.contains("清理重复样式") == true)
    }

    func testAskQuestionDefersCompanionAssistantContentBeforeQuestionCard() {
        let call = AgentToolCall(
            id: "ask",
            name: "AskQuestion",
            inputJSON: #"{"question":"请选择优化范围","options":["全部","只改 UI"]}"#
        )

        let result = InteractivePlanContentDeferrer.prepare(
            assistantContent: "我先确认几个选择，然后再给出最终计划。",
            toolCalls: [call]
        )

        XCTAssertTrue(result.suppressVisibleAssistantText)
        XCTAssertEqual(result.visibleIntro, "我先确认几个选择，然后再给出最终计划。")
        XCTAssertNil(result.planMarkdown)
        XCTAssertEqual(result.toolCalls, [call])
    }

    func testPlanModeAskQuestionSuppressesCompanionDraftText() {
        let call = AgentToolCall(
            id: "ask",
            name: "AskQuestion",
            inputJSON: #"{"questions":[{"question":"商品类型是什么？","options":[{"label":"电子产品"},{"label":"服装"}]}]}"#
        )

        let result = InteractivePlanContentDeferrer.prepare(
            assistantContent: "请告诉我几个偏好，我再生成计划。\n\n1. 商品类型是什么？",
            toolCalls: [call],
            runMode: .plan
        )

        XCTAssertTrue(result.suppressVisibleAssistantText)
        XCTAssertNil(result.visibleIntro)
        XCTAssertNil(result.planMarkdown)
        XCTAssertEqual(result.hiddenCompanionText, "请告诉我几个偏好，我再生成计划。\n\n1. 商品类型是什么？")
    }

    func testPlanModeSwitchModeSuppressesIntroAndMovesPlanToConfirmationInput() throws {
        let assistantText = """
        好的，下面是计划。

        ## 实施计划
        1. 读取项目结构。
        2. 修改页面。
        """
        let call = AgentToolCall(id: "switch", name: "SwitchMode", inputJSON: #"{"mode":"agent"}"#)

        let result = InteractivePlanContentDeferrer.prepare(
            assistantContent: assistantText,
            toolCalls: [call],
            runMode: .plan
        )

        XCTAssertTrue(result.suppressVisibleAssistantText)
        XCTAssertNil(result.visibleIntro)
        XCTAssertTrue(result.planMarkdown?.contains("## 实施计划") == true)
        let data = try XCTUnwrap(result.toolCalls.first?.inputJSON.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue((object["assistantPlanMarkdown"] as? String)?.contains("修改页面") == true)
    }

    func testPlanStreamingHoldsContentUntilInteractiveToolDecision() {
        XCTAssertTrue(InteractivePlanContentDeferrer.shouldHoldStreamingContent(
            "## 实施计划\n1. 优化 UI",
            runMode: .plan,
            hasToolCallAccumulator: false
        ))
        XCTAssertTrue(InteractivePlanContentDeferrer.shouldHoldStreamingContent(
            "好的，我先查看项目结构来完善计划。",
            runMode: .plan,
            hasToolCallAccumulator: false
        ))
        XCTAssertFalse(InteractivePlanContentDeferrer.shouldHoldStreamingContent(
            "好的，我先查看项目结构来完善计划。",
            runMode: .plan,
            hasToolCallAccumulator: true
        ))
        XCTAssertTrue(InteractivePlanContentDeferrer.shouldHoldStreamingContent(
            "## Implementation plan\n1. Update the UI",
            runMode: .agent,
            hasToolCallAccumulator: false
        ))
        XCTAssertFalse(InteractivePlanContentDeferrer.shouldHoldStreamingContent(
            "Here is the final summary.",
            runMode: .agent,
            hasToolCallAccumulator: false
        ))
    }

    func testPlanModeSynthesizesIntroForSafeExplorationToolCalls() {
        let readCall = AgentToolCall(
            id: "read",
            name: "Read",
            inputJSON: #"{"file_path":"README.md"}"#
        )
        let writeCall = AgentToolCall(
            id: "write",
            name: "Write",
            inputJSON: #"{"file_path":"README.md","content":"x"}"#
        )
        let shellCall = AgentToolCall(
            id: "shell",
            name: "Shell",
            inputJSON: #"{"command":"date +%Y-%m-%d"}"#
        )

        XCTAssertTrue(PlanModeIntroSynthesizer.intro(for: [readCall], runMode: .plan)?.contains("完善计划") == true)
        XCTAssertTrue(PlanModeIntroSynthesizer.intro(for: [shellCall], runMode: .plan)?.contains("只读命令") == true)
        XCTAssertNil(PlanModeIntroSynthesizer.intro(for: [writeCall], runMode: .plan))
        XCTAssertNil(PlanModeIntroSynthesizer.intro(for: [readCall], runMode: .agent))
    }

    func testPlanModeSafeExplorationKeepsAssistantIntroVisible() {
        let call = AgentToolCall(
            id: "shell",
            name: "Shell",
            inputJSON: #"{"command":"date +%Y-%m-%d"}"#
        )

        let result = InteractivePlanContentDeferrer.prepare(
            assistantContent: "我先看一下当前时间，再整理时钟网页的实现计划。",
            toolCalls: [call],
            runMode: .plan
        )

        XCTAssertFalse(result.suppressVisibleAssistantText)
        XCTAssertNil(result.hiddenCompanionText)
    }

    func testPlanPlainTextQuestionRecoversToAskQuestionCard() throws {
        let context = AgentRunContext(request: agentRequest(runMode: .plan))
        let text = """
        我需要先确认几个问题：

        1. 商品类型是什么？
        - 电子产品
        - 服装

        2. 网站风格偏好？
        - 简洁现代
        - 高端奢华
        """

        guard case .askQuestion(let call) = PlanTurnRecoveryClassifier.recovery(for: text, context: context) else {
            return XCTFail("Plain text questions should recover to AskQuestion.")
        }

        XCTAssertEqual(call.name, "AskQuestion")
        let data = try XCTUnwrap(call.inputJSON.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["recoveredFromPlainText"] as? Bool, true)
        let questions = try XCTUnwrap(object["questions"] as? [[String: Any]])
        XCTAssertEqual(questions.count, 2)
        XCTAssertEqual(questions.first?["question"] as? String, "商品类型是什么？")
        XCTAssertEqual((questions.first?["options"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual((questions.last?["options"] as? [[String: Any]])?.count, 2)
    }

    func testPlanPlainTextCalendarQuestionRecoversToFourChoiceQuestions() throws {
        let context = AgentRunContext(request: agentRequest(runMode: .plan))
        let text = """
        请告诉我你的偏好，我来帮你创建一个漂亮的日历网站。
        1. **日历的功能需求？**
        """

        guard case .askQuestion(let call) = PlanTurnRecoveryClassifier.recovery(for: text, context: context) else {
            return XCTFail("Calendar planning text should recover to AskQuestion.")
        }

        let data = try XCTUnwrap(call.inputJSON.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let questions = try XCTUnwrap(object["questions"] as? [[String: Any]])
        XCTAssertEqual(questions.count, 4)
        XCTAssertEqual(questions.first?["question"] as? String, "日历的功能侧重是什么？")
        for question in questions {
            let options = try XCTUnwrap(question["options"] as? [[String: Any]])
            XCTAssertFalse(options.isEmpty)
            XCTAssertFalse(((question["question"] as? String) ?? "").contains("*"))
        }
    }

    func testPlanPlainTextPlanRecoversToSwitchModeConfirmation() throws {
        let context = AgentRunContext(request: agentRequest(runMode: .plan, permissionMode: .bypassPermissions))
        context.planQuestionAnswered = true
        let text = """
        ## 实施计划
        1. 读取现有 HTML/CSS/JS 文件结构。
        2. 创建日历页面并补齐交互逻辑。
        3. 验证页面可以打开并总结结果。
        """

        guard case .switchMode(let call) = PlanTurnRecoveryClassifier.recovery(for: text, context: context) else {
            return XCTFail("Plain text plans should recover to SwitchMode.")
        }

        let data = try XCTUnwrap(call.inputJSON.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(call.name, "SwitchMode")
        XCTAssertEqual(object["mode"] as? String, "agent")
        XCTAssertEqual(object["recoveredFromPlainText"] as? Bool, true)
        XCTAssertTrue((object["plan"] as? String)?.contains("创建日历页面") == true)

        if case .ask = AgentPermissionPolicy.policy(for: call, context: context) {
            // Recovered plain-text plans should still show the confirmation card instead of getting stuck
            // behind the missing AskQuestion protocol requirement.
        } else {
            XCTFail("Recovered SwitchMode plan should ask for confirmation.")
        }
    }

    func testPlanPlainTextPlanBeforeQuestionRecoversToAskQuestion() throws {
        let context = AgentRunContext(request: agentRequest(runMode: .plan, permissionMode: .bypassPermissions))
        let text = """
        ## 实施计划
        1. 创建日历页面。
        2. 验证页面。
        """

        guard case .askQuestion(let call) = PlanTurnRecoveryClassifier.recovery(for: text, context: context) else {
            return XCTFail("Plan mode must ask questions before plan confirmation.")
        }

        let payload = try XCTUnwrap(AgentInteractivePayload.askUserQuestion(from: call.inputJSON))
        XCTAssertFalse(payload.questions.isEmpty)
    }

    func testPlanModeAllowsReadOnlyShellAndSoftBlocksWriteShell() {
        let context = AgentRunContext(request: agentRequest(runMode: .plan, permissionMode: .default))

        XCTAssertEqual(
            AgentPermissionPolicy.policy(
                for: AgentToolCall(id: "date", name: "Shell", inputJSON: #"{"command":"date +%Y-%m-%d"}"#),
                context: context
            ),
            .allow
        )
        XCTAssertEqual(
            AgentPermissionPolicy.policy(
                for: AgentToolCall(id: "git-show", name: "Shell", inputJSON: #"{"command":"git show --stat HEAD"}"#),
                context: context
            ),
            .allow
        )
        if case .block(let reason) = AgentPermissionPolicy.policy(
            for: AgentToolCall(id: "touch", name: "Shell", inputJSON: #"{"command":"touch index.html"}"#),
            context: context
        ) {
            XCTAssertTrue(reason.contains("Plan mode skipped"))
        } else {
            XCTFail("Write-capable Shell must be soft-blocked in Plan mode.")
        }
    }

    func testAskQuestionResultUsesPilotDeckStyleAnswerHint() {
        let call = AgentToolCall(
            id: "ask",
            name: "AskQuestion",
            inputJSON: #"{"questions":[{"question":"商品类型是什么？","options":[{"label":"电子产品"},{"label":"服装"}]}]}"#
        )
        let result = AgentToolExecutor.askUserQuestionResult(
            call: call,
            updatedInputJSON: #"{"answers":{"商品类型是什么？":"电子产品"}}"#
        )

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("User has answered your questions"))
        XCTAssertTrue(result.output.contains(#""商品类型是什么？"="电子产品""#))
        XCTAssertFalse(result.output.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"))
    }

    func testPlanWorkflowPresentationStatusesMatchInteractiveStages() {
        let ask = AgentToolCall(id: "ask", name: "AskQuestion", inputJSON: "{}")
        let read = AgentToolCall(id: "read", name: "Read", inputJSON: #"{"file_path":"README.md"}"#)
        let switchMode = AgentToolCall(id: "switch", name: "SwitchMode", inputJSON: #"{"mode":"agent","plan":"Do it"}"#)

        XCTAssertEqual(
            PlanWorkflowPresentation.generationStatus(for: [ask], runMode: .plan),
            PlanWorkflowPresentation.generatingQuestionStatus
        )
        XCTAssertEqual(
            PlanWorkflowPresentation.generationStatus(for: [read], runMode: .plan),
            PlanWorkflowPresentation.collectingContextStatus
        )
        XCTAssertEqual(
            PlanWorkflowPresentation.generationStatus(for: [switchMode], runMode: .plan),
            PlanWorkflowPresentation.generatingPlanStatus
        )
        XCTAssertEqual(
            PlanWorkflowPresentation.waitingStatus(for: "AskQuestion", runMode: .plan),
            PlanWorkflowPresentation.waitingForAnswerStatus
        )
        XCTAssertNil(PlanWorkflowPresentation.generationStatus(for: [ask], runMode: .agent))
    }

    func testInteractivePermissionActivitiesDoNotExpandRawDetailsByDefault() {
        XCTAssertFalse(AgentActivityPresentationPolicy.expandsPermissionByDefault(.askUserQuestion))
        XCTAssertFalse(AgentActivityPresentationPolicy.expandsPermissionByDefault(.exitPlanMode))
    }

    func testSwitchModeCanStayInPlanForRevisionFeedback() async {
        let context = AgentRunContext(request: agentRequest(runMode: .plan))
        let call = AgentToolCall(
            id: "switch-refine",
            name: "SwitchMode",
            inputJSON: #"{"mode":"plan","userFeedback":"Add rollback steps before executing."}"#
        )

        let result = await NativeToolRouter.execute(call: call, context: context)

        XCTAssertFalse(result.isError)
        XCTAssertEqual(context.runMode, .plan)
        XCTAssertFalse(context.planExited)
        XCTAssertTrue(result.output.contains("Stay in Plan mode"))
        XCTAssertTrue(result.output.contains("rollback"))
    }

    func testNestedTaskIsRejectedAtMaxSubagentDepth() async {
        let context = AgentRunContext(request: agentRequest(nativeConfigValues: ["runtime.maxSubagentDepth": "1"]))
        context.subagentDepth = 1
        let call = AgentToolCall(
            id: "nested-task",
            name: "Task",
            inputJSON: #"{"prompt":"Explore nested work","type":"explore"}"#
        )

        let result = await NativeToolRouter.execute(call: call, context: context)

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("subagent_depth_exceeded"))
    }

    func testNativeAttachmentResolverBuildsMultimodalContentParts() throws {
        let root = try makeAgentWorkspace("attachments")
        defer { try? FileManager.default.removeItem(at: root) }
        let textURL = root.appendingPathComponent("notes.txt")
        let imageURL = root.appendingPathComponent("pixel.png")
        let pdfURL = root.appendingPathComponent("sample.pdf")
        try "Use this text attachment.".write(to: textURL, atomically: true, encoding: .utf8)
        try writeTinyPNG(to: imageURL)
        try writeMinimalPDF(to: pdfURL)

        let (parts, diagnostics) = NativeAttachmentResolver.openAIContentParts(for: [
            FileAttachment(id: UUID(), fileName: "notes.txt", path: textURL.path, mimeType: "text/plain"),
            FileAttachment(id: UUID(), fileName: "pixel.png", path: imageURL.path, mimeType: "image/png"),
            FileAttachment(id: UUID(), fileName: "sample.pdf", path: pdfURL.path, mimeType: "application/pdf"),
        ])

        XCTAssertTrue(parts.contains { ($0["type"] as? String) == "image_url" })
        XCTAssertTrue(parts.contains { (($0["text"] as? String) ?? "").contains("Use this text attachment.") })
        XCTAssertTrue(parts.contains { (($0["text"] as? String) ?? "").contains("Page 1") })
        XCTAssertTrue(diagnostics.contains { $0.message.contains("multimodal") })
    }

    func testNativeContextBudgetCompactsLongToolResultsAndReportsLevels() {
        var messages: [[String: Any]] = [
            ["role": "system", "content": "system"],
            ["role": "user", "content": "start"],
        ]
        for toolIndex in 0..<5 {
            let id = "tool-\(toolIndex)"
            messages.append(["role": "assistant", "content": NSNull(), "tool_calls": [
                ["id": id, "type": "function", "function": ["name": "Read", "arguments": "{}"]],
            ]])
            messages.append([
                "role": "tool",
                "tool_call_id": id,
                "content": toolIndex == 0 ? String(repeating: "x", count: 24_000) : "small result \(toolIndex)",
            ])
        }
        for index in 0..<8 {
            messages.append(["role": index.isMultiple(of: 2) ? "assistant" : "user", "content": "message \(index)"])
        }

        let before = NativeContextBudget.snapshot(messages: messages, contextWindow: 3_000)
        let compaction = NativeContextBudget.compactIfNeeded(messages: messages, contextWindow: 3_000)

        XCTAssertEqual(before.level, .recovering)
        XCTAssertNotNil(compaction)
        XCTAssertLessThan(compaction?.postTokens ?? Int.max, compaction?.preTokens ?? 0)
        XCTAssertTrue(String(describing: compaction?.messages ?? []).contains("microcompacted"))
    }

    func testToolInvocationPresentationRendersShellRawFallbackAndCommonFields() {
        let presentation = ToolInvocationPresentation.parse(
            toolName: "bash",
            inputJSON: #"{"command":"sed -n '1,20p' README.md\nrg -n \"ChatView\" .","description":"Inspect UI"}"#
        )

        XCTAssertEqual(presentation.toolName, "Shell")
        XCTAssertEqual(presentation.title, "Shell")
        XCTAssertEqual(presentation.command, "sed -n '1,20p' README.md\nrg -n \"ChatView\" .")
        XCTAssertTrue(presentation.parsed)
        XCTAssertEqual(presentation.primaryValue, presentation.command)
        let target = ToolInvocationPresentation.target(toolName: "Shell", inputJSON: presentation.rawInput, limit: 80)
        XCTAssertEqual(target, "sed -n '1,20p' README.md rg -n \"ChatView\" .")

        let fallback = ToolInvocationPresentation.parse(toolName: "Read", inputJSON: "{path: README.md")

        XCTAssertFalse(fallback.parsed)
        XCTAssertNil(fallback.command)
        XCTAssertEqual(fallback.fields, [
            ToolInvocationField(label: "Raw input", value: "{path: README.md", isPrimary: true),
        ])
        XCTAssertEqual(fallback.primaryValue, "{path: README.md")

        let read = ToolInvocationPresentation.parse(toolName: "Read", inputJSON: #"{"file_path":"/tmp/App.swift","offset":12}"#)
        let grep = ToolInvocationPresentation.parse(toolName: "Grep", inputJSON: #"{"pattern":"ToolInvocation","path":"apps/macos-native"}"#)
        let glob = ToolInvocationPresentation.parse(toolName: "Glob", inputJSON: #"{"pattern":"**/*.swift","path":"apps/macos-native"}"#)
        let task = ToolInvocationPresentation.parse(toolName: "Task", inputJSON: #"{"description":"Inspect tool UI","prompt":"Find process rows","type":"explore"}"#)

        XCTAssertEqual(read.fields.map(\.label), ["Path", "Offset"])
        XCTAssertEqual(read.primaryValue, "/tmp/App.swift")
        XCTAssertEqual(grep.fields.map(\.label), ["Pattern", "Path"])
        XCTAssertEqual(grep.primaryValue, "ToolInvocation")
        XCTAssertEqual(glob.fields.map(\.label), ["Pattern", "Path"])
        XCTAssertEqual(glob.primaryValue, "**/*.swift")
        XCTAssertEqual(task.fields.map(\.label), ["Description", "Prompt", "Type"])
        XCTAssertEqual(task.primaryValue, "Inspect tool UI")
    }

    func testTodoListPresentationParsesSnapshotAndDiff() {
        let firstInput = """
        {"todos":[
          {"id":"1","content":"Create project structure","status":"completed"},
          {"id":"2","content":"Write index.html","status":"in_progress"},
          {"id":"3","content":"Write styles","status":"pending"}
        ]}
        """
        let secondInput = """
        {"todos":[
          {"id":"1","content":"Create project structure","status":"done"},
          {"id":"2","content":"Write index.html","status":"completed"},
          {"id":"3","content":"Write styles","status":"in-progress"},
          {"id":"4","content":"Smoke test","status":"todo"}
        ]}
        """

        let first = TodoListPresentation.parse(toolName: "TodoWrite", inputJSON: firstInput, resultOutput: nil)
        let second = TodoListPresentation.parse(
            toolName: "TodoWrite",
            inputJSON: secondInput,
            resultOutput: nil,
            previous: first?.snapshot
        )

        XCTAssertEqual(first?.snapshot.completedCount, 1)
        XCTAssertEqual(first?.snapshot.inProgressCount, 1)
        XCTAssertEqual(first?.snapshot.pendingCount, 1)
        XCTAssertEqual(second?.snapshot.completedCount, 2)
        XCTAssertEqual(second?.snapshot.inProgressCount, 1)
        XCTAssertEqual(second?.snapshot.pendingCount, 1)
        XCTAssertEqual(second?.snapshot.items.first(where: { $0.id == "1" })?.status, .completed)
        XCTAssertTrue(second?.diff.changedItemKeys.contains("2") == true)
        XCTAssertTrue(second?.diff.completedItemKeys.contains("2") == true)
        XCTAssertTrue(second?.summary(isChinese: true).contains("2 完成") == true)
    }

    func testTodoListPresentationPreservesInputOrderAndContentKeys() {
        let previousInput = """
        {"todos":[
          {"content":"Create project structure","status":"in_progress"},
          {"content":"Write index.html","status":"pending"},
          {"content":"Smoke test","status":"pending"}
        ]}
        """
        let nextInput = """
        {"todos":[
          {"content":"Create project structure","status":"completed"},
          {"content":"Write index.html","status":"in_progress"},
          {"content":"Smoke test","status":"pending"}
        ]}
        """

        let previous = TodoListPresentation.parse(toolName: "TodoWrite", inputJSON: previousInput, resultOutput: nil)
        let next = TodoListPresentation.parse(
            toolName: "TodoWrite",
            inputJSON: nextInput,
            resultOutput: nil,
            previous: previous?.snapshot
        )

        XCTAssertEqual(next?.snapshot.items.map(\.content), [
            "Create project structure",
            "Write index.html",
            "Smoke test",
        ])
        XCTAssertEqual(next?.snapshot.items.map(\.status), [.completed, .inProgress, .pending])
        XCTAssertTrue(next?.diff.completedItemKeys.contains("content:create project structure") == true)
        XCTAssertTrue(next?.diff.changedItemKeys.contains("content:write index.html") == true)
    }

    func testTodoListPresentationParsesTodoReadAndMarkdown() {
        let read = TodoListPresentation.parse(
            toolName: "TodoRead",
            inputJSON: "{}",
            resultOutput: #"[{"content":"Review","status":"completed"},{"content":"Ship","status":"pending"}]"#
        )
        XCTAssertEqual(read?.snapshot.totalCount, 2)
        XCTAssertEqual(read?.snapshot.completedCount, 1)

        let markdown = TodoListPresentation.parse(
            toolName: "TodoWrite",
            inputJSON: #"{"markdown":"- [x] Done\n- [ ] Current\n- [ ] Later"}"#,
            resultOutput: nil
        )
        XCTAssertEqual(markdown?.snapshot.completedCount, 1)
        XCTAssertEqual(markdown?.snapshot.inProgressCount, 1)
        XCTAssertEqual(markdown?.snapshot.pendingCount, 1)
    }

    func testTodoWriteDetailIgnoresToolResultHistory() {
        let input = #"{"todos":[{"content":"Create structure","status":"completed"},{"content":"Write CSS","status":"in_progress"}]}"#
        let pollutedResult = """
        Updated todo list.
        Read 1: <html>...
        {"file_path":"calendar/index.html"}
        Searched for **/*
        """

        let presentation = ToolDetailPresentation.todoList(
            toolName: "TodoWrite",
            inputJSON: input,
            resultOutput: pollutedResult
        )

        XCTAssertEqual(presentation?.snapshot.items.map(\.content), ["Create structure", "Write CSS"])
        XCTAssertEqual(presentation?.snapshot.completedCount, 1)
        XCTAssertEqual(presentation?.snapshot.inProgressCount, 1)
        XCTAssertFalse(presentation?.snapshot.items.map(\.content).contains(where: { $0.contains("Read 1") }) == true)
        XCTAssertFalse(presentation?.snapshot.items.map(\.content).contains(where: { $0.contains("Searched") }) == true)
    }

    func testLiveStatusPresentationDoesNotExposeRunHistoryForTodo() {
        let date = Date()
        let read = AgentActivity(
            id: "read",
            sessionId: "session",
            title: "Read",
            detail: "Read 1: <html>...",
            phase: .tool,
            state: .completed,
            createdAt: date,
            updatedAt: date,
            toolName: "Read",
            detailMessages: ["Read 1: <html>..."]
        )
        let grep = AgentActivity(
            id: "grep",
            sessionId: "session",
            title: "Grep",
            detail: "Searched for **/*",
            phase: .search,
            state: .completed,
            createdAt: date.addingTimeInterval(1),
            updatedAt: date.addingTimeInterval(1),
            toolName: "Grep",
            detailMessages: ["Searched for **/*"]
        )
        let todo = AgentActivity(
            id: "todo",
            sessionId: "session",
            title: "Running TodoWrite",
            detail: #"{"todos":[{"content":"Write CSS","status":"in_progress"}]}"#,
            phase: .todo,
            state: .running,
            createdAt: date.addingTimeInterval(2),
            updatedAt: date.addingTimeInterval(2),
            toolName: "TodoWrite",
            detailMessages: [#"{"todos":[{"content":"Write CSS","status":"in_progress"}]}"#]
        )

        let presentation = ProcessTracePresentation.make(activities: [read, grep, todo], isChinese: true)

        XCTAssertTrue(presentation.shouldRender)
        XCTAssertEqual(presentation.detailRows, [])
        XCTAssertTrue(presentation.summaryText.contains("Todo"))
    }

    func testLiveStatusPresentationOnlyUsesCurrentToolDetail() {
        let date = Date()
        let previousWrite = AgentActivity(
            id: "write",
            sessionId: "session",
            title: "Write",
            detail: "Wrote calendar/index.html",
            phase: .edit,
            state: .completed,
            createdAt: date,
            updatedAt: date,
            toolName: "Write",
            detailMessages: ["Wrote calendar/index.html"]
        )
        let runningRead = AgentActivity(
            id: "read",
            sessionId: "session",
            title: "Running Read",
            detail: #"{"file_path":"calendar/js/app.js"}"#,
            phase: .tool,
            state: .running,
            createdAt: date.addingTimeInterval(1),
            updatedAt: date.addingTimeInterval(1),
            toolName: "Read",
            detailMessages: [#"{"file_path":"calendar/js/app.js"}"#]
        )

        let presentation = ProcessTracePresentation.make(activities: [previousWrite, runningRead], isChinese: true)
        let combined = presentation.detailRows.map { "\($0.title) \($0.detail)" }.joined(separator: "\n")

        XCTAssertEqual(presentation.detailRows.count, 1)
        XCTAssertTrue(combined.contains("calendar/js/app.js"))
        XCTAssertFalse(combined.contains("calendar/index.html"))
    }

    func testTodoAndTaskAreBoundaryProcessTools() {
        XCTAssertTrue(ProcessToolGroupingPolicy.isBoundaryProcessTool("TodoWrite"))
        XCTAssertTrue(ProcessToolGroupingPolicy.isBoundaryProcessTool("todo_read"))
        XCTAssertTrue(ProcessToolGroupingPolicy.isBoundaryProcessTool("Task"))
        XCTAssertFalse(ProcessToolGroupingPolicy.isBoundaryProcessTool("Read"))
        XCTAssertFalse(ProcessToolGroupingPolicy.isBoundaryProcessTool("Write"))
    }

    func testToolOutputPreviewLimiterTruncatesLargeToolOutput() {
        let output = (0..<120).map { "line \($0)" }.joined(separator: "\n")
        let preview = ToolOutputPreviewLimiter.preview(output, maxChars: 500, maxLines: 20)

        XCTAssertTrue(preview.contains("line 0"))
        XCTAssertTrue(preview.contains("output truncated"))
        XCTAssertFalse(preview.contains("line 119"))
    }

    func testPlanTodoExecutionGateRequiresInitializationAndRefresh() {
        let context = AgentRunContext(request: agentRequest(runMode: .agent, permissionMode: .bypassPermissions))
        context.planExecutionApproved = true
        context.todoRequiresInitialization = true
        let write = AgentToolCall(id: "write", name: "Write", inputJSON: #"{"file_path":"index.html","content":"hi"}"#)

        let initialBlock = PlanTodoExecutionGate.blockingResult(for: write, context: context)
        XCTAssertEqual(initialBlock?.isPolicyBlock, true)
        XCTAssertEqual(initialBlock?.isError, false)

        let todo = AgentToolCall(id: "todo", name: "TodoWrite", inputJSON: #"{"todos":[{"content":"Write file","status":"in_progress"}]}"#)
        context.recordToolResult(
            AgentToolResult(callId: "todo", toolName: "TodoWrite", output: "ok", isError: false),
            call: todo
        )
        XCTAssertNil(PlanTodoExecutionGate.blockingResult(for: write, context: context))

        context.recordToolResult(
            AgentToolResult(callId: "write", toolName: "Write", output: "Wrote index.html", isError: false),
            call: write
        )
        XCTAssertTrue(context.todoRequiresRefresh)
        XCTAssertEqual(PlanTodoExecutionGate.blockingResult(for: write, context: context)?.isPolicyBlock, true)
    }

    func testRootGlobExecutionPolicyCachesRepeatedRootDiscovery() {
        let context = AgentRunContext(request: agentRequest(permissionMode: .bypassPermissions))
        let rootGlob = AgentToolCall(id: "glob", name: "Glob", inputJSON: #"{"pattern":"**/*","path":"."}"#)
        let targetedGlob = AgentToolCall(id: "targeted", name: "Glob", inputJSON: #"{"pattern":"**/*.swift","path":"."}"#)

        XCTAssertTrue(RootGlobExecutionPolicy.isRootWorkspaceGlob(inputJSON: rootGlob.inputJSON))
        XCTAssertNil(RootGlobExecutionPolicy.cachedResultIfAvailable(call: rootGlob, context: context))
        _ = RootGlobExecutionPolicy.recordIfRootGlob(call: rootGlob, output: "index.html\nsrc/app.js", context: context)

        let cached = RootGlobExecutionPolicy.cachedResultIfAvailable(call: rootGlob, context: context)
        XCTAssertEqual(cached?.isError, false)
        XCTAssertTrue(cached?.output.contains("Cached workspace discovery") == true)
        XCTAssertNil(RootGlobExecutionPolicy.cachedResultIfAvailable(call: targetedGlob, context: context))
    }

    func testNativeContextBudgetPreservesToolPairIntegrity() {
        let messages: [[String: Any]] = [
            ["role": "assistant", "content": NSNull(), "tool_calls": [
                ["id": "paired", "type": "function", "function": ["name": "Read", "arguments": "{}"]],
                ["id": "dangling-call", "type": "function", "function": ["name": "Read", "arguments": "{}"]],
            ]],
            ["role": "tool", "tool_call_id": "paired", "content": "ok"],
            ["role": "tool", "tool_call_id": "dangling-result", "content": "orphan"],
        ]

        let preserved = NativeContextBudget.preserveToolPairIntegrity(messages)
        let serialized = String(describing: preserved)

        XCTAssertTrue(serialized.contains("paired"))
        XCTAssertFalse(serialized.contains("dangling-call"))
        XCTAssertFalse(serialized.contains("dangling-result"))
    }

    func testTaskInvocationPresentationShowsSubagentDetails() {
        let presentation = TaskInvocationPresentation.parse(
            inputJSON: #"{"type":"explore","description":"Inspect calendar files","prompt":"Find current implementation","cwd":"calendar"}"#
        )

        XCTAssertEqual(presentation?.type, "explore")
        XCTAssertEqual(presentation?.description, "Inspect calendar files")
        XCTAssertEqual(presentation?.prompt, "Find current implementation")
        XCTAssertEqual(presentation?.cwd, "calendar")
        XCTAssertTrue(presentation?.rowTitle(isChinese: true, running: true, failed: false).contains("子 Agent / explore") == true)
    }

    @MainActor
    func testSelectingProjectDoesNotShowDraftSession() {
        let state = AppState()
        let project = state.projects[0]
        state.startDraftSession(project: project)
        XCTAssertTrue(state.isDraftSessionVisible)

        state.selectProject(project)

        XCTAssertFalse(state.isDraftSessionVisible)
        XCTAssertNil(state.selectedSessionID)
    }

    func testProcessTraceFiltersByAssistantAnchor() {
        let date = Date()
        let first = AgentActivity(
            id: "first",
            sessionId: "session",
            title: "Read",
            detail: "index.html",
            phase: .tool,
            state: .completed,
            createdAt: date,
            updatedAt: date,
            toolName: "Read",
            anchorBlockID: "assistant-1"
        )
        let second = AgentActivity(
            id: "second",
            sessionId: "session",
            title: "Grep",
            detail: "pattern",
            phase: .search,
            state: .running,
            createdAt: date.addingTimeInterval(1),
            updatedAt: date.addingTimeInterval(1),
            toolName: "Grep",
            anchorBlockID: "assistant-2"
        )

        let filtered = AgentActivity.processTraceActivities([first, second], anchoredTo: "assistant-2")

        XCTAssertEqual(filtered.map(\.id), ["second"])
    }

    func testChatScrollPinningStateDetachesAndRepinsByBottomGap() {
        var pinning = ChatScrollPinningState()
        XCTAssertTrue(pinning.shouldFollowOutput)

        pinning.update(bottomY: 480, viewportHeight: 320)
        XCTAssertTrue(pinning.shouldFollowOutput)

        pinning.recordUserScroll(deltaY: 24)
        XCTAssertFalse(pinning.shouldFollowOutput)

        pinning.update(bottomY: 480, viewportHeight: 320)
        XCTAssertFalse(pinning.shouldFollowOutput)

        pinning.update(bottomY: 336, viewportHeight: 320)
        XCTAssertTrue(pinning.shouldFollowOutput)

        let now = Date()
        pinning.recordProgrammaticScroll(now: now)
        pinning.update(bottomY: 360, viewportHeight: 320, now: now.addingTimeInterval(0.10))
        XCTAssertTrue(pinning.shouldFollowOutput)

        pinning.update(bottomY: 420, viewportHeight: 320, now: now.addingTimeInterval(0.10))
        XCTAssertTrue(pinning.shouldFollowOutput)
    }

    func testProcessTraceSummaryShowsRunningCommandWithShimmer() {
        let activity = AgentActivity(
            id: "shell",
            sessionId: "session",
            title: "Running Shell",
            detail: #"{"command":"sed -n '1,20p' README.md"}"#,
            phase: .command,
            state: .running,
            createdAt: Date(),
            updatedAt: Date(),
            toolName: "Shell"
        )

        let summary = ProcessTraceSummary.make(activities: [activity], isChinese: true)

        XCTAssertTrue(summary.shouldShimmer)
        XCTAssertEqual(summary.runningActivityID, "shell")
        XCTAssertTrue(summary.text.contains("正在执行"))
        XCTAssertTrue(summary.text.contains("sed -n"))

        let write = AgentActivity(
            id: "write",
            sessionId: "session",
            title: "Running Write",
            detail: #"{"path":"styles.css"}"#,
            phase: .edit,
            state: .running,
            createdAt: Date(),
            updatedAt: Date(),
            toolName: "Write"
        )
        let writeSummary = ProcessTraceSummary.make(activities: [write], isChinese: true)
        XCTAssertTrue(writeSummary.shouldShimmer)
        XCTAssertTrue(writeSummary.text.contains("正在写入"))
        XCTAssertTrue(writeSummary.text.contains("styles.css"))

        let streaming = AgentActivity(
            id: "streaming",
            sessionId: "session",
            title: "正在接收响应",
            detail: "正在流式输出助手回复",
            phase: .status,
            state: .running,
            createdAt: Date(),
            updatedAt: Date(),
            toolName: nil
        )
        let streamingSummary = ProcessTraceSummary.make(activities: [streaming], isChinese: true)
        XCTAssertTrue(streamingSummary.shouldShimmer)
        XCTAssertTrue(streamingSummary.text.contains("正在接收响应"))

        let question = AgentActivity(
            id: "ask",
            sessionId: "session",
            title: "已询问 2 个问题",
            detail: "User has answered your questions.",
            phase: .status,
            state: .completed,
            createdAt: Date(),
            updatedAt: Date(),
            toolName: "AskQuestion",
            detailMessages: ["questions_count=2"]
        )
        let questionSummary = ProcessTraceSummary.make(activities: [question], isChinese: true)
        XCTAssertFalse(questionSummary.shouldShimmer)
        XCTAssertTrue(questionSummary.text.contains("已询问 2 个问题"))

        let todo = AgentActivity(
            id: "todo",
            sessionId: "session",
            title: "Running TodoWrite",
            detail: #"{"todos":[{"content":"Ship","status":"in_progress"}]}"#,
            phase: .todo,
            state: .running,
            createdAt: Date(),
            updatedAt: Date(),
            toolName: "TodoWrite"
        )
        let todoSummary = ProcessTraceSummary.make(activities: [todo], isChinese: true)
        XCTAssertTrue(todoSummary.shouldShimmer)
        XCTAssertTrue(todoSummary.text.contains("正在更新 Todo List"))
    }

    func testAgentLoopWatchdogUsesProgressNotFixedIterationLimit() {
        var watchdog = AgentLoopWatchdog()
        for _ in 0..<(AgentLoopWatchdog.maxDuplicateOnlyTurns - 1) {
            XCTAssertEqual(
                watchdog.recordDuplicateOnlyTurn(),
                .continueWithNudge("""
                The previous tool request was a duplicate and was skipped. Do not repeat the exact same tool call.
                Inspect the current file state if needed, update TodoWrite for real progress changes, or continue with the next distinct implementation or verification step.
                """)
            )
        }
        if case .pauseNeedsUser(let message) = watchdog.recordDuplicateOnlyTurn() {
            XCTAssertTrue(message.contains("repeated the same tool request"))
        } else {
            XCTFail("Expected duplicate-only watchdog to pause without throwing a transport error.")
        }

        watchdog.recordProgress()
        for _ in 0..<(AgentLoopWatchdog.maxDuplicateOnlyTurns - 1) {
            if case .continueWithNudge = watchdog.recordDuplicateOnlyTurn() {
                XCTAssertTrue(true)
            } else {
                XCTFail("Expected duplicate-only watchdog to continue before the pause threshold.")
            }
        }

        var errorWatchdog = AgentLoopWatchdog()
        let result = AgentToolResult(callId: "1", toolName: "Shell", output: "same failure", isError: true)
        XCTAssertNil(errorWatchdog.recordToolResult(result))
        XCTAssertNil(errorWatchdog.recordToolResult(result))
        XCTAssertNotNil(errorWatchdog.recordToolResult(result))
        XCTAssertNil(errorWatchdog.recordToolResult(AgentToolResult(callId: "policy", toolName: "Shell", output: "Plan mode skipped this write-capable shell command.", isError: false, isPolicyBlock: true)))
        XCTAssertNil(errorWatchdog.recordToolResult(AgentToolResult(callId: "2", toolName: "Shell", output: "ok", isError: false)))
    }

    @MainActor
    func testComposerRunModeStaysPlanAfterSendUntilPlanDecision() {
        let state = AppState()
        state.composerRunMode = .plan

        let requested = state.consumeComposerRunModeForSend()

        XCTAssertEqual(requested, .plan)
        XCTAssertEqual(state.composerRunMode, .plan)

        let refineID = UUID()
        state.pendingPermissions = [
            PermissionRequest(
                id: refineID,
                sessionId: "session",
                toolName: "SwitchMode",
                inputJSON: #"{"mode":"agent","plan":"Ship it."}"#,
                reason: "Plan approval is required before leaving Plan mode.",
                scope: .session,
                createdAt: Date(),
                kind: .exitPlanMode
            ),
        ]
        state.approvePermission(refineID, updatedInputJSON: #"{"mode":"plan","userFeedback":"revise"}"#)
        XCTAssertEqual(state.composerRunMode, .plan)

        let executeID = UUID()
        state.pendingPermissions = [
            PermissionRequest(
                id: executeID,
                sessionId: "session",
                toolName: "SwitchMode",
                inputJSON: #"{"mode":"agent","plan":"Ship it."}"#,
                reason: "Plan approval is required before leaving Plan mode.",
                scope: .session,
                createdAt: Date(),
                kind: .exitPlanMode
            ),
        ]
        state.approvePermission(executeID, updatedInputJSON: #"{"mode":"agent","plan":"Ship it."}"#)

        XCTAssertEqual(state.composerRunMode, .agent)
    }

    func testSkillToolPlanPolicyRemainsAvailableForLegacyFallbacks() {
        let tools = NativeToolRouter.openAITools()
        let names = tools.compactMap { tool -> String? in
            guard let function = tool["function"] as? [String: Any] else { return nil }
            return function["name"] as? String
        }
        XCTAssertTrue(names.contains("Skill"))

        let context = AgentRunContext(request: agentRequest(runMode: .plan))
        let call = AgentToolCall(
            id: "call-skill",
            name: "Skill",
            inputJSON: #"{"skill":"9gclaw-rag:glm-web-search","args":"weather"}"#
        )
        XCTAssertEqual(NativeToolRouter.permissionPolicy(for: call, context: context), .allow)
    }

    func testLowercaseSkillToolNameIsCanonicalizedBeforeExecution() async throws {
        let request = agentRequest(
            nativeConfigValues: [
                "rag.enabled": "true",
                "rag.glmWebSearch.baseUrl": "https://api.z.ai/api/paas/v4/web_search",
                "rag.glmWebSearch.apiKey": "test-rag-key",
            ]
        )
        let context = AgentRunContext(request: request)
        let call = AgentToolCall(
            id: "call-lowercase-skill",
            name: "skill",
            inputJSON: #"{"skill":"9gclaw-rag:rag-research","args":"DARPA autonomous systems"}"#
        )

        let result = await NativeToolRouter.execute(call: call, context: context)

        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.toolName, "Skill")
        XCTAssertTrue(result.output.contains("9gclaw-rag:rag-research"))
        XCTAssertTrue(context.invokedSkills.contains("9gclaw-rag:rag-research"))
    }

    func testShellInputAliasIsCanonicalizedToCommand() {
        let call = AgentToolCall(
            id: "call-bash-input",
            name: "bash",
            inputJSON: #"{"input":"python3 scripts/local_knowledge_search.py --query \"DARPA\"","timeout_seconds":30}"#
        )

        let normalized = ToolArgumentNormalizer.normalize(call)

        XCTAssertNil(normalized.recoveryResult)
        XCTAssertEqual(normalized.call.name, "Shell")
        let object = try? JSONSerialization.jsonObject(with: Data(normalized.call.inputJSON.utf8)) as? [String: Any]
        XCTAssertEqual(object?["command"] as? String, #"python3 scripts/local_knowledge_search.py --query "DARPA""#)
        XCTAssertFalse(normalized.call.inputJSON.contains(#""input":"#))
    }

    func testShellXMLParameterWrapperIsRemovedFromCommand() {
        let call = AgentToolCall(
            id: "call-bash-xml",
            name: "Shell",
            inputJSON: #"{"command":"<parameter>\npython3 ${CLAUDE_PLUGIN_ROOT}/scripts/local_knowledge_search.py --query \"DARPA autonomous systems research\""}"#
        )

        let normalized = ToolArgumentNormalizer.normalize(call)

        XCTAssertNil(normalized.recoveryResult)
        let object = try? JSONSerialization.jsonObject(with: Data(normalized.call.inputJSON.utf8)) as? [String: Any]
        XCTAssertEqual(
            object?["command"] as? String,
            #"python3 ${CLAUDE_PLUGIN_ROOT}/scripts/local_knowledge_search.py --query "DARPA autonomous systems research""#
        )
    }

    func testSkillRuntimeLoadsBundledRAGSkillAndInjectsEnvironment() throws {
        let request = agentRequest(
            nativeConfigValues: [
                "rag.enabled": "true",
                "rag.glmWebSearch.baseUrl": "https://api.z.ai/api/paas/v4/web_search",
                "rag.glmWebSearch.apiKey": "test-rag-key",
                "rag.glmWebSearch.defaultTopK": "10",
            ]
        )
        let context = AgentRunContext(request: request)
        let output = try SkillRuntimeService.load(
            inputJSON: #"{"skill":"9gclaw-rag:glm-web-search","args":"Beijing weather"}"#,
            context: context
        )

        XCTAssertTrue(output.contains("9gclaw-rag:glm-web-search"))
        XCTAssertTrue(output.contains("glm_web_search.py"))
        XCTAssertTrue(context.invokedSkills.contains("9gclaw-rag:glm-web-search"))

        let environment = SkillRuntimeService.environment(configValues: request.nativeConfigValues)
        XCTAssertEqual(environment["EDGECLAW_RAG_ENABLED"], "true")
        XCTAssertEqual(environment["EDGECLAW_RAG_GLM_WEB_SEARCH_API_KEY"], "test-rag-key")
        XCTAssertNotNil(environment["CLAUDE_PLUGIN_ROOT"])
    }

    func testBundledRAGPluginResourceIsPackaged() throws {
        let resources = try XCTUnwrap(Bundle.main.resourceURL)
        let skillFile = resources
            .appendingPathComponent("edgeclaw-rag-plugin", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("glm-web-search", isDirectory: true)
            .appendingPathComponent("SKILL.md")

        XCTAssertTrue(FileManager.default.fileExists(atPath: skillFile.path))
    }

    func testRouterChoosesTierModelWithoutDARPAHardcoding() {
        let yaml = """
        models:
          providers:
            edgeclaw:
              type: openai-chat
              baseUrl: http://example.local/v1
              apiKey: test
          entries:
            default:
              provider: edgeclaw
              name: qwen3.6-27b
            router_small:
              provider: edgeclaw
              name: qwen3.6-35b-a3b
        router:
          enabled: true
          routes:
            default:
              model: default
          tokenSaver:
            tiers:
              SIMPLE:
                model: router_small
              MEDIUM:
                model: router_small
              COMPLEX:
                model: default
        """
        let values = NativeConfigService.scalarMap(from: yaml)
        XCTAssertEqual(NativeRouterRuntime.entryID(forTier: "SIMPLE", values: values), "router_small")
        XCTAssertFalse(values.keys.contains { $0.lowercased().contains("darpa") })
    }

    func testRoutingDashboardSessionKeepsStructuredRouteTraceAndLegacyCompatibility() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let legacyJSON = """
        {
          "id": "legacy-session",
          "title": "Legacy routing",
          "projectName": "general",
          "lastActiveAt": "2026-05-17T08:00:00Z",
          "totalTokens": 5120,
          "estimatedCost": 0.004,
          "savedCost": 0.002,
          "byTier": {
            "SIMPLE": { "count": 1, "totalTokens": 5120 }
          },
          "byModel": {
            "qwen3.6-35b-a3b": { "count": 1, "totalTokens": 5120 }
          },
          "requestLog": [
            "16:00:00 default -> qwen3.6-35b-a3b routed as SIMPLE",
            "16:00:01 qwen3.6-35b-a3b usage · SIMPLE · 5120/160000 tokens"
          ]
        }
        """

        let legacy = try decoder.decode(RoutingDashboardSession.self, from: Data(legacyJSON.utf8))

        XCTAssertEqual(legacy.total.totalTokens, 5120)
        XCTAssertEqual(legacy.total.estimatedCost, 0.004)
        XCTAssertEqual(legacy.total.savedCost, 0.002)
        XCTAssertEqual(legacy.requestLog.count, 2)
        XCTAssertTrue(legacy.requestEntries.isEmpty)

        let structuredJSON = """
        {
          "id": "structured-session",
          "title": "Weather site",
          "projectName": "general",
          "lastActiveAt": "2026-05-17T08:05:00Z",
          "totalTokens": 12000,
          "estimatedCost": 0.008,
          "savedCost": 0.004,
          "total": {
            "count": 2,
            "requestCount": 2,
            "totalTokens": 12000,
            "estimatedCost": 0.008,
            "baselineCost": 0.012,
            "savedCost": 0.004
          },
          "byTier": {
            "MEDIUM": { "count": 1, "requestCount": 1 }
          },
          "byModel": {
            "qwen3.6-35b-a3b": { "count": 1, "requestCount": 1 },
            "skill:9gclaw-rag:glm-web-search": { "count": 1, "requestCount": 1 }
          },
          "byScenario": {
            "default": { "count": 1, "requestCount": 1 },
            "skill": { "count": 1, "requestCount": 1 }
          },
          "byRole": {
            "main": { "count": 2, "requestCount": 2 }
          },
          "requestLog": [],
          "requestEntries": [
            {
              "id": "route-1",
              "ts": "2026-05-17T08:05:01Z",
              "role": "main",
              "tier": "MEDIUM",
              "model": "qwen3.6-35b-a3b",
              "tokens": 12000,
              "cost": 0.008,
              "baselineCost": 0.012,
              "savedCost": 0.004,
              "query": "Build a weather website",
              "scenario": "default",
              "route": "default"
            },
            {
              "id": "skill-1",
              "ts": "2026-05-17T08:05:02Z",
              "role": "main",
              "model": "skill:9gclaw-rag:glm-web-search",
              "tokens": 0,
              "cost": 0,
              "query": "Skill invoked",
              "scenario": "skill",
              "skill": "9gclaw-rag:glm-web-search"
            }
          ]
        }
        """

        let structured = try decoder.decode(RoutingDashboardSession.self, from: Data(structuredJSON.utf8))

        XCTAssertEqual(structured.requestEntries.count, 2)
        XCTAssertEqual(structured.requestEntries.first?.tier, "MEDIUM")
        XCTAssertEqual(structured.requestEntries.first?.query, "Build a weather website")
        XCTAssertEqual(structured.requestEntries.last?.skill, "9gclaw-rag:glm-web-search")
        XCTAssertEqual(structured.byScenario["skill"]?.requestCount, 1)
        XCTAssertEqual(structured.byRole["main"]?.requestCount, 2)
        XCTAssertEqual(structured.total.baselineCost, 0.012)
    }

    func testMainHeaderToolSwitcherLayoutAlwaysShowsPrimaryTabs() {
        for width in [1440.0, 1100.0, 760.0] {
            let layout = MainHeaderToolSwitcherLayout.resolve(
                availableWidth: width,
                activeTab: .memory
            )

            XCTAssertEqual(layout.visibleTabs, AppTab.primaryTabs)
            XCTAssertTrue(layout.overflowTabs.isEmpty)
            XCTAssertFalse(layout.iconOnly)
            XCTAssertEqual(layout.estimatedWidth, 508)
        }
        XCTAssertEqual(MainHeaderToolSwitcherLayout.buttonWidth(for: .chat, iconOnly: false), 82)
        XCTAssertEqual(MainHeaderToolSwitcherLayout.buttonWidth(for: .chat, iconOnly: true), 36)
    }

    func testCodeEditorPreferencesDefaultToLineNumbersAndMinimapForNewUsers() {
        XCTAssertTrue(CodeEditorPreferences.defaults.lineNumbers)
        XCTAssertTrue(CodeEditorPreferences.defaults.showMinimap)
        XCTAssertTrue(CodeEditorPreferences.defaults.wordWrap)
    }

    func testCodeLineNumberMetricsGrowWithDigitCount() {
        let singleDigit = CodeLineNumberMetrics.rulerWidth(lineCount: 9)
        let doubleDigit = CodeLineNumberMetrics.rulerWidth(lineCount: 99)
        let tripleDigit = CodeLineNumberMetrics.rulerWidth(lineCount: 999)

        XCTAssertEqual(CodeLineNumberMetrics.lineCount(in: ""), 1)
        XCTAssertEqual(CodeLineNumberMetrics.lineCount(in: "one\ntwo\n"), 3)
        XCTAssertEqual(singleDigit, doubleDigit)
        XCTAssertGreaterThan(tripleDigit, doubleDigit)
        XCTAssertEqual(CodeLineNumberMetrics.lineNumber(forCharacterIndex: 0, lineStarts: [0, 4, 8]), 1)
        XCTAssertEqual(CodeLineNumberMetrics.lineNumber(forCharacterIndex: 5, lineStarts: [0, 4, 8]), 2)
    }

    func testCodeMinimapModelSamplesLargeFilesAndTracksViewport() {
        let text = (1...2_400).map { index in
            index.isMultiple(of: 2) ? "    let value\(index) = \(index)" : ""
        }.joined(separator: "\n")

        let model = CodeMinimapModel(text: text, visibleLineRange: 120..<180, maxLines: 600)

        XCTAssertEqual(model.totalLines, 2_400)
        XCTAssertEqual(model.sampleStride, 4)
        XCTAssertLessThanOrEqual(model.lines.count, 600)
        XCTAssertGreaterThan(model.viewportStartFraction, 0.04)
        XCTAssertLessThan(model.viewportStartFraction, 0.06)
        XCTAssertGreaterThan(model.viewportHeightFraction, 0.02)
        XCTAssertTrue(model.lines.contains { !$0.isBlank && $0.indentLevel > 0 })
    }

    func testProjectCreationWizardUsesCompactMetrics() {
        XCTAssertEqual(ProjectCreationWizardMetrics.maxWidth, 612)
        XCTAssertEqual(ProjectCreationWizardMetrics.formMaxWidth, 520)
        XCTAssertEqual(ProjectCreationWizardMetrics.fieldHeight, 36)
        XCTAssertEqual(ProjectCreationWizardMetrics.browseButtonWidth, 44)
        XCTAssertLessThan(ProjectCreationWizardMetrics.maxWidth, 720)
        XCTAssertLessThan(ProjectCreationWizardMetrics.formMaxWidth, ProjectCreationWizardMetrics.maxWidth)
        XCTAssertLessThan(ProjectCreationWizardMetrics.contentMinHeight, 324)
        XCTAssertLessThan(ProjectCreationWizardMetrics.typeCardMinHeight, 132)
        XCTAssertEqual(ProjectCreationWizardMetrics.footerHeight, 54)
    }

    func testPlanConfirmationCardUsesBluePlanAreaAndVerticalChoices() {
        XCTAssertEqual(PlanConfirmationCardMetrics.planMinHeight, 220)
        XCTAssertEqual(PlanConfirmationCardMetrics.planMaxHeight, 460)
        XCTAssertEqual(PlanConfirmationCardMetrics.actionLayout, "execute-feedback-footer")
        XCTAssertEqual(PlanConfirmationCardMetrics.actionRowHeight, 38)
        XCTAssertEqual(PlanConfirmationCardMetrics.footerButtonCount, 2)
        XCTAssertTrue(PlanConfirmationCardMetrics.emptyPlanFallbackZH.contains("同步"))
    }

    func testEditorHeaderToolbarUsesNeutralIconButtons() {
        XCTAssertEqual(EditorHeaderToolbarMetrics.iconButtonSize, 28)
        XCTAssertEqual(EditorHeaderToolbarMetrics.iconFontSize, 13.5)
        XCTAssertFalse(EditorHeaderToolbarMetrics.usesProminentSaveButton)
    }

    func testCodeEditorScrollStabilityMetricsDisableMinimapHitTestingAndThrottleViewport() {
        XCTAssertFalse(CodeEditorScrollStabilityMetrics.minimapAllowsHitTesting)
        XCTAssertTrue(CodeEditorScrollStabilityMetrics.preservesScrollOriginOnUpdate)
        XCTAssertGreaterThanOrEqual(CodeEditorScrollStabilityMetrics.visibleRangePublishInterval, 0.06)
    }

    func testFilePreviewActionPolicyMatchesRequestedPreviewSurface() {
        let html = WorkspaceFile(
            id: "index",
            name: "index.html",
            path: "/tmp/index.html",
            relativePath: "index.html",
            depth: 0,
            isDirectory: false,
            isExpanded: false,
            modifiedAt: nil,
            byteCount: nil
        )
        let markdown = WorkspaceFile(
            id: "readme",
            name: "README.md",
            path: "/tmp/README.md",
            relativePath: "README.md",
            depth: 0,
            isDirectory: false,
            isExpanded: false,
            modifiedAt: nil,
            byteCount: nil
        )
        let pdf = WorkspaceFile(
            id: "paper",
            name: "paper.pdf",
            path: "/tmp/paper.pdf",
            relativePath: "paper.pdf",
            depth: 0,
            isDirectory: false,
            isExpanded: false,
            modifiedAt: nil,
            byteCount: nil
        )

        XCTAssertEqual(FilePreviewActionPolicy.treePreviewIcon(for: html), "globe")
        XCTAssertFalse(FilePreviewActionPolicy.editorShowsHTMLPreview(for: html))
        XCTAssertEqual(FilePreviewActionPolicy.editorPreviewToggleIcon(for: markdown, isPreviewing: false), "doc.richtext")
        XCTAssertEqual(FilePreviewActionPolicy.editorPreviewToggleIcon(for: markdown, isPreviewing: true), "pencil")
        XCTAssertTrue(FilePreviewActionPolicy.usesNativePDFPreview(for: pdf))
        XCTAssertTrue(pdf.isPDF)
    }

    func testProcessToolPresentationClassifierUsesExactCanonicalTools() {
        XCTAssertEqual(AgentToolPresentationClassifier.phase(forToolName: "Task"), .subagent)
        XCTAssertEqual(AgentToolPresentationClassifier.phase(forToolName: "Agent"), .subagent)
        XCTAssertEqual(AgentToolPresentationClassifier.phase(forToolName: "Shell"), .command)
        XCTAssertEqual(AgentToolPresentationClassifier.phase(forToolName: "Glob"), .search)
        XCTAssertEqual(AgentToolPresentationClassifier.phase(forToolName: "SemanticSearch"), .search)
        XCTAssertEqual(AgentToolPresentationClassifier.phase(forToolName: "TodoRead"), .todo)
        XCTAssertEqual(AgentToolPresentationClassifier.phase(forToolName: "TodoWrite"), .todo)
        XCTAssertEqual(AgentToolPresentationClassifier.phase(forToolName: "ReadLints"), .tool)

        let mixedPhases = ["Task", "Shell"].map(AgentToolPresentationClassifier.phase(forToolName:))
        XCTAssertFalse(mixedPhases.contains(.search))
    }

    @MainActor
    func testOpenSettingsStoresInitialTabWithoutShowingOverlay() {
        let state = AppState()

        state.showSettings = false
        state.openSettings(.config)

        XCTAssertEqual(state.settingsInitialTab, .config)
        XCTAssertFalse(state.showSettings)
    }

    private func project(name: String, displayName: String, date: Date) -> WorkspaceProject {
        WorkspaceProject(
            id: UUID(),
            name: name,
            displayName: displayName,
            rootPath: "/Users/tester/\(name)",
            sessions: [],
            codexSessions: [],
            cursorSessions: [],
            geminiSessions: [],
            createdAt: date,
            lastActivity: date
        )
    }

    private func agentRequest(
        projectPath: String = NSTemporaryDirectory(),
        prompt: String = "test",
        runMode: ChatRunMode = .agent,
        permissionMode: ComposerPermissionMode = .default,
        toolSettings: ToolPermissionSettings = .defaults,
        nativeConfigValues: [String: String] = [:]
    ) -> AgentRequest {
        AgentRequest(
            sessionId: "test-session",
            projectPath: projectPath,
            prompt: prompt,
            providerConfig: ProviderConfig(
                provider: .nineGClaw,
                apiType: .openAIChat,
                baseURL: "http://example.local/v1",
                model: "qwen3.6-27b",
                secretAccount: "test",
                headers: [:]
            ),
            apiKey: "test-key",
            priorMessages: [],
            timeoutMs: 1_000,
            contextWindow: 160_000,
            permissionMode: permissionMode,
            runMode: runMode,
            workspaceContext: nil,
            toolSettings: toolSettings,
            routerRoute: "default",
            nativeConfigValues: nativeConfigValues,
            permissionHandler: nil
        )
    }

    private func makeAgentWorkspace(_ prefix: String) throws -> URL {
        let root = repoRootURL()
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func jsonObject(from value: String) throws -> [String: Any] {
        let data = try XCTUnwrap(value.data(using: .utf8))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func toolJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private func writeTinyPNG(to url: URL) throws {
        let base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        try data.write(to: url)
    }

    private func writeMinimalPDF(to url: URL) throws {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 200)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        try (data as Data).write(to: url)
    }

    private func repoRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
