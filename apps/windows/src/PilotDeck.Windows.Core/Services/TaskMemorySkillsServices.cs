using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace PilotDeck.Windows.Core;

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
        var now = DateTimeOffset.UtcNow;
        var normalizedName = string.IsNullOrWhiteSpace(name) ? "Untitled memory" : name.Trim();
        var normalizedSummary = summary.Trim();
        var safeName = PathHelpers.SafeFileToken(string.IsNullOrWhiteSpace(name) ? "memory" : name.Trim());
        var type = string.IsNullOrWhiteSpace(projectName) ? MemoryRecordType.User : MemoryRecordType.Project;
        var record = new MemoryRecord(
            Guid.NewGuid(),
            normalizedName,
            normalizedSummary,
            projectName,
            now,
            type,
            $"{safeName}.md",
            false,
            BuildMemoryContent(normalizedName, normalizedSummary, type, projectName, now, deprecated: false));
        Save(record);
        return record;
    }

    public MemoryRecord Edit(MemoryRecord record, string name, string summary)
    {
        var updatedAt = DateTimeOffset.UtcNow;
        var normalizedName = string.IsNullOrWhiteSpace(name) ? "Untitled memory" : name.Trim();
        var normalizedSummary = summary.Trim();
        var updated = record with
        {
            Name = normalizedName,
            Summary = normalizedSummary,
            UpdatedAt = updatedAt,
            Content = UpsertMemoryFrontmatter(record, normalizedName, normalizedSummary, record.Deprecated, updatedAt),
        };
        Save(updated);
        return updated;
    }

    public MemoryRecord SetDeprecated(MemoryRecord record, bool deprecated)
    {
        var updatedAt = DateTimeOffset.UtcNow;
        var updated = record with
        {
            Deprecated = deprecated,
            UpdatedAt = updatedAt,
            Content = UpsertMemoryFrontmatter(record, record.Name, record.Summary, deprecated, updatedAt),
        };
        Save(updated);
        return updated;
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
        var parsed = MemoryFile(content);
        var firstHeading = FirstHeading(content);
        var name = parsed?.Name.NilIfBlank() ?? firstHeading.NilIfBlank() ?? Path.GetFileNameWithoutExtension(path);
        var summary = parsed?.Description.NilIfBlank() ?? Preview(content);
        var type = parsed?.Type ?? RecordType(content, path);
        var scope = parsed?.Scope;
        var projectName = string.Equals(scope, "global", StringComparison.OrdinalIgnoreCase) ? null : parsed?.ProjectName.NilIfBlank();
        return new MemoryRecord(
            StableRecordId(relative),
            name,
            summary,
            projectName,
            parsed?.UpdatedAt ?? new DateTimeOffset(info.LastWriteTimeUtc),
            type,
            relative,
            parsed?.Deprecated ?? Deprecated(content),
            content);
    }

    private static string BuildMemoryContent(
        string name,
        string summary,
        MemoryRecordType type,
        string? projectName,
        DateTimeOffset updatedAt,
        bool deprecated)
    {
        var lines = new List<string>
        {
            "---",
            $"name: {FrontmatterValue(name)}",
            $"description: {FrontmatterValue(summary)}",
            $"type: {MemoryRecordTypeValue(type)}",
            $"scope: {(string.IsNullOrWhiteSpace(projectName) ? "global" : "project")}",
        };
        if (!string.IsNullOrWhiteSpace(projectName))
        {
            lines.Add($"project_name: {FrontmatterValue(projectName)}");
        }
        lines.Add($"updated_at: {updatedAt:O}");
        lines.Add($"deprecated: {(deprecated ? "true" : "false")}");
        lines.Add("---");
        lines.Add("");
        lines.Add($"# {name}");
        lines.Add("");
        if (!string.IsNullOrWhiteSpace(summary))
        {
            lines.Add(summary);
        }

        return string.Join("\n", lines);
    }

    private static string UpsertMemoryFrontmatter(
        MemoryRecord record,
        string name,
        string summary,
        bool deprecated,
        DateTimeOffset updatedAt)
    {
        var lines = record.Content.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n').ToList();
        ReplaceOrInsert("name", FrontmatterValue(name), lines);
        ReplaceOrInsert("description", FrontmatterValue(summary), lines);
        ReplaceOrInsert("type", MemoryRecordTypeValue(record.Type), lines);
        ReplaceOrInsert("scope", string.IsNullOrWhiteSpace(record.ProjectName) ? "global" : "project", lines);
        if (!string.IsNullOrWhiteSpace(record.ProjectName))
        {
            ReplaceOrInsert("project_name", FrontmatterValue(record.ProjectName), lines);
        }
        ReplaceOrInsert("updated_at", updatedAt.ToString("O"), lines);
        ReplaceOrInsert("deprecated", deprecated ? "true" : "false", lines);
        return string.Join("\n", lines);
    }

    private static void ReplaceOrInsert(string key, string value, List<string> lines)
    {
        var existing = lines.FindIndex(line => line.TrimStart().StartsWith($"{key}:", StringComparison.OrdinalIgnoreCase));
        if (existing >= 0)
        {
            lines[existing] = $"{key}: {value}";
            return;
        }

        var fenceEnd = lines.Skip(1).Select((line, index) => (line, index: index + 1))
            .FirstOrDefault(item => string.Equals(item.line.Trim(), "---", StringComparison.Ordinal)).index;
        if (fenceEnd > 0)
        {
            lines.Insert(fenceEnd, $"{key}: {value}");
            return;
        }

        lines.InsertRange(0, ["---", $"{key}: {value}", "---", ""]);
    }

    private static ParsedMemoryFile? MemoryFile(string content)
    {
        var header = FrontmatterHeader(content);
        if (header is null) return null;
        var values = FrontmatterValues(header);
        return new ParsedMemoryFile(
            values.GetValueOrDefault("name") ?? "",
            values.GetValueOrDefault("description") ?? "",
            MemoryRecordTypeValue(values.GetValueOrDefault("type")),
            values.GetValueOrDefault("scope"),
            values.GetValueOrDefault("project_name"),
            Date(values.GetValueOrDefault("updated_at")),
            Bool(values.GetValueOrDefault("deprecated")));
    }

    private static string? FrontmatterHeader(string content)
    {
        var normalized = content.Replace("\r\n", "\n").Replace('\r', '\n');
        if (!normalized.StartsWith("---\n", StringComparison.Ordinal)) return null;
        var end = normalized.IndexOf("\n---\n", 4, StringComparison.Ordinal);
        return end < 0 ? null : normalized[4..end];
    }

    private static Dictionary<string, string> FrontmatterValues(string header)
    {
        var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in header.Split('\n'))
        {
            var separator = line.IndexOf(':');
            if (separator <= 0) continue;
            var key = line[..separator].Trim();
            var value = line[(separator + 1)..].Trim().Trim('"');
            if (!string.IsNullOrWhiteSpace(key))
            {
                values[key] = value;
            }
        }

        return values;
    }

    private static string StripFrontmatter(string content)
    {
        var normalized = content.Replace("\r\n", "\n").Replace('\r', '\n');
        if (!normalized.StartsWith("---\n", StringComparison.Ordinal)) return content;
        var end = normalized.IndexOf("\n---\n", 4, StringComparison.Ordinal);
        return end < 0 ? content : normalized[(end + 5)..].Trim('\n');
    }

    private static string? FirstHeading(string content) =>
        StripFrontmatter(content)
            .Split('\n')
            .Select(line => line.Trim())
            .FirstOrDefault(line => line.StartsWith("# ", StringComparison.Ordinal))?
            .TrimStart('#')
            .Trim();

    private static string Preview(string content) =>
        StripFrontmatter(content)
            .Split('\n')
            .Select(line => line.Trim())
            .FirstOrDefault(line => !string.IsNullOrWhiteSpace(line) && !line.StartsWith('#') && !line.Contains(':'))
            ?.Truncate(240) ?? "Memory record";

    private static bool Deprecated(string content) =>
        Bool(FrontmatterHeader(content) is { } header ? FrontmatterValues(header).GetValueOrDefault("deprecated") : null)
        ?? content.Contains("deprecated: true", StringComparison.OrdinalIgnoreCase);

    private static MemoryRecordType RecordType(string content, string fallbackPath)
    {
        var lower = $"{content} {fallbackPath}".ToLowerInvariant();
        if (lower.Contains("type: project")) return MemoryRecordType.Project;
        if (lower.Contains("type: feedback")) return MemoryRecordType.Feedback;
        if (lower.Contains("type: user") || lower.Contains("/user") || lower.Contains("\\user")) return MemoryRecordType.User;
        if (lower.Contains("general_project_meta")) return MemoryRecordType.GeneralProjectMeta;
        if (lower.Contains("feedback")) return MemoryRecordType.Feedback;
        return MemoryRecordType.Project;
    }

    private static MemoryRecordType? MemoryRecordTypeValue(string? raw) => raw?.Trim() switch
    {
        "project" => MemoryRecordType.Project,
        "feedback" => MemoryRecordType.Feedback,
        "user" => MemoryRecordType.User,
        "general_project_meta" => MemoryRecordType.GeneralProjectMeta,
        _ => null,
    };

    private static string MemoryRecordTypeValue(MemoryRecordType type) => type switch
    {
        MemoryRecordType.Project => "project",
        MemoryRecordType.Feedback => "feedback",
        MemoryRecordType.User => "user",
        MemoryRecordType.GeneralProjectMeta => "general_project_meta",
        _ => "project",
    };

    private static DateTimeOffset? Date(string? raw) =>
        DateTimeOffset.TryParse(raw, out var value) ? value : null;

    private static bool? Bool(string? raw) => raw?.Trim().ToLowerInvariant() switch
    {
        "true" => true,
        "false" => false,
        _ => null,
    };

    private static Guid StableRecordId(string relativePath)
    {
        var normalized = relativePath.Replace('\\', '/').ToLowerInvariant();
        var hash = SHA1.HashData(Encoding.UTF8.GetBytes(normalized));
        return new Guid(hash.Take(16).ToArray());
    }

    private static string FrontmatterValue(string value) =>
        value.Replace("\r", " ").Replace("\n", " ").Trim();

    private sealed record ParsedMemoryFile(
        string Name,
        string Description,
        MemoryRecordType? Type,
        string? Scope,
        string? ProjectName,
        DateTimeOffset? UpdatedAt,
        bool? Deprecated);
}

