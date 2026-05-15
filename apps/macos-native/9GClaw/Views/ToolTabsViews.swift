import SwiftUI

struct FilesView: View {
    @EnvironmentObject private var state: AppState
    @State private var files: [WorkspaceFile] = []

    var body: some View {
        HSplitView {
            List(files, selection: $state.selectedFile) { file in
                Label(file.name, systemImage: file.isDirectory ? "folder" : "doc.text")
                    .tag(file)
            }
            .frame(minWidth: 260)

            VStack(alignment: .leading, spacing: 0) {
                if let file = state.selectedFile {
                    Text(file.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DesignTokens.secondaryText)
                        .padding(12)
                    Divider()
                    TextEditor(text: $state.selectedFileContent)
                        .font(.system(size: 13, design: .monospaced))
                    HStack {
                        Spacer()
                        Button("Save") {
                            try? state.workspaceService.writeFile(path: file.path, content: state.selectedFileContent)
                        }
                    }
                    .padding(12)
                } else {
                    ContentUnavailableView("No file selected", systemImage: "doc.text.magnifyingglass")
                }
            }
        }
        .task(id: state.selectedProject?.id) {
            loadFiles()
        }
        .onChange(of: state.selectedFile) { _, file in
            guard let file, !file.isDirectory else { return }
            state.selectedFileContent = (try? state.workspaceService.readFile(path: file.path)) ?? ""
        }
    }

    private func loadFiles() {
        guard let project = state.selectedProject else {
            files = []
            return
        }
        files = (try? state.workspaceService.listFiles(project: project)) ?? []
    }
}

struct GitView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Status") { state.refreshGitStatus() }
                Button("Diff") {
                    state.refreshGitDiff()
                }
                Spacer()
            }
            .padding(12)
            Divider()
            ScrollView {
                Text(state.gitOutput.isEmpty ? "Run git status to inspect the selected project." : state.gitOutput)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        .task {
            state.refreshGitStatus()
        }
    }
}

struct ShellView: View {
    @EnvironmentObject private var state: AppState
    @State private var command = "pwd"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Command", text: $command)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { state.runShell(command: command) }
                Button("Run") {
                    state.runShell(command: command)
                }
            }
            .padding(12)
            Divider()
            List(state.terminalRuns) { run in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("$ \(run.command)")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        Spacer()
                        if let exitCode = run.exitCode {
                            Text("exit \(exitCode)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(exitCode == 0 ? .green : .red)
                        }
                    }
                    Text(run.output)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
                .padding(.vertical, 6)
            }
        }
    }
}

struct TasksView: View {
    @EnvironmentObject private var state: AppState
    @State private var title = ""
    @State private var prompt = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Task title", text: $title)
                TextField("Prompt", text: $prompt)
                Button("Queue") {
                    _ = state.taskService.createPlan(title: title.isEmpty ? "Untitled task" : title, prompt: prompt)
                    title = ""
                    prompt = ""
                    state.objectWillChange.send()
                }
            }
            .padding(12)
            Divider()
            List(state.taskService.plans) { plan in
                HStack {
                    Label(plan.title, systemImage: "checklist")
                    Spacer()
                    Text(plan.status.rawValue)
                        .foregroundStyle(DesignTokens.secondaryText)
                }
            }
        }
    }
}

struct MemoryView: View {
    @EnvironmentObject private var state: AppState
    @State private var query = ""
    @State private var name = ""
    @State private var summary = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search memory", text: $query)
                TextField("Name", text: $name)
                TextField("Summary", text: $summary)
                Button("Save") {
                    _ = state.memoryService.upsert(name: name, summary: summary, projectName: state.selectedProject?.name)
                    name = ""
                    summary = ""
                    state.objectWillChange.send()
                }
            }
            .padding(12)
            Divider()
            List(state.memoryService.search(query)) { record in
                VStack(alignment: .leading) {
                    Text(record.name).font(.system(size: 13, weight: .semibold))
                    Text(record.summary).foregroundStyle(DesignTokens.secondaryText)
                }
            }
        }
    }
}

struct SkillsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        List(state.skillsService.skills) { skill in
            HStack {
                VStack(alignment: .leading) {
                    Text(skill.name).font(.system(size: 13, weight: .semibold))
                    Text(skill.description).foregroundStyle(DesignTokens.secondaryText)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { skill.enabled },
                    set: { state.skillsService.setEnabled(skill, enabled: $0); state.objectWillChange.send() }
                ))
                .labelsHidden()
            }
        }
    }
}

struct DashboardView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
            GridRow {
                Metric("Projects", "\(state.projects.count)", "folder")
                Metric("Sessions", "\(state.projects.reduce(0) { $0 + $1.allSessions.count })", "message")
                Metric("Memory", "\(state.memoryService.records.count)", "externaldrive")
                Metric("Tasks", "\(state.taskService.plans.count)", "checklist")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct AlwaysOnView: View {
    var body: some View {
        ParityPlaceholderView(
            title: "Always-on",
            systemImage: "dot.radiowaves.left.and.right",
            detail: "Native Always-on will mirror discovery plans, cron jobs, run history, logs, approval state, and background session linking."
        )
    }
}

struct PreviewView: View {
    var body: some View {
        ParityPlaceholderView(title: "Preview", systemImage: "eye", detail: "Project preview routes become native inspectors instead of static HTTP previews.")
    }
}

struct PluginPlaceholderView: View {
    var name: String

    var body: some View {
        ParityPlaceholderView(title: name, systemImage: "shippingbox", detail: "Plugin UI will be backed by native manifest, asset, install, enable, update, and delete services.")
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
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: image)
                .foregroundStyle(DesignTokens.secondaryText)
            Text(value)
                .font(.system(size: 32, weight: .semibold))
        }
        .padding(14)
        .frame(width: 170, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous)
                .fill(DesignTokens.panel)
        )
    }
}

private struct ParityPlaceholderView: View {
    var title: String
    var systemImage: String
    var detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 24, weight: .semibold))
            Text(detail)
                .foregroundStyle(DesignTokens.secondaryText)
                .frame(maxWidth: 720, alignment: .leading)
            Divider()
            Text("This tab is wired into the native shell and has a dedicated Swift service boundary. The parity matrix in Docs/PARITY_MATRIX.md is the implementation checklist for completing behavior equivalence.")
                .foregroundStyle(DesignTokens.secondaryText)
                .frame(maxWidth: 720, alignment: .leading)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
