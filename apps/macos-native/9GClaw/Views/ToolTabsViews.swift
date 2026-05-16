import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FilesView: View {
    @EnvironmentObject private var state: AppState
    @State private var files: [WorkspaceFile] = []
    @State private var expandedDirectories: Set<String> = []
    @State private var chatWidth = DesignTokens.filesChatDefaultWidth
    @State private var editorWidth: CGFloat = 600
    @State private var editorFile: WorkspaceFile?
    @State private var editorExpanded = false

    var body: some View {
        HStack(spacing: 0) {
            ChatView()
                .environmentObject(state)
                .frame(width: chatWidth)
                .frame(minWidth: DesignTokens.filesChatMinWidth)

            SplitDivider(width: $chatWidth, minWidth: DesignTokens.filesChatMinWidth, maxWidth: 720)

            filePane
                .frame(minWidth: DesignTokens.filesPaneMinWidth, maxWidth: editorExpanded ? 0 : .infinity)
                .opacity(editorExpanded ? 0 : 1)

            if let editorFile {
                SplitDivider(width: $editorWidth, minWidth: 320, maxWidth: 900, reverse: true)
                FileEditorPane(
                    file: editorFile,
                    content: $state.selectedFileContent,
                    width: editorExpanded ? nil : editorWidth,
                    isExpanded: editorExpanded,
                    onClose: {
                        self.editorFile = nil
                        state.selectedFile = nil
                        state.selectedFileContent = ""
                        editorExpanded = false
                    },
                    onToggleExpand: { editorExpanded.toggle() },
                    onSave: {
                        do {
                            try state.workspaceService.writeFile(path: editorFile.path, content: state.selectedFileContent)
                            state.statusLine = "Saved \(editorFile.name)"
                        } catch {
                            state.errorBanner = error.localizedDescription
                        }
                    }
                )
                .environmentObject(state)
            }
        }
        .background(DesignTokens.background)
        .task(id: state.selectedProjectID) { loadFiles() }
    }

    private var filePane: some View {
        VStack(spacing: 0) {
            toolbar
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if files.isEmpty {
                        ToolEmptyState(
                            title: "No files found",
                            detail: "Refresh after selecting a workspace with readable files.",
                            systemImage: "doc.text.magnifyingglass"
                        )
                        .padding(.top, 48)
                    } else {
                        ForEach(files) { file in
                            FileTreeRow(
                                file: file,
                                isSelected: state.selectedFile == file,
                                onOpen: { open(file) },
                                onToggle: { toggle(file) },
                                onPreviewHTML: { openHTML(file) },
                                onDelete: { delete(file) },
                                onRename: { rename(file) }
                            )
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
        .background(DesignTokens.background)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 13))
                    .foregroundStyle(DesignTokens.tertiaryText)
                Text(state.selectedWorkspaceContext?.rootPath ?? "No project selected")
                    .font(.system(size: 10.5, design: .monospaced))
                    .lineLimit(1)
                    .foregroundStyle(DesignTokens.tertiaryText)
            }
            Spacer()
            Menu {
                Button("New File") { create(isDirectory: false) }
                Button("New Folder") { create(isDirectory: true) }
                Divider()
                Button("Upload Files...") { upload(allowDirectories: false) }
                Button("Upload Folder...") { upload(allowDirectories: true) }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(WebToolbarButtonStyle())
            Button { downloadZip() } label: { Image(systemName: "square.and.arrow.down") }
                .buttonStyle(WebToolbarButtonStyle())
            Button { loadFiles() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(WebToolbarButtonStyle())
            Button {
                expandedDirectories.removeAll()
                loadFiles()
            } label: { Image(systemName: "rectangle.compress.vertical") }
                .buttonStyle(WebToolbarButtonStyle())
            Button { state.activeTab = .chat } label: { Image(systemName: "xmark") }
                .buttonStyle(WebToolbarButtonStyle())
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DesignTokens.separator).frame(height: 1)
        }
    }

    private func loadFiles() {
        guard let context = state.selectedWorkspaceContext else {
            files = []
            return
        }
        files = (try? state.workspaceService.listFiles(rootPath: context.rootPath, expandedDirectories: expandedDirectories)) ?? []
    }

    private func open(_ file: WorkspaceFile) {
        if file.isDirectory {
            toggle(file)
            return
        }
        state.selectedFile = file
        editorFile = file
        state.selectedFileContent = (try? state.workspaceService.readFile(path: file.path)) ?? ""
    }

    private func toggle(_ file: WorkspaceFile) {
        guard file.isDirectory else { return }
        if expandedDirectories.contains(file.path) {
            expandedDirectories.remove(file.path)
        } else {
            expandedDirectories.insert(file.path)
        }
        loadFiles()
    }

    private func openHTML(_ file: WorkspaceFile) {
        NSWorkspace.shared.open(URL(fileURLWithPath: file.path))
    }

    private func create(isDirectory: Bool) {
        guard let context = state.selectedWorkspaceContext else { return }
        let alert = NSAlert()
        alert.messageText = isDirectory ? "New Folder" : "New File"
        alert.informativeText = "Enter a name."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = isDirectory ? "New Folder" : "untitled.txt"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let parent = state.selectedFile?.isDirectory == true ? state.selectedFile!.path : context.rootPath
            let path = try state.workspaceService.createFile(parentPath: parent, name: field.stringValue, isDirectory: isDirectory)
            if isDirectory {
                expandedDirectories.insert(path)
            }
            loadFiles()
        } catch {
            state.errorBanner = error.localizedDescription
        }
    }

    private func rename(_ file: WorkspaceFile) {
        let alert = NSAlert()
        alert.messageText = "Rename"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = file.name
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            _ = try state.workspaceService.rename(path: file.path, newName: field.stringValue)
            loadFiles()
        } catch {
            state.errorBanner = error.localizedDescription
        }
    }

    private func delete(_ file: WorkspaceFile) {
        let alert = NSAlert()
        alert.messageText = "Delete \(file.name)?"
        alert.informativeText = "This cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try state.workspaceService.delete(path: file.path)
            if state.selectedFile == file {
                editorFile = nil
                state.selectedFile = nil
            }
            loadFiles()
        } catch {
            state.errorBanner = error.localizedDescription
        }
    }

    private func upload(allowDirectories: Bool) {
        guard let context = state.selectedWorkspaceContext else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = !allowDirectories
        panel.canChooseDirectories = allowDirectories
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        do {
            try state.workspaceService.copyItems(panel.urls, into: context.rootPath)
            loadFiles()
        } catch {
            state.errorBanner = error.localizedDescription
        }
    }

    private func downloadZip() {
        guard let context = state.selectedWorkspaceContext else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(context.displayName).zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try state.workspaceService.exportZip(rootPath: context.rootPath, to: url)
            state.statusLine = "Downloaded \(url.lastPathComponent)"
        } catch {
            state.errorBanner = error.localizedDescription
        }
    }
}

