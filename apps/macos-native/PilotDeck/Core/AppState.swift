import Combine
import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var projects: [WorkspaceProject] = WorkspaceProject.sample()
    @Published var selectedProjectID: UUID?
    @Published var selectedSessionID: String?
    @Published var activeTab: AppTab = .chat
    @Published var uiPreferences = NativeUIPreferencesStorage.storedPreferences()
    @Published var isSidebarVisible = true
    @Published var messagesBySession: [String: [ChatMessage]] = [:]
    @Published var activitiesBySession: [String: [AgentActivity]] = [:]
    @Published var turnsBySession: [String: [AgentTurn]] = [:]
    @Published var turnItemsBySession: [String: [AgentTurnItem]] = [:]
    @Published var composerText = ""
    @Published var composerRunMode: ChatRunMode = .agent
    @Published var composerPermissionMode: ComposerPermissionMode = .default
    @Published var pendingAttachments: [FileAttachment] = []
    @Published var settings = AppSettings.defaults
    @Published var pendingPermissions: [PermissionRequest] = []
    @Published var terminalRuns: [TerminalRun] = []
    @Published var gitOutput = ""
    @Published var selectedFile: WorkspaceFile?
    @Published var selectedFileContent = ""
    @Published var statusLine = "Ready"
    @Published var errorBanner: String?
    @Published var warningBanner: String?
    @Published var showSettings = false
    @Published var showProjectCreationWizard = false
    @Published var settingsInitialTab: SettingsMainTab = .appearance
    @Published var pilotDeckConfigText = ""
    @Published var settingsSaveNotice: String?
    @Published var toolRefreshRevision = 0
    @Published var streamRenderRevision = 0
    @Published var isDraftSessionVisible = false
    @Published var expandedAssistantProcessIDs: Set<String> = []
    @Published var expandedToolRowIDs: Set<String> = []
    @Published var collapsedToolRowIDs: Set<String> = []
    @Published var tokenBudgetBySession: [String: TokenBudget] = [:]

    let settingsStore: AppSettingsStore
    let providerClient = NativeAgentRuntime()
    let workspaceService = WorkspaceService()
    let gitService = GitService()
    let terminalService = TerminalService()
    let taskService = TaskService()
    let memoryService = MemoryService()
    let skillsService = SkillsService()
    let routingService = RoutingService()
    let alwaysOnService = AlwaysOnService()
    let alwaysOnManager = NativeAlwaysOnManager()

    private var activeAgentTask: Task<Void, Never>?
    private var activeRunToken: UUID?
    private var alwaysOnBackgroundTasks: [String: Task<Void, Never>] = [:]
    private var alwaysOnBackgroundRunTokens: Set<UUID> = []
    private var lastUserMessageAtByProjectRoot: [String: Date] = [:]
    private var activitySequence = 0
    private var permissionContinuations: [UUID: CheckedContinuation<AgentPermissionDecision, Never>] = [:]
    private var pendingAssistantDeltas: [UUID: String] = [:]
    private var assistantDeltaFlushTasks: [UUID: Task<Void, Never>] = [:]
    private var assistantSessionByID: [UUID: String] = [:]
    private var routingModelBySession: [String: String] = [:]
    private var routingTierBySession: [String: String] = [:]
    private var routingProjectNameBySession: [String: String] = [:]
    private var memoryProjectNameBySession: [String: String] = [:]
    private var memoryProjectRootBySession: [String: String] = [:]
    private var memoryAutomationTask: Task<Void, Never>?
    private var lastErrorBySession: [String: String] = [:]
    private var lastWarningBySession: [String: String] = [:]
    private var hasBootstrapped = false

    init(settingsStore: AppSettingsStore = AppSettingsStore()) {
        self.settingsStore = settingsStore
        settings.generalWorkspacePath = Self.normalizedGeneralWorkspacePath(settings.generalWorkspacePath)
        isSidebarVisible = uiPreferences.sidebarVisible
        selectedProjectID = projects.first?.id
        selectedSessionID = projects.first?.sessions.first?.id
        restoreComposerPermissionMode(for: selectedSessionID)
        if let sessionID = selectedSessionID {
            messagesBySession[sessionID] = [
                ChatMessage(
                    id: UUID(),
                    sessionId: sessionID,
                    provider: .pilotDeck,
                    role: .assistant,
                    blocks: [.text("Native PilotDeck is running with the macOS parity shell. Configure a provider in Settings to start a real agent session.")],
                    createdAt: Date(),
                    isStreaming: false,
                    tokenBudget: nil
                )
            ]
        }
    }

    nonisolated static func defaultGeneralWorkspacePath(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        home.appendingPathComponent("PilotDeck", isDirectory: true)
            .appendingPathComponent("general", isDirectory: true)
            .standardizedFileURL
            .path
    }

    nonisolated static func normalizedGeneralWorkspacePath(_ rawPath: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let fallback = defaultGeneralWorkspacePath(home: home)
        guard let trimmed = rawPath.nilIfBlankOrConfigNull else { return fallback }
        let expanded = expandUserPath(trimmed, home: home)
        guard expanded.hasPrefix("/") else { return fallback }
        let normalized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        if normalized == "/null" {
            return fallback
        }
        return normalized
    }

    nonisolated static func normalizedWorkspacesRoot(_ rawPath: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let fallback = home.standardizedFileURL.path
        guard let trimmed = rawPath.nilIfBlankOrConfigNull else { return fallback }
        let expanded = expandUserPath(trimmed, home: home)
        guard expanded.hasPrefix("/") else { return fallback }
        let normalized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        return normalized == "/null" ? fallback : normalized
    }

    nonisolated private static func expandUserPath(_ path: String, home: URL) -> String {
        if path == "~" {
            return home.standardizedFileURL.path
        }
        if path.hasPrefix("~/") {
            return home.appendingPathComponent(String(path.dropFirst(2))).standardizedFileURL.path
        }
        return NSString(string: path).expandingTildeInPath
    }

    nonisolated static func normalizedSettings(_ settings: AppSettings) -> AppSettings {
        var normalized = settings
        normalized.providerConfig.provider = .pilotDeck
        normalized.providerConfig.apiType = .openAIChat
        normalized.providerConfig.secretAccount = ProviderConfig.empty.secretAccount
        normalized.workspacesRoot = normalizedWorkspacesRoot(settings.workspacesRoot)
        normalized.generalWorkspacePath = normalizedGeneralWorkspacePath(settings.generalWorkspacePath)
        normalized.permissions.disallowedTools.removeAll(where: isWebSearchPermissionRule)
        return normalized
    }

    nonisolated private static func isWebSearchPermissionRule(_ rule: String) -> Bool {
        AgentToolNameCanonicalizer.canonical(rule) == "WebSearch"
    }

    var selectedProject: WorkspaceProject? {
        guard let selectedProjectID else { return nil }
        return projects.first(where: { $0.id == selectedProjectID })
    }

    var selectedSession: ProjectSession? {
        guard let selectedProject, let selectedSessionID else { return nil }
        return selectedProject.allSessions.first(where: { $0.id == selectedSessionID })
    }

    var currentMessages: [ChatMessage] {
        guard let selectedSessionID else { return [] }
        return messagesBySession[selectedSessionID] ?? []
    }

    var currentActivities: [AgentActivity] {
        guard let selectedSessionID else { return [] }
        return activitiesBySession[selectedSessionID] ?? []
    }

    var currentPendingPermissions: [PermissionRequest] {
        guard let selectedSessionID else { return [] }
        return pendingPermissions.filter { $0.sessionId == selectedSessionID }
    }

    var currentTurnItems: [AgentTurnItem] {
        guard let selectedSessionID else { return [] }
        return (turnItemsBySession[selectedSessionID] ?? []).sorted { $0.sequence < $1.sequence }
    }

    var isCurrentSessionStreaming: Bool {
        currentMessages.contains { $0.isStreaming }
    }

    func bootstrap() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        do {
            _ = try AppPaths.current()
            do {
                if let storedSettings = try settingsStore.load() {
                    let normalizedSettings = Self.normalizedSettings(storedSettings)
                    settings = normalizedSettings
                    if normalizedSettings != storedSettings {
                        try? settingsStore.save(normalizedSettings)
                    }
                }
            } catch {
                AppLog.write("settings load error: \(error.localizedDescription)")
            }
            logBundleNetworkPolicy()
            try bootstrapLocalDebugConfigIfNeeded()
            loadPilotDeckConfigText()
            applyNativeConfigFromCurrentText()
            let restoredSelection = loadPersistedWorkspaceState()
            loadManualProjectsFromPilotDeckConfig()
            mergeSharedProjectPathIndex()
            mergePilotDeckWebHistory()
            mergeSharedSessionIndex()
            recoverLocalSessionIndex()
            restoreWorkspaceSelection(restoredSelection)
            persistWorkspaceState()
            refreshNativeToolData()
            restartMemoryAutomationLoop()
            restartAlwaysOnAutomationLoop()
            statusLine = t(.nativeInitialized)
        } catch {
            errorBanner = error.localizedDescription
            AppLog.write("bootstrap error: \(error.localizedDescription)")
        }
    }

    func refreshProjects() async {
        mergePilotDeckWebHistory()
        projects = WorkspaceService.sortedProjects(projects, order: settings.projectSortOrder)
        persistWorkspaceState()
        statusLine = t(.projectsRefreshed)
    }

    func bumpToolRefresh() {
        toolRefreshRevision += 1
    }

    func selectProject(_ project: WorkspaceProject) {
        selectedProjectID = project.id
        selectedSessionID = nil
        errorBanner = nil
        isDraftSessionVisible = false
        activeTab = .chat
        persistWorkspaceState()
        refreshNativeToolData()
        kickMemoryAutomationCheck()
    }

    func selectSession(_ session: ProjectSession) {
        isDraftSessionVisible = false
        selectedSessionID = session.id
        restoreComposerPermissionMode(for: session.id)
        activeTab = .chat
        if session.isBackgroundTaskSession, let selectedProject {
            loadBackgroundTaskMessagesIfNeeded(session: session, project: selectedProject)
        } else {
            loadPersistedMessagesIfNeeded(sessionID: session.id)
        }
        if lastErrorBySession[session.id] != nil || session.state == .failed {
            markSession(session.id, state: .failed)
        } else {
            markSession(session.id, state: .idle)
        }
        refreshVisibleErrorBanner()
        persistWorkspaceState()
        refreshNativeToolData()
    }

    func openAlwaysOnSession(_ target: AlwaysOnSessionTarget) {
        guard let projectIndex = selectedProjectIndex else { return }
        switch target.kind {
        case .origin:
            if let session = projects[projectIndex].allSessions.first(where: { $0.id == target.sessionId }) {
                selectSession(session)
                return
            }
            guard let session = AlwaysOnBackgroundTranscriptLoader.makePersistedSession(target: target) else {
                errorBanner = "This chat record no longer exists."
                return
            }
            upsertBackgroundSession(session, projectIndex: projectIndex)
            selectSession(session)
        case .background:
            guard let session = AlwaysOnBackgroundTranscriptLoader.makeSession(
                target: target,
                existing: projects[projectIndex].allSessions.first(where: { $0.id == target.sessionId })
            ) else { return }
            upsertBackgroundSession(session, projectIndex: projectIndex)
            selectSession(session)
        }
    }

    func startNewSession() {
        startDraftSession(project: selectedProject)
    }

    func startDraftSession(project: WorkspaceProject?) {
        if let project {
            selectedProjectID = project.id
        } else if selectedProjectID == nil {
            selectedProjectID = projects.first?.id
        }
        selectedSessionID = nil
        errorBanner = nil
        warningBanner = nil
        restoreComposerPermissionMode(for: nil)
        isDraftSessionVisible = true
        activeTab = .chat
        persistWorkspaceState()
        refreshNativeToolData()
    }

    private func refreshVisibleErrorBanner() {
        guard let selectedSessionID else {
            errorBanner = nil
            warningBanner = nil
            return
        }
        errorBanner = lastErrorBySession[selectedSessionID]
        warningBanner = lastWarningBySession[selectedSessionID]
    }

    func toggleComposerRunMode() {
        composerRunMode = composerRunMode == .agent ? .plan : .agent
    }

    func setSidebarVisible(_ visible: Bool) {
        updateUIPreferences { preferences in
            preferences.sidebarVisible = visible
        }
    }

    func setSendByCtrlEnter(_ enabled: Bool) {
        updateUIPreferences { preferences in
            preferences.sendByCtrlEnter = enabled
        }
    }

    func setUIPreference(_ keyPath: WritableKeyPath<NativeUIPreferences, Bool>, _ value: Bool) {
        updateUIPreferences { preferences in
            preferences[keyPath: keyPath] = value
        }
    }

    func isToolRowExpanded(_ id: String) -> Bool {
        ToolRowExpansionPolicy.isExpanded(
            id: id,
            expandedIDs: expandedToolRowIDs,
            collapsedIDs: collapsedToolRowIDs,
            autoExpandTools: uiPreferences.autoExpandTools
        )
    }

    func toggleToolRowExpanded(_ id: String) {
        ToolRowExpansionPolicy.toggle(
            id: id,
            expandedIDs: &expandedToolRowIDs,
            collapsedIDs: &collapsedToolRowIDs,
            autoExpandTools: uiPreferences.autoExpandTools
        )
    }

    func isAssistantProcessExpanded(_ id: String) -> Bool {
        expandedAssistantProcessIDs.contains(id)
    }

    func toggleAssistantProcessExpanded(_ id: String) {
        if expandedAssistantProcessIDs.contains(id) {
            expandedAssistantProcessIDs.remove(id)
        } else {
            expandedAssistantProcessIDs.insert(id)
        }
    }

    private func updateUIPreferences(_ update: (inout NativeUIPreferences) -> Void) {
        var preferences = uiPreferences
        update(&preferences)
        uiPreferences = preferences
        isSidebarVisible = preferences.sidebarVisible
        NativeUIPreferencesStorage.save(preferences)
    }

    func setComposerPermissionMode(_ mode: ComposerPermissionMode) {
        composerPermissionMode = mode
        ComposerPermissionModeStorage.save(mode, for: selectedSessionID)
    }

    private func restoreComposerPermissionMode(for sessionID: String?) {
        composerPermissionMode = ComposerPermissionModeStorage.storedMode(for: sessionID)
    }

    @discardableResult
    func consumeComposerRunModeForSend() -> ChatRunMode {
        composerRunMode
    }

    @discardableResult
    func createSessionForSelectedProject(title: String = "") -> ProjectSession? {
        guard let projectIndex = selectedProjectIndex else { return nil }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let session = ProjectSession(
            id: UUID().uuidString,
            provider: .pilotDeck,
            title: trimmedTitle.isEmpty ? t(.newSession) : trimmedTitle,
            summary: "",
            createdAt: Date(),
            updatedAt: nil,
            lastActivity: nil,
            lastConversationAt: nil,
            state: .idle
        )
        projects[projectIndex].sessions.insert(session, at: 0)
        selectedSessionID = session.id
        isDraftSessionVisible = false
        messagesBySession[session.id] = []
        activeTab = .chat
        persistWorkspaceState()
        return session
    }

    func createProject(name: String, path: String) {
        let validation = WorkspaceService(workspaceRoot: URL(fileURLWithPath: settings.workspacesRoot))
            .validateWorkspacePath(path)
        guard validation.valid, let resolved = validation.resolvedPath else {
            errorBanner = validation.error
            return
        }
        guard FileManager.default.fileExists(atPath: resolved) else {
            errorBanner = t(.workspacePathDoesNotExist)
            return
        }
        let project = WorkspaceProject(
            id: UUID(),
            name: WorkspaceService.projectName(for: resolved),
            displayName: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? URL(fileURLWithPath: resolved).lastPathComponent : name,
            rootPath: resolved,
            sessions: [],
            codexSessions: [],
            cursorSessions: [],
            geminiSessions: [],
            createdAt: Date(),
            lastActivity: Date()
        )
        projects.insert(project, at: 0)
        do {
            try persistManualProject(project)
            persistWorkspaceState()
        } catch {
            errorBanner = error.localizedDescription
        }
        selectProject(project)
        startNewSession()
        restartAlwaysOnAutomationLoop()
    }

    func createProjectFromWizard(displayName: String, path: String, createDirectory: Bool, githubURL: String?) async {
        let trimmedPath = NSString(string: path.trimmingCharacters(in: .whitespacesAndNewlines)).expandingTildeInPath
        let service = WorkspaceService(workspaceRoot: URL(fileURLWithPath: settings.workspacesRoot))
        let validation = service.validateWorkspacePath(trimmedPath)
        guard validation.valid, let resolved = validation.resolvedPath else {
            errorBanner = validation.error
            return
        }

        do {
            if createDirectory {
                try service.createWorkspaceDirectory(path: resolved)
            } else if !FileManager.default.fileExists(atPath: resolved) {
                throw NSError(
                    domain: "WorkspaceService",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Existing workspace path does not exist."]
                )
            }
            if let githubURL, !githubURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try await service.cloneRepository(githubURL, into: resolved)
            }
            createProject(name: displayName, path: resolved)
            showProjectCreationWizard = false
            statusLine = t(.projectAdded)
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    func sendComposerMessage() {
        let prompt = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pendingAttachments
        guard !prompt.isEmpty || !attachments.isEmpty else { return }
        guard selectedSession?.isReadOnly != true else { return }
        if selectedSessionID == nil {
            _ = createSessionForSelectedProject(title: promptTitle(from: prompt))
        }
        guard let sessionID = selectedSessionID else { return }
        finishCurrentRunAsSuperseded()
        let historyBeforeSend = currentMessages
        let requestedRunMode = consumeComposerRunModeForSend()

        composerText = ""
        pendingAttachments = []
        var userBlocks: [ChatBlock] = []
        if !prompt.isEmpty {
            userBlocks.append(.text(prompt))
        }
        userBlocks.append(contentsOf: attachments.map { .attachment($0) })
        if userBlocks.isEmpty {
            userBlocks.append(.text("Attached files"))
        }
        let assistantID = UUID()
        let runStartedAt = Date()
        assistantSessionByID[assistantID] = sessionID
        let userMessage = ChatMessage(
            id: UUID(),
            sessionId: sessionID,
            provider: .pilotDeck,
            role: .user,
            blocks: userBlocks,
            createdAt: Date(),
            isStreaming: false,
            tokenBudget: nil
        )
        append(userMessage)
        touchSessionConversation(sessionID)
        lastErrorBySession.removeValue(forKey: sessionID)
        if selectedSessionID == sessionID {
            errorBanner = nil
        }
        var activities = activitiesBySession[sessionID] ?? []
        activities.removeAll { $0.anchorBlockID == assistantID.uuidString }
        activities.append(
            AgentActivity(
                id: "run-\(assistantID.uuidString)",
                sessionId: sessionID,
                title: t(.connecting),
                detail: t(.openingRemoteModelStream),
                phase: .status,
                state: .running,
                createdAt: runStartedAt,
                updatedAt: runStartedAt,
                anchorBlockID: assistantID.uuidString,
                sequence: nextActivitySequence()
            )
        )
        activitiesBySession[sessionID] = activities

        let assistantMessage = ChatMessage(
            id: assistantID,
            sessionId: sessionID,
            provider: .pilotDeck,
            role: .assistant,
            blocks: [.text("")],
            createdAt: runStartedAt,
            isStreaming: true,
            tokenBudget: nil,
            runStartedAt: runStartedAt
        )
        append(assistantMessage)
        markSession(sessionID, state: .processing)
        persistSessionMessages(sessionID: sessionID)

        let workspacePath: String
        do {
            workspacePath = try prepareSelectedWorkspacePathForRun()
        } catch {
            handleAgentEvent(.error(error.localizedDescription), assistantID: assistantID, sessionID: sessionID)
            return
        }
        lastUserMessageAtByProjectRoot[AlwaysOnService.normalizedProjectRoot(workspacePath)] = Date()
        syncMemoryWorkspaceCatalog()
        memoryProjectNameBySession[sessionID] = selectedProject.flatMap(memoryProjectName)
        memoryProjectRootBySession[sessionID] = workspacePath
        let nativeConfig = currentNativeConfigSnapshot()
        let basePrompt = agentPrompt(prompt: prompt, attachments: attachments)
        var nativeConfigValues = nativeConfig?.rawValues ?? [:]
        nativeConfigValues["app.language"] = settings.language.resolved() == .chineseSimplified ? "zh-CN" : "en"
        let runToken = UUID()
        activeRunToken = runToken
        activeAgentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let routeTier = await self.routerTier(
                prompt: prompt,
                runMode: requestedRunMode,
                nativeConfig: nativeConfig,
                nativeConfigValues: nativeConfigValues
            )
            let visibleTools = NativeToolRouter.openAITools(configValues: nativeConfigValues)
            let routeSignals = NativeRouterRuntime.requestSignals(
                prompt: basePrompt,
                priorMessages: historyBeforeSend,
                attachments: attachments,
                tools: visibleTools
            )
            let routeDecision = NativeRouterRuntime.decision(
                forTier: routeTier,
                values: nativeConfigValues,
                signals: routeSignals,
                sessionID: sessionID
            )
            let routeEntryID = routeDecision.entryID
            let providerConfig = nativeConfig.flatMap { NativeConfigService.providerConfig(entryID: routeEntryID, values: $0.rawValues) }
                ?? nativeConfig?.providerConfig
                ?? self.settings.providerConfig
            let requestContextWindow = nativeConfig.map {
                NativeConfigService.contextWindow(entryID: routeEntryID, values: $0.rawValues) ?? $0.contextWindow
            } ?? self.settings.contextWindow
            let apiKey = NativeConfigService.resolvedAPIKey(
                routeEntryID: routeEntryID,
                nativeConfig: nativeConfig
            )
            self.memoryService.updateExtractionRuntime(
                providerConfig: providerConfig,
                apiKey: apiKey,
                timeoutMs: nativeConfig?.apiTimeoutMs ?? self.settings.apiTimeoutMs
            )

            let routingProjectName = self.selectedProject?.displayName ?? "general"
            self.routingModelBySession[sessionID] = providerConfig.model
            self.routingTierBySession[sessionID] = routeDecision.tier ?? routeTier
            self.routingProjectNameBySession[sessionID] = routingProjectName
            self.routingService.recordRequest(
                sessionID: sessionID,
                title: self.selectedSession?.displayTitle ?? self.promptTitle(from: prompt),
                projectName: routingProjectName,
                model: providerConfig.model,
                route: routeDecision.scenario,
                tier: routeDecision.tier ?? routeTier,
                query: prompt,
                decision: routeDecision,
                projectPath: workspacePath
            )
            let fallbackRoutes = self.routerFallbackRoutes(
                primaryEntryID: routeEntryID,
                scenario: routeDecision.scenario,
                nativeConfig: nativeConfig,
                values: nativeConfigValues
            )
            let memoryResult = await self.memoryService.retrieveContextForTurn(
                query: basePrompt,
                recentMessages: historyBeforeSend + [userMessage],
                sessionID: sessionID,
                projectName: self.memoryProjectNameBySession[sessionID],
                projectRoot: workspacePath
            )
            let promptWithMemory: String
            if memoryResult.injected {
                promptWithMemory = """
                <memory-context>
                \(memoryResult.systemContext)
                </memory-context>

                \(basePrompt)
                """
            } else {
                promptWithMemory = basePrompt
            }
            let request = AgentRequest(
                sessionId: sessionID,
                projectPath: workspacePath,
                prompt: promptWithMemory,
                attachments: attachments,
                providerConfig: providerConfig,
                apiKey: apiKey,
                priorMessages: historyBeforeSend,
                timeoutMs: nativeConfig?.apiTimeoutMs ?? self.settings.apiTimeoutMs,
                contextWindow: requestContextWindow,
                permissionMode: self.composerPermissionMode,
                runMode: requestedRunMode,
                workspaceContext: self.selectedWorkspaceContext,
                toolSettings: self.settings.permissions,
                routerRoute: routeDecision.scenario,
                fallbackRoutes: fallbackRoutes,
                nativeConfigValues: nativeConfigValues,
                permissionHandler: { [weak self] permission in
                    guard let self else { return .deny }
                    return await self.requestAgentPermission(permission)
                }
            )
            var sawTerminalEvent = false
            do {
                for try await event in self.providerClient.stream(request: request) {
                    if event.isTerminal {
                        sawTerminalEvent = true
                    }
                    self.handleAgentEvent(event, assistantID: assistantID, sessionID: sessionID, runToken: runToken)
                }
                if !sawTerminalEvent {
                    self.handleAgentEvent(.complete(sessionId: sessionID), assistantID: assistantID, sessionID: sessionID, runToken: runToken)
                }
            } catch {
                self.handleAgentEvent(.error(error.localizedDescription), assistantID: assistantID, sessionID: sessionID, runToken: runToken)
            }
        }
    }

    private func routerTier(
        prompt: String,
        runMode: ChatRunMode,
        nativeConfig: NativeConfigSnapshot?,
        nativeConfigValues: [String: String]
    ) async -> String {
        let fallbackTier = RouterTier(canonicalizing: RoutingService.classifyTier(prompt: prompt, runMode: runMode)).rawValue
        guard configBool(nativeConfigValues["router.enabled"]),
              configBool(nativeConfigValues["router.tokenSaver.enabled"]) else {
            return fallbackTier
        }
        let defaultTier = RouterTier(canonicalizing: nativeConfigValues["router.tokenSaver.defaultTier"]).rawValue
        guard let judged = await judgeRouterTier(prompt: prompt, runMode: runMode, nativeConfig: nativeConfig, values: nativeConfigValues) else {
            return defaultTier
        }
        return judged
    }

    private func judgeRouterTier(
        prompt: String,
        runMode: ChatRunMode,
        nativeConfig: NativeConfigSnapshot?,
        values: [String: String]
    ) async -> String? {
        let judgeEntryID = values["router.tokenSaver.judgeModel"]?.nilIfBlank
            ?? values["router.tokenSaver.judge"]?.nilIfBlank
            ?? nativeConfig?.defaultEntryID
            ?? "default"
        guard let providerConfig = NativeConfigService.providerConfig(entryID: judgeEntryID, values: values) ?? nativeConfig?.providerConfig else {
            return nil
        }
        let apiKey = NativeConfigService.resolvedAPIKey(
            routeEntryID: judgeEntryID,
            nativeConfig: nativeConfig
        )
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        do {
            let endpoint = try ProviderClient.endpointURL(baseURL: providerConfig.baseURL, suffix: "chat/completions")
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = TimeInterval(max(Int(values["router.tokenSaver.judgeTimeoutMs"] ?? "") ?? 8_000, 1_000)) / 1_000.0
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            for (key, value) in providerConfig.headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            let body: [String: Any] = [
                "model": providerConfig.model,
                "messages": [
                    [
                        "role": "system",
                        "content": routerJudgeSystemPrompt(values: values),
                    ],
                    [
                        "role": "user",
                        "content": "Run mode: \(runMode.rawValue)\n\nUser request:\n\(prompt)",
                    ],
                ],
                "temperature": 0,
                "max_tokens": 96,
                "stream": false,
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let statusCode = (response as? HTTPURLResponse)?.statusCode,
                  200..<300 ~= statusCode,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = object["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                return nil
            }
            return parseRouterJudgeTier(content)
        } catch {
            return nil
        }
    }

    private func routerJudgeSystemPrompt(values: [String: String]) -> String {
        let descriptions = RouterTier.allCases.map { tier in
            let description = values["router.tokenSaver.tiers.\(tier.rawValue).description"]?.nilIfBlank
                ?? values["router.tokenSaver.tiers.\(tier.rawValue.uppercased()).description"]?.nilIfBlank
                ?? defaultRouterTierDescription(tier)
            return "- \(tier.rawValue): \(description)"
        }.joined(separator: "\n")
        return """
        You classify a single agent request for model routing.
        Return only compact JSON with this shape: {"tier":"simple|medium|complex|reasoning","reason":"short reason"}.

        Tier meanings:
        \(descriptions)

        Routing rules:
        \(routerTokenSaverRules(values: values))

        Use complex for multi-step implementation or broad coding work. Use reasoning for deep analysis, architecture, hard debugging, safety/security review, or plan mode.
        """
    }

    private func routerTokenSaverRules(values: [String: String]) -> String {
        if let rules = values["router.tokenSaver.rules"]?.nilIfBlank {
            return rules
        }
        return """
        - Short prompts (<20 words) -> simple unless they ask to edit/build/code.
        - Single-file edits, code review, and explanations -> medium.
        - Multi-file tasks, refactoring, implementation, or website/game creation -> complex.
        - Novel architecture, deep analysis, hard debugging, or security review -> reasoning.
        """
    }

    private func defaultRouterTierDescription(_ tier: RouterTier) -> String {
        switch tier {
        case .simple:
            return "Short Q&A, greetings, file reads, tiny local edits."
        case .medium:
            return "Moderate coding, explanations, reviews, single-file changes."
        case .complex:
            return "Multi-step coding, larger features, coordinated edits."
        case .reasoning:
            return "Deep reasoning, architecture, novel algorithms, security analysis."
        }
    }

    private func parseRouterJudgeTier(_ content: String) -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = [
            trimmed,
            trimmed.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: ""),
        ]
        for candidate in candidates {
            if let data = candidate.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tier = object["tier"] as? String {
                return RouterTier(canonicalizing: tier).rawValue
            }
        }
        let lower = trimmed.lowercased()
        for tier in RouterTier.allCases where lower.contains(tier.rawValue) {
            return tier.rawValue
        }
        return nil
    }

    private func routerFallbackRoutes(
        primaryEntryID: String,
        scenario: String,
        nativeConfig: NativeConfigSnapshot?,
        values: [String: String]
    ) -> [AgentRouteCandidate] {
        let routeList = values["router.fallback.\(scenario)"]?.nilIfBlank
            ?? values["router.fallback.default"]?.nilIfBlank
            ?? ""
        let entryIDs = routeList
            .split { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" }
            .map(String.init)
            .filter { !$0.isEmpty && $0 != primaryEntryID }
        var seen: Set<String> = []
        return entryIDs.compactMap { entryID in
            guard seen.insert(entryID).inserted,
                  let providerConfig = NativeConfigService.providerConfig(entryID: entryID, values: values) else {
                return nil
            }
            let apiKey = NativeConfigService.resolvedAPIKey(
                routeEntryID: entryID,
                nativeConfig: nativeConfig
            )
            guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return AgentRouteCandidate(
                entryID: entryID,
                scenario: "fallback",
                providerConfig: providerConfig,
                apiKey: apiKey,
                contextWindow: NativeConfigService.contextWindow(entryID: entryID, values: values)
                    ?? nativeConfig?.contextWindow
                    ?? settings.contextWindow
            )
        }
    }

    private func configBool(_ rawValue: String?) -> Bool {
        let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == "true" || value == "1" || value == "yes"
    }

    private func agentPrompt(prompt: String, attachments: [FileAttachment]) -> String {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !attachments.isEmpty else {
            return trimmedPrompt.isEmpty ? t(.reviewAttachedFiles) : trimmedPrompt
        }

        var lines: [String] = []
        if trimmedPrompt.isEmpty {
            lines.append(t(.reviewAttachedFiles))
        } else {
            lines.append(trimmedPrompt)
        }
        lines.append("")
        lines.append("Attached files:")
        for attachment in attachments {
            let mime = attachment.mimeType ?? "unknown"
            lines.append("- \(attachment.fileName) (\(mime)): \(attachment.path)")
            if attachment.isImage {
                lines.append("  Image attachment is included as model input when the provider supports vision.")
            } else if let excerpt = attachmentTextExcerpt(attachment) {
                lines.append("  Excerpt:")
                lines.append(excerpt.split(separator: "\n").map { "    \($0)" }.joined(separator: "\n"))
            }
        }
        return lines.joined(separator: "\n")
    }

    private func attachmentTextExcerpt(_ attachment: FileAttachment) -> String? {
        let url = URL(fileURLWithPath: attachment.path)
        let textExtensions = Set(["md", "txt", "swift", "js", "ts", "tsx", "jsx", "json", "yaml", "yml", "py", "rb", "go", "rs", "html", "css", "csv", "xml"])
        guard textExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? NSNumber,
            size.intValue <= 512_000,
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(8_000))
    }

    func abortActiveRun() {
        activeAgentTask?.cancel()
        activeAgentTask = nil
        flushAllPendingAssistantDeltas()
        assistantDeltaFlushTasks.values.forEach { $0.cancel() }
        assistantDeltaFlushTasks.removeAll()
        activeRunToken = nil
        resolveAllPendingPermissions(decision: .deny)
        if let selectedSessionID {
            markSession(selectedSessionID, state: .idle)
            finishStreamingMessage(sessionID: selectedSessionID)
            cancelRunningActivities(sessionID: selectedSessionID)
            captureMemoryTurn(sessionID: selectedSessionID, errored: false, interrupted: true)
        }
        statusLine = t(.stopGeneration)
    }

    func shutdownForTermination() {
        activeAgentTask?.cancel()
        activeAgentTask = nil
        flushAllPendingAssistantDeltas()
        assistantDeltaFlushTasks.values.forEach { $0.cancel() }
        assistantDeltaFlushTasks.removeAll()
        memoryAutomationTask?.cancel()
        memoryAutomationTask = nil
        alwaysOnBackgroundTasks.values.forEach { $0.cancel() }
        alwaysOnBackgroundTasks.removeAll()
        alwaysOnBackgroundRunTokens.removeAll()
        activeRunToken = nil
        resolveAllPendingPermissions(decision: .deny)
        Task {
            await alwaysOnManager.stop()
        }
    }

    private func finishCurrentRunAsSuperseded() {
        guard activeRunToken != nil || activeAgentTask != nil || isCurrentSessionStreaming else { return }
        activeAgentTask?.cancel()
        activeAgentTask = nil
        flushAllPendingAssistantDeltas()
        assistantDeltaFlushTasks.values.forEach { $0.cancel() }
        assistantDeltaFlushTasks.removeAll()
        activeRunToken = nil
        resolveAllPendingPermissions(decision: .deny)
        if let selectedSessionID {
            finishStreamingMessage(sessionID: selectedSessionID)
            cancelRunningActivities(sessionID: selectedSessionID)
            markSession(selectedSessionID, state: .idle)
            captureMemoryTurn(sessionID: selectedSessionID, errored: false, interrupted: true)
        }
    }

    func runShell(command: String) {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let cwd = URL(fileURLWithPath: effectiveSelectedWorkspacePath)
        let service = terminalService
        Task { @MainActor in
            let run = await service.run(command: command, cwd: cwd)
            terminalRuns.insert(run, at: 0)
        }
    }

    func refreshGitStatus() {
        guard let selectedProject else {
            gitOutput = "No project selected."
            return
        }
        let service = gitService
        let repo = URL(fileURLWithPath: effectiveWorkspacePath(for: selectedProject))
        Task { @MainActor in
            do {
                gitOutput = try await service.status(repo: repo)
            } catch {
                gitOutput = error.localizedDescription
            }
        }
    }

    func refreshGitDiff() {
        guard let selectedProject else {
            gitOutput = "No project selected."
            return
        }
        let service = gitService
        let repo = URL(fileURLWithPath: effectiveWorkspacePath(for: selectedProject))
        Task { @MainActor in
            do {
                gitOutput = try await service.diff(repo: repo)
            } catch {
                gitOutput = error.localizedDescription
            }
        }
    }

    func runGitFetch() {
        runGitOperation(label: t(.fetch)) { service, repo in
            try await service.fetch(repo: repo)
        }
    }

    func runGitPull() {
        runGitOperation(label: t(.pull)) { service, repo in
            try await service.pull(repo: repo)
        }
    }

    func runGitPush() {
        runGitOperation(label: t(.push)) { service, repo in
            try await service.push(repo: repo)
        }
    }

    func renameProject(_ project: WorkspaceProject, displayName: String) {
        let nextName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nextName.isEmpty else { return }
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index].displayName = nextName
        projects[index].lastActivity = Date()
        do {
            try persistManualProject(projects[index])
            persistWorkspaceState()
            statusLine = "\(t(.rename)) \(nextName)"
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    func deleteProject(_ project: WorkspaceProject) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        let removed = projects.remove(at: index)
        let removedRoot = normalizedPath(effectiveWorkspacePath(for: removed))
        for session in removed.allSessions {
            removeSessionArtifacts(session.id)
        }
        SharedProjectPathIndexStore.markDeleted(rootPath: removedRoot)
        SharedSessionIndexStore.removeProject(rootPath: removedRoot)
        do {
            try removeManualProjectFromConfig(removed)
        } catch {
            errorBanner = error.localizedDescription
        }
        if selectedProjectID == removed.id {
            selectedProjectID = projects.first?.id
            selectedSessionID = nil
        }
        persistWorkspaceState()
        statusLine = "\(t(.delete)) \(removed.displayName)"
        refreshNativeToolData()
    }

    func renameSession(_ session: ProjectSession, in project: WorkspaceProject, title: String) {
        let nextTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nextTitle.isEmpty,
              let projectIndex = projects.firstIndex(where: { $0.id == project.id }) else { return }
        renameSession(in: &projects[projectIndex].sessions, sessionID: session.id, title: nextTitle)
        renameSession(in: &projects[projectIndex].codexSessions, sessionID: session.id, title: nextTitle)
        renameSession(in: &projects[projectIndex].cursorSessions, sessionID: session.id, title: nextTitle)
        renameSession(in: &projects[projectIndex].geminiSessions, sessionID: session.id, title: nextTitle)
        persistWorkspaceState()
        statusLine = "\(t(.rename)) \(nextTitle)"
    }

    func deleteSession(_ session: ProjectSession, in project: WorkspaceProject) {
        guard let projectIndex = projects.firstIndex(where: { $0.id == project.id }) else { return }
        removeSession(from: &projects[projectIndex].sessions, sessionID: session.id)
        removeSession(from: &projects[projectIndex].codexSessions, sessionID: session.id)
        removeSession(from: &projects[projectIndex].cursorSessions, sessionID: session.id)
        removeSession(from: &projects[projectIndex].geminiSessions, sessionID: session.id)
        removeSessionArtifacts(session.id)
        SharedSessionIndexStore.removeSession(sessionID: session.id)
        if selectedSessionID == session.id {
            selectedSessionID = nil
        }
        persistWorkspaceState()
        statusLine = "\(t(.delete)) \(session.displayTitle)"
        refreshNativeToolData()
    }

    func saveSettings() {
        do {
            try savePilotDeckConfigTextIfChanged()
            applyNativeConfigFromCurrentText()
            try settingsStore.save(settings)
            persistWorkspaceState()
            refreshNativeToolData()
            restartMemoryAutomationLoop()
            restartAlwaysOnAutomationLoop()
            settingsSaveNotice = t(.saved)
            statusLine = t(.settingsSaved)
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    func alwaysOnConfigSnapshot() -> AlwaysOnService.ConfigSnapshot {
        AlwaysOnService.ConfigSnapshot.from(values: NativeConfigService.scalarMap(from: pilotDeckConfigText))
    }

    func alwaysOnProjectIdentities(includeGeneral: Bool = false) -> [AlwaysOnProjectIdentity] {
        projects.compactMap { project in
            let isGeneral = isGeneralProject(project)
            guard includeGeneral || !isGeneral else { return nil }
            let rootPath = effectiveWorkspacePath(for: project)
            return AlwaysOnProjectIdentity(
                id: AlwaysOnService.normalizedProjectRoot(rootPath),
                projectName: project.name,
                displayName: project.displayName,
                rootPath: rootPath,
                isGeneral: isGeneral
            )
        }
    }

    func alwaysOnDashboardSnapshot(scope: WorkspaceContext?) -> AlwaysOnDashboardSnapshot {
        let config = alwaysOnConfigSnapshot()
        let identities: [AlwaysOnProjectIdentity]
        if let scope, !scope.isGeneral {
            identities = [
                AlwaysOnProjectIdentity(
                    id: AlwaysOnService.normalizedProjectRoot(scope.rootPath),
                    projectName: scope.projectName,
                    displayName: scope.displayName,
                    rootPath: scope.rootPath,
                    isGeneral: false
                ),
            ]
        } else {
            identities = alwaysOnProjectIdentities()
        }
        return alwaysOnService.dashboard(projects: identities, config: config)
    }

    func restartAlwaysOnAutomationLoop() {
        let config = alwaysOnConfigSnapshot()
        let identities = alwaysOnProjectIdentities()
        Task {
            await alwaysOnManager.start(config: config, projects: identities) { [weak self] project, config in
                guard let self else { return }
                await self.fireAlwaysOnDiscoveryIfEligible(project: project, config: config)
            }
        }
    }

    func startAlwaysOnDiscovery(context: WorkspaceContext) {
        let project = AlwaysOnProjectIdentity(
            id: AlwaysOnService.normalizedProjectRoot(context.rootPath),
            projectName: context.projectName,
            displayName: context.displayName,
            rootPath: context.rootPath,
            isGeneral: context.isGeneral
        )
        let config = alwaysOnConfigSnapshot()
        launchAlwaysOnBackgroundTask(label: "manual-discovery-\(UUID().uuidString)") { [weak self] in
            await self?.runAlwaysOnDiscovery(project: project, config: config, trigger: "manual")
        }
    }

    func runAlwaysOnPlan(_ plan: AlwaysOnPlan, context: WorkspaceContext) {
        let config = alwaysOnConfigSnapshot()
        let project = AlwaysOnProjectIdentity(
            id: AlwaysOnService.normalizedProjectRoot(context.rootPath),
            projectName: context.projectName,
            displayName: context.displayName,
            rootPath: context.rootPath,
            isGeneral: context.isGeneral
        )
        launchAlwaysOnBackgroundTask(label: "manual-plan-\(plan.id)-\(UUID().uuidString)") { [weak self] in
            await self?.runAlwaysOnPlanInBackground(plan: plan, project: project, config: config)
        }
    }

    func runAlwaysOnCronJob(_ job: AlwaysOnCronJob, context: WorkspaceContext) {
        let config = alwaysOnConfigSnapshot()
        let project = AlwaysOnProjectIdentity(
            id: AlwaysOnService.normalizedProjectRoot(context.rootPath),
            projectName: context.projectName,
            displayName: context.displayName,
            rootPath: context.rootPath,
            isGeneral: context.isGeneral
        )
        launchAlwaysOnBackgroundTask(label: "manual-cron-\(job.id)-\(UUID().uuidString)") { [weak self] in
            await self?.runAlwaysOnCronInBackground(job: job, project: project, config: config)
        }
    }

    private func launchAlwaysOnBackgroundTask(label: String, operation: @escaping @MainActor () async -> Void) {
        alwaysOnBackgroundTasks[label]?.cancel()
        let task = Task { @MainActor [weak self] in
            defer { self?.alwaysOnBackgroundTasks.removeValue(forKey: label) }
            guard !Task.isCancelled else { return }
            await operation()
        }
        alwaysOnBackgroundTasks[label] = task
    }

    func applyAlwaysOnCycle(cycleID: String, projectRoot: String) {
        let normalizedRoot = AlwaysOnService.normalizedProjectRoot(projectRoot)
        let project = alwaysOnProjectIdentities().first {
            AlwaysOnService.normalizedProjectRoot($0.rootPath) == normalizedRoot
        } ?? AlwaysOnProjectIdentity(
            id: normalizedRoot,
            projectName: URL(fileURLWithPath: normalizedRoot).lastPathComponent,
            displayName: URL(fileURLWithPath: normalizedRoot).lastPathComponent,
            rootPath: normalizedRoot,
            isGeneral: false
        )
        alwaysOnService.appendRunEvent(
            projectName: project.projectName,
            projectRoot: project.rootPath,
            kind: "apply",
            status: .applying,
            title: "Apply cycle",
            detail: cycleID,
            runId: nil,
            planId: nil,
            cycleId: cycleID
        )
        Task { @MainActor in
            do {
                let cycle = try await alwaysOnService.applyCycle(cycleID: cycleID, projectRoot: project.rootPath)
                alwaysOnService.appendRunEvent(
                    projectName: project.projectName,
                    projectRoot: project.rootPath,
                    kind: "apply",
                    status: .applied,
                    title: "Cycle applied",
                    detail: cycle.workspacePath ?? cycle.id,
                    runId: nil,
                    planId: cycle.planId,
                    cycleId: cycle.id
                )
            } catch {
                errorBanner = error.localizedDescription
                alwaysOnService.appendRunEvent(
                    projectName: project.projectName,
                    projectRoot: project.rootPath,
                    kind: "apply",
                    status: .applyFailed,
                    title: "Apply failed",
                    detail: error.localizedDescription,
                    runId: nil,
                    planId: nil,
                    cycleId: cycleID
                )
            }
            bumpToolRefresh()
        }
    }

    private func fireAlwaysOnDiscoveryIfEligible(project: AlwaysOnProjectIdentity, config: AlwaysOnService.ConfigSnapshot) async {
        let decision = alwaysOnService.evaluateGate(
            project: project,
            config: config,
            snapshot: AlwaysOnService.GateSnapshot(
                isProjectBusy: isAlwaysOnProjectBusy(rootPath: project.rootPath),
                lastUserMessageAt: lastUserMessageAtByProjectRoot[AlwaysOnService.normalizedProjectRoot(project.rootPath)],
                now: Date()
            )
        )
        alwaysOnService.recordGate(project: project, decision: decision)
        guard decision.allowed else { return }
        await runAlwaysOnDiscovery(project: project, config: config, trigger: "auto")
    }

    private func runAlwaysOnDiscovery(project: AlwaysOnProjectIdentity, config: AlwaysOnService.ConfigSnapshot, trigger: String) async {
        let runID = "discovery-\(UUID().uuidString)"
        let beforePlanIDs = Set(alwaysOnService.plans(projectRoot: project.rootPath).map(\.id))
        alwaysOnService.markDiscoveryStarted(project: project, runID: runID)
        alwaysOnService.appendRunEvent(
            projectName: project.projectName,
            projectRoot: project.rootPath,
            kind: "discovery",
            status: .running,
            title: trigger == "manual" ? "Manual discovery" : "Auto discovery",
            detail: project.displayName,
            runId: runID,
            planId: nil,
            cycleId: nil
        )
        let plans = alwaysOnService.plans(projectRoot: project.rootPath)
        let cronJobs = alwaysOnService.cronJobs(projectRoot: project.rootPath)
        let sessions = sessions(forProjectRoot: project.rootPath)
        let discoveryContext = alwaysOnService.discoveryContext(
            projectName: project.projectName,
            displayName: project.displayName,
            projectRoot: project.rootPath,
            plans: plans,
            cronJobs: cronJobs,
            sessions: sessions,
            memoryRecords: memoryService.list(projectName: project.projectName)
        )
        let prompt = alwaysOnService.discoveryPrompt(
            projectName: project.projectName,
            displayName: project.displayName,
            projectRoot: project.rootPath,
            context: discoveryContext,
            language: settings.language.resolved() == .chineseSimplified ? "zh-CN" : "en"
        )
        let chatHistory = alwaysOnChatHistoryJSON(sessions: sessions)
        let session = createAlwaysOnBackgroundSession(projectRoot: project.rootPath, title: "Always-On discovery: \(project.displayName)", runID: runID)
        let runRecord: AlwaysOnRunHistory?
        do {
            runRecord = try alwaysOnService.startDiscoveryRun(
                projectRoot: project.rootPath,
                title: trigger == "manual" ? "Manual discovery" : "Auto discovery",
                sessionId: session.id,
                runID: runID
            )
        } catch {
            AppLog.write("always-on discovery start history error: \(error.localizedDescription)", file: "always-on.log")
            runRecord = nil
        }
        let result = await runAlwaysOnAgentTurn(
            project: project,
            title: "Always-On discovery: \(project.displayName)",
            prompt: prompt,
            projectPath: project.rootPath,
            runID: runID,
            phase: "discovery",
            config: config,
            extraValues: [
                "alwaysOn.run.trigger": trigger,
                "alwaysOn.run.chatHistory": chatHistory,
            ],
            existingSession: session
        )
        let afterPlans = alwaysOnService.plans(projectRoot: project.rootPath)
        let createdCount = afterPlans.filter { !beforePlanIDs.contains($0.id) }.count
        let status: AlwaysOnStatus = result.succeeded
            ? (createdCount > 0 ? .completed : .noPlan)
            : .failed
        let discoverySummary = result.summary.nilIfBlank ?? "\(createdCount) plan(s) created"
        let timelineDetail = discoverySummary.count > 800
            ? "\(String(discoverySummary.prefix(800)))..."
            : discoverySummary
        if let runRecord {
            do {
                try alwaysOnService.finishDiscoveryRun(
                    run: runRecord,
                    projectRoot: project.rootPath,
                    status: status,
                    sessionId: result.sessionID,
                    outputLog: discoverySummary,
                    error: result.succeeded ? nil : result.summary.nilIfBlank,
                    metadata: [
                        "trigger": trigger,
                        "createdPlans": String(createdCount),
                        "sessionId": result.sessionID,
                    ]
                )
            } catch {
                AppLog.write("always-on discovery finish history error: \(error.localizedDescription)", file: "always-on.log")
            }
        }
        alwaysOnService.markDiscoveryFinished(project: project, runID: runID, status: status)
        alwaysOnService.appendRunEvent(
            projectName: project.projectName,
            projectRoot: project.rootPath,
            kind: "discovery",
            status: status,
            title: status == .noPlan ? "No plan" : "Discovery finished",
            detail: timelineDetail,
            runId: runID,
            planId: nil,
            cycleId: nil
        )
        bumpToolRefresh()
    }

    private func runAlwaysOnPlanInBackground(plan: AlwaysOnPlan, project: AlwaysOnProjectIdentity, config: AlwaysOnService.ConfigSnapshot) async {
        let preparation: AlwaysOnWorkspacePreparation
        do {
            preparation = try await alwaysOnService.prepareWorkspace(
                projectName: project.projectName,
                projectRoot: project.rootPath,
                config: config.workspace
            )
        } catch {
            errorBanner = error.localizedDescription
            alwaysOnService.appendRunEvent(
                projectName: project.projectName,
                projectRoot: project.rootPath,
                kind: "workspace",
                status: .failed,
                title: plan.title,
                detail: error.localizedDescription,
                runId: nil,
                planId: plan.id,
                cycleId: nil
            )
            return
        }

        let runID = "execution-\(UUID().uuidString)"
        let session = createAlwaysOnBackgroundSession(projectRoot: project.rootPath, title: "Always-On: \(plan.title)", runID: runID)
        let runRecord: AlwaysOnRunHistory?
        do {
            runRecord = try alwaysOnService.startPlanRun(
                plan: plan,
                projectRoot: project.rootPath,
                sessionId: session.id,
                runID: runID
            )
        } catch {
            AppLog.write("always-on plan start history error: \(error.localizedDescription)", file: "always-on.log")
            runRecord = nil
        }
        alwaysOnService.appendRunEvent(
            projectName: project.projectName,
            projectRoot: project.rootPath,
            kind: "execution",
            status: .running,
            title: plan.title,
            detail: preparation.workspacePath,
            runId: runID,
            planId: plan.id,
            cycleId: preparation.cycleId
        )
        let prompt = """
        Execute this Always-On plan in the isolated workspace.

        Original project root: \(project.rootPath)
        Isolated workspace: \(preparation.workspacePath)
        Workspace mode: \(preparation.mode)
        Plan id: \(plan.id)
        Plan title: \(plan.title)

        \(plan.content.isEmpty ? plan.summary : plan.content)

        Requirements:
        - Work only inside the isolated workspace.
        - Do not use interactive tools.
        - Do not run git push or git remote commands.
        - At the end, call always_on_report with a concise report.
        """
        let result = await runAlwaysOnAgentTurn(
            project: project,
            title: "Always-On: \(plan.title)",
            prompt: prompt,
            projectPath: preparation.workspacePath,
            runID: runID,
            phase: "execution",
            config: config,
            extraValues: [
                "alwaysOn.run.planId": plan.id,
                "alwaysOn.run.cycleId": preparation.cycleId,
                "alwaysOn.run.workspacePath": preparation.workspacePath,
            ],
            existingSession: session
        )
        let finalStatus: AlwaysOnStatus = result.succeeded ? .completed : .failed
        if let runRecord {
            do {
                try alwaysOnService.finishPlanRun(
                    plan: plan,
                    run: runRecord,
                    projectRoot: project.rootPath,
                    status: finalStatus,
                    sessionId: result.sessionID,
                    outputLog: result.summary.nilIfBlank ?? "Always-On execution finished.",
                    error: result.succeeded ? nil : result.summary.nilIfBlank,
                    metadata: [
                        "cycleId": preparation.cycleId,
                        "workspacePath": preparation.workspacePath,
                        "workspaceMode": preparation.mode,
                        "sessionId": result.sessionID,
                    ]
                )
            } catch {
                AppLog.write("always-on plan finish history error: \(error.localizedDescription)", file: "always-on.log")
            }
        }
        alwaysOnService.appendRunEvent(
            projectName: project.projectName,
            projectRoot: project.rootPath,
            kind: "execution",
            status: finalStatus,
            title: plan.title,
            detail: result.summary.nilIfBlank ?? preparation.workspacePath,
            runId: runID,
            planId: plan.id,
            cycleId: preparation.cycleId
        )
        bumpToolRefresh()
    }

    private func runAlwaysOnCronInBackground(job: AlwaysOnCronJob, project: AlwaysOnProjectIdentity, config: AlwaysOnService.ConfigSnapshot) async {
        let title = alwaysOnCronRunTitle(job)
        let preparation: AlwaysOnWorkspacePreparation
        do {
            preparation = try await alwaysOnService.prepareWorkspace(
                projectName: project.projectName,
                projectRoot: project.rootPath,
                config: config.workspace
            )
        } catch {
            errorBanner = error.localizedDescription
            alwaysOnService.appendRunEvent(
                projectName: project.projectName,
                projectRoot: project.rootPath,
                kind: "workspace",
                status: .failed,
                title: title,
                detail: error.localizedDescription,
                runId: nil,
                planId: nil,
                cycleId: nil
            )
            return
        }

        let runID = "cron-\(UUID().uuidString)"
        let session = createAlwaysOnBackgroundSession(projectRoot: project.rootPath, title: "Always-On: \(title)", runID: runID)
        let runRecord: AlwaysOnRunHistory?
        do {
            runRecord = try alwaysOnService.startCronRun(
                job: job,
                projectRoot: project.rootPath,
                sessionId: session.id,
                runID: runID
            )
        } catch {
            AppLog.write("always-on cron start history error: \(error.localizedDescription)", file: "always-on.log")
            runRecord = nil
        }
        alwaysOnService.appendRunEvent(
            projectName: project.projectName,
            projectRoot: project.rootPath,
            kind: "cron",
            status: .running,
            title: title,
            detail: preparation.workspacePath,
            runId: runID,
            planId: nil,
            cycleId: preparation.cycleId
        )
        let prompt = """
        Run this Always-On cron job in the isolated workspace.

        Original project root: \(project.rootPath)
        Isolated workspace: \(preparation.workspacePath)
        Workspace mode: \(preparation.mode)
        Cron id: \(job.id)
        Schedule: \(job.cron)

        \(job.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Run the scheduled Always-On task." : job.prompt)

        Requirements:
        - Work only inside the isolated workspace.
        - Do not use interactive tools.
        - Do not run git push or git remote commands.
        - At the end, call always_on_report with a concise report.
        """
        let result = await runAlwaysOnAgentTurn(
            project: project,
            title: "Always-On: \(title)",
            prompt: prompt,
            projectPath: preparation.workspacePath,
            runID: runID,
            phase: "execution",
            config: config,
            extraValues: [
                "alwaysOn.run.cronId": job.id,
                "alwaysOn.run.cycleId": preparation.cycleId,
                "alwaysOn.run.workspacePath": preparation.workspacePath,
            ],
            existingSession: session
        )
        let finalStatus: AlwaysOnStatus = result.succeeded ? .completed : .failed
        if let runRecord {
            do {
                try alwaysOnService.finishCronRun(
                    job: job,
                    run: runRecord,
                    projectRoot: project.rootPath,
                    status: finalStatus,
                    sessionId: result.sessionID,
                    outputLog: result.summary.nilIfBlank ?? "Always-On cron run finished.",
                    error: result.succeeded ? nil : result.summary.nilIfBlank,
                    metadata: [
                        "cycleId": preparation.cycleId,
                        "workspacePath": preparation.workspacePath,
                        "workspaceMode": preparation.mode,
                        "sessionId": result.sessionID,
                    ]
                )
            } catch {
                AppLog.write("always-on cron finish history error: \(error.localizedDescription)", file: "always-on.log")
            }
        }
        alwaysOnService.appendRunEvent(
            projectName: project.projectName,
            projectRoot: project.rootPath,
            kind: "cron",
            status: finalStatus,
            title: title,
            detail: result.summary.nilIfBlank ?? preparation.workspacePath,
            runId: runID,
            planId: nil,
            cycleId: preparation.cycleId
        )
        bumpToolRefresh()
    }

    private func alwaysOnCronRunTitle(_ job: AlwaysOnCronJob) -> String {
        let firstLine = job.prompt.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let title = firstLine.replacingOccurrences(of: #"^#\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? job.cron : title
    }

    private struct AlwaysOnTurnResult {
        var succeeded: Bool
        var sessionID: String
        var summary: String
    }

    private func runAlwaysOnAgentTurn(
        project: AlwaysOnProjectIdentity,
        title: String,
        prompt: String,
        projectPath: String,
        runID: String,
        phase: String,
        config: AlwaysOnService.ConfigSnapshot,
        extraValues: [String: String],
        existingSession: ProjectSession? = nil
    ) async -> AlwaysOnTurnResult {
        guard let nativeConfig = currentNativeConfigSnapshot() else {
            return AlwaysOnTurnResult(succeeded: false, sessionID: "", summary: "Native config is invalid.")
        }
        let entryID = nativeConfig.rawValues["router.routes.background.model"]?.nilIfBlank
            ?? nativeConfig.rawValues["router.routes.default.model"]?.nilIfBlank
            ?? nativeConfig.defaultEntryID
        let providerConfig = NativeConfigService.providerConfig(entryID: entryID, values: nativeConfig.rawValues)
            ?? nativeConfig.providerConfig
        let apiKey = NativeConfigService.resolvedAPIKey(
            routeEntryID: entryID,
            nativeConfig: nativeConfig
        )

        let session = existingSession ?? createAlwaysOnBackgroundSession(projectRoot: project.rootPath, title: title, runID: runID)
        let sessionID = session.id
        memoryProjectNameBySession[sessionID] = project.projectName
        memoryProjectRootBySession[sessionID] = project.rootPath
        let assistantID = UUID()
        let runStartedAt = Date()
        assistantSessionByID[assistantID] = sessionID
        let userMessage = ChatMessage(
            id: UUID(),
            sessionId: sessionID,
            provider: .pilotDeck,
            role: .user,
            blocks: [.text(prompt)],
            createdAt: Date(),
            isStreaming: false,
            tokenBudget: nil
        )
        let assistantMessage = ChatMessage(
            id: assistantID,
            sessionId: sessionID,
            provider: .pilotDeck,
            role: .assistant,
            blocks: [.text("")],
            createdAt: runStartedAt,
            isStreaming: true,
            tokenBudget: nil,
            runStartedAt: runStartedAt
        )
        messagesBySession[sessionID] = [userMessage, assistantMessage]
        markSession(sessionID, state: .processing)
        persistSessionMessages(sessionID: sessionID)

        var values = nativeConfig.rawValues
        values["alwaysOn.run.enabled"] = "true"
        values["alwaysOn.run.phase"] = phase
        values["alwaysOn.run.id"] = runID
        values["alwaysOn.projectName"] = project.projectName
        values["alwaysOn.projectRoot"] = project.rootPath
        values["alwaysOn.displayName"] = project.displayName
        values["alwaysOn.run.excludedTools"] = "AskQuestion,SwitchMode,Task"
        values["alwaysOn.run.deniedShellPatterns"] = "git push,git remote"
        values["alwaysOn.execution.maxTurns"] = String(config.execution.maxTurns)
        values["alwaysOn.execution.maxToolCalls"] = String(config.execution.maxToolCalls)
        values["alwaysOn.execution.timeoutMinutes"] = String(config.execution.timeoutMinutes)
        values["app.language"] = settings.language.resolved() == .chineseSimplified ? "zh-CN" : "en"
        for (key, value) in extraValues {
            values[key] = value
        }

        let requestContext = WorkspaceContext(
            projectID: nil,
            projectName: project.projectName,
            displayName: project.displayName,
            rootPath: projectPath,
            isGeneral: false
        )
        let request = AgentRequest(
            sessionId: sessionID,
            projectPath: projectPath,
            prompt: prompt,
            attachments: [],
            providerConfig: providerConfig,
            apiKey: apiKey,
            priorMessages: [],
            timeoutMs: max(60_000, config.execution.timeoutMinutes * 60_000),
            contextWindow: NativeConfigService.contextWindow(entryID: entryID, values: nativeConfig.rawValues) ?? nativeConfig.contextWindow,
            permissionMode: .bypassPermissions,
            runMode: .agent,
            workspaceContext: requestContext,
            toolSettings: settings.permissions,
            routerRoute: "always-on-\(phase)",
            fallbackRoutes: routerFallbackRoutes(
                primaryEntryID: entryID,
                scenario: "always-on-\(phase)",
                nativeConfig: nativeConfig,
                values: nativeConfig.rawValues
            ),
            nativeConfigValues: values,
            permissionHandler: nil
        )
        let runToken = UUID()
        var succeeded = false
        var sawTerminalEvent = false
        let taskKey = "\(phase)-\(runID)"
        alwaysOnBackgroundTasks[taskKey] = Task {}
        alwaysOnBackgroundRunTokens.insert(runToken)
        defer {
            alwaysOnBackgroundTasks.removeValue(forKey: taskKey)
            alwaysOnBackgroundRunTokens.remove(runToken)
        }
        do {
            for try await event in providerClient.stream(request: request) {
                if event.isTerminal {
                    sawTerminalEvent = true
                }
                handleAgentEvent(event, assistantID: assistantID, sessionID: sessionID, runToken: runToken)
            }
            if !sawTerminalEvent {
                handleAgentEvent(.complete(sessionId: sessionID), assistantID: assistantID, sessionID: sessionID, runToken: runToken)
            }
            succeeded = true
        } catch {
            handleAgentEvent(.error(error.localizedDescription), assistantID: assistantID, sessionID: sessionID, runToken: runToken)
        }
        let summary = messagesBySession[sessionID]?.last(where: { $0.role == .assistant })?.plainText ?? ""
        return AlwaysOnTurnResult(succeeded: succeeded, sessionID: sessionID, summary: summary)
    }

    private func createAlwaysOnBackgroundSession(projectRoot: String, title: String, runID: String) -> ProjectSession {
        let session = ProjectSession(
            id: "always-on-\(UUID().uuidString)",
            provider: .pilotDeck,
            title: title,
            summary: runID,
            createdAt: Date(),
            updatedAt: Date(),
            lastActivity: Date(),
            lastConversationAt: Date(),
            state: .idle,
            sessionKind: .backgroundTask,
            taskId: runID,
            taskStatus: "running",
            isReadOnly: true
        )
        if let index = projects.firstIndex(where: { AlwaysOnService.normalizedProjectRoot(effectiveWorkspacePath(for: $0)) == AlwaysOnService.normalizedProjectRoot(projectRoot) }) {
            projects[index].sessions.insert(session, at: 0)
        }
        return session
    }

    private func sessions(forProjectRoot rootPath: String) -> [ProjectSession] {
        let normalized = AlwaysOnService.normalizedProjectRoot(rootPath)
        return projects.first { AlwaysOnService.normalizedProjectRoot(effectiveWorkspacePath(for: $0)) == normalized }?.allSessions ?? []
    }

    private func isAlwaysOnProjectBusy(rootPath: String) -> Bool {
        let normalized = AlwaysOnService.normalizedProjectRoot(rootPath)
        if alwaysOnBackgroundTasks.keys.contains(where: { !$0.isEmpty }) {
            let hasProjectTask = projects
                .first { AlwaysOnService.normalizedProjectRoot(effectiveWorkspacePath(for: $0)) == normalized }?
                .allSessions
                .contains { $0.state == .processing } ?? false
            if hasProjectTask { return true }
        }
        return sessions(forProjectRoot: rootPath).contains { $0.state == .processing }
    }

    private func alwaysOnChatHistoryJSON(sessions: [ProjectSession], limit: Int = 12) -> String {
        let items = sessions
            .sorted { $0.activityDate > $1.activityDate }
            .prefix(limit)
            .map { session -> [String: Any] in
                let messages = messagesBySession[session.id] ?? []
                let lastUser = messages.last(where: { $0.role == .user })?.plainText
                let lastAssistant = messages.last(where: { $0.role == .assistant })?.plainText
                return [
                    "id": session.id,
                    "title": session.displayTitle,
                    "summary": session.summary,
                    "lastActivity": ISO8601DateFormatter().string(from: session.activityDate),
                    "lastUserMessage": String((lastUser ?? "").prefix(1_500)),
                    "lastAssistantMessage": String((lastAssistant ?? "").prefix(1_500)),
                ]
            }
        guard let data = try? JSONSerialization.data(withJSONObject: Array(items), options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    func openSettings(_ tab: SettingsMainTab = .appearance) {
        settingsInitialTab = tab
    }

    func t(_ key: L10nKey, _ args: CVarArg...) -> String {
        LocalizationService(language: settings.language).text(key, arguments: args)
    }

    func tabLabel(_ tab: AppTab) -> String {
        switch tab {
        case .chat:
            return t(.agent)
        case .alwaysOn:
            return t(.alwaysOn)
        case .files:
            return t(.files)
        case .shell:
            return t(.shell)
        case .git:
            return t(.git)
        case .tasks:
            return t(.tasks)
        case .memory:
            return t(.memory)
        case .skills:
            return t(.skills)
        case .dashboard:
            return t(.dashboard)
        case .preview:
            return t(.preview)
        case .plugin(let name):
            return name
        }
    }

    func runModeLabel(_ mode: ChatRunMode) -> String {
        switch mode {
        case .agent:
            return t(.chatRunModeAgent)
        case .plan:
            return t(.chatRunModePlan)
        }
    }

    func permissionModeLabel(_ mode: ComposerPermissionMode) -> String {
        switch mode {
        case .default:
            return t(.permissionModeDefault)
        case .bypassPermissions:
            return t(.permissionModeBypass)
        }
    }

    var selectedWorkspaceContext: WorkspaceContext? {
        guard let selectedProject else { return nil }
        return WorkspaceContext(
            projectID: selectedProject.id,
            projectName: selectedProject.name,
            displayName: selectedProject.displayName,
            rootPath: effectiveWorkspacePath(for: selectedProject),
            isGeneral: isGeneralProject(selectedProject)
        )
    }

    var effectiveSelectedWorkspacePath: String {
        if let selectedProject {
            return effectiveWorkspacePath(for: selectedProject)
        }
        return Self.normalizedGeneralWorkspacePath(settings.generalWorkspacePath)
    }

    func effectiveWorkspacePath(for project: WorkspaceProject) -> String {
        if isGeneralProject(project) {
            return Self.normalizedGeneralWorkspacePath(settings.generalWorkspacePath)
        }
        return project.rootPath
    }

    private func prepareSelectedWorkspacePathForRun() throws -> String {
        let workspacePath = effectiveSelectedWorkspacePath
        if selectedProject.map(isGeneralProject) ?? true {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: workspacePath),
                withIntermediateDirectories: true
            )
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workspacePath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NSError(
                domain: "PilotDeckWorkspace",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Workspace path does not exist: \(workspacePath). Check PilotDeck general workspace settings."]
            )
        }
        return workspacePath
    }

    func isGeneralProject(_ project: WorkspaceProject) -> Bool {
        project.name == "general" || project.displayName == "general"
    }

    private func memoryProjectName(_ project: WorkspaceProject) -> String? {
        isGeneralProject(project) ? nil : project.name
    }

    private func syncMemoryWorkspaceCatalog() {
        memoryService.updateWorkspaceCatalog(
            projects.map { project in
                MemoryWorkspaceCatalogEntry(
                    projectName: project.name,
                    displayName: project.displayName,
                    rootPath: effectiveWorkspacePath(for: project),
                    isGeneral: isGeneralProject(project)
                )
            }
        )
    }

    func refreshNativeToolData() {
        guard let selectedProject else { return }
        let workspacePath = effectiveWorkspacePath(for: selectedProject)
        syncMemoryWorkspaceCatalog()
        skillsService.refresh(projectPath: workspacePath, isGeneral: isGeneralProject(selectedProject))
        memoryService.loadWorkspaceRecords(projectRoot: workspacePath, projectName: memoryProjectName(selectedProject))
    }

    private func restartMemoryAutomationLoop() {
        memoryAutomationTask?.cancel()
        memoryAutomationTask = nil
        guard memoryService.settingsSnapshot().enabled else { return }
        memoryAutomationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.runDueMemoryAutomation()
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }

    private func kickMemoryAutomationCheck() {
        Task { @MainActor [weak self] in
            await self?.runDueMemoryAutomation()
        }
    }

    private func runDueMemoryAutomation() async {
        guard let selectedProject else { return }
        let projectRoot = effectiveWorkspacePath(for: selectedProject)
        let projectName = memoryProjectName(selectedProject)
        let before = memoryService.automaticJobKindsDue(projectRoot: projectRoot, projectName: projectName)
        guard !before.isEmpty else { return }
        let snapshot = await memoryService.runAutomaticJobsIfDue(
            projectRoot: projectRoot,
            projectName: projectName
        )
        if !snapshot.indexTraceRecords.isEmpty || !snapshot.dreamTraceRecords.isEmpty {
            statusLine = t(.memory)
            bumpToolRefresh()
        }
    }

    func addAllowedTool(_ tool: String) {
        let canonical = canonicalPermissionRule(tool)
        guard !canonical.isEmpty else { return }
        removeMatchingPermissionRule(canonical, from: \.disallowedTools)
        addUnique(canonical, to: \.allowedTools)
        persistSettingsAfterPermissionChange()
    }

    func addBlockedTool(_ tool: String) {
        let canonical = canonicalPermissionRule(tool)
        guard !canonical.isEmpty else { return }
        guard canonical != "WebSearch" else { return }
        removeMatchingPermissionRule(canonical, from: \.allowedTools)
        addUnique(canonical, to: \.disallowedTools)
        persistSettingsAfterPermissionChange()
    }

    func grantAllowedToolFromChat(_ tool: String) {
        let canonical = canonicalPermissionRule(tool)
        guard !canonical.isEmpty else { return }
        settings.permissions.disallowedTools.removeAll { permissionRuleEquals($0, canonical) }
        addUnique(canonical, to: \.allowedTools)
        persistSettingsAfterPermissionChange()
    }

    func removeAllowedTool(_ tool: String) {
        settings.permissions.allowedTools.removeAll { permissionRuleEquals($0, tool) }
        settings.permissions.lastUpdated = Date()
        persistSettingsAfterPermissionChange()
    }

    func removeBlockedTool(_ tool: String) {
        settings.permissions.disallowedTools.removeAll { permissionRuleEquals($0, tool) }
        settings.permissions.lastUpdated = Date()
        persistSettingsAfterPermissionChange()
    }

    func exportPermissions(to url: URL) throws {
        let payload: [String: Any] = [
            "version": 1,
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "source": PermissionsExportDefaults.source,
            "allowedTools": settings.permissions.allowedTools,
            "disallowedTools": settings.permissions.disallowedTools,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    func importPermissions(from url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let allowed = payload["allowedTools"] as? [String] ?? []
        let blocked = payload["disallowedTools"] as? [String] ?? []
        let mergedAllowed = uniqueCanonicalRules(settings.permissions.allowedTools + allowed)
        let mergedBlocked = uniqueCanonicalRules(settings.permissions.disallowedTools + blocked)
            .filter { !Self.isWebSearchPermissionRule($0) }
        settings.permissions.disallowedTools = mergedBlocked
        settings.permissions.allowedTools = mergedAllowed
        settings.permissions.lastUpdated = Date()
        persistSettingsAfterPermissionChange()
    }

    func requestAgentPermission(_ request: AgentPermissionRequest) async -> AgentPermissionDecision {
        if !pendingPermissions.contains(where: { $0.id == request.id }) {
            pendingPermissions.append(
                PermissionRequest(
                    id: request.id,
                    sessionId: request.sessionId,
                    toolName: request.toolName,
                    inputJSON: request.inputJSON,
                    reason: request.reason,
                    scope: request.scope,
                    createdAt: Date(),
                    kind: request.kind,
                    interactivePayload: request.interactivePayload
                )
            )
        }
        statusLine = request.reason
        return await withCheckedContinuation { continuation in
            permissionContinuations[request.id] = continuation
        }
    }

    func approvePermission(_ id: UUID, remember: Bool = false, updatedInputJSON: String? = nil) {
        guard let request = pendingPermissions.first(where: { $0.id == id }) else { return }
        pendingPermissions.removeAll { $0.id == id }
        if remember {
            grantAllowedToolFromChat(request.toolName)
        }
        if request.kind == .exitPlanMode {
            updateComposerRunModeAfterPlanDecision(updatedInputJSON: updatedInputJSON)
        }
        finishPermissionActivity(request, state: .completed)
        statusLine = t(.permissionAllowedFormat, request.toolName)
        permissionContinuations.removeValue(forKey: id)?.resume(returning: .allow(remember: remember, updatedInputJSON: updatedInputJSON))
    }

    func denyPermission(_ id: UUID) {
        guard let request = pendingPermissions.first(where: { $0.id == id }) else { return }
        pendingPermissions.removeAll { $0.id == id }
        if request.kind == .exitPlanMode {
            composerRunMode = .agent
        }
        finishPermissionActivity(request, state: .cancelled)
        statusLine = t(.permissionDeniedFormat, request.toolName)
        permissionContinuations.removeValue(forKey: id)?.resume(returning: .deny)
    }

    private func updateComposerRunModeAfterPlanDecision(updatedInputJSON: String?) {
        guard let updatedInputJSON,
              let data = updatedInputJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            composerRunMode = .agent
            return
        }
        let mode = ((object["mode"] as? String) ?? "agent")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        composerRunMode = mode == "plan" ? .plan : .agent
    }

    private func applyNativeConfigFromCurrentText() {
        guard let native = NativeConfigService.snapshot(from: pilotDeckConfigText) else { return }
        var updated = settings
        updated.providerConfig = native.providerConfig
        updated.apiTimeoutMs = native.apiTimeoutMs
        updated.contextWindow = native.contextWindow
        if let workspacesRoot = native.workspacesRoot?.nilIfBlankOrConfigNull {
            updated.workspacesRoot = Self.normalizedWorkspacesRoot(workspacesRoot)
        }
        if let generalWorkspacePath = native.generalWorkspacePath?.nilIfBlankOrConfigNull {
            updated.generalWorkspacePath = Self.normalizedGeneralWorkspacePath(generalWorkspacePath)
        }
        settings = Self.normalizedSettings(updated)
        memoryService.updateSettings(MemorySettingsSnapshot.fromConfigValues(native.rawValues))
    }

    private func loadPilotDeckConfigText() {
        pilotDeckConfigText = (try? String(contentsOf: Self.pilotDeckConfigURL(), encoding: .utf8))
            ?? Self.legacyPilotDeckConfigURLs().lazy.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.first
            ?? Self.defaultPilotDeckConfigText()
    }

    private func currentNativeConfigSnapshot() -> NativeConfigSnapshot? {
        NativeConfigService.snapshot(from: pilotDeckConfigText)
    }

    private func savePilotDeckConfigTextIfChanged() throws {
        let url = Self.pilotDeckConfigURL()
        let nextText = NativeConfigService.webSchemaConfigTextIfNeeded(
            from: pilotDeckConfigText,
            homePath: FileManager.default.homeDirectoryForCurrentUser.path,
            userName: NSUserName()
        )
        if nextText != pilotDeckConfigText {
            pilotDeckConfigText = nextText
        }
        let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard nextText != old else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try nextText.write(to: url, atomically: true, encoding: .utf8)
    }

    static func pilotDeckConfigURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        PilotDeckConfigPath.configURL(environment: environment, home: home)
    }

    static func legacyPilotDeckConfigURLs(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        PilotDeckConfigPath.legacyConfigURLs(home: home)
    }

    private func bootstrapLocalDebugConfigIfNeeded() throws {
        let url = Self.pilotDeckConfigURL()
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        if let legacyURL = Self.legacyPilotDeckConfigURLs().first(where: { FileManager.default.fileExists(atPath: $0.path) }),
           let legacyText = try? String(contentsOf: legacyURL, encoding: .utf8) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let migratedText = NativeConfigService.webSchemaConfigTextIfNeeded(
                from: legacyText,
                homePath: FileManager.default.homeDirectoryForCurrentUser.path,
                userName: NSUserName()
            )
            try migratedText.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.defaultPilotDeckConfigText().write(to: url, atomically: true, encoding: .utf8)
    }

    private func logBundleNetworkPolicy() {
        let ats = Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any]
        let arbitraryLoads = ats?["NSAllowsArbitraryLoads"] as? Bool ?? false
        let localNetworking = ats?["NSAllowsLocalNetworking"] as? Bool ?? false
        AppLog.write("bundle=\(Bundle.main.bundleIdentifier ?? "unknown") ats.arbitraryLoads=\(arbitraryLoads) ats.localNetworking=\(localNetworking)")
    }

    private func loadManualProjectsFromPilotDeckConfig() {
        guard let url = Self.pilotDeckProjectConfigURLs().first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawProjects = json["projects"] as? [String: Any] else { return }

        var loaded: [WorkspaceProject] = []
        for (projectName, value) in rawProjects {
            guard let object = value as? [String: Any],
                  object["manuallyAdded"] as? Bool == true,
                  let originalPath = object["originalPath"] as? String else { continue }
            let resolved = NSString(string: originalPath).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: resolved) else { continue }
            let displayName = object["displayName"] as? String
            loaded.append(
                WorkspaceProject(
                    id: UUID(),
                    name: projectName,
                    displayName: (displayName?.isEmpty == false ? displayName : URL(fileURLWithPath: resolved).lastPathComponent) ?? URL(fileURLWithPath: resolved).lastPathComponent,
                    rootPath: resolved,
                    sessions: [],
                    codexSessions: [],
                    cursorSessions: [],
                    geminiSessions: [],
                    createdAt: Date(),
                    lastActivity: Date()
                )
            )
        }

        for project in loaded.sorted(by: { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }) {
            guard !projects.contains(where: { $0.rootPath == project.rootPath || $0.name == project.name }) else { continue }
            projects.append(project)
        }
        projects = WorkspaceService.sortedProjects(projects, order: settings.projectSortOrder)
        if selectedProjectID == nil {
            selectedProjectID = projects.first?.id
        }
    }

    private func persistManualProject(_ project: WorkspaceProject) throws {
        let url = Self.pilotDeckProjectConfigURL()
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = json
        }
        var rawProjects = root["projects"] as? [String: Any] ?? [:]
        rawProjects[project.name] = [
            "manuallyAdded": true,
            "originalPath": project.rootPath,
            "displayName": project.displayName,
        ]
        root["projects"] = rawProjects
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    private func removeManualProjectFromConfig(_ project: WorkspaceProject) throws {
        let url = Self.pilotDeckProjectConfigURL()
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = json
        }
        var rawProjects = root["projects"] as? [String: Any] ?? [:]
        rawProjects.removeValue(forKey: project.name)
        root["projects"] = rawProjects
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    private static func pilotDeckProjectConfigURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pilotdeck", isDirectory: true)
            .appendingPathComponent("project-config.json")
    }

    private static func pilotDeckProjectConfigURLs() -> [URL] {
        [pilotDeckProjectConfigURL()]
    }

    private static func defaultPilotDeckConfigText() -> String {
        PilotDeckConfigDefaults.configText(
            homePath: FileManager.default.homeDirectoryForCurrentUser.path,
            userName: NSUserName()
        )
    }

    private func promptTitle(from prompt: String) -> String {
        let line = prompt.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return t(.newSession) }
        return String(trimmed.prefix(72))
    }

    private func addUnique(_ tool: String, to keyPath: WritableKeyPath<ToolPermissionSettings, [String]>) {
        let trimmed = canonicalPermissionRule(tool)
        guard !trimmed.isEmpty else { return }
        if !settings.permissions[keyPath: keyPath].contains(where: { permissionRuleEquals($0, trimmed) }) {
            settings.permissions[keyPath: keyPath].append(trimmed)
            settings.permissions.lastUpdated = Date()
        }
    }

    private func removeMatchingPermissionRule(_ tool: String, from keyPath: WritableKeyPath<ToolPermissionSettings, [String]>) {
        let count = settings.permissions[keyPath: keyPath].count
        settings.permissions[keyPath: keyPath].removeAll { permissionRuleEquals($0, tool) }
        if settings.permissions[keyPath: keyPath].count != count {
            settings.permissions.lastUpdated = Date()
        }
    }

    private func canonicalPermissionRule(_ tool: String) -> String {
        let trimmed = tool.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let lowercased = trimmed.lowercased()
        if lowercased.hasPrefix("bash("), trimmed.hasSuffix(")") {
            return trimmed
        }
        return AgentToolNameCanonicalizer.canonical(trimmed)
    }

    private func permissionRuleEquals(_ lhs: String, _ rhs: String) -> Bool {
        canonicalPermissionRule(lhs) == canonicalPermissionRule(rhs)
    }

    private func uniqueCanonicalRules(_ rules: [String]) -> [String] {
        var result: [String] = []
        for rule in rules {
            let canonical = canonicalPermissionRule(rule)
            guard !canonical.isEmpty, !result.contains(where: { permissionRuleEquals($0, canonical) }) else { continue }
            result.append(canonical)
        }
        return result
    }

    private func persistSettingsAfterPermissionChange() {
        do {
            try settingsStore.save(settings)
        } catch {
            AppLog.write("failed to persist permission settings: \(error.localizedDescription)", file: "permissions.log")
            errorBanner = error.localizedDescription
        }
    }

    private var selectedProjectIndex: Int? {
        guard let selectedProjectID else { return nil }
        return projects.firstIndex(where: { $0.id == selectedProjectID })
    }

    private func loadPersistedWorkspaceState() -> WorkspaceStatePersistence.Selection? {
        guard let snapshot = WorkspaceStatePersistence.load() else {
            ensureGeneralProject()
            return nil
        }
        let restored = snapshot.projects
            .map(Self.restoredProject)
            .filter { project in
                isGeneralProject(project) || FileManager.default.fileExists(atPath: project.rootPath)
            }
        if !restored.isEmpty {
            projects = restored
        }
        ensureGeneralProject()
        return snapshot.selection
    }

    private func restoreWorkspaceSelection(_ selection: WorkspaceStatePersistence.Selection?) {
        let normalizedProjectRoot = selection?.projectRoot.map(normalizedPath)
        if let normalizedProjectRoot,
           let project = projects.first(where: { normalizedPath(effectiveWorkspacePath(for: $0)) == normalizedProjectRoot }) {
            selectedProjectID = project.id
        } else if let selectedProjectID,
                  projects.contains(where: { $0.id == selectedProjectID }) {
            // Keep the currently selected project from the in-memory bootstrap.
        } else {
            selectedProjectID = projects.first?.id
        }

        if let sessionID = selection?.sessionID,
           selectedProject?.allSessions.contains(where: { $0.id == sessionID }) == true {
            selectedSessionID = sessionID
            loadPersistedMessagesIfNeeded(sessionID: sessionID)
        } else {
            selectedSessionID = nil
        }
        restoreComposerPermissionMode(for: selectedSessionID)
    }

    private func persistWorkspaceState() {
        let persistedProjects = projects.map(Self.projectForPersistence)
        WorkspaceStatePersistence.save(
            projects: persistedProjects,
            selection: WorkspaceStatePersistence.Selection(
                projectRoot: selectedProject.map { effectiveWorkspacePath(for: $0) },
                sessionID: selectedSessionID
            )
        )
        persistSharedIndexes(projects: persistedProjects)
    }

    private func ensureGeneralProject() {
        guard !projects.contains(where: isGeneralProject) else { return }
        projects.insert(
            WorkspaceProject(
                id: UUID(),
                name: "general",
                displayName: "general",
                rootPath: Self.normalizedGeneralWorkspacePath(settings.generalWorkspacePath),
                sessions: [],
                codexSessions: [],
                cursorSessions: [],
                geminiSessions: [],
                createdAt: Date(),
                lastActivity: Date()
            ),
            at: 0
        )
    }

    private func mergeSharedProjectPathIndex() {
        ensureGeneralProject()
        let snapshot = SharedProjectPathIndexStore.load()
        let deletedRoots = Set(snapshot.projects.compactMap { entry -> String? in
            entry.deletedAt == nil ? nil : normalizedPath(entry.rootPath)
        })
        var indexedProjects = snapshot.projects.filter { $0.deletedAt == nil }
        let webProjects = PilotDeckWebHistoryStore.loadKnownProjects()
            .filter { !deletedRoots.contains(normalizedPath($0.rootPath)) }
            .map {
                SharedProjectPathIndexStore.Entry(
                    rootPath: $0.rootPath,
                    projectName: $0.projectName,
                    displayName: $0.displayName,
                    isGeneral: false,
                    sources: ["web"],
                    createdAt: Date(),
                    updatedAt: Date(),
                    deletedAt: nil
                )
            }
        indexedProjects.append(contentsOf: webProjects)

        for entry in indexedProjects where !entry.isGeneral {
            let rootPath = normalizedPath(entry.rootPath)
            guard FileManager.default.fileExists(atPath: rootPath) else { continue }
            guard !projects.contains(where: { normalizedPath(effectiveWorkspacePath(for: $0)) == rootPath }) else { continue }
            projects.append(
                WorkspaceProject(
                    id: UUID(),
                    name: entry.projectName.nilIfBlank ?? WorkspaceService.projectName(for: rootPath),
                    displayName: entry.displayName.nilIfBlank ?? URL(fileURLWithPath: rootPath).lastPathComponent,
                    rootPath: rootPath,
                    sessions: [],
                    codexSessions: [],
                    cursorSessions: [],
                    geminiSessions: [],
                    createdAt: entry.createdAt,
                    lastActivity: entry.updatedAt
                )
            )
        }
        projects = WorkspaceService.sortedProjects(projects, order: settings.projectSortOrder)
    }

    private func mergePilotDeckWebHistory() {
        ensureGeneralProject()
        if let generalHistory = PilotDeckWebHistoryStore.loadGeneralHistory(),
           let generalIndex = projects.firstIndex(where: isGeneralProject) {
            for session in generalHistory.sessions {
                mergeImportedSession(session, into: &projects[generalIndex].sessions)
            }
            projects[generalIndex].sessions.sort { $0.activityDate > $1.activityDate }
            projects[generalIndex].lastActivity = projects[generalIndex].latestActivity
        }

        let histories = PilotDeckWebHistoryStore.loadProjects()

        for history in histories {
            let normalizedRoot = normalizedPath(history.rootPath)
            let index: Int
            if let existing = projects.firstIndex(where: { normalizedPath(effectiveWorkspacePath(for: $0)) == normalizedRoot }) {
                index = existing
            } else {
                projects.append(
                    WorkspaceProject(
                        id: UUID(),
                        name: WorkspaceService.projectName(for: history.rootPath),
                        displayName: URL(fileURLWithPath: history.rootPath).lastPathComponent,
                        rootPath: history.rootPath,
                        sessions: [],
                        codexSessions: [],
                        cursorSessions: [],
                        geminiSessions: [],
                        createdAt: history.sessions.map(\.createdAt).min() ?? Date(),
                        lastActivity: history.sessions.map(\.activityDate).max()
                    )
                )
                index = projects.count - 1
            }

            for session in history.sessions {
                mergeImportedSession(session, into: &projects[index].sessions)
            }
            projects[index].sessions.sort { $0.activityDate > $1.activityDate }
            projects[index].lastActivity = projects[index].latestActivity
        }
        projects = WorkspaceService.sortedProjects(projects, order: settings.projectSortOrder)
    }

    private func mergeSharedSessionIndex() {
        guard let paths = try? AppPaths.current() else { return }
        let entries = SharedSessionIndexStore.loadEntries()
        guard !entries.isEmpty else { return }

        var mergedCount = 0
        for entry in entries {
            let normalizedRoot = normalizedPath(entry.projectRoot)
            guard let projectIndex = projects.firstIndex(where: {
                normalizedPath(effectiveWorkspacePath(for: $0)) == normalizedRoot
            }) else { continue }
            guard entry.hasReadableTranscript(nativeSessionsDirectory: paths.sessions) else { continue }
            guard !projects[projectIndex].allSessions.contains(where: { $0.id == entry.session.id }) else { continue }

            mergeImportedSession(entry.session, into: &projects[projectIndex].sessions)
            projects[projectIndex].sessions.sort { $0.activityDate > $1.activityDate }
            projects[projectIndex].lastActivity = projects[projectIndex].latestActivity
            mergedCount += 1
        }

        if mergedCount > 0 {
            projects = WorkspaceService.sortedProjects(projects, order: settings.projectSortOrder)
            AppLog.write("merged \(mergedCount) session index entr\(mergedCount == 1 ? "y" : "ies") from shared session index")
        }
    }

    private func mergeImportedSession(_ session: ProjectSession, into sessions: inout [ProjectSession]) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index].title = session.title
            sessions[index].summary = session.summary
            sessions[index].updatedAt = maxDate(sessions[index].updatedAt, session.updatedAt)
            sessions[index].lastActivity = maxDate(sessions[index].lastActivity, session.lastActivity)
            sessions[index].lastConversationAt = maxDate(sessions[index].lastConversationAt, session.lastConversationAt)
            sessions[index].messageCount = session.messageCount ?? sessions[index].messageCount
            sessions[index].relativeTranscriptPath = session.relativeTranscriptPath ?? sessions[index].relativeTranscriptPath
            sessions[index].transcriptKey = session.transcriptKey ?? sessions[index].transcriptKey
        } else {
            sessions.append(session)
        }
    }

    private func recoverLocalSessionIndex() {
        guard let paths = try? AppPaths.current() else { return }
        let knownProjectRoots = projectRootIndex()
        let recovered = LocalSessionIndexRecovery.recover(
            sessionsDirectory: paths.sessions,
            knownProjectRoots: knownProjectRoots,
            generalProjectRoot: projects.first(where: isGeneralProject).map { normalizedPath(effectiveWorkspacePath(for: $0)) }
        )
        guard !recovered.isEmpty else { return }

        var recoveredCount = 0
        for recoveredSession in recovered {
            guard !projects.contains(where: { project in
                project.allSessions.contains(where: { $0.id == recoveredSession.session.id })
            }) else { continue }
            guard let projectIndex = projects.firstIndex(where: {
                normalizedPath(effectiveWorkspacePath(for: $0)) == recoveredSession.projectRoot
            }) else { continue }

            mergeImportedSession(recoveredSession.session, into: &projects[projectIndex].sessions)
            projects[projectIndex].sessions.sort { $0.activityDate > $1.activityDate }
            projects[projectIndex].lastActivity = projects[projectIndex].latestActivity
            recoveredCount += 1
        }

        if recoveredCount > 0 {
            projects = WorkspaceService.sortedProjects(projects, order: settings.projectSortOrder)
            AppLog.write("recovered \(recoveredCount) local session index entr\(recoveredCount == 1 ? "y" : "ies") from persisted chat messages")
        }
    }

    private func projectRootIndex() -> [String] {
        var roots: [String] = []
        for project in projects {
            let root = normalizedPath(effectiveWorkspacePath(for: project))
            if !roots.contains(root) {
                roots.append(root)
            }
        }
        return roots
    }

    private func persistSharedIndexes(projects persistedProjects: [WorkspaceProject]) {
        guard !persistedProjects.isEmpty else { return }
        let projectEntries = persistedProjects.map { project in
            SharedProjectPathIndexStore.Entry(
                rootPath: normalizedPath(effectiveWorkspacePath(for: project)),
                projectName: project.name,
                displayName: project.displayName,
                isGeneral: isGeneralProject(project),
                sources: ["mac-native"],
                createdAt: project.createdAt,
                updatedAt: project.latestActivity,
                deletedAt: nil
            )
        }
        SharedProjectPathIndexStore.upsert(projectEntries)

        let sessionEntries = persistedProjects.flatMap { project in
            let rootPath = normalizedPath(effectiveWorkspacePath(for: project))
            return project.allSessions.map { session in
                SharedSessionIndexStore.Entry(
                    projectRoot: rootPath,
                    session: Self.projectSessionForIndex(session),
                    source: session.transcriptKey == "pilotdeck-web" ? "web" : "mac-native",
                    updatedAt: session.activityDate
                )
            }
        }
        SharedSessionIndexStore.save(entries: sessionEntries)
    }

    fileprivate static func projectSessionForIndex(_ session: ProjectSession) -> ProjectSession {
        restoredSession(session)
    }

    private static func restoredProject(_ project: WorkspaceProject) -> WorkspaceProject {
        var restored = project
        restored.sessions = restored.sessions.map(restoredSession)
        restored.codexSessions = restored.codexSessions.map(restoredSession)
        restored.cursorSessions = restored.cursorSessions.map(restoredSession)
        restored.geminiSessions = restored.geminiSessions.map(restoredSession)
        return restored
    }

    private static func restoredSession(_ session: ProjectSession) -> ProjectSession {
        var restored = session
        if restored.state == .processing {
            restored.state = .idle
        }
        return restored
    }

    private static func projectForPersistence(_ project: WorkspaceProject) -> WorkspaceProject {
        var persisted = project
        persisted.sessions = persisted.sessions.map(restoredSession)
        persisted.codexSessions = persisted.codexSessions.map(restoredSession)
        persisted.cursorSessions = persisted.cursorSessions.map(restoredSession)
        persisted.geminiSessions = persisted.geminiSessions.map(restoredSession)
        return persisted
    }

    private func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            .standardizedFileURL
            .path
    }

    private func maxDate(_ left: Date?, _ right: Date?) -> Date? {
        switch (left, right) {
        case (.some(let left), .some(let right)):
            return max(left, right)
        case (.some(let left), .none):
            return left
        case (.none, .some(let right)):
            return right
        case (.none, .none):
            return nil
        }
    }

    private func runGitOperation(label: String, operation: @escaping @Sendable (GitService, URL) async throws -> String) {
        guard let selectedProject else {
            gitOutput = "No project selected."
            return
        }
        gitOutput = "\(label)..."
        let service = gitService
        let repo = URL(fileURLWithPath: effectiveWorkspacePath(for: selectedProject))
        Task { @MainActor in
            do {
                gitOutput = try await operation(service, repo)
                if gitOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    gitOutput = "\(label) complete."
                }
            } catch {
                gitOutput = error.localizedDescription
            }
        }
    }

    private func renameSession(in sessions: inout [ProjectSession], sessionID: String, title: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].title = title
        sessions[index].updatedAt = Date()
    }

    private func removeSession(from sessions: inout [ProjectSession], sessionID: String) {
        sessions.removeAll { $0.id == sessionID }
    }

    private func removeSessionArtifacts(_ sessionID: String) {
        messagesBySession.removeValue(forKey: sessionID)
        activitiesBySession.removeValue(forKey: sessionID)
        turnsBySession.removeValue(forKey: sessionID)
        turnItemsBySession.removeValue(forKey: sessionID)
        lastErrorBySession.removeValue(forKey: sessionID)
        lastWarningBySession.removeValue(forKey: sessionID)
        memoryProjectNameBySession.removeValue(forKey: sessionID)
        memoryProjectRootBySession.removeValue(forKey: sessionID)
        guard let paths = try? AppPaths.current() else { return }
        try? FileManager.default.removeItem(at: paths.sessions.appendingPathComponent("\(sessionID).json"))
    }

    private func append(_ message: ChatMessage) {
        var messages = messagesBySession[message.sessionId] ?? []
        messages.append(message)
        messagesBySession[message.sessionId] = messages
        streamRenderRevision += 1
    }

    private func handleAgentEvent(_ event: AgentEvent, assistantID: UUID, sessionID explicitSessionID: String? = nil, runToken: UUID? = nil) {
        if let runToken,
           !alwaysOnBackgroundRunTokens.contains(runToken),
           activeRunToken != runToken {
            return
        }
        let targetSessionID = explicitSessionID ?? assistantSessionByID[assistantID] ?? selectedSessionID
        switch event {
        case .turnStarted(let turn):
            lastWarningBySession.removeValue(forKey: turn.sessionId)
            if selectedSessionID == turn.sessionId {
                warningBanner = nil
            }
            upsertTurn(turn)
        case .turnItemStarted(let item), .turnItemUpdated(let item), .turnItemCompleted(let item):
            upsertTurnItem(item)
        case .turnCompleted(let turn):
            upsertTurn(turn)
        case .sessionCreated(let sessionId):
            statusLine = t(.sessionStartedFormat, sessionId)
        case .contentDelta(let text):
            queueAssistantDelta(text, assistantID: assistantID)
        case .reasoningDelta(let text):
            flushPendingAssistantDelta(assistantID: assistantID)
            appendAssistantReasoningDelta(text, assistantID: assistantID, sessionID: targetSessionID)
        case .toolUse(let id, let name, let inputJSON):
            flushPendingAssistantDelta(assistantID: assistantID)
            let isInteractiveControl = PlanWorkflowPresentation.isInteractiveControl(name)
            let interactiveDetailMessages = interactiveControlDetailMessages(for: name, inputJSON: inputJSON)
            let displayInput = AgentToolInputPreview.activityDetail(toolName: name, inputJSON: inputJSON)
            if name == "Skill", let targetSessionID {
                routingService.recordSkillInvocation(
                    sessionID: targetSessionID,
                    title: sessionTitle(for: targetSessionID),
                    projectName: routingProjectNameBySession[targetSessionID] ?? "general",
                    skill: Self.skillName(from: inputJSON)
                )
            } else if AgentToolNameCanonicalizer.canonical(name) == "Task", let targetSessionID {
                routingService.recordSubagentInvocation(
                    sessionID: targetSessionID,
                    title: sessionTitle(for: targetSessionID),
                    projectName: routingProjectNameBySession[targetSessionID] ?? "general",
                    model: routingModelBySession[targetSessionID] ?? "unknown",
                    tier: routingTierBySession[targetSessionID] ?? RouterTier.complex.rawValue,
                    inputJSON: inputJSON
                )
            }
            upsertActivity(
                id: id,
                title: interactiveControlTitle(for: name) ?? t(.runningToolFormat, name),
                detail: isInteractiveControl ? "" : displayInput,
                phase: activityPhase(for: name),
                state: .running,
                toolName: name,
                detailMessages: isInteractiveControl ? interactiveDetailMessages : [displayInput],
                expandedDefault: false,
                anchorBlockID: assistantID.uuidString,
                sessionID: targetSessionID
            )
            appendAssistantBlock(.toolCall(ToolCall(id: id, name: name, inputJSON: inputJSON, status: .pending)), assistantID: assistantID, sessionID: targetSessionID)
        case .toolResult(let id, let output, let isError):
            flushPendingAssistantDelta(assistantID: assistantID)
            updateActivity(id: id, state: isError ? .failed : .completed, detail: output, sessionID: targetSessionID)
            appendAssistantBlock(.toolResult(ToolResult(toolCallId: id, output: output, isError: isError)), assistantID: assistantID, sessionID: targetSessionID)
        case .permissionRequest(let request):
            let isInteractiveControl = PlanWorkflowPresentation.isInteractiveControl(request.toolName)
            let displayInput = AgentToolInputPreview.activityDetail(toolName: request.toolName, inputJSON: request.inputJSON)
            upsertActivity(
                id: "permission-\(request.id.uuidString)",
                title: interactiveControlTitle(for: request.toolName) ?? request.reason,
                detail: isInteractiveControl ? "" : displayInput,
                phase: activityPhase(for: request.toolName),
                state: .running,
                toolName: request.toolName,
                detailMessages: isInteractiveControl ? [] : [displayInput],
                expandedDefault: AgentActivityPresentationPolicy.expandsPermissionByDefault(request.kind),
                anchorBlockID: assistantID.uuidString,
                sessionID: targetSessionID
            )
        case .status(let status):
            statusLine = status
            if let targetSessionID, let notice = automaticPauseNotice(for: status) {
                lastWarningBySession[targetSessionID] = notice
                if selectedSessionID == targetSessionID {
                    warningBanner = notice
                }
            }
            guard !isInlineToolProgressStatus(status) else { return }
            upsertActivity(
                id: statusActivityID(status, assistantID: assistantID),
                title: statusTitle(status),
                detail: statusDetail(status),
                phase: .status,
                state: .running,
                anchorBlockID: assistantID.uuidString,
                sessionID: targetSessionID
            )
        case .routerFallback(_, let model):
            if let targetSessionID {
                routingModelBySession[targetSessionID] = model
            }
        case .tokenUsage(let usage, let contextWindow):
            if let targetSessionID {
                routingService.recordTokenUsage(
                    sessionID: targetSessionID,
                    title: sessionTitle(for: targetSessionID),
                    projectName: routingProjectNameBySession[targetSessionID] ?? "general",
                    model: routingModelBySession[targetSessionID] ?? settings.providerConfig.model,
                    tier: routingTierBySession[targetSessionID] ?? RouterTier.complex.rawValue,
                    usage: usage,
                    contextWindow: contextWindow,
                    values: currentNativeConfigSnapshot()?.rawValues ?? [:]
                )
            }
        case .tokenBudget(let used, let total):
            updateTokenBudget(TokenBudget(used: used, total: total, level: ContextBudgetLevel.level(used: used, total: total)), assistantID: assistantID, sessionID: targetSessionID)
        case .contextBudget(let used, let total, let level):
            updateTokenBudget(TokenBudget(used: used, total: total, level: level), assistantID: assistantID, sessionID: targetSessionID)
            upsertActivity(
                id: "context-\(assistantID.uuidString)",
                title: contextBudgetTitle(level),
                detail: contextBudgetDetail(used: used, total: total, level: level),
                phase: .status,
                state: level == .compacting || level == .recovering ? .running : .completed,
                anchorBlockID: assistantID.uuidString,
                sessionID: targetSessionID
            )
        case .compactStarted(let trigger, _):
            flushPendingAssistantDelta(assistantID: assistantID)
            upsertContextCompactionStatusBlock(
                title: contextCompactionStartedTitle(trigger: trigger),
                kind: contextCompactionStatusKind(trigger: trigger),
                assistantID: assistantID,
                sessionID: targetSessionID
            )
            upsertActivity(
                id: "compact-\(assistantID.uuidString)",
                title: contextCompactionStartedTitle(trigger: trigger),
                detail: "",
                phase: .status,
                state: .running,
                anchorBlockID: assistantID.uuidString,
                sessionID: targetSessionID
            )
        case .compactCompleted(let status, _, let postTokens):
            flushPendingAssistantDelta(assistantID: assistantID)
            upsertContextCompactionStatusBlock(
                title: contextCompactionCompletedTitle(status: status),
                kind: contextCompactionStatusKind(status: status),
                assistantID: assistantID,
                sessionID: targetSessionID
            )
            guard isContextCompactionFinished(postTokens: postTokens, sessionID: targetSessionID) else {
                return
            }
            if let targetSessionID {
                completeContextCompactionActivities(
                    sessionID: targetSessionID,
                    anchorBlockID: assistantID.uuidString,
                    completedTitle: contextCompactionCompletedTitle(status: status)
                )
            }
            upsertActivity(
                id: "compact-\(assistantID.uuidString)",
                title: contextCompactionCompletedTitle(status: status),
                detail: "",
                phase: .status,
                state: .completed,
                anchorBlockID: assistantID.uuidString,
                sessionID: targetSessionID
            )
        case .subagentStatus(let id, let status, let detail):
            upsertActivity(
                id: id,
                title: subagentStatusTitle(status),
                detail: detail,
                phase: .subagent,
                state: activityState(forSubagentStatus: status),
                toolName: "Task",
                detailMessages: detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [detail],
                expandedDefault: false,
                anchorBlockID: assistantID.uuidString,
                sessionID: targetSessionID
            )
        case .streamEnd:
            flushPendingAssistantDelta(assistantID: assistantID)
            if let targetSessionID {
                finishStreamingMessage(sessionID: targetSessionID)
                completeRunningActivities(sessionID: targetSessionID, anchorBlockID: assistantID.uuidString)
            }
        case .complete(let sessionId):
            flushPendingAssistantDelta(assistantID: assistantID)
            finishStreamingMessage(sessionID: sessionId)
            lastErrorBySession.removeValue(forKey: sessionId)
            if selectedSessionID == sessionId {
                errorBanner = nil
            }
            markSession(sessionId, state: .idle)
            touchSessionConversation(sessionId)
            completeRunningActivities(sessionID: sessionId, anchorBlockID: assistantID.uuidString)
            captureMemoryTurn(sessionID: sessionId, errored: false, interrupted: false)
            statusLine = t(.complete)
            finalizeAgentRun(runToken: runToken)
        case .aborted(let sessionId):
            flushPendingAssistantDelta(assistantID: assistantID)
            finishStreamingMessage(sessionID: sessionId)
            if selectedSessionID == sessionId {
                refreshVisibleErrorBanner()
            }
            markSession(sessionId, state: .idle)
            cancelRunningActivities(sessionID: sessionId, anchorBlockID: assistantID.uuidString)
            captureMemoryTurn(sessionID: sessionId, errored: false, interrupted: true)
            statusLine = t(.aborted)
            finalizeAgentRun(runToken: runToken)
        case .error(let message):
            flushPendingAssistantDelta(assistantID: assistantID)
            appendAssistantDelta("\n\(message)", assistantID: assistantID, sessionID: targetSessionID)
            if let targetSessionID {
                lastWarningBySession.removeValue(forKey: targetSessionID)
                lastErrorBySession[targetSessionID] = message
                markSession(targetSessionID, state: .failed)
                touchSessionConversation(targetSessionID)
                finishStreamingMessage(sessionID: targetSessionID)
                failRunningActivities(sessionID: targetSessionID, message: message, anchorBlockID: assistantID.uuidString)
                captureMemoryTurn(sessionID: targetSessionID, errored: true, interrupted: false)
            }
            if let targetSessionID, selectedSessionID == targetSessionID {
                warningBanner = nil
                errorBanner = message
            }
            finalizeAgentRun(runToken: runToken)
        }
    }

    private func captureMemoryTurn(sessionID: String, errored: Bool, interrupted: Bool) {
        let projectName = memoryProjectNameBySession[sessionID] ?? projectName(forSessionID: sessionID)
        let projectRoot = memoryProjectRootBySession[sessionID] ?? projectRoot(forSessionID: sessionID)
        _ = memoryService.captureTurn(
            messages: messagesBySession[sessionID] ?? [],
            sessionID: sessionID,
            projectName: projectName,
            projectRoot: projectRoot,
            errored: errored,
            interrupted: interrupted
        )
    }

    private func upsertTurn(_ turn: AgentTurn) {
        var turns = turnsBySession[turn.sessionId] ?? []
        if let index = turns.firstIndex(where: { $0.id == turn.id }) {
            turns[index] = turn
        } else {
            turns.append(turn)
        }
        turnsBySession[turn.sessionId] = turns.sorted { $0.startedAt < $1.startedAt }
        for item in turn.items {
            upsertTurnItem(item)
        }
        streamRenderRevision += 1
    }

    private func upsertTurnItem(_ item: AgentTurnItem) {
        guard item.isRenderable else { return }
        var items = turnItemsBySession[item.sessionId] ?? []
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
        turnItemsBySession[item.sessionId] = items.sorted {
            if $0.turnId == $1.turnId {
                return $0.sequence < $1.sequence
            }
            return $0.createdAt < $1.createdAt
        }
        streamRenderRevision += 1
    }

    private func finalizeAgentRun(runToken: UUID?) {
        guard runToken == nil || activeRunToken == runToken else { return }
        flushAllPendingAssistantDeltas()
        if !pendingPermissions.isEmpty || !permissionContinuations.isEmpty {
            resolveAllPendingPermissions(decision: .deny)
        }
        assistantDeltaFlushTasks.values.forEach { $0.cancel() }
        assistantDeltaFlushTasks.removeAll()
        activeRunToken = nil
        activeAgentTask = nil
    }

    private func queueAssistantDelta(_ text: String, assistantID: UUID) {
        guard !text.isEmpty else { return }
        pendingAssistantDeltas[assistantID, default: ""] += text
        guard assistantDeltaFlushTasks[assistantID] == nil else { return }
        assistantDeltaFlushTasks[assistantID] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 24_000_000)
            guard let self else { return }
            self.assistantDeltaFlushTasks[assistantID] = nil
            self.flushPendingAssistantDelta(assistantID: assistantID)
        }
    }

    private func flushPendingAssistantDelta(assistantID: UUID) {
        guard let text = pendingAssistantDeltas.removeValue(forKey: assistantID), !text.isEmpty else { return }
        assistantDeltaFlushTasks[assistantID]?.cancel()
        assistantDeltaFlushTasks[assistantID] = nil
        appendAssistantDelta(text, assistantID: assistantID)
    }

    private func flushAllPendingAssistantDeltas() {
        for assistantID in Array(pendingAssistantDeltas.keys) {
            flushPendingAssistantDelta(assistantID: assistantID)
        }
    }

    private func appendAssistantDelta(_ text: String, assistantID: UUID, sessionID explicitSessionID: String? = nil) {
        let sessionID = explicitSessionID ?? assistantSessionByID[assistantID] ?? selectedSessionID
        guard let sessionID,
              var messages = messagesBySession[sessionID],
              let index = messages.firstIndex(where: { $0.id == assistantID }) else { return }
        var message = messages[index]
        if message.blocks.isEmpty {
            message.blocks = [.text(text)]
        } else if let lastIndex = message.blocks.indices.last,
                  case .text(let existing) = message.blocks[lastIndex] {
            message.blocks[lastIndex] = .text(existing + text)
        } else {
            message.blocks.append(.text(text))
        }
        messages[index] = message
        messagesBySession[sessionID] = messages
        streamRenderRevision += 1
    }

    private func appendAssistantReasoningDelta(_ text: String, assistantID: UUID, sessionID explicitSessionID: String? = nil) {
        guard !text.isEmpty else { return }
        let sessionID = explicitSessionID ?? assistantSessionByID[assistantID] ?? selectedSessionID
        guard let sessionID,
              var messages = messagesBySession[sessionID],
              let index = messages.firstIndex(where: { $0.id == assistantID }) else { return }
        var message = messages[index]
        if let lastIndex = message.blocks.indices.last,
           case .reasoning(let existing) = message.blocks[lastIndex] {
            message.blocks[lastIndex] = .reasoning(existing + text)
        } else {
            message.blocks.append(.reasoning(text))
        }
        messages[index] = message
        messagesBySession[sessionID] = messages
        streamRenderRevision += 1
    }

    private static func skillName(from inputJSON: String) -> String {
        guard let data = inputJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let skill = object["skill"] as? String,
              !skill.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "unknown"
        }
        return skill
    }

    private func appendAssistantBlock(_ block: ChatBlock, assistantID: UUID, sessionID explicitSessionID: String? = nil) {
        let sessionID = explicitSessionID ?? assistantSessionByID[assistantID] ?? selectedSessionID
        guard let sessionID,
              var messages = messagesBySession[sessionID],
              let index = messages.firstIndex(where: { $0.id == assistantID }) else { return }
        messages[index].blocks.append(block)
        messagesBySession[sessionID] = messages
        streamRenderRevision += 1
    }

    private func upsertContextCompactionStatusBlock(
        title: String,
        kind: ProcessStatusKind,
        detail: String? = nil,
        assistantID: UUID,
        sessionID explicitSessionID: String? = nil
    ) {
        let sessionID = explicitSessionID ?? assistantSessionByID[assistantID] ?? selectedSessionID
        guard let sessionID,
              var messages = messagesBySession[sessionID],
              let index = messages.firstIndex(where: { $0.id == assistantID }) else { return }
        if let existingIndex = messages[index].blocks.lastIndex(where: { block in
            if case .processStatus(let existing) = block {
                return existing.kind == kind
            }
            return false
        }) {
            if case .processStatus(var existing) = messages[index].blocks[existingIndex] {
                guard existing.title != title || existing.detail != detail else { return }
                existing.title = title
                existing.detail = detail
                messages[index].blocks[existingIndex] = .processStatus(existing)
            }
        } else {
            messages[index].blocks.append(.processStatus(ProcessStatusBlock(
                id: "context-\(kind.rawValue)-\(UUID().uuidString)",
                title: title,
                detail: detail,
                kind: kind
            )))
        }
        messagesBySession[sessionID] = messages
        streamRenderRevision += 1
    }

    private func isContextCompactionFinished(postTokens: Int, sessionID: String?) -> Bool {
        guard let sessionID,
              let total = tokenBudgetBySession[sessionID]?.total,
              total > 0 else {
            return true
        }
        return postTokens < total
    }

    private func updateTokenBudget(_ budget: TokenBudget, assistantID: UUID, sessionID explicitSessionID: String? = nil) {
        let sessionID = explicitSessionID ?? assistantSessionByID[assistantID] ?? selectedSessionID
        guard let sessionID else { return }
        tokenBudgetBySession[sessionID] = budget
        guard var messages = messagesBySession[sessionID],
              let index = messages.firstIndex(where: { $0.id == assistantID }) else { return }
        messages[index].tokenBudget = budget
        messagesBySession[sessionID] = messages
        streamRenderRevision += 1
    }

    private func finishStreamingMessage(sessionID: String) {
        guard var messages = messagesBySession[sessionID] else { return }
        let finishedAt = Date()
        for index in messages.indices where messages[index].isStreaming {
            messages[index].isStreaming = false
            if messages[index].role == .assistant {
                if messages[index].runStartedAt == nil {
                    messages[index].runStartedAt = messages[index].createdAt
                }
                if messages[index].runEndedAt == nil {
                    messages[index].runEndedAt = finishedAt
                }
            }
        }
        messagesBySession[sessionID] = messages
        persistSessionMessages(sessionID: sessionID)
        streamRenderRevision += 1
    }

    private func markSession(_ sessionId: String, state: SessionState) {
        for projectIndex in projects.indices {
            updateSessionState(in: &projects[projectIndex].sessions, sessionId: sessionId, state: state)
            updateSessionState(in: &projects[projectIndex].codexSessions, sessionId: sessionId, state: state)
            updateSessionState(in: &projects[projectIndex].cursorSessions, sessionId: sessionId, state: state)
            updateSessionState(in: &projects[projectIndex].geminiSessions, sessionId: sessionId, state: state)
        }
        persistWorkspaceState()
    }

    private func updateSessionState(in sessions: inout [ProjectSession], sessionId: String, state: SessionState) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        sessions[index].state = state
    }

    private func touchSessionConversation(_ sessionID: String) {
        for projectIndex in projects.indices {
            touchSessionConversation(in: &projects[projectIndex].sessions, sessionID: sessionID)
            touchSessionConversation(in: &projects[projectIndex].codexSessions, sessionID: sessionID)
            touchSessionConversation(in: &projects[projectIndex].cursorSessions, sessionID: sessionID)
            touchSessionConversation(in: &projects[projectIndex].geminiSessions, sessionID: sessionID)
        }
        persistWorkspaceState()
    }

    private func touchSessionConversation(in sessions: inout [ProjectSession], sessionID: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let now = Date()
        sessions[index].lastConversationAt = now
        sessions[index].lastActivity = now
        sessions[index].updatedAt = now
    }

    private func upsertActivity(
        id: String,
        title: String,
        detail: String,
        phase: AgentActivityPhase,
        state: AgentActivityState,
        toolName: String? = nil,
        detailMessages: [String] = [],
        expandedDefault: Bool = false,
        anchorBlockID: String? = nil,
        sessionID explicitSessionID: String? = nil
    ) {
        guard let sessionID = explicitSessionID ?? selectedSessionID else { return }
        var activities = activitiesBySession[sessionID] ?? []
        if let index = activities.firstIndex(where: { $0.id == id }) {
            activities[index].title = title
            activities[index].detail = detail
            activities[index].phase = phase
            activities[index].state = state
            activities[index].toolName = toolName ?? activities[index].toolName
            if !detailMessages.isEmpty {
                activities[index].detailMessages = detailMessages
            }
            activities[index].expandedDefault = expandedDefault || activities[index].expandedDefault
            activities[index].anchorBlockID = anchorBlockID ?? activities[index].anchorBlockID
            activities[index].updatedAt = Date()
        } else {
            activities.append(
                AgentActivity(
                    id: id,
                    sessionId: sessionID,
                    title: title,
                    detail: detail,
                    phase: phase,
                    state: state,
                    createdAt: Date(),
                    updatedAt: Date(),
                    toolName: toolName,
                    detailMessages: detailMessages,
                    expandedDefault: expandedDefault,
                    anchorBlockID: anchorBlockID,
                    sequence: nextActivitySequence()
                )
            )
        }
        activitiesBySession[sessionID] = activities
        streamRenderRevision += 1
    }

    private func nextActivitySequence() -> Int {
        activitySequence += 1
        return activitySequence
    }

    private func updateActivity(id: String, state: AgentActivityState, detail: String, sessionID explicitSessionID: String? = nil) {
        guard let sessionID = explicitSessionID ?? selectedSessionID,
              var activities = activitiesBySession[sessionID],
              let index = activities.firstIndex(where: { $0.id == id }) else { return }
        activities[index].state = state
        activities[index].detail = detail
        if let title = completedInteractiveControlTitle(for: activities[index]) {
            activities[index].title = title
        }
        if state != .running {
            activities[index].endedAt = Date()
            hideCompletedInteractivePermissionActivities(
                toolName: activities[index].toolName,
                activities: &activities
            )
        }
        activities[index].updatedAt = Date()
        activitiesBySession[sessionID] = activities
        streamRenderRevision += 1
    }

    private func finishPermissionActivity(_ request: PermissionRequest, state: AgentActivityState) {
        var activities = activitiesBySession[request.sessionId] ?? []
        let now = Date()
        let permissionID = "permission-\(request.id.uuidString)"
        for index in activities.indices {
            if activities[index].id == permissionID {
                activities[index].state = state
                activities[index].endedAt = now
                activities[index].updatedAt = now
                continue
            }

            guard activities[index].state == .running,
                  activities[index].phase == .status else { continue }
            let text = "\(activities[index].title) \(activities[index].detail)"
                .lowercased()
            if text.contains("permission") || text.contains("权限") {
                activities[index].state = .completed
                activities[index].endedAt = now
                activities[index].updatedAt = now
            }
        }
        activitiesBySession[request.sessionId] = activities
        streamRenderRevision += 1
    }

    private func completeRunningActivities(sessionID: String, anchorBlockID: String? = nil) {
        guard var activities = activitiesBySession[sessionID] else { return }
        for index in activities.indices where activities[index].state == .running && activityMatchesAnchor(activities[index], anchorBlockID: anchorBlockID) {
            activities[index].state = .completed
            activities[index].endedAt = Date()
            activities[index].updatedAt = Date()
        }
        activitiesBySession[sessionID] = activities
        streamRenderRevision += 1
    }

    private func completeContextCompactionActivities(sessionID: String, anchorBlockID: String?, completedTitle: String) {
        guard var activities = activitiesBySession[sessionID] else { return }
        var didUpdate = false
        for index in activities.indices where activities[index].state == .running && activityMatchesAnchor(activities[index], anchorBlockID: anchorBlockID) {
            guard isContextCompactionStatusActivity(activities[index]) else { continue }
            activities[index].title = completedTitle
            activities[index].detail = ""
            activities[index].state = .completed
            activities[index].endedAt = Date()
            activities[index].updatedAt = Date()
            didUpdate = true
        }
        guard didUpdate else { return }
        activitiesBySession[sessionID] = activities
        streamRenderRevision += 1
    }

    private func cancelRunningActivities(sessionID: String, anchorBlockID: String? = nil) {
        guard var activities = activitiesBySession[sessionID] else { return }
        for index in activities.indices where activities[index].state == .running && activityMatchesAnchor(activities[index], anchorBlockID: anchorBlockID) {
            activities[index].state = .cancelled
            activities[index].endedAt = Date()
            activities[index].updatedAt = Date()
        }
        activitiesBySession[sessionID] = activities
        streamRenderRevision += 1
    }

    private func failRunningActivities(sessionID: String, message: String, anchorBlockID: String? = nil) {
        guard var activities = activitiesBySession[sessionID] else { return }
        if activities.isEmpty {
            activities.append(
                AgentActivity(
                    id: "error-\(UUID().uuidString)",
                    sessionId: sessionID,
                    title: t(.processFailed),
                    detail: message,
                    phase: .status,
                    state: .failed,
                    createdAt: Date(),
                    updatedAt: Date(),
                    anchorBlockID: anchorBlockID
                )
            )
        } else {
            for index in activities.indices where activities[index].state == .running && activityMatchesAnchor(activities[index], anchorBlockID: anchorBlockID) {
                activities[index].state = .failed
                activities[index].detail = message
                activities[index].endedAt = Date()
                activities[index].updatedAt = Date()
            }
        }
        activitiesBySession[sessionID] = activities
        streamRenderRevision += 1
    }

    private func activityMatchesAnchor(_ activity: AgentActivity, anchorBlockID: String?) -> Bool {
        guard let anchorBlockID else { return true }
        return activity.anchorBlockID == anchorBlockID
    }

    private func isContextCompactionStatusActivity(_ activity: AgentActivity) -> Bool {
        guard activity.phase == .status, activity.toolName == nil else { return false }
        let haystack = "\(activity.id) \(activity.title) \(activity.detail)"
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return haystack.contains("context-compacting") ||
            haystack.contains("context-recovering") ||
            haystack.contains("context compacting") ||
            haystack.contains("context recovering") ||
            haystack.contains("context compaction") ||
            haystack.contains("context recovery") ||
            haystack.contains("automatically compacting context") ||
            haystack.contains("recovering context") ||
            haystack.contains("正在自动压缩上下文") ||
            haystack.contains("正在恢复上下文") ||
            haystack.contains("上下文压缩中") ||
            haystack.contains("上下文恢复中")
    }

    private func resolveAllPendingPermissions(decision: AgentPermissionDecision) {
        let ids = Set(pendingPermissions.map(\.id)).union(permissionContinuations.keys)
        pendingPermissions.removeAll()
        for id in ids {
            permissionContinuations.removeValue(forKey: id)?.resume(returning: decision)
        }
    }

    private func persistSessionMessages(sessionID: String) {
        guard let messages = messagesBySession[sessionID],
              let paths = try? AppPaths.current() else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(messages)
            try data.write(to: paths.sessions.appendingPathComponent("\(sessionID).json"), options: .atomic)
        } catch {
            AppLog.write("session persist error for \(sessionID): \(error.localizedDescription)")
        }
    }

    private func loadPersistedMessagesIfNeeded(sessionID: String) {
        guard messagesBySession[sessionID] == nil,
              let paths = try? AppPaths.current() else { return }
        let url = paths.sessions.appendingPathComponent("\(sessionID).json")
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            if let transcriptURL = importedWebTranscriptURL(forSessionID: sessionID),
               let messages = PilotDeckWebHistoryStore.loadMessages(sessionID: sessionID, transcriptURL: transcriptURL) {
                messagesBySession[sessionID] = messages
            } else if let projectRoot = projectRoot(forSessionID: sessionID),
               let messages = PilotDeckWebHistoryStore.loadMessages(sessionID: sessionID, projectRoot: projectRoot) {
                messagesBySession[sessionID] = messages
            } else {
                messagesBySession[sessionID] = []
            }
            streamRenderRevision += 1
            return
        }
        do {
            var messages = try JSONDecoder().decode([ChatMessage].self, from: data)
            for index in messages.indices {
                messages[index].isStreaming = false
            }
            messagesBySession[sessionID] = messages
            streamRenderRevision += 1
        } catch {
            AppLog.write("session load error for \(sessionID): \(error.localizedDescription)")
            messagesBySession[sessionID] = []
        }
    }

    private func importedWebTranscriptURL(forSessionID sessionID: String) -> URL? {
        for project in projects {
            guard let session = project.allSessions.first(where: { $0.id == sessionID }),
                  session.transcriptKey == "pilotdeck-web",
                  let transcriptPath = session.relativeTranscriptPath?.nilIfBlank else {
                continue
            }
            return URL(fileURLWithPath: NSString(string: transcriptPath).expandingTildeInPath)
                .standardizedFileURL
        }
        return nil
    }

    private func loadBackgroundTaskMessagesIfNeeded(session: ProjectSession, project: WorkspaceProject) {
        guard messagesBySession[session.id] == nil else { return }
        messagesBySession[session.id] = AlwaysOnBackgroundTranscriptLoader.messages(
            for: session,
            projectName: project.name
        )
        streamRenderRevision += 1
    }

    private func upsertBackgroundSession(_ session: ProjectSession, projectIndex: Int) {
        projects[projectIndex].sessions.removeAll { $0.id == session.id }
        projects[projectIndex].codexSessions.removeAll { $0.id == session.id }
        projects[projectIndex].cursorSessions.removeAll { $0.id == session.id }
        projects[projectIndex].geminiSessions.removeAll { $0.id == session.id }
        projects[projectIndex].sessions.insert(session, at: 0)
        persistWorkspaceState()
    }

    private func sessionTitle(for sessionID: String) -> String {
        for project in projects {
            if let session = project.allSessions.first(where: { $0.id == sessionID }) {
                return session.displayTitle
            }
        }
        return t(.newSession)
    }

    private func projectName(forSessionID sessionID: String) -> String? {
        for project in projects where project.allSessions.contains(where: { $0.id == sessionID }) {
            return memoryProjectName(project)
        }
        return selectedProject.flatMap(memoryProjectName)
    }

    private func projectRoot(forSessionID sessionID: String) -> String? {
        for project in projects where project.allSessions.contains(where: { $0.id == sessionID }) {
            return effectiveWorkspacePath(for: project)
        }
        return selectedProject.map { effectiveWorkspacePath(for: $0) }
    }

    private func contextBudgetTitle(_ level: ContextBudgetLevel) -> String {
        let zh = settings.language.resolved() == .chineseSimplified
        switch level {
        case .normal:
            return zh ? "上下文正常" : "Context normal"
        case .attention:
            return zh ? "上下文关注" : "Context attention"
        case .warning:
            return zh ? "上下文警告" : "Context warning"
        case .compacting:
            return zh ? "上下文压缩中" : "Context compacting"
        case .recovering:
            return zh ? "上下文恢复中" : "Context recovering"
        }
    }

    private func contextBudgetDetail(used: Int, total: Int, level: ContextBudgetLevel) -> String {
        let percent = total > 0 ? Int((Double(used) / Double(total) * 100).rounded()) : 0
        let zh = settings.language.resolved() == .chineseSimplified
        if zh {
            return "\(contextBudgetTitle(level)): \(used.formatted()) / \(total.formatted()) tokens (\(percent)%)"
        }
        return "\(contextBudgetTitle(level)): \(used.formatted()) / \(total.formatted()) tokens (\(percent)%)"
    }

    private func contextCompactionCompletedTitle(status: String) -> String {
        let zh = settings.language.resolved() == .chineseSimplified
        if contextCompactionStatusKind(status: status) == .contextRecovery {
            return zh ? "上下文恢复已完成" : "Context recovery completed"
        }
        return zh ? "上下文压缩已完成" : "Context compaction completed"
    }

    private func contextCompactionStartedTitle(trigger: String) -> String {
        let zh = settings.language.resolved() == .chineseSimplified
        if contextCompactionStatusKind(trigger: trigger) == .contextRecovery {
            return zh ? "正在恢复上下文" : "Recovering context"
        }
        return zh ? "正在自动压缩上下文" : "Automatically compacting context"
    }

    private func contextCompactionStatusKind(status: String) -> ProcessStatusKind {
        let normalized = status.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.contains("recover") || normalized.contains("恢复") {
            return .contextRecovery
        }
        return .contextCompaction
    }

    private func contextCompactionStatusKind(trigger: String) -> ProcessStatusKind {
        let normalized = trigger.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.contains("prompt_too_long") || normalized.contains("recover") || normalized.contains("恢复") {
            return .contextRecovery
        }
        return .contextCompaction
    }

    private func subagentStatusTitle(_ status: String) -> String {
        let zh = settings.language.resolved() == .chineseSimplified
        switch status.lowercased() {
        case "started":
            return zh ? "子 Agent 已启动" : "Subagent started"
        case "running":
            return zh ? "子 Agent 运行中" : "Subagent running"
        case "completed":
            return zh ? "子 Agent 已完成" : "Subagent completed"
        case "failed":
            return zh ? "子 Agent 失败" : "Subagent failed"
        default:
            return zh ? "子 Agent 状态：\(status)" : "Subagent \(status)"
        }
    }

    private func automaticPauseNotice(for status: String) -> String? {
        let zh = settings.language.resolved() == .chineseSimplified
        switch status.lowercased() {
        case "tool error loop paused":
            return zh
                ? "自动诊断已暂停：连续几次工具检查失败。当前回复可能仍然有效，你可以继续提问，或要求换一种方式检查。"
                : "Automatic diagnostics paused after repeated tool-check failures. The current response may still be useful; continue the chat or ask PilotDeck to check another way."
        case "needs continuation":
            return zh
                ? "自动续跑已暂停。你可以输入“继续”，或补充更具体的要求。"
                : "Automatic continuation paused. Type “continue” or add more specific instructions to resume."
        default:
            return nil
        }
    }

    private func activityState(forSubagentStatus status: String) -> AgentActivityState {
        switch status.lowercased() {
        case "completed":
            return .completed
        case "failed":
            return .failed
        default:
            return .running
        }
    }

    private func statusTitle(_ status: String) -> String {
        switch status.lowercased() {
        case "connecting": return t(.connecting)
        case "streaming": return t(.receivingResponse)
        case "thinking": return t(.working)
        case "processing": return settings.language.resolved() == .chineseSimplified ? "等待模型继续" : "Waiting for model"
        case "continuing": return settings.language.resolved() == .chineseSimplified ? "正在继续" : "Continuing"
        case "needs continuation": return settings.language.resolved() == .chineseSimplified ? "需要继续" : "Needs continuation"
        case "tool error loop paused": return settings.language.resolved() == .chineseSimplified ? "自动诊断已暂停" : "Automatic diagnostics paused"
        case "executing plan": return settings.language.resolved() == .chineseSimplified ? "正在执行计划" : "Executing plan"
        case "context compacting": return settings.language.resolved() == .chineseSimplified ? "正在自动压缩上下文" : "Automatically compacting context"
        case "context recovering": return settings.language.resolved() == .chineseSimplified ? "正在恢复上下文" : "Recovering context"
        case PlanWorkflowPresentation.generatingQuestionStatus:
            return settings.language.resolved() == .chineseSimplified ? "正在生成问题" : "Generating questions"
        case PlanWorkflowPresentation.collectingContextStatus:
            return settings.language.resolved() == .chineseSimplified ? "正在收集上下文" : "Collecting context"
        case PlanWorkflowPresentation.generatingPlanStatus:
            return settings.language.resolved() == .chineseSimplified ? "正在生成计划" : "Generating plan"
        case PlanWorkflowPresentation.waitingForAnswerStatus:
            return settings.language.resolved() == .chineseSimplified ? "等待你的回答" : "Waiting for your answer"
        case PlanWorkflowPresentation.waitingForConfirmationStatus:
            return settings.language.resolved() == .chineseSimplified ? "等待计划确认" : "Waiting for plan confirmation"
        case PlanWorkflowPresentation.recoveringStatus:
            return settings.language.resolved() == .chineseSimplified ? "正在恢复计划流程" : "Recovering planning flow"
        case PlanWorkflowPresentation.recoveryNeededStatus:
            return settings.language.resolved() == .chineseSimplified ? "计划需要继续完善" : "Planning needs more input"
        case "waiting for permission": return "Permission required"
        case let value where value.hasPrefix("running "):
            let tool = String(value.dropFirst("running ".count))
            return settings.language.resolved() == .chineseSimplified ? "正在执行 \(tool)" : "Running \(tool)"
        case let value where value.hasPrefix("recovering "):
            let tool = String(value.dropFirst("recovering ".count))
            return settings.language.resolved() == .chineseSimplified ? "正在恢复 \(tool)" : "Recovering \(tool)"
        default: return status.isEmpty ? t(.working) : status.capitalized
        }
    }

    private func statusDetail(_ status: String) -> String {
        switch status.lowercased() {
        case "connecting": return t(.openingRemoteModelStream)
        case "streaming": return t(.streamingAssistantOutput)
        case "thinking": return t(.agentStatusUpdate)
        case "processing": return settings.language.resolved() == .chineseSimplified ? "工具结果已返回，正在生成下一步。" : "Tool results returned; generating the next step."
        case "continuing": return settings.language.resolved() == .chineseSimplified ? "模型还没有完成任务，正在推进下一步。" : "The model has not completed the task yet, continuing the next step."
        case "needs continuation": return settings.language.resolved() == .chineseSimplified ? "自动续跑已暂停。你可以输入“继续”或补充更具体的要求。" : "Automatic continuation paused. Type continue or add more specific instructions to resume."
        case "tool error loop paused": return settings.language.resolved() == .chineseSimplified ? "连续几次工具检查失败，已停止自动重试，避免无意义循环。" : "Repeated tool checks failed, so automatic retries stopped to avoid an unproductive loop."
        case "executing plan": return settings.language.resolved() == .chineseSimplified ? "计划已确认，正在切换到执行。" : "The plan was approved; switching to implementation."
        case "context compacting": return settings.language.resolved() == .chineseSimplified ? "接近配置上限，正在生成上下文摘要。" : "Near the configured limit; generating a context summary."
        case "context recovering": return settings.language.resolved() == .chineseSimplified ? "请求过长，正在压缩上下文后重试。" : "The request was too long; compacting context before retrying."
        case PlanWorkflowPresentation.generatingQuestionStatus:
            return settings.language.resolved() == .chineseSimplified ? "正在准备需要你选择的问题。" : "Preparing the questions for your input."
        case PlanWorkflowPresentation.collectingContextStatus:
            return settings.language.resolved() == .chineseSimplified ? "正在只读查看项目上下文。" : "Reading project context without making changes."
        case PlanWorkflowPresentation.generatingPlanStatus:
            return settings.language.resolved() == .chineseSimplified ? "正在整理可确认的执行计划。" : "Preparing the plan for confirmation."
        case PlanWorkflowPresentation.waitingForAnswerStatus:
            return settings.language.resolved() == .chineseSimplified ? "请在问题卡片中选择或填写答案。" : "Answer the question card to continue planning."
        case PlanWorkflowPresentation.waitingForConfirmationStatus:
            return settings.language.resolved() == .chineseSimplified ? "请确认执行计划，或补充要求继续完善。" : "Confirm the plan or add feedback to keep planning."
        case PlanWorkflowPresentation.recoveringStatus:
            return settings.language.resolved() == .chineseSimplified ? "模型返回了普通文本，正在转成可交互的计划步骤。" : "The model returned prose; converting it into an interactive planning step."
        case PlanWorkflowPresentation.recoveryNeededStatus:
            return settings.language.resolved() == .chineseSimplified ? "请补充要求，或重新发送后继续生成计划。" : "Add feedback or send again to continue planning."
        case "waiting for permission": return "Approve or deny the requested tool action."
        default: return t(.agentStatusUpdate)
        }
    }

    private func interactiveControlTitle(for toolName: String) -> String? {
        switch AgentToolNameCanonicalizer.canonical(toolName) {
        case "AskQuestion":
            return settings.language.resolved() == .chineseSimplified ? "等待你的回答" : "Waiting for your answer"
        case "SwitchMode":
            return settings.language.resolved() == .chineseSimplified ? "等待计划确认" : "Waiting for plan confirmation"
        default:
            return nil
        }
    }

    private func interactiveControlDetailMessages(for toolName: String, inputJSON: String) -> [String] {
        guard AgentToolNameCanonicalizer.canonical(toolName) == "AskQuestion",
              let payload = AgentInteractivePayload.askUserQuestion(from: inputJSON) else {
            return []
        }
        return ["questions_count=\(payload.questions.count)"]
    }

    private func completedInteractiveControlTitle(for activity: AgentActivity) -> String? {
        guard activity.state == .completed,
              AgentToolNameCanonicalizer.canonical(activity.toolName ?? "") == "AskQuestion" else {
            return nil
        }
        let count = questionCount(from: activity.detailMessages) ?? 1
        if settings.language.resolved() == .chineseSimplified {
            return "已询问 \(count) 个问题"
        }
        return "Asked \(count) \(count == 1 ? "question" : "questions")"
    }

    private func hideCompletedInteractivePermissionActivities(toolName: String?, activities: inout [AgentActivity]) {
        guard PlanWorkflowPresentation.isInteractiveControl(toolName) else { return }
        let canonical = AgentToolNameCanonicalizer.canonical(toolName ?? "")
        for index in activities.indices {
            guard activities[index].id.hasPrefix("permission-"),
                  AgentToolNameCanonicalizer.canonical(activities[index].toolName ?? "") == canonical else { continue }
            activities[index].state = .completed
            activities[index].title = ""
            activities[index].detail = ""
            activities[index].toolName = nil
            activities[index].detailMessages = []
            activities[index].endedAt = Date()
            activities[index].updatedAt = Date()
        }
    }

    private func questionCount(from values: [String]) -> Int? {
        for value in values {
            if value.hasPrefix("questions_count="),
               let count = Int(value.dropFirst("questions_count=".count)) {
                return count
            }
        }
        return nil
    }

    private func activityPhase(for toolName: String) -> AgentActivityPhase {
        AgentToolPresentationClassifier.phase(forToolName: toolName)
    }

    private func isInlineToolProgressStatus(_ status: String) -> Bool {
        let normalized = status
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.hasPrefix("running ") || normalized.hasPrefix("recovering ")
    }

    private func statusActivityID(_ status: String, assistantID: UUID) -> String {
        let normalized = status
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            return "status-\(assistantID.uuidString)-working"
        }
        if normalized == "connecting" ||
            normalized == "streaming" ||
            normalized == "thinking" ||
            normalized == "processing" ||
            normalized == "context compacting" ||
            normalized == "context recovering" ||
            normalized == "waiting for permission" ||
            normalized.hasPrefix("plan ") {
            return "status-\(assistantID.uuidString)-\(normalized.replacingOccurrences(of: " ", with: "-"))"
        }
        if normalized.hasPrefix("reconnecting") || normalized.contains("重试") || normalized.contains("retry") {
            return "status-\(assistantID.uuidString)-reconnecting"
        }
        return "status-\(assistantID.uuidString)-\(UUID().uuidString)"
    }
}

