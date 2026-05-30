using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using UglyToad.PdfPig;
using UglyToad.PdfPig.DocumentLayoutAnalysis.TextExtractor;

namespace G9Claw.Windows.Core;

public sealed record AgentToolExecutionContext(
    string SessionId,
    string WorkspaceRoot,
    ChatRunMode RunMode,
    ToolPermissionSettings PermissionSettings,
    CancellationToken CancellationToken,
    IReadOnlyDictionary<string, string>? NativeConfigValues = null,
    int SubagentDepth = 0,
    int? MaxSubagentDepth = null,
    ProviderConfig? ProviderConfig = null,
    string? ApiKey = null,
    int TimeoutMs = 120_000,
    int ContextWindow = 160_000,
    ComposerPermissionMode PermissionMode = ComposerPermissionMode.Default);

public sealed class AgentToolExecutor
{
    private readonly WorkspaceService _workspaceService;
    private readonly TerminalService _terminalService;
    private readonly NativeRunStore _runStore;
    private readonly INativeSubagentRunner _subagentRunner;
    private readonly bool _preferRipgrep;

    public AgentToolExecutor(WorkspaceService? workspaceService = null, TerminalService? terminalService = null, NativeRunStore? runStore = null, INativeSubagentRunner? subagentRunner = null, bool preferRipgrep = true)
    {
        _workspaceService = workspaceService ?? new WorkspaceService();
        _terminalService = terminalService ?? new TerminalService();
        _runStore = runStore ?? new NativeRunStore();
        _subagentRunner = subagentRunner ?? new ProviderNativeSubagentRunner();
        _preferRipgrep = preferRipgrep;
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
                "WebFetch" => Ok(call, "WebFetch is disabled. Use Skill with g9claw-rag:rag-research for source-grounded web evidence."),
                "ReadLints" => await ReadLintsAsync(call, context),
                "Skill" => Skill(call, context),
                "TodoRead" => TodoRead(call, context),
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

        var extension = Path.GetExtension(resolved).TrimStart('.').ToLowerInvariant();
        if (extension == "ipynb")
        {
            return Ok(call, ReadNotebook(resolved, context.WorkspaceRoot));
        }

        if (extension == "pdf")
        {
            return Ok(call, ReadPdf(resolved, context.WorkspaceRoot, OptionalString(doc.RootElement, "pages")));
        }

        if (ImageMimeType(extension) is not null)
        {
            return Ok(call, ReadImage(resolved, context.WorkspaceRoot, extension));
        }

        var offset = OptionalInt(doc.RootElement, "offset") ?? 1;
        WorkspaceTextFileRead fileContent;
        try
        {
            fileContent = _workspaceService.ReadTextFile(filePath, workspaceRoot: context.WorkspaceRoot);
        }
        catch (WorkspaceFileReadException exception)
        {
            return Error(call, exception.Message);
        }

        using var reader = new StringReader(fileContent.Content);
        var allLines = new List<string>();
        while (reader.ReadLine() is { } line)
        {
            allLines.Add(line);
        }

        var lineOffset = Math.Max(0, offset - 1);
        var limit = OptionalInt(doc.RootElement, "limit") ?? Math.Min(allLines.Count, 2_000);
        var lines = allLines
            .Skip(lineOffset)
            .Take(Math.Max(1, limit))
            .Select((line, index) => $"{lineOffset + index + 1}: {line}")
            .ToList();
        return Ok(call, string.Join(Environment.NewLine, lines));
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
        if (_preferRipgrep && TryRunRipgrep(root, pattern, resolved, context.WorkspaceRoot) is { } rgOutput)
        {
            return Ok(call, rgOutput);
        }

        var glob = OptionalString(root, "glob") ?? OptionalString(root, "include");
        var includeRegex = string.IsNullOrWhiteSpace(glob) ? null : GlobToRegex(glob);
        var outputMode = OptionalString(root, "output_mode") ?? "files_with_matches";
        var headLimit = OptionalInt(root, "head_limit") ?? 250;
        var offset = Math.Max(0, OptionalInt(root, "offset") ?? 0);
        var contextLines = Math.Max(0, OptionalInt(root, "context") ?? OptionalInt(root, "-C") ?? 0);
        var beforeLines = Math.Max(0, OptionalInt(root, "-B") ?? contextLines);
        var afterLines = Math.Max(0, OptionalInt(root, "-A") ?? contextLines);
        var options = OptionalBool(root, "-i") == true ? RegexOptions.IgnoreCase : RegexOptions.None;
        var regex = new Regex(pattern, options | RegexOptions.Compiled);
        var files = Directory.Exists(resolved) ? EnumerateSearchableFiles(resolved, null) : [resolved];
        var results = new List<string>();
        var counts = new SortedDictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        var seenFiles = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (var file in files)
        {
            var relative = RelativeWorkspacePath(context.WorkspaceRoot, file);
            if (includeRegex is not null && !includeRegex.IsMatch(relative)) continue;
            var lines = SafeReadLines(file).ToList();
            var emittedContextLines = new HashSet<int>();
            for (var index = 0; index < lines.Count; index++)
            {
                var line = lines[index];
                if (!regex.IsMatch(line)) continue;
                counts[relative] = counts.GetValueOrDefault(relative) + 1;
                switch (outputMode)
                {
                    case "content":
                        AppendGrepContentLines(results, emittedContextLines, relative, lines, index, beforeLines, afterLines);
                        break;
                    case "count":
                        break;
                    default:
                        if (seenFiles.Add(relative))
                        {
                            results.Add(relative);
                        }
                        break;
                }
            }
        }

        if (outputMode == "count")
        {
            results = counts.Select(item => $"{item.Key}:{item.Value}").ToList();
        }

        var sliced = SliceToolOutput(results, offset, headLimit);
        return Ok(call, sliced.Count == 0 ? $"No matches for {pattern}." : string.Join(Environment.NewLine, sliced));
    }

