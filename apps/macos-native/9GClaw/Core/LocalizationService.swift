import Foundation

enum ResolvedAppLanguage: String {
    case english
    case chineseSimplified
}

enum L10nKey: String, CaseIterable {
    case add
    case agent
    case allow
    case allowedTools
    case allowedToolsDetail
    case alwaysOn
    case appearance
    case askPlaceholder
    case attach
    case attachHelp
    case back
    case blockedTools
    case browse
    case cancel
    case chatRunModeAgent
    case chatRunModeAgentDetail
    case chatRunModePlan
    case chatRunModePlanDetail
    case choosePermissionMode
    case chooseRunMode
    case chooseWorkspaceType
    case connecting
    case clear
    case codeEditor
    case commandHelp
    case complete
    case config
    case configureWorkspace
    case contextUsage
    case contextUsageDetail
    case continueAction
    case create
    case createNew
    case createNewDetail
    case createProject
    case createProjectSubtitle
    case creatingProject
    case dashboard
    case delete
    case deny
    case diff
    case dismiss
    case displayLanguage
    case displayLanguageDetail
    case displayName
    case done
    case download
    case exported
    case exportAction
    case failed
    case fetch
    case files
    case general
    case git
    case githubURLOptional
    case hideSidebar
    case imported
    case importAction
    case index
    case languageChineseSimplified
    case languageEnglish
    case languageSystem
    case live
    case memory
    case mentionFile
    case newAction
    case newFile
    case newFolder
    case newSession
    case name
    case noGeneralWorkspaceFound
    case noProjectsFound
    case noSessionsYet
    case noTokenBudget
    case notSavedYet
    case openExisting
    case openExistingDetail
    case openHTML
    case permissionAllowedFormat
    case permissionDeniedFormat
    case permissionModeBypass
    case permissionModeBypassDetail
    case permissionModeDefault
    case permissionModeDefaultDetail
    case permissions
    case preview
    case processFailed
    case projectAdded
    case projectDeleteUnavailable
    case projectRenameUnavailable
    case projectSorting
    case projects
    case pull
    case push
    case queue
    case receivingResponse
    case refresh
    case refreshProjects
    case rename
    case review
    case reviewAttachedFiles
    case routing
    case run
    case runningToolFormat
    case saved
    case save
    case send
    case sessionDeleteUnavailable
    case sessionRenameUnavailable
    case settings
    case settingsSaved
    case shell
    case sessionStartedFormat
    case showLess
    case showMoreFormat
    case showSidebar
    case skills
    case status
    case streamingAssistantOutput
    case stopGeneration
    case stopped
    case tasks
    case toolError
    case toolResult
    case toolsFormat
    case type
    case uploadFiles
    case uploadFolder
    case welcomePrompt
    case working
    case nativeInitialized
    case openingRemoteModelStream
    case projectsRefreshed
    case agentStatusUpdate
    case aborted
    case ready
    case workspacePath
    case workspacePathDoesNotExist
    case addEntry
    case addProvider
    case allowAllUsers
    case allowAllUsersDetail
    case alwaysOnProjectOnly
    case apiKey
    case archive
    case backgroundDiscoveryAgent
    case cannotBeUndone
    case charactersFormat
    case command
    case configFile
    case configInvalid
    case configPreview
    case configReloadedNotice
    case configSummaryHelp
    case configValid
    case cost
    case disableBuiltInWebTools
    case disableBuiltInWebToolsDetail
    case discover
    case discoveryTrigger
    case discoveryTriggerDetail
    case dragToResize
    case enabled
    case enterName
    case entries
    case entriesDetail
    case form
    case gateway
    case gatewayConfigParsed
    case gatewayDetail
    case gatewayDisabled
    case gitStatusPrompt
    case groupSessionsPerUser
    case groupSessionsPerUserDetail
    case includeAssistant
    case includeAssistantDetail
    case keychainHelp
    case linesFormat
    case mainAgent
    case memoryDisabled
    case memoryServiceEnabled
    case missing
    case modelRoutingSummary
    case noActivePlans
    case noAlwaysOnRuns
    case noAllowedToolsConfigured
    case noBlockedToolsConfigured
    case noEntriesConfigured
    case noOutputLog
    case noPlanContent
    case noProjectSelected
    case noProvidersConfigured
    case noRoutingActivity
    case noSkillsYet
    case nativeSettingsApplied
    case oneShot
    case pickProject
    case plansCronJobs
    case present
    case processEnv
    case provider
    case providers
    case providersDetail
    case quickAdd
    case rag
    case ragDetail
    case rawYAML
    case recentRoutes
    case recurring
    case runtime
    case models
    case agents
    case reload
    case reloadCurrent
    case reloadDetail
    case revealFile
    case reloadedCurrentConfig
    case remove
    case requests
    case revert
    case routerDashboardNative
    case routerDetail
    case routerDisabled
    case routerLog
    case routerLogDetail
    case runHistory
    case saveAndReload
    case savedAndReloaded
    case saveShortcut
    case session
    case selectProject
    case searchMemory
    case storedInKeychain
    case subagents
    case threadSessionsPerUser
    case threadSessionsPerUserDetail
    case tokenSaver
    case tokenSaverDetail
    case tokens
    case unsaved
    case unsavedChanges
    case user
    case workspaceMemory
    case feedback
    case latest
    case none
    case noMemoryRecords
    case noMemoryRecordsDetail
    case userSummary
    case noSummaryYet
    case generalSkillsOnly
    case projectSkills
    case userSkills
    case pickSkill
    case pickSkillDetail
    case scope
    case slug
    case description
    case alphabetical
    case gitURLHelp
    case permissionsShareDetail
    case recentActivity
    case toggle
}

