using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace G9Claw.Windows.Core;

public sealed record AgentToolExecutionContext(
    string SessionId,
    string WorkspaceRoot,
    ChatRunMode RunMode,
    ToolPermissionSettings PermissionSettings,
    CancellationToken CancellationToken);

public sealed class AgentToolExecutor
{
    private readonly WorkspaceService _workspaceService;
    private readonly TerminalService _terminalService;
    private readonly NativeRunStore _runStore;

    public AgentToolExecutor(WorkspaceService? workspaceService = null, TerminalService? terminalService = null, NativeRunStore? runStore = null)
    {
        _workspaceService = workspaceService ?? new WorkspaceService();
        _terminalService = terminalService ?? new TerminalService();
        _runStore = runStore ?? new NativeRunStore();
    }

    public async Task<AgentToolResult> ExecuteAsync(AgentToolCall rawCall, AgentToolExecutionContext context)
    {
        var normalized = ToolArgumentNormalizer.Normalize(rawCall);
        if (normalized.RecoveryResult is not null) return normalized.RecoveryResult;

        var call = normalized.Call;
        try
        {
            return call.Name switch
            {
                "Read" => Read(call, context),
                "Write" => Write(call, context),
                "StrReplace" => StrReplace(call, context),
                "Delete" => Delete(call, context),
                "EditNotebook" => EditNotebook(call, context),
                "Grep" => Grep(call, context),
                "Glob" => Glob(call, context),
                "SemanticSearch" => SemanticSearch(call, context),
                "Shell" => await ShellAsync(call, context),
                "Await" => await AwaitAsync(call, context),
                "ReadLints" => ReadLints(call),
                "Skill" => Skill(call, context),
                "TodoWrite" => TodoWrite(call, context),
                "AskQuestion" => AskQuestion(call),
                "SwitchMode" => SwitchMode(call, context),
                "Task" => await TaskToolAsync(call, context),
                _ => Error(call, $"Unsupported tool: {call.Name}"),
            };
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            return Error(call, ex.Message);
        }
    }

    public static string ValidatedWorkingDirectory(string cwd)
    {
        if (string.IsNullOrWhiteSpace(cwd)) throw new ArgumentException("Working directory is required.", nameof(cwd));
        var expanded = PathHelpers.ExpandHome(cwd.Trim());
        if (!Path.IsPathFullyQualified(expanded)) throw new InvalidOperationException("Working directory must be an absolute path.");
        var full = PathHelpers.NormalizeFullPath(expanded);
        if (!Directory.Exists(full)) throw new DirectoryNotFoundException($"Working directory does not exist: {full}");
        return full;
    }

    private AgentToolResult Read(AgentToolCall call, AgentToolExecutionContext context)
    {
        using var doc = JsonDocument.Parse(call.InputJson);
        var filePath = RequiredString(doc.RootElement, "file_path");
        var resolved = WorkspaceService.ResolveWorkspacePath(filePath, context.WorkspaceRoot);
        if (Directory.Exists(resolved)) return Error(call, "Read expects a file path, not a directory.");
        if (!File.Exists(resolved)) return Error(call, $"File does not exist: {resolved}");

        var offset = OptionalInt(doc.RootElement, "offset") ?? 1;
        var limit = OptionalInt(doc.RootElement, "limit") ?? 400;
        var lines = File.ReadLines(resolved, Encoding.UTF8)
            .Skip(Math.Max(0, offset - 1))
            .Take(Math.Max(1, limit))
            .ToList();
        var header = $"{Path.GetRelativePath(context.WorkspaceRoot, resolved)} ({new FileInfo(resolved).Length} bytes)";
        return Ok(call, $"{header}\n{string.Join(Environment.NewLine, lines)}");
    }

    private AgentToolResult Write(AgentToolCall call, AgentToolExecutionContext context)
    {
        using var doc = JsonDocument.Parse(call.InputJson);
        var filePath = RequiredString(doc.RootElement, "file_path");
        var content = RequiredString(doc.RootElement, "content");
        _workspaceService.WriteFile(filePath, content, context.WorkspaceRoot);
        return Ok(call, $"Wrote {filePath} ({Encoding.UTF8.GetByteCount(content)} bytes).");
    }