    private static string? TryRunRipgrep(JsonElement input, string pattern, string searchRoot, string workspaceRoot)
    {
        var executable = FindExecutable("rg");
        if (executable is null) return null;

        var startInfo = new ProcessStartInfo
        {
            FileName = executable,
            WorkingDirectory = workspaceRoot,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        foreach (var argument in RipgrepArguments(input, pattern, searchRoot))
        {
            startInfo.ArgumentList.Add(argument);
        }

        try
        {
            using var process = new Process { StartInfo = startInfo };
            if (!process.Start()) return null;
            var stdout = process.StandardOutput.ReadToEndAsync();
            var stderr = process.StandardError.ReadToEndAsync();
            if (!process.WaitForExit(30_000))
            {
                try { process.Kill(entireProcessTree: true); }
                catch { }
                return null;
            }

            _ = stderr.GetAwaiter().GetResult();
            if (process.ExitCode != 0 && process.ExitCode != 1) return null;

            var normalized = stdout.GetAwaiter().GetResult()
                .Replace("\r\n", "\n")
                .Split('\n', StringSplitOptions.RemoveEmptyEntries)
                .Select(line => NormalizeRipgrepLine(line, workspaceRoot))
                .ToList();
            var offset = Math.Max(0, OptionalInt(input, "offset") ?? 0);
            var headLimit = OptionalInt(input, "head_limit") ?? 250;
            var sliced = SliceToolOutput(normalized, offset, headLimit);
            return sliced.Count == 0 ? $"No matches for {pattern}." : string.Join(Environment.NewLine, sliced);
        }
        catch
        {
            return null;
        }
    }

    internal static IReadOnlyList<string> RipgrepArguments(JsonElement input, string pattern, string searchRoot)
    {
        var outputMode = OptionalString(input, "output_mode") ?? "files_with_matches";
        var args = new List<string> { "--color", "never" };
        switch (outputMode)
        {
            case "content":
                args.Add("--line-number");
                break;
            case "count":
                args.Add("--count");
                break;
            default:
                args.Add("--files-with-matches");
                break;
        }

        var glob = OptionalString(input, "glob") ?? OptionalString(input, "include");
        if (!string.IsNullOrWhiteSpace(glob))
        {
            args.Add("--glob");
            args.Add(glob);
        }

        if (OptionalBool(input, "-i") == true) args.Add("-i");
        if (OptionalBool(input, "multiline") == true)
        {
            args.Add("-U");
            args.Add("--multiline-dotall");
        }

        var type = OptionalString(input, "type");
        if (!string.IsNullOrWhiteSpace(type))
        {
            args.Add("--type");
            args.Add(type);
        }

        if ((OptionalInt(input, "context") ?? OptionalInt(input, "-C")) is int context)
        {
            args.Add("-C");
            args.Add(context.ToString());
        }

        if (OptionalInt(input, "-B") is int before)
        {
            args.Add("-B");
            args.Add(before.ToString());
        }

        if (OptionalInt(input, "-A") is int after)
        {
            args.Add("-A");
            args.Add(after.ToString());
        }

        args.Add("--");
        args.Add(pattern);
        args.Add(searchRoot);
        return args;
    }

    internal static string NormalizeRipgrepLine(string line, string workspaceRoot)
    {
        var normalized = line.Replace('\\', '/');
        var normalizedRoot = Path.GetFullPath(workspaceRoot)
            .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
            .Replace('\\', '/');
        var prefix = normalizedRoot + "/";
        return normalized.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)
            ? normalized[prefix.Length..]
            : normalized;
    }

    private static string? FindExecutable(string name)
    {
        var pathValue = Environment.GetEnvironmentVariable("PATH") ?? "";
        var suffixes = OperatingSystem.IsWindows()
            ? new[] { ".exe", ".cmd", ".bat", "" }
            : new[] { "" };
        foreach (var directory in pathValue.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            var trimmed = directory.Trim().Trim('"');
            if (string.IsNullOrWhiteSpace(trimmed)) continue;
            foreach (var suffix in suffixes)
            {
                var candidate = Path.Combine(trimmed, name + suffix);
                if (File.Exists(candidate)) return candidate;
            }
        }

        return null;
    }

