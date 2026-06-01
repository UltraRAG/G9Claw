using System.Text.Json;
using System.Text.Json.Serialization;

namespace PilotDeck.Windows.Core;

public sealed record WorkspaceSessionSnapshot(
    List<WorkspaceProject> Projects,
    Guid? SelectedProjectId,
    string? SelectedSessionId,
    bool IsDraftSessionVisible);

public sealed class WorkspaceSessionStore
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true,
    };
    private static readonly JsonSerializerOptions JsonLineOptions = new(JsonSerializerDefaults.Web);

    static WorkspaceSessionStore()
    {
        JsonOptions.Converters.Add(new JsonStringEnumConverter());
        JsonLineOptions.Converters.Add(new JsonStringEnumConverter());
    }

    private readonly string _sessionsDirectory;
    private readonly string _projectsFile;
    private readonly string _routingStatsFile;

    public WorkspaceSessionStore(string? sessionsDirectory = null)
    {
        _sessionsDirectory = sessionsDirectory ?? AppPaths.EnsureCreated().SessionsDirectory;
        _projectsFile = Path.Combine(_sessionsDirectory, "projects.json");
        _routingStatsFile = Path.Combine(_sessionsDirectory, "routing-stats.jsonl");
    }

    public WorkspaceSessionSnapshot? LoadSnapshot()
    {
        if (!File.Exists(_projectsFile)) return null;
        try
        {
            var snapshot = JsonSerializer.Deserialize<WorkspaceSessionSnapshot>(File.ReadAllText(_projectsFile), JsonOptions);
            return snapshot is null || snapshot.Projects.Count == 0 ? null : Normalize(snapshot);
        }
        catch (JsonException)
        {
            return null;
        }
        catch (IOException)
        {
            return null;
        }
    }

    public void SaveSnapshot(AppState state)
    {
        Directory.CreateDirectory(_sessionsDirectory);
        var projects = state.Projects.Select(project => project with
        {
            Sessions = project.Sessions.Select(session => WithMessageCount(state, session)).ToList(),
            CodexSessions = project.CodexSessions.Select(session => WithMessageCount(state, session)).ToList(),
            CursorSessions = project.CursorSessions.Select(session => WithMessageCount(state, session)).ToList(),
            GeminiSessions = project.GeminiSessions.Select(session => WithMessageCount(state, session)).ToList(),
        }).ToList();
        var snapshot = new WorkspaceSessionSnapshot(
            projects,
            state.SelectedProjectId,
            state.SelectedSessionId,
            state.IsDraftSessionVisible);
        File.WriteAllText(_projectsFile, JsonSerializer.Serialize(snapshot, JsonOptions));
    }

    public IReadOnlyList<ChatMessage> LoadMessages(string sessionId)
    {
        var file = MessageFile(sessionId);
        if (!File.Exists(file)) return [];
        try
        {
            var messages = JsonSerializer.Deserialize<List<ChatMessage>>(File.ReadAllText(file), JsonOptions) ?? [];
            return messages.Select(message => message with { IsStreaming = false }).ToList();
        }
        catch (JsonException)
        {
            return [];
        }
        catch (IOException)
        {
            return [];
        }
    }

    public void SaveMessages(string sessionId, IReadOnlyList<ChatMessage> messages)
    {
        Directory.CreateDirectory(_sessionsDirectory);
        File.WriteAllText(MessageFile(sessionId), JsonSerializer.Serialize(messages, JsonOptions));
    }

    public void DeleteMessages(string sessionId)
    {
        var file = MessageFile(sessionId);
        if (File.Exists(file)) File.Delete(file);
    }

    public IReadOnlyList<RoutingUsageRecord> LoadRoutingUsage()
    {
        if (!File.Exists(_routingStatsFile)) return [];
        var records = new List<RoutingUsageRecord>();
        foreach (var line in File.ReadLines(_routingStatsFile))
        {
            if (string.IsNullOrWhiteSpace(line)) continue;
            try
            {
                if (JsonSerializer.Deserialize<RoutingUsageRecord>(line, JsonLineOptions) is { } record)
                {
                    records.Add(record);
                }
            }
            catch (JsonException)
            {
            }
        }

        return records
            .GroupBy(record => $"{record.SessionId}:{record.CreatedAt.UtcDateTime:O}:{record.Route}:{record.Model}", StringComparer.OrdinalIgnoreCase)
            .Select(group => group.Last())
            .OrderBy(record => record.CreatedAt)
            .ToList();
    }

    public void SaveRoutingUsage(IEnumerable<RoutingUsageRecord> records)
    {
        Directory.CreateDirectory(_sessionsDirectory);
        var lines = records
            .OrderBy(record => record.CreatedAt)
            .Select(record => JsonSerializer.Serialize(record, JsonLineOptions));
        File.WriteAllLines(_routingStatsFile, lines);
    }

    public void RestoreInto(AppState state, WorkspaceSessionSnapshot snapshot)
    {
        state.Projects.Clear();
        foreach (var project in Normalize(snapshot).Projects)
        {
            state.Projects.Add(project);
            foreach (var session in project.AllSessions)
            {
                state.MessagesBySession[session.Id] = LoadMessages(session.Id).ToList();
            }
        }

        var selectedProjectId = snapshot.SelectedProjectId is { } id &&
                                state.Projects.Any(project => project.Id == id)
            ? snapshot.SelectedProjectId
            : state.Projects.FirstOrDefault()?.Id;
        state.SelectedProjectId = selectedProjectId;
        state.SelectedSessionId = snapshot.SelectedSessionId is { } sessionId &&
                                  state.Projects.SelectMany(project => project.AllSessions).Any(session => session.Id == sessionId)
            ? snapshot.SelectedSessionId
            : null;
        state.IsDraftSessionVisible = snapshot.IsDraftSessionVisible && state.SelectedSessionId is null;
    }

    private string MessageFile(string sessionId) =>
        Path.Combine(_sessionsDirectory, $"{PathHelpers.SafeFileToken(sessionId)}.json");

    private static WorkspaceSessionSnapshot Normalize(WorkspaceSessionSnapshot snapshot) => snapshot with
    {
        Projects = snapshot.Projects.Select(project => project with
        {
            Sessions = project.Sessions ?? [],
            CodexSessions = project.CodexSessions ?? [],
            CursorSessions = project.CursorSessions ?? [],
            GeminiSessions = project.GeminiSessions ?? [],
        }).ToList(),
    };

    private static ProjectSession WithMessageCount(AppState state, ProjectSession session)
    {
        var count = state.MessagesBySession.TryGetValue(session.Id, out var messages)
            ? messages.Count
            : session.MessageCount;
        return session with
        {
            MessageCount = count,
            State = session.State == SessionState.Processing ? SessionState.Idle : session.State,
        };
    }
}
