import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct FilesView: View {
    @EnvironmentObject private var state: AppState
    @State private var files: [WorkspaceFile] = []
    @State private var fileListing: WorkspaceFileListing?
    @State private var isLoadingFiles = false
    @State private var fileListError: String?
    @State private var expandedDirectories: Set<String> = []
    @State private var browserWidth = FileWorkspaceLayoutMetrics.browserDefaultWidth
    @State private var editorFile: WorkspaceFile?
    @State private var editorOriginalContent = ""
    @State private var editorLoadState: FileEditorLoadState = .idle
    @State private var editorExpanded = false
    @State private var searchText = ""
    @State private var inlineEdit: FileInlineEdit?
    @State private var isFileDropTarget = false

    var body: some View {
        GeometryReader { proxy in
            let browserMax = min(FileWorkspaceLayoutMetrics.browserMaxWidth, proxy.size.width * 0.52)
            let clampedBrowserWidth = min(max(browserWidth, FileWorkspaceLayoutMetrics.browserMinWidth), browserMax)
            HStack(spacing: 0) {
                filePane
                    .frame(width: editorExpanded ? 0 : clampedBrowserWidth)
                    .opacity(editorExpanded ? 0 : 1)
                    .clipped()

                if !editorExpanded {
                    SplitDivider(
                        width: $browserWidth,
                        minWidth: FileWorkspaceLayoutMetrics.browserMinWidth,
                        maxWidth: browserMax
                    )
                }

                if let editorFile {
                    FileEditorPane(
                        file: editorFile,
                        content: $state.selectedFileContent,
                        originalContent: editorOriginalContent,
                        width: nil,
                        isExpanded: editorExpanded,
                        onClose: {
                            self.editorFile = nil
                            editorOriginalContent = ""
                            editorLoadState = .idle
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
                        },
                        loadState: editorLoadState
                    )
                    .environmentObject(state)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                } else {
                    fileEmptyEditor
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
            .background(DesignTokens.background)
        }
        .background(DesignTokens.background)
        .task(id: state.selectedProjectID) { loadFiles() }
    }

    private var filePane: some View {
        VStack(spacing: 0) {
            fileHeader
            ScrollView {
                LazyVStack(alignment: .leading, spacing: FileWorkspaceLayoutMetrics.treeSpacing) {
                    if isLoadingFiles && files.isEmpty {
                        FilePaneStatusView(
                            title: filesText(english: "Loading files", chinese: "正在加载文件"),
                            detail: state.selectedWorkspaceContext?.rootPath ?? state.t(.noProjectSelected),
                            systemImage: "arrow.clockwise",
                            isLoading: true
                        )
                        .padding(.top, 56)
                    } else if let fileListError, files.isEmpty {
                        FilePaneStatusView(
                            title: filesText(english: "Could not load files", chinese: "无法加载文件"),
                            detail: fileListError,
                            systemImage: "exclamationmark.triangle"
                        )
                        .padding(.top, 56)
                    } else if filteredFiles.isEmpty, inlineEdit == nil {
                        FilePaneStatusView(
                            title: emptyFilesTitle,
                            detail: emptyFilesDetail,
                            systemImage: emptyFilesIcon
                        )
                        .padding(.top, 56)
                    } else {
                        if let inlineEdit, inlineEdit.isCreate, inlineEdit.parentPath == nil {
                            FileInlineEditRow(edit: inlineEdit, onCommit: commitInlineEdit, onCancel: cancelInlineEdit)
                        }
                        ForEach(filteredFiles) { file in
                            FileTreeRow(
                                file: file,
                                isSelected: state.selectedFile?.path == file.path,
                                isEditing: inlineEdit?.targetPath == file.path,
                                editText: inlineEdit?.targetPath == file.path ? inlineEdit?.text : nil,
                                onOpen: { open(file) },
                                onPreviewHTML: { openHTML(file) },
                                onDownload: { downloadFile(file) },
                                onCopyPath: { copyPath(file) },
                                onNewFile: { beginCreate(in: file, isDirectory: false) },
                                onNewFolder: { beginCreate(in: file, isDirectory: true) },
                                onDelete: { delete(file) },
                                onRename: { beginRename(file) },
                                onCommitEdit: commitInlineEdit,
                                onCancelEdit: cancelInlineEdit
                            )
                            if let inlineEdit, inlineEdit.isCreate, inlineEdit.parentPath == file.path {
                                FileInlineEditRow(edit: inlineEdit, onCommit: commitInlineEdit, onCancel: cancelInlineEdit)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .background(
                DesignTokens.background
                    .contentShape(Rectangle())
                    .onTapGesture {
                        cancelInlineEdit()
                    }
            )
            .contextMenu {
                filePaneContextMenu
            }
            .dropDestination(for: URL.self) { urls, _ in
                handleFileDrop(urls)
            } isTargeted: { isTargeted in
                isFileDropTarget = isTargeted
            }
            .overlay {
                if isFileDropTarget {
                    RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous)
                        .stroke(DesignTokens.accent.opacity(0.58), lineWidth: 1.5)
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
        }
        .background(DesignTokens.background)
    }

    private var fileHeader: some View {
        VStack(spacing: 9) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.t(.files))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DesignTokens.text)
                    Text(state.selectedWorkspaceContext?.rootPath ?? state.t(.noProjectSelected))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(DesignTokens.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    fileToolbarButton("doc.badge.plus", help: state.t(.newFile), isDisabled: !hasWorkspace) { beginCreateAtSelection(isDirectory: false) }
                    fileToolbarButton("folder.badge.plus", help: state.t(.newFolder), isDisabled: !hasWorkspace) { beginCreateAtSelection(isDirectory: true) }
                    fileToolbarButton("square.and.arrow.up", help: state.t(.uploadFiles), isDisabled: !hasWorkspace) { upload(allowDirectories: false) }
                    fileToolbarButton("arrow.clockwise", help: state.t(.refresh), isDisabled: !hasWorkspace || isLoadingFiles) { loadFiles() }
                }
            }

            HStack(spacing: 7) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DesignTokens.tertiaryText)
                    TextField(filesText(english: "Search files", chinese: "搜索文件"), text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(DesignTokens.tertiaryText)
                    }
                }
                .padding(.horizontal, 9)
                .frame(height: 30)
                .background(DesignTokens.contentSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(DesignTokens.separator.opacity(0.72), lineWidth: 1)
                )

                Menu {
                    Button(state.t(.newFile)) { beginCreateAtSelection(isDirectory: false) }
                        .disabled(!hasWorkspace)
                    Button(state.t(.newFolder)) { beginCreateAtSelection(isDirectory: true) }
                        .disabled(!hasWorkspace)
                    Divider()
                    Button(state.t(.uploadFiles)) { upload(allowDirectories: false) }
                        .disabled(!hasWorkspace)
                    Button(state.t(.uploadFolder)) { upload(allowDirectories: true) }
                        .disabled(!hasWorkspace)
                    Button(state.t(.download)) { downloadZip() }
                        .disabled(!hasWorkspace)
                    if let selected = selectedFileInListing {
                        Divider()
                        Button("\(state.t(.delete)) \(selected.name)", role: .destructive) { delete(selected) }
                    }
                    Divider()
                    Button(filesText(english: "Collapse all", chinese: "全部折叠")) {
                        expandedDirectories.removeAll()
                        loadFiles()
                    }
                    .disabled(expandedDirectories.isEmpty)
                    Button(filesText(english: "Close", chinese: "关闭")) { state.activeTab = .chat }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 30, height: 30)
                }
                .menuStyle(.borderlessButton)
                .buttonStyle(WebToolbarButtonStyle())
            }

            if let status = filePaneStatusLine {
                HStack(spacing: 5) {
                    Image(systemName: status.icon)
                        .font(.system(size: 10, weight: .semibold))
                    Text(status.text)
                        .font(.system(size: 10.5))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(status.color)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DesignTokens.separator).frame(height: 1)
        }
    }

    @ViewBuilder
    private var filePaneContextMenu: some View {
        Button(state.t(.newFile)) { beginCreate(parentPath: nil, depth: 0, isDirectory: false) }
            .disabled(!hasWorkspace)
        Button(state.t(.newFolder)) { beginCreate(parentPath: nil, depth: 0, isDirectory: true) }
            .disabled(!hasWorkspace)
        Divider()
        Button(state.t(.uploadFiles)) { upload(allowDirectories: false) }
            .disabled(!hasWorkspace)
        Button(state.t(.uploadFolder)) { upload(allowDirectories: true) }
            .disabled(!hasWorkspace)
        Button(state.t(.refresh)) { loadFiles() }
            .disabled(!hasWorkspace || isLoadingFiles)
    }

    private func fileToolbarButton(
        _ systemImage: String,
        help: String,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                if systemImage == "arrow.clockwise", isLoadingFiles {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.58)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 12.5, weight: .medium))
                }
            }
            .frame(width: 30, height: 30)
        }
        .buttonStyle(WebToolbarButtonStyle())
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
        .help(help)
    }

    private var fileEmptyEditor: some View {
        VStack(spacing: 10) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(DesignTokens.tertiaryText)
            Text(filesText(english: "Select a file to edit", chinese: "选择文件开始编辑"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DesignTokens.text)
            Text(filesText(
                english: "Browse the project tree, then open a source file, image, or Markdown preview.",
                chinese: "在左侧浏览项目文件，打开源码、图片或 Markdown 预览。"
            ))
                .font(.system(size: 12))
                .foregroundStyle(DesignTokens.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.contentSurface.opacity(0.30))
    }

    private var hasWorkspace: Bool {
        state.selectedWorkspaceContext != nil
    }

    private var selectedFileInListing: WorkspaceFile? {
        guard let selected = state.selectedFile else { return nil }
        return files.first { $0.path == selected.path }
    }

    private var uploadTargetDirectoryPath: String? {
        guard let context = state.selectedWorkspaceContext else { return nil }
        guard let selected = selectedFileInListing else { return context.rootPath }
        if selected.isDirectory {
            return selected.path
        }
        return URL(fileURLWithPath: selected.path).deletingLastPathComponent().path
    }

    private var emptyFilesTitle: String {
        if state.selectedWorkspaceContext == nil {
            return filesText(english: "Pick a workspace", chinese: "请选择工作区")
        }
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return filesText(english: "No matching files", chinese: "没有匹配的文件")
        }
        if fileListing?.isRootHiddenOnly == true {
            return filesText(english: "Only hidden files here", chinese: "这里暂时只有隐藏文件")
        }
        return filesText(english: "No files found", chinese: "没有文件")
    }

    private var emptyFilesDetail: String {
        if state.selectedWorkspaceContext == nil {
            return filesText(english: "Choose or create a project before browsing files.", chinese: "先选择或创建项目，然后再浏览文件。")
        }
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return filesText(english: "Try another filename or clear the search.", chinese: "换个文件名搜索，或者清空搜索条件。")
        }
        if let listing = fileListing, listing.isRootHiddenOnly {
            return filesText(
                english: "\(listing.skippedRootItemCount) hidden or generated item\(listing.skippedRootItemCount == 1 ? "" : "s") are omitted from the project browser.",
                chinese: "已省略 \(listing.skippedRootItemCount) 个隐藏或生成项目，避免文件树被内部数据占满。"
            )
        }
        return filesText(english: "Create a file, upload project assets, or refresh after changing the workspace.", chinese: "你可以新建文件、上传项目资源，或在外部修改后刷新。")
    }

    private var emptyFilesIcon: String {
        if state.selectedWorkspaceContext == nil {
            return "folder.badge.questionmark"
        }
        if fileListing?.isRootHiddenOnly == true {
            return "eye.slash"
        }
        return "doc.text.magnifyingglass"
    }

    private var filePaneStatusLine: (icon: String, text: String, color: Color)? {
        if let fileListError {
            return ("exclamationmark.triangle", fileListError, DesignTokens.danger)
        }
        if let listing = fileListing, listing.skippedItemCount > 0 {
            return (
                "eye.slash",
                filesText(
                    english: "\(listing.skippedItemCount) hidden or generated item\(listing.skippedItemCount == 1 ? "" : "s") omitted",
                    chinese: "已省略 \(listing.skippedItemCount) 个隐藏或生成项目"
                ),
                DesignTokens.tertiaryText
            )
        }
        return nil
    }

    private func filesText(english: String, chinese: String) -> String {
        state.settings.language.resolved() == .chineseSimplified ? chinese : english
    }

    private var filteredFiles: [WorkspaceFile] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return files }
        return files.filter { file in
            file.name.lowercased().contains(query) || file.relativePath.lowercased().contains(query)
        }
    }

    private func loadFiles() {
        guard let context = state.selectedWorkspaceContext else {
            files = []
            fileListing = nil
            fileListError = nil
            isLoadingFiles = false
            return
        }
        isLoadingFiles = true
        fileListError = nil
        do {
            let listing = try state.workspaceService.fileListing(
                rootPath: context.rootPath,
                expandedDirectories: expandedDirectories
            )
            fileListing = listing
            files = listing.files
            if let selected = state.selectedFile, let updated = files.first(where: { $0.path == selected.path }) {
                state.selectedFile = updated
            }
            if let editorFile, let updated = files.first(where: { $0.path == editorFile.path }) {
                self.editorFile = updated
                if state.selectedFile?.path == editorFile.path {
                    state.selectedFile = updated
                }
            }
        } catch {
            fileListing = nil
            files = []
            fileListError = error.localizedDescription
        }
        isLoadingFiles = false
    }

    private func open(_ file: WorkspaceFile) {
        cancelInlineEdit()
        if file.isDirectory {
            state.selectedFile = file
            toggle(file)
            return
        }
        state.selectedFile = file
        editorFile = file
        editorLoadState = .loading
        do {
            if file.isImage || file.isPDF || WorkspaceService.isProbablyBinaryFile(path: file.path) {
                state.selectedFileContent = ""
                editorOriginalContent = ""
                editorLoadState = .loaded
                return
            }
            let read = try state.workspaceService.readTextFile(path: file.path)
            let content = read.content
            state.selectedFileContent = content
            editorOriginalContent = content
            editorLoadState = .loaded
        } catch let error as WorkspaceFileReadError {
            state.selectedFileContent = ""
            editorOriginalContent = ""
            editorLoadState = .unsupported(fileReadErrorMessage(error))
        } catch {
            state.selectedFileContent = ""
            editorOriginalContent = ""
            editorLoadState = .failed(error.localizedDescription)
        }
    }

    private func save(_ file: WorkspaceFile) {
        guard editorLoadState.canSave else {
            state.errorBanner = filesText(english: "Reload the file before saving.", chinese: "请重新加载文件后再保存。")
            return
        }
        do {
            try state.workspaceService.writeFile(path: file.path, content: state.selectedFileContent)
            editorOriginalContent = state.selectedFileContent
            editorLoadState = .loaded
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

    private func beginCreateAtSelection(isDirectory: Bool) {
        if let selected = state.selectedFile, selected.isDirectory {
            beginCreate(in: selected, isDirectory: isDirectory)
        } else if let selected = state.selectedFile {
            let parentPath = URL(fileURLWithPath: selected.path).deletingLastPathComponent().path
            if let parent = files.first(where: { $0.path == parentPath }) {
                beginCreate(in: parent, isDirectory: isDirectory)
            } else {
                beginCreate(parentPath: nil, depth: 0, isDirectory: isDirectory)
            }
        } else {
            beginCreate(parentPath: nil, depth: 0, isDirectory: isDirectory)
        }
    }

    private func beginCreate(in file: WorkspaceFile, isDirectory: Bool) {
        guard file.isDirectory else { return }
        expandedDirectories.insert(file.path)
        loadFiles()
        beginCreate(parentPath: file.path, depth: file.depth + 1, isDirectory: isDirectory)
    }

    private func beginCreate(parentPath: String?, depth: Int, isDirectory: Bool) {
        cancelInlineEdit()
        inlineEdit = FileInlineEdit(
            kind: isDirectory ? .createFolder : .createFile,
            targetPath: nil,
            parentPath: parentPath,
            depth: depth,
            text: isDirectory ? "untitled" : "untitled.txt"
        )
    }

    private func beginRename(_ file: WorkspaceFile) {
        cancelInlineEdit()
        inlineEdit = FileInlineEdit(kind: .rename, targetPath: file.path, parentPath: nil, depth: file.depth, text: file.name)
    }

    private func commitInlineEdit(_ rawValue: String) {
        guard let edit = inlineEdit else { return }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            cancelInlineEdit()
            return
        }
        do {
            switch edit.kind {
            case .rename:
                guard let targetPath = edit.targetPath else { return }
                let newPath = try state.workspaceService.rename(path: targetPath, newName: value)
                inlineEdit = nil
                loadFiles()
                if editorFile?.path == targetPath {
                    if let updated = files.first(where: { $0.path == newPath }) {
                        open(updated)
                    } else {
                        editorFile = nil
                        state.selectedFile = nil
                        state.selectedFileContent = ""
                        editorOriginalContent = ""
                        editorLoadState = .idle
                    }
                }
            case .createFile, .createFolder:
                guard let context = state.selectedWorkspaceContext else { return }
                let parent = edit.parentPath ?? context.rootPath
                let path = try state.workspaceService.createFile(parentPath: parent, name: value, isDirectory: edit.kind == .createFolder)
                inlineEdit = nil
                if edit.kind == .createFolder {
                    expandedDirectories.insert(path)
                }
                loadFiles()
                if edit.kind == .createFile, let created = files.first(where: { $0.path == path }) {
                    open(created)
                }
            }
        } catch {
            state.errorBanner = error.localizedDescription
        }
    }

    private func cancelInlineEdit() {
        inlineEdit = nil
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
            if state.selectedFile?.path == file.path {
                editorFile = nil
                state.selectedFile = nil
                state.selectedFileContent = ""
                editorOriginalContent = ""
                editorLoadState = .idle
            }
            loadFiles()
        } catch {
            state.errorBanner = error.localizedDescription
        }
    }

    private func copyPath(_ file: WorkspaceFile) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(file.path, forType: .string)
        state.statusLine = "\(state.t(.copyPath)) \(file.name)"
    }

    private func downloadFile(_ file: WorkspaceFile) {
        guard !file.isDirectory else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.copyItem(at: URL(fileURLWithPath: file.path), to: url)
            state.statusLine = "\(state.t(.download)) \(url.lastPathComponent)"
        } catch {
            state.errorBanner = error.localizedDescription
        }
    }

    private func upload(allowDirectories: Bool) {
        guard let targetDirectory = uploadTargetDirectoryPath else { return }
        cancelInlineEdit()
        let panel = NSOpenPanel()
        panel.canChooseFiles = !allowDirectories
        panel.canChooseDirectories = allowDirectories
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        do {
            try state.workspaceService.copyItems(panel.urls, into: targetDirectory)
            loadFiles()
        } catch {
            state.errorBanner = error.localizedDescription
        }
    }

    private func handleFileDrop(_ urls: [URL]) -> Bool {
        guard let targetDirectory = uploadTargetDirectoryPath else { return false }
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty else { return false }
        cancelInlineEdit()
        copyDroppedItems(fileURLs, into: targetDirectory)
        return true
    }

    private func copyDroppedItems(_ urls: [URL], into targetDirectory: String) {
        let uniqueURLs = urls.reduce(into: [URL]()) { result, url in
            let standardized = url.standardizedFileURL
            if !result.contains(where: { $0.path == standardized.path }) {
                result.append(standardized)
            }
        }
        guard !uniqueURLs.isEmpty else {
            state.errorBanner = filesText(english: "No files were found in the drop.", chinese: "拖拽内容中没有可用文件。")
            return
        }
        do {
            try state.workspaceService.copyItems(uniqueURLs, into: targetDirectory)
            loadFiles()
            state.statusLine = filesText(
                english: "Uploaded \(uniqueURLs.count) item\(uniqueURLs.count == 1 ? "" : "s")",
                chinese: "已上传 \(uniqueURLs.count) 个项目"
            )
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

    private func fileReadErrorMessage(_ error: WorkspaceFileReadError) -> String {
        switch error {
        case .binaryFile:
            return filesText(
                english: "This file appears to be binary and cannot be edited as text.",
                chinese: "这个文件看起来是二进制文件，不能作为文本编辑。"
            )
        case let .fileTooLarge(byteCount, limit):
            return filesText(
                english: "This file is too large to edit safely (\(WorkspaceFileReadError.formatBytes(byteCount)); limit \(WorkspaceFileReadError.formatBytes(limit))).",
                chinese: "这个文件太大，不能安全地直接编辑（\(WorkspaceFileReadError.formatBytes(byteCount))；上限 \(WorkspaceFileReadError.formatBytes(limit))）。"
            )
        case .unsupportedEncoding:
            return filesText(
                english: "This file is not valid UTF-8 text.",
                chinese: "这个文件不是有效的 UTF-8 文本。"
            )
        }
    }
}

enum FileWorkspaceLayoutMetrics {
    static let browserDefaultWidth: CGFloat = 330
    static let browserMinWidth: CGFloat = 260
    static let browserMaxWidth: CGFloat = 430
    static let treeRowHeight: CGFloat = 28
    static let treeSpacing: CGFloat = 2
    static let inlineFieldHeight: CGFloat = 24
}

enum FilePreviewActionPolicy {
    static func treePreviewIcon(for file: WorkspaceFile) -> String? {
        file.isHTML ? "globe" : nil
    }

    static func editorShowsHTMLPreview(for file: WorkspaceFile) -> Bool {
        false
    }

    static func editorPreviewToggleIcon(for file: WorkspaceFile, isPreviewing: Bool) -> String? {
        if file.isMarkdown {
            return isPreviewing ? "pencil" : "doc.richtext"
        }
        return nil
    }

    static func usesNativePDFPreview(for file: WorkspaceFile) -> Bool {
        file.isPDF
    }
}

enum FileEditorLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
    case unsupported(String)

    var canSave: Bool {
        self == .loaded
    }
}

private struct FilePaneStatusView: View {
    var title: String
    var detail: String
    var systemImage: String
    var isLoading = false

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.76)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 24, weight: .regular))
                }
            }
            .frame(width: 36, height: 36)
            .foregroundStyle(DesignTokens.tertiaryText)

            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(DesignTokens.text)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(DesignTokens.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
    }
}

private enum FileInlineEditKind: Equatable {
    case rename
    case createFile
    case createFolder
}

private struct FileInlineEdit: Equatable, Identifiable {
    let id = UUID()
    var kind: FileInlineEditKind
    var targetPath: String?
    var parentPath: String?
    var depth: Int
    var text: String

    var isCreate: Bool {
        kind == .createFile || kind == .createFolder
    }

    var iconName: String {
        switch kind {
        case .createFolder:
            return "folder"
        case .rename, .createFile:
            return "doc.text"
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
                    VStack(alignment: .leading, spacing: 16) {
                        switch subtab {
                        case .projectMemory:
                            projectMemory(snapshot)
                        case .profile:
                            profileMemory(snapshot)
                        case .trace:
                            memoryTrace(snapshot)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 18)
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

    private var memoryLanguage: ResolvedAppLanguage {
        state.settings.language.resolved()
    }

    private var isChineseMemoryUI: Bool {
        memoryLanguage == .chineseSimplified
    }

    private func memory(_ english: String, _ chinese: String) -> String {
        isChineseMemoryUI ? chinese : english
    }

    private func memoryTopbar(_ snapshot: MemoryDashboardSnapshot) -> some View {
        let jobs = mergedJobStates(snapshot)
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 2) {
                    MemoryNavTabButton(title: projectTabTitle(snapshot), isActive: subtab == .projectMemory) {
                        selectedRecord = nil
                        subtab = .projectMemory
                    }
                    MemoryNavTabButton(title: NativeMemoryViewLayout.subtabLabel(.profile, language: memoryLanguage), isActive: subtab == .profile) {
                        selectedRecord = nil
                        subtab = .profile
                    }
                    MemoryNavTabButton(title: NativeMemoryViewLayout.subtabLabel(.trace, language: memoryLanguage), isActive: subtab == .trace) {
                        selectedRecord = nil
                        subtab = .trace
                    }
                }

                Spacer(minLength: 12)

                memoryTopbarStatus(snapshot, jobs: jobs)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)

            if subtab == .projectMemory {
                memoryProjectToolbar(snapshot, jobs: jobs)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
        }
        .background(DesignTokens.card)
        .overlay(alignment: .bottom) { Rectangle().fill(DesignTokens.separator).frame(height: 1) }
    }

    private func memoryProjectToolbar(_ snapshot: MemoryDashboardSnapshot, jobs: [MemoryJobKind: MemoryJobState]) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignTokens.tertiaryText)
                TextField(memory("Search current view", "搜索当前视图"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !query.isEmpty {
                    Button {
                        query = ""
                        state.bumpToolRefresh()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DesignTokens.tertiaryText)
                    .help(memory("Clear search", "清空搜索"))
                }
            }
            .padding(.horizontal, 9)
            .frame(minWidth: 180, maxWidth: 360, minHeight: 30, maxHeight: 30)
            .background(DesignTokens.contentSurface, in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous).stroke(DesignTokens.separator.opacity(0.82)))

            Button { state.bumpToolRefresh() } label: {
                Label(memory("Search", "搜索"), systemImage: "magnifyingglass")
            }
            .buttonStyle(MemoryToolbarButtonStyle())

            Spacer(minLength: 12)

            Button { refreshMemory() } label: {
                Label(state.t(.refresh), systemImage: "arrow.clockwise")
            }
            .buttonStyle(MemoryToolbarButtonStyle())

            MemoryJobButton(title: memory("Index", "索引"), systemImage: "arrow.triangle.2.circlepath", state: jobs[.index] ?? .idle(.index), isProminent: false, minWidth: 70) { indexMemory() }
            MemoryJobButton(title: "Dream", systemImage: "sparkles", state: jobs[.dream] ?? .idle(.dream), isProminent: false, minWidth: 76) { dreamMemory() }

