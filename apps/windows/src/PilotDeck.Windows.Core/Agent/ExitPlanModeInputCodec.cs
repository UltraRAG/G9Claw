using System.Text.Json;
using System.Text.Json.Nodes;

namespace PilotDeck.Windows.Core;

public static class ExitPlanModeInputCodec
{
    private static readonly string[] PlanKeys = ["assistantPlanMarkdown", "plan", "planContent", "content", "markdown", "text", "body"];

    public static string UpdatedInputJson(string originalInputJson, string mode, string? userFeedback)
    {
        var root = ParseObject(originalInputJson) ?? [];
        root["mode"] = mode;
        var feedback = userFeedback?.Trim() ?? "";
        if (string.Equals(mode, "plan", StringComparison.OrdinalIgnoreCase) &&
            !string.IsNullOrWhiteSpace(feedback))
        {
            root["userFeedback"] = feedback;
        }
        else
        {
            root.Remove("userFeedback");
        }

        return JsonCanonicalizer.ToCanonicalJson(root);
    }

    public static string ExtractPlanMarkdown(string inputJson, bool chinese)
    {
        return ExtractPlanMarkdownOrNull(inputJson) ??
            (chinese
                ? PlanConfirmationCardMetrics.EmptyPlanFallbackZH
                : PlanConfirmationCardMetrics.EmptyPlanFallbackEN);
    }

    public static string? ExtractPlanMarkdownOrNull(string inputJson)
    {
        try
        {
            using var document = JsonDocument.Parse(inputJson);
            if (document.RootElement.ValueKind != JsonValueKind.Object)
            {
                return NonBlank(inputJson);
            }

            foreach (var key in PlanKeys)
            {
                if (document.RootElement.TryGetProperty(key, out var value) &&
                    value.ValueKind == JsonValueKind.String &&
                    NonBlank(value.GetString()) is { } text)
                {
                    return text;
                }
            }

            if (document.RootElement.TryGetProperty("steps", out var steps) &&
                steps.ValueKind == JsonValueKind.Array)
            {
                var lines = steps.EnumerateArray()
                    .Select((item, index) => item.ValueKind == JsonValueKind.String
                        ? $"{index + 1}. {item.GetString()}"
                        : "")
                    .Where(item => !string.IsNullOrWhiteSpace(item));
                if (NonBlank(string.Join("\n", lines)) is { } stepPlan)
                {
                    return stepPlan;
                }
            }

            if (document.RootElement.TryGetProperty("plan", out var plan) &&
                plan.ValueKind == JsonValueKind.Object)
            {
                var sections = plan.EnumerateObject()
                    .Select(PlanSection)
                    .Where(item => !string.IsNullOrWhiteSpace(item))
                    .Order(StringComparer.Ordinal)
                    .ToList();
                return NonBlank(string.Join("\n\n", sections));
            }
        }
        catch (JsonException)
        {
            return NonBlank(inputJson);
        }

        return null;
    }

    private static string? PlanSection(JsonProperty property)
    {
        if (property.Value.ValueKind == JsonValueKind.String &&
            NonBlank(property.Value.GetString()) is { } text)
        {
            return $"### {property.Name}\n{text}";
        }

        if (property.Value.ValueKind == JsonValueKind.Array)
        {
            var items = property.Value.EnumerateArray()
                .Select(item => item.ValueKind == JsonValueKind.String ? item.GetString() : null)
                .Where(item => !string.IsNullOrWhiteSpace(item))
                .Select(item => $"- {item}");
            return NonBlank($"### {property.Name}\n{string.Join("\n", items)}");
        }

        return null;
    }

    private static JsonObject? ParseObject(string inputJson)
    {
        try
        {
            return JsonNode.Parse(string.IsNullOrWhiteSpace(inputJson) ? "{}" : inputJson) as JsonObject;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static string? NonBlank(string? value)
    {
        var trimmed = value?.Trim() ?? "";
        return string.IsNullOrWhiteSpace(trimmed) ? null : trimmed;
    }
}
