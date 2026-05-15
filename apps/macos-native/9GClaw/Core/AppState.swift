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
    @Published var composerText = ""
    @Published var settings = AppSettings.defaults
    @Published var apiKeyDraft = ""
    @Published var pendingPermissions: [PermissionRequest] = []
    @Published var terminalRuns: [TerminalRun] = []
    @Published var gitOutput = ""
    @Published var selectedFile: WorkspaceFile?
    @Published var selectedFileContent = ""
    @Published var statusLine = "Ready"
    @Published var errorBanner: String?

    let keychain = KeychainStore()
    let providerClient = ProviderClient()
    let workspaceService = WorkspaceService()
    let gitService = GitService()
    let terminalService = TerminalService()
    let taskService = TaskService()
    let memoryService = MemoryService()
    let skillsService = SkillsService()

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

    func bootstrap() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        do {
            _ = try AppPaths.current()
            apiKeyDraft = try keychain.readSecret(account: settings.providerConfig.secretAccount) ?? ""
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
        selectedSessionID = project.allSessions.first?.id
        activeTab = .chat
    }

    func selectSession(_ session: ProjectSession) {
        selectedSessionID = session.id
        activeTab = .chat
        markSession(session.id, state: .idle)
    }

    func startNewSession() {
        guard let projectIndex = selectedProjectIndex else { return }
        let session = ProjectSession(
            id: UUID().uuidString,
            provider: .nineGClaw,
            title: "New chat",
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
    }

    func createProject(name: String, path: String) {
        let validation = workspaceService.validateWorkspacePath(path)
        guard validation.valid, let resolved = validation.resolvedPath else {
            errorBanner = validation.error
            return
        }
        let project = WorkspaceProject(
            id: UUID(),
            name: name,
            displayName: name,
            rootPath: resolved,
            sessions: [],
            codexSessions: [],
            cursorSessions: [],
            geminiSessions: [],
            createdAt: Date(),
            lastActivity: Date()
        )
        projects.insert(project, at: 0)
        selectProject(project)
        startNewSession()
    }

    func sendComposerMessage() {
        let prompt = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        if selectedSessionID == nil {
            startNewSession()
        }
        guard let sessionID = selectedSessionID else { return }

        composerText = ""
        let userMessage = ChatMessage(
            id: UUID(),
            sessionId: sessionID,
            provider: .nineGClaw,
            role: .user,
            blocks: [.text(prompt)],
            createdAt: Date(),
            isStreaming: false,
            tokenBudget: nil
        )
        append(userMessage)

        let assistantID = UUID()
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

        let apiKey: String
        do {
            apiKey = try keychain.readSecret(account: settings.providerConfig.secretAccount) ?? apiKeyDraft
        } catch {
            handleAgentEvent(.error(error.localizedDescription), assistantID: assistantID)
            return
        }

        let request = AgentRequest(
            sessionId: sessionID,
            projectPath: selectedProject?.rootPath ?? FileManager.default.homeDirectoryForCurrentUser.path,
            prompt: prompt,
            providerConfig: settings.providerConfig,
            apiKey: apiKey,
            priorMessages: currentMessages
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
        let cwd = selectedProject.map { URL(fileURLWithPath: $0.rootPath) }
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
        let repo = URL(fileURLWithPath: selectedProject.rootPath)
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
        let repo = URL(fileURLWithPath: selectedProject.rootPath)
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
            statusLine = "Settings saved"
        } catch {
            errorBanner = error.localizedDescription
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
            appendAssistantBlock(.toolCall(ToolCall(id: id, name: name, inputJSON: inputJSON, status: .pending)), assistantID: assistantID)
        case .toolResult(let id, let output, let isError):
            appendAssistantBlock(.toolResult(ToolResult(toolCallId: id, output: output, isError: isError)), assistantID: assistantID)
        case .status(let status):
            statusLine = status
        case .tokenBudget(let used, let total):
            updateTokenBudget(TokenBudget(used: used, total: total), assistantID: assistantID)
        case .streamEnd:
            if let selectedSessionID {
                finishStreamingMessage(sessionID: selectedSessionID)
            }
        case .complete(let sessionId):
            markSession(sessionId, state: .idle)
            statusLine = "Complete"
        case .aborted(let sessionId):
            markSession(sessionId, state: .idle)
            statusLine = "Aborted"
        case .error(let message):
            appendAssistantDelta("\n\(message)", assistantID: assistantID)
            if let selectedSessionID {
                markSession(selectedSessionID, state: .failed)
                finishStreamingMessage(sessionID: selectedSessionID)
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
}