struct GitView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ToolPage(title: "Git", subtitle: state.selectedWorkspaceContext?.rootPath ?? "No project selected") {
            Button("Status") { state.refreshGitStatus() }.buttonStyle(WebToolbarButtonStyle(isProminent: true))
            Button("Diff") { state.refreshGitDiff() }.buttonStyle(WebToolbarButtonStyle())
            Button("Fetch") { state.errorBanner = "Fetch is not implemented in this parity pass." }.buttonStyle(WebToolbarButtonStyle())
            Button("Pull") { state.errorBanner = "Pull is not implemented in this parity pass." }.buttonStyle(WebToolbarButtonStyle())
            Button("Push") { state.errorBanner = "Push is not implemented in this parity pass." }.buttonStyle(WebToolbarButtonStyle())
        } content: {
            MonospaceOutput(text: state.gitOutput.isEmpty ? "Run git status to inspect the selected workspace." : state.gitOutput)
        }
        .task { state.refreshGitStatus() }
    }
}

struct ShellView: View {
    @EnvironmentObject private var state: AppState
    @State private var command = "pwd"

    var body: some View {
        ToolPage(title: "Shell", subtitle: state.selectedWorkspaceContext?.rootPath ?? "No project selected") {
            HStack(spacing: 8) {
                TextField("Command", text: $command)
                    .textFieldStyle(WebFieldStyle())
                    .font(.system(size: 13, design: .monospaced))
                    .frame(width: 360)
                    .onSubmit { state.runShell(command: command) }
                Button("Run") { state.runShell(command: command) }
                    .buttonStyle(WebToolbarButtonStyle(isProminent: true))
            }
        } content: {
            ToolList {
                if state.terminalRuns.isEmpty {
                    ToolEmptyState(title: "No shell output", detail: "Run a command to create a terminal transcript.", systemImage: "terminal")
                        .padding(.top, 80)
                } else {
                    ForEach(state.terminalRuns) { run in
                        TerminalRunRow(run: run)
                    }
                }
            }
        }
    }
}

struct TasksView: View {
    @EnvironmentObject private var state: AppState
    @State private var title = ""
    @State private var prompt = ""

    var body: some View {
        ToolPage(title: "Tasks", subtitle: "Task plans and execution queue") {
            TextField("Task title", text: $title).textFieldStyle(WebFieldStyle()).frame(width: 180)
            TextField("Prompt", text: $prompt).textFieldStyle(WebFieldStyle()).frame(width: 280)
            Button("Queue") {
                _ = state.taskService.createPlan(title: title.isEmpty ? "Untitled task" : title, prompt: prompt)
                title = ""
                prompt = ""
                state.objectWillChange.send()
            }
            .buttonStyle(WebToolbarButtonStyle(isProminent: true))
        } content: {
            ToolList {
                if state.taskService.plans.isEmpty {
                    ToolEmptyState(title: "No tasks queued", detail: "Create a task plan from the toolbar.", systemImage: "checklist")
                } else {
                    ForEach(state.taskService.plans) { plan in
                        ToolListRow(systemImage: "checklist", title: plan.title, detail: plan.prompt) {
                            Text(plan.status.rawValue)
                        }
                    }
                }
            }
        }
    }
}

