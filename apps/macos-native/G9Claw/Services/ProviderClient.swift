import Foundation
import PDFKit

struct AgentPermissionRequest: Sendable, Equatable {
    var id: UUID
    var sessionId: String
    var toolName: String
    var inputJSON: String
    var reason: String
    var scope: PermissionScope
    var kind: PermissionRequestKind = .tool
    var interactivePayload: AgentInteractivePayload? = nil
}

enum AgentPermissionDecision: Sendable, Equatable {
    case allow(remember: Bool, updatedInputJSON: String?)
    case deny
}

struct AgentRequest: Sendable {
    var sessionId: String
    var projectPath: String
    var prompt: String
    var attachments: [FileAttachment] = []
    var providerConfig: ProviderConfig
    var apiKey: String
    var priorMessages: [ChatMessage]
    var timeoutMs: Int
    var contextWindow: Int
    var permissionMode: ComposerPermissionMode
    var runMode: ChatRunMode
    var workspaceContext: WorkspaceContext?
    var toolSettings: ToolPermissionSettings
    var routerRoute: String
    var nativeConfigValues: [String: String] = [:]
    var permissionHandler: (@MainActor @Sendable (AgentPermissionRequest) async -> AgentPermissionDecision)?
}

struct AttachmentDiagnostic: Sendable, Equatable {
    enum Severity: String, Sendable {
        case info
        case warning
        case error
    }

    var severity: Severity
    var message: String
}

enum ResolvedAttachmentBlock: Sendable, Equatable {
    case text(path: String, text: String)
    case image(path: String, mimeType: String, base64: String, bytes: Int)
}

struct NativeAttachmentResolver {
    static let maxTextBytes = 1_000_000
    static let maxImageBytes = 8_000_000
    static let maxTextCharacters = 30_000
    static let maxPDFPages = 10

    static func resolve(_ attachments: [FileAttachment]) -> (blocks: [ResolvedAttachmentBlock], diagnostics: [AttachmentDiagnostic]) {
        var blocks: [ResolvedAttachmentBlock] = []
        var diagnostics: [AttachmentDiagnostic] = []

        for attachment in attachments {
            let result = resolve(attachment)
            blocks.append(contentsOf: result.blocks)
            diagnostics.append(contentsOf: result.diagnostics)
        }

        return (blocks, diagnostics)
    }

    static func openAIContentParts(for attachments: [FileAttachment]) -> ([[String: Any]], [AttachmentDiagnostic]) {
        let resolved = resolve(attachments)
        var parts: [[String: Any]] = resolved.blocks.map { block in
            switch block {
            case .text(let path, let text):
                return [
                    "type": "text",
                    "text": "<attachment path=\"\(path)\">\n\(text)\n</attachment>",
                ]
            case .image(_, let mimeType, let base64, _):
                return [
                    "type": "image_url",
                    "image_url": [
                        "url": "data:\(mimeType);base64,\(base64)",
                    ],
                ]
            }
        }

        let warnings = resolved.diagnostics.filter { $0.severity != .info }
        if !warnings.isEmpty {
            parts.append([
                "type": "text",
                "text": "[Attachment diagnostics]\n" + warnings.map { "- \($0.message)" }.joined(separator: "\n"),
            ])
        }

        return (parts, resolved.diagnostics)
    }

    private static func resolve(_ attachment: FileAttachment) -> (blocks: [ResolvedAttachmentBlock], diagnostics: [AttachmentDiagnostic]) {
        let url = URL(fileURLWithPath: attachment.path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ([], [.init(severity: .warning, message: "Attachment not found: \(attachment.path).")])
        }

        if attachment.isImage {
            return resolveImage(attachment, url: url)
        }
        if attachment.isPDF {
            return resolvePDF(attachment, url: url)
        }
        if attachment.isTextLike {
            return resolveText(attachment, url: url)
        }

        let ext = url.pathExtension.isEmpty ? "(none)" : url.pathExtension
        return ([], [.init(severity: .info, message: "Attachment \(attachment.fileName) has unsupported extension \(ext); skipped.")])
    }

    private static func resolveImage(_ attachment: FileAttachment, url: URL) -> (blocks: [ResolvedAttachmentBlock], diagnostics: [AttachmentDiagnostic]) {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? NSNumber
        else {
            return ([], [.init(severity: .warning, message: "Unable to read image attachment metadata: \(attachment.fileName).")])
        }
        guard size.intValue <= maxImageBytes else {
            return ([], [.init(severity: .warning, message: "Image \(attachment.fileName) is \(size.intValue) bytes; limit is \(maxImageBytes).")])
        }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return ([], [.init(severity: .warning, message: "Unable to read image attachment: \(attachment.fileName).")])
        }
        let mimeType = attachment.mimeType ?? imageMimeType(for: url) ?? "image/png"
        return (
            [.image(path: url.path, mimeType: mimeType, base64: data.base64EncodedString(), bytes: data.count)],
            [.init(severity: .info, message: "Image attachment forwarded as multimodal input: \(attachment.fileName).")]
        )
    }

    private static func resolveText(_ attachment: FileAttachment, url: URL) -> (blocks: [ResolvedAttachmentBlock], diagnostics: [AttachmentDiagnostic]) {
        guard
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attributes[.size] as? NSNumber
        else {
            return ([], [.init(severity: .warning, message: "Unable to read text attachment metadata: \(attachment.fileName).")])
        }
        guard size.intValue <= maxTextBytes else {
            return ([], [.init(severity: .warning, message: "Attachment \(attachment.fileName) is \(size.intValue) bytes; limit is \(maxTextBytes).")])
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ([], [.init(severity: .warning, message: "Attachment \(attachment.fileName) is not valid UTF-8 text.")])
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ([], [.init(severity: .info, message: "Attachment \(attachment.fileName) is empty; skipped.")])
        }
        let truncated = trimmed.count > maxTextCharacters
        let output = String(trimmed.prefix(maxTextCharacters)) + (truncated ? "\n...[truncated]" : "")
        let diagnostics: [AttachmentDiagnostic] = truncated
            ? [.init(severity: .warning, message: "Attachment \(attachment.fileName) was truncated to \(maxTextCharacters) characters.")]
            : []
        return ([.text(path: url.path, text: output)], diagnostics)
    }

    private static func resolvePDF(_ attachment: FileAttachment, url: URL) -> (blocks: [ResolvedAttachmentBlock], diagnostics: [AttachmentDiagnostic]) {
        guard let document = PDFDocument(url: url) else {
            return ([], [.init(severity: .warning, message: "Unable to parse PDF attachment: \(attachment.fileName).")])
        }
        let selectedPages = Array(0..<min(document.pageCount, maxPDFPages))
        let text = selectedPages.map { index -> String in
            let pageText = document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
            return "## Page \(index + 1)\n\(pageText?.isEmpty == false ? pageText! : "(no extractable text)")"
        }.joined(separator: "\n\n")
        var diagnostics: [AttachmentDiagnostic] = [
            .init(severity: .info, message: "PDF \(attachment.fileName) resolved as text from \(selectedPages.count) page(s).")
        ]
        if document.pageCount > maxPDFPages {
            diagnostics.append(.init(severity: .warning, message: "PDF \(attachment.fileName) has \(document.pageCount) pages; only first \(maxPDFPages) pages were included."))
        }
        return ([.text(path: url.path, text: text)], diagnostics)
    }

    private static func imageMimeType(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "tiff", "tif": return "image/tiff"
        case "bmp": return "image/bmp"
        default: return nil
        }
    }
}

struct AgentToolCall: Sendable, Equatable {
    var id: String
    var name: String
    var inputJSON: String

    var signature: String {
        "\(name):\(Self.canonicalJSON(inputJSON))"
    }

    private static func canonicalJSON(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let canonicalData = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let canonical = String(data: canonicalData, encoding: .utf8) else {
            return json.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return canonical
    }
}

enum InteractivePlanContentDeferrer {
    struct Result: Equatable {
        var toolCalls: [AgentToolCall]
        var visibleIntro: String?
        var planMarkdown: String?
        var hiddenCompanionText: String?
        var suppressVisibleAssistantText: Bool
    }

    static func prepare(assistantContent: String, toolCalls: [AgentToolCall]) -> Result {
        prepare(assistantContent: assistantContent, toolCalls: toolCalls, runMode: .agent)
    }

    static func prepare(
        assistantContent: String,
        toolCalls: [AgentToolCall],
        runMode: ChatRunMode
    ) -> Result {
        let suppress = shouldSuppressVisibleAssistantContent(
            assistantContent: assistantContent,
            toolCalls: toolCalls,
            runMode: runMode
        )
        guard suppress else {
            return Result(
                toolCalls: toolCalls,
                visibleIntro: nil,
                planMarkdown: nil,
                hiddenCompanionText: nil,
                suppressVisibleAssistantText: false
            )
        }

        let split = splitInteractiveContent(assistantContent, toolCalls: toolCalls, runMode: runMode)
        let updatedCalls = toolCalls.map { call in
            attachDeferredPlanContentIfNeeded(split.planMarkdown, to: call)
        }
        return Result(
            toolCalls: updatedCalls,
            visibleIntro: split.visibleIntro,
            planMarkdown: split.planMarkdown,
            hiddenCompanionText: split.hiddenCompanionText,
            suppressVisibleAssistantText: true
        )
    }

    static func shouldSuppressVisibleAssistantContent(
        assistantContent: String,
        toolCalls: [AgentToolCall],
        runMode: ChatRunMode = .agent
    ) -> Bool {
        let trimmed = assistantContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if runMode == .plan {
            if toolCalls.isEmpty { return true }
            if toolCalls.contains(where: isInteractivePlanTool) { return true }
            return looksLikeInteractiveProtocolText(trimmed) || looksLikePotentialPlanText(trimmed)
        }
        return toolCalls.contains(where: isInteractivePlanTool)
    }

    static func shouldHoldStreamingContent(
        _ sample: String,
        runMode: ChatRunMode,
        hasToolCallAccumulator: Bool
    ) -> Bool {
        let trimmed = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if looksLikeInteractiveProtocolText(trimmed) { return true }
        if looksLikePotentialPlanText(trimmed) { return true }
        if runMode == .plan {
            return !hasToolCallAccumulator
        }
        if hasToolCallAccumulator {
            return false
        }
        return false
    }

    static func looksLikePotentialPlanText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()
        if lower.contains("switchmode") || lower.contains("执行计划") || lower.contains("实施计划") {
            return true
        }
        if lower.contains("计划") && (lower.contains("步骤") || lower.contains("确认") || lower.contains("执行")) {
            return true
        }
        if lower.contains("plan") && (lower.contains("execute") || lower.contains("implementation") || lower.contains("step")) {
            return true
        }
        if trimmed.hasPrefix("#") && (lower.contains("计划") || lower.contains("plan")) {
            return true
        }
        if trimmed.range(of: #"(?m)^\s*\d+\.\s+.+"#, options: .regularExpression) != nil,
           lower.contains("执行") || lower.contains("implement") || lower.contains("optimize") {
            return true
        }
        return false
    }

    private static func isInteractivePlanTool(_ call: AgentToolCall) -> Bool {
        switch AgentToolNameCanonicalizer.canonical(call.name) {
        case "AskQuestion", "SwitchMode":
            return true
        default:
            return false
        }
    }

    private static func looksLikeInteractiveProtocolText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if trimmed.hasPrefix("{") &&
            (lower.contains(#""tool""#) || lower.contains(#""name""#) || lower.contains("switchmode") || lower.contains("askquestion")) {
            return true
        }
        if trimmed.hasPrefix("<") &&
            (lower.contains("call") || lower.contains("tool") || lower.contains("switchmode") || lower.contains("askquestion")) {
            return true
        }
        return false
    }

    private static func splitInteractiveContent(
        _ assistantContent: String,
        toolCalls: [AgentToolCall],
        runMode: ChatRunMode
    ) -> (visibleIntro: String?, planMarkdown: String?, hiddenCompanionText: String?) {
        let trimmed = assistantContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, nil, nil) }

        let hasSwitchMode = toolCalls.contains {
            AgentToolNameCanonicalizer.canonical($0.name) == "SwitchMode"
        }
        let hasAskQuestion = toolCalls.contains {
            AgentToolNameCanonicalizer.canonical($0.name) == "AskQuestion"
        }
        if runMode == .plan, hasAskQuestion {
            return (nil, nil, trimmed)
        }
        if runMode == .plan, toolCalls.isEmpty {
            return (nil, nil, trimmed)
        }
        guard hasSwitchMode else {
            let intro = shortIntro(from: trimmed)
            return (intro, nil, trimmed == intro ? nil : trimmed)
        }

