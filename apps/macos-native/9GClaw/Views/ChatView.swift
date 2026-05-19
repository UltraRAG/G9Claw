import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @EnvironmentObject private var state: AppState
    @State private var scrollPinning = ChatScrollPinningState()

    var body: some View {
        conversationBody
        .background(Color.clear)
    }

    private var conversationBody: some View {
        Group {
            if state.currentMessages.isEmpty {
                emptyLanding
            } else {
                VStack(spacing: 0) {
                    ScrollViewReader { proxy in
                        GeometryReader { geometry in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 18) {
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
                                    Color.clear
                                        .frame(height: 1)
                                        .id(ChatScrollTarget.bottom)
                                        .background(
                                            GeometryReader { bottomProxy in
                                                Color.clear.preference(
                                                    key: ChatBottomOffsetPreferenceKey.self,
                                                    value: bottomProxy.frame(in: .named(ChatScrollTarget.coordinateSpace)).maxY
                                                )
                                            }
                                        )
                                }
                                .padding(.horizontal, DesignTokens.transcriptPaddingH)
                                .padding(.vertical, DesignTokens.transcriptPaddingV)
                                .frame(maxWidth: DesignTokens.transcriptMaxWidth)
                                .frame(maxWidth: .infinity)
                            }
                            .coordinateSpace(name: ChatScrollTarget.coordinateSpace)
                            .scrollIndicators(.automatic)
                            .onPreferenceChange(ChatBottomOffsetPreferenceKey.self) { bottom in
                                scrollPinning.update(bottomY: bottom, viewportHeight: geometry.size.height)
                            }
                            .onChange(of: state.currentMessages.count) { _, _ in
                                followBottomIfPinned(proxy)
                            }
                            .onChange(of: state.currentActivities.count) { _, _ in
                                guard isPinnedToBottom, !traceActivities.isEmpty else { return }
                                followBottomIfPinned(proxy)
                            }
                            .onChange(of: state.streamRenderRevision) { _, _ in
                                followBottomIfPinned(proxy)
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

    private var isPinnedToBottom: Bool {
        scrollPinning.isPinnedToBottom
    }

    private func followBottomIfPinned(_ proxy: ScrollViewProxy) {
        guard scrollPinning.shouldFollowOutput else { return }
        scrollPinning.recordProgrammaticScroll()
        withAnimation(.easeOut(duration: 0.16)) {
            proxy.scrollTo(ChatScrollTarget.bottom, anchor: .bottom)
        }
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

private enum ChatScrollTarget {
    static let bottom = "chat-bottom-sentinel"
    static let coordinateSpace = "chat-scroll"
}

private struct ChatBottomOffsetPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ChatScrollPinningState: Equatable {
    static let attachThreshold: CGFloat = 24
    static let detachThreshold: CGFloat = 72
    static let programmaticGraceInterval: TimeInterval = 0.35

    var isPinnedToBottom = true
    var lastProgrammaticScrollAt: Date?

    var shouldFollowOutput: Bool {
        isPinnedToBottom
    }

    mutating func recordProgrammaticScroll(now: Date = Date()) {
        isPinnedToBottom = true
        lastProgrammaticScrollAt = now
    }

    mutating func update(bottomY: CGFloat, viewportHeight: CGFloat, now: Date = Date()) {
        let gap = max(0, bottomY - viewportHeight)
        if let lastProgrammaticScrollAt,
           now.timeIntervalSince(lastProgrammaticScrollAt) < Self.programmaticGraceInterval,
           gap <= Self.detachThreshold {
            return
        }
        if gap <= Self.attachThreshold {
            isPinnedToBottom = true
        } else if gap >= Self.detachThreshold {
            isPinnedToBottom = false
        }
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
                    .padding(.bottom, 4)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if !state.pendingPermissions.isEmpty {
                Group {
                    if state.pendingPermissions.count > 1 {
                        ScrollView(.vertical, showsIndicators: true) {
                            PermissionBanner()
                                .environmentObject(state)
                                .padding(.vertical, 2)
                        }
                        .frame(maxHeight: 132)
                    } else {
                        PermissionBanner()
                            .environmentObject(state)
                    }
                }
                .frame(maxWidth: DesignTokens.composerMaxWidth)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            ComposerCard(chromeless: false)
                .environmentObject(state)
                .frame(maxWidth: DesignTokens.composerMaxWidth)
        }
        .padding(.horizontal, 24)
        .padding(.top, 6)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [
                    DesignTokens.background.opacity(0.0),
                    DesignTokens.background.opacity(0.62),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .allowsHitTesting(false)
        )
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
        HStack(spacing: 7) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.52)
                .tint(CodexProcessStyle.iconMuted)
            if activity.phase == .thinking || activity.phase == .status {
                ShimmeringProcessText(text: text, font: .system(size: 12.5, weight: .medium))
                    .lineLimit(1)
            } else {
                Text(text)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(CodexProcessStyle.detail)
                    .lineLimit(1)
            }
            if !activity.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(activity.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(CodexProcessStyle.detail.opacity(0.68))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: DesignTokens.composerMaxWidth)
        .padding(.horizontal, 4)
        .frame(height: 22)
        .animation(.easeOut(duration: 0.16), value: activity.id)
    }
}

private struct ShimmeringProcessText: View {
    var text: String
    var font: Font
    var baseColor: Color = CodexProcessStyle.detail
    @State private var phase: CGFloat = -0.55

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(
                LinearGradient(
                    colors: [
                        baseColor.opacity(0.48),
                        CodexProcessStyle.detailStrong.opacity(0.92),
                        baseColor.opacity(0.48),
                    ],
                    startPoint: UnitPoint(x: phase, y: 0.5),
                    endPoint: UnitPoint(x: phase + 0.72, y: 0.5)
                )
            )
            .onAppear {
                phase = -0.55
                withAnimation(.linear(duration: 1.55).repeatForever(autoreverses: false)) {
                    phase = 1.15
                }
            }
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
            ComposerGlassBackground(isFocused: focused, chromeless: chromeless)
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
                    if latestTokenBudget != nil {
                        Text(contextLevelLabel)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(contextTone)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(contextTone.opacity(0.10), in: Capsule())
                    }
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
            .background(DesignTokens.background.opacity(0.92))
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
        return "--"
    }

    private var contextDetailText: String {
        guard let latestTokenBudget else {
            return state.t(.contextUsageDetail)
        }
        if state.settings.language.resolved() == .chineseSimplified {
            return "\(contextLevelLabel)：已用 \(latestTokenBudget.used.formatted()) token，共 \(latestTokenBudget.total.formatted())。"
        }
        return "\(contextLevelLabel): Used \(latestTokenBudget.used.formatted()) tokens of \(latestTokenBudget.total.formatted())."
    }

    private var contextLevel: ContextBudgetLevel? {
        guard let latestTokenBudget else { return nil }
        return latestTokenBudget.level ?? ContextBudgetLevel.level(used: latestTokenBudget.used, total: latestTokenBudget.total)
    }

    private var contextLevelLabel: String {
        let isChinese = state.settings.language.resolved() == .chineseSimplified
        switch contextLevel ?? .normal {
        case .normal:
            return isChinese ? "正常" : "Normal"
        case .attention:
            return isChinese ? "关注" : "Attention"
        case .warning:
            return isChinese ? "警告" : "Warning"
        case .compacting:
            return isChinese ? "压缩中" : "Compacting"
        case .recovering:
            return isChinese ? "恢复中" : "Recovering"
        }
    }

    private var contextTone: Color {
        switch contextLevel {
        case .recovering:
            return DesignTokens.danger
        case .compacting, .warning:
            return DesignTokens.warning
        case .attention:
            return DesignTokens.accent
        case .normal:
            return DesignTokens.tertiaryText
        case nil:
            return DesignTokens.neutral400
        }
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

    private let assistantFontSize: CGFloat = 14.5
    private let userFontSize: CGFloat = 14.5

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
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
                    userBlockView(block)
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 10)
            .frame(maxWidth: (DesignTokens.transcriptMaxWidth - DesignTokens.transcriptPaddingH * 2) * 0.78, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.userBubbleRadius, style: .continuous)
                    .fill(DesignTokens.neutral100)
            )
        }
        .frame(maxWidth: .infinity)
    }

    private var assistantRow: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
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
            .frame(maxWidth: .infinity, alignment: .leading)

            if !message.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    copyAssistantMessage()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12.5, weight: .medium))
                        .frame(width: 24, height: 24)
                        .background(DesignTokens.neutral100.opacity(0.72), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(state.settings.language.resolved() == .chineseSimplified ? "复制输出" : "Copy response")
                .opacity(0.72)
            }
        }
        .font(.system(size: assistantFontSize))
        .lineSpacing(5)
        .foregroundStyle(DesignTokens.text)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func copyAssistantMessage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.plainText, forType: .string)
    }

    private var assistantSegments: [AssistantBlockSegment] {
        var segments: [AssistantBlockSegment] = []
        let pairedToolCallIDs = Set(message.blocks.compactMap { block -> String? in
            guard case .toolCall(let call) = block else { return nil }
            return call.id
        })
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
                if !pairedToolCallIDs.contains(result.toolCallId), !consumedResultIDs.contains(result.toolCallId) {
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
                NativeMarkdownView(text: text, fontSize: assistantFontSize, lineSpacing: 5)
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
            NativeMarkdownView(text: text, fontSize: assistantFontSize, lineSpacing: 5)
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

private enum CodexProcessStyle {
    static let title = DesignTokens.neutral500.opacity(0.90)
    static let titleStrong = DesignTokens.neutral600.opacity(0.88)
    static let detail = DesignTokens.neutral400.opacity(0.92)
    static let detailStrong = DesignTokens.neutral500.opacity(0.86)
    static let icon = DesignTokens.neutral500.opacity(0.88)
    static let iconMuted = DesignTokens.neutral400.opacity(0.86)
    static let rowFont = Font.system(size: 13.5, weight: .medium)
    static let detailFont = Font.system(size: 12, weight: .regular)
    static let detailMonoFont = Font.system(size: 11.5, weight: .regular, design: .monospaced)
}

struct ToolInvocationField: Equatable {
    var label: String
    var value: String
    var isPrimary: Bool = false
}

struct ToolInvocationPresentation: Equatable {
    var toolName: String
    var title: String
    var command: String?
    var fields: [ToolInvocationField]
    var rawInput: String
    var parsed: Bool

    var primaryValue: String? {
        if let command, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return command
        }
        return fields.first(where: \.isPrimary)?.value ?? fields.first?.value
    }

    static func parse(toolName rawToolName: String, inputJSON: String) -> ToolInvocationPresentation {
        let toolName = AgentToolNameCanonicalizer.canonical(rawToolName)
        guard let data = inputJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ToolInvocationPresentation(
                toolName: toolName,
                title: toolName,
                command: nil,
                fields: [ToolInvocationField(label: "Raw input", value: inputJSON, isPrimary: true)],
                rawInput: inputJSON,
                parsed: false
            )
        }

        let presentation = parsedPresentation(toolName: toolName, object: object, rawInput: inputJSON)
        if presentation.command?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false || !presentation.fields.isEmpty {
            return presentation
        }
        return ToolInvocationPresentation(
            toolName: toolName,
            title: toolName,
            command: nil,
            fields: [ToolInvocationField(label: "Raw input", value: inputJSON, isPrimary: true)],
            rawInput: inputJSON,
            parsed: false
        )
    }

    static func target(toolName: String, inputJSON: String, limit: Int = 72) -> String? {
        parse(toolName: toolName, inputJSON: inputJSON).primaryValue.map { compact($0, limit: limit) }
    }

    private static func parsedPresentation(toolName: String, object: [String: Any], rawInput: String) -> ToolInvocationPresentation {
        switch toolName {
        case "Shell":
            return ToolInvocationPresentation(
                toolName: toolName,
                title: "Shell",
                command: stringValue(for: ["command", "input_command", "input", "cmd"], in: object),
                fields: fields([
                    ("cwd", "Cwd", true),
                    ("description", "Description", false),
                    ("timeout", "Timeout", false),
                ], in: object),
                rawInput: rawInput,
                parsed: true
            )
        case "Read":
            return fieldPresentation(toolName, rawInput, object, [
                (["file_path", "path"], "Path", true),
                (["offset"], "Offset", false),
                (["limit"], "Limit", false),
            ])
        case "Grep":
            return fieldPresentation(toolName, rawInput, object, [
                (["pattern", "query"], "Pattern", true),
                (["path"], "Path", false),
                (["glob"], "Glob", false),
            ])
        case "Glob":
            return fieldPresentation(toolName, rawInput, object, [
                (["pattern", "glob"], "Pattern", true),
                (["path"], "Path", false),
            ])
        case "StrReplace":
            return fieldPresentation(toolName, rawInput, object, [
                (["file_path", "path"], "Path", true),
                (["old_string", "oldString"], "Old", false),
                (["new_string", "newString"], "New", false),
                (["replace_all"], "Replace all", false),
            ])
        case "Write":
            return fieldPresentation(toolName, rawInput, object, [
                (["file_path", "path"], "Path", true),
                (["content"], "Content", false),
            ])
        case "Task":
            return fieldPresentation(toolName, rawInput, object, [
                (["description"], "Description", true),
                (["prompt"], "Prompt", true),
                (["type", "subagent_type"], "Type", false),
                (["cwd"], "Cwd", false),
            ])
        case "Skill":
            return fieldPresentation(toolName, rawInput, object, [
                (["skill"], "Skill", true),
                (["args"], "Args", false),
            ])
        case "WebSearch":
            return fieldPresentation(toolName, rawInput, object, [
                (["query", "q"], "Query", true),
            ])
        case "WebFetch":
            return fieldPresentation(toolName, rawInput, object, [
                (["url"], "URL", true),
                (["prompt"], "Prompt", false),
            ])
        case "SemanticSearch":
            return fieldPresentation(toolName, rawInput, object, [
                (["query"], "Query", true),
                (["path"], "Path", false),
            ])
        default:
            return fieldPresentation(toolName, rawInput, object, [
                (["file_path", "path"], "Path", true),
                (["pattern"], "Pattern", true),
                (["query"], "Query", true),
                (["description"], "Description", true),
                (["prompt"], "Prompt", true),
                (["url"], "URL", true),
            ])
        }
    }

    private static func fieldPresentation(
        _ toolName: String,
        _ rawInput: String,
        _ object: [String: Any],
        _ specs: [([String], String, Bool)]
    ) -> ToolInvocationPresentation {
        var output: [ToolInvocationField] = []
        for spec in specs {
            guard let value = stringValue(for: spec.0, in: object),
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            output.append(ToolInvocationField(label: spec.1, value: value, isPrimary: spec.2 && !output.contains(where: \.isPrimary)))
        }
        return ToolInvocationPresentation(toolName: toolName, title: toolName, command: nil, fields: output, rawInput: rawInput, parsed: true)
    }

    private static func fields(_ specs: [(String, String, Bool)], in object: [String: Any]) -> [ToolInvocationField] {
        specs.compactMap { key, label, primary in
            guard let value = displayString(object[key]),
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return ToolInvocationField(label: label, value: value, isPrimary: primary)
        }
    }

    private static func stringValue(for keys: [String], in object: [String: Any]) -> String? {
        for key in keys {
            guard let value = displayString(object[key]) else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func displayString(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return string
    }

    private static func compact(_ value: String, limit: Int) -> String {
        let normalized = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        let index = normalized.index(normalized.startIndex, offsetBy: max(0, limit - 1))
        return String(normalized[..<index]) + "…"
    }
}

struct ProcessTraceSummary: Equatable {
    var text: String
    var shouldShimmer: Bool
    var runningActivityID: String?

    static func make(activities: [AgentActivity], isChinese: Bool) -> ProcessTraceSummary {
        let visible = activities.filter { activity in
            !activity.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                !activity.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                activity.toolName != nil
        }.sorted { $0.createdAt < $1.createdAt }

        if let running = visible.last(where: { $0.state == .running && $0.toolName != nil }) {
            return ProcessTraceSummary(
                text: runningText(for: running, isChinese: isChinese),
                shouldShimmer: true,
                runningActivityID: running.id
            )
        }
        if let running = visible.last(where: { $0.state == .running }) {
            return ProcessTraceSummary(
                text: running.title.isEmpty ? (isChinese ? "正在处理" : "Processing") : running.title,
                shouldShimmer: true,
                runningActivityID: running.id
            )
        }
        return ProcessTraceSummary(text: aggregateText(for: visible, isChinese: isChinese), shouldShimmer: false, runningActivityID: nil)
    }

    private static func runningText(for activity: AgentActivity, isChinese: Bool) -> String {
        let targetText = target(for: activity).map { " \($0)" } ?? ""
        let toolName = activity.toolName ?? ""
        let phase = AgentToolPresentationClassifier.phase(forToolName: toolName)
        if AgentToolPresentationClassifier.isReadTool(toolName) {
            return isChinese ? "正在读取\(targetText)" : "Reading\(targetText)"
        }
        switch phase {
        case .search:
            return isChinese ? "正在搜索\(targetText)" : "Searching\(targetText)"
        case .command:
            return isChinese ? "正在执行\(targetText)" : "Running\(targetText)"
        case .edit:
            return isChinese ? "正在编辑\(targetText)" : "Editing\(targetText)"
        case .subagent:
            return isChinese ? "正在运行任务\(targetText)" : "Running task\(targetText)"
        default:
            let fallback = activity.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return fallback.isEmpty ? (isChinese ? "正在处理" : "Processing") : fallback
        }
    }

    private static func aggregateText(for activities: [AgentActivity], isChinese: Bool) -> String {
        let reads = uniqueTargets(in: activities) { activity in
            activity.toolName.map(AgentToolPresentationClassifier.isReadTool) == true
        }.count
        let edits = uniqueTargets(in: activities) { AgentToolPresentationClassifier.phase(forToolName: $0.toolName ?? "") == .edit }.count
        let searches = activities.filter { AgentToolPresentationClassifier.phase(forToolName: $0.toolName ?? "") == .search }.count
        let commands = activities.filter { AgentToolPresentationClassifier.phase(forToolName: $0.toolName ?? "") == .command }.count
        let otherTools = activities.filter { $0.toolName != nil }.count

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

    private static func uniqueTargets(in activities: [AgentActivity], where predicate: (AgentActivity) -> Bool) -> Set<String> {
        Set(activities.compactMap { activity in
            guard predicate(activity) else { return nil }
            return target(for: activity) ?? activity.id
        })
    }

    private static func target(for activity: AgentActivity) -> String? {
        guard let toolName = activity.toolName else { return nil }
        let sources = [activity.detail] + activity.detailMessages
        for source in sources {
            if let target = ToolInvocationPresentation.target(toolName: toolName, inputJSON: source, limit: 64) {
                return target
            }
            let compact = compact(source, limit: 64)
            if !compact.isEmpty, !compact.hasPrefix("{") {
                return compact
            }
        }
        return nil
    }

    private static func compact(_ value: String, limit: Int) -> String {
        let normalized = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        let index = normalized.index(normalized.startIndex, offsetBy: max(0, limit - 1))
        return String(normalized[..<index]) + "…"
    }
}

private struct InlineProcessToolRow: View {
    @EnvironmentObject private var state: AppState
    var call: ToolCall
    var result: ToolResult?

    private var failed: Bool { result?.isError == true }
    private var running: Bool { result == nil }
    private var expansionKey: String { "tool:\(call.id)" }
    private var expanded: Bool { state.expandedToolRowIDs.contains(expansionKey) }
    private var presentation: ToolInvocationPresentation {
        ToolInvocationPresentation.parse(toolName: call.name, inputJSON: call.inputJSON)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    if expanded {
                        state.expandedToolRowIDs.remove(expansionKey)
                    } else {
                        state.expandedToolRowIDs.insert(expansionKey)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    CodexInlineToolIcon(phase: phase, state: stateForRow)
                    if running {
                        ShimmeringProcessText(text: title, font: CodexProcessStyle.rowFont)
                            .lineLimit(1)
                    } else {
                        Text(title)
                            .font(CodexProcessStyle.rowFont)
                            .foregroundStyle(failed ? DesignTokens.danger.opacity(0.78) : CodexProcessStyle.title)
                            .lineLimit(1)
                    }
                    if running {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.50)
                            .tint(CodexProcessStyle.iconMuted)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CodexProcessStyle.detail)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ToolInvocationDetailCard(
                        presentation: presentation,
                        result: result,
                        isChinese: isChinese
                    )
                    if let result {
                        if let image = ParsedToolImage.parse(result.output) {
                            ToolImagePreview(parsed: image)
                        }
                    }
                    RawToolInputDisclosure(rawInput: call.inputJSON, isChinese: isChinese)
                }
                .padding(.leading, 31)
                .transition(.opacity.combined(with: .scale(scale: 0.99, anchor: .topLeading)))
            }
        }
        .padding(.vertical, failed ? 4 : 5)
    }

    private var title: String {
        let target = ToolInvocationPresentation.target(toolName: call.name, inputJSON: call.inputJSON, limit: 56)
        let suffix = target.map { " \($0)" } ?? ""
        let canonical = AgentToolNameCanonicalizer.canonical(call.name).lowercased()
        switch phase {
        case .search:
            return running ? localized("正在搜索\(suffix)", "Searching\(suffix)") : localized("已搜索\(suffix)", "Searched\(suffix)")
        case .command:
            return running ? localized("正在运行命令\(suffix)", "Running command\(suffix)") : localized("已运行命令\(suffix)", "Ran command\(suffix)")
        case .edit:
            return running ? localized("正在编辑\(suffix)", "Editing\(suffix)") : localized("已编辑\(suffix)", "Edited\(suffix)")
        case .subagent:
            return running ? localized("正在运行任务\(suffix)", "Running task\(suffix)") : localized("已运行任务\(suffix)", "Ran task\(suffix)")
        default:
            break
        }
        if AgentToolPresentationClassifier.isReadTool(call.name) {
            return running ? localized("正在读取\(suffix)", "Reading\(suffix)") : localized("已读取\(suffix)", "Read\(suffix)")
        }
        if canonical == "askquestion" {
            return running ? localized("等待你的回答", "Waiting for your answer") : localized("已回答问题", "Answered question")
        }
        if failed {
            return localized("\(call.name) 失败", "\(call.name) failed")
        }
        return running ? localized("正在运行 \(call.name)", "Running \(call.name)") : localized("已完成 \(call.name)", "Completed \(call.name)")
    }

    private var phase: AgentActivityPhase {
        AgentToolPresentationClassifier.phase(forToolName: call.name)
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
}

private struct ToolInvocationDetailCard: View {
    var presentation: ToolInvocationPresentation
    var result: ToolResult?
    var isChinese: Bool

    private var failed: Bool { result?.isError == true }
    private var statusText: String {
        if result == nil { return isChinese ? "运行中" : "Running" }
        return failed ? (isChinese ? "失败" : "Failed") : (isChinese ? "成功" : "Succeeded")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(presentation.title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(CodexProcessStyle.titleStrong)

            if let command = presentation.command {
                Text(prompt(command))
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundStyle(DesignTokens.text)
                    .lineSpacing(3)
                    .lineLimit(10)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(presentation.fields.enumerated()), id: \.offset) { _, field in
                        ToolInvocationFieldRow(field: field)
                    }
                }
            }

            if let output = result?.output.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
                Divider().opacity(0.58)
                Text(output)
                    .font(CodexProcessStyle.detailMonoFont)
                    .foregroundStyle(failed ? DesignTokens.danger.opacity(0.86) : CodexProcessStyle.detailStrong)
                    .lineSpacing(3)
                    .lineLimit(14)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 5) {
                Spacer(minLength: 0)
                Image(systemName: result == nil ? "hourglass" : (failed ? "xmark" : "checkmark"))
                    .font(.system(size: 11, weight: .medium))
                Text(statusText)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(failed ? DesignTokens.danger.opacity(0.82) : CodexProcessStyle.detail)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous)
                .fill(DesignTokens.neutral100.opacity(0.70))
        )
    }

    private func prompt(_ command: String) -> String {
        "$ " + command.replacingOccurrences(of: "\n", with: "\n  ")
    }
}

