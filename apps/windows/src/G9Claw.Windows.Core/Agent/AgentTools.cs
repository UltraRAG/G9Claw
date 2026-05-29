using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace G9Claw.Windows.Core;

public static class AgentToolNameCanonicalizer
{
    public static string Canonical(string rawName)
    {
        var trimmed = rawName.Trim();
        var lower = trimmed.ToLowerInvariant();
        if (lower.StartsWith("g9claw-rag:", StringComparison.Ordinal)) return trimmed;

        return lower switch
        {
            "read" => "Read",
            "write" => "Write",
            "strreplace" or "str_replace" or "str-replace" or "edit" or "multiedit" or "multi_edit" or "multi-edit" => "StrReplace",
            "delete" or "remove" or "unlink" => "Delete",
            "editnotebook" or "edit_notebook" or "edit-notebook" or "notebookedit" or "notebook_edit" or "notebook-edit" => "EditNotebook",
            "glob" => "Glob",
            "grep" => "Grep",
            "semanticsearch" or "semantic_search" or "semantic-search" => "SemanticSearch",
            "bash" or "shell" or "run_command" or "runcommand" => "Shell",
            "await" or "taskoutput" or "task_output" or "task-output" or "agentoutputtool" or "bashoutputtool" => "Await",
            "websearch" or "web_search" or "web-search" => "WebSearch",
            "webfetch" or "web_fetch" or "web-fetch" => "WebFetch",
            "weather" or "getweather" or "get_weather" or "get-weather" => "Weather",
            "readlints" or "read_lints" or "read-lints" or "lints" or "lint" => "ReadLints",
            "skill" or "loadskill" or "load_skill" => "Skill",
            "task" or "taskcreate" or "task_create" or "task-create" or "agent" or "subagent" or "sub_agent" or "sub-agent" => "Task",
            "todoread" or "todo_read" or "todo-read" => "TodoRead",
            "todowrite" or "todo_write" or "todo-write" => "TodoWrite",
            "switchmode" or "switch_mode" or "switch-mode" or "exitplanmode" or "exit_plan_mode" or "exit-plan-mode" or "exitplanmodev2" => "SwitchMode",
            "askquestion" or "ask_question" or "ask-question" or "askuserquestion" or "ask_user_question" or "ask-user-question" => "AskQuestion",
            _ => trimmed,
        };
    }
}

public sealed record ToolSchema(
    string Name,
    string Description,
    IReadOnlyDictionary<string, object?> Properties,
    IReadOnlyList<string> Required);

public static class AgentToolRegistry
{
    public static readonly string[] ToolNames =
    [
        "Read",
        "Write",
        "StrReplace",
        "Delete",
        "EditNotebook",
        "Grep",
        "Glob",
        "SemanticSearch",
        "Shell",
        "Await",
        "ReadLints",
        "Skill",
        "TodoWrite",
        "AskQuestion",
        "SwitchMode",
        "Task",
    ];

    public static IReadOnlyList<ToolSchema> Schemas { get; } =
    [
        Tool("Read", "Read text, image, PDF, or Jupyter notebook content from the workspace.",
            Props(("file_path", Str("Workspace-relative or absolute file path.")), ("offset", Int("Optional 1-based line offset.")), ("limit", Int("Optional maximum number of lines to return.")), ("pages", Str("Optional PDF page range such as 1-3."))), ["file_path"]),
        Tool("Write", "Create or overwrite a UTF-8 file in the workspace.",
            Props(("file_path", Str("Workspace-relative or absolute file path.")), ("content", Str("Complete file contents to write."))), ["file_path", "content"]),
        Tool("StrReplace", "Replace exact strings in a workspace file. Supports one replacement or an edits array.",
            Props(("file_path", Str("Workspace-relative or absolute file path.")), ("old_string", Str("Exact text to replace.")), ("new_string", Str("Replacement text.")), ("replace_all", Bool("Replace every match instead of requiring one unique match."))), ["file_path"]),
        Tool("Delete", "Delete a file or, with recursive=true, a directory inside the workspace.",
            Props(("path", Str("Workspace-relative or absolute file or directory path.")), ("recursive", Bool("Allow deleting directories recursively."))), ["path"]),
        Tool("EditNotebook", "Replace, insert, or delete a cell in a Jupyter notebook file.",
            Props(("notebook_path", Str("Workspace-relative or absolute .ipynb path.")), ("cell_id", Str("Optional notebook cell id.")), ("cell_number", Int("Optional 0-based cell index.")), ("new_source", Str("New source for replace or insert.")), ("cell_type", Enum(["code", "markdown"], "Cell type for inserted cells.")), ("edit_mode", Enum(["replace", "insert", "delete"], "Notebook edit mode. Defaults to replace."))), ["notebook_path"]),
        Tool("Grep", "Search text files by regular expression under the workspace, preferring ripgrep.",
            Props(("pattern", Str("Regular expression to search for.")), ("path", Str("Optional directory or file to search.")), ("glob", Str("Optional glob filter such as *.cs.")), ("include", Str("Legacy alias for glob.")), ("output_mode", Enum(["content", "files_with_matches", "count"], "Result mode. Defaults to files_with_matches.")), ("-B", Int("Context lines before each match.")), ("-A", Int("Context lines after each match.")), ("-C", Int("Context lines before and after each match.")), ("context", Int("Alias for -C.")), ("-n", Bool("Show line numbers in content mode.")), ("-i", Bool("Case-insensitive search.")), ("type", Str("Optional ripgrep file type.")), ("head_limit", Int("Maximum returned lines or entries.")), ("offset", Int("Number of results to skip before limiting.")), ("multiline", Bool("Enable multiline matching."))), ["pattern"]),
        Tool("Glob", "Find files by glob pattern under the workspace.",
            Props(("pattern", Str("Glob such as **/*.cs or *.md.")), ("path", Str("Optional directory to search."))), ["pattern"]),
        Tool("SemanticSearch", "Search code by meaning using a deterministic local workspace index.",
            Props(("query", Str("Natural-language or code concept query.")), ("path", Str("Optional directory or file to search.")), ("limit", Int("Maximum number of ranked results."))), ["query"]),
        Tool("Shell", "Run a PowerShell command in the workspace.",
            Props(("command", Str("Command to run with PowerShell.")), ("description", Str("Short reason for running the command.")), ("timeout", Int("Optional timeout in milliseconds.")), ("run_in_background", Bool("Start the command in the background and return a task id."))), ["command"]),
        Tool("Await", "Wait for or read output from a background Shell or Task.",
            Props(("task_id", Str("Background task id.")), ("block", Bool("Whether to block until completion. Defaults to true.")), ("timeout", Int("Maximum wait time in milliseconds."))), ["task_id"]),
        Tool("ReadLints", "Read current workspace linter or diagnostic findings when available.",
            Props(("path", Str("Optional file or directory to scope diagnostics.")), ("severity", Str("Optional severity filter such as error or warning.")), ("limit", Int("Maximum number of diagnostics."))), []),
        Tool("Skill", "Load a G9Claw skill. Use g9claw-rag:glm-web-search for public web search and weather, or g9claw-rag:rag-research for source-grounded research.",
            Props(("skill", Str("Skill name, for example g9claw-rag:glm-web-search.")), ("args", Str("User query or task arguments for the skill."))), ["skill"]),
        Tool("TodoWrite", "Replace the current session todo list.",
            Props(("todos", new Dictionary<string, object?> { ["type"] = "array", ["items"] = new Dictionary<string, object?> { ["type"] = "object", ["additionalProperties"] = true } })), ["todos"]),
        Tool("AskQuestion", "Ask the user one or more short blocking questions.",
            Props(("questions", new Dictionary<string, object?> { ["type"] = "array", ["minItems"] = 1 }), ("question", Str("Legacy single question fallback.")), ("options", new Dictionary<string, object?> { ["type"] = "array", ["items"] = Str("Legacy option label.") })), []),
        Tool("SwitchMode", "Switch between plan and agent mode. Use mode=agent with a concrete plan to execute after planning.",
            Props(("mode", Enum(["plan", "agent"], "Target run mode.")), ("plan", Str("The plan to execute when switching to agent mode."))), ["mode"]),
        Tool("Task", "Start a delegated task or subagent.",
            Props(("type", Enum(["generalPurpose", "explore", "shell", "cursor-guide", "ci-investigator", "best-of-n-runner"], "Task type. Defaults to generalPurpose.")), ("prompt", Str("Concrete task prompt or shell command for type=shell.")), ("description", Str("Optional short label.")), ("model", Str("Optional model hint.")), ("run_in_background", Bool("Run task asynchronously and return a task id.")), ("cwd", Str("Optional workspace-relative or absolute cwd.")), ("isolation", Enum(["worktree"], "Optional isolation mode. best-of-n-runner uses worktree isolation.")), ("n", Int("Number of isolated attempts for best-of-n-runner."))), ["prompt"]),
    ];

