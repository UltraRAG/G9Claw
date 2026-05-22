using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace G9Claw.Windows.Core;

public static class AgentToolNameCanonicalizer
{
    public static string Canonical(string rawName)
    {
        var trimmed = rawName.Trim();
        var lower = trimmed.ToLowerInvariant();
        if (lower.StartsWith("g9claw-rag:", StringComparison.Ordinal)) return trimmed;

        return lower switch
        {
            "read" => "Read",
            "write" => "Write",
            "strreplace" or "str_replace" or "str-replace" or "edit" or "multiedit" or "multi_edit" or "multi-edit" => "StrReplace",
            "delete" or "remove" or "unlink" => "Delete",
            "editnotebook" or "edit_notebook" or "edit-notebook" or "notebookedit" or "notebook_edit" or "notebook-edit" => "EditNotebook",
            "glob" => "Glob",
            "grep" => "Grep",
            "semanticsearch" or "semantic_search" or "semantic-search" => "SemanticSearch",
            "bash" or "shell" or "run_command" or "runcommand" => "Shell",
            "await" or "taskoutput" or "task_output" or "task-output" or "agentoutputtool" or "bashoutputtool" => "Await",
            "websearch" or "web_search" or "web-search" => "WebSearch",
            "webfetch" or "web_fetch" or "web-fetch" => "WebFetch",
            "weather" or "getweather" or "get_weather" or "get-weather" => "Weather",
            "readlints" or "read_lints" or "read-lints" or "lints" or "lint" => "ReadLints",
            "skill" or "loadskill" or "load_skill" => "Skill",
            "task" or "taskcreate" or "task_create" or "task-create" or "agent" or "subagent" or "sub_agent" or "sub-agent" => "Task",
            "todoread" or "todo_read" or "todo-read" => "TodoRead",
            "todowrite" or "todo_write" or "todo-write" => "TodoWrite",
            "switchmode" or "switch_mode" or "switch-mode" or "exitplanmode" or "exit_plan_mode" or "exit-plan-mode" or "exitplanmodev2" => "SwitchMode",
            "askquestion" or "ask_question" or "ask-question" or "askuserquestion" or "ask_user_question" or "ask-user-question" => "AskQuestion",
            _ => trimmed,
        };
    }
}

public sealed record ToolSchema(
    string Name,
    string Description,
    IReadOnlyDictionary<string, object?> Properties,
    IReadOnlyList<string> Required);

public static class AgentToolRegistry
{
    public static readonly string[] ToolNames =
    [
        "Read",
        "Write",
        "StrReplace",
        "Delete",
        "EditNotebook",
        "Grep",
        "Glob",
        "SemanticSearch",
        "Shell",
        "Await",
        "ReadLints",
        "Skill",
        "TodoWrite",
        "AskQuestion",
        "SwitchMode",
        "Task",
    ];

