using System.Net.Http.Headers;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;

namespace G9Claw.Windows.Core;

public sealed class ProviderClientException : Exception
{
    public int? StatusCode { get; }
    public bool PartialVisibleOutput { get; }

    private ProviderClientException(string message, int? statusCode = null, bool partialVisibleOutput = false, Exception? innerException = null)
        : base(message, innerException)
    {
        StatusCode = statusCode;
        PartialVisibleOutput = partialVisibleOutput;
    }

    public static ProviderClientException MissingBaseUrl() => new("Provider base URL is not configured.");
    public static ProviderClientException MissingModel() => new("Provider model is not configured.");
    public static ProviderClientException MissingApiKey() => new("Provider API key is not configured. Add it in Settings or ~/.g9claw/config.yaml.");
    public static ProviderClientException InvalidUrl(string value) => new($"Provider base URL is invalid: {value}");
    public static ProviderClientException HttpError(int statusCode, string body) => new(
        string.IsNullOrWhiteSpace(body) ? $"Provider request failed with HTTP {statusCode}." : $"Provider request failed with HTTP {statusCode}: {body}",
        statusCode);
    public static ProviderClientException UnsupportedProvider(SessionProvider provider) => new($"{provider.DisplayName()} is not implemented yet in native AgentCore.");
    public static ProviderClientException InvalidResponse() => new("Provider returned an invalid response.");
    public static ProviderClientException Transport(string message, Exception? innerException = null) => new(message, innerException: innerException);
    public static ProviderClientException StreamInterruptedAfterPartialOutput(string message) => new(
        $"Provider response stream disconnected after partial output: {message}",
        partialVisibleOutput: true);
}

public sealed record ProviderRetryPolicy(
    int RequestMaxRetries,
    int StreamMaxRetries,
    int BaseDelayMs,
    bool Retry429,
    bool Retry5xx,
    bool RetryTransport)
{
    public static ProviderRetryPolicy CodexDefault { get; } = new(
        RequestMaxRetries: 4,
        StreamMaxRetries: 5,
        BaseDelayMs: 200,
        Retry429: false,
        Retry5xx: true,
        RetryTransport: true);
}

public sealed record ProviderRetryDecision(bool ShouldRetry, TimeSpan Delay, string Reason)
{
    public static ProviderRetryDecision NoRetry { get; } = new(false, TimeSpan.Zero, "");
}

public enum ProviderStreamEventKind
{
    ContentDelta,
    ToolCall,
    TokenBudget,
    Done,
}

public sealed record ProviderStreamEvent(
    ProviderStreamEventKind Kind,
    string? Text = null,
    AgentToolCall? ToolCall = null,
    TokenBudget? TokenBudget = null);

public static partial class NativeAgentRuntime
{
    public static Uri EndpointUrl(string baseUrl, string suffix)
    {
        if (string.IsNullOrWhiteSpace(baseUrl)) throw ProviderClientException.MissingBaseUrl();
        if (!Uri.TryCreate(baseUrl.Trim(), UriKind.Absolute, out var baseUri))
        {
            throw ProviderClientException.InvalidUrl(baseUrl);
        }

        var trimmedSuffix = suffix.Trim('/');
        var path = baseUri.AbsolutePath.Trim('/');
        if (path.EndsWith(trimmedSuffix, StringComparison.OrdinalIgnoreCase))
        {
            return baseUri;
        }

        var normalizedBase = baseUri.ToString().TrimEnd('/');
        return new Uri($"{normalizedBase}/{trimmedSuffix}");
    }

