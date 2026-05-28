using System.Text.Json;

namespace G9Claw.Windows.Core;

public static class DestructivePlanInputCodec
{
    public static string PlanMarkdown(string inputJson, bool chinese) =>
        ExitPlanModeInputCodec.ExtractPlanMarkdown(inputJson, chinese);

    public static string Target(string inputJson, bool chinese) =>
        StringValue(inputJson, "target") ?? (chinese ? "目标路径" : "target path");

    public static string ToolName(string inputJson, string fallbackToolName) =>
        StringValue(inputJson, "destructiveTool") ?? fallbackToolName;

    private static string? StringValue(string inputJson, string key)
    {
        try
        {
            using var doc = JsonDocument.Parse(inputJson);
            if (doc.RootElement.ValueKind != JsonValueKind.Object ||
                !doc.RootElement.TryGetProperty(key, out var value))
            {
                return null;
            }

            var text = value.ValueKind == JsonValueKind.String ? value.GetString() : value.ToString();
            return string.IsNullOrWhiteSpace(text) ? null : text.Trim();
        }
        catch (JsonException)
        {
            return null;
        }
    }
}
