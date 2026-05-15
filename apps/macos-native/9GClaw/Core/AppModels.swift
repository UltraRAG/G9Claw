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
        case .dashboard: "Dashboard"
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
                sessions: [
                    ProjectSession(
                        id: "welcome",
                        provider: .nineGClaw,
                        title: "Welcome session",
                        summary: "Native macOS parity workspace",
                        createdAt: now.addingTimeInterval(-3600),
                        updatedAt: now.addingTimeInterval(-600),
                        lastActivity: now.addingTimeInterval(-600),
                        state: .idle
                    )
                ],
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
    var projectSortOrder: ProjectSortOrder
    var colorScheme: AppColorScheme

    static let defaults = AppSettings(
        providerConfig: .empty,
        workspacesRoot: FileManager.default.homeDirectoryForCurrentUser.path,
        projectSortOrder: .name,
        colorScheme: .system
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
}

struct SkillRecord: Identifiable, Hashable, Codable {
    var id: UUID
    var name: String
    var description: String
    var enabled: Bool
}