private struct ToolInvocationFieldRow: View {
    var field: ToolInvocationField

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(field.label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(CodexProcessStyle.detail)
            Text(field.value)
                .font(CodexProcessStyle.detailMonoFont)
                .foregroundStyle(field.isPrimary ? DesignTokens.text : CodexProcessStyle.detailStrong)
                .lineLimit(field.isPrimary ? 6 : 4)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RawToolInputDisclosure: View {
    var rawInput: String
    var isChinese: Bool
    @State private var isExpanded = false

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.14)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9.5, weight: .semibold))
                Text(isChinese ? "原始工具输入" : "Raw tool input")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(CodexProcessStyle.detail)
        }
        .buttonStyle(.plain)

        if isExpanded {
            Text(rawInput)
                .font(CodexProcessStyle.detailMonoFont)
                .foregroundStyle(CodexProcessStyle.detailStrong)
                .lineLimit(12)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(DesignTokens.neutral50.opacity(0.55), in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous))
                .transition(.opacity)
        }
    }
}

private struct ToolInvocationCompactDetail: View {
    var presentation: ToolInvocationPresentation
    var output: String?
    var isError: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let command = presentation.command {
                Text("$ " + compact(command, limit: 180))
                    .font(CodexProcessStyle.detailMonoFont)
                    .foregroundStyle(DesignTokens.text)
                    .lineLimit(3)
                    .textSelection(.enabled)
            } else if !presentation.fields.isEmpty {
                ForEach(Array(presentation.fields.prefix(2).enumerated()), id: \.offset) { _, field in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(field.label)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(CodexProcessStyle.detail)
                            .frame(width: 70, alignment: .leading)
                        Text(compact(field.value, limit: 180))
                            .font(CodexProcessStyle.detailMonoFont)
                            .foregroundStyle(field.isPrimary ? DesignTokens.text : CodexProcessStyle.detailStrong)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
            }
            if let output = output?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
                Text(compact(output, limit: 180))
                    .font(CodexProcessStyle.detailMonoFont)
                    .foregroundStyle(isError ? DesignTokens.danger.opacity(0.86) : CodexProcessStyle.detail)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
        .padding(.leading, 28)
    }

