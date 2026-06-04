import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    var isEmbeddedInMainWindow = false
    var onReturnToApp: (() -> Void)?

    var body: some View {
        SettingsContentView(
            isEmbeddedInMainWindow: isEmbeddedInMainWindow,
            onReturnToApp: onReturnToApp
        )
            .environmentObject(state)
    }
}

private struct SettingsContentView: View {
    @EnvironmentObject private var state: AppState
    var isEmbeddedInMainWindow = false
    var onReturnToApp: (() -> Void)?
    @State private var currentPage: SettingsPage = .main
    @State private var configSection: PilotDeckConfigSection?
    @State private var savedConfigText = ""
    @State private var configMessage: String?
    @State private var configError: String?
    @State private var configExternalNotice: String?
    @State private var showConfigDetails = false
    @State private var selectedModelPoolEntry: String?
    @State private var recentlyRemovedWebProviderIDs = Set<String>()
    @State private var showCatalogProviderPicker = false
    @State private var newModelID = ""
    @State private var showAdvancedAgents = false
    @State private var showAdvancedRouter = false
    @State private var showAdvancedRuntime = false
    @State private var isTestingSearchConnection = false
    @State private var searchConnectionMessage: String?
    @State private var searchConnectionError: String?
    @State private var mcpScope: NativeMCPConfigScope = .global
    @State private var mcpDraft = NativeMCPConfigDraft.empty
    @State private var mcpProjectRoot = ""
    @State private var mcpMessage: String?
    @State private var mcpError: String?
    @State private var newCustomEnvKey = ""
    @State private var newCustomEnvValue = ""

