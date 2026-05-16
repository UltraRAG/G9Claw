import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        conversationBody
        .background(DesignTokens.background)
    }

    private var conversationBody: some View {
        Group {
            if state.currentMessages.isEmpty {
                emptyLanding
            } else {
                VStack(spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 32) {
                                ForEach(state.currentMessages) { message in
                                    if message.id == tracedAssistantID {
                                        ProcessRunHeader(activities: traceActivities)
                                            .environmentObject(state)
                                            .id("process-run-header")
                                    }
                                    MessageRow(message: message)
                                        .id(message.id)
                                    if message.id == tracedAssistantID, !tracedAssistantHasToolBlocks {
                                        ProcessLiveStatusRow(activities: traceActivities)
                                            .environmentObject(state)
                                            .id("process-live-status")
                                    }
                                }
                                if tracedAssistantID == nil, !traceActivities.isEmpty {
                                    ProcessLiveStatusRow(activities: traceActivities)
                                        .environmentObject(state)
                                        .id("process-live-status")
                                }
                            }
                            .padding(.horizontal, DesignTokens.transcriptPaddingH)
                            .padding(.vertical, DesignTokens.transcriptPaddingV)
                            .frame(maxWidth: DesignTokens.transcriptMaxWidth)
                            .frame(maxWidth: .infinity)
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
                            guard !traceActivities.isEmpty else { return }
                            withAnimation(.easeOut(duration: 0.18)) {
                                proxy.scrollTo("process-live-status", anchor: .bottom)
                            }
                        }
                    }

                    ComposerFooter()
                        .environmentObject(state)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var tracedAssistantID: UUID? {
        guard !traceActivities.isEmpty else { return nil }
        return latestAssistantID
    }

    private var latestAssistantID: UUID? {
        state.currentMessages.last(where: { $0.role == .assistant })?.id
    }

    private var tracedAssistantHasToolBlocks: Bool {
        guard let tracedAssistantID,
              let message = state.currentMessages.first(where: { $0.id == tracedAssistantID }) else {
            return false
        }
        return message.blocks.contains { block in
            if case .toolCall = block { return true }
            if case .toolResult = block { return true }
            return false
        }
    }

    private var traceActivities: [AgentActivity] {
        AgentActivity.processTraceActivities(state.currentActivities, anchoredTo: latestAssistantID?.uuidString)
    }

    private var emptyLanding: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Text(state.t(.welcomePrompt))
                .font(.system(size: DesignTokens.welcomeTitleSize, weight: .medium))
                .tracking(-0.4)
                .foregroundStyle(DesignTokens.text)
                .multilineTextAlignment(.center)
                .padding(.bottom, 34)
            ComposerCard(chromeless: false)
                .environmentObject(state)
                .frame(maxWidth: DesignTokens.composerMaxWidth)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ComposerFooter: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            if let runningActivity {
                ComposerRunningStatusRow(activity: runningActivity)
                    .environmentObject(state)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 6)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
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

    private var runningActivity: AgentActivity? {
        state.currentActivities
            .filter { $0.state == .running }
            .sorted { $0.updatedAt < $1.updatedAt }
            .last
    }
}

private struct ComposerRunningStatusRow: View {
    @EnvironmentObject private var state: AppState
    var activity: AgentActivity

    private var text: String {
        let title = activity.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty {
            return state.settings.language.resolved() == .chineseSimplified ? "正在思考" : "Thinking"
        }
        return title
    }

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.62)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DesignTokens.tertiaryText)
                .lineLimit(1)
            if !activity.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(activity.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(DesignTokens.tertiaryText.opacity(0.72))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: DesignTokens.composerMaxWidth)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(DesignTokens.neutral50, in: Capsule())
        .animation(.easeOut(duration: 0.16), value: activity.id)
    }
}


private struct ComposerCard: View {
    @EnvironmentObject private var state: AppState
    @State private var focused = false
    @State private var showContextPopover = false
    @State private var isComposingMarkedText = false
    var chromeless: Bool

    private var canSend: Bool {
        (!state.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !state.pendingAttachments.isEmpty) &&
            !state.isCurrentSessionStreaming &&
            !isComposingMarkedText
    }

    var body: some View {
        VStack(spacing: 0) {
            if !state.pendingAttachments.isEmpty {
                attachmentTray
                    .padding(.bottom, 6)
            }

            ZStack(alignment: .topLeading) {
                if state.composerText.isEmpty && !isComposingMarkedText {
                    Text(state.t(.askPlaceholder))
                        .font(.system(size: 14))
                        .foregroundStyle(DesignTokens.neutral400)
                        .padding(.horizontal, 8)
                        .padding(.top, 7)
                }
                ComposerTextEditor(
                    text: $state.composerText,
                    isFocused: $focused,
                    hasMarkedText: $isComposingMarkedText,
                    canSubmit: canSend,
                    pasteboardAttachments: pastedAttachments,
                    onPasteAttachments: { attachments in
                        state.pendingAttachments.append(contentsOf: attachments)
                        focused = true
                    },
                    onToggleRunMode: {
                        state.toggleComposerRunMode()
                    },
                    onSubmit: {
                        if state.isCurrentSessionStreaming {
                            state.abortActiveRun()
                        } else if canSend {
                            state.sendComposerMessage()
                        }
                    }
                )
                    .frame(height: DesignTokens.composerTextMinHeight)
            }

            HStack(spacing: 2) {
                runModeButton
                    .padding(.trailing, 4)
                iconControl("paperclip", help: state.t(.attachHelp)) {
                    openAttachmentPanel()
                }
                iconControl("at", help: state.t(.mentionFile)) {
                    state.composerText += "@"
                    focused = true
                }
                iconControl("command", help: state.t(.commandHelp)) {
                    state.composerText += "/"
                    focused = true
                }
                permissionModeButton
                Spacer(minLength: 8)
                contextGauge
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
                .shadow(color: .black.opacity(chromeless ? 0.06 : 0.05), radius: 2, y: 1)
        )
    }

    private var attachmentTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(state.pendingAttachments) { attachment in
                    HStack(spacing: 6) {
                        Image(systemName: attachment.isImage ? "photo" : "paperclip")
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
                    Label(state.runModeLabel(mode), systemImage: mode.systemImage)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: state.composerRunMode.systemImage)
                    .font(.system(size: 15))
                Text(state.runModeLabel(state.composerRunMode))
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
        .help(state.t(.chooseRunMode))
    }

    private var permissionModeButton: some View {
        let isBypass = state.composerPermissionMode == .bypassPermissions
        let tone = isBypass ? DesignTokens.warning : DesignTokens.secondaryText
        return Menu {
            ForEach(ComposerPermissionMode.allCases) { mode in
                Button {
                    state.composerPermissionMode = mode
                } label: {
                    Label(state.permissionModeLabel(mode), systemImage: mode.systemImage)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: state.composerPermissionMode.systemImage)
                    .font(.system(size: 15))
                Text(state.permissionModeLabel(state.composerPermissionMode))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
            }
            .frame(height: 28)
            .padding(.horizontal, 8)
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(
            ComposerControlButtonStyle(
                foreground: tone,
                idleBackground: isBypass ? DesignTokens.warning.opacity(0.10) : .clear,
                pressedBackground: isBypass ? DesignTokens.warning.opacity(0.18) : DesignTokens.neutral100
            )
        )
        .help(state.t(.choosePermissionMode))
    }

    private var contextGauge: some View {
        Button {
            showContextPopover.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.system(size: 15, weight: .medium))
                Text(contextPercentText)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
            }
            .foregroundStyle(contextTone)
            .frame(height: 28)
            .padding(.horizontal, 6)
            .frame(minWidth: latestTokenBudget == nil ? 40 : 58)
            .background(
                Capsule(style: .continuous)
                    .fill(latestTokenBudget == nil ? Color.clear : DesignTokens.neutral100)
            )
        }
        .buttonStyle(ComposerControlButtonStyle())
        .popover(isPresented: $showContextPopover, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(state.t(.contextWindow))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DesignTokens.text)
                    Spacer()
                    if let contextPercent {
                        Text("\(contextPercent)%")
                            .font(.system(size: 13, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(contextTone)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(contextTone.opacity(0.12), in: Capsule())
                    }
                }
                Text(contextDetailText)
                    .font(.system(size: 13, weight: latestTokenBudget == nil ? .regular : .medium))
                    .foregroundStyle(DesignTokens.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if latestTokenBudget != nil {
                    Text(state.settings.language.resolved() == .chineseSimplified ? "接近配置上限时会自动触发上下文压缩。" : "Context compaction starts automatically near the configured limit.")
                        .font(.system(size: 12))
                        .foregroundStyle(DesignTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(width: 300, alignment: .leading)
            .background(DesignTokens.background)
        }
        .help(contextDetailText)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var latestTokenBudget: TokenBudget? {
        state.currentMessages.reversed().compactMap(\.tokenBudget).first
    }

    private var contextPercent: Int? {
        guard let latestTokenBudget, latestTokenBudget.total > 0 else { return nil }
        return max(0, min(999, Int((Double(latestTokenBudget.used) / Double(latestTokenBudget.total) * 100).rounded())))
    }

    private var contextPercentText: String {
        if let contextPercent {
            return "\(contextPercent)%"
        }
        return "0%"
    }

    private var contextDetailText: String {
        guard let latestTokenBudget else {
            return state.t(.contextUsageDetail)
        }
        if state.settings.language.resolved() == .chineseSimplified {
            return "已用 \(latestTokenBudget.used.formatted()) token，共 \(latestTokenBudget.total.formatted())。"
        }
        return "Used \(latestTokenBudget.used.formatted()) tokens of \(latestTokenBudget.total.formatted())."
    }

    private var contextTone: Color {
        guard let contextPercent else { return DesignTokens.neutral400 }
        if contextPercent >= 90 { return DesignTokens.danger }
        if contextPercent >= 70 { return DesignTokens.warning }
        return DesignTokens.tertiaryText
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
                .foregroundStyle(state.isCurrentSessionStreaming ? .white : (canSend ? .white : DesignTokens.neutral400))
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous)
                        .fill(state.isCurrentSessionStreaming ? Color(nsColor: NSColor(red: 239/255, green: 68/255, blue: 68/255, alpha: 1)) : (canSend ? DesignTokens.neutral900 : DesignTokens.neutral200))
                )
        }
        .buttonStyle(.plain)
        .disabled(!state.isCurrentSessionStreaming && !canSend)
        .keyboardShortcut(.return, modifiers: [.command])
        .help(state.isCurrentSessionStreaming ? state.t(.stopGeneration) : state.t(.send))
    }

    private func openAttachmentPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        panel.prompt = state.t(.attach)
        guard panel.runModal() == .OK else { return }
        let attachments = panel.urls.map(ComposerPasteboardReader.attachment)
        state.pendingAttachments.append(contentsOf: attachments)
        focused = true
    }