    public static IReadOnlyList<ProviderStreamEvent> OpenAIChatEvents(JsonElement root, int contextWindow)
    {
        var events = new List<ProviderStreamEvent>();
        if (root.TryGetProperty("choices", out var choices) &&
            choices.ValueKind == JsonValueKind.Array &&
            choices.GetArrayLength() > 0)
        {
            var choice = choices[0];
            if (choice.TryGetProperty("delta", out var delta))
            {
                if (delta.TryGetProperty("content", out var content) &&
                    content.ValueKind == JsonValueKind.String &&
                    !string.IsNullOrEmpty(content.GetString()))
                {
                    events.Add(new ProviderStreamEvent(ProviderStreamEventKind.ContentDelta, Text: content.GetString()));
                }

                if (delta.TryGetProperty("tool_calls", out var toolCalls) && toolCalls.ValueKind == JsonValueKind.Array)
                {
                    foreach (var toolCall in toolCalls.EnumerateArray())
                    {
                        var call = OpenAIToolCallFromDelta(toolCall);
                        if (call is not null) events.Add(new ProviderStreamEvent(ProviderStreamEventKind.ToolCall, ToolCall: call));
                    }
                }
            }
            else if (choice.TryGetProperty("message", out var message))
            {
                if (message.TryGetProperty("content", out var content) &&
                    content.ValueKind == JsonValueKind.String &&
                    !string.IsNullOrEmpty(content.GetString()))
                {
                    events.Add(new ProviderStreamEvent(ProviderStreamEventKind.ContentDelta, Text: content.GetString()));
                }

                if (message.TryGetProperty("tool_calls", out var toolCalls) && toolCalls.ValueKind == JsonValueKind.Array)
                {
                    foreach (var toolCall in toolCalls.EnumerateArray())
                    {
                        var call = OpenAIToolCallFromDelta(toolCall);
                        if (call is not null) events.Add(new ProviderStreamEvent(ProviderStreamEventKind.ToolCall, ToolCall: call));
                    }
                }
            }
        }

        if (TryTokenBudget(root, contextWindow) is { } budget)
        {
            events.Add(new ProviderStreamEvent(ProviderStreamEventKind.TokenBudget, TokenBudget: budget));
        }

        return events;
    }

    public static IReadOnlyList<ProviderStreamEvent> OpenAIResponsesEvents(JsonElement root, int contextWindow)
    {
        var events = new List<ProviderStreamEvent>();
        var type = root.TryGetProperty("type", out var typeElement) ? typeElement.GetString() : null;
        switch (type)
        {
            case "response.output_text.delta":
                if (root.TryGetProperty("delta", out var delta) && delta.ValueKind == JsonValueKind.String)
                {
                    events.Add(new ProviderStreamEvent(ProviderStreamEventKind.ContentDelta, Text: delta.GetString()));
                }
                break;
            case "response.output_item.done":
                if (root.TryGetProperty("item", out var item) && item.TryGetProperty("type", out var itemType) &&
                    itemType.GetString() == "function_call")
                {
                    var name = item.TryGetProperty("name", out var nameElement) ? nameElement.GetString() ?? "" : "";
                    var callId = item.TryGetProperty("call_id", out var callIdElement) ? callIdElement.GetString() ?? "" : "";
                    var arguments = item.TryGetProperty("arguments", out var argumentsElement) ? argumentsElement.ToString() : "{}";
                    if (!string.IsNullOrWhiteSpace(name))
                    {
                        events.Add(new ProviderStreamEvent(
                            ProviderStreamEventKind.ToolCall,
                            ToolCall: new AgentToolCall(string.IsNullOrWhiteSpace(callId) ? $"call-{Guid.NewGuid():D}" : callId, name, string.IsNullOrWhiteSpace(arguments) ? "{}" : arguments)));
                    }
                }
                break;
            case "response.completed":
                if (TryTokenBudget(root, contextWindow) is { } budget)
                {
                    events.Add(new ProviderStreamEvent(ProviderStreamEventKind.TokenBudget, TokenBudget: budget));
                }
                events.Add(new ProviderStreamEvent(ProviderStreamEventKind.Done));
                break;
        }

        return events;
    }

    public static IReadOnlyList<ProviderStreamEvent> AnthropicMessagesEvents(JsonElement root, int contextWindow)
    {
        var events = new List<ProviderStreamEvent>();
        var type = root.TryGetProperty("type", out var typeElement) ? typeElement.GetString() : null;
        if (type == "content_block_delta" &&
            root.TryGetProperty("delta", out var delta) &&
            delta.TryGetProperty("text", out var text) &&
            text.ValueKind == JsonValueKind.String)
        {
            events.Add(new ProviderStreamEvent(ProviderStreamEventKind.ContentDelta, Text: text.GetString()));
        }
        else if (type == "message_delta" && TryTokenBudget(root, contextWindow) is { } budget)
        {
            events.Add(new ProviderStreamEvent(ProviderStreamEventKind.TokenBudget, TokenBudget: budget));
        }
        else if (type == "message_stop")
        {
            events.Add(new ProviderStreamEvent(ProviderStreamEventKind.Done));
        }

        return events;
    }

