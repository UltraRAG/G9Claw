import Foundation
import SwiftUI

enum SessionProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case pilotDeck = "pilotdeck"
    case cursor
    case codex
    case gemini

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "pilotdeck":
            self = .pilotDeck
        default:
            self = SessionProvider(rawValue: rawValue) ?? .pilotDeck
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var displayName: String {
        switch self {
        case .pilotDeck: "PilotDeck"
        default: rawValue.capitalized
        }
    }

    var isNativeAvailable: Bool {
        self == .pilotDeck
    }
}

enum ProjectSessionKind: String, Codable {
    case backgroundTask = "background_task"
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

enum ComposerPermissionModeStorage {
    static let defaultKey = "permissionMode-default"
    static let sessionKeyPrefix = "permissionMode-"

    static func storedMode(for sessionID: String?, defaults: UserDefaults = .standard) -> ComposerPermissionMode {
        if let sessionID,
           let mode = mode(defaults.string(forKey: "\(sessionKeyPrefix)\(sessionID)")) {
            return mode
        }
        return mode(defaults.string(forKey: defaultKey)) ?? .default
    }

    static func save(_ mode: ComposerPermissionMode, for sessionID: String?, defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: defaultKey)
        if let sessionID {
            defaults.set(mode.rawValue, forKey: "\(sessionKeyPrefix)\(sessionID)")
        }
    }

    private static func mode(_ rawValue: String?) -> ComposerPermissionMode? {
        guard let rawValue else { return nil }
        return ComposerPermissionMode(rawValue: rawValue)
    }
}

struct NativeUIPreferences: Equatable {
    var autoExpandTools = false
    var showRawParameters = false
    var showThinking = true
    var autoScrollToBottom = true
    var sendByCtrlEnter = false
    var sidebarVisible = true
}

enum ToolRowExpansionPolicy {
    static func isExpanded(
        id: String,
        expandedIDs: Set<String>,
        collapsedIDs: Set<String>,
        autoExpandTools: Bool
    ) -> Bool {
        if collapsedIDs.contains(id) { return false }
        if expandedIDs.contains(id) { return true }
        return autoExpandTools
    }

    static func toggle(
        id: String,
        expandedIDs: inout Set<String>,
        collapsedIDs: inout Set<String>,
        autoExpandTools: Bool
    ) {
        if isExpanded(
            id: id,
            expandedIDs: expandedIDs,
            collapsedIDs: collapsedIDs,
            autoExpandTools: autoExpandTools
        ) {
            expandedIDs.remove(id)
            collapsedIDs.insert(id)
        } else {
            collapsedIDs.remove(id)
            expandedIDs.insert(id)
        }
    }
}

enum NativeUIPreferencesStorage {
    static let storageKey = "uiPreferences"

    static func storedPreferences(defaults: UserDefaults = .standard) -> NativeUIPreferences {
        if let raw = defaults.string(forKey: storageKey),
           let data = raw.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return preferences(from: object)
        }

        var preferences = NativeUIPreferences()
        preferences.autoExpandTools = boolValue(defaults.object(forKey: "autoExpandTools"), fallback: preferences.autoExpandTools)
        preferences.showRawParameters = boolValue(defaults.object(forKey: "showRawParameters"), fallback: preferences.showRawParameters)
        preferences.showThinking = boolValue(defaults.object(forKey: "showThinking"), fallback: preferences.showThinking)
        preferences.autoScrollToBottom = boolValue(defaults.object(forKey: "autoScrollToBottom"), fallback: preferences.autoScrollToBottom)
        preferences.sendByCtrlEnter = boolValue(defaults.object(forKey: "sendByCtrlEnter"), fallback: preferences.sendByCtrlEnter)
        preferences.sidebarVisible = boolValue(defaults.object(forKey: "sidebarVisible"), fallback: preferences.sidebarVisible)
        return preferences
    }

    static func saveSidebarVisible(_ visible: Bool, defaults: UserDefaults = .standard) {
        var preferences = storedPreferences(defaults: defaults)
        preferences.sidebarVisible = visible
        save(preferences, defaults: defaults)
    }

    static func save(_ preferences: NativeUIPreferences, defaults: UserDefaults = .standard) {
        let object: [String: Bool] = [
            "autoExpandTools": preferences.autoExpandTools,
            "showRawParameters": preferences.showRawParameters,
            "showThinking": preferences.showThinking,
            "autoScrollToBottom": preferences.autoScrollToBottom,
            "sendByCtrlEnter": preferences.sendByCtrlEnter,
            "sidebarVisible": preferences.sidebarVisible,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        defaults.set(text, forKey: storageKey)
    }

    private static func preferences(from object: [String: Any]) -> NativeUIPreferences {
        var preferences = NativeUIPreferences()
        preferences.autoExpandTools = boolValue(object["autoExpandTools"], fallback: preferences.autoExpandTools)
        preferences.showRawParameters = boolValue(object["showRawParameters"], fallback: preferences.showRawParameters)
        preferences.showThinking = boolValue(object["showThinking"], fallback: preferences.showThinking)
        preferences.autoScrollToBottom = boolValue(object["autoScrollToBottom"], fallback: preferences.autoScrollToBottom)
        preferences.sendByCtrlEnter = boolValue(object["sendByCtrlEnter"], fallback: preferences.sendByCtrlEnter)
        preferences.sidebarVisible = boolValue(object["sidebarVisible"], fallback: preferences.sidebarVisible)
        return preferences
    }

    private static func boolValue(_ value: Any?, fallback: Bool) -> Bool {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? String {
            if value == "true" { return true }
            if value == "false" { return false }
        }
        return fallback
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
    var lastConversationAt: Date? = nil
    var state: SessionState
    var messageCount: Int? = nil
    var sessionKind: ProjectSessionKind? = nil
    var parentSessionId: String? = nil
    var relativeTranscriptPath: String? = nil
    var transcriptKey: String? = nil
    var taskId: String? = nil
    var taskStatus: String? = nil
    var outputFile: String? = nil
    var isReadOnly: Bool? = nil

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? id : trimmed
    }

    var activityDate: Date {
        lastConversationAt ?? lastActivity ?? updatedAt ?? createdAt
    }

    var isBackgroundTaskSession: Bool {
        sessionKind == .backgroundTask &&
            parentSessionId?.isEmpty == false &&
            relativeTranscriptPath?.isEmpty == false
    }
}

