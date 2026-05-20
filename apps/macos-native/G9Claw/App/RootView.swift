import SwiftUI

struct RootView: View {
    @EnvironmentObject private var state: AppState
    @AppStorage("sidebar-v2-width") private var sidebarWidth = Double(DesignTokens.sidebarDefaultWidth)

    var body: some View {
        HStack(spacing: 0) {
            if state.isSidebarVisible {
                SidebarView(width: $sidebarWidth)
                    .environmentObject(state)
                    .frame(width: CGFloat(sidebarWidth))
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            } else {
                CollapsedSidebarRail()
                    .environmentObject(state)
                    .frame(width: DesignTokens.sidebarCollapsedRailWidth)
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }

            MainAreaView()
                .environmentObject(state)
                .frame(minWidth: 760, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background {
            AppGlassWindowBackground()
                .ignoresSafeArea()
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
}

private extension AppColorScheme {
    var swiftUIColorScheme: ColorScheme? {
        switch self {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }
}
