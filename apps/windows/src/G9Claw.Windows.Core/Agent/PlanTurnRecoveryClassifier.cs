using System.Text.Json;
using System.Text.RegularExpressions;

namespace G9Claw.Windows.Core;

public enum PlanTurnRecoveryKind
{
    AskQuestion,
    SwitchMode,
    Intro,
}

public sealed record PlanTurnRecovery(
    PlanTurnRecoveryKind Kind,
    AgentToolCall Call,
    string WorkflowStatus,
    string GenerationStatus,
    string? IntroText = null);

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
            var questionText = string.IsNullOrWhiteSpace(trimmed) ? userPrompt : trimmed;
            if (!string.IsNullOrWhiteSpace(trimmed) &&
                !LooksLikeQuestionTurn(trimmed) &&
                !LooksLikeFinalPlan(trimmed))
            {
                return new PlanTurnRecovery(
                    PlanTurnRecoveryKind.Intro,
                    AskQuestionCall(questionText),
                    RecoveringStatus,
                    GeneratingQuestionStatus,
                    ShortIntro(trimmed));
            }

            return new PlanTurnRecovery(
                PlanTurnRecoveryKind.AskQuestion,
                AskQuestionCall(questionText),
                RecoveringStatus,
                GeneratingQuestionStatus);
        }

        if (!string.IsNullOrWhiteSpace(trimmed) && !LooksLikeFinalPlan(trimmed))
        {
            return new PlanTurnRecovery(
                PlanTurnRecoveryKind.Intro,
                SwitchModeCall(FallbackPlanMarkdown(trimmed, userPrompt)),
                RecoveringStatus,
                GeneratingPlanStatus,
                ShortIntro(trimmed));
        }

        return new PlanTurnRecovery(
            PlanTurnRecoveryKind.SwitchMode,
            SwitchModeCall(FallbackPlanMarkdown(trimmed, userPrompt)),
            RecoveringStatus,
            GeneratingPlanStatus);
    }

    private static AgentToolCall AskQuestionCall(string text)
    {
        var payload = new
        {
            questions = ChoiceQuestions(text),
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

    private static IReadOnlyList<Dictionary<string, object?>> ChoiceQuestions(string text)
    {
        var normalized = NormalizeLines(text);
        var lines = normalized
            .Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Where(line => !string.IsNullOrWhiteSpace(line))
            .ToList();
        var questions = new List<Dictionary<string, object?>>();

        for (var index = 0; index < lines.Count && questions.Count < 4; index++)
        {
            var question = NormalizedQuestionLine(lines[index]);
            if (question is null) continue;

            var optionLabels = InlineOptions(lines[index]);
            var scan = index + 1;
            while (scan < lines.Count)
            {
                if (NormalizedQuestionLine(lines[scan]) is not null) break;
                if (NormalizedOptionLine(lines[scan]) is { } option)
                {
                    optionLabels.Add(option);
                }
                scan++;
            }

            questions.Add(QuestionPayload(question, optionLabels, normalized));
            index = Math.Max(index, scan - 1);
        }

        if (questions.Count == 0)
        {
            var question = FallbackQuestion(normalized);
            questions.Add(QuestionPayload(question, [], normalized));
        }

        return questions;
    }

    private static Dictionary<string, object?> QuestionPayload(string question, IReadOnlyList<string> labels, string sourceText) =>
        new()
        {
            ["header"] = "Plan question",
            ["question"] = CleanQuestionText(question),
            ["options"] = OptionDictionaries(labels, FallbackOptions(question, sourceText)),
            ["multiSelect"] = ShouldAllowMultiple(question),
        };

    private static string? NormalizedQuestionLine(string line)
    {
        var cleaned = CleanQuestionText(StripListMarker(line));
        if (string.IsNullOrWhiteSpace(cleaned)) return null;
        if (LooksLikeQuestionTurn(cleaned)) return cleaned;
        return null;
    }

    private static string? NormalizedOptionLine(string line)
    {
        var match = Regex.Match(line.Trim(), @"^\s*(?:[-*]|\d+[\.\)\u3001\uff09]|[A-Za-z][\.\)])\s*(?<option>.+?)\s*$");
        if (!match.Success) return null;
        var cleaned = CleanOptionText(match.Groups["option"].Value);
        if (string.IsNullOrWhiteSpace(cleaned) || cleaned.Length > 80) return null;
        return NormalizedQuestionLine(cleaned) is null ? cleaned : null;
    }

    private static List<string> InlineOptions(string line)
    {
        foreach (var marker in new[] { "options:", "such as", "choices:", "choose from:" })
        {
            var index = line.IndexOf(marker, StringComparison.OrdinalIgnoreCase);
            if (index < 0) continue;
            var tail = line[(index + marker.Length)..];
            return SplitOptionTail(tail);
        }

        return [];
    }

    private static List<string> SplitOptionTail(string tail) =>
        Regex.Split(tail, @"\s*(?:,|;|/|\||\bor\b)\s*", RegexOptions.IgnoreCase)
            .Select(CleanOptionText)
            .Where(option => !string.IsNullOrWhiteSpace(option))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Take(6)
            .ToList();

    private static IReadOnlyList<Dictionary<string, string>> OptionDictionaries(
        IReadOnlyList<string> labels,
        IReadOnlyList<string> fallback)
    {
        var source = labels.Count > 0 ? labels : fallback;
        return source
            .Select(CleanOptionText)
            .Where(option => !string.IsNullOrWhiteSpace(option))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Take(6)
            .Select(option => new Dictionary<string, string> { ["label"] = option })
            .ToList();
    }

    private static IReadOnlyList<string> FallbackOptions(string question, string sourceText)
    {
        var lower = $"{question} {sourceText}".ToLowerInvariant();
        if (lower.Contains("feature", StringComparison.Ordinal) ||
            lower.Contains("module", StringComparison.Ordinal) ||
            lower.Contains("requirement", StringComparison.Ordinal))
        {
            return ["Basic features", "Complete feature set", "Visual demo first", "Let G9Claw decide"];
        }

        if (lower.Contains("style", StringComparison.Ordinal) ||
            lower.Contains("design", StringComparison.Ordinal) ||
            lower.Contains("visual", StringComparison.Ordinal))
        {
            return ["Clean modern", "Premium native", "Playful colorful", "System default"];
        }

        if (lower.Contains("storage", StringComparison.Ordinal) ||
            lower.Contains("data", StringComparison.Ordinal) ||
            lower.Contains("save", StringComparison.Ordinal))
        {
            return ["Static demo data", "Local persistence", "Import and export", "No data storage yet"];
        }

        return ["Recommended approach", "Simpler approach", "Complete approach", "Continue analysis first"];
    }

    private static bool ShouldAllowMultiple(string question)
    {
        var lower = question.ToLowerInvariant();
        return lower.Contains("multiple", StringComparison.Ordinal) ||
               lower.Contains("which", StringComparison.Ordinal) ||
               lower.Contains("features", StringComparison.Ordinal) ||
               lower.Contains("modules", StringComparison.Ordinal) ||
               lower.Contains("\u54ea\u4e9b", StringComparison.Ordinal);
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
            lower.Contains("\uff1f", StringComparison.Ordinal) ||
            lower.Contains("\u8bf7\u544a\u8bc9", StringComparison.Ordinal) ||
            lower.Contains("\u8bf7\u9009\u62e9", StringComparison.Ordinal) ||
            lower.Contains("\u9700\u8981\u786e\u8ba4", StringComparison.Ordinal) ||
            lower.Contains("\u51e0\u4e2a\u95ee\u9898", StringComparison.Ordinal) ||
            lower.Contains("\u8865\u5145", StringComparison.Ordinal) ||
            lower.Contains("\u504f\u597d", StringComparison.Ordinal) ||
            lower.Contains("what", StringComparison.Ordinal) ||
            lower.Contains("which", StringComparison.Ordinal) ||
            lower.Contains("choose", StringComparison.Ordinal) ||
            lower.Contains("question", StringComparison.Ordinal) ||
            lower.Contains("confirm", StringComparison.Ordinal) ||
            Regex.IsMatch(text, @"(?m)^\s*\d+[\.\u3001\uff09\)]\s*[^.\n]*[\?\uff1f]");
    }

    private static bool LooksLikeFinalPlan(string text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return false;
        }

        var lower = text.ToLowerInvariant();
        var hasPlanWord = lower.Contains("plan", StringComparison.Ordinal) ||
            lower.Contains("implementation", StringComparison.Ordinal) ||
            lower.Contains("\u8ba1\u5212", StringComparison.Ordinal) ||
            lower.Contains("\u65b9\u6848", StringComparison.Ordinal) ||
            lower.Contains("\u5b9e\u65bd", StringComparison.Ordinal);
        return hasPlanWord && Regex.Matches(text, @"(?m)^\s*(?:\d+[\.\)\u3001\uff09]|-|\*)\s+\S+").Count >= 2;
    }

    private static string NormalizeLines(string text) =>
        (text ?? "").Replace("\r\n", "\n").Replace('\r', '\n').Trim();

    private static string StripListMarker(string text) =>
        Regex.Replace(text.Trim(), @"^\s*(?:[-*]|\d+[\.\)\u3001\uff09])\s*", "");

    private static string CleanQuestionText(string text) =>
        Regex.Replace(text, @"[*_`#]+", "")
            .Trim();

    private static string CleanOptionText(string text) =>
        Regex.Replace(text, @"[*_`#]+", "")
            .Trim()
            .TrimEnd('.', ';', ',');

    private static string Compact(string value, int limit)
    {
        var normalized = value.Replace('\n', ' ').Replace('\t', ' ').Trim();
        return normalized.Length <= limit ? normalized : $"{normalized[..Math.Max(0, limit - 1)]}...";
    }

    private static string ShortIntro(string text)
    {
        var trimmed = (text ?? "").Trim();
        if (trimmed.Length <= 180)
        {
            return trimmed;
        }

        var paragraph = trimmed
            .Split(["\n\n"], StringSplitOptions.None)
            .Select(item => item.Trim())
            .FirstOrDefault(item => !string.IsNullOrWhiteSpace(item)) ?? trimmed;
        return paragraph.Length <= 180 ? paragraph : $"{paragraph[..160].Trim()}...";
    }

    private static JsonSerializerOptions JsonOptions { get; } = new() { WriteIndented = true };
}