            Menu {
                Button {
                    rollbackDream()
                } label: {
                    Label(memory("Rollback Last Dream", "回滚上一次 Dream"), systemImage: "arrow.uturn.backward")
                }
                .disabled(snapshot.lastDreamSnapshot?.rollbackReady != true || (jobs[.rollback] ?? .idle(.rollback)).phase == .running)
            } label: {
                MemoryToolbarMenuLabel(title: memory("More", "更多"), systemImage: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .foregroundStyle(DesignTokens.secondaryText)
        }
    }

    private func projectTabTitle(_ snapshot: MemoryDashboardSnapshot) -> String {
        if snapshot.workspace.workspaceMode == "general" || state.selectedWorkspaceContext?.isGeneral == true {
            return memory("General Memory", "通用记忆")
        }
        return NativeMemoryViewLayout.subtabLabel(.projectMemory, language: memoryLanguage)
    }

    private func memoryTopbarStatus(_ snapshot: MemoryDashboardSnapshot, jobs: [MemoryJobKind: MemoryJobState]) -> some View {
        HStack(spacing: 6) {
            if let running = jobs.values.first(where: { $0.phase == .running }) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.55)
                Text(running.message.isEmpty ? running.kind.rawValue.capitalized : running.message)
                    .foregroundStyle(DesignTokens.secondaryText)
            } else {
                MemoryStatusPill(text: memory("Ready", "就绪"), tone: .neutral)
            }
            MemoryStatusPill(
                text: snapshot.scheduler.enabled ? memory("Auto", "自动") : memory("Manual", "手动"),
                tone: snapshot.scheduler.enabled ? .success : .neutral
            )
            Text(snapshot.overview.lastIndexedAt.map { "\(memory("Indexed", "已索引")) \(relativeDate($0))" } ?? memory("Not indexed", "未索引"))
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(DesignTokens.tertiaryText)
        .lineLimit(1)
    }

    private func projectMemory(_ snapshot: MemoryDashboardSnapshot) -> some View {
        let meta = snapshot.workspace.projectMeta
        return VStack(alignment: .leading, spacing: 18) {
            if snapshot.workspace.workspaceMode == "general" || state.selectedWorkspaceContext?.isGeneral == true {
                MemoryGeneralTopicsSection(
                    title: memory("General Topics", "通用主题"),
                    empty: memory("No general topics have been formed yet.", "当前还没有形成通用主题。"),
                    topics: snapshot.workspace.generalProjects,
                    selectedID: snapshot.workspace.selectedProjectId
                )
            } else if let meta {
                MemoryProjectContextCard(meta: meta)
                    .environmentObject(state)
            }

            MemoryRecordSection(
                title: snapshot.workspace.workspaceMode == "general" ? memory("General Memory", "通用记忆") : memory("Project Memory", "项目记忆"),
                subtitle: snapshot.workspace.workspaceMode == "general"
                    ? memory("Facts, preferences, and context from general conversations.", "通用对话中的事实、偏好和上下文记录。")
                    : memory("Progress, facts, and state records for the current project.", "当前 project 的进展、事实和状态记录。"),
                records: snapshot.workspace.projectEntries,
                empty: snapshot.workspace.workspaceMode == "general" ? memory("No general memory yet.", "当前没有通用记忆。") : memory("No project memory yet.", "当前没有项目记忆。")
            ) { record in
                selectedRecord = record
            }

            if !snapshot.workspace.feedbackEntries.isEmpty || !query.isEmpty {
                MemoryRecordSection(
                    title: memory("Collaboration Feedback", "协作反馈"),
                    subtitle: snapshot.workspace.workspaceMode == "general"
                        ? memory("Preferences, constraints, and delivery rules from general conversations.", "通用对话中的偏好、约束和交付规则。")
                        : memory("User preferences, constraints, and delivery rules for the current project.", "用户对当前 project 的偏好、约束和交付规则。"),
                    records: snapshot.workspace.feedbackEntries,
                    empty: memory("No collaboration feedback yet.", "当前没有协作反馈。")
                ) { record in
                    selectedRecord = record
                }
            }

            let deprecated = snapshot.workspace.deprecatedProjectEntries + snapshot.workspace.deprecatedFeedbackEntries
            if !deprecated.isEmpty {
                MemoryRecordSection(
                    title: memory("Deprecated", "已弃用"),
                    subtitle: memory("Project memory and collaboration feedback marked as deprecated.", "已标记为弃用的项目记忆与协作反馈。"),
                    records: deprecated,
                    empty: memory("No deprecated memory yet.", "当前没有已弃用记忆。")
                ) { record in
                    selectedRecord = record
                }
            }
        }
    }

    private func profileMemory(_ snapshot: MemoryDashboardSnapshot) -> some View {
        let userNotes = snapshot.records.filter { $0.type == .user && !$0.deprecated }
        let feedbackProfile = snapshot.records.filter { $0.type == .feedback && !$0.deprecated }
        return VStack(alignment: .leading, spacing: 16) {
            MemoryBoardGroup(title: memory("User Profile", "用户画像"), subtitle: memory("Long-term identity background and preferences.", "长期身份背景和偏好。")) {
                if snapshot.userSummary.isEmpty {
                    MemoryEmptyDashedState(text: memory("No summarized user profile yet. User Notes are merged here after Dream runs.", "当前还没有汇总后的用户画像；User Notes 会在 Dream 后合并到这里。"))
                } else {
                    Text(snapshot.userSummary)
                        .font(.system(size: 13))
                        .foregroundStyle(DesignTokens.secondaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if !userNotes.isEmpty {
                MemoryRecordSection(title: "User Notes", subtitle: memory("Long-term user profile, preferences, and background.", "长期用户画像、偏好和背景信息。"), records: userNotes, empty: memory("No user profile records yet.", "暂无用户画像记录。")) { record in
                    selectedRecord = record
                }
            }

            if !feedbackProfile.isEmpty {
                MemoryRecordSection(title: memory("Feedback Profile", "反馈画像"), subtitle: memory("User preferences extracted from collaboration feedback.", "从协作反馈中提取的用户偏好。"), records: feedbackProfile, empty: memory("No feedback profile yet.", "暂无反馈画像。")) { record in
                    selectedRecord = record
                }
            }
        }
    }

    private func memoryTrace(_ snapshot: MemoryDashboardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 4) {
                MemoryTraceTabButton("Recall", isActive: traceSubtab == .recall) {
                    traceSubtab = .recall
                    selectedTraceID = nil
                }
                MemoryTraceTabButton("Index", isActive: traceSubtab == .index) {
                    traceSubtab = .index
                    selectedTraceID = nil
                }
                MemoryTraceTabButton("Dream", isActive: traceSubtab == .dream) {
                    traceSubtab = .dream
                    selectedTraceID = nil
                }
            }
            .padding(4)
            .background(DesignTokens.neutral50, in: RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous))

            let records = traceRecords(snapshot)
            if records.isEmpty {
                MemoryBoardGroup(title: traceSelectTitle, subtitle: nil) {
                    MemoryEmptyDashedState(text: traceEmptyDetail)
                }
            } else {
                MemoryBoardGroup(title: traceSelectTitle, subtitle: nil) {
                    Menu {
                        ForEach(records) { trace in
                            Button {
                                selectedTraceID = trace.id
                            } label: {
                                Text("\(trace.title) · \(trace.trigger) · \(relativeDate(trace.createdAt))")
                            }
                        }
                    } label: {
                        MemoryTraceSelectLabel(trace: selectedTrace(records))
                    }
                }

                MemoryTraceDetail(trace: selectedTrace(records))
                    .environmentObject(state)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private var traceSelectTitle: String {
        switch traceSubtab {
        case .recall: memory("Select a case", "选择一个事例")
        case .index: memory("Select an Index trace", "选择一条 Index 追踪")
        case .dream: memory("Select a Dream trace", "选择一条 Dream 追踪")
        }
    }

    private var traceEmptyDetail: String {
        switch traceSubtab {
        case .recall: memory("Select a case to inspect Recall details.", "选择一个事例查看 Recall 详情。")
        case .index: memory("Run Index Sync to show Index traces here.", "运行索引同步后这里会显示 Index 追踪。")
        case .dream: memory("Run Memory Dream to show Dream traces here.", "运行记忆 Dream 后这里会显示 Dream 追踪。")
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

    private func mergedJobStates(_ snapshot: MemoryDashboardSnapshot) -> [MemoryJobKind: MemoryJobState] {
        var states = snapshot.jobStates
        for (kind, local) in memoryJobs {
            guard let snapshotJob = states[kind] else {
                states[kind] = local
                continue
            }
            if local.phase == .running ||
                ((local.endedAt ?? .distantPast) > (snapshotJob.endedAt ?? .distantPast)) {
                states[kind] = local
            }
        }
        return states
    }

    private func job(_ kind: MemoryJobKind) -> MemoryJobState {
        mergedJobStates(currentSnapshot)[kind] ?? .idle(kind)
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
        setJob(.index, phase: .running, message: memory("Indexing current workspace", "正在索引当前工作区"))
        selectedRecord = nil
        let service = state.memoryService
        let projectRoot = state.selectedWorkspaceContext?.rootPath
        let projectName = state.selectedProject?.name
        Task { @MainActor in
            do {
                let snapshot = try await service.runIndexJob(projectRoot: projectRoot, projectName: projectName)
                let traceID = snapshot.indexTraceRecords.first?.id
                setJob(.index, phase: .completed, message: memory("Index sync complete", "索引同步完成"), traceID: traceID)
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
        setJob(.dream, phase: .running, message: memory("Running Memory Dream", "正在运行 Memory Dream"))
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
            title: memory("Rollback Last Dream", "回滚上一次 Dream"),
            detail: memory("Rollback restores the memory snapshot from before the last Dream and overwrites the current memory result. Workspace code files are not changed.", "回滚会恢复上一次 Dream 前的记忆快照，并覆盖当前记忆结果。不会修改工作区代码文件。")
        ) else { return }
        setJob(.rollback, phase: .running, message: memory("Rolling back Dream", "正在回滚 Dream"))
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
        alert.messageText = record.type == .feedback ? memory("Edit Collaboration Feedback", "编辑协作反馈") : memory("Edit Project Memory", "编辑项目记忆")
        alert.informativeText = memory("Only header fields are edited; raw markdown is not exposed directly.", "只编辑头字段，不直接暴露原始 markdown。")
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
        alert.messageText = memory("Delete Memory", "删除记忆")
        alert.informativeText = memory("This deletes the memory file or native record.", "此操作会删除该记忆文件或 native 记录。")
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

enum MemorySubTab {
    case projectMemory
    case profile
    case trace
}

private enum MemoryTraceSubTab {
    case recall
    case index
    case dream
}

enum NativeMemoryViewLayout {
    static let subtabOrder: [MemorySubTab] = [
        .projectMemory,
        .profile,
        .trace,
    ]

    static func subtabLabel(_ tab: MemorySubTab, language: ResolvedAppLanguage) -> String {
        switch (tab, language) {
        case (.projectMemory, .chineseSimplified):
            return "项目记忆"
        case (.projectMemory, _):
            return "Project Memory"
        case (.profile, .chineseSimplified):
            return "用户画像"
        case (.profile, _):
            return "User Profile"
        case (.trace, .chineseSimplified):
            return "记忆追踪"
        case (.trace, _):
            return "Memory Trace"
        }
    }
}

private struct MemoryNavTabButton: View {
    var title: String
    var isActive: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: isActive ? .semibold : .medium))
                .foregroundStyle(isActive ? DesignTokens.text : DesignTokens.secondaryText)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(isActive ? DesignTokens.neutral100 : Color.clear, in: RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct MemoryTraceTabButton: View {
    var title: String
    var isActive: Bool
    var action: () -> Void

    init(_ title: String, isActive: Bool, action: @escaping () -> Void) {
        self.title = title
        self.isActive = isActive
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: isActive ? .semibold : .medium))
                .foregroundStyle(isActive ? DesignTokens.text : DesignTokens.secondaryText)
                .padding(.horizontal, 16)
                .frame(height: 30)
                .background(isActive ? DesignTokens.card : Color.clear, in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                        .stroke(isActive ? DesignTokens.separator.opacity(0.72) : Color.clear, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct MemoryToolbarDivider: View {
    var body: some View {
        Rectangle()
            .fill(DesignTokens.separator)
            .frame(width: 1, height: 20)
            .padding(.horizontal, 4)
    }
}

private struct MemoryToolbarButtonStyle: ButtonStyle {
    var isProminent: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isProminent ? DesignTokens.text : DesignTokens.secondaryText)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(background(isPressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous).stroke(isProminent ? Color.clear : DesignTokens.separator))
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }

    private func background(isPressed: Bool) -> Color {
        if isProminent {
            return isPressed ? DesignTokens.neutral200 : DesignTokens.neutral100
        }
        return isPressed ? DesignTokens.neutral100 : DesignTokens.card
    }
}

private struct MemoryToolbarMenuLabel: View {
    var title: String
    var systemImage: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(DesignTokens.secondaryText)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(DesignTokens.card, in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous).stroke(DesignTokens.separator))
    }
}

private struct MemoryJobButton: View {
    @Environment(\.isEnabled) private var isEnabled
    var title: String
    var systemImage: String
    var state: MemoryJobState
    var isProminent: Bool
    var minWidth: CGFloat = 78
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if state.phase == .running {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.55)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(title)
                    .lineLimit(1)
            }
            .frame(minWidth: minWidth)
        }
        .buttonStyle(MemoryToolbarButtonStyle(isProminent: isProminent))
        .disabled(state.phase == .running)
        .help(state.message.isEmpty ? title : state.message)
        .opacity(isEnabled ? 1 : 0.55)
    }
}

private struct MemoryDashboardMetric: Identifiable, Hashable {
    var id: String
    var icon: String
    var label: String
    var value: String
    var detail: String?
}

private struct MemoryBoardGroup<Content: View>: View {
    var title: String
    var subtitle: String?
    var content: Content

    init(title: String, subtitle: String?, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignTokens.text)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(DesignTokens.tertiaryText)
                        .lineLimit(2)
                }
            }
            content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(DesignTokens.card, in: RoundedRectangle(cornerRadius: DesignTokens.largeRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.largeRadius, style: .continuous).stroke(DesignTokens.separator))
    }
}

private struct MemoryEmptyDashedState: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(DesignTokens.tertiaryText)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .center)
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous)
                    .stroke(DesignTokens.neutral300, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
    }
}

private struct MemoryGeneralTopicsSection: View {
    var title: String
    var empty: String
    var topics: [MemoryProjectMeta]
    var selectedID: String?

    var body: some View {
        MemoryBoardGroup(title: title, subtitle: nil) {
            if topics.isEmpty {
                MemoryEmptyDashedState(text: empty)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 10)], spacing: 10) {
                    ForEach(topics) { topic in
                        MemoryGeneralTopicCard(topic: topic, isSelected: topic.projectId == selectedID)
                    }
                }
            }
        }
    }
}

private struct MemoryGeneralTopicCard: View {
    @EnvironmentObject private var state: AppState
    var topic: MemoryProjectMeta
    var isSelected: Bool

    private func memory(_ english: String, _ chinese: String) -> String {
        state.settings.language.resolved() == .chineseSimplified ? chinese : english
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(topic.projectName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignTokens.text)
                    .lineLimit(2)
                Spacer()
                if isSelected {
                    MemoryStatusPill(text: memory("Current", "当前"), tone: .neutral)
                }
            }
            Text(topic.description.isEmpty ? memory("No summary yet.", "暂无摘要。") : topic.description)
                .font(.system(size: 12))
                .foregroundStyle(DesignTokens.secondaryText)
                .lineLimit(2)
            HStack(spacing: 6) {
                if let workspacePath = topic.workspacePath {
                    MemoryChip(text: URL(fileURLWithPath: workspacePath).lastPathComponent)
                }
                MemoryChip(text: sourceLabel)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(DesignTokens.card, in: RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous).stroke(isSelected ? DesignTokens.text.opacity(0.40) : DesignTokens.separator))
    }

    private var sourceLabel: String {
        switch topic.sourceType {
        case "general_local", "workspace_external_mirror":
            return memory("General Local", "通用本地")
        case "workspace_external":
            return memory("External Read-only", "外部只读")
        default:
            return topic.sourceType
        }
    }
}

private struct MemoryWorkspaceDashboardCard: View {
    var title: String
    var description: String
    var path: String?
    var status: String
    var source: String
    var schedulerEnabled: Bool
    var metrics: [MemoryDashboardMetric]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(DesignTokens.accent.opacity(0.12))
                    Image(systemName: "externaldrive.badge.checkmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(DesignTokens.accent)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(DesignTokens.text)
                            .lineLimit(1)
                        MemoryStatusPill(text: status, tone: .neutral)
                    }
                    Text(description)
                        .font(.system(size: 13))
                        .foregroundStyle(DesignTokens.secondaryText)
                        .lineLimit(2)
                    if let path {
                        Label(path, systemImage: "folder")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(DesignTokens.tertiaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 16)
                VStack(alignment: .trailing, spacing: 8) {
                    MemoryStatusPill(
                        text: schedulerEnabled ? "Auto" : "Manual",
                        tone: schedulerEnabled ? .success : .neutral
                    )
                    MemoryStatusPill(text: source, tone: .neutral)
                }
            }

            HStack(spacing: 0) {
                ForEach(Array(metrics.enumerated()), id: \.offset) { index, metric in
                    MemoryMetricCell(metric: metric)
                    if index < metrics.count - 1 {
                        Rectangle()
                            .fill(DesignTokens.separator.opacity(0.70))
                            .frame(width: 1, height: 42)
                            .padding(.horizontal, 4)
                    }
                }
            }
        }
        .padding(16)
        .background(DesignTokens.contentSurface, in: RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous).stroke(DesignTokens.separator.opacity(0.72)))
        .shadow(color: .black.opacity(0.04), radius: 14, y: 8)
    }
}

private struct MemoryMetricCell: View {
    var metric: MemoryDashboardMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(metric.label, systemImage: metric.icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DesignTokens.tertiaryText)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(metric.value)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(DesignTokens.text)
                    .monospacedDigit()
                    .lineLimit(1)
                if let detail = metric.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(DesignTokens.tertiaryText)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
    }
}

private struct MemoryRuntimePanel: View {
    @EnvironmentObject private var state: AppState
    var snapshot: MemoryDashboardSnapshot

    private func memory(_ english: String, _ chinese: String) -> String {
        state.settings.language.resolved() == .chineseSimplified ? chinese : english
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(memory("Runtime", "运行状态"), systemImage: "waveform.path.ecg")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignTokens.text)
                Spacer()
                MemoryStatusPill(
                    text: snapshot.scheduler.enabled ? memory("Auto", "自动") : memory("Manual", "手动"),
                    tone: snapshot.scheduler.enabled ? .success : .neutral
                )
            }

            VStack(spacing: 0) {
                MemoryRuntimeTraceRow(
                    title: "Recall",
                    icon: "text.magnifyingglass",
                    trace: snapshot.caseTraceRecords.first,
                    empty: memory("No recall yet", "暂无 Recall")
                )
                MemoryPanelDivider()
                MemoryRuntimeTraceRow(
                    title: "Index",
                    icon: "arrow.triangle.2.circlepath",
                    trace: snapshot.indexTraceRecords.first,
                    empty: memory("No index yet", "暂无 Index")
                )
                MemoryPanelDivider()
                MemoryRuntimeTraceRow(
                    title: "Dream",
                    icon: "sparkles",
                    trace: snapshot.dreamTraceRecords.first,
                    empty: memory("No dream yet", "暂无 Dream")
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(memory("Last indexed", "最近索引"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DesignTokens.tertiaryText)
                    Spacer()
                    Text(snapshot.overview.lastIndexedAt.map(relativeDate) ?? state.t(.none))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DesignTokens.secondaryText)
                        .lineLimit(1)
                }
                HStack {
                    Text(memory("Last dream", "最近 Dream"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DesignTokens.tertiaryText)
                    Spacer()
                    Text(snapshot.overview.lastDreamAt.map(relativeDate) ?? state.t(.none))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DesignTokens.secondaryText)
                        .lineLimit(1)
                }
            }
            .padding(10)
            .background(DesignTokens.cardSurfaceSubtle, in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous))
        }
        .padding(14)
        .background(DesignTokens.contentSurface, in: RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous).stroke(DesignTokens.separator.opacity(0.72)))
    }
}

private struct MemoryRuntimeTraceRow: View {
    var title: String
    var icon: String
    var trace: MemoryTraceRecord?
    var empty: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(trace == nil ? DesignTokens.tertiaryText : DesignTokens.accent)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DesignTokens.text)
                    if let trace {
                        Text(trace.trigger)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(DesignTokens.tertiaryText)
                    }
                }
                Text(trace?.title ?? empty)
                    .font(.system(size: 12))
                    .foregroundStyle(trace == nil ? DesignTokens.tertiaryText : DesignTokens.secondaryText)
                    .lineLimit(2)
                if let trace {
                    Text(relativeDate(trace.createdAt))
                        .font(.system(size: 11))
                        .foregroundStyle(DesignTokens.tertiaryText)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }
}

private enum MemoryStatusTone {
    case neutral
    case success
    case warning
    case project
    case feedback
    case deprecated
    case trace
}

private struct MemoryStatusPill: View {
    var text: String
    var tone: MemoryStatusTone

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(background, in: Capsule())
    }

    private var foreground: Color {
        switch tone {
        case .neutral: DesignTokens.secondaryText
        case .success: DesignTokens.success
        case .warning: DesignTokens.warning
        case .project: DesignTokens.secondaryText
        case .feedback: DesignTokens.secondaryText
        case .deprecated: DesignTokens.tertiaryText
        case .trace: DesignTokens.secondaryText
        }
    }

    private var background: Color {
        switch tone {
        case .neutral: DesignTokens.cardSurfaceSubtle
        case .success: DesignTokens.success.opacity(0.12)
        case .warning: DesignTokens.warning.opacity(0.12)
        case .project: DesignTokens.neutral100.opacity(0.74)
        case .feedback: DesignTokens.neutral100.opacity(0.74)
        case .deprecated: DesignTokens.neutral100
        case .trace: DesignTokens.neutral100.opacity(0.74)
        }
    }
}

private struct MemoryPanelDivider: View {
    var body: some View {
        Rectangle()
            .fill(DesignTokens.separator.opacity(0.58))
            .frame(height: 1)
    }
}

private struct MemoryRecordCard: View {
    @EnvironmentObject private var state: AppState
    var record: MemoryRecord
    var selected: Bool

    private func memory(_ english: String, _ chinese: String) -> String {
        state.settings.language.resolved() == .chineseSimplified ? chinese : english
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(record.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignTokens.text)
                    .lineLimit(2)
                Spacer(minLength: 8)
                MemoryStatusPill(text: record.deprecated ? memory("Deprecated", "已弃用") : typeLabel, tone: badgeTone)
            }
            Text(metaLine)
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.tertiaryText)
                .lineLimit(1)
            Text(record.summary.isEmpty ? record.content : record.summary)
                .font(.system(size: 12))
                .foregroundStyle(DesignTokens.secondaryText)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(DesignTokens.contentSurface, in: RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous))
        .overlay(alignment: .leading) {
            Capsule()
                .fill(tint)
                .frame(width: selected ? 3 : 2)
                .padding(.vertical, 10)
                .padding(.leading, 1)
        }
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous)
                .stroke(selected ? DesignTokens.text.opacity(0.42) : DesignTokens.separator, lineWidth: selected ? 1.2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous))
    }

    private var metaLine: String {
        [
            relativeDate(record.updatedAt),
            typeLabel,
            record.relativePath,
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " · ")
    }

    private var typeLabel: String {
        switch record.type {
        case .project:
            return memory("Project", "项目")
        case .feedback:
            return memory("Feedback", "反馈")
        case .user:
            return memory("User", "用户")
        case .generalProjectMeta:
            return memory("Chat Project", "通用主题")
        }
    }

    private var badgeTone: MemoryStatusTone {
        if record.deprecated {
            return .deprecated
        }
        switch record.type {
        case .project, .feedback, .user, .generalProjectMeta:
            return .neutral
        }
    }

    private var tint: Color {
        if record.deprecated {
            return DesignTokens.neutral300
        }
        switch record.type {
        case .project, .generalProjectMeta:
            return DesignTokens.neutral300
        case .feedback:
            return DesignTokens.neutral400
        case .user:
            return DesignTokens.neutral500
        }
    }
}

private struct MemoryRecordSection: View {
    var title: String
    var subtitle: String
    var records: [MemoryRecord]
    var empty: String
    var onSelect: (MemoryRecord) -> Void

    var body: some View {
        MemoryBoardGroup(title: title, subtitle: subtitle) {
            if records.isEmpty {
                MemoryEmptyDashedState(text: empty)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 10)], spacing: 10) {
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
    @EnvironmentObject private var state: AppState
    var meta: MemoryProjectMeta

    private func memory(_ english: String, _ chinese: String) -> String {
        state.settings.language.resolved() == .chineseSimplified ? chinese : english
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(projectDisplayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DesignTokens.text)
                        .lineLimit(1)
                    Text(meta.description.isEmpty ? memory("The current workspace is the only top-level project.", "当前 workspace 就是唯一顶层 project。") : meta.description)
                        .font(.system(size: 13))
                        .foregroundStyle(DesignTokens.secondaryText)
                        .lineLimit(2)
                }
                Spacer()
                MemoryStatusPill(text: statusLabel, tone: .neutral)
            }
            HStack(spacing: 8) {
                if let workspacePath = meta.workspacePath {
                    MemoryChip(text: "\(memory("Project path", "项目路径")) \(URL(fileURLWithPath: workspacePath).lastPathComponent)")
                }
                MemoryChip(text: sourceLabel)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(DesignTokens.contentSurface, in: RoundedRectangle(cornerRadius: DesignTokens.largeRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.largeRadius, style: .continuous).stroke(DesignTokens.separator))
    }