    private AgentToolResult StrReplace(AgentToolCall call, AgentToolExecutionContext context)
    {
        using var doc = JsonDocument.Parse(call.InputJson);
        var root = doc.RootElement;
        var filePath = RequiredString(root, "file_path");
        var resolved = WorkspaceService.ResolveWorkspacePath(filePath, context.WorkspaceRoot);
        var text = File.ReadAllText(resolved, Encoding.UTF8);
        var original = text;

        if (root.TryGetProperty("edits", out var edits) && edits.ValueKind == JsonValueKind.Array)
        {
            foreach (var edit in edits.EnumerateArray())
            {
                text = ApplyReplacement(text, RequiredString(edit, "old_string"), RequiredString(edit, "new_string"), OptionalBool(edit, "replace_all") ?? false);
            }
        }
        else
        {
            text = ApplyReplacement(text, RequiredString(root, "old_string"), RequiredString(root, "new_string"), OptionalBool(root, "replace_all") ?? false);
        }

        if (text == original) return Error(call, "No changes were made.");
        File.WriteAllText(resolved, text, Encoding.UTF8);
        return Ok(call, $"Updated {Path.GetRelativePath(context.WorkspaceRoot, resolved)}.");
    }

    private AgentToolResult Delete(AgentToolCall call, AgentToolExecutionContext context)
    {
        using var doc = JsonDocument.Parse(call.InputJson);
        var path = RequiredString(doc.RootElement, "path");
        var recursive = OptionalBool(doc.RootElement, "recursive") ?? false;
        _workspaceService.Delete(path, context.WorkspaceRoot, recursive);
        return Ok(call, $"Deleted {path}.");
    }

    private AgentToolResult EditNotebook(AgentToolCall call, AgentToolExecutionContext context)
    {
        using var doc = JsonDocument.Parse(call.InputJson);
        var root = doc.RootElement;
        var path = RequiredString(root, "notebook_path");
        var resolved = WorkspaceService.ResolveWorkspacePath(path, context.WorkspaceRoot);
        if (!File.Exists(resolved)) return Error(call, $"Notebook does not exist: {resolved}");

        var notebook = JsonNode.Parse(File.ReadAllText(resolved, Encoding.UTF8)) as JsonObject
                       ?? throw new InvalidOperationException("Notebook JSON root must be an object.");
        var cells = notebook["cells"] as JsonArray
                    ?? throw new InvalidOperationException("Notebook does not contain a cells array.");
        var editMode = OptionalString(root, "edit_mode") ?? "replace";
        var cellIndex = ResolveNotebookCellIndex(cells, OptionalInt(root, "cell_number"), OptionalString(root, "cell_id"));

        switch (editMode)
        {
            case "delete":
                if (cellIndex < 0) throw new InvalidOperationException("Target notebook cell was not found.");
                cells.RemoveAt(cellIndex);
                break;
            case "insert":
                var insertAt = cellIndex >= 0 ? cellIndex + 1 : cells.Count;
                cells.Insert(insertAt, CreateNotebookCell(OptionalString(root, "cell_type") ?? "code", OptionalString(root, "new_source") ?? ""));
                break;
            default:
                if (cellIndex < 0) throw new InvalidOperationException("Target notebook cell was not found.");
                var existing = cells[cellIndex] as JsonObject
                               ?? throw new InvalidOperationException("Target notebook cell is not an object.");
                existing["source"] = OptionalString(root, "new_source") ?? "";
                if (OptionalString(root, "cell_type") is { } cellType) existing["cell_type"] = cellType;
                break;
        }

        File.WriteAllText(resolved, notebook.ToJsonString(new JsonSerializerOptions { WriteIndented = true }), Encoding.UTF8);
        return Ok(call, $"Notebook updated: {Path.GetRelativePath(context.WorkspaceRoot, resolved)}.");
    }