    var body: some View {
        VStack(spacing: 0) {
            if isEmbeddedInMainWindow {
                settingsReturnBar
            }

            ScrollView {
                SettingsPageContainer(
                    title: settingsPageTitle(currentPage),
                    backLabel: currentPage == .main ? nil : state.t(.back),
                    onBack: currentPage == .main ? nil : { currentPage = .main }
                ) {
                    if let notice = state.settingsSaveNotice {
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(DesignTokens.success)
                    }
                    currentPageContent
                        .transition(.opacity.combined(with: .offset(y: 4)))
                        .id(currentPage)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .frame(
            minWidth: isEmbeddedInMainWindow ? 0 : 760,
            maxWidth: isEmbeddedInMainWindow ? .infinity : nil,
            minHeight: isEmbeddedInMainWindow ? 0 : 620,
            maxHeight: isEmbeddedInMainWindow ? .infinity : nil
        )
        .onExitCommand {
            if isEmbeddedInMainWindow {
                onReturnToApp?()
            }
        }
        .onAppear {
            currentPage = settingsPage(for: state.settingsInitialTab)
            if savedConfigText.isEmpty {
                savedConfigText = state.pilotDeckConfigText
            }
        }
        .onChange(of: state.settingsInitialTab) { _, newValue in
            currentPage = settingsPage(for: newValue)
        }
    }

    private var settingsReturnBar: some View {
        HStack {
            Button {
                onReturnToApp?()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 13, weight: .semibold))
                    Text(local(chinese: "返回应用", english: "Back to App"))
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(DesignTokens.secondaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.top, DesignTokens.sidebarContentTopPadding)
        .padding(.horizontal, 40)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingsPage(for tab: SettingsMainTab) -> SettingsPage {
        switch tab {
        case .appearance:
            return .main
        case .permissions:
            return .permissions
        case .config:
            return .config
        case .mcp:
            return .mcp
        }
    }

    private func settingsPageTitle(_ page: SettingsPage) -> String {
        switch page {
        case .main:
            return state.t(.settings)
        case .behavior:
            return local(chinese: "聊天与输入", english: "Chat & Input")
        case .codeEditor:
            return state.t(.codeEditor)
        case .permissions:
            return state.t(.permissions)
        case .config:
            return state.t(.config)
        case .mcp:
            return local(chinese: "MCP 服务器", english: "MCP Servers")
        }
    }

    private func local(chinese: String, english: String) -> String {
        state.settings.language.resolved() == .chineseSimplified ? chinese : english
    }

    private func nonBlank(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func configPathValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed.lowercased() != "null" else {
            return nil
        }
        return trimmed
    }

    private func routerModelDetail(_ id: String) -> String {
        switch id {
        case "default":
            return local(chinese: "普通请求的默认路由模型。", english: "Default route model for regular requests.")
        case "background":
            return local(chinese: "后台任务和常驻流程使用的模型。", english: "Model for background tasks and Always-on flows.")
        case "think":
            return local(chinese: "需要更强推理时使用的模型。", english: "Model used when stronger reasoning is needed.")
        case "longContext":
            return local(chinese: "长上下文请求使用的模型。", english: "Model used for long-context requests.")
        case "webSearch":
            return local(chinese: "带 Web 搜索工具的请求使用的模型。", english: "Model used for requests with web-search tools.")
        default:
            return ""
        }
    }

    private func languageOptionLabel(_ language: AppLanguage) -> String {
        switch language {
        case .system:
            return state.t(.languageSystem)
        case .english:
            return state.t(.languageEnglish)
        case .chineseSimplified:
            return state.t(.languageChineseSimplified)
        }
    }

    private func configSectionLabel(_ section: PilotDeckConfigSection) -> String {
        switch section {
        case .runtime:
            return state.t(.runtime)
        case .models:
            return state.t(.models)
        case .agents:
            return local(chinese: "智能体", english: "Agents")
        case .alwaysOn:
            return state.t(.alwaysOn)
        case .memory:
            return state.t(.memory)
        case .search:
            return state.t(.search)
        case .router:
            return state.t(.routing)
        case .gateway:
            return state.t(.gateway)
        case .customEnv:
            return local(chinese: "自定义环境变量", english: "Custom Env")
        case .raw:
            return state.t(.rawYAML)
        }
    }

    @ViewBuilder
    private var currentPageContent: some View {
        switch currentPage {
        case .main:
            mainSettingsContent
        case .behavior:
            behaviorContent
        case .codeEditor:
            codeEditorContent
        case .permissions:
            permissionsContent
        case .config:
            configContent
        case .mcp:
            mcpContent
        }
    }

    private var mainSettingsContent: some View {
        VStack(alignment: .leading, spacing: 26) {
            SettingsSectionBlock(title: local(chinese: "基础", english: "Basics")) {
                SettingsCardBlock {
                    SettingsNavigationRow(
                        systemImage: "doc.badge.gearshape",
                        title: state.t(.config),
                        detail: local(chinese: "模型、运行时、搜索、常驻等基础配置", english: "Models, runtime, Search, Always-on, and essential config")
                    ) {
                        currentPage = .config
                    }
                }
            }

            SettingsSectionBlock(title: local(chinese: "应用", english: "Application")) {
                SettingsCardBlock {
                    VStack(spacing: 0) {
                        SettingsMenuRow(
                            systemImage: "paintpalette",
                            title: state.t(.colorScheme),
                            detail: state.t(.colorSchemeDetail)
                        ) {
                            colorSchemePicker
                        }
                        SettingsCardDivider()
                        SettingsMenuRow(
                            systemImage: "globe",
                            title: state.t(.displayLanguage),
                            detail: state.t(.displayLanguageDetail)
                        ) {
                            languagePicker
                        }
                        SettingsCardDivider()
                        SettingsMenuRow(
                            systemImage: "arrow.up.arrow.down",
                            title: state.t(.projectSorting),
                            detail: state.t(.projectSortingDetail)
                        ) {
                            projectSortingPicker
                        }
                    }
                }
            }

            SettingsSectionBlock(title: local(chinese: "工作流", english: "Workflow")) {
                SettingsCardBlock {
                    VStack(spacing: 0) {
                        SettingsNavigationRow(
                            systemImage: "text.bubble",
                            title: local(chinese: "聊天与输入", english: "Chat & Input"),
                            detail: local(chinese: "工具显示、滚动行为和发送快捷键", english: "Tool display, scrolling, and send shortcut")
                        ) {
                            currentPage = .behavior
                        }
                        SettingsCardDivider()
                        SettingsNavigationRow(
                            systemImage: "chevron.left.forwardslash.chevron.right",
                            title: state.t(.codeEditor),
                            detail: local(chinese: "自动换行、行号、缩略图和字号", english: "Word wrap, line numbers, minimap, and font size")
                        ) {
                            currentPage = .codeEditor
                        }
                    }
                }
            }

            SettingsSectionBlock(title: local(chinese: "高级", english: "Advanced")) {
                SettingsCardBlock {
                    VStack(spacing: 0) {
                        SettingsNavigationRow(
                            systemImage: "server.rack",
                            title: local(chinese: "MCP 服务器", english: "MCP Servers"),
                            detail: local(chinese: "配置全局和项目 MCP 工具", english: "Configure global and project MCP tools")
                        ) {
                            currentPage = .mcp
                        }
                        SettingsCardDivider()
                        SettingsNavigationRow(
                            systemImage: "shield",
                            title: state.t(.permissions),
                            detail: local(chinese: "管理允许和禁用的工具规则", english: "Manage allowed and blocked tool rules")
                        ) {
                            currentPage = .permissions
                        }
                    }
                }
            }
        }
        .controlSize(.regular)
    }

    private var behaviorContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSectionBlock(title: state.t(.toolDisplay)) {
                SettingsCardBlock(divided: true) {
                    SettingsRowBlock(title: state.t(.autoExpandTools), detail: "") {
                        WebSettingsToggle(isOn: uiPreferenceBinding(\.autoExpandTools))
                    }
                    SettingsCardDivider()
                    SettingsRowBlock(title: state.t(.showRawParameters), detail: "") {
                        WebSettingsToggle(isOn: uiPreferenceBinding(\.showRawParameters))
                    }
                    SettingsCardDivider()
                    SettingsRowBlock(title: state.t(.showThinking), detail: "") {
                        WebSettingsToggle(isOn: uiPreferenceBinding(\.showThinking))
                    }
                }
            }

            SettingsSectionBlock(title: state.t(.viewOptions)) {
                SettingsCardBlock {
                    SettingsRowBlock(title: state.t(.autoScrollToBottom), detail: "") {
                        WebSettingsToggle(isOn: uiPreferenceBinding(\.autoScrollToBottom))
                    }
                }
            }

            SettingsSectionBlock(title: state.t(.inputSettings)) {
                SettingsCardBlock {
                    SettingsRowBlock(title: state.t(.sendByCtrlEnter), detail: state.t(.sendByCtrlEnterDetail)) {
                        WebSettingsToggle(isOn: uiPreferenceBinding(\.sendByCtrlEnter))
                    }
                }
            }
        }
        .controlSize(.regular)
    }

    private var codeEditorContent: some View {
        SettingsSectionBlock(title: state.t(.codeEditor)) {
            SettingsCardBlock(divided: true) {
                SettingsRowBlock(title: state.t(.wordWrap), detail: state.t(.wordWrapDetail)) {
                    Toggle("", isOn: $state.settings.codeEditor.wordWrap)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                SettingsCardDivider()
                SettingsRowBlock(title: state.t(.showMinimap), detail: state.t(.showMinimapDetail)) {
                    Toggle("", isOn: $state.settings.codeEditor.showMinimap)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                SettingsCardDivider()
                SettingsRowBlock(title: state.t(.lineNumbers), detail: state.t(.lineNumbersDetail)) {
                    Toggle("", isOn: $state.settings.codeEditor.lineNumbers)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                SettingsCardDivider()
                SettingsRowBlock(title: state.t(.fontSize), detail: state.t(.fontSizeDetail)) {
                    fontSizePicker
                }
            }
        }
        .controlSize(.regular)
    }

    private var colorSchemePicker: some View {
        Picker("", selection: $state.settings.colorScheme) {
            ForEach(AppColorScheme.allCases) { scheme in
                Text(colorSchemeLabel(scheme)).tag(scheme)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: NativeAppearanceSettingsLayout.colorSchemePickerWidth)
    }

    private var languagePicker: some View {
        Picker("", selection: $state.settings.language) {
            ForEach(AppLanguage.allCases) { language in
                Text(languageOptionLabel(language)).tag(language)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: NativeAppearanceSettingsLayout.languagePickerWidth)
    }

    private var projectSortingPicker: some View {
        Picker("", selection: $state.settings.projectSortOrder) {
            Text(state.t(.alphabetical)).tag(ProjectSortOrder.name)
            Text(state.t(.recentActivity)).tag(ProjectSortOrder.date)
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: NativeAppearanceSettingsLayout.projectSortingPickerWidth)
    }

    private var fontSizePicker: some View {
        Picker("", selection: $state.settings.codeEditor.fontSize) {
            ForEach(NativeAppearanceSettingsLayout.fontSizeOptions, id: \.self) { size in
                Text("\(size)px").tag(size)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 96)
    }

    private func uiPreferenceBinding(_ keyPath: WritableKeyPath<NativeUIPreferences, Bool>) -> Binding<Bool> {
        Binding(
            get: { state.uiPreferences[keyPath: keyPath] },
            set: { state.setUIPreference(keyPath, $0) }
        )
    }

    private func colorSchemeLabel(_ scheme: AppColorScheme) -> String {
        switch scheme {
        case .system:
            return state.t(.colorSchemeSystem)
        case .light:
            return state.t(.colorSchemeLight)
        case .dark:
            return state.t(.colorSchemeDark)
        }
    }

    private var permissionsContent: some View {
        VStack(alignment: .leading, spacing: 26) {
            SettingsSectionBlock(
                title: state.t(.permissions),
                detail: state.t(.permissionsManageDetail)
            ) {
                HStack(spacing: 8) {
                    Button {
                        exportPermissions()
                    } label: {
                        Label(state.t(.exportAction), systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(WebToolbarButtonStyle())
                    Button {
                        importPermissions()
                    } label: {
                        Label(state.t(.importAction), systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(WebToolbarButtonStyle())
                    Text(state.t(.permissionsShareDetail))
                        .font(.system(size: 12))
                        .foregroundStyle(DesignTokens.tertiaryText)
                }
            }

            PermissionListSection(
                title: state.t(.allowedTools),
                detail: state.t(.allowedToolsDetail),
                tint: DesignTokens.success,
                items: state.settings.permissions.allowedTools,
                quickItems: ToolPermissionSettings.quickAllowedTools,
                placeholder: state.t(.allowedToolPlaceholder),
                onAdd: state.addAllowedTool,
                onRemove: state.removeAllowedTool
            )

            PermissionListSection(
                title: state.t(.blockedTools),
                detail: state.t(.blockedToolsDetail),
                tint: DesignTokens.danger,
                items: state.settings.permissions.disallowedTools,
                quickItems: ToolPermissionSettings.quickBlockedTools,
                placeholder: state.t(.blockedToolPlaceholder),
                onAdd: state.addBlockedTool,
                onRemove: state.removeBlockedTool
            )

            SettingsSectionBlock(title: state.t(.patternExamples)) {
                SettingsCardBlock {
                    VStack(alignment: .leading, spacing: 8) {
                        CodeExample("Bash(git log:*)", state.t(.allowAllGitLogCommands))
                        CodeExample("Bash(git diff:*)", state.t(.allowAllGitDiffCommands))
                        CodeExample("Write", state.t(.allowAllWrites))
                        CodeExample("Bash(rm:*)", state.t(.blockAllRmCommands))
                    }
                    .padding(14)
                }
            }
        }
    }

    private var mcpContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionBlock(
                title: local(chinese: "MCP 服务器", english: "MCP Servers"),
                detail: local(
                    chinese: "通过全局或项目 JSON 配置 MCP 工具。同名项目服务器会覆盖全局服务器。",
                    english: "Configure MCP tools with global or project JSON. Project servers override global servers with the same name."
                )
            ) {
                SettingsCardBlock(divided: true) {
                    SettingsRowBlock(
                        title: local(chinese: "作用域", english: "Scope"),
                        detail: mcpScope == .global
                            ? local(chinese: "全局 MCP 会在所有项目中可用。", english: "Global MCP servers are available to every project.")
                            : local(chinese: "项目 MCP 只对选中的项目生效。", english: "Project MCP servers only apply to the selected project.")
                    ) {
                        Picker("", selection: $mcpScope) {
                            Text(local(chinese: "全局", english: "Global")).tag(NativeMCPConfigScope.global)
                            Text(local(chinese: "项目", english: "Project")).tag(NativeMCPConfigScope.project)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 190)
                    }
                    if mcpScope == .project {
                        SettingsCardDivider()
                        SettingsRowBlock(
                            title: state.t(.projects),
                            detail: local(chinese: "选择要编辑 `.pilotdeck/mcp.json` 的项目。", english: "Choose the project whose `.pilotdeck/mcp.json` should be edited.")
                        ) {
                            Picker("", selection: $mcpProjectRoot) {
                                ForEach(mcpProjectOptions, id: \.root) { item in
                                    Text(item.name).tag(item.root)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 260)
                            .disabled(mcpProjectOptions.isEmpty)
                        }
                    }
                }
            }

            SettingsSectionBlock(title: local(chinese: "配置文件", english: "Config File")) {
                SettingsCardBlock {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "server.rack")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(DesignTokens.tertiaryText)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(mcpDraft.exists ? local(chinese: "已存在", english: "Existing config") : local(chinese: "尚未创建", english: "Not created yet"))
                                    .font(.system(size: 13, weight: .semibold))
                                Text(mcpDraft.path)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(DesignTokens.tertiaryText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(DesignTokens.neutral100, in: RoundedRectangle(cornerRadius: 5))
                            }
                        }
                        HStack(spacing: 8) {
                            Button {
                                revealMCPConfigFile()
                            } label: {
                                Label(state.t(.revealFile), systemImage: "folder")
                            }
                            .buttonStyle(WebToolbarButtonStyle())
                            Button {
                                loadMCPConfig()
                            } label: {
                                Label(state.t(.refresh), systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(WebToolbarButtonStyle())
                            Spacer()
                            Button {
                                saveMCPConfig()
                            } label: {
                                Label(local(chinese: "保存 MCP", english: "Save MCP"), systemImage: "square.and.arrow.down")
                            }
                            .buttonStyle(WebToolbarButtonStyle(isProminent: true))
                            .disabled(mcpScope == .project && mcpProjectRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(14)
                }
            }

            if let mcpError {
                NoticeBanner(text: mcpError, tint: DesignTokens.danger) {
                    self.mcpError = nil
                }
            }
            if let mcpMessage {
                NoticeBanner(text: mcpMessage, tint: DesignTokens.success) {
                    self.mcpMessage = nil
                }
            }

            SettingsSectionBlock(
                title: local(chinese: "服务器", english: "Servers"),
                detail: local(chinese: "支持 STDIO 和 HTTP MCP 服务器。", english: "Supports STDIO and HTTP MCP servers.")
            ) {
                SettingsCardBlock {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text(local(chinese: "\(mcpDraft.servers.count) 个服务器", english: "\(mcpDraft.servers.count) servers"))
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Button {
                                addMCPServer(.stdio)
                            } label: {
                                Label("STDIO", systemImage: "plus")
                            }
                            .buttonStyle(WebToolbarButtonStyle())
                            Button {
                                addMCPServer(.http)
                            } label: {
                                Label("HTTP", systemImage: "plus")
                            }
                            .buttonStyle(WebToolbarButtonStyle())
                        }

                        if mcpDraft.servers.isEmpty {
                            dashedEmpty(local(chinese: "暂无 MCP 服务器。", english: "No MCP servers configured."))
                        } else {
                            VStack(spacing: 12) {
                                ForEach($mcpDraft.servers) { $server in
                                    mcpServerCard(server: $server)
                                }
                            }
                        }

                        DisclosureGroup {
                            TextEditor(text: mcpRawJSONBinding)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(minHeight: 240)
                                .scrollContentBackground(.hidden)
                                .background(DesignTokens.neutral50, in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius))
                                .overlay(RoundedRectangle(cornerRadius: DesignTokens.smallRadius).stroke(DesignTokens.separator))
                                .padding(.top, 8)
                        } label: {
                            SettingsFieldLabel(
                                title: local(chinese: "高级 JSON", english: "Advanced JSON"),
                                detail: local(chinese: "直接编辑原始 `mcpServers` JSON。", english: "Edit the raw `mcpServers` JSON directly.")
                            )
                        }
                    }
                    .padding(14)
                }
            }
        }
        .onAppear {
            ensureMCPProjectRoot()
            loadMCPConfig()
        }
        .onChange(of: mcpScope) { _, _ in
            ensureMCPProjectRoot()
            loadMCPConfig()
        }
        .onChange(of: mcpProjectRoot) { _, _ in
            guard mcpScope == .project else { return }
            loadMCPConfig()
        }
        .onChange(of: mcpDraft.servers) { _, _ in
            syncMCPRawFromServers()
        }
    }

    private func mcpServerCard(server: Binding<NativeMCPServerDraft>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    TextField(local(chinese: "服务器名称", english: "Server name"), text: server.name)
                        .textFieldStyle(.roundedBorder)
                    Text(mcpServerSummary(server.wrappedValue))
                        .font(.system(size: 11))
                        .foregroundStyle(DesignTokens.tertiaryText)
                        .lineLimit(1)
                }
                Picker("", selection: server.transport) {
                    Text("STDIO").tag(NativeMCPTransport.stdio)
                    Text("HTTP").tag(NativeMCPTransport.http)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 150)
                Button {
                    removeMCPServer(server.wrappedValue.id)
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(SettingsIconButtonStyle())
                .foregroundStyle(DesignTokens.danger)
            }

            if server.wrappedValue.transport == .stdio {
                ConfigGrid {
                    SettingsTextField(local(chinese: "命令", english: "Command"), text: server.command)
                }
                SettingsTextArea(local(chinese: "参数（每行一个）", english: "Args (one per line)"), text: server.argsText)
                SettingsTextArea(local(chinese: "环境变量 KEY=VALUE", english: "Env KEY=VALUE"), text: server.envText)
                SettingsRowBlock(
                    title: "Per-session",
                    detail: local(chinese: "为每个会话独立启动 MCP 进程。", english: "Start a separate MCP process for each session.")
                ) {
                    WebSettingsToggle(isOn: server.perSession)
                }
            } else {
                ConfigGrid {
                    SettingsTextField("URL", text: server.url)
                }
                SettingsTextArea(local(chinese: "Headers KEY=VALUE", english: "Headers KEY=VALUE"), text: server.headersText)
            }
        }
        .padding(12)
        .background(DesignTokens.neutral50.opacity(0.8), in: RoundedRectangle(cornerRadius: DesignTokens.radius))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.radius).stroke(DesignTokens.separator))
    }

    private var mcpProjectOptions: [(name: String, root: String)] {
        state.projects
            .filter { !state.isGeneralProject($0) }
            .map { project in
                (
                    name: project.displayName,
                    root: state.effectiveWorkspacePath(for: project)
                )
            }
            .filter { !$0.root.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var mcpRawJSONBinding: Binding<String> {
        Binding(
            get: { mcpDraft.rawJSON },
            set: { value in
                mcpDraft.rawJSON = value
                do {
                    let parsed = try NativeMCPConfigService.parse(raw: value, path: mcpDraft.path, exists: mcpDraft.exists)
                    mcpDraft.servers = parsed.servers
                    mcpError = nil
                } catch {
                    mcpError = error.localizedDescription
                }
            }
        )
    }

    private func ensureMCPProjectRoot() {
        guard mcpScope == .project else { return }
        let options = mcpProjectOptions
        if !options.contains(where: { $0.root == mcpProjectRoot }) {
            mcpProjectRoot = options.first?.root ?? ""
        }
    }

    private func loadMCPConfig() {
        do {
            ensureMCPProjectRoot()
            mcpDraft = try NativeMCPConfigService.load(scope: mcpScope, projectRoot: mcpProjectRoot)
            mcpError = nil
            mcpMessage = nil
        } catch {
            mcpDraft = NativeMCPConfigService.emptyDraft(scope: mcpScope, projectRoot: mcpProjectRoot)
            mcpError = error.localizedDescription
        }
    }

    private func saveMCPConfig() {
        do {
            ensureMCPProjectRoot()
            mcpDraft = try NativeMCPConfigService.save(raw: mcpDraft.rawJSON, scope: mcpScope, projectRoot: mcpProjectRoot)
            mcpError = nil
            mcpMessage = local(chinese: "MCP 配置已保存。", english: "MCP config saved.")
        } catch {
            mcpError = error.localizedDescription
        }
    }

    private func revealMCPConfigFile() {
        let url = NativeMCPConfigService.configURL(scope: mcpScope, projectRoot: mcpProjectRoot)
        guard !url.path.isEmpty else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }

    private func syncMCPRawFromServers() {
        do {
            let nextRaw = try NativeMCPConfigService.rawJSON(servers: mcpDraft.servers)
            if nextRaw != mcpDraft.rawJSON {
                mcpDraft.rawJSON = nextRaw
            }
            mcpError = nil
        } catch {
            mcpError = error.localizedDescription
        }
    }

    private func addMCPServer(_ transport: NativeMCPTransport) {
        let existing = Set(mcpDraft.servers.map(\.name))
        let base = transport == .stdio ? "new-stdio-server" : "new-http-server"
        var name = base
        var index = 2
        while existing.contains(name) {
            name = "\(base)-\(index)"
            index += 1
        }
        mcpDraft.servers.append(NativeMCPServerDraft.template(name: name, transport: transport))
    }

    private func removeMCPServer(_ id: UUID) {
        mcpDraft.servers.removeAll { $0.id == id }
    }

    private func mcpServerSummary(_ server: NativeMCPServerDraft) -> String {
        switch server.transport {
        case .stdio:
            var parts: [String] = []
            let command = server.command.trimmingCharacters(in: .whitespacesAndNewlines)
            if !command.isEmpty {
                parts.append(command)
            }
            let firstArg = server.argsText
                .split(separator: "\n")
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !firstArg.isEmpty {
                parts.append(firstArg)
            }
            return parts.isEmpty ? "STDIO" : parts.joined(separator: " ")
        case .http:
            let url = server.url.trimmingCharacters(in: .whitespacesAndNewlines)
            return url.isEmpty ? "HTTP" : url
        }
    }

    private var configContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            configHeaderCard

            if let configExternalNotice {
                NoticeBanner(text: configExternalNotice, tint: DesignTokens.warning) {
                    self.configExternalNotice = nil
                }
            }
            if let configError {
                NoticeBanner(text: configError, tint: DesignTokens.danger) {
                    self.configError = nil
                }
            }
            if let configMessage {
                NoticeBanner(text: configMessage, tint: DesignTokens.success) {
                    self.configMessage = nil
                }
            }

            if configSection == nil {
                configSectionHome
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    Button {
                        configSection = nil
                    } label: {
                        Label(local(chinese: "返回服务配置", english: "Back to service config"), systemImage: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DesignTokens.tertiaryText)

                    configSectionContent
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    private var configHeaderCard: some View {
        SettingsCardBlock {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Button {
                        showConfigDetails.toggle()
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "doc.badge.gearshape")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(DesignTokens.tertiaryText)
                                .frame(width: 22)
                                .padding(.top, 1)
                            VStack(alignment: .leading, spacing: 8) {
                                Text(configFileURL().path.isEmpty ? state.t(.configPreview) : state.t(.configFile))
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(DesignTokens.text)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(configFileURL().path)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(DesignTokens.tertiaryText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(DesignTokens.neutral100, in: RoundedRectangle(cornerRadius: 5))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 8)
                    let validation = validateConfig()
                    Text(validation.valid ? (isConfigDirty ? state.t(.unsavedChanges) : local(chinese: "无未保存更改", english: "No unsaved changes")) : state.t(.configInvalid))
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .foregroundStyle(validation.valid ? DesignTokens.tertiaryText : DesignTokens.danger)
                        .background(validation.valid ? DesignTokens.neutral100 : DesignTokens.danger.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                    Button {
                        saveConfigAndReload()
                    } label: {
                        Label(local(chinese: "保存并重载", english: "Save & Reload"), systemImage: "externaldrive.badge.checkmark")
                            .lineLimit(1)
                    }
                    .buttonStyle(WebToolbarButtonStyle(isProminent: true))
                    .disabled(!validation.valid || !isConfigDirty)
                    Button {
                        showConfigDetails.toggle()
                    } label: {
                        Image(systemName: showConfigDetails ? "chevron.up" : "chevron.down")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(SettingsIconButtonStyle())
                }

                if showConfigDetails {
                    HStack(spacing: 8) {
                        Button {
                            revealConfigFile()
                        } label: {
                            Label(state.t(.revealFile), systemImage: "folder")
                                .lineLimit(1)
                        }
                        .buttonStyle(WebToolbarButtonStyle())
                        Button {
                            importConfigFile()
                        } label: {
                            Label(state.t(.importAction), systemImage: "square.and.arrow.down")
                                .lineLimit(1)
                        }
                        .buttonStyle(WebToolbarButtonStyle())
                        Button {
                            exportConfigFile()
                        } label: {
                            Label(state.t(.exportAction), systemImage: "square.and.arrow.up")
                                .lineLimit(1)
                        }
                        .buttonStyle(WebToolbarButtonStyle())
                        Spacer(minLength: 8)
                    }
                    Divider()
                    configStatusOverview
                }
            }
            .padding(14)
        }
    }

    private var configStatusOverview: some View {
        let validation = validateConfig()
        return VStack(alignment: .leading, spacing: 10) {
            configStatusItem(
                title: validation.valid ? state.t(.configValid) : state.t(.configInvalid),
                detail: isConfigDirty ? state.t(.unsavedChanges) : nil,
                tint: validation.valid ? DesignTokens.success : DesignTokens.danger
            )
            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 190), spacing: 10),
                ],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(NativeConfigReloadSummary.subsystems) { subsystem in
                    let isReloaded = reloadSummaryIsReloaded(subsystem)
                    configStatusItem(
                        title: state.t(subsystem.label),
                        detail: reloadSummaryDetail(subsystem),
                        tint: isReloaded ? DesignTokens.success : DesignTokens.neutral400
                    )
                }
            }
            if !validation.errors.isEmpty || !validation.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(validation.errors, id: \.self) { item in
                        Text("• \(item)")
                            .font(.system(size: 12))
                            .foregroundStyle(DesignTokens.danger)
                    }
                    ForEach(validation.warnings, id: \.self) { item in
                        Text("• \(item)")
                            .font(.system(size: 12))
                            .foregroundStyle(DesignTokens.warning)
                    }
                }
            }
        }
    }

    private func configStatusItem(title: String, detail: String?, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignTokens.text)
                    .lineLimit(1)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(DesignTokens.tertiaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.neutral50.opacity(0.8), in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius))
    }

    private var configSectionSidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(NativeConfigFormLayout.sectionOrder) { section in
                Button {
                    configSection = section
                } label: {
                    Text(configSectionLabel(section))
                        .font(.system(size: 13, weight: configSection == section ? .semibold : .regular))
                        .foregroundStyle(configSection == section ? DesignTokens.text : DesignTokens.tertiaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(configSection == section ? DesignTokens.neutral100 : Color.clear, in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius))
                        .contentShape(RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: NativeConfigFormLayout.sectionNavigationWidth)
        .padding(6)
        .background(DesignTokens.neutral50.opacity(0.7), in: RoundedRectangle(cornerRadius: DesignTokens.radius))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.radius).stroke(DesignTokens.separator))
    }

    private var configSectionHome: some View {
        VStack(alignment: .leading, spacing: 22) {
            configSectionGroup(
                title: local(chinese: "基础", english: "Basic"),
                detail: local(chinese: "先配置模型池，再把模型分配给智能体。", english: "Configure model providers first, then assign models to agents."),
                sections: [.models, .agents]
            )
            configSectionGroup(
                title: local(chinese: "功能", english: "Features"),
                detail: nil,
                sections: [.router, .memory, .search, .alwaysOn, .gateway]
            )
            configSectionGroup(
                title: local(chinese: "高级", english: "Advanced"),
                detail: nil,
                sections: [.runtime, .customEnv]
            )
        }
    }

    private func configSectionGroup(title: String, detail: String?, sections: [PilotDeckConfigSection]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DesignTokens.text)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(DesignTokens.tertiaryText)
                }
            }
            SettingsCardBlock(divided: true) {
                ForEach(sections) { section in
                    Button {
                        configSection = section
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: configSectionIcon(section))
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(DesignTokens.tertiaryText)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(configSectionLabel(section))
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(DesignTokens.text)
                                Text(configSectionDescription(section))
                                    .font(.system(size: 12))
                                    .foregroundStyle(DesignTokens.tertiaryText)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(DesignTokens.tertiaryText)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func configSectionIcon(_ section: PilotDeckConfigSection) -> String {
        switch section {
        case .runtime: return "server.rack"
        case .models: return "externaldrive"
        case .agents: return "bubble.left.and.bubble.right"
        case .alwaysOn: return "dot.radiowaves.left.and.right"
        case .memory: return "archivebox"
        case .search: return "magnifyingglass"
        case .router: return "point.3.connected.trianglepath.dotted"
        case .gateway: return "network"
        case .customEnv: return "curlybraces"
        case .raw: return "doc.plaintext"
        }
    }

    private func configSectionDescription(_ section: PilotDeckConfigSection) -> String {
        switch section {
        case .runtime:
            return state.t(.runtimeDetail)
        case .models:
            return local(chinese: "配置想使用的模型提供商、API 密钥、接口地址与启用模型。", english: "Configure providers, API keys, endpoints, and enabled models.")
        case .agents:
            return local(chinese: "为主智能体和子智能体选择默认模型。", english: "Choose default models for the main agent and subagents.")
        case .alwaysOn:
            return local(chinese: "配置后台发现、触发节奏、休眠与项目启用范围。", english: "Configure discovery, cadence, dormancy, and project opt-in.")
        case .memory:
            return local(chinese: "配置记忆开关、记忆模型，以及导入导出。", english: "Configure memory, its model, and import/export.")
        case .search:
            return state.t(.searchSectionDetail)
        case .router:
            return state.t(.routerDetail)
        case .gateway:
            return state.t(.gatewayDetail)
        case .customEnv:
            return local(chinese: "维护传给运行时和工具的自定义环境变量。", english: "Manage custom environment variables for runtime and tools.")
        case .raw:
            return ""
        }
    }

    @ViewBuilder
    private var configSectionContent: some View {
        if let configSection {
        switch configSection {
        case .runtime:
            VStack(alignment: .leading, spacing: 18) {
                SettingsSectionBlock(title: state.t(.runtime), detail: state.t(.runtimeDetail)) {
                    SettingsCardBlock(divided: true) {
                        SettingsRowBlock(
                            title: state.t(.workspacesRoot),
                            detail: local(chinese: "新项目默认创建位置。", english: "Default location for new projects.")
                        ) {
                            SettingsTextField(state.t(.workspacesRoot), text: Binding(
                                get: { state.settings.workspacesRoot },
                                set: { value in
                                    state.settings.workspacesRoot = value
                                    setConfigValue(NativeRuntimeConfigFormFields.workspacesRootPath, value)
                                }
                            ))
                            .frame(width: 340)
                        }
                        SettingsCardDivider()
                        SettingsRowBlock(
                            title: state.t(.generalWorkspace),
                            detail: local(chinese: "通用对话使用的本地工作目录。", english: "Local workspace used by General chat.")
                        ) {
                            SettingsTextField(state.t(.generalWorkspace), text: Binding(
                                get: { state.settings.generalWorkspacePath },
                                set: { value in
                                    state.settings.generalWorkspacePath = value
                                    setConfigValue(NativeRuntimeConfigFormFields.generalWorkspacePath, value)
                                }
                            ))
                            .frame(width: 340)
                        }
                    }
                }
                Button {
                    showAdvancedRuntime.toggle()
                } label: {
                    Label(local(chinese: "高级运行时", english: "Advanced runtime"), systemImage: showAdvancedRuntime ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignTokens.tertiaryText)
                if showAdvancedRuntime {
                    SettingsCardBlock(divided: true) {
                        ConfigGrid {
                            ForEach(NativeRuntimeConfigFormFields.textFields) { field in
                                SettingsTextField(state.t(field.label), text: configBinding(field.path))
                            }
                        }
                        .padding(14)
                    }
                }
            }
        case .models:
            modelsConfigContent
        case .agents:
            agentsConfigContent
        case .alwaysOn:
            VStack(alignment: .leading, spacing: 18) {
                SettingsSectionBlock(
                    title: state.t(.alwaysOn),
                    detail: local(
                        chinese: "配置后台发现的开关、节奏、休眠、执行保护和项目范围。",
                        english: "Configure background discovery, cadence, dormancy, execution guards, and project scope."
                    )
                ) {
                    SettingsCardBlock(divided: true) {
                        SettingsRowBlock(
                            title: state.t(.enabled),
                            detail: local(
                                chinese: "总开关。关闭后不会启动任何 Always-On 调度。",
                                english: "Master switch. When off, no Always-On scheduler runs."
                            )
                        ) {
                            WebSettingsToggle(isOn: configBoolBinding(NativeAlwaysOnConfigFormFields.enabledPath))
                        }
                    }
                }

                if configBool(NativeAlwaysOnConfigFormFields.enabledPath) {
                    SettingsSectionBlock(
                        title: local(chinese: "触发", english: "Trigger"),
                        detail: local(chinese: "控制自动发现的触发频率、冷却时间和预算。", english: "Control discovery cadence, cooldown, and budget.")
                    ) {
                        SettingsCardBlock(divided: true) {
                            SettingsRowBlock(
                                title: local(chinese: "自动发现", english: "Auto Discovery"),
                                detail: state.t(.discoveryTriggerDetail)
                            ) {
                                WebSettingsToggle(isOn: configBoolBinding(NativeAlwaysOnConfigFormFields.triggerEnabledPath))
                            }
                            ConfigGrid {
                                ForEach(NativeAlwaysOnConfigFormFields.triggerFields) { field in
                                    SettingsTextField(
                                        local(chinese: field.chineseLabel, english: field.englishLabel),
                                        text: configBinding(field.path)
                                    )
                                }
                                SettingsPickerField(
                                    local(chinese: "偏好通道", english: "Prefer Channel"),
                                    selection: configBinding("alwaysOn.trigger.preferChannel", fallback: "web"),
                                    options: ["web", "tui"],
                                    emptyLabel: "web"
                                )
                            }
                            .padding(14)
                        }
                    }

                    SettingsSectionBlock(
                        title: local(chinese: "休眠", english: "Dormancy"),
                        detail: local(chinese: "文件变化检测的防抖和忽略规则。", english: "Debounce and ignore rules for filesystem activity.")
                    ) {
                        SettingsCardBlock(divided: true) {
                            SettingsRowBlock(
                                title: state.t(.enabled),
                                detail: local(chinese: "开启后会忽略频繁抖动和不重要文件。", english: "When on, noisy and irrelevant filesystem changes are ignored.")
                            ) {
                                WebSettingsToggle(isOn: configBoolBinding("alwaysOn.dormancy.enabled", defaultValue: true))
                            }
                            ConfigGrid {
                                SettingsTextField(
                                    local(chinese: "防抖（毫秒）", english: "Debounce (ms)"),
                                    text: configBinding("alwaysOn.dormancy.debounceMs")
                                )
                                SettingsTextArea(
                                    local(chinese: "忽略规则（每行一个）", english: "Ignore globs (one per line)"),
                                    text: configArrayTextBinding("alwaysOn.dormancy.ignoreGlobs")
                                )
                            }
                            .padding(14)
                        }
                    }

                    SettingsSectionBlock(
                        title: local(chinese: "工作区", english: "Workspace"),
                        detail: local(chinese: "隔离工作区和快照的位置与限制。", english: "Isolation workspace and snapshot locations and limits.")
                    ) {
                        SettingsCardBlock {
                            ConfigGrid {
                                ForEach(NativeAlwaysOnConfigFormFields.workspaceFields) { field in
                                    SettingsTextField(
                                        local(chinese: field.chineseLabel, english: field.englishLabel),
                                        text: configBinding(field.path)
                                    )
                                }
                                webSettingsToggleRow(
                                    title: local(chinese: "Git LFS", english: "Git LFS"),
                                    detail: local(chinese: "复制工作区时保留 Git LFS 行为。", english: "Preserve Git LFS behavior when preparing workspaces."),
                                    isOn: configBoolBinding("alwaysOn.workspace.gitLfs")
                                )
                            }
                            .padding(14)
                        }
                    }

                    SettingsSectionBlock(
                        title: local(chinese: "执行", english: "Execution"),
                        detail: local(chinese: "限制后台任务的轮次、工具调用和超时时间。", english: "Limit background turns, tool calls, and timeout.")
                    ) {
                        SettingsCardBlock {
                            ConfigGrid {
                                ForEach(NativeAlwaysOnConfigFormFields.executionFields) { field in
                                    SettingsTextField(
                                        local(chinese: field.chineseLabel, english: field.englishLabel),
                                        text: configBinding(field.path)
                                    )
                                }
                            }
                            .padding(14)
                        }
                    }

                    SettingsSectionBlock(
                        title: state.t(.projects),
                        detail: local(chinese: "选择哪些项目允许 Always-On 后台发现。", english: "Choose which projects can run Always-On discovery.")
                    ) {
                        SettingsCardBlock(divided: true) {
                            if alwaysOnProjectRows.isEmpty {
                                Text(state.t(.noProjectsFound))
                                    .font(.system(size: 13))
                                    .foregroundStyle(DesignTokens.tertiaryText)
                                    .padding(16)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                ForEach(alwaysOnProjectRows) { project in
                                    let root = AlwaysOnProjectConfig.projectRoot(state.effectiveWorkspacePath(for: project))
                                    SettingsRowBlock(title: project.displayName, detail: root) {
                                        WebSettingsToggle(isOn: alwaysOnProjectEnabledBinding(root: root))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        case .memory:
            VStack(alignment: .leading, spacing: 18) {
                SettingsSectionBlock(
                    title: state.t(.memory),
                    detail: local(
                        chinese: "配置记忆开关与记忆专用模型。导入导出用于备份和迁移。",
                        english: "Configure memory and its model. Import/export is for backup and migration."
                    )
                ) {
                    SettingsCardBlock(divided: true) {
                        SettingsRowBlock(title: state.t(.enabled), detail: state.t(.memoryDetail)) {
                            WebSettingsToggle(isOn: configBoolBinding(NativeMemoryConfigFormFields.enabledPath))
                        }
                        if configBool(NativeMemoryConfigFormFields.enabledPath) {
                            SettingsCardDivider()
                            SettingsRowBlock(
                                title: local(chinese: "记忆模型", english: "Memory Model"),
                                detail: local(chinese: "记忆检索、索引和 Dream 可继承主智能体模型。", english: "Recall, Index, and Dream can inherit the main agent model.")
                            ) {
                                modelAssignmentPicker(path: NativeMemoryConfigFormFields.modelPath, includeInherit: true)
                            }
                        }
                    }
                }
                SettingsSectionBlock(
                    title: local(chinese: "导入与导出", english: "Import & Export"),
                    detail: local(chinese: "备份或迁移当前项目记忆，也可以导入/导出完整记忆库。", english: "Back up or migrate the current project memory, or move the full memory library.")
                ) {
                    SettingsCardBlock(divided: true) {
                        SettingsRowBlock(
                            title: local(chinese: "当前项目记忆", english: "Current Project Memory"),
                            detail: selectedMemoryProjectDetail()
                        ) {
                            HStack(spacing: 8) {
                                Button {
                                    importMemoryBundle(scope: .currentProject)
                                } label: {
                                    Label(state.t(.importAction), systemImage: "square.and.arrow.down")
                                }
                                .buttonStyle(WebToolbarButtonStyle())
                                .disabled(selectedMemoryProjectTarget() == nil)

                                Button {
                                    exportMemoryBundle(scope: .currentProject)
                                } label: {
                                    Label(state.t(.exportAction), systemImage: "square.and.arrow.up")
                                }
                                .buttonStyle(WebToolbarButtonStyle(isProminent: true))
                                .disabled(selectedMemoryProjectTarget() == nil)

                                Button(role: .destructive) {
                                    clearMemory(scope: .currentProject)
                                } label: {
                                    Label(local(chinese: "清除", english: "Clear"), systemImage: "trash")
                                }
                                .buttonStyle(WebToolbarButtonStyle(tint: DesignTokens.danger))
                                .disabled(selectedMemoryProjectTarget() == nil)
                            }
                        }
                        SettingsCardDivider()
                        SettingsRowBlock(
                            title: local(chinese: "所有记忆", english: "All Memory"),
                            detail: local(chinese: "包含用户/全局记忆，以及 PilotDeck 当前已知的项目记忆。", english: "Includes user/global memory and project memory currently known to PilotDeck.")
                        ) {
                            HStack(spacing: 8) {
                                Button {
                                    importMemoryBundle(scope: .allMemory)
                                } label: {
                                    Label(state.t(.importAction), systemImage: "square.and.arrow.down")
                                }
                                .buttonStyle(WebToolbarButtonStyle())

                                Button {
                                    exportMemoryBundle(scope: .allMemory)
                                } label: {
                                    Label(state.t(.exportAction), systemImage: "square.and.arrow.up")
                                }
                                .buttonStyle(WebToolbarButtonStyle(isProminent: true))

                                Button(role: .destructive) {
                                    clearMemory(scope: .allMemory)
                                } label: {
                                    Label(local(chinese: "清除", english: "Clear"), systemImage: "trash")
                                }
                                .buttonStyle(WebToolbarButtonStyle(tint: DesignTokens.danger))
                            }
                        }
                    }
                }
            }
        case .search:
            VStack(alignment: .leading, spacing: 18) {
                SettingsSectionBlock(title: state.t(.search), detail: state.t(.searchSectionDetail)) {
                    VStack(alignment: .leading, spacing: 16) {
                        SettingsCardBlock(divided: true) {
                            SettingsRowBlock(title: state.t(.provider), detail: state.t(.searchProviderDetail)) {
                                SettingsPickerField(
                                    state.t(.provider),
                                    selection: searchProviderBinding(),
                                    options: NativeSearchConfigFormFields.providerOptions,
                                    emptyLabel: "glm",
                                    optionLabel: NativeSearchConfigFormFields.providerLabel
                                )
                            }
                            ConfigGrid {
                                ForEach(NativeSearchConfigFormFields.essentialFields) { field in
                                    SettingsTextField(
                                        state.t(field.label),
                                        text: configBinding(field.path),
                                        isSecure: field.isSecure
                                    )
                                }
                            }
                            .padding(14)
                            SettingsCardDivider()
                            HStack(alignment: .center, spacing: 10) {
                                Button {
                                    testSearchConnection()
                                } label: {
                                    Label(
                                        isTestingSearchConnection
                                            ? state.t(.connecting)
                                            : local(chinese: "测试连接", english: "Test Connection"),
                                        systemImage: "arrow.clockwise"
                                    )
                                }
                                .buttonStyle(WebToolbarButtonStyle())
                                .disabled(isTestingSearchConnection)

                                if let searchConnectionMessage {
                                    Text(searchConnectionMessage)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(DesignTokens.success)
                                        .lineLimit(2)
                                } else if let searchConnectionError {
                                    Text(searchConnectionError)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(DesignTokens.danger)
                                        .lineLimit(2)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                        }
                        if configValue(NativeSearchConfigFormFields.providerPath) == "custom" {
                            SettingsCardBlock(divided: true) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(state.t(.customProvider))
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(DesignTokens.text)
                                    Text(state.t(.customProviderDetail))
                                        .font(.system(size: 11))
                                        .foregroundStyle(DesignTokens.tertiaryText)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)

                                ConfigGrid {
                                    ForEach(NativeSearchConfigFormFields.customFields) { field in
                                        SettingsTextField(
                                            state.t(field.label),
                                            text: configBinding(field.path),
                                            isSecure: field.isSecure
                                        )
                                    }
                                }
                                .padding(14)
                            }
                        }
                    }
                }
            }
        case .router:
            routerSettingsContent
        case .gateway:
            VStack(alignment: .leading, spacing: 18) {
                SettingsSectionBlock(title: state.t(.gateway)) {
                    SettingsCardBlock(divided: true) {
                        SettingsRowBlock(title: state.t(.enabled), detail: state.t(.gatewayDetail)) {
                            WebSettingsToggle(isOn: configBoolBinding(NativeGatewayConfigFormFields.enabledPath))
                        }
                        if configBool(NativeGatewayConfigFormFields.enabledPath) {
                            ConfigGrid {
                                SettingsTextField(state.t(.home), text: configBinding(NativeGatewayConfigFormFields.homePath))
                            }
                            .padding(14)
                        }
                    }
                }
            }
        case .customEnv:
            customEnvSettingsContent
        case .raw:
            EmptyView()
        }
        } else {
            EmptyView()
        }
    }

    private var modelsConfigContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionBlock(
                title: local(chinese: "模型池", english: "Model Pool"),
                detail: local(chinese: "配置想使用的模型提供商、API 密钥、接口地址与启用模型。智能体、记忆和路由会从这里选择。", english: "Configure providers, API keys, endpoints, and enabled models. Agents, memory, and router choose from this pool.")
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        showCatalogProviderPicker.toggle()
                    } label: {
                        Label(local(chinese: "添加提供商", english: "Add Provider"), systemImage: "plus")
                    }
                    .buttonStyle(WebToolbarButtonStyle())

                    if showCatalogProviderPicker {
                        catalogProviderPickerCard
                    }

                    if webProviderIDs.isEmpty {
                        dashedEmpty(local(chinese: "暂无模型提供商。", english: "No model providers yet."))
                    } else {
                        ForEach(webProviderIDs, id: \.self) { provider in
                            webProviderCard(provider)
                        }
                    }
                }
            }
        }
    }

    private var agentsConfigContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionBlock(
                title: local(chinese: "智能体", english: "Agents"),
                detail: local(
                    chinese: "选择主智能体和子智能体默认模型。模型连接统一从模型池维护。",
                    english: "Choose main and subagent models. Model connections are managed in the model pool."
                )
            ) {
                SettingsCardBlock(divided: true) {
                    SettingsRowBlock(
                        title: state.t(.mainAgent),
                        detail: local(chinese: "默认会话和普通任务使用的模型。", english: "Model used by default chats and regular tasks.")
                    ) {
                        modelAssignmentPicker(path: "agent.model")
                    }

                    if let mainRef = nonBlank(configValue("agent.model")), NativeConfigService.splitModelRef(mainRef) != nil {
                        SettingsCardDivider()
                        agentCapabilitiesBlock(modelRef: mainRef)
                    }

                    SettingsCardDivider()
                    Button {
                        showAdvancedAgents.toggle()
                    } label: {
                        Label(local(chinese: "高级智能体", english: "Advanced agents"), systemImage: showAdvancedAgents ? "chevron.down" : "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DesignTokens.tertiaryText)

                    if showAdvancedAgents {
                        SettingsCardDivider()
                        SettingsRowBlock(
                            title: state.t(.subagents),
                            detail: local(chinese: "子智能体默认模型，可继承主智能体。", english: "Default subagent model; can inherit the main agent.")
                        ) {
                            modelAssignmentPicker(path: "agent.subagents.default", includeInherit: true)
                        }
                        SettingsCardDivider()
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "info.circle")
                                .foregroundStyle(DesignTokens.accent)
                            Text(local(chinese: "子智能体的模型也会被 Router 和 Token Saver 规则影响。", english: "Subagent models can still be affected by Router and Token Saver policy."))
                                .font(.system(size: 11))
                                .foregroundStyle(DesignTokens.tertiaryText)
                        }
                        .padding(14)
                    }
                }
            }
        }
    }

    private var routerSettingsContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionBlock(
                title: state.t(.routing),
                detail: local(chinese: "原生 Router 决定每次请求使用哪个模型，并把真实请求记录写入本机统计。", english: "Native Router selects the model for each request and records native request stats.")
            ) {
                SettingsCardBlock(divided: true) {
                    SettingsRowBlock(title: state.t(.enabled), detail: state.t(.routerDetail)) {
                        WebSettingsToggle(isOn: configBoolBinding(NativeRouterConfigFormFields.enabledPath))
                    }
                    if configBool(NativeRouterConfigFormFields.enabledPath) {
                        SettingsCardDivider()
                        modelAssignmentRowsList(routerLevelModelRows)
                    }
                }
            }

            if configBool(NativeRouterConfigFormFields.enabledPath) {
                Button {
                    showAdvancedRouter.toggle()
                } label: {
                    Label(local(chinese: "高级路由", english: "Advanced router"), systemImage: showAdvancedRouter ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignTokens.tertiaryText)

                if showAdvancedRouter {
                    SettingsSectionBlock(
                        title: local(chinese: "回退链", english: "Fallback chains"),
                        detail: local(chinese: "按场景配置候选模型链。mac 端会按顺序尝试可用模型。", english: "Configure candidate model chains per scenario. macOS tries available models in order.")
                    ) {
                        SettingsCardBlock {
                            ConfigGrid {
                                ForEach(NativeRouterConfigFormFields.fallbackFields) { field in
                                    SettingsTextArea(
                                        local(
                                            chinese: "\(field.chineseLabel)（每行一个模型）",
                                            english: "\(field.englishLabel) (one model per line)"
                                        ),
                                        text: configArrayTextBinding(field.path)
                                    )
                                }
                            }
                            .padding(14)
                        }
                    }

                    SettingsSectionBlock(
                        title: local(chinese: "零用量重试", english: "Zero-usage retry"),
                        detail: local(chinese: "当提供商返回空 usage 时自动重试，避免错误计费/路由统计。", english: "Retry when a provider returns empty usage to avoid bad billing or router stats.")
                    ) {
                        SettingsCardBlock(divided: true) {
                            SettingsRowBlock(
                                title: state.t(.enabled),
                                detail: local(chinese: "启用后最多按下面次数重试。", english: "When enabled, retry up to the configured attempt count.")
                            ) {
                                WebSettingsToggle(isOn: configBoolBinding("router.zeroUsageRetry.enabled", defaultValue: true))
                            }
                            if configBool("router.zeroUsageRetry.enabled", defaultValue: true) {
                                SettingsCardDivider()
                                ConfigGrid {
                                    SettingsTextField(
                                        local(chinese: "最大尝试次数", english: "Max attempts"),
                                        text: configBinding("router.zeroUsageRetry.maxAttempts")
                                    )
                                }
                                .padding(14)
                            }
                        }
                    }

                    SettingsSectionBlock(
                        title: state.t(.tokenSaver),
                        detail: local(chinese: "对齐 PD 的 simple / medium / complex / reasoning 四档，复杂度判断和回退细节由客户端处理。", english: "Uses PD-style simple / medium / complex / reasoning tiers. Classification and fallback details are handled by the client.")
                    ) {
                        SettingsCardBlock(divided: true) {
                            SettingsRowBlock(title: state.t(.enabled), detail: state.t(.tokenSaverDetail)) {
                                WebSettingsToggle(isOn: configBoolBinding("router.tokenSaver.enabled", defaultValue: true))
                            }
                            if configBool("router.tokenSaver.enabled", defaultValue: true) {
                                SettingsCardDivider()
                                ConfigGrid {
                                    SettingsPickerField(
                                        local(chinese: "默认档位", english: "Default tier"),
                                        selection: configBinding("router.tokenSaver.defaultTier", fallback: "medium"),
                                        options: RouterTier.allCases.map(\.rawValue),
                                        emptyLabel: "medium"
                                    )
                                    SettingsTextField(
                                        local(chinese: "判断超时（毫秒）", english: "Judge timeout (ms)"),
                                        text: configBinding("router.tokenSaver.judgeTimeoutMs")
                                    )
                                    SettingsPickerField(
                                        local(chinese: "子智能体策略", english: "Subagent policy"),
                                        selection: configBinding("router.tokenSaver.subagent.policy", fallback: "judge"),
                                        options: ["judge", "skip"],
                                        emptyLabel: "judge"
                                    )
                                }
                                .padding(14)
                                SettingsCardDivider()
                                ConfigGrid {
                                    ForEach(NativeRouterConfigFormFields.tierDescriptionFields) { field in
                                        SettingsTextField(
                                            local(chinese: field.chineseLabel, english: field.englishLabel),
                                            text: configBinding(field.path)
                                        )
                                    }
                                    SettingsTextArea(
                                        local(chinese: "规则（每行一条）", english: "Rules (one per line)"),
                                        text: configArrayTextBinding("router.tokenSaver.rules")
                                    )
                                }
                                .padding(14)
                            }
                        }
                    }

                    SettingsSectionBlock(
                        title: local(chinese: "自动编排", english: "Auto-orchestrate"),
                        detail: local(chinese: "达到指定复杂度档位时自动启用更轻的系统提示和编排策略。", english: "Enable orchestration behavior for selected complexity tiers.")
                    ) {
                        SettingsCardBlock(divided: true) {
                            SettingsRowBlock(
                                title: state.t(.enabled),
                                detail: local(chinese: "通常 complex 档位会触发。", english: "Usually triggered by the complex tier.")
                            ) {
                                WebSettingsToggle(isOn: configBoolBinding("router.autoOrchestrate.enabled", defaultValue: true))
                            }
                            if configBool("router.autoOrchestrate.enabled", defaultValue: true) {
                                SettingsCardDivider()
                                ConfigGrid {
                                    SettingsTextArea(
                                        local(chinese: "触发档位（每行一个）", english: "Trigger tiers (one per line)"),
                                        text: configArrayTextBinding("router.autoOrchestrate.triggerTiers")
                                    )
                                    webSettingsToggleRow(
                                        title: local(chinese: "精简系统提示", english: "Slim system prompt"),
                                        detail: local(chinese: "编排时减少重复提示上下文。", english: "Reduce repeated prompt context during orchestration."),
                                        isOn: configBoolBinding("router.autoOrchestrate.slimSystemPrompt", defaultValue: true)
                                    )
                                }
                                .padding(14)
                            }
                        }
                    }

                    SettingsSectionBlock(
                        title: local(chinese: "统计与价格", english: "Stats & pricing"),
                        detail: local(chinese: "记录路由统计，并可为模型配置每百万 token 价格。", english: "Record router stats and optionally configure per-million token pricing.")
                    ) {
                        SettingsCardBlock(divided: true) {
                            SettingsRowBlock(
                                title: state.t(.enabled),
                                detail: local(chinese: "用于路由看板展示请求、Token 和成本。", english: "Used by the router dashboard for requests, tokens, and cost.")
                            ) {
                                WebSettingsToggle(isOn: configBoolBinding("router.stats.enabled", defaultValue: true))
                            }
                            if configBool("router.stats.enabled", defaultValue: true) {
                                SettingsCardDivider()
                                ConfigGrid {
                                    ForEach(NativeRouterConfigFormFields.pricingFields) { field in
                                        SettingsTextField(
                                            local(chinese: field.chineseLabel, english: field.englishLabel),
                                            text: configBinding(field.path)
                                        )
                                    }
                                }
                                .padding(14)
                            }
                        }
                    }
                }
            }
        }
    }

    private var customEnvSettingsContent: some View {
        SettingsSectionBlock(
            title: local(chinese: "自定义环境变量", english: "Custom Env"),
            detail: local(chinese: "与网页版一致，写入 `customEnv`；mac 端会保留这些键，并在需要时传给运行时。", english: "Matches the web config `customEnv` block; macOS preserves these keys for runtime use.")
        ) {
            SettingsCardBlock {
                VStack(alignment: .leading, spacing: 12) {
                    if customEnvKeys.isEmpty {
                        dashedEmpty(local(chinese: "暂无自定义环境变量。", english: "No custom environment variables."))
                    } else {
                        VStack(spacing: 10) {
                            ForEach(customEnvKeys, id: \.self) { key in
                                HStack(spacing: 10) {
                                    Text(key)
                                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                        .frame(width: 180, alignment: .leading)
                                    SettingsTextField(
                                        local(chinese: "值", english: "Value"),
                                        text: configBinding("customEnv.\(key)"),
                                        isSecure: customEnvKeyLooksSecret(key)
                                    )
                                    Button {
                                        removeCustomEnvKey(key)
                                    } label: {
                                        Image(systemName: "trash")
                                            .frame(width: 28, height: 28)
                                    }
                                    .buttonStyle(SettingsIconButtonStyle())
                                    .foregroundStyle(DesignTokens.danger)
                                }
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        TextField("KEY", text: $newCustomEnvKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .onSubmit(addCustomEnvKey)
                        TextField("value", text: $newCustomEnvValue)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .onSubmit(addCustomEnvKey)
                        Button {
                            addCustomEnvKey()
                        } label: {
                            Label(state.t(.add), systemImage: "plus")
                        }
                        .buttonStyle(WebToolbarButtonStyle(isProminent: true))
                        .disabled(!isValidCustomEnvKey(newCustomEnvKey))
                    }
                    let quickKeys = NativeCustomEnvConfigFormFields.wellKnownKeys.filter { !customEnvKeys.contains($0.key) }
                    if !quickKeys.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(local(chinese: "快速添加常用变量", english: "Quick add common variables"))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(DesignTokens.tertiaryText)
                            FlowLayout(spacing: 6) {
                                ForEach(quickKeys, id: \.key) { item in
                                    Button {
                                        setConfigValue("customEnv.\(item.key)", "")
                                    } label: {
                                        Label(item.key, systemImage: "plus")
                                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    }
                                    .buttonStyle(WebToolbarButtonStyle())
                                    .help(item.hint)
                                }
                            }
                        }
                    }
                }
                .padding(14)
            }
        }
    }

    private var routerTierModelRows: [NativeModelAssignmentRowSpec] {
        RouterTier.allCases.map { tier in
            NativeModelAssignmentRowSpec(
                id: "\(tier.rawValue)Tier",
                title: routerTierTitle(tier),
                detail: routerTierDetail(tier),
                path: "router.tokenSaver.tiers.\(tier.rawValue).model"
            )
        }
    }

    private var routerLevelModelRows: [NativeModelAssignmentRowSpec] {
        [
            NativeModelAssignmentRowSpec(
                id: "defaultRoute",
                title: state.t(.defaultRouteModel),
                detail: routerModelDetail("default"),
                path: "router.scenarios.default"
            ),
            NativeModelAssignmentRowSpec(
                id: "judgeModel",
                title: state.t(.judgeModel),
                detail: local(chinese: "Token Saver 用这个模型判断任务复杂度。", english: "Token Saver uses this model to judge task complexity."),
                path: "router.tokenSaver.judge"
            ),
        ] + routerTierModelRows
    }

    private func routerTierTitle(_ tier: RouterTier) -> String {
        switch tier {
        case .simple: local(chinese: "简单任务", english: "Simple")
        case .medium: local(chinese: "中等任务", english: "Medium")
        case .complex: local(chinese: "复杂任务", english: "Complex")
        case .reasoning: local(chinese: "推理任务", english: "Reasoning")
        }
    }

    private func routerTierDetail(_ tier: RouterTier) -> String {
        switch tier {
        case .simple:
            local(chinese: "简短问答、读取、小改动。", english: "Short Q&A, reads, tiny edits.")
        case .medium:
            local(chinese: "解释、审查、单文件或中等复杂度任务。", english: "Explanations, reviews, single-file or moderate tasks.")
        case .complex:
            local(chinese: "多步骤实现、较大功能、协调修改。", english: "Multi-step implementation, larger features, coordinated changes.")
        case .reasoning:
            local(chinese: "深度分析、架构、安全或困难调试。", english: "Deep analysis, architecture, safety, or hard debugging.")
        }
    }

    private var primaryModelAssignmentRows: [NativeModelAssignmentRowSpec] {
        [
            NativeModelAssignmentRowSpec(
                id: "mainAgent",
                title: state.t(.mainAgent),
                detail: local(chinese: "默认会话和普通任务使用的模型。", english: "Model used by default chats and regular tasks."),
                path: "agent.model"
            ),
            NativeModelAssignmentRowSpec(
                id: "subagents",
                title: state.t(.subagents),
                detail: local(chinese: "子智能体默认模型，可继承主智能体。", english: "Default subagent model; can inherit the main agent."),
                path: "agent.subagents.default",
                includeInherit: true
            ),
        ]
    }

    private var routeModelAssignmentRows: [NativeModelAssignmentRowSpec] {
        NativeRouterConfigFormFields.routeModelFields.map { field in
            NativeModelAssignmentRowSpec(
                id: field.id,
                title: state.t(field.label),
                detail: routerModelDetail(field.id),
                path: field.path
            )
        }
    }

    private func modelAssignmentRowsCard(_ rows: [NativeModelAssignmentRowSpec]) -> some View {
        SettingsCardBlock(divided: true) {
            modelAssignmentRowsList(rows)
        }
    }

    private func modelAssignmentRowsList(_ rows: [NativeModelAssignmentRowSpec]) -> some View {
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            SettingsRowBlock(title: row.title, detail: row.detail) {
                modelAssignmentPicker(path: row.path, includeInherit: row.includeInherit)
            }
            if index < rows.count - 1 {
                SettingsCardDivider()
            }
        }
    }

    private var webProviderIDs: [String] {
        configChildIDs(parentPath: "model.providers")
            .filter { provider in
                !provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
    }

    private var catalogProviderPickerCard: some View {
        SettingsCardBlock {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(local(chinese: "添加模型提供商", english: "Add model provider"))
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button(state.t(.cancel)) {
                        showCatalogProviderPicker = false
                    }
                    .buttonStyle(WebToolbarButtonStyle())
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                    ForEach(NativeModelCatalog.providers) { provider in
                        Button {
                            addCatalogProvider(provider)
                            showCatalogProviderPicker = false
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(provider.displayName)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(DesignTokens.text)
                                Text(local(chinese: "\(provider.models.count) 个模型", english: "\(provider.models.count) models"))
                                    .font(.system(size: 10))
                                    .foregroundStyle(DesignTokens.tertiaryText)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(DesignTokens.neutral50, in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius))
                            .overlay(RoundedRectangle(cornerRadius: DesignTokens.smallRadius).stroke(DesignTokens.separator))
                        }
                        .buttonStyle(.plain)
                        .disabled(webProviderIDs.contains(provider.id))
                        .opacity(webProviderIDs.contains(provider.id) ? 0.45 : 1)
                    }
                    Button {
                        addCustomProvider()
                        showCatalogProviderPicker = false
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("+ " + local(chinese: "自定义提供商", english: "Custom provider"))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(DesignTokens.text)
                            Text(local(chinese: "手动配置接口地址", english: "Manual endpoint setup"))
                                .font(.system(size: 10))
                                .foregroundStyle(DesignTokens.tertiaryText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(DesignTokens.neutral50, in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius))
                        .overlay(RoundedRectangle(cornerRadius: DesignTokens.smallRadius).stroke(DesignTokens.separator, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
        }
    }

    private func webProviderCard(_ provider: String) -> some View {
        let catalog = NativeModelCatalog.provider(id: provider)
        let models = enabledModels(forProvider: provider)
        return SettingsCardBlock {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(catalog?.displayName ?? provider)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(DesignTokens.text)
                        HStack(spacing: 8) {
                            Text(local(chinese: "ID", english: "ID"))
                                .font(.system(size: 11))
                                .foregroundStyle(DesignTokens.tertiaryText)
                            TextField("provider", text: Binding(
                                get: { provider },
                                set: { renameWebProvider(oldID: provider, newID: $0) }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 220)
                        }
                    }
                    Spacer()
                    Button {
                        removeWebProvider(provider)
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(SettingsIconButtonStyle())
                    .foregroundStyle(DesignTokens.danger)
                }

                ConfigGrid {
                    SettingsPickerField(
                        local(chinese: "协议", english: "Protocol"),
                        selection: Binding(
                            get: { nonBlank(configValue("model.providers.\(provider).protocol")) ?? catalog?.protocolValue ?? "openai" },
                            set: { setConfigValue("model.providers.\(provider).protocol", $0 == "anthropic" ? "anthropic" : "openai") }
                        ),
                        options: NativeModelsConfigFormFields.providerProtocolOptions,
                        emptyLabel: "openai",
                        optionLabel: NativeModelsConfigFormFields.providerProtocolLabel
                    )
                    SettingsTextField(local(chinese: "接口地址", english: "Base URL"), text: configBinding("model.providers.\(provider).url"))
                }

                VStack(alignment: .leading, spacing: 5) {
                    SettingsTextField(state.t(.apiKey), text: configBinding("model.providers.\(provider).apiKey"), isSecure: true)
                    Text(state.t(.apiKeyConfigHelp))
                        .font(.system(size: 11))
                        .foregroundStyle(DesignTokens.tertiaryText)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text(local(chinese: "已启用模型", english: "Enabled Models"))
                            .font(.system(size: 12, weight: .semibold))
                        Text("·")
                            .foregroundStyle(DesignTokens.tertiaryText)
                        Image(systemName: "photo")
                            .font(.system(size: 11))
                            .foregroundStyle(DesignTokens.tertiaryText)
                        Text(local(chinese: "支持图片输入", english: "supports image input"))
                            .font(.system(size: 10))
                            .foregroundStyle(DesignTokens.tertiaryText)
                    }

                    if let catalog, !catalog.models.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6)], alignment: .leading, spacing: 6) {
                            ForEach(catalog.models) { model in
                                let isEnabled = models.contains(model.id)
                                Button {
                                    if isEnabled {
                                        removeWebModel(provider: provider, model: model.id)
                                    } else {
                                        addWebModel(provider: provider, model: model.id)
                                    }
                                } label: {
                                    HStack(spacing: 5) {
                                        if isEnabled {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 10, weight: .bold))
                                        }
                                        Text(model.displayName)
                                            .lineLimit(1)
                                        if model.supportsImage {
                                            Image(systemName: "photo")
                                                .font(.system(size: 10))
                                        }
                                    }
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(isEnabled ? DesignTokens.text : DesignTokens.tertiaryText)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                                    .background(isEnabled ? DesignTokens.neutral100 : DesignTokens.neutral50, in: RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(isEnabled ? DesignTokens.neutral300 : DesignTokens.separator))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    ForEach(models.filter { model in
                        catalog?.models.contains(where: { $0.id == model }) != true
                    }, id: \.self) { model in
                        HStack(spacing: 8) {
                            Text(model)
                                .font(.system(size: 12, design: .monospaced))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                removeWebModel(provider: provider, model: model)
                            } label: {
                                Image(systemName: "trash")
                                    .frame(width: 24, height: 24)
                            }
                            .buttonStyle(SettingsIconButtonStyle())
                            .foregroundStyle(DesignTokens.tertiaryText)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(DesignTokens.neutral50, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(DesignTokens.separator))
                    }

                    HStack(spacing: 8) {
                        TextField(local(chinese: "自定义模型 ID", english: "Custom model ID"), text: $newModelID)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .onSubmit {
                                addPendingCustomModel(provider: provider)
                            }
                        Button {
                            addPendingCustomModel(provider: provider)
                        } label: {
                            Label(state.t(.add), systemImage: "plus")
                        }
                        .buttonStyle(WebToolbarButtonStyle())
                        .disabled(newModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .padding(16)
        }
    }

    private func agentCapabilitiesBlock(modelRef: String) -> some View {
        let parsed = NativeConfigService.splitModelRef(modelRef)
        let provider = parsed?.providerID ?? ""
        let model = parsed?.modelID ?? ""
        let catalogModel = NativeModelCatalog.model(providerID: provider, modelID: model)
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(local(chinese: "模型能力", english: "Model capabilities"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignTokens.text)
                Text(local(chinese: "这里覆盖当前主模型的上下文窗口和最大输出。图片能力优先参考模型目录。", english: "Override context window and max output for the selected main model. Image support follows the catalog when available."))
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.tertiaryText)
            }
            HStack(spacing: 10) {
                Label(
                    (catalogModel?.supportsImage == true)
                        ? local(chinese: "支持图片输入", english: "Image input enabled")
                        : local(chinese: "文本模型", english: "Text model"),
                    systemImage: "photo"
                )
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(catalogModel?.supportsImage == true ? DesignTokens.success : DesignTokens.tertiaryText)
                Spacer()
            }
            ConfigGrid {
                SettingsTextField(
                    local(chinese: "最大输出 Tokens", english: "Max output tokens"),
                    text: Binding(
                        get: { webModelScalar(provider: provider, model: model, suffix: ["capabilities", "maxOutputTokens"]) },
                        set: { setWebModelScalar(provider: provider, model: model, suffix: ["capabilities", "maxOutputTokens"], value: $0) }
                    )
                )
                SettingsTextField(
                    local(chinese: "最大上下文 Tokens", english: "Max context tokens"),
                    text: configBinding("agent.maxContextTokens")
                )
            }
        }
        .padding(14)
    }

    private var modelPoolEntryIDs: [String] {
        let values = LegacyConfigLoader.scalarMap(from: state.pilotDeckConfigText)
        var ids = Set(NativeConfigService.modelEntryIDs(values: values))
        for provider in webProviderIDs {
            if let catalog = NativeModelCatalog.provider(id: provider) {
                for model in catalog.models {
                    ids.insert(NativeConfigService.modelRef(providerID: provider, modelID: model.id))
                }
            }
        }
        return ids.sorted()
    }

    private var selectedModelPoolEntryID: String? {
        let entries = modelPoolEntryIDs
        if let selectedModelPoolEntry, entries.contains(selectedModelPoolEntry) {
            return selectedModelPoolEntry
        }
        return entries.first
    }

    private var selectedModelPoolEntryBinding: Binding<String> {
        Binding(
            get: { selectedModelPoolEntryID ?? "" },
            set: { selectedModelPoolEntry = $0.isEmpty ? nil : $0 }
        )
    }

    @ViewBuilder
    private func modelPoolEditorCard(_ entry: String) -> some View {
        if let parsed = NativeConfigService.splitModelRef(entry) {
            webModelPoolEditorCard(provider: parsed.providerID, model: parsed.modelID)
        } else {
        let provider = providerID(forEntry: entry)
        SettingsCardBlock {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(modelOptionLabel(entry))
                            .font(.system(size: 13, weight: .semibold))
                        Text(modelPoolSummary(forEntry: entry))
                            .font(.system(size: 11))
                            .foregroundStyle(DesignTokens.tertiaryText)
                    }
                    Spacer()
                    Button(state.t(.remove)) { removeModelPoolEntry(entry) }
                        .buttonStyle(WebToolbarButtonStyle())
                }

                ConfigGrid {
                    SettingsTextField(local(chinese: "模型名称", english: "Model Name"), text: Binding(
                        get: {
                            entry == "default" ? state.settings.providerConfig.model : configValue("models.entries.\(entry).name")
                        },
                        set: { value in
                            if entry == "default" {
                                state.settings.providerConfig.model = value
                            }
                            setConfigValue("models.entries.\(entry).name", value)
                        }
                    ))
                    SettingsPickerField(
                        state.t(.type),
                        selection: configBinding("models.providers.\(provider).type", fallback: NativeModelsConfigFormFields.defaultProviderType),
                        options: NativeModelsConfigFormFields.providerTypeOptions,
                        emptyLabel: NativeModelsConfigFormFields.defaultProviderType
                    )
                    SettingsTextField(state.t(.baseURL), text: Binding(
                        get: {
                            isDefaultProvider(provider) ? state.settings.providerConfig.baseURL : configValue("models.providers.\(provider).baseUrl")
                        },
                        set: { value in
                            if isDefaultProvider(provider) {
                                state.settings.providerConfig.baseURL = value
                            }
                            setConfigValue("models.providers.\(provider).baseUrl", value)
                        }
                    ))
                    SettingsTextField(state.t(.apiKey), text: configBinding("models.providers.\(provider).apiKey"), isSecure: true)
                    SettingsTextField(state.t(.contextWindow), text: configBinding("models.entries.\(entry).contextWindow"))
                }

                Text(state.t(.apiKeyConfigHelp))
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.tertiaryText)
            }
            .padding(14)
        }
        }
    }

