import AppKit
import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        conversationBody
        .background(DesignTokens.background)
    }

    private var conversationBody: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 32) {
                        if state.currentMessages.isEmpty {
                            emptyPromptBlock
                                .id("empty-prompt")
                        } else {
                            ForEach(state.currentMessages) { message in
                                MessageRow(message: message)
                                    .id(message.id)
                            }
                        }
                        if !state.currentActivities.isEmpty {
                            ProcessLiveStatusRow(activities: state.currentActivities)
                                .id("process-live-status")
                        }
                    }
                    .padding(.horizontal, 48)
                    .padding(.top, 32)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.automatic)
                .onChange(of: state.currentMessages.count) { _, _ in
                    if let id = state.currentMessages.last?.id {
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: state.currentActivities.count) { _, _ in
                    guard !state.currentActivities.isEmpty else { return }
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo("process-live-status", anchor: .bottom)
                    }
                }
            }

            ComposerFooter()
                .environmentObject(state)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyPromptBlock: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Text("What would you like to work on today?")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(DesignTokens.text)
                .multilineTextAlignment(.center)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 360)
    }
}

private struct ComposerFooter: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            if !state.pendingPermissions.isEmpty {
                PermissionBanner()
                    .environmentObject(state)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
            }

            ComposerCard(chromeless: false)
                .environmentObject(state)
                .frame(maxWidth: DesignTokens.composerMaxWidth)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
        .background(DesignTokens.background)
    }
}

private struct ComposerCard: View {
    @EnvironmentObject private var state: AppState
    @FocusState private var focused: Bool
    var chromeless: Bool

    private var canSend: Bool {
        (!state.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !state.pendingAttachments.isEmpty) &&
            !state.isCurrentSessionStreaming
    }

    var body: some View {
        VStack(spacing: 0) {
            if !state.pendingAttachments.isEmpty {
                attachmentTray
                    .padding(.bottom, 6)
            }

            ZStack(alignment: .topLeading) {
                if state.composerText.isEmpty {
                    Text("Ask 9GClaw")
                        .font(.system(size: 14))
                        .foregroundStyle(DesignTokens.neutral400)
                        .padding(.horizontal, 8)
                        .padding(.top, 7)
                }
                TextEditor(text: $state.composerText)
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .focused($focused)
                    .frame(height: DesignTokens.composerTextMinHeight)
                    .padding(.horizontal, 3)
            }

            HStack(spacing: 2) {
                runModeButton
                    .padding(.trailing, 4)
                iconControl("paperclip", help: "Attach photos or files") {
                    openAttachmentPanel()
                }
                iconControl("at", help: "Mention a file") {
                    state.composerText += "@"
                    focused = true
                }
                iconControl("command", help: "Run a command") {
                    state.composerText += "/"
                    focused = true
                }
                permissionModeButton
                contextGauge
                Spacer(minLength: 8)
                sendOrStopButton
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.largeRadius, style: .continuous)
                .fill(DesignTokens.background)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.largeRadius, style: .continuous)
                        .stroke(focused ? DesignTokens.neutral300 : DesignTokens.separator, lineWidth: 1)
                )
                .shadow(color: .black.opacity(chromeless ? 0.06 : 0.04), radius: 4, y: 1)
        )
    }

    private var attachmentTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(state.pendingAttachments) { attachment in
                    HStack(spacing: 6) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 12))
                        Text(attachment.fileName)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Button {
                            state.pendingAttachments.removeAll { $0.id == attachment.id }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .buttonStyle(.plain)
                    }
                    .foregroundStyle(DesignTokens.secondaryText)
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                            .fill(DesignTokens.neutral100)
                    )
                }
            }
        }
    }

    private var runModeButton: some View {
        Menu {
            ForEach(ChatRunMode.allCases) { mode in
                Button {
                    state.composerRunMode = mode
                } label: {
                    Label(mode.label, systemImage: mode.systemImage)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: state.composerRunMode.systemImage)
                    .font(.system(size: 15))
                Text(state.composerRunMode.label)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
            }
            .frame(height: 28)
            .padding(.horizontal, 8)
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(ComposerControlButtonStyle())
        .help("Choose run mode")
    }

    private var permissionModeButton: some View {
        Menu {
            ForEach(ComposerPermissionMode.allCases) { mode in
                Button {
                    state.composerPermissionMode = mode
                } label: {
                    Label(mode.label, systemImage: mode.systemImage)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: state.composerPermissionMode.systemImage)
                    .font(.system(size: 15))
                Text(state.composerPermissionMode.label)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
            }
            .frame(height: 28)
            .padding(.horizontal, 8)
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(ComposerControlButtonStyle())
        .help("Choose permission mode")
    }

    private var contextGauge: some View {
        Menu {
            Text("Context usage: 0%")
            Text("No token budget has been reported for this session yet.")
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "gauge")
                    .font(.system(size: 15))
                Text("0%")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(DesignTokens.tertiaryText)
            .frame(height: 28)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                    .fill(Color.clear)
            )
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(ComposerControlButtonStyle())
        .help("Context usage")
    }

    private func iconControl(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(ComposerControlButtonStyle())
        .help(help)
    }

    private var sendOrStopButton: some View {
        Button {
            if state.isCurrentSessionStreaming {
                state.abortActiveRun()
            } else {
                state.sendComposerMessage()
            }
        } label: {
            Image(systemName: state.isCurrentSessionStreaming ? "stop.fill" : "arrow.up")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(state.isCurrentSessionStreaming || canSend ? .white : DesignTokens.neutral400)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous)
                        .fill(state.isCurrentSessionStreaming || canSend ? DesignTokens.neutral900 : DesignTokens.neutral200)
                )
        }
        .buttonStyle(.plain)
        .disabled(!state.isCurrentSessionStreaming && !canSend)
        .keyboardShortcut(.return, modifiers: [.command])
        .help(state.isCurrentSessionStreaming ? "Stop generation" : "Send")
    }

    private func openAttachmentPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        let attachments = panel.urls.map { url in
            FileAttachment(
                id: UUID(),
                fileName: url.lastPathComponent,
                path: url.path,
                mimeType: nil
            )
        }
        state.pendingAttachments.append(contentsOf: attachments)
        focused = true
    }
}

