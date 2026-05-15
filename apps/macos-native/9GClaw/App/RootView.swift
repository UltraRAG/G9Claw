import SwiftUI

struct RootView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HSplitView {
            if state.isSidebarVisible {
                SidebarView()
                    .environmentObject(state)
                    .frame(minWidth: 280, idealWidth: 318, maxWidth: 380)
            }

            MainAreaView()
                .environmentObject(state)
                .frame(minWidth: 760)
        }
        .background(DesignTokens.background)
        .task {
            await state.bootstrap()
        }
    }
}
