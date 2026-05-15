import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        TabView {
            providerTab
                .tabItem {
                    Label("Provider", systemImage: "network")
                }

            workspaceTab
                .tabItem {
                    Label("Workspace", systemImage: "folder")
                }

            parityTab
                .tabItem {
                    Label("Parity", systemImage: "checklist")
                }
        }
        .padding(18)
    }

    private var providerTab: some View {
        Form {
            Picker("Provider", selection: providerBinding) {
                ForEach(SessionProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }

            Picker("API Type", selection: apiTypeBinding) {
                ForEach(ProviderAPIType.allCases) { type in
                    Text(type.rawValue).tag(type)
                }
            }

            TextField("Base URL", text: baseURLBinding)
            TextField("Model", text: modelBinding)
            SecureField("API Key", text: $state.apiKeyDraft)

            HStack {
                Spacer()
                Button("Save") {
                    state.saveSettings()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
    }

    private var workspaceTab: some View {
        Form {
            TextField("Workspaces root", text: workspacesRootBinding)
            Picker("Project sort", selection: projectSortBinding) {
                ForEach(ProjectSortOrder.allCases) { order in
                    Text(order.rawValue).tag(order)
                }
            }
            Picker("Appearance", selection: colorSchemeBinding) {
                ForEach(AppColorScheme.allCases) { scheme in
                    Text(scheme.rawValue).tag(scheme)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var parityTab: some View {
        List(ParityCatalog.modules) { item in
            VStack(alignment: .leading, spacing: 8) {
                Text(item.swiftModule)
                    .font(.system(size: 14, weight: .semibold))
                Text(item.legacySources.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DesignTokens.secondaryText)
                ForEach(item.acceptance, id: \.self) { acceptance in
                    Label(acceptance, systemImage: "circle")
                        .font(.system(size: 12))
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var providerBinding: Binding<SessionProvider> {
        Binding(
            get: { state.settings.providerConfig.provider },
            set: { state.settings.providerConfig.provider = $0 }
        )
    }

    private var apiTypeBinding: Binding<ProviderAPIType> {
        Binding(
            get: { state.settings.providerConfig.apiType },
            set: { state.settings.providerConfig.apiType = $0 }
        )
    }

    private var baseURLBinding: Binding<String> {
        Binding(
            get: { state.settings.providerConfig.baseURL },
            set: { state.settings.providerConfig.baseURL = $0 }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { state.settings.providerConfig.model },
            set: { state.settings.providerConfig.model = $0 }
        )
    }

    private var workspacesRootBinding: Binding<String> {
        Binding(
            get: { state.settings.workspacesRoot },
            set: { state.settings.workspacesRoot = $0 }
        )
    }

    private var projectSortBinding: Binding<ProjectSortOrder> {
        Binding(
            get: { state.settings.projectSortOrder },
            set: { state.settings.projectSortOrder = $0 }
        )
    }

    private var colorSchemeBinding: Binding<AppColorScheme> {
        Binding(
            get: { state.settings.colorScheme },
            set: { state.settings.colorScheme = $0 }
        )
    }
}
