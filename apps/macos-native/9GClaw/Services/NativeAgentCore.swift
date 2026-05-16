import Foundation

enum NativeAgentReference {
    static let codexSourceRoot = "/Users/hx/Workspace/codex"
    static let referenceFiles = [
        "codex-rs/core/src/thread_manager.rs",
        "codex-rs/core/src/codex_thread.rs",
        "codex-rs/core/src/session/session.rs",
        "codex-rs/core/src/state/session.rs",
        "codex-rs/core/src/state/turn.rs",
        "codex-rs/core/src/session/turn.rs",
        "codex-rs/core/src/tools/router.rs",
        "codex-rs/core/src/tools/registry.rs",
        "codex-rs/core/src/unified_exec/process.rs",
    ]
}

actor NativeThreadManager {
    private var sessions: [String: NativeSession] = [:]

    func session(for request: AgentRequest) async -> NativeSession {
        if let existing = sessions[request.sessionId] {
            await existing.updateWorkspacePath(request.projectPath)
            return existing
        }
        let session = NativeSession(
            sessionId: request.sessionId,
            workspacePath: request.projectPath
        )
        sessions[request.sessionId] = session
        return session
    }

    func interrupt(sessionId: String) async {
        await sessions[sessionId]?.interruptActiveTurn(reason: "Interrupted by user.")
    }

    func shutdown() async {
        for session in sessions.values {
            await session.interruptActiveTurn(reason: "Shutting down.")
        }
        sessions.removeAll()
    }
}

actor NativeSession {
    let sessionId: String
    private var workspacePath: String
    private var turns: [String: AgentTurn] = [:]
    private var activeTurn: NativeTurnController?

    init(sessionId: String, workspacePath: String) {
        self.sessionId = sessionId
        self.workspacePath = workspacePath
    }

    func updateWorkspacePath(_ path: String) {
        workspacePath = path
    }

    func startTurn(request: AgentRequest) async -> NativeTurnController {
        if let activeTurn {
            await activeTurn.interrupt(reason: "Superseded by a new turn.")
        }
        let controller = NativeTurnController(
            sessionId: sessionId,
            workspacePath: request.projectPath,
            mode: request.runMode
        )
        activeTurn = controller
        let snapshot = await controller.snapshot()
        turns[snapshot.id] = snapshot
        return controller
    }

    func snapshot() async -> AgentTurnStoreSnapshot {
        if let activeTurn {
            let activeSnapshot = await activeTurn.snapshot()
            turns[activeSnapshot.id] = activeSnapshot
        }
        return AgentTurnStoreSnapshot(
            sessionId: sessionId,
            activeTurnId: activeTurn == nil ? nil : await activeTurn?.turnID(),
            turns: turns.values.sorted { $0.startedAt < $1.startedAt }
        )
    }

    func recordSnapshot(from controller: NativeTurnController) async {
        let snapshot = await controller.snapshot()
        turns[snapshot.id] = snapshot
        if snapshot.status != .inProgress, await activeTurn?.turnID() == snapshot.id {
            activeTurn = nil
        }
    }

    func interruptActiveTurn(reason: String) async {
        guard let activeTurn else { return }
        await activeTurn.interrupt(reason: reason)
        await recordSnapshot(from: activeTurn)
    }
}

