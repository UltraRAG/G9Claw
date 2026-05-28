import CryptoKit
import Foundation

final class TaskService {
    private(set) var plans: [TaskPlan] = []

    func createPlan(title: String, prompt: String) -> TaskPlan {
        let plan = TaskPlan(id: UUID(), title: title, prompt: prompt, status: .queued, createdAt: Date())
        plans.insert(plan, at: 0)
        return plan
    }

    func updateStatus(id: UUID, status: TaskStatus) {
        guard let index = plans.firstIndex(where: { $0.id == id }) else { return }
        plans[index].status = status
    }
}

final class MemoryService {
    private(set) var records: [MemoryRecord] = []
    private let memoryRoot: URL
    private var recordFileURLs: [String: URL] = [:]
    private var caseTraceRecords: [MemoryTraceRecord] = []
    private var indexTraceRecords: [MemoryTraceRecord] = []
    private var dreamTraceRecords: [MemoryTraceRecord] = []
    private var lastDreamSnapshot: MemoryDreamSnapshot?
    private var lastIndexedAt: Date?
    private var lastDreamAt: Date?
    private var settings = MemorySettingsSnapshot.defaults
    private var jobStates: [MemoryJobKind: MemoryJobState] = Dictionary(
        uniqueKeysWithValues: MemoryJobKind.allCases.map { ($0, .idle($0)) }
    )

    init(
        memoryRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".g9claw", isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
    ) {
        self.memoryRoot = memoryRoot
    }

    func upsert(name: String, summary: String, projectName: String?) -> MemoryRecord {
        if let index = records.firstIndex(where: { $0.name == name && $0.projectName == projectName }) {
            records[index].summary = summary
            records[index].content = summary
            records[index].updatedAt = Date()
            return records[index]
        }
        let record = MemoryRecord(
            id: UUID(),
            name: name,
            summary: summary,
            projectName: projectName,
            updatedAt: Date(),
            type: .project,
            relativePath: "\(name).md",
            deprecated: false,
            content: summary
        )
        records.insert(record, at: 0)
        return record
    }