    private func compact(_ value: String, limit: Int) -> String {
        let normalized = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        let index = normalized.index(normalized.startIndex, offsetBy: max(0, limit - 1))
        return String(normalized[..<index]) + "..."
    }
}

private struct InlineProcessToolGroupRow: View {
    @EnvironmentObject private var state: AppState
    var items: [(ToolCall, ToolResult?)]

    private var isRunning: Bool { items.contains { $0.1 == nil } }
    private var hasFailure: Bool { items.contains { $0.1?.isError == true } }
    private var expansionKey: String {
        "tool-group:" + items.map { $0.0.id }.joined(separator: ",")
    }
    private var expanded: Bool { state.expandedToolRowIDs.contains(expansionKey) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    if expanded {
                        state.expandedToolRowIDs.remove(expansionKey)
                    } else {
                        state.expandedToolRowIDs.insert(expansionKey)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    CodexInlineToolIcon(phase: dominantPhase, state: groupState)
                    if isRunning {
                        ShimmeringProcessText(text: summaryText, font: CodexProcessStyle.rowFont)
                            .lineLimit(1)
                    } else {
                        Text(summaryText)
                            .font(CodexProcessStyle.rowFont)
                            .foregroundStyle(hasFailure ? DesignTokens.danger.opacity(0.78) : CodexProcessStyle.title)
                            .lineLimit(1)
                    }
                    if isRunning {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.50)
                            .tint(CodexProcessStyle.iconMuted)
                    }
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CodexProcessStyle.detail)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 7) {
                                CodexInlineToolIcon(phase: phase(for: item.0), state: state(for: item.1))
                                    .scaleEffect(0.86)
                                Text(lineTitle(for: item.0, result: item.1))
                                    .font(CodexProcessStyle.detailFont)
                                    .foregroundStyle(CodexProcessStyle.detailStrong)
                                    .lineLimit(1)
                            }
                            ToolInvocationCompactDetail(
                                presentation: ToolInvocationPresentation.parse(toolName: item.0.name, inputJSON: item.0.inputJSON),
                                output: item.1?.output,
                                isError: item.1?.isError == true
                            )
                        }
                    }
                }
                .padding(.leading, 31)
                .transition(.opacity.combined(with: .scale(scale: 0.99, anchor: .topLeading)))
            }
        }
        .padding(.vertical, hasFailure ? 4 : 5)
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
        if let running = items.last(where: { $0.1 == nil }) {
            return lineTitle(for: running.0, result: nil)
        }
        let readTargets = Set(items.compactMap { item -> String? in
            AgentToolPresentationClassifier.isReadTool(item.0.name) ? target(for: item.0) ?? item.0.id : nil
        })
        let editTargets = Set(items.compactMap { item -> String? in
            phase(for: item.0) == .edit ? target(for: item.0) ?? item.0.id : nil
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
        let targetText = target(for: call).map { " \($0)" } ?? ""
        let running = result == nil
        if AgentToolPresentationClassifier.isReadTool(call.name) { return running ? localized("正在读取\(targetText)", "Reading\(targetText)") : localized("已读取\(targetText)", "Read\(targetText)") }
        switch phase(for: call) {
        case .search:
            return running ? localized("正在搜索\(targetText)", "Searching\(targetText)") : localized("已搜索\(targetText)", "Searched\(targetText)")
        case .edit:
            return running ? localized("正在编辑\(targetText)", "Editing\(targetText)") : localized("已编辑\(targetText)", "Edited\(targetText)")
        case .command:
            return running ? localized("正在运行命令\(targetText)", "Running command\(targetText)") : localized("已运行命令\(targetText)", "Ran command\(targetText)")
        case .subagent:
            return running ? localized("正在运行任务\(targetText)", "Running task\(targetText)") : localized("已运行任务\(targetText)", "Ran task\(targetText)")
        default:
            break
        }
        return running ? localized("正在运行 \(call.name)", "Running \(call.name)") : localized("已完成 \(call.name)", "Completed \(call.name)")
    }

    private func phase(for call: ToolCall) -> AgentActivityPhase {
        AgentToolPresentationClassifier.phase(forToolName: call.name)
    }

    private func state(for result: ToolResult?) -> AgentActivityState {
        guard let result else { return .running }
        return result.isError ? .failed : .completed
    }

    private func localized(_ zh: String, _ en: String) -> String {
        isChinese ? zh : en
    }

    private func target(for call: ToolCall) -> String? {
        ToolInvocationPresentation.target(toolName: call.name, inputJSON: call.inputJSON, limit: 72)
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

private struct ParsedToolImage {
    var image: NSImage
    var caption: String?

    static func parse(_ output: String) -> ParsedToolImage? {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let type = (object["type"] as? String)?.lowercased()
        guard type == nil || type == "image" || type == "tool_image" else { return nil }
        let file = object["file"] as? [String: Any]
        let path = (file?["filePath"] as? String)
            ?? (file?["path"] as? String)
            ?? (object["filePath"] as? String)
            ?? (object["path"] as? String)
        if let path,
           let image = NSImage(contentsOfFile: NSString(string: path).expandingTildeInPath) {
            return ParsedToolImage(image: image, caption: URL(fileURLWithPath: path).lastPathComponent)
        }
        let base64 = (file?["base64"] as? String)
            ?? (file?["data"] as? String)
            ?? (object["base64"] as? String)
            ?? (object["data"] as? String)
        guard let base64,
              let decoded = Data(base64Encoded: base64),
              let image = NSImage(data: decoded) else {
            return nil
        }
        return ParsedToolImage(image: image, caption: object["name"] as? String)
    }
}

private struct ToolImagePreview: View {
    var parsed: ParsedToolImage

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(nsImage: parsed.image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 360, maxHeight: 220, alignment: .leading)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous)
                        .stroke(DesignTokens.separator, lineWidth: 1)
                )
            if let caption = parsed.caption, !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(CodexProcessStyle.detail)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(DesignTokens.neutral50.opacity(0.62), in: RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous))
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
                    .font(CodexProcessStyle.rowFont)
                    .foregroundStyle(result.isError ? DesignTokens.danger.opacity(0.78) : CodexProcessStyle.title)
                Text(result.output)
                    .font(CodexProcessStyle.detailMonoFont)
                    .foregroundStyle(CodexProcessStyle.detailStrong)
                    .lineLimit(5)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct CodexInlineToolIcon: View {
    var phase: AgentActivityPhase
    var state: AgentActivityState

    var body: some View {
        Image(systemName: iconName)
            .font(.system(size: 15, weight: .regular))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(iconColor)
            .frame(width: 18, height: 18)
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
            return DesignTokens.danger.opacity(0.76)
        case .cancelled:
            return CodexProcessStyle.iconMuted
        case .running:
            return CodexProcessStyle.iconMuted
        case .completed:
            return CodexProcessStyle.icon
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
                } else if request.kind == .exitPlanMode {
                    ExitPlanModePermissionCard(request: request)
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
    @State private var showingInput = false

    private var isChinese: Bool {
        state.settings.language.resolved() == .chineseSimplified
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignTokens.warning)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 4) {
                    Text(isChinese ? "需要权限确认" : "Permission required")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DesignTokens.text)
                    Text(request.reason)
                        .font(.system(size: 12))
                        .foregroundStyle(DesignTokens.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 4) {
                        Text(isChinese ? "工具：" : "Tool:")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(DesignTokens.tertiaryText)
                        Text(request.toolName)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(DesignTokens.secondaryText)
                    }
                }

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    Button(isChinese ? "拒绝" : "Deny") {
                        state.denyPermission(request.id)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignTokens.danger)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                            .fill(DesignTokens.background)
                            .overlay(
                                RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                                    .stroke(DesignTokens.danger.opacity(0.24), lineWidth: 1)
                            )
                    )

                    Button(isChinese ? "允许一次" : "Allow once") {
                        state.approvePermission(request.id)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                            .fill(DesignTokens.warning)
                    )

                    Button(isChinese ? "始终允许" : "Always allow") {
                        state.approvePermission(request.id, remember: true)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                            .fill(DesignTokens.neutral900)
                    )
                }
            }

            if !request.inputJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    withAnimation(.easeOut(duration: 0.14)) {
                        showingInput.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showingInput ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                        Text(isChinese ? "查看工具输入" : "View tool input")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(DesignTokens.warning)
                }
                .buttonStyle(.plain)

                if showingInput {
                    Text(request.inputJSON)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(DesignTokens.secondaryText)
                        .textSelection(.enabled)
                        .lineLimit(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                                .fill(DesignTokens.warning.opacity(0.075))
                                .overlay(
                                    RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                                        .stroke(DesignTokens.warning.opacity(0.16), lineWidth: 1)
                                )
                        )
                        .transition(.opacity)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: DesignTokens.composerMaxWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous)
                .fill(DesignTokens.warning.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.radius, style: .continuous)
                        .stroke(DesignTokens.warning.opacity(0.26), lineWidth: 1)
                )
        )
    }
}