    private func webModelPoolEditorCard(provider: String, model: String) -> some View {
        let ref = NativeConfigService.modelRef(providerID: provider, modelID: model)
        return SettingsCardBlock {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(modelOptionLabel(ref))
                            .font(.system(size: 13, weight: .semibold))
                        Text(modelPoolSummary(forEntry: ref))
                            .font(.system(size: 11))
                            .foregroundStyle(DesignTokens.tertiaryText)
                    }
                    Spacer()
                    Button(state.t(.remove)) { removeModelPoolEntry(ref) }
                        .buttonStyle(WebToolbarButtonStyle())
                }

                ConfigGrid {
                    SettingsTextField(local(chinese: "Provider ID", english: "Provider ID"), text: Binding(
                        get: { provider },
                        set: { renameWebProvider(oldID: provider, newID: $0) }
                    ))
                    SettingsPickerField(
                        state.t(.type),
                        selection: Binding(
                            get: { nonBlank(configValue("model.providers.\(provider).protocol")) ?? "openai" },
                            set: { setConfigValue("model.providers.\(provider).protocol", $0 == "anthropic" ? "anthropic" : "openai") }
                        ),
                        options: ["openai", "anthropic"],
                        emptyLabel: "openai"
                    )
                    SettingsTextField(local(chinese: "模型 ID", english: "Model ID"), text: Binding(
                        get: { model },
                        set: { renameWebModel(provider: provider, oldID: model, newID: $0) }
                    ))
                    SettingsTextField(state.t(.baseURL), text: configBinding("model.providers.\(provider).url"))
                    SettingsTextField(state.t(.apiKey), text: configBinding("model.providers.\(provider).apiKey"), isSecure: true)
                    SettingsTextField(state.t(.contextWindow), text: Binding(
                        get: { webModelScalar(provider: provider, model: model, suffix: ["capabilities", "maxContextTokens"]) },
                        set: { setWebModelScalar(provider: provider, model: model, suffix: ["capabilities", "maxContextTokens"], value: $0) }
                    ))
                }

