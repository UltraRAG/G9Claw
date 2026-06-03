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
