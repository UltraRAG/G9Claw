import SwiftUI

struct MainAreaView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(DesignTokens.background)
        .overlay(alignment: .top) {
            if let error = state.errorBanner {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error).lineLimit(2)
                    Spacer()
                    Button("Dismiss") {
                        state.errorBanner = nil
                    }
                }
                .font(.system(size: 12))
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(.red.opacity(0.14))
                .padding(.top, DesignTokens.headerHeight)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if !state.isSidebarVisible {
                Button {
                    state.isSidebarVisible = true
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(.plain)
                .help("Show sidebar")
            } else {
                Button {
                    state.isSidebarVisible = false
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(.plain)
                .help("Hide sidebar")
            }

            HStack(spacing: 7) {
                Text(state.selectedProject?.displayName ?? "Home")
                    .foregroundStyle(DesignTokens.secondaryText)
                Text("/")
                    .foregroundStyle(DesignTokens.tertiaryText)
                Text(state.activeTab.label)
                    .fontWeight(.medium)
                if let session = state.selectedSession {
                    Text(session.displayTitle)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DesignTokens.secondaryText)
                        .lineLimit(1)
                }
            }
            .font(.system(size: 13))

            Spacer(minLength: 12)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(AppTab.primaryTabs, id: \.id) { tab in
                        Button {
                            state.activeTab = tab
                        } label: {
                            Label(tab.label, systemImage: tab.systemImage)
                        }
                        .buttonStyle(NativePillButtonStyle(isActive: state.activeTab == tab))
                    }
                }
            }
            .frame(maxWidth: 620)
        }
        .padding(.horizontal, 18)
        .frame(height: DesignTokens.headerHeight)
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
}
