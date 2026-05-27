import AppKit
import XCTest
@testable import G9Claw

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
                provider: .g9Claw,
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

    func testSidebarProjectRestorationPrefersRememberedProject() {
        let now = Date()
        let first = project(name: "first", displayName: "First", date: now)
        let remembered = project(name: "remembered", displayName: "Remembered", date: now)

        let restored = SidebarProjectRestorationPolicy.preferredProject(
            from: [first, remembered],
            lastProjectIDRaw: remembered.id.uuidString
        )

        XCTAssertEqual(restored?.id, remembered.id)
        XCTAssertEqual(
            SidebarProjectRestorationPolicy.preferredProject(from: [first, remembered], lastProjectIDRaw: "")?.id,
            first.id
        )
    }

    func testLegacyConfigLoaderReadsDefaultProviderSettings() {
        let yaml = """
        runtime:
          workspacesRoot: ~/Workspace
        gateway:
          runtimePaths:
            generalCwd: ~/G9Claw/general
        models:
          providers:
            g9claw:
              type: openai-chat
              baseUrl: http://example.local/v1
              apiKey: local-secret
          entries:
            default:
              provider: g9claw
              name: qwen3.6-27b
        """

        let snapshot = LegacyConfigLoader.snapshot(from: yaml)

        XCTAssertEqual(snapshot?.baseURL, "http://example.local/v1")
        XCTAssertEqual(snapshot?.apiKey, "local-secret")
        XCTAssertEqual(snapshot?.model, "qwen3.6-27b")
        XCTAssertEqual(snapshot?.workspacesRoot, "~/Workspace")
        XCTAssertEqual(snapshot?.generalWorkspacePath, "~/G9Claw/general")
    }

    func testGeneralWorkspacePathFallsBackWhenConfigIsRelative() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

        XCTAssertEqual(
            AppState.normalizedGeneralWorkspacePath("general", home: home),
            "/Users/tester/G9Claw/general"
        )
        XCTAssertEqual(
            AppState.normalizedGeneralWorkspacePath("  ", home: home),
            "/Users/tester/G9Claw/general"
        )
        XCTAssertEqual(
            AppState.normalizedGeneralWorkspacePath("/Users/tester/Projects/demo", home: home),
            "/Users/tester/Projects/demo"
        )
    }

    func testNativeConfigPathUsesG9ClawConfigLocationAndOverride() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

        XCTAssertEqual(
            G9ClawConfigPath.configURL(environment: [:], home: home).path,
            "/Users/tester/.g9claw/config.yaml"
        )
        XCTAssertEqual(
            G9ClawConfigPath.configURL(environment: ["G9CLAW_CONFIG_PATH": "~/g9claw-dev.yaml"], home: home).path,
            "/Users/tester/g9claw-dev.yaml"
        )
        XCTAssertEqual(
            G9ClawConfigPath.legacyConfigURL(home: home).path,
            "/Users/tester/.edgeclaw/config.yaml"
        )
    }

    func testNativeDefaultConfigUsesG9ClawProviderAndDisabledRouterRagDefaults() {
        let yaml = G9ClawConfigDefaults.configText(homePath: "/Users/tester", userName: "tester")
        let values = NativeConfigService.scalarMap(from: yaml)

        XCTAssertEqual(values["models.entries.default.provider"], "g9claw")
        XCTAssertEqual(values["models.providers.g9claw.type"], "openai-chat")
        XCTAssertEqual(values["models.providers.edgeclaw.type"], nil)
        XCTAssertEqual(values["memory.model"], "inherit")
        XCTAssertEqual(values["memory.autoIndexIntervalMinutes"], "30")
        XCTAssertEqual(values["memory.autoDreamIntervalMinutes"], "60")
        XCTAssertEqual(values["rag.enabled"], "false")
        XCTAssertEqual(values["rag.glmWebSearch.baseUrl"], "")
        XCTAssertEqual(values["router.enabled"], "false")
        XCTAssertEqual(values["router.tokenSaver.enabled"], "false")
        XCTAssertEqual(values["gateway.home"], "/Users/tester/.g9claw/gateway")
        XCTAssertEqual(values["gateway.runtimePaths.generalCwd"], "~/G9Claw/general")

        let channelNames = Set(values.keys.compactMap { key -> String? in
            guard key.hasPrefix("gateway.channels.") else { return nil }
            let parts = key.split(separator: ".")
            return parts.count > 2 ? String(parts[2]) : nil
        })
        XCTAssertEqual(
            channelNames,
            Set([
                "feishu",
                "telegram",
                "discord",
                "slack",
                "wecom",
                "wecom_callback",
                "dingtalk",
                "weixin",
                "whatsapp",
                "signal",
                "matrix",
                "mattermost",
                "email",
                "sms_twilio",
                "homeassistant",
                "api_server",
                "webhook",
                "bluebubbles",
            ])
        )
        XCTAssertEqual(values["gateway.channels.feishu.webhookPath"], "/feishu/webhook")
        XCTAssertEqual(values["gateway.channels.feishu.homeChannel.name"], "Home")
        XCTAssertEqual(values["gateway.channels.telegram.webhookPort"], "null")
        XCTAssertEqual(values["gateway.channels.wecom.websocketUrl"], "wss://openws.work.weixin.qq.com")
        XCTAssertEqual(values["gateway.channels.api_server.port"], "8642")
        XCTAssertEqual(values["gateway.channels.api_server.modelName"], "g9claw-gateway")
        XCTAssertEqual(values["gateway.channels.webhook.secret"], "")
    }

    func testNativeConfigServiceUsesG9ClawAsDefaultProviderID() {
        let yaml = """
        models:
          providers:
            g9claw:
              type: openai-chat
              baseUrl: http://g9claw.local/v1
              apiKey: test-secret
          entries:
            default:
              provider: g9claw
              name: test-model
        """

        let values = NativeConfigService.scalarMap(from: yaml)
        let snapshot = NativeConfigService.snapshot(from: yaml)

        XCTAssertEqual(NativeConfigService.providerID(entryID: "missing", values: values), "g9claw")
        XCTAssertEqual(snapshot?.providerConfig.baseURL, "http://g9claw.local/v1")
        XCTAssertEqual(snapshot?.providerConfig.model, "test-model")
        XCTAssertEqual(snapshot?.providerConfig.secretAccount, ProviderConfig.empty.secretAccount)
        XCTAssertEqual(snapshot?.apiKey, "test-secret")
    }

    func testNativeConfigScalarMapMigratesLegacyAlwaysOnTriggerLikeWeb() {
        let yaml = """
        agents:
          alwaysOn:
            discovery:
              trigger:
                enabled: true
                tickIntervalMinutes: 15
                cooldownMinutes: 45
        """

        let values = NativeConfigService.scalarMap(from: yaml)

        XCTAssertEqual(values["alwaysOn.discovery.trigger.enabled"], "true")
        XCTAssertEqual(values["alwaysOn.discovery.trigger.tickIntervalMinutes"], "15")
        XCTAssertEqual(values["alwaysOn.discovery.trigger.cooldownMinutes"], "45")
        XCTAssertNil(values["agents.alwaysOn.discovery.trigger.enabled"])
    }

    func testNativeConfigScalarMapPrefersTopLevelAlwaysOnTriggerLikeWeb() {
        let yaml = """
        agents:
          alwaysOn:
            discovery:
              trigger:
                enabled: true
                tickIntervalMinutes: 15
        alwaysOn:
          discovery:
            trigger:
              enabled: false
              tickIntervalMinutes: 3
        """

        let values = NativeConfigService.scalarMap(from: yaml)

        XCTAssertEqual(values["alwaysOn.discovery.trigger.enabled"], "false")
        XCTAssertEqual(values["alwaysOn.discovery.trigger.tickIntervalMinutes"], "3")
        XCTAssertNil(values["agents.alwaysOn.discovery.trigger.enabled"])
    }

    func testNativeConfigScalarMapMigratesLegacyRagMilvusURIToDatabaseURLLikeWeb() {
        let legacyOnly = """
        rag:
          localKnowledge:
            milvusUri: http://127.0.0.1:52008/search
        """
        let explicitDatabaseURL = """
        rag:
          localKnowledge:
            databaseUrl: http://database.example/search
            milvusUri: http://legacy.example/search
        """

        let migrated = NativeConfigService.scalarMap(from: legacyOnly)
        let preferred = NativeConfigService.scalarMap(from: explicitDatabaseURL)

        XCTAssertEqual(migrated["rag.localKnowledge.databaseUrl"], "http://127.0.0.1:52008/search")
        XCTAssertNil(migrated["rag.localKnowledge.milvusUri"])
        XCTAssertEqual(preferred["rag.localKnowledge.databaseUrl"], "http://database.example/search")
        XCTAssertNil(preferred["rag.localKnowledge.milvusUri"])
    }

    func testNativeConfigFormLayoutMatchesWebSplitSectionNavigation() {
        XCTAssertTrue(NativeConfigFormLayout.usesSplitSectionNavigation)
        XCTAssertFalse(NativeConfigFormLayout.usesSectionDropdown)
        XCTAssertFalse(NativeConfigFormLayout.usesViewModeToggle)
        XCTAssertFalse(NativeConfigFormLayout.exposesRawYAMLEditor)
        XCTAssertEqual(NativeConfigFormLayout.headerActionIDs, [
            "revealInFinder",
            "import",
            "export",
            "saveAndReloadCurrent",
        ])
        XCTAssertEqual(NativeConfigFormLayout.sectionNavigationWidth, 180)
        XCTAssertEqual(NativeConfigFormLayout.sectionNavigationGap, 16)
        XCTAssertEqual(NativeConfigFormLayout.sectionOrder, [
            .runtime,
            .models,
            .alwaysOn,
            .memory,
            .rag,
            .router,
            .gateway,
        ])
        XCTAssertFalse(NativeConfigFormLayout.sectionOrder.contains(.raw))
    }

    func testNativeConfigReloadSummarySubsystemsMatchWebSettingsTab() {
        XCTAssertEqual(NativeConfigReloadSummary.subsystemIDs, [
            "processEnv",
            "memory",
            "router",
            "gateway",
        ])
        XCTAssertEqual(NativeConfigReloadSummary.subsystems.map(\.label), [
            .processEnv,
            .memory,
            .routerCCR,
            .gateway,
        ])
    }

    func testNativeConfigModelPickerOptionsMatchWebFormSelects() {
        let yaml = """
        models:
          entries:
            default:
              provider: g9claw
              name: main-model
            router_small:
              provider: g9claw
              name: small-model
        """
        let values = NativeConfigService.scalarMap(from: yaml)

        XCTAssertEqual(NativeConfigModelOptions.entryIDs(values: values), ["default", "router_small"])
        XCTAssertEqual(
            NativeConfigModelOptions.options(values: values, includeEmpty: true),
            ["", "default", "router_small"]
        )
        XCTAssertEqual(
            NativeConfigModelOptions.options(values: values, includeInherit: true),
            ["inherit", "default", "router_small"]
        )
    }

    func testNativeModelsConfigFormBehaviorMatchesWebSettingsTab() {
        XCTAssertEqual(NativeModelsConfigFormFields.providerTypeOptions, [
            "openai-chat",
            "openai-responses",
            "anthropic",
            "litellm",
            "ccr",
        ])
        XCTAssertEqual(NativeModelsConfigFormFields.newProviderScalars, [
            "type": "openai-chat",
            "baseUrl": "",
            "apiKey": "",
        ])
        XCTAssertFalse(NativeModelsConfigFormFields.newProviderScalars.keys.contains("transformer"))
        XCTAssertFalse(NativeModelsConfigFormFields.newProviderScalars.keys.contains("headers"))

        XCTAssertTrue(NativeModelsConfigFormFields.usesModelPoolDropdown)
        XCTAssertTrue(NativeModelsConfigFormFields.usageAssignmentsLiveInModelSection)
        XCTAssertFalse(NativeModelsConfigFormFields.entryRowsExposeProviderPicker)
        XCTAssertFalse(NativeModelsConfigFormFields.entryRowsExposeModelNameField)
        XCTAssertEqual(NativeModelsConfigFormFields.assignmentPaths, [
            "agents.main.model",
            "agents.subagents.default",
            "memory.model",
            "router.routes.default.model",
            "router.routes.background.model",
            "router.routes.think.model",
            "router.routes.longContext.model",
            "router.routes.webSearch.model",
            "router.tokenSaver.judgeModel",
            "router.tokenSaver.tiers.SIMPLE.model",
            "router.tokenSaver.tiers.MEDIUM.model",
            "router.tokenSaver.tiers.COMPLEX.model",
            "router.tokenSaver.tiers.REASONING.model",
            "router.autoOrchestrate.mainAgentModel",
        ])
        XCTAssertEqual(NativeModelsConfigFormFields.newEntryScalars(firstProvider: "g9claw"), [
            "provider": "g9claw",
            "name": "",
            "contextWindow": "",
        ])
    }

    func testNativeRuntimeConfigFormFieldsMatchWebSettingsTab() {
        XCTAssertEqual(NativeRuntimeConfigFormFields.visiblePaths, [
            "runtime.apiTimeoutMs",
            "runtime.databasePath",
            "runtime.workspacesRoot",
        ])
        XCTAssertFalse(NativeRuntimeConfigFormFields.visiblePaths.contains("runtime.host"))
        XCTAssertFalse(NativeRuntimeConfigFormFields.visiblePaths.contains("runtime.serverPort"))
        XCTAssertFalse(NativeRuntimeConfigFormFields.visiblePaths.contains("runtime.vitePort"))
        XCTAssertFalse(NativeRuntimeConfigFormFields.visiblePaths.contains("runtime.proxyPort"))
        XCTAssertFalse(NativeRuntimeConfigFormFields.visiblePaths.contains("runtime.contextWindow"))
        XCTAssertFalse(NativeRuntimeConfigFormFields.visiblePaths.contains("runtime.httpsProxy"))
        XCTAssertFalse(NativeRuntimeConfigFormFields.visiblePaths.contains("gateway.runtimePaths.generalCwd"))
    }

    func testNativeRagConfigFormFieldsExposeBothWebEndpointApiKeys() {
        let fields = NativeRagConfigFormFields.textFields
        let paths = fields.map(\.path)

        XCTAssertEqual(
            paths,
            [
                "rag.localKnowledge.baseUrl",
                "rag.localKnowledge.apiKey",
                "rag.localKnowledge.modelName",
                "rag.localKnowledge.databaseUrl",
                "rag.glmWebSearch.baseUrl",
                "rag.glmWebSearch.apiKey",
                "rag.glmWebSearch.defaultTopK",
            ]
        )
        XCTAssertEqual(Set(fields.filter(\.isSecure).map(\.path)), [
            "rag.localKnowledge.apiKey",
            "rag.glmWebSearch.apiKey",
        ])
        XCTAssertEqual(NativeRagConfigFormFields.enabledPath, "rag.enabled")
        XCTAssertEqual(NativeRagConfigFormFields.disableBuiltInWebToolsPath, "rag.disableBuiltInWebTools")
        XCTAssertTrue(NativeRagConfigFormFields.disableBuiltInWebToolsDefault)
        XCTAssertEqual(NativeRagConfigFormFields.booleanDefaults, [
            "rag.enabled": false,
            "rag.disableBuiltInWebTools": true,
        ])

        XCTAssertEqual(NativeRagConfigFormFields.endpointCards.map(\.id), [
            "localKnowledge",
            "glmWebSearch",
        ])
        XCTAssertEqual(NativeRagConfigFormFields.endpointCards.map(\.title), [
            .ragLocalKnowledgeTitle,
            .ragGlmWebSearchTitle,
        ])
        XCTAssertEqual(NativeRagConfigFormFields.endpointCards[0].fields.map(\.path), [
            "rag.localKnowledge.baseUrl",
            "rag.localKnowledge.apiKey",
            "rag.localKnowledge.modelName",
            "rag.localKnowledge.databaseUrl",
        ])
        XCTAssertFalse(NativeRagConfigFormFields.endpointCards[0].includesDefaultTopK)
        XCTAssertEqual(NativeRagConfigFormFields.endpointCards[1].fields.map(\.path), [
            "rag.glmWebSearch.baseUrl",
            "rag.glmWebSearch.apiKey",
            "rag.glmWebSearch.defaultTopK",
        ])
        XCTAssertTrue(NativeRagConfigFormFields.endpointCards[1].includesDefaultTopK)
        XCTAssertEqual(NativeRagConfigFormFields.localKnowledgeFields.map(\.label), [
            .localKnowledgeBaseURL,
            .apiKey,
            .embeddingModel,
            .databaseURL,
        ])
        XCTAssertEqual(NativeRagConfigFormFields.glmWebSearchFields.map(\.label), [
            .glmWebSearchBaseURL,
            .apiKey,
            .glmDefaultTopK,
        ])
    }

    func testNativeRagConfigLabelsMatchWebSettingsTabCopy() {
        let english = LocalizationService(language: .english)
        let chinese = LocalizationService(language: .chineseSimplified)

        XCTAssertEqual(
            english.text(.ragSectionDetail),
            "Local retriever and GLM web search APIs used by the bundled G9Claw RAG skills."
        )
        XCTAssertEqual(
            english.text(.ragDetail),
            "When on, G9Claw exports G9CLAW_RAG_* env vars so RAG skills can call these APIs."
        )
        XCTAssertEqual(
            english.text(.disableBuiltInWebToolsDetail),
            "When RAG is enabled, hide WebFetch/WebSearch from model-visible tools so web search goes through G9Claw RAG skills."
        )
        XCTAssertEqual(english.text(.ragLocalKnowledgeTitle), "Local knowledge / Retriever")
        XCTAssertEqual(
            english.text(.ragLocalKnowledgeDetail),
            "Private or curated knowledge base retrieval endpoint, including Milvus-backed services."
        )
        XCTAssertEqual(english.text(.ragGlmWebSearchTitle), "Z.AI / GLM Web Search")
        XCTAssertEqual(
            english.text(.ragGlmWebSearchDetail),
            "Public web search endpoint used for current information and URL-backed citations."
        )
        XCTAssertEqual(english.text(.localKnowledgeBaseURL), "Embedding / Model URL")
        XCTAssertEqual(english.text(.apiKey), "API key")
        XCTAssertEqual(english.text(.embeddingModel), "Model name")
        XCTAssertEqual(english.text(.databaseURL), "Search URL")
        XCTAssertEqual(english.text(.glmWebSearchBaseURL), "Endpoint URL")
        XCTAssertEqual(english.text(.glmDefaultTopK), "Default top K")

        XCTAssertEqual(
            chinese.text(.ragSectionDetail),
            "内置 G9Claw RAG 技能使用的本地检索器和 GLM Web Search API。"
        )
        XCTAssertEqual(chinese.text(.ragLocalKnowledgeTitle), "本地知识库 / Retriever")
        XCTAssertEqual(chinese.text(.glmWebSearchBaseURL), "Endpoint URL")
    }

    func testNativeRagDisableBuiltInWebToolsDefaultsOnLikeWebSettingsTab() {
        XCTAssertTrue(NativeConfigBoolValue.resolve("", defaultValue: NativeRagConfigFormFields.disableBuiltInWebToolsDefault))
        XCTAssertTrue(NativeConfigBoolValue.resolve("true", defaultValue: NativeRagConfigFormFields.disableBuiltInWebToolsDefault))
        XCTAssertFalse(NativeConfigBoolValue.resolve("false", defaultValue: NativeRagConfigFormFields.disableBuiltInWebToolsDefault))

        XCTAssertFalse(NativeConfigBoolValue.resolve("", defaultValue: false))
    }

    func testNativeMemoryConfigFormFieldsMatchWebSettingsTab() {
        XCTAssertEqual(NativeMemoryConfigFormFields.visiblePaths, [
            "memory.enabled",
        ])
        XCTAssertTrue(NativeModelsConfigFormFields.assignmentPaths.contains("memory.model"))
        XCTAssertFalse(NativeMemoryConfigFormFields.visiblePaths.contains("memory.includeAssistant"))
        XCTAssertFalse(NativeMemoryConfigFormFields.visiblePaths.contains("memory.reasoningMode"))
        XCTAssertFalse(NativeMemoryConfigFormFields.visiblePaths.contains("memory.autoIndexIntervalMinutes"))
    }

    func testNativeAlwaysOnConfigFormFieldsMatchWebSettingsTab() {
        XCTAssertEqual(NativeAlwaysOnConfigFormFields.visiblePaths, [
            "alwaysOn.discovery.trigger.enabled",
            "alwaysOn.discovery.trigger.tickIntervalMinutes",
            "alwaysOn.discovery.trigger.cooldownMinutes",
            "alwaysOn.discovery.trigger.dailyBudget",
        ])
        XCTAssertFalse(NativeAlwaysOnConfigFormFields.visiblePaths.contains("alwaysOn.discovery.trigger.heartbeatStaleSeconds"))
        XCTAssertFalse(NativeAlwaysOnConfigFormFields.visiblePaths.contains("alwaysOn.discovery.trigger.recentUserMsgMinutes"))
        XCTAssertFalse(NativeAlwaysOnConfigFormFields.visiblePaths.contains("alwaysOn.discovery.trigger.preferClient"))
    }

    func testNativeRouterAndGatewayConfigFormFieldsMatchWebSettingsTab() {
        XCTAssertEqual(NativeRouterConfigFormFields.visiblePaths, [
            "router.enabled",
        ])
        XCTAssertEqual(NativeRouterConfigFormFields.routeModelFields.map(\.path), [
            "router.routes.default.model",
            "router.routes.background.model",
        ])
        XCTAssertEqual(NativeRouterConfigFormFields.advancedRouteModelFields.map(\.path), [
            "router.routes.think.model",
            "router.routes.longContext.model",
            "router.routes.webSearch.model",
        ])
        XCTAssertFalse(NativeRouterConfigFormFields.visiblePaths.contains("router.log"))
        XCTAssertFalse(NativeRouterConfigFormFields.visiblePaths.contains("router.routes.default.model"))
        XCTAssertFalse(NativeRouterConfigFormFields.visiblePaths.contains("router.tokenSaver.enabled"))

        XCTAssertEqual(NativeGatewayConfigFormFields.visiblePaths, [
            "gateway.enabled",
            "gateway.home",
        ])
        XCTAssertFalse(NativeGatewayConfigFormFields.visiblePaths.contains("gateway.allowAllUsers"))
        XCTAssertFalse(NativeGatewayConfigFormFields.visiblePaths.contains("gateway.groupSessionsPerUser"))
        XCTAssertFalse(NativeGatewayConfigFormFields.visiblePaths.contains("gateway.runtimePaths.generalCwd"))
    }

    func testToolPermissionQuickRulesMatchWebSettingsTab() {
        XCTAssertEqual(
            ToolPermissionSettings.quickAllowedTools,
            [
                "Bash(git log:*)",
                "Bash(git diff:*)",
                "Bash(git status:*)",
                "Read",
                "Write",
                "Edit",
                "Glob",
                "Grep",
                "MultiEdit",
                "Task",
                "TodoWrite",
            ]
        )
        XCTAssertEqual(
            ToolPermissionSettings.quickBlockedTools,
            [
                "Bash(rm:*)",
                "Bash(sudo:*)",
                "WebFetch",
                "WebSearch",
            ]
        )
    }

    func testPermissionsExportDefaultsMatchWebNaming() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-05-23T23:55:00Z"))

        XCTAssertEqual(PermissionsExportDefaults.source, "g9claw")
        XCTAssertEqual(
            PermissionsExportDefaults.filename(date: date),
            "g9claw-permissions-2026-05-23.json"
        )
    }

    @MainActor
    func testPermissionsExportUsesG9ClawPayloadShape() throws {
        let state = AppState()
        state.settings.permissions.allowedTools = ["Bash(git log:*)", "MultiEdit"]
        state.settings.permissions.disallowedTools = ["Bash(rm:*)", "WebSearch"]
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("g9claw-permissions-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        try state.exportPermissions(to: url)

        let data = try Data(contentsOf: url)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(payload["version"] as? Int, 1)
        XCTAssertEqual(payload["source"] as? String, "g9claw")
        XCTAssertNotNil(payload["exportedAt"] as? String)
        XCTAssertEqual(payload["allowedTools"] as? [String], ["Bash(git log:*)", "MultiEdit"])
        XCTAssertEqual(payload["disallowedTools"] as? [String], ["Bash(rm:*)", "WebSearch"])
    }

    @MainActor
    func testPermissionsSettingsAddAndImportKeepAllowedBlockedListsIndependentLikeWeb() throws {
        let state = AppState()
        state.settings.permissions.allowedTools = ["Read"]
        state.settings.permissions.disallowedTools = ["Write"]

        state.addAllowedTool("Write")
        state.addBlockedTool("Read")

        XCTAssertEqual(state.settings.permissions.allowedTools, ["Read", "Write"])
        XCTAssertEqual(state.settings.permissions.disallowedTools, ["Write", "Read"])

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("g9claw-permissions-import-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let payload: [String: Any] = [
            "allowedTools": ["Bash(git log:*)", "WebSearch"],
            "disallowedTools": ["WebSearch", "Bash(rm:*)"],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: url)

        try state.importPermissions(from: url)

        XCTAssertEqual(state.settings.permissions.allowedTools, [
            "Read",
            "Write",
            "Bash(git log:*)",
            "WebSearch",
        ])
        XCTAssertEqual(state.settings.permissions.disallowedTools, [
            "Write",
            "Read",
            "WebSearch",
            "Bash(rm:*)",
        ])
    }

    @MainActor
    func testChatPermissionGrantStillClearsMatchingBlockedRuleLikeWebGrantButton() {
        let state = AppState()
        state.settings.permissions.allowedTools = []
        state.settings.permissions.disallowedTools = ["Write", "Bash(rm:*)"]

        state.grantAllowedToolFromChat("Write")

        XCTAssertEqual(state.settings.permissions.allowedTools, ["Write"])
        XCTAssertEqual(state.settings.permissions.disallowedTools, ["Bash(rm:*)"])
    }

    func testComposerPermissionModeStorageMatchesWebLocalStorageKeys() throws {
        let suiteName = "g9claw-permission-mode-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(ComposerPermissionModeStorage.defaultKey, "permissionMode-default")
        XCTAssertEqual(ComposerPermissionModeStorage.sessionKeyPrefix, "permissionMode-")
        XCTAssertEqual(ComposerPermissionModeStorage.storedMode(for: nil, defaults: defaults), .default)

        defaults.set("acceptEdits", forKey: ComposerPermissionModeStorage.defaultKey)
        XCTAssertEqual(ComposerPermissionModeStorage.storedMode(for: nil, defaults: defaults), .default)

        ComposerPermissionModeStorage.save(.bypassPermissions, for: nil, defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: ComposerPermissionModeStorage.defaultKey), "bypassPermissions")
        XCTAssertEqual(ComposerPermissionModeStorage.storedMode(for: nil, defaults: defaults), .bypassPermissions)
        XCTAssertEqual(ComposerPermissionModeStorage.storedMode(for: "session-a", defaults: defaults), .bypassPermissions)

        defaults.set("default", forKey: "\(ComposerPermissionModeStorage.sessionKeyPrefix)session-a")
        XCTAssertEqual(ComposerPermissionModeStorage.storedMode(for: "session-a", defaults: defaults), .default)

        ComposerPermissionModeStorage.save(.bypassPermissions, for: "session-a", defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: "\(ComposerPermissionModeStorage.sessionKeyPrefix)session-a"), "bypassPermissions")
        XCTAssertEqual(ComposerPermissionModeStorage.storedMode(for: "session-a", defaults: defaults), .bypassPermissions)
    }

    func testNativeUIPreferencesStorageMatchesWebDefaultsAndLegacyFallback() throws {
        let suiteName = "g9claw-ui-prefs-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(NativeUIPreferencesStorage.storageKey, "uiPreferences")
        XCTAssertEqual(NativeUIPreferencesStorage.storedPreferences(defaults: defaults), NativeUIPreferences())

        defaults.set("not-json", forKey: NativeUIPreferencesStorage.storageKey)
        defaults.set("false", forKey: "sidebarVisible")
        defaults.set("false", forKey: "showThinking")
        defaults.set("true", forKey: "sendByCtrlEnter")

        var preferences = NativeUIPreferencesStorage.storedPreferences(defaults: defaults)
        XCTAssertFalse(preferences.sidebarVisible)
        XCTAssertFalse(preferences.showThinking)
        XCTAssertTrue(preferences.sendByCtrlEnter)
        XCTAssertFalse(preferences.autoExpandTools)
        XCTAssertTrue(preferences.autoScrollToBottom)

        defaults.set("""
        {"sidebarVisible":true,"autoScrollToBottom":false,"showRawParameters":true,"sendByCtrlEnter":"false","showThinking":false}
        """, forKey: NativeUIPreferencesStorage.storageKey)

        preferences = NativeUIPreferencesStorage.storedPreferences(defaults: defaults)
        XCTAssertTrue(preferences.sidebarVisible)
        XCTAssertFalse(preferences.autoScrollToBottom)
        XCTAssertTrue(preferences.showRawParameters)
        XCTAssertFalse(preferences.sendByCtrlEnter)
        XCTAssertFalse(preferences.showThinking)
        XCTAssertFalse(preferences.autoExpandTools)
    }

    func testNativeUIPreferencesStorageSavesUnifiedSidebarVisibility() throws {
        let suiteName = "g9claw-ui-prefs-save-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        NativeUIPreferencesStorage.saveSidebarVisible(false, defaults: defaults)

        let storedText = try XCTUnwrap(defaults.string(forKey: NativeUIPreferencesStorage.storageKey))
        let storedData = try XCTUnwrap(storedText.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: storedData) as? [String: Bool])
        XCTAssertEqual(object["sidebarVisible"], false)
        XCTAssertEqual(object["showThinking"], true)
        XCTAssertEqual(object["autoScrollToBottom"], true)

        let preferences = NativeUIPreferencesStorage.storedPreferences(defaults: defaults)
        XCTAssertFalse(preferences.sidebarVisible)
        XCTAssertTrue(preferences.showThinking)
        XCTAssertTrue(preferences.autoScrollToBottom)
    }

    func testToolRowExpansionPolicyUsesAutoExpandToolsWithManualOverride() {
        let id = "tool:read-1"
        var expandedIDs = Set<String>()
        var collapsedIDs = Set<String>()

        XCTAssertFalse(ToolRowExpansionPolicy.isExpanded(
            id: id,
            expandedIDs: expandedIDs,
            collapsedIDs: collapsedIDs,
            autoExpandTools: false
        ))
        XCTAssertTrue(ToolRowExpansionPolicy.isExpanded(
            id: id,
            expandedIDs: expandedIDs,
            collapsedIDs: collapsedIDs,
            autoExpandTools: true
        ))

        ToolRowExpansionPolicy.toggle(
            id: id,
            expandedIDs: &expandedIDs,
            collapsedIDs: &collapsedIDs,
            autoExpandTools: true
        )
        XCTAssertTrue(collapsedIDs.contains(id))
        XCTAssertFalse(ToolRowExpansionPolicy.isExpanded(
            id: id,
            expandedIDs: expandedIDs,
            collapsedIDs: collapsedIDs,
            autoExpandTools: true
        ))

        ToolRowExpansionPolicy.toggle(
            id: id,
            expandedIDs: &expandedIDs,
            collapsedIDs: &collapsedIDs,
            autoExpandTools: true
        )
        XCTAssertTrue(expandedIDs.contains(id))
        XCTAssertFalse(collapsedIDs.contains(id))
        XCTAssertTrue(ToolRowExpansionPolicy.isExpanded(
            id: id,
            expandedIDs: expandedIDs,
            collapsedIDs: collapsedIDs,
            autoExpandTools: false
        ))
    }

    func testShellWorkingDirectoryRejectsRelativeOrMissingPaths() {
        XCTAssertThrowsError(try AgentToolExecutor.validatedWorkingDirectory("general")) { error in
            XCTAssertTrue(error.localizedDescription.contains("absolute path"))
        }
        XCTAssertThrowsError(try AgentToolExecutor.validatedWorkingDirectory("/tmp/g9claw-missing-\(UUID().uuidString)")) { error in
            XCTAssertTrue(error.localizedDescription.contains("does not exist"))
        }
    }

    func testNativeConfigServiceResolvesRouterDefaultEntry() throws {
        let yaml = """
        runtime:
          apiTimeoutMs: 90000
          contextWindow: 120000
          workspacesRoot: /Users/tester
        gateway:
          runtimePaths:
            generalCwd: /Users/tester/G9Claw/general
        models:
          providers:
            g9claw:
              type: openai-chat
              baseUrl: http://example.local/v1
              apiKey: local-secret
              headers:
                X-Test: enabled
            g9claw_router:
              type: openai-chat
              baseUrl: http://router.local/v1
              apiKey: router-secret
          entries:
            default:
              provider: g9claw
              name: qwen3.6-27b
              contextWindow: 160000
            router_small:
              provider: g9claw_router
              name: qwen3.6-35b-a3b
              contextWindow: 64000
        router:
          routes:
            default:
              model: router_small
        """

        let snapshot = try XCTUnwrap(NativeConfigService.snapshot(from: yaml))
        let routerProvider = try XCTUnwrap(NativeConfigService.providerConfig(entryID: snapshot.defaultEntryID, values: snapshot.rawValues))

        XCTAssertEqual(snapshot.mainEntryID, "default")
        XCTAssertEqual(snapshot.defaultEntryID, "router_small")
        XCTAssertEqual(snapshot.providerConfig.baseURL, "http://example.local/v1")
        XCTAssertEqual(snapshot.providerConfig.model, "qwen3.6-27b")
        XCTAssertEqual(snapshot.apiKey, "local-secret")
        XCTAssertEqual(snapshot.apiTimeoutMs, 90_000)
        XCTAssertEqual(snapshot.contextWindow, 160_000)
        XCTAssertEqual(routerProvider.baseURL, "http://router.local/v1")
        XCTAssertEqual(routerProvider.model, "qwen3.6-35b-a3b")
        XCTAssertEqual(NativeConfigService.contextWindow(entryID: snapshot.defaultEntryID, values: snapshot.rawValues), 64_000)
    }

    func testNativeConfigServiceAcceptsDirectRouterDefaultField() throws {
        let yaml = """
        models:
          providers:
            g9claw:
              type: openai-chat
              baseUrl: http://example.local/v1
            router:
              type: openai-chat
              baseUrl: http://router.local/v1
              apiKey: router-secret
          entries:
            default:
              provider: g9claw
              name: default-model
            direct_router:
              provider: router
              name: routed-model
              contextWindow: 96000
        router:
          default: direct_router
        """

        let snapshot = try XCTUnwrap(NativeConfigService.snapshot(from: yaml))
        let routerProvider = try XCTUnwrap(NativeConfigService.providerConfig(entryID: snapshot.defaultEntryID, values: snapshot.rawValues))

        XCTAssertEqual(snapshot.mainEntryID, "default")
        XCTAssertEqual(snapshot.defaultEntryID, "direct_router")
        XCTAssertEqual(snapshot.providerConfig.baseURL, "http://example.local/v1")
        XCTAssertEqual(snapshot.providerConfig.model, "default-model")
        XCTAssertNil(snapshot.apiKey)
        XCTAssertEqual(snapshot.contextWindow, 160_000)
        XCTAssertEqual(routerProvider.baseURL, "http://router.local/v1")
        XCTAssertEqual(routerProvider.model, "routed-model")
        XCTAssertEqual(NativeConfigService.contextWindow(entryID: snapshot.defaultEntryID, values: snapshot.rawValues), 96_000)
    }

    func testNativeConfigServiceUsesMainModelContextWindowLikeWebRuntimeEnv() throws {
        let yaml = """
        runtime:
          contextWindow: 131072
        models:
          providers:
            g9claw:
              type: openai-chat
              baseUrl: http://main.local/v1
          entries:
            default:
              provider: g9claw
              name: default-model
            main_large:
              provider: g9claw
              name: main-model
              contextWindow: 262144
            router_small:
              provider: g9claw
              name: router-model
              contextWindow: 64000
        agents:
          main:
            model: main_large
        router:
          enabled: false
          routes:
            default:
              model: router_small
        """

        let snapshot = try XCTUnwrap(NativeConfigService.snapshot(from: yaml))
        let values = snapshot.rawValues

        XCTAssertEqual(snapshot.mainEntryID, "main_large")
        XCTAssertEqual(snapshot.defaultEntryID, "router_small")
        XCTAssertEqual(snapshot.providerConfig.model, "main-model")
        XCTAssertEqual(snapshot.contextWindow, 262_144)
        XCTAssertEqual(NativeConfigService.contextWindow(entryID: "router_small", values: values), 64_000)
        XCTAssertEqual(
            NativeRouterRuntime.decision(forTier: "SIMPLE", values: values),
            NativeRouterRuntime.Decision(entryID: "main_large", scenario: "default", tier: nil)
        )

        let withoutMainContext = """
        runtime:
          contextWindow: 131072
        models:
          providers:
            g9claw:
              type: openai-chat
              baseUrl: http://main.local/v1
          entries:
            default:
              provider: g9claw
              name: default-model
            main_large:
              provider: g9claw
              name: main-model
        agents:
          main:
            model: main_large
        """
        XCTAssertEqual(NativeConfigService.snapshot(from: withoutMainContext)?.contextWindow, 131_072)
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
                    "delta": [
                        "reasoning_content": "thinking through it",
                        "content": "hello",
                    ],
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
            .reasoningDelta("thinking through it"),
            .contentDelta("hello"),
            .tokenBudget(used: 7, total: 160_000),
        ])
    }

    func testNativeAgentRuntimeNormalizesCCRThinkingObjectDeltas() {
        let thinkingObject: [String: Any] = [
            "choices": [
                [
                    "delta": [
                        "thinking": [
                            "content": "response summary",
                        ],
                    ],
                ],
            ],
        ]
        let signatureOnlyObject: [String: Any] = [
            "choices": [
                [
                    "delta": [
                        "thinking": [
                            "signature": "reasoning-part-id",
                        ],
                        "content": "final answer",
                    ],
                ],
            ],
        ]

        XCTAssertEqual(
            NativeAgentRuntime.openAIChatEvents(from: thinkingObject, contextWindow: 160_000),
            [.reasoningDelta("response summary")]
        )
        XCTAssertEqual(
            NativeAgentRuntime.openAIChatEvents(from: signatureOnlyObject, contextWindow: 160_000),
            [.contentDelta("final answer")]
        )
    }

    func testChatBlockVisibilityPolicyMatchesWebShowThinkingPreference() {
        XCTAssertTrue(ChatBlockVisibilityPolicy.isVisible(.reasoning("thinking"), showThinking: true))
        XCTAssertFalse(ChatBlockVisibilityPolicy.isVisible(.reasoning("thinking"), showThinking: false))
        XCTAssertTrue(ChatBlockVisibilityPolicy.isVisible(.text("answer"), showThinking: false))
        XCTAssertTrue(ChatBlockVisibilityPolicy.isVisible(.toolResult(ToolResult(toolCallId: "tool", output: "ok", isError: false)), showThinking: false))
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

    func testNativeAgentRuntimeToolSchemasIncludeG9ClawCodeCoreTools() {
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

    func testAgentToolNameCanonicalizerKeepsG9ClawCodeAndSubagentAliasesCompatible() {
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
        {"skill":"g9claw-rag:rag-research","args":"DARPA autonomous systems research"}
        """

        let calls = NativeAgentRuntime.fallbackToolCalls(in: text)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data((calls.first?.inputJSON ?? "{}").utf8)) as? [String: Any])

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "Skill")
        XCTAssertEqual(object["skill"] as? String, "g9claw-rag:rag-research")
    }

    func testNativeAgentRuntimeMapsDirectRAGToolJSONToSkill() throws {
        let text = """
        {"tool":"g9claw-rag:glm-web-search","input":{"query":"Beijing weather"}}
        """

        let calls = NativeAgentRuntime.fallbackToolCalls(in: text)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data((calls.first?.inputJSON ?? "{}").utf8)) as? [String: Any])

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "Skill")
        XCTAssertEqual(object["skill"] as? String, "g9claw-rag:glm-web-search")
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
        XCTAssertEqual(searchObject["skill"] as? String, "g9claw-rag:glm-web-search")
        XCTAssertEqual(searchObject["args"] as? String, "Beijing weather")
        XCTAssertEqual(weatherObject["skill"] as? String, "g9claw-rag:glm-web-search")
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

    func testNativeAgentRuntimeParsesG9ClawInvokeFallbackToolCall() {
        let text = """
        <invoke name="Skill">
        <parameter name="skill">g9claw-rag:rag-research</parameter>
        <parameter name="args">DARPA autonomous systems research</parameter>
        </invoke>
        """

        let calls = NativeAgentRuntime.fallbackToolCalls(in: text)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "Skill")
        let object = try? JSONSerialization.jsonObject(with: Data((calls.first?.inputJSON ?? "{}").utf8)) as? [String: Any]
        XCTAssertEqual(object?["skill"] as? String, "g9claw-rag:rag-research")
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
            .appendingPathComponent("g9claw-agent-root-\(UUID().uuidString)", isDirectory: true)
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

    func testWebBashPermissionRulesMatchNativeShellCalls() {
        var allowedPermissions = ToolPermissionSettings.defaults
        allowedPermissions.allowedTools = ["Bash(git log:*)"]
        let allowedContext = AgentRunContext(
            request: agentRequest(permissionMode: .default, toolSettings: allowedPermissions)
        )
        let gitLog = AgentToolCall(
            id: "git-log",
            name: "Shell",
            inputJSON: #"{"command":"git log --oneline"}"#
        )

        XCTAssertEqual(AgentPermissionPolicy.policy(for: gitLog, context: allowedContext), .allow)

        var blockedPermissions = ToolPermissionSettings.defaults
        blockedPermissions.disallowedTools = ["Bash(rm:*)"]
        let blockedContext = AgentRunContext(
            request: agentRequest(permissionMode: .bypassPermissions, toolSettings: blockedPermissions)
        )
        let rm = AgentToolCall(
            id: "rm-shell",
            name: "Shell",
            inputJSON: #"{"command":"rm -rf build"}"#
        )

        if case .deny(let reason) = AgentPermissionPolicy.policy(for: rm, context: blockedContext) {
            XCTAssertTrue(reason.lowercased().contains("blocked"))
        } else {
            XCTFail("Bash(...) block rules should deny matching native Shell calls.")
        }
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

    func testReadOnlyFileListingDoesNotForceSecondBootstrapAfterAnswer() {
        let request = agentRequest(prompt: "帮我看看这个路径里都有哪些文件？", permissionMode: .bypassPermissions)
        let context = AgentRunContext(request: request)

        XCTAssertTrue(
            NativeAgentRuntime.shouldForceWorkspaceBootstrap(
                request: request,
                context: context,
                assistantContent: "这个路径下有一些文件。"
            )
        )

        let call = AgentToolCall(id: "glob", name: "Glob", inputJSON: #"{"pattern":"**/*","path":"."}"#)
        context.recordToolResult(
            AgentToolResult(callId: "glob", toolName: "Glob", output: "a.docx\nb.docx", isError: false),
            call: call
        )

        XCTAssertFalse(
            NativeAgentRuntime.shouldForceWorkspaceBootstrap(
                request: request,
                context: context,
                assistantContent: "这个路径下共有 2 个文件。"
            )
        )
        XCTAssertTrue(
            CompletionGate.canFinish(
                request: request,
                context: context,
                assistantContent: "这个路径下共有 2 个文件。"
            )
        )
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
        只回答一句：G9Claw smoke test ok。

        Relevant G9Claw memory context:
        之前用户要求优化、创建、修改网页。
        """

        XCTAssertFalse(NativeAgentRuntime.isWorkspaceMutationRequest(prompt))
    }

    func testCompletionGateIgnoresInjectedMemoryContext() {
        let prompt = """
        只回答一句：smoke ok。

        Relevant G9Claw memory context:
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
            .appendingPathComponent("g9claw-agent-write-\(UUID().uuidString)", isDirectory: true)
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
        let root = try makeAgentWorkspace("g9claw-agent-read")
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
        let root = try makeAgentWorkspace("g9claw-agent-edit")
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
        let root = try makeAgentWorkspace("g9claw-agent-search")
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
        let root = try makeAgentWorkspace("g9claw-agent-disabled-search")
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
        XCTAssertTrue(search.output.contains("g9claw-rag:glm-web-search"))
        XCTAssertTrue(weather.output.contains("g9claw-rag:glm-web-search"))
        XCTAssertTrue(context.invokedSkills.contains("g9claw-rag:glm-web-search"))
        XCTAssertFalse(fetch.isError)
        XCTAssertTrue(fetch.output.contains("g9claw-rag:rag-research"))
    }

    func testAgentToolExecutorInteractionModeTodoAndTaskTools() async throws {
        let root = try makeAgentWorkspace("g9claw-agent-interaction")
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
            .appendingPathComponent("g9claw-paste-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("notes.txt")
        try "hello".write(to: fileURL, atomically: true, encoding: .utf8)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("g9claw-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([fileURL as NSURL])
        pasteboard.setString("Please inspect the attached file.", forType: .string)

        let attachments = ComposerPasteboardReader.attachments(from: pasteboard) { _ in nil }

        XCTAssertEqual(attachments.map(\.fileName), ["notes.txt"])
        XCTAssertEqual(ComposerPasteboardReader.textPayload(from: pasteboard, attachments: attachments), "Please inspect the attached file.")
    }

    func testComposerPasteboardReaderDropsFinderFileNameTextPayload() throws {
        let root = repoRootURL()
            .appendingPathComponent("g9claw-filename-paste-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("github.pptx")
        try Data("pptx".utf8).write(to: fileURL)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("g9claw-filename-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([fileURL as NSURL])
        pasteboard.setString("github.pptx", forType: .string)

        let attachments = ComposerPasteboardReader.attachments(from: pasteboard) { _ in nil }

        XCTAssertEqual(attachments.map(\.fileName), ["github.pptx"])
        XCTAssertNil(ComposerPasteboardReader.textPayload(from: pasteboard, attachments: attachments))
    }

    func testComposerPasteboardReaderParsesPlainFilePathWithoutTextPayload() throws {
        let root = repoRootURL()
            .appendingPathComponent("g9claw-path-paste-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("notes with spaces.md")
        try "# Notes".write(to: fileURL, atomically: true, encoding: .utf8)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("g9claw-path-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString(fileURL.path, forType: .string)

        let attachments = ComposerPasteboardReader.attachments(from: pasteboard) { _ in nil }

        XCTAssertEqual(attachments.map(\.fileName), ["notes with spaces.md"])
        XCTAssertNil(ComposerPasteboardReader.textPayload(from: pasteboard, attachments: attachments))
    }

    func testComposerPasteboardReaderParsesClipboardImage() throws {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("g9claw-image-\(UUID().uuidString)"))
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

    func testComposerPasteboardReaderParsesRawJPEGImageData() throws {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [:]) else {
            return XCTFail("Expected test image to produce JPEG data.")
        }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("g9claw-jpeg-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(jpeg, forType: NSPasteboard.PasteboardType("public.jpeg"))
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

    func testComposerAttachmentDeduperKeepsExistingPathAndAllowsNewPastedImages() {
        let existing = FileAttachment(id: UUID(), fileName: "notes.txt", path: "/tmp/notes.txt", mimeType: "text/plain")
        let duplicate = FileAttachment(id: UUID(), fileName: "notes copy.txt", path: "/tmp/notes.txt", mimeType: "text/plain")
        let imageOne = FileAttachment(id: UUID(), fileName: "pasted-image-1.png", path: "/tmp/pasted-image-1.png", mimeType: "image/png")
        let imageTwo = FileAttachment(id: UUID(), fileName: "pasted-image-2.png", path: "/tmp/pasted-image-2.png", mimeType: "image/png")

        let merged = ComposerAttachmentDeduper.merged([existing], with: [duplicate, imageOne, imageTwo])

        XCTAssertEqual(merged.map(\.path), [existing.path, imageOne.path, imageTwo.path])
    }

    func testComposerAttachmentPreviewModelUsesImageAndFileTypeIcons() {
        let image = FileAttachment(id: UUID(), fileName: "shot.png", path: "/tmp/shot.png", mimeType: "image/png")
        let pdf = FileAttachment(id: UUID(), fileName: "brief.pdf", path: "/tmp/brief.pdf", mimeType: "application/pdf")
        let code = FileAttachment(id: UUID(), fileName: "app.swift", path: "/tmp/app.swift", mimeType: "text/x-swift")

        XCTAssertEqual(ComposerAttachmentPreviewModel.make(for: image).systemImage, "photo")
        XCTAssertEqual(ComposerAttachmentPreviewModel.make(for: pdf).systemImage, "doc.richtext")
        XCTAssertEqual(ComposerAttachmentPreviewModel.make(for: code).systemImage, "chevron.left.forwardslash.chevron.right")
        XCTAssertEqual(ComposerAttachmentPreviewModel.make(for: code).typeLabel, "SWIFT")
    }

    func testComposerPasteShortcutPolicyMatchesPlainCommandVOnly() {
        XCTAssertTrue(ComposerPasteShortcutPolicy.isPasteShortcut(
            charactersIgnoringModifiers: "v",
            modifierFlags: [.command]
        ))
        XCTAssertTrue(ComposerPasteShortcutPolicy.isPasteShortcut(
            charactersIgnoringModifiers: "V",
            modifierFlags: [.command]
        ))
        XCTAssertFalse(ComposerPasteShortcutPolicy.isPasteShortcut(
            charactersIgnoringModifiers: "v",
            modifierFlags: [.command, .shift]
        ))
        XCTAssertFalse(ComposerPasteShortcutPolicy.isPasteShortcut(
            charactersIgnoringModifiers: "c",
            modifierFlags: [.command]
        ))
    }

    func testComposerSubmitShortcutPolicyMatchesWebSendByCtrlEnter() {
        let returnKey: UInt16 = 36
        let keypadReturnKey: UInt16 = 76

        XCTAssertTrue(ComposerSubmitShortcutPolicy.shouldSubmit(
            keyCode: returnKey,
            modifierFlags: [],
            sendByCtrlEnter: false
        ))
        XCTAssertFalse(ComposerSubmitShortcutPolicy.shouldSubmit(
            keyCode: returnKey,
            modifierFlags: [],
            sendByCtrlEnter: true
        ))
        XCTAssertTrue(ComposerSubmitShortcutPolicy.shouldSubmit(
            keyCode: returnKey,
            modifierFlags: [.control],
            sendByCtrlEnter: true
        ))
        XCTAssertTrue(ComposerSubmitShortcutPolicy.shouldSubmit(
            keyCode: keypadReturnKey,
            modifierFlags: [.command],
            sendByCtrlEnter: true
        ))
        XCTAssertFalse(ComposerSubmitShortcutPolicy.shouldSubmit(
            keyCode: returnKey,
            modifierFlags: [.shift],
            sendByCtrlEnter: false
        ))
        XCTAssertFalse(ComposerSubmitShortcutPolicy.shouldSubmit(
            keyCode: 48,
            modifierFlags: [.control],
            sendByCtrlEnter: true
        ))
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

    func testProjectWelcomePromptIncludesProjectName() {
        let english = LocalizationService(language: .english)
        let chinese = LocalizationService(language: .chineseSimplified)

        XCTAssertEqual(english.text(.projectWelcomePrompt, "G9Claw"), "Where should we move G9Claw forward today?")
        XCTAssertEqual(chinese.text(.projectWelcomePrompt, "原神"), "从「原神」开始，今天推进哪一块？")
    }

    func testAppSettingsStoreRoundTripsLanguage() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("g9claw-settings-\(UUID().uuidString)", isDirectory: true)
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

    func testNativeAppearanceSettingsLayoutMatchesWebSettingsTab() {
        XCTAssertEqual(NativeAppearanceSettingsLayout.sectionOrder, [
            .colorScheme,
            .language,
            .toolDisplay,
            .viewOptions,
            .inputSettings,
            .projectSorting,
            .codeEditor,
        ])
        XCTAssertFalse(NativeAppearanceSettingsLayout.usesDarkModeToggle)
        XCTAssertTrue(NativeAppearanceSettingsLayout.usesThemePicker)
        XCTAssertEqual(NativeAppearanceSettingsLayout.colorSchemePickerWidth, 160)
        XCTAssertEqual(NativeAppearanceSettingsLayout.fontSizeOptions, [
            10,
            11,
            12,
            13,
            14,
            15,
            16,
            18,
            20,
        ])

        XCTAssertEqual(LocalizationService.english[.colorScheme], "Theme")
        XCTAssertEqual(LocalizationService.english[.colorSchemeSystem], "Follow System")
        XCTAssertEqual(LocalizationService.chineseSimplified[.colorSchemeSystem], "系统跟随")
        XCTAssertEqual(LocalizationService.english[.colorSchemeDetail], "Follow the system appearance or choose a fixed theme.")
        XCTAssertEqual(LocalizationService.english[.displayLanguageDetail], "Choose your preferred language for the interface")
        XCTAssertEqual(LocalizationService.english[.toolDisplay], "Tool Display")
        XCTAssertEqual(LocalizationService.english[.viewOptions], "View Options")
        XCTAssertEqual(LocalizationService.english[.inputSettings], "Input Settings")
        XCTAssertEqual(LocalizationService.english[.autoExpandTools], "Auto-expand tools")
        XCTAssertEqual(LocalizationService.english[.showRawParameters], "Show raw parameters")
        XCTAssertEqual(LocalizationService.english[.showThinking], "Show thinking")
        XCTAssertEqual(LocalizationService.english[.autoScrollToBottom], "Auto-scroll to bottom")
        XCTAssertEqual(LocalizationService.english[.sendByCtrlEnter], "Send by Ctrl+Enter")
        XCTAssertEqual(LocalizationService.chineseSimplified[.sendByCtrlEnter], "使用 Ctrl+Enter 发送")
        XCTAssertEqual(LocalizationService.english[.projectSortingDetail], "How projects are ordered in the sidebar")
        XCTAssertEqual(LocalizationService.english[.lineNumbers], "Show Line Numbers")
    }

    func testCodeEditorDefaultsMatchWebSettingsController() {
        let defaults = CodeEditorPreferences.defaults

        XCTAssertEqual(defaults.wordWrap, false)
        XCTAssertEqual(defaults.showMinimap, true)
        XCTAssertEqual(defaults.lineNumbers, true)
        XCTAssertEqual(defaults.fontSize, 14)
    }

    func testNativeMemoryViewPrimaryTabsLocalizeLikeWebMemoryPanel() {
        XCTAssertEqual(NativeMemoryViewLayout.subtabOrder, [
            .projectMemory,
            .profile,
            .trace,
        ])
        XCTAssertEqual(
            NativeMemoryViewLayout.subtabOrder.map { NativeMemoryViewLayout.subtabLabel($0, language: .english) },
            [
                "Project Memory",
                "User Profile",
                "Memory Trace",
            ]
        )
        XCTAssertEqual(
            NativeMemoryViewLayout.subtabOrder.map { NativeMemoryViewLayout.subtabLabel($0, language: .chineseSimplified) },
            [
                "项目记忆",
                "用户画像",
                "记忆追踪",
            ]
        )
    }

    func testMemorySettingsSnapshotFollowsWebConfigShapeAndDefaults() {
        let yaml = """
        memory:
          enabled: false
          model: memory
          reasoningMode: accuracy_first
          autoIndexIntervalMinutes: 45
          autoDreamIntervalMinutes: 90
          captureStrategy: full_session
          includeAssistant: false
          maxMessageChars: 12000
          heartbeatBatchSize: 7
        """
        let settings = MemorySettingsSnapshot.fromConfigValues(NativeConfigService.scalarMap(from: yaml))

        XCTAssertEqual(settings.enabled, false)
        XCTAssertEqual(settings.model, "memory")
        XCTAssertEqual(settings.reasoningMode, "accuracy_first")
        XCTAssertEqual(settings.autoIndexIntervalMinutes, 45)
        XCTAssertEqual(settings.autoDreamIntervalMinutes, 90)
        XCTAssertEqual(settings.captureStrategy, "full_session")
        XCTAssertEqual(settings.includeAssistant, false)
        XCTAssertEqual(settings.maxMessageChars, 12_000)
        XCTAssertEqual(settings.heartbeatBatchSize, 7)

        let defaults = MemorySettingsSnapshot.fromConfigValues([:])
        XCTAssertEqual(defaults.enabled, true)
        XCTAssertEqual(defaults.model, "inherit")
        XCTAssertEqual(defaults.reasoningMode, "answer_first")
        XCTAssertEqual(defaults.captureStrategy, "last_turn")
        XCTAssertEqual(defaults.includeAssistant, true)
        XCTAssertEqual(defaults.maxMessageChars, 6_000)
        XCTAssertEqual(defaults.heartbeatBatchSize, 30)
    }

    func testNativeMemoryDashboardSettingsMatchWebMemoryDrawer() {
        XCTAssertEqual(NativeMemoryDashboardSettingsFields.visiblePaths, [
            "memory.autoIndexIntervalMinutes",
            "memory.autoDreamIntervalMinutes",
        ])

        XCTAssertEqual(NativeMemoryDashboardSettingsFields.normalizedInterval("45", fallback: 30), 45)
        XCTAssertEqual(NativeMemoryDashboardSettingsFields.normalizedInterval("0", fallback: 30), 0)
        XCTAssertEqual(NativeMemoryDashboardSettingsFields.normalizedInterval("-5", fallback: 30), 0)
        XCTAssertEqual(NativeMemoryDashboardSettingsFields.normalizedInterval("20000", fallback: 30), 10_080)
        XCTAssertEqual(NativeMemoryDashboardSettingsFields.normalizedInterval("bad", fallback: 30), 30)
        XCTAssertEqual(NativeMemoryDashboardSettingsFields.normalizedInterval("42.8", fallback: 30), 42)
    }

    func testMemoryDashboardSchedulerReflectsMemoryEnabledConfig() {
        let service = MemoryService()
        service.updateSettings(MemorySettingsSnapshot(enabled: false))

        let snapshot = service.dashboard(projectName: "Native")

        XCTAssertFalse(snapshot.settings.enabled)
        XCTAssertFalse(snapshot.scheduler.enabled)
        XCTAssertEqual(snapshot.scheduler.status, "disabled")
        XCTAssertFalse(snapshot.overview.schedulerEnabled)
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

    func testProcessTraceRunningToolIconIsNotPollutedByOlderFailure() {
        let assistantID = "assistant-run"
        let failedPermission = AgentActivity(
            id: "permission-old",
            sessionId: "session",
            title: "Permission denied",
            detail: "",
            phase: .edit,
            state: .failed,
            createdAt: Date().addingTimeInterval(-2),
            updatedAt: Date().addingTimeInterval(-2),
            toolName: "Write",
            anchorBlockID: assistantID
        )
        let runningWrite = AgentActivity(
            id: "write-running",
            sessionId: "session",
            title: "Running Write",
            detail: #"{"file_path":"index.html"}"#,
            phase: .edit,
            state: .running,
            createdAt: Date(),
            updatedAt: Date(),
            toolName: "Write",
            anchorBlockID: assistantID
        )

        let presentation = ProcessTracePresentation.make(
            activities: [failedPermission, runningWrite],
            isChinese: false
        )

        XCTAssertEqual(presentation.iconName, "pencil")
    }

    func testWriteToolInputPreviewDoesNotCarryFullContentIntoActivityTrace() throws {
        let content = Array(repeating: "0123456789", count: 120).joined(separator: "\n")
        let inputJSON = toolJSON(["file_path": "src/App.swift", "content": content])

        let preview = AgentToolInputPreview.activityDetail(toolName: "Write", inputJSON: inputJSON)
        let object = try jsonObject(from: preview)
        let summary = try XCTUnwrap(object["content_summary"] as? String)

        XCTAssertEqual(object["file_path"] as? String, "src/App.swift")
        XCTAssertTrue(summary.contains("bytes"))
        XCTAssertLessThan(preview.count, 900)
        XCTAssertFalse(preview.contains(content))
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
            .appendingPathComponent("g9claw-memory-\(UUID().uuidString)", isDirectory: true)
        let memoryRoot = root.appendingPathComponent(".g9claw/memory", isDirectory: true)
        try FileManager.default.createDirectory(at: memoryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        ---
        name: Launch Plan
        description: Build the first native dashboard.
        type: project
        scope: project
        project_id: current_project
        updated_at: 2026-05-23T10:00:00Z
        source_session_key: session-launch
        ---

        Ship the native Memory dashboard.
        """.write(to: memoryRoot.appendingPathComponent("launch-plan.md"), atomically: true, encoding: .utf8)

        let service = MemoryService()
        service.loadWorkspaceRecords(projectRoot: root.path, projectName: "Native")
        let snapshot = service.dashboard(projectName: "Native", projectRoot: root.path)

        XCTAssertEqual(snapshot.workspace.workspaceMode, "project")
        XCTAssertEqual(snapshot.workspace.totalProjects, 1)
        XCTAssertEqual(snapshot.workspace.projectEntries.first?.name, "Launch Plan")
        XCTAssertEqual(snapshot.workspace.projectEntries.first?.summary, "Build the first native dashboard.")
        XCTAssertEqual(snapshot.workspace.projectEntries.first?.sourceSessionKey, "session-launch")
        XCTAssertEqual(snapshot.overview.totalEntries, 1)
    }

    func testMemoryServiceLoadsG9ClawWorkspaceAndGlobalMemoryShape() throws {
        let root = repoRootURL()
            .appendingPathComponent("g9claw-memory-load-\(UUID().uuidString)", isDirectory: true)
        let memoryRoot = root.appendingPathComponent("g9claw-memory", isDirectory: true)
        let workspaceHash = MemoryService.g9clawWorkspaceHash(for: root.standardizedFileURL.path)
        let workspaceMemoryRoot = memoryRoot
            .appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent(workspaceHash, isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
        let projectMemoryRoot = workspaceMemoryRoot.appendingPathComponent("Project", isDirectory: true)
        let feedbackMemoryRoot = workspaceMemoryRoot.appendingPathComponent("Feedback", isDirectory: true)
        let globalMemoryRoot = memoryRoot
            .appendingPathComponent("global", isDirectory: true)
            .appendingPathComponent("UserIdentity", isDirectory: true)
        try FileManager.default.createDirectory(at: projectMemoryRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: feedbackMemoryRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: globalMemoryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        ---
        name: Router Cost
        description: Saved price baseline is shown in route details.
        type: project
        scope: project
        project_id: current_project
        updated_at: 2026-05-23T10:00:00Z
        source_session_key: session-router
        ---

        ## Fact
        Router pricing should display baseline and saved cost.
        """.write(to: projectMemoryRoot.appendingPathComponent("router-cost.md"), atomically: true, encoding: .utf8)
        try """
        ---
        name: Old Feedback
        description: This feedback was superseded.
        type: feedback
        scope: project
        updated_at: 2026-05-23T09:00:00Z
        deprecated: true
        ---

        Do not show this in the active list.
        """.write(to: feedbackMemoryRoot.appendingPathComponent("old-feedback.md"), atomically: true, encoding: .utf8)
        try """
        ---
        name: User Profile
        description: User prefers concise engineering updates.
        type: user
        scope: global
        updated_at: 2026-05-23T08:00:00Z
        ---

        Keep progress reports concise and factual.
        """.write(to: globalMemoryRoot.appendingPathComponent("user-profile.md"), atomically: true, encoding: .utf8)
        try """
        # Memory

        ## Project Memory
        - [Router Cost](Project/router-cost.md)
        """.write(to: workspaceMemoryRoot.appendingPathComponent("MEMORY.md"), atomically: true, encoding: .utf8)
        try """
        ---
        project_name: Web Memory Project
        description: Project metadata from g9claw memory.
        status: active
        updated_at: 2026-05-23T11:00:00Z
        ---

        ## Status
        active
        """.write(to: workspaceMemoryRoot.appendingPathComponent("project.meta.md"), atomically: true, encoding: .utf8)

        let service = MemoryService(memoryRoot: memoryRoot)
        service.loadWorkspaceRecords(projectRoot: root.path, projectName: "Native")
        let snapshot = service.dashboard(projectName: "Native", projectRoot: root.path)

        XCTAssertEqual(snapshot.records.map(\.name).sorted(), ["Old Feedback", "Router Cost", "User Profile"])
        XCTAssertEqual(snapshot.overview.userEntries, 1)
        XCTAssertEqual(snapshot.workspace.totalFiles, 1)
        XCTAssertEqual(snapshot.workspace.projectEntries.first?.relativePath, "Project/router-cost.md")
        XCTAssertEqual(snapshot.workspace.deprecatedFeedbackEntries.first?.name, "Old Feedback")
        XCTAssertEqual(service.search("session-router").first?.name, "Router Cost")
        XCTAssertEqual(service.list(kind: .feedback, projectName: "Native").count, 0)
        XCTAssertEqual(service.list(kind: .feedback, projectName: "Native", includeDeprecated: true).first?.name, "Old Feedback")
        XCTAssertEqual(service.get(ids: ["global/UserIdentity/user-profile.md"], projectName: "Native").first?.summary, "User prefers concise engineering updates.")
        XCTAssertTrue(snapshot.workspace.manifestContent.contains("[Router Cost](Project/router-cost.md)"))
        XCTAssertEqual(snapshot.workspace.projectMeta?.projectName, "Web Memory Project")
        XCTAssertEqual(snapshot.workspace.projectMeta?.status, "active")
    }

    func testMemoryCurrentProjectExportUsesWebSnapshotBundleShape() throws {
        let root = repoRootURL()
            .appendingPathComponent("g9claw-memory-export-\(UUID().uuidString)", isDirectory: true)
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        let memoryRoot = root.appendingPathComponent("g9claw-memory", isDirectory: true)
        let workspaceHash = MemoryService.g9clawWorkspaceHash(for: projectRoot.standardizedFileURL.path)
        let workspaceMemoryRoot = memoryRoot
            .appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent(workspaceHash, isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
        let projectMemoryRoot = workspaceMemoryRoot.appendingPathComponent("Project", isDirectory: true)
        let globalMemoryRoot = memoryRoot
            .appendingPathComponent("global", isDirectory: true)
            .appendingPathComponent("UserIdentity", isDirectory: true)
        try FileManager.default.createDirectory(at: projectMemoryRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: globalMemoryRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        ---
        name: Router Cost
        description: Saved price baseline is shown in route details.
        type: project
        scope: project
        project_id: current_project
        updated_at: 2026-05-23T10:00:00Z
        ---

        Router pricing should display baseline and saved cost.
        """.write(to: projectMemoryRoot.appendingPathComponent("router-cost.md"), atomically: true, encoding: .utf8)
        try "# Memory\n\nThis derived manifest is regenerated on import.\n".write(
            to: workspaceMemoryRoot.appendingPathComponent("MEMORY.md"),
            atomically: true,
            encoding: .utf8
        )
        try """
        ---
        name: User Profile
        description: Keep updates concise.
        type: user
        scope: global
        updated_at: 2026-05-23T08:00:00Z
        ---

        Global memory should not be included in current-project exports.
        """.write(to: globalMemoryRoot.appendingPathComponent("user-profile.md"), atomically: true, encoding: .utf8)

        let service = MemoryService(memoryRoot: memoryRoot)
        service.loadWorkspaceRecords(projectRoot: projectRoot.path, projectName: "Native")
        let data = try service.exportBundle(projectName: "Native", projectRoot: projectRoot.path)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let files = try XCTUnwrap(object["files"] as? [[String: Any]])
        let paths = files.compactMap { $0["relativePath"] as? String }

        XCTAssertEqual(object["formatVersion"] as? String, "clawxmemory-memory-snapshot.v4")
        XCTAssertEqual(object["scope"] as? String, "current_project")
        XCTAssertEqual(paths, ["Project/router-cost.md"])
        XCTAssertFalse(paths.contains("MEMORY.md"))
        XCTAssertFalse(paths.contains { $0.hasPrefix("global/") })
        XCTAssertTrue((files.first?["content"] as? String)?.contains("Saved price baseline") == true)
    }

    func testMemoryImportCurrentProjectWritesG9ClawWorkspaceFiles() throws {
        let root = repoRootURL()
            .appendingPathComponent("g9claw-memory-import-\(UUID().uuidString)", isDirectory: true)
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        let memoryRoot = root.appendingPathComponent("g9claw-memory", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceHash = MemoryService.g9clawWorkspaceHash(for: projectRoot.standardizedFileURL.path)
        let workspaceMemoryRoot = memoryRoot
            .appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent(workspaceHash, isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
        let content = """
        ---
        name: Imported Memory
        description: Imported from a web snapshot bundle.
        type: project
        scope: project
        project_id: current_project
        updated_at: 2026-05-23T10:00:00Z
        ---

        The native app should materialize this file under the G9Claw workspace memory root.
        """
        let bundle: [String: Any] = [
            "formatVersion": "clawxmemory-memory-snapshot.v4",
            "scope": "current_project",
            "exportedAt": "2026-05-23T10:00:00Z",
            "files": [
                [
                    "relativePath": "Project/imported-memory.md",
                    "content": content
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: bundle, options: [.sortedKeys])
        let service = MemoryService(memoryRoot: memoryRoot)

        try service.importBundle(data, projectName: "Native", projectRoot: projectRoot.path)
        let written = workspaceMemoryRoot.appendingPathComponent("Project/imported-memory.md")
        let snapshot = service.dashboard(projectName: "Native", projectRoot: projectRoot.path)

        XCTAssertTrue(FileManager.default.fileExists(atPath: written.path))
        XCTAssertEqual(snapshot.workspace.projectEntries.first?.name, "Imported Memory")
        XCTAssertTrue(snapshot.workspace.manifestContent.contains("Project/imported-memory.md"))
    }

    func testMemoryImportRejectsUnsafeSnapshotPaths() throws {
        let root = repoRootURL()
            .appendingPathComponent("g9claw-memory-unsafe-\(UUID().uuidString)", isDirectory: true)
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle: [String: Any] = [
            "formatVersion": "clawxmemory-memory-snapshot.v4",
            "scope": "current_project",
            "exportedAt": "2026-05-23T10:00:00Z",
            "files": [
                [
                    "relativePath": "../escape.md",
                    "content": "unsafe"
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: bundle, options: [.sortedKeys])
        let service = MemoryService(memoryRoot: root.appendingPathComponent("g9claw-memory", isDirectory: true))

        XCTAssertThrowsError(try service.importBundle(data, projectName: "Native", projectRoot: projectRoot.path)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Invalid files[0].relativePath"))
        }
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
            .appendingPathComponent("g9claw-memory-job-\(UUID().uuidString)", isDirectory: true)
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

    func testAlwaysOnServiceParsesWebCronAndRunHistoryShape() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("g9claw-alwayson-\(UUID().uuidString)", isDirectory: true)
        let alwaysOnRoot = root.appendingPathComponent(".g9claw/always-on", isDirectory: true)
        let plansRoot = alwaysOnRoot.appendingPathComponent("plans", isDirectory: true)
        let runsRoot = alwaysOnRoot.appendingPathComponent("runs", isDirectory: true)
        try FileManager.default.createDirectory(at: plansRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "# Plan A\n\nRun the nightly checks.".write(
            to: plansRoot.appendingPathComponent("plan-a.md"),
            atomically: true,
            encoding: .utf8
        )
        try """
        {
          "plans": [
            {
              "id": "plan-a",
              "title": "Nightly checks",
              "summary": "Check the project every night.",
              "rationale": "Keep background maintenance visible.",
              "status": "ready",
              "approvalMode": "manual",
              "planFilePath": ".g9claw/always-on/plans/plan-a.md",
              "contextRefs": {
                "workingDirectory": ["/repo"],
                "memory": ["Router parity note"],
                "recentChats": ["Session one"]
              },
              "createdAt": "2026-05-23T10:00:00Z",
              "updatedAt": "2026-05-23T10:05:00Z",
              "executionSessionId": "session-plan",
              "executionStatus": "completed"
            }
          ]
        }
        """.write(to: alwaysOnRoot.appendingPathComponent("discovery-plans.json"), atomically: true, encoding: .utf8)
        try """
        {
          "jobs": [
            {
              "id": "cron-a",
              "prompt": "# Nightly\\nRun diagnostics",
              "cron": "0 1 * * *",
              "status": "scheduled",
              "recurring": true,
              "durable": false,
              "permanent": true,
              "manualOnly": true,
              "originSessionId": "origin-session",
              "transcriptKey": "cron-transcript",
              "createdAt": 1770000000000,
              "lastFiredAt": 1770003600000,
              "latestRun": {
                "status": "running",
                "runId": "run-a",
                "startedAt": "2026-05-23T10:10:00Z",
                "sessionId": "session-a",
                "summary": "Still running",
                "lastActivity": "2026-05-23T10:11:00Z",
                "taskId": "task-a",
                "outputFile": "runs/run-a.log",
                "parentSessionId": "parent-a",
                "relativeTranscriptPath": "transcripts/session-a.jsonl",
                "transcriptKey": "run-transcript"
              }
            }
          ]
        }
        """.write(to: alwaysOnRoot.appendingPathComponent("cron-jobs.json"), atomically: true, encoding: .utf8)
        try """
        {"runId":"run-a","title":"Cron Run","kind":"cron","status":"running","startedAt":"2026-05-23T10:10:00Z","sourceId":"cron-a","outputLog":"inline log","session":{"sessionId":"session-a","parentSessionId":"parent-a","relativeTranscriptPath":"transcripts/session-a.jsonl"}}
        """.write(to: alwaysOnRoot.appendingPathComponent("run-history.jsonl"), atomically: true, encoding: .utf8)
        try "log file content".write(to: runsRoot.appendingPathComponent("run-a.log"), atomically: true, encoding: .utf8)

        let service = AlwaysOnService()
        let plans = service.plans(projectRoot: root.path)
        let cronJobs = service.cronJobs(projectRoot: root.path)
        let history = service.runHistory(projectRoot: root.path)

        XCTAssertEqual(plans.first?.id, "plan-a")
        XCTAssertEqual(plans.first?.content, "# Plan A\n\nRun the nightly checks.")
        XCTAssertEqual(plans.first?.executionStatus, .completed)
        XCTAssertEqual(plans.first?.contextRefs?["workingDirectory"], ["/repo"])
        XCTAssertEqual(plans.first?.contextRefs?["memory"], ["Router parity note"])
        XCTAssertEqual(cronJobs.first?.status, .scheduled)
        XCTAssertEqual(cronJobs.first?.durable, false)
        XCTAssertEqual(cronJobs.first?.permanent, true)
        XCTAssertEqual(cronJobs.first?.manualOnly, true)
        XCTAssertEqual(cronJobs.first?.originSessionId, "origin-session")
        XCTAssertEqual(cronJobs.first?.transcriptKey, "cron-transcript")
        XCTAssertEqual(cronJobs.first?.latestSessionId, "session-a")
        XCTAssertEqual(cronJobs.first?.latestRun?.parentSessionId, "parent-a")
        XCTAssertEqual(cronJobs.first?.latestRun?.relativeTranscriptPath, "transcripts/session-a.jsonl")
        XCTAssertEqual(history.first?.sessionId, "session-a")
        XCTAssertEqual(history.first?.parentSessionId, "parent-a")
        XCTAssertEqual(history.first?.relativeTranscriptPath, "transcripts/agent-session-a.jsonl")
        XCTAssertEqual(history.first?.outputLog, "log file content")
    }

    func testAlwaysOnServiceCreatesPlanAndRunHistoryRoundTrip() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("g9claw-alwayson-roundtrip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = AlwaysOnService()
        let plan = try service.createDiscoveryPlan(
            projectRoot: root.path,
            title: "Review dependencies",
            prompt: "Check dependency health weekly."
        )
        let run = try service.startPlanRun(plan: plan, projectRoot: root.path, sessionId: "session-run")
        let plans = service.plans(projectRoot: root.path)
        let history = service.runHistory(projectRoot: root.path)

        XCTAssertEqual(plans.first?.id, plan.id)
        XCTAssertEqual(plans.first?.status, .running)
        XCTAssertEqual(history.first?.id, run.id)
        XCTAssertEqual(history.first?.sessionId, "session-run")
        XCTAssertTrue(history.first?.outputLog.contains("Started native Always-On plan run") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".g9claw/always-on", isDirectory: true).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".claude", isDirectory: true).path))
    }

    func testAlwaysOnServiceReadsWebG9ClawAlwaysOnAndCronTaskFiles() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("g9claw-alwayson-g9claw-\(UUID().uuidString)", isDirectory: true)
        let alwaysOnRoot = root.appendingPathComponent(".g9claw/always-on", isDirectory: true)
        let plansRoot = alwaysOnRoot.appendingPathComponent("plans", isDirectory: true)
        let runsRoot = alwaysOnRoot.appendingPathComponent("runs", isDirectory: true)
        try FileManager.default.createDirectory(at: plansRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".g9claw", isDirectory: true), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "# Web Plan\n\nUse the web Always-On root.".write(
            to: plansRoot.appendingPathComponent("plan-web.md"),
            atomically: true,
            encoding: .utf8
        )
        try """
        {
          "plans": [
            {
              "id": "plan-web",
              "title": "Web root plan",
              "summary": "Plan stored in .g9claw.",
              "rationale": "Matches the web UI storage path.",
              "status": "ready",
              "approvalMode": "manual",
              "planFilePath": ".g9claw/always-on/plans/plan-web.md",
              "createdAt": "2026-05-23T10:00:00Z",
              "updatedAt": "2026-05-23T10:05:00Z"
            }
          ]
        }
        """.write(to: alwaysOnRoot.appendingPathComponent("discovery-plans.json"), atomically: true, encoding: .utf8)
        try """
        {"runId":"run-web","title":"Support scan","kind":"cron","status":"completed","startedAt":"2026-05-23T10:10:00Z","sourceId":"cron-durable","session":{"sessionId":"background-session","parentSessionId":"parent-session","relativeTranscriptPath":"parent-session/subagents/agent-cron.jsonl"}}
        """.write(to: alwaysOnRoot.appendingPathComponent("run-history.jsonl"), atomically: true, encoding: .utf8)
        try "web log content".write(to: runsRoot.appendingPathComponent("run-web.log"), atomically: true, encoding: .utf8)
        try """
        {
          "tasks": [
            {
              "id": "cron-durable",
              "cron": "*/15 * * * *",
              "prompt": "# Support scan\\nReview incoming support spikes",
              "createdAt": 1770000000000,
              "recurring": true,
              "originSessionId": "origin-durable",
              "transcriptKey": "cron-durable-key"
            }
          ]
        }
        """.write(to: root.appendingPathComponent(".g9claw/scheduled_tasks.json"), atomically: true, encoding: .utf8)
        try """
        {
          "tasks": [
            {
              "id": "cron-session",
              "cron": "0 9 * * *",
              "prompt": "Follow up on the stale TODOs",
              "createdAt": 1770003600000,
              "manualOnly": true,
              "originSessionId": "origin-session"
            }
          ]
        }
        """.write(to: root.appendingPathComponent(".g9claw/session_scheduled_tasks.json"), atomically: true, encoding: .utf8)

        let service = AlwaysOnService()
        let plans = service.plans(projectRoot: root.path)
        let history = service.runHistory(projectRoot: root.path)
        let jobsByID = Dictionary(uniqueKeysWithValues: service.cronJobs(projectRoot: root.path).map { ($0.id, $0) })

        XCTAssertEqual(plans.first?.planFilePath, ".g9claw/always-on/plans/plan-web.md")
        XCTAssertEqual(plans.first?.content, "# Web Plan\n\nUse the web Always-On root.")
        XCTAssertEqual(history.first?.outputLog, "web log content")
        XCTAssertEqual(jobsByID["cron-durable"]?.durable, true)
        XCTAssertEqual(jobsByID["cron-durable"]?.status, .scheduled)
        XCTAssertEqual(jobsByID["cron-durable"]?.latestRun?.runId, "run-web")
        XCTAssertEqual(jobsByID["cron-durable"]?.latestRun?.parentSessionId, "parent-session")
        XCTAssertEqual(jobsByID["cron-session"]?.durable, false)
        XCTAssertEqual(jobsByID["cron-session"]?.manualOnly, true)
    }

    func testAlwaysOnServiceStartsAndDeletesWebCronJobs() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("g9claw-alwayson-cron-actions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".g9claw", isDirectory: true), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        {
          "tasks": [
            {
              "id": "cron-run-now",
              "cron": "*/5 * * * *",
              "prompt": "# Run now\\nCheck status",
              "createdAt": 1770000000000,
              "recurring": true
            },
            {
              "id": "cron-delete",
              "cron": "0 0 * * *",
              "prompt": "Remove me",
              "createdAt": 1770000000000,
              "recurring": true
            }
          ]
        }
        """.write(to: root.appendingPathComponent(".g9claw/scheduled_tasks.json"), atomically: true, encoding: .utf8)

        let service = AlwaysOnService()
        let job = try XCTUnwrap(service.cronJobs(projectRoot: root.path).first { $0.id == "cron-run-now" })
        let run = try service.startCronRun(job: job, projectRoot: root.path, sessionId: "session-run-now")
        let refreshed = try XCTUnwrap(service.cronJobs(projectRoot: root.path).first { $0.id == "cron-run-now" })

        XCTAssertEqual(refreshed.status, .running)
        XCTAssertEqual(refreshed.latestRun?.runId, run.id)
        XCTAssertEqual(refreshed.latestRun?.sessionId, "session-run-now")
        XCTAssertEqual(service.runHistory(projectRoot: root.path).first?.sourceId, "cron-run-now")
        XCTAssertEqual(service.runLog(projectRoot: root.path, runID: run.id).source, .logFile)

        XCTAssertTrue(try service.deleteCronJob(jobID: "cron-delete", projectRoot: root.path))
        XCTAssertNil(service.cronJobs(projectRoot: root.path).first { $0.id == "cron-delete" })
    }

    func testAlwaysOnServiceFoldsRunHistoryEventsAndPreservesMetadata() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("g9claw-alwayson-run-history-fold-\(UUID().uuidString)", isDirectory: true)
        let alwaysOnRoot = root.appendingPathComponent(".g9claw/always-on", isDirectory: true)
        try FileManager.default.createDirectory(at: alwaysOnRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let lines = [
            """
            {"runId":"run-1","kind":"plan","sourceId":"plan-alpha","title":"Plan Alpha","status":"queued","timestamp":"2026-04-20T10:00:00.000Z","metadata":{"source":"manual"}}
            """,
            """
            {"runId":"run-1","kind":"plan","sourceId":"plan-alpha","title":"Plan Alpha","status":"completed","timestamp":"2026-04-20T10:05:00.000Z","finishedAt":"2026-04-20T10:05:00.000Z","sessionId":"session-1","output":"Done.","metadata":{"planFilePath":".g9claw/always-on/plans/plan-alpha.md"}}
            """,
            "not json",
        ].joined(separator: "\n") + "\n"
        try lines.write(to: alwaysOnRoot.appendingPathComponent("run-history.jsonl"), atomically: true, encoding: .utf8)

        let service = AlwaysOnService()
        let history = service.runHistory(projectRoot: root.path)
        let detail = try XCTUnwrap(service.runHistoryDetail(projectRoot: root.path, runID: "run-1"))

        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.id, "run-1")
        XCTAssertEqual(history.first?.status, .completed)
        XCTAssertEqual(history.first?.sessionId, "session-1")
        XCTAssertEqual(detail.outputLog, "Done.")
        XCTAssertEqual(detail.metadata["source"], "manual")
        XCTAssertEqual(detail.metadata["planFilePath"], ".g9claw/always-on/plans/plan-alpha.md")
        XCTAssertEqual(detail.metadata["logSource"], "history")
        XCTAssertEqual(detail.metadata["finishedAt"], "2026-04-20T10:05:00Z")
    }

    func testAlwaysOnServiceDerivesBackgroundSessionAndFiltersUnknownHistoryLikeWeb() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("g9claw-alwayson-run-history-session-\(UUID().uuidString)", isDirectory: true)
        let alwaysOnRoot = root.appendingPathComponent(".g9claw/always-on", isDirectory: true)
        try FileManager.default.createDirectory(at: alwaysOnRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let lines = [
            """
            {"runId":"run-cron","kind":"cron","sourceId":"cron-alpha","title":"Cron Alpha","status":"completed","timestamp":"2026-04-20T10:00:00.000Z","parentSessionId":"origin-session","relativeTranscriptPath":"origin-session/subagents/agent-cron-thread.jsonl"}
            """,
            """
            {"runId":"run-metadata","kind":"cron","sourceId":"cron-beta","title":"Cron Beta","status":"completed","timestamp":"2026-04-20T10:01:00.000Z","metadata":{"originSessionId":"origin-session","transcriptKey":"cron-thread-raw"}}
            """,
            """
            {"runId":"run-hidden","kind":"cron","sourceId":"cron-hidden","title":"Hidden","status":"unknown","timestamp":"2026-04-20T10:02:00.000Z"}
            """,
        ].joined(separator: "\n") + "\n"
        try lines.write(to: alwaysOnRoot.appendingPathComponent("run-history.jsonl"), atomically: true, encoding: .utf8)

        let service = AlwaysOnService()
        let historyIDs = service.runHistory(projectRoot: root.path).map(\.id)
        let cronDetail = try XCTUnwrap(service.runHistoryDetail(projectRoot: root.path, runID: "run-cron"))
        let metadataDetail = try XCTUnwrap(service.runHistoryDetail(projectRoot: root.path, runID: "run-metadata"))
        let hiddenDetail = try XCTUnwrap(service.runHistoryDetail(projectRoot: root.path, runID: "run-hidden"))

        XCTAssertFalse(historyIDs.contains("run-hidden"))
        XCTAssertEqual(cronDetail.sessionId, "background-origin-session-agent-cron-thread")
        XCTAssertEqual(cronDetail.metadata["sessionId"], "background-origin-session-agent-cron-thread")
        XCTAssertEqual(metadataDetail.sessionId, "background-origin-session-agent-cron-thread-raw")
        XCTAssertEqual(metadataDetail.parentSessionId, "origin-session")
        XCTAssertEqual(metadataDetail.relativeTranscriptPath, "origin-session/subagents/agent-cron-thread-raw.jsonl")
        XCTAssertEqual(hiddenDetail.status, .unknown)
    }

    func testAlwaysOnRunHistoryDetailPrefersDedicatedLogAndPollsOnlyQueuedOrRunning() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("g9claw-alwayson-run-history-log-\(UUID().uuidString)", isDirectory: true)
        let alwaysOnRoot = root.appendingPathComponent(".g9claw/always-on", isDirectory: true)
        let runsRoot = alwaysOnRoot.appendingPathComponent("runs", isDirectory: true)
        try FileManager.default.createDirectory(at: runsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        {"runId":"run-log","kind":"plan","sourceId":"plan-log","title":"Plan Log","status":"running","timestamp":"2026-04-20T10:00:00.000Z","output":"history output"}
        """.write(to: alwaysOnRoot.appendingPathComponent("run-history.jsonl"), atomically: true, encoding: .utf8)
        try "dedicated log output\n".write(to: runsRoot.appendingPathComponent("run-log.log"), atomically: true, encoding: .utf8)

        let detail = try XCTUnwrap(AlwaysOnService().runHistoryDetail(projectRoot: root.path, runID: "run-log"))

        XCTAssertEqual(detail.outputLog, "dedicated log output\n")
        XCTAssertEqual(detail.metadata["logSource"], "log-file")
        XCTAssertEqual(detail.metadata["logSize"], String("dedicated log output\n".utf8.count))
        XCTAssertTrue(detail.shouldPollLog)
        XCTAssertFalse(AlwaysOnRunHistory(
            id: "run-complete",
            title: "Complete",
            kind: "plan",
            status: .completed,
            startedAt: Date(),
            sourceId: "plan-complete",
            outputLog: "",
            sessionId: nil,
            parentSessionId: nil,
            relativeTranscriptPath: nil
        ).shouldPollLog)
    }

    func testNativeAlwaysOnRowsMatchWebItemsFilteringSortingAndActions() throws {
        let base = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-05-23T12:00:00Z"))
        func plan(
            _ id: String,
            status: AlwaysOnStatus,
            updatedOffset: TimeInterval,
            executionSessionId: String? = nil,
            executionStatus: AlwaysOnStatus? = nil
        ) -> AlwaysOnPlan {
            AlwaysOnPlan(
                id: id,
                title: id,
                summary: "",
                rationale: "",
                content: "",
                status: status,
                approvalMode: "manual",
                planFilePath: ".g9claw/always-on/plans/\(id).md",
                createdAt: base.addingTimeInterval(-1_000),
                updatedAt: base.addingTimeInterval(updatedOffset),
                executionSessionId: executionSessionId,
                executionStatus: executionStatus
            )
        }
        func cron(
            _ id: String,
            status: AlwaysOnStatus,
            recurring: Bool,
            durable: Bool = true,
            manualOnly: Bool = false,
            createdOffset: TimeInterval = -800,
            firedOffset: TimeInterval? = nil,
            latestActivityOffset: TimeInterval? = nil
        ) -> AlwaysOnCronJob {
            AlwaysOnCronJob(
                id: id,
                prompt: "# \(id)\nDo work",
                cron: "0 1 * * *",
                status: status,
                recurring: recurring,
                durable: durable,
                createdAt: base.addingTimeInterval(createdOffset),
                lastFiredAt: firedOffset.map { base.addingTimeInterval($0) },
                latestSessionId: nil,
                permanent: false,
                manualOnly: manualOnly,
                originSessionId: nil,
                transcriptKey: nil,
                latestRun: latestActivityOffset.map {
                    AlwaysOnCronLatestRun(
                        status: status,
                        runId: "run-\(id)",
                        startedAt: base.addingTimeInterval($0 - 30),
                        sessionId: "session-\(id)",
                        summary: id,
                        lastActivity: base.addingTimeInterval($0),
                        taskId: id,
                        outputFile: ".g9claw/always-on/runs/run-\(id).log",
                        parentSessionId: nil,
                        relativeTranscriptPath: nil,
                        transcriptKey: nil
                    )
                }
            )
        }

        let rows = NativeAlwaysOnRows.rows(
            plans: [
                plan("ready-old", status: .ready, updatedOffset: -300),
                plan("ready-with-session", status: .ready, updatedOffset: -60, executionSessionId: "session-existing"),
                plan("running-plan", status: .running, updatedOffset: -120),
                plan("queued-execution", status: .ready, updatedOffset: -90, executionStatus: .queued),
                plan("completed-hidden", status: .completed, updatedOffset: 120),
                plan("superseded-hidden", status: .superseded, updatedOffset: 110),
                plan("execution-completed-hidden", status: .ready, updatedOffset: 100, executionStatus: .completed),
            ],
            cronJobs: [
                cron("scheduled-cron", status: .scheduled, recurring: false, createdOffset: -600),
                cron("completed-one-shot-hidden", status: .completed, recurring: false, latestActivityOffset: -5),
                cron("completed-recurring", status: .completed, recurring: true, latestActivityOffset: -10),
                cron("manual-session-cron", status: .scheduled, recurring: false, durable: false, manualOnly: true, firedOffset: -20),
            ]
        )

        XCTAssertEqual(rows.map(\.id), [
            "cron:completed-recurring",
            "cron:manual-session-cron",
            "plan:ready-with-session",
            "plan:queued-execution",
            "plan:running-plan",
            "plan:ready-old",
            "cron:scheduled-cron",
        ])
        XCTAssertFalse(rows.contains { $0.id.contains("completed-hidden") })
        XCTAssertFalse(rows.contains { $0.id.contains("superseded-hidden") })
        XCTAssertEqual(rows.first?.completedAt, base.addingTimeInterval(-10))
        XCTAssertEqual(rows.first?.title, "completed-recurring")
        XCTAssertEqual(rows.first?.typeLabel, "persistent / recurring")

        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        XCTAssertTrue(byID["plan:ready-old"]?.canRun == true)
        XCTAssertFalse(byID["plan:ready-with-session"]?.canRun == true)
        XCTAssertFalse(byID["plan:running-plan"]?.canRun == true)
        XCTAssertFalse(byID["plan:running-plan"]?.canArchiveOrDelete == true)
        XCTAssertTrue(byID["plan:queued-execution"]?.canRun == true)
        XCTAssertFalse(byID["plan:queued-execution"]?.canArchiveOrDelete == true)
        XCTAssertTrue(byID["cron:manual-session-cron"]?.canRun == true)
        XCTAssertTrue(byID["cron:manual-session-cron"]?.canArchiveOrDelete == true)
        XCTAssertEqual(byID["cron:manual-session-cron"]?.typeLabel, "session-scope / one-shot / manual")
    }

    func testNativeAlwaysOnItemsRowsMatchWebTableColumnsDateLabelsAndCronViewAction() throws {
        let createdAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-05-23T10:00:00Z"))
        let triggeredAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-05-23T11:00:00Z"))
        let completedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-05-23T12:00:00Z"))
        let plan = AlwaysOnPlan(
            id: "plan-a",
            title: "Plan Alpha",
            summary: "",
            rationale: "",
            content: "",
            status: .ready,
            approvalMode: "manual",
            planFilePath: ".g9claw/always-on/plans/plan-a.md",
            createdAt: createdAt,
            updatedAt: triggeredAt,
            executionSessionId: nil,
            executionStatus: nil
        )
        let cronJob = AlwaysOnCronJob(
            id: "cron-a",
            prompt: "# Cron Alpha",
            cron: "0 1 * * *",
            status: .scheduled,
            recurring: false,
            durable: true,
            createdAt: createdAt,
            lastFiredAt: triggeredAt,
            latestSessionId: "session-a",
            permanent: false,
            manualOnly: false,
            originSessionId: "origin-a",
            transcriptKey: "agent-a.jsonl",
            latestRun: AlwaysOnCronLatestRun(
                status: .completed,
                runId: "run-a",
                startedAt: triggeredAt,
                sessionId: "session-a",
                summary: "done",
                lastActivity: completedAt,
                taskId: "task-a",
                outputFile: ".g9claw/always-on/runs/run-a.log",
                parentSessionId: "origin-a",
                relativeTranscriptPath: "origin-a/subagents/agent-a.jsonl",
                transcriptKey: "agent-a.jsonl"
            )
        )

        XCTAssertEqual(NativeAlwaysOnItemsRows.columns(), ["Title", "Type", "Status", "Created", "Triggered", "Completed", ""])
        XCTAssertEqual(NativeAlwaysOnItemsRows.columns(language: .chineseSimplified), ["标题", "类型", "状态", "创建", "触发", "完成", ""])

        let planRow = NativeAlwaysOnItemsRows.row(NativeAlwaysOnRow(
            kind: .plan,
            id: "plan:plan-a",
            title: plan.title,
            typeLabel: "plan",
            statusLabel: plan.status.rawValue,
            createdAt: plan.createdAt,
            triggeredAt: nil,
            completedAt: nil,
            sortAt: plan.updatedAt,
            plan: plan,
            cronJob: nil
        ))
        XCTAssertEqual(planRow.title, "Plan Alpha")
        XCTAssertEqual(planRow.type, "plan")
        XCTAssertEqual(planRow.status, "ready")
        XCTAssertTrue(planRow.created.contains("05/23"))
        XCTAssertEqual(planRow.triggered, "—")
        XCTAssertEqual(planRow.completed, "—")
        XCTAssertTrue(planRow.canRun)
        XCTAssertTrue(planRow.canArchiveOrDelete)
        XCTAssertFalse(planRow.canOpenCronSession)

        let cronRow = NativeAlwaysOnItemsRows.row(NativeAlwaysOnRow(
            kind: .cron,
            id: "cron:cron-a",
            title: "Cron Alpha",
            typeLabel: "persistent / one-shot",
            statusLabel: cronJob.status.rawValue,
            createdAt: createdAt,
            triggeredAt: triggeredAt,
            completedAt: completedAt,
            sortAt: completedAt,
            plan: nil,
            cronJob: cronJob
        ))
        XCTAssertEqual(cronRow.title, "Cron Alpha")
        XCTAssertEqual(cronRow.type, "persistent / one-shot")
        XCTAssertEqual(cronRow.status, "scheduled")
        XCTAssertTrue(cronRow.triggered.contains("05/23"))
        XCTAssertTrue(cronRow.completed.contains("05/23"))
        XCTAssertTrue(cronRow.canRun)
        XCTAssertTrue(cronRow.canArchiveOrDelete)
        XCTAssertTrue(cronRow.canOpenCronSession)

        var cronWithoutTranscript = cronJob
        cronWithoutTranscript.latestRun = AlwaysOnCronLatestRun(
            status: .completed,
            runId: "run-b",
            startedAt: triggeredAt,
            sessionId: "session-a",
            summary: nil,
            lastActivity: completedAt,
            taskId: nil,
            outputFile: nil,
            parentSessionId: nil,
            relativeTranscriptPath: nil,
            transcriptKey: nil
        )
        XCTAssertFalse(NativeAlwaysOnItemsRows.canOpenCronSession(NativeAlwaysOnRow(
            kind: .cron,
            id: "cron:cron-b",
            title: "Cron Without Transcript",
            typeLabel: "persistent / one-shot",
            statusLabel: cronWithoutTranscript.status.rawValue,
            createdAt: createdAt,
            triggeredAt: triggeredAt,
            completedAt: completedAt,
            sortAt: completedAt,
            plan: nil,
            cronJob: cronWithoutTranscript
        )))
    }

    func testNativeAlwaysOnChromeCopyAndUpdatedLabelMatchesWeb() throws {
        let english = LocalizationService(language: .english)
        let chinese = LocalizationService(language: .chineseSimplified)

        XCTAssertEqual(english.text(.alwaysOn), "Always-on")
        XCTAssertEqual(english.text(.backgroundDiscoveryAgent), "Background discovery agent for this project.")
        XCTAssertEqual(english.text(.plansCronJobs), "Plans & Cron Jobs")
        XCTAssertEqual(english.text(.discover), "Discover")
        XCTAssertEqual(english.text(.alwaysOnProjectOnly), "Pick a project to view Always-on.")
        XCTAssertEqual(chinese.text(.alwaysOn), "常驻")
        XCTAssertEqual(chinese.text(.backgroundDiscoveryAgent), "为该项目持续运行的后台发现代理。")
        XCTAssertEqual(chinese.text(.plansCronJobs), "计划与定时任务")
        XCTAssertEqual(chinese.text(.discover), "扫描")
        XCTAssertEqual(chinese.text(.alwaysOnProjectOnly), "选择一个项目以查看常驻。")

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-05-23T12:00:00Z"))
        XCTAssertEqual(
            NativeAlwaysOnUpdatedLabel.updatedText(now.addingTimeInterval(-30), now: now),
            "Updated just now"
        )
        XCTAssertEqual(
            NativeAlwaysOnUpdatedLabel.updatedText(now.addingTimeInterval(-90), now: now),
            "Updated 2m ago"
        )
        XCTAssertEqual(
            NativeAlwaysOnUpdatedLabel.updatedText(now.addingTimeInterval(-90 * 60), language: .chineseSimplified, now: now),
            "更新于 2 小时前"
        )
        XCTAssertEqual(
            NativeAlwaysOnUpdatedLabel.updatedText(now.addingTimeInterval(-36 * 60 * 60), now: now),
            "Updated 2d ago"
        )
        XCTAssertEqual(NativeAlwaysOnUpdatedLabel.updatedText(nil, now: now), "Updated —")
    }

    func testNativeAlwaysOnPlanDetailPresentationMatchesWebSectionsAndContextRefs() throws {
        let createdAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-05-23T10:00:00Z"))
        let updatedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-05-23T12:00:00Z"))
        let plan = AlwaysOnPlan(
            id: "plan-a",
            title: "  ",
            summary: "Check router drift.",
            rationale: "Keep parity visible.",
            content: "# Plan",
            status: .ready,
            approvalMode: "manual",
            planFilePath: " .g9claw/always-on/plans/plan-a.md ",
            contextRefs: [
                "workingDirectory": ["/repo"],
                "memory": ["Router parity note"],
                "existingPlans": ["Ignored by the Web detail renderer"],
                "cronJobs": [],
                "recentChats": ["Session 1"],
            ],
            createdAt: createdAt,
            updatedAt: updatedAt,
            executionSessionId: nil,
            executionStatus: nil
        )

        XCTAssertEqual(NativeAlwaysOnPlanDetailPresentation.detailTitle(plan), "plan-a")
        XCTAssertEqual(NativeAlwaysOnPlanDetailPresentation.sectionTitle(.summary), "Summary")
        XCTAssertEqual(NativeAlwaysOnPlanDetailPresentation.sectionTitle(.planMarkdown, language: .chineseSimplified), "Plan Markdown")
        XCTAssertEqual(NativeAlwaysOnPlanDetailPresentation.sectionTitle(.contextRefs, language: .chineseSimplified), "上下文引用")
        XCTAssertEqual(
            NativeAlwaysOnPlanDetailPresentation.fileLocation(projectRoot: "/Users/tester/repo/", planFilePath: plan.planFilePath),
            "/Users/tester/repo/.g9claw/always-on/plans/plan-a.md"
        )
        XCTAssertEqual(
            NativeAlwaysOnPlanDetailPresentation.fileLocation(projectRoot: "/repo", planFilePath: "/tmp/plan.md"),
            "/tmp/plan.md"
        )
        XCTAssertEqual(NativeAlwaysOnPlanDetailPresentation.fileLocation(projectRoot: "", planFilePath: "  "), "—")

        let englishMeta = NativeAlwaysOnPlanDetailPresentation.metaItems(plan, projectRoot: "/Users/tester/repo")
        XCTAssertEqual(englishMeta[0].0, "File location")
        XCTAssertEqual(englishMeta[1].0, "Created")
        XCTAssertEqual(englishMeta[2].0, "Updated")
        XCTAssertTrue(englishMeta[1].1.contains("05/23"))

        let chineseGroups = NativeAlwaysOnPlanDetailPresentation.contextRefGroups(plan, language: .chineseSimplified)
        XCTAssertEqual(chineseGroups.map(\.key), ["workingDirectory", "memory", "recentChats"])
        XCTAssertEqual(chineseGroups.map(\.label), ["工作目录", "记忆", "近期对话"])
        XCTAssertEqual(chineseGroups[1].values, ["Router parity note"])
    }

    func testNativeAlwaysOnCronLabelsMatchWebDetailHelpers() {
        func cron(
            prompt: String,
            cronExpression: String = "0 1 * * *",
            recurring: Bool = false,
            durable: Bool = true,
            permanent: Bool = false,
            manualOnly: Bool = false
        ) -> AlwaysOnCronJob {
            AlwaysOnCronJob(
                id: "cron-a",
                prompt: prompt,
                cron: cronExpression,
                status: .scheduled,
                recurring: recurring,
                durable: durable,
                createdAt: nil,
                lastFiredAt: nil,
                latestSessionId: nil,
                permanent: permanent,
                manualOnly: manualOnly,
                originSessionId: nil,
                transcriptKey: nil,
                latestRun: nil
            )
        }

        let headingJob = cron(prompt: "# Nightly scan ###\nReview workspace")
        XCTAssertEqual(NativeAlwaysOnCronLabels.promptTitle(headingJob.prompt), "Nightly scan")
        XCTAssertEqual(NativeAlwaysOnCronLabels.rowTitle(headingJob), "Nightly scan")

        let nonHeadingJob = cron(prompt: "  ## Not H1\nBody  ")
        XCTAssertEqual(NativeAlwaysOnCronLabels.promptTitle(nonHeadingJob.prompt), "")
        XCTAssertEqual(NativeAlwaysOnCronLabels.rowTitle(nonHeadingJob), "## Not H1\nBody")

        XCTAssertEqual(NativeAlwaysOnCronLabels.rowTitle(cron(prompt: "", cronExpression: "*/15 * * * *")), "*/15 * * * *")

        let longTitle = String(repeating: "a", count: 80)
        XCTAssertEqual(
            NativeAlwaysOnCronLabels.rowTitle(cron(prompt: "# \(longTitle)")),
            "\(String(repeating: "a", count: 55))…"
        )

        let manualSessionJob = cron(prompt: "# Manual", recurring: false, durable: false, permanent: true, manualOnly: true)
        XCTAssertEqual(NativeAlwaysOnCronLabels.typeLabel(manualSessionJob), "session-scope / one-shot / manual")
        XCTAssertEqual(NativeAlwaysOnCronLabels.triggerLabel(manualSessionJob), "One-shot / Manual only / Permanent")
        XCTAssertEqual(NativeAlwaysOnCronLabels.scopeLabel(manualSessionJob), "Session-scope")
        XCTAssertEqual(NativeAlwaysOnCronLabels.triggerLabel(manualSessionJob, language: .chineseSimplified), "单次触发 / 仅手动 / 永久")
        XCTAssertEqual(NativeAlwaysOnCronLabels.scopeLabel(cron(prompt: "# Durable"), language: .chineseSimplified), "持久")
    }

    func testNativeAlwaysOnCronDetailPresentationMatchesWebFieldsAndSessionTarget() throws {
        let createdAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-05-23T10:00:00Z"))
        let firedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-05-23T11:00:00Z"))
        let job = AlwaysOnCronJob(
            id: "cron-a",
            prompt: "# Cron Alpha\nRun diagnostics",
            cron: "0 1 * * *",
            status: .scheduled,
            recurring: true,
            durable: false,
            createdAt: createdAt,
            lastFiredAt: firedAt,
            latestSessionId: "session-a",
            permanent: true,
            manualOnly: true,
            originSessionId: "origin-a",
            transcriptKey: "cron-key",
            latestRun: AlwaysOnCronLatestRun(
                status: .completed,
                runId: "run-a",
                startedAt: createdAt,
                sessionId: "session-a",
                summary: "Latest cron summary",
                lastActivity: firedAt,
                taskId: "task-a",
                outputFile: "runs/run-a.log",
                parentSessionId: "origin-a",
                relativeTranscriptPath: "origin-a/subagents/agent-a.jsonl",
                transcriptKey: "agent-a.jsonl"
            )
        )

        XCTAssertEqual(NativeAlwaysOnCronDetailPresentation.sectionTitle(.prompt), "Prompt")
        XCTAssertEqual(NativeAlwaysOnCronDetailPresentation.sectionTitle(.schedule, language: .chineseSimplified), "调度配置")
        XCTAssertEqual(NativeAlwaysOnCronDetailPresentation.promptText(AlwaysOnCronJob(
            id: "empty-cron",
            prompt: "",
            cron: "0 2 * * *",
            status: .scheduled,
            recurring: false,
            durable: true,
            createdAt: nil,
            lastFiredAt: nil,
            latestSessionId: nil,
            originSessionId: nil,
            transcriptKey: nil,
            latestRun: nil
        )), "")

        let schedule = NativeAlwaysOnCronDetailPresentation.scheduleItems(job)
        XCTAssertEqual(schedule.map(\.0), [
            "Cron expression",
            "Current status",
            "Trigger type",
            "Scope",
            "Created",
            "Last fired",
        ])
        XCTAssertEqual(schedule[0].1, "0 1 * * *")
        XCTAssertEqual(schedule[1].1, "scheduled")
        XCTAssertEqual(schedule[2].1, "Recurring / Manual only / Permanent")
        XCTAssertEqual(schedule[3].1, "Session-scope")
        XCTAssertTrue(schedule[4].1.contains("05/23"))
        XCTAssertTrue(schedule[5].1.contains("05/23"))

        let chineseSchedule = NativeAlwaysOnCronDetailPresentation.scheduleItems(job, language: .chineseSimplified)
        XCTAssertEqual(chineseSchedule.map(\.0), ["Cron 表达式", "当前状态", "触发类型", "持久性范围", "创建时间", "上次触发"])
        XCTAssertEqual(chineseSchedule[2].1, "重复触发 / 仅手动 / 永久")
        XCTAssertEqual(chineseSchedule[3].1, "会话范围")

        XCTAssertEqual(NativeAlwaysOnCronDetailPresentation.originSessionValue(job), "origin-a")
        XCTAssertEqual(NativeAlwaysOnCronDetailPresentation.latestRunSessionValue(job), "session-a")
        XCTAssertEqual(NativeAlwaysOnCronDetailPresentation.transcriptKeyValue(job), "cron-key")
        XCTAssertTrue(NativeAlwaysOnCronDetailPresentation.canOpenLatestRunSession(job))
        XCTAssertEqual(NativeAlwaysOnCronDetailPresentation.latestRunTargetSummary(job), "Latest cron summary")
        let target = try XCTUnwrap(NativeAlwaysOnCronDetailPresentation.latestRunTarget(job))
        XCTAssertEqual(target.kind, .background)
        XCTAssertEqual(target.sessionId, "session-a")
        XCTAssertEqual(target.parentSessionId, "origin-a")
        XCTAssertEqual(target.relativeTranscriptPath, "origin-a/subagents/agent-a.jsonl")
        XCTAssertEqual(target.title, "Latest cron summary")
        XCTAssertEqual(target.transcriptKey, "agent-a.jsonl")
        XCTAssertEqual(target.taskId, "task-a")
        XCTAssertEqual(target.taskStatus, "scheduled")
        XCTAssertEqual(target.outputFile, "runs/run-a.log")

        var noTargetJob = job
        noTargetJob.latestRun = AlwaysOnCronLatestRun(
            status: .completed,
            runId: "run-b",
            startedAt: createdAt,
            sessionId: "session-b",
            summary: "",
            lastActivity: firedAt,
            taskId: nil,
            outputFile: nil,
            parentSessionId: nil,
            relativeTranscriptPath: nil,
            transcriptKey: nil
        )
        XCTAssertFalse(NativeAlwaysOnCronDetailPresentation.canOpenLatestRunSession(noTargetJob))
        XCTAssertNil(NativeAlwaysOnCronDetailPresentation.latestRunTarget(noTargetJob))
        XCTAssertEqual(NativeAlwaysOnCronDetailPresentation.latestRunTargetSummary(noTargetJob), "# Cron Alpha\nRun diagnostics")
    }

    func testAlwaysOnBackgroundTranscriptLoaderMatchesWebReadOnlySessionAndMessages() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("g9claw-bg-transcript-\(UUID().uuidString)", isDirectory: true)
        let projectName = "project-with-readonly-cron-count"
        let parentSessionId = "parent-session-readonly"
        let transcriptFileName = "agent-cron-readonly.jsonl"
        let transcriptPath = home
            .appendingPathComponent(".g9claw/projects/\(projectName)/\(parentSessionId)/subagents", isDirectory: true)
            .appendingPathComponent(transcriptFileName)
        try FileManager.default.createDirectory(at: transcriptPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        try """
        {"uuid":"cron-trigger","timestamp":"2026-04-19T10:00:00.000Z","type":"user","isMeta":true,"message":{"role":"user","content":"提醒用户：该站起来活动一下了！"}}
        {"uuid":"cron-system-error","timestamp":"2026-04-19T10:00:01.000Z","type":"system","subtype":"api_error","cause":{"code":"ConnectionRefused","path":"http://ccr.local/v1/messages?beta=true"}}
        {"uuid":"cron-synthetic-error","timestamp":"2026-04-19T10:00:02.000Z","type":"assistant","isApiErrorMessage":true,"message":{"role":"assistant","model":"<synthetic>","content":[{"type":"text","text":"API Error: Unable to connect to API (ConnectionRefused)"}]}}
        {"uuid":"cron-synthetic-empty","timestamp":"2026-04-19T10:00:03.000Z","type":"assistant","message":{"role":"assistant","model":"<synthetic>","content":[{"type":"text","text":"No response requested."}]}}
        {"uuid":"cron-assistant","timestamp":"2026-04-19T10:00:04.000Z","type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Checking the schedule."},{"type":"text","text":"Done."},{"type":"tool_use","id":"tool-1","name":"Read","input":{"file_path":"README.md"}},{"type":"tool_result","tool_use_id":"tool-1","content":"ok"}]}}
        {"uuid":"cron-normalized-tool","timestamp":"2026-04-19T10:00:05.000Z","type":"tool_use","toolId":"tool-2","toolName":"Shell","toolInput":{"command":"pwd"}}
        {"uuid":"cron-normalized-result","timestamp":"2026-04-19T10:00:06.000Z","type":"tool_result","toolCallId":"tool-2","output":"workspace"}
        """.write(to: transcriptPath, atomically: true, encoding: .utf8)

        let sessionId = AlwaysOnBackgroundTranscriptLoader.backgroundSessionID(
            parentSessionId: parentSessionId,
            transcriptFilename: transcriptFileName
        )
        let lastActivity = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-04-19T10:01:00Z"))
        let target = AlwaysOnSessionTarget.background(
            sessionId: sessionId,
            parentSessionId: parentSessionId,
            relativeTranscriptPath: "\(parentSessionId)/subagents/\(transcriptFileName)",
            title: "Cron summary",
            summary: "Cron summary",
            lastActivity: lastActivity,
            transcriptKey: transcriptFileName,
            taskId: "cron-task",
            taskStatus: "completed",
            outputFile: ".g9claw/always-on/runs/run-a.log"
        )

        let session = try XCTUnwrap(AlwaysOnBackgroundTranscriptLoader.makeSession(target: target, existing: nil, now: Date(timeIntervalSince1970: 0)))

        XCTAssertEqual(session.id, "background-parent-session-readonly-agent-cron-readonly")
        XCTAssertEqual(session.sessionKind, .backgroundTask)
        XCTAssertEqual(session.parentSessionId, parentSessionId)
        XCTAssertEqual(session.relativeTranscriptPath, "\(parentSessionId)/subagents/\(transcriptFileName)")
        XCTAssertEqual(session.transcriptKey, transcriptFileName)
        XCTAssertEqual(session.taskId, "cron-task")
        XCTAssertEqual(session.taskStatus, "completed")
        XCTAssertEqual(session.outputFile, ".g9claw/always-on/runs/run-a.log")
        XCTAssertEqual(session.isReadOnly, true)
        XCTAssertTrue(session.isBackgroundTaskSession)

        XCTAssertEqual(
            AlwaysOnBackgroundTranscriptLoader.transcriptURL(
                projectName: projectName,
                parentSessionId: parentSessionId,
                relativeTranscriptPath: "\(parentSessionId)/subagents/\(transcriptFileName)",
                home: home
            )?.path,
            transcriptPath.path
        )
        XCTAssertNil(AlwaysOnBackgroundTranscriptLoader.transcriptURL(
            projectName: projectName,
            parentSessionId: parentSessionId,
            relativeTranscriptPath: "../\(transcriptFileName)",
            home: home
        ))
        XCTAssertFalse(AlwaysOnBackgroundTranscriptLoader.isCronTranscriptFilename("agent-task.jsonl"))

        let messages = AlwaysOnBackgroundTranscriptLoader.messages(for: session, projectName: projectName, home: home)
        XCTAssertEqual(messages.count, 6)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[0].plainText, "提醒用户：该站起来活动一下了！")
        XCTAssertEqual(messages[1].role, .system)
        XCTAssertTrue(messages[1].plainText.contains("ConnectionRefused"))
        XCTAssertEqual(messages[2].role, .assistant)
        XCTAssertTrue(messages[2].plainText.contains("API Error"))
        XCTAssertEqual(messages[3].role, .assistant)
        XCTAssertTrue(messages[3].blocks.contains { if case .reasoning(let text) = $0 { return text == "Checking the schedule." }; return false })
        XCTAssertTrue(messages[3].plainText.contains("Done."))
        XCTAssertTrue(messages[3].blocks.contains { if case .toolCall(let call) = $0 { return call.name == "Read" && call.inputJSON.contains("README.md") }; return false })
        XCTAssertTrue(messages[3].blocks.contains { if case .toolResult(let result) = $0 { return result.toolCallId == "tool-1" && result.output == "ok" }; return false })
        XCTAssertTrue(messages[4].blocks.contains { if case .toolCall(let call) = $0 { return call.id == "tool-2" && call.name == "Shell" && call.inputJSON.contains("pwd") }; return false })
        XCTAssertTrue(messages[5].blocks.contains { if case .toolResult(let result) = $0 { return result.toolCallId == "tool-2" && result.output == "workspace" }; return false })
    }

    @MainActor
    func testAppStateOpenAlwaysOnBackgroundSessionCreatesReadOnlyFallbackAndBlocksSend() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("g9claw-open-bg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let project = WorkspaceProject(
            id: UUID(),
            name: WorkspaceService.projectName(for: root.path),
            displayName: "Open BG",
            rootPath: root.path,
            sessions: [],
            codexSessions: [],
            cursorSessions: [],
            geminiSessions: [],
            createdAt: Date(),
            lastActivity: Date()
        )
        let state = AppState()
        state.projects = [project]
        state.selectedProjectID = project.id

        let target = AlwaysOnSessionTarget.background(
            sessionId: "background-parent-agent-cron",
            parentSessionId: "parent",
            relativeTranscriptPath: "parent/subagents/agent-cron.jsonl",
            title: "Cron fallback",
            summary: "Cron fallback",
            lastActivity: Date(timeIntervalSince1970: 10),
            transcriptKey: "agent-cron.jsonl",
            taskId: "task-a",
            taskStatus: "completed",
            outputFile: "runs/run-a.log"
        )

        state.openAlwaysOnSession(target)

        XCTAssertEqual(state.activeTab, .chat)
        XCTAssertEqual(state.selectedSessionID, "background-parent-agent-cron")
        XCTAssertEqual(state.selectedSession?.sessionKind, .backgroundTask)
        XCTAssertEqual(state.selectedSession?.isReadOnly, true)
        XCTAssertEqual(state.selectedSession?.title, "Cron fallback")
        XCTAssertEqual(state.projects.first?.sessions.first?.id, "background-parent-agent-cron")

        state.composerText = "Do not send"
        state.sendComposerMessage()
        XCTAssertEqual(state.messagesBySession["background-parent-agent-cron"] ?? [], [])
        XCTAssertEqual(state.composerText, "Do not send")
    }

    func testNativeAlwaysOnRunMetadataVisibilityMatchesWebHistoryDetail() {
        XCTAssertEqual(NativeAlwaysOnRunMetadata.hiddenKeys, [
            "source",
            "sourceId",
            "parentSessionId",
            "logUpdatedAt",
            "logSize",
            "logTruncated",
        ])

        let visible = NativeAlwaysOnRunMetadata.visibleEntries([
            "source": "manual",
            "sourceId": "plan-a",
            "parentSessionId": "parent-a",
            "logUpdatedAt": "2026-05-23T12:00:00Z",
            "logSize": "2048",
            "logTruncated": "true",
            "sessionId": "session-a",
            "originSessionId": "origin-a",
            "relativeTranscriptPath": "origin-a/subagents/agent-a.jsonl",
            "transcriptKey": "agent-a",
            "finishedAt": "2026-05-23T12:01:00Z",
            "status": "completed",
            "emptyValue": "",
        ])

        XCTAssertEqual(
            visible.map { "\($0.key)=\($0.value)" },
            [
                "emptyValue=—",
                "finishedAt=2026-05-23T12:01:00Z",
                "originSessionId=origin-a",
                "relativeTranscriptPath=origin-a/subagents/agent-a.jsonl",
                "sessionId=session-a",
                "status=completed",
                "transcriptKey=agent-a",
            ]
        )
    }

    func testNativeAlwaysOnRunHistoryDetailPresentationUsesWebVisibleMetadataOnly() throws {
        let run = AlwaysOnRunHistory(
            id: "run-a",
            title: "  ",
            kind: "cron",
            status: .running,
            startedAt: Date(timeIntervalSince1970: 0),
            sourceId: "cron-a",
            outputLog: "",
            sessionId: "session-a",
            parentSessionId: "parent-a",
            relativeTranscriptPath: "parent-a/subagents/agent-a.jsonl",
            finishedAt: nil,
            error: nil,
            metadata: [
                "source": "manual",
                "sourceId": "cron-a",
                "parentSessionId": "parent-a",
                "logUpdatedAt": "2026-05-23T12:00:00Z",
                "logSize": "2048",
                "logTruncated": "true",
                "runId": "run-a",
                "status": "running",
                "startedAt": "1970-01-01T00:00:00Z",
                "sessionId": "session-a",
                "originSessionId": "origin-a",
                "relativeTranscriptPath": "parent-a/subagents/agent-a.jsonl",
                "transcriptKey": "agent-a.jsonl",
                "logSource": "log-file",
            ],
            transcriptKey: "agent-a.jsonl"
        )

        XCTAssertEqual(NativeAlwaysOnRunHistoryDetailPresentation.title(run), "Run detail")
        XCTAssertEqual(NativeAlwaysOnRunHistoryDetailPresentation.title(run, language: .chineseSimplified), "运行详情")
        XCTAssertEqual(NativeAlwaysOnRunHistoryDetailPresentation.logSource(run), "log-file")
        XCTAssertEqual(NativeAlwaysOnRunHistoryDetailPresentation.logUpdatedAt(run), "2026-05-23T12:00:00Z")
        XCTAssertTrue(NativeAlwaysOnRunHistoryDetailPresentation.isLogTruncated(run))
        XCTAssertEqual(
            NativeAlwaysOnRunHistoryDetailPresentation.outputLog(run, emptyText: "No output log was captured for this run."),
            "No output log was captured for this run."
        )

        let metadataKeys = Set(NativeAlwaysOnRunHistoryDetailPresentation.metadataEntries(run).map(\.key))

        XCTAssertFalse(metadataKeys.contains("source"))
        XCTAssertFalse(metadataKeys.contains("sourceId"))
        XCTAssertFalse(metadataKeys.contains("parentSessionId"))
        XCTAssertFalse(metadataKeys.contains("logUpdatedAt"))
        XCTAssertFalse(metadataKeys.contains("logSize"))
        XCTAssertFalse(metadataKeys.contains("logTruncated"))
        XCTAssertTrue(metadataKeys.contains("runId"))
        XCTAssertTrue(metadataKeys.contains("status"))
        XCTAssertTrue(metadataKeys.contains("startedAt"))
        XCTAssertTrue(metadataKeys.contains("sessionId"))
        XCTAssertTrue(metadataKeys.contains("originSessionId"))
        XCTAssertTrue(metadataKeys.contains("relativeTranscriptPath"))
        XCTAssertTrue(metadataKeys.contains("transcriptKey"))
        XCTAssertTrue(metadataKeys.contains("logSource"))

        let target = try XCTUnwrap(NativeAlwaysOnRunHistoryDetailPresentation.sessionTarget(run))
        XCTAssertEqual(target.kind, .background)
        XCTAssertEqual(target.sessionId, "session-a")
        XCTAssertEqual(target.parentSessionId, "parent-a")
        XCTAssertEqual(target.relativeTranscriptPath, "parent-a/subagents/agent-a.jsonl")
        XCTAssertEqual(target.title, "  ")
        XCTAssertEqual(target.taskId, "cron-a")
        XCTAssertEqual(target.taskStatus, "running")
        XCTAssertEqual(target.transcriptKey, "agent-a.jsonl")
    }

    func testNativeAlwaysOnRunHistoryRowsMatchWebTableColumnsAndSessionLabel() throws {
        let startedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-05-23T12:00:00Z"))
        let run = AlwaysOnRunHistory(
            id: "run-a",
            title: "Plan Alpha",
            kind: "plan",
            status: .completed,
            startedAt: startedAt,
            sourceId: "plan-alpha",
            outputLog: "",
            sessionId: "session-a",
            parentSessionId: nil,
            relativeTranscriptPath: nil
        )
        let transcriptOnlyRun = AlwaysOnRunHistory(
            id: "run-b",
            title: "Cron Beta",
            kind: "cron",
            status: .failed,
            startedAt: startedAt,
            sourceId: "cron-beta",
            outputLog: "",
            sessionId: nil,
            parentSessionId: "origin-a",
            relativeTranscriptPath: "origin-a/subagents/agent-cron.jsonl"
        )
        let noSessionRun = AlwaysOnRunHistory(
            id: "run-c",
            title: "  ",
            kind: "plan",
            status: .queued,
            startedAt: startedAt,
            sourceId: "plan-empty",
            outputLog: "",
            sessionId: nil,
            parentSessionId: nil,
            relativeTranscriptPath: nil
        )
        let hiddenRun = AlwaysOnRunHistory(
            id: "run-hidden",
            title: "Hidden",
            kind: "plan",
            status: .unknown,
            startedAt: startedAt,
            sourceId: "hidden",
            outputLog: "",
            sessionId: nil,
            parentSessionId: nil,
            relativeTranscriptPath: nil
        )

        XCTAssertEqual(NativeAlwaysOnRunHistoryRows.columns(), ["Title", "Kind", "Status", "Started", "Source", "Session"])
        XCTAssertEqual(NativeAlwaysOnRunHistoryRows.columns(language: .chineseSimplified), ["标题", "类型", "状态", "开始时间", "来源", "会话"])
        XCTAssertTrue(NativeAlwaysOnRunHistoryRows.isVisible(run))
        XCTAssertFalse(NativeAlwaysOnRunHistoryRows.isVisible(hiddenRun))

        let row = NativeAlwaysOnRunHistoryRows.row(run)
        XCTAssertEqual(row.title, "Plan Alpha")
        XCTAssertEqual(row.kind, "plan")
        XCTAssertEqual(row.status, "completed")
        XCTAssertEqual(row.source, "plan-alpha")
        XCTAssertEqual(row.session, "Available")
        XCTAssertTrue(row.started.contains("05/23"))

        XCTAssertEqual(NativeAlwaysOnRunHistoryRows.row(transcriptOnlyRun, language: .chineseSimplified).session, "可用")
        XCTAssertEqual(NativeAlwaysOnRunHistoryRows.row(noSessionRun).title, "—")
        XCTAssertEqual(NativeAlwaysOnRunHistoryRows.row(noSessionRun).session, "—")
    }

    func testAlwaysOnDiscoveryPromptMatchesWebStructuredContextShape() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("g9claw-alwayson-discovery-prompt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "Project README".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = ISO8601DateFormatter().date(from: "2026-05-23T10:00:00Z")!
        let service = AlwaysOnService()
        let context = service.discoveryContext(
            projectName: "g9claw-opc",
            displayName: "G9Claw OPC",
            projectRoot: root.path,
            plans: [
                AlwaysOnPlan(
                    id: "plan-a",
                    title: "Review router drift",
                    summary: "Check whether router config drifted.",
                    rationale: "Keep parity visible.",
                    content: "",
                    status: .ready,
                    approvalMode: "manual",
                    planFilePath: ".g9claw/always-on/plans/plan-a.md",
                    createdAt: now.addingTimeInterval(-120),
                    updatedAt: now.addingTimeInterval(-60),
                    executionSessionId: nil,
                    executionStatus: nil
                )
            ],
            cronJobs: [
                AlwaysOnCronJob(
                    id: "cron-a",
                    prompt: "# Nightly scan\nReview issues",
                    cron: "0 1 * * *",
                    status: .scheduled,
                    recurring: true,
                    durable: true,
                    createdAt: now.addingTimeInterval(-600),
                    lastFiredAt: nil,
                    latestSessionId: nil,
                    permanent: false,
                    manualOnly: true,
                    originSessionId: "origin-a",
                    transcriptKey: "cron-a",
                    latestRun: AlwaysOnCronLatestRun(
                        status: .completed,
                        runId: "run-a",
                        startedAt: now.addingTimeInterval(-300),
                        sessionId: "session-a",
                        summary: "Finished scan",
                        lastActivity: now.addingTimeInterval(-240),
                        taskId: "cron-a",
                        outputFile: ".g9claw/always-on/runs/run-a.log",
                        parentSessionId: "parent-a",
                        relativeTranscriptPath: "parent-a/subagents/agent-cron-a.jsonl",
                        transcriptKey: "agent-cron-a.jsonl"
                    )
                )
            ],
            sessions: [
                ProjectSession(
                    id: "chat-1",
                    provider: .g9Claw,
                    title: "中文规划",
                    summary: "用户要求用中文整理 Always-On 计划。",
                    createdAt: now.addingTimeInterval(-180),
                    updatedAt: nil,
                    lastActivity: now.addingTimeInterval(-90),
                    state: .idle
                )
            ],
            memoryRecords: [
                MemoryRecord(
                    id: UUID(),
                    name: "Router",
                    summary: "Router parity details.",
                    projectName: "g9claw-opc",
                    updatedAt: now.addingTimeInterval(-30),
                    type: .project,
                    relativePath: "Project/router.md",
                    deprecated: false,
                    content: "Router parity details."
                )
            ],
            now: now
        )
        let english = service.discoveryPrompt(
            projectName: "g9claw-opc",
            displayName: "G9Claw OPC",
            projectRoot: root.path,
            context: context,
            language: "en"
        )
        let chinese = service.discoveryPrompt(
            projectName: "g9claw-opc",
            displayName: "G9Claw OPC",
            projectRoot: root.path,
            context: context,
            language: "zh-CN"
        )

        XCTAssertEqual(context.generatedAt, "2026-05-23T10:00:00Z")
        XCTAssertEqual(context.lookbackDays, 7)
        XCTAssertTrue(context.workspace.signals.contains("README.md present"))
        XCTAssertEqual(context.memory.first?.path, "Project/router.md")
        XCTAssertEqual(context.existingPlans.first?.id, "plan-a")
        XCTAssertEqual(context.cronJobs.first?.latestRunSummary, "Finished scan")
        XCTAssertEqual(context.recentChats.first?.id, "chat-1")

        XCTAssertTrue(english.contains("Always-On discovery planning for project \"G9Claw OPC\"."))
        XCTAssertTrue(english.contains("Use the project store at `~/.g9claw/projects/g9claw-opc`"))
        XCTAssertTrue(english.contains("Every saved plan must include these markdown sections exactly:"))
        XCTAssertTrue(english.contains("Do not call `CronCreate`"))
        XCTAssertTrue(english.contains("\"recentChats\""))
        XCTAssertTrue(english.contains("\"cronJobs\""))
        XCTAssertTrue(english.contains("## Approval And Execution"))
        XCTAssertFalse(english.contains(".g9claw/always-on"))

        XCTAssertTrue(chinese.contains("Always-On 主动发现规划"))
        XCTAssertTrue(chinese.contains("近期聊天语言为准"))
        XCTAssertTrue(chinese.contains("结构化 discovery context"))
    }

    func testAlwaysOnDiscoveryRequestDedupeMatchesWebPolicy() {
        var store = AlwaysOnDiscoveryRequestDedupeStore()

        XCTAssertTrue(store.shouldProcess("request-1"))
        XCTAssertFalse(store.shouldProcess("request-1"))
        XCTAssertFalse(store.shouldProcess(" request-1 "))
        XCTAssertFalse(store.shouldProcess(nil))
        XCTAssertFalse(store.shouldProcess(""))
        XCTAssertFalse(store.shouldProcess("   "))

        XCTAssertTrue(store.shouldProcess("request-2", maxSize: 2))
        XCTAssertTrue(store.shouldProcess("request-3", maxSize: 2))
        XCTAssertTrue(store.shouldProcess("request-1", maxSize: 2))
        XCTAssertTrue(store.shouldProcess("request-2", maxSize: 2))
        XCTAssertTrue(store.shouldProcess("request-3", maxSize: 2))
    }

    func testAlwaysOnServiceRunLogReadsTailMetadataLikeWeb() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("g9claw-alwayson-run-log-\(UUID().uuidString)", isDirectory: true)
        let runsRoot = root.appendingPathComponent(".g9claw/always-on/runs", isDirectory: true)
        try FileManager.default.createDirectory(at: runsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "first line\nsecond line\n".write(
            to: runsRoot.appendingPathComponent("run-1.log"),
            atomically: true,
            encoding: .utf8
        )

        let log = AlwaysOnService().runLog(projectRoot: root.path, runID: "run/1", tailBytes: 12)

        XCTAssertEqual(log.runId, "run/1")
        XCTAssertEqual(log.content, "second line\n")
        XCTAssertEqual(log.truncated, true)
        XCTAssertEqual(log.size, 23)
        XCTAssertEqual(log.source, .logFile)
        XCTAssertNotNil(log.updatedAt)
    }

    func testAlwaysOnServiceRunLogReturnsHistorySourceWhenFileIsMissing() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("g9claw-alwayson-run-log-missing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let log = AlwaysOnService().runLog(projectRoot: root.path, runID: "missing-run")

        XCTAssertEqual(log.runId, "missing-run")
        XCTAssertEqual(log.content, "")
        XCTAssertEqual(log.truncated, false)
        XCTAssertEqual(log.updatedAt, nil)
        XCTAssertEqual(log.size, 0)
        XCTAssertEqual(log.source, .history)
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

    func testCodeMinimapSnapshotSamplesLargeFilesAndViewportModelIsCheap() {
        let text = (1...2_000).map { "line \($0) let value = \($0)" }.joined(separator: "\n")
        let snapshot = CodeMinimapSnapshot(text: text, maxLines: 500)
        let model = CodeMinimapModel(snapshot: snapshot, visibleLineRange: 100..<180)

        XCTAssertEqual(snapshot.totalLines, 2_000)
        XCTAssertLessThanOrEqual(snapshot.lines.count, 500)
        XCTAssertGreaterThan(snapshot.sampleStride, 1)
        XCTAssertEqual(model.totalLines, snapshot.totalLines)
        XCTAssertGreaterThan(model.viewportStartFraction, 0)
        XCTAssertGreaterThanOrEqual(CodeLineNumberMetrics.rulerWidth(lineCount: 1), 48)
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

    func testAlwaysOnProjectConfigPatchMatchesWebTopLevelShape() {
        let enabled = AlwaysOnProjectConfig.setEnabled(in: "", projectRoot: "/workspace/a/", enabled: true)
        let enabledValues = NativeConfigService.scalarMap(from: enabled)

        XCTAssertEqual(AlwaysOnProjectConfig.projectRoot("/workspace/a/"), "/workspace/a")
        XCTAssertEqual(enabledValues["alwaysOn.discovery.projects./workspace/a.enabled"], "true")
        XCTAssertTrue(AlwaysOnProjectConfig.isEnabled(yaml: enabled, projectRoot: "/workspace/a/"))

        let disabled = AlwaysOnProjectConfig.setEnabled(in: enabled, projectRoot: "/workspace/a/", enabled: false)
        let disabledValues = NativeConfigService.scalarMap(from: disabled)

        XCTAssertEqual(disabledValues["alwaysOn.discovery.projects./workspace/a.enabled"], "false")
        XCTAssertFalse(AlwaysOnProjectConfig.isEnabled(yaml: disabled, projectRoot: "/workspace/a/"))
    }

    func testYAMLScalarEditorSetsObjectScalarForDottedProjectRootKeys() {
        let yaml = """
        alwaysOn:
          discovery:
            projects:
              /Users/tester/workspace/app.one:
                enabled: true
                mode: manual
        """

        let updated = YAMLScalarEditor.setObjectScalar(
            parentPath: "alwaysOn.discovery.projects",
            id: "/Users/tester/workspace/app.one",
            key: "enabled",
            value: "false",
            in: yaml
        )
        let values = NativeConfigService.scalarMap(from: updated)

        XCTAssertEqual(values["alwaysOn.discovery.projects./Users/tester/workspace/app.one.enabled"], "false")
        XCTAssertEqual(values["alwaysOn.discovery.projects./Users/tester/workspace/app.one.mode"], "manual")
        XCTAssertFalse(updated.contains("app:\n"))
    }

    func testConfigYAMLAPIKeyResolutionPrefersYAMLAndFallsBackToKeychainWhenBlank() {
        let yamlWithKey = """
        models:
          providers:
            g9claw:
              type: openai-chat
              baseUrl: http://example.local/v1
              apiKey: yaml-secret
          entries:
            default:
              provider: g9claw
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
            g9claw:
              type: openai-chat
              baseUrl: http://example.local/v1
              apiKey: ""
          entries:
            default:
              provider: g9claw
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
            .appendingPathComponent("g9claw-skill-\(UUID().uuidString)", isDirectory: true)
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
        XCTAssertTrue(pinning.canAutoFollowOutput(autoScrollToBottom: true))
        XCTAssertFalse(pinning.canAutoFollowOutput(autoScrollToBottom: false))

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
            inputJSON: #"{"skill":"g9claw-rag:glm-web-search","args":"weather"}"#
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
            inputJSON: #"{"skill":"g9claw-rag:rag-research","args":"DARPA autonomous systems"}"#
        )

        let result = await NativeToolRouter.execute(call: call, context: context)

        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.toolName, "Skill")
        XCTAssertTrue(result.output.contains("g9claw-rag:rag-research"))
        XCTAssertTrue(context.invokedSkills.contains("g9claw-rag:rag-research"))
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
            inputJSON: #"{"command":"<parameter>\npython3 ${G9CLAW_PLUGIN_ROOT}/scripts/local_knowledge_search.py --query \"DARPA autonomous systems research\""}"#
        )

        let normalized = ToolArgumentNormalizer.normalize(call)

        XCTAssertNil(normalized.recoveryResult)
        let object = try? JSONSerialization.jsonObject(with: Data(normalized.call.inputJSON.utf8)) as? [String: Any]
        XCTAssertEqual(
            object?["command"] as? String,
            #"python3 ${G9CLAW_PLUGIN_ROOT}/scripts/local_knowledge_search.py --query "DARPA autonomous systems research""#
        )
    }

    func testSkillRuntimeLoadsBundledRAGSkillAndInjectsEnvironment() throws {
        let request = agentRequest(
            nativeConfigValues: [
                "rag.enabled": "true",
                "rag.disableBuiltInWebTools": "true",
                "rag.localKnowledge.baseUrl": "https://local.example.com/",
                "rag.localKnowledge.apiKey": "local-secret",
                "rag.localKnowledge.modelName": "retriever-v1",
                "rag.localKnowledge.milvusUri": "milvus://milvus.example.com:19530",
                "rag.glmWebSearch.baseUrl": "https://api.z.ai/api/paas/v4/web_search/",
                "rag.glmWebSearch.apiKey": "test-rag-key",
            ]
        )
        let context = AgentRunContext(request: request)
        let output = try SkillRuntimeService.load(
            inputJSON: #"{"skill":"g9claw-rag:glm-web-search","args":"Beijing weather"}"#,
            context: context
        )

        XCTAssertTrue(output.contains("g9claw-rag:glm-web-search"))
        XCTAssertTrue(output.contains("glm_web_search.py"))
        XCTAssertTrue(context.invokedSkills.contains("g9claw-rag:glm-web-search"))

        let environment = SkillRuntimeService.environment(configValues: request.nativeConfigValues)
        XCTAssertEqual(environment["G9CLAW_RAG_ENABLED"], "1")
        XCTAssertEqual(environment["G9CLAW_RAG_DISABLE_BUILTIN_WEB_TOOLS"], "1")
        XCTAssertEqual(environment["G9CLAW_RAG_LOCAL_KNOWLEDGE_BASE_URL"], "https://local.example.com")
        XCTAssertEqual(environment["G9CLAW_RAG_LOCAL_KNOWLEDGE_API_KEY"], "local-secret")
        XCTAssertEqual(environment["G9CLAW_RAG_LOCAL_KNOWLEDGE_MODEL_NAME"], "retriever-v1")
        XCTAssertEqual(environment["G9CLAW_RAG_LOCAL_KNOWLEDGE_DATABASE_URL"], "milvus://milvus.example.com:19530")
        XCTAssertEqual(environment["G9CLAW_RAG_LOCAL_KNOWLEDGE_MILVUS_URI"], "milvus://milvus.example.com:19530")
        XCTAssertEqual(environment["G9CLAW_RAG_LOCAL_KNOWLEDGE_TOP_K"], "8")
        XCTAssertEqual(environment["G9CLAW_RAG_GLM_WEB_SEARCH_BASE_URL"], "https://api.z.ai/api/paas/v4/web_search")
        XCTAssertEqual(environment["G9CLAW_RAG_GLM_WEB_SEARCH_API_KEY"], "test-rag-key")
        XCTAssertEqual(environment["G9CLAW_RAG_GLM_WEB_SEARCH_TOP_K"], "8")
        XCTAssertNotNil(environment["G9CLAW_PLUGIN_ROOT"])
        XCTAssertNil(environment["EDGECLAW_PLUGIN_ROOT"])
        XCTAssertNil(environment["CLAU" + "DE_PLUGIN_ROOT"])
    }

    func testBundledRAGPluginResourceIsPackaged() throws {
        let resources = try XCTUnwrap(Bundle.main.resourceURL)
        let skillFile = resources
            .appendingPathComponent("g9claw-rag-plugin", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("glm-web-search", isDirectory: true)
            .appendingPathComponent("SKILL.md")

        XCTAssertTrue(FileManager.default.fileExists(atPath: skillFile.path))
    }

    func testMacNativeAndBundledRAGPluginDoNotContainOldBrandNames() throws {
        let root = repoRootURL()
        let scanRoots = [
            root.appendingPathComponent("apps/macos-native", isDirectory: true),
            root.appendingPathComponent("packages/g9claw-rag-plugin", isDirectory: true),
        ]
        let forbidden = [
            "9" + "GClaw",
            "9" + "gclaw",
            "Nine" + "GClaw",
            "Clau" + "de",
            "clau" + "de",
            "CLAU" + "DE",
            "Edge" + "Claw",
            "edge" + "claw",
            "EDGE" + "CLAW",
        ]
        let scannedExtensions: Set<String> = ["swift", "md", "yaml", "yml", "json", "plist", "pbxproj", "entitlements", "py", "sh"]
        var hits: [String] = []

        for scanRoot in scanRoots {
            guard let enumerator = FileManager.default.enumerator(
                at: scanRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: []
            ) else { continue }
            for case let fileURL as URL in enumerator {
                let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { continue }
                let ext = fileURL.pathExtension
                if !ext.isEmpty, !scannedExtensions.contains(ext) { continue }
                guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
                for token in forbidden where contents.contains(token) {
                    hits.append("\(fileURL.path): \(token)")
                }
            }
        }

        XCTAssertTrue(hits.isEmpty, hits.joined(separator: "\n"))
    }

    func testRouterChoosesTierModelWithoutDARPAHardcoding() {
        let yaml = """
        models:
          providers:
            g9claw:
              type: openai-chat
              baseUrl: http://example.local/v1
              apiKey: test
          entries:
            default:
              provider: g9claw
              name: qwen3.6-27b
            router_small:
              provider: g9claw
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

    func testRouterRuntimeMatchesLegacyScenarioPriorityWhenTokenSaverIsOff() {
        let yaml = """
        models:
          providers:
            g9claw:
              type: openai-chat
              baseUrl: http://example.local/v1
          entries:
            default:
              provider: g9claw
              name: default-model
            background_entry:
              provider: g9claw
              name: background-model
            think_entry:
              provider: g9claw
              name: think-model
            long_entry:
              provider: g9claw
              name: long-model
            web_entry:
              provider: g9claw
              name: web-model
            simple_entry:
              provider: g9claw
              name: simple-model
        router:
          enabled: true
          routes:
            default:
              model: default
            background:
              model: background_entry
            think:
              model: think_entry
            longContext:
              model: long_entry
            webSearch:
              model: web_entry
            longContextThreshold: 60000
          tokenSaver:
            enabled: false
            tiers:
              SIMPLE:
                model: simple_entry
        """
        let values = NativeConfigService.scalarMap(from: yaml)

        XCTAssertEqual(
            NativeRouterRuntime.decision(
                forTier: "SIMPLE",
                values: values,
                tokenCount: 70_000,
                isBackgroundRequest: true,
                hasWebSearchTools: true,
                hasThinking: true
            ),
            NativeRouterRuntime.Decision(entryID: "long_entry", scenario: "longContext", tier: nil)
        )
        XCTAssertEqual(
            NativeRouterRuntime.decision(forTier: "SIMPLE", values: values, isBackgroundRequest: true).scenario,
            "background"
        )
        XCTAssertEqual(
            NativeRouterRuntime.decision(forTier: "SIMPLE", values: values, hasWebSearchTools: true).entryID,
            "web_entry"
        )
        XCTAssertEqual(
            NativeRouterRuntime.decision(forTier: "SIMPLE", values: values, hasThinking: true).entryID,
            "think_entry"
        )
        XCTAssertEqual(NativeRouterRuntime.decision(forTier: "SIMPLE", values: values).entryID, "default")
    }

    func testRouterRuntimeRequestSignalsFeedWebStyleLongContextAndToolRouting() {
        let yaml = """
        models:
          providers:
            g9claw:
              type: openai-chat
              baseUrl: http://example.local/v1
          entries:
            default:
              provider: g9claw
              name: default-model
            long_entry:
              provider: g9claw
              name: long-model
            web_entry:
              provider: g9claw
              name: web-model
        router:
          enabled: true
          routes:
            default:
              model: default
            longContext:
              model: long_entry
            webSearch:
              model: web_entry
            longContextThreshold: 1000
        """
        let values = NativeConfigService.scalarMap(from: yaml)
        let history = [
            ChatMessage(
                id: UUID(),
                sessionId: "router-session",
                provider: .g9Claw,
                role: .user,
                blocks: [.text(String(repeating: "h", count: 2_500))],
                createdAt: Date(),
                isStreaming: false,
                tokenBudget: nil
            ),
        ]
        let longSignals = NativeRouterRuntime.requestSignals(
            prompt: String(repeating: "p", count: 2_500),
            priorMessages: history,
            attachments: [],
            tools: []
        )

        XCTAssertGreaterThan(longSignals.tokenCount, 1_000)
        XCTAssertEqual(
            NativeRouterRuntime.decision(forTier: "SIMPLE", values: values, signals: longSignals).scenario,
            "longContext"
        )

        let webSearchTool: [[String: Any]] = [
            [
                "type": "web_search_preview",
                "name": "web_search_preview",
            ],
        ]
        let webSignals = NativeRouterRuntime.requestSignals(
            prompt: "Search current public sources",
            priorMessages: [],
            attachments: [],
            tools: webSearchTool
        )

        XCTAssertTrue(webSignals.hasWebSearchTools)
        XCTAssertEqual(
            NativeRouterRuntime.decision(forTier: "SIMPLE", values: values, signals: webSignals).scenario,
            "webSearch"
        )
    }

    func testRouterRuntimeRequestSignalTokenEstimateIncludesToolSchemasAndImageAttachments() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("g9-router-signals-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let imageURL = tempDir.appendingPathComponent("diagram.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)
        let imageAttachment = FileAttachment(
            id: UUID(),
            fileName: "diagram.png",
            path: imageURL.path,
            mimeType: "image/png"
        )
        let smallSignals = NativeRouterRuntime.requestSignals(
            prompt: "short",
            priorMessages: [],
            attachments: [],
            tools: []
        )
        let richSignals = NativeRouterRuntime.requestSignals(
            prompt: "short",
            priorMessages: [],
            attachments: [imageAttachment],
            tools: [
                [
                    "type": "function",
                    "function": [
                        "name": "HugeTool",
                        "description": String(repeating: "d", count: 4_000),
                        "parameters": [
                            "type": "object",
                            "properties": [
                                "query": ["type": "string", "description": String(repeating: "q", count: 1_000)],
                            ],
                        ],
                    ],
                ],
            ]
        )

        XCTAssertFalse(smallSignals.hasWebSearchTools)
        XCTAssertGreaterThanOrEqual(richSignals.tokenCount - smallSignals.tokenCount, 3_000)
    }

    func testRouterRuntimeResolvesBackgroundProviderRouteForSubagents() {
        let yaml = """
        runtime:
          contextWindow: 120000
        models:
          providers:
            main:
              type: openai-chat
              baseUrl: http://main.local/v1
              apiKey: main-secret
            background:
              type: openai-chat
              baseUrl: http://background.local/v1
              apiKey: background-secret
          entries:
            default:
              provider: main
              name: main-model
              contextWindow: 160000
            background_entry:
              provider: background
              name: background-model
              contextWindow: 64000
        agents:
          main:
            model: default
        router:
          enabled: true
          routes:
            default:
              model: default
            background:
              model: background_entry
        """
        let values = NativeConfigService.scalarMap(from: yaml)
        let fallbackProvider = ProviderConfig(
            provider: .g9Claw,
            apiType: .openAIChat,
            baseURL: "http://fallback.local/v1",
            model: "fallback-model",
            secretAccount: "fallback",
            headers: [:]
        )
        let route = NativeRouterRuntime.resolvedProviderRoute(
            forTier: "COMPLEX",
            values: values,
            fallbackProviderConfig: fallbackProvider,
            fallbackAPIKey: "fallback-secret",
            fallbackContextWindow: 32_000,
            signals: NativeRouterRuntime.RequestSignals(
                tokenCount: 0,
                isBackgroundRequest: true,
                hasWebSearchTools: false,
                hasThinking: false
            )
        )

        XCTAssertEqual(route.decision.scenario, "background")
        XCTAssertEqual(route.providerConfig.baseURL, "http://background.local/v1")
        XCTAssertEqual(route.providerConfig.model, "background-model")
        XCTAssertEqual(route.apiKey, "background-secret")
        XCTAssertEqual(route.contextWindow, 64_000)
    }

    func testRouterRuntimeTokenSaverTakesOverLikeWebRouterWhenEnabled() {
        let yaml = """
        models:
          providers:
            g9claw:
              type: openai-chat
              baseUrl: http://example.local/v1
          entries:
            default:
              provider: g9claw
              name: default-model
            simple_entry:
              provider: g9claw
              name: simple-model
            long_entry:
              provider: g9claw
              name: long-model
            web_entry:
              provider: g9claw
              name: web-model
        router:
          enabled: true
          routes:
            default:
              model: default
            longContext:
              model: long_entry
            webSearch:
              model: web_entry
            longContextThreshold: 60000
          tokenSaver:
            enabled: true
            tiers:
              SIMPLE:
                model: simple_entry
        """
        let values = NativeConfigService.scalarMap(from: yaml)

        let decision = NativeRouterRuntime.decision(
            forTier: "SIMPLE",
            values: values,
            tokenCount: 100_000,
            hasWebSearchTools: true
        )

        XCTAssertEqual(decision.entryID, "simple_entry")
        XCTAssertEqual(decision.scenario, "tokenSaver")
        XCTAssertEqual(decision.tier, "SIMPLE")
    }

    func testRouterRuntimeFallsBackToDefaultForDisabledRouterOrMissingEntries() {
        let yaml = """
        models:
          providers:
            g9claw:
              type: openai-chat
              baseUrl: http://example.local/v1
          entries:
            default:
              provider: g9claw
              name: default-model
        router:
          enabled: false
          routes:
            default:
              model: default
            webSearch:
              model: missing_entry
          tokenSaver:
            enabled: true
            tiers:
              SIMPLE:
                model: missing_entry
        """
        let disabledValues = NativeConfigService.scalarMap(from: yaml)

        XCTAssertEqual(
            NativeRouterRuntime.decision(
                forTier: "SIMPLE",
                values: disabledValues,
                tokenCount: 100_000,
                hasWebSearchTools: true
            ),
            NativeRouterRuntime.Decision(entryID: "default", scenario: "default", tier: nil)
        )

        let enabledValues = NativeConfigService.scalarMap(from: yaml.replacingOccurrences(of: "enabled: false", with: "enabled: true"))
        XCTAssertEqual(NativeRouterRuntime.decision(forTier: "SIMPLE", values: enabledValues, hasWebSearchTools: true).entryID, "default")
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
            "skill:g9claw-rag:glm-web-search": { "count": 1, "requestCount": 1 }
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
              "model": "skill:g9claw-rag:glm-web-search",
              "tokens": 0,
              "cost": 0,
              "query": "Skill invoked",
              "scenario": "skill",
              "skill": "g9claw-rag:glm-web-search"
            }
          ]
        }
        """

        let structured = try decoder.decode(RoutingDashboardSession.self, from: Data(structuredJSON.utf8))

        XCTAssertEqual(structured.requestEntries.count, 2)
        XCTAssertEqual(structured.requestEntries.first?.tier, "MEDIUM")
        XCTAssertEqual(structured.requestEntries.first?.query, "Build a weather website")
        XCTAssertEqual(structured.requestEntries.last?.skill, "g9claw-rag:glm-web-search")
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
            XCTAssertEqual(layout.estimatedWidth, 544)
        }
        XCTAssertEqual(MainHeaderToolSwitcherLayout.buttonWidth(for: .chat, iconOnly: false), 82)
        XCTAssertEqual(MainHeaderToolSwitcherLayout.buttonWidth(for: .alwaysOn, iconOnly: false), 118)
        XCTAssertEqual(MainHeaderToolSwitcherLayout.buttonWidth(for: .chat, iconOnly: true), 36)

        let chatOnlyLayout = MainHeaderToolSwitcherLayout.resolve(
            availableWidth: 760,
            activeTab: .chat,
            tabs: [.chat]
        )
        XCTAssertEqual(chatOnlyLayout.visibleTabs, [.chat])
        XCTAssertEqual(chatOnlyLayout.estimatedWidth, 88)
    }

    func testCodeEditorPreferencesDefaultToLineNumbersAndMinimapForNewUsers() {
        XCTAssertTrue(CodeEditorPreferences.defaults.lineNumbers)
        XCTAssertTrue(CodeEditorPreferences.defaults.showMinimap)
        XCTAssertFalse(CodeEditorPreferences.defaults.wordWrap)
        XCTAssertEqual(CodeEditorPreferences.defaults.fontSize, 14)
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

    func testCodeLineNumberModeAddsEditorTextInset() {
        let plainInset = CodeLineNumberMetrics.textInset(lineNumbersVisible: false)
        let lineNumberInset = CodeLineNumberMetrics.textInset(lineNumbersVisible: true, lineCount: 687)

        XCTAssertGreaterThan(lineNumberInset.width, plainInset.width)
        XCTAssertGreaterThan(lineNumberInset.width, CodeLineNumberMetrics.rulerWidth(lineCount: 687))
        XCTAssertEqual(lineNumberInset.height, plainInset.height)
    }

    func testWrappedCodeEditorDoesNotPreserveHorizontalOffset() {
        XCTAssertEqual(CodeEditorScrollStabilityMetrics.horizontalOrigin(42, wordWrap: true, maxX: 300), 0)
        XCTAssertEqual(CodeEditorScrollStabilityMetrics.horizontalOrigin(-8, wordWrap: false, maxX: 300), 0)
        XCTAssertEqual(CodeEditorScrollStabilityMetrics.horizontalOrigin(420, wordWrap: false, maxX: 300), 300)
        XCTAssertEqual(CodeEditorScrollStabilityMetrics.horizontalOrigin(120, wordWrap: false, maxX: 300), 120)
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
        XCTAssertEqual(model.lineNumber(atY: 0, height: 600), 1)
        XCTAssertEqual(model.lineNumber(atY: 300, height: 600), 1_201)
        XCTAssertEqual(model.lineNumber(atY: 900, height: 600), 2_400)
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

    func testCodeEditorScrollStabilityMetricsEnableMinimapDraggingAndThrottleViewport() {
        XCTAssertTrue(CodeEditorScrollStabilityMetrics.minimapAllowsHitTesting)
        XCTAssertTrue(CodeEditorScrollStabilityMetrics.preservesScrollOriginOnUpdate)
        XCTAssertTrue(CodeEditorScrollStabilityMetrics.editorBodyClipsRulerToContent)
        XCTAssertGreaterThanOrEqual(CodeEditorScrollStabilityMetrics.visibleRangePublishInterval, 0.06)
        XCTAssertEqual(CodeEditorScrollStabilityMetrics.minimapViewportMinHeight, 18)
    }

    func testCodeSyntaxHighlightingMapsCommonEditorLanguages() {
        XCTAssertEqual(CodeSyntaxHighlightingService.languageAlias(forFileName: "index.html"), "html")
        XCTAssertEqual(CodeSyntaxHighlightingService.languageAlias(forFileName: "main.py"), "python")
        XCTAssertEqual(CodeSyntaxHighlightingService.languageAlias(forFileName: "style.css"), "css")
        XCTAssertEqual(CodeSyntaxHighlightingService.languageAlias(forFileName: "app.tsx"), "typescript")
        XCTAssertEqual(CodeSyntaxHighlightingService.languageAlias(forFileName: "Package.swift"), "swift")
        XCTAssertEqual(CodeSyntaxHighlightingService.languageAlias(forFileName: "config.json"), "json")
        XCTAssertEqual(CodeSyntaxHighlightingService.languageAlias(forFileName: "README.md"), "markdown")
        XCTAssertEqual(CodeSyntaxHighlightingService.languageAlias(forFileName: "script.zsh"), "bash")
        XCTAssertNil(CodeSyntaxHighlightingService.languageAlias(forFileName: "archive.unknown"))
    }

    func testCodeSyntaxHighlightingUsesDarkLightThemesAndLargeFileGuard() {
        XCTAssertEqual(CodeSyntaxHighlightingService.themeName(isDarkMode: false), "xcode")
        XCTAssertEqual(CodeSyntaxHighlightingService.themeName(isDarkMode: true), "tokyoNight")
        XCTAssertTrue(CodeSyntaxHighlightingService.shouldHighlight("<main></main>", languageAlias: "html"))
        XCTAssertFalse(CodeSyntaxHighlightingService.shouldHighlight("", languageAlias: "html"))
        XCTAssertFalse(CodeSyntaxHighlightingService.shouldHighlight("let x = 1", languageAlias: nil))
        XCTAssertFalse(CodeSyntaxHighlightingService.shouldHighlight(String(repeating: "a", count: CodeSyntaxHighlightingService.maxHighlightedCharacters + 1), languageAlias: "python"))
    }

    func testCodeSyntaxHighlightingProducesVisibleEditorColors() async throws {
        let highlighted = try await CodeSyntaxHighlightingService.highlightedText(
            "<!DOCTYPE html>\n<html><style>body { color: #fff; }</style></html>",
            languageAlias: "html",
            isDarkMode: false
        )
        let attributed = NSAttributedString(highlighted)
        var colors = Set<String>()
        attributed.enumerateAttribute(
            .foregroundColor,
            in: NSRange(location: 0, length: attributed.length),
            options: []
        ) { value, _, _ in
            guard let color = value as? NSColor else { return }
            colors.insert(color.usingColorSpace(.sRGB)?.description ?? color.description)
        }

        XCTAssertGreaterThan(colors.count, 1)
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
                provider: .g9Claw,
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