    private var projectDisplayName: String {
        if let workspacePath = meta.workspacePath, !workspacePath.isEmpty {
            return URL(fileURLWithPath: workspacePath).lastPathComponent
        }
        let raw = meta.projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.contains("/") {
            return URL(fileURLWithPath: raw).lastPathComponent
        }
        if raw.hasPrefix("-Users-") || raw.hasPrefix("Users-") {
            return raw.split(separator: "-").last.map(String.init) ?? raw
        }
        return raw.isEmpty ? memory("Current Project", "当前项目") : raw
    }

    private var statusLabel: String {
        switch meta.status.lowercased() {
        case "in_progress", "active":
            return memory("In progress", "进行中")
        case "done", "completed":
            return memory("Done", "已完成")
        case "planned", "todo":
            return memory("Planned", "计划中")
        default:
            return meta.status.isEmpty ? memory("Active", "进行中") : meta.status.replacingOccurrences(of: "_", with: " ")
        }
    }

    private var sourceLabel: String {
        switch meta.sourceType {
        case "workspace":
            return "workspace"
        case "general_local", "workspace_external_mirror":
            return memory("General Local", "通用本地")
        case "workspace_external":
            return memory("External Read-only", "外部只读")
        default:
            return meta.sourceType
        }
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
                .foregroundStyle(DesignTokens.text)
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
        .background(DesignTokens.contentSurface, in: RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous).stroke(DesignTokens.separator.opacity(0.72)))
    }
}

private struct MemoryTraceSelectLabel: View {
    var trace: MemoryTraceRecord?

    var body: some View {
        HStack(spacing: 10) {
            Text(trace.map { "\($0.title) · \($0.trigger) · \(relativeDate($0.createdAt))" } ?? "Select a trace…")
                .font(.system(size: 13))
                .foregroundStyle(trace == nil ? DesignTokens.tertiaryText : DesignTokens.text)
                .lineLimit(1)
            Spacer()
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DesignTokens.tertiaryText)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.card, in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous).stroke(DesignTokens.separator))
    }
}

private struct MemoryDetailPage: View {
    @EnvironmentObject private var state: AppState
    var record: MemoryRecord
    var onBack: () -> Void
    var onEdit: () -> Void
    var onToggleDeprecated: () -> Void
    var onDelete: () -> Void

    private func memory(_ english: String, _ chinese: String) -> String {
        state.settings.language.resolved() == .chineseSimplified ? chinese : english
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Button("← \(state.t(.back))") { onBack() }
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
                        Button(memory("Edit", "编辑")) { onEdit() }.buttonStyle(WebToolbarButtonStyle())
                        Button(record.deprecated ? memory("Restore", "恢复") : memory("Deprecate", "弃用")) { onToggleDeprecated() }.buttonStyle(WebToolbarButtonStyle())
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
            HStack(spacing: 6) {
                Text(trace.trigger)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DesignTokens.tertiaryText)
                Text(relativeDate(trace.createdAt))
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.tertiaryText)
            }
        }
        .padding(12)
        .background(selected ? DesignTokens.cardSurface : DesignTokens.cardSurfaceSubtle, in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous).stroke(selected ? DesignTokens.accent.opacity(0.60) : DesignTokens.separator.opacity(0.58)))
        .contentShape(RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous))
    }
}

private struct MemoryTraceDetail: View {
    @EnvironmentObject private var state: AppState
    var trace: MemoryTraceRecord?

    private func memory(_ english: String, _ chinese: String) -> String {
        state.settings.language.resolved() == .chineseSimplified ? chinese : english
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let trace {
                MemoryBoardGroup(title: trace.title, subtitle: "\(trace.trigger) · \(relativeDate(trace.createdAt))") {
                    Text(trace.reply.isEmpty ? memory("No output yet.", "暂无输出。") : trace.reply)
                        .font(.system(size: 13))
                        .foregroundStyle(DesignTokens.secondaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                traceBlock(title: "Meta", text: trace.meta.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n"))
                traceBlock(title: memory("Injected Context", "注入上下文"), text: trace.context)
                traceBlock(title: memory("Tool Events", "工具事件"), text: trace.toolEvents)
                MemoryBoardGroup(title: memory("Reasoning Timeline", "推理过程"), subtitle: nil) {
                    if trace.steps.isEmpty {
                        MemoryEmptyDashedState(text: memory("No steps yet.", "暂无步骤。"))
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(trace.steps.enumerated()), id: \.element.id) { index, step in
                                MemoryTimelineStep(index: index + 1, step: step)
                            }
                        }
                    }
                }
            } else {
                MemoryBoardGroup(title: memory("No trace records", "暂无追踪记录"), subtitle: nil) {
                    MemoryEmptyDashedState(text: memory("Select a trace to inspect details.", "选择一条追踪查看详情。"))
                }
            }
        }
    }

    private func traceBlock(title: String, text: String) -> some View {
        MemoryBoardGroup(title: title, subtitle: nil) {
            Text(text.isEmpty ? memory("No records.", "暂无记录。") : text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(DesignTokens.secondaryText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct MemoryTimelineStep: View {
    var index: Int
    var step: MemoryTraceStep

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(index)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(DesignTokens.background)
                .frame(width: 20, height: 20)
                .background(tint, in: Circle())
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(step.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DesignTokens.text)
                    MemoryStatusPill(text: step.status, tone: tone)
                }
                Text(step.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(DesignTokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }

    private var tone: MemoryStatusTone {
        switch step.status.lowercased() {
        case "success", "completed": return .success
        case "warning", "skipped": return .warning
        case "error", "failed": return .deprecated
        default: return .trace
        }
    }

    private var tint: Color {
        switch tone {
        case .success: return DesignTokens.success
        case .warning: return DesignTokens.warning
        case .deprecated: return DesignTokens.danger
        default: return DesignTokens.text
        }
    }
}

struct SkillsView: View {
    @EnvironmentObject private var state: AppState
    @State private var selectedSkillKey: String?
    @State private var skillFilter = ""
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
    @State private var modalError: String?
    @State private var importSource: URL?
    @State private var importSourceText = ""
    @State private var importSlug = ""
    @State private var importOverwrite = false
    @State private var transferOverwrite = false
    @State private var pendingDelete: SkillRecord?

    private var selectedSkill: SkillRecord? {
        state.skillsService.skills.first { skillKey($0) == selectedSkillKey }
    }

    private var isGeneralContext: Bool {
        guard let selectedProject = state.selectedProject else { return true }
        return state.isGeneralProject(selectedProject)
    }

    private var currentProjectPath: String? {
        guard let selectedProject = state.selectedProject, !state.isGeneralProject(selectedProject) else {
            return nil
        }
        return state.effectiveWorkspacePath(for: selectedProject)
    }

    private var projectSkills: [SkillRecord] {
        filteredSkills(scope: .project)
    }

    private var userSkills: [SkillRecord] {
        filteredSkills(scope: .user)
    }

    private var hasAnySkills: Bool {
        !state.skillsService.skills.isEmpty
    }

    private var selectedDestinationScope: SkillScope {
        isGeneralContext ? .user : newScope
    }

    private var currentTargetRoot: String {
        destinationPath(for: selectedDestinationScope)
    }

    private var importURLFromText: URL? {
        let trimmed = importSourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return importSource }
        return URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath)
    }

    var body: some View {
        VStack(spacing: 0) {
            ToolToolbar(
                title: state.t(.skills),
                subtitle: toolbarSubtitle
            ) {
                Button(state.t(.refresh)) { refresh() }.buttonStyle(WebToolbarButtonStyle())
                Button {
                    openNew(tab: .importFolder)
                } label: {
                    Label(state.t(.importAction), systemImage: "folder.badge.plus")
                }
                .buttonStyle(WebToolbarButtonStyle())
                Button {
                    openNew(tab: .install)
                } label: {
                    Label(state.t(.newAction), systemImage: "plus")
                }
                .buttonStyle(WebToolbarButtonStyle(isProminent: true))
            }
            HStack(spacing: 0) {
                skillsList
                    .frame(width: 304)
                Rectangle().fill(DesignTokens.separator).frame(width: 1)
                skillDetail
            }
        }
        .background(DesignTokens.background)
        .sheet(isPresented: $showNew) {
            newSkillSheet
                .frame(width: 780, height: 590)
        }
        .confirmationDialog(
            localized("Delete skill?", "删除这个技能？"),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingDelete = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            if let skill = pendingDelete {
                Button(state.t(.delete), role: .destructive) { delete(skill) }
            }
            Button(state.t(.cancel), role: .cancel) { pendingDelete = nil }
        } message: {
            if let skill = pendingDelete {
                Text(localized("This removes \(skill.name) from \(scopeTitle(skill.scope).lowercased()).", "这会从\(scopeTitle(skill.scope))中移除 \(skill.name)。"))
            }
        }
        .task { refresh() }
    }

    private var skillsList: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                scopeIntro
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(DesignTokens.tertiaryText)
                    TextField(localized("Search skills", "搜索技能"), text: $skillFilter)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                    if !skillFilter.isEmpty {
                        Button {
                            skillFilter = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(DesignTokens.tertiaryText)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(DesignTokens.cardSurfaceSubtle, in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DesignTokens.smallRadius).stroke(DesignTokens.separator.opacity(0.58)))
            }
            .padding(12)
            .overlay(alignment: .bottom) { Rectangle().fill(DesignTokens.separator.opacity(0.72)).frame(height: 1) }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if !isGeneralContext {
                        SkillScopeSection(
                            title: scopeTitle(.project),
                            detail: localized("Only active in this project. Project skills win on name conflicts.", "仅当前项目生效。同名时项目技能优先。"),
                            emptyTitle: localized("No project skills", "暂无项目技能"),
                            skills: projectSkills,
                            selectedSkillKey: selectedSkillKey,
                            keyForSkill: skillKey,
                            onSelect: select
                        )
                    }
                    SkillScopeSection(
                        title: scopeTitle(.user),
                        detail: isGeneralContext
                            ? localized("Available to General chat and every project.", "会在通用对话和所有项目里生效。")
                            : localized("Shared across General chat and every project.", "通用对话和所有项目共享。"),
                        emptyTitle: localized("No global skills", "暂无全局技能"),
                        skills: userSkills,
                        selectedSkillKey: selectedSkillKey,
                        keyForSkill: skillKey,
                        onSelect: select
                    )
                    if !hasAnySkills || (projectSkills.isEmpty && userSkills.isEmpty) {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(
                                skillFilter.isEmpty ? localized("No skills yet", "暂无技能") : localized("No matching skills", "没有匹配的技能"),
                                systemImage: "sparkles"
                            )
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DesignTokens.text)
                            Text(skillFilter.isEmpty
                                 ? localized("Install from ClawHub, import a folder, or write one from scratch.", "可以从 ClawHub 安装、导入文件夹，或自己写一个。")
                                 : localized("Try a different name, description, slug, or scope.", "换个名称、描述、slug 或作用域再试。"))
                                .font(.system(size: 12))
                                .foregroundStyle(DesignTokens.tertiaryText)
                                .lineLimit(3)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(DesignTokens.cardSurfaceSubtle, in: RoundedRectangle(cornerRadius: DesignTokens.radius))
                        .overlay(RoundedRectangle(cornerRadius: DesignTokens.radius).stroke(DesignTokens.separator.opacity(0.58)))
                        .padding(.horizontal, 10)
                    }
                }
                .padding(.vertical, 12)
            }
        }
    }

    @ViewBuilder
    private var skillDetail: some View {
        if let skill = selectedSkill {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(scopeTint(skill.scope).opacity(0.12))
                            Image(systemName: "sparkles")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(scopeTint(skill.scope))
                        }
                        .frame(width: 42, height: 42)

                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Text(skill.name)
                                    .font(.system(size: 16, weight: .semibold))
                                    .lineLimit(1)
                                ScopeBadge(title: scopeTitle(skill.scope), tint: scopeTint(skill.scope))
                                if let version = skill.version {
                                    ScopeBadge(title: "v\(version)", tint: DesignTokens.tertiaryText)
                                }
                                if editorContent != originalContent {
                                    ScopeBadge(title: localized("Unsaved", "未保存"), tint: DesignTokens.warning)
                                }
                            }
                            Text(skill.description.isEmpty ? skill.slug : skill.description)
                                .font(.system(size: 12))
                                .foregroundStyle(DesignTokens.secondaryText)
                                .lineLimit(2)
                            HStack(spacing: 14) {
                                metaLabel(localized("Saved at", "保存位置"), value: skill.skillDir)
                                metaLabel(localized("Effective in", "生效范围"), value: effectiveRange(for: skill.scope))
                            }
                        }
                        Spacer(minLength: 16)
                        HStack(spacing: 8) {
                            Button {
                                reveal(skill)
                            } label: {
                                Label(localized("Finder", "访达"), systemImage: "magnifyingglass")
                            }
                            .buttonStyle(WebToolbarButtonStyle())
                            transferMenu(for: skill)
                            Button(role: .destructive) {
                                pendingDelete = skill
                            } label: {
                                Label(state.t(.delete), systemImage: "trash")
                            }
                            .buttonStyle(WebToolbarButtonStyle())
                        }
                    }
                    if skill.scope == .user && !isGeneralContext {
                        inlineNotice(
                            icon: "globe",
                            text: localized("This is a global skill. It remains available when you switch to other projects.", "这是全局技能，切换到其他项目后仍然可用。"),
                            tint: DesignTokens.tertiaryText
                        )
                    } else if skill.scope == .project {
                        inlineNotice(
                            icon: "folder",
                            text: localized("If a global skill has the same name, this project skill is the one the agent will load here.", "如果存在同名全局技能，当前项目会优先加载这个项目技能。"),
                            tint: DesignTokens.accent
                        )
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .overlay(alignment: .bottom) { Rectangle().fill(DesignTokens.separator).frame(height: 1) }

                TextEditor(text: $editorContent)
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .background(DesignTokens.background)

                HStack {
                    Text(editorContent == originalContent ? localized("No unsaved changes", "没有未保存更改") : localized("Edited SKILL.md", "SKILL.md 已编辑"))
                        .font(.system(size: 11))
                        .foregroundStyle(editorContent == originalContent ? DesignTokens.tertiaryText : DesignTokens.warning)
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
            ToolEmptyState(
                title: state.t(.pickSkill),
                detail: isGeneralContext
                    ? localized("Global skills added here are available in General chat and projects.", "这里添加的是全局技能，会在通用对话和项目中生效。")
                    : localized("Choose a project or global skill to inspect, edit, or move.", "选择一个当前项目技能或全局技能来查看、编辑或移动。"),
                systemImage: "sparkles"
            )
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
                newSkillTab(.install, title: localized("Install from ClawHub", "从 ClawHub 安装"), icon: "square.and.arrow.down")
                newSkillTab(.importFolder, title: localized("Import folder", "从文件夹导入"), icon: "folder.badge.plus")
                newSkillTab(.create, title: localized("Write my own", "自己写一个"), icon: "pencil")
                Spacer()
            }
            .padding(.horizontal, 18)
            .frame(height: 42)
            .overlay(alignment: .bottom) { Rectangle().fill(DesignTokens.separator).frame(height: 1) }

            VStack(spacing: 0) {
                destinationSummary
                if let modalNotice {
                    sheetNotice(modalNotice, tint: DesignTokens.success, icon: "checkmark.circle")
                }
                if let modalError {
                    sheetNotice(modalError, tint: DesignTokens.danger, icon: "exclamationmark.triangle")
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
        .onAppear {
            if isGeneralContext {
                newScope = .user
            } else if currentProjectPath != nil, newScope == .user {
                newScope = .project
            }
        }
    }

    private func newSkillTab(_ tab: SkillNewTab, title: String, icon: String) -> some View {
        Button {
            newTab = tab
            modalNotice = nil
            modalError = nil
            if tab == .create, newBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                newBody = localized("Describe when this skill should be used, prerequisites, and steps to follow.", "描述这个技能适合什么时候使用、前置条件，以及应该遵循的步骤。")
            }
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var scopePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(localized("Destination", "保存到"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DesignTokens.tertiaryText)
                Picker(state.t(.scope), selection: $newScope) {
                    Text(scopeTitle(.user)).tag(SkillScope.user)
                    Text(scopeTitle(.project)).tag(SkillScope.project)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .disabled(isGeneralContext)
            }
            Text(isGeneralContext
                 ? localized("General chat can only add global skills.", "通用对话只能添加全局技能。")
                 : scopeDetail(newScope))
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.tertiaryText)
                .lineLimit(2)
        }
        .onAppear {
            if isGeneralContext {
                newScope = .user
            }
        }
    }

    private var clawHubInstallPane: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(DesignTokens.tertiaryText)
                TextField(localized("Search clawhub.com...", "在 clawhub.com 搜索..."), text: $hubQuery)
                    .textFieldStyle(.plain)
                    .onSubmit { searchClawHub() }
                if hubSearching {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 8)
                Button(localized("Search", "搜索")) { searchClawHub() }
                    .buttonStyle(WebToolbarButtonStyle())
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(DesignTokens.background, in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius))
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.smallRadius).stroke(DesignTokens.separator))
            .padding(.horizontal, 18)

            HStack {
                scopePicker
                Spacer()
            }
            .padding(.horizontal, 18)

            ScrollView {
                LazyVStack(spacing: 8) {
                    if hubResults.isEmpty {
                        ToolEmptyState(
                            title: hubQuery.isEmpty ? localized("Search ClawHub", "搜索 ClawHub") : localized("No results", "没有搜索结果"),
                            detail: hubQuery.isEmpty
                                ? localized("Find a skill, choose the destination, then install it into this app.", "找到技能后选择保存位置，再安装到当前客户端。")
                                : localized("Try another keyword, or check the network and ClawHub service.", "换一个关键词，或检查网络和 ClawHub 服务。"),
                            systemImage: "sparkles"
                        )
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
                                        Text(forceInstallSlugs.contains(result.slug) ? localized("Install anyway", "强制安装") : localized("Install", "安装"))
                                    }
                                }
                                .buttonStyle(WebToolbarButtonStyle(isProminent: true))
                                .disabled(hubInstallingSlug != nil && hubInstallingSlug != result.slug)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(DesignTokens.cardSurfaceSubtle, in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius))
                            .overlay(RoundedRectangle(cornerRadius: DesignTokens.smallRadius).stroke(DesignTokens.separator.opacity(0.58)))
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
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        chooseImportFolder()
                    } label: {
                        Label(localized("Choose folder", "选择文件夹"), systemImage: "folder")
                    }
                    .buttonStyle(WebToolbarButtonStyle(isProminent: true))
                    TextField(localized("~/code/my-skill", "~/code/my-skill"), text: $importSourceText)
                        .textFieldStyle(WebFieldStyle())
                    Text(localized("Pick a folder with SKILL.md, or paste an absolute path. ~ is supported.", "选择包含 SKILL.md 的文件夹，或粘贴绝对路径。支持 ~。"))
                        .font(.system(size: 11))
                        .foregroundStyle(DesignTokens.tertiaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 10) {
                    SettingsTextFieldCompat(state.t(.slug), text: $importSlug)
                    Toggle(localized("Overwrite existing skill", "覆盖已有同名技能"), isOn: $importOverwrite)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                        .foregroundStyle(DesignTokens.secondaryText)
                    scopePicker
                }
                .frame(width: 280, alignment: .leading)
            }

            if let source = importURLFromText {
                let validation = state.skillsService.validate(source: source)
                SkillValidationSummary(validation: validation)
                HStack {
                    Spacer()
                    Button(localized("Import skill", "导入技能")) { importChosenSkill(validation: validation, source: source) }
                        .buttonStyle(WebToolbarButtonStyle(isProminent: true))
                        .disabled(!validation.ok)
                }
            } else {
                ToolEmptyState(
                    title: localized("Choose a folder", "选择一个文件夹"),
                    detail: localized("The import check will appear here before anything is copied.", "导入校验会先显示在这里，确认后才会复制。"),
                    systemImage: "folder.badge.plus"
                )
                .frame(height: 220)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
    }

    private var createSkillPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                SettingsTextFieldCompat(state.t(.slug), text: $newSlug)
                SettingsTextFieldCompat(state.t(.name), text: $newName)
                SettingsTextFieldCompat(state.t(.description), text: $newDescription)
            }
            TextEditor(text: $newBody)
                .font(.system(size: 13, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(DesignTokens.cardSurfaceSubtle, in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius))
                .overlay(RoundedRectangle(cornerRadius: DesignTokens.smallRadius).stroke(DesignTokens.separator))
            HStack(alignment: .top) {
                scopePicker
                Spacer()
            }
            HStack {
                Spacer()
                Button(state.t(.cancel)) { showNew = false }.buttonStyle(WebToolbarButtonStyle())
                Button(state.t(.create)) { createSkill() }.buttonStyle(WebToolbarButtonStyle(isProminent: true))
                    .disabled(!canCreateSkill)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
    }

    private func refresh() {
        state.refreshNativeToolData()
        if let selectedSkillKey, state.skillsService.skills.contains(where: { skillKey($0) == selectedSkillKey }) {
            select(state.skillsService.skills.first { skillKey($0) == selectedSkillKey })
        } else {
            select(state.skillsService.skills.first)
        }
        state.bumpToolRefresh()
    }

    private func select(_ skill: SkillRecord?) {
        guard let skill else { return }
        selectedSkillKey = skillKey(skill)
        editorContent = (try? state.skillsService.read(skill)) ?? ""
        originalContent = editorContent
    }

    private func save(_ skill: SkillRecord) {
        do {
            _ = try state.skillsService.write(skill, content: editorContent)
            originalContent = editorContent
            let key = skillKey(skill)
            refresh()
            select(state.skillsService.skills.first { skillKey($0) == key })
        } catch {
            state.errorBanner = error.localizedDescription
        }
    }

    private func delete(_ skill: SkillRecord) {
        do {
            try state.skillsService.delete(skill)
            selectedSkillKey = nil
            pendingDelete = nil
            refresh()
        } catch {
            state.errorBanner = error.localizedDescription
        }
    }

    private func createSkill() {
        do {
            let scope = selectedDestinationScope
            let slug = newSlug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? derivedSkillSlug(name: newName, fallback: newDescription)
                : newSlug.trimmingCharacters(in: .whitespacesAndNewlines)
            let skill = try state.skillsService.create(
                scope: scope,
                projectPath: scope == .project ? currentProjectPath : nil,
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
            select(state.skillsService.skills.first { $0.slug == skill.slug && $0.scope == skill.scope } ?? skill)
        } catch {
            modalError = error.localizedDescription
        }
    }

    private func importSkill() {
        openNew(tab: .importFolder)
    }

    private func searchClawHub() {
        guard !hubSearching else { return }
        hubSearching = true
        modalNotice = nil
        modalError = nil
        let query = hubQuery
        let service = state.skillsService
        Task.detached(priority: .userInitiated) {
            do {
                let results = try await service.clawHubSearch(query: query)
                await MainActor.run {
                    hubResults = results
                    hubSearching = false
                }
            } catch {
                await MainActor.run {
                    modalError = error.localizedDescription
                    hubResults = []
                    hubSearching = false
                }
            }
        }
    }

    private func installClawHub(_ result: SkillHubSearchResult) {
        guard hubInstallingSlug == nil else { return }
        hubInstallingSlug = result.slug
        modalNotice = nil
        modalError = nil
        let force = forceInstallSlugs.contains(result.slug)
        let scope = selectedDestinationScope
        let projectPath = scope == .project ? currentProjectPath : nil
        let service = state.skillsService
        Task.detached(priority: .userInitiated) {
            do {
                let installed = try await service.clawHubInstall(
                    slug: result.slug,
                    force: force,
                    scope: scope,
                    projectPath: projectPath
                )
                await MainActor.run {
                    if installed.installed, let skill = installed.skill {
                        showNew = false
                        refresh()
                        select(state.skillsService.skills.first { $0.slug == skill.slug && $0.scope == skill.scope } ?? skill)
                    } else if installed.needsForce {
                        forceInstallSlugs.insert(result.slug)
                        modalError = installed.stderr.isEmpty
                            ? localized("This skill requires confirmation. Click install again to continue.", "该技能需要二次确认。再次点击安装以继续。")
                            : installed.stderr
                    } else {
                        modalNotice = installed.stderr.isEmpty ? installed.stdout : installed.stderr
                    }
                    hubInstallingSlug = nil
                }
            } catch {
                await MainActor.run {
                    modalError = error.localizedDescription
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
        importSourceText = url.path
    }

    private func importChosenSkill(validation: SkillValidationResult, source: URL) {
        guard validation.ok else { return }
        do {
            let scope = selectedDestinationScope
            let skill = try state.skillsService.importFolder(
                source: source,
                scope: scope,
                projectPath: scope == .project ? currentProjectPath : nil,
                slug: trimmedImportSlug(),
                overwrite: importOverwrite
            )
            showNew = false
            refresh()
            let importedSlug = skill.slug
            let importedScope = skill.scope
            let refreshedSkill = state.skillsService.skills.first { candidate in
                candidate.slug == importedSlug && candidate.scope == importedScope
            } ?? skill
            select(refreshedSkill)
        } catch {
            modalError = error.localizedDescription
        }
    }

    private func trimmedImportSlug() -> String? {
        let trimmed = importSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var canCreateSkill: Bool {
        let hasIdentity = !newSlug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasDescription = !newDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasIdentity && hasDescription
    }

    private func openNew(tab: SkillNewTab) {
        newTab = tab
        newScope = isGeneralContext ? .user : .project
        modalNotice = nil
        modalError = nil
        if tab == .create, newBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            newBody = localized("Describe when this skill should be used, prerequisites, and steps to follow.", "描述这个技能适合什么时候使用、前置条件，以及应该遵循的步骤。")
        }
        showNew = true
    }

    private func filteredSkills(scope: SkillScope) -> [SkillRecord] {
        let query = skillFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return state.skillsService.skills
            .filter { $0.scope == scope }
            .filter { skill in
                guard !query.isEmpty else { return true }
                return [
                    skill.name,
                    skill.slug,
                    skill.description,
                    scopeTitle(skill.scope),
                    skill.skillDir,
                ].joined(separator: " ").lowercased().contains(query)
            }
    }

    private func copy(_ skill: SkillRecord, to scope: SkillScope) {
        do {
            let copied = try state.skillsService.copySkill(skill, to: scope, projectPath: scope == .project ? currentProjectPath : nil, overwrite: transferOverwrite)
            refresh()
            select(state.skillsService.skills.first { $0.slug == copied.slug && $0.scope == copied.scope } ?? copied)
        } catch {
            state.errorBanner = error.localizedDescription
        }
    }

    private func move(_ skill: SkillRecord, to scope: SkillScope) {
        do {
            let moved = try state.skillsService.moveSkill(skill, to: scope, projectPath: scope == .project ? currentProjectPath : nil, overwrite: transferOverwrite)
            refresh()
            select(state.skillsService.skills.first { $0.slug == moved.slug && $0.scope == moved.scope } ?? moved)
        } catch {
            state.errorBanner = error.localizedDescription
        }
    }

    private func reveal(_ skill: SkillRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: skill.skillFile)])
    }

    private func skillKey(_ skill: SkillRecord) -> String {
        "\(skill.scope.rawValue):\(skill.slug)"
    }

    private var toolbarSubtitle: String {
        if isGeneralContext {
            return localized("General chat uses global skills. New skills here apply everywhere.", "通用对话使用全局技能。这里新增的技能会在所有地方生效。")
        }
        let name = state.selectedWorkspaceContext?.displayName ?? state.t(.projects)
        return localized("\(name) uses project skills first, then global skills.", "\(name) 会优先使用当前项目技能，然后使用全局技能。")
    }

    private var scopeIntro: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(isGeneralContext ? scopeTitle(.user) : localized("Project + Global", "项目 + 全局"), systemImage: isGeneralContext ? "globe" : "folder")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(DesignTokens.text)
            Text(isGeneralContext
                 ? localized("Skills added from General are global by design.", "从通用对话添加的技能默认就是全局技能。")
                 : localized("Current project skills override global skills with the same name.", "当前项目技能会覆盖同名全局技能。"))
                .font(.system(size: 11.5))
                .foregroundStyle(DesignTokens.tertiaryText)
                .lineLimit(3)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.cardSurfaceSubtle, in: RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.radius).stroke(DesignTokens.separator.opacity(0.58)))
    }

    private var destinationSummary: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: selectedDestinationScope == .project ? "folder" : "globe")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(scopeTint(selectedDestinationScope))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(localized("Destination: \(scopeTitle(selectedDestinationScope))", "保存到：\(scopeTitle(selectedDestinationScope))"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignTokens.text)
                Text("\(effectiveRange(for: selectedDestinationScope)) · \(currentTargetRoot)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DesignTokens.tertiaryText)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(DesignTokens.cardSurfaceSubtle)
        .overlay(alignment: .bottom) { Rectangle().fill(DesignTokens.separator.opacity(0.58)).frame(height: 1) }
    }

    private func sheetNotice(_ text: String, tint: Color, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(text)
                .lineLimit(2)
            Spacer()
        }
        .font(.system(size: 12))
        .foregroundStyle(tint)
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    private func transferMenu(for skill: SkillRecord) -> some View {
        Menu {
            Toggle(localized("Overwrite destination", "覆盖目标同名技能"), isOn: $transferOverwrite)
            Divider()
            if !isGeneralContext && skill.scope == .user {
                Button(localized("Copy to current project", "复制到当前项目")) { copy(skill, to: .project) }
                Button(localized("Move to current project", "移动到当前项目")) { move(skill, to: .project) }
            }
            if skill.scope == .project {
                Button(localized("Copy to global", "复制到全局")) { copy(skill, to: .user) }
                Button(localized("Move to global", "移动到全局")) { move(skill, to: .user) }
            }
        } label: {
            Label(localized("Scope", "作用域"), systemImage: "arrow.left.arrow.right")
        }
        .buttonStyle(WebToolbarButtonStyle())
        .disabled(isGeneralContext || (skill.scope == .user && currentProjectPath == nil))
    }

    private func metaLabel(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(DesignTokens.tertiaryText)
            Text(value)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(DesignTokens.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: 260, alignment: .leading)
    }

    private func inlineNotice(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11))
            Text(text)
                .font(.system(size: 11.5))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous))
    }

    private func scopeTitle(_ scope: SkillScope) -> String {
        switch scope {
        case .user:
            return localized("Global Skills", "全局技能")
        case .project:
            return localized("Current Project Skills", "当前项目技能")
        }
    }

    private func scopeDetail(_ scope: SkillScope) -> String {
        switch scope {
        case .user:
            return localized("Available to General chat and every project.", "在通用对话和所有项目中生效。")
        case .project:
            return localized("Only available to the current project. Wins over global skills with the same name.", "仅当前项目生效。同名时优先于全局技能。")
        }
    }

    private func effectiveRange(for scope: SkillScope) -> String {
        switch scope {
        case .user:
            return localized("General chat and every project", "通用对话和所有项目")
        case .project:
            return localized("Only the current project", "仅当前项目")
        }
    }

    private func destinationPath(for scope: SkillScope) -> String {
        switch scope {
        case .user:
            return SkillsService.userSkillsRoot().path
        case .project:
            if let currentProjectPath {
                return SkillsService.projectSkillsRoot(currentProjectPath).path
            }
            return SkillsService.userSkillsRoot().path
        }
    }

    private func scopeTint(_ scope: SkillScope) -> Color {
        scope == .project ? DesignTokens.accent : DesignTokens.success
    }

    private func localized(_ english: String, _ chinese: String) -> String {
        state.settings.language.resolved() == .chineseSimplified ? chinese : english
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
    @EnvironmentObject private var state: AppState
    var validation: SkillValidationResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                validation.ok
                    ? localized("Validation passed", "校验通过")
                    : localized("Validation failed", "校验失败"),
                systemImage: validation.ok ? "checkmark.circle" : "exclamationmark.triangle"
            )
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(validation.ok ? DesignTokens.success : DesignTokens.danger)
            Text(localized(
                "\(validation.fileCount) files · \(ByteCountFormatter.string(fromByteCount: Int64(validation.totalBytes), countStyle: .file))",
                "\(validation.fileCount) 个文件 · \(ByteCountFormatter.string(fromByteCount: Int64(validation.totalBytes), countStyle: .file))"
            ))
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
        .background(DesignTokens.cardSurfaceSubtle, in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.smallRadius).stroke(DesignTokens.separator))
    }

    private func localized(_ english: String, _ chinese: String) -> String {
        state.settings.language.resolved() == .chineseSimplified ? chinese : english
    }
}

