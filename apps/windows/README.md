# G9Claw Native Windows

Native Windows desktop implementation for G9Claw.

This app follows the native macOS parity target in `apps/macos-native/`:

- no Electron, Tauri, React desktop host, WebView2, Node, Bun, or localhost server;
- WinUI 3 shell with a native C# runtime;
- self-contained Windows App SDK and .NET publish output;
- installer output via MSI / setup bootstrapper;
- user secrets stored outside plain text configuration.

## Layout

```text
apps/windows/
  src/G9Claw.Windows.Core/   # Native runtime, models, tools, settings, providers
  src/G9Claw.Windows/        # WinUI 3 app shell
  tests/G9Claw.Windows.Tests # Parity and Windows safety tests
  installer/                 # WiX installer scaffold
```

## Build

Requires a Windows machine with .NET 10 SDK and Visual Studio/Windows App SDK
workloads installed.

```powershell
cd apps/windows
dotnet restore
dotnet build .\G9Claw.Windows.sln -c Debug
dotnet test .\G9Claw.Windows.sln -c Debug
dotnet publish .\src\G9Claw.Windows\G9Claw.Windows.csproj -c Release -r win-x64 --self-contained true
dotnet build .\installer\G9Claw.Windows.Installer.wixproj -c Release
```

`G9Claw.Windows.sln` intentionally contains only the WinUI app, core library,
and tests so Visual Studio 2026 can open and build it without a WiX extension.
Build the WiX installer project from the command line with `dotnet build`.
If Visual Studio still says it cannot start a class library, set
`G9Claw.Windows` as the startup project. Older `.vs/` state can keep pointing at
`G9Claw.Windows.Core` from before the solution order was corrected.

The app stores runtime data under `%LOCALAPPDATA%\G9Claw`.

The WinUI app targets the installed Windows SDK API contract
`net10.0-windows10.0.26100.0` while keeping `TargetPlatformMinVersion` at
Windows 10 22H2 (`10.0.19045.0`). Release publish removes unused WebView2
runtime files so the installer does not ship a WebView2 host/runtime.
