import Foundation

struct WorkspaceValidationResult: Equatable {
    var valid: Bool
    var resolvedPath: String?
    var error: String?
}

final class WorkspaceService {
    static let forbiddenPaths: [String] = [
        "/",
        "/etc",
        "/bin",
        "/sbin",
        "/usr",
        "/dev",
        "/proc",
        "/sys",
        "/var",
        "/boot",
        "/root",
        "/lib",
        "/lib64",
        "/opt",
        "/tmp",
        "/run",
        "C:\\Windows",
        "C:\\Program Files",
        "C:\\Program Files (x86)",
        "C:\\ProgramData",
        "C:\\System Volume Information",
        "C:\\$Recycle.Bin",
    ]

    let workspaceRoot: URL
    private let fileManager: FileManager

    init(workspaceRoot: URL = FileManager.default.homeDirectoryForCurrentUser, fileManager: FileManager = .default) {
        self.workspaceRoot = workspaceRoot.standardizedFileURL
        self.fileManager = fileManager
    }

    func validateWorkspacePath(_ requestedPath: String) -> WorkspaceValidationResult {
        let expanded = NSString(string: requestedPath).expandingTildeInPath
        let requestedURL = URL(fileURLWithPath: expanded).standardizedFileURL
        let normalized = requestedURL.path

        if Self.forbiddenPaths.contains(normalized) || normalized == "/" {
            return WorkspaceValidationResult(
                valid: false,
                resolvedPath: nil,
                error: "Cannot use system-critical directories as workspace locations"
            )
        }

        for forbidden in Self.forbiddenPaths {
            if normalized == forbidden || normalized.hasPrefix(forbidden + "/") {
                if forbidden == "/var" &&
                    (normalized.hasPrefix("/var/tmp") || normalized.hasPrefix("/var/folders")) {
                    continue
                }
                return WorkspaceValidationResult(
                    valid: false,
                    resolvedPath: nil,
                    error: "Cannot create workspace in system directory: \(forbidden)"
                )
            }
        }

        let rootPath = workspaceRoot.path
        guard normalized == rootPath || normalized.hasPrefix(rootPath + "/") else {
            return WorkspaceValidationResult(
                valid: false,
                resolvedPath: nil,
                error: "Workspace path must be within the allowed workspace root: \(rootPath)"
            )
        }

        return WorkspaceValidationResult(valid: true, resolvedPath: normalized, error: nil)
    }

    func listFiles(project: WorkspaceProject) throws -> [WorkspaceFile] {
        try listFiles(rootPath: project.rootPath)
    }

    func listFiles(rootPath: String, expandedDirectories: Set<String> = []) throws -> [WorkspaceFile] {
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL
        var output: [WorkspaceFile] = []

        func walk(_ directory: URL, depth: Int) throws {
            let contents = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
            let visible = contents
                .filter { !Self.hiddenNames.contains($0.lastPathComponent) }
                .sorted { left, right in
                    let leftDir = ((try? left.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false)
                    let rightDir = ((try? right.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false)
                    if leftDir != rightDir { return leftDir && !rightDir }
                    return left.lastPathComponent.localizedCaseInsensitiveCompare(right.lastPathComponent) == .orderedAscending
                }

            for url in visible {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey])
                let isDirectory = values?.isDirectory ?? false
                let relativePath = Self.relativePath(for: url, root: root)
                let file = WorkspaceFile(
                    id: url.path,
                    name: url.lastPathComponent,
                    path: url.path,
                    relativePath: relativePath,
                    depth: depth,
                    isDirectory: isDirectory,
                    isExpanded: expandedDirectories.contains(url.path),
                    modifiedAt: values?.contentModificationDate,
                    byteCount: values?.fileSize
                )
                output.append(file)
                if isDirectory && expandedDirectories.contains(url.path) {
                    try walk(url, depth: depth + 1)
                }
            }
        }

        try walk(root, depth: 0)
        return output
    }

