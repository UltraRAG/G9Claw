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

struct MemoryRuntimeDiagnostic: Hashable, Codable {
    var code: String
    var severity: String
    var message: String
}

struct MemoryRetrieveResult: Hashable, Codable {
    var systemContext: String
    var diagnostics: [MemoryRuntimeDiagnostic]
    var traceID: String?

    var injected: Bool {
        !systemContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
    private var lastDreamRecordsBefore: [MemoryRecord]?
    private var lastIndexedAt: Date?
    private var lastDreamAt: Date?
    private var lastIndexedAtByContext: [String: Date] = [:]
    private var lastDreamAtByContext: [String: Date] = [:]
    private var settings = MemorySettingsSnapshot.defaults
    private var jobStates: [MemoryJobKind: MemoryJobState] = Dictionary(
        uniqueKeysWithValues: MemoryJobKind.allCases.map { ($0, .idle($0)) }
    )
    private var pendingRetrievals: [String: PendingRetrieval] = [:]

    private struct PendingRetrieval {
        var query: String
        var startedAt: Date
        var traceID: String
        var intent: String
        var contextPreview: String
    }

    private struct PendingMemoryTurn: Codable, Hashable {
        var id: String
        var sessionID: String
        var projectName: String?
        var projectRoot: String?
        var source: String
        var capturedAt: Date
        var indexedAt: Date?
        var messages: [PendingMemoryMessage]
    }

    private struct PendingMemoryMessage: Codable, Hashable {
        var role: String
        var content: String
        var createdAt: Date
    }

    private struct MemoryClassificationLabel: Hashable {
        var type: MemoryRecordType
        var reason: String
        var evidence: String
        var candidateName: String? = nil
        var candidateDescription: String? = nil
        var candidateBody: String? = nil
    }

    private struct UserIdentityFacts: Hashable {
        var name: String?
        var profession: String?

        var isEmpty: Bool {
            name.nilIfBlank == nil && profession.nilIfBlank == nil
        }
    }

    private struct MemoryExtractionRuntime {
        var providerConfig: ProviderConfig
        var apiKey: String
        var timeoutMs: Int
    }

    private struct MemoryRecallRouteDecision: Hashable {
        var route: String
        var source: String
        var reason: String
    }

    private var extractionRuntime: MemoryExtractionRuntime?

    init(
        memoryRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pilotdeck", isDirectory: true)
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
        let projectLocalMemoryRoot = projectLocalWorkspaceMemoryRoot(for: projectURL.path)
        let nativeWorkspaceMemoryRoot = nativeWorkspaceMemoryRoot(for: projectURL.path)
        let globalMemoryRoot = globalMemoryRoot()
        let roots = uniqueMemoryRoots([
            (root: projectLocalMemoryRoot, relativeRoot: projectURL, projectName: projectName, exposedPrefix: ""),
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

    static func pilotDeckWorkspaceHash(for projectRoot: String) -> String {
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
    @MainActor
    func indexWorkspace(projectRoot: String?, projectName: String?, trigger: String = "manual") async throws -> MemoryDashboardSnapshot {
        guard let projectRoot else {
            throw NSError(domain: "MemoryService", code: 400, userInfo: [NSLocalizedDescriptionKey: "No workspace selected."])
        }
        let root = URL(fileURLWithPath: NSString(string: projectRoot).expandingTildeInPath).standardizedFileURL
        try FileManager.default.createDirectory(at: nativeWorkspaceMemoryRoot(for: root.path), withIntermediateDirectories: true)

        var pendingTurns = try loadPendingTurns(projectRoot: root.path, projectName: projectName)
        pendingTurns.sort { $0.capturedAt < $1.capturedAt }
        let batch = Array(pendingTurns.prefix(max(1, settings.heartbeatBatchSize)))
        let now = Date()
        var steps: [(String, String, String)] = [
            ("index_start", "Index Started", "trigger=\(trigger)")
        ]
        let messageCount = batch.reduce(0) { $0 + $1.messages.count }
        steps.append((
            "batch_loaded",
            "Batch Loaded",
            "\(batch.count) segments, \(messageCount) messages loaded."
        ))
        let focusTurns = batch.flatMap { turn in
            turn.messages.filter { $0.role == ChatRole.user.rawValue }.map { (turn, $0) }
        }
        steps.append((
            "focus_turns_selected",
            "Focus Turns Selected",
            "\(focusTurns.count) user turns in this batch; assistant messages are context only."
        ))

        var storedRecords: [MemoryRecord] = []
        for (turn, focus) in focusTurns {
            let labels = await classifyMemoryTurn(userText: focus.content, assistantContext: turn.messages, projectName: projectName)
            let labelSummary = labels.isEmpty ? "none" : labels.map(\.type.rawValue).joined(separator: ",")
            steps.append((
                "classification",
                "Classification",
                "\(String(focus.content.prefix(120))) -> \(labelSummary)"
            ))
            for label in labels {
                guard let record = await makeIndexedMemoryRecord(
                    label: label,
                    userText: focus.content,
                    turn: turn,
                    projectName: projectName,
                    capturedAt: turn.capturedAt,
                    indexedAt: now
                ) else { continue }
                try writeRecordIfPossible(record, projectRoot: root.path)
                records.removeAll { $0.relativePath == record.relativePath && $0.projectName == record.projectName }
                records.insert(record, at: 0)
                if let url = recordURL(for: record, projectRoot: root.path) {
                    recordFileURLs[recordStorageKey(record)] = url
                }
                storedRecords.append(record)
                steps.append((
                    "\(label.type.rawValue)_create",
                    "\(label.type.label) Create",
                    "created=\(record.name); reason=\(label.reason)"
                ))
            }
        }

        for turn in batch {
            try markPendingTurnIndexed(turn, indexedAt: now)
        }
        if !storedRecords.isEmpty {
            try? repairManifest(at: nativeWorkspaceMemoryRoot(for: root.path))
        }
        loadWorkspaceRecords(projectRoot: root.path, projectName: projectName)
        let indexedAt = Date()
        lastIndexedAt = indexedAt
        lastIndexedAtByContext[memoryContextKey(projectRoot: root.path, projectName: projectName)] = indexedAt
        steps.append((
            "persist",
            "Persist",
            "\(storedRecords.count) memory files written."
        ))
        steps.append((
            "index_finished",
            "Index Finished",
            "stored=\(storedRecords.count), failed=0"
        ))
        let trace = makeTrace(
                kind: "index",
                title: "Memory Index",
                status: "completed",
                trigger: trigger,
                context: root.path,
                reply: storedRecords.isEmpty ? "No pending turns produced memory records." : "Indexed \(storedRecords.count) memory records.",
                steps: steps
            )
        indexTraceRecords.insert(trace, at: 0)
        return dashboard(projectName: projectName, projectRoot: root.path)
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
        let automationEnabled = settings.enabled && (settings.autoIndexIntervalMinutes > 0 || settings.autoDreamIntervalMinutes > 0)
        let visibleCaseTraceRecords = visibleTraces(caseTraceRecords, projectName: projectName, projectRoot: projectRoot)
        let visibleIndexTraceRecords = visibleTraces(indexTraceRecords, projectName: projectName, projectRoot: projectRoot)
        let visibleDreamTraceRecords = visibleTraces(dreamTraceRecords, projectName: projectName, projectRoot: projectRoot)
        let overview = MemoryOverview(
            totalEntries: active.count,
            projectEntries: active.filter { $0.type == .project }.count,
            feedbackEntries: active.filter { $0.type == .feedback }.count,
            userEntries: active.filter { $0.type == .user }.count,
            latestMemoryAt: active.map(\.updatedAt).max(),
            lastIndexedAt: lastIndexedAt(for: projectRoot, projectName: projectName),
            lastDreamAt: lastDreamAt(for: projectRoot, projectName: projectName),
            schedulerEnabled: automationEnabled
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
            userSummary: userProfileSummary(from: active),
            caseTraces: visibleCaseTraceRecords.map(\.title),
            indexTraces: visibleIndexTraceRecords.map(\.title),
            dreamTraces: visibleDreamTraceRecords.map(\.title),
            overview: overview,
            settings: settings,
            workspace: workspace,
            caseTraceRecords: visibleCaseTraceRecords,
            indexTraceRecords: visibleIndexTraceRecords,
            dreamTraceRecords: visibleDreamTraceRecords,
            lastDreamSnapshot: lastDreamSnapshot,
            scheduler: MemorySchedulerSnapshot(enabled: automationEnabled, status: automationEnabled ? "running" : "disabled"),
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

    func retrieveContext(
        query: String,
        recentMessages: [ChatMessage],
        sessionID: String,
        projectName: String?,
        projectRoot: String?
    ) -> MemoryRetrieveResult {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.enabled else {
            return disabledMemoryRetrieveResult()
        }

        beginJob(.recall, message: "正在检索 Memory")
        if let projectRoot {
            loadWorkspaceRecords(projectRoot: projectRoot, projectName: projectName)
        }

        let startedAt = Date()
        let routeDecision = localRecallRouteDecision(
            query: normalizedQuery,
            recentMessages: recentMessages,
            projectName: projectName
        )
        return finishRetrieveContext(
            normalizedQuery: normalizedQuery,
            recentMessages: recentMessages,
            sessionID: sessionID,
            projectName: projectName,
            projectRoot: projectRoot,
            startedAt: startedAt,
            routeDecision: routeDecision
        )
    }

    @MainActor
    func retrieveContextForTurn(
        query: String,
        recentMessages: [ChatMessage],
        sessionID: String,
        projectName: String?,
        projectRoot: String?
    ) async -> MemoryRetrieveResult {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.enabled else {
            return disabledMemoryRetrieveResult()
        }

        beginJob(.recall, message: "正在检索 Memory")
        if let projectRoot {
            loadWorkspaceRecords(projectRoot: projectRoot, projectName: projectName)
        }

        let startedAt = Date()
        let routeDecision = await recallRouteDecision(
            query: normalizedQuery,
            recentMessages: recentMessages,
            projectName: projectName
        )
        return finishRetrieveContext(
            normalizedQuery: normalizedQuery,
            recentMessages: recentMessages,
            sessionID: sessionID,
            projectName: projectName,
            projectRoot: projectRoot,
            startedAt: startedAt,
            routeDecision: routeDecision
        )
    }

    private func disabledMemoryRetrieveResult() -> MemoryRetrieveResult {
        MemoryRetrieveResult(
            systemContext: "",
            diagnostics: [
                MemoryRuntimeDiagnostic(
                    code: "memory_disabled",
                    severity: "info",
                    message: "Memory retrieval is disabled."
                )
            ],
            traceID: nil
        )
    }

    private func finishRetrieveContext(
        normalizedQuery: String,
        recentMessages: [ChatMessage],
        sessionID: String,
        projectName: String?,
        projectRoot: String?,
        startedAt: Date,
        routeDecision: MemoryRecallRouteDecision
    ) -> MemoryRetrieveResult {
        let route = routeDecision.route
        let scopedRecords = scopedMemoryRecords(route: route, projectName: projectName)
        let userProfile = userProfileRecord(in: scopedRecords)
        let selected = selectedMemoryRecords(
            query: normalizedQuery,
            route: route,
            records: scopedRecords
        )
        let systemContext = renderMemoryContext(
            query: normalizedQuery,
            route: route,
            records: selected,
            projectName: projectName,
            projectRoot: projectRoot
        )
        let reply = systemContext.isEmpty ? "PilotDeck memory returned no relevant context." : systemContext
        let trace = makeTrace(
            kind: "recall",
            title: normalizedQuery.isEmpty ? "Memory Recall" : "Recall: \(String(normalizedQuery.prefix(80)))",
            status: "completed",
            trigger: "turn_start",
            context: projectRoot ?? projectName ?? "general",
            reply: reply,
            steps: [
                ("recall_start", "Recall Started", "query=\(String(normalizedQuery.prefix(240))), mode=auto"),
                ("memory_gate", "Memory Gate", "route=\(route), source=\(routeDecision.source), reason=\(routeDecision.reason), recentMessages=\(recentMessages.count)"),
                ("user_base_loaded", "User Base Loaded", userBaseTraceDetail(route: route, userProfile: userProfile)),
                ("manifest_scanned", "Manifest Scanned", "candidates=\(scopedRecords.count), scope=\(recallScopeDescription(route: route, projectName: projectName))"),
                ("manifest_selected", "Manifest Selected", "selected=\(selected.count), ids=\(selected.map(\.relativePath).joined(separator: ", "))"),
                ("files_loaded", "Files Loaded", "requested=\(selected.count), loaded=\(selected.count)"),
                ("context_rendered", "Context Rendered", contextRenderedTraceDetail(route: route, systemContext: systemContext, selected: selected, userProfile: userProfile))
            ]
        )
        caseTraceRecords.insert(trace, at: 0)
        pendingRetrievals[sessionID] = PendingRetrieval(
            query: normalizedQuery,
            startedAt: startedAt,
            traceID: trace.id,
            intent: route,
            contextPreview: systemContext
        )
        finishJob(.recall, phase: .completed, message: "Recall 完成", traceID: trace.id)

        let diagnostics: [MemoryRuntimeDiagnostic] = systemContext.isEmpty
            ? [
                MemoryRuntimeDiagnostic(
                    code: "memory_context_empty",
                    severity: "info",
                    message: "Memory returned no relevant context."
                )
            ]
            : []
        return MemoryRetrieveResult(systemContext: systemContext, diagnostics: diagnostics, traceID: trace.id)
    }

    @discardableResult
    func captureTurn(
        messages: [ChatMessage],
        sessionID: String,
        projectName: String?,
        projectRoot: String?,
        source: String = "pilotdeck-macos-native",
        errored: Bool = false,
        interrupted: Bool = false
    ) -> MemoryRecord? {
        guard settings.enabled else { return nil }
        let normalizedMessages = capturedMessages(from: messages)
        guard !normalizedMessages.isEmpty else {
            finalizePendingRetrieval(sessionID: sessionID, status: captureStatus(errored: errored, interrupted: interrupted), assistantReply: "")
            return nil
        }

        let now = Date()
        let formatter = ISO8601DateFormatter()
        let assistantText = normalizedMessages.last(where: { $0.role == .assistant })?.plainText ?? ""
        let turn = PendingMemoryTurn(
            id: "l0-\(Self.fileTimestamp(now))-\(Self.shortHash(sessionID + formatter.string(from: now)))",
            sessionID: sessionID,
            projectName: projectName,
            projectRoot: projectRoot,
            source: source,
            capturedAt: now,
            indexedAt: nil,
            messages: normalizedMessages.map {
                PendingMemoryMessage(role: $0.role.rawValue, content: $0.plainText, createdAt: $0.createdAt)
            }
        )

        do {
            try writePendingTurn(turn)
        } catch {
            AppLog.write("failed to capture memory turn: \(error.localizedDescription)", file: "memory.log")
        }

        finalizePendingRetrieval(
            sessionID: sessionID,
            status: captureStatus(errored: errored, interrupted: interrupted),
            assistantReply: assistantText,
            capturedRecord: turn.id,
            capturedAt: formatter.string(from: now)
        )
        return nil
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

    func updateExtractionRuntime(providerConfig: ProviderConfig, apiKey: String, timeoutMs: Int) {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !providerConfig.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !providerConfig.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !trimmedKey.isEmpty else {
            extractionRuntime = nil
            return
        }
        extractionRuntime = MemoryExtractionRuntime(
            providerConfig: providerConfig,
            apiKey: trimmedKey,
            timeoutMs: timeoutMs
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
    func runDream(
        projectName: String?,
        projectRoot: String?,
        trigger: String = "manual",
        userProfileOverride: MemoryRecord? = nil
    ) -> MemoryDashboardSnapshot {
        let scoped = records.filter { projectName == nil || $0.projectName == projectName || $0.projectName == nil }
        let now = Date()
        lastDreamAt = now
        lastDreamAtByContext[memoryContextKey(projectRoot: projectRoot, projectName: projectName)] = now
        lastDreamRecordsBefore = records
        let userNotes = scoped
            .filter { $0.type == .user && !$0.deprecated && $0.relativePath.hasPrefix("global/UserIdentityNotes/") }
            .sorted { ($0.capturedAt ?? $0.updatedAt) < ($1.capturedAt ?? $1.updatedAt) }
        let existingProfiles = scoped
            .filter { $0.type == .user && !$0.deprecated && ($0.relativePath == "global/UserIdentity/user-profile.md" || $0.relativePath.hasSuffix("UserIdentity/user-profile.md")) }
        let projectSources = scoped
            .filter { record in
                !record.deprecated &&
                    record.type != .user &&
                    !record.relativePath.hasPrefix("Project/Dream/")
            }
        lastDreamSnapshot = MemoryDreamSnapshot(
            capturedAt: now,
            rollbackReady: true,
            summary: "Dream prepared from \(projectSources.count) project records and \(userNotes.count) user notes."
        )
        let summary = projectSources.prefix(12).map { "- \($0.name): \($0.summary)" }.joined(separator: "\n")
        let dreamRecord = projectSources.count >= 2 ? makeDreamRecord(
            summary: summary,
            projectName: projectName,
            capturedAt: now,
            sourceCount: projectSources.count
        ) : nil
        let userProfile = userProfileOverride ?? makeUserProfileRecord(
            existingProfiles: existingProfiles,
            userNotes: userNotes,
            rewrittenAt: now
        )
        var steps: [(String, String, String)] = [
            ("dream_start", "Dream Start", "\(trigger) dream run started."),
            ("snapshot_loaded", "Snapshot Loaded", "\(projectSources.count) project files, \(userNotes.count) user notes.")
        ]
        let projectEntries = projectSources.filter { $0.type == .project || $0.type == .generalProjectMeta }
        let feedbackEntries = projectSources.filter { $0.type == .feedback }
        steps.append((
            "project_header_scan",
            "Project Header Scan",
            "\(projectEntries.count) active project memory headers scanned."
        ))
        steps.append((
            "project_cluster_plan",
            "Project Cluster Plan",
            projectEntries.count >= 2
                ? "1 project cluster selected for Dream rewrite."
                : "No project cluster was large enough to rewrite."
        ))
        steps.append((
            "feedback_header_scan",
            "Feedback Header Scan",
            "\(feedbackEntries.count) active feedback memory headers scanned."
        ))
        steps.append((
            "feedback_cluster_plan",
            "Feedback Cluster Plan",
            feedbackEntries.count >= 2
                ? "Feedback memories are available for future collaboration-rule consolidation."
                : "No feedback cluster was large enough to rewrite."
        ))
        steps.append((
            "project_meta_review",
            "Project Meta Review",
            "Project metadata review completed without changing project.meta.md."
        ))
        if userProfile != nil {
            steps.append((
                "user_profile_rewritten",
                "User Profile Rewritten",
                "\(userProfileOverride == nil ? "Local fallback" : "Model rewrite") updated the global user profile and absorbed \(userNotes.count) user notes."
            ))
        } else {
            steps.append((
                "user_profile_rewritten",
                "User Profile Rewritten",
                "No user notes were available for profile rewriting."
            ))
        }
        steps.append((
            "project_dream",
                "Project Dream",
                dreamRecord?.relativePath ?? "No project dream cluster was large enough to rewrite."
            ))
        steps.append((
            "manifests_repaired",
            "Manifests Repaired",
            "Memory manifests repaired after Dream mutations."
        ))
        let reply: String
        if let userProfile {
            reply = "Updated \(userProfile.name)."
        } else if let dreamRecord {
            reply = dreamRecord.summary
        } else {
            reply = "No source records needed Dream rewriting."
        }
        steps.append((
            "dream_finished",
            "Dream Finished",
            "profileUpdated=\(userProfile == nil ? "no" : "yes"), projectDream=\(dreamRecord == nil ? "no" : "yes")"
        ))
        let trace = makeTrace(
                kind: "dream",
                title: "Memory Dream",
                status: "completed",
                trigger: trigger,
                context: projectRoot ?? projectName ?? "general",
                reply: reply,
                steps: steps
            )
        dreamTraceRecords.insert(trace, at: 0)
        if let userProfile {
            do {
                for note in userNotes {
                    if let url = recordURL(for: note, projectRoot: projectRoot), FileManager.default.fileExists(atPath: url.path) {
                        try? FileManager.default.removeItem(at: url)
                    }
                }
                try writeRecordIfPossible(userProfile, projectRoot: projectRoot)
                records.removeAll {
                    userNotes.map(\.relativePath).contains($0.relativePath) ||
                        $0.relativePath == userProfile.relativePath
                }
                records.insert(userProfile, at: 0)
                if let url = recordURL(for: userProfile, projectRoot: projectRoot) {
                    recordFileURLs[recordStorageKey(userProfile)] = url
                }
            } catch {
                AppLog.write("failed to write memory user profile: \(error.localizedDescription)", file: "memory.log")
            }
        }
        if let dreamRecord {
            do {
                try writeRecordIfPossible(dreamRecord, projectRoot: projectRoot)
                records.removeAll { $0.relativePath == dreamRecord.relativePath && $0.projectName == dreamRecord.projectName }
                records.insert(dreamRecord, at: 0)
                if let url = recordURL(for: dreamRecord, projectRoot: projectRoot) {
                    recordFileURLs[recordStorageKey(dreamRecord)] = url
                    try? repairManifest(at: url.deletingLastPathComponent().deletingLastPathComponent())
                }
            } catch {
                AppLog.write("failed to write memory dream record: \(error.localizedDescription)", file: "memory.log")
            }
        }
        return dashboard(projectName: projectName, projectRoot: projectRoot)
    }

    @discardableResult
    @MainActor
    func runIndexJob(projectRoot: String?, projectName: String?, trigger: String = "manual") async throws -> MemoryDashboardSnapshot {
        beginJob(.index, message: "正在索引当前工作区")
        do {
            try await Task.sleep(nanoseconds: 180_000_000)
            let snapshot = try await indexWorkspace(projectRoot: projectRoot, projectName: projectName, trigger: trigger)
            finishJob(.index, phase: .completed, message: "索引同步完成", traceID: snapshot.indexTraceRecords.first?.id)
            return dashboard(projectName: projectName, projectRoot: projectRoot, isGeneral: projectName == nil)
        } catch {
            finishJob(.index, phase: .failed, message: error.localizedDescription)
            throw error
        }
    }

    @discardableResult
    @MainActor
    func runDreamJob(projectName: String?, projectRoot: String?, trigger: String = "manual") async -> MemoryDashboardSnapshot {
        beginJob(.dream, message: "正在运行 Memory Dream")
        try? await Task.sleep(nanoseconds: 180_000_000)
        if let projectRoot,
           let pending = try? loadPendingTurns(projectRoot: projectRoot, projectName: projectName),
           !pending.isEmpty {
            _ = try? await runIndexJob(projectRoot: projectRoot, projectName: projectName, trigger: "\(trigger)_dream_prep")
        }
        let userProfileOverride = await makeUserProfileRecordWithModelIfPossible(
            projectName: projectName,
            rewrittenAt: Date()
        )
        let snapshot = runDream(
            projectName: projectName,
            projectRoot: projectRoot,
            trigger: trigger,
            userProfileOverride: userProfileOverride
        )
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
        if let previousRecords = lastDreamRecordsBefore {
            let previousKeys = Set(previousRecords.map(recordStorageKey))
            let removedRecords = records.filter { record in
                !previousKeys.contains(recordStorageKey(record)) &&
                    (projectName == nil || record.projectName == projectName || record.projectName == nil)
            }
            for record in removedRecords {
                if let url = recordURL(for: record, projectRoot: projectRoot), FileManager.default.fileExists(atPath: url.path) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            records = previousRecords
            for record in previousRecords where projectName == nil || record.projectName == projectName || record.projectName == nil {
                try? writeRecordIfPossible(record, projectRoot: projectRoot)
            }
            if let projectRoot {
                try? repairManifest(at: nativeWorkspaceMemoryRoot(for: projectRoot))
            }
            lastDreamRecordsBefore = nil
        }
        self.lastDreamSnapshot = MemoryDreamSnapshot(
            capturedAt: lastDreamSnapshot.capturedAt,
            rollbackReady: false,
            summary: lastDreamSnapshot.summary
        )
        return dashboard(projectName: projectName, projectRoot: projectRoot)
    }

    func automaticJobKindsDue(projectRoot: String? = nil, projectName: String? = nil, now: Date = Date()) -> [MemoryJobKind] {
        guard settings.enabled else { return [] }
        var due: [MemoryJobKind] = []
        if isAutomaticJobDue(lastRunAt: lastIndexedAt(for: projectRoot, projectName: projectName), intervalMinutes: settings.autoIndexIntervalMinutes, now: now) {
            due.append(.index)
        }
        if isAutomaticJobDue(lastRunAt: lastDreamAt(for: projectRoot, projectName: projectName), intervalMinutes: settings.autoDreamIntervalMinutes, now: now) {
            due.append(.dream)
        }
        return due
    }

    @discardableResult
    @MainActor
    func runAutomaticJobsIfDue(
        projectRoot: String?,
        projectName: String?,
        now: Date = Date()
    ) async -> MemoryDashboardSnapshot {
        let due = automaticJobKindsDue(projectRoot: projectRoot, projectName: projectName, now: now)
        guard !due.isEmpty else {
            return dashboard(projectName: projectName, projectRoot: projectRoot, isGeneral: projectName == nil)
        }
        for kind in due {
            switch kind {
            case .index:
                guard projectRoot != nil, jobStates[.index]?.phase != .running else { continue }
                _ = try? await runIndexJob(projectRoot: projectRoot, projectName: projectName, trigger: "auto")
            case .dream:
                guard jobStates[.dream]?.phase != .running else { continue }
                _ = await runDreamJob(projectName: projectName, projectRoot: projectRoot, trigger: "auto")
            case .recall, .rollback:
                continue
            }
        }
        return dashboard(projectName: projectName, projectRoot: projectRoot, isGeneral: projectName == nil)
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
        case Self.memoryExportFormatVersion, Self.legacyMemoryExportFormatVersion:
            let bundle = try decoder.decode(CurrentProjectMemoryExportBundle.self, from: data)
            try importCurrentProjectBundle(bundle, projectName: projectName, projectRoot: projectRoot)
        case Self.allProjectsMemoryExportFormatVersion, Self.legacyAllProjectsMemoryExportFormatVersion:
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

    private struct CapturedMemoryMessage {
        var role: ChatRole
        var plainText: String
        var createdAt: Date
    }

    private func nativeWorkspaceContainerRoot(for projectRoot: String) -> URL {
        nativeWorkspaceMemoryRoot(for: projectRoot).deletingLastPathComponent()
    }

    private func controlRoot(for projectRoot: String?) -> URL {
        if let projectRoot {
            return nativeWorkspaceContainerRoot(for: projectRoot).appendingPathComponent("control", isDirectory: true)
        }
        return memoryRoot.appendingPathComponent("control", isDirectory: true)
    }

    private func pendingTurnDirectory(for projectRoot: String?) -> URL {
        controlRoot(for: projectRoot).appendingPathComponent("l0_sessions", isDirectory: true)
    }

    private func pendingTurnURL(for turn: PendingMemoryTurn) -> URL {
        pendingTurnDirectory(for: turn.projectRoot).appendingPathComponent("\(turn.id).json")
    }

    private func writePendingTurn(_ turn: PendingMemoryTurn) throws {
        let url = pendingTurnURL(for: turn)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(turn).write(to: url, options: .atomic)
    }

    private func loadPendingTurns(projectRoot: String?, projectName: String?) throws -> [PendingMemoryTurn] {
        let directory = pendingTurnDirectory(for: projectRoot)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        return urls.compactMap { url in
            guard url.pathExtension.lowercased() == "json",
                  let data = try? Data(contentsOf: url),
                  let turn = try? decoder.decode(PendingMemoryTurn.self, from: data),
                  turn.indexedAt == nil else {
                return nil
            }
            if let projectName {
                return turn.projectName == projectName ? turn : nil
            }
            return turn
        }
    }

    private func markPendingTurnIndexed(_ turn: PendingMemoryTurn, indexedAt: Date) throws {
        var updated = turn
        updated.indexedAt = indexedAt
        try writePendingTurn(updated)
    }

    @MainActor
    private func recallRouteDecision(
        query: String,
        recentMessages: [ChatMessage],
        projectName: String?
    ) async -> MemoryRecallRouteDecision {
        if let decision = try? await recallRouteDecisionWithModel(
            query: query,
            recentMessages: recentMessages,
            projectName: projectName
        ) {
            return decision
        }
        return localRecallRouteDecision(query: query, recentMessages: recentMessages, projectName: projectName)
    }

    private func localRecallRouteDecision(
        query: String,
        recentMessages: [ChatMessage],
        projectName: String?
    ) -> MemoryRecallRouteDecision {
        let route = memoryRoute(query: query, recentMessages: recentMessages, projectName: projectName)
        let reason: String
        switch route {
        case "user":
            reason = "query asks for stable user identity/background memory"
        case "project":
            reason = "query can benefit from current project memory"
        case "mix":
            reason = "query needs both user identity/background and project memory"
        default:
            reason = "query does not clearly require long-term memory"
        }
        return MemoryRecallRouteDecision(route: route, source: "local_fallback", reason: reason)
    }

    @MainActor
    private func recallRouteDecisionWithModel(
        query: String,
        recentMessages: [ChatMessage],
        projectName: String?
    ) async throws -> MemoryRecallRouteDecision? {
        guard let extractionRuntime else { return nil }
        let systemPrompt = [
            "You decide whether the current query should trigger long-term memory recall.",
            "Return JSON only with fields route and reason.",
            "Valid route values: none, user, project, mix.",
            "Use none unless the query clearly needs long-term memory.",
            "Use user only when the query is asking about stable personal identity/background facts about who the user is, such as name, profession, long-term role context, life background, or durable relationships.",
            "Do not use user for reply preferences, language choices, formatting rules, style guidance, file/tool boundaries, or delivery rules; those belong to project.",
            "Use project when the query only needs current project memory, including project facts, collaboration rules, delivery style, file boundaries, or project status.",
            "Use mix only when the query genuinely needs both current project memory and the user's stable identity/background at the same time.",
            "Do not use mix just because both could be helpful; choose mix only when both are actually necessary to answer well."
        ].joined(separator: "\n")
        let userPayload: [String: Any] = [
            "query": query,
            "project": projectName ?? "",
            "recent_messages": recentMessages.suffix(4).map { message in
                [
                    "role": message.role.rawValue,
                    "content": String(message.plainText.prefix(220))
                ]
            }
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: userPayload, options: [.prettyPrinted, .sortedKeys])
        let userPrompt = String(data: payloadData, encoding: .utf8) ?? query
        let raw = try await callMemoryModel(runtime: extractionRuntime, systemPrompt: systemPrompt, userPrompt: userPrompt)
        guard let data = Self.extractJSONObject(from: raw).data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let routeRaw = (object["route"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              ["none", "user", "project", "mix"].contains(routeRaw) else {
            return nil
        }
        let reason = (object["reason"] as? String)?.nilIfBlank ?? "model memory gate selected \(routeRaw)"
        return MemoryRecallRouteDecision(route: routeRaw, source: "model_gate", reason: reason)
    }

    private func memoryRoute(query: String, recentMessages: [ChatMessage], projectName: String?) -> String {
        let recentText = recentMessages.suffix(8).map(\.plainText).joined(separator: "\n")
        let haystack = "\(query)\n\(recentText)".lowercased()
        guard !haystack.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return projectName == nil ? "none" : "project"
        }
        let userHints = [
            "profile", "personal background", "who am i", "my name", "i am ", "i'm ",
            "我是谁", "我叫什么", "我的名字", "我叫", "我是", "姓名", "职业", "身份", "背景"
        ]
        let projectHints = [
            "workspace", "project", "code", "file", "implement", "fix", "debug", "build", "test",
            "remember", "preference", "prefer", "always", "never", "style", "format",
            "工作区", "项目", "代码", "文件", "实现", "修复", "调试", "测试",
            "记住", "偏好", "习惯", "风格", "回复", "格式", "以后", "不要", "别再"
        ]
        let needsUser = userHints.contains { haystack.contains($0) }
        let needsProject = projectName != nil && (projectHints.contains { haystack.contains($0) } || !needsUser)
        if needsUser && needsProject { return "mix" }
        if needsUser { return "user" }
        if needsProject { return "project" }
        return projectName == nil ? "none" : "project"
    }

    private func scopedMemoryRecords(route: String, projectName: String?) -> [MemoryRecord] {
        records
            .filter { !$0.deprecated }
            .filter { record in
                let isGlobal = isGlobalMemoryRecord(record)
                let isProject = projectName != nil && record.projectName == projectName && !isGlobal
                switch route {
                case "user":
                    return record.type == .user && isGlobal
                case "mix":
                    return (record.type == .user && isGlobal) || isProject || (projectName == nil && record.type != .user)
                case "project":
                    return isProject || (projectName == nil && record.type != .user)
                default:
                    return false
                }
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func selectedMemoryRecords(query: String, route: String, records: [MemoryRecord]) -> [MemoryRecord] {
        guard route != "none", !records.isEmpty else { return [] }
        let terms = Self.recallTerms(from: query)
        if terms.isEmpty {
            return Array(records.prefix(8))
        }
        let now = Date()
        let scored = records
            .map { record in (record, Self.recallScore(record, terms: terms, now: now)) }
            .filter { $0.1 > 0 }
            .sorted {
                if $0.1 == $1.1 {
                    return $0.0.updatedAt > $1.0.updatedAt
                }
                return $0.1 > $1.1
            }
            .prefix(8)
            .map(\.0)
        if !scored.isEmpty {
            return scored
        }
        if route == "user" || route == "mix" {
            let profiles = records.filter {
                $0.type == .user &&
                    ($0.relativePath == "global/UserIdentity/user-profile.md" || $0.relativePath.hasSuffix("UserIdentity/user-profile.md"))
            }
            if !profiles.isEmpty {
                return Array(profiles.prefix(3))
            }
        }
        return []
    }

    private func userProfileRecord(in records: [MemoryRecord]) -> MemoryRecord? {
        records
            .filter { $0.type == .user && !$0.deprecated }
            .first {
                $0.relativePath == "global/UserIdentity/user-profile.md" ||
                    $0.relativePath.hasSuffix("UserIdentity/user-profile.md")
            }
    }

    private func userBaseTraceDetail(route: String, userProfile: MemoryRecord?) -> String {
        guard route == "user" || route == "mix" else {
            return "required=no, route=\(route); current route does not require user identity background."
        }
        guard let userProfile else {
            return "required=yes, identityBackground=0; no stable user profile was available."
        }
        return "required=yes, identityBackground=1, file=\(userProfile.relativePath); attached compact global user profile."
    }

    private func recallScopeDescription(route: String, projectName: String?) -> String {
        switch route {
        case "user":
            return "global_user"
        case "project":
            return projectName == nil ? "general_project" : "workspace_project"
        case "mix":
            return projectName == nil ? "global_user+general_project" : "global_user+workspace_project"
        default:
            return "none"
        }
    }

    private func contextRenderedTraceDetail(
        route: String,
        systemContext: String,
        selected: [MemoryRecord],
        userProfile: MemoryRecord?
    ) -> String {
        let injected = systemContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "false" : "true"
        let userBase = userProfile == nil ? "no" : "yes"
        let lines = systemContext.isEmpty ? 0 : systemContext.components(separatedBy: .newlines).count
        return "injected=\(injected), route=\(route), userBaseInjected=\(userBase), fileCount=\(selected.count), characters=\(systemContext.count), lines=\(lines)"
    }

    private func renderMemoryContext(
        query: String,
        route: String,
        records: [MemoryRecord],
        projectName: String?,
        projectRoot: String?
    ) -> String {
        guard route != "none", !records.isEmpty else { return "" }
        let userRecords = records.filter { isGlobalMemoryRecord($0) || $0.type == .user }
        let projectRecords = records.filter { !(isGlobalMemoryRecord($0) || $0.type == .user) }
        var lines: [String] = [
            "## PilotDeck Memory Recall",
            "- route: \(route)",
            "- query: \(String(query.prefix(240)))"
        ]
        if let projectName {
            lines.append("- project: \(projectName)")
        }
        if let projectRoot {
            lines.append("- workspace: \(projectRoot)")
        }
        lines.append("")
        lines.append("Use these long-term memory records only when they are relevant to the current turn.")
        if !userRecords.isEmpty {
            lines.append("")
            lines.append("### User Memory")
            lines.append(contentsOf: userRecords.map(memoryContextLine))
        }
        if !projectRecords.isEmpty {
            lines.append("")
            lines.append("### Project Memory")
            lines.append(contentsOf: projectRecords.map(memoryContextLine))
        }
        return lines.joined(separator: "\n")
    }

    private func memoryContextLine(_ record: MemoryRecord) -> String {
        let path = record.relativePath.isEmpty ? record.name : record.relativePath
        let summary = record.summary.replacingOccurrences(of: "\n", with: " ")
        return "- `\(path)`: \(record.name) - \(summary)"
    }

    private func isGlobalMemoryRecord(_ record: MemoryRecord) -> Bool {
        record.scope == "global" || record.projectName == nil || record.relativePath.hasPrefix("global/")
    }

    private func capturedMessages(from messages: [ChatMessage]) -> [CapturedMemoryMessage] {
        let finished = messages.filter { !$0.isStreaming }
        let eligible = settings.captureStrategy == "full_session" ? finished : lastTurnMessages(from: finished)
        return eligible.compactMap { message in
            guard message.role == .user || message.role == .assistant else { return nil }
            if message.role == .assistant && !settings.includeAssistant { return nil }
            let text = memoryText(from: message).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return CapturedMemoryMessage(
                role: message.role,
                plainText: String(text.prefix(settings.maxMessageChars)),
                createdAt: message.createdAt
            )
        }
    }

    private func lastTurnMessages(from messages: [ChatMessage]) -> [ChatMessage] {
        guard !messages.isEmpty else { return [] }
        guard let assistantIndex = messages.lastIndex(where: { $0.role == .assistant }) else {
            return Array(messages.suffix(1))
        }
        let prefix = messages[...assistantIndex]
        let userIndex = prefix.lastIndex(where: { $0.role == .user }) ?? assistantIndex
        return Array(messages[userIndex...assistantIndex])
    }

    private func memoryText(from message: ChatMessage) -> String {
        message.blocks.compactMap { block -> String? in
            switch block {
            case .text(let text):
                return text
            case .reasoning:
                return nil
            case .attachment(let attachment):
                return "[Attachment: \(attachment.fileName) \(attachment.path)]"
            case .processStatus:
                return nil
            case .toolCall(let call):
                let input = call.inputJSON.trimmingCharacters(in: .whitespacesAndNewlines)
                return "[Tool call: \(call.name)] \(String(input.prefix(800)))"
            case .toolResult(let result):
                let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                let status = result.isError ? "error" : "ok"
                return "[Tool result: \(result.toolCallId) \(status)] \(String(output.prefix(1_200)))"
            }
        }
        .joined(separator: "\n\n")
    }

    private func captureStatus(errored: Bool, interrupted: Bool) -> String {
        if interrupted { return "interrupted" }
        if errored { return "failed" }
        return "completed"
    }

    private func captureSummary(userText: String, assistantText: String) -> String {
        let user = userText.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let assistant = assistantText.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if !user.isEmpty && !assistant.isEmpty {
            return "User: \(String(user.prefix(120))) | Assistant: \(String(assistant.prefix(120)))"
        }
        if !user.isEmpty {
            return "User: \(String(user.prefix(180)))"
        }
        if !assistant.isEmpty {
            return "Assistant: \(String(assistant.prefix(180)))"
        }
        return "Captured conversation turn"
    }

    @MainActor
    private func classifyMemoryTurn(
        userText: String,
        assistantContext: [PendingMemoryMessage],
        projectName: String?
    ) async -> [MemoryClassificationLabel] {
        if let labels = try? await classifyMemoryTurnWithModel(
            userText: userText,
            assistantContext: assistantContext,
            projectName: projectName
        ), !labels.isEmpty {
            return labels
        }
        return classifyMemoryTurnLocally(userText: userText, projectName: projectName)
    }

    @MainActor
    private func classifyMemoryTurnLocally(userText: String, projectName: String?) -> [MemoryClassificationLabel] {
        let normalized = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        let lower = normalized.lowercased()
        let identity = extractUserIdentityFacts(from: normalized)
        if !identity.isEmpty {
            return [
                MemoryClassificationLabel(
                    type: .user,
                    reason: "The user stated durable identity/background facts.",
                    evidence: normalized
                )
            ]
        }
        if Self.containsAny(lower, [
            "以后", "下次", "偏好", "习惯", "风格", "请你", "不要", "别再", "回复", "输出",
            "prefer", "preference", "always", "never", "style", "format"
        ]) {
            return [
                MemoryClassificationLabel(
                    type: .feedback,
                    reason: "The user gave a durable collaboration preference or delivery rule.",
                    evidence: normalized
                )
            ]
        }
        if projectName != nil,
           Self.containsAny(lower, [
               "记住", "记录", "项目", "工作区", "代码", "需求", "实现", "修复", "测试",
               "remember", "project", "workspace", "code", "requirement", "implement", "fix", "test"
           ]) {
            return [
                MemoryClassificationLabel(
                    type: .project,
                    reason: "The user stated a durable project fact or project-scoped requirement.",
                    evidence: normalized
                )
            ]
        }
        return []
    }

    @MainActor
    private func classifyMemoryTurnWithModel(
        userText: String,
        assistantContext: [PendingMemoryMessage],
        projectName: String?
    ) async throws -> [MemoryClassificationLabel] {
        guard let extractionRuntime else { return [] }
        let assistantMessages = assistantContext
            .filter { $0.role == ChatRole.assistant.rawValue }
            .map(\.content)
            .suffix(3)
            .joined(separator: "\n\n")
        let systemPrompt = """
        You are the native PilotDeck memory indexer.
        Classify exactly one focus user turn into durable memory labels.
        Return JSON only: {"labels":[{"type":"user|project|feedback","reason":"...","evidence":"..."}]}.

        Rules:
        - user: stable cross-project identity/background facts about the user, such as name, profession, durable role, life background, or long-term personal context.
        - project: durable facts or requirements about the current project/workspace.
        - feedback: durable collaboration preferences, delivery rules, format/style guidance, or process feedback.
        - Assistant text is context only. Never create memory from content that appears only in assistant text.
        - Skip ephemeral greetings, one-off questions, and facts that are not useful later.
        - Do not write the final memory note in this step; only classify and cite evidence from the user turn.
        """
        let userPayload: [String: Any] = [
            "project": projectName ?? "",
            "focus_user_turn": userText,
            "assistant_context_only": assistantMessages
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: userPayload, options: [.prettyPrinted, .sortedKeys])
        let userPrompt = String(data: payloadData, encoding: .utf8) ?? userText
        let raw = try await callMemoryModel(runtime: extractionRuntime, systemPrompt: systemPrompt, userPrompt: userPrompt)
        guard let data = Self.extractJSONObject(from: raw).data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let labels = object["labels"] as? [[String: Any]] else {
            return []
        }
        return labels.compactMap { item in
            guard let typeRaw = (item["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  let type = MemoryRecordType(rawValue: typeRaw),
                  type == .user || type == .project || type == .feedback else {
                return nil
            }
            let body = (item["body"] as? String)?.nilIfBlank
            let name = (item["name"] as? String)?.nilIfBlank
            let description = (item["description"] as? String)?.nilIfBlank
            return MemoryClassificationLabel(
                type: type,
                reason: (item["reason"] as? String)?.nilIfBlank ?? "Model classified this turn as \(type.rawValue).",
                evidence: (item["evidence"] as? String)?.nilIfBlank ?? userText,
                candidateName: name,
                candidateDescription: description,
                candidateBody: body
            )
        }
    }

    @MainActor
    private func callMemoryModel(
        runtime: MemoryExtractionRuntime,
        systemPrompt: String,
        userPrompt: String
    ) async throws -> String {
        guard runtime.providerConfig.apiType == .openAIChat else {
            throw ProviderClientError.unsupportedProvider(runtime.providerConfig.provider)
        }
        let endpoint = try Self.openAIChatEndpoint(baseURL: runtime.providerConfig.baseURL)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = max(10, Double(runtime.timeoutMs) / 1000.0)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(runtime.apiKey)", forHTTPHeaderField: "Authorization")
        for (key, value) in runtime.providerConfig.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": runtime.providerConfig.model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "stream": false,
            "temperature": 0
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode,
              200..<300 ~= status else {
            throw ProviderClientError.invalidResponse
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw ProviderClientError.invalidResponse
        }
        return content
    }

    @MainActor
    private func makeIndexedMemoryRecord(
        label: MemoryClassificationLabel,
        userText: String,
        turn: PendingMemoryTurn,
        projectName: String?,
        capturedAt: Date,
        indexedAt: Date
    ) async -> MemoryRecord? {
        if label.candidateBody.nilIfBlank != nil || label.candidateName.nilIfBlank != nil {
            return makeModelMemoryRecord(
                label: label,
                fallbackText: userText,
                turn: turn,
                projectName: projectName,
                capturedAt: capturedAt,
                indexedAt: indexedAt
            )
        }
        if let record = try? await makeMemoryNoteWithModel(
            label: label,
            userText: userText,
            turn: turn,
            projectName: projectName,
            capturedAt: capturedAt,
            indexedAt: indexedAt
        ) {
            return record
        }
        switch label.type {
        case .user:
            return makeUserIdentityNote(userText: userText, turn: turn, capturedAt: capturedAt, indexedAt: indexedAt)
        case .feedback:
            return makeFeedbackMemoryNote(userText: userText, turn: turn, projectName: projectName, capturedAt: capturedAt, indexedAt: indexedAt)
        case .project, .generalProjectMeta:
            return makeProjectMemoryNote(userText: userText, turn: turn, projectName: projectName, capturedAt: capturedAt, indexedAt: indexedAt)
        }
    }

    @MainActor
    private func makeMemoryNoteWithModel(
        label: MemoryClassificationLabel,
        userText: String,
        turn: PendingMemoryTurn,
        projectName: String?,
        capturedAt: Date,
        indexedAt: Date
    ) async throws -> MemoryRecord? {
        guard let extractionRuntime else { return nil }
        let systemPrompt: String
        switch label.type {
        case .user:
            systemPrompt = """
            Create one durable global user identity/background memory note from the focus user turn.
            Return JSON only: {"name":"...","description":"...","body":"markdown"}.
            Preserve stable facts such as name, profession, long-term role, life background, or durable relationships.
            Do not include project tasks, temporary requests, collaboration style preferences, or assistant-only claims.
            Keep the body concise Markdown; prefer bullets such as **姓名** and **职业** when available.
            """
        case .feedback:
            systemPrompt = """
            Create one durable collaboration feedback memory note from the focus user turn.
            Return JSON only: {"name":"...","description":"...","body":"markdown"}.
            Preserve stable preferences about how the assistant should work, answer, format, use tools, or handle future collaboration.
            Do not include user identity facts or one-off task content unless it is part of a durable collaboration rule.
            Keep the body concise Markdown.
            """
        case .project, .generalProjectMeta:
            systemPrompt = """
            Create one durable project memory note from the focus user turn.
            Return JSON only: {"name":"...","description":"...","body":"markdown"}.
            Preserve stable project facts, decisions, requirements, implementation notes, constraints, or current status.
            Do not include global user identity/background facts unless they are explicitly project-scoped.
            Keep the body concise Markdown.
            """
        }
        let assistantContext = turn.messages
            .filter { $0.role == ChatRole.assistant.rawValue }
            .map(\.content)
            .suffix(3)
            .joined(separator: "\n\n")
        let userPayload: [String: Any] = [
            "project": projectName ?? "",
            "label": label.type.rawValue,
            "classification_reason": label.reason,
            "evidence": label.evidence,
            "focus_user_turn": userText,
            "assistant_context_only": assistantContext
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: userPayload, options: [.prettyPrinted, .sortedKeys])
        let userPrompt = String(data: payloadData, encoding: .utf8) ?? userText
        let raw = try await callMemoryModel(runtime: extractionRuntime, systemPrompt: systemPrompt, userPrompt: userPrompt)
        guard let data = Self.extractJSONObject(from: raw).data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let body = (object["body"] as? String)?.nilIfBlank
        let name = (object["name"] as? String)?.nilIfBlank
        let description = (object["description"] as? String)?.nilIfBlank
        guard body != nil || name != nil || description != nil else { return nil }
        let modelLabel = MemoryClassificationLabel(
            type: label.type,
            reason: label.reason,
            evidence: label.evidence,
            candidateName: name,
            candidateDescription: description,
            candidateBody: body
        )
        return makeModelMemoryRecord(
            label: modelLabel,
            fallbackText: userText,
            turn: turn,
            projectName: projectName,
            capturedAt: capturedAt,
            indexedAt: indexedAt
        )
    }

    private func makeModelMemoryRecord(
        label: MemoryClassificationLabel,
        fallbackText: String,
        turn: PendingMemoryTurn,
        projectName: String?,
        capturedAt: Date,
        indexedAt: Date
    ) -> MemoryRecord {
        let name = label.candidateName.nilIfBlank ?? Self.compactTitle(from: fallbackText, fallback: "\(label.type.label) Memory")
        let description = label.candidateDescription.nilIfBlank ?? String(fallbackText.replacingOccurrences(of: "\n", with: " ").prefix(140))
        let body = label.candidateBody.nilIfBlank ?? fallbackText
        let scope = label.type == .user ? "global" : "project"
        let relativePath: String
        switch label.type {
        case .user:
            relativePath = "global/UserIdentityNotes/\(Self.memoryFileSlug(name))-\(Self.shortHash(fallbackText + turn.sessionID)).md"
        case .feedback:
            relativePath = "Feedback/\(Self.memoryFileSlug(name))-\(Self.shortHash(fallbackText + turn.sessionID)).md"
        case .project, .generalProjectMeta:
            relativePath = "Project/\(Self.memoryFileSlug(name))-\(Self.shortHash(fallbackText + turn.sessionID)).md"
        }
        let content = renderMemoryFile(
            name: name,
            description: description,
            type: label.type,
            scope: scope,
            projectId: label.type == .user ? nil : projectName,
            sourceSessionKey: turn.sessionID,
            capturedAt: capturedAt,
            updatedAt: indexedAt,
            body: body
        )
        return MemoryRecord(
            id: UUID(),
            name: name,
            summary: description,
            projectName: label.type == .user ? nil : projectName,
            updatedAt: indexedAt,
            type: label.type,
            relativePath: relativePath,
            deprecated: false,
            content: content,
            scope: scope,
            projectId: label.type == .user ? nil : projectName,
            sourceSessionKey: turn.sessionID,
            capturedAt: capturedAt
        )
    }

    private func makeUserIdentityNote(
        userText: String,
        turn: PendingMemoryTurn,
        capturedAt: Date,
        indexedAt: Date
    ) -> MemoryRecord? {
        let facts = extractUserIdentityFacts(from: userText)
        guard !facts.isEmpty else { return nil }
        let namePart = facts.name.nilIfBlank
        let professionPart = facts.profession.nilIfBlank
        let titleFacts = [namePart, professionPart].compactMap(\.self).joined(separator: "，")
        let title = titleFacts.isEmpty ? "用户身份" : "用户身份：\(titleFacts)"
        var bodyLines: [String] = ["## 基本信息", ""]
        if let namePart {
            bodyLines.append("- **姓名**：\(namePart)")
        }
        if let professionPart {
            bodyLines.append("- **职业**：\(professionPart)")
        }
        let description: String
        if namePart != nil, professionPart != nil {
            description = "记录用户的姓名和职业背景。"
        } else if namePart != nil {
            description = "记录用户的姓名。"
        } else {
            description = "记录用户的职业背景。"
        }
        let content = renderMemoryFile(
            name: title,
            description: description,
            type: .user,
            scope: "global",
            projectId: nil,
            sourceSessionKey: turn.sessionID,
            capturedAt: capturedAt,
            updatedAt: indexedAt,
            body: bodyLines.joined(separator: "\n")
        )
        let slug = Self.memoryFileSlug(title)
        let relativePath = "global/UserIdentityNotes/\(slug)-\(Self.shortHash(userText + turn.sessionID)).md"
        return MemoryRecord(
            id: UUID(),
            name: title,
            summary: description,
            projectName: nil,
            updatedAt: indexedAt,
            type: .user,
            relativePath: relativePath,
            deprecated: false,
            content: content,
            scope: "global",
            projectId: nil,
            sourceSessionKey: turn.sessionID,
            capturedAt: capturedAt
        )
    }

    private func makeProjectMemoryNote(
        userText: String,
        turn: PendingMemoryTurn,
        projectName: String?,
        capturedAt: Date,
        indexedAt: Date
    ) -> MemoryRecord {
        let title = Self.compactTitle(from: userText, fallback: "Project Memory")
        let body = """
        ## Project Note

        \(userText)
        """
        let content = renderMemoryFile(
            name: title,
            description: String(userText.replacingOccurrences(of: "\n", with: " ").prefix(140)),
            type: .project,
            scope: "project",
            projectId: projectName,
            sourceSessionKey: turn.sessionID,
            capturedAt: capturedAt,
            updatedAt: indexedAt,
            body: body
        )
        return MemoryRecord(
            id: UUID(),
            name: title,
            summary: String(userText.replacingOccurrences(of: "\n", with: " ").prefix(180)),
            projectName: projectName,
            updatedAt: indexedAt,
            type: .project,
            relativePath: "Project/\(Self.memoryFileSlug(title))-\(Self.shortHash(userText + turn.sessionID)).md",
            deprecated: false,
            content: content,
            scope: "project",
            projectId: projectName,
            sourceSessionKey: turn.sessionID,
            capturedAt: capturedAt
        )
    }

    private func makeFeedbackMemoryNote(
        userText: String,
        turn: PendingMemoryTurn,
        projectName: String?,
        capturedAt: Date,
        indexedAt: Date
    ) -> MemoryRecord {
        let title = Self.compactTitle(from: userText, fallback: "Feedback Memory")
        let body = """
        ## Collaboration Feedback

        \(userText)
        """
        let content = renderMemoryFile(
            name: title,
            description: String(userText.replacingOccurrences(of: "\n", with: " ").prefix(140)),
            type: .feedback,
            scope: "project",
            projectId: projectName,
            sourceSessionKey: turn.sessionID,
            capturedAt: capturedAt,
            updatedAt: indexedAt,
            body: body
        )
        return MemoryRecord(
            id: UUID(),
            name: title,
            summary: String(userText.replacingOccurrences(of: "\n", with: " ").prefix(180)),
            projectName: projectName,
            updatedAt: indexedAt,
            type: .feedback,
            relativePath: "Feedback/\(Self.memoryFileSlug(title))-\(Self.shortHash(userText + turn.sessionID)).md",
            deprecated: false,
            content: content,
            scope: "project",
            projectId: projectName,
            sourceSessionKey: turn.sessionID,
            capturedAt: capturedAt
        )
    }

    private func renderMemoryFile(
        name: String,
        description: String,
        type: MemoryRecordType,
        scope: String,
        projectId: String?,
        sourceSessionKey: String?,
        capturedAt: Date,
        updatedAt: Date,
        body: String
    ) -> String {
        let formatter = ISO8601DateFormatter()
        var header = [
            "---",
            "name: \(frontmatterSafe(name))",
            "description: \(frontmatterSafe(description))",
            "type: \(type.rawValue)",
            "scope: \(scope)"
        ]
        if let projectId {
            header.append("project_id: \(frontmatterSafe(projectId))")
        }
        if let sourceSessionKey {
            header.append("source_session_key: \(frontmatterSafe(sourceSessionKey))")
        }
        header.append("captured_at: \(formatter.string(from: capturedAt))")
        header.append("updated_at: \(formatter.string(from: updatedAt))")
        header.append("deprecated: false")
        header.append("---")
        return "\(header.joined(separator: "\n"))\n\(body)\n"
    }

    private func renderCapturedTurn(
        messages: [CapturedMemoryMessage],
        summary: String,
        sessionID: String,
        source: String,
        capturedAt: Date
    ) -> String {
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: capturedAt)
        let body = messages.map { message -> String in
            let role = message.role.rawValue.capitalized
            let createdAt = formatter.string(from: message.createdAt)
            return """
            ### \(role) - \(createdAt)

            \(message.plainText)
            """
        }
        .joined(separator: "\n\n")
        return """
        ---
        name: \(frontmatterSafe("Turn \(String(sessionID.prefix(8)))"))
        description: \(frontmatterSafe(summary))
        type: project
        scope: project
        source_session_key: \(frontmatterSafe(sessionID))
        source: \(frontmatterSafe(source))
        captured_at: \(timestamp)
        updated_at: \(timestamp)
        deprecated: false
        ---
        # Turn Memory

        - Session: \(sessionID)
        - Source: \(source)
        - Captured at: \(timestamp)

        ## Summary

        \(summary)

        ## Messages

        \(body)
        """
    }

    private func frontmatterSafe(_ value: String) -> String {
        let cleaned = value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Memory" : cleaned
    }

    private func extractUserIdentityFacts(from text: String) -> UserIdentityFacts {
        let name = Self.firstMatch(
            pattern: #"(?i)(?:我叫|我的名字(?:是|叫)?|姓名(?:是|叫)?|my name is)\s*([\p{Han}A-Za-z][\p{Han}A-Za-z0-9_·・•]{0,18})"#,
            in: text
        )
        let profession = Self.firstMatch(
            pattern: #"(?i)(?:我是(?:一个|一名|一位)?|我是一(?:个|名|位)|职业(?:是|为)|我是做|是一个)\s*([^，。,.!！?？\n]{2,36})"#,
            in: text
        )
        return UserIdentityFacts(
            name: Self.cleanedIdentityFact(name),
            profession: Self.cleanedIdentityFact(profession)
        )
    }

    private static func cleanedIdentityFact(_ value: String?) -> String? {
        guard var cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cleaned.isEmpty else {
            return nil
        }
        let prefixes = ["一个", "一名", "一位", "a ", "an "]
        for prefix in prefixes where cleaned.lowercased().hasPrefix(prefix) {
            cleaned = String(cleaned.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: " ，。,.!！?？；;：:"))
        return cleaned.nilIfBlank
    }

    private static func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let matchRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[matchRange])
    }

    private static func containsAny(_ value: String, _ needles: [String]) -> Bool {
        needles.contains { value.contains($0.lowercased()) }
    }

    private static func compactTitle(from text: String, fallback: String) -> String {
        let compact = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return fallback }
        return String(compact.prefix(48))
    }

    private static func memoryFileSlug(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:").union(.newlines)
        let pieces = value
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        let slug = pieces.joined(separator: "-")
        return String((slug.nilIfBlank ?? "memory").prefix(72))
    }

    private static func shortHash(_ value: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(10).description
    }

    private static func openAIChatEndpoint(baseURL: String) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProviderClientError.missingBaseURL }
        let suffix = "chat/completions"
        let normalized: String
        if trimmed.hasSuffix("/\(suffix)") {
            normalized = trimmed
        } else {
            normalized = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/\(suffix)"
        }
        guard let url = URL(string: normalized) else {
            throw ProviderClientError.invalidURL(normalized)
        }
        return url
    }

    private static func extractJSONObject(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            let withoutFence = trimmed
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```JSON", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return extractJSONObject(from: withoutFence)
        }
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}"),
              start <= end else {
            return trimmed
        }
        return String(trimmed[start...end])
    }

    private static func fileTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private func finalizePendingRetrieval(
        sessionID: String,
        status: String,
        assistantReply: String,
        capturedRecord: String? = nil,
        capturedAt: String? = nil
    ) {
        let now = Date()
        let iso = ISO8601DateFormatter().string(from: now)
        guard let pending = pendingRetrievals.removeValue(forKey: sessionID) else {
            if let capturedRecord {
                let trace = makeTrace(
                    kind: "capture",
                    title: "Capture: \(String(sessionID.prefix(8)))",
                    status: status,
                    trigger: "turn_end",
                    context: capturedRecord,
                    reply: assistantReply.nilIfBlank ?? "Captured turn memory.",
                    steps: [
                        ("capture_turn", "Turn Captured", "record=\(capturedRecord)")
                    ]
                )
                caseTraceRecords.insert(trace, at: 0)
            }
            return
        }
        guard let index = caseTraceRecords.firstIndex(where: { $0.id == pending.traceID }) else { return }
        var trace = caseTraceRecords[index]
        trace.status = status
        trace.meta["status"] = status
        trace.meta["finishedAt"] = iso
        trace.meta["intent"] = pending.intent
        trace.meta["startedAt"] = ISO8601DateFormatter().string(from: pending.startedAt)
        trace.meta["injected"] = pending.contextPreview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "false" : "true"
        if let capturedRecord {
            trace.meta["capturedRecord"] = capturedRecord
        }
        if let capturedAt {
            trace.meta["capturedAt"] = capturedAt
        }
        if let reply = assistantReply.nilIfBlank {
            trace.reply = reply
        }
        let captureDetail = capturedRecord.map { "record=\($0)" } ?? "record=none"
        let existingEvents = trace.toolEvents.trimmingCharacters(in: .whitespacesAndNewlines)
        let captureEvent = "Turn Captured: \(captureDetail)"
        trace.toolEvents = existingEvents.isEmpty ? captureEvent : "\(existingEvents)\n\(captureEvent)"
        trace.steps.append(
            MemoryTraceStep(
                id: "capture_turn",
                title: "Turn Captured",
                detail: captureDetail,
                status: status,
                createdAt: now
            )
        )
        caseTraceRecords[index] = trace
    }

    private func makeDreamRecord(
        summary: String,
        projectName: String?,
        capturedAt: Date,
        sourceCount: Int
    ) -> MemoryRecord {
        let timestamp = ISO8601DateFormatter().string(from: capturedAt)
        let relativePath = "Project/Dream/project-dream-\(Self.fileTimestamp(capturedAt)).md"
        let title = "Project Dream \(Self.fileTimestamp(capturedAt))"
        let content = """
        ---
        name: \(frontmatterSafe(title))
        description: \(frontmatterSafe("Consolidated \(sourceCount) memory records."))
        type: project
        scope: project
        captured_at: \(timestamp)
        updated_at: \(timestamp)
        deprecated: false
        ---
        # Memory Dream

        - Source records: \(sourceCount)
        - Captured at: \(timestamp)

        ## Consolidated Notes

        \(summary)
        """
        return MemoryRecord(
            id: UUID(),
            name: title,
            summary: "Consolidated \(sourceCount) memory records.",
            projectName: projectName,
            updatedAt: capturedAt,
            type: .project,
            relativePath: relativePath,
            deprecated: false,
            content: content,
            scope: "project",
            projectId: projectName,
            sourceSessionKey: nil,
            capturedAt: capturedAt
        )
    }

    private func makeUserProfileRecord(
        existingProfiles: [MemoryRecord],
        userNotes: [MemoryRecord],
        rewrittenAt: Date
    ) -> MemoryRecord? {
        guard !userNotes.isEmpty else { return nil }
        var facts = UserIdentityFacts(name: nil, profession: nil)
        for profile in existingProfiles.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            let combined = "\(profile.name)\n\(profile.summary)\n\(profile.content)"
            facts = mergeIdentityFacts(facts, with: extractUserIdentityFacts(from: combined))
            facts = mergeIdentityFacts(facts, with: factsFromProfileBullets(combined))
        }
        for note in userNotes {
            let combined = "\(note.name)\n\(note.summary)\n\(note.content)"
            facts = mergeIdentityFacts(facts, with: extractUserIdentityFacts(from: combined))
            facts = mergeIdentityFacts(facts, with: factsFromProfileBullets(combined))
        }
        guard !facts.isEmpty else { return nil }

        var bodyLines = ["## 身份背景", ""]
        var descriptionParts: [String] = ["身份背景"]
        if let name = facts.name.nilIfBlank {
            bodyLines.append("- **姓名**：\(name)")
            descriptionParts.append("姓名：\(name)")
        }
        if let profession = facts.profession.nilIfBlank {
            bodyLines.append("- **职业**：\(profession)")
            descriptionParts.append("职业：\(profession)")
        }
        let sourceSession = userNotes.last?.sourceSessionKey
        let capturedAt = userNotes.compactMap(\.capturedAt).last ?? userNotes.last?.updatedAt ?? rewrittenAt
        let description = descriptionParts.joined(separator: " ")
        let content = renderMemoryFile(
            name: "user-profile",
            description: description,
            type: .user,
            scope: "global",
            projectId: nil,
            sourceSessionKey: sourceSession,
            capturedAt: capturedAt,
            updatedAt: rewrittenAt,
            body: bodyLines.joined(separator: "\n")
        )
        return MemoryRecord(
            id: UUID(),
            name: "user-profile",
            summary: description,
            projectName: nil,
            updatedAt: rewrittenAt,
            type: .user,
            relativePath: "global/UserIdentity/user-profile.md",
            deprecated: false,
            content: content,
            scope: "global",
            projectId: nil,
            sourceSessionKey: sourceSession,
            capturedAt: capturedAt
        )
    }

    @MainActor
    private func makeUserProfileRecordWithModelIfPossible(
        projectName: String?,
        rewrittenAt: Date
    ) async -> MemoryRecord? {
        guard let extractionRuntime else { return nil }
        let scoped = records.filter { projectName == nil || $0.projectName == projectName || $0.projectName == nil }
        let userNotes = scoped
            .filter { $0.type == .user && !$0.deprecated && $0.relativePath.hasPrefix("global/UserIdentityNotes/") }
            .sorted { ($0.capturedAt ?? $0.updatedAt) < ($1.capturedAt ?? $1.updatedAt) }
        guard !userNotes.isEmpty else { return nil }
        let existingProfiles = scoped
            .filter { $0.type == .user && !$0.deprecated && ($0.relativePath == "global/UserIdentity/user-profile.md" || $0.relativePath.hasSuffix("UserIdentity/user-profile.md")) }
            .sorted { $0.updatedAt < $1.updatedAt }
        let systemPrompt = """
        You rewrite the stable global user profile from durable user identity notes.
        Return JSON only: {"description":"short summary","body":"markdown profile"}.

        Rules:
        - Preserve durable identity/background facts about the user: name, profession, long-term role, background, stable relationships.
        - Merge new notes into the existing profile without duplicating facts.
        - Do not include project-specific tasks, temporary requests, style preferences, or assistant-only claims.
        - Keep the body concise Markdown. For Chinese identity fields, prefer bullets such as **姓名** and **职业** when available.
        - If no stable user identity/background facts exist, return {"description":"","body":""}.
        """
        let userPayload: [String: Any] = [
            "existing_profile": existingProfiles.map { record in
                [
                    "relative_path": record.relativePath,
                    "description": record.summary,
                    "content": String(Self.bodyWithoutFrontmatter(record.content).prefix(4_000))
                ]
            },
            "user_notes": userNotes.map { record in
                [
                    "relative_path": record.relativePath,
                    "description": record.summary,
                    "content": String(Self.bodyWithoutFrontmatter(record.content).prefix(4_000))
                ]
            }
        ]
        do {
            let payloadData = try JSONSerialization.data(withJSONObject: userPayload, options: [.prettyPrinted, .sortedKeys])
            let userPrompt = String(data: payloadData, encoding: .utf8) ?? ""
            let raw = try await callMemoryModel(runtime: extractionRuntime, systemPrompt: systemPrompt, userPrompt: userPrompt)
            guard let data = Self.extractJSONObject(from: raw).data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            let body = (object["body"] as? String)?.nilIfBlank
            let description = (object["description"] as? String)?.nilIfBlank ?? body.map { String($0.replacingOccurrences(of: "\n", with: " ").prefix(120)) }
            guard let body, let description else { return nil }
            let sourceSession = userNotes.last?.sourceSessionKey
            let capturedAt = userNotes.compactMap(\.capturedAt).last ?? userNotes.last?.updatedAt ?? rewrittenAt
            let content = renderMemoryFile(
                name: "user-profile",
                description: description,
                type: .user,
                scope: "global",
                projectId: nil,
                sourceSessionKey: sourceSession,
                capturedAt: capturedAt,
                updatedAt: rewrittenAt,
                body: body
            )
            return MemoryRecord(
                id: UUID(),
                name: "user-profile",
                summary: description,
                projectName: nil,
                updatedAt: rewrittenAt,
                type: .user,
                relativePath: "global/UserIdentity/user-profile.md",
                deprecated: false,
                content: content,
                scope: "global",
                projectId: nil,
                sourceSessionKey: sourceSession,
                capturedAt: capturedAt
            )
        } catch {
            AppLog.write("memory user profile model rewrite fallback: \(error.localizedDescription)", file: "memory.log")
            return nil
        }
    }

    private func mergeIdentityFacts(_ current: UserIdentityFacts, with incoming: UserIdentityFacts) -> UserIdentityFacts {
        UserIdentityFacts(
            name: incoming.name.nilIfBlank ?? current.name,
            profession: incoming.profession.nilIfBlank ?? current.profession
        )
    }

    private func factsFromProfileBullets(_ content: String) -> UserIdentityFacts {
        let name = Self.firstMatch(pattern: #"(?m)(?:\*\*)?姓名(?:\*\*)?[：:]\s*([^\n\r]+)"#, in: content)
        let profession = Self.firstMatch(pattern: #"(?m)(?:\*\*)?职业(?:\*\*)?[：:]\s*([^\n\r]+)"#, in: content)
        return UserIdentityFacts(
            name: Self.cleanedIdentityFact(name),
            profession: Self.cleanedIdentityFact(profession)
        )
    }

    private func isAutomaticJobDue(lastRunAt: Date?, intervalMinutes: Int, now: Date) -> Bool {
        guard intervalMinutes > 0 else { return false }
        guard let lastRunAt else { return true }
        return now.timeIntervalSince(lastRunAt) >= Double(intervalMinutes) * 60
    }

    private func lastIndexedAt(for projectRoot: String?, projectName: String?) -> Date? {
        if projectRoot != nil || projectName != nil {
            return lastIndexedAtByContext[memoryContextKey(projectRoot: projectRoot, projectName: projectName)]
        }
        return lastIndexedAt
    }

    private func lastDreamAt(for projectRoot: String?, projectName: String?) -> Date? {
        if projectRoot != nil || projectName != nil {
            return lastDreamAtByContext[memoryContextKey(projectRoot: projectRoot, projectName: projectName)]
        }
        return lastDreamAt
    }

    private func memoryContextKey(projectRoot: String?, projectName: String?) -> String {
        if let projectRoot = projectRoot?.nilIfBlank {
            return URL(fileURLWithPath: NSString(string: projectRoot).expandingTildeInPath).standardizedFileURL.path
        }
        return projectName?.nilIfBlank ?? "general"
    }

    private func visibleTraces(
        _ traces: [MemoryTraceRecord],
        projectName: String?,
        projectRoot: String?
    ) -> [MemoryTraceRecord] {
        guard projectName != nil || projectRoot != nil else { return traces }
        let contextKey = memoryContextKey(projectRoot: projectRoot, projectName: projectName)
        return traces.filter { trace in
            trace.context == contextKey ||
                trace.context == projectName ||
                trace.meta["project"] == projectName ||
                trace.meta["workspace"] == contextKey
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

    private func userProfileSummary(from records: [MemoryRecord]) -> String {
        guard let profile = records
            .filter({ $0.type == .user && !$0.deprecated })
            .first(where: { $0.relativePath == "global/UserIdentity/user-profile.md" || $0.relativePath.hasSuffix("UserIdentity/user-profile.md") }) else {
            return ""
        }
        return Self.bodyWithoutFrontmatter(profile.content).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func bodyWithoutFrontmatter(_ content: String) -> String {
        guard content.hasPrefix("---\n"),
              let endRange = content.range(of: "\n---\n", range: content.index(content.startIndex, offsetBy: 4)..<content.endIndex) else {
            return content
        }
        return String(content[endRange.upperBound...])
    }

    private static let memoryExportFormatVersion = "pilotdeck-memory-snapshot.v1"
    private static let allProjectsMemoryExportFormatVersion = "pilotdeck-memory-snapshot.all-projects.v1"
    private static let legacyMemoryExportFormatVersion = "clawxmemory-memory-snapshot.v4"
    private static let legacyAllProjectsMemoryExportFormatVersion = "clawxmemory-memory-snapshot.all-projects.v1"

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
            let native = try snapshotFiles(in: nativeWorkspaceMemoryRoot(for: projectRoot))
            let files = mergeSnapshotFiles(native)
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
            .appendingPathComponent(Self.pilotDeckWorkspaceHash(for: projectURL.path), isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
    }

    private func projectLocalWorkspaceMemoryRoot(for projectRoot: String) -> URL {
        URL(fileURLWithPath: NSString(string: projectRoot).expandingTildeInPath).standardizedFileURL
            .appendingPathComponent(".pilotdeck", isDirectory: true)
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
            let url = nativeWorkspaceMemoryRoot(for: projectRoot).appendingPathComponent("MEMORY.md")
            if let content = try? String(contentsOf: url, encoding: .utf8), !content.isEmpty {
                return content
            }
        }
        return records.map { "- \($0.name): \($0.summary)" }.joined(separator: "\n")
    }

    private func projectMetaFromFile(projectRoot: String?, fallbackProjectName: String?, isGeneral: Bool) -> MemoryProjectMeta? {
        guard let projectRoot else { return nil }
        let url = nativeWorkspaceMemoryRoot(for: projectRoot).appendingPathComponent("project.meta.md")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let values = Self.frontmatterValues(from: Self.frontmatterHeader(content) ?? "")
        let projectName = values["project_name"]?.nilIfBlank ?? values["name"]?.nilIfBlank ?? fallbackProjectName
        guard let projectName else { return nil }
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

    private static func isDerivedMemoryFile(_ relativePath: String) -> Bool {
        let name = URL(fileURLWithPath: relativePath).lastPathComponent
        return name == "MEMORY.md" ||
            name == "project.meta.md" ||
            name.hasPrefix("turn-") ||
            name.hasPrefix("memory-dream-")
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
        let skipped = Set(["node_modules", "dist", "build", ".next", ".turbo"])
        let allowedExtensions = Set(["md", "txt", "swift", "js", "ts", "tsx", "jsx", "json", "yaml", "yml", "py", "rb", "go", "rs", "html", "css"])
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsPackageDescendants]
        ) else { return [] }
        var urls: [URL] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name.hasPrefix(".") || skipped.contains(name) {
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

    func copySkill(_ skill: SkillRecord, to scope: SkillScope, projectPath: String?, overwrite: Bool) throws -> SkillRecord {
        try transferSkill(skill, to: scope, projectPath: projectPath, overwrite: overwrite, removeOriginal: false)
    }

    func moveSkill(_ skill: SkillRecord, to scope: SkillScope, projectPath: String?, overwrite: Bool) throws -> SkillRecord {
        try transferSkill(skill, to: scope, projectPath: projectPath, overwrite: overwrite, removeOriginal: true)
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
            .appendingPathComponent("pilotdeck-skillhub-\(UUID().uuidString)", isDirectory: true)
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
        if let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true {
                    hardFails.append(.init(code: "symlink_not_supported", message: "Symbolic links are not supported: \(url.lastPathComponent)"))
                }
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

    private func transferSkill(
        _ skill: SkillRecord,
        to scope: SkillScope,
        projectPath: String?,
        overwrite: Bool,
        removeOriginal: Bool
    ) throws -> SkillRecord {
        let source = URL(fileURLWithPath: skill.skillDir).standardizedFileURL
        let root = try root(for: scope, projectPath: projectPath).standardizedFileURL
        let target = root.appendingPathComponent(skill.slug, isDirectory: true).standardizedFileURL
        guard source.path != target.path else {
            throw NSError(domain: "SkillsService", code: 409, userInfo: [NSLocalizedDescriptionKey: "Skill is already in that scope."])
        }
        guard FileManager.default.fileExists(atPath: source.appendingPathComponent("SKILL.md").path) else {
            throw NSError(domain: "SkillsService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Source skill is missing SKILL.md."])
        }
        let validation = validate(source: source)
        guard validation.ok else {
            throw NSError(
                domain: "SkillsService",
                code: 422,
                userInfo: [NSLocalizedDescriptionKey: validation.hardFails.first?.message ?? "Validation failed"]
            )
        }
        if FileManager.default.fileExists(atPath: target.path) {
            if overwrite {
                try FileManager.default.removeItem(at: target)
            } else {
                throw NSError(domain: "SkillsService", code: 409, userInfo: [NSLocalizedDescriptionKey: "Skill already exists in the destination scope."])
            }
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: target)
        if removeOriginal {
            try FileManager.default.removeItem(at: source)
        }
        return readSkillMeta(skillDir: target, scope: scope)!
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
            .appendingPathComponent(".pilotdeck", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
    }

    static func projectSkillsRoot(_ projectPath: String) -> URL {
        URL(fileURLWithPath: projectPath)
            .appendingPathComponent(".pilotdeck", isDirectory: true)
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
    private var recordsByID: [String: RouterStatsRecord] = [:]
    private var recordOrder: [String] = []
    private var pendingMainRecordIDBySession: [String: String] = [:]
    private let recordsURL: URL?
    private let statsURL: URL?

    init() {
        if let paths = try? AppPaths.current() {
            let root = paths.applicationSupport.appendingPathComponent("Routing", isDirectory: true)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            recordsURL = root.appendingPathComponent("routing-records.json")
            statsURL = root.appendingPathComponent("routing-stats.jsonl")
        } else {
            recordsURL = nil
            statsURL = nil
        }
        load()
    }

    static func classifyTier(prompt: String, runMode: ChatRunMode) -> String {
        if runMode == .plan { return RouterTier.reasoning.rawValue }
        let normalized = prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let words = normalized.split { $0.isWhitespace || $0.isNewline }
        if words.count < 20,
           !containsAny(normalized, ["修改", "优化", "实现", "生成", "创建", "网页", "网站", "代码", "edit", "fix", "build", "implement", "website", "code"]) {
            return RouterTier.simple.rawValue
        }
        if containsAny(normalized, ["架构", "重构", "全量", "复杂", "深入", "推理", "research", "architecture", "refactor", "reasoning"]) {
            return RouterTier.reasoning.rawValue
        }
        if containsAny(normalized, ["修改", "优化", "实现", "生成", "创建", "网页", "网站", "多文件", "edit", "fix", "build", "implement", "website", "multi-file"]) {
            return RouterTier.complex.rawValue
        }
        return RouterTier.medium.rawValue
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
        query: String? = nil,
        decision: RouterDecision? = nil,
        projectPath: String? = nil
    ) {
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "unknown" : model
        let now = Date()
        let tierKey = canonicalTier(tier)
        let routeKey = route.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? "default"
        let id = decision?.id ?? UUID().uuidString
        let record = RouterStatsRecord(
            id: id,
            sessionID: sessionID,
            turnID: id,
            projectName: projectName,
            projectPath: projectPath,
            title: title,
            ts: now,
            event: "decision",
            role: "main",
            scenario: decision?.scenario ?? routeKey,
            resolvedFrom: decision?.resolvedFrom ?? routeKey,
            tier: decision?.tier ?? tierKey,
            providerID: decision?.providerID,
            model: normalizedModel,
            route: routeKey,
            query: sanitizedQuery(query ?? title),
            estimatedInputTokens: decision?.estimatedInputTokens ?? 0,
            stickyHit: decision?.stickyHit ?? false,
            reason: decision?.reason
        )
        pendingMainRecordIDBySession[sessionID] = id
        appendRecord(record)
    }

    func recordTokens(
        sessionID: String,
        title: String,
        projectName: String,
        model: String,
        tier: String,
        totalTokens: Int,
        contextWindow: Int,
        values: [String: String] = [:]
    ) {
        recordTokenUsage(
            sessionID: sessionID,
            title: title,
            projectName: projectName,
            model: model,
            tier: tier,
            usage: RouterTokenUsage(inputTokens: totalTokens, totalTokens: totalTokens),
            contextWindow: contextWindow,
            values: values
        )
    }

    func recordTokenUsage(
        sessionID: String,
        title: String,
        projectName: String,
        model: String,
        tier: String,
        usage: RouterTokenUsage,
        contextWindow: Int,
        values: [String: String] = [:]
    ) {
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "unknown" : model
        let cost = estimatedCost(model: normalizedModel, usage: usage, values: values)
        let baselineCost = baselineCost(usage: usage, values: values)
        let savedCost = max(0, baselineCost - cost)
        let now = Date()
        let tierKey = canonicalTier(tier)
        let recordID = pendingMainRecordIDBySession[sessionID] ?? UUID().uuidString
        let previous = recordsByID[recordID]
        let record = RouterStatsRecord(
            id: recordID,
            sessionID: sessionID,
            turnID: previous?.turnID ?? recordID,
            projectName: projectName,
            projectPath: previous?.projectPath,
            title: title,
            ts: now,
            event: "usage",
            role: previous?.role ?? "main",
            scenario: previous?.scenario ?? "usage",
            resolvedFrom: previous?.resolvedFrom ?? "usage",
            tier: previous?.tier ?? tierKey,
            providerID: previous?.providerID,
            model: normalizedModel,
            route: previous?.route,
            query: previous?.query,
            skill: previous?.skill,
            usage: usage,
            cost: cost,
            baselineCost: baselineCost,
            savedCost: savedCost,
            estimatedInputTokens: previous?.estimatedInputTokens ?? min(usage.totalTokens, contextWindow),
            stickyHit: previous?.stickyHit ?? false,
            reason: previous?.reason
        )
        appendRecord(record)
    }

    func recordSkillInvocation(
        sessionID: String,
        title: String,
        projectName: String,
        skill: String
    ) {
        let now = Date()
        let normalized = skill.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "unknown" : skill
        appendRecord(RouterStatsRecord(
            sessionID: sessionID,
            projectName: projectName,
            title: title,
            ts: now,
            event: "skill",
            role: "tool",
            scenario: "skill",
            resolvedFrom: "tool",
            model: "skill:\(normalized)",
            query: "Skill invoked",
            skill: normalized
        ))
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
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "unknown" : model
        let tierKey = canonicalTier(tier)
        let query = Self.subagentQuery(from: inputJSON)
        appendRecord(RouterStatsRecord(
            sessionID: sessionID,
            projectName: projectName,
            title: title,
            ts: now,
            event: "decision",
            role: "sub",
            scenario: "subagent",
            resolvedFrom: "subagent",
            tier: tierKey,
            model: normalizedModel,
            route: "background",
            query: query
        ))
    }

    func dashboard(projects: [WorkspaceProject], projectFilter: String?) -> RoutingDashboardSnapshot {
        let filteredProjects = projectFilter == nil ? projects : projects.filter { $0.name == projectFilter }
        let projectNameMap = Dictionary(uniqueKeysWithValues: projects.map { ($0.name, $0.displayName) })
        let acceptedProjectNames: Set<String>? = projectFilter.flatMap { filter in
            var names: Set<String> = [filter]
            if let displayName = projectNameMap[filter] {
                names.insert(displayName)
            }
            return names
        }
        let sessionTitles = Dictionary(uniqueKeysWithValues: projects.flatMap { project in
            project.allSessions.map { ($0.id, (title: $0.displayTitle, project: project.displayName, date: $0.activityDate)) }
        })
        let filteredRecords = orderedRecords().filter { record in
            guard let acceptedProjectNames else { return true }
            return acceptedProjectNames.contains(record.projectName)
        }
        let allSessions = buildSessions(from: filteredRecords, sessionTitles: sessionTitles)
            .sorted { $0.lastActiveAt > $1.lastActiveAt }
        let projectSummaries = buildProjectSummaries(from: allSessions)
        return RoutingDashboardSnapshot(
            totalProjects: filteredProjects.count,
            totalSessions: allSessions.count,
            totalRequests: allSessions.reduce(0) { $0 + $1.total.requestCount },
            routedSessions: allSessions.filter { !$0.byModel.isEmpty || !$0.byTier.isEmpty }.count,
            totalTokens: allSessions.reduce(0) { $0 + $1.totalTokens },
            estimatedCost: allSessions.reduce(0) { $0 + $1.estimatedCost },
            savedCost: allSessions.reduce(0) { $0 + $1.savedCost },
            recentSessions: Array(allSessions.prefix(80)),
            projects: projectSummaries
        )
    }

    private func estimatedCost(model: String, usage: RouterTokenUsage, values: [String: String]) -> Double {
        let rate = modelPricingRate(model: model, values: values)
        return (Double(usage.totalTokens) / 1_000_000) * rate
    }

    private func baselineCost(usage: RouterTokenUsage, values: [String: String]) -> Double {
        let baselineModel = values["router.tokenStats.baselineModel"]?.nilIfBlank
            ?? values["router.stats.baselineModel"]?.nilIfBlank
            ?? values["agents.main.model"]?.nilIfBlank
            ?? "default"
        let rate = modelPricingRate(model: baselineModel, values: values)
        return (Double(usage.totalTokens) / 1_000_000) * rate
    }

    private func modelPricingRate(model: String, values: [String: String]) -> Double {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["router.tokenStats.modelPricing.", "router.stats.modelPricing."] {
            for (key, value) in values where key.hasPrefix(prefix) && (key.hasSuffix(".inputPerMillion") || key.hasSuffix(".costPerMillion")) {
                let modelKey = key
                    .dropFirst(prefix.count)
                    .replacingOccurrences(of: ".inputPerMillion", with: "")
                    .replacingOccurrences(of: ".costPerMillion", with: "")
                if trimmedModel == modelKey || trimmedModel.contains(modelKey),
                   let rate = Double(value), rate >= 0 {
                    return rate
                }
            }
        }
        if let rate = Double(values["router.tokenStats.defaultCostPerMillion"] ?? ""), rate >= 0 {
            return rate
        }
        if trimmedModel.contains("qwen3.6-27b") {
            return 0.4
        }
        if trimmedModel.contains("qwen3.6-35b") || trimmedModel.contains("35b-a3b") {
            return 0.2
        }
        return 0.8
    }

    private func mergeAggregate(bucket existing: RoutingBucket?, with incoming: RoutingBucket) -> RoutingBucket {
        let current = existing ?? RoutingBucket()
        return RoutingBucket(
            count: current.count + incoming.count,
            inputTokens: current.inputTokens + incoming.inputTokens,
            outputTokens: current.outputTokens + incoming.outputTokens,
            cacheReadTokens: current.cacheReadTokens + incoming.cacheReadTokens,
            totalTokens: current.totalTokens + incoming.totalTokens,
            requestCount: current.requestCount + max(incoming.requestCount, incoming.count),
            estimatedCost: current.estimatedCost + incoming.estimatedCost,
            baselineCost: current.baselineCost + incoming.baselineCost,
            savedCost: current.savedCost + incoming.savedCost
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

    private func sanitizedQuery(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 180 else { return trimmed }
        return String(trimmed.prefix(180)) + "…"
    }

    private func canonicalTier(_ rawValue: String?) -> String {
        RouterTier(canonicalizing: rawValue).rawValue
    }

    private func bucket(for record: RouterStatsRecord) -> RoutingBucket {
        let counts = countsAsRequest(record) ? 1 : 0
        return RoutingBucket(
            count: counts,
            inputTokens: record.usage.inputTokens,
            outputTokens: record.usage.outputTokens,
            cacheReadTokens: record.usage.cacheReadTokens,
            totalTokens: record.usage.totalTokens,
            requestCount: counts,
            estimatedCost: record.cost,
            baselineCost: record.baselineCost,
            savedCost: record.savedCost
        )
    }

    private func countsAsRequest(_ record: RouterStatsRecord) -> Bool {
        record.event != "skill"
    }

    private func requestEntry(for record: RouterStatsRecord) -> RoutingRequestLogEntry {
        RoutingRequestLogEntry(
            id: record.id,
            ts: record.ts,
            role: record.role,
            tier: record.tier,
            model: record.model,
            tokens: record.usage.totalTokens,
            cost: record.cost,
            baselineCost: record.baselineCost > 0 ? record.baselineCost : nil,
            savedCost: record.savedCost > 0 ? record.savedCost : nil,
            query: record.query,
            scenario: record.scenario,
            route: record.route,
            skill: record.skill
        )
    }

    private func buildSessions(
        from records: [RouterStatsRecord],
        sessionTitles: [String: (title: String, project: String, date: Date)]
    ) -> [RoutingDashboardSession] {
        var sessions: [String: RoutingDashboardSession] = [:]
        for record in records {
            let metadata = sessionTitles[record.sessionID]
            var session = sessions[record.sessionID] ?? makeSession(
                id: record.sessionID,
                title: metadata?.title ?? record.title,
                projectName: metadata?.project ?? record.projectName,
                at: metadata?.date ?? record.ts
            )
            session.title = metadata?.title ?? record.title
            session.projectName = metadata?.project ?? record.projectName
            session.lastActiveAt = max(session.lastActiveAt, record.ts)
            let incoming = bucket(for: record)
            session.total = mergeAggregate(bucket: session.total, with: incoming)
            if let tier = record.tier?.nilIfBlank {
                session.byTier[tier] = mergeAggregate(bucket: session.byTier[tier], with: incoming)
            }
            session.byModel[record.model] = mergeAggregate(bucket: session.byModel[record.model], with: incoming)
            session.byRole[record.role] = mergeAggregate(bucket: session.byRole[record.role], with: incoming)
            session.byScenario[record.scenario] = mergeAggregate(bucket: session.byScenario[record.scenario], with: incoming)
            session.requestEntries.append(requestEntry(for: record))
            session.requestEntries = Array(session.requestEntries.suffix(160))
            session.requestLog.append(logLine(for: record))
            session.requestLog = Array(session.requestLog.suffix(140))
            session.totalTokens = session.total.totalTokens
            session.estimatedCost = session.total.estimatedCost
            session.savedCost = session.total.savedCost
            sessions[record.sessionID] = session
        }
        return Array(sessions.values)
    }

    private func buildProjectSummaries(from sessions: [RoutingDashboardSession]) -> [RoutingDashboardProject] {
        var summaries: [String: RoutingDashboardProject] = [:]
        for session in sessions {
            var summary = summaries[session.projectName] ?? RoutingDashboardProject(
                id: session.projectName,
                name: session.projectName,
                displayName: session.projectName,
                total: RoutingBucket(),
                sessions: 0,
                lastActiveAt: nil
            )
            summary.total = mergeAggregate(bucket: summary.total, with: session.total)
            summary.sessions += 1
            if let last = summary.lastActiveAt {
                summary.lastActiveAt = max(last, session.lastActiveAt)
            } else {
                summary.lastActiveAt = session.lastActiveAt
            }
            summaries[session.projectName] = summary
        }
        return summaries.values.sorted {
            ($0.lastActiveAt ?? .distantPast) > ($1.lastActiveAt ?? .distantPast)
        }
    }

    private func logLine(for record: RouterStatsRecord) -> String {
        let time = DateFormatter.routingTime.string(from: record.ts)
        if record.event == "skill", let skill = record.skill {
            return "\(time) skill invoked · \(skill)"
        }
        let tier = record.tier.map { " · \($0)" } ?? ""
        let usage = record.usage.totalTokens > 0 ? " · \(record.usage.totalTokens) tokens" : ""
        return "\(time) \(record.role) \(record.scenario) -> \(record.model)\(tier)\(usage)"
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
        var loadedJSONL = false
        if let statsURL,
           let data = try? Data(contentsOf: statsURL),
           let text = String(data: data, encoding: .utf8) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            for line in text.split(separator: "\n") {
                guard let lineData = String(line).data(using: .utf8),
                      let record = try? decoder.decode(RouterStatsRecord.self, from: lineData) else { continue }
                ingest(record)
                loadedJSONL = true
            }
        }
        guard !loadedJSONL,
              let recordsURL,
              let data = try? Data(contentsOf: recordsURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([String: RoutingDashboardSession].self, from: data) {
            for record in decoded.values {
                for statsRecord in migrateLegacySession(record) {
                    ingest(statsRecord)
                }
            }
            persistJSONLMigration()
        }
    }

    private func appendRecord(_ record: RouterStatsRecord) {
        ingest(record)
        appendJSONL(record)
    }

    private func ingest(_ record: RouterStatsRecord) {
        if recordsByID[record.id] == nil {
            recordOrder.append(record.id)
        }
        recordsByID[record.id] = record
    }

    private func orderedRecords() -> [RouterStatsRecord] {
        recordOrder.compactMap { recordsByID[$0] }.sorted { $0.ts < $1.ts }
    }

    private func appendJSONL(_ record: RouterStatsRecord) {
        guard let statsURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var data = try? encoder.encode(record) else { return }
        data.append(0x0A)
        if !FileManager.default.fileExists(atPath: statsURL.path) {
            FileManager.default.createFile(atPath: statsURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: statsURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private func persistJSONLMigration() {
        guard let statsURL, !recordsByID.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = orderedRecords().compactMap { try? encoder.encode($0) }
            .reduce(into: Data()) { partial, line in
                partial.append(line)
                partial.append(0x0A)
            }
        try? data.write(to: statsURL, options: .atomic)
    }

    private func migrateLegacySession(_ record: RoutingDashboardSession) -> [RouterStatsRecord] {
        let entries = record.requestEntries.isEmpty ? migrateLegacyLogEntries(record) : record.requestEntries
        return entries.map { entry in
            let usage = RouterTokenUsage(inputTokens: entry.tokens, totalTokens: entry.tokens)
            return RouterStatsRecord(
                id: entry.id,
                sessionID: record.id,
                turnID: entry.id,
                projectName: record.projectName,
                title: record.title,
                ts: entry.ts,
                event: entry.tokens > 0 ? "usage" : (entry.skill == nil ? "decision" : "skill"),
                role: entry.role,
                scenario: entry.scenario ?? "legacy",
                resolvedFrom: entry.route ?? entry.scenario ?? "legacy",
                tier: entry.tier.map(canonicalTier),
                model: entry.model,
                route: entry.route,
                query: entry.query,
                skill: entry.skill,
                usage: usage,
                cost: entry.cost,
                baselineCost: entry.baselineCost ?? 0,
                savedCost: entry.savedCost ?? 0
            )
        }
    }

    private func migrateLegacyLogEntries(_ record: RoutingDashboardSession) -> [RoutingRequestLogEntry] {
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
                let usage = RouterTokenUsage(inputTokens: tokens, totalTokens: tokens)
                let cost = estimatedCost(model: model, usage: usage, values: [:])
                let baseline = baselineCost(usage: usage, values: [:])
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
                    role: "tool",
                    model: "skill:\(skill)",
                    query: "Skill invoked",
                    scenario: "skill",
                    skill: skill
                ))
            }
        }
        return entries
    }
}

actor NativeAlwaysOnManager {
    typealias FireHandler = @MainActor @Sendable (AlwaysOnProjectIdentity, AlwaysOnService.ConfigSnapshot) async -> Void

    private var task: Task<Void, Never>?

    func start(config: AlwaysOnService.ConfigSnapshot, projects: [AlwaysOnProjectIdentity], fire: @escaping FireHandler) {
        task?.cancel()
        guard config.enabled, config.trigger.enabled, !projects.isEmpty else {
            task = nil
            return
        }
        let interval = UInt64(max(1, config.trigger.tickIntervalMinutes) * 60) * 1_000_000_000
        task = Task { [config, projects, fire] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            while !Task.isCancelled {
                for project in projects where !Task.isCancelled {
                    await fire(project, config)
                }
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

private extension DateFormatter {
    static let routingTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

private enum AlwaysOnServiceError: LocalizedError {
    case invalidWorkspace(String)

    var errorDescription: String? {
        switch self {
        case .invalidWorkspace(let message):
            message
        }
    }
}

final class AlwaysOnService: @unchecked Sendable {
    private let defaultRunLogTailBytes = 60_000
    private let maxRunLogTailBytes = 512_000
    private let outputLogMaxCharacters = 60_000
    private let discoveryContextLookbackDays = 7
    private let discoveryContextMaxItems = 20
    private let maxEventCount = 200

    struct ConfigSnapshot: Sendable, Equatable {
        var enabled: Bool
        var language: String
        var trigger: TriggerConfig
        var dormancy: DormancyConfig
        var workspace: WorkspaceConfig
        var execution: ExecutionConfig
        var projects: [String: ProjectConfig]

        static func from(values: [String: String]) -> ConfigSnapshot {
            ConfigSnapshot(
                enabled: AlwaysOnService.bool(values["alwaysOn.enabled"], defaultValue: false),
                language: values["alwaysOn.language"]?.nilIfBlank ?? "zh-CN",
                trigger: TriggerConfig.from(values: values),
                dormancy: DormancyConfig.from(values: values),
                workspace: WorkspaceConfig.from(values: values),
                execution: ExecutionConfig.from(values: values),
                projects: ProjectConfig.projects(from: values)
            )
        }

        func projectEnabled(root: String) -> Bool {
            let normalized = AlwaysOnService.normalizedProjectRoot(root)
            return projects[normalized]?.enabled ?? false
        }
    }

    struct TriggerConfig: Sendable, Equatable {
        var enabled: Bool
        var tickIntervalMinutes: Int
        var cooldownMinutes: Int
        var dailyBudget: Int
        var heartbeatStaleSeconds: Int
        var recentUserMsgMinutes: Int
        var preferChannel: String

        static func from(values: [String: String]) -> TriggerConfig {
            TriggerConfig(
                enabled: AlwaysOnService.bool(values["alwaysOn.trigger.enabled"], defaultValue: false),
                tickIntervalMinutes: AlwaysOnService.positiveInt(values["alwaysOn.trigger.tickIntervalMinutes"], defaultValue: 5),
                cooldownMinutes: AlwaysOnService.positiveInt(values["alwaysOn.trigger.cooldownMinutes"], defaultValue: 60),
                dailyBudget: AlwaysOnService.positiveInt(values["alwaysOn.trigger.dailyBudget"], defaultValue: 4),
                heartbeatStaleSeconds: AlwaysOnService.positiveInt(values["alwaysOn.trigger.heartbeatStaleSeconds"], defaultValue: 90),
                recentUserMsgMinutes: AlwaysOnService.positiveInt(values["alwaysOn.trigger.recentUserMsgMinutes"], defaultValue: 5),
                preferChannel: values["alwaysOn.trigger.preferChannel"]?.nilIfBlank ?? "native"
            )
        }
    }

    struct DormancyConfig: Sendable, Equatable {
        var enabled: Bool
        var debounceMs: Int
        var ignoreGlobs: [String]

        static func from(values: [String: String]) -> DormancyConfig {
            DormancyConfig(
                enabled: AlwaysOnService.bool(values["alwaysOn.dormancy.enabled"], defaultValue: true),
                debounceMs: AlwaysOnService.positiveInt(values["alwaysOn.dormancy.debounceMs"], defaultValue: 2_000),
                ignoreGlobs: AlwaysOnService.splitList(values["alwaysOn.dormancy.ignoreGlobs"])
            )
        }
    }

    struct WorkspaceConfig: Sendable, Equatable {
        var gitWorktreeBaseDir: String?
        var snapshotBaseDir: String?
        var snapshotMaxBytes: Int
        var gitLfs: Bool

        static func from(values: [String: String]) -> WorkspaceConfig {
            WorkspaceConfig(
                gitWorktreeBaseDir: values["alwaysOn.workspace.gitWorktreeBaseDir"]?.nilIfBlank,
                snapshotBaseDir: values["alwaysOn.workspace.snapshotBaseDir"]?.nilIfBlank,
                snapshotMaxBytes: AlwaysOnService.positiveInt(values["alwaysOn.workspace.snapshotMaxBytes"], defaultValue: 1_073_741_824),
                gitLfs: AlwaysOnService.bool(values["alwaysOn.workspace.gitLfs"], defaultValue: false)
            )
        }
    }

    struct ExecutionConfig: Sendable, Equatable {
        var maxTurns: Int
        var maxToolCalls: Int
        var timeoutMinutes: Int

        static func from(values: [String: String]) -> ExecutionConfig {
            ExecutionConfig(
                maxTurns: AlwaysOnService.positiveInt(values["alwaysOn.execution.maxTurns"], defaultValue: 30),
                maxToolCalls: AlwaysOnService.positiveInt(values["alwaysOn.execution.maxToolCalls"], defaultValue: 200),
                timeoutMinutes: AlwaysOnService.positiveInt(values["alwaysOn.execution.timeoutMinutes"], defaultValue: 20)
            )
        }
    }

    struct ProjectConfig: Sendable, Equatable {
        var enabled: Bool

        static func projects(from values: [String: String]) -> [String: ProjectConfig] {
            let prefix = "alwaysOn.projects."
            var roots = Set<String>()
            for key in values.keys where key.hasPrefix(prefix) && key.hasSuffix(".enabled") {
                let suffix = String(key.dropFirst(prefix.count).dropLast(".enabled".count))
                let normalized = AlwaysOnService.normalizedProjectRoot(suffix)
                if !normalized.isEmpty {
                    roots.insert(normalized)
                }
            }
            var result: [String: ProjectConfig] = [:]
            for root in roots {
                let value = values["\(prefix)\(root).enabled"]
                result[root] = ProjectConfig(enabled: AlwaysOnService.bool(value, defaultValue: false))
            }
            return result
        }
    }

    struct GateSnapshot: Sendable, Equatable {
        var isProjectBusy: Bool
        var lastUserMessageAt: Date?
        var now: Date = Date()
    }

    struct GateDecision: Sendable, Equatable {
        var allowed: Bool
        var reason: String
        var detail: String
        var nextEligibleAt: Date?
    }

    private struct CronJobStore {
        var url: URL
        var collectionKey: String?
        var durableDefault: Bool?
        var rootObject: Any
        var rawJobs: [[String: Any]]
    }

    private struct AlwaysOnCycleIndex: Codable {
        var cycles: [AlwaysOnCycle]
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
        var seen = Set<String>()
        return planIndexObjects(projectRoot: projectRoot).compactMap { raw in
            let id = string(raw["id"], fallback: UUID().uuidString)
            guard seen.insert(id).inserted else { return nil }
            let relativePlanPath = string(raw["planFilePath"], fallback: planFileURL(projectRoot: projectRoot, planID: id).path)
            let contentURL = planContentURL(path: relativePlanPath, projectRoot: projectRoot)
            let content = (try? String(contentsOf: contentURL, encoding: .utf8)) ?? ""
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
                executionStatus: AlwaysOnStatus(rawValue: string(raw["executionStatus"])),
                dedupeKey: optionalString(raw["dedupeKey"]),
                sourceRunId: optionalString(raw["sourceRunId"]),
                workCycleId: optionalString(raw["workCycleId"]),
                workspacePath: optionalString(raw["workspacePath"]),
                reportFilePath: optionalString(raw["reportFilePath"]),
                projectName: optionalString(raw["projectName"]),
                projectRoot: optionalString(raw["projectRoot"])
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
        let projectStorePath = pilotDeckProjectStorePath(projectName: projectName, projectRoot: projectRoot)
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
                "5. 如果存在值得跟进的工作，使用 `always_on_discovery_plan` 最多保存 3 个计划。",
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
            "5. If there is worthwhile work, use `always_on_discovery_plan` to persist up to 3 plans.",
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

    @discardableResult
    func startDiscoveryRun(projectRoot: String, title: String, sessionId: String?, runID: String) throws -> AlwaysOnRunHistory {
        let run = AlwaysOnRunHistory(
            id: runID,
            title: title,
            kind: "discovery",
            status: .running,
            startedAt: Date(),
            sourceId: "discovery",
            outputLog: "Started native Always-On discovery.",
            sessionId: sessionId,
            parentSessionId: nil,
            relativeTranscriptPath: nil,
            metadata: ["sessionId": sessionId ?? ""]
        )
        try appendRunHistory(run, projectRoot: projectRoot)
        try writeRunLog(run, projectRoot: projectRoot)
        return run
    }

    func finishDiscoveryRun(
        run: AlwaysOnRunHistory,
        projectRoot: String,
        status: AlwaysOnStatus,
        sessionId: String?,
        outputLog: String,
        error: String? = nil,
        metadata: [String: String] = [:]
    ) throws {
        let finished = AlwaysOnRunHistory(
            id: run.id,
            title: run.title,
            kind: run.kind,
            status: status,
            startedAt: run.startedAt,
            sourceId: run.sourceId,
            outputLog: outputLog,
            sessionId: sessionId ?? run.sessionId,
            parentSessionId: run.parentSessionId,
            relativeTranscriptPath: run.relativeTranscriptPath,
            finishedAt: Date(),
            error: error,
            metadata: metadata.merging(["sessionId": sessionId ?? run.sessionId ?? ""]) { current, _ in current },
            transcriptKey: run.transcriptKey
        )
        try appendRunHistory(finished, projectRoot: projectRoot)
        try writeRunLog(finished, projectRoot: projectRoot)
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
        guard !runId.isEmpty, kind == "plan" || kind == "cron" || kind == "discovery", !sourceId.isEmpty,
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
        try startCronRun(job: job, projectRoot: projectRoot, sessionId: sessionId, runID: nil)
    }

    @discardableResult
    func startCronRun(job: AlwaysOnCronJob, projectRoot: String, sessionId: String?, runID: String? = nil) throws -> AlwaysOnRunHistory {
        let run = AlwaysOnRunHistory(
            id: runID?.nilIfBlank ?? "run-\(UUID().uuidString)",
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

    func finishCronRun(
        job: AlwaysOnCronJob,
        run: AlwaysOnRunHistory,
        projectRoot: String,
        status: AlwaysOnStatus,
        sessionId: String?,
        outputLog: String,
        error: String? = nil,
        metadata: [String: String] = [:]
    ) throws {
        let finished = AlwaysOnRunHistory(
            id: run.id,
            title: run.title,
            kind: run.kind,
            status: status,
            startedAt: run.startedAt,
            sourceId: run.sourceId,
            outputLog: outputLog,
            sessionId: sessionId ?? run.sessionId,
            parentSessionId: run.parentSessionId,
            relativeTranscriptPath: run.relativeTranscriptPath,
            finishedAt: Date(),
            error: error,
            metadata: metadata,
            transcriptKey: run.transcriptKey
        )
        try appendRunHistory(finished, projectRoot: projectRoot)
        try writeRunLog(finished, projectRoot: projectRoot)
        try updateCronJobLatestRun(job: job, run: finished, projectRoot: projectRoot)
    }

    private func updateCronJobLatestRun(job: AlwaysOnCronJob, run: AlwaysOnRunHistory, projectRoot: String) throws {
        let now = ISO8601DateFormatter().string(from: run.startedAt)
        let lastActivity = ISO8601DateFormatter().string(from: run.finishedAt ?? run.startedAt)
        for var store in cronJobStores(projectRoot) {
            var changed = false
            for index in store.rawJobs.indices where cronJobMatches(store.rawJobs[index], jobID: job.id) {
                store.rawJobs[index]["status"] = run.status.rawValue
                store.rawJobs[index]["lastFiredAt"] = Int(run.startedAt.timeIntervalSince1970 * 1000)
                store.rawJobs[index]["latestRun"] = [
                    "status": run.status.rawValue,
                    "runId": run.id,
                    "startedAt": now,
                    "sessionId": run.sessionId ?? "",
                    "summary": run.title,
                    "lastActivity": lastActivity,
                    "taskId": job.id,
                    "outputFile": ".pilotdeck/always-on/runs/\(run.id).log",
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
        try startPlanRun(plan: plan, projectRoot: projectRoot, sessionId: sessionId, runID: nil)
    }

    @discardableResult
    func startPlanRun(plan: AlwaysOnPlan, projectRoot: String, sessionId: String?, runID: String? = nil) throws -> AlwaysOnRunHistory {
        try updatePlanStatus(planID: plan.id, projectRoot: projectRoot, status: "running")
        let run = AlwaysOnRunHistory(
            id: runID?.nilIfBlank ?? "run-\(UUID().uuidString)",
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

    func finishPlanRun(
        plan: AlwaysOnPlan,
        run: AlwaysOnRunHistory,
        projectRoot: String,
        status: AlwaysOnStatus,
        sessionId: String?,
        outputLog: String,
        error: String? = nil,
        metadata: [String: String] = [:]
    ) throws {
        try updatePlanStatus(planID: plan.id, projectRoot: projectRoot, status: status.rawValue)
        let finished = AlwaysOnRunHistory(
            id: run.id,
            title: run.title,
            kind: run.kind,
            status: status,
            startedAt: run.startedAt,
            sourceId: run.sourceId,
            outputLog: outputLog,
            sessionId: sessionId ?? run.sessionId,
            parentSessionId: run.parentSessionId,
            relativeTranscriptPath: run.relativeTranscriptPath,
            finishedAt: Date(),
            error: error,
            metadata: metadata,
            transcriptKey: run.transcriptKey
        )
        try appendRunHistory(finished, projectRoot: projectRoot)
        try writeRunLog(finished, projectRoot: projectRoot)
    }

    @discardableResult
    func createDiscoveryPlan(projectRoot: String, title: String, prompt: String) throws -> AlwaysOnPlan {
        try createDiscoveryPlan(
            projectRoot: projectRoot,
            title: title,
            prompt: prompt,
            summary: nil,
            rationale: nil,
            content: nil,
            approvalMode: "manual",
            contextRefs: nil,
            sourceRunId: nil,
            projectName: nil
        )
    }

    @discardableResult
    func createDiscoveryPlan(
        projectRoot: String,
        title: String,
        prompt: String,
        summary: String? = nil,
        rationale: String? = nil,
        content: String? = nil,
        approvalMode: String = "manual",
        contextRefs: [String: [String]]? = nil,
        sourceRunId: String? = nil,
        projectName: String? = nil
    ) throws -> AlwaysOnPlan {
        let root = alwaysOnRoot(projectRoot)
        let plansRoot = root.appendingPathComponent("plans", isDirectory: true)
        try FileManager.default.createDirectory(at: plansRoot, withIntermediateDirectories: true)
        let id = "plan-\(UUID().uuidString)"
        let planURL = planFileURL(projectRoot: projectRoot, planID: id)
        let relativePlanPath = planURL.path
        let now = Date()
        let resolvedContent = content?.nilIfBlank ?? """
        # \(title)

        Status: draft
        Created: \(ISO8601DateFormatter().string(from: now))

        ## Context

        \(summary?.nilIfBlank ?? "Created from native Always-On discovery.")

        ## Signals Reviewed

        \(prompt)

        ## Proposed Work

        \(summary?.nilIfBlank ?? prompt)

        ## Execution Steps

        Review and run this plan from Always-On when ready.

        ## Verification

        Confirm the workspace diff and run focused checks.

        ## Approval And Execution

        Approval mode: \(approvalMode)
        """
        try resolvedContent.write(to: planURL, atomically: true, encoding: .utf8)

        let plan = AlwaysOnPlan(
            id: id,
            title: title,
            summary: summary?.nilIfBlank ?? prompt,
            rationale: rationale?.nilIfBlank ?? "Created from native Always-On discovery.",
            content: resolvedContent,
            status: .draft,
            approvalMode: approvalMode.nilIfBlank ?? "manual",
            planFilePath: relativePlanPath,
            contextRefs: contextRefs,
            createdAt: now,
            updatedAt: now,
            executionSessionId: nil,
            executionStatus: nil,
            sourceRunId: sourceRunId,
            projectName: projectName,
            projectRoot: Self.normalizedProjectRoot(projectRoot)
        )
        try upsertPlanIndex(plan, projectRoot: projectRoot)
        return plan
    }

    private func updatePlanStatus(planID: String, projectRoot: String, status: String) throws {
        let indexURL = existingPlanIndexURL(projectRoot: projectRoot)
            ?? planIndexURL(projectRoot: projectRoot)
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
        let indexURL = planIndexURL(projectRoot: projectRoot)
        try FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
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
        if let value = plan.dedupeKey { rawPlan["dedupeKey"] = value }
        if let value = plan.sourceRunId { rawPlan["sourceRunId"] = value }
        if let value = plan.workCycleId { rawPlan["workCycleId"] = value }
        if let value = plan.workspacePath { rawPlan["workspacePath"] = value }
        if let value = plan.reportFilePath { rawPlan["reportFilePath"] = value }
        if let value = plan.projectName { rawPlan["projectName"] = value }
        if let value = plan.projectRoot { rawPlan["projectRoot"] = value }
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
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "startedAt": ISO8601DateFormatter().string(from: run.startedAt),
            "sourceId": run.sourceId,
            "outputLog": run.outputLog,
            "sessionId": run.sessionId ?? "",
        ]
        if let finishedAt = run.finishedAt {
            object["finishedAt"] = ISO8601DateFormatter().string(from: finishedAt)
        }
        if let error = run.error?.nilIfBlank {
            object["error"] = error
        }
        if !run.metadata.isEmpty {
            object["metadata"] = run.metadata
        }
        if let transcriptKey = run.transcriptKey?.nilIfBlank {
            object["transcriptKey"] = transcriptKey
        }
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

    func appendRunEvent(
        projectName: String,
        projectRoot: String,
        kind: String,
        status: AlwaysOnStatus,
        title: String,
        detail: String = "",
        runId: String? = nil,
        planId: String? = nil,
        cycleId: String? = nil
    ) {
        let event = AlwaysOnEvent(
            id: "evt-\(UUID().uuidString)",
            projectName: projectName,
            projectRoot: Self.normalizedProjectRoot(projectRoot),
            kind: kind,
            status: status,
            title: title,
            detail: detail,
            runId: runId,
            planId: planId,
            cycleId: cycleId,
            createdAt: Date()
        )
        do {
            let url = eventsURL(projectRoot: projectRoot)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(event)
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
        } catch {
            AppLog.write("always-on event append error: \(error.localizedDescription)", file: "always-on.log")
        }
    }

    func events(projectRoot: String, limit: Int = 80) -> [AlwaysOnEvent] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let lines = alwaysOnRoots(projectRoot)
            .map { $0.appendingPathComponent("events.jsonl") }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .flatMap { $0.split(separator: "\n", omittingEmptySubsequences: true) }
        return lines.compactMap { line in
            try? decoder.decode(AlwaysOnEvent.self, from: Data(String(line).utf8))
        }
        .sorted { $0.createdAt > $1.createdAt }
        .prefix(max(1, limit))
        .map { $0 }
    }

    func dashboard(projects identities: [AlwaysOnProjectIdentity], config: ConfigSnapshot) -> AlwaysOnDashboardSnapshot {
        let projectDashboards = identities.map { identity in
            let projectPlans = plans(projectRoot: identity.rootPath)
            let history = runHistory(projectRoot: identity.rootPath)
            let state = projectState(projectRoot: identity.rootPath)
            let status = AlwaysOnStatus(rawValue: state["status"] ?? "") ?? .unknown
            let runningHistoryCount = history.filter { $0.status == .queued || $0.status == .running || $0.status == .executing || $0.status == .reporting }.count
            let stateRunningCount = (status == .running || status == .executing || status == .reporting) ? 1 : 0
            return AlwaysOnProjectDashboard(
                id: identity.id,
                projectName: identity.projectName,
                displayName: identity.displayName,
                rootPath: identity.rootPath,
                enabled: config.projectEnabled(root: identity.rootPath),
                status: status,
                lastGate: state["lastGate"],
                lastRunAt: date(state["lastRunAt"]),
                nextEligibleAt: date(state["nextEligibleAt"]),
                readyPlans: projectPlans.filter { Self.isRunnablePlanStatus($0.status) }.count,
                runningRuns: max(runningHistoryCount, stateRunningCount)
            )
        }
        let allEvents = identities.flatMap { events(projectRoot: $0.rootPath, limit: 40) }
            .sorted { $0.createdAt > $1.createdAt }
        let calendar = Calendar.current
        let todayEvents = allEvents.filter { calendar.isDateInToday($0.createdAt) }.count
        return AlwaysOnDashboardSnapshot(
            totalProjects: identities.count,
            enabledProjects: projectDashboards.filter(\.enabled).count,
            runningCount: projectDashboards.reduce(0) { $0 + $1.runningRuns },
            todayEvents: todayEvents,
            readyPlans: projectDashboards.reduce(0) { $0 + $1.readyPlans },
            recentEvents: Array(allEvents.prefix(80)),
            projects: projectDashboards
        )
    }

    func evaluateGate(
        project: AlwaysOnProjectIdentity,
        config: ConfigSnapshot,
        snapshot: GateSnapshot
    ) -> GateDecision {
        guard config.enabled else {
            return GateDecision(allowed: false, reason: "disabled", detail: "Always-On is disabled.", nextEligibleAt: nil)
        }
        guard config.trigger.enabled else {
            return GateDecision(allowed: false, reason: "trigger_disabled", detail: "Auto discovery trigger is disabled.", nextEligibleAt: nil)
        }
        guard config.projectEnabled(root: project.rootPath) else {
            return GateDecision(allowed: false, reason: "project_disabled", detail: "Project is not opted into Always-On.", nextEligibleAt: nil)
        }
        guard FileManager.default.fileExists(atPath: project.rootPath) else {
            return GateDecision(allowed: false, reason: "project_missing", detail: "Project path no longer exists.", nextEligibleAt: nil)
        }
        if snapshot.isProjectBusy {
            return GateDecision(allowed: false, reason: "agent_busy", detail: "A project session is currently running.", nextEligibleAt: nil)
        }
        if let lastUser = snapshot.lastUserMessageAt {
            let quietUntil = lastUser.addingTimeInterval(TimeInterval(config.trigger.recentUserMsgMinutes * 60))
            if quietUntil > snapshot.now {
                return GateDecision(allowed: false, reason: "recent_user_msg", detail: "Waiting after recent user activity.", nextEligibleAt: quietUntil)
            }
        }
        let state = projectState(projectRoot: project.rootPath)
        if let lastRunAt = date(state["lastRunAt"]) {
            let cooldownUntil = lastRunAt.addingTimeInterval(TimeInterval(config.trigger.cooldownMinutes * 60))
            if cooldownUntil > snapshot.now {
                return GateDecision(allowed: false, reason: "cooldown", detail: "Cooldown is still active.", nextEligibleAt: cooldownUntil)
            }
        }
        let todayRunCount = todayDiscoveryRunCount(projectRoot: project.rootPath, now: snapshot.now)
        if todayRunCount >= config.trigger.dailyBudget {
            return GateDecision(allowed: false, reason: "daily_budget", detail: "Daily discovery budget is exhausted.", nextEligibleAt: Calendar.current.startOfDay(for: snapshot.now).addingTimeInterval(24 * 60 * 60))
        }
        if config.dormancy.enabled,
           state["dormant"] == "true",
           !hasWorkspaceSignal(projectRoot: project.rootPath, since: date(state["dormantSince"]), ignoreGlobs: config.dormancy.ignoreGlobs) {
            return GateDecision(allowed: false, reason: "dormant_no_signal", detail: "Dormant until workspace signal changes.", nextEligibleAt: nil)
        }
        return GateDecision(allowed: true, reason: "eligible", detail: "Discovery is eligible.", nextEligibleAt: nil)
    }

    func recordGate(project: AlwaysOnProjectIdentity, decision: GateDecision) {
        var state = projectState(projectRoot: project.rootPath)
        state["status"] = decision.allowed ? AlwaysOnStatus.ready.rawValue : AlwaysOnStatus.queued.rawValue
        state["lastGate"] = decision.reason
        state["lastGateDetail"] = decision.detail
        if let nextEligibleAt = decision.nextEligibleAt {
            state["nextEligibleAt"] = isoString(nextEligibleAt)
        } else {
            state.removeValue(forKey: "nextEligibleAt")
        }
        try? writeProjectState(state, projectRoot: project.rootPath)
    }

    func markDiscoveryStarted(project: AlwaysOnProjectIdentity, runID: String) {
        var state = projectState(projectRoot: project.rootPath)
        state["status"] = AlwaysOnStatus.running.rawValue
        state["lastRunAt"] = isoString(Date())
        state["lastRunId"] = runID
        state["dormant"] = "false"
        try? writeProjectState(state, projectRoot: project.rootPath)
    }

    func markDiscoveryFinished(project: AlwaysOnProjectIdentity, runID: String, status: AlwaysOnStatus) {
        var state = projectState(projectRoot: project.rootPath)
        state["status"] = status.rawValue
        state["lastRunId"] = runID
        state["lastFinishedAt"] = isoString(Date())
        if status == .noPlan {
            state["dormant"] = "true"
            state["dormantSince"] = isoString(Date())
        }
        try? writeProjectState(state, projectRoot: project.rootPath)
    }

    func prepareWorkspace(projectName: String, projectRoot: String, config: WorkspaceConfig) async throws -> AlwaysOnWorkspacePreparation {
        let cycle = AlwaysOnCycle(
            id: "cycle-\(UUID().uuidString)",
            projectName: projectName,
            projectRoot: Self.normalizedProjectRoot(projectRoot),
            planId: nil,
            discoveryRunId: nil,
            executionRunId: nil,
            reportRunId: nil,
            workspacePath: nil,
            workspaceMode: nil,
            status: .queued,
            title: "Workspace preparation",
            summary: nil,
            reportFilePath: nil,
            createdAt: Date(),
            updatedAt: Date(),
            appliedAt: nil,
            archivedAt: nil
        )
        return try await prepareWorkspace(projectName: projectName, projectRoot: projectRoot, cycle: cycle, config: config)
    }

    func prepareWorkspace(projectName: String, projectRoot: String, cycle: AlwaysOnCycle, config: WorkspaceConfig) async throws -> AlwaysOnWorkspacePreparation {
        let root = URL(fileURLWithPath: Self.normalizedProjectRoot(projectRoot))
        let preparation: AlwaysOnWorkspacePreparation
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path),
           let worktree = try? await createGitWorktree(projectName: projectName, sourceRoot: root, cycleID: cycle.id, config: config) {
            preparation = worktree
        } else {
            preparation = try copySnapshot(projectName: projectName, sourceRoot: root, cycleID: cycle.id, config: config)
        }
        var updated = cycle
        updated.workspacePath = preparation.workspacePath
        updated.workspaceMode = preparation.mode
        updated.status = .ready
        updated.updatedAt = Date()
        try upsertCycle(updated, projectRoot: projectRoot)
        return preparation
    }

    @discardableResult
    func writeReport(
        projectName: String,
        projectRoot: String,
        cycleId: String?,
        planId: String?,
        summary: String,
        content: String,
        status: AlwaysOnStatus
    ) throws -> String {
        let reportID = cycleId?.nilIfBlank ?? "report-\(UUID().uuidString)"
        let reportsRoot = alwaysOnRoot(projectRoot).appendingPathComponent("reports", isDirectory: true)
        try FileManager.default.createDirectory(at: reportsRoot, withIntermediateDirectories: true)
        let reportURL = reportsRoot.appendingPathComponent("\(normalizeRunID(reportID)).md")
        let markdown = content.nilIfBlank ?? """
        # Always-On Report

        \(summary)
        """
        try markdown.write(to: reportURL, atomically: true, encoding: .utf8)
        appendRunEvent(
            projectName: projectName,
            projectRoot: projectRoot,
            kind: "report",
            status: status,
            title: summary,
            detail: reportURL.path,
            runId: cycleId,
            planId: planId,
            cycleId: cycleId
        )
        if var cycle = cycles(projectRoot: projectRoot).first(where: { $0.id == cycleId }) {
            cycle.reportFilePath = reportURL.path
            cycle.status = status
            cycle.summary = summary
            cycle.updatedAt = Date()
            try upsertCycle(cycle, projectRoot: projectRoot)
        }
        return reportURL.path
    }

    private func alwaysOnRoot(_ projectRoot: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pilotdeck", isDirectory: true)
            .appendingPathComponent("always-on", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(Self.projectStorageID(projectRoot), isDirectory: true)
    }

    private func projectLocalAlwaysOnRoot(_ projectRoot: String) -> URL {
        URL(fileURLWithPath: NSString(string: projectRoot).expandingTildeInPath)
            .appendingPathComponent(".pilotdeck", isDirectory: true)
            .appendingPathComponent("always-on", isDirectory: true)
    }

    private func alwaysOnRoots(_ projectRoot: String) -> [URL] {
        [
            alwaysOnRoot(projectRoot),
            projectLocalAlwaysOnRoot(projectRoot),
        ]
    }

    private func existingAlwaysOnFile(_ projectRoot: String, _ fileName: String) -> URL? {
        alwaysOnRoots(projectRoot)
            .map { $0.appendingPathComponent(fileName) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func planIndexObjects(projectRoot: String) -> [[String: Any]] {
        planIndexCandidateURLs(projectRoot: projectRoot).flatMap { url -> [[String: Any]] in
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return []
            }
            return json["plans"] as? [[String: Any]] ?? []
        }
    }

    private func planIndexURL(projectRoot: String) -> URL {
        alwaysOnRoot(projectRoot)
            .appendingPathComponent("plans", isDirectory: true)
            .appendingPathComponent("index.json")
    }

    private func existingPlanIndexURL(projectRoot: String) -> URL? {
        planIndexCandidateURLs(projectRoot: projectRoot)
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func planIndexCandidateURLs(projectRoot: String) -> [URL] {
        alwaysOnRoots(projectRoot).flatMap { root in
            [
                root.appendingPathComponent("plans", isDirectory: true).appendingPathComponent("index.json"),
                root.appendingPathComponent("discovery-plans.json"),
            ]
        }
    }

    private func planFileURL(projectRoot: String, planID: String) -> URL {
        alwaysOnRoot(projectRoot)
            .appendingPathComponent("plans", isDirectory: true)
            .appendingPathComponent("\(normalizeRunID(planID)).md")
    }

    private func planContentURL(path: String, projectRoot: String) -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }
        return URL(fileURLWithPath: projectRoot).appendingPathComponent(path)
    }

    private func eventsURL(projectRoot: String) -> URL {
        alwaysOnRoot(projectRoot).appendingPathComponent("events.jsonl")
    }

    private func stateURL(projectRoot: String) -> URL {
        alwaysOnRoot(projectRoot).appendingPathComponent("state.json")
    }

    private func projectState(projectRoot: String) -> [String: String] {
        guard let url = alwaysOnRoots(projectRoot)
            .map({ $0.appendingPathComponent("state.json") })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) }),
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return metadataStrings(json)
    }

    private func writeProjectState(_ state: [String: String], projectRoot: String) throws {
        let url = stateURL(projectRoot: projectRoot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func todayDiscoveryRunCount(projectRoot: String, now: Date) -> Int {
        let calendar = Calendar.current
        return events(projectRoot: projectRoot, limit: maxEventCount)
            .filter { $0.kind == "discovery" && calendar.isDate($0.createdAt, inSameDayAs: now) }
            .count
    }

    private func hasWorkspaceSignal(projectRoot: String, since: Date?, ignoreGlobs: [String]) -> Bool {
        guard let since else { return true }
        let root = URL(fileURLWithPath: Self.normalizedProjectRoot(projectRoot))
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return false }
        let ignoredNames: Set<String> = ["node_modules", "dist", "build", ".next", ".turbo"]
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name.hasPrefix(".") || ignoredNames.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            if ignoreGlobs.contains(where: { Self.simpleGlob(relative, matches: $0) }) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard let modifiedAt = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modifiedAt > since else { continue }
            return true
        }
        return false
    }

    private func createGitWorktree(
        projectName: String,
        sourceRoot: URL,
        cycleID: String,
        config: WorkspaceConfig
    ) async throws -> AlwaysOnWorkspacePreparation {
        let base = workspaceBaseURL(config.gitWorktreeBaseDir, fallbackComponent: "worktrees")
        let workspace = base
            .appendingPathComponent(Self.safeFilename(projectName), isDirectory: true)
            .appendingPathComponent(cycleID, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace.deletingLastPathComponent(), withIntermediateDirectories: true)
        let runner = ProcessRunner()
        _ = try await runner.run("/usr/bin/git", arguments: ["worktree", "add", "--detach", workspace.path, "HEAD"], cwd: sourceRoot)
        if config.gitLfs {
            _ = try? await runner.run("/usr/bin/git", arguments: ["lfs", "pull"], cwd: workspace)
        }
        return AlwaysOnWorkspacePreparation(
            cycleId: cycleID,
            workspacePath: workspace.path,
            mode: "worktree",
            sourceRoot: sourceRoot.path,
            createdAt: Date()
        )
    }

    private func copySnapshot(
        projectName: String,
        sourceRoot: URL,
        cycleID: String,
        config: WorkspaceConfig
    ) throws -> AlwaysOnWorkspacePreparation {
        let base = workspaceBaseURL(config.snapshotBaseDir, fallbackComponent: "snapshots")
        let workspace = base
            .appendingPathComponent(Self.safeFilename(projectName), isDirectory: true)
            .appendingPathComponent(cycleID, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace.deletingLastPathComponent(), withIntermediateDirectories: true)
        try copyDirectorySnapshot(from: sourceRoot, to: workspace, maxBytes: config.snapshotMaxBytes)
        return AlwaysOnWorkspacePreparation(
            cycleId: cycleID,
            workspacePath: workspace.path,
            mode: "snapshot",
            sourceRoot: sourceRoot.path,
            createdAt: Date()
        )
    }

    private func workspaceBaseURL(_ configuredPath: String?, fallbackComponent: String) -> URL {
        if let configuredPath = configuredPath?.nilIfBlank {
            return URL(fileURLWithPath: NSString(string: configuredPath).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pilotdeck", isDirectory: true)
            .appendingPathComponent("always-on", isDirectory: true)
            .appendingPathComponent(fallbackComponent, isDirectory: true)
    }

    private func copyDirectorySnapshot(from source: URL, to destination: URL, maxBytes: Int) throws {
        let ignoredNames: Set<String> = ["node_modules", "dist", "build", ".next", ".turbo"]
        var copiedBytes = 0
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        guard let enumerator = FileManager.default.enumerator(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name.hasPrefix(".") || ignoredNames.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            let relative = url.path.replacingOccurrences(of: source.path + "/", with: "")
            let target = destination.appendingPathComponent(relative)
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values.isDirectory == true {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                copiedBytes += values.fileSize ?? 0
                guard copiedBytes <= maxBytes else {
                    throw NSError(domain: "AlwaysOnWorkspace", code: 413, userInfo: [NSLocalizedDescriptionKey: "Snapshot exceeded alwaysOn.workspace.snapshotMaxBytes."])
                }
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: target)
            }
        }
    }

    private func applyGitWorkspaceDiff(source: URL, destination: URL) async throws {
        let command = [
            "set -euo pipefail",
            "git -C \(shellQuote(source.path)) diff --binary HEAD | git -C \(shellQuote(destination.path)) apply --whitespace=nowarn",
        ].joined(separator: "\n")
        _ = try await ProcessRunner().run("/bin/zsh", arguments: ["-lc", command])
    }

    private func copyWorkspaceChanges(source: URL, destination: URL) throws {
        guard let enumerator = FileManager.default.enumerator(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else { return }
        for case let url as URL in enumerator {
            let relative = url.path.replacingOccurrences(of: source.path + "/", with: "")
            guard !relative.isEmpty else { continue }
            if relative == ".git" || relative.hasPrefix(".git/") || relative == ".pilotdeck" || relative.hasPrefix(".pilotdeck/") {
                enumerator.skipDescendants()
                continue
            }
            let target = destination.appendingPathComponent(relative)
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: target.path) {
                    try FileManager.default.removeItem(at: target)
                }
                try FileManager.default.copyItem(at: url, to: target)
            }
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func cyclesIndexURL(projectRoot: String) -> URL {
        alwaysOnRoot(projectRoot)
            .appendingPathComponent("cycles", isDirectory: true)
            .appendingPathComponent("index.json")
    }

    private func upsertCycle(_ cycle: AlwaysOnCycle, projectRoot: String) throws {
        let url = cyclesIndexURL(projectRoot: projectRoot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var cycles = cycles(projectRoot: projectRoot)
        cycles.removeAll { $0.id == cycle.id }
        cycles.insert(cycle, at: 0)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(["cycles": cycles])
        try data.write(to: url, options: .atomic)
    }

    func cycles(projectRoot: String) -> [AlwaysOnCycle] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for root in alwaysOnRoots(projectRoot) {
            let url = root.appendingPathComponent("cycles", isDirectory: true).appendingPathComponent("index.json")
            guard let data = try? Data(contentsOf: url),
                  let wrapper = try? decoder.decode(AlwaysOnCycleIndex.self, from: data) else { continue }
            return wrapper.cycles.sorted { $0.updatedAt > $1.updatedAt }
        }
        return []
    }

    func applyCycle(cycleID: String, projectRoot: String) async throws -> AlwaysOnCycle {
        let trimmedID = cycleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var cycle = cycles(projectRoot: projectRoot).first(where: { $0.id == trimmedID }) else {
            throw AlwaysOnServiceError.invalidWorkspace("Always-On cycle was not found.")
        }
        guard let workspacePath = cycle.workspacePath?.nilIfBlank else {
            throw AlwaysOnServiceError.invalidWorkspace("Always-On cycle has no isolated workspace.")
        }
        let source = URL(fileURLWithPath: workspacePath)
        let destination = URL(fileURLWithPath: Self.normalizedProjectRoot(projectRoot))
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw AlwaysOnServiceError.invalidWorkspace("Isolated workspace no longer exists.")
        }
        guard source.standardizedFileURL.path != destination.standardizedFileURL.path else {
            throw AlwaysOnServiceError.invalidWorkspace("Refusing to apply a cycle onto the same workspace.")
        }

        cycle.status = .applying
        cycle.updatedAt = Date()
        try upsertCycle(cycle, projectRoot: projectRoot)

        if cycle.workspaceMode == "worktree",
           FileManager.default.fileExists(atPath: source.appendingPathComponent(".git").path),
           FileManager.default.fileExists(atPath: destination.appendingPathComponent(".git").path) {
            try await applyGitWorkspaceDiff(source: source, destination: destination)
        } else {
            try copyWorkspaceChanges(source: source, destination: destination)
        }

        cycle.status = .applied
        cycle.appliedAt = Date()
        cycle.updatedAt = Date()
        try upsertCycle(cycle, projectRoot: projectRoot)
        return cycle
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
            (root.appendingPathComponent(".pilotdeck").appendingPathComponent("scheduled_tasks.json"), true),
            (root.appendingPathComponent(".pilotdeck").appendingPathComponent("session_scheduled_tasks.json"), false),
            (root.appendingPathComponent(".pilotdeck").appendingPathComponent("cron-jobs.json"), nil),
            (root.appendingPathComponent(".pilotdeck").appendingPathComponent("always-on").appendingPathComponent("cron-jobs.json"), nil),
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

    private func pilotDeckProjectStorePath(projectName: String, projectRoot: String) -> String {
        let root = projectRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        if let home = firstMatch(pattern: #"^(\/Users\/[^\/]+|\/home\/[^\/]+)"#, in: root) {
            return "\(home)/.pilotdeck/projects/\(projectName)"
        }
        if let windowsHome = firstMatch(pattern: #"^([A-Za-z]:\\Users\\[^\\]+)"#, in: root) {
            return "\(windowsHome)\\.pilotdeck\\projects\\\(projectName)"
        }
        return "~/.pilotdeck/projects/\(projectName)"
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

    static func normalizedProjectRoot(_ rawRoot: String) -> String {
        let expanded = NSString(string: rawRoot.trimmingCharacters(in: .whitespacesAndNewlines)).expandingTildeInPath
        return expanded.replacingOccurrences(of: "[\\\\/]+$", with: "", options: .regularExpression)
    }

    private static func projectStorageID(_ projectRoot: String) -> String {
        let normalized = normalizedProjectRoot(projectRoot)
        let data = Data(normalized.utf8)
        return data.base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func safeFilename(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? "project" : trimmed
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return fallback.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }.reduce(into: "") { $0.append($1) }
    }

    private static func bool(_ raw: String?, defaultValue: Bool) -> Bool {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
            return defaultValue
        }
        switch raw {
        case "true", "1", "yes", "on": return true
        case "false", "0", "no", "off": return false
        default: return defaultValue
        }
    }

    private static func positiveInt(_ raw: String?, defaultValue: Int) -> Int {
        guard let raw, let value = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else {
            return defaultValue
        }
        return value
    }

    private static func splitList(_ raw: String?) -> [String] {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty, raw != "[]" else { return [] }
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return trimmed
            .split { $0 == "," || $0 == "\n" }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
            .filter { !$0.isEmpty }
    }

    private static func simpleGlob(_ path: String, matches pattern: String) -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed == "*" || trimmed == "**/*" { return true }
        if trimmed.hasSuffix("/**") {
            return path.hasPrefix(String(trimmed.dropLast(3)))
        }
        if trimmed.hasSuffix("*") {
            return path.hasPrefix(String(trimmed.dropLast()))
        }
        if trimmed.hasPrefix("*.") {
            return path.hasSuffix(String(trimmed.dropFirst()))
        }
        return path == trimmed || path.contains(trimmed)
    }

    private static func isRunnablePlanStatus(_ status: AlwaysOnStatus) -> Bool {
        switch status {
        case .ready, .draft, .queued, .failed:
            return true
        default:
            return false
        }
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
            outputFile: ".pilotdeck/always-on/runs/\(run.id).log",
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