    func loadWorkspaceRecords(projectRoot: String?, projectName: String?) {
        guard let projectRoot else { return }
        let projectURL = URL(fileURLWithPath: NSString(string: projectRoot).expandingTildeInPath).standardizedFileURL
        let legacyMemoryRoot = legacyWorkspaceMemoryRoot(for: projectURL.path)
        let nativeWorkspaceMemoryRoot = nativeWorkspaceMemoryRoot(for: projectURL.path)
        let globalMemoryRoot = globalMemoryRoot()
        let roots = uniqueMemoryRoots([
            (root: legacyMemoryRoot, relativeRoot: projectURL, projectName: projectName, exposedPrefix: ""),
            (root: nativeWorkspaceMemoryRoot, relativeRoot: nativeWorkspaceMemoryRoot, projectName: projectName, exposedPrefix: ""),
            (root: globalMemoryRoot, relativeRoot: globalMemoryRoot, projectName: nil, exposedPrefix: "global/")
        ])
        var loaded: [MemoryRecord] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root.root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: []
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
                if Self.isDerivedMemoryFile(url.lastPathComponent) {
                    continue
                }
                let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                let parsed = Self.memoryFile(from: content)
                let fallbackRelativePath = url.path.replacingOccurrences(of: projectURL.path + "/", with: "")
                let relativePath = exposedRelativePath(for: url, relativeRoot: root.relativeRoot, fallback: fallbackRelativePath, prefix: root.exposedPrefix)
                var record = MemoryRecord(
                    id: UUID(),
                    name: parsed?.name.nilIfBlank ?? url.deletingPathExtension().lastPathComponent,
                    summary: parsed?.description.nilIfBlank ?? Self.preview(content),
                    projectName: parsed?.scope == "global" ? nil : root.projectName,
                    updatedAt: parsed?.updatedAt ?? values?.contentModificationDate ?? Date(),
                    type: parsed?.type ?? Self.recordType(from: content, fallbackPath: url.path),
                    relativePath: relativePath,
                    deprecated: parsed?.deprecated ?? Self.deprecated(from: content),
                    content: content,
                    scope: parsed?.scope ?? (root.projectName == nil ? "global" : "project"),
                    projectId: parsed?.projectId,
                    sourceSessionKey: parsed?.sourceSessionKey,
                    capturedAt: parsed?.capturedAt
                )
                if record.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    record.summary = Self.preview(content)
                }
                loaded.append(record)
                recordFileURLs[recordStorageKey(record)] = url
            }
        }
        records.removeAll { $0.projectName == projectName || $0.relativePath.hasPrefix("global/") }
        records = merge(loaded, into: records)
    }

    static func g9clawWorkspaceHash(for projectRoot: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(projectRoot.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(10).description
    }

    private func uniqueMemoryRoots(_ roots: [(root: URL, relativeRoot: URL, projectName: String?, exposedPrefix: String)]) -> [(root: URL, relativeRoot: URL, projectName: String?, exposedPrefix: String)] {
        var seen: Set<String> = []
        return roots.filter { entry in
            seen.insert(entry.root.standardizedFileURL.path).inserted
        }
    }

    private func exposedRelativePath(for url: URL, relativeRoot: URL, fallback: String, prefix: String) -> String {
        let rootPath = relativeRoot.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        let relative = filePath.hasPrefix(rootPath + "/")
            ? String(filePath.dropFirst(rootPath.count + 1))
            : fallback
        if prefix.isEmpty || relative.hasPrefix(prefix) {
            return relative
        }
        return prefix + relative
    }

    @discardableResult
    func indexWorkspace(projectRoot: String?, projectName: String?) throws -> MemoryDashboardSnapshot {
        guard let projectRoot else {
            throw NSError(domain: "MemoryService", code: 400, userInfo: [NSLocalizedDescriptionKey: "No workspace selected."])
        }
        let root = URL(fileURLWithPath: NSString(string: projectRoot).expandingTildeInPath).standardizedFileURL
        let memoryRoot = nativeWorkspaceMemoryRoot(for: root.path)
        try FileManager.default.createDirectory(at: memoryRoot, withIntermediateDirectories: true)

        let indexedFiles = Self.indexableFiles(in: root)
        let fileLines = indexedFiles.prefix(160).map { url -> String in
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            let preview = ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty && !$0.hasPrefix("#") }
                .map { String($0) } ?? "No preview"
            return "- `\(relative)`: \(String(preview.prefix(180)))"
        }
        let content = """
        # Workspace Index

        Generated by native PilotDeck.

        - Workspace: \(root.path)
        - Indexed at: \(ISO8601DateFormatter().string(from: Date()))
        - Files scanned: \(indexedFiles.count)

        ## Files

        \(fileLines.isEmpty ? "No supported text files found." : fileLines.joined(separator: "\n"))
        """
        try content.write(to: memoryRoot.appendingPathComponent("native-workspace-index.md"), atomically: true, encoding: String.Encoding.utf8)
        loadWorkspaceRecords(projectRoot: root.path, projectName: projectName)
        lastIndexedAt = Date()
        let trace = makeTrace(
                kind: "index",
                title: "Index Sync",
                status: "completed",
                trigger: "manual",
                context: root.path,
                reply: "Indexed \(indexedFiles.count) files.",
                steps: [
                    ("index_start", "开始索引", "Workspace: \(root.path)"),
                    ("index_finished", "索引完成", "Files scanned: \(indexedFiles.count)")
                ]
            )
        indexTraceRecords.insert(trace, at: 0)
        return dashboard(projectName: projectName)
    }

    func search(_ query: String) -> [MemoryRecord] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let visible = records.sorted { $0.updatedAt > $1.updatedAt }
        guard !normalized.isEmpty else { return visible }
        return visible.filter {
            $0.name.lowercased().contains(normalized) ||
            $0.summary.lowercased().contains(normalized) ||
            $0.relativePath.lowercased().contains(normalized) ||
            $0.content.lowercased().contains(normalized) ||
            ($0.sourceSessionKey?.lowercased().contains(normalized) ?? false) ||
            ($0.projectId?.lowercased().contains(normalized) ?? false) ||
            ($0.projectName?.lowercased().contains(normalized) ?? false)
        }
    }

    func dashboard(
        query: String = "",
        projectName: String? = nil,
        projectRoot: String? = nil,
        isGeneral: Bool = false
    ) -> MemoryDashboardSnapshot {
        let filtered = search(query).filter { projectName == nil || $0.projectName == projectName || $0.projectName == nil }
        let active = filtered.filter { !$0.deprecated }
        let overview = MemoryOverview(
            totalEntries: active.count,
            projectEntries: active.filter { $0.type == .project }.count,
            feedbackEntries: active.filter { $0.type == .feedback }.count,
            userEntries: active.filter { $0.type == .user }.count,
            latestMemoryAt: active.map(\.updatedAt).max(),
            lastIndexedAt: lastIndexedAt,
            lastDreamAt: lastDreamAt,
            schedulerEnabled: settings.enabled
        )
        let workspace = workspaceSnapshot(
            records: filtered,
            active: active,
            projectName: projectName,
            projectRoot: projectRoot,
            isGeneral: isGeneral
        )
        return MemoryDashboardSnapshot(
            totalEntries: active.count,
            projectEntries: active.filter { $0.type == .project }.count,
            feedbackEntries: active.filter { $0.type == .feedback }.count,
            latestMemoryAt: active.map(\.updatedAt).max(),
            records: filtered,
            userSummary: active.prefix(5).map { "- \($0.name): \($0.summary)" }.joined(separator: "\n"),
            caseTraces: caseTraceRecords.map(\.title),
            indexTraces: indexTraceRecords.map(\.title),
            dreamTraces: dreamTraceRecords.map(\.title),
            overview: overview,
            settings: settings,
            workspace: workspace,
            caseTraceRecords: caseTraceRecords,
            indexTraceRecords: indexTraceRecords,
            dreamTraceRecords: dreamTraceRecords,
            lastDreamSnapshot: lastDreamSnapshot,
            scheduler: MemorySchedulerSnapshot(enabled: settings.enabled, status: settings.enabled ? "running" : "disabled"),
            jobStates: jobStates
        )
    }

    func overview(projectName: String? = nil) -> MemoryOverview {
        dashboard(projectName: projectName).overview
    }

    func settingsSnapshot() -> MemorySettingsSnapshot {
        settings
    }

    func workspace(
        query: String = "",
        projectName: String? = nil,
        projectRoot: String? = nil,
        isGeneral: Bool = false
    ) -> MemoryWorkspaceSnapshot {
        dashboard(query: query, projectName: projectName, projectRoot: projectRoot, isGeneral: isGeneral).workspace
    }

    func list(
        kind: MemoryRecordType? = nil,
        query: String = "",
        limit: Int = 100,
        offset: Int = 0,
        projectName: String? = nil,
        includeDeprecated: Bool = false
    ) -> [MemoryRecord] {
        let filtered = search(query)
            .filter { projectName == nil || $0.projectName == projectName || $0.projectName == nil }
            .filter { kind == nil || $0.type == kind }
            .filter { includeDeprecated || !$0.deprecated }
            .sorted { $0.updatedAt > $1.updatedAt }
        guard offset < filtered.count else { return [] }
        return Array(filtered.dropFirst(max(0, offset)).prefix(max(1, limit)))
    }

    func get(ids: [String], projectName: String? = nil) -> [MemoryRecord] {
        let wanted = Set(ids)
        return records.filter { record in
            (projectName == nil || record.projectName == projectName || record.projectName == nil) &&
                (wanted.contains(record.id.uuidString) || wanted.contains(record.relativePath) || wanted.contains(record.name))
        }
    }

    func userSummary(projectName: String? = nil) -> String {
        dashboard(projectName: projectName).userSummary
    }

    func recallForTurn(prompt: String, projectName: String?, projectRoot: String?) -> String {
        let normalizedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let scoped = records
            .filter { !$0.deprecated }
            .filter { projectName == nil || $0.projectName == projectName || $0.projectName == nil }
            .sorted { $0.updatedAt > $1.updatedAt }
        let terms = Self.recallTerms(from: normalizedPrompt)
        let selected: [MemoryRecord]
        if terms.isEmpty {
            selected = Array(scoped.prefix(5))
        } else {
            selected = scoped
                .map { record in (record, Self.recallScore(record, terms: terms, now: Date())) }
                .filter { $0.1 > 0 }
                .sorted {
                    if $0.1 == $1.1 {
                        return $0.0.updatedAt > $1.0.updatedAt
                    }
                    return $0.1 > $1.1
                }
                .prefix(8)
                .map(\.0)
        }
        let context = selected.map { "- \($0.name): \($0.summary)" }.joined(separator: "\n")
        let reply = context.isEmpty ? "No memory records matched this turn." : context
        let trace = makeTrace(
                kind: "recall",
                title: normalizedPrompt.isEmpty ? "Memory Recall" : "Recall: \(String(normalizedPrompt.prefix(80)))",
                status: "completed",
                trigger: "agent_turn",
                context: projectRoot ?? projectName ?? "general",
                reply: reply,
                steps: [
                    ("recall_start", "开始 Recall", "Prompt: \(String(normalizedPrompt.prefix(240)))"),
                    ("recall_selected", context.isEmpty ? "无匹配记忆" : "注入记忆", "Records: \(selected.count), scoped: \(scoped.count), terms: \(terms.joined(separator: ","))")
                ]
            )
        caseTraceRecords.insert(trace, at: 0)
        finishJob(.recall, phase: .completed, message: "Recall 完成", traceID: trace.id)
        return context
    }

    func caseTraces(limit: Int = 12) -> [MemoryTraceRecord] {
        Array(caseTraceRecords.prefix(max(1, limit)))
    }

    func indexTraces(limit: Int = 30) -> [MemoryTraceRecord] {
        Array(indexTraceRecords.prefix(max(1, limit)))
    }

    func dreamTraces(limit: Int = 30) -> [MemoryTraceRecord] {
        Array(dreamTraceRecords.prefix(max(1, limit)))
    }

    func clear(projectName: String?, projectRoot: String? = nil) {
        if let projectRoot {
            try? FileManager.default.removeItem(at: nativeWorkspaceMemoryRoot(for: projectRoot))
            try? FileManager.default.removeItem(at: legacyWorkspaceMemoryRoot(for: projectRoot))
        } else if projectName == nil {
            try? FileManager.default.removeItem(at: memoryRoot.appendingPathComponent("workspaces", isDirectory: true))
            try? FileManager.default.removeItem(at: globalMemoryRoot())
        }
        records.removeAll { projectName == nil || $0.projectName == projectName }
        if projectName == nil {
            recordFileURLs.removeAll()
        } else {
            recordFileURLs = recordFileURLs.filter { !$0.key.hasPrefix("\(projectName ?? ""):") }
        }
    }

    func updateSettings(_ next: MemorySettingsSnapshot) {
        settings = MemorySettingsSnapshot(
            enabled: next.enabled,
            model: next.model,
            reasoningMode: next.reasoningMode,
            autoIndexIntervalMinutes: next.autoIndexIntervalMinutes,
            autoDreamIntervalMinutes: next.autoDreamIntervalMinutes,
            captureStrategy: next.captureStrategy,
            includeAssistant: next.includeAssistant,
            maxMessageChars: next.maxMessageChars,
            heartbeatBatchSize: next.heartbeatBatchSize
        )
    }

    func editRecord(_ record: MemoryRecord, name: String, summary: String, projectRoot: String?) throws -> MemoryRecord {
        guard let index = records.firstIndex(where: { $0.id == record.id || $0.relativePath == record.relativePath }) else {
            throw NSError(domain: "MemoryService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Memory record not found."])
        }
        records[index].name = name
        records[index].summary = summary
        records[index].content = Self.rewriteHeader(content: records[index].content, name: name, summary: summary)
        records[index].updatedAt = Date()
        try writeRecordIfPossible(records[index], projectRoot: projectRoot)
        return records[index]
    }

    func setDeprecated(_ record: MemoryRecord, deprecated: Bool, projectRoot: String?) throws {
        guard let index = records.firstIndex(where: { $0.id == record.id || $0.relativePath == record.relativePath }) else { return }
        records[index].deprecated = deprecated
        records[index].updatedAt = Date()
        records[index].content = Self.setDeprecatedFlag(records[index].content, deprecated: deprecated)
        try writeRecordIfPossible(records[index], projectRoot: projectRoot)
    }

    func delete(_ record: MemoryRecord, projectRoot: String?) throws {
        if let url = recordURL(for: record, projectRoot: projectRoot), FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        records.removeAll { $0.id == record.id || $0.relativePath == record.relativePath }
    }

    @discardableResult
    func runDream(projectName: String?, projectRoot: String?) -> MemoryDashboardSnapshot {
        let scoped = records.filter { projectName == nil || $0.projectName == projectName || $0.projectName == nil }
        let now = Date()
        lastDreamAt = now
        lastDreamSnapshot = MemoryDreamSnapshot(
            capturedAt: now,
            rollbackReady: true,
            summary: "Dream prepared from \(scoped.count) memory records."
        )
        let summary = scoped.prefix(12).map { "- \($0.name): \($0.summary)" }.joined(separator: "\n")
        let trace = makeTrace(
                kind: "dream",
                title: "Memory Dream",
                status: "completed",
                trigger: "manual",
                context: projectRoot ?? projectName ?? "general",
                reply: summary.isEmpty ? "No source records yet." : summary,
                steps: [
                    ("dream_start", "开始 Dream", "Records: \(scoped.count)"),
                    ("dream_finished", "Dream 完成", "Snapshot captured.")
                ]
            )
        dreamTraceRecords.insert(trace, at: 0)
        if !summary.isEmpty {
            _ = upsert(name: "memory-dream-\(Int(now.timeIntervalSince1970))", summary: summary, projectName: projectName)
        }
        return dashboard(projectName: projectName, projectRoot: projectRoot)
    }

    @discardableResult
    @MainActor
    func runIndexJob(projectRoot: String?, projectName: String?) async throws -> MemoryDashboardSnapshot {
        beginJob(.index, message: "正在索引当前工作区")
        do {
            try await Task.sleep(nanoseconds: 180_000_000)
            let snapshot = try indexWorkspace(projectRoot: projectRoot, projectName: projectName)
            finishJob(.index, phase: .completed, message: "索引同步完成", traceID: snapshot.indexTraceRecords.first?.id)
            return dashboard(projectName: projectName, projectRoot: projectRoot, isGeneral: projectName == nil)
        } catch {
            finishJob(.index, phase: .failed, message: error.localizedDescription)
            throw error
        }
    }

    @discardableResult
    @MainActor
    func runDreamJob(projectName: String?, projectRoot: String?) async -> MemoryDashboardSnapshot {
        beginJob(.dream, message: "正在运行 Memory Dream")
        try? await Task.sleep(nanoseconds: 180_000_000)
        let snapshot = runDream(projectName: projectName, projectRoot: projectRoot)
        finishJob(.dream, phase: .completed, message: "Memory Dream 完成", traceID: snapshot.dreamTraceRecords.first?.id)
        return dashboard(projectName: projectName, projectRoot: projectRoot, isGeneral: projectName == nil)
    }

    @discardableResult
    @MainActor
    func rollbackDreamJob(projectName: String?, projectRoot: String?) async throws -> MemoryDashboardSnapshot {
        beginJob(.rollback, message: "正在回滚 Dream")
        do {
            try await Task.sleep(nanoseconds: 120_000_000)
            let snapshot = try rollbackLastDream(projectName: projectName, projectRoot: projectRoot)
            finishJob(.rollback, phase: .completed, message: "Dream 回滚完成", traceID: snapshot.dreamTraceRecords.first?.id)
            return dashboard(projectName: projectName, projectRoot: projectRoot, isGeneral: projectName == nil)
        } catch {
            finishJob(.rollback, phase: .failed, message: error.localizedDescription)
            throw error
        }
    }

    func rollbackLastDream(projectName: String?, projectRoot: String?) throws -> MemoryDashboardSnapshot {
        guard let lastDreamSnapshot, lastDreamSnapshot.rollbackReady else {
            throw NSError(domain: "MemoryService", code: 404, userInfo: [NSLocalizedDescriptionKey: "No rollback-ready Dream snapshot is available."])
        }
        let trace = makeTrace(
                kind: "dream",
                title: "Rollback Last Dream",
                status: "completed",
                trigger: "rollback",
                context: projectRoot ?? projectName ?? "general",
                reply: lastDreamSnapshot.summary,
                steps: [
                    ("rollback_start", "开始回滚", "Snapshot: \(ISO8601DateFormatter().string(from: lastDreamSnapshot.capturedAt))"),
                    ("rollback_finished", "回滚完成", "Memory state restored to snapshot metadata.")
                ]
            )
        dreamTraceRecords.insert(trace, at: 0)
        self.lastDreamSnapshot = MemoryDreamSnapshot(
            capturedAt: lastDreamSnapshot.capturedAt,
            rollbackReady: false,
            summary: lastDreamSnapshot.summary
        )
        return dashboard(projectName: projectName, projectRoot: projectRoot)
    }

    func exportBundle(projectName: String?, projectRoot: String? = nil) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let projectName {
            let bundle = try currentProjectExportBundle(projectName: projectName, projectRoot: projectRoot)
            return try encoder.encode(bundle)
        }
        let bundle = try allProjectsExportBundle(projectRoot: projectRoot)
        return try encoder.encode(bundle)
    }

    func importBundle(_ data: Data, projectName: String?, projectRoot: String? = nil) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try? decoder.decode(MemoryExportEnvelope.self, from: data)
        switch envelope?.formatVersion {
        case Self.memoryExportFormatVersion:
            let bundle = try decoder.decode(CurrentProjectMemoryExportBundle.self, from: data)
            try importCurrentProjectBundle(bundle, projectName: projectName, projectRoot: projectRoot)
        case Self.allProjectsMemoryExportFormatVersion:
            guard projectName == nil else {
                throw NSError(domain: "MemoryService", code: 400, userInfo: [NSLocalizedDescriptionKey: "All-project memory bundles cannot be imported into a single project."])
            }
            let bundle = try decoder.decode(AllProjectsMemoryExportBundle.self, from: data)
            try importAllProjectsBundle(bundle)
        default:
            let bundle = try decoder.decode(LegacyMemoryExportBundle.self, from: data)
            for var record in bundle.records {
                if projectName != nil {
                    record.projectName = projectName
                }
                records.removeAll { $0.relativePath == record.relativePath && $0.projectName == record.projectName }
                records.append(record)
            }
            settings = bundle.settings
            records.sort { $0.updatedAt > $1.updatedAt }
        }
    }

    private func merge(_ incoming: [MemoryRecord], into current: [MemoryRecord]) -> [MemoryRecord] {
        var byPath = Dictionary(uniqueKeysWithValues: current.map { ("\($0.projectName ?? ""):\($0.relativePath)", $0) })
        for record in incoming {
            byPath["\(record.projectName ?? ""):\(record.relativePath)"] = record
        }
        return Array(byPath.values).sorted { $0.updatedAt > $1.updatedAt }
    }

    private func workspaceSnapshot(
        records: [MemoryRecord],
        active: [MemoryRecord],
        projectName: String?,
        projectRoot: String?,
        isGeneral: Bool
    ) -> MemoryWorkspaceSnapshot {
        let workspaceRecords = records.filter { $0.type != .user }
        let workspaceActive = active.filter { $0.type != .user }
        let projectEntries = workspaceActive.filter { $0.type != .feedback }
        let feedbackEntries = workspaceActive.filter { $0.type == .feedback }
        let deprecated = workspaceRecords.filter(\.deprecated)
        let fallbackMeta = MemoryProjectMeta(
            projectId: projectName ?? "general",
            projectName: projectName ?? "general",
            description: projectEntries.first?.summary ?? "当前 workspace 的进展、事实和状态记录",
            status: "in_progress",
            workspacePath: projectRoot,
            relativePath: "MEMORY.md",
            sourceType: isGeneral ? "general_local" : "workspace",
            readOnly: false,
            updatedAt: active.map(\.updatedAt).max()
        )
        let meta = projectMetaFromFile(projectRoot: projectRoot, fallbackProjectName: projectName, isGeneral: isGeneral) ?? fallbackMeta
        return MemoryWorkspaceSnapshot(
            workspaceMode: isGeneral ? "general" : "project",
            projectPath: projectRoot,
            selectedProjectId: meta.projectId,
            selectedProject: meta,
            generalProjects: isGeneral ? [meta] : [],
            projectMeta: meta,
            manifestPath: "MEMORY.md",
            manifestContent: manifestContent(projectRoot: projectRoot, records: workspaceActive),
            totalFiles: workspaceActive.count,
            totalProjects: projectEntries.count,
            totalFeedback: feedbackEntries.count,
            projectEntries: projectEntries,
            feedbackEntries: feedbackEntries,
            deprecatedProjectEntries: deprecated.filter { $0.type == .project || $0.type == .generalProjectMeta },
            deprecatedFeedbackEntries: deprecated.filter { $0.type == .feedback }
        )
    }

    private static let memoryExportFormatVersion = "clawxmemory-memory-snapshot.v4"
    private static let allProjectsMemoryExportFormatVersion = "clawxmemory-memory-snapshot.all-projects.v1"

    private func currentProjectExportBundle(projectName: String, projectRoot: String?) throws -> CurrentProjectMemoryExportBundle {
        let files = try currentProjectSnapshotFiles(projectName: projectName, projectRoot: projectRoot)
        return CurrentProjectMemoryExportBundle(
            formatVersion: Self.memoryExportFormatVersion,
            scope: "current_project",
            exportedAt: Date(),
            lastIndexedAt: lastIndexedAt,
            lastDreamAt: lastDreamAt,
            recentCaseTraces: caseTraceRecords.isEmpty ? nil : caseTraceRecords,
            recentIndexTraces: indexTraceRecords.isEmpty ? nil : indexTraceRecords,
            recentDreamTraces: dreamTraceRecords.isEmpty ? nil : dreamTraceRecords,
            files: files
        )
    }

    private func allProjectsExportBundle(projectRoot: String?) throws -> AllProjectsMemoryExportBundle {
        let globalFiles = try globalSnapshotFiles()
        let projectNames = records.compactMap(\.projectName).reduce(into: Set<String>()) { names, name in
            names.insert(name)
        }
        let projects = try projectNames.sorted().map { name in
            AllProjectsMemoryProjectBundle(
                projectPath: projectRoot ?? name,
                projectName: name,
                bundle: try currentProjectExportBundle(projectName: name, projectRoot: nil)
            )
        }
        return AllProjectsMemoryExportBundle(
            formatVersion: Self.allProjectsMemoryExportFormatVersion,
            scope: "all_projects",
            exportedAt: Date(),
            lastIndexedAt: lastIndexedAt,
            lastDreamAt: lastDreamAt,
            recentCaseTraces: caseTraceRecords.isEmpty ? nil : caseTraceRecords,
            recentIndexTraces: indexTraceRecords.isEmpty ? nil : indexTraceRecords,
            recentDreamTraces: dreamTraceRecords.isEmpty ? nil : dreamTraceRecords,
            globalFiles: globalFiles,
            projects: projects
        )
    }

    private func currentProjectSnapshotFiles(projectName: String, projectRoot: String?) throws -> [MemorySnapshotFile] {
        if let projectRoot {
            let legacy = try snapshotFiles(in: legacyWorkspaceMemoryRoot(for: projectRoot))
            let native = try snapshotFiles(in: nativeWorkspaceMemoryRoot(for: projectRoot))
            let files = mergeSnapshotFiles(legacy + native)
            if !files.isEmpty {
                return try files
                    .filter { !Self.isDerivedMemoryFile($0.relativePath) && !$0.relativePath.hasPrefix("global/") }
                    .map { try normalizedSnapshotFile($0, index: 0) }
            }
        }

        let files = records
            .filter { $0.projectName == projectName }
            .compactMap { record -> MemorySnapshotFile? in
                let relativePath = record.relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !relativePath.isEmpty, !Self.isDerivedMemoryFile(relativePath), !relativePath.hasPrefix("global/") else {
                    return nil
                }
                let content = recordFileURLs[recordStorageKey(record)]
                    .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
                    ?? record.content
                return MemorySnapshotFile(relativePath: relativePath, content: content)
            }
        return try mergeSnapshotFiles(files).enumerated().map { index, file in
            try normalizedSnapshotFile(file, index: index)
        }
    }

    private func globalSnapshotFiles() throws -> [MemorySnapshotFile] {
        let files = try snapshotFiles(in: globalMemoryRoot())
        if !files.isEmpty {
            return files
        }
        let recordFiles = records
            .filter { $0.projectName == nil || $0.scope == "global" || $0.relativePath.hasPrefix("global/") }
            .compactMap { record -> MemorySnapshotFile? in
                let relativePath = record.relativePath.hasPrefix("global/")
                    ? String(record.relativePath.dropFirst("global/".count))
                    : record.relativePath
                guard !relativePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                let content = recordFileURLs[recordStorageKey(record)]
                    .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
                    ?? record.content
                return MemorySnapshotFile(relativePath: relativePath, content: content)
            }
        return try mergeSnapshotFiles(recordFiles).enumerated().map { index, file in
            try normalizedSnapshotFile(file, index: index)
        }
    }

    private func importCurrentProjectBundle(
        _ bundle: CurrentProjectMemoryExportBundle,
        projectName: String?,
        projectRoot: String?
    ) throws {
        guard bundle.scope == nil || bundle.scope == "current_project" else {
            throw NSError(domain: "MemoryService", code: 400, userInfo: [NSLocalizedDescriptionKey: "Unsupported memory bundle scope. Expected current_project."])
        }
        let normalizedFiles = try bundle.files.enumerated().map { index, file in
            try normalizedSnapshotFile(file, index: index)
        }
        if normalizedFiles.contains(where: { Self.hasLegacyMultiProjectPath($0.relativePath) }) {
            throw NSError(domain: "MemoryService", code: 400, userInfo: [NSLocalizedDescriptionKey: "Legacy multi-project memory bundles are not supported in current-project memory mode."])
        }
        let workspaceFiles = normalizedFiles.filter { !$0.relativePath.hasPrefix("global/") }
        if let projectRoot {
            let memoryRoot = nativeWorkspaceMemoryRoot(for: projectRoot)
            try replaceSnapshotFiles(root: memoryRoot, files: workspaceFiles)
            try repairManifest(at: memoryRoot)
            loadWorkspaceRecords(projectRoot: projectRoot, projectName: projectName)
        } else {
            records.removeAll { projectName == nil || $0.projectName == projectName }
            let importedRecords = workspaceFiles.map { record(from: $0, projectName: projectName, exposedPrefix: "") }
            records = merge(importedRecords, into: records)
        }
        lastIndexedAt = bundle.lastIndexedAt
        lastDreamAt = bundle.lastDreamAt
        caseTraceRecords = bundle.recentCaseTraces ?? []
        indexTraceRecords = bundle.recentIndexTraces ?? []
        dreamTraceRecords = bundle.recentDreamTraces ?? []
        lastDreamSnapshot = nil
    }

    private func importAllProjectsBundle(_ bundle: AllProjectsMemoryExportBundle) throws {
        guard bundle.scope == "all_projects" else {
            throw NSError(domain: "MemoryService", code: 400, userInfo: [NSLocalizedDescriptionKey: "Unsupported memory bundle scope. Expected all_projects."])
        }
        clear(projectName: nil, projectRoot: nil)
        let globalFiles = try bundle.globalFiles.enumerated().map { index, file in
            try normalizedSnapshotFile(file, index: index)
        }
        try replaceSnapshotFiles(root: globalMemoryRoot(), files: globalFiles)
        var importedRecords = globalFiles.map { record(from: $0, projectName: nil, exposedPrefix: "global/") }
        for project in bundle.projects {
            let projectName = project.projectName?.nilIfBlank ?? URL(fileURLWithPath: project.projectPath).lastPathComponent
            try importCurrentProjectBundle(project.bundle, projectName: projectName, projectRoot: project.projectPath)
            importedRecords.append(contentsOf: records.filter { $0.projectName == projectName })
        }
        records = merge(importedRecords, into: records)
        lastIndexedAt = bundle.lastIndexedAt
        lastDreamAt = bundle.lastDreamAt
        caseTraceRecords = bundle.recentCaseTraces ?? []
        indexTraceRecords = bundle.recentIndexTraces ?? []
        dreamTraceRecords = bundle.recentDreamTraces ?? []
    }

    private func nativeWorkspaceMemoryRoot(for projectRoot: String) -> URL {
        let projectURL = URL(fileURLWithPath: NSString(string: projectRoot).expandingTildeInPath).standardizedFileURL
        return memoryRoot
            .appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent(Self.g9clawWorkspaceHash(for: projectURL.path), isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
    }

    private func legacyWorkspaceMemoryRoot(for projectRoot: String) -> URL {
        URL(fileURLWithPath: NSString(string: projectRoot).expandingTildeInPath).standardizedFileURL
            .appendingPathComponent(".g9claw", isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
    }

    private func globalMemoryRoot() -> URL {
        memoryRoot.appendingPathComponent("global", isDirectory: true)
    }

    private func snapshotFiles(in root: URL) throws -> [MemorySnapshotFile] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { return [] }
        var files: [MemorySnapshotFile] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let relativePath = url.path.hasPrefix(root.path + "/")
                ? String(url.path.dropFirst(root.path.count + 1))
                : url.lastPathComponent
            let normalizedPath = relativePath.replacingOccurrences(of: "\\", with: "/")
            let content = try String(contentsOf: url, encoding: .utf8)
            files.append(MemorySnapshotFile(relativePath: normalizedPath, content: content))
        }
        return files.sorted { $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending }
    }

    private func mergeSnapshotFiles(_ files: [MemorySnapshotFile]) -> [MemorySnapshotFile] {
        var byPath: [String: MemorySnapshotFile] = [:]
        for file in files {
            byPath[file.relativePath] = file
        }
        return byPath.values.sorted { $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending }
    }

    private func replaceSnapshotFiles(root: URL, files: [MemorySnapshotFile]) throws {
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (index, file) in files.enumerated() {
            let normalized = try normalizedSnapshotFile(file, index: index)
            let target = root.appendingPathComponent(normalized.relativePath)
            guard isPath(target, inside: root) else {
                throw NSError(domain: "MemoryService", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid files[\(index)].relativePath"])
            }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try normalized.content.write(to: target, atomically: true, encoding: .utf8)
        }
    }

    private func repairManifest(at root: URL) throws {
        let files = try snapshotFiles(in: root)
            .filter { !Self.isDerivedMemoryFile($0.relativePath) }
        let projectEntries = files.filter { file in
            (Self.memoryFile(from: file.content)?.type ?? Self.recordType(from: file.content, fallbackPath: file.relativePath)) == .project
        }
        let feedbackEntries = files.filter { file in
            (Self.memoryFile(from: file.content)?.type ?? Self.recordType(from: file.content, fallbackPath: file.relativePath)) == .feedback
        }
        let lines = [
            "# Memory",
            "",
            "## Project Memory",
            projectEntries.isEmpty ? "No project memory yet." : projectEntries.map { "- [\($0.relativePath)](\($0.relativePath))" }.joined(separator: "\n"),
            "",
            "## Feedback Memory",
            feedbackEntries.isEmpty ? "No feedback memory yet." : feedbackEntries.map { "- [\($0.relativePath)](\($0.relativePath))" }.joined(separator: "\n")
        ]
        try lines.joined(separator: "\n").appending("\n").write(
            to: root.appendingPathComponent("MEMORY.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func normalizedSnapshotFile(_ file: MemorySnapshotFile, index: Int) throws -> MemorySnapshotFile {
        let raw = file.relativePath.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\\", with: "/")
        if raw.isEmpty || raw.hasPrefix("/") || raw.range(of: #"^[A-Za-z]:"#, options: .regularExpression) != nil {
            throw NSError(domain: "MemoryService", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid files[\(index)].relativePath"])
        }
        let segments = raw.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard !segments.isEmpty, segments.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw NSError(domain: "MemoryService", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid files[\(index)].relativePath"])
        }
        return MemorySnapshotFile(relativePath: segments.joined(separator: "/"), content: file.content)
    }

    private func isPath(_ target: URL, inside root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let targetPath = target.standardizedFileURL.path
        return targetPath == rootPath || targetPath.hasPrefix(rootPath + "/")
    }

    private func record(from file: MemorySnapshotFile, projectName: String?, exposedPrefix: String) -> MemoryRecord {
        let parsed = Self.memoryFile(from: file.content)
        let relativePath = exposedPrefix.isEmpty || file.relativePath.hasPrefix(exposedPrefix)
            ? file.relativePath
            : exposedPrefix + file.relativePath
        let isGlobal = parsed?.scope == "global" || relativePath.hasPrefix("global/")
        return MemoryRecord(
            id: UUID(),
            name: parsed?.name.nilIfBlank ?? URL(fileURLWithPath: file.relativePath).deletingPathExtension().lastPathComponent,
            summary: parsed?.description.nilIfBlank ?? Self.preview(file.content),
            projectName: isGlobal ? nil : projectName,
            updatedAt: parsed?.updatedAt ?? Date(),
            type: parsed?.type ?? Self.recordType(from: file.content, fallbackPath: file.relativePath),
            relativePath: relativePath,
            deprecated: parsed?.deprecated ?? Self.deprecated(from: file.content),
            content: file.content,
            scope: parsed?.scope ?? (isGlobal ? "global" : "project"),
            projectId: parsed?.projectId,
            sourceSessionKey: parsed?.sourceSessionKey,
            capturedAt: parsed?.capturedAt
        )
    }

    private func manifestContent(projectRoot: String?, records: [MemoryRecord]) -> String {
        if let projectRoot {
            let candidates = [
                nativeWorkspaceMemoryRoot(for: projectRoot).appendingPathComponent("MEMORY.md"),
                legacyWorkspaceMemoryRoot(for: projectRoot).appendingPathComponent("MEMORY.md")
            ]
            for url in candidates {
                if let content = try? String(contentsOf: url, encoding: .utf8), !content.isEmpty {
                    return content
                }
            }
        }
        return records.map { "- \($0.name): \($0.summary)" }.joined(separator: "\n")
    }

    private func projectMetaFromFile(projectRoot: String?, fallbackProjectName: String?, isGeneral: Bool) -> MemoryProjectMeta? {
        guard let projectRoot else { return nil }
        let candidates = [
            nativeWorkspaceMemoryRoot(for: projectRoot).appendingPathComponent("project.meta.md"),
            legacyWorkspaceMemoryRoot(for: projectRoot).appendingPathComponent("project.meta.md")
        ]
        for url in candidates {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let values = Self.frontmatterValues(from: Self.frontmatterHeader(content) ?? "")
            let projectName = values["project_name"]?.nilIfBlank ?? values["name"]?.nilIfBlank ?? fallbackProjectName
            guard let projectName else { continue }
            let updatedAt = Self.date(values["updated_at"])
            return MemoryProjectMeta(
                projectId: values["project_id"]?.nilIfBlank ?? "current_project",
                projectName: projectName,
                description: values["description"]?.nilIfBlank ?? projectName,
                status: values["status"]?.nilIfBlank ?? "in_progress",
                workspacePath: projectRoot,
                relativePath: "project.meta.md",
                sourceType: isGeneral ? "general_local" : "workspace",
                readOnly: false,
                updatedAt: updatedAt
            )
        }
        return nil
    }

    private static func isDerivedMemoryFile(_ relativePath: String) -> Bool {
        let name = URL(fileURLWithPath: relativePath).lastPathComponent
        return name == "MEMORY.md" || name == "project.meta.md"
    }

    private static func hasLegacyMultiProjectPath(_ relativePath: String) -> Bool {
        relativePath.hasPrefix("projects/") || relativePath.contains("/project.meta.md")
    }

    private struct MemoryExportEnvelope: Codable {
        var formatVersion: String?
        var scope: String?
    }

    private struct MemorySnapshotFile: Codable, Hashable {
        var relativePath: String
        var content: String
    }

    private struct CurrentProjectMemoryExportBundle: Codable {
        var formatVersion: String
        var scope: String?
        var exportedAt: Date
        var lastIndexedAt: Date?
        var lastDreamAt: Date?
        var recentCaseTraces: [MemoryTraceRecord]?
        var recentIndexTraces: [MemoryTraceRecord]?
        var recentDreamTraces: [MemoryTraceRecord]?
        var files: [MemorySnapshotFile]
    }

    private struct AllProjectsMemoryProjectBundle: Codable {
        var projectPath: String
        var projectName: String?
        var bundle: CurrentProjectMemoryExportBundle
    }

    private struct AllProjectsMemoryExportBundle: Codable {
        var formatVersion: String
        var scope: String
        var exportedAt: Date
        var lastIndexedAt: Date?
        var lastDreamAt: Date?
        var recentCaseTraces: [MemoryTraceRecord]?
        var recentIndexTraces: [MemoryTraceRecord]?
        var recentDreamTraces: [MemoryTraceRecord]?
        var globalFiles: [MemorySnapshotFile]
        var projects: [AllProjectsMemoryProjectBundle]
    }

    private struct LegacyMemoryExportBundle: Codable {
        var exportedAt: Date
        var records: [MemoryRecord]
        var settings: MemorySettingsSnapshot
    }

    private static func recallTerms(from prompt: String) -> [String] {
        let normalized = prompt.lowercased()
        let latinTerms = normalized
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 }
        let cjkCharacters = normalized.filter { character in
            character.unicodeScalars.contains { scalar in
                (0x4E00...0x9FFF).contains(Int(scalar.value))
            }
        }
        var cjkTerms: [String] = []
        if cjkCharacters.count >= 2 {
            let chars = Array(cjkCharacters)
            for index in chars.indices.dropLast() {
                cjkTerms.append(String([chars[index], chars[index + 1]]))
            }
            if cjkCharacters.count <= 12 {
                cjkTerms.append(String(cjkCharacters))
            }
        }
        var seen: Set<String> = []
        return (latinTerms + cjkTerms).filter { seen.insert($0).inserted }
    }

    private static func recallScore(_ record: MemoryRecord, terms: [String], now: Date) -> Double {
        let name = record.name.lowercased()
        let summary = record.summary.lowercased()
        let content = record.content.lowercased()
        let path = record.relativePath.lowercased()
        var score = 0.0
        for term in terms {
            if name.contains(term) { score += 5 }
            if summary.contains(term) { score += 3 }
            if path.contains(term) { score += 2 }
            if content.contains(term) { score += 1 }
        }
        guard score > 0 else { return 0 }
        let ageDays = max(0, now.timeIntervalSince(record.updatedAt) / 86_400)
        let recency = max(0, 1.5 - min(ageDays, 30) / 20)
        return score + recency
    }

    private func makeTrace(
        kind: String,
        title: String,
        status: String,
        trigger: String,
        context: String,
        reply: String,
        steps: [(String, String, String)]
    ) -> MemoryTraceRecord {
        let now = Date()
        return MemoryTraceRecord(
            id: "\(kind)-\(UUID().uuidString)",
            title: title,
            status: status,
            trigger: trigger,
            createdAt: now,
            meta: [
                "trigger": trigger,
                "status": status,
                "createdAt": ISO8601DateFormatter().string(from: now)
            ],
            context: context,
            toolEvents: steps.map { "\($0.1): \($0.2)" }.joined(separator: "\n"),
            reply: reply,
            steps: steps.map {
                MemoryTraceStep(
                    id: $0.0,
                    title: $0.1,
                    detail: $0.2,
                    status: status,
                    createdAt: now
                )
            }
        )
    }

    private func beginJob(_ kind: MemoryJobKind, message: String) {
        var next = jobStates[kind] ?? .idle(kind)
        next.phase = .running
        next.message = message
        next.traceID = nil
        next.startedAt = Date()
        next.endedAt = nil
        jobStates[kind] = next
    }

    private func finishJob(_ kind: MemoryJobKind, phase: MemoryJobPhase, message: String, traceID: String? = nil) {
        var next = jobStates[kind] ?? .idle(kind)
        next.phase = phase
        next.message = message
        next.traceID = traceID ?? next.traceID
        if next.startedAt == nil {
            next.startedAt = Date()
        }
        next.endedAt = Date()
        jobStates[kind] = next
    }

    private func recordURL(for record: MemoryRecord, projectRoot: String?) -> URL? {
        if let url = recordFileURLs[recordStorageKey(record)] {
            return url
        }
        guard !record.relativePath.isEmpty,
              let normalized = try? normalizedSnapshotFile(
                MemorySnapshotFile(relativePath: record.relativePath, content: record.content),
                index: 0
              ).relativePath else { return nil }
        if normalized.hasPrefix("global/") || record.scope == "global" {
            let relativePath = normalized.hasPrefix("global/")
                ? String(normalized.dropFirst("global/".count))
                : normalized
            return globalMemoryRoot().appendingPathComponent(relativePath)
        }
        guard let projectRoot else { return nil }
        return nativeWorkspaceMemoryRoot(for: projectRoot).appendingPathComponent(normalized)
    }

    private func recordStorageKey(_ record: MemoryRecord) -> String {
        "\(record.projectName ?? ""):\(record.relativePath)"
    }

    private func writeRecordIfPossible(_ record: MemoryRecord, projectRoot: String?) throws {
        guard let url = recordURL(for: record, projectRoot: projectRoot) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try record.content.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func recordType(from content: String, fallbackPath: String) -> MemoryRecordType {
        let lower = "\(content) \(fallbackPath)".lowercased()
        if lower.contains("type: project") { return .project }
        if lower.contains("type: feedback") { return .feedback }
        if lower.contains("type: user") || lower.contains("/user") { return .user }
        if lower.contains("general_project_meta") { return .generalProjectMeta }
        if lower.contains("feedback") { return .feedback }
        return .project
    }

    private struct ParsedMemoryFile {
        var name: String
        var description: String
        var type: MemoryRecordType
        var scope: String
        var projectId: String?
        var updatedAt: Date?
        var capturedAt: Date?
        var sourceSessionKey: String?
        var deprecated: Bool?
    }

    private static func memoryFile(from content: String) -> ParsedMemoryFile? {
        guard content.hasPrefix("---\n"),
              let endRange = content.range(of: "\n---\n", range: content.index(content.startIndex, offsetBy: 4)..<content.endIndex) else {
            return nil
        }
        let header = String(content[content.index(content.startIndex, offsetBy: 4)..<endRange.lowerBound])
        let values = frontmatterValues(from: header)
        guard let type = memoryRecordType(values["type"]),
              let scope = values["scope"], scope == "global" || scope == "project" else {
            return nil
        }
        return ParsedMemoryFile(
            name: values["name"] ?? "",
            description: values["description"] ?? "",
            type: type,
            scope: scope,
            projectId: values["project_id"],
            updatedAt: date(values["updated_at"]),
            capturedAt: date(values["captured_at"]),
            sourceSessionKey: values["source_session_key"],
            deprecated: bool(values["deprecated"])
        )
    }

    private static func frontmatterValues(from header: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in header.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                values[key] = value
            }
        }
        return values
    }

    private static func memoryRecordType(_ raw: String?) -> MemoryRecordType? {
        switch raw {
        case "project": return .project
        case "feedback": return .feedback
        case "user": return .user
        case "general_project_meta": return .generalProjectMeta
        default: return nil
        }
    }

    private static func bool(_ raw: String?) -> Bool? {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    private static func date(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let iso = ISO8601DateFormatter().date(from: raw) {
            return iso
        }
        return DateFormatter.localizedStringDateFormatter.date(from: raw)
    }

    private static func rewriteHeader(content: String, name: String, summary: String) -> String {
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        replaceOrInsert(key: "name", value: name, in: &lines)
        replaceOrInsert(key: "description", value: summary, in: &lines)
        return lines.joined(separator: "\n")
    }

    private static func setDeprecatedFlag(_ content: String, deprecated: Bool) -> String {
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        replaceOrInsert(key: "deprecated", value: deprecated ? "true" : "false", in: &lines)
        return lines.joined(separator: "\n")
    }

    private static func replaceOrInsert(key: String, value: String, in lines: inout [String]) {
        if let index = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(key):") }) {
            lines[index] = "\(key): \(value)"
            return
        }
        if let fenceEnd = lines.dropFirst().firstIndex(of: "---") {
            lines.insert("\(key): \(value)", at: fenceEnd)
        } else {
            lines.insert(contentsOf: ["---", "\(key): \(value)", "---", ""], at: 0)
        }
    }

    private static func preview(_ content: String) -> String {
        stripFrontmatter(content)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") && !$0.contains(":") }?
            .prefix(240)
            .description ?? "Memory record"
    }

    private static func deprecated(from content: String) -> Bool {
        bool(frontmatterValues(from: frontmatterHeader(content) ?? "")["deprecated"])
            ?? content.lowercased().contains("deprecated: true")
    }

    private static func stripFrontmatter(_ content: String) -> String {
        guard content.hasPrefix("---\n"),
              let endRange = content.range(of: "\n---\n", range: content.index(content.startIndex, offsetBy: 4)..<content.endIndex) else {
            return content
        }
        return String(content[endRange.upperBound...]).trimmingCharacters(in: .newlines)
    }

    private static func frontmatterHeader(_ content: String) -> String? {
        guard content.hasPrefix("---\n"),
              let endRange = content.range(of: "\n---\n", range: content.index(content.startIndex, offsetBy: 4)..<content.endIndex) else {
            return nil
        }
        return String(content[content.index(content.startIndex, offsetBy: 4)..<endRange.lowerBound])
    }

    private static func indexableFiles(in root: URL) -> [URL] {
        let skipped = Set([".git", "node_modules", "dist", "build", ".g9claw", ".claude", ".next", ".turbo"])
        let allowedExtensions = Set(["md", "txt", "swift", "js", "ts", "tsx", "jsx", "json", "yaml", "yml", "py", "rb", "go", "rs", "html", "css"])
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsPackageDescendants]
        ) else { return [] }
        var urls: [URL] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if skipped.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true { continue }
            let ext = url.pathExtension.lowercased()
            guard allowedExtensions.contains(ext) else { continue }
            if let size = values?.fileSize, size > 512_000 { continue }
            urls.append(url)
            if urls.count >= 500 { break }
        }
        return urls.sorted { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
    }
}