private struct MessageRow: View {
    var message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            userRow
        case .assistant:
            assistantRow
        case .system, .tool:
            delegatedRow
        }
    }

    private var userRow: some View {
        HStack {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block, compact: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: 780, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.userBubbleRadius, style: .continuous)
                    .fill(DesignTokens.neutral100)
            )
        }
        .frame(maxWidth: .infinity)
    }

    private var assistantRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block, compact: false)
            }
            if message.isStreaming && message.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Rectangle()
                    .fill(DesignTokens.neutral400)
                    .frame(width: 8, height: 16)
            }
        }
        .font(.system(size: 14))
        .lineSpacing(4)
        .foregroundStyle(DesignTokens.text)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var delegatedRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block, compact: false)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous)
                .fill(DesignTokens.neutral50)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous)
                        .stroke(DesignTokens.separator, lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private func blockView(_ block: ChatBlock, compact: Bool) -> some View {
        switch block {
        case .text(let text):
            Text(text.isEmpty ? " " : text)
                .font(.system(size: 14))
                .lineSpacing(compact ? 2 : 4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .toolCall(let call):
            ToolBlock(title: call.name, detail: call.inputJSON, systemImage: "hammer", tint: DesignTokens.warning)
        case .toolResult(let result):
            ToolBlock(
                title: result.isError ? "Tool error" : "Tool result",
                detail: result.output,
                systemImage: result.isError ? "exclamationmark.triangle" : "checkmark.circle",
                tint: result.isError ? DesignTokens.danger : DesignTokens.success
            )
        case .attachment(let attachment):
            ToolBlock(title: attachment.fileName, detail: attachment.path, systemImage: "paperclip", tint: DesignTokens.accent)
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
                .lineLimit(12)
                .foregroundStyle(DesignTokens.secondaryText)
                .textSelection(.enabled)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous)
                .fill(DesignTokens.neutral50)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous)
                        .stroke(DesignTokens.separator, lineWidth: 1)
                )
        )
    }
}

