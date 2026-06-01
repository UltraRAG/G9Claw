namespace PilotDeck.Windows.Core;

public enum PermissionDecision
{
    Pending,
    Allowed,
    Denied,
    Expired,
}

public sealed record PermissionRecord(
    PermissionRequest Request,
    PermissionDecision Decision,
    PermissionScope? GrantedScope,
    DateTimeOffset? ResolvedAt,
    string? Response);

public sealed class PermissionService
{
    private readonly Dictionary<Guid, PermissionRecord> _records = [];

    public PermissionRecord Request(
        string sessionId,
        string toolName,
        string inputJson,
        string reason,
        PermissionRequestKind kind = PermissionRequestKind.Tool,
        PermissionScope scope = PermissionScope.Session,
        AgentInteractivePayload? interactivePayload = null)
    {
        var request = new PermissionRequest(
            Guid.NewGuid(),
            sessionId,
            toolName,
            inputJson,
            reason,
            scope,
            DateTimeOffset.UtcNow,
            kind,
            interactivePayload);
        var record = new PermissionRecord(request, PermissionDecision.Pending, null, null, null);
        _records[request.Id] = record;
        return record;
    }

    public PermissionRecord Resolve(Guid requestId, bool allow, PermissionScope? grantedScope = null, string? response = null)
    {
        if (!_records.TryGetValue(requestId, out var record)) throw new InvalidOperationException($"Permission request not found: {requestId}");
        if (record.Decision != PermissionDecision.Pending) return record;

        var resolved = record with
        {
            Decision = allow ? PermissionDecision.Allowed : PermissionDecision.Denied,
            GrantedScope = allow ? grantedScope ?? record.Request.Scope : null,
            ResolvedAt = DateTimeOffset.UtcNow,
            Response = response,
        };
        _records[requestId] = resolved;
        return resolved;
    }

    public IReadOnlyList<PermissionRecord> ExpirePending(TimeSpan timeout)
    {
        var now = DateTimeOffset.UtcNow;
        var expired = new List<PermissionRecord>();
        foreach (var pair in _records.ToList())
        {
            var record = pair.Value;
            if (record.Decision != PermissionDecision.Pending) continue;
            if (now - record.Request.CreatedAt < timeout) continue;

            var resolved = record with
            {
                Decision = PermissionDecision.Expired,
                ResolvedAt = now,
            };
            _records[pair.Key] = resolved;
            expired.Add(resolved);
        }

        return expired;
    }

    public IReadOnlyList<PermissionRecord> Pending(string? sessionId = null)
    {
        return _records.Values
            .Where(record => record.Decision == PermissionDecision.Pending)
            .Where(record => sessionId is null || record.Request.SessionId == sessionId)
            .OrderBy(record => record.Request.CreatedAt)
            .ToList();
    }

    public IReadOnlyList<PermissionRecord> Snapshot() =>
        _records.Values.OrderBy(record => record.Request.CreatedAt).ToList();
}
