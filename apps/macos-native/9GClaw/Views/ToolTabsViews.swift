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
    @State private var editorOriginalContent = ""
    @State private var editorExpanded = false

    var body: some View {
        GeometryReader { proxy in
            let layout = splitLayout(for: proxy.size.width)
            HStack(spacing: 0) {
                ChatView()
                    .environmentObject(state)
                    .frame(width: layout.chat)
                    .clipped()

                SplitDivider(
                    width: $chatWidth,
                    minWidth: DesignTokens.filesChatMinWidth,
                    maxWidth: layout.maxChat
                )

                filePane
                    .frame(width: editorExpanded ? 0 : layout.tree)
                    .opacity(editorExpanded ? 0 : 1)
                    .clipped()

                if let editorFile {
                    SplitDivider(width: $editorWidth, minWidth: 320, maxWidth: layout.maxEditor, reverse: true)
                    FileEditorPane(
                        file: editorFile,
                        content: $state.selectedFileContent,
                        originalContent: editorOriginalContent,
                        width: editorExpanded ? nil : layout.editor,
                        isExpanded: editorExpanded,
                        onClose: {
                            self.editorFile = nil
                            editorOriginalContent = ""
                            state.selectedFile = nil
                            state.selectedFileContent = ""
                            editorExpanded = false
                        },
                        onToggleExpand: { editorExpanded.toggle() },
                        onRevert: {
                            state.selectedFileContent = editorOriginalContent
                        },
                        onSave: {
                            save(editorFile)
                        }
                    )
                    .environmentObject(state)
                    .frame(width: editorExpanded ? max(320, proxy.size.width - layout.chat - 24) : layout.editor)
                    .clipped()
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
            .background(DesignTokens.background)
        }
        .background(DesignTokens.background)
        .task(id: state.selectedProjectID) { loadFiles() }
    }

    private func splitLayout(for availableWidth: CGFloat) -> (chat: CGFloat, tree: CGFloat, editor: CGFloat, maxChat: CGFloat, maxEditor: CGFloat) {
        let layout = FilesSplitLayoutCalculator.calculate(
            availableWidth: availableWidth,
            requestedChatWidth: chatWidth,
            requestedEditorWidth: editorWidth,
            hasEditor: editorFile != nil,
            editorExpanded: editorExpanded
        )
        return (layout.chat, layout.tree, layout.editor, layout.maxChat, layout.maxEditor)
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
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            ViewThatFits(in: .horizontal) {
                fileToolbarFull
                fileToolbarOverflow
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DesignTokens.separator).frame(height: 1)
        }
    }

    private var fileToolbarFull: some View {
        HStack(spacing: 6) {
            createUploadMenu
            Button { downloadZip() } label: { Image(systemName: "square.and.arrow.down") }
                .buttonStyle(WebToolbarButtonStyle())
                .help(state.t(.download))
            Button { loadFiles() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(WebToolbarButtonStyle())
                .help(state.t(.refresh))
            Button {
                expandedDirectories.removeAll()
                loadFiles()
            } label: { Image(systemName: "rectangle.compress.vertical") }
                .buttonStyle(WebToolbarButtonStyle())
                .help("Collapse all")
            Button { state.activeTab = .chat } label: { Image(systemName: "xmark") }
                .buttonStyle(WebToolbarButtonStyle())
        }
    }

    private var fileToolbarOverflow: some View {
        HStack(spacing: 6) {
            createUploadMenu
            Menu {
                Button(state.t(.download)) { downloadZip() }
                Button(state.t(.refresh)) { loadFiles() }
                Button("Collapse all") {
                    expandedDirectories.removeAll()
                    loadFiles()
                }
                Divider()
                Button("Close") { state.activeTab = .chat }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(WebToolbarButtonStyle())
        }
    }

    private var createUploadMenu: some View {
        Menu {
            Button(state.t(.newFile)) { create(isDirectory: false) }
            Button(state.t(.newFolder)) { create(isDirectory: true) }
            Divider()
            Button(state.t(.uploadFiles)) { upload(allowDirectories: false) }
            Button(state.t(.uploadFolder)) { upload(allowDirectories: true) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(WebToolbarButtonStyle())
        .help(state.t(.newFile))
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
        do {
            let content = try state.workspaceService.readFile(path: file.path)
            state.selectedFileContent = content
            editorOriginalContent = content
        } catch {
            state.selectedFileContent = ""
            editorOriginalContent = ""
            state.errorBanner = error.localizedDescription
        }
    }

    private func save(_ file: WorkspaceFile) {
        do {
            try state.workspaceService.writeFile(path: file.path, content: state.selectedFileContent)
            editorOriginalContent = state.selectedFileContent
            state.statusLine = "\(state.t(.saved)) \(file.name)"
            loadFiles()
            if let updated = files.first(where: { $0.path == file.path }) {
                editorFile = updated
                state.selectedFile = updated
            }
        } catch {
            state.errorBanner = error.localizedDescription
        }
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
        alert.messageText = isDirectory ? state.t(.newFolder) : state.t(.newFile)
        alert.informativeText = state.t(.enterName)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = isDirectory ? state.t(.newFolder) : "untitled.txt"
        alert.accessoryView = field
        alert.addButton(withTitle: state.t(.create))
        alert.addButton(withTitle: state.t(.cancel))
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
        alert.messageText = state.t(.rename)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = file.name
        alert.accessoryView = field
        alert.addButton(withTitle: state.t(.rename))
        alert.addButton(withTitle: state.t(.cancel))
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
        alert.messageText = "\(state.t(.delete)) \(file.name)?"
        alert.informativeText = state.t(.cannotBeUndone)
        alert.addButton(withTitle: state.t(.delete))
        alert.addButton(withTitle: state.t(.cancel))
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
            state.statusLine = "\(state.t(.download)) \(url.lastPathComponent)"
        } catch {
            state.errorBanner = error.localizedDescription
        }
    }
}

struct GitView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ToolPage(title: state.t(.git), subtitle: state.selectedWorkspaceContext?.rootPath ?? state.t(.noProjectSelected)) {
            Button(state.t(.status)) { state.refreshGitStatus() }.buttonStyle(WebToolbarButtonStyle(isProminent: true))
            Button(state.t(.diff)) { state.refreshGitDiff() }.buttonStyle(WebToolbarButtonStyle())
            Button(state.t(.fetch)) { state.runGitFetch() }.buttonStyle(WebToolbarButtonStyle())
            Button(state.t(.pull)) { state.runGitPull() }.buttonStyle(WebToolbarButtonStyle())
            Button(state.t(.push)) { state.runGitPush() }.buttonStyle(WebToolbarButtonStyle())
        } content: {
            MonospaceOutput(text: state.gitOutput.isEmpty ? state.t(.gitStatusPrompt) : state.gitOutput)
        }
        .task { state.refreshGitStatus() }
    }
}

struct ShellView: View {
    @EnvironmentObject private var state: AppState
    @State private var command = "pwd"

    var body: some View {
        ToolPage(title: state.t(.shell), subtitle: state.selectedWorkspaceContext?.rootPath ?? state.t(.noProjectSelected)) {
            HStack(spacing: 8) {
                TextField(state.t(.command), text: $command)
                    .textFieldStyle(WebFieldStyle())
                    .font(.system(size: 13, design: .monospaced))
                    .frame(width: 360)
                    .onSubmit { state.runShell(command: command) }
                Button(state.t(.run)) { state.runShell(command: command) }
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
        ToolPage(title: state.t(.tasks), subtitle: "Task plans and execution queue") {
            TextField("Task title", text: $title).textFieldStyle(WebFieldStyle()).frame(width: 180)
            TextField("Prompt", text: $prompt).textFieldStyle(WebFieldStyle()).frame(width: 280)
            Button(state.t(.queue)) {
                _ = state.taskService.createPlan(title: title.isEmpty ? "Untitled task" : title, prompt: prompt)
                title = ""
                prompt = ""
                state.bumpToolRefresh()
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
    @State private var subtab: MemorySubTab = .projectMemory
    @State private var traceSubtab: MemoryTraceSubTab = .recall
    @State private var selectedTraceID: String?
    @State private var memoryJobs: [MemoryJobKind: MemoryJobState] = Dictionary(
        uniqueKeysWithValues: MemoryJobKind.allCases.map { ($0, MemoryJobState.idle($0)) }
    )

    var body: some View {
        let _ = state.toolRefreshRevision
        let snapshot = currentSnapshot
        VStack(spacing: 0) {
            memoryTopbar(snapshot)

            if let selectedRecord {
                MemoryDetailPage(
                    record: selectedRecord,
                    onBack: { self.selectedRecord = nil },
                    onEdit: { editRecord(selectedRecord) },
                    onToggleDeprecated: { toggleDeprecated(selectedRecord) },
                    onDelete: { deleteRecord(selectedRecord) }
                )
                .environmentObject(state)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        switch subtab {
                        case .projectMemory:
                            projectMemory(snapshot)
                        case .profile:
                            profileMemory(snapshot)
                        case .trace:
                            memoryTrace(snapshot)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .background(DesignTokens.background)
    }

    private var currentSnapshot: MemoryDashboardSnapshot {
        state.memoryService.dashboard(
            query: query,
            projectName: state.selectedProject?.name,
            projectRoot: state.selectedWorkspaceContext?.rootPath,
            isGeneral: state.selectedWorkspaceContext?.isGeneral == true
        )
    }

    private func memoryTopbar(_ snapshot: MemoryDashboardSnapshot) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    TabButton("项目记忆", isActive: subtab == .projectMemory) {
                        selectedRecord = nil
                        subtab = .projectMemory
                    }
                    TabButton("用户画像", isActive: subtab == .profile) {
                        selectedRecord = nil
                        subtab = .profile
                    }
                    TabButton("记忆追踪", isActive: subtab == .trace) {
                        selectedRecord = nil
                        subtab = .trace
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 24)
            .frame(height: 42)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if subtab == .projectMemory {
                        TextField(state.t(.searchMemory), text: $query)
                            .textFieldStyle(WebFieldStyle())
                            .frame(width: 220)
                        Button("搜索") { state.bumpToolRefresh() }
                            .buttonStyle(WebToolbarButtonStyle())
                    }

                    Button(state.t(.refresh)) { refreshMemory() }
                        .buttonStyle(WebToolbarButtonStyle())
                    MemoryJobButton(title: "索引同步", state: job(.index), isProminent: true) { indexMemory() }
                    MemoryJobButton(title: "记忆 Dream", state: job(.dream), isProminent: true) { dreamMemory() }
                    MemoryJobButton(title: "回滚上一次 Dream", state: job(.rollback), isProminent: false) { rollbackDream() }
                        .disabled(snapshot.lastDreamSnapshot?.rollbackReady != true)

                    Menu {
                        Button("导出当前项目记忆") { exportMemory(allProjects: false) }
                        Button("导出全部记忆") { exportMemory(allProjects: true) }
                        Divider()
                        Button("导入当前项目记忆") { importMemory(allProjects: false) }
                        Button("导入全部记忆") { importMemory(allProjects: true) }
                        Divider()
                        Button("清空当前项目记忆", role: .destructive) { clearMemory(allProjects: false) }
                        Button("清空全部记忆", role: .destructive) { clearMemory(allProjects: true) }
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .menuStyle(.borderlessButton)
                }
                .padding(.horizontal, 24)
                .frame(minWidth: 0, alignment: .leading)
            }
            .frame(height: 42)

            HStack(spacing: 10) {
                Text(state.selectedWorkspaceContext?.rootPath ?? state.t(.selectProject))
                    .font(.system(size: 12))
                    .foregroundStyle(DesignTokens.tertiaryText)
                    .lineLimit(1)
                Spacer()
                Text("自动构建：\(snapshot.scheduler.enabled ? "已启用" : "已关闭")")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignTokens.tertiaryText)
                Text("最近索引 \(snapshot.overview.lastIndexedAt.map(relativeDate) ?? state.t(.none))")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignTokens.tertiaryText)
                if let running = memoryJobs.values.first(where: { $0.phase == .running }) {
                    HStack(spacing: 5) {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.55)
                        Text(running.message)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DesignTokens.tertiaryText)
                }
                Text("条目 \(snapshot.overview.totalEntries)")
                    .font(.system(size: 12))
                    .foregroundStyle(DesignTokens.tertiaryText)
            }
            .padding(.horizontal, 24)
            .frame(height: 32)
            .overlay(alignment: .bottom) { Rectangle().fill(DesignTokens.separator).frame(height: 1) }
        }
    }

    private func projectMemory(_ snapshot: MemoryDashboardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            if let meta = snapshot.workspace.projectMeta {
                MemoryProjectContextCard(meta: meta)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                RoutingStatCard(icon: "externaldrive", label: "条目", value: "\(snapshot.workspace.totalFiles)", detail: "active memory records")
                RoutingStatCard(icon: "folder", label: "项目", value: "\(snapshot.workspace.totalProjects)", detail: state.selectedWorkspaceContext?.displayName)
                RoutingStatCard(icon: "bubble.left.and.bubble.right", label: "反馈", value: "\(snapshot.workspace.totalFeedback)", detail: "collaboration feedback")
                RoutingStatCard(icon: "clock", label: "最新", value: snapshot.latestMemoryAt.map(relativeDate) ?? "无", detail: "latest memory update")
            }

            MemoryRecordSection(title: "项目记忆", subtitle: "当前 project 的进展、事实和状态记录", records: snapshot.workspace.projectEntries, empty: snapshot.workspace.workspaceMode == "general" ? "当前没有通用记忆。" : "当前没有项目记忆。") { record in
                selectedRecord = record
            }
            MemoryRecordSection(title: "协作反馈", subtitle: "用户对当前 project 的偏好、约束和交付规则", records: snapshot.workspace.feedbackEntries, empty: "当前没有协作反馈。") { record in
                selectedRecord = record
            }
            if !snapshot.workspace.deprecatedProjectEntries.isEmpty || !snapshot.workspace.deprecatedFeedbackEntries.isEmpty {
                MemoryRecordSection(title: "已弃用记忆", subtitle: "标记为 deprecated 的项目记忆和协作反馈", records: snapshot.workspace.deprecatedProjectEntries + snapshot.workspace.deprecatedFeedbackEntries, empty: "当前没有已弃用记忆。") { record in
                    selectedRecord = record
                }
            }
        }
    }

    private func profileMemory(_ snapshot: MemoryDashboardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            MemorySummaryCard(title: "用户摘要", text: snapshot.userSummary.isEmpty ? "当前还没有汇总后的用户画像；User Notes 会在 Dream 后合并到这里。" : snapshot.userSummary, footnote: state.selectedWorkspaceContext?.rootPath)

            MemoryRecordSection(title: "User Notes", subtitle: "长期用户画像、偏好和背景信息", records: snapshot.records.filter { $0.type == .user && !$0.deprecated }, empty: "暂无用户画像记录。") { record in
                selectedRecord = record
            }

            MemoryRecordSection(title: "反馈画像", subtitle: "从协作反馈中提取的用户偏好", records: snapshot.records.filter { $0.type == .feedback && !$0.deprecated }, empty: "暂无反馈画像。") { record in
                selectedRecord = record
            }
        }
    }

    private func memoryTrace(_ snapshot: MemoryDashboardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 6) {
                TabButton("Recall", isActive: traceSubtab == .recall) {
                    traceSubtab = .recall
                    selectedTraceID = nil
                }
                TabButton("Index", isActive: traceSubtab == .index) {
                    traceSubtab = .index
                    selectedTraceID = nil
                }
                TabButton("Dream", isActive: traceSubtab == .dream) {
                    traceSubtab = .dream
                    selectedTraceID = nil
                }
            }

            let records = traceRecords(snapshot)
            if records.isEmpty {
                ToolEmptyState(title: "暂无追踪记录", detail: traceEmptyDetail, systemImage: "clock.arrow.circlepath")
                    .frame(height: 360)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(traceSelectTitle)
                            .font(.system(size: 14, weight: .semibold))
                        ForEach(records) { trace in
                            Button {
                                selectedTraceID = trace.id
                            } label: {
                                MemoryTraceListRow(trace: trace, selected: selectedTraceID == trace.id || (selectedTraceID == nil && records.first?.id == trace.id))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(width: 300, alignment: .topLeading)

                    MemoryTraceDetail(trace: selectedTrace(records))
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    private var traceSelectTitle: String {
        switch traceSubtab {
        case .recall: "选择一个事例"
        case .index: "选择一条 Index 追踪"
        case .dream: "选择一条 Dream 追踪"
        }
    }

    private var traceEmptyDetail: String {
        switch traceSubtab {
        case .recall: "选择一个事例查看 Recall 详情。"
        case .index: "运行索引同步后这里会显示 Index 追踪。"
        case .dream: "运行记忆 Dream 后这里会显示 Dream 追踪。"
        }
    }

    private func traceRecords(_ snapshot: MemoryDashboardSnapshot) -> [MemoryTraceRecord] {
        switch traceSubtab {
        case .recall: snapshot.caseTraceRecords
        case .index: snapshot.indexTraceRecords
        case .dream: snapshot.dreamTraceRecords
        }
    }

    private func selectedTrace(_ records: [MemoryTraceRecord]) -> MemoryTraceRecord? {
        if let selectedTraceID, let trace = records.first(where: { $0.id == selectedTraceID }) {
            return trace
        }
        return records.first
    }

    private func job(_ kind: MemoryJobKind) -> MemoryJobState {
        memoryJobs[kind] ?? .idle(kind)
    }

    private func setJob(_ kind: MemoryJobKind, phase: MemoryJobPhase, message: String, traceID: String? = nil) {
        let now = Date()
        var next = memoryJobs[kind] ?? .idle(kind)
        next.phase = phase
        next.message = message
        next.traceID = traceID ?? next.traceID
        if phase == .running {
            next.startedAt = now
            next.endedAt = nil
        } else {
            next.endedAt = now
        }
        memoryJobs[kind] = next
    }

    private func indexMemory() {
        guard job(.index).phase != .running else { return }
        setJob(.index, phase: .running, message: "正在索引当前工作区")
        selectedRecord = nil
        let service = state.memoryService
        let projectRoot = state.selectedWorkspaceContext?.rootPath
        let projectName = state.selectedProject?.name
        Task { @MainActor in
            do {
                let snapshot = try await service.runIndexJob(projectRoot: projectRoot, projectName: projectName)
                let traceID = snapshot.indexTraceRecords.first?.id
                setJob(.index, phase: .completed, message: "索引同步完成", traceID: traceID)
                selectedTraceID = traceID
                traceSubtab = .index
                subtab = .trace
                state.statusLine = "Memory index updated"
            } catch {
                setJob(.index, phase: .failed, message: error.localizedDescription)
                state.errorBanner = error.localizedDescription
            }
            state.bumpToolRefresh()
        }
    }

    private func refreshMemory() {
        state.refreshNativeToolData()
        state.bumpToolRefresh()
    }

    private func dreamMemory() {
        guard job(.dream).phase != .running else { return }
        setJob(.dream, phase: .running, message: "正在运行 Memory Dream")
        let service = state.memoryService
        let projectName = state.selectedProject?.name
        let projectRoot = state.selectedWorkspaceContext?.rootPath
        Task { @MainActor in
            let snapshot = await service.runDreamJob(projectName: projectName, projectRoot: projectRoot)
            let traceID = snapshot.dreamTraceRecords.first?.id
            setJob(.dream, phase: .completed, message: "Memory Dream complete", traceID: traceID)
            selectedTraceID = traceID
            state.statusLine = "Memory Dream complete"
            traceSubtab = .dream
            subtab = .trace
            state.bumpToolRefresh()
        }
    }

    private func rollbackDream() {
        guard job(.rollback).phase != .running else { return }
        guard confirmMemoryAction(
            title: "回滚上一次 Dream",
            detail: "回滚会恢复上一次 Dream 前的记忆快照，并覆盖当前记忆结果。不会修改工作区代码文件。"
        ) else { return }
        setJob(.rollback, phase: .running, message: "正在回滚 Dream")
        let service = state.memoryService
        let projectName = state.selectedProject?.name
        let projectRoot = state.selectedWorkspaceContext?.rootPath
        Task { @MainActor in
            do {
                let snapshot = try await service.rollbackDreamJob(projectName: projectName, projectRoot: projectRoot)
                let traceID = snapshot.dreamTraceRecords.first?.id
                setJob(.rollback, phase: .completed, message: "Dream rollback complete", traceID: traceID)
                selectedTraceID = traceID
                traceSubtab = .dream
                subtab = .trace
                state.statusLine = "Rolled back the last Dream"
            } catch {
                setJob(.rollback, phase: .failed, message: error.localizedDescription)
                state.errorBanner = error.localizedDescription
            }
            state.bumpToolRefresh()
        }
    }

    private func clearMemory(allProjects: Bool) {
        guard confirmMemoryAction(
            title: allProjects ? "清空全部记忆" : "清空当前项目记忆",
            detail: allProjects
                ? "此操作会删除所有项目记忆以及全局用户画像。"
                : "此操作会删除当前项目记忆，不会修改工作区代码文件。"
        ) else { return }
        state.memoryService.clear(
            projectName: allProjects ? nil : state.selectedProject?.name,
            projectRoot: allProjects ? nil : state.selectedWorkspaceContext?.rootPath
        )
        selectedRecord = nil
        state.statusLine = allProjects ? "All memory cleared" : "Current project memory cleared"
        state.bumpToolRefresh()
    }

    private func exportMemory(allProjects: Bool) {
        do {
            let data = try state.memoryService.exportBundle(projectName: allProjects ? nil : state.selectedProject?.name)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = allProjects ? "edgeclaw-memory-all-projects.json" : "edgeclaw-memory-current-project.json"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            state.statusLine = allProjects ? "All-project memory exported" : "Current project memory exported"
        } catch {
            state.errorBanner = error.localizedDescription
        }
    }

    private func importMemory(allProjects: Bool) {
        guard confirmMemoryAction(
            title: allProjects ? "导入全部项目记忆" : "导入当前项目记忆",
            detail: allProjects
                ? "导入会覆盖全部项目记忆和全局用户画像，但不会修改工作区代码文件。"
                : "导入会覆盖当前项目记忆，但不会影响其他项目或工作区代码文件。"
        ) else { return }
        do {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.json]
            panel.allowsMultipleSelection = false
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let data = try Data(contentsOf: url)
            try state.memoryService.importBundle(data, projectName: allProjects ? nil : state.selectedProject?.name)
            state.statusLine = allProjects ? "All-project memory imported" : "Current project memory imported"
            state.bumpToolRefresh()
        } catch {
            state.errorBanner = error.localizedDescription
        }
    }

    private func confirmMemoryAction(title: String, detail: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: state.settings.language.resolved() == .chineseSimplified ? "确认" : "Confirm")
        alert.addButton(withTitle: state.t(.cancel))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func editRecord(_ record: MemoryRecord) {
        let alert = NSAlert()
        alert.messageText = record.type == .feedback ? "编辑协作反馈" : "编辑项目记忆"
        alert.informativeText = "只编辑头字段，不直接暴露原始 markdown。"
        alert.addButton(withTitle: state.t(.save))
        alert.addButton(withTitle: state.t(.cancel))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 8
        let nameField = NSTextField(string: record.name)
        let summaryField = NSTextField(string: record.summary)
        stack.addArrangedSubview(nameField)
        stack.addArrangedSubview(summaryField)
        stack.frame = NSRect(x: 0, y: 0, width: 420, height: 58)
        alert.accessoryView = stack
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let updated = try state.memoryService.editRecord(record, name: nameField.stringValue, summary: summaryField.stringValue, projectRoot: state.selectedWorkspaceContext?.rootPath)
            selectedRecord = updated
            state.statusLine = "Memory updated"
            state.bumpToolRefresh()
        } catch {
            state.errorBanner = error.localizedDescription
        }
    }

    private func toggleDeprecated(_ record: MemoryRecord) {
        do {
            try state.memoryService.setDeprecated(record, deprecated: !record.deprecated, projectRoot: state.selectedWorkspaceContext?.rootPath)
            selectedRecord = nil
            state.statusLine = record.deprecated ? "Memory restored" : "Memory deprecated"
            state.bumpToolRefresh()
        } catch {
            state.errorBanner = error.localizedDescription
        }
    }

    private func deleteRecord(_ record: MemoryRecord) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "删除记忆"
        alert.informativeText = "此操作会删除该记忆文件或 native 记录。"
        alert.addButton(withTitle: state.t(.delete))
        alert.addButton(withTitle: state.t(.cancel))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try state.memoryService.delete(record, projectRoot: state.selectedWorkspaceContext?.rootPath)
            selectedRecord = nil
            state.statusLine = "Memory deleted"
            state.bumpToolRefresh()
        } catch {
            state.errorBanner = error.localizedDescription
        }
    }
}