enum WorkspaceStatePersistence {
    struct Selection: Codable, Hashable {
        var projectRoot: String?
        var sessionID: String?
    }

    struct Snapshot: Codable, Hashable {
        var version: Int
        var projects: [WorkspaceProject]
        var selection: Selection?
    }

    private static let version = 1
    private static let fileName = "workspace-state.json"

    static func load() -> Snapshot? {
        guard let url = stateURL(),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        do {
            return try JSONDecoder().decode(Snapshot.self, from: data)
        } catch {
            AppLog.write("workspace state load error: \(error.localizedDescription)")
            return nil
        }
    }

    static func save(projects: [WorkspaceProject], selection: Selection) {
        guard let url = stateURL() else { return }
        do {
            let snapshot = Snapshot(version: version, projects: projects, selection: selection)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            AppLog.write("workspace state save error: \(error.localizedDescription)")
        }
    }

    private static func stateURL() -> URL? {
        guard let paths = try? AppPaths.current() else { return nil }
        return paths.applicationSupport.appendingPathComponent(fileName)
    }
}

enum SharedProjectPathIndexStore {
    struct Entry: Codable, Hashable {
        var rootPath: String
        var projectName: String
        var displayName: String
        var isGeneral: Bool
        var sources: [String]
        var createdAt: Date
        var updatedAt: Date
        var deletedAt: Date?

