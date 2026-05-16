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

        XCTAssertEqual(Set(names), Set(AgentToolRegistry.toolNames))
        XCTAssertTrue(names.contains("Read"))
        XCTAssertTrue(names.contains("Write"))
        XCTAssertTrue(names.contains("Bash"))
        XCTAssertTrue(names.contains("TodoWrite"))
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

    func testNativeAgentRuntimeParsesLegacyCommandFallbackAsToolOnly() {
        let calls = NativeAgentRuntime.fallbackToolCalls(in: #"<command>{"input":"ls"}</command>"#)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "Glob")
        XCTAssertTrue(calls.first?.inputJSON.contains(#""pattern":"*""#) == true)
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
        XCTAssertEqual(invocation.recoveryResult?.toolName, "Edit")
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
            name: "ExitPlanMode",
            inputJSON: #"{"plan":"Edit index.html."}"#
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
        context.continuationNudgeCount = 3

        XCTAssertNil(
            NativeAgentRuntime.continuationNudge(
                request: request,
                context: context,
                assistantContent: "I should continue."
            )
        )
    }

    func testReadOnlyBashDoesNotSatisfyWorkspaceMutation() {
        let request = agentRequest(prompt: "optimize this website", permissionMode: .bypassPermissions)
        let context = AgentRunContext(request: request)
        let call = AgentToolCall(id: "bash", name: "Bash", inputJSON: #"{"command":"find . -maxdepth 1 -type f"}"#)
        context.recordToolResult(
            AgentToolResult(callId: "bash", toolName: "Bash", output: "index.html", isError: false),
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
        let editCall = AgentToolCall(id: "call-edit", name: "Edit", inputJSON: "{}")
        if case .deny(let reason) = NativeToolRouter.permissionPolicy(for: editCall, context: context) {
            XCTAssertTrue(reason.lowercased().contains("plan mode"))
        } else {
            XCTFail("Plan mode must deny mutating tools before ExitPlanMode.")
        }
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
        permissionMode: ComposerPermissionMode = .default
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
            toolSettings: .defaults,
            routerRoute: "default",
            permissionHandler: nil
        )
    }

    private func repoRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