private enum PlanConfirmationChoice: String, CaseIterable, Identifiable {
    case refine
    case execute
    case cancel

    var id: String { rawValue }

    func title(isChinese: Bool) -> String {
        switch self {
        case .refine:
            return isChinese ? "继续完善" : "Keep planning"
        case .execute:
            return isChinese ? "执行计划" : "Execute plan"
        case .cancel:
            return isChinese ? "取消/返回" : "Cancel"
        }
    }

    func subtitle(isChinese: Bool) -> String {
        switch self {
        case .refine:
            return isChinese ? "让模型根据反馈继续修改计划" : "Ask the model to revise the plan"
        case .execute:
            return isChinese ? "退出 Plan 模式并开始执行" : "Leave Plan mode and start executing"
        case .cancel:
            return isChinese ? "停止本次计划确认" : "Stop this plan confirmation"
        }
    }

    var systemImage: String {
        switch self {
        case .refine:
            return "message"
        case .execute:
            return "checkmark.circle.fill"
        case .cancel:
            return "xmark.circle"
        }
    }
}

private struct ExitPlanModePermissionCard: View {
    @EnvironmentObject private var state: AppState
    var request: PermissionRequest
    @State private var feedback = ""
    @State private var selectedChoice: PlanConfirmationChoice = .execute