private enum MemorySubTab {
    case projectMemory
    case profile
    case trace
}

private enum MemoryTraceSubTab {
    case recall
    case index
    case dream
}

private struct MemoryJobButton: View {
    var title: String
    var state: MemoryJobState
    var isProminent: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if state.phase == .running {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.55)
                }
                Text(state.phase == .running && !state.message.isEmpty ? state.message : title)
                    .lineLimit(1)
            }
        }
        .buttonStyle(WebToolbarButtonStyle(isProminent: isProminent))
        .disabled(state.phase == .running)
        .help(state.message.isEmpty ? title : state.message)
    }
}

private struct MemoryRecordCard: View {
    var record: MemoryRecord
    var selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(record.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                Spacer()
                Text(record.type.label)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(DesignTokens.accent.opacity(0.12), in: Capsule())
                    .foregroundStyle(DesignTokens.accent)
            }
            Text(relativeDate(record.updatedAt))
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.tertiaryText)
            Text(record.summary)
                .font(.system(size: 13))
                .foregroundStyle(DesignTokens.secondaryText)
                .lineLimit(4)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 142, alignment: .topLeading)
        .background(DesignTokens.background, in: RoundedRectangle(cornerRadius: DesignTokens.radius))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.radius)
                .stroke(selected ? DesignTokens.accent : DesignTokens.separator, lineWidth: selected ? 2 : 1)
        )
    }
}