    private AgentToolResult Grep(AgentToolCall call, AgentToolExecutionContext context)
    {
        using var doc = JsonDocument.Parse(call.InputJson);
        var root = doc.RootElement;
        var pattern = RequiredString(root, "pattern");
        var basePath = OptionalString(root, "path") ?? context.WorkspaceRoot;
        var resolved = WorkspaceService.ResolveWorkspacePath(basePath, context.WorkspaceRoot);
        var glob = OptionalString(root, "glob") ?? OptionalString(root, "include");
        var outputMode = OptionalString(root, "output_mode") ?? "files_with_matches";
        var headLimit = OptionalInt(root, "head_limit") ?? 100;
        var options = OptionalBool(root, "-i") == true ? RegexOptions.IgnoreCase : RegexOptions.None;
        var regex = new Regex(pattern, options | RegexOptions.Compiled);
        var files = Directory.Exists(resolved) ? EnumerateSearchableFiles(resolved, glob) : [resolved];
        var results = new List<string>();

        foreach (var file in files)
        {
            var lineNumber = 0;
            var fileMatched = false;
            foreach (var line in SafeReadLines(file))
            {
                lineNumber++;
                if (!regex.IsMatch(line)) continue;
                fileMatched = true;
                if (outputMode == "content")
                {
                    results.Add($"{Path.GetRelativePath(context.WorkspaceRoot, file)}:{lineNumber}:{line}");
                }
                if (results.Count >= headLimit) break;
            }

            if (outputMode == "files_with_matches" && fileMatched)
            {
                results.Add(Path.GetRelativePath(context.WorkspaceRoot, file));
            }
            else if (outputMode == "count" && fileMatched)
            {
                results.Add(Path.GetRelativePath(context.WorkspaceRoot, file));
            }
            if (results.Count >= headLimit) break;
        }

        return Ok(call, results.Count == 0 ? "No matches." : string.Join(Environment.NewLine, results));
    }

    private AgentToolResult Glob(AgentToolCall call, AgentToolExecutionContext context)
    {
        using var doc = JsonDocument.Parse(call.InputJson);
        var pattern = RequiredString(doc.RootElement, "pattern");
        var basePath = OptionalString(doc.RootElement, "path") ?? context.WorkspaceRoot;
        var resolved = WorkspaceService.ResolveWorkspacePath(basePath, context.WorkspaceRoot);
        var regex = GlobToRegex(pattern);
        var files = Directory.EnumerateFiles(resolved, "*", SearchOption.AllDirectories)
            .Where(path => regex.IsMatch(Path.GetRelativePath(resolved, path).Replace('\\', '/')))
            .Take(500)
            .Select(path => Path.GetRelativePath(context.WorkspaceRoot, path))
            .ToList();
        return Ok(call, files.Count == 0 ? "No files found." : string.Join(Environment.NewLine, files));
    }

    private AgentToolResult SemanticSearch(AgentToolCall call, AgentToolExecutionContext context)
    {
        using var doc = JsonDocument.Parse(call.InputJson);
        var query = RequiredString(doc.RootElement, "query");
        var limit = OptionalInt(doc.RootElement, "limit") ?? 20;
        var terms = query.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Where(term => term.Length > 2)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToList();
        var scored = EnumerateSearchableFiles(context.WorkspaceRoot, null)
            .Select(path => new { Path = path, Score = ScoreFile(path, terms) })
            .Where(item => item.Score > 0)
            .OrderByDescending(item => item.Score)
            .ThenBy(item => item.Path, StringComparer.OrdinalIgnoreCase)
            .Take(limit)
            .Select(item => $"{Path.GetRelativePath(context.WorkspaceRoot, item.Path)} score={item.Score}");
        return Ok(call, string.Join(Environment.NewLine, scored));
    }

    private async Task<AgentToolResult> ShellAsync(AgentToolCall call, AgentToolExecutionContext context)
    {
        using var doc = JsonDocument.Parse(call.InputJson);
        var command = RequiredString(doc.RootElement, "command");
        var timeout = OptionalInt(doc.RootElement, "timeout") ?? 120_000;
        var cwd = OptionalString(doc.RootElement, "cwd") is { } requestedCwd
            ? WorkspaceService.ResolveWorkspacePath(requestedCwd, context.WorkspaceRoot)
            : context.WorkspaceRoot;
        if (OptionalBool(doc.RootElement, "run_in_background") == true)
        {
            var run = _runStore.StartShellTask(command, cwd, _terminalService, timeout, context.CancellationToken);
            return Ok(call, $"Started background shell task {run.Id}. Use Await with task_id={run.Id} to read output.", taskId: run.Id);
        }

        var result = await _terminalService.RunAsync(command, cwd, timeout, context.CancellationToken);
        return new AgentToolResult(call.Id, call.Name, result.Output, result.ExitCode != 0, Diagnostics: new Dictionary<string, string>
        {
            ["cwd"] = result.Cwd,
            ["exitCode"] = result.ExitCode?.ToString() ?? "",
        });
    }