    private var isChinese: Bool {
        state.settings.language.resolved() == .chineseSimplified
    }

    private var planMarkdown: String {
        ExitPlanModePlanExtractor.extract(from: request.inputJSON, isChinese: isChinese)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(DesignTokens.accent.opacity(0.12))
                        .frame(width: 34, height: 34)
                    Image(systemName: "checklist")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(DesignTokens.accent)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(isChinese ? "计划已准备好" : "Plan is ready")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DesignTokens.text)
                    Text(isChinese ? "确认后会退出 Plan 模式，并让模型开始按计划执行。" : "Confirm to leave Plan mode and let the agent execute this plan.")
                        .font(.system(size: 12))
                        .foregroundStyle(DesignTokens.secondaryText)
                }

                Spacer()
            }
            .padding(12)
            .background(DesignTokens.accent.opacity(0.055))

            ScrollView {
                NativeMarkdownView(text: planMarkdown, fontSize: 13, lineSpacing: 5)
                    .padding(12)
            }
            .frame(maxHeight: 180)

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(isChinese ? "选择下一步" : "Choose next step")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DesignTokens.tertiaryText)

                    HStack(spacing: 8) {
                        ForEach(PlanConfirmationChoice.allCases) { choice in
                            planChoiceButton(choice)
                        }
                    }
                }

                TextEditor(text: $feedback)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 44, maxHeight: 64)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                            .fill(DesignTokens.background)
                            .overlay(
                                RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                                    .stroke(DesignTokens.separator, lineWidth: 1)
                            )
                    )
                    .overlay(alignment: .topLeading) {
                        if feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(isChinese ? "补充要求或修改点（可选）" : "Optional feedback or changes")
                                .font(.system(size: 12))
                                .foregroundStyle(DesignTokens.tertiaryText.opacity(0.72))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 14)
                        }
                    }

                HStack(spacing: 8) {
                    Spacer()

                    Button {
                        performSelectedChoice()
                    } label: {
                        Label(selectedChoice.title(isChinese: isChinese), systemImage: selectedChoice.systemImage)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                            .fill(DesignTokens.accent)
                    )
                }
            }
            .padding(12)
            .background(DesignTokens.background.opacity(0.74))
        }
        .frame(maxWidth: DesignTokens.composerMaxWidth, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(DesignTokens.accent.opacity(0.26), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
    }

    private func planChoiceButton(_ choice: PlanConfirmationChoice) -> some View {
        let isSelected = selectedChoice == choice
        return Button {
            withAnimation(.snappy(duration: 0.18)) {
                selectedChoice = choice
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: choice.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.title(isChinese: isChinese))
                        .font(.system(size: 12, weight: .semibold))
                    Text(choice.subtitle(isChinese: isChinese))
                        .font(.system(size: 10.5))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(isSelected ? DesignTokens.accent : DesignTokens.secondaryText)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                    .fill(isSelected ? DesignTokens.accent.opacity(0.10) : DesignTokens.background)
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                            .stroke(isSelected ? DesignTokens.accent.opacity(0.38) : DesignTokens.separator, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func performSelectedChoice() {
        switch selectedChoice {
        case .execute:
            state.approvePermission(request.id, updatedInputJSON: updatedPlanInputJSON(mode: "agent"))
        case .refine:
            let fallback = isChinese ? "请继续完善计划，暂时不要退出 Plan 模式。" : "Please keep refining the plan and do not leave Plan mode yet."
            state.approvePermission(request.id, updatedInputJSON: updatedPlanInputJSON(mode: "plan", fallbackFeedback: fallback))
        case .cancel:
            state.denyPermission(request.id)
        }
    }

    private func updatedPlanInputJSON(mode: String, fallbackFeedback: String? = nil) -> String {
        let trimmedFeedback = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        let feedbackValue = trimmedFeedback.isEmpty ? fallbackFeedback : trimmedFeedback
        var object: [String: Any]
        if let data = request.inputJSON.data(using: .utf8),
           let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            object = parsed
        } else {
            object = [:]
        }
        object["mode"] = mode
        if let feedbackValue, !feedbackValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            object["userFeedback"] = feedbackValue
        }
        guard JSONSerialization.isValidJSONObject(object),
              let updated = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: updated, encoding: .utf8) else {
            return request.inputJSON
        }
        return string
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
                            Text(question.header?.isEmpty == false ? question.header! : "AskQuestion")
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

private enum ExitPlanModePlanExtractor {
    static func extract(from inputJSON: String, isChinese: Bool) -> String {
        extractOptional(from: inputJSON)
            ?? (isChinese ? "模型准备退出 Plan 模式并开始执行。" : "The agent is ready to leave Plan mode and start implementation.")
    }

    static func extractOptional(from inputJSON: String) -> String? {
        guard let object = JSONPayloadExtractor.object(from: inputJSON) else {
            let trimmed = inputJSON.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        for key in ["plan", "planContent", "content", "markdown", "text", "body"] {
            if let value = object[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        if let steps = object["steps"] as? [String], !steps.isEmpty {
            return steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        }
        if let plan = object["plan"] as? [String: Any] {
            return plan
                .compactMap { key, value -> String? in
                    if let string = value as? String, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return "### \(key)\n\(string)"
                    }
                    if let array = value as? [String], !array.isEmpty {
                        return "### \(key)\n" + array.map { "- \($0)" }.joined(separator: "\n")
                    }
                    return nil
                }
                .sorted()
                .joined(separator: "\n\n")
                .blankToNil
        }
        return nil
    }
}

private enum JSONPayloadExtractor {
    static func object(from value: String) -> [String: Any]? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = decodeObject(trimmed) {
            return direct
        }
        guard let json = firstJSONObjectString(in: value) else {
            return nil
        }
        return decodeObject(json)
    }

    static func firstJSONObjectString(in value: String) -> String? {
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaping = false

        for index in value.indices {
            let char = value[index]
            if inString {
                if escaping {
                    escaping = false
                } else if char == "\\" {
                    escaping = true
                } else if char == "\"" {
                    inString = false
                }
                continue
            }

            if char == "\"" {
                inString = true
                continue
            }
            if char == "{" {
                if depth == 0 {
                    start = index
                }
                depth += 1
            } else if char == "}", depth > 0 {
                depth -= 1
                if depth == 0, let start {
                    return String(value[start...index])
                }
            }
        }
        return nil
    }

    private static func decodeObject(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }
}

private struct ParsedRAGToolResult {
    enum SourceKind {
        case web
        case local
        case unknown
    }

    struct Item: Identifiable {
        var id: Int
        var title: String
        var url: String?
        var snippet: String
        var source: String
        var score: String?
    }

    var sourceKind: SourceKind
    var sourceLabel: String
    var query: String
    var status: String
    var ok: Bool
    var endpoint: String?
    var topK: Int?
    var elapsedMs: Int?
    var error: String?
    var items: [Item]
    var rawJSON: String

    static func parse(from values: [String]) -> ParsedRAGToolResult? {
        for value in values.reversed() {
            guard let object = JSONPayloadExtractor.object(from: value) else { continue }
            guard isRAGLike(object) else { continue }
            return parse(object: object, raw: JSONPayloadExtractor.firstJSONObjectString(in: value) ?? value)
        }
        return nil
    }

    private static func parse(object: [String: Any], raw: String) -> ParsedRAGToolResult {
        let debug = object["debug"] as? [String: Any] ?? [:]
        let query = stringValue(object["query"])
            ?? stringValue(object["q"])
            ?? stringValue(debug["query"])
            ?? ""
        let ok = (object["ok"] as? Bool) ?? ((object["error"] as? String) == nil)
        let status = stringValue(object["status"])
            ?? (ok ? "ok" : "error")
        let arrays = firstArray(object, keys: ["results", "citations", "items", "documents", "matches"])
        let sourceKind = inferSourceKind(object: object, debug: debug, items: arrays)
        let sourceLabel: String
        switch sourceKind {
        case .web:
            sourceLabel = "Z.AI / GLM Web Search"
        case .local:
            sourceLabel = "Local Knowledge"
        case .unknown:
            sourceLabel = "RAG Search"
        }

        return ParsedRAGToolResult(
            sourceKind: sourceKind,
            sourceLabel: sourceLabel,
            query: query,
            status: status,
            ok: ok,
            endpoint: endpointHost(from: object, debug: debug),
            topK: intValue(object["topK"]) ?? intValue(object["top_k"]) ?? intValue(debug["topK"]),
            elapsedMs: intValue(object["elapsedMs"]) ?? intValue(object["elapsed_ms"]) ?? intValue(debug["elapsedMs"]),
            error: stringValue(object["error"]) ?? stringValue(debug["error"]),
            items: arrays.enumerated().map { index, item in
                ParsedRAGToolResult.Item(
                    id: index,
                    title: stringValue(item["title"]) ?? stringValue(item["name"]) ?? stringValue(item["url"]) ?? stringValue(item["id"]) ?? "Result \(index + 1)",
                    url: stringValue(item["url"]) ?? stringValue(item["link"]),
                    snippet: stringValue(item["snippet"]) ?? stringValue(item["content"]) ?? stringValue(item["text"]) ?? stringValue(item["summary"]) ?? "",
                    source: stringValue(item["source"]) ?? stringValue(item["url"]) ?? stringValue(item["id"]) ?? stringValue(item["path"]) ?? "",
                    score: stringValue(item["score"]) ?? stringValue(item["distance"])
                )
            },
            rawJSON: prettyJSON(object) ?? raw
        )
    }

    private static func isRAGLike(_ object: [String: Any]) -> Bool {
        if object["results"] != nil || object["citations"] != nil || object["items"] != nil {
            return object["query"] != nil || object["debug"] != nil || object["context"] != nil || object["source"] != nil
        }
        let raw = (prettyJSON(object) ?? "").lowercased()
        return raw.contains("glm web search") ||
            raw.contains("local knowledge") ||
            raw.contains("rag") ||
            raw.contains("milvus") ||
            raw.contains("databaseurl")
    }

    private static func inferSourceKind(object: [String: Any], debug: [String: Any], items: [[String: Any]]) -> SourceKind {
        let raw = (prettyJSON(object) ?? "").lowercased()
        if raw.contains("glm web search") || raw.contains("z.ai") || raw.contains("web_search") || items.contains(where: { stringValue($0["url"]) != nil }) {
            return .web
        }
        if raw.contains("local knowledge") || raw.contains("milvus") || raw.contains("databaseurl") || items.contains(where: { stringValue($0["path"]) != nil || stringValue($0["id"]) != nil }) {
            return .local
        }
        if stringValue(debug["provider"])?.lowercased().contains("zai") == true {
            return .web
        }
        return .unknown
    }

    private static func endpointHost(from object: [String: Any], debug: [String: Any]) -> String? {
        for raw in [
            stringValue(object["endpoint"]),
            stringValue(object["baseUrl"]),
            stringValue(object["databaseUrl"]),
            stringValue(debug["endpoint"]),
            stringValue(debug["baseUrl"]),
            stringValue(debug["databaseUrl"])
        ] {
            guard let raw, !raw.isEmpty else { continue }
            if let host = URL(string: raw)?.host {
                return host
            }
            return raw
        }
        return nil
    }

    private static func firstArray(_ object: [String: Any], keys: [String]) -> [[String: Any]] {
        for key in keys {
            if let array = object[key] as? [[String: Any]] {
                return array
            }
        }
        return []
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            return string.trimmingCharacters(in: .whitespacesAndNewlines).blankToNil
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func prettyJSON(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

private struct RAGResultContentView: View {
    var result: ParsedRAGToolResult
    var isChinese: Bool
    @State private var showingRaw = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(result.ok ? "OK" : "ERROR")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(result.ok ? DesignTokens.success : DesignTokens.danger)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule(style: .continuous)
                                .fill((result.ok ? DesignTokens.success : DesignTokens.danger).opacity(0.11))
                        )
                    Text(result.sourceLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DesignTokens.secondaryText)
                    if let endpoint = result.endpoint {
                        Text("via \(endpoint)")
                            .font(.system(size: 10))
                            .foregroundStyle(DesignTokens.tertiaryText)
                    }
                    Spacer()
                }

                if !result.query.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(isChinese ? "查询" : "Query")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(DesignTokens.tertiaryText)
                        Text(result.query)
                            .font(.system(size: 11))
                            .foregroundStyle(DesignTokens.secondaryText)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }

                HStack(spacing: 10) {
                    metricText(label: isChinese ? "结果" : "results", value: "\(result.items.count)")
                    if let topK = result.topK {
                        metricText(label: "topK", value: "\(topK)")
                    }
                    metricText(label: isChinese ? "状态" : "status", value: result.status)
                    if let elapsedMs = result.elapsedMs {
                        metricText(label: isChinese ? "耗时" : "elapsed", value: "\(elapsedMs)ms")
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                    .fill(DesignTokens.neutral50.opacity(0.78))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                            .stroke(DesignTokens.separator.opacity(0.75), lineWidth: 1)
                    )
            )

            if let error = result.error, !error.isEmpty {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(DesignTokens.danger)
                    .textSelection(.enabled)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                            .fill(DesignTokens.danger.opacity(0.07))
                    )
            }

            if !result.items.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(result.items) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(item.id + 1)")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(DesignTokens.tertiaryText)
                                .frame(width: 18, alignment: .trailing)

                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 5) {
                                    if let url = item.url, let link = URL(string: url) {
                                        Button {
                                            NSWorkspace.shared.open(link)
                                        } label: {
                                            Text(item.title)
                                                .font(.system(size: 11, weight: .semibold))
                                                .foregroundStyle(DesignTokens.accent)
                                                .lineLimit(1)
                                        }
                                        .buttonStyle(.plain)
                                    } else {
                                        Text(item.title)
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(DesignTokens.text)
                                            .lineLimit(1)
                                    }
                                    if let score = item.score, !score.isEmpty {
                                        Text(score)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(DesignTokens.tertiaryText)
                                    }
                                }
                                if !item.source.isEmpty {
                                    Text(item.source)
                                        .font(.system(size: 10))
                                        .foregroundStyle(DesignTokens.tertiaryText)
                                        .lineLimit(1)
                                }
                                if !item.snippet.isEmpty {
                                    Text(item.snippet)
                                        .font(.system(size: 11))
                                        .foregroundStyle(DesignTokens.secondaryText)
                                        .lineLimit(3)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .padding(.vertical, 8)
                        .overlay(alignment: .bottom) {
                            if item.id != result.items.count - 1 {
                                Rectangle().fill(DesignTokens.separator.opacity(0.72)).frame(height: 1)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                        .fill(DesignTokens.background)
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                                .stroke(DesignTokens.separator.opacity(0.75), lineWidth: 1)
                        )
                )
            }

            Button {
                withAnimation(.easeOut(duration: 0.14)) {
                    showingRaw.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: showingRaw ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                    Text("raw retrieval JSON")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                }
                .foregroundStyle(DesignTokens.tertiaryText)
            }
            .buttonStyle(.plain)

            if showingRaw {
                Text(result.rawJSON)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(DesignTokens.secondaryText)
                    .textSelection(.enabled)
                    .lineLimit(18)
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                            .fill(DesignTokens.neutral50)
                    )
                    .transition(.opacity)
            }
        }
    }

    private func metricText(label: String, value: String) -> some View {
        Text("\(label)=\(value)")
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(DesignTokens.tertiaryText)
    }
}

