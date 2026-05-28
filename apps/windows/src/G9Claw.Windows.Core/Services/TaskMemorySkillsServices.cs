using System.Text.Json;

namespace G9Claw.Windows.Core;

public sealed class MemoryService
{
    private readonly string _directory;

    public MemoryService(string? directory = null)
    {
        _directory = directory ?? AppPaths.Current().MemoryDirectory;
    }

    public IReadOnlyList<MemoryRecord> Load()
    {
        if (!Directory.Exists(_directory)) return [];
        return Directory.EnumerateFiles(_directory, "*.*", SearchOption.AllDirectories)
            .Where(path => Path.GetExtension(path).Equals(".md", StringComparison.OrdinalIgnoreCase) ||
                           Path.GetExtension(path).Equals(".txt", StringComparison.OrdinalIgnoreCase) ||
                           Path.GetExtension(path).Equals(".json", StringComparison.OrdinalIgnoreCase))
            .Select(ToMemoryRecord)
            .OrderByDescending(record => record.UpdatedAt)
            .ToList();
    }

    public void Save(MemoryRecord record)
    {
        Directory.CreateDirectory(_directory);
        var file = Path.Combine(_directory, string.IsNullOrWhiteSpace(record.RelativePath) ? $"{record.Id:D}.md" : record.RelativePath);
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        File.WriteAllText(file, record.Content);
    }

    public MemoryRecord Create(string name, string summary, string? projectName = null)
    {
        var safeName = PathHelpers.SafeFileToken(string.IsNullOrWhiteSpace(name) ? "memory" : name.Trim());
        var record = new MemoryRecord(
            Guid.NewGuid(),
            string.IsNullOrWhiteSpace(name) ? "Untitled memory" : name.Trim(),
            summary,
            projectName,
            DateTimeOffset.UtcNow,
            string.IsNullOrWhiteSpace(projectName) ? MemoryRecordType.User : MemoryRecordType.Project,
            $"{safeName}.md",
            false,
            $"# {(string.IsNullOrWhiteSpace(name) ? "Untitled memory" : name.Trim())}\n\n{summary}");
        Save(record);
        return record;
    }

    public void Delete(MemoryRecord record)
    {
        var file = Path.Combine(_directory, record.RelativePath);
        if (File.Exists(file)) File.Delete(file);
    }

    public void Clear()
    {
        if (Directory.Exists(_directory)) Directory.Delete(_directory, recursive: true);
        Directory.CreateDirectory(_directory);
    }

    public string ExportJson(string targetPath)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(targetPath)!);
        File.WriteAllText(targetPath, JsonSerializer.Serialize(Load(), new JsonSerializerOptions(JsonSerializerDefaults.Web) { WriteIndented = true }));
        return targetPath;
    }

    public int ImportJson(string sourcePath)
    {
        var imported = JsonSerializer.Deserialize<List<MemoryRecord>>(File.ReadAllText(sourcePath), new JsonSerializerOptions(JsonSerializerDefaults.Web)) ?? [];
        foreach (var record in imported)
        {
            Save(record with { UpdatedAt = DateTimeOffset.UtcNow });
        }

        return imported.Count;
    }

    private MemoryRecord ToMemoryRecord(string path)
    {
        var info = new FileInfo(path);
        var content = File.ReadAllText(path);
        var relative = Path.GetRelativePath(_directory, path);
        var firstLine = content.Split('\n').FirstOrDefault()?.Trim().TrimStart('#').Trim();
        return new MemoryRecord(
            Guid.NewGuid(),
            string.IsNullOrWhiteSpace(firstLine) ? Path.GetFileNameWithoutExtension(path) : firstLine!,
            content.Length > 240 ? content[..240] : content,
            null,
            info.LastWriteTimeUtc,
            MemoryRecordType.User,
            relative,
            false,
            content);
    }
}

public sealed class SkillService
{
    private readonly string _userSkillDirectory;

    public SkillService(string? userSkillDirectory = null)
    {
        _userSkillDirectory = userSkillDirectory ?? AppPaths.Current().SkillsDirectory;
    }