struct MemoryView: View {
    @EnvironmentObject private var state: AppState
    @State private var query = ""
    @State private var selectedRecord: MemoryRecord?

    var body: some View {
        let snapshot = state.memoryService.dashboard(query: query, projectName: state.selectedProject?.name)
        VStack(spacing: 0) {
            ToolToolbar(title: "Memory", subtitle: state.selectedWorkspaceContext?.rootPath ?? "Select a project") {
                TextField("Search memory", text: $query)
                    .textFieldStyle(WebFieldStyle())
                    .frame(width: 220)
                Button("Index") {
                    state.refreshNativeToolData()
                    state.objectWillChange.send()
                }
                .buttonStyle(WebToolbarButtonStyle(isProminent: true))
                Button("Clear") {
                    state.memoryService.clear(projectName: state.selectedProject?.name)
                    state.objectWillChange.send()
                }
                .buttonStyle(WebToolbarButtonStyle())
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        Metric("Entries", "\(snapshot.totalEntries)", "externaldrive")
                        Metric("Project", "\(snapshot.projectEntries)", "folder")
                        Metric("Feedback", "\(snapshot.feedbackEntries)", "bubble.left.and.bubble.right")
                        Metric("Latest", snapshot.latestMemoryAt.map(relativeDate) ?? "none", "clock")
                    }
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Workspace Memory")
                                .font(.system(size: 13, weight: .semibold))
                            if snapshot.records.isEmpty {
                                ToolEmptyState(title: "No memory records", detail: "Run Index or add memory files in this workspace.", systemImage: "externaldrive")
                                    .frame(height: 240)
                            } else {
                                ForEach(snapshot.records) { record in
                                    Button {
                                        selectedRecord = record
                                    } label: {
                                        ToolListRow(systemImage: record.type == .feedback ? "text.bubble" : "doc.text", title: record.name, detail: record.summary) {
                                            Text(record.type.label)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)

                        VStack(alignment: .leading, spacing: 10) {
                            Text(selectedRecord?.name ?? "User Summary")
                                .font(.system(size: 13, weight: .semibold))
                            Text(selectedRecord?.summary ?? (snapshot.userSummary.isEmpty ? "No summary yet." : snapshot.userSummary))
                                .font(.system(size: 12))
                                .foregroundStyle(DesignTokens.secondaryText)
                                .textSelection(.enabled)
                            if let selectedRecord {
                                Text(selectedRecord.relativePath)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(DesignTokens.tertiaryText)
                            }
                        }
                        .padding(14)
                        .frame(width: 320, alignment: .topLeading)
                        .background(DesignTokens.neutral50, in: RoundedRectangle(cornerRadius: DesignTokens.radius))
                        .overlay(RoundedRectangle(cornerRadius: DesignTokens.radius).stroke(DesignTokens.separator))
                    }
                }
                .padding(24)
            }
        }
        .background(DesignTokens.background)
    }
}

struct SkillsView: View {
    @EnvironmentObject private var state: AppState
    @State private var selectedSkillID: UUID?
    @State private var editorContent = ""
    @State private var originalContent = ""
    @State private var showNew = false
    @State private var newSlug = ""
    @State private var newName = ""
    @State private var newDescription = ""
    @State private var newScope: SkillScope = .user

    private var selectedSkill: SkillRecord? {
        state.skillsService.skills.first { $0.id == selectedSkillID }
    }

    var body: some View {
        VStack(spacing: 0) {
            ToolToolbar(
                title: "Skills",
                subtitle: state.selectedWorkspaceContext?.isGeneral == true
                    ? "General chat - user-scope skills only"
                    : (state.selectedWorkspaceContext?.rootPath ?? "No project selected")
            ) {
                Button("Refresh") { refresh() }.buttonStyle(WebToolbarButtonStyle())
                Button("Import") { importSkill() }.buttonStyle(WebToolbarButtonStyle())
                Button("New") {
                    newScope = state.selectedWorkspaceContext?.isGeneral == true ? .user : .project
                    showNew = true
                }
                .buttonStyle(WebToolbarButtonStyle(isProminent: true))
            }
            HStack(spacing: 0) {
                skillsList
                    .frame(width: 288)
                Rectangle().fill(DesignTokens.separator).frame(width: 1)
                skillDetail
            }
        }
        .background(DesignTokens.background)
        .sheet(isPresented: $showNew) {
            newSkillSheet
                .frame(width: 520, height: 360)
        }
        .task { refresh() }
    }

