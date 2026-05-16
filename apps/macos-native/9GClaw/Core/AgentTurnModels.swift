import Foundation

enum AgentTurnStatus: String, Codable, Hashable, Sendable {
    case inProgress
    case completed
    case interrupted
    case failed
}

enum TurnLifecycle: String, Codable, Hashable, Sendable {
    case idle
    case runningModel
    case runningTool
    case waitingApproval
    case waitingUserInput
    case retrying
    case completed
    case failed
    case cancelled
}

enum AgentTurnItemKind: String, Codable, Hashable, Sendable {
    case userMessage
    case agentMessage
    case reasoning
    case plan
    case commandExecution
    case fileChange
    case toolCall
    case toolResult
    case webSearch
    case contextCompaction
    case status
}

enum AgentTurnItemStatus: String, Codable, Hashable, Sendable {
    case pending
    case inProgress
    case completed
    case failed
    case declined
    case interrupted
}

struct CommandExecutionPayload: Codable, Hashable, Sendable {
    var command: String
    var cwd: String
    var stdout: String
    var stderr: String
    var exitCode: Int?
    var durationMs: Int?
}

struct FileChangePayload: Codable, Hashable, Sendable {
    var path: String
    var operation: String
    var additions: Int?
    var deletions: Int?
}

struct ToolInvocationPayload: Codable, Hashable, Sendable {
    var callId: String
    var toolName: String
    var inputJSON: String
    var output: String?
    var isError: Bool
}

struct WebSearchPayload: Codable, Hashable, Sendable {
    var query: String
    var resultCount: Int?
}

struct AgentTurnItem: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var sessionId: String
    var turnId: String
    var sequence: Int
    var kind: AgentTurnItemKind
    var status: AgentTurnItemStatus
    var title: String
    var text: String
    var toolName: String?
    var commandExecution: CommandExecutionPayload?
    var fileChange: FileChangePayload?
    var toolInvocation: ToolInvocationPayload?
    var webSearch: WebSearchPayload?
    var createdAt: Date
    var updatedAt: Date
    var completedAt: Date?

    var isRenderable: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            toolInvocation != nil ||
            commandExecution != nil ||
            fileChange != nil ||
            webSearch != nil
    }
}

struct AgentTurn: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var sessionId: String
    var runToken: UUID
    var workspacePath: String
    var status: AgentTurnStatus
    var mode: ChatRunMode
    var startedAt: Date
    var updatedAt: Date
    var completedAt: Date?
    var items: [AgentTurnItem]

    var hasPendingWork: Bool {
        status == .inProgress &&
            items.contains { $0.status == .pending || $0.status == .inProgress }
    }
}

struct AgentTurnStoreSnapshot: Codable, Hashable, Sendable {
    var sessionId: String
    var activeTurnId: String?
    var turns: [AgentTurn]
}