enum ChatRole: String, Codable, Sendable {
    case user
    case assistant
    case system
    case tool
}

enum ChatBlock: Hashable, Codable, Sendable {
    case text(String)
    case reasoning(String)
    case toolCall(ToolCall)
    case toolResult(ToolResult)
    case attachment(FileAttachment)
    case processStatus(ProcessStatusBlock)
}

enum ChatBlockVisibilityPolicy {
    static func isVisible(_ block: ChatBlock, showThinking: Bool) -> Bool {
        switch block {
        case .reasoning:
            return showThinking
        case .text, .toolCall, .toolResult, .attachment, .processStatus:
            return true
        }
    }
}

enum ProcessStatusKind: String, Hashable, Codable, Sendable {
    case contextCompaction
    case contextRecovery
}

struct ProcessStatusBlock: Hashable, Codable, Sendable {
    var id: String
    var title: String
    var detail: String?
    var kind: ProcessStatusKind
}

struct ChatMessage: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var sessionId: String
    var provider: SessionProvider
    var role: ChatRole
    var blocks: [ChatBlock]
    var createdAt: Date
    var isStreaming: Bool
    var tokenBudget: TokenBudget?
    var runStartedAt: Date? = nil
    var runEndedAt: Date? = nil

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
    var runID: String? = nil
    var title: String
    var detail: String
    var phase: AgentActivityPhase
    var state: AgentActivityState
    var createdAt: Date
    var updatedAt: Date
    var toolName: String? = nil
    var detailMessages: [String] = []
    var expandedDefault: Bool = false
    var anchorBlockID: String? = nil
    var sequence: Int? = nil
    var endedAt: Date? = nil
    var summaryMetrics: [String: Int]? = nil
}

extension AgentActivity {
    var isMeaningfulProcessTrace: Bool {
        if toolName != nil { return true }
        if phase != .status { return true }
        if state == .failed || state == .cancelled { return true }
        let haystack = "\(title) \(detail)".lowercased()
        return haystack.contains("compact") ||
            haystack.contains("recover") ||
            haystack.contains("压缩") ||
            haystack.contains("恢复") ||
            haystack.contains("permission") ||
            haystack.contains("权限")
    }

    var shouldRenderInProcessTrace: Bool {
        isMeaningfulProcessTrace || (state == .running && phase == .status)
    }

