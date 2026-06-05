import SwiftUI

struct MainAreaView: View {
    @EnvironmentObject private var state: AppState
    @Namespace private var toolSwitcherNamespace

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .top) {
            if let error = state.errorBanner {
                noticeBanner(error, tint: DesignTokens.danger, icon: "exclamationmark.triangle")
                    .padding(.top, DesignTokens.headerHeight)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(10)
            } else if let warning = state.warningBanner {
                noticeBanner(warning, tint: DesignTokens.warning, icon: "info.circle")
                    .padding(.top, DesignTokens.headerHeight)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(10)
            }
        }
        .background {
            MainGlassBackground()
        }
        .foregroundStyle(DesignTokens.text)
    }

    private var header: some View {
        GeometryReader { proxy in
            let availableWidth = proxy.size.width
            let showSessionTitle = availableWidth >= 1160
            let horizontalPadding: CGFloat = availableWidth < 760 ? 12 : 18
            let leadingTitlebarReserve: CGFloat = state.isSidebarVisible ? 0 : DesignTokens.titlebarContentReserveWhenSidebarHidden
            let leadingPadding = horizontalPadding + leadingTitlebarReserve
            let trailingPadding = horizontalPadding
            let controlGap: CGFloat = availableWidth < 1080 ? 6 : 10
            let innerWidth = max(0, availableWidth - leadingPadding - trailingPadding)
            let showsToolSwitcher = showsHeaderToolSwitcher
            let switcherLayout = MainHeaderToolSwitcherLayout.resolve(
                availableWidth: innerWidth,
                activeTab: state.activeTab,
                tabs: availableToolTabs
            )

            HStack(spacing: 0) {
                breadcrumb(showSessionTitle: showSessionTitle, showTabLabel: showsToolSwitcher)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(4)
                    .clipped()

                if showsToolSwitcher {
                    toolSwitcher(layout: switcherLayout)
                        .padding(.leading, controlGap)
                        .frame(width: switcherLayout.estimatedWidth, alignment: .trailing)
                        .layoutPriority(5)
                }
            }
            .padding(.leading, leadingPadding)
            .padding(.trailing, trailingPadding)
            .frame(width: proxy.size.width, height: DesignTokens.titlebarControlSize)
            .padding(.top, DesignTokens.titlebarControlTop)
            .frame(width: proxy.size.width, height: DesignTokens.headerHeight, alignment: .top)
        }
        .frame(height: DesignTokens.headerHeight)
        .background {
            MainGlassBackground()
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DesignTokens.separator.opacity(0.46))
                .frame(height: 1)
        }
        .onAppear(perform: clampActiveTabToAvailableTabs)
        .onChange(of: state.selectedProjectID) { _, _ in
            clampActiveTabToAvailableTabs()
        }
        .onChange(of: state.activeTab) { _, _ in
            clampActiveTabToAvailableTabs()
        }
    }

    private func breadcrumb(showSessionTitle: Bool, showTabLabel: Bool) -> some View {
        let workspaceTitle = selectedWorkspaceTitle

        return HStack(spacing: 6) {
            Text(workspaceTitle)
                .foregroundStyle(DesignTokens.neutral500)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(5)
            if showTabLabel {
                Text("/")
                    .foregroundStyle(DesignTokens.neutral400.opacity(0.60))
                Text(state.tabLabel(state.activeTab))
                    .fontWeight(.medium)
                    .foregroundStyle(DesignTokens.text)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            if showSessionTitle, let session = state.selectedSession {
                Text(session.displayTitle)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DesignTokens.neutral500)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 6)
                    .layoutPriority(0)
            }
        }
        .font(.system(size: 12.5))
        .frame(minWidth: 0, alignment: .leading)
    }

    private var selectedWorkspaceTitle: String {
        guard let selectedProject = state.selectedProject else {
            return state.t(.general)
        }
        if state.isGeneralProject(selectedProject) {
            return state.t(.general)
        }
        return selectedProject.displayName
    }

    private var showsHeaderToolSwitcher: Bool {
        state.selectedProject != nil
    }

    private var availableToolTabs: [AppTab] {
        guard let selectedProject = state.selectedProject else {
            return [.chat]
        }
        if state.isGeneralProject(selectedProject) {
            return [.chat, .skills, .dashboard]
        }
        return AppTab.primaryTabs
    }

    private func clampActiveTabToAvailableTabs() {
        guard !availableToolTabs.contains(state.activeTab) else { return }
        state.activeTab = .chat
    }

    @ViewBuilder
    private func toolSwitcher(layout: MainHeaderToolSwitcherLayout) -> some View {
        HStack(spacing: MainHeaderToolSwitcherLayout.itemSpacing) {
            ForEach(layout.visibleTabs, id: \.id) { tab in
                toolButton(tab, iconOnly: layout.iconOnly)
            }
        }
        .padding(.horizontal, MainHeaderToolSwitcherLayout.containerPadding)
        .padding(.vertical, MainHeaderToolSwitcherLayout.containerVerticalPadding)
        .frame(width: layout.estimatedWidth, height: MainHeaderToolSwitcherLayout.containerHeight, alignment: .trailing)
        .background { toolSwitcherBackground }
        .animation(.snappy(duration: 0.22), value: state.activeTab)
    }

    private var toolSwitcherBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: MainHeaderToolSwitcherLayout.containerCornerRadius, style: .continuous)
                .fill(.clear)
                .background(
                    VisualEffectBackground(material: .titlebar, blendingMode: .withinWindow)
                        .clipShape(RoundedRectangle(cornerRadius: MainHeaderToolSwitcherLayout.containerCornerRadius, style: .continuous))
                )
            RoundedRectangle(cornerRadius: MainHeaderToolSwitcherLayout.containerCornerRadius, style: .continuous)
                .fill(DesignTokens.titlebarSwitchSurface)
            RoundedRectangle(cornerRadius: MainHeaderToolSwitcherLayout.containerCornerRadius, style: .continuous)
                .strokeBorder(DesignTokens.titlebarSwitchHighlight, lineWidth: 0.7)
            RoundedRectangle(cornerRadius: MainHeaderToolSwitcherLayout.containerCornerRadius, style: .continuous)
                .strokeBorder(DesignTokens.titlebarSwitchBorder, lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.045), radius: 6, y: 2)
    }

    private func toolButton(_ tab: AppTab, iconOnly: Bool) -> some View {
        let isActive = state.activeTab == tab
        let hasUnread = tab == .alwaysOn && state.projects.contains { $0.hasUnreadSession }

        return Button {
            withAnimation(.snappy(duration: 0.22)) {
                state.activeTab = tab
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 13, weight: .regular))
                    .imageScale(.small)
                if !iconOnly {
                    Text(state.tabLabel(tab))
                        .font(.system(size: 12.5, weight: isActive ? .semibold : .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, iconOnly ? 0 : 6)
            .frame(
                width: MainHeaderToolSwitcherLayout.buttonWidth(for: tab, iconOnly: iconOnly),
                height: MainHeaderToolSwitcherLayout.buttonHeight
            )
            .foregroundStyle(isActive ? DesignTokens.text : DesignTokens.tertiaryText)
            .background(
                ZStack {
                    if isActive {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .fill(DesignTokens.titlebarSwitchActiveSurface)
                            .overlay(
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .strokeBorder(DesignTokens.titlebarSwitchActiveBorder, lineWidth: 0.8)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .strokeBorder(DesignTokens.titlebarSwitchHighlight, lineWidth: 0.6)
                            )
                            .shadow(color: .black.opacity(0.10), radius: 4, y: 1)
                            .matchedGeometryEffect(id: "tool-switcher-pill", in: toolSwitcherNamespace)
                    }
                }
            )
            .overlay(alignment: .topTrailing) {
                if hasUnread {
                    Circle()
                        .fill(DesignTokens.accent)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(DesignTokens.background, lineWidth: 2))
                        .offset(x: 4, y: -4)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(state.tabLabel(tab))
    }

    @ViewBuilder
    private var content: some View {
        switch state.activeTab {
        case .chat:
            ChatView()
        case .files:
            FilesView()
        case .skills:
            SkillsView()
        case .dashboard:
            DashboardView()
        case .memory:
            MemoryView()
        case .alwaysOn:
            AlwaysOnView()
        case .shell:
            ShellView()
        case .git:
            GitView()
        case .tasks:
            TasksView()
        case .preview:
            PreviewView()
        case .plugin(let name):
            PluginPlaceholderView(name: name)
        }
    }

    private func noticeBanner(_ message: String, tint: Color, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13))
            Text(message)
                .font(.system(size: 12))
                .lineLimit(2)
            Spacer()
            Button(state.t(.dismiss)) {
                state.errorBanner = nil
                state.warningBanner = nil
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(tint.opacity(0.10))
    }
}

struct MainHeaderToolSwitcherLayout: Equatable {
    static let itemSpacing: CGFloat = 2
    static let containerPadding: CGFloat = 3
    static let containerVerticalPadding: CGFloat = 2
    static let containerHeight = DesignTokens.titlebarControlSize
    static let containerCornerRadius = containerHeight / 2
    static let buttonHeight: CGFloat = 28
    private static let regularButtonWidth: CGFloat = 82
    private static let iconButtonWidth: CGFloat = 36

    var visibleTabs: [AppTab]
    var overflowTabs: [AppTab]
    var iconOnly: Bool
    var estimatedWidth: CGFloat

    static func resolve(
        availableWidth: CGFloat,
        activeTab: AppTab,
        tabs: [AppTab] = AppTab.primaryTabs
    ) -> MainHeaderToolSwitcherLayout {
        let allTabs = uniqueTabs(tabs)
        guard !allTabs.isEmpty else {
            return MainHeaderToolSwitcherLayout(visibleTabs: [], overflowTabs: [], iconOnly: false, estimatedWidth: 0)
        }

        let fullWidth = estimatedWidth(for: allTabs, overflow: [], iconOnly: false)
        let compactWidth = estimatedWidth(for: allTabs, overflow: [], iconOnly: true)
        let iconOnly = availableWidth < fullWidth + 160

        return MainHeaderToolSwitcherLayout(
            visibleTabs: allTabs,
            overflowTabs: [],
            iconOnly: iconOnly,
            estimatedWidth: iconOnly ? compactWidth : fullWidth
        )
    }

    static func buttonWidth(for tab: AppTab, iconOnly: Bool) -> CGFloat {
        if iconOnly {
            return iconButtonWidth
        }
        switch tab {
        case .alwaysOn:
            return 118
        default:
            return regularButtonWidth
        }
    }

    private static func estimatedWidth(for visible: [AppTab], overflow: [AppTab], iconOnly: Bool) -> CGFloat {
        let buttonWidth = visible.reduce(CGFloat(0)) { partial, tab in
            partial + Self.buttonWidth(for: tab, iconOnly: iconOnly)
        }
        let itemCount = visible.count + (overflow.isEmpty ? 0 : 1)
        let spacing = CGFloat(max(0, itemCount - 1)) * itemSpacing
        let overflowWidth: CGFloat = 0
        return containerPadding * 2 + buttonWidth + overflowWidth + spacing
    }

    private static func uniqueTabs(_ tabs: [AppTab]) -> [AppTab] {
        var seen = Set<AppTab>()
        return tabs.filter { tab in
            if seen.contains(tab) {
                return false
            }
            seen.insert(tab)
            return true
        }
    }
}

private struct MainHeaderIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(DesignTokens.mutedForeground)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                    .fill(configuration.isPressed ? DesignTokens.neutral100 : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous))
            .opacity(configuration.isPressed ? 0.76 : 1)
    }
}