    private func pastedAttachments(from pasteboard: NSPasteboard) -> [FileAttachment] {
        ComposerPasteboardReader.attachments(from: pasteboard, saveImage: savePastedImage)
    }

    private func savePastedImage(_ image: NSImage) -> URL? {
        guard
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:]),
            let paths = try? AppPaths.current()
        else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let safeStamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = paths.attachments.appendingPathComponent("pasted-image-\(safeStamp).png")
        do {
            try png.write(to: url, options: .atomic)
            return url
        } catch {
            state.errorBanner = error.localizedDescription
            return nil
        }
    }
}

enum ComposerPasteboardReader {
    private static let fileNamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")

    static func attachments(from pasteboard: NSPasteboard, saveImage: (NSImage) -> URL?) -> [FileAttachment] {
        let fileURLs = orderedUniqueFileURLs(from: pasteboard)
        if !fileURLs.isEmpty {
            return fileURLs.map(attachment)
        }
        guard let image = image(from: pasteboard),
              let url = saveImage(image) else {
            return []
        }
        return [
            FileAttachment(
                id: UUID(),
                fileName: url.lastPathComponent,
                path: url.path,
                mimeType: "image/png"
            ),
        ]
    }

    static func attachment(for url: URL) -> FileAttachment {
        FileAttachment(
            id: UUID(),
            fileName: url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent,
            path: url.path,
            mimeType: mimeType(for: url)
        )
    }

    static func textPayload(from pasteboard: NSPasteboard, attachments: [FileAttachment]) -> String? {
        guard let value = pasteboard.string(forType: .string),
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let attachmentValues = Set(
            attachments.flatMap { attachment -> [String] in
                let url = URL(fileURLWithPath: attachment.path)
                return [attachment.path, url.absoluteString]
            }
        )
        let lines = value
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !attachmentValues.isEmpty,
           !lines.isEmpty,
           lines.allSatisfy({ attachmentValues.contains($0) }) {
            return nil
        }
        return value
    }

    private static func orderedUniqueFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        var urls: [URL] = []
        if let readURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] {
            urls.append(contentsOf: readURLs)
        }
        if let fileURLString = pasteboard.string(forType: .fileURL),
           let url = URL(string: fileURLString),
           url.isFileURL {
            urls.append(url)
        }
        if let filenames = pasteboard.propertyList(forType: fileNamesType) as? [String] {
            urls.append(contentsOf: filenames.map(URL.init(fileURLWithPath:)))
        }
        var seen: Set<String> = []
        return urls.compactMap { url in
            let standardized = url.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { return nil }
            return standardized
        }
    }

    private static func image(from pasteboard: NSPasteboard) -> NSImage? {
        if let image = NSImage(pasteboard: pasteboard) {
            return image
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type),
               let image = NSImage(data: data) {
                return image
            }
        }
        return nil
    }

    private static func mimeType(for url: URL) -> String? {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return "inode/directory"
        }
        return UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
    }
}

private struct MessageRow: View {
    @EnvironmentObject private var state: AppState
    var message: ChatMessage

    private let assistantFontSize: CGFloat = 15
    private let userFontSize: CGFloat = 15

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
                    userBlockView(block)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: (DesignTokens.transcriptMaxWidth - DesignTokens.transcriptPaddingH * 2) * 0.78, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.userBubbleRadius, style: .continuous)
                    .fill(DesignTokens.neutral100)
            )
        }
        .frame(maxWidth: .infinity)
    }

    private var assistantRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(assistantSegments.enumerated()), id: \.offset) { _, segment in
                assistantSegmentView(segment)
            }
            if message.isStreaming && message.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                RoundedRectangle(cornerRadius: 1)
                    .fill(DesignTokens.neutral400)
                    .frame(width: 8, height: 16)
                .opacity(0.8)
            }
        }
        .font(.system(size: assistantFontSize))
        .lineSpacing(7)
        .foregroundStyle(DesignTokens.text)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var assistantSegments: [AssistantBlockSegment] {
        var segments: [AssistantBlockSegment] = []
        var consumedResultIDs = Set<String>()
        var toolGroup: [(ToolCall, ToolResult?)] = []

        func flushToolGroup() {
            guard !toolGroup.isEmpty else { return }
            if toolGroup.count == 1, let first = toolGroup.first {
                segments.append(.tool(first.0, first.1))
            } else {
                segments.append(.toolGroup(toolGroup))
            }
            toolGroup.removeAll()
        }

        for block in message.blocks {
            switch block {
            case .text(let text):
                flushToolGroup()
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty, !isPureMarkdownSeparator(cleaned) else { continue }
                segments.append(.text(text))
            case .attachment(let attachment):
                flushToolGroup()
                segments.append(.attachment(attachment))
            case .toolCall(let call):
                let result = message.blocks.compactMap { candidate -> ToolResult? in
                    guard case .toolResult(let result) = candidate, result.toolCallId == call.id else { return nil }
                    return result
                }.last
                if result != nil {
                    consumedResultIDs.insert(call.id)
                }
                toolGroup.append((call, result))
            case .toolResult(let result):
                if !consumedResultIDs.contains(result.toolCallId) {
                    flushToolGroup()
                    segments.append(.orphanToolResult(result))
                }
            }
        }
        flushToolGroup()
        return segments
    }

    private func isPureMarkdownSeparator(_ text: String) -> Bool {
        let compact = text.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: " ", with: "")
        return compact == "---" || compact == "----"
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
            if compact {
                Text(text)
                    .font(.system(size: userFontSize))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                NativeMarkdownView(text: text, fontSize: assistantFontSize, lineSpacing: 7)
            }
        case .toolCall(let call):
            ToolBlock(title: call.name, detail: call.inputJSON, systemImage: "hammer", tint: DesignTokens.warning)
        case .toolResult(let result):
            ToolBlock(
                title: result.isError ? state.t(.toolError) : state.t(.toolResult),
                detail: result.output,
                systemImage: result.isError ? "exclamationmark.triangle" : "checkmark.circle",
                tint: result.isError ? DesignTokens.danger : DesignTokens.success
            )
        case .attachment(let attachment):
            ToolBlock(title: attachment.fileName, detail: attachment.path, systemImage: "paperclip", tint: DesignTokens.accent)
        }
    }

    @ViewBuilder
    private func assistantSegmentView(_ segment: AssistantBlockSegment) -> some View {
        switch segment {
        case .text(let text):
            NativeMarkdownView(text: text, fontSize: assistantFontSize, lineSpacing: 7)
        case .attachment(let attachment):
            AttachmentChip(attachment: attachment)
        case .tool(let call, let result):
            InlineProcessToolRow(call: call, result: result)
                .environmentObject(state)
        case .toolGroup(let items):
            InlineProcessToolGroupRow(items: items)
                .environmentObject(state)
        case .orphanToolResult(let result):
            InlineProcessToolResultRow(result: result)
                .environmentObject(state)
        }
    }

    @ViewBuilder
    private func userBlockView(_ block: ChatBlock) -> some View {
        switch block {
        case .text(let text):
            Text(text.isEmpty ? " " : text)
                .font(.system(size: userFontSize))
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .attachment(let attachment):
            AttachmentChip(attachment: attachment)
        case .toolCall, .toolResult:
            blockView(block, compact: true)
        }
    }
}

