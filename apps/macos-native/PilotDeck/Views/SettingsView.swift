import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        SettingsContentView()
            .environmentObject(state)
    }
}

private struct SettingsContentView: View {
    @EnvironmentObject private var state: AppState
    @State private var currentPage: SettingsPage = .main
    @State private var configSection: PilotDeckConfigSection = .models
    @State private var savedConfigText = ""
    @State private var configMessage: String?
    @State private var configError: String?
    @State private var configExternalNotice: String?
    @State private var selectedModelPoolEntry: String?
    @State private var mcpScope: NativeMCPConfigScope = .global
    @State private var mcpDraft = NativeMCPConfigDraft.empty
    @State private var mcpProjectRoot = ""
    @State private var mcpMessage: String?
    @State private var mcpError: String?

    var body: some View {
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
        .background(Color(nsColor: .windowBackgroundColor))
        .background(SettingsWindowConfigurator(title: state.t(.settings)))
        .frame(minWidth: 760, minHeight: 620)
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

            HStack(alignment: .top, spacing: NativeConfigFormLayout.sectionNavigationGap) {
                configSectionSidebar
                configSectionContent
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private var configHeaderCard: some View {
        SettingsCardBlock {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "doc.badge.gearshape")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DesignTokens.tertiaryText)
                        .frame(width: 22)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(configFileURL().path.isEmpty ? state.t(.configPreview) : state.t(.configFile))
                                .font(.system(size: 13, weight: .semibold))
                            if isConfigDirty {
                                Text(state.t(.unsaved))
                                    .font(.system(size: 10, weight: .bold))
                                    .tracking(0.6)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .foregroundStyle(DesignTokens.warning)
                                    .background(DesignTokens.warning.opacity(0.10), in: Capsule())
                                    .overlay(Capsule().stroke(DesignTokens.warning.opacity(0.35), lineWidth: 1))
                            }
                            Spacer()
                        }
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
                    Button {
                        saveConfigAndReload()
                    } label: {
                        Label(local(chinese: "保存并重新加载当前配置", english: "Save & Reload Current"), systemImage: "arrow.clockwise")
                            .lineLimit(1)
                    }
                    .buttonStyle(WebToolbarButtonStyle())
                }
                Divider()
                configStatusOverview
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