private struct MemoryRecordSection: View {
    var title: String
    var subtitle: String
    var records: [MemoryRecord]
    var empty: String
    var onSelect: (MemoryRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(DesignTokens.tertiaryText)
            }
            if records.isEmpty {
                Text(empty)
                    .font(.system(size: 13))
                    .foregroundStyle(DesignTokens.tertiaryText)
                    .frame(maxWidth: .infinity, minHeight: 96, alignment: .center)
                    .background(DesignTokens.neutral50, in: RoundedRectangle(cornerRadius: DesignTokens.radius))
                    .overlay(RoundedRectangle(cornerRadius: DesignTokens.radius).stroke(DesignTokens.separator))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                    ForEach(records) { record in
                        Button { onSelect(record) } label: {
                            MemoryRecordCard(record: record, selected: false)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct MemoryProjectContextCard: View {
    var meta: MemoryProjectMeta

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(meta.projectName)
                        .font(.system(size: 18, weight: .semibold))
                    Text(meta.description.isEmpty ? "当前 workspace 就是唯一顶层 project。" : meta.description)
                        .font(.system(size: 13))
                        .foregroundStyle(DesignTokens.secondaryText)
                }
                Spacer()
                Text(meta.status)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(DesignTokens.neutral100, in: Capsule())
            }
            HStack(spacing: 8) {
                if let workspacePath = meta.workspacePath {
                    MemoryChip(text: "项目路径 \(URL(fileURLWithPath: workspacePath).lastPathComponent)")
                }
                MemoryChip(text: meta.sourceType)
            }
        }
        .padding(18)
        .background(DesignTokens.background, in: RoundedRectangle(cornerRadius: DesignTokens.radius))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.radius).stroke(DesignTokens.separator))
    }
}

