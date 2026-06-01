using LibGit2Sharp;

namespace PilotDeck.Windows.Core;

public sealed record GitStatusEntry(string Path, string State);
public sealed record GitStatusSnapshot(string RepositoryPath, string Branch, bool IsDirty, IReadOnlyList<GitStatusEntry> Entries);
public sealed record GitCommitResult(string Sha, string Message);
public sealed record GitBranchSnapshot(string CurrentBranch, IReadOnlyList<string> Branches);
public sealed record GitRemoteSnapshot(string Name, string Url);

public sealed class GitService
{
    public string Init(string workspacePath)
    {
        Directory.CreateDirectory(workspacePath);
        return Repository.Init(workspacePath);
    }

    public GitStatusSnapshot Status(string workspacePath)
    {
        using var repo = OpenRepository(workspacePath);
        var status = repo.RetrieveStatus(new StatusOptions());
        var entries = status.Select(entry => new GitStatusEntry(entry.FilePath, entry.State.ToString())).ToList();
        return new GitStatusSnapshot(repo.Info.WorkingDirectory, repo.Head.FriendlyName, entries.Count > 0, entries);
    }

    public string Diff(string workspacePath, IEnumerable<string>? paths = null)
    {
        using var repo = OpenRepository(workspacePath);
        var patch = paths is null
            ? repo.Diff.Compare<Patch>(repo.Head.Tip?.Tree, DiffTargets.WorkingDirectory)
            : repo.Diff.Compare<Patch>(repo.Head.Tip?.Tree, DiffTargets.WorkingDirectory, paths);
        return patch.Content;
    }

    public string FileDiff(string workspacePath, string path) => Diff(workspacePath, [path]);

    public GitBranchSnapshot Branches(string workspacePath)
    {
        using var repo = OpenRepository(workspacePath);
        var branches = repo.Branches
            .Where(branch => !branch.IsRemote)
            .Select(branch => branch.FriendlyName)
            .OrderBy(name => name, StringComparer.OrdinalIgnoreCase)
            .ToList();
        return new GitBranchSnapshot(repo.Head.FriendlyName, branches);
    }

    public string CheckoutBranch(string workspacePath, string branchName)
    {
        using var repo = OpenRepository(workspacePath);
        var branch = repo.Branches[branchName] ?? repo.CreateBranch(branchName);
        Commands.Checkout(repo, branch);
        return branch.FriendlyName;
    }

    public string CreateBranch(string workspacePath, string branchName, bool checkout = false)
    {
        using var repo = OpenRepository(workspacePath);
        if (repo.Branches[branchName] is not null) throw new InvalidOperationException($"Branch already exists: {branchName}");
        var branch = repo.CreateBranch(branchName);
        if (checkout) Commands.Checkout(repo, branch);
        return branch.FriendlyName;
    }

    public void DeleteBranch(string workspacePath, string branchName)
    {
        using var repo = OpenRepository(workspacePath);
        var branch = repo.Branches[branchName] ?? throw new InvalidOperationException($"Branch not found: {branchName}");
        if (branch.IsCurrentRepositoryHead) throw new InvalidOperationException("Cannot delete the current branch.");
        repo.Branches.Remove(branch);
    }

    public GitCommitResult Commit(string workspacePath, string message, IEnumerable<string> paths, string authorName, string authorEmail)
    {
        using var repo = OpenRepository(workspacePath);
        Commands.Stage(repo, paths);
        var signature = new Signature(authorName, authorEmail, DateTimeOffset.Now);
        var commit = repo.Commit(message, signature, signature);
        return new GitCommitResult(commit.Sha, commit.MessageShort);
    }

    public void Fetch(string workspacePath, string remoteName = "origin")
    {
        using var repo = OpenRepository(workspacePath);
        var remote = repo.Network.Remotes[remoteName] ?? throw new InvalidOperationException($"Remote not found: {remoteName}");
        var refSpecs = remote.FetchRefSpecs.Select(spec => spec.Specification);
        Commands.Fetch(repo, remote.Name, refSpecs, new FetchOptions(), null);
    }

    public void Pull(string workspacePath, string authorName, string authorEmail)
    {
        using var repo = OpenRepository(workspacePath);
        var signature = new Signature(authorName, authorEmail, DateTimeOffset.Now);
        Commands.Pull(repo, signature, new PullOptions { FetchOptions = new FetchOptions() });
    }

    public void PushCurrentBranch(string workspacePath)
    {
        using var repo = OpenRepository(workspacePath);
        repo.Network.Push(repo.Head, new PushOptions());
    }

    public void PublishCurrentBranch(string workspacePath, string remoteName = "origin")
    {
        using var repo = OpenRepository(workspacePath);
        var remote = repo.Network.Remotes[remoteName] ?? throw new InvalidOperationException($"Remote not found: {remoteName}");
        var branch = repo.Head;
        repo.Branches.Update(branch, updater =>
        {
            updater.Remote = remote.Name;
            updater.UpstreamBranch = branch.CanonicalName;
        });
        repo.Network.Push(branch, new PushOptions());
    }

    public IReadOnlyList<GitRemoteSnapshot> Remotes(string workspacePath)
    {
        using var repo = OpenRepository(workspacePath);
        return repo.Network.Remotes.Select(remote => new GitRemoteSnapshot(remote.Name, remote.Url)).ToList();
    }

    public void Discard(string workspacePath, IEnumerable<string> paths)
    {
        using var repo = OpenRepository(workspacePath);
        var root = repo.Info.WorkingDirectory;
        foreach (var path in paths)
        {
            var normalized = path.Replace('\\', '/');
            var fullPath = Path.Combine(root, normalized);
            var entry = repo.Head.Tip?[normalized];
            if (entry is null)
            {
                if (File.Exists(fullPath)) File.Delete(fullPath);
                else if (Directory.Exists(fullPath)) Directory.Delete(fullPath, recursive: true);
                continue;
            }

            if (entry.TargetType != TreeEntryTargetType.Blob || entry.Target is not Blob blob) continue;
            Directory.CreateDirectory(Path.GetDirectoryName(fullPath)!);
            using var content = blob.GetContentStream();
            using var output = File.Create(fullPath);
            content.CopyTo(output);
        }
    }

    public void DeleteUntracked(string workspacePath, IEnumerable<string>? paths = null)
    {
        using var repo = OpenRepository(workspacePath);
        var root = repo.Info.WorkingDirectory;
        var requested = paths?.Select(path => path.Replace('\\', '/')).ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var entry in repo.RetrieveStatus(new StatusOptions()).Where(entry => entry.State.HasFlag(FileStatus.NewInWorkdir)))
        {
            if (requested is not null && !requested.Contains(entry.FilePath.Replace('\\', '/'))) continue;
            var fullPath = Path.Combine(root, entry.FilePath);
            if (File.Exists(fullPath)) File.Delete(fullPath);
            else if (Directory.Exists(fullPath)) Directory.Delete(fullPath, recursive: true);
        }
    }

    private static Repository OpenRepository(string workspacePath)
    {
        var discovered = Repository.Discover(workspacePath);
        if (string.IsNullOrWhiteSpace(discovered))
        {
            throw new InvalidOperationException($"No Git repository found at or above {workspacePath}");
        }

        return new Repository(discovered);
    }
}
