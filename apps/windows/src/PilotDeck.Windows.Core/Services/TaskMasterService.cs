using System.Text.Json;

namespace PilotDeck.Windows.Core;

public sealed record TaskMasterSnapshot(
    bool Detected,
    string Root,
    string TasksFile,
    IReadOnlyList<TaskPlan> Tasks);

public sealed class TaskMasterService
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web) { WriteIndented = true };

    public TaskMasterSnapshot Detect(string workspaceRoot)
    {
        var root = PathHelpers.NormalizeFullPath(workspaceRoot);
        var taskRoot = Path.Combine(root, ".taskmaster");
        var tasksFile = Path.Combine(taskRoot, "tasks", "tasks.json");
        var detected = Directory.Exists(taskRoot) || File.Exists(tasksFile) || File.Exists(Path.Combine(root, "taskmaster.config.json"));
        return new TaskMasterSnapshot(detected, taskRoot, tasksFile, detected ? LoadTasks(tasksFile) : []);
    }

    public TaskMasterSnapshot Init(string workspaceRoot)
    {
        var root = PathHelpers.NormalizeFullPath(workspaceRoot);
        var taskRoot = Path.Combine(root, ".taskmaster");
        var tasksDir = Path.Combine(taskRoot, "tasks");
        var tasksFile = Path.Combine(tasksDir, "tasks.json");
        Directory.CreateDirectory(tasksDir);
        if (!File.Exists(tasksFile))
        {
            File.WriteAllText(tasksFile, "[]");
        }

        return Detect(root);
    }

    public TaskPlan AddTask(string workspaceRoot, string title, string prompt)
    {
        var snapshot = Init(workspaceRoot);
        var tasks = snapshot.Tasks.ToList();
        var task = new TaskPlan(Guid.NewGuid(), title.Trim(), prompt, TaskStatus.Queued, DateTimeOffset.UtcNow);
        tasks.Add(task);
        File.WriteAllText(snapshot.TasksFile, JsonSerializer.Serialize(tasks, JsonOptions));
        return task;
    }

    private static IReadOnlyList<TaskPlan> LoadTasks(string tasksFile)
    {
        if (!File.Exists(tasksFile)) return [];
        try
        {
            return JsonSerializer.Deserialize<List<TaskPlan>>(File.ReadAllText(tasksFile), JsonOptions) ?? [];
        }
        catch
        {
            return [];
        }
    }
}