    public static ProviderRetryDecision RetryDecision(Exception error, int failedAttempts, ProviderRetryPolicy? policy = null)
    {
        policy ??= ProviderRetryPolicy.CodexDefault;
        if (error is ProviderClientException { PartialVisibleOutput: true })
        {
            return ProviderRetryDecision.NoRetry;
        }

        if (failedAttempts >= policy.StreamMaxRetries)
        {
            return ProviderRetryDecision.NoRetry;
        }

        if (error is ProviderClientException { StatusCode: int statusCode })
        {
            var retry = (statusCode == 429 && policy.Retry429) || (statusCode >= 500 && policy.Retry5xx);
            return retry
                ? new ProviderRetryDecision(true, RetryBackoffDelay(failedAttempts, policy.BaseDelayMs), $"HTTP {statusCode}")
                : ProviderRetryDecision.NoRetry;
        }

        if (policy.RetryTransport && error is HttpRequestException or TaskCanceledException or IOException)
        {
            return new ProviderRetryDecision(true, RetryBackoffDelay(failedAttempts, policy.BaseDelayMs), "transport");
        }

        if (policy.RetryTransport && error is ProviderClientException transport &&
            transport.Message.Contains("timed out", StringComparison.OrdinalIgnoreCase))
        {
            return new ProviderRetryDecision(true, RetryBackoffDelay(failedAttempts, policy.BaseDelayMs), "transport");
        }

        return ProviderRetryDecision.NoRetry;
    }

    public static TimeSpan RetryBackoffDelay(int failedAttempts, int baseDelayMs = 200)
    {
        var multiplier = Math.Pow(2, Math.Max(0, failedAttempts));
        return TimeSpan.FromMilliseconds(baseDelayMs * multiplier);
    }

    private static AgentToolCall? OpenAIToolCallFromDelta(JsonElement toolCall)
    {
        if (!toolCall.TryGetProperty("function", out var function)) return null;
        var name = function.TryGetProperty("name", out var nameElement) ? nameElement.GetString() : null;
        if (string.IsNullOrWhiteSpace(name)) return null;
        var id = toolCall.TryGetProperty("id", out var idElement) ? idElement.GetString() : null;
        var arguments = function.TryGetProperty("arguments", out var argumentsElement) ? argumentsElement.GetString() : "{}";
        return new AgentToolCall(string.IsNullOrWhiteSpace(id) ? $"call-{Guid.NewGuid():D}" : id!, name!, string.IsNullOrWhiteSpace(arguments) ? "{}" : arguments!);
    }

    private static TokenBudget? TryTokenBudget(JsonElement root, int contextWindow)
    {
        if (!root.TryGetProperty("usage", out var usage) || usage.ValueKind != JsonValueKind.Object) return null;

        var inputTokens = IntProperty(usage, "input_tokens");
        var outputTokens = IntProperty(usage, "output_tokens");
        var total = IntProperty(usage, "total_tokens") ??
                    AddNullable(inputTokens, outputTokens) ??
                    inputTokens ??
                    outputTokens;
        return total is int used ? new TokenBudget(used, contextWindow) : null;
    }

    private static int? AddNullable(int? left, int? right) =>
        left is int leftValue && right is int rightValue ? leftValue + rightValue : null;

    private static int? IntProperty(JsonElement root, string name)
    {
        if (!root.TryGetProperty(name, out var value)) return null;
        return value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var result) ? result : null;
    }
}

public sealed class OpenAIChatToolCallAccumulator
{
    private readonly Dictionary<int, ToolCallBuilder> _builders = [];

