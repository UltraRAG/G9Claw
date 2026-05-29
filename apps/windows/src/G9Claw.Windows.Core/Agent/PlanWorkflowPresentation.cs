namespace G9Claw.Windows.Core;

public static class PlanWorkflowPresentation
{
    public const string GeneratingQuestionStatus = "plan generating question";
    public const string CollectingContextStatus = "plan collecting context";
    public const string GeneratingPlanStatus = "plan generating plan";
    public const string WaitingForAnswerStatus = "plan waiting answer";
    public const string WaitingForConfirmationStatus = "plan waiting confirmation";
    public const string RecoveringStatus = "plan recovering workflow";
    public const string RecoveryNeededStatus = "plan recovery needed";

    public static string? GenerationStatus(IEnumerable<AgentToolCall> toolCalls, ChatRunMode runMode)
    {
        var calls = toolCalls.ToList();
        if (runMode != ChatRunMode.Plan || calls.Count == 0)
        {
            return null;
        }

        var names = calls
            .Select(call => AgentToolNameCanonicalizer.Canonical(call.Name))
            .ToHashSet(StringComparer.Ordinal);
        if (names.Contains("AskQuestion"))
        {
            return GeneratingQuestionStatus;
        }

        if (names.Contains("SwitchMode"))
        {
            return GeneratingPlanStatus;
        }

        return calls.All(IsPlanExplorationCall) ? CollectingContextStatus : null;
    }

    public static string? WaitingStatus(string toolName, ChatRunMode runMode)
    {
        if (runMode != ChatRunMode.Plan)
        {
            return null;
        }

        return AgentToolNameCanonicalizer.Canonical(toolName) switch
        {
            "AskQuestion" => WaitingForAnswerStatus,
            "SwitchMode" => WaitingForConfirmationStatus,
            _ => null,
        };
    }

    public static bool IsInteractiveControl(string? toolName)
    {
        if (string.IsNullOrWhiteSpace(toolName))
        {
            return false;
        }

        return AgentToolNameCanonicalizer.Canonical(toolName) is "AskQuestion" or "SwitchMode";
    }

    private static bool IsPlanExplorationCall(AgentToolCall call)
    {
        var toolName = AgentToolNameCanonicalizer.Canonical(call.Name);
        if (toolName is "AskQuestion" or "SwitchMode")
        {
            return false;
        }

        return AgentToolBehaviorClassifier.IsReadOnlyTool(call);
    }
}
