using PilotDeck.Windows.Core;
using Microsoft.UI.Xaml;

namespace PilotDeck.Windows;

public partial class App : Application
{
    private Window? _window;

    public App()
    {
        InitializeComponent();
        UnhandledException += (_, args) =>
        {
            try
            {
                var path = Path.Combine(AppPaths.Current().LogsDirectory, "unhandled.log");
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                File.AppendAllText(path, $"{DateTimeOffset.Now:O} {args.Exception}\n\n");
            }
            catch
            {
                // Best-effort crash logging only.
            }
        };
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        AppPaths.EnsureCreated();
        _window = new MainWindow();
        _window.Activate();
    }
}