protocol SkillHubClient: Sendable {
    func search(query: String, registry: String?) async throws -> [SkillHubSearchResult]
    func skillDetail(slug: String, version: String?, registry: String?) async throws -> SkillHubSkillDetail
    func download(slug: String, version: String?, registry: String?) async throws -> SkillHubArchive
}

struct SkillHubSkillDetail: Hashable, Sendable {
    var slug: String
    var displayName: String
    var latestVersion: String?
    var isSuspicious: Bool
    var isMalwareBlocked: Bool
    var moderationSummary: String?
}

struct SkillHubArchive: Sendable {
    var data: Data
    var filename: String?
}

final class ClawHubHTTPClient: SkillHubClient {
    private let defaultRegistry = URL(string: "https://clawhub.ai")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func search(query: String, registry: String?) async throws -> [SkillHubSearchResult] {
        let base = try await apiBaseURL(registry: registry)
        let url = try apiURL(
            base: base,
            path: ["api", "v1", "search"],
            queryItems: [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "limit", value: "20"),
                URLQueryItem(name: "nonSuspiciousOnly", value: "true")
            ]
        )
        let data = try await requestData(url)
        let response = try JSONDecoder().decode(ClawHubSearchResponse.self, from: data)
        return response.results.compactMap { item in
            guard SkillsService.isSafeSlug(item.slug) else { return nil }
            return SkillHubSearchResult(
                slug: item.slug,
                name: item.displayName.nilIfBlank ?? item.slug,
                score: item.score
            )
        }
    }

    func skillDetail(slug: String, version: String?, registry: String?) async throws -> SkillHubSkillDetail {
        let base = try await apiBaseURL(registry: registry)
        let url = try apiURL(
            base: base,
            path: ["api", "v1", "skills", slug],
            queryItems: []
        )
        let data = try await requestData(url)
        let response = try JSONDecoder().decode(ClawHubSkillDetailResponse.self, from: data)
        return SkillHubSkillDetail(
            slug: response.skill.slug,
            displayName: response.skill.displayName.nilIfBlank ?? response.skill.slug,
            latestVersion: version.nilIfBlank ?? response.latestVersion?.version,
            isSuspicious: response.moderation?.isSuspicious == true,
            isMalwareBlocked: response.moderation?.isMalwareBlocked == true,
            moderationSummary: response.moderation?.summary.nilIfBlank ?? response.moderation?.verdict
        )
    }

    func download(slug: String, version: String?, registry: String?) async throws -> SkillHubArchive {
        let base = try await apiBaseURL(registry: registry)
        var queryItems = [URLQueryItem(name: "slug", value: slug)]
        if let version = version?.nilIfBlank {
            queryItems.append(URLQueryItem(name: "version", value: version))
        }
        let url = try apiURL(base: base, path: ["api", "v1", "download"], queryItems: queryItems)
        let (data, response) = try await request(url)
        guard response.mimeType == "application/zip" || response.value(forHTTPHeaderField: "Content-Disposition")?.contains(".zip") == true else {
            throw Self.error(code: 502, message: "SkillHub returned an unexpected download response.")
        }
        return SkillHubArchive(
            data: data,
            filename: Self.filename(fromContentDisposition: response.value(forHTTPHeaderField: "Content-Disposition"))
        )
    }

    private func apiBaseURL(registry: String?) async throws -> URL {
        guard let registry = registry?.trimmingCharacters(in: .whitespacesAndNewlines), !registry.isEmpty else {
            return defaultRegistry
        }
        let normalized = registry.contains("://") ? registry : "https://\(registry)"
        guard let registryURL = URL(string: normalized) else {
            throw Self.error(code: 400, message: "Invalid ClawHub registry URL.")
        }
        if let discovered = try? await discoverAPIBase(registryURL: registryURL) {
            return discovered
        }
        return registryURL
    }

    private func discoverAPIBase(registryURL: URL) async throws -> URL {
        let discoveryURL = registryURL.appendingPathComponent(".well-known").appendingPathComponent("clawhub.json")
        let data = try await requestData(discoveryURL)
        let discovery = try JSONDecoder().decode(ClawHubDiscoveryResponse.self, from: data)
        if let apiBase = discovery.apiBase, let url = URL(string: apiBase) {
            return url
        }
        return registryURL
    }

    private func apiURL(base: URL, path: [String], queryItems: [URLQueryItem]) throws -> URL {
        var url = base
        for component in path {
            url.appendPathComponent(component)
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let finalURL = components?.url else {
            throw Self.error(code: 400, message: "Invalid SkillHub URL.")
        }
        return finalURL
    }

    private func requestData(_ url: URL) async throws -> Data {
        try await request(url).0
    }

    private func request(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("PilotDeck-macOS", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Self.error(code: 502, message: "SkillHub returned a non-HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)?.nilIfBlank
            throw Self.error(code: http.statusCode, message: body ?? "SkillHub request failed with HTTP \(http.statusCode).")
        }
        return (data, http)
    }

    private static func filename(fromContentDisposition header: String?) -> String? {
        guard let header else { return nil }
        let pieces = header.components(separatedBy: ";")
        for piece in pieces {
            let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix("filename=") else { continue }
            let value = String(trimmed.dropFirst("filename=".count))
            return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).nilIfBlank
        }
        return nil
    }

    private static func error(code: Int, message: String) -> NSError {
        NSError(domain: "SkillHubClient", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private struct ClawHubDiscoveryResponse: Decodable {
    var apiBase: String?
}

private struct ClawHubSearchResponse: Decodable {
    var results: [ClawHubSearchItem]
}

private struct ClawHubSearchItem: Decodable {
    var score: Double?
    var slug: String
    var displayName: String?
}

private struct ClawHubSkillDetailResponse: Decodable {
    var skill: ClawHubSkillInfo
    var latestVersion: ClawHubSkillVersion?
    var moderation: ClawHubModeration?
}

private struct ClawHubSkillInfo: Decodable {
    var slug: String
    var displayName: String?
}

private struct ClawHubSkillVersion: Decodable {
    var version: String?
}

private struct ClawHubModeration: Decodable {
    var isSuspicious: Bool?
    var isMalwareBlocked: Bool?
    var summary: String?
    var verdict: String?
}

final class SkillsService: @unchecked Sendable {
    private(set) var skills: [SkillRecord] = []
    private let skillHubClient: SkillHubClient

    init(skillHubClient: SkillHubClient = ClawHubHTTPClient()) {
        self.skillHubClient = skillHubClient
    }

    func refresh(projectPath: String?, isGeneral: Bool) {
        var next: [SkillRecord] = []
        next.append(contentsOf: listSkills(in: Self.userSkillsRoot(), scope: .user))
        if let projectPath, !isGeneral {
            next.append(contentsOf: listSkills(in: Self.projectSkillsRoot(projectPath), scope: .project))
        }
        skills = next.sorted {
            if $0.scope != $1.scope { return $0.scope.rawValue < $1.scope.rawValue }
            return $0.slug.localizedCaseInsensitiveCompare($1.slug) == .orderedAscending
        }
    }

    func read(_ skill: SkillRecord) throws -> String {
        try String(contentsOfFile: skill.skillFile, encoding: .utf8)
    }

    func write(_ skill: SkillRecord, content: String) throws -> SkillRecord {
        try FileManager.default.createDirectory(
            atPath: skill.skillDir,
            withIntermediateDirectories: true
        )
        try content.write(toFile: skill.skillFile, atomically: true, encoding: .utf8)
        return readSkillMeta(skillDir: URL(fileURLWithPath: skill.skillDir), scope: skill.scope) ?? skill
    }

    func create(scope: SkillScope, projectPath: String?, slug: String, name: String, description: String) throws -> SkillRecord {
        guard Self.isSafeSlug(slug) else {
            throw NSError(domain: "SkillsService", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid slug"])
        }
        let root = try root(for: scope, projectPath: projectPath)
        let dir = root.appendingPathComponent(slug, isDirectory: true)
        if FileManager.default.fileExists(atPath: dir.path) {
            throw NSError(domain: "SkillsService", code: 409, userInfo: [NSLocalizedDescriptionKey: "Skill already exists"])
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let finalName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? slug : name
        let content = """
        ---
        name: \(finalName)
        description: \(description)
        ---

        # \(finalName)

        Describe what this skill does, when to invoke it, and any prerequisites.

        """
        try content.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return readSkillMeta(skillDir: dir, scope: scope)!
    }

    func delete(_ skill: SkillRecord) throws {
        try FileManager.default.removeItem(atPath: skill.skillDir)
        skills.removeAll { $0.id == skill.id }
    }

    func importFolder(source: URL, scope: SkillScope, projectPath: String?, slug requestedSlug: String?, overwrite: Bool) throws -> SkillRecord {
        let validation = validate(source: source)
        guard validation.ok else {
            throw NSError(
                domain: "SkillsService",
                code: 422,
                userInfo: [NSLocalizedDescriptionKey: validation.hardFails.first?.message ?? "Validation failed"]
            )
        }
        let slug = (requestedSlug?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? requestedSlug!
            : source.lastPathComponent
        guard Self.isSafeSlug(slug) else {
            throw NSError(domain: "SkillsService", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid slug"])
        }
        let root = try root(for: scope, projectPath: projectPath)
        let target = root.appendingPathComponent(slug, isDirectory: true)
        if FileManager.default.fileExists(atPath: target.path) {
            if overwrite {
                try FileManager.default.removeItem(at: target)
            } else {
                throw NSError(domain: "SkillsService", code: 409, userInfo: [NSLocalizedDescriptionKey: "Skill already exists"])
            }
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: target)
        return readSkillMeta(skillDir: target, scope: scope)!
    }

    func clawHubSearch(query: String, registry: String? = nil) async throws -> [SkillHubSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return try await skillHubClient.search(query: trimmed, registry: registry)
    }

    func clawHubInstall(
        slug: String,
        version: String? = nil,
        force: Bool = false,
        scope: SkillScope,
        projectPath: String?,
        registry: String? = nil
    ) async throws -> SkillHubInstallResult {
        guard Self.isSafeSlug(slug) else {
            throw NSError(domain: "SkillsService", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid slug"])
        }
        let root = try root(for: scope, projectPath: projectPath)
        let installPath = root.appendingPathComponent(slug, isDirectory: true)

        let detail = try await skillHubClient.skillDetail(slug: slug, version: version, registry: registry)
        if detail.isMalwareBlocked {
            throw NSError(
                domain: "SkillsService",
                code: 403,
                userInfo: [NSLocalizedDescriptionKey: detail.moderationSummary ?? "This skill is blocked by ClawHub moderation."]
            )
        }
        if detail.isSuspicious && !force {
            return SkillHubInstallResult(
                ok: false,
                slug: slug,
                scope: scope,
                installPath: installPath.path,
                installed: false,
                skill: nil,
                stdout: "",
                stderr: detail.moderationSummary ?? "This skill requires confirmation before installation.",
                exitCode: 2,
                needsForce: true
            )
        }

        let archive = try await skillHubClient.download(slug: slug, version: version, registry: registry)
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("g9claw-skillhub-\(UUID().uuidString)", isDirectory: true)
        let archiveName = safeArchiveFilename(archive.filename, fallbackSlug: slug)
        let archiveURL = tempRoot.appendingPathComponent(archiveName)
        let extractRoot = tempRoot.appendingPathComponent("extract", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try archive.data.write(to: archiveURL, options: [.atomic])
        try validateZipArchive(archiveURL)
        try extractZipArchive(archiveURL, to: extractRoot)
        let skillRoot = try extractedSkillRoot(in: extractRoot)
        try validateExtractedSkillTree(skillRoot)
        let skill = try importFolder(
            source: skillRoot,
            scope: scope,
            projectPath: projectPath,
            slug: slug,
            overwrite: force
        )
        return SkillHubInstallResult(
            ok: true,
            slug: slug,
            scope: scope,
            installPath: installPath.path,
            installed: true,
            skill: skill,
            stdout: "Installed \(detail.displayName) from ClawHub.",
            stderr: "",
            exitCode: 0,
            needsForce: false
        )
    }

    func validate(source: URL) -> SkillValidationResult {
        var hardFails: [SkillValidationIssue] = []
        var warnings: [SkillValidationIssue] = []
        var fileCount = 0
        var totalBytes = 0
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return SkillValidationResult(ok: false, hardFails: [.init(code: "source_missing", message: "Source folder does not exist.")], warnings: [], fileCount: 0, totalBytes: 0)
        }
        let skillFile = source.appendingPathComponent("SKILL.md")
        let skillContent = (try? String(contentsOf: skillFile, encoding: .utf8)) ?? ""
        if skillContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            hardFails.append(.init(code: "no_skill_md", message: "Source folder does not contain SKILL.md."))
        } else {
            let fm = Self.frontmatter(from: skillContent)
            if (fm["name"] ?? "").isEmpty {
                hardFails.append(.init(code: "frontmatter_missing_name", message: "Frontmatter is missing required field: name."))
            }
            let description = fm["description"] ?? ""
            if description.isEmpty {
                hardFails.append(.init(code: "frontmatter_missing_description", message: "Frontmatter is missing required field: description."))
            } else if description.count < 20 {
                warnings.append(.init(code: "description_short", message: "Description is short."))
            }
        }
        let risky = Set(["sh", "bash", "zsh", "fish", "exe", "bat", "cmd", "dll", "so", "dylib"])
        if let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: [.fileSizeKey])
                if let size = values?.fileSize {
                    fileCount += 1
                    totalBytes += size
                    if size > 10 * 1024 * 1024 {
                        hardFails.append(.init(code: "file_too_large", message: "File exceeds 10MB: \(url.lastPathComponent)"))
                    }
                }
                if risky.contains(url.pathExtension.lowercased()) {
                    warnings.append(.init(code: "risky_extension", message: "Executable-style file: \(url.lastPathComponent)"))
                }
            }
        }
        if fileCount > 500 {
            hardFails.append(.init(code: "too_many_files", message: "Bundle has more than 500 files."))
        }
        if totalBytes > 50 * 1024 * 1024 {
            hardFails.append(.init(code: "total_too_large", message: "Bundle total size exceeds 50MB."))
        }
        return SkillValidationResult(ok: hardFails.isEmpty, hardFails: hardFails, warnings: warnings, fileCount: fileCount, totalBytes: totalBytes)
    }

    func setEnabled(_ skill: SkillRecord, enabled: Bool) {
        guard let index = skills.firstIndex(where: { $0.id == skill.id }) else { return }
        skills[index].enabled = enabled
    }

    private func listSkills(in root: URL, scope: SkillScope) -> [SkillRecord] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.compactMap { readSkillMeta(skillDir: $0, scope: scope) }
    }

    private func readSkillMeta(skillDir: URL, scope: SkillScope) -> SkillRecord? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: skillDir.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        guard Self.isSafeSlug(skillDir.lastPathComponent) else { return nil }
        let skillFile = skillDir.appendingPathComponent("SKILL.md")
        guard let content = try? String(contentsOf: skillFile, encoding: .utf8) else { return nil }
        let fm = Self.frontmatter(from: content)
        let values = try? skillFile.resourceValues(forKeys: [.contentModificationDateKey])
        return SkillRecord(
            id: UUID(),
            slug: skillDir.lastPathComponent,
            name: fm["name"]?.isEmpty == false ? fm["name"]! : skillDir.lastPathComponent,
            description: fm["description"] ?? "",
            version: fm["version"],
            skillDir: skillDir.path,
            skillFile: skillFile.path,
            scope: scope,
            mtime: values?.contentModificationDate,
            enabled: true
        )
    }

    private func root(for scope: SkillScope, projectPath: String?) throws -> URL {
        switch scope {
        case .user:
            return Self.userSkillsRoot()
        case .project:
            guard let projectPath, !projectPath.isEmpty else {
                throw NSError(domain: "SkillsService", code: 400, userInfo: [NSLocalizedDescriptionKey: "Project scope requires a real project."])
            }
            return Self.projectSkillsRoot(projectPath)
        }
    }

    static func userSkillsRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".g9claw", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
    }

    static func projectSkillsRoot(_ projectPath: String) -> URL {
        URL(fileURLWithPath: projectPath)
            .appendingPathComponent(".g9claw", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
    }

    static func isSafeSlug(_ slug: String) -> Bool {
        let pattern = #"^[a-zA-Z0-9][a-zA-Z0-9._-]{0,99}$"#
        return slug.range(of: pattern, options: .regularExpression) != nil && !slug.contains("..")
    }

    static func frontmatter(from content: String) -> [String: String] {
        guard content.hasPrefix("---") else { return [:] }
        let parts = content.components(separatedBy: "---")
        guard parts.count >= 3 else { return [:] }
        var result: [String: String] = [:]
        for line in parts[1].split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            result[key] = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return result
    }

    private func safeArchiveFilename(_ filename: String?, fallbackSlug: String) -> String {
        guard let filename = filename?.nilIfBlank else { return "\(fallbackSlug).zip" }
        let candidate = URL(fileURLWithPath: filename).lastPathComponent
        guard candidate.lowercased().hasSuffix(".zip"), !candidate.contains("/") else {
            return "\(fallbackSlug).zip"
        }
        return candidate
    }

    private func validateZipArchive(_ archiveURL: URL) throws {
        let run = try runSystemProcess(
            executable: "/usr/bin/unzip",
            args: ["-Z1", archiveURL.path],
            timeout: 20
        )
        let entries = run.stdout
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !entries.isEmpty else {
            throw NSError(domain: "SkillsService", code: 422, userInfo: [NSLocalizedDescriptionKey: "Skill archive is empty."])
        }
        for entry in entries {
            guard Self.isSafeArchiveEntry(entry) else {
                throw NSError(
                    domain: "SkillsService",
                    code: 422,
                    userInfo: [NSLocalizedDescriptionKey: "Skill archive contains an unsafe path: \(entry)"]
                )
            }
        }
    }

    private func extractZipArchive(_ archiveURL: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        _ = try runSystemProcess(
            executable: "/usr/bin/ditto",
            args: ["-x", "-k", archiveURL.path, destination.path],
            timeout: 60
        )
    }

    private func extractedSkillRoot(in extractRoot: URL) throws -> URL {
        if validate(source: extractRoot).ok {
            return extractRoot
        }
        var candidates: [URL] = []
        if let enumerator = FileManager.default.enumerator(
            at: extractRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator where url.lastPathComponent == "SKILL.md" {
                let parent = url.deletingLastPathComponent()
                if parent != extractRoot,
                   !candidates.contains(where: { $0.standardizedFileURL == parent.standardizedFileURL }) {
                    candidates.append(parent)
                }
            }
        }
        let validCandidates = candidates.filter { validate(source: $0).ok }
        if validCandidates.count == 1, let candidate = validCandidates.first {
            return candidate
        }
        if validCandidates.isEmpty {
            throw NSError(domain: "SkillsService", code: 422, userInfo: [NSLocalizedDescriptionKey: "Skill archive does not contain a valid SKILL.md."])
        }
        throw NSError(domain: "SkillsService", code: 422, userInfo: [NSLocalizedDescriptionKey: "Skill archive contains multiple skill roots."])
    }

    private func validateExtractedSkillTree(_ root: URL) throws {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
            if values?.isSymbolicLink == true {
                throw NSError(domain: "SkillsService", code: 422, userInfo: [NSLocalizedDescriptionKey: "Skill archive contains a symbolic link: \(url.lastPathComponent)"])
            }
        }
    }

    static func isSafeArchiveEntry(_ entry: String) -> Bool {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.hasPrefix("~"),
              !trimmed.contains("\\"),
              !trimmed.contains("\0"),
              !trimmed.contains("//") else { return false }
        let components = trimmed
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !components.isEmpty else { return false }
        return !components.contains("..")
    }

    private func runSystemProcess(executable: String, args: [String], timeout: TimeInterval) throws -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw NSError(
                domain: "SkillsService",
                code: 503,
                userInfo: [NSLocalizedDescriptionKey: "Unable to run required macOS archive tool."]
            )
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            throw NSError(domain: "SkillsService", code: 408, userInfo: [NSLocalizedDescriptionKey: "Archive operation timed out."])
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw NSError(
                domain: "SkillsService",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: stderr.nilIfBlank ?? stdout.nilIfBlank ?? "Archive operation failed."]
            )
        }
        return (stdout, stderr, process.terminationStatus)
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension Optional where Wrapped == String {
    var nilIfBlank: String? {
        guard let value = self else { return nil }
        return value.nilIfBlank
    }
}