    private var skillsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                SkillScopeSection(
                    title: "Project Skills",
                    skills: state.skillsService.skills.filter { $0.scope == .project },
                    selectedSkillID: selectedSkillID,
                    onSelect: select
                )
                .opacity(state.selectedWorkspaceContext?.isGeneral == true ? 0 : 1)
                SkillScopeSection(
                    title: "User Skills",
                    skills: state.skillsService.skills.filter { $0.scope == .user },
                    selectedSkillID: selectedSkillID,
                    onSelect: select
                )
                if state.skillsService.skills.isEmpty {
                    Text("No skills yet. Click New to install or create one.")
                        .font(.system(size: 12))
                        .foregroundStyle(DesignTokens.tertiaryText)
                        .padding(16)
                }
            }
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private var skillDetail: some View {
        if let skill = selectedSkill {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(skill.name)
                                .font(.system(size: 14, weight: .semibold))
                            Text(skill.scope.rawValue)
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background((skill.scope == .project ? DesignTokens.accent : DesignTokens.warning).opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                        }
                        Text(skill.description.isEmpty ? skill.slug : skill.description)
                            .font(.system(size: 11))
                            .foregroundStyle(DesignTokens.tertiaryText)
                        Text(skill.skillDir)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(DesignTokens.tertiaryText)
                    }
                    Spacer()
                    Button("Delete") { delete(skill) }.buttonStyle(WebToolbarButtonStyle())
                    Button("Revert") { editorContent = originalContent }.buttonStyle(WebToolbarButtonStyle()).disabled(editorContent == originalContent)
                    Button("Save") { save(skill) }.buttonStyle(WebToolbarButtonStyle(isProminent: true)).disabled(editorContent == originalContent)
                }
                .padding(.horizontal, 18)
                .frame(height: 74)
                .overlay(alignment: .bottom) { Rectangle().fill(DesignTokens.separator).frame(height: 1) }

                TextEditor(text: $editorContent)
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(12)
            }
        } else {
            ToolEmptyState(title: "Pick a skill", detail: "Select a skill on the left to view or edit its SKILL.md.", systemImage: "sparkles")
        }
    }

    private var newSkillSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Skill")
                .font(.system(size: 16, weight: .semibold))
            Picker("Scope", selection: $newScope) {
                Text("User").tag(SkillScope.user)
                Text("Project").tag(SkillScope.project)
            }
            .pickerStyle(.segmented)
            .disabled(state.selectedWorkspaceContext?.isGeneral == true)
            SettingsTextFieldCompat("Slug", text: $newSlug)
            SettingsTextFieldCompat("Name", text: $newName)
            SettingsTextFieldCompat("Description", text: $newDescription)
            Spacer()
            HStack {
                Spacer()
                Button("Cancel") { showNew = false }.buttonStyle(WebToolbarButtonStyle())
                Button("Create") { createSkill() }.buttonStyle(WebToolbarButtonStyle(isProminent: true))
            }
        }
        .padding(20)
    }

    private func refresh() {
        state.refreshNativeToolData()
        if selectedSkillID == nil {
            select(state.skillsService.skills.first)
        }
        state.objectWillChange.send()
    }

    private func select(_ skill: SkillRecord?) {
        guard let skill else { return }
        selectedSkillID = skill.id
        editorContent = (try? state.skillsService.read(skill)) ?? ""
        originalContent = editorContent
    }

    private func save(_ skill: SkillRecord) {
        do {
            _ = try state.skillsService.write(skill, content: editorContent)
            originalContent = editorContent
            refresh()
        } catch {
            state.errorBanner = error.localizedDescription
        }
    }

    private func delete(_ skill: SkillRecord) {
        do {
            try state.skillsService.delete(skill)
            selectedSkillID = nil
            refresh()
        } catch {
            state.errorBanner = error.localizedDescription
        }
    }

    private func createSkill() {
        do {
            let skill = try state.skillsService.create(
                scope: newScope,
                projectPath: state.selectedWorkspaceContext?.isGeneral == true ? nil : state.selectedWorkspaceContext?.rootPath,
                slug: newSlug,
                name: newName,
                description: newDescription
            )
            showNew = false
            newSlug = ""
            newName = ""
            newDescription = ""
            refresh()
            select(skill)
        } catch {
            state.errorBanner = error.localizedDescription
        }
    }

    private func importSkill() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let scope: SkillScope = state.selectedWorkspaceContext?.isGeneral == true ? .user : .project
            let skill = try state.skillsService.importFolder(
                source: url,
                scope: scope,
                projectPath: scope == .project ? state.selectedWorkspaceContext?.rootPath : nil,
                slug: nil,
                overwrite: false
            )
            refresh()
            select(skill)
        } catch {
            state.errorBanner = error.localizedDescription
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        let snapshot = state.routingService.dashboard(projects: state.projects, projectFilter: state.selectedProject?.name)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Dashboard")
                            .font(.system(size: 20, weight: .semibold))
                        Text("Model routing, token saver, request log, and cost summary.")
                            .font(.system(size: 13))
                            .foregroundStyle(DesignTokens.tertiaryText)
                    }
                    Spacer()
                    Button {
                        state.objectWillChange.send()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(WebToolbarButtonStyle())
                }
                HStack(spacing: 12) {
                    Metric("Requests", "\(snapshot.routedSessions)", "arrow.triangle.branch")
                    Metric("Tokens", "\(snapshot.totalTokens)", "number")
                    Metric("Cost", formatCost(snapshot.estimatedCost), "dollarsign.circle")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ToolSection(title: "Recent routes") {
                    if snapshot.recentSessions.isEmpty {
                        Text("No routing activity yet. Start a conversation to see stats here.")
                            .font(.system(size: 13))
                            .foregroundStyle(DesignTokens.tertiaryText)
                            .padding(.vertical, 24)
                    } else {
                        HStack {
                            Text("Session")
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text("Project")
                                .frame(width: 140, alignment: .leading)
                            Text("Tokens")
                                .frame(width: 80, alignment: .trailing)
                            Text("Cost")
                                .frame(width: 80, alignment: .trailing)
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DesignTokens.tertiaryText)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 6)
                        ForEach(snapshot.recentSessions) { session in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.title)
                                        .font(.system(size: 13, weight: .semibold))
                                        .lineLimit(1)
                                    Text(session.requestLog.first ?? relativeDate(session.lastActiveAt))
                                        .font(.system(size: 11))
                                        .foregroundStyle(DesignTokens.tertiaryText)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Text(session.projectName)
                                    .font(.system(size: 12))
                                    .foregroundStyle(DesignTokens.tertiaryText)
                                    .frame(width: 140, alignment: .leading)
                                Text("\(session.totalTokens)")
                                    .font(.system(size: 12, design: .monospaced))
                                    .frame(width: 80, alignment: .trailing)
                                Text(formatCost(session.estimatedCost))
                                    .font(.system(size: 12, design: .monospaced))
                                    .frame(width: 80, alignment: .trailing)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .background(DesignTokens.neutral50, in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius))
                        }
                    }
                }
            }
            .frame(maxWidth: 960, alignment: .topLeading)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
        }
        .background(DesignTokens.background)
    }
}