        var normalized: Entry {
            var entry = self
            entry.rootPath = SharedProjectPathIndexStore.normalizedPath(rootPath)
            entry.sources = SharedProjectPathIndexStore.uniqued(sources.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty })
            return entry
        }
    }

    struct Snapshot: Codable, Hashable {
        var version: Int
        var projects: [Entry]
    }

    private static let version = 1
    private static let fileName = "project-index.json"

    static func loadActiveEntries(url: URL = defaultURL()) -> [Entry] {
        load(url: url).projects.filter { $0.deletedAt == nil }
    }

    static func upsert(_ incoming: [Entry], url: URL = defaultURL()) {
        guard !incoming.isEmpty else { return }
        var existing = load(url: url).projects.reduce(into: [String: Entry]()) { result, entry in
            result[normalizedPath(entry.rootPath)] = entry.normalized
        }

        for rawEntry in incoming {
            let entry = rawEntry.normalized
            let key = normalizedPath(entry.rootPath)
            if var current = existing[key] {
                current.projectName = entry.projectName.nilIfBlank ?? current.projectName
                current.displayName = entry.displayName.nilIfBlank ?? current.displayName
                current.isGeneral = current.isGeneral || entry.isGeneral
                current.sources = uniqued(current.sources + entry.sources)
                current.createdAt = min(current.createdAt, entry.createdAt)
                current.updatedAt = max(current.updatedAt, entry.updatedAt)
                current.deletedAt = nil
                existing[key] = current
            } else {
                existing[key] = entry
            }
        }

        save(Array(existing.values), url: url)
    }

    static func markDeleted(rootPath: String, url: URL = defaultURL(), now: Date = Date()) {
        let key = normalizedPath(rootPath)
        var entries = load(url: url).projects.reduce(into: [String: Entry]()) { result, entry in
            result[normalizedPath(entry.rootPath)] = entry.normalized
        }
        if var entry = entries[key] {
            entry.deletedAt = now
            entry.updatedAt = now
            entries[key] = entry
        } else {
            entries[key] = Entry(
                rootPath: key,
                projectName: WorkspaceService.projectName(for: key),
                displayName: URL(fileURLWithPath: key).lastPathComponent,
                isGeneral: false,
                sources: ["mac-native"],
                createdAt: now,
                updatedAt: now,
                deletedAt: now
            )
        }
        save(Array(entries.values), url: url)
    }

    static func load(url: URL = defaultURL()) -> Snapshot {
        guard let data = try? Data(contentsOf: url) else {
            return Snapshot(version: version, projects: [])
        }
        do {
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            return Snapshot(version: snapshot.version, projects: snapshot.projects.map(\.normalized))
        } catch {
            AppLog.write("shared project index load error: \(error.localizedDescription)")
            return Snapshot(version: version, projects: [])
        }
    }

    private static func save(_ entries: [Entry], url: URL) {
        let snapshot = Snapshot(
            version: version,
            projects: entries
                .map(\.normalized)
                .sorted { left, right in
                    if left.isGeneral != right.isGeneral { return left.isGeneral && !right.isGeneral }
                    return left.updatedAt > right.updatedAt
                }
        )
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            AppLog.write("shared project index save error: \(error.localizedDescription)")
        }
    }

    static func defaultURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home
            .appendingPathComponent(".pilotdeck", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            .standardizedFileURL
            .path
    }

    private static func uniqued(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }
}

