using System.Text.Json;

namespace G9Claw.Windows.Core;

public enum ToolInvocationPhase
{
    Tool,
    Read,
    Edit,
    Search,
    Command,
    Todo,
    Task,
}

public enum ToolInvocationState
{
    Running,
    Completed,
    Failed,
}

public sealed record ToolInvocationPresentation(
    ToolInvocationPhase Phase,
    ToolInvocationState State,
    string Summary,
    string InputPreview,
    string? OutputPreview,
    bool IsBoundary);

public static class ToolInvocationPresenter
{
    public static string? Target(string toolName, string inputJson, int limit = 72)
    {
        var target = ToolInvocationDetailPresentation.Parse(toolName, inputJson).PrimaryValue;
        return string.IsNullOrWhiteSpace(target) ? null : Compact(target, limit);
    }

    public static ToolInvocationPresentation Present(AgentToolCall call, AgentToolResult? result, bool chinese)
    {
        var toolName = AgentToolNameCanonicalizer.Canonical(call.Name);
        var phase = PhaseFor(toolName);
        var state = result is null
            ? ToolInvocationState.Running
            : result.IsError
                ? ToolInvocationState.Failed
                : ToolInvocationState.Completed;
        var input = ToolInput.FromJson(call.InputJson);
        var target = TargetFor(toolName, input);
        var policyBlocked = result?.IsPolicyBlock == true ||
                            result?.Output.TrimStart().StartsWith("Plan mode skipped", StringComparison.Ordinal) == true;
        var summary = Summary(toolName, phase, state, target, chinese, policyBlocked);
        if (TodoListPresentation.Parse(toolName, call.InputJson, result?.Output) is { } todoPresentation)
        {
            summary = todoPresentation.RowTitle(toolName, chinese, state == ToolInvocationState.Running);
        }
        else if (string.Equals(toolName, "Task", StringComparison.OrdinalIgnoreCase) &&
                 TaskInvocationPresentation.Parse(call.InputJson) is { } taskPresentation)
        {
            summary = taskPresentation.RowTitle(chinese, state == ToolInvocationState.Running, state == ToolInvocationState.Failed);
        }

        return new ToolInvocationPresentation(
            phase,
            state,
            summary,
            Compact(string.IsNullOrWhiteSpace(target) ? call.InputJson : target, 240),
            result is null ? null : ToolOutputPreviewLimiter.Preview(result.Output),
            IsBoundary(toolName));
    }

    public static ToolInvocationPresentation PresentGroup(
        IReadOnlyList<(AgentToolCall Call, AgentToolResult? Result)> items,
        bool chinese)
    {
        var running = items.LastOrDefault(item => item.Result is null);
        if (running.Call is not null)
        {
            return Present(running.Call, null, chinese);
        }

        var readTargets = items
            .Where(item => PhaseFor(AgentToolNameCanonicalizer.Canonical(item.Call.Name)) == ToolInvocationPhase.Read)
            .Select(item => Target(item.Call.Name, item.Call.InputJson) ?? item.Call.Id)
            .ToHashSet(StringComparer.Ordinal);
        var editTargets = items
            .Where(item => PhaseFor(AgentToolNameCanonicalizer.Canonical(item.Call.Name)) == ToolInvocationPhase.Edit)
            .Select(item => Target(item.Call.Name, item.Call.InputJson) ?? item.Call.Id)
            .ToHashSet(StringComparer.Ordinal);
        var searches = items.Count(item => PhaseFor(AgentToolNameCanonicalizer.Canonical(item.Call.Name)) == ToolInvocationPhase.Search);
        var commands = items.Count(item => PhaseFor(AgentToolNameCanonicalizer.Canonical(item.Call.Name)) == ToolInvocationPhase.Command);
        var todos = items.Count(item => PhaseFor(AgentToolNameCanonicalizer.Canonical(item.Call.Name)) == ToolInvocationPhase.Todo);
        var other = Math.Max(0, items.Count - readTargets.Count - editTargets.Count - searches - commands - todos);
        var hasKnownWork = todos > 0 || readTargets.Count > 0 || searches > 0 || editTargets.Count > 0 || commands > 0;
        var summary = chinese
            ? string.Join("\u3001", Parts([
                todos > 0 ? "\u5df2\u66f4\u65b0 Todo List" : "",
                readTargets.Count > 0 ? $"\u5df2\u63a2\u7d22 {readTargets.Count} \u4e2a\u6587\u4ef6" : "",
                searches > 0 ? $"\u5df2\u641c\u7d22 {searches} \u6b21" : "",
                editTargets.Count > 0 ? $"\u5df2\u7f16\u8f91 {editTargets.Count} \u4e2a\u6587\u4ef6" : "",
                commands > 0 ? $"\u5df2\u8fd0\u884c {commands} \u6761\u547d\u4ee4" : "",
                !hasKnownWork && other > 0 ? $"\u5df2\u4f7f\u7528 {other} \u4e2a\u5de5\u5177" : "",
            ]))
            : string.Join(", ", Parts([
                todos > 0 ? "updated Todo List" : "",
                readTargets.Count > 0 ? $"explored {readTargets.Count} {(readTargets.Count == 1 ? "file" : "files")}" : "",
                searches > 0 ? $"{searches} {(searches == 1 ? "search" : "searches")}" : "",
                editTargets.Count > 0 ? $"edited {editTargets.Count} {(editTargets.Count == 1 ? "file" : "files")}" : "",
                commands > 0 ? $"ran {commands} {(commands == 1 ? "command" : "commands")}" : "",
                !hasKnownWork && other > 0 ? $"used {other} {(other == 1 ? "tool" : "tools")}" : "",
            ]));
        if (string.IsNullOrWhiteSpace(summary))
        {
            summary = chinese ? $"\u5df2\u4f7f\u7528 {items.Count} \u4e2a\u5de5\u5177" : $"used {items.Count} tools";
        }

        return new ToolInvocationPresentation(
            ToolInvocationPhase.Tool,
            ToolInvocationState.Completed,
            summary,
            summary,
            ToolOutputPreviewLimiter.Preview(items.LastOrDefault(item => item.Result is not null).Result?.Output ?? ""),
            false);
    }