    private async Task<AgentToolResult> AwaitAsync(AgentToolCall call, AgentToolExecutionContext context)
    {
        using var doc = JsonDocument.Parse(call.InputJson);
        var taskId = RequiredString(doc.RootElement, "task_id");
        var timeout = OptionalInt(doc.RootElement, "timeout") ?? 60_000;
        var run = await _runStore.AwaitAsync(taskId, TimeSpan.FromMilliseconds(timeout), context.CancellationToken);
        if (run is null) return Error(call, $"Unknown task id: {taskId}");
        var output = FormatRunOutput(run);
        return new AgentToolResult(call.Id, call.Name, output, run.Status == TaskStatus.Failed, TaskId: run.Id, Diagnostics: new Dictionary<string, string>
        {
            ["status"] = run.Status.ToString(),
            ["kind"] = run.Kind,
            ["cwd"] = run.Cwd,
            ["exitCode"] = run.ExitCode?.ToString() ?? "",
        });
    }

    private static AgentToolResult ReadLints(AgentToolCall call) =>
        Ok(call, "No native diagnostics provider is attached yet.");

    private AgentToolResult Skill(AgentToolCall call, AgentToolExecutionContext context)
    {
        using var doc = JsonDocument.Parse(call.InputJson);
        var skill = OptionalString(doc.RootElement, "skill") ?? OptionalString(doc.RootElement, "name") ?? "";
        var args = OptionalString(doc.RootElement, "args") ?? OptionalString(doc.RootElement, "query") ?? "";
        if (string.IsNullOrWhiteSpace(skill)) return Error(call, "Skill requires a skill name.");

        var service = new SkillService();
        var record = service.Resolve(skill, context.WorkspaceRoot);
        if (record is null) return Error(call, $"Skill not found: {skill}");
        var content = service.Read(record);
        var limited = content.Length > 24_000 ? content[..24_000] + "\n\n[truncated]" : content;
        var output = new StringBuilder()
            .AppendLine($"Skill: {record.Name} ({record.Slug})")
            .AppendLine($"Scope: {record.Scope}")
            .AppendLine($"Path: {record.SkillFile}");
        if (!string.IsNullOrWhiteSpace(args))
        {
            output.AppendLine($"Args: {args.Trim()}");
        }

        output.AppendLine()
            .Append(limited);
        return Ok(call, output.ToString(), artifactPath: record.SkillFile);
    }

    private AgentToolResult TodoWrite(AgentToolCall call, AgentToolExecutionContext context)
    {
        using var doc = JsonDocument.Parse(call.InputJson);
        if (!doc.RootElement.TryGetProperty("todos", out var todosElement) || todosElement.ValueKind != JsonValueKind.Array)
        {
            return Error(call, "TodoWrite requires a todos array.");
        }

        var todos = todosElement.EnumerateArray()
            .Select((todo, index) => new NativeTodoItem(
                FirstString(todo, ["content", "text", "title"]) ?? todo.ToString(),
                FirstString(todo, ["status", "state"]) ?? "pending",
                OptionalInt(todo, "priority") ?? index + 1))
            .Where(todo => !string.IsNullOrWhiteSpace(todo.Content))
            .ToList();
        _runStore.ReplaceTodos(context.SessionId, todos);
        return Ok(call, $"Saved {todos.Count} todo item(s) for session {context.SessionId}.");
    }

    private static AgentToolResult AskQuestion(AgentToolCall call) =>
        Error(call, "AskQuestion requires a user answer before continuing.");

    private static AgentToolResult SwitchMode(AgentToolCall call, AgentToolExecutionContext context)
    {
        using var doc = JsonDocument.Parse(call.InputJson);
        var mode = OptionalString(doc.RootElement, "mode") ?? (context.RunMode == ChatRunMode.Plan ? "agent" : "plan");
        return Ok(call, $"SwitchMode accepted: {mode}.");
    }

