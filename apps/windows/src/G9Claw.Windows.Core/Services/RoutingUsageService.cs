namespace G9Claw.Windows.Core;

public sealed record RoutingUsageRecord(
    string SessionId,
    string ProjectName,
    string Route,
    string Provider,
    string Model,
    string Tier,
    int InputTokens,
    int OutputTokens,
    decimal EstimatedCost,
    decimal BaselineCost,
    DateTimeOffset CreatedAt,
    string? FallbackFromModelEntry = null,
    string? FallbackReason = null,
    string? FinalModelEntry = null)
{
    public int TotalTokens => InputTokens + OutputTokens;
    public decimal SavedCost => Math.Max(0, BaselineCost - EstimatedCost);
}

public sealed record RoutingModelBreakdown(
    string Provider,
    string Model,
    int Requests,
    int InputTokens,
    int OutputTokens,
    decimal EstimatedCost,
    decimal BaselineCost)
{
    public int TotalTokens => InputTokens + OutputTokens;
    public decimal SavedCost => Math.Max(0, BaselineCost - EstimatedCost);
}

public sealed record RoutingDashboardSnapshot(
    int RequestCount,
    int InputTokens,
    int OutputTokens,
    decimal EstimatedCost,
    decimal BaselineCost,
    IReadOnlyList<RoutingUsageRecord> RecentRoutes,
    IReadOnlyList<RoutingModelBreakdown> ModelBreakdown)
{
    public int TotalTokens => InputTokens + OutputTokens;
    public decimal SavedCost => Math.Max(0, BaselineCost - EstimatedCost);
}

public static class RoutingUsageEstimator
{
    public static RoutingUsageRecord FromBudget(
        AgentRequest request,
        WorkspaceProject? project,
        TokenBudget? budget,
        DateTimeOffset? createdAt = null)
    {
        var total = Math.Max(0, budget?.Used ?? 0);
        var output = Math.Min(total, Math.Max(0, total / 3));
        var input = Math.Max(0, total - output);
        var settings = request.NativeConfigValues.TryGetValue("router.tier", out var tier) && !string.IsNullOrWhiteSpace(tier)
            ? tier
            : "default";

        return new RoutingUsageRecord(
            request.SessionId,
            project?.DisplayName ?? "General",
            string.IsNullOrWhiteSpace(request.RouterRoute) ? "default" : request.RouterRoute,
            request.ProviderConfig.Provider.DisplayName(),
            request.ProviderConfig.Model,
            settings,
            input,
            output,
            Estimate(input, output, request.NativeConfigValues, "router.inputPricePerMillion", "router.outputPricePerMillion"),
            Estimate(input, output, request.NativeConfigValues, "router.baselineInputPricePerMillion", "router.baselineOutputPricePerMillion"),
            createdAt ?? DateTimeOffset.UtcNow,
            request.NativeConfigValues.GetValueOrDefault("router.fallbackFromModelEntry"),
            request.NativeConfigValues.GetValueOrDefault("router.fallbackReason"),
            request.NativeConfigValues.GetValueOrDefault("router.finalModelEntry"));
    }

    public static decimal Estimate(
        int inputTokens,
        int outputTokens,
        NativeRouterSettings settings,
        bool baseline)
    {
        return Price(
            inputTokens,
            outputTokens,
            baseline ? settings.BaselineInputPricePerMillion : settings.InputPricePerMillion,
            baseline ? settings.BaselineOutputPricePerMillion : settings.OutputPricePerMillion);
    }

    private static decimal Estimate(
        int inputTokens,
        int outputTokens,
        IReadOnlyDictionary<string, string> values,
        string inputKey,
        string outputKey)
    {
        var inputPrice = DecimalValue(values, inputKey);
        var outputPrice = DecimalValue(values, outputKey);
        return Price(inputTokens, outputTokens, inputPrice, outputPrice);
    }

    private static decimal Price(int inputTokens, int outputTokens, decimal inputPricePerMillion, decimal outputPricePerMillion) =>
        Math.Round(inputTokens / 1_000_000m * inputPricePerMillion + outputTokens / 1_000_000m * outputPricePerMillion, 6);

    private static decimal DecimalValue(IReadOnlyDictionary<string, string> values, string key) =>
        values.TryGetValue(key, out var value) && decimal.TryParse(value, out var parsed)
            ? Math.Max(0, parsed)
            : 0;
}

public static class RoutingUsageAggregator
{
    public static RoutingDashboardSnapshot Snapshot(IEnumerable<RoutingUsageRecord> records, int recentLimit = 12)
    {
        var list = records.OrderByDescending(record => record.CreatedAt).ToList();
        var breakdown = list
            .GroupBy(record => $"{record.Provider}\n{record.Model}", StringComparer.OrdinalIgnoreCase)
            .Select(group =>
            {
                var first = group.First();
                return new RoutingModelBreakdown(
                    first.Provider,
                    first.Model,
                    group.Count(),
                    group.Sum(record => record.InputTokens),
                    group.Sum(record => record.OutputTokens),
                    group.Sum(record => record.EstimatedCost),
                    group.Sum(record => record.BaselineCost));
            })
            .OrderByDescending(item => item.Requests)
            .ThenBy(item => item.Provider, StringComparer.OrdinalIgnoreCase)
            .ThenBy(item => item.Model, StringComparer.OrdinalIgnoreCase)
            .ToList();

        return new RoutingDashboardSnapshot(
            list.Count,
            list.Sum(record => record.InputTokens),
            list.Sum(record => record.OutputTokens),
            list.Sum(record => record.EstimatedCost),
            list.Sum(record => record.BaselineCost),
            list.Take(Math.Max(1, recentLimit)).ToList(),
            breakdown);
    }
}
