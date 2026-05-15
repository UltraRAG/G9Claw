import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var state: AppState
    @State private var activeSection: SidebarSection = .projects
    @State private var newProjectName = ""
    @State private var newProjectPath = FileManager.default.homeDirectoryForCurrentUser.path

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("", selection: $activeSection) {
                Text("Projects").tag(SidebarSection.projects)
                Text("General").tag(SidebarSection.general)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            Divider()

            if activeSection == .projects {
                projectList
            } else {
                generalTools
            }

            Divider()
            footer
        }
        .background {
            VisualEffectBackground(material: .sidebar)
                .ignoresSafeArea()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.primary)
                .frame(width: 26, height: 26)
                .overlay(Text("9").foregroundStyle(.background).font(.system(size: 15, weight: .bold)))
            Text("9GClaw")
                .font(.system(size: 18, weight: .semibold))
            Spacer()
            Button {
                state.startNewSession()
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.plain)
            .help("New session")
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
    }

    private var projectList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                if state.projects.isEmpty {
                    ContentUnavailableView("No projects", systemImage: "folder.badge.plus", description: Text("Create or select a workspace to begin."))
                        .padding(.top, 40)
                }
                ForEach(WorkspaceService.sortedProjects(state.projects, order: state.settings.projectSortOrder)) { project in
                    projectSection(project)
                }
            }
            .padding(10)
        }
    }

    private func projectSection(_ project: WorkspaceProject) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                state.selectProject(project)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DesignTokens.tertiaryText)
                    Image(systemName: "folder")
                        .foregroundStyle(DesignTokens.secondaryText)
                    Text(project.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    Text(relativeDate(project.latestActivity))
                        .font(.system(size: 11))
                        .foregroundStyle(DesignTokens.tertiaryText)
                }
            }
            .buttonStyle(SidebarRowStyle(isActive: state.selectedProjectID == project.id && state.selectedSessionID == nil))

            ForEach(project.allSessions) { session in
                Button {
                    state.selectProject(project)
                    state.selectSession(session)
                } label: {
                    HStack(spacing: 8) {
                        SessionDot(state: session.state)
                        Text(session.displayTitle)
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Spacer()
                        Text(session.provider.displayName)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(DesignTokens.tertiaryText)
                    }
                    .padding(.leading, 24)
                }
                .buttonStyle(SidebarRowStyle(isActive: state.selectedSessionID == session.id))
            }
        }
    }

    private var generalTools: some View {
        List {
            Section("Global Tools") {
                ForEach([AppTab.memory, .alwaysOn, .tasks, .dashboard], id: \.id) { tab in
                    Button {
                        state.activeTab = tab
                    } label: {
                        Label(tab.label, systemImage: tab.systemImage)
                    }
                }
            }
            Section("Parity Sources") {
                ForEach(ParityCatalog.modules) { source in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.swiftModule).font(.system(size: 12, weight: .semibold))
                        Text(source.legacySources.first ?? "")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(DesignTokens.secondaryText)
                            .lineLimit(1)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            HStack {
                Text(state.statusLine)
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.secondaryText)
                    .lineLimit(1)
                Spacer()
                Button {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .help("Settings")
            }

            DisclosureGroup("Create project") {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Name", text: $newProjectName)
                    TextField("Path", text: $newProjectPath)
                    Button("Create") {
                        let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
                        state.createProject(name: name.isEmpty ? "Untitled" : name, path: newProjectPath)
                    }
                }
                .font(.system(size: 12))
            }
            .font(.system(size: 12))
        }
        .padding(12)
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private enum SidebarSection {
    case projects
    case general
}

private struct SessionDot: View {
    var state: SessionState

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: state == .processing ? 8 : 6, height: state == .processing ? 8 : 6)
            .overlay {
                if state == .processing {
                    Circle().stroke(color.opacity(0.3), lineWidth: 3)
                }
            }
    }

    private var color: Color {
        switch state {
        case .idle: DesignTokens.tertiaryText
        case .processing: .blue
        case .unread: .blue
        case .failed: .red
        }
    }
}