    private async Task<AgentToolResult> TaskToolAsync(AgentToolCall call, AgentToolExecutionContext context)
    {
        using var doc = JsonDocument.Parse(call.InputJson);
        var root = doc.RootElement;
        var type = OptionalString(root, "type") ?? "generalPurpose";
        var prompt = RequiredString(root, "prompt");
        var description = OptionalString(root, "description") ?? prompt.Split('\n').FirstOrDefault() ?? type;
        var cwd = OptionalString(root, "cwd") is { } requestedCwd
            ? WorkspaceService.ResolveWorkspacePath(requestedCwd, context.WorkspaceRoot)
            : context.WorkspaceRoot;
        var background = OptionalBool(root, "run_in_background") ?? true;
        var timeout = OptionalInt(root, "timeout") ?? 120_000;

        if (type.Equals("shell", StringComparison.OrdinalIgnoreCase))
        {
            if (background)
            {
                var run = _runStore.StartShellTask(prompt, cwd, _terminalService, timeout, context.CancellationToken);
                return Ok(call, $"Started shell task {run.Id}: {description}", taskId: run.Id);
            }

            var result = await _terminalService.RunAsync(prompt, cwd, timeout, context.CancellationToken);
            return new AgentToolResult(call.Id, call.Name, result.Output, result.ExitCode != 0, Diagnostics: new Dictionary<string, string>
            {
                ["taskType"] = type,
                ["cwd"] = cwd,
                ["exitCode"] = result.ExitCode?.ToString() ?? "",
            });
        }

        var output = $"Recorded {type} task: {description}\n\n{prompt}";
        var task = _runStore.CreateRecordedTask(type, description, cwd, output);
        return Ok(call, output, taskId: task.Id);
    }

    private static AgentToolResult Ok(AgentToolCall call, string output, string? artifactPath = null, string? taskId = null) =>
        new(call.Id, call.Name, output, false, artifactPath, taskId);

    private static AgentToolResult Error(AgentToolCall call, string output) => new(call.Id, call.Name, output, true);

    private static string FormatRunOutput(NativeBackgroundRun run)
    {
        var builder = new StringBuilder()
            .AppendLine($"{run.Kind} {run.Id}: {run.Status}")
            .AppendLine($"cwd: {run.Cwd}");
        if (run.ExitCode is not null) builder.AppendLine($"exit: {run.ExitCode}");
        if (!string.IsNullOrWhiteSpace(run.Error)) builder.AppendLine($"error: {run.Error}");
        builder.AppendLine()
            .Append(string.IsNullOrWhiteSpace(run.Output) ? "(no output yet)" : run.Output);
        return builder.ToString();
    }

    private static string ApplyReplacement(string text, string oldString, string newString, bool replaceAll)
    {
        if (string.IsNullOrEmpty(oldString)) throw new InvalidOperationException("old_string is required.");
        var count = CountOccurrences(text, oldString);
        if (count == 0) throw new InvalidOperationException("old_string was not found.");
        if (!replaceAll && count > 1) throw new InvalidOperationException("old_string occurs multiple times. Set replace_all=true or provide a more specific string.");
        return replaceAll ? text.Replace(oldString, newString) : ReplaceFirst(text, oldString, newString);
    }

    private static int CountOccurrences(string text, string needle)
    {
        var count = 0;
        var index = 0;
        while ((index = text.IndexOf(needle, index, StringComparison.Ordinal)) >= 0)
        {
            count++;
            index += needle.Length;
        }
        return count;
    }

    private static string ReplaceFirst(string text, string oldString, string newString)
    {
        var index = text.IndexOf(oldString, StringComparison.Ordinal);
        return index < 0 ? text : text[..index] + newString + text[(index + oldString.Length)..];
    }