private struct MemoryChip: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(DesignTokens.neutral100, in: Capsule())
            .foregroundStyle(DesignTokens.secondaryText)
    }
}

private struct MemorySummaryCard: View {
    var title: String
    var text: String
    var footnote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(DesignTokens.secondaryText)
                .textSelection(.enabled)
            if let footnote {
                Text(footnote)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DesignTokens.tertiaryText)
            }
        }
        .padding(16)
        .background(DesignTokens.neutral50, in: RoundedRectangle(cornerRadius: DesignTokens.radius))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.radius).stroke(DesignTokens.separator))
    }
}

private struct MemoryDetailPage: View {
    @EnvironmentObject private var state: AppState
    var record: MemoryRecord
    var onBack: () -> Void
    var onEdit: () -> Void
    var onToggleDeprecated: () -> Void
    var onDelete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Button("← 返回") { onBack() }
                    .buttonStyle(WebToolbarButtonStyle())

                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(record.type.label)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(DesignTokens.tertiaryText)
                        Text(record.name)
                            .font(.system(size: 24, weight: .semibold))
                        Text(record.summary)
                            .font(.system(size: 14))
                            .foregroundStyle(DesignTokens.secondaryText)
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        Button("编辑") { onEdit() }.buttonStyle(WebToolbarButtonStyle())
                        Button(record.deprecated ? "恢复" : "弃用") { onToggleDeprecated() }.buttonStyle(WebToolbarButtonStyle())
                        Button(state.t(.delete)) { onDelete() }.buttonStyle(WebToolbarButtonStyle())
                    }
                }
                .padding(18)
                .background(DesignTokens.background, in: RoundedRectangle(cornerRadius: DesignTokens.radius))
                .overlay(RoundedRectangle(cornerRadius: DesignTokens.radius).stroke(DesignTokens.separator))

                Text(record.content.isEmpty ? record.summary : record.content)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(DesignTokens.secondaryText)
                    .textSelection(.enabled)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DesignTokens.neutral50, in: RoundedRectangle(cornerRadius: DesignTokens.radius))
                    .overlay(RoundedRectangle(cornerRadius: DesignTokens.radius).stroke(DesignTokens.separator))
            }
            .padding(28)
        }
    }
}

private struct MemoryTraceListRow: View {
    var trace: MemoryTraceRecord
    var selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(trace.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text(trace.status)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DesignTokens.success)
            }
            Text(relativeDate(trace.createdAt))
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.tertiaryText)
        }
        .padding(12)
        .background(selected ? DesignTokens.neutral100 : DesignTokens.neutral50, in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.smallRadius).stroke(selected ? DesignTokens.accent : DesignTokens.separator))
    }
}

