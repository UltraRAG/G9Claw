import AppKit
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var state: AppState
    @Binding var width: Double
    @AppStorage("sidebar-v2-active-section") private var activeSectionRaw = SidebarSection.projects.rawValue
    @State private var expandedProjectIDs: Set<UUID> = []
    @State private var collapsedSessionProjectIDs: Set<UUID> = []
    @State private var isResizing = false
    @State private var resizeStartWidth = Double(DesignTokens.sidebarDefaultWidth)

    private var activeSection: SidebarSection {
        get { SidebarSection(rawValue: activeSectionRaw) ?? .projects }
        nonmutating set { activeSectionRaw = newValue.rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            sectionToggle
            listBody
            footer
        }
        .background(DesignTokens.sidebarBackground)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(DesignTokens.separator)
                .frame(width: 1)
        }
        .overlay(alignment: .trailing) {
            resizeHandle
        }
        .onAppear {
            syncSectionWithSelection()
            if let selectedProjectID = state.selectedProjectID {
                expandedProjectIDs.insert(selectedProjectID)
            }
        }
        .onChange(of: state.selectedProjectID) { _, _ in
            syncSectionWithSelection()
            if let selectedProjectID = state.selectedProjectID {
                expandedProjectIDs.insert(selectedProjectID)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Button {
                if let generalProject {
                    state.selectProject(generalProject)
                    activeSection = .general
                }
            } label: {
                LogoImage()
                    .frame(width: 184, height: 56, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("9GClaw")

            Button {
                state.isSidebarVisible = false
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(WebIconButtonStyle())
            .help("Hide sidebar")
        }
        .padding(.leading, 4)
        .padding(.trailing, 16)
        .frame(height: DesignTokens.sidebarHeaderHeight)
    }

    private var sectionToggle: some View {
        HStack(spacing: 2) {
            segmentButton(.projects)
            segmentButton(.general)
        }
        .padding(2)
        .frame(height: DesignTokens.sidebarSegmentHeight)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                .fill(DesignTokens.neutral100)
        )
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private func segmentButton(_ section: SidebarSection) -> some View {
        Button {
            activeSection = section
            if section == .general, let generalProject {
                state.selectProject(generalProject)
            }
        } label: {
            Text(section.title)
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .foregroundStyle(activeSection == section ? DesignTokens.text : DesignTokens.tertiaryText)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(activeSection == section ? DesignTokens.background : Color.clear)
                        .shadow(
                            color: activeSection == section ? .black.opacity(0.08) : .clear,
                            radius: 2,
                            y: 1
                        )
                )
        }
        .buttonStyle(.plain)
    }

    private var listBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if activeSection == .projects {
                    projectsSection
                } else {
                    generalSection
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .scrollIndicators(.automatic)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionHeader(
                title: "Projects",
                leftActionIcon: areAllProjectsExpanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical",
                leftAction: toggleAllProjects,
                rightActionIcon: "plus",
                rightAction: {
                    state.showProjectCreationWizard = true
                }
            )

            if otherProjects.isEmpty {
                Text("No projects found")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.tertiaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            } else {
                ForEach(otherProjects) { project in
                    projectGroup(project)
                }
            }
        }
        .padding(.top, 8)
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionHeader(
                title: "General",
                rightActionIcon: "square.and.pencil",
                rightAction: {
                    if let generalProject {
                        expandedProjectIDs.insert(generalProject.id)
                        state.selectProject(generalProject)
                    }
                    state.startNewSession()
                }
            )

            if let generalProject {
                sessionRows(for: generalProject, flat: true)
                    .padding(.horizontal, 4)
            } else {
                Text("No general workspace found")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.tertiaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }
        }
        .padding(.top, 8)
    }

    private func sectionHeader(
        title: String,
        leftActionIcon: String? = nil,
        leftAction: (() -> Void)? = nil,
        rightActionIcon: String? = nil,
        rightAction: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .medium))
                .tracking(0.44)
                .foregroundStyle(DesignTokens.tertiaryText.opacity(0.90))
                .frame(maxWidth: .infinity, alignment: .leading)

            if let leftActionIcon, let leftAction {
                headerIconButton(systemName: leftActionIcon, action: leftAction)
            }

            if let rightActionIcon, let rightAction {
                headerIconButton(systemName: rightActionIcon, action: rightAction)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 2)
        .padding(.bottom, 4)
    }

    private func headerIconButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13.5, weight: .regular))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(WebIconButtonStyle())
    }

    private func projectGroup(_ project: WorkspaceProject) -> some View {
        let isExpanded = expandedProjectIDs.contains(project.id)
        let isSelected = state.selectedProjectID == project.id

        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                Button {
                    toggleProject(project)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .foregroundStyle(DesignTokens.tertiaryText)
                            .frame(width: 14, height: 14)
                        Image(systemName: "folder")
                            .font(.system(size: 13.5, weight: .regular))
                            .foregroundStyle(isSelected ? DesignTokens.text : DesignTokens.tertiaryText)
                            .frame(width: 14, height: 14)
                        Text(project.displayName)
                            .font(.system(size: 13))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                    }
                    .foregroundStyle(isSelected ? DesignTokens.text : DesignTokens.secondaryText)
                    .padding(.leading, 6)
                    .padding(.trailing, 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    expandedProjectIDs.insert(project.id)
                    state.startDraftSession(project: project)
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 13))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(WebIconButtonStyle())
                .opacity(isSelected ? 1 : 0.55)
            }
            .frame(height: DesignTokens.sidebarProjectRowHeight)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous)
                    .fill(isSelected ? DesignTokens.selectedRowFill() : Color.clear)
            )

            if isExpanded {
                sessionRows(for: project, flat: false)
            }
        }
        .contextMenu {
            Button("Rename") {
                state.errorBanner = "Project rename is not implemented in this UI parity pass."
            }
            Button("Delete", role: .destructive) {
                state.errorBanner = "Project delete is not implemented in this UI parity pass."
            }
        }
    }

    private func sessionRows(for project: WorkspaceProject, flat: Bool) -> some View {
        let allSessions = project.allSessions
        let isCollapsed = collapsedSessionProjectIDs.contains(project.id)
        let visibleSessions = isCollapsed ? Array(allSessions.prefix(5)) : allSessions
        let showDraftSession = state.selectedProjectID == project.id && state.activeTab == .chat && state.selectedSessionID == nil

        return VStack(alignment: .leading, spacing: 2) {
            if showDraftSession {
                Button {
                    state.startNewSession()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("New Session")
                            .font(.system(size: 12.5))
                            .foregroundStyle(DesignTokens.text)
                            .lineLimit(1)
                        Text("Not saved yet")
                            .font(.system(size: 11))
                            .foregroundStyle(DesignTokens.tertiaryText)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                            .fill(DesignTokens.selectedRowFill())
                    )
                }
                .buttonStyle(.plain)
            }

            if visibleSessions.isEmpty {
                Text("No sessions yet")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.tertiaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            } else {
                ForEach(visibleSessions) { session in
                    sessionRow(project: project, session: session)
                }
            }

            if allSessions.count > 5 {
                Button {
                    if isCollapsed {
                        collapsedSessionProjectIDs.remove(project.id)
                    } else {
                        collapsedSessionProjectIDs.insert(project.id)
                    }
                } label: {
                    Text(isCollapsed ? "Show more (\(allSessions.count - 5))" : "Show less")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignTokens.tertiaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, flat ? 0 : 24)
    }

    private func sessionRow(project: WorkspaceProject, session: ProjectSession) -> some View {
        let isSelected = state.selectedProjectID == project.id && state.selectedSessionID == session.id && state.activeTab == .chat

        return Button {
            state.selectProject(project)
            state.selectSession(session)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                SessionDot(state: session.state)
                    .frame(width: 12, height: 18)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 1) {
                    Text(session.displayTitle)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                        .foregroundStyle(DesignTokens.text)
                    Text(relativeDate(session.activityDate))
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .foregroundStyle(DesignTokens.tertiaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                    .fill(isSelected ? DesignTokens.selectedRowFill() : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename") {
                state.errorBanner = "Session rename is not implemented in this UI parity pass."
            }
            Button("Delete", role: .destructive) {
                state.errorBanner = "Session delete is not implemented in this UI parity pass."
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(DesignTokens.separator)
                .frame(height: 1)
            Button {
                state.openSettings(.appearance)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16, weight: .regular))
                    Text("Settings")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(DesignTokens.secondaryText)
                .padding(.horizontal, 24)
                .frame(height: 36)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous)
                        .fill(Color.clear)
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .frame(height: DesignTokens.sidebarFooterHeight)
    }

    private var resizeHandle: some View {
        Rectangle()
            .fill(isResizing ? DesignTokens.accent.opacity(0.60) : Color.clear)
            .frame(width: 5)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isResizing {
                            isResizing = true
                            resizeStartWidth = width
                        }
                        width = clamp(
                            resizeStartWidth + value.translation.width,
                            min: Double(DesignTokens.sidebarMinWidth),
                            max: Double(DesignTokens.sidebarMaxWidth)
                        )
                    }
                    .onEnded { _ in
                        isResizing = false
                    }
            )
            .onTapGesture(count: 2) {
                width = Double(DesignTokens.sidebarDefaultWidth)
            }
    }

    private var generalProject: WorkspaceProject? {
        state.projects.first { $0.name == "general" || $0.displayName == "general" }
    }

    private var otherProjects: [WorkspaceProject] {
        WorkspaceService.sortedProjects(state.projects, order: state.settings.projectSortOrder)
            .filter { project in
                guard let generalProject else { return true }
                return project.id != generalProject.id
            }
    }

    private var areAllProjectsExpanded: Bool {
        !otherProjects.isEmpty && otherProjects.allSatisfy { expandedProjectIDs.contains($0.id) }
    }

    private func toggleProject(_ project: WorkspaceProject) {
        if expandedProjectIDs.contains(project.id) {
            expandedProjectIDs.remove(project.id)
        } else {
            expandedProjectIDs.insert(project.id)
        }
        state.selectProject(project)
    }

    private func toggleAllProjects() {
        if areAllProjectsExpanded {
            otherProjects.forEach { expandedProjectIDs.remove($0.id) }
        } else {
            otherProjects.forEach { expandedProjectIDs.insert($0.id) }
        }
    }

    private func syncSectionWithSelection() {
        guard let selectedProject = state.selectedProject else { return }
        if let generalProject, selectedProject.id == generalProject.id {
            activeSection = .general
        } else {
            activeSection = .projects
        }
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func clamp(_ value: Double, min: Double, max: Double) -> Double {
        Swift.min(max, Swift.max(min, value))
    }
}

