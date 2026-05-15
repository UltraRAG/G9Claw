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
        let record = MemoryRecord(id: UUID(), name: name, summary: summary, projectName: projectName, updatedAt: Date())
        records.insert(record, at: 0)
        return record
    }

    func search(_ query: String) -> [MemoryRecord] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return records }
        return records.filter {
            $0.name.lowercased().contains(normalized) ||
            $0.summary.lowercased().contains(normalized) ||
            ($0.projectName?.lowercased().contains(normalized) ?? false)
        }
    }
}

final class SkillsService {
    private(set) var skills: [SkillRecord] = [
        SkillRecord(id: UUID(), name: "imagegen", description: "Generate or edit raster images.", enabled: true),
        SkillRecord(id: UUID(), name: "openai-docs", description: "Use official OpenAI documentation.", enabled: true),
        SkillRecord(id: UUID(), name: "github", description: "Repository, PR, and CI workflows.", enabled: false),
    ]

    func setEnabled(_ skill: SkillRecord, enabled: Bool) {
        guard let index = skills.firstIndex(where: { $0.id == skill.id }) else { return }
        skills[index].enabled = enabled
    }
}
