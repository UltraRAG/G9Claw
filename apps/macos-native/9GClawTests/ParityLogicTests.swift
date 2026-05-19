import AppKit
import XCTest
@testable import NineGClaw

final class ParityLogicTests: XCTestCase {
    func testWorkspaceRejectsSystemPaths() {
        let service = WorkspaceService(workspaceRoot: URL(fileURLWithPath: "/Users/tester"))

        XCTAssertFalse(service.validateWorkspacePath("/").valid)
        XCTAssertFalse(service.validateWorkspacePath("/usr/bin").valid)
        XCTAssertFalse(service.validateWorkspacePath("/opt/homebrew").valid)
        XCTAssertFalse(service.validateWorkspacePath("/tmp/work").valid)
    }

    func testWorkspaceRejectsPathOutsideRoot() {
        let service = WorkspaceService(workspaceRoot: URL(fileURLWithPath: "/Users/tester/Workspace"))
        let result = service.validateWorkspacePath("/Users/tester/Downloads/project")

        XCTAssertFalse(result.valid)
        XCTAssertEqual(result.error, "Workspace path must be within the allowed workspace root: /Users/tester/Workspace")
    }

    func testWorkspaceAllowsPathInsideRoot() {
        let service = WorkspaceService(workspaceRoot: URL(fileURLWithPath: "/Users/tester"))
        let result = service.validateWorkspacePath("/Users/tester/project")

        XCTAssertTrue(result.valid)
        XCTAssertEqual(result.resolvedPath, "/Users/tester/project")
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
            "WebSearch",
            "WebFetch",
            "ReadLints",
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
    }

    func testAgentToolNameCanonicalizerAcceptsSubagentAliases() {
        XCTAssertEqual(AgentToolNameCanonicalizer.canonical("Agent"), "Task")
        XCTAssertEqual(AgentToolNameCanonicalizer.canonical("subagent"), "Task")
        XCTAssertEqual(AgentToolNameCanonicalizer.canonical("sub_agent"), "Task")
        XCTAssertEqual(AgentToolNameCanonicalizer.canonical("sub-agent"), "Task")
    }

