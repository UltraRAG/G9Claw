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

    func upsert(name: String, summary: String, projectName: String?) -> MemoryRecord {
        if let index = records.firstIndex(where: { $0.name == name && $0.projectName == projectName }) {
            records[index].summary = summary
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
            deprecated: false
        )
        records.insert(record, at: 0)
        return record
    }

    func loadWorkspaceRecords(projectRoot: String?, projectName: String?) {
        guard let projectRoot else { return }
        let memoryRoot = URL(fileURLWithPath: projectRoot)
            .appendingPathComponent(".edgeclaw")
            .appendingPathComponent("memory")
        let claudeMemoryRoot = URL(fileURLWithPath: projectRoot)
            .appendingPathComponent(".claude")
            .appendingPathComponent("memory")
        let roots = [memoryRoot, claudeMemoryRoot]
        var loaded: [MemoryRecord] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
                let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                loaded.append(
                    MemoryRecord(
                        id: UUID(),
                        name: url.deletingPathExtension().lastPathComponent,
                        summary: Self.preview(content),
                        projectName: projectName,
                        updatedAt: values?.contentModificationDate ?? Date(),
                        type: content.lowercased().contains("feedback") ? .feedback : .project,
                        relativePath: url.path.replacingOccurrences(of: projectRoot + "/", with: ""),
                        deprecated: content.lowercased().contains("deprecated: true")
                    )
                )
            }
        }
        if !loaded.isEmpty {
            records = merge(loaded, into: records)
        }
    }

    func search(_ query: String) -> [MemoryRecord] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let visible = records.sorted { $0.updatedAt > $1.updatedAt }
        guard !normalized.isEmpty else { return visible }
        return visible.filter {
            $0.name.lowercased().contains(normalized) ||
            $0.summary.lowercased().contains(normalized) ||
            $0.relativePath.lowercased().contains(normalized) ||
            ($0.projectName?.lowercased().contains(normalized) ?? false)
        }
    }

    func dashboard(query: String = "", projectName: String? = nil) -> MemoryDashboardSnapshot {
        let filtered = search(query).filter { projectName == nil || $0.projectName == projectName || $0.projectName == nil }
        let active = filtered.filter { !$0.deprecated }
        return MemoryDashboardSnapshot(
            totalEntries: active.count,
            projectEntries: active.filter { $0.type == .project }.count,
            feedbackEntries: active.filter { $0.type == .feedback }.count,
            latestMemoryAt: active.map(\.updatedAt).max(),
            records: filtered,
            userSummary: active.prefix(5).map { "- \($0.name): \($0.summary)" }.joined(separator: "\n"),
            caseTraces: [],
            indexTraces: ["Native memory index ready"],
            dreamTraces: []
        )
    }

    func clear(projectName: String?) {
        records.removeAll { projectName == nil || $0.projectName == projectName }
    }

    private func merge(_ incoming: [MemoryRecord], into current: [MemoryRecord]) -> [MemoryRecord] {
        var byPath = Dictionary(uniqueKeysWithValues: current.map { ("\($0.projectName ?? ""):\($0.relativePath)", $0) })
        for record in incoming {
            byPath["\(record.projectName ?? ""):\(record.relativePath)"] = record
        }
        return Array(byPath.values).sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func preview(_ content: String) -> String {
        content
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") }?
            .prefix(240)
            .description ?? "Memory record"
    }
}

final class SkillsService {
    private(set) var skills: [SkillRecord] = []

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
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
    }

    static func projectSkillsRoot(_ projectPath: String) -> URL {
        URL(fileURLWithPath: projectPath)
            .appendingPathComponent(".claude", isDirectory: true)
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
}

final class RoutingService {
    private var tokenRecords: [String: RoutingDashboardSession] = [:]