struct LocalizationService {
    let language: ResolvedAppLanguage

    init(language: AppLanguage, preferredLanguages: [String] = Locale.preferredLanguages) {
        self.language = language.resolved(preferredLanguages: preferredLanguages)
    }

    func text(_ key: L10nKey, _ args: CVarArg...) -> String {
        text(key, arguments: args)
    }

    func text(_ key: L10nKey, arguments args: [CVarArg]) -> String {
        let template = Self.table(for: language)[key] ?? Self.english[key] ?? key.rawValue
        guard !args.isEmpty else { return template }
        return String(format: template, locale: locale, arguments: args)
    }

    private var locale: Locale {
        switch language {
        case .english: Locale(identifier: "en_US")
        case .chineseSimplified: Locale(identifier: "zh_Hans")
        }
    }

    static func table(for language: ResolvedAppLanguage) -> [L10nKey: String] {
        switch language {
        case .english: english
        case .chineseSimplified: chineseSimplified
        }
    }

    static let english: [L10nKey: String] = [
        .add: "Add",
        .agent: "Agent",
        .allow: "Allow",
        .allowedTools: "Allowed tools",
        .allowedToolsDetail: "Tools that auto-run without prompting.",
        .alwaysOn: "Always-on",
        .appearance: "Appearance",
        .askPlaceholder: "Ask 9GClaw",
        .attach: "Attach",
        .attachHelp: "Attach photos or files",
        .back: "Back",
        .blockedTools: "Blocked tools",
        .browse: "Browse",
        .cancel: "Cancel",
        .chatRunModeAgent: "Agent",
        .chatRunModeAgentDetail: "Run the agent with tools and streaming output.",
        .chatRunModePlan: "Plan",
        .chatRunModePlanDetail: "Ask the agent to produce a plan first.",
        .choosePermissionMode: "Choose permission mode",
        .chooseRunMode: "Choose run mode",
        .chooseWorkspaceType: "Choose workspace type",
        .connecting: "Connecting",
        .clear: "Clear",
        .codeEditor: "Code Editor",
        .commandHelp: "Run a command",
        .complete: "Complete",
        .config: "Config",
        .configureWorkspace: "Configure workspace",
        .contextUsage: "Context usage: 0%",
        .contextUsageDetail: "No token budget has been reported for this session yet.",
        .continueAction: "Continue",
        .create: "Create",
        .createNew: "Create New",
        .createNewDetail: "Create a new folder, optionally from Git.",
        .createProject: "Create Project",
        .createProjectSubtitle: "Add an existing workspace or create a new folder.",
        .creatingProject: "Creating project...",
        .dashboard: "Routing",
        .delete: "Delete",
        .deny: "Deny",
        .diff: "Diff",
        .dismiss: "Dismiss",
        .displayLanguage: "Display Language",
        .displayLanguageDetail: "Choose the language used by the interface.",
        .displayName: "Display Name",
        .done: "Done",
        .download: "Download",
        .exported: "Exported",
        .exportAction: "Export",
        .failed: "Failed",
        .fetch: "Fetch",
        .files: "Files",
        .general: "General",
        .git: "Git",
        .githubURLOptional: "GitHub URL (optional)",
        .hideSidebar: "Hide sidebar",
        .imported: "Imported",
        .importAction: "Import",
        .index: "Index",
        .languageChineseSimplified: "简体中文",
        .languageEnglish: "English",
        .languageSystem: "System",
        .live: "Live",
        .memory: "Memory",
        .mentionFile: "Mention a file",
        .newAction: "New",
        .newFile: "New File",
        .newFolder: "New Folder",
        .newSession: "New Session",
        .name: "Name",
        .noGeneralWorkspaceFound: "No general workspace found",
        .noProjectsFound: "No projects found",
        .noSessionsYet: "No sessions yet",
        .noTokenBudget: "No token budget has been reported for this session yet.",
        .notSavedYet: "Not saved yet",
        .openExisting: "Open Existing",
        .openExistingDetail: "Register an existing local project folder.",
        .openHTML: "Open HTML",
        .permissionAllowedFormat: "Permission allowed for %@",
        .permissionDeniedFormat: "Permission denied for %@",
        .permissionModeBypass: "Full access",
        .permissionModeBypassDetail: "Allow trusted tool actions for this run.",
        .permissionModeDefault: "Default permissions",
        .permissionModeDefaultDetail: "Ask before running tools that need approval.",
        .permissions: "Permissions",
        .preview: "Preview",
        .processFailed: "Process failed",
        .projectAdded: "Project added",
        .projectDeleteUnavailable: "Project delete is not implemented in this UI parity pass.",
        .projectRenameUnavailable: "Project rename is not implemented in this UI parity pass.",
        .projectSorting: "Project Sorting",
        .projects: "Projects",
        .pull: "Pull",
        .push: "Push",
        .queue: "Queue",
        .receivingResponse: "Receiving response",
        .refresh: "Refresh",
        .refreshProjects: "Refresh Projects",
        .rename: "Rename",
        .review: "Review",
        .reviewAttachedFiles: "Review the attached files.",
        .routing: "Routing",
        .run: "Run",
        .runningToolFormat: "Running %@",
        .saved: "Saved",
        .save: "Save",
        .send: "Send",
        .sessionDeleteUnavailable: "Session delete is not implemented in this UI parity pass.",
        .sessionRenameUnavailable: "Session rename is not implemented in this UI parity pass.",
        .settings: "Settings",
        .settingsSaved: "Settings saved",
        .shell: "Shell",
        .sessionStartedFormat: "Session %@ started",
        .showLess: "Show less",
        .showMoreFormat: "Show more (%d)",
        .showSidebar: "Show sidebar",
        .skills: "Skills",
        .status: "Status",
        .streamingAssistantOutput: "Streaming assistant output",
        .stopGeneration: "Stop generation",
        .stopped: "Stopped",
        .tasks: "Tasks",
        .toolError: "Tool error",
        .toolResult: "Tool result",
        .toolsFormat: "%d tools",
        .type: "Type",
        .uploadFiles: "Upload Files...",
        .uploadFolder: "Upload Folder...",
        .welcomePrompt: "What would you like to work on today?",
        .working: "Working",
        .nativeInitialized: "Native macOS app initialized",
        .openingRemoteModelStream: "Opening the remote model stream",
        .projectsRefreshed: "Projects refreshed",
        .agentStatusUpdate: "Agent status update",
        .aborted: "Aborted",
        .ready: "Ready",
        .workspacePath: "Workspace Path",
        .workspacePathDoesNotExist: "Workspace path does not exist.",
        .addEntry: "Add Entry",
        .addProvider: "Add Provider",
        .allowAllUsers: "Allow All Users",
        .allowAllUsersDetail: "Allow any remote user to interact with the gateway.",
        .alwaysOnProjectOnly: "Always-On is available for project workspaces.",
        .apiKey: "API Key",
        .archive: "Archive",
        .backgroundDiscoveryAgent: "Background discovery agent for this project.",
        .cannotBeUndone: "This cannot be undone.",
        .charactersFormat: "%d characters",
        .command: "Command",
        .configFile: "Config file",
        .configInvalid: "Config has validation errors",
        .configPreview: "Config preview",
        .configReloadedNotice: "Config was reloaded from disk. Unsaved native edits were discarded.",
        .configSummaryHelp: "Use Raw YAML for full fidelity editing. Form controls above keep the native runtime in sync with the most common fields.",
        .configValid: "Config is valid",
        .cost: "Cost",
        .disableBuiltInWebTools: "Disable Built-in Web Tools",
        .disableBuiltInWebToolsDetail: "Route search through configured RAG services.",
        .discover: "Discover",
        .discoveryTrigger: "Discovery Trigger",
        .discoveryTriggerDetail: "Run the discovery trigger in the background.",
        .dragToResize: "Drag to resize",
        .enabled: "Enabled",
        .enterName: "Enter a name.",
        .entries: "Entries",
        .entriesDetail: "Named model entries used by agents and routing.",
        .form: "Form",
        .gateway: "Gateway",
        .gatewayConfigParsed: "Gateway config parsed.",
        .gatewayDetail: "Enable external message gateway integrations.",
        .gatewayDisabled: "gateway.enabled is false.",
        .gitStatusPrompt: "Run git status to inspect the selected workspace.",
        .groupSessionsPerUser: "Group Sessions Per User",
        .groupSessionsPerUserDetail: "Keep channel sessions grouped by user.",
        .includeAssistant: "Include Assistant",
        .includeAssistantDetail: "Include assistant messages in captured memory context.",
        .keychainHelp: "Saved to Keychain; YAML apiKey stays blank for local safety.",
        .linesFormat: "%d lines",
        .mainAgent: "Main Agent",
        .memoryDisabled: "memory.enabled is false.",
        .memoryServiceEnabled: "Memory service enabled.",
        .missing: "missing",
        .modelRoutingSummary: "Model routing, token saver, request log, and cost summary.",
        .noActivePlans: "No active plans or cron jobs. Completed runs are available in Run History.",
        .noAlwaysOnRuns: "No Always-On runs have been recorded yet.",
        .noAllowedToolsConfigured: "No allowed tools configured yet.",
        .noBlockedToolsConfigured: "No blocked tools configured.",
        .noEntriesConfigured: "No model entries configured.",
        .noOutputLog: "No output log was captured for this run.",
        .noPlanContent: "No plan markdown content.",
        .noProjectSelected: "No project selected",
        .noProvidersConfigured: "No providers configured.",
        .noRoutingActivity: "No routing activity yet. Start a conversation to see stats here.",
        .noSkillsYet: "No skills yet. Click New to install or create one.",
        .nativeSettingsApplied: "Native settings are applied in process.",
        .oneShot: "one-shot",
        .pickProject: "Pick a project",
        .plansCronJobs: "Plans & Cron Jobs",
        .present: "present",
        .processEnv: "processEnv",
        .provider: "Provider",
        .providers: "Providers",
        .providersDetail: "Provider definitions used by model entries.",
        .quickAdd: "Quick add:",
        .rag: "RAG",
        .ragDetail: "Enable retrieval-augmented context.",
        .rawYAML: "Raw YAML",
        .recentRoutes: "Recent routes",
        .recurring: "recurring",
        .runtime: "Runtime",
        .models: "Models",
        .agents: "Agents",
        .reload: "Reload",
        .reloadCurrent: "Reload Current",
        .reloadDetail: "Last save and reload impact for native services.",
        .revealFile: "Reveal File",
        .reloadedCurrentConfig: "Reloaded current config",
        .remove: "Remove",
        .requests: "Requests",
        .revert: "Revert",
        .routerDashboardNative: "Router dashboard uses native records.",
        .routerDetail: "Enable model routing and token statistics.",
        .routerDisabled: "router.enabled is false.",
        .routerLog: "Log",
        .routerLogDetail: "Write router request logs for debugging.",
        .runHistory: "Run History",
        .saveAndReload: "Save & Reload",
        .savedAndReloaded: "Saved and reloaded",
        .saveShortcut: "Cmd+S save · Esc close",
        .session: "Session",
        .selectProject: "Select a project",
        .searchMemory: "Search memory",
        .storedInKeychain: "Stored in Keychain",
        .subagents: "Subagents",
        .threadSessionsPerUser: "Thread Sessions Per User",
        .threadSessionsPerUserDetail: "Thread remote sessions separately per user.",
        .tokenSaver: "Token Saver",
        .tokenSaverDetail: "Select model tier from task complexity.",
        .tokens: "Tokens",
        .unsaved: "UNSAVED",
        .unsavedChanges: "Unsaved changes",
        .user: "User",
        .workspaceMemory: "Workspace Memory",
        .feedback: "Feedback",
        .latest: "Latest",
        .none: "none",
        .noMemoryRecords: "No memory records",
        .noMemoryRecordsDetail: "Run Index or add memory files in this workspace.",
        .userSummary: "User Summary",
        .noSummaryYet: "No summary yet.",
        .generalSkillsOnly: "General chat - user-scope skills only",
        .projectSkills: "Project Skills",
        .userSkills: "User Skills",
        .pickSkill: "Pick a skill",
        .pickSkillDetail: "Select a skill on the left to view or edit its SKILL.md.",
        .scope: "Scope",
        .slug: "Slug",
        .description: "Description",
        .alphabetical: "Alphabetical",
        .gitURLHelp: "If a Git URL is provided, 9GClaw creates the target folder first and clones into it.",
        .permissionsShareDetail: "Share or back up your tool permissions as JSON.",
        .recentActivity: "Recent Activity",
        .toggle: "Toggle",
    ]