    public IReadOnlyList<ProviderStreamEvent> Apply(JsonElement root)
    {
        var events = new List<ProviderStreamEvent>();
        if (!root.TryGetProperty("choices", out var choices) ||
            choices.ValueKind != JsonValueKind.Array ||
            choices.GetArrayLength() == 0)
        {
            return events;
        }

        var choice = choices[0];
        if (choice.TryGetProperty("delta", out var delta) &&
            delta.TryGetProperty("tool_calls", out var toolCalls) &&
            toolCalls.ValueKind == JsonValueKind.Array)
        {
            foreach (var toolCall in toolCalls.EnumerateArray())
            {
                var index = toolCall.TryGetProperty("index", out var indexElement) && indexElement.TryGetInt32(out var parsedIndex)
                    ? parsedIndex
                    : _builders.Count;
                if (!_builders.TryGetValue(index, out var builder))
                {
                    builder = new ToolCallBuilder();
                    _builders[index] = builder;
                }

                if (toolCall.TryGetProperty("id", out var idElement) && idElement.ValueKind == JsonValueKind.String)
                {
                    builder.Id = idElement.GetString();
                }

                if (toolCall.TryGetProperty("function", out var function))
                {
                    if (function.TryGetProperty("name", out var nameElement) && nameElement.ValueKind == JsonValueKind.String)
                    {
                        builder.Name = nameElement.GetString();
                    }

                    if (function.TryGetProperty("arguments", out var argumentsElement) && argumentsElement.ValueKind == JsonValueKind.String)
                    {
                        builder.Arguments.Append(argumentsElement.GetString());
                    }
                }
            }
        }

        var finishReason = choice.TryGetProperty("finish_reason", out var finishElement) && finishElement.ValueKind == JsonValueKind.String
            ? finishElement.GetString()
            : null;
        if (string.Equals(finishReason, "tool_calls", StringComparison.OrdinalIgnoreCase))
        {
            events.AddRange(Flush());
        }

        return events;
    }

    public IReadOnlyList<ProviderStreamEvent> Flush()
    {
        if (_builders.Count == 0) return [];
        var events = _builders
            .OrderBy(pair => pair.Key)
            .Select(pair => pair.Value.ToCall())
            .Where(call => call is not null)
            .Select(call => new ProviderStreamEvent(ProviderStreamEventKind.ToolCall, ToolCall: call))
            .ToList();
        _builders.Clear();
        return events;
    }

    private sealed class ToolCallBuilder
    {
        public string? Id { get; set; }
        public string? Name { get; set; }
        public StringBuilder Arguments { get; } = new();

        public AgentToolCall? ToCall()
        {
            if (string.IsNullOrWhiteSpace(Name)) return null;
            var id = string.IsNullOrWhiteSpace(Id) ? $"call-{Guid.NewGuid():D}" : Id.Trim();
            var args = Arguments.Length == 0 ? "{}" : Arguments.ToString();
            return new AgentToolCall(id, Name.Trim(), string.IsNullOrWhiteSpace(args) ? "{}" : args);
        }
    }
}

public interface IProviderClient
{
    IAsyncEnumerable<ProviderStreamEvent> StreamAsync(
        AgentRequest request,
        CancellationToken cancellationToken = default);
}

public sealed class ProviderClient : IProviderClient
{
    private readonly HttpClient _httpClient;

    public ProviderClient(HttpClient? httpClient = null)
    {
        _httpClient = httpClient ?? new HttpClient();
    }