                Text(state.t(.apiKeyConfigHelp))
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.tertiaryText)
            }
            .padding(14)
        }
    }

    private func configBinding(_ path: String) -> Binding<String> {
        Binding(
            get: { configValue(path) },
            set: { setConfigValue(path, $0) }
        )
    }

    private func configBinding(_ path: String, fallback: String) -> Binding<String> {
        Binding(
            get: {
                let value = configValue(path)
                return value.isEmpty ? fallback : value
            },
            set: { setConfigValue(path, $0) }
        )
    }

    private func configArrayTextBinding(_ path: String) -> Binding<String> {
        Binding(
            get: {
                YAMLScalarEditor.stringArray(
                    path: canonicalConfigPath(path),
                    in: state.pilotDeckConfigText
                )
                .joined(separator: "\n")
            },
            set: { value in
                let values = value
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                state.pilotDeckConfigText = YAMLScalarEditor.setStringArray(
                    path: canonicalConfigPath(path),
                    values: values,
                    in: state.pilotDeckConfigText
                )
            }
        )
    }

    private func configBoolBinding(_ path: String, defaultValue: Bool = false) -> Binding<Bool> {
        Binding(
            get: {
                configBool(path, defaultValue: defaultValue)
            },
            set: { setConfigValue(path, $0 ? "true" : "false") }
        )
    }

    private func testSearchConnection() {
        isTestingSearchConnection = true
        searchConnectionMessage = nil
        searchConnectionError = nil
        let values = LegacyConfigLoader.scalarMap(from: state.pilotDeckConfigText)
        Task {
            let result = await NativeSearchConnectionTester.test(values: values)
            await MainActor.run {
                isTestingSearchConnection = false
                switch result {
                case .success:
                    searchConnectionMessage = local(chinese: "连接成功", english: "Connection succeeded")
                    searchConnectionError = nil
                case .failure(let message):
                    searchConnectionMessage = nil
                    searchConnectionError = message
                }
            }
        }
    }

    private func searchProviderBinding() -> Binding<String> {
        Binding(
            get: {
                let value = configValue(NativeSearchConfigFormFields.providerPath)
                return NativeSearchConfigFormFields.providerOptions.contains(value) ? value : "glm"
            },
            set: { provider in
                let selected = NativeSearchConfigFormFields.providerOptions.contains(provider) ? provider : "glm"
                searchConnectionMessage = nil
                searchConnectionError = nil
                setConfigValue(NativeSearchConfigFormFields.providerPath, selected)
                let endpoint = configValue("tools.webSearch.endpoint").trimmingCharacters(in: .whitespacesAndNewlines)
                let defaultEndpoints = Set(NativeSearchConfigFormFields.defaultEndpoints.values)
                if selected == "custom" {
                    if defaultEndpoints.contains(endpoint) {
                        setConfigValue("tools.webSearch.endpoint", "")
                    }
                } else if endpoint.isEmpty || defaultEndpoints.contains(endpoint) {
                    setConfigValue("tools.webSearch.endpoint", NativeSearchConfigFormFields.defaultEndpoints[selected] ?? "")
                }
            }
        )
    }

    private var alwaysOnProjectRows: [WorkspaceProject] {
        state.projects.filter { project in
            !state.isGeneralProject(project)
                && !AlwaysOnProjectConfig.projectRoot(state.effectiveWorkspacePath(for: project)).isEmpty
        }
    }

    private func alwaysOnProjectEnabledBinding(root: String) -> Binding<Bool> {
        Binding(
            get: {
                AlwaysOnProjectConfig.isEnabled(yaml: state.pilotDeckConfigText, projectRoot: root)
            },
            set: { enabled in
                state.pilotDeckConfigText = AlwaysOnProjectConfig.setEnabled(
                    in: state.pilotDeckConfigText,
                    projectRoot: root,
                    enabled: enabled
                )
            }
        )
    }

    private func configValue(_ path: String) -> String {
        let values = LegacyConfigLoader.scalarMap(from: state.pilotDeckConfigText)
        let canonical = canonicalConfigPath(path)
        return values[canonical] ?? values[path] ?? ""
    }

    private func setConfigValue(_ path: String, _ value: String) {
        guard !shouldIgnoreRecentlyRemovedProviderWrite(path) else { return }
        let canonical = canonicalConfigPath(path)
        if NativeConfigCompatibility.shouldDeleteWhenEmpty(path: canonical, value: value) {
            state.pilotDeckConfigText = YAMLScalarEditor.removeObject(path: canonical, in: state.pilotDeckConfigText)
            return
        }
        state.pilotDeckConfigText = YAMLScalarEditor.set(path: canonical, value: value, in: state.pilotDeckConfigText)
    }

    private func shouldIgnoreRecentlyRemovedProviderWrite(_ path: String) -> Bool {
        let canonical = canonicalConfigPath(path)
        let components = canonical.split(separator: ".").map(String.init)
        guard components.count >= 4,
              components[0] == "model",
              components[1] == "providers"
        else { return false }

        let provider = components[2]
        guard recentlyRemovedWebProviderIDs.contains(provider) else { return false }

        let prefix = "model.providers.\(provider)."
        return !LegacyConfigLoader.scalarMap(from: state.pilotDeckConfigText).keys.contains { $0.hasPrefix(prefix) }
    }

    private func canonicalConfigPath(_ path: String) -> String {
        switch path {
        case "runtime.workspacesRoot":
            return "webui.runtime.workspacesRoot"
        case "runtime.apiTimeoutMs":
            return "webui.runtime.apiTimeoutMs"
        case "runtime.databasePath":
            return "webui.runtime.databasePath"
        case "runtime.httpsProxy":
            return "webui.runtime.httpsProxy"
        case "agents.main.model":
            return "agent.model"
        case "agents.subagents.default":
            return "agent.subagents.default"
        case "router.routes.default.model":
            return "router.scenarios.default"
        case "router.routes.background.model":
            return "router.scenarios.background"
        case "router.routes.think.model":
            return "router.scenarios.think"
        case "router.routes.longContext.model":
            return "router.scenarios.longContext"
        case "router.routes.webSearch.model":
            return "router.scenarios.webSearch"
        case "router.tokenSaver.judgeModel":
            return "router.tokenSaver.judge"
        default:
            return path
        }
    }

    private var isConfigDirty: Bool {
        state.pilotDeckConfigText != savedConfigText
    }

    private func configBool(_ path: String, defaultValue: Bool = false) -> Bool {
        NativeConfigBoolValue.resolve(configValue(path), defaultValue: defaultValue)
    }

    private func reloadSummaryIsReloaded(_ subsystem: NativeConfigReloadSubsystemSpec) -> Bool {
        switch subsystem.state {
        case .alwaysReloaded:
            return true
        case .boolPath(let path):
            return configBool(path)
        case .nonEmptyPath(let path):
            return !configValue(path).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func reloadSummaryDetail(_ subsystem: NativeConfigReloadSubsystemSpec) -> String {
        if reloadSummaryIsReloaded(subsystem) {
            return state.t(subsystem.reloadedDetail)
        }
        if let skippedDetail = subsystem.skippedDetail {
            return state.t(skippedDetail)
        }
        return state.t(.skipped)
    }

    private func configFileURL() -> URL {
        PilotDeckConfigPath.configURL()
    }

    private var yamlContentTypes: [UTType] {
        let types = [
            UTType(filenameExtension: "yaml"),
            UTType(filenameExtension: "yml"),
        ].compactMap(\.self)
        return types.isEmpty ? [.plainText] : types
    }

    private func reloadConfigFromDisk() {
        do {
            let url = FileManager.default.fileExists(atPath: configFileURL().path)
                ? configFileURL()
                : PilotDeckConfigPath.legacyConfigURLs().first(where: { FileManager.default.fileExists(atPath: $0.path) }) ?? configFileURL()
            let text = try String(contentsOf: url, encoding: .utf8)
            if isConfigDirty {
                configExternalNotice = state.t(.configReloadedNotice)
            }
            state.pilotDeckConfigText = text
            savedConfigText = text
            configError = nil
            configMessage = state.t(.reloadedCurrentConfig)
            applyRuntimeFieldsFromConfig()
        } catch {
            configError = error.localizedDescription
        }
    }

    private func revealConfigFile() {
        NSWorkspace.shared.activateFileViewerSelecting([configFileURL()])
    }

    private func importConfigFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = yamlContentTypes
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            state.pilotDeckConfigText = try String(contentsOf: url, encoding: .utf8)
            configError = nil
            configMessage = local(chinese: "已导入配置，保存并重新加载后生效。", english: "Imported config. Save and reload to apply it.")
        } catch {
            configError = error.localizedDescription
        }
    }

    private func exportConfigFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "pilotdeck.yaml"
        panel.allowedContentTypes = yamlContentTypes
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try state.pilotDeckConfigText.write(to: url, atomically: true, encoding: .utf8)
            configError = nil
            configMessage = state.t(.exported)
        } catch {
            configError = error.localizedDescription
        }
    }

    private func saveConfigAndReload() {
        let validation = validateConfig()
        guard validation.valid else {
            configMessage = nil
            configError = validation.errors.first ?? state.t(.configInvalid)
            return
        }
        state.saveSettings()
        savedConfigText = state.pilotDeckConfigText
        configError = nil
        configMessage = state.t(.savedAndReloaded)
        applyRuntimeFieldsFromConfig()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            state.settingsSaveNotice = nil
        }
    }

    private func applyRuntimeFieldsFromConfig() {
        let values = LegacyConfigLoader.scalarMap(from: state.pilotDeckConfigText)
        if let root = configPathValue(values["runtime.workspacesRoot"]) {
            state.settings.workspacesRoot = AppState.normalizedWorkspacesRoot(root)
        }
        if let general = configPathValue(values["gateway.runtimePaths.generalCwd"]) {
            state.settings.generalWorkspacePath = AppState.normalizedGeneralWorkspacePath(general)
        }
        if let timeout = values["runtime.apiTimeoutMs"].flatMap(Int.init) {
            state.settings.apiTimeoutMs = timeout
        }
        if let context = values["runtime.contextWindow"].flatMap(Int.init) {
            state.settings.contextWindow = context
        }
        let mainRef = nonBlank(values["agent.model"] ?? "") ?? nonBlank(values["agents.main.model"] ?? "") ?? "default"
        let defaultProvider = NativeConfigService.providerID(entryID: mainRef, values: values)
        if let baseURL = values["model.providers.\(defaultProvider).url"] ?? values["models.providers.\(defaultProvider).baseUrl"] {
            state.settings.providerConfig.baseURL = baseURL
        }
        if let model = values["models.entries.\(mainRef).name"] ?? NativeConfigService.splitModelRef(mainRef)?.modelID {
            state.settings.providerConfig.model = model
        }
    }

    private func validateConfig() -> NativeConfigValidation {
        let values = LegacyConfigLoader.scalarMap(from: state.pilotDeckConfigText)
        var errors: [String] = []
        var warnings: [String] = []
        let mainRef = nonBlank(values["agent.model"] ?? "") ?? nonBlank(values["agents.main.model"] ?? "")
        if let mainRef {
            if NativeConfigService.providerConfig(entryID: mainRef, values: values) == nil {
                errors.append("agent.model must resolve to a configured model provider.")
            }
        } else {
            warnings.append("agent.model is empty; pick a model from the model pool.")
        }
        if configPathValue(values["runtime.workspacesRoot"]) == nil {
            warnings.append("webui.runtime.workspacesRoot is empty; project creation will use the home directory fallback.")
        }
        if configPathValue(values["gateway.runtimePaths.generalCwd"]) == nil {
            warnings.append("gateway.runtimePaths.generalCwd is empty; Chat will use the default workspace.")
        }
        if state.pilotDeckConfigText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Config YAML is empty.")
        }
        errors.append(contentsOf: NativeConfigCompatibility.validationErrors(
            yaml: state.pilotDeckConfigText,
            values: values
        ))
        return NativeConfigValidation(errors: errors, warnings: warnings)
    }

    private func defaultProviderID() -> String {
        let values = LegacyConfigLoader.scalarMap(from: state.pilotDeckConfigText)
        let mainRef = nonBlank(values["agent.model"] ?? "") ?? nonBlank(values["agents.main.model"] ?? "") ?? "default"
        return NativeConfigService.providerID(entryID: mainRef, values: values)
    }

    private func isDefaultProvider(_ provider: String) -> Bool {
        provider == defaultProviderID()
    }

    private func configChildIDs(parentPath: String) -> [String] {
        let direct = YAMLScalarEditor.directChildKeys(parentPath: parentPath, in: state.pilotDeckConfigText)
        if !direct.isEmpty {
            return direct.sorted()
        }

        let prefix = parentPath + "."
        var ids = Set<String>()
        for key in LegacyConfigLoader.scalarMap(from: state.pilotDeckConfigText).keys where key.hasPrefix(prefix) {
            let suffix = key.dropFirst(prefix.count)
            if let first = suffix.split(separator: ".").first {
                ids.insert(String(first))
            }
        }
        return ids.sorted()
    }

    private var customEnvKeys: [String] {
        configChildIDs(parentPath: "customEnv")
    }

    private func isValidCustomEnvKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
            && !customEnvKeys.contains(trimmed)
    }

    private func addCustomEnvKey() {
        let key = newCustomEnvKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidCustomEnvKey(key) else { return }
        setConfigValue("customEnv.\(key)", newCustomEnvValue)
        newCustomEnvKey = ""
        newCustomEnvValue = ""
    }

    private func removeCustomEnvKey(_ key: String) {
        state.pilotDeckConfigText = YAMLScalarEditor.removeObject(
            components: ["customEnv", key],
            in: state.pilotDeckConfigText
        )
    }

    private func customEnvKeyLooksSecret(_ key: String) -> Bool {
        key.range(of: #"(KEY|TOKEN|SECRET|PASSWORD)"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func providerID(forEntry entry: String) -> String {
        NativeConfigService.splitModelRef(entry)?.providerID
            ?? nonBlank(configValue("models.entries.\(entry).provider"))
            ?? "pilotdeck"
    }

    private func modelName(forEntry entry: String) -> String {
        NativeConfigService.splitModelRef(entry)?.modelID
            ?? configValue("models.entries.\(entry).name")
    }

    private func modelPoolSummary(forEntry entry: String) -> String {
        let provider = providerID(forEntry: entry)
        let providerType = nonBlank(configValue("model.providers.\(provider).protocol"))
            ?? nonBlank(configValue("models.providers.\(provider).type"))
            ?? "openai"
        return "\(provider) · \(providerType)"
    }

    private func modelOptionLabel(_ option: String) -> String {
        if option == "inherit" {
            return state.t(.inheritMain)
        }
        if option.isEmpty {
            return state.t(.pickModelEntry)
        }
        let name = nonBlank(modelName(forEntry: option)) ?? option
        let duplicateCount = modelPoolEntryIDs.filter { candidate in
            nonBlank(modelName(forEntry: candidate)) == nonBlank(modelName(forEntry: option))
        }.count
        return duplicateCount > 1 ? "\(name) · \(providerID(forEntry: option))" : name
    }

    private func modelAssignmentOptions(path: String, includeInherit: Bool) -> [String] {
        var options: [String] = includeInherit ? ["inherit"] : []
        options.append(contentsOf: modelPoolEntryIDs)
        let currentValue = configValue(path).trimmingCharacters(in: .whitespacesAndNewlines)
        if currentValue.isEmpty {
            options.insert("", at: includeInherit ? 1 : 0)
        } else if !options.contains(currentValue) {
            let current = currentValue
            options.insert(current, at: includeInherit ? 1 : 0)
        }
        return options.isEmpty ? [""] : options
    }

    private func modelAssignmentPicker(path: String, includeInherit: Bool = false) -> some View {
        Picker("", selection: Binding(
            get: { configValue(path) },
            set: { value in
                if let parsed = NativeConfigService.splitModelRef(value) {
                    addWebModel(provider: parsed.providerID, model: parsed.modelID)
                }
                setConfigValue(path, value)
            }
        )) {
            ForEach(modelAssignmentOptions(path: path, includeInherit: includeInherit), id: \.self) { option in
                Text(modelOptionLabel(option)).tag(option)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 220)
    }

    private func dashedEmpty(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(DesignTokens.tertiaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous)
                    .stroke(DesignTokens.separator, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
    }

    private func webSettingsToggleRow(title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignTokens.text)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.tertiaryText)
                    .lineLimit(2)
            }
            Spacer()
            WebSettingsToggle(isOn: isOn)
        }
    }

    private func addModelPoolEntry() {
        let entryIDs = Set(modelPoolEntryIDs)
        var providerID = "provider1"
        var index = 1
        while entryIDs.contains("\(providerID)/model1") || configValue("model.providers.\(providerID).protocol") != "" {
            index += 1
            providerID = "provider\(index)"
        }
        let modelID = "model1"
        recentlyRemovedWebProviderIDs.remove(providerID)

        var yaml = state.pilotDeckConfigText
        yaml = YAMLScalarEditor.set(path: "model.providers.\(providerID).protocol", value: "openai", in: yaml)
        yaml = YAMLScalarEditor.set(path: "model.providers.\(providerID).url", value: "", in: yaml)
        yaml = YAMLScalarEditor.set(path: "model.providers.\(providerID).apiKey", value: "", in: yaml)
        yaml = YAMLScalarEditor.set(components: ["model", "providers", providerID, "models", modelID], value: "{}", in: yaml)
        state.pilotDeckConfigText = yaml
        selectedModelPoolEntry = NativeConfigService.modelRef(providerID: providerID, modelID: modelID)
    }

    private func enabledModels(forProvider provider: String) -> [String] {
        configChildIDs(parentPath: "model.providers.\(provider).models")
    }

    private func addCatalogProvider(_ provider: NativeModelCatalogProvider) {
        guard !webProviderIDs.contains(provider.id) else { return }
        recentlyRemovedWebProviderIDs.remove(provider.id)
        var yaml = state.pilotDeckConfigText
        yaml = YAMLScalarEditor.set(path: "model.providers.\(provider.id).protocol", value: provider.protocolValue, in: yaml)
        yaml = YAMLScalarEditor.set(path: "model.providers.\(provider.id).url", value: provider.defaultURL, in: yaml)
        yaml = YAMLScalarEditor.set(path: "model.providers.\(provider.id).apiKey", value: "", in: yaml)
        if provider.models.isEmpty {
            yaml = YAMLScalarEditor.set(components: ["model", "providers", provider.id, "models"], value: "{}", in: yaml)
        } else {
            for model in provider.models {
                yaml = YAMLScalarEditor.set(
                    components: ["model", "providers", provider.id, "models", model.id],
                    value: "{}",
                    in: yaml
                )
            }
        }
        state.pilotDeckConfigText = yaml
    }

    private func addCustomProvider() {
        var index = 1
        var providerID = "provider\(index)"
        while webProviderIDs.contains(providerID) || !configValue("model.providers.\(providerID).protocol").isEmpty {
            index += 1
            providerID = "provider\(index)"
        }
        recentlyRemovedWebProviderIDs.remove(providerID)
        var yaml = state.pilotDeckConfigText
        yaml = YAMLScalarEditor.set(path: "model.providers.\(providerID).protocol", value: "openai", in: yaml)
        yaml = YAMLScalarEditor.set(path: "model.providers.\(providerID).url", value: "", in: yaml)
        yaml = YAMLScalarEditor.set(path: "model.providers.\(providerID).apiKey", value: "", in: yaml)
        yaml = YAMLScalarEditor.set(components: ["model", "providers", providerID, "models"], value: "{}", in: yaml)
        state.pilotDeckConfigText = yaml
    }

    private func addWebModel(provider: String, model: String) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard NativeConfigCompatibility.isValidModelID(trimmed) else { return }
        recentlyRemovedWebProviderIDs.remove(provider)
        state.pilotDeckConfigText = YAMLScalarEditor.set(
            components: ["model", "providers", provider, "models", trimmed],
            value: "{}",
            in: state.pilotDeckConfigText
        )
    }

    private func addPendingCustomModel(provider: String) {
        let model = newModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return }
        addWebModel(provider: provider, model: model)
        newModelID = ""
    }

    private func removeWebModel(provider: String, model: String) {
        let ref = NativeConfigService.modelRef(providerID: provider, modelID: model)
        let fallback = modelPoolEntryIDs.first { $0 != ref }
        var yaml = YAMLScalarEditor.removeObject(
            components: ["model", "providers", provider, "models", model],
            in: state.pilotDeckConfigText
        )
        yaml = reassignModelReferences(removing: ref, fallback: fallback, in: yaml)
        state.pilotDeckConfigText = yaml
    }

    private func removeWebProvider(_ provider: String) {
        NSApp.keyWindow?.makeFirstResponder(nil)
        recentlyRemovedWebProviderIDs.insert(provider)
        let refs = modelPoolEntryIDs.filter { NativeConfigService.splitModelRef($0)?.providerID == provider }
        let fallback = modelPoolEntryIDs.first { NativeConfigService.splitModelRef($0)?.providerID != provider }
        var yaml = YAMLScalarEditor.removeObject(
            components: ["model", "providers", provider],
            in: state.pilotDeckConfigText
        )
        for ref in refs {
            yaml = reassignModelReferences(removing: ref, fallback: fallback, in: yaml)
        }
        state.pilotDeckConfigText = yaml
    }

    private func removeModelPoolEntry(_ entry: String) {
        if let parsed = NativeConfigService.splitModelRef(entry) {
            let fallbackEntry = modelPoolEntryIDs.first { $0 != entry }
            var yaml = YAMLScalarEditor.removeObject(
                components: ["model", "providers", parsed.providerID, "models", parsed.modelID],
                in: state.pilotDeckConfigText
            )
            yaml = reassignModelReferences(removing: entry, fallback: fallbackEntry, in: yaml)
            let remaining = NativeConfigService.modelEntryIDs(values: LegacyConfigLoader.scalarMap(from: yaml))
                .contains { NativeConfigService.splitModelRef($0)?.providerID == parsed.providerID }
            if !remaining {
                yaml = YAMLScalarEditor.removeObject(components: ["model", "providers", parsed.providerID], in: yaml)
            }
            state.pilotDeckConfigText = yaml
            if selectedModelPoolEntry == entry {
                selectedModelPoolEntry = nil
            }
            return
        }

        let provider = providerID(forEntry: entry)
        let fallbackEntry = modelPoolEntryIDs.first { $0 != entry }
        let remainingUses = modelPoolEntryIDs
            .filter { $0 != entry }
            .filter { providerID(forEntry: $0) == provider }
            .count
        var yaml = YAMLScalarEditor.removeObject(path: "models.entries.\(entry)", in: state.pilotDeckConfigText)
        yaml = reassignModelReferences(removing: entry, fallback: fallbackEntry, in: yaml)
        if remainingUses == 0, provider != "pilotdeck" {
            yaml = YAMLScalarEditor.removeObject(path: "models.providers.\(provider)", in: yaml)
        }
        state.pilotDeckConfigText = yaml
        if selectedModelPoolEntry == entry {
            selectedModelPoolEntry = nil
        }
    }

    private func reassignModelReferences(removing removedEntry: String, fallback: String?, in yaml: String) -> String {
        let values = LegacyConfigLoader.scalarMap(from: yaml)
        return NativeModelsConfigFormFields.assignmentPaths.reduce(yaml) { result, path in
            guard values[path] == removedEntry || values[canonicalConfigPath(path)] == removedEntry else { return result }
            let replacement = NativeModelsConfigFormFields.inheritableAssignmentPaths.contains(path)
                ? (fallback ?? "inherit")
                : (fallback ?? "")
            return YAMLScalarEditor.set(path: canonicalConfigPath(path), value: replacement, in: result)
        }
    }

    private func webModelScalar(provider: String, model: String, suffix: [String]) -> String {
        let path = (["model", "providers", provider, "models", model] + suffix).joined(separator: ".")
        return LegacyConfigLoader.scalarMap(from: state.pilotDeckConfigText)[path] ?? ""
    }

    private func setWebModelScalar(provider: String, model: String, suffix: [String], value: String) {
        state.pilotDeckConfigText = YAMLScalarEditor.set(
            components: ["model", "providers", provider, "models", model] + suffix,
            value: value,
            in: state.pilotDeckConfigText
        )
    }

    private func renameWebModel(provider: String, oldID: String, newID rawNewID: String) {
        let newID = rawNewID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard NativeConfigCompatibility.isValidModelID(newID), newID != oldID else { return }
        let oldRef = NativeConfigService.modelRef(providerID: provider, modelID: oldID)
        let newRef = NativeConfigService.modelRef(providerID: provider, modelID: newID)
        guard !modelPoolEntryIDs.contains(newRef) else { return }
        var yaml = YAMLScalarEditor.renameObject(
            parentComponents: ["model", "providers", provider, "models"],
            oldID: oldID,
            newID: newID,
            in: state.pilotDeckConfigText
        )
        yaml = replaceModelReference(oldRef: oldRef, newRef: newRef, in: yaml)
        state.pilotDeckConfigText = yaml
        selectedModelPoolEntry = newRef
    }

    private func renameWebProvider(oldID: String, newID rawNewID: String) {
        let newID = rawNewID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard NativeConfigCompatibility.isValidProviderID(newID), newID != oldID else { return }
        guard configValue("model.providers.\(newID).protocol").isEmpty else { return }
        var yaml = YAMLScalarEditor.renameObject(
            parentComponents: ["model", "providers"],
            oldID: oldID,
            newID: newID,
            in: state.pilotDeckConfigText
        )
        for entry in modelPoolEntryIDs {
            guard let parsed = NativeConfigService.splitModelRef(entry), parsed.providerID == oldID else { continue }
            let newRef = NativeConfigService.modelRef(providerID: newID, modelID: parsed.modelID)
            yaml = replaceModelReference(oldRef: entry, newRef: newRef, in: yaml)
            if selectedModelPoolEntry == entry {
                selectedModelPoolEntry = newRef
            }
        }
        state.pilotDeckConfigText = yaml
    }

    private func replaceModelReference(oldRef: String, newRef: String, in yaml: String) -> String {
        let values = LegacyConfigLoader.scalarMap(from: yaml)
        return NativeModelsConfigFormFields.assignmentPaths.reduce(yaml) { result, path in
            values[path] == oldRef || values[canonicalConfigPath(path)] == oldRef
                ? YAMLScalarEditor.set(path: canonicalConfigPath(path), value: newRef, in: result)
                : result
        }
    }

    private func selectedMemoryProjectTarget() -> MemorySettingsTransferTarget? {
        guard let project = state.selectedProject else { return nil }
        return MemorySettingsTransferTarget(
            projectName: project.name,
            displayName: project.displayName,
            rootPath: state.effectiveWorkspacePath(for: project)
        )
    }

    private func selectedMemoryProjectDetail() -> String {
        guard let target = selectedMemoryProjectTarget() else {
            return state.t(.noProjectSelected)
        }
        return "\(target.displayName) · \(target.rootPath)"
    }

    private func memoryBundleFilename(scope: MemorySettingsTransferScope) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: Date())
        switch scope {
        case .currentProject:
            return "pilotdeck-memory-current-project-\(date).json"
        case .allMemory:
            return "pilotdeck-memory-all-\(date).json"
        }
    }

    private func exportMemoryBundle(scope: MemorySettingsTransferScope) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = memoryBundleFilename(scope: scope)
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data: Data
            switch scope {
            case .currentProject:
                guard let target = selectedMemoryProjectTarget() else {
                    state.errorBanner = state.t(.noProjectSelected)
                    return
                }
                state.memoryService.loadWorkspaceRecords(projectRoot: target.rootPath, projectName: target.projectName)
                data = try state.memoryService.exportBundle(projectName: target.projectName, projectRoot: target.rootPath)
            case .allMemory:
                if let target = selectedMemoryProjectTarget() {
                    state.memoryService.loadWorkspaceRecords(projectRoot: target.rootPath, projectName: target.projectName)
                }
                data = try state.memoryService.exportBundle(projectName: nil)
            }
            try data.write(to: url, options: [.atomic])
            state.settingsSaveNotice = local(chinese: "记忆已导出。", english: "Memory exported.")
        } catch {
            state.errorBanner = error.localizedDescription
        }
    }

    private func importMemoryBundle(scope: MemorySettingsTransferScope) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let bundleScope = memoryBundleScope(from: data)
            switch scope {
            case .currentProject:
                guard let target = selectedMemoryProjectTarget() else {
                    state.errorBanner = state.t(.noProjectSelected)
                    return
                }
                if bundleScope == "all_projects" {
                    state.errorBanner = local(chinese: "这是所有记忆备份，请在“所有记忆”里导入。", english: "This is an all-memory backup. Import it from All Memory.")
                    return
                }
                try state.memoryService.importBundle(data, projectName: target.projectName, projectRoot: target.rootPath)
                state.memoryService.loadWorkspaceRecords(projectRoot: target.rootPath, projectName: target.projectName)
            case .allMemory:
                if bundleScope == "current_project" {
                    state.errorBanner = local(chinese: "这是当前项目记忆备份，请在“当前项目记忆”里导入。", english: "This is a current-project memory backup. Import it from Current Project Memory.")
                    return
                }
                try state.memoryService.importBundle(data, projectName: nil, projectRoot: nil)
                if let target = selectedMemoryProjectTarget() {
                    state.memoryService.loadWorkspaceRecords(projectRoot: target.rootPath, projectName: target.projectName)
                }
            }
            state.bumpToolRefresh()
            state.settingsSaveNotice = local(chinese: "记忆已导入。", english: "Memory imported.")
        } catch {
            state.errorBanner = error.localizedDescription
        }
    }

    private func clearMemory(scope: MemorySettingsTransferScope) {
        guard confirmClearMemory(scope: scope) else { return }
        switch scope {
        case .currentProject:
            guard let target = selectedMemoryProjectTarget() else {
                state.errorBanner = state.t(.noProjectSelected)
                return
            }
            state.memoryService.clear(projectName: target.projectName, projectRoot: target.rootPath)
            state.memoryService.loadWorkspaceRecords(projectRoot: target.rootPath, projectName: target.projectName)
            state.settingsSaveNotice = local(chinese: "当前项目记忆已清除。", english: "Current project memory cleared.")
        case .allMemory:
            state.memoryService.clear(projectName: nil, projectRoot: nil)
            if let target = selectedMemoryProjectTarget() {
                state.memoryService.loadWorkspaceRecords(projectRoot: target.rootPath, projectName: target.projectName)
            }
            state.settingsSaveNotice = local(chinese: "所有记忆已清除。", english: "All memory cleared.")
        }
        state.bumpToolRefresh()
    }

    private func confirmClearMemory(scope: MemorySettingsTransferScope) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch scope {
        case .currentProject:
            let targetName = selectedMemoryProjectTarget()?.displayName ?? local(chinese: "当前项目", english: "Current Project")
            alert.messageText = local(chinese: "清除当前项目记忆？", english: "Clear current project memory?")
            alert.informativeText = local(
                chinese: "这会删除“\(targetName)”的记忆文件。此操作不能撤销。",
                english: "This will delete memory files for “\(targetName)”. This action cannot be undone."
            )
        case .allMemory:
            alert.messageText = local(chinese: "清除所有记忆？", english: "Clear all memory?")
            alert.informativeText = local(
                chinese: "这会删除用户/全局记忆，以及 PilotDeck 当前已知项目的记忆文件。此操作不能撤销。",
                english: "This will delete user/global memory and memory files for projects currently known to PilotDeck. This action cannot be undone."
            )
        }
        alert.addButton(withTitle: local(chinese: "清除", english: "Clear"))
        alert.addButton(withTitle: state.t(.cancel))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func memoryBundleScope(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["scope"] as? String
    }

    private func exportPermissions() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = PermissionsExportDefaults.filename()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try state.exportPermissions(to: url)
            state.settingsSaveNotice = state.t(.exported)
        } catch {
            state.errorBanner = error.localizedDescription
        }
    }

    private func importPermissions() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try state.importPermissions(from: url)
            state.settingsSaveNotice = state.t(.imported)
        } catch {
            state.errorBanner = error.localizedDescription
        }
    }
}

