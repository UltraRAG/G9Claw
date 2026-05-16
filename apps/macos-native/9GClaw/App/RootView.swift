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
            }

            MainAreaView()
                .environmentObject(state)
                .frame(minWidth: 760, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DesignTokens.background)
        .overlay {
            if state.showSettings {
                SettingsModalView {
                    state.showSettings = false
                }
                .environmentObject(state)
                .transition(.opacity.combined(with: .scale(scale: 0.985)))
            }
            if state.showProjectCreationWizard {
                ProjectCreationWizardView {
                    state.showProjectCreationWizard = false
                }
                .environmentObject(state)
                .transition(.opacity.combined(with: .scale(scale: 0.985)))
            }
        }
        .animation(.easeInOut(duration: 0.20), value: state.showSettings)
        .animation(.easeInOut(duration: 0.20), value: state.showProjectCreationWizard)
        .task {
            await state.bootstrap()
        }
        .onAppear {
            sidebarWidth = min(
                Double(DesignTokens.sidebarMaxWidth),
                max(Double(DesignTokens.sidebarMinWidth), sidebarWidth)
            )
        }
    }
}
