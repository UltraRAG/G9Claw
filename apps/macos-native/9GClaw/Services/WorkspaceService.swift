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
        let root = URL(fileURLWithPath: project.rootPath)
        let contents = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        return contents
            .filter { !["node_modules", ".git", "dist", "build"].contains($0.lastPathComponent) }
            .map { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
                return WorkspaceFile(
                    id: url.path,
                    name: url.lastPathComponent,
                    path: url.path,
                    isDirectory: values?.isDirectory ?? false,
                    modifiedAt: values?.contentModificationDate
                )
            }
            .sorted { left, right in
                if left.isDirectory != right.isDirectory { return left.isDirectory && !right.isDirectory }
                return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
            }
    }

    func readFile(path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    func writeFile(path: String, content: String) throws {
        try content.write(toFile: path, atomically: true, encoding: .utf8)
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
}

struct WorkspaceFile: Identifiable, Hashable {
    var id: String
    var name: String
    var path: String
    var isDirectory: Bool
    var modifiedAt: Date?
}