enum SharedSessionIndexStore {
    struct Entry: Codable, Hashable {
        var projectRoot: String
        var session: ProjectSession
        var source: String
        var updatedAt: Date

        var normalized: Entry {
            var entry = self
            entry.projectRoot = SharedSessionIndexStore.normalizedPath(projectRoot)
            entry.source = source.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? "mac-native"
            entry.session = SharedSessionIndexStore.sessionForIndex(session)
            entry.updatedAt = session.activityDate
            return entry
        }

        func hasReadableTranscript(nativeSessionsDirectory: URL, fileManager: FileManager = .default) -> Bool {
            if session.isBackgroundTaskSession {
                return true
            }
            if session.transcriptKey == "pilotdeck-web" || source == "web" {
                guard let transcriptPath = session.relativeTranscriptPath?.nilIfBlank else { return false }
                return fileManager.fileExists(atPath: URL(fileURLWithPath: transcriptPath).standardizedFileURL.path)
            }
            return fileManager.fileExists(
                atPath: nativeSessionsDirectory
                    .appendingPathComponent("\(session.id).json")
                    .standardizedFileURL
                    .path
            )
        }
    }

    struct Snapshot: Codable, Hashable {
        var version: Int
        var sessions: [Entry]
    }

    private static let version = 1
    private static let fileName = "session-index.json"