    public static IReadOnlyList<ToolSchema> Schemas { get; } =
    [
        Tool("Read", "Read text, image, PDF, or Jupyter notebook content from the workspace.",
            Props(("file_path", Str("Workspace-relative or absolute file path.")), ("offset", Int("Optional 1-based line offset.")), ("limit", Int("Optional maximum number of lines to return.")), ("pages", Str("Optional PDF page range such as 1-3."))), ["file_path"]),
        Tool("Write", "Create or overwrite a UTF-8 file in the workspace.",
            Props(("file_path", Str("Workspace-relative or absolute file path.")), ("content", Str("Complete file contents to write."))), ["file_path", "content"]),
        Tool("StrReplace", "Replace exact strings in a workspace file. Supports one replacement or an edits array.",
            Props(("file_path", Str("Workspace-relative or absolute file path.")), ("old_string", Str("Exact text to replace.")), ("new_string", Str("Replacement text.")), ("replace_all", Bool("Replace every match instead of requiring one unique match."))), ["file_path"]),
        Tool("Delete", "Delete a file or, with recursive=true, a directory inside the workspace.",
            Props(("path", Str("Workspace-relative or absolute file or directory path.")), ("recursive", Bool("Allow deleting directories recursively."))), ["path"]),
        Tool("EditNotebook", "Replace, insert, or delete a cell in a Jupyter notebook file.",
            Props(("notebook_path", Str("Workspace-relative or absolute .ipynb path.")), ("cell_id", Str("Optional notebook cell id.")), ("cell_number", Int("Optional 0-based cell index.")), ("new_source", Str("New source for replace or insert.")), ("cell_type", Enum(["code", "markdown"], "Cell type for inserted cells.")), ("edit_mode", Enum(["replace", "insert", "delete"], "Notebook edit mode. Defaults to replace."))), ["notebook_path"]),
        Tool("Grep", "Search text files by regular expression under the workspace.",
            Props(("pattern", Str("Regular expression to search for.")), ("path", Str("Optional directory or file to search.")), ("glob", Str("Optional glob filter.")), ("include", Str("Legacy alias for glob.")), ("output_mode", Enum(["content", "files_with_matches", "count"], "Result mode.")), ("head_limit", Int("Maximum returned lines or entries.")), ("-i", Bool("Case-insensitive search."))), ["pattern"]),
        Tool("Glob", "Find files by glob pattern under the workspace.",
            Props(("pattern", Str("Glob such as **/*.cs or *.md.")), ("path", Str("Optional directory to search."))), ["pattern"]),
        Tool("SemanticSearch", "Search code by meaning using a deterministic local workspace index.",
            Props(("query", Str("Natural-language or code concept query.")), ("path", Str("Optional directory or file to search.")), ("limit", Int("Maximum number of ranked results."))), ["query"]),
        Tool("Shell", "Run a PowerShell command in the workspace.",
            Props(("command", Str("Command to run with PowerShell.")), ("description", Str("Short reason for running the command.")), ("timeout", Int("Optional timeout in milliseconds.")), ("run_in_background", Bool("Start the command in the background and return a task id."))), ["command"]),
        Tool("Await", "Wait for or read output from a background Shell or Task.",
            Props(("task_id", Str("Background task id.")), ("block", Bool("Whether to block until completion. Defaults to true.")), ("timeout", Int("Maximum wait time in milliseconds."))), ["task_id"]),
        Tool("ReadLints", "Read current workspace linter or diagnostic findings when available.",
            Props(("path", Str("Optional file or directory to scope diagnostics.")), ("severity", Str("Optional severity filter such as error or warning.")), ("limit", Int("Maximum number of diagnostics."))), []),
        Tool("Skill", "Load a G9Claw skill. Use g9claw-rag:glm-web-search for public web search and weather, or g9claw-rag:rag-research for source-grounded research.",
            Props(("skill", Str("Skill name, for example g9claw-rag:glm-web-search.")), ("args", Str("User query or task arguments for the skill."))), ["skill"]),
        Tool("TodoWrite", "Replace the current session todo list.",
            Props(("todos", new Dictionary<string, object?> { ["type"] = "array", ["items"] = new Dictionary<string, object?> { ["type"] = "object", ["additionalProperties"] = true } })), ["todos"]),
        Tool("AskQuestion", "Ask the user one or more short blocking questions.",
            Props(("questions", new Dictionary<string, object?> { ["type"] = "array", ["minItems"] = 1 }), ("question", Str("Legacy single question fallback.")), ("options", new Dictionary<string, object?> { ["type"] = "array", ["items"] = Str("Legacy option label.") })), []),
        Tool("SwitchMode", "Switch between plan and agent mode. Use mode=agent with a concrete plan to execute after planning.",
            Props(("mode", Enum(["plan", "agent"], "Target run mode.")), ("plan", Str("The plan to execute when switching to agent mode."))), ["mode"]),
        Tool("Task", "Start a delegated task or subagent.",
            Props(("type", Enum(["generalPurpose", "explore", "shell", "cursor-guide", "ci-investigator", "best-of-n-runner"], "Task type.")), ("prompt", Str("Concrete task prompt or shell command for type=shell.")), ("description", Str("Optional short label.")), ("model", Str("Optional model hint.")), ("run_in_background", Bool("Run task asynchronously and return a task id.")), ("cwd", Str("Optional workspace-relative or absolute cwd."))), ["prompt"]),
    ];