struct DashboardView: View {
    @EnvironmentObject private var state: AppState
    @State private var expandedSessions: Set<String> = []
    @State private var showsTotalDashboard = false

    var body: some View {
        let selectedProject = state.selectedProject
        let isProjectScoped = selectedProject != nil && !showsTotalDashboard
        let snapshot = state.routingService.dashboard(
            projects: state.projects,
            projectFilter: isProjectScoped ? selectedProject?.name : nil
        )
        let baseline = max(snapshot.estimatedCost + snapshot.savedCost, snapshot.estimatedCost)
        let savingsRate = baseline > 0 ? snapshot.savedCost / baseline : 0
        let recentSessions = snapshot.recentSessions
        let isChinese = state.settings.language.resolved() == .chineseSimplified
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(state.t(.routing))
                            .font(.system(size: 19, weight: .semibold))
                        HStack(spacing: 6) {
                            Text(isProjectScoped ? "\(selectedProject?.displayName ?? selectedProject?.name ?? "Project") 的路由统计。" : state.t(.modelRoutingSummary))
                            if !isProjectScoped, selectedProject != nil {
                                Text("全部项目")
                                    .font(.system(size: 11, weight: .semibold))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(.thinMaterial, in: Capsule())
                                    .overlay(Capsule().stroke(DesignTokens.separator))
                            }
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(DesignTokens.tertiaryText)
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        if selectedProject != nil {
                            Picker("", selection: Binding(
                                get: { showsTotalDashboard ? "total" : "project" },
                                set: { value in
                                    withAnimation(.snappy(duration: 0.18)) {
                                        showsTotalDashboard = value == "total"
                                        expandedSessions.removeAll()
                                    }
                                }
                            )) {
                                Text(isChinese ? "项目" : "Project").tag("project")
                                Text(isChinese ? "总计" : "Total").tag("total")
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 132)
                        }
                        Button {
                            state.bumpToolRefresh()
                        } label: {
                            Label(state.t(.refresh), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(WebToolbarButtonStyle())
                    }
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    RoutingStatCard(
                        icon: "waveform.path.ecg",
                        label: state.t(.requests),
                        value: "\(snapshot.totalRequests)",
                        detail: isChinese ? "\(snapshot.routedSessions) 个已路由会话" : "\(snapshot.routedSessions) routed sessions",
                        compact: true
                    )
                    RoutingStatCard(
                        icon: "sum",
                        label: state.t(.tokens),
                        value: formatTokens(snapshot.totalTokens),
                        detail: isChinese ? "native agent 记录的输入/输出" : "input/output recorded by native agent",
                        compact: true
                    )
                    RoutingStatCard(
                        icon: "dollarsign",
                        label: state.t(.cost),
                        value: formatCost(snapshot.estimatedCost),
                        detail: baseline > 0 ? (isChinese ? "不走 Router \(formatCost(baseline))" : "No router \(formatCost(baseline))") : nil,
                        hint: snapshot.savedCost > 0
                            ? (isChinese ? "↗ 节省 \(formatCost(snapshot.savedCost)) (\(Int((savingsRate * 100).rounded()))%)" : "↗ Saved \(formatCost(snapshot.savedCost)) (\(Int((savingsRate * 100).rounded()))%)")
                            : nil,
                        compact: true
                    )
                }

                if !isProjectScoped, !snapshot.projects.isEmpty {
                    ToolSection(title: isChinese ? "项目" : "Projects") {
                        VStack(spacing: 8) {
                            ForEach(snapshot.projects) { project in
                                RoutingProjectSummaryRow(project: project)
                            }
                        }
                    }
                }

                ToolSection(title: isChinese ? "会话" : state.t(.recentRoutes)) {
                    if recentSessions.isEmpty {
                        Text(state.t(.noRoutingActivity))
                            .font(.system(size: 13))
                            .foregroundStyle(DesignTokens.tertiaryText)
                            .padding(.vertical, 18)
                    } else {
                        HStack {
                            Text(state.t(.session))
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(isChinese ? "分类" : "Tier")
                                .frame(width: 76, alignment: .trailing)
                            Text(state.t(.tokens))
                                .frame(width: 82, alignment: .trailing)
                            Text(state.t(.cost))
                                .frame(width: 72, alignment: .trailing)
                            Text(isChinese ? "节省" : "Saved")
                                .frame(width: 72, alignment: .trailing)
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DesignTokens.tertiaryText)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 6)
                        ForEach(recentSessions) { session in
                            RoutingSessionRow(
                                session: session,
                                expanded: expandedSessions.contains(session.id),
                                onToggle: {
                                    withAnimation(.snappy(duration: 0.18)) {
                                        if expandedSessions.contains(session.id) {
                                            expandedSessions.remove(session.id)
                                        } else {
                                            expandedSessions.insert(session.id)
                                        }
                                    }
                                }
                            )
                        }
                    }
                }

                if !snapshot.recentSessions.isEmpty {
                    RoutingCostSummaryCard(
                        actual: snapshot.estimatedCost,
                        baseline: baseline,
                        saved: snapshot.savedCost,
                        sessions: snapshot.routedSessions,
                        tokens: snapshot.totalTokens,
                        savingsRate: savingsRate,
                        isChinese: isChinese
                    )
                }
            }
            .frame(maxWidth: 980, alignment: .topLeading)
            .padding(.horizontal, 32)
            .padding(.vertical, 20)
        }
        .background(Color.clear)
        .onChange(of: state.selectedProjectID) { _, _ in
            showsTotalDashboard = false
            expandedSessions.removeAll()
        }
    }
}

private struct RoutingBackButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(DesignTokens.secondaryText)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(GlassControlBackground(isActive: false, cornerRadius: 14, showsShadow: false))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

private struct RoutingProjectSummaryRow: View {
    var project: RoutingDashboardProject

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(project.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DesignTokens.text)
                    .lineLimit(1)
                Text("\(project.sessions) sessions · \(project.total.requestCount) requests")
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.tertiaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            metric(formatTokens(project.total.totalTokens), "tokens")
            metric(formatCost(project.total.estimatedCost), "cost")
            Text(project.total.savedCost > 0 ? formatCost(project.total.savedCost) : "—")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(project.total.savedCost > 0 ? DesignTokens.success : DesignTokens.tertiaryText)
                .frame(width: 78, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(DesignTokens.cardSurfaceSubtle, in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.smallRadius).stroke(DesignTokens.separator.opacity(0.56)))
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(DesignTokens.secondaryText)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(DesignTokens.tertiaryText)
        }
        .frame(width: 80, alignment: .trailing)
    }
}

private struct RoutingCostSummaryCard: View {
    var actual: Double
    var baseline: Double
    var saved: Double
    var sessions: Int
    var tokens: Int
    var savingsRate: Double
    var isChinese: Bool

    var body: some View {
        HStack(spacing: 0) {
            metric(isChinese ? "实际开销" : "Actual", formatCost(actual), isChinese ? "\(sessions) 个会话 · \(formatTokens(tokens)) tokens" : "\(sessions) sessions · \(formatTokens(tokens)) tokens", DesignTokens.text)
            Divider()
            metric(isChinese ? "不走 Router" : "No router", formatCost(baseline), isChinese ? "按主模型基准估算" : "Estimated on main model", DesignTokens.text)
            Divider()
            metric(isChinese ? "节省" : "Saved", formatCost(saved), baseline > 0 ? (isChinese ? "相对基准 \(Int((savingsRate * 100).rounded()))%" : "\(Int((savingsRate * 100).rounded()))% vs baseline") : (isChinese ? "暂无基准" : "No baseline"), DesignTokens.success)
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .background(DesignTokens.contentSurface, in: RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous)
                .stroke(DesignTokens.success.opacity(0.22))
        )
    }

    private func metric(_ title: String, _ value: String, _ detail: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DesignTokens.tertiaryText)
            Text(value)
                .font(.system(size: 22, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(color)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.tertiaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RoutingSessionRow: View {
    var session: RoutingDashboardSession
    var expanded: Bool
    var onToggle: () -> Void

    private var primaryTier: String {
        if let first = session.requestEntries.last(where: { $0.tier != nil })?.tier {
            return first
        }
        return session.byTier.keys.sorted().first ?? "RECORDED"
    }

    private var entries: [RoutingRequestLogEntry] {
        session.requestEntries.sorted { $0.ts < $1.ts }
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DesignTokens.tertiaryText)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DesignTokens.text)
                            .lineLimit(1)
                        HStack(spacing: 8) {
                            Text(session.projectName)
                            if let skill = entries.last(where: { $0.skill != nil })?.skill {
                                Text("skill \(skill)")
                            } else if let query = entries.last?.query, !query.isEmpty {
                                Text(query)
                                    .lineLimit(1)
                            } else {
                                Text(relativeDate(session.lastActiveAt))
                            }
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(DesignTokens.tertiaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    TierBadge(tier: primaryTier)
                        .frame(width: 76, alignment: .trailing)
                    Text(formatTokens(session.total.totalTokens))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(DesignTokens.secondaryText)
                        .frame(width: 82, alignment: .trailing)
                    Text(formatCost(session.total.estimatedCost))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(DesignTokens.secondaryText)
                        .frame(width: 72, alignment: .trailing)
                    Text(session.total.savedCost > 0 ? formatCost(session.total.savedCost) : "—")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(session.total.savedCost > 0 ? DesignTokens.success : DesignTokens.tertiaryText)
                        .frame(width: 72, alignment: .trailing)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        .background(DesignTokens.cardSurfaceSubtle, in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.smallRadius).stroke(DesignTokens.separator.opacity(0.56)))

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if entries.isEmpty {
                        ForEach(session.requestLog.suffix(8), id: \.self) { line in
                            Text(line)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(DesignTokens.tertiaryText)
                        }
                    } else {
                        ForEach(entries) { entry in
                            RoutingRequestLogRow(entry: entry)
                        }
                    }
                }
                .padding(.leading, 38)
                .padding(.trailing, 10)
                .padding(.vertical, 10)
                .background(DesignTokens.cardSurface.opacity(0.92), in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius))
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                .clipped()
            }
        }
        .animation(.snappy(duration: 0.18), value: expanded)
    }
}

private struct RoutingRequestLogRow: View {
    var entry: RoutingRequestLogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(entry.role == "sub" ? "Subagent" : "Main")
                        .font(.system(size: 12, weight: .semibold))
                    if let tier = entry.tier {
                        TierBadge(tier: tier)
                    }
                    Text(entry.model)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(DesignTokens.tertiaryText)
                    Spacer()
                    Text(formatTokens(entry.tokens))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(DesignTokens.tertiaryText)
                    Text(formatCost(entry.cost))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(DesignTokens.secondaryText)
                }
                if let skill = entry.skill {
                    Text("Skill: \(skill)")
                        .font(.system(size: 12))
                        .foregroundStyle(DesignTokens.secondaryText)
                }
                if let query = entry.query, !query.isEmpty {
                    Text(query)
                        .font(.system(size: 12))
                        .foregroundStyle(DesignTokens.tertiaryText)
                        .lineLimit(2)
                }
                if let saved = entry.savedCost, saved > 0 {
                    Text("Baseline \(formatCost(entry.baselineCost ?? 0)) · Saved \(formatCost(saved))")
                        .font(.system(size: 11))
                        .foregroundStyle(DesignTokens.success)
                }
            }
        }
        .padding(10)
        .background(DesignTokens.cardSurface, in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.smallRadius).stroke(DesignTokens.separator.opacity(0.62)))
    }

    private var iconName: String {
        if entry.skill != nil { return "sparkles" }
        if entry.role == "sub" { return "square.stack.3d.up" }
        return "arrow.triangle.branch"
    }

    private var iconColor: Color {
        entry.skill != nil ? DesignTokens.warning : DesignTokens.tertiaryText
    }
}

private struct TierBadge: View {
    var tier: String

    var body: some View {
        Text(tier)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
    }

    private var background: Color {
        switch tier.uppercased() {
        case "SIMPLE": DesignTokens.accent.opacity(0.12)
        case "MEDIUM": DesignTokens.warning.opacity(0.14)
        case "REASONING": Color.purple.opacity(0.12)
        default: DesignTokens.success.opacity(0.12)
        }
    }

    private var foreground: Color {
        switch tier.uppercased() {
        case "SIMPLE": DesignTokens.accent
        case "MEDIUM": DesignTokens.warning
        case "REASONING": Color.purple
        default: DesignTokens.success
        }
    }
}

struct AlwaysOnView: View {
    @EnvironmentObject private var state: AppState
    @State private var subtab: AlwaysOnSubTab = .dashboard
    @State private var selectedPlan: AlwaysOnPlan?
    @State private var selectedCronJob: AlwaysOnCronJob?
    @State private var selectedRun: AlwaysOnRunHistory?
    @State private var selectedDetailProjectRoot: String?