private enum MemorySettingsTransferScope {
    case currentProject
    case allMemory
}

enum NativeMemorySettingsTransferActions {
    static let currentProject = ["import", "export", "clear"]
    static let allMemory = ["import", "export", "clear"]
}

private struct MemorySettingsTransferTarget {
    var projectName: String
    var displayName: String
    var rootPath: String
}

private struct SettingsPageContainer<Content: View>: View {
    var title: String
    var backLabel: String?
    var onBack: (() -> Void)?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let backLabel, let onBack {
                Button(action: onBack) {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                        Text(backLabel)
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(DesignTokens.secondaryText)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 2)
            }
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            content()
        }
        .padding(.top, 48)
        .padding(.bottom, 36)
        .padding(.horizontal, 40)
        .frame(maxWidth: 860, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

private enum SettingsPage: Hashable {
    case main
    case behavior
    case codeEditor
    case permissions
    case config
    case mcp
}

enum NativeMCPConfigScope: String, CaseIterable, Identifiable, Hashable {
    case global
    case project

    var id: String { rawValue }
}

enum NativeMCPTransport: String, CaseIterable, Identifiable, Hashable {
    case stdio
    case http

    var id: String { rawValue }
}

struct NativeMCPConfigDraft: Hashable {
    var path: String
    var exists: Bool
    var servers: [NativeMCPServerDraft]
    var rawJSON: String

    static let empty = NativeMCPConfigDraft(
        path: "",
        exists: false,
        servers: [],
        rawJSON: NativeMCPConfigService.emptyRawJSON
    )
}

struct NativeMCPServerDraft: Identifiable, Hashable {
    var id: UUID
    var name: String
    var transport: NativeMCPTransport
    var command: String
    var argsText: String
    var envText: String
    var perSession: Bool
    var url: String
    var headersText: String

    static func template(name: String, transport: NativeMCPTransport) -> NativeMCPServerDraft {
        switch transport {
        case .stdio:
            return NativeMCPServerDraft(
                id: UUID(),
                name: name,
                transport: .stdio,
                command: "npx",
                argsText: "-y\nsome-mcp-server",
                envText: "API_KEY=${env:API_KEY}",
                perSession: false,
                url: "",
                headersText: ""
            )
        case .http:
            return NativeMCPServerDraft(
                id: UUID(),
                name: name,
                transport: .http,
                command: "",
                argsText: "",
                envText: "",
                perSession: false,
                url: "https://example.com/mcp",
                headersText: "Authorization=Bearer ${env:MCP_TOKEN}"
            )
        }
    }
}

enum NativeMCPConfigService {
    static let emptyRawJSON = """
    {
      "mcpServers" : {

      }
    }
    """

    static func globalConfigURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".pilotdeck", isDirectory: true)
            .appendingPathComponent("mcp.json")
    }

    static func projectConfigURL(projectRoot: String) -> URL {
        let root = projectRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else { return URL(fileURLWithPath: "") }
        return URL(fileURLWithPath: root)
            .appendingPathComponent(".pilotdeck", isDirectory: true)
            .appendingPathComponent("mcp.json")
    }

    static func configURL(scope: NativeMCPConfigScope, projectRoot: String) -> URL {
        switch scope {
        case .global:
            return globalConfigURL()
        case .project:
            return projectConfigURL(projectRoot: projectRoot)
        }
    }

    static func emptyDraft(scope: NativeMCPConfigScope, projectRoot: String) -> NativeMCPConfigDraft {
        NativeMCPConfigDraft(
            path: configURL(scope: scope, projectRoot: projectRoot).path,
            exists: false,
            servers: [],
            rawJSON: emptyRawJSON
        )
    }

    static func load(scope: NativeMCPConfigScope, projectRoot: String) throws -> NativeMCPConfigDraft {
        let url = configURL(scope: scope, projectRoot: projectRoot)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return NativeMCPConfigDraft(path: url.path, exists: false, servers: [], rawJSON: emptyRawJSON)
        }
        let raw = try String(contentsOf: url, encoding: .utf8)
        return try parse(raw: raw, path: url.path, exists: true)
    }

    static func save(raw: String, scope: NativeMCPConfigScope, projectRoot: String) throws -> NativeMCPConfigDraft {
        let url = configURL(scope: scope, projectRoot: projectRoot)
        let draft = try parse(raw: raw, path: url.path, exists: true)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try draft.rawJSON.write(to: url, atomically: true, encoding: .utf8)
        return NativeMCPConfigDraft(path: url.path, exists: true, servers: draft.servers, rawJSON: draft.rawJSON)
    }

    static func parse(raw: String, path: String, exists: Bool) throws -> NativeMCPConfigDraft {
        let data = Data(raw.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw NativeMCPConfigError.invalidRoot
        }
        let rawServers = root["mcpServers"]
        if rawServers == nil {
            return NativeMCPConfigDraft(path: path, exists: exists, servers: [], rawJSON: try rawJSON(servers: []))
        }
        guard let serversObject = rawServers as? [String: Any] else {
            throw NativeMCPConfigError.invalidServers
        }
        let servers = try serversObject.keys.sorted().map { name in
            try serverDraft(name: name, value: serversObject[name] ?? [:])
        }
        return NativeMCPConfigDraft(path: path, exists: exists, servers: servers, rawJSON: try rawJSON(servers: servers))
    }

    static func rawJSON(servers: [NativeMCPServerDraft]) throws -> String {
        var serverObjects: [String: Any] = [:]
        for server in servers {
            let name = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw NativeMCPConfigError.emptyName }
            guard serverObjects[name] == nil else { throw NativeMCPConfigError.duplicateName(name) }
            switch server.transport {
            case .stdio:
                let command = server.command.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !command.isEmpty else { throw NativeMCPConfigError.missingCommand(name) }
                var item: [String: Any] = ["command": command]
                let args = nonEmptyLines(server.argsText)
                if !args.isEmpty { item["args"] = args }
                let env = keyValueLines(server.envText)
                if !env.isEmpty { item["env"] = env }
                if server.perSession { item["perSession"] = true }
                serverObjects[name] = item
            case .http:
                let url = server.url.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !url.isEmpty else { throw NativeMCPConfigError.missingURL(name) }
                var item: [String: Any] = ["url": url]
                let headers = keyValueLines(server.headersText)
                if !headers.isEmpty { item["headers"] = headers }
                serverObjects[name] = item
            }
        }
        let root: [String: Any] = ["mcpServers": serverObjects]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    private static func serverDraft(name: String, value: Any) throws -> NativeMCPServerDraft {
        guard let raw = value as? [String: Any] else {
            throw NativeMCPConfigError.invalidServer(name)
        }
        if let command = raw["command"] as? String {
            return NativeMCPServerDraft(
                id: UUID(),
                name: name,
                transport: .stdio,
                command: command,
                argsText: stringArray(raw["args"]).joined(separator: "\n"),
                envText: lines(from: stringDictionary(raw["env"])),
                perSession: (raw["perSession"] as? Bool) == true,
                url: "",
                headersText: ""
            )
        }
        if let url = (raw["url"] as? String) ?? (raw["httpUrl"] as? String) {
            return NativeMCPServerDraft(
                id: UUID(),
                name: name,
                transport: .http,
                command: "",
                argsText: "",
                envText: "",
                perSession: false,
                url: url,
                headersText: lines(from: stringDictionary(raw["headers"]))
            )
        }
        throw NativeMCPConfigError.unrecognizedTransport(name)
    }

    private static func stringArray(_ value: Any?) -> [String] {
        (value as? [Any])?.compactMap { $0 as? String } ?? []
    }

    private static func stringDictionary(_ value: Any?) -> [String: String] {
        guard let object = value as? [String: Any] else { return [:] }
        return object.reduce(into: [:]) { result, item in
            if let value = item.value as? String {
                result[item.key] = value
            }
        }
    }

    private static func lines(from dictionary: [String: String]) -> String {
        dictionary.keys.sorted().map { "\($0)=\(dictionary[$0] ?? "")" }.joined(separator: "\n")
    }

    private static func nonEmptyLines(_ text: String) -> [String] {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func keyValueLines(_ text: String) -> [String: String] {
        nonEmptyLines(text).reduce(into: [:]) { result, line in
            guard let separator = line.firstIndex(where: { $0 == "=" || $0 == ":" }) else { return }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            result[key] = value
        }
    }
}