file static class MemoryServiceStringExtensions
{
    public static string? NilIfBlank(this string? value) =>
        string.IsNullOrWhiteSpace(value) ? null : value.Trim();

    public static string Truncate(this string value, int maxLength) =>
        value.Length <= maxLength ? value : value[..maxLength];
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
            (Path.Combine(home, ".pd", "skills"), SkillScope.User),
            (Path.Combine(home, ".codex", "skills"), SkillScope.User),
            (Path.Combine(home, ".agents", "skills"), SkillScope.User),
        };
        if (SkillRuntimeEnvironment.PluginRoot() is { } pluginRoot)
        {
            roots.Add((Path.Combine(pluginRoot, "skills"), SkillScope.Plugin));
        }
        if (!string.IsNullOrWhiteSpace(projectRoot))
        {
            roots.Add((Path.Combine(projectRoot, ".pd", "skills"), SkillScope.Project));
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
        var root = SkillRoot(scope, projectRoot);
        var safeSlug = SafeSlug(slug);
        var directory = Path.Combine(root, safeSlug);
        Directory.CreateDirectory(directory);
        var file = Path.Combine(directory, "SKILL.md");
        if (File.Exists(file)) throw new IOException($"Skill already exists: {safeSlug}");
        File.WriteAllText(file, $"# {name.Trim()}\n\n{description.Trim()}\n");
        return ToSkillRecord(file, scope);
    }

    public SkillRecord ImportFolder(SkillScope scope, string? projectRoot, string sourceDirectory, bool overwrite = false)
    {
        if (string.IsNullOrWhiteSpace(sourceDirectory)) throw new ArgumentException("Skill folder is required.", nameof(sourceDirectory));
        var source = Path.GetFullPath(sourceDirectory);
        var sourceSkillFile = Path.Combine(source, "SKILL.md");
        if (!File.Exists(sourceSkillFile)) throw new FileNotFoundException("Selected folder must contain SKILL.md.", sourceSkillFile);

        var root = SkillRoot(scope, projectRoot);
        Directory.CreateDirectory(root);
        var safeSlug = SafeSlug(Path.GetFileName(source.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)));
        var target = Path.Combine(root, safeSlug);
        if (Directory.Exists(target))
        {
            if (!overwrite) throw new IOException($"Skill already exists: {safeSlug}");
            Directory.Delete(target, recursive: true);
        }

        CopyDirectory(source, target);
        return ToSkillRecord(Path.Combine(target, "SKILL.md"), scope);
    }

    public void Delete(SkillRecord skill)
    {
        if (Directory.Exists(skill.SkillDir)) Directory.Delete(skill.SkillDir, recursive: true);
    }

    private string SkillRoot(SkillScope scope, string? projectRoot) =>
        scope == SkillScope.Project && !string.IsNullOrWhiteSpace(projectRoot)
            ? Path.Combine(projectRoot, ".pd", "skills")
            : _userSkillDirectory;

    private static void CopyDirectory(string source, string target)
    {
        Directory.CreateDirectory(target);
        foreach (var directory in Directory.EnumerateDirectories(source, "*", SearchOption.AllDirectories))
        {
            Directory.CreateDirectory(Path.Combine(target, Path.GetRelativePath(source, directory)));
        }

        foreach (var file in Directory.EnumerateFiles(source, "*", SearchOption.AllDirectories))
        {
            var relative = Path.GetRelativePath(source, file);
            File.Copy(file, Path.Combine(target, relative), overwrite: false);
        }
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