    func testAgentToolNameCanonicalizerKeepsClaudeCodeAliasesCompatible() {
        XCTAssertEqual(AgentToolNameCanonicalizer.canonical("Edit"), "StrReplace")
        XCTAssertEqual(AgentToolNameCanonicalizer.canonical("MultiEdit"), "StrReplace")
        XCTAssertEqual(AgentToolNameCanonicalizer.canonical("Bash"), "Shell")
        XCTAssertEqual(AgentToolNameCanonicalizer.canonical("run_command"), "Shell")
        XCTAssertEqual(AgentToolNameCanonicalizer.canonical("TaskCreate"), "Task")
        XCTAssertEqual(AgentToolNameCanonicalizer.canonical("TaskOutput"), "Await")
        XCTAssertEqual(AgentToolNameCanonicalizer.canonical("AskUserQuestion"), "AskQuestion")
        XCTAssertEqual(AgentToolNameCanonicalizer.canonical("ExitPlanMode"), "SwitchMode")
        XCTAssertEqual(AgentToolNameCanonicalizer.canonical("NotebookEdit"), "EditNotebook")
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

    func testAskUserQuestionNormalizesWebQuestionsShape() throws {
        let payload = try XCTUnwrap(AgentInteractivePayload.askUserQuestion(from: """
        {"questions":[{"header":"Choose","question":"What should I build?","options":[{"label":"Landing Page","description":"Product page"},{"label":"Blog"}],"multiSelect":false}]}
        """))

        XCTAssertEqual(payload.questions.count, 1)
        XCTAssertEqual(payload.questions.first?.header, "Choose")
        XCTAssertEqual(payload.questions.first?.question, "What should I build?")
        XCTAssertEqual(payload.questions.first?.options.map(\.label), ["Landing Page", "Blog"])
        XCTAssertEqual(payload.questions.first?.options.first?.description, "Product page")
        XCTAssertEqual(payload.questions.first?.multiSelect, false)
    }

    func testAskUserQuestionNormalizesLegacyQuestionShape() throws {
        let payload = try XCTUnwrap(AgentInteractivePayload.askUserQuestion(from: """
        {"question":"Pick a style","options":["Minimal","Playful"]}
        """))

        XCTAssertEqual(payload.questions.count, 1)
        XCTAssertEqual(payload.questions.first?.question, "Pick a style")
        XCTAssertEqual(payload.questions.first?.options.map(\.label), ["Minimal", "Playful"])
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
    }

    func testAgentRunContextDedupesToolSignature() {
        let context = AgentRunContext(request: agentRequest(permissionMode: .bypassPermissions))
        let first = AgentToolCall(id: "call-1", name: "Read", inputJSON: #"{"file_path":"README.md"}"#)
        let repeated = AgentToolCall(id: "call-2", name: "Read", inputJSON: #"{"file_path":"README.md"}"#)

        XCTAssertTrue(context.markToolCallIfNeeded(first))
        XCTAssertFalse(context.markToolCallIfNeeded(repeated))
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

    func testAgentPermissionPolicyRejectsMutatingToolsInPlanMode() {
        let context = AgentRunContext(request: agentRequest(runMode: .plan, permissionMode: .bypassPermissions))
        let call = AgentToolCall(
            id: "call-1",
            name: "Write",
            inputJSON: #"{"file_path":"index.html","content":"hi"}"#
        )

        switch AgentPermissionPolicy.policy(for: call, context: context) {
        case .deny(let reason):
            XCTAssertTrue(reason.contains("plan mode"))
        default:
            XCTFail("Write should be denied before ExitPlanMode in plan mode.")
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

    func testAgentToolExecutorSearchShellAwaitWebFetchAndLints() async throws {
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
        try "<html><body><h1>Fetched Title</h1><p>Body text</p></body></html>".write(
            to: root.appendingPathComponent("page.html"),
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

        let fetchURL = root.appendingPathComponent("page.html").absoluteString
        let fetch = await NativeToolRouter.execute(
            call: AgentToolCall(id: "fetch", name: "WebFetch", inputJSON: toolJSON(["url": fetchURL, "prompt": "extract text"])),
            context: context
        )
        XCTAssertFalse(fetch.isError, fetch.output)
        XCTAssertTrue(fetch.output.contains("Fetched Title"))

        let lints = await NativeToolRouter.execute(
            call: AgentToolCall(id: "lints", name: "ReadLints", inputJSON: #"{"path":".","severity":"warning"}"#),
            context: context
        )
        XCTAssertFalse(lints.isError, lints.output)
        XCTAssertTrue(lints.output.contains("lint warning"))
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

        if case .deny(let reason) = AgentPermissionPolicy.policy(
            for: AgentToolCall(id: "delete", name: "Delete", inputJSON: #"{"path":"tmp.txt"}"#),
            context: context
        ) {
            XCTAssertTrue(reason.contains("plan mode"))
        } else {
            XCTFail("Delete must be denied in plan mode.")
        }

        if case .deny = AgentPermissionPolicy.policy(
            for: AgentToolCall(id: "shell-write", name: "Shell", inputJSON: #"{"command":"touch tmp.txt"}"#),
            context: context
        ) {
            XCTAssertTrue(true)
        } else {
            XCTFail("Mutating Shell must be denied in plan mode.")
        }

        if case .deny = AgentPermissionPolicy.policy(
            for: AgentToolCall(id: "task-full", name: "Task", inputJSON: #"{"type":"generalPurpose","prompt":"change files"}"#),
            context: context
        ) {
            XCTAssertTrue(true)
        } else {
            XCTFail("Mutating/full-agent Task must be denied in plan mode.")
        }
    }

    func testWebSearchReturnsToolErrorWhenProviderIsMissing() async throws {
        let root = try makeAgentWorkspace("9gclaw-agent-websearch")
        defer { try? FileManager.default.removeItem(at: root) }
        let context = AgentRunContext(request: agentRequest(projectPath: root.path, permissionMode: .bypassPermissions))

        let result = await NativeToolRouter.execute(
            call: AgentToolCall(id: "web-search", name: "WebSearch", inputJSON: #"{"query":"test","allowed_domains":["example.com"]}"#),
            context: context
        )

        XCTAssertEqual(result.toolName, "WebSearch")
        XCTAssertFalse(result.output.isEmpty)
    }

    func testAppInfoPlistIncludesATSForHTTPProviders() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plistURL = repoRoot
            .appendingPathComponent("9GClaw")
            .appendingPathComponent("App")
            .appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: plistURL)
        var format: PropertyListSerialization.PropertyListFormat = .xml
        let rawPlist = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        let plist = try XCTUnwrap(rawPlist as? [String: Any])
        let ats = try XCTUnwrap(plist["NSAppTransportSecurity"] as? [String: Any])

        XCTAssertEqual(ats["NSAllowsArbitraryLoads"] as? Bool, true)
        XCTAssertEqual(ats["NSAllowsLocalNetworking"] as? Bool, true)
        let exceptionDomains = try XCTUnwrap(ats["NSExceptionDomains"] as? [String: Any])
        let edgeclawHTTPProvider = try XCTUnwrap(exceptionDomains["58.57.119.12"] as? [String: Any])
        XCTAssertEqual(edgeclawHTTPProvider["NSExceptionAllowsInsecureHTTPLoads"] as? Bool, true)
    }

    func testAppInfoPlistDeclaresAppIcon() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plistURL = repoRoot
            .appendingPathComponent("9GClaw")
            .appendingPathComponent("App")
            .appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: plistURL)
        var format: PropertyListSerialization.PropertyListFormat = .xml
        let rawPlist = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        let plist = try XCTUnwrap(rawPlist as? [String: Any])

        XCTAssertEqual(plist["CFBundleIconName"] as? String, "AppIcon")
        XCTAssertEqual(plist["CFBundleIconFile"] as? String, "AppIcon")
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

    func testFilesSplitLayoutNeverOverflowsAvailableWidth() {
        let layout = FilesSplitLayoutCalculator.calculate(
            availableWidth: 820,
            requestedChatWidth: 720,
            requestedEditorWidth: 900,
            hasEditor: true,
            editorExpanded: false
        )

        XCTAssertLessThanOrEqual(layout.chat + layout.tree + layout.editor + 24, 820.0001)
        XCTAssertGreaterThan(layout.chat, 0)
        XCTAssertGreaterThan(layout.tree, 0)
        XCTAssertGreaterThan(layout.editor, 0)

        let noEditor = FilesSplitLayoutCalculator.calculate(
            availableWidth: 560,
            requestedChatWidth: 720,
            requestedEditorWidth: 0,
            hasEditor: false,
            editorExpanded: false
        )
        XCTAssertLessThanOrEqual(noEditor.chat + noEditor.tree + 12, 560.0001)
        XCTAssertEqual(noEditor.editor, 0)
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

    func testConfigYAMLAPIKeyIsPreferredOverKeychainFallback() {
        let yaml = """
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
        let snapshot = NativeConfigService.snapshot(from: yaml)

        let resolved = NativeConfigService.resolvedAPIKey(
            routeEntryID: "default",
            nativeConfig: snapshot,
            keychainValue: "keychain-secret",
            apiKeyDraft: "draft-secret"
        )

        XCTAssertEqual(resolved, "yaml-secret")
    }

    func testConfigYAMLAPIKeyFallsBackToKeychainWhenBlank() {
        let yaml = """
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
        let snapshot = NativeConfigService.snapshot(from: yaml)

        let resolved = NativeConfigService.resolvedAPIKey(
            routeEntryID: "default",
            nativeConfig: snapshot,
            keychainValue: "keychain-secret",
            apiKeyDraft: "draft-secret"
        )

        XCTAssertEqual(resolved, "keychain-secret")
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
        if case .deny(let reason) = NativeToolRouter.permissionPolicy(for: editCall, context: context) {
            XCTAssertTrue(reason.lowercased().contains("plan mode"))
        } else {
            XCTFail("Plan mode must deny mutating tools before SwitchMode.")
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
            ["role": "tool", "content": String(repeating: "x", count: 24_000)],
        ]
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

    func testToolInvocationPresentationRendersShellCommand() {
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
    }

    func testToolInvocationPresentationFallsBackToRawInputForMalformedJSON() {
        let presentation = ToolInvocationPresentation.parse(toolName: "Read", inputJSON: "{path: README.md")

        XCTAssertFalse(presentation.parsed)
        XCTAssertNil(presentation.command)
        XCTAssertEqual(presentation.fields, [
            ToolInvocationField(label: "Raw input", value: "{path: README.md", isPrimary: true),
        ])
        XCTAssertEqual(presentation.primaryValue, "{path: README.md")
    }

    func testToolInvocationPresentationExtractsCommonToolFields() {
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

    @MainActor
    func testComposerRunModeConsumeResetsPlanAfterSnapshot() {
        let state = AppState()
        state.composerRunMode = .plan

        let requested = state.consumeComposerRunModeForSend()

        XCTAssertEqual(requested, .plan)
        XCTAssertEqual(state.composerRunMode, .agent)
    }

    func testAgentEventTerminalClassification() {
        XCTAssertTrue(AgentEvent.complete(sessionId: "s").isTerminal)
        XCTAssertTrue(AgentEvent.aborted(sessionId: "s").isTerminal)
        XCTAssertTrue(AgentEvent.error("boom").isTerminal)
        XCTAssertFalse(AgentEvent.streamEnd.isTerminal)
        XCTAssertFalse(AgentEvent.status("thinking").isTerminal)
    }

    func testSkillToolPlanPolicyRemainsAvailableForLegacyFallbacks() {
        let tools = NativeToolRouter.openAITools()
        let names = tools.compactMap { tool -> String? in
            guard let function = tool["function"] as? [String: Any] else { return nil }
            return function["name"] as? String
        }
        XCTAssertFalse(names.contains("Skill"))

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

    func testProcessToolPresentationClassifierUsesExactCanonicalTools() {
        XCTAssertEqual(AgentToolPresentationClassifier.phase(forToolName: "Task"), .subagent)
        XCTAssertEqual(AgentToolPresentationClassifier.phase(forToolName: "Agent"), .subagent)
        XCTAssertEqual(AgentToolPresentationClassifier.phase(forToolName: "Shell"), .command)
        XCTAssertEqual(AgentToolPresentationClassifier.phase(forToolName: "Glob"), .search)
        XCTAssertEqual(AgentToolPresentationClassifier.phase(forToolName: "SemanticSearch"), .search)
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
