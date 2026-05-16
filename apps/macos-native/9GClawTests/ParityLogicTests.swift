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
        I need to inspect the file.
        ```json
        {"tool":"Read","input":{"file_path":"README.md"}}
        ```
        """

        let calls = NativeAgentRuntime.fallbackToolCalls(in: text)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "Read")
        XCTAssertTrue(calls.first?.inputJSON.contains("README.md") == true)
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
        runMode: ChatRunMode = .agent,
        permissionMode: ComposerPermissionMode = .default
    ) -> AgentRequest {
        AgentRequest(
            sessionId: "test-session",
            projectPath: projectPath,
            prompt: "test",
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
