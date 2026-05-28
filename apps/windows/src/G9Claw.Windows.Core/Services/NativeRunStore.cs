using System.Collections.Concurrent;
using System.Text.Json;

namespace G9Claw.Windows.Core;

public sealed record NativeTodoItem(
    string Content,
    string Status,
    int Priority);

public sealed record NativeBackgroundRun(
    string Id,
    string Kind,
    string Description,
    string Cwd,
    string Output,
    TaskStatus Status,
    int? ExitCode,
    DateTimeOffset StartedAt,
    DateTimeOffset? CompletedAt,
    string? Error);

public sealed class NativeRunStore
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web) { WriteIndented = true };
    private readonly ConcurrentDictionary<string, NativeBackgroundRun> _runs = new(StringComparer.OrdinalIgnoreCase);
    private readonly ConcurrentDictionary<string, List<NativeTodoItem>> _todos = new(StringComparer.OrdinalIgnoreCase);
    private readonly ConcurrentDictionary<string, string> _todoJson = new(StringComparer.OrdinalIgnoreCase);
    private readonly string _directory;

    public NativeRunStore(string? directory = null)
    {
        _directory = directory ?? AppPaths.EnsureCreated().RunHistoryDirectory;
    }

    public IReadOnlyList<NativeBackgroundRun> Runs =>
        _runs.Values.OrderByDescending(run => run.StartedAt).ToList();

    public IReadOnlyList<NativeTodoItem> Todos(string sessionId) =>
        _todos.TryGetValue(sessionId, out var todos) ? todos.ToList() : [];

    public void ReplaceTodos(string sessionId, IEnumerable<NativeTodoItem> todos, string? todosJson = null)
    {
        var todoList = todos.ToList();
        _todos[sessionId] = todoList;
        _todoJson[sessionId] = string.IsNullOrWhiteSpace(todosJson)
            ? JsonSerializer.Serialize(todoList, JsonOptions)
            : todosJson;
        PersistTodos(sessionId, todoList);
        PersistTodosJson(sessionId, _todoJson[sessionId]);
    }

    public IReadOnlyList<NativeTodoItem> LoadTodos(string sessionId)
    {
        if (_todos.TryGetValue(sessionId, out var cached)) return cached.ToList();
        var file = TodoFile(sessionId);
        if (!File.Exists(file)) return [];
        try
        {
            var loaded = JsonSerializer.Deserialize<List<NativeTodoItem>>(File.ReadAllText(file), JsonOptions) ?? [];
            _todos[sessionId] = loaded;
            return loaded;
        }
        catch
        {
            return [];
        }
    }

    public string LoadTodosJson(string sessionId)
    {
        if (_todoJson.TryGetValue(sessionId, out var cached)) return cached;
        var file = TodoJsonFile(sessionId);
        if (File.Exists(file))
        {
            var loaded = File.ReadAllText(file);
            _todoJson[sessionId] = loaded;
            return loaded;
        }

        var todos = LoadTodos(sessionId);
        var json = JsonSerializer.Serialize(todos, JsonOptions);
        _todoJson[sessionId] = json;
        return json;
    }

    public NativeBackgroundRun CreateRecordedTask(string kind, string description, string cwd, string output, TaskStatus status = TaskStatus.Completed, string? error = null)
    {
        var now = DateTimeOffset.UtcNow;
        var run = new NativeBackgroundRun(
            $"task-{Guid.NewGuid():D}",
            kind,
            string.IsNullOrWhiteSpace(description) ? kind : description.Trim(),
            cwd,
            output,
            status,
            status == TaskStatus.Completed ? 0 : null,
            now,
            status is TaskStatus.Completed or TaskStatus.Failed ? now : null,
            error);
        _runs[run.Id] = run;
        return run;
    }

    public NativeBackgroundRun StartRecordedTask(
        string kind,
        string description,
        string cwd,
        string output,
        CancellationToken cancellationToken)
    {
        var id = $"task-{Guid.NewGuid():D}";
        var started = new NativeBackgroundRun(
            id,
            kind,
            string.IsNullOrWhiteSpace(description) ? kind : description.Trim(),
            cwd,
            "",
            TaskStatus.Running,
            null,
            DateTimeOffset.UtcNow,
            null,
            null);
        _runs[id] = started;

        _ = Task.Run(() =>
        {
            if (cancellationToken.IsCancellationRequested)
            {
                _runs[id] = started with
                {
                    Output = "Task was cancelled.",
                    Status = TaskStatus.Failed,
                    ExitCode = -1,
                    CompletedAt = DateTimeOffset.UtcNow,
                    Error = "Cancelled.",
                };
                return;
            }

            _runs[id] = started with
            {
                Output = output,
                Status = TaskStatus.Completed,
                ExitCode = 0,
                CompletedAt = DateTimeOffset.UtcNow,
            };
        }, CancellationToken.None);

        return started;
    }

    public NativeBackgroundRun StartShellTask(
        string command,
        string cwd,
        TerminalService terminalService,
        int timeoutMs,
        CancellationToken cancellationToken,
        IReadOnlyDictionary<string, string>? environment = null)
    {
        var id = $"task-{Guid.NewGuid():D}";
        var started = new NativeBackgroundRun(
            id,
            "shell",
            command,
            cwd,
            "",
            TaskStatus.Running,
            null,
            DateTimeOffset.UtcNow,
            null,
            null);
        _runs[id] = started;

        _ = Task.Run(async () =>
        {
            try
            {
                var result = await terminalService.RunAsync(command, cwd, timeoutMs, cancellationToken, environment);
                _runs[id] = started with
                {
                    Output = result.Output,
                    Status = result.ExitCode == 0 ? TaskStatus.Completed : TaskStatus.Failed,
                    ExitCode = result.ExitCode,
                    CompletedAt = DateTimeOffset.UtcNow,
                    Error = result.ExitCode == 0 ? null : $"Process exited with code {result.ExitCode}.",
                };
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                _runs[id] = started with
                {
                    Output = ex.Message,
                    Status = TaskStatus.Failed,
                    ExitCode = -1,
                    CompletedAt = DateTimeOffset.UtcNow,
                    Error = ex.Message,
                };
            }
            catch (OperationCanceledException)
            {
                _runs[id] = started with
                {
                    Output = "Task was cancelled.",
                    Status = TaskStatus.Failed,
                    ExitCode = -1,
                    CompletedAt = DateTimeOffset.UtcNow,
                    Error = "Cancelled.",
                };
            }
        }, CancellationToken.None);

        return started;
    }

    public NativeBackgroundRun? Snapshot(string taskId) =>
        _runs.TryGetValue(taskId, out var run) ? run : null;

    public async Task<NativeBackgroundRun?> AwaitAsync(string taskId, TimeSpan timeout, CancellationToken cancellationToken)
    {
        var until = DateTimeOffset.UtcNow + timeout;
        while (DateTimeOffset.UtcNow < until)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (Snapshot(taskId) is { } run && run.Status != TaskStatus.Running) return run;
            await Task.Delay(150, cancellationToken);
        }

        return Snapshot(taskId);
    }

    private void PersistTodos(string sessionId, IReadOnlyList<NativeTodoItem> todos)
    {
        var file = TodoFile(sessionId);
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        File.WriteAllText(file, JsonSerializer.Serialize(todos, JsonOptions));
    }

    private void PersistTodosJson(string sessionId, string todosJson)
    {
        var file = TodoJsonFile(sessionId);
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        File.WriteAllText(file, todosJson);
    }

    private string TodoFile(string sessionId) =>
        Path.Combine(_directory, "todos", $"{PathHelpers.SafeFileToken(sessionId)}.json");

    private string TodoJsonFile(string sessionId) =>
        Path.Combine(_directory, "todos-json", $"{PathHelpers.SafeFileToken(sessionId)}.json");
}