enum NativeMCPConfigError: LocalizedError, Equatable {
    case invalidRoot
    case invalidServers
    case invalidServer(String)
    case unrecognizedTransport(String)
    case emptyName
    case duplicateName(String)
    case missingCommand(String)
    case missingURL(String)

    var errorDescription: String? {
        switch self {
        case .invalidRoot:
            return "MCP config root must be a JSON object."
        case .invalidServers:
            return "mcpServers must be a JSON object."
        case .invalidServer(let name):
            return "MCP server \"\(name)\" must be a JSON object."
        case .unrecognizedTransport(let name):
            return "MCP server \"\(name)\" must define command, url, or httpUrl."
        case .emptyName:
            return "MCP server name cannot be empty."
        case .duplicateName(let name):
            return "MCP server \"\(name)\" is duplicated."
        case .missingCommand(let name):
            return "MCP server \"\(name)\" requires a command."
        case .missingURL(let name):
            return "MCP server \"\(name)\" requires a URL."
        }
    }
}

private struct PermissionListSection: View {
    @EnvironmentObject private var state: AppState
    @State private var draft = ""
    var title: String
    var detail: String
    var tint: Color
    var items: [String]
    var quickItems: [String]
    var placeholder: String
    var onAdd: (String) -> Void
    var onRemove: (String) -> Void

    var body: some View {
        SettingsSectionBlock(title: title, detail: detail) {
            SettingsCardBlock {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        TextField(placeholder, text: $draft)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.regular)
                            .onSubmit { addDraft() }
                        Button {
                            addDraft()
                        } label: {
                            Label(state.t(.add), systemImage: "plus")
                        }
                        .buttonStyle(WebToolbarButtonStyle(isProminent: true))
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Text(state.t(.quickAdd))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DesignTokens.tertiaryText)
                    FlowLayout(spacing: 8) {
                        ForEach(quickItems, id: \.self) { item in
                            Button(item) {
                                onAdd(item)
                            }
                            .buttonStyle(WebToolbarButtonStyle())
                            .disabled(items.contains(item))
                        }
                    }
                    VStack(spacing: 8) {
                        if items.isEmpty {
                            Text(title == state.t(.allowedTools) ? state.t(.noAllowedToolsConfigured) : state.t(.noBlockedToolsConfigured))
                                .font(.system(size: 12))
                                .foregroundStyle(DesignTokens.tertiaryText)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 18)
                                .overlay(
                                    RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous)
                                        .stroke(DesignTokens.separator, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                )
                        } else {
                            ForEach(items, id: \.self) { item in
                                HStack {
                                    Text(item)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(tint)
                                    Spacer()
                                    Button {
                                        onRemove(item)
                                    } label: {
                                        Image(systemName: "xmark")
                                            .frame(width: 24, height: 24)
                                    }
                                    .buttonStyle(SettingsIconButtonStyle())
                                }
                                .padding(.horizontal, 10)
                                .frame(height: 36)
                                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous)
                                        .stroke(tint.opacity(0.25), lineWidth: 1)
                                )
                            }
                        }
                    }
                }
                .padding(12)
            }
        }
    }

    private func addDraft() {
        onAdd(draft)
        draft = ""
    }
}

private struct ConfigSummary: View {
    @EnvironmentObject private var state: AppState
    var text: String
    var keys: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(keys, id: \.self) { key in
                HStack {
                    Text(key)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    Spacer()
                    Text(text.contains(key) ? state.t(.present) : state.t(.missing))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(text.contains(key) ? DesignTokens.success : DesignTokens.warning)
                }
                .padding(.vertical, 3)
            }
            Text(state.t(.configSummaryHelp))
                .font(.system(size: 12))
                .foregroundStyle(DesignTokens.tertiaryText)
        }
    }
}

enum NativeAppearanceSection: String, CaseIterable, Identifiable {
    case colorScheme
    case language
    case toolDisplay
    case viewOptions
    case inputSettings
    case projectSorting
    case codeEditor

    var id: String { rawValue }
}

enum NativeAppearanceSettingsLayout {
    static let sectionOrder: [NativeAppearanceSection] = [
        .colorScheme,
        .language,
        .toolDisplay,
        .viewOptions,
        .inputSettings,
        .projectSorting,
        .codeEditor,
    ]
    static let usesDarkModeToggle = false
    static let usesThemePicker = true
    static let colorSchemePickerWidth: CGFloat = 160
    static let languagePickerWidth: CGFloat = 160
    static let projectSortingPickerWidth: CGFloat = 160
    static let fontSizeOptions = [
        10,
        11,
        12,
        13,
        14,
        15,
        16,
        18,
        20,
    ]
}

private struct NativeModelCatalogModel: Hashable, Identifiable {
    let id: String
    let displayName: String
    var supportsImage = false
    var maxContextTokens: Int?
}

private struct NativeModelCatalogProvider: Hashable, Identifiable {
    let id: String
    let displayName: String
    let protocolValue: String
    let defaultURL: String
    let models: [NativeModelCatalogModel]
}

private enum NativeModelCatalog {
    static let providers: [NativeModelCatalogProvider] = [
        NativeModelCatalogProvider(
            id: "anthropic",
            displayName: "Anthropic",
            protocolValue: "anthropic",
            defaultURL: "https://api.anthropic.com",
            models: [
                NativeModelCatalogModel(id: "claude-sonnet-4.6", displayName: "Claude Sonnet 4.6", supportsImage: true, maxContextTokens: 200_000),
                NativeModelCatalogModel(id: "claude-opus-4-20250514", displayName: "Claude Opus 4", supportsImage: true, maxContextTokens: 200_000),
                NativeModelCatalogModel(id: "claude-sonnet-4-20250514", displayName: "Claude Sonnet 4", supportsImage: true, maxContextTokens: 200_000),
                NativeModelCatalogModel(id: "claude-haiku-3-5-20241022", displayName: "Claude 3.5 Haiku", supportsImage: true, maxContextTokens: 200_000),
            ]
        ),
        NativeModelCatalogProvider(
            id: "openai",
            displayName: "OpenAI",
            protocolValue: "openai",
            defaultURL: "https://api.openai.com/v1",
            models: [
                NativeModelCatalogModel(id: "gpt-4.1", displayName: "GPT-4.1", supportsImage: true, maxContextTokens: 1_047_576),
                NativeModelCatalogModel(id: "gpt-4.1-mini", displayName: "GPT-4.1 Mini", supportsImage: true, maxContextTokens: 1_047_576),
                NativeModelCatalogModel(id: "gpt-4o", displayName: "GPT-4o", supportsImage: true, maxContextTokens: 128_000),
                NativeModelCatalogModel(id: "gpt-4o-mini", displayName: "GPT-4o Mini", supportsImage: true, maxContextTokens: 128_000),
                NativeModelCatalogModel(id: "o3", displayName: "o3", supportsImage: true, maxContextTokens: 200_000),
            ]
        ),
        NativeModelCatalogProvider(
            id: "deepseek",
            displayName: "DeepSeek",
            protocolValue: "openai",
            defaultURL: "https://api.deepseek.com/v1",
            models: [
                NativeModelCatalogModel(id: "deepseek-v4-pro", displayName: "DeepSeek V4 Pro", maxContextTokens: 131_072),
                NativeModelCatalogModel(id: "deepseek-v4-flash", displayName: "DeepSeek V4 Flash", maxContextTokens: 1_048_576),
                NativeModelCatalogModel(id: "deepseek-chat", displayName: "DeepSeek Chat (V3)", maxContextTokens: 65_536),
                NativeModelCatalogModel(id: "deepseek-reasoner", displayName: "DeepSeek Reasoner", maxContextTokens: 65_536),
            ]
        ),
        NativeModelCatalogProvider(
            id: "google",
            displayName: "Google AI",
            protocolValue: "openai",
            defaultURL: "https://generativelanguage.googleapis.com/v1beta/openai",
            models: [
                NativeModelCatalogModel(id: "gemini-2.5-pro", displayName: "Gemini 2.5 Pro", supportsImage: true, maxContextTokens: 1_048_576),
                NativeModelCatalogModel(id: "gemini-2.5-flash", displayName: "Gemini 2.5 Flash", supportsImage: true, maxContextTokens: 1_048_576),
                NativeModelCatalogModel(id: "gemini-2.0-flash", displayName: "Gemini 2.0 Flash", supportsImage: true, maxContextTokens: 1_048_576),
            ]
        ),
        NativeModelCatalogProvider(
            id: "openrouter",
            displayName: "OpenRouter",
            protocolValue: "openai",
            defaultURL: "https://openrouter.ai/api/v1",
            models: [
                NativeModelCatalogModel(id: "anthropic/claude-sonnet-4.6", displayName: "Claude Sonnet 4.6", supportsImage: true, maxContextTokens: 200_000),
                NativeModelCatalogModel(id: "google/gemini-2.5-pro", displayName: "Gemini 2.5 Pro", supportsImage: true, maxContextTokens: 1_048_576),
                NativeModelCatalogModel(id: "deepseek/deepseek-v4-flash", displayName: "DeepSeek V4 Flash", maxContextTokens: 1_048_576),
            ]
        ),
        NativeModelCatalogProvider(
            id: "minimax",
            displayName: "MiniMax",
            protocolValue: "openai",
            defaultURL: "https://api.minimaxi.com/v1",
            models: [
                NativeModelCatalogModel(id: "MiniMax-M2.5", displayName: "MiniMax M2.5", maxContextTokens: 1_000_000),
                NativeModelCatalogModel(id: "MiniMax-M2.7-highspeed", displayName: "MiniMax M2.7 Highspeed", maxContextTokens: 1_000_000),
            ]
        ),
        NativeModelCatalogProvider(
            id: "moonshot",
            displayName: "Moonshot AI (Kimi)",
            protocolValue: "openai",
            defaultURL: "https://api.moonshot.cn/v1",
            models: [
                NativeModelCatalogModel(id: "kimi-k2.6", displayName: "Kimi K2.6", supportsImage: true, maxContextTokens: 262_144),
                NativeModelCatalogModel(id: "kimi-k1.5", displayName: "Kimi K1.5", supportsImage: true, maxContextTokens: 131_072),
            ]
        ),
    ]

    static func provider(id: String) -> NativeModelCatalogProvider? {
        providers.first { $0.id == id }
    }

    static func model(providerID: String, modelID: String) -> NativeModelCatalogModel? {
        provider(id: providerID)?.models.first { $0.id == modelID }
    }
}

enum NativeConfigFormLayout {
    static let usesGroupedSectionHome = true
    static let usesSplitSectionNavigation = false
    static let usesSectionDropdown = false
    static let usesViewModeToggle = false
    static let exposesRawYAMLEditor = false
    static let headerActionIDs = [
        "revealInFinder",
        "import",
        "export",
        "saveAndReloadCurrent",
    ]
    static let sectionNavigationWidth: CGFloat = 180
    static let sectionNavigationGap: CGFloat = 16
    static let sectionOrder: [PilotDeckConfigSection] = [
        .models,
        .agents,
        .router,
        .memory,
        .search,
        .alwaysOn,
        .gateway,
        .runtime,
        .customEnv,
    ]
}

enum NativeReloadSummaryState: Hashable {
    case alwaysReloaded
    case boolPath(String)
    case nonEmptyPath(String)
}

struct NativeConfigReloadSubsystemSpec: Hashable, Identifiable {
    let id: String
    let label: L10nKey
    let state: NativeReloadSummaryState
    let reloadedDetail: L10nKey
    let skippedDetail: L10nKey?
}

enum NativeConfigReloadSummary {
    static let subsystems: [NativeConfigReloadSubsystemSpec] = [
        NativeConfigReloadSubsystemSpec(
            id: "processEnv",
            label: .processEnv,
            state: .alwaysReloaded,
            reloadedDetail: .nativeSettingsApplied,
            skippedDetail: nil
        ),
        NativeConfigReloadSubsystemSpec(
            id: "memory",
            label: .memory,
            state: .boolPath("memory.enabled"),
            reloadedDetail: .memoryServiceEnabled,
            skippedDetail: .memoryDisabled
        ),
        NativeConfigReloadSubsystemSpec(
            id: "router",
            label: .routerCCR,
            state: .boolPath("router.enabled"),
            reloadedDetail: .routerDashboardNative,
            skippedDetail: .routerDisabled
        ),
        NativeConfigReloadSubsystemSpec(
            id: "gateway",
            label: .gateway,
            state: .boolPath("gateway.enabled"),
            reloadedDetail: .gatewayConfigParsed,
            skippedDetail: nil
        ),
    ]

    static var subsystemIDs: [String] {
        subsystems.map(\.id)
    }
}

enum NativeConfigModelOptions {
    static func entryIDs(values: [String: String]) -> [String] {
        NativeConfigService.modelEntryIDs(values: values)
    }

    static func options(
        values: [String: String],
        includeEmpty: Bool = false,
        includeInherit: Bool = false
    ) -> [String] {
        var result: [String] = []
        if includeEmpty {
            result.append("")
        }
        if includeInherit {
            result.append("inherit")
        }
        result.append(contentsOf: entryIDs(values: values))
        return result
    }
}

