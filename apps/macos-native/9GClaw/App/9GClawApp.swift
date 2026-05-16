import SwiftUI

@main
struct NineGClawApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .frame(minWidth: 1120, minHeight: 720)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(state.t(.newSession)) {
                    state.startNewSession()
                }
                .keyboardShortcut("n", modifiers: [.command])
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
                .frame(width: 760, height: 560)
        }
    }
}
