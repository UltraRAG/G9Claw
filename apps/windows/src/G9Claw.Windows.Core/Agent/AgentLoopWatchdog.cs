namespace G9Claw.Windows.Core;

public enum AgentLoopWatchdogDecisionKind
{
    ContinueWithNudge,
    PauseNeedsUser,
}

public sealed record AgentLoopWatchdogDecision(
    AgentLoopWatchdogDecisionKind Kind,
    string Message);

public sealed class AgentLoopWatchdog
{
    public const int MaxDuplicateOnlyTurns = 4;
    public const int MaxRepeatedErrorResults = 3;

    private int _duplicateOnlyTurns;
    private string? _lastErrorSignature;
    private int _repeatedErrorResults;

    public void RecordProgress()
    {
        _duplicateOnlyTurns = 0;
    }

    public AgentLoopWatchdogDecision RecordDuplicateOnlyTurn()
    {
        _duplicateOnlyTurns++;
        if (_duplicateOnlyTurns >= MaxDuplicateOnlyTurns)
        {
            return new AgentLoopWatchdogDecision(
                AgentLoopWatchdogDecisionKind.PauseNeedsUser,
                "Agent repeated the same tool request without making progress. Please continue with a more specific instruction or adjust the request.");
        }

        return new AgentLoopWatchdogDecision(
            AgentLoopWatchdogDecisionKind.ContinueWithNudge,
            """
            The previous tool request was a duplicate and was skipped. Do not repeat the exact same tool call.
            Inspect the current file state if needed, update TodoWrite for real progress changes, or continue with the next distinct implementation or verification step.
            """);
    }

    public string? RecordToolResult(AgentToolResult result)
    {
        if (result.IsPolicyBlock || !result.IsError)
        {
            _lastErrorSignature = null;
            _repeatedErrorResults = 0;
            return null;
        }

        var signature = $"{result.ToolName}:{Compact(result.Output, 240)}";
        if (signature == _lastErrorSignature)
        {
            _repeatedErrorResults++;
        }
        else
        {
            _lastErrorSignature = signature;
            _repeatedErrorResults = 1;
        }

        return _repeatedErrorResults >= MaxRepeatedErrorResults
            ? $"Agent encountered the same tool error repeatedly and paused to avoid an unproductive loop: {Compact(result.Output, 180)}"
            : null;
    }

    private static string Compact(string value, int limit)
    {
        var normalized = value
            .Replace('\n', ' ')
            .Replace('\t', ' ')
            .Trim();
        return normalized.Length <= limit ? normalized : $"{normalized[..Math.Max(0, limit - 1)]}...";
    }
}
