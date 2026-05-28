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

public sealed record ProcessTraceSummary(
    string Text,
    bool ShouldShimmer,
    string? RunningActivityId)
{
    public static ProcessTraceSummary Make(IEnumerable<AgentActivity> activities, bool chinese)
    {
        var visible = VisibleActivities(activities);
        var runningTool = visible.LastOrDefault(activity =>
            activity.State == AgentActivityState.Running &&
            !string.IsNullOrWhiteSpace(activity.ToolName));
        if (runningTool is not null)
        {
            return new ProcessTraceSummary(RunningText(runningTool, chinese), true, runningTool.Id);
        }

        var running = visible.LastOrDefault(activity => activity.State == AgentActivityState.Running);
        if (running is not null)
        {
            var title = running.Title.Trim();
            return new ProcessTraceSummary(
                string.IsNullOrWhiteSpace(title) ? (chinese ? "\u6b63\u5728\u5904\u7406" : "Processing") : title,
                true,
                running.Id);
        }

        return new ProcessTraceSummary(AggregateText(visible, chinese), false, null);
    }

    private static List<AgentActivity> VisibleActivities(IEnumerable<AgentActivity> activities) =>
        activities
            .Where(activity =>
                !string.IsNullOrWhiteSpace(activity.Title) ||
                !string.IsNullOrWhiteSpace(activity.Detail) ||
                activity.ToolName is not null)
            .OrderBy(activity => activity.CreatedAt)
            .ToList();

    private static string RunningText(AgentActivity activity, bool chinese)
    {
        var target = TargetFor(activity);
        var targetText = string.IsNullOrWhiteSpace(target) ? "" : $" {target}";
        var toolName = activity.ToolName ?? "";
        var canonical = AgentToolNameCanonicalizer.Canonical(toolName).ToLowerInvariant();
        var phase = AgentToolPresentationClassifier.PhaseForToolName(toolName);

        if (canonical == "askquestion") return chinese ? "\u7b49\u5f85\u4f60\u7684\u56de\u7b54" : "Waiting for your answer";
        if (canonical == "switchmode") return chinese ? "\u7b49\u5f85\u8ba1\u5212\u786e\u8ba4" : "Waiting for plan confirmation";
        if (canonical == "read") return chinese ? $"\u6b63\u5728\u8bfb\u53d6{targetText}" : $"Reading{targetText}";
        if (canonical == "write") return chinese ? $"\u6b63\u5728\u5199\u5165{targetText}" : $"Writing{targetText}";
        if (canonical is "strreplace" or "editnotebook") return chinese ? $"\u6b63\u5728\u7f16\u8f91{targetText}" : $"Editing{targetText}";
        if (canonical == "delete") return chinese ? $"\u6b63\u5728\u5220\u9664{targetText}" : $"Deleting{targetText}";
        if (canonical == "todowrite") return chinese ? "\u6b63\u5728\u66f4\u65b0 Todo List" : "Updating Todo List";
        if (canonical == "todoread") return chinese ? "\u6b63\u5728\u8bfb\u53d6 Todo List" : "Reading Todo List";

        return phase switch
        {
            AgentActivityPhase.Search => chinese ? $"\u6b63\u5728\u641c\u7d22{targetText}" : $"Searching{targetText}",
            AgentActivityPhase.Command => chinese ? $"\u6b63\u5728\u6267\u884c{targetText}" : $"Running{targetText}",
            AgentActivityPhase.Edit => chinese ? $"\u6b63\u5728\u7f16\u8f91{targetText}" : $"Editing{targetText}",
            AgentActivityPhase.Todo => chinese ? "\u6b63\u5728\u66f4\u65b0 Todo List" : "Updating Todo List",
            AgentActivityPhase.Subagent => chinese ? $"\u6b63\u5728\u8fd0\u884c\u4efb\u52a1{targetText}" : $"Running task{targetText}",
            AgentActivityPhase.Thinking => chinese ? "\u6b63\u5728\u601d\u8003" : "Thinking",
            AgentActivityPhase.Status => StatusText(activity.Title, chinese),
            _ => FallbackText(activity.Title, chinese),
        };
    }

    private static string StatusText(string title, bool chinese)
    {
        var fallback = title.Trim();
        var lower = fallback.ToLowerInvariant();
        if (lower.Contains("connecting", StringComparison.Ordinal)) return chinese ? "\u6b63\u5728\u8fde\u63a5\u6a21\u578b" : "Connecting to model";
        if (lower.Contains("continuing", StringComparison.Ordinal) || fallback.Contains("\u7ee7\u7eed", StringComparison.Ordinal)) return chinese ? "\u6b63\u5728\u7ee7\u7eed\u5904\u7406" : "Continuing";
        return string.IsNullOrWhiteSpace(fallback) ? (chinese ? "\u6b63\u5728\u601d\u8003" : "Thinking") : fallback;
    }

    private static string FallbackText(string title, bool chinese)
    {
        var fallback = title.Trim();
        return string.IsNullOrWhiteSpace(fallback) ? (chinese ? "\u6b63\u5728\u5904\u7406" : "Processing") : fallback;
    }

    private static string AggregateText(IReadOnlyList<AgentActivity> activities, bool chinese)
    {
        var reads = UniqueTargetCount(activities, activity =>
            activity.ToolName is not null && AgentToolPresentationClassifier.IsReadTool(activity.ToolName));
        var edits = UniqueTargetCount(activities, activity =>
            AgentToolPresentationClassifier.PhaseForToolName(activity.ToolName ?? "") == AgentActivityPhase.Edit);
        var searches = activities.Count(activity =>
            AgentToolPresentationClassifier.PhaseForToolName(activity.ToolName ?? "") == AgentActivityPhase.Search);
        var commands = activities.Count(activity =>
            AgentToolPresentationClassifier.PhaseForToolName(activity.ToolName ?? "") == AgentActivityPhase.Command);
        var todos = activities.Count(activity =>
            AgentToolPresentationClassifier.PhaseForToolName(activity.ToolName ?? "") == AgentActivityPhase.Todo);
        var questions = QuestionCount(activities);
        var otherTools = activities.Count(activity => activity.ToolName is not null);

        var parts = new List<string>();
        if (chinese)
        {
            if (questions > 0) parts.Add($"\u5df2\u8be2\u95ee {questions} \u4e2a\u95ee\u9898");
            if (todos > 0) parts.Add("\u5df2\u66f4\u65b0 Todo List");
            if (reads > 0) parts.Add($"\u5df2\u63a2\u7d22 {reads} \u4e2a\u6587\u4ef6");
            if (searches > 0) parts.Add($"{searches} \u6b21\u641c\u7d22");
            if (edits > 0) parts.Add($"\u5df2\u7f16\u8f91 {edits} \u4e2a\u6587\u4ef6");
            if (commands > 0) parts.Add($"\u5df2\u8fd0\u884c {commands} \u6761\u547d\u4ee4");
            if (parts.Count == 0 && otherTools > 0) parts.Add($"\u5df2\u4f7f\u7528 {otherTools} \u4e2a\u5de5\u5177");
            return parts.Count == 0 ? "\u6b63\u5728\u5904\u7406" : string.Join(" ", parts);
        }

        if (questions > 0) parts.Add($"asked {questions} {(questions == 1 ? "question" : "questions")}");
        if (todos > 0) parts.Add("updated Todo List");
        if (reads > 0) parts.Add($"explored {reads} {(reads == 1 ? "file" : "files")}");
        if (searches > 0) parts.Add($"{searches} {(searches == 1 ? "search" : "searches")}");
        if (edits > 0) parts.Add($"edited {edits} {(edits == 1 ? "file" : "files")}");
        if (commands > 0) parts.Add($"ran {commands} {(commands == 1 ? "command" : "commands")}");
        if (parts.Count == 0 && otherTools > 0) parts.Add($"used {otherTools} {(otherTools == 1 ? "tool" : "tools")}");
        return parts.Count == 0 ? "Processing" : string.Join(", ", parts);
    }

    private static int QuestionCount(IEnumerable<AgentActivity> activities) =>
        activities.Sum(activity =>
            AgentToolNameCanonicalizer.Canonical(activity.ToolName ?? "") == "AskQuestion" &&
            !activity.Id.StartsWith("permission-", StringComparison.Ordinal) &&
            activity.State == AgentActivityState.Completed
                ? QuestionCount(activity.DetailMessages) ?? 1
                : 0);

    private static int? QuestionCount(IEnumerable<string>? values)
    {
        if (values is null) return null;
        const string prefix = "questions_count=";
        foreach (var value in values)
        {
            if (value.StartsWith(prefix, StringComparison.Ordinal) &&
                int.TryParse(value[prefix.Length..], out var count))
            {
                return count;
            }
        }

        return null;
    }

    private static int UniqueTargetCount(IEnumerable<AgentActivity> activities, Func<AgentActivity, bool> predicate) =>
        activities
            .Where(predicate)
            .Select(activity => TargetFor(activity) ?? activity.Id)
            .ToHashSet(StringComparer.Ordinal)
            .Count;

    private static string? TargetFor(AgentActivity activity)
    {
        if (string.IsNullOrWhiteSpace(activity.ToolName)) return null;
        var sources = new[] { activity.Detail }.Concat(activity.DetailMessages ?? []);
        foreach (var source in sources)
        {
            var target = ToolInvocationPresenter.Target(activity.ToolName, source, 64);
            if (!string.IsNullOrWhiteSpace(target)) return target;

            var compact = Compact(source, 64);
            if (!string.IsNullOrWhiteSpace(compact) &&
                !compact.StartsWith("{", StringComparison.Ordinal))
            {
                return compact;
            }
        }

        return null;
    }

    private static string Compact(string? value, int limit)
    {
        var normalized = (value ?? "").Replace("\r", " ").Replace("\n", " ").Replace("\t", " ").Trim();
        if (normalized.Length <= limit) return normalized;
        return $"{normalized[..Math.Max(0, limit - 1)]}\u2026";
    }
}

