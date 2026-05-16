import Foundation

struct AppPaths {
    let applicationSupport: URL
    let logs: URL
    let attachments: URL
    let sessions: URL
    let memory: URL
    let tasks: URL

    static func current() throws -> AppPaths {
        let manager = FileManager.default
        let appSupportRoot = try manager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("9GClaw", isDirectory: true)
        let logsRoot = try manager.url(
            for: .libraryDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("Logs", isDirectory: true)
        .appendingPathComponent("9GClaw", isDirectory: true)

        let paths = AppPaths(
            applicationSupport: appSupportRoot,
            logs: logsRoot,
            attachments: appSupportRoot.appendingPathComponent("Attachments", isDirectory: true),
            sessions: appSupportRoot.appendingPathComponent("Sessions", isDirectory: true),
            memory: appSupportRoot.appendingPathComponent("Memory", isDirectory: true),
            tasks: appSupportRoot.appendingPathComponent("Tasks", isDirectory: true)
        )

        for path in [
            paths.applicationSupport,
            paths.logs,
            paths.attachments,
            paths.sessions,
            paths.memory,
            paths.tasks,
        ] {
            try manager.createDirectory(at: path, withIntermediateDirectories: true)
        }

        return paths
    }
}

enum AppLog {
    static func write(_ message: String, file: String = "app.log") {
        guard let paths = try? AppPaths.current() else { return }
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        let url = paths.logs.appendingPathComponent(file)
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                do {
                    _ = try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } catch {
                    // Logging must never affect app behavior.
                }
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