private enum AssistantBlockSegment {
    case text(String)
    case attachment(FileAttachment)
    case tool(ToolCall, ToolResult?)
    case toolGroup([(ToolCall, ToolResult?)])
    case orphanToolResult(ToolResult)
}

private struct InlineProcessToolRow: View {
    @EnvironmentObject private var state: AppState
    var call: ToolCall
    var result: ToolResult?
    @State private var expanded = false

    private var failed: Bool { result?.isError == true }
    private var running: Bool { result == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                HStack(spacing: 9) {
                    CodexInlineToolIcon(phase: phase, state: stateForRow)
                    Text(title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(DesignTokens.tertiaryText)
                        .lineLimit(1)
                    if running {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.52)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DesignTokens.neutral400)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    detailBlock(label: isChinese ? "输入" : "Input", value: call.inputJSON)
                    if let result {
                        detailBlock(label: result.isError ? state.t(.toolError) : state.t(.toolResult), value: result.output)
                    }
                }
                .padding(.leading, 28)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 8)
    }

    private var title: String {
        let target = InlineProcessToolRow.target(from: call.inputJSON)
        let suffix = target.map { " \($0)" } ?? ""
        let lower = call.name.lowercased()
        if lower.contains("grep") || lower.contains("glob") || lower.contains("search") {
            return running ? localized("正在搜索\(suffix)", "Searching\(suffix)") : localized("已搜索\(suffix)", "Searched\(suffix)")
        }
        if lower.contains("read") {
            return running ? localized("正在读取\(suffix)", "Reading\(suffix)") : localized("已读取\(suffix)", "Read\(suffix)")
        }
        if lower.contains("write") || lower.contains("edit") || lower.contains("multi") {
            return running ? localized("正在编辑\(suffix)", "Editing\(suffix)") : localized("已编辑\(suffix)", "Edited\(suffix)")
        }
        if lower.contains("bash") || lower.contains("shell") {
            return running ? localized("正在运行命令\(suffix)", "Running command\(suffix)") : localized("已运行命令\(suffix)", "Ran command\(suffix)")
        }
        if lower == "askuserquestion" {
            return running ? localized("等待你的回答", "Waiting for your answer") : localized("已回答问题", "Answered question")
        }
        if failed {
            return localized("\(call.name) 失败", "\(call.name) failed")
        }
        return running ? localized("正在运行 \(call.name)", "Running \(call.name)") : localized("已完成 \(call.name)", "Completed \(call.name)")
    }

    private var phase: AgentActivityPhase {
        let lower = call.name.lowercased()
        if lower.contains("grep") || lower.contains("glob") || lower.contains("search") { return .search }
        if lower.contains("bash") || lower.contains("shell") { return .command }
        if lower.contains("write") || lower.contains("edit") || lower.contains("multi") { return .edit }
        return .tool
    }

    private var stateForRow: AgentActivityState {
        if running { return .running }
        return failed ? .failed : .completed
    }

    private var isChinese: Bool {
        switch state.settings.language {
        case .chineseSimplified: true
        case .english: false
        case .system: Locale.preferredLanguages.first?.hasPrefix("zh") == true
        }
    }

    private func localized(_ zh: String, _ en: String) -> String {
        isChinese ? zh : en
    }

    private func detailBlock(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DesignTokens.tertiaryText)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(DesignTokens.secondaryText)
                .lineLimit(12)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(9)
        .background(DesignTokens.neutral50, in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous))
    }

    private static func target(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        for key in ["file_path", "path", "pattern", "query", "command", "description"] {
            guard let raw = object[key] as? String else { continue }
            let trimmed = raw.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if key == "path" || key == "file_path" {
                let name = URL(fileURLWithPath: trimmed).lastPathComponent
                return name.isEmpty ? trimmed : name
            }
            return trimmed.count > 56 ? String(trimmed.prefix(55)) + "…" : trimmed
        }
        return nil
    }
}

private struct InlineProcessToolGroupRow: View {
    @EnvironmentObject private var state: AppState
    var items: [(ToolCall, ToolResult?)]
    @State private var expanded = false

