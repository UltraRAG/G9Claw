namespace PilotDeck.Windows.Core;

public sealed record NativeContextRecoveryResult(
    List<ChatMessage> PriorMessages,
    List<AgentToolExchange> ToolExchanges,
    int PreTokens,
    int PostTokens,
    string Trigger,
    string Status);

public static partial class NativeAgentRuntime
{
    public static TokenBudget ContextBudgetSnapshot(AgentRequest request) =>
        new(EstimateRequestTokens(request), Math.Max(request.ContextWindow, 1));

    public static ContextBudgetLevel ContextBudgetLevelFor(TokenBudget budget)
    {
        if (budget.Total <= 0)
        {
            return ContextBudgetLevel.Normal;
        }

        var ratio = (double)Math.Max(0, budget.Used) / budget.Total;
        if (ratio >= 0.95) return ContextBudgetLevel.Recovering;
        if (ratio >= 0.80) return ContextBudgetLevel.Warning;
        if (ratio >= 0.60) return ContextBudgetLevel.Attention;
        return ContextBudgetLevel.Normal;
    }

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

    public static NativeContextRecoveryResult? CompactContextIfNeeded(AgentRequest request)
    {
        var before = ContextBudgetSnapshot(request);
        var beforeLevel = ContextBudgetLevelFor(before);
        if (beforeLevel is not (ContextBudgetLevel.Warning or ContextBudgetLevel.Recovering))
        {
            return null;
        }

        var compactedToolExchanges = MicroCompactToolResults(request.ToolExchanges);
        var compactedRequest = request with { ToolExchanges = compactedToolExchanges };
        var after = ContextBudgetSnapshot(compactedRequest);
        var status = "micro";

        if (ContextBudgetLevelFor(after) is ContextBudgetLevel.Warning or ContextBudgetLevel.Recovering)
        {
            compactedRequest = request with
            {
                PriorMessages = SnipPriorMessages(request, 10),
                ToolExchanges = compactedToolExchanges.TakeLast(6).ToList(),
            };
            after = ContextBudgetSnapshot(compactedRequest);
            status = "snip";
        }

        if (ContextBudgetLevelFor(after) is ContextBudgetLevel.Warning or ContextBudgetLevel.Recovering)
        {
            compactedRequest = request with
            {
                PriorMessages = SnipPriorMessages(request, 6),
                ToolExchanges = compactedToolExchanges.TakeLast(4).ToList(),
            };
            after = ContextBudgetSnapshot(compactedRequest);
            status = "full";
        }

        return new NativeContextRecoveryResult(
            compactedRequest.PriorMessages,
            compactedRequest.ToolExchanges,
            before.Used,
            after.Used,
            beforeLevel == ContextBudgetLevel.Recovering ? "blocking_threshold" : "warning_threshold",
            status);
    }

    public static NativeContextRecoveryResult ForceRecoverContext(AgentRequest request)
    {
        var preTokens = EstimateRequestTokens(request);
        var compactedPrior = SnipPriorMessages(request, 4);
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

    private static List<ChatMessage> SnipPriorMessages(AgentRequest request, int tailCount)
    {
        var systemMessages = request.PriorMessages
            .Where(message => message.Role == ChatRole.System)
            .ToList();
        var body = request.PriorMessages
            .Where(message => message.Role != ChatRole.System)
            .ToList();
        var tail = body.TakeLast(Math.Max(1, tailCount)).ToList();
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

    private static List<AgentToolExchange> MicroCompactToolResults(List<AgentToolExchange> exchanges)
    {
        if (exchanges.Count <= 4)
        {
            return exchanges.ToList();
        }

        var recentStart = Math.Max(0, exchanges.Count - 4);
        return exchanges.Select((exchange, index) =>
        {
            if (index >= recentStart || exchange.Result.Output.Length <= 3000)
            {
                return exchange;
            }

            var compactedOutput = $"{exchange.Result.Output[..1600]}\n... (microcompacted, original {exchange.Result.Output.Length} characters)";
            return exchange with { Result = exchange.Result with { Output = compactedOutput } };
        }).ToList();
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