final class RoutingService {
    private var tokenRecords: [String: RoutingDashboardSession] = [:]
    private let recordsURL: URL?

    init() {
        if let paths = try? AppPaths.current() {
            let root = paths.applicationSupport.appendingPathComponent("Routing", isDirectory: true)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            recordsURL = root.appendingPathComponent("routing-records.json")
        } else {
            recordsURL = nil
        }
        load()
    }

    static func classifyTier(prompt: String, runMode: ChatRunMode) -> String {
        if runMode == .plan { return "REASONING" }
        let normalized = prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let words = normalized.split { $0.isWhitespace || $0.isNewline }
        if words.count < 20,
           !containsAny(normalized, ["修改", "优化", "实现", "生成", "创建", "网页", "网站", "代码", "edit", "fix", "build", "implement", "website", "code"]) {
            return "SIMPLE"
        }
        if containsAny(normalized, ["架构", "重构", "全量", "复杂", "深入", "推理", "research", "architecture", "refactor", "reasoning"]) {
            return "REASONING"
        }
        if containsAny(normalized, ["修改", "优化", "实现", "生成", "创建", "网页", "网站", "多文件", "edit", "fix", "build", "implement", "website", "multi-file"]) {
            return "COMPLEX"
        }
        return "MEDIUM"
    }

