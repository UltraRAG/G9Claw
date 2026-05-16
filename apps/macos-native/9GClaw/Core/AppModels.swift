import Foundation
import SwiftUI

enum SessionProvider: String, CaseIterable, Codable, Identifiable {
    case claude
    case cursor
    case codex
    case gemini
    case nineGClaw = "9gclaw"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nineGClaw: "9GClaw"
        default: rawValue.capitalized
        }
    }

    var isNativeAvailable: Bool {
        self == .nineGClaw
    }
}

enum ChatRunMode: String, CaseIterable, Codable, Identifiable {
    case agent
    case plan

    var id: String { rawValue }

    var label: String {
        switch self {
        case .agent: "智能体"
        case .plan: "计划"
        }
    }

    var systemImage: String {
        switch self {
        case .agent: "sparkles"
        case .plan: "checklist"
        }
    }

    var detail: String {
        switch self {
        case .agent: "Run the agent with tools and streaming output."
        case .plan: "Ask the agent to produce a plan first."
        }
    }
}

enum ComposerPermissionMode: String, CaseIterable, Codable, Identifiable {
    case `default`
    case bypassPermissions

    var id: String { rawValue }

    var label: String {
        switch self {
        case .default: "Default permissions"
        case .bypassPermissions: "完全访问权限"
        }
    }

    var systemImage: String {
        switch self {
        case .default: "hand.raised"
        case .bypassPermissions: "shield.lefthalf.filled"
        }
    }

    var detail: String {
        switch self {
        case .default: "Ask before running tools that need approval."
        case .bypassPermissions: "Allow trusted tool actions for this run."
        }
    }
}

enum AppTab: Hashable, Identifiable {
    case chat
    case alwaysOn
    case files
    case shell
    case git
    case tasks
    case memory
    case skills
    case dashboard
    case preview
    case plugin(String)

    var id: String {
        switch self {
        case .chat: "chat"
        case .alwaysOn: "always-on"
        case .files: "files"
        case .shell: "shell"
        case .git: "git"
        case .tasks: "tasks"
        case .memory: "memory"
        case .skills: "skills"
        case .dashboard: "dashboard"
        case .preview: "preview"
        case .plugin(let name): "plugin:\(name)"
        }
    }

    var label: String {
        switch self {
        case .chat: "Agent"
        case .alwaysOn: "Always-on"
        case .files: "Files"
        case .shell: "Shell"
        case .git: "Git"
        case .tasks: "Tasks"
        case .memory: "Memory"
        case .skills: "Skills"
        case .dashboard: "Routing"
        case .preview: "Preview"
        case .plugin(let name): name
        }
    }

    var systemImage: String {
        switch self {
        case .chat: "message"
        case .alwaysOn: "dot.radiowaves.left.and.right"
        case .files: "folder"
        case .shell: "terminal"
        case .git: "arrow.triangle.branch"
        case .tasks: "checklist"
        case .memory: "externaldrive"
        case .skills: "sparkles"
        case .dashboard: "chart.bar"
        case .preview: "eye"
        case .plugin: "shippingbox"
        }
    }

    static let primaryTabs: [AppTab] = [
        .chat,
        .files,
        .skills,
        .dashboard,
        .memory,
        .alwaysOn,
    ]

    static let extendedTabs: [AppTab] = [
        .chat,
        .alwaysOn,
        .shell,
        .files,
        .git,
        .dashboard,
        .tasks,
        .memory,
        .skills,
    ]
}

enum SessionState: String, Codable {
    case idle
    case processing
    case unread
    case failed
}

struct WorkspaceProject: Identifiable, Hashable, Codable {
    var id: UUID
    var name: String
    var displayName: String
    var rootPath: String
    var sessions: [ProjectSession]
    var codexSessions: [ProjectSession]
    var cursorSessions: [ProjectSession]
    var geminiSessions: [ProjectSession]
    var createdAt: Date
    var lastActivity: Date?

    var allSessions: [ProjectSession] {
        (sessions + codexSessions + cursorSessions + geminiSessions)
            .sorted { $0.activityDate > $1.activityDate }
    }

    var latestActivity: Date {
        allSessions.map(\.activityDate).max() ?? lastActivity ?? createdAt
    }

    static func sample() -> [WorkspaceProject] {
        let now = Date()
        return [
            WorkspaceProject(
                id: UUID(),
                name: "general",
                displayName: "general",
                rootPath: FileManager.default.homeDirectoryForCurrentUser.path,
                sessions: [],
                codexSessions: [],
                cursorSessions: [],
                geminiSessions: [],
                createdAt: now.addingTimeInterval(-7200),
                lastActivity: now.addingTimeInterval(-600)
            )
        ]
    }
}

struct ProjectSession: Identifiable, Hashable, Codable {
    var id: String
    var provider: SessionProvider
    var title: String
    var summary: String
    var createdAt: Date
    var updatedAt: Date?
    var lastActivity: Date?
    var state: SessionState

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? id : trimmed
    }

    var activityDate: Date {
        lastActivity ?? updatedAt ?? createdAt
    }
}