private struct PlanTraceContentView: View {
    var markdown: String

    var body: some View {
        NativeMarkdownView(text: markdown, fontSize: 12, lineSpacing: 5)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                    .fill(DesignTokens.accent.opacity(0.055))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                            .stroke(DesignTokens.accent.opacity(0.14), lineWidth: 1)
                    )
            )
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
        VStack(alignment: .leading, spacing: 7) {
            Text(headerText)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(CodexProcessStyle.title)
                .monospacedDigit()
            Rectangle()
                .fill(DesignTokens.separator.opacity(0.74))
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

    private var traceSummary: ProcessTraceSummary {
        ProcessTraceSummary.make(activities: visibleActivities, isChinese: isChinese)
    }

    private var summaryText: String {
        let reads = uniqueTargets { activity in
            activity.toolName.map(AgentToolPresentationClassifier.isReadTool) == true
        }.count
        let edits = uniqueTargets { presentationPhase(for: $0) == .edit }.count
        let searches = visibleActivities.filter { presentationPhase(for: $0) == .search }.count
        let commands = visibleActivities.filter { presentationPhase(for: $0) == .command }.count
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

    private var shouldRender: Bool {
        guard !visibleActivities.isEmpty else { return false }
        if hasRunningActivity { return true }
        let reads = uniqueTargets { activity in
            activity.toolName.map(AgentToolPresentationClassifier.isReadTool) == true
        }.count
        let edits = uniqueTargets { presentationPhase(for: $0) == .edit }.count
        let commands = visibleActivities.filter { presentationPhase(for: $0) == .command }.count
        let meaningfulTools = visibleActivities.filter { activity in
            guard activity.toolName != nil else { return false }
            return presentationPhase(for: activity) != .search
        }.count
        return reads > 0 || edits > 0 || commands > 0 || meaningfulTools > 0 || compacting
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

    private var isThinkingOnly: Bool {
        hasRunningActivity &&
            visibleActivities.allSatisfy { activity in
                activity.phase == .status || activity.phase == .thinking
            }
    }

    var body: some View {
        if shouldRender {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: traceIcon)
                        .font(.system(size: 15, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                    if traceSummary.shouldShimmer {
                        ShimmeringProcessText(text: traceSummary.text, font: CodexProcessStyle.rowFont)
                    } else {
                        Text(traceSummary.text)
                            .font(CodexProcessStyle.rowFont)
                    }
                    if hasRunningActivity {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.48)
                            .tint(CodexProcessStyle.iconMuted)
                    }
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(CodexProcessStyle.title)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(detailRows.isEmpty)

            if expanded {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(detailRows) { row in
                        VStack(alignment: .leading, spacing: 3) {
                            if row.isRunning {
                                ShimmeringProcessText(text: row.title, font: CodexProcessStyle.detailFont)
                                    .lineLimit(2)
                            } else {
                                Text(row.title)
                                    .font(CodexProcessStyle.detailFont)
                                    .foregroundStyle(CodexProcessStyle.detail)
                                    .lineLimit(2)
                            }
                            if !row.detail.isEmpty {
                                Text(row.detail)
                                    .font(CodexProcessStyle.detailMonoFont)
                                    .foregroundStyle(CodexProcessStyle.detail.opacity(0.92))
                                    .lineLimit(3)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.leading, 24)
                .transition(.opacity.combined(with: .scale(scale: 0.985, anchor: .topLeading)))
            }

            if compacting {
                HStack(spacing: 16) {
                    Rectangle().fill(DesignTokens.separator).frame(height: 1)
                    Text(isChinese ? "正在自动压缩上下文" : "Automatically compacting context")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(CodexProcessStyle.detail)
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
    }

    private var traceIcon: String {
        if visibleActivities.contains(where: { $0.state == .failed }) { return "exclamationmark.triangle" }
        if visibleActivities.contains(where: { presentationPhase(for: $0) == .command }) { return "terminal" }
        if visibleActivities.contains(where: { presentationPhase(for: $0) == .search }) { return "magnifyingglass" }
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
        let canonical = AgentToolNameCanonicalizer.canonical(toolName).lowercased()
        let phase = presentationPhase(for: activity)
        if phase == .search {
            return target.map { "Searched for \($0)" } ?? (isChinese ? "已搜索" : "Searched")
        }
        if AgentToolPresentationClassifier.isReadTool(toolName) {
            return target.map { "Read \($0)" } ?? (isChinese ? "已读取文件" : "Read file")
        }
        if phase == .edit {
            return target.map { (activity.state == .running ? (isChinese ? "正在编辑 \($0)" : "Editing \($0)") : (isChinese ? "已编辑 \($0)" : "Edited \($0)")) } ?? (isChinese ? "已编辑文件" : "Edited file")
        }
        if phase == .command {
            return target.map { (activity.state == .running ? (isChinese ? "正在执行命令 \($0)" : "Running \($0)") : (isChinese ? "已运行命令 \($0)" : "Ran \($0)")) } ?? (isChinese ? "已运行命令" : "Ran command")
        }
        if phase == .subagent {
            return target.map { (activity.state == .running ? (isChinese ? "正在运行任务 \($0)" : "Running task \($0)") : (isChinese ? "已运行任务 \($0)" : "Ran task \($0)")) } ?? (isChinese ? "已运行任务" : "Ran task")
        }
        if canonical == "skill" {
            return target.map { (activity.state == .running ? (isChinese ? "正在加载技能 \($0)" : "Loading skill \($0)") : (isChinese ? "已加载技能 \($0)" : "Loaded skill \($0)")) } ?? (isChinese ? "已加载技能" : "Loaded skill")
        }
        if canonical == "askquestion" {
            return activity.state == .completed ? (isChinese ? "已回答问题" : "Answered question") : (isChinese ? "等待你的回答" : "Waiting for your answer")
        }
        if canonical == "switchmode" {
            return activity.state == .completed ? (isChinese ? "已切换模式" : "Switched mode") : (isChinese ? "正在切换模式" : "Switching mode")
        }
        return activity.title.isEmpty ? (isChinese ? "正在处理" : "Processing") : activity.title
    }

    private func compactDetail(for activity: AgentActivity) -> String {
        if let parsed = parsedRAGSummary(from: [activity.detail] + activity.detailMessages) {
            return parsed
        }
        let detail = compactPreview(activity.detail)
        if detail.hasPrefix("{"), detail.hasSuffix("}") {
            return target(for: activity) ?? ""
        }
        return detail
    }

    private func uniqueTargets(where predicate: (AgentActivity) -> Bool) -> Set<String> {
        Set(visibleActivities.compactMap { activity in
            guard predicate(activity) else { return nil }
            return target(for: activity) ?? activity.id
        })
    }

    private func presentationPhase(for activity: AgentActivity) -> AgentActivityPhase {
        guard let toolName = activity.toolName, !toolName.isEmpty else {
            return activity.phase
        }
        return AgentToolPresentationClassifier.phase(forToolName: toolName)
    }

    private func target(for activity: AgentActivity) -> String? {
        let sources = [activity.detail] + activity.detailMessages
        for source in sources {
            if let object = jsonObject(source) {
                for key in ["skill", "args", "file_path", "notebook_path", "path", "pattern", "query", "url", "command", "task_id", "description"] {
                    if let value = object[key] as? String {
                        if let display = displayTarget(value, key: key) {
                            return display
                        }
                    }
                }
            }
            let compact = compactPreview(source)
            if !compact.isEmpty, !compact.hasPrefix("{") {
                if let display = displayTarget(compact, key: "") {
                    return display
                }
            }
        }
        return nil
    }

    private func parsedRAGSummary(from values: [String]) -> String? {
        if let result = ParsedRAGToolResult.parse(from: values) {
            let query = result.query.isEmpty ? result.sourceLabel : result.query
            if result.items.isEmpty {
                return result.ok
                    ? "\(result.sourceLabel) · \(query)"
                    : (isChinese ? "\(result.sourceLabel) 错误：\(result.error ?? result.status)" : "\(result.sourceLabel) error: \(result.error ?? result.status)")
            }
            return isChinese
                ? "\(result.sourceLabel) · \(query) · \(result.items.count) 条证据"
                : "\(result.sourceLabel) · \(query) · \(result.items.count) citations"
        }
        for value in values {
            guard let object = jsonObject(value) else { continue }
            if let skill = object["skill"] as? String {
                let allowed = (object["allowedTools"] as? [String])?.count ?? 0
                return allowed > 0
                    ? (isChinese ? "\(skill) · \(allowed) 个允许工具" : "\(skill) · \(allowed) allowed tools")
                    : skill
            }
        }
        return nil
    }

    private func jsonObject(_ value: String) -> [String: Any]? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}"), let data = trimmed.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func displayTarget(_ value: String, key: String) -> String? {
        let compact = compactPreview(value)
        if compact.isEmpty || compact == "/" || compact == "." {
            return nil
        }
        if key == "file_path" || key == "path" {
            let display = URL(fileURLWithPath: compact).lastPathComponent.isEmpty ? compact : URL(fileURLWithPath: compact).lastPathComponent
            return (display == "/" || display == ".") ? nil : display
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
        ragResult != nil || planMarkdown != nil || commandTrace != nil || !detailLines.isEmpty
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
        if let ragResult {
            let query = ragResult.query.isEmpty ? ragResult.sourceLabel : ragResult.query
            return isChinese
                ? "\(ragResult.sourceLabel) · \(query) · \(ragResult.items.count) 条结果"
                : "\(ragResult.sourceLabel) · \(query) · \(ragResult.items.count) results"
        }
        if let commandTrace {
            return commandTrace.preview(isChinese: isChinese)
        }
        let raw = detailLines.last ?? activity.detail
        let cleaned = compactPreview(raw)
        if cleaned.isEmpty || looksLikeToolInput(raw) {
            return compactTarget()
        }
        return cleaned
    }

    private var ragResult: ParsedRAGToolResult? {
        ParsedRAGToolResult.parse(from: detailLines + [activity.detail])
    }

    private var commandTrace: ParsedCommandTrace? {
        guard let toolName = activity.toolName?.lowercased(),
              toolName.contains("bash") || toolName.contains("shell") || toolName.contains("command") else {
            return nil
        }
        return ParsedCommandTrace.parse(from: detailLines + [activity.detail])
    }

    private var planMarkdown: String? {
        let lowerToolName = (activity.toolName ?? "").lowercased()
        guard lowerToolName.contains("switchmode") || lowerToolName.contains("exitplanmode") else { return nil }
        for line in detailLines {
            if let plan = ExitPlanModePlanExtractor.extractOptional(from: line) {
                return plan
            }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                if canExpand {
                    onToggle()
                }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    ProcessStepIcon(phase: activity.phase, state: activity.state)
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            if shouldShimmerTitle {
                                ShimmeringProcessText(text: titleText, font: CodexProcessStyle.rowFont)
                                    .lineLimit(1)
                            } else {
                                Text(titleText)
                                    .font(CodexProcessStyle.rowFont)
                                    .foregroundStyle(activity.state == .failed ? DesignTokens.danger.opacity(0.78) : CodexProcessStyle.title)
                                    .lineLimit(1)
                            }

                            if let toolName = activity.toolName {
                                Text(toolName)
                                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(CodexProcessStyle.detail)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(DesignTokens.neutral100.opacity(0.56))
                                    )
                            }

                            if canExpand {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(CodexProcessStyle.detail)
                                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                            }
                        }

                        if let previewText, !previewText.isEmpty {
                            Text(previewText)
                                .font(CodexProcessStyle.detailFont)
                                .foregroundStyle(CodexProcessStyle.detail)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 0)
                .padding(.vertical, 6)
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
                VStack(alignment: .leading, spacing: 5) {
                    if let ragResult {
                        RAGResultContentView(result: ragResult, isChinese: isChinese)
                    } else if let planMarkdown {
                        PlanTraceContentView(markdown: planMarkdown)
                    } else if let commandTrace {
                        CommandTraceContentView(trace: commandTrace, isChinese: isChinese)
                    } else {
                        ForEach(Array(detailLines.enumerated()), id: \.offset) { index, line in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(detailLabel(index: index, count: detailLines.count))
                                    .font(.system(size: 9.5, weight: .semibold))
                                    .foregroundStyle(CodexProcessStyle.detail)
                                Text(line)
                                    .font(CodexProcessStyle.detailMonoFont)
                                    .foregroundStyle(CodexProcessStyle.detailStrong)
                                    .lineLimit(12)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                                    .fill(DesignTokens.neutral50.opacity(0.62))
                            )
                        }
                    }
                }
                .padding(.leading, 28)
                .transition(.opacity.combined(with: .scale(scale: 0.99, anchor: .topLeading)))
            }
        }
    }

    private var shouldShimmerTitle: Bool {
        activity.state == .running && (activity.phase == .thinking || activity.phase == .status)
    }

    private var rowBackground: Color {
        switch activity.state {
        case .running:
            return .clear
        case .failed:
            return .clear
        case .cancelled:
            return .clear
        case .completed:
            return .clear
        }
    }

    private var rowBorder: Color {
        switch activity.state {
        case .running:
            return .clear
        case .failed:
            return .clear
        default:
            return .clear
        }
    }

    private var titleText: String {
        if let toolName = activity.toolName, !toolName.isEmpty {
            return toolTitle(toolName)
        }
        return statusTitle()
    }

    private func toolTitle(_ toolName: String) -> String {
        let lower = AgentToolNameCanonicalizer.canonical(toolName).lowercased()
        let phase = AgentToolPresentationClassifier.phase(forToolName: toolName)
        let target = compactTarget()
        let suffix = target.map { " \($0)" } ?? ""

        if AgentToolPresentationClassifier.isReadTool(toolName) {
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
        if lower == "write" {
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
        if phase == .edit {
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
        if lower == "delete" {
            return localized(
                running: "Deleting\(suffix)",
                completed: "Deleted\(suffix)",
                failed: "Delete failed\(suffix)",
                cancelled: "Stopped deleting\(suffix)",
                zhRunning: "正在删除\(suffix)",
                zhCompleted: "已删除\(suffix)",
                zhFailed: "删除失败\(suffix)",
                zhCancelled: "已停止删除\(suffix)"
            )
        }
        if phase == .search {
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
        if phase == .command {
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
        if phase == .subagent {
            return localized(
                running: "Running task\(suffix)",
                completed: "Ran task\(suffix)",
                failed: "Task failed\(suffix)",
                cancelled: "Stopped task\(suffix)",
                zhRunning: "正在运行任务\(suffix)",
                zhCompleted: "已运行任务\(suffix)",
                zhFailed: "任务失败\(suffix)",
                zhCancelled: "已停止任务\(suffix)"
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
        if lower == "askquestion" {
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
        if lower == "switchmode" {
            return localized(
                running: "Switching mode",
                completed: "Switched mode",
                failed: "Mode switch failed",
                cancelled: "Mode switch stopped",
                zhRunning: "正在切换模式",
                zhCompleted: "已切换模式",
                zhFailed: "切换模式失败",
                zhCancelled: "已停止切换模式"
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
                if !compact.isEmpty, compact != "/", compact != "." {
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

private struct ParsedCommandTrace {
    var command: String?
    var cwd: String?
    var exitCode: Int?
    var stdout: String?
    var stderr: String?
    var description: String?

    static func parse(from candidates: [String]) -> ParsedCommandTrace? {
        var trace = ParsedCommandTrace()
        var sawCommand = false
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let object = jsonObject(trimmed) {
                if let command = stringValue(object, keys: ["command", "cmd", "input"]) {
                    trace.command = command
                    sawCommand = true
                }
                if let cwd = stringValue(object, keys: ["cwd", "workdir", "workingDirectory"]) {
                    trace.cwd = cwd
                }
                if let description = stringValue(object, keys: ["description", "summary"]) {
                    trace.description = description
                }
                if let stdout = stringValue(object, keys: ["stdout", "output", "result"]) {
                    trace.stdout = stdout
                }
                if let stderr = stringValue(object, keys: ["stderr", "error"]) {
                    trace.stderr = stderr
                }
                if let exitCode = intValue(object, keys: ["exitCode", "exit_code", "code", "status"]) {
                    trace.exitCode = exitCode
                }
                continue
            }
            if trimmed.lowercased().hasPrefix("exit code:") {
                let parts = trimmed.components(separatedBy: .newlines)
                if let first = parts.first {
                    trace.exitCode = Int(first.replacingOccurrences(of: "exit code:", with: "", options: .caseInsensitive).trimmingCharacters(in: .whitespacesAndNewlines))
                }
                let rest = parts.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !rest.isEmpty {
                    trace.stdout = rest
                }
                continue
            }
            if sawCommand {
                trace.stdout = [trace.stdout, trimmed].compactMap { value in
                    let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return normalized?.isEmpty == false ? normalized : nil
                }.joined(separator: "\n")
            }
        }
        guard sawCommand || trace.stdout != nil || trace.stderr != nil else { return nil }
        return trace
    }

    func preview(isChinese: Bool) -> String? {
        if let command, !command.isEmpty {
            return command.replacingOccurrences(of: "\n", with: " ")
        }
        if let description, !description.isEmpty {
            return description
        }
        if let stdout, !stdout.isEmpty {
            return stdout.replacingOccurrences(of: "\n", with: " ")
        }
        return isChinese ? "命令输出" : "Command output"
    }

    private static func jsonObject(_ value: String) -> [String: Any]? {
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func stringValue(_ object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    private static func intValue(_ object: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = object[key] as? Int { return value }
            if let value = object[key] as? String, let int = Int(value) { return int }
        }
        return nil
    }
}

private struct CommandTraceContentView: View {
    var trace: ParsedCommandTrace
    var isChinese: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let command = trace.command {
                block(title: isChinese ? "命令" : "Command", value: command, mono: true)
            }
            if let cwd = trace.cwd {
                block(title: "CWD", value: cwd, mono: true)
            }
            if let exitCode = trace.exitCode {
                HStack(spacing: 8) {
                    Text(isChinese ? "退出码" : "Exit code")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(CodexProcessStyle.detail)
                    Text("\(exitCode)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(exitCode == 0 ? DesignTokens.success : DesignTokens.danger)
                }
            }
            if let stdout = trace.stdout, !stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                block(title: "stdout", value: stdout, mono: true)
            }
            if let stderr = trace.stderr, !stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                block(title: "stderr", value: stderr, mono: true, isError: true)
            }
        }
    }

    private func block(title: String, value: String, mono: Bool, isError: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(isError ? DesignTokens.danger.opacity(0.78) : CodexProcessStyle.detail)
            Text(value)
                .font(mono ? CodexProcessStyle.detailMonoFont : CodexProcessStyle.detailFont)
                .foregroundStyle(isError ? DesignTokens.danger.opacity(0.86) : CodexProcessStyle.detailStrong)
                .lineLimit(14)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.smallRadius, style: .continuous)
                .fill(DesignTokens.neutral50.opacity(0.54))
        )
    }
}

private struct ProcessStepIcon: View {
    var phase: AgentActivityPhase
    var state: AgentActivityState

    var body: some View {
        Group {
            if state == .running, phase == .status || phase == .thinking {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.48)
                    .tint(CodexProcessStyle.iconMuted)
            } else {
                Image(systemName: iconName)
                    .font(.system(size: 15, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(iconColor)
            }
        }
        .frame(width: 18, height: 18)
    }

    private var iconName: String {
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
            return CodexProcessStyle.iconMuted
        case .completed:
            return CodexProcessStyle.icon
        case .failed:
            return DesignTokens.danger.opacity(0.76)
        case .cancelled:
            return CodexProcessStyle.iconMuted
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

private extension String {
    var blankToNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
