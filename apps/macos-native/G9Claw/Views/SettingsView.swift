import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        SettingsContentView()
            .environmentObject(state)
    }
}

private struct SettingsContentView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var activeTab: SettingsMainTab = .appearance
    @State private var configSection: G9ClawConfigSection = .runtime
    @AppStorage(NativeConfigViewMode.storageKey) private var configViewRaw = NativeConfigViewMode.form.rawValue
    @State private var savedConfigText = ""
    @State private var configMessage: String?
    @State private var configError: String?
    @State private var configExternalNotice: String?

    private var configView: NativeConfigViewMode {
        get { NativeConfigViewMode.fromStoredRaw(configViewRaw) }
        nonmutating set { configViewRaw = newValue.rawValue }
    }

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar
            Divider()
            ScrollView {
                SettingsPageContainer(title: settingsTabLabel(activeTab)) {
                    if let notice = state.settingsSaveNotice {
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(DesignTokens.success)
                    }
                    activeContent
                        .transition(.opacity.combined(with: .offset(y: 4)))
                        .id(activeTab)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(SettingsWindowConfigurator())
        .frame(minWidth: 860, minHeight: 620)
        .onAppear {
            activeTab = state.settingsInitialTab
            if savedConfigText.isEmpty {
                savedConfigText = state.g9ClawConfigText
            }
        }
        .onChange(of: state.settingsInitialTab) { _, newValue in
            activeTab = newValue
        }
    }

    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Spacer()
                .frame(height: 72)
            ForEach(SettingsMainTab.allCases) { tab in
                settingsSidebarRow(tab)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(width: 218)
        .background {
            VisualEffectBackground(material: .sidebar, blendingMode: .withinWindow)
            Color(nsColor: .windowBackgroundColor).opacity(0.28)
        }
    }

    private func settingsSidebarRow(_ tab: SettingsMainTab) -> some View {
        let selected = activeTab == tab
        return Button {
            activeTab = tab
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 22)
                Text(settingsTabLabel(tab))
                    .font(.system(size: 14, weight: selected ? .semibold : .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Color.white : DesignTokens.secondaryText)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 42)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.accentColor : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func settingsTabLabel(_ tab: SettingsMainTab) -> String {
        switch tab {
        case .appearance:
            return state.t(.appearance)
        case .permissions:
            return state.t(.permissions)
        case .config:
            return state.t(.config)
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

    private func configViewModeLabel(_ mode: NativeConfigViewMode) -> String {
        switch mode {
        case .form:
            return state.t(.form)
        case .raw:
            return state.t(.rawYAML)
        }
    }

    private func configSectionLabel(_ section: G9ClawConfigSection) -> String {
        switch section {
        case .runtime:
            return state.t(.runtime)
        case .models:
            return state.t(.models)
        case .agents:
            return state.t(.agents)
        case .alwaysOn:
            return state.t(.alwaysOn)
        case .memory:
            return state.t(.memory)
        case .rag:
            return state.t(.rag)
        case .router:
            return state.t(.routing)
        case .gateway:
            return state.t(.gateway)
        case .raw:
            return state.t(.rawYAML)
        }
    }

    @ViewBuilder
    private var activeContent: some View {
        switch activeTab {
        case .appearance:
            appearanceContent
        case .permissions:
            permissionsContent
        case .config:
            configContent
        }
    }

    private var appearanceContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsSectionBlock(title: state.t(.darkMode)) {
                SettingsCardBlock {
                    SettingsRowBlock(title: state.t(.darkMode), detail: state.t(.darkModeDetail)) {
                        WebSettingsToggle(isOn: darkModeBinding)
                    }
                }
            }

            SettingsSectionBlock(title: state.t(.appearance)) {
                SettingsCardBlock {
                    SettingsRowBlock(title: state.t(.displayLanguage), detail: state.t(.displayLanguageDetail)) {
                        Picker("", selection: $state.settings.language) {
                            ForEach(AppLanguage.allCases) { language in
                                Text(languageOptionLabel(language)).tag(language)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 160)
                    }
                }
            }

            SettingsSectionBlock(title: state.t(.toolDisplay)) {
                SettingsCardBlock(divided: true) {
                    SettingsRowBlock(title: state.t(.autoExpandTools), detail: "") {
                        WebSettingsToggle(isOn: uiPreferenceBinding(\.autoExpandTools))
                    }
                    SettingsRowBlock(title: state.t(.showRawParameters), detail: "") {
                        WebSettingsToggle(isOn: uiPreferenceBinding(\.showRawParameters))
                    }
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

            SettingsSectionBlock(title: state.t(.projectSorting)) {
                SettingsCardBlock {
                    SettingsRowBlock(title: state.t(.projectSorting), detail: state.t(.projectSortingDetail)) {
                        Picker("", selection: $state.settings.projectSortOrder) {
                            Text(state.t(.alphabetical)).tag(ProjectSortOrder.name)
                            Text(state.t(.recentActivity)).tag(ProjectSortOrder.date)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 160)
                    }
                }
            }

            SettingsSectionBlock(title: state.t(.codeEditor)) {
                SettingsCardBlock(divided: true) {
                    SettingsRowBlock(title: state.t(.wordWrap), detail: state.t(.wordWrapDetail)) {
                        Toggle("", isOn: $state.settings.codeEditor.wordWrap)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    SettingsRowBlock(title: state.t(.showMinimap), detail: state.t(.showMinimapDetail)) {
                        Toggle("", isOn: $state.settings.codeEditor.showMinimap)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    SettingsRowBlock(title: state.t(.lineNumbers), detail: state.t(.lineNumbersDetail)) {
                        Toggle("", isOn: $state.settings.codeEditor.lineNumbers)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    SettingsRowBlock(title: state.t(.fontSize), detail: state.t(.fontSizeDetail)) {
                        Picker("", selection: $state.settings.codeEditor.fontSize) {
                            ForEach(NativeAppearanceSettingsLayout.fontSizeOptions, id: \.self) { size in
                                Text("\(size)px").tag(size)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 96)
                    }
                }
            }
        }
        .controlSize(.regular)
    }

    private var darkModeBinding: Binding<Bool> {
        Binding(
            get: {
                switch state.settings.colorScheme {
                case .dark:
                    return true
                case .light:
                    return false
                case .system:
                    return colorScheme == .dark
                }
            },
            set: { enabled in
                state.settings.colorScheme = enabled ? .dark : .light
            }
        )
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
            return state.t(.languageSystem)
        case .light:
            return LocalizationService(language: state.settings.language).language == .chineseSimplified ? "浅色" : "Light"
        case .dark:
            return LocalizationService(language: state.settings.language).language == .chineseSimplified ? "深色" : "Dark"
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

            if configView == .form {
                HStack(alignment: .top, spacing: NativeConfigFormLayout.sectionNavigationGap) {
                    configSectionSidebar
                    VStack(alignment: .leading, spacing: 16) {
                        configSectionContent
                        configValidationSummary
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                rawYamlPanel
                configValidationSummary
            }

            reloadSummaryCard
            configSaveBar
        }
    }

    private var configHeaderCard: some View {
        SettingsCardBlock {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "doc.badge.gearshape")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DesignTokens.tertiaryText)
                        .frame(width: 22)
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
                HStack(spacing: 8) {
                    configViewModeToggle
                    Spacer(minLength: 8)
                    Button {
                        revealConfigFile()
                    } label: {
                        Label(state.t(.revealFile), systemImage: "folder")
                            .lineLimit(1)
                    }
                    .buttonStyle(WebToolbarButtonStyle())
                    Button {
                        reloadConfigFromDisk()
                    } label: {
                        Label(state.t(.refresh), systemImage: "arrow.clockwise")
                            .lineLimit(1)
                    }
                    .buttonStyle(WebToolbarButtonStyle())
                }
            }
            .padding(14)
        }
    }

    private var configViewModeToggle: some View {
        HStack(spacing: 2) {
            ForEach(NativeConfigViewMode.allCases) { mode in
                Button {
                    configView = mode
                } label: {
                    Label(configViewModeLabel(mode), systemImage: mode.systemImage)
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                }
                .buttonStyle(PillButtonStyle(isActive: configView == mode))
            }
        }
        .padding(2)
        .background(DesignTokens.neutral100, in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius))
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
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: NativeConfigFormLayout.sectionNavigationWidth)
        .padding(6)
        .background(DesignTokens.neutral50.opacity(0.7), in: RoundedRectangle(cornerRadius: DesignTokens.radius))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.radius).stroke(DesignTokens.separator))
    }

    private var rawYamlPanel: some View {
        SettingsCardBlock {
            VStack(alignment: .leading, spacing: 10) {
                Text(state.t(.rawYAML))
                    .font(.system(size: 13, weight: .semibold))
                TextEditor(text: $state.g9ClawConfigText)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 460)
                    .background(DesignTokens.neutral50, in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius))
                    .overlay(RoundedRectangle(cornerRadius: DesignTokens.smallRadius).stroke(DesignTokens.separator))
            }
            .padding(14)
        }
    }

    private var configValidationSummary: some View {
        let validation = validateConfig()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: validation.valid ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(validation.valid ? DesignTokens.success : DesignTokens.danger)
                Text(validation.valid ? state.t(.configValid) : state.t(.configInvalid))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(validation.valid ? DesignTokens.success : DesignTokens.danger)
                if isConfigDirty {
                    Text(state.t(.unsavedChanges))
                        .font(.system(size: 12))
                        .foregroundStyle(DesignTokens.tertiaryText)
                }
            }
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

    private var reloadSummaryCard: some View {
        SettingsSectionBlock(title: state.t(.reload), detail: state.t(.reloadDetail)) {
            SettingsCardBlock {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(NativeConfigReloadSummary.subsystems) { subsystem in
                        ReloadSummaryRow(
                            name: state.t(subsystem.label),
                            isReloaded: reloadSummaryIsReloaded(subsystem),
                            detail: reloadSummaryDetail(subsystem)
                        )
                    }
                }
                .padding(14)
            }
        }
    }

    private var configSaveBar: some View {
        HStack(spacing: 8) {
            Spacer()
            Button {
                reloadConfigFromDisk()
            } label: {
                Label(state.t(.reloadCurrent), systemImage: "arrow.clockwise")
            }
            .buttonStyle(WebToolbarButtonStyle())
            Button {
                saveConfigAndReload()
            } label: {
                Label(isConfigDirty ? state.t(.saveAndReload) : state.t(.saved), systemImage: "square.and.arrow.down")
            }
            .buttonStyle(WebToolbarButtonStyle(isProminent: true))
            .disabled(!isConfigDirty)
        }
        .padding(12)
        .background(DesignTokens.background.opacity(0.92), in: RoundedRectangle(cornerRadius: DesignTokens.radius))
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
                    }
                    .padding(14)
                }
            }
        case .models:
            modelsConfigContent
        case .agents:
            VStack(alignment: .leading, spacing: 18) {
                SettingsSectionBlock(title: state.t(.mainAgent)) {
                    SettingsCardBlock {
                        ConfigGrid {
                            SettingsPickerField(
                                state.t(.model),
                                selection: configBinding("agents.main.model"),
                                options: configModelOptions(includeEmpty: true),
                                emptyLabel: state.t(.pickModelEntry)
                            )
                        }
                        .padding(14)
                    }
                }
                SettingsSectionBlock(title: state.t(.subagents)) {
                    SettingsCardBlock {
                        ConfigGrid {
                            SettingsPickerField(
                                state.t(.defaultConfig),
                                selection: configBinding("agents.subagents.default"),
                                options: configModelOptions(includeInherit: true),
                                emptyLabel: state.t(.inheritMain)
                            )
                        }
                        .padding(14)
                    }
                }
            }
        case .alwaysOn:
            VStack(alignment: .leading, spacing: 18) {
                SettingsSectionBlock(title: state.t(.discoveryTrigger)) {
                    SettingsCardBlock(divided: true) {
                        SettingsRowBlock(title: state.t(.enabled), detail: state.t(.discoveryTriggerDetail)) {
                            WebSettingsToggle(isOn: configBoolBinding(NativeAlwaysOnConfigFormFields.enabledPath))
                        }
                        ConfigGrid {
                            ForEach(NativeAlwaysOnConfigFormFields.textFields) { field in
                                SettingsTextField(state.t(field.label), text: configBinding(field.path))
                            }
                        }
                        .padding(14)
                    }
                }
                SettingsSectionBlock(title: state.t(.projects)) {
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
                SettingsSectionBlock(title: state.t(.memory)) {
                    SettingsCardBlock(divided: true) {
                        SettingsRowBlock(title: state.t(.enabled), detail: state.t(.memoryDetail)) {
                            WebSettingsToggle(isOn: configBoolBinding(NativeMemoryConfigFormFields.enabledPath))
                        }
                        if configBool(NativeMemoryConfigFormFields.enabledPath) {
                            ConfigGrid {
                                SettingsPickerField(
                                    state.t(.model),
                                    selection: configBinding(NativeMemoryConfigFormFields.modelPath),
                                    options: configModelOptions(includeInherit: true),
                                    emptyLabel: state.t(.inheritMain)
                                )
                            }
                            .padding(14)
                        }
                    }
                }
            }
        case .rag:
            VStack(alignment: .leading, spacing: 18) {
                SettingsSectionBlock(title: state.t(.rag), detail: state.t(.ragSectionDetail)) {
                    VStack(alignment: .leading, spacing: 16) {
                        SettingsCardBlock {
                            SettingsRowBlock(title: state.t(.enabled), detail: state.t(.ragDetail)) {
                                WebSettingsToggle(isOn: configBoolBinding(NativeRagConfigFormFields.enabledPath))
                            }
                        }
                        SettingsCardBlock {
                            SettingsRowBlock(title: state.t(.disableBuiltInWebTools), detail: state.t(.disableBuiltInWebToolsDetail)) {
                                WebSettingsToggle(
                                    isOn: configBoolBinding(
                                        NativeRagConfigFormFields.disableBuiltInWebToolsPath,
                                        defaultValue: NativeRagConfigFormFields.disableBuiltInWebToolsDefault
                                    )
                                )
                            }
                        }
                        ForEach(NativeRagConfigFormFields.endpointCards) { endpoint in
                            ragEndpointCard(endpoint)
                        }
                    }
                }
            }
        case .router:
            VStack(alignment: .leading, spacing: 18) {
                SettingsSectionBlock(title: state.t(.routing)) {
                    SettingsCardBlock {
                        SettingsRowBlock(title: state.t(.enabled), detail: state.t(.routerDetail)) {
                            WebSettingsToggle(isOn: configBoolBinding(NativeRouterConfigFormFields.enabledPath))
                        }
                    }
                }
            }
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
            rawYamlPanel
        }
    }

    private var modelsConfigContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionBlock(title: state.t(.providers), detail: state.t(.providersDetail)) {
                SettingsCardBlock {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(state.t(.providers))
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Button(state.t(.addProvider)) { addProvider() }
                                .buttonStyle(WebToolbarButtonStyle())
                        }
                        let providers = configChildIDs(parentPath: "models.providers")
                        if providers.isEmpty {
                            dashedEmpty(state.t(.noProvidersConfigured))
                        } else {
                            ForEach(providers, id: \.self) { provider in
                                providerCard(provider)
                            }
                        }
                    }
                    .padding(14)
                }
            }
            SettingsSectionBlock(title: state.t(.entries), detail: state.t(.entriesDetail)) {
                SettingsCardBlock {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(state.t(.entries))
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Button(state.t(.addEntry)) { addEntry() }
                                .buttonStyle(WebToolbarButtonStyle())
                                .disabled(configChildIDs(parentPath: "models.providers").isEmpty)
                        }
                        let entries = configChildIDs(parentPath: "models.entries")
                        if entries.isEmpty {
                            dashedEmpty(state.t(.noEntriesConfigured))
                        } else {
                            ForEach(entries, id: \.self) { entry in
                                entryCard(entry)
                            }
                        }
                    }
                    .padding(14)
                }
            }
        }
    }

    private func ragEndpointCard(_ endpoint: NativeRagEndpointConfigCardSpec) -> some View {
        SettingsCardBlock(divided: true) {
            VStack(alignment: .leading, spacing: 3) {
                Text(state.t(endpoint.title))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DesignTokens.text)
                Text(state.t(endpoint.detail))
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.tertiaryText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            ConfigGrid {
                ForEach(endpoint.fields) { field in
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

    private func providerCard(_ provider: String) -> some View {
        SettingsCardBlock {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(provider)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    Spacer()
                    Text(configValue("models.providers.\(provider).type").isEmpty ? state.t(.missing) : configValue("models.providers.\(provider).type"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DesignTokens.tertiaryText)
                    Button(state.t(.rename)) { renameConfigObject(parentPath: "models.providers", oldID: provider) }
                        .buttonStyle(WebToolbarButtonStyle())
                    Button(state.t(.remove)) { removeConfigObject(path: "models.providers.\(provider)") }
                        .buttonStyle(WebToolbarButtonStyle())
                }
                ConfigGrid {
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
                }
                Text(state.t(.keychainHelp))
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.tertiaryText)
            }
            .padding(14)
        }
    }

    private func entryCard(_ entry: String) -> some View {
        SettingsCardBlock {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(entry)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    Spacer()
                    Button(state.t(.rename)) { renameConfigObject(parentPath: "models.entries", oldID: entry) }
                        .buttonStyle(WebToolbarButtonStyle())
                    Button(state.t(.remove)) { removeConfigObject(path: "models.entries.\(entry)") }
                        .buttonStyle(WebToolbarButtonStyle())
                }
                ConfigGrid {
                    SettingsPickerField(
                        state.t(.provider),
                        selection: configBinding("models.entries.\(entry).provider"),
                        options: NativeModelsConfigFormFields.providerOptions(providerIDs: configChildIDs(parentPath: "models.providers")),
                        emptyLabel: state.t(.provider)
                    )
                    SettingsTextField(state.t(.name), text: Binding(
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
                    SettingsTextField(state.t(.contextWindow), text: configBinding("models.entries.\(entry).contextWindow"))
                }
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

    private var alwaysOnProjectRows: [WorkspaceProject] {
        state.projects.filter { project in
            !state.isGeneralProject(project)
                && !AlwaysOnProjectConfig.projectRoot(state.effectiveWorkspacePath(for: project)).isEmpty
        }
    }

    private func alwaysOnProjectEnabledBinding(root: String) -> Binding<Bool> {
        Binding(
            get: {
                AlwaysOnProjectConfig.isEnabled(yaml: state.g9ClawConfigText, projectRoot: root)
            },
            set: { enabled in
                state.g9ClawConfigText = AlwaysOnProjectConfig.setEnabled(
                    in: state.g9ClawConfigText,
                    projectRoot: root,
                    enabled: enabled
                )
            }
        )
    }

    private func configValue(_ path: String) -> String {
        LegacyConfigLoader.scalarMap(from: state.g9ClawConfigText)[path] ?? ""
    }

    private func setConfigValue(_ path: String, _ value: String) {
        state.g9ClawConfigText = YAMLScalarEditor.set(path: path, value: value, in: state.g9ClawConfigText)
    }

    private var isConfigDirty: Bool {
        state.g9ClawConfigText != savedConfigText
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
        G9ClawConfigPath.configURL()
    }

    private func reloadConfigFromDisk() {
        do {
            let url = FileManager.default.fileExists(atPath: configFileURL().path)
                ? configFileURL()
                : G9ClawConfigPath.legacyConfigURL()
            let text = try String(contentsOf: url, encoding: .utf8)
            if isConfigDirty {
                configExternalNotice = state.t(.configReloadedNotice)
            }
            state.g9ClawConfigText = text
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

    private func saveConfigAndReload() {
        state.saveSettings()
        savedConfigText = state.g9ClawConfigText
        configError = nil
        configMessage = state.t(.savedAndReloaded)
        applyRuntimeFieldsFromConfig()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            state.settingsSaveNotice = nil
        }
    }

    private func applyRuntimeFieldsFromConfig() {
        let values = LegacyConfigLoader.scalarMap(from: state.g9ClawConfigText)
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
        let values = LegacyConfigLoader.scalarMap(from: state.g9ClawConfigText)
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
            warnings.append("gateway.runtimePaths.generalCwd is empty; General chat will use the default workspace.")
        }
        if configView == .raw && state.g9ClawConfigText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Config YAML is empty.")
        }
        return NativeConfigValidation(errors: errors, warnings: warnings)
    }

    private func defaultProviderID() -> String {
        let provider = configValue("models.entries.default.provider").trimmingCharacters(in: .whitespacesAndNewlines)
        return provider.isEmpty ? "g9claw" : provider
    }

    private func isDefaultProvider(_ provider: String) -> Bool {
        provider == defaultProviderID()
    }

    private func configChildIDs(parentPath: String) -> [String] {
        let prefix = parentPath + "."
        var ids = Set<String>()
        for key in LegacyConfigLoader.scalarMap(from: state.g9ClawConfigText).keys where key.hasPrefix(prefix) {
            let suffix = key.dropFirst(prefix.count)
            if let first = suffix.split(separator: ".").first {
                ids.insert(String(first))
            }
        }
        return ids.sorted()
    }

    private func configModelOptions(includeEmpty: Bool = false, includeInherit: Bool = false) -> [String] {
        NativeConfigModelOptions.options(
            values: LegacyConfigLoader.scalarMap(from: state.g9ClawConfigText),
            includeEmpty: includeEmpty,
            includeInherit: includeInherit
        )
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

    private func addProvider() {
        let ids = Set(configChildIDs(parentPath: "models.providers"))
        var index = 1
        while ids.contains("provider\(index)") { index += 1 }
        let id = "provider\(index)"
        state.g9ClawConfigText = YAMLScalarEditor.appendBlock(
            parentPath: "models.providers",
            id: id,
            scalars: NativeModelsConfigFormFields.newProviderScalars,
            in: state.g9ClawConfigText
        )
    }

    private func addEntry() {
        let ids = Set(configChildIDs(parentPath: "models.entries"))
        var id = ids.contains("default") ? "entry1" : "default"
        var index = 1
        while ids.contains(id) {
            index += 1
            id = "entry\(index)"
        }
        guard let firstProvider = configChildIDs(parentPath: "models.providers").first else { return }
        state.g9ClawConfigText = YAMLScalarEditor.appendBlock(
            parentPath: "models.entries",
            id: id,
            scalars: NativeModelsConfigFormFields.newEntryScalars(firstProvider: firstProvider),
            in: state.g9ClawConfigText
        )
    }

    private func renameConfigObject(parentPath: String, oldID: String) {
        let alert = NSAlert()
        alert.messageText = "\(state.t(.rename)) \(oldID)"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = oldID
        alert.accessoryView = field
        alert.addButton(withTitle: state.t(.rename))
        alert.addButton(withTitle: state.t(.cancel))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let nextID = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nextID.isEmpty, nextID != oldID else { return }
        state.g9ClawConfigText = YAMLScalarEditor.renameObject(parentPath: parentPath, oldID: oldID, newID: nextID, in: state.g9ClawConfigText)
    }

    private func removeConfigObject(path: String) {
        state.g9ClawConfigText = YAMLScalarEditor.removeObject(path: path, in: state.g9ClawConfigText)
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
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            content()
        }
        .padding(.top, 48)
        .padding(.bottom, 36)
        .padding(.horizontal, 34)
        .frame(maxWidth: 760, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .top)
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

enum NativeConfigViewMode: String, CaseIterable, Identifiable {
    case form
    case raw

    static let storageKey = "g9claw:configView"

    static func fromStoredRaw(_ rawValue: String) -> NativeConfigViewMode {
        NativeConfigViewMode(rawValue: rawValue) ?? .form
    }

    var id: String { rawValue }

    var label: String {
        switch self {
        case .form: "Form"
        case .raw: "Raw YAML"
        }
    }

    var systemImage: String {
        switch self {
        case .form: "list.bullet.rectangle"
        case .raw: "chevron.left.forwardslash.chevron.right"
        }
    }
}

enum NativeAppearanceSection: String, CaseIterable, Identifiable {
    case darkMode
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
        .darkMode,
        .language,
        .toolDisplay,
        .viewOptions,
        .inputSettings,
        .projectSorting,
        .codeEditor,
    ]
    static let usesDarkModeToggle = true
    static let usesThemePicker = false
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
    static let sectionNavigationWidth: CGFloat = 180
    static let sectionNavigationGap: CGFloat = 16
    static let sectionOrder: [G9ClawConfigSection] = [
        .runtime,
        .models,
        .agents,
        .alwaysOn,
        .memory,
        .rag,
        .router,
        .gateway,
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
            skippedDetail: .gatewayDisabled
        ),
        NativeConfigReloadSubsystemSpec(
            id: "proxy",
            label: .proxy,
            state: .nonEmptyPath("runtime.proxyPort"),
            reloadedDetail: .proxyConfigParsed,
            skippedDetail: .proxyDisabled
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

    static func providerOptions(providerIDs: [String]) -> [String] {
        [""] + providerIDs
    }

    static func newEntryScalars(firstProvider: String) -> [String: String] {
        [
            "provider": firstProvider,
            "name": "",
        ]
    }
}

struct NativeConfigTextFieldSpec: Hashable, Identifiable {
    let label: L10nKey
    let path: String
    var isSecure = false

    var id: String { path }
}

struct NativeRagEndpointConfigCardSpec: Hashable, Identifiable {
    let id: String
    let title: L10nKey
    let detail: L10nKey
    let fields: [NativeConfigTextFieldSpec]
    let includesDefaultTopK: Bool
}

enum NativeRuntimeConfigFormFields {
    static let workspacesRootPath = "runtime.workspacesRoot"
    static let textFields: [NativeConfigTextFieldSpec] = [
        NativeConfigTextFieldSpec(label: .host, path: "runtime.host"),
        NativeConfigTextFieldSpec(label: .serverPort, path: "runtime.serverPort"),
        NativeConfigTextFieldSpec(label: .vitePort, path: "runtime.vitePort"),
        NativeConfigTextFieldSpec(label: .proxyPort, path: "runtime.proxyPort"),
        NativeConfigTextFieldSpec(label: .contextWindow, path: "runtime.contextWindow"),
        NativeConfigTextFieldSpec(label: .apiTimeoutMs, path: "runtime.apiTimeoutMs"),
        NativeConfigTextFieldSpec(label: .databasePath, path: "runtime.databasePath"),
    ]
    static let visiblePaths = textFields.map(\.path) + [
        workspacesRootPath,
    ]
}

enum NativeAlwaysOnConfigFormFields {
    static let enabledPath = "alwaysOn.discovery.trigger.enabled"
    static let textFields: [NativeConfigTextFieldSpec] = [
        NativeConfigTextFieldSpec(label: .tickIntervalMinutes, path: "alwaysOn.discovery.trigger.tickIntervalMinutes"),
        NativeConfigTextFieldSpec(label: .cooldownMinutes, path: "alwaysOn.discovery.trigger.cooldownMinutes"),
        NativeConfigTextFieldSpec(label: .dailyBudget, path: "alwaysOn.discovery.trigger.dailyBudget"),
    ]
    static let visiblePaths = [enabledPath] + textFields.map(\.path)
}

enum NativeRagConfigFormFields {
    static let enabledPath = "rag.enabled"
    static let disableBuiltInWebToolsPath = "rag.disableBuiltInWebTools"
    static let disableBuiltInWebToolsDefault = true
    static let booleanDefaults = [
        enabledPath: false,
        disableBuiltInWebToolsPath: disableBuiltInWebToolsDefault,
    ]
    static let localKnowledgeFields: [NativeConfigTextFieldSpec] = [
        NativeConfigTextFieldSpec(label: .localKnowledgeBaseURL, path: "rag.localKnowledge.baseUrl"),
        NativeConfigTextFieldSpec(label: .apiKey, path: "rag.localKnowledge.apiKey", isSecure: true),
        NativeConfigTextFieldSpec(label: .embeddingModel, path: "rag.localKnowledge.modelName"),
        NativeConfigTextFieldSpec(label: .databaseURL, path: "rag.localKnowledge.databaseUrl"),
    ]
    static let glmWebSearchFields: [NativeConfigTextFieldSpec] = [
        NativeConfigTextFieldSpec(label: .glmWebSearchBaseURL, path: "rag.glmWebSearch.baseUrl"),
        NativeConfigTextFieldSpec(label: .apiKey, path: "rag.glmWebSearch.apiKey", isSecure: true),
        NativeConfigTextFieldSpec(label: .glmDefaultTopK, path: "rag.glmWebSearch.defaultTopK"),
    ]
    static let endpointCards: [NativeRagEndpointConfigCardSpec] = [
        NativeRagEndpointConfigCardSpec(
            id: "localKnowledge",
            title: .ragLocalKnowledgeTitle,
            detail: .ragLocalKnowledgeDetail,
            fields: localKnowledgeFields,
            includesDefaultTopK: false
        ),
        NativeRagEndpointConfigCardSpec(
            id: "glmWebSearch",
            title: .ragGlmWebSearchTitle,
            detail: .ragGlmWebSearchDetail,
            fields: glmWebSearchFields,
            includesDefaultTopK: true
        ),
    ]
    static let textFields: [NativeConfigTextFieldSpec] = localKnowledgeFields + glmWebSearchFields
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
    static let visiblePaths = [
        enabledPath,
        modelPath,
    ]
}

enum NativeRouterConfigFormFields {
    static let enabledPath = "router.enabled"
    static let visiblePaths = [
        enabledPath,
    ]
}

enum NativeGatewayConfigFormFields {
    static let enabledPath = "gateway.enabled"
    static let homePath = "gateway.home"
    static let visiblePaths = [
        enabledPath,
        homePath,
    ]
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

private struct ReloadSummaryRow: View {
    @EnvironmentObject private var state: AppState
    var name: String
    var isReloaded: Bool
    var detail: String

    var body: some View {
        HStack(spacing: 10) {
            Text(name)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .frame(width: 98, alignment: .leading)
            Text(isReloaded ? state.t(.reloaded) : state.t(.skipped))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isReloaded ? DesignTokens.success : DesignTokens.tertiaryText)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background((isReloaded ? DesignTokens.success : DesignTokens.neutral400).opacity(0.10), in: Capsule())
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(DesignTokens.tertiaryText)
                .lineLimit(1)
            Spacer()
        }
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
        let value = LegacyConfigLoader.scalarMap(from: yaml)["alwaysOn.discovery.projects.\(root).enabled"]?.lowercased()
        return value == "true" || value == "1" || value == "yes"
    }

    static func setEnabled(in yaml: String, projectRoot rawRoot: String, enabled: Bool) -> String {
        let root = projectRoot(rawRoot)
        guard !root.isEmpty else { return yaml }
        return YAMLScalarEditor.setObjectScalar(
            parentPath: "alwaysOn.discovery.projects",
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

struct SettingsPickerField: View {
    var label: String
    @Binding var selection: String
    var options: [String]
    var emptyLabel: String

    init(_ label: String, selection: Binding<String>, options: [String], emptyLabel: String) {
        self.label = label
        self._selection = selection
        self.options = options
        self.emptyLabel = emptyLabel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DesignTokens.tertiaryText)
            Picker(label, selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(option.isEmpty || option == "inherit" ? emptyLabel : option)
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
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

private struct SettingsIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? DesignTokens.text : DesignTokens.secondaryText)
            .background(GlassControlBackground(isActive: false, cornerRadius: 10, material: .popover, showsShadow: false))
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