    @ViewBuilder
    private var configSectionContent: some View {
        switch configSection {
        case .runtime:
            SettingsSectionBlock(title: state.t(.runtime), detail: state.t(.runtimeDetail)) {
                SettingsCardBlock(divided: true) {
                    ConfigGrid {
                        ForEach(NativeRuntimeConfigFormFields.textFields) { field in
                            SettingsTextField(state.t(field.label), text: configBinding(field.path))
                        }
                        SettingsTextField(state.t(.workspacesRoot), text: Binding(
                            get: { state.settings.workspacesRoot },
                            set: { value in
                                state.settings.workspacesRoot = value
                                setConfigValue(NativeRuntimeConfigFormFields.workspacesRootPath, value)
                            }
                        ))
                        SettingsTextField(state.t(.generalWorkspace), text: Binding(
                            get: { state.settings.generalWorkspacePath },
                            set: { value in
                                state.settings.generalWorkspacePath = value
                                setConfigValue(NativeRuntimeConfigFormFields.generalWorkspacePath, value)
                            }
                        ))
                    }
                    .padding(14)
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
                        chinese: "配置后台发现的开关、节奏和项目范围。隔离工作区、休眠和执行保护由客户端自动处理。",
                        english: "Configure background discovery, cadence, and project scope. Workspace isolation, dormancy, and execution guards are handled automatically."
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
                        SettingsCardDivider()
                        SettingsRowBlock(
                            title: local(chinese: "自动发现", english: "Auto Discovery"),
                            detail: state.t(.discoveryTriggerDetail)
                        ) {
                            WebSettingsToggle(isOn: configBoolBinding(NativeAlwaysOnConfigFormFields.triggerEnabledPath))
                        }
                        SettingsCardDivider()
                        ConfigGrid {
                            ForEach(NativeAlwaysOnConfigFormFields.triggerFields) { field in
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
        case .memory:
            VStack(alignment: .leading, spacing: 18) {
                SettingsSectionBlock(
                    title: state.t(.memory),
                    detail: local(
                        chinese: "配置记忆捕获、索引、Dream，以及记忆专用模型。",
                        english: "Configure memory capture, indexing, Dream, and the memory model."
                    )
                ) {
                    SettingsCardBlock(divided: true) {
                        SettingsRowBlock(title: state.t(.enabled), detail: state.t(.memoryDetail)) {
                            WebSettingsToggle(isOn: configBoolBinding(NativeMemoryConfigFormFields.enabledPath))
                        }
                        SettingsCardDivider()
                        SettingsRowBlock(
                            title: local(chinese: "记忆模型", english: "Memory Model"),
                            detail: local(chinese: "记忆检索、索引和 Dream 可继承主智能体模型。", english: "Recall, Index, and Dream can inherit the main agent model.")
                        ) {
                            modelAssignmentPicker(path: NativeMemoryConfigFormFields.modelPath, includeInherit: true)
                        }
                        SettingsCardDivider()
                        ConfigGrid {
                            ForEach(NativeMemoryConfigFormFields.scheduleFields) { field in
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
        case .raw:
            EmptyView()
        }
    }

    private var modelsConfigContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionBlock(
                title: local(chinese: "模型池", english: "Model Pool"),
                detail: local(chinese: "集中维护可复用的模型连接与模型名称。", english: "Manage reusable model connections and model names.")
            ) {
                SettingsCardBlock {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(local(chinese: "已配置模型", english: "Configured Models"))
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Button(local(chinese: "添加配置", english: "Add Config")) { addModelPoolEntry() }
                                .buttonStyle(WebToolbarButtonStyle())
                        }
                        let entries = modelPoolEntryIDs
                        if entries.isEmpty {
                            dashedEmpty(local(chinese: "暂无模型配置。", english: "No model configs yet."))
                        } else {
                            SettingsPickerField(
                                local(chinese: "选择模型", english: "Select Model"),
                                selection: selectedModelPoolEntryBinding,
                                options: entries,
                                emptyLabel: local(chinese: "选择模型", english: "Select model"),
                                optionLabel: modelOptionLabel
                            )
                            if let entry = selectedModelPoolEntryID {
                                modelPoolEditorCard(entry)
                            }
                        }
                    }
                    .padding(14)
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
                modelAssignmentRowsCard(primaryModelAssignmentRows)
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
                        modelAssignmentRowsList(routerDecisionModelRows)
                    }
                }
            }

            if configBool(NativeRouterConfigFormFields.enabledPath) {
                SettingsSectionBlock(
                    title: state.t(.tokenSaver),
                    detail: local(chinese: "对齐 PD 的 simple / medium / complex / reasoning 四档，复杂度判断和回退细节由客户端处理。", english: "Uses PD-style simple / medium / complex / reasoning tiers. Classification and fallback details are handled by the client.")
                ) {
                    SettingsCardBlock(divided: true) {
                        SettingsRowBlock(title: state.t(.enabled), detail: state.t(.tokenSaverDetail)) {
                            WebSettingsToggle(isOn: configBoolBinding("router.tokenSaver.enabled"))
                        }
                        SettingsCardDivider()
                        modelAssignmentRowsList(routerTierModelRows)
                    }
                }
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

    private var routerDecisionModelRows: [NativeModelAssignmentRowSpec] {
        routeModelAssignmentRows + [
            NativeModelAssignmentRowSpec(
                id: "judgeModel",
                title: state.t(.judgeModel),
                detail: local(chinese: "Token Saver 用这个模型判断任务复杂度。", english: "Token Saver uses this model to judge task complexity."),
                path: "router.tokenSaver.judgeModel"
            ),
        ]
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
                path: "agents.main.model"
            ),
            NativeModelAssignmentRowSpec(
                id: "subagents",
                title: state.t(.subagents),
                detail: local(chinese: "子智能体默认模型，可继承主智能体。", english: "Default subagent model; can inherit the main agent."),
                path: "agents.subagents.default",
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

    private var modelPoolEntryIDs: [String] {
        configChildIDs(parentPath: "models.entries")
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

    private func modelPoolEditorCard(_ entry: String) -> some View {
        let provider = providerID(forEntry: entry)
        return SettingsCardBlock {
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

    private func configBoolBinding(_ path: String, defaultValue: Bool = false) -> Binding<Bool> {
        Binding(
            get: {
                configBool(path, defaultValue: defaultValue)
            },
            set: { setConfigValue(path, $0 ? "true" : "false") }
        )
    }

    private func searchProviderBinding() -> Binding<String> {
        Binding(
            get: {
                let value = configValue(NativeSearchConfigFormFields.providerPath)
                return NativeSearchConfigFormFields.providerOptions.contains(value) ? value : "glm"
            },
            set: { provider in
                let selected = NativeSearchConfigFormFields.providerOptions.contains(provider) ? provider : "glm"
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
        LegacyConfigLoader.scalarMap(from: state.pilotDeckConfigText)[path] ?? ""
    }

    private func setConfigValue(_ path: String, _ value: String) {
        state.pilotDeckConfigText = YAMLScalarEditor.set(path: path, value: value, in: state.pilotDeckConfigText)
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
        panel.nameFieldStringValue = "config.yaml"
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
        if let root = values["runtime.workspacesRoot"], !root.isEmpty {
            state.settings.workspacesRoot = NSString(string: root).expandingTildeInPath
        }
        if let general = values["gateway.runtimePaths.generalCwd"], !general.isEmpty {
            state.settings.generalWorkspacePath = AppState.normalizedGeneralWorkspacePath(general)
        }
        if let timeout = values["runtime.apiTimeoutMs"].flatMap(Int.init) {
            state.settings.apiTimeoutMs = timeout
        }
        if let context = values["runtime.contextWindow"].flatMap(Int.init) {
            state.settings.contextWindow = context
        }
        let defaultProvider = defaultProviderID()
        if let baseURL = values["models.providers.\(defaultProvider).baseUrl"] {
            state.settings.providerConfig.baseURL = baseURL
        }
        if let model = values["models.entries.default.name"] {
            state.settings.providerConfig.model = model
        }
    }

    private func validateConfig() -> NativeConfigValidation {
        let values = LegacyConfigLoader.scalarMap(from: state.pilotDeckConfigText)
        var errors: [String] = []
        var warnings: [String] = []
        let defaultProvider = values["models.entries.default.provider"] ?? ""
        if defaultProvider.isEmpty {
            errors.append("models.entries.default.provider is required.")
        } else if values["models.providers.\(defaultProvider).baseUrl"] == nil {
            errors.append("models.entries.default.provider must reference an existing provider.")
        }
        if (values["models.entries.default.name"] ?? "").isEmpty {
            errors.append("models.entries.default.name is required.")
        }
        if (values["runtime.workspacesRoot"] ?? "").isEmpty {
            warnings.append("runtime.workspacesRoot is empty; project creation will use the home directory fallback.")
        }
        if (values["gateway.runtimePaths.generalCwd"] ?? "").isEmpty {
            warnings.append("gateway.runtimePaths.generalCwd is empty; Chat will use the default workspace.")
        }
        if state.pilotDeckConfigText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Config YAML is empty.")
        }
        return NativeConfigValidation(errors: errors, warnings: warnings)
    }

    private func defaultProviderID() -> String {
        let provider = configValue("models.entries.default.provider").trimmingCharacters(in: .whitespacesAndNewlines)
        return provider.isEmpty ? "pilotdeck" : provider
    }

    private func isDefaultProvider(_ provider: String) -> Bool {
        provider == defaultProviderID()
    }

    private func configChildIDs(parentPath: String) -> [String] {
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

    private func providerID(forEntry entry: String) -> String {
        nonBlank(configValue("models.entries.\(entry).provider")) ?? "pilotdeck"
    }

    private func modelName(forEntry entry: String) -> String {
        configValue("models.entries.\(entry).name")
    }

    private func modelPoolSummary(forEntry entry: String) -> String {
        let provider = providerID(forEntry: entry)
        let providerType = nonBlank(configValue("models.providers.\(provider).type")) ?? NativeModelsConfigFormFields.defaultProviderType
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
        Picker("", selection: configBinding(path)) {
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

    private func addModelPoolEntry() {
        let entryIDs = Set(modelPoolEntryIDs)
        var id = entryIDs.contains("default") ? "model1" : "default"
        var index = 1
        while entryIDs.contains(id) {
            index += 1
            id = "model\(index)"
        }

        let providerIDs = Set(configChildIDs(parentPath: "models.providers"))
        let providerID: String
        if id == "default", providerIDs.contains("pilotdeck") {
            providerID = "pilotdeck"
        } else {
            providerID = id
        }

        var yaml = state.pilotDeckConfigText
        if !providerIDs.contains(providerID) {
            yaml = YAMLScalarEditor.appendBlock(
                parentPath: "models.providers",
                id: providerID,
                scalars: NativeModelsConfigFormFields.newProviderScalars,
                in: yaml
            )
        }
        state.pilotDeckConfigText = YAMLScalarEditor.appendBlock(
            parentPath: "models.entries",
            id: id,
            scalars: NativeModelsConfigFormFields.newEntryScalars(firstProvider: providerID),
            in: yaml
        )
        selectedModelPoolEntry = id
    }

    private func removeModelPoolEntry(_ entry: String) {
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
            guard values[path] == removedEntry else { return result }
            let replacement = NativeModelsConfigFormFields.inheritableAssignmentPaths.contains(path)
                ? (fallback ?? "inherit")
                : (fallback ?? "")
            return YAMLScalarEditor.set(path: path, value: replacement, in: result)
        }
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

enum NativeConfigFormLayout {
    static let usesSplitSectionNavigation = true
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
        .memory,
        .router,
        .search,
        .alwaysOn,
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
    ]

    static var subsystemIDs: [String] {
        subsystems.map(\.id)
    }
}

enum NativeConfigModelOptions {
    static func entryIDs(values: [String: String]) -> [String] {
        let prefix = "models.entries."
        var ids = Set<String>()
        for key in values.keys where key.hasPrefix(prefix) {
            let suffix = key.dropFirst(prefix.count)
            if let first = suffix.split(separator: ".").first {
                ids.insert(String(first))
            }
        }
        return ids.sorted()
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
    static let usesModelPoolDropdown = true
    static let usageAssignmentsLiveInModelSection = false
    static let entryRowsExposeProviderPicker = false
    static let entryRowsExposeModelNameField = false
    static let assignmentPaths = [
        "agents.main.model",
        "agents.subagents.default",
        "memory.model",
        "router.routes.default.model",
        "router.routes.background.model",
        "router.routes.think.model",
        "router.routes.longContext.model",
        "router.routes.webSearch.model",
        "router.tokenSaver.judgeModel",
        "router.tokenSaver.tiers.simple.model",
        "router.tokenSaver.tiers.medium.model",
        "router.tokenSaver.tiers.complex.model",
        "router.tokenSaver.tiers.reasoning.model",
        "router.autoOrchestrate.mainAgentModel",
    ]
    static let inheritableAssignmentPaths: Set<String> = [
        "agents.subagents.default",
        "memory.model",
    ]
    static let defaultProviderType = "openai-chat"
    static let providerTypeOptions = [
        "openai-chat",
        "openai-responses",
        "anthropic",
        "litellm",
        "ccr",
    ]
    static let newProviderScalars = [
        "type": defaultProviderType,
        "baseUrl": "",
        "apiKey": "",
    ]

    static func newEntryScalars(firstProvider: String) -> [String: String] {
        [
            "provider": firstProvider,
            "name": "",
            "contextWindow": "",
        ]
    }
}

enum NativeAgentConfigFormFields {
    static let visiblePaths = [
        "agents.main.model",
        "agents.subagents.default",
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
    static let workspacesRootPath = "runtime.workspacesRoot"
    static let generalWorkspacePath = "gateway.runtimePaths.generalCwd"
    static let textFields: [NativeConfigTextFieldSpec] = [
        NativeConfigTextFieldSpec(label: .apiTimeoutMs, path: "runtime.apiTimeoutMs"),
        NativeConfigTextFieldSpec(label: .databasePath, path: "runtime.databasePath"),
    ]
    static let visiblePaths: [String] = []
}

enum NativeAlwaysOnConfigFormFields {
    static let enabledPath = "alwaysOn.enabled"
    static let triggerEnabledPath = "alwaysOn.trigger.enabled"
    static let triggerFields: [NativeAlwaysOnConfigFieldSpec] = [
        NativeAlwaysOnConfigFieldSpec(path: "alwaysOn.trigger.tickIntervalMinutes", englishLabel: "Tick Interval (minutes)", chineseLabel: "检查间隔（分钟）"),
        NativeAlwaysOnConfigFieldSpec(path: "alwaysOn.trigger.cooldownMinutes", englishLabel: "Cooldown (minutes)", chineseLabel: "冷却时间（分钟）"),
        NativeAlwaysOnConfigFieldSpec(path: "alwaysOn.trigger.dailyBudget", englishLabel: "Daily Budget", chineseLabel: "每日运行预算"),
    ]
    static let visiblePaths = [
        enabledPath,
        triggerEnabledPath,
    ] + triggerFields.map(\.path)
}

enum NativeSearchConfigFormFields {
    static let providerPath = "tools.webSearch.provider"
    static let providerOptions = ["glm", "tavily", "custom"]
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
        autoIndexIntervalPath,
        autoDreamIntervalPath,
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
        NativeRouterModelFieldSpec(id: "default", label: .defaultRouteModel, path: "router.routes.default.model"),
        NativeRouterModelFieldSpec(id: "background", label: .backgroundRouteModel, path: "router.routes.background.model"),
    ]
    static let visiblePaths = [
        enabledPath,
        "router.routes.default.model",
        "router.routes.background.model",
        "router.tokenSaver.enabled",
        "router.tokenSaver.judgeModel",
        "router.tokenSaver.tiers.simple.model",
        "router.tokenSaver.tiers.medium.model",
        "router.tokenSaver.tiers.complex.model",
        "router.tokenSaver.tiers.reasoning.model",
    ]
}

enum NativeGatewayConfigFormFields {
    static let enabledPath = "gateway.enabled"
    static let homePath = "gateway.home"
    static let visiblePaths: [String] = []
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
        var lines = yaml.components(separatedBy: "\n")
        var stack: [(indent: Int, key: String)] = []

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
            let currentPath = (stack.map(\.key) + [key]).joined(separator: ".")
            if currentPath == path {
                let prefix = String(repeating: " ", count: indent)
                if rawValue.isEmpty && value.isEmpty {
                    lines[index] = "\(prefix)\(key): \"\""
                } else {
                    lines[index] = "\(prefix)\(key): \(format(value))"
                }
                return lines.joined(separator: "\n")
            }
            if rawValue.isEmpty {
                stack.append((indent, key))
            }
        }

        return append(path: path, value: value, to: yaml)
    }

    static func appendBlock(parentPath: String, id: String, scalars: [String: String], in yaml: String) -> String {
        var lines = yaml.components(separatedBy: "\n")
        if let parentIndex = lineIndex(for: parentPath, in: lines) {
            let parentIndent = indent(of: lines[parentIndex])
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
        let parts = parentPath.split(separator: ".").map(String.init)
        for index in parts.indices {
            result += "\(String(repeating: " ", count: index * 2))\(parts[index]):\n"
        }
        result = appendBlock(parentPath: parentPath, id: id, scalars: scalars, in: result)
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
        var lines = yaml.components(separatedBy: "\n")
        let path = "\(parentPath).\(oldID)"
        guard let index = lineIndex(for: path, in: lines) else { return yaml }
        let currentIndent = indent(of: lines[index])
        lines[index] = "\(String(repeating: " ", count: currentIndent))\(newID):"
        return lines.joined(separator: "\n")
    }

    static func removeObject(path: String, in yaml: String) -> String {
        var lines = yaml.components(separatedBy: "\n")
        guard let start = lineIndex(for: path, in: lines) else { return yaml }
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
        return lines.joined(separator: "\n")
    }

    private static func append(path: String, value: String, to yaml: String) -> String {
        let parts = path.split(separator: ".").map(String.init)
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

    private static func indent(of line: String) -> Int {
        line.prefix { $0 == " " }.count
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