    private var isRunning: Bool { items.contains { $0.1 == nil } }
    private var hasFailure: Bool { items.contains { $0.1?.isError == true } }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 9) {
                    CodexInlineToolIcon(phase: dominantPhase, state: groupState)
                    Text(summaryText)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(DesignTokens.tertiaryText)
                        .lineLimit(1)
                    if isRunning {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.52)
                    }
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DesignTokens.neutral400)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 7) {
                                CodexInlineToolIcon(phase: phase(for: item.0), state: state(for: item.1))
                                    .scaleEffect(0.86)
                                Text(lineTitle(for: item.0, result: item.1))
                                    .font(.system(size: 13))
                                    .foregroundStyle(DesignTokens.secondaryText)
                                    .lineLimit(1)
                            }
                            if let output = item.1?.output.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
                                Text(compact(output, limit: 180))
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(DesignTokens.tertiaryText.opacity(0.88))
                                    .lineLimit(3)
                                    .textSelection(.enabled)
                                    .padding(.leading, 28)
                            } else if !item.0.inputJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(compact(item.0.inputJSON, limit: 180))
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(DesignTokens.tertiaryText.opacity(0.78))
                                    .lineLimit(2)
                                    .textSelection(.enabled)
                                    .padding(.leading, 28)
                            }
                        }
                    }
                }
                .padding(.leading, 28)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 8)
    }

    private var groupState: AgentActivityState {
        if isRunning { return .running }
        if hasFailure { return .failed }
        return .completed
    }

    private var dominantPhase: AgentActivityPhase {
        if items.contains(where: { phase(for: $0.0) == .edit }) { return .edit }
        if items.contains(where: { phase(for: $0.0) == .search }) { return .search }
        if items.contains(where: { phase(for: $0.0) == .command }) { return .command }
        return .tool
    }

    private var summaryText: String {
        let readTargets = Set(items.compactMap { item -> String? in
            phase(for: item.0) == .tool && item.0.name.lowercased().contains("read") ? target(from: item.0.inputJSON) ?? item.0.id : nil
        })
        let editTargets = Set(items.compactMap { item -> String? in
            phase(for: item.0) == .edit ? target(from: item.0.inputJSON) ?? item.0.id : nil
        })
        let searches = items.filter { phase(for: $0.0) == .search }.count
        let commands = items.filter { phase(for: $0.0) == .command }.count
        let otherTools = items.count - readTargets.count - editTargets.count - searches - commands

        var parts: [String] = []
        if isChinese {
            if !readTargets.isEmpty { parts.append("已探索 \(readTargets.count) 个文件") }
            if searches > 0 { parts.append("\(searches) 次搜索") }
            if !editTargets.isEmpty { parts.append("已编辑 \(editTargets.count) 个文件") }
            if commands > 0 { parts.append("已运行 \(commands) 条命令") }
            if parts.isEmpty, otherTools > 0 { parts.append("已使用 \(otherTools) 个工具") }
            return parts.isEmpty ? "正在处理" : parts.joined(separator: " ")
        }

        if !readTargets.isEmpty { parts.append("explored \(readTargets.count) \(readTargets.count == 1 ? "file" : "files")") }
        if searches > 0 { parts.append("\(searches) \(searches == 1 ? "search" : "searches")") }
        if !editTargets.isEmpty { parts.append("edited \(editTargets.count) \(editTargets.count == 1 ? "file" : "files")") }
        if commands > 0 { parts.append("ran \(commands) \(commands == 1 ? "command" : "commands")") }
        if parts.isEmpty, otherTools > 0 { parts.append("used \(otherTools) \(otherTools == 1 ? "tool" : "tools")") }
        return parts.isEmpty ? "Processing" : parts.joined(separator: " ")
    }

    private var isChinese: Bool {
        switch state.settings.language {
        case .chineseSimplified: true
        case .english: false
        case .system: Locale.preferredLanguages.first?.hasPrefix("zh") == true
        }
    }

    private func lineTitle(for call: ToolCall, result: ToolResult?) -> String {
        let targetText = target(from: call.inputJSON).map { " \($0)" } ?? ""
        let lower = call.name.lowercased()
        let running = result == nil
        if lower.contains("read") { return running ? localized("正在读取\(targetText)", "Reading\(targetText)") : localized("已读取\(targetText)", "Read\(targetText)") }
        if lower.contains("grep") || lower.contains("glob") || lower.contains("search") { return running ? localized("正在搜索\(targetText)", "Searching\(targetText)") : localized("已搜索\(targetText)", "Searched\(targetText)") }
        if lower.contains("write") || lower.contains("edit") || lower.contains("multi") { return running ? localized("正在编辑\(targetText)", "Editing\(targetText)") : localized("已编辑\(targetText)", "Edited\(targetText)") }
        if lower.contains("bash") || lower.contains("shell") { return running ? localized("正在运行命令\(targetText)", "Running command\(targetText)") : localized("已运行命令\(targetText)", "Ran command\(targetText)") }
        return running ? localized("正在运行 \(call.name)", "Running \(call.name)") : localized("已完成 \(call.name)", "Completed \(call.name)")
    }

    private func phase(for call: ToolCall) -> AgentActivityPhase {
        let lower = call.name.lowercased()
        if lower.contains("grep") || lower.contains("glob") || lower.contains("search") { return .search }
        if lower.contains("bash") || lower.contains("shell") { return .command }
        if lower.contains("write") || lower.contains("edit") || lower.contains("multi") { return .edit }
        return .tool
    }

    private func state(for result: ToolResult?) -> AgentActivityState {
        guard let result else { return .running }
        return result.isError ? .failed : .completed
    }

    private func localized(_ zh: String, _ en: String) -> String {
        isChinese ? zh : en
    }

    private func target(from json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        for key in ["file_path", "path", "pattern", "query", "command", "description"] {
            guard let raw = object[key] as? String else { continue }
            let cleaned = compact(raw, limit: key == "command" ? 72 : 80)
            if cleaned.isEmpty { continue }
            if key == "path" || key == "file_path" {
                let name = URL(fileURLWithPath: cleaned).lastPathComponent
                return name.isEmpty ? cleaned : name
            }
            return cleaned
        }
        return nil
    }

    private func compact(_ value: String, limit: Int) -> String {
        let normalized = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        let index = normalized.index(normalized.startIndex, offsetBy: max(0, limit - 1))
        return String(normalized[..<index]) + "…"
    }
}

private struct InlineProcessToolResultRow: View {
    @EnvironmentObject private var state: AppState
    var result: ToolResult

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            CodexInlineToolIcon(phase: .tool, state: result.isError ? .failed : .completed)
            VStack(alignment: .leading, spacing: 3) {
                Text(result.isError ? state.t(.toolError) : state.t(.toolResult))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(DesignTokens.tertiaryText)
                Text(result.output)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(DesignTokens.secondaryText)
                    .lineLimit(5)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct CodexInlineToolIcon: View {
    var phase: AgentActivityPhase
    var state: AgentActivityState
    @State private var pulse = false

    var body: some View {
        ZStack {
            if state == .running {
                Circle()
                    .fill(iconColor.opacity(pulse ? 0.08 : 0.18))
                    .frame(width: pulse ? 20 : 12, height: pulse ? 20 : 12)
                    .animation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true), value: pulse)
            }
            Image(systemName: iconName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(iconColor)
        }
        .frame(width: 18, height: 18)
        .onAppear {
            if state == .running {
                pulse = true
            }
        }
    }

    private var iconName: String {
        switch state {
        case .failed: return "exclamationmark.triangle"
        case .cancelled: return "xmark.circle"
        case .completed:
            switch phase {
            case .edit: return "pencil"
            case .search: return "magnifyingglass"
            case .command: return "terminal"
            case .thinking: return "sparkles"
            case .subagent: return "person.2"
            case .status, .tool: return "apple.terminal"
            }
        case .running:
            switch phase {
            case .edit: return "pencil"
            case .search: return "magnifyingglass"
            case .command: return "terminal"
            case .thinking: return "sparkles"
            case .subagent: return "person.2"
            case .status, .tool: return "apple.terminal"
            }
        }
    }

    private var iconColor: Color {
        switch state {
        case .failed:
            return DesignTokens.danger.opacity(0.86)
        case .cancelled:
            return DesignTokens.neutral400
        case .running:
            return DesignTokens.tertiaryText
        case .completed:
            return DesignTokens.tertiaryText
        }
    }
}

private struct AttachmentChip: View {
    var attachment: FileAttachment

    private var typeLabel: String {
        let ext = URL(fileURLWithPath: attachment.path).pathExtension.uppercased()
        if !ext.isEmpty { return ext }
        if let mimeType = attachment.mimeType, let suffix = mimeType.split(separator: "/").last {
            return suffix.uppercased()
        }
        return "FILE"
    }