    static func loadEntries(url: URL = defaultURL()) -> [Entry] {
        load(url: url).sessions.map(\.normalized)
    }

    static func save(entries: [Entry], url: URL = defaultURL()) {
        var unique: [String: Entry] = [:]
        for rawEntry in entries {
            let entry = rawEntry.normalized
            unique[entry.session.id] = entry
        }
        let snapshot = Snapshot(
            version: version,
            sessions: Array(unique.values).sorted { $0.updatedAt > $1.updatedAt }
        )
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            AppLog.write("shared session index save error: \(error.localizedDescription)")
        }
    }

    static func removeProject(rootPath: String, url: URL = defaultURL()) {
        let normalizedRoot = normalizedPath(rootPath)
        let entries = loadEntries(url: url).filter { normalizedPath($0.projectRoot) != normalizedRoot }
        save(entries: entries, url: url)
    }

    static func removeSession(sessionID: String, url: URL = defaultURL()) {
        let entries = loadEntries(url: url).filter { $0.session.id != sessionID }
        save(entries: entries, url: url)
    }

    static func load(url: URL = defaultURL()) -> Snapshot {
        guard let data = try? Data(contentsOf: url) else {
            return Snapshot(version: version, sessions: [])
        }
        do {
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            return Snapshot(version: snapshot.version, sessions: snapshot.sessions.map(\.normalized))
        } catch {
            AppLog.write("shared session index load error: \(error.localizedDescription)")
            return Snapshot(version: version, sessions: [])
        }
    }

    static func defaultURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home
            .appendingPathComponent(".pilotdeck", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            .standardizedFileURL
            .path
    }

    private static func sessionForIndex(_ session: ProjectSession) -> ProjectSession {
        var persisted = session
        if persisted.state == .processing {
            persisted.state = .idle
        }
        return persisted
    }
}