    private static func containsAny(_ value: String, _ needles: [String]) -> Bool {
        needles.contains { value.contains($0) }
    }

    func recordRequest(
        sessionID: String,
        title: String,
        projectName: String,
        model: String,
        route: String,
        tier: String,
        query: String? = nil
    ) {
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "unknown" : model
        let now = Date()
        var record = tokenRecords[sessionID] ?? makeSession(id: sessionID, title: title, projectName: projectName, at: now)
        record.title = title
        record.projectName = projectName
        record.lastActiveAt = now
        let tierKey = tier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "COMPLEX" : tier
        let routeKey = route.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "default" : route
        let requestBucket = RoutingBucket(count: 1, requestCount: 1)
        record.total = mergeRequest(bucket: record.total, with: requestBucket)
        record.byTier[tierKey] = mergeRequest(bucket: record.byTier[tierKey], with: requestBucket)
        record.byModel[normalizedModel] = mergeRequest(bucket: record.byModel[normalizedModel], with: requestBucket)
        record.byRole["main"] = mergeRequest(bucket: record.byRole["main"], with: requestBucket)
        record.byScenario[routeKey] = mergeRequest(bucket: record.byScenario[routeKey], with: requestBucket)
        let entry = RoutingRequestLogEntry(
            ts: now,
            role: "main",
            tier: tierKey,
            model: normalizedModel,
            query: sanitizedQuery(query ?? title),
            scenario: routeKey,
            route: routeKey
        )
        record.requestEntries.append(entry)
        record.requestEntries = Array(record.requestEntries.suffix(120))
        record.requestLog.append("\(DateFormatter.routingTime.string(from: now)) \(routeKey) -> \(normalizedModel) routed as \(tierKey)")
        record.requestLog = Array(record.requestLog.suffix(100))
        tokenRecords[sessionID] = record
        persist()
    }

    func recordTokens(
        sessionID: String,
        title: String,
        projectName: String,
        model: String,
        tier: String,
        totalTokens: Int,
        contextWindow: Int
    ) {
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "unknown" : model
        let cost = estimatedCost(model: normalizedModel, tokens: totalTokens)
        let baselineCost = baselineCost(tokens: totalTokens)
        let savedCost = max(0, baselineCost - cost)
        let now = Date()
        let bucket = RoutingBucket(
            inputTokens: totalTokens,
            totalTokens: totalTokens,
            estimatedCost: cost,
            baselineCost: baselineCost,
            savedCost: savedCost
        )
        var record = tokenRecords[sessionID] ?? makeSession(id: sessionID, title: title, projectName: projectName, at: now)
        record.title = title
        record.projectName = projectName
        record.lastActiveAt = now
        record.totalTokens = max(record.totalTokens, totalTokens)
        record.estimatedCost = max(record.estimatedCost, cost)
        record.savedCost = max(record.savedCost, savedCost)
        let tierKey = tier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "COMPLEX" : tier
        let scenarioKey = latestScenario(in: record) ?? "usage"
        record.total = mergeUsage(bucket: record.total, with: bucket)
        record.byTier[tierKey] = mergeUsage(bucket: record.byTier[tierKey], with: bucket)
        record.byModel[normalizedModel] = mergeUsage(bucket: record.byModel[normalizedModel], with: bucket)
        record.byRole["main"] = mergeUsage(bucket: record.byRole["main"], with: bucket)
        record.byScenario[scenarioKey] = mergeUsage(bucket: record.byScenario[scenarioKey], with: bucket)
        if let index = record.requestEntries.lastIndex(where: { $0.role == "main" && ($0.tier ?? tierKey) == tierKey }) {
            record.requestEntries[index].tokens = max(record.requestEntries[index].tokens, totalTokens)
            record.requestEntries[index].cost = max(record.requestEntries[index].cost, cost)
            record.requestEntries[index].baselineCost = max(record.requestEntries[index].baselineCost ?? 0, baselineCost)
            record.requestEntries[index].savedCost = max(record.requestEntries[index].savedCost ?? 0, savedCost)
            record.requestEntries[index].model = normalizedModel
        } else {
            record.requestEntries.append(RoutingRequestLogEntry(
                ts: now,
                role: "main",
                tier: tierKey,
                model: normalizedModel,
                tokens: totalTokens,
                cost: cost,
                baselineCost: baselineCost,
                savedCost: savedCost,
                scenario: scenarioKey
            ))
        }
        record.requestEntries = Array(record.requestEntries.suffix(120))
        record.requestLog.append("\(DateFormatter.routingTime.string(from: now)) \(normalizedModel) usage · \(tierKey) · \(totalTokens)/\(contextWindow) tokens")
        record.requestLog = Array(record.requestLog.suffix(100))
        tokenRecords[sessionID] = record
        persist()
    }

    func recordSkillInvocation(
        sessionID: String,
        title: String,
        projectName: String,
        skill: String
    ) {
        let now = Date()
        var record = tokenRecords[sessionID] ?? makeSession(id: sessionID, title: title, projectName: projectName, at: now)
        record.title = title
        record.projectName = projectName
        record.lastActiveAt = now
        let normalized = skill.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "unknown" : skill
        let requestBucket = RoutingBucket(count: 1, requestCount: 1)
        record.total = mergeRequest(bucket: record.total, with: requestBucket)
        record.byModel["skill:\(normalized)"] = merge(
            bucket: record.byModel["skill:\(normalized)"],
            with: requestBucket
        )
        record.byScenario["skill"] = mergeRequest(bucket: record.byScenario["skill"], with: requestBucket)
        record.byRole["main"] = mergeRequest(bucket: record.byRole["main"], with: requestBucket)
        record.requestEntries.append(RoutingRequestLogEntry(
            ts: now,
            role: "main",
            model: "skill:\(normalized)",
            query: "Skill invoked",
            scenario: "skill",
            skill: normalized
        ))
        record.requestEntries = Array(record.requestEntries.suffix(120))
        record.requestLog.append("\(DateFormatter.routingTime.string(from: now)) skill invoked · \(normalized)")
        record.requestLog = Array(record.requestLog.suffix(100))
        tokenRecords[sessionID] = record
        persist()
    }

    func recordSubagentInvocation(
        sessionID: String,
        title: String,
        projectName: String,
        model: String,
        tier: String,
        inputJSON: String
    ) {
        let now = Date()
        var record = tokenRecords[sessionID] ?? makeSession(id: sessionID, title: title, projectName: projectName, at: now)
        record.title = title
        record.projectName = projectName
        record.lastActiveAt = now
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "unknown" : model
        let tierKey = tier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "COMPLEX" : tier
        let requestBucket = RoutingBucket(count: 1, requestCount: 1)
        record.total = mergeRequest(bucket: record.total, with: requestBucket)
        record.byTier[tierKey] = mergeRequest(bucket: record.byTier[tierKey], with: requestBucket)
        record.byModel[normalizedModel] = mergeRequest(bucket: record.byModel[normalizedModel], with: requestBucket)
        record.byScenario["subagent"] = mergeRequest(bucket: record.byScenario["subagent"], with: requestBucket)
        record.byRole["sub"] = mergeRequest(bucket: record.byRole["sub"], with: requestBucket)
        let query = Self.subagentQuery(from: inputJSON)
        record.requestEntries.append(RoutingRequestLogEntry(
            ts: now,
            role: "sub",
            tier: tierKey,
            model: normalizedModel,
            query: query,
            scenario: "subagent",
            route: "background"
        ))
        record.requestEntries = Array(record.requestEntries.suffix(120))
        record.requestLog.append("\(DateFormatter.routingTime.string(from: now)) subagent -> \(normalizedModel) routed as \(tierKey)")
        record.requestLog = Array(record.requestLog.suffix(100))
        tokenRecords[sessionID] = record
        persist()
    }

