import AppKit
import SwiftUI

@main
struct PilotDeckApp: App {
    @StateObject private var state = AppState()

    init() {
        AppLifecycleDiagnostics.install()
        MenuBarSanitizer.install()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .frame(minWidth: 1120, minHeight: 720)
                .background(WindowChromeConfigurator())
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    state.shutdownForTermination()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About PilotDeck") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: "PilotDeck",
                        .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                        .version: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
                    ])
                }
            }

            CommandGroup(replacing: .newItem) {
                Button {
                    state.startNewSession()
                } label: {
                    Text(verbatim: "New Chat")
                }
                .keyboardShortcut("n", modifiers: [.command])
            }

            CommandGroup(replacing: .appSettings) {
                Button {
                    state.openSettings(.appearance)
                } label: {
                    Text(state.t(.settings))
                }
                .keyboardShortcut(",", modifiers: [.command])
            }

            CommandGroup(replacing: .saveItem) {}
            CommandGroup(replacing: .importExport) {}
            CommandGroup(replacing: .printItem) {}

            CommandGroup(after: .newItem) {
                Button {
                    Task { await state.refreshProjects() }
                } label: {
                    Text(verbatim: "Refresh")
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button {
                    state.abortActiveRun()
                } label: {
                    Text(verbatim: "Stop Generating")
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(!state.isCurrentSessionStreaming)
            }

            CommandGroup(replacing: .help) {
                Button("Home") {
                    PilotDeckHelpLinks.open(.home)
                }

                Button("Documentation") {
                    PilotDeckHelpLinks.open(.docs)
                }

                Button("GitHub") {
                    PilotDeckHelpLinks.open(.github)
                }
            }
        }

    }
}

private enum PilotDeckHelpLinks {
    case home
    case docs
    case github

    private var url: URL {
        switch self {
        case .home:
            URL(string: "https://pilotdeck.openbmb.cn/pilotdeck.github.io/")!
        case .docs:
            URL(string: "https://pilotdeck.openbmb.cn/pilotdeck.github.io/docs/en/introduction")!
        case .github:
            URL(string: "https://github.com/OpenBMB/PilotDeck")!
        }
    }

    static func open(_ link: PilotDeckHelpLinks) {
        NSWorkspace.shared.open(link.url)
    }
}

@MainActor
private enum MenuBarSanitizer {
    private static var installed = false
    private static var observers: [NSObjectProtocol] = []
    private static let fileMenuTitles: Set<String> = [
        "File",
        "文件",
    ]

    static func install() {
        guard !installed else { return }
        installed = true
        let notificationNames: [Notification.Name] = [
            NSApplication.didFinishLaunchingNotification,
            NSApplication.didBecomeActiveNotification,
            NSMenu.didAddItemNotification,
        ]
        observers = notificationNames.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    prune()
                    pruneSoon()
                }
            }
        }
        pruneSoon()
    }

    static func pruneSoon() {
        DispatchQueue.main.async {
            prune()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            prune()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            prune()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            prune()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            prune()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
            prune()
        }
    }

    private static func prune() {
        guard let menu = NSApp.mainMenu else { return }
        for item in menu.items {
            if let submenu = item.submenu {
                pruneSeparators(in: submenu)
                if fileMenuTitles.contains(item.title) {
                    pruneFileMenu(submenu)
                }
            }
        }
    }

    private static func pruneSeparators(in menu: NSMenu) {
        while let first = menu.items.first, isPrunableSeparator(first) {
            menu.removeItem(first)
        }

        while let last = menu.items.last, isPrunableSeparator(last) {
            menu.removeItem(last)
        }

        var index = 1
        while index < menu.items.count {
            let previous = menu.items[index - 1]
            let current = menu.items[index]
            if isPrunableSeparator(previous), isPrunableSeparator(current) {
                menu.removeItem(at: index)
            } else {
                index += 1
            }
        }
    }

    private static func isPrunableSeparator(_ item: NSMenuItem) -> Bool {
        item.isSeparatorItem || item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func pruneFileMenu(_ menu: NSMenu) {
        while menu.items.count > 3 {
            menu.removeItem(at: 3)
        }
    }
}

@MainActor
private enum AppLifecycleDiagnostics {
    private static var installed = false
    private static var terminationObserver: NSObjectProtocol?

    static func install() {
        guard !installed else { return }
        installed = true
        let process = ProcessInfo.processInfo
        let environment = process.environment
        let xcodeFlag = environment["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] != nil || environment["XCODE_RUNNING_FOR_PREVIEWS"] != nil
        AppLog.write(
            "launch pid=\(process.processIdentifier) bundle=\(Bundle.main.bundleIdentifier ?? "unknown") path=\(Bundle.main.bundlePath) xcode=\(xcodeFlag)"
        )
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                AppLog.write("willTerminate pid=\(ProcessInfo.processInfo.processIdentifier)")
                if let observer = terminationObserver {
                    NotificationCenter.default.removeObserver(observer)
                    terminationObserver = nil
                }
            }
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
        MenuBarSanitizer.pruneSoon()
        alignTrafficLightButtons(in: window)
    }

    private func alignTrafficLightButtons(in window: NSWindow) {
        let adjustedTag = 9_504
        let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for buttonType in buttonTypes {
            guard let button = window.standardWindowButton(buttonType),
                  button.tag != adjustedTag else { continue }
            var frame = button.frame
            frame.origin.y = max(0, frame.origin.y - DesignTokens.trafficLightVerticalAdjustment)
            button.frame = frame
            button.tag = adjustedTag
        }
    }
}