    public static IReadOnlyList<Dictionary<string, object?>> OpenAITools()
    {
        return Schemas.Select(schema => new Dictionary<string, object?>
        {
            ["type"] = "function",
            ["function"] = new Dictionary<string, object?>
            {
                ["name"] = schema.Name,
                ["description"] = schema.Description,
                ["parameters"] = new Dictionary<string, object?>
                {
                    ["type"] = "object",
                    ["properties"] = schema.Properties,
                    ["required"] = schema.Required,
                    ["additionalProperties"] = false,
                },
            },
        }).ToList();
    }

    private static ToolSchema Tool(string name, string description, IReadOnlyDictionary<string, object?> properties, IReadOnlyList<string> required) =>
        new(name, description, properties, required);

    private static Dictionary<string, object?> Props(params (string Name, object? Value)[] values) =>
        values.ToDictionary(value => value.Name, value => value.Value);

    private static Dictionary<string, object?> Str(string description) => new() { ["type"] = "string", ["description"] = description };
    private static Dictionary<string, object?> Int(string description) => new() { ["type"] = "integer", ["description"] = description };
    private static Dictionary<string, object?> Bool(string description) => new() { ["type"] = "boolean", ["description"] = description };
    private static Dictionary<string, object?> Enum(string[] values, string description) => new() { ["type"] = "string", ["enum"] = values, ["description"] = description };
}

public sealed record NormalizationError(string Message);
public sealed record NormalizedInvocation(AgentToolCall Call, AgentToolResult? RecoveryResult);

public sealed class AgentRootGlobExecutionPolicy
{
    private string? _rootGlobCacheOutput;
    private int _rootGlobCacheEntryCount;

    public AgentToolResult? CachedResultIfAvailable(AgentToolCall call)
    {
        if (!IsRootWorkspaceGlob(call) || string.IsNullOrWhiteSpace(_rootGlobCacheOutput))
        {
            return null;
        }

        return new AgentToolResult(
            call.Id,
            "Glob",
            CachedSummary(_rootGlobCacheOutput, _rootGlobCacheEntryCount),
            false);
    }

    public AgentToolResult RecordIfRootGlob(AgentToolCall call, AgentToolResult result)
    {
        if (!IsRootWorkspaceGlob(call))
        {
            return result;
        }

        _rootGlobCacheOutput = result.Output;
        _rootGlobCacheEntryCount = EntryCount(result.Output);
        return result with { Output = CompactBootstrapOutput(result.Output) };
    }

    public static bool IsRootWorkspaceGlob(AgentToolCall call)
    {
        if (!string.Equals(AgentToolNameCanonicalizer.Canonical(call.Name), "Glob", StringComparison.Ordinal))
        {
            return false;
        }

        try
        {
            using var doc = JsonDocument.Parse(string.IsNullOrWhiteSpace(call.InputJson) ? "{}" : call.InputJson);
            if (doc.RootElement.ValueKind != JsonValueKind.Object) return false;
            var pattern = FirstString(doc.RootElement, "pattern") ?? FirstString(doc.RootElement, "glob") ?? "";
            var path = FirstString(doc.RootElement, "path") ?? ".";
            pattern = pattern.Trim();
            path = path.Trim();
            return pattern == "**/*" && (path.Length == 0 || path == "." || path == "./");
        }
        catch (JsonException)
        {
            return false;
        }
    }

    private static string CachedSummary(string output, int entryCount)
    {
        var count = entryCount > 0 ? entryCount : EntryCount(output);
        return $"""
        Cached workspace discovery from earlier Glob **/* ({count} entries). Use targeted Read/Grep/Glob for known paths instead of repeating full workspace discovery.
        {CompactBootstrapOutput(output)}
        """;
    }

    private static string CompactBootstrapOutput(string output)
    {
        var trimmed = output.Trim();
        var lines = NonEmptyLines(trimmed).ToList();
        if (lines.Count <= 160 && trimmed.Length <= 12_000)
        {
            return trimmed;
        }

        var preview = string.Join("\n", lines.Take(140));
        return $"{preview}\n... workspace discovery truncated for display; {lines.Count} total entries ...";
    }

    private static int EntryCount(string output) => NonEmptyLines(output).Count();

    private static IEnumerable<string> NonEmptyLines(string output) =>
        output.Replace("\r\n", "\n").Split('\n').Where(line => !string.IsNullOrWhiteSpace(line));

    private static string? FirstString(JsonElement root, string key)
    {
        if (!root.TryGetProperty(key, out var value)) return null;
        return value.ValueKind == JsonValueKind.String ? value.GetString() : value.ToString();
    }
}

public sealed class AgentPlanTodoExecutionGate
{
    private bool _planExecutionApproved;
    private bool _todoRequiresInitialization;
    private bool _todoRequiresRefresh;

    public AgentToolResult? BlockingResult(AgentToolCall call)
    {
        if (!_planExecutionApproved) return null;
        var toolName = AgentToolNameCanonicalizer.Canonical(call.Name);
        if (toolName == "TodoWrite" || AgentToolBehaviorClassifier.IsReadOnlyTool(call)) return null;
        if (_todoRequiresInitialization)
        {
            return RequiredTodoResult(
                call,
                "Initialize the execution todo list with TodoWrite before the first workspace-changing tool after plan approval.");
        }

        if (_todoRequiresRefresh)
        {
            return RequiredTodoResult(
                call,
                "Update the todo list with TodoWrite before the next workspace-changing tool so progress remains visible.");
        }

        return null;
    }

    public void Record(AgentToolCall call, AgentToolResult result)
    {
        if (result.IsPolicyBlock) return;
        var toolName = AgentToolNameCanonicalizer.Canonical(call.Name);
        if (!result.IsError && toolName == "SwitchMode")
        {
            var mode = SwitchModeTarget(call.InputJson);
            if (mode == "agent")
            {
                _planExecutionApproved = true;
                _todoRequiresInitialization = true;
                _todoRequiresRefresh = false;
            }
            else if (mode == "plan")
            {
                _planExecutionApproved = false;
                _todoRequiresInitialization = false;
                _todoRequiresRefresh = false;
            }

            return;
        }

        if (!result.IsError && toolName == "TodoWrite")
        {
            _todoRequiresInitialization = false;
            _todoRequiresRefresh = false;
        }
        else if (RequiresTodoRefresh(call, result))
        {
            _todoRequiresRefresh = true;
        }
    }