private struct MemoryTraceDetail: View {
    var trace: MemoryTraceRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let trace {
                MemorySummaryCard(title: trace.title, text: trace.reply.isEmpty ? "暂无输出。" : trace.reply, footnote: "\(trace.trigger) · \(relativeDate(trace.createdAt))")
                traceBlock(title: "Meta", text: trace.meta.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n"))
                traceBlock(title: "注入上下文", text: trace.context)
                traceBlock(title: "工具事件", text: trace.toolEvents)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Reasoning Timeline")
                        .font(.system(size: 14, weight: .semibold))
                    ForEach(trace.steps) { step in
                        HStack(alignment: .top, spacing: 10) {
                            Circle().fill(DesignTokens.accent).frame(width: 7, height: 7).padding(.top, 6)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(step.title)
                                    .font(.system(size: 13, weight: .medium))
                                Text(step.detail)
                                    .font(.system(size: 12))
                                    .foregroundStyle(DesignTokens.tertiaryText)
                            }
                        }
                    }
                }
                .padding(16)
                .background(DesignTokens.background, in: RoundedRectangle(cornerRadius: DesignTokens.radius))
                .overlay(RoundedRectangle(cornerRadius: DesignTokens.radius).stroke(DesignTokens.separator))
            } else {
                ToolEmptyState(title: "暂无追踪记录", detail: "选择一条追踪查看详情。", systemImage: "clock.arrow.circlepath")
                    .frame(height: 260)
            }
        }
    }

    private func traceBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(text.isEmpty ? "暂无记录。" : text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(DesignTokens.secondaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(DesignTokens.neutral50, in: RoundedRectangle(cornerRadius: DesignTokens.radius))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.radius).stroke(DesignTokens.separator))
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
    @State private var newBody = ""
    @State private var newScope: SkillScope = .user
    @State private var newTab: SkillNewTab = .install
    @State private var hubQuery = ""
    @State private var hubResults: [SkillHubSearchResult] = []
    @State private var hubSearching = false
    @State private var hubInstallingSlug: String?
    @State private var forceInstallSlugs: Set<String> = []
    @State private var modalNotice: String?
    @State private var importSource: URL?
    @State private var importSlug = ""

    private var selectedSkill: SkillRecord? {
        state.skillsService.skills.first { $0.id == selectedSkillID }
    }

    var body: some View {
        VStack(spacing: 0) {
            ToolToolbar(
                title: state.t(.skills),
                subtitle: state.selectedWorkspaceContext?.isGeneral == true
                    ? state.t(.generalSkillsOnly)
                    : (state.selectedWorkspaceContext?.rootPath ?? state.t(.noProjectSelected))
            ) {
                Button(state.t(.refresh)) { refresh() }.buttonStyle(WebToolbarButtonStyle())
                Button(state.t(.importAction)) { importSkill() }.buttonStyle(WebToolbarButtonStyle())
                Button(state.t(.newAction)) {
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
                .frame(width: 760, height: 560)
        }
        .task { refresh() }
    }

    private var skillsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                SkillScopeSection(
                    title: state.t(.projectSkills),
                    skills: state.skillsService.skills.filter { $0.scope == .project },
                    selectedSkillID: selectedSkillID,
                    onSelect: select
                )
                .opacity(state.selectedWorkspaceContext?.isGeneral == true ? 0 : 1)
                SkillScopeSection(
                    title: state.t(.userSkills),
                    skills: state.skillsService.skills.filter { $0.scope == .user },
                    selectedSkillID: selectedSkillID,
                    onSelect: select
                )
                if state.skillsService.skills.isEmpty {
                    Text(state.t(.noSkillsYet))
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
                }
                .padding(.horizontal, 18)
                .frame(height: 74)
                .overlay(alignment: .bottom) { Rectangle().fill(DesignTokens.separator).frame(height: 1) }

                TextEditor(text: $editorContent)
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(12)

                HStack {
                    Button(role: .destructive) { delete(skill) } label: {
                        Label(state.t(.delete), systemImage: "trash")
                    }
                    .buttonStyle(WebToolbarButtonStyle())
                    Spacer()
                    if editorContent != originalContent {
                        Button(state.t(.revert)) { editorContent = originalContent }
                            .buttonStyle(WebToolbarButtonStyle())
                    }
                    Button {
                        save(skill)
                    } label: {
                        Label(state.t(.save), systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(WebToolbarButtonStyle(isProminent: true))
                    .disabled(editorContent == originalContent)
                }
                .padding(.horizontal, 18)
                .frame(height: 44)
                .overlay(alignment: .top) { Rectangle().fill(DesignTokens.separator).frame(height: 1) }
            }
        } else {
            ToolEmptyState(title: state.t(.pickSkill), detail: state.t(.pickSkillDetail), systemImage: "sparkles")
        }
    }

    private var newSkillSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(state.t(.newAction))\(state.t(.skills))")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button { showNew = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(WebToolbarButtonStyle())
            }
            .padding(.horizontal, 18)
            .frame(height: 56)
            .overlay(alignment: .bottom) { Rectangle().fill(DesignTokens.separator).frame(height: 1) }

            HStack(spacing: 0) {
                newSkillTab(.install, title: "从 ClawHub 安装", icon: "square.and.arrow.down")
                newSkillTab(.importFolder, title: "从文件夹导入", icon: "folder.badge.plus")
                newSkillTab(.create, title: "自己写一个", icon: "pencil")
                Spacer()
            }
            .padding(.horizontal, 18)
            .frame(height: 42)
            .overlay(alignment: .bottom) { Rectangle().fill(DesignTokens.separator).frame(height: 1) }

            VStack(spacing: 0) {
                if let modalNotice {
                    Text(modalNotice)
                        .font(.system(size: 12))
                        .foregroundStyle(DesignTokens.tertiaryText)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                switch newTab {
                case .install:
                    clawHubInstallPane
                case .importFolder:
                    importSkillPane
                case .create:
                    createSkillPane
                }
            }
        }
    }

    private func newSkillTab(_ tab: SkillNewTab, title: String, icon: String) -> some View {
        Button {
            newTab = tab
            modalNotice = nil
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                Text(title)
                    .font(.system(size: 13, weight: newTab == tab ? .semibold : .regular))
            }
            .foregroundStyle(newTab == tab ? DesignTokens.text : DesignTokens.tertiaryText)
            .padding(.horizontal, 12)
            .frame(height: 40)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(newTab == tab ? DesignTokens.neutral900 : Color.clear)
                    .frame(height: 2)
            }
        }
        .buttonStyle(.plain)
    }

    private var scopePicker: some View {
        HStack(spacing: 8) {
            Text(state.t(.scope))
                .font(.system(size: 12))
                .foregroundStyle(DesignTokens.tertiaryText)
            Picker(state.t(.scope), selection: $newScope) {
                Text(state.t(.user)).tag(SkillScope.user)
                Text(state.t(.projects)).tag(SkillScope.project)
            }
            .pickerStyle(.segmented)
            .frame(width: 140)
            .disabled(state.selectedWorkspaceContext?.isGeneral == true)
        }
        .fixedSize(horizontal: true, vertical: false)
        .onAppear {
            if state.selectedWorkspaceContext?.isGeneral == true {
                newScope = .user
            }
        }
    }

    private var clawHubInstallPane: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(DesignTokens.tertiaryText)
                TextField("在 clawhub.com 搜索...", text: $hubQuery)
                    .textFieldStyle(.plain)
                    .onSubmit { searchClawHub() }
                if hubSearching {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 8)
                scopePicker
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(DesignTokens.background, in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius))
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.smallRadius).stroke(DesignTokens.separator))
            .padding(.horizontal, 18)

            ScrollView {
                LazyVStack(spacing: 8) {
                    if hubResults.isEmpty {
                        ToolEmptyState(title: hubQuery.isEmpty ? "输入关键词搜索 clawhub.com。" : "没有搜索结果", detail: hubQuery.isEmpty ? "" : "换一个关键词再试。", systemImage: "sparkles")
                            .frame(height: 260)
                    } else {
                        ForEach(hubResults) { result in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(result.name)
                                        .font(.system(size: 13, weight: .semibold))
                                    Text(result.slug)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(DesignTokens.tertiaryText)
                                }
                                Spacer()
                                if let score = result.score {
                                    Text(String(format: "%.2f", score))
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(DesignTokens.tertiaryText)
                                }
                                Button {
                                    installClawHub(result)
                                } label: {
                                    HStack(spacing: 5) {
                                        if hubInstallingSlug == result.slug {
                                            ProgressView()
                                                .controlSize(.small)
                                                .scaleEffect(0.7)
                                        }
                                        Text(forceInstallSlugs.contains(result.slug) ? "强制安装" : "安装")
                                    }
                                }
                                .buttonStyle(WebToolbarButtonStyle(isProminent: true))
                                .disabled(hubInstallingSlug != nil && hubInstallingSlug != result.slug)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(DesignTokens.neutral50, in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius))
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }
        }
    }

    private var importSkillPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Button {
                    chooseImportFolder()
                } label: {
                    Label("选择文件夹", systemImage: "folder")
                }
                .buttonStyle(WebToolbarButtonStyle(isProminent: true))
                Text(importSource?.path ?? "请选择包含 SKILL.md 的文件夹")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(DesignTokens.tertiaryText)
                    .lineLimit(1)
            }
            if let importSource {
                let validation = state.skillsService.validate(source: importSource)
                SkillValidationSummary(validation: validation)
                Button("导入") { importChosenSkill(validation: validation) }
                    .buttonStyle(WebToolbarButtonStyle(isProminent: true))
                    .disabled(!validation.ok)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
    }

    private var createSkillPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                SettingsTextFieldCompat(state.t(.name), text: $newName)
                SettingsTextFieldCompat(state.t(.description), text: $newDescription)
            }
            TextEditor(text: $newBody)
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(DesignTokens.neutral50, in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius))
                .overlay(RoundedRectangle(cornerRadius: DesignTokens.smallRadius).stroke(DesignTokens.separator))
            HStack {
                Spacer()
                Button(state.t(.cancel)) { showNew = false }.buttonStyle(WebToolbarButtonStyle())
                Button(state.t(.create)) { createSkill() }.buttonStyle(WebToolbarButtonStyle(isProminent: true))
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
    }

    private func refresh() {
        state.refreshNativeToolData()
        if selectedSkillID == nil {
            select(state.skillsService.skills.first)
        }
        state.bumpToolRefresh()
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
            let slug = derivedSkillSlug(name: newName, fallback: newDescription)
            let skill = try state.skillsService.create(
                scope: newScope,
                projectPath: state.selectedWorkspaceContext?.isGeneral == true ? nil : state.selectedWorkspaceContext?.rootPath,
                slug: slug,
                name: newName,
                description: newDescription
            )
            if !newBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let content = """
                ---
                name: \(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? slug : newName)
                description: \(newDescription)
                ---

                \(newBody)

                """
                _ = try state.skillsService.write(skill, content: content)
            }
            showNew = false
            newSlug = ""
            newName = ""
            newDescription = ""
            newBody = ""
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

    private func searchClawHub() {
        guard !hubSearching else { return }
        hubSearching = true
        modalNotice = nil
        let query = hubQuery
        let service = state.skillsService
        Task.detached(priority: .userInitiated) {
            let result = Result { try service.clawHubSearch(query: query) }
            await MainActor.run {
                switch result {
                case .success(let results):
                    hubResults = results
                case .failure(let error):
                    modalNotice = error.localizedDescription
                    hubResults = []
                }
                hubSearching = false
            }
        }
    }

    private func installClawHub(_ result: SkillHubSearchResult) {
        guard hubInstallingSlug == nil else { return }
        hubInstallingSlug = result.slug
        modalNotice = nil
        let force = forceInstallSlugs.contains(result.slug)
        let scope = state.selectedWorkspaceContext?.isGeneral == true ? SkillScope.user : newScope
        let projectPath = scope == .project ? state.selectedWorkspaceContext?.rootPath : nil
        let service = state.skillsService
        Task.detached(priority: .userInitiated) {
            do {
                let installed = try service.clawHubInstall(
                    slug: result.slug,
                    force: force,
                    scope: scope,
                    projectPath: projectPath
                )
                await MainActor.run {
                    if installed.installed, let skill = installed.skill {
                        showNew = false
                        refresh()
                        select(skill)
                    } else if installed.needsForce {
                        forceInstallSlugs.insert(result.slug)
                        modalNotice = "该 skill 被标记为需要确认。再次点击强制安装。"
                    } else {
                        modalNotice = installed.stderr.isEmpty ? installed.stdout : installed.stderr
                    }
                    hubInstallingSlug = nil
                }
            } catch {
                await MainActor.run {
                    modalNotice = error.localizedDescription
                    hubInstallingSlug = nil
                }
            }
        }
    }

    private func chooseImportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importSource = url
    }

    private func importChosenSkill(validation: SkillValidationResult) {
        guard validation.ok, let importSource else { return }
        do {
            let scope = state.selectedWorkspaceContext?.isGeneral == true ? SkillScope.user : newScope
            let skill = try state.skillsService.importFolder(
                source: importSource,
                scope: scope,
                projectPath: scope == .project ? state.selectedWorkspaceContext?.rootPath : nil,
                slug: nil,
                overwrite: false
            )
            showNew = false
            refresh()
            select(skill)
        } catch {
            modalNotice = error.localizedDescription
        }
    }

    private func derivedSkillSlug(name: String, fallback: String) -> String {
        let source = [name, fallback, "skill"]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "skill"
        var slug = source
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9._-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
        if slug.isEmpty {
            slug = "skill"
        }
        if slug.count > 80 {
            slug = String(slug.prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
        }
        return slug.isEmpty ? "skill" : slug
    }
}

