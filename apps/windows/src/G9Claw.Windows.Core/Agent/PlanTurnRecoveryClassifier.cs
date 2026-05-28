using System.Text.Json;
using System.Text.RegularExpressions;

namespace G9Claw.Windows.Core;

public sealed record PlanTurnRecovery(
    AgentToolCall Call,
    string WorkflowStatus,
    string GenerationStatus);

public static class PlanTurnRecoveryClassifier
{
    public const string RecoveringStatus = "plan recovering workflow";
    public const string GeneratingQuestionStatus = "plan generating question";
    public const string GeneratingPlanStatus = "plan generating plan";

    public static PlanTurnRecovery? Recovery(
        string assistantContent,
        string userPrompt,
        bool planQuestionAnswered)
    {
        var trimmed = (assistantContent ?? "").Trim();
        if (LooksLikeRawProtocol(trimmed))
        {
            return null;
        }

        if (!planQuestionAnswered)
        {
            return new PlanTurnRecovery(
                AskQuestionCall(string.IsNullOrWhiteSpace(trimmed) ? userPrompt : trimmed),
                RecoveringStatus,
                GeneratingQuestionStatus);
        }

        return new PlanTurnRecovery(
            SwitchModeCall(FallbackPlanMarkdown(trimmed, userPrompt)),
            RecoveringStatus,
            GeneratingPlanStatus);
    }

    private static AgentToolCall AskQuestionCall(string text)
    {
        var question = FallbackQuestion(text);
        var payload = new
        {
            questions = new[]
            {
                new
                {
                    header = "Plan question",
                    question,
                    options = Array.Empty<object>(),
                    multiSelect = false,
                },
            },
            recoveredFromPlainText = true,
        };
        return new AgentToolCall($"plan-recovery-ask-{Guid.NewGuid():D}", "AskQuestion", JsonSerializer.Serialize(payload, JsonOptions));
    }

    private static AgentToolCall SwitchModeCall(string plan)
    {
        var payload = new
        {
            mode = "agent",
            plan,
            assistantPlanMarkdown = plan,
            recoveredFromPlainText = true,
        };
        return new AgentToolCall($"plan-recovery-switch-{Guid.NewGuid():D}", "SwitchMode", JsonSerializer.Serialize(payload, JsonOptions));
    }

    private static bool LooksLikeRawProtocol(string text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return false;
        }

        var lower = text.ToLowerInvariant();
        if (lower.StartsWith("<call", StringComparison.Ordinal) ||
            lower.StartsWith("<invoke", StringComparison.Ordinal) ||
            lower.StartsWith("<tool", StringComparison.Ordinal) ||
            lower.StartsWith("<response", StringComparison.Ordinal))
        {
            return true;
        }

        return text.StartsWith("{", StringComparison.Ordinal) &&
            (lower.Contains("\"name\"", StringComparison.Ordinal) ||
             lower.Contains("\"tool\"", StringComparison.Ordinal) ||
             lower.Contains("askquestion", StringComparison.Ordinal) ||
             lower.Contains("switchmode", StringComparison.Ordinal));
    }

    private static string FallbackQuestion(string text)
    {
        var normalized = NormalizeLines(text);
        var questionLine = normalized
            .Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .FirstOrDefault(LooksLikeQuestionTurn);
        if (!string.IsNullOrWhiteSpace(questionLine))
        {
            return StripListMarker(questionLine);
        }

        return string.IsNullOrWhiteSpace(normalized)
            ? "What should I clarify before preparing the execution plan?"
            : $"Please confirm how I should proceed with this plan: {Compact(normalized, 260)}";
    }

    private static string FallbackPlanMarkdown(string assistantContent, string userPrompt)
    {
        if (LooksLikeFinalPlan(assistantContent))
        {
            return assistantContent.Trim();
        }

        var content = string.IsNullOrWhiteSpace(assistantContent)
            ? "No additional assistant plan text was provided."
            : assistantContent.Trim();
        return $"""
        Plan

        User request:
        {userPrompt.Trim()}

        Recovered assistant notes:
        {content}
        """;
    }

    private static bool LooksLikeQuestionTurn(string text)
    {
        var lower = text.ToLowerInvariant();
        return lower.Contains("?", StringComparison.Ordinal) ||
            lower.Contains("what", StringComparison.Ordinal) ||
            lower.Contains("which", StringComparison.Ordinal) ||
            lower.Contains("choose", StringComparison.Ordinal) ||
            lower.Contains("question", StringComparison.Ordinal) ||
            lower.Contains("confirm", StringComparison.Ordinal);
    }

    private static bool LooksLikeFinalPlan(string text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return false;
        }

        var lower = text.ToLowerInvariant();
        var hasPlanWord = lower.Contains("plan", StringComparison.Ordinal) ||
            lower.Contains("implementation", StringComparison.Ordinal);
        return hasPlanWord && Regex.Matches(text, @"(?m)^\s*(?:\d+[\.\)]|-|\*)\s+\S+").Count >= 2;
    }

    private static string NormalizeLines(string text) =>
        (text ?? "").Replace("\r\n", "\n").Replace('\r', '\n').Trim();

    private static string StripListMarker(string text) =>
        Regex.Replace(text.Trim(), @"^\s*(?:[-*]|\d+[\.\)])\s*", "");

    private static string Compact(string value, int limit)
    {
        var normalized = value.Replace('\n', ' ').Replace('\t', ' ').Trim();
        return normalized.Length <= limit ? normalized : $"{normalized[..Math.Max(0, limit - 1)]}...";
    }

    private static JsonSerializerOptions JsonOptions { get; } = new() { WriteIndented = true };
}
