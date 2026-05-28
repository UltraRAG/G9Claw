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
        var canonical = AgentToolNameCanonicalizer.Canonical(toolName);
        var target = TargetFor(canonical, ToolInput.FromJson(inputJson));
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
        return new ToolInvocationPresentation(
            phase,
            state,
            summary,
            Compact(string.IsNullOrWhiteSpace(target) ? call.InputJson : target, 240),
            result is null ? null : Compact(result.Output, 360),
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
            Compact(items.LastOrDefault(item => item.Result is not null).Result?.Output ?? "", 360),
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