    public static bool IsBoundary(string toolName)
    {
        var canonical = AgentToolNameCanonicalizer.Canonical(toolName);
        return string.Equals(canonical, "TodoWrite", StringComparison.OrdinalIgnoreCase) ||
               string.Equals(canonical, "TodoRead", StringComparison.OrdinalIgnoreCase) ||
               string.Equals(canonical, "Task", StringComparison.OrdinalIgnoreCase);
    }

    private static ToolInvocationPhase PhaseFor(string toolName)
    {
        if (string.Equals(toolName, "Shell", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(toolName, "Await", StringComparison.OrdinalIgnoreCase))
        {
            return ToolInvocationPhase.Command;
        }

        if (string.Equals(toolName, "Read", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(toolName, "ReadLints", StringComparison.OrdinalIgnoreCase))
        {
            return ToolInvocationPhase.Read;
        }

        if (string.Equals(toolName, "Write", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(toolName, "StrReplace", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(toolName, "MultiEdit", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(toolName, "Delete", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(toolName, "EditNotebook", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(toolName, "NotebookEdit", StringComparison.OrdinalIgnoreCase))
        {
            return ToolInvocationPhase.Edit;
        }

        if (string.Equals(toolName, "Grep", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(toolName, "Glob", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(toolName, "SemanticSearch", StringComparison.OrdinalIgnoreCase))
        {
            return ToolInvocationPhase.Search;
        }

        if (string.Equals(toolName, "TodoWrite", StringComparison.OrdinalIgnoreCase) ||
            string.Equals(toolName, "TodoRead", StringComparison.OrdinalIgnoreCase))
        {
            return ToolInvocationPhase.Todo;
        }

        if (string.Equals(toolName, "Task", StringComparison.OrdinalIgnoreCase))
        {
            return ToolInvocationPhase.Task;
        }

        return ToolInvocationPhase.Tool;
    }

    private static string Summary(string toolName, ToolInvocationPhase phase, ToolInvocationState state, string target, bool chinese, bool policyBlocked)
    {
        var suffix = string.IsNullOrWhiteSpace(target) ? "" : $" {target}";
        var canonical = AgentToolNameCanonicalizer.Canonical(toolName);
        if (string.Equals(canonical, "TodoWrite", StringComparison.OrdinalIgnoreCase))
        {
            return state == ToolInvocationState.Running
                ? (chinese ? "\u6b63\u5728\u66f4\u65b0 Todo List" : "Updating Todo List")
                : (chinese ? "\u5df2\u66f4\u65b0 Todo List" : "Updated Todo List");
        }

        if (string.Equals(canonical, "TodoRead", StringComparison.OrdinalIgnoreCase))
        {
            return state == ToolInvocationState.Running
                ? (chinese ? "\u6b63\u5728\u8bfb\u53d6 Todo List" : "Reading Todo List")
                : (chinese ? "\u5df2\u8bfb\u53d6 Todo List" : "Read Todo List");
        }

        return (phase, state, chinese) switch
        {
            (ToolInvocationPhase.Command, _, true) when policyBlocked => $"\u8ba1\u5212\u6a21\u5f0f\u5df2\u8df3\u8fc7\u547d\u4ee4{suffix}",
            (ToolInvocationPhase.Edit, _, true) when policyBlocked => $"\u8ba1\u5212\u6a21\u5f0f\u5df2\u8df3\u8fc7\u7f16\u8f91{suffix}",
            (ToolInvocationPhase.Command, ToolInvocationState.Running, true) => $"\u6b63\u5728\u8fd0\u884c\u547d\u4ee4{suffix}",
            (ToolInvocationPhase.Command, _, true) => $"\u5df2\u8fd0\u884c\u547d\u4ee4{suffix}",
            (ToolInvocationPhase.Read, ToolInvocationState.Running, true) => $"\u6b63\u5728\u8bfb\u53d6{suffix}",
            (ToolInvocationPhase.Read, _, true) => $"\u5df2\u8bfb\u53d6{suffix}",
            (ToolInvocationPhase.Search, ToolInvocationState.Running, true) => $"\u6b63\u5728\u641c\u7d22{suffix}",
            (ToolInvocationPhase.Search, _, true) => $"\u5df2\u641c\u7d22{suffix}",
            (ToolInvocationPhase.Edit, ToolInvocationState.Running, true) => $"\u6b63\u5728\u7f16\u8f91{suffix}",
            (ToolInvocationPhase.Edit, _, true) => $"\u5df2\u7f16\u8f91{suffix}",
            (ToolInvocationPhase.Task, ToolInvocationState.Running, true) => $"\u6b63\u5728\u8fd0\u884c\u4efb\u52a1{suffix}",
            (ToolInvocationPhase.Task, _, true) => $"\u5df2\u8fd0\u884c\u4efb\u52a1{suffix}",
            (_, ToolInvocationState.Running, true) => $"\u6b63\u5728\u8fd0\u884c {toolName}",
            (_, ToolInvocationState.Completed, true) => $"\u5df2\u5b8c\u6210 {toolName}",
            (_, ToolInvocationState.Failed, true) => $"{toolName} \u5931\u8d25",
            (ToolInvocationPhase.Command, _, false) when policyBlocked => $"Skipped command in Plan mode{suffix}",
            (ToolInvocationPhase.Edit, _, false) when policyBlocked => $"Skipped edit in Plan mode{suffix}",
            (ToolInvocationPhase.Command, ToolInvocationState.Running, false) => $"Running command{suffix}",
            (ToolInvocationPhase.Command, _, false) => $"Ran command{suffix}",
            (ToolInvocationPhase.Read, ToolInvocationState.Running, false) => $"Reading{suffix}",
            (ToolInvocationPhase.Read, _, false) => $"Read{suffix}",
            (ToolInvocationPhase.Search, ToolInvocationState.Running, false) => $"Searching{suffix}",
            (ToolInvocationPhase.Search, _, false) => $"Searched{suffix}",
            (ToolInvocationPhase.Edit, ToolInvocationState.Running, false) => $"Editing{suffix}",
            (ToolInvocationPhase.Edit, _, false) => $"Edited{suffix}",
            (ToolInvocationPhase.Task, ToolInvocationState.Running, false) => $"Running task{suffix}",
            (ToolInvocationPhase.Task, _, false) => $"Ran task{suffix}",
            (_, ToolInvocationState.Running, false) => $"Running {toolName}",
            (_, ToolInvocationState.Completed, false) => $"Completed {toolName}",
            (_, ToolInvocationState.Failed, false) => $"{toolName} failed",
            _ => toolName,
        };
    }

    private static string TargetFor(string toolName, ToolInput input)
    {
        if (string.Equals(toolName, "Shell", StringComparison.OrdinalIgnoreCase)) return input.First("command", "cmd", "input");
        if (string.Equals(toolName, "Await", StringComparison.OrdinalIgnoreCase)) return input.First("task_id", "taskId");
        if (string.Equals(toolName, "Grep", StringComparison.OrdinalIgnoreCase)) return input.First("pattern", "query");
        if (string.Equals(toolName, "Glob", StringComparison.OrdinalIgnoreCase)) return input.First("pattern", "path");
        if (string.Equals(toolName, "SemanticSearch", StringComparison.OrdinalIgnoreCase)) return input.First("query", "pattern");
        if (string.Equals(toolName, "Task", StringComparison.OrdinalIgnoreCase)) return input.First("prompt", "type", "description");
        return input.First("file_path", "path", "notebook_path", "notebookPath", "name", "query", "prompt");
    }

    private static IEnumerable<string> Parts(IEnumerable<string> parts) => parts.Where(part => !string.IsNullOrWhiteSpace(part));

    private static string Compact(string? value, int limit)
    {
        var normalized = (value ?? "").Replace("\r", " ").Replace("\n", " ").Replace("\t", " ").Trim();
        if (normalized.Length <= limit) return normalized;
        return $"{normalized[..Math.Max(0, limit - 3)]}...";
    }

    private sealed class ToolInput
    {
        private readonly Dictionary<string, string> _values;

        private ToolInput(Dictionary<string, string> values)
        {
            _values = values;
        }

        public static ToolInput FromJson(string json)
        {
            var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            try
            {
                using var document = JsonDocument.Parse(json);
                if (document.RootElement.ValueKind == JsonValueKind.Object)
                {
                    foreach (var property in document.RootElement.EnumerateObject())
                    {
                        values[property.Name] = property.Value.ValueKind == JsonValueKind.String
                            ? property.Value.GetString() ?? ""
                            : property.Value.GetRawText();
                    }
                }
                else if (document.RootElement.ValueKind == JsonValueKind.String)
                {
                    values["input"] = document.RootElement.GetString() ?? "";
                }
            }
            catch
            {
                values["input"] = json;
            }

            return new ToolInput(values);
        }

        public string First(params string[] keys)
        {
            foreach (var key in keys)
            {
                if (_values.TryGetValue(key, out var value) && !string.IsNullOrWhiteSpace(value))
                {
                    return Compact(value, 180);
                }
            }

            return "";
        }
    }
}

public sealed record ToolInvocationFieldPresentation(
    string Label,
    string Value,
    bool IsPrimary = false);

public sealed record ToolInvocationDetailPresentation(
    string ToolName,
    string Title,
    string? Command,
    IReadOnlyList<ToolInvocationFieldPresentation> Fields,
    string RawInput,
    bool Parsed)
{
    public string? PrimaryValue =>
        !string.IsNullOrWhiteSpace(Command)
            ? Command
            : Fields.FirstOrDefault(item => item.IsPrimary)?.Value ?? Fields.FirstOrDefault()?.Value;

    public static ToolInvocationDetailPresentation Parse(string rawToolName, string inputJson)
    {
        var toolName = AgentToolNameCanonicalizer.Canonical(rawToolName);
        try
        {
            using var document = JsonDocument.Parse(inputJson);
            if (document.RootElement.ValueKind == JsonValueKind.Object)
            {
                var presentation = ParsedPresentation(toolName, document.RootElement, inputJson);
                if (!string.IsNullOrWhiteSpace(presentation.Command) || presentation.Fields.Count > 0)
                {
                    return presentation;
                }
            }
        }
        catch (JsonException)
        {
        }

        return new ToolInvocationDetailPresentation(
            toolName,
            toolName,
            null,
            [new ToolInvocationFieldPresentation("Raw input", inputJson, true)],
            inputJson,
            false);
    }

    public string DetailText(bool chinese, string? output, bool showRawInput = false)
    {
        var lines = new List<string>();
        if (!string.IsNullOrWhiteSpace(Command))
        {
            lines.Add("$ " + Command.Replace("\r\n", "\n").Replace('\r', '\n').Replace("\n", "\n  "));
        }
        else
        {
            foreach (var field in Fields)
            {
                lines.Add($"{field.Label}:");
                lines.Add(field.Value);
                lines.Add("");
            }

            if (lines.Count > 0 && string.IsNullOrEmpty(lines[^1]))
            {
                lines.RemoveAt(lines.Count - 1);
            }
        }

        var preview = ToolOutputPreviewLimiter.Preview(output ?? "");
        if (!string.IsNullOrWhiteSpace(preview))
        {
            if (lines.Count > 0) lines.Add("");
            lines.Add(chinese ? "\u8f93\u51fa:" : "Output:");
            lines.Add(preview);
        }

        if (showRawInput)
        {
            if (lines.Count > 0) lines.Add("");
            lines.Add(chinese ? "\u539f\u59cb\u53c2\u6570:" : "Raw input:");
            lines.Add(ToolOutputPreviewLimiter.Preview(RawInput, maxChars: 6_000, maxLines: 120));
        }

        return string.Join("\n", lines);
    }

    private static ToolInvocationDetailPresentation ParsedPresentation(string toolName, JsonElement root, string rawInput) =>
        toolName switch
        {
            "Shell" => new ToolInvocationDetailPresentation(
                toolName,
                "Shell",
                StringValue(root, "command", "input_command", "input", "cmd"),
                BuildFields(root, [
                    (["cwd"], "Cwd", true),
                    (["description"], "Description", false),
                    (["timeout"], "Timeout", false),
                ]),
                rawInput,
                true),
            "Read" => FieldPresentation(toolName, rawInput, root, [
                (["file_path", "path"], "Path", true),
                (["offset"], "Offset", false),
                (["limit"], "Limit", false),
            ]),
            "Grep" => FieldPresentation(toolName, rawInput, root, [
                (["pattern", "query"], "Pattern", true),
                (["path"], "Path", false),
                (["glob"], "Glob", false),
            ]),
            "Glob" => FieldPresentation(toolName, rawInput, root, [
                (["pattern", "glob"], "Pattern", true),
                (["path"], "Path", false),
            ]),
            "StrReplace" => FieldPresentation(toolName, rawInput, root, [
                (["file_path", "path"], "Path", true),
                (["old_string", "oldString"], "Old", false),
                (["new_string", "newString"], "New", false),
                (["replace_all"], "Replace all", false),
            ]),
            "Write" => WritePresentation(toolName, rawInput, root),
            "Task" => FieldPresentation(toolName, rawInput, root, [
                (["description"], "Description", true),
                (["prompt"], "Prompt", true),
                (["type", "subagent_type"], "Type", false),
                (["cwd"], "Cwd", false),
            ]),
            "Skill" => FieldPresentation(toolName, rawInput, root, [
                (["skill"], "Skill", true),
                (["args"], "Args", false),
            ]),
            "TodoRead" => new ToolInvocationDetailPresentation(
                toolName,
                "Todo List",
                null,
                [new ToolInvocationFieldPresentation("Action", "Read todo list", true)],
                rawInput,
                true),
            "TodoWrite" => new ToolInvocationDetailPresentation(
                toolName,
                "Todo List",
                null,
                [new ToolInvocationFieldPresentation(
                    "Summary",
                    TodoListPresentation.Parse(toolName, rawInput, null)?.Summary(chinese: false) ?? "Update todo list",
                    true)],
                rawInput,
                true),
            "WebSearch" => FieldPresentation(toolName, rawInput, root, [
                (["query", "q"], "Query", true),
            ]),
            "WebFetch" => FieldPresentation(toolName, rawInput, root, [
                (["url"], "URL", true),
                (["prompt"], "Prompt", false),
            ]),
            "SemanticSearch" => FieldPresentation(toolName, rawInput, root, [
                (["query"], "Query", true),
                (["path"], "Path", false),
            ]),
            _ => FieldPresentation(toolName, rawInput, root, [
                (["file_path", "path"], "Path", true),
                (["pattern"], "Pattern", true),
                (["query"], "Query", true),
                (["description"], "Description", true),
                (["prompt"], "Prompt", true),
                (["url"], "URL", true),
            ]),
        };

    private static ToolInvocationDetailPresentation FieldPresentation(
        string toolName,
        string rawInput,
        JsonElement root,
        IReadOnlyList<(string[] Keys, string Label, bool Primary)> specs) =>
        new(toolName, toolName, null, BuildFields(root, specs), rawInput, true);

    private static ToolInvocationDetailPresentation WritePresentation(string toolName, string rawInput, JsonElement root)
    {
        var fields = new List<ToolInvocationFieldPresentation>();
        if (StringValue(root, "file_path", "path") is { } path)
        {
            fields.Add(new ToolInvocationFieldPresentation("Path", path, true));
        }

        if (StringValue(root, "content") is { } content)
        {
            fields.Add(new ToolInvocationFieldPresentation(
                "Content",
                AgentToolInputPreview.WriteContentSummary(content, previewLimit: 520),
                fields.Count == 0));
        }

        return new ToolInvocationDetailPresentation(toolName, toolName, null, fields, rawInput, true);
    }

    private static List<ToolInvocationFieldPresentation> BuildFields(
        JsonElement root,
        IReadOnlyList<(string[] Keys, string Label, bool Primary)> specs)
    {
        var fields = new List<ToolInvocationFieldPresentation>();
        foreach (var (keys, label, primary) in specs)
        {
            var value = StringValue(root, keys);
            if (string.IsNullOrWhiteSpace(value)) continue;
            fields.Add(new ToolInvocationFieldPresentation(label, value, primary && fields.All(item => !item.IsPrimary)));
        }

        return fields;
    }

    private static string? StringValue(JsonElement root, params string[] keys)
    {
        foreach (var key in keys)
        {
            if (!root.TryGetProperty(key, out var value)) continue;
            var text = DisplayString(value)?.Trim();
            if (!string.IsNullOrWhiteSpace(text)) return text;
        }

        return null;
    }

    private static string? DisplayString(JsonElement value) =>
        value.ValueKind switch
        {
            JsonValueKind.String => value.GetString(),
            JsonValueKind.Number => value.GetRawText(),
            JsonValueKind.True => "true",
            JsonValueKind.False => "false",
            JsonValueKind.Object or JsonValueKind.Array => JsonSerializer.Serialize(value, new JsonSerializerOptions { WriteIndented = false }),
            _ => null,
        };
}

public enum TodoPresentationStatus
{
    Completed,
    InProgress,
    Pending,
}

public sealed record TodoListItemPresentation(
    string Id,
    string? ExplicitId,
    string Content,
    TodoPresentationStatus Status,
    int SourceIndex)
{
    public string StableKey
    {
        get
        {
            if (!string.IsNullOrWhiteSpace(ExplicitId)) return ExplicitId;
            var normalized = Content.Trim().ToLowerInvariant();
            return string.IsNullOrWhiteSpace(normalized) ? $"index:{SourceIndex}" : $"content:{normalized}";
        }
    }
}

public sealed record TodoListSnapshot(IReadOnlyList<TodoListItemPresentation> Items)
{
    public int CompletedCount => Items.Count(item => item.Status == TodoPresentationStatus.Completed);
    public int InProgressCount => Items.Count(item => item.Status == TodoPresentationStatus.InProgress);
    public int PendingCount => Items.Count(item => item.Status == TodoPresentationStatus.Pending);
    public int TotalCount => Items.Count;
}

public sealed record TodoListDiff(
    IReadOnlySet<string> ChangedItemKeys,
    IReadOnlySet<string> CompletedItemKeys)
{
    public static TodoListDiff Empty { get; } = new(new HashSet<string>(), new HashSet<string>());

    public static TodoListDiff Make(TodoListSnapshot? previous, TodoListSnapshot current)
    {
        if (previous is null) return Empty;
        var oldByKey = previous.Items.ToDictionary(item => item.StableKey, StringComparer.Ordinal);
        var changed = new HashSet<string>(StringComparer.Ordinal);
        var completed = new HashSet<string>(StringComparer.Ordinal);
        foreach (var item in current.Items)
        {
            oldByKey.TryGetValue(item.StableKey, out var old);
            if (old is null || old.Status != item.Status || old.Content != item.Content)
            {
                changed.Add(item.StableKey);
            }

            if (old?.Status != TodoPresentationStatus.Completed && item.Status == TodoPresentationStatus.Completed)
            {
                completed.Add(item.StableKey);
            }
        }

        return new TodoListDiff(changed, completed);
    }
}

public sealed record TodoListPresentation(
    TodoListSnapshot Snapshot,
    TodoListDiff Diff)
{
    public static TodoListPresentation? Parse(
        string toolName,
        string inputJson,
        string? resultOutput,
        TodoListSnapshot? previous = null)
    {
        var canonical = AgentToolNameCanonicalizer.Canonical(toolName);
        if (canonical is not ("TodoWrite" or "TodoRead")) return null;
        var resultSource = resultOutput?.Trim();
        var source = canonical == "TodoRead"
            ? (!string.IsNullOrWhiteSpace(resultSource) ? resultSource! : inputJson)
            : inputJson;
        var snapshot = SnapshotFrom(source);
        return snapshot is null ? null : new TodoListPresentation(snapshot, TodoListDiff.Make(previous, snapshot));
    }

    public string Summary(bool chinese) =>
        chinese
            ? $"{Snapshot.CompletedCount} \u5b8c\u6210 \u00b7 {Snapshot.InProgressCount} \u8fdb\u884c\u4e2d \u00b7 {Snapshot.PendingCount} \u5f85\u529e"
            : $"{Snapshot.CompletedCount} done \u00b7 {Snapshot.InProgressCount} in progress \u00b7 {Snapshot.PendingCount} pending";

    public string RowTitle(string toolName, bool chinese, bool running)
    {
        var canonical = AgentToolNameCanonicalizer.Canonical(toolName);
        var title = canonical == "TodoRead"
            ? running
                ? (chinese ? "\u6b63\u5728\u8bfb\u53d6 Todo List" : "Reading Todo List")
                : (chinese ? "\u5df2\u8bfb\u53d6 Todo List" : "Read Todo List")
            : running
                ? (chinese ? "\u6b63\u5728\u66f4\u65b0 Todo List" : "Updating Todo List")
                : (chinese ? "\u5df2\u66f4\u65b0 Todo List" : "Updated Todo List");
        return running ? title : $"{title} \u00b7 {Summary(chinese)}";
    }

    public string DetailTitle(bool chinese) => "Todo List";

    public string DetailText(bool chinese)
    {
        var lines = new List<string> { Summary(chinese), "" };
        foreach (var item in Snapshot.Items)
        {
            var status = item.Status switch
            {
                TodoPresentationStatus.Completed => chinese ? "\u5b8c\u6210" : "done",
                TodoPresentationStatus.InProgress => chinese ? "\u8fdb\u884c\u4e2d" : "in progress",
                _ => chinese ? "\u5f85\u529e" : "pending",
            };
            var marker = item.Status == TodoPresentationStatus.Completed ? "x" : " ";
            lines.Add($"- [{marker}] {item.Content} ({status})");
        }

        return string.Join("\n", lines);
    }

    private static TodoListSnapshot? SnapshotFrom(string source)
    {
        var trimmed = source.Trim();
        if (string.IsNullOrWhiteSpace(trimmed)) return null;
        try
        {
            using var document = JsonDocument.Parse(trimmed);
            var items = TodoItemsFrom(document.RootElement);
            if (items is { Count: > 0 }) return new TodoListSnapshot(items);
        }
        catch (JsonException)
        {
        }

        var markdownItems = TodoItemsFromMarkdown(trimmed);
        return markdownItems.Count == 0 ? null : new TodoListSnapshot(markdownItems);
    }

    private static List<TodoListItemPresentation>? TodoItemsFrom(JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.Object)
        {
            if (value.TryGetProperty("todos", out var todos))
            {
                return TodoItemsFrom(todos);
            }

            if (StringValue(value, "markdown") is { } markdown)
            {
                return TodoItemsFromMarkdown(markdown);
            }

            var item = TodoItemFrom(value, 0);
            return item is null ? null : [item];
        }

        if (value.ValueKind != JsonValueKind.Array) return null;
        var output = new List<TodoListItemPresentation>();
        var index = 0;
        foreach (var item in value.EnumerateArray())
        {
            if (item.ValueKind == JsonValueKind.Object && TodoItemFrom(item, index) is { } parsed)
            {
                output.Add(parsed);
            }

            index++;
        }

        return output;
    }

    private static TodoListItemPresentation? TodoItemFrom(JsonElement value, int fallbackIndex)
    {
        var content = StringValue(value, "content") ??
                      StringValue(value, "title") ??
                      StringValue(value, "subject") ??
                      StringValue(value, "task");
        if (string.IsNullOrWhiteSpace(content)) return null;
        var explicitId = StringValue(value, "id");
        var id = string.IsNullOrWhiteSpace(explicitId) ? $"todo-{fallbackIndex + 1}" : explicitId!;
        var rawStatus = StringValue(value, "status") ??
                        (value.TryGetProperty("done", out var done) && done.ValueKind == JsonValueKind.True ? "completed" : "pending");
        return new TodoListItemPresentation(
            id,
            string.IsNullOrWhiteSpace(explicitId) ? null : explicitId,
            content.Trim(),
            NormalizedStatus(rawStatus),
            fallbackIndex);
    }

    private static List<TodoListItemPresentation> TodoItemsFromMarkdown(string markdown)
    {
        var output = new List<TodoListItemPresentation>();
        var assignedInProgress = false;
        var lines = markdown.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n');
        for (var index = 0; index < lines.Length; index++)
        {
            var trimmed = lines[index].Trim();
            if (!trimmed.StartsWith("- [", StringComparison.Ordinal) &&
                !trimmed.StartsWith("* [", StringComparison.Ordinal))
            {
                continue;
            }

            var checkedItem = trimmed.StartsWith("- [x]", StringComparison.OrdinalIgnoreCase) ||
                              trimmed.StartsWith("* [x]", StringComparison.OrdinalIgnoreCase);
            var close = trimmed.IndexOf(']');
            if (close < 0 || close + 1 >= trimmed.Length) continue;
            var content = trimmed[(close + 1)..].Trim(' ', '-', '\t');
            if (string.IsNullOrWhiteSpace(content)) continue;
            var status = checkedItem
                ? TodoPresentationStatus.Completed
                : !assignedInProgress
                    ? TodoPresentationStatus.InProgress
                    : TodoPresentationStatus.Pending;
            if (status == TodoPresentationStatus.InProgress)
            {
                assignedInProgress = true;
            }

            output.Add(new TodoListItemPresentation($"todo-{index + 1}", null, content, status, index));
        }

        return output;
    }

    private static TodoPresentationStatus NormalizedStatus(string rawStatus)
    {
        var value = rawStatus.Trim().ToLowerInvariant().Replace('-', '_');
        return value switch
        {
            "completed" or "complete" or "done" or "finished" or "success" => TodoPresentationStatus.Completed,
            "in_progress" or "inprogress" or "progress" or "active" or "current" or "running" => TodoPresentationStatus.InProgress,
            _ => TodoPresentationStatus.Pending,
        };
    }

    private static string? StringValue(JsonElement root, string key)
    {
        if (!root.TryGetProperty(key, out var value)) return null;
        var text = value.ValueKind switch
        {
            JsonValueKind.String => value.GetString(),
            JsonValueKind.Number => value.GetRawText(),
            _ => null,
        };
        text = text?.Trim();
        return string.IsNullOrWhiteSpace(text) ? null : text;
    }
}

public sealed record TaskInvocationPresentation(
    string Type,
    string Description,
    string Prompt,
    string? Cwd,
    string? Isolation)
{
    public static TaskInvocationPresentation? Parse(string inputJson)
    {
        try
        {
            using var document = JsonDocument.Parse(inputJson);
            if (document.RootElement.ValueKind != JsonValueKind.Object) return null;
            var root = document.RootElement;
            var type = StringValue(root, "type") ??
                       StringValue(root, "subagent_type") ??
                       "Agent";
            var description = StringValue(root, "description") ??
                              StringValue(root, "task") ??
                              type;
            return new TaskInvocationPresentation(
                type,
                description,
                StringValue(root, "prompt") ?? "",
                StringValue(root, "cwd"),
                StringValue(root, "isolation"));
        }
        catch (JsonException)
        {
            return null;
        }
    }

    public string RowTitle(bool chinese, bool running, bool failed)
    {
        var baseTitle = chinese ? $"\u5b50 Agent / {Type}: {Description}" : $"Subagent / {Type}: {Description}";
        if (failed) return chinese ? $"{baseTitle} \u5931\u8d25" : $"{baseTitle} failed";
        if (running) return chinese ? $"\u6b63\u5728\u8fd0\u884c {baseTitle}" : $"Running {baseTitle}";
        return chinese ? $"\u5df2\u5b8c\u6210 {baseTitle}" : $"Completed {baseTitle}";
    }

    public string DetailTitle(bool chinese) =>
        chinese ? $"\u5b50 Agent / {Type}" : $"Subagent / {Type}";

    public string DetailText(bool chinese, string? output)
    {
        var lines = new List<string> { Description };
        if (!string.IsNullOrWhiteSpace(Prompt))
        {
            lines.Add("");
            lines.Add($"{(chinese ? "\u4efb\u52a1" : "Prompt")}:");
            lines.Add(Prompt);
        }

        if (!string.IsNullOrWhiteSpace(Cwd))
        {
            lines.Add("");
            lines.Add($"Cwd: {Cwd}");
        }

        if (!string.IsNullOrWhiteSpace(Isolation))
        {
            lines.Add($"{(chinese ? "\u9694\u79bb" : "Isolation")}: {Isolation}");
        }

        var preview = ToolOutputPreviewLimiter.Preview(output ?? "");
        if (!string.IsNullOrWhiteSpace(preview))
        {
            lines.Add("");
            lines.Add(chinese ? "\u8f93\u51fa:" : "Output:");
            lines.Add(preview);
        }

        return string.Join("\n", lines);
    }

    private static string? StringValue(JsonElement root, string key)
    {
        if (!root.TryGetProperty(key, out var value)) return null;
        var text = value.ValueKind switch
        {
            JsonValueKind.String => value.GetString(),
            JsonValueKind.Number => value.GetRawText(),
            _ => null,
        };
        text = text?.Trim();
        return string.IsNullOrWhiteSpace(text) ? null : text;
    }
}

public static class ToolOutputPreviewLimiter
{
    private const string TruncationNotice = "... output truncated for display ...";

    public static string Preview(string value, int maxChars = 2_400, int maxLines = 80)
    {
        var normalized = (value ?? "").Replace("\r\n", "\n").Replace('\r', '\n');
        var lines = normalized.Split('\n');
        var truncated = false;
        if (lines.Length > maxLines)
        {
            lines = lines.Take(maxLines).ToArray();
            truncated = true;
        }

        var output = string.Join("\n", lines);
        if (output.Length > maxChars)
        {
            output = output[..Math.Max(0, maxChars)];
            truncated = true;
        }

        return truncated ? $"{output}\n{TruncationNotice}" : output;
    }
}
