using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using G9Claw.Windows.Core;
using System.Security;
using XamlPath = Microsoft.UI.Xaml.Shapes.Path;

namespace G9Claw.Windows;

public static class V2IconCatalog
{
    public static IReadOnlySet<string> RequiredKeys => LucideIconCatalog.RequiredKeys;

    public static bool HasIcon(string key) => LucideIconCatalog.HasIcon(key);

    public static FrameworkElement Icon(string key, double size, Brush foreground)
    {
        if (!LucideIconCatalog.HasIcon(key))
        {
            throw new ArgumentException($"Unknown lucide icon key '{key}'. Add it to V2IconCatalog before using it.", nameof(key));
        }

        var canvas = new Canvas
        {
            Width = 24,
            Height = 24,
        };

        foreach (var pathData in PathData(key))
        {
            var path = CreatePath(pathData);
            path.Stroke = foreground;
            canvas.Children.Add(path);
        }

        return new Viewbox
        {
            Width = size,
            Height = size,
            Child = canvas,
            Stretch = Stretch.Uniform,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
    }

    private static XamlPath CreatePath(string data)
    {
        var escaped = SecurityElement.Escape(data) ?? string.Empty;
        var path = (XamlPath)XamlReader.Load(
            $"""<Path xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Data="{escaped}" />""");
        path.Fill = null;
        path.StrokeThickness = 1.75;
        path.StrokeStartLineCap = PenLineCap.Round;
        path.StrokeEndLineCap = PenLineCap.Round;
        path.StrokeLineJoin = PenLineJoin.Round;
        return path;
    }

    private static string[] PathData(string key) => key switch
    {
        "ArrowUp" => ["M12 19V5", "M5 12l7-7 7 7"],
        "AtSign" => ["M16 8a6 6 0 1 0 1.6 4.1L16 8v4a4 4 0 1 1-4-4", "M12 12a2 2 0 1 0 0-4 2 2 0 0 0 0 4"],
        "BarChart" or "BarChart3" => ["M3 3v18h18", "M18 17V9", "M13 17V5", "M8 17v-3"],
        "Bot" => ["M12 8V4H8", "M6 8h12a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2v-8a2 2 0 0 1 2-2", "M2 14h2", "M20 14h2", "M15 13v2", "M9 13v2"],
        "ChevronDown" => ["M6 9l6 6 6-6"],
        "ChevronRight" => ["M9 18l6-6-6-6"],
        "ChevronUp" => ["M18 15l-6-6-6 6"],
        "Chevrons" => ["M7 7l5 5 5-5", "M7 13l5 5 5-5"],
        "Database" => ["M12 3c4.97 0 9 1.79 9 4s-4.03 4-9 4-9-1.79-9-4 4.03-4 9-4", "M3 7v10c0 2.21 4.03 4 9 4s9-1.79 9-4V7", "M3 12c0 2.21 4.03 4 9 4s9-1.79 9-4"],
        "Document" or "File" => ["M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z", "M14 2v6h6", "M16 13H8", "M16 17H8", "M10 9H8"],
        "Download" => ["M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4", "M7 10l5 5 5-5", "M12 15V3"],
        "Edit" => ["M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7", "M18.5 2.5a2.12 2.12 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z"],
        "Folder" => ["M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.7-.9L9.6 3.9A2 2 0 0 0 7.9 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2z"],
        "FolderPlus" => ["M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.7-.9L9.6 3.9A2 2 0 0 0 7.9 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2z", "M12 10v6", "M9 13h6"],
        "Gear" or "Settings" => ["M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.38a2 2 0 0 0-.73-2.73l-.15-.09a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z", "M9 12a3 3 0 1 0 6 0 3 3 0 0 0-6 0"],
        "GitBranch" => ["M6 3v12", "M18 9a3 3 0 1 0 0-6 3 3 0 0 0 0 6", "M6 21a3 3 0 1 0 0-6 3 3 0 0 0 0 6", "M18 9a9 9 0 0 1-9 9"],
        "MessageSquarePlus" => ["M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z", "M12 7v6", "M9 10h6"],
        "PanelLeftClose" => ["M3 3h18v18H3z", "M9 3v18", "M16 15l-3-3 3-3"],
        "PanelLeftOpen" => ["M3 3h18v18H3z", "M9 3v18", "M14 9l3 3-3 3"],
        "Play" => ["M5 5v14l14-7z"],
        "Plus" => ["M5 12h14", "M12 5v14"],
        "Radio" => ["M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8", "M16.24 7.76a6 6 0 0 1 0 8.49", "M7.76 16.24a6 6 0 0 1 0-8.49", "M20.49 3.51a12 12 0 0 1 0 16.97", "M3.51 20.49a12 12 0 0 1 0-16.97"],
        "Refresh" => ["M3 12a9 9 0 0 1 15-6.7L21 8", "M21 3v5h-5", "M21 12a9 9 0 0 1-15 6.7L3 16", "M3 21v-5h5"],
        "Sparkles" => ["M12 3l1.9 5.7L20 11l-6.1 2.3L12 19l-1.9-5.7L4 11l6.1-2.3z", "M5 3v4", "M3 5h4", "M19 17v4", "M17 19h4"],
        "Stop" or "Square" => ["M6 6h12v12H6z"],
        "Terminal" or "terminal" => ["M4 17l6-6-6-6", "M12 19h8"],
        "Trash" => ["M3 6h18", "M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2", "M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6", "M10 11v6", "M14 11v6"],
        "Upload" => ["M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4", "M17 8l-5-5-5 5", "M12 3v12"],
        "X" => ["M18 6 6 18", "M6 6l12 12"],
        "Palette" => ["M12 22a10 10 0 1 1 10-10 4 4 0 0 1-4 4h-1.5a2 2 0 0 0-1.4 3.4l.3.3A1.4 1.4 0 0 1 14.4 22z", "M6.5 11a.5.5 0 1 0 0-1 .5.5 0 0 0 0 1", "M9.5 7a.5.5 0 1 0 0-1 .5.5 0 0 0 0 1", "M14.5 7a.5.5 0 1 0 0-1 .5.5 0 0 0 0 1", "M17.5 11a.5.5 0 1 0 0-1 .5.5 0 0 0 0 1"],
        "Shield" => ["M20 13c0 5-3.5 7.5-8 9-4.5-1.5-8-4-8-9V5l8-3 8 3z"],
        "FileCog" => ["M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z", "M14 2v6h6", "M10.3 13.3l.4-1.3h2.6l.4 1.3 1.2.7-.6 1.2.6 1.2-1.2.7-.4 1.3h-2.6l-.4-1.3-1.2-.7.6-1.2-.6-1.2z", "M12 14.5a.7.7 0 1 0 0 1.4.7.7 0 0 0 0-1.4"],
        "Save" => ["M19 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11l5 5v11a2 2 0 0 1-2 2z", "M17 21v-8H7v8", "M7 3v5h8"],
        "AlertCircle" => ["M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20", "M12 8v4", "M12 16h.01"],
        "Info" => ["M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20", "M12 16v-4", "M12 8h.01"],
        "Hammer" => ["M15 12l-8.5 8.5a2.1 2.1 0 0 1-3-3L12 9", "M17.6 9.4l-5-5L15 2l5 5z", "M12 4l8 8"],
        "Image" => ["M21 19V5a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2z", "M8.5 11.5a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5", "M21 15l-5-5L5 21"],
        "CheckCircle" => ["M22 11.08V12a10 10 0 1 1-5.93-9.14", "M22 4 12 14.01l-3-3"],
        "XCircle" => ["M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20", "M15 9l-6 6", "M9 9l6 6"],
        "Code" => ["M16 18l6-6-6-6", "M8 6l-6 6 6 6"],
        "Command" => ["M8 5v14", "M16 5v14", "M5 8h14", "M5 16h14"],
        "CircleGauge" => ["M4 17 C2 12 4 6 9 4 C14 2 20 5 21 11", "M12 12l4-4", "M12 12h.01"],
        "Paperclip" => ["M21.44 11.05l-9.19 9.19a6 6 0 0 1-8.49-8.49l9.19-9.19a4 4 0 0 1 5.66 5.66l-8.49 8.49a2 2 0 0 1-2.83-2.83l8.49-8.48"],
        "Copy" => ["M8 8h10a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2V10a2 2 0 0 1 2-2", "M16 8V6a2 2 0 0 0-2-2H4a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h2"],
        "Eye" or "eye" => ["M2 12s3-7 10-7 10 7 10 7-3 7-10 7-10-7-10-7", "M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6"],
        "LayoutList" => ["M8 6h13", "M8 12h13", "M8 18h13", "M3 6h.01", "M3 12h.01", "M3 18h.01"],
        "ListChecks" or "checklist" => ["M10 6h11", "M10 12h11", "M10 18h11", "M3 6l1 1 3-3", "M3 12l1 1 3-3", "M3 18l1 1 3-3"],
        _ => throw new ArgumentException($"Unknown lucide icon key '{key}'.", nameof(key)),
    };
}