    public IReadOnlyList<SkillRecord> Load(string? projectRoot = null)
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var roots = new List<(string Path, SkillScope Scope)>
        {
            (_userSkillDirectory, SkillScope.User),
            (Path.Combine(home, ".g9claw", "skills"), SkillScope.User),
            (Path.Combine(home, ".codex", "skills"), SkillScope.User),
            (Path.Combine(home, ".agents", "skills"), SkillScope.User),
        };
        if (SkillRuntimeEnvironment.PluginRoot() is { } pluginRoot)
        {
            roots.Add((Path.Combine(pluginRoot, "skills"), SkillScope.Plugin));
        }
        if (!string.IsNullOrWhiteSpace(projectRoot))
        {
            roots.Add((Path.Combine(projectRoot, ".g9claw", "skills"), SkillScope.Project));
        }

        return roots
            .DistinctBy(root => PathHelpers.NormalizeFullPath(root.Path), StringComparer.OrdinalIgnoreCase)
            .Where(root => Directory.Exists(root.Path))
            .SelectMany(root => Directory.EnumerateFiles(root.Path, "SKILL.md", SearchOption.AllDirectories)
                .Select(path => ToSkillRecord(path, root.Scope)))
            .OrderBy(skill => skill.Name, StringComparer.OrdinalIgnoreCase)
            .ToList();
    }

    public SkillRecord? Resolve(string requested, string? projectRoot = null)
    {
        var normalized = NormalizeSkillName(requested);
        return Load(projectRoot)
            .FirstOrDefault(skill =>
                string.Equals(NormalizeSkillName(skill.Slug), normalized, StringComparison.OrdinalIgnoreCase) ||
                string.Equals(NormalizeSkillName(skill.Name), normalized, StringComparison.OrdinalIgnoreCase));
    }

    public string Read(SkillRecord skill) => File.ReadAllText(skill.SkillFile);

    public SkillRecord Write(SkillRecord skill, string content)
    {
        Directory.CreateDirectory(skill.SkillDir);
        File.WriteAllText(skill.SkillFile, content);
        return ToSkillRecord(skill.SkillFile, skill.Scope);
    }

    public SkillRecord Create(SkillScope scope, string? projectRoot, string slug, string name, string description)
    {
        var root = scope == SkillScope.Project && !string.IsNullOrWhiteSpace(projectRoot)
            ? Path.Combine(projectRoot, ".g9claw", "skills")
            : _userSkillDirectory;
        var safeSlug = SafeSlug(slug);
        var directory = Path.Combine(root, safeSlug);
        Directory.CreateDirectory(directory);
        var file = Path.Combine(directory, "SKILL.md");
        if (File.Exists(file)) throw new IOException($"Skill already exists: {safeSlug}");
        File.WriteAllText(file, $"# {name.Trim()}\n\n{description.Trim()}\n");
        return ToSkillRecord(file, scope);
    }

    public void Delete(SkillRecord skill)
    {
        if (Directory.Exists(skill.SkillDir)) Directory.Delete(skill.SkillDir, recursive: true);
    }

    private static SkillRecord ToSkillRecord(string skillFile, SkillScope scope)
    {
        var directory = Path.GetDirectoryName(skillFile)!;
        var content = File.ReadAllText(skillFile);
        var name = FirstMarkdownHeading(content) ?? Path.GetFileName(directory);
        var description = FirstNonHeadingParagraph(content) ?? "";
        return new SkillRecord(
            Guid.NewGuid(),
            Path.GetFileName(directory),
            name,
            description,
            null,
            directory,
            skillFile,
            scope,
            File.GetLastWriteTimeUtc(skillFile),
            true);
    }

    private static string? FirstMarkdownHeading(string content)
    {
        return content.Split('\n')
            .Select(line => line.Trim())
            .FirstOrDefault(line => line.StartsWith("# ", StringComparison.Ordinal))?[2..].Trim();
    }

    private static string? FirstNonHeadingParagraph(string content)
    {
        return content.Split('\n')
            .Select(line => line.Trim())
            .FirstOrDefault(line => !string.IsNullOrWhiteSpace(line) && !line.StartsWith('#'));
    }

    private static string NormalizeSkillName(string value)
    {
        var trimmed = value.Trim().Replace('\\', '/').Split('/').Last();
        var colon = trimmed.LastIndexOf(':');
        if (colon >= 0 && colon + 1 < trimmed.Length) trimmed = trimmed[(colon + 1)..];
        return trimmed.ToLowerInvariant();
    }

    private static string SafeSlug(string value)
    {
        var cleaned = new string(value.Trim().ToLowerInvariant().Select(ch =>
            char.IsLetterOrDigit(ch) || ch is '-' or '_' or '.' ? ch : '-').ToArray()).Trim('-');
        if (string.IsNullOrWhiteSpace(cleaned)) throw new ArgumentException("Skill slug is required.", nameof(value));
        return cleaned;
    }
}