    public static IReadOnlyList<Dictionary<string, object?>> OpenAITools()
    {
        return Schemas.Select(schema => new Dictionary<string, object?>
        {
            ["type"] = "function",
            ["function"] = new Dictionary<string, object?>
            {
                ["name"] = schema.Name,
                ["description"] = schema.Description,
                ["parameters"] = new Dictionary<string, object?>
                {
                    ["type"] = "object",
                    ["properties"] = schema.Properties,
                    ["required"] = schema.Required,
                    ["additionalProperties"] = false,
                },
            },
        }).ToList();
    }

    private static ToolSchema Tool(string name, string description, IReadOnlyDictionary<string, object?> properties, IReadOnlyList<string> required) =>
        new(name, description, properties, required);

    private static Dictionary<string, object?> Props(params (string Name, object? Value)[] values) =>
        values.ToDictionary(value => value.Name, value => value.Value);

    private static Dictionary<string, object?> Str(string description) => new() { ["type"] = "string", ["description"] = description };
    private static Dictionary<string, object?> Int(string description) => new() { ["type"] = "integer", ["description"] = description };
    private static Dictionary<string, object?> Bool(string description) => new() { ["type"] = "boolean", ["description"] = description };
    private static Dictionary<string, object?> Enum(string[] values, string description) => new() { ["type"] = "string", ["enum"] = values, ["description"] = description };
}

public sealed record NormalizationError(string Message);
public sealed record NormalizedInvocation(AgentToolCall Call, AgentToolResult? RecoveryResult);

public static class ToolArgumentNormalizer
{
    internal static readonly JsonSerializerOptions JsonWriteOptions = new()
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public const string InvalidJsonRecoveryMessage =
        "Tool input was invalid JSON. Retry with a JSON object using double-quoted keys and strings.";

    public static IReadOnlyList<NormalizedInvocation> Normalize(IEnumerable<AgentToolCall> calls) =>
        calls.Select(Normalize).ToList();

    public static NormalizedInvocation Normalize(AgentToolCall call)
    {
        var canonicalName = AgentToolNameCanonicalizer.Canonical(call.Name);
        var canonicalJson = CanonicalObjectJson(call.InputJson);
        if (!canonicalJson.Success)
        {
            var safeCall = new AgentToolCall(call.Id, canonicalName, "{}");
            var output = $"{InvalidJsonRecoveryMessage}\n\nTool: {canonicalName}\nError: {canonicalJson.Error!.Message}";
            return new NormalizedInvocation(
                safeCall,
                new AgentToolResult(call.Id, canonicalName, output, true));
        }

        if (CanonicalizedLegacySearchInvocation(call.Id, canonicalName, canonicalJson.Json!) is { } legacy)
        {
            return legacy;
        }

        var canonicalInput = CanonicalToolInputJson(canonicalName, canonicalJson.Json!);
        return new NormalizedInvocation(new AgentToolCall(call.Id, canonicalName, canonicalInput), null);
    }

    public static string ProviderSafeInputJson(string inputJson) =>
        CanonicalObjectJson(inputJson).Json ?? "{}";

    public static (bool Success, string? Json, NormalizationError? Error) CanonicalObjectJson(string inputJson)
    {
        var value = string.IsNullOrWhiteSpace(inputJson) ? "{}" : inputJson.Trim();
        try
        {
            using var doc = JsonDocument.Parse(value);
            if (doc.RootElement.ValueKind != JsonValueKind.Object)
            {
                return (false, null, new NormalizationError("Tool arguments must be a JSON object."));
            }

            return (true, JsonCanonicalizer.ToCanonicalJson(doc.RootElement), null);
        }
        catch (JsonException ex)
        {
            return (false, null, new NormalizationError(ex.Message));
        }
    }

