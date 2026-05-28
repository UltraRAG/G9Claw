using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace G9Claw.Windows.Core;

public sealed record NativeSubagentRequest(
    string WorkspaceRoot,
    string Prompt,
    string Description,
    string ExtraContext,
    AgentToolExecutionContext Context);

public interface INativeSubagentRunner
{
    bool RequiresProviderConfig { get; }

    Task<string> RunAsync(NativeSubagentRequest request, CancellationToken cancellationToken);
}

public sealed class ProviderNativeSubagentRunner : INativeSubagentRunner
{
    private readonly IProviderClient _providerClient;

    public ProviderNativeSubagentRunner(IProviderClient? providerClient = null)
    {
        _providerClient = providerClient ?? new ProviderClient();
    }

    public bool RequiresProviderConfig => true;

    public async Task<string> RunAsync(NativeSubagentRequest request, CancellationToken cancellationToken)
    {
        var context = request.Context;
        if (context.ProviderConfig is null || string.IsNullOrWhiteSpace(context.ApiKey))
        {
            throw new InvalidOperationException("Subagent execution requires provider configuration and API key.");
        }

        var configValues = context.NativeConfigValues is null
            ? new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            : new Dictionary<string, string>(context.NativeConfigValues, StringComparer.OrdinalIgnoreCase);
        var routeTier = NativeRoutingClassifier.ClassifyTier(request.Prompt, context.RunMode);
        var route = NativeRouterRuntime.ResolveProviderRoute(
            routeTier,
            configValues,
            context.ProviderConfig,
            context.ApiKey,
            context.ContextWindow,
            NativeRouterRuntime.SignalsForPrompt(request.Prompt, isBackgroundRequest: true));
        configValues["router.tier"] = route.Decision.Tier ?? routeTier;
        configValues["router.routeEntryId"] = route.Decision.EntryId;
        configValues["router.routeSource"] = "subagent";
        configValues["provider.providerId"] = route.ProviderId;
        configValues["provider.modelEntryId"] = route.Decision.EntryId;
        configValues["provider.modelName"] = route.ProviderConfig.Model;
        configValues["provider.endpointUrl"] = NativeAgentRuntime.EndpointUrl(
            route.ProviderConfig.BaseUrl,
            AgentModelResolver.SuffixFor(route.ProviderConfig.ApiType)).ToString();

        var content = $"""
        Workspace: {request.WorkspaceRoot}
        Description: {request.Description}

        {request.ExtraContext}

        Subtask:
        {request.Prompt}
        """;
        var subagentRequest = new AgentRequest(
            context.SessionId,
            request.WorkspaceRoot,
            content,
            [],
            route.ProviderConfig,
            route.ApiKey,
            [
                new ChatMessage(
                    Guid.NewGuid(),
                    context.SessionId,
                    SessionProvider.G9Claw,
                    ChatRole.System,
                    [ChatBlock.FromText("You are a focused read-only subagent. Answer the delegated subtask concisely. Do not claim to edit files, run shell commands, or call tools.")],
                    DateTimeOffset.UtcNow,
                    false,
                    null),
            ],
            context.TimeoutMs,
            route.ContextWindow,
            context.PermissionMode,
            context.RunMode,
            context.PermissionSettings,
            route.Decision.Scenario,
            configValues)
        {
            EnableTools = false,
            Stream = false,
        };

        var output = new StringBuilder();
        await foreach (var providerEvent in _providerClient.StreamAsync(subagentRequest, cancellationToken))
        {
            if (providerEvent.Kind == ProviderStreamEventKind.ContentDelta && providerEvent.Text is { } text)
            {
                output.Append(text);
            }
            else if (providerEvent.Kind == ProviderStreamEventKind.ToolCall)
            {
                throw new InvalidOperationException("Read-only subagent attempted to call a tool.");
            }
        }

        var answer = output.ToString().Trim();
        if (string.IsNullOrWhiteSpace(answer))
        {
            throw new InvalidOperationException("Provider returned an empty subagent response.");
        }

        return new JsonObject
        {
            ["description"] = request.Description,
            ["prompt"] = request.Prompt,
            ["result"] = answer,
        }.ToJsonString(new JsonSerializerOptions { WriteIndented = true });
    }
}