    func readFile(path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    func writeFile(path: String, content: String) throws {
        try content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func createFile(parentPath: String, name: String, isDirectory: Bool) throws -> String {
        let safeName = try safeChildName(name)
        let url = URL(fileURLWithPath: parentPath).appendingPathComponent(safeName)
        if isDirectory {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fileManager.fileExists(atPath: url.path) {
                try Data().write(to: url)
            }
        }
        return url.path
    }

    func createWorkspaceDirectory(path: String) throws {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if fileManager.fileExists(atPath: url.path) {
            return
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func cloneRepository(_ repositoryURL: String, into path: String) async throws {
        let trimmed = repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let destination = URL(fileURLWithPath: path).standardizedFileURL
        let existing = (try? fileManager.contentsOfDirectory(atPath: destination.path)) ?? []
        guard existing.isEmpty else {
            throw NSError(
                domain: "WorkspaceService",
                code: 409,
                userInfo: [NSLocalizedDescriptionKey: "Target folder must be empty before cloning."]
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["clone", "--progress", trimmed, destination.path]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(
                domain: "WorkspaceService",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: output.isEmpty ? "git clone failed with exit code \(process.terminationStatus)" : output]
            )
        }
    }

    func rename(path: String, newName: String) throws -> String {
        let safeName = try safeChildName(newName)
        let source = URL(fileURLWithPath: path)
        let target = source.deletingLastPathComponent().appendingPathComponent(safeName)
        try fileManager.moveItem(at: source, to: target)
        return target.path
    }

    func delete(path: String) throws {
        try fileManager.removeItem(atPath: path)
    }

    func copyItems(_ urls: [URL], into directoryPath: String) throws {
        let destination = URL(fileURLWithPath: directoryPath)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for source in urls {
            let target = destination.appendingPathComponent(source.lastPathComponent)
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            try fileManager.copyItem(at: source, to: target)
        }
    }

    func exportZip(rootPath: String, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = URL(fileURLWithPath: rootPath)
        process.arguments = ["-qry", destination.path, "."]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw NSError(
                domain: "WorkspaceService",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "zip failed with exit code \(process.terminationStatus)"]
            )
        }
    }

    private func safeChildName(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "." || trimmed == ".." || trimmed.contains("/") || trimmed.contains("\\") {
            throw NSError(
                domain: "WorkspaceService",
                code: 400,
                userInfo: [NSLocalizedDescriptionKey: "Invalid name"]
            )
        }
        return trimmed
    }

    static func sortedProjects(_ projects: [WorkspaceProject], order: ProjectSortOrder) -> [WorkspaceProject] {
        switch order {
        case .name:
            projects.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        case .date:
            projects.sorted { $0.latestActivity > $1.latestActivity }
        }
    }

    static func projectName(for path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        let normalized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        let separators = CharacterSet(charactersIn: "/\\: \t\n\r~_")
        let parts = normalized.components(separatedBy: separators).filter { !$0.isEmpty }
        let slug = parts.joined(separator: "-")
        return slug.isEmpty ? "workspace" : "-\(slug)"
    }

    private static let hiddenNames = Set(["node_modules", ".git", "dist", "build", ".DS_Store"])

    private static func relativePath(for url: URL, root: URL) -> String {
        let relative = url.standardizedFileURL.path.replacingOccurrences(of: root.path + "/", with: "")
        return relative == url.path ? url.lastPathComponent : relative
    }
}

struct WorkspaceFile: Identifiable, Hashable {
    var id: String
    var name: String
    var path: String
    var relativePath: String
    var depth: Int
    var isDirectory: Bool
    var isExpanded: Bool
    var modifiedAt: Date?
    var byteCount: Int?

    var fileExtension: String {
        URL(fileURLWithPath: path).pathExtension.lowercased()
    }

    var isMarkdown: Bool {
        fileExtension == "md" || fileExtension == "markdown"
    }

    var isHTML: Bool {
        fileExtension == "html" || fileExtension == "htm"
    }

    var isImage: Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"].contains(fileExtension)
    }
}