    private static NormalizedInvocation? CanonicalizedLegacySearchInvocation(string callId, string toolName, string inputJson)
    {
        if (toolName is not ("WebSearch" or "Weather")) return null;

        using var doc = JsonDocument.Parse(inputJson);
        var root = doc.RootElement;
        var rawQuery = FirstStringValue(root, ["query", "q", "search_query", "location", "city", "place"]);
        if (string.IsNullOrWhiteSpace(rawQuery))
        {
            return new NormalizedInvocation(
                new AgentToolCall(callId, "Skill", "{}"),
                new AgentToolResult(callId, "Skill", $"{toolName} is disabled. Use Skill with g9claw-rag:glm-web-search and provide a query.", true));
        }

        var args = rawQuery.Trim();
        if (toolName == "Weather" &&
            !args.Contains("weather", StringComparison.OrdinalIgnoreCase) &&
            !args.Contains("天气", StringComparison.Ordinal))
        {
            args = $"{args} weather";
        }

        var mapped = JsonSerializer.Serialize(new SortedDictionary<string, object?>
        {
            ["args"] = args,
            ["skill"] = "g9claw-rag:glm-web-search",
        }, JsonWriteOptions);
        return new NormalizedInvocation(new AgentToolCall(callId, "Skill", mapped), null);
    }

    private static string CanonicalToolInputJson(string toolName, string inputJson)
    {
        var node = JsonNode.Parse(inputJson) as JsonObject;
        if (node is null) return inputJson;

        switch (toolName)
        {
            case "Shell":
                CanonicalizeShellInput(node);
                break;
            case "Skill":
                CanonicalizeSkillInput(node);
                break;
            case "Task":
                CanonicalizeTaskInput(node);
                break;
            case "StrReplace":
                MoveProperty(node, "oldString", "old_string");
                MoveProperty(node, "newString", "new_string");
                break;
            case "Await":
                if (!node.ContainsKey("task_id"))
                {
                    node["task_id"] = CloneOrString(node["id"]) ?? CloneOrString(node["taskId"]);
                }
                node.Remove("id");
                node.Remove("taskId");
                break;
        }

        return JsonCanonicalizer.ToCanonicalJson(node);
    }

    private static void CanonicalizeShellInput(JsonObject node)
    {
        var command = FirstNonBlank(node, "command") ?? FirstNonBlank(node, "input") ?? FirstNonBlank(node, "input_command") ?? FirstNonBlank(node, "cmd");
        if (!string.IsNullOrWhiteSpace(command)) node["command"] = SanitizeXmlParameterWrapper(command);
        node.Remove("input");
        node.Remove("input_command");
        node.Remove("cmd");
        if (!node.ContainsKey("timeout") && node["timeout_seconds"] is not null)
        {
            node["timeout"] = CloneOrString(node["timeout_seconds"]);
        }
        node.Remove("timeout_seconds");
    }

    private static void CanonicalizeSkillInput(JsonObject node)
    {
        var skill = FirstNonBlank(node, "skill");
        var args = FirstNonBlank(node, "args");
        if (skill is not null) node["skill"] = SanitizeXmlParameterWrapper(skill);
        if (args is not null) node["args"] = SanitizeXmlParameterWrapper(args);
    }

    private static void CanonicalizeTaskInput(JsonObject node)
    {
        if (!node.ContainsKey("prompt"))
        {
            node["prompt"] = FirstNonBlank(node, "description") ?? FirstNonBlank(node, "subject") ??
                             FirstNonBlank(node, "command") ?? FirstNonBlank(node, "input") ?? "";
        }
        if (!node.ContainsKey("type") && node["subagent_type"] is not null)
        {
            node["type"] = CloneOrString(node["subagent_type"]);
        }
        node.Remove("subagent_type");
        node.Remove("input");
    }