    private static bool RequiresTodoRefresh(AgentToolCall call, AgentToolResult result)
    {
        if (result.IsError || result.IsPolicyBlock) return false;
        var toolName = AgentToolNameCanonicalizer.Canonical(call.Name);
        return toolName != "TodoWrite" && !AgentToolBehaviorClassifier.IsReadOnlyTool(call);
    }

    private static AgentToolResult RequiredTodoResult(AgentToolCall call, string reason)
    {
        var toolName = AgentToolNameCanonicalizer.Canonical(call.Name);
        return new AgentToolResult(
            call.Id,
            toolName,
            $"{reason} The requested {toolName} tool was not executed yet; call TodoWrite next, then retry this tool.",
            false,
            IsPolicyBlock: true);
    }

    private static string SwitchModeTarget(string inputJson)
    {
        try
        {
            using var doc = JsonDocument.Parse(string.IsNullOrWhiteSpace(inputJson) ? "{}" : inputJson);
            if (doc.RootElement.ValueKind != JsonValueKind.Object) return "agent";
            return FirstString(doc.RootElement, "mode")?.Trim().ToLowerInvariant() ?? "agent";
        }
        catch (JsonException)
        {
            return "agent";
        }
    }

    private static string? FirstString(JsonElement root, string key)
    {
        if (!root.TryGetProperty(key, out var value)) return null;
        return value.ValueKind == JsonValueKind.String ? value.GetString() : value.ToString();
    }
}

public sealed class AgentPlanModePolicy
{
    public const string ExitPlanApprovalReason = "Plan approval is required before leaving Plan mode.";

    private readonly ChatRunMode _initialRunMode;
    private bool _planExited;
    private bool _planQuestionAnswered;
    private bool _planExecutionApproved;

    public AgentPlanModePolicy(ChatRunMode runMode)
    {
        _initialRunMode = runMode;
        _planExited = runMode == ChatRunMode.Agent;
        _planQuestionAnswered = runMode == ChatRunMode.Agent;
        _planExecutionApproved = false;
    }

    public bool PlanExecutionApproved => _planExecutionApproved;
    public bool PlanExited => _planExited;
    public bool PlanQuestionAnswered => _planQuestionAnswered;

    public AgentToolResult? BlockingResult(AgentToolCall call)
    {
        var toolName = AgentToolNameCanonicalizer.Canonical(call.Name);
        if (_initialRunMode == ChatRunMode.Plan && !_planExited && !IsPlanModeSafe(toolName, call))
        {
            return PolicyBlock(call, PlanModePolicyBlockMessage(toolName));
        }

        if (toolName == "SwitchMode" &&
            SwitchModeTarget(call.InputJson) == "agent" &&
            _initialRunMode == ChatRunMode.Plan &&
            !_planExited &&
            !_planQuestionAnswered &&
            !IsRecoveredPlainTextPlan(call.InputJson))
        {
            return PolicyBlock(
                call,
                "Plan mode requires AskQuestion before leaving Plan mode. Ask the user a blocking question first, then generate the final plan.");
        }

        return null;
    }

    public bool AllowsWithoutGenericPermission(AgentToolCall call)
    {
        return _initialRunMode == ChatRunMode.Plan &&
               !_planExited &&
               AgentToolNameCanonicalizer.Canonical(call.Name) == "Shell" &&
               AgentToolBehaviorClassifier.IsReadOnlyShell(call.InputJson);
    }

    public bool RequiresExitPlanApproval(AgentToolCall call)
    {
        return _initialRunMode == ChatRunMode.Plan &&
               !_planExited &&
               AgentToolNameCanonicalizer.Canonical(call.Name) == "SwitchMode" &&
               SwitchModeTarget(call.InputJson) == "agent";
    }

    public void Record(AgentToolCall call, AgentToolResult result)
    {
        if (result.IsPolicyBlock) return;
        var toolName = AgentToolNameCanonicalizer.Canonical(call.Name);
        if (toolName == "AskQuestion" && !result.IsError)
        {
            _planQuestionAnswered = true;
        }

        if (toolName == "SwitchMode" && !result.IsError)
        {
            var mode = SwitchModeTarget(call.InputJson);
            if (mode == "agent")
            {
                _planExited = true;
                _planExecutionApproved = true;
            }
            else if (mode == "plan")
            {
                _planExited = false;
                _planExecutionApproved = false;
            }
        }
    }

    private static bool IsPlanModeSafe(string toolName, AgentToolCall call)
    {
        return toolName switch
        {
            "Read" or "Glob" or "Grep" or "SemanticSearch" or "ReadLints" or "Skill" or "TodoRead" or "TodoWrite" or "AskQuestion" or "SwitchMode" or "Await" => true,
            "Shell" => AgentToolBehaviorClassifier.IsReadOnlyShell(call.InputJson),
            "Task" => AgentToolBehaviorClassifier.IsReadOnlyTask(call.InputJson),
            _ => false,
        };
    }

    private static string PlanModePolicyBlockMessage(string toolName)
    {
        return toolName == "Shell"
            ? "Plan mode skipped this write-capable shell command. Use read-only commands while planning, then call SwitchMode with mode=\"agent\" and a concrete plan before mutating the workspace."
            : $"Plan mode skipped this workspace-changing {toolName} tool. Continue planning with read/search tools, then call SwitchMode with mode=\"agent\" and a concrete plan before mutating the workspace.";
    }

    private static AgentToolResult PolicyBlock(AgentToolCall call, string output) =>
        new(call.Id, AgentToolNameCanonicalizer.Canonical(call.Name), output, false, IsPolicyBlock: true);

    private static string SwitchModeTarget(string inputJson)
    {
        try
        {
            using var doc = JsonDocument.Parse(string.IsNullOrWhiteSpace(inputJson) ? "{}" : inputJson);
            if (doc.RootElement.ValueKind != JsonValueKind.Object) return "agent";
            return StringValue(doc.RootElement, "mode")?.Trim().ToLowerInvariant() ?? "agent";
        }
        catch (JsonException)
        {
            return "agent";
        }
    }

    private static bool IsRecoveredPlainTextPlan(string inputJson)
    {
        try
        {
            using var doc = JsonDocument.Parse(string.IsNullOrWhiteSpace(inputJson) ? "{}" : inputJson);
            if (doc.RootElement.ValueKind != JsonValueKind.Object) return false;
            return doc.RootElement.TryGetProperty("recoveredFromPlainText", out var value) &&
                   value.ValueKind == JsonValueKind.True;
        }
        catch (JsonException)
        {
            return false;
        }
    }

    private static string? StringValue(JsonElement root, string key)
    {
        if (!root.TryGetProperty(key, out var value)) return null;
        return value.ValueKind == JsonValueKind.String ? value.GetString() : value.ToString();
    }
}

public static class AgentDestructiveToolClassifier
{
    public const string ApprovalReason = "Destructive action plan approval is required before deleting workspace files.";

    public static bool IsDestructive(AgentToolCall call)
    {
        var toolName = AgentToolNameCanonicalizer.Canonical(call.Name);
        if (toolName == "Delete") return true;
        return toolName == "Shell" &&
               StringValue(call.InputJson, "command") is { } command &&
               IsDestructiveShellCommand(command);
    }

