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
        var summary = Summary(toolName, phase, state, target, chinese);
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

        var failed = items.FirstOrDefault(item => item.Result?.IsError == true);
        if (failed.Call is not null)
        {
            return Present(failed.Call, failed.Result, chinese);
        }

        var reads = items.Count(item => PhaseFor(AgentToolNameCanonicalizer.Canonical(item.Call.Name)) == ToolInvocationPhase.Read);
        var edits = items.Count(item => PhaseFor(AgentToolNameCanonicalizer.Canonical(item.Call.Name)) == ToolInvocationPhase.Edit);
        var searches = items.Count(item => PhaseFor(AgentToolNameCanonicalizer.Canonical(item.Call.Name)) == ToolInvocationPhase.Search);
        var commands = items.Count(item => PhaseFor(AgentToolNameCanonicalizer.Canonical(item.Call.Name)) == ToolInvocationPhase.Command);
        var other = Math.Max(0, items.Count - reads - edits - searches - commands);
        var summary = chinese
            ? string.Join("\u3001", Parts([
                reads > 0 ? $"\u5df2\u8bfb\u53d6 {reads} \u4e2a\u6587\u4ef6" : "",
                edits > 0 ? $"\u5df2\u7f16\u8f91 {edits} \u4e2a\u6587\u4ef6" : "",
                searches > 0 ? $"\u5df2\u641c\u7d22 {searches} \u6b21" : "",
                commands > 0 ? $"\u5df2\u8fd0\u884c {commands} \u6761\u547d\u4ee4" : "",
                other > 0 ? $"\u5df2\u4f7f\u7528 {other} \u4e2a\u5de5\u5177" : "",
            ]))
            : string.Join(", ", Parts([
                reads > 0 ? $"read {reads} files" : "",
                edits > 0 ? $"edited {edits} files" : "",
                searches > 0 ? $"searched {searches} times" : "",
                commands > 0 ? $"ran {commands} commands" : "",
                other > 0 ? $"used {other} tools" : "",
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
               string.Equals(canonical, "Task", StringComparison.OrdinalIgnoreCase) ||
               string.Equals(canonical, "AskQuestion", StringComparison.OrdinalIgnoreCase) ||
               string.Equals(canonical, "SwitchMode", StringComparison.OrdinalIgnoreCase);
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

    private static string Summary(string toolName, ToolInvocationPhase phase, ToolInvocationState state, string target, bool chinese)
    {
        var value = string.IsNullOrWhiteSpace(target) ? toolName : target;
        return (phase, state, chinese) switch
        {
            (ToolInvocationPhase.Command, ToolInvocationState.Running, true) => $"\u6b63\u5728\u8fd0\u884c: {value}",
            (ToolInvocationPhase.Command, ToolInvocationState.Completed, true) => $"\u5df2\u8fd0\u884c: {value}",
            (ToolInvocationPhase.Command, ToolInvocationState.Failed, true) => $"\u8fd0\u884c\u5931\u8d25: {value}",
            (ToolInvocationPhase.Read, ToolInvocationState.Running, true) => $"\u6b63\u5728\u8bfb\u53d6: {value}",
            (ToolInvocationPhase.Read, ToolInvocationState.Completed, true) => $"\u5df2\u8bfb\u53d6: {value}",
            (ToolInvocationPhase.Read, ToolInvocationState.Failed, true) => $"\u8bfb\u53d6\u5931\u8d25: {value}",
            (ToolInvocationPhase.Search, ToolInvocationState.Running, true) => $"\u6b63\u5728\u641c\u7d22: {value}",
            (ToolInvocationPhase.Search, ToolInvocationState.Completed, true) => $"\u5df2\u641c\u7d22: {value}",
            (ToolInvocationPhase.Search, ToolInvocationState.Failed, true) => $"\u641c\u7d22\u5931\u8d25: {value}",
            (ToolInvocationPhase.Edit, ToolInvocationState.Running, true) => $"\u6b63\u5728\u7f16\u8f91: {value}",
            (ToolInvocationPhase.Edit, ToolInvocationState.Completed, true) => $"\u5df2\u7f16\u8f91: {value}",
            (ToolInvocationPhase.Edit, ToolInvocationState.Failed, true) => $"\u7f16\u8f91\u5931\u8d25: {value}",
            (ToolInvocationPhase.Todo, ToolInvocationState.Running, true) => "\u6b63\u5728\u66f4\u65b0 Todo List",
            (ToolInvocationPhase.Todo, ToolInvocationState.Completed, true) => "\u5df2\u66f4\u65b0 Todo List",
            (ToolInvocationPhase.Task, ToolInvocationState.Running, true) => $"\u6b63\u5728\u6267\u884c\u4efb\u52a1: {value}",
            (ToolInvocationPhase.Task, ToolInvocationState.Completed, true) => $"\u5df2\u6267\u884c\u4efb\u52a1: {value}",
            (_, ToolInvocationState.Running, true) => $"\u6b63\u5728\u4f7f\u7528: {toolName}",
            (_, ToolInvocationState.Completed, true) => $"\u5df2\u4f7f\u7528: {toolName}",
            (_, ToolInvocationState.Failed, true) => $"{toolName} \u5931\u8d25",
            (ToolInvocationPhase.Command, ToolInvocationState.Running, false) => $"Running: {value}",
            (ToolInvocationPhase.Command, ToolInvocationState.Completed, false) => $"Ran: {value}",
            (ToolInvocationPhase.Command, ToolInvocationState.Failed, false) => $"Command failed: {value}",
            (ToolInvocationPhase.Read, ToolInvocationState.Running, false) => $"Reading: {value}",
            (ToolInvocationPhase.Read, ToolInvocationState.Completed, false) => $"Read: {value}",
            (ToolInvocationPhase.Read, ToolInvocationState.Failed, false) => $"Read failed: {value}",
            (ToolInvocationPhase.Search, ToolInvocationState.Running, false) => $"Searching: {value}",
            (ToolInvocationPhase.Search, ToolInvocationState.Completed, false) => $"Searched: {value}",
            (ToolInvocationPhase.Search, ToolInvocationState.Failed, false) => $"Search failed: {value}",
            (ToolInvocationPhase.Edit, ToolInvocationState.Running, false) => $"Editing: {value}",
            (ToolInvocationPhase.Edit, ToolInvocationState.Completed, false) => $"Edited: {value}",
            (ToolInvocationPhase.Edit, ToolInvocationState.Failed, false) => $"Edit failed: {value}",
            (_, ToolInvocationState.Running, false) => $"Using: {toolName}",
            (_, ToolInvocationState.Completed, false) => $"Used: {toolName}",
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
