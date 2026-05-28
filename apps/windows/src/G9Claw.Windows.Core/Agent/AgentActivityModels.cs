using System.Text.Json;

namespace G9Claw.Windows.Core;

public sealed record AgentActivity(
    string Id,
    string SessionId,
    string? RunId,
    string Title,
    string Detail,
    AgentActivityPhase Phase,
    AgentActivityState State,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt,
    string? ToolName = null,
    List<string>? DetailMessages = null,
    bool ExpandedDefault = false,
    string? AnchorBlockId = null,
    int? Sequence = null,
    DateTimeOffset? EndedAt = null,
    Dictionary<string, int>? SummaryMetrics = null)
{
    public bool IsMeaningfulProcessTrace
    {
        get
        {
            if (ToolName is not null) return true;
            if (Phase != AgentActivityPhase.Status) return true;
            if (State is AgentActivityState.Failed or AgentActivityState.Cancelled) return true;
            var haystack = $"{Title} {Detail}".ToLowerInvariant();
            return haystack.Contains("compact", StringComparison.Ordinal) ||
                   haystack.Contains("\u538b\u7f29", StringComparison.Ordinal) ||
                   haystack.Contains("permission", StringComparison.Ordinal) ||
                   haystack.Contains("\u6743\u9650", StringComparison.Ordinal);
        }
    }

    public bool ShouldRenderInProcessTrace =>
        IsMeaningfulProcessTrace || (State == AgentActivityState.Running && Phase == AgentActivityPhase.Status);

    public static IReadOnlyList<AgentActivity> ProcessTraceActivities(IEnumerable<AgentActivity> activities) =>
        activities
            .Where(activity => activity.ShouldRenderInProcessTrace)
            .Where(activity =>
                !string.IsNullOrWhiteSpace(activity.Title) ||
                !string.IsNullOrWhiteSpace(activity.Detail) ||
                activity.ToolName is not null)
            .OrderBy(activity => activity.CreatedAt)
            .ToList();

    public static IReadOnlyList<AgentActivity> ProcessTraceActivities(
        IEnumerable<AgentActivity> activities,
        string? anchoredTo)
    {
        if (anchoredTo is null) return ProcessTraceActivities(activities);
        return ProcessTraceActivities(activities.Where(activity => activity.AnchorBlockId == anchoredTo));
    }

    public static IReadOnlyList<AgentActivity> RunHeaderActivities(
        IEnumerable<AgentActivity> activities,
        string? anchoredTo)
    {
        var scoped = anchoredTo is null
            ? activities
            : activities.Where(activity => activity.AnchorBlockId == anchoredTo);
        return scoped
            .Where(activity =>
                !string.IsNullOrWhiteSpace(activity.Title) ||
                !string.IsNullOrWhiteSpace(activity.Detail) ||
                activity.ToolName is not null)
            .OrderBy(activity => activity.CreatedAt)
            .ToList();
    }

    public static bool HasRenderableProcessTrace(IEnumerable<AgentActivity> activities) =>
        ProcessTraceActivities(activities).Count > 0;
}

public enum AgentActivityPhase
{
    Status,
    Tool,
    Search,
    Command,
    Edit,
    Todo,
    Subagent,
    Thinking,
}

public enum AgentActivityState
{
    Running,
    Completed,
    Failed,
    Cancelled,
}

public static class AgentActivityPresentationPolicy
{
    public static bool ExpandsPermissionByDefault(PermissionRequestKind kind) => false;
}

public static class AgentToolPresentationClassifier
{
    public static AgentActivityPhase PhaseForToolName(string toolName)
    {
        var canonical = AgentToolNameCanonicalizer.Canonical(toolName).ToLowerInvariant();
        if (SearchTools.Contains(canonical)) return AgentActivityPhase.Search;
        if (CommandTools.Contains(canonical)) return AgentActivityPhase.Command;
        if (EditTools.Contains(canonical)) return AgentActivityPhase.Edit;
        if (TodoTools.Contains(canonical)) return AgentActivityPhase.Todo;
        if (SubagentTools.Contains(canonical)) return AgentActivityPhase.Subagent;
        return AgentActivityPhase.Tool;
    }

    public static bool IsReadTool(string toolName) =>
        string.Equals(AgentToolNameCanonicalizer.Canonical(toolName), "Read", StringComparison.OrdinalIgnoreCase);

    public static bool IsSearchTool(string toolName) =>
        PhaseForToolName(toolName) == AgentActivityPhase.Search;

    private static readonly HashSet<string> SearchTools = new(StringComparer.OrdinalIgnoreCase)
    {
        "grep",
        "glob",
        "semanticsearch",
        "websearch",
        "webfetch",
    };

    private static readonly HashSet<string> CommandTools = new(StringComparer.OrdinalIgnoreCase)
    {
        "shell",
    };

    private static readonly HashSet<string> EditTools = new(StringComparer.OrdinalIgnoreCase)
    {
        "write",
        "strreplace",
        "delete",
        "editnotebook",
    };

    private static readonly HashSet<string> TodoTools = new(StringComparer.OrdinalIgnoreCase)
    {
        "todoread",
        "todowrite",
    };

    private static readonly HashSet<string> SubagentTools = new(StringComparer.OrdinalIgnoreCase)
    {
        "task",
    };
}

public sealed record ToolCall(
    string Id,
    string Name,
    string InputJson,
    ToolCallStatus Status);

public enum ToolCallStatus
{
    Pending,
    Running,
    Approved,
    Denied,
    Completed,
    Failed,
}

public sealed record ToolResult(
    string ToolCallId,
    string Output,
    bool IsError);

public static class AgentToolInputPreview
{
    public static string ActivityDetail(string toolName, string inputJson)
    {
        if (!string.Equals(AgentToolNameCanonicalizer.Canonical(toolName), "Write", StringComparison.Ordinal))
        {
            return inputJson;
        }

        var values = JsonValues(inputJson);
        if (values is null || !values.TryGetValue("content", out var content))
        {
            return inputJson;
        }

        var preview = new SortedDictionary<string, object?>
        {
            ["content_summary"] = WriteContentSummary(content),
        };
        if (values.TryGetValue("file_path", out var filePath))
        {
            preview["file_path"] = filePath;
        }
        else if (values.TryGetValue("path", out var path))
        {
            preview["file_path"] = path;
        }

        return JsonSerializer.Serialize(preview);
    }

    public static string WriteContentSummary(string content, int previewLimit = 360)
    {
        var lineCount = content.Count(ch => ch == '\n') + 1;
        var summary = $"{lineCount} line{(lineCount == 1 ? "" : "s")}, {System.Text.Encoding.UTF8.GetByteCount(content)} bytes";
        var compact = content.Replace('\t', ' ').Trim();
        if (!string.IsNullOrWhiteSpace(compact))
        {
            summary += $" - {Truncated(compact, previewLimit).Replace("\r", " ").Replace("\n", " ")}";
        }

        return summary;
    }

    private static Dictionary<string, string>? JsonValues(string inputJson)
    {
        try
        {
            using var document = JsonDocument.Parse(inputJson);
            if (document.RootElement.ValueKind != JsonValueKind.Object) return null;
            return document.RootElement.EnumerateObject()
                .ToDictionary(
                    property => property.Name,
                    property => property.Value.ValueKind == JsonValueKind.String
                        ? property.Value.GetString() ?? ""
                        : property.Value.GetRawText(),
                    StringComparer.OrdinalIgnoreCase);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static string Truncated(string value, int limit)
    {
        if (value.Length <= limit) return value;
        return $"{value[..Math.Max(0, limit - 1)]}\u2026";
    }
}
