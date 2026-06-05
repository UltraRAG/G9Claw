@preconcurrency import AppKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var state: AppState
    @AppStorage("sidebar-v2-width") private var sidebarWidth = Double(DesignTokens.sidebarDefaultWidth)
    @State private var isWindowFullScreen = false

    var body: some View {
        HStack(spacing: 0) {
            sidebarHost

            MainAreaView()
                .environmentObject(state)
                .frame(minWidth: 760, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background {
            AppGlassWindowBackground()
                .ignoresSafeArea()
        }
        .background {
            WindowFullScreenStateReader(isFullScreen: $isWindowFullScreen)
        }
        .background {
            TitlebarDoubleClickZoomReader()
        }
        .overlay(alignment: .topLeading) {
            if !state.showProjectCreationWizard && !state.showSettings {
                SidebarTitlebarToggleButton()
                    .environmentObject(state)
                    .padding(.leading, sidebarToggleLeadingOffset)
                    .padding(.top, DesignTokens.titlebarControlTop)
                    .transition(.opacity)
                    .zIndex(20)
            }
        }
        .overlay {
            if state.showProjectCreationWizard {
                ProjectCreationWizardView {
                    state.showProjectCreationWizard = false
                }
                .environmentObject(state)
                .transition(.opacity.combined(with: .scale(scale: 0.985)))
            }
        }
        .overlay {
            if state.showSettings {
                SettingsView(isEmbeddedInMainWindow: true) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        state.closeSettings()
                    }
                }
                .environmentObject(state)
                .preferredColorScheme(state.settings.colorScheme.swiftUIColorScheme)
                .transition(.opacity)
                .zIndex(50)
            }
        }
        .animation(.easeInOut(duration: 0.20), value: state.showProjectCreationWizard)
        .animation(.easeInOut(duration: 0.18), value: state.showSettings)
        .animation(.snappy(duration: 0.28, extraBounce: 0.02), value: state.isSidebarVisible)
        .task {
            await state.bootstrap()
        }
        .preferredColorScheme(state.settings.colorScheme.swiftUIColorScheme)
        .ignoresSafeArea(.container, edges: .top)
        .onAppear {
            sidebarWidth = min(
                Double(DesignTokens.sidebarMaxWidth),
                max(Double(DesignTokens.sidebarMinWidth), sidebarWidth)
            )
        }
    }

    private var sidebarHost: some View {
        let contentWidth = CGFloat(sidebarWidth)
        let slotWidth = state.isSidebarVisible ? contentWidth : 0

        return ZStack(alignment: .leading) {
            SidebarView(width: $sidebarWidth)
                .environmentObject(state)
                .frame(width: contentWidth)
                .offset(x: state.isSidebarVisible ? 0 : -contentWidth)
                .allowsHitTesting(state.isSidebarVisible)
                .accessibilityHidden(!state.isSidebarVisible)
        }
        .frame(width: slotWidth, alignment: .leading)
        .frame(maxHeight: .infinity)
        .clipped()
    }

    private var sidebarToggleLeadingOffset: CGFloat {
        isWindowFullScreen
            ? DesignTokens.titlebarSidebarButtonFullscreenLeading
            : DesignTokens.titlebarSidebarButtonLeading
    }
}

