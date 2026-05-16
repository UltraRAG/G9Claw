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
            let switcherMaxWidth = min(620, max(280, proxy.size.width * 0.70))

            HStack(spacing: 0) {
                if !state.isSidebarVisible {
                    Button {
                        state.isSidebarVisible = true
                    } label: {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 16))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(MainHeaderIconButtonStyle())
                    .padding(.trailing, 16)
                    .help("Show sidebar")
                }

                breadcrumb
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

                toolSwitcher(maxWidth: switcherMaxWidth)
                    .padding(.leading, 16)
            }
            .padding(.horizontal, 24)
            .frame(width: proxy.size.width, height: DesignTokens.headerHeight)
        }
        .frame(height: DesignTokens.headerHeight)
        .background(DesignTokens.background)
    }

    private var breadcrumb: some View {
        HStack(spacing: 8) {
            Text(state.selectedProject?.displayName ?? "Home")
                .foregroundStyle(DesignTokens.tertiaryText)
                .lineLimit(1)
            Text("/")
                .foregroundStyle(DesignTokens.neutral400.opacity(0.60))
            Text(state.activeTab.label)
                .fontWeight(.medium)
                .foregroundStyle(DesignTokens.text)
            if let session = state.selectedSession {
                Text(session.displayTitle)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DesignTokens.tertiaryText)
                    .lineLimit(1)
                    .padding(.leading, 8)
            }
        }
        .font(.system(size: 13))
        .frame(minWidth: 0, alignment: .leading)
    }

    private func toolSwitcher(maxWidth: CGFloat) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(AppTab.primaryTabs, id: \.id) { tab in
                    toolButton(tab)
                }
            }
        }
        .frame(height: 36)
        .frame(maxWidth: maxWidth)
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
                    .frame(width: 14, height: 14)
                Text(tab.label)
                    .font(.system(size: 13, weight: isActive ? .medium : .regular))
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
                        .offset(x: -4, y: 4)
                }
            }
        }
        .buttonStyle(.plain)
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
            Button("Dismiss") {
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
            .foregroundStyle(DesignTokens.tertiaryText)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                    .fill(configuration.isPressed ? DesignTokens.neutral100 : Color.clear)
            )
            .opacity(configuration.isPressed ? 0.76 : 1)
    }
}