    public async IAsyncEnumerable<ProviderStreamEvent> StreamAsync(
        AgentRequest request,
        [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        ValidateRequest(request);
        var chatToolAccumulator = request.ProviderConfig.ApiType == ProviderApiType.OpenAIChat
            ? new OpenAIChatToolCallAccumulator()
            : null;
        using var httpRequest = BuildRequest(request);
        using var response = await _httpClient.SendAsync(httpRequest, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            var body = await response.Content.ReadAsStringAsync(cancellationToken);
            throw ProviderClientException.HttpError((int)response.StatusCode, body);
        }

        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
        using var reader = new StreamReader(stream, Encoding.UTF8);
        var sawVisibleOutput = false;
        var nonSseBody = new StringBuilder();
        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var line = await reader.ReadLineAsync(cancellationToken);
            if (line is null) break;
            if (!line.StartsWith("data:", StringComparison.OrdinalIgnoreCase))
            {
                if (!string.IsNullOrWhiteSpace(line))
                {
                    nonSseBody.AppendLine(line);
                }

                continue;
            }

            var data = line["data:".Length..].Trim();
            if (data == "[DONE]")
            {
                if (chatToolAccumulator is not null)
                {
                    foreach (var pendingToolCall in chatToolAccumulator.Flush())
                    {
                        yield return pendingToolCall;
                    }
                }

                yield return new ProviderStreamEvent(ProviderStreamEventKind.Done);
                yield break;
            }

            IReadOnlyList<ProviderStreamEvent> events;
            try
            {
                using var doc = JsonDocument.Parse(data);
                events = request.ProviderConfig.ApiType switch
                {
                    ProviderApiType.OpenAIChat => NativeAgentRuntime.OpenAIChatEvents(doc.RootElement, request.ContextWindow)
                        .Where(item => item.Kind != ProviderStreamEventKind.ToolCall)
                        .Concat(chatToolAccumulator?.Apply(doc.RootElement) ?? [])
                        .ToList(),
                    ProviderApiType.OpenAIResponses => NativeAgentRuntime.OpenAIResponsesEvents(doc.RootElement, request.ContextWindow),
                    ProviderApiType.AnthropicMessages => NativeAgentRuntime.AnthropicMessagesEvents(doc.RootElement, request.ContextWindow),
                    _ => [],
                };
            }
            catch (JsonException)
            {
                continue;
            }

            foreach (var providerEvent in events)
            {
                sawVisibleOutput |= providerEvent.Kind is ProviderStreamEventKind.ContentDelta or ProviderStreamEventKind.ToolCall;
                yield return providerEvent;
            }
        }

        if (!sawVisibleOutput && nonSseBody.Length > 0)
        {
            foreach (var providerEvent in ParseNonSseResponse(nonSseBody.ToString(), request))
            {
                sawVisibleOutput |= providerEvent.Kind is ProviderStreamEventKind.ContentDelta or ProviderStreamEventKind.ToolCall;
                yield return providerEvent;
            }

            if (sawVisibleOutput)
            {
                yield return new ProviderStreamEvent(ProviderStreamEventKind.Done);
                yield break;
            }
        }

        if (sawVisibleOutput)
        {
            throw ProviderClientException.StreamInterruptedAfterPartialOutput("Provider stream ended without a done marker.");
        }
    }

    private static IReadOnlyList<ProviderStreamEvent> ParseNonSseResponse(string body, AgentRequest request)
    {
        try
        {
            using var doc = JsonDocument.Parse(body);
            return request.ProviderConfig.ApiType switch
            {
                ProviderApiType.OpenAIChat => NativeAgentRuntime.OpenAIChatEvents(doc.RootElement, request.ContextWindow),
                ProviderApiType.OpenAIResponses => NativeAgentRuntime.OpenAIResponsesEvents(doc.RootElement, request.ContextWindow),
                ProviderApiType.AnthropicMessages => NativeAgentRuntime.AnthropicMessagesEvents(doc.RootElement, request.ContextWindow),
                _ => [],
            };
        }
        catch (JsonException)
        {
            return [];
        }
    }

    private static void ValidateRequest(AgentRequest request)
    {
        if (request.ProviderConfig.Provider != SessionProvider.G9Claw) throw ProviderClientException.UnsupportedProvider(request.ProviderConfig.Provider);
        if (string.IsNullOrWhiteSpace(request.ProviderConfig.BaseUrl)) throw ProviderClientException.MissingBaseUrl();
        if (string.IsNullOrWhiteSpace(request.ProviderConfig.Model)) throw ProviderClientException.MissingModel();
        if (string.IsNullOrWhiteSpace(request.ApiKey)) throw ProviderClientException.MissingApiKey();
    }

    private static HttpRequestMessage BuildRequest(AgentRequest request)
    {
        var suffix = request.ProviderConfig.ApiType switch
        {
            ProviderApiType.OpenAIChat => "chat/completions",
            ProviderApiType.OpenAIResponses => "responses",
            ProviderApiType.AnthropicMessages => "messages",
            _ => "chat/completions",
        };
        var httpRequest = new HttpRequestMessage(HttpMethod.Post, NativeAgentRuntime.EndpointUrl(request.ProviderConfig.BaseUrl, suffix));
        httpRequest.Headers.Authorization = new AuthenticationHeaderValue("Bearer", request.ApiKey);
        foreach (var header in request.ProviderConfig.Headers)
        {
            httpRequest.Headers.TryAddWithoutValidation(header.Key, header.Value);
        }

        if (request.ProviderConfig.ApiType == ProviderApiType.AnthropicMessages)
        {
            httpRequest.Headers.TryAddWithoutValidation("anthropic-version", "2023-06-01");
        }

        var body = request.ProviderConfig.ApiType switch
        {
            ProviderApiType.OpenAIResponses => BuildOpenAIResponsesBody(request),
            ProviderApiType.AnthropicMessages => BuildAnthropicBody(request),
            _ => BuildOpenAIChatBody(request),
        };
        httpRequest.Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json");
        return httpRequest;
    }