    var body: some View {
        if attachment.isImage, let image = NSImage(contentsOfFile: attachment.path) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 280, maxHeight: 180, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous)
                        .stroke(DesignTokens.separator, lineWidth: 1)
                )
        } else {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous)
                        .fill(attachmentAccent)
                        .frame(width: 40, height: 40)
                    Image(systemName: attachment.isImage ? "photo" : "doc.text")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.fileName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DesignTokens.text)
                        .lineLimit(1)
                    Text(typeLabel)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DesignTokens.tertiaryText)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.largeRadius, style: .continuous)
                    .fill(DesignTokens.background.opacity(0.82))
            )
        }
    }

    private var attachmentAccent: Color {
        switch typeLabel.lowercased() {
        case "pdf":
            return DesignTokens.danger
        case "doc", "docx":
            return DesignTokens.accent
        case "xls", "xlsx", "csv":
            return DesignTokens.success
        case "ppt", "pptx":
            return DesignTokens.warning
        default:
            return DesignTokens.neutral500
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

private struct ComposerTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var hasMarkedText: Bool
    var canSubmit: Bool
    var pasteboardAttachments: (NSPasteboard) -> [FileAttachment]
    var onPasteAttachments: ([FileAttachment]) -> Void
    var onToggleRunMode: () -> Void
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder

        let textView = SubmitTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = NSColor.labelColor
        textView.insertionPointColor = NSColor.controlAccentColor
        textView.textContainerInset = NSSize(width: 8, height: 7)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.string = text
        textView.shouldSubmit = { context.coordinator.canSubmit }
        textView.hasActiveMarkedText = { context.coordinator.hasMarkedText }
        textView.onPaste = { pasteboard in
            context.coordinator.handlePaste(pasteboard)
        }
        textView.onSubmit = {
            Task { @MainActor in
                context.coordinator.submit()
            }
        }
        textView.onToggleRunMode = {
            Task { @MainActor in
                context.coordinator.toggleRunMode()
            }
        }

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.canSubmit = canSubmit
        guard let textView = context.coordinator.textView else { return }
        let isMarked = textView.hasMarkedText() || context.coordinator.hasMarkedText
        if !isMarked, textView.string != text {
            textView.string = text
        }
        textView.shouldSubmit = { context.coordinator.canSubmit }
        textView.hasActiveMarkedText = { context.coordinator.hasMarkedText }
        textView.onPaste = { pasteboard in
            context.coordinator.handlePaste(pasteboard)
        }
        textView.onSubmit = {
            Task { @MainActor in
                context.coordinator.submit()
            }
        }
        textView.onToggleRunMode = {
            Task { @MainActor in
                context.coordinator.toggleRunMode()
            }
        }
        if isFocused, textView.window?.firstResponder !== textView {
            textView.window?.makeFirstResponder(textView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextEditor
        weak var textView: SubmitTextView?
        var canSubmit: Bool
        var hasMarkedText = false

        init(_ parent: ComposerTextEditor) {
            self.parent = parent
            self.canSubmit = parent.canSubmit
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            updateMarkedTextState(textView)
            if !hasMarkedText {
                parent.text = textView.string
            }
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.isFocused = true
            if let textView = notification.object as? NSTextView {
                updateMarkedTextState(textView)
            }
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.isFocused = false
            hasMarkedText = false
            parent.hasMarkedText = false
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            updateMarkedTextState(textView)
        }

        @MainActor
        func handlePaste(_ pasteboard: NSPasteboard) -> Bool {
            let attachments = parent.pasteboardAttachments(pasteboard)
            guard !attachments.isEmpty else { return false }
            if let text = ComposerPasteboardReader.textPayload(from: pasteboard, attachments: attachments),
               let textView {
                textView.insertText(text, replacementRange: textView.selectedRange())
                parent.text = textView.string
            }
            parent.onPasteAttachments(attachments)
            return true
        }

        @MainActor
        func submit() {
            guard canSubmit, !hasMarkedText else { return }
            parent.onSubmit()
        }

        @MainActor
        func toggleRunMode() {
            guard !hasMarkedText else { return }
            parent.onToggleRunMode()
        }

        private func updateMarkedTextState(_ textView: NSTextView) {
            let next = textView.hasMarkedText()
            hasMarkedText = next
            if parent.hasMarkedText != next {
                parent.hasMarkedText = next
            }
        }
    }
}

private final class SubmitTextView: NSTextView {
    var shouldSubmit: () -> Bool = { false }
    var hasActiveMarkedText: () -> Bool = { false }
    var onPaste: (NSPasteboard) -> Bool = { _ in false }
    var onSubmit: () -> Void = {}
    var onToggleRunMode: () -> Void = {}

    override func paste(_ sender: Any?) {
        if onPaste(NSPasteboard.general) {
            return
        }
        super.paste(sender)
    }

    override func keyDown(with event: NSEvent) {
        let normalizedFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isShiftTab = event.keyCode == 48 &&
            normalizedFlags.contains(.shift) &&
            !normalizedFlags.contains(.command) &&
            !normalizedFlags.contains(.control) &&
            !normalizedFlags.contains(.option)
        if isShiftTab {
            if hasMarkedText() || hasActiveMarkedText() {
                super.keyDown(with: event)
            } else {
                onToggleRunMode()
            }
            return
        }

        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, !event.modifierFlags.contains(.shift) {
            if hasMarkedText() || hasActiveMarkedText() {
                super.keyDown(with: event)
            } else if shouldSubmit() {
                onSubmit()
            }
            return
        }
        super.keyDown(with: event)
    }
}

private struct PermissionBanner: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(state.pendingPermissions) { request in
                if request.kind == .askUserQuestion, let payload = request.interactivePayload {
                    AskUserQuestionPanel(request: request, payload: payload)
                        .environmentObject(state)
                } else {
                    GenericPermissionCard(request: request)
                        .environmentObject(state)
                }
            }
        }
    }
}