    var body: some View {
        guard let context = state.selectedWorkspaceContext, !context.isGeneral else {
            return AnyView(generalView())
        }
        let plans = state.alwaysOnService.plans(projectRoot: context.rootPath)
        let cronJobs = state.alwaysOnService.cronJobs(projectRoot: context.rootPath)
        let history = state.alwaysOnService.runHistory(projectRoot: context.rootPath)
        let rows = NativeAlwaysOnRows.rows(plans: plans, cronJobs: cronJobs)
        let language = state.settings.language.resolved()
        return AnyView(
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    HStack(spacing: 2) {
                        TabButton(localized("Dashboard", "看板"), isActive: subtab == .dashboard) {
                            subtab = .dashboard
                            clearAlwaysOnSelection()
                        }
                        TabButton(state.t(.plansCronJobs), isActive: subtab == .items) {
                            subtab = .items
                            clearAlwaysOnSelection(keepRun: false)
                        }
                        TabButton(state.t(.runHistory), isActive: subtab == .history) {
                            subtab = .history
                            selectedPlan = nil
                            selectedCronJob = nil
                            selectedDetailProjectRoot = nil
                        }
                    }
                    .padding(3)
                    .background(GlassControlBackground(isActive: false, cornerRadius: 16, material: .popover, showsShadow: false))
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.top, 10)
                .padding(.bottom, 8)
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

                        if let selectedPlan {
                            planDetail(selectedPlan, projectRoot: selectedDetailProjectRoot ?? context.rootPath)
                        } else if let selectedCronJob {
                            cronDetail(selectedCronJob, projectRoot: selectedDetailProjectRoot ?? context.rootPath)
                        } else if let selectedRun {
                            runHistoryDetail(selectedRun, projectRoot: selectedDetailProjectRoot ?? context.rootPath)
                        } else if subtab == .dashboard {
                            dashboardContent(snapshot: state.alwaysOnDashboardSnapshot(scope: context), groups: projectGroups(scope: context))
                        } else if subtab == .history {
                            historyView(history, projectRoot: context.rootPath)
                        } else {
                            itemsView(rows: rows, projectRoot: context.rootPath)
                        }

                        if let updatedAt = plans.first?.updatedAt {
                            Text(NativeAlwaysOnUpdatedLabel.updatedText(updatedAt, language: language))
                                .font(.system(size: 11))
                                .foregroundStyle(DesignTokens.tertiaryText)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                }
            }
            .background(Color.clear)
            .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
                pollSelectedRunLog(context: context)
            }
        )
    }

    private func itemsView(rows: [NativeAlwaysOnRow], projectRoot: String) -> some View {
        return VStack(alignment: .leading, spacing: 12) {
            if rows.isEmpty {
                Text(state.t(.noActivePlans))
                    .font(.system(size: 13))
                    .foregroundStyle(DesignTokens.tertiaryText)
                    .padding(18)
            } else {
                VStack(spacing: 8) {
                    ForEach(rows) { row in
                        compactItemRow(row, projectRoot: projectRoot)
                    }
                }
            }
        }
        .padding(16)
        .background(DesignTokens.contentSurface, in: RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous).stroke(DesignTokens.separator.opacity(0.72)))
    }

    private func alwaysOnItemTableRow(_ row: NativeAlwaysOnRow, projectRoot: String) -> some View {
        let tableRow = NativeAlwaysOnItemsRows.row(row)
        return HStack(spacing: 12) {
            Button {
                switch row.kind {
                case .plan:
                    selectedPlan = row.plan
                    selectedDetailProjectRoot = projectRoot
                case .cron:
                    selectedCronJob = row.cronJob
                    selectedDetailProjectRoot = projectRoot
                }
            } label: {
                Text(tableRow.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DesignTokens.accent)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: NativeAlwaysOnItemsRows.columnWidths[0], alignment: .leading)
            }
            .buttonStyle(.plain)

            Text(tableRow.type)
                .frame(width: NativeAlwaysOnItemsRows.columnWidths[1], alignment: .leading)
            Text(tableRow.status)
                .frame(width: NativeAlwaysOnItemsRows.columnWidths[2], alignment: .leading)
            Text(tableRow.created)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(DesignTokens.tertiaryText)
                .frame(width: NativeAlwaysOnItemsRows.columnWidths[3], alignment: .leading)
            Text(tableRow.triggered)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(DesignTokens.tertiaryText)
                .frame(width: NativeAlwaysOnItemsRows.columnWidths[4], alignment: .leading)
            Text(tableRow.completed)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(DesignTokens.tertiaryText)
                .frame(width: NativeAlwaysOnItemsRows.columnWidths[5], alignment: .leading)

            HStack(spacing: 6) {
                if row.kind == .cron {
                    Button(state.t(.view)) {
                        openCronSession(row)
                    }
                    .buttonStyle(WebToolbarButtonStyle())
                    .disabled(!NativeAlwaysOnItemsRows.canOpenCronSession(row))
                }
                Button(state.t(.run)) {
                    if let plan = row.plan {
                        runPlan(plan, projectRoot: projectRoot)
                    } else if let job = row.cronJob {
                        runCronJob(job, projectRoot: projectRoot)
                    }
                }
                .buttonStyle(WebToolbarButtonStyle(isProminent: true))
                .disabled(!row.canRun)
                Button(row.kind == .plan ? state.t(.archive) : state.t(.delete)) {
                    if let plan = row.plan {
                        try? state.alwaysOnService.archive(plan: plan, projectRoot: projectRoot)
                        state.bumpToolRefresh()
                    } else if let job = row.cronJob {
                        do {
                            _ = try state.alwaysOnService.deleteCronJob(jobID: job.id, projectRoot: projectRoot)
                            selectedCronJob = nil
                            state.bumpToolRefresh()
                        } catch {
                            state.errorBanner = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(WebToolbarButtonStyle())
                .disabled(!row.canArchiveOrDelete)
            }
            .frame(width: NativeAlwaysOnItemsRows.columnWidths[6], alignment: .trailing)
        }
        .font(.system(size: 12))
        .foregroundStyle(DesignTokens.secondaryText)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    private func startDiscovery(context: WorkspaceContext) {
        state.startAlwaysOnDiscovery(context: context)
        state.bumpToolRefresh()
    }

    private func runCronJob(_ job: AlwaysOnCronJob, projectRoot: String) {
        guard let context = context(forProjectRoot: projectRoot) else { return }
        state.runAlwaysOnCronJob(job, context: context)
        state.bumpToolRefresh()
    }

    private func runPlan(_ plan: AlwaysOnPlan, projectRoot: String) {
        guard let context = context(forProjectRoot: projectRoot) else { return }
        state.runAlwaysOnPlan(plan, context: context)
        state.bumpToolRefresh()
    }

    private func cronDetail(_ job: AlwaysOnCronJob, projectRoot: String) -> some View {
        let language = state.settings.language.resolved()
        let row = NativeAlwaysOnRows.cronRow(job)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        selectedCronJob = nil
                    } label: {
                        Label(state.t(.back), systemImage: "arrow.left")
                    }
                    .buttonStyle(WebToolbarButtonStyle())
                    Text(cronTitle(job))
                        .font(.system(size: 20, weight: .semibold))
                        .lineLimit(2)
                }
                Spacer()
                HStack(spacing: 6) {
                    Button(state.t(.run)) {
                        runCronJob(job, projectRoot: projectRoot)
                    }
                    .buttonStyle(WebToolbarButtonStyle(isProminent: true))
                    .disabled(!row.canRun)
                    Button(state.t(.delete)) {
                        do {
                            _ = try state.alwaysOnService.deleteCronJob(jobID: job.id, projectRoot: projectRoot)
                            selectedCronJob = nil
                            state.bumpToolRefresh()
                        } catch {
                            state.errorBanner = error.localizedDescription
                        }
                    }
                    .buttonStyle(WebToolbarButtonStyle())
                    .disabled(!row.canArchiveOrDelete)
                }
            }
            .padding(.bottom, 14)
            .overlay(alignment: .bottom) { Rectangle().fill(DesignTokens.separator.opacity(0.72)).frame(height: 1) }

            HStack(alignment: .top, spacing: 16) {
                alwaysOnDetailSection(title: NativeAlwaysOnCronDetailPresentation.sectionTitle(.prompt, language: language)) {
                    MonospaceOutput(text: NativeAlwaysOnCronDetailPresentation.promptText(job))
                        .frame(minHeight: 160)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 14) {
                    alwaysOnDetailSection(title: NativeAlwaysOnCronDetailPresentation.sectionTitle(.schedule, language: language)) {
                        alwaysOnMetaList(items: NativeAlwaysOnCronDetailPresentation.scheduleItems(job, language: language))
                    }
                    alwaysOnDetailSection(title: NativeAlwaysOnCronDetailPresentation.sectionTitle(.createdFrom, language: language)) {
                        alwaysOnInteractiveMetaList([
                            AlwaysOnMetaDisplayItem(
                                title: NativeAlwaysOnCronDetailPresentation.fieldLabel(.originSessionId, language: language),
                                value: NativeAlwaysOnCronDetailPresentation.originSessionValue(job),
                                action: cronOriginSessionAction(job)
                            ),
                            AlwaysOnMetaDisplayItem(
                                title: NativeAlwaysOnCronDetailPresentation.fieldLabel(.sessionId, language: language),
                                value: NativeAlwaysOnCronDetailPresentation.latestRunSessionValue(job),
                                action: cronLatestRunSessionAction(job)
                            ),
                            AlwaysOnMetaDisplayItem(
                                title: NativeAlwaysOnCronDetailPresentation.fieldLabel(.transcriptKey, language: language),
                                value: NativeAlwaysOnCronDetailPresentation.transcriptKeyValue(job)
                            ),
                        ])
                    }
                }
                .frame(width: 320, alignment: .topLeading)
            }
        }
    }

    private func alwaysOnMetaSection(title: String, items: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DesignTokens.tertiaryText)
                .textCase(.uppercase)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), alignment: .leading)], alignment: .leading, spacing: 12) {
                ForEach(items, id: \.0) { item in
                    AlwaysOnMetaItem(title: item.0, value: item.1)
                }
            }
        }
    }

    private func alwaysOnDetailSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DesignTokens.tertiaryText)
                .textCase(.uppercase)
            content()
        }
        .padding(16)
        .background(DesignTokens.contentSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(DesignTokens.separator.opacity(0.72)))
    }

    private func alwaysOnMetaCard(items: [(String, String)]) -> some View {
        alwaysOnMetaList(items: items)
            .padding(16)
            .background(DesignTokens.contentSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(DesignTokens.separator.opacity(0.72)))
    }

    private func alwaysOnMetaList(items: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(items, id: \.0) { item in
                AlwaysOnMetaItem(title: item.0, value: item.1)
            }
        }
    }

    private func alwaysOnInteractiveMetaCard(_ items: [AlwaysOnMetaDisplayItem]) -> some View {
        alwaysOnInteractiveMetaList(items)
            .padding(16)
            .background(DesignTokens.contentSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(DesignTokens.separator.opacity(0.72)))
    }

    private func alwaysOnInteractiveMetaList(_ items: [AlwaysOnMetaDisplayItem]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(items) { item in
                AlwaysOnMetaItem(title: item.title, value: item.value, action: item.action)
            }
        }
    }

    private func alwaysOnContextRefs(_ groups: [NativeAlwaysOnContextRefGroup], language: ResolvedAppLanguage) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if groups.isEmpty {
                Text(language == .chineseSimplified ? "无" : "None")
                    .font(.system(size: 13))
                    .foregroundStyle(DesignTokens.tertiaryText)
            } else {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.label)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(DesignTokens.tertiaryText)
                            .textCase(.uppercase)
                        ForEach(group.values, id: \.self) { value in
                            Text(value)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(DesignTokens.secondaryText)
                                .lineLimit(3)
                                .truncationMode(.middle)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(DesignTokens.cardSurfaceSubtle, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                    }
                }
            }
        }
    }

    private func planDetail(_ plan: AlwaysOnPlan, projectRoot: String) -> some View {
        let language = state.settings.language.resolved()
        let row = NativeAlwaysOnRows.planRow(plan)
        let groups = NativeAlwaysOnPlanDetailPresentation.contextRefGroups(plan, language: language)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        selectedPlan = nil
                    } label: {
                        Label(state.t(.back), systemImage: "arrow.left")
                    }
                    .buttonStyle(WebToolbarButtonStyle())
                    Text(NativeAlwaysOnPlanDetailPresentation.detailTitle(plan))
                        .font(.system(size: 20, weight: .semibold))
                        .lineLimit(2)
                }
                Spacer()
                HStack(spacing: 6) {
                    Button(state.t(.run)) {
                        runPlan(plan, projectRoot: projectRoot)
                    }
                    .buttonStyle(WebToolbarButtonStyle(isProminent: true))
                    .disabled(!row.canRun)
                    Button(state.t(.archive)) {
                        try? state.alwaysOnService.archive(plan: plan, projectRoot: projectRoot)
                        selectedPlan = nil
                        state.bumpToolRefresh()
                    }
                    .buttonStyle(WebToolbarButtonStyle())
                    .disabled(!row.canArchiveOrDelete)
                }
            }
            .padding(.bottom, 14)
            .overlay(alignment: .bottom) { Rectangle().fill(DesignTokens.separator.opacity(0.72)).frame(height: 1) }

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    if !plan.summary.isEmpty || !plan.rationale.isEmpty {
                        alwaysOnDetailSection(title: NativeAlwaysOnPlanDetailPresentation.sectionTitle(.summary, language: language)) {
                            VStack(alignment: .leading, spacing: 10) {
                                if !plan.summary.isEmpty {
                                    Text(plan.summary)
                                        .font(.system(size: 13))
                                        .foregroundStyle(DesignTokens.text)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                if !plan.rationale.isEmpty {
                                    Text(plan.rationale)
                                        .font(.system(size: 13))
                                        .foregroundStyle(DesignTokens.secondaryText)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    alwaysOnDetailSection(title: NativeAlwaysOnPlanDetailPresentation.sectionTitle(.planMarkdown, language: language)) {
                        MarkdownPreview(text: plan.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? state.t(.noPlanContent) : plan.content)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 14) {
                    alwaysOnMetaCard(items: NativeAlwaysOnPlanDetailPresentation.metaItems(plan, projectRoot: projectRoot, language: language))
                    alwaysOnDetailSection(title: NativeAlwaysOnPlanDetailPresentation.sectionTitle(.contextRefs, language: language)) {
                        alwaysOnContextRefs(groups, language: language)
                    }
                }
                .frame(width: 320, alignment: .topLeading)
            }
        }
    }

    private func historyView(_ history: [AlwaysOnRunHistory], projectRoot: String) -> some View {
        let language = state.settings.language.resolved()
        let rows = history
            .filter(NativeAlwaysOnRunHistoryRows.isVisible)
            .map { NativeAlwaysOnRunHistoryRows.row($0, language: language) }
        return VStack(alignment: .leading, spacing: 12) {
            if let selectedRun {
                runHistoryDetail(selectedRun, projectRoot: selectedDetailProjectRoot ?? projectRoot)
            } else if rows.isEmpty {
                Text(state.t(.noAlwaysOnRuns))
                    .font(.system(size: 13))
                    .foregroundStyle(DesignTokens.tertiaryText)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        ForEach(Array(NativeAlwaysOnRunHistoryRows.columns(language: language).enumerated()), id: \.offset) { index, title in
                            Text(title)
                                .frame(width: NativeAlwaysOnRunHistoryRows.columnWidths[index], alignment: .leading)
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DesignTokens.tertiaryText)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                    .overlay(alignment: .bottom) { Rectangle().fill(DesignTokens.separator.opacity(0.72)).frame(height: 1) }

                    ForEach(rows) { row in
                        Button {
                            selectedRun = history.first { $0.id == row.id }
                            selectedDetailProjectRoot = projectRoot
                        } label: {
                            HStack(spacing: 12) {
                                Text(row.title)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(DesignTokens.accent)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(width: NativeAlwaysOnRunHistoryRows.columnWidths[0], alignment: .leading)
                                Text(row.kind)
                                    .textCase(.lowercase)
                                    .frame(width: NativeAlwaysOnRunHistoryRows.columnWidths[1], alignment: .leading)
                                Text(row.status)
                                    .frame(width: NativeAlwaysOnRunHistoryRows.columnWidths[2], alignment: .leading)
                                Text(row.started)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(DesignTokens.tertiaryText)
                                    .frame(width: NativeAlwaysOnRunHistoryRows.columnWidths[3], alignment: .leading)
                                Text(row.source)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(DesignTokens.tertiaryText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(width: NativeAlwaysOnRunHistoryRows.columnWidths[4], alignment: .leading)
                                Text(row.session)
                                    .frame(width: NativeAlwaysOnRunHistoryRows.columnWidths[5], alignment: .leading)
                            }
                            .font(.system(size: 12))
                            .foregroundStyle(DesignTokens.secondaryText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .overlay(alignment: .bottom) { Rectangle().fill(DesignTokens.separator.opacity(0.45)).frame(height: 1) }
                    }
                }
                .frame(minWidth: 880, alignment: .leading)
            }
        }
    }

    private func runHistoryDetail(_ run: AlwaysOnRunHistory, projectRoot: String) -> some View {
        let language = state.settings.language.resolved()
        let metadataEntries = NativeAlwaysOnRunHistoryDetailPresentation.metadataEntries(run)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Button { selectedRun = nil } label: { Label(state.t(.back), systemImage: "arrow.left") }
                        .buttonStyle(WebToolbarButtonStyle())
                    Text(NativeAlwaysOnRunHistoryDetailPresentation.title(run, language: language))
                        .font(.system(size: 20, weight: .semibold))
                    Text("\(run.kind) · \(run.status.rawValue) · \(relativeDate(run.startedAt))")
                        .font(.system(size: 13))
                        .foregroundStyle(DesignTokens.secondaryText)
                }
                Spacer()
                if let cycleID = nonEmptyMetadataValue(run.metadata["cycleId"]) {
                    Button {
                        state.applyAlwaysOnCycle(cycleID: cycleID, projectRoot: projectRoot)
                    } label: {
                        Label(localized("Apply Cycle", "应用 Cycle"), systemImage: "arrow.triangle.merge")
                    }
                    .buttonStyle(WebToolbarButtonStyle(isProminent: true))
                }
                Button(state.t(.refresh)) {
                    refreshSelectedRunDetail(projectRoot: projectRoot)
                }
                .buttonStyle(WebToolbarButtonStyle())
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(state.t(.outputLog))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DesignTokens.tertiaryText)
                        .textCase(.uppercase)
                    HStack(spacing: 12) {
                        Text("\(state.t(.source)): \(NativeAlwaysOnRunHistoryDetailPresentation.logSource(run))")
                        Text("\(state.t(.lastUpdated)): \(NativeAlwaysOnRunHistoryDetailPresentation.logUpdatedAt(run))")
                        if NativeAlwaysOnRunHistoryDetailPresentation.isLogTruncated(run) {
                            Text(state.t(.truncated))
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.tertiaryText)
                    MonospaceOutput(text: NativeAlwaysOnRunHistoryDetailPresentation.outputLog(run, emptyText: state.t(.noOutputLog)))
                        .frame(minHeight: 360)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 8) {
                    Text(state.t(.metadata))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DesignTokens.tertiaryText)
                        .textCase(.uppercase)
                    if metadataEntries.isEmpty {
                        Text(state.t(.none))
                            .font(.system(size: 13))
                            .foregroundStyle(DesignTokens.tertiaryText)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(metadataEntries, id: \.key) { item in
                                AlwaysOnMetaItem(
                                    title: item.key,
                                    value: item.value,
                                    action: metadataAction(for: item.key, value: item.value, run: run, projectRoot: projectRoot)
                                )
                            }
                        }
                    }
                }
                .frame(width: 320, alignment: .topLeading)
            }
            .padding(14)
            .background(DesignTokens.contentSurface, in: RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous).stroke(DesignTokens.separator.opacity(0.72)))
        }
    }

    private func refreshSelectedRunDetail(projectRoot: String) {
        guard let selectedRun,
              let refreshed = state.alwaysOnService.runHistoryDetail(projectRoot: projectRoot, runID: selectedRun.id)
        else { return }
        self.selectedRun = refreshed
        state.bumpToolRefresh()
    }

    private func pollSelectedRunLog(context: WorkspaceContext) {
        guard let selectedRun, selectedRun.shouldPollLog else { return }
        if let refreshed = state.alwaysOnService.runHistoryDetail(projectRoot: selectedDetailProjectRoot ?? context.rootPath, runID: selectedRun.id) {
            self.selectedRun = refreshed
        }
        state.bumpToolRefresh()
    }

    private func openCronSession(_ row: NativeAlwaysOnRow) {
        guard let job = row.cronJob,
              let target = NativeAlwaysOnCronDetailPresentation.latestRunTarget(job) else { return }
        state.openAlwaysOnSession(target)
    }

    private func cronOriginSessionAction(_ job: AlwaysOnCronJob) -> (() -> Void)? {
        guard let sessionId = job.originSessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionId.isEmpty
        else { return nil }
        return { state.openAlwaysOnSession(.origin(sessionId: sessionId)) }
    }

    private func cronLatestRunSessionAction(_ job: AlwaysOnCronJob) -> (() -> Void)? {
        guard let target = NativeAlwaysOnCronDetailPresentation.latestRunTarget(job) else { return nil }
        return { state.openAlwaysOnSession(target) }
    }

    private func sessionForRun(_ run: AlwaysOnRunHistory) -> ProjectSession? {
        guard let target = NativeAlwaysOnRunHistoryDetailPresentation.sessionTarget(run) else { return nil }
        return AlwaysOnBackgroundTranscriptLoader.makeSession(
            target: target,
            existing: state.selectedProject?.allSessions.first { $0.id == target.sessionId }
        )
    }

    private func visibleRunMetadataEntries(_ run: AlwaysOnRunHistory) -> [(key: String, value: String)] {
        NativeAlwaysOnRunMetadata.visibleEntries(run.metadata)
    }

    private func metadataAction(for key: String, value: String, run: AlwaysOnRunHistory, projectRoot: String) -> (() -> Void)? {
        if key == "sessionId", let target = NativeAlwaysOnRunHistoryDetailPresentation.sessionTarget(run) {
            return { openSession(target, projectRoot: projectRoot) }
        }
        if key == "originSessionId" {
            let sessionId = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sessionId.isEmpty, sessionId != "—" else { return nil }
            return { openSession(.origin(sessionId: sessionId), projectRoot: projectRoot) }
        }
        return nil
    }

    private func nonEmptyMetadataValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    private func generalView() -> some View {
        let snapshot = state.alwaysOnDashboardSnapshot(scope: nil)
        let groups = projectGroups(scope: nil)
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                HStack(spacing: 2) {
                    TabButton(localized("Dashboard", "看板"), isActive: subtab == .dashboard) {
                        subtab = .dashboard
                        clearAlwaysOnSelection()
                    }
                    TabButton(state.t(.plansCronJobs), isActive: subtab == .items) {
                        subtab = .items
                        clearAlwaysOnSelection(keepRun: false)
                    }
                }
                .padding(3)
                .background(GlassControlBackground(isActive: false, cornerRadius: 16, material: .popover, showsShadow: false))
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .overlay(alignment: .bottom) { Rectangle().fill(DesignTokens.separator).frame(height: 1) }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(state.t(.alwaysOn))
                                .font(.system(size: 20, weight: .semibold))
                            Text(localized("Global background automation across enabled projects.", "所有已启用项目的后台自动化。"))
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

                    if let selectedPlan {
                        planDetail(selectedPlan, projectRoot: selectedDetailProjectRoot ?? "")
                    } else if let selectedCronJob {
                        cronDetail(selectedCronJob, projectRoot: selectedDetailProjectRoot ?? "")
                    } else if let selectedRun {
                        runHistoryDetail(selectedRun, projectRoot: selectedDetailProjectRoot ?? "")
                    } else if subtab == .items {
                        groupedItemsView(groups: groups)
                    } else {
                        dashboardContent(snapshot: snapshot, groups: groups)
                    }
                }
                .frame(maxWidth: 1120, alignment: .topLeading)
                .padding(.horizontal, 28)
                .padding(.vertical, 18)
            }
        }
        .background(Color.clear)
    }

    private func dashboardContent(snapshot: AlwaysOnDashboardSnapshot, groups: [AlwaysOnProjectItemsGroup]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                RoutingStatCard(icon: "folder.badge.gearshape", label: localized("Enabled Projects", "启用项目"), value: "\(snapshot.enabledProjects)/\(snapshot.totalProjects)", detail: localized("participating", "已加入"))
                RoutingStatCard(icon: "checklist", label: localized("Ready Plans", "待执行计划"), value: "\(snapshot.readyPlans)", detail: localized("manual runnable", "可手动运行"))
                RoutingStatCard(icon: "dot.radiowaves.left.and.right", label: localized("Running", "运行中"), value: "\(snapshot.runningCount)", detail: localized("background sessions", "后台会话"))
                RoutingStatCard(icon: "calendar", label: localized("Today", "今日事件"), value: "\(snapshot.todayEvents)", detail: localized("activity events", "活动事件"))
            }

            if groups.count > 1 {
                ToolSection(title: localized("Projects", "项目")) {
                    VStack(spacing: 8) {
                        ForEach(groups) { group in
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(group.dashboard?.enabled == true ? DesignTokens.success : DesignTokens.tertiaryText.opacity(0.45))
                                    .frame(width: 7, height: 7)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(group.identity.displayName)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(DesignTokens.text)
                                        .lineLimit(1)
                                    Text(group.identity.rootPath)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(DesignTokens.tertiaryText)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                compactMetric("\(group.dashboard?.readyPlans ?? 0)", localized("plans", "计划"))
                                compactMetric("\(group.cronJobs.count)", "cron")
                                compactMetric(group.dashboard?.lastGate ?? "—", localized("gate", "门控"))
                                if let context = context(forProjectRoot: group.identity.rootPath) {
                                    Button {
                                        startDiscovery(context: context)
                                    } label: {
                                        Image(systemName: "sparkles")
                                    }
                                    .help(state.t(.discover))
                                    .buttonStyle(WebToolbarButtonStyle())
                                    .disabled(group.dashboard?.enabled != true)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(DesignTokens.cardSurfaceSubtle, in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: DesignTokens.smallRadius).stroke(DesignTokens.separator.opacity(0.56)))
                        }
                    }
                }
            }

            HStack(alignment: .top, spacing: 14) {
                ToolSection(title: localized("Timeline", "时间线")) {
                    timelineRows(snapshot.recentEvents)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                ToolSection(title: localized("Runs", "运行")) {
                    recentRunRows(groups: groups)
                }
                .frame(width: 340, alignment: .topLeading)
            }
        }
    }

    private func groupedItemsView(groups: [AlwaysOnProjectItemsGroup]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if groups.allSatisfy({ $0.rows.isEmpty }) {
                Text(state.t(.noActivePlans))
                    .font(.system(size: 13))
                    .foregroundStyle(DesignTokens.tertiaryText)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DesignTokens.contentSurface, in: RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DesignTokens.radius).stroke(DesignTokens.separator.opacity(0.72)))
            } else {
                ForEach(groups.filter { !$0.rows.isEmpty }) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text(group.identity.displayName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(DesignTokens.text)
                            Text(group.identity.rootPath)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(DesignTokens.tertiaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        ForEach(group.rows) { row in
                            compactItemRow(row, projectRoot: group.identity.rootPath)
                        }
                    }
                    .padding(16)
                    .background(DesignTokens.contentSurface, in: RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DesignTokens.radius).stroke(DesignTokens.separator.opacity(0.72)))
                }
            }
        }
    }

    private func compactItemRow(_ row: NativeAlwaysOnRow, projectRoot: String) -> some View {
        let item = NativeAlwaysOnItemsRows.row(row)
        return HStack(spacing: 12) {
            Image(systemName: row.kind == .plan ? "list.bullet.clipboard" : "calendar.badge.clock")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(DesignTokens.tertiaryText)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 5) {
                Button {
                    switch row.kind {
                    case .plan:
                        selectedPlan = row.plan
                    case .cron:
                        selectedCronJob = row.cronJob
                    }
                    selectedDetailProjectRoot = projectRoot
                } label: {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DesignTokens.accent)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .buttonStyle(.plain)
                HStack(spacing: 7) {
                    Text(item.type)
                    Text(item.status)
                        .foregroundStyle(statusTint(row.plan?.executionStatus ?? row.plan?.status ?? row.cronJob?.status ?? .unknown))
                    Text("\(localized("Created", "创建")) \(item.created)")
                    Text("\(localized("Triggered", "触发")) \(item.triggered)")
                }
                .font(.system(size: 11))
                .foregroundStyle(DesignTokens.tertiaryText)
                .lineLimit(1)
            }
            Spacer()
            HStack(spacing: 6) {
                Button {
                    switch row.kind {
                    case .plan:
                        selectedPlan = row.plan
                    case .cron:
                        selectedCronJob = row.cronJob
                    }
                    selectedDetailProjectRoot = projectRoot
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .help(state.t(.view))
                .buttonStyle(WebToolbarButtonStyle())

                Button {
                    if let plan = row.plan {
                        runPlan(plan, projectRoot: projectRoot)
                    } else if let job = row.cronJob {
                        runCronJob(job, projectRoot: projectRoot)
                    }
                } label: {
                    Image(systemName: "play.fill")
                }
                .help(state.t(.run))
                .buttonStyle(WebToolbarButtonStyle(isProminent: true))
                .disabled(!row.canRun)

                Button {
                    if let plan = row.plan {
                        try? state.alwaysOnService.archive(plan: plan, projectRoot: projectRoot)
                    } else if let job = row.cronJob {
                        _ = try? state.alwaysOnService.deleteCronJob(jobID: job.id, projectRoot: projectRoot)
                    }
                    clearAlwaysOnSelection()
                    state.bumpToolRefresh()
                } label: {
                    Image(systemName: row.kind == .plan ? "archivebox" : "trash")
                }
                .help(row.kind == .plan ? state.t(.archive) : state.t(.delete))
                .buttonStyle(WebToolbarButtonStyle())
                .disabled(!row.canArchiveOrDelete)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(DesignTokens.cardSurfaceSubtle, in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.smallRadius).stroke(DesignTokens.separator.opacity(0.56)))
    }

    private func timelineRows(_ events: [AlwaysOnEvent]) -> some View {
        VStack(spacing: 0) {
            if events.isEmpty {
                Text(localized("No Always-On activity yet.", "暂无 Always-On 活动。"))
                    .font(.system(size: 13))
                    .foregroundStyle(DesignTokens.tertiaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(events.prefix(18)) { event in
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .fill(statusTint(event.status))
                            .frame(width: 7, height: 7)
                            .padding(.top, 6)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(event.title)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(DesignTokens.text)
                                    .lineLimit(1)
                                Text(event.kind)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(statusTint(event.status))
                                Spacer()
                                Text(NativeAlwaysOnUpdatedLabel.relativeText(event.createdAt, language: state.settings.language.resolved()))
                                    .font(.system(size: 11))
                                    .foregroundStyle(DesignTokens.tertiaryText)
                            }
                            Text(event.detail.isEmpty ? event.projectName : event.detail)
                                .font(.system(size: 12))
                                .foregroundStyle(DesignTokens.tertiaryText)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 9)
                    .overlay(alignment: .bottom) { Rectangle().fill(DesignTokens.separator.opacity(0.45)).frame(height: 1) }
                }
            }
        }
    }

    private func recentRunRows(groups: [AlwaysOnProjectItemsGroup]) -> some View {
        let runs = groups
            .flatMap { group in group.history.prefix(6).map { (group.identity, $0) } }
            .sorted { $0.1.startedAt > $1.1.startedAt }
            .prefix(8)
        return VStack(spacing: 8) {
            if runs.isEmpty {
                Text(state.t(.noAlwaysOnRuns))
                    .font(.system(size: 13))
                    .foregroundStyle(DesignTokens.tertiaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(runs), id: \.1.id) { item in
                    Button {
                        selectedRun = item.1
                        selectedDetailProjectRoot = item.0.rootPath
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.1.kind == "cron" ? "calendar.badge.clock" : "list.bullet.clipboard")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(statusTint(item.1.status))
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.1.title)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(DesignTokens.text)
                                    .lineLimit(1)
                                Text("\(item.0.displayName) · \(item.1.status.rawValue)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(DesignTokens.tertiaryText)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(DesignTokens.cardSurfaceSubtle, in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func projectGroups(scope: WorkspaceContext?) -> [AlwaysOnProjectItemsGroup] {
        let snapshot = state.alwaysOnDashboardSnapshot(scope: scope)
        let identities: [AlwaysOnProjectIdentity]
        if let scope, !scope.isGeneral {
            identities = [
                AlwaysOnProjectIdentity(
                    id: AlwaysOnService.normalizedProjectRoot(scope.rootPath),
                    projectName: scope.projectName,
                    displayName: scope.displayName,
                    rootPath: scope.rootPath,
                    isGeneral: false
                ),
            ]
        } else {
            identities = state.alwaysOnProjectIdentities()
        }
        let dashboardByRoot = Dictionary(
            uniqueKeysWithValues: snapshot.projects.map { (AlwaysOnService.normalizedProjectRoot($0.rootPath), $0) }
        )
        return identities.map { identity in
            let plans = state.alwaysOnService.plans(projectRoot: identity.rootPath)
            let cronJobs = state.alwaysOnService.cronJobs(projectRoot: identity.rootPath)
            let history = state.alwaysOnService.runHistory(projectRoot: identity.rootPath)
            return AlwaysOnProjectItemsGroup(
                identity: identity,
                dashboard: dashboardByRoot[AlwaysOnService.normalizedProjectRoot(identity.rootPath)],
                plans: plans,
                cronJobs: cronJobs,
                history: history,
                rows: NativeAlwaysOnRows.rows(plans: plans, cronJobs: cronJobs)
            )
        }
        .sorted { left, right in
            let leftDate = left.dashboard?.lastRunAt ?? left.plans.first?.updatedAt ?? .distantPast
            let rightDate = right.dashboard?.lastRunAt ?? right.plans.first?.updatedAt ?? .distantPast
            if leftDate == rightDate {
                return left.identity.displayName.localizedStandardCompare(right.identity.displayName) == .orderedAscending
            }
            return leftDate > rightDate
        }
    }

    private func context(forProjectRoot projectRoot: String) -> WorkspaceContext? {
        let normalized = AlwaysOnService.normalizedProjectRoot(projectRoot)
        let project = state.projects.first { AlwaysOnService.normalizedProjectRoot($0.rootPath) == normalized }
        let identity = state.alwaysOnProjectIdentities().first { AlwaysOnService.normalizedProjectRoot($0.rootPath) == normalized }
        guard let identity else { return nil }
        return WorkspaceContext(
            projectID: project?.id,
            projectName: identity.projectName,
            displayName: identity.displayName,
            rootPath: identity.rootPath,
            isGeneral: false
        )
    }

    private func openSession(_ target: AlwaysOnSessionTarget, projectRoot: String) {
        let normalized = AlwaysOnService.normalizedProjectRoot(projectRoot)
        if let project = state.projects.first(where: { AlwaysOnService.normalizedProjectRoot($0.rootPath) == normalized }) {
            state.selectedProjectID = project.id
        }
        state.openAlwaysOnSession(target)
    }

    private func compactMetric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(DesignTokens.secondaryText)
                .lineLimit(1)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(DesignTokens.tertiaryText)
        }
        .frame(width: 72, alignment: .trailing)
    }

    private func statusTint(_ status: AlwaysOnStatus) -> Color {
        switch status {
        case .completed, .ready, .applied:
            return DesignTokens.success
        case .running, .executing, .reporting, .queued, .scheduled, .applying:
            return DesignTokens.accent
        case .failed, .applyFailed:
            return DesignTokens.danger
        case .noPlan, .draft, .superseded, .archived, .unknown:
            return DesignTokens.tertiaryText
        }
    }

    private func clearAlwaysOnSelection(keepRun: Bool = false) {
        selectedPlan = nil
        selectedCronJob = nil
        if !keepRun {
            selectedRun = nil
        }
        selectedDetailProjectRoot = nil
    }

    private func localized(_ english: String, _ chinese: String) -> String {
        state.settings.language.resolved() == .chineseSimplified ? chinese : english
    }
}