    private static Dictionary<string, object?> BuildOpenAIChatBody(AgentRequest request)
    {
        var body = new Dictionary<string, object?>
        {
            ["model"] = request.ProviderConfig.Model,
            ["stream"] = request.Stream,
            ["messages"] = BuildOpenAIMessages(request),
        };
        if (request.Stream)
        {
            body["stream_options"] = new Dictionary<string, object?> { ["include_usage"] = true };
        }

        if (request.EnableTools)
        {
            body["tools"] = AgentToolRegistry.OpenAITools();
            body["tool_choice"] = "auto";
        }

        return body;
    }

    private static Dictionary<string, object?> BuildOpenAIResponsesBody(AgentRequest request)
    {
        var body = new Dictionary<string, object?>
        {
            ["model"] = request.ProviderConfig.Model,
            ["stream"] = request.Stream,
            ["input"] = PromptWithAttachmentSummary(request),
        };
        if (request.EnableTools)
        {
            body["tools"] = AgentToolRegistry.OpenAITools().Select(tool => tool["function"]).ToList();
        }

        return body;
    }

    private static Dictionary<string, object?> BuildAnthropicBody(AgentRequest request) => new()
    {
        ["model"] = request.ProviderConfig.Model,
        ["stream"] = request.Stream,
        ["max_tokens"] = 4096,
        ["messages"] = new[] { new Dictionary<string, object?> { ["role"] = "user", ["content"] = PromptWithAttachmentSummary(request) } },
    };

    private static List<Dictionary<string, object?>> BuildOpenAIMessages(AgentRequest request)
    {
        var messages = request.PriorMessages
            .Where(message => message.Role is ChatRole.User or ChatRole.Assistant or ChatRole.System)
            .Select(message => new Dictionary<string, object?>
            {
                ["role"] = message.Role.ToString().ToLowerInvariant(),
                ["content"] = message.PlainText,
            })
            .ToList();
        messages.Add(new Dictionary<string, object?> { ["role"] = "user", ["content"] = BuildOpenAIUserContent(request) });
        foreach (var exchange in request.ToolExchanges)
        {
            messages.Add(new Dictionary<string, object?>
            {
                ["role"] = "assistant",
                ["content"] = "",
                ["tool_calls"] = new object[]
                {
                    new Dictionary<string, object?>
                    {
                        ["id"] = exchange.Call.Id,
                        ["type"] = "function",
                        ["function"] = new Dictionary<string, object?>
                        {
                            ["name"] = exchange.Call.Name,
                            ["arguments"] = exchange.Call.InputJson,
                        },
                    },
                },
            });
            messages.Add(new Dictionary<string, object?>
            {
                ["role"] = "tool",
                ["tool_call_id"] = exchange.Call.Id,
                ["content"] = exchange.Result.Output,
            });
        }

        return messages;
    }

    private static object BuildOpenAIUserContent(AgentRequest request)
    {
        if (request.Attachments.Count == 0)
        {
            return request.Prompt;
        }

        var attachmentParts = NativeAttachmentResolver.OpenAIContentParts(request.Attachments).Parts;
        if (attachmentParts.Count == 0)
        {
            return request.Prompt;
        }

        var parts = new List<Dictionary<string, object?>>();
        if (!string.IsNullOrWhiteSpace(request.Prompt))
        {
            parts.Add(new Dictionary<string, object?>
            {
                ["type"] = "text",
                ["text"] = request.Prompt,
            });
        }

        parts.AddRange(attachmentParts);
        return parts;
    }

    private static string PromptWithAttachmentSummary(AgentRequest request)
    {
        return NativeAttachmentResolver.PromptWithAttachments(request.Prompt, request.Attachments);
    }
}