enum ChatRole: String, Codable {
    case user
    case assistant
    case system
    case tool
}

enum ChatBlock: Hashable, Codable {
    case text(String)
    case toolCall(ToolCall)
    case toolResult(ToolResult)
    case attachment(FileAttachment)
}

struct ChatMessage: Identifiable, Hashable, Codable {
    var id: UUID
    var sessionId: String
    var provider: SessionProvider
    var role: ChatRole
    var blocks: [ChatBlock]
    var createdAt: Date
    var isStreaming: Bool
    var tokenBudget: TokenBudget?

    var plainText: String {
        blocks.compactMap {
            if case .text(let text) = $0 { return text }
            return nil
        }.joined()
    }
}

struct AgentActivity: Identifiable, Hashable, Codable {
    var id: String
    var sessionId: String
    var title: String
    var detail: String
    var phase: AgentActivityPhase
    var state: AgentActivityState
    var createdAt: Date
    var updatedAt: Date
}

enum AgentActivityPhase: String, Codable {
    case status
    case tool
    case search
    case command
    case edit
    case subagent
    case thinking
}

enum AgentActivityState: String, Codable {
    case running
    case completed
    case failed
    case cancelled
}

struct ToolCall: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var inputJSON: String
    var status: ToolCallStatus
}

enum ToolCallStatus: String, Codable {
    case pending
    case running
    case approved
    case denied
    case completed
    case failed
}

struct ToolResult: Hashable, Codable {
    var toolCallId: String
    var output: String
    var isError: Bool
}

struct FileAttachment: Identifiable, Hashable, Codable {
    var id: UUID
    var fileName: String
    var path: String
    var mimeType: String?
}

struct PermissionRequest: Identifiable, Hashable, Codable {
    var id: UUID
    var sessionId: String
    var toolName: String
    var inputJSON: String
    var reason: String
    var scope: PermissionScope
    var createdAt: Date
}

enum PermissionScope: String, Codable {
    case session
    case project
    case global
}

struct ProviderConfig: Hashable, Codable {
    var provider: SessionProvider
    var apiType: ProviderAPIType
    var baseURL: String
    var model: String
    var secretAccount: String
    var headers: [String: String]

    static let empty = ProviderConfig(
        provider: .nineGClaw,
        apiType: .openAIChat,
        baseURL: "",
        model: "",
        secretAccount: "9gclaw-provider-api-key",
        headers: [:]
    )
}

enum ProviderAPIType: String, Codable, CaseIterable, Identifiable {
    case openAIChat
    case openAIResponses
    case anthropicMessages

    var id: String { rawValue }
}

struct AppSettings: Hashable, Codable {
    var providerConfig: ProviderConfig
    var workspacesRoot: String
    var generalWorkspacePath: String
    var apiTimeoutMs: Int
    var contextWindow: Int
    var projectSortOrder: ProjectSortOrder
    var colorScheme: AppColorScheme
    var language: AppLanguage
    var codeEditor: CodeEditorPreferences
    var permissions: ToolPermissionSettings

    static let defaults = AppSettings(
        providerConfig: .empty,
        workspacesRoot: FileManager.default.homeDirectoryForCurrentUser.path,
        generalWorkspacePath: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Claude")
            .appendingPathComponent("general")
            .path,
        apiTimeoutMs: 120_000,
        contextWindow: 160_000,
        projectSortOrder: .name,
        colorScheme: .system,
        language: .system,
        codeEditor: .defaults,
        permissions: .defaults
    )
}

enum ProjectSortOrder: String, Codable, CaseIterable, Identifiable {
    case name
    case date

    var id: String { rawValue }
}

enum AppColorScheme: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }
}

enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case system
    case english
    case chineseSimplified

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .english: "English"
        case .chineseSimplified: "简体中文"
        }
    }
}

struct CodeEditorPreferences: Hashable, Codable {
    var wordWrap: Bool
    var showMinimap: Bool
    var lineNumbers: Bool
    var fontSize: Int

    static let defaults = CodeEditorPreferences(
        wordWrap: true,
        showMinimap: false,
        lineNumbers: false,
        fontSize: 13
    )
}

struct ToolPermissionSettings: Hashable, Codable {
    var allowedTools: [String]
    var disallowedTools: [String]
    var lastUpdated: Date?

    static let quickAllowedTools = [
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

    static let quickBlockedTools = [
        "Bash(rm:*)",
        "Bash(sudo:*)",
        "WebFetch",
        "WebSearch",
    ]

    static let defaults = ToolPermissionSettings(
        allowedTools: [],
        disallowedTools: [],
        lastUpdated: nil
    )
}

enum SettingsMainTab: String, CaseIterable, Identifiable {
    case appearance
    case permissions
    case config

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appearance: "Appearance"
        case .permissions: "Permissions"
        case .config: "Config"
        }
    }

    var systemImage: String {
        switch self {
        case .appearance: "paintpalette"
        case .permissions: "shield"
        case .config: "doc.badge.gearshape"
        }
    }
}