actor NativeTurnController {
    let runToken: UUID
    private var turn: AgentTurn
    private var nextSequenceValue = 0
    private var itemIndexByToolCallID: [String: String] = [:]

    init(sessionId: String, workspacePath: String, mode: ChatRunMode) {
        let id = "turn-\(UUID().uuidString)"
        let now = Date()
        runToken = UUID()
        turn = AgentTurn(
            id: id,
            sessionId: sessionId,
            runToken: runToken,
            workspacePath: workspacePath,
            status: .inProgress,
            mode: mode,
            startedAt: now,
            updatedAt: now,
            completedAt: nil,
            items: []
        )
    }

    func turnID() -> String {
        turn.id
    }

    func snapshot() -> AgentTurn {
        turn
    }

    func accepts(runToken candidate: UUID) -> Bool {
        turn.runToken == candidate && turn.status == .inProgress
    }

    func markPlanExited() {
        turn.mode = .agent
        turn.updatedAt = Date()
    }

    func recordUserMessage(_ text: String) -> AgentTurnItem {
        makeItem(kind: .userMessage, status: .completed, title: "User", text: text)
    }

    func recordStatus(_ title: String, text: String = "") -> AgentTurnItem {
        makeItem(kind: .status, status: .inProgress, title: title, text: text)
    }

    func recordAssistantText(_ text: String) -> AgentTurnItem? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return makeItem(kind: .agentMessage, status: .completed, title: "", text: text)
    }

    func recordToolCall(_ call: AgentToolCall) -> AgentTurnItem {
        let item = makeItem(
            kind: itemKind(forTool: call.name),
            status: .inProgress,
            title: call.name,
            text: "",
            toolName: call.name,
            toolInvocation: ToolInvocationPayload(
                callId: call.id,
                toolName: call.name,
                inputJSON: call.inputJSON,
                output: nil,
                isError: false
            )
        )
        itemIndexByToolCallID[call.id] = item.id
        return item
    }

    func recordToolResult(_ result: AgentToolResult) -> (callItem: AgentTurnItem?, resultItem: AgentTurnItem) {
        let now = Date()
        var updatedCall: AgentTurnItem?
        if let itemID = itemIndexByToolCallID[result.callId],
           let index = turn.items.firstIndex(where: { $0.id == itemID }) {
            turn.items[index].status = result.isError ? .failed : .completed
            turn.items[index].text = result.output
            turn.items[index].completedAt = now
            turn.items[index].updatedAt = now
            turn.items[index].toolInvocation?.output = result.output
            turn.items[index].toolInvocation?.isError = result.isError
            updatedCall = turn.items[index]
        }
        let resultItem = makeItem(
            kind: .toolResult,
            status: result.isError ? .failed : .completed,
            title: result.isError ? "\(result.toolName) failed" : "\(result.toolName) result",
            text: result.output,
            toolName: result.toolName,
            toolInvocation: ToolInvocationPayload(
                callId: result.callId,
                toolName: result.toolName,
                inputJSON: "",
                output: result.output,
                isError: result.isError
            )
        )
        return (updatedCall, resultItem)
    }

    func finish() {
        guard turn.status == .inProgress else { return }
        let now = Date()
        for index in turn.items.indices where turn.items[index].status == .inProgress {
            turn.items[index].status = .completed
            turn.items[index].updatedAt = now
            turn.items[index].completedAt = now
        }
        turn.status = .completed
        turn.updatedAt = now
        turn.completedAt = now
    }

    func fail(reason: String) {
        let now = Date()
        for index in turn.items.indices where turn.items[index].status == .inProgress {
            turn.items[index].status = .failed
            turn.items[index].updatedAt = now
            turn.items[index].completedAt = now
        }
        _ = makeItem(kind: .status, status: .failed, title: "Error", text: reason)
        turn.status = .failed
        turn.updatedAt = now
        turn.completedAt = now
    }

    func interrupt(reason: String) {
        let now = Date()
        for index in turn.items.indices where turn.items[index].status == .inProgress {
            turn.items[index].status = .interrupted
            turn.items[index].updatedAt = now
            turn.items[index].completedAt = now
        }
        _ = makeItem(kind: .status, status: .interrupted, title: "Interrupted", text: reason)
        turn.status = .interrupted
        turn.updatedAt = now
        turn.completedAt = now
    }

    private func makeItem(
        kind: AgentTurnItemKind,
        status: AgentTurnItemStatus,
        title: String,
        text: String,
        toolName: String? = nil,
        commandExecution: CommandExecutionPayload? = nil,
        fileChange: FileChangePayload? = nil,
        toolInvocation: ToolInvocationPayload? = nil,
        webSearch: WebSearchPayload? = nil
    ) -> AgentTurnItem {
        nextSequenceValue += 1
        let now = Date()
        let item = AgentTurnItem(
            id: "\(turn.id)-\(nextSequenceValue)",
            sessionId: turn.sessionId,
            turnId: turn.id,
            sequence: nextSequenceValue,
            kind: kind,
            status: status,
            title: title,
            text: text,
            toolName: toolName,
            commandExecution: commandExecution,
            fileChange: fileChange,
            toolInvocation: toolInvocation,
            webSearch: webSearch,
            createdAt: now,
            updatedAt: now,
            completedAt: status == .completed || status == .failed || status == .interrupted || status == .declined ? now : nil
        )
        turn.items.append(item)
        turn.updatedAt = now
        return item
    }

    private func itemKind(forTool toolName: String) -> AgentTurnItemKind {
        let lower = toolName.lowercased()
        if lower == "bash" || lower.contains("shell") {
            return .commandExecution
        }
        if lower == "write" || lower == "edit" || lower == "multiedit" {
            return .fileChange
        }
        if lower == "grep" || lower == "glob" {
            return .webSearch
        }
        if lower.contains("exitplan") || lower.contains("plan") {
            return .plan
        }
        return .toolCall
    }
}

enum NativeToolRouter {
    static func openAITools() -> [[String: Any]] {
        AgentToolRegistry.openAITools()
    }

    static func permissionPolicy(for call: AgentToolCall, context: AgentRunContext) -> AgentPermissionPolicy.Result {
        AgentPermissionPolicy.policy(for: call, context: context)
    }

    static func execute(call: AgentToolCall, context: AgentRunContext) async -> AgentToolResult {
        await AgentToolExecutor.execute(call: call, context: context)
    }
}

struct NativeProcessResult: Sendable, Equatable {
    var id: UUID
    var command: String
    var stdout: String
    var stderr: String
    var exitCode: Int32
    var durationMs: Int
    var timedOut: Bool
}

actor NativeProcessRunner {
    private var processes: [UUID: Process] = [:]

    func run(
        command: String,
        cwd: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeoutSeconds: TimeInterval = 120
    ) async throws -> NativeProcessResult {
        let id = UUID()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = cwd
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let started = Date()
        processes[id] = process
        try process.run()

        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            if process.isRunning {
                process.terminate()
            }
        }

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeoutTask.cancel()
        processes[id] = nil

        let duration = Int(Date().timeIntervalSince(started) * 1_000)
        let timedOut = duration >= Int(timeoutSeconds * 1_000) && process.terminationStatus != 0
        return NativeProcessResult(
            id: id,
            command: command,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus,
            durationMs: duration,
            timedOut: timedOut
        )
    }

    func terminate(id: UUID) {
        processes[id]?.terminate()
        processes[id] = nil
    }

    func terminateAll() {
        for process in processes.values where process.isRunning {
            process.terminate()
        }
        processes.removeAll()
    }
}
