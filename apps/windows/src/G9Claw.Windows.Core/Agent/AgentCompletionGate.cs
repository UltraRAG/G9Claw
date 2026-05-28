using System.Text.Json;

namespace G9Claw.Windows.Core;

public enum AgentCompletionDecisionKind
{
    Complete,
    ContinueWithNudge,
    PauseNeedsUser,
    RealError,
}

public sealed record AgentCompletionDecision(
    AgentCompletionDecisionKind Kind,
    string Message = "")
{
    public static AgentCompletionDecision Complete { get; } = new(AgentCompletionDecisionKind.Complete);
}

public sealed class AgentCompletionGate
{
    private const int MaxNudges = 5;
    private int _continuationNudgeCount;
    private int _mutatingToolCount;
    private int _verificationAfterMutationCount;
    private bool _lastToolResultWasError;
    private bool _hasIncompleteTodos;

    public AgentCompletionDecision Decision(AgentRequest request, string assistantContent)
    {
        if (_lastToolResultWasError)
        {
            return new AgentCompletionDecision(
                AgentCompletionDecisionKind.RealError,
                "The last tool call failed and the agent could not recover automatically.");
        }

        if (request.RunMode == ChatRunMode.Plan)
        {
            return AgentCompletionDecision.Complete;
        }

        if (!IsWorkspaceMutationRequest(PrimaryUserPrompt(request.Prompt)))
        {
            return AgentCompletionDecision.Complete;
        }

        if (_mutatingToolCount == 0)
        {
            return ContinueOrPause("""
            Continue the workspace task. You have not completed the requested change yet.
            Use the available tools for the next concrete step. Inspect files if needed, then edit or write files before giving a final summary.
            Do not stop after describing the plan or after a single search result.
            """);
        }

        if (RequiresPostMutationVerification(request.Prompt) && _verificationAfterMutationCount == 0)
        {
            return ContinueOrPause("""
            Continue the workspace task. You have changed files, but have not verified or read back the result yet.
            Run a focused read/search/check command, then continue with any remaining edits before giving the final summary.
            """);
        }

        if (_hasIncompleteTodos)
        {
            return ContinueOrPause("""
            Continue the workspace task. The todo list still has unfinished items.
            Complete the current todo item, update TodoWrite when progress changes, and do not give the final summary until every required todo is completed or explicitly canceled.
            """);
        }

        if (LooksLikeOngoingWorkspaceWork(assistantContent))
        {
            return ContinueOrPause("""
            Continue the implementation. You have started changing the workspace, but the last assistant message still describes in-progress work.
            Keep using concrete file/search/shell tools until the requested task is actually complete, then give a concise final summary.
            """);
        }

        return AgentCompletionDecision.Complete;
    }

    public void RecordToolResult(AgentToolCall call, AgentToolResult result)
    {
        if (result.IsPolicyBlock)
        {
            return;
        }

        _lastToolResultWasError = result.IsError;
        if (result.IsError)
        {
            return;
        }

        _continuationNudgeCount = 0;
        if (AgentToolNameCanonicalizer.Canonical(call.Name) == "TodoWrite")
        {
            _hasIncompleteTodos = HasIncompleteTodos(call.InputJson);
        }

        if (AgentToolBehaviorClassifier.IsWorkspaceMutatingTool(call))
        {
            _mutatingToolCount++;
        }
        else if (_mutatingToolCount > 0 && IsVerificationTool(call))
        {
            _verificationAfterMutationCount++;
        }
    }

    private AgentCompletionDecision ContinueOrPause(string nudge)
    {
        if (_continuationNudgeCount >= MaxNudges)
        {
            return new AgentCompletionDecision(
                AgentCompletionDecisionKind.PauseNeedsUser,
                "The task appears to still be in progress, but automatic continuation paused to avoid an unproductive loop. You can type continue or add more specific instructions to resume.");
        }

        _continuationNudgeCount++;
        return new AgentCompletionDecision(AgentCompletionDecisionKind.ContinueWithNudge, nudge);
    }

