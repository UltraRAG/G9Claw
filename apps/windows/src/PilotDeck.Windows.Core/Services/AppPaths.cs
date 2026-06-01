namespace PilotDeck.Windows.Core;

public sealed record AppPathSet(
    string Root,
    string SettingsFile,
    string UiPreferencesFile,
    string PermissionModeFile,
    string CredentialsDirectory,
    string SessionsDirectory,
    string LogsDirectory,
    string MemoryDirectory,
    string SkillsDirectory,
    string PluginsDirectory,
    string RunHistoryDirectory);

public static class AppPaths
{
    public const string ProductDirectoryName = "PilotDeck";
    private static string LegacyProductDirectoryName => string.Concat("G", "9", "Claw");

    public static AppPathSet Current()
    {
        var root = Path.Combine(LocalAppDataRoot(), ProductDirectoryName);
        return new AppPathSet(
            root,
            Path.Combine(root, "settings.json"),
            Path.Combine(root, "ui-preferences.json"),
            Path.Combine(root, "permission-modes.json"),
            Path.Combine(root, "credentials"),
            Path.Combine(root, "sessions"),
            Path.Combine(root, "logs"),
            Path.Combine(root, "memory"),
            Path.Combine(root, "skills"),
            Path.Combine(root, "plugins"),
            Path.Combine(root, "run-history"));
    }

    public static AppPathSet EnsureCreated()
    {
        var paths = Current();
        MigrateLegacyRootIfNeeded(paths.Root);
        Directory.CreateDirectory(paths.Root);
        Directory.CreateDirectory(paths.CredentialsDirectory);
        Directory.CreateDirectory(paths.SessionsDirectory);
        Directory.CreateDirectory(paths.LogsDirectory);
        Directory.CreateDirectory(paths.MemoryDirectory);
        Directory.CreateDirectory(paths.SkillsDirectory);
        Directory.CreateDirectory(paths.PluginsDirectory);
        Directory.CreateDirectory(paths.RunHistoryDirectory);
        return paths;
    }

    private static string LocalAppDataRoot()
    {
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (!string.IsNullOrWhiteSpace(localAppData)) return localAppData;
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "AppData", "Local");
    }

    private static void MigrateLegacyRootIfNeeded(string currentRoot)
    {
        var legacyRoot = Path.Combine(LocalAppDataRoot(), LegacyProductDirectoryName);
        if (!Directory.Exists(legacyRoot)) return;

        try
        {
            CopyDirectoryWithoutOverwrite(legacyRoot, currentRoot);
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }

    private static void CopyDirectoryWithoutOverwrite(string sourceDirectory, string targetDirectory)
    {
        Directory.CreateDirectory(targetDirectory);
        foreach (var sourceFile in Directory.EnumerateFiles(sourceDirectory))
        {
            var targetFile = Path.Combine(targetDirectory, Path.GetFileName(sourceFile));
            if (!File.Exists(targetFile))
            {
                File.Copy(sourceFile, targetFile);
            }
        }

        foreach (var sourceChild in Directory.EnumerateDirectories(sourceDirectory))
        {
            var targetChild = Path.Combine(targetDirectory, Path.GetFileName(sourceChild));
            CopyDirectoryWithoutOverwrite(sourceChild, targetChild);
        }
    }
}

public static class PathHelpers
{
    public static string ExpandHome(string path, string? homePath = null)
    {
        if (string.IsNullOrWhiteSpace(path)) return path;
        if (path == "~")
        {
            return homePath ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        }

        if (path.StartsWith("~/", StringComparison.Ordinal) || path.StartsWith(@"~\", StringComparison.Ordinal))
        {
            var home = homePath ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            return Path.Combine(home, path[2..]);
        }

        return path;
    }

    public static string NormalizeFullPath(string path)
    {
        var full = Path.GetFullPath(ExpandHome(path));
        return full.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
    }

    public static bool IsFilesystemRoot(string path)
    {
        var full = Path.GetFullPath(ExpandHome(path));
        var normalized = full.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var root = Path.GetPathRoot(full);
        if (string.IsNullOrWhiteSpace(root)) return false;
        var normalizedRoot = root.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        return string.Equals(normalized, normalizedRoot, comparison);
    }

    public static bool IsSameOrChildPath(string candidate, string root)
    {
        var normalizedCandidate = NormalizeFullPath(candidate);
        var normalizedRoot = NormalizeFullPath(root);
        var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
        return string.Equals(normalizedCandidate, normalizedRoot, comparison)
            || normalizedCandidate.StartsWith(normalizedRoot + Path.DirectorySeparatorChar, comparison)
            || normalizedCandidate.StartsWith(normalizedRoot + Path.AltDirectorySeparatorChar, comparison);
    }

    public static string SafeFileToken(string value)
    {
        var bytes = System.Text.Encoding.UTF8.GetBytes(value);
        return Convert.ToBase64String(bytes)
            .Replace('+', '-')
            .Replace('/', '_')
            .TrimEnd('=');
    }
}