    func dashboard(projects: [WorkspaceProject], projectFilter: String?) -> RoutingDashboardSnapshot {
        let filtered = projectFilter == nil ? projects : projects.filter { $0.name == projectFilter }
        let sessions = filtered.flatMap { project in
            project.allSessions.map { session in
                if var recorded = tokenRecords[session.id] {
                    recorded.title = session.displayTitle
                    recorded.projectName = project.displayName
                    recorded.lastActiveAt = max(recorded.lastActiveAt, session.activityDate)
                    return recorded
                }
                return RoutingDashboardSession(
                    id: session.id,
                    title: session.displayTitle,
                    projectName: project.displayName,
                    lastActiveAt: session.activityDate,
                    totalTokens: 0,
                    estimatedCost: 0,
                    savedCost: 0,
                    byTier: [:],
                    byModel: [:],
                    requestLog: []
                )
            }
        }
        let knownIDs = Set(sessions.map(\.id))
        let orphanRecords = tokenRecords.values.filter { record in
            !knownIDs.contains(record.id) && (projectFilter == nil || record.projectName == projectFilter)
        }
        let allSessions = (sessions + orphanRecords).sorted { $0.lastActiveAt > $1.lastActiveAt }
        return RoutingDashboardSnapshot(
            totalProjects: filtered.count,
            totalSessions: allSessions.count,
            routedSessions: allSessions.filter { !$0.byModel.isEmpty || !$0.byTier.isEmpty }.count,
            totalTokens: allSessions.reduce(0) { $0 + $1.totalTokens },
            estimatedCost: allSessions.reduce(0) { $0 + $1.estimatedCost },
            savedCost: allSessions.reduce(0) { $0 + $1.savedCost },
            recentSessions: Array(allSessions.prefix(40))
        )
    }

    private func estimatedCost(model: String, tokens: Int) -> Double {
        let perMillion: Double
        if model.contains("qwen3.6-27b") {
            perMillion = 0.4
        } else if model.contains("qwen3.6-35b") {
            perMillion = 0.2
        } else {
            perMillion = 0.8
        }
        return (Double(tokens) / 1_000_000) * perMillion
    }

    private func baselineCost(tokens: Int) -> Double {
        (Double(tokens) / 1_000_000) * 0.8
    }

    private func merge(bucket existing: RoutingBucket?, with incoming: RoutingBucket) -> RoutingBucket {
        mergeRequest(bucket: existing, with: incoming)
    }

    private func mergeRequest(bucket existing: RoutingBucket?, with incoming: RoutingBucket) -> RoutingBucket {
        let current = existing ?? RoutingBucket()
        return RoutingBucket(
            count: current.count + incoming.count,
            inputTokens: max(current.inputTokens, incoming.inputTokens),
            outputTokens: max(current.outputTokens, incoming.outputTokens),
            cacheReadTokens: max(current.cacheReadTokens, incoming.cacheReadTokens),
            totalTokens: max(current.totalTokens, incoming.totalTokens),
            requestCount: current.requestCount + max(incoming.requestCount, incoming.count),
            estimatedCost: max(current.estimatedCost, incoming.estimatedCost),
            baselineCost: max(current.baselineCost, incoming.baselineCost),
            savedCost: max(current.savedCost, incoming.savedCost)
        )
    }

    private func mergeUsage(bucket existing: RoutingBucket?, with incoming: RoutingBucket) -> RoutingBucket {
        let current = existing ?? RoutingBucket()
        return RoutingBucket(
            count: current.count,
            inputTokens: max(current.inputTokens, incoming.inputTokens),
            outputTokens: max(current.outputTokens, incoming.outputTokens),
            cacheReadTokens: max(current.cacheReadTokens, incoming.cacheReadTokens),
            totalTokens: max(current.totalTokens, incoming.totalTokens),
            requestCount: current.requestCount,
            estimatedCost: max(current.estimatedCost, incoming.estimatedCost),
            baselineCost: max(current.baselineCost, incoming.baselineCost),
            savedCost: max(current.savedCost, incoming.savedCost)
        )
    }

    private func makeSession(id: String, title: String, projectName: String, at date: Date) -> RoutingDashboardSession {
        RoutingDashboardSession(
            id: id,
            title: title,
            projectName: projectName,
            lastActiveAt: date,
            totalTokens: 0,
            estimatedCost: 0,
            savedCost: 0,
            byTier: [:],
            byModel: [:],
            requestLog: []
        )
    }

    private func latestScenario(in record: RoutingDashboardSession) -> String? {
        record.requestEntries.last(where: { $0.scenario?.isEmpty == false })?.scenario
    }

    private func sanitizedQuery(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 180 else { return trimmed }
        return String(trimmed.prefix(180)) + "…"
    }

    private static func subagentQuery(from inputJSON: String) -> String {
        guard let data = inputJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "Subagent"
        }
        let preferred = [
            object["description"] as? String,
            object["prompt"] as? String,
            object["context"] as? String,
        ]
        let value = preferred.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? "Subagent"
        guard value.count > 180 else { return value }
        return String(value.prefix(180)) + "…"
    }

    private func load() {
        guard let recordsURL,
              let data = try? Data(contentsOf: recordsURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([String: RoutingDashboardSession].self, from: data) {
            tokenRecords = decoded.mapValues { migrateLegacyEntries($0) }
        }
    }

    private func persist() {
        guard let recordsURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(tokenRecords) else { return }
        try? data.write(to: recordsURL, options: .atomic)
    }

    private func migrateLegacyEntries(_ record: RoutingDashboardSession) -> RoutingDashboardSession {
        guard record.requestEntries.isEmpty, !record.requestLog.isEmpty else { return record }
        var migrated = record
        var entries: [RoutingRequestLogEntry] = []
        for line in record.requestLog {
            let body = String(line.dropFirst(min(line.count, 9))).trimmingCharacters(in: .whitespaces)
            if body.contains(" routed as ") {
                let parts = body.components(separatedBy: " routed as ")
                let routeAndModel = parts.first ?? body
                let tier = parts.dropFirst().first?.trimmingCharacters(in: .whitespacesAndNewlines)
                let routeParts = routeAndModel.components(separatedBy: " -> ")
                let route = routeParts.first?.trimmingCharacters(in: .whitespacesAndNewlines)
                let model = routeParts.dropFirst().first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
                entries.append(RoutingRequestLogEntry(
                    ts: record.lastActiveAt,
                    role: "main",
                    tier: tier?.isEmpty == false ? tier : nil,
                    model: model,
                    query: sanitizedQuery(record.title),
                    scenario: route?.isEmpty == false ? route : nil,
                    route: route?.isEmpty == false ? route : nil
                ))
            } else if body.contains(" usage · ") {
                let parts = body.components(separatedBy: " · ")
                let model = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
                let tier = parts.dropFirst().first?.trimmingCharacters(in: .whitespacesAndNewlines)
                let tokenText = parts.dropFirst(2).first ?? ""
                let tokens = Int(tokenText.components(separatedBy: "/").first?.filter(\.isNumber) ?? "") ?? 0
                let cost = estimatedCost(model: model, tokens: tokens)
                let baseline = baselineCost(tokens: tokens)
                if let index = entries.indices.last {
                    entries[index].model = model
                    entries[index].tier = entries[index].tier ?? tier
                    entries[index].tokens = max(entries[index].tokens, tokens)
                    entries[index].cost = max(entries[index].cost, cost)
                    entries[index].baselineCost = max(entries[index].baselineCost ?? 0, baseline)
                    entries[index].savedCost = max(entries[index].savedCost ?? 0, max(0, baseline - cost))
                } else {
                    entries.append(RoutingRequestLogEntry(
                        ts: record.lastActiveAt,
                        role: "main",
                        tier: tier,
                        model: model,
                        tokens: tokens,
                        cost: cost,
                        baselineCost: baseline,
                        savedCost: max(0, baseline - cost),
                        scenario: "usage"
                    ))
                }
            } else if body.contains("skill invoked ·") {
                let skill = body.components(separatedBy: "skill invoked ·").dropFirst().first?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
                entries.append(RoutingRequestLogEntry(
                    ts: record.lastActiveAt,
                    role: "main",
                    model: "skill:\(skill)",
                    query: "Skill invoked",
                    scenario: "skill",
                    skill: skill
                ))
            }
        }
        migrated.requestEntries = entries
        return migrated
    }
}

private extension DateFormatter {
    static let routingTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

final class AlwaysOnService {
    private let defaultRunLogTailBytes = 60_000
    private let maxRunLogTailBytes = 512_000
    private let outputLogMaxCharacters = 60_000
    private let discoveryContextLookbackDays = 7
    private let discoveryContextMaxItems = 20

    private struct CronJobStore {
        var url: URL
        var collectionKey: String?
        var durableDefault: Bool?
        var rootObject: Any
        var rawJobs: [[String: Any]]
    }

    private struct RunHistoryEvent {
        var runId: String
        var kind: String
        var sourceId: String
        var title: String
        var status: AlwaysOnStatus
        var timestamp: Date
        var startedAt: Date?
        var finishedAt: Date?
        var sessionId: String?
        var parentSessionId: String?
        var relativeTranscriptPath: String?
        var transcriptKey: String?
        var output: String?
        var error: String?
        var metadata: [String: String]
    }

    private struct RunHistoryRecord {
        var runId: String
        var kind: String
        var sourceId: String
        var title: String
        var status: AlwaysOnStatus
        var createdAt: Date
        var updatedAt: Date
        var startedAt: Date
        var finishedAt: Date?
        var sessionId: String?
        var parentSessionId: String?
        var relativeTranscriptPath: String?
        var transcriptKey: String?
        var metadata: [String: String]
        var outputLog: String
        var error: String?
    }

