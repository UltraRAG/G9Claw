using System.Diagnostics;
using System.Text;

namespace G9Claw.Windows.Core;

public sealed record TerminalRun(
    Guid Id,
    string Command,
    string Cwd,
    string Output,
    int? ExitCode,
    DateTimeOffset StartedAt,
    DateTimeOffset? EndedAt);

public sealed class TerminalService
{
    public async Task<TerminalRun> RunAsync(
        string command,
        string? cwd = null,
        int timeoutMs = 120_000,
        CancellationToken cancellationToken = default,
        IReadOnlyDictionary<string, string>? environment = null)
    {
        var workingDirectory = string.IsNullOrWhiteSpace(cwd)
            ? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)
            : cwd;
        workingDirectory = AgentToolExecutor.ValidatedWorkingDirectory(workingDirectory);

        var startedAt = DateTimeOffset.UtcNow;
        var output = new StringBuilder();
        var psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = false,
            CreateNoWindow = true,
            WorkingDirectory = workingDirectory,
        };
        if (environment is not null)
        {
            foreach (var (key, value) in environment)
            {
                psi.Environment[key] = value;
            }
        }

        psi.ArgumentList.Add("-NoLogo");
        psi.ArgumentList.Add("-NoProfile");
        psi.ArgumentList.Add("-ExecutionPolicy");
        psi.ArgumentList.Add("Bypass");
        psi.ArgumentList.Add("-Command");
        psi.ArgumentList.Add(command);

        using var process = new Process { StartInfo = psi, EnableRaisingEvents = true };
        process.Start();

        var stdout = process.StandardOutput.ReadToEndAsync(cancellationToken);
        var stderr = process.StandardError.ReadToEndAsync(cancellationToken);
        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutCts.CancelAfter(Math.Max(1_000, timeoutMs));

        try
        {
            await process.WaitForExitAsync(timeoutCts.Token);
        }
        catch (OperationCanceledException)
        {
            try
            {
                if (!process.HasExited) process.Kill(entireProcessTree: true);
            }
            catch
            {
                // Best effort cleanup. The returned run records timeout failure.
            }
        }

        output.Append(await stdout);
        var stderrText = await stderr;
        if (!string.IsNullOrWhiteSpace(stderrText))
        {
            if (output.Length > 0) output.AppendLine();
            output.Append(stderrText);
        }

        var exitCode = process.HasExited ? process.ExitCode : -1;
        if (!process.HasExited)
        {
            output.AppendLine();
            output.Append($"Command timed out after {timeoutMs} ms.");
        }

        return new TerminalRun(
            Guid.NewGuid(),
            command,
            workingDirectory,
            output.ToString(),
            exitCode,
            startedAt,
            DateTimeOffset.UtcNow);
    }
}