    public static string PlanJson(AgentToolCall call)
    {
        var toolName = AgentToolNameCanonicalizer.Canonical(call.Name);
        var target = TargetDescription(call);
        return JsonSerializer.Serialize(new SortedDictionary<string, object?>
        {
            ["destructiveTool"] = toolName,
            ["mode"] = "agent",
            ["plan"] = $"The agent is about to run a deletion-capable {toolName} operation. Target: {target}.\n\nAfter execution, the agent should verify that the target no longer exists.",
            ["target"] = target,
            ["title"] = "Destructive change approval",
        }, new JsonSerializerOptions { WriteIndented = true });
    }

    public static string TargetDescription(AgentToolCall call)
    {
        var toolName = AgentToolNameCanonicalizer.Canonical(call.Name);
        if (toolName == "Delete")
        {
            return StringValue(call.InputJson, "path") ?? "selected path";
        }

        if (toolName == "Shell" && StringValue(call.InputJson, "command") is { } command)
        {
            return Compact(command, 120);
        }

        return toolName;
    }

    private static bool IsDestructiveShellCommand(string command)
    {
        return command
            .ToLowerInvariant()
            .Split(['\n', ';', '&', '|'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Any(segment =>
            {
                var normalized = segment.StartsWith("sudo ", StringComparison.Ordinal)
                    ? segment[5..]
                    : segment;
                return normalized.StartsWith("rm ", StringComparison.Ordinal) ||
                       normalized.StartsWith("rmdir ", StringComparison.Ordinal) ||
                       normalized.StartsWith("trash ", StringComparison.Ordinal) ||
                       normalized.StartsWith("del ", StringComparison.Ordinal) ||
                       normalized.StartsWith("erase ", StringComparison.Ordinal) ||
                       normalized.StartsWith("remove-item ", StringComparison.Ordinal) ||
                       normalized.StartsWith("ri ", StringComparison.Ordinal) ||
                       (normalized.StartsWith("find ", StringComparison.Ordinal) && normalized.Contains(" -delete", StringComparison.Ordinal));
            });
    }

    private static string? StringValue(string inputJson, string key)
    {
        try
        {
            using var doc = JsonDocument.Parse(string.IsNullOrWhiteSpace(inputJson) ? "{}" : inputJson);
            if (doc.RootElement.ValueKind != JsonValueKind.Object) return null;
            if (!doc.RootElement.TryGetProperty(key, out var value)) return null;
            var text = value.ValueKind == JsonValueKind.String ? value.GetString() : value.ToString();
            return string.IsNullOrWhiteSpace(text) ? null : text.Trim();
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static string Compact(string value, int limit)
    {
        var normalized = value.Replace("\r", " ").Replace("\n", " ").Replace("\t", " ").Trim();
        return normalized.Length <= limit ? normalized : normalized[..Math.Max(0, limit - 1)] + "...";
    }
}

public sealed class AgentDeletionVerificationPolicy
{
    private bool _hasSuccessfulDeletion;

    public AgentToolResult Record(AgentToolCall call, AgentToolResult result)
    {
        if (result.IsPolicyBlock)
        {
            return result;
        }

        if (IsBenign(result, call))
        {
            return result with { IsBenignVerification = true };
        }

        if (!result.IsError && AgentDestructiveToolClassifier.IsDestructive(call))
        {
            _hasSuccessfulDeletion = true;
        }

        return result;
    }

    private bool IsBenign(AgentToolResult result, AgentToolCall call)
    {
        return _hasSuccessfulDeletion &&
               result.IsError &&
               IsVerificationTool(call.Name) &&
               IsMissingPathOutput(result.Output);
    }

    private static bool IsVerificationTool(string toolName)
    {
        return AgentToolNameCanonicalizer.Canonical(toolName) is "Glob" or "Read" or "Grep";
    }

    private static bool IsMissingPathOutput(string output)
    {
        var lower = output.ToLowerInvariant();
        return lower.Contains("path does not exist", StringComparison.Ordinal) ||
               lower.Contains("no such file", StringComparison.Ordinal) ||
               lower.Contains("directory not found", StringComparison.Ordinal) ||
               lower.Contains("file not found", StringComparison.Ordinal) ||
               lower.Contains("couldn't be opened", StringComparison.Ordinal) ||
               lower.Contains("couldn\u2019t be opened", StringComparison.Ordinal) ||
               lower.Contains("does not exist", StringComparison.Ordinal) ||
               lower.Contains("could not find", StringComparison.Ordinal);
    }
}

public sealed record AgentToolDeduplicationDecision(AgentToolResult? Result, bool Skip);

public sealed class AgentToolDeduplicationPolicy
{
    private readonly HashSet<string> _executedToolSignatures = new(StringComparer.Ordinal);
    private int _workspaceMutationEpoch;
    private string? _todosSignature = "[]";

    public AgentToolDeduplicationDecision? Deduplicate(AgentToolCall call)
    {
        var canonicalName = AgentToolNameCanonicalizer.Canonical(call.Name);
        if (canonicalName == "TodoWrite")
        {
            var incoming = TodoSnapshotSignature(call.InputJson);
            if (!string.IsNullOrWhiteSpace(incoming) && incoming == _todosSignature)
            {
                return new AgentToolDeduplicationDecision(
                    DuplicateToolResult(
                        call,
                        "Todo list is already up to date. Continue with the next unfinished item or inspect current files before updating TodoWrite again."),
                    false);
            }

            return null;
        }

        if (MarkToolCallIfNeeded(call))
        {
            return null;
        }

        if (IsDuplicateSoftBlockTool(call))
        {
            return new AgentToolDeduplicationDecision(
                DuplicateToolResult(
                    call,
                    "Duplicate tool request skipped; inspect current file or continue with the next distinct step."),
                false);
        }

        return new AgentToolDeduplicationDecision(null, true);
    }

    public bool WouldSkipWithoutResult(AgentToolCall call)
    {
        var normalized = ToolArgumentNormalizer.Normalize(call);
        if (normalized.RecoveryResult is not null)
        {
            return false;
        }

        call = normalized.Call;
        if (AgentToolNameCanonicalizer.Canonical(call.Name) == "TodoWrite")
        {
            return false;
        }

        return _executedToolSignatures.Contains(DeduplicationKey(call)) &&
               !IsDuplicateSoftBlockTool(call);
    }

    public void Record(AgentToolCall call, AgentToolResult result)
    {
        if (result.IsPolicyBlock) return;
        var toolName = AgentToolNameCanonicalizer.Canonical(call.Name);
        if (!result.IsError && toolName == "TodoWrite")
        {
            _todosSignature = TodoSnapshotSignature(call.InputJson);
        }

        if (!result.IsError && AgentToolBehaviorClassifier.IsWorkspaceMutatingTool(call))
        {
            _workspaceMutationEpoch++;
        }
    }

    private bool MarkToolCallIfNeeded(AgentToolCall call) =>
        _executedToolSignatures.Add(DeduplicationKey(call));

    private string DeduplicationKey(AgentToolCall call)
    {
        var canonicalName = AgentToolNameCanonicalizer.Canonical(call.Name);
        var baseKey = $"{canonicalName}:{call.InputJson}";
        return IsEpochScopedTool(call) ? $"{_workspaceMutationEpoch}:{baseKey}" : baseKey;
    }

    private static bool IsEpochScopedTool(AgentToolCall call)
    {
        return AgentToolNameCanonicalizer.Canonical(call.Name) switch
        {
            "Read" or "Grep" or "Glob" or "ReadLints" or "SemanticSearch" or "TodoRead" or "Skill" or "Await" => true,
            "Shell" => AgentToolBehaviorClassifier.IsReadOnlyShell(call.InputJson),
            "Task" => AgentToolBehaviorClassifier.IsReadOnlyTask(call.InputJson),
            _ => false,
        };
    }

    private static bool IsDuplicateSoftBlockTool(AgentToolCall call)
    {
        return AgentToolNameCanonicalizer.Canonical(call.Name) switch
        {
            "Write" or "StrReplace" or "Delete" or "EditNotebook" => true,
            "Shell" => !AgentToolBehaviorClassifier.IsReadOnlyShell(call.InputJson),
            "Task" => !AgentToolBehaviorClassifier.IsReadOnlyTask(call.InputJson),
            _ => false,
        };
    }

    private static AgentToolResult DuplicateToolResult(AgentToolCall call, string detail) =>
        new(call.Id, AgentToolNameCanonicalizer.Canonical(call.Name), detail, false, IsPolicyBlock: true);

    private static string? TodoSnapshotSignature(string inputJson)
    {
        try
        {
            using var doc = JsonDocument.Parse(string.IsNullOrWhiteSpace(inputJson) ? "{}" : inputJson);
            if (doc.RootElement.ValueKind == JsonValueKind.Object &&
                doc.RootElement.TryGetProperty("todos", out var todos))
            {
                return JsonCanonicalizer.ToCanonicalJson(todos);
            }

            return doc.RootElement.ValueKind == JsonValueKind.Array
                ? JsonCanonicalizer.ToCanonicalJson(doc.RootElement)
                : null;
        }
        catch (JsonException)
        {
            return null;
        }
    }
}

public static class AgentToolBehaviorClassifier
{
    public static bool IsReadOnlyTool(AgentToolCall call)
    {
        return AgentToolNameCanonicalizer.Canonical(call.Name) switch
        {
            "Read" or "Glob" or "Grep" or "SemanticSearch" or "ReadLints" or "TodoRead" or "AskQuestion" or "SwitchMode" or "Await" or "Skill" => true,
            "Shell" => IsReadOnlyShell(call.InputJson),
            "Task" => IsReadOnlyTask(call.InputJson),
            _ => false,
        };
    }

    public static bool IsWorkspaceMutatingTool(AgentToolCall call)
    {
        return AgentToolNameCanonicalizer.Canonical(call.Name) switch
        {
            "Write" or "StrReplace" or "Delete" or "EditNotebook" => true,
            "Shell" => !IsReadOnlyShell(call.InputJson),
            "Task" => !IsReadOnlyTask(call.InputJson),
            _ => false,
        };
    }

    public static bool IsReadOnlyShell(string inputJson)
    {
        var command = StringValue(inputJson, "command");
        if (string.IsNullOrWhiteSpace(command)) return false;
        var trimmed = command.Trim().ToLowerInvariant();
        var writeMarkers = new[]
        {
            ">", ">>", "| tee", " out-file", " set-content", " add-content", "rm ", "del ", "erase ", "remove-item",
            "mv ", "move-item", "cp ", "copy-item", "mkdir ", "new-item", "touch ", "sed -i", "perl -pi",
            "python ", "node ", "npm ", "bun ", "dotnet ", "msbuild "
        };
        if (writeMarkers.Any(marker => trimmed.Contains(marker, StringComparison.Ordinal)))
        {
            return false;
        }

        var readPrefixes = new[]
        {
            "date", "get-date", "pwd", "ls", "dir", "get-childitem", "find", "grep", "rg", "select-string",
            "cat", "type", "get-content", "wc", "measure-object", "head", "tail", "stat", "file", "du",
            "git status", "git diff", "git log", "git show", "git ls-files"
        };
        return readPrefixes.Any(prefix => trimmed == prefix || trimmed.StartsWith(prefix + " ", StringComparison.Ordinal));
    }

    public static bool IsReadOnlyTask(string inputJson)
    {
        var type = StringValue(inputJson, "type") ?? "generalPurpose";
        return type.Trim().ToLowerInvariant() is "explore" or "cursor-guide" or "ci-investigator";
    }

    private static string? StringValue(string inputJson, string key)
    {
        try
        {
            using var doc = JsonDocument.Parse(string.IsNullOrWhiteSpace(inputJson) ? "{}" : inputJson);
            if (doc.RootElement.ValueKind != JsonValueKind.Object) return null;
            if (!doc.RootElement.TryGetProperty(key, out var value)) return null;
            return value.ValueKind == JsonValueKind.String ? value.GetString() : value.ToString();
        }
        catch (JsonException)
        {
            return null;
        }
    }
}

public static class ToolArgumentNormalizer
{
    internal static readonly JsonSerializerOptions JsonWriteOptions = new()
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public const string InvalidJsonRecoveryMessage =
        "Tool input was invalid JSON. Retry with a JSON object using double-quoted keys and strings.";

    public static IReadOnlyList<NormalizedInvocation> Normalize(IEnumerable<AgentToolCall> calls) =>
        calls.Select(Normalize).ToList();

    public static NormalizedInvocation Normalize(AgentToolCall call)
    {
        var canonicalName = AgentToolNameCanonicalizer.Canonical(call.Name);
        var canonicalJson = CanonicalObjectJson(call.InputJson);
        if (!canonicalJson.Success)
        {
            var safeCall = new AgentToolCall(call.Id, canonicalName, "{}");
            var output = $"{InvalidJsonRecoveryMessage}\n\nTool: {canonicalName}\nError: {canonicalJson.Error!.Message}";
            return new NormalizedInvocation(
                safeCall,
                new AgentToolResult(call.Id, canonicalName, output, true));
        }

        if (CanonicalizedLegacySearchInvocation(call.Id, canonicalName, canonicalJson.Json!) is { } legacy)
        {
            return legacy;
        }

        var canonicalInput = CanonicalToolInputJson(canonicalName, canonicalJson.Json!);
        return new NormalizedInvocation(new AgentToolCall(call.Id, canonicalName, canonicalInput), null);
    }

    public static string ProviderSafeInputJson(string inputJson) =>
        CanonicalObjectJson(inputJson).Json ?? "{}";

    public static (bool Success, string? Json, NormalizationError? Error) CanonicalObjectJson(string inputJson)
    {
        var value = string.IsNullOrWhiteSpace(inputJson) ? "{}" : inputJson.Trim();
        try
        {
            using var doc = JsonDocument.Parse(value);
            if (doc.RootElement.ValueKind != JsonValueKind.Object)
            {
                return (false, null, new NormalizationError("Tool arguments must be a JSON object."));
            }

            return (true, JsonCanonicalizer.ToCanonicalJson(doc.RootElement), null);
        }
        catch (JsonException ex)
        {
            return (false, null, new NormalizationError(ex.Message));
        }
    }

    private static NormalizedInvocation? CanonicalizedLegacySearchInvocation(string callId, string toolName, string inputJson)
    {
        if (toolName is not ("WebSearch" or "Weather")) return null;

        using var doc = JsonDocument.Parse(inputJson);
        var root = doc.RootElement;
        var rawQuery = FirstStringValue(root, ["query", "q", "search_query", "location", "city", "place"]);
        if (string.IsNullOrWhiteSpace(rawQuery))
        {
            return new NormalizedInvocation(
                new AgentToolCall(callId, "Skill", "{}"),
                new AgentToolResult(callId, "Skill", $"{toolName} is disabled. Use Skill with g9claw-rag:glm-web-search and provide a query.", true));
        }

        var args = rawQuery.Trim();
        if (toolName == "Weather" &&
            !args.Contains("weather", StringComparison.OrdinalIgnoreCase) &&
            !args.Contains("天气", StringComparison.Ordinal))
        {
            args = $"{args} weather";
        }

        var mapped = JsonSerializer.Serialize(new SortedDictionary<string, object?>
        {
            ["args"] = args,
            ["skill"] = "g9claw-rag:glm-web-search",
        }, JsonWriteOptions);
        return new NormalizedInvocation(new AgentToolCall(callId, "Skill", mapped), null);
    }

    private static string CanonicalToolInputJson(string toolName, string inputJson)
    {
        var node = JsonNode.Parse(inputJson) as JsonObject;
        if (node is null) return inputJson;

        switch (toolName)
        {
            case "Shell":
                CanonicalizeShellInput(node);
                break;
            case "Skill":
                CanonicalizeSkillInput(node);
                break;
            case "Task":
                CanonicalizeTaskInput(node);
                break;
            case "StrReplace":
                MoveProperty(node, "oldString", "old_string");
                MoveProperty(node, "newString", "new_string");
                break;
            case "Await":
                if (!node.ContainsKey("task_id"))
                {
                    node["task_id"] = CloneOrString(node["id"]) ?? CloneOrString(node["taskId"]);
                }
                node.Remove("id");
                node.Remove("taskId");
                break;
        }

        return JsonCanonicalizer.ToCanonicalJson(node);
    }

    private static void CanonicalizeShellInput(JsonObject node)
    {
        var command = FirstNonBlank(node, "command") ?? FirstNonBlank(node, "input") ?? FirstNonBlank(node, "input_command") ?? FirstNonBlank(node, "cmd");
        if (!string.IsNullOrWhiteSpace(command)) node["command"] = SanitizeXmlParameterWrapper(command);
        node.Remove("input");
        node.Remove("input_command");
        node.Remove("cmd");
        if (!node.ContainsKey("timeout") && node["timeout_seconds"] is not null)
        {
            node["timeout"] = CloneOrString(node["timeout_seconds"]);
        }
        node.Remove("timeout_seconds");
    }

    private static void CanonicalizeSkillInput(JsonObject node)
    {
        var skill = FirstNonBlank(node, "skill");
        var args = FirstNonBlank(node, "args");
        if (skill is not null) node["skill"] = SanitizeXmlParameterWrapper(skill);
        if (args is not null) node["args"] = SanitizeXmlParameterWrapper(args);
    }

    private static void CanonicalizeTaskInput(JsonObject node)
    {
        if (!node.ContainsKey("prompt"))
        {
            node["prompt"] = FirstNonBlank(node, "description") ?? FirstNonBlank(node, "subject") ??
                             FirstNonBlank(node, "command") ?? FirstNonBlank(node, "input") ?? "";
        }
        if (!node.ContainsKey("type") && node["subagent_type"] is not null)
        {
            node["type"] = CloneOrString(node["subagent_type"]);
        }
        node.Remove("subagent_type");
        node.Remove("input");
    }

    private static string? FirstStringValue(JsonElement root, IEnumerable<string> keys)
    {
        foreach (var key in keys)
        {
            if (!root.TryGetProperty(key, out var value)) continue;
            var text = value.ValueKind switch
            {
                JsonValueKind.String => value.GetString(),
                JsonValueKind.Number => value.GetRawText(),
                JsonValueKind.True => "true",
                JsonValueKind.False => "false",
                _ => value.ToString(),
            };
            if (!string.IsNullOrWhiteSpace(text)) return text;
        }

        return null;
    }

    private static string? FirstNonBlank(JsonObject node, params string[] keys)
    {
        foreach (var key in keys)
        {
            var jsonNode = node[key];
            if (jsonNode is null) continue;
            string value;
            try
            {
                value = jsonNode.GetValue<string>();
            }
            catch
            {
                value = jsonNode.ToJsonString();
            }
            if (!string.IsNullOrWhiteSpace(value)) return value;
        }

        return null;
    }

    private static JsonNode? CloneOrString(JsonNode? node) =>
        node is null ? null : JsonNode.Parse(node.ToJsonString());

    private static void MoveProperty(JsonObject node, string oldName, string newName)
    {
        if (!node.ContainsKey(newName) && node[oldName] is not null)
        {
            node[newName] = CloneOrString(node[oldName]);
        }
        node.Remove(oldName);
    }

    private static string SanitizeXmlParameterWrapper(string value)
    {
        var cleaned = value.Trim();
        cleaned = Regex.Replace(cleaned, @"(?is)^<parameter(?:\s+[^>]*)?>\s*", "");
        cleaned = Regex.Replace(cleaned, @"(?is)\s*</parameter>\s*$", "");
        return cleaned.Trim();
    }
}

public static partial class NativeAgentRuntime
{
    private static readonly Regex FencedJsonOnly = new(@"^\s*```(?:json)?\s*(?<json>\{[\s\S]*\})\s*```\s*$", RegexOptions.Compiled | RegexOptions.IgnoreCase);
    private static readonly Regex ResponseXmlEnvelope = new(@"(?is)^<response>\s*(?<json>\{.*\})\s*</response>$", RegexOptions.Compiled);
    private static readonly Regex InvokeBlock = new(@"(?is)<invoke\s+name=""(?<name>[^""]+)"">\s*(?<body>.*?)\s*</invoke>", RegexOptions.Compiled);
    private static readonly Regex ParameterBlock = new(@"(?is)<parameter\s+name=""(?<name>[^""]+)"">\s*(?<value>.*?)\s*</parameter>", RegexOptions.Compiled);
    private static readonly Regex CompactXmlCall = new(@"<call=""(?<name>[^""]+)"":(?<input>\{[^<]*?\})\}", RegexOptions.Compiled);
    private static readonly Regex ToolCallXmlBlock = new(@"(?s)<tool_call\s+name=[""'](?<name>[^""']+)[""']\s*>(?<body>.*?)</tool_call>", RegexOptions.Compiled);

    public static IReadOnlyList<AgentToolCall> FallbackToolCalls(string text)
    {
        if (string.IsNullOrWhiteSpace(text)) return [];
        var trimmed = text.Trim();

        var fenced = FencedJsonOnly.Match(trimmed);
        if (fenced.Success) return ToolCallsFromJson(fenced.Groups["json"].Value);

        if (trimmed.StartsWith('{') && trimmed.EndsWith('}')) return ToolCallsFromJson(trimmed);

        var response = ResponseXmlEnvelope.Match(trimmed);
        if (response.Success) return ToolCallsFromJson(response.Groups["json"].Value);

        var invokeCalls = XmlInvokeFallbackToolCalls(trimmed);
        if (invokeCalls.Count > 0) return invokeCalls;

        var inlineJsonCalls = InlineJsonFallbackToolCalls(trimmed);
        if (inlineJsonCalls.Count > 0) return inlineJsonCalls;

        var compactCalls = CompactXmlFallbackToolCalls(trimmed);
        if (compactCalls.Count > 0) return compactCalls;

        if (trimmed.StartsWith("<tool_call", StringComparison.OrdinalIgnoreCase) &&
            trimmed.EndsWith("</tool_call>", StringComparison.OrdinalIgnoreCase))
        {
            return XmlToolCallFallbackToolCalls(trimmed);
        }

        return LegacyCommandFallbackToolCall(trimmed) is { } legacyCommand ? [legacyCommand] : [];
    }

    private static IReadOnlyList<AgentToolCall> XmlInvokeFallbackToolCalls(string text)
    {
        var calls = new List<AgentToolCall>();
        foreach (Match invoke in InvokeBlock.Matches(text))
        {
            if (!invoke.Success) continue;
            var name = invoke.Groups["name"].Value.Trim();
            var args = new SortedDictionary<string, object?>(StringComparer.Ordinal);
            foreach (Match parameter in ParameterBlock.Matches(invoke.Groups["body"].Value))
            {
                var key = parameter.Groups["name"].Value.Trim();
                if (key.Length == 0) continue;
                args[key] = XmlUnescaped(parameter.Groups["value"].Value.Trim());
            }
            if (args.Count == 0) continue;

            calls.Add(
                CanonicalFallbackToolCall(new AgentToolCall(
                    $"call-{Guid.NewGuid():D}",
                    name,
                    JsonSerializer.Serialize(args, ToolArgumentNormalizer.JsonWriteOptions))));
        }

        return calls;
    }

    private static IReadOnlyList<AgentToolCall> InlineJsonFallbackToolCalls(string text)
    {
        if (text.Contains("```", StringComparison.Ordinal)) return [];
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var calls = new List<AgentToolCall>();
        foreach (var snippet in BalancedJsonObjectSnippets(text))
        {
            foreach (var call in ToolCallsFromJson(snippet))
            {
                var signature = $"{call.Name}:{call.InputJson}";
                if (seen.Add(signature)) calls.Add(call);
            }
        }

        return calls;
    }

    private static IReadOnlyList<string> BalancedJsonObjectSnippets(string text)
    {
        var snippets = new List<string>();
        var depth = 0;
        var start = -1;
        var inString = false;
        var escaped = false;
        for (var index = 0; index < text.Length; index++)
        {
            var character = text[index];
            if (inString)
            {
                if (escaped)
                {
                    escaped = false;
                }
                else if (character == '\\')
                {
                    escaped = true;
                }
                else if (character == '"')
                {
                    inString = false;
                }
                continue;
            }

            if (character == '"')
            {
                inString = true;
            }
            else if (character == '{')
            {
                if (depth == 0) start = index;
                depth++;
            }
            else if (character == '}' && depth > 0)
            {
                depth--;
                if (depth == 0 && start >= 0)
                {
                    snippets.Add(text[start..(index + 1)]);
                    start = -1;
                }
            }
        }

        return snippets;
    }

    private static IReadOnlyList<AgentToolCall> CompactXmlFallbackToolCalls(string text)
    {
        var calls = new List<AgentToolCall>();
        foreach (Match match in CompactXmlCall.Matches(text))
        {
            var call = CompactXmlToolCall(match.Groups["name"].Value, match.Groups["input"].Value);
            if (call is not null) calls.Add(call);
        }

        return calls;
    }

    private static AgentToolCall? CompactXmlToolCall(string rawName, string rawInput)
    {
        try
        {
            using var doc = JsonDocument.Parse(rawInput);
            var input = doc.RootElement.ValueKind == JsonValueKind.Object ? doc.RootElement : default;
            var lowerName = rawName.ToLowerInvariant();
            string toolName;
            SortedDictionary<string, object?> normalizedInput;
            switch (lowerName)
            {
                case "executebash":
                case "bash":
                case "shell":
                case "runcommand":
                    var command = FirstString(input, "command") ??
                                  FirstString(input, "input_command") ??
                                  FirstString(input, "input") ??
                                  "";
                    if (command.TrimStart().StartsWith("ls", StringComparison.Ordinal))
                    {
                        toolName = "Glob";
                        normalizedInput = new SortedDictionary<string, object?>(StringComparer.Ordinal)
                        {
                            ["path"] = ".",
                            ["pattern"] = "*",
                        };
                    }
                    else
                    {
                        toolName = "Shell";
                        normalizedInput = new SortedDictionary<string, object?>(StringComparer.Ordinal)
                        {
                            ["command"] = command,
                        };
                    }
                    break;
                case "readfile":
                case "read":
                    toolName = "Read";
                    normalizedInput = new SortedDictionary<string, object?>(StringComparer.Ordinal)
                    {
                        ["file_path"] = FirstString(input, "file_path") ??
                                        FirstString(input, "path") ??
                                        FirstString(input, "input") ??
                                        "",
                    };
                    break;
                case "writefile":
                case "write":
                    toolName = "Write";
                    normalizedInput = new SortedDictionary<string, object?>(StringComparer.Ordinal)
                    {
                        ["content"] = FirstString(input, "content") ?? "",
                        ["file_path"] = FirstString(input, "file_path") ?? FirstString(input, "path") ?? "",
                    };
                    break;
                case "editfile":
                case "edit":
                case "strreplace":
                    toolName = "StrReplace";
                    normalizedInput = new SortedDictionary<string, object?>(StringComparer.Ordinal)
                    {
                        ["file_path"] = FirstString(input, "file_path") ?? FirstString(input, "path") ?? "",
                        ["new_string"] = FirstString(input, "new_string") ?? "",
                        ["old_string"] = FirstString(input, "old_string") ?? "",
                    };
                    break;
                default:
                    return null;
            }

            return new AgentToolCall(
                $"call-{Guid.NewGuid():D}",
                toolName,
                JsonSerializer.Serialize(normalizedInput, ToolArgumentNormalizer.JsonWriteOptions));
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static IReadOnlyList<AgentToolCall> XmlToolCallFallbackToolCalls(string text)
    {
        var calls = new List<AgentToolCall>();
        foreach (Match match in ToolCallXmlBlock.Matches(text))
        {
            var name = match.Groups["name"].Value;
            var body = match.Groups["body"].Value.Trim();
            if (string.IsNullOrWhiteSpace(name)) continue;
            var inputJson = body.StartsWith('{')
                ? body
                : JsonSerializer.Serialize(new SortedDictionary<string, object?>
                {
                    ["input"] = body,
                }, ToolArgumentNormalizer.JsonWriteOptions);
            calls.Add(new AgentToolCall($"call-{Guid.NewGuid():D}", name, inputJson));
        }

        return calls;
    }

    private static AgentToolCall? LegacyCommandFallbackToolCall(string text)
    {
        foreach (var pattern in new[] { @"(?is)^<command>\s*(?<body>.*?)\s*</command>$", @"(?is)^<bash>\s*(?<body>.*?)\s*</bash>$" })
        {
            var match = Regex.Match(text, pattern);
            if (!match.Success) continue;

            var body = match.Groups["body"].Value.Trim();
            if (string.IsNullOrWhiteSpace(body)) return null;

            var command = body;
            var description = "Run workspace command";
            if (body.StartsWith("{", StringComparison.Ordinal))
            {
                try
                {
                    using var doc = JsonDocument.Parse(body);
                    if (doc.RootElement.ValueKind == JsonValueKind.Object)
                    {
                        command = FirstString(doc.RootElement, "command") ??
                                  FirstString(doc.RootElement, "cmd") ??
                                  FirstString(doc.RootElement, "input") ??
                                  "";
                        description = FirstString(doc.RootElement, "description") ?? description;
                    }
                }
                catch (JsonException)
                {
                    command = body;
                }
            }

            var trimmedCommand = command.Trim();
            if (string.IsNullOrWhiteSpace(trimmedCommand)) return null;

            if (trimmedCommand == "ls" || trimmedCommand.StartsWith("ls ", StringComparison.Ordinal))
            {
                return new AgentToolCall(
                    $"call-{Guid.NewGuid():D}",
                    "Glob",
                    JsonSerializer.Serialize(new SortedDictionary<string, object?>
                    {
                        ["path"] = ".",
                        ["pattern"] = "*",
                    }, ToolArgumentNormalizer.JsonWriteOptions));
            }

            return new AgentToolCall(
                $"call-{Guid.NewGuid():D}",
                "Shell",
                JsonSerializer.Serialize(new SortedDictionary<string, object?>
                {
                    ["command"] = trimmedCommand,
                    ["description"] = description,
                }, ToolArgumentNormalizer.JsonWriteOptions));
        }

        return null;
    }

    private static IReadOnlyList<AgentToolCall> ToolCallsFromJson(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.ValueKind != JsonValueKind.Object) return [];
            var root = doc.RootElement;

            if (root.TryGetProperty("tool_calls", out var rawToolCalls) &&
                rawToolCalls.ValueKind == JsonValueKind.Array)
            {
                return ToolCallsFromJsonArray(rawToolCalls);
            }

            if (root.TryGetProperty("tools", out var rawTools) &&
                rawTools.ValueKind == JsonValueKind.Array)
            {
                return ToolCallsFromJsonArray(rawTools);
            }

            return ToolCallFromJsonObject(root) is { } call ? [call] : [];
        }
        catch (JsonException)
        {
            return [];
        }
    }

    private static IReadOnlyList<AgentToolCall> ToolCallsFromJsonArray(JsonElement rawCalls)
    {
        var calls = new List<AgentToolCall>();
        foreach (var rawCall in rawCalls.EnumerateArray())
        {
            if (ToolCallFromJsonObject(rawCall) is { } call)
            {
                calls.Add(call);
            }
        }

        return calls;
    }

    private static AgentToolCall? ToolCallFromJsonObject(JsonElement root)
    {
        if (root.ValueKind != JsonValueKind.Object) return null;
        var callId = FallbackCallId(root);
        var skill = FirstString(root, "skill");
        if (!string.IsNullOrWhiteSpace(skill))
        {
            var payload = JsonSerializer.Serialize(new SortedDictionary<string, object?>
            {
                ["args"] = FirstString(root, "args") ?? "",
                ["skill"] = skill,
            }, ToolArgumentNormalizer.JsonWriteOptions);
            return CanonicalFallbackToolCall(new AgentToolCall(callId, "Skill", payload));
        }

        var rawName = FirstString(root, "tool") ??
                      FirstString(root, "name") ??
                      FunctionString(root, "name");
        if (string.IsNullOrWhiteSpace(rawName)) return null;

        var toolName = AgentToolNameCanonicalizer.Canonical(rawName);
        var hasInput = TryGetRawInput(root, out var rawInput);
        if (toolName == "Shell" &&
            hasInput &&
            CommandString(rawInput) is { } command &&
            command.TrimStart().StartsWith("ls", StringComparison.Ordinal))
        {
            return new AgentToolCall(
                callId,
                "Glob",
                JsonSerializer.Serialize(new SortedDictionary<string, object?>
                {
                    ["path"] = ".",
                    ["pattern"] = "*",
                }, ToolArgumentNormalizer.JsonWriteOptions));
        }

        var inputJson = hasInput ? InputJsonFromRawInput(rawInput) : "{}";
        return CanonicalFallbackToolCall(new AgentToolCall(callId, toolName, inputJson));
    }

    private static string FallbackCallId(JsonElement root) =>
        FirstString(root, "id") is { } id && !string.IsNullOrWhiteSpace(id)
            ? id
            : $"call-{Guid.NewGuid():D}";

    private static string? FunctionString(JsonElement root, string key)
    {
        if (!root.TryGetProperty("function", out var function) ||
            function.ValueKind != JsonValueKind.Object)
        {
            return null;
        }

        return FirstString(function, key);
    }

    private static bool TryGetRawInput(JsonElement root, out JsonElement rawInput)
    {
        if (root.TryGetProperty("input", out rawInput)) return true;
        if (root.TryGetProperty("arguments", out rawInput)) return true;
        if (root.TryGetProperty("function", out var function) &&
            function.ValueKind == JsonValueKind.Object &&
            function.TryGetProperty("arguments", out rawInput))
        {
            return true;
        }

        rawInput = default;
        return false;
    }

    private static string InputJsonFromRawInput(JsonElement rawInput)
    {
        if (rawInput.ValueKind == JsonValueKind.String)
        {
            var input = rawInput.GetString() ?? "";
            var trimmed = input.Trim();
            return trimmed.StartsWith('{')
                ? trimmed
                : JsonSerializer.Serialize(new SortedDictionary<string, object?>
                {
                    ["input"] = input,
                }, ToolArgumentNormalizer.JsonWriteOptions);
        }

        return JsonCanonicalizer.ToCanonicalJson(rawInput);
    }

    private static string? CommandString(JsonElement rawInput)
    {
        if (rawInput.ValueKind == JsonValueKind.String) return rawInput.GetString();
        if (rawInput.ValueKind != JsonValueKind.Object) return null;
        return FirstString(rawInput, "command") ??
               FirstString(rawInput, "input_command") ??
               FirstString(rawInput, "input");
    }

    private static string? FirstString(JsonElement root, string key)
    {
        if (!root.TryGetProperty(key, out var value)) return null;
        return value.ValueKind == JsonValueKind.String ? value.GetString() : value.ToString();
    }

    private static AgentToolCall CanonicalFallbackToolCall(AgentToolCall call)
    {
        var canonicalName = AgentToolNameCanonicalizer.Canonical(call.Name);
        if (!canonicalName.StartsWith("g9claw-rag:", StringComparison.OrdinalIgnoreCase))
        {
            return call with { Name = canonicalName };
        }

        var args = "";
        try
        {
            using var doc = JsonDocument.Parse(call.InputJson);
            if (doc.RootElement.ValueKind == JsonValueKind.Object)
            {
                args = FirstString(doc.RootElement, "args") ??
                       FirstString(doc.RootElement, "query") ??
                       FirstString(doc.RootElement, "prompt") ??
                       "";
            }
        }
        catch (JsonException)
        {
            args = "";
        }

        var payload = JsonSerializer.Serialize(new SortedDictionary<string, object?>
        {
            ["args"] = args,
            ["skill"] = canonicalName,
        }, ToolArgumentNormalizer.JsonWriteOptions);
        return new AgentToolCall(call.Id, "Skill", payload);
    }

    private static string XmlUnescaped(string value) =>
        value
            .Replace("&quot;", "\"", StringComparison.Ordinal)
            .Replace("&apos;", "'", StringComparison.Ordinal)
            .Replace("&lt;", "<", StringComparison.Ordinal)
            .Replace("&gt;", ">", StringComparison.Ordinal)
            .Replace("&amp;", "&", StringComparison.Ordinal);
}

internal static class JsonCanonicalizer
{
    public static string ToCanonicalJson(JsonElement element)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
        {
            WriteElement(writer, element);
        }
        return Encoding.UTF8.GetString(stream.ToArray());
    }

    public static string ToCanonicalJson(JsonNode node)
    {
        using var doc = JsonDocument.Parse(node.ToJsonString());
        return ToCanonicalJson(doc.RootElement);
    }

    private static void WriteElement(Utf8JsonWriter writer, JsonElement element)
    {
        switch (element.ValueKind)
        {
            case JsonValueKind.Object:
                writer.WriteStartObject();
                foreach (var property in element.EnumerateObject().OrderBy(property => property.Name, StringComparer.Ordinal))
                {
                    writer.WritePropertyName(property.Name);
                    WriteElement(writer, property.Value);
                }
                writer.WriteEndObject();
                break;
            case JsonValueKind.Array:
                writer.WriteStartArray();
                foreach (var item in element.EnumerateArray())
                {
                    WriteElement(writer, item);
                }
                writer.WriteEndArray();
                break;
            case JsonValueKind.String:
                writer.WriteStringValue(element.GetString());
                break;
            case JsonValueKind.Number:
                element.WriteTo(writer);
                break;
            case JsonValueKind.True:
                writer.WriteBooleanValue(true);
                break;
            case JsonValueKind.False:
                writer.WriteBooleanValue(false);
                break;
            case JsonValueKind.Null:
            case JsonValueKind.Undefined:
                writer.WriteNullValue();
                break;
        }
    }
}