enum NativeModelsConfigFormFields {
    static let usesProviderCards = true
    static let usesCatalogProviderPicker = true
    static let usesModelPoolDropdown = false
    static let usageAssignmentsLiveInModelSection = false
    static let entryRowsExposeProviderPicker = false
    static let entryRowsExposeModelNameField = false
    static let assignmentPaths = [
        "agent.model",
        "agent.subagents.default",
        "memory.model",
        "router.scenarios.default",
        "router.scenarios.background",
        "router.scenarios.think",
        "router.scenarios.longContext",
        "router.scenarios.webSearch",
        "router.tokenSaver.judge",
        "router.tokenSaver.tiers.simple.model",
        "router.tokenSaver.tiers.medium.model",
        "router.tokenSaver.tiers.complex.model",
        "router.tokenSaver.tiers.reasoning.model",
        "router.autoOrchestrate.mainAgentModel",
    ]
    static let inheritableAssignmentPaths: Set<String> = [
        "agent.subagents.default",
        "memory.model",
    ]
    static let providerProtocolOptions = [
        "openai",
        "anthropic",
    ]
    static let defaultProviderType = "openai"
    static let providerTypeOptions = providerProtocolOptions
    static let newProviderScalars = [
        "protocol": defaultProviderType,
        "url": "",
        "apiKey": "",
        "models": "{}",
    ]

    static func newEntryScalars(firstProvider: String) -> [String: String] {
        [
            "provider": firstProvider,
            "model": "",
        ]
    }

    static func providerProtocolLabel(_ value: String) -> String {
        switch value {
        case "openai": return "openai"
        case "anthropic": return "anthropic"
        default: return value
        }
    }
}

enum NativeAgentConfigFormFields {
    static let visiblePaths = [
        "agent.model",
        "agent.subagents.default",
    ]
}

struct NativeModelAssignmentRowSpec: Hashable, Identifiable {
    let id: String
    let title: String
    let detail: String
    let path: String
    var includeInherit = false
}

struct NativeRouterModelFieldSpec: Hashable, Identifiable {
    let id: String
    let label: L10nKey
    let path: String
}

struct NativeConfigTextFieldSpec: Hashable, Identifiable {
    let label: L10nKey
    let path: String
    var isSecure = false

    var id: String { path }
}

struct NativeAlwaysOnConfigFieldSpec: Hashable, Identifiable {
    let path: String
    let englishLabel: String
    let chineseLabel: String

    var id: String { path }
}

enum NativeRuntimeConfigFormFields {
    static let workspacesRootPath = "webui.runtime.workspacesRoot"
    static let generalWorkspacePath = "gateway.runtimePaths.generalCwd"
    static let textFields: [NativeConfigTextFieldSpec] = [
        NativeConfigTextFieldSpec(label: .apiTimeoutMs, path: "webui.runtime.apiTimeoutMs"),
        NativeConfigTextFieldSpec(label: .databasePath, path: "webui.runtime.databasePath"),
        NativeConfigTextFieldSpec(label: .httpsProxy, path: "webui.runtime.httpsProxy"),
    ]
    static let visiblePaths: [String] = [
        workspacesRootPath,
        generalWorkspacePath,
    ] + textFields.map(\.path)
}

enum NativeAlwaysOnConfigFormFields {
    static let enabledPath = "alwaysOn.enabled"
    static let triggerEnabledPath = "alwaysOn.trigger.enabled"
    static let triggerFields: [NativeAlwaysOnConfigFieldSpec] = [
        NativeAlwaysOnConfigFieldSpec(path: "alwaysOn.trigger.tickIntervalMinutes", englishLabel: "Tick Interval (minutes)", chineseLabel: "检查间隔（分钟）"),
        NativeAlwaysOnConfigFieldSpec(path: "alwaysOn.trigger.cooldownMinutes", englishLabel: "Cooldown (minutes)", chineseLabel: "冷却时间（分钟）"),
        NativeAlwaysOnConfigFieldSpec(path: "alwaysOn.trigger.dailyBudget", englishLabel: "Daily Budget", chineseLabel: "每日运行预算"),
        NativeAlwaysOnConfigFieldSpec(path: "alwaysOn.trigger.heartbeatStaleSeconds", englishLabel: "Heartbeat stale (seconds)", chineseLabel: "心跳过期（秒）"),
        NativeAlwaysOnConfigFieldSpec(path: "alwaysOn.trigger.recentUserMsgMinutes", englishLabel: "Recent user message (minutes)", chineseLabel: "最近用户消息（分钟）"),
    ]
    static let workspaceFields: [NativeAlwaysOnConfigFieldSpec] = [
        NativeAlwaysOnConfigFieldSpec(path: "alwaysOn.workspace.gitWorktreeBaseDir", englishLabel: "Git worktree base dir", chineseLabel: "Git worktree 目录"),
        NativeAlwaysOnConfigFieldSpec(path: "alwaysOn.workspace.snapshotBaseDir", englishLabel: "Snapshot base dir", chineseLabel: "快照目录"),
        NativeAlwaysOnConfigFieldSpec(path: "alwaysOn.workspace.snapshotMaxBytes", englishLabel: "Snapshot max bytes", chineseLabel: "快照最大字节数"),
    ]
    static let executionFields: [NativeAlwaysOnConfigFieldSpec] = [
        NativeAlwaysOnConfigFieldSpec(path: "alwaysOn.execution.maxTurns", englishLabel: "Max turns", chineseLabel: "最大轮次"),
        NativeAlwaysOnConfigFieldSpec(path: "alwaysOn.execution.maxToolCalls", englishLabel: "Max tool calls", chineseLabel: "最大工具调用"),
        NativeAlwaysOnConfigFieldSpec(path: "alwaysOn.execution.timeoutMinutes", englishLabel: "Timeout (minutes)", chineseLabel: "超时（分钟）"),
    ]
    static let visiblePaths = [
        enabledPath,
        triggerEnabledPath,
        "alwaysOn.trigger.preferChannel",
        "alwaysOn.dormancy.enabled",
        "alwaysOn.dormancy.debounceMs",
        "alwaysOn.dormancy.ignoreGlobs",
        "alwaysOn.workspace.gitLfs",
    ] + triggerFields.map(\.path) + workspaceFields.map(\.path) + executionFields.map(\.path)
}

enum NativeSearchConfigFormFields {
    static let providerPath = "tools.webSearch.provider"
    static let providerOptions = ["glm", "tavily", "custom"]
    static let exposesTestConnectionAction = true
    static let defaultEndpoints = [
        "glm": "https://api.z.ai/api/paas/v4/web_search",
        "tavily": "https://api.tavily.com/search",
    ]
    static let primaryFields: [NativeConfigTextFieldSpec] = [
        NativeConfigTextFieldSpec(label: .apiKey, path: "tools.webSearch.apiKey", isSecure: true),
        NativeConfigTextFieldSpec(label: .endpointURL, path: "tools.webSearch.endpoint"),
    ]
    static let essentialFields = primaryFields
    static let customFields: [NativeConfigTextFieldSpec] = [
        NativeConfigTextFieldSpec(label: .customProviderName, path: "tools.webSearch.customProvider.name"),
        NativeConfigTextFieldSpec(label: .customAuth, path: "tools.webSearch.customProvider.auth"),
        NativeConfigTextFieldSpec(label: .customMethod, path: "tools.webSearch.customProvider.method"),
        NativeConfigTextFieldSpec(label: .queryParam, path: "tools.webSearch.customProvider.queryParam"),
        NativeConfigTextFieldSpec(label: .apiKeyParam, path: "tools.webSearch.customProvider.apiKeyParam"),
        NativeConfigTextFieldSpec(label: .resultsPath, path: "tools.webSearch.customProvider.resultsPath"),
        NativeConfigTextFieldSpec(label: .titleField, path: "tools.webSearch.customProvider.titleField"),
        NativeConfigTextFieldSpec(label: .urlField, path: "tools.webSearch.customProvider.urlField"),
        NativeConfigTextFieldSpec(label: .snippetField, path: "tools.webSearch.customProvider.snippetField"),
        NativeConfigTextFieldSpec(label: .sourceField, path: "tools.webSearch.customProvider.sourceField"),
        NativeConfigTextFieldSpec(label: .publishedAtField, path: "tools.webSearch.customProvider.publishedAtField"),
    ]
    static let visiblePaths = [providerPath] + essentialFields.map(\.path) + customFields.map(\.path)

    static func providerLabel(_ provider: String) -> String {
        switch provider {
        case "glm": return "GLM / Z.AI"
        case "tavily": return "Tavily"
        case "custom": return "Custom"
        default: return provider
        }
    }
}

enum NativeSearchConnectionTestResult: Equatable {
    case success(String)
    case failure(String)
}

enum NativeSearchConnectionTester {
    static func test(
        values: [String: String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        query: String = "PilotDeck connection test"
    ) async -> NativeSearchConnectionTestResult {
        do {
            let request = try request(values: values, environment: environment, query: query)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure("Search provider returned a non-HTTP response.")
            }
            guard 200..<300 ~= http.statusCode else {
                let detail = String(data: data, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
                return .failure("HTTP \(http.statusCode): \(String(detail.prefix(160)))")
            }
            return .success("Search provider responded successfully.")
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    static func request(
        values: [String: String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        query: String = "PilotDeck connection test"
    ) throws -> URLRequest {
        let config = NativeSearchConnectionConfig(values: values, environment: environment)
        guard let endpoint = NativeSearchConnectionConfig.nonBlank(config.endpoint) else {
            throw NativeSearchConnectionError.missingEndpoint
        }
        guard var url = URL(string: endpoint) else {
            throw NativeSearchConnectionError.invalidEndpoint(endpoint)
        }
        guard config.apiKey != nil || (config.provider == "custom" && config.customAuth == "none") else {
            throw NativeSearchConnectionError.missingAPIKey(config.provider)
        }

        var headers = ["Accept": "application/json"]
        var body: [String: Any]?
        var method = "POST"

        switch config.provider {
        case "tavily":
            headers["Content-Type"] = "application/json"
            body = [
                "api_key": config.apiKey ?? "",
                "query": query,
                "max_results": 1,
                "search_depth": "basic",
            ]
        case "custom":
            method = config.customMethod == "GET" ? "GET" : "POST"
            if method == "GET" {
                url.appendPilotDeckQueryItem(name: config.customQueryParam, value: query)
            } else {
                headers["Content-Type"] = "application/json"
                body = [config.customQueryParam: query]
            }
            if config.customAuth == "bearer", let apiKey = config.apiKey {
                headers["Authorization"] = "Bearer \(apiKey)"
            } else if config.customAuth == "queryApiKey", let apiKey = config.apiKey {
                url.appendPilotDeckQueryItem(name: config.customAPIKeyParam, value: apiKey)
            } else if config.customAuth == "bodyApiKey", let apiKey = config.apiKey {
                if method == "GET" {
                    url.appendPilotDeckQueryItem(name: config.customAPIKeyParam, value: apiKey)
                } else {
                    body?[config.customAPIKeyParam] = apiKey
                }
            }
        default:
            headers["Authorization"] = "Bearer \(config.apiKey ?? "")"
            headers["Content-Type"] = "application/json"
            body = [
                "search_engine": "search-prime",
                "search_query": query,
                "count": 1,
                "search_recency_filter": "noLimit",
            ]
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = TimeInterval(config.timeoutMs) / 1000
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }
}

private struct NativeSearchConnectionConfig {
    var provider: String
    var endpoint: String
    var apiKey: String?
    var timeoutMs: Int
    var customAuth: String
    var customMethod: String
    var customQueryParam: String
    var customAPIKeyParam: String

    init(values: [String: String], environment: [String: String]) {
        let rawProvider = Self.nonBlank(values["tools.webSearch.provider"])?.lowercased() ?? "glm"
        provider = NativeSearchConfigFormFields.providerOptions.contains(rawProvider) ? rawProvider : "glm"
        timeoutMs = Self.clampedInt(values["tools.webSearch.timeoutMs"], defaultValue: 30_000, min: 1_000, max: 120_000)
        customAuth = Self.nonBlank(values["tools.webSearch.customProvider.auth"]) ?? "bearer"
        customMethod = (Self.nonBlank(values["tools.webSearch.customProvider.method"]) ?? "POST").uppercased()
        customQueryParam = Self.nonBlank(values["tools.webSearch.customProvider.queryParam"]) ?? "query"
        customAPIKeyParam = Self.nonBlank(values["tools.webSearch.customProvider.apiKeyParam"]) ?? "api_key"

        let configuredEndpoint = Self.nonBlank(values["tools.webSearch.endpoint"])
        switch provider {
        case "tavily":
            endpoint = configuredEndpoint == NativeSearchConfigFormFields.defaultEndpoints["glm"]
                ? NativeSearchConfigFormFields.defaultEndpoints["tavily"] ?? ""
                : (configuredEndpoint ?? NativeSearchConfigFormFields.defaultEndpoints["tavily"] ?? "")
            apiKey = Self.nonBlank(values["tools.webSearch.apiKey"]) ?? Self.nonBlank(environment["TAVILY_API_KEY"])
        case "custom":
            let defaults = Set(NativeSearchConfigFormFields.defaultEndpoints.values)
            endpoint = configuredEndpoint.flatMap { defaults.contains($0) ? nil : $0 } ?? ""
            apiKey = Self.nonBlank(values["tools.webSearch.apiKey"]) ?? Self.nonBlank(environment["CUSTOM_WEB_SEARCH_API_KEY"])
        default:
            endpoint = configuredEndpoint
                ?? Self.nonBlank(environment["GLM_WEB_SEARCH_ENDPOINT"])
                ?? NativeSearchConfigFormFields.defaultEndpoints["glm"]
                ?? ""
            apiKey = Self.nonBlank(values["tools.webSearch.apiKey"])
                ?? Self.nonBlank(environment["GLM_WEB_SEARCH_API_KEY"])
                ?? Self.nonBlank(environment["ZAI_API_KEY"])
        }
    }

    static func nonBlank(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func clampedInt(_ rawValue: String?, defaultValue: Int, min: Int, max: Int) -> Int {
        guard let value = rawValue.flatMap(Int.init) else { return defaultValue }
        return Swift.max(min, Swift.min(max, value))
    }
}

enum NativeSearchConnectionError: LocalizedError, Equatable {
    case missingEndpoint
    case invalidEndpoint(String)
    case missingAPIKey(String)

    var errorDescription: String? {
        switch self {
        case .missingEndpoint:
            return "Search endpoint is empty."
        case .invalidEndpoint(let endpoint):
            return "Invalid search endpoint: \(endpoint)"
        case .missingAPIKey(let provider):
            return "\(NativeSearchConfigFormFields.providerLabel(provider)) requires an API key."
        }
    }
}

private extension URL {
    mutating func appendPilotDeckQueryItem(name: String, value: String) {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == name }
        items.append(URLQueryItem(name: name, value: value))
        components.queryItems = items
        if let url = components.url {
            self = url
        }
    }
}

enum NativeCustomEnvConfigFormFields {
    static let wellKnownKeys: [(key: String, hint: String)] = [
        ("TAVILY_API_KEY", "Tavily web search API key"),
        ("FIRECRAWL_API_KEY", "Firecrawl web scraping API key"),
        ("SERPER_API_KEY", "Serper search API key"),
        ("BROWSERBASE_API_KEY", "Browserbase API key"),
    ]
}

enum NativeConfigBoolValue {
    static func resolve(_ rawValue: String, defaultValue: Bool = false) -> Bool {
        let lower = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.isEmpty {
            return defaultValue
        }
        if lower == "true" || lower == "1" || lower == "yes" {
            return true
        }
        if lower == "false" || lower == "0" || lower == "no" {
            return false
        }
        return defaultValue
    }
}

enum NativeMemoryConfigFormFields {
    static let enabledPath = "memory.enabled"
    static let modelPath = "memory.model"
    static let autoIndexIntervalPath = "memory.autoIndexIntervalMinutes"
    static let autoDreamIntervalPath = "memory.autoDreamIntervalMinutes"
    static let scheduleFields: [NativeMemoryScheduleFieldSpec] = [
        NativeMemoryScheduleFieldSpec(
            path: autoIndexIntervalPath,
            englishLabel: "Auto Index Interval (minutes)",
            chineseLabel: "自动索引间隔（分钟）"
        ),
        NativeMemoryScheduleFieldSpec(
            path: autoDreamIntervalPath,
            englishLabel: "Auto Dream Interval (minutes)",
            chineseLabel: "自动 Dream 间隔（分钟）"
        ),
    ]
    static let visiblePaths = [
        enabledPath,
        modelPath,
    ]
}

struct NativeMemoryScheduleFieldSpec: Hashable, Identifiable {
    let path: String
    let englishLabel: String
    let chineseLabel: String

    var id: String { path }
}

enum NativeRouterConfigFormFields {
    static let enabledPath = "router.enabled"
    static let routeModelFields: [NativeRouterModelFieldSpec] = [
        NativeRouterModelFieldSpec(id: "default", label: .defaultRouteModel, path: "router.scenarios.default"),
    ]
    static let fallbackFields: [NativeAlwaysOnConfigFieldSpec] = [
        NativeAlwaysOnConfigFieldSpec(path: "router.fallback.default", englishLabel: "Default fallback", chineseLabel: "默认回退"),
        NativeAlwaysOnConfigFieldSpec(path: "router.fallback.background", englishLabel: "Background fallback", chineseLabel: "后台回退"),
    ]
    static let tierDescriptionFields: [NativeAlwaysOnConfigFieldSpec] = [
        NativeAlwaysOnConfigFieldSpec(path: "router.tokenSaver.tiers.simple.description", englishLabel: "Simple description", chineseLabel: "简单描述"),
        NativeAlwaysOnConfigFieldSpec(path: "router.tokenSaver.tiers.medium.description", englishLabel: "Medium description", chineseLabel: "中等描述"),
        NativeAlwaysOnConfigFieldSpec(path: "router.tokenSaver.tiers.complex.description", englishLabel: "Complex description", chineseLabel: "复杂描述"),
        NativeAlwaysOnConfigFieldSpec(path: "router.tokenSaver.tiers.reasoning.description", englishLabel: "Reasoning description", chineseLabel: "推理描述"),
    ]
    static let pricingFields: [NativeAlwaysOnConfigFieldSpec] = [
        NativeAlwaysOnConfigFieldSpec(path: "router.stats.modelPricing.default.input", englishLabel: "Default input / 1M", chineseLabel: "默认输入 / 百万"),
        NativeAlwaysOnConfigFieldSpec(path: "router.stats.modelPricing.default.output", englishLabel: "Default output / 1M", chineseLabel: "默认输出 / 百万"),
        NativeAlwaysOnConfigFieldSpec(path: "router.stats.modelPricing.default.cacheRead", englishLabel: "Default cache read / 1M", chineseLabel: "默认缓存读取 / 百万"),
    ]
    static let visiblePaths = [
        enabledPath,
        "router.scenarios.default",
        "router.tokenSaver.enabled",
        "router.tokenSaver.judge",
        "router.tokenSaver.defaultTier",
        "router.tokenSaver.judgeTimeoutMs",
        "router.tokenSaver.subagent.policy",
        "router.tokenSaver.tiers.simple.model",
        "router.tokenSaver.tiers.medium.model",
        "router.tokenSaver.tiers.complex.model",
        "router.tokenSaver.tiers.reasoning.model",
        "router.tokenSaver.rules",
        "router.zeroUsageRetry.enabled",
        "router.zeroUsageRetry.maxAttempts",
        "router.autoOrchestrate.enabled",
        "router.autoOrchestrate.triggerTiers",
        "router.autoOrchestrate.slimSystemPrompt",
        "router.stats.enabled",
    ] + fallbackFields.map(\.path) + tierDescriptionFields.map(\.path) + pricingFields.map(\.path)
}

enum NativeGatewayConfigFormFields {
    static let enabledPath = "gateway.enabled"
    static let homePath = "gateway.home"
    static let visiblePaths: [String] = []
}

enum NativeConfigCompatibility {
    static let webArrayPaths: Set<String> = [
        "alwaysOn.dormancy.ignoreGlobs",
        "router.fallback.default",
        "router.fallback.background",
        "router.tokenSaver.rules",
        "router.autoOrchestrate.triggerTiers",
    ]

    static let optionalNonEmptyStringPaths: Set<String> = [
        "tools.webSearch.apiKey",
        "tools.webSearch.endpoint",
        "tools.webSearch.customProvider.name",
        "tools.webSearch.customProvider.auth",
        "tools.webSearch.customProvider.method",
        "tools.webSearch.customProvider.queryParam",
        "tools.webSearch.customProvider.apiKeyParam",
        "tools.webSearch.customProvider.resultsPath",
        "tools.webSearch.customProvider.titleField",
        "tools.webSearch.customProvider.urlField",
        "tools.webSearch.customProvider.snippetField",
        "tools.webSearch.customProvider.sourceField",
        "tools.webSearch.customProvider.publishedAtField",
    ]

    static func shouldDeleteWhenEmpty(path: String, value: String) -> Bool {
        optionalNonEmptyStringPaths.contains(path)
            && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func isValidProviderID(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == value, !trimmed.isEmpty else { return false }
        return trimmed.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
    }

    static func isValidModelID(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == value, !trimmed.isEmpty else { return false }
        return trimmed.range(of: #"^[^\s/\\]+$"#, options: .regularExpression) != nil
    }

    static func validationErrors(yaml: String, values: [String: String]) -> [String] {
        var errors: [String] = []

        for path in webArrayPaths.sorted() where YAMLScalarEditor.containsPath(path, in: yaml) {
            if !YAMLScalarEditor.isStringArray(path: path, in: yaml) {
                errors.append("\(path) must be a YAML string array, not a scalar value.")
            }
        }

        for path in optionalNonEmptyStringPaths.sorted() where YAMLScalarEditor.containsPath(path, in: yaml) {
            if (values[path] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append("\(path) cannot be saved as an empty string. Clear it from YAML or enter a value.")
            }
        }

        let searchProvider = values["tools.webSearch.provider"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let searchProvider,
           !searchProvider.isEmpty,
           !NativeSearchConfigFormFields.providerOptions.contains(searchProvider) {
            errors.append("tools.webSearch.provider must be glm, tavily, or custom.")
        }

        if let bindAddress = values["gateway.bindAddress"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bindAddress.isEmpty,
           bindAddress != "127.0.0.1",
           bindAddress != "localhost" {
            errors.append("gateway.bindAddress must stay on 127.0.0.1/localhost for web compatibility.")
        }

        for providerID in YAMLScalarEditor.directChildKeys(parentPath: "model.providers", in: yaml) {
            if !isValidProviderID(providerID) {
                errors.append("model provider id '\(providerID)' must use only letters, numbers, '_' or '-'.")
                continue
            }

            let prefix = "model.providers.\(providerID)"
            for requiredPath in ["\(prefix).protocol", "\(prefix).url", "\(prefix).apiKey"] {
                if (values[requiredPath] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    errors.append("\(requiredPath) is required for the shared web config.")
                }
            }

            let modelIDs = YAMLScalarEditor.directChildKeys(parentPath: "\(prefix).models", in: yaml)
            if modelIDs.isEmpty {
                errors.append("\(prefix).models must contain at least one enabled model.")
            }
            for modelID in modelIDs where !isValidModelID(modelID) {
                errors.append("model id '\(modelID)' under provider '\(providerID)' cannot contain whitespace or '/'.")
            }
        }

        return errors
    }
}

private struct NativeConfigValidation {
    var errors: [String]
    var warnings: [String]
    var valid: Bool { errors.isEmpty }
}

private struct NoticeBanner: View {
    @EnvironmentObject private var state: AppState
    var text: String
    var tint: Color
    var onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .font(.system(size: 13, weight: .semibold))
            Text(text)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(state.t(.dismiss), action: onDismiss)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(10)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: DesignTokens.radius))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.radius).stroke(tint.opacity(0.28)))
    }
}

struct ConfigGrid<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(minimum: 180), spacing: 12),
                GridItem(.flexible(minimum: 180), spacing: 12),
            ],
            alignment: .leading,
            spacing: 12
        ) {
            content()
        }
    }
}