    private static IEnumerable<string> EnumerateSearchableFiles(string root, string? glob)
    {
        var regex = string.IsNullOrWhiteSpace(glob) ? null : GlobToRegex(glob);
        return Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories)
            .Where(path => !Path.GetRelativePath(root, path).Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar).Any(IsHiddenOrBuildDir))
            .Where(path => regex is null || regex.IsMatch(Path.GetFileName(path)) || regex.IsMatch(Path.GetRelativePath(root, path).Replace('\\', '/')));
    }

    private static bool IsHiddenOrBuildDir(string segment) =>
        segment is ".git" or "node_modules" or "dist" or "build" or "bin" or "obj";

    private static IEnumerable<string> SafeReadLines(string path)
    {
        if (new FileInfo(path).Length > 1_000_000) yield break;
        IEnumerable<string> lines;
        try
        {
            lines = File.ReadLines(path, Encoding.UTF8);
        }
        catch
        {
            yield break;
        }

        foreach (var line in lines) yield return line;
    }

    private static int ScoreFile(string path, IReadOnlyList<string> terms)
    {
        if (terms.Count == 0) return 0;
        string text;
        try
        {
            if (new FileInfo(path).Length > 500_000) return 0;
            text = File.ReadAllText(path, Encoding.UTF8);
        }
        catch
        {
            return 0;
        }

        return terms.Sum(term => Regex.Matches(text, Regex.Escape(term), RegexOptions.IgnoreCase).Count);
    }

    private static Regex GlobToRegex(string pattern)
    {
        var normalized = pattern.Replace('\\', '/');
        var builder = new StringBuilder("^");
        for (var i = 0; i < normalized.Length; i++)
        {
            var ch = normalized[i];
            if (ch == '*')
            {
                if (i + 1 < normalized.Length && normalized[i + 1] == '*')
                {
                    builder.Append(".*");
                    i++;
                }
                else
                {
                    builder.Append("[^/]*");
                }
            }
            else if (ch == '?')
            {
                builder.Append("[^/]");
            }
            else
            {
                builder.Append(Regex.Escape(ch.ToString()));
            }
        }
        builder.Append('$');
        return new Regex(builder.ToString(), RegexOptions.IgnoreCase | RegexOptions.Compiled);
    }

    private static string RequiredString(JsonElement root, string key)
    {
        var value = OptionalString(root, key);
        if (string.IsNullOrWhiteSpace(value)) throw new InvalidOperationException($"{key} is required.");
        return value;
    }

    private static string? OptionalString(JsonElement root, string key)
    {
        return root.TryGetProperty(key, out var value)
            ? value.ValueKind == JsonValueKind.String ? value.GetString() : value.ToString()
            : null;
    }

    private static string? FirstString(JsonElement root, IReadOnlyList<string> keys)
    {
        foreach (var key in keys)
        {
            if (OptionalString(root, key) is { } value && !string.IsNullOrWhiteSpace(value)) return value;
        }

        return null;
    }

    private static int? OptionalInt(JsonElement root, string key)
    {
        if (!root.TryGetProperty(key, out var value)) return null;
        if (value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var number)) return number;
        return int.TryParse(value.ToString(), out var parsed) ? parsed : null;
    }

    private static bool? OptionalBool(JsonElement root, string key)
    {
        if (!root.TryGetProperty(key, out var value)) return null;
        return value.ValueKind switch
        {
            JsonValueKind.True => true,
            JsonValueKind.False => false,
            JsonValueKind.String when bool.TryParse(value.GetString(), out var parsed) => parsed,
            _ => null,
        };
    }

    private static int ResolveNotebookCellIndex(JsonArray cells, int? cellNumber, string? cellId)
    {
        if (cellNumber is int index) return index >= 0 && index < cells.Count ? index : -1;
        if (string.IsNullOrWhiteSpace(cellId)) return -1;

        for (var i = 0; i < cells.Count; i++)
        {
            if (cells[i] is JsonObject cell &&
                cell["id"]?.GetValue<string>() == cellId)
            {
                return i;
            }
        }

        return -1;
    }

    private static JsonObject CreateNotebookCell(string cellType, string source)
    {
        var cell = new JsonObject
        {
            ["cell_type"] = cellType is "markdown" ? "markdown" : "code",
            ["metadata"] = new JsonObject(),
            ["source"] = source,
        };
        if (cell["cell_type"]?.GetValue<string>() == "code")
        {
            cell["execution_count"] = null;
            cell["outputs"] = new JsonArray();
        }

        return cell;
    }
}
