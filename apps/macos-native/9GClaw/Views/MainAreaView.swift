import SwiftUI

struct MainAreaView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = state.errorBanner {
                errorBanner(error)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DesignTokens.background)
        .foregroundStyle(DesignTokens.text)
    }

    private var header: some View {
        GeometryReader { proxy in
            let availableWidth = proxy.size.width
            let showSessionTitle = availableWidth >= 1160
            let horizontalPadding: CGFloat = availableWidth < 760 ? 14 : 24
            let controlGap: CGFloat = availableWidth < 1080 ? 8 : 16
            let toolMaxWidth = min(max(560, availableWidth * 0.70), availableWidth - 220)

            HStack(spacing: 0) {
                breadcrumb(showSessionTitle: showSessionTitle)
                    .frame(minWidth: min(240, max(150, availableWidth * 0.24)), maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(3)
                    .clipped()

                toolSwitcher()
                    .padding(.leading, controlGap)
                    .frame(width: max(320, toolMaxWidth), alignment: .trailing)
                    .layoutPriority(2)
            }
            .padding(.horizontal, horizontalPadding)
            .frame(width: proxy.size.width, height: DesignTokens.headerHeight)
        }
        .frame(height: DesignTokens.headerHeight)
        .background(DesignTokens.background)
    }

    private func breadcrumb(showSessionTitle: Bool) -> some View {
        HStack(spacing: 8) {
            Text(state.selectedProject?.displayName ?? "Home")
                .foregroundStyle(DesignTokens.neutral500)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(3)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 80, alignment: .leading)
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
    private func toolSwitcher() -> some View {
        GeometryReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(AppTab.primaryTabs, id: \.id) { tab in
                        toolButton(tab)
                    }
                }
                .frame(minWidth: proxy.size.width, alignment: .trailing)
            }
            .frame(width: proxy.size.width, height: 36, alignment: .trailing)
        }
        .frame(height: 36)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func toolButton(_ tab: AppTab) -> some View {
        let isActive = state.activeTab == tab
        let hasUnread = tab == .alwaysOn && state.projects.flatMap(\.allSessions).contains { $0.state == .unread }

        return Button {
            state.activeTab = tab
        } label: {
            HStack(spacing: 6) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 14, weight: .regular))
                    .imageScale(.small)
                Text(state.tabLabel(tab))
                    .font(.system(size: 13, weight: isActive ? .medium : .regular))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .foregroundStyle(isActive ? DesignTokens.text : DesignTokens.tertiaryText)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                    .fill(isActive ? DesignTokens.neutral100 : Color.clear)
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
        }
        .fixedSize(horizontal: true, vertical: false)
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
