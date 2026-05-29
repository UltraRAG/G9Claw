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

    public static bool IsPlanExplorationCall(AgentToolCall call)
    {
        var toolName = AgentToolNameCanonicalizer.Canonical(call.Name);
        if (toolName is "AskQuestion" or "SwitchMode")
        {
            return false;
        }

        return toolName == "TodoWrite" || AgentToolBehaviorClassifier.IsReadOnlyTool(call);
    }
}

public static class PlanModeIntroSynthesizer
{
    public const string ReadIntro = "\u6211\u5148\u67e5\u770b\u76f8\u5173\u6587\u4ef6\u548c\u9879\u76ee\u7ed3\u6784\uff0c\u7528\u6765\u5b8c\u5584\u8ba1\u5212\u3002";
    public const string SearchIntro = "\u6211\u5148\u641c\u7d22\u73b0\u6709\u4ee3\u7801\u7ebf\u7d22\uff0c\u7528\u6765\u5b8c\u5584\u8ba1\u5212\u3002";
    public const string CommandIntro = "\u6211\u5148\u8fd0\u884c\u53ea\u8bfb\u547d\u4ee4\u786e\u8ba4\u4e0a\u4e0b\u6587\uff0c\u7528\u6765\u5b8c\u5584\u8ba1\u5212\u3002";
    public const string TodoIntro = "\u6211\u5148\u6574\u7406\u4efb\u52a1\u4e0a\u4e0b\u6587\uff0c\u7528\u6765\u5b8c\u5584\u8ba1\u5212\u3002";
    public const string ContextIntro = "\u6211\u5148\u6536\u96c6\u5fc5\u8981\u4e0a\u4e0b\u6587\uff0c\u7528\u6765\u5b8c\u5584\u8ba1\u5212\u3002";

    public static string? Intro(IEnumerable<AgentToolCall> toolCalls, ChatRunMode runMode)
    {
        var calls = toolCalls.ToList();
        if (runMode != ChatRunMode.Plan || calls.Count == 0 || !calls.All(PlanWorkflowPresentation.IsPlanExplorationCall))
        {
            return null;
        }

        var names = calls
            .Select(call => AgentToolNameCanonicalizer.Canonical(call.Name))
            .ToList();
        if (names.Any(AgentToolPresentationClassifier.IsReadTool))
        {
            return ReadIntro;
        }

        if (names.Any(name => AgentToolPresentationClassifier.PhaseForToolName(name) == AgentActivityPhase.Search))
        {
            return SearchIntro;
        }

        if (names.Any(name => AgentToolPresentationClassifier.PhaseForToolName(name) == AgentActivityPhase.Command))
        {
            return CommandIntro;
        }

        if (names.Contains("TodoRead", StringComparer.Ordinal) || names.Contains("TodoWrite", StringComparer.Ordinal))
        {
            return TodoIntro;
        }

        return ContextIntro;
    }
}