struct AlwaysOnView: View {
    @EnvironmentObject private var state: AppState
    @State private var subtab: AlwaysOnSubTab = .items
    @State private var selectedPlan: AlwaysOnPlan?
    @State private var selectedRun: AlwaysOnRunHistory?

    var body: some View {
        guard let context = state.selectedWorkspaceContext, !context.isGeneral else {
            return AnyView(ToolEmptyState(title: "Pick a project", detail: "Always-On is available for project workspaces.", systemImage: "dot.radiowaves.left.and.right"))
        }
        let plans = state.alwaysOnService.plans(projectRoot: context.rootPath)
        let cronJobs = state.alwaysOnService.cronJobs(projectRoot: context.rootPath)
        let history = state.alwaysOnService.runHistory(projectRoot: context.rootPath)
        return AnyView(
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    TabButton("Plans & Cron Jobs", isActive: subtab == .items) { subtab = .items; selectedRun = nil }
                    TabButton("Run History", isActive: subtab == .history) { subtab = .history; selectedPlan = nil }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(height: 36)
                .overlay(alignment: .bottom) { Rectangle().fill(DesignTokens.separator).frame(height: 1) }

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Always-On")
                                    .font(.system(size: 20, weight: .semibold))
                                Text("Background discovery agent for this project.")
                                    .font(.system(size: 13))
                                    .foregroundStyle(DesignTokens.tertiaryText)
                            }
                            Spacer()
                            Button("Refresh") { state.objectWillChange.send() }.buttonStyle(WebToolbarButtonStyle())
                            Button("Discover") {
                                state.startDraftSession(project: state.selectedProject)
                                state.composerText = "Run Always-On discovery for \(context.displayName)."
                            }
                            .buttonStyle(WebToolbarButtonStyle(isProminent: true))
                        }