struct ProjectCreationWizardView: View {
    @EnvironmentObject private var state: AppState
    var onClose: () -> Void

    @State private var step = 0
    @State private var workspaceType: WorkspaceCreationType = .existing
    @State private var displayName = ""
    @State private var workspacePath = ""
    @State private var githubURL = ""
    @State private var isCreating = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.50)
                .ignoresSafeArea()
                .background(.ultraThinMaterial)

            VStack(spacing: 0) {
                wizardHeader
                progress
                Divider().background(DesignTokens.separator)
                content
                    .frame(minHeight: 300)
                    .padding(24)
                Divider().background(DesignTokens.separator)
                footer
            }
            .frame(maxWidth: 672)
            .background(DesignTokens.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(DesignTokens.separator, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 28, y: 14)
            .padding(24)
            .onAppear {
                if workspacePath.isEmpty {
                    workspacePath = state.settings.workspacesRoot
                }
            }
        }
    }

    private var wizardHeader: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(DesignTokens.accent.opacity(0.12))
                .frame(width: 38, height: 38)
                .overlay {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(DesignTokens.accent)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text("Create Project")
                    .font(.system(size: 18, weight: .semibold))
                Text("Add an existing workspace or create a new folder.")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignTokens.tertiaryText)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(WebIconButtonStyle())
        }
        .padding(.horizontal, 20)
        .frame(height: 64)
    }

    private var progress: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(index <= step ? DesignTokens.accent : DesignTokens.neutral200)
                    .frame(height: 4)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0:
            VStack(alignment: .leading, spacing: 14) {
                Text("Choose workspace type")
                    .font(.system(size: 15, weight: .semibold))
                HStack(spacing: 12) {
                    typeCard(.existing, title: "Open Existing", detail: "Register an existing local project folder.", icon: "folder")
                    typeCard(.new, title: "Create New", detail: "Create a new folder, optionally from Git.", icon: "plus.square")
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        case 1:
            VStack(alignment: .leading, spacing: 14) {
                Text("Configure workspace")
                    .font(.system(size: 15, weight: .semibold))
                SettingsTextField("Display Name", text: $displayName)
                HStack(alignment: .bottom, spacing: 8) {
                    SettingsTextField("Workspace Path", text: $workspacePath)
                    Button("Browse") { browseFolder() }
                        .buttonStyle(WebToolbarButtonStyle())
                }
                if workspaceType == .new {
                    SettingsTextField("GitHub URL (optional)", text: $githubURL)
                    Text("If a Git URL is provided, 9GClaw creates the target folder first and clones into it.")
                        .font(.system(size: 12))
                        .foregroundStyle(DesignTokens.tertiaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        default:
            VStack(alignment: .leading, spacing: 16) {
                Text("Review")
                    .font(.system(size: 15, weight: .semibold))
                SettingsCardBlock(divided: true) {
                    reviewRow("Type", workspaceType == .existing ? "Existing workspace" : "New workspace")
                    reviewRow("Name", finalDisplayName)
                    reviewRow("Path", expandedPath)
                    if workspaceType == .new && !githubURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        reviewRow("Git", githubURL)
                    }
                }
                if isCreating {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.72)
                        Text("Creating project...")
                            .font(.system(size: 12))
                            .foregroundStyle(DesignTokens.tertiaryText)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var footer: some View {
        HStack {
            Button("Back") {
                step = max(0, step - 1)
            }
            .buttonStyle(WebToolbarButtonStyle())
            .disabled(step == 0 || isCreating)

            Spacer()

            Button("Cancel", action: onClose)
                .buttonStyle(WebToolbarButtonStyle())
                .disabled(isCreating)

            Button(step == 2 ? "Create Project" : "Continue") {
                if step < 2 {
                    step += 1
                } else {
                    createProject()
                }
            }
            .buttonStyle(WebToolbarButtonStyle(isProminent: true))
            .disabled(!canContinue || isCreating)
        }
        .padding(.horizontal, 20)
        .frame(height: 58)
    }

    private func typeCard(_ type: WorkspaceCreationType, title: String, detail: String, icon: String) -> some View {
        Button {
            workspaceType = type
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(workspaceType == type ? DesignTokens.accent : DesignTokens.tertiaryText)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignTokens.text)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(DesignTokens.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(workspaceType == type ? DesignTokens.accent.opacity(0.08) : DesignTokens.background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(workspaceType == type ? DesignTokens.accent : DesignTokens.separator, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func reviewRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(DesignTokens.tertiaryText)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.system(size: 12, design: label == "Path" ? .monospaced : .default))
                .foregroundStyle(DesignTokens.text)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var canContinue: Bool {
        if step == 1 || step == 2 {
            return !workspacePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    private var expandedPath: String {
        NSString(string: workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)).expandingTildeInPath
    }

    private var finalDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let name = URL(fileURLWithPath: expandedPath).lastPathComponent
        return name.isEmpty ? "Untitled Project" : name
    }

    private func browseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: state.settings.workspacesRoot)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        workspacePath = url.path
        if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            displayName = url.lastPathComponent
        }
    }

    private func createProject() {
        isCreating = true
        let name = finalDisplayName
        let path = expandedPath
        let git = githubURL.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            await state.createProjectFromWizard(
                displayName: name,
                path: path,
                createDirectory: workspaceType == .new,
                githubURL: git.isEmpty ? nil : git
            )
            isCreating = false
        }
    }
}

private enum WorkspaceCreationType {
    case existing
    case new
}

private enum SidebarSection: String {
    case projects
    case general

    var title: String {
        switch self {
        case .projects: "Projects"
        case .general: "General"
        }
    }
}

private struct WebIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(DesignTokens.tertiaryText)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                    .fill(configuration.isPressed ? DesignTokens.neutral200 : Color.clear)
            )
            .opacity(configuration.isPressed ? 0.76 : 1)
    }
}

private struct LogoImage: View {
    var body: some View {
        if let image = Self.image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
        } else {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(DesignTokens.text)
                    .frame(width: 26, height: 26)
                    .overlay {
                        Text("9")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(DesignTokens.background)
                    }
                Text("9GClaw")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(DesignTokens.text)
            }
        }
    }

    private static var image: NSImage? {
        if let url = Bundle.main.url(forResource: "9gclaw-logo", withExtension: "png") {
            return NSImage(contentsOf: url)
        }
        return NSImage(named: "9gclaw-logo")
    }
}

private struct SessionDot: View {
    var state: SessionState

    var body: some View {
        Group {
            if state == .processing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.46)
                    .frame(width: 12, height: 12)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
            }
        }
    }

    private var color: Color {
        switch state {
        case .idle: DesignTokens.neutral300
        case .processing: DesignTokens.tertiaryText
        case .unread: DesignTokens.accent
        case .failed: DesignTokens.danger
        }
    }
}
