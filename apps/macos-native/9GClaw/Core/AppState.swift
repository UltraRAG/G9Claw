import Combine
import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var projects: [WorkspaceProject] = WorkspaceProject.sample()
    @Published var selectedProjectID: UUID?
    @Published var selectedSessionID: String?
    @Published var activeTab: AppTab = .chat
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
    @Published var apiKeyDraft = ""
    @Published var pendingPermissions: [PermissionRequest] = []
    @Published var terminalRuns: [TerminalRun] = []
    @Published var gitOutput = ""
    @Published var selectedFile: WorkspaceFile?
    @Published var selectedFileContent = ""
    @Published var statusLine = "Ready"
    @Published var errorBanner: String?
    @Published var showSettings = false
    @Published var showProjectCreationWizard = false
    @Published var settingsInitialTab: SettingsMainTab = .appearance
    @Published var edgeClawConfigText = ""
    @Published var settingsSaveNotice: String?
    @Published var toolRefreshRevision = 0

    let keychain = KeychainStore()
    let settingsStore = AppSettingsStore()
    let providerClient = NativeAgentRuntime()
    let workspaceService = WorkspaceService()
    let gitService = GitService()
    let terminalService = TerminalService()
    let taskService = TaskService()
    let memoryService = MemoryService()
    let skillsService = SkillsService()
    let routingService = RoutingService()
    let alwaysOnService = AlwaysOnService()

    private var activeAgentTask: Task<Void, Never>?
    private var activeRunToken: UUID?
    private var activitySequence = 0
    private var permissionContinuations: [UUID: CheckedContinuation<AgentPermissionDecision, Never>] = [:]
    private var pendingAssistantDeltas: [UUID: String] = [:]
    private var assistantDeltaFlushTasks: [UUID: Task<Void, Never>] = [:]
    private var hasBootstrapped = false

    init() {
        selectedProjectID = projects.first?.id
        selectedSessionID = projects.first?.sessions.first?.id
        if let sessionID = selectedSessionID {
            messagesBySession[sessionID] = [
                ChatMessage(
                    id: UUID(),
                    sessionId: sessionID,
                    provider: .nineGClaw,
                    role: .assistant,
                    blocks: [.text("Native 9GClaw is running with the macOS parity shell. Configure a provider in Settings to start a real agent session.")],
                    createdAt: Date(),
                    isStreaming: false,
                    tokenBudget: nil
                )
            ]
        }
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
            if let storedSettings = try settingsStore.load() {
                settings = storedSettings
            }
            logBundleNetworkPolicy()
            try bootstrapLocalDebugConfigIfNeeded()
            loadEdgeClawConfigText()
            applyNativeConfigFromCurrentText()
            try seedDebugKeyFromEnvironmentIfPresent()
            apiKeyDraft = try keychain.readSecret(account: settings.providerConfig.secretAccount) ?? apiKeyDraft
            loadManualProjectsFromClaudeConfig()
            refreshNativeToolData()
            statusLine = t(.nativeInitialized)
        } catch {
            errorBanner = error.localizedDescription
            AppLog.write("bootstrap error: \(error.localizedDescription)")
        }
    }

    func refreshProjects() async {
        projects = WorkspaceService.sortedProjects(projects, order: settings.projectSortOrder)
        statusLine = t(.projectsRefreshed)
    }

    func bumpToolRefresh() {
        toolRefreshRevision += 1
    }

    func selectProject(_ project: WorkspaceProject) {
        selectedProjectID = project.id
        selectedSessionID = nil
        activeTab = .chat
        refreshNativeToolData()
    }

    func selectSession(_ session: ProjectSession) {
        selectedSessionID = session.id
        activeTab = .chat
        markSession(session.id, state: .idle)
        refreshNativeToolData()
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
        activeTab = .chat
        refreshNativeToolData()
    }

    func toggleComposerRunMode() {
        composerRunMode = composerRunMode == .agent ? .plan : .agent
    }

    @discardableResult
    func consumeComposerRunModeForSend() -> ChatRunMode {
        let runMode = composerRunMode
        if runMode == .plan {
            composerRunMode = .agent
        }
        return runMode
    }

    @discardableResult
    func createSessionForSelectedProject(title: String = "New Session") -> ProjectSession? {
        guard let projectIndex = selectedProjectIndex else { return nil }
        let session = ProjectSession(
            id: UUID().uuidString,
            provider: .nineGClaw,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New Session" : title,
            summary: "",
            createdAt: Date(),
            updatedAt: nil,
            lastActivity: nil,
            lastConversationAt: nil,
            state: .idle
        )
        projects[projectIndex].sessions.insert(session, at: 0)
        selectedSessionID = session.id
        messagesBySession[session.id] = []
        activeTab = .chat
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
        } catch {
            errorBanner = error.localizedDescription
        }
        selectProject(project)
        startNewSession()
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
        let userMessage = ChatMessage(
            id: UUID(),
            sessionId: sessionID,
            provider: .nineGClaw,
            role: .user,
            blocks: userBlocks,
            createdAt: Date(),
            isStreaming: false,
            tokenBudget: nil
        )
        append(userMessage)
        touchSessionConversation(sessionID)
        if let selectedProject, !prompt.isEmpty {
            _ = memoryService.upsert(
                name: "session-\(String(sessionID.prefix(8)))",
                summary: prompt,
                projectName: selectedProject.name
            )
        }
        activitiesBySession[sessionID] = [
            AgentActivity(
                id: "run-\(assistantID.uuidString)",
                sessionId: sessionID,
                title: t(.connecting),
                detail: t(.openingRemoteModelStream),
                phase: .status,
                state: .running,
                createdAt: Date(),
                updatedAt: Date(),
                anchorBlockID: assistantID.uuidString,
                sequence: nextActivitySequence()
            )
        ]

        let assistantMessage = ChatMessage(
            id: assistantID,
            sessionId: sessionID,
            provider: .nineGClaw,
            role: .assistant,
            blocks: [.text("")],
            createdAt: Date(),
            isStreaming: true,
            tokenBudget: nil
        )
        append(assistantMessage)
        markSession(sessionID, state: .processing)

        let nativeConfig = currentNativeConfigSnapshot()
        let providerConfig = nativeConfig?.providerConfig ?? settings.providerConfig
        let apiKey: String
        do {
            apiKey = try keychain.readSecret(account: providerConfig.secretAccount)
                ?? nativeConfig?.apiKey
                ?? apiKeyDraft
        } catch {
            handleAgentEvent(.error(error.localizedDescription), assistantID: assistantID)
            return
        }
        let basePrompt = agentPrompt(prompt: prompt, attachments: attachments)
        let memoryContext = memoryService.recallForTurn(
            prompt: basePrompt,
            projectName: selectedProject?.name,
            projectRoot: selectedWorkspaceContext?.rootPath
        )
        let promptWithMemory: String
        if memoryContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            promptWithMemory = basePrompt
        } else {
            promptWithMemory = """
            \(basePrompt)

            Relevant 9GClaw memory context:
            \(memoryContext)
            """
        }

        let request = AgentRequest(
            sessionId: sessionID,
            projectPath: effectiveSelectedWorkspacePath,
            prompt: promptWithMemory,
            attachments: attachments,
            providerConfig: providerConfig,
            apiKey: apiKey,
            priorMessages: historyBeforeSend,
            timeoutMs: nativeConfig?.apiTimeoutMs ?? settings.apiTimeoutMs,
            contextWindow: nativeConfig?.contextWindow ?? settings.contextWindow,
            permissionMode: composerPermissionMode,
            runMode: requestedRunMode,
            workspaceContext: selectedWorkspaceContext,
            toolSettings: settings.permissions,
            routerRoute: nativeConfig?.defaultEntryID ?? "default",
            permissionHandler: { [weak self] permission in
                guard let self else { return .deny }
                return await self.requestAgentPermission(permission)
            }
        )
        if let selectedProject {
            routingService.recordRequest(
                sessionID: sessionID,
                title: selectedSession?.displayTitle ?? promptTitle(from: prompt),
                projectName: selectedProject.displayName,
                model: providerConfig.model,
                route: request.routerRoute,
                tier: requestedRunMode == .plan ? "REASONING" : "COMPLEX"
            )
        }

        let runToken = UUID()
        activeRunToken = runToken
        activeAgentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var sawTerminalEvent = false
            do {
                for try await event in providerClient.stream(request: request) {
                    if event.isTerminal {
                        sawTerminalEvent = true
                    }
                    self.handleAgentEvent(event, assistantID: assistantID, runToken: runToken)
                }
                if !sawTerminalEvent {
                    self.handleAgentEvent(.complete(sessionId: sessionID), assistantID: assistantID, runToken: runToken)
                }
            } catch {
                self.handleAgentEvent(.error(error.localizedDescription), assistantID: assistantID, runToken: runToken)
            }
        }
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
        }
        statusLine = t(.stopGeneration)
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
            statusLine = "\(t(.rename)) \(nextName)"
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    func deleteProject(_ project: WorkspaceProject) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        let removed = projects.remove(at: index)
        for session in removed.allSessions {
            removeSessionArtifacts(session.id)
        }
        do {
            try removeManualProjectFromConfig(removed)
        } catch {
            errorBanner = error.localizedDescription
        }
        if selectedProjectID == removed.id {
            selectedProjectID = projects.first?.id
            selectedSessionID = nil
        }
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
        statusLine = "\(t(.rename)) \(nextTitle)"
    }

    func deleteSession(_ session: ProjectSession, in project: WorkspaceProject) {
        guard let projectIndex = projects.firstIndex(where: { $0.id == project.id }) else { return }
        removeSession(from: &projects[projectIndex].sessions, sessionID: session.id)
        removeSession(from: &projects[projectIndex].codexSessions, sessionID: session.id)
        removeSession(from: &projects[projectIndex].cursorSessions, sessionID: session.id)
        removeSession(from: &projects[projectIndex].geminiSessions, sessionID: session.id)
        removeSessionArtifacts(session.id)
        if selectedSessionID == session.id {
            selectedSessionID = nil
        }
        statusLine = "\(t(.delete)) \(session.displayTitle)"
        refreshNativeToolData()
    }

    func saveSettings() {
        do {
            if !apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try keychain.saveSecret(apiKeyDraft, account: settings.providerConfig.secretAccount)
            }
            try saveEdgeClawConfigTextIfChanged()
            applyNativeConfigFromCurrentText()
            try settingsStore.save(settings)
            refreshNativeToolData()
            settingsSaveNotice = t(.saved)
            statusLine = t(.settingsSaved)
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    func openSettings(_ tab: SettingsMainTab = .appearance) {
        settingsInitialTab = tab
        showSettings = true
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
        return settings.generalWorkspacePath
    }

    func effectiveWorkspacePath(for project: WorkspaceProject) -> String {
        if isGeneralProject(project) {
            return NSString(string: settings.generalWorkspacePath).expandingTildeInPath
        }
        return project.rootPath
    }

    func isGeneralProject(_ project: WorkspaceProject) -> Bool {
        project.name == "general" || project.displayName == "general"
    }

    func refreshNativeToolData() {
        guard let selectedProject else { return }
        let workspacePath = effectiveWorkspacePath(for: selectedProject)
        skillsService.refresh(projectPath: workspacePath, isGeneral: isGeneralProject(selectedProject))
        memoryService.loadWorkspaceRecords(projectRoot: workspacePath, projectName: selectedProject.name)
    }

    func addAllowedTool(_ tool: String) {
        addUnique(tool, to: \.allowedTools)
    }

    func addBlockedTool(_ tool: String) {
        addUnique(tool, to: \.disallowedTools)
    }

    func removeAllowedTool(_ tool: String) {
        settings.permissions.allowedTools.removeAll { $0 == tool }
        settings.permissions.lastUpdated = Date()
    }

    func removeBlockedTool(_ tool: String) {
        settings.permissions.disallowedTools.removeAll { $0 == tool }
        settings.permissions.lastUpdated = Date()
    }

    func exportPermissions(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let payload: [String: Any] = [
            "version": 1,
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "source": "edgeclaw",
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
        for item in allowed where !settings.permissions.allowedTools.contains(item) {
            settings.permissions.allowedTools.append(item)
        }
        for item in blocked where !settings.permissions.disallowedTools.contains(item) {
            settings.permissions.disallowedTools.append(item)
        }
        settings.permissions.lastUpdated = Date()
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

    func approvePermission(_ id: UUID, updatedInputJSON: String? = nil) {
        guard let request = pendingPermissions.first(where: { $0.id == id }) else { return }
        pendingPermissions.removeAll { $0.id == id }
        statusLine = t(.permissionAllowedFormat, request.toolName)
        permissionContinuations.removeValue(forKey: id)?.resume(returning: .allow(remember: false, updatedInputJSON: updatedInputJSON))
    }

    func denyPermission(_ id: UUID) {
        guard let request = pendingPermissions.first(where: { $0.id == id }) else { return }
        pendingPermissions.removeAll { $0.id == id }
        statusLine = t(.permissionDeniedFormat, request.toolName)
        permissionContinuations.removeValue(forKey: id)?.resume(returning: .deny)
    }

    private func applyNativeConfigFromCurrentText() {
        guard let native = NativeConfigService.snapshot(from: edgeClawConfigText) else { return }
        var updated = settings
        updated.providerConfig = native.providerConfig
        updated.apiTimeoutMs = native.apiTimeoutMs
        updated.contextWindow = native.contextWindow
        if let workspacesRoot = native.workspacesRoot,
           !workspacesRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated.workspacesRoot = NSString(string: workspacesRoot).expandingTildeInPath
        }
        if let generalWorkspacePath = native.generalWorkspacePath,
           !generalWorkspacePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated.generalWorkspacePath = NSString(string: generalWorkspacePath).expandingTildeInPath
        }
        settings = updated

        if apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let apiKey = native.apiKey,
           !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            apiKeyDraft = apiKey
            try? keychain.saveSecret(apiKey, account: settings.providerConfig.secretAccount)
        }
    }

    private func loadEdgeClawConfigText() {
        let url = Self.edgeClawConfigURL()
        edgeClawConfigText = (try? String(contentsOf: url, encoding: .utf8)) ?? Self.defaultEdgeClawConfigText()
    }

    private func currentNativeConfigSnapshot() -> NativeConfigSnapshot? {
        NativeConfigService.snapshot(from: edgeClawConfigText)
    }

    private func saveEdgeClawConfigTextIfChanged() throws {
        let url = Self.edgeClawConfigURL()
        let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard edgeClawConfigText != old else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try edgeClawConfigText.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func edgeClawConfigURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".edgeclaw", isDirectory: true)
            .appendingPathComponent("config.yaml")
    }

    private func bootstrapLocalDebugConfigIfNeeded() throws {
        let url = Self.edgeClawConfigURL()
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.defaultEdgeClawConfigText().write(to: url, atomically: true, encoding: .utf8)
    }

    private func seedDebugKeyFromEnvironmentIfPresent() throws {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["EDGECLAW_DEBUG_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return }
        try keychain.saveSecret(key, account: settings.providerConfig.secretAccount)
    }

    private func logBundleNetworkPolicy() {
        let ats = Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any]
        let arbitraryLoads = ats?["NSAllowsArbitraryLoads"] as? Bool ?? false
        let localNetworking = ats?["NSAllowsLocalNetworking"] as? Bool ?? false
        AppLog.write("bundle=\(Bundle.main.bundleIdentifier ?? "unknown") ats.arbitraryLoads=\(arbitraryLoads) ats.localNetworking=\(localNetworking)")
    }

    private func loadManualProjectsFromClaudeConfig() {
        guard let data = try? Data(contentsOf: Self.claudeProjectConfigURL()),
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
        let url = Self.claudeProjectConfigURL()
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
        let url = Self.claudeProjectConfigURL()
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

    private static func claudeProjectConfigURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("project-config.json")
    }

    private static func defaultEdgeClawConfigText() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return """
        version: 1
        runtime:
          host: 0.0.0.0
          serverPort: 3001
          vitePort: 5173
          proxyPort: 18080
          contextWindow: 160000
          apiTimeoutMs: 120000
          httpsProxy: ""
          databasePath: \(home)/.cloudcli/auth.db
          workspacesRoot: \(home)
        models:
          providers:
            edgeclaw:
              type: openai-chat
              baseUrl: http://58.57.119.12:52010/v1
              apiKey: ""
              transformer: null
              headers: {}
            edgeclaw_memory:
              type: openai-chat
              baseUrl: http://58.57.119.12:52010/v1
              apiKey: ""
              transformer: null
              headers: {}
            edgeclaw_router:
              type: openai-chat
              baseUrl: http://58.57.119.12:52010/v1
              apiKey: ""
              transformer: null
              headers: {}
            openrouter:
              type: openai-chat
              baseUrl: https://openrouter.ai/api/v1/chat/completions
              apiKey: ""
              transformer: null
              headers: {}
          entries:
            default:
              provider: edgeclaw
              name: qwen3.6-27b
              contextWindow: 160000
            memory:
              provider: edgeclaw_memory
              name: qwen3.6-27b
              contextWindow: 160000
            router_small:
              provider: edgeclaw_router
              name: qwen3.6-35b-a3b
              contextWindow: 160000
        agents:
          main:
            model: default
            params: {}
          subagents:
            default: inherit
            params: {}
        alwaysOn:
          discovery:
            trigger:
              enabled: false
              tickIntervalMinutes: 5
              cooldownMinutes: 60
              dailyBudget: 4
              heartbeatStaleSeconds: 90
              recentUserMsgMinutes: 5
              preferClient: webui
            projects: {}
        memory:
          enabled: true
          model: memory
          params: {}
          reasoningMode: answer_first
          autoIndexIntervalMinutes: 1
          autoDreamIntervalMinutes: 2
          captureStrategy: last_turn
          includeAssistant: true
          maxMessageChars: 6000
          heartbeatBatchSize: 30
        rag:
          enabled: true
          disableBuiltInWebTools: true
          localKnowledge:
            baseUrl: http://58.57.119.12:52010/v1
            apiKey: ""
            modelName: qwen3-embedding-0.6b
            databaseUrl: http://58.57.119.12:52008/search
            defaultTopK: 10
          glmWebSearch:
            baseUrl: https://api.z.ai/api/paas/v4/web_search
            apiKey: ""
            defaultTopK: 10
        router:
          enabled: true
          log: false
          host: 127.0.0.1
          port: 19080
          apiTimeoutMs: 120000
          routes:
            default:
              model: default
              params: {}
            background:
              model: router_small
              params: {}
            think:
              model: default
              params: {}
            longContext:
              model: default
              params: {}
            webSearch:
              model: default
              params: {}
            longContextThreshold: 60000
          tokenSaver:
            enabled: true
            judgeModel: router_small
            defaultTier: COMPLEX
            subagentPolicy: inherit
            tiers:
              SIMPLE:
                model: router_small
                description: Simple Q&A, file reads, greetings, small edits
              MEDIUM:
                model: router_small
                description: Moderate coding, single-file edits, explanations
              COMPLEX:
                model: default
                description: Multi-step coding, architecture, large refactors
              REASONING:
                model: default
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
            mainAgentModel: default
            skillPath: ~/.claude/prompts/auto-orchestrate.md
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
            modelPricing:
              edgeclaw,qwen3.6-27b:
                inputPer1M: 0.4
                outputPer1M: 3.2
              edgeclaw_memory,qwen3.6-27b:
                inputPer1M: 0.4
                outputPer1M: 3.2
              edgeclaw_router,qwen3.6-35b-a3b:
                inputPer1M: 0.2
                outputPer1M: 1.2
            savingsBaselineModel: edgeclaw,qwen3.6-27b
          fallback: {}
          httpsProxy: ""
          rewriteSystemPrompt: ""
          customRouterPath: ""
        gateway:
          enabled: false
          home: \(home)/.edgeclaw/gateway
          allowAllUsers: false
          allowedUsers: []
          groupSessionsPerUser: true
          threadSessionsPerUser: false
          unauthorizedDmBehavior: pair
          runtimePaths:
            sessionMetadata: ~/.claude/projects/.gateway/sessions.json
            userBindings: ~/.claude/projects/.gateway/user-projects.json
            generalCwd: \(home)/Claude/general
            generalJsonl: ~/.claude/projects/-Users-\(NSUserName())-Claude-general/*.jsonl
            boundProjectJsonl: ~/.claude/projects/<encoded-project>/*.jsonl
        """
    }

    private func promptTitle(from prompt: String) -> String {
        let line = prompt.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "New Session" }
        return String(trimmed.prefix(72))
    }

    private func addUnique(_ tool: String, to keyPath: WritableKeyPath<ToolPermissionSettings, [String]>) {
        let trimmed = tool.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !settings.permissions[keyPath: keyPath].contains(trimmed) {
            settings.permissions[keyPath: keyPath].append(trimmed)
            settings.permissions.lastUpdated = Date()
        }
    }

    private var selectedProjectIndex: Int? {
        guard let selectedProjectID else { return nil }
        return projects.firstIndex(where: { $0.id == selectedProjectID })
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
        guard let paths = try? AppPaths.current() else { return }
        try? FileManager.default.removeItem(at: paths.sessions.appendingPathComponent("\(sessionID).json"))
    }

    private func append(_ message: ChatMessage) {
        var messages = messagesBySession[message.sessionId] ?? []
        messages.append(message)
        messagesBySession[message.sessionId] = messages
    }

    private func handleAgentEvent(_ event: AgentEvent, assistantID: UUID, runToken: UUID? = nil) {
        if let runToken, activeRunToken != runToken {
            return
        }
        switch event {
        case .turnStarted(let turn):
            upsertTurn(turn)
        case .turnItemStarted(let item), .turnItemUpdated(let item), .turnItemCompleted(let item):
            upsertTurnItem(item)
        case .turnCompleted(let turn):
            upsertTurn(turn)
        case .sessionCreated(let sessionId):
            statusLine = t(.sessionStartedFormat, sessionId)
        case .contentDelta(let text):
            queueAssistantDelta(text, assistantID: assistantID)
        case .toolUse(let id, let name, let inputJSON):
            flushPendingAssistantDelta(assistantID: assistantID)
            upsertActivity(
                id: id,
                title: t(.runningToolFormat, name),
                detail: inputJSON,
                phase: activityPhase(for: name),
                state: .running,
                toolName: name,
                detailMessages: [inputJSON],
                expandedDefault: false,
                anchorBlockID: assistantID.uuidString
            )
            appendAssistantBlock(.toolCall(ToolCall(id: id, name: name, inputJSON: inputJSON, status: .pending)), assistantID: assistantID)
        case .toolResult(let id, let output, let isError):
            flushPendingAssistantDelta(assistantID: assistantID)
            updateActivity(id: id, state: isError ? .failed : .completed, detail: output)
            appendAssistantBlock(.toolResult(ToolResult(toolCallId: id, output: output, isError: isError)), assistantID: assistantID)
        case .permissionRequest(let request):
            upsertActivity(
                id: "permission-\(request.id.uuidString)",
                title: request.reason,
                detail: request.inputJSON,
                phase: activityPhase(for: request.toolName),
                state: .running,
                toolName: request.toolName,
                detailMessages: [request.inputJSON],
                expandedDefault: request.kind == .askUserQuestion,
                anchorBlockID: assistantID.uuidString
            )
        case .status(let status):
            statusLine = status
            upsertActivity(
                id: statusActivityID(status, assistantID: assistantID),
                title: statusTitle(status),
                detail: statusDetail(status),
                phase: .status,
                state: .running,
                anchorBlockID: assistantID.uuidString
            )
        case .tokenBudget(let used, let total):
            updateTokenBudget(TokenBudget(used: used, total: total), assistantID: assistantID)
            if let selectedSessionID, let selectedProject {
                routingService.recordTokens(
                    sessionID: selectedSessionID,
                    title: selectedSession?.displayTitle ?? "New Session",
                    projectName: selectedProject.displayName,
                    model: settings.providerConfig.model,
                    totalTokens: used,
                    contextWindow: total
                )
            }
        case .streamEnd:
            flushPendingAssistantDelta(assistantID: assistantID)
            if let selectedSessionID {
                finishStreamingMessage(sessionID: selectedSessionID)
                completeRunningActivities(sessionID: selectedSessionID, anchorBlockID: assistantID.uuidString)
            }
        case .complete(let sessionId):
            flushPendingAssistantDelta(assistantID: assistantID)
            finishStreamingMessage(sessionID: sessionId)
            markSession(sessionId, state: .idle)
            touchSessionConversation(sessionId)
            completeRunningActivities(sessionID: sessionId, anchorBlockID: assistantID.uuidString)
            statusLine = t(.complete)
            finalizeAgentRun(runToken: runToken)
        case .aborted(let sessionId):
            flushPendingAssistantDelta(assistantID: assistantID)
            finishStreamingMessage(sessionID: sessionId)
            markSession(sessionId, state: .idle)
            cancelRunningActivities(sessionID: sessionId, anchorBlockID: assistantID.uuidString)
            statusLine = t(.aborted)
            finalizeAgentRun(runToken: runToken)
        case .error(let message):
            flushPendingAssistantDelta(assistantID: assistantID)
            appendAssistantDelta("\n\(message)", assistantID: assistantID)
            if let selectedSessionID {
                markSession(selectedSessionID, state: .failed)
                touchSessionConversation(selectedSessionID)
                finishStreamingMessage(sessionID: selectedSessionID)
                failRunningActivities(sessionID: selectedSessionID, message: message, anchorBlockID: assistantID.uuidString)
            }
            errorBanner = message
            finalizeAgentRun(runToken: runToken)
        }
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

    private func appendAssistantDelta(_ text: String, assistantID: UUID) {
        guard let selectedSessionID,
              var messages = messagesBySession[selectedSessionID],
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
        messagesBySession[selectedSessionID] = messages
    }

    private func appendAssistantBlock(_ block: ChatBlock, assistantID: UUID) {
        guard let selectedSessionID,
              var messages = messagesBySession[selectedSessionID],
              let index = messages.firstIndex(where: { $0.id == assistantID }) else { return }
        messages[index].blocks.append(block)
        messagesBySession[selectedSessionID] = messages
    }

    private func updateTokenBudget(_ budget: TokenBudget, assistantID: UUID) {
        guard let selectedSessionID,
              var messages = messagesBySession[selectedSessionID],
              let index = messages.firstIndex(where: { $0.id == assistantID }) else { return }
        messages[index].tokenBudget = budget
        messagesBySession[selectedSessionID] = messages
    }

    private func finishStreamingMessage(sessionID: String) {
        guard var messages = messagesBySession[sessionID] else { return }
        for index in messages.indices where messages[index].isStreaming {
            messages[index].isStreaming = false
        }
        messagesBySession[sessionID] = messages
        persistSessionMessages(sessionID: sessionID)
    }

    private func markSession(_ sessionId: String, state: SessionState) {
        for projectIndex in projects.indices {
            updateSessionState(in: &projects[projectIndex].sessions, sessionId: sessionId, state: state)
            updateSessionState(in: &projects[projectIndex].codexSessions, sessionId: sessionId, state: state)
            updateSessionState(in: &projects[projectIndex].cursorSessions, sessionId: sessionId, state: state)
            updateSessionState(in: &projects[projectIndex].geminiSessions, sessionId: sessionId, state: state)
        }
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
        anchorBlockID: String? = nil
    ) {
        guard let selectedSessionID else { return }
        var activities = activitiesBySession[selectedSessionID] ?? []
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
                    sessionId: selectedSessionID,
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
        activitiesBySession[selectedSessionID] = activities
    }

    private func nextActivitySequence() -> Int {
        activitySequence += 1
        return activitySequence
    }

    private func updateActivity(id: String, state: AgentActivityState, detail: String) {
        guard let selectedSessionID,
              var activities = activitiesBySession[selectedSessionID],
              let index = activities.firstIndex(where: { $0.id == id }) else { return }
        activities[index].state = state
        activities[index].detail = detail
        if !detail.isEmpty {
            activities[index].detailMessages.append(detail)
        }
        if state != .running {
            activities[index].endedAt = Date()
        }
        activities[index].updatedAt = Date()
        activitiesBySession[selectedSessionID] = activities
    }

    private func completeRunningActivities(sessionID: String, anchorBlockID: String? = nil) {
        guard var activities = activitiesBySession[sessionID] else { return }
        for index in activities.indices where activities[index].state == .running && activityMatchesAnchor(activities[index], anchorBlockID: anchorBlockID) {
            activities[index].state = .completed
            activities[index].endedAt = Date()
            activities[index].updatedAt = Date()
        }
        activitiesBySession[sessionID] = activities
    }

    private func cancelRunningActivities(sessionID: String, anchorBlockID: String? = nil) {
        guard var activities = activitiesBySession[sessionID] else { return }
        for index in activities.indices where activities[index].state == .running && activityMatchesAnchor(activities[index], anchorBlockID: anchorBlockID) {
            activities[index].state = .cancelled
            activities[index].endedAt = Date()
            activities[index].updatedAt = Date()
        }
        activitiesBySession[sessionID] = activities
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
    }

    private func activityMatchesAnchor(_ activity: AgentActivity, anchorBlockID: String?) -> Bool {
        guard let anchorBlockID else { return true }
        return activity.anchorBlockID == anchorBlockID
    }

    private func resolveAllPendingPermissions(decision: AgentPermissionDecision) {
        let ids = pendingPermissions.map(\.id)
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

    private func statusTitle(_ status: String) -> String {
        switch status.lowercased() {
        case "connecting": return t(.connecting)
        case "streaming": return t(.receivingResponse)
        case "thinking", "processing": return t(.working)
        case "continuing": return settings.language.resolved() == .chineseSimplified ? "正在继续" : "Continuing"
        case "executing plan": return settings.language.resolved() == .chineseSimplified ? "正在执行计划" : "Executing plan"
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
        case "thinking", "processing": return t(.agentStatusUpdate)
        case "continuing": return settings.language.resolved() == .chineseSimplified ? "模型还没有完成任务，正在推进下一步。" : "The model has not completed the task yet, continuing the next step."
        case "executing plan": return settings.language.resolved() == .chineseSimplified ? "计划已确认，正在切换到执行。" : "The plan was approved; switching to implementation."
        case "waiting for permission": return "Approve or deny the requested tool action."
        default: return t(.agentStatusUpdate)
        }
    }

    private func activityPhase(for toolName: String) -> AgentActivityPhase {
        let lower = toolName.lowercased()
        if lower.contains("grep") || lower.contains("glob") || lower.contains("search") || lower.contains("rag") {
            return .search
        }
        if lower.contains("bash") || lower.contains("shell") || lower.contains("command") || lower.contains("exec") {
            return .command
        }
        if lower.contains("edit") || lower.contains("write") || lower.contains("patch") || lower.contains("create") {
            return .edit
        }
        if lower == "task" || lower.contains("agent") {
            return .subagent
        }
        return .tool
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
            normalized == "waiting for permission" {
            return "status-\(assistantID.uuidString)-\(normalized.replacingOccurrences(of: " ", with: "-"))"
        }
        if normalized.hasPrefix("reconnecting") || normalized.contains("重试") || normalized.contains("retry") {
            return "status-\(assistantID.uuidString)-reconnecting"
        }
        return "status-\(assistantID.uuidString)-\(UUID().uuidString)"
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
    var defaultEntryID: String
}

enum NativeConfigService {
    static func loadDefaultConfig(
        url: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".edgeclaw")
            .appendingPathComponent("config.yaml")
    ) -> NativeConfigSnapshot? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return snapshot(from: text)
    }

    static func snapshot(from yaml: String) -> NativeConfigSnapshot? {
        let values = scalarMap(from: yaml)
        let defaultEntry = values["router.routes.default.model"]?.nilIfBlank ?? "default"
        let entryID = values["models.entries.\(defaultEntry).provider"] == nil ? "default" : defaultEntry
        guard let providerConfig = providerConfig(entryID: entryID, values: values) else { return nil }
        let apiKey = values["models.providers.\(values["models.entries.\(entryID).provider"] ?? "edgeclaw").apiKey"]
        let workspacesRoot = values["runtime.workspacesRoot"]
        let generalWorkspacePath = values["gateway.runtimePaths.generalCwd"]
        let apiTimeoutMs = values["runtime.apiTimeoutMs"].flatMap(Int.init)
            ?? values["router.apiTimeoutMs"].flatMap(Int.init)
            ?? 120_000
        let contextWindow = values["models.entries.\(entryID).contextWindow"].flatMap(Int.init)
            ?? values["runtime.contextWindow"].flatMap(Int.init)
            ?? 160_000

        return NativeConfigSnapshot(
            providerConfig: providerConfig,
            apiKey: apiKey,
            workspacesRoot: workspacesRoot,
            generalWorkspacePath: generalWorkspacePath,
            apiTimeoutMs: apiTimeoutMs,
            contextWindow: contextWindow,
            defaultEntryID: entryID
        )
    }

    static func scalarMap(from yaml: String) -> [String: String] {
        var result: [String: String] = [:]
        var stack: [(indent: Int, key: String)] = []

        for rawLine in yaml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
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
            if rawValue.isEmpty {
                stack.append((indent, key))
                continue
            }
            let path = (stack.map(\.key) + [key]).joined(separator: ".")
            result[path] = normalizeScalar(rawValue)
        }

        return result
    }

    private static func providerConfig(entryID: String, values: [String: String]) -> ProviderConfig? {
        let providerID = values["models.entries.\(entryID).provider"] ?? "edgeclaw"
        let baseURL = values["models.providers.\(providerID).baseUrl"] ?? ""
        let model = values["models.entries.\(entryID).name"] ?? ""
        guard !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let type = values["models.providers.\(providerID).type"] ?? "openai-chat"
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
            provider: .nineGClaw,
            apiType: apiType,
            baseURL: baseURL,
            model: model,
            secretAccount: providerID == "edgeclaw" ? ProviderConfig.empty.secretAccount : "9gclaw-provider-\(providerID)-api-key",
            headers: headers
        )
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

enum LegacyConfigLoader {
    static func loadDefaultConfig(
        url: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".edgeclaw")
            .appendingPathComponent("config.yaml")
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
}