                        if subtab == .history {
                            historyView(history)
                        } else if let selectedPlan {
                            planDetail(selectedPlan, projectRoot: context.rootPath)
                        } else {
                            itemsView(plans: plans, cronJobs: cronJobs, projectRoot: context.rootPath)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                }
            }
            .background(DesignTokens.background)
        )
    }

    private func itemsView(plans: [AlwaysOnPlan], cronJobs: [AlwaysOnCronJob], projectRoot: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if plans.isEmpty && cronJobs.isEmpty {
                Text("No active plans or cron jobs. Completed runs are available in Run History.")
                    .font(.system(size: 13))
                    .foregroundStyle(DesignTokens.tertiaryText)
                    .padding(18)
            } else {
                ForEach(plans) { plan in
                    ToolListRow(systemImage: "sparkles", title: plan.title, detail: "\(plan.status.rawValue) · \(relativeDate(plan.updatedAt))") {
                        HStack(spacing: 6) {
                            Button("View") { selectedPlan = plan }.buttonStyle(WebToolbarButtonStyle())
                            Button("Run") {
                                try? state.alwaysOnService.markPlanRunning(plan: plan, projectRoot: projectRoot)
                                state.objectWillChange.send()
                            }.buttonStyle(WebToolbarButtonStyle(isProminent: true))
                            Button("Archive") {
                                try? state.alwaysOnService.archive(plan: plan, projectRoot: projectRoot)
                                state.objectWillChange.send()
                            }.buttonStyle(WebToolbarButtonStyle())
                        }
                    }
                }
                ForEach(cronJobs) { job in
                    ToolListRow(systemImage: "timer", title: cronTitle(job), detail: "\(job.status.rawValue) · \(job.cron)") {
                        Text(job.recurring ? "recurring" : "one-shot")
                    }
                }
            }
        }
        .padding(18)
        .background(DesignTokens.background, in: RoundedRectangle(cornerRadius: DesignTokens.radius))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.radius).stroke(DesignTokens.separator))
    }

    private func planDetail(_ plan: AlwaysOnPlan, projectRoot: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Button {
                selectedPlan = nil
            } label: {
                Label("Back", systemImage: "arrow.left")
            }
            .buttonStyle(WebToolbarButtonStyle())
            Text(plan.title)
                .font(.system(size: 20, weight: .semibold))
            if !plan.summary.isEmpty {
                Text(plan.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(DesignTokens.secondaryText)
            }
            MarkdownPreview(text: plan.content.isEmpty ? "No plan markdown content." : plan.content)
            Text(plan.planFilePath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(DesignTokens.tertiaryText)
        }
    }

    private func historyView(_ history: [AlwaysOnRunHistory]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let selectedRun {
                Button { self.selectedRun = nil } label: { Label("Back", systemImage: "arrow.left") }
                    .buttonStyle(WebToolbarButtonStyle())
                Text(selectedRun.title)
                    .font(.system(size: 20, weight: .semibold))
                MonospaceOutput(text: selectedRun.outputLog.isEmpty ? "No output log was captured for this run." : selectedRun.outputLog)
                    .frame(minHeight: 360)
            } else if history.isEmpty {
                Text("No Always-On runs have been recorded yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(DesignTokens.tertiaryText)
            } else {
                ForEach(history) { run in
                    Button {
                        selectedRun = run
                    } label: {
                        ToolListRow(systemImage: "clock.arrow.circlepath", title: run.title, detail: "\(run.kind) · \(run.status.rawValue) · \(relativeDate(run.startedAt))") {
                            Text(run.sourceId)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct PreviewView: View {
    var body: some View {
        ToolPage(title: "Preview", subtitle: "Native inspectors for project preview targets") {} content: {
            ToolEmptyState(title: "No preview selected", detail: "Open HTML files from Files to launch them in the default browser.", systemImage: "eye")
        }
    }
}

struct PluginPlaceholderView: View {
    var name: String

    var body: some View {
        ToolPage(title: name, subtitle: "Plugin tab") {} content: {
            ToolEmptyState(title: name, detail: "Plugin manifest, assets, enablement, and lifecycle controls will map to native services.", systemImage: "shippingbox")
        }
    }
}

private struct FileEditorPane: View {
    @EnvironmentObject private var state: AppState
    var file: WorkspaceFile
    @Binding var content: String
    var width: CGFloat?
    var isExpanded: Bool
    var onClose: () -> Void
    var onToggleExpand: () -> Void
    var onSave: () -> Void
    @State private var markdownPreview = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: file.isImage ? "photo" : "doc.text")
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .font(.system(size: 13, weight: .semibold))
                    Text(file.relativePath)
                        .font(.system(size: 10.5, design: .monospaced))
                        .lineLimit(1)
                        .foregroundStyle(DesignTokens.tertiaryText)
                }
                Spacer()
                if file.isMarkdown {
                    Button(markdownPreview ? "Edit Markdown" : "Preview Markdown") { markdownPreview.toggle() }
                        .buttonStyle(WebToolbarButtonStyle())
                }
                if file.isHTML {
                    Button("Open HTML") { NSWorkspace.shared.open(URL(fileURLWithPath: file.path)) }
                        .buttonStyle(WebToolbarButtonStyle())
                }
                Button("Download") { download() }.buttonStyle(WebToolbarButtonStyle())
                Button("Save") { onSave() }.buttonStyle(WebToolbarButtonStyle(isProminent: true)).disabled(file.isImage)
                Button { onToggleExpand() } label: { Image(systemName: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(WebToolbarButtonStyle())
                Button { onClose() } label: { Image(systemName: "xmark") }
                    .buttonStyle(WebToolbarButtonStyle())
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            .overlay(alignment: .bottom) { Rectangle().fill(DesignTokens.separator).frame(height: 1) }

            if file.isImage, let image = NSImage(contentsOfFile: file.path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
            } else if file.isMarkdown && markdownPreview {
                ScrollView {
                    MarkdownPreview(text: content)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else if isProbablyBinary(file.path) {
                ToolEmptyState(title: "Binary File", detail: "\(file.name) cannot be displayed in the text editor.", systemImage: "doc.zipper")
            } else {
                TextEditor(text: $content)
                    .font(.system(size: CGFloat(state.settings.codeEditor.fontSize), design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(12)
            }
            CodeEditorFooterCompat(content: content)
        }
        .frame(width: width)
        .frame(maxWidth: isExpanded ? .infinity : nil, maxHeight: .infinity)
        .background(DesignTokens.background)
    }

    private func download() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.copyItem(at: URL(fileURLWithPath: file.path), to: url)
        } catch {
            state.errorBanner = error.localizedDescription
        }
    }

    private func isProbablyBinary(_ path: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe]) else { return false }
        return data.prefix(1024).contains(0)
    }
}

private struct FileTreeRow: View {
    var file: WorkspaceFile
    var isSelected: Bool
    var onOpen: () -> Void
    var onToggle: () -> Void
    var onPreviewHTML: () -> Void
    var onDelete: () -> Void
    var onRename: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onOpen) {
                HStack(spacing: 6) {
                    Spacer().frame(width: CGFloat(file.depth * 18))
                    if file.isDirectory {
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(file.isExpanded ? 90 : 0))
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 12)
                    } else {
                        Spacer().frame(width: 12)
                    }
                    Image(systemName: iconName)
                        .font(.system(size: 13))
                        .foregroundStyle(file.isDirectory ? DesignTokens.warning : DesignTokens.tertiaryText)
                        .frame(width: 15)
                    Text(file.name)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 6)
                .frame(height: 28)
                .foregroundStyle(DesignTokens.text)
                .background(isSelected ? DesignTokens.selectedRowFill() : Color.clear, in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius))
            }
            .buttonStyle(.plain)

            if file.isHTML {
                Button(action: onPreviewHTML) {
                    Image(systemName: "eye")
                        .font(.system(size: 12))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }
        }
        .contextMenu {
            Button("Rename", action: onRename)
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private var iconName: String {
        if file.isDirectory { return "folder" }
        if file.isMarkdown { return "doc.richtext" }
        if file.isHTML { return "globe" }
        if file.isImage { return "photo" }
        return "doc.text"
    }
}

private struct SkillScopeSection: View {
    var title: String
    var skills: [SkillRecord]
    var selectedSkillID: UUID?
    var onSelect: (SkillRecord) -> Void

    var body: some View {
        if !skills.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("\(title.uppercased()) · \(skills.count)")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(DesignTokens.neutral400)
                    .padding(.horizontal, 14)
                ForEach(skills) { skill in
                    Button { onSelect(skill) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(skill.name)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                                if let version = skill.version {
                                    Text("v\(version)")
                                        .font(.system(size: 10))
                                        .foregroundStyle(DesignTokens.tertiaryText)
                                }
                            }
                            if !skill.description.isEmpty {
                                Text(skill.description)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                    .foregroundStyle(DesignTokens.tertiaryText)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(selectedSkillID == skill.id ? DesignTokens.selectedRowFill() : Color.clear, in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
        }
    }
}

private struct MarkdownPreview: View {
    var text: String

    var body: some View {
        if let attributed = try? AttributedString(markdown: text) {
            Text(attributed)
                .font(.system(size: 13))
                .textSelection(.enabled)
        } else {
            Text(text)
                .font(.system(size: 13))
                .textSelection(.enabled)
        }
    }
}

private enum AlwaysOnSubTab {
    case items
    case history
}

private struct TabButton: View {
    var title: String
    var isActive: Bool
    var action: () -> Void

    init(_ title: String, isActive: Bool, action: @escaping () -> Void) {
        self.title = title
        self.isActive = isActive
        self.action = action
    }

    var body: some View {
        Button(title, action: action)
            .buttonStyle(PillTabButtonStyle(isActive: isActive))
    }
}

private struct PillTabButtonStyle: ButtonStyle {
    var isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: isActive ? .medium : .regular))
            .foregroundStyle(isActive ? DesignTokens.text : DesignTokens.tertiaryText)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(isActive ? DesignTokens.neutral100 : Color.clear, in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

private struct SettingsTextFieldCompat: View {
    var label: String
    @Binding var text: String

    init(_ label: String, text: Binding<String>) {
        self.label = label
        self._text = text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DesignTokens.tertiaryText)
            TextField(label, text: $text)
                .textFieldStyle(WebFieldStyle())
        }
    }
}

private struct SplitDivider: View {
    @Binding var width: CGFloat
    var minWidth: CGFloat
    var maxWidth: CGFloat
    var reverse = false
    @State private var startWidth: CGFloat = 0
    @State private var dragging = false

    var body: some View {
        Rectangle()
            .fill(dragging ? DesignTokens.accent.opacity(0.45) : DesignTokens.separator)
            .frame(width: dragging ? 3 : 1)
            .contentShape(Rectangle().inset(by: -4))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !dragging {
                            dragging = true
                            startWidth = width
                        }
                        let delta = reverse ? -value.translation.width : value.translation.width
                        width = min(maxWidth, max(minWidth, startWidth + delta))
                    }
                    .onEnded { _ in dragging = false }
            )
            .help("Drag to resize")
    }
}