private struct TitlebarDoubleClickZoomReader: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            context.coordinator.attach(to: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.attach(to: nsView)
        }
    }

    @MainActor
    final class Coordinator: @unchecked Sendable {
        private weak var view: NSView?
        private var eventMonitor: EventMonitorBox?

        func attach(to view: NSView) {
            self.view = view
            guard eventMonitor == nil else { return }

            guard let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] event in
                self?.handle(event) ?? event
            }) else { return }
            eventMonitor = EventMonitorBox(monitor)
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard event.clickCount == 2,
                  let view,
                  let window = view.window,
                  event.window === window,
                  shouldHandle(event, in: window)
            else {
                return event
            }

            performTitlebarDoubleClickAction(in: window)
            return nil
        }

        private func shouldHandle(_ event: NSEvent, in window: NSWindow) -> Bool {
            guard !window.styleMask.contains(.fullScreen) else { return false }

            let point = event.locationInWindow
            let titlebarHeight = DesignTokens.headerHeight + 6
            guard point.y >= window.frame.height - titlebarHeight else { return false }

            // Leave the traffic lights and custom sidebar toggle alone. Double-clicking
            // the rest of our hidden-titlebar strip should behave like a native titlebar.
            let protectedLeadingWidth = DesignTokens.titlebarSidebarButtonLeading
                + DesignTokens.titlebarControlSize
                + 18
            return point.x > protectedLeadingWidth
        }

        private func performTitlebarDoubleClickAction(in window: NSWindow) {
            let action = titlebarDoubleClickAction()
            switch action {
            case "minimize":
                window.performMiniaturize(nil)
            case "none":
                break
            default:
                window.performZoom(nil)
            }
        }

        private func titlebarDoubleClickAction() -> String {
            let globalValue = UserDefaults.standard
                .persistentDomain(forName: UserDefaults.globalDomain)?["AppleActionOnDoubleClick"] as? String
            let value = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? globalValue
            return value?.lowercased() ?? "maximize"
        }
    }

    private final class EventMonitorBox: @unchecked Sendable {
        private let monitor: Any

        init(_ monitor: Any) {
            self.monitor = monitor
        }

        deinit {
            NSEvent.removeMonitor(monitor)
        }
    }
}

private struct WindowFullScreenStateReader: NSViewRepresentable {
    @Binding var isFullScreen: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isFullScreen: $isFullScreen)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            context.coordinator.attach(to: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.attach(to: nsView.window)
        }
    }

    @MainActor
    final class Coordinator: @unchecked Sendable {
        private var isFullScreen: Binding<Bool>
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []

        init(isFullScreen: Binding<Bool>) {
            self.isFullScreen = isFullScreen
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        func attach(to window: NSWindow?) {
            guard self.window !== window else {
                sync()
                return
            }
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            self.window = window
            guard let window else {
                isFullScreen.wrappedValue = false
                return
            }

            let names: [Notification.Name] = [
                NSWindow.didEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification,
                NSWindow.didResizeNotification,
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(
                    forName: name,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in
                        self?.sync()
                    }
                }
            }
            sync()
        }

        private func sync() {
            isFullScreen.wrappedValue = window?.styleMask.contains(.fullScreen) == true
        }
    }
}

private struct SidebarTitlebarToggleButton: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.28, extraBounce: 0.02)) {
                state.setSidebarVisible(!state.isSidebarVisible)
            }
        } label: {
            TitlebarSidebarGlyph()
                .frame(width: DesignTokens.titlebarControlSize, height: DesignTokens.titlebarControlSize)
        }
        .buttonStyle(TitlebarIconButtonStyle())
        .help(state.isSidebarVisible ? state.t(.hideSidebar) : state.t(.showSidebar))
    }
}

private struct TitlebarSidebarGlyph: View {
    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .stroke(DesignTokens.mutedForeground, lineWidth: 1.25)
                .frame(width: DesignTokens.titlebarSidebarGlyphSize, height: DesignTokens.titlebarSidebarGlyphSize)

            Capsule(style: .continuous)
                .fill(DesignTokens.mutedForeground)
                .frame(width: 1.25, height: DesignTokens.titlebarSidebarGlyphSize * 0.5)
                .padding(.leading, DesignTokens.titlebarSidebarGlyphSize * 0.28)
        }
        .frame(
            width: DesignTokens.titlebarSidebarGlyphSize,
            height: DesignTokens.titlebarSidebarGlyphSize
        )
    }
}

private struct TitlebarIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(DesignTokens.mutedForeground)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                    .fill(configuration.isPressed ? DesignTokens.neutral100.opacity(0.76) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}