    private static string? FirstStringValue(JsonElement root, IEnumerable<string> keys)
    {
        foreach (var key in keys)
        {
            if (!root.TryGetProperty(key, out var value)) continue;
            var text = value.ValueKind switch
            {
                JsonValueKind.String => value.GetString(),
                JsonValueKind.Number => value.GetRawText(),
                JsonValueKind.True => "true",
                JsonValueKind.False => "false",
                _ => value.ToString(),
            };
            if (!string.IsNullOrWhiteSpace(text)) return text;
        }

        return null;
    }

    private static string? FirstNonBlank(JsonObject node, params string[] keys)
    {
        foreach (var key in keys)
        {
            var jsonNode = node[key];
            if (jsonNode is null) continue;
            string value;
            try
            {
                value = jsonNode.GetValue<string>();
            }
            catch
            {
                value = jsonNode.ToJsonString();
            }
            if (!string.IsNullOrWhiteSpace(value)) return value;
        }

        return null;
    }

    private static JsonNode? CloneOrString(JsonNode? node) =>
        node is null ? null : JsonNode.Parse(node.ToJsonString());

    private static void MoveProperty(JsonObject node, string oldName, string newName)
    {
        if (!node.ContainsKey(newName) && node[oldName] is not null)
        {
            node[newName] = CloneOrString(node[oldName]);
        }
        node.Remove(oldName);
    }

    private static string SanitizeXmlParameterWrapper(string value)
    {
        var cleaned = value.Trim();
        cleaned = Regex.Replace(cleaned, @"(?is)^<parameter(?:\s+[^>]*)?>\s*", "");
        cleaned = Regex.Replace(cleaned, @"(?is)\s*</parameter>\s*$", "");
        return cleaned.Trim();
    }
}

public static partial class NativeAgentRuntime
{
    private static readonly Regex FencedJsonOnly = new(@"^\s*```(?:json)?\s*(?<json>\{[\s\S]*\})\s*```\s*$", RegexOptions.Compiled | RegexOptions.IgnoreCase);
    private static readonly Regex TrailingJsonObject = new(@"(?s)(?<json>\{.*\})\s*$", RegexOptions.Compiled);
    private static readonly Regex InvokeBlock = new(@"(?is)<invoke\s+name=""(?<name>[^""]+)"">\s*(?<body>.*?)\s*</invoke>", RegexOptions.Compiled);
    private static readonly Regex ParameterBlock = new(@"(?is)<parameter\s+name=""(?<name>[^""]+)"">\s*(?<value>.*?)\s*</parameter>", RegexOptions.Compiled);

    public static IReadOnlyList<AgentToolCall> FallbackToolCalls(string text)
    {
        if (string.IsNullOrWhiteSpace(text)) return [];
        var trimmed = text.Trim();

        if (Regex.Match(trimmed, @"(?is)^<command>.*</command>$").Success)
        {
            return [new AgentToolCall($"call-{Guid.NewGuid():D}", "Glob", """{"pattern":"*"}""")];
        }

        var invoke = InvokeBlock.Match(trimmed);
        if (invoke.Success)
        {
            var name = invoke.Groups["name"].Value.Trim();
            var args = new SortedDictionary<string, object?>(StringComparer.Ordinal);
            foreach (Match parameter in ParameterBlock.Matches(invoke.Groups["body"].Value))
            {
                args[parameter.Groups["name"].Value.Trim()] = parameter.Groups["value"].Value.Trim();
            }
            return [new AgentToolCall($"call-{Guid.NewGuid():D}", name, JsonSerializer.Serialize(args))];
        }

        string? jsonText = null;
        var fenced = FencedJsonOnly.Match(trimmed);
        if (fenced.Success)
        {
            jsonText = fenced.Groups["json"].Value;
        }
        else if (trimmed.StartsWith('{') && trimmed.EndsWith('}'))
        {
            jsonText = trimmed;
        }
        else
        {
            var trailing = TrailingJsonObject.Match(trimmed);
            if (trailing.Success && !trimmed[..trailing.Index].Contains("```", StringComparison.Ordinal))
            {
                jsonText = trailing.Groups["json"].Value;
            }
        }

        return jsonText is null ? [] : ToolCallsFromJson(jsonText);
    }

