import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var state: AppState
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if state.currentMessages.isEmpty {
                            emptyState
                        } else {
                            ForEach(state.currentMessages) { message in
                                MessageRow(message: message)
                                    .id(message.id)
                            }
                        }
                    }
                    .padding(.horizontal, 34)
                    .padding(.vertical, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: state.currentMessages.count) { _, _ in
                    if let id = state.currentMessages.last?.id {
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(id, anchor: .bottom)
                        }
                    }
                }
            }

            composer
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Pick a project from the sidebar to get started", systemImage: "message")
                .font(.system(size: 22, weight: .semibold))
            Text("The native Agent tab mirrors the existing 9GClaw conversation surface: project context, session state, streaming output, tool requests, and token status.")
                .foregroundStyle(DesignTokens.secondaryText)
                .frame(maxWidth: 620, alignment: .leading)
        }
        .padding(.top, 80)
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if !state.pendingPermissions.isEmpty {
                PermissionBanner()
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField("Ask 9GClaw", text: $state.composerText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...8)
                    .focused($composerFocused)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous)
                            .fill(DesignTokens.panel)
                    )
                    .onSubmit {
                        state.sendComposerMessage()
                    }

                Button {
                    state.sendComposerMessage()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    state.abortActiveRun()
                } label: {
                    Image(systemName: "stop.fill")
                        .frame(width: 26, height: 30)
                }
                .buttonStyle(.borderless)
                .help("Stop generation")
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        .background(.bar)
    }
}

private struct MessageRow: View {
    var message: ChatMessage

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            avatar
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(message.createdAt, style: .time)
                        .font(.system(size: 11))
                        .foregroundStyle(DesignTokens.tertiaryText)
                    if message.isStreaming {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Spacer()
                    if let budget = message.tokenBudget {
                        Text("\(budget.used)/\(budget.total)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(DesignTokens.secondaryText)
                    }
                }

                ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
            }
            .frame(maxWidth: 860, alignment: .leading)
        }
    }

    private var avatar: some View {
        Circle()
            .fill(message.role == .user ? .blue.opacity(0.16) : DesignTokens.panel)
            .frame(width: 28, height: 28)
            .overlay {
                Image(systemName: message.role == .user ? "person.fill" : "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(message.role == .user ? .blue : DesignTokens.secondaryText)
            }
    }

    private var title: String {
        switch message.role {
        case .user: "You"
        case .assistant: message.provider.displayName
        case .system: "System"
        case .tool: "Tool"
        }
    }

    @ViewBuilder
    private func blockView(_ block: ChatBlock) -> some View {
        switch block {
        case .text(let text):
            Text(text.isEmpty ? " " : text)
                .font(.system(size: 14))
                .textSelection(.enabled)
                .lineSpacing(3)
        case .toolCall(let call):
            ToolBlock(title: call.name, detail: call.inputJSON, systemImage: "hammer", tint: .orange)
        case .toolResult(let result):
            ToolBlock(title: result.isError ? "Tool error" : "Tool result", detail: result.output, systemImage: "checkmark.circle", tint: result.isError ? .red : .green)
        case .attachment(let attachment):
            ToolBlock(title: attachment.fileName, detail: attachment.path, systemImage: "paperclip", tint: .blue)
        }
    }
}

private struct ToolBlock: View {
    var title: String
    var detail: String
    var systemImage: String
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
            Text(detail)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(DesignTokens.secondaryText)
                .lineLimit(12)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous)
                .fill(DesignTokens.panel)
        )
    }
}

private struct PermissionBanner: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(state.pendingPermissions) { request in
                HStack {
                    Label(request.toolName, systemImage: "hand.raised")
                    Text(request.reason)
                        .foregroundStyle(DesignTokens.secondaryText)
                    Spacer()
                    Button("Deny") {}
                    Button("Allow") {}
                        .buttonStyle(.borderedProminent)
                }
                .font(.system(size: 12))
            }
        }
        .padding(.horizontal, 24)
    }
}