enum EdgeClawConfigSection: String, CaseIterable, Identifiable {
    case runtime
    case models
    case agents
    case alwaysOn
    case memory
    case rag
    case router
    case gateway
    case raw

    var id: String { rawValue }

    var label: String {
        switch self {
        case .runtime: "Runtime"
        case .models: "Models"
        case .agents: "Agents"
        case .alwaysOn: "Always-On"
        case .memory: "Memory"
        case .rag: "RAG"
        case .router: "Router"
        case .gateway: "Gateway"
        case .raw: "Raw YAML"
        }
    }
}

struct WorkspaceContext: Hashable, Codable {
    var projectID: UUID?
    var projectName: String
    var displayName: String
    var rootPath: String
    var isGeneral: Bool
}

struct TokenBudget: Hashable, Codable {
    var used: Int
    var total: Int
}

struct TaskPlan: Identifiable, Hashable, Codable {
    var id: UUID
    var title: String
    var prompt: String
    var status: TaskStatus
    var createdAt: Date
}

enum TaskStatus: String, Codable {
    case queued
    case running
    case completed
    case failed
}

struct MemoryRecord: Identifiable, Hashable, Codable {
    var id: UUID
    var name: String
    var summary: String
    var projectName: String?
    var updatedAt: Date
    var type: MemoryRecordType = .project
    var relativePath: String = ""
    var deprecated: Bool = false
}

enum MemoryRecordType: String, Codable, CaseIterable, Identifiable {
    case project
    case feedback
    case user
    case generalProjectMeta

    var id: String { rawValue }

    var label: String {
        switch self {
        case .project: "Project"
        case .feedback: "Feedback"
        case .user: "User"
        case .generalProjectMeta: "General Project"
        }
    }
}

struct MemoryDashboardSnapshot: Hashable, Codable {
    var totalEntries: Int
    var projectEntries: Int
    var feedbackEntries: Int
    var latestMemoryAt: Date?
    var records: [MemoryRecord]
    var userSummary: String
    var caseTraces: [String]
    var indexTraces: [String]
    var dreamTraces: [String]
}

enum SkillScope: String, Codable, CaseIterable, Identifiable {
    case user
    case project

    var id: String { rawValue }
}

struct SkillRecord: Identifiable, Hashable, Codable {
    var id: UUID
    var slug: String
    var name: String
    var description: String
    var version: String?
    var skillDir: String
    var skillFile: String
    var scope: SkillScope
    var mtime: Date?
    var enabled: Bool
}

struct SkillValidationIssue: Identifiable, Hashable, Codable {
    var id = UUID()
    var code: String
    var message: String
}

struct SkillValidationResult: Hashable, Codable {
    var ok: Bool
    var hardFails: [SkillValidationIssue]
    var warnings: [SkillValidationIssue]
    var fileCount: Int
    var totalBytes: Int
}

struct RoutingBucket: Hashable, Codable {
    var count: Int
    var inputTokens: Int
    var outputTokens: Int
    var estimatedCost: Double
}

struct RoutingDashboardSession: Identifiable, Hashable, Codable {
    var id: String
    var title: String
    var projectName: String
    var lastActiveAt: Date
    var totalTokens: Int
    var estimatedCost: Double
    var savedCost: Double
    var byTier: [String: RoutingBucket]
    var byModel: [String: RoutingBucket]
    var requestLog: [String]
}

struct RoutingDashboardSnapshot: Hashable, Codable {
    var totalProjects: Int
    var totalSessions: Int
    var routedSessions: Int
    var totalTokens: Int
    var estimatedCost: Double
    var savedCost: Double
    var recentSessions: [RoutingDashboardSession]
}

enum AlwaysOnStatus: String, Codable {
    case ready
    case queued
    case running
    case completed
    case failed
    case draft
    case superseded
    case unknown
}

struct AlwaysOnPlan: Identifiable, Hashable, Codable {
    var id: String
    var title: String
    var summary: String
    var rationale: String
    var content: String
    var status: AlwaysOnStatus
    var approvalMode: String
    var planFilePath: String
    var createdAt: Date
    var updatedAt: Date
    var executionSessionId: String?
    var executionStatus: AlwaysOnStatus?
}

struct AlwaysOnCronJob: Identifiable, Hashable, Codable {
    var id: String
    var prompt: String
    var cron: String
    var status: AlwaysOnStatus
    var recurring: Bool
    var durable: Bool
    var createdAt: Date?
    var lastFiredAt: Date?
    var latestSessionId: String?
}

struct AlwaysOnRunHistory: Identifiable, Hashable, Codable {
    var id: String
    var title: String
    var kind: String
    var status: AlwaysOnStatus
    var startedAt: Date
    var sourceId: String
    var outputLog: String
    var sessionId: String?
}
