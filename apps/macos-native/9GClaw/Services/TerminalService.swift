import Foundation

struct TerminalRun: Identifiable, Hashable, Sendable {
    var id: UUID
    var command: String
    var cwd: String
    var output: String
    var exitCode: Int32?
    var startedAt: Date
    var endedAt: Date?
}

struct TerminalService: Sendable {
    private let runner: ProcessRunner

    init(runner: ProcessRunner = ProcessRunner()) {
        self.runner = runner
    }

    func run(command: String, cwd: URL?) async -> TerminalRun {
        var run = TerminalRun(
            id: UUID(),
            command: command,
            cwd: cwd?.path ?? FileManager.default.homeDirectoryForCurrentUser.path,
            output: "",
            exitCode: nil,
            startedAt: Date(),
            endedAt: nil
        )

        do {
            let result = try await runner.run("/bin/zsh", arguments: ["-lc", command], cwd: cwd)
            run.output = result.output
            run.exitCode = result.exitCode
        } catch let ProcessRunnerError.failed(code, output) {
            run.output = output
            run.exitCode = code
        } catch {
            run.output = error.localizedDescription
            run.exitCode = -1
        }
        run.endedAt = Date()
        return run
    }
}
