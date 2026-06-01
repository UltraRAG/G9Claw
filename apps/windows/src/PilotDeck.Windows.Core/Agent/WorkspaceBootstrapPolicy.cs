using System.Text.Json;

namespace PilotDeck.Windows.Core;

public static class WorkspaceBootstrapPolicy
{
    public static bool ShouldForceWorkspaceBootstrap(
        AgentRequest request,
        IReadOnlyList<AgentToolExchange> toolExchanges,
        string assistantContent)
    {
        if (request.RunMode == ChatRunMode.Plan || toolExchanges.Count > 0)
        {
            return false;
        }

        var prompt = PrimaryUserPrompt(request.Prompt).ToLowerInvariant();
        if (!IsWorkspaceMutationRequest(prompt))
        {
            return false;
        }

        var content = (assistantContent ?? "").Trim().ToLowerInvariant();
        if (content.Contains("```", StringComparison.Ordinal) ||
            content == "bash" ||
            content == "json")
        {
            return true;
        }

        string[] finalOnlyPhrases = ["cannot", "can't", "unable", "no permission", "not supported"];
        return !finalOnlyPhrases.Any(phrase => content.Contains(phrase, StringComparison.Ordinal));
    }

    public static AgentToolCall ForcedWorkspaceBootstrapToolCall() =>
        new(
            $"native-bootstrap-{Guid.NewGuid():D}",
            "Glob",
            JsonSerializer.Serialize(new { pattern = "**/*", path = "." }));

    private static bool IsWorkspaceMutationRequest(string prompt)
    {
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
        return mutationVerbs.Any(verb => prompt.Contains(verb, StringComparison.Ordinal));
    }

    private static string PrimaryUserPrompt(string prompt)
    {
        string[] separators =
        [
            "\n\nRelevant PilotDeck memory context:",
            "\n\nRelevant PilotDeck memory context:",
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