public sealed class TaskPlanStore
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web) { WriteIndented = true };
    private readonly string _directory;

    public TaskPlanStore(string? directory = null)
    {
        _directory = directory ?? AppPaths.Current().RunHistoryDirectory;
    }

    public IReadOnlyList<TaskPlan> Load()
    {
        if (!Directory.Exists(_directory)) return [];
        return Directory.EnumerateFiles(_directory, "task-*.json", SearchOption.TopDirectoryOnly)
            .Select(path =>
            {
                try { return JsonSerializer.Deserialize<TaskPlan>(File.ReadAllText(path), JsonOptions); }
                catch { return null; }
            })
            .OfType<TaskPlan>()
            .OrderByDescending(plan => plan.CreatedAt)
            .ToList();
    }

    public void Save(TaskPlan plan)
    {
        Directory.CreateDirectory(_directory);
        File.WriteAllText(Path.Combine(_directory, $"task-{plan.Id:D}.json"), JsonSerializer.Serialize(plan, JsonOptions));
    }
}

public sealed class AlwaysOnStore
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web) { WriteIndented = true };
    private readonly string _directory;

    public AlwaysOnStore(string? directory = null)
    {
        _directory = directory ?? Path.Combine(AppPaths.Current().RunHistoryDirectory, "always-on");
    }

    public IReadOnlyList<AlwaysOnPlan> Load()
    {
        if (!Directory.Exists(_directory)) return [];
        return Directory.EnumerateFiles(_directory, "*.json", SearchOption.TopDirectoryOnly)
            .Select(path =>
            {
                try { return JsonSerializer.Deserialize<AlwaysOnPlan>(File.ReadAllText(path), JsonOptions); }
                catch { return null; }
            })
            .OfType<AlwaysOnPlan>()
            .OrderByDescending(plan => plan.UpdatedAt)
            .ToList();
    }

    public void Save(AlwaysOnPlan plan)
    {
        Directory.CreateDirectory(_directory);
        File.WriteAllText(Path.Combine(_directory, $"{plan.Id}.json"), JsonSerializer.Serialize(plan, JsonOptions));
    }

    public AlwaysOnPlan Create(string title, string prompt)
    {
        var now = DateTimeOffset.UtcNow;
        var plan = new AlwaysOnPlan(
            $"plan-{Guid.NewGuid():D}",
            string.IsNullOrWhiteSpace(title) ? "Discovery plan" : title.Trim(),
            prompt.Length > 180 ? prompt[..180] : prompt,
            prompt,
            AlwaysOnStatus.Ready,
            now,
            now);
        Save(plan);
        return plan;
    }

    public AlwaysOnPlan MarkRunNow(AlwaysOnPlan plan)
    {
        var updated = plan with
        {
            Status = AlwaysOnStatus.Completed,
            UpdatedAt = DateTimeOffset.UtcNow,
            Summary = $"Run completed at {DateTimeOffset.Now:g}",
        };
        Save(updated);
        return updated;
    }

    public void Delete(AlwaysOnPlan plan)
    {
        var file = Path.Combine(_directory, $"{plan.Id}.json");
        if (File.Exists(file)) File.Delete(file);
    }
}
