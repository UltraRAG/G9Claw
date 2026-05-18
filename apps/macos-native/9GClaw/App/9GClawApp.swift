import AppKit
import SwiftUI

@main
struct NineGClawApp: App {
    @StateObject private var state = AppState()

    init() {
        AppLifecycleDiagnostics.install()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .frame(minWidth: 1120, minHeight: 720)
                .background(WindowChromeConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(state.t(.newSession)) {
                    state.startNewSession()
                }
                .keyboardShortcut("n", modifiers: [.command])
            }

            CommandGroup(replacing: .appSettings) {
                Button(state.t(.settings)) {
                    state.openSettings(.appearance)
                    SettingsWindowPresenter.openAndBringToFront()
                }
                .keyboardShortcut(",", modifiers: [.command])
            }

            CommandMenu("9GClaw") {
                Button(state.t(.refreshProjects)) {
                    Task { await state.refreshProjects() }
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button(state.t(.stopGeneration)) {
                    state.abortActiveRun()
                }
                .keyboardShortcut(".", modifiers: [.command])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(state)
                .frame(width: 920, height: 640)
        }
    }
}

@MainActor
enum SettingsWindowPresenter {
    static let identifier = NSUserInterfaceItemIdentifier("9GClawSettingsWindow")

    static func configure(window: NSWindow?) {
        guard let window else { return }
        window.identifier = identifier
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 860, height: 620)
    }

    static func openAndBringToFront() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        bringToFront()
    }

    static func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow(in: NSApp.windows)?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            NSApp.activate(ignoringOtherApps: true)
            settingsWindow(in: NSApp.windows)?.makeKeyAndOrderFront(nil)
        }
    }

    static func settingsWindow(in windows: [NSWindow]) -> NSWindow? {
        windows.first { $0.identifier == identifier }
    }
}

struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            SettingsWindowPresenter.configure(window: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            SettingsWindowPresenter.configure(window: nsView.window)
        }
    }
}

@MainActor
private enum AppLifecycleDiagnostics {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        let process = ProcessInfo.processInfo
        let environment = process.environment
        let xcodeFlag = environment["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] != nil || environment["XCODE_RUNNING_FOR_PREVIEWS"] != nil
        AppLog.write(
            "launch pid=\(process.processIdentifier) bundle=\(Bundle.main.bundleIdentifier ?? "unknown") path=\(Bundle.main.bundlePath) xcode=\(xcodeFlag)"
        )
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            AppLog.write("willTerminate pid=\(ProcessInfo.processInfo.processIdentifier)")
        }
    }
}

private struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            configure(window: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(window: nsView.window)
        }
    }

    private func configure(window: NSWindow?) {
        guard let window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
    }
}
