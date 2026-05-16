import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        SettingsContentView(onClose: nil)
            .environmentObject(state)
    }
}

struct SettingsModalView: View {
    @EnvironmentObject private var state: AppState
    var onClose: () -> Void

    var body: some View {
        ZStack {
            DesignTokens.background.opacity(0.80)
                .ignoresSafeArea()
                .background(.ultraThinMaterial)
                .onTapGesture { onClose() }

            SettingsContentView(onClose: onClose)
                .environmentObject(state)
                .frame(maxWidth: 896, maxHeight: .infinity)
                .frame(height: nil)
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
        }
    }
}

private struct SettingsContentView: View {
    @EnvironmentObject private var state: AppState
    @State private var activeTab: SettingsMainTab = .appearance
    @State private var configSection: EdgeClawConfigSection = .runtime
    @State private var configView: NativeConfigViewMode = .form
    @State private var savedConfigText = ""
    @State private var configMessage: String?
    @State private var configError: String?
    @State private var configExternalNotice: String?
    var onClose: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                sidebar
                Divider()
                    .background(DesignTokens.separator)
                ScrollView {
                    activeContent
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .transition(.opacity.combined(with: .offset(y: 4)))
                        .id(activeTab)
                }
                .background(DesignTokens.background)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DesignTokens.background)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(DesignTokens.separator, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.16), radius: 28, y: 12)
        )
        .onAppear {
            activeTab = state.settingsInitialTab
            if savedConfigText.isEmpty {
                savedConfigText = state.edgeClawConfigText
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(state.t(.settings))
                .font(.system(size: DesignTokens.settingsTitleSize, weight: .semibold))
            if let notice = state.settingsSaveNotice {
                Text(notice)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DesignTokens.success)
            }
            Spacer()
            Button {
                onClose?()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(SettingsIconButtonStyle())
            .opacity(onClose == nil ? 0 : 1)
            .disabled(onClose == nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DesignTokens.separator).frame(height: 1)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(SettingsMainTab.allCases) { tab in
                Button {
                    activeTab = tab
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 15))
                            .frame(width: 18)
                        Text(settingsTabLabel(tab))
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .foregroundStyle(activeTab == tab ? DesignTokens.text : DesignTokens.tertiaryText)
                    .background(
                        RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous)
                            .fill(activeTab == tab ? DesignTokens.neutral100 : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(12)
        .frame(width: 224)
        .background(DesignTokens.neutral50.opacity(0.74))
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

    private func configSectionLabel(_ section: EdgeClawConfigSection) -> String {
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
        VStack(alignment: .leading, spacing: 26) {
            SettingsSectionBlock(title: state.t(.appearance)) {
                SettingsCardBlock {
                    SettingsRowBlock(title: state.t(.appearance), detail: "") {
                        WebSettingsToggle(isOn: Binding(
                            get: { state.settings.colorScheme == .dark },
                            set: { state.settings.colorScheme = $0 ? .dark : .light }
                        ))
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
                        .frame(width: 150)
                    }
                }
            }

            SettingsSectionBlock(title: state.t(.projectSorting)) {
                SettingsCardBlock {
                    SettingsRowBlock(title: state.t(.projectSorting), detail: "") {
                        Picker("", selection: $state.settings.projectSortOrder) {
                            Text(state.t(.alphabetical)).tag(ProjectSortOrder.name)
                            Text(state.t(.recentActivity)).tag(ProjectSortOrder.date)
                        }
                        .labelsHidden()
                        .frame(width: 170)
                    }
                }
            }

            SettingsSectionBlock(title: state.t(.codeEditor)) {
                SettingsCardBlock(divided: true) {
                    SettingsRowBlock(title: state.t(.wordWrap), detail: state.t(.wordWrapDetail)) {
                        Toggle("", isOn: $state.settings.codeEditor.wordWrap).labelsHidden()
                    }
                    SettingsRowBlock(title: state.t(.showMinimap), detail: state.t(.showMinimapDetail)) {
                        Toggle("", isOn: $state.settings.codeEditor.showMinimap).labelsHidden()
                    }
                    SettingsRowBlock(title: state.t(.lineNumbers), detail: state.t(.lineNumbersDetail)) {
                        Toggle("", isOn: $state.settings.codeEditor.lineNumbers).labelsHidden()
                    }
                    SettingsRowBlock(title: state.t(.fontSize), detail: state.t(.fontSizeDetail)) {
                        Picker("", selection: $state.settings.codeEditor.fontSize) {
                            ForEach([10, 11, 12, 13, 14, 15, 16, 18, 20], id: \.self) { size in
                                Text("\(size)px").tag(size)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 90)
                    }
                }
            }
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
                HStack(alignment: .top, spacing: 18) {
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
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "doc.badge.gearshape")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DesignTokens.tertiaryText)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 6) {
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
                        }
                        Text(configFileURL().path)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(DesignTokens.tertiaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(DesignTokens.neutral100, in: RoundedRectangle(cornerRadius: 5))
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        configViewModeToggle
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
            ForEach(EdgeClawConfigSection.formSections) { section in
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
        .frame(width: 180)
        .padding(6)
        .background(DesignTokens.neutral50.opacity(0.7), in: RoundedRectangle(cornerRadius: DesignTokens.radius))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.radius).stroke(DesignTokens.separator))
    }

    private var rawYamlPanel: some View {
        SettingsCardBlock {
            VStack(alignment: .leading, spacing: 10) {
                Text(state.t(.rawYAML))
                    .font(.system(size: 13, weight: .semibold))
                TextEditor(text: $state.edgeClawConfigText)
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
                    ReloadSummaryRow(name: state.t(.processEnv), isReloaded: true, detail: state.t(.nativeSettingsApplied))
                    ReloadSummaryRow(name: state.t(.memory), isReloaded: configBool("memory.enabled"), detail: configBool("memory.enabled") ? state.t(.memoryServiceEnabled) : state.t(.memoryDisabled))
                    ReloadSummaryRow(name: state.t(.routing), isReloaded: configBool("router.enabled"), detail: configBool("router.enabled") ? state.t(.routerDashboardNative) : state.t(.routerDisabled))
                    ReloadSummaryRow(name: state.t(.gateway), isReloaded: configBool("gateway.enabled"), detail: configBool("gateway.enabled") ? state.t(.gatewayConfigParsed) : state.t(.gatewayDisabled))
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
            .disabled(!isConfigDirty && state.apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                        SettingsTextField(state.t(.host), text: configBinding("runtime.host"))
                        SettingsTextField(state.t(.serverPort), text: configBinding("runtime.serverPort"))
                        SettingsTextField(state.t(.vitePort), text: configBinding("runtime.vitePort"))
                        SettingsTextField(state.t(.proxyPort), text: configBinding("runtime.proxyPort"))
                        SettingsTextField(state.t(.contextWindow), text: configBinding("runtime.contextWindow"))
                        SettingsTextField(state.t(.apiTimeoutMs), text: configBinding("runtime.apiTimeoutMs"))
                        SettingsTextField(state.t(.httpsProxy), text: configBinding("runtime.httpsProxy"))
                        SettingsTextField(state.t(.databasePath), text: configBinding("runtime.databasePath"))
                        SettingsTextField(state.t(.workspacesRoot), text: Binding(
                            get: { state.settings.workspacesRoot },
                            set: { value in
                                state.settings.workspacesRoot = value
                                setConfigValue("runtime.workspacesRoot", value)
                            }
                        ))
                        SettingsTextField(state.t(.generalWorkspace), text: Binding(
                            get: { state.settings.generalWorkspacePath },
                            set: { value in
                                state.settings.generalWorkspacePath = value
                                setConfigValue("gateway.runtimePaths.generalCwd", value)
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
                    SettingsCardBlock { ConfigGrid { SettingsTextField(state.t(.model), text: configBinding("agents.main.model")) }.padding(14) }
                }
                SettingsSectionBlock(title: state.t(.subagents)) {
                    SettingsCardBlock { ConfigGrid { SettingsTextField(state.t(.defaultConfig), text: configBinding("agents.subagents.default")) }.padding(14) }
                }
            }
        case .alwaysOn:
            VStack(alignment: .leading, spacing: 18) {
                SettingsSectionBlock(title: state.t(.discoveryTrigger)) {
                    SettingsCardBlock(divided: true) {
                        SettingsRowBlock(title: state.t(.enabled), detail: state.t(.discoveryTriggerDetail)) {
                            WebSettingsToggle(isOn: configBoolBinding("alwaysOn.discovery.trigger.enabled"))
                        }
                        ConfigGrid {
                            SettingsTextField(state.t(.tickIntervalMinutes), text: configBinding("alwaysOn.discovery.trigger.tickIntervalMinutes"))
                            SettingsTextField(state.t(.cooldownMinutes), text: configBinding("alwaysOn.discovery.trigger.cooldownMinutes"))
                            SettingsTextField(state.t(.dailyBudget), text: configBinding("alwaysOn.discovery.trigger.dailyBudget"))
                            SettingsTextField(state.t(.heartbeatStaleSeconds), text: configBinding("alwaysOn.discovery.trigger.heartbeatStaleSeconds"))
                            SettingsTextField(state.t(.recentUserMsgMinutes), text: configBinding("alwaysOn.discovery.trigger.recentUserMsgMinutes"))
                            SettingsTextField(state.t(.preferClient), text: configBinding("alwaysOn.discovery.trigger.preferClient"))
                        }
                        .padding(14)
                    }
                }
            }
        case .memory:
            VStack(alignment: .leading, spacing: 18) {
                SettingsSectionBlock(title: state.t(.memory)) {
                    SettingsCardBlock(divided: true) {
                        SettingsRowBlock(title: state.t(.enabled), detail: state.t(.memoryDetail)) {
                            WebSettingsToggle(isOn: configBoolBinding("memory.enabled"))
                        }
                        SettingsRowBlock(title: state.t(.includeAssistant), detail: state.t(.includeAssistantDetail)) {
                            WebSettingsToggle(isOn: configBoolBinding("memory.includeAssistant"))
                        }
                        ConfigGrid {
                            SettingsTextField(state.t(.model), text: configBinding("memory.model"))
                            SettingsTextField(state.t(.reasoningMode), text: configBinding("memory.reasoningMode"))
                            SettingsTextField(state.t(.autoIndexIntervalMinutes), text: configBinding("memory.autoIndexIntervalMinutes"))
                            SettingsTextField(state.t(.autoDreamIntervalMinutes), text: configBinding("memory.autoDreamIntervalMinutes"))
                            SettingsTextField(state.t(.captureStrategy), text: configBinding("memory.captureStrategy"))
                            SettingsTextField(state.t(.maxMessageChars), text: configBinding("memory.maxMessageChars"))
                            SettingsTextField(state.t(.heartbeatBatchSize), text: configBinding("memory.heartbeatBatchSize"))
                        }
                        .padding(14)
                    }
                }
            }
        case .rag:
            VStack(alignment: .leading, spacing: 18) {
                SettingsSectionBlock(title: state.t(.rag)) {
                    SettingsCardBlock(divided: true) {
                        SettingsRowBlock(title: state.t(.enabled), detail: state.t(.ragDetail)) {
                            WebSettingsToggle(isOn: configBoolBinding("rag.enabled"))
                        }
                        SettingsRowBlock(title: state.t(.disableBuiltInWebTools), detail: state.t(.disableBuiltInWebToolsDetail)) {
                            WebSettingsToggle(isOn: configBoolBinding("rag.disableBuiltInWebTools"))
                        }
                        ConfigGrid {
                            SettingsTextField(state.t(.localKnowledgeBaseURL), text: configBinding("rag.localKnowledge.baseUrl"))
                            SettingsTextField(state.t(.embeddingModel), text: configBinding("rag.localKnowledge.modelName"))
                            SettingsTextField(state.t(.databaseURL), text: configBinding("rag.localKnowledge.databaseUrl"))
                            SettingsTextField(state.t(.defaultTopK), text: configBinding("rag.localKnowledge.defaultTopK"))
                            SettingsTextField(state.t(.glmWebSearchBaseURL), text: configBinding("rag.glmWebSearch.baseUrl"))
                            SettingsTextField(state.t(.glmDefaultTopK), text: configBinding("rag.glmWebSearch.defaultTopK"))
                        }
                        .padding(14)
                    }
                }
            }
        case .router:
            VStack(alignment: .leading, spacing: 18) {
                SettingsSectionBlock(title: state.t(.routing)) {
                    SettingsCardBlock(divided: true) {
                        SettingsRowBlock(title: state.t(.enabled), detail: state.t(.routerDetail)) {
                            WebSettingsToggle(isOn: configBoolBinding("router.enabled"))
                        }
                        SettingsRowBlock(title: state.t(.routerLog), detail: state.t(.routerLogDetail)) {
                            WebSettingsToggle(isOn: configBoolBinding("router.log"))
                        }
                        ConfigGrid {
                            SettingsTextField(state.t(.host), text: configBinding("router.host"))
                            SettingsTextField(state.t(.port), text: configBinding("router.port"))
                            SettingsTextField(state.t(.apiTimeoutMs), text: configBinding("router.apiTimeoutMs"))
                            SettingsTextField(state.t(.defaultRouteModel), text: configBinding("router.routes.default.model"))
                            SettingsTextField(state.t(.backgroundRouteModel), text: configBinding("router.routes.background.model"))
                            SettingsTextField(state.t(.thinkRouteModel), text: configBinding("router.routes.think.model"))
                            SettingsTextField(state.t(.longContextRouteModel), text: configBinding("router.routes.longContext.model"))
                            SettingsTextField(state.t(.webSearchRouteModel), text: configBinding("router.routes.webSearch.model"))
                            SettingsTextField(state.t(.longContextThreshold), text: configBinding("router.routes.longContextThreshold"))
                        }
                        .padding(14)
                    }
                }
                SettingsSectionBlock(title: state.t(.tokenSaver)) {
                    SettingsCardBlock(divided: true) {
                        SettingsRowBlock(title: state.t(.enabled), detail: state.t(.tokenSaverDetail)) {
                            WebSettingsToggle(isOn: configBoolBinding("router.tokenSaver.enabled"))
                        }
                        ConfigGrid {
                            SettingsTextField(state.t(.judgeModel), text: configBinding("router.tokenSaver.judgeModel"))
                            SettingsTextField(state.t(.defaultTier), text: configBinding("router.tokenSaver.defaultTier"))
                            SettingsTextField(state.t(.subagentPolicy), text: configBinding("router.tokenSaver.subagentPolicy"))
                            SettingsTextField(state.t(.savingsBaselineModel), text: configBinding("router.tokenStats.savingsBaselineModel"))
                        }
                        .padding(14)
                    }
                }
            }
        case .gateway:
            VStack(alignment: .leading, spacing: 18) {
                SettingsSectionBlock(title: state.t(.gateway)) {
                    SettingsCardBlock(divided: true) {
                        SettingsRowBlock(title: state.t(.enabled), detail: state.t(.gatewayDetail)) {
                            WebSettingsToggle(isOn: configBoolBinding("gateway.enabled"))
                        }
                        SettingsRowBlock(title: state.t(.allowAllUsers), detail: state.t(.allowAllUsersDetail)) {
                            WebSettingsToggle(isOn: configBoolBinding("gateway.allowAllUsers"))
                        }
                        SettingsRowBlock(title: state.t(.groupSessionsPerUser), detail: state.t(.groupSessionsPerUserDetail)) {
                            WebSettingsToggle(isOn: configBoolBinding("gateway.groupSessionsPerUser"))
                        }
                        SettingsRowBlock(title: state.t(.threadSessionsPerUser), detail: state.t(.threadSessionsPerUserDetail)) {
                            WebSettingsToggle(isOn: configBoolBinding("gateway.threadSessionsPerUser"))
                        }
                        ConfigGrid {
                            SettingsTextField(state.t(.home), text: configBinding("gateway.home"))
                            SettingsTextField(state.t(.unauthorizedDMBehavior), text: configBinding("gateway.unauthorizedDmBehavior"))
                            SettingsTextField(state.t(.sessionMetadata), text: configBinding("gateway.runtimePaths.sessionMetadata"))
                            SettingsTextField(state.t(.userBindings), text: configBinding("gateway.runtimePaths.userBindings"))
                            SettingsTextField(state.t(.generalCWD), text: configBinding("gateway.runtimePaths.generalCwd"))
                            SettingsTextField(state.t(.generalJSONL), text: configBinding("gateway.runtimePaths.generalJsonl"))
                            SettingsTextField(state.t(.boundProjectJSONL), text: configBinding("gateway.runtimePaths.boundProjectJsonl"))
                        }
                        .padding(14)
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
                                providerCard(provider, keychainBacked: provider.hasPrefix("edgeclaw"))
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

    private func providerCard(_ provider: String, keychainBacked: Bool) -> some View {
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
                    SettingsTextField(state.t(.type), text: configBinding("models.providers.\(provider).type"))
                    SettingsTextField(state.t(.baseURL), text: Binding(
                        get: {
                            provider == "edgeclaw" ? state.settings.providerConfig.baseURL : configValue("models.providers.\(provider).baseUrl")
                        },
                        set: { value in
                            if provider == "edgeclaw" {
                                state.settings.providerConfig.baseURL = value
                            }
                            setConfigValue("models.providers.\(provider).baseUrl", value)
                        }
                    ))
                    if keychainBacked {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(state.t(.apiKey))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(DesignTokens.tertiaryText)
                            SecureField(state.t(.storedInKeychain), text: $state.apiKeyDraft)
                                .textFieldStyle(WebFieldStyle())
                                .font(.system(size: 12, design: .monospaced))
                            Text(state.t(.keychainHelp))
                                .font(.system(size: 11))
                                .foregroundStyle(DesignTokens.tertiaryText)
                        }
                    } else {
                        SettingsTextField(state.t(.apiKey), text: configBinding("models.providers.\(provider).apiKey"))
                    }
                }
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
                    SettingsTextField(state.t(.provider), text: configBinding("models.entries.\(entry).provider"))
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

    private func configBoolBinding(_ path: String) -> Binding<Bool> {
        Binding(
            get: {
                let value = configValue(path).lowercased()
                return value == "true" || value == "yes" || value == "1"
            },
            set: { setConfigValue(path, $0 ? "true" : "false") }
        )
    }

    private func configValue(_ path: String) -> String {
        LegacyConfigLoader.scalarMap(from: state.edgeClawConfigText)[path] ?? ""
    }

    private func setConfigValue(_ path: String, _ value: String) {
        state.edgeClawConfigText = YAMLScalarEditor.set(path: path, value: value, in: state.edgeClawConfigText)
    }

    private var isConfigDirty: Bool {
        state.edgeClawConfigText != savedConfigText
    }

    private func configBool(_ path: String) -> Bool {
        let lower = configValue(path).lowercased()
        return lower == "true" || lower == "1" || lower == "yes"
    }

    private func configFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".edgeclaw", isDirectory: true)
            .appendingPathComponent("config.yaml")
    }

    private func reloadConfigFromDisk() {
        do {
            let text = try String(contentsOf: configFileURL(), encoding: .utf8)
            if isConfigDirty {
            configExternalNotice = state.t(.configReloadedNotice)
            }
            state.edgeClawConfigText = text
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
        savedConfigText = state.edgeClawConfigText
        configError = nil
        configMessage = state.t(.savedAndReloaded)
        applyRuntimeFieldsFromConfig()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            state.settingsSaveNotice = nil
        }
    }

    private func applyRuntimeFieldsFromConfig() {
        let values = LegacyConfigLoader.scalarMap(from: state.edgeClawConfigText)
        if let root = values["runtime.workspacesRoot"], !root.isEmpty {
            state.settings.workspacesRoot = NSString(string: root).expandingTildeInPath
        }
        if let general = values["gateway.runtimePaths.generalCwd"], !general.isEmpty {
            state.settings.generalWorkspacePath = NSString(string: general).expandingTildeInPath
        }
        if let timeout = values["runtime.apiTimeoutMs"].flatMap(Int.init) {
            state.settings.apiTimeoutMs = timeout
        }
        if let context = values["runtime.contextWindow"].flatMap(Int.init) {
            state.settings.contextWindow = context
        }
        let defaultProvider = values["models.entries.default.provider"] ?? "edgeclaw"
        if let baseURL = values["models.providers.\(defaultProvider).baseUrl"] {
            state.settings.providerConfig.baseURL = baseURL
        }
        if let model = values["models.entries.default.name"] {
            state.settings.providerConfig.model = model
        }
    }

    private func validateConfig() -> NativeConfigValidation {
        let values = LegacyConfigLoader.scalarMap(from: state.edgeClawConfigText)
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
        if configView == .raw && state.edgeClawConfigText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Config YAML is empty.")
        }
        return NativeConfigValidation(errors: errors, warnings: warnings)
    }

    private func configChildIDs(parentPath: String) -> [String] {
        let prefix = parentPath + "."
        var ids = Set<String>()
        for key in LegacyConfigLoader.scalarMap(from: state.edgeClawConfigText).keys where key.hasPrefix(prefix) {
            let suffix = key.dropFirst(prefix.count)
            if let first = suffix.split(separator: ".").first {
                ids.insert(String(first))
            }
        }
        return ids.sorted()
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
        state.edgeClawConfigText = YAMLScalarEditor.appendBlock(
            parentPath: "models.providers",
            id: id,
            scalars: [
                "type": "openai-chat",
                "baseUrl": "",
                "apiKey": "",
                "transformer": "null",
                "headers": "{}",
            ],
            in: state.edgeClawConfigText
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
        let firstProvider = configChildIDs(parentPath: "models.providers").first ?? ""
        state.edgeClawConfigText = YAMLScalarEditor.appendBlock(
            parentPath: "models.entries",
            id: id,
            scalars: [
                "provider": firstProvider,
                "name": "",
                "contextWindow": "160000",
            ],
            in: state.edgeClawConfigText
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
        state.edgeClawConfigText = YAMLScalarEditor.renameObject(parentPath: parentPath, oldID: oldID, newID: nextID, in: state.edgeClawConfigText)
    }

    private func removeConfigObject(path: String) {
        state.edgeClawConfigText = YAMLScalarEditor.removeObject(path: path, in: state.edgeClawConfigText)
    }

    private func exportPermissions() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "edgeclaw-permissions.json"
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
                            .textFieldStyle(WebFieldStyle())
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

private enum NativeConfigViewMode: String, CaseIterable, Identifiable {
    case form
    case raw

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

private struct NativeConfigValidation {
    var errors: [String]
    var warnings: [String]
    var valid: Bool { errors.isEmpty }
}

private extension EdgeClawConfigSection {
    static let formSections: [EdgeClawConfigSection] = [
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
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title.uppercased())
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.72)
                    .foregroundStyle(DesignTokens.tertiaryText)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(DesignTokens.tertiaryText)
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
        .background(DesignTokens.background, in: RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous)
                .stroke(DesignTokens.separator, lineWidth: 1)
        )
    }
}

struct WebSettingsToggle: View {
    @EnvironmentObject private var state: AppState
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            RoundedRectangle(cornerRadius: 999, style: .continuous)
                .fill(isOn ? DesignTokens.accent : DesignTokens.neutral100)
                .overlay(
                    RoundedRectangle(cornerRadius: 999, style: .continuous)
                        .stroke(isOn ? DesignTokens.accent : DesignTokens.separator, lineWidth: 2)
                )
                .frame(width: 48, height: 28)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(DesignTokens.background)
                        .shadow(color: .black.opacity(0.16), radius: 2, y: 1)
                        .frame(width: 20, height: 20)
                        .padding(.horizontal, 4)
                        .overlay {
                            Image(systemName: isOn ? "moon.fill" : "sun.max.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(isOn ? DesignTokens.accent : DesignTokens.warning)
                        }
                }
        }
        .buttonStyle(.plain)
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
            let currentPath = (stack.map(\.key) + [key]).joined(separator: ".")
            if currentPath == path {
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

private struct SettingsRowBlock<Content: View>: View {
    var title: String
    var detail: String
    @ViewBuilder var trailing: () -> Content

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(DesignTokens.tertiaryText)
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 58)
    }
}

struct SettingsTextField: View {
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
            TextField(label, text: $text)
                .textFieldStyle(WebFieldStyle())
                .font(.system(size: 12, design: .monospaced))
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
            .background(isActive ? DesignTokens.neutral100 : Color.clear, in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

private struct SettingsIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(DesignTokens.tertiaryText)
            .background(configuration.isPressed ? DesignTokens.neutral100 : Color.clear, in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius))
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