private enum SkillNewTab {
    case install
    case importFolder
    case create
}

private struct SkillValidationSummary: View {
    var validation: SkillValidationResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(validation.ok ? "校验通过" : "校验失败", systemImage: validation.ok ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(validation.ok ? DesignTokens.success : DesignTokens.danger)
            Text("\(validation.fileCount) files · \(ByteCountFormatter.string(fromByteCount: Int64(validation.totalBytes), countStyle: .file))")
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.tertiaryText)
            ForEach(validation.hardFails + validation.warnings) { issue in
                Text(issue.message)
                    .font(.system(size: 11))
                    .foregroundStyle(validation.hardFails.contains(issue) ? DesignTokens.danger : DesignTokens.warning)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.neutral50, in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.smallRadius).stroke(DesignTokens.separator))
    }
}

struct DashboardView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        let snapshot = state.routingService.dashboard(projects: state.projects, projectFilter: state.selectedProject?.name)
        let baseline = max(snapshot.estimatedCost + snapshot.savedCost, snapshot.estimatedCost)
        let savingsRate = baseline > 0 ? snapshot.savedCost / baseline : 0
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        if state.selectedProject != nil {
                            Text("← 总计")
                                .font(.system(size: 13))
                                .foregroundStyle(DesignTokens.tertiaryText)
                        }
                        Text(state.t(.routing))
                            .font(.system(size: 20, weight: .semibold))
                        Text(state.t(.modelRoutingSummary))
                            .font(.system(size: 13))
                            .foregroundStyle(DesignTokens.tertiaryText)
                    }
                    Spacer()
                    Button {
                        state.bumpToolRefresh()
                    } label: {
                        Label(state.t(.refresh), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(WebToolbarButtonStyle())
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    RoutingStatCard(icon: "waveform.path.ecg", label: state.t(.requests), value: "\(snapshot.routedSessions)", detail: "\(snapshot.totalSessions) sessions")
                    RoutingStatCard(icon: "sum", label: state.t(.tokens), value: formatTokens(snapshot.totalTokens), detail: "input/output recorded by native agent")
                    RoutingStatCard(icon: "dollarsign", label: state.t(.cost), value: formatCost(snapshot.estimatedCost), detail: baseline > 0 ? "不走 Router \(formatCost(baseline))" : nil, hint: snapshot.savedCost > 0 ? "↗ 节省 \(formatCost(snapshot.savedCost)) (\(Int((savingsRate * 100).rounded()))%)" : nil)
                }

                ToolSection(title: state.t(.recentRoutes)) {
                    if snapshot.recentSessions.isEmpty {
                        Text(state.t(.noRoutingActivity))
                            .font(.system(size: 13))
                            .foregroundStyle(DesignTokens.tertiaryText)
                            .padding(.vertical, 24)
                    } else {
                        HStack {
                            Text(state.t(.session))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(state.t(.projects))
                                .frame(width: 140, alignment: .leading)
                            Text(state.t(.tokens))
                                .frame(width: 80, alignment: .trailing)
                            Text(state.t(.cost))
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

                if !snapshot.recentSessions.isEmpty {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            costCell(title: "实际开销", value: formatCost(snapshot.estimatedCost), detail: "\(snapshot.routedSessions) routed sessions · \(formatTokens(snapshot.totalTokens)) tokens")
                            Divider()
                            costCell(title: "不走 Router 开销", value: formatCost(baseline), detail: "按所有路由 token 都交给主模型估算。")
                            Divider()
                            costCell(title: "节省", value: formatCost(snapshot.savedCost), detail: baseline > 0 ? "相对基准 \(Int((savingsRate * 100).rounded()))%" : "暂无基准")
                                .foregroundStyle(DesignTokens.success)
                        }
                        .frame(height: 130)
                        Divider()
                        ForEach(snapshot.recentSessions.prefix(8)) { session in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(session.title)
                                        .font(.system(size: 13, weight: .semibold))
                                        .lineLimit(1)
                                    Text("\(session.byTier.keys.sorted().first ?? "RECORDED") · \(formatTokens(session.totalTokens)) tokens · \(relativeDate(session.lastActiveAt))")
                                        .font(.system(size: 11))
                                        .foregroundStyle(DesignTokens.tertiaryText)
                                }
                                Spacer()
                                Text(formatCost(session.estimatedCost))
                                    .font(.system(size: 12, design: .monospaced))
                                Text(session.savedCost > 0 ? "节省 \(formatCost(session.savedCost))" : "—")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(DesignTokens.success)
                                    .frame(width: 100, alignment: .trailing)
                            }
                            .padding(.horizontal, 18)
                            .frame(height: 58)
                            Divider()
                        }
                    }
                    .background(DesignTokens.success.opacity(0.055), in: RoundedRectangle(cornerRadius: DesignTokens.radius))
                    .overlay(RoundedRectangle(cornerRadius: DesignTokens.radius).stroke(DesignTokens.success.opacity(0.35)))
                }
            }
            .frame(maxWidth: 960, alignment: .topLeading)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
        }
        .background(DesignTokens.background)
    }

    private func costCell(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DesignTokens.tertiaryText)
            Text(value)
                .font(.system(size: 22, weight: .semibold))
                .monospacedDigit()
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(DesignTokens.tertiaryText)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct AlwaysOnView: View {
    @EnvironmentObject private var state: AppState
    @State private var subtab: AlwaysOnSubTab = .items
    @State private var selectedPlan: AlwaysOnPlan?
    @State private var selectedRun: AlwaysOnRunHistory?

    var body: some View {
        guard let context = state.selectedWorkspaceContext, !context.isGeneral else {
            return AnyView(ToolEmptyState(title: state.t(.pickProject), detail: state.t(.alwaysOnProjectOnly), systemImage: "dot.radiowaves.left.and.right"))
        }
        let plans = state.alwaysOnService.plans(projectRoot: context.rootPath)
        let cronJobs = state.alwaysOnService.cronJobs(projectRoot: context.rootPath)
        let history = state.alwaysOnService.runHistory(projectRoot: context.rootPath)
        return AnyView(
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    TabButton(state.t(.plansCronJobs), isActive: subtab == .items) { subtab = .items; selectedRun = nil }
                    TabButton(state.t(.runHistory), isActive: subtab == .history) { subtab = .history; selectedPlan = nil }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(height: 36)
                .overlay(alignment: .bottom) { Rectangle().fill(DesignTokens.separator).frame(height: 1) }

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(state.t(.alwaysOn))
                                    .font(.system(size: 20, weight: .semibold))
                                Text(state.t(.backgroundDiscoveryAgent))
                                    .font(.system(size: 13))
                                    .foregroundStyle(DesignTokens.tertiaryText)
                            }
                            Spacer()
                            Button(state.t(.refresh)) { state.bumpToolRefresh() }.buttonStyle(WebToolbarButtonStyle())
                            Button(state.t(.discover)) {
                                startDiscovery(context: context)
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
                Text(state.t(.noActivePlans))
                    .font(.system(size: 13))
                    .foregroundStyle(DesignTokens.tertiaryText)
                    .padding(18)
            } else {
                ForEach(plans) { plan in
                    ToolListRow(systemImage: "sparkles", title: plan.title, detail: "\(plan.status.rawValue) · \(relativeDate(plan.updatedAt))") {
                        HStack(spacing: 6) {
                            Button(state.t(.review)) { selectedPlan = plan }.buttonStyle(WebToolbarButtonStyle())
                            Button(state.t(.run)) {
                                runPlan(plan, projectRoot: projectRoot)
                            }.buttonStyle(WebToolbarButtonStyle(isProminent: true))
                            Button(state.t(.archive)) {
                                try? state.alwaysOnService.archive(plan: plan, projectRoot: projectRoot)
                                state.bumpToolRefresh()
                            }.buttonStyle(WebToolbarButtonStyle())
                        }
                    }
                }
                ForEach(cronJobs) { job in
                    ToolListRow(systemImage: "timer", title: cronTitle(job), detail: "\(job.status.rawValue) · \(job.cron)") {
                        Text(job.recurring ? state.t(.recurring) : state.t(.oneShot))
                    }
                }
            }
        }
        .padding(18)
        .background(DesignTokens.background, in: RoundedRectangle(cornerRadius: DesignTokens.radius))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.radius).stroke(DesignTokens.separator))
    }

    private func startDiscovery(context: WorkspaceContext) {
        let title = "Discovery: \(context.displayName)"
        let prompt = """
        Run Always-On discovery for \(context.displayName).

        Inspect the workspace, identify useful background maintenance or monitoring work, then create or update Always-On discovery plan files under `.claude/always-on/`.
        """
        do {
            _ = try state.alwaysOnService.createDiscoveryPlan(
                projectRoot: context.rootPath,
                title: title,
                prompt: prompt
            )
            state.startDraftSession(project: state.selectedProject)
            _ = state.createSessionForSelectedProject(title: title)
            state.composerText = prompt
            state.activeTab = .chat
            state.sendComposerMessage()
        } catch {
            state.errorBanner = error.localizedDescription
        }
    }

    private func runPlan(_ plan: AlwaysOnPlan, projectRoot: String) {
        let title = "Always-On: \(plan.title)"
        let prompt = """
        Execute this Always-On plan in the current workspace.

        Plan title: \(plan.title)
        Plan file: \(plan.planFilePath)

        \(plan.content.isEmpty ? plan.summary : plan.content)
        """
        do {
            state.startDraftSession(project: state.selectedProject)
            let session = state.createSessionForSelectedProject(title: title)
            _ = try state.alwaysOnService.startPlanRun(
                plan: plan,
                projectRoot: projectRoot,
                sessionId: session?.id
            )
            state.composerText = prompt
            state.activeTab = .chat
            state.sendComposerMessage()
        } catch {
            state.errorBanner = error.localizedDescription
        }
    }

    private func planDetail(_ plan: AlwaysOnPlan, projectRoot: String) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Button {
                selectedPlan = nil
            } label: {
                Label(state.t(.back), systemImage: "arrow.left")
            }
            .buttonStyle(WebToolbarButtonStyle())
            Text(plan.title)
                .font(.system(size: 20, weight: .semibold))
            if !plan.summary.isEmpty {
                Text(plan.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(DesignTokens.secondaryText)
            }
            MarkdownPreview(text: plan.content.isEmpty ? state.t(.noPlanContent) : plan.content)
            Text(plan.planFilePath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(DesignTokens.tertiaryText)
        }
    }

    private func historyView(_ history: [AlwaysOnRunHistory]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let selectedRun {
                Button { self.selectedRun = nil } label: { Label(state.t(.back), systemImage: "arrow.left") }
                    .buttonStyle(WebToolbarButtonStyle())
                Text(selectedRun.title)
                    .font(.system(size: 20, weight: .semibold))
                MonospaceOutput(text: selectedRun.outputLog.isEmpty ? state.t(.noOutputLog) : selectedRun.outputLog)
                    .frame(minHeight: 360)
            } else if history.isEmpty {
                Text(state.t(.noAlwaysOnRuns))
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
    var originalContent: String
    var width: CGFloat?
    var isExpanded: Bool
    var onClose: () -> Void
    var onToggleExpand: () -> Void
    var onRevert: () -> Void
    var onSave: () -> Void
    @State private var markdownPreview = false

    private var isBinaryFile: Bool {
        isProbablyBinary(file.path)
    }

    private var canEditText: Bool {
        !file.isImage && !isBinaryFile
    }

    private var isDirty: Bool {
        content != originalContent
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: file.isImage ? "photo" : "doc.text")
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(file.name)
                            .font(.system(size: 13, weight: .semibold))
                        if file.isHTML {
                            Button {
                                openHTMLPreview()
                            } label: {
                                Image(systemName: "eye")
                                    .font(.system(size: 11, weight: .semibold))
                                    .frame(width: 22, height: 22)
                            }
                            .buttonStyle(InlineIconButtonStyle(tint: DesignTokens.accent))
                            .help(state.t(.openHTML))
                            .accessibilityLabel(state.t(.openHTML))
                        }
                    }
                    Text(file.relativePath)
                        .font(.system(size: 10.5, design: .monospaced))
                        .lineLimit(1)
                        .foregroundStyle(DesignTokens.tertiaryText)
                }
                Spacer(minLength: 8)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if isDirty {
                            Text(state.t(.unsaved))
                                .font(.system(size: 10, weight: .bold))
                                .tracking(0.5)
                                .foregroundStyle(DesignTokens.warning)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(DesignTokens.warning.opacity(0.10), in: Capsule())
                        }
                        if file.isMarkdown {
                            Button(markdownPreview ? "Edit" : "Preview") { markdownPreview.toggle() }
                                .buttonStyle(WebToolbarButtonStyle())
                        }
                        if file.isHTML {
                            Button {
                                openHTMLPreview()
                            } label: {
                                Image(systemName: "eye")
                            }
                            .buttonStyle(WebToolbarButtonStyle())
                            .help(state.t(.openHTML))
                            .accessibilityLabel(state.t(.openHTML))
                        }
                        Button { download() } label: { Image(systemName: "square.and.arrow.down") }
                            .buttonStyle(WebToolbarButtonStyle())
                            .help(state.t(.download))
                        Button { onRevert() } label: { Image(systemName: "arrow.uturn.backward") }
                            .buttonStyle(WebToolbarButtonStyle())
                            .disabled(!isDirty || !canEditText)
                            .help(state.t(.revert))
                        Button(state.t(.save)) { onSave() }
                            .buttonStyle(WebToolbarButtonStyle(isProminent: true))
                            .disabled(!isDirty || !canEditText)
                            .keyboardShortcut("s", modifiers: .command)
                        Button { onToggleExpand() } label: { Image(systemName: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }
                            .buttonStyle(WebToolbarButtonStyle())
                        Button { onClose() } label: { Image(systemName: "xmark") }
                            .buttonStyle(WebToolbarButtonStyle())
                    }
                    .frame(minWidth: 0, alignment: .trailing)
                }
                .frame(maxWidth: 360, alignment: .trailing)
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
            } else if isBinaryFile {
                ToolEmptyState(title: "Binary File", detail: "\(file.name) cannot be displayed in the text editor.", systemImage: "doc.zipper")
            } else {
                FileContentTextEditor(
                    text: $content,
                    fontSize: CGFloat(state.settings.codeEditor.fontSize),
                    wordWrap: state.settings.codeEditor.wordWrap,
                    onSave: {
                        if isDirty {
                            onSave()
                        }
                    }
                )
            }
            CodeEditorFooterCompat(content: content, isDirty: isDirty)
        }
        .frame(width: width)
        .frame(maxWidth: isExpanded ? .infinity : nil, maxHeight: .infinity)
        .background(DesignTokens.background)
    }

    private func openHTMLPreview() {
        NSWorkspace.shared.open(URL(fileURLWithPath: file.path))
        state.statusLine = "\(state.t(.openHTML)) \(file.name)"
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
    @EnvironmentObject private var state: AppState
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
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(InlineIconButtonStyle(tint: DesignTokens.accent))
                .help(state.t(.openHTML))
                .accessibilityLabel(state.t(.openHTML))
            }
        }
        .contextMenu {
            Button(state.t(.rename), action: onRename)
            Button(state.t(.delete), role: .destructive, action: onDelete)
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

private struct InlineIconButtonStyle: ButtonStyle {
    var tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(tint)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                    .fill(configuration.isPressed ? tint.opacity(0.16) : tint.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                    .stroke(tint.opacity(0.14), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.74 : 1)
    }
}

private struct FileContentTextEditor: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat
    var wordWrap: Bool
    var onSave: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !wordWrap
        scrollView.borderType = .noBorder

        let textView = FileTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.usesFontPanel = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = NSColor.labelColor
        textView.insertionPointColor = NSColor.controlAccentColor
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.textContainer?.lineFragmentPadding = 0
        textView.string = text
        textView.onSave = { context.coordinator.save() }
        applyWrap(wordWrap, to: textView, in: scrollView)

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.onSave = { context.coordinator.save() }
        scrollView.hasHorizontalScroller = !wordWrap
        applyWrap(wordWrap, to: textView, in: scrollView)
    }

    private func applyWrap(_ enabled: Bool, to textView: NSTextView, in scrollView: NSScrollView) {
        if enabled {
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        } else {
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = [.width]
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: FileContentTextEditor
        weak var textView: FileTextView?

        init(_ parent: FileContentTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        @MainActor
        func save() {
            parent.onSave()
        }
    }
}

private final class FileTextView: NSTextView {
    var onSave: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        let isSave = event.charactersIgnoringModifiers?.lowercased() == "s" &&
            event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
        if isSave {
            Task { @MainActor in
                onSave()
            }
            return
        }
        super.keyDown(with: event)
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
        NativeMarkdownView(text: text, fontSize: 13, lineSpacing: 5)
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
    @EnvironmentObject private var state: AppState
    @Binding var width: CGFloat
    var minWidth: CGFloat
    var maxWidth: CGFloat
    var reverse = false
    @State private var startWidth: CGFloat = 0
    @State private var dragging = false
    @State private var hovering = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.clear)
                .frame(width: 12)
            Rectangle()
                .fill(dragging || hovering ? DesignTokens.accent.opacity(0.60) : DesignTokens.separator)
                .frame(width: dragging ? 3 : 1)
        }
            .frame(width: 12)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if !dragging {
                            dragging = true
                            startWidth = clamped(width)
                        }
                        let delta = reverse ? -value.translation.width : value.translation.width
                        width = clamped(startWidth + delta)
                    }
                    .onEnded { _ in dragging = false }
            )
            .onHover { inside in
                hovering = inside
                if inside {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .help(state.t(.dragToResize))
    }

    private func clamped(_ value: CGFloat) -> CGFloat {
        let lower = min(minWidth, maxWidth)
        let upper = max(lower, maxWidth)
        return min(upper, max(lower, value))
    }
}