private struct AlwaysOnProjectItemsGroup: Identifiable, Hashable {
    var identity: AlwaysOnProjectIdentity
    var dashboard: AlwaysOnProjectDashboard?
    var plans: [AlwaysOnPlan]
    var cronJobs: [AlwaysOnCronJob]
    var history: [AlwaysOnRunHistory]
    var rows: [NativeAlwaysOnRow]

    var id: String { identity.id }
}

private struct AlwaysOnMetaItem: View {
    var title: String
    var value: String
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DesignTokens.tertiaryText)
                .textCase(.uppercase)
            if let action, value != "—" {
                Button(action: action) {
                    Text(value)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignTokens.accent)
            } else {
                Text(value)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(DesignTokens.secondaryText)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AlwaysOnMetaDisplayItem: Identifiable {
    var id: String { title }
    var title: String
    var value: String
    var action: (() -> Void)? = nil
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
    var loadState: FileEditorLoadState
    @State private var markdownPreview = false
    @State private var saveFlash = false

    private var isBinaryFile: Bool {
        WorkspaceService.isProbablyBinaryFile(path: file.path)
    }

    private var canEditText: Bool {
        loadState.canSave && !file.isImage && !file.isPDF && !isBinaryFile
    }

    private var isDirty: Bool {
        content != originalContent
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: headerIconName)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .font(.system(size: 13, weight: .semibold))
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
                        if let previewIcon = FilePreviewActionPolicy.editorPreviewToggleIcon(for: file, isPreviewing: markdownPreview) {
                            Button { markdownPreview.toggle() } label: {
                                Image(systemName: previewIcon)
                            }
                                .buttonStyle(EditorHeaderIconButtonStyle())
                                .help(markdownPreview ? "Edit Markdown" : "Preview Markdown")
                        }
                        Button { download() } label: { Image(systemName: "square.and.arrow.down") }
                            .buttonStyle(EditorHeaderIconButtonStyle())
                            .help(state.t(.download))
                        if canEditText {
                            Button { onRevert() } label: { Image(systemName: "arrow.uturn.backward") }
                                .buttonStyle(EditorHeaderIconButtonStyle())
                                .disabled(!isDirty)
                                .help(state.t(.revert))
                            Button { performSave() } label: {
                                Image(systemName: saveFlash ? "checkmark" : "tray.and.arrow.down")
                            }
                                .buttonStyle(EditorHeaderIconButtonStyle(isActive: isDirty || saveFlash, tint: isDirty || saveFlash ? DesignTokens.accent : DesignTokens.secondaryText))
                                .disabled(!isDirty)
                                .keyboardShortcut("s", modifiers: .command)
                                .help(state.t(.save))
                        }
                        Button { onToggleExpand() } label: { Image(systemName: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }
                            .buttonStyle(EditorHeaderIconButtonStyle())
                        Button { attemptClose() } label: { Image(systemName: "xmark") }
                            .buttonStyle(EditorHeaderIconButtonStyle())
                    }
                    .frame(minWidth: 0, alignment: .trailing)
                }
                .frame(maxWidth: 360, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            .background(DesignTokens.background)
            .overlay(alignment: .bottom) { Rectangle().fill(DesignTokens.separator).frame(height: 1) }
            .zIndex(1)

            if file.isImage, let image = NSImage(contentsOfFile: file.path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
            } else if FilePreviewActionPolicy.usesNativePDFPreview(for: file) {
                PDFDocumentPreview(url: URL(fileURLWithPath: file.path))
            } else if case .loading = loadState {
                FilePaneStatusView(
                    title: editorText(english: "Loading file", chinese: "正在加载文件"),
                    detail: file.relativePath,
                    systemImage: "arrow.clockwise",
                    isLoading: true
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if case let .failed(message) = loadState {
                FilePaneStatusView(
                    title: editorText(english: "Could not load file", chinese: "无法加载文件"),
                    detail: message,
                    systemImage: "exclamationmark.triangle"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if case let .unsupported(message) = loadState {
                FilePaneStatusView(
                    title: editorText(english: "Cannot edit this file", chinese: "无法编辑此文件"),
                    detail: message,
                    systemImage: "doc.badge.exclamationmark"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if file.isMarkdown && markdownPreview {
                ScrollView {
                    MarkdownPreview(text: content)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else if isBinaryFile {
                ToolEmptyState(
                    title: editorText(english: "Binary File", chinese: "二进制文件"),
                    detail: editorText(
                        english: "\(file.name) cannot be displayed in the text editor.",
                        chinese: "\(file.name) 不能在文本编辑器中显示。"
                    ),
                    systemImage: "doc.zipper"
                )
            } else {
                CodeEditorWithChrome(
                    text: $content,
                    fileName: file.name,
                    fontSize: CGFloat(state.settings.codeEditor.fontSize),
                    wordWrap: state.settings.codeEditor.wordWrap,
                    lineNumbers: state.settings.codeEditor.lineNumbers,
                    showMinimap: state.settings.codeEditor.showMinimap,
                    onSave: {
                        if isDirty {
                            performSave()
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

    private var headerIconName: String {
        if file.isImage { return "photo" }
        if file.isPDF { return "doc.richtext" }
        if file.isMarkdown { return "doc.richtext" }
        if file.isHTML { return "chevron.left.forwardslash.chevron.right" }
        return "doc.text"
    }

    private func editorText(english: String, chinese: String) -> String {
        state.settings.language.resolved() == .chineseSimplified ? chinese : english
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

    private func performSave() {
        guard isDirty, canEditText else { return }
        onSave()
        saveFlash = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            saveFlash = false
        }
    }

    private func attemptClose() {
        guard isDirty else {
            onClose()
            return
        }
        let alert = NSAlert()
        alert.messageText = editorText(english: "Close without saving \(file.name)?", chinese: "不保存并关闭 \(file.name)？")
        alert.informativeText = editorText(english: "Unsaved changes will be lost.", chinese: "未保存的更改会丢失。")
        alert.addButton(withTitle: editorText(english: "Close", chinese: "关闭"))
        alert.addButton(withTitle: state.t(.cancel))
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        onClose()
    }

}

private struct PDFDocumentPreview: NSViewRepresentable {
    var url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .clear
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.documentURL != url {
            nsView.document = PDFDocument(url: url)
        }
        nsView.autoScales = true
    }
}

private struct FileTreeRow: View {
    @EnvironmentObject private var state: AppState
    var file: WorkspaceFile
    var isSelected: Bool
    var isEditing: Bool
    var editText: String?
    var onOpen: () -> Void
    var onPreviewHTML: () -> Void
    var onDownload: () -> Void
    var onCopyPath: () -> Void
    var onNewFile: () -> Void
    var onNewFolder: () -> Void
    var onDelete: () -> Void
    var onRename: () -> Void
    var onCommitEdit: (String) -> Void
    var onCancelEdit: () -> Void
    @State private var draftName = ""

    var body: some View {
        Group {
            if isEditing {
                editRow
            } else {
                rowButton
            }
        }
        .contextMenu {
            if file.isDirectory {
                Button(state.t(.newFile), action: onNewFile)
                Button(state.t(.newFolder), action: onNewFolder)
                Divider()
            }
            if !file.isDirectory {
                Button(state.t(.download), action: onDownload)
                if file.isHTML {
                    Button(state.t(.openHTML), action: onPreviewHTML)
                }
            }
            Button(state.t(.copyPath), action: onCopyPath)
            Button(state.t(.rename), action: onRename)
            Divider()
            Button(state.t(.delete), role: .destructive, action: onDelete)
        }
        .onAppear {
            if draftName.isEmpty {
                draftName = editText ?? file.name
            }
        }
        .onChange(of: editText) { _, value in
            draftName = value ?? file.name
        }
    }

    private var rowButton: some View {
        HStack(spacing: 6) {
            indentation
            disclosure
            fileIcon
            Text(file.name)
                .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                .lineLimit(1)
            Spacer(minLength: 8)
            rowActions
        }
        .padding(.horizontal, 6)
        .frame(height: FileWorkspaceLayoutMetrics.treeRowHeight)
        .foregroundStyle(DesignTokens.text)
        .background(
            isSelected ? DesignTokens.selectedRowFill() : Color.clear,
            in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius)
        )
        .contentShape(RoundedRectangle(cornerRadius: DesignTokens.smallRadius))
        .onTapGesture(perform: onOpen)
    }

    private var editRow: some View {
        HStack(spacing: 6) {
            indentation
            Spacer().frame(width: 12)
            fileIcon
            TextField(file.name, text: $draftName)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .padding(.horizontal, 6)
                .frame(height: FileWorkspaceLayoutMetrics.inlineFieldHeight)
                .background(DesignTokens.contentSurface, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(DesignTokens.accent.opacity(0.65), lineWidth: 1)
                )
                .onSubmit { onCommitEdit(draftName) }
                .onExitCommand(perform: onCancelEdit)
        }
        .padding(.horizontal, 6)
        .frame(height: FileWorkspaceLayoutMetrics.treeRowHeight)
        .onAppear { draftName = editText ?? file.name }
    }

    private var indentation: some View {
        Spacer().frame(width: CGFloat(file.depth * 18))
    }

    @ViewBuilder
    private var disclosure: some View {
        if file.isDirectory {
            Image(systemName: "chevron.right")
                .rotationEffect(.degrees(file.isExpanded ? 90 : 0))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DesignTokens.tertiaryText)
                .frame(width: 12)
        } else {
            Spacer().frame(width: 12)
        }
    }

    private var fileIcon: some View {
        Image(systemName: iconName)
            .font(.system(size: 13))
            .foregroundStyle(file.isDirectory ? DesignTokens.warning : iconColor)
            .frame(width: 15)
    }

    @ViewBuilder
    private var rowActions: some View {
        if let icon = FilePreviewActionPolicy.treePreviewIcon(for: file) {
            Button(action: onPreviewHTML) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(InlineIconButtonStyle(tint: DesignTokens.accent))
            .help(state.t(.openHTML))
            .accessibilityLabel(state.t(.openHTML))
        }
    }

    private var iconName: String {
        if file.isDirectory { return "folder" }
        if file.isMarkdown { return "doc.richtext" }
        if file.isHTML { return "chevron.left.forwardslash.chevron.right" }
        if file.isPDF { return "doc.richtext" }
        if file.isImage { return "photo" }
        return "doc.text"
    }

    private var iconColor: Color {
        if file.isMarkdown { return DesignTokens.accent }
        if file.isHTML { return DesignTokens.tertiaryText }
        if file.isPDF { return DesignTokens.danger.opacity(0.82) }
        if file.isImage { return DesignTokens.warning }
        return DesignTokens.tertiaryText
    }
}

private struct FileInlineEditRow: View {
    var edit: FileInlineEdit
    var onCommit: (String) -> Void
    var onCancel: () -> Void
    @State private var value = ""

    var body: some View {
        HStack(spacing: 6) {
            Spacer().frame(width: CGFloat(edit.depth * 18))
            Spacer().frame(width: 12)
            Image(systemName: edit.iconName)
                .font(.system(size: 13))
                .foregroundStyle(edit.kind == .createFolder ? DesignTokens.warning : DesignTokens.tertiaryText)
                .frame(width: 15)
            TextField(edit.text, text: $value)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .padding(.horizontal, 6)
                .frame(height: FileWorkspaceLayoutMetrics.inlineFieldHeight)
                .background(DesignTokens.contentSurface, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(DesignTokens.accent.opacity(0.65), lineWidth: 1)
                )
                .onSubmit { onCommit(value) }
                .onExitCommand(perform: onCancel)
        }
        .padding(.horizontal, 6)
        .frame(height: FileWorkspaceLayoutMetrics.treeRowHeight)
        .onAppear { value = edit.text }
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
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous))
            .opacity(configuration.isPressed ? 0.74 : 1)
    }
}

struct CodeLineNumberMetrics {
    static let editorTextInset = NSSize(width: 14, height: 14)
    static let editorTextInsetAfterLineNumberGutter: CGFloat = 12

    static func lineCount(in text: String) -> Int {
        max(1, text.components(separatedBy: .newlines).count)
    }

    static func rulerWidth(lineCount: Int, digitWidth: CGFloat = 7) -> CGFloat {
        let digits = max(2, String(max(1, lineCount)).count)
        return max(48, CGFloat(digits) * digitWidth + 28)
    }

    static func lineStarts(in text: String) -> [Int] {
        let nsText = text as NSString
        guard nsText.length > 0 else { return [0] }

        var starts = [0]
        var searchRange = NSRange(location: 0, length: nsText.length)
        while searchRange.length > 0 {
            let newlineRange = nsText.range(of: "\n", options: [], range: searchRange)
            if newlineRange.location == NSNotFound { break }
            let nextStart = newlineRange.location + newlineRange.length
            starts.append(nextStart)
            let nextLocation = nextStart
            searchRange = NSRange(location: nextLocation, length: nsText.length - nextLocation)
        }
        return starts
    }

    static func lineNumber(forCharacterIndex characterIndex: Int, lineStarts: [Int]) -> Int {
        guard !lineStarts.isEmpty else { return 1 }
        let target = max(0, characterIndex)
        var lower = 0
        var upper = lineStarts.count
        while lower < upper {
            let mid = (lower + upper) / 2
            if lineStarts[mid] <= target {
                lower = mid + 1
            } else {
                upper = mid
            }
        }
        return max(1, lower)
    }

    static func textInset(lineNumbersVisible: Bool, lineCount: Int = 1) -> NSSize {
        guard lineNumbersVisible else { return editorTextInset }
        return NSSize(
            width: rulerWidth(lineCount: lineCount) + editorTextInsetAfterLineNumberGutter,
            height: editorTextInset.height
        )
    }
}

struct CodeMinimapLine: Equatable {
    var indentLevel: Int
    var widthFraction: Double
    var intensity: Double
    var isBlank: Bool
}

struct CodeMinimapSnapshot: Equatable {
    let totalLines: Int
    let lines: [CodeMinimapLine]
    let sampleStride: Int
    let signature: String

    static let empty = CodeMinimapSnapshot(text: "")

    init(text: String, maxLines: Int = 900) {
        let rawLines = text.components(separatedBy: .newlines)
        totalLines = max(1, rawLines.count)
        sampleStride = max(1, Int(ceil(Double(totalLines) / Double(max(1, maxLines)))))
        signature = Self.signature(for: text)

        var sampled: [CodeMinimapLine] = []
        var index = 0
        while index < rawLines.count {
            let upper = min(rawLines.count, index + sampleStride)
            let representative = rawLines[index..<upper].max { lhs, rhs in
                lhs.trimmingCharacters(in: .whitespacesAndNewlines).count <
                    rhs.trimmingCharacters(in: .whitespacesAndNewlines).count
            } ?? ""
            sampled.append(Self.line(from: representative))
            index += sampleStride
        }
        lines = sampled.isEmpty ? [Self.line(from: "")] : sampled
    }

    static func signature(for text: String) -> String {
        "\(text.utf16.count):\(text.hashValue)"
    }

    private static func line(from rawLine: String) -> CodeMinimapLine {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let indent = rawLine.prefix { character in
            character == " " || character == "\t"
        }.reduce(0) { partial, character in
            partial + (character == "\t" ? 4 : 1)
        }
        let width = trimmed.isEmpty ? 0.18 : min(1, max(0.22, Double(trimmed.count) / 96))
        let intensity = trimmed.isEmpty ? 0.10 : min(0.66, 0.20 + Double(trimmed.count) / 150)
        return CodeMinimapLine(
            indentLevel: min(24, indent),
            widthFraction: width,
            intensity: intensity,
            isBlank: trimmed.isEmpty
        )
    }
}

struct CodeMinimapModel: Equatable {
    static let width: CGFloat = 64

    let totalLines: Int
    let lines: [CodeMinimapLine]
    let viewportStartFraction: Double
    let viewportHeightFraction: Double
    let sampleStride: Int

    init(text: String, visibleLineRange: Range<Int>? = nil, maxLines: Int = 900) {
        self.init(snapshot: CodeMinimapSnapshot(text: text, maxLines: maxLines), visibleLineRange: visibleLineRange)
    }

    init(snapshot: CodeMinimapSnapshot, visibleLineRange: Range<Int>? = nil) {
        totalLines = snapshot.totalLines
        lines = snapshot.lines
        sampleStride = snapshot.sampleStride
        let fallbackUpper = min(totalLines + 1, 32)
        let range = visibleLineRange ?? (1..<max(2, fallbackUpper))
        let lower = max(1, min(totalLines, range.lowerBound))
        let upper = max(lower + 1, min(totalLines + 1, range.upperBound))
        viewportStartFraction = min(1, max(0, Double(lower - 1) / Double(max(1, totalLines))))
        viewportHeightFraction = min(1, max(0.035, Double(upper - lower) / Double(max(1, totalLines))))
    }

    func lineNumber(atY y: CGFloat, height: CGFloat) -> Int {
        guard height > 0 else { return 1 }
        let fraction = min(1, max(0, Double(y / height)))
        return min(totalLines, max(1, Int((fraction * Double(totalLines)).rounded(.down)) + 1))
    }
}

enum CodeEditorScrollStabilityMetrics {
    static let visibleRangePublishInterval: TimeInterval = 0.12
    static let preservesScrollOriginOnUpdate = true
    static let minimapAllowsHitTesting = true
    static let editorBodyClipsRulerToContent = true
    static let minimapViewportMinHeight: CGFloat = 18

    static func horizontalOrigin(_ proposed: CGFloat, wordWrap: Bool, maxX: CGFloat) -> CGFloat {
        guard !wordWrap else { return 0 }
        return min(max(0, proposed), max(0, maxX))
    }
}

private struct CodeEditorWithChrome: View {
    @Binding var text: String
    var fileName: String
    var fontSize: CGFloat
    var wordWrap: Bool
    var lineNumbers: Bool
    var showMinimap: Bool
    var onSave: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var visibleLineRange: Range<Int>?
    @State private var minimapSeekLine: Int?
    @State private var minimapSnapshot = CodeMinimapSnapshot.empty

    var body: some View {
        GeometryReader { proxy in
            let minimapWidth = showMinimap ? CodeMinimapModel.width : 0
            let editorWidth = max(0, proxy.size.width - minimapWidth)

            HStack(spacing: 0) {
                FileContentTextEditor(
                    text: $text,
                    minimapSeekLine: $minimapSeekLine,
                    syntaxLanguage: CodeSyntaxHighlightingService.languageAlias(forFileName: fileName),
                    isDarkMode: colorScheme == .dark,
                    fontSize: fontSize,
                    wordWrap: wordWrap,
                    lineNumbers: lineNumbers,
                    layoutWidth: editorWidth,
                    onVisibleLineRangeChange: { range in
                        guard visibleLineRange != range else { return }
                        var transaction = Transaction()
                        transaction.animation = nil
                        withTransaction(transaction) {
                            visibleLineRange = range
                        }
                    },
                    onSave: onSave
                )
                .frame(width: editorWidth, height: proxy.size.height)

                if showMinimap {
                    CodeMinimapView(
                        model: CodeMinimapModel(snapshot: minimapSnapshot, visibleLineRange: visibleLineRange),
                        onSeekLine: { line in
                            guard minimapSeekLine != line else { return }
                            var transaction = Transaction()
                            transaction.animation = nil
                            withTransaction(transaction) {
                                minimapSeekLine = line
                            }
                        }
                    )
                        .frame(width: minimapWidth, height: proxy.size.height)
                        .transition(.identity)
                        .allowsHitTesting(CodeEditorScrollStabilityMetrics.minimapAllowsHitTesting)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignTokens.background)
        .clipped()
        .transaction { transaction in
            transaction.animation = nil
        }
        .onAppear {
            refreshMinimapSnapshotIfNeeded()
        }
        .onChange(of: text) { _, _ in
            refreshMinimapSnapshotIfNeeded()
        }
        .onChange(of: showMinimap) { _, enabled in
            if enabled {
                refreshMinimapSnapshotIfNeeded()
            }
        }
    }

    private func refreshMinimapSnapshotIfNeeded() {
        guard showMinimap else { return }
        let signature = CodeMinimapSnapshot.signature(for: text)
        guard minimapSnapshot.signature != signature else { return }
        minimapSnapshot = CodeMinimapSnapshot(text: text)
    }
}

private struct CodeMinimapView: View {
    var model: CodeMinimapModel
    var onSeekLine: (Int) -> Void
    @GestureState private var isDragging = false

    var body: some View {
        GeometryReader { proxy in
            Canvas(opaque: true, rendersAsynchronously: false) { context, size in
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .color(DesignTokens.background)
                )

                let count = max(1, model.lines.count)
                let rowHeight = max(1, size.height / CGFloat(count))

                for (index, line) in model.lines.enumerated() {
                    let y = CGFloat(index) * size.height / CGFloat(count)
                    let x = min(size.width - 12, 6 + CGFloat(line.indentLevel) * 0.65)
                    let availableWidth = max(5, size.width - x - 7)
                    let width = max(4, availableWidth * CGFloat(line.widthFraction))
                    let height = max(1, rowHeight * (line.isBlank ? 0.20 : 0.42))
                    let rect = CGRect(
                        x: x,
                        y: y + (rowHeight - height) / 2,
                        width: width,
                        height: height
                    )
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: 0.8),
                        with: .color(DesignTokens.tertiaryText.opacity(line.intensity))
                    )
                }

                let viewportY = CGFloat(model.viewportStartFraction) * size.height
                let viewportHeight = max(
                    CodeEditorScrollStabilityMetrics.minimapViewportMinHeight,
                    CGFloat(model.viewportHeightFraction) * size.height
                )
                let viewportRect = CGRect(
                    x: 4,
                    y: min(size.height - viewportHeight, viewportY),
                    width: max(0, size.width - 8),
                    height: viewportHeight
                )
                context.fill(
                    Path(roundedRect: viewportRect, cornerRadius: 4),
                    with: .color((isDragging ? DesignTokens.neutral500 : DesignTokens.neutral400).opacity(isDragging ? 0.26 : 0.18))
                )
                context.stroke(
                    Path(roundedRect: viewportRect, cornerRadius: 4),
                    with: .color((isDragging ? DesignTokens.neutral600 : DesignTokens.neutral500).opacity(isDragging ? 0.50 : 0.32)),
                    lineWidth: 1
                )
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isDragging) { _, state, _ in
                        state = true
                    }
                    .onChanged { value in
                        onSeekLine(model.lineNumber(atY: value.location.y, height: proxy.size.height))
                    }
            )
            .transaction { transaction in
                transaction.animation = nil
            }
        }
        .background(DesignTokens.background)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(DesignTokens.separator.opacity(0.72))
                .frame(width: 1)
        }
        .accessibilityLabel("Code minimap")
    }
}

private struct FileContentTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var minimapSeekLine: Int?
    var syntaxLanguage: String?
    var isDarkMode: Bool
    var fontSize: CGFloat
    var wordWrap: Bool
    var lineNumbers: Bool
    var layoutWidth: CGFloat
    var onVisibleLineRangeChange: (Range<Int>) -> Void
    var onSave: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = true
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !wordWrap
        scrollView.borderType = .noBorder
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.usesPredominantAxisScrolling = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        let textView = FileTextView()
        textView.delegate = context.coordinator
        configureRendering(in: scrollView, textView: textView)
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.usesFontPanel = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = NSColor.labelColor
        textView.insertionPointColor = NSColor.controlAccentColor
        textView.textContainerInset = CodeLineNumberMetrics.textInset(
            lineNumbersVisible: lineNumbers,
            lineCount: CodeLineNumberMetrics.lineCount(in: text)
        )
        textView.textContainer?.lineFragmentPadding = 0
        textView.string = text
        context.coordinator.applyBaseTypingAttributes(to: textView)
        textView.onSave = { context.coordinator.save() }
        applyWrap(wordWrap, to: textView, in: scrollView)

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.attach(scrollView: scrollView, textView: textView)
        context.coordinator.lastFontSize = fontSize
        context.coordinator.lastWordWrap = wordWrap
        context.coordinator.lastLineNumbers = lineNumbers
        context.coordinator.lastContentWidth = effectiveContentWidth(in: scrollView)
        context.coordinator.lastLayoutWidth = layoutWidth
        context.coordinator.lastSyntaxLanguage = syntaxLanguage
        context.coordinator.lastDarkMode = isDarkMode
        context.coordinator.refreshLineIndex()
        configureLineNumbers(lineNumbers, in: scrollView, textView: textView, coordinator: context.coordinator)
        context.coordinator.scheduleHighlight()
        context.coordinator.publishVisibleLineRange()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        let previousOrigin = scrollView.contentView.bounds.origin
        var originToRestore = previousOrigin
        var shouldPublishVisibleRange = false
        if wordWrap {
            originToRestore.x = 0
        }
        if textView.string != text {
            textView.string = text
            context.coordinator.applyBaseTypingAttributes(to: textView)
            context.coordinator.refreshLineIndex()
            context.coordinator.scheduleHighlight()
            shouldPublishVisibleRange = true
        }
        if context.coordinator.lastFontSize != fontSize {
            textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            context.coordinator.applyBaseTypingAttributes(to: textView)
            context.coordinator.lastFontSize = fontSize
            context.coordinator.scheduleHighlight()
            shouldPublishVisibleRange = true
        }
        if context.coordinator.lastSyntaxLanguage != syntaxLanguage ||
            context.coordinator.lastDarkMode != isDarkMode {
            context.coordinator.lastSyntaxLanguage = syntaxLanguage
            context.coordinator.lastDarkMode = isDarkMode
            configureRendering(in: scrollView, textView: textView)
            context.coordinator.applyBaseTypingAttributes(to: textView)
            context.coordinator.scheduleHighlight()
        }
        textView.onSave = { context.coordinator.save() }
        let contentWidth = effectiveContentWidth(in: scrollView)
        if context.coordinator.lastWordWrap != wordWrap ||
            abs(context.coordinator.lastContentWidth - contentWidth) > 0.5 ||
            abs(context.coordinator.lastLayoutWidth - layoutWidth) > 0.5 {
            scrollView.hasHorizontalScroller = !wordWrap
            applyWrap(wordWrap, to: textView, in: scrollView)
            context.coordinator.lastWordWrap = wordWrap
            context.coordinator.lastContentWidth = contentWidth
            context.coordinator.lastLayoutWidth = layoutWidth
            if wordWrap {
                originToRestore.x = 0
            }
            shouldPublishVisibleRange = true
        }
        if context.coordinator.lastLineNumbers != lineNumbers {
            configureLineNumbers(lineNumbers, in: scrollView, textView: textView, coordinator: context.coordinator)
            context.coordinator.lastLineNumbers = lineNumbers
            applyWrap(wordWrap, to: textView, in: scrollView)
            context.coordinator.lastContentWidth = effectiveContentWidth(in: scrollView)
            originToRestore.x = 0
            shouldPublishVisibleRange = true
        }
        if CodeEditorScrollStabilityMetrics.preservesScrollOriginOnUpdate {
            context.coordinator.restoreVisibleOrigin(originToRestore)
        }
        if let line = minimapSeekLine {
            context.coordinator.scrollToLine(line)
            DispatchQueue.main.async {
                minimapSeekLine = nil
            }
        }
        if shouldPublishVisibleRange {
            context.coordinator.publishVisibleLineRange()
        }
    }

    private func applyWrap(_ enabled: Bool, to textView: NSTextView, in scrollView: NSScrollView) {
        let contentWidth = effectiveContentWidth(in: scrollView)
        if enabled {
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.containerSize = NSSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude)
            textView.minSize = NSSize(width: contentWidth, height: scrollView.contentSize.height)
            textView.maxSize = NSSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude)
            textView.setFrameSize(NSSize(width: contentWidth, height: max(textView.frame.height, scrollView.contentSize.height)))
        } else {
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = [.width]
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        }
        textView.needsLayout = true
    }

    private func effectiveContentWidth(in scrollView: NSScrollView) -> CGFloat {
        let contentWidth = scrollView.contentSize.width
        if contentWidth > 1 {
            return max(1, min(contentWidth, layoutWidth > 1 ? layoutWidth : contentWidth))
        }
        return max(1, layoutWidth)
    }

    private func configureRendering(in scrollView: NSScrollView, textView: FileTextView) {
        let background = CodeEditorRenderingPalette.backgroundColor(isDarkMode: isDarkMode)
        scrollView.drawsBackground = true
        scrollView.backgroundColor = background
        scrollView.contentView.drawsBackground = true
        scrollView.contentView.backgroundColor = background
        textView.drawsBackground = true
        textView.backgroundColor = background
        textView.enclosingScrollView?.backgroundColor = background
    }

    private func configureLineNumbers(
        _ visible: Bool,
        in scrollView: NSScrollView,
        textView: FileTextView,
        coordinator: Coordinator
    ) {
        if visible {
            let ruler = coordinator.lineNumberRuler ?? CodeLineNumberRulerView(scrollView: scrollView, textView: textView)
            coordinator.lineNumberRuler = ruler
            scrollView.verticalRulerView = ruler
            scrollView.hasVerticalRuler = true
            scrollView.rulersVisible = true
            ruler.textView = textView
            ruler.refresh(lineStarts: coordinator.lineStarts)
        } else {
            scrollView.verticalRulerView = nil
            scrollView.hasVerticalRuler = false
            scrollView.rulersVisible = false
            coordinator.lineNumberRuler = nil
        }
        coordinator.applyEditorInsets(lineNumbersVisible: visible)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: FileContentTextEditor
        weak var textView: FileTextView?
        weak var scrollView: NSScrollView?
        weak var observedContentView: NSClipView?
        var lineStarts: [Int] = [0]
        var lastVisibleLineRange: Range<Int>?
        var lineNumberRuler: CodeLineNumberRulerView?
        var lastVisibleLineRangePublishedAt: Date = .distantPast
        var pendingVisibleLineRange: Range<Int>?
        var pendingPublishScheduled = false
        var pendingVisibleRangeCalculationScheduled = false
        var lastFontSize: CGFloat = 0
        var lastWordWrap = false
        var lastLineNumbers = false
        var lastContentWidth: CGFloat = 0
        var lastLayoutWidth: CGFloat = 0
        var lastSyntaxLanguage: String?
        var lastDarkMode = false
        private var highlightGeneration = 0
        private var highlightWorkItem: DispatchWorkItem?
        private var isApplyingHighlight = false
        private var isAdjustingScrollOrigin = false

        init(_ parent: FileContentTextEditor) {
            self.parent = parent
        }

        deinit {
            if let observedContentView {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSView.boundsDidChangeNotification,
                    object: observedContentView
                )
            }
        }

        @MainActor
        func attach(scrollView: NSScrollView, textView: FileTextView) {
            self.scrollView = scrollView
            self.textView = textView
            if observedContentView !== scrollView.contentView {
                if let observedContentView {
                    NotificationCenter.default.removeObserver(
                        self,
                        name: NSView.boundsDidChangeNotification,
                        object: observedContentView
                    )
                }
                observedContentView = scrollView.contentView
                scrollView.contentView.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(boundsDidChange(_:)),
                    name: NSView.boundsDidChangeNotification,
                    object: scrollView.contentView
                )
            }
        }

        @MainActor
        func refreshLineIndex() {
            let currentText = textView?.string ?? parent.text
            lineStarts = CodeLineNumberMetrics.lineStarts(in: currentText)
            lineNumberRuler?.refresh(lineStarts: lineStarts)
            applyEditorInsets(lineNumbersVisible: parent.lineNumbers)
        }

        @MainActor
        func applyEditorInsets(lineNumbersVisible: Bool) {
            guard let textView else { return }
            let inset = CodeLineNumberMetrics.textInset(
                lineNumbersVisible: lineNumbersVisible,
                lineCount: lineStarts.count
            )
            guard textView.textContainerInset != inset else { return }
            textView.textContainerInset = inset
            textView.needsLayout = true
            lineNumberRuler?.needsDisplay = true
        }

        @MainActor
        func textDidChange(_ notification: Notification) {
            guard !isApplyingHighlight else { return }
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            refreshLineIndex()
            applyBaseTypingAttributes(to: textView)
            scheduleHighlight()
            publishVisibleLineRange()
        }

        @MainActor
        func save() {
            parent.onSave()
        }

        @objc @MainActor private func boundsDidChange(_ notification: Notification) {
            lineNumberRuler?.needsDisplay = true
            invalidateVisibleEditorRegion()
            clampVisibleOriginIfNeeded()
            publishVisibleLineRangeAfterScroll()
        }

        @MainActor
        func textViewDidChangeSelection(_ notification: Notification) {
            lineNumberRuler?.needsDisplay = true
        }

        @MainActor
        private func publishVisibleLineRangeAfterScroll() {
            let now = Date()
            let elapsed = now.timeIntervalSince(lastVisibleLineRangePublishedAt)
            if elapsed >= CodeEditorScrollStabilityMetrics.visibleRangePublishInterval {
                publishVisibleLineRange()
                return
            }
            scheduleVisibleRangeCalculation(after: CodeEditorScrollStabilityMetrics.visibleRangePublishInterval - elapsed)
        }

        @MainActor
        private func invalidateVisibleEditorRegion() {
            guard let textView, let scrollView else { return }
            let visibleRect = scrollView.contentView.documentVisibleRect
            textView.setNeedsDisplay(visibleRect)
            scrollView.contentView.setNeedsDisplay(scrollView.contentView.bounds)
        }

        @MainActor
        private func scheduleVisibleRangeCalculation(after delay: TimeInterval) {
            guard !pendingVisibleRangeCalculationScheduled else { return }
            pendingVisibleRangeCalculationScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.01, delay)) { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.pendingVisibleRangeCalculationScheduled = false
                    self.publishVisibleLineRange()
                }
            }
        }

        @MainActor
        func publishVisibleLineRange() {
            guard let textView, let scrollView else {
                publish(1..<2)
                return
            }
            guard let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else {
                publish(1..<2)
                return
            }

            layoutManager.ensureLayout(for: textContainer)
            if layoutManager.numberOfGlyphs == 0 {
                publish(1..<2)
                return
            }

            let visibleRect = scrollView.contentView.bounds
            let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
            if glyphRange.location == NSNotFound || glyphRange.length == 0 {
                publish(1..<2)
                return
            }

            let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            let startLine = CodeLineNumberMetrics.lineNumber(forCharacterIndex: charRange.location, lineStarts: lineStarts)
            let endCharacterIndex = max(charRange.location, NSMaxRange(charRange) - 1)
            let endLine = CodeLineNumberMetrics.lineNumber(forCharacterIndex: endCharacterIndex, lineStarts: lineStarts)
            publish(startLine..<max(startLine + 1, endLine + 1))
        }

        @MainActor
        private func publish(_ range: Range<Int>) {
            guard lastVisibleLineRange != range else { return }
            let now = Date()
            let elapsed = now.timeIntervalSince(lastVisibleLineRangePublishedAt)
            guard elapsed >= CodeEditorScrollStabilityMetrics.visibleRangePublishInterval else {
                pendingVisibleLineRange = range
                schedulePendingPublish(after: CodeEditorScrollStabilityMetrics.visibleRangePublishInterval - elapsed)
                return
            }
            publishNow(range, now: now)
        }

        @MainActor
        private func publishNow(_ range: Range<Int>, now: Date = Date()) {
            guard lastVisibleLineRange != range else { return }
            lastVisibleLineRange = range
            lastVisibleLineRangePublishedAt = now
            parent.onVisibleLineRangeChange(range)
        }

        @MainActor
        private func schedulePendingPublish(after delay: TimeInterval) {
            guard !pendingPublishScheduled else { return }
            pendingPublishScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.01, delay)) { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.pendingPublishScheduled = false
                    guard let range = self.pendingVisibleLineRange else { return }
                    self.pendingVisibleLineRange = nil
                    self.publishNow(range)
                }
            }
        }

        @MainActor
        func restoreVisibleOrigin(_ origin: NSPoint) {
            guard let scrollView else { return }
            let clamped = clampedOrigin(origin, in: scrollView)
            guard abs(scrollView.contentView.bounds.origin.x - clamped.x) > 0.5 ||
                abs(scrollView.contentView.bounds.origin.y - clamped.y) > 0.5 else { return }
            isAdjustingScrollOrigin = true
            scrollView.contentView.scroll(to: clamped)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            isAdjustingScrollOrigin = false
        }

        @MainActor
        private func clampVisibleOriginIfNeeded() {
            guard let scrollView, !isAdjustingScrollOrigin else { return }
            restoreVisibleOrigin(scrollView.contentView.bounds.origin)
        }

        @MainActor
        private func clampedOrigin(_ origin: NSPoint, in scrollView: NSScrollView) -> NSPoint {
            let documentSize = scrollView.documentView?.bounds.size ?? .zero
            let viewportSize = scrollView.contentView.bounds.size
            let maxX = max(0, documentSize.width - viewportSize.width)
            let maxY = max(0, documentSize.height - viewportSize.height)
            return NSPoint(
                x: CodeEditorScrollStabilityMetrics.horizontalOrigin(origin.x, wordWrap: parent.wordWrap, maxX: maxX),
                y: min(max(0, origin.y), maxY)
            )
        }

        @MainActor
        func scrollToLine(_ requestedLine: Int) {
            guard let textView, let scrollView, let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return }
            let line = min(max(1, requestedLine), max(1, lineStarts.count))
            let charIndex = lineStarts[max(0, line - 1)]
            let glyphIndex: Int
            if charIndex < (textView.string as NSString).length {
                glyphIndex = layoutManager.glyphIndexForCharacter(at: charIndex)
            } else {
                glyphIndex = max(0, layoutManager.numberOfGlyphs - 1)
            }
            layoutManager.ensureLayout(for: textContainer)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            let targetY = max(0, lineRect.minY + textView.textContainerOrigin.y - 8)
            let documentHeight = scrollView.documentView?.bounds.height ?? 0
            let maxY = max(0, documentHeight - scrollView.contentView.bounds.height)
            let targetX = parent.wordWrap ? 0 : scrollView.contentView.bounds.origin.x
            let target = NSPoint(x: targetX, y: min(maxY, targetY))
            isAdjustingScrollOrigin = true
            scrollView.contentView.scroll(to: target)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            isAdjustingScrollOrigin = false
            publishVisibleLineRange()
        }

        @MainActor
        func applyBaseTypingAttributes(to textView: NSTextView) {
            textView.typingAttributes = baseAttributes()
        }

        @MainActor
        func scheduleHighlight() {
            highlightGeneration += 1
            let generation = highlightGeneration
            highlightWorkItem?.cancel()
            guard let textView else { return }
            let language = parent.syntaxLanguage
            guard CodeSyntaxHighlightingService.shouldHighlight(textView.string, languageAlias: language),
                  let language else {
                applyPlainAttributes()
                return
            }
            let source = textView.string
            let darkMode = parent.isDarkMode
            let item = DispatchWorkItem { [weak self] in
                Task {
                    do {
                        let highlighted = try await CodeSyntaxHighlightingService.highlightedText(
                            source,
                            languageAlias: language,
                            isDarkMode: darkMode
                        )
                        await MainActor.run {
                            self?.applyHighlight(highlighted, source: source, generation: generation)
                        }
                    } catch {
                        await MainActor.run {
                            guard self?.highlightGeneration == generation else { return }
                            self?.applyPlainAttributes()
                        }
                    }
                }
            }
            highlightWorkItem = item
            DispatchQueue.main.asyncAfter(
                deadline: .now() + CodeSyntaxHighlightingService.highlightDebounceInterval,
                execute: item
            )
        }

        @MainActor
        private func applyPlainAttributes() {
            guard let textView, let storage = textView.textStorage else { return }
            let range = NSRange(location: 0, length: (textView.string as NSString).length)
            guard range.length > 0 else { return }
            let selectedRanges = textView.selectedRanges
            let origin = scrollView?.contentView.bounds.origin
            isApplyingHighlight = true
            storage.beginEditing()
            storage.setAttributes(baseAttributes(), range: range)
            storage.endEditing()
            textView.selectedRanges = selectedRanges
            if let origin {
                restoreVisibleOrigin(origin)
            }
            applyBaseTypingAttributes(to: textView)
            isApplyingHighlight = false
        }

        @MainActor
        private func applyHighlight(_ highlighted: AttributedString, source: String, generation: Int) {
            guard highlightGeneration == generation else { return }
            guard let textView, let storage = textView.textStorage, textView.string == source else { return }
            let highlightedString = NSAttributedString(highlighted)
            let sourceLength = (source as NSString).length
            guard sourceLength > 0 else { return }
            let selectedRanges = textView.selectedRanges
            let origin = scrollView?.contentView.bounds.origin
            let base = baseAttributes()
            let fullRange = NSRange(location: 0, length: sourceLength)
            isApplyingHighlight = true
            storage.beginEditing()
            storage.setAttributes(base, range: fullRange)
            let highlightLength = min(sourceLength, highlightedString.length)
            if highlightLength > 0 {
                highlightedString.enumerateAttributes(
                    in: NSRange(location: 0, length: highlightLength),
                    options: []
                ) { attributes, range, _ in
                    var applied = base
                    if let foreground = attributes[.foregroundColor] {
                        applied[.foregroundColor] = foreground
                    }
                    if let background = attributes[.backgroundColor] {
                        applied[.backgroundColor] = background
                    }
                    storage.setAttributes(applied, range: range)
                }
            }
            storage.endEditing()
            textView.selectedRanges = selectedRanges
            if let origin {
                restoreVisibleOrigin(origin)
            }
            applyBaseTypingAttributes(to: textView)
            isApplyingHighlight = false
        }

        @MainActor
        private func baseAttributes() -> [NSAttributedString.Key: Any] {
            [
                .font: NSFont.monospacedSystemFont(ofSize: parent.fontSize, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ]
        }
    }
}

