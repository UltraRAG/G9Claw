import SwiftUI

struct RootView: View {
    @EnvironmentObject private var state: AppState
    @AppStorage("sidebar-v2-width") private var sidebarWidth = Double(DesignTokens.sidebarDefaultWidth)

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
        .overlay(alignment: .topLeading) {
            if !state.showProjectCreationWizard {
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
        .animation(.easeInOut(duration: 0.20), value: state.showProjectCreationWizard)
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
        DesignTokens.titlebarSidebarButtonLeading
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
