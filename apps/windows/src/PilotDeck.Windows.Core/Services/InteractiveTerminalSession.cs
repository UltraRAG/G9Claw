using System.Diagnostics;
using System.Text;

namespace PilotDeck.Windows.Core;

public sealed class InteractiveTerminalSession : IAsyncDisposable
{
    private readonly Process _process;
    private readonly StringBuilder _output = new();

    public Guid Id { get; } = Guid.NewGuid();
    public string Cwd { get; }
    public bool HasExited => _process.HasExited;
    public string Output => _output.ToString();

    private InteractiveTerminalSession(Process process, string cwd)
    {
        _process = process;
        Cwd = cwd;
        _process.OutputDataReceived += (_, args) =>
        {
            if (args.Data is not null) _output.AppendLine(args.Data);
        };
        _process.ErrorDataReceived += (_, args) =>
        {
            if (args.Data is not null) _output.AppendLine(args.Data);
        };
    }

    public static InteractiveTerminalSession Start(string cwd)
    {
        var workingDirectory = AgentToolExecutor.ValidatedWorkingDirectory(cwd);
        var psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            WorkingDirectory = workingDirectory,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        psi.ArgumentList.Add("-NoLogo");
        psi.ArgumentList.Add("-NoProfile");
        psi.ArgumentList.Add("-ExecutionPolicy");
        psi.ArgumentList.Add("Bypass");

        var process = new Process { StartInfo = psi, EnableRaisingEvents = true };
        process.Start();
        var session = new InteractiveTerminalSession(process, workingDirectory);
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        return session;
    }

    public Task SendInputAsync(string input)
    {
        if (_process.HasExited) throw new InvalidOperationException("Terminal session has exited.");
        _process.StandardInput.WriteLine(input);
        _process.StandardInput.Flush();
        return Task.CompletedTask;
    }

    public void Resize(int columns, int rows)
    {
        if (columns <= 0 || rows <= 0) throw new ArgumentOutOfRangeException(nameof(columns), "Terminal dimensions must be positive.");
        // Windows process redirection does not expose ConPTY resize directly; UI keeps these values for layout.
    }

    public async ValueTask DisposeAsync()
    {
        try
        {
            if (!_process.HasExited)
            {
                _process.StandardInput.WriteLine("exit");
                if (!await WaitForExitAsync(TimeSpan.FromSeconds(2)))
                {
                    _process.Kill(entireProcessTree: true);
                }
            }
        }
        finally
        {
            _process.Dispose();
        }
    }

    private async Task<bool> WaitForExitAsync(TimeSpan timeout)
    {
        using var cts = new CancellationTokenSource(timeout);
        try
        {
            await _process.WaitForExitAsync(cts.Token);
            return true;
        }
        catch (OperationCanceledException)
        {
            return false;
        }
    }
}
