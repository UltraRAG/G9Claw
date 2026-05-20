import Foundation

struct ProcessResult: Equatable, Sendable {
    var exitCode: Int32
    var stdout: String
    var stderr: String

    var output: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

enum ProcessRunnerError: Error, LocalizedError, Sendable {
    case failed(Int32, String)

    var errorDescription: String? {
        switch self {
        case .failed(let code, let output): "Process failed with exit code \(code): \(output)"
        }
    }
}

struct ProcessRunner: Sendable {
    func run(_ executable: String, arguments: [String], cwd: URL? = nil, environment: [String: String] = [:]) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = cwd
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            process.terminationHandler = { process in
                let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let result = ProcessResult(exitCode: process.terminationStatus, stdout: out, stderr: err)
                if process.terminationStatus == 0 {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: ProcessRunnerError.failed(process.terminationStatus, result.output))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

struct GitService: Sendable {
    private let runner: ProcessRunner

    init(runner: ProcessRunner = ProcessRunner()) {
        self.runner = runner
    }

    func status(repo: URL) async throws -> String {
        try await git(["status", "--short", "--branch"], repo: repo).stdout
    }

    func diff(repo: URL, path: String? = nil) async throws -> String {
        var args = ["diff", "--"]
        if let path, !path.isEmpty {
            args.append(path)
        }
        return try await git(args, repo: repo).stdout
    }

    func branches(repo: URL) async throws -> String {
        try await git(["branch", "--all", "--verbose", "--no-abbrev"], repo: repo).stdout
    }

    func commit(repo: URL, message: String) async throws -> String {
        try await git(["add", "-A"], repo: repo)
        return try await git(["commit", "-m", message], repo: repo).output
    }

    func fetch(repo: URL) async throws -> String {
        try await git(["fetch", "--all", "--prune"], repo: repo).output
    }

    func pull(repo: URL) async throws -> String {
        try await git(["pull", "--ff-only"], repo: repo).output
    }

    func push(repo: URL) async throws -> String {
        try await git(["push"], repo: repo).output
    }

    @discardableResult
    private func git(_ arguments: [String], repo: URL) async throws -> ProcessResult {
        try await runner.run("/usr/bin/git", arguments: arguments, cwd: repo)
    }
}