    private static bool IsVerificationTool(AgentToolCall call) =>
        AgentToolNameCanonicalizer.Canonical(call.Name) is "Read" or "Glob" or "Grep" or "SemanticSearch" or "ReadLints" or "TodoRead" or "Skill" or "Await" ||
        (AgentToolNameCanonicalizer.Canonical(call.Name) == "Shell" && AgentToolBehaviorClassifier.IsReadOnlyShell(call.InputJson)) ||
        (AgentToolNameCanonicalizer.Canonical(call.Name) == "Task" && AgentToolBehaviorClassifier.IsReadOnlyTask(call.InputJson));

    private static bool HasIncompleteTodos(string inputJson)
    {
        try
        {
            using var doc = JsonDocument.Parse(string.IsNullOrWhiteSpace(inputJson) ? "{}" : inputJson);
            return ContainsIncompleteTodo(doc.RootElement);
        }
        catch (JsonException)
        {
            return false;
        }
    }

    private static bool ContainsIncompleteTodo(JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.Object)
        {
            if (value.TryGetProperty("todos", out var todos))
            {
                return ContainsIncompleteTodo(todos);
            }

            if (value.TryGetProperty("content", out _) ||
                value.TryGetProperty("title", out _) ||
                value.TryGetProperty("task", out _))
            {
                var rawStatus = StringValue(value, "status") ??
                    (BoolValue(value, "done") == true ? "completed" : "pending");
                var status = rawStatus.Trim().ToLowerInvariant();
                return status is not ("completed" or "done");
            }

            foreach (var property in value.EnumerateObject())
            {
                if (ContainsIncompleteTodo(property.Value))
                {
                    return true;
                }
            }

            return false;
        }

        return value.ValueKind == JsonValueKind.Array &&
            value.EnumerateArray().Any(ContainsIncompleteTodo);
    }

    private static string? StringValue(JsonElement root, string key)
    {
        if (!root.TryGetProperty(key, out var value))
        {
            return null;
        }

        return value.ValueKind == JsonValueKind.String ? value.GetString() : value.ToString();
    }

    private static bool? BoolValue(JsonElement root, string key)
    {
        if (!root.TryGetProperty(key, out var value))
        {
            return null;
        }

        return value.ValueKind switch
        {
            JsonValueKind.True => true,
            JsonValueKind.False => false,
            _ => null,
        };
    }

    private static bool IsWorkspaceMutationRequest(string prompt)
    {
        var lower = prompt.ToLowerInvariant();
        string[] mutationVerbs =
        [
            "create",
            "build",
            "generate",
            "make",
            "write",
            "edit",
            "modify",
            "fix",
            "optimize",
            "implement",
            "rewrite",
            "update",
            "improve",
            "save",
            "delete",
            "remove",
        ];
        return mutationVerbs.Any(verb => lower.Contains(verb, StringComparison.Ordinal));
    }

    private static bool RequiresPostMutationVerification(string prompt)
    {
        var lower = PrimaryUserPrompt(prompt).ToLowerInvariant();
        string[] verificationVerbs =
        [
            "optimize",
            "fix",
            "improve",
            "refactor",
            "verify",
            "check",
            "continue",
            "delete",
            "remove",
        ];
        return verificationVerbs.Any(verb => lower.Contains(verb, StringComparison.Ordinal));
    }

    private static bool LooksLikeOngoingWorkspaceWork(string assistantContent)
    {
        var value = (assistantContent ?? "").Trim().ToLowerInvariant();
        if (string.IsNullOrWhiteSpace(value))
        {
            return true;
        }

        string[] completionMarkers = ["done", "completed", "complete.", "finished", "final summary", "here is the final", "all set"];
        if (completionMarkers.Any(marker => value.Contains(marker, StringComparison.Ordinal)))
        {
            return false;
        }

        string[] inProgressMarkers = ["let me", "i'll", "i will", "now let", "next", "continue", "start implementing", "apply", "verify", "check"];
        return inProgressMarkers.Any(marker => value.Contains(marker, StringComparison.Ordinal));
    }

    private static string PrimaryUserPrompt(string prompt)
    {
        string[] separators =
        [
            "\n\nRelevant PilotDeck memory context:",
            "\n\nRelevant G9Claw memory context:",
            "\n\nAttached files:",
            "\n\n\u9644\u4ef6:",
        ];
        var primary = prompt ?? "";
        foreach (var separator in separators)
        {
            var index = primary.IndexOf(separator, StringComparison.Ordinal);
            if (index >= 0)
            {
                primary = primary[..index];
            }
        }

        return primary.Trim();
    }
}