public sealed record ComposerRunningStatusPresentation(
    bool ShouldRender,
    string SummaryText,
    bool ShouldShimmer,
    string DetailText,
    string? ActivityId)
{
    public static ComposerRunningStatusPresentation Make(IEnumerable<AgentActivity> activities, bool chinese)
    {
        var running = activities
            .Where(activity => activity.State == AgentActivityState.Running)
            .OrderBy(activity => activity.UpdatedAt)
            .LastOrDefault();
        if (running is null)
        {
            return new ComposerRunningStatusPresentation(false, "", false, "", null);
        }

        var summary = ProcessTraceSummary.Make([running], chinese);
        var detail = running.ToolName is null ? running.Detail.Trim() : "";
        return new ComposerRunningStatusPresentation(
            true,
            summary.Text,
            summary.ShouldShimmer || running.State == AgentActivityState.Running,
            detail,
            running.Id);
    }
}

public sealed record CodexTraceDetailRow(
    string Title,
    string Detail,
    bool IsRunning);

public sealed record ProcessTracePresentation(
    bool ShouldRender,
    string SummaryText,
    bool ShouldShimmer,
    string IconName,
    IReadOnlyList<CodexTraceDetailRow> DetailRows,
    bool Compacting)
{
    public bool CanExpand => DetailRows.Count > 0;

    public static ProcessTracePresentation Make(IEnumerable<AgentActivity> activities, bool chinese)
    {
        var visible = activities
            .Where(activity =>
                !string.IsNullOrWhiteSpace(activity.Title) ||
                !string.IsNullOrWhiteSpace(activity.Detail) ||
                activity.ToolName is not null)
            .OrderBy(activity => activity.CreatedAt)
            .ToList();
        var summary = ProcessTraceSummary.Make(visible, chinese);
        var current = visible.LastOrDefault(activity => activity.State == AgentActivityState.Running);
        var compacting = visible.Any(activity =>
        {
            var haystack = $"{activity.Title} {activity.Detail} {activity.ToolName ?? ""}".ToLowerInvariant();
            return haystack.Contains("compact", StringComparison.Ordinal) ||
                   haystack.Contains("\u538b\u7f29", StringComparison.Ordinal);
        });

        return new ProcessTracePresentation(
            current is not null || compacting,
            summary.Text,
            summary.ShouldShimmer,
            IconNameFor(current, visible),
            current is null ? [] : CurrentDetailRows(current, chinese),
            compacting);
    }

    private static IReadOnlyList<CodexTraceDetailRow> CurrentDetailRows(AgentActivity activity, bool chinese)
    {
        if (activity.State != AgentActivityState.Running) return [];
        if (IsInteractiveControlActivity(activity)) return [];
        var phase = PresentationPhase(activity);
        if (phase == AgentActivityPhase.Todo) return [];

        var title = DetailTitle(activity, chinese);
        var detail = CompactDetail(activity);
        if (string.IsNullOrWhiteSpace(title)) return [];
        return [new CodexTraceDetailRow(title, detail, true)];
    }

    private static string IconNameFor(AgentActivity? current, IReadOnlyList<AgentActivity> fallbackActivities)
    {
        if (current is not null)
        {
            return PresentationPhase(current) switch
            {
                AgentActivityPhase.Status or AgentActivityPhase.Thinking => "Sparkles",
                AgentActivityPhase.Tool => "Hammer",
                AgentActivityPhase.Todo => "ListChecks",
                AgentActivityPhase.Command => "Terminal",
                AgentActivityPhase.Search => "Search",
                AgentActivityPhase.Edit => "Edit",
                AgentActivityPhase.Subagent => "Bot",
                _ => "Terminal",
            };
        }

        if (fallbackActivities.Any(activity => activity.State == AgentActivityState.Failed)) return "AlertCircle";
        if (fallbackActivities.Any(activity => PresentationPhase(activity) == AgentActivityPhase.Todo)) return "ListChecks";
        if (fallbackActivities.Any(activity => PresentationPhase(activity) == AgentActivityPhase.Command)) return "Terminal";
        if (fallbackActivities.Any(activity => PresentationPhase(activity) == AgentActivityPhase.Search)) return "Search";
        if (fallbackActivities.Any(activity => PresentationPhase(activity) == AgentActivityPhase.Edit)) return "Edit";
        return "Terminal";
    }

    private static string DetailTitle(AgentActivity activity, bool chinese)
    {
        var target = Target(activity);
        var toolName = activity.ToolName ?? "";
        var phase = PresentationPhase(activity);
        if (phase == AgentActivityPhase.Search)
        {
            if (IsRootWorkspaceGlob(activity)) return chinese ? "\u6b63\u5728\u63a2\u7d22\u5de5\u4f5c\u533a" : "Exploring workspace";
            return target is null
                ? (chinese ? "\u6b63\u5728\u641c\u7d22" : "Searching")
                : (chinese ? $"\u6b63\u5728\u641c\u7d22 {target}" : $"Searching {target}");
        }

        if (AgentToolPresentationClassifier.IsReadTool(toolName))
        {
            return target is null
                ? (chinese ? "\u6b63\u5728\u8bfb\u53d6\u6587\u4ef6" : "Reading file")
                : (chinese ? $"\u6b63\u5728\u8bfb\u53d6 {target}" : $"Reading {target}");
        }

        if (phase == AgentActivityPhase.Edit)
        {
            return target is null
                ? (chinese ? "\u6b63\u5728\u7f16\u8f91\u6587\u4ef6" : "Editing file")
                : (chinese ? $"\u6b63\u5728\u7f16\u8f91 {target}" : $"Editing {target}");
        }

        if (phase == AgentActivityPhase.Command)
        {
            return target is null
                ? (chinese ? "\u6b63\u5728\u6267\u884c\u547d\u4ee4" : "Running command")
                : (chinese ? $"\u6b63\u5728\u6267\u884c\u547d\u4ee4 {target}" : $"Running {target}");
        }

        if (phase == AgentActivityPhase.Subagent)
        {
            return target is null
                ? (chinese ? "\u6b63\u5728\u8fd0\u884c\u4efb\u52a1" : "Running task")
                : (chinese ? $"\u6b63\u5728\u8fd0\u884c\u4efb\u52a1 {target}" : $"Running task {target}");
        }

        var fallback = activity.Title.Trim();
        return string.IsNullOrWhiteSpace(fallback) ? (chinese ? "\u6b63\u5728\u5904\u7406" : "Processing") : fallback;
    }

    private static string CompactDetail(AgentActivity activity)
    {
        var candidates = new[] { activity.Detail }.Concat(activity.DetailMessages ?? []);
        foreach (var value in candidates)
        {
            var trimmed = value.Trim();
            if (string.IsNullOrWhiteSpace(trimmed)) continue;
            if (trimmed.StartsWith("{", StringComparison.Ordinal) && trimmed.EndsWith("}", StringComparison.Ordinal))
            {
                if (Target(activity) is { } target) return target;
                continue;
            }

            if (IsLowValueStatus(trimmed)) continue;
            return CompactPreview(trimmed, 130);
        }

        return "";
    }

    private static string? Target(AgentActivity activity)
    {
        if (string.IsNullOrWhiteSpace(activity.ToolName)) return null;
        foreach (var source in new[] { activity.Detail }.Concat(activity.DetailMessages ?? []))
        {
            var target = ToolInvocationPresenter.Target(activity.ToolName, source, 72);
            if (!string.IsNullOrWhiteSpace(target)) return target;
        }

        return null;
    }

    private static AgentActivityPhase PresentationPhase(AgentActivity activity) =>
        string.IsNullOrWhiteSpace(activity.ToolName)
            ? activity.Phase
            : AgentToolPresentationClassifier.PhaseForToolName(activity.ToolName);

    private static bool IsInteractiveControlActivity(AgentActivity activity)
    {
        if (activity.ToolName is null) return false;
        var canonical = AgentToolNameCanonicalizer.Canonical(activity.ToolName);
        return canonical == "AskQuestion" || canonical == "SwitchMode";
    }

    private static bool IsRootWorkspaceGlob(AgentActivity activity)
    {
        if (AgentToolNameCanonicalizer.Canonical(activity.ToolName ?? "") != "Glob") return false;
        return new[] { activity.Detail }
            .Concat(activity.DetailMessages ?? [])
            .Any(source => AgentRootGlobExecutionPolicy.IsRootWorkspaceGlob(new AgentToolCall(activity.Id, "Glob", source)));
    }

    private static bool IsLowValueStatus(string value)
    {
        var haystack = value.ToLowerInvariant();
        var markers = new[]
        {
            "connecting",
            "streaming",
            "processing",
            "thinking",
            "agent state",
            "\u6b63\u5728\u8fde\u63a5",
            "\u6b63\u5728\u63a5\u6536\u54cd\u5e94",
            "\u5904\u7406\u4e2d",
            "\u6b63\u5728\u601d\u8003",
        };
        return markers.Any(marker => haystack.Contains(marker, StringComparison.Ordinal));
    }

    private static string CompactPreview(string value, int limit)
    {
        var compact = value.Replace("\r", " ").Replace("\n", " ").Replace("\t", " ").Trim();
        if (compact.Length <= limit) return compact;
        return $"{compact[..Math.Max(0, limit - 1)]}\u2026";
    }
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