private final class CodeLineNumberRulerView: NSRulerView {
    weak var textView: NSTextView?
    private var lineStarts: [Int] = [0]

    override var isOpaque: Bool {
        true
    }

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = CodeLineNumberMetrics.rulerWidth(lineCount: 1)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func refresh(lineStarts: [Int]) {
        self.lineStarts = lineStarts.isEmpty ? [0] : lineStarts
        ruleThickness = CodeLineNumberMetrics.rulerWidth(lineCount: self.lineStarts.count)
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let scrollView = scrollView else { return }
        guard let layoutManager = textView.layoutManager, let textContainer = textView.textContainer else { return }

        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let backgroundColor = isDark
            ? NSColor(srgbRed: 10 / 255, green: 10 / 255, blue: 10 / 255, alpha: 1)
            : NSColor.white
        let separatorColor = isDark
            ? NSColor(srgbRed: 31 / 255, green: 31 / 255, blue: 31 / 255, alpha: 1)
            : NSColor(srgbRed: 229 / 255, green: 231 / 255, blue: 235 / 255, alpha: 1)
        let numberColor = isDark
            ? NSColor(srgbRed: 110 / 255, green: 118 / 255, blue: 129 / 255, alpha: 1)
            : NSColor(srgbRed: 140 / 255, green: 140 / 255, blue: 140 / 255, alpha: 1)
        let activeNumberColor = isDark
            ? NSColor(srgbRed: 201 / 255, green: 209 / 255, blue: 217 / 255, alpha: 1)
            : NSColor(srgbRed: 36 / 255, green: 41 / 255, blue: 47 / 255, alpha: 1)

        backgroundColor.setFill()
        NSBezierPath(rect: bounds).fill()
        separatorColor.setFill()
        NSBezierPath(rect: NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height)).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: numberColor,
        ]
        let activeAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: activeNumberColor,
        ]
        let visibleRect = scrollView.contentView.bounds
        let activeLine = CodeLineNumberMetrics.lineNumber(
            forCharacterIndex: textView.selectedRange().location,
            lineStarts: lineStarts
        )
        layoutManager.ensureLayout(for: textContainer)

        if layoutManager.numberOfGlyphs == 0 {
            draw(lineNumber: 1, y: textView.textContainerInset.height - visibleRect.minY, attributes: activeAttributes)
            return
        }

        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        if glyphRange.location == NSNotFound { return }

        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let startLine = CodeLineNumberMetrics.lineNumber(forCharacterIndex: charRange.location, lineStarts: lineStarts)
        let endCharacterIndex = max(charRange.location, NSMaxRange(charRange) - 1)
        let endLine = min(
            lineStarts.count,
            CodeLineNumberMetrics.lineNumber(forCharacterIndex: endCharacterIndex, lineStarts: lineStarts) + 1
        )
        guard startLine <= endLine else { return }

        for line in startLine...endLine {
            let lineStart = lineStarts[max(0, line - 1)]
            let glyphIndex: Int
            if lineStart < (textView.string as NSString).length {
                glyphIndex = layoutManager.glyphIndexForCharacter(at: lineStart)
            } else {
                glyphIndex = max(0, layoutManager.numberOfGlyphs - 1)
            }
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            let y = lineRect.minY + textView.textContainerOrigin.y - visibleRect.minY
            draw(lineNumber: line, y: y, attributes: line == activeLine ? activeAttributes : attributes)
        }
    }

    private func draw(lineNumber: Int, y: CGFloat, attributes: [NSAttributedString.Key: Any]) {
        let label = "\(lineNumber)" as NSString
        let size = label.size(withAttributes: attributes)
        let x = max(4, bounds.width - size.width - 12)
        let drawPoint = NSPoint(x: x, y: y + 1)
        label.draw(at: drawPoint, withAttributes: attributes)
    }
}

private enum CodeEditorRenderingPalette {
    static func backgroundColor(isDarkMode: Bool) -> NSColor {
        if isDarkMode {
            return NSColor(srgbRed: 10 / 255, green: 10 / 255, blue: 10 / 255, alpha: 1)
        }
        return .white
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
    var detail: String
    var emptyTitle: String
    var skills: [SkillRecord]
    var selectedSkillKey: String?
    var keyForSkill: (SkillRecord) -> String
    var onSelect: (SkillRecord) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(title.uppercased()) · \(skills.count)")
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.36)
                    .foregroundStyle(DesignTokens.neutral400)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(DesignTokens.tertiaryText)
                    .lineLimit(2)
            }
            .padding(.horizontal, 14)
            if skills.isEmpty {
                Text(emptyTitle)
                    .font(.system(size: 12))
                    .foregroundStyle(DesignTokens.tertiaryText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            } else {
                ForEach(skills) { skill in
                    let isSelected = selectedSkillKey == keyForSkill(skill)
                    Button { onSelect(skill) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(skill.name)
                                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                                if let version = skill.version {
                                    Text("v\(version)")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(DesignTokens.tertiaryText)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(DesignTokens.cardSurfaceSubtle, in: Capsule())
                                }
                            }
                            if !skill.description.isEmpty {
                                Text(skill.description)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                    .foregroundStyle(DesignTokens.tertiaryText)
                            }
                            Text(skill.slug)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(DesignTokens.neutral400)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(isSelected ? DesignTokens.selectedRowFill() : Color.clear, in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius))
                        .contentShape(RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 8)
    }
}

private struct ScopeBadge: View {
    var title: String
    var tint: Color

    var body: some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(tint.opacity(0.10), in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.18), lineWidth: 0.8))
    }
}

private struct MarkdownPreview: View {
    var text: String

    var body: some View {
        NativeMarkdownView(text: text, fontSize: 13, lineSpacing: 5)
    }
}

enum NativeAlwaysOnRowKind: String, Hashable {
    case plan
    case cron

    var systemImage: String {
        switch self {
        case .plan:
            return "sparkles"
        case .cron:
            return "timer"
        }
    }
}