    private static IReadOnlyList<AgentToolCall> ToolCallsFromJson(string json)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.ValueKind != JsonValueKind.Object) return [];
            var root = doc.RootElement;

            if (root.TryGetProperty("skill", out var skill))
            {
                var args = root.TryGetProperty("args", out var argsElement) ? argsElement.ToString() : "";
                var payload = JsonSerializer.Serialize(new SortedDictionary<string, object?>
                {
                    ["args"] = args,
                    ["skill"] = skill.GetString() ?? "",
                }, ToolArgumentNormalizer.JsonWriteOptions);
                return [new AgentToolCall($"call-{Guid.NewGuid():D}", "Skill", payload)];
            }

            var toolName = root.TryGetProperty("tool", out var tool)
                ? tool.GetString()
                : root.TryGetProperty("name", out var name)
                    ? name.GetString()
                    : null;
            if (string.IsNullOrWhiteSpace(toolName)) return [];

            if (toolName.StartsWith("g9claw-rag:", StringComparison.OrdinalIgnoreCase))
            {
                var args = "";
                if (root.TryGetProperty("input", out var directInput) && directInput.ValueKind == JsonValueKind.Object)
                {
                    args = directInput.TryGetProperty("query", out var query) ? query.ToString() : directInput.ToString();
                }
                var payload = JsonSerializer.Serialize(new SortedDictionary<string, object?>
                {
                    ["args"] = args,
                    ["skill"] = toolName,
                }, ToolArgumentNormalizer.JsonWriteOptions);
                return [new AgentToolCall($"call-{Guid.NewGuid():D}", "Skill", payload)];
            }

            var inputJson = root.TryGetProperty("input", out var input)
                ? JsonCanonicalizer.ToCanonicalJson(input)
                : root.TryGetProperty("arguments", out var arguments)
                    ? JsonCanonicalizer.ToCanonicalJson(arguments)
                    : "{}";
            return [new AgentToolCall($"call-{Guid.NewGuid():D}", toolName, inputJson)];
        }
        catch (JsonException)
        {
            return [];
        }
    }
}

internal static class JsonCanonicalizer
{
    public static string ToCanonicalJson(JsonElement element)
    {
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
        {
            WriteElement(writer, element);
        }
        return Encoding.UTF8.GetString(stream.ToArray());
    }

    public static string ToCanonicalJson(JsonNode node)
    {
        using var doc = JsonDocument.Parse(node.ToJsonString());
        return ToCanonicalJson(doc.RootElement);
    }

    private static void WriteElement(Utf8JsonWriter writer, JsonElement element)
    {
        switch (element.ValueKind)
        {
            case JsonValueKind.Object:
                writer.WriteStartObject();
                foreach (var property in element.EnumerateObject().OrderBy(property => property.Name, StringComparer.Ordinal))
                {
                    writer.WritePropertyName(property.Name);
                    WriteElement(writer, property.Value);
                }
                writer.WriteEndObject();
                break;
            case JsonValueKind.Array:
                writer.WriteStartArray();
                foreach (var item in element.EnumerateArray())
                {
                    WriteElement(writer, item);
                }
                writer.WriteEndArray();
                break;
            case JsonValueKind.String:
                writer.WriteStringValue(element.GetString());
                break;
            case JsonValueKind.Number:
                element.WriteTo(writer);
                break;
            case JsonValueKind.True:
                writer.WriteBooleanValue(true);
                break;
            case JsonValueKind.False:
                writer.WriteBooleanValue(false);
                break;
            case JsonValueKind.Null:
            case JsonValueKind.Undefined:
                writer.WriteNullValue();
                break;
        }
    }
}