private struct SettingsSectionBlock<Content: View>: View {
    var title: String
    var detail: String?
    @ViewBuilder var content: () -> Content

    init(title: String, detail: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            content()
        }
    }
}

struct SettingsCardBlock<Content: View>: View {
    var divided = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        )
    }
}

private struct SettingsCardDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 54)
    }
}

private struct SettingsMenuRow<Trailing: View>: View {
    var systemImage: String
    var title: String
    var detail: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(DesignTokens.secondaryText)
                .frame(width: 28)

            SettingsFieldLabel(title: title, detail: detail)

            Spacer(minLength: 16)

            trailing()
                .controlSize(.regular)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(minHeight: 58)
    }
}

private struct SettingsNavigationRow: View {
    var systemImage: String
    var title: String
    var detail: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(DesignTokens.secondaryText)
                    .frame(width: 28)

                SettingsFieldLabel(title: title, detail: detail)

                Spacer(minLength: 16)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DesignTokens.tertiaryText)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct WebSettingsToggle: View {
    @EnvironmentObject private var state: AppState
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.regular)
            .accessibilityLabel(state.t(.toggle))
            .accessibilityValue(isOn ? state.t(.on) : state.t(.off))
    }
}

enum YAMLScalarEditor {
    static func set(path: String, value: String, in yaml: String) -> String {
        set(components: path.split(separator: ".").map(String.init), value: value, in: yaml)
    }

    static func setStringArray(path: String, values: [String], in yaml: String) -> String {
        setStringArray(components: path.split(separator: ".").map(String.init), values: values, in: yaml)
    }

    static func setStringArray(components: [String], values: [String], in yaml: String) -> String {
        guard !components.isEmpty, let key = components.last else { return yaml }
        let normalizedValues = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let cleaned = removeObject(components: components, in: yaml)
        let placeholder = set(components: components, value: "[]", in: cleaned)
        guard !normalizedValues.isEmpty else { return placeholder }

        var lines = placeholder.components(separatedBy: "\n")
        guard let index = lineIndex(forComponents: components, in: lines) else { return placeholder }
        let currentIndent = indent(of: lines[index])
        let prefix = String(repeating: " ", count: currentIndent)
        let itemPrefix = String(repeating: " ", count: currentIndent + 2)
        let block = ["\(prefix)\(key):"] + normalizedValues.map { "\(itemPrefix)- \(format($0))" }
        lines.replaceSubrange(index...index, with: block)
        return lines.joined(separator: "\n")
    }

    static func stringArray(path: String, in yaml: String) -> [String] {
        stringArray(components: path.split(separator: ".").map(String.init), in: yaml)
    }

    static func stringArray(components: [String], in yaml: String) -> [String] {
        let lines = yaml.components(separatedBy: "\n")
        guard let index = lineIndex(forComponents: components, in: lines),
              let rawValue = rawValue(at: index, in: lines)
        else { return [] }
        if rawValue == "[]" { return [] }
        if rawValue.hasPrefix("["), rawValue.hasSuffix("]") {
            return parseInlineArray(rawValue)
        }
        if !rawValue.isEmpty {
            return [normalizeScalar(rawValue)]
        }
        return sequenceValues(after: index, in: lines, parentIndent: indent(of: lines[index])) ?? []
    }

    static func isStringArray(path: String, in yaml: String) -> Bool {
        isStringArray(components: path.split(separator: ".").map(String.init), in: yaml)
    }

    static func isStringArray(components: [String], in yaml: String) -> Bool {
        let lines = yaml.components(separatedBy: "\n")
        guard let index = lineIndex(forComponents: components, in: lines),
              let rawValue = rawValue(at: index, in: lines)
        else { return true }
        if rawValue == "[]" { return true }
        if rawValue.hasPrefix("["), rawValue.hasSuffix("]") { return true }
        if !rawValue.isEmpty { return false }
        return sequenceValues(after: index, in: lines, parentIndent: indent(of: lines[index])) != nil
    }

    static func containsPath(_ path: String, in yaml: String) -> Bool {
        let lines = yaml.components(separatedBy: "\n")
        return lineIndex(for: path, in: lines) != nil
    }

    static func directChildKeys(parentPath: String, in yaml: String) -> [String] {
        let lines = yaml.components(separatedBy: "\n")
        guard let parentIndex = lineIndex(for: parentPath, in: lines) else { return [] }
        let parentIndent = indent(of: lines[parentIndex])
        var keys: [String] = []
        var index = parentIndex + 1
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                index += 1
                continue
            }
            let currentIndent = indent(of: line)
            if currentIndent <= parentIndent { break }
            if currentIndent == parentIndent + 2,
               let colon = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
                if !key.isEmpty, !key.hasPrefix("- ") {
                    keys.append(key)
                }
            }
            index += 1
        }
        return keys
    }

    static func set(components: [String], value: String, in yaml: String) -> String {
        var lines = yaml.components(separatedBy: "\n")
        var stack: [(indent: Int, key: String)] = []
        guard !components.isEmpty else { return yaml }

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
            let currentComponents = stack.map(\.key) + [key]
            if currentComponents == components {
                let prefix = String(repeating: " ", count: indent)
                if rawValue.isEmpty && value.isEmpty {
                    lines[index] = "\(prefix)\(key): \"\""
                } else {
                    lines[index] = "\(prefix)\(key): \(format(value))"
                }
                return lines.joined(separator: "\n")
            }
            if rawValue.isEmpty || (rawValue == "{}" && components.starts(with: currentComponents)) {
                if rawValue == "{}" {
                    lines[index] = "\(String(repeating: " ", count: indent))\(key):"
                }
                stack.append((indent, key))
            }
        }

        if let updated = insertMissingPath(components: components, value: value, into: lines) {
            return updated
        }

        return append(components: components, value: value, to: yaml)
    }

    static func appendBlock(parentPath: String, id: String, scalars: [String: String], in yaml: String) -> String {
        appendBlock(parentComponents: parentPath.split(separator: ".").map(String.init), id: id, scalars: scalars, in: yaml)
    }

    static func appendBlock(parentComponents: [String], id: String, scalars: [String: String], in yaml: String) -> String {
        var lines = yaml.components(separatedBy: "\n")
        if let parentIndex = lineIndex(forComponents: parentComponents, in: lines) {
            let parentIndent = indent(of: lines[parentIndex])
            if lines[parentIndex].trimmingCharacters(in: .whitespaces).hasSuffix(": {}") {
                let key = parentComponents.last ?? ""
                lines[parentIndex] = "\(String(repeating: " ", count: parentIndent))\(key):"
            }
            var insertIndex = parentIndex + 1
            while insertIndex < lines.count {
                let trimmed = lines[insertIndex].trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty, indent(of: lines[insertIndex]) <= parentIndent {
                    break
                }
                insertIndex += 1
            }
            let childIndent = String(repeating: " ", count: parentIndent + 2)
            let scalarIndent = String(repeating: " ", count: parentIndent + 4)
            var block = ["\(childIndent)\(id):"]
            for (key, value) in scalars {
                block.append("\(scalarIndent)\(key): \(format(value))")
            }
            lines.insert(contentsOf: block, at: insertIndex)
            return lines.joined(separator: "\n")
        }

        var result = yaml.trimmingCharacters(in: .newlines)
        if !result.isEmpty { result += "\n" }
        for index in parentComponents.indices {
            result += "\(String(repeating: " ", count: index * 2))\(parentComponents[index]):\n"
        }
        result = appendBlock(parentComponents: parentComponents, id: id, scalars: scalars, in: result)
        return result
    }

    static func setObjectScalar(parentPath: String, id: String, key: String, value: String, in yaml: String) -> String {
        let parentComponents = parentPath.split(separator: ".").map(String.init)
        guard !parentComponents.isEmpty, !id.isEmpty, !key.isEmpty else { return yaml }

        var lines = yaml.components(separatedBy: "\n")
        let scalarComponents = parentComponents + [id, key]
        if let scalarIndex = lineIndex(forComponents: scalarComponents, in: lines) {
            let currentIndent = indent(of: lines[scalarIndex])
            lines[scalarIndex] = "\(String(repeating: " ", count: currentIndent))\(key): \(format(value))"
            return lines.joined(separator: "\n")
        }

        let objectComponents = parentComponents + [id]
        if let objectIndex = lineIndex(forComponents: objectComponents, in: lines) {
            let objectIndent = indent(of: lines[objectIndex])
            var insertIndex = objectIndex + 1
            while insertIndex < lines.count {
                let trimmed = lines[insertIndex].trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty, indent(of: lines[insertIndex]) <= objectIndent {
                    break
                }
                insertIndex += 1
            }
            lines.insert("\(String(repeating: " ", count: objectIndent + 2))\(key): \(format(value))", at: insertIndex)
            return lines.joined(separator: "\n")
        }

        return appendBlock(parentPath: parentPath, id: id, scalars: [key: value], in: yaml)
    }

    static func renameObject(parentPath: String, oldID: String, newID: String, in yaml: String) -> String {
        renameObject(parentComponents: parentPath.split(separator: ".").map(String.init), oldID: oldID, newID: newID, in: yaml)
    }

    static func renameObject(parentComponents: [String], oldID: String, newID: String, in yaml: String) -> String {
        var lines = yaml.components(separatedBy: "\n")
        guard let index = lineIndex(forComponents: parentComponents + [oldID], in: lines) else { return yaml }
        let currentIndent = indent(of: lines[index])
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
        let rawValue: String
        if let colon = trimmed.firstIndex(of: ":") {
            rawValue = String(trimmed[trimmed.index(after: colon)...])
        } else {
            rawValue = ""
        }
        lines[index] = "\(String(repeating: " ", count: currentIndent))\(newID):\(rawValue)"
        return lines.joined(separator: "\n")
    }

    static func removeObject(path: String, in yaml: String) -> String {
        removeObject(components: path.split(separator: ".").map(String.init), in: yaml)
    }

    static func removeObject(components: [String], in yaml: String) -> String {
        var lines = yaml.components(separatedBy: "\n")
        if let start = lineIndex(forComponents: components, in: lines) {
            let startIndent = indent(of: lines[start])
            var end = start + 1
            while end < lines.count {
                let trimmed = lines[end].trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty, indent(of: lines[end]) <= startIndent {
                    break
                }
                end += 1
            }
            lines.removeSubrange(start..<end)
        }
        lines = removeLooseEntries(components: components, from: lines)
        return lines.joined(separator: "\n")
    }

    private static func append(components parts: [String], value: String, to yaml: String) -> String {
        guard !parts.isEmpty else { return yaml }
        var lines = yaml.trimmingCharacters(in: .newlines).components(separatedBy: "\n")
        lines.append("# Added by native Settings")
        for index in parts.indices {
            let indent = String(repeating: " ", count: index * 2)
            if index == parts.count - 1 {
                lines.append("\(indent)\(parts[index]): \(format(value))")
            } else {
                lines.append("\(indent)\(parts[index]):")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func insertMissingPath(components parts: [String], value: String, into sourceLines: [String]) -> String? {
        guard parts.count > 1 else { return nil }
        var lines = sourceLines

        for parentLength in stride(from: parts.count - 1, through: 1, by: -1) {
            let parentComponents = Array(parts.prefix(parentLength))
            guard let parentIndex = lineIndex(forComponents: parentComponents, in: lines) else { continue }

            let parentLine = lines[parentIndex]
            let parentIndent = indent(of: parentLine)
            let trimmed = parentLine.trimmingCharacters(in: .whitespaces)
            let rawValue: String
            if let colon = trimmed.firstIndex(of: ":") {
                rawValue = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            } else {
                rawValue = ""
            }
            guard rawValue.isEmpty || rawValue == "{}" else { continue }

            if rawValue == "{}" {
                let key = parentComponents.last ?? ""
                lines[parentIndex] = "\(String(repeating: " ", count: parentIndent))\(key):"
            }

            var insertIndex = parentIndex + 1
            while insertIndex < lines.count {
                let candidate = lines[insertIndex]
                let candidateTrimmed = candidate.trimmingCharacters(in: .whitespaces)
                if !candidateTrimmed.isEmpty, indent(of: candidate) <= parentIndent {
                    break
                }
                insertIndex += 1
            }

            let remainder = Array(parts.dropFirst(parentLength))
            var block: [String] = []
            for offset in remainder.indices {
                let currentIndent = String(repeating: " ", count: parentIndent + 2 + offset * 2)
                let key = remainder[offset]
                if offset == remainder.count - 1 {
                    block.append("\(currentIndent)\(key): \(format(value))")
                } else {
                    block.append("\(currentIndent)\(key):")
                }
            }
            lines.insert(contentsOf: block, at: insertIndex)
            return lines.joined(separator: "\n")
        }

        return nil
    }

    private static func lineIndex(for path: String, in lines: [String]) -> Int? {
        lineIndex(forComponents: path.split(separator: ".").map(String.init), in: lines)
    }

    private static func lineIndex(forComponents components: [String], in lines: [String]) -> Int? {
        var stack: [(indent: Int, key: String)] = []
        for index in lines.indices {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("- ") else { continue }
            let currentIndent = indent(of: line)
            while let last = stack.last, last.indent >= currentIndent {
                stack.removeLast()
            }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            let currentComponents = stack.map(\.key) + [key]
            if currentComponents == components {
                return index
            }
            if value.isEmpty {
                stack.append((currentIndent, key))
            }
        }
        return nil
    }

    private static func rawValue(at index: Int, in lines: [String]) -> String? {
        guard lines.indices.contains(index) else { return nil }
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }
        return String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    }

    private static func sequenceValues(after index: Int, in lines: [String], parentIndent: Int) -> [String]? {
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
            let currentIndent = indent(of: line)
            if currentIndent <= parentIndent { break }
            sawChild = true
            guard trimmed.hasPrefix("- ") else { return nil }
            let raw = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            values.append(normalizeScalar(raw))
            current += 1
        }
        return sawChild ? values : nil
    }

    private static func parseInlineArray(_ rawValue: String) -> [String] {
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

    private static func removeLooseEntries(components: [String], from lines: [String]) -> [String] {
        guard !components.isEmpty else { return lines }
        let prefix = components.joined(separator: ".")
        var stack: [(indent: Int, key: String)] = []
        var indexesToRemove = Set<Int>()

        for index in lines.indices {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("- ") else { continue }
            let currentIndent = indent(of: line)
            while let last = stack.last, last.indent >= currentIndent {
                stack.removeLast()
            }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            let currentPath = (stack.map(\.key) + [key]).joined(separator: ".")
            if currentPath == prefix || currentPath.hasPrefix(prefix + ".") {
                indexesToRemove.insert(index)
            }
            if value.isEmpty {
                stack.append((currentIndent, key))
            }
        }

        return lines.enumerated()
            .filter { !indexesToRemove.contains($0.offset) }
            .map(\.element)
    }

    private static func indent(of line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    private static func normalizeScalar(_ rawValue: String) -> String {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value.removeFirst()
            value.removeLast()
            return value.replacingOccurrences(of: "\\\"", with: "\"")
        }
        if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
            value.removeFirst()
            value.removeLast()
            return value.replacingOccurrences(of: "''", with: "'")
        }
        if let hash = value.firstIndex(of: "#") {
            value = String(value[..<hash]).trimmingCharacters(in: .whitespaces)
        }
        return value
    }

    private static func format(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "\"\"" }
        let lower = trimmed.lowercased()
        if lower == "true" || lower == "false" || lower == "null" || trimmed == "{}" || trimmed == "[]" {
            return trimmed
        }
        if Int(trimmed) != nil || Double(trimmed) != nil {
            return trimmed
        }
        if trimmed.contains("#") || trimmed.hasPrefix(" ") || trimmed.hasSuffix(" ") {
            return "\"\(trimmed.replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        return trimmed
    }
}

enum AlwaysOnProjectConfig {
    static func projectRoot(_ root: String) -> String {
        root.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[\\\\/]+$", with: "", options: .regularExpression)
    }

    static func isEnabled(yaml: String, projectRoot rawRoot: String) -> Bool {
        let root = projectRoot(rawRoot)
        guard !root.isEmpty else { return false }
        let value = LegacyConfigLoader.scalarMap(from: yaml)["alwaysOn.projects.\(root).enabled"]?.lowercased()
        return value == "true" || value == "1" || value == "yes"
    }

    static func setEnabled(in yaml: String, projectRoot rawRoot: String, enabled: Bool) -> String {
        let root = projectRoot(rawRoot)
        guard !root.isEmpty else { return yaml }
        return YAMLScalarEditor.setObjectScalar(
            parentPath: "alwaysOn.projects",
            id: root,
            key: "enabled",
            value: enabled ? "true" : "false",
            in: yaml
        )
    }
}

private struct SettingsRowBlock<Content: View>: View {
    var title: String
    var detail: String
    @ViewBuilder var trailing: () -> Content

    var body: some View {
        LabeledContent {
            trailing()
                .controlSize(.regular)
                .frame(maxWidth: .infinity, alignment: .trailing)
        } label: {
            SettingsFieldLabel(title: title, detail: detail)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .frame(minHeight: 48)
    }
}

private struct SettingsFieldLabel: View {
    var title: String
    var detail: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
            if !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct SettingsTextField: View {
    var label: String
    @Binding var text: String
    var isSecure: Bool

    init(_ label: String, text: Binding<String>, isSecure: Bool = false) {
        self.label = label
        self._text = text
        self.isSecure = isSecure
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DesignTokens.tertiaryText)
            if isSecure {
                SecureField(label, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.regular)
                    .font(.system(size: 13, design: .monospaced))
            } else {
                TextField(label, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.regular)
                    .font(.system(size: 13, design: .monospaced))
            }
        }
    }
}

struct SettingsTextArea: View {
    var label: String
    @Binding var text: String

    init(_ label: String, text: Binding<String>) {
        self.label = label
        self._text = text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DesignTokens.tertiaryText)
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 74)
                .scrollContentBackground(.hidden)
                .background(DesignTokens.neutral50, in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius))
                .overlay(RoundedRectangle(cornerRadius: DesignTokens.smallRadius).stroke(DesignTokens.separator))
        }
    }
}

struct SettingsPickerField: View {
    var label: String
    @Binding var selection: String
    var options: [String]
    var emptyLabel: String
    var optionLabel: (String) -> String

    init(
        _ label: String,
        selection: Binding<String>,
        options: [String],
        emptyLabel: String,
        optionLabel: ((String) -> String)? = nil
    ) {
        self.label = label
        self._selection = selection
        self.options = options
        self.emptyLabel = emptyLabel
        self.optionLabel = optionLabel ?? { option in
            option.isEmpty || option == "inherit" ? emptyLabel : option
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DesignTokens.tertiaryText)
            Picker(label, selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(optionLabel(option))
                        .tag(option)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.regular)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct CodeExample: View {
    var code: String
    var detail: String

    init(_ code: String, _ detail: String) {
        self.code = code
        self.detail = detail
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(code)
                .font(.system(size: 12, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(DesignTokens.neutral100, in: RoundedRectangle(cornerRadius: 4))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(DesignTokens.tertiaryText)
        }
    }
}

private struct PillButtonStyle: ButtonStyle {
    var isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: isActive ? .semibold : .regular))
            .padding(.horizontal, 10)
            .frame(height: 30)
            .foregroundStyle(isActive ? DesignTokens.text : DesignTokens.tertiaryText)
            .background {
                ZStack {
                    if isActive {
                        VisualEffectBackground(material: .popover, blendingMode: .withinWindow)
                    } else {
                        Color.clear
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous))
            }
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                    .stroke(isActive ? .white.opacity(0.45) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

private struct SettingsIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? DesignTokens.text : DesignTokens.secondaryText)
            .background(GlassControlBackground(isActive: false, cornerRadius: 10, material: .popover, showsShadow: false))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

private struct FlowLayout<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: spacing) {
                content()
            }
        }
    }
}
