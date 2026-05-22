using System.Security.Cryptography;
using System.Text;
using System.Runtime.Versioning;

namespace G9Claw.Windows.Core;

public interface ICredentialStore
{
    Task<string?> ReadSecretAsync(string account, CancellationToken cancellationToken = default);
    Task WriteSecretAsync(string account, string secret, CancellationToken cancellationToken = default);
    Task DeleteSecretAsync(string account, CancellationToken cancellationToken = default);
}

public sealed class DpapiCredentialStore : ICredentialStore
{
    private readonly string _directory;
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("G9Claw.Windows.Native");

    public DpapiCredentialStore(string? directory = null)
    {
        _directory = directory ?? AppPaths.Current().CredentialsDirectory;
    }

    public async Task<string?> ReadSecretAsync(string account, CancellationToken cancellationToken = default)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("DPAPI credential storage is only supported on Windows.");
        var file = FileFor(account);
        if (!File.Exists(file)) return null;
        var protectedBytes = await File.ReadAllBytesAsync(file, cancellationToken);
        var plainBytes = Unprotect(protectedBytes);
        return Encoding.UTF8.GetString(plainBytes);
    }

    public async Task WriteSecretAsync(string account, string secret, CancellationToken cancellationToken = default)
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("DPAPI credential storage is only supported on Windows.");
        Directory.CreateDirectory(_directory);
        var plainBytes = Encoding.UTF8.GetBytes(secret);
        var protectedBytes = Protect(plainBytes);
        await File.WriteAllBytesAsync(FileFor(account), protectedBytes, cancellationToken);
    }

    public Task DeleteSecretAsync(string account, CancellationToken cancellationToken = default)
    {
        var file = FileFor(account);
        if (File.Exists(file)) File.Delete(file);
        return Task.CompletedTask;
    }

    private string FileFor(string account)
    {
        if (string.IsNullOrWhiteSpace(account)) throw new ArgumentException("Credential account is required.", nameof(account));
        return Path.Combine(_directory, $"{PathHelpers.SafeFileToken(account)}.bin");
    }

    [SupportedOSPlatform("windows")]
    private static byte[] Protect(byte[] plainBytes) =>
        ProtectedData.Protect(plainBytes, Entropy, DataProtectionScope.CurrentUser);

    [SupportedOSPlatform("windows")]
    private static byte[] Unprotect(byte[] protectedBytes) =>
        ProtectedData.Unprotect(protectedBytes, Entropy, DataProtectionScope.CurrentUser);
}
