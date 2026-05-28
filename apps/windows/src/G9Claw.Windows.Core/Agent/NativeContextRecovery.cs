namespace G9Claw.Windows.Core;

public sealed record NativeContextRecoveryResult(
    List<ChatMessage> PriorMessages,
    List<AgentToolExchange> ToolExchanges,
    int PreTokens,
    int PostTokens,
    string Trigger,
    string Status);

public static partial class NativeAgentRuntime
{
    public static bool IsPromptTooLongError(Exception error)
    {
        if (error is not ProviderClientException { StatusCode: 400 or 413 } providerError)
        {
            return false;
        }

        var lower = providerError.Message.ToLowerInvariant();
        return lower.Contains("prompt_too_long", StringComparison.Ordinal) ||
            lower.Contains("context length", StringComparison.Ordinal) ||
            lower.Contains("maximum context", StringComparison.Ordinal) ||
            lower.Contains("too many tokens", StringComparison.Ordinal) ||
            lower.Contains("tokens exceed", StringComparison.Ordinal);
    }

    public static NativeContextRecoveryResult ForceRecoverContext(AgentRequest request)
    {
        var preTokens = EstimateRequestTokens(request);
        var compactedPrior = SnipPriorMessages(request);
        var compactedToolExchanges = request.ToolExchanges.TakeLast(4).ToList();
        var recoveredRequest = request with
        {
            PriorMessages = compactedPrior,
            ToolExchanges = compactedToolExchanges,
        };

        return new NativeContextRecoveryResult(
            compactedPrior,
            compactedToolExchanges,
            preTokens,
            EstimateRequestTokens(recoveredRequest),
            "prompt_too_long",
            "recovering");
    }

    private static List<ChatMessage> SnipPriorMessages(AgentRequest request)
    {
        var systemMessages = request.PriorMessages
            .Where(message => message.Role == ChatRole.System)
            .ToList();
        var body = request.PriorMessages
            .Where(message => message.Role != ChatRole.System)
            .ToList();
        var tail = body.TakeLast(4).ToList();
        var dropped = Math.Max(0, body.Count - tail.Count);
        var compacted = new List<ChatMessage>(systemMessages.Count + tail.Count + 1);
        compacted.AddRange(systemMessages);
        if (dropped > 0 || request.ToolExchanges.Count > 4)
        {
            compacted.Add(new ChatMessage(
                Guid.NewGuid(),
                request.SessionId,
                request.ProviderConfig.Provider,
                ChatRole.User,
                [ChatBlock.FromText($"""
                [Context compacted]
                Older conversation turns were summarized locally before continuing.
                Messages summarized: {dropped}.
                Continue the current task using the latest visible context and tool results.
                """)],
                DateTimeOffset.UtcNow,
                false,
                null));
        }

        compacted.AddRange(tail);
        return compacted;
    }

    private static int EstimateRequestTokens(AgentRequest request)
    {
        long characters = request.Prompt.Length;
        characters += request.Attachments.Sum(attachment => attachment.FileName.Length + attachment.Path.Length);
        characters += request.PriorMessages.Sum(message => message.PlainText.Length);
        characters += request.ToolExchanges.Sum(exchange =>
            exchange.Call.Name.Length +
            exchange.Call.InputJson.Length +
            exchange.Result.Output.Length);
        return Math.Max(1, (int)Math.Ceiling(characters / 4.0));
    }
}