private struct GenericPermissionCard: View {
    @EnvironmentObject private var state: AppState
    var request: PermissionRequest

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DesignTokens.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(request.reason)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignTokens.text)
                if !request.inputJSON.isEmpty {
                    Text(request.inputJSON)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(DesignTokens.tertiaryText)
                        .lineLimit(2)
                }
            }
            Spacer()
            Button(state.t(.deny)) {
                state.denyPermission(request.id)
            }
            Button(state.t(.allow)) {
                state.approvePermission(request.id)
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

private struct AskUserQuestionPanel: View {
    @EnvironmentObject private var state: AppState
    var request: PermissionRequest
    var payload: AgentInteractivePayload

    @State private var currentIndex = 0
    @State private var selections: [String: Set<String>] = [:]
    @State private var otherAnswers: [String: String] = [:]
    @State private var appeared = false
    @State private var pulse = false

    private var question: AgentQuestion {
        payload.questions[min(currentIndex, max(payload.questions.count - 1, 0))]
    }

    private var isChinese: Bool {
        state.settings.language.resolved() == .chineseSimplified
    }

    private var progressText: String {
        "\(currentIndex + 1) / \(max(payload.questions.count, 1))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(DesignTokens.accent)
                .frame(height: 3)

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(DesignTokens.accent.opacity(pulse ? 0.16 : 0.30))
                            .frame(width: pulse ? 30 : 22, height: pulse ? 30 : 22)
                        Image(systemName: "questionmark.bubble.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(DesignTokens.accent)
                    }
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(question.header?.isEmpty == false ? question.header! : "AskUserQuestion")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(DesignTokens.accent)
                            if payload.questions.count > 1 {
                                Text(progressText)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(DesignTokens.tertiaryText)
                            }
                        }
                        Text(question.question)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(DesignTokens.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button {
                        state.denyPermission(request.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DesignTokens.tertiaryText)
                }

                if payload.questions.count > 1 {
                    HStack(spacing: 5) {
                        ForEach(payload.questions.indices, id: \.self) { index in
                            Capsule()
                                .fill(index == currentIndex ? DesignTokens.accent : DesignTokens.neutral200)
                                .frame(width: index == currentIndex ? 18 : 6, height: 6)
                                .animation(.easeOut(duration: 0.16), value: currentIndex)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(question.options.enumerated()), id: \.element.id) { index, option in
                        optionButton(option: option, index: index)
                    }
                    otherInput
                }

                HStack(spacing: 8) {
                    Button(isChinese ? "跳过" : "Skip") {
                        submit(skip: true)
                    }
                    .buttonStyle(.borderless)

                    Spacer()

                    if currentIndex > 0 {
                        Button(isChinese ? "上一步" : "Back") {
                            withAnimation(.easeOut(duration: 0.16)) {
                                currentIndex -= 1
                            }
                        }
                    }
                    Button(currentIndex == payload.questions.count - 1 ? (isChinese ? "提交" : "Submit") : (isChinese ? "下一步" : "Next")) {
                        if currentIndex == payload.questions.count - 1 {
                            submit(skip: false)
                        } else {
                            withAnimation(.easeOut(duration: 0.16)) {
                                currentIndex += 1
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasAnswer(for: question))
                }
            }
            .padding(14)
        }
        .frame(maxWidth: DesignTokens.composerMaxWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous)
                .fill(DesignTokens.background)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous)
                        .stroke(DesignTokens.separator, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.05), radius: 8, y: 4)
        )
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 8)
        .onAppear {
            withAnimation(.easeOut(duration: 0.18)) {
                appeared = true
            }
            pulse = true
        }
    }

    private func optionButton(option: AgentQuestionOption, index: Int) -> some View {
        let selected = selections[question.question]?.contains(option.label) == true
        return Button {
            toggle(option.label, for: question)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Text("\(index + 1)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selected ? .white : DesignTokens.tertiaryText)
                    .frame(width: 20, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(selected ? DesignTokens.accent : DesignTokens.neutral100)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DesignTokens.text)
                    if let description = option.description, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 12))
                            .foregroundStyle(DesignTokens.tertiaryText)
                    }
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(DesignTokens.accent)
                }
            }
            .padding(10)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                    .fill(selected ? DesignTokens.accent.opacity(0.08) : DesignTokens.neutral50)
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                            .stroke(selected ? DesignTokens.accent.opacity(0.55) : DesignTokens.separator, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var otherInput: some View {
        HStack(spacing: 10) {
            Text(isChinese ? "其他" : "Other")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DesignTokens.tertiaryText)
                .frame(width: 44, alignment: .leading)
            TextField(isChinese ? "输入自定义答案" : "Type a custom answer", text: otherBinding(for: question))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                .fill(DesignTokens.neutral50)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                        .stroke(DesignTokens.separator, lineWidth: 1)
                )
        )
    }

    private func otherBinding(for question: AgentQuestion) -> Binding<String> {
        Binding(
            get: { otherAnswers[question.question] ?? "" },
            set: { otherAnswers[question.question] = $0 }
        )
    }

    private func toggle(_ option: String, for question: AgentQuestion) {
        var values = selections[question.question] ?? []
        if question.multiSelect {
            if values.contains(option) {
                values.remove(option)
            } else {
                values.insert(option)
            }
        } else {
            values = values.contains(option) ? [] : [option]
        }
        selections[question.question] = values
    }

    private func hasAnswer(for question: AgentQuestion) -> Bool {
        !(selections[question.question] ?? []).isEmpty ||
            !(otherAnswers[question.question]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private func submit(skip: Bool) {
        let answers = skip ? [:] : payload.questions.reduce(into: [String: String]()) { result, question in
            var values = Array(selections[question.question] ?? []).sorted()
            let other = otherAnswers[question.question]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !other.isEmpty {
                values.append(other)
            }
            if !values.isEmpty {
                result[question.question] = values.joined(separator: ", ")
            }
        }
        let updated = AgentInteractivePayload.updatedInputJSON(originalInputJSON: request.inputJSON, answers: answers)
        state.approvePermission(request.id, updatedInputJSON: updated)
    }
}

private struct ProcessRunHeader: View {
    @EnvironmentObject private var state: AppState
    var activities: [AgentActivity]
    @State private var now = Date()

    private var visibleActivities: [AgentActivity] {
        activities.filter { activity in
            !activity.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                !activity.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                activity.toolName != nil
        }.sorted { $0.createdAt < $1.createdAt }
    }

    private var isChinese: Bool {
        switch state.settings.language {
        case .chineseSimplified:
            return true
        case .english:
            return false
        case .system:
            return Locale.preferredLanguages.first?.hasPrefix("zh") == true
        }
    }

    private var hasRunningActivity: Bool {
        visibleActivities.contains { $0.state == .running }
    }

    private var runStartedAt: Date {
        visibleActivities.map(\.createdAt).min() ?? Date()
    }

    private var runEndedAt: Date {
        if hasRunningActivity {
            return now
        }
        return visibleActivities.map(\.updatedAt).max() ?? now
    }

    private var headerText: String {
        let duration = formatDuration(max(0, runEndedAt.timeIntervalSince(runStartedAt)))
        return isChinese ? "已处理 \(duration)" : "Processed \(duration)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(headerText)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(DesignTokens.tertiaryText)
                .monospacedDigit()
            Rectangle()
                .fill(DesignTokens.separator)
                .frame(height: 1)
        }
        .frame(maxWidth: DesignTokens.transcriptMaxWidth, alignment: .leading)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { value in
            if hasRunningActivity {
                now = value
            }
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        let rest = total % 60
        return rest == 0 ? "\(minutes)m" : "\(minutes)m \(rest)s"
    }
}

private struct ProcessLiveStatusRow: View {
    @EnvironmentObject private var state: AppState
    var activities: [AgentActivity]
    @State private var expanded = false

    private var visibleActivities: [AgentActivity] {
        activities.filter { activity in
            !activity.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                !activity.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                activity.toolName != nil
        }.sorted { $0.createdAt < $1.createdAt }
    }

    private var isChinese: Bool {
        switch state.settings.language {
        case .chineseSimplified:
            return true
        case .english:
            return false
        case .system:
            return Locale.preferredLanguages.first?.hasPrefix("zh") == true
        }
    }

    private var hasRunningActivity: Bool {
        visibleActivities.contains { $0.state == .running }
    }

    private var summaryText: String {
        let reads = uniqueTargets(for: [.tool], matching: ["read"]).count
        let edits = uniqueTargets(for: [.edit], matching: ["write", "edit", "multi"]).count
        let searches = visibleActivities.filter { $0.phase == .search || matches($0, ["grep", "glob", "search"]) }.count
        let commands = visibleActivities.filter { $0.phase == .command || matches($0, ["bash", "shell", "command"]) }.count
        let otherTools = visibleActivities.filter { $0.toolName != nil }.count

        var parts: [String] = []
        if isChinese {
            if reads > 0 { parts.append("已探索 \(reads) 个文件") }
            if searches > 0 { parts.append("\(searches) 次搜索") }
            if edits > 0 { parts.append("已编辑 \(edits) 个文件") }
            if commands > 0 { parts.append("已运行 \(commands) 条命令") }
            if parts.isEmpty, otherTools > 0 { parts.append("已使用 \(otherTools) 个工具") }
            return parts.isEmpty ? "正在处理" : parts.joined(separator: " ")
        }

        if reads > 0 { parts.append("explored \(reads) \(reads == 1 ? "file" : "files")") }
        if searches > 0 { parts.append("\(searches) \(searches == 1 ? "search" : "searches")") }
        if edits > 0 { parts.append("edited \(edits) \(edits == 1 ? "file" : "files")") }
        if commands > 0 { parts.append("ran \(commands) \(commands == 1 ? "command" : "commands")") }
        if parts.isEmpty, otherTools > 0 { parts.append("used \(otherTools) \(otherTools == 1 ? "tool" : "tools")") }
        return parts.isEmpty ? "Processing" : parts.joined(separator: ", ")
    }

    private var detailRows: [CodexTraceDetailRow] {
        visibleActivities.flatMap { detailRows(for: $0) }
    }

    private var compacting: Bool {
        visibleActivities.contains {
            let haystack = "\($0.title) \($0.detail) \($0.toolName ?? "")".lowercased()
            return haystack.contains("compact") || haystack.contains("压缩")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: traceIcon)
                        .font(.system(size: 13, weight: .medium))
                    Text(summaryText)
                        .font(.system(size: 14, weight: .medium))
                    if hasRunningActivity {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.58)
                    }
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(DesignTokens.tertiaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(detailRows.isEmpty)

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(detailRows) { row in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.title)
                                .font(.system(size: 13))
                                .foregroundStyle(row.isRunning ? DesignTokens.secondaryText : DesignTokens.tertiaryText)
                                .lineLimit(2)
                            if !row.detail.isEmpty {
                                Text(row.detail)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(DesignTokens.tertiaryText.opacity(0.86))
                                    .lineLimit(3)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.leading, 24)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if compacting {
                HStack(spacing: 16) {
                    Rectangle().fill(DesignTokens.separator).frame(height: 1)
                    Text(isChinese ? "正在自动压缩上下文" : "Automatically compacting context")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(DesignTokens.neutral300)
                        .fixedSize()
                    Rectangle().fill(DesignTokens.separator).frame(height: 1)
                }
            }
        }
        .frame(maxWidth: DesignTokens.transcriptMaxWidth, alignment: .leading)
        .animation(.easeOut(duration: 0.18), value: visibleActivities.map { "\($0.id):\($0.state.rawValue)" })
        .onAppear {
            expanded = visibleActivities.contains(where: \.expandedDefault)
        }
    }

    private var traceIcon: String {
        if visibleActivities.contains(where: { $0.state == .failed }) { return "exclamationmark.triangle" }
        if visibleActivities.contains(where: { $0.phase == .command }) { return "terminal" }
        if visibleActivities.contains(where: { $0.phase == .search }) { return "magnifyingglass" }
        return "apple.terminal"
    }

    private func detailRows(for activity: AgentActivity) -> [CodexTraceDetailRow] {
        let base = detailTitle(for: activity)
        var rows = [CodexTraceDetailRow(title: base, detail: compactDetail(for: activity), isRunning: activity.state == .running)]
        for detail in activity.detailMessages where detail.trimmingCharacters(in: .whitespacesAndNewlines) != activity.detail.trimmingCharacters(in: .whitespacesAndNewlines) {
            let compact = compactPreview(detail)
            if !compact.isEmpty {
                rows.append(CodexTraceDetailRow(title: compact, detail: "", isRunning: activity.state == .running))
            }
        }
        return rows
    }

    private func detailTitle(for activity: AgentActivity) -> String {
        let target = target(for: activity)
        let toolName = activity.toolName ?? ""
        let lower = toolName.lowercased()
        if lower.contains("grep") || lower.contains("glob") || lower.contains("search") || activity.phase == .search {
            return target.map { "Searched for \($0)" } ?? (isChinese ? "已搜索" : "Searched")
        }
        if lower.contains("read") {
            return target.map { "Read \($0)" } ?? (isChinese ? "已读取文件" : "Read file")
        }
        if lower.contains("write") || lower.contains("edit") || lower.contains("multi") || activity.phase == .edit {
            return target.map { (activity.state == .running ? (isChinese ? "正在编辑 \($0)" : "Editing \($0)") : (isChinese ? "已编辑 \($0)" : "Edited \($0)")) } ?? (isChinese ? "已编辑文件" : "Edited file")
        }
        if lower.contains("bash") || activity.phase == .command {
            return target.map { (activity.state == .running ? (isChinese ? "正在执行命令 \($0)" : "Running \($0)") : (isChinese ? "已运行命令 \($0)" : "Ran \($0)")) } ?? (isChinese ? "已运行命令" : "Ran command")
        }
        if lower == "askuserquestion" {
            return activity.state == .completed ? (isChinese ? "已回答问题" : "Answered question") : (isChinese ? "等待你的回答" : "Waiting for your answer")
        }
        if lower == "exitplanmode" {
            return activity.state == .completed ? (isChinese ? "已退出计划模式" : "Exited plan mode") : (isChinese ? "正在退出计划模式" : "Exiting plan mode")
        }
        return activity.title.isEmpty ? (isChinese ? "正在处理" : "Processing") : activity.title
    }

    private func compactDetail(for activity: AgentActivity) -> String {
        let detail = compactPreview(activity.detail)
        if detail.hasPrefix("{"), detail.hasSuffix("}") {
            return target(for: activity) ?? ""
        }
        return detail
    }

    private func uniqueTargets(for phases: Set<AgentActivityPhase>, matching names: [String]) -> Set<String> {
        Set(visibleActivities.compactMap { activity in
            guard phases.contains(activity.phase) || matches(activity, names) else { return nil }
            return target(for: activity) ?? activity.id
        })
    }

    private func matches(_ activity: AgentActivity, _ names: [String]) -> Bool {
        let value = "\(activity.toolName ?? "") \(activity.title)".lowercased()
        return names.contains { value.contains($0) }
    }

    private func target(for activity: AgentActivity) -> String? {
        let sources = [activity.detail] + activity.detailMessages
        for source in sources {
            if let object = jsonObject(source) {
                for key in ["file_path", "path", "pattern", "query", "command", "description"] {
                    if let value = object[key] as? String {
                        return displayTarget(value, key: key)
                    }
                }
            }
            let compact = compactPreview(source)
            if !compact.isEmpty, !compact.hasPrefix("{") {
                return displayTarget(compact, key: "")
            }
        }
        return nil
    }

    private func jsonObject(_ value: String) -> [String: Any]? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}"), let data = trimmed.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func displayTarget(_ value: String, key: String) -> String {
        let compact = compactPreview(value)
        if key == "file_path" || key == "path" {
            return URL(fileURLWithPath: compact).lastPathComponent.isEmpty ? compact : URL(fileURLWithPath: compact).lastPathComponent
        }
        return truncate(compact, limit: key == "command" ? 72 : 80)
    }

    private func compactPreview(_ value: String) -> String {
        truncate(
            value
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            limit: 130
        )
    }

    private func truncate(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        let index = value.index(value.startIndex, offsetBy: max(0, limit - 1))
        return String(value[..<index]) + "…"
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        let rest = total % 60
        return rest == 0 ? "\(minutes)m" : "\(minutes)m \(rest)s"
    }
}