struct FilesSplitLayout: Equatable {
    var chat: CGFloat
    var tree: CGFloat
    var editor: CGFloat
    var maxChat: CGFloat
    var maxEditor: CGFloat
}

enum FilesSplitLayoutCalculator {
    static func calculate(
        availableWidth: CGFloat,
        requestedChatWidth: CGFloat,
        requestedEditorWidth: CGFloat,
        hasEditor: Bool,
        editorExpanded: Bool
    ) -> FilesSplitLayout {
        let dividerWidth: CGFloat = hasEditor ? 24 : 12
        let contentWidth = max(availableWidth - dividerWidth, 1)
        let preferredMinChat: CGFloat = 320
        let preferredMinTree: CGFloat = 240
        let preferredMinEditor: CGFloat = hasEditor ? 320 : 0
        let compressedMinChat: CGFloat = 240
        let compressedMinTree: CGFloat = 180
        let compressedMinEditor: CGFloat = hasEditor ? 240 : 0

        var editor = hasEditor && !editorExpanded ? min(max(requestedEditorWidth, preferredMinEditor), 900) : 0
        var chat = min(max(requestedChatWidth, preferredMinChat), 720)
        var tree = contentWidth - chat - editor

        if tree < preferredMinTree {
            var deficit = preferredMinTree - tree
            let editorReduction = min(max(0, editor - compressedMinEditor), deficit)
            editor -= editorReduction
            deficit -= editorReduction
            let chatReduction = min(max(0, chat - compressedMinChat), deficit)
            chat -= chatReduction
            tree = contentWidth - chat - editor
        }

        if tree < compressedMinTree {
            tree = compressedMinTree
            let total = chat + tree + editor
            if total > contentWidth {
                let scale = contentWidth / total
                chat = max(1, chat * scale)
                tree = max(1, tree * scale)
                editor = max(0, editor * scale)
            }
        }

        let maxEditor = hasEditor ? max(compressedMinEditor, min(900, contentWidth - compressedMinChat - compressedMinTree)) : 0
        let maxChat = max(compressedMinChat, min(720, contentWidth - compressedMinTree - (hasEditor ? compressedMinEditor : 0)))
        return FilesSplitLayout(chat: chat, tree: tree, editor: editor, maxChat: maxChat, maxEditor: maxEditor)
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

private struct RoutingStatCard: View {
    var icon: String
    var label: String
    var value: String
    var detail: String?
    var hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DesignTokens.tertiaryText)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DesignTokens.tertiaryText)
            }
            Text(value)
                .font(.system(size: 28, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(DesignTokens.text)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.tertiaryText)
                    .lineLimit(2)
            }
            if let hint {
                Text(hint)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DesignTokens.success)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(DesignTokens.background, in: RoundedRectangle(cornerRadius: DesignTokens.radius))
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
            .frame(minWidth: isProminent ? 56 : 32, minHeight: 32)
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
    @EnvironmentObject private var state: AppState
    var content: String
    var isDirty: Bool = false

    var body: some View {
        HStack {
            Text(state.t(.linesFormat, content.split(separator: "\n", omittingEmptySubsequences: false).count))
            Text(state.t(.charactersFormat, content.count))
            Spacer()
            if isDirty {
                Text(state.t(.unsavedChanges))
                    .foregroundStyle(DesignTokens.warning)
            }
            Text(state.t(.saveShortcut))
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
    if abs(value) < 0.01 { return String(format: "$%.4f", value) }
    return String(format: "$%.2f", value)
}

private func formatTokens(_ value: Int) -> String {
    if value >= 1_000_000 {
        return String(format: "%.2fM", Double(value) / 1_000_000)
    }
    if value >= 1_000 {
        return String(format: "%.1fk", Double(value) / 1_000)
    }
    return "\(value)"
}

private func cronTitle(_ job: AlwaysOnCronJob) -> String {
    let firstLine = job.prompt.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
    return firstLine.replacingOccurrences(of: #"^#\s+"#, with: "", options: .regularExpression).isEmpty
        ? job.cron
        : firstLine.replacingOccurrences(of: #"^#\s+"#, with: "", options: .regularExpression)
}
