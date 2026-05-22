using System.Text;

namespace G9Claw.Windows.Core;

public sealed record WorkspaceValidationResult(bool Valid, string? ResolvedPath, string? Error);
public sealed record WorkspacePreview(
    string Path,
    string RelativePath,
    WorkspacePreviewKind Kind,
    string? Text,
    string? MimeType,
    long ByteCount);

public enum WorkspacePreviewKind
{
    Text,
    Markdown,
    Html,
    Pdf,
    Image,
    Binary,
}

public sealed class WorkspaceService
{
    private static readonly string[] ForbiddenPaths =
    [
        @"C:\Windows",
        @"C:\Program Files",
        @"C:\Program Files (x86)",
        @"C:\ProgramData",
        @"C:\System Volume Information",
        @"C:\$Recycle.Bin",
        @"C:\Recovery",
        @"C:\PerfLogs",
        @"C:\Boot",
        @"C:\Documents and Settings",
        "/",
        "/etc",
        "/bin",
        "/sbin",
        "/usr",
        "/dev",
        "/proc",
        "/sys",
        "/var",
        "/boot",
        "/root",
        "/lib",
        "/lib64",
        "/opt",
        "/tmp",
        "/run",
    ];

    private static readonly HashSet<string> HiddenNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "node_modules",
        ".git",
        "dist",
        "build",
        ".DS_Store",
    };

    public string WorkspaceRoot { get; }

    public WorkspaceService(string? workspaceRoot = null)
    {
        WorkspaceRoot = PathHelpers.NormalizeFullPath(workspaceRoot ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
    }

    public WorkspaceValidationResult ValidateWorkspacePath(string requestedPath)
    {
        if (string.IsNullOrWhiteSpace(requestedPath))
        {
            return new WorkspaceValidationResult(false, null, "Workspace path is required.");
        }

        var expanded = PathHelpers.ExpandHome(requestedPath.Trim());
        if (!Path.IsPathFullyQualified(expanded))
        {
            return new WorkspaceValidationResult(false, null, "Workspace path must be absolute.");
        }

        string normalized;
        try
        {
            normalized = PathHelpers.NormalizeFullPath(expanded);
        }
        catch (Exception ex)
        {
            return new WorkspaceValidationResult(false, null, ex.Message);
        }

        foreach (var forbidden in ForbiddenPaths)
        {
            if (IsForbidden(normalized, forbidden))
            {
                return new WorkspaceValidationResult(false, null, $"Cannot create workspace in system directory: {forbidden}");
            }
        }

        if (PathHelpers.IsFilesystemRoot(normalized))
        {
            return new WorkspaceValidationResult(false, null, "Workspace path cannot be a filesystem root.");
        }

        if (!PathHelpers.IsSameOrChildPath(normalized, WorkspaceRoot))
        {
            return new WorkspaceValidationResult(false, null, $"Workspace path must be within the allowed workspace root: {WorkspaceRoot}");
        }

        return new WorkspaceValidationResult(true, normalized, null);
    }

    public static List<WorkspaceProject> SortedProjects(IEnumerable<WorkspaceProject> projects, ProjectSortOrder order)
    {
        return order == ProjectSortOrder.Name
            ? projects.OrderBy(project => project.DisplayName, StringComparer.CurrentCultureIgnoreCase).ToList()
            : projects.OrderByDescending(project => project.LatestActivity).ToList();
    }

    public static string ProjectNameFor(string path)
    {
        var normalized = PathHelpers.NormalizeFullPath(path);
        var separators = new[] { '/', '\\', ':', ' ', '\t', '\n', '\r', '~', '_' };
        var parts = normalized.Split(separators, StringSplitOptions.RemoveEmptyEntries);
        var slug = string.Join("-", parts);
        return string.IsNullOrWhiteSpace(slug) ? "workspace" : $"-{slug}";
    }

    public IReadOnlyList<WorkspaceFile> ListFiles(string rootPath, ISet<string>? expandedDirectories = null)
    {
        var root = PathHelpers.NormalizeFullPath(rootPath);
        EnsureInsideWorkspace(rootPath, root);
        var output = new List<WorkspaceFile>();
        Walk(root, root, 0, expandedDirectories ?? new HashSet<string>(StringComparer.OrdinalIgnoreCase), output);
        return output;
    }

    public string ReadFile(string path, string workspaceRoot)
    {
        var resolved = ResolveWorkspacePath(path, workspaceRoot);
        return File.ReadAllText(resolved, Encoding.UTF8);
    }

    public void WriteFile(string path, string content, string workspaceRoot)
    {
        var resolved = ResolveWorkspacePath(path, workspaceRoot);
        Directory.CreateDirectory(Path.GetDirectoryName(resolved)!);
        File.WriteAllText(resolved, content, Encoding.UTF8);
    }

    public string CreateFile(string parentPath, string name, bool isDirectory, string workspaceRoot)
    {
        var parent = EnsureInsideWorkspace(parentPath, workspaceRoot);
        var safeName = SafeChildName(name);
        var target = Path.Combine(parent, safeName);
        EnsureInsideWorkspace(target, workspaceRoot);
        if (isDirectory)
        {
            Directory.CreateDirectory(target);
        }
        else
        {
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            if (!File.Exists(target)) File.WriteAllBytes(target, []);
        }

        return target;
    }

    public string Rename(string path, string newName, string workspaceRoot)
    {
        var source = EnsureInsideWorkspace(path, workspaceRoot);
        var target = Path.Combine(Path.GetDirectoryName(source)!, SafeChildName(newName));
        EnsureInsideWorkspace(target, workspaceRoot);
        if (Directory.Exists(source))
        {
            Directory.Move(source, target);
        }
        else
        {
            File.Move(source, target);
        }

        return target;
    }

    public void Delete(string path, string workspaceRoot, bool recursive)
    {
        var resolved = ResolveWorkspacePath(path, workspaceRoot);
        if (Directory.Exists(resolved))
        {
            Directory.Delete(resolved, recursive);
        }
        else if (File.Exists(resolved))
        {
            File.Delete(resolved);
        }
    }

    public string UploadFile(string sourcePath, string targetDirectory, string workspaceRoot, bool overwrite = false)
    {
        var source = PathHelpers.NormalizeFullPath(sourcePath);
        if (!File.Exists(source)) throw new FileNotFoundException("Upload source file does not exist.", source);
        var targetParent = ResolveWorkspacePath(targetDirectory, workspaceRoot);
        Directory.CreateDirectory(targetParent);
        var target = Path.Combine(targetParent, Path.GetFileName(source));
        EnsureInsideWorkspace(target, workspaceRoot);
        if (File.Exists(target) && !overwrite)
        {
            throw new IOException($"Target file already exists: {target}");
        }

        File.Copy(source, target, overwrite);
        return target;
    }

    public WorkspacePreview Preview(string path, string workspaceRoot, int maxTextBytes = 512_000)
    {
        var resolved = ResolveWorkspacePath(path, workspaceRoot);
        if (!File.Exists(resolved)) throw new FileNotFoundException("Preview file does not exist.", resolved);
        var info = new FileInfo(resolved);
        var extension = Path.GetExtension(resolved).TrimStart('.').ToLowerInvariant();
        var kind = extension switch
        {
            "md" or "markdown" => WorkspacePreviewKind.Markdown,
            "html" or "htm" => WorkspacePreviewKind.Html,
            "pdf" => WorkspacePreviewKind.Pdf,
            "png" or "jpg" or "jpeg" or "gif" or "webp" or "bmp" or "tiff" or "tif" => WorkspacePreviewKind.Image,
            _ => IsTextExtension(extension) && info.Length <= maxTextBytes ? WorkspacePreviewKind.Text : WorkspacePreviewKind.Binary,
        };

        var text = kind is WorkspacePreviewKind.Text or WorkspacePreviewKind.Markdown or WorkspacePreviewKind.Html
            ? File.ReadAllText(resolved, Encoding.UTF8)
            : null;
        return new WorkspacePreview(
            resolved,
            Path.GetRelativePath(workspaceRoot, resolved),
            kind,
            text,
            MimeTypeFor(extension, kind),
            info.Length);
    }

    public static string ResolveWorkspacePath(string path, string workspaceRoot)
    {
        var expanded = PathHelpers.ExpandHome(path.Trim());
        var candidate = Path.IsPathFullyQualified(expanded)
            ? expanded
            : Path.Combine(workspaceRoot, expanded);
        return EnsureInsideWorkspace(candidate, workspaceRoot);
    }

    public static string EnsureInsideWorkspace(string path, string workspaceRoot)
    {
        var resolved = PathHelpers.NormalizeFullPath(path);
        var root = PathHelpers.NormalizeFullPath(workspaceRoot);
        if (!PathHelpers.IsSameOrChildPath(resolved, root))
        {
            throw new InvalidOperationException($"Path is outside workspace root: {resolved}");
        }

        return resolved;
    }

    private static void Walk(string root, string directory, int depth, ISet<string> expandedDirectories, List<WorkspaceFile> output)
    {
        foreach (var path in Directory.EnumerateFileSystemEntries(directory)
                     .Where(path => !HiddenNames.Contains(Path.GetFileName(path)))
                     .OrderByDescending(Directory.Exists)
                     .ThenBy(Path.GetFileName, StringComparer.CurrentCultureIgnoreCase))
        {
            var info = new FileInfo(path);
            var isDirectory = Directory.Exists(path);
            var relative = Path.GetRelativePath(root, path);
            output.Add(new WorkspaceFile(
                path,
                Path.GetFileName(path),
                path,
                relative,
                depth,
                isDirectory,
                expandedDirectories.Contains(path),
                info.Exists ? info.LastWriteTimeUtc : Directory.GetLastWriteTimeUtc(path),
                isDirectory ? null : info.Length));

            if (isDirectory && expandedDirectories.Contains(path))
            {
                Walk(root, path, depth + 1, expandedDirectories, output);
            }
        }
    }

    private static string SafeChildName(string value)
    {
        var trimmed = value.Trim();
        if (string.IsNullOrEmpty(trimmed) || trimmed is "." or ".." || trimmed.Contains('/') || trimmed.Contains('\\'))
        {
            throw new ArgumentException("Invalid name.", nameof(value));
        }

        return trimmed;
    }

    private static bool IsForbidden(string normalizedPath, string forbidden)
    {
        if (OperatingSystem.IsWindows() && forbidden.StartsWith("/", StringComparison.Ordinal))
        {
            return false;
        }

        if (!OperatingSystem.IsWindows() && forbidden.Contains(':'))
        {
            return false;
        }

        var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        var normalizedForbidden = PathHelpers.NormalizeFullPath(forbidden);
        return string.Equals(normalizedPath, normalizedForbidden, comparison)
            || normalizedPath.StartsWith(normalizedForbidden + Path.DirectorySeparatorChar, comparison)
            || normalizedPath.StartsWith(normalizedForbidden + Path.AltDirectorySeparatorChar, comparison);
    }

    private static bool IsTextExtension(string extension) => new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
        "txt", "json", "jsonl", "yaml", "yml", "toml", "xml", "cs", "swift", "ts", "tsx", "js", "jsx",
        "py", "rs", "go", "java", "kt", "cpp", "c", "h", "hpp", "css", "scss", "sql", "sh", "ps1",
    }.Contains(extension);

    private static string MimeTypeFor(string extension, WorkspacePreviewKind kind) => extension switch
    {
        "md" or "markdown" => "text/markdown",
        "html" or "htm" => "text/html",
        "pdf" => "application/pdf",
        "png" => "image/png",
        "jpg" or "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "json" => "application/json",
        _ when kind == WorkspacePreviewKind.Text => "text/plain",
        _ => "application/octet-stream",
    };
}
