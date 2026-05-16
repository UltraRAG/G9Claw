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

    let keychain = KeychainStore()
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

    var isCurrentSessionStreaming: Bool {
        currentMessages.contains { $0.isStreaming }
    }

    func bootstrap() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        do {
            _ = try AppPaths.current()
            logBundleNetworkPolicy()
            try bootstrapLocalDebugConfigIfNeeded()
            loadEdgeClawConfigText()
            applyNativeConfigFromCurrentText()
            try seedDebugKeyFromEnvironmentIfPresent()
            apiKeyDraft = try keychain.readSecret(account: settings.providerConfig.secretAccount) ?? apiKeyDraft
            loadManualProjectsFromClaudeConfig()
            refreshNativeToolData()
            statusLine = "Native macOS app initialized"
        } catch {
            errorBanner = error.localizedDescription
            AppLog.write("bootstrap error: \(error.localizedDescription)")
        }
    }

    func refreshProjects() async {
        projects = WorkspaceService.sortedProjects(projects, order: settings.projectSortOrder)
        statusLine = "Projects refreshed"
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
            lastActivity: Date(),
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
            errorBanner = "Workspace path does not exist."
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
            statusLine = "Project added"
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
        let historyBeforeSend = currentMessages

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
        activitiesBySession[sessionID] = [
            AgentActivity(
                id: "run-\(assistantID.uuidString)",
                sessionId: sessionID,
                title: "Processing",
                detail: "Connecting to provider",
                phase: .status,
                state: .running,
                createdAt: Date(),
                updatedAt: Date()
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

        let request = AgentRequest(
            sessionId: sessionID,
            projectPath: effectiveSelectedWorkspacePath,
            prompt: prompt.isEmpty ? "Review the attached files." : prompt,
            providerConfig: providerConfig,
            apiKey: apiKey,
            priorMessages: historyBeforeSend,
            timeoutMs: nativeConfig?.apiTimeoutMs ?? settings.apiTimeoutMs,
            contextWindow: nativeConfig?.contextWindow ?? settings.contextWindow,
            permissionMode: composerPermissionMode
        )

        activeAgentTask?.cancel()
        activeAgentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for try await event in providerClient.stream(request: request) {
                    self.handleAgentEvent(event, assistantID: assistantID)
                }
            } catch {
                self.handleAgentEvent(.error(error.localizedDescription), assistantID: assistantID)
            }
        }
    }

    func abortActiveRun() {
        activeAgentTask?.cancel()
        if let selectedSessionID {
            markSession(selectedSessionID, state: .idle)
            finishStreamingMessage(sessionID: selectedSessionID)
        }
        statusLine = "Generation stopped"
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

    func saveSettings() {
        do {
            if !apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try keychain.saveSecret(apiKeyDraft, account: settings.providerConfig.secretAccount)
            }
            try saveEdgeClawConfigTextIfChanged()
            applyNativeConfigFromCurrentText()
            refreshNativeToolData()
            settingsSaveNotice = "Saved"
            statusLine = "Settings saved"
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    func openSettings(_ tab: SettingsMainTab = .appearance) {
        settingsInitialTab = tab
        showSettings = true
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

    private func append(_ message: ChatMessage) {
        var messages = messagesBySession[message.sessionId] ?? []
        messages.append(message)
        messagesBySession[message.sessionId] = messages
    }

    private func handleAgentEvent(_ event: AgentEvent, assistantID: UUID) {
        switch event {
        case .sessionCreated(let sessionId):
            statusLine = "Session \(sessionId) started"
        case .contentDelta(let text):
            appendAssistantDelta(text, assistantID: assistantID)
        case .toolUse(let id, let name, let inputJSON):
            upsertActivity(
                id: id,
                title: "Running \(name)",
                detail: inputJSON,
                phase: activityPhase(for: name),
                state: .running
            )
            appendAssistantBlock(.toolCall(ToolCall(id: id, name: name, inputJSON: inputJSON, status: .pending)), assistantID: assistantID)
        case .toolResult(let id, let output, let isError):
            updateActivity(id: id, state: isError ? .failed : .completed, detail: output)
            appendAssistantBlock(.toolResult(ToolResult(toolCallId: id, output: output, isError: isError)), assistantID: assistantID)
        case .status(let status):
            statusLine = status
            upsertActivity(
                id: "status",
                title: statusTitle(status),
                detail: statusDetail(status),
                phase: .status,
                state: .running
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
            if let selectedSessionID {
                finishStreamingMessage(sessionID: selectedSessionID)
                completeRunningActivities(sessionID: selectedSessionID)
            }
        case .complete(let sessionId):
            markSession(sessionId, state: .idle)
            completeRunningActivities(sessionID: sessionId)
            statusLine = "Complete"
        case .aborted(let sessionId):
            markSession(sessionId, state: .idle)
            cancelRunningActivities(sessionID: sessionId)
            statusLine = "Aborted"
        case .error(let message):
            appendAssistantDelta("\n\(message)", assistantID: assistantID)
            if let selectedSessionID {
                markSession(selectedSessionID, state: .failed)
                finishStreamingMessage(sessionID: selectedSessionID)
                failRunningActivities(sessionID: selectedSessionID, message: message)
            }
            errorBanner = message
        }
    }

    private func appendAssistantDelta(_ text: String, assistantID: UUID) {
        guard let selectedSessionID,
              var messages = messagesBySession[selectedSessionID],
              let index = messages.firstIndex(where: { $0.id == assistantID }) else { return }
        var message = messages[index]
        if message.blocks.isEmpty {
            message.blocks = [.text(text)]
        } else if case .text(let existing) = message.blocks[0] {
            message.blocks[0] = .text(existing + text)
        } else {
            message.blocks.insert(.text(text), at: 0)
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
        sessions[index].lastActivity = Date()
    }

    private func upsertActivity(
        id: String,
        title: String,
        detail: String,
        phase: AgentActivityPhase,
        state: AgentActivityState
    ) {
        guard let selectedSessionID else { return }
        var activities = activitiesBySession[selectedSessionID] ?? []
        if let index = activities.firstIndex(where: { $0.id == id }) {
            activities[index].title = title
            activities[index].detail = detail
            activities[index].phase = phase
            activities[index].state = state
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
                    updatedAt: Date()
                )
            )
        }
        activitiesBySession[selectedSessionID] = activities
    }

    private func updateActivity(id: String, state: AgentActivityState, detail: String) {
        guard let selectedSessionID,
              var activities = activitiesBySession[selectedSessionID],
              let index = activities.firstIndex(where: { $0.id == id }) else { return }
        activities[index].state = state
        activities[index].detail = detail
        activities[index].updatedAt = Date()
        activitiesBySession[selectedSessionID] = activities
    }

    private func completeRunningActivities(sessionID: String) {
        guard var activities = activitiesBySession[sessionID] else { return }
        for index in activities.indices where activities[index].state == .running {
            activities[index].state = .completed
            activities[index].updatedAt = Date()
        }
        activitiesBySession[sessionID] = activities
    }

    private func cancelRunningActivities(sessionID: String) {
        guard var activities = activitiesBySession[sessionID] else { return }
        for index in activities.indices where activities[index].state == .running {
            activities[index].state = .cancelled
            activities[index].updatedAt = Date()
        }
        activitiesBySession[sessionID] = activities
    }

    private func failRunningActivities(sessionID: String, message: String) {
        guard var activities = activitiesBySession[sessionID] else { return }
        if activities.isEmpty {
            activities.append(
                AgentActivity(
                    id: "error-\(UUID().uuidString)",
                    sessionId: sessionID,
                    title: "Process failed",
                    detail: message,
                    phase: .status,
                    state: .failed,
                    createdAt: Date(),
                    updatedAt: Date()
                )
            )
        } else {
            for index in activities.indices where activities[index].state == .running {
                activities[index].state = .failed
                activities[index].detail = message
                activities[index].updatedAt = Date()
            }
        }
        activitiesBySession[sessionID] = activities
    }

    private func statusTitle(_ status: String) -> String {
        switch status.lowercased() {
        case "connecting": "Connecting"
        case "streaming": "Receiving response"
        default: status.isEmpty ? "Processing" : status.capitalized
        }
    }

    private func statusDetail(_ status: String) -> String {
        switch status.lowercased() {
        case "connecting": "Opening the remote model stream"
        case "streaming": "Streaming assistant output"
        default: "Agent status update"
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