private struct PermissionBanner: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(state.pendingPermissions) { request in
                HStack(spacing: 10) {
                    Image(systemName: "hand.raised")
                        .foregroundStyle(DesignTokens.warning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(request.toolName)
                            .font(.system(size: 12, weight: .semibold))
                        Text(request.reason)
                            .font(.system(size: 12))
                            .foregroundStyle(DesignTokens.secondaryText)
                    }
                    Spacer()
                    Button("Deny") {
                        state.pendingPermissions.removeAll { $0.id == request.id }
                        state.statusLine = "Permission denied for \(request.toolName)"
                    }
                    Button("Allow") {
                        state.pendingPermissions.removeAll { $0.id == request.id }
                        state.statusLine = "Permission allowed for \(request.toolName)"
                    }
                        .buttonStyle(.borderedProminent)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous)
                        .fill(DesignTokens.neutral50)
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous)
                                .stroke(DesignTokens.separator, lineWidth: 1)
                        )
                )
            }
        }
    }
}

private struct ProcessLiveStatusRow: View {
    var activities: [AgentActivity]
    @State private var expanded = false

    private var latest: AgentActivity? {
        activities.last { $0.state == .running } ?? activities.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    statusIcon(latest?.phase ?? .status, state: latest?.state ?? .running)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(latest?.title ?? "Processing")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DesignTokens.text)
                        Text(liveDetail)
                            .font(.system(size: 12))
                            .foregroundStyle(DesignTokens.tertiaryText)
                            .lineLimit(1)
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        Text(summaryText)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(DesignTokens.tertiaryText)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                            .foregroundStyle(DesignTokens.tertiaryText)
                    }
                }
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(activities) { activity in
                        HStack(alignment: .top, spacing: 10) {
                            statusIcon(activity.phase, state: activity.state)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(activity.title)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(DesignTokens.text)
                                if !activity.detail.isEmpty {
                                    Text(activity.detail)
                                        .font(.system(size: 11, design: activity.phase == .tool ? .monospaced : .default))
                                        .foregroundStyle(DesignTokens.tertiaryText)
                                        .lineLimit(4)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.largeRadius, style: .continuous)
                .fill(DesignTokens.neutral50)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.largeRadius, style: .continuous)
                        .stroke(DesignTokens.separator, lineWidth: 1)
                )
        )
    }

    private var liveDetail: String {
        latest?.detail.isEmpty == false ? latest?.detail ?? "" : "Working"
    }

    private var summaryText: String {
        if activities.contains(where: { $0.state == .running }) { return "Live" }
        if activities.contains(where: { $0.state == .failed }) { return "Failed" }
        if activities.contains(where: { $0.state == .cancelled }) { return "Stopped" }
        let toolCount = activities.filter { $0.phase != .status }.count
        if toolCount == 0 { return "Done" }
        return "\(toolCount) tools"
    }

    private func statusIcon(_ phase: AgentActivityPhase, state: AgentActivityState) -> some View {
        ZStack {
            if state == .running {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.58)
            } else {
                Image(systemName: iconName(phase, state: state))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(iconColor(state))
            }
        }
        .frame(width: 22, height: 22)
        .background(
            Circle()
                .fill(iconColor(state).opacity(0.10))
        )
    }

    private func iconName(_ phase: AgentActivityPhase, state: AgentActivityState) -> String {
        if state == .failed { return "exclamationmark.triangle" }
        if state == .cancelled { return "stop.fill" }
        switch phase {
        case .status, .thinking:
            return "sparkles"
        case .tool:
            return "hammer"
        case .search:
            return "magnifyingglass"
        case .command:
            return "terminal"
        case .edit:
            return "pencil"
        case .subagent:
            return "person.2"
        }
    }

    private func iconColor(_ state: AgentActivityState) -> Color {
        switch state {
        case .running: DesignTokens.accent
        case .completed: DesignTokens.success
        case .failed: DesignTokens.danger
        case .cancelled: DesignTokens.tertiaryText
        }
    }
}

private struct ComposerControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(DesignTokens.secondaryText)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                    .fill(configuration.isPressed ? DesignTokens.neutral100 : Color.clear)
            )
            .opacity(configuration.isPressed ? 0.76 : 1)
    }
}