enum LocalSessionIndexRecovery {
    struct RecoveredSession: Hashable {
        var projectRoot: String
        var session: ProjectSession
    }

    private struct ProjectRootCandidate: Hashable {
        var root: String
        var aliases: [String]
    }

    static func recover(
        sessionsDirectory: URL,
        knownProjectRoots: [String],
        generalProjectRoot: String?
    ) -> [RecoveredSession] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let roots = uniqued(knownProjectRoots.map(normalizedPath))
        let generalRoot = generalProjectRoot.map(normalizedPath)
        let projectRoots = roots
            .filter { $0 != generalRoot }
            .sorted { $0.count > $1.count }
        let projectCandidates = projectRoots.map {
            ProjectRootCandidate(root: $0, aliases: aliases(forProjectRoot: $0))
        }
        let decoder = JSONDecoder()

        return files
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { url in
                let sessionID = url.deletingPathExtension().lastPathComponent
                guard !sessionID.hasPrefix("always-on-") else { return nil }
                guard let data = try? Data(contentsOf: url),
                      let messages = try? decoder.decode([ChatMessage].self, from: data),
                      !messages.isEmpty else { return nil }

                let searchText = searchableTranscriptText(messages)
                let normalizedSearchText = searchText.lowercased()
                let matchedRoot = projectCandidates.first { searchText.contains($0.root) }?.root
                    ?? projectCandidates.first { candidate in
                        candidate.aliases.contains { containsStandalone($0, in: normalizedSearchText) }
                    }?.root
                let targetRoot = matchedRoot ?? generalRoot
                guard let targetRoot else { return nil }

                let metadata = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                return RecoveredSession(
                    projectRoot: targetRoot,
                    session: makeSession(id: sessionID, messages: messages, fileModifiedAt: metadata)
                )
            }
    }

    private static func makeSession(id: String, messages: [ChatMessage], fileModifiedAt: Date?) -> ProjectSession {
        let createdAt = messages.map(\.createdAt).min() ?? fileModifiedAt ?? Date()
        let lastActivity = messages.map(\.createdAt).max() ?? fileModifiedAt ?? createdAt
        let title = sessionTitle(from: messages, fallback: id)
        return ProjectSession(
            id: id,
            provider: messages.last?.provider ?? messages.first?.provider ?? .pilotDeck,
            title: title,
            summary: title,
            createdAt: createdAt,
            updatedAt: fileModifiedAt,
            lastActivity: lastActivity,
            lastConversationAt: lastActivity,
            state: .idle,
            messageCount: messages.count
        )
    }

    private static func sessionTitle(from messages: [ChatMessage], fallback: String) -> String {
        let userText = messages.first(where: { $0.role == .user })?.plainText
        let anyText = messages.first(where: { !$0.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.plainText
        let title = (userText ?? anyText ?? fallback)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return truncated(title.isEmpty ? fallback : title, limit: 80)
    }

    private static func searchableTranscriptText(_ messages: [ChatMessage]) -> String {
        let text = messages
            .flatMap { message in
                message.blocks.flatMap(searchableText)
            }
            .joined(separator: "\n")
        return text.replacingOccurrences(of: "\\/", with: "/")
    }

    private static func searchableText(_ block: ChatBlock) -> [String] {
        switch block {
        case .text(let text), .reasoning(let text):
            return [text]
        case .toolCall(let call):
            return [call.name, call.inputJSON]
        case .toolResult(let result):
            return [result.output]
        case .attachment(let attachment):
            return [attachment.fileName, attachment.path]
        case .processStatus(let status):
            return [status.title, status.detail ?? ""]
        }
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            .standardizedFileURL
            .path
    }

    private static func uniqued(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }

    private static func aliases(forProjectRoot root: String) -> [String] {
        let leaf = URL(fileURLWithPath: root).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard leaf.count >= 3,
              !genericProjectAliases.contains(leaf) else { return [] }
        let spaced = leaf
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        return uniqued([leaf, spaced].filter { !$0.isEmpty && $0.count >= 3 })
    }

    private static let genericProjectAliases: Set<String> = [
        "default",
        "demo",
        "general",
        "new",
        "project",
        "sample",
        "temp",
        "test",
        "tmp",
        "untitled",
        "workspace",
    ]

    private static func containsStandalone(_ alias: String, in text: String) -> Bool {
        var searchStart = text.startIndex
        while let range = text.range(of: alias, range: searchStart..<text.endIndex) {
            let hasLeadingBoundary = range.lowerBound == text.startIndex
                || isAliasBoundary(text[text.index(before: range.lowerBound)])
            let hasTrailingBoundary = range.upperBound == text.endIndex
                || isAliasBoundary(text[range.upperBound])
            if hasLeadingBoundary && hasTrailingBoundary {
                return true
            }
            searchStart = range.upperBound
        }
        return false
    }

    private static func isAliasBoundary(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            !(scalar.properties.isAlphabetic
                || scalar.properties.numericType != nil
                || scalar == UnicodeScalar("_")
                || scalar == UnicodeScalar("-"))
        }
    }

    private static func truncated(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        let index = value.index(value.startIndex, offsetBy: max(0, limit - 1))
        return String(value[..<index]) + "…"
    }
}

enum PilotDeckWebHistoryStore {
    struct ProjectHistory: Hashable {
        var rootPath: String
        var sessions: [ProjectSession]
    }

    struct KnownProject: Hashable {
        var rootPath: String
        var projectName: String
        var displayName: String
    }

    private static let readBytes = 65_536
    private static let internalSessionPrefixes = [
        "always-on-discovery:",
        "always-on-workspace:",
        "always-on-report:",
    ]