private struct CodexTraceDetailRow: Identifiable {
    let id = UUID()
    var title: String
    var detail: String
    var isRunning: Bool
}

private struct ProcessTraceStepRow: View {
    @EnvironmentObject private var state: AppState
    var activity: AgentActivity
    var isExpanded: Bool
    var onToggle: () -> Void

    private var canExpand: Bool {
        !detailLines.isEmpty
    }

    private var detailLines: [String] {
        var lines = activity.detailMessages
        let detail = activity.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !detail.isEmpty, !lines.contains(detail) {
            lines.append(detail)
        }
        return lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var previewText: String? {
        let raw = detailLines.last ?? activity.detail
        let cleaned = compactPreview(raw)
        if cleaned.isEmpty || looksLikeToolInput(raw) {
            return compactTarget()
        }
        return cleaned
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if canExpand {
                    onToggle()
                }
            } label: {
                HStack(alignment: .top, spacing: 9) {
                    ProcessStepIcon(phase: activity.phase, state: activity.state)
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(titleText)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(DesignTokens.text)
                                .lineLimit(1)

                            if let toolName = activity.toolName {
                                Text(toolName)
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(DesignTokens.tertiaryText)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(DesignTokens.neutral100)
                                    )
                            }
                        }

                        if let previewText, !previewText.isEmpty {
                            Text(previewText)
                                .font(.system(size: 11))
                                .foregroundStyle(DesignTokens.tertiaryText)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 8)

                    if canExpand {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(DesignTokens.tertiaryText)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous)
                        .fill(rowBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous)
                                .stroke(rowBorder, lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)

            if isExpanded, canExpand {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(detailLines.enumerated()), id: \.offset) { index, line in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(detailLabel(index: index, count: detailLines.count))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(DesignTokens.tertiaryText)
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(DesignTokens.secondaryText)
                                .lineLimit(12)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                                .fill(DesignTokens.neutral50)
                        )
                    }
                }
                .padding(.leading, 31)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var rowBackground: Color {
        switch activity.state {
        case .running:
            return DesignTokens.accent.opacity(0.045)
        case .failed:
            return DesignTokens.danger.opacity(0.055)
        case .cancelled:
            return DesignTokens.neutral50
        case .completed:
            return DesignTokens.neutral50.opacity(0.82)
        }
    }

    private var rowBorder: Color {
        switch activity.state {
        case .running:
            return DesignTokens.accent.opacity(0.18)
        case .failed:
            return DesignTokens.danger.opacity(0.2)
        default:
            return DesignTokens.separator.opacity(0.72)
        }
    }

    private var titleText: String {
        if let toolName = activity.toolName, !toolName.isEmpty {
            return toolTitle(toolName)
        }
        return statusTitle()
    }

    private func toolTitle(_ toolName: String) -> String {
        let lower = toolName.lowercased()
        let target = compactTarget()
        let suffix = target.map { " \($0)" } ?? ""

        if lower == "read" || lower.contains("read") {
            return localized(
                running: "Reading\(suffix)",
                completed: "Read\(suffix)",
                failed: "Read failed\(suffix)",
                cancelled: "Stopped reading\(suffix)",
                zhRunning: "正在读取\(suffix)",
                zhCompleted: "已读取\(suffix)",
                zhFailed: "读取失败\(suffix)",
                zhCancelled: "已停止读取\(suffix)"
            )
        }
        if lower == "write" || lower.contains("write") || lower.contains("create") {
            return localized(
                running: "Writing\(suffix)",
                completed: "Wrote\(suffix)",
                failed: "Write failed\(suffix)",
                cancelled: "Stopped writing\(suffix)",
                zhRunning: "正在写入\(suffix)",
                zhCompleted: "已写入\(suffix)",
                zhFailed: "写入失败\(suffix)",
                zhCancelled: "已停止写入\(suffix)"
            )
        }
        if lower.contains("edit") || lower.contains("patch") {
            return localized(
                running: "Editing\(suffix)",
                completed: "Edited\(suffix)",
                failed: "Edit failed\(suffix)",
                cancelled: "Stopped editing\(suffix)",
                zhRunning: "正在编辑\(suffix)",
                zhCompleted: "已编辑\(suffix)",
                zhFailed: "编辑失败\(suffix)",
                zhCancelled: "已停止编辑\(suffix)"
            )
        }
        if lower.contains("grep") || lower.contains("glob") || lower.contains("search") {
            return localized(
                running: "Searching\(suffix)",
                completed: "Searched\(suffix)",
                failed: "Search failed\(suffix)",
                cancelled: "Stopped searching\(suffix)",
                zhRunning: "正在搜索\(suffix)",
                zhCompleted: "已搜索\(suffix)",
                zhFailed: "搜索失败\(suffix)",
                zhCancelled: "已停止搜索\(suffix)"
            )
        }
        if lower.contains("bash") || lower.contains("shell") || lower.contains("command") {
            return localized(
                running: "Running command\(suffix)",
                completed: "Ran command\(suffix)",
                failed: "Command failed\(suffix)",
                cancelled: "Stopped command\(suffix)",
                zhRunning: "正在运行命令\(suffix)",
                zhCompleted: "已运行命令\(suffix)",
                zhFailed: "命令失败\(suffix)",
                zhCancelled: "已停止命令\(suffix)"
            )
        }
        if lower == "todoread" {
            return localized(
                running: "Reading todo list",
                completed: "Read todo list",
                failed: "Todo read failed",
                cancelled: "Stopped reading todo list",
                zhRunning: "正在读取待办",
                zhCompleted: "已读取待办",
                zhFailed: "读取待办失败",
                zhCancelled: "已停止读取待办"
            )
        }
        if lower == "todowrite" {
            return localized(
                running: "Updating todo list",
                completed: "Updated todo list",
                failed: "Todo update failed",
                cancelled: "Stopped updating todo list",
                zhRunning: "正在更新待办",
                zhCompleted: "已更新待办",
                zhFailed: "更新待办失败",
                zhCancelled: "已停止更新待办"
            )
        }
        if lower == "askuserquestion" {
            return localized(
                running: "Waiting for your answer",
                completed: "Question answered",
                failed: "Question failed",
                cancelled: "Question skipped",
                zhRunning: "等待你的回答",
                zhCompleted: "已回答问题",
                zhFailed: "提问失败",
                zhCancelled: "已跳过问题"
            )
        }
        if lower == "exitplanmode" {
            return localized(
                running: "Exiting plan mode",
                completed: "Exited plan mode",
                failed: "Plan mode exit failed",
                cancelled: "Plan mode exit stopped",
                zhRunning: "正在退出计划模式",
                zhCompleted: "已退出计划模式",
                zhFailed: "退出计划模式失败",
                zhCancelled: "已停止退出计划模式"
            )
        }

        return localized(
            running: "Running \(toolName)",
            completed: "Completed \(toolName)",
            failed: "\(toolName) failed",
            cancelled: "Stopped \(toolName)",
            zhRunning: "正在运行 \(toolName)",
            zhCompleted: "已完成 \(toolName)",
            zhFailed: "\(toolName) 失败",
            zhCancelled: "已停止 \(toolName)"
        )
    }

    private func statusTitle() -> String {
        let normalized = "\(activity.title) \(activity.detail)".lowercased()
        if normalized.contains("connect") {
            return isChinese ? "正在连接模型" : "Connecting to model"
        }
        if normalized.contains("stream") || normalized.contains("receiving") || normalized.contains("接收") {
            return isChinese ? "正在生成回复" : "Generating response"
        }
        if normalized.contains("permission") || normalized.contains("权限") {
            return isChinese ? "等待权限确认" : "Waiting for permission"
        }
        if normalized.contains("think") || normalized.contains("process") || normalized.contains("处理") || normalized.contains("working") {
            return isChinese ? "正在思考" : "Thinking"
        }
        if activity.state == .completed {
            return isChinese ? "已完成" : "Completed"
        }
        if activity.state == .failed {
            return isChinese ? "失败" : "Failed"
        }
        if activity.state == .cancelled {
            return isChinese ? "已停止" : "Stopped"
        }
        return activity.title.isEmpty ? state.t(.working) : activity.title
    }

    private func localized(
        running: String,
        completed: String,
        failed: String,
        cancelled: String,
        zhRunning: String,
        zhCompleted: String,
        zhFailed: String,
        zhCancelled: String
    ) -> String {
        switch activity.state {
        case .running:
            return isChinese ? zhRunning : running
        case .completed:
            return isChinese ? zhCompleted : completed
        case .failed:
            return isChinese ? zhFailed : failed
        case .cancelled:
            return isChinese ? zhCancelled : cancelled
        }
    }

    private var isChinese: Bool {
        switch state.settings.language {
        case .chineseSimplified:
            return true
        case .english:
            return false
        case .system:
            return Locale.preferredLanguages.first?.hasPrefix("zh") == true
        }
    }

    private func compactTarget() -> String? {
        guard let object = toolInputObject() else { return nil }
        for key in ["file_path", "path", "pattern", "command", "query", "description"] {
            if let value = object[key] as? String {
                let compact = compactPreview(value)
                if !compact.isEmpty {
                    return truncate(compact, limit: key == "command" ? 56 : 44)
                }
            }
        }
        return nil
    }

    private func toolInputObject() -> [String: Any]? {
        for line in detailLines {
            guard looksLikeToolInput(line), let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            return object
        }
        return nil
    }

    private func detailLabel(index: Int, count: Int) -> String {
        if count == 1 {
            return isChinese ? "详情" : "Detail"
        }
        if index == 0, looksLikeToolInput(detailLines[index]) {
            return isChinese ? "输入" : "Input"
        }
        if index == count - 1 {
            return isChinese ? "结果" : "Result"
        }
        return isChinese ? "详情" : "Detail"
    }

    private func compactPreview(_ value: String) -> String {
        truncate(
            value
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            limit: 110
        )
    }

    private func truncate(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        let index = value.index(value.startIndex, offsetBy: max(0, limit - 1))
        return String(value[..<index]) + "…"
    }

    private func looksLikeToolInput(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("{") && trimmed.hasSuffix("}")
    }
}