    static func processTraceActivities(_ activities: [AgentActivity]) -> [AgentActivity] {
        activities
            .filter(\.shouldRenderInProcessTrace)
            .filter { activity in
                !activity.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    !activity.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    activity.toolName != nil
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    static func processTraceActivities(_ activities: [AgentActivity], anchoredTo anchorBlockID: String?) -> [AgentActivity] {
        guard let anchorBlockID else {
            return processTraceActivities(activities)
        }
        return processTraceActivities(activities.filter { $0.anchorBlockID == anchorBlockID })
    }

    static func runHeaderActivities(_ activities: [AgentActivity], anchoredTo anchorBlockID: String?) -> [AgentActivity] {
        let scoped = anchorBlockID.map { anchor in
            activities.filter { $0.anchorBlockID == anchor }
        } ?? activities
        return scoped
            .filter { activity in
                !activity.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    !activity.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    activity.toolName != nil
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    static func hasRenderableProcessTrace(_ activities: [AgentActivity]) -> Bool {
        !processTraceActivities(activities).isEmpty
    }
}

enum AgentActivityPresentationPolicy {
    static func expandsPermissionByDefault(_ kind: PermissionRequestKind) -> Bool {
        false
    }
}

enum AgentActivityPhase: String, Codable {
    case status
    case tool
    case search
    case command
    case edit
    case todo
    case subagent
    case thinking
}

enum AgentToolPresentationClassifier {
    static func phase(forToolName toolName: String) -> AgentActivityPhase {
        let canonical = AgentToolNameCanonicalizer.canonical(toolName).lowercased()
        if searchTools.contains(canonical) {
            return .search
        }
        if commandTools.contains(canonical) {
            return .command
        }
        if editTools.contains(canonical) {
            return .edit
        }
        if todoTools.contains(canonical) {
            return .todo
        }
        if subagentTools.contains(canonical) {
            return .subagent
        }
        return .tool
    }

    static func isReadTool(_ toolName: String) -> Bool {
        AgentToolNameCanonicalizer.canonical(toolName).lowercased() == "read"
    }

    static func isSearchTool(_ toolName: String) -> Bool {
        phase(forToolName: toolName) == .search
    }

    private static let searchTools: Set<String> = [
        "grep",
        "glob",
        "semanticsearch",
        "websearch",
        "webfetch",
    ]

    private static let commandTools: Set<String> = [
        "shell",
    ]

    private static let editTools: Set<String> = [
        "write",
        "strreplace",
        "delete",
        "editnotebook",
    ]

    private static let todoTools: Set<String> = [
        "todoread",
        "todowrite",
    ]

    private static let subagentTools: Set<String> = [
        "task",
    ]
}

enum AgentActivityState: String, Codable {
    case running
    case completed
    case failed
    case cancelled
}

struct ToolCall: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var name: String
    var inputJSON: String
    var status: ToolCallStatus
}

enum ToolCallStatus: String, Codable, Sendable {
    case pending
    case running
    case approved
    case denied
    case completed
    case failed
}

struct ToolResult: Hashable, Codable, Sendable {
    var toolCallId: String
    var output: String
    var isError: Bool
}

enum AgentToolInputPreview {
    static func activityDetail(toolName: String, inputJSON: String) -> String {
        guard AgentToolNameCanonicalizer.canonical(toolName) == "Write" else {
            return inputJSON
        }
        guard let object = jsonObject(from: inputJSON) else {
            return inputJSON
        }
        let path = stringValue(for: ["file_path", "path"], in: object)
        guard let content = stringValue(for: ["content"], in: object) else {
            return inputJSON
        }

        var preview: [String: Any] = [
            "content_summary": writeContentSummary(content),
        ]
        if let path {
            preview["file_path"] = path
        }
        return jsonString(preview) ?? inputJSON
    }

    static func writeContentSummary(_ content: String, previewLimit: Int = 360) -> String {
        let lineCount = content.reduce(1) { count, character in
            character == "\n" ? count + 1 : count
        }
        var summary = "\(lineCount) line\(lineCount == 1 ? "" : "s"), \(content.utf8.count) bytes"
        let compact = content
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !compact.isEmpty {
            let preview = truncated(compact, limit: previewLimit)
                .replacingOccurrences(of: "\n", with: " ")
            summary += " · \(preview)"
        }
        return summary
    }

    private static func jsonObject(from raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func jsonString(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    private static func stringValue(for keys: [String], in object: [String: Any]) -> String? {
        for key in keys {
            if let string = object[key] as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty || key == "content" {
                    return string
                }
            }
            if let number = object[key] as? NSNumber {
                return number.stringValue
            }
        }
        return nil
    }

    private static func truncated(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        let index = value.index(value.startIndex, offsetBy: max(0, limit - 1))
        return String(value[..<index]) + "…"
    }
}

enum PermissionRequestKind: String, Hashable, Codable, Sendable {
    case tool
    case askUserQuestion
    case exitPlanMode
    case destructivePlanApproval
}

struct AgentQuestionOption: Identifiable, Hashable, Codable, Sendable {
    var label: String
    var description: String?

    var id: String { label }
}

struct AgentQuestion: Identifiable, Hashable, Codable, Sendable {
    var header: String?
    var question: String
    var options: [AgentQuestionOption]
    var multiSelect: Bool

    var id: String { question }
}

struct AgentInteractivePayload: Hashable, Codable, Sendable {
    var questions: [AgentQuestion]

    static func askUserQuestion(from inputJSON: String) -> AgentInteractivePayload? {
        guard let data = inputJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let rawQuestions = object["questions"] as? [[String: Any]] {
            let questions = rawQuestions.compactMap(normalizedQuestion(from:))
            return questions.isEmpty ? nil : AgentInteractivePayload(questions: questions)
        }

        guard let legacyQuestion = (object["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !legacyQuestion.isEmpty else {
            return nil
        }
        let options = repairedOptions(normalizedOptions(from: object["options"]), question: legacyQuestion)
        return AgentInteractivePayload(
            questions: [
                AgentQuestion(
                    header: (object["header"] as? String)?.nilIfBlank,
                    question: cleanedQuestion(legacyQuestion),
                    options: options,
                    multiSelect: object["multiSelect"] as? Bool ?? false
                )
            ]
        )
    }

    static func updatedInputJSON(originalInputJSON: String, answers: [String: String]) -> String {
        var object: [String: Any] = [:]
        if let data = originalInputJSON.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = parsed
        }
        object["answers"] = answers
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return #"{"answers":{}}"#
        }
        return string
    }

    private static func normalizedQuestion(from object: [String: Any]) -> AgentQuestion? {
        guard let question = (object["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !question.isEmpty else {
            return nil
        }
        let cleaned = cleanedQuestion(question)
        return AgentQuestion(
            header: (object["header"] as? String)?.nilIfBlank,
            question: cleaned,
            options: repairedOptions(normalizedOptions(from: object["options"]), question: cleaned),
            multiSelect: object["multiSelect"] as? Bool ?? false
        )
    }

    private static func normalizedOptions(from rawValue: Any?) -> [AgentQuestionOption] {
        if let strings = rawValue as? [String] {
            return repairedOptionList(strings
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { AgentQuestionOption(label: cleanedOption($0), description: nil) })
        }
        if let objects = rawValue as? [[String: Any]] {
            return repairedOptionList(objects.compactMap { option in
                guard let label = (option["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !label.isEmpty else {
                    return nil
                }
                return AgentQuestionOption(label: cleanedOption(label), description: (option["description"] as? String)?.nilIfBlank)
            })
        }
        return []
    }

    private static func repairedOptions(_ options: [AgentQuestionOption], question: String) -> [AgentQuestionOption] {
        let deduped = repairedOptionList(options)
        return deduped
    }

    private static func repairedOptionList(_ options: [AgentQuestionOption]) -> [AgentQuestionOption] {
        var seen = Set<String>()
        var result: [AgentQuestionOption] = []
        for option in options {
            let label = cleanedOption(option.label)
            let key = label.lowercased()
            guard !label.isEmpty, seen.insert(key).inserted else { continue }
            result.append(AgentQuestionOption(label: label, description: option.description))
        }
        return result
    }

    private static func cleanedQuestion(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"[*_`#]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\s*(?:\d+[\.\)、)]|[-•])\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanedOption(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"[*_`#]+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "。.?？:：")))
    }
}

struct FileAttachment: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var fileName: String
    var path: String
    var mimeType: String?

    var isImage: Bool {
        if mimeType?.lowercased().hasPrefix("image/") == true {
            return true
        }
        return ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"].contains(
            URL(fileURLWithPath: path).pathExtension.lowercased()
        )
    }

    var isPDF: Bool {
        mimeType?.lowercased() == "application/pdf" ||
            URL(fileURLWithPath: path).pathExtension.lowercased() == "pdf"
    }

    var isTextLike: Bool {
        if mimeType?.lowercased().hasPrefix("text/") == true { return true }
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return ["md", "txt", "swift", "js", "ts", "tsx", "jsx", "json", "yaml", "yml", "py", "rb", "go", "rs", "html", "css", "csv", "xml", "log"].contains(ext)
    }
}

struct PermissionRequest: Identifiable, Hashable, Codable {
    var id: UUID
    var sessionId: String
    var toolName: String
    var inputJSON: String
    var reason: String
    var scope: PermissionScope
    var createdAt: Date
    var kind: PermissionRequestKind = .tool
    var interactivePayload: AgentInteractivePayload? = nil
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
        provider: .pilotDeck,
        apiType: .openAIChat,
        baseURL: "",
        model: "",
        secretAccount: "pilotdeck-provider-api-key",
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
            .appendingPathComponent("PilotDeck")
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

    var swiftUIColorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}

enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case system
    case english
    case chineseSimplified

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "Follow System"
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
        wordWrap: false,
        showMinimap: true,
        lineNumbers: true,
        fontSize: 14
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
    ]

    static let defaults = ToolPermissionSettings(
        allowedTools: [],
        disallowedTools: [],
        lastUpdated: nil
    )
}

enum PermissionsExportDefaults {
    static let source = "pilotdeck"

    static func filename(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return "pilotdeck-permissions-\(formatter.string(from: date)).json"
    }
}

enum SettingsMainTab: String, CaseIterable, Identifiable, Hashable {
    case appearance
    case permissions
    case config
    case mcp

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appearance: "Appearance"
        case .permissions: "Permissions"
        case .config: "Config"
        case .mcp: "MCP Servers"
        }
    }

    var systemImage: String {
        switch self {
        case .appearance: "paintpalette"
        case .permissions: "shield"
        case .config: "doc.badge.gearshape"
        case .mcp: "server.rack"
        }
    }
}

enum PilotDeckConfigSection: String, CaseIterable, Identifiable {
    case runtime
    case models
    case agents
    case alwaysOn
    case memory
    case search
    case router
    case gateway
    case customEnv
    case raw

    var id: String { rawValue }

    var label: String {
        switch self {
        case .runtime: "Runtime"
        case .models: "Models"
        case .agents: "Agents"
        case .alwaysOn: "Always-On"
        case .memory: "Memory"
        case .search: "Search"
        case .router: "Router"
        case .gateway: "Gateway"
        case .customEnv: "Custom Env"
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

struct TokenBudget: Hashable, Codable, Sendable {
    var used: Int
    var total: Int
    var level: ContextBudgetLevel? = nil
}

enum ContextBudgetLevel: String, Codable, Hashable, Sendable {
    case normal
    case attention
    case warning
    case compacting
    case recovering

    static func level(used: Int, total: Int) -> ContextBudgetLevel {
        guard total > 0 else { return .normal }
        let ratio = Double(used) / Double(total)
        if ratio >= 0.95 { return .recovering }
        if ratio >= 0.80 { return .warning }
        if ratio >= 0.60 { return .attention }
        return .normal
    }
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
    var content: String = ""
    var scope: String = "project"
    var projectId: String?
    var sourceSessionKey: String?
    var capturedAt: Date?
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
        case .generalProjectMeta: "Chat Project"
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
    var overview: MemoryOverview = .empty
    var settings: MemorySettingsSnapshot = .defaults
    var workspace: MemoryWorkspaceSnapshot = .empty
    var caseTraceRecords: [MemoryTraceRecord] = []
    var indexTraceRecords: [MemoryTraceRecord] = []
    var dreamTraceRecords: [MemoryTraceRecord] = []
    var lastDreamSnapshot: MemoryDreamSnapshot?
    var scheduler: MemorySchedulerSnapshot = .disabled
    var jobStates: [MemoryJobKind: MemoryJobState] = Dictionary(
        uniqueKeysWithValues: MemoryJobKind.allCases.map { ($0, .idle($0)) }
    )
}

struct MemoryOverview: Hashable, Codable {
    var totalEntries: Int
    var projectEntries: Int
    var feedbackEntries: Int
    var userEntries: Int
    var latestMemoryAt: Date?
    var lastIndexedAt: Date?
    var lastDreamAt: Date?
    var schedulerEnabled: Bool

    static let empty = MemoryOverview(
        totalEntries: 0,
        projectEntries: 0,
        feedbackEntries: 0,
        userEntries: 0,
        latestMemoryAt: nil,
        lastIndexedAt: nil,
        lastDreamAt: nil,
        schedulerEnabled: false
    )
}

struct MemorySettingsSnapshot: Hashable, Codable {
    var enabled: Bool
    var model: String
    var reasoningMode: String
    var autoIndexIntervalMinutes: Int
    var autoDreamIntervalMinutes: Int
    var captureStrategy: String
    var includeAssistant: Bool
    var maxMessageChars: Int
    var heartbeatBatchSize: Int

    init(
        enabled: Bool = true,
        model: String = "inherit",
        reasoningMode: String = "answer_first",
        autoIndexIntervalMinutes: Int = 30,
        autoDreamIntervalMinutes: Int = 60,
        captureStrategy: String = "last_turn",
        includeAssistant: Bool = true,
        maxMessageChars: Int = 6000,
        heartbeatBatchSize: Int = 30
    ) {
        self.enabled = enabled
        self.model = model
        self.reasoningMode = reasoningMode == "accuracy_first" ? "accuracy_first" : "answer_first"
        self.autoIndexIntervalMinutes = Self.normalizedInterval(autoIndexIntervalMinutes, fallback: 30)
        self.autoDreamIntervalMinutes = Self.normalizedInterval(autoDreamIntervalMinutes, fallback: 60)
        self.captureStrategy = captureStrategy == "full_session" ? "full_session" : "last_turn"
        self.includeAssistant = includeAssistant
        self.maxMessageChars = max(1, maxMessageChars)
        self.heartbeatBatchSize = max(1, heartbeatBatchSize)
    }

    static let defaults = MemorySettingsSnapshot()

    static func fromConfigValues(_ values: [String: String]) -> MemorySettingsSnapshot {
        MemorySettingsSnapshot(
            enabled: bool(values["memory.enabled"], fallback: true),
            model: values["memory.model"]?.nilIfBlank ?? "inherit",
            reasoningMode: values["memory.reasoningMode"]?.nilIfBlank ?? "answer_first",
            autoIndexIntervalMinutes: int(values["memory.autoIndexIntervalMinutes"], fallback: 30),
            autoDreamIntervalMinutes: int(values["memory.autoDreamIntervalMinutes"], fallback: 60),
            captureStrategy: values["memory.captureStrategy"]?.nilIfBlank ?? "last_turn",
            includeAssistant: bool(values["memory.includeAssistant"], fallback: true),
            maxMessageChars: int(values["memory.maxMessageChars"], fallback: 6000),
            heartbeatBatchSize: int(values["memory.heartbeatBatchSize"], fallback: 30)
        )
    }

    private static func normalizedInterval(_ value: Int, fallback: Int) -> Int {
        let resolved = value < 0 ? fallback : value
        return min(10_080, max(0, resolved))
    }

    private static func int(_ value: String?, fallback: Int) -> Int {
        value.flatMap(Int.init) ?? fallback
    }

    private static func bool(_ value: String?, fallback: Bool) -> Bool {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "1", "yes", "on": return true
        case "false", "0", "no", "off": return false
        default: return fallback
        }
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case model
        case reasoningMode
        case autoIndexIntervalMinutes
        case autoDreamIntervalMinutes
        case captureStrategy
        case includeAssistant
        case maxMessageChars
        case heartbeatBatchSize
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
            model: try container.decodeIfPresent(String.self, forKey: .model) ?? "inherit",
            reasoningMode: try container.decodeIfPresent(String.self, forKey: .reasoningMode) ?? "answer_first",
            autoIndexIntervalMinutes: try container.decodeIfPresent(Int.self, forKey: .autoIndexIntervalMinutes) ?? 30,
            autoDreamIntervalMinutes: try container.decodeIfPresent(Int.self, forKey: .autoDreamIntervalMinutes) ?? 60,
            captureStrategy: try container.decodeIfPresent(String.self, forKey: .captureStrategy) ?? "last_turn",
            includeAssistant: try container.decodeIfPresent(Bool.self, forKey: .includeAssistant) ?? true,
            maxMessageChars: try container.decodeIfPresent(Int.self, forKey: .maxMessageChars) ?? 6000,
            heartbeatBatchSize: try container.decodeIfPresent(Int.self, forKey: .heartbeatBatchSize) ?? 30
        )
    }
}

struct MemoryWorkspaceSnapshot: Hashable, Codable {
    var workspaceMode: String
    var projectPath: String?
    var selectedProjectId: String?
    var selectedProject: MemoryProjectMeta?
    var generalProjects: [MemoryProjectMeta]
    var projectMeta: MemoryProjectMeta?
    var manifestPath: String
    var manifestContent: String
    var totalFiles: Int
    var totalProjects: Int
    var totalFeedback: Int
    var projectEntries: [MemoryRecord]
    var feedbackEntries: [MemoryRecord]
    var deprecatedProjectEntries: [MemoryRecord]
    var deprecatedFeedbackEntries: [MemoryRecord]

    static let empty = MemoryWorkspaceSnapshot(
        workspaceMode: "project",
        projectPath: nil,
        selectedProjectId: nil,
        selectedProject: nil,
        generalProjects: [],
        projectMeta: nil,
        manifestPath: "MEMORY.md",
        manifestContent: "",
        totalFiles: 0,
        totalProjects: 0,
        totalFeedback: 0,
        projectEntries: [],
        feedbackEntries: [],
        deprecatedProjectEntries: [],
        deprecatedFeedbackEntries: []
    )
}

struct MemoryProjectMeta: Identifiable, Hashable, Codable {
    var id: String { projectId }
    var projectId: String
    var projectName: String
    var description: String
    var status: String
    var workspacePath: String?
    var relativePath: String?
    var sourceType: String
    var readOnly: Bool
    var updatedAt: Date?
}

struct MemoryTraceRecord: Identifiable, Hashable, Codable {
    var id: String
    var title: String
    var status: String
    var trigger: String
    var createdAt: Date
    var meta: [String: String]
    var context: String
    var toolEvents: String
    var reply: String
    var steps: [MemoryTraceStep]
}

struct MemoryTraceStep: Identifiable, Hashable, Codable {
    var id: String
    var title: String
    var detail: String
    var status: String
    var createdAt: Date
}

enum MemoryJobKind: String, Codable, Hashable, CaseIterable, Identifiable {
    case recall
    case index
    case dream
    case rollback

    var id: String { rawValue }
}

enum MemoryJobPhase: String, Codable, Hashable {
    case idle
    case running
    case completed
    case failed
}

struct MemoryJobState: Identifiable, Hashable, Codable {
    var id: MemoryJobKind { kind }
    var kind: MemoryJobKind
    var phase: MemoryJobPhase
    var message: String
    var traceID: String?
    var startedAt: Date?
    var endedAt: Date?

    static func idle(_ kind: MemoryJobKind) -> MemoryJobState {
        MemoryJobState(kind: kind, phase: .idle, message: "", traceID: nil, startedAt: nil, endedAt: nil)
    }
}

struct MemoryDreamSnapshot: Hashable, Codable {
    var capturedAt: Date
    var rollbackReady: Bool
    var summary: String
}

struct MemorySchedulerSnapshot: Hashable, Codable {
    var enabled: Bool
    var status: String

    static let disabled = MemorySchedulerSnapshot(enabled: false, status: "disabled")
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

struct SkillHubSearchResult: Identifiable, Hashable, Codable {
    var id: String { slug }
    var slug: String
    var name: String
    var score: Double?
}

struct SkillHubInstallResult: Hashable, Codable {
    var ok: Bool
    var slug: String
    var scope: SkillScope
    var installPath: String
    var installed: Bool
    var skill: SkillRecord?
    var stdout: String
    var stderr: String
    var exitCode: Int32
    var needsForce: Bool
}

struct RoutingBucket: Hashable, Codable {
    var count: Int
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var totalTokens: Int
    var requestCount: Int
    var estimatedCost: Double
    var baselineCost: Double
    var savedCost: Double

    init(
        count: Int = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        totalTokens: Int? = nil,
        requestCount: Int? = nil,
        estimatedCost: Double = 0,
        baselineCost: Double = 0,
        savedCost: Double = 0
    ) {
        self.count = count
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.totalTokens = totalTokens ?? inputTokens + outputTokens + cacheReadTokens
        self.requestCount = requestCount ?? count
        self.estimatedCost = estimatedCost
        self.baselineCost = baselineCost
        self.savedCost = savedCost
    }

    private enum CodingKeys: String, CodingKey {
        case count
        case inputTokens
        case outputTokens
        case cacheReadTokens
        case totalTokens
        case requestCount
        case estimatedCost
        case baselineCost
        case savedCost
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        count = try container.decodeIfPresent(Int.self, forKey: .count) ?? 0
        inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        cacheReadTokens = try container.decodeIfPresent(Int.self, forKey: .cacheReadTokens) ?? 0
        totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens) ?? inputTokens + outputTokens + cacheReadTokens
        requestCount = try container.decodeIfPresent(Int.self, forKey: .requestCount) ?? count
        estimatedCost = try container.decodeIfPresent(Double.self, forKey: .estimatedCost) ?? 0
        baselineCost = try container.decodeIfPresent(Double.self, forKey: .baselineCost) ?? 0
        savedCost = try container.decodeIfPresent(Double.self, forKey: .savedCost) ?? 0
    }
}

enum RouterTier: String, CaseIterable, Hashable, Codable {
    case simple
    case medium
    case complex
    case reasoning

    init(canonicalizing rawValue: String?) {
        let normalized = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        switch normalized {
        case "simple": self = .simple
        case "complex": self = .complex
        case "reasoning": self = .reasoning
        default: self = .medium
        }
    }

    var configKey: String { rawValue }
    var displayName: String { rawValue }
}

struct RouterTokenUsage: Hashable, Codable, Sendable {
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var totalTokens: Int

    init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        totalTokens: Int? = nil
    ) {
        self.inputTokens = max(0, inputTokens)
        self.outputTokens = max(0, outputTokens)
        self.cacheReadTokens = max(0, cacheReadTokens)
        self.totalTokens = max(0, totalTokens ?? inputTokens + outputTokens + cacheReadTokens)
    }

    var isEmpty: Bool { totalTokens <= 0 && inputTokens <= 0 && outputTokens <= 0 && cacheReadTokens <= 0 }
}

struct RouterDecision: Hashable, Codable, Sendable {
    var id: String
    var entryID: String
    var providerID: String?
    var model: String?
    var scenario: String
    var tier: String?
    var role: String
    var resolvedFrom: String
    var stickyHit: Bool
    var orchestrating: Bool
    var reason: String?
    var estimatedInputTokens: Int

    init(
        id: String = UUID().uuidString,
        entryID: String,
        providerID: String? = nil,
        model: String? = nil,
        scenario: String,
        tier: String? = nil,
        role: String = "main",
        resolvedFrom: String,
        stickyHit: Bool = false,
        orchestrating: Bool = false,
        reason: String? = nil,
        estimatedInputTokens: Int = 0
    ) {
        self.id = id
        self.entryID = entryID
        self.providerID = providerID
        self.model = model
        self.scenario = scenario
        self.tier = tier
        self.role = role
        self.resolvedFrom = resolvedFrom
        self.stickyHit = stickyHit
        self.orchestrating = orchestrating
        self.reason = reason
        self.estimatedInputTokens = estimatedInputTokens
    }
}

struct RouterStatsRecord: Identifiable, Hashable, Codable {
    var id: String
    var sessionID: String
    var turnID: String
    var projectName: String
    var projectPath: String?
    var title: String
    var ts: Date
    var event: String
    var role: String
    var scenario: String
    var resolvedFrom: String
    var tier: String?
    var providerID: String?
    var model: String
    var route: String?
    var query: String?
    var skill: String?
    var usage: RouterTokenUsage
    var cost: Double
    var baselineCost: Double
    var savedCost: Double
    var estimatedInputTokens: Int
    var stickyHit: Bool
    var reason: String?

    init(
        id: String = UUID().uuidString,
        sessionID: String,
        turnID: String? = nil,
        projectName: String,
        projectPath: String? = nil,
        title: String,
        ts: Date = Date(),
        event: String,
        role: String,
        scenario: String,
        resolvedFrom: String,
        tier: String? = nil,
        providerID: String? = nil,
        model: String,
        route: String? = nil,
        query: String? = nil,
        skill: String? = nil,
        usage: RouterTokenUsage = RouterTokenUsage(),
        cost: Double = 0,
        baselineCost: Double = 0,
        savedCost: Double = 0,
        estimatedInputTokens: Int = 0,
        stickyHit: Bool = false,
        reason: String? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.turnID = turnID ?? id
        self.projectName = projectName
        self.projectPath = projectPath
        self.title = title
        self.ts = ts
        self.event = event
        self.role = role
        self.scenario = scenario
        self.resolvedFrom = resolvedFrom
        self.tier = tier
        self.providerID = providerID
        self.model = model
        self.route = route
        self.query = query
        self.skill = skill
        self.usage = usage
        self.cost = cost
        self.baselineCost = baselineCost
        self.savedCost = savedCost
        self.estimatedInputTokens = estimatedInputTokens
        self.stickyHit = stickyHit
        self.reason = reason
    }
}

struct RoutingRequestLogEntry: Identifiable, Hashable, Codable {
    var id: String
    var ts: Date
    var role: String
    var tier: String?
    var model: String
    var tokens: Int
    var cost: Double
    var baselineCost: Double?
    var savedCost: Double?
    var query: String?
    var scenario: String?
    var route: String?
    var skill: String?

    init(
        id: String = UUID().uuidString,
        ts: Date = Date(),
        role: String,
        tier: String? = nil,
        model: String,
        tokens: Int = 0,
        cost: Double = 0,
        baselineCost: Double? = nil,
        savedCost: Double? = nil,
        query: String? = nil,
        scenario: String? = nil,
        route: String? = nil,
        skill: String? = nil
    ) {
        self.id = id
        self.ts = ts
        self.role = role
        self.tier = tier
        self.model = model
        self.tokens = tokens
        self.cost = cost
        self.baselineCost = baselineCost
        self.savedCost = savedCost
        self.query = query
        self.scenario = scenario
        self.route = route
        self.skill = skill
    }
}

struct RoutingDashboardSession: Identifiable, Hashable, Codable {
    var id: String
    var title: String
    var projectName: String
    var lastActiveAt: Date
    var totalTokens: Int
    var estimatedCost: Double
    var savedCost: Double
    var total: RoutingBucket
    var byTier: [String: RoutingBucket]
    var byModel: [String: RoutingBucket]
    var byScenario: [String: RoutingBucket]
    var byRole: [String: RoutingBucket]
    var requestLog: [String]
    var requestEntries: [RoutingRequestLogEntry]

    init(
        id: String,
        title: String,
        projectName: String,
        lastActiveAt: Date,
        totalTokens: Int,
        estimatedCost: Double,
        savedCost: Double,
        total: RoutingBucket? = nil,
        byTier: [String: RoutingBucket],
        byModel: [String: RoutingBucket],
        byScenario: [String: RoutingBucket] = [:],
        byRole: [String: RoutingBucket] = [:],
        requestLog: [String],
        requestEntries: [RoutingRequestLogEntry] = []
    ) {
        self.id = id
        self.title = title
        self.projectName = projectName
        self.lastActiveAt = lastActiveAt
        self.totalTokens = totalTokens
        self.estimatedCost = estimatedCost
        self.savedCost = savedCost
        self.total = total ?? RoutingBucket(
            count: Self.inferredRequestCount(byTier: byTier, byModel: byModel, byRole: byRole),
            inputTokens: totalTokens,
            totalTokens: totalTokens,
            estimatedCost: estimatedCost,
            baselineCost: estimatedCost + savedCost,
            savedCost: savedCost
        )
        self.byTier = byTier
        self.byModel = byModel
        self.byScenario = byScenario
        self.byRole = byRole
        self.requestLog = requestLog
        self.requestEntries = requestEntries
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case projectName
        case lastActiveAt
        case totalTokens
        case estimatedCost
        case savedCost
        case total
        case byTier
        case byModel
        case byScenario
        case byRole
        case requestLog
        case requestEntries
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        projectName = try container.decode(String.self, forKey: .projectName)
        lastActiveAt = try container.decode(Date.self, forKey: .lastActiveAt)
        totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens) ?? 0
        estimatedCost = try container.decodeIfPresent(Double.self, forKey: .estimatedCost) ?? 0
        savedCost = try container.decodeIfPresent(Double.self, forKey: .savedCost) ?? 0
        byTier = try container.decodeIfPresent([String: RoutingBucket].self, forKey: .byTier) ?? [:]
        byModel = try container.decodeIfPresent([String: RoutingBucket].self, forKey: .byModel) ?? [:]
        byScenario = try container.decodeIfPresent([String: RoutingBucket].self, forKey: .byScenario) ?? [:]
        byRole = try container.decodeIfPresent([String: RoutingBucket].self, forKey: .byRole) ?? [:]
        requestLog = try container.decodeIfPresent([String].self, forKey: .requestLog) ?? []
        requestEntries = try container.decodeIfPresent([RoutingRequestLogEntry].self, forKey: .requestEntries) ?? []
        total = try container.decodeIfPresent(RoutingBucket.self, forKey: .total) ?? RoutingBucket(
            count: Self.inferredRequestCount(byTier: byTier, byModel: byModel, byRole: byRole),
            inputTokens: totalTokens,
            totalTokens: totalTokens,
            estimatedCost: estimatedCost,
            baselineCost: estimatedCost + savedCost,
            savedCost: savedCost
        )
    }

    private static func inferredRequestCount(
        byTier: [String: RoutingBucket],
        byModel: [String: RoutingBucket],
        byRole: [String: RoutingBucket]
    ) -> Int {
        let sums = [byTier, byModel, byRole].map { buckets in
            buckets.values.reduce(0) { partial, bucket in
                partial + max(bucket.count, bucket.requestCount)
            }
        }
        return sums.max() ?? 0
    }
}

struct RoutingDashboardSnapshot: Hashable, Codable {
    var totalProjects: Int
    var totalSessions: Int
    var totalRequests: Int
    var routedSessions: Int
    var totalTokens: Int
    var estimatedCost: Double
    var savedCost: Double
    var recentSessions: [RoutingDashboardSession]
    var projects: [RoutingDashboardProject] = []
}

struct RoutingDashboardProject: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var displayName: String
    var total: RoutingBucket
    var sessions: Int
    var lastActiveAt: Date?
}

enum AlwaysOnStatus: String, Codable {
    case scheduled
    case ready
    case queued
    case running
    case executing
    case reporting
    case completed
    case failed
    case draft
    case superseded
    case noPlan = "no_plan"
    case applying
    case applied
    case applyFailed = "apply_failed"
    case archived
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
    var contextRefs: [String: [String]]? = nil
    var createdAt: Date
    var updatedAt: Date
    var executionSessionId: String?
    var executionStatus: AlwaysOnStatus?
    var dedupeKey: String? = nil
    var sourceRunId: String? = nil
    var workCycleId: String? = nil
    var workspacePath: String? = nil
    var reportFilePath: String? = nil
    var projectName: String? = nil
    var projectRoot: String? = nil

    init(
        id: String,
        title: String,
        summary: String,
        rationale: String,
        content: String,
        status: AlwaysOnStatus,
        approvalMode: String,
        planFilePath: String,
        contextRefs: [String: [String]]? = nil,
        createdAt: Date,
        updatedAt: Date,
        executionSessionId: String?,
        executionStatus: AlwaysOnStatus?
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.rationale = rationale
        self.content = content
        self.status = status
        self.approvalMode = approvalMode
        self.planFilePath = planFilePath
        self.contextRefs = contextRefs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.executionSessionId = executionSessionId
        self.executionStatus = executionStatus
        self.dedupeKey = nil
        self.sourceRunId = nil
        self.workCycleId = nil
        self.workspacePath = nil
        self.reportFilePath = nil
        self.projectName = nil
        self.projectRoot = nil
    }

    init(
        id: String,
        title: String,
        summary: String,
        rationale: String,
        content: String,
        status: AlwaysOnStatus,
        approvalMode: String,
        planFilePath: String,
        contextRefs: [String: [String]]? = nil,
        createdAt: Date,
        updatedAt: Date,
        executionSessionId: String?,
        executionStatus: AlwaysOnStatus?,
        dedupeKey: String? = nil,
        sourceRunId: String? = nil,
        workCycleId: String? = nil,
        workspacePath: String? = nil,
        reportFilePath: String? = nil,
        projectName: String? = nil,
        projectRoot: String? = nil
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.rationale = rationale
        self.content = content
        self.status = status
        self.approvalMode = approvalMode
        self.planFilePath = planFilePath
        self.contextRefs = contextRefs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.executionSessionId = executionSessionId
        self.executionStatus = executionStatus
        self.dedupeKey = dedupeKey
        self.sourceRunId = sourceRunId
        self.workCycleId = workCycleId
        self.workspacePath = workspacePath
        self.reportFilePath = reportFilePath
        self.projectName = projectName
        self.projectRoot = projectRoot
    }
}

struct AlwaysOnCronLatestRun: Identifiable, Hashable, Codable {
    var status: AlwaysOnStatus?
    var runId: String?
    var startedAt: Date?
    var sessionId: String?
    var summary: String?
    var lastActivity: Date?
    var taskId: String?
    var outputFile: String?
    var parentSessionId: String?
    var relativeTranscriptPath: String?
    var transcriptKey: String?

    var id: String {
        runId ?? sessionId ?? taskId ?? transcriptKey ?? "latest"
    }
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
    var permanent: Bool = false
    var manualOnly: Bool = false
    var originSessionId: String?
    var transcriptKey: String?
    var latestRun: AlwaysOnCronLatestRun?
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
    var parentSessionId: String?
    var relativeTranscriptPath: String?
    var finishedAt: Date? = nil
    var error: String? = nil
    var metadata: [String: String] = [:]
    var transcriptKey: String? = nil

    var shouldPollLog: Bool {
        status == .queued || status == .running
    }
}

enum AlwaysOnRunLogSource: String, Hashable, Codable {
    case logFile = "log-file"
    case session
    case history
}

struct AlwaysOnRunLog: Identifiable, Hashable, Codable {
    var runId: String
    var content: String
    var truncated: Bool
    var updatedAt: Date?
    var size: Int
    var source: AlwaysOnRunLogSource

    var id: String { runId }
}

struct AlwaysOnProjectIdentity: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var projectName: String
    var displayName: String
    var rootPath: String
    var isGeneral: Bool = false
}

struct AlwaysOnDashboardSnapshot: Hashable, Codable {
    var totalProjects: Int
    var enabledProjects: Int
    var runningCount: Int
    var todayEvents: Int
    var readyPlans: Int
    var recentEvents: [AlwaysOnEvent]
    var projects: [AlwaysOnProjectDashboard]
}

struct AlwaysOnProjectDashboard: Identifiable, Hashable, Codable {
    var id: String
    var projectName: String
    var displayName: String
    var rootPath: String
    var enabled: Bool
    var status: AlwaysOnStatus
    var lastGate: String?
    var lastRunAt: Date?
    var nextEligibleAt: Date?
    var readyPlans: Int
    var runningRuns: Int
}

struct AlwaysOnEvent: Identifiable, Hashable, Codable {
    var id: String
    var projectName: String
    var projectRoot: String
    var kind: String
    var status: AlwaysOnStatus
    var title: String
    var detail: String
    var runId: String?
    var planId: String?
    var cycleId: String?
    var createdAt: Date
}

struct AlwaysOnCycle: Identifiable, Hashable, Codable {
    var id: String
    var projectName: String
    var projectRoot: String
    var planId: String?
    var discoveryRunId: String?
    var executionRunId: String?
    var reportRunId: String?
    var workspacePath: String?
    var workspaceMode: String?
    var status: AlwaysOnStatus
    var title: String
    var summary: String?
    var reportFilePath: String?
    var createdAt: Date
    var updatedAt: Date
    var appliedAt: Date?
    var archivedAt: Date?
}

struct AlwaysOnWorkspacePreparation: Hashable, Codable {
    var cycleId: String
    var workspacePath: String
    var mode: String
    var sourceRoot: String
    var createdAt: Date
}

enum AlwaysOnSessionTargetKind: String, Hashable, Codable {
    case origin
    case background
}

struct AlwaysOnSessionTarget: Hashable, Codable {
    var kind: AlwaysOnSessionTargetKind
    var sessionId: String
    var parentSessionId: String?
    var relativeTranscriptPath: String?
    var title: String?
    var summary: String?
    var lastActivity: Date?
    var transcriptKey: String?
    var taskId: String?
    var taskStatus: String?
    var outputFile: String?

    static func origin(sessionId: String) -> AlwaysOnSessionTarget {
        AlwaysOnSessionTarget(
            kind: .origin,
            sessionId: sessionId,
            parentSessionId: nil,
            relativeTranscriptPath: nil,
            title: nil,
            summary: nil,
            lastActivity: nil,
            transcriptKey: nil,
            taskId: nil,
            taskStatus: nil,
            outputFile: nil
        )
    }

    static func background(
        sessionId: String,
        parentSessionId: String,
        relativeTranscriptPath: String,
        title: String?,
        summary: String?,
        lastActivity: Date?,
        transcriptKey: String?,
        taskId: String?,
        taskStatus: String?,
        outputFile: String?
    ) -> AlwaysOnSessionTarget {
        AlwaysOnSessionTarget(
            kind: .background,
            sessionId: sessionId,
            parentSessionId: parentSessionId,
            relativeTranscriptPath: relativeTranscriptPath,
            title: title,
            summary: summary,
            lastActivity: lastActivity,
            transcriptKey: transcriptKey,
            taskId: taskId,
            taskStatus: taskStatus,
            outputFile: outputFile
        )
    }
}

struct AlwaysOnDiscoveryContext: Hashable, Codable {
    var generatedAt: String
    var lookbackDays: Int
    var workspace: Workspace
    var memory: [MemoryItem]
    var existingPlans: [PlanItem]
    var cronJobs: [CronItem]
    var recentChats: [ChatItem]

    struct Workspace: Hashable, Codable {
        var projectName: String
        var projectRoot: String
        var signals: [String]
    }

    struct MemoryItem: Hashable, Codable {
        var path: String
        var modifiedAt: String
        var summary: String
    }

    struct PlanItem: Hashable, Codable {
        var id: String
        var title: String
        var status: String
        var approvalMode: String
        var updatedAt: String
        var summary: String
    }

    struct CronItem: Hashable, Codable {
        var id: String
        var status: String
        var cron: String
        var recurring: Bool
        var manualOnly: Bool
        var prompt: String
        var latestRunSummary: String?
    }

    struct ChatItem: Hashable, Codable {
        var id: String
        var summary: String
        var lastActivity: String
        var lastUserMessage: String?
        var lastAssistantMessage: String?
    }
}

struct AlwaysOnDiscoveryRequestDedupeStore: Hashable, Codable {
    private(set) var seen: Set<String> = []
    private(set) var order: [String] = []

    mutating func shouldProcess(_ requestID: String?, maxSize: Int = 100) -> Bool {
        guard let normalized = requestID?.trimmingCharacters(in: .whitespacesAndNewlines), !normalized.isEmpty else {
            return false
        }
        guard !seen.contains(normalized) else {
            return false
        }
        seen.insert(normalized)
        order.append(normalized)
        while order.count > maxSize {
            if let oldest = order.first {
                seen.remove(oldest)
            }
            order.removeFirst()
        }
        return true
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