    static func loadProjects(pilotHome: URL = defaultPilotHome()) -> [ProjectHistory] {
        let projectsDir = pilotHome.appendingPathComponent("projects", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: projectsDir.path) else {
            return []
        }
        return names.compactMap { name -> ProjectHistory? in
            let projectDir = projectsDir.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: projectDir.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return nil
            }
            guard let rootPath = markerProjectRoot(from: projectDir),
                  FileManager.default.fileExists(atPath: rootPath) else {
                return nil
            }
            guard URL(fileURLWithPath: rootPath).standardizedFileURL.path != pilotHome.standardizedFileURL.path else {
                return nil
            }
            let sessions = loadSessions(projectRoot: rootPath, pilotHome: pilotHome)
            guard !sessions.isEmpty else { return nil }
            return ProjectHistory(rootPath: rootPath, sessions: sessions)
        }
        .sorted { left, right in
            (left.sessions.map(\.activityDate).max() ?? .distantPast) >
                (right.sessions.map(\.activityDate).max() ?? .distantPast)
        }
    }

    static func loadKnownProjects(pilotHome: URL = defaultPilotHome()) -> [KnownProject] {
        var projects: [String: KnownProject] = [:]

        for project in loadConfiguredProjects(pilotHome: pilotHome) {
            projects[normalizedPath(project.rootPath)] = project
        }

        let projectsDir = pilotHome.appendingPathComponent("projects", isDirectory: true)
        if let names = try? FileManager.default.contentsOfDirectory(atPath: projectsDir.path) {
            for name in names {
                let projectDir = projectsDir.appendingPathComponent(name, isDirectory: true)
                guard let rootPath = markerProjectRoot(from: projectDir),
                      FileManager.default.fileExists(atPath: rootPath),
                      normalizedPath(rootPath) != normalizedPath(pilotHome.path) else {
                    continue
                }
                let root = normalizedPath(rootPath)
                projects[root] = projects[root] ?? KnownProject(
                    rootPath: root,
                    projectName: WorkspaceService.projectName(for: root),
                    displayName: URL(fileURLWithPath: root).lastPathComponent
                )
            }
        }

        return projects.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    static func loadGeneralHistory(pilotHome: URL = defaultPilotHome()) -> ProjectHistory? {
        let rootPath = pilotHome.standardizedFileURL.path
        let sessions = loadSessions(projectRoot: rootPath, pilotHome: pilotHome)
        guard !sessions.isEmpty else { return nil }
        return ProjectHistory(rootPath: rootPath, sessions: sessions)
    }

    static func loadSessions(projectRoot: String, pilotHome: URL = defaultPilotHome()) -> [ProjectSession] {
        let chatDir = projectChatDir(projectRoot: projectRoot, pilotHome: pilotHome)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: chatDir.path) else {
            return []
        }
        return names
            .filter { $0.hasSuffix(".jsonl") }
            .compactMap { name -> ProjectSession? in
                let sessionID = String(name.dropLast(".jsonl".count))
                guard !isInternalSession(sessionID) else { return nil }
                let url = chatDir.appendingPathComponent(name)
                return sessionInfo(sessionID: sessionID, transcriptURL: url)
            }
            .sorted { $0.activityDate > $1.activityDate }
    }

    static func loadMessages(sessionID: String, projectRoot: String, pilotHome: URL = defaultPilotHome()) -> [ChatMessage]? {
        let transcriptURL = projectChatDir(projectRoot: projectRoot, pilotHome: pilotHome)
            .appendingPathComponent("\(sanitizeSessionID(sessionID)).jsonl")
        return loadMessages(sessionID: sessionID, transcriptURL: transcriptURL)
    }

    static func loadMessages(sessionID: String, transcriptURL: URL) -> [ChatMessage]? {
        guard let text = try? String(contentsOf: transcriptURL, encoding: .utf8) else {
            return nil
        }
        let entries = transcriptEntries(from: text)
        guard !entries.isEmpty else { return [] }
        let startIndex = lastCompactBoundaryIndex(in: entries).map { $0 + 1 } ?? 0
        var messages: [ChatMessage] = []
        for entry in entries.dropFirst(startIndex) {
            let createdAt = date(from: entry["createdAt"] as? String) ?? Date()
            switch entry["type"] as? String {
            case "accepted_input":
                let canonicalMessages = entry["messages"] as? [[String: Any]] ?? []
                messages.append(contentsOf: canonicalMessages.compactMap {
                    chatMessage(from: $0, sessionID: sessionID, createdAt: createdAt)
                })
            case "assistant_message", "tool_result_message", "durable_message":
                if let message = entry["message"] as? [String: Any],
                   let chat = chatMessage(from: message, sessionID: sessionID, createdAt: createdAt) {
                    messages.append(chat)
                }
            case "control_boundary":
                if isCompactBoundary(entry) {
                    messages.append(
                        ChatMessage(
                            id: UUID(),
                            sessionId: sessionID,
                            provider: .pilotDeck,
                            role: .system,
                            blocks: [.text("Context compacted")],
                            createdAt: createdAt,
                            isStreaming: false,
                            tokenBudget: nil
                        )
                    )
                }
            default:
                continue
            }
        }
        return messages
    }

    static func projectID(for projectRoot: String) -> String {
        let normalizedRoot = URL(fileURLWithPath: NSString(string: projectRoot).expandingTildeInPath)
            .standardizedFileURL
            .path
            .replacingOccurrences(of: "\\", with: "/")
            .replacingOccurrences(of: #"^[A-Za-z]:"#, with: "", options: .regularExpression)
        let slug = normalizedRoot
            .replacingOccurrences(of: #"[^A-Za-z0-9._-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "project" : slug
    }

    static func projectChatDir(projectRoot: String, pilotHome: URL = defaultPilotHome()) -> URL {
        let projectsDir = pilotHome.appendingPathComponent("projects", isDirectory: true)
        let storedID = storedProjectID(projectRoot: projectRoot, projectsDir: projectsDir)
        return projectsDir
            .appendingPathComponent(storedID ?? projectID(for: projectRoot), isDirectory: true)
            .appendingPathComponent("chats", isDirectory: true)
    }

    static func sanitizeSessionID(_ sessionID: String) -> String {
        sessionID
            .replacingOccurrences(of: #"[\\/]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .nilIfBlank ?? "session"
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            .standardizedFileURL
            .path
    }

    private static func defaultPilotHome() -> URL {
        let raw = ProcessInfo.processInfo.environment["PILOT_HOME"] ?? "~/.pilotdeck"
        let expanded = NSString(string: raw).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    private static func markerProjectRoot(from projectDir: URL) -> String? {
        let marker = projectDir.appendingPathComponent(".cwd")
        guard let raw = try? String(contentsOf: marker, encoding: .utf8) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath)
            .standardizedFileURL
            .path
    }

    private static func storedProjectID(projectRoot: String, projectsDir: URL) -> String? {
        let target = URL(fileURLWithPath: NSString(string: projectRoot).expandingTildeInPath)
            .standardizedFileURL
            .path
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: projectsDir.path) else {
            return nil
        }
        for entry in entries {
            let dir = projectsDir.appendingPathComponent(entry, isDirectory: true)
            guard let markerRoot = markerProjectRoot(from: dir),
                  markerRoot == target else {
                continue
            }
            return entry
        }
        return nil
    }

    private static func sessionInfo(sessionID: String, transcriptURL: URL) -> ProjectSession? {
        guard let lite = readLite(transcriptURL) else { return nil }
        let source = "\(lite.head)\n\(lite.tail)"
        let title = lastMetadataStringField(source, "title")
            ?? lastMetadataStringField(source, "aiTitle")
        let firstPrompt = firstAcceptedInputText(lite.head)
        let lastPrompt = lastAcceptedInputText(lite.tail) ?? firstPrompt
        let summary = title ?? lastPrompt
        guard let summary, !summary.isEmpty else { return nil }

        let createdAt = firstEntryDate(lite.head) ?? lite.modifiedAt
        return ProjectSession(
            id: sessionID,
            provider: .pilotDeck,
            title: title ?? summary,
            summary: summary,
            createdAt: createdAt,
            updatedAt: lite.modifiedAt,
            lastActivity: lite.modifiedAt,
            lastConversationAt: lite.modifiedAt,
            state: .idle,
            messageCount: nil,
            relativeTranscriptPath: transcriptURL.path,
            transcriptKey: "pilotdeck-web"
        )
    }

    private struct LiteTranscript {
        var modifiedAt: Date
        var head: String
        var tail: String
    }

    private static func readLite(_ url: URL) -> LiteTranscript? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let sizeNumber = attributes[.size] as? NSNumber,
              sizeNumber.intValue > 0 else {
            return nil
        }
        let modifiedAt = (attributes[.modificationDate] as? Date) ?? Date()
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let size = sizeNumber.intValue
        let headData = handle.readData(ofLength: min(readBytes, size))
        let head = String(data: headData, encoding: .utf8) ?? ""
        var tail = head
        if size > readBytes {
            try? handle.seek(toOffset: UInt64(max(0, size - readBytes)))
            let tailData = handle.readData(ofLength: readBytes)
            tail = String(data: tailData, encoding: .utf8) ?? ""
        }
        return LiteTranscript(modifiedAt: modifiedAt, head: head, tail: tail)
    }

    private static func firstEntryDate(_ text: String) -> Date? {
        for object in transcriptEntries(from: text) {
            if let raw = object["createdAt"] as? String,
               let parsed = date(from: raw) {
                return parsed
            }
        }
        return nil
    }

    private static func loadConfiguredProjects(pilotHome: URL) -> [KnownProject] {
        let url = pilotHome.appendingPathComponent("project-config.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawProjects = json["projects"] as? [String: Any] else {
            return []
        }

        return rawProjects.compactMap { projectName, value -> KnownProject? in
            guard let object = value as? [String: Any],
                  let originalPath = object["originalPath"] as? String else {
                return nil
            }
            let rootPath = normalizedPath(NSString(string: originalPath).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: rootPath),
                  rootPath != normalizedPath(pilotHome.path) else {
                return nil
            }
            let displayName = (object["displayName"] as? String)?.nilIfBlank
                ?? URL(fileURLWithPath: rootPath).lastPathComponent
            return KnownProject(
                rootPath: rootPath,
                projectName: projectName,
                displayName: displayName
            )
        }
    }

    private static func firstAcceptedInputText(_ text: String) -> String? {
        for object in transcriptEntries(from: text) where object["type"] as? String == "accepted_input" {
            if let messages = object["messages"] as? [[String: Any]],
               let found = messages.compactMap(canonicalTextMessage).first(where: { !$0.isEmpty }) {
                return found
            }
        }
        return nil
    }

    private static func lastAcceptedInputText(_ text: String) -> String? {
        for object in transcriptEntries(from: text).reversed() where object["type"] as? String == "accepted_input" {
            if let messages = object["messages"] as? [[String: Any]],
               let found = messages.compactMap(canonicalTextMessage).last(where: { !$0.isEmpty }) {
                return found
            }
        }
        return nil
    }

    private static func canonicalTextMessage(_ object: [String: Any]) -> String? {
        guard (object["role"] as? String) == "user",
              let content = object["content"] as? [[String: Any]] else {
            return nil
        }
        let text = content.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func lastMetadataStringField(_ text: String, _ key: String) -> String? {
        for object in transcriptEntries(from: text).reversed() where object["type"] as? String == "session_metadata" {
            guard let metadata = object["metadata"] as? [String: Any],
                  let value = metadata[key] as? String else {
                continue
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private static func transcriptEntries(from text: String) -> [[String: Any]] {
        text.split(whereSeparator: \.isNewline).compactMap { line -> [String: Any]? in
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return object
        }
    }

    private static func lastCompactBoundaryIndex(in entries: [[String: Any]]) -> Int? {
        for index in entries.indices.reversed() where isCompactBoundary(entries[index]) {
            return index
        }
        return nil
    }

    private static func isCompactBoundary(_ entry: [String: Any]) -> Bool {
        guard entry["type"] as? String == "control_boundary",
              let boundary = entry["boundary"] as? [String: Any],
              boundary["kind"] as? String == "compact" else {
            return false
        }
        return boundary["subtype"] as? String == "compact_boundary"
    }

    private static func chatMessage(from object: [String: Any], sessionID: String, createdAt: Date) -> ChatMessage? {
        guard let content = object["content"] as? [[String: Any]] else { return nil }
        let containsToolResult = content.contains { $0["type"] as? String == "tool_result" }
        let rawRole = object["role"] as? String
        let role: ChatRole
        if containsToolResult {
            role = .assistant
        } else {
            role = ChatRole(rawValue: rawRole ?? "") ?? .assistant
        }
        let blocks = content.compactMap(chatBlock)
        guard !blocks.isEmpty else { return nil }
        return ChatMessage(
            id: UUID(),
            sessionId: sessionID,
            provider: .pilotDeck,
            role: role,
            blocks: blocks,
            createdAt: createdAt,
            isStreaming: false,
            tokenBudget: nil
        )
    }

    private static func chatBlock(from object: [String: Any]) -> ChatBlock? {
        switch object["type"] as? String {
        case "text":
            return (object["text"] as? String).map(ChatBlock.text)
        case "reasoning":
            return (object["text"] as? String).map(ChatBlock.reasoning)
        case "tool_call":
            let id = object["id"] as? String ?? UUID().uuidString
            let name = object["name"] as? String ?? "Tool"
            let input = object["input"].map(jsonString) ?? "{}"
            return .toolCall(ToolCall(id: id, name: name, inputJSON: input, status: .completed))
        case "tool_result":
            let id = object["toolCallId"] as? String ?? object["tool_call_id"] as? String ?? UUID().uuidString
            let output = toolResultText(object)
            let raw = object["raw"] as? [String: Any]
            let isError = (raw?["type"] as? String) == "error" || raw?["error"] != nil
            return .toolResult(ToolResult(toolCallId: id, output: output, isError: isError))
        case "image":
            return .text("[image]")
        default:
            return nil
        }
    }

    private static func toolResultText(_ object: [String: Any]) -> String {
        if let content = object["content"] as? [[String: Any]] {
            let text = content.compactMap { block -> String? in
                if block["type"] as? String == "text" {
                    return block["text"] as? String
                }
                return nil
            }.joined(separator: "\n")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        if let raw = object["raw"] as? [String: Any] {
            if let data = raw["data"] as? [String: Any] {
                let stdout = data["stdout"] as? String ?? ""
                let stderr = data["stderr"] as? String ?? ""
                let combined = [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
                if !combined.isEmpty {
                    return combined
                }
            }
            return jsonString(raw)
        }
        return jsonString(object)
    }

    private static func jsonString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return string
    }

    private static func date(from raw: String?) -> Date? {
        guard let raw else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: raw) {
            return parsed
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
            .date(from: raw)
    }

    private static func isInternalSession(_ sessionID: String) -> Bool {
        internalSessionPrefixes.contains { sessionID.hasPrefix($0) }
    }
}

struct LegacyConfigSnapshot: Equatable {
    var baseURL: String?
    var model: String?
    var apiKey: String?
    var workspacesRoot: String?
    var generalWorkspacePath: String?
}

struct NativeConfigSnapshot: Equatable {
    var providerConfig: ProviderConfig
    var apiKey: String?
    var workspacesRoot: String?
    var generalWorkspacePath: String?
    var apiTimeoutMs: Int
    var contextWindow: Int
    var mainEntryID: String
    var defaultEntryID: String
    var rawValues: [String: String]
}

enum PilotDeckConfigPath {
    private static let configDirectoryName = ".pilotdeck"
    private static let configFileName = "pilotdeck.yaml"
    private static let legacyConfigFileName = "config.yaml"

    static func configURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let override = environment["PILOTDECK_CONFIG_PATH"]?.nilIfBlank {
            if override == "~" {
                return home
            }
            if override.hasPrefix("~/") {
                return home.appendingPathComponent(String(override.dropFirst(2)))
            }
            return URL(fileURLWithPath: override)
        }
        return home
            .appendingPathComponent(configDirectoryName, isDirectory: true)
            .appendingPathComponent(configFileName)
    }

    static func legacyConfigURLs(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let oldPilotDeckConfig = home
            .appendingPathComponent(configDirectoryName, isDirectory: true)
            .appendingPathComponent(legacyConfigFileName)
        return [oldPilotDeckConfig]
    }

    static func legacyConfigURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        legacyConfigURLs(home: home)[0]
    }
}

enum PilotDeckConfigDefaults {
    static func configText(homePath: String, userName: String) -> String {
        """
        schemaVersion: 1
        agent:
          model: ""
          params: {}
          subagents:
            default: inherit
            params: {}
        model:
          providers: {}
        memory:
          enabled: true
          reasoningMode: answer_first
          autoIndexIntervalMinutes: 30
          autoDreamIntervalMinutes: 60
          captureStrategy: last_turn
          includeAssistant: true
          maxMessageChars: 6000
          heartbeatBatchSize: 30
        webui:
          runtime:
            host: 0.0.0.0
            serverPort: 3001
            vitePort: 5173
            proxyPort: 18080
            apiTimeoutMs: 120000
            httpsProxy: ""
            databasePath: \(homePath)/.pilotdeck/auth.db
            workspacesRoot: \(homePath)
        alwaysOn:
          enabled: false
          language: zh-CN
          trigger:
            enabled: false
            tickIntervalMinutes: 5
            cooldownMinutes: 60
            dailyBudget: 4
            heartbeatStaleSeconds: 90
            recentUserMsgMinutes: 5
            preferChannel: native
          dormancy:
            enabled: true
            debounceMs: 2000
            ignoreGlobs: []
          workspace:
            gitWorktreeBaseDir: ""
            snapshotBaseDir: ""
            snapshotMaxBytes: 1073741824
            gitLfs: false
          execution:
            maxTurns: 30
            maxToolCalls: 200
            timeoutMinutes: 20
          projects: {}
        tools:
          webSearch:
            provider: glm
            endpoint: https://api.z.ai/api/paas/v4/web_search
            timeoutMs: 30000
            organicLimit: 8
            customProvider:
              name: custom
              auth: bearer
              method: POST
              queryParam: query
              apiKeyParam: api_key
              titleField: title
              urlField: url
              snippetField: snippet
              sourceField: source
              publishedAtField: publishedAt
        router:
          enabled: false
          log: true
          host: 127.0.0.1
          port: 19080
          apiTimeoutMs: 120000
          scenarios:
            default: ""
            background: ""
            think: ""
            longContext: ""
            webSearch: ""
          routes:
            longContextThreshold: 60000
          tokenSaver:
            enabled: false
            judge: ""
            defaultTier: medium
            subagentPolicy: inherit
            judgeTimeoutMs: 15000
            tiers:
              simple:
                model: ""
                description: Simple Q&A, file reads, greetings, small edits
              medium:
                model: ""
                description: Moderate coding, single-file edits, explanations
              complex:
                model: ""
                description: Multi-step coding, architecture, large refactors
              reasoning:
                model: ""
                description: Deep reasoning, novel algorithms, security analysis
            rules:
              - Short prompts (<20 words) -> SIMPLE
              - Single-file edits, code review -> MEDIUM
              - Multi-file tasks, refactoring -> COMPLEX
              - Novel architecture, deep analysis -> REASONING
          autoOrchestrate:
            enabled: false
            triggerTiers:
              - COMPLEX
              - REASONING
            mainAgentModel: ""
            skillPath: ~/.pilotdeck/prompts/auto-orchestrate.md
            blockedTools: []
            allowedTools:
              - Agent
              - Read
              - Grep
              - Glob
              - TodoRead
              - TodoWrite
            subagentMaxTokens: 48000
            slimSystemPrompt: true
          tokenStats:
            enabled: true
            baselineModel: ""
            defaultCostPerMillion: 0.8
          zeroUsageRetry:
            enabled: true
            maxAttempts: 1
          transientRetry:
            enabled: true
            maxAttempts: 5
            baseDelayMs: 200
            retry429: false
            retry5xx: true
            retryTransport: true
          fallback: {}
          httpsProxy: ""
          rewriteSystemPrompt: ""
          customRouterPath: ""
        gateway:
          enabled: false
          home: \(homePath)/.pilotdeck/gateway
          allowAllUsers: false
          allowedUsers: []
          groupSessionsPerUser: true
          threadSessionsPerUser: false
          unauthorizedDmBehavior: pair
          streaming:
            enabled: false
            transport: edit
            editInterval: 1.0
            bufferThreshold: 40
            cursor: " ▉"
          sessionReset:
            default:
              mode: both
              atHour: 4
              idleMinutes: 1440
              notify: true
              notifyExcludeChannels:
                - api_server
                - webhook
            byType: {}
            byChannel: {}
          quickCommands: {}
          channels:
            feishu:
              enabled: false
              appId: ""
              appSecret: ""
              connectionMode: websocket
              domainName: feishu
              verificationToken: ""
              encryptKey: ""
              webhookHost: 127.0.0.1
              webhookPort: 8765
              webhookPath: /feishu/webhook
              projectCard: false
              homeChannel:
                chatId: ""
                name: Home
              allowedUsers: []
              allowAllUsers: false
              replyToMode: first
            telegram:
              enabled: false
              token: ""
              webhookUrl: ""
              webhookPort: null
              homeChannel:
                chatId: ""
                name: Home
              allowedUsers: []
              allowAllUsers: false
              replyToMode: first
            discord:
              enabled: false
              token: ""
              homeChannel:
                chatId: ""
                name: Home
              allowedUsers: []
              allowAllUsers: false
              replyToMode: first
            slack:
              enabled: false
              botToken: ""
              appToken: ""
              homeChannel:
                chatId: ""
                name: Home
              allowedUsers: []
              allowAllUsers: false
              replyToMode: first
            wecom:
              enabled: false
              botId: ""
              botSecret: ""
              websocketUrl: wss://openws.work.weixin.qq.com
              homeChannel:
                chatId: ""
                name: Home
              allowedUsers: []
              allowAllUsers: false
              replyToMode: first
            wecom_callback:
              enabled: false
              port: null
              corpId: ""
              token: ""
              encodingAesKey: ""
              corpSecret: ""
              agentId: ""
              apps: []
              homeChannel:
                chatId: ""
                name: Home
              allowedUsers: []
              allowAllUsers: false
              replyToMode: first
            dingtalk:
              enabled: false
              clientId: ""
              clientSecret: ""
              streamDebug: false
              homeChannel:
                chatId: ""
                name: Home
              allowedUsers: []
              allowAllUsers: false
              replyToMode: first
            weixin:
              enabled: false
              baseUrl: ""
              token: ""
              accountId: ""
              cdnAesKey: ""
              homeChannel:
                chatId: ""
                name: Home
              allowedUsers: []
              allowAllUsers: false
              replyToMode: first
            whatsapp:
              enabled: false
              homeChannel:
                chatId: ""
                name: Home
              allowedUsers: []
              allowAllUsers: false
              replyToMode: first
            signal:
              enabled: false
              httpUrl: ""
              account: ""
              homeChannel:
                chatId: ""
                name: Home
              allowedUsers: []
              allowAllUsers: false
              replyToMode: first
            matrix:
              enabled: false
              homeserver: ""
              accessToken: ""
              userId: ""
              password: ""
              encryption: false
              homeChannel:
                chatId: ""
                name: Home
              allowedUsers: []
              allowAllUsers: false
              replyToMode: first
            mattermost:
              enabled: false
              url: ""
              token: ""
              homeChannel:
                chatId: ""
                name: Home
              allowedUsers: []
              allowAllUsers: false
              replyToMode: first
            email:
              enabled: false
              address: ""
              password: ""
              imapHost: ""
              imapPort: 993
              smtpHost: ""
              smtpPort: 587
              homeChannel:
                chatId: ""
                name: Home
              allowedUsers: []
              allowAllUsers: false
              replyToMode: first
            sms_twilio:
              enabled: false
              accountSid: ""
              authToken: ""
              phoneNumber: ""
              webhookPort: 8790
              homeChannel:
                chatId: ""
                name: Home
              allowedUsers: []
              allowAllUsers: false
              replyToMode: first
            homeassistant:
              enabled: false
              url: ""
              token: ""
            api_server:
              enabled: false
              key: ""
              port: 8642
              host: ""
              corsOrigins: ""
              modelName: pilotdeck-gateway
            webhook:
              enabled: false
              port: 8643
              secret: ""
            bluebubbles:
              enabled: false
              serverUrl: ""
              password: ""
              homeChannel:
                chatId: ""
                name: Home
              allowedUsers: []
              allowAllUsers: false
              replyToMode: first
          runtimePaths:
            sessionMetadata: ~/.pilotdeck/projects/.gateway/sessions.json
            userBindings: ~/.pilotdeck/projects/.gateway/user-projects.json
            generalCwd: ~/PilotDeck/general
            generalJsonl: ~/.pilotdeck/projects/-Users-\(userName)-PilotDeck-general/*.jsonl
            boundProjectJsonl: ~/.pilotdeck/projects/<encoded-project>/*.jsonl
        """
    }
}

enum NativeConfigService {
    static func webSchemaConfigTextIfNeeded(from yaml: String, homePath: String, userName: String) -> String {
        let values = scalarMap(from: yaml)
        if values["schemaVersion"] != nil || values.keys.contains(where: { $0.hasPrefix("model.providers.") }) {
            return yaml
        }

        let entries = modelEntryIDs(values: values)
        let providerIDs = legacyProviderIDs(values: values, entries: entries)
        let mainEntry = values["agents.main.model"]?.nilIfBlank ?? "default"
        let mainRef = legacyEntryToModelRef(mainEntry, values: values) ?? ""
        let modelRef = { (key: String, fallback: String) -> String in
            yamlScalar(legacyEntryToModelRef(values[key] ?? "", values: values) ?? fallback)
        }
        let modelRefAny = { (keys: [String], fallback: String) -> String in
            let raw = keys.compactMap { values[$0]?.nilIfBlank }.first ?? ""
            return yamlScalar(legacyEntryToModelRef(raw, values: values) ?? fallback)
        }

        var lines: [String] = [
            "schemaVersion: 1",
            "agent:",
            "  model: \(yamlScalar(mainRef))",
            "  params: {}",
            "  subagents:",
            "    default: \(yamlScalar(values["agents.subagents.default"]?.nilIfBlank ?? "inherit"))",
            "    params: {}",
            "model:",
            "  providers:",
        ]

        if providerIDs.isEmpty {
            lines[lines.count - 1] = "  providers: {}"
        } else {
            for providerID in providerIDs {
                lines.append("    \(providerID):")
                lines.append("      protocol: \(yamlScalar(legacyTypeToProviderProtocol(values["models.providers.\(providerID).type"])))")
                lines.append("      url: \(yamlScalar(values["models.providers.\(providerID).baseUrl"] ?? ""))")
                lines.append("      apiKey: \(yamlScalar(values["models.providers.\(providerID).apiKey"] ?? ""))")
                lines.append("      models:")
                let providerEntries = entries.filter { values["models.entries.\($0).provider"] == providerID }
                if providerEntries.isEmpty {
                    lines[lines.count - 1] = "      models: {}"
                } else {
                    for entry in providerEntries {
                        guard let model = values["models.entries.\(entry).name"]?.nilIfBlank else { continue }
                        if let context = values["models.entries.\(entry).contextWindow"]?.nilIfBlank {
                            lines.append("        \(model):")
                            lines.append("          capabilities:")
                            lines.append("            maxContextTokens: \(context)")
                        } else {
                            lines.append("        \(model): {}")
                        }
                    }
                }
            }
        }

        lines.append(contentsOf: [
            "memory:",
            "  enabled: \(values["memory.enabled"] ?? "true")",
            "  model: \(yamlScalar(legacyEntryToModelRef(values["memory.model"] ?? "", values: values) ?? values["memory.model"] ?? ""))",
            "  reasoningMode: \(yamlScalar(values["memory.reasoningMode"] ?? "answer_first"))",
            "  autoIndexIntervalMinutes: \(values["memory.autoIndexIntervalMinutes"] ?? "30")",
            "  autoDreamIntervalMinutes: \(values["memory.autoDreamIntervalMinutes"] ?? "60")",
            "  captureStrategy: \(yamlScalar(values["memory.captureStrategy"] ?? "last_turn"))",
            "  includeAssistant: \(values["memory.includeAssistant"] ?? "true")",
            "  maxMessageChars: \(values["memory.maxMessageChars"] ?? "6000")",
            "  heartbeatBatchSize: \(values["memory.heartbeatBatchSize"] ?? "30")",
            "webui:",
            "  runtime:",
            "    host: \(yamlScalar(values["runtime.host"] ?? "0.0.0.0"))",
            "    serverPort: \(values["runtime.serverPort"] ?? "3001")",
            "    vitePort: \(values["runtime.vitePort"] ?? "5173")",
            "    proxyPort: \(values["runtime.proxyPort"] ?? "18080")",
            "    apiTimeoutMs: \(values["runtime.apiTimeoutMs"] ?? "120000")",
            "    httpsProxy: \(yamlScalar(values["runtime.httpsProxy"] ?? ""))",
            "    databasePath: \(yamlScalar(values["runtime.databasePath"] ?? "\(homePath)/.pilotdeck/auth.db"))",
            "    workspacesRoot: \(yamlScalar(values["runtime.workspacesRoot"]?.nilIfBlankOrConfigNull ?? homePath))",
            "alwaysOn:",
            "  enabled: \(values["alwaysOn.enabled"] ?? "false")",
            "  trigger:",
            "    enabled: \(values["alwaysOn.trigger.enabled"] ?? "false")",
            "    tickIntervalMinutes: \(values["alwaysOn.trigger.tickIntervalMinutes"] ?? "5")",
            "    cooldownMinutes: \(values["alwaysOn.trigger.cooldownMinutes"] ?? "60")",
            "    dailyBudget: \(values["alwaysOn.trigger.dailyBudget"] ?? "4")",
            "  projects: {}",
            "tools:",
            "  webSearch:",
            "    provider: \(yamlScalar(values["tools.webSearch.provider"] ?? "glm"))",
            "    endpoint: \(yamlScalar(values["tools.webSearch.endpoint"] ?? "https://api.z.ai/api/paas/v4/web_search"))",
            "router:",
            "  enabled: \(values["router.enabled"] ?? "false")",
            "  scenarios:",
            "    default: \(modelRef("router.routes.default.model", mainRef))",
            "    background: \(modelRef("router.routes.background.model", mainRef))",
            "    think: \(modelRef("router.routes.think.model", mainRef))",
            "    longContext: \(modelRef("router.routes.longContext.model", mainRef))",
            "    webSearch: \(modelRef("router.routes.webSearch.model", mainRef))",
            "  routes:",
            "    longContextThreshold: \(values["router.routes.longContextThreshold"] ?? values["router.longContextThreshold"] ?? "60000")",
            "  tokenSaver:",
            "    enabled: \(values["router.tokenSaver.enabled"] ?? "false")",
            "    judge: \(modelRef("router.tokenSaver.judgeModel", mainRef))",
            "    tiers:",
            "      simple:",
            "        model: \(modelRefAny(["router.tokenSaver.tiers.simple.model", "router.tokenSaver.tiers.SIMPLE.model"], mainRef))",
            "      medium:",
            "        model: \(modelRefAny(["router.tokenSaver.tiers.medium.model", "router.tokenSaver.tiers.MEDIUM.model"], mainRef))",
            "      complex:",
            "        model: \(modelRefAny(["router.tokenSaver.tiers.complex.model", "router.tokenSaver.tiers.COMPLEX.model"], mainRef))",
            "      reasoning:",
            "        model: \(modelRefAny(["router.tokenSaver.tiers.reasoning.model", "router.tokenSaver.tiers.REASONING.model"], mainRef))",
            "gateway:",
            "  enabled: \(values["gateway.enabled"] ?? "false")",
            "  home: \(yamlScalar(values["gateway.home"] ?? "\(homePath)/.pilotdeck/gateway"))",
            "  runtimePaths:",
            "    generalCwd: \(yamlScalar(values["gateway.runtimePaths.generalCwd"]?.nilIfBlankOrConfigNull ?? "~/PilotDeck/general"))",
            "    generalJsonl: \(yamlScalar(values["gateway.runtimePaths.generalJsonl"] ?? "~/.pilotdeck/projects/-Users-\(userName)-PilotDeck-general/*.jsonl"))",
        ])

        if let webSearchAPIKey = values["tools.webSearch.apiKey"]?.nilIfBlank {
            let insertIndex = lines.firstIndex(of: "    endpoint: \(yamlScalar(values["tools.webSearch.endpoint"] ?? "https://api.z.ai/api/paas/v4/web_search"))") ?? lines.count
            lines.insert("    apiKey: \(yamlScalar(webSearchAPIKey))", at: insertIndex)
        }

        return lines.joined(separator: "\n") + "\n"
    }

    static func loadDefaultConfig(
        url: URL = PilotDeckConfigPath.configURL()
    ) -> NativeConfigSnapshot? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return snapshot(from: text)
    }

    static func snapshot(from yaml: String) -> NativeConfigSnapshot? {
        let values = scalarMap(from: yaml)
        let mainEntry = values["agent.model"]?.nilIfBlank
            ?? values["agents.main.model"]?.nilIfBlank
            ?? "default"
        let mainEntryID = validEntryID(mainEntry, values: values) ?? "default"
        let defaultEntry = values["router.scenarios.default"]?.nilIfBlank
            ?? values["router.routes.default.model"]?.nilIfBlank
            ?? values["router.default"]?.nilIfBlank
            ?? mainEntryID
        let defaultEntryID = validEntryID(defaultEntry, values: values) ?? mainEntryID
        guard let providerConfig = providerConfig(entryID: mainEntryID, values: values) else { return nil }
        let mainProviderID = providerID(entryID: mainEntryID, values: values)
        let apiKey = values["model.providers.\(mainProviderID).apiKey"]
            ?? values["models.providers.\(mainProviderID).apiKey"]
        let workspacesRoot = (values["webui.runtime.workspacesRoot"] ?? values["runtime.workspacesRoot"])?.nilIfBlankOrConfigNull
        let generalWorkspacePath = values["gateway.runtimePaths.generalCwd"]?.nilIfBlankOrConfigNull
        let apiTimeoutMs = values["webui.runtime.apiTimeoutMs"].flatMap(Int.init)
            ?? values["runtime.apiTimeoutMs"].flatMap(Int.init)
            ?? values["router.apiTimeoutMs"].flatMap(Int.init)
            ?? 120_000
        let contextWindow = contextWindow(entryID: mainEntryID, values: values) ?? 160_000

        return NativeConfigSnapshot(
            providerConfig: providerConfig,
            apiKey: apiKey,
            workspacesRoot: workspacesRoot,
            generalWorkspacePath: generalWorkspacePath,
            apiTimeoutMs: apiTimeoutMs,
            contextWindow: contextWindow,
            mainEntryID: mainEntryID,
            defaultEntryID: defaultEntryID,
            rawValues: values
        )
    }

    static func contextWindow(entryID: String, values: [String: String]) -> Int? {
        let configuredWindow = positiveInt(values["models.entries.\(entryID).contextWindow"])
            ?? webModelContextWindow(entryID: entryID, values: values)
            ?? positiveInt(values["webui.runtime.contextWindow"])
            ?? positiveInt(values["runtime.contextWindow"])
        guard let agentMax = agentMaxContextTokens(values: values) else {
            return configuredWindow
        }
        guard let configuredWindow else {
            return agentMax
        }
        return min(configuredWindow, agentMax)
    }

    static func scalarMap(from yaml: String) -> [String: String] {
        var result: [String: String] = [:]
        var stack: [(indent: Int, key: String)] = []
        let lines = yaml
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        for index in lines.indices {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("- ") else { continue }
            let indent = line.prefix { $0 == " " }.count
            while let last = stack.last, last.indent >= indent {
                stack.removeLast()
            }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let rawValue = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            let path = (stack.map(\.key) + [key]).joined(separator: ".")
            if rawValue.isEmpty {
                if let sequence = stringSequenceValue(after: index, in: lines, parentIndent: indent) {
                    result[path] = sequence.joined(separator: "\n")
                    continue
                }
                stack.append((indent, key))
                continue
            }
            if rawValue == "[]" {
                result[path] = ""
            } else if rawValue.hasPrefix("["), rawValue.hasSuffix("]") {
                result[path] = parseInlineStringArray(rawValue).joined(separator: "\n")
            } else {
                result[path] = normalizeScalar(rawValue)
            }
        }

        return normalizedScalarMap(result)
    }

    private static func stringSequenceValue(after index: Int, in lines: [String], parentIndent: Int) -> [String]? {
        var values: [String] = []
        var sawChild = false
        var current = index + 1
        while current < lines.count {
            let line = lines[current]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                current += 1
                continue
            }
            let indent = line.prefix { $0 == " " }.count
            if indent <= parentIndent { break }
            sawChild = true
            guard trimmed.hasPrefix("- ") else { return nil }
            let rawValue = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            values.append(normalizeScalar(rawValue))
            current += 1
        }
        return sawChild ? values : nil
    }

    private static func parseInlineStringArray(_ rawValue: String) -> [String] {
        let body = rawValue
            .dropFirst()
            .dropLast()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return [] }
        return body
            .split(separator: ",")
            .map { normalizeScalar(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.isEmpty }
    }

    private static func normalizedScalarMap(_ values: [String: String]) -> [String: String] {
        var normalized = values

        addWebSchemaAliases(values, into: &normalized)
        migrateAlwaysOnScalars(values, into: &normalized)
        normalized = normalized.filter { !$0.key.hasPrefix("agents.alwaysOn.") }
        normalized = normalized.filter { !$0.key.hasPrefix("alwaysOn.discovery.") }

        normalized = normalized.filter { $0.key != "compat" && !$0.key.hasPrefix("compat.") }

        return normalized
    }

    private static func addWebSchemaAliases(_ values: [String: String], into normalized: inout [String: String]) {
        copyAlias(from: "schemaVersion", to: "version", values: values, normalized: &normalized)
        copyPrefixAliases(from: "webui.runtime.", to: "runtime.", values: values, normalized: &normalized)

        copyAlias(from: "agent.model", to: "agents.main.model", values: values, normalized: &normalized)
        copyAlias(from: "agent.subagents.default", to: "agents.subagents.default", values: values, normalized: &normalized)

        for providerID in webProviderIDs(values) {
            let providerPrefix = "model.providers.\(providerID)."
            let legacyPrefix = "models.providers.\(providerID)."
            if normalized["\(legacyPrefix)type"] == nil {
                let protocolValue = values["\(providerPrefix)protocol"]?.nilIfBlank ?? "openai"
                normalized["\(legacyPrefix)type"] = providerProtocolToLegacyType(protocolValue)
            }
            copyAlias(from: "\(providerPrefix)url", to: "\(legacyPrefix)baseUrl", values: values, normalized: &normalized)
            copyAlias(from: "\(providerPrefix)apiKey", to: "\(legacyPrefix)apiKey", values: values, normalized: &normalized)
            copyPrefixAliases(from: "\(providerPrefix)headers.", to: "\(legacyPrefix)headers.", values: values, normalized: &normalized)

            for modelID in webModelIDs(providerID: providerID, values: values) {
                let entryID = modelRef(providerID: providerID, modelID: modelID)
                normalized["models.entries.\(entryID).provider"] = normalized["models.entries.\(entryID).provider"] ?? providerID
                normalized["models.entries.\(entryID).name"] = normalized["models.entries.\(entryID).name"] ?? modelID
                let maxContextPath = "model.providers.\(providerID).models.\(modelID).capabilities.maxContextTokens"
                if let maxContext = values[maxContextPath],
                   normalized["models.entries.\(entryID).contextWindow"] == nil {
                    normalized["models.entries.\(entryID).contextWindow"] = maxContext
                }
            }
        }

        let modelRefs = [
            values["agent.model"],
            values["memory.model"],
            values["agent.subagents.default"],
            values["router.scenarios.default"],
            values["router.scenarios.background"],
            values["router.scenarios.think"],
            values["router.scenarios.longContext"],
            values["router.scenarios.webSearch"],
            values["router.tokenSaver.judge"],
            values["router.tokenSaver.tiers.simple.model"],
            values["router.tokenSaver.tiers.medium.model"],
            values["router.tokenSaver.tiers.complex.model"],
            values["router.tokenSaver.tiers.reasoning.model"],
        ]
        for ref in modelRefs.compactMap({ $0?.nilIfBlank }) where ref != "inherit" {
            guard let parsed = splitModelRef(ref), values["model.providers.\(parsed.providerID).url"] != nil || values["model.providers.\(parsed.providerID).apiKey"] != nil || values["model.providers.\(parsed.providerID).protocol"] != nil else {
                continue
            }
            let entryID = modelRef(providerID: parsed.providerID, modelID: parsed.modelID)
            normalized["models.entries.\(entryID).provider"] = normalized["models.entries.\(entryID).provider"] ?? parsed.providerID
            normalized["models.entries.\(entryID).name"] = normalized["models.entries.\(entryID).name"] ?? parsed.modelID
        }

        copyAlias(from: "router.scenarios.default", to: "router.routes.default.model", values: values, normalized: &normalized)
        copyAlias(from: "router.scenarios.background", to: "router.routes.background.model", values: values, normalized: &normalized)
        copyAlias(from: "router.scenarios.think", to: "router.routes.think.model", values: values, normalized: &normalized)
        copyAlias(from: "router.scenarios.longContext", to: "router.routes.longContext.model", values: values, normalized: &normalized)
        copyAlias(from: "router.scenarios.webSearch", to: "router.routes.webSearch.model", values: values, normalized: &normalized)
        copyAlias(from: "router.tokenSaver.judge", to: "router.tokenSaver.judgeModel", values: values, normalized: &normalized)
    }

    private static func copyAlias(from source: String, to target: String, values: [String: String], normalized: inout [String: String]) {
        guard normalized[target] == nil, let value = values[source] else { return }
        normalized[target] = value
    }

    private static func copyPrefixAliases(from sourcePrefix: String, to targetPrefix: String, values: [String: String], normalized: inout [String: String]) {
        for (key, value) in values where key.hasPrefix(sourcePrefix) {
            let suffix = String(key.dropFirst(sourcePrefix.count))
            if normalized["\(targetPrefix)\(suffix)"] == nil {
                normalized["\(targetPrefix)\(suffix)"] = value
            }
        }
    }

    private static func webProviderIDs(_ values: [String: String]) -> [String] {
        let prefix = "model.providers."
        var ids = Set<String>()
        for key in values.keys where key.hasPrefix(prefix) {
            let suffix = String(key.dropFirst(prefix.count))
            guard let first = suffix.split(separator: ".").first else { continue }
            ids.insert(String(first))
        }
        return ids.sorted()
    }

    static func webModelIDs(providerID: String, values: [String: String]) -> [String] {
        let prefix = "model.providers.\(providerID).models."
        var ids = Set<String>()
        for key in values.keys where key.hasPrefix(prefix) {
            let suffix = String(key.dropFirst(prefix.count))
            if let capabilitiesRange = suffix.range(of: ".capabilities.") {
                ids.insert(String(suffix[..<capabilitiesRange.lowerBound]))
            } else if let multimodalRange = suffix.range(of: ".multimodal.") {
                ids.insert(String(suffix[..<multimodalRange.lowerBound]))
            } else {
                ids.insert(suffix)
            }
        }
        return ids.sorted()
    }

    static func modelEntryIDs(values: [String: String]) -> [String] {
        let prefix = "models.entries."
        var ids = Set<String>()
        for key in values.keys where key.hasPrefix(prefix) {
            let suffix = String(key.dropFirst(prefix.count))
            if let range = suffix.range(of: ".provider") ?? suffix.range(of: ".name") ?? suffix.range(of: ".contextWindow") {
                ids.insert(String(suffix[..<range.lowerBound]))
            } else if let first = suffix.split(separator: ".").first {
                ids.insert(String(first))
            }
        }
        return ids.sorted()
    }

    private static func providerProtocolToLegacyType(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "anthropic":
            return "anthropic"
        default:
            return "openai-chat"
        }
    }

    private static func legacyTypeToProviderProtocol(_ value: String?) -> String {
        switch (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "anthropic", "anthropic-messages":
            return "anthropic"
        default:
            return "openai"
        }
    }

    private static func legacyProviderIDs(values: [String: String], entries: [String]) -> [String] {
        let explicit = values.keys.compactMap { key -> String? in
            let prefix = "models.providers."
            guard key.hasPrefix(prefix) else { return nil }
            return key.dropFirst(prefix.count).split(separator: ".").first.map(String.init)
        }
        let fromEntries = entries.compactMap { values["models.entries.\($0).provider"]?.nilIfBlank }
        return Array(Set(explicit + fromEntries)).sorted()
    }

    private static func legacyEntryToModelRef(_ entryID: String, values: [String: String]) -> String? {
        let entry = entryID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entry.isEmpty, entry != "inherit" else { return entry.isEmpty ? nil : entry }
        if splitModelRef(entry) != nil {
            return entry
        }
        guard let provider = values["models.entries.\(entry).provider"]?.nilIfBlank,
              let model = values["models.entries.\(entry).name"]?.nilIfBlank else {
            return nil
        }
        return modelRef(providerID: provider, modelID: model)
    }

    private static func yamlScalar(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "\"\"" }
        let lower = trimmed.lowercased()
        if lower == "true" || lower == "false" || lower == "null" || Int(trimmed) != nil || Double(trimmed) != nil {
            return trimmed
        }
        let needsQuote = trimmed.contains("#")
            || trimmed.contains(": ")
            || trimmed.contains("{")
            || trimmed.contains("}")
            || trimmed.contains("[")
            || trimmed.contains("]")
            || trimmed.hasPrefix("*")
            || trimmed.hasPrefix("&")
            || trimmed.hasPrefix("!")
            || trimmed.hasPrefix("|")
            || trimmed.hasPrefix(">")
            || trimmed.hasPrefix("-")
            || trimmed.hasPrefix("@")
            || trimmed.hasPrefix("`")
        if needsQuote {
            return "\"\(trimmed.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        return trimmed
    }

    private static func migrateAlwaysOnScalars(_ values: [String: String], into normalized: inout [String: String]) {
        migrateAlwaysOnTriggerScalars(values, into: &normalized, legacyPrefix: "agents.alwaysOn.discovery.trigger.")
        migrateAlwaysOnTriggerScalars(values, into: &normalized, legacyPrefix: "alwaysOn.discovery.trigger.")

        let legacyProjectPrefixes = [
            "agents.alwaysOn.discovery.projects.",
            "alwaysOn.discovery.projects.",
        ]
        for prefix in legacyProjectPrefixes {
            for (key, value) in values where key.hasPrefix(prefix) {
                let suffix = String(key.dropFirst(prefix.count))
                let target = "alwaysOn.projects.\(suffix)"
                if normalized[target] == nil {
                    normalized[target] = value
                }
            }
        }
    }

    private static func migrateAlwaysOnTriggerScalars(
        _ values: [String: String],
        into normalized: inout [String: String],
        legacyPrefix: String
    ) {
        for (key, value) in values where key.hasPrefix(legacyPrefix) {
            let legacySuffix = String(key.dropFirst(legacyPrefix.count))
            let suffix = legacySuffix == "preferClient" ? "preferChannel" : legacySuffix
            let target = "alwaysOn.trigger.\(suffix)"
            if normalized[target] == nil {
                normalized[target] = suffix == "preferChannel" ? normalizedAlwaysOnChannel(value) : value
            }
        }
    }

    private static func normalizedAlwaysOnChannel(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "webui", "web-ui", "web_ui":
            return "web"
        case "macos", "mac", "native":
            return "native"
        default:
            return value
        }
    }

    static func validEntryID(_ entryID: String, values: [String: String]) -> String? {
        if values["models.entries.\(entryID).provider"] != nil {
            return entryID
        }
        guard let parsed = splitModelRef(entryID),
              values.keys.contains(where: { $0.hasPrefix("model.providers.\(parsed.providerID).") }) else {
            return nil
        }
        return entryID
    }

    private static func positiveInt(_ rawValue: String?) -> Int? {
        guard let value = rawValue.flatMap(Int.init), value > 0 else { return nil }
        return value
    }

    private static func agentMaxContextTokens(values: [String: String]) -> Int? {
        positiveInt(values["agent.maxContextTokens"])
            ?? positiveInt(values["agents.main.maxContextTokens"])
    }

    static func providerConfig(entryID: String, values: [String: String]) -> ProviderConfig? {
        let providerID = providerID(entryID: entryID, values: values)
        let baseURL = values["model.providers.\(providerID).url"]
            ?? values["models.providers.\(providerID).baseUrl"]
            ?? ""
        let model = values["models.entries.\(entryID).name"]
            ?? splitModelRef(entryID)?.modelID
            ?? ""
        guard !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let type = values["models.providers.\(providerID).type"]
            ?? providerProtocolToLegacyType(values["model.providers.\(providerID).protocol"] ?? "openai")
        let apiType: ProviderAPIType
        switch type {
        case "openai-responses":
            apiType = .openAIResponses
        case "anthropic-messages", "anthropic":
            apiType = .anthropicMessages
        default:
            apiType = .openAIChat
        }
        let headersPrefix = "models.providers.\(providerID).headers."
        var headers: [String: String] = [:]
        for (key, value) in values where key.hasPrefix(headersPrefix) {
            headers[String(key.dropFirst(headersPrefix.count))] = value
        }
        return ProviderConfig(
            provider: .pilotDeck,
            apiType: apiType,
            baseURL: baseURL,
            model: model,
            secretAccount: isPilotDeckProviderID(providerID) ? ProviderConfig.empty.secretAccount : "pilotdeck-provider-\(providerID)-api-key",
            headers: headers
        )
    }

    static func providerID(entryID: String, values: [String: String]) -> String {
        values["models.entries.\(entryID).provider"]?.nilIfBlank
            ?? splitModelRef(entryID)?.providerID
            ?? "pilotdeck"
    }

    private static func isPilotDeckProviderID(_ providerID: String) -> Bool {
        switch providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "pilotdeck":
            return true
        default:
            return false
        }
    }

    static func resolvedAPIKey(
        routeEntryID: String,
        nativeConfig: NativeConfigSnapshot?
    ) -> String {
        guard let nativeConfig else {
            return ""
        }
        let providerID = providerID(entryID: routeEntryID, values: nativeConfig.rawValues)
        return nativeConfig.rawValues["model.providers.\(providerID).apiKey"]?.nilIfBlank
            ?? nativeConfig.rawValues["models.providers.\(providerID).apiKey"]?.nilIfBlank
            ?? nativeConfig.apiKey?.nilIfBlank
            ?? ""
    }

    static func splitModelRef(_ ref: String) -> (providerID: String, modelID: String)? {
        let value = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let slash = value.firstIndex(of: "/"),
              slash > value.startIndex,
              slash < value.index(before: value.endIndex) else {
            return nil
        }
        return (
            providerID: String(value[..<slash]),
            modelID: String(value[value.index(after: slash)...])
        )
    }

    static func modelRef(providerID: String, modelID: String) -> String {
        "\(providerID)/\(modelID)"
    }

    private static func webModelContextWindow(entryID: String, values: [String: String]) -> Int? {
        guard let parsed = splitModelRef(entryID) else { return nil }
        return positiveInt(values["model.providers.\(parsed.providerID).models.\(parsed.modelID).capabilities.maxContextTokens"])
            ?? positiveInt(values["model.providers.\(parsed.providerID).models.\(parsed.modelID).maxContextTokens"])
    }

    private static func normalizeScalar(_ rawValue: String) -> String {
        var value = rawValue
        if let commentStart = value.firstIndex(of: "#") {
            value = String(value[..<commentStart]).trimmingCharacters(in: .whitespaces)
        }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'")) {
            value.removeFirst()
            value.removeLast()
        }
        return value
    }
}

enum NativeRouterRuntime {
    private static let perMessageOverhead = 4
    private static let multimediaTokens = 2_000
    nonisolated(unsafe) private static var stickyDecisionsBySession: [String: RouterDecision] = [:]

    typealias Decision = RouterDecision

    struct RequestSignals: Equatable {
        var tokenCount: Int
        var isBackgroundRequest: Bool
        var hasWebSearchTools: Bool
        var hasThinking: Bool
    }

    struct ProviderRoute: Equatable {
        var decision: Decision
        var providerConfig: ProviderConfig
        var apiKey: String
        var contextWindow: Int
    }

    static func entryID(forTier tier: String, values: [String: String]) -> String {
        decision(forTier: tier, values: values).entryID
    }

    static func decision(
        forTier tier: String,
        values: [String: String],
        signals: RequestSignals,
        sessionID: String? = nil
    ) -> Decision {
        decision(
            forTier: tier,
            values: values,
            tokenCount: signals.tokenCount,
            isBackgroundRequest: signals.isBackgroundRequest,
            hasWebSearchTools: signals.hasWebSearchTools,
            hasThinking: signals.hasThinking,
            sessionID: sessionID
        )
    }

    static func requestSignals(
        prompt: String,
        priorMessages: [ChatMessage],
        attachments: [FileAttachment],
        isBackgroundRequest: Bool = false,
        hasThinking: Bool = false,
        tools: [[String: Any]] = NativeToolRouter.openAITools()
    ) -> RequestSignals {
        RequestSignals(
            tokenCount: estimatedTokenCount(
                prompt: prompt,
                priorMessages: priorMessages,
                attachments: attachments,
                tools: tools
            ),
            isBackgroundRequest: isBackgroundRequest,
            hasWebSearchTools: hasWebSearchTool(tools),
            hasThinking: hasThinking
        )
    }

    static func resolvedProviderRoute(
        forTier tier: String,
        values: [String: String],
        fallbackProviderConfig: ProviderConfig,
        fallbackAPIKey: String,
        fallbackContextWindow: Int,
        signals: RequestSignals
    ) -> ProviderRoute {
        var routeDecision = decision(forTier: tier, values: values, signals: signals)
        let providerConfig = NativeConfigService.providerConfig(entryID: routeDecision.entryID, values: values)
            ?? fallbackProviderConfig
        let providerID = NativeConfigService.providerID(entryID: routeDecision.entryID, values: values)
        routeDecision.providerID = providerID
        routeDecision.model = providerConfig.model
        let apiKey = values["model.providers.\(providerID).apiKey"]?.nilIfBlank
            ?? values["models.providers.\(providerID).apiKey"]?.nilIfBlank
            ?? fallbackAPIKey
        let contextWindow = NativeConfigService.contextWindow(entryID: routeDecision.entryID, values: values)
            ?? fallbackContextWindow
        return ProviderRoute(
            decision: routeDecision,
            providerConfig: providerConfig,
            apiKey: apiKey,
            contextWindow: contextWindow
        )
    }

    static func decision(
        forTier tier: String,
        values: [String: String],
        tokenCount: Int = 0,
        lastInputTokens: Int? = nil,
        isBackgroundRequest: Bool = false,
        hasWebSearchTools: Bool = false,
        hasThinking: Bool = false,
        sessionID: String? = nil
    ) -> Decision {
        let mainRoute = mainEntryID(values: values) ?? "default"
        let defaultRoute = routeEntryID("default", values: values) ?? mainRoute
        guard isEnabled(values["router.enabled"]) else {
            return makeDecision(
                entryID: mainRoute,
                scenario: "default",
                tier: nil,
                resolvedFrom: "disabled",
                values: values,
                estimatedInputTokens: tokenCount
            )
        }

        let normalizedTier = RouterTier(canonicalizing: tier).rawValue
        if tokenSaverCanRoute(values: values) {
            if let sessionID,
               normalizedTier == RouterTier.simple.rawValue,
               let sticky = stickyDecisionsBySession[sessionID],
               sticky.tier != RouterTier.simple.rawValue {
                var decision = sticky
                decision.id = UUID().uuidString
                decision.stickyHit = true
                decision.reason = "sticky-session"
                decision.estimatedInputTokens = tokenCount
                return remember(decision, sessionID: sessionID)
            }
            if let tierModel = tokenSaverEntryID(for: normalizedTier, values: values),
               NativeConfigService.validEntryID(tierModel, values: values) != nil {
                return remember(
                    applyAutoOrchestrateIfNeeded(
                        makeDecision(
                            entryID: tierModel,
                            scenario: "tokenSaver",
                            tier: normalizedTier,
                            resolvedFrom: "tokenSaver",
                            values: values,
                            estimatedInputTokens: tokenCount
                        ),
                        values: values
                    ),
                    sessionID: sessionID
                )
            }
        }

        let threshold = longContextThreshold(values: values)
        let exceedsCurrentContext = tokenCount > threshold
        let exceedsLastUsage = (lastInputTokens ?? 0) > threshold && tokenCount > 20_000
        if (exceedsCurrentContext || exceedsLastUsage),
           let entryID = routeEntryID("longContext", values: values) {
            return remember(makeDecision(entryID: entryID, scenario: "longContext", tier: nil, resolvedFrom: "longContext", values: values, estimatedInputTokens: tokenCount), sessionID: sessionID)
        }

        if isBackgroundRequest, let entryID = routeEntryID("background", values: values) {
            return remember(makeDecision(entryID: entryID, scenario: "background", tier: nil, resolvedFrom: "background", values: values, estimatedInputTokens: tokenCount), sessionID: sessionID)
        }

        if hasWebSearchTools, let entryID = routeEntryID("webSearch", values: values) {
            return remember(makeDecision(entryID: entryID, scenario: "webSearch", tier: nil, resolvedFrom: "webSearch", values: values, estimatedInputTokens: tokenCount), sessionID: sessionID)
        }

        if hasThinking, let entryID = routeEntryID("think", values: values) {
            return remember(makeDecision(entryID: entryID, scenario: "think", tier: nil, resolvedFrom: "think", values: values, estimatedInputTokens: tokenCount), sessionID: sessionID)
        }

        return remember(makeDecision(entryID: defaultRoute, scenario: "default", tier: nil, resolvedFrom: "default", values: values, estimatedInputTokens: tokenCount), sessionID: sessionID)
    }

    static func invalidateSticky(sessionID: String) {
        stickyDecisionsBySession.removeValue(forKey: sessionID)
    }

    private static func remember(_ decision: Decision, sessionID: String?) -> Decision {
        if let sessionID, decision.scenario == "tokenSaver" {
            stickyDecisionsBySession[sessionID] = decision
        }
        return decision
    }

    private static func applyAutoOrchestrateIfNeeded(_ decision: Decision, values: [String: String]) -> Decision {
        guard isEnabled(values["router.autoOrchestrate.enabled"]),
              let tier = decision.tier,
              autoOrchestrateTriggerTiers(values: values).contains(RouterTier(canonicalizing: tier).rawValue) else {
            return decision
        }
        let entryID = values["router.autoOrchestrate.mainAgentModel"]?.nilIfBlank
            .flatMap { NativeConfigService.validEntryID($0, values: values) == nil ? nil : $0 }
            ?? decision.entryID
        var next = makeDecision(
            entryID: entryID,
            scenario: decision.scenario,
            tier: tier,
            resolvedFrom: decision.resolvedFrom,
            values: values,
            estimatedInputTokens: decision.estimatedInputTokens
        )
        next.id = decision.id
        next.stickyHit = decision.stickyHit
        next.orchestrating = true
        next.reason = [decision.reason, "auto-orchestrate-ready"].compactMap { $0 }.joined(separator: ", ")
        return next
    }

    private static func autoOrchestrateTriggerTiers(values: [String: String]) -> Set<String> {
        if let raw = values["router.autoOrchestrate.triggerTiers"]?.nilIfBlank {
            let parsed = raw
                .split { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" }
                .map { RouterTier(canonicalizing: String($0)).rawValue }
            if !parsed.isEmpty {
                return Set(parsed)
            }
        }
        return [RouterTier.complex.rawValue, RouterTier.reasoning.rawValue]
    }

    private static func makeDecision(
        entryID: String,
        scenario: String,
        tier: String?,
        resolvedFrom: String,
        values: [String: String],
        estimatedInputTokens: Int
    ) -> Decision {
        let providerID = NativeConfigService.providerID(entryID: entryID, values: values)
        let model = NativeConfigService.providerConfig(entryID: entryID, values: values)?.model
        return Decision(
            entryID: entryID,
            providerID: providerID,
            model: model,
            scenario: scenario,
            tier: tier,
            role: "main",
            resolvedFrom: resolvedFrom,
            estimatedInputTokens: estimatedInputTokens
        )
    }

    private static func tokenSaverCanRoute(values: [String: String]) -> Bool {
        let enabled = values["router.tokenSaver.enabled"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if enabled == "false" || enabled == "0" || enabled == "no" {
            return false
        }
        if enabled == "true" || enabled == "1" || enabled == "yes" {
            return true
        }
        return values.keys.contains { $0.hasPrefix("router.tokenSaver.tiers.") && $0.hasSuffix(".model") }
    }

    private static func tokenSaverEntryID(for tier: String, values: [String: String]) -> String? {
        let canonical = RouterTier(canonicalizing: tier).rawValue
        let legacy = canonical.uppercased()
        return values["router.tokenSaver.tiers.\(canonical).model"]?.nilIfBlank
            ?? values["router.tokenSaver.tiers.\(legacy).model"]?.nilIfBlank
    }

    private static func estimatedTokenCount(
        prompt: String,
        priorMessages: [ChatMessage],
        attachments: [FileAttachment],
        tools: [[String: Any]]
    ) -> Int {
        var total = priorMessages.reduce(0) { partial, message in
            partial + estimatedTokens(message: message)
        }
        total += perMessageOverhead + estimatedValue(userContent(prompt: prompt, attachments: attachments))
        total += estimatedTools(tools)
        return max(0, total)
    }

    private static func estimatedTokens(message: ChatMessage) -> Int {
        let content = message.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return 0 }
        return perMessageOverhead + estimatedValue(content)
    }

    private static func userContent(prompt: String, attachments: [FileAttachment]) -> Any {
        guard !attachments.isEmpty else { return prompt }
        let attachmentParts = NativeAttachmentResolver.openAIContentParts(for: attachments).0
        guard !attachmentParts.isEmpty else { return prompt }

        var content: [[String: Any]] = []
        if !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content.append([
                "type": "text",
                "text": prompt,
            ])
        }
        content.append(contentsOf: attachmentParts)
        return content
    }

    private static func estimatedTools(_ tools: [[String: Any]]) -> Int {
        tools.reduce(0) { partial, tool in
            var total = partial
            if let function = tool["function"] as? [String: Any] {
                let name = function["name"] as? String ?? ""
                let description = function["description"] as? String ?? ""
                if !description.isEmpty {
                    total += estimatedText("\(name)\(description)")
                }
                if let parameters = function["parameters"] {
                    total += estimatedSerialized(parameters)
                }
            } else {
                let name = tool["name"] as? String ?? ""
                let description = tool["description"] as? String ?? ""
                if !description.isEmpty {
                    total += estimatedText("\(name)\(description)")
                }
                if let inputSchema = tool["input_schema"] {
                    total += estimatedSerialized(inputSchema)
                }
            }
            return total
        }
    }

    private static func estimatedValue(_ value: Any?) -> Int {
        guard let value else { return 0 }
        if let text = value as? String {
            return estimatedText(text)
        }
        if let parts = value as? [[String: Any]] {
            return parts.reduce(0) { partial, part in
                if part["type"] as? String == "image_url" {
                    return partial + multimediaTokens
                }
                return partial + estimatedValue(part["text"]) + estimatedValue(part["image_url"])
            }
        }
        return estimatedSerialized(value)
    }

    private static func estimatedText(_ text: String) -> Int {
        max(1, text.count / 4)
    }

    private static func estimatedSerialized(_ value: Any) -> Int {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else {
            return estimatedText(String(describing: value))
        }
        return max(1, data.count / 4)
    }

    private static func hasWebSearchTool(_ tools: [[String: Any]]) -> Bool {
        tools.contains { tool in
            guard let type = tool["type"] as? String else { return false }
            return type.hasPrefix("web_search")
        }
    }

    private static func isEnabled(_ rawValue: String?) -> Bool {
        let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == "true" || value == "1" || value == "yes"
    }

    private static func mainEntryID(values: [String: String]) -> String? {
        let candidates = [
            values["agent.model"]?.nilIfBlank,
            values["agents.main.model"]?.nilIfBlank,
            "default",
        ]
        guard let entryID = candidates.compactMap({ $0 }).first(where: { NativeConfigService.validEntryID($0, values: values) != nil }) else {
            return nil
        }
        return entryID
    }

    private static func routeEntryID(_ route: String, values: [String: String]) -> String? {
        let candidates = [
            values["router.scenarios.\(route)"]?.nilIfBlank,
            values["router.routes.\(route).model"]?.nilIfBlank,
            values["router.\(route)"]?.nilIfBlank,
        ]
        guard let entryID = candidates.compactMap({ $0 }).first(where: { NativeConfigService.validEntryID($0, values: values) != nil }) else {
            return nil
        }
        return entryID
    }

    private static func longContextThreshold(values: [String: String]) -> Int {
        values["router.routes.longContextThreshold"].flatMap(Int.init)
            ?? values["router.longContextThreshold"].flatMap(Int.init)
            ?? 60_000
    }
}

enum AlwaysOnBackgroundTranscriptLoader {
    static func makeSession(
        target: AlwaysOnSessionTarget,
        existing: ProjectSession?,
        now: Date = Date()
    ) -> ProjectSession? {
        guard target.kind == .background,
              let parentSessionId = target.parentSessionId?.nilIfBlank,
              let relativeTranscriptPath = target.relativeTranscriptPath?.nilIfBlank else {
            return nil
        }
        let title = firstNonBlank(target.title, target.summary, existing?.title) ?? "Background task"
        let summary = firstNonBlank(target.summary, existing?.summary, target.title) ?? title
        var session = existing ?? ProjectSession(
            id: target.sessionId,
            provider: .pilotDeck,
            title: title,
            summary: summary,
            createdAt: target.lastActivity ?? now,
            updatedAt: target.lastActivity,
            lastActivity: target.lastActivity,
            lastConversationAt: nil,
            state: .idle
        )
        session.id = target.sessionId
        session.provider = existing?.provider ?? .pilotDeck
        session.title = title
        session.summary = summary
        session.updatedAt = target.lastActivity ?? session.updatedAt
        session.lastActivity = target.lastActivity ?? session.lastActivity
        session.sessionKind = .backgroundTask
        session.parentSessionId = parentSessionId
        session.relativeTranscriptPath = relativeTranscriptPath
        session.transcriptKey = firstNonBlank(target.transcriptKey, existing?.transcriptKey)
            ?? URL(fileURLWithPath: relativeTranscriptPath).lastPathComponent
        session.taskId = firstNonBlank(target.taskId, existing?.taskId)
        session.taskStatus = firstNonBlank(target.taskStatus, existing?.taskStatus)
        session.outputFile = firstNonBlank(target.outputFile, existing?.outputFile)
        session.isReadOnly = true
        return session
    }

    static func makePersistedSession(target: AlwaysOnSessionTarget) -> ProjectSession? {
        let sessionId = target.sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard target.kind == .origin,
              sessionId.hasPrefix("always-on-"),
              let paths = try? AppPaths.current() else {
            return nil
        }
        let url = paths.sessions.appendingPathComponent("\(sessionId).json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let messages = (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode([ChatMessage].self, from: $0) } ?? []
        let createdAt = messages.first?.createdAt ?? target.lastActivity ?? Date()
        let lastActivity = messages.last?.createdAt ?? target.lastActivity ?? createdAt
        let title = firstNonBlank(target.title, target.summary) ?? "Always-On run"
        let summary = firstNonBlank(target.summary, target.taskId, target.taskStatus) ?? title
        return ProjectSession(
            id: sessionId,
            provider: .pilotDeck,
            title: title,
            summary: summary,
            createdAt: createdAt,
            updatedAt: lastActivity,
            lastActivity: lastActivity,
            lastConversationAt: lastActivity,
            state: .idle,
            messageCount: messages.isEmpty ? nil : messages.count,
            sessionKind: .backgroundTask,
            taskId: target.taskId,
            taskStatus: target.taskStatus,
            outputFile: target.outputFile,
            isReadOnly: true
        )
    }

    static func messages(
        for session: ProjectSession,
        projectName: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [ChatMessage] {
        guard let parentSessionId = session.parentSessionId,
              let relativeTranscriptPath = session.relativeTranscriptPath,
              let url = transcriptURL(
                projectName: projectName,
                parentSessionId: parentSessionId,
                relativeTranscriptPath: relativeTranscriptPath,
                home: home
              ),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        let messages = text
            .split(whereSeparator: \.isNewline)
            .compactMap { jsonObject(from: String($0)) }
            .flatMap { normalizeEntry($0, session: session) }
        return messages.sorted { $0.createdAt < $1.createdAt }
    }

    static func transcriptURL(
        projectName: String,
        parentSessionId: String,
        relativeTranscriptPath: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        let parent = parentSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        let relative = relativeTranscriptPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !projectName.isEmpty, !parent.isEmpty, !relative.isEmpty else { return nil }

        let projectDirs = [".pilotdeck"].map { directory in
            home
                .appendingPathComponent(directory, isDirectory: true)
                .appendingPathComponent("projects", isDirectory: true)
                .appendingPathComponent(projectName, isDirectory: true)
                .standardizedFileURL
        }
        for projectDir in projectDirs {
            let allowedDir = projectDir
                .appendingPathComponent(parent, isDirectory: true)
                .appendingPathComponent("subagents", isDirectory: true)
                .standardizedFileURL
            let requestedPath = (projectDir.path as NSString).appendingPathComponent(relative)
            let requested = URL(fileURLWithPath: requestedPath).standardizedFileURL

            if requested.path.hasPrefix(allowedDir.path + "/"),
               isCronTranscriptFilename(requested.lastPathComponent),
               fileManager.fileExists(atPath: requested.path) {
                return requested
            }
        }
        return nil
    }

    static func backgroundSessionID(parentSessionId: String, transcriptFilename: String) -> String {
        "background-\(safeSessionIDComponent(parentSessionId))-\(safeSessionIDComponent(deletingJSONLExtension(transcriptFilename)))"
    }

    static func isCronTranscriptFilename(_ fileName: String) -> Bool {
        let lower = fileName.lowercased()
        return lower.hasPrefix("agent-cron") && lower.hasSuffix(".jsonl") && !fileName.contains("/")
    }

    private static func normalizeEntry(_ raw: [String: Any], session: ProjectSession) -> [ChatMessage] {
        let message = raw["message"] as? [String: Any]
        let role = (message?["role"] as? String) ?? (raw["role"] as? String)
        let createdAt = date(raw["timestamp"]) ?? date(message?["timestamp"]) ?? Date()

        if role == "user" {
            let text = textContent(message?["content"] ?? raw["content"])
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [
                chatMessage(session: session, role: .user, blocks: [.text(text)], createdAt: createdAt),
            ]
        }

        if role == "assistant" || raw["type"] as? String == "assistant" {
            if bool(raw["isApiErrorMessage"]) == true {
                let text = textContent(message?["content"] ?? raw["content"])
                return [chatMessage(session: session, role: .assistant, blocks: [.text(text.nilIfBlank ?? formatAPIError(raw))], createdAt: createdAt)]
            }
            if message?["model"] as? String == "<synthetic>" {
                return []
            }
            let blocks = assistantBlocks(from: message?["content"] ?? raw["content"])
            return blocks.isEmpty ? [] : [
                chatMessage(session: session, role: .assistant, blocks: blocks, createdAt: createdAt),
            ]
        }

        switch raw["type"] as? String {
        case "system" where raw["subtype"] as? String == "api_error":
            return [chatMessage(session: session, role: .system, blocks: [.text(formatAPIError(raw))], createdAt: createdAt)]
        case "thinking", "redacted_thinking", "reasoning":
            let text = textContent(raw["thinking"] ?? raw["text"] ?? raw["content"])
            return text.nilIfBlank.map {
                [chatMessage(session: session, role: .assistant, blocks: [.reasoning($0)], createdAt: createdAt)]
            } ?? []
        case "tool_use":
            return [chatMessage(session: session, role: .assistant, blocks: [toolCallBlock(raw)], createdAt: createdAt)]
        case "tool_result":
            return [chatMessage(session: session, role: .tool, blocks: [toolResultBlock(raw)], createdAt: createdAt)]
        case "error":
            let text = textContent(raw["error"]).nilIfBlank ?? textContent(raw["message"]).nilIfBlank ?? "Unknown provider error"
            return [chatMessage(session: session, role: .system, blocks: [.text(text)], createdAt: createdAt)]
        default:
            return []
        }
    }

    private static func assistantBlocks(from content: Any?) -> [ChatBlock] {
        if let parts = content as? [Any] {
            return parts.flatMap { part -> [ChatBlock] in
                guard let object = part as? [String: Any] else {
                    let text = textContent(part)
                    return text.nilIfBlank.map { [.text($0)] } ?? []
                }
                switch object["type"] as? String {
                case "tool_use":
                    return [toolCallBlock(object)]
                case "tool_result":
                    return [toolResultBlock(object)]
                case "thinking", "redacted_thinking", "reasoning":
                    let text = textContent(object["thinking"] ?? object["text"] ?? object["content"])
                    return text.nilIfBlank.map { [.reasoning($0)] } ?? []
                case "text", nil:
                    let text = textContent(object)
                    return text.nilIfBlank.map { [.text($0)] } ?? []
                default:
                    let text = textContent(object)
                    return text.nilIfBlank.map { [.text($0)] } ?? []
                }
            }
        }
        let text = textContent(content)
        return text.nilIfBlank.map { [.text($0)] } ?? []
    }

    private static func toolCallBlock(_ raw: [String: Any]) -> ChatBlock {
        .toolCall(ToolCall(
            id: string(raw["id"]) ?? string(raw["tool_use_id"]) ?? string(raw["toolId"]) ?? string(raw["toolCallId"]) ?? UUID().uuidString,
            name: string(raw["name"]) ?? string(raw["toolName"]) ?? "UnknownTool",
            inputJSON: jsonString(raw["input"] ?? raw["toolInput"]) ?? "{}",
            status: .completed
        ))
    }

    private static func toolResultBlock(_ raw: [String: Any]) -> ChatBlock {
        .toolResult(ToolResult(
            toolCallId: string(raw["tool_use_id"]) ?? string(raw["toolId"]) ?? string(raw["toolCallId"]) ?? "",
            output: textContent(raw["content"] ?? raw["output"]),
            isError: bool(raw["is_error"]) == true || bool(raw["isError"]) == true
        ))
    }

    private static func chatMessage(
        session: ProjectSession,
        role: ChatRole,
        blocks: [ChatBlock],
        createdAt: Date
    ) -> ChatMessage {
        ChatMessage(
            id: UUID(),
            sessionId: session.id,
            provider: session.provider,
            role: role,
            blocks: blocks,
            createdAt: createdAt,
            isStreaming: false,
            tokenBudget: nil
        )
    }

    private static func textContent(_ value: Any?) -> String {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        if let object = value as? [String: Any] {
            if let text = object["text"] as? String {
                return text
            }
            if let message = object["message"] as? String {
                return message
            }
            return jsonString(object) ?? ""
        }
        if let values = value as? [Any] {
            return values.map(textContent).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n")
        }
        return ""
    }

    private static func formatAPIError(_ raw: [String: Any]) -> String {
        if let cause = raw["cause"] as? [String: Any] {
            let code = string(cause["code"]) ?? "API Error"
            let path = string(cause["path"])
            return path.map { "\(code): \($0)" } ?? code
        }
        return textContent(raw["error"]).nilIfBlank ?? "API Error"
    }

    private static func jsonObject(from raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func jsonString(_ value: Any?) -> String? {
        guard let value,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String {
            return value
        }
        if let value = value as? NSNumber {
            return value.stringValue
        }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let string = value as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes", "on": return true
            case "false", "0", "no", "off": return false
            default: return nil
            }
        }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        if let value = value as? Date { return value }
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw)
        }
        guard let string = value as? String else { return nil }
        if let date = iso8601Date(from: string) {
            return date
        }
        return nil
    }

    private static func firstNonBlank(_ values: String?...) -> String? {
        values.compactMap { $0?.nilIfBlank }.first
    }

    private static func deletingJSONLExtension(_ value: String) -> String {
        value.lowercased().hasSuffix(".jsonl") ? String(value.dropLast(6)) : value
    }

    private static func safeSessionIDComponent(_ value: String) -> String {
        String(value.map { character in
            character.isLetter || character.isNumber || character == "." || character == "_" || character == "-"
                ? character
                : "-"
        })
    }

    private static func iso8601Date(from string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) {
            return date
        }
        return ISO8601DateFormatter().date(from: string)
    }
}

enum LegacyConfigLoader {
    static func loadDefaultConfig(
        url: URL = PilotDeckConfigPath.configURL()
    ) -> LegacyConfigSnapshot? {
        guard let native = NativeConfigService.loadDefaultConfig(url: url) else { return nil }
        return legacySnapshot(from: native)
    }

    static func snapshot(from yaml: String) -> LegacyConfigSnapshot? {
        guard let native = NativeConfigService.snapshot(from: yaml) else { return nil }
        return legacySnapshot(from: native)
    }

    static func scalarMap(from yaml: String) -> [String: String] {
        NativeConfigService.scalarMap(from: yaml)
    }

    private static func legacySnapshot(from native: NativeConfigSnapshot) -> LegacyConfigSnapshot {
        LegacyConfigSnapshot(
            baseURL: native.providerConfig.baseURL,
            model: native.providerConfig.model,
            apiKey: native.apiKey,
            workspacesRoot: native.workspacesRoot,
            generalWorkspacePath: native.generalWorkspacePath
        )
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var nilIfBlankOrConfigNull: String? {
        guard let trimmed = nilIfBlank else { return nil }
        return trimmed.lowercased() == "null" ? nil : trimmed
    }
}