    func plans(projectRoot: String) -> [AlwaysOnPlan] {
        guard let indexURL = existingAlwaysOnFile(projectRoot, "discovery-plans.json") else { return [] }
        guard
            let data = try? Data(contentsOf: indexURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawPlans = json["plans"] as? [[String: Any]]
        else { return [] }
        return rawPlans.compactMap { raw in
            let id = string(raw["id"], fallback: UUID().uuidString)
            let relativePlanPath = string(raw["planFilePath"], fallback: ".g9claw/always-on/plans/\(id).md")
            let content = (try? String(contentsOfFile: URL(fileURLWithPath: projectRoot).appendingPathComponent(relativePlanPath).path, encoding: .utf8)) ?? ""
            return AlwaysOnPlan(
                id: id,
                title: string(raw["title"], fallback: "Untitled discovery plan"),
                summary: string(raw["summary"]),
                rationale: string(raw["rationale"]),
                content: content,
                status: AlwaysOnStatus(rawValue: string(raw["status"], fallback: "ready")) ?? .unknown,
                approvalMode: string(raw["approvalMode"], fallback: "manual"),
                planFilePath: relativePlanPath,
                contextRefs: stringArrayMap(raw["contextRefs"]),
                createdAt: date(raw["createdAt"]) ?? Date(),
                updatedAt: date(raw["updatedAt"]) ?? Date(),
                executionSessionId: optionalString(raw["executionSessionId"]),
                executionStatus: AlwaysOnStatus(rawValue: string(raw["executionStatus"]))
            )
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    func discoveryContext(
        projectName: String,
        displayName: String,
        projectRoot: String,
        plans: [AlwaysOnPlan],
        cronJobs: [AlwaysOnCronJob],
        sessions: [ProjectSession],
        memoryRecords: [MemoryRecord] = [],
        now: Date = Date()
    ) -> AlwaysOnDiscoveryContext {
        let cutoff = now.addingTimeInterval(TimeInterval(-discoveryContextLookbackDays * 24 * 60 * 60))
        let recentSessions = sessions
            .filter { $0.activityDate >= cutoff }
            .sorted { $0.activityDate > $1.activityDate }
            .prefix(discoveryContextMaxItems)

        return AlwaysOnDiscoveryContext(
            generatedAt: isoString(now),
            lookbackDays: discoveryContextLookbackDays,
            workspace: AlwaysOnDiscoveryContext.Workspace(
                projectName: projectName,
                projectRoot: projectRoot,
                signals: workspaceSignals(projectRoot: projectRoot)
            ),
            memory: memoryRecords
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(discoveryContextMaxItems)
                .map {
                    AlwaysOnDiscoveryContext.MemoryItem(
                        path: $0.relativePath,
                        modifiedAt: isoString($0.updatedAt),
                        summary: $0.summary
                    )
                },
            existingPlans: plans
                .filter { $0.status != .superseded }
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(discoveryContextMaxItems)
                .map {
                    AlwaysOnDiscoveryContext.PlanItem(
                        id: $0.id,
                        title: $0.title,
                        status: $0.status.rawValue,
                        approvalMode: $0.approvalMode,
                        updatedAt: isoString($0.updatedAt),
                        summary: $0.summary
                    )
                },
            cronJobs: cronJobs
                .prefix(discoveryContextMaxItems)
                .map {
                    AlwaysOnDiscoveryContext.CronItem(
                        id: $0.id,
                        status: $0.status.rawValue,
                        cron: $0.cron,
                        recurring: $0.recurring,
                        manualOnly: $0.manualOnly,
                        prompt: $0.prompt,
                        latestRunSummary: $0.latestRun?.summary
                    )
                },
            recentChats: recentSessions.map {
                AlwaysOnDiscoveryContext.ChatItem(
                    id: $0.id,
                    summary: $0.summary.isEmpty ? $0.displayTitle : $0.summary,
                    lastActivity: isoString($0.activityDate),
                    lastUserMessage: nil,
                    lastAssistantMessage: nil
                )
            }
        )
    }

    func discoveryPrompt(
        projectName: String,
        displayName: String,
        projectRoot: String,
        context: AlwaysOnDiscoveryContext,
        language: String?
    ) -> String {
        let normalizedLanguage = language == "zh-CN" ? "zh-CN" : "en"
        let contextJSON = discoveryContextJSON(context)
        let projectStorePath = g9clawProjectStorePath(projectName: projectName, projectRoot: projectRoot)
        if normalizedLanguage == "zh-CN" {
            return [
                "Always-On 主动发现规划，项目为“\(displayName)”。",
                "",
                "你的任务只限于发现和规划。",
                "检查提供的上下文，判断是否存在值得后续跟进的任务，并最多保存 3 个结构化 discovery plans。",
                "",
                "要求：",
                "1. 检查当前工作区 `\(projectRoot)`。",
                "2. 如有需要，将项目存储目录 `\(projectStorePath)` 作为辅助上下文。",
                "3. 阅读下方结构化 discovery context，不要自行虚构上下文窗口。",
                "4. 如果没有值得跟进的工作，说明原因并停止，不要保存任何计划。",
                "5. 如果存在值得跟进的工作，使用 `AlwaysOnDiscoveryPlan` 最多保存 3 个计划。",
                "6. 每个保存的计划必须严格包含这些 Markdown 小节：",
                "   - `## Context`",
                "   - `## Signals Reviewed`",
                "   - `## Proposed Work`",
                "   - `## Execution Steps`",
                "   - `## Verification`",
                "   - `## Approval And Execution`",
                "7. 除非工作明显安全且适合自动执行，否则使用 `approvalMode: \"manual\"`。",
                "8. 不要调用 `CronCreate`，不要现在执行这些工作，也不要启动后台任务。",
                "9. 语言：如果结构化上下文或计划 `contextRefs.recentChats` 中包含近期聊天记录，推断这些近期聊天记录的主要语言。最终回复以及每个保存的计划 Markdown 正文都优先使用该语言。如果它与 Web UI 语言不同，以近期聊天语言为准。如果无法判断近期聊天语言，则使用当前提示词语言。",
                "10. 在最终回复中，总结你检查了什么，以及创建或更新了哪些 discovery plan ID。",
                "",
                "结构化 discovery context：",
                "```json",
                contextJSON,
                "```",
            ].joined(separator: "\n")
        }

        return [
            "Always-On discovery planning for project \"\(displayName)\".",
            "",
            "Your job is discovery only.",
            "Inspect the provided context, decide whether there are worthwhile follow-up tasks, and persist up to 3 structured discovery plans.",
            "",
            "Requirements:",
            "1. Inspect the current workspace at `\(projectRoot)`.",
            "2. Use the project store at `\(projectStorePath)` as supporting context if needed.",
            "3. Read the structured discovery context below instead of inventing your own context window.",
            "4. If there is no worthwhile follow-up work, explain why and stop without saving any plans.",
            "5. If there is worthwhile work, use `AlwaysOnDiscoveryPlan` to persist up to 3 plans.",
            "6. Every saved plan must include these markdown sections exactly:",
            "   - `## Context`",
            "   - `## Signals Reviewed`",
            "   - `## Proposed Work`",
            "   - `## Execution Steps`",
            "   - `## Verification`",
            "   - `## Approval And Execution`",
            "7. Use `approvalMode: \"manual\"` unless the work is clearly safe and suitable for auto-execution.",
            "8. Do not call `CronCreate`, do not execute the work now, and do not start background tasks.",
            "9. Language: if the structured context or plan `contextRefs.recentChats` includes recent chat records, infer the primary language of those recent chats. Use that language for your final reply and for every saved plan markdown body. If it differs from the Web UI language, recent chats win. If no recent chat language is discernible, use this prompt language.",
            "10. In your final reply, summarize what you reviewed and which discovery plan IDs were created or updated.",
            "",
            "Structured discovery context:",
            "```json",
            contextJSON,
            "```",
        ].joined(separator: "\n")
    }

    func runHistory(projectRoot: String) -> [AlwaysOnRunHistory] {
        runHistoryRecords(projectRoot: projectRoot, includeUnknown: false)
    }

    func runHistoryDetail(projectRoot: String, runID: String) -> AlwaysOnRunHistory? {
        runHistoryRecords(projectRoot: projectRoot, includeUnknown: true).first { $0.id == runID }
    }

    private func runHistoryRecords(projectRoot: String, includeUnknown: Bool) -> [AlwaysOnRunHistory] {
        readRunHistoryRecords(projectRoot: projectRoot)
            .filter { includeUnknown || $0.status != .unknown }
            .map { history in
                let session = recoveredSessionInfo(for: history)
                let log = runLog(projectRoot: projectRoot, runID: history.runId)
                let outputLog = !log.content.isEmpty
                    ? log.content
                    : [history.outputLog, history.error.map { "Error: \($0)" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
                var metadata = history.metadata
                metadata["runId"] = history.runId
                metadata["sourceId"] = history.sourceId
                metadata["status"] = history.status.rawValue
                metadata["startedAt"] = isoString(history.startedAt)
                if let finishedAt = history.finishedAt {
                    metadata["finishedAt"] = isoString(finishedAt)
                }
                if let sessionId = session.sessionId {
                    metadata["sessionId"] = sessionId
                }
                if let parentSessionId = session.parentSessionId {
                    metadata["parentSessionId"] = parentSessionId
                }
                if let relativeTranscriptPath = session.relativeTranscriptPath {
                    metadata["relativeTranscriptPath"] = relativeTranscriptPath
                }
                if let transcriptKey = session.transcriptKey {
                    metadata["transcriptKey"] = transcriptKey
                }
                metadata["logSource"] = log.source.rawValue
                metadata["logSize"] = String(log.size)
                metadata["logTruncated"] = String(log.truncated)
                if let updatedAt = log.updatedAt {
                    metadata["logUpdatedAt"] = isoString(updatedAt)
                }
                return AlwaysOnRunHistory(
                    id: history.runId,
                    title: history.title,
                    kind: history.kind,
                    status: history.status,
                    startedAt: history.startedAt,
                    sourceId: history.sourceId,
                    outputLog: outputLog,
                    sessionId: session.sessionId,
                    parentSessionId: session.parentSessionId,
                    relativeTranscriptPath: session.relativeTranscriptPath,
                    finishedAt: history.finishedAt,
                    error: history.error,
                    metadata: metadata,
                    transcriptKey: session.transcriptKey ?? history.transcriptKey
                )
            }
            .sorted {
                let left = $0.startedAt
                let right = $1.startedAt
                return left > right
            }
    }

    private func readRunHistoryRecords(projectRoot: String) -> [RunHistoryRecord] {
        let rawLines = alwaysOnRoots(projectRoot)
            .map { $0.appendingPathComponent("run-history.jsonl") }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .flatMap { $0.split(separator: "\n", omittingEmptySubsequences: true) }
        guard !rawLines.isEmpty else { return [] }

        var recordsByID: [String: RunHistoryRecord] = [:]
        for line in rawLines {
            guard let event = runHistoryEvent(from: String(line)) else { continue }
            if var existing = recordsByID[event.runId] {
                mergeRunHistoryEvent(event, into: &existing)
                recordsByID[event.runId] = existing
            } else {
                recordsByID[event.runId] = runHistoryRecord(from: event)
            }
        }

        return recordsByID.values.sorted {
            let left = max($0.startedAt, $0.updatedAt)
            let right = max($1.startedAt, $1.updatedAt)
            return left > right
        }
    }

    private func runHistoryEvent(from line: String) -> RunHistoryEvent? {
        guard
            let data = line.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let runId = string(json["runId"], fallback: string(json["id"]))
        let kind = string(json["kind"])
        let sourceId = string(json["sourceId"])
        let statusRaw = string(json["status"])
        guard !runId.isEmpty, kind == "plan" || kind == "cron", !sourceId.isEmpty,
              let status = AlwaysOnStatus(rawValue: statusRaw) else {
            return nil
        }
        let timestamp = date(json["timestamp"]) ?? Date()
        let metadata = metadataStrings(json["metadata"])
        let session = json["session"] as? [String: Any]
        let output = optionalString(json["output"]) ?? optionalString(json["outputLog"])
        return RunHistoryEvent(
            runId: runId,
            kind: kind,
            sourceId: sourceId,
            title: string(json["title"], fallback: sourceId),
            status: status,
            timestamp: timestamp,
            startedAt: date(json["startedAt"]),
            finishedAt: date(json["finishedAt"]),
            sessionId: optionalString(json["sessionId"]) ?? optionalString(session?["sessionId"]),
            parentSessionId: optionalString(json["parentSessionId"]) ?? optionalString(session?["parentSessionId"]),
            relativeTranscriptPath: optionalString(json["relativeTranscriptPath"]) ?? optionalString(session?["relativeTranscriptPath"]),
            transcriptKey: optionalString(json["transcriptKey"]) ?? metadata["transcriptKey"],
            output: output,
            error: optionalString(json["error"]),
            metadata: metadata
        )
    }

    private func runHistoryRecord(from event: RunHistoryEvent) -> RunHistoryRecord {
        var record = RunHistoryRecord(
            runId: event.runId,
            kind: event.kind,
            sourceId: event.sourceId,
            title: event.title,
            status: event.status,
            createdAt: event.timestamp,
            updatedAt: event.timestamp,
            startedAt: event.startedAt ?? event.timestamp,
            finishedAt: event.finishedAt,
            sessionId: event.sessionId,
            parentSessionId: event.parentSessionId,
            relativeTranscriptPath: event.relativeTranscriptPath,
            transcriptKey: event.transcriptKey,
            metadata: [:],
            outputLog: "",
            error: nil
        )
        mergeRunHistoryEvent(event, into: &record)
        return record
    }

    private func mergeRunHistoryEvent(_ event: RunHistoryEvent, into record: inout RunHistoryRecord) {
        record.title = event.title.isEmpty ? record.title : event.title
        record.status = event.status
        record.updatedAt = event.timestamp
        record.startedAt = event.startedAt ?? record.startedAt
        record.finishedAt = event.finishedAt ?? record.finishedAt
        record.sessionId = event.sessionId ?? record.sessionId
        record.parentSessionId = event.parentSessionId ?? record.parentSessionId
        record.relativeTranscriptPath = event.relativeTranscriptPath ?? record.relativeTranscriptPath
        record.transcriptKey = event.transcriptKey ?? record.transcriptKey
        record.metadata.merge(event.metadata) { _, next in next }

        let eventOutput = [event.output, event.error.map { "Error: \($0)" }]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        if !eventOutput.isEmpty {
            record.outputLog = trimmedOutputLog([record.outputLog, eventOutput].filter { !$0.isEmpty }.joined(separator: "\n\n"))
        }
        if let error = event.error {
            record.error = error
        }
    }

    private func trimmedOutputLog(_ value: String) -> String {
        guard value.count > outputLogMaxCharacters else { return value }
        let start = value.index(value.endIndex, offsetBy: -outputLogMaxCharacters)
        return String(value[start...])
    }

    private func recoveredSessionInfo(for record: RunHistoryRecord) -> (sessionId: String?, parentSessionId: String?, relativeTranscriptPath: String?, transcriptKey: String?) {
        let parentSessionId = record.parentSessionId ?? record.metadata["originSessionId"]
        let transcriptKey = record.transcriptKey ?? record.metadata["transcriptKey"]
        let relativeTranscriptPath = normalizedRelativeTranscriptPath(
            record.relativeTranscriptPath,
            parentSessionId: parentSessionId,
            transcriptKey: transcriptKey
        )
        let sessionId = record.sessionId ?? backgroundSessionID(parentSessionId: parentSessionId, relativeTranscriptPath: relativeTranscriptPath)
        return (sessionId, parentSessionId, relativeTranscriptPath, transcriptKey)
    }

    private func normalizedRelativeTranscriptPath(_ value: String?, parentSessionId: String?, transcriptKey: String?) -> String? {
        if let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            guard let parentSessionId else { return value }
            let directory = (value as NSString).deletingLastPathComponent
            guard let filename = normalizedTranscriptFilename((value as NSString).lastPathComponent) else {
                return value
            }
            let resolvedDirectory = directory.isEmpty || directory == "." ? parentSessionId : directory
            return "\(resolvedDirectory)/\(filename)"
        }
        guard let parentSessionId,
              let transcriptKey,
              let filename = normalizedTranscriptFilename(transcriptKey)
        else { return nil }
        return "\(parentSessionId)/subagents/\(filename)"
    }

    private func normalizedTranscriptFilename(_ value: String?) -> String? {
        let rawName = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawName.isEmpty else { return nil }
        var stem = ((rawName as NSString).lastPathComponent as NSString).deletingPathExtension
        if stem.isEmpty { return nil }
        if !stem.hasPrefix("agent-") {
            stem = "agent-\(stem)"
        }
        return "\(stem).jsonl"
    }

    private func backgroundSessionID(parentSessionId: String?, relativeTranscriptPath: String?) -> String? {
        guard let parent = safeSessionIDComponent(parentSessionId),
              let transcriptPath = relativeTranscriptPath,
              let transcript = safeSessionIDComponent(((transcriptPath as NSString).lastPathComponent as NSString).deletingPathExtension)
        else { return nil }
        return "background-\(parent)-\(transcript)"
    }

    private func safeSessionIDComponent(_ value: String?) -> String? {
        let raw = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        var result = ""
        for scalar in raw.unicodeScalars {
            if allowed.contains(scalar) {
                result.unicodeScalars.append(scalar)
            } else {
                result.append("-")
            }
        }
        return result.isEmpty ? nil : result
    }

    func cronJobs(projectRoot: String) -> [AlwaysOnCronJob] {
        let stores = cronJobStores(projectRoot)
        guard !stores.isEmpty else { return [] }
        let history = runHistory(projectRoot: projectRoot)
        return stores.flatMap { store in
            store.rawJobs.map { raw in
                var enriched = raw
                if enriched["durable"] == nil, let durableDefault = store.durableDefault {
                    enriched["durable"] = durableDefault
                }
                return cronJob(from: enriched, history: history)
            }
        }
    }

    private func cronJob(from raw: [String: Any], history: [AlwaysOnRunHistory]) -> AlwaysOnCronJob {
        let id = string(raw["id"], fallback: string(raw["taskId"], fallback: UUID().uuidString))
        let historyRun = history.first { $0.kind == "cron" && $0.sourceId == id }
        let latestRun = latestRun(raw["latestRun"] as? [String: Any]) ?? latestRun(from: historyRun)
        let explicitStatus = AlwaysOnStatus(rawValue: string(raw["status"]))
        let status = explicitStatus
            ?? ((latestRun?.status == .running || latestRun?.status == .queued) ? latestRun?.status : nil)
            ?? .scheduled
        return AlwaysOnCronJob(
            id: id,
            prompt: string(raw["prompt"]),
            cron: string(raw["cron"]),
            status: status,
            recurring: bool(raw["recurring"], fallback: true),
            durable: bool(raw["durable"], fallback: true),
            createdAt: date(raw["createdAt"]),
            lastFiredAt: date(raw["lastFiredAt"]),
            latestSessionId: latestRun?.sessionId,
            permanent: bool(raw["permanent"], fallback: false),
            manualOnly: bool(raw["manualOnly"], fallback: false),
            originSessionId: optionalString(raw["originSessionId"]),
            transcriptKey: optionalString(raw["transcriptKey"]),
            latestRun: latestRun
        )
    }

    @discardableResult
    func deleteCronJob(jobID: String, projectRoot: String) throws -> Bool {
        var deleted = false
        for var store in cronJobStores(projectRoot) {
            let originalCount = store.rawJobs.count
            store.rawJobs.removeAll { cronJobMatches($0, jobID: jobID) }
            guard store.rawJobs.count != originalCount else { continue }
            try writeCronJobStore(store)
            deleted = true
        }
        return deleted
    }

    @discardableResult
    func startCronRun(job: AlwaysOnCronJob, projectRoot: String, sessionId: String?) throws -> AlwaysOnRunHistory {
        let run = AlwaysOnRunHistory(
            id: "run-\(UUID().uuidString)",
            title: cronRunTitle(job),
            kind: "cron",
            status: .running,
            startedAt: Date(),
            sourceId: job.id,
            outputLog: "Started native Always-On cron run for \(cronRunTitle(job)).",
            sessionId: sessionId,
            parentSessionId: nil,
            relativeTranscriptPath: nil
        )
        try appendRunHistory(run, projectRoot: projectRoot)
        try writeRunLog(run, projectRoot: projectRoot)
        try updateCronJobLatestRun(job: job, run: run, projectRoot: projectRoot)
        return run
    }

    private func updateCronJobLatestRun(job: AlwaysOnCronJob, run: AlwaysOnRunHistory, projectRoot: String) throws {
        let now = ISO8601DateFormatter().string(from: run.startedAt)
        for var store in cronJobStores(projectRoot) {
            var changed = false
            for index in store.rawJobs.indices where cronJobMatches(store.rawJobs[index], jobID: job.id) {
                store.rawJobs[index]["status"] = AlwaysOnStatus.running.rawValue
                store.rawJobs[index]["lastFiredAt"] = Int(run.startedAt.timeIntervalSince1970 * 1000)
                store.rawJobs[index]["latestRun"] = [
                    "status": AlwaysOnStatus.running.rawValue,
                    "runId": run.id,
                    "startedAt": now,
                    "sessionId": run.sessionId ?? "",
                    "summary": run.title,
                    "lastActivity": now,
                    "taskId": job.id,
                    "outputFile": ".g9claw/always-on/runs/\(run.id).log",
                    "parentSessionId": run.parentSessionId ?? "",
                    "relativeTranscriptPath": run.relativeTranscriptPath ?? "",
                    "transcriptKey": job.transcriptKey ?? "",
                ]
                changed = true
            }
            if changed {
                try writeCronJobStore(store)
            }
        }
    }

    private func cronJobMatches(_ raw: [String: Any], jobID: String) -> Bool {
        string(raw["id"]) == jobID || string(raw["taskId"]) == jobID
    }

    private func cronRunTitle(_ job: AlwaysOnCronJob) -> String {
        let firstLine = job.prompt.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let title = firstLine.replacingOccurrences(of: #"^#\s+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? job.cron : title
    }

    func runLog(projectRoot: String, runID: String, tailBytes: Int = 60_000) -> AlwaysOnRunLog {
        let requestedRunID = runID.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeRunID = normalizeRunID(runID)
        guard !safeRunID.isEmpty else {
            return AlwaysOnRunLog(
                runId: requestedRunID,
                content: "",
                truncated: false,
                updatedAt: nil,
                size: 0,
                source: .history
            )
        }

        guard let logURL = alwaysOnRunsRoots(projectRoot)
            .map({ $0.appendingPathComponent("\(safeRunID).log") })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) })
        else {
            return AlwaysOnRunLog(
                runId: requestedRunID,
                content: "",
                truncated: false,
                updatedAt: nil,
                size: 0,
                source: .history
            )
        }
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
            let size = (attributes[.size] as? NSNumber)?.intValue
        else {
            return AlwaysOnRunLog(
                runId: requestedRunID,
                content: "",
                truncated: false,
                updatedAt: nil,
                size: 0,
                source: .history
            )
        }

        let safeTailBytes = normalizedTailBytes(tailBytes)
        let start = max(0, size - safeTailBytes)
        let content: String
        if size == 0 {
            content = ""
        } else if let handle = try? FileHandle(forReadingFrom: logURL) {
            defer { try? handle.close() }
            do {
                try handle.seek(toOffset: UInt64(start))
                let data = try handle.readToEnd() ?? Data()
                content = String(data: data, encoding: .utf8) ?? ""
            } catch {
                content = ""
            }
        } else {
            content = ""
        }

        return AlwaysOnRunLog(
            runId: requestedRunID,
            content: content,
            truncated: start > 0,
            updatedAt: attributes[.modificationDate] as? Date,
            size: size,
            source: content.isEmpty ? .history : .logFile
        )
    }

    func archive(plan: AlwaysOnPlan, projectRoot: String) throws {
        try updatePlanStatus(planID: plan.id, projectRoot: projectRoot, status: "superseded")
    }

    func markPlanRunning(plan: AlwaysOnPlan, projectRoot: String) throws {
        try updatePlanStatus(planID: plan.id, projectRoot: projectRoot, status: "running")
    }

    @discardableResult
    func startPlanRun(plan: AlwaysOnPlan, projectRoot: String, sessionId: String?) throws -> AlwaysOnRunHistory {
        try updatePlanStatus(planID: plan.id, projectRoot: projectRoot, status: "running")
        let run = AlwaysOnRunHistory(
            id: "run-\(UUID().uuidString)",
            title: plan.title,
            kind: "plan",
            status: .running,
            startedAt: Date(),
            sourceId: plan.id,
            outputLog: "Started native Always-On plan run for \(plan.title).",
            sessionId: sessionId,
            parentSessionId: nil,
            relativeTranscriptPath: nil
        )
        try appendRunHistory(run, projectRoot: projectRoot)
        try writeRunLog(run, projectRoot: projectRoot)
        return run
    }

    @discardableResult
    func createDiscoveryPlan(projectRoot: String, title: String, prompt: String) throws -> AlwaysOnPlan {
        let root = alwaysOnRoot(projectRoot)
        let plansRoot = root.appendingPathComponent("plans", isDirectory: true)
        try FileManager.default.createDirectory(at: plansRoot, withIntermediateDirectories: true)
        let id = "plan-\(UUID().uuidString)"
        let relativePlanPath = ".g9claw/always-on/plans/\(id).md"
        let now = Date()
        let content = """
        # \(title)

        Status: draft
        Created: \(ISO8601DateFormatter().string(from: now))

        ## Discovery Prompt

        \(prompt)

        ## Notes

        Native PilotDeck created this draft plan. Review it, then run it from Always-On.
        """
        try content.write(to: plansRoot.appendingPathComponent("\(id).md"), atomically: true, encoding: .utf8)

        let plan = AlwaysOnPlan(
            id: id,
            title: title,
            summary: prompt,
            rationale: "Created from native Always-On discovery.",
            content: content,
            status: .draft,
            approvalMode: "manual",
            planFilePath: relativePlanPath,
            createdAt: now,
            updatedAt: now,
            executionSessionId: nil,
            executionStatus: nil
        )
        try upsertPlanIndex(plan, projectRoot: projectRoot)
        return plan
    }

    private func updatePlanStatus(planID: String, projectRoot: String, status: String) throws {
        let indexURL = existingAlwaysOnFile(projectRoot, "discovery-plans.json")
            ?? alwaysOnRoot(projectRoot).appendingPathComponent("discovery-plans.json")
        guard
            let data = try? Data(contentsOf: indexURL),
            var json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            var rawPlans = json["plans"] as? [[String: Any]]
        else { return }
        for index in rawPlans.indices where string(rawPlans[index]["id"]) == planID {
            rawPlans[index]["status"] = status
            rawPlans[index]["updatedAt"] = ISO8601DateFormatter().string(from: Date())
        }
        json["plans"] = rawPlans
        let out = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: indexURL)
    }

    private func upsertPlanIndex(_ plan: AlwaysOnPlan, projectRoot: String) throws {
        let root = alwaysOnRoot(projectRoot)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let indexURL = root.appendingPathComponent("discovery-plans.json")
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: indexURL),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }
        var rawPlans = json["plans"] as? [[String: Any]] ?? []
        rawPlans.removeAll { string($0["id"]) == plan.id }
        var rawPlan: [String: Any] = [
            "id": plan.id,
            "title": plan.title,
            "summary": plan.summary,
            "rationale": plan.rationale,
            "status": plan.status.rawValue,
            "approvalMode": plan.approvalMode,
            "planFilePath": plan.planFilePath,
            "createdAt": ISO8601DateFormatter().string(from: plan.createdAt),
            "updatedAt": ISO8601DateFormatter().string(from: plan.updatedAt),
        ]
        if let contextRefs = plan.contextRefs, !contextRefs.isEmpty {
            rawPlan["contextRefs"] = contextRefs
        }
        rawPlans.insert(rawPlan, at: 0)
        json["plans"] = rawPlans
        let out = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: indexURL, options: .atomic)
    }

    private func appendRunHistory(_ run: AlwaysOnRunHistory, projectRoot: String) throws {
        let root = alwaysOnRoot(projectRoot)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("run-history.jsonl")
        var object: [String: Any] = [
            "runId": run.id,
            "title": run.title,
            "kind": run.kind,
            "status": run.status.rawValue,
            "startedAt": ISO8601DateFormatter().string(from: run.startedAt),
            "sourceId": run.sourceId,
            "outputLog": run.outputLog,
            "sessionId": run.sessionId ?? "",
        ]
        if run.sessionId != nil || run.parentSessionId != nil || run.relativeTranscriptPath != nil {
            object["session"] = [
                "sessionId": run.sessionId ?? "",
                "parentSessionId": run.parentSessionId ?? "",
                "relativeTranscriptPath": run.relativeTranscriptPath ?? "",
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var line = String(data: data, encoding: .utf8) ?? "{}"
        line += "\n"
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } else {
            try line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func writeRunLog(_ run: AlwaysOnRunHistory, projectRoot: String) throws {
        let runsRoot = alwaysOnRunsRoot(projectRoot)
        try FileManager.default.createDirectory(at: runsRoot, withIntermediateDirectories: true)
        try run.outputLog.write(to: runsRoot.appendingPathComponent("\(run.id).log"), atomically: true, encoding: .utf8)
    }

    private func alwaysOnRoot(_ projectRoot: String) -> URL {
        URL(fileURLWithPath: NSString(string: projectRoot).expandingTildeInPath)
            .appendingPathComponent(".g9claw", isDirectory: true)
            .appendingPathComponent("always-on", isDirectory: true)
    }

    private func legacyAlwaysOnRoot(_ projectRoot: String) -> URL {
        URL(fileURLWithPath: NSString(string: projectRoot).expandingTildeInPath)
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("always-on", isDirectory: true)
    }

    private func alwaysOnRoots(_ projectRoot: String) -> [URL] {
        [alwaysOnRoot(projectRoot), legacyAlwaysOnRoot(projectRoot)]
    }

    private func existingAlwaysOnFile(_ projectRoot: String, _ fileName: String) -> URL? {
        alwaysOnRoots(projectRoot)
            .map { $0.appendingPathComponent(fileName) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func alwaysOnRunsRoot(_ projectRoot: String) -> URL {
        alwaysOnRoot(projectRoot).appendingPathComponent("runs", isDirectory: true)
    }

    private func alwaysOnRunsRoots(_ projectRoot: String) -> [URL] {
        alwaysOnRoots(projectRoot).map { $0.appendingPathComponent("runs", isDirectory: true) }
    }

    private func cronJobStores(_ projectRoot: String) -> [CronJobStore] {
        cronJobSourceURLs(projectRoot).compactMap { source in
            readCronJobStore(url: source.url, durableDefault: source.durableDefault)
        }
    }

    private func cronJobSourceURLs(_ projectRoot: String) -> [(url: URL, durableDefault: Bool?)] {
        let root = URL(fileURLWithPath: NSString(string: projectRoot).expandingTildeInPath)
        return [
            (root.appendingPathComponent(".g9claw").appendingPathComponent("scheduled_tasks.json"), true),
            (root.appendingPathComponent(".g9claw").appendingPathComponent("session_scheduled_tasks.json"), false),
            (root.appendingPathComponent(".g9claw").appendingPathComponent("cron-jobs.json"), nil),
            (root.appendingPathComponent(".g9claw").appendingPathComponent("always-on").appendingPathComponent("cron-jobs.json"), nil),
            (root.appendingPathComponent(".claude").appendingPathComponent("scheduled_tasks.json"), true),
            (root.appendingPathComponent(".claude").appendingPathComponent("session_scheduled_tasks.json"), false),
            (root.appendingPathComponent(".claude").appendingPathComponent("always-on").appendingPathComponent("cron-jobs.json"), nil),
        ]
    }

    private func readCronJobStore(url: URL, durableDefault: Bool?) -> CronJobStore? {
        guard
            FileManager.default.fileExists(atPath: url.path),
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data)
        else { return nil }

        if let list = json as? [[String: Any]] {
            return CronJobStore(url: url, collectionKey: nil, durableDefault: durableDefault, rootObject: json, rawJobs: list)
        }
        if let dict = json as? [String: Any] {
            if let jobs = dict["jobs"] as? [[String: Any]] {
                return CronJobStore(url: url, collectionKey: "jobs", durableDefault: durableDefault, rootObject: json, rawJobs: jobs)
            }
            if let tasks = dict["tasks"] as? [[String: Any]] {
                return CronJobStore(url: url, collectionKey: "tasks", durableDefault: durableDefault, rootObject: json, rawJobs: tasks)
            }
        }
        return nil
    }

    private func writeCronJobStore(_ store: CronJobStore) throws {
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let object: Any
        if let collectionKey = store.collectionKey {
            var dict = store.rootObject as? [String: Any] ?? [:]
            dict[collectionKey] = store.rawJobs
            object = dict
        } else {
            object = store.rawJobs
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: store.url, options: .atomic)
    }

    private func workspaceSignals(projectRoot: String) -> [String] {
        let root = URL(fileURLWithPath: NSString(string: projectRoot).expandingTildeInPath)
        let names = ["package.json", "README.md", ".git"]
        return names.compactMap { name in
            let url = root.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: url.path) ? "\(name) present" : nil
        }
    }

    private func discoveryContextJSON(_ context: AlwaysOnDiscoveryContext) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard
            let data = try? encoder.encode(context),
            let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    private func g9clawProjectStorePath(projectName: String, projectRoot: String) -> String {
        let root = projectRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        if let home = firstMatch(pattern: #"^(\/Users\/[^\/]+|\/home\/[^\/]+)"#, in: root) {
            return "\(home)/.g9claw/projects/\(projectName)"
        }
        if let windowsHome = firstMatch(pattern: #"^([A-Za-z]:\\Users\\[^\\]+)"#, in: root) {
            return "\(windowsHome)\\.g9claw\\projects\\\(projectName)"
        }
        return "~/.g9claw/projects/\(projectName)"
    }

    private func firstMatch(pattern: String, in value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard
            let match = regex.firstMatch(in: value, range: range),
            match.numberOfRanges > 1,
            let matchRange = Range(match.range(at: 1), in: value)
        else { return nil }
        return String(value[matchRange])
    }

    private func normalizeRunID(_ runID: String) -> String {
        let trimmed = runID.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
        var result = ""
        for scalar in trimmed.unicodeScalars {
            if allowed.contains(scalar) {
                result.unicodeScalars.append(scalar)
            } else {
                result.append("-")
            }
        }
        return result
    }

    private func normalizedTailBytes(_ value: Int) -> Int {
        if value <= 0 {
            return defaultRunLogTailBytes
        }
        return min(value, maxRunLogTailBytes)
    }

    private func isoString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func metadataStrings(_ value: Any?) -> [String: String] {
        guard let dictionary = value as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in dictionary {
            if let string = value as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    result[key] = trimmed
                }
            } else if let bool = value as? Bool {
                result[key] = String(bool)
            } else if let number = value as? NSNumber {
                result[key] = number.stringValue
            } else if value is NSNull {
                continue
            } else if JSONSerialization.isValidJSONObject(value),
                      let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                      let text = String(data: data, encoding: .utf8),
                      !text.isEmpty {
                result[key] = text
            } else {
                let text = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    result[key] = text
                }
            }
        }
        return result
    }

    private func string(_ value: Any?, fallback: String = "") -> String {
        if let string = value as? String, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return fallback
    }

    private func optionalString(_ value: Any?) -> String? {
        let value = string(value)
        return value.isEmpty ? nil : value
    }

    private func stringArrayMap(_ value: Any?) -> [String: [String]]? {
        guard let object = value as? [String: Any] else { return nil }
        var result: [String: [String]] = [:]
        for (key, rawValues) in object {
            let values = (rawValues as? [Any] ?? [])
                .map { string($0) }
                .filter { !$0.isEmpty }
            if !values.isEmpty {
                result[key] = values
            }
        }
        return result.isEmpty ? nil : result
    }

    private func bool(_ value: Any?, fallback: Bool) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return fallback
    }

    private func date(_ value: Any?) -> Date? {
        if let value = value as? Date { return value }
        if let string = value as? String {
            if let iso = ISO8601DateFormatter().date(from: string) {
                return iso
            }
            return DateFormatter.localizedStringDateFormatter.date(from: string)
        }
        if let number = value as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue / 1000)
        }
        return nil
    }

    private func latestRun(_ raw: [String: Any]?) -> AlwaysOnCronLatestRun? {
        guard let raw else { return nil }
        return AlwaysOnCronLatestRun(
            status: AlwaysOnStatus(rawValue: string(raw["status"])),
            runId: optionalString(raw["runId"]),
            startedAt: date(raw["startedAt"]),
            sessionId: optionalString(raw["sessionId"]),
            summary: optionalString(raw["summary"]),
            lastActivity: date(raw["lastActivity"]),
            taskId: optionalString(raw["taskId"]),
            outputFile: optionalString(raw["outputFile"]),
            parentSessionId: optionalString(raw["parentSessionId"]),
            relativeTranscriptPath: optionalString(raw["relativeTranscriptPath"]),
            transcriptKey: optionalString(raw["transcriptKey"])
        )
    }

    private func latestRun(from run: AlwaysOnRunHistory?) -> AlwaysOnCronLatestRun? {
        guard let run else { return nil }
        return AlwaysOnCronLatestRun(
            status: run.status,
            runId: run.id,
            startedAt: run.startedAt,
            sessionId: run.sessionId,
            summary: run.title,
            lastActivity: run.startedAt,
            taskId: run.sourceId,
            outputFile: ".g9claw/always-on/runs/\(run.id).log",
            parentSessionId: run.parentSessionId,
            relativeTranscriptPath: run.relativeTranscriptPath,
            transcriptKey: run.transcriptKey
        )
    }
}

private extension DateFormatter {
    static let localizedStringDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"
        return formatter
    }()
}