    func recordTokens(
        sessionID: String,
        title: String,
        projectName: String,
        model: String,
        totalTokens: Int,
        contextWindow: Int
    ) {
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "unknown" : model
        let cost = estimatedCost(model: normalizedModel, tokens: totalTokens)
        let bucket = RoutingBucket(count: 1, inputTokens: totalTokens, outputTokens: 0, estimatedCost: cost)
        tokenRecords[sessionID] = RoutingDashboardSession(
            id: sessionID,
            title: title,
            projectName: projectName,
            lastActiveAt: Date(),
            totalTokens: totalTokens,
            estimatedCost: cost,
            savedCost: 0,
            byTier: ["COMPLEX": bucket],
            byModel: [normalizedModel: bucket],
            requestLog: [
                "\(DateFormatter.routingTime.string(from: Date())) \(normalizedModel) routed as COMPLEX · \(totalTokens)/\(contextWindow) tokens"
            ]
        )
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
        }.sorted { $0.lastActiveAt > $1.lastActiveAt }
        return RoutingDashboardSnapshot(
            totalProjects: filtered.count,
            totalSessions: sessions.count,
            routedSessions: sessions.filter { !$0.byModel.isEmpty || !$0.byTier.isEmpty }.count,
            totalTokens: sessions.reduce(0) { $0 + $1.totalTokens },
            estimatedCost: sessions.reduce(0) { $0 + $1.estimatedCost },
            savedCost: sessions.reduce(0) { $0 + $1.savedCost },
            recentSessions: Array(sessions.prefix(40))
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
}

private extension DateFormatter {
    static let routingTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

final class AlwaysOnService {
    func plans(projectRoot: String) -> [AlwaysOnPlan] {
        let indexURL = URL(fileURLWithPath: projectRoot)
            .appendingPathComponent(".claude")
            .appendingPathComponent("always-on")
            .appendingPathComponent("discovery-plans.json")
        guard
            let data = try? Data(contentsOf: indexURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawPlans = json["plans"] as? [[String: Any]]
        else { return [] }
        return rawPlans.compactMap { raw in
            let id = string(raw["id"], fallback: UUID().uuidString)
            let relativePlanPath = string(raw["planFilePath"], fallback: ".claude/always-on/plans/\(id).md")
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
                createdAt: date(raw["createdAt"]) ?? Date(),
                updatedAt: date(raw["updatedAt"]) ?? Date(),
                executionSessionId: optionalString(raw["executionSessionId"]),
                executionStatus: AlwaysOnStatus(rawValue: string(raw["executionStatus"]))
            )
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    func runHistory(projectRoot: String) -> [AlwaysOnRunHistory] {
        let historyURL = URL(fileURLWithPath: projectRoot)
            .appendingPathComponent(".claude")
            .appendingPathComponent("always-on")
            .appendingPathComponent("run-history.jsonl")
        guard let raw = try? String(contentsOf: historyURL, encoding: .utf8) else { return [] }
        return raw.split(separator: "\n").compactMap { line in
            guard
                let data = String(line).data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            let runId = string(json["runId"], fallback: string(json["id"], fallback: UUID().uuidString))
            let logURL = URL(fileURLWithPath: projectRoot)
                .appendingPathComponent(".claude")
                .appendingPathComponent("always-on")
                .appendingPathComponent("runs")
                .appendingPathComponent("\(runId).log")
            return AlwaysOnRunHistory(
                id: runId,
                title: string(json["title"], fallback: string(json["sourceId"], fallback: "Run")),
                kind: string(json["kind"], fallback: "plan"),
                status: AlwaysOnStatus(rawValue: string(json["status"], fallback: "unknown")) ?? .unknown,
                startedAt: date(json["startedAt"]) ?? Date(),
                sourceId: string(json["sourceId"]),
                outputLog: (try? String(contentsOf: logURL, encoding: .utf8)) ?? string(json["outputLog"]),
                sessionId: optionalString(json["sessionId"])
            )
        }
        .sorted { $0.startedAt > $1.startedAt }
    }

    func cronJobs(projectRoot: String) -> [AlwaysOnCronJob] {
        let possible = [
            URL(fileURLWithPath: projectRoot).appendingPathComponent(".claude").appendingPathComponent("cron-jobs.json"),
            URL(fileURLWithPath: projectRoot).appendingPathComponent(".claude").appendingPathComponent("always-on").appendingPathComponent("cron-jobs.json"),
        ]
        guard
            let url = possible.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data)
        else { return [] }
        let rawJobs: [[String: Any]]
        if let list = json as? [[String: Any]] {
            rawJobs = list
        } else if let dict = json as? [String: Any], let jobs = dict["jobs"] as? [[String: Any]] {
            rawJobs = jobs
        } else {
            rawJobs = []
        }
        return rawJobs.map { raw in
            AlwaysOnCronJob(
                id: string(raw["id"], fallback: string(raw["taskId"], fallback: UUID().uuidString)),
                prompt: string(raw["prompt"]),
                cron: string(raw["cron"]),
                status: AlwaysOnStatus(rawValue: string(raw["status"], fallback: "unknown")) ?? .unknown,
                recurring: bool(raw["recurring"], fallback: true),
                durable: bool(raw["durable"], fallback: true),
                createdAt: date(raw["createdAt"]),
                lastFiredAt: date(raw["lastFiredAt"]),
                latestSessionId: optionalString((raw["latestRun"] as? [String: Any])?["sessionId"])
            )
        }
    }

    func archive(plan: AlwaysOnPlan, projectRoot: String) throws {
        try updatePlanStatus(planID: plan.id, projectRoot: projectRoot, status: "superseded")
    }

    func markPlanRunning(plan: AlwaysOnPlan, projectRoot: String) throws {
        try updatePlanStatus(planID: plan.id, projectRoot: projectRoot, status: "running")
    }

    private func updatePlanStatus(planID: String, projectRoot: String, status: String) throws {
        let indexURL = URL(fileURLWithPath: projectRoot)
            .appendingPathComponent(".claude")
            .appendingPathComponent("always-on")
            .appendingPathComponent("discovery-plans.json")
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
}

private extension DateFormatter {
    static let localizedStringDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"
        return formatter
    }()
}