        if let range = planStartRange(in: trimmed) {
            let intro = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
            let plan = String(trimmed[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
            return (runMode == .plan ? nil : intro.map(shortIntro(from:)), plan, trimmed)
        }

        if looksLikePotentialPlanText(trimmed), trimmed.count > 220 {
            return (nil, trimmed, trimmed)
        }

        return (shortIntro(from: trimmed), nil, trimmed)
    }

    private static func planStartRange(in text: String) -> Range<String.Index>? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var offset = text.startIndex
        for lineSubsequence in lines {
            let line = String(lineSubsequence)
            let lower = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let isPlanHeading = lower.hasPrefix("#") &&
                (lower.contains("计划") || lower.contains("plan") || lower.contains("方案"))
            let isPlanList = lower.range(of: #"^\d+\.\s+.+"#, options: .regularExpression) != nil &&
                (text.lowercased().contains("计划") || text.lowercased().contains("plan"))
            if isPlanHeading || isPlanList {
                return offset..<offset
            }
            offset = text.index(offset, offsetBy: lineSubsequence.count)
            if offset < text.endIndex {
                offset = text.index(after: offset)
            }
        }
        return nil
    }

    private static func shortIntro(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 260 else { return trimmed }
        let paragraph = trimmed
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? trimmed
        if paragraph.count <= 260 { return paragraph }
        let index = paragraph.index(paragraph.startIndex, offsetBy: 240)
        return String(paragraph[..<index]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private static func attachDeferredPlanContentIfNeeded(_ planMarkdown: String?, to call: AgentToolCall) -> AgentToolCall {
        guard AgentToolNameCanonicalizer.canonical(call.name) == "SwitchMode" else {
            return call
        }

        var object = jsonObject(from: call.inputJSON) ?? [:]
        let existingPlan = (object["plan"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let planMarkdown = planMarkdown?.trimmingCharacters(in: .whitespacesAndNewlines), !planMarkdown.isEmpty {
            if existingPlan.isEmpty || planMarkdown.count > existingPlan.count + 80 {
                object["plan"] = planMarkdown
            }
            object["assistantPlanMarkdown"] = planMarkdown
        }
        if object["mode"] == nil {
            object["mode"] = "agent"
        }
        return AgentToolCall(id: call.id, name: call.name, inputJSON: jsonString(object, pretty: true))
    }

    private static func jsonObject(from inputJSON: String) -> [String: Any]? {
        guard let data = inputJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }
}

enum PlanModeIntroSynthesizer {
    static func intro(for toolCalls: [AgentToolCall], runMode: ChatRunMode) -> String? {
        guard runMode == .plan, !toolCalls.isEmpty else { return nil }
        let canonicalNames = toolCalls.map { AgentToolNameCanonicalizer.canonical($0.name) }
        guard toolCalls.allSatisfy(isPlanExplorationCall) else { return nil }
        if canonicalNames.contains(where: AgentToolPresentationClassifier.isReadTool) {
            return "我先查看相关文件和项目结构，用来完善计划。"
        }
        if canonicalNames.contains(where: { AgentToolPresentationClassifier.phase(forToolName: $0) == .search }) {
            return "我先搜索现有代码线索，用来完善计划。"
        }
        if canonicalNames.contains(where: { AgentToolPresentationClassifier.phase(forToolName: $0) == .command }) {
            return "我先运行只读命令确认上下文，用来完善计划。"
        }
        if canonicalNames.contains("TodoRead") || canonicalNames.contains("TodoWrite") {
            return "我先整理任务上下文，用来完善计划。"
        }
        return "我先收集必要上下文，用来完善计划。"
    }

    private static func isPlanExplorationCall(_ call: AgentToolCall) -> Bool {
        let toolName = AgentToolNameCanonicalizer.canonical(call.name)
        if toolName == "Shell" {
            return AgentRunContext.isReadOnlyShell(call.inputJSON)
        }
        if toolName == "Task" {
            return AgentRunContext.isReadOnlyTask(call.inputJSON)
        }
        return AgentPermissionPolicy.planModeSafeTools.contains(toolName) &&
            toolName != "AskQuestion" &&
            toolName != "SwitchMode"
    }
}

enum PlanTurnRecoveryClassifier {
    enum Recovery: Equatable {
        case askQuestion(AgentToolCall)
        case switchMode(AgentToolCall)
        case intro(String)
    }

    static func recovery(for assistantContent: String, context: AgentRunContext) -> Recovery? {
        guard context.runMode == .plan, !context.planExited else { return nil }
        let trimmed = assistantContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !looksLikeRawProtocol(trimmed) else { return nil }
        if !context.planQuestionAnswered {
            if looksLikeQuestionTurn(trimmed) || looksLikeFinalPlan(trimmed) {
                return .askQuestion(askQuestionCall(from: trimmed))
            }
            return .intro(shortIntro(from: trimmed))
        }
        if looksLikeFinalPlan(trimmed) {
            return .switchMode(switchModeCall(from: trimmed))
        }
        return .intro(shortIntro(from: trimmed))
    }

    static func fallbackSwitchModeCall(from text: String, userPrompt: String) -> AgentToolCall {
        let plan = fallbackPlanMarkdown(from: text, userPrompt: userPrompt)
        return switchModeCall(from: plan)
    }

    static func fallbackAskQuestionCall(from text: String) -> AgentToolCall {
        askQuestionCall(from: text)
    }

    private static func looksLikeRawProtocol(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.hasPrefix("<call") || lower.hasPrefix("<invoke") || lower.hasPrefix("<tool") || lower.hasPrefix("<response") {
            return true
        }
        if text.hasPrefix("{"),
           lower.contains(#""name""#) || lower.contains(#""tool""#) || lower.contains("askquestion") || lower.contains("switchmode") {
            return true
        }
        return false
    }

    private static func askQuestionCall(from text: String) -> AgentToolCall {
        let questions = choiceQuestions(from: text)
        let payload: [String: Any] = [
            "questions": questions,
            "recoveredFromPlainText": true,
        ]
        return AgentToolCall(
            id: "plan-recovery-ask-\(UUID().uuidString)",
            name: "AskQuestion",
            inputJSON: jsonString(payload, pretty: true)
        )
    }

    private static func switchModeCall(from text: String) -> AgentToolCall {
        let plan = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload: [String: Any] = [
            "mode": "agent",
            "plan": plan,
            "assistantPlanMarkdown": plan,
            "recoveredFromPlainText": true,
        ]
        return AgentToolCall(
            id: "plan-recovery-switch-\(UUID().uuidString)",
            name: "SwitchMode",
            inputJSON: jsonString(payload, pretty: true)
        )
    }

    private static func looksLikeQuestionTurn(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("askquestion") || lower.contains("switchmode") { return false }
        let markers = ["?", "？", "请告诉", "请选择", "需要确认", "几个问题", "补充", "偏好", "what", "which", "choose", "question"]
        if markers.contains(where: { lower.contains($0.lowercased()) }) { return true }
        return text.range(of: #"(?m)^\s*\d+[\.\)、)]\s*[^。\n]*[?？]"#, options: .regularExpression) != nil
    }

    private static func looksLikeFinalPlan(_ text: String) -> Bool {
        if InteractivePlanContentDeferrer.looksLikePotentialPlanText(text) { return true }
        let lower = text.lowercased()
        let hasPlanWord = lower.contains("计划") || lower.contains("方案") || lower.contains("实施") || lower.contains("plan")
        let numberedSteps = regexMatchCount(#"(?m)^\s*\d+[\.\)、)]\s+.+"#, in: text)
        return hasPlanWord && numberedSteps >= 2
    }

    private static func regexMatchCount(_ pattern: String, in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.numberOfMatches(in: text, range: range)
    }

    private static func extractedQuestions(from text: String) -> [[String: Any]] {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var result: [[String: Any]] = []
        var index = 0
        while index < lines.count, result.count < 4 {
            let line = lines[index]
            guard let question = normalizedQuestionLine(line) else {
                index += 1
                continue
            }
            var optionLabels = inlineOptions(from: line)
            var scan = index + 1
            while scan < lines.count {
                let candidate = lines[scan]
                if normalizedQuestionLine(candidate) != nil { break }
                if let option = normalizedOptionLine(candidate) {
                    optionLabels.append(option)
                }
                scan += 1
            }
            let options = optionDictionaries(optionLabels, fallback: fallbackOptions(for: question, sourceText: text))
            result.append([
                "header": "计划问题",
                "question": question,
                "options": options,
                "multiSelect": shouldAllowMultiple(question: question),
            ])
            index = max(scan, index + 1)
        }
        if result.isEmpty, looksLikeQuestionTurn(text) {
            result.append([
                "header": "计划问题",
                "question": fallbackQuestion(from: text),
                "options": optionDictionaries([], fallback: fallbackOptions(for: fallbackQuestion(from: text), sourceText: text)),
                "multiSelect": false,
            ])
        }
        return result
    }

    private static func choiceQuestions(from text: String) -> [[String: Any]] {
        if looksLikeCalendarTask(text) {
            let extracted = extractedQuestions(from: text)
            if extracted.count >= 2 {
                return extracted
            }
            return calendarChoiceQuestions()
        }
        var questions = extractedQuestions(from: text)
        if questions.isEmpty {
            let question = fallbackQuestion(from: text)
            questions = [[
                "header": "计划问题",
                "question": cleanQuestionText(question),
                "options": optionDictionaries([], fallback: fallbackOptions(for: question, sourceText: text)),
                "multiSelect": false,
            ]]
        }
        return questions.prefix(4).map { question in
            var repaired = question
            let questionText = (question["question"] as? String) ?? fallbackQuestion(from: text)
            let labels = optionLabels(in: question)
            repaired["question"] = cleanQuestionText(questionText)
            repaired["options"] = optionDictionaries(labels, fallback: fallbackOptions(for: questionText, sourceText: text))
            repaired["multiSelect"] = question["multiSelect"] as? Bool ?? shouldAllowMultiple(question: questionText)
            return repaired
        }
    }

    private static func calendarChoiceQuestions() -> [[String: Any]] {
        [
            [
                "header": "功能侧重",
                "question": "日历的功能侧重是什么？",
                "options": optionDictionaries([
                    "基础月历",
                    "日程管理",
                    "提醒与倒计时",
                    "节假日/农历展示",
                ], fallback: []),
                "multiSelect": true,
            ],
            [
                "header": "视觉风格",
                "question": "页面视觉风格偏好是什么？",
                "options": optionDictionaries([
                    "简洁现代",
                    "温暖生活感",
                    "高端玻璃质感",
                    "活泼多彩",
                ], fallback: []),
                "multiSelect": false,
            ],
            [
                "header": "数据方式",
                "question": "日程数据要如何处理？",
                "options": optionDictionaries([
                    "演示静态数据",
                    "localStorage 本地保存",
                    "支持导入导出",
                    "暂不需要日程数据",
                ], fallback: []),
                "multiSelect": false,
            ],
            [
                "header": "技术偏好",
                "question": "技术实现偏好是什么？",
                "options": optionDictionaries([
                    "原生 HTML/CSS/JS",
                    "沿用项目现有技术",
                    "优先响应式移动端",
                    "由 PilotDeck 判断",
                ], fallback: []),
                "multiSelect": false,
            ],
        ]
    }

    private static func looksLikeCalendarTask(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("日历") || lower.contains("calendar")
    }

    private static func optionLabels(in question: [String: Any]) -> [String] {
        if let options = question["options"] as? [[String: String]] {
            return options.compactMap { $0["label"] }
        }
        if let options = question["options"] as? [[String: Any]] {
            return options.compactMap { $0["label"] as? String }
        }
        if let options = question["options"] as? [String] {
            return options
        }
        return []
    }

    private static func normalizedQuestionLine(_ line: String) -> String? {
        guard !line.isEmpty else { return nil }
        let cleaned = cleanQuestionText(line.replacingOccurrences(
            of: #"^\s*(?:\d+[\.\)、)]|[-*•])\s*"#,
            with: "",
            options: .regularExpression
        ))
        guard !cleaned.isEmpty else { return nil }
        let lower = cleaned.lowercased()
        if !cleaned.contains("?"),
           !cleaned.contains("？"),
           (lower.contains("我来") || lower.contains("以便") || lower.contains("为了")) {
            return nil
        }
        if cleaned.contains("?") || cleaned.contains("？") ||
            lower.contains("是什么") ||
            lower.contains("偏好") ||
            lower.contains("需要哪些") ||
            lower.contains("请选择") ||
            lower.contains("请告诉") {
            return cleaned
        }
        return nil
    }

    private static func normalizedOptionLine(_ line: String) -> String? {
        let cleaned = cleanOptionText(line.replacingOccurrences(
            of: #"^\s*(?:[-*•]|\d+[\.\)、)])\s*"#,
            with: "",
            options: .regularExpression
        ))
        guard !cleaned.isEmpty, cleaned.count <= 80 else { return nil }
        if normalizedQuestionLine(cleaned) != nil { return nil }
        return cleaned
    }

    private static func fallbackQuestion(from text: String) -> String {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let firstQuestion = lines.first(where: { $0.contains("?") || $0.contains("？") }) {
            return normalizedQuestionLine(firstQuestion) ?? cleanQuestionText(firstQuestion)
        }
        if looksLikeCalendarTask(text) {
            return "日历的功能侧重是什么？"
        }
        return "请补充完成计划所需的关键信息。"
    }

    private static func inlineOptions(from line: String) -> [String] {
        let separators = ["例如：", "比如：", "可选：", "例如:", "比如:", "可选:", "options:", "such as"]
        guard let marker = separators.first(where: { line.lowercased().contains($0.lowercased()) }),
              let range = line.range(of: marker, options: [.caseInsensitive]) else {
            return []
        }
        let tail = String(line[range.upperBound...])
        return tail
            .replacingOccurrences(of: "或者", with: "、")
            .replacingOccurrences(of: "还是", with: "、")
            .components(separatedBy: CharacterSet(charactersIn: "、,，/；;"))
            .map(cleanOptionText)
            .filter { !$0.isEmpty }
    }

    private static func fallbackOptions(for question: String, sourceText: String) -> [String] {
        let lower = (question + " " + sourceText).lowercased()
        if lower.contains("功能") || lower.contains("模块") || lower.contains("需求") || lower.contains("feature") {
            return ["基础功能", "功能完整", "视觉展示优先", "由 PilotDeck 判断"]
        }
        if lower.contains("风格") || lower.contains("视觉") || lower.contains("style") || lower.contains("design") {
            return ["简洁现代", "高端质感", "活泼多彩", "系统原生"]
        }
        if lower.contains("数据") || lower.contains("保存") || lower.contains("storage") {
            return ["静态演示数据", "本地保存", "支持导入导出", "暂不需要"]
        }
        if lower.contains("技术") || lower.contains("框架") || lower.contains("html") || lower.contains("framework") {
            return ["原生 HTML/CSS/JS", "沿用现有技术", "轻量框架", "由 PilotDeck 判断"]
        }
        if looksLikeCalendarTask(lower) {
            return ["基础月历", "日程管理", "视觉效果优先", "由 PilotDeck 判断"]
        }
        return ["推荐方案", "简洁方案", "功能完整方案", "先继续分析"]
    }

    private static func optionDictionaries(_ labels: [String], fallback: [String]) -> [[String: String]] {
        let cleanedLabels = deduped(labels.map(cleanOptionText)).filter { !$0.isEmpty }
        let source = cleanedLabels.isEmpty ? fallback : cleanedLabels
        let finalLabels = deduped(source.map(cleanOptionText))
            .filter { !$0.isEmpty }
        return finalLabels.map { ["label": $0] }
    }

    private static func shouldAllowMultiple(question: String) -> Bool {
        let lower = question.lowercased()
        return lower.contains("多选") ||
            lower.contains("哪些") ||
            lower.contains("模块") ||
            lower.contains("功能") ||
            lower.contains("multiple")
    }

    private static func cleanQuestionText(_ text: String) -> String {
        var cleaned = text
            .replacingOccurrences(of: #"[*_`#]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\s*(?:\d+[\.\)、)]|[-•])\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return cleaned
    }

    private static func cleanOptionText(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"[*_`#]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\s*(?:例如|比如|可选)\s*[:：]\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "。.?？:：")))
    }

    private static func deduped(_ labels: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for label in labels {
            let key = label.lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(label)
        }
        return result
    }

    private static func fallbackPlanMarkdown(from text: String, userPrompt: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if looksLikeFinalPlan(trimmed) {
            return trimmed
        }
        let prompt = NativeAgentRuntime.primaryUserPrompt(from: userPrompt)
        let target = prompt.isEmpty ? "用户请求" : prompt
        return """
        ## 执行计划

        1. 梳理当前工作区和相关文件，确认实现入口。
        2. 根据已回答的问题完成设计和功能实现：\(target)。
        3. 保存必要文件，并进行一次只读检查或本地预览验证。
        4. 汇总完成内容、修改文件和验证结果。
        """
    }

    private static func shortIntro(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 180 else { return trimmed }
        let paragraph = trimmed
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? trimmed
        if paragraph.count <= 180 { return paragraph }
        let index = paragraph.index(paragraph.startIndex, offsetBy: 160)
        return String(paragraph[..<index]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

enum PlanWorkflowPresentation {
    static let generatingQuestionStatus = "plan generating question"
    static let collectingContextStatus = "plan collecting context"
    static let generatingPlanStatus = "plan generating plan"
    static let waitingForAnswerStatus = "plan waiting answer"
    static let waitingForConfirmationStatus = "plan waiting confirmation"
    static let recoveringStatus = "plan recovering workflow"
    static let recoveryNeededStatus = "plan recovery needed"

    static func generationStatus(for toolCalls: [AgentToolCall], runMode: ChatRunMode) -> String? {
        guard runMode == .plan, !toolCalls.isEmpty else { return nil }
        let names = toolCalls.map { AgentToolNameCanonicalizer.canonical($0.name) }
        if names.contains("AskQuestion") {
            return generatingQuestionStatus
        }
        if names.contains("SwitchMode") {
            return generatingPlanStatus
        }
        if toolCalls.allSatisfy(isPlanExplorationCall) {
            return collectingContextStatus
        }
        return nil
    }

    static func waitingStatus(for toolName: String, runMode: ChatRunMode) -> String? {
        guard runMode == .plan else { return nil }
        switch AgentToolNameCanonicalizer.canonical(toolName) {
        case "AskQuestion":
            return waitingForAnswerStatus
        case "SwitchMode":
            return waitingForConfirmationStatus
        default:
            return nil
        }
    }

    static func isInteractiveControl(_ toolName: String?) -> Bool {
        guard let toolName else { return false }
        let canonical = AgentToolNameCanonicalizer.canonical(toolName)
        return canonical == "AskQuestion" || canonical == "SwitchMode"
    }

    private static func isPlanExplorationCall(_ call: AgentToolCall) -> Bool {
        let toolName = AgentToolNameCanonicalizer.canonical(call.name)
        if toolName == "Shell" {
            return AgentRunContext.isReadOnlyShell(call.inputJSON)
        }
        if toolName == "Task" {
            return AgentRunContext.isReadOnlyTask(call.inputJSON)
        }
        return AgentPermissionPolicy.planModeSafeTools.contains(toolName) &&
            toolName != "AskQuestion" &&
            toolName != "SwitchMode"
    }
}

enum AgentToolNameCanonicalizer {
    static func canonical(_ rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        switch lower {
        case "read": return "Read"
        case "write": return "Write"
        case "strreplace", "str_replace", "str-replace", "edit", "multiedit", "multi_edit", "multi-edit":
            return "StrReplace"
        case "delete", "remove", "unlink": return "Delete"
        case "editnotebook", "edit_notebook", "edit-notebook", "notebookedit", "notebook_edit", "notebook-edit":
            return "EditNotebook"
        case "glob": return "Glob"
        case "grep": return "Grep"
        case "semanticsearch", "semantic_search", "semantic-search": return "SemanticSearch"
        case "bash", "shell", "run_command", "runcommand": return "Shell"
        case "await", "taskoutput", "task_output", "task-output", "agentoutputtool", "bashoutputtool":
            return "Await"
        case "websearch", "web_search", "web-search": return "WebSearch"
        case "webfetch", "web_fetch", "web-fetch": return "WebFetch"
        case "weather", "getweather", "get_weather", "get-weather": return "Weather"
        case "readlints", "read_lints", "read-lints", "lints", "lint": return "ReadLints"
        case "skill", "loadskill", "load_skill": return "Skill"
        case "task", "taskcreate", "task_create", "task-create", "agent", "subagent", "sub_agent", "sub-agent":
            return "Task"
        case "todoread", "todo_read", "todo-read": return "TodoRead"
        case "todowrite", "todo_write", "todo-write": return "TodoWrite"
        case "switchmode", "switch_mode", "switch-mode", "exitplanmode", "exit_plan_mode", "exit-plan-mode", "exitplanmodev2":
            return "SwitchMode"
        case "askquestion", "ask_question", "ask-question", "askuserquestion", "ask_user_question", "ask-user-question":
            return "AskQuestion"
        default: return trimmed
        }
    }
}

struct ToolArgumentNormalizer {
    struct NormalizationError: Error, Sendable, Equatable {
        var message: String
    }

    struct NormalizedInvocation: Sendable, Equatable {
        var call: AgentToolCall
        var recoveryResult: AgentToolResult?
    }

    static let invalidJSONRecoveryMessage = "Tool input was invalid JSON. Retry with a JSON object using double-quoted keys and strings."

    static func normalize(_ calls: [AgentToolCall]) -> [NormalizedInvocation] {
        calls.map(normalize)
    }

    static func normalize(_ call: AgentToolCall) -> NormalizedInvocation {
        let canonicalName = AgentToolNameCanonicalizer.canonical(call.name)
        switch canonicalObjectJSONString(call.inputJSON) {
        case .success(let canonical):
            if let legacySearch = canonicalizedLegacySearchInvocation(
                callId: call.id,
                toolName: canonicalName,
                inputJSON: canonical
            ) {
                return legacySearch
            }
            let canonicalInput = canonicalToolInputJSON(toolName: canonicalName, inputJSON: canonical)
            return NormalizedInvocation(
                call: AgentToolCall(id: call.id, name: canonicalName, inputJSON: canonicalInput),
                recoveryResult: nil
            )
        case .failure(let error):
            let safeCall = AgentToolCall(id: call.id, name: canonicalName, inputJSON: "{}")
            let output = "\(invalidJSONRecoveryMessage)\n\nTool: \(canonicalName)\nError: \(error.message)"
            return NormalizedInvocation(
                call: safeCall,
                recoveryResult: AgentToolResult(
                    callId: call.id,
                    toolName: canonicalName,
                    output: output,
                    isError: true
                )
            )
        }
    }

    private static func canonicalizedLegacySearchInvocation(
        callId: String,
        toolName: String,
        inputJSON: String
    ) -> NormalizedInvocation? {
        guard toolName == "WebSearch" || toolName == "Weather" else { return nil }
        guard let data = inputJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        guard let rawQuery = firstStringValue(
            keys: ["query", "q", "search_query", "location", "city", "place"],
            in: object
        ) else {
            return NormalizedInvocation(
                call: AgentToolCall(id: callId, name: "WebSearch", inputJSON: "{}"),
                recoveryResult: AgentToolResult(
                    callId: callId,
                    toolName: "WebSearch",
                    output: "\(toolName) requires a non-empty query.",
                    isError: true
                )
            )
        }
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let args = toolName == "Weather" && !lower.contains("weather") && !trimmed.contains("天气")
            ? "\(trimmed) weather"
            : trimmed
        return NormalizedInvocation(
            call: AgentToolCall(
                id: callId,
                name: "WebSearch",
                inputJSON: jsonString([
                    "query": args,
                ])
            ),
            recoveryResult: nil
        )
    }

    private static func firstStringValue(keys: [String], in object: [String: Any]) -> String? {
        for key in keys {
            guard let value = object[key] else { continue }
            let string: String
            if let raw = value as? String {
                string = raw
            } else if let number = value as? NSNumber {
                string = number.stringValue
            } else {
                string = String(describing: value)
            }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    static func providerSafeInputJSON(_ inputJSON: String) -> String {
        switch canonicalObjectJSONString(inputJSON) {
        case .success(let canonical):
            return canonical
        case .failure:
            return "{}"
        }
    }

    static func canonicalObjectJSONString(_ inputJSON: String) -> Result<String, NormalizationError> {
        let trimmed = inputJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? "{}" : trimmed
        guard let data = value.data(using: .utf8) else {
            return .failure(NormalizationError(message: "Input was not valid UTF-8."))
        }
        do {
            let parsed = try JSONSerialization.jsonObject(with: data)
            guard let object = parsed as? [String: Any] else {
                return .failure(NormalizationError(message: "Tool arguments must be a JSON object."))
            }
            guard JSONSerialization.isValidJSONObject(object) else {
                return .failure(NormalizationError(message: "Tool arguments contain a value that cannot be encoded as JSON."))
            }
            let canonicalData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            guard let canonical = String(data: canonicalData, encoding: .utf8) else {
                return .failure(NormalizationError(message: "Canonical JSON could not be encoded as UTF-8."))
            }
            return .success(canonical)
        } catch {
            return .failure(NormalizationError(message: error.localizedDescription))
        }
    }

    private static func canonicalToolInputJSON(toolName: String, inputJSON: String) -> String {
        guard let data = inputJSON.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return inputJSON
        }
        switch toolName {
        case "Shell":
            canonicalizeShellInput(&object)
        case "Skill":
            canonicalizeSkillInput(&object)
        case "Task":
            canonicalizeTaskInput(&object)
        case "StrReplace":
            canonicalizeStrReplaceInput(&object)
        case "Await":
            canonicalizeAwaitInput(&object)
        default:
            return inputJSON
        }
        guard JSONSerialization.isValidJSONObject(object),
              let canonicalData = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let canonical = String(data: canonicalData, encoding: .utf8) else {
            return inputJSON
        }
        return canonical
    }

    private static func canonicalizeShellInput(_ object: inout [String: Any]) {
        if let command = (object["command"] as? String).nilIfBlank {
            object["command"] = sanitizeXMLParameterWrapper(command)
        } else {
            let command = (object["input"] as? String).nilIfBlank
                ?? (object["input_command"] as? String).nilIfBlank
                ?? (object["cmd"] as? String).nilIfBlank
            if let command {
                object["command"] = sanitizeXMLParameterWrapper(command)
            }
        }
        object.removeValue(forKey: "input")
        object.removeValue(forKey: "input_command")
        object.removeValue(forKey: "cmd")
        if object["timeout"] == nil, let timeoutSeconds = object["timeout_seconds"] {
            object["timeout"] = timeoutSeconds
        }
        object.removeValue(forKey: "timeout_seconds")
    }

    private static func canonicalizeSkillInput(_ object: inout [String: Any]) {
        if let skill = (object["skill"] as? String).nilIfBlank {
            object["skill"] = sanitizeXMLParameterWrapper(skill)
        }
        if let args = (object["args"] as? String).nilIfBlank {
            object["args"] = sanitizeXMLParameterWrapper(args)
        }
    }

    private static func canonicalizeTaskInput(_ object: inout [String: Any]) {
        if object["prompt"] == nil {
            object["prompt"] = (object["description"] as? String)
                ?? (object["subject"] as? String)
                ?? (object["command"] as? String)
                ?? (object["input"] as? String)
                ?? ""
        }
        if object["type"] == nil, object["subagent_type"] != nil {
            object["type"] = object["subagent_type"]
        }
        object.removeValue(forKey: "subagent_type")
        object.removeValue(forKey: "input")
    }

    private static func canonicalizeStrReplaceInput(_ object: inout [String: Any]) {
        if object["old_string"] == nil, let value = object["oldString"] {
            object["old_string"] = value
        }
        if object["new_string"] == nil, let value = object["newString"] {
            object["new_string"] = value
        }
        object.removeValue(forKey: "oldString")
        object.removeValue(forKey: "newString")
    }

    private static func canonicalizeAwaitInput(_ object: inout [String: Any]) {
        if object["task_id"] == nil {
            object["task_id"] = object["id"] ?? object["taskId"]
        }
        object.removeValue(forKey: "id")
        object.removeValue(forKey: "taskId")
    }

    private static func sanitizeXMLParameterWrapper(_ value: String) -> String {
        var cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let regex = try? NSRegularExpression(pattern: #"(?is)^<parameter(?:\s+[^>]*)?>\s*"#),
           let match = regex.firstMatch(in: cleaned, range: NSRange(location: 0, length: (cleaned as NSString).length)),
           match.range.location == 0 {
            cleaned = (cleaned as NSString).substring(from: match.range.length)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if cleaned.range(of: #"(?is)</parameter>\s*$"#, options: .regularExpression) != nil {
            cleaned = cleaned.replacingOccurrences(
                of: #"(?is)</parameter>\s*$"#,
                with: "",
                options: .regularExpression
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleaned
    }
}

struct AgentToolResult: Sendable, Equatable {
    var callId: String
    var toolName: String
    var output: String
    var isError: Bool
    var isPolicyBlock: Bool = false
}

enum PlanWorkflowStage: String, Sendable {
    case needsQuestion
    case waitingForAnswer
    case answeredGeneratingPlan
    case waitingForConfirmation
    case executing
    case refining
}

final class AgentRunContext: @unchecked Sendable {
    var sessionId: String
    var workspacePath: String
    var runMode: ChatRunMode
    var permissionMode: ComposerPermissionMode
    var toolSettings: ToolPermissionSettings
    var planExited: Bool
    var todosJSON: String
    var continuationNudgeCount: Int
    var toolExecutionCount: Int
    var successfulToolExecutionCount: Int
    var exploratoryToolCount: Int
    var mutatingToolCount: Int
    var verificationAfterMutationCount: Int
    var failedToolCount: Int
    var recoverableProtocolErrorCount: Int
    var planPlainTextRecoveryCount: Int
    var planWorkflowStage: PlanWorkflowStage
    var planQuestionRecoveryCount: Int
    var planGenerationRecoveryCount: Int
    var providerConfig: ProviderConfig
    var apiKey: String
    var timeoutMs: Int
    var contextWindow: Int
    var nativeConfigValues: [String: String]
    var invokedSkills: [String]
    var planQuestionAnswered: Bool
    var subagentDepth: Int
    var maxSubagentDepth: Int
    var lastExecutedToolName: String?
    var lastToolResultWasError: Bool
    var planExecutionApproved: Bool
    var hasSuccessfulDeletion: Bool
    var lastToolResultWasBenignDeletionVerification: Bool
    var todoRequiresInitialization: Bool
    var todoRequiresRefresh: Bool
    var rootGlobCacheOutput: String?
    var rootGlobCacheEntryCount: Int
    var partialStreamRecoveryCount: Int
    var workspaceMutationEpoch: Int
    private var executedToolSignatures: Set<String>

    init(request: AgentRequest) {
        sessionId = request.sessionId
        workspacePath = request.projectPath
        runMode = request.runMode
        permissionMode = request.permissionMode
        toolSettings = request.toolSettings
        planExited = request.runMode == .agent
        todosJSON = "[]"
        continuationNudgeCount = 0
        toolExecutionCount = 0
        successfulToolExecutionCount = 0
        exploratoryToolCount = 0
        mutatingToolCount = 0
        verificationAfterMutationCount = 0
        failedToolCount = 0
        recoverableProtocolErrorCount = 0
        planPlainTextRecoveryCount = 0
        planWorkflowStage = request.runMode == .plan ? .needsQuestion : .executing
        planQuestionRecoveryCount = 0
        planGenerationRecoveryCount = 0
        providerConfig = request.providerConfig
        apiKey = request.apiKey
        timeoutMs = request.timeoutMs
        contextWindow = request.contextWindow
        nativeConfigValues = request.nativeConfigValues
        invokedSkills = []
        planQuestionAnswered = request.runMode == .agent
        subagentDepth = 0
        maxSubagentDepth = max(0, Int(request.nativeConfigValues["runtime.maxSubagentDepth"] ?? "") ?? 1)
        lastExecutedToolName = nil
        lastToolResultWasError = false
        planExecutionApproved = false
        hasSuccessfulDeletion = false
        lastToolResultWasBenignDeletionVerification = false
        todoRequiresInitialization = false
        todoRequiresRefresh = false
        rootGlobCacheOutput = nil
        rootGlobCacheEntryCount = 0
        partialStreamRecoveryCount = 0
        workspaceMutationEpoch = 0
        executedToolSignatures = []
    }

    func recordInvokedSkill(_ skill: String) {
        let trimmed = skill.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !invokedSkills.contains(trimmed) else { return }
        invokedSkills.append(trimmed)
    }

    var hasIncompleteTodos: Bool {
        Self.hasIncompleteTodos(in: todosJSON)
    }

    func markToolCallIfNeeded(_ call: AgentToolCall) -> Bool {
        executedToolSignatures.insert(deduplicationKey(for: call)).inserted
    }

    func deduplicatedInvocation(_ invocation: ToolArgumentNormalizer.NormalizedInvocation) -> ToolArgumentNormalizer.NormalizedInvocation? {
        let call = invocation.call
        let canonicalName = AgentToolNameCanonicalizer.canonical(call.name)
        if canonicalName == "TodoWrite" {
            if let incoming = Self.todoSnapshotSignature(in: call.inputJSON),
               let current = Self.todoSnapshotSignature(in: todosJSON),
               incoming == current {
                return ToolArgumentNormalizer.NormalizedInvocation(
                    call: call,
                    recoveryResult: duplicateToolResult(
                        call: call,
                        detail: "Todo list is already up to date. Continue with the next unfinished item or inspect current files before updating TodoWrite again."
                    )
                )
            }
            return invocation
        }

        if markToolCallIfNeeded(call) {
            return invocation
        }

        if Self.isDuplicateSoftBlockTool(call) {
            return ToolArgumentNormalizer.NormalizedInvocation(
                call: call,
                recoveryResult: duplicateToolResult(
                    call: call,
                    detail: "Duplicate tool request skipped; inspect current file or continue with the next distinct step."
                )
            )
        }
        return nil
    }

    func recordToolResult(_ result: AgentToolResult, call: AgentToolCall) {
        toolExecutionCount += 1
        lastExecutedToolName = result.toolName
        if result.isPolicyBlock {
            lastToolResultWasBenignDeletionVerification = false
            lastToolResultWasError = false
            return
        }
        let benignDeletionVerification = DeletionVerificationClassifier.isBenign(
            result: result,
            call: call,
            hasSuccessfulDeletion: hasSuccessfulDeletion
        )
        lastToolResultWasBenignDeletionVerification = benignDeletionVerification
        lastToolResultWasError = result.isError && !benignDeletionVerification
        if !result.isError {
            successfulToolExecutionCount += 1
            continuationNudgeCount = 0
            recoverableProtocolErrorCount = 0
            if DestructiveToolClassifier.isDestructive(call: call) {
                hasSuccessfulDeletion = true
            }
        } else {
            failedToolCount += 1
            if result.output.contains(ToolArgumentNormalizer.invalidJSONRecoveryMessage) {
                recoverableProtocolErrorCount += 1
            }
        }
        if result.toolName == "AskQuestion", !result.isError {
            planQuestionAnswered = true
            planWorkflowStage = .answeredGeneratingPlan
        }
        if result.toolName == "SwitchMode", !result.isError {
            if runMode == .plan {
                planWorkflowStage = .refining
            } else if planExited {
                planWorkflowStage = .executing
                if planExecutionApproved {
                    todoRequiresInitialization = true
                    todoRequiresRefresh = false
                }
            } else {
                planWorkflowStage = .waitingForConfirmation
            }
        }
        if result.toolName == "TodoWrite", !result.isError {
            todoRequiresInitialization = false
            todoRequiresRefresh = false
        } else if PlanTodoExecutionGate.requiresTodoRefresh(after: call, result: result) {
            todoRequiresRefresh = true
        }
        switch result.toolName {
        case "Read", "Glob", "Grep", "SemanticSearch", "ReadLints", "TodoRead", "Skill", "TodoWrite", "AskQuestion", "Await":
            exploratoryToolCount += 1
            if (!result.isError || benignDeletionVerification), mutatingToolCount > 0 {
                verificationAfterMutationCount += 1
            }
        case "Write", "StrReplace", "Delete", "EditNotebook", "Shell", "Task":
            if result.isError {
                break
            } else if result.toolName == "Shell", Self.isReadOnlyShell(call.inputJSON) {
                exploratoryToolCount += 1
                if mutatingToolCount > 0 {
                    verificationAfterMutationCount += 1
                }
            } else if result.toolName == "Task", Self.isReadOnlyTask(call.inputJSON) {
                exploratoryToolCount += 1
                if mutatingToolCount > 0 {
                    verificationAfterMutationCount += 1
                }
            } else {
                mutatingToolCount += 1
                workspaceMutationEpoch += 1
            }
        default:
            break
        }
    }

    private func deduplicationKey(for call: AgentToolCall) -> String {
        let canonicalName = AgentToolNameCanonicalizer.canonical(call.name)
        let base = "\(canonicalName):\(call.inputJSON)"
        if Self.isEpochScopedTool(call) {
            return "\(workspaceMutationEpoch):\(base)"
        }
        return base
    }

    private static func isEpochScopedTool(_ call: AgentToolCall) -> Bool {
        let canonicalName = AgentToolNameCanonicalizer.canonical(call.name)
        switch canonicalName {
        case "Read", "Grep", "Glob", "ReadLints", "SemanticSearch", "TodoRead", "Skill", "Await":
            return true
        case "Shell":
            return isReadOnlyShell(call.inputJSON)
        case "Task":
            return isReadOnlyTask(call.inputJSON)
        default:
            return false
        }
    }

    private static func isDuplicateSoftBlockTool(_ call: AgentToolCall) -> Bool {
        let canonicalName = AgentToolNameCanonicalizer.canonical(call.name)
        switch canonicalName {
        case "Write", "StrReplace", "Delete", "EditNotebook":
            return true
        case "Shell":
            return !isReadOnlyShell(call.inputJSON)
        case "Task":
            return !isReadOnlyTask(call.inputJSON)
        default:
            return false
        }
    }

    private func duplicateToolResult(call: AgentToolCall, detail: String) -> AgentToolResult {
        AgentToolResult(
            callId: call.id,
            toolName: AgentToolNameCanonicalizer.canonical(call.name),
            output: detail,
            isError: false,
            isPolicyBlock: true
        )
    }

    private static func todoSnapshotSignature(in inputJSON: String) -> String? {
        guard let data = inputJSON.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        if let object = value as? [String: Any], let todos = object["todos"] {
            return jsonString(todos)
        }
        if let array = value as? [Any] {
            return jsonString(array)
        }
        return nil
    }

    static func hasIncompleteTodos(in todosJSON: String) -> Bool {
        guard let data = todosJSON.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else {
            return false
        }
        return containsIncompleteTodo(value)
    }

    private static func containsIncompleteTodo(_ value: Any) -> Bool {
        if let object = value as? [String: Any] {
            if let todos = object["todos"] {
                return containsIncompleteTodo(todos)
            }
            if object["content"] != nil || object["title"] != nil || object["task"] != nil {
                let rawStatus = (object["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    ?? (object["done"] as? Bool == true ? "completed" : "pending")
                return rawStatus != "completed" && rawStatus != "done"
            }
            return object.values.contains { containsIncompleteTodo($0) }
        }
        if let array = value as? [Any] {
            return array.contains { containsIncompleteTodo($0) }
        }
        return false
    }

    static func isReadOnlyShell(_ inputJSON: String) -> Bool {
        guard let data = inputJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = object["command"] as? String else {
            return false
        }
        let trimmed = command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !trimmed.isEmpty else { return false }
        let writeMarkers = [">", ">>", "| tee", "rm ", "mv ", "cp ", "mkdir ", "touch ", "sed -i", "perl -pi", "python ", "node ", "npm ", "bun ", "swift "]
        if writeMarkers.contains(where: { trimmed.contains($0) }) {
            return false
        }
        let readPrefixes = [
            "date",
            "pwd",
            "ls",
            "find",
            "grep",
            "rg",
            "cat",
            "wc",
            "head",
            "tail",
            "stat",
            "file",
            "du",
            "git status",
            "git diff",
            "git log",
            "git show",
            "git ls-files",
        ]
        return readPrefixes.contains { trimmed == $0 || trimmed.hasPrefix($0 + " ") }
    }

    static func isReadOnlyTask(_ inputJSON: String) -> Bool {
        guard let data = inputJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        let type = ((object["type"] as? String) ?? "generalPurpose")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return ["explore", "cursor-guide", "ci-investigator"].contains(type)
    }
}

enum PlanTodoExecutionGate {
    static func blockingResult(for call: AgentToolCall, context: AgentRunContext) -> AgentToolResult? {
        guard context.planExecutionApproved else { return nil }
        let toolName = AgentToolNameCanonicalizer.canonical(call.name)
        guard toolName != "TodoWrite", !isReadOnlyTool(call) else { return nil }
        if context.todoRequiresInitialization {
            return requiredTodoResult(
                call: call,
                reason: "Initialize the execution todo list with TodoWrite before the first workspace-changing tool after plan approval."
            )
        }
        if context.todoRequiresRefresh {
            return requiredTodoResult(
                call: call,
                reason: "Update the todo list with TodoWrite before the next workspace-changing tool so progress remains visible."
            )
        }
        return nil
    }

    static func requiresTodoRefresh(after call: AgentToolCall, result: AgentToolResult) -> Bool {
        guard !result.isError, !result.isPolicyBlock else { return false }
        let toolName = AgentToolNameCanonicalizer.canonical(call.name)
        guard toolName != "TodoWrite" else { return false }
        return !isReadOnlyTool(call)
    }

    static func isReadOnlyTool(_ call: AgentToolCall) -> Bool {
        switch AgentToolNameCanonicalizer.canonical(call.name) {
        case "Read", "Glob", "Grep", "SemanticSearch", "ReadLints", "TodoRead", "AskQuestion", "SwitchMode", "Await", "Skill":
            return true
        case "Shell":
            return AgentRunContext.isReadOnlyShell(call.inputJSON)
        case "Task":
            return AgentRunContext.isReadOnlyTask(call.inputJSON)
        default:
            return false
        }
    }

    private static func requiredTodoResult(call: AgentToolCall, reason: String) -> AgentToolResult {
        AgentToolResult(
            callId: call.id,
            toolName: AgentToolNameCanonicalizer.canonical(call.name),
            output: "\(reason) The requested \(AgentToolNameCanonicalizer.canonical(call.name)) tool was not executed yet; call TodoWrite next, then retry this tool.",
            isError: false,
            isPolicyBlock: true
        )
    }
}

enum RootGlobExecutionPolicy {
    static func isRootWorkspaceGlob(inputJSON: String) -> Bool {
        guard let data = inputJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        let pattern = ((object["pattern"] as? String) ?? (object["glob"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let path = ((object["path"] as? String) ?? ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return pattern == "**/*" && (path.isEmpty || path == "." || path == "./")
    }

    static func cachedResultIfAvailable(call: AgentToolCall, context: AgentRunContext) -> AgentToolResult? {
        guard AgentToolNameCanonicalizer.canonical(call.name) == "Glob",
              isRootWorkspaceGlob(inputJSON: call.inputJSON),
              let cached = context.rootGlobCacheOutput,
              !cached.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return AgentToolResult(
            callId: call.id,
            toolName: "Glob",
            output: cachedSummary(from: cached, entryCount: context.rootGlobCacheEntryCount),
            isError: false
        )
    }

    static func recordIfRootGlob(call: AgentToolCall, output: String, context: AgentRunContext) -> String {
        guard AgentToolNameCanonicalizer.canonical(call.name) == "Glob",
              isRootWorkspaceGlob(inputJSON: call.inputJSON) else {
            return output
        }
        context.rootGlobCacheOutput = output
        context.rootGlobCacheEntryCount = entryCount(output)
        return compactBootstrapOutput(output)
    }

    private static func cachedSummary(from output: String, entryCount: Int) -> String {
        let count = entryCount > 0 ? entryCount : self.entryCount(output)
        return """
        Cached workspace discovery from earlier Glob **/* (\(count) entries). Use targeted Read/Grep/Glob for known paths instead of repeating full workspace discovery.
        \(compactBootstrapOutput(output))
        """
    }

    private static func compactBootstrapOutput(_ output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard lines.count > 160 || trimmed.count > 12_000 else { return trimmed }
        let preview = lines.prefix(140).joined(separator: "\n")
        return "\(preview)\n... workspace discovery truncated for display; \(lines.count) total entries ..."
    }

    private static func entryCount(_ output: String) -> Int {
        output.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }
}

enum DestructiveToolClassifier {
    static func isDestructive(call: AgentToolCall) -> Bool {
        let toolName = AgentToolNameCanonicalizer.canonical(call.name)
        if toolName == "Delete" { return true }
        guard toolName == "Shell", let command = stringValue("command", in: call.inputJSON) else {
            return false
        }
        return isDestructiveShellCommand(command)
    }

    static func targetDescription(call: AgentToolCall) -> String {
        let toolName = AgentToolNameCanonicalizer.canonical(call.name)
        if toolName == "Delete" {
            return stringValue("path", in: call.inputJSON) ?? "selected path"
        }
        if toolName == "Shell", let command = stringValue("command", in: call.inputJSON) {
            return compact(command, limit: 120)
        }
        return toolName
    }

    static func planJSON(call: AgentToolCall, isChinese: Bool = true) -> String {
        let toolName = AgentToolNameCanonicalizer.canonical(call.name)
        let target = targetDescription(call: call)
        let title = isChinese ? "删除计划确认" : "Destructive change approval"
        let impact = isChinese
            ? "即将执行会删除文件或目录的操作：\(toolName)。目标：\(target)。"
            : "The agent is about to run a deletion-capable \(toolName) operation. Target: \(target)."
        let verify = isChinese
            ? "执行后将通过文件读取或搜索结果确认目标已经不存在。"
            : "After execution, the agent should verify that the target no longer exists."
        return jsonString([
            "title": title,
            "mode": "agent",
            "plan": "\(impact)\n\n\(verify)",
            "destructiveTool": toolName,
            "target": target,
        ], pretty: true)
    }

    private static func isDestructiveShellCommand(_ command: String) -> Bool {
        command
            .lowercased()
            .components(separatedBy: CharacterSet(charactersIn: "\n;&|"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .contains { segment in
                let normalized = segment.hasPrefix("sudo ") ? String(segment.dropFirst(5)) : segment
                return normalized.hasPrefix("rm ") ||
                    normalized.hasPrefix("rmdir ") ||
                    normalized.hasPrefix("trash ") ||
                    (normalized.hasPrefix("find ") && normalized.contains(" -delete"))
            }
    }

    private static func stringValue(_ key: String, in inputJSON: String) -> String? {
        guard let data = inputJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return (object[key] as? String)?.nilIfBlank
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

enum DeletionVerificationClassifier {
    static func isBenign(result: AgentToolResult, call: AgentToolCall, hasSuccessfulDeletion: Bool) -> Bool {
        guard hasSuccessfulDeletion,
              result.isError,
              isVerificationTool(call.name),
              isMissingPathOutput(result.output) else {
            return false
        }
        return true
    }

    static func shouldSuppressTranscriptPair(call: ToolCall, result: ToolResult?, sawSuccessfulDeletion: Bool) -> Bool {
        guard sawSuccessfulDeletion,
              let result,
              result.isError,
              isRootWildcardGlob(call),
              isMissingPathOutput(result.output) else {
            return false
        }
        return true
    }

    static func isSuccessfulDeletion(call: ToolCall, result: ToolResult?) -> Bool {
        guard result?.isError == false else { return false }
        return DestructiveToolClassifier.isDestructive(
            call: AgentToolCall(id: call.id, name: call.name, inputJSON: call.inputJSON)
        )
    }

    private static func isVerificationTool(_ toolName: String) -> Bool {
        switch AgentToolNameCanonicalizer.canonical(toolName) {
        case "Glob", "Read", "Grep":
            return true
        default:
            return false
        }
    }

    private static func isRootWildcardGlob(_ call: ToolCall) -> Bool {
        guard AgentToolNameCanonicalizer.canonical(call.name) == "Glob",
              let data = call.inputJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        let pattern = ((object["pattern"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let path = ((object["path"] as? String) ?? ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return pattern == "**/*" && (path.isEmpty || path == "." || path == "./")
    }

    private static func isMissingPathOutput(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("path does not exist") ||
            lower.contains("no such file") ||
            lower.contains("directory not found") ||
            lower.contains("file not found") ||
            lower.contains("couldn’t be opened") ||
            lower.contains("couldn't be opened") ||
            lower.contains("目录不存在") ||
            lower.contains("不存在")
    }
}

enum AgentLoopState: Sendable, Equatable {
    case thinking
    case runningTool(String)
    case waitingForPermission(String)
    case complete
    case error(String)
}

enum ContinuationPolicy {
    static let maxNudges = 5
    static let maxRecoverableProtocolErrors = 3
}

enum AgentLoopWatchdogDecision: Equatable {
    case continueWithNudge(String)
    case pauseNeedsUser(String)
}

struct AgentLoopWatchdog: Equatable {
    static let maxDuplicateOnlyTurns = 4
    static let maxRepeatedErrorResults = 3

    private var duplicateOnlyTurns = 0
    private var lastErrorSignature: String?
    private var repeatedErrorResults = 0

    mutating func recordProgress() {
        duplicateOnlyTurns = 0
    }

    mutating func recordDuplicateOnlyTurn() -> AgentLoopWatchdogDecision {
        duplicateOnlyTurns += 1
        if duplicateOnlyTurns >= Self.maxDuplicateOnlyTurns {
            return .pauseNeedsUser("Agent repeated the same tool request without making progress. Please continue with a more specific instruction or adjust the request.")
        }
        return .continueWithNudge("""
        The previous tool request was a duplicate and was skipped. Do not repeat the exact same tool call.
        Inspect the current file state if needed, update TodoWrite for real progress changes, or continue with the next distinct implementation or verification step.
        """)
    }

    mutating func recordToolResult(_ result: AgentToolResult) -> String? {
        guard !result.isPolicyBlock else {
            lastErrorSignature = nil
            repeatedErrorResults = 0
            return nil
        }
        guard result.isError else {
            lastErrorSignature = nil
            repeatedErrorResults = 0
            return nil
        }
        let signature = "\(result.toolName):\(compact(result.output, limit: 240))"
        if signature == lastErrorSignature {
            repeatedErrorResults += 1
        } else {
            lastErrorSignature = signature
            repeatedErrorResults = 1
        }
        guard repeatedErrorResults >= Self.maxRepeatedErrorResults else { return nil }
        return "Agent encountered the same tool error repeatedly and paused to avoid an unproductive loop: \(compact(result.output, limit: 180))"
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

struct NativeContextCompactionResult {
    var messages: [[String: Any]]
    var trigger: String
    var preTokens: Int
    var postTokens: Int
    var status: String
}

enum NativeContextBudget {
    private static let perMessageOverhead = 4
    private static let multimediaTokens = 2_000

    static func snapshot(messages: [[String: Any]], contextWindow: Int) -> TokenBudget {
        let total = max(contextWindow, 1)
        let used = max(0, messages.reduce(0) { $0 + estimateMessage($1) })
        return TokenBudget(used: used, total: total, level: ContextBudgetLevel.level(used: used, total: total))
    }

    static func compactIfNeeded(messages: [[String: Any]], contextWindow: Int) -> NativeContextCompactionResult? {
        let before = snapshot(messages: messages, contextWindow: contextWindow)
        guard (before.level ?? .normal) == .warning || (before.level ?? .normal) == .recovering else {
            return nil
        }

        var compacted = microCompactToolResults(messages)
        var after = snapshot(messages: compacted, contextWindow: contextWindow)
        var status = "micro"
        if (after.level ?? .normal) == .warning || (after.level ?? .normal) == .recovering {
            compacted = snipMiddle(compacted, tailCount: 10)
            after = snapshot(messages: compacted, contextWindow: contextWindow)
            status = "snip"
        }
        if (after.level ?? .normal) == .warning || (after.level ?? .normal) == .recovering {
            compacted = snipMiddle(compacted, tailCount: 6)
            after = snapshot(messages: compacted, contextWindow: contextWindow)
            status = "full"
        }

        return NativeContextCompactionResult(
            messages: compacted,
            trigger: (before.level ?? .normal) == .recovering ? "blocking_threshold" : "warning_threshold",
            preTokens: before.used,
            postTokens: after.used,
            status: status
        )
    }

    static func forceRecover(messages: [[String: Any]], contextWindow: Int) -> NativeContextCompactionResult {
        let before = snapshot(messages: messages, contextWindow: contextWindow)
        let compacted = snipMiddle(microCompactToolResults(messages), tailCount: 4)
        let after = snapshot(messages: compacted, contextWindow: contextWindow)
        return NativeContextCompactionResult(
            messages: compacted,
            trigger: "prompt_too_long",
            preTokens: before.used,
            postTokens: after.used,
            status: "recovering"
        )
    }

    private static func microCompactToolResults(_ messages: [[String: Any]]) -> [[String: Any]] {
        var next = messages
        guard next.count > 8 else { return next }
        let recentToolIndices = Set(next.indices.filter { (next[$0]["role"] as? String) == "tool" }.suffix(4))
        for index in next.indices.dropLast(6) where (next[index]["role"] as? String) == "tool" && !recentToolIndices.contains(index) {
            guard let content = next[index]["content"] as? String, content.count > 3_000 else { continue }
            next[index]["content"] = "\(content.prefix(1_600))\n... (microcompacted, original \(content.count) characters)"
        }
        return preserveToolPairIntegrity(next)
    }

    private static func snipMiddle(_ messages: [[String: Any]], tailCount: Int) -> [[String: Any]] {
        guard messages.count > tailCount + 3 else { return messages }
        let systemMessages = messages.prefix { ($0["role"] as? String) == "system" }
        let bodyStart = systemMessages.count
        let body = Array(messages.dropFirst(bodyStart))
        let tail = validTail(from: body, count: tailCount)
        let dropped = max(0, body.count - tail.count)
        let summary = [
            "role": "user",
            "content": """
            [Context compacted]
            Older conversation turns were summarized locally before continuing.
            Messages summarized: \(dropped).
            Continue the current task using the latest visible context and tool results.
            """,
        ]
        return Array(systemMessages) + [summary] + tail
    }

    private static func validTail(from messages: [[String: Any]], count: Int) -> [[String: Any]] {
        var tail = Array(messages.suffix(max(1, count)))
        while tail.first?["role"] as? String == "tool" {
            tail.removeFirst()
        }
        return preserveToolPairIntegrity(tail)
    }

    static func preserveToolPairIntegrity(_ messages: [[String: Any]]) -> [[String: Any]] {
        let assistantCallIDs = Set(messages.flatMap(toolCallIDs(in:)))
        let toolResultIDs = Set(messages.compactMap(toolResultID(in:)))
        let pairedIDs = assistantCallIDs.intersection(toolResultIDs)
        return messages.compactMap { message in
            let role = message["role"] as? String
            if role == "tool" {
                guard let id = toolResultID(in: message), pairedIDs.contains(id) else { return nil }
                return message
            }
            if role == "assistant", let calls = message["tool_calls"] as? [[String: Any]] {
                var next = message
                let filteredCalls = calls.filter { call in
                    guard let id = call["id"] as? String else { return false }
                    return pairedIDs.contains(id)
                }
                if filteredCalls.isEmpty {
                    next.removeValue(forKey: "tool_calls")
                    if contentIsEmpty(next["content"]) {
                        return nil
                    }
                } else {
                    next["tool_calls"] = filteredCalls
                }
                return next
            }
            return message
        }
    }

    private static func toolCallIDs(in message: [String: Any]) -> [String] {
        guard (message["role"] as? String) == "assistant",
              let calls = message["tool_calls"] as? [[String: Any]] else {
            return []
        }
        return calls.compactMap { $0["id"] as? String }
    }

    private static func toolResultID(in message: [String: Any]) -> String? {
        guard (message["role"] as? String) == "tool" else { return nil }
        return message["tool_call_id"] as? String
    }

    private static func contentIsEmpty(_ value: Any?) -> Bool {
        if value == nil || value is NSNull { return true }
        if let string = value as? String {
            return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return false
    }

    private static func estimateMessage(_ message: [String: Any]) -> Int {
        perMessageOverhead + estimateValue(message["content"]) + estimateToolCalls(message["tool_calls"])
    }

    private static func estimateToolCalls(_ value: Any?) -> Int {
        guard let value else { return 0 }
        return max(1, serializedLength(value) / 4)
    }

    private static func estimateValue(_ value: Any?) -> Int {
        guard let value else { return 0 }
        if let text = value as? String {
            return max(1, text.count / 4)
        }
        if let parts = value as? [[String: Any]] {
            return parts.reduce(0) { partial, part in
                if part["type"] as? String == "image_url" {
                    return partial + multimediaTokens
                }
                return partial + estimateValue(part["text"]) + estimateValue(part["image_url"])
            }
        }
        return max(1, serializedLength(value) / 4)
    }

    private static func serializedLength(_ value: Any) -> Int {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else {
            return String(describing: value).count
        }
        return data.count
    }
}

enum CompletionGate {
    enum Decision: Equatable {
        case complete
        case continueWithNudge(String)
        case pauseNeedsUser(String)
        case realError(String)
    }

    static func canFinish(request: AgentRequest, context: AgentRunContext, assistantContent: String) -> Bool {
        decision(request: request, context: context, assistantContent: assistantContent) == .complete
    }

    static func decision(request: AgentRequest, context: AgentRunContext, assistantContent: String) -> Decision {
        if context.lastToolResultWasError {
            return .realError("The last tool call failed and the agent could not recover automatically.")
        }
        if context.runMode == .plan, !context.planExited {
            return .pauseNeedsUser(NativeAgentRuntime.planModeProtocolRecoveryMessage)
        }
        guard NativeAgentRuntime.isWorkspaceMutationRequest(request.prompt) else {
            return .complete
        }
        if context.mutatingToolCount == 0 {
            return continuationOrPause(request: request, context: context, assistantContent: assistantContent)
        }
        if NativeAgentRuntime.requiresPostMutationVerification(request.prompt),
           context.verificationAfterMutationCount == 0 {
            return continuationOrPause(request: request, context: context, assistantContent: assistantContent)
        }
        if context.hasIncompleteTodos {
            return continuationOrPause(request: request, context: context, assistantContent: assistantContent)
        }
        let content = assistantContent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if content.isEmpty || content == "bash" || content == "json" {
            return continuationOrPause(request: request, context: context, assistantContent: assistantContent)
        }
        if NativeAgentRuntime.looksLikeOngoingWorkspaceWork(content) {
            return continuationOrPause(request: request, context: context, assistantContent: assistantContent)
        }
        return .complete
    }

    private static func continuationOrPause(
        request: AgentRequest,
        context: AgentRunContext,
        assistantContent: String
    ) -> Decision {
        if let nudge = NativeAgentRuntime.continuationNudge(
            request: request,
            context: context,
            assistantContent: assistantContent
        ) {
            return .continueWithNudge(nudge)
        }
        return .pauseNeedsUser("The task appears to still be in progress, but automatic continuation paused to avoid an unproductive loop. You can type 继续 or add more specific instructions to resume.")
    }
}

enum AgentEvent: Sendable, Equatable {
    case turnStarted(AgentTurn)
    case turnItemStarted(AgentTurnItem)
    case turnItemUpdated(AgentTurnItem)
    case turnItemCompleted(AgentTurnItem)
    case turnCompleted(AgentTurn)
    case sessionCreated(sessionId: String)
    case contentDelta(String)
    case reasoningDelta(String)
    case toolUse(id: String, name: String, inputJSON: String)
    case toolResult(id: String, output: String, isError: Bool)
    case permissionRequest(AgentPermissionRequest)
    case status(String)
    case tokenBudget(used: Int, total: Int)
    case contextBudget(used: Int, total: Int, level: ContextBudgetLevel)
    case compactStarted(trigger: String, preTokens: Int)
    case compactCompleted(status: String, preTokens: Int, postTokens: Int)
    case subagentStatus(id: String, status: String, detail: String)
    case streamEnd
    case complete(sessionId: String)
    case aborted(sessionId: String)
    case error(String)
}

extension AgentEvent {
    var isTerminal: Bool {
        switch self {
        case .complete, .aborted, .error:
            return true
        default:
            return false
        }
    }
}

enum ProviderClientError: Error, LocalizedError {
    case missingBaseURL
    case missingModel
    case missingAPIKey
    case invalidURL(String)
    case httpError(statusCode: Int, body: String)
    case unsupportedProvider(SessionProvider)
    case invalidResponse
    case transport(String)
    case streamInterruptedAfterPartialOutput(String)
    case toolExecution(String)

    var errorDescription: String? {
        switch self {
        case .missingBaseURL: "Provider base URL is not configured."
        case .missingModel: "Provider model is not configured."
        case .missingAPIKey: "Provider API key is not configured. Add it in Settings or ~/.g9claw/config.yaml."
        case .invalidURL(let value): "Provider base URL is invalid: \(value)"
        case .httpError(let statusCode, let body):
            if body.isEmpty {
                "Provider request failed with HTTP \(statusCode)."
            } else {
                "Provider request failed with HTTP \(statusCode): \(body)"
            }
        case .unsupportedProvider(let provider): "\(provider.displayName) is not implemented yet in native AgentCore."
        case .invalidResponse: "Provider returned an invalid response."
        case .transport(let message): message
        case .streamInterruptedAfterPartialOutput(let message):
            "Provider response stream disconnected after partial output: \(message)"
        case .toolExecution(let message): message
        }
    }
}

struct ProviderRetryPolicy: Sendable, Equatable {
    var requestMaxRetries: Int
    var streamMaxRetries: Int
    var baseDelayMs: Int
    var retry429: Bool
    var retry5xx: Bool
    var retryTransport: Bool

    static let codexDefault = ProviderRetryPolicy(
        requestMaxRetries: 4,
        streamMaxRetries: 5,
        baseDelayMs: 200,
        retry429: false,
        retry5xx: true,
        retryTransport: true
    )
}

struct ProviderRetryDecision: Sendable, Equatable {
    var shouldRetry: Bool
    var delay: TimeInterval
    var reason: String

    static let noRetry = ProviderRetryDecision(shouldRetry: false, delay: 0, reason: "")
}

struct NativeAgentRuntime: Sendable {
    private static let threadManager = NativeThreadManager()
    static let planModeProtocolRecoveryMessage = "Plan mode could not reach a user question or plan confirmation. AskQuestion or SwitchMode mode=\"agent\" is required before the turn can finish."

    func stream(request: AgentRequest) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let nativeSession = await Self.threadManager.session(for: request)
                let turnController = await nativeSession.startTurn(request: request)
                do {
                    let startedTurn = await turnController.snapshot()
                    continuation.yield(.turnStarted(startedTurn))
                    let userItem = await turnController.recordUserMessage(request.prompt)
                    continuation.yield(.turnItemCompleted(userItem))
                    continuation.yield(.sessionCreated(sessionId: request.sessionId))
                    let connectingItem = await turnController.recordStatus("connecting")
                    continuation.yield(.turnItemStarted(connectingItem))
                    continuation.yield(.status("connecting"))

                    switch request.providerConfig.provider {
                    case .g9Claw:
                        try await Self.streamG9ClawAgent(
                            request: request,
                            continuation: continuation,
                            turnController: turnController
                        )
                    case .cursor, .codex, .gemini:
                        throw ProviderClientError.unsupportedProvider(request.providerConfig.provider)
                    }

                    continuation.yield(.streamEnd)
                    await turnController.finish()
                    await nativeSession.recordSnapshot(from: turnController)
                    continuation.yield(.turnCompleted(await turnController.snapshot()))
                    continuation.yield(.complete(sessionId: request.sessionId))
                    continuation.finish()
                } catch is CancellationError {
                    await turnController.interrupt(reason: "Cancelled.")
                    await nativeSession.recordSnapshot(from: turnController)
                    continuation.yield(.turnCompleted(await turnController.snapshot()))
                    continuation.yield(.aborted(sessionId: request.sessionId))
                    continuation.finish()
                } catch {
                    await turnController.fail(reason: error.localizedDescription)
                    await nativeSession.recordSnapshot(from: turnController)
                    continuation.yield(.turnCompleted(await turnController.snapshot()))
                    continuation.yield(.error(error.localizedDescription))
                    continuation.finish()
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private static func streamG9ClawAgent(
        request: AgentRequest,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation,
        turnController: NativeTurnController
    ) async throws {
        let config = request.providerConfig
        guard !config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderClientError.missingBaseURL
        }
        guard !config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderClientError.missingModel
        }
        guard config.apiType == .openAIChat else {
            throw ProviderClientError.unsupportedProvider(config.provider)
        }

        let context = AgentRunContext(request: request)
        var messages = openAIInitialMessages(request: request)
        var didForceWorkspaceBootstrap = false
        var didRecoverContextOverflow = false
        var loopWatchdog = AgentLoopWatchdog()
        var iteration = 0

        while !Task.isCancelled {
            iteration += 1
            if Task.isCancelled { throw CancellationError() }
            let statusItem = await turnController.recordStatus(iteration == 1 ? "thinking" : "processing")
            continuation.yield(.turnItemStarted(statusItem))
            continuation.yield(.status(iteration == 1 ? "thinking" : "processing"))
            let budget = NativeContextBudget.snapshot(messages: messages, contextWindow: request.contextWindow)
            continuation.yield(.contextBudget(used: budget.used, total: budget.total, level: budget.level ?? .normal))
            if let compaction = NativeContextBudget.compactIfNeeded(messages: messages, contextWindow: request.contextWindow) {
                continuation.yield(.compactStarted(trigger: compaction.trigger, preTokens: compaction.preTokens))
                let compactItem = await turnController.recordStatus("context compacting", text: compaction.trigger)
                continuation.yield(.turnItemStarted(compactItem))
                continuation.yield(.status("context compacting"))
                messages = compaction.messages
                continuation.yield(.compactCompleted(status: compaction.status, preTokens: compaction.preTokens, postTokens: compaction.postTokens))
                continuation.yield(.contextBudget(
                    used: compaction.postTokens,
                    total: request.contextWindow,
                    level: NativeContextBudget.snapshot(messages: messages, contextWindow: request.contextWindow).level ?? .normal
                ))
            }

            let turn: ModelTurn
            do {
                turn = try await performOpenAIChatTurnWithRetry(
                    request: request,
                    messages: messages,
                    continuation: continuation,
                    runMode: context.runMode
                )
            } catch {
                if case ProviderClientError.streamInterruptedAfterPartialOutput(let message) = error,
                   context.partialStreamRecoveryCount < 2 {
                    context.partialStreamRecoveryCount += 1
                    messages.append([
                        "role": "user",
                        "content": """
                        The provider response stream disconnected after partial visible output: \(message)
                        Continue the same task from the latest completed tool result. Do not repeat already completed tool calls unless needed for verification.
                        """,
                    ])
                    let recoveryItem = await turnController.recordStatus("waiting for model response", text: "partial_stream_timeout_recovery")
                    continuation.yield(.turnItemStarted(recoveryItem))
                    continuation.yield(.status("waiting for model response"))
                    continue
                }
                if !didRecoverContextOverflow, isPromptTooLongError(error) {
                    didRecoverContextOverflow = true
                    let recovery = NativeContextBudget.forceRecover(messages: messages, contextWindow: request.contextWindow)
                    continuation.yield(.compactStarted(trigger: recovery.trigger, preTokens: recovery.preTokens))
                    messages = recovery.messages
                    continuation.yield(.compactCompleted(status: recovery.status, preTokens: recovery.preTokens, postTokens: recovery.postTokens))
                    continuation.yield(.contextBudget(used: recovery.postTokens, total: request.contextWindow, level: .recovering))
                    let recoveryItem = await turnController.recordStatus("context recovering", text: "prompt_too_long")
                    continuation.yield(.turnItemStarted(recoveryItem))
                    continuation.yield(.status("context recovering"))
                    continue
                }
                throw error
            }
            context.partialStreamRecoveryCount = 0
            var rawToolCalls = turn.toolCalls
            if rawToolCalls.isEmpty {
                rawToolCalls = fallbackToolCalls(in: turn.assistantContent)
            }
            rawToolCalls = rawToolCalls.map(canonicalToolCall)
            var planPlainTextIntroOverride: String?
            if rawToolCalls.isEmpty,
               context.runMode == .plan,
               !context.planExited,
               let recovery = PlanTurnRecoveryClassifier.recovery(for: turn.assistantContent, context: context) {
                switch recovery {
                case .askQuestion(let call):
                    context.planPlainTextRecoveryCount += 1
                    context.planQuestionRecoveryCount += 1
                    context.planWorkflowStage = .waitingForAnswer
                    rawToolCalls = [call]
                    let recoveryItem = await turnController.recordStatus(PlanWorkflowPresentation.recoveringStatus)
                    continuation.yield(.turnItemStarted(recoveryItem))
                    continuation.yield(.status(PlanWorkflowPresentation.recoveringStatus))
                case .switchMode(let call):
                    context.planPlainTextRecoveryCount += 1
                    context.planGenerationRecoveryCount += 1
                    context.planWorkflowStage = .waitingForConfirmation
                    rawToolCalls = [call]
                    let recoveryItem = await turnController.recordStatus(PlanWorkflowPresentation.recoveringStatus)
                    continuation.yield(.turnItemStarted(recoveryItem))
                    continuation.yield(.status(PlanWorkflowPresentation.recoveringStatus))
                case .intro(let intro):
                    if context.planQuestionAnswered, context.planGenerationRecoveryCount > 0 {
                        context.planPlainTextRecoveryCount += 1
                        context.planGenerationRecoveryCount += 1
                        context.planWorkflowStage = .waitingForConfirmation
                        rawToolCalls = [PlanTurnRecoveryClassifier.fallbackSwitchModeCall(
                            from: turn.assistantContent,
                            userPrompt: request.prompt
                        )]
                        let recoveryItem = await turnController.recordStatus(PlanWorkflowPresentation.recoveringStatus)
                        continuation.yield(.turnItemStarted(recoveryItem))
                        continuation.yield(.status(PlanWorkflowPresentation.recoveringStatus))
                    } else if !context.planQuestionAnswered, context.planQuestionRecoveryCount > 0 {
                        context.planPlainTextRecoveryCount += 1
                        context.planQuestionRecoveryCount += 1
                        context.planWorkflowStage = .waitingForAnswer
                        rawToolCalls = [PlanTurnRecoveryClassifier.fallbackAskQuestionCall(from: turn.assistantContent + "\n" + request.prompt)]
                        let recoveryItem = await turnController.recordStatus(PlanWorkflowPresentation.recoveringStatus)
                        continuation.yield(.turnItemStarted(recoveryItem))
                        continuation.yield(.status(PlanWorkflowPresentation.recoveringStatus))
                    } else {
                        context.planPlainTextRecoveryCount += 1
                        if context.planQuestionAnswered {
                            context.planGenerationRecoveryCount += 1
                            context.planWorkflowStage = .answeredGeneratingPlan
                        } else {
                            context.planQuestionRecoveryCount += 1
                            context.planWorkflowStage = .needsQuestion
                        }
                        planPlainTextIntroOverride = intro
                    }
                }
            }
            let interactiveContent = InteractivePlanContentDeferrer.prepare(
                assistantContent: turn.assistantContent,
                toolCalls: rawToolCalls,
                runMode: context.runMode
            )
            rawToolCalls = interactiveContent.toolCalls
            if let planStatus = PlanWorkflowPresentation.generationStatus(for: rawToolCalls, runMode: context.runMode) {
                let planStatusItem = await turnController.recordStatus(planStatus)
                continuation.yield(.turnItemStarted(planStatusItem))
                continuation.yield(.status(planStatus))
            }
            let visibleAssistantText = visibleAssistantTextForTurn(
                assistantContent: turn.assistantContent,
                toolCalls: rawToolCalls,
                interactiveContent: interactiveContent,
                runMode: context.runMode
            )
            let assistantTextForDisplay = planPlainTextIntroOverride ?? visibleAssistantText
            if let planPlainTextIntroOverride {
                continuation.yield(.contentDelta(planPlainTextIntroOverride))
            }
            if let assistantItem = await turnController.recordAssistantText(assistantTextForDisplay) {
                continuation.yield(.turnItemCompleted(assistantItem))
            }
            let normalizedInvocations = ToolArgumentNormalizer.normalize(rawToolCalls)
            var toolInvocations = normalizedInvocations.compactMap { context.deduplicatedInvocation($0) }
            if !normalizedInvocations.isEmpty, toolInvocations.isEmpty {
                switch loopWatchdog.recordDuplicateOnlyTurn() {
                case .continueWithNudge(let nudge):
                    appendAssistantContentIfNeeded(turn.assistantContent, to: &messages)
                    messages.append([
                        "role": "user",
                        "content": nudge,
                    ])
                    let nudgeItem = await turnController.recordStatus("continuing")
                    continuation.yield(.turnItemStarted(nudgeItem))
                    continuation.yield(.status("continuing"))
                    continue
                case .pauseNeedsUser:
                    let pauseItem = await turnController.recordStatus("needs continuation")
                    continuation.yield(.turnItemStarted(pauseItem))
                    continuation.yield(.status("needs continuation"))
                    return
                }
            } else if !toolInvocations.isEmpty {
                loopWatchdog.recordProgress()
            }
            if toolInvocations.isEmpty,
               context.runMode != .plan,
               !didForceWorkspaceBootstrap,
               shouldForceWorkspaceBootstrap(request: request, context: context, assistantContent: turn.assistantContent) {
                didForceWorkspaceBootstrap = true
                let call = forcedWorkspaceBootstrapToolCall()
                let invocation = ToolArgumentNormalizer.normalize(call)
                if context.markToolCallIfNeeded(invocation.call) {
                    let exploreItem = await turnController.recordStatus("exploring workspace")
                    continuation.yield(.turnItemStarted(exploreItem))
                    continuation.yield(.status("exploring workspace"))
                    toolInvocations = [invocation]
                }
            }

            if toolInvocations.isEmpty {
                if let nudge = continuationNudge(request: request, context: context, assistantContent: turn.assistantContent) {
                    appendAssistantContentIfNeeded(turn.assistantContent, to: &messages)
                    messages.append([
                        "role": "user",
                        "content": nudge,
                    ])
                    context.continuationNudgeCount += 1
                    let nudgeItem = await turnController.recordStatus("continuing")
                    continuation.yield(.turnItemStarted(nudgeItem))
                    continuation.yield(.status("continuing"))
                    continue
                }
                if context.runMode == .plan, !context.planExited {
                    let recoveryCall = context.planQuestionAnswered
                        ? PlanTurnRecoveryClassifier.fallbackSwitchModeCall(from: turn.assistantContent, userPrompt: request.prompt)
                        : PlanTurnRecoveryClassifier.fallbackAskQuestionCall(from: turn.assistantContent.isEmpty ? request.prompt : turn.assistantContent)
                    let invocation = ToolArgumentNormalizer.normalize(recoveryCall)
                    if context.markToolCallIfNeeded(invocation.call) {
                        context.planPlainTextRecoveryCount += 1
                        if context.planQuestionAnswered {
                            context.planGenerationRecoveryCount += 1
                            context.planWorkflowStage = .waitingForConfirmation
                        } else {
                            context.planQuestionRecoveryCount += 1
                            context.planWorkflowStage = .waitingForAnswer
                        }
                        let recoveryItem = await turnController.recordStatus(PlanWorkflowPresentation.recoveringStatus)
                        continuation.yield(.turnItemStarted(recoveryItem))
                        continuation.yield(.status(PlanWorkflowPresentation.recoveringStatus))
                        toolInvocations = [invocation]
                    } else {
                        let recoveryItem = await turnController.recordStatus(PlanWorkflowPresentation.recoveryNeededStatus)
                        continuation.yield(.turnItemStarted(recoveryItem))
                        continuation.yield(.status(PlanWorkflowPresentation.recoveryNeededStatus))
                        return
                    }
                }
            }

            if toolInvocations.isEmpty {
                switch CompletionGate.decision(request: request, context: context, assistantContent: turn.assistantContent) {
                case .complete:
                    return
                case .continueWithNudge(let nudge):
                    appendAssistantContentIfNeeded(turn.assistantContent, to: &messages)
                    messages.append([
                        "role": "user",
                        "content": nudge,
                    ])
                    context.continuationNudgeCount += 1
                    let nudgeItem = await turnController.recordStatus("continuing")
                    continuation.yield(.turnItemStarted(nudgeItem))
                    continuation.yield(.status("continuing"))
                    continue
                case .pauseNeedsUser:
                    let pauseItem = await turnController.recordStatus("needs continuation")
                    continuation.yield(.turnItemStarted(pauseItem))
                    continuation.yield(.status("needs continuation"))
                    return
                case .realError(let message):
                    throw ProviderClientError.transport(message)
                }
            }
            let assistantToolContent = isHiddenToolProtocol(turn.assistantContent) ? "" : turn.assistantContent
            let toolCalls = toolInvocations.map(\.call)
            messages.append(openAIAssistantToolMessage(content: assistantToolContent, toolCalls: toolCalls))

            for invocation in toolInvocations {
                let call = invocation.call
                if Task.isCancelled { throw CancellationError() }
                let runningItem = await turnController.recordStatus(invocation.recoveryResult == nil ? "running \(call.name)" : "recovering \(call.name)")
                continuation.yield(.turnItemStarted(runningItem))
                continuation.yield(.status(invocation.recoveryResult == nil ? "running \(call.name)" : "recovering \(call.name)"))
                let toolItem = await turnController.recordToolCall(call)
                continuation.yield(.turnItemStarted(toolItem))
                continuation.yield(.toolUse(id: call.id, name: call.name, inputJSON: call.inputJSON))
                if AgentToolNameCanonicalizer.canonical(call.name) == "Task" {
                    continuation.yield(.subagentStatus(id: call.id, status: "running", detail: call.inputJSON))
                }
                let result: AgentToolResult
                if let recoveryResult = invocation.recoveryResult {
                    result = recoveryResult
                } else {
                    result = await executeToolWithPolicy(
                        call: call,
                        context: context,
                        request: request,
                        continuation: continuation
                    )
                }
                let recorded = await turnController.recordToolResult(result)
                if let callItem = recorded.callItem {
                    continuation.yield(.turnItemUpdated(callItem))
                }
                continuation.yield(.turnItemCompleted(recorded.resultItem))
                continuation.yield(.toolResult(id: call.id, output: result.output, isError: result.isError))
                context.recordToolResult(result, call: call)
                if let watchdogMessage = loopWatchdog.recordToolResult(result) {
                    throw ProviderClientError.transport(watchdogMessage)
                }
                if result.toolName == "Task" {
                    continuation.yield(.subagentStatus(id: call.id, status: result.isError ? "failed" : "completed", detail: result.output))
                }
                let didApprovePlanExecution = !result.isError && result.toolName == "SwitchMode" && context.runMode == .agent && context.planExited
                if didApprovePlanExecution {
                    await turnController.markPlanExited()
                    let executeItem = await turnController.recordStatus("executing plan")
                    continuation.yield(.turnItemStarted(executeItem))
                    continuation.yield(.status("executing plan"))
                }
                messages.append(openAIToolResultMessage(result))
                if didApprovePlanExecution {
                    messages.append([
                        "role": "user",
                        "content": "The plan was approved. Continue executing it now in agent mode. Before the first workspace-changing tool, call TodoWrite with the concrete execution checklist. After each write/edit/delete/non-read-only tool, refresh TodoWrite before the next workspace-changing tool. Use concrete file/search/shell tools and do not stop after restating the plan.",
                    ])
                    context.continuationNudgeCount += 1
                }
            }
        }

        throw CancellationError()
    }

    private static func visibleAssistantTextForTurn(
        assistantContent: String,
        toolCalls: [AgentToolCall],
        interactiveContent: InteractivePlanContentDeferrer.Result,
        runMode: ChatRunMode
    ) -> String {
        if runMode == .plan {
            if interactiveContent.suppressVisibleAssistantText {
                return interactiveContent.visibleIntro ?? ""
            }
            guard !toolCalls.isEmpty else { return "" }
            let canonicalNames = toolCalls.map { AgentToolNameCanonicalizer.canonical($0.name) }
            if canonicalNames.contains("AskQuestion") || canonicalNames.contains("SwitchMode") {
                return ""
            }
            return assistantContent.nilIfBlank ?? PlanModeIntroSynthesizer.intro(for: toolCalls, runMode: runMode) ?? ""
        }
        if interactiveContent.suppressVisibleAssistantText {
            return interactiveContent.visibleIntro ?? ""
        }
        return assistantContent.nilIfBlank ?? ""
    }

    private static func performOpenAIChatTurnWithRetry(
        request: AgentRequest,
        messages: [[String: Any]],
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation,
        runMode: ChatRunMode,
        policy: ProviderRetryPolicy = .codexDefault
    ) async throws -> ModelTurn {
        var failedAttempts = 0
        while true {
            do {
                return try await performOpenAIChatTurn(
                    request: request,
                    messages: messages,
                    continuation: continuation,
                    runMode: runMode
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let decision = retryDecision(for: error, failedAttempts: failedAttempts, policy: policy)
                guard decision.shouldRetry else {
                    if isRetryableProviderError(error, policy: policy) != nil, failedAttempts >= policy.streamMaxRetries {
                        throw ProviderClientError.transport(
                            "Provider request failed after \(failedAttempts + 1) attempts: \(error.localizedDescription)"
                        )
                    }
                    throw error
                }

                failedAttempts += 1
                continuation.yield(.status("Reconnecting... \(failedAttempts)/\(policy.streamMaxRetries)"))
                AppLog.write("provider retry \(failedAttempts)/\(policy.streamMaxRetries): \(decision.reason)")
                try await sleepForRetryDelay(decision.delay)
            }
        }
    }

    private static func performOpenAIChatTurn(
        request: AgentRequest,
        messages: [[String: Any]],
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation,
        runMode: ChatRunMode
    ) async throws -> ModelTurn {
        let endpoint = try endpointURL(baseURL: request.providerConfig.baseURL, suffix: "chat/completions")
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = modelStreamTimeoutInterval(from: request.timeoutMs)
        try applyHeaders(to: &urlRequest, request: request)
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": request.providerConfig.model,
            "messages": messages,
            "stream": true,
            "stream_options": [
                "include_usage": true,
            ],
            "tools": NativeToolRouter.openAITools(configValues: request.nativeConfigValues),
            "tool_choice": "auto",
        ])

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
        } catch {
            throw mapTransportError(error)
        }
        guard let statusCode = (response as? HTTPURLResponse)?.statusCode else {
            throw ProviderClientError.invalidResponse
        }
        guard 200..<300 ~= statusCode else {
            let body = try await readErrorBody(from: bytes)
            throw ProviderClientError.httpError(statusCode: statusCode, body: body)
        }

        var content = ""
        var heldContent = ""
        var shouldStreamContent = false
        var didYieldVisibleContent = false
        var accumulators: [Int: OpenAIToolCallAccumulator] = [:]
        continuation.yield(.status("streaming"))

        do {
            for try await line in bytes.lines {
                if Task.isCancelled { throw CancellationError() }
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
                if payload == "[DONE]" { break }
                guard let data = payload.data(using: .utf8),
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    continue
                }
                if let choices = object["choices"] as? [[String: Any]],
                   let delta = choices.first?["delta"] as? [String: Any],
                   let rawCalls = delta["tool_calls"] as? [[String: Any]] {
                    for rawCall in rawCalls {
                        let index = rawCall["index"] as? Int ?? 0
                        var accumulator = accumulators[index] ?? OpenAIToolCallAccumulator(index: index)
                        accumulator.apply(delta: rawCall)
                        accumulators[index] = accumulator
                    }
                }
                for event in openAIChatEvents(from: object, contextWindow: request.contextWindow) {
                    if case .contentDelta(let delta) = event {
                        content += delta
                        if shouldStreamContent {
                            continuation.yield(event)
                            didYieldVisibleContent = true
                        } else {
                            heldContent += delta
                            let sample = heldContent.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !sample.isEmpty,
                               !looksLikeProtocolPrefix(sample),
                               !InteractivePlanContentDeferrer.shouldHoldStreamingContent(
                                   sample,
                                   runMode: runMode,
                                   hasToolCallAccumulator: !accumulators.isEmpty
                               ) {
                                shouldStreamContent = true
                                continuation.yield(.contentDelta(heldContent))
                                didYieldVisibleContent = true
                                heldContent = ""
                            }
                        }
                    } else {
                        continuation.yield(event)
                    }
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let mapped = mapTransportError(error)
            if didYieldVisibleContent {
                throw ProviderClientError.streamInterruptedAfterPartialOutput(mapped.localizedDescription)
            }
            throw mapped
        }

        let calls = accumulators.keys.sorted().compactMap { accumulators[$0]?.toolCall }
        let interactiveContent = InteractivePlanContentDeferrer.prepare(
            assistantContent: content,
            toolCalls: calls,
            runMode: runMode
        )
        if !didYieldVisibleContent, !heldContent.isEmpty, !isHiddenToolProtocol(content) {
            let visibleContent = visibleAssistantTextForTurn(
                assistantContent: content,
                toolCalls: calls,
                interactiveContent: interactiveContent,
                runMode: runMode
            )
            if !visibleContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continuation.yield(.contentDelta(visibleContent))
            }
        }

        return ModelTurn(assistantContent: content, toolCalls: calls)
    }

    static func endpointURL(baseURL: String, suffix: String) throws -> URL {
        let trimmed = baseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedSuffix = suffix
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let value: String
        if trimmed.hasSuffix("/\(normalizedSuffix)") || trimmed.hasSuffix(normalizedSuffix) {
            value = trimmed
        } else {
            value = "\(trimmed)/\(normalizedSuffix)"
        }
        guard let url = URL(string: value), let scheme = url.scheme, !scheme.isEmpty else {
            throw ProviderClientError.invalidURL(baseURL)
        }
        return url
    }

    static func openAIChatEvents(from object: [String: Any], contextWindow: Int) -> [AgentEvent] {
        var events: [AgentEvent] = []
        if let choices = object["choices"] as? [[String: Any]],
           let delta = choices.first?["delta"] as? [String: Any] {
            for reasoning in reasoningDeltas(from: delta) {
                events.append(.reasoningDelta(reasoning))
            }
            if let content = delta["content"] as? String, !content.isEmpty {
                events.append(.contentDelta(content))
            }
        }
        if let usage = object["usage"] as? [String: Any],
           let budget = tokenBudget(from: usage, contextWindow: contextWindow) {
            events.append(.tokenBudget(used: budget.used, total: budget.total))
        }
        return events
    }

    private static func reasoningDeltas(from delta: [String: Any]) -> [String] {
        var values: [String] = []
        for key in ["reasoning_content", "reasoning", "thinking", "redacted_thinking", "reasoning_summary"] {
            appendReasoningText(delta[key], to: &values)
        }
        return values
    }

    private static func appendReasoningText(_ value: Any?, to values: inout [String]) {
        if let text = value as? String {
            appendReasoningText(text, to: &values)
            return
        }
        guard let object = value as? [String: Any] else { return }
        for key in ["content", "thinking", "text", "reasoning", "summary"] {
            appendReasoningText(object[key], to: &values)
        }
    }

    private static func appendReasoningText(_ text: String?, to values: inout [String]) {
        guard let text, !text.isEmpty else { return }
        values.append(text)
    }

    static func runSubagent(inputJSON: String, context: AgentRunContext) async throws -> String {
        let input = try AgentToolExecutor.inputObject(from: inputJSON)
        let prompt = try AgentToolExecutor.requiredString("prompt", input: input)
        let description = (input["description"] as? String).nilIfBlank ?? "Subagent"
        let extraContext = (input["context"] as? String).nilIfBlank ?? ""
        let routeTier = RoutingService.classifyTier(prompt: prompt, runMode: context.runMode)
        let routeSignals = NativeRouterRuntime.requestSignals(
            prompt: prompt,
            priorMessages: [],
            attachments: [],
            isBackgroundRequest: true,
            tools: []
        )
        let route = NativeRouterRuntime.resolvedProviderRoute(
            forTier: routeTier,
            values: context.nativeConfigValues,
            fallbackProviderConfig: context.providerConfig,
            fallbackAPIKey: context.apiKey,
            fallbackContextWindow: context.contextWindow,
            signals: routeSignals
        )
        let providerConfig = route.providerConfig

        let endpoint = try endpointURL(baseURL: providerConfig.baseURL, suffix: "chat/completions")
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = modelStreamTimeoutInterval(from: context.timeoutMs)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let apiKey = route.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw ProviderClientError.missingAPIKey
        }
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        for (key, value) in providerConfig.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        let content = """
        Workspace: \(context.workspacePath)
        Description: \(description)

        \(extraContext)

        Subtask:
        \(prompt)
        """
        let body: [String: Any] = [
            "model": providerConfig.model,
            "messages": [
                [
                    "role": "system",
                    "content": "You are a focused read-only subagent. Answer the delegated subtask concisely. Do not claim to edit files, run shell commands, or call tools.",
                ],
                [
                    "role": "user",
                    "content": content,
                ],
            ],
            "stream": false,
        ]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch {
            throw mapTransportError(error)
        }
        guard let statusCode = (response as? HTTPURLResponse)?.statusCode else {
            throw ProviderClientError.invalidResponse
        }
        guard 200..<300 ~= statusCode else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ProviderClientError.httpError(statusCode: statusCode, body: body)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let answer = message["content"] as? String,
              !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderClientError.invalidResponse
        }
        return jsonString(
            [
                "description": description,
                "prompt": prompt,
                "result": answer.trimmingCharacters(in: .whitespacesAndNewlines),
            ],
            pretty: true
        )
    }

    static func fallbackToolCalls(in text: String) -> [AgentToolCall] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if let json = wholeFencedJSONEnvelope(in: trimmed) {
            return jsonFallbackToolCalls(in: json)
        }
        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
            return jsonFallbackToolCalls(in: trimmed)
        }
        if let responseJSON = wholeXMLEnvelope(named: "response", in: trimmed) {
            return jsonFallbackToolCalls(in: responseJSON)
        }
        let invokeCalls = xmlInvokeFallbackToolCalls(in: trimmed)
        if !invokeCalls.isEmpty {
            return invokeCalls
        }
        let inlineJSONCalls = inlineJSONFallbackToolCalls(in: trimmed)
        if !inlineJSONCalls.isEmpty {
            return inlineJSONCalls
        }
        let compactCalls = compactXMLFallbackToolCalls(in: trimmed)
        if !compactCalls.isEmpty {
            return compactCalls
        }
        if trimmed.hasPrefix("<tool_call"), trimmed.hasSuffix("</tool_call>") {
            return xmlFallbackToolCalls(in: trimmed)
        }
        if let call = legacyCommandFallbackToolCall(in: trimmed) {
            return [call]
        }
        return []
    }

    private static func looksLikeProtocolPrefix(_ text: String) -> Bool {
        text.hasPrefix("<") || text.hasPrefix("{") || text.hasPrefix("```")
    }

    private static func isHiddenToolProtocol(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if trimmed.range(of: #"^<CALL_[A-Z_]+>"#, options: .regularExpression) != nil {
            return true
        }
        if lower.hasPrefix("<call") || lower.hasPrefix("<response") || lower.hasPrefix("<invoke") || lower.hasPrefix("<command") || lower.hasPrefix("<bash") || lower.hasPrefix("<tool") {
            return true
        }
        return !fallbackToolCalls(in: trimmed).isEmpty
    }

    private static func openAIInitialMessages(request: AgentRequest) -> [[String: Any]] {
        var messages: [[String: Any]] = [
            [
                "role": "system",
                "content": nativeAgentSystemPrompt(request: request),
            ],
        ]
        for message in request.priorMessages {
            guard let converted = openAIMessage(message) else { continue }
            messages.append(converted)
        }
        messages.append(openAIUserMessage(prompt: request.prompt, attachments: request.attachments))
        return messages
    }

    private static func nativeAgentSystemPrompt(request: AgentRequest) -> String {
        let toolNames = AgentToolRegistry.visibleToolNames(configValues: request.nativeConfigValues).joined(separator: ", ")
        let searchInstruction = nativeAgentSearchInstruction()
        let modeText = request.runMode == .plan
            ? """
            You are in plan mode. The user does not want implementation yet.
            Only read/search/todo/question tools are allowed before approval. Do not edit files or run mutating shell commands until SwitchMode is called with mode="agent" and a concrete plan, and the user approves it.
            A plan-mode turn must end only by calling AskQuestion to gather user input or SwitchMode mode="agent" with the final plan. Do not ask questions, request approval, or present the final plan as ordinary prose.
            Ask the user at least one blocking question with AskQuestion before requesting execution. AskQuestion must use the questions array shape. Include concrete options when useful, with no fixed minimum or maximum; do not include an "Other" option because the UI adds it automatically.
            """
            : "You are in agent mode. Use tools to inspect and modify the workspace."
        return """
        You are PilotDeck, a native macOS coding agent with a PilotDeck style workflow.
        Workspace root: \(request.projectPath)
        \(modeText)

        Use the provided tools for all file reads, file writes, edits, searches, todos, and shell commands.
        Never claim that you created, edited, deleted, or inspected a file unless the corresponding tool result confirms it.
        Prefer small, verifiable steps: inspect files, make precise edits, run focused checks, then summarize.
        Prefer targeted Read/Grep/Glob once paths are known. Use root Glob **/* only for the first workspace discovery; do not repeat full-workspace glob after you already have a file list.
        Prefer the canonical tool names: \(toolNames).
        For shell commands, use Shell only when needed and keep commands scoped to the workspace. Use run_in_background plus Await for long-running commands.
        \(searchInstruction)
        \(nativeAgentSkillContext(workspacePath: request.projectPath))
        Use Task for delegated analysis or shell-focused background work.
        If OpenAI tool calling is unavailable, emit exactly one raw JSON fallback tool request and no other prose in that assistant turn.
        Example: {"tool":"Read","input":{"file_path":"README.md"}}
        Do not emit markdown fences, language labels such as "bash" or "json", or a prose explanation when requesting a tool.
        """
    }

    private static func nativeAgentSearchInstruction() -> String {
        return "For current public information, weather, recent documentation, or URL-backed evidence, call WebSearch with a focused query."
    }

    static func nativeAgentSkillContext(workspacePath: String) -> String {
        let skills = SkillRuntimeService.availableSkills(workspacePath: workspacePath)
        let skillLines: String
        if skills.isEmpty {
            skillLines = "- No project or user skills are installed for this workspace."
        } else {
            skillLines = skills.map { skill in
                let summary = skill.summary
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let clipped = summary.count > 220 ? String(summary.prefix(220)) + "..." : summary
                return "- \(skill.name) (\(skill.scope)): \(clipped)"
            }.joined(separator: "\n")
        }
        return """
        Available skills for this workspace:
        \(skillLines)
        To use one, call Skill with the exact skill name above. Skill loads instructions; it does not execute subcommands. After loading a skill, follow its returned instructions using Shell/Read/other tools. If the skill refers to relative paths such as scripts/foo, run them from the returned skillDir or use absolute paths. Do not invent sub-skill names like skill:action unless that exact skill name is listed.
        """
    }

    static func shouldForceWorkspaceBootstrap(request: AgentRequest, context: AgentRunContext, assistantContent: String) -> Bool {
        guard context.toolExecutionCount == 0,
              context.exploratoryToolCount == 0,
              context.mutatingToolCount == 0 else {
            return false
        }
        let prompt = primaryUserPrompt(from: request.prompt).lowercased()
        let content = assistantContent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let workspaceVerbs = [
            "网页", "网站", "项目", "文件", "代码", "实现", "生成", "修改", "优化", "修复", "完善",
            "删除", "移除", "清空",
            "create", "build", "edit", "modify", "fix", "optimize", "implement", "file", "website", "page", "code",
            "delete", "remove",
        ]
        guard workspaceVerbs.contains(where: { prompt.contains($0) }) else { return false }
        if content.contains("```") || content == "bash" || content == "json" {
            return true
        }
        let finalOnlyPhrases = ["cannot", "无法", "不能", "不支持", "没有权限"]
        return !finalOnlyPhrases.contains { content.contains($0) }
    }

    static func continuationNudge(request: AgentRequest, context: AgentRunContext, assistantContent: String) -> String? {
        guard context.continuationNudgeCount < ContinuationPolicy.maxNudges else { return nil }
        guard context.recoverableProtocolErrorCount < ContinuationPolicy.maxRecoverableProtocolErrors else { return nil }
        let content = assistantContent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let prompt = primaryUserPrompt(from: request.prompt).lowercased()
        if request.runMode == .plan, !context.planExited {
            if !context.planQuestionAnswered {
                return """
                Continue the planning turn. Ask the user blocking questions with AskQuestion before requesting execution. Include concrete options when useful, with no fixed minimum or maximum; the UI will add Other automatically. Do not call SwitchMode mode="agent" until the user answers.
                """
            }
            return """
            Continue the planning turn with the user's answers. You may use read-only exploration tools if needed. If the plan is concrete enough to execute, call SwitchMode with mode="agent" and a complete plan so the user can approve implementation. Do not stop after ordinary prose only.
            """
        }
        guard isWorkspaceMutationRequest(prompt) else { return nil }
        let refusalPhrases = ["cannot", "can't", "unable", "无法", "不能", "没有权限", "不支持"]
        if refusalPhrases.contains(where: { content.contains($0) }) {
            return nil
        }
        if context.mutatingToolCount == 0 {
            return """
            Continue the workspace task. You have not completed the requested change yet.
            Use the available tools for the next concrete step. Inspect files if needed, then edit or write files before giving a final summary.
            Do not stop after describing the plan or after a single search result.
            """
        }
        if context.lastToolResultWasError {
            return """
            Continue debugging the failed tool step. Use another safe tool call or explain the concrete blocker only if no tool can make progress.
            """
        }
        if context.mutatingToolCount > 0,
           requiresPostMutationVerification(prompt),
           context.verificationAfterMutationCount == 0 {
            return """
            Continue the workspace task. You have changed files, but have not verified or read back the result yet.
            Run a focused read/search/check command, then continue with any remaining edits before giving the final summary.
            """
        }
        if context.hasIncompleteTodos {
            return """
            Continue the workspace task. The todo list still has unfinished items.
            Complete the current todo item, update TodoWrite when progress changes, and do not give the final summary until every required todo is completed or explicitly canceled.
            """
        }
        if context.mutatingToolCount > 0, looksLikeOngoingWorkspaceWork(content) {
            return """
            Continue the implementation. You have started changing the workspace, but the last assistant message still describes in-progress work.
            Keep using concrete file/search/shell tools until the requested task is actually complete, then give a concise final summary.
            """
        }
        return nil
    }

    static func looksLikeOngoingWorkspaceWork(_ content: String) -> Bool {
        let value = content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return true }
        let completionMarkers = [
            "已完成", "完成了", "优化完成", "创建完成", "修复完成", "实现完成", "总结", "下面是最终", "以下是最终",
            "done", "completed", "complete.", "finished", "final summary", "here is the final", "all set",
        ]
        if completionMarkers.contains(where: { value.contains($0) }) {
            return false
        }
        let inProgressMarkers = [
            "let me", "i'll", "i will", "now let", "next", "continue", "start implementing", "apply", "verify", "check",
            "我将", "我会", "我来", "让我", "现在", "接下来", "下一步", "继续", "开始执行", "开始修改", "先", "然后",
        ]
        return inProgressMarkers.contains { value.contains($0) }
    }

    static func requiresPostMutationVerification(_ prompt: String) -> Bool {
        let prompt = primaryUserPrompt(from: prompt).lowercased()
        let verificationVerbs = [
            "优化", "修复", "完善", "调整", "重构", "检查", "验证", "继续", "删除", "移除", "清空",
            "optimize", "fix", "improve", "refactor", "verify", "check", "continue", "delete", "remove",
        ]
        return verificationVerbs.contains { prompt.contains($0) }
    }

    static func isWorkspaceMutationRequest(_ prompt: String) -> Bool {
        let prompt = primaryUserPrompt(from: prompt).lowercased()
        let mutationVerbs = [
            "创建", "新建", "生成", "做一个", "帮我做", "修改", "优化", "修复", "完善", "实现", "重写", "调整", "编辑", "保存", "删除", "移除", "清空",
            "create", "build", "generate", "make", "write", "edit", "modify", "fix", "optimize", "implement", "rewrite", "update", "improve", "save", "delete", "remove",
        ]
        return mutationVerbs.contains { prompt.contains($0) }
    }

    static func primaryUserPrompt(from prompt: String) -> String {
        var primary = prompt
        while let start = primary.range(of: "<memory-context>"),
              let end = primary.range(of: "</memory-context>", range: start.upperBound..<primary.endIndex) {
            primary.removeSubrange(start.lowerBound..<end.upperBound)
            primary = primary.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let separators = [
            "\n\nRelevant PilotDeck memory context:",
            "\n\nRelevant G9Claw memory context:",
            "\n\nAttached files:",
            "\n\n附件:",
        ]
        for separator in separators {
            if let range = primary.range(of: separator) {
                primary = String(primary[..<range.lowerBound])
            }
        }
        return primary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func appendAssistantContentIfNeeded(_ content: String, to messages: inout [[String: Any]]) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isHiddenToolProtocol(trimmed) else { return }
        messages.append([
            "role": "assistant",
            "content": trimmed,
        ])
    }

    private static func canonicalToolCall(_ call: AgentToolCall) -> AgentToolCall {
        let canonicalName = AgentToolNameCanonicalizer.canonical(call.name)
        return AgentToolCall(id: call.id, name: canonicalName, inputJSON: call.inputJSON)
    }

    private static func forcedWorkspaceBootstrapToolCall() -> AgentToolCall {
        AgentToolCall(
            id: "native-bootstrap-\(UUID().uuidString)",
            name: "Glob",
            inputJSON: jsonString([
                "pattern": "**/*",
                "path": ".",
            ])
        )
    }

    private static func openAIMessage(_ message: ChatMessage) -> [String: Any]? {
        let content = message.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }
        switch message.role {
        case .user:
            return ["role": "user", "content": content]
        case .assistant:
            return ["role": "assistant", "content": content]
        case .system:
            return ["role": "system", "content": content]
        case .tool:
            return nil
        }
    }

    private static func openAIUserMessage(prompt: String, attachments: [FileAttachment]) -> [String: Any] {
        guard !attachments.isEmpty else {
            return ["role": "user", "content": prompt]
        }

        let attachmentParts = NativeAttachmentResolver.openAIContentParts(for: attachments).0
        guard !attachmentParts.isEmpty else {
            return ["role": "user", "content": prompt]
        }

        var content: [[String: Any]] = []
        if !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content.append([
                "type": "text",
                "text": prompt,
            ])
        }
        content.append(contentsOf: attachmentParts)
        return ["role": "user", "content": content]
    }

    private static func openAIAssistantToolMessage(content: String, toolCalls: [AgentToolCall]) -> [String: Any] {
        [
            "role": "assistant",
            "content": content.isEmpty ? NSNull() : content,
            "tool_calls": toolCalls.map { call in
                [
                    "id": call.id,
                    "type": "function",
                    "function": [
                        "name": call.name,
                        "arguments": ToolArgumentNormalizer.providerSafeInputJSON(call.inputJSON),
                    ],
                ]
            },
        ]
    }

    private static func openAIToolResultMessage(_ result: AgentToolResult) -> [String: Any] {
        [
            "role": "tool",
            "tool_call_id": result.callId,
            "content": result.output,
        ]
    }

    private static func executeToolWithPolicy(
        call: AgentToolCall,
        context: AgentRunContext,
        request: AgentRequest,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async -> AgentToolResult {
        if let todoBlock = PlanTodoExecutionGate.blockingResult(for: call, context: context) {
            return todoBlock
        }
        let requestKind = permissionKind(for: call)
        let interactivePayload = requestKind == .askUserQuestion
            ? AgentInteractivePayload.askUserQuestion(from: call.inputJSON)
            : nil
        let permissionInputJSON = requestKind == .destructivePlanApproval
            ? DestructiveToolClassifier.planJSON(call: call)
            : call.inputJSON
        let policy = NativeToolRouter.permissionPolicy(for: call, context: context)
        switch policy {
        case .allow:
            break
        case .block(let reason):
            return AgentToolResult(
                callId: call.id,
                toolName: call.name,
                output: reason,
                isError: false,
                isPolicyBlock: true
            )
        case .deny(let reason):
            return AgentToolResult(callId: call.id, toolName: call.name, output: reason, isError: true)
        case .ask(let reason):
            let permission = AgentPermissionRequest(
                id: UUID(),
                sessionId: context.sessionId,
                toolName: call.name,
                inputJSON: permissionInputJSON,
                reason: reason,
                scope: .session,
                kind: requestKind,
                interactivePayload: interactivePayload
            )
            continuation.yield(.permissionRequest(permission))
            continuation.yield(.status(PlanWorkflowPresentation.waitingStatus(for: call.name, runMode: context.runMode) ?? "waiting for permission"))
            let decision = await request.permissionHandler?(permission) ?? .deny
            switch decision {
            case .allow(_, let updatedInputJSON):
                if requestKind == .askUserQuestion {
                    return AgentToolExecutor.askUserQuestionResult(
                        call: call,
                        updatedInputJSON: updatedInputJSON ?? call.inputJSON
                    )
                }
                if let updatedInputJSON {
                    return await NativeToolRouter.execute(
                        call: AgentToolCall(id: call.id, name: call.name, inputJSON: updatedInputJSON),
                        context: context
                    )
                }
            case .deny:
                return AgentToolResult(
                    callId: call.id,
                    toolName: call.name,
                    output: "Permission denied for \(call.name).",
                    isError: true
                )
            }
        }

        return await NativeToolRouter.execute(call: call, context: context)
    }

    private static func permissionKind(for call: AgentToolCall) -> PermissionRequestKind {
        switch AgentToolNameCanonicalizer.canonical(call.name) {
        case "AskQuestion":
            return .askUserQuestion
        case "SwitchMode":
            return .exitPlanMode
        default:
            if DestructiveToolClassifier.isDestructive(call: call) {
                return .destructivePlanApproval
            }
            return .tool
        }
    }

    private static func applyHeaders(to request: inout URLRequest, request agentRequest: AgentRequest) throws {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let apiKey = agentRequest.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            throw ProviderClientError.missingAPIKey
        }
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        for (key, value) in agentRequest.providerConfig.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
    }

    private static func tokenBudget(from usage: [String: Any], contextWindow: Int) -> TokenBudget? {
        let input = usage["input_tokens"] as? Int ?? usage["prompt_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? usage["completion_tokens"] as? Int ?? 0
        let total = usage["total_tokens"] as? Int ?? input + output
        guard total > 0 else { return nil }
        let budgetTotal = max(contextWindow, total)
        return TokenBudget(used: total, total: budgetTotal, level: ContextBudgetLevel.level(used: total, total: budgetTotal))
    }

    private static func timeoutInterval(from milliseconds: Int) -> TimeInterval {
        TimeInterval(max(milliseconds, 1_000)) / 1_000.0
    }

    private static func modelStreamTimeoutInterval(from milliseconds: Int) -> TimeInterval {
        TimeInterval(max(milliseconds, 300_000)) / 1_000.0
    }

    static func isPromptTooLongError(_ error: Error) -> Bool {
        guard case ProviderClientError.httpError(let statusCode, let body) = error else {
            return false
        }
        guard statusCode == 400 || statusCode == 413 else { return false }
        let lower = body.lowercased()
        return lower.contains("prompt_too_long") ||
            lower.contains("context length") ||
            lower.contains("maximum context") ||
            lower.contains("too many tokens") ||
            lower.contains("tokens exceed")
    }

    static func retryDecision(
        for error: Error,
        failedAttempts: Int,
        policy: ProviderRetryPolicy = .codexDefault
    ) -> ProviderRetryDecision {
        guard let reason = isRetryableProviderError(error, policy: policy),
              failedAttempts < policy.streamMaxRetries else {
            return .noRetry
        }
        return ProviderRetryDecision(
            shouldRetry: true,
            delay: retryBackoffDelay(failedAttempts: failedAttempts, baseDelayMs: policy.baseDelayMs),
            reason: reason
        )
    }

    static func isRetryableProviderError(_ error: Error, policy: ProviderRetryPolicy = .codexDefault) -> String? {
        if error is CancellationError {
            return nil
        }
        if case ProviderClientError.streamInterruptedAfterPartialOutput = error {
            return nil
        }
        if let providerError = error as? ProviderClientError {
            switch providerError {
            case .httpError(let statusCode, _):
                if statusCode == 429 {
                    return policy.retry429 ? "HTTP 429 rate limit" : nil
                }
                return policy.retry5xx && (500..<600).contains(statusCode) ? "HTTP \(statusCode)" : nil
            case .transport(let message):
                let lower = message.lowercased()
                if lower.contains("app transport security") {
                    return nil
                }
                return policy.retryTransport ? "transport failure" : nil
            default:
                return nil
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorCancelled, NSURLErrorAppTransportSecurityRequiresSecureConnection:
                return nil
            default:
                return policy.retryTransport ? "network \(nsError.code)" : nil
            }
        }
        return nil
    }

    static func retryBackoffDelay(failedAttempts: Int, baseDelayMs: Int) -> TimeInterval {
        let retryNumber = max(failedAttempts + 1, 1)
        let exponent = min(retryNumber - 1, 8)
        let multiplier = pow(2.0, Double(exponent))
        let jitter = Double.random(in: 0.9...1.1)
        return (Double(max(baseDelayMs, 1)) * multiplier * jitter) / 1_000.0
    }

    private static func sleepForRetryDelay(_ delay: TimeInterval) async throws {
        let clamped = min(max(delay, 0), 30)
        let nanoseconds = UInt64(clamped * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }

    private static func readErrorBody(from bytes: URLSession.AsyncBytes) async throws -> String {
        var body = ""
        for try await line in bytes.lines {
            if !body.isEmpty { body += "\n" }
            body += line
            if body.count > 4_096 {
                return String(body.prefix(4_096)) + "..."
            }
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func mapTransportError(_ error: Error) -> Error {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorAppTransportSecurityRequiresSecureConnection {
            return ProviderClientError.transport(
                "App Transport Security blocked the HTTP provider request. Rebuild and launch the latest PilotDeck app bundle so NSAppTransportSecurity is included."
            )
        }
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return CancellationError()
        }
        if nsError.domain == NSURLErrorDomain {
            return ProviderClientError.transport("Network request failed: \(nsError.localizedDescription)")
        }
        return error
    }

    private static func wholeFencedJSONEnvelope(in text: String) -> String? {
        let pattern = #"(?s)^```(?:json)?\s*(\{.*\})\s*```$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsText = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)),
              match.numberOfRanges > 1 else {
            return nil
        }
        return nsText.substring(with: match.range(at: 1))
    }

    private static func wholeXMLEnvelope(named name: String, in text: String) -> String? {
        let pattern = #"(?is)^<\#(name)>\s*(\{.*\})\s*</\#(name)>$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsText = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)),
              match.numberOfRanges > 1 else {
            return nil
        }
        return nsText.substring(with: match.range(at: 1))
    }

    private static func jsonFallbackToolCalls(in snippet: String) -> [AgentToolCall] {
        guard let data = snippet.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return toolCalls(fromJSONObject: object)
    }

    private static func inlineJSONFallbackToolCalls(in text: String) -> [AgentToolCall] {
        guard !text.contains("```") else { return [] }
        let snippets = balancedJSONObjectSnippets(in: text)
        guard !snippets.isEmpty else { return [] }
        var seen = Set<String>()
        return snippets.flatMap(jsonFallbackToolCalls).compactMap { call in
            let signature = "\(call.name):\(call.inputJSON)"
            guard !seen.contains(signature) else { return nil }
            seen.insert(signature)
            return call
        }
    }

    private static func balancedJSONObjectSnippets(in text: String) -> [String] {
        var snippets: [String] = []
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                switch character {
                case "\"":
                    inString = true
                case "{":
                    if depth == 0 {
                        start = index
                    }
                    depth += 1
                case "}":
                    if depth > 0 {
                        depth -= 1
                        if depth == 0, let snippetStart = start {
                            snippets.append(String(text[snippetStart...index]))
                            start = nil
                        }
                    }
                default:
                    break
                }
            }
            index = text.index(after: index)
        }
        return snippets
    }

    private static func xmlFallbackToolCalls(in text: String) -> [AgentToolCall] {
        let pattern = #"(?s)<tool_call\s+name=["']([^"']+)["']\s*>(.*?)</tool_call>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsText = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).compactMap { match in
            guard match.numberOfRanges > 2 else { return nil }
            let name = nsText.substring(with: match.range(at: 1))
            let body = nsText.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            let inputJSON = body.hasPrefix("{") ? body : jsonString(["input": body])
            return AgentToolCall(id: "fallback-\(UUID().uuidString)", name: name, inputJSON: inputJSON)
        }
    }

    private static func compactXMLFallbackToolCalls(in text: String) -> [AgentToolCall] {
        let pattern = #"<call=\"([^\"]+)\":(\{[^<]*?\})\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsText = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).compactMap { match in
            guard match.numberOfRanges > 2 else { return nil }
            let rawName = nsText.substring(with: match.range(at: 1))
            let rawInput = nsText.substring(with: match.range(at: 2))
            return compactXMLToolCall(name: rawName, inputJSON: rawInput)
        }
    }

    private static func xmlInvokeFallbackToolCalls(in text: String) -> [AgentToolCall] {
        let invokePattern = #"(?is)<invoke\s+name=\"([^\"]+)\"\s*>(.*?)</invoke>"#
        guard let invokeRegex = try? NSRegularExpression(pattern: invokePattern) else { return [] }
        let nsText = text as NSString
        return invokeRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).compactMap { match in
            guard match.numberOfRanges > 2 else { return nil }
            let rawName = nsText.substring(with: match.range(at: 1))
            let body = nsText.substring(with: match.range(at: 2))
            var input: [String: Any] = [:]
            let parameterPattern = #"(?is)<parameter\s+name=\"([^\"]+)\"\s*>(.*?)</parameter>"#
            guard let parameterRegex = try? NSRegularExpression(pattern: parameterPattern) else { return nil }
            let nsBody = body as NSString
            for parameterMatch in parameterRegex.matches(in: body, range: NSRange(location: 0, length: nsBody.length)) {
                guard parameterMatch.numberOfRanges > 2 else { continue }
                let key = nsBody.substring(with: parameterMatch.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = xmlUnescaped(nsBody.substring(with: parameterMatch.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines))
                if !key.isEmpty {
                    input[key] = value
                }
            }
            guard !input.isEmpty else { return nil }
            return canonicalToolCall(
                AgentToolCall(id: "fallback-\(UUID().uuidString)", name: rawName, inputJSON: jsonString(input))
            )
        }
    }

    private static func xmlUnescaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func compactXMLToolCall(name rawName: String, inputJSON rawInput: String) -> AgentToolCall? {
        let input = (try? AgentToolExecutor.inputObject(from: rawInput)) ?? [:]
        let lowerName = rawName.lowercased()
        let toolName: String
        let normalizedInput: [String: Any]
        switch lowerName {
        case "executebash", "bash", "shell", "runcommand":
            let command = (input["command"] as? String)
                ?? (input["input_command"] as? String)
                ?? (input["input"] as? String)
                ?? ""
            if command.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("ls") {
                toolName = "Glob"
                normalizedInput = ["pattern": "*", "path": "."]
            } else {
                toolName = "Shell"
                normalizedInput = ["command": command]
            }
        case "readfile", "read":
            toolName = "Read"
            normalizedInput = [
                "file_path": (input["file_path"] as? String)
                    ?? (input["path"] as? String)
                    ?? (input["input"] as? String)
                    ?? "",
            ]
        case "writefile", "write":
            toolName = "Write"
            normalizedInput = [
                "file_path": (input["file_path"] as? String) ?? (input["path"] as? String) ?? "",
                "content": (input["content"] as? String) ?? "",
            ]
        case "editfile", "edit", "strreplace":
            toolName = "StrReplace"
            normalizedInput = [
                "file_path": (input["file_path"] as? String) ?? (input["path"] as? String) ?? "",
                "old_string": (input["old_string"] as? String) ?? "",
                "new_string": (input["new_string"] as? String) ?? "",
            ]
        default:
            return nil
        }
        return AgentToolCall(
            id: "fallback-\(UUID().uuidString)",
            name: toolName,
            inputJSON: jsonString(normalizedInput)
        )
    }

    private static func legacyCommandFallbackToolCall(in text: String) -> AgentToolCall? {
        let patterns = [
            #"(?s)^<command>\s*(.*?)\s*</command>$"#,
            #"(?s)^<bash>\s*(.*?)\s*</bash>$"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsText = text as NSString
            guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)),
                  match.numberOfRanges > 1 else { continue }
            let body = nsText.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            let command: String
            let description: String
            if body.hasPrefix("{"),
               let data = body.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                command = (object["command"] as? String)
                    ?? (object["cmd"] as? String)
                    ?? (object["input"] as? String)
                    ?? ""
                description = (object["description"] as? String) ?? "Run workspace command"
            } else {
                command = body
                description = "Run workspace command"
            }
            let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedCommand.isEmpty else { return nil }
            let normalizedInput: [String: Any]
            let toolName: String
            if trimmedCommand == "ls" || trimmedCommand.hasPrefix("ls ") {
                toolName = "Glob"
                normalizedInput = ["pattern": "*", "path": "."]
            } else {
                toolName = "Shell"
                normalizedInput = ["command": trimmedCommand, "description": description]
            }
            return AgentToolCall(id: "fallback-\(UUID().uuidString)", name: toolName, inputJSON: jsonString(normalizedInput))
        }
        return nil
    }

    private static func toolCalls(fromJSONObject object: [String: Any]) -> [AgentToolCall] {
        if let rawCalls = object["tool_calls"] as? [[String: Any]] {
            return rawCalls.compactMap(toolCall(fromJSONObject:))
        }
        if let rawCalls = object["tools"] as? [[String: Any]] {
            return rawCalls.compactMap(toolCall(fromJSONObject:))
        }
        if let call = toolCall(fromJSONObject: object) {
            return [call]
        }
        return []
    }

    private static func toolCall(fromJSONObject object: [String: Any]) -> AgentToolCall? {
        if let skill = object["skill"] as? String, !skill.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return canonicalToolCall(
                AgentToolCall(
                    id: object["id"] as? String ?? "fallback-\(UUID().uuidString)",
                    name: "Skill",
                    inputJSON: jsonString(object)
                )
            )
        }
        let rawName = object["tool"] as? String
            ?? object["name"] as? String
            ?? (object["function"] as? [String: Any])?["name"] as? String
        guard let rawName, !rawName.isEmpty else { return nil }
        let name = canonicalFallbackToolName(rawName)
        let rawInput = object["input"]
            ?? object["arguments"]
            ?? (object["function"] as? [String: Any])?["arguments"]
            ?? [:]
        if name == "Shell", let command = commandString(from: rawInput),
           command.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("ls") {
            return AgentToolCall(
                id: object["id"] as? String ?? "fallback-\(UUID().uuidString)",
                name: "Glob",
                inputJSON: jsonString(["pattern": "*", "path": "."])
            )
        }
        let inputJSON: String
        if let input = rawInput as? String {
            let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
            inputJSON = trimmedInput.hasPrefix("{")
                ? trimmedInput
                : jsonString(["input": input])
        } else {
            inputJSON = jsonString(rawInput)
        }
        return canonicalToolCall(
            AgentToolCall(
                id: object["id"] as? String ?? "fallback-\(UUID().uuidString)",
                name: name,
                inputJSON: inputJSON
            )
        )
    }

    private static func canonicalFallbackToolName(_ rawName: String) -> String {
        AgentToolNameCanonicalizer.canonical(rawName)
    }

    private static func commandString(from rawInput: Any) -> String? {
        if let command = rawInput as? String {
            return command
        }
        if let object = rawInput as? [String: Any] {
            return object["command"] as? String
                ?? object["input_command"] as? String
                ?? object["input"] as? String
        }
        return nil
    }
}

private struct ModelTurn {
    var assistantContent: String
    var toolCalls: [AgentToolCall]
}

private struct OpenAIToolCallAccumulator {
    var index: Int
    var id = ""
    var name = ""
    var arguments = ""

    mutating func apply(delta: [String: Any]) {
        if let id = delta["id"] as? String {
            self.id = id
        }
        if let function = delta["function"] as? [String: Any] {
            if let name = function["name"] as? String {
                self.name += name
            }
            if let arguments = function["arguments"] as? String {
                self.arguments += arguments
            }
        }
    }

    var toolCall: AgentToolCall? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return AgentToolCall(
            id: id.isEmpty ? "call-\(UUID().uuidString)" : id,
            name: name,
            inputJSON: arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}" : arguments
        )
    }
}

enum AgentToolRegistry {
    static let baseToolNames = [
        "Read",
        "Write",
        "StrReplace",
        "Delete",
        "EditNotebook",
        "Grep",
        "Glob",
        "SemanticSearch",
        "Shell",
        "Await",
        "ReadLints",
        "Skill",
        "TodoWrite",
        "AskQuestion",
        "SwitchMode",
        "Task",
    ]
    static let toolNames = baseToolNames + ["WebSearch"]

    static func visibleToolNames(configValues _: [String: String] = [:]) -> [String] {
        toolNames
    }

    static func openAITools(configValues _: [String: String] = [:]) -> [[String: Any]] {
        var tools: [[String: Any]] = [
            functionTool(
                "Read",
                "Read text, image, PDF, or Jupyter notebook content from the workspace.",
                [
                    "file_path": stringProperty("Workspace-relative or absolute file path."),
                    "offset": integerProperty("Optional 1-based line offset."),
                    "limit": integerProperty("Optional maximum number of lines to return."),
                    "pages": stringProperty("Optional PDF page range such as 1-3."),
                ],
                required: ["file_path"]
            ),
            functionTool(
                "Write",
                "Create or overwrite a UTF-8 file in the workspace.",
                [
                    "file_path": stringProperty("Workspace-relative or absolute file path."),
                    "content": stringProperty("Complete file contents to write."),
                ],
                required: ["file_path", "content"]
            ),
            functionTool(
                "StrReplace",
                "Replace exact strings in a workspace file. Supports one replacement or an edits array.",
                [
                    "file_path": stringProperty("Workspace-relative or absolute file path."),
                    "old_string": stringProperty("Exact text to replace."),
                    "new_string": stringProperty("Replacement text."),
                    "replace_all": boolProperty("Replace every match instead of requiring one unique match."),
                    "edits": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "old_string": stringProperty("Exact text to replace."),
                                "new_string": stringProperty("Replacement text."),
                                "replace_all": boolProperty("Replace every match."),
                            ],
                            "required": ["old_string", "new_string"],
                        ],
                    ],
                ],
                required: ["file_path"]
            ),
            functionTool(
                "Delete",
                "Delete a file or, with recursive=true, a directory inside the workspace.",
                [
                    "path": stringProperty("Workspace-relative or absolute file or directory path."),
                    "recursive": boolProperty("Allow deleting directories recursively."),
                ],
                required: ["path"]
            ),
            functionTool(
                "EditNotebook",
                "Replace, insert, or delete a cell in a Jupyter notebook file.",
                [
                    "notebook_path": stringProperty("Workspace-relative or absolute .ipynb path."),
                    "cell_id": stringProperty("Optional notebook cell id."),
                    "cell_number": integerProperty("Optional 0-based cell index."),
                    "new_source": stringProperty("New source for replace or insert."),
                    "cell_type": [
                        "type": "string",
                        "enum": ["code", "markdown"],
                        "description": "Cell type for inserted cells or replacement metadata.",
                    ],
                    "edit_mode": [
                        "type": "string",
                        "enum": ["replace", "insert", "delete"],
                        "description": "Notebook edit mode. Defaults to replace.",
                    ],
                ],
                required: ["notebook_path"]
            ),
            functionTool(
                "Grep",
                "Search text files by regular expression under the workspace, preferring ripgrep.",
                [
                    "pattern": stringProperty("Regular expression to search for."),
                    "path": stringProperty("Optional directory or file to search."),
                    "glob": stringProperty("Optional glob filter such as *.swift."),
                    "include": stringProperty("Legacy alias for glob."),
                    "output_mode": [
                        "type": "string",
                        "enum": ["content", "files_with_matches", "count"],
                        "description": "Result mode. Defaults to files_with_matches.",
                    ],
                    "-B": integerProperty("Context lines before each match."),
                    "-A": integerProperty("Context lines after each match."),
                    "-C": integerProperty("Context lines before and after each match."),
                    "context": integerProperty("Alias for -C."),
                    "-n": boolProperty("Show line numbers in content mode."),
                    "-i": boolProperty("Case-insensitive search."),
                    "type": stringProperty("Optional ripgrep file type."),
                    "head_limit": integerProperty("Maximum returned lines or entries."),
                    "offset": integerProperty("Number of results to skip before limiting."),
                    "multiline": boolProperty("Enable multiline matching."),
                ],
                required: ["pattern"]
            ),
            functionTool(
                "Glob",
                "Find files by glob pattern under the workspace.",
                [
                    "pattern": stringProperty("Glob such as **/*.swift or *.md."),
                    "path": stringProperty("Optional directory to search."),
                ],
                required: ["pattern"]
            ),
            functionTool(
                "SemanticSearch",
                "Search code by meaning using a deterministic local workspace index.",
                [
                    "query": stringProperty("Natural-language or code concept query."),
                    "path": stringProperty("Optional directory or file to search."),
                    "limit": integerProperty("Maximum number of ranked results."),
                ],
                required: ["query"]
            ),
            functionTool(
                "WebSearch",
                """
                Search the public web for current information through the configured Search provider. Supports GLM/Z.AI, Tavily, or a custom JSON API.
                Use it for current events, recent documentation, weather, or source-backed evidence beyond the workspace.
                """,
                [
                    "query": stringProperty("Specific search query. Include versions, dates, product names, or locations when useful."),
                    "gl": stringProperty("Optional country code for localized custom providers, such as us or cn."),
                ],
                required: ["query"]
            ),
        ]
        tools.append(contentsOf: [
            functionTool(
                "Shell",
                "Run a shell command in the workspace.",
                [
                    "command": stringProperty("Command to run with /bin/zsh -lc."),
                    "description": stringProperty("Short reason for running the command."),
                    "timeout": integerProperty("Optional timeout in milliseconds."),
                    "run_in_background": boolProperty("Start the command in the background and return a task id."),
                ],
                required: ["command"]
            ),
            functionTool(
                "Await",
                "Wait for or read output from a background Shell or Task.",
                [
                    "task_id": stringProperty("Background task id."),
                    "block": boolProperty("Whether to block until completion. Defaults to true."),
                    "timeout": integerProperty("Maximum wait time in milliseconds."),
                ],
                required: ["task_id"]
            ),
            functionTool(
                "ReadLints",
                "Read current workspace linter or diagnostic findings when available.",
                [
                    "path": stringProperty("Optional file or directory to scope diagnostics."),
                    "severity": stringProperty("Optional severity filter such as error or warning."),
                    "limit": integerProperty("Maximum number of diagnostics."),
                ],
                required: []
            ),
            functionTool(
                "Skill",
                "Load a PilotDeck skill's instructions. This does not execute the skill; after loading, use Shell/Read/other tools according to the returned instructions and skillDir. Use exact names from the system prompt's Available skills list.",
                [
                    "skill": stringProperty("Exact skill name from the Available skills list."),
                    "args": stringProperty("User query or task arguments for the skill."),
                ],
                required: ["skill"]
            ),
            functionTool(
                "TodoWrite",
                "Replace the current session todo list.",
                [
                    "todos": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "additionalProperties": true,
                        ],
                    ],
                ],
                required: ["todos"]
            ),
            functionTool(
                "AskQuestion",
                "Ask the user one or more short blocking questions. In Plan mode, use this for clarification; never ask plan approval here. Use the questions array shape. Options are optional and may contain any number of entries.",
                [
                    "questions": [
                        "type": "array",
                        "minItems": 1,
                        "items": [
                            "type": "object",
                            "properties": [
                                "header": stringProperty("Short section label."),
                                "question": stringProperty("Question to ask."),
                                "options": [
                                    "type": "array",
                                    "items": [
                                        "type": "object",
                                        "properties": [
                                            "label": stringProperty("Option label."),
                                            "description": stringProperty("Optional short description."),
                                        ],
                                        "required": ["label"],
                                    ],
                                ],
                                "multiSelect": boolProperty("Whether multiple options may be selected."),
                            ],
                            "required": ["question"],
                        ],
                    ],
                    "question": stringProperty("Legacy single question fallback."),
                    "options": [
                        "type": "array",
                        "items": stringProperty("Legacy option label."),
                    ],
                ],
                required: []
            ),
            functionTool(
                "SwitchMode",
                "Switch between plan and agent mode. Use mode=agent with a concrete plan to execute after planning.",
                [
                    "mode": [
                        "type": "string",
                        "enum": ["plan", "agent"],
                        "description": "Target run mode.",
                    ],
                    "plan": stringProperty("The plan to execute when switching to agent mode."),
                ],
                required: ["mode"]
            ),
            functionTool(
                "Task",
                "Start a delegated task or subagent.",
                [
                    "type": [
                        "type": "string",
                        "enum": ["generalPurpose", "explore", "shell", "cursor-guide", "ci-investigator", "best-of-n-runner"],
                        "description": "Task type. Defaults to generalPurpose.",
                    ],
                    "prompt": stringProperty("Concrete task prompt or shell command for type=shell."),
                    "description": stringProperty("Optional short label."),
                    "model": stringProperty("Optional model hint."),
                    "run_in_background": boolProperty("Run task asynchronously and return a task id."),
                    "cwd": stringProperty("Optional workspace-relative or absolute cwd."),
                    "isolation": [
                        "type": "string",
                        "enum": ["worktree"],
                        "description": "Optional isolation mode. best-of-n-runner uses worktree isolation.",
                    ],
                    "n": integerProperty("Number of isolated attempts for best-of-n-runner."),
                ],
                required: ["prompt"]
            ),
        ])
        return tools
    }

    private static func functionTool(
        _ name: String,
        _ description: String,
        _ properties: [String: Any],
        required: [String]
    ) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": [
                    "type": "object",
                    "properties": properties,
                    "required": required,
                    "additionalProperties": false,
                ],
            ],
        ]
    }

    private static func stringProperty(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private static func integerProperty(_ description: String) -> [String: Any] {
        ["type": "integer", "description": description]
    }

    private static func boolProperty(_ description: String) -> [String: Any] {
        ["type": "boolean", "description": description]
    }
}

enum AgentPermissionPolicy {
    enum Result: Equatable {
        case allow
        case ask(String)
        case block(String)
        case deny(String)
    }

    static let planModeSafeTools = Set([
        "Read",
        "Glob",
        "Grep",
        "SemanticSearch",
        "WebSearch",
        "ReadLints",
        "Skill",
        "TodoRead",
        "TodoWrite",
        "AskQuestion",
        "SwitchMode",
        "Await",
    ])

    static let mutatingTools = Set(["Write", "StrReplace", "Delete", "EditNotebook", "Shell"])
    static let interactiveTools = Set(["AskQuestion"])

    static func policy(for call: AgentToolCall, context: AgentRunContext) -> Result {
        let toolName = normalizedToolName(call.name)
        if context.runMode == .plan, !context.planExited, !isPlanModeSafe(toolName: toolName, call: call) {
            return .block(planModePolicyBlockMessage(for: toolName))
        }
        if toolName != "WebSearch", matchesAny(ruleSet: context.toolSettings.disallowedTools, call: call) {
            return .deny("\(toolName) is blocked by permissions settings.")
        }
        if context.runMode == .plan,
           !context.planExited,
           toolName == "Shell",
           AgentRunContext.isReadOnlyShell(call.inputJSON) {
            return .allow
        }
        if toolName == "SwitchMode", switchModeTarget(call.inputJSON) == "agent" {
            if context.runMode == .plan,
               !context.planExited,
               !context.planQuestionAnswered,
               !isRecoveredPlainTextPlan(call.inputJSON) {
                return .block("Plan mode requires AskQuestion before leaving Plan mode. Ask the user a blocking question first, then generate the final plan.")
            }
            return .ask("Plan approval is required before leaving Plan mode.")
        }
        if DestructiveToolClassifier.isDestructive(call: call) {
            if context.planExecutionApproved {
                return .allow
            }
            return .ask("Destructive action plan approval is required before deleting workspace files.")
        }
        if interactiveTools.contains(toolName) {
            return .ask("PilotDeck wants to ask a question.")
        }
        if context.permissionMode == .bypassPermissions {
            return .allow
        }
        if matchesAny(ruleSet: context.toolSettings.allowedTools, call: call) {
            return .allow
        }
        if toolRequiresPrompt(toolName: toolName, call: call) {
            return .ask("PilotDeck wants to run \(toolName).")
        }
        return .allow
    }

    private static func planModePolicyBlockMessage(for toolName: String) -> String {
        if toolName == "Shell" {
            return "Plan mode skipped this write-capable shell command. Use read-only commands while planning, then call SwitchMode with mode=\"agent\" and a concrete plan before mutating the workspace."
        }
        return "Plan mode skipped this workspace-changing \(toolName) tool. Continue planning with read/search tools, then call SwitchMode with mode=\"agent\" and a concrete plan before mutating the workspace."
    }

    private static func switchModeTarget(_ inputJSON: String) -> String {
        guard let data = inputJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "agent"
        }
        return ((object["mode"] as? String) ?? "agent")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func isRecoveredPlainTextPlan(_ inputJSON: String) -> Bool {
        guard let data = inputJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["recoveredFromPlainText"] as? Bool == true
    }

    private static func normalizedToolName(_ value: String) -> String {
        AgentToolNameCanonicalizer.canonical(value)
    }

    private static func matchesAny(ruleSet: [String], call: AgentToolCall) -> Bool {
        ruleSet.contains { rule in matches(rule: rule, call: call) }
    }

    private static func matches(rule: String, call: AgentToolCall) -> Bool {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let canonicalName = AgentToolNameCanonicalizer.canonical(call.name)
        if trimmed == canonicalName || AgentToolNameCanonicalizer.canonical(trimmed) == canonicalName { return true }
        guard canonicalName == "Shell" else {
            return false
        }
        let ruleName: String
        if trimmed.hasPrefix("Shell("), trimmed.hasSuffix(")") {
            ruleName = "Shell"
        } else if trimmed.hasPrefix("Bash("), trimmed.hasSuffix(")") {
            ruleName = "Bash"
        } else {
            return false
        }
        let inner = String(trimmed.dropFirst(ruleName.count + 1).dropLast())
        let input = (try? AgentToolExecutor.inputObject(from: call.inputJSON)) ?? [:]
        let command = input["command"] as? String ?? ""
        if inner == "*" { return true }
        if inner.hasSuffix("*") {
            var prefix = String(inner.dropLast())
            if prefix.hasSuffix(":") {
                prefix.removeLast()
            }
            return command.hasPrefix(prefix)
        }
        return command == inner
    }

    private static func isPlanModeSafe(toolName: String, call: AgentToolCall) -> Bool {
        if planModeSafeTools.contains(toolName) { return true }
        if toolName == "Shell" {
            return AgentRunContext.isReadOnlyShell(call.inputJSON)
        }
        if toolName == "Task" {
            return AgentRunContext.isReadOnlyTask(call.inputJSON)
        }
        return false
    }

    private static func toolRequiresPrompt(toolName: String, call: AgentToolCall) -> Bool {
        if toolName == "WebSearch" {
            return true
        }
        if toolName == "Shell" {
            return true
        }
        if toolName == "Task" {
            return !AgentRunContext.isReadOnlyTask(call.inputJSON)
        }
        return mutatingTools.contains(toolName)
    }
}

struct ResolvedAgentSkill: Sendable, Equatable {
    var requestedName: String
    var canonicalName: String
    var skillDir: String
    var skillFile: String
    var pluginRoot: String?
    var summary: String
    var allowedTools: [String]
    var content: String
}

struct AgentSkillCatalogEntry: Sendable, Equatable {
    var name: String
    var slug: String
    var scope: String
    var summary: String
}

enum SkillRuntimeService {
    static func load(inputJSON: String, context: AgentRunContext) throws -> String {
        let input = try AgentToolExecutor.inputObject(from: inputJSON)
        let requestedSkill = try AgentToolExecutor.requiredString("skill", input: input)
        let args = (input["args"] as? String).nilIfBlank ?? ""
        let resolved = try resolve(
            requestedSkill,
            workspacePath: context.workspacePath
        )
        context.recordInvokedSkill(resolved.canonicalName)
        let payload: [String: Any] = [
            "skill": resolved.canonicalName,
            "requestedSkill": resolved.requestedName,
            "args": args,
            "skillDir": resolved.skillDir,
            "skillFile": resolved.skillFile,
            "pluginRoot": resolved.pluginRoot ?? "",
            "summary": resolved.summary,
            "allowedTools": resolved.allowedTools,
            "instructions": limitSkillContent(resolved.content),
            "executionHint": "Skill loaded only. If instructions mention relative files or scripts, run them from skillDir or use absolute paths with Shell.",
        ]
        return jsonString(payload, pretty: true)
    }

    static func resolve(_ skill: String, workspacePath: String) throws -> ResolvedAgentSkill {
        let requested = skill.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty else {
            throw ProviderClientError.toolExecution("Skill name is required.")
        }

        var candidates: [URL] = []
        candidates.append(Self.userSkillsRoot().appendingPathComponent(slugCandidate(requested), isDirectory: true))
        candidates.append(Self.projectSkillsRoot(workspacePath).appendingPathComponent(slugCandidate(requested), isDirectory: true))

        for candidate in candidates {
            if let resolved = readSkill(at: candidate, requested: requested) {
                return resolved
            }
        }

        for root in searchableSkillRoots(workspacePath: workspacePath) {
            if let match = scan(root: root, requested: requested) {
                return match
            }
        }

        throw ProviderClientError.toolExecution("Skill not found: \(requested)")
    }

    static func availableSkills(workspacePath: String, limit: Int = 24) -> [AgentSkillCatalogEntry] {
        var scopedRoots: [(root: URL, scope: String)] = []
        let trimmedWorkspace = workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedWorkspace.isEmpty {
            scopedRoots.append((projectSkillsRoot(trimmedWorkspace), "project"))
        }
        scopedRoots.append((userSkillsRoot(), "user"))

        var entries: [AgentSkillCatalogEntry] = []
        var seen: Set<String> = []
        for scopedRoot in scopedRoots {
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: scopedRoot.root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for child in children.sorted(by: { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }) {
                guard let resolved = readSkill(at: child, requested: child.lastPathComponent) else { continue }
                let dedupeKey = resolved.canonicalName.lowercased()
                guard seen.insert(dedupeKey).inserted else { continue }
                entries.append(AgentSkillCatalogEntry(
                    name: resolved.canonicalName,
                    slug: child.lastPathComponent,
                    scope: scopedRoot.scope,
                    summary: resolved.summary
                ))
                if entries.count >= limit {
                    return entries
                }
            }
        }
        return entries
    }

    static func environment(configValues: [String: String]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "CLAU" + "DE_PLUGIN_ROOT")
        let prefix = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = [prefix, environment["PATH"]].compactMap { $0 }.joined(separator: ":")
        return environment.compactMapValues { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : value
        }
    }

    private static func searchableSkillRoots(workspacePath: String) -> [URL] {
        [
            userSkillsRoot(),
            projectSkillsRoot(workspacePath),
        ]
    }

    private static func readSkill(at directory: URL, requested: String) -> ResolvedAgentSkill? {
        let file = directory.appendingPathComponent("SKILL.md")
        guard let content = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let frontmatter = parseFrontmatter(content)
        let canonical = canonicalName(requested: requested, directory: directory, frontmatter: frontmatter)
        return ResolvedAgentSkill(
            requestedName: requested,
            canonicalName: canonical,
            skillDir: directory.path,
            skillFile: file.path,
            pluginRoot: nil,
            summary: summary(from: content, frontmatter: frontmatter),
            allowedTools: parseAllowedTools(content),
            content: content
        )
    }

    private static func scan(root: URL, requested: String) -> ResolvedAgentSkill? {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let needle = requested.lowercased()
        for child in children {
            guard let resolved = readSkill(at: child, requested: requested) else { continue }
            let haystack = "\(child.lastPathComponent) \(resolved.canonicalName) \(resolved.summary) \(resolved.content.prefix(800))".lowercased()
            if haystack.contains(needle) {
                return resolved
            }
        }
        return nil
    }

    private static func userSkillsRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".g9claw", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
    }

    private static func projectSkillsRoot(_ workspacePath: String) -> URL {
        URL(fileURLWithPath: NSString(string: workspacePath).expandingTildeInPath)
            .appendingPathComponent(".g9claw", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
    }

    private static func slugCandidate(_ requested: String) -> String {
        let value = requested.split(separator: ":").last.map(String.init) ?? requested
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func canonicalName(requested: String, directory: URL, frontmatter: [String: String]) -> String {
        let slug = directory.lastPathComponent
        return frontmatter["name"]?.nilIfBlank ?? slug
    }

    private static func parseFrontmatter(_ content: String) -> [String: String] {
        let lines = content.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---" else { return [:] }
        var result: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespacesAndNewlines) == "---" { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value.removeFirst()
                value.removeLast()
            }
            result[key] = value
        }
        return result
    }

    private static func parseAllowedTools(_ content: String) -> [String] {
        var tools: [String] = []
        var inAllowedTools = false
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "allowed-tools:" {
                inAllowedTools = true
                continue
            }
            if inAllowedTools, trimmed.hasPrefix("- ") {
                var value = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                    value.removeFirst()
                    value.removeLast()
                }
                tools.append(value)
                continue
            }
            if inAllowedTools, !trimmed.isEmpty, !trimmed.hasPrefix("#") {
                break
            }
        }
        return tools
    }

    private static func summary(from content: String, frontmatter: [String: String]) -> String {
        if let description = frontmatter["description"].nilIfBlank {
            return description
        }
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !trimmed.hasPrefix("---"), !trimmed.hasPrefix("#") {
                return trimmed
            }
        }
        return ""
    }

    private static func limitSkillContent(_ content: String) -> String {
        if content.count <= 18_000 { return content }
        return String(content.prefix(18_000)) + "\n... skill content truncated ..."
    }
}

enum AgentToolExecutor {
    static func execute(call: AgentToolCall, context: AgentRunContext) async -> AgentToolResult {
        let invocation = ToolArgumentNormalizer.normalize(call)
        if let recoveryResult = invocation.recoveryResult {
            return recoveryResult
        }
        let executionCall = invocation.call
        let toolName = AgentToolNameCanonicalizer.canonical(executionCall.name)
        if let cachedGlob = RootGlobExecutionPolicy.cachedResultIfAvailable(call: executionCall, context: context) {
            return cachedGlob
        }
        do {
            let output: String
            switch toolName {
            case "Read":
                output = try read(inputJSON: executionCall.inputJSON, workspacePath: context.workspacePath)
            case "Write":
                output = try write(inputJSON: executionCall.inputJSON, workspacePath: context.workspacePath)
            case "StrReplace":
                output = try strReplace(inputJSON: executionCall.inputJSON, workspacePath: context.workspacePath)
            case "Delete":
                output = try delete(inputJSON: executionCall.inputJSON, workspacePath: context.workspacePath)
            case "EditNotebook":
                output = try editNotebook(inputJSON: executionCall.inputJSON, workspacePath: context.workspacePath)
            case "Grep":
                output = try grep(inputJSON: executionCall.inputJSON, workspacePath: context.workspacePath)
            case "Glob":
                output = RootGlobExecutionPolicy.recordIfRootGlob(
                    call: executionCall,
                    output: try glob(inputJSON: executionCall.inputJSON, workspacePath: context.workspacePath),
                    context: context
                )
            case "SemanticSearch":
                output = try semanticSearch(inputJSON: executionCall.inputJSON, workspacePath: context.workspacePath)
            case "Shell":
                output = try await shell(inputJSON: executionCall.inputJSON, context: context)
            case "Await":
                output = try await awaitTask(inputJSON: executionCall.inputJSON)
            case "WebSearch":
                output = try await webSearch(inputJSON: executionCall.inputJSON, context: context)
            case "WebFetch":
                output = "WebFetch is disabled. Use WebSearch for source-grounded web evidence."
            case "ReadLints":
                output = try await readLints(inputJSON: executionCall.inputJSON, context: context)
            case "Skill":
                output = try SkillRuntimeService.load(inputJSON: executionCall.inputJSON, context: context)
            case "Task":
                output = try await runTask(inputJSON: executionCall.inputJSON, context: context)
            case "TodoRead":
                output = context.todosJSON
            case "TodoWrite":
                output = try todoWrite(inputJSON: executionCall.inputJSON, context: context)
            case "SwitchMode":
                let input = try inputObject(from: executionCall.inputJSON)
                let mode = ((input["mode"] as? String) ?? "agent").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if mode == "agent" {
                    context.planExited = true
                    context.runMode = .agent
                    context.planExecutionApproved = true
                } else if mode == "plan" {
                    context.planExited = false
                    context.runMode = .plan
                    context.planExecutionApproved = false
                }
                if mode == "plan", let feedback = (input["userFeedback"] as? String).nilIfBlank {
                    output = "Stay in Plan mode. User requested revisions:\n\(feedback)"
                } else {
                    output = (input["plan"] as? String).nilIfBlank ?? "Mode switched to \(mode)."
                }
            case "AskQuestion":
                guard hasNonEmptyAnswers(executionCall.inputJSON) else {
                    throw ProviderClientError.toolExecution("AskQuestion requires a user answer before continuing.")
                }
                output = askUserQuestionOutput(inputJSON: executionCall.inputJSON)
            default:
                throw ProviderClientError.toolExecution("Unsupported tool: \(toolName)")
            }
            return AgentToolResult(callId: executionCall.id, toolName: toolName, output: limitOutput(output), isError: false)
        } catch {
            return AgentToolResult(callId: executionCall.id, toolName: toolName, output: error.localizedDescription, isError: true)
        }
    }

    static func askUserQuestionResult(call: AgentToolCall, updatedInputJSON: String) -> AgentToolResult {
        guard hasNonEmptyAnswers(updatedInputJSON) else {
            return AgentToolResult(
                callId: call.id,
                toolName: AgentToolNameCanonicalizer.canonical(call.name),
                output: "AskQuestion requires a user answer before continuing.",
                isError: true
            )
        }
        return AgentToolResult(
            callId: call.id,
            toolName: AgentToolNameCanonicalizer.canonical(call.name),
            output: limitOutput(askUserQuestionOutput(inputJSON: updatedInputJSON)),
            isError: false
        )
    }

    static func askUserQuestionOutput(inputJSON: String) -> String {
        guard let data = inputJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = object["answers"] as? [String: Any] else {
            return "User has not answered any questions yet."
        }
        let entries = answers.keys.sorted().compactMap { key -> String? in
            guard let value = answers[key] else { return nil }
            let display: String
            if let string = value as? String {
                display = string
            } else if let values = value as? [String] {
                display = values.joined(separator: ", ")
            } else {
                display = String(describing: value)
            }
            let trimmed = display.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return "\"\(key)\"=\"\(trimmed)\""
        }
        guard !entries.isEmpty else {
            return "User has not answered any questions yet."
        }
        return "User has answered your questions: \(entries.joined(separator: ", ")). You can now continue with the user's answers in mind. If you are in Plan mode, continue with read-only planning if needed, then call SwitchMode with mode=\"agent\" and a concrete plan. Do not stop after ordinary prose only."
    }

    private static func hasNonEmptyAnswers(_ inputJSON: String) -> Bool {
        guard let data = inputJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = object["answers"] as? [String: Any] else {
            return false
        }
        return answers.values.contains { value in
            if let string = value as? String {
                return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if let values = value as? [String] {
                return values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            }
            return true
        }
    }

    static func inputObject(from json: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderClientError.toolExecution("Tool input must be a JSON object.")
        }
        return object
    }

    static func applyEdit(content: String, oldString: String, newString: String, replaceAll: Bool) throws -> String {
        guard !oldString.isEmpty else {
            throw ProviderClientError.toolExecution("old_string must not be empty.")
        }
        let count = content.components(separatedBy: oldString).count - 1
        guard count > 0 else {
            throw ProviderClientError.toolExecution("old_string was not found.")
        }
        if !replaceAll, count != 1 {
            throw ProviderClientError.toolExecution("old_string matched \(count) times. Provide a unique string or set replace_all.")
        }
        if replaceAll {
            return content.replacingOccurrences(of: oldString, with: newString)
        }
        guard let range = content.range(of: oldString) else {
            throw ProviderClientError.toolExecution("old_string was not found.")
        }
        var updated = content
        updated.replaceSubrange(range, with: newString)
        return updated
    }

    private static func read(inputJSON: String, workspacePath: String) throws -> String {
        let input = try inputObject(from: inputJSON)
        let file = try requiredString("file_path", input: input)
        let url = try AgentPathResolver.resolve(file, workspacePath: workspacePath, mustExist: true)
        let ext = url.pathExtension.lowercased()
        if ext == "ipynb" {
            return try readNotebook(url: url, workspacePath: workspacePath)
        }
        if ext == "pdf" {
            return try readPDF(url: url, workspacePath: workspacePath, pages: (input["pages"] as? String).nilIfBlank)
        }
        if imageMimeType(for: url) != nil {
            return try readImage(url: url, workspacePath: workspacePath)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.components(separatedBy: .newlines)
        let offset = max((input["offset"] as? Int ?? 1) - 1, 0)
        let limit = input["limit"] as? Int ?? min(lines.count, 2_000)
        let selected = lines.dropFirst(offset).prefix(max(limit, 1))
        return selected.enumerated().map { index, line in
            "\(offset + index + 1): \(line)"
        }.joined(separator: "\n")
    }

    private static func write(inputJSON: String, workspacePath: String) throws -> String {
        let input = try inputObject(from: inputJSON)
        let file = try requiredString("file_path", input: input)
        let content = try requiredString("content", input: input)
        let url = try AgentPathResolver.resolve(file, workspacePath: workspacePath, mustExist: false)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return "Wrote \(content.utf8.count) bytes to \(AgentPathResolver.relativePath(url, workspacePath: workspacePath))."
    }

    private static func strReplace(inputJSON: String, workspacePath: String) throws -> String {
        let input = try inputObject(from: inputJSON)
        let file = try requiredString("file_path", input: input)
        let url = try AgentPathResolver.resolve(file, workspacePath: workspacePath, mustExist: true)
        var content = try String(contentsOf: url, encoding: .utf8)
        let edits: [[String: Any]]
        if let batch = input["edits"] as? [[String: Any]], !batch.isEmpty {
            edits = batch
        } else {
            edits = [input]
        }
        for editInput in edits {
            let oldString = try requiredString("old_string", input: editInput)
            let newString = try requiredString("new_string", input: editInput)
            let replaceAll = editInput["replace_all"] as? Bool ?? false
            content = try applyEdit(content: content, oldString: oldString, newString: newString, replaceAll: replaceAll)
        }
        try content.write(to: url, atomically: true, encoding: .utf8)
        let target = AgentPathResolver.relativePath(url, workspacePath: workspacePath)
        return edits.count == 1 ? "Edited \(target)." : "Applied \(edits.count) edits to \(target)."
    }

    private static func delete(inputJSON: String, workspacePath: String) throws -> String {
        let input = try inputObject(from: inputJSON)
        let rawPath = try requiredString("path", input: input)
        let recursive = input["recursive"] as? Bool ?? false
        let url = try AgentPathResolver.resolve(rawPath, workspacePath: workspacePath, mustExist: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ProviderClientError.toolExecution("Path does not exist: \(rawPath)")
        }
        if isDirectory.boolValue, !recursive {
            throw ProviderClientError.toolExecution("Refusing to delete directory without recursive=true: \(rawPath)")
        }
        try FileManager.default.removeItem(at: url)
        return "Deleted \(AgentPathResolver.relativePath(url, workspacePath: workspacePath))."
    }

    private static func editNotebook(inputJSON: String, workspacePath: String) throws -> String {
        let input = try inputObject(from: inputJSON)
        let notebookPath = try requiredString("notebook_path", input: input)
        let url = try AgentPathResolver.resolve(notebookPath, workspacePath: workspacePath, mustExist: true)
        guard url.pathExtension.lowercased() == "ipynb" else {
            throw ProviderClientError.toolExecution("EditNotebook requires a .ipynb file.")
        }
        let data = try Data(contentsOf: url)
        guard var object = try JSONSerialization.jsonObject(with: data, options: [.mutableContainers]) as? [String: Any],
              var cells = object["cells"] as? [[String: Any]] else {
            throw ProviderClientError.toolExecution("Notebook JSON must contain a cells array.")
        }
        let mode = ((input["edit_mode"] as? String) ?? "replace").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let index = try notebookCellIndex(input: input, cells: cells, allowEndForInsert: mode == "insert")
        switch mode {
        case "insert":
            let source = (input["new_source"] as? String) ?? ""
            var cell: [String: Any] = [
                "cell_type": (input["cell_type"] as? String).nilIfBlank ?? "code",
                "metadata": [:],
                "source": notebookSourceArray(source),
                "id": UUID().uuidString.prefix(8).lowercased(),
            ]
            if (cell["cell_type"] as? String) == "code" {
                cell["outputs"] = []
                cell["execution_count"] = NSNull()
            }
            cells.insert(cell, at: min(max(index, 0), cells.count))
        case "delete":
            guard cells.indices.contains(index) else {
                throw ProviderClientError.toolExecution("Notebook cell index out of range: \(index)")
            }
            cells.remove(at: index)
        case "replace":
            guard cells.indices.contains(index) else {
                throw ProviderClientError.toolExecution("Notebook cell index out of range: \(index)")
            }
            let source = try requiredString("new_source", input: input)
            cells[index]["source"] = notebookSourceArray(source)
            if let cellType = (input["cell_type"] as? String).nilIfBlank {
                cells[index]["cell_type"] = cellType
            }
        default:
            throw ProviderClientError.toolExecution("Unsupported notebook edit_mode: \(mode)")
        }
        object["cells"] = cells
        let updated = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try updated.write(to: url, options: .atomic)
        return "Notebook \(mode) applied to \(AgentPathResolver.relativePath(url, workspacePath: workspacePath)) at cell \(index)."
    }

    private static func glob(inputJSON: String, workspacePath: String) throws -> String {
        let input = try inputObject(from: inputJSON)
        let pattern = try requiredString("pattern", input: input)
        let searchPath = (input["path"] as? String).nilIfBlank ?? "."
        let root = try AgentPathResolver.resolve(searchPath, workspacePath: workspacePath, mustExist: true)
        let regex = try AgentPathResolver.globRegex(pattern)
        var matches: [String] = []
        for url in AgentPathResolver.walk(root) {
            let relative = AgentPathResolver.relativePath(url, workspacePath: root.path)
            if regex.firstMatch(in: relative, range: NSRange(location: 0, length: (relative as NSString).length)) != nil {
                matches.append(AgentPathResolver.relativePath(url, workspacePath: workspacePath))
            }
            if matches.count >= 500 { break }
        }
        return matches.isEmpty ? "No files matched \(pattern)." : matches.sorted().joined(separator: "\n")
    }

    private static func grep(inputJSON: String, workspacePath: String) throws -> String {
        let input = try inputObject(from: inputJSON)
        let pattern = try requiredString("pattern", input: input)
        let searchPath = (input["path"] as? String).nilIfBlank ?? "."
        let root = try AgentPathResolver.resolve(searchPath, workspacePath: workspacePath, mustExist: true)
        if let rgOutput = try runRipgrep(input: input, pattern: pattern, root: root, workspacePath: workspacePath) {
            return rgOutput
        }
        let include = (input["glob"] as? String).nilIfBlank ?? (input["include"] as? String).nilIfBlank
        let includeRegex = try include.map { try AgentPathResolver.globRegex($0) }
        let options: NSRegularExpression.Options = (input["-i"] as? Bool ?? false) ? [.caseInsensitive] : []
        let regex = try NSRegularExpression(pattern: pattern, options: options)
        let outputMode = (input["output_mode"] as? String).nilIfBlank ?? "files_with_matches"
        let headLimit = input["head_limit"] as? Int ?? 250
        let offset = max(input["offset"] as? Int ?? 0, 0)
        let urls: [URL]
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            urls = [root]
        } else {
            urls = AgentPathResolver.walk(root)
        }
        var output: [String] = []
        var counts: [String: Int] = [:]
        var seenFiles = Set<String>()
        for url in urls {
            let relative = AgentPathResolver.relativePath(url, workspacePath: workspacePath)
            if let includeRegex,
               includeRegex.firstMatch(in: relative, range: NSRange(location: 0, length: (relative as NSString).length)) == nil {
                continue
            }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let lines = text.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                let nsLine = line as NSString
                if regex.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)) != nil {
                    counts[relative, default: 0] += 1
                    switch outputMode {
                    case "content":
                        output.append("\(relative):\(index + 1):\(line)")
                    case "count":
                        break
                    default:
                        if seenFiles.insert(relative).inserted {
                            output.append(relative)
                        }
                    }
                }
            }
        }
        if outputMode == "count" {
            output = counts.keys.sorted().map { "\($0):\(counts[$0] ?? 0)" }
        }
        let sliced = output.dropFirst(offset).prefix(headLimit == 0 ? output.count : max(headLimit, 1))
        return sliced.isEmpty ? "No matches for \(pattern)." : sliced.joined(separator: "\n")
    }

    private static func semanticSearch(inputJSON: String, workspacePath: String) throws -> String {
        let input = try inputObject(from: inputJSON)
        let query = try requiredString("query", input: input)
        let searchPath = (input["path"] as? String).nilIfBlank ?? "."
        let root = try AgentPathResolver.resolve(searchPath, workspacePath: workspacePath, mustExist: true)
        let limit = max(1, min(input["limit"] as? Int ?? 20, 100))
        let terms = semanticTerms(query)
        guard !terms.isEmpty else {
            throw ProviderClientError.toolExecution("SemanticSearch query did not contain searchable terms.")
        }
        var hits: [[String: Any]] = []
        for url in AgentPathResolver.walk(root) {
            guard let text = try? String(contentsOf: url, encoding: .utf8), text.count <= 300_000 else { continue }
            let relative = AgentPathResolver.relativePath(url, workspacePath: workspacePath)
            var bestScore = score(relative.lowercased(), terms: terms) * 4
            var bestLine = 1
            var bestSnippet = ""
            for (index, line) in text.components(separatedBy: .newlines).enumerated() {
                let lineScore = score(line.lowercased(), terms: terms)
                if lineScore > bestScore {
                    bestScore = lineScore
                    bestLine = index + 1
                    bestSnippet = line.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            if bestScore > 0 {
                hits.append([
                    "path": relative,
                    "line": bestLine,
                    "score": bestScore,
                    "snippet": bestSnippet.isEmpty ? relative : String(bestSnippet.prefix(500)),
                ])
            }
        }
        let sorted = hits.sorted {
            let leftScore = ($0["score"] as? Int) ?? 0
            let rightScore = ($1["score"] as? Int) ?? 0
            if leftScore != rightScore { return leftScore > rightScore }
            return (($0["path"] as? String) ?? "") < (($1["path"] as? String) ?? "")
        }.prefix(limit)
        return jsonString(["query": query, "results": Array(sorted)], pretty: true)
    }

    private static func shell(inputJSON: String, context: AgentRunContext) async throws -> String {
        let input = try inputObject(from: inputJSON)
        let command = try requiredString("command", input: input)
        let timeoutMs = shellTimeoutMilliseconds(input)
        let cwd = context.workspacePath
        let environment = SkillRuntimeService.environment(configValues: context.nativeConfigValues)
        if input["run_in_background"] as? Bool == true {
            let id = try AgentBackgroundTaskStore.shared.startShell(
                command: command,
                cwd: cwd,
                environment: environment,
                timeoutMs: timeoutMs,
                description: (input["description"] as? String).nilIfBlank ?? command
            )
            return jsonString(["task_id": id, "status": "running", "description": command], pretty: true)
        }
        let result = try await runShellCommand(command: command, cwd: cwd, environment: environment, timeoutMs: timeoutMs)
        return shellResultText(result)
    }

    private static func awaitTask(inputJSON: String) async throws -> String {
        let input = try inputObject(from: inputJSON)
        let taskId = try requiredString("task_id", input: input)
        let block = input["block"] as? Bool ?? true
        let timeoutMs = max(0, min(input["timeout"] as? Int ?? 30_000, 600_000))
        return try await AgentBackgroundTaskStore.shared.output(taskId: taskId, block: block, timeoutMs: timeoutMs)
    }

    private static func webSearch(inputJSON: String, context: AgentRunContext) async throws -> String {
        let input = try inputObject(from: inputJSON)
        let query = try requiredString("query", input: input)
        let gl = (input["gl"] as? String).nilIfBlank
        let config = WebSearchRuntimeConfig(values: context.nativeConfigValues)
        guard config.apiKey != nil || (config.provider == "custom" && config.customAuth == "none") else {
            throw ProviderClientError.toolExecution("WebSearch is not configured. Set tools.webSearch.apiKey or the provider-specific environment variable.")
        }

        switch config.provider {
        case "tavily":
            return try await performTavilyWebSearch(query: query, config: config)
        case "custom":
            return try await performCustomWebSearch(query: query, gl: gl, config: config)
        default:
            return try await performGlmWebSearch(query: query, config: config)
        }
    }

    private static func webFetch(inputJSON: String, context: AgentRunContext) async throws -> String {
        throw ProviderClientError.toolExecution("WebFetch is disabled. Use WebSearch for source-grounded web evidence.")
    }

    private struct WebSearchRuntimeConfig {
        static let defaultGlmEndpoint = "https://api.z.ai/api/paas/v4/web_search"
        static let defaultTavilyEndpoint = "https://api.tavily.com/search"

        var provider: String
        var endpoint: String
        var apiKey: String?
        var timeoutMs: Int
        var organicLimit: Int
        var customName: String
        var customAuth: String
        var customMethod: String
        var customQueryParam: String
        var customAPIKeyParam: String
        var customResultsPath: String
        var customTitleField: String
        var customURLField: String
        var customSnippetField: String
        var customSourceField: String
        var customPublishedAtField: String

        init(values: [String: String], environment: [String: String] = ProcessInfo.processInfo.environment) {
            let rawProvider = values["tools.webSearch.provider"]?.nilIfBlank?.lowercased() ?? "glm"
            provider = ["glm", "tavily", "custom"].contains(rawProvider) ? rawProvider : "glm"
            timeoutMs = Self.clampedInt(values["tools.webSearch.timeoutMs"], defaultValue: 30_000, min: 1_000, max: 120_000)
            organicLimit = Self.clampedInt(values["tools.webSearch.organicLimit"], defaultValue: 8, min: 1, max: 50)
            customName = values["tools.webSearch.customProvider.name"]?.nilIfBlank ?? "custom"
            customAuth = values["tools.webSearch.customProvider.auth"]?.nilIfBlank ?? "bearer"
            customMethod = (values["tools.webSearch.customProvider.method"]?.nilIfBlank ?? "POST").uppercased()
            customQueryParam = values["tools.webSearch.customProvider.queryParam"]?.nilIfBlank ?? "query"
            customAPIKeyParam = values["tools.webSearch.customProvider.apiKeyParam"]?.nilIfBlank ?? "api_key"
            customResultsPath = values["tools.webSearch.customProvider.resultsPath"]?.nilIfBlank ?? ""
            customTitleField = values["tools.webSearch.customProvider.titleField"]?.nilIfBlank ?? "title"
            customURLField = values["tools.webSearch.customProvider.urlField"]?.nilIfBlank ?? "url"
            customSnippetField = values["tools.webSearch.customProvider.snippetField"]?.nilIfBlank ?? "snippet"
            customSourceField = values["tools.webSearch.customProvider.sourceField"]?.nilIfBlank ?? "source"
            customPublishedAtField = values["tools.webSearch.customProvider.publishedAtField"]?.nilIfBlank ?? "publishedAt"

            let configuredEndpoint = values["tools.webSearch.endpoint"]?.nilIfBlank
            if provider == "tavily" {
                endpoint = configuredEndpoint == Self.defaultGlmEndpoint ? Self.defaultTavilyEndpoint : (configuredEndpoint ?? Self.defaultTavilyEndpoint)
            } else if provider == "custom" {
                let defaultEndpoints = [Self.defaultGlmEndpoint, Self.defaultTavilyEndpoint]
                endpoint = configuredEndpoint.flatMap { defaultEndpoints.contains($0) ? nil : $0 } ?? ""
            } else if let configuredEndpoint {
                endpoint = configuredEndpoint
            } else {
                endpoint = environment["GLM_WEB_SEARCH_ENDPOINT"]?.nilIfBlank ?? Self.defaultGlmEndpoint
            }

            let configuredKey = values["tools.webSearch.apiKey"]?.nilIfBlank
            switch provider {
            case "tavily":
                apiKey = configuredKey ?? environment["TAVILY_API_KEY"]?.nilIfBlank
            case "custom":
                apiKey = configuredKey ?? environment["CUSTOM_WEB_SEARCH_API_KEY"]?.nilIfBlank
            default:
                apiKey = configuredKey
                    ?? environment["GLM_WEB_SEARCH_API_KEY"]?.nilIfBlank
                    ?? environment["ZAI_API_KEY"]?.nilIfBlank
            }
        }

        private static func clampedInt(_ rawValue: String?, defaultValue: Int, min: Int, max: Int) -> Int {
            guard let value = rawValue.flatMap(Int.init) else { return defaultValue }
            return Swift.max(min, Swift.min(max, value))
        }
    }

    private static func performGlmWebSearch(query: String, config: WebSearchRuntimeConfig) async throws -> String {
        guard let apiKey = config.apiKey else {
            throw ProviderClientError.toolExecution("GLM web search requires tools.webSearch.apiKey or GLM_WEB_SEARCH_API_KEY/ZAI_API_KEY.")
        }
        let payload: [String: Any] = [
            "search_engine": "search-prime",
            "search_query": query,
            "count": config.organicLimit,
            "search_recency_filter": "noLimit",
        ]
        let raw = try await performJSONRequest(
            endpoint: config.endpoint,
            method: "POST",
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Content-Type": "application/json",
                "Accept": "application/json",
            ],
            body: payload,
            timeoutMs: config.timeoutMs,
            providerName: "glm"
        )
        try throwIfSearchError(raw, providerName: "GLM web search")
        let organic = mappedResults(
            extractResultItems(raw),
            limit: config.organicLimit,
            titleFields: ["title", "name"],
            urlFields: ["url", "link", "href"],
            snippetFields: ["snippet", "summary", "content", "text"],
            sourceFields: ["source", "site", "media"],
            publishedAtFields: ["publishedAt", "published_at", "publish_date", "date"]
        )
        return webSearchOutput(query: query, provider: "glm", endpoint: config.endpoint, organic: organic)
    }

    private static func performTavilyWebSearch(query: String, config: WebSearchRuntimeConfig) async throws -> String {
        guard let apiKey = config.apiKey else {
            throw ProviderClientError.toolExecution("Tavily search requires tools.webSearch.apiKey or TAVILY_API_KEY.")
        }
        let raw = try await performJSONRequest(
            endpoint: config.endpoint,
            method: "POST",
            headers: [
                "Content-Type": "application/json",
                "Accept": "application/json",
            ],
            body: [
                "api_key": apiKey,
                "query": query,
                "max_results": config.organicLimit,
                "include_answer": true,
                "search_depth": "basic",
            ],
            timeoutMs: config.timeoutMs,
            providerName: "tavily"
        )
        try throwIfSearchError(raw, providerName: "Tavily search")
        let rawResults = raw["results"] as? [[String: Any]] ?? []
        let organic = rawResults.prefix(config.organicLimit).map { entry in
            [
                "title": stringValue(entry["title"]) ?? "",
                "link": stringValue(entry["url"]) ?? "",
                "snippet": stringValue(entry["content"]) ?? "",
                "source": stringValue(entry["url"]) ?? "",
            ]
        }
        var extra: [String: Any] = [:]
        if let answer = stringValue(raw["answer"]), !answer.isEmpty {
            extra["answerBox"] = ["answer": answer]
        }
        return webSearchOutput(query: query, provider: "tavily", endpoint: config.endpoint, organic: Array(organic), extra: extra)
    }

    private static func performCustomWebSearch(query: String, gl: String?, config: WebSearchRuntimeConfig) async throws -> String {
        guard !config.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderClientError.toolExecution("Custom web search requires tools.webSearch.endpoint.")
        }
        guard var url = URL(string: config.endpoint) else {
            throw ProviderClientError.toolExecution("Invalid custom web search endpoint: \(config.endpoint)")
        }
        var headers = ["Accept": "application/json"]
        var body: [String: Any] = [:]
        let method = config.customMethod == "GET" ? "GET" : "POST"

        if method == "GET" {
            url.appendQueryItem(name: config.customQueryParam, value: query)
            if let gl { url.appendQueryItem(name: "gl", value: gl) }
        } else {
            headers["Content-Type"] = "application/json"
            body[config.customQueryParam] = query
            if let gl { body["gl"] = gl }
        }

        if config.customAuth == "bearer", let apiKey = config.apiKey {
            headers["Authorization"] = "Bearer \(apiKey)"
        } else if config.customAuth == "queryApiKey", let apiKey = config.apiKey {
            url.appendQueryItem(name: config.customAPIKeyParam, value: apiKey)
        } else if config.customAuth == "bodyApiKey", let apiKey = config.apiKey {
            if method == "GET" {
                url.appendQueryItem(name: config.customAPIKeyParam, value: apiKey)
            } else {
                body[config.customAPIKeyParam] = apiKey
            }
        }

        let raw = try await performJSONRequest(
            endpoint: url.absoluteString,
            method: method,
            headers: headers,
            body: method == "POST" ? body : nil,
            timeoutMs: config.timeoutMs,
            providerName: config.customName
        )
        try throwIfSearchError(raw, providerName: config.customName)
        let resultValue: Any? = config.customResultsPath.isEmpty ? extractResultItems(raw) : readPath(raw, path: config.customResultsPath)
        let organic = mappedResults(
            resultValue as? [[String: Any]] ?? extractResultItems(resultValue),
            limit: config.organicLimit,
            titleFields: [config.customTitleField],
            urlFields: [config.customURLField],
            snippetFields: [config.customSnippetField],
            sourceFields: [config.customSourceField],
            publishedAtFields: [config.customPublishedAtField]
        )
        return webSearchOutput(query: query, provider: "custom", endpoint: config.endpoint, organic: organic, extra: ["providerName": config.customName])
    }

    private static func performJSONRequest(
        endpoint: String,
        method: String,
        headers: [String: String],
        body: [String: Any]?,
        timeoutMs: Int,
        providerName: String
    ) async throws -> [String: Any] {
        guard let url = URL(string: endpoint) else {
            throw ProviderClientError.toolExecution("Invalid \(providerName) web search endpoint: \(endpoint)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = TimeInterval(timeoutMs) / 1000
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ProviderClientError.transport("web_search (\(providerName)) request failed: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProviderClientError.invalidResponse
        }
        guard 200..<300 ~= http.statusCode else {
            let detail = String(data: data, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw ProviderClientError.toolExecution("\(providerName) web search error (\(http.statusCode)): \(String(detail.prefix(500)))")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderClientError.toolExecution("\(providerName) web search returned non-object JSON.")
        }
        return object
    }

    private static func throwIfSearchError(_ raw: [String: Any], providerName: String) throws {
        if let error = stringValue(raw["error"]), !error.isEmpty {
            throw ProviderClientError.toolExecution("\(providerName) error: \(error)")
        }
        if let code = raw["code"] as? NSNumber, code.intValue != 0 {
            let message = stringValue(raw["msg"]) ?? stringValue(raw["message"]) ?? "search provider error"
            throw ProviderClientError.toolExecution("\(providerName) error code=\(code): \(message)")
        }
    }

    private static func webSearchOutput(
        query: String,
        provider: String,
        endpoint: String,
        organic: [[String: Any]],
        extra: [String: Any] = [:]
    ) -> String {
        var output: [String: Any] = [
            "ok": true,
            "status": "ok",
            "query": query,
            "provider": provider,
            "endpoint": endpoint,
            "organic": organic,
            "results": organic,
        ]
        for (key, value) in extra {
            output[key] = value
        }
        return jsonString(output, pretty: true)
    }

    private static func extractResultItems(_ value: Any?) -> [[String: Any]] {
        if let array = value as? [[String: Any]] {
            return array
        }
        guard let object = value as? [String: Any] else {
            return []
        }
        for key in ["search_result", "results", "items", "webPages", "data"] {
            if let array = object[key] as? [[String: Any]] {
                return array
            }
            if let nested = object[key] as? [String: Any] {
                let child = extractResultItems(nested)
                if !child.isEmpty {
                    return child
                }
            }
        }
        return []
    }

    private static func mappedResults(
        _ entries: [[String: Any]],
        limit: Int,
        titleFields: [String],
        urlFields: [String],
        snippetFields: [String],
        sourceFields: [String],
        publishedAtFields: [String]
    ) -> [[String: Any]] {
        entries.prefix(limit).map { entry in
            var result: [String: Any] = [
                "title": firstMappedString(entry, fields: titleFields) ?? "",
                "link": firstMappedString(entry, fields: urlFields) ?? "",
                "snippet": firstMappedString(entry, fields: snippetFields) ?? "",
                "source": firstMappedString(entry, fields: sourceFields) ?? "",
            ]
            if let publishedAt = firstMappedString(entry, fields: publishedAtFields) {
                result["publishedAt"] = publishedAt
            }
            return result
        }
    }

    private static func firstMappedString(_ object: [String: Any], fields: [String]) -> String? {
        for field in fields {
            if let value = stringValue(readPath(object, path: field)) {
                return value
            }
        }
        return nil
    }

    private static func readPath(_ value: Any?, path: String) -> Any? {
        let parts = path.split(separator: ".").map(String.init)
        guard !parts.isEmpty else { return nil }
        var current = value
        for part in parts {
            guard let object = current as? [String: Any] else { return nil }
            current = object[part]
        }
        return current
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            return string.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private static func readLints(inputJSON: String, context: AgentRunContext) async throws -> String {
        let input = try inputObject(from: inputJSON)
        let limit = max(1, min(input["limit"] as? Int ?? 100, 500))
        let severityFilter = (input["severity"] as? String).nilIfBlank?.lowercased()
        let scopedPath = (input["path"] as? String).nilIfBlank ?? "."
        _ = try AgentPathResolver.resolve(scopedPath, workspacePath: context.workspacePath, mustExist: true)
        guard let command = context.nativeConfigValues["lint.command"].nilIfBlank else {
            return jsonString(["diagnostics": [], "message": "No native lint.command is configured and no live LSP diagnostics are available."], pretty: true)
        }
        let result = try await runShellCommand(
            command: command,
            cwd: context.workspacePath,
            environment: SkillRuntimeService.environment(configValues: context.nativeConfigValues),
            timeoutMs: 120_000
        )
        let diagnostics = parseLintDiagnostics(result.stdout + "\n" + result.stderr, severity: severityFilter, limit: limit)
        return jsonString([
            "diagnostics": diagnostics,
            "exitCode": result.exitCode,
            "truncated": diagnostics.count >= limit,
        ], pretty: true)
    }

    private static func runTask(inputJSON: String, context: AgentRunContext) async throws -> String {
        guard context.subagentDepth < context.maxSubagentDepth else {
            throw ProviderClientError.toolExecution("subagent_depth_exceeded (depth=\(context.subagentDepth), max=\(context.maxSubagentDepth)); nested Task is not allowed.")
        }
        let input = try inputObject(from: inputJSON)
        let prompt = try requiredString("prompt", input: input)
        let type = ((input["type"] as? String) ?? "generalPurpose").trimmingCharacters(in: .whitespacesAndNewlines)
        let description = (input["description"] as? String).nilIfBlank ?? type
        if input["run_in_background"] as? Bool == true {
            let n = input["n"] as? Int
            let timeout = input["timeout"] as? Int
            let cwd = (input["cwd"] as? String).nilIfBlank
            let isolation = (input["isolation"] as? String).nilIfBlank
            let id = AgentBackgroundTaskStore.shared.startAsync(description: description) {
                var taskInput: [String: Any] = ["description": description]
                if let n { taskInput["n"] = n }
                if let timeout { taskInput["timeout"] = timeout }
                if let cwd { taskInput["cwd"] = cwd }
                if let isolation { taskInput["isolation"] = isolation }
                return (try? await runTaskSynchronously(type: type, prompt: prompt, input: taskInput, context: context)) ?? "Task failed."
            }
            return jsonString(["task_id": id, "status": "running", "description": description], pretty: true)
        }
        return try await runTaskSynchronously(type: type, prompt: prompt, input: input, context: context)
    }

    private static func readImage(url: URL, workspacePath: String) throws -> String {
        let data = try Data(contentsOf: url)
        guard let mime = imageMimeType(for: url) else {
            throw ProviderClientError.toolExecution("Unsupported image type: \(url.pathExtension)")
        }
        return jsonString([
            "type": "image",
            "file": [
                "filePath": AgentPathResolver.relativePath(url, workspacePath: workspacePath),
                "mediaType": mime,
                "originalSize": data.count,
                "base64": data.base64EncodedString(),
            ],
        ], pretty: true)
    }

    private static func readPDF(url: URL, workspacePath: String, pages: String?) throws -> String {
        let data = try Data(contentsOf: url)
        guard let document = PDFDocument(data: data) else {
            throw ProviderClientError.toolExecution("Unable to parse PDF: \(url.lastPathComponent)")
        }
        let pageNumbers = parsePDFPages(pages, total: document.pageCount)
        var sections = [
            "PDF \(AgentPathResolver.relativePath(url, workspacePath: workspacePath))",
            "pages: \(document.pageCount)",
            "selected: \(pageNumbers.map(String.init).joined(separator: ","))",
            "",
        ]
        for number in pageNumbers {
            guard let page = document.page(at: number - 1) else { continue }
            sections.append("## Page \(number)")
            sections.append(page.string?.nilIfBlank ?? "(no extractable text)")
            sections.append("")
        }
        return sections.joined(separator: "\n")
    }

    private static func readNotebook(url: URL, workspacePath: String) throws -> String {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cells = object["cells"] as? [[String: Any]] else {
            throw ProviderClientError.toolExecution("Notebook JSON must contain a cells array.")
        }
        var output = ["Notebook \(AgentPathResolver.relativePath(url, workspacePath: workspacePath))", "cells: \(cells.count)", ""]
        for (index, cell) in cells.enumerated() {
            let type = cell["cell_type"] as? String ?? "unknown"
            let source = notebookSourceString(cell["source"])
            output.append("## Cell \(index) [\(type)]")
            output.append(source.isEmpty ? "(empty)" : String(source.prefix(4_000)))
            output.append("")
        }
        return output.joined(separator: "\n")
    }

    private static func imageMimeType(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return nil
        }
    }

    private static func parsePDFPages(_ value: String?, total: Int) -> [Int] {
        guard total > 0 else { return [] }
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return Array(1...min(total, 10)) }
        var pages = Set<Int>()
        for part in trimmed.split(separator: ",") {
            let bounds = part.split(separator: "-", maxSplits: 1).compactMap { Int(String($0).trimmingCharacters(in: .whitespaces)) }
            if bounds.count == 2 {
                for page in min(bounds[0], bounds[1])...max(bounds[0], bounds[1]) where page >= 1 && page <= total {
                    pages.insert(page)
                }
            } else if let page = bounds.first, page >= 1, page <= total {
                pages.insert(page)
            }
        }
        return Array(pages).sorted().prefix(10).map { $0 }
    }

    private static func notebookCellIndex(input: [String: Any], cells: [[String: Any]], allowEndForInsert: Bool) throws -> Int {
        if let cellID = (input["cell_id"] as? String).nilIfBlank,
           let index = cells.firstIndex(where: { ($0["id"] as? String) == cellID }) {
            return allowEndForInsert ? index + 1 : index
        }
        if let number = input["cell_number"] as? Int {
            if allowEndForInsert, number == cells.count { return number }
            guard cells.indices.contains(number) else {
                throw ProviderClientError.toolExecution("Notebook cell_number out of range: \(number)")
            }
            return number
        }
        if allowEndForInsert {
            return cells.count
        }
        throw ProviderClientError.toolExecution("EditNotebook requires cell_id or cell_number for replace/delete.")
    }

    private static func notebookSourceArray(_ source: String) -> [String] {
        let parts = source.components(separatedBy: "\n")
        guard !parts.isEmpty else { return [""] }
        return parts.enumerated().map { index, line in
            index == parts.count - 1 ? line : line + "\n"
        }
    }

    private static func notebookSourceString(_ source: Any?) -> String {
        if let value = source as? String { return value }
        if let lines = source as? [String] { return lines.joined() }
        return ""
    }

    private static func runRipgrep(input: [String: Any], pattern: String, root: URL, workspacePath: String) throws -> String? {
        guard let rg = executableURL(named: "rg") else { return nil }
        let outputMode = (input["output_mode"] as? String).nilIfBlank ?? "files_with_matches"
        var args = ["--color", "never"]
        switch outputMode {
        case "content":
            args.append("--line-number")
        case "count":
            args.append("--count")
        default:
            args.append("--files-with-matches")
        }
        if let glob = (input["glob"] as? String).nilIfBlank ?? (input["include"] as? String).nilIfBlank {
            args.append(contentsOf: ["--glob", glob])
        }
        if input["-i"] as? Bool == true { args.append("-i") }
        if input["multiline"] as? Bool == true { args.append(contentsOf: ["-U", "--multiline-dotall"]) }
        if let type = (input["type"] as? String).nilIfBlank { args.append(contentsOf: ["--type", type]) }
        if let context = input["context"] as? Int ?? input["-C"] as? Int { args.append(contentsOf: ["-C", "\(context)"]) }
        if let before = input["-B"] as? Int { args.append(contentsOf: ["-B", "\(before)"]) }
        if let after = input["-A"] as? Int { args.append(contentsOf: ["-A", "\(after)"]) }
        args.append(contentsOf: ["--", pattern, root.path])
        let result = try runProcessSync(
            executable: rg.path,
            arguments: args,
            cwd: workspacePath,
            environment: ProcessInfo.processInfo.environment,
            timeoutMs: 30_000
        )
        guard result.exitCode == 0 || result.exitCode == 1 else { return nil }
        let lines = result.stdout.components(separatedBy: .newlines).filter { !$0.isEmpty }
        let normalized = lines.map { line in
            line.replacingOccurrences(of: workspacePath + "/", with: "")
        }
        let offset = max(input["offset"] as? Int ?? 0, 0)
        let headLimit = input["head_limit"] as? Int ?? 250
        let sliced = normalized.dropFirst(offset).prefix(headLimit == 0 ? normalized.count : max(headLimit, 1))
        return sliced.isEmpty ? "No matches for \(pattern)." : sliced.joined(separator: "\n")
    }

    private static func executableURL(named name: String) -> URL? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":")
            .map(String.init)
        for path in paths {
            let url = URL(fileURLWithPath: path).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private static func semanticTerms(_ query: String) -> [String] {
        query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
    }

    private static func score(_ text: String, terms: [String]) -> Int {
        terms.reduce(0) { partial, term in
            partial + (text.contains(term) ? 1 : 0)
        }
    }

    private static func shellTimeoutMilliseconds(_ input: [String: Any]) -> Int {
        if let timeout = input["timeout"] as? Int {
            return max(1_000, min(timeout, 600_000))
        }
        if let timeoutSeconds = input["timeout_seconds"] as? Int {
            return max(1_000, min(timeoutSeconds * 1_000, 600_000))
        }
        return 120_000
    }

    private static func runShellCommand(command: String, cwd: String, environment: [String: String], timeoutMs: Int) async throws -> AgentShellRunResult {
        try await runProcess(
            executable: "/bin/zsh",
            arguments: ["-lc", command],
            cwd: cwd,
            environment: environment,
            timeoutMs: timeoutMs
        )
    }

    private static func runProcess(
        executable: String,
        arguments: [String],
        cwd: String,
        environment: [String: String],
        timeoutMs: Int
    ) async throws -> AgentShellRunResult {
        try await Task.detached {
            try runProcessSync(executable: executable, arguments: arguments, cwd: cwd, environment: environment, timeoutMs: timeoutMs)
        }.value
    }

    static func validatedWorkingDirectory(_ cwd: String) throws -> URL {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = NSString(string: trimmed).expandingTildeInPath
        guard !expanded.isEmpty, expanded.hasPrefix("/") else {
            throw ProviderClientError.toolExecution("Workspace path must be an absolute path: \(cwd). Check PilotDeck general workspace settings.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProviderClientError.toolExecution("Workspace path does not exist: \(expanded). Check PilotDeck general workspace settings.")
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    private static func runProcessSync(
        executable: String,
        arguments: [String],
        cwd: String,
        environment: [String: String],
        timeoutMs: Int
    ) throws -> AgentShellRunResult {
        let started = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = try validatedWorkingDirectory(cwd)
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        var timedOut = false
        let deadline = Date().addingTimeInterval(Double(max(timeoutMs, 1)) / 1_000.0)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            timedOut = true
            process.terminate()
        }
        process.waitUntilExit()
        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return AgentShellRunResult(
            stdout: out,
            stderr: err,
            exitCode: Int(process.terminationStatus),
            timedOut: timedOut,
            durationMs: Int(Date().timeIntervalSince(started) * 1000)
        )
    }

    static func shellResultText(_ result: AgentShellRunResult) -> String {
        var parts = ["exit code: \(result.exitCode)"]
        if result.timedOut { parts.append("timed out") }
        if !result.stdout.isEmpty { parts.append(result.stdout.trimmingCharacters(in: .newlines)) }
        if !result.stderr.isEmpty { parts.append(result.stderr.trimmingCharacters(in: .newlines)) }
        return parts.joined(separator: "\n")
    }

    private static func stringArray(_ value: Any?) -> [String] {
        (value as? [String]) ?? []
    }

    private static func extractFetchedText(data: Data, url: URL) -> String {
        if url.pathExtension.lowercased() == "pdf", let document = PDFDocument(data: data) {
            return (0..<document.pageCount)
                .compactMap { document.page(at: $0)?.string }
                .joined(separator: "\n\n")
        }
        let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        if raw.range(of: "<html", options: [.caseInsensitive]) != nil || raw.range(of: "<body", options: [.caseInsensitive]) != nil {
            return stripHTML(raw)
        }
        return raw
    }

    private static func stripHTML(_ html: String) -> String {
        html
            .replacingOccurrences(of: #"(?is)<script.*?</script>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)<style.*?</style>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?s)<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func applyFetchPrompt(_ prompt: String, content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = prompt.lowercased()
        let maxLength = lower.contains("full") || lower.contains("完整") ? 30_000 : 12_000
        return String(trimmed.prefix(maxLength))
    }

    private static func parseLintDiagnostics(_ output: String, severity: String?, limit: Int) -> [[String: Any]] {
        let pattern = #"^(.+?):(\d+):(?:(\d+):)?\s*(?:(error|warning|info|note):)?\s*(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        var diagnostics: [[String: Any]] = []
        for line in output.components(separatedBy: .newlines) {
            let nsLine = line as NSString
            guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)),
                  match.numberOfRanges >= 6 else { continue }
            let level = match.range(at: 4).location == NSNotFound ? "error" : nsLine.substring(with: match.range(at: 4)).lowercased()
            if let severity, level != severity { continue }
            diagnostics.append([
                "file": nsLine.substring(with: match.range(at: 1)),
                "line": Int(nsLine.substring(with: match.range(at: 2))) ?? 0,
                "column": match.range(at: 3).location == NSNotFound ? 0 : (Int(nsLine.substring(with: match.range(at: 3))) ?? 0),
                "severity": level,
                "message": nsLine.substring(with: match.range(at: 5)),
            ])
            if diagnostics.count >= limit { break }
        }
        return diagnostics
    }

    private static func runTaskSynchronously(type: String, prompt: String, input: [String: Any], context: AgentRunContext) async throws -> String {
        let normalizedType = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let scopedContext = try taskScopedContext(input: input, context: context)
        switch normalizedType {
        case "shell":
            return try await shell(
                inputJSON: jsonString([
                    "command": prompt,
                    "description": (input["description"] as? String) ?? "Task shell command",
                    "timeout": input["timeout"] as? Int ?? 120_000,
                ]),
                context: scopedContext
            )
        case "best-of-n-runner":
            let n = max(1, min(input["n"] as? Int ?? 3, 8))
            var results: [[String: Any]] = []
            for index in 1...n {
                let result = try await withIsolatedGitWorktree(workspacePath: scopedContext.workspacePath) { worktreePath in
                    let isolatedContext = childContext(from: scopedContext, workspacePath: worktreePath)
                    let taskContext = subagentContext(from: isolatedContext)
                    return try await NativeAgentRuntime.runSubagent(
                        inputJSON: jsonString([
                            "prompt": "\(prompt)\n\nAttempt \(index) of \(n). Use this isolated git worktree and return the best concise result.",
                            "description": "best-of-n \(index)",
                            "context": "Task isolation: git worktree at \(worktreePath)",
                        ]),
                        context: taskContext
                    )
                }
                results.append(["attempt": index, "worktree": result.worktreePath, "result": result.output])
            }
            return jsonString(["type": type, "attempts": results, "selectedAttempt": 1], pretty: true)
        case "explore", "cursor-guide", "ci-investigator", "generalpurpose", "general-purpose", "general_purpose":
            if ((input["isolation"] as? String) ?? "").lowercased() == "worktree" {
                let result = try await withIsolatedGitWorktree(workspacePath: scopedContext.workspacePath) { worktreePath in
                    let isolatedContext = childContext(from: scopedContext, workspacePath: worktreePath)
                    let taskContext = subagentContext(from: isolatedContext)
                    return try await NativeAgentRuntime.runSubagent(
                        inputJSON: jsonString([
                            "prompt": prompt,
                            "description": (input["description"] as? String) ?? type,
                            "context": "Task type: \(type)\nTask isolation: git worktree at \(worktreePath)",
                        ]),
                        context: taskContext
                    )
                }
                return jsonString(["type": type, "worktree": result.worktreePath, "result": result.output], pretty: true)
            }
            return try await NativeAgentRuntime.runSubagent(
                inputJSON: jsonString([
                    "prompt": prompt,
                    "description": (input["description"] as? String) ?? type,
                    "context": "Task type: \(type)",
                ]),
                context: subagentContext(from: scopedContext)
            )
        default:
            throw ProviderClientError.toolExecution("Unsupported Task type: \(type)")
        }
    }

    private static func taskScopedContext(input: [String: Any], context: AgentRunContext) throws -> AgentRunContext {
        guard let cwd = (input["cwd"] as? String).nilIfBlank else { return context }
        let url = try AgentPathResolver.resolve(cwd, workspacePath: context.workspacePath, mustExist: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProviderClientError.toolExecution("Task cwd must be an existing directory: \(cwd)")
        }
        return childContext(from: context, workspacePath: url.path)
    }

    private static func childContext(from context: AgentRunContext, workspacePath: String) -> AgentRunContext {
        let request = AgentRequest(
            sessionId: context.sessionId,
            projectPath: workspacePath,
            prompt: "delegated task",
            providerConfig: context.providerConfig,
            apiKey: context.apiKey,
            priorMessages: [],
            timeoutMs: context.timeoutMs,
            contextWindow: context.contextWindow,
            permissionMode: context.permissionMode,
            runMode: context.runMode,
            workspaceContext: nil,
            toolSettings: context.toolSettings,
            routerRoute: "task",
            nativeConfigValues: context.nativeConfigValues,
            permissionHandler: nil
        )
        let child = AgentRunContext(request: request)
        child.planExited = context.planExited
        child.planQuestionAnswered = context.planQuestionAnswered
        child.planWorkflowStage = context.planWorkflowStage
        child.planQuestionRecoveryCount = context.planQuestionRecoveryCount
        child.planGenerationRecoveryCount = context.planGenerationRecoveryCount
        child.planExecutionApproved = context.planExecutionApproved
        child.todosJSON = context.todosJSON
        child.workspaceMutationEpoch = context.workspaceMutationEpoch
        child.subagentDepth = context.subagentDepth
        child.maxSubagentDepth = context.maxSubagentDepth
        return child
    }

    private static func subagentContext(from context: AgentRunContext) -> AgentRunContext {
        let child = childContext(from: context, workspacePath: context.workspacePath)
        child.subagentDepth = context.subagentDepth + 1
        child.maxSubagentDepth = context.maxSubagentDepth
        return child
    }

    private static func withIsolatedGitWorktree(
        workspacePath: String,
        operation: (String) async throws -> String
    ) async throws -> (worktreePath: String, output: String) {
        let environment = SkillRuntimeService.environment(configValues: [:])
        let repoRoot = try gitOutput(
            arguments: ["-C", workspacePath, "rev-parse", "--show-toplevel"],
            cwd: workspacePath,
            environment: environment
        )
        _ = try gitOutput(
            arguments: ["-C", repoRoot, "rev-parse", "--verify", "HEAD"],
            cwd: repoRoot,
            environment: environment
        )
        let parent = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("g9claw-worktrees", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let worktree = parent.appendingPathComponent("worktree-\(UUID().uuidString)", isDirectory: true)
        let add = try runProcessSync(
            executable: "/usr/bin/env",
            arguments: ["git", "-C", repoRoot, "worktree", "add", "--detach", worktree.path, "HEAD"],
            cwd: repoRoot,
            environment: environment,
            timeoutMs: 120_000
        )
        guard add.exitCode == 0 else {
            throw ProviderClientError.toolExecution(shellResultText(add))
        }
        defer {
            _ = try? runProcessSync(
                executable: "/usr/bin/env",
                arguments: ["git", "-C", repoRoot, "worktree", "remove", "--force", worktree.path],
                cwd: repoRoot,
                environment: environment,
                timeoutMs: 120_000
            )
            try? FileManager.default.removeItem(at: worktree)
        }
        let output = try await operation(worktree.path)
        return (worktree.path, output)
    }

    private static func gitOutput(arguments: [String], cwd: String, environment: [String: String]) throws -> String {
        let result = try runProcessSync(
            executable: "/usr/bin/env",
            arguments: ["git"] + arguments,
            cwd: cwd,
            environment: environment,
            timeoutMs: 30_000
        )
        guard result.exitCode == 0 else {
            throw ProviderClientError.toolExecution(shellResultText(result))
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func todoWrite(inputJSON: String, context: AgentRunContext) throws -> String {
        let input = try inputObject(from: inputJSON)
        guard let todos = input["todos"] else {
            throw ProviderClientError.toolExecution("TodoWrite requires todos.")
        }
        context.todosJSON = jsonString(todos, pretty: true)
        return "Todos have been modified successfully. Ensure that you continue to use the todo list to track your progress. Please proceed with the current tasks if applicable."
    }

    static func requiredString(_ key: String, input: [String: Any]) throws -> String {
        guard let value = input[key] as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderClientError.toolExecution("Missing required string: \(key)")
        }
        return value
    }

    private static func limitOutput(_ output: String) -> String {
        if output.count <= 20_000 { return output }
        return String(output.prefix(20_000)) + "\n... output truncated ..."
    }
}

struct AgentShellRunResult: Sendable, Equatable {
    var stdout: String
    var stderr: String
    var exitCode: Int
    var timedOut: Bool
    var durationMs: Int
}

final class AgentBackgroundTaskRecord: @unchecked Sendable {
    let id: String
    let description: String
    let startedAt: Date
    var status: String
    var output: String
    var stdout: String
    var stderr: String
    var exitCode: Int?
    var completedAt: Date?
    var process: Process?

    init(id: String, description: String, status: String = "running", process: Process? = nil) {
        self.id = id
        self.description = description
        self.startedAt = Date()
        self.status = status
        self.output = ""
        self.stdout = ""
        self.stderr = ""
        self.process = process
    }
}

final class AgentBackgroundTaskStore: @unchecked Sendable {
    static let shared = AgentBackgroundTaskStore()
    private let lock = NSLock()
    private var records: [String: AgentBackgroundTaskRecord] = [:]

    func startShell(command: String, cwd: String, environment: [String: String], timeoutMs: Int, description: String) throws -> String {
        let id = "task-\(UUID().uuidString)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = try AgentToolExecutor.validatedWorkingDirectory(cwd)
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let record = AgentBackgroundTaskRecord(id: id, description: description, process: process)
        lock.withLock { records[id] = record }
        try process.run()
        Task.detached { [weak self] in
            let started = Date()
            let deadline = Date().addingTimeInterval(Double(max(timeoutMs, 1)) / 1_000.0)
            var timedOut = false
            while process.isRunning, Date() < deadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            if process.isRunning {
                timedOut = true
                process.terminate()
            }
            process.waitUntilExit()
            let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let result = AgentShellRunResult(
                stdout: out,
                stderr: err,
                exitCode: Int(process.terminationStatus),
                timedOut: timedOut,
                durationMs: Int(Date().timeIntervalSince(started) * 1000)
            )
            self?.complete(
                id: id,
                output: AgentToolExecutor.shellResultText(result),
                stdout: result.stdout,
                stderr: result.stderr,
                exitCode: result.exitCode
            )
        }
        return id
    }

    func startAsync(description: String, operation: @escaping @Sendable () async -> String) -> String {
        let id = "task-\(UUID().uuidString)"
        let record = AgentBackgroundTaskRecord(id: id, description: description)
        lock.withLock { records[id] = record }
        Task.detached { [weak self] in
            let output = await operation()
            self?.complete(id: id, output: output, stdout: output, stderr: "", exitCode: 0)
        }
        return id
    }

    func output(taskId: String, block: Bool, timeoutMs: Int) async throws -> String {
        let deadline = Date().addingTimeInterval(Double(max(timeoutMs, 0)) / 1_000.0)
        while true {
            if let snapshot = snapshot(taskId) {
                if snapshot.status != "running" || !block || Date() >= deadline {
                    return jsonString([
                        "task_id": snapshot.id,
                        "description": snapshot.description,
                        "status": snapshot.status,
                        "exitCode": snapshot.exitCode.map { $0 as Any } ?? NSNull(),
                        "stdout": snapshot.stdout,
                        "stderr": snapshot.stderr,
                        "output": snapshot.output,
                    ], pretty: true)
                }
            } else {
                throw ProviderClientError.toolExecution("Background task not found: \(taskId)")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func terminate(sessionId: String? = nil) {
        lock.withLock {
            for record in records.values where record.status == "running" {
                record.process?.terminate()
                record.status = "cancelled"
                record.completedAt = Date()
            }
        }
    }

    private func complete(id: String, output: String, stdout: String, stderr: String, exitCode: Int?) {
        lock.withLock {
            guard let record = records[id] else { return }
            record.output = output
            record.stdout = stdout
            record.stderr = stderr
            record.exitCode = exitCode
            record.status = "completed"
            record.completedAt = Date()
            record.process = nil
        }
    }

    private func snapshot(_ id: String) -> AgentBackgroundTaskRecord? {
        lock.withLock {
            guard let record = records[id] else { return nil }
            let copy = AgentBackgroundTaskRecord(id: record.id, description: record.description)
            copy.status = record.status
            copy.output = record.output
            copy.stdout = record.stdout
            copy.stderr = record.stderr
            copy.exitCode = record.exitCode
            copy.completedAt = record.completedAt
            return copy
        }
    }
}

enum AgentPathResolver {
    static let skippedDirectoryNames = Set([".git", "node_modules", "dist", "build", ".DS_Store"])

    static func resolve(_ rawPath: String, workspacePath: String, mustExist: Bool) throws -> URL {
        let root = URL(fileURLWithPath: NSString(string: workspacePath).expandingTildeInPath).standardizedFileURL
        let expanded = NSString(string: rawPath.trimmingCharacters(in: .whitespacesAndNewlines)).expandingTildeInPath
        let candidate: URL
        if expanded.hasPrefix("/") {
            candidate = URL(fileURLWithPath: expanded).standardizedFileURL
        } else {
            candidate = root.appendingPathComponent(expanded).standardizedFileURL
        }
        let rootPath = root.path
        let path = candidate.path
        guard path == rootPath || path.hasPrefix(rootPath + "/") else {
            throw ProviderClientError.toolExecution("Path escapes workspace: \(rawPath)")
        }
        if mustExist, !FileManager.default.fileExists(atPath: path) {
            throw ProviderClientError.toolExecution("Path does not exist: \(rawPath)")
        }
        for forbidden in WorkspaceService.forbiddenPaths where path == forbidden || path.hasPrefix(forbidden + "/") {
            throw ProviderClientError.toolExecution("Refusing to access system path: \(forbidden)")
        }
        return candidate
    }

    static func relativePath(_ url: URL, workspacePath: String) -> String {
        let root = URL(fileURLWithPath: workspacePath).standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == root ? "." : path.replacingOccurrences(of: root + "/", with: "")
    }

    static func walk(_ root: URL) -> [URL] {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var urls: [URL] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if skippedDirectoryNames.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true { continue }
            urls.append(url)
        }
        return urls
    }

    static func globRegex(_ pattern: String) throws -> NSRegularExpression {
        var regex = "^"
        let chars = Array(pattern)
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "*" {
                if index + 1 < chars.count, chars[index + 1] == "*" {
                    if index + 2 < chars.count, chars[index + 2] == "/" {
                        regex += "(?:.*/)?"
                        index += 3
                    } else {
                        regex += ".*"
                        index += 2
                    }
                } else {
                    regex += "[^/]*"
                    index += 1
                }
            } else if char == "?" {
                regex += "[^/]"
                index += 1
            } else {
                regex += NSRegularExpression.escapedPattern(for: String(char))
                index += 1
            }
        }
        regex += "$"
        return try NSRegularExpression(pattern: regex)
    }
}

private func jsonString(_ value: Any, pretty: Bool = false) -> String {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
          ),
          let string = String(data: data, encoding: .utf8) else {
        return "{}"
    }
    return string
}

private extension Optional where Wrapped == String {
    var nilIfBlank: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension URL {
    mutating func appendQueryItem(name: String, value: String) {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == name }
        items.append(URLQueryItem(name: name, value: value))
        components.queryItems = items
        if let url = components.url {
            self = url
        }
    }
}

typealias ProviderClient = NativeAgentRuntime
