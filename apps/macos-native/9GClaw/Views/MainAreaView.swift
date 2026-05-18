import SwiftUI

struct MainAreaView: View {
    @EnvironmentObject private var state: AppState
    @Namespace private var toolSwitcherNamespace

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = state.errorBanner {
                errorBanner(error)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            let horizontalPadding: CGFloat = availableWidth < 760 ? 14 : 24
            let controlGap: CGFloat = availableWidth < 1080 ? 6 : 12
            let innerWidth = max(0, availableWidth - horizontalPadding * 2)
            let switcherLayout = MainHeaderToolSwitcherLayout.resolve(
                availableWidth: innerWidth,
                activeTab: state.activeTab
            )

            HStack(spacing: 0) {
                breadcrumb(showSessionTitle: showSessionTitle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(4)
                    .clipped()

                toolSwitcher(layout: switcherLayout)
                    .padding(.leading, controlGap)
                    .frame(width: switcherLayout.estimatedWidth, alignment: .trailing)
                    .layoutPriority(5)
            }
            .padding(.horizontal, horizontalPadding)
            .frame(width: proxy.size.width, height: DesignTokens.headerHeight)
        }
        .frame(height: DesignTokens.headerHeight)
        .background {
            MainGlassBackground()
        }
    }

    private func breadcrumb(showSessionTitle: Bool) -> some View {
        let workspaceTitle = state.selectedProject?.displayName ?? state.t(.general)

        return HStack(spacing: 8) {
            Text(workspaceTitle)
                .foregroundStyle(DesignTokens.neutral500)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(5)
            Text("/")
                .foregroundStyle(DesignTokens.neutral400.opacity(0.60))
            Text(state.tabLabel(state.activeTab))
                .fontWeight(.medium)
                .foregroundStyle(DesignTokens.text)
                .lineLimit(1)
                .layoutPriority(1)
            if showSessionTitle, let session = state.selectedSession {
                Text(session.displayTitle)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DesignTokens.neutral500)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 8)
                    .layoutPriority(0)
                }
        }
        .font(.system(size: 13))
        .frame(minWidth: 0, alignment: .leading)
    }

    @ViewBuilder
    private func toolSwitcher(layout: MainHeaderToolSwitcherLayout) -> some View {
        HStack(spacing: MainHeaderToolSwitcherLayout.itemSpacing) {
            ForEach(layout.visibleTabs, id: \.id) { tab in
                toolButton(tab, iconOnly: layout.iconOnly)
            }
        }
        .padding(3)
        .frame(width: layout.estimatedWidth, height: 34, alignment: .trailing)
        .background(
            GlassControlBackground(cornerRadius: 15, material: .popover, showsShadow: false)
        )
        .animation(.snappy(duration: 0.22), value: state.activeTab)
    }

    private func toolButton(_ tab: AppTab, iconOnly: Bool) -> some View {
        let isActive = state.activeTab == tab
        let hasUnread = tab == .alwaysOn && state.projects.flatMap(\.allSessions).contains { $0.state == .unread }

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
            .padding(.horizontal, iconOnly ? 0 : 8)
            .frame(
                width: MainHeaderToolSwitcherLayout.buttonWidth(for: tab, iconOnly: iconOnly),
                height: 28
            )
            .foregroundStyle(isActive ? DesignTokens.text : DesignTokens.tertiaryText)
            .background(
                ZStack {
                    if isActive {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(DesignTokens.contentSurface.opacity(0.88))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(DesignTokens.separator.opacity(0.55), lineWidth: 1)
                            )
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
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 13))
            Text(message)
                .font(.system(size: 12))
                .lineLimit(2)
            Spacer()
            Button(state.t(.dismiss)) {
                state.errorBanner = nil
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(DesignTokens.danger)
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(DesignTokens.danger.opacity(0.10))
    }
}

struct MainHeaderToolSwitcherLayout: Equatable {
    static let itemSpacing: CGFloat = 2
    static let containerHorizontalPadding: CGFloat = 6
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
        return MainHeaderToolSwitcherLayout(
            visibleTabs: allTabs,
            overflowTabs: [],
            iconOnly: false,
            estimatedWidth: fullWidth
        )
    }

    static func buttonWidth(for tab: AppTab, iconOnly: Bool) -> CGFloat {
        if iconOnly {
            return iconButtonWidth
        }
        switch tab {
        case .chat:
            return 92
        case .dashboard:
            return 92
        case .alwaysOn:
            return 106
        case .plugin:
            return 104
        default:
            return 84
        }
    }

    private static func estimatedWidth(for visible: [AppTab], overflow: [AppTab], iconOnly: Bool) -> CGFloat {
        let buttonWidth = visible.reduce(CGFloat(0)) { partial, tab in
            partial + Self.buttonWidth(for: tab, iconOnly: iconOnly)
        }
        let itemCount = visible.count + (overflow.isEmpty ? 0 : 1)
        let spacing = CGFloat(max(0, itemCount - 1)) * itemSpacing
        let overflowWidth: CGFloat = 0
        return containerHorizontalPadding + buttonWidth + overflowWidth + spacing
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
            .opacity(configuration.isPressed ? 0.76 : 1)
    }
}