    private static void AppendGrepContentLines(
        List<string> results,
        HashSet<int> emittedContextLines,
        string relative,
        IReadOnlyList<string> lines,
        int matchIndex,
        int beforeLines,
        int afterLines)
    {
        var start = Math.Max(0, matchIndex - beforeLines);
        var end = Math.Min(lines.Count - 1, matchIndex + afterLines);
        for (var index = start; index <= end; index++)
        {
            if (emittedContextLines.Add(index))
            {
                results.Add($"{relative}:{index + 1}:{lines[index]}");
            }
        }
    }

    private AgentToolResult Glob(AgentToolCall call, AgentToolExecutionContext context)
    {
        using var doc = JsonDocument.Parse(call.InputJson);
        var pattern = RequiredString(doc.RootElement, "pattern");
        var basePath = OptionalString(doc.RootElement, "path") ?? context.WorkspaceRoot;
        var resolved = WorkspaceService.ResolveWorkspacePath(basePath, context.WorkspaceRoot);
        var regex = GlobToRegex(pattern);
        var files = Directory.EnumerateFiles(resolved, "*", SearchOption.AllDirectories)
            .Where(path => !Path.GetRelativePath(resolved, path).Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar).Any(IsHiddenOrBuildDir))
            .Where(path => regex.IsMatch(Path.GetRelativePath(resolved, path).Replace('\\', '/')))
            .Select(path => RelativeWorkspacePath(context.WorkspaceRoot, path))
            .OrderBy(path => path, StringComparer.OrdinalIgnoreCase)
            .Take(500)
            .ToList();
        return Ok(call, files.Count == 0 ? $"No files matched {pattern}." : string.Join(Environment.NewLine, files));
    }

    private AgentToolResult SemanticSearch(AgentToolCall call, AgentToolExecutionContext context)
    {
        using var doc = JsonDocument.Parse(call.InputJson);
        var root = doc.RootElement;
        var query = RequiredString(doc.RootElement, "query");
        var searchPath = OptionalString(root, "path") ?? ".";
        var resolved = WorkspaceService.ResolveWorkspacePath(searchPath, context.WorkspaceRoot);
        var limit = Math.Max(1, Math.Min(OptionalInt(doc.RootElement, "limit") ?? 20, 100));
        var terms = Regex.Split(query.ToLowerInvariant(), @"[^\p{L}\p{Nd}]+")
            .Where(term => term.Length >= 2)
            .Distinct(StringComparer.Ordinal)
            .ToList();
        if (terms.Count == 0) return Error(call, "SemanticSearch query did not contain searchable terms.");

        var hits = EnumerateSearchableFiles(resolved, null)
            .Select(path => SemanticHit(path, context.WorkspaceRoot, terms))
            .OfType<Dictionary<string, object>>()
            .OrderByDescending(hit => (int)hit["score"])
            .ThenBy(hit => (string)hit["path"], StringComparer.OrdinalIgnoreCase)
            .Take(limit)
            .ToList();
        var output = JsonSerializer.Serialize(new Dictionary<string, object>
        {
            ["query"] = query,
            ["results"] = hits,
        }, new JsonSerializerOptions { WriteIndented = true });
        return Ok(call, output);
    }

    private async Task<AgentToolResult> ShellAsync(AgentToolCall call, AgentToolExecutionContext context)
    {
        using var doc = JsonDocument.Parse(call.InputJson);
        var command = RequiredString(doc.RootElement, "command");
        var timeout = ShellTimeoutMilliseconds(doc.RootElement);
        var cwd = OptionalString(doc.RootElement, "cwd") is { } requestedCwd
            ? WorkspaceService.ResolveWorkspacePath(requestedCwd, context.WorkspaceRoot)
            : context.WorkspaceRoot;
        var environment = SkillRuntimeEnvironment.Build(context.NativeConfigValues);
        if (OptionalBool(doc.RootElement, "run_in_background") == true)
        {
            var run = _runStore.StartShellTask(command, cwd, _terminalService, timeout, context.CancellationToken, environment);
            return Ok(call, BackgroundStartOutput(run.Id, command), taskId: run.Id);
        }

        var result = await _terminalService.RunAsync(command, cwd, timeout, context.CancellationToken, environment);
        var isError = result.ExitCode != 0;
        var output = ShellResultText(result);
        return new AgentToolResult(call.Id, call.Name, isError ? output : LimitOutput(output), isError, Diagnostics: new Dictionary<string, string>
        {
            ["cwd"] = result.Cwd,
            ["exitCode"] = result.ExitCode?.ToString() ?? "",
        });
    }

    private async Task<AgentToolResult> AwaitAsync(AgentToolCall call, AgentToolExecutionContext context)
    {
        using var doc = JsonDocument.Parse(call.InputJson);
        var taskId = RequiredString(doc.RootElement, "task_id");
        var block = OptionalBool(doc.RootElement, "block") ?? true;
        var timeout = AwaitTimeoutMilliseconds(doc.RootElement);
        var run = block
            ? await _runStore.AwaitAsync(taskId, TimeSpan.FromMilliseconds(timeout), context.CancellationToken)
            : _runStore.Snapshot(taskId);
        if (run is null) return Error(call, $"Unknown task id: {taskId}");
        var output = FormatRunOutput(run);
        var isError = run.Status == TaskStatus.Failed;
        return new AgentToolResult(call.Id, call.Name, isError ? output : LimitOutput(output), isError, TaskId: run.Id, Diagnostics: new Dictionary<string, string>
        {
            ["status"] = run.Status.ToString(),
            ["kind"] = run.Kind,
            ["cwd"] = run.Cwd,
            ["exitCode"] = run.ExitCode?.ToString() ?? "",
        });
    }

    private async Task<AgentToolResult> ReadLintsAsync(AgentToolCall call, AgentToolExecutionContext context)
    {
        using var doc = JsonDocument.Parse(call.InputJson);
        var root = doc.RootElement;
        var limit = Math.Max(1, Math.Min(OptionalInt(root, "limit") ?? 100, 500));
        var severity = OptionalString(root, "severity")?.Trim().ToLowerInvariant();
        if (string.IsNullOrWhiteSpace(severity)) severity = null;
        var scopedPath = OptionalString(root, "path");
        scopedPath = string.IsNullOrWhiteSpace(scopedPath) ? "." : scopedPath;
        var resolved = WorkspaceService.ResolveWorkspacePath(scopedPath, context.WorkspaceRoot);
        if (!File.Exists(resolved) && !Directory.Exists(resolved))
        {
            return Error(call, $"Path does not exist: {scopedPath}");
        }

        var command = NativeConfigValue(context.NativeConfigValues, "lint.command");
        if (command is null)
        {
            return Ok(call, PrettyJson(new JsonObject
            {
                ["diagnostics"] = new JsonArray(),
                ["message"] = "No native lint.command is configured and no live LSP diagnostics are available.",
            }));
        }

        var result = await _terminalService.RunAsync(
            command,
            context.WorkspaceRoot,
            120_000,
            context.CancellationToken,
            SkillRuntimeEnvironment.Build(context.NativeConfigValues));
        var diagnostics = ParseLintDiagnostics(result.Output, severity, limit);
        var diagnosticsJson = new JsonArray();
        foreach (var diagnostic in diagnostics)
        {
            diagnosticsJson.Add(new JsonObject
            {
                ["file"] = diagnostic["file"].ToString(),
                ["line"] = (int)diagnostic["line"],
                ["column"] = (int)diagnostic["column"],
                ["severity"] = diagnostic["severity"].ToString(),
                ["message"] = diagnostic["message"].ToString(),
            });
        }

        return Ok(call, PrettyJson(new JsonObject
        {
            ["diagnostics"] = diagnosticsJson,
            ["exitCode"] = result.ExitCode,
            ["truncated"] = diagnostics.Count >= limit,
        }));
    }

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

    private AgentToolResult TodoRead(AgentToolCall call, AgentToolExecutionContext context) =>
        Ok(call, _runStore.LoadTodosJson(context.SessionId));

    private AgentToolResult TodoWrite(AgentToolCall call, AgentToolExecutionContext context)
    {
        using var doc = JsonDocument.Parse(call.InputJson);
        if (!doc.RootElement.TryGetProperty("todos", out var todosElement))
        {
            return Error(call, "TodoWrite requires todos.");
        }

        var todos = todosElement.ValueKind == JsonValueKind.Array
            ? todosElement.EnumerateArray()
                .Select((todo, index) => new NativeTodoItem(
                    FirstString(todo, ["content", "text", "title"]) ?? todo.ToString(),
                    FirstString(todo, ["status", "state"]) ?? "pending",
                    OptionalInt(todo, "priority") ?? index + 1))
                .Where(todo => !string.IsNullOrWhiteSpace(todo.Content))
                .ToList()
            : [];
        _runStore.ReplaceTodos(context.SessionId, todos, PrettyJson(todosElement));
        return Ok(call, "Todos have been modified successfully. Ensure that you continue to use the todo list to track your progress. Please proceed with the current tasks if applicable.");
    }

    private static AgentToolResult AskQuestion(AgentToolCall call) =>
        Error(call, "AskQuestion requires a user answer before continuing.");

    private static AgentToolResult SwitchMode(AgentToolCall call, AgentToolExecutionContext context)
    {
        using var doc = JsonDocument.Parse(call.InputJson);
        var mode = OptionalString(doc.RootElement, "mode") ?? (context.RunMode == ChatRunMode.Plan ? "agent" : "plan");
        if (string.Equals(mode, "plan", StringComparison.OrdinalIgnoreCase) &&
            OptionalString(doc.RootElement, "userFeedback") is { } feedback &&
            !string.IsNullOrWhiteSpace(feedback))
        {
            return Ok(call, $"Stay in Plan mode. User requested revisions:\n{feedback.Trim()}");
        }

        return Ok(call, OptionalString(doc.RootElement, "plan") ?? $"SwitchMode accepted: {mode}.");
    }

    private async Task<AgentToolResult> TaskToolAsync(AgentToolCall call, AgentToolExecutionContext context)
    {
        var maxSubagentDepth = MaxSubagentDepth(context);
        if (context.SubagentDepth >= maxSubagentDepth)
        {
            return Error(call, $"subagent_depth_exceeded (depth={context.SubagentDepth}, max={maxSubagentDepth}); nested Task is not allowed.");
        }

        using var doc = JsonDocument.Parse(call.InputJson);
        var root = doc.RootElement;
        var type = OptionalString(root, "type") ?? "generalPurpose";
        var prompt = RequiredString(root, "prompt");
        var description = OptionalString(root, "description") ?? prompt.Split('\n').FirstOrDefault() ?? type;
        var cwd = OptionalString(root, "cwd") is { } requestedCwd
            ? ValidatedTaskWorkingDirectory(requestedCwd, context.WorkspaceRoot)
            : context.WorkspaceRoot;
        var background = OptionalBool(root, "run_in_background") ?? false;
        var timeout = ShellTimeoutMilliseconds(root);
        var normalizedType = NormalizeTaskType(type);

        if (normalizedType is null)
        {
            return Error(call, $"Unsupported Task type: {type}");
        }

        if (normalizedType == "shell")
        {
            var environment = SkillRuntimeEnvironment.Build(context.NativeConfigValues);
            if (background)
            {
                var run = _runStore.StartShellTask(prompt, cwd, _terminalService, timeout, context.CancellationToken, environment);
                return Ok(call, BackgroundStartOutput(run.Id, description), taskId: run.Id);
            }

            var result = await _terminalService.RunAsync(prompt, cwd, timeout, context.CancellationToken, environment);
            var isError = result.ExitCode != 0;
            var shellOutput = ShellResultText(result);
            return new AgentToolResult(call.Id, call.Name, isError ? shellOutput : LimitOutput(shellOutput), isError, Diagnostics: new Dictionary<string, string>
            {
                ["taskType"] = normalizedType,
                ["cwd"] = cwd,
                ["exitCode"] = result.ExitCode?.ToString() ?? "",
            });
        }

        var output = await TaskOutputAsync(normalizedType, type, prompt, description, cwd, root, context);
        var task = background
            ? _runStore.StartRecordedTask(normalizedType, description, cwd, output, context.CancellationToken)
            : _runStore.CreateRecordedTask(type, description, cwd, output);
        if (background)
        {
            return Ok(call, BackgroundStartOutput(task.Id, description), taskId: task.Id);
        }

        return Ok(call, output, taskId: task.Id);
    }

    private static AgentToolResult Ok(AgentToolCall call, string output, string? artifactPath = null, string? taskId = null) =>
        new(call.Id, call.Name, LimitOutput(output), false, artifactPath, taskId);

    private static AgentToolResult Error(AgentToolCall call, string output) => new(call.Id, call.Name, output, true);

    private static string LimitOutput(string output) =>
        output.Length <= 20_000 ? output : output[..20_000] + "\n... output truncated ...";

    internal static string ShellResultText(TerminalRun result)
    {
        var parts = new List<string> { $"exit code: {result.ExitCode ?? -1}" };
        var output = result.Output.TrimEnd('\r', '\n');
        if (!string.IsNullOrEmpty(output))
        {
            parts.Add(output);
        }

        return string.Join('\n', parts);
    }

    internal static int ShellTimeoutMilliseconds(JsonElement root)
    {
        if (OptionalInt(root, "timeout") is { } timeout) return ClampTimeout(timeout, 1_000);
        if (OptionalInt(root, "timeout_seconds") is { } timeoutSeconds)
        {
            return ClampTimeout((long)timeoutSeconds * 1_000, 1_000);
        }

        return 120_000;
    }

    internal static int AwaitTimeoutMilliseconds(JsonElement root) =>
        ClampTimeout(OptionalInt(root, "timeout") ?? 30_000, 0);

    private static int ClampTimeout(long timeoutMs, int minimum) =>
        (int)Math.Max(minimum, Math.Min(timeoutMs, 600_000));

    private async Task<string> TaskOutputAsync(
        string normalizedType,
        string type,
        string prompt,
        string description,
        string cwd,
        JsonElement input,
        AgentToolExecutionContext context)
    {
        if (normalizedType == "best-of-n-runner")
        {
            var n = Math.Max(1, Math.Min(OptionalInt(input, "n") ?? 3, 8));
            var attempts = new JsonArray();
            for (var index = 1; index <= n; index++)
            {
                var attemptPrompt = $"{prompt}\n\nAttempt {index} of {n}. Use this isolated git worktree and return the best concise result.";
                var attemptDescription = $"best-of-n {index}";
                var result = await WithIsolatedGitWorktreeAsync(cwd, worktreePath =>
                    TaskSubagentOutputAsync(
                        type,
                        attemptPrompt,
                        attemptDescription,
                        worktreePath,
                        $"Task isolation: git worktree at {worktreePath}",
                        context),
                    context.CancellationToken);
                attempts.Add(new JsonObject
                {
                    ["attempt"] = index,
                    ["worktree"] = result.WorktreePath,
                    ["result"] = result.Output,
                });
            }

            return PrettyJson(new JsonObject
            {
                ["type"] = type,
                ["attempts"] = attempts,
                ["selectedAttempt"] = 1,
            });
        }

        if (string.Equals(OptionalString(input, "isolation")?.Trim(), "worktree", StringComparison.OrdinalIgnoreCase))
        {
            var result = await WithIsolatedGitWorktreeAsync(cwd, worktreePath =>
                TaskSubagentOutputAsync(
                    type,
                    prompt,
                    description,
                    worktreePath,
                    $"Task type: {type}\nTask isolation: git worktree at {worktreePath}",
                    context),
                context.CancellationToken);
            return PrettyJson(new JsonObject
            {
                ["type"] = type,
                ["worktree"] = result.WorktreePath,
                ["result"] = result.Output,
            });
        }

        return await TaskSubagentOutputAsync(type, prompt, description, cwd, $"Task type: {type}", context);
    }

    private static string RecordedTaskOutput(string type, string description, string prompt) =>
        $"Recorded {type} task: {description}\n\n{prompt}";

    private Task<string> TaskSubagentOutputAsync(
        string type,
        string prompt,
        string description,
        string workspaceRoot,
        string extraContext,
        AgentToolExecutionContext context)
    {
        if (_subagentRunner.RequiresProviderConfig &&
            (context.ProviderConfig is null || string.IsNullOrWhiteSpace(context.ApiKey)))
        {
            return Task.FromResult(RecordedTaskOutput(type, description, prompt));
        }

        var childContext = context with
        {
            WorkspaceRoot = workspaceRoot,
            SubagentDepth = context.SubagentDepth + 1,
        };
        return _subagentRunner.RunAsync(
            new NativeSubagentRequest(workspaceRoot, prompt, description, extraContext, childContext),
            context.CancellationToken);
    }

    private static async Task<(string WorktreePath, string Output)> WithIsolatedGitWorktreeAsync(
        string workspacePath,
        Func<string, Task<string>> operation,
        CancellationToken cancellationToken)
    {
        var environment = SkillRuntimeEnvironment.Build(null);
        var repoRoot = (await GitOutputAsync(
            ["-C", workspacePath, "rev-parse", "--show-toplevel"],
            workspacePath,
            environment,
            30_000,
            cancellationToken)).Trim();
        _ = await GitOutputAsync(
            ["-C", repoRoot, "rev-parse", "--verify", "HEAD"],
            repoRoot,
            environment,
            30_000,
            cancellationToken);
        var parent = Path.Combine(Path.GetTempPath(), "g9claw-worktrees");
        Directory.CreateDirectory(parent);
        var worktreePath = Path.Combine(parent, $"worktree-{Guid.NewGuid():D}");

        try
        {
            _ = await GitOutputAsync(
                ["-C", repoRoot, "worktree", "add", "--detach", worktreePath, "HEAD"],
                repoRoot,
                environment,
                120_000,
                cancellationToken);
            return (worktreePath, await operation(worktreePath));
        }
        finally
        {
            try
            {
                _ = await GitOutputAsync(
                    ["-C", repoRoot, "worktree", "remove", "--force", worktreePath],
                    repoRoot,
                    environment,
                    120_000,
                    CancellationToken.None);
            }
            catch
            {
            }

            try
            {
                if (Directory.Exists(worktreePath)) Directory.Delete(worktreePath, true);
            }
            catch
            {
            }
        }
    }

    private static async Task<string> GitOutputAsync(
        IReadOnlyList<string> arguments,
        string cwd,
        IReadOnlyDictionary<string, string> environment,
        int timeoutMs,
        CancellationToken cancellationToken)
    {
        var psi = new ProcessStartInfo
        {
            FileName = "git",
            WorkingDirectory = cwd,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };
        foreach (var argument in arguments)
        {
            psi.ArgumentList.Add(argument);
        }

        foreach (var (key, value) in environment)
        {
            psi.Environment[key] = value;
        }

        using var process = new Process { StartInfo = psi };
        process.Start();
        var stdout = process.StandardOutput.ReadToEndAsync(cancellationToken);
        var stderr = process.StandardError.ReadToEndAsync(cancellationToken);
        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutCts.CancelAfter(Math.Max(1_000, timeoutMs));
        try
        {
            await process.WaitForExitAsync(timeoutCts.Token);
        }
        catch (OperationCanceledException)
        {
            try
            {
                if (!process.HasExited) process.Kill(entireProcessTree: true);
            }
            catch
            {
            }

            throw new TimeoutException($"git {string.Join(' ', arguments)} timed out after {timeoutMs} ms.");
        }

        var output = await stdout;
        var error = await stderr;
        if (process.ExitCode == 0) return output;
        throw new InvalidOperationException(string.IsNullOrWhiteSpace(error) ? output : error);
    }

    internal static int MaxSubagentDepth(AgentToolExecutionContext context)
    {
        if (context.MaxSubagentDepth is { } maxSubagentDepth)
        {
            return Math.Max(0, maxSubagentDepth);
        }

        if (context.NativeConfigValues is not null &&
            context.NativeConfigValues.TryGetValue("runtime.maxSubagentDepth", out var configured) &&
            int.TryParse(configured, out var parsed))
        {
            return Math.Max(0, parsed);
        }

        return 1;
    }

    private static string ValidatedTaskWorkingDirectory(string cwd, string workspaceRoot)
    {
        var resolved = WorkspaceService.ResolveWorkspacePath(cwd, workspaceRoot);
        if (!Directory.Exists(resolved))
        {
            throw new InvalidOperationException($"Task cwd must be an existing directory: {cwd}");
        }

        return resolved;
    }

    private static string? NormalizeTaskType(string type)
    {
        return type.Trim().ToLowerInvariant() switch
        {
            "shell" => "shell",
            "best-of-n-runner" => "best-of-n-runner",
            "explore" => "explore",
            "cursor-guide" => "cursor-guide",
            "ci-investigator" => "ci-investigator",
            "generalpurpose" or "general-purpose" or "general_purpose" => "generalPurpose",
            _ => null,
        };
    }

    internal static IReadOnlyList<Dictionary<string, object>> ParseLintDiagnostics(string output, string? severity, int limit)
    {
        limit = Math.Max(1, limit);
        severity = string.IsNullOrWhiteSpace(severity) ? null : severity.Trim().ToLowerInvariant();
        var regex = new Regex(
            @"^(.+?):(\d+):(?:(\d+):)?\s*(?:(error|warning|info|note):)?\s*(.+)$",
            RegexOptions.IgnoreCase | RegexOptions.Compiled);
        var diagnostics = new List<Dictionary<string, object>>();
        using var reader = new StringReader(output);
        while (reader.ReadLine() is { } line)
        {
            var match = regex.Match(line);
            if (!match.Success) continue;
            var level = match.Groups[4].Success ? match.Groups[4].Value.ToLowerInvariant() : "error";
            if (severity is not null && level != severity) continue;
            diagnostics.Add(new Dictionary<string, object>
            {
                ["file"] = match.Groups[1].Value,
                ["line"] = ParseDiagnosticNumber(match.Groups[2].Value),
                ["column"] = match.Groups[3].Success ? ParseDiagnosticNumber(match.Groups[3].Value) : 0,
                ["severity"] = level,
                ["message"] = match.Groups[5].Value,
            });
            if (diagnostics.Count >= limit) break;
        }

        return diagnostics;
    }

    private static int ParseDiagnosticNumber(string value) =>
        int.TryParse(value, out var parsed) ? parsed : 0;

    private static string? NativeConfigValue(IReadOnlyDictionary<string, string>? values, string key) =>
        values is not null && values.TryGetValue(key, out var value) && !string.IsNullOrWhiteSpace(value)
            ? value
            : null;

    private static string PrettyJson(JsonElement element)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream, new JsonWriterOptions { Indented = true }))
        {
            element.WriteTo(writer);
        }

        return Encoding.UTF8.GetString(stream.ToArray());
    }

    private static string PrettyJson(JsonNode node) =>
        node.ToJsonString(new JsonSerializerOptions { WriteIndented = true });

    private static string BackgroundStartOutput(string taskId, string description) =>
        PrettyJson(new JsonObject
        {
            ["task_id"] = taskId,
            ["status"] = "running",
            ["description"] = description,
        });

    private static string FormatRunOutput(NativeBackgroundRun run) =>
        PrettyJson(new JsonObject
        {
            ["task_id"] = run.Id,
            ["description"] = run.Description,
            ["status"] = BackgroundStatus(run.Status),
            ["exitCode"] = run.ExitCode,
            ["stdout"] = run.Output,
            ["stderr"] = run.Error ?? "",
            ["output"] = run.Output,
        });

    private static string BackgroundStatus(TaskStatus status) =>
        status switch
        {
            TaskStatus.Completed => "completed",
            TaskStatus.Failed => "failed",
            TaskStatus.Running => "running",
            TaskStatus.Queued => "queued",
            _ => status.ToString().ToLowerInvariant(),
        };

    private static string ReadImage(string path, string workspaceRoot, string extension)
    {
        var mimeType = ImageMimeType(extension) ?? throw new InvalidOperationException($"Unsupported image type: {extension}");
        var bytes = File.ReadAllBytes(path);
        return PrettyJson(new JsonObject
        {
            ["type"] = "image",
            ["file"] = new JsonObject
            {
                ["filePath"] = RelativeWorkspacePath(workspaceRoot, path),
                ["mediaType"] = mimeType,
                ["originalSize"] = bytes.Length,
                ["base64"] = Convert.ToBase64String(bytes),
            },
        });
    }

    private static string ReadNotebook(string path, string workspaceRoot)
    {
        using var doc = JsonDocument.Parse(File.ReadAllText(path, Encoding.UTF8));
        if (!doc.RootElement.TryGetProperty("cells", out var cells) || cells.ValueKind != JsonValueKind.Array)
        {
            throw new InvalidOperationException("Notebook JSON must contain a cells array.");
        }

        var output = new List<string>
        {
            $"Notebook {RelativeWorkspacePath(workspaceRoot, path)}",
            $"cells: {cells.GetArrayLength()}",
            "",
        };
        var index = 0;
        foreach (var cell in cells.EnumerateArray())
        {
            var cellType = cell.TryGetProperty("cell_type", out var typeElement) ? typeElement.GetString() ?? "unknown" : "unknown";
            var source = cell.TryGetProperty("source", out var sourceElement) ? NotebookSourceString(sourceElement) : "";
            output.Add($"## Cell {index} [{cellType}]");
            output.Add(string.IsNullOrEmpty(source) ? "(empty)" : source[..Math.Min(source.Length, 4_000)]);
            output.Add("");
            index++;
        }

        return string.Join("\n", output);
    }

    private static string ReadPdf(string path, string workspaceRoot, string? pages)
    {
        using var document = PdfDocument.Open(path);
        var pageNumbers = ParsePdfPages(pages, document.NumberOfPages);
        var sections = new List<string>
        {
            $"PDF {RelativeWorkspacePath(workspaceRoot, path)}",
            $"pages: {document.NumberOfPages}",
            $"selected: {string.Join(",", pageNumbers)}",
            "",
        };

        foreach (var number in pageNumbers)
        {
            var page = document.GetPage(number);
            var text = ContentOrderTextExtractor.GetText(page).Trim();
            sections.Add($"## Page {number}");
            sections.Add(string.IsNullOrWhiteSpace(text) ? "(no extractable text)" : text);
            sections.Add("");
        }

        return string.Join("\n", sections);
    }

    internal static IReadOnlyList<int> ParsePdfPages(string? value, int total)
    {
        if (total <= 0) return [];
        var trimmed = value?.Trim() ?? "";
        if (string.IsNullOrEmpty(trimmed))
        {
            return Enumerable.Range(1, Math.Min(total, 10)).ToList();
        }

        var pages = new SortedSet<int>();
        foreach (var part in trimmed.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var bounds = part.Split('-', 2, StringSplitOptions.TrimEntries)
                .Select(item => int.TryParse(item, out var parsed) ? parsed : (int?)null)
                .OfType<int>()
                .ToList();
            if (bounds.Count == 2)
            {
                for (var page = Math.Min(bounds[0], bounds[1]); page <= Math.Max(bounds[0], bounds[1]); page++)
                {
                    if (page >= 1 && page <= total) pages.Add(page);
                }
            }
            else if (bounds.Count == 1 && bounds[0] >= 1 && bounds[0] <= total)
            {
                pages.Add(bounds[0]);
            }
        }

        return pages.Take(10).ToList();
    }

    private static string NotebookSourceString(JsonElement source)
    {
        return source.ValueKind switch
        {
            JsonValueKind.String => source.GetString() ?? "",
            JsonValueKind.Array => string.Concat(source.EnumerateArray().Select(item => item.ValueKind == JsonValueKind.String ? item.GetString() : item.ToString())),
            _ => source.ToString(),
        };
    }

    private static string? ImageMimeType(string extension)
    {
        return extension.ToLowerInvariant() switch
        {
            "jpg" or "jpeg" => "image/jpeg",
            "png" => "image/png",
            "gif" => "image/gif",
            "webp" => "image/webp",
            _ => null,
        };
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

    private static IReadOnlyList<string> SliceToolOutput(IReadOnlyList<string> values, int offset, int headLimit)
    {
        var skipped = values.Skip(Math.Max(0, offset));
        return headLimit == 0
            ? skipped.ToList()
            : skipped.Take(Math.Max(1, headLimit)).ToList();
    }

    private static string RelativeWorkspacePath(string workspaceRoot, string path) =>
        Path.GetRelativePath(workspaceRoot, path).Replace('\\', '/');

    private static Dictionary<string, object>? SemanticHit(string path, string workspaceRoot, IReadOnlyList<string> terms)
    {
        if (terms.Count == 0) return null;
        string text;
        try
        {
            if (new FileInfo(path).Length > 300_000) return null;
            text = File.ReadAllText(path, Encoding.UTF8);
        }
        catch
        {
            return null;
        }

        var relative = RelativeWorkspacePath(workspaceRoot, path);
        var bestScore = SemanticScore(relative.ToLowerInvariant(), terms) * 4;
        var bestLine = 1;
        var bestSnippet = "";
        var lines = text.Split(["\r\n", "\n"], StringSplitOptions.None);
        for (var index = 0; index < lines.Length; index++)
        {
            var line = lines[index];
            var lineScore = SemanticScore(line.ToLowerInvariant(), terms);
            if (lineScore > bestScore)
            {
                bestScore = lineScore;
                bestLine = index + 1;
                bestSnippet = line.Trim();
            }
        }

        if (bestScore <= 0) return null;
        return new Dictionary<string, object>
        {
            ["path"] = relative,
            ["line"] = bestLine,
            ["score"] = bestScore,
            ["snippet"] = string.IsNullOrWhiteSpace(bestSnippet)
                ? relative
                : bestSnippet[..Math.Min(bestSnippet.Length, 500)],
        };
    }

    private static int SemanticScore(string text, IReadOnlyList<string> terms) =>
        terms.Count(term => text.Contains(term, StringComparison.OrdinalIgnoreCase));

    private static IEnumerable<string> EnumerateSearchableFiles(string root, string? glob)
    {
        var regex = string.IsNullOrWhiteSpace(glob) ? null : GlobToRegex(glob);
        return Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories)
            .Where(path => !Path.GetRelativePath(root, path).Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar).Any(IsHiddenOrBuildDir))
            .Where(path => regex is null || regex.IsMatch(Path.GetFileName(path)) || regex.IsMatch(Path.GetRelativePath(root, path).Replace('\\', '/')))
            .OrderBy(path => path, StringComparer.OrdinalIgnoreCase);
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