struct NativeAlwaysOnRow: Identifiable, Hashable {
    var kind: NativeAlwaysOnRowKind
    var id: String
    var title: String
    var typeLabel: String
    var statusLabel: String
    var createdAt: Date?
    var triggeredAt: Date?
    var completedAt: Date?
    var sortAt: Date
    var plan: AlwaysOnPlan?
    var cronJob: AlwaysOnCronJob?

    var canRun: Bool {
        switch kind {
        case .plan:
            return plan?.status == .ready && plan?.executionSessionId == nil
        case .cron:
            return true
        }
    }

    var canArchiveOrDelete: Bool {
        switch kind {
        case .plan:
            return plan?.executionStatus != .running
                && plan?.executionStatus != .queued
                && plan?.status != .running
                && plan?.status != .queued
        case .cron:
            return true
        }
    }
}

struct NativeAlwaysOnItemsRow: Identifiable, Equatable {
    var id: String
    var title: String
    var type: String
    var status: String
    var created: String
    var triggered: String
    var completed: String
    var canRun: Bool
    var canArchiveOrDelete: Bool
    var canOpenCronSession: Bool
}

struct NativeAlwaysOnContextRefGroup: Identifiable, Equatable {
    var id: String { key }
    var key: String
    var label: String
    var values: [String]
}

enum NativeAlwaysOnPlanDetailPresentation {
    static func detailTitle(_ plan: AlwaysOnPlan) -> String {
        NativeAlwaysOnRows.planTitle(plan)
    }

    static func sectionTitle(_ section: Section, language: ResolvedAppLanguage = .english) -> String {
        switch (section, language) {
        case (.summary, .chineseSimplified): return "摘要"
        case (.planMarkdown, .chineseSimplified): return "Plan Markdown"
        case (.contextRefs, .chineseSimplified): return "上下文引用"
        case (.summary, _): return "Summary"
        case (.planMarkdown, _): return "Plan Markdown"
        case (.contextRefs, _): return "Context Refs"
        }
    }

    static func fieldLabel(_ field: Field, language: ResolvedAppLanguage = .english) -> String {
        switch (field, language) {
        case (.fileLocation, .chineseSimplified): return "文件位置"
        case (.createdAt, .chineseSimplified): return "创建时间"
        case (.updatedAt, .chineseSimplified): return "更新时间"
        case (.fileLocation, _): return "File location"
        case (.createdAt, _): return "Created"
        case (.updatedAt, _): return "Updated"
        }
    }

    static func fileLocation(projectRoot: String, planFilePath: String) -> String {
        let filePath = planFilePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filePath.isEmpty else { return "—" }
        if filePath.hasPrefix("/") || filePath.range(of: #"^[a-zA-Z]:[\\/]"#, options: .regularExpression) != nil {
            return filePath
        }
        let root = projectRoot.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[\\/]+$"#, with: "", options: .regularExpression)
        let relative = filePath.replacingOccurrences(of: #"^[\\/]+"#, with: "", options: .regularExpression)
        return root.isEmpty ? relative : "\(root)/\(relative)"
    }

    static func metaItems(_ plan: AlwaysOnPlan, projectRoot: String, language: ResolvedAppLanguage = .english) -> [(String, String)] {
        [
            (fieldLabel(.fileLocation, language: language), fileLocation(projectRoot: projectRoot, planFilePath: plan.planFilePath)),
            (fieldLabel(.createdAt, language: language), NativeAlwaysOnDateLabels.time(plan.createdAt)),
            (fieldLabel(.updatedAt, language: language), NativeAlwaysOnDateLabels.time(plan.updatedAt)),
        ]
    }

    static func contextRefGroups(_ plan: AlwaysOnPlan, language: ResolvedAppLanguage = .english) -> [NativeAlwaysOnContextRefGroup] {
        contextRefOrder.compactMap { key, label in
            let values = plan.contextRefs?[key] ?? []
            guard !values.isEmpty else { return nil }
            return NativeAlwaysOnContextRefGroup(key: key, label: localizedContextLabel(label, language: language), values: values)
        }
    }

    enum Section {
        case summary
        case planMarkdown
        case contextRefs
    }

    enum Field {
        case fileLocation
        case createdAt
        case updatedAt
    }

    private static let contextRefOrder: [(key: String, label: ContextLabel)] = [
        ("workingDirectory", .workingDirectory),
        ("memory", .memory),
        ("cronJobs", .cronJobs),
        ("recentChats", .recentChats),
    ]

    private enum ContextLabel {
        case workingDirectory
        case memory
        case cronJobs
        case recentChats
    }

    private static func localizedContextLabel(_ label: ContextLabel, language: ResolvedAppLanguage) -> String {
        switch (label, language) {
        case (.workingDirectory, .chineseSimplified): return "工作目录"
        case (.memory, .chineseSimplified): return "记忆"
        case (.cronJobs, .chineseSimplified): return "Cron Jobs"
        case (.recentChats, .chineseSimplified): return "近期对话"
        case (.workingDirectory, _): return "Working Directory"
        case (.memory, _): return "Memory"
        case (.cronJobs, _): return "Cron Jobs"
        case (.recentChats, _): return "Recent Chats"
        }
    }
}

enum NativeAlwaysOnCronDetailPresentation {
    static func sectionTitle(_ section: Section, language: ResolvedAppLanguage = .english) -> String {
        switch (section, language) {
        case (.prompt, .chineseSimplified): return "提示词"
        case (.schedule, .chineseSimplified): return "调度配置"
        case (.createdFrom, .chineseSimplified): return "创建来源"
        case (.prompt, _): return "Prompt"
        case (.schedule, _): return "Schedule"
        case (.createdFrom, _): return "Created From"
        }
    }

    static func fieldLabel(_ field: Field, language: ResolvedAppLanguage = .english) -> String {
        switch (field, language) {
        case (.cronExpression, .chineseSimplified): return "Cron 表达式"
        case (.currentStatus, .chineseSimplified): return "当前状态"
        case (.triggerType, .chineseSimplified): return "触发类型"
        case (.scope, .chineseSimplified): return "持久性范围"
        case (.createdAt, .chineseSimplified): return "创建时间"
        case (.lastFiredAt, .chineseSimplified): return "上次触发"
        case (.originSessionId, .chineseSimplified): return "来源会话"
        case (.sessionId, .chineseSimplified): return "Session ID"
        case (.transcriptKey, .chineseSimplified): return "Transcript key"
        case (.cronExpression, _): return "Cron expression"
        case (.currentStatus, _): return "Current status"
        case (.triggerType, _): return "Trigger type"
        case (.scope, _): return "Scope"
        case (.createdAt, _): return "Created"
        case (.lastFiredAt, _): return "Last fired"
        case (.originSessionId, _): return "Origin session"
        case (.sessionId, _): return "Session ID"
        case (.transcriptKey, _): return "Transcript key"
        }
    }

    static func promptText(_ job: AlwaysOnCronJob) -> String {
        job.prompt
    }

    static func scheduleItems(_ job: AlwaysOnCronJob, language: ResolvedAppLanguage = .english) -> [(String, String)] {
        [
            (fieldLabel(.cronExpression, language: language), job.cron),
            (fieldLabel(.currentStatus, language: language), job.status.rawValue),
            (fieldLabel(.triggerType, language: language), NativeAlwaysOnCronLabels.triggerLabel(job, language: language)),
            (fieldLabel(.scope, language: language), NativeAlwaysOnCronLabels.scopeLabel(job, language: language)),
            (fieldLabel(.createdAt, language: language), NativeAlwaysOnDateLabels.time(job.createdAt)),
            (fieldLabel(.lastFiredAt, language: language), NativeAlwaysOnDateLabels.time(job.lastFiredAt)),
        ]
    }

    static func originSessionValue(_ job: AlwaysOnCronJob) -> String {
        valueOrDash(job.originSessionId)
    }

    static func latestRunSessionValue(_ job: AlwaysOnCronJob) -> String {
        valueOrDash(job.latestRun?.sessionId)
    }

    static func transcriptKeyValue(_ job: AlwaysOnCronJob) -> String {
        valueOrDash(job.transcriptKey)
    }

    static func canOpenLatestRunSession(_ job: AlwaysOnCronJob) -> Bool {
        job.latestRun?.sessionId?.isEmpty == false
    }

    static func latestRunTarget(_ job: AlwaysOnCronJob) -> AlwaysOnSessionTarget? {
        guard let latestRun = job.latestRun,
              let sessionId = latestRun.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionId.isEmpty else {
            return nil
        }
        let title = latestRunTargetSummary(job)
        guard let parentSessionId = latestRun.parentSessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !parentSessionId.isEmpty,
              let relativeTranscriptPath = latestRun.relativeTranscriptPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !relativeTranscriptPath.isEmpty else {
            return .origin(sessionId: sessionId)
        }
        return .background(
            sessionId: sessionId,
            parentSessionId: parentSessionId,
            relativeTranscriptPath: relativeTranscriptPath,
            title: title,
            summary: title,
            lastActivity: latestRun.lastActivity,
            transcriptKey: latestRun.transcriptKey ?? job.transcriptKey,
            taskId: latestRun.taskId,
            taskStatus: job.status.rawValue,
            outputFile: latestRun.outputFile
        )
    }

    static func latestRunTargetSummary(_ job: AlwaysOnCronJob) -> String {
        let candidates = [job.latestRun?.summary, job.prompt, job.cron]
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "—"
    }

    enum Section {
        case prompt
        case schedule
        case createdFrom
    }

    enum Field {
        case cronExpression
        case currentStatus
        case triggerType
        case scope
        case createdAt
        case lastFiredAt
        case originSessionId
        case sessionId
        case transcriptKey
    }

    private static func valueOrDash(_ value: String?) -> String {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? "—" : text
    }
}

enum NativeAlwaysOnDateLabels {
    static func time(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM/dd HH:mm"
        return formatter.string(from: date)
    }
}

enum NativeAlwaysOnUpdatedLabel {
    static func updatedText(_ date: Date?, language: ResolvedAppLanguage = .english, now: Date = Date()) -> String {
        let relative = relativeText(date, language: language, now: now)
        if language == .chineseSimplified {
            return "更新于 \(relative)"
        }
        return "Updated \(relative)"
    }

    static func relativeText(_ date: Date?, language: ResolvedAppLanguage = .english, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let seconds = Int((now.timeIntervalSince(date) / 1).rounded())
        if seconds < 60 {
            return language == .chineseSimplified ? "刚刚" : "just now"
        }
        let minutes = Int((Double(seconds) / 60).rounded())
        if minutes < 60 {
            return language == .chineseSimplified ? "\(minutes) 分钟前" : "\(minutes)m ago"
        }
        let hours = Int((Double(minutes) / 60).rounded())
        if hours < 24 {
            return language == .chineseSimplified ? "\(hours) 小时前" : "\(hours)h ago"
        }
        let days = Int((Double(hours) / 24).rounded())
        return language == .chineseSimplified ? "\(days) 天前" : "\(days)d ago"
    }
}

enum NativeAlwaysOnItemsRows {
    static let columnWidths: [CGFloat] = [280, 140, 88, 112, 96, 96, 196]

    static func columns(language: ResolvedAppLanguage = .english) -> [String] {
        if language == .chineseSimplified {
            return ["标题", "类型", "状态", "创建", "触发", "完成", ""]
        }
        return ["Title", "Type", "Status", "Created", "Triggered", "Completed", ""]
    }

    static func row(_ row: NativeAlwaysOnRow) -> NativeAlwaysOnItemsRow {
        NativeAlwaysOnItemsRow(
            id: row.id,
            title: row.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "—" : row.title,
            type: row.typeLabel,
            status: row.statusLabel,
            created: NativeAlwaysOnDateLabels.time(row.createdAt),
            triggered: NativeAlwaysOnDateLabels.time(row.triggeredAt),
            completed: NativeAlwaysOnDateLabels.time(row.completedAt),
            canRun: row.canRun,
            canArchiveOrDelete: row.canArchiveOrDelete,
            canOpenCronSession: canOpenCronSession(row)
        )
    }

    static func canOpenCronSession(_ row: NativeAlwaysOnRow) -> Bool {
        guard row.kind == .cron,
              let latestRun = row.cronJob?.latestRun,
              latestRun.parentSessionId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              latestRun.relativeTranscriptPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else { return false }
        return true
    }
}

enum NativeAlwaysOnRows {
    static func rows(plans: [AlwaysOnPlan], cronJobs: [AlwaysOnCronJob]) -> [NativeAlwaysOnRow] {
        let planRows = plans.filter(isActivePlan).map(planRow)
        let cronRows = cronJobs.filter(isActiveCronJob).map(cronRow)
        return (planRows + cronRows).sorted {
            if $0.sortAt == $1.sortAt {
                return $0.id < $1.id
            }
            return $0.sortAt > $1.sortAt
        }
    }

    static func isActivePlan(_ plan: AlwaysOnPlan) -> Bool {
        plan.status != .completed && plan.status != .superseded && plan.executionStatus != .completed
    }

    static func isActiveCronJob(_ job: AlwaysOnCronJob) -> Bool {
        job.recurring || job.status != .completed
    }

    static func planRow(_ plan: AlwaysOnPlan) -> NativeAlwaysOnRow {
        let completedAt = plan.status == .completed || plan.executionStatus == .completed ? plan.updatedAt : nil
        return NativeAlwaysOnRow(
            kind: .plan,
            id: "plan:\(plan.id)",
            title: planTitle(plan),
            typeLabel: "plan",
            statusLabel: (plan.executionStatus ?? plan.status).rawValue,
            createdAt: plan.createdAt,
            triggeredAt: nil,
            completedAt: completedAt,
            sortAt: plan.updatedAt,
            plan: plan,
            cronJob: nil
        )
    }

    static func cronRow(_ job: AlwaysOnCronJob) -> NativeAlwaysOnRow {
        let latestActivity = job.latestRun?.lastActivity
        let triggeredAt = job.lastFiredAt ?? latestActivity
        let createdAt = job.createdAt
        return NativeAlwaysOnRow(
            kind: .cron,
            id: "cron:\(job.id)",
            title: NativeAlwaysOnCronLabels.rowTitle(job),
            typeLabel: NativeAlwaysOnCronLabels.typeLabel(job),
            statusLabel: job.status.rawValue,
            createdAt: createdAt,
            triggeredAt: triggeredAt,
            completedAt: job.status == .completed ? latestActivity : nil,
            sortAt: triggeredAt ?? createdAt ?? .distantPast,
            plan: nil,
            cronJob: job
        )
    }

    static func planTitle(_ plan: AlwaysOnPlan) -> String {
        let explicit = plan.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty {
            return explicit
        }
        let filename = plan.planFilePath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/")
            .last
            .map(String.init) ?? ""
        let stem = filename.replacingOccurrences(of: #"(?i)\.md$"#, with: "", options: .regularExpression)
        return stem.isEmpty ? plan.id : stem
    }
}

enum NativeAlwaysOnCronLabels {
    static let titleMaxLength = 56

    static func promptTitle(_ prompt: String?) -> String {
        let text = (prompt ?? "").replacingOccurrences(of: #"^\s+"#, with: "", options: .regularExpression)
        let firstLine = text
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = firstLine.replacingOccurrences(
            of: #"^#(?!#)\s+(.+)$"#,
            with: "$1",
            options: .regularExpression
        )
        guard title != firstLine else { return "" }
        return title.replacingOccurrences(
            of: #"\s+#+\s*$"#,
            with: "",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func rowTitle(_ job: AlwaysOnCronJob) -> String {
        let title = promptTitle(job.prompt)
        let candidate = title.isEmpty ? job.prompt : title
        let truncated = truncate(candidate, maxLength: titleMaxLength)
        return truncated.isEmpty ? job.cron : truncated
    }

    static func truncate(_ value: String?, maxLength: Int = 56) -> String {
        let text = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > maxLength else { return text }
        let end = text.index(text.startIndex, offsetBy: maxLength - 1)
        return "\(text[..<end])…"
    }

    static func typeLabel(_ job: AlwaysOnCronJob) -> String {
        var label = "\(job.durable ? "persistent" : "session-scope") / \(job.recurring ? "recurring" : "one-shot")"
        if job.manualOnly {
            label += " / manual"
        }
        return label
    }

    static func triggerLabel(_ job: AlwaysOnCronJob, language: ResolvedAppLanguage = .english) -> String {
        var labels = [job.recurring ? localized(.recurringTrigger, language: language) : localized(.oneShotTrigger, language: language)]
        if job.manualOnly {
            labels.append(localized(.manualOnly, language: language))
        }
        if job.permanent {
            labels.append(localized(.permanent, language: language))
        }
        return labels.joined(separator: " / ")
    }

    static func scopeLabel(_ job: AlwaysOnCronJob, language: ResolvedAppLanguage = .english) -> String {
        job.durable ? localized(.persistentScope, language: language) : localized(.sessionScope, language: language)
    }

    private enum LocalizedLabel {
        case recurringTrigger
        case oneShotTrigger
        case manualOnly
        case permanent
        case persistentScope
        case sessionScope
    }

    private static func localized(_ label: LocalizedLabel, language: ResolvedAppLanguage) -> String {
        switch (label, language) {
        case (.recurringTrigger, .chineseSimplified): return "重复触发"
        case (.oneShotTrigger, .chineseSimplified): return "单次触发"
        case (.manualOnly, .chineseSimplified): return "仅手动"
        case (.permanent, .chineseSimplified): return "永久"
        case (.persistentScope, .chineseSimplified): return "持久"
        case (.sessionScope, .chineseSimplified): return "会话范围"
        case (.recurringTrigger, _): return "Recurring"
        case (.oneShotTrigger, _): return "One-shot"
        case (.manualOnly, _): return "Manual only"
        case (.permanent, _): return "Permanent"
        case (.persistentScope, _): return "Persistent"
        case (.sessionScope, _): return "Session-scope"
        }
    }
}

enum NativeAlwaysOnRunMetadata {
    static let hiddenKeys: Set<String> = [
        "source",
        "sourceId",
        "parentSessionId",
        "logUpdatedAt",
        "logSize",
        "logTruncated",
    ]

    static func visibleEntries(_ metadata: [String: String]) -> [(key: String, value: String)] {
        metadata
            .filter { !hiddenKeys.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { (key: $0.key, value: $0.value.isEmpty ? "—" : $0.value) }
    }
}

private enum AlwaysOnSubTab {
    case dashboard
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
            .frame(height: 28)
            .background(
                Group {
                    if isActive {
                        GlassControlBackground(isActive: true, cornerRadius: 13, material: .popover, showsShadow: false)
                    } else {
                        Color.clear
                    }
                }
            )
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
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

struct NativeAlwaysOnRunHistoryRow: Identifiable, Equatable {
    var id: String
    var title: String
    var kind: String
    var status: String
    var started: String
    var source: String
    var session: String
}

enum NativeAlwaysOnRunHistoryRows {
    static let columnWidths: [CGFloat] = [260, 80, 90, 120, 190, 92]

    static func columns(language: ResolvedAppLanguage = .english) -> [String] {
        if language == .chineseSimplified {
            return ["标题", "类型", "状态", "开始时间", "来源", "会话"]
        }
        return ["Title", "Kind", "Status", "Started", "Source", "Session"]
    }

    static func isVisible(_ run: AlwaysOnRunHistory) -> Bool {
        run.status != .unknown
    }

    static func row(_ run: AlwaysOnRunHistory, language: ResolvedAppLanguage = .english) -> NativeAlwaysOnRunHistoryRow {
        NativeAlwaysOnRunHistoryRow(
            id: run.id,
            title: run.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "—" : run.title,
            kind: run.kind,
            status: run.status.rawValue,
            started: startedLabel(run.startedAt),
            source: run.sourceId,
            session: sessionLabel(run, language: language)
        )
    }

    static func sessionLabel(_ run: AlwaysOnRunHistory, language: ResolvedAppLanguage = .english) -> String {
        if run.sessionId?.isEmpty == false || run.relativeTranscriptPath?.isEmpty == false {
            return language == .chineseSimplified ? "可用" : "Available"
        }
        return "—"
    }

    static func startedLabel(_ date: Date) -> String {
        NativeAlwaysOnDateLabels.time(date)
    }
}

enum NativeAlwaysOnRunHistoryDetailPresentation {
    static func title(_ run: AlwaysOnRunHistory, language: ResolvedAppLanguage = .english) -> String {
        let title = run.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.isEmpty else { return title }
        return language == .chineseSimplified ? "运行详情" : "Run detail"
    }

    static func logSource(_ run: AlwaysOnRunHistory) -> String {
        let source = run.metadata["logSource"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let source, !source.isEmpty {
            return source
        }
        return AlwaysOnRunLogSource.history.rawValue
    }

    static func logUpdatedAt(_ run: AlwaysOnRunHistory) -> String {
        let updatedAt = run.metadata["logUpdatedAt"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let updatedAt, !updatedAt.isEmpty {
            return updatedAt
        }
        return "—"
    }

    static func isLogTruncated(_ run: AlwaysOnRunHistory) -> Bool {
        run.metadata["logTruncated"] == "true"
    }

    static func outputLog(_ run: AlwaysOnRunHistory, emptyText: String) -> String {
        run.outputLog.isEmpty ? emptyText : run.outputLog
    }

    static func metadataEntries(_ run: AlwaysOnRunHistory) -> [(key: String, value: String)] {
        NativeAlwaysOnRunMetadata.visibleEntries(run.metadata)
    }

    static func sessionTarget(_ run: AlwaysOnRunHistory) -> AlwaysOnSessionTarget? {
        guard let sessionId = run.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionId.isEmpty else {
            return nil
        }
        guard let parentSessionId = run.parentSessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !parentSessionId.isEmpty,
              let relativeTranscriptPath = run.relativeTranscriptPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !relativeTranscriptPath.isEmpty else {
            return AlwaysOnSessionTarget(
                kind: .origin,
                sessionId: sessionId,
                parentSessionId: nil,
                relativeTranscriptPath: nil,
                title: run.title,
                summary: run.title,
                lastActivity: run.finishedAt ?? run.startedAt,
                transcriptKey: run.transcriptKey,
                taskId: run.sourceId,
                taskStatus: run.status.rawValue,
                outputFile: run.metadata["outputFile"]
            )
        }
        return .background(
            sessionId: sessionId,
            parentSessionId: parentSessionId,
            relativeTranscriptPath: relativeTranscriptPath,
            title: run.title,
            summary: run.title,
            lastActivity: run.finishedAt ?? run.startedAt,
            transcriptKey: run.transcriptKey,
            taskId: run.sourceId,
            taskStatus: run.status.rawValue,
            outputFile: run.metadata["outputFile"]
        )
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
            .background(
                HorizontalResizeHandleSurface(
                    isHovering: $hovering,
                    isDragging: $dragging,
                    onDragStart: { _ in
                        startWidth = clamped(width)
                    },
                    onDragChanged: { deltaX in
                        let delta = reverse ? -deltaX : deltaX
                        width = clamped(startWidth + delta)
                    },
                    onDragEnded: {},
                    onDoubleClick: nil
                )
            )
            .transaction { transaction in
                if dragging {
                    transaction.animation = nil
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
            .background(DesignTokens.cardSurface, in: RoundedRectangle(cornerRadius: DesignTokens.radius))
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.radius).stroke(DesignTokens.separator.opacity(0.72)))
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
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DesignTokens.tertiaryText)
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DesignTokens.tertiaryText)
            }
            Text(value)
                .font(.system(size: compact ? 22 : 26, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(DesignTokens.text)
            if detail != nil || hint != nil {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(DesignTokens.tertiaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if let hint {
                        Text(hint)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(DesignTokens.success)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(compact ? 14 : 18)
        .frame(maxWidth: .infinity, minHeight: compact ? 104 : 120, maxHeight: compact ? 104 : nil, alignment: .topLeading)
        .background(DesignTokens.contentSurface, in: RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.radius).stroke(DesignTokens.separator.opacity(0.72)))
    }
}

struct WebToolbarButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var isProminent = false

    func makeBody(configuration: Configuration) -> some View {
        let foreground = isProminent
            ? (isEnabled ? DesignTokens.prominentButtonForeground : DesignTokens.prominentButtonDisabledForeground)
            : (isEnabled ? DesignTokens.secondaryText : DesignTokens.tertiaryText.opacity(0.72))

        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(minWidth: isProminent ? 56 : 32, minHeight: 32)
            .background(
                Group {
                    if isProminent {
                        RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                            .fill(isEnabled ? DesignTokens.prominentButtonFill : DesignTokens.prominentButtonDisabledFill)
                    } else {
                        GlassControlBackground(isActive: false, cornerRadius: DesignTokens.smallRadius, showsShadow: false)
                    }
                }
            )
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous))
            .opacity(configuration.isPressed ? 0.76 : 1)
    }
}

enum EditorHeaderToolbarMetrics {
    static let iconButtonSize: CGFloat = 28
    static let iconFontSize: CGFloat = 13.5
    static let usesProminentSaveButton = false
}

private struct EditorHeaderIconButtonStyle: ButtonStyle {
    var isActive = false
    var tint: Color = DesignTokens.secondaryText

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: EditorHeaderToolbarMetrics.iconFontSize, weight: .medium))
            .foregroundStyle(isActive ? tint : DesignTokens.secondaryText)
            .frame(width: EditorHeaderToolbarMetrics.iconButtonSize, height: EditorHeaderToolbarMetrics.iconButtonSize)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isActive ? tint.opacity(0.10) : DesignTokens.neutral100.opacity(0.62))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(isActive ? tint.opacity(0.22) : DesignTokens.separator.opacity(0.62), lineWidth: 1)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(configuration.isPressed ? 0.70 : 1)
    }
}

struct WebFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(.system(size: 13))
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(DesignTokens.background.opacity(0.92), in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                    .stroke(DesignTokens.separator.opacity(0.66))
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
    NativeAlwaysOnCronLabels.rowTitle(job)
}