private struct ToolPage<Actions: View, Content: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            ToolToolbar(title: title, subtitle: subtitle, actions: actions)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(DesignTokens.background)
    }
}

struct ToolToolbar<Actions: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DesignTokens.text)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundStyle(DesignTokens.tertiaryText)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) { actions() }
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
        .overlay(alignment: .bottom) { Rectangle().fill(DesignTokens.separator).frame(height: 1) }
    }
}

private struct ToolList<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                content()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

private struct ToolSection<Content: View>: View {
    var title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .medium))
                .tracking(0.44)
                .foregroundStyle(DesignTokens.tertiaryText)
            VStack(alignment: .leading, spacing: 2) {
                content()
            }
            .padding(16)
            .background(DesignTokens.background, in: RoundedRectangle(cornerRadius: DesignTokens.radius))
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.radius).stroke(DesignTokens.separator))
        }
    }
}

private struct ToolListRow<Trailing: View>: View {
    var systemImage: String
    var title: String
    var detail: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14))
                .foregroundStyle(DesignTokens.tertiaryText)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DesignTokens.text)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(DesignTokens.tertiaryText)
                    .lineLimit(2)
            }
            Spacer()
            trailing()
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DesignTokens.tertiaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }
}

private struct ToolEmptyState: View {
    var title: String
    var detail: String
    var systemImage: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 26))
                .foregroundStyle(DesignTokens.neutral400)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DesignTokens.text)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(DesignTokens.tertiaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MonospaceOutput: View {
    var text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(DesignTokens.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
    }
}

private struct TerminalRunRow: View {
    var run: TerminalRun

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("$ \(run.command)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                Spacer()
                if let exitCode = run.exitCode {
                    Text("exit \(exitCode)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(exitCode == 0 ? DesignTokens.success : DesignTokens.danger)
                }
            }
            Text(run.output.isEmpty ? " " : run.output)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(DesignTokens.secondaryText)
                .textSelection(.enabled)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous)
                .fill(DesignTokens.neutral50)
                .overlay(RoundedRectangle(cornerRadius: DesignTokens.radius).stroke(DesignTokens.separator))
        )
    }
}

