import AppKit
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openSettings) private var openSettings
    @Binding var width: Double
    @AppStorage("sidebar-v2-active-section") private var activeSectionRaw = SidebarSection.projects.rawValue
    @State private var expandedProjectIDs: Set<UUID> = []
    @State private var collapsedSessionProjectIDs: Set<UUID> = []
    @State private var isResizing = false
    @State private var resizeStartWidth = Double(DesignTokens.sidebarDefaultWidth)
    @Namespace private var sectionToggleGlassNamespace

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
        .background {
            SidebarGlassBackground()
        }
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
                    .frame(height: 56, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("9GClaw")

            Button {
                withAnimation(.snappy(duration: 0.28, extraBounce: 0.02)) {
                    state.isSidebarVisible = false
                }
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(WebIconButtonStyle())
            .help(state.t(.hideSidebar))
        }
        .padding(.leading, 8)
        .padding(.trailing, 16)
        .padding(.top, 30)
        .frame(height: DesignTokens.sidebarHeaderHeight + 30)
    }

    private var sectionToggle: some View {
        HStack(spacing: 2) {
            segmentButton(.projects)
            segmentButton(.general)
        }
        .padding(3)
        .frame(height: DesignTokens.sidebarSegmentHeight + 4)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(DesignTokens.background.opacity(0.18))
                    .background(
                        VisualEffectBackground(material: .hudWindow, blendingMode: .withinWindow)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    )
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(0.34), lineWidth: 0.7)
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(DesignTokens.separator.opacity(0.55), lineWidth: 0.7)
                LinearGradient(
                    colors: [.white.opacity(0.30), .white.opacity(0.03), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .allowsHitTesting(false)
            }
        )
        .shadow(color: .black.opacity(0.06), radius: 7, y: 3)
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .animation(.spring(response: 0.26, dampingFraction: 0.82), value: activeSection)
    }

    private func segmentButton(_ section: SidebarSection) -> some View {
        Button {
            activeSection = section
            if section == .general, let generalProject {
                state.selectProject(generalProject)
            }
        } label: {
            ZStack {
                if activeSection == section {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(DesignTokens.background.opacity(0.58))
                        .background(
                            VisualEffectBackground(material: .popover, blendingMode: .withinWindow)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(.white.opacity(0.58), lineWidth: 0.7)
                        )
                        .shadow(color: .black.opacity(0.10), radius: 4, y: 2)
                        .matchedGeometryEffect(id: "active-sidebar-section", in: sectionToggleGlassNamespace)
                }

                Text(sectionTitle(section))
                    .font(.system(size: 12, weight: activeSection == section ? .semibold : .medium))
                    .foregroundStyle(activeSection == section ? DesignTokens.text : DesignTokens.secondaryText.opacity(0.72))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                title: state.t(.projects),
                leftActionIcon: areAllProjectsExpanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical",
                leftAction: toggleAllProjects,
                rightActionIcon: "plus",
                rightAction: {
                    state.showProjectCreationWizard = true
                }
            )

            if otherProjects.isEmpty {
                Text(state.t(.noProjectsFound))
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
                title: state.t(.general),
                leftActionIcon: isGeneralExpanded ? "rectangle.compress.vertical" : "rectangle.expand.vertical",
                leftAction: toggleGeneralExpanded,
                rightActionIcon: "plus",
                rightAction: {
                    if let generalProject {
                        expandedProjectIDs.insert(generalProject.id)
                        state.selectProject(generalProject)
                    }
                    state.startNewSession()
                }
            )

            if let generalProject {
                projectGroup(generalProject)
            } else {
                Text(state.t(.noGeneralWorkspaceFound))
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
                .tracking(11 * 0.04)
                .foregroundStyle(DesignTokens.neutral500.opacity(0.90))
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
            Button(state.t(.rename)) {
                if let nextName = promptText(title: state.t(.rename), initialValue: project.displayName) {
                    state.renameProject(project, displayName: nextName)
                }
            }
            Button(state.t(.delete), role: .destructive) {
                if confirmDelete(name: project.displayName) {
                    state.deleteProject(project)
                }
            }
        }
    }

    private func sessionRows(for project: WorkspaceProject, flat: Bool) -> some View {
        let allSessions = project.allSessions
        let isCollapsed = collapsedSessionProjectIDs.contains(project.id)
        let visibleSessions = isCollapsed ? Array(allSessions.prefix(5)) : allSessions
        let showDraftSession = state.isDraftSessionVisible && state.selectedProjectID == project.id && state.activeTab == .chat && state.selectedSessionID == nil

        return VStack(alignment: .leading, spacing: 2) {
            if showDraftSession {
                Button {
                    state.startNewSession()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.t(.newSession))
                            .font(.system(size: 12.5))
                            .foregroundStyle(DesignTokens.text)
                            .lineLimit(1)
                        Text(state.t(.notSavedYet))
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
                Text(state.t(.noSessionsYet))
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
                    Text(isCollapsed ? state.t(.showMoreFormat, allSessions.count - 5) : state.t(.showLess))
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
            Button(state.t(.rename)) {
                if let nextTitle = promptText(title: state.t(.rename), initialValue: session.displayTitle) {
                    state.renameSession(session, in: project, title: nextTitle)
                }
            }
            Button(state.t(.delete), role: .destructive) {
                if confirmDelete(name: session.displayTitle) {
                    state.deleteSession(session, in: project)
                }
            }
        }
    }

    private func promptText(title: String, initialValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = initialValue
        alert.accessoryView = field
        alert.addButton(withTitle: title)
        alert.addButton(withTitle: state.t(.cancel))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func confirmDelete(name: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "\(state.t(.delete)) \(name)?"
        alert.informativeText = state.t(.cannotBeUndone)
        alert.alertStyle = .warning
        alert.addButton(withTitle: state.t(.delete))
        alert.addButton(withTitle: state.t(.cancel))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(DesignTokens.separator)
                .frame(height: 1)
            Button {
                state.openSettings(.appearance)
                openSettings()
                SettingsWindowPresenter.bringToFront()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16, weight: .regular))
                    Text(state.t(.settings))
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(DesignTokens.secondaryText)
                .padding(.horizontal, 24)
                .frame(height: 36)
                .contentShape(RoundedRectangle(cornerRadius: DesignTokens.radius))
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

    private var isGeneralExpanded: Bool {
        guard let generalProject else { return false }
        return expandedProjectIDs.contains(generalProject.id)
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

    private func toggleGeneralExpanded() {
        guard let generalProject else { return }
        if expandedProjectIDs.contains(generalProject.id) {
            expandedProjectIDs.remove(generalProject.id)
        } else {
            expandedProjectIDs.insert(generalProject.id)
            state.selectProject(generalProject)
        }
    }

    private func sectionTitle(_ section: SidebarSection) -> String {
        switch section {
        case .projects:
            return state.t(.projects)
        case .general:
            return state.t(.general)
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

struct CollapsedSidebarRail: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    withAnimation(.snappy(duration: 0.28, extraBounce: 0.02)) {
                        state.isSidebarVisible = true
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 16, weight: .regular))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(WebIconButtonStyle())
                .help(state.t(.showSidebar))
            }
            .padding(.trailing, 10)
            .padding(.top, 30)
            .frame(height: DesignTokens.sidebarHeaderHeight + 30)

            Spacer(minLength: 0)
        }
        .background {
            SidebarGlassBackground()
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(DesignTokens.separator)
                .frame(width: 1)
        }
    }
}

struct ProjectCreationWizardMetrics {
    static let maxWidth: CGFloat = 612
    static let formMaxWidth: CGFloat = 520
    static let headerHeight: CGFloat = 58
    static let contentMinHeight: CGFloat = 268
    static let contentPadding: CGFloat = 24
    static let footerHeight: CGFloat = 54
    static let fieldHeight: CGFloat = 36
    static let browseButtonWidth: CGFloat = 44
    static let typeCardMinHeight: CGFloat = 104
}

struct ProjectCreationWizardView: View {
    @EnvironmentObject private var state: AppState
    var onClose: () -> Void

    @State private var step = 0
    @State private var workspaceType: WorkspaceCreationType = .existing
    @State private var hoveredWorkspaceType: WorkspaceCreationType?
    @State private var displayName = ""
    @State private var workspacePath = ""
    @State private var githubURL = ""
    @State private var isCreating = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.36)
                .ignoresSafeArea()
                .background(.ultraThinMaterial)

            VStack(spacing: 0) {
                wizardHeader
                progress
                Divider().background(DesignTokens.separator)
                content
                    .frame(minHeight: ProjectCreationWizardMetrics.contentMinHeight, alignment: .top)
                    .padding(ProjectCreationWizardMetrics.contentPadding)
                Divider().background(DesignTokens.separator)
                footer
            }
            .frame(maxWidth: ProjectCreationWizardMetrics.maxWidth)
            .background(DesignTokens.modalSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(DesignTokens.separator, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.22), radius: 34, y: 18)
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
                .fill(DesignTokens.accent.opacity(0.10))
                .frame(width: 32, height: 32)
                .overlay {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DesignTokens.accent)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(state.t(.createProject))
                    .font(.system(size: 16, weight: .semibold))
                Text(state.t(.createProjectSubtitle))
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
        .padding(.horizontal, 24)
        .frame(height: ProjectCreationWizardMetrics.headerHeight)
    }

    private var progress: some View {
        HStack(spacing: 0) {
            ForEach(Array(stepItems.enumerated()), id: \.offset) { index, label in
                HStack(spacing: 7) {
                    stepBadge(index)
                    Text(label)
                        .font(.system(size: 11.5, weight: index == step ? .medium : .regular))
                        .foregroundStyle(index <= step ? DesignTokens.text : DesignTokens.tertiaryText)
                        .lineLimit(1)
                }
                if index < stepItems.count - 1 {
                    Capsule()
                        .fill(index < step ? DesignTokens.accent.opacity(0.42) : DesignTokens.neutral200.opacity(0.88))
                        .frame(width: 56, height: 1.5)
                        .padding(.horizontal, 12)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stepItems: [String] {
        [state.t(.type), state.t(.configureWorkspace), state.t(.review)]
    }

    @ViewBuilder
    private func stepBadge(_ index: Int) -> some View {
        let completed = index < step
        ZStack {
            Circle()
                .fill(index <= step ? DesignTokens.accent.opacity(completed ? 0.88 : 1) : DesignTokens.neutral100.opacity(0.78))
                .frame(width: 20, height: 20)
                .overlay(
                    Circle()
                        .stroke(index <= step ? DesignTokens.accent.opacity(0.72) : DesignTokens.separator, lineWidth: 1)
                )
            if completed {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.white)
            } else {
                Text("\(index + 1)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(index <= step ? Color.white : DesignTokens.tertiaryText)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0:
            VStack(alignment: .leading, spacing: 12) {
                Text(state.t(.chooseWorkspaceType))
                    .font(.system(size: 15, weight: .semibold))
                HStack(spacing: 12) {
                    typeCard(.existing, title: state.t(.openExisting), detail: state.t(.openExistingDetail), icon: "folder")
                    typeCard(.new, title: state.t(.createNew), detail: state.t(.createNewDetail), icon: "plus.square")
                }
            }
            .frame(maxWidth: ProjectCreationWizardMetrics.formMaxWidth, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        case 1:
            VStack(alignment: .leading, spacing: 12) {
                Text(state.t(.configureWorkspace))
                    .font(.system(size: 15, weight: .semibold))
                wizardTextField(state.t(.displayName), text: $displayName)
                VStack(alignment: .leading, spacing: 5) {
                    Text(state.t(.workspacePath))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DesignTokens.tertiaryText)
                    HStack(spacing: 8) {
                        WizardPlainTextField(
                            placeholder: state.t(.workspacePath),
                            text: $workspacePath,
                            monospaced: true
                        )
                        .layoutPriority(1)
                        Button { browseFolder() } label: {
                            Image(systemName: "folder")
                                .font(.system(size: 13, weight: .medium))
                                .frame(width: ProjectCreationWizardMetrics.browseButtonWidth, height: ProjectCreationWizardMetrics.fieldHeight)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(DesignTokens.secondaryText)
                        .background(
                            RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                                .fill(DesignTokens.controlSurface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                                .stroke(DesignTokens.separator.opacity(0.78), lineWidth: 1)
                        )
                        .help(state.t(.browse))
                    }
                }
                if workspaceType == .new {
                    wizardTextField(state.t(.githubURLOptional), text: $githubURL, monospaced: true)
                    Text(state.t(.gitURLHelp))
                        .font(.system(size: 12))
                        .foregroundStyle(DesignTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: ProjectCreationWizardMetrics.formMaxWidth, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        default:
            VStack(alignment: .leading, spacing: 14) {
                Text(state.t(.review))
                    .font(.system(size: 15, weight: .semibold))
                VStack(spacing: 0) {
                    reviewRow(state.t(.type), workspaceType == .existing ? state.t(.openExisting) : state.t(.createNew))
                    Divider().padding(.leading, 112)
                    reviewRow(state.t(.displayName), finalDisplayName)
                    Divider().padding(.leading, 112)
                    reviewRow(state.t(.workspacePath), expandedPath)
                    if workspaceType == .new && !githubURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Divider().padding(.leading, 112)
                        reviewRow("Git", githubURL)
                    }
                }
                .background(DesignTokens.contentSurface, in: RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous)
                        .stroke(DesignTokens.separator.opacity(0.82), lineWidth: 1)
                )
                if isCreating {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.68)
                        Text(state.t(.creatingProject))
                            .font(.system(size: 12))
                            .foregroundStyle(DesignTokens.tertiaryText)
                    }
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: ProjectCreationWizardMetrics.formMaxWidth, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func wizardTextField(_ title: String, text: Binding<String>, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DesignTokens.tertiaryText)
            WizardPlainTextField(placeholder: title, text: text, monospaced: monospaced)
        }
    }

    private var footer: some View {
        HStack {
            if step == 0 {
                Button(state.t(.cancel), action: onClose)
                    .buttonStyle(WebToolbarButtonStyle())
                    .disabled(isCreating)
            } else {
                Button {
                    step = max(0, step - 1)
                } label: {
                    Text(state.t(.back))
                }
                .buttonStyle(WebToolbarButtonStyle())
                .disabled(isCreating)
            }

            Spacer()

            if step > 0 {
                Button(state.t(.cancel), action: onClose)
                    .buttonStyle(WebToolbarButtonStyle())
                    .disabled(isCreating)
            }

            Button {
                if step < 2 {
                    step += 1
                } else {
                    createProject()
                }
            } label: {
                Text(step == 2 ? state.t(.createProject) : state.t(.continueAction))
            }
            .buttonStyle(WebToolbarButtonStyle(isProminent: true))
            .disabled(!canContinue || isCreating)
        }
        .padding(.horizontal, 20)
        .frame(height: ProjectCreationWizardMetrics.footerHeight)
    }

    private func typeCard(_ type: WorkspaceCreationType, title: String, detail: String, icon: String) -> some View {
        let selected = workspaceType == type
        let hovering = hoveredWorkspaceType == type
        return Button {
            workspaceType = type
        } label: {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selected ? DesignTokens.accent.opacity(0.12) : DesignTokens.neutral100.opacity(0.85))
                    .frame(width: 34, height: 34)
                    .overlay {
                        Image(systemName: icon)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(selected ? DesignTokens.accent : DesignTokens.tertiaryText)
                    }
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DesignTokens.text)
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(DesignTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DesignTokens.accent)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: ProjectCreationWizardMetrics.typeCardMinHeight, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous)
                    .fill(selected ? DesignTokens.accent.opacity(0.055) : (hovering ? DesignTokens.neutral100.opacity(0.68) : DesignTokens.contentSurface))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous)
                    .stroke(selected ? DesignTokens.accent.opacity(0.88) : DesignTokens.separator.opacity(hovering ? 0.95 : 0.74), lineWidth: selected ? 1.2 : 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hoveredWorkspaceType = inside ? type : nil
        }
    }

    private struct WizardPlainTextField: View {
        var placeholder: String
        @Binding var text: String
        var monospaced = false
        @FocusState private var isFocused: Bool

        var body: some View {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: monospaced ? .monospaced : .default))
                .foregroundStyle(DesignTokens.text)
                .textSelection(.enabled)
                .lineLimit(1)
                .padding(.horizontal, 11)
                .frame(height: ProjectCreationWizardMetrics.fieldHeight)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                        .fill(DesignTokens.controlSurfaceActive.opacity(0.72))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                        .stroke(isFocused ? DesignTokens.accent.opacity(0.55) : DesignTokens.separator.opacity(0.78), lineWidth: 1)
                )
                .focused($isFocused)
        }
    }

    private func reviewRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(DesignTokens.tertiaryText)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.system(size: 12, design: label == state.t(.workspacePath) ? .monospaced : .default))
                .foregroundStyle(DesignTokens.text)
                .textSelection(.enabled)
                .lineLimit(3)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
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
        return name.isEmpty ? state.t(.createProject) : name
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
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let image = image {
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

    private var image: NSImage? {
        let resourceName = colorScheme == .dark ? "9gclaw-logo-white" : "9gclaw-logo"
        if let url = Bundle.main.url(forResource: resourceName, withExtension: "png") {
            return NSImage(contentsOf: url)
        }
        if let fallback = Bundle.main.url(forResource: "9gclaw-logo", withExtension: "png") {
            return NSImage(contentsOf: fallback)
        }
        return NSImage(named: resourceName) ?? NSImage(named: "9gclaw-logo")
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