    static let chineseSimplified: [L10nKey: String] = [
        .add: "添加",
        .agent: "智能体",
        .allow: "允许",
        .allowedTools: "允许的工具",
        .allowedToolsDetail: "无需确认即可自动运行的工具。",
        .alwaysOn: "常驻",
        .appearance: "外观",
        .askPlaceholder: "询问 9GClaw",
        .attach: "添加附件",
        .attachHelp: "添加图片或文件",
        .back: "返回",
        .blockedTools: "禁用工具",
        .browse: "浏览",
        .cancel: "取消",
        .chatRunModeAgent: "智能体",
        .chatRunModeAgentDetail: "使用工具和流式输出运行智能体。",
        .chatRunModePlan: "计划",
        .chatRunModePlanDetail: "先让智能体生成计划。",
        .choosePermissionMode: "选择权限模式",
        .chooseRunMode: "选择运行模式",
        .chooseWorkspaceType: "选择工作区类型",
        .connecting: "正在连接",
        .clear: "清空",
        .codeEditor: "代码编辑器",
        .commandHelp: "运行命令",
        .complete: "完成",
        .config: "配置",
        .configureWorkspace: "配置工作区",
        .contextUsage: "上下文使用率：0%",
        .contextUsageDetail: "当前会话尚未返回 token 预算。",
        .continueAction: "继续",
        .create: "创建",
        .createNew: "新建",
        .createNewDetail: "创建新文件夹，可选从 Git 初始化。",
        .createProject: "创建项目",
        .createProjectSubtitle: "添加已有工作区或创建新文件夹。",
        .creatingProject: "正在创建项目...",
        .dashboard: "路由",
        .delete: "删除",
        .deny: "拒绝",
        .diff: "差异",
        .dismiss: "关闭",
        .displayLanguage: "显示语言",
        .displayLanguageDetail: "选择界面使用的语言。",
        .displayName: "显示名称",
        .done: "完成",
        .download: "下载",
        .exported: "已导出",
        .exportAction: "导出",
        .failed: "失败",
        .fetch: "拉取远端",
        .files: "文件",
        .general: "通用",
        .git: "Git",
        .githubURLOptional: "GitHub URL（可选）",
        .hideSidebar: "隐藏侧边栏",
        .imported: "已导入",
        .importAction: "导入",
        .index: "索引",
        .languageChineseSimplified: "简体中文",
        .languageEnglish: "English",
        .languageSystem: "跟随系统",
        .live: "运行中",
        .memory: "记忆",
        .mentionFile: "提及文件",
        .newAction: "新建",
        .newFile: "新建文件",
        .newFolder: "新建文件夹",
        .newSession: "新会话",
        .name: "名称",
        .noGeneralWorkspaceFound: "未找到通用工作区",
        .noProjectsFound: "未找到项目",
        .noSessionsYet: "暂无会话",
        .noTokenBudget: "当前会话尚未返回 token 预算。",
        .notSavedYet: "尚未保存",
        .openExisting: "打开已有项目",
        .openExistingDetail: "注册已有的本地项目文件夹。",
        .openHTML: "打开 HTML",
        .permissionAllowedFormat: "已允许 %@",
        .permissionDeniedFormat: "已拒绝 %@",
        .permissionModeBypass: "完全访问权限",
        .permissionModeBypassDetail: "允许本次运行执行受信任的工具操作。",
        .permissionModeDefault: "默认权限",
        .permissionModeDefaultDetail: "运行需要审批的工具前先询问。",
        .permissions: "权限",
        .preview: "预览",
        .processFailed: "进程失败",
        .projectAdded: "项目已添加",
        .projectDeleteUnavailable: "本轮 UI 对齐尚未实现项目删除。",
        .projectRenameUnavailable: "本轮 UI 对齐尚未实现项目重命名。",
        .projectSorting: "项目排序",
        .projects: "项目",
        .pull: "拉取",
        .push: "推送",
        .queue: "队列",
        .receivingResponse: "正在接收响应",
        .refresh: "刷新",
        .refreshProjects: "刷新项目",
        .rename: "重命名",
        .review: "确认",
        .reviewAttachedFiles: "检查附件文件。",
        .routing: "路由",
        .run: "运行",
        .runningToolFormat: "正在运行 %@",
        .saved: "已保存",
        .save: "保存",
        .send: "发送",
        .sessionDeleteUnavailable: "本轮 UI 对齐尚未实现会话删除。",
        .sessionRenameUnavailable: "本轮 UI 对齐尚未实现会话重命名。",
        .settings: "设置",
        .settingsSaved: "设置已保存",
        .shell: "Shell",
        .sessionStartedFormat: "会话 %@ 已开始",
        .showLess: "收起",
        .showMoreFormat: "显示更多（%d）",
        .showSidebar: "显示侧边栏",
        .skills: "技能",
        .status: "状态",
        .streamingAssistantOutput: "正在流式输出助手回复",
        .stopGeneration: "停止生成",
        .stopped: "已停止",
        .tasks: "任务",
        .toolError: "工具错误",
        .toolResult: "工具结果",
        .toolsFormat: "%d 个工具",
        .type: "类型",
        .uploadFiles: "上传文件...",
        .uploadFolder: "上传文件夹...",
        .welcomePrompt: "今天想处理什么？",
        .working: "处理中",
        .nativeInitialized: "原生 macOS 应用已初始化",
        .openingRemoteModelStream: "正在打开远端模型流",
        .projectsRefreshed: "项目已刷新",
        .agentStatusUpdate: "智能体状态更新",
        .aborted: "已中止",
        .ready: "就绪",
        .workspacePath: "工作区路径",
        .workspacePathDoesNotExist: "工作区路径不存在。",
        .addEntry: "添加条目",
        .addProvider: "添加 Provider",
        .allowAllUsers: "允许所有用户",
        .allowAllUsersDetail: "允许任意远程用户访问网关。",
        .alwaysOnProjectOnly: "Always-On 仅适用于项目工作区。",
        .apiKey: "API Key",
        .archive: "归档",
        .backgroundDiscoveryAgent: "此项目的后台发现智能体。",
        .cannotBeUndone: "此操作无法撤销。",
        .charactersFormat: "%d 个字符",
        .command: "命令",
        .configFile: "配置文件",
        .configInvalid: "配置存在校验错误",
        .configPreview: "配置预览",
        .configReloadedNotice: "配置已从磁盘重新加载，未保存的原生编辑已丢弃。",
        .configSummaryHelp: "使用 Raw YAML 可完整编辑配置；上方表单会让原生运行时同步常用字段。",
        .configValid: "配置有效",
        .cost: "成本",
        .disableBuiltInWebTools: "禁用内置 Web 工具",
        .disableBuiltInWebToolsDetail: "通过已配置的 RAG 服务路由搜索。",
        .discover: "发现",
        .discoveryTrigger: "发现触发器",
        .discoveryTriggerDetail: "在后台运行发现触发器。",
        .dragToResize: "拖动调整大小",
        .enabled: "启用",
        .enterName: "请输入名称。",
        .entries: "条目",
        .entriesDetail: "智能体和路由使用的命名模型条目。",
        .form: "表单",
        .gateway: "网关",
        .gatewayConfigParsed: "网关配置已解析。",
        .gatewayDetail: "启用外部消息网关集成。",
        .gatewayDisabled: "gateway.enabled 为 false。",
        .gitStatusPrompt: "运行 git status 查看当前工作区。",
        .groupSessionsPerUser: "按用户分组会话",
        .groupSessionsPerUserDetail: "按用户保持频道会话分组。",
        .includeAssistant: "包含助手消息",
        .includeAssistantDetail: "在捕获记忆上下文时包含助手消息。",
        .keychainHelp: "已保存到 Keychain；为了本机安全，YAML apiKey 保持为空。",
        .linesFormat: "%d 行",
        .mainAgent: "主智能体",
        .memoryDisabled: "memory.enabled 为 false。",
        .memoryServiceEnabled: "记忆服务已启用。",
        .missing: "缺失",
        .modelRoutingSummary: "模型路由、token saver、请求日志和成本汇总。",
        .noActivePlans: "暂无活跃计划或 Cron 任务；完成的运行在运行历史中查看。",
        .noAlwaysOnRuns: "尚未记录 Always-On 运行。",
        .noAllowedToolsConfigured: "尚未配置允许工具。",
        .noBlockedToolsConfigured: "尚未配置禁用工具。",
        .noEntriesConfigured: "尚未配置模型条目。",
        .noOutputLog: "本次运行没有捕获输出日志。",
        .noPlanContent: "没有计划 Markdown 内容。",
        .noProjectSelected: "未选择项目",
        .noProvidersConfigured: "尚未配置 Provider。",
        .noRoutingActivity: "暂无路由活动。开始对话后这里会显示统计。",
        .noSkillsYet: "暂无技能。点击新建来安装或创建技能。",
        .nativeSettingsApplied: "原生设置已应用到当前进程。",
        .oneShot: "单次",
        .pickProject: "选择一个项目",
        .plansCronJobs: "计划与 Cron 任务",
        .present: "存在",
        .processEnv: "进程环境",
        .provider: "Provider",
        .providers: "Providers",
        .providersDetail: "模型条目使用的 Provider 定义。",
        .quickAdd: "快速添加：",
        .rag: "RAG",
        .ragDetail: "启用检索增强上下文。",
        .rawYAML: "Raw YAML",
        .recentRoutes: "最近路由",
        .recurring: "重复",
        .runtime: "运行时",
        .models: "模型",
        .agents: "智能体",
        .reload: "重新加载",
        .reloadCurrent: "重新加载当前配置",
        .reloadDetail: "最近保存和重新加载对原生服务的影响。",
        .revealFile: "在访达中显示",
        .reloadedCurrentConfig: "已重新加载当前配置",
        .remove: "移除",
        .requests: "请求",
        .revert: "还原",
        .routerDashboardNative: "路由看板使用原生记录。",
        .routerDetail: "启用模型路由和 token 统计。",
        .routerDisabled: "router.enabled 为 false。",
        .routerLog: "日志",
        .routerLogDetail: "写入路由请求日志用于调试。",
        .runHistory: "运行历史",
        .saveAndReload: "保存并重新加载",
        .savedAndReloaded: "已保存并重新加载",
        .saveShortcut: "Cmd+S 保存 · Esc 关闭",
        .session: "会话",
        .selectProject: "选择项目",
        .searchMemory: "搜索记忆",
        .storedInKeychain: "已存入 Keychain",
        .subagents: "子智能体",
        .threadSessionsPerUser: "按用户拆分线程会话",
        .threadSessionsPerUserDetail: "为每个用户分别线程化远程会话。",
        .tokenSaver: "Token Saver",
        .tokenSaverDetail: "根据任务复杂度选择模型层级。",
        .tokens: "Tokens",
        .unsaved: "未保存",
        .unsavedChanges: "未保存更改",
        .user: "用户",
        .workspaceMemory: "工作区记忆",
        .feedback: "反馈",
        .latest: "最新",
        .none: "无",
        .noMemoryRecords: "暂无记忆记录",
        .noMemoryRecordsDetail: "运行索引，或在此工作区添加记忆文件。",
        .userSummary: "用户摘要",
        .noSummaryYet: "暂无摘要。",
        .generalSkillsOnly: "通用对话 - 仅显示用户级技能",
        .projectSkills: "项目技能",
        .userSkills: "用户技能",
        .pickSkill: "选择技能",
        .pickSkillDetail: "在左侧选择技能以查看或编辑 SKILL.md。",
        .scope: "范围",
        .slug: "Slug",
        .description: "描述",
        .alphabetical: "按字母排序",
        .gitURLHelp: "如果提供 Git URL，9GClaw 会先创建目标文件夹并 clone 到其中。",
        .permissionsShareDetail: "以 JSON 共享或备份工具权限。",
        .recentActivity: "最近活动",
        .toggle: "切换",
    ]
}

extension AppLanguage {
    func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> ResolvedAppLanguage {
        switch self {
        case .english:
            return .english
        case .chineseSimplified:
            return .chineseSimplified
        case .system:
            let languageCode = preferredLanguages.first?.lowercased() ?? Locale.current.identifier.lowercased()
            return languageCode.hasPrefix("zh") ? .chineseSimplified : .english
        }
    }

    func localizedLabel(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        let service = LocalizationService(language: self, preferredLanguages: preferredLanguages)
        switch self {
        case .system:
            return service.text(.languageSystem)
        case .english:
            return service.text(.languageEnglish)
        case .chineseSimplified:
            return service.text(.languageChineseSimplified)
        }
    }
}
