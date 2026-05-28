using System.Text.Json;
using System.Text.Json.Nodes;

namespace G9Claw.Windows.Core;

public static class AskQuestionAnswerCodec
{
    public static string UpdatedInputJson(string originalInputJson, IReadOnlyDictionary<string, string> answers)
    {
        var root = ParseObject(originalInputJson) ?? [];
        var answerObject = new JsonObject();
        foreach (var pair in answers.OrderBy(pair => pair.Key, StringComparer.Ordinal))
        {
            if (!string.IsNullOrWhiteSpace(pair.Value))
            {
                answerObject[pair.Key] = pair.Value.Trim();
            }
        }

        root["answers"] = answerObject;
        return JsonCanonicalizer.ToCanonicalJson(root);
    }

    public static bool HasNonEmptyAnswers(string inputJson) =>
        AnswerEntries(inputJson).Count > 0;

    public static string Output(string inputJson)
    {
        var entries = AnswerEntries(inputJson)
            .Select(pair => $"\"{pair.Key}\"=\"{pair.Value}\"")
            .ToList();
        if (entries.Count == 0)
        {
            return "User has not answered any questions yet.";
        }

        return $"User has answered your questions: {string.Join(", ", entries)}. You can now continue with the user's answers in mind. If you are in Plan mode, continue with read-only planning if needed, then call SwitchMode with mode=\"agent\" and a concrete plan. Do not stop after ordinary prose only.";
    }

    private static SortedDictionary<string, string> AnswerEntries(string inputJson)
    {
        var entries = new SortedDictionary<string, string>(StringComparer.Ordinal);
        try
        {
            using var doc = JsonDocument.Parse(inputJson);
            if (!doc.RootElement.TryGetProperty("answers", out var answers) ||
                answers.ValueKind != JsonValueKind.Object)
            {
                return entries;
            }

            foreach (var property in answers.EnumerateObject())
            {
                var value = DisplayValue(property.Value);
                if (!string.IsNullOrWhiteSpace(value))
                {
                    entries[property.Name] = value.Trim();
                }
            }
        }
        catch (JsonException)
        {
            return entries;
        }

        return entries;
    }

    private static string DisplayValue(JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.String)
        {
            return value.GetString() ?? "";
        }

        if (value.ValueKind == JsonValueKind.Array)
        {
            var values = value.EnumerateArray()
                .Select(DisplayValue)
                .Where(item => !string.IsNullOrWhiteSpace(item));
            return string.Join(", ", values);
        }

        return value.ToString();
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
}