private struct Metric: View {
    var title: String
    var value: String
    var image: String

    init(_ title: String, _ value: String, _ image: String) {
        self.title = title
        self.value = value
        self.image = image
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: image)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DesignTokens.tertiaryText)
            Text(value)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(DesignTokens.text)
        }
        .padding(14)
        .frame(width: 150, alignment: .leading)
        .background(DesignTokens.neutral50, in: RoundedRectangle(cornerRadius: DesignTokens.radius))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.radius).stroke(DesignTokens.separator))
    }
}

struct WebToolbarButtonStyle: ButtonStyle {
    var isProminent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isProminent ? Color.white : DesignTokens.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(minWidth: isProminent ? 56 : 32, minHeight: 30)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                    .fill(isProminent ? DesignTokens.neutral900 : DesignTokens.neutral100)
            )
            .opacity(configuration.isPressed ? 0.76 : 1)
    }
}

struct WebFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                    .fill(DesignTokens.neutral100)
            )
    }
}

private struct CodeEditorFooterCompat: View {
    var content: String

    var body: some View {
        HStack {
            Text("\(content.split(separator: "\n", omittingEmptySubsequences: false).count) lines")
            Text("\(content.count) characters")
            Spacer()
            Text("Cmd+S save · Esc close")
        }
        .font(.system(size: 11))
        .foregroundStyle(DesignTokens.tertiaryText)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .overlay(alignment: .top) { Rectangle().fill(DesignTokens.separator).frame(height: 1) }
    }
}

private func relativeDate(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: Date())
}

private func formatCost(_ value: Double) -> String {
    if value == 0 { return "$0.00" }
    return String(format: "$%.4f", value)
}

private func cronTitle(_ job: AlwaysOnCronJob) -> String {
    let firstLine = job.prompt.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
    return firstLine.replacingOccurrences(of: #"^#\s+"#, with: "", options: .regularExpression).isEmpty
        ? job.cron
        : firstLine.replacingOccurrences(of: #"^#\s+"#, with: "", options: .regularExpression)
}