private struct ProcessStepIcon: View {
    var phase: AgentActivityPhase
    var state: AgentActivityState
    @State private var pulse = false

    var body: some View {
        ZStack {
            if state == .running {
                Circle()
                    .stroke(iconColor.opacity(0.22), lineWidth: 1)
                    .scaleEffect(pulse ? 1.42 : 0.72)
                    .opacity(pulse ? 0 : 0.62)
                    .animation(
                        .easeOut(duration: 1.05).repeatForever(autoreverses: false),
                        value: pulse
                    )
            }

            Circle()
                .fill(iconColor.opacity(state == .running ? 0.12 : 0.1))
                .frame(width: 22, height: 22)

            if state == .running {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.48)
            } else {
                Image(systemName: iconName)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(iconColor)
            }
        }
        .frame(width: 24, height: 24)
        .onAppear {
            if state == .running {
                pulse = true
            }
        }
    }

    private var iconName: String {
        if state == .completed { return "checkmark" }
        if state == .failed { return "exclamationmark" }
        if state == .cancelled { return "xmark" }
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

    private var iconColor: Color {
        switch state {
        case .running:
            return DesignTokens.accent
        case .completed:
            return DesignTokens.success
        case .failed:
            return DesignTokens.danger
        case .cancelled:
            return DesignTokens.tertiaryText
        }
    }
}

private struct ComposerControlButtonStyle: ButtonStyle {
    var foreground: Color = DesignTokens.secondaryText
    var idleBackground: Color = .clear
    var pressedBackground: Color = DesignTokens.neutral100

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foreground)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                    .fill(configuration.isPressed ? pressedBackground : idleBackground)
            )
            .opacity(configuration.isPressed ? 0.76 : 1)
    }
}
