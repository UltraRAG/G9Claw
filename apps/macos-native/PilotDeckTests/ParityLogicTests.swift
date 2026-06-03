import AppKit
import XCTest
@testable import PilotDeck

final class ParityLogicTests: XCTestCase {
    func testWorkspacePathValidationCoversRootOutsideAndSystemPaths() {
        let service = WorkspaceService(workspaceRoot: URL(fileURLWithPath: "/Users/tester"))

        XCTAssertFalse(service.validateWorkspacePath("/").valid)
        XCTAssertFalse(service.validateWorkspacePath("/usr/bin").valid)
        XCTAssertFalse(service.validateWorkspacePath("/opt/homebrew").valid)
        XCTAssertFalse(service.validateWorkspacePath("/tmp/work").valid)

        let workspaceService = WorkspaceService(workspaceRoot: URL(fileURLWithPath: "/Users/tester/Workspace"))
        let outside = workspaceService.validateWorkspacePath("/Users/tester/Downloads/project")

        XCTAssertFalse(outside.valid)
        XCTAssertEqual(outside.error, "Workspace path must be within the allowed workspace root: /Users/tester/Workspace")

        let inside = service.validateWorkspacePath("/Users/tester/project")
        XCTAssertTrue(inside.valid)
        XCTAssertEqual(inside.resolvedPath, "/Users/tester/project")
    }

    func testPilotDeckWebHistoryStoreDiscoversProjectSessionsAndMessages() throws {
        let pilotHome = temporaryDirectory("pilotdeck-web-home")
        let projectRoot = temporaryDirectory("pilotdeck-web-project")
        defer {
            try? FileManager.default.removeItem(at: pilotHome)
            try? FileManager.default.removeItem(at: projectRoot)
        }

        let projectID = PilotDeckWebHistoryStore.projectID(for: projectRoot.path)
        let projectDir = pilotHome
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(projectID, isDirectory: true)
        let chatDir = projectDir.appendingPathComponent("chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatDir, withIntermediateDirectories: true)
        try projectRoot.path.write(to: projectDir.appendingPathComponent(".cwd"), atomically: true, encoding: .utf8)

        let sessionID = "web:s_history"
        let transcript = """
        {"type":"accepted_input","sessionId":"web:s_history","turnId":"turn-1","sequence":1,"createdAt":"2026-06-01T02:00:00.000Z","messages":[{"role":"user","content":[{"type":"text","text":"你好，帮我做一个小网站"}]}]}
        {"type":"assistant_message","sessionId":"web:s_history","turnId":"turn-1","sequence":2,"createdAt":"2026-06-01T02:00:01.000Z","message":{"role":"assistant","content":[{"type":"text","text":"好的，我会创建一个小网站。"}]}}
        {"type":"turn_result","sessionId":"web:s_history","turnId":"turn-1","sequence":3,"createdAt":"2026-06-01T02:00:02.000Z","result":{"type":"success","stopReason":"completed","usage":{"inputTokens":1,"outputTokens":1,"totalTokens":2},"permissionDenials":[]}}
        """
        try transcript.write(
            to: chatDir.appendingPathComponent("\(sessionID).jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let histories = PilotDeckWebHistoryStore.loadProjects(pilotHome: pilotHome)
        XCTAssertEqual(histories.count, 1)
        XCTAssertEqual(histories.first?.rootPath, projectRoot.path)
        XCTAssertEqual(histories.first?.sessions.first?.id, sessionID)
        XCTAssertEqual(histories.first?.sessions.first?.summary, "你好，帮我做一个小网站")

        let messages = try XCTUnwrap(PilotDeckWebHistoryStore.loadMessages(
            sessionID: sessionID,
            projectRoot: projectRoot.path,
            pilotHome: pilotHome
        ))
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.first?.role, .user)
        XCTAssertEqual(messages.first?.plainText, "你好，帮我做一个小网站")
        XCTAssertEqual(messages.last?.role, .assistant)
        XCTAssertEqual(messages.last?.plainText, "好的，我会创建一个小网站。")
    }

    func testPilotDeckWebHistoryStoreDiscoversGeneralSessions() throws {
        let pilotHome = temporaryDirectory("pilotdeck-web-general-home")
        defer { try? FileManager.default.removeItem(at: pilotHome) }

        let projectID = PilotDeckWebHistoryStore.projectID(for: pilotHome.path)
        let chatDir = pilotHome
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(projectID, isDirectory: true)
            .appendingPathComponent("chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatDir, withIntermediateDirectories: true)

        let sessionID = "web:s_general"
        let transcriptURL = chatDir.appendingPathComponent("\(sessionID).jsonl")
        let transcript = """
        {"type":"accepted_input","sessionId":"web:s_general","turnId":"turn-1","sequence":1,"createdAt":"2026-06-01T10:00:00.000Z","messages":[{"role":"user","content":[{"type":"text","text":"你好啊"}]}]}
        {"type":"assistant_message","sessionId":"web:s_general","turnId":"turn-1","sequence":2,"createdAt":"2026-06-01T10:00:01.000Z","message":{"role":"assistant","content":[{"type":"text","text":"你好！"}]}}
        """
        try transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let history = try XCTUnwrap(PilotDeckWebHistoryStore.loadGeneralHistory(pilotHome: pilotHome))
        XCTAssertEqual(history.rootPath, pilotHome.path)
        XCTAssertEqual(history.sessions.map(\.id), [sessionID])
        XCTAssertEqual(history.sessions.first?.summary, "你好啊")
        XCTAssertEqual(history.sessions.first?.relativeTranscriptPath, transcriptURL.path)
        XCTAssertEqual(history.sessions.first?.transcriptKey, "pilotdeck-web")

        let messages = try XCTUnwrap(PilotDeckWebHistoryStore.loadMessages(
            sessionID: sessionID,
            transcriptURL: transcriptURL
        ))
        XCTAssertEqual(messages.map(\.plainText), ["你好啊", "你好！"])
    }

    func testPilotDeckWebHistoryStoreDiscoversKnownProjectWithoutChats() throws {
        let pilotHome = temporaryDirectory("pilotdeck-web-known-home")
        let projectRoot = temporaryDirectory("pilotdeck-web-known-project")
        let configuredRoot = temporaryDirectory("pilotdeck-web-configured-project")
        defer {
            try? FileManager.default.removeItem(at: pilotHome)
            try? FileManager.default.removeItem(at: projectRoot)
            try? FileManager.default.removeItem(at: configuredRoot)
        }

        let projectID = PilotDeckWebHistoryStore.projectID(for: projectRoot.path)
        let projectDir = pilotHome
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(projectID, isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try projectRoot.path.write(to: projectDir.appendingPathComponent(".cwd"), atomically: true, encoding: .utf8)

        let config: [String: Any] = [
            "projects": [
                "configured-project": [
                    "originalPath": configuredRoot.path,
                    "displayName": "Configured Project",
                ],
            ],
        ]
        let configData = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        try configData.write(to: pilotHome.appendingPathComponent("project-config.json"), options: .atomic)

        let known = PilotDeckWebHistoryStore.loadKnownProjects(pilotHome: pilotHome)
        let roots = Set(known.map(\.rootPath))

        XCTAssertTrue(roots.contains(projectRoot.standardizedFileURL.path))
        XCTAssertTrue(roots.contains(configuredRoot.standardizedFileURL.path))
        XCTAssertEqual(
            known.first(where: { $0.rootPath == configuredRoot.standardizedFileURL.path })?.displayName,
            "Configured Project"
        )
    }

    func testSharedProjectPathIndexPreservesTombstoneUntilReopened() throws {
        let root = temporaryDirectory("pilotdeck-shared-project-index")
        let projectRoot = temporaryDirectory("pilotdeck-shared-project")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: projectRoot)
        }

        let indexURL = root.appendingPathComponent(".pilotdeck/project-index.json")
        let createdAt = Date(timeIntervalSince1970: 100)
        SharedProjectPathIndexStore.upsert([
            SharedProjectPathIndexStore.Entry(
                rootPath: projectRoot.path,
                projectName: "native-project",
                displayName: "Native Project",
                isGeneral: false,
                sources: ["mac-native"],
                createdAt: createdAt,
                updatedAt: createdAt,
                deletedAt: nil
            ),
        ], url: indexURL)

        XCTAssertEqual(SharedProjectPathIndexStore.loadActiveEntries(url: indexURL).map(\.rootPath), [
            projectRoot.standardizedFileURL.path,
        ])

        let deletedAt = Date(timeIntervalSince1970: 200)
        SharedProjectPathIndexStore.markDeleted(rootPath: projectRoot.path, url: indexURL, now: deletedAt)

        XCTAssertTrue(SharedProjectPathIndexStore.loadActiveEntries(url: indexURL).isEmpty)
        XCTAssertEqual(SharedProjectPathIndexStore.load(url: indexURL).projects.first?.deletedAt, deletedAt)

        let reopenedAt = Date(timeIntervalSince1970: 300)
        SharedProjectPathIndexStore.upsert([
            SharedProjectPathIndexStore.Entry(
                rootPath: projectRoot.path,
                projectName: "web-project",
                displayName: "Web Project",
                isGeneral: false,
                sources: ["web"],
                createdAt: reopenedAt,
                updatedAt: reopenedAt,
                deletedAt: nil
            ),
        ], url: indexURL)

        let reopened = try XCTUnwrap(SharedProjectPathIndexStore.loadActiveEntries(url: indexURL).first)
        XCTAssertNil(reopened.deletedAt)
        XCTAssertEqual(reopened.projectName, "web-project")
        XCTAssertEqual(Set(reopened.sources), ["mac-native", "web"])
    }

    func testSharedSessionIndexRequiresReadableNativeTranscript() throws {
        let root = temporaryDirectory("pilotdeck-shared-session-index")
        let projectRoot = temporaryDirectory("pilotdeck-shared-session-project")
        let sessionsDirectory = root.appendingPathComponent("Sessions", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: projectRoot)
        }
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)

        let indexURL = root.appendingPathComponent(".pilotdeck/session-index.json")
        let session = ProjectSession(
            id: "native-session",
            provider: .pilotDeck,
            title: "Build a local app",
            summary: "Build a local app",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 110),
            lastActivity: Date(timeIntervalSince1970: 120),
            lastConversationAt: Date(timeIntervalSince1970: 130),
            state: .processing,
            messageCount: 3
        )

        SharedSessionIndexStore.save(entries: [
            SharedSessionIndexStore.Entry(
                projectRoot: projectRoot.path,
                session: session,
                source: "mac-native",
                updatedAt: session.activityDate
            ),
        ], url: indexURL)

        let loadedBeforeTranscript = try XCTUnwrap(SharedSessionIndexStore.loadEntries(url: indexURL).first)
        XCTAssertEqual(loadedBeforeTranscript.session.state, .idle)
        XCTAssertFalse(loadedBeforeTranscript.hasReadableTranscript(nativeSessionsDirectory: sessionsDirectory))

        try "[]".write(
            to: sessionsDirectory.appendingPathComponent("\(session.id).json"),
            atomically: true,
            encoding: .utf8
        )

        let loadedAfterTranscript = try XCTUnwrap(SharedSessionIndexStore.loadEntries(url: indexURL).first)
        XCTAssertTrue(loadedAfterTranscript.hasReadableTranscript(nativeSessionsDirectory: sessionsDirectory))
    }

    func testLocalSessionIndexRecoveryRestoresProjectSessionFromMessagePath() throws {
        let sessionsDirectory = temporaryDirectory("pilotdeck-local-sessions")
        defer { try? FileManager.default.removeItem(at: sessionsDirectory) }

        let projectRoot = "/Users/meisen/workspace/9gclaw_projects/football"
        let sessionID = "native-football-session"
        let messages = [
            ChatMessage(
                id: UUID(),
                sessionId: sessionID,
                provider: .pilotDeck,
                role: .user,
                blocks: [.text("帮我做一款 html 的足球游戏")],
                createdAt: Date(timeIntervalSince1970: 100),
                isStreaming: false,
                tokenBudget: nil
            ),
            ChatMessage(
                id: UUID(),
                sessionId: sessionID,
                provider: .pilotDeck,
                role: .assistant,
                blocks: [
                    .toolCall(ToolCall(
                        id: "write-football",
                        name: "Write",
                        inputJSON: #"{"file_path":"\/Users\/meisen\/workspace\/9gclaw_projects\/football\/index.html","content":"<html></html>"}"#,
                        status: .completed
                    )),
                ],
                createdAt: Date(timeIntervalSince1970: 120),
                isStreaming: false,
                tokenBudget: nil
            ),
        ]
        let data = try JSONEncoder().encode(messages)
        try data.write(to: sessionsDirectory.appendingPathComponent("\(sessionID).json"), options: .atomic)

        let recovered = LocalSessionIndexRecovery.recover(
            sessionsDirectory: sessionsDirectory,
            knownProjectRoots: ["/Users/meisen", projectRoot],
            generalProjectRoot: "/Users/meisen"
        )

        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered.first?.projectRoot, projectRoot)
        XCTAssertEqual(recovered.first?.session.id, sessionID)
        XCTAssertEqual(recovered.first?.session.title, "帮我做一款 html 的足球游戏")
        XCTAssertEqual(recovered.first?.session.messageCount, 2)
        XCTAssertEqual(recovered.first?.session.lastConversationAt, Date(timeIntervalSince1970: 120))
    }

    func testLocalSessionIndexRecoveryCanUseSpecificProjectSlugWhenPathIsAbsent() throws {
        let sessionsDirectory = temporaryDirectory("pilotdeck-local-slug-sessions")
        defer { try? FileManager.default.removeItem(at: sessionsDirectory) }

        let projectRoot = "/Users/meisen/workspace/9gclaw_projects/tanchishe"
        let sessionID = "native-tanchishe-session"
        let messages = [
            ChatMessage(
                id: UUID(),
                sessionId: sessionID,
                provider: .pilotDeck,
                role: .assistant,
                blocks: [.text("Created the tanchishe HTML game and opened index.html.")],
                createdAt: Date(timeIntervalSince1970: 200),
                isStreaming: false,
                tokenBudget: nil
            ),
        ]
        let data = try JSONEncoder().encode(messages)
        try data.write(to: sessionsDirectory.appendingPathComponent("\(sessionID).json"), options: .atomic)

        let recovered = LocalSessionIndexRecovery.recover(
            sessionsDirectory: sessionsDirectory,
            knownProjectRoots: ["/Users/meisen", projectRoot],
            generalProjectRoot: "/Users/meisen"
        )

        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered.first?.projectRoot, projectRoot)
    }

    func testLocalSessionIndexRecoveryDoesNotUseGenericProjectSlug() throws {
        let sessionsDirectory = temporaryDirectory("pilotdeck-local-generic-sessions")
        defer { try? FileManager.default.removeItem(at: sessionsDirectory) }

        let sessionID = "native-generic-session"
        let messages = [
            ChatMessage(
                id: UUID(),
                sessionId: sessionID,
                provider: .pilotDeck,
                role: .user,
                blocks: [.text("Run one more test for the weather answer.")],
                createdAt: Date(timeIntervalSince1970: 300),
                isStreaming: false,
                tokenBudget: nil
            ),
        ]
        let data = try JSONEncoder().encode(messages)
        try data.write(to: sessionsDirectory.appendingPathComponent("\(sessionID).json"), options: .atomic)

        let recovered = LocalSessionIndexRecovery.recover(
            sessionsDirectory: sessionsDirectory,
            knownProjectRoots: ["/Users/meisen", "/Users/meisen/workspace/9gclaw_projects/test"],
            generalProjectRoot: "/Users/meisen"
        )

        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered.first?.projectRoot, "/Users/meisen")
    }

    func testProjectNameMatchesWebManualProjectSlugPolicy() {
        XCTAssertEqual(WorkspaceService.projectName(for: "/Users/tester/My_Project"), "-Users-tester-My-Project")
    }

    func testNativeAgentRuntimeContextUsesLocalDateInsteadOfUTCDate() {
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = utcCalendar.date(from: DateComponents(
            year: 2026,
            month: 5,
            day: 31,
            hour: 16,
            minute: 30
        ))!
        let shanghai = TimeZone(identifier: "Asia/Shanghai")!

        let context = NativeAgentRuntime.nativeAgentRuntimeContext(now: now, timeZone: shanghai)

        XCTAssertTrue(context.contains("current_date: 2026-06-01"))
        XCTAssertTrue(context.contains("current_weekday: Monday"))
        XCTAssertTrue(context.contains("timezone: Asia/Shanghai (UTC+08:00)"))
        XCTAssertTrue(context.contains("<system-reminder>"))
        XCTAssertTrue(context.contains("<environment>"))
        XCTAssertFalse(context.contains("current_date: 2026-05-31"))
    }

    func testWorkspaceFileListingReportsHiddenOnlyRoots() throws {
        let root = temporaryDirectory("pilotdeck-files")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".pilotdeck"), withIntermediateDirectories: true)

        let service = WorkspaceService(workspaceRoot: root)
        let hiddenOnly = try service.fileListing(rootPath: root.path)

        XCTAssertTrue(hiddenOnly.files.isEmpty)
        XCTAssertEqual(hiddenOnly.visibleRootItemCount, 0)
        XCTAssertEqual(hiddenOnly.skippedRootItemCount, 1)
        XCTAssertTrue(hiddenOnly.isRootHiddenOnly)

        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        let visible = try service.fileListing(rootPath: root.path)

        XCTAssertEqual(visible.files.map(\.name), ["Sources"])
        XCTAssertEqual(visible.visibleRootItemCount, 1)
        XCTAssertFalse(visible.isRootHiddenOnly)
    }

    func testWorkspaceTextReadRejectsBinaryAndLargeFiles() throws {
        let root = temporaryDirectory("pilotdeck-read")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = WorkspaceService(workspaceRoot: root)

        let textURL = root.appendingPathComponent("note.txt")
        try "hello".write(to: textURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(try service.readTextFile(path: textURL.path).content, "hello")

        let binaryURL = root.appendingPathComponent("asset.bin")
        try Data([0, 1, 2, 3]).write(to: binaryURL)
        XCTAssertThrowsError(try service.readTextFile(path: binaryURL.path)) { error in
            XCTAssertEqual(error as? WorkspaceFileReadError, .binaryFile)
        }

        let largeURL = root.appendingPathComponent("large.txt")
        try String(repeating: "x", count: 12).write(to: largeURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try service.readTextFile(path: largeURL.path, maxBytes: 8)) { error in
            guard case .fileTooLarge(byteCount: 12, limit: 8) = error as? WorkspaceFileReadError else {
                return XCTFail("Expected fileTooLarge, got \(error)")
            }
        }
    }

    func testWorkspaceCopyItemsSkipsSourceAlreadyInDestination() throws {
        let root = temporaryDirectory("pilotdeck-copy-items")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = WorkspaceService(workspaceRoot: root)

        let existingFile = root.appendingPathComponent("asset.txt")
        try "original".write(to: existingFile, atomically: true, encoding: .utf8)
        try service.copyItems([existingFile], into: root.path)
        XCTAssertEqual(try String(contentsOf: existingFile, encoding: .utf8), "original")

        let nestedDirectory = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        let sourceFile = root.appendingPathComponent("source.txt")
        try "copied".write(to: sourceFile, atomically: true, encoding: .utf8)
        try service.copyItems([sourceFile], into: nestedDirectory.path)
        XCTAssertEqual(
            try String(contentsOf: nestedDirectory.appendingPathComponent("source.txt"), encoding: .utf8),
            "copied"
        )
    }

    func testProjectSortingByNameMatchesSidebarPolicy() {
        let now = Date()
        let projects = [
            project(name: "zeta", displayName: "Zeta", date: now),
            project(name: "alpha", displayName: "Alpha", date: now),
        ]

        XCTAssertEqual(WorkspaceService.sortedProjects(projects, order: .name).map(\.displayName), ["Alpha", "Zeta"])
    }

    func testProjectSortingByDateUsesMostRecentSessionActivity() {
        let now = Date()
        let old = project(name: "old", displayName: "Old", date: now.addingTimeInterval(-5000))
        var recent = project(name: "recent", displayName: "Recent", date: now.addingTimeInterval(-9000))
        recent.sessions = [
            ProjectSession(
                id: "recent-session",
                provider: .pilotDeck,
                title: "Recent",
                summary: "",
                createdAt: now.addingTimeInterval(-9000),
                updatedAt: nil,
                lastActivity: now,
                state: .idle
            )
        ]

        XCTAssertEqual(WorkspaceService.sortedProjects([old, recent], order: .date).first?.name, "recent")
    }

    func testSidebarProjectRestorationPrefersRememberedProject() {
        let now = Date()
        let first = project(name: "first", displayName: "First", date: now)
        let remembered = project(name: "remembered", displayName: "Remembered", date: now)

        let restored = SidebarProjectRestorationPolicy.preferredProject(
            from: [first, remembered],
            lastProjectIDRaw: remembered.id.uuidString
        )

        XCTAssertEqual(restored?.id, remembered.id)
        XCTAssertEqual(
            SidebarProjectRestorationPolicy.preferredProject(from: [first, remembered], lastProjectIDRaw: "")?.id,
            first.id
        )
    }

    func testLegacyConfigLoaderReadsDefaultProviderSettings() {
        let yaml = """
        runtime:
          workspacesRoot: ~/Workspace
        gateway:
          runtimePaths:
            generalCwd: ~/PilotDeck/general
        models:
          providers:
            pilotdeck:
              type: openai-chat
              baseUrl: http://example.local/v1
              apiKey: local-secret
          entries:
            default:
              provider: pilotdeck
              name: qwen3.6-27b
        """

        let snapshot = LegacyConfigLoader.snapshot(from: yaml)

        XCTAssertEqual(snapshot?.baseURL, "http://example.local/v1")
        XCTAssertEqual(snapshot?.apiKey, "local-secret")
        XCTAssertEqual(snapshot?.model, "qwen3.6-27b")
        XCTAssertEqual(snapshot?.workspacesRoot, "~/Workspace")
        XCTAssertEqual(snapshot?.generalWorkspacePath, "~/PilotDeck/general")
    }

    func testGeneralWorkspacePathFallsBackWhenConfigIsRelative() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

        XCTAssertEqual(
            AppState.normalizedGeneralWorkspacePath("general", home: home),
            "/Users/tester/PilotDeck/general"
        )
        XCTAssertEqual(
            AppState.normalizedGeneralWorkspacePath("  ", home: home),
            "/Users/tester/PilotDeck/general"
        )
        XCTAssertEqual(
            AppState.normalizedGeneralWorkspacePath("/Users/tester/Projects/demo", home: home),
            "/Users/tester/Projects/demo"
        )
        XCTAssertEqual(
            AppState.normalizedGeneralWorkspacePath("null", home: home),
            "/Users/tester/PilotDeck/general"
        )
        XCTAssertEqual(
            AppState.normalizedGeneralWorkspacePath("/null", home: home),
            "/Users/tester/PilotDeck/general"
        )
    }

    func testWorkspaceRootFallsBackWhenConfigIsNullOrRelative() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

        XCTAssertEqual(AppState.normalizedWorkspacesRoot("null", home: home), "/Users/tester")
        XCTAssertEqual(AppState.normalizedWorkspacesRoot("/null", home: home), "/Users/tester")
        XCTAssertEqual(AppState.normalizedWorkspacesRoot("workspace", home: home), "/Users/tester")
        XCTAssertEqual(AppState.normalizedWorkspacesRoot("~/Workspace", home: home), "/Users/tester/Workspace")
    }

    func testSettingsNormalizationUsesNativePilotDeckProvider() {
        var settings = AppSettings.defaults
        settings.providerConfig.provider = .codex
        settings.providerConfig.apiType = .openAIResponses
        settings.providerConfig.secretAccount = "custom-secret-account"
        settings.workspacesRoot = "/null"
        settings.generalWorkspacePath = "general"

        let normalized = AppState.normalizedSettings(settings)

        XCTAssertEqual(normalized.providerConfig.provider, .pilotDeck)
        XCTAssertEqual(normalized.providerConfig.apiType, .openAIChat)
        XCTAssertEqual(normalized.providerConfig.secretAccount, ProviderConfig.empty.secretAccount)
        XCTAssertNotEqual(normalized.workspacesRoot, "/null")
        XCTAssertTrue(normalized.generalWorkspacePath.hasSuffix("/PilotDeck/general"))
    }

    func testSettingsStoreLoadsUnknownSessionProviderWithoutBlockingBootstrap() throws {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pilotdeck-settings-provider-\(UUID().uuidString).json")
        var settings = AppSettings.defaults
        settings.providerConfig.secretAccount = "custom-secret-account"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var json = try XCTUnwrap(String(data: encoder.encode(settings), encoding: .utf8))
        json = json.replacingOccurrences(of: #""provider" : "pilotdeck""#, with: #""provider" : "custom-session-source""#)
        try json.write(to: tempURL, atomically: true, encoding: String.Encoding.utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let loaded = try XCTUnwrap(try AppSettingsStore(url: tempURL).load())
        XCTAssertEqual(loaded.providerConfig.provider, .pilotDeck)

        let normalized = AppState.normalizedSettings(loaded)
        XCTAssertEqual(normalized.providerConfig.secretAccount, ProviderConfig.empty.secretAccount)
    }

    func testNativeConfigPathUsesPilotDeckConfigLocationAndOverride() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

        XCTAssertEqual(
            PilotDeckConfigPath.configURL(environment: [:], home: home).path,
            "/Users/tester/.pilotdeck/pilotdeck.yaml"
        )
        XCTAssertEqual(
            PilotDeckConfigPath.configURL(environment: ["PILOTDECK_CONFIG_PATH": "~/pilotdeck-dev.yaml"], home: home).path,
            "/Users/tester/pilotdeck-dev.yaml"
        )
        XCTAssertEqual(
            PilotDeckConfigPath.legacyConfigURL(home: home).path,
            "/Users/tester/.pilotdeck/config.yaml"
        )
        XCTAssertEqual(
            PilotDeckConfigPath.legacyConfigURLs(home: home).map(\.path),
            ["/Users/tester/.pilotdeck/config.yaml"]
        )
    }

    func testNativeDefaultConfigUsesWebSchemaAndSearchDefaults() {
        let yaml = PilotDeckConfigDefaults.configText(homePath: "/Users/tester", userName: "tester")
        let values = NativeConfigService.scalarMap(from: yaml)

        XCTAssertEqual(values["schemaVersion"], "1")
        XCTAssertEqual(values["agent.model"], "")
        XCTAssertEqual(values["model.providers"], "{}")
        XCTAssertNil(values["memory.model"])
        XCTAssertEqual(values["memory.autoIndexIntervalMinutes"], "30")
        XCTAssertEqual(values["memory.autoDreamIntervalMinutes"], "60")
        XCTAssertEqual(values["webui.runtime.workspacesRoot"], "/Users/tester")
        XCTAssertEqual(values["runtime.workspacesRoot"], "/Users/tester")
        XCTAssertEqual(values["tools.webSearch.provider"], "glm")
        XCTAssertEqual(values["tools.webSearch.endpoint"], "https://api.z.ai/api/paas/v4/web_search")
        XCTAssertEqual(values["tools.webSearch.organicLimit"], "8")
        XCTAssertEqual(values["tools.webSearch.customProvider.auth"], "bearer")
        XCTAssertEqual(values["router.enabled"], "false")
        XCTAssertEqual(values["router.scenarios.default"], "")
        XCTAssertEqual(values["router.tokenSaver.enabled"], "false")
        XCTAssertEqual(values["router.tokenSaver.defaultTier"], "medium")
        XCTAssertEqual(values["router.tokenSaver.judgeTimeoutMs"], "15000")
        XCTAssertEqual(values["router.tokenStats.defaultCostPerMillion"], "0.8")
        XCTAssertEqual(values["router.zeroUsageRetry.enabled"], "true")
        XCTAssertEqual(values["router.transientRetry.enabled"], "true")
        XCTAssertEqual(values["gateway.home"], "/Users/tester/.pilotdeck/gateway")
        XCTAssertEqual(values["gateway.runtimePaths.generalCwd"], "~/PilotDeck/general")

        let channelNames = Set(values.keys.compactMap { key -> String? in
            guard key.hasPrefix("gateway.channels.") else { return nil }
            let parts = key.split(separator: ".")
            return parts.count > 2 ? String(parts[2]) : nil
        })
        XCTAssertEqual(
            channelNames,
            Set([
                "feishu",
                "telegram",
                "discord",
                "slack",
                "wecom",
                "wecom_callback",
                "dingtalk",
                "weixin",
                "whatsapp",
                "signal",
                "matrix",
                "mattermost",
                "email",
                "sms_twilio",
                "homeassistant",
                "api_server",
                "webhook",
                "bluebubbles",
            ])
        )
        XCTAssertEqual(values["gateway.channels.feishu.webhookPath"], "/feishu/webhook")
        XCTAssertEqual(values["gateway.channels.feishu.homeChannel.name"], "Home")
        XCTAssertEqual(values["gateway.channels.telegram.webhookPort"], "null")
        XCTAssertEqual(values["gateway.channels.wecom.websocketUrl"], "wss://openws.work.weixin.qq.com")
        XCTAssertEqual(values["gateway.channels.api_server.port"], "8642")
        XCTAssertEqual(values["gateway.channels.api_server.modelName"], "pilotdeck-gateway")
        XCTAssertEqual(values["gateway.channels.webhook.secret"], "")
    }

    func testNativeConfigServiceReadsWebV2PilotDeckYamlDirectly() throws {
        let yaml = """
        schemaVersion: 1
        agent:
          model: zai/glm-4.5
          maxContextTokens: 128000
          subagents:
            default: inherit
        model:
          providers:
            zai:
              protocol: openai
              url: https://api.z.ai/api/paas/v4
              apiKey: web-secret
              headers:
                X-Test: yes
              models:
                glm-4.5: {}
                glm-4.5-air:
                  capabilities:
                    maxContextTokens: 64000
        memory:
          enabled: true
          model: zai/glm-4.5-air
        webui:
          runtime:
            apiTimeoutMs: 90000
            workspacesRoot: /Users/tester/workspace
        router:
          enabled: true
          scenarios:
            default: zai/glm-4.5
            background: zai/glm-4.5-air
          tokenSaver:
            judge: zai/glm-4.5-air
            tiers:
              simple:
                model: zai/glm-4.5-air
        """

        let snapshot = try XCTUnwrap(NativeConfigService.snapshot(from: yaml))
        let values = snapshot.rawValues

        XCTAssertEqual(snapshot.mainEntryID, "zai/glm-4.5")
        XCTAssertEqual(snapshot.defaultEntryID, "zai/glm-4.5")
        XCTAssertEqual(snapshot.providerConfig.baseURL, "https://api.z.ai/api/paas/v4")
        XCTAssertEqual(snapshot.providerConfig.model, "glm-4.5")
        XCTAssertEqual(snapshot.apiKey, "web-secret")
        XCTAssertEqual(snapshot.apiTimeoutMs, 90_000)
        XCTAssertEqual(snapshot.contextWindow, 128_000)
        XCTAssertEqual(values["models.entries.zai/glm-4.5.provider"], "zai")
        XCTAssertEqual(values["models.entries.zai/glm-4.5-air.contextWindow"], "64000")
        XCTAssertEqual(NativeConfigService.resolvedAPIKey(routeEntryID: "zai/glm-4.5-air", nativeConfig: snapshot), "web-secret")
        XCTAssertEqual(NativeRouterRuntime.decision(forTier: "simple", values: values, isBackgroundRequest: true).entryID, "zai/glm-4.5-air")
    }

    func testLegacyNativeConfigCanBeMigratedToWebSchema() throws {
        let legacy = """
        runtime:
          apiTimeoutMs: 90000
          workspacesRoot: /Users/tester/workspace
        models:
          providers:
            pilotdeck:
              type: openai-chat
              baseUrl: https://api.example.com/v1
              apiKey: old-secret
          entries:
            default:
              provider: pilotdeck
              name: qwen3
              contextWindow: 96000
            small:
              provider: pilotdeck
              name: qwen-small
        agents:
          main:
            model: default
        router:
          routes:
            background:
              model: small
        """

        let migrated = NativeConfigService.webSchemaConfigTextIfNeeded(from: legacy, homePath: "/Users/tester", userName: "tester")
        let snapshot = try XCTUnwrap(NativeConfigService.snapshot(from: migrated))

        XCTAssertTrue(migrated.contains("schemaVersion: 1"))
        XCTAssertTrue(migrated.contains("model: pilotdeck/qwen3"))
        XCTAssertFalse(migrated.contains("\nmodels:\n  providers:"))
        XCTAssertEqual(snapshot.providerConfig.baseURL, "https://api.example.com/v1")
        XCTAssertEqual(snapshot.providerConfig.model, "qwen3")
        XCTAssertEqual(snapshot.contextWindow, 96_000)
        XCTAssertEqual(snapshot.rawValues["router.scenarios.background"], "pilotdeck/qwen-small")
    }

    func testNativeConfigServiceUsesPilotDeckAsDefaultProviderID() {
        let yaml = """
        models:
          providers:
            pilotdeck:
              type: openai-chat
              baseUrl: http://pilotdeck.local/v1
              apiKey: test-secret
          entries:
            default:
              provider: pilotdeck
              name: test-model
        """

        let values = NativeConfigService.scalarMap(from: yaml)
        let snapshot = NativeConfigService.snapshot(from: yaml)

        XCTAssertEqual(NativeConfigService.providerID(entryID: "missing", values: values), "pilotdeck")
        XCTAssertEqual(snapshot?.providerConfig.baseURL, "http://pilotdeck.local/v1")
        XCTAssertEqual(snapshot?.providerConfig.model, "test-model")
        XCTAssertEqual(snapshot?.providerConfig.secretAccount, ProviderConfig.empty.secretAccount)
        XCTAssertEqual(snapshot?.apiKey, "test-secret")
    }

    func testNativeConfigSnapshotTreatsRuntimeNullPathsAsUnset() throws {
        let yaml = """
        schemaVersion: 1
        agent:
          model: pilotdeck/qwen3
        model:
          providers:
            pilotdeck:
              protocol: openai
              url: http://pilotdeck.local/v1
              apiKey: test-secret
              models:
                qwen3: {}
        webui:
          runtime:
            workspacesRoot: null
        gateway:
          runtimePaths:
            generalCwd: null
        """

        let snapshot = try XCTUnwrap(NativeConfigService.snapshot(from: yaml))

        XCTAssertNil(snapshot.workspacesRoot)
        XCTAssertNil(snapshot.generalWorkspacePath)
    }

    func testLegacyConfigMigrationDoesNotPreserveNullWorkspaceRoot() {
        let legacy = """
        runtime:
          workspacesRoot: null
        gateway:
          runtimePaths:
            generalCwd: null
        models:
          providers:
            pilotdeck:
              type: openai-chat
              baseUrl: http://pilotdeck.local/v1
          entries:
            default:
              provider: pilotdeck
              name: qwen3
        agents:
          main:
            model: default
        """

        let migrated = NativeConfigService.webSchemaConfigTextIfNeeded(from: legacy, homePath: "/Users/tester", userName: "tester")
        let values = NativeConfigService.scalarMap(from: migrated)

        XCTAssertEqual(values["webui.runtime.workspacesRoot"], "/Users/tester")
        XCTAssertEqual(values["gateway.runtimePaths.generalCwd"], "~/PilotDeck/general")
    }

    func testNativeConfigScalarMapMigratesLegacyAlwaysOnTriggerLikeWeb() {
        let yaml = """
        agents:
          alwaysOn:
            discovery:
              trigger:
                enabled: true
                tickIntervalMinutes: 15
                cooldownMinutes: 45
                preferClient: webui
        """

        let values = NativeConfigService.scalarMap(from: yaml)

        XCTAssertEqual(values["alwaysOn.trigger.enabled"], "true")
        XCTAssertEqual(values["alwaysOn.trigger.tickIntervalMinutes"], "15")
        XCTAssertEqual(values["alwaysOn.trigger.cooldownMinutes"], "45")
        XCTAssertEqual(values["alwaysOn.trigger.preferChannel"], "web")
        XCTAssertNil(values["alwaysOn.discovery.trigger.enabled"])
        XCTAssertNil(values["agents.alwaysOn.discovery.trigger.enabled"])
    }

    func testNativeConfigScalarMapPrefersTopLevelAlwaysOnTriggerLikeWeb() {
        let yaml = """
        agents:
          alwaysOn:
            discovery:
              trigger:
                enabled: true
                tickIntervalMinutes: 15
        alwaysOn:
          trigger:
            enabled: false
            tickIntervalMinutes: 3
        """

        let values = NativeConfigService.scalarMap(from: yaml)

        XCTAssertEqual(values["alwaysOn.trigger.enabled"], "false")
        XCTAssertEqual(values["alwaysOn.trigger.tickIntervalMinutes"], "3")
        XCTAssertNil(values["alwaysOn.discovery.trigger.enabled"])
        XCTAssertNil(values["agents.alwaysOn.discovery.trigger.enabled"])
    }

    func testNativeConfigFormLayoutMatchesWebGroupedSectionNavigation() {
        XCTAssertTrue(NativeConfigFormLayout.usesGroupedSectionHome)
        XCTAssertFalse(NativeConfigFormLayout.usesSplitSectionNavigation)
        XCTAssertFalse(NativeConfigFormLayout.usesSectionDropdown)
        XCTAssertFalse(NativeConfigFormLayout.usesViewModeToggle)
        XCTAssertFalse(NativeConfigFormLayout.exposesRawYAMLEditor)
        XCTAssertEqual(NativeConfigFormLayout.headerActionIDs, [
            "revealInFinder",
            "import",
            "export",
            "saveAndReloadCurrent",
        ])
        XCTAssertEqual(NativeConfigFormLayout.sectionOrder, [
            .models,
            .agents,
            .router,
            .memory,
            .search,
            .alwaysOn,
            .gateway,
            .runtime,
            .customEnv,
        ])
        XCTAssertFalse(NativeConfigFormLayout.sectionOrder.contains(.raw))
    }

    func testNativeConfigReloadSummarySubsystemsMatchWebSettingsTab() {
        XCTAssertEqual(NativeConfigReloadSummary.subsystemIDs, [
            "processEnv",
            "memory",
            "router",
            "gateway",
        ])
        XCTAssertEqual(NativeConfigReloadSummary.subsystems.map(\.label), [
            .processEnv,
            .memory,
            .routerCCR,
            .gateway,
        ])
    }

    func testNativeMCPSettingsUsePilotDeckPathsAndJSONShape() throws {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

        XCTAssertEqual(
            NativeMCPConfigService.globalConfigURL(home: home).path,
            "/Users/tester/.pilotdeck/mcp.json"
        )
        XCTAssertEqual(
            NativeMCPConfigService.projectConfigURL(projectRoot: "/Users/tester/project").path,
            "/Users/tester/project/.pilotdeck/mcp.json"
        )

        let raw = """
        {
          "mcpServers": {
            "docs": {
              "url": "https://example.com/mcp",
              "headers": {
                "Authorization": "Bearer ${env:MCP_TOKEN}"
              }
            },
            "github": {
              "command": "npx",
              "args": ["-y", "@modelcontextprotocol/server-github"],
              "env": {
                "GITHUB_TOKEN": "${env:GITHUB_TOKEN}"
              },
              "perSession": true
            }
          }
        }
        """

        let draft = try NativeMCPConfigService.parse(raw: raw, path: "/tmp/mcp.json", exists: true)

        XCTAssertEqual(draft.path, "/tmp/mcp.json")
        XCTAssertTrue(draft.exists)
        XCTAssertEqual(draft.servers.map(\.name), ["docs", "github"])
        XCTAssertEqual(draft.servers.first?.transport, .http)
        XCTAssertEqual(draft.servers.first?.headersText, "Authorization=Bearer ${env:MCP_TOKEN}")
        XCTAssertEqual(draft.servers.last?.transport, .stdio)
        XCTAssertEqual(draft.servers.last?.command, "npx")
        XCTAssertEqual(draft.servers.last?.argsText, "-y\n@modelcontextprotocol/server-github")
        XCTAssertEqual(draft.servers.last?.envText, "GITHUB_TOKEN=${env:GITHUB_TOKEN}")
        XCTAssertEqual(draft.servers.last?.perSession, true)

        let serialized = try NativeMCPConfigService.rawJSON(servers: draft.servers)
        XCTAssertTrue(serialized.contains("\"mcpServers\""))
        XCTAssertTrue(serialized.contains("\"github\""))
        XCTAssertTrue(serialized.contains("\"perSession\" : true"))

        XCTAssertThrowsError(try NativeMCPConfigService.parse(raw: #"{"mcpServers":{"bad":{}}}"#, path: "", exists: true)) { error in
            XCTAssertEqual(error as? NativeMCPConfigError, .unrecognizedTransport("bad"))
        }
    }

    func testNativeConfigModelPickerOptionsMatchWebFormSelects() {
        let yaml = """
        model:
          providers:
            pilotdeck:
              protocol: openai
              url: http://example.local/v1
              models:
                main-model: {}
                small-model: {}
        models:
          entries:
            default:
              provider: pilotdeck
              name: main-model
            router_small:
              provider: pilotdeck
              name: small-model
        """
        let values = NativeConfigService.scalarMap(from: yaml)

        XCTAssertEqual(NativeConfigModelOptions.entryIDs(values: values), ["default", "pilotdeck/main-model", "pilotdeck/small-model", "router_small"])
        XCTAssertEqual(
            NativeConfigModelOptions.options(values: values, includeEmpty: true),
            ["", "default", "pilotdeck/main-model", "pilotdeck/small-model", "router_small"]
        )
        XCTAssertEqual(
            NativeConfigModelOptions.options(values: values, includeInherit: true),
            ["inherit", "default", "pilotdeck/main-model", "pilotdeck/small-model", "router_small"]
        )
    }

    func testNativeModelsConfigFormBehaviorMatchesWebSettingsTab() {
        XCTAssertTrue(NativeModelsConfigFormFields.usesProviderCards)
        XCTAssertTrue(NativeModelsConfigFormFields.usesCatalogProviderPicker)
        XCTAssertEqual(NativeModelsConfigFormFields.providerTypeOptions, ["openai", "anthropic"])
        XCTAssertEqual(NativeModelsConfigFormFields.newProviderScalars, [
            "protocol": "openai",
            "url": "",
            "apiKey": "",
            "models": "{}",
        ])
        XCTAssertFalse(NativeModelsConfigFormFields.newProviderScalars.keys.contains("transformer"))
        XCTAssertFalse(NativeModelsConfigFormFields.newProviderScalars.keys.contains("headers"))

        XCTAssertFalse(NativeModelsConfigFormFields.usesModelPoolDropdown)
        XCTAssertFalse(NativeModelsConfigFormFields.usageAssignmentsLiveInModelSection)
        XCTAssertFalse(NativeModelsConfigFormFields.entryRowsExposeProviderPicker)
        XCTAssertFalse(NativeModelsConfigFormFields.entryRowsExposeModelNameField)
        XCTAssertEqual(NativeModelsConfigFormFields.assignmentPaths, [
            "agent.model",
            "agent.subagents.default",
            "memory.model",
            "router.scenarios.default",
            "router.scenarios.background",
            "router.scenarios.think",
            "router.scenarios.longContext",
            "router.scenarios.webSearch",
            "router.tokenSaver.judge",
            "router.tokenSaver.tiers.simple.model",
            "router.tokenSaver.tiers.medium.model",
            "router.tokenSaver.tiers.complex.model",
            "router.tokenSaver.tiers.reasoning.model",
            "router.autoOrchestrate.mainAgentModel",
        ])
        XCTAssertEqual(NativeModelsConfigFormFields.newEntryScalars(firstProvider: "pilotdeck"), [
            "provider": "pilotdeck",
            "model": "",
        ])

        XCTAssertEqual(NativeAgentConfigFormFields.visiblePaths, [
            "agent.model",
            "agent.subagents.default",
        ])
    }

    func testNativeRuntimeConfigFormFieldsMatchWebSettingsTab() {
        XCTAssertEqual(NativeRuntimeConfigFormFields.visiblePaths, [
            "webui.runtime.workspacesRoot",
            "gateway.runtimePaths.generalCwd",
            "webui.runtime.apiTimeoutMs",
            "webui.runtime.databasePath",
            "webui.runtime.httpsProxy",
        ])
        XCTAssertEqual(NativeRuntimeConfigFormFields.textFields.map(\.path), [
            "webui.runtime.apiTimeoutMs",
            "webui.runtime.databasePath",
            "webui.runtime.httpsProxy",
        ])
        XCTAssertFalse(NativeRuntimeConfigFormFields.visiblePaths.contains("webui.runtime.host"))
        XCTAssertFalse(NativeRuntimeConfigFormFields.visiblePaths.contains("webui.runtime.serverPort"))
        XCTAssertFalse(NativeRuntimeConfigFormFields.visiblePaths.contains("webui.runtime.vitePort"))
        XCTAssertFalse(NativeRuntimeConfigFormFields.visiblePaths.contains("webui.runtime.proxyPort"))
        XCTAssertFalse(NativeRuntimeConfigFormFields.visiblePaths.contains("webui.runtime.contextWindow"))
    }

    func testNativeSearchConfigFormFieldsExposeWebSearchProviders() {
        let primaryFields = NativeSearchConfigFormFields.primaryFields
        let customFields = NativeSearchConfigFormFields.customFields

        XCTAssertEqual(
            NativeSearchConfigFormFields.visiblePaths,
            [
                "tools.webSearch.provider",
                "tools.webSearch.apiKey",
                "tools.webSearch.endpoint",
                "tools.webSearch.customProvider.name",
                "tools.webSearch.customProvider.auth",
                "tools.webSearch.customProvider.method",
                "tools.webSearch.customProvider.queryParam",
                "tools.webSearch.customProvider.apiKeyParam",
                "tools.webSearch.customProvider.resultsPath",
                "tools.webSearch.customProvider.titleField",
                "tools.webSearch.customProvider.urlField",
                "tools.webSearch.customProvider.snippetField",
                "tools.webSearch.customProvider.sourceField",
                "tools.webSearch.customProvider.publishedAtField",
            ]
        )
        XCTAssertEqual(NativeSearchConfigFormFields.providerOptions, ["glm", "tavily", "custom"])
        XCTAssertTrue(NativeSearchConfigFormFields.exposesTestConnectionAction)
        XCTAssertEqual(Set(primaryFields.filter(\.isSecure).map(\.path)), ["tools.webSearch.apiKey"])
        XCTAssertTrue(customFields.filter(\.isSecure).isEmpty)
        XCTAssertEqual(primaryFields.map(\.label), [
            .apiKey,
            .endpointURL,
        ])
        XCTAssertFalse(NativeSearchConfigFormFields.visiblePaths.contains("tools.webSearch.organicLimit"))
        XCTAssertFalse(NativeSearchConfigFormFields.visiblePaths.contains("tools.webSearch.timeoutMs"))
        XCTAssertEqual(customFields.map(\.label), [
            .customProviderName,
            .customAuth,
            .customMethod,
            .queryParam,
            .apiKeyParam,
            .resultsPath,
            .titleField,
            .urlField,
            .snippetField,
            .sourceField,
            .publishedAtField,
        ])
    }

    func testNativeSearchConfigLabelsMatchWebSettingsTabCopy() {
        let english = LocalizationService(language: .english)
        let chinese = LocalizationService(language: .chineseSimplified)

        XCTAssertEqual(
            english.text(.searchSectionDetail),
            "Web search backing the agent's WebSearch tool. Select one provider; provider-specific request shapes stay behind the adapter."
        )
        XCTAssertEqual(
            english.text(.searchProviderDetail),
            "Choose GLM/Z.AI, Tavily, or a custom JSON API."
        )
        XCTAssertEqual(english.text(.search), "Search")
        XCTAssertEqual(english.text(.apiKey), "API key")
        XCTAssertEqual(english.text(.endpointURL), "Endpoint URL")
        XCTAssertEqual(english.text(.organicLimit), "Organic limit")
        XCTAssertEqual(english.text(.customProvider), "Custom provider")

        XCTAssertEqual(
            chinese.text(.searchSectionDetail),
            "智能体 WebSearch 工具使用的网络搜索配置。只选择一个提供商，具体请求格式由适配器处理。"
        )
        XCTAssertEqual(chinese.text(.search), "搜索")
        XCTAssertEqual(chinese.text(.endpointURL), "Endpoint URL")
    }

    func testNativeSearchConnectionTesterBuildsProviderRequests() throws {
        let glm = try NativeSearchConnectionTester.request(values: [
            "tools.webSearch.provider": "glm",
            "tools.webSearch.apiKey": "glm-key",
        ], environment: [:], query: "hello")
        XCTAssertEqual(glm.url?.absoluteString, "https://api.z.ai/api/paas/v4/web_search")
        XCTAssertEqual(glm.httpMethod, "POST")
        XCTAssertEqual(glm.value(forHTTPHeaderField: "Authorization"), "Bearer glm-key")

        let tavily = try NativeSearchConnectionTester.request(values: [
            "tools.webSearch.provider": "tavily",
            "tools.webSearch.endpoint": "https://api.z.ai/api/paas/v4/web_search",
            "tools.webSearch.apiKey": "tavily-key",
        ], environment: [:], query: "hello")
        XCTAssertEqual(tavily.url?.absoluteString, "https://api.tavily.com/search")
        XCTAssertEqual(tavily.httpMethod, "POST")

        let custom = try NativeSearchConnectionTester.request(values: [
            "tools.webSearch.provider": "custom",
            "tools.webSearch.endpoint": "https://search.example.test/api",
            "tools.webSearch.customProvider.auth": "none",
            "tools.webSearch.customProvider.method": "GET",
            "tools.webSearch.customProvider.queryParam": "q",
        ], environment: [:], query: "hello world")
        XCTAssertEqual(custom.httpMethod, "GET")
        XCTAssertEqual(custom.url?.query, "q=hello%20world")

        XCTAssertThrowsError(try NativeSearchConnectionTester.request(values: [
            "tools.webSearch.provider": "glm",
        ], environment: [:]))
    }

    func testNativeMemoryConfigFormFieldsMatchWebSettingsTab() {
        XCTAssertEqual(NativeMemoryConfigFormFields.visiblePaths, [
            "memory.enabled",
            "memory.model",
        ])
        XCTAssertEqual(NativeMemoryConfigFormFields.scheduleFields.map(\.path), [
            "memory.autoIndexIntervalMinutes",
            "memory.autoDreamIntervalMinutes",
        ])
        XCTAssertTrue(NativeModelsConfigFormFields.assignmentPaths.contains("memory.model"))
        XCTAssertFalse(NativeMemoryConfigFormFields.visiblePaths.contains("memory.captureStrategy"))
        XCTAssertFalse(NativeMemoryConfigFormFields.visiblePaths.contains("memory.includeAssistant"))
        XCTAssertFalse(NativeMemoryConfigFormFields.visiblePaths.contains("memory.reasoningMode"))
        XCTAssertFalse(NativeMemoryConfigFormFields.visiblePaths.contains("memory.maxMessageChars"))
        XCTAssertFalse(NativeMemoryConfigFormFields.visiblePaths.contains("memory.heartbeatBatchSize"))
    }

    func testNativeMemorySettingsTransferActionsIncludeClear() {
        XCTAssertEqual(NativeMemorySettingsTransferActions.currentProject, ["import", "export", "clear"])
        XCTAssertEqual(NativeMemorySettingsTransferActions.allMemory, ["import", "export", "clear"])
    }

    func testNativeAlwaysOnConfigFormFieldsMatchWebSettingsTab() {
        XCTAssertEqual(NativeAlwaysOnConfigFormFields.visiblePaths, [
            "alwaysOn.enabled",
            "alwaysOn.trigger.enabled",
            "alwaysOn.trigger.preferChannel",
            "alwaysOn.dormancy.enabled",
            "alwaysOn.dormancy.debounceMs",
            "alwaysOn.dormancy.ignoreGlobs",
            "alwaysOn.workspace.gitLfs",
            "alwaysOn.trigger.tickIntervalMinutes",
            "alwaysOn.trigger.cooldownMinutes",
            "alwaysOn.trigger.dailyBudget",
            "alwaysOn.trigger.heartbeatStaleSeconds",
            "alwaysOn.trigger.recentUserMsgMinutes",
            "alwaysOn.workspace.gitWorktreeBaseDir",
            "alwaysOn.workspace.snapshotBaseDir",
            "alwaysOn.workspace.snapshotMaxBytes",
            "alwaysOn.execution.maxTurns",
            "alwaysOn.execution.maxToolCalls",
            "alwaysOn.execution.timeoutMinutes",
        ])
        XCTAssertFalse(NativeAlwaysOnConfigFormFields.visiblePaths.contains("alwaysOn.discovery.trigger.preferClient"))
    }

    func testNativeRouterAndGatewayConfigFormFieldsMatchWebSettingsTab() {
        XCTAssertEqual(NativeRouterConfigFormFields.visiblePaths, [
            "router.enabled",
            "router.scenarios.default",
            "router.tokenSaver.enabled",
            "router.tokenSaver.judge",
            "router.tokenSaver.defaultTier",
            "router.tokenSaver.judgeTimeoutMs",
            "router.tokenSaver.subagent.policy",
            "router.tokenSaver.tiers.simple.model",
            "router.tokenSaver.tiers.medium.model",
            "router.tokenSaver.tiers.complex.model",
            "router.tokenSaver.tiers.reasoning.model",
            "router.tokenSaver.rules",
            "router.zeroUsageRetry.enabled",
            "router.zeroUsageRetry.maxAttempts",
            "router.autoOrchestrate.enabled",
            "router.autoOrchestrate.triggerTiers",
            "router.autoOrchestrate.slimSystemPrompt",
            "router.stats.enabled",
            "router.fallback.default",
            "router.fallback.background",
            "router.tokenSaver.tiers.simple.description",
            "router.tokenSaver.tiers.medium.description",
            "router.tokenSaver.tiers.complex.description",
            "router.tokenSaver.tiers.reasoning.description",
            "router.stats.modelPricing.default.input",
            "router.stats.modelPricing.default.output",
            "router.stats.modelPricing.default.cacheRead",
        ])
        XCTAssertEqual(NativeRouterConfigFormFields.routeModelFields.map(\.path), [
            "router.scenarios.default",
        ])
        XCTAssertFalse(NativeRouterConfigFormFields.visiblePaths.contains("router.log"))
        XCTAssertFalse(NativeRouterConfigFormFields.visiblePaths.contains("router.scenarios.think"))
        XCTAssertFalse(NativeRouterConfigFormFields.visiblePaths.contains("router.scenarios.longContext"))
        XCTAssertFalse(NativeRouterConfigFormFields.visiblePaths.contains("router.scenarios.webSearch"))
        XCTAssertFalse(NativeRouterConfigFormFields.visiblePaths.contains("router.tokenStats.defaultCostPerMillion"))
        XCTAssertFalse(NativeRouterConfigFormFields.visiblePaths.contains("router.transientRetry.enabled"))
        XCTAssertTrue(NativeRouterConfigFormFields.visiblePaths.contains("router.scenarios.default"))
        XCTAssertTrue(NativeRouterConfigFormFields.visiblePaths.contains("router.tokenSaver.enabled"))

        XCTAssertTrue(NativeGatewayConfigFormFields.visiblePaths.isEmpty)
        XCTAssertFalse(NativeGatewayConfigFormFields.visiblePaths.contains("gateway.allowAllUsers"))
        XCTAssertFalse(NativeGatewayConfigFormFields.visiblePaths.contains("gateway.groupSessionsPerUser"))
        XCTAssertFalse(NativeGatewayConfigFormFields.visiblePaths.contains("gateway.runtimePaths.generalCwd"))
    }

    func testToolPermissionQuickRulesMatchWebSettingsTab() {
        XCTAssertEqual(
            ToolPermissionSettings.quickAllowedTools,
            [
                "Bash(git log:*)",
                "Bash(git diff:*)",
                "Bash(git status:*)",
                "Read",
                "Write",
                "Edit",
                "Glob",
                "Grep",
                "MultiEdit",
                "Task",
                "TodoWrite",
            ]
        )
        XCTAssertEqual(
            ToolPermissionSettings.quickBlockedTools,
            [
                "Bash(rm:*)",
                "Bash(sudo:*)",
                "WebFetch",
            ]
        )
    }

    func testPermissionsExportDefaultsMatchWebNaming() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-05-23T23:55:00Z"))

        XCTAssertEqual(PermissionsExportDefaults.source, "pilotdeck")
        XCTAssertEqual(
            PermissionsExportDefaults.filename(date: date),
            "pilotdeck-permissions-2026-05-23.json"
        )
    }

    @MainActor
    func testPermissionsExportUsesPilotDeckPayloadShape() throws {
        let state = makeTestAppState()
        state.settings.permissions.allowedTools = ["Bash(git log:*)", "MultiEdit"]
        state.settings.permissions.disallowedTools = ["Bash(rm:*)"]
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pilotdeck-permissions-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        try state.exportPermissions(to: url)

        let data = try Data(contentsOf: url)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(payload["version"] as? Int, 1)
        XCTAssertEqual(payload["source"] as? String, "pilotdeck")
        XCTAssertNotNil(payload["exportedAt"] as? String)
        XCTAssertEqual(payload["allowedTools"] as? [String], ["Bash(git log:*)", "MultiEdit"])
        XCTAssertEqual(payload["disallowedTools"] as? [String], ["Bash(rm:*)"])
    }

    @MainActor
    func testPermissionsSettingsAddAndImportKeepListsExclusiveAndIgnoreWebSearchBlocks() throws {
        let state = makeTestAppState()
        state.settings.permissions.allowedTools = ["Read"]
        state.settings.permissions.disallowedTools = ["Write"]

        state.addAllowedTool("Write")
        state.addBlockedTool("Read")
        state.addBlockedTool("WebSearch")

        XCTAssertEqual(state.settings.permissions.allowedTools, ["Write"])
        XCTAssertEqual(state.settings.permissions.disallowedTools, ["Read"])

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pilotdeck-permissions-import-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let payload: [String: Any] = [
            "allowedTools": ["Bash(git log:*)", "WebSearch"],
            "disallowedTools": ["WebSearch", "Bash(rm:*)"],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: url)

        try state.importPermissions(from: url)

        XCTAssertEqual(state.settings.permissions.allowedTools, [
            "Write",
            "Bash(git log:*)",
            "WebSearch",
        ])
        XCTAssertEqual(state.settings.permissions.disallowedTools, [
            "Read",
            "Bash(rm:*)",
        ])
    }

    func testNormalizedSettingsDropsLegacyWebSearchBlock() {
        var settings = AppSettings.defaults
        settings.permissions.allowedTools = ["WebSearch"]
        settings.permissions.disallowedTools = ["WebSearch", "web_search", "Bash(rm:*)"]

        let normalized = AppState.normalizedSettings(settings)

        XCTAssertEqual(normalized.permissions.allowedTools, ["WebSearch"])
        XCTAssertEqual(normalized.permissions.disallowedTools, ["Bash(rm:*)"])
    }

    @MainActor
    func testChatPermissionGrantStillClearsMatchingBlockedRuleLikeWebGrantButton() {
        let state = makeTestAppState()
        state.settings.permissions.allowedTools = []
        state.settings.permissions.disallowedTools = ["Write", "Bash(rm:*)"]

        state.grantAllowedToolFromChat("Write")

        XCTAssertEqual(state.settings.permissions.allowedTools, ["Write"])
        XCTAssertEqual(state.settings.permissions.disallowedTools, ["Bash(rm:*)"])
    }

    func testComposerPermissionModeStorageMatchesWebLocalStorageKeys() throws {
        let suiteName = "pilotdeck-permission-mode-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(ComposerPermissionModeStorage.defaultKey, "permissionMode-default")
        XCTAssertEqual(ComposerPermissionModeStorage.sessionKeyPrefix, "permissionMode-")
        XCTAssertEqual(ComposerPermissionModeStorage.storedMode(for: nil, defaults: defaults), .default)

        defaults.set("acceptEdits", forKey: ComposerPermissionModeStorage.defaultKey)
        XCTAssertEqual(ComposerPermissionModeStorage.storedMode(for: nil, defaults: defaults), .default)

        ComposerPermissionModeStorage.save(.bypassPermissions, for: nil, defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: ComposerPermissionModeStorage.defaultKey), "bypassPermissions")
        XCTAssertEqual(ComposerPermissionModeStorage.storedMode(for: nil, defaults: defaults), .bypassPermissions)
        XCTAssertEqual(ComposerPermissionModeStorage.storedMode(for: "session-a", defaults: defaults), .bypassPermissions)

        defaults.set("default", forKey: "\(ComposerPermissionModeStorage.sessionKeyPrefix)session-a")
        XCTAssertEqual(ComposerPermissionModeStorage.storedMode(for: "session-a", defaults: defaults), .default)

        ComposerPermissionModeStorage.save(.bypassPermissions, for: "session-a", defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: "\(ComposerPermissionModeStorage.sessionKeyPrefix)session-a"), "bypassPermissions")
        XCTAssertEqual(ComposerPermissionModeStorage.storedMode(for: "session-a", defaults: defaults), .bypassPermissions)
    }

    func testNativeUIPreferencesStorageMatchesWebDefaultsAndLegacyFallback() throws {
        let suiteName = "pilotdeck-ui-prefs-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(NativeUIPreferencesStorage.storageKey, "uiPreferences")
        XCTAssertEqual(NativeUIPreferencesStorage.storedPreferences(defaults: defaults), NativeUIPreferences())

        defaults.set("not-json", forKey: NativeUIPreferencesStorage.storageKey)
        defaults.set("false", forKey: "sidebarVisible")
        defaults.set("false", forKey: "showThinking")
        defaults.set("true", forKey: "sendByCtrlEnter")

        var preferences = NativeUIPreferencesStorage.storedPreferences(defaults: defaults)
        XCTAssertFalse(preferences.sidebarVisible)
        XCTAssertFalse(preferences.showThinking)
        XCTAssertTrue(preferences.sendByCtrlEnter)
        XCTAssertFalse(preferences.autoExpandTools)
        XCTAssertTrue(preferences.autoScrollToBottom)

        defaults.set("""
        {"sidebarVisible":true,"autoScrollToBottom":false,"showRawParameters":true,"sendByCtrlEnter":"false","showThinking":false}
        """, forKey: NativeUIPreferencesStorage.storageKey)

        preferences = NativeUIPreferencesStorage.storedPreferences(defaults: defaults)
        XCTAssertTrue(preferences.sidebarVisible)
        XCTAssertFalse(preferences.autoScrollToBottom)
        XCTAssertTrue(preferences.showRawParameters)
        XCTAssertFalse(preferences.sendByCtrlEnter)
        XCTAssertFalse(preferences.showThinking)
        XCTAssertFalse(preferences.autoExpandTools)
    }

    func testNativeUIPreferencesStorageSavesUnifiedSidebarVisibility() throws {
        let suiteName = "pilotdeck-ui-prefs-save-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        NativeUIPreferencesStorage.saveSidebarVisible(false, defaults: defaults)

        let storedText = try XCTUnwrap(defaults.string(forKey: NativeUIPreferencesStorage.storageKey))
        let storedData = try XCTUnwrap(storedText.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: storedData) as? [String: Bool])
        XCTAssertEqual(object["sidebarVisible"], false)
        XCTAssertEqual(object["showThinking"], true)
        XCTAssertEqual(object["autoScrollToBottom"], true)

        let preferences = NativeUIPreferencesStorage.storedPreferences(defaults: defaults)
        XCTAssertFalse(preferences.sidebarVisible)
        XCTAssertTrue(preferences.showThinking)
        XCTAssertTrue(preferences.autoScrollToBottom)
    }

    func testToolRowExpansionPolicyUsesAutoExpandToolsWithManualOverride() {
        let id = "tool:read-1"
        var expandedIDs = Set<String>()
        var collapsedIDs = Set<String>()

        XCTAssertFalse(ToolRowExpansionPolicy.isExpanded(
            id: id,
            expandedIDs: expandedIDs,
            collapsedIDs: collapsedIDs,
            autoExpandTools: false
        ))
        XCTAssertTrue(ToolRowExpansionPolicy.isExpanded(
            id: id,
            expandedIDs: expandedIDs,
            collapsedIDs: collapsedIDs,
            autoExpandTools: true
        ))

        ToolRowExpansionPolicy.toggle(
            id: id,
            expandedIDs: &expandedIDs,
            collapsedIDs: &collapsedIDs,
            autoExpandTools: true
        )
        XCTAssertTrue(collapsedIDs.contains(id))
        XCTAssertFalse(ToolRowExpansionPolicy.isExpanded(
            id: id,
            expandedIDs: expandedIDs,
            collapsedIDs: collapsedIDs,
            autoExpandTools: true
        ))

        ToolRowExpansionPolicy.toggle(
            id: id,
            expandedIDs: &expandedIDs,
            collapsedIDs: &collapsedIDs,
            autoExpandTools: true
        )
        XCTAssertTrue(expandedIDs.contains(id))
        XCTAssertFalse(collapsedIDs.contains(id))
        XCTAssertTrue(ToolRowExpansionPolicy.isExpanded(
            id: id,
            expandedIDs: expandedIDs,
            collapsedIDs: collapsedIDs,
            autoExpandTools: false
        ))
    }

    func testShellWorkingDirectoryRejectsRelativeOrMissingPaths() {
        XCTAssertThrowsError(try AgentToolExecutor.validatedWorkingDirectory("general")) { error in
            XCTAssertTrue(error.localizedDescription.contains("absolute path"))
        }
        XCTAssertThrowsError(try AgentToolExecutor.validatedWorkingDirectory("/tmp/pilotdeck-missing-\(UUID().uuidString)")) { error in
            XCTAssertTrue(error.localizedDescription.contains("does not exist"))
        }
    }

    func testNativeConfigServiceResolvesRouterDefaultEntry() throws {
        let yaml = """
        runtime:
          apiTimeoutMs: 90000
          contextWindow: 120000
          workspacesRoot: /Users/tester
        gateway:
          runtimePaths:
            generalCwd: /Users/tester/PilotDeck/general
        models:
          providers:
            pilotdeck:
              type: openai-chat
              baseUrl: http://example.local/v1
              apiKey: local-secret
              headers:
                X-Test: enabled
            pilotdeck_router:
              type: openai-chat
              baseUrl: http://router.local/v1
              apiKey: router-secret
          entries:
            default:
              provider: pilotdeck
              name: qwen3.6-27b
              contextWindow: 160000
            router_small:
              provider: pilotdeck_router
              name: qwen3.6-35b-a3b
              contextWindow: 64000
        router:
          routes:
            default:
              model: router_small
        """

        let snapshot = try XCTUnwrap(NativeConfigService.snapshot(from: yaml))
        let routerProvider = try XCTUnwrap(NativeConfigService.providerConfig(entryID: snapshot.defaultEntryID, values: snapshot.rawValues))

        XCTAssertEqual(snapshot.mainEntryID, "default")
        XCTAssertEqual(snapshot.defaultEntryID, "router_small")
        XCTAssertEqual(snapshot.providerConfig.baseURL, "http://example.local/v1")
        XCTAssertEqual(snapshot.providerConfig.model, "qwen3.6-27b")
        XCTAssertEqual(snapshot.apiKey, "local-secret")
        XCTAssertEqual(snapshot.apiTimeoutMs, 90_000)
        XCTAssertEqual(snapshot.contextWindow, 160_000)
        XCTAssertEqual(routerProvider.baseURL, "http://router.local/v1")
        XCTAssertEqual(routerProvider.model, "qwen3.6-35b-a3b")
        XCTAssertEqual(NativeConfigService.contextWindow(entryID: snapshot.defaultEntryID, values: snapshot.rawValues), 64_000)
    }

    func testNativeConfigServiceCapsModelCapabilityContextWithAgentMaxTokens() throws {
        let yaml = """
        schemaVersion: 1
        agent:
          model: edgeclaw/qwen3.6-27b
          maxContextTokens: 8000
        model:
          providers:
            edgeclaw:
              protocol: openai
              url: http://example.local/v1
              models:
                qwen3.6-27b:
                  capabilities:
                    maxContextTokens: 160000
                    maxOutputTokens: 16384
        router:
          scenarios:
            default: edgeclaw/qwen3.6-27b
        """

        let snapshot = try XCTUnwrap(NativeConfigService.snapshot(from: yaml))

        XCTAssertEqual(snapshot.contextWindow, 8_000)
        XCTAssertEqual(NativeConfigService.contextWindow(entryID: snapshot.mainEntryID, values: snapshot.rawValues), 8_000)
        XCTAssertEqual(NativeConfigService.contextWindow(entryID: snapshot.defaultEntryID, values: snapshot.rawValues), 8_000)
    }

    func testNativeConfigServiceAcceptsDirectRouterDefaultField() throws {
        let yaml = """
        models:
          providers:
            pilotdeck:
              type: openai-chat
              baseUrl: http://example.local/v1
            router:
              type: openai-chat
              baseUrl: http://router.local/v1
              apiKey: router-secret
          entries:
            default:
              provider: pilotdeck
              name: default-model
            direct_router:
              provider: router
              name: routed-model
              contextWindow: 96000
        router:
          default: direct_router
        """

        let snapshot = try XCTUnwrap(NativeConfigService.snapshot(from: yaml))
        let routerProvider = try XCTUnwrap(NativeConfigService.providerConfig(entryID: snapshot.defaultEntryID, values: snapshot.rawValues))

        XCTAssertEqual(snapshot.mainEntryID, "default")
        XCTAssertEqual(snapshot.defaultEntryID, "direct_router")
        XCTAssertEqual(snapshot.providerConfig.baseURL, "http://example.local/v1")
        XCTAssertEqual(snapshot.providerConfig.model, "default-model")
        XCTAssertNil(snapshot.apiKey)
        XCTAssertEqual(snapshot.contextWindow, 160_000)
        XCTAssertEqual(routerProvider.baseURL, "http://router.local/v1")
        XCTAssertEqual(routerProvider.model, "routed-model")
        XCTAssertEqual(NativeConfigService.contextWindow(entryID: snapshot.defaultEntryID, values: snapshot.rawValues), 96_000)
    }

    func testNativeConfigServiceUsesMainModelContextWindowLikeWebRuntimeEnv() throws {
        let yaml = """
        runtime:
          contextWindow: 131072
        models:
          providers:
            pilotdeck:
              type: openai-chat
              baseUrl: http://main.local/v1
          entries:
            default:
              provider: pilotdeck
              name: default-model
            main_large:
              provider: pilotdeck
              name: main-model
              contextWindow: 262144
            router_small:
              provider: pilotdeck
              name: router-model
              contextWindow: 64000
        agents:
          main:
            model: main_large
        router:
          enabled: false
          routes:
            default:
              model: router_small
        """

        let snapshot = try XCTUnwrap(NativeConfigService.snapshot(from: yaml))
        let values = snapshot.rawValues

        XCTAssertEqual(snapshot.mainEntryID, "main_large")
        XCTAssertEqual(snapshot.defaultEntryID, "router_small")
        XCTAssertEqual(snapshot.providerConfig.model, "main-model")
        XCTAssertEqual(snapshot.contextWindow, 262_144)
        XCTAssertEqual(NativeConfigService.contextWindow(entryID: "router_small", values: values), 64_000)
        let disabledRouterDecision = NativeRouterRuntime.decision(forTier: "SIMPLE", values: values)
        XCTAssertEqual(disabledRouterDecision.entryID, "main_large")
        XCTAssertEqual(disabledRouterDecision.scenario, "default")
        XCTAssertNil(disabledRouterDecision.tier)
        XCTAssertEqual(disabledRouterDecision.resolvedFrom, "disabled")

        let withoutMainContext = """
        runtime:
          contextWindow: 131072
        models:
          providers:
            pilotdeck:
              type: openai-chat
              baseUrl: http://main.local/v1
          entries:
            default:
              provider: pilotdeck
              name: default-model
            main_large:
              provider: pilotdeck
              name: main-model
        agents:
          main:
            model: main_large
        """
        XCTAssertEqual(NativeConfigService.snapshot(from: withoutMainContext)?.contextWindow, 131_072)
    }

    func testNativeAgentRuntimeEndpointDoesNotDuplicateChatCompletions() throws {
        let full = try NativeAgentRuntime.endpointURL(
            baseURL: "https://openrouter.ai/api/v1/chat/completions",
            suffix: "chat/completions"
        )
        let base = try NativeAgentRuntime.endpointURL(
            baseURL: "http://example.local/v1/",
            suffix: "chat/completions"
        )

        XCTAssertEqual(full.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(base.absoluteString, "http://example.local/v1/chat/completions")
    }

    func testNativeAgentRuntimeNormalizesOpenAIChatStreamEvents() {
        let object: [String: Any] = [
            "choices": [
                [
                    "delta": [
                        "reasoning_content": "thinking through it",
                        "content": "hello",
                    ],
                ],
            ],
            "usage": [
                "prompt_tokens": 3,
                "completion_tokens": 4,
                "total_tokens": 7,
            ],
        ]

        let events = NativeAgentRuntime.openAIChatEvents(from: object, contextWindow: 160_000)

        XCTAssertEqual(events, [
            .reasoningDelta("thinking through it"),
            .contentDelta("hello"),
            .tokenUsage(RouterTokenUsage(inputTokens: 3, outputTokens: 4, cacheReadTokens: 0, totalTokens: 7), contextWindow: 160_000),
        ])
    }

    func testNativeAgentRuntimeTokenUsageKeepsConfiguredContextWindowWhenOverBudget() {
        let object: [String: Any] = [
            "choices": [],
            "usage": [
                "prompt_tokens": 47_000,
                "completion_tokens": 588,
                "total_tokens": 47_588,
            ],
        ]

        let events = NativeAgentRuntime.openAIChatEvents(from: object, contextWindow: 8_000)

        XCTAssertEqual(events, [
            .tokenUsage(RouterTokenUsage(inputTokens: 47_000, outputTokens: 588, cacheReadTokens: 0, totalTokens: 47_588), contextWindow: 8_000),
        ])
    }

    func testNativeAgentRuntimeNormalizesCCRThinkingObjectDeltas() {
        let thinkingObject: [String: Any] = [
            "choices": [
                [
                    "delta": [
                        "thinking": [
                            "content": "response summary",
                        ],
                    ],
                ],
            ],
        ]
        let signatureOnlyObject: [String: Any] = [
            "choices": [
                [
                    "delta": [
                        "thinking": [
                            "signature": "reasoning-part-id",
                        ],
                        "content": "final answer",
                    ],
                ],
            ],
        ]

        XCTAssertEqual(
            NativeAgentRuntime.openAIChatEvents(from: thinkingObject, contextWindow: 160_000),
            [.reasoningDelta("response summary")]
        )
        XCTAssertEqual(
            NativeAgentRuntime.openAIChatEvents(from: signatureOnlyObject, contextWindow: 160_000),
            [.contentDelta("final answer")]
        )
    }

    func testChatBlockVisibilityPolicyMatchesWebShowThinkingPreference() {
        XCTAssertTrue(ChatBlockVisibilityPolicy.isVisible(.reasoning("thinking"), showThinking: true))
        XCTAssertFalse(ChatBlockVisibilityPolicy.isVisible(.reasoning("thinking"), showThinking: false))
        XCTAssertTrue(ChatBlockVisibilityPolicy.isVisible(.text("answer"), showThinking: false))
        XCTAssertTrue(ChatBlockVisibilityPolicy.isVisible(.toolResult(ToolResult(toolCallId: "tool", output: "ok", isError: false)), showThinking: false))
        XCTAssertTrue(ChatBlockVisibilityPolicy.isVisible(.processStatus(ProcessStatusBlock(
            id: "context-compact",
            title: "上下文压缩已完成",
            detail: nil,
            kind: .contextCompaction
        )), showThinking: false))
    }

    func testProcessStatusBlockPersistsWithoutAffectingPlainText() throws {
        let message = ChatMessage(
            id: UUID(),
            sessionId: "session",
            provider: .pilotDeck,
            role: .assistant,
            blocks: [
                .text("before"),
                .processStatus(ProcessStatusBlock(
                    id: "context-compact",
                    title: "上下文压缩已完成",
                    detail: nil,
                    kind: .contextCompaction
                )),
                .text("after"),
            ],
            createdAt: Date(timeIntervalSince1970: 1),
            isStreaming: false,
            tokenBudget: nil
        )

        XCTAssertEqual(message.plainText, "beforeafter")

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)

        XCTAssertEqual(decoded.blocks, message.blocks)
        XCTAssertEqual(decoded.plainText, "beforeafter")
    }

    func testProviderRetryPolicyMatchesCodexTransientDefaults() {
        let policy = ProviderRetryPolicy.codexDefault

        XCTAssertTrue(NativeAgentRuntime.retryDecision(
            for: ProviderClientError.transport("Network request failed: timed out"),
            failedAttempts: 0,
            policy: policy
        ).shouldRetry)
        XCTAssertTrue(NativeAgentRuntime.retryDecision(
            for: ProviderClientError.httpError(statusCode: 502, body: "bad gateway"),
            failedAttempts: 0,
            policy: policy
        ).shouldRetry)
        XCTAssertFalse(NativeAgentRuntime.retryDecision(
            for: ProviderClientError.httpError(statusCode: 429, body: "rate limited"),
            failedAttempts: 0,
            policy: policy
        ).shouldRetry)
        XCTAssertFalse(NativeAgentRuntime.retryDecision(
            for: ProviderClientError.httpError(statusCode: 400, body: "bad request"),
            failedAttempts: 0,
            policy: policy
        ).shouldRetry)
    }

    func testProviderRetryPolicyReadsRouterTransientConfig() {
        let policy = ProviderRetryPolicy.fromConfig([
            "router.transientRetry.maxAttempts": "2",
            "router.transientRetry.baseDelayMs": "50",
            "router.transientRetry.retry429": "true",
            "router.transientRetry.retry5xx": "false",
            "router.transientRetry.retryTransport": "false",
            "router.transientRetry.enabled": "false",
        ])

        XCTAssertFalse(policy.enabled)
        XCTAssertEqual(policy.streamMaxRetries, 2)
        XCTAssertEqual(policy.requestMaxRetries, 2)
        XCTAssertEqual(policy.baseDelayMs, 50)
        XCTAssertTrue(policy.retry429)
        XCTAssertFalse(policy.retry5xx)
        XCTAssertFalse(policy.retryTransport)
        XCTAssertFalse(NativeAgentRuntime.retryDecision(
            for: ProviderClientError.httpError(statusCode: 429, body: "rate limited"),
            failedAttempts: 0,
            policy: policy
        ).shouldRetry)
    }

    func testProviderRetryPolicyDoesNotReplayPartialVisibleStreams() {
        XCTAssertFalse(NativeAgentRuntime.retryDecision(
            for: ProviderClientError.streamInterruptedAfterPartialOutput("lost connection"),
            failedAttempts: 0
        ).shouldRetry)
        XCTAssertFalse(NativeAgentRuntime.retryDecision(
            for: ProviderClientError.transport("App Transport Security blocked the HTTP provider request."),
            failedAttempts: 0
        ).shouldRetry)
        XCTAssertFalse(NativeAgentRuntime.retryDecision(
            for: ProviderClientError.transport("Network request failed: timed out"),
            failedAttempts: ProviderRetryPolicy.codexDefault.streamMaxRetries
        ).shouldRetry)
    }

    func testProviderRetryBackoffUsesCodexBaseDelayWithJitter() {
        let first = NativeAgentRuntime.retryBackoffDelay(failedAttempts: 0, baseDelayMs: 200)
        let second = NativeAgentRuntime.retryBackoffDelay(failedAttempts: 1, baseDelayMs: 200)

        XCTAssertGreaterThanOrEqual(first, 0.18)
        XCTAssertLessThanOrEqual(first, 0.22)
        XCTAssertGreaterThanOrEqual(second, 0.36)
        XCTAssertLessThanOrEqual(second, 0.44)
    }

    func testNativeAgentRuntimeToolSchemasIncludePilotDeckCodeCoreTools() {
        let tools = AgentToolRegistry.openAITools()
        let names = tools.compactMap { tool -> String? in
            guard let function = tool["function"] as? [String: Any] else { return nil }
            return function["name"] as? String
        }
        let canonicalToolSet: Set<String> = [
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
            "WebSearch",
        ]

        XCTAssertEqual(Set(names), Set(AgentToolRegistry.toolNames))
        XCTAssertEqual(Set(names), canonicalToolSet)
        XCTAssertFalse(names.contains("Bash"))
        XCTAssertFalse(names.contains("Agent"))
        XCTAssertFalse(names.contains("Edit"))
        XCTAssertFalse(names.contains("ExitPlanMode"))
        XCTAssertFalse(names.contains("AskUserQuestion"))
        XCTAssertTrue(names.contains("WebSearch"))
        XCTAssertFalse(names.contains("WebFetch"))
        XCTAssertFalse(names.contains("Weather"))
    }

    func testAgentToolNameCanonicalizerKeepsPilotDeckCodeAndSubagentAliasesCompatible() {
        XCTAssertEqual(AgentToolNameCanonicalizer.canonical("Edit"), "StrReplace")
        XCTAssertEqual(AgentToolNameCanonicalizer.canonical("MultiEdit"), "StrReplace")
        XCTAssertEqual(AgentToolNameCanonicalizer.canonical("Bash"), "Shell")
        XCTAssertEqual(AgentToolNameCanonicalizer.canonical("run_command"), "Shell")
        XCTAssertEqual(AgentToolNameCanonicalizer.canonical("Agent"), "Task")
        XCTAssertEqual(AgentToolNameCanonicalizer.canonical("subagent"), "Task")
        XCTAssertEqual(AgentToolNameCanonicalizer.canonical("sub_agent"), "Task")
        XCTAssertEqual(AgentToolNameCanonicalizer.canonical("sub-agent"), "Task")
        XCTAssertEqual(AgentToolNameCanonicalizer.canonical("TaskCreate"), "Task")
        XCTAssertEqual(AgentToolNameCanonicalizer.canonical("TaskOutput"), "Await")
        XCTAssertEqual(AgentToolNameCanonicalizer.canonical("AskUserQuestion"), "AskQuestion")
        XCTAssertEqual(AgentToolNameCanonicalizer.canonical("ExitPlanMode"), "SwitchMode")
        XCTAssertEqual(AgentToolNameCanonicalizer.canonical("NotebookEdit"), "EditNotebook")
        XCTAssertEqual(AgentToolNameCanonicalizer.canonical("GetWeather"), "Weather")
    }

    func testNativeAgentRuntimeParsesFallbackJSONToolCall() {
        let text = """
        ```json
        {"tool":"Read","input":{"file_path":"README.md"}}
        ```
        """

        let calls = NativeAgentRuntime.fallbackToolCalls(in: text)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "Read")
        XCTAssertTrue(calls.first?.inputJSON.contains("README.md") == true)
    }

    func testNativeAgentRuntimeDoesNotParseMixedMarkdownFallbackToolCall() {
        let text = """
        I need to inspect the file.
        ```json
        {"tool":"Read","input":{"file_path":"README.md"}}
        ```
        """

        XCTAssertTrue(NativeAgentRuntime.fallbackToolCalls(in: text).isEmpty)
    }

    func testNativeAgentRuntimeParsesInlineSkillJSONFallback() throws {
        let text = """
        I will load a skill.
        {"skill":"code-review","args":"review this change"}
        """

        let calls = NativeAgentRuntime.fallbackToolCalls(in: text)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data((calls.first?.inputJSON ?? "{}").utf8)) as? [String: Any])

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "Skill")
        XCTAssertEqual(object["skill"] as? String, "code-review")
    }

    func testNativeAgentRuntimeParsesWebSearchFallbackToolCall() throws {
        let text = """
        {"tool":"web_search","input":{"query":"Beijing weather"}}
        """

        let calls = NativeAgentRuntime.fallbackToolCalls(in: text)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data((calls.first?.inputJSON ?? "{}").utf8)) as? [String: Any])

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "WebSearch")
        XCTAssertEqual(object["query"] as? String, "Beijing weather")
    }

    func testLegacySearchAndWeatherCallsNormalizeToWebSearch() throws {
        let search = ToolArgumentNormalizer.normalize(AgentToolCall(
            id: "search",
            name: "WebSearch",
            inputJSON: #"{"query":"Beijing weather"}"#
        ))
        let weather = ToolArgumentNormalizer.normalize(AgentToolCall(
            id: "weather",
            name: "GetWeather",
            inputJSON: #"{"location":"北京"}"#
        ))
        let missing = ToolArgumentNormalizer.normalize(AgentToolCall(
            id: "missing",
            name: "Weather",
            inputJSON: #"{"unit":"celsius"}"#
        ))

        XCTAssertEqual(search.call.name, "WebSearch")
        XCTAssertEqual(weather.call.name, "WebSearch")
        XCTAssertNil(search.recoveryResult)
        XCTAssertNil(weather.recoveryResult)

        let searchObject = try jsonObject(from: search.call.inputJSON)
        let weatherObject = try jsonObject(from: weather.call.inputJSON)
        XCTAssertEqual(searchObject["query"] as? String, "Beijing weather")
        XCTAssertEqual(weatherObject["query"] as? String, "北京 weather")
        XCTAssertEqual(missing.call.name, "WebSearch")
        XCTAssertTrue(missing.recoveryResult?.isError == true)
        XCTAssertTrue(missing.recoveryResult?.output.contains("non-empty query") == true)
    }

    func testNativeAgentRuntimeParsesLegacyCommandFallbackAsToolOnly() {
        let calls = NativeAgentRuntime.fallbackToolCalls(in: #"<command>{"input":"ls"}</command>"#)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "Glob")
        XCTAssertTrue(calls.first?.inputJSON.contains(#""pattern":"*""#) == true)
    }

    func testNativeAgentRuntimeParsesPilotDeckInvokeFallbackToolCall() {
        let text = """
        <invoke name="Skill">
        <parameter name="skill">code-review</parameter>
        <parameter name="args">review this change</parameter>
        </invoke>
        """

        let calls = NativeAgentRuntime.fallbackToolCalls(in: text)

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.name, "Skill")
        let object = try? JSONSerialization.jsonObject(with: Data((calls.first?.inputJSON ?? "{}").utf8)) as? [String: Any]
        XCTAssertEqual(object?["skill"] as? String, "code-review")
    }

    func testToolArgumentNormalizerCanonicalizesValidToolArguments() throws {
        let invocation = ToolArgumentNormalizer.normalize(
            AgentToolCall(id: "call-1", name: "Read", inputJSON: #"{"file_path":"README.md","offset":0}"#)
        )
        let data = try XCTUnwrap(invocation.call.inputJSON.data(using: .utf8))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNil(invocation.recoveryResult)
        XCTAssertEqual(object["file_path"] as? String, "README.md")
        XCTAssertEqual(object["offset"] as? Int, 0)
    }

    func testToolArgumentNormalizerTurnsMalformedArgumentsIntoRecoverableToolResult() {
        let invocation = ToolArgumentNormalizer.normalize(
            AgentToolCall(id: "call-bad", name: "Edit", inputJSON: #"{file_path:"index.html"}"#)
        )

        XCTAssertEqual(invocation.call.inputJSON, "{}")
        XCTAssertEqual(invocation.recoveryResult?.callId, "call-bad")
        XCTAssertEqual(invocation.recoveryResult?.toolName, "StrReplace")
        XCTAssertEqual(invocation.recoveryResult?.isError, true)
        XCTAssertTrue(invocation.recoveryResult?.output.contains("invalid JSON") == true)
        XCTAssertEqual(ToolArgumentNormalizer.providerSafeInputJSON(#"{file_path:"index.html"}"#), "{}")
    }

    func testToolArgumentNormalizerRejectsNonObjectArguments() {
        let invocation = ToolArgumentNormalizer.normalize(
            AgentToolCall(id: "call-string", name: "Read", inputJSON: #""README.md""#)
        )

        XCTAssertEqual(invocation.call.inputJSON, "{}")
        XCTAssertTrue(invocation.recoveryResult?.output.contains("JSON object") == true)
    }

    func testAskUserQuestionNormalizesWebAndLegacyQuestionShapes() throws {
        let webPayload = try XCTUnwrap(AgentInteractivePayload.askUserQuestion(from: """
        {"questions":[{"header":"Choose","question":"What should I build?","options":[{"label":"Landing Page","description":"Product page"},{"label":"Blog"}],"multiSelect":false}]}
        """))

        XCTAssertEqual(webPayload.questions.count, 1)
        XCTAssertEqual(webPayload.questions.first?.header, "Choose")
        XCTAssertEqual(webPayload.questions.first?.question, "What should I build?")
        XCTAssertEqual(webPayload.questions.first?.options.map(\.label), ["Landing Page", "Blog"])
        XCTAssertEqual(webPayload.questions.first?.options.first?.description, "Product page")
        XCTAssertEqual(webPayload.questions.first?.multiSelect, false)

        let legacyPayload = try XCTUnwrap(AgentInteractivePayload.askUserQuestion(from: """
        {"question":"Pick a style","options":["Minimal","Playful"]}
        """))

        XCTAssertEqual(legacyPayload.questions.count, 1)
        XCTAssertEqual(legacyPayload.questions.first?.question, "Pick a style")
        XCTAssertEqual(legacyPayload.questions.first?.options.map(\.label), ["Minimal", "Playful"])

        let repairedPayload = try XCTUnwrap(AgentInteractivePayload.askUserQuestion(from: """
        {"questions":[{"header":"计划问题","question":"**页面风格偏好？**","options":[]}]}
        """))
        XCTAssertEqual(repairedPayload.questions.first?.question, "页面风格偏好？")
        XCTAssertEqual(repairedPayload.questions.first?.options.count, 0)

        let manyOptionsPayload = try XCTUnwrap(AgentInteractivePayload.askUserQuestion(from: """
        {"questions":[{"question":"Pick features","options":["A","B","C","D","E","F"]}]}
        """))
        XCTAssertEqual(manyOptionsPayload.questions.first?.options.map(\.label), ["A", "B", "C", "D", "E", "F"])
    }

    func testAskUserQuestionUpdatedInputCarriesAnswers() throws {
        let updated = AgentInteractivePayload.updatedInputJSON(
            originalInputJSON: #"{"question":"Pick a style","options":["Minimal","Playful"]}"#,
            answers: ["Pick a style": "Minimal"]
        )
        let data = try XCTUnwrap(updated.data(using: .utf8))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let answers = try XCTUnwrap(object["answers"] as? [String: String])

        XCTAssertEqual(answers["Pick a style"], "Minimal")
    }

    func testAgentToolExecutorReturnsAskUserQuestionAnswers() {
        let call = AgentToolCall(
            id: "question-1",
            name: "AskUserQuestion",
            inputJSON: #"{"question":"Pick a style","answers":{"Pick a style":"Minimal"}}"#
        )

        let result = AgentToolExecutor.askUserQuestionResult(call: call, updatedInputJSON: call.inputJSON)

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("Pick a style"))
        XCTAssertTrue(result.output.contains("Minimal"))
        XCTAssertTrue(result.output.contains("SwitchMode"))
        XCTAssertTrue(result.output.contains("Do not stop after ordinary prose only"))
    }

    func testAgentToolExecutorRejectsEmptyAskUserQuestionAnswer() {
        let call = AgentToolCall(
            id: "question-empty",
            name: "AskQuestion",
            inputJSON: #"{"question":"确认删除吗？"}"#
        )

        let result = AgentToolExecutor.askUserQuestionResult(call: call, updatedInputJSON: call.inputJSON)

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("requires a user answer"))
    }

    func testAgentRunContextDedupesToolSignature() {
        let context = AgentRunContext(request: agentRequest(permissionMode: .bypassPermissions))
        let first = AgentToolCall(id: "call-1", name: "Read", inputJSON: #"{"file_path":"README.md"}"#)
        let repeated = AgentToolCall(id: "call-2", name: "Read", inputJSON: #"{"file_path":"README.md"}"#)

        XCTAssertTrue(context.markToolCallIfNeeded(first))
        XCTAssertFalse(context.markToolCallIfNeeded(repeated))
    }

    func testReadDeduplicationIsScopedToWorkspaceMutationEpoch() {
        let context = AgentRunContext(request: agentRequest(prompt: "fix the website", permissionMode: .bypassPermissions))
        let firstRead = AgentToolCall(id: "read-1", name: "Read", inputJSON: #"{"file_path":"index.html"}"#)
        let secondRead = AgentToolCall(id: "read-2", name: "Read", inputJSON: #"{"file_path":"index.html"}"#)

        XCTAssertNotNil(context.deduplicatedInvocation(.init(call: firstRead, recoveryResult: nil)))
        XCTAssertNil(context.deduplicatedInvocation(.init(call: secondRead, recoveryResult: nil)))

        let edit = AgentToolCall(id: "edit", name: "StrReplace", inputJSON: #"{"file_path":"index.html","old_string":"a","new_string":"b"}"#)
        context.recordToolResult(
            AgentToolResult(callId: "edit", toolName: "StrReplace", output: "Edited index.html", isError: false),
            call: edit
        )

        let thirdRead = AgentToolCall(id: "read-3", name: "Read", inputJSON: #"{"file_path":"index.html"}"#)
        XCTAssertEqual(context.workspaceMutationEpoch, 1)
        XCTAssertNotNil(context.deduplicatedInvocation(.init(call: thirdRead, recoveryResult: nil)))
    }

    func testDuplicateMutatingToolReturnsSoftPolicyResult() {
        let context = AgentRunContext(request: agentRequest(prompt: "fix the website", permissionMode: .bypassPermissions))
        let firstEdit = AgentToolCall(id: "edit-1", name: "StrReplace", inputJSON: #"{"file_path":"index.html","old_string":"a","new_string":"b"}"#)
        let repeatedEdit = AgentToolCall(id: "edit-2", name: "StrReplace", inputJSON: #"{"file_path":"index.html","old_string":"a","new_string":"b"}"#)

        XCTAssertNotNil(context.deduplicatedInvocation(.init(call: firstEdit, recoveryResult: nil)))
        let duplicate = context.deduplicatedInvocation(.init(call: repeatedEdit, recoveryResult: nil))

        XCTAssertEqual(duplicate?.recoveryResult?.isError, false)
        XCTAssertEqual(duplicate?.recoveryResult?.isPolicyBlock, true)
        XCTAssertTrue(duplicate?.recoveryResult?.output.contains("Duplicate tool request skipped") == true)
    }

    func testDuplicateTodoWriteUsesCurrentSnapshotAsNoOp() {
        let context = AgentRunContext(request: agentRequest(prompt: "fix the website", permissionMode: .bypassPermissions))
        context.todosJSON = #"[{"content":"Update HTML","status":"in_progress"}]"#
        let todo = AgentToolCall(id: "todo", name: "TodoWrite", inputJSON: #"{"todos":[{"content":"Update HTML","status":"in_progress"}]}"#)

        let duplicate = context.deduplicatedInvocation(.init(call: todo, recoveryResult: nil))

        XCTAssertEqual(duplicate?.recoveryResult?.isError, false)
        XCTAssertEqual(duplicate?.recoveryResult?.isPolicyBlock, true)
        XCTAssertTrue(duplicate?.recoveryResult?.output.contains("already up to date") == true)
    }

    func testAgentPathResolverRejectsTraversalOutsideWorkspace() throws {
        let root = repoRootURL()
            .appendingPathComponent("pilotdeck-agent-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(
            try AgentPathResolver.resolve("../escape.txt", workspacePath: root.path, mustExist: false)
        )
    }

    func testAgentEditRequiresUniqueMatchUnlessReplaceAll() throws {
        XCTAssertThrowsError(
            try AgentToolExecutor.applyEdit(
                content: "one fish one fish",
                oldString: "one",
                newString: "two",
                replaceAll: false
            )
        )

        XCTAssertEqual(
            try AgentToolExecutor.applyEdit(
                content: "one fish one fish",
                oldString: "one",
                newString: "two",
                replaceAll: true
            ),
            "two fish two fish"
        )
    }

    func testAgentPermissionPolicySoftBlocksMutatingToolsInPlanMode() {
        let context = AgentRunContext(request: agentRequest(runMode: .plan, permissionMode: .bypassPermissions))
        let call = AgentToolCall(
            id: "call-1",
            name: "Write",
            inputJSON: #"{"file_path":"index.html","content":"hi"}"#
        )

        switch AgentPermissionPolicy.policy(for: call, context: context) {
        case .block(let reason):
            XCTAssertTrue(reason.contains("Plan mode skipped"))
        default:
            XCTFail("Write should be soft-blocked before SwitchMode in plan mode.")
        }
    }

    func testPlanModeAllowsMutatingToolsAfterExitPlanMode() async {
        let context = AgentRunContext(request: agentRequest(runMode: .plan, permissionMode: .bypassPermissions))
        let exit = AgentToolCall(
            id: "exit-plan",
            name: "SwitchMode",
            inputJSON: #"{"mode":"agent","plan":"Edit index.html."}"#
        )
        _ = await AgentToolExecutor.execute(call: exit, context: context)
        let write = AgentToolCall(
            id: "call-write",
            name: "Write",
            inputJSON: #"{"file_path":"index.html","content":"hi"}"#
        )

        switch AgentPermissionPolicy.policy(for: write, context: context) {
        case .allow:
            break
        default:
            XCTFail("Write should be allowed after ExitPlanMode.")
        }
    }

    func testAllowedToolBypassesGenericPermissionPrompt() {
        var permissions = ToolPermissionSettings.defaults
        permissions.allowedTools = ["write"]
        let context = AgentRunContext(
            request: agentRequest(permissionMode: .default, toolSettings: permissions)
        )
        let call = AgentToolCall(
            id: "call-write",
            name: "Write",
            inputJSON: #"{"file_path":"index.html","content":"hi"}"#
        )

        XCTAssertEqual(AgentPermissionPolicy.policy(for: call, context: context), .allow)
    }

    func testWebBashPermissionRulesMatchNativeShellCalls() {
        var allowedPermissions = ToolPermissionSettings.defaults
        allowedPermissions.allowedTools = ["Bash(git log:*)"]
        let allowedContext = AgentRunContext(
            request: agentRequest(permissionMode: .default, toolSettings: allowedPermissions)
        )
        let gitLog = AgentToolCall(
            id: "git-log",
            name: "Shell",
            inputJSON: #"{"command":"git log --oneline"}"#
        )

        XCTAssertEqual(AgentPermissionPolicy.policy(for: gitLog, context: allowedContext), .allow)

        var blockedPermissions = ToolPermissionSettings.defaults
        blockedPermissions.disallowedTools = ["Bash(rm:*)"]
        let blockedContext = AgentRunContext(
            request: agentRequest(permissionMode: .bypassPermissions, toolSettings: blockedPermissions)
        )
        let rm = AgentToolCall(
            id: "rm-shell",
            name: "Shell",
            inputJSON: #"{"command":"rm -rf build"}"#
        )

        if case .deny(let reason) = AgentPermissionPolicy.policy(for: rm, context: blockedContext) {
            XCTAssertTrue(reason.lowercased().contains("blocked"))
        } else {
            XCTFail("Bash(...) block rules should deny matching native Shell calls.")
        }
    }

    func testWebSearchBlockRulesAreIgnoredBecauseItIsTheUnifiedWebTool() {
        var permissions = ToolPermissionSettings.defaults
        permissions.disallowedTools = ["WebSearch", "web_search"]
        let call = AgentToolCall(
            id: "web-search",
            name: "WebSearch",
            inputJSON: #"{"query":"Beijing weather today"}"#
        )

        let bypassContext = AgentRunContext(
            request: agentRequest(permissionMode: .bypassPermissions, toolSettings: permissions)
        )
        XCTAssertEqual(AgentPermissionPolicy.policy(for: call, context: bypassContext), .allow)

        let defaultContext = AgentRunContext(
            request: agentRequest(permissionMode: .default, toolSettings: permissions)
        )
        if case .ask(let reason) = AgentPermissionPolicy.policy(for: call, context: defaultContext) {
            XCTAssertTrue(reason.contains("WebSearch"))
        } else {
            XCTFail("Default mode should still ask before network search, not deny WebSearch.")
        }
    }

    func testAllowedInteractiveSwitchModeStillRequiresPlanConfirmation() {
        var permissions = ToolPermissionSettings.defaults
        permissions.allowedTools = ["exit_plan_mode"]
        let context = AgentRunContext(
            request: agentRequest(runMode: .plan, permissionMode: .default, toolSettings: permissions)
        )
        context.planQuestionAnswered = true
        let call = AgentToolCall(
            id: "exit-plan",
            name: "SwitchMode",
            inputJSON: #"{"mode":"agent","plan":"Edit index.html."}"#
        )

        if case .ask(let reason) = AgentPermissionPolicy.policy(for: call, context: context) {
            XCTAssertTrue(reason.lowercased().contains("plan approval"))
        } else {
            XCTFail("Allowed tools must not bypass Plan exit confirmation.")
        }
    }

    func testPlanSwitchModeRequiresAskQuestionBeforeConfirmation() {
        let context = AgentRunContext(request: agentRequest(runMode: .plan, permissionMode: .bypassPermissions))
        let call = AgentToolCall(
            id: "exit-plan-before-question",
            name: "SwitchMode",
            inputJSON: #"{"mode":"agent","plan":"Edit index.html."}"#
        )

        if case .block(let reason) = AgentPermissionPolicy.policy(for: call, context: context) {
            XCTAssertTrue(reason.contains("AskQuestion"))
        } else {
            XCTFail("Plan mode must soft-block exit before AskQuestion is answered.")
        }

        context.planQuestionAnswered = true
        if case .ask(let reason) = AgentPermissionPolicy.policy(for: call, context: context) {
            XCTAssertTrue(reason.lowercased().contains("plan approval"))
        } else {
            XCTFail("Plan exit should ask after the planning question is answered.")
        }
    }

    func testAskQuestionRequiresUserInteractionEvenWithBypassPermissions() {
        let context = AgentRunContext(request: agentRequest(permissionMode: .bypassPermissions))
        let call = AgentToolCall(
            id: "ask-question",
            name: "AskQuestion",
            inputJSON: #"{"question":"确认删除吗？","options":["删除","取消"]}"#
        )

        if case .ask(let reason) = AgentPermissionPolicy.policy(for: call, context: context) {
            XCTAssertTrue(reason.lowercased().contains("question"))
        } else {
            XCTFail("AskQuestion must not be auto-answered in bypass mode.")
        }
    }

    func testDestructiveDeleteRequiresPlanApprovalInAgentMode() {
        let context = AgentRunContext(request: agentRequest(permissionMode: .bypassPermissions))
        let call = AgentToolCall(
            id: "delete-root",
            name: "Delete",
            inputJSON: #"{"path":".","recursive":true}"#
        )

        if case .ask(let reason) = AgentPermissionPolicy.policy(for: call, context: context) {
            XCTAssertTrue(reason.lowercased().contains("destructive"))
        } else {
            XCTFail("Delete should require destructive plan approval in Agent mode.")
        }

        context.planExecutionApproved = true
        XCTAssertEqual(AgentPermissionPolicy.policy(for: call, context: context), .allow)
    }

    func testBypassAllowsLowRiskWorkspaceFileDeleteOnly() throws {
        let root = try makeAgentWorkspace("pilotdeck-low-risk-delete")
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("chrome_game.png")
        try "debug screenshot".write(to: file, atomically: true, encoding: .utf8)
        let call = AgentToolCall(
            id: "delete-file",
            name: "Delete",
            inputJSON: #"{"path":"chrome_game.png"}"#
        )

        let bypassContext = AgentRunContext(request: agentRequest(projectPath: root.path, permissionMode: .bypassPermissions))
        XCTAssertEqual(AgentPermissionPolicy.policy(for: call, context: bypassContext), .allow)

        let defaultContext = AgentRunContext(request: agentRequest(projectPath: root.path, permissionMode: .default))
        if case .ask(let reason) = AgentPermissionPolicy.policy(for: call, context: defaultContext) {
            XCTAssertTrue(reason.lowercased().contains("destructive"))
        } else {
            XCTFail("Default permission mode should still ask before deleting workspace files.")
        }
    }

    func testBypassStillAsksForUnsafeDeletionTargets() throws {
        let root = try makeAgentWorkspace("pilotdeck-unsafe-delete")
        defer { try? FileManager.default.removeItem(at: root) }

        let directory = root.appendingPathComponent("screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let protectedFile = root.appendingPathComponent(".env")
        try "TOKEN=secret".write(to: protectedFile, atomically: true, encoding: .utf8)
        let outsideFile = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).txt")
        try "outside".write(to: outsideFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outsideFile) }

        let context = AgentRunContext(request: agentRequest(projectPath: root.path, permissionMode: .bypassPermissions))
        let unsafeDeletes = [
            AgentToolCall(id: "delete-directory", name: "Delete", inputJSON: #"{"path":"screenshots"}"#),
            AgentToolCall(id: "delete-protected", name: "Delete", inputJSON: #"{"path":".env"}"#),
            AgentToolCall(id: "delete-outside", name: "Delete", inputJSON: #"{"path":"\#(outsideFile.path)"}"#),
            AgentToolCall(id: "delete-recursive", name: "Delete", inputJSON: #"{"path":"chrome_game.png","recursive":true}"#),
            AgentToolCall(id: "delete-recursive-string", name: "Delete", inputJSON: #"{"path":"chrome_game.png","recursive":"true"}"#),
        ]

        for call in unsafeDeletes {
            if case .ask(let reason) = AgentPermissionPolicy.policy(for: call, context: context) {
                XCTAssertTrue(reason.lowercased().contains("destructive"))
            } else {
                XCTFail("\(call.id) should still require deletion approval in bypass mode.")
            }
        }
    }

    func testDestructiveShellRequiresPlanApprovalInAgentMode() {
        let context = AgentRunContext(request: agentRequest(permissionMode: .bypassPermissions))
        let call = AgentToolCall(
            id: "rm-shell",
            name: "Shell",
            inputJSON: #"{"command":"rm -rf public"}"#
        )

        XCTAssertTrue(DestructiveToolClassifier.isDestructive(call: call))
        if case .ask(let reason) = AgentPermissionPolicy.policy(for: call, context: context) {
            XCTAssertTrue(reason.lowercased().contains("destructive"))
        } else {
            XCTFail("Deletion shell commands should require destructive plan approval.")
        }
    }

    func testBlockedToolOverridesAllowedAndBypassPermissionMode() {
        var permissions = ToolPermissionSettings.defaults
        permissions.allowedTools = ["Write"]
        permissions.disallowedTools = ["write"]
        let context = AgentRunContext(
            request: agentRequest(permissionMode: .bypassPermissions, toolSettings: permissions)
        )
        let call = AgentToolCall(
            id: "call-write",
            name: "Write",
            inputJSON: #"{"file_path":"index.html","content":"hi"}"#
        )

        switch AgentPermissionPolicy.policy(for: call, context: context) {
        case .deny(let reason):
            XCTAssertTrue(reason.lowercased().contains("blocked"))
        default:
            XCTFail("Blocked tool should deny before allowed tools or bypass mode.")
        }
    }

    func testWorkspaceMutationDoesNotCompleteAfterOneExploratoryTool() {
        let request = agentRequest(prompt: "帮我继续优化一下这个网页", permissionMode: .bypassPermissions)
        let context = AgentRunContext(request: request)
        let call = AgentToolCall(id: "glob", name: "Glob", inputJSON: #"{"pattern":"**/*","path":"."}"#)
        context.recordToolResult(
            AgentToolResult(callId: "glob", toolName: "Glob", output: "index.html", isError: false),
            call: call
        )

        let nudge = NativeAgentRuntime.continuationNudge(
            request: request,
            context: context,
            assistantContent: "I found index.html."
        )

        XCTAssertNotNil(nudge)
        XCTAssertTrue(nudge?.contains("not completed") == true)
    }

    func testReadOnlyFileListingDoesNotForceSecondBootstrapAfterAnswer() {
        let request = agentRequest(prompt: "帮我看看这个路径里都有哪些文件？", permissionMode: .bypassPermissions)
        let context = AgentRunContext(request: request)

        XCTAssertTrue(
            NativeAgentRuntime.shouldForceWorkspaceBootstrap(
                request: request,
                context: context,
                assistantContent: "这个路径下有一些文件。"
            )
        )

        let call = AgentToolCall(id: "glob", name: "Glob", inputJSON: #"{"pattern":"**/*","path":"."}"#)
        context.recordToolResult(
            AgentToolResult(callId: "glob", toolName: "Glob", output: "a.docx\nb.docx", isError: false),
            call: call
        )

        XCTAssertFalse(
            NativeAgentRuntime.shouldForceWorkspaceBootstrap(
                request: request,
                context: context,
                assistantContent: "这个路径下共有 2 个文件。"
            )
        )
        XCTAssertTrue(
            CompletionGate.canFinish(
                request: request,
                context: context,
                assistantContent: "这个路径下共有 2 个文件。"
            )
        )
    }

    func testWorkspaceMutationContinuationHasLimit() {
        let request = agentRequest(prompt: "fix the website", permissionMode: .bypassPermissions)
        let context = AgentRunContext(request: request)
        context.continuationNudgeCount = ContinuationPolicy.maxNudges

        XCTAssertNil(
            NativeAgentRuntime.continuationNudge(
                request: request,
                context: context,
                assistantContent: "I should continue."
            )
        )
    }

    func testSuccessfulToolProgressResetsContinuationBudget() {
        let request = agentRequest(prompt: "fix the website", permissionMode: .bypassPermissions)
        let context = AgentRunContext(request: request)
        context.continuationNudgeCount = ContinuationPolicy.maxNudges
        context.recoverableProtocolErrorCount = ContinuationPolicy.maxRecoverableProtocolErrors

        let call = AgentToolCall(id: "read", name: "Read", inputJSON: #"{"file_path":"index.html"}"#)
        context.recordToolResult(
            AgentToolResult(callId: "read", toolName: "Read", output: "<html></html>", isError: false),
            call: call
        )

        XCTAssertEqual(context.continuationNudgeCount, 0)
        XCTAssertEqual(context.recoverableProtocolErrorCount, 0)
        XCTAssertNotNil(
            NativeAgentRuntime.continuationNudge(
                request: request,
                context: context,
                assistantContent: "I should continue."
            )
        )
    }

    func testIncompleteTodosPreventPrematureCompletion() {
        let request = agentRequest(prompt: "帮我优化这个网页", permissionMode: .bypassPermissions)
        let context = AgentRunContext(request: request)
        context.mutatingToolCount = 1
        context.verificationAfterMutationCount = 1
        context.todosJSON = """
        [
          {"content":"Update HTML","status":"completed"},
          {"content":"Update CSS","status":"in_progress"},
          {"content":"Verify","status":"pending"}
        ]
        """

        XCTAssertTrue(context.hasIncompleteTodos)
        if case .continueWithNudge = CompletionGate.decision(
            request: request,
            context: context,
            assistantContent: "优化完成。"
        ) {
            XCTAssertTrue(true)
        } else {
            XCTFail("Expected incomplete todos to keep the workspace task running.")
        }

        context.todosJSON = """
        [
          {"content":"Update HTML","status":"completed"},
          {"content":"Update CSS","status":"done"}
        ]
        """
        XCTAssertFalse(context.hasIncompleteTodos)
        XCTAssertTrue(CompletionGate.canFinish(request: request, context: context, assistantContent: "优化完成。"))
    }

    func testDeletionVerificationErrorDoesNotBlockCompletion() {
        let request = agentRequest(prompt: "帮我删除一下这个个人网站", permissionMode: .bypassPermissions)
        let context = AgentRunContext(request: request)
        let deleteCall = AgentToolCall(id: "delete", name: "Delete", inputJSON: #"{"path":".","recursive":true}"#)
        context.recordToolResult(
            AgentToolResult(callId: "delete", toolName: "Delete", output: "Deleted .", isError: false),
            call: deleteCall
        )
        let globCall = AgentToolCall(id: "glob", name: "Glob", inputJSON: #"{"pattern":"**/*","path":"."}"#)
        context.recordToolResult(
            AgentToolResult(callId: "glob", toolName: "Glob", output: "Path does not exist: .", isError: true),
            call: globCall
        )

        XCTAssertTrue(context.hasSuccessfulDeletion)
        XCTAssertTrue(context.lastToolResultWasBenignDeletionVerification)
        XCTAssertFalse(context.lastToolResultWasError)
        XCTAssertEqual(context.verificationAfterMutationCount, 1)
        XCTAssertTrue(CompletionGate.canFinish(request: request, context: context, assistantContent: "确认删除完成，目录不存在。"))
    }

    func testDeletionVerificationRootGlobCanBeSuppressedInTranscript() {
        let deleteCall = ToolCall(id: "delete", name: "Delete", inputJSON: #"{"path":".","recursive":true}"#, status: .completed)
        let deleteResult = ToolResult(toolCallId: "delete", output: "Deleted .", isError: false)
        let globCall = ToolCall(id: "glob", name: "Glob", inputJSON: #"{"pattern":"**/*","path":"."}"#, status: .completed)
        let globResult = ToolResult(toolCallId: "glob", output: "Path does not exist: .", isError: true)

        XCTAssertTrue(DeletionVerificationClassifier.isSuccessfulDeletion(call: deleteCall, result: deleteResult))
        XCTAssertTrue(DeletionVerificationClassifier.shouldSuppressTranscriptPair(
            call: globCall,
            result: globResult,
            sawSuccessfulDeletion: true
        ))
        XCTAssertFalse(DeletionVerificationClassifier.shouldSuppressTranscriptPair(
            call: globCall,
            result: globResult,
            sawSuccessfulDeletion: false
        ))
    }

    func testPlanModeContinuationNudgesEvenForNonWorkspacePrompt() {
        let request = agentRequest(prompt: "北京天气怎么样？", runMode: .plan, permissionMode: .bypassPermissions)
        let context = AgentRunContext(request: request)

        let nudge = NativeAgentRuntime.continuationNudge(
            request: request,
            context: context,
            assistantContent: "北京今天晴。"
        )

        XCTAssertNotNil(nudge)
        XCTAssertTrue(nudge?.contains("AskQuestion") == true)
    }

    func testPlanModeProtocolRecoveryMessageIsNotWorkspaceMutationBanner() {
        XCTAssertTrue(NativeAgentRuntime.planModeProtocolRecoveryMessage.contains("AskQuestion"))
        XCTAssertTrue(NativeAgentRuntime.planModeProtocolRecoveryMessage.contains("SwitchMode"))
        XCTAssertFalse(NativeAgentRuntime.planModeProtocolRecoveryMessage.contains("workspace change"))
    }

    func testWorkspaceMutationIgnoresInjectedMemoryContext() {
        let prompt = """
        <memory-context>
        只回答一句：PilotDeck smoke test ok。

        之前用户要求优化、创建、修改网页。
        </memory-context>

        只回答一句：PilotDeck smoke test ok。
        """

        XCTAssertFalse(NativeAgentRuntime.isWorkspaceMutationRequest(prompt))
    }

    func testCompletionGateIgnoresInjectedMemoryContext() {
        let prompt = """
        <memory-context>
        之前用户要求优化、创建、修改网页。
        </memory-context>

        只回答一句：smoke ok。
        """
        let request = agentRequest(prompt: prompt, permissionMode: .default)
        let context = AgentRunContext(request: request)

        XCTAssertTrue(CompletionGate.canFinish(request: request, context: context, assistantContent: "smoke ok。"))
    }

    func testContinueAloneDoesNotMakeSimpleFollowupAWorkspaceMutation() {
        XCTAssertFalse(NativeAgentRuntime.isWorkspaceMutationRequest("继续用一句话回答：第二轮 ok。"))
        XCTAssertTrue(NativeAgentRuntime.isWorkspaceMutationRequest("继续优化这个网页"))
    }

    func testWorkspaceMutationDoesNotFinishOnInProgressTextAfterOneEdit() {
        let request = agentRequest(prompt: "继续优化这个网页", permissionMode: .bypassPermissions)
        let context = AgentRunContext(request: request)
        context.mutatingToolCount = 1
        context.planExited = true
        let content = "现在创建优化后的 HTML 文件："

        XCTAssertFalse(CompletionGate.canFinish(request: request, context: context, assistantContent: content))
        XCTAssertNotNil(NativeAgentRuntime.continuationNudge(request: request, context: context, assistantContent: content))
    }

    func testCompletionGateContinuesOrPausesInsteadOfWorkspaceBanner() {
        let request = agentRequest(prompt: "继续优化这个网页", permissionMode: .bypassPermissions)
        let context = AgentRunContext(request: request)
        context.mutatingToolCount = 1
        context.planExited = true
        let content = "Let me check the duplicate elements issue and fix it."

        if case .continueWithNudge(let nudge) = CompletionGate.decision(request: request, context: context, assistantContent: content) {
            XCTAssertTrue(nudge.contains("Continue"))
        } else {
            XCTFail("Expected continuation nudge for ongoing workspace work.")
        }

        context.continuationNudgeCount = ContinuationPolicy.maxNudges
        if case .pauseNeedsUser(let message) = CompletionGate.decision(request: request, context: context, assistantContent: content) {
            XCTAssertTrue(message.contains("continue") || message.contains("继续"))
        } else {
            XCTFail("Expected recoverable pause after nudge budget is exhausted.")
        }
    }

    func testReadOnlyShellDoesNotSatisfyWorkspaceMutation() {
        let request = agentRequest(prompt: "optimize this website", permissionMode: .bypassPermissions)
        let context = AgentRunContext(request: request)
        let call = AgentToolCall(id: "shell", name: "Shell", inputJSON: #"{"command":"find . -maxdepth 1 -type f"}"#)
        context.recordToolResult(
            AgentToolResult(callId: "shell", toolName: "Shell", output: "index.html", isError: false),
            call: call
        )

        XCTAssertNotNil(
            NativeAgentRuntime.continuationNudge(
                request: request,
                context: context,
                assistantContent: "I found index.html."
            )
        )
    }

    func testOptimizeTaskRequiresVerificationAfterMutation() {
        let request = agentRequest(prompt: "继续优化这个网页", permissionMode: .bypassPermissions)
        let context = AgentRunContext(request: request)
        let editCall = AgentToolCall(id: "edit", name: "StrReplace", inputJSON: #"{"file_path":"index.html","old_string":"a","new_string":"b"}"#)
        context.recordToolResult(
            AgentToolResult(callId: "edit", toolName: "StrReplace", output: "Updated index.html", isError: false),
            call: editCall
        )

        XCTAssertFalse(
            CompletionGate.canFinish(
                request: request,
                context: context,
                assistantContent: "优化完成。"
            )
        )
        XCTAssertNotNil(
            NativeAgentRuntime.continuationNudge(
                request: request,
                context: context,
                assistantContent: "优化完成。"
            )
        )

        let readCall = AgentToolCall(id: "read", name: "Read", inputJSON: #"{"file_path":"index.html"}"#)
        context.recordToolResult(
            AgentToolResult(callId: "read", toolName: "Read", output: "<html>...</html>", isError: false),
            call: readCall
        )

        XCTAssertTrue(
            CompletionGate.canFinish(
                request: request,
                context: context,
                assistantContent: "优化完成。"
            )
        )
    }

    func testAgentToolExecutorWritesInsideWorkspace() async throws {
        let root = repoRootURL()
            .appendingPathComponent("pilotdeck-agent-write-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = AgentRunContext(request: agentRequest(projectPath: root.path, permissionMode: .bypassPermissions))
        let call = AgentToolCall(
            id: "call-write",
            name: "Write",
            inputJSON: #"{"file_path":"site/index.html","content":"<h1>Hello</h1>"}"#
        )

        let result = await AgentToolExecutor.execute(call: call, context: context)

        XCTAssertFalse(result.isError, result.output)
        let written = try String(contentsOf: root.appendingPathComponent("site/index.html"), encoding: .utf8)
        XCTAssertEqual(written, "<h1>Hello</h1>")
    }

    func testAgentToolExecutorReadsTextImagePDFAndNotebook() async throws {
        let root = try makeAgentWorkspace("pilotdeck-agent-read")
        defer { try? FileManager.default.removeItem(at: root) }
        try "alpha\nbeta\ngamma".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try writeTinyPNG(to: root.appendingPathComponent("pixel.png"))
        try writeMinimalPDF(to: root.appendingPathComponent("empty.pdf"))
        try """
        {"cells":[{"cell_type":"code","id":"cell-a","metadata":{},"source":["print(1)\\n"],"outputs":[],"execution_count":null}],"metadata":{},"nbformat":4,"nbformat_minor":5}
        """.write(to: root.appendingPathComponent("lab.ipynb"), atomically: true, encoding: .utf8)
        let context = AgentRunContext(request: agentRequest(projectPath: root.path, permissionMode: .bypassPermissions))

        let text = await NativeToolRouter.execute(
            call: AgentToolCall(id: "read-text", name: "Read", inputJSON: #"{"file_path":"notes.txt","limit":2}"#),
            context: context
        )
        XCTAssertFalse(text.isError, text.output)
        XCTAssertTrue(text.output.contains("1: alpha"))
        XCTAssertTrue(text.output.contains("2: beta"))

        let image = await NativeToolRouter.execute(
            call: AgentToolCall(id: "read-image", name: "Read", inputJSON: #"{"file_path":"pixel.png"}"#),
            context: context
        )
        XCTAssertFalse(image.isError, image.output)
        let imageObject = try jsonObject(from: image.output)
        XCTAssertEqual(imageObject["type"] as? String, "image")
        let imageFile = try XCTUnwrap(imageObject["file"] as? [String: Any])
        XCTAssertEqual(imageFile["mediaType"] as? String, "image/png")

        let pdf = await NativeToolRouter.execute(
            call: AgentToolCall(id: "read-pdf", name: "Read", inputJSON: #"{"file_path":"empty.pdf","pages":"1"}"#),
            context: context
        )
        XCTAssertFalse(pdf.isError, pdf.output)
        XCTAssertTrue(pdf.output.contains("PDF empty.pdf"))
        XCTAssertTrue(pdf.output.contains("pages: 1"))

        let notebook = await NativeToolRouter.execute(
            call: AgentToolCall(id: "read-notebook", name: "Read", inputJSON: #"{"file_path":"lab.ipynb"}"#),
            context: context
        )
        XCTAssertFalse(notebook.isError, notebook.output)
        XCTAssertTrue(notebook.output.contains("Notebook lab.ipynb"))
        XCTAssertTrue(notebook.output.contains("print(1)"))
    }

    func testAgentToolExecutorPersistsLargeToolOutputForLaterRead() async throws {
        let root = try makeAgentWorkspace("pilotdeck-agent-large-output")
        defer { try? FileManager.default.removeItem(at: root) }
        let lines = (1...1_200).map { "line-\($0) " + String(repeating: "x", count: 40) }
        try lines.joined(separator: "\n").write(to: root.appendingPathComponent("large.txt"), atomically: true, encoding: .utf8)
        let context = AgentRunContext(request: agentRequest(projectPath: root.path, permissionMode: .bypassPermissions))

        let result = await NativeToolRouter.execute(
            call: AgentToolCall(
                id: "call:large/read?",
                name: "Read",
                inputJSON: #"{"file_path":"large.txt","limit":1200}"#
            ),
            context: context
        )

        XCTAssertFalse(result.isError, result.output)
        XCTAssertTrue(result.output.contains("<persisted-output>"))
        XCTAssertTrue(result.output.contains("Full output saved to: .pilotdeck/tool-results/test-session/Read-call-large-read.txt"))
        XCTAssertTrue(result.output.contains("Use Read with file_path"))
        let persisted = root.appendingPathComponent(".pilotdeck/tool-results/test-session/Read-call-large-read.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: persisted.path))
        let persistedText = try String(contentsOf: persisted, encoding: .utf8)
        XCTAssertTrue(persistedText.contains("1: line-1"))
        XCTAssertTrue(persistedText.contains("1200: line-1200"))

        let reread = await NativeToolRouter.execute(
            call: AgentToolCall(
                id: "read-persisted-tail",
                name: "Read",
                inputJSON: #"{"file_path":".pilotdeck/tool-results/test-session/Read-call-large-read.txt","offset":1198,"limit":3}"#
            ),
            context: context
        )

        XCTAssertFalse(reread.isError, reread.output)
        XCTAssertTrue(reread.output.contains("1200: 1200: line-1200"))
    }

    func testAgentToolExecutorEditsDeletesAndNotebookCells() async throws {
        let root = try makeAgentWorkspace("pilotdeck-agent-edit")
        defer { try? FileManager.default.removeItem(at: root) }
        let context = AgentRunContext(request: agentRequest(projectPath: root.path, permissionMode: .bypassPermissions))
        try "one fish one fish".write(to: root.appendingPathComponent("story.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("scratch"), withIntermediateDirectories: true)
        try "temp".write(to: root.appendingPathComponent("scratch/temp.txt"), atomically: true, encoding: .utf8)
        try """
        {"cells":[{"cell_type":"markdown","id":"intro","metadata":{},"source":["# Old\\n"]}],"metadata":{},"nbformat":4,"nbformat_minor":5}
        """.write(to: root.appendingPathComponent("lab.ipynb"), atomically: true, encoding: .utf8)

        let replace = await NativeToolRouter.execute(
            call: AgentToolCall(id: "replace", name: "StrReplace", inputJSON: #"{"file_path":"story.txt","old_string":"one","new_string":"two","replace_all":true}"#),
            context: context
        )
        XCTAssertFalse(replace.isError, replace.output)
        let replaced = try String(contentsOf: root.appendingPathComponent("story.txt"), encoding: .utf8)
        XCTAssertEqual(replaced, "two fish two fish")

        let batch = await NativeToolRouter.execute(
            call: AgentToolCall(id: "batch", name: "MultiEdit", inputJSON: #"{"file_path":"story.txt","edits":[{"old_string":"two","new_string":"red","replace_all":true},{"old_string":"red fish red","new_string":"red fish blue"}]}"#),
            context: context
        )
        XCTAssertFalse(batch.isError, batch.output)
        let batchReplaced = try String(contentsOf: root.appendingPathComponent("story.txt"), encoding: .utf8)
        XCTAssertEqual(batchReplaced, "red fish blue fish")

        let notebookReplace = await NativeToolRouter.execute(
            call: AgentToolCall(
                id: "nb-replace",
                name: "EditNotebook",
                inputJSON: toolJSON([
                    "notebook_path": "lab.ipynb",
                    "cell_id": "intro",
                    "new_source": "# New\n",
                    "cell_type": "markdown",
                ])
            ),
            context: context
        )
        XCTAssertFalse(notebookReplace.isError, notebookReplace.output)
        let notebookInsert = await NativeToolRouter.execute(
            call: AgentToolCall(id: "nb-insert", name: "NotebookEdit", inputJSON: #"{"notebook_path":"lab.ipynb","cell_number":1,"edit_mode":"insert","cell_type":"code","new_source":"print(2)\n"}"#),
            context: context
        )
        XCTAssertFalse(notebookInsert.isError, notebookInsert.output)
        let notebookDelete = await NativeToolRouter.execute(
            call: AgentToolCall(id: "nb-delete", name: "EditNotebook", inputJSON: #"{"notebook_path":"lab.ipynb","cell_number":0,"edit_mode":"delete"}"#),
            context: context
        )
        XCTAssertFalse(notebookDelete.isError, notebookDelete.output)
        let notebook = try jsonObject(from: String(contentsOf: root.appendingPathComponent("lab.ipynb"), encoding: .utf8))
        let cells = try XCTUnwrap(notebook["cells"] as? [[String: Any]])
        XCTAssertEqual(cells.count, 1)
        XCTAssertEqual(cells.first?["cell_type"] as? String, "code")

        let blockedDelete = await NativeToolRouter.execute(
            call: AgentToolCall(id: "delete-dir-blocked", name: "Delete", inputJSON: #"{"path":"scratch"}"#),
            context: context
        )
        XCTAssertTrue(blockedDelete.isError)
        let delete = await NativeToolRouter.execute(
            call: AgentToolCall(id: "delete-dir", name: "Delete", inputJSON: #"{"path":"scratch","recursive":true}"#),
            context: context
        )
        XCTAssertFalse(delete.isError, delete.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("scratch").path))
    }

    func testAgentToolExecutorSearchShellAwaitAndLints() async throws {
        let root = try makeAgentWorkspace("pilotdeck-agent-search")
        defer {
            AgentBackgroundTaskStore.shared.terminate()
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "func renderDashboard() {}\nlet title = \"alpha\"\n".write(
            to: root.appendingPathComponent("src/App.swift"),
            atomically: true,
            encoding: .utf8
        )
        let request = agentRequest(
            projectPath: root.path,
            permissionMode: .bypassPermissions,
            nativeConfigValues: ["lint.command": "printf 'src/App.swift:2:5: warning: lint warning\\n'"]
        )
        let context = AgentRunContext(request: request)

        let glob = await NativeToolRouter.execute(
            call: AgentToolCall(id: "glob", name: "Glob", inputJSON: #"{"pattern":"**/*.swift","path":"."}"#),
            context: context
        )
        XCTAssertFalse(glob.isError, glob.output)
        XCTAssertTrue(glob.output.contains("src/App.swift"))

        let grep = await NativeToolRouter.execute(
            call: AgentToolCall(id: "grep", name: "Grep", inputJSON: #"{"pattern":"renderDashboard","path":"src","output_mode":"content"}"#),
            context: context
        )
        XCTAssertFalse(grep.isError, grep.output)
        XCTAssertTrue(grep.output.contains("renderDashboard"))

        let semantic = await NativeToolRouter.execute(
            call: AgentToolCall(id: "semantic", name: "SemanticSearch", inputJSON: #"{"query":"renderDashboard","limit":3}"#),
            context: context
        )
        XCTAssertFalse(semantic.isError, semantic.output)
        let semanticObject = try jsonObject(from: semantic.output)
        let semanticResults = try XCTUnwrap(semanticObject["results"] as? [[String: Any]])
        XCTAssertEqual(semanticResults.first?["path"] as? String, "src/App.swift")

        let shell = await NativeToolRouter.execute(
            call: AgentToolCall(id: "shell", name: "Shell", inputJSON: #"{"command":"printf shell-ok","timeout":5000}"#),
            context: context
        )
        XCTAssertFalse(shell.isError, shell.output)
        XCTAssertTrue(shell.output.contains("shell-ok"))

        let background = await NativeToolRouter.execute(
            call: AgentToolCall(id: "shell-bg", name: "Shell", inputJSON: #"{"command":"printf bg-ok","run_in_background":true,"timeout":5000}"#),
            context: context
        )
        XCTAssertFalse(background.isError, background.output)
        let backgroundObject = try jsonObject(from: background.output)
        let taskID = try XCTUnwrap(backgroundObject["task_id"] as? String)
        let awaited = await NativeToolRouter.execute(
            call: AgentToolCall(id: "await", name: "Await", inputJSON: toolJSON(["task_id": taskID, "block": true, "timeout": 2_000])),
            context: context
        )
        XCTAssertFalse(awaited.isError, awaited.output)
        XCTAssertTrue(awaited.output.contains("bg-ok"))

        let lints = await NativeToolRouter.execute(
            call: AgentToolCall(id: "lints", name: "ReadLints", inputJSON: #"{"path":".","severity":"warning"}"#),
            context: context
        )
        XCTAssertFalse(lints.isError, lints.output)
        XCTAssertTrue(lints.output.contains("lint warning"))
    }

    func testShellAutoBackgroundsLongForegroundCommands() async throws {
        let root = try makeAgentWorkspace("pilotdeck-shell-auto-background")
        defer {
            AgentBackgroundTaskStore.shared.terminate()
            try? FileManager.default.removeItem(at: root)
        }
        let context = AgentRunContext(request: agentRequest(
            projectPath: root.path,
            permissionMode: .bypassPermissions,
            nativeConfigValues: ["runtime.shellAutoBackgroundAfterMs": "100"]
        ))

        let result = await NativeToolRouter.execute(
            call: AgentToolCall(
                id: "shell-auto-bg",
                name: "Shell",
                inputJSON: #"{"command":"sleep 1; printf auto-bg-ok","timeout":5000}"#
            ),
            context: context
        )

        XCTAssertFalse(result.isError, result.output)
        let payload = try jsonObject(from: result.output)
        XCTAssertEqual(payload["status"] as? String, "running")
        XCTAssertEqual(payload["auto_backgrounded"] as? Bool, true)
        let taskID = try XCTUnwrap(payload["task_id"] as? String)

        let awaited = await NativeToolRouter.execute(
            call: AgentToolCall(id: "await-auto-bg", name: "Await", inputJSON: toolJSON(["task_id": taskID, "block": true, "timeout": 3_000])),
            context: context
        )
        XCTAssertFalse(awaited.isError, awaited.output)
        XCTAssertTrue(awaited.output.contains("auto-bg-ok"))
    }

    func testShellDrainsLargeOutputWithoutTimeout() async throws {
        let root = try makeAgentWorkspace("pilotdeck-shell-large-output")
        defer {
            AgentBackgroundTaskStore.shared.terminate()
            try? FileManager.default.removeItem(at: root)
        }
        let context = AgentRunContext(request: agentRequest(projectPath: root.path, permissionMode: .bypassPermissions))
        let command = #"for i in {1..6000}; do printf 'line-%04d abcdefghijklmnopqrstuvwxyz\n' "$i"; done"#

        let result = await NativeToolRouter.execute(
            call: AgentToolCall(
                id: "shell-large-output",
                name: "Shell",
                inputJSON: toolJSON(["command": command, "timeout": 5_000])
            ),
            context: context
        )

        XCTAssertFalse(result.isError, result.output)
        XCTAssertTrue(result.output.contains("exit code: 0"), result.output)
        XCTAssertFalse(result.output.contains("timed out"), result.output)
    }

    func testReadTextHonorsOffsetAndLimit() async throws {
        let root = try makeAgentWorkspace("pilotdeck-read-offset-limit")
        defer { try? FileManager.default.removeItem(at: root) }
        let lines = (1...5_000).map { "line-\($0)" }.joined(separator: "\n")
        try lines.write(to: root.appendingPathComponent("large.txt"), atomically: true, encoding: .utf8)
        let context = AgentRunContext(request: agentRequest(projectPath: root.path, permissionMode: .bypassPermissions))

        let result = await NativeToolRouter.execute(
            call: AgentToolCall(
                id: "read-large-text",
                name: "Read",
                inputJSON: toolJSON(["file_path": "large.txt", "offset": 4_200, "limit": 3])
            ),
            context: context
        )

        XCTAssertFalse(result.isError, result.output)
        XCTAssertTrue(result.output.contains("4200: line-4200"), result.output)
        XCTAssertTrue(result.output.contains("4202: line-4202"), result.output)
        XCTAssertFalse(result.output.contains("4203: line-4203"), result.output)
    }

    func testBackgroundTaskTerminationIsScopedBySession() async throws {
        let root = try makeAgentWorkspace("pilotdeck-bg-scope")
        defer {
            AgentBackgroundTaskStore.shared.terminate()
            try? FileManager.default.removeItem(at: root)
        }
        let environment = ProcessInfo.processInfo.environment
        let first = try AgentBackgroundTaskStore.shared.startShell(
            sessionId: "session-a",
            command: "sleep 1; printf session-a",
            cwd: root.path,
            environment: environment,
            timeoutMs: 5_000,
            description: "session a"
        )
        let second = try AgentBackgroundTaskStore.shared.startShell(
            sessionId: "session-b",
            command: "sleep 0.2; printf session-b",
            cwd: root.path,
            environment: environment,
            timeoutMs: 5_000,
            description: "session b"
        )

        AgentBackgroundTaskStore.shared.terminate(sessionId: "session-a")

        let firstOutput = try await AgentBackgroundTaskStore.shared.output(taskId: first, block: false, timeoutMs: 0)
        let firstPayload = try jsonObject(from: firstOutput)
        XCTAssertEqual(firstPayload["status"] as? String, "cancelled")
        XCTAssertEqual(firstPayload["session_id"] as? String, "session-a")

        let secondOutput = try await AgentBackgroundTaskStore.shared.output(taskId: second, block: true, timeoutMs: 3_000)
        let secondPayload = try jsonObject(from: secondOutput)
        XCTAssertEqual(secondPayload["status"] as? String, "completed")
        XCTAssertEqual(secondPayload["session_id"] as? String, "session-b")
        XCTAssertTrue(secondOutput.contains("session-b"))
    }

    func testShellExitCodeSemanticsDriveToolErrorState() async throws {
        let root = try makeAgentWorkspace("pilotdeck-shell-exit-semantics")
        defer {
            AgentBackgroundTaskStore.shared.terminate()
            try? FileManager.default.removeItem(at: root)
        }
        try "alpha\n".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "beta\n".write(to: root.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let context = AgentRunContext(request: agentRequest(projectPath: root.path, permissionMode: .bypassPermissions))

        let failing = await NativeToolRouter.execute(
            call: AgentToolCall(id: "shell-fail", name: "Shell", inputJSON: #"{"command":"printf shell-failed >&2; exit 7","timeout":5000}"#),
            context: context
        )
        XCTAssertTrue(failing.isError, failing.output)
        XCTAssertTrue(failing.output.contains("exit code: 7"))

        let grepNoMatch = await NativeToolRouter.execute(
            call: AgentToolCall(id: "grep-no-match", name: "Shell", inputJSON: #"{"command":"grep missing a.txt","timeout":5000}"#),
            context: context
        )
        XCTAssertFalse(grepNoMatch.isError, grepNoMatch.output)
        XCTAssertTrue(grepNoMatch.output.contains("exit code: 1"))

        let pipedGrepNoMatch = await NativeToolRouter.execute(
            call: AgentToolCall(id: "grep-pipe-no-match", name: "Shell", inputJSON: #"{"command":"printf alpha | grep missing","timeout":5000}"#),
            context: context
        )
        XCTAssertFalse(pipedGrepNoMatch.isError, pipedGrepNoMatch.output)
        XCTAssertTrue(pipedGrepNoMatch.output.contains("exit code: 1"))

        let grepBad = await NativeToolRouter.execute(
            call: AgentToolCall(id: "grep-bad", name: "Shell", inputJSON: #"{"command":"grep missing no-such-file.txt","timeout":5000}"#),
            context: context
        )
        XCTAssertTrue(grepBad.isError, grepBad.output)

        let diffDifferent = await NativeToolRouter.execute(
            call: AgentToolCall(id: "diff-different", name: "Shell", inputJSON: #"{"command":"diff a.txt b.txt","timeout":5000}"#),
            context: context
        )
        XCTAssertFalse(diffDifferent.isError, diffDifferent.output)
        XCTAssertTrue(diffDifferent.output.contains("exit code: 1"))

        let background = await NativeToolRouter.execute(
            call: AgentToolCall(id: "shell-bg-fail", name: "Shell", inputJSON: #"{"command":"printf bg-failed; exit 4","run_in_background":true,"timeout":5000}"#),
            context: context
        )
        XCTAssertFalse(background.isError, background.output)
        let backgroundObject = try jsonObject(from: background.output)
        let taskID = try XCTUnwrap(backgroundObject["task_id"] as? String)
        let awaited = await NativeToolRouter.execute(
            call: AgentToolCall(id: "await-bg-fail", name: "Await", inputJSON: toolJSON(["task_id": taskID, "block": true, "timeout": 10_000])),
            context: context
        )
        XCTAssertTrue(awaited.isError, awaited.output)
        XCTAssertTrue(awaited.output.contains("bg-failed"))
        XCTAssertTrue(awaited.output.contains("\"exitCode\" : 4"))
    }

    func testLegacySearchAndWeatherExecutionsNormalizeToWebSearchWhileWebFetchIsDisabled() async throws {
        let root = try makeAgentWorkspace("pilotdeck-agent-disabled-search")
        defer { try? FileManager.default.removeItem(at: root) }
        let context = AgentRunContext(request: agentRequest(
            projectPath: root.path,
            permissionMode: .bypassPermissions,
            nativeConfigValues: [
                "tools.webSearch.provider": "custom",
                "tools.webSearch.customProvider.auth": "none",
            ]
        ))

        let search = await NativeToolRouter.execute(
            call: AgentToolCall(id: "web-search", name: "WebSearch", inputJSON: #"{"query":"Beijing weather"}"#),
            context: context
        )
        let weather = await NativeToolRouter.execute(
            call: AgentToolCall(id: "weather", name: "GetWeather", inputJSON: #"{"location":"北京"}"#),
            context: context
        )
        let fetch = await NativeToolRouter.execute(
            call: AgentToolCall(id: "web-fetch", name: "WebFetch", inputJSON: #"{"url":"https://example.com","prompt":"extract"}"#),
            context: context
        )

        XCTAssertTrue(search.isError, search.output)
        XCTAssertTrue(weather.isError, weather.output)
        XCTAssertEqual(search.toolName, "WebSearch")
        XCTAssertEqual(weather.toolName, "WebSearch")
        XCTAssertTrue(search.output.contains("tools.webSearch.endpoint"))
        XCTAssertTrue(weather.output.contains("tools.webSearch.endpoint"))
        XCTAssertFalse(fetch.isError)
        XCTAssertTrue(fetch.output.contains("WebFetch is disabled"))
    }

    func testAgentToolExecutorInteractionModeTodoAndTaskTools() async throws {
        let root = try makeAgentWorkspace("pilotdeck-agent-interaction")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("subdir"), withIntermediateDirectories: true)
        let context = AgentRunContext(request: agentRequest(projectPath: root.path, runMode: .plan, permissionMode: .bypassPermissions))

        let todos = await NativeToolRouter.execute(
            call: AgentToolCall(id: "todos", name: "TodoWrite", inputJSON: #"{"todos":[{"content":"ship parity","status":"in_progress"}]}"#),
            context: context
        )
        XCTAssertFalse(todos.isError, todos.output)
        XCTAssertTrue(context.todosJSON.contains("ship parity"))
        XCTAssertTrue(todos.output.contains("continue to use the todo list"))

        let question = AgentToolExecutor.askUserQuestionResult(
            call: AgentToolCall(id: "ask", name: "AskQuestion", inputJSON: "{}"),
            updatedInputJSON: #"{"question":"Pick","answers":{"Pick":"A"}}"#
        )
        XCTAssertFalse(question.isError)
        XCTAssertEqual(question.toolName, "AskQuestion")
        XCTAssertTrue(question.output.contains("A"))

        let switchMode = await NativeToolRouter.execute(
            call: AgentToolCall(id: "switch", name: "SwitchMode", inputJSON: #"{"mode":"agent","plan":"Run task."}"#),
            context: context
        )
        XCTAssertFalse(switchMode.isError, switchMode.output)
        XCTAssertEqual(context.runMode, .agent)
        XCTAssertTrue(context.planExited)
        XCTAssertTrue(context.planExecutionApproved)

        let task = await NativeToolRouter.execute(
            call: AgentToolCall(id: "task", name: "Task", inputJSON: #"{"type":"shell","prompt":"pwd","cwd":"subdir","timeout":5000}"#),
            context: context
        )
        XCTAssertFalse(task.isError, task.output)
        XCTAssertTrue(task.output.contains(root.appendingPathComponent("subdir").path))
    }

    func testAgentRunContextRestoresTodoStateFromPriorMessages() async throws {
        let prior = ChatMessage(
            id: UUID(),
            sessionId: "test-session",
            provider: .pilotDeck,
            role: .assistant,
            blocks: [
                .toolCall(ToolCall(
                    id: "todo-restore",
                    name: "TodoWrite",
                    inputJSON: #"{"todos":[{"content":"finish the native task bridge","status":"in_progress"},{"content":"verify build","status":"pending"}]}"#,
                    status: .completed
                )),
                .toolResult(ToolResult(
                    toolCallId: "todo-restore",
                    output: "Todos have been modified successfully.",
                    isError: false
                )),
            ],
            createdAt: Date(),
            isStreaming: false
        )
        let context = AgentRunContext(request: agentRequest(priorMessages: [prior]))

        XCTAssertTrue(context.todosJSON.contains("finish the native task bridge"))
        XCTAssertTrue(context.hasIncompleteTodos)

        let reminder = try XCTUnwrap(NativeAgentRuntime.nativeAgentTodoReminderContext(context: context))
        XCTAssertTrue(reminder.contains("<system-reminder>"))
        XCTAssertTrue(reminder.contains("<todo-list>"))
        XCTAssertTrue(reminder.contains("verify build"))

        let read = await NativeToolRouter.execute(
            call: AgentToolCall(id: "todo-read", name: "TodoRead", inputJSON: "{}"),
            context: context
        )
        XCTAssertFalse(read.isError, read.output)
        XCTAssertTrue(read.output.contains("finish the native task bridge"))
    }

    func testAgentPermissionPolicyClassifiesCanonicalTools() {
        let context = AgentRunContext(request: agentRequest(runMode: .plan, permissionMode: .bypassPermissions))
        XCTAssertEqual(
            AgentPermissionPolicy.policy(
                for: AgentToolCall(id: "read", name: "Read", inputJSON: #"{"file_path":"README.md"}"#),
                context: context
            ),
            .allow
        )
        XCTAssertEqual(
            AgentPermissionPolicy.policy(
                for: AgentToolCall(id: "shell-read", name: "Shell", inputJSON: #"{"command":"git status --short"}"#),
                context: context
            ),
            .allow
        )
        XCTAssertEqual(
            AgentPermissionPolicy.policy(
                for: AgentToolCall(id: "task-explore", name: "Task", inputJSON: #"{"type":"explore","prompt":"find usage"}"#),
                context: context
            ),
            .allow
        )

        if case .block(let reason) = AgentPermissionPolicy.policy(
            for: AgentToolCall(id: "delete", name: "Delete", inputJSON: #"{"path":"tmp.txt"}"#),
            context: context
        ) {
            XCTAssertTrue(reason.contains("Plan mode skipped"))
        } else {
            XCTFail("Delete must be soft-blocked in plan mode.")
        }

        if case .block = AgentPermissionPolicy.policy(
            for: AgentToolCall(id: "shell-write", name: "Shell", inputJSON: #"{"command":"touch tmp.txt"}"#),
            context: context
        ) {
            XCTAssertTrue(true)
        } else {
            XCTFail("Mutating Shell must be soft-blocked in plan mode.")
        }

        if case .block = AgentPermissionPolicy.policy(
            for: AgentToolCall(id: "task-full", name: "Task", inputJSON: #"{"type":"generalPurpose","prompt":"change files"}"#),
            context: context
        ) {
            XCTAssertTrue(true)
        } else {
            XCTFail("Mutating/full-agent Task must be soft-blocked in plan mode.")
        }
    }

    func testComposerPasteboardReaderParsesFinderFileAndMixedText() throws {
        let root = repoRootURL()
            .appendingPathComponent("pilotdeck-paste-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("notes.txt")
        try "hello".write(to: fileURL, atomically: true, encoding: .utf8)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("pilotdeck-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([fileURL as NSURL])
        pasteboard.setString("Please inspect the attached file.", forType: .string)

        let attachments = ComposerPasteboardReader.attachments(from: pasteboard) { _ in nil }

        XCTAssertEqual(attachments.map(\.fileName), ["notes.txt"])
        XCTAssertEqual(ComposerPasteboardReader.textPayload(from: pasteboard, attachments: attachments), "Please inspect the attached file.")
    }

    func testComposerPasteboardReaderDropsFinderFileNameTextPayload() throws {
        let root = repoRootURL()
            .appendingPathComponent("pilotdeck-filename-paste-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("github.pptx")
        try Data("pptx".utf8).write(to: fileURL)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("pilotdeck-filename-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([fileURL as NSURL])
        pasteboard.setString("github.pptx", forType: .string)

        let attachments = ComposerPasteboardReader.attachments(from: pasteboard) { _ in nil }

        XCTAssertEqual(attachments.map(\.fileName), ["github.pptx"])
        XCTAssertNil(ComposerPasteboardReader.textPayload(from: pasteboard, attachments: attachments))
    }

    func testComposerPasteboardReaderParsesPlainFilePathWithoutTextPayload() throws {
        let root = repoRootURL()
            .appendingPathComponent("pilotdeck-path-paste-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("notes with spaces.md")
        try "# Notes".write(to: fileURL, atomically: true, encoding: .utf8)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("pilotdeck-path-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString(fileURL.path, forType: .string)

        let attachments = ComposerPasteboardReader.attachments(from: pasteboard) { _ in nil }

        XCTAssertEqual(attachments.map(\.fileName), ["notes with spaces.md"])
        XCTAssertNil(ComposerPasteboardReader.textPayload(from: pasteboard, attachments: attachments))
    }

    func testComposerPasteboardReaderDetectsAttachmentPayloadForDrops() throws {
        let textPasteboard = NSPasteboard(name: NSPasteboard.Name("pilotdeck-drop-text-\(UUID().uuidString)"))
        textPasteboard.clearContents()
        textPasteboard.setString("Just drag this text into the composer.", forType: .string)
        XCTAssertFalse(ComposerPasteboardReader.hasAttachmentPayload(from: textPasteboard))

        let root = repoRootURL()
            .appendingPathComponent("pilotdeck-drop-file-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("drop-notes.md")
        try "# Drop notes".write(to: fileURL, atomically: true, encoding: .utf8)
        let filePasteboard = NSPasteboard(name: NSPasteboard.Name("pilotdeck-drop-file-\(UUID().uuidString)"))
        filePasteboard.clearContents()
        filePasteboard.writeObjects([fileURL as NSURL])

        XCTAssertTrue(ComposerPasteboardReader.hasAttachmentPayload(from: filePasteboard))

        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.green.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        let imagePasteboard = NSPasteboard(name: NSPasteboard.Name("pilotdeck-drop-image-\(UUID().uuidString)"))
        imagePasteboard.clearContents()
        imagePasteboard.writeObjects([image])

        XCTAssertTrue(ComposerPasteboardReader.hasAttachmentPayload(from: imagePasteboard))
    }

    func testComposerPasteboardReaderParsesClipboardImage() throws {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("pilotdeck-image-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        let savedURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pasted-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: savedURL) }

        let attachments = ComposerPasteboardReader.attachments(from: pasteboard) { _ in
            try? Data("png".utf8).write(to: savedURL)
            return savedURL
        }

        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments.first?.mimeType, "image/png")
        XCTAssertEqual(attachments.first?.path, savedURL.path)
    }

    func testComposerPasteboardReaderParsesRawJPEGImageData() throws {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let jpeg = bitmap.representation(using: .jpeg, properties: [:]) else {
            return XCTFail("Expected test image to produce JPEG data.")
        }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("pilotdeck-jpeg-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(jpeg, forType: NSPasteboard.PasteboardType("public.jpeg"))
        let savedURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pasted-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: savedURL) }

        let attachments = ComposerPasteboardReader.attachments(from: pasteboard) { _ in
            try? Data("png".utf8).write(to: savedURL)
            return savedURL
        }

        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments.first?.mimeType, "image/png")
        XCTAssertEqual(attachments.first?.path, savedURL.path)
    }

    func testComposerAttachmentDeduperKeepsExistingPathAndAllowsNewPastedImages() {
        let existing = FileAttachment(id: UUID(), fileName: "notes.txt", path: "/tmp/notes.txt", mimeType: "text/plain")
        let duplicate = FileAttachment(id: UUID(), fileName: "notes copy.txt", path: "/tmp/notes.txt", mimeType: "text/plain")
        let imageOne = FileAttachment(id: UUID(), fileName: "pasted-image-1.png", path: "/tmp/pasted-image-1.png", mimeType: "image/png")
        let imageTwo = FileAttachment(id: UUID(), fileName: "pasted-image-2.png", path: "/tmp/pasted-image-2.png", mimeType: "image/png")

        let merged = ComposerAttachmentDeduper.merged([existing], with: [duplicate, imageOne, imageTwo])

        XCTAssertEqual(merged.map(\.path), [existing.path, imageOne.path, imageTwo.path])
    }

    func testComposerAttachmentPreviewModelUsesImageAndFileTypeIcons() {
        let image = FileAttachment(id: UUID(), fileName: "shot.png", path: "/tmp/shot.png", mimeType: "image/png")
        let pdf = FileAttachment(id: UUID(), fileName: "brief.pdf", path: "/tmp/brief.pdf", mimeType: "application/pdf")
        let code = FileAttachment(id: UUID(), fileName: "app.swift", path: "/tmp/app.swift", mimeType: "text/x-swift")

        XCTAssertEqual(ComposerAttachmentPreviewModel.make(for: image).systemImage, "photo")
        XCTAssertEqual(ComposerAttachmentPreviewModel.make(for: pdf).systemImage, "doc.richtext")
        XCTAssertEqual(ComposerAttachmentPreviewModel.make(for: code).systemImage, "chevron.left.forwardslash.chevron.right")
        XCTAssertEqual(ComposerAttachmentPreviewModel.make(for: code).typeLabel, "SWIFT")
    }

    func testComposerPasteShortcutPolicyMatchesPlainCommandVOnly() {
        XCTAssertTrue(ComposerPasteShortcutPolicy.isPasteShortcut(
            charactersIgnoringModifiers: "v",
            modifierFlags: [.command]
        ))
        XCTAssertTrue(ComposerPasteShortcutPolicy.isPasteShortcut(
            charactersIgnoringModifiers: "V",
            modifierFlags: [.command]
        ))
        XCTAssertFalse(ComposerPasteShortcutPolicy.isPasteShortcut(
            charactersIgnoringModifiers: "v",
            modifierFlags: [.command, .shift]
        ))
        XCTAssertFalse(ComposerPasteShortcutPolicy.isPasteShortcut(
            charactersIgnoringModifiers: "c",
            modifierFlags: [.command]
        ))
    }

    func testComposerSubmitShortcutPolicyMatchesWebSendByCtrlEnter() {
        let returnKey: UInt16 = 36
        let keypadReturnKey: UInt16 = 76

        XCTAssertTrue(ComposerSubmitShortcutPolicy.shouldSubmit(
            keyCode: returnKey,
            modifierFlags: [],
            sendByCtrlEnter: false
        ))
        XCTAssertFalse(ComposerSubmitShortcutPolicy.shouldSubmit(
            keyCode: returnKey,
            modifierFlags: [],
            sendByCtrlEnter: true
        ))
        XCTAssertTrue(ComposerSubmitShortcutPolicy.shouldSubmit(
            keyCode: returnKey,
            modifierFlags: [.control],
            sendByCtrlEnter: true
        ))
        XCTAssertTrue(ComposerSubmitShortcutPolicy.shouldSubmit(
            keyCode: keypadReturnKey,
            modifierFlags: [.command],
            sendByCtrlEnter: true
        ))
        XCTAssertFalse(ComposerSubmitShortcutPolicy.shouldSubmit(
            keyCode: returnKey,
            modifierFlags: [.shift],
            sendByCtrlEnter: false
        ))
        XCTAssertFalse(ComposerSubmitShortcutPolicy.shouldSubmit(
            keyCode: 48,
            modifierFlags: [.control],
            sendByCtrlEnter: true
        ))
    }

    func testAppLanguageSystemResolvesChineseAndEnglish() {
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["zh-Hans-US"]), .chineseSimplified)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["en-US"]), .english)
        XCTAssertEqual(AppLanguage.english.resolved(preferredLanguages: ["zh-Hans-US"]), .english)
        XCTAssertEqual(AppLanguage.chineseSimplified.resolved(preferredLanguages: ["en-US"]), .chineseSimplified)
    }

    func testLocalizationTablesCoverAllKeys() {
        let allKeys = Set(L10nKey.allCases)

        XCTAssertEqual(Set(LocalizationService.english.keys), allKeys)
        XCTAssertEqual(Set(LocalizationService.chineseSimplified.keys), allKeys)
    }

    func testProjectWelcomePromptIncludesProjectName() {
        let english = LocalizationService(language: .english)
        let chinese = LocalizationService(language: .chineseSimplified)

        XCTAssertEqual(english.text(.projectWelcomePrompt, "PilotDeck"), "Where should we move PilotDeck forward today?")
        XCTAssertEqual(chinese.text(.projectWelcomePrompt, "原神"), "从「原神」开始，今天推进哪一块？")
    }

    func testAppSettingsStoreRoundTripsLanguage() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pilotdeck-settings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppSettingsStore(url: root.appendingPathComponent("settings.json"))
        var settings = AppSettings.defaults
        settings.language = .chineseSimplified
        settings.projectSortOrder = .date

        try store.save(settings)
        let loaded = try XCTUnwrap(store.load())

        XCTAssertEqual(loaded.language, .chineseSimplified)
        XCTAssertEqual(loaded.projectSortOrder, .date)
    }

    func testNativeAppearanceSettingsLayoutMatchesWebSettingsTab() {
        XCTAssertEqual(NativeAppearanceSettingsLayout.sectionOrder, [
            .colorScheme,
            .language,
            .toolDisplay,
            .viewOptions,
            .inputSettings,
            .projectSorting,
            .codeEditor,
        ])
        XCTAssertFalse(NativeAppearanceSettingsLayout.usesDarkModeToggle)
        XCTAssertTrue(NativeAppearanceSettingsLayout.usesThemePicker)
        XCTAssertEqual(NativeAppearanceSettingsLayout.colorSchemePickerWidth, 160)
        XCTAssertEqual(NativeAppearanceSettingsLayout.fontSizeOptions, [
            10,
            11,
            12,
            13,
            14,
            15,
            16,
            18,
            20,
        ])

        XCTAssertEqual(LocalizationService.english[.colorScheme], "Theme")
        XCTAssertEqual(LocalizationService.english[.colorSchemeSystem], "Follow System")
        XCTAssertEqual(LocalizationService.english[.languageSystem], "Follow System")
        XCTAssertEqual(LocalizationService.chineseSimplified[.colorSchemeSystem], "系统跟随")
        XCTAssertEqual(LocalizationService.chineseSimplified[.languageSystem], "系统跟随")
        XCTAssertEqual(LocalizationService.english[.colorSchemeDetail], "Follow the system appearance or choose a fixed theme.")
        XCTAssertEqual(LocalizationService.english[.displayLanguageDetail], "Choose your preferred language for the interface")
        XCTAssertEqual(LocalizationService.english[.toolDisplay], "Tool Display")
        XCTAssertEqual(LocalizationService.english[.viewOptions], "View Options")
        XCTAssertEqual(LocalizationService.english[.inputSettings], "Input Settings")
        XCTAssertEqual(LocalizationService.english[.autoExpandTools], "Auto-expand tools")
        XCTAssertEqual(LocalizationService.english[.showRawParameters], "Show raw parameters")
        XCTAssertEqual(LocalizationService.english[.showThinking], "Show thinking")
        XCTAssertEqual(LocalizationService.english[.autoScrollToBottom], "Auto-scroll to bottom")
        XCTAssertEqual(LocalizationService.english[.sendByCtrlEnter], "Send by Ctrl+Enter")
        XCTAssertEqual(LocalizationService.chineseSimplified[.sendByCtrlEnter], "使用 Ctrl+Enter 发送")
        XCTAssertEqual(LocalizationService.english[.projectSortingDetail], "How projects are ordered in the sidebar")
        XCTAssertEqual(LocalizationService.english[.lineNumbers], "Show Line Numbers")
    }

    func testCodeEditorDefaultsMatchWebSettingsController() {
        let defaults = CodeEditorPreferences.defaults

        XCTAssertEqual(defaults.wordWrap, false)
        XCTAssertEqual(defaults.showMinimap, true)
        XCTAssertEqual(defaults.lineNumbers, true)
        XCTAssertEqual(defaults.fontSize, 14)
    }

    func testNativeMemoryViewPrimaryTabsLocalizeLikeWebMemoryPanel() {
        XCTAssertEqual(NativeMemoryViewLayout.subtabOrder, [
            .projectMemory,
            .profile,
            .trace,
        ])
        XCTAssertEqual(
            NativeMemoryViewLayout.subtabOrder.map { NativeMemoryViewLayout.subtabLabel($0, language: .english) },
            [
                "Project Memory",
                "User Profile",
                "Memory Trace",
            ]
        )
        XCTAssertEqual(
            NativeMemoryViewLayout.subtabOrder.map { NativeMemoryViewLayout.subtabLabel($0, language: .chineseSimplified) },
            [
                "项目记忆",
                "用户画像",
                "记忆追踪",
            ]
        )
    }

    func testMemorySettingsSnapshotFollowsWebConfigShapeAndDefaults() {
        let yaml = """
        memory:
          enabled: false
          model: memory
          reasoningMode: accuracy_first
          autoIndexIntervalMinutes: 45
          autoDreamIntervalMinutes: 90
          captureStrategy: full_session
          includeAssistant: false
          maxMessageChars: 12000
          heartbeatBatchSize: 7
        """
        let settings = MemorySettingsSnapshot.fromConfigValues(NativeConfigService.scalarMap(from: yaml))

        XCTAssertEqual(settings.enabled, false)
        XCTAssertEqual(settings.model, "memory")
        XCTAssertEqual(settings.reasoningMode, "accuracy_first")
        XCTAssertEqual(settings.autoIndexIntervalMinutes, 45)
        XCTAssertEqual(settings.autoDreamIntervalMinutes, 90)
        XCTAssertEqual(settings.captureStrategy, "full_session")
        XCTAssertEqual(settings.includeAssistant, false)
        XCTAssertEqual(settings.maxMessageChars, 12_000)
        XCTAssertEqual(settings.heartbeatBatchSize, 7)

        let defaults = MemorySettingsSnapshot.fromConfigValues([:])
        XCTAssertEqual(defaults.enabled, true)
        XCTAssertEqual(defaults.model, "inherit")
        XCTAssertEqual(defaults.reasoningMode, "answer_first")
        XCTAssertEqual(defaults.captureStrategy, "last_turn")
        XCTAssertEqual(defaults.includeAssistant, true)
        XCTAssertEqual(defaults.maxMessageChars, 6_000)
        XCTAssertEqual(defaults.heartbeatBatchSize, 30)
    }

    func testMemoryDashboardSchedulerReflectsMemoryEnabledConfig() {
        let service = MemoryService()
        service.updateSettings(MemorySettingsSnapshot(enabled: false))

        let snapshot = service.dashboard(projectName: "Native")

        XCTAssertFalse(snapshot.settings.enabled)
        XCTAssertFalse(snapshot.scheduler.enabled)
        XCTAssertEqual(snapshot.scheduler.status, "disabled")
        XCTAssertFalse(snapshot.overview.schedulerEnabled)

        service.updateSettings(MemorySettingsSnapshot(autoIndexIntervalMinutes: 0, autoDreamIntervalMinutes: 0))
        let noAutomation = service.dashboard(projectName: "Native")
        XCTAssertTrue(noAutomation.settings.enabled)
        XCTAssertFalse(noAutomation.scheduler.enabled)
    }

    func testProcessTraceHidesCompletedStatusOnlyActivity() {
        let completedStatus = AgentActivity(
            id: "status",
            sessionId: "session",
            title: "Connecting",
            detail: "Opening model stream",
            phase: .status,
            state: .completed,
            createdAt: Date(),
            updatedAt: Date()
        )
        let runningStatus = AgentActivity(
            id: "status",
            sessionId: "session",
            title: "Connecting",
            detail: "Opening model stream",
            phase: .status,
            state: .running,
            createdAt: Date(),
            updatedAt: Date()
        )
        let completedTool = AgentActivity(
            id: "tool",
            sessionId: "session",
            title: "Read README.md",
            detail: #"{"file_path":"README.md"}"#,
            phase: .tool,
            state: .completed,
            createdAt: Date(),
            updatedAt: Date(),
            toolName: "Read"
        )

        XCTAssertFalse(AgentActivity.hasRenderableProcessTrace([completedStatus]))
        XCTAssertTrue(AgentActivity.hasRenderableProcessTrace([runningStatus]))
        XCTAssertTrue(AgentActivity.hasRenderableProcessTrace([completedStatus, completedTool]))
        XCTAssertEqual(AgentActivity.processTraceActivities([completedStatus, completedTool]).map(\.id), ["tool"])
    }

    func testProcessTraceRunningToolIconIsNotPollutedByOlderFailure() {
        let assistantID = "assistant-run"
        let failedPermission = AgentActivity(
            id: "permission-old",
            sessionId: "session",
            title: "Permission denied",
            detail: "",
            phase: .edit,
            state: .failed,
            createdAt: Date().addingTimeInterval(-2),
            updatedAt: Date().addingTimeInterval(-2),
            toolName: "Write",
            anchorBlockID: assistantID
        )
        let runningWrite = AgentActivity(
            id: "write-running",
            sessionId: "session",
            title: "Running Write",
            detail: #"{"file_path":"index.html"}"#,
            phase: .edit,
            state: .running,
            createdAt: Date(),
            updatedAt: Date(),
            toolName: "Write",
            anchorBlockID: assistantID
        )

        let presentation = ProcessTracePresentation.make(
            activities: [failedPermission, runningWrite],
            isChinese: false
        )

        XCTAssertEqual(presentation.iconName, "pencil")
    }

    func testProcessTraceCompactionCompletionDoesNotStayRunning() {
        let date = Date()
        let completedCompaction = AgentActivity(
            id: "compact-assistant",
            sessionId: "session",
            title: "上下文压缩已完成",
            detail: "",
            phase: .status,
            state: .completed,
            createdAt: date,
            updatedAt: date
        )

        let completedPresentation = ProcessTracePresentation.make(
            activities: [completedCompaction],
            isChinese: true
        )

        XCTAssertTrue(completedPresentation.shouldRender)
        XCTAssertEqual(completedPresentation.summaryText, "上下文压缩已完成")
        XCTAssertFalse(completedPresentation.shouldShimmer)
        XCTAssertNil(completedPresentation.compactionBannerText)

        let runningRead = AgentActivity(
            id: "read",
            sessionId: "session",
            title: "Running Read",
            detail: #"{"file_path":"config/config.yaml"}"#,
            phase: .tool,
            state: .running,
            createdAt: date.addingTimeInterval(1),
            updatedAt: date.addingTimeInterval(1),
            toolName: "Read"
        )

        let continuedPresentation = ProcessTracePresentation.make(
            activities: [completedCompaction, runningRead],
            isChinese: true
        )

        XCTAssertTrue(continuedPresentation.shouldRender)
        XCTAssertTrue(continuedPresentation.summaryText.contains("正在读取"))
        XCTAssertTrue(continuedPresentation.summaryText.contains("config.yaml"))
        XCTAssertTrue(continuedPresentation.shouldShimmer)
        XCTAssertNil(continuedPresentation.compactionBannerText)
    }

    func testWriteToolInputPreviewDoesNotCarryFullContentIntoActivityTrace() throws {
        let content = Array(repeating: "0123456789", count: 120).joined(separator: "\n")
        let inputJSON = toolJSON(["file_path": "src/App.swift", "content": content])

        let preview = AgentToolInputPreview.activityDetail(toolName: "Write", inputJSON: inputJSON)
        let object = try jsonObject(from: preview)
        let summary = try XCTUnwrap(object["content_summary"] as? String)

        XCTAssertEqual(object["file_path"] as? String, "src/App.swift")
        XCTAssertTrue(summary.contains("bytes"))
        XCTAssertLessThan(preview.count, 900)
        XCTAssertFalse(preview.contains(content))
    }

    func testRunHeaderActivitiesKeepCompletedStatusForTiming() {
        let assistantID = "assistant-run"
        let completedStatus = AgentActivity(
            id: "run",
            sessionId: "session",
            title: "正在接收响应",
            detail: "正在流式输出助手回复",
            phase: .status,
            state: .completed,
            createdAt: Date().addingTimeInterval(-3),
            updatedAt: Date(),
            anchorBlockID: assistantID
        )
        let unrelated = AgentActivity(
            id: "other",
            sessionId: "session",
            title: "Other",
            detail: "",
            phase: .status,
            state: .completed,
            createdAt: Date(),
            updatedAt: Date(),
            anchorBlockID: "other-assistant"
        )

        XCTAssertEqual(AgentActivity.processTraceActivities([completedStatus], anchoredTo: assistantID).map(\.id), [])
        XCTAssertEqual(AgentActivity.runHeaderActivities([completedStatus, unrelated], anchoredTo: assistantID).map(\.id), ["run"])
    }

    func testAssistantProcessHeaderCanFallbackToPersistedToolBlocks() {
        let message = ChatMessage(
            id: UUID(),
            sessionId: "session",
            provider: .pilotDeck,
            role: .assistant,
            blocks: [
                .toolCall(ToolCall(id: "call-read", name: "Read", inputJSON: "{}", status: .completed)),
                .toolResult(ToolResult(toolCallId: "call-read", output: "ok", isError: false)),
                .text("Done")
            ],
            createdAt: Date(),
            isStreaming: false,
            tokenBudget: nil
        )
        let askQuestion = ChatMessage(
            id: UUID(),
            sessionId: "session",
            provider: .pilotDeck,
            role: .assistant,
            blocks: [.toolCall(ToolCall(id: "ask", name: "AskQuestion", inputJSON: "{}", status: .completed))],
            createdAt: Date(),
            isStreaming: false,
            tokenBudget: nil
        )

        XCTAssertTrue(message.hasPersistedProcessBlocks)
        XCTAssertTrue(message.hasAssistantTranscriptContent)
        XCTAssertFalse(askQuestion.hasPersistedProcessBlocks)
        XCTAssertFalse(askQuestion.hasAssistantTranscriptContent)
    }

    func testChatMessagePersistsRunTimingForCompletedHeaders() throws {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let ended = started.addingTimeInterval(12)
        let legacyMessage = ChatMessage(
            id: UUID(),
            sessionId: "session",
            provider: .pilotDeck,
            role: .assistant,
            blocks: [.text("Legacy")],
            createdAt: started,
            isStreaming: false,
            tokenBudget: nil
        )
        let message = ChatMessage(
            id: UUID(),
            sessionId: "session",
            provider: .pilotDeck,
            role: .assistant,
            blocks: [.text("Done")],
            createdAt: started,
            isStreaming: false,
            tokenBudget: nil,
            runStartedAt: started,
            runEndedAt: ended
        )

        let legacyData = try JSONEncoder().encode(legacyMessage)
        let decodedLegacy = try JSONDecoder().decode(ChatMessage.self, from: legacyData)
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)

        XCTAssertTrue(decodedLegacy.hasAssistantTranscriptContent)
        XCTAssertNil(decodedLegacy.runStartedAt)
        XCTAssertNil(decodedLegacy.runEndedAt)
        XCTAssertEqual(decoded.runStartedAt?.timeIntervalSince1970 ?? 0, started.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(decoded.runEndedAt?.timeIntervalSince1970 ?? 0, ended.timeIntervalSince1970, accuracy: 0.001)
    }

    func testMemoryDashboardBuildsWorkspaceSnapshot() throws {
        let root = repoRootURL()
            .appendingPathComponent("pilotdeck-memory-\(UUID().uuidString)", isDirectory: true)
        let memoryRoot = root.appendingPathComponent(".pilotdeck/memory", isDirectory: true)
        try FileManager.default.createDirectory(at: memoryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        ---
        name: Launch Plan
        description: Build the first native dashboard.
        type: project
        scope: project
        project_id: current_project
        updated_at: 2026-05-23T10:00:00Z
        source_session_key: session-launch
        ---

        Ship the native Memory dashboard.
        """.write(to: memoryRoot.appendingPathComponent("launch-plan.md"), atomically: true, encoding: .utf8)

        let service = MemoryService(memoryRoot: root.appendingPathComponent("isolated-pilotdeck-memory", isDirectory: true))
        service.loadWorkspaceRecords(projectRoot: root.path, projectName: "Native")
        let snapshot = service.dashboard(projectName: "Native", projectRoot: root.path)

        XCTAssertEqual(snapshot.workspace.workspaceMode, "project")
        XCTAssertEqual(snapshot.workspace.totalProjects, 1)
        XCTAssertEqual(snapshot.workspace.projectEntries.first?.name, "Launch Plan")
        XCTAssertEqual(snapshot.workspace.projectEntries.first?.summary, "Build the first native dashboard.")
        XCTAssertEqual(snapshot.workspace.projectEntries.first?.sourceSessionKey, "session-launch")
        XCTAssertEqual(snapshot.overview.totalEntries, 1)
    }

    func testMemoryServiceLoadsPilotDeckWorkspaceAndGlobalMemoryShape() throws {
        let root = repoRootURL()
            .appendingPathComponent("pilotdeck-memory-load-\(UUID().uuidString)", isDirectory: true)
        let memoryRoot = root.appendingPathComponent("pilotdeck-memory", isDirectory: true)
        let workspaceHash = MemoryService.pilotDeckWorkspaceHash(for: root.standardizedFileURL.path)
        let workspaceMemoryRoot = memoryRoot
            .appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent(workspaceHash, isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
        let projectMemoryRoot = workspaceMemoryRoot.appendingPathComponent("Project", isDirectory: true)
        let feedbackMemoryRoot = workspaceMemoryRoot.appendingPathComponent("Feedback", isDirectory: true)
        let globalMemoryRoot = memoryRoot
            .appendingPathComponent("global", isDirectory: true)
            .appendingPathComponent("UserIdentity", isDirectory: true)
        try FileManager.default.createDirectory(at: projectMemoryRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: feedbackMemoryRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: globalMemoryRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        ---
        name: Router Cost
        description: Saved price baseline is shown in route details.
        type: project
        scope: project
        project_id: current_project
        updated_at: 2026-05-23T10:00:00Z
        source_session_key: session-router
        ---

        ## Fact
        Router pricing should display baseline and saved cost.
        """.write(to: projectMemoryRoot.appendingPathComponent("router-cost.md"), atomically: true, encoding: .utf8)
        try """
        ---
        name: Old Feedback
        description: This feedback was superseded.
        type: feedback
        scope: project
        updated_at: 2026-05-23T09:00:00Z
        deprecated: true
        ---

        Do not show this in the active list.
        """.write(to: feedbackMemoryRoot.appendingPathComponent("old-feedback.md"), atomically: true, encoding: .utf8)
        try """
        ---
        name: Legacy Turn
        description: Old raw captured turn.
        type: project
        scope: project
        updated_at: 2026-05-23T07:00:00Z
        ---

        Raw turn artifacts should be ignored by the native loader.
        """.write(to: projectMemoryRoot.appendingPathComponent("turn-20260529-120000-legacy.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: projectMemoryRoot.appendingPathComponent("Dream", isDirectory: true), withIntermediateDirectories: true)
        try """
        ---
        name: Memory Dream Legacy
        description: Old synthetic dream artifact.
        type: project
        scope: project
        updated_at: 2026-05-23T07:30:00Z
        ---

        Legacy memory-dream artifacts should be ignored by the native loader.
        """.write(to: projectMemoryRoot.appendingPathComponent("Dream/memory-dream-20260529-120000.md"), atomically: true, encoding: .utf8)
        try """
        ---
        name: Project Dream 20260529-120001
        description: Old native synthetic dream artifact.
        type: project
        scope: project
        updated_at: 2026-05-23T07:31:00Z
        ---

        Legacy project-dream artifacts should be ignored by the native loader.
        """.write(to: projectMemoryRoot.appendingPathComponent("Dream/project-dream-20260529-120001.md"), atomically: true, encoding: .utf8)
        try """
        ---
        name: User Profile
        description: User prefers concise engineering updates.
        type: user
        scope: global
        updated_at: 2026-05-23T08:00:00Z
        ---

        Keep progress reports concise and factual.
        """.write(to: globalMemoryRoot.appendingPathComponent("user-profile.md"), atomically: true, encoding: .utf8)
        try """
        # Memory

        ## Project Memory
        - [Router Cost](Project/router-cost.md)
        """.write(to: workspaceMemoryRoot.appendingPathComponent("MEMORY.md"), atomically: true, encoding: .utf8)
        try """
        ---
        project_name: Web Memory Project
        description: Project metadata from pilotdeck memory.
        status: active
        updated_at: 2026-05-23T11:00:00Z
        ---

        ## Status
        active
        """.write(to: workspaceMemoryRoot.appendingPathComponent("project.meta.md"), atomically: true, encoding: .utf8)

        let service = MemoryService(memoryRoot: memoryRoot)
        service.loadWorkspaceRecords(projectRoot: root.path, projectName: "Native")
        let snapshot = service.dashboard(projectName: "Native", projectRoot: root.path)

        XCTAssertEqual(snapshot.records.map(\.name).sorted(), ["Old Feedback", "Router Cost", "User Profile"])
        XCTAssertEqual(snapshot.overview.userEntries, 1)
        XCTAssertEqual(snapshot.workspace.totalFiles, 1)
        XCTAssertEqual(snapshot.workspace.projectEntries.first?.relativePath, "Project/router-cost.md")
        XCTAssertEqual(snapshot.workspace.deprecatedFeedbackEntries.first?.name, "Old Feedback")
        XCTAssertEqual(service.search("session-router").first?.name, "Router Cost")
        XCTAssertEqual(service.list(kind: .feedback, projectName: "Native").count, 0)
        XCTAssertEqual(service.list(kind: .feedback, projectName: "Native", includeDeprecated: true).first?.name, "Old Feedback")
        XCTAssertEqual(service.get(ids: ["global/UserIdentity/user-profile.md"], projectName: "Native").first?.summary, "User prefers concise engineering updates.")
        XCTAssertTrue(snapshot.workspace.manifestContent.contains("[Router Cost](Project/router-cost.md)"))
        XCTAssertEqual(snapshot.workspace.projectMeta?.projectName, "Web Memory Project")
        XCTAssertEqual(snapshot.workspace.projectMeta?.status, "active")
    }

    func testMemoryCurrentProjectExportUsesWebSnapshotBundleShape() throws {
        let root = repoRootURL()
            .appendingPathComponent("pilotdeck-memory-export-\(UUID().uuidString)", isDirectory: true)
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        let memoryRoot = root.appendingPathComponent("pilotdeck-memory", isDirectory: true)
        let workspaceHash = MemoryService.pilotDeckWorkspaceHash(for: projectRoot.standardizedFileURL.path)
        let workspaceMemoryRoot = memoryRoot
            .appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent(workspaceHash, isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
        let projectMemoryRoot = workspaceMemoryRoot.appendingPathComponent("Project", isDirectory: true)
        let globalMemoryRoot = memoryRoot
            .appendingPathComponent("global", isDirectory: true)
            .appendingPathComponent("UserIdentity", isDirectory: true)
        try FileManager.default.createDirectory(at: projectMemoryRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: globalMemoryRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        ---
        name: Router Cost
        description: Saved price baseline is shown in route details.
        type: project
        scope: project
        project_id: current_project
        updated_at: 2026-05-23T10:00:00Z
        ---

        Router pricing should display baseline and saved cost.
        """.write(to: projectMemoryRoot.appendingPathComponent("router-cost.md"), atomically: true, encoding: .utf8)
        try "# Memory\n\nThis derived manifest is regenerated on import.\n".write(
            to: workspaceMemoryRoot.appendingPathComponent("MEMORY.md"),
            atomically: true,
            encoding: .utf8
        )
        try """
        ---
        name: User Profile
        description: Keep updates concise.
        type: user
        scope: global
        updated_at: 2026-05-23T08:00:00Z
        ---

        Global memory should not be included in current-project exports.
        """.write(to: globalMemoryRoot.appendingPathComponent("user-profile.md"), atomically: true, encoding: .utf8)

        let service = MemoryService(memoryRoot: memoryRoot)
        service.loadWorkspaceRecords(projectRoot: projectRoot.path, projectName: "Native")
        let data = try service.exportBundle(projectName: "Native", projectRoot: projectRoot.path)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let files = try XCTUnwrap(object["files"] as? [[String: Any]])
        let paths = files.compactMap { $0["relativePath"] as? String }

        XCTAssertEqual(object["formatVersion"] as? String, "pilotdeck-memory-snapshot.v1")
        XCTAssertEqual(object["scope"] as? String, "current_project")
        XCTAssertEqual(paths, ["Project/router-cost.md"])
        XCTAssertFalse(paths.contains("MEMORY.md"))
        XCTAssertFalse(paths.contains { $0.hasPrefix("global/") })
        XCTAssertTrue((files.first?["content"] as? String)?.contains("Saved price baseline") == true)
    }

    func testMemoryImportCurrentProjectWritesPilotDeckWorkspaceFiles() throws {
        let root = repoRootURL()
            .appendingPathComponent("pilotdeck-memory-import-\(UUID().uuidString)", isDirectory: true)
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        let memoryRoot = root.appendingPathComponent("pilotdeck-memory", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaceHash = MemoryService.pilotDeckWorkspaceHash(for: projectRoot.standardizedFileURL.path)
        let workspaceMemoryRoot = memoryRoot
            .appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent(workspaceHash, isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
        let content = """
        ---
        name: Imported Memory
        description: Imported from a web snapshot bundle.
        type: project
        scope: project
        project_id: current_project
        updated_at: 2026-05-23T10:00:00Z
        ---

        The native app should materialize this file under the PilotDeck workspace memory root.
        """
        let bundle: [String: Any] = [
            "formatVersion": "pilotdeck-memory-snapshot.v1",
            "scope": "current_project",
            "exportedAt": "2026-05-23T10:00:00Z",
            "files": [
                [
                    "relativePath": "Project/imported-memory.md",
                    "content": content
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: bundle, options: [.sortedKeys])
        let service = MemoryService(memoryRoot: memoryRoot)

        try service.importBundle(data, projectName: "Native", projectRoot: projectRoot.path)
        let written = workspaceMemoryRoot.appendingPathComponent("Project/imported-memory.md")
        let snapshot = service.dashboard(projectName: "Native", projectRoot: projectRoot.path)

        XCTAssertTrue(FileManager.default.fileExists(atPath: written.path))
        XCTAssertEqual(snapshot.workspace.projectEntries.first?.name, "Imported Memory")
        XCTAssertTrue(snapshot.workspace.manifestContent.contains("Project/imported-memory.md"))
    }

    func testMemoryClearCurrentProjectRemovesNativeAndProjectLocalFiles() throws {
        let root = repoRootURL()
            .appendingPathComponent("pilotdeck-memory-clear-current-\(UUID().uuidString)", isDirectory: true)
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        let memoryRoot = root.appendingPathComponent("pilotdeck-memory", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspaceHash = MemoryService.pilotDeckWorkspaceHash(for: projectRoot.standardizedFileURL.path)
        let nativeFile = memoryRoot
            .appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent(workspaceHash, isDirectory: true)
            .appendingPathComponent("memory/Project/native.md")
        let localFile = projectRoot
            .appendingPathComponent(".pilotdeck/memory/Project/local.md")
        let globalFile = memoryRoot
            .appendingPathComponent("global/UserIdentity/profile.md")
        for file in [nativeFile, localFile, globalFile] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "memory".write(to: file, atomically: true, encoding: .utf8)
        }

        let service = MemoryService(memoryRoot: memoryRoot)
        service.loadWorkspaceRecords(projectRoot: projectRoot.path, projectName: "Native")
        service.clear(projectName: "Native", projectRoot: projectRoot.path)

        XCTAssertFalse(FileManager.default.fileExists(atPath: nativeFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: localFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: globalFile.path))
    }

    func testMemoryClearAllRemovesGlobalNativeAndKnownProjectLocalFiles() throws {
        let root = repoRootURL()
            .appendingPathComponent("pilotdeck-memory-clear-all-\(UUID().uuidString)", isDirectory: true)
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        let memoryRoot = root.appendingPathComponent("pilotdeck-memory", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let workspaceHash = MemoryService.pilotDeckWorkspaceHash(for: projectRoot.standardizedFileURL.path)
        let nativeFile = memoryRoot
            .appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent(workspaceHash, isDirectory: true)
            .appendingPathComponent("memory/Project/native.md")
        let localFile = projectRoot
            .appendingPathComponent(".pilotdeck/memory/Project/local.md")
        let globalFile = memoryRoot
            .appendingPathComponent("global/UserIdentity/profile.md")
        for file in [nativeFile, localFile, globalFile] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "memory".write(to: file, atomically: true, encoding: .utf8)
        }

        let service = MemoryService(memoryRoot: memoryRoot)
        service.updateWorkspaceCatalog([
            MemoryWorkspaceCatalogEntry(
                projectName: "Native",
                displayName: "Native",
                rootPath: projectRoot.path,
                isGeneral: false
            )
        ])
        service.loadWorkspaceRecords(projectRoot: projectRoot.path, projectName: "Native")
        service.clear(projectName: nil, projectRoot: nil)

        XCTAssertFalse(FileManager.default.fileExists(atPath: nativeFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: localFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: globalFile.path))
    }

    func testMemoryImportRejectsUnsafeSnapshotPaths() throws {
        let root = repoRootURL()
            .appendingPathComponent("pilotdeck-memory-unsafe-\(UUID().uuidString)", isDirectory: true)
        let projectRoot = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle: [String: Any] = [
            "formatVersion": "clawxmemory-memory-snapshot.v4",
            "scope": "current_project",
            "exportedAt": "2026-05-23T10:00:00Z",
            "files": [
                [
                    "relativePath": "../escape.md",
                    "content": "unsafe"
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: bundle, options: [.sortedKeys])
        let service = MemoryService(memoryRoot: root.appendingPathComponent("pilotdeck-memory", isDirectory: true))

        XCTAssertThrowsError(try service.importBundle(data, projectName: "Native", projectRoot: projectRoot.path)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Invalid files[0].relativePath"))
        }
    }

    func testMemoryDreamRollbackAndBundleRoundTrip() throws {
        let root = repoRootURL()
            .appendingPathComponent("pilotdeck-memory-dream-\(UUID().uuidString)", isDirectory: true)
        let memoryRoot = root.appendingPathComponent("memory-root", isDirectory: true)
        let projectRoot = root.appendingPathComponent("Native", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = MemoryService(memoryRoot: memoryRoot)
        _ = service.upsert(name: "session-summary", summary: "Created the Swift agent shell.", projectName: "Native")
        _ = service.upsert(name: "launch-summary", summary: "Prepared the native memory dashboard.", projectName: "Native")

        var snapshot = service.runDream(projectName: "Native", projectRoot: projectRoot.path)

        XCTAssertEqual(snapshot.dreamTraceRecords.count, 1)
        XCTAssertEqual(snapshot.lastDreamSnapshot?.rollbackReady, true)
        let files = FileManager.default.fileExists(atPath: memoryRoot.path)
            ? (try FileManager.default.subpathsOfDirectory(atPath: memoryRoot.path))
            : []
        XCTAssertFalse(snapshot.records.contains { $0.name.hasPrefix("Project Dream") })
        XCTAssertFalse(snapshot.records.contains { $0.relativePath.hasPrefix("Project/Dream/") })
        XCTAssertFalse(files.contains { $0.contains("project-dream-") })

        snapshot = try service.rollbackLastDream(projectName: "Native", projectRoot: projectRoot.path)

        XCTAssertEqual(snapshot.dreamTraceRecords.count, 2)
        XCTAssertEqual(snapshot.lastDreamSnapshot?.rollbackReady, false)
        XCTAssertFalse(snapshot.records.contains { $0.name.hasPrefix("Project Dream") })

        let exported = try service.exportBundle(projectName: "Native")
        let imported = MemoryService()
        try imported.importBundle(exported, projectName: "Native")
        let importedSnapshot = imported.dashboard(projectName: "Native")

        XCTAssertTrue(importedSnapshot.records.map(\.name).contains("session-summary"))
        XCTAssertGreaterThanOrEqual(importedSnapshot.overview.totalEntries, 1)
    }

    func testMemoryRecallRanksRelevantRecordsAndKeepsEmptyDiagnostics() {
        let service = MemoryService()
        _ = service.upsert(name: "router-cost", summary: "Router cost baseline and saved price are shown in route details.", projectName: "Native")
        _ = service.upsert(name: "theme-note", summary: "Use compact spacing in the memory page.", projectName: "Native")

        let result = service.retrieveContext(
            query: "How should router saved price display?",
            recentMessages: [],
            sessionID: "recall-router",
            projectName: "Native",
            projectRoot: nil
        )
        XCTAssertTrue(result.systemContext.contains("router-cost"))
        XCTAssertFalse(result.systemContext.contains("theme-note"))
        let recallTrace = service.caseTraces(limit: 1).first
        XCTAssertEqual(
            recallTrace?.steps.map(\.id),
            ["recall_start", "memory_gate", "user_base_loaded", "manifest_scanned", "manifest_selected", "files_loaded", "context_rendered"]
        )
        XCTAssertTrue(recallTrace?.steps.first(where: { $0.id == "memory_gate" })?.detail.contains("route=project") == true)
        XCTAssertTrue(recallTrace?.steps.first(where: { $0.id == "user_base_loaded" })?.detail.contains("required=no") == true)

        let empty = service.retrieveContext(
            query: "completely-unmatched-term",
            recentMessages: [],
            sessionID: "recall-empty",
            projectName: "Native",
            projectRoot: nil
        )
        XCTAssertFalse(empty.injected)
        XCTAssertEqual(service.caseTraces(limit: 1).first?.reply, "PilotDeck memory returned no relevant context.")
    }

    @MainActor
    func testMemoryCaptureTurnIndexesProjectMemoryAndCompletesTrace() async throws {
        let root = repoRootURL()
            .appendingPathComponent("pilotdeck-memory-capture-\(UUID().uuidString)", isDirectory: true)
        let memoryRoot = root.appendingPathComponent("memory-root", isDirectory: true)
        let projectRoot = root.appendingPathComponent("Native", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = MemoryService(memoryRoot: memoryRoot)
        let sessionID = "session-capture"
        let user = ChatMessage(
            id: UUID(),
            sessionId: sessionID,
            provider: .pilotDeck,
            role: .user,
            blocks: [.text("Remember that router pricing should show saved price first.")],
            createdAt: Date(),
            isStreaming: false,
            tokenBudget: nil
        )
        let assistant = ChatMessage(
            id: UUID(),
            sessionId: sessionID,
            provider: .pilotDeck,
            role: .assistant,
            blocks: [.text("Captured the router pricing display preference.")],
            createdAt: Date(),
            isStreaming: false,
            tokenBudget: nil
        )

        _ = service.retrieveContext(
            query: "router pricing",
            recentMessages: [user],
            sessionID: sessionID,
            projectName: "Native",
            projectRoot: projectRoot.path
        )
        let captured = service.captureTurn(
            messages: [user, assistant],
            sessionID: sessionID,
            projectName: "Native",
            projectRoot: projectRoot.path
        )

        XCTAssertNil(captured)
        var files = try FileManager.default.subpathsOfDirectory(atPath: memoryRoot.path)
        XCTAssertTrue(files.contains { $0.contains("l0_sessions") && $0.hasSuffix(".json") })
        XCTAssertFalse(files.contains { $0.contains("Project/turn-") })
        let trace = try XCTUnwrap(service.caseTraces(limit: 1).first)
        XCTAssertEqual(trace.status, "completed")
        XCTAssertTrue(trace.meta["capturedRecord"]?.hasPrefix("l0-") == true)
        XCTAssertTrue(trace.steps.map(\.id).contains("capture_turn"))

        let indexed = try await service.runIndexJob(projectRoot: projectRoot.path, projectName: "Native")
        let record = try XCTUnwrap(indexed.records.first { $0.sourceSessionKey == sessionID && $0.type == .project })
        XCTAssertTrue(record.relativePath.hasPrefix("Project/"))
        XCTAssertTrue(record.content.contains("source_session_key: \(sessionID)"))
        XCTAssertTrue(record.content.contains("router pricing should show saved price first"))
        files = try FileManager.default.subpathsOfDirectory(atPath: memoryRoot.path)
        XCTAssertTrue(files.contains { $0.hasSuffix(record.relativePath) })
        XCTAssertEqual(indexed.indexTraceRecords.first?.reply, "Indexed 1 memory records.")
    }

    @MainActor
    func testMemoryGeneralRecallCombinesExternalProjectAndGeneralOverlay() async throws {
        let root = repoRootURL()
            .appendingPathComponent("pilotdeck-memory-general-overlay-\(UUID().uuidString)", isDirectory: true)
        let memoryRoot = root.appendingPathComponent("memory-root", isDirectory: true)
        let generalRoot = root.appendingPathComponent("general", isDirectory: true)
        let projectRoot = root.appendingPathComponent("saas-pricing", isDirectory: true)
        try FileManager.default.createDirectory(at: generalRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = MemoryService(memoryRoot: memoryRoot)
        service.updateWorkspaceCatalog([
            MemoryWorkspaceCatalogEntry(projectName: "general", displayName: "general", rootPath: generalRoot.path, isGeneral: true),
            MemoryWorkspaceCatalogEntry(projectName: "SaaS Pricing Rewrite", displayName: "SaaS Pricing Rewrite", rootPath: projectRoot.path, isGeneral: false)
        ])

        let projectSession = "saas-project-session"
        let projectUser = ChatMessage(
            id: UUID(),
            sessionId: projectSession,
            provider: .pilotDeck,
            role: .user,
            blocks: [.text("记住 SaaS Pricing Rewrite 项目：CTA 不要用 立即购买，优先写 draft.md，不要编辑 .gitignore。")],
            createdAt: Date(),
            isStreaming: false,
            tokenBudget: nil
        )
        let projectAssistant = ChatMessage(
            id: UUID(),
            sessionId: projectSession,
            provider: .pilotDeck,
            role: .assistant,
            blocks: [.text("已记录 SaaS Pricing Rewrite 的项目约束。")],
            createdAt: Date(),
            isStreaming: false,
            tokenBudget: nil
        )
        _ = service.captureTurn(
            messages: [projectUser, projectAssistant],
            sessionID: projectSession,
            projectName: "SaaS Pricing Rewrite",
            projectRoot: projectRoot.path
        )
        _ = try await service.runIndexJob(projectRoot: projectRoot.path, projectName: "SaaS Pricing Rewrite")

        let overlaySession = "general-overlay-session"
        let overlayUser = ChatMessage(
            id: UUID(),
            sessionId: overlaySession,
            provider: .pilotDeck,
            role: .user,
            blocks: [.text("对于 SaaS Pricing Rewrite 这个项目，默认先强调年付节省，不要提永久免费方案。")],
            createdAt: Date(),
            isStreaming: false,
            tokenBudget: nil
        )
        let overlayAssistant = ChatMessage(
            id: UUID(),
            sessionId: overlaySession,
            provider: .pilotDeck,
            role: .assistant,
            blocks: [.text("已把这条 General 覆盖规则挂到 SaaS Pricing Rewrite。")],
            createdAt: Date(),
            isStreaming: false,
            tokenBudget: nil
        )
        _ = service.captureTurn(
            messages: [overlayUser, overlayAssistant],
            sessionID: overlaySession,
            projectName: nil,
            projectRoot: generalRoot.path
        )
        let generalIndexed = try await service.runIndexJob(projectRoot: generalRoot.path, projectName: nil)
        XCTAssertTrue(generalIndexed.workspace.generalProjects.contains { $0.projectName == "SaaS Pricing Rewrite" })

        let recalled = await service.retrieveContextForTurn(
            query: "请回忆一下 SaaS Pricing Rewrite 的要求",
            recentMessages: [],
            sessionID: "general-recall-saas",
            projectName: nil,
            projectRoot: generalRoot.path
        )

        XCTAssertTrue(recalled.injected)
        XCTAssertTrue(recalled.systemContext.contains("draft.md"))
        XCTAssertTrue(recalled.systemContext.contains("立即购买"))
        XCTAssertTrue(recalled.systemContext.contains("年付节省"))
        XCTAssertTrue(recalled.systemContext.contains("永久免费"))
        let recallTrace = try XCTUnwrap(service.caseTraces(limit: 1).first)
        XCTAssertTrue(recallTrace.steps.map(\.id).contains("project_shortlist_built"))
        XCTAssertTrue(recallTrace.steps.map(\.id).contains("project_selected"))

        service.updateWorkspaceCatalog([
            MemoryWorkspaceCatalogEntry(projectName: "general", displayName: "general", rootPath: generalRoot.path, isGeneral: true)
        ])
        service.loadWorkspaceRecords(projectRoot: generalRoot.path, projectName: nil)
        let removedProjectDashboard = service.dashboard(projectName: nil, projectRoot: generalRoot.path, isGeneral: true)
        let localOverlayOnly = try XCTUnwrap(removedProjectDashboard.workspace.generalProjects.first { $0.projectName == "SaaS Pricing Rewrite" })
        XCTAssertNotEqual(localOverlayOnly.sourceType, "workspace_external")
        let recalledAfterRemoval = await service.retrieveContextForTurn(
            query: "请回忆一下 SaaS Pricing Rewrite 的要求",
            recentMessages: [],
            sessionID: "general-recall-saas-after-removal",
            projectName: nil,
            projectRoot: generalRoot.path
        )
        XCTAssertTrue(recalledAfterRemoval.systemContext.contains("年付节省"))
        XCTAssertFalse(recalledAfterRemoval.systemContext.contains("draft.md"))
        XCTAssertFalse(recalledAfterRemoval.systemContext.contains("立即购买"))
    }

    @MainActor
    func testMemoryFeedbackSpecEndToEndNativeFlow() async throws {
        let root = repoRootURL()
            .appendingPathComponent("pilotdeck-memory-feedback-spec-\(UUID().uuidString)", isDirectory: true)
        let memoryRoot = root.appendingPathComponent("memory-root", isDirectory: true)
        let generalRoot = root.appendingPathComponent("general", isDirectory: true)
        let workspaceA = root.appendingPathComponent("memory-test-a", isDirectory: true)
        let workspaceB = root.appendingPathComponent("memory-test-b", isDirectory: true)
        try FileManager.default.createDirectory(at: generalRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = MemoryService(memoryRoot: memoryRoot)
        service.updateWorkspaceCatalog([
            MemoryWorkspaceCatalogEntry(projectName: "general", displayName: "general", rootPath: generalRoot.path, isGeneral: true),
            MemoryWorkspaceCatalogEntry(projectName: "Wedding Launch Copy", displayName: "Wedding Launch Copy", rootPath: workspaceA.path, isGeneral: false),
            MemoryWorkspaceCatalogEntry(projectName: "SaaS Pricing Rewrite", displayName: "SaaS Pricing Rewrite", rootPath: workspaceB.path, isGeneral: false)
        ])

        func capture(_ text: String, sessionID: String, projectName: String?, projectRoot: URL) {
            let user = ChatMessage(
                id: UUID(),
                sessionId: sessionID,
                provider: .pilotDeck,
                role: .user,
                blocks: [.text(text)],
                createdAt: Date(),
                isStreaming: false,
                tokenBudget: nil
            )
            let assistant = ChatMessage(
                id: UUID(),
                sessionId: sessionID,
                provider: .pilotDeck,
                role: .assistant,
                blocks: [.text("已记录。")],
                createdAt: Date(),
                isStreaming: false,
                tokenBudget: nil
            )
            _ = service.captureTurn(
                messages: [user, assistant],
                sessionID: sessionID,
                projectName: projectName,
                projectRoot: projectRoot.path
            )
        }

        func recall(_ query: String, sessionID: String, projectName: String?, projectRoot: URL) async -> String {
            let result = await service.retrieveContextForTurn(
                query: query,
                recentMessages: [],
                sessionID: sessionID,
                projectName: projectName,
                projectRoot: projectRoot.path
            )
            XCTAssertTrue(result.injected, "Expected memory context for query: \(query)")
            return result.systemContext
        }

        func assertContainsAll(_ haystack: String, _ needles: [String], file: StaticString = #filePath, line: UInt = #line) {
            for needle in needles {
                XCTAssertTrue(haystack.contains(needle), "Expected memory context to contain \(needle). Context:\n\(haystack)", file: file, line: line)
            }
        }

        func assertContainsNone(_ haystack: String, _ needles: [String], file: StaticString = #filePath, line: UInt = #line) {
            for needle in needles {
                XCTAssertFalse(haystack.contains(needle), "Expected memory context not to contain \(needle). Context:\n\(haystack)", file: file, line: line)
            }
        }

        capture(
            "我叫张三，是婚礼策划师，长期在英国生活，主要服务伦敦和曼城的华人婚礼客户。",
            sessionID: "global-user-identity",
            projectName: nil,
            projectRoot: generalRoot
        )
        capture(
            "我还有一个长期副业，是帮中小商家做小红书获客咨询，平时更关注转化率、标题点击率和内容自然感。",
            sessionID: "global-user-side-business",
            projectName: nil,
            projectRoot: generalRoot
        )
        _ = try await service.runIndexJob(projectRoot: generalRoot.path, projectName: nil)
        _ = await service.runDreamJob(projectName: nil, projectRoot: generalRoot.path)

        var context = await recall(
            "我是谁，长期在哪里生活，主要服务谁？",
            sessionID: "recall-global-identity",
            projectName: nil,
            projectRoot: generalRoot
        )
        assertContainsAll(context, ["张三", "英国", "伦敦", "曼城", "华人婚礼客户"])

        context = await recall(
            "我还有什么长期副业，平时最关注哪些指标？",
            sessionID: "recall-global-side-business",
            projectName: nil,
            projectRoot: generalRoot
        )
        assertContainsAll(context, ["小红书获客咨询", "转化率", "标题点击率", "内容自然感"])

        capture(
            "这个项目叫 Wedding Launch Copy，目标是给英国华人婚礼客户写小红书获客文案。一期先产出 10 篇模板。当前最大风险是文案太像硬广、缺少真实分享感。",
            sessionID: "workspace-a-project",
            projectName: "Wedding Launch Copy",
            projectRoot: workspaceA
        )
        capture(
            "这个项目里封面标题不要超过 14 个字，语气要像真实新娘分享，避免销售腔。",
            sessionID: "workspace-a-rules",
            projectName: "Wedding Launch Copy",
            projectRoot: workspaceA
        )
        _ = try await service.runIndexJob(projectRoot: workspaceA.path, projectName: "Wedding Launch Copy")

        capture(
            "这个项目叫 SaaS Pricing Rewrite，目标是给 B2B SaaS 官网改写定价页文案。一期先完成 3 个定价方案对比模块。当前最大风险是卖点太泛、没有差异化。",
            sessionID: "workspace-b-project",
            projectName: "SaaS Pricing Rewrite",
            projectRoot: workspaceB
        )
        capture(
            "这个项目里 CTA 不要出现“立即购买”，默认用简洁商务中文；如果要写文件，优先新建 draft.md，不要改动 .gitignore。",
            sessionID: "workspace-b-rules",
            projectName: "SaaS Pricing Rewrite",
            projectRoot: workspaceB
        )
        _ = try await service.runIndexJob(projectRoot: workspaceB.path, projectName: "SaaS Pricing Rewrite")

        context = await recall(
            "这个项目的一期目标、主要风险和标题限制分别是什么？",
            sessionID: "recall-workspace-a",
            projectName: "Wedding Launch Copy",
            projectRoot: workspaceA
        )
        assertContainsAll(context, ["10 篇模板", "硬广", "真实分享感", "14 个字"])
        assertContainsNone(context, ["draft.md", "立即购买"])

        context = await recall(
            "这个项目的一期目标、主要风险、CTA 限制和文件规范分别是什么？",
            sessionID: "recall-workspace-b",
            projectName: "SaaS Pricing Rewrite",
            projectRoot: workspaceB
        )
        assertContainsAll(context, ["3 个定价方案", "卖点太泛", "没有差异化", "立即购买", "draft.md", ".gitignore"])
        assertContainsNone(context, ["14 个字"])

        context = await recall(
            "结合我的长期背景和当前项目，给我一句这个项目更适合什么写法。",
            sessionID: "recall-workspace-a-mix",
            projectName: "Wedding Launch Copy",
            projectRoot: workspaceA
        )
        assertContainsAll(context, ["婚礼策划师", "英国", "华人婚礼客户", "小红书获客文案", "真实分享", "硬广"])

        context = await recall(
            "关于 Wedding Launch Copy，这个项目的一期目标、风险和标题限制分别是什么？",
            sessionID: "recall-general-a",
            projectName: nil,
            projectRoot: generalRoot
        )
        assertContainsAll(context, ["10 篇模板", "硬广", "14 个字"])
        assertContainsNone(context, ["draft.md", "立即购买"])

        context = await recall(
            "关于 SaaS Pricing Rewrite，这个项目的一期目标、CTA 限制和文件操作规范分别是什么？",
            sessionID: "recall-general-b",
            projectName: nil,
            projectRoot: generalRoot
        )
        assertContainsAll(context, ["3 个定价方案", "立即购买", "draft.md", ".gitignore"])
        assertContainsNone(context, ["14 个字"])

        capture(
            "补充一条长期项目规则：在 SaaS Pricing Rewrite 里，默认先强调年付节省，不要提永久免费方案。记住这条规则。",
            sessionID: "general-b-overlay",
            projectName: nil,
            projectRoot: generalRoot
        )
        _ = try await service.runIndexJob(projectRoot: generalRoot.path, projectName: nil)

        context = await recall(
            "在 SaaS Pricing Rewrite 里默认应该强调什么、不该提什么、CTA 怎么写？",
            sessionID: "recall-general-b-overlay",
            projectName: nil,
            projectRoot: generalRoot
        )
        assertContainsAll(context, ["年付节省", "永久免费", "立即购买"])
        let generalDashboard = service.dashboard(projectName: nil, projectRoot: generalRoot.path, isGeneral: true)
        let saasProject = try XCTUnwrap(generalDashboard.workspace.generalProjects.first { $0.projectName == "SaaS Pricing Rewrite" })
        XCTAssertEqual(saasProject.sourceType, "workspace_external")

        context = await recall(
            "这个项目的一期目标、CTA 限制和文件规范分别是什么？",
            sessionID: "recall-workspace-b-after-overlay",
            projectName: "SaaS Pricing Rewrite",
            projectRoot: workspaceB
        )
        assertContainsAll(context, ["3 个定价方案", "立即购买", "draft.md", ".gitignore"])
        assertContainsNone(context, ["年付节省", "永久免费"])

        capture(
            "我现在在 General Chat 里开一个新项目，项目名叫 GBX-A 20260423 HoneydewPulse。这个项目目标是给英国奶茶店写小红书获客文案，一期先做 6 篇内容模板。当前最大风险是文案太像广告，缺少真实顾客体验感。",
            sessionID: "general-local-project",
            projectName: nil,
            projectRoot: generalRoot
        )
        capture(
            "GBX-A 20260423 HoneydewPulse 这个项目里，标题不要超过 16 个字，语气要像真实顾客种草，禁止出现“全网最低价”。",
            sessionID: "general-local-project-rules",
            projectName: nil,
            projectRoot: generalRoot
        )
        _ = try await service.runIndexJob(projectRoot: generalRoot.path, projectName: nil)

        context = await recall(
            "关于 GBX-A 20260423 HoneydewPulse，这个项目的一期目标、主要风险和标题限制是什么？",
            sessionID: "recall-general-local-project",
            projectName: nil,
            projectRoot: generalRoot
        )
        assertContainsAll(context, ["6 篇内容模板", "太像广告", "真实顾客体验感", "16 个字", "全网最低价"])
        XCTAssertTrue(
            service.dashboard(projectName: nil, projectRoot: generalRoot.path, isGeneral: true)
                .workspace
                .generalProjects
                .contains { $0.projectName == "GBX-A 20260423 HoneydewPulse" }
        )
    }

    @MainActor
    func testMemoryIndexAndDreamPromoteUserIdentityToGlobalProfile() async throws {
        let root = repoRootURL()
            .appendingPathComponent("pilotdeck-memory-identity-\(UUID().uuidString)", isDirectory: true)
        let memoryRoot = root.appendingPathComponent("memory-root", isDirectory: true)
        let projectRoot = root.appendingPathComponent("Native", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = MemoryService(memoryRoot: memoryRoot)
        let sessionID = "session-identity"
        let user = ChatMessage(
            id: UUID(),
            sessionId: sessionID,
            provider: .pilotDeck,
            role: .user,
            blocks: [.text("你好 我叫张三 是一个游戏开发工程师")],
            createdAt: Date(),
            isStreaming: false,
            tokenBudget: nil
        )
        let assistant = ChatMessage(
            id: UUID(),
            sessionId: sessionID,
            provider: .pilotDeck,
            role: .assistant,
            blocks: [.text("你好，张三。")],
            createdAt: Date(),
            isStreaming: false,
            tokenBudget: nil
        )

        XCTAssertNil(service.captureTurn(
            messages: [user, assistant],
            sessionID: sessionID,
            projectName: "Native",
            projectRoot: projectRoot.path
        ))
        let indexed = try await service.runIndexJob(projectRoot: projectRoot.path, projectName: "Native")
        let userNote = try XCTUnwrap(indexed.records.first { $0.relativePath.hasPrefix("global/UserIdentityNotes/") })

        XCTAssertEqual(userNote.type, .user)
        XCTAssertNil(userNote.projectName)
        XCTAssertTrue(userNote.content.contains("张三"))
        XCTAssertTrue(userNote.content.contains("游戏开发工程师"))
        XCTAssertFalse(indexed.records.contains { $0.relativePath.contains("Project/turn-") })

        let dreamed = await service.runDreamJob(projectName: "Native", projectRoot: projectRoot.path)
        XCTAssertTrue(dreamed.userSummary.contains("张三"))
        XCTAssertTrue(dreamed.userSummary.contains("游戏开发工程师"))
        XCTAssertTrue(dreamed.records.contains { $0.relativePath == "global/UserIdentity/user-profile.md" })
        XCTAssertFalse(dreamed.records.contains { $0.relativePath == userNote.relativePath })
        let dreamStepIDs = dreamed.dreamTraceRecords.first?.steps.map(\.id) ?? []
        XCTAssertTrue(dreamStepIDs.contains("snapshot_loaded"))
        XCTAssertTrue(dreamStepIDs.contains("project_header_scan"))
        XCTAssertTrue(dreamStepIDs.contains("feedback_header_scan"))
        XCTAssertTrue(dreamStepIDs.contains("user_profile_rewritten"))
        XCTAssertTrue(dreamStepIDs.contains("manifests_repaired"))

        let recalled = await service.retrieveContextForTurn(
            query: "我叫什么名字？",
            recentMessages: [],
            sessionID: "recall-identity",
            projectName: "Native",
            projectRoot: projectRoot.path
        )
        XCTAssertTrue(recalled.injected)
        XCTAssertTrue(recalled.systemContext.contains("张三"))
        let identityTrace = try XCTUnwrap(service.caseTraces(limit: 1).first)
        XCTAssertTrue(identityTrace.steps.first(where: { $0.id == "memory_gate" })?.detail.contains("route=user") == true)
        XCTAssertTrue(identityTrace.steps.first(where: { $0.id == "user_base_loaded" })?.detail.contains("identityBackground=1") == true)
        XCTAssertTrue(identityTrace.steps.first(where: { $0.id == "files_loaded" })?.detail.contains("loaded=1") == true)
        XCTAssertTrue(identityTrace.steps.first(where: { $0.id == "context_rendered" })?.detail.contains("userBaseInjected=yes") == true)
    }

    @MainActor
    func testMemoryJobsPersistStateAndTraceIDsInSnapshot() async throws {
        let root = repoRootURL()
            .appendingPathComponent("pilotdeck-memory-job-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "hello".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let service = MemoryService()
        let indexed = try await service.runIndexJob(projectRoot: root.path, projectName: "Native")

        XCTAssertEqual(indexed.jobStates[.index]?.phase, .completed)
        XCTAssertEqual(indexed.jobStates[.index]?.traceID, indexed.indexTraceRecords.first?.id)

        _ = service.retrieveContext(
            query: "What did we do?",
            recentMessages: [],
            sessionID: "recall-job",
            projectName: "Native",
            projectRoot: root.path
        )
        let recalled = service.dashboard(projectName: "Native", projectRoot: root.path)
        XCTAssertEqual(recalled.jobStates[.recall]?.phase, .completed)
        XCTAssertEqual(recalled.jobStates[.recall]?.traceID, recalled.caseTraceRecords.first?.id)

        let dreamed = await service.runDreamJob(projectName: "Native", projectRoot: root.path)
        XCTAssertEqual(dreamed.jobStates[.dream]?.phase, .completed)
        XCTAssertEqual(dreamed.jobStates[.dream]?.traceID, dreamed.dreamTraceRecords.first?.id)
    }

    @MainActor
    func testMemoryAutomaticJobsRunDueIndexAndDreamWithAutoTraces() async throws {
        let root = repoRootURL()
            .appendingPathComponent("pilotdeck-memory-auto-\(UUID().uuidString)", isDirectory: true)
        let memoryRoot = root.appendingPathComponent("memory-root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "auto memory smoke".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let service = MemoryService(memoryRoot: memoryRoot)
        service.updateSettings(MemorySettingsSnapshot(autoIndexIntervalMinutes: 1, autoDreamIntervalMinutes: 1))
        for index in 1...2 {
            let sessionID = "auto-\(index)"
            let user = ChatMessage(
                id: UUID(),
                sessionId: sessionID,
                provider: .pilotDeck,
                role: .user,
                blocks: [.text("Remember project fact \(index): auto memory should persist.")],
                createdAt: Date(),
                isStreaming: false,
                tokenBudget: nil
            )
            let assistant = ChatMessage(
                id: UUID(),
                sessionId: sessionID,
                provider: .pilotDeck,
                role: .assistant,
                blocks: [.text("Saved project fact \(index).")],
                createdAt: Date(),
                isStreaming: false,
                tokenBudget: nil
            )
            XCTAssertNil(service.captureTurn(
                messages: [user, assistant],
                sessionID: sessionID,
                projectName: "Native",
                projectRoot: root.path
            ))
        }

        XCTAssertEqual(service.automaticJobKindsDue(), [.index, .dream])

        let first = await service.runAutomaticJobsIfDue(projectRoot: root.path, projectName: "Native")
        XCTAssertEqual(first.jobStates[.index]?.phase, .completed)
        XCTAssertEqual(first.jobStates[.dream]?.phase, .completed)
        XCTAssertEqual(first.indexTraceRecords.first?.trigger, "auto")
        XCTAssertEqual(first.dreamTraceRecords.first?.trigger, "auto")
        XCTAssertFalse(first.records.contains { $0.name.hasPrefix("Project Dream") })
        XCTAssertFalse(first.records.contains { $0.relativePath.hasPrefix("Project/Dream/") })
        XCTAssertGreaterThanOrEqual(first.records.count, 2)

        let second = await service.runAutomaticJobsIfDue(projectRoot: root.path, projectName: "Native")
        XCTAssertEqual(second.indexTraceRecords.count, first.indexTraceRecords.count)
        XCTAssertEqual(second.dreamTraceRecords.count, first.dreamTraceRecords.count)

        service.updateSettings(MemorySettingsSnapshot(autoIndexIntervalMinutes: 0, autoDreamIntervalMinutes: 0))
        XCTAssertEqual(service.automaticJobKindsDue(), [])
    }

    func testAlwaysOnServiceParsesWebCronAndRunHistoryShape() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pilotdeck-alwayson-\(UUID().uuidString)", isDirectory: true)
        let alwaysOnRoot = root.appendingPathComponent(".pilotdeck/always-on", isDirectory: true)
        let plansRoot = alwaysOnRoot.appendingPathComponent("plans", isDirectory: true)
        let runsRoot = alwaysOnRoot.appendingPathComponent("runs", isDirectory: true)
        try FileManager.default.createDirectory(at: plansRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "# Plan A\n\nRun the nightly checks.".write(
            to: plansRoot.appendingPathComponent("plan-a.md"),
            atomically: true,
            encoding: .utf8
        )
        try """
        {
          "plans": [
            {
              "id": "plan-a",
              "title": "Nightly checks",
              "summary": "Check the project every night.",
              "rationale": "Keep background maintenance visible.",
              "status": "ready",
              "approvalMode": "manual",
              "planFilePath": ".pilotdeck/always-on/plans/plan-a.md",
              "contextRefs": {
                "workingDirectory": ["/repo"],
                "memory": ["Router parity note"],
                "recentChats": ["Session one"]
              },
              "createdAt": "2026-05-23T10:00:00Z",
              "updatedAt": "2026-05-23T10:05:00Z",
              "executionSessionId": "session-plan",
              "executionStatus": "completed"
            }
          ]
        }
        """.write(to: alwaysOnRoot.appendingPathComponent("discovery-plans.json"), atomically: true, encoding: .utf8)
        try """
        {
          "jobs": [
            {
              "id": "cron-a",
              "prompt": "# Nightly\\nRun diagnostics",
              "cron": "0 1 * * *",
              "status": "scheduled",
              "recurring": true,
              "durable": false,
              "permanent": true,
              "manualOnly": true,
              "originSessionId": "origin-session",
              "transcriptKey": "cron-transcript",
              "createdAt": 1770000000000,
              "lastFiredAt": 1770003600000,
              "latestRun": {
                "status": "running",
                "runId": "run-a",
                "startedAt": "2026-05-23T10:10:00Z",
                "sessionId": "session-a",
                "summary": "Still running",
                "lastActivity": "2026-05-23T10:11:00Z",
                "taskId": "task-a",
                "outputFile": "runs/run-a.log",
                "parentSessionId": "parent-a",
                "relativeTranscriptPath": "transcripts/session-a.jsonl",
                "transcriptKey": "run-transcript"
              }
            }
          ]
        }
        """.write(to: alwaysOnRoot.appendingPathComponent("cron-jobs.json"), atomically: true, encoding: .utf8)
        try """
        {"runId":"run-a","title":"Cron Run","kind":"cron","status":"running","startedAt":"2026-05-23T10:10:00Z","sourceId":"cron-a","outputLog":"inline log","session":{"sessionId":"session-a","parentSessionId":"parent-a","relativeTranscriptPath":"transcripts/session-a.jsonl"}}
        """.write(to: alwaysOnRoot.appendingPathComponent("run-history.jsonl"), atomically: true, encoding: .utf8)
        try "log file content".write(to: runsRoot.appendingPathComponent("run-a.log"), atomically: true, encoding: .utf8)

        let service = AlwaysOnService()
        let plans = service.plans(projectRoot: root.path)
        let cronJobs = service.cronJobs(projectRoot: root.path)
        let history = service.runHistory(projectRoot: root.path)

        XCTAssertEqual(plans.first?.id, "plan-a")
        XCTAssertEqual(plans.first?.content, "# Plan A\n\nRun the nightly checks.")
        XCTAssertEqual(plans.first?.executionStatus, .completed)
        XCTAssertEqual(plans.first?.contextRefs?["workingDirectory"], ["/repo"])
        XCTAssertEqual(plans.first?.contextRefs?["memory"], ["Router parity note"])
        XCTAssertEqual(cronJobs.first?.status, .scheduled)
        XCTAssertEqual(cronJobs.first?.durable, false)
        XCTAssertEqual(cronJobs.first?.permanent, true)
        XCTAssertEqual(cronJobs.first?.manualOnly, true)
        XCTAssertEqual(cronJobs.first?.originSessionId, "origin-session")
        XCTAssertEqual(cronJobs.first?.transcriptKey, "cron-transcript")
        XCTAssertEqual(cronJobs.first?.latestSessionId, "session-a")
        XCTAssertEqual(cronJobs.first?.latestRun?.parentSessionId, "parent-a")
        XCTAssertEqual(cronJobs.first?.latestRun?.relativeTranscriptPath, "transcripts/session-a.jsonl")
        XCTAssertEqual(history.first?.sessionId, "session-a")
        XCTAssertEqual(history.first?.parentSessionId, "parent-a")
        XCTAssertEqual(history.first?.relativeTranscriptPath, "transcripts/agent-session-a.jsonl")
        XCTAssertEqual(history.first?.outputLog, "log file content")
    }

    func testAlwaysOnServiceCreatesPlanAndRunHistoryRoundTrip() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pilotdeck-alwayson-roundtrip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = AlwaysOnService()
        let plan = try service.createDiscoveryPlan(
            projectRoot: root.path,
            title: "Review dependencies",
            prompt: "Check dependency health weekly."
        )
        let run = try service.startPlanRun(plan: plan, projectRoot: root.path, sessionId: "session-run")
        let plans = service.plans(projectRoot: root.path)
        let history = service.runHistory(projectRoot: root.path)

        XCTAssertEqual(plans.first?.id, plan.id)
        XCTAssertEqual(plans.first?.status, .running)
        XCTAssertEqual(history.first?.id, run.id)
        XCTAssertEqual(history.first?.sessionId, "session-run")
        XCTAssertTrue(history.first?.outputLog.contains("Started native Always-On plan run") == true)

        let discoveryRun = try service.startDiscoveryRun(
            projectRoot: root.path,
            title: "Manual discovery",
            sessionId: "session-discovery",
            runID: "discovery-roundtrip"
        )
        try service.finishDiscoveryRun(
            run: discoveryRun,
            projectRoot: root.path,
            status: .noPlan,
            sessionId: "session-discovery",
            outputLog: "No plan needed.",
            metadata: ["trigger": "manual"]
        )
        let discoveryHistory = try XCTUnwrap(service.runHistory(projectRoot: root.path).first { $0.id == "discovery-roundtrip" })
        XCTAssertEqual(discoveryHistory.kind, "discovery")
        XCTAssertEqual(discoveryHistory.status, .noPlan)
        XCTAssertEqual(discoveryHistory.sessionId, "session-discovery")
        XCTAssertEqual(discoveryHistory.metadata["trigger"], "manual")
        XCTAssertEqual(discoveryHistory.outputLog, "No plan needed.")

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".pilotdeck/always-on", isDirectory: true).path))
    }

    func testAlwaysOnServiceReadsWebPilotDeckAlwaysOnAndCronTaskFiles() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pilotdeck-alwayson-pilotdeck-\(UUID().uuidString)", isDirectory: true)
        let alwaysOnRoot = root.appendingPathComponent(".pilotdeck/always-on", isDirectory: true)
        let plansRoot = alwaysOnRoot.appendingPathComponent("plans", isDirectory: true)
        let runsRoot = alwaysOnRoot.appendingPathComponent("runs", isDirectory: true)
        try FileManager.default.createDirectory(at: plansRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: runsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".pilotdeck", isDirectory: true), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "# Web Plan\n\nUse the web Always-On root.".write(
            to: plansRoot.appendingPathComponent("plan-web.md"),
            atomically: true,
            encoding: .utf8
        )
        try """
        {
          "plans": [
            {
              "id": "plan-web",
              "title": "Web root plan",
              "summary": "Plan stored in .pilotdeck.",
              "rationale": "Matches the web UI storage path.",
              "status": "ready",
              "approvalMode": "manual",
              "planFilePath": ".pilotdeck/always-on/plans/plan-web.md",
              "createdAt": "2026-05-23T10:00:00Z",
              "updatedAt": "2026-05-23T10:05:00Z"
            }
          ]
        }
        """.write(to: alwaysOnRoot.appendingPathComponent("discovery-plans.json"), atomically: true, encoding: .utf8)
        try """
        {"runId":"run-web","title":"Support scan","kind":"cron","status":"completed","startedAt":"2026-05-23T10:10:00Z","sourceId":"cron-durable","session":{"sessionId":"background-session","parentSessionId":"parent-session","relativeTranscriptPath":"parent-session/subagents/agent-cron.jsonl"}}
        """.write(to: alwaysOnRoot.appendingPathComponent("run-history.jsonl"), atomically: true, encoding: .utf8)
        try "web log content".write(to: runsRoot.appendingPathComponent("run-web.log"), atomically: true, encoding: .utf8)
        try """
        {
          "tasks": [
            {
              "id": "cron-durable",
              "cron": "*/15 * * * *",
              "prompt": "# Support scan\\nReview incoming support spikes",
              "createdAt": 1770000000000,
              "recurring": true,
              "originSessionId": "origin-durable",
              "transcriptKey": "cron-durable-key"
            }
          ]
        }
        """.write(to: root.appendingPathComponent(".pilotdeck/scheduled_tasks.json"), atomically: true, encoding: .utf8)
        try """
        {
          "tasks": [
            {
              "id": "cron-session",
              "cron": "0 9 * * *",
              "prompt": "Follow up on the stale TODOs",
              "createdAt": 1770003600000,
              "manualOnly": true,
              "originSessionId": "origin-session"
            }
          ]
        }
        """.write(to: root.appendingPathComponent(".pilotdeck/session_scheduled_tasks.json"), atomically: true, encoding: .utf8)

        let service = AlwaysOnService()
        let plans = service.plans(projectRoot: root.path)
        let history = service.runHistory(projectRoot: root.path)
        let jobsByID = Dictionary(uniqueKeysWithValues: service.cronJobs(projectRoot: root.path).map { ($0.id, $0) })

        XCTAssertEqual(plans.first?.planFilePath, ".pilotdeck/always-on/plans/plan-web.md")
        XCTAssertEqual(plans.first?.content, "# Web Plan\n\nUse the web Always-On root.")
        XCTAssertEqual(history.first?.outputLog, "web log content")
        XCTAssertEqual(jobsByID["cron-durable"]?.durable, true)
        XCTAssertEqual(jobsByID["cron-durable"]?.status, .scheduled)
        XCTAssertEqual(jobsByID["cron-durable"]?.latestRun?.runId, "run-web")
        XCTAssertEqual(jobsByID["cron-durable"]?.latestRun?.parentSessionId, "parent-session")
        XCTAssertEqual(jobsByID["cron-session"]?.durable, false)
        XCTAssertEqual(jobsByID["cron-session"]?.manualOnly, true)
    }

    func testAlwaysOnServiceStartsAndDeletesWebCronJobs() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pilotdeck-alwayson-cron-actions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".pilotdeck", isDirectory: true), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        {
          "tasks": [
            {
              "id": "cron-run-now",
              "cron": "*/5 * * * *",
              "prompt": "# Run now\\nCheck status",
              "createdAt": 1770000000000,
              "recurring": true
            },
            {
              "id": "cron-delete",
              "cron": "0 0 * * *",
              "prompt": "Remove me",
              "createdAt": 1770000000000,
              "recurring": true
            }
          ]
        }
        """.write(to: root.appendingPathComponent(".pilotdeck/scheduled_tasks.json"), atomically: true, encoding: .utf8)

        let service = AlwaysOnService()
        let job = try XCTUnwrap(service.cronJobs(projectRoot: root.path).first { $0.id == "cron-run-now" })
        let run = try service.startCronRun(job: job, projectRoot: root.path, sessionId: "session-run-now")
        let refreshed = try XCTUnwrap(service.cronJobs(projectRoot: root.path).first { $0.id == "cron-run-now" })

        XCTAssertEqual(refreshed.status, .running)
        XCTAssertEqual(refreshed.latestRun?.runId, run.id)
        XCTAssertEqual(refreshed.latestRun?.sessionId, "session-run-now")
        XCTAssertEqual(service.runHistory(projectRoot: root.path).first?.sourceId, "cron-run-now")
        XCTAssertEqual(service.runLog(projectRoot: root.path, runID: run.id).source, .logFile)

        XCTAssertTrue(try service.deleteCronJob(jobID: "cron-delete", projectRoot: root.path))
        XCTAssertNil(service.cronJobs(projectRoot: root.path).first { $0.id == "cron-delete" })
    }

    func testAlwaysOnServiceFoldsRunHistoryEventsAndPreservesMetadata() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pilotdeck-alwayson-run-history-fold-\(UUID().uuidString)", isDirectory: true)
        let alwaysOnRoot = root.appendingPathComponent(".pilotdeck/always-on", isDirectory: true)
        try FileManager.default.createDirectory(at: alwaysOnRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let lines = [
            """
            {"runId":"run-1","kind":"plan","sourceId":"plan-alpha","title":"Plan Alpha","status":"queued","timestamp":"2026-04-20T10:00:00.000Z","metadata":{"source":"manual"}}
            """,
            """
            {"runId":"run-1","kind":"plan","sourceId":"plan-alpha","title":"Plan Alpha","status":"completed","timestamp":"2026-04-20T10:05:00.000Z","finishedAt":"2026-04-20T10:05:00.000Z","sessionId":"session-1","output":"Done.","metadata":{"planFilePath":".pilotdeck/always-on/plans/plan-alpha.md"}}
            """,
            "not json",
        ].joined(separator: "\n") + "\n"
        try lines.write(to: alwaysOnRoot.appendingPathComponent("run-history.jsonl"), atomically: true, encoding: .utf8)

        let service = AlwaysOnService()
        let history = service.runHistory(projectRoot: root.path)
        let detail = try XCTUnwrap(service.runHistoryDetail(projectRoot: root.path, runID: "run-1"))

        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.id, "run-1")
        XCTAssertEqual(history.first?.status, .completed)
        XCTAssertEqual(history.first?.sessionId, "session-1")
        XCTAssertEqual(detail.outputLog, "Done.")
        XCTAssertEqual(detail.metadata["source"], "manual")
        XCTAssertEqual(detail.metadata["planFilePath"], ".pilotdeck/always-on/plans/plan-alpha.md")
        XCTAssertEqual(detail.metadata["logSource"], "history")
        XCTAssertEqual(detail.metadata["finishedAt"], "2026-04-20T10:05:00Z")
    }

    func testAlwaysOnServiceDerivesBackgroundSessionAndFiltersUnknownHistoryLikeWeb() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pilotdeck-alwayson-run-history-session-\(UUID().uuidString)", isDirectory: true)
        let alwaysOnRoot = root.appendingPathComponent(".pilotdeck/always-on", isDirectory: true)
        try FileManager.default.createDirectory(at: alwaysOnRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let lines = [
            """
            {"runId":"run-cron","kind":"cron","sourceId":"cron-alpha","title":"Cron Alpha","status":"completed","timestamp":"2026-04-20T10:00:00.000Z","parentSessionId":"origin-session","relativeTranscriptPath":"origin-session/subagents/agent-cron-thread.jsonl"}
            """,
            """
            {"runId":"run-metadata","kind":"cron","sourceId":"cron-beta","title":"Cron Beta","status":"completed","timestamp":"2026-04-20T10:01:00.000Z","metadata":{"originSessionId":"origin-session","transcriptKey":"cron-thread-raw"}}
            """,
            """
            {"runId":"run-hidden","kind":"cron","sourceId":"cron-hidden","title":"Hidden","status":"unknown","timestamp":"2026-04-20T10:02:00.000Z"}
            """,
        ].joined(separator: "\n") + "\n"
        try lines.write(to: alwaysOnRoot.appendingPathComponent("run-history.jsonl"), atomically: true, encoding: .utf8)

        let service = AlwaysOnService()
        let historyIDs = service.runHistory(projectRoot: root.path).map(\.id)
        let cronDetail = try XCTUnwrap(service.runHistoryDetail(projectRoot: root.path, runID: "run-cron"))
        let metadataDetail = try XCTUnwrap(service.runHistoryDetail(projectRoot: root.path, runID: "run-metadata"))
        let hiddenDetail = try XCTUnwrap(service.runHistoryDetail(projectRoot: root.path, runID: "run-hidden"))

        XCTAssertFalse(historyIDs.contains("run-hidden"))
        XCTAssertEqual(cronDetail.sessionId, "background-origin-session-agent-cron-thread")
        XCTAssertEqual(cronDetail.metadata["sessionId"], "background-origin-session-agent-cron-thread")
        XCTAssertEqual(metadataDetail.sessionId, "background-origin-session-agent-cron-thread-raw")
        XCTAssertEqual(metadataDetail.parentSessionId, "origin-session")
        XCTAssertEqual(metadataDetail.relativeTranscriptPath, "origin-session/subagents/agent-cron-thread-raw.jsonl")
        XCTAssertEqual(hiddenDetail.status, .unknown)
    }

    func testAlwaysOnRunHistoryDetailPrefersDedicatedLogAndPollsOnlyQueuedOrRunning() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pilotdeck-alwayson-run-history-log-\(UUID().uuidString)", isDirectory: true)
        let alwaysOnRoot = root.appendingPathComponent(".pilotdeck/always-on", isDirectory: true)
        let runsRoot = alwaysOnRoot.appendingPathComponent("runs", isDirectory: true)
        try FileManager.default.createDirectory(at: runsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        {"runId":"run-log","kind":"plan","sourceId":"plan-log","title":"Plan Log","status":"running","timestamp":"2026-04-20T10:00:00.000Z","output":"history output"}
        """.write(to: alwaysOnRoot.appendingPathComponent("run-history.jsonl"), atomically: true, encoding: .utf8)
        try "dedicated log output\n".write(to: runsRoot.appendingPathComponent("run-log.log"), atomically: true, encoding: .utf8)

        let detail = try XCTUnwrap(AlwaysOnService().runHistoryDetail(projectRoot: root.path, runID: "run-log"))

        XCTAssertEqual(detail.outputLog, "dedicated log output\n")
        XCTAssertEqual(detail.metadata["logSource"], "log-file")
        XCTAssertEqual(detail.metadata["logSize"], String("dedicated log output\n".utf8.count))
        XCTAssertTrue(detail.shouldPollLog)
        XCTAssertFalse(AlwaysOnRunHistory(
            id: "run-complete",
            title: "Complete",
            kind: "plan",
            status: .completed,
            startedAt: Date(),
            sourceId: "plan-complete",
            outputLog: "",
            sessionId: nil,
            parentSessionId: nil,
            relativeTranscriptPath: nil
        ).shouldPollLog)
    }

    func testNativeAlwaysOnRowsMatchWebItemsFilteringSortingAndActions() throws {
        let base = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-05-23T12:00:00Z"))
        func plan(
            _ id: String,
            status: AlwaysOnStatus,
            updatedOffset: TimeInterval,
            executionSessionId: String? = nil,
            executionStatus: AlwaysOnStatus? = nil
        ) -> AlwaysOnPlan {
            AlwaysOnPlan(
                id: id,
                title: id,
                summary: "",
                rationale: "",
                content: "",
                status: status,
                approvalMode: "manual",
                planFilePath: ".pilotdeck/always-on/plans/\(id).md",
                contextRefs: nil,
                createdAt: base.addingTimeInterval(-1_000),
                updatedAt: base.addingTimeInterval(updatedOffset),
                executionSessionId: executionSessionId,
                executionStatus: executionStatus
            )
        }
        func cron(
            _ id: String,
            status: AlwaysOnStatus,
            recurring: Bool,
            durable: Bool = true,
            manualOnly: Bool = false,
            createdOffset: TimeInterval = -800,
            firedOffset: TimeInterval? = nil,
            latestActivityOffset: TimeInterval? = nil
        ) -> AlwaysOnCronJob {
            AlwaysOnCronJob(
                id: id,
                prompt: "# \(id)\nDo work",
                cron: "0 1 * * *",
                status: status,
                recurring: recurring,
                durable: durable,
                createdAt: base.addingTimeInterval(createdOffset),
                lastFiredAt: firedOffset.map { base.addingTimeInterval($0) },
                latestSessionId: nil,
                permanent: false,
                manualOnly: manualOnly,
                originSessionId: nil,
                transcriptKey: nil,
                latestRun: latestActivityOffset.map {
                    AlwaysOnCronLatestRun(
                        status: status,
                        runId: "run-\(id)",
                        startedAt: base.addingTimeInterval($0 - 30),
                        sessionId: "session-\(id)",
                        summary: id,
                        lastActivity: base.addingTimeInterval($0),
                        taskId: id,
                        outputFile: ".pilotdeck/always-on/runs/run-\(id).log",
                        parentSessionId: nil,
                        relativeTranscriptPath: nil,
                        transcriptKey: nil
                    )
                }
            )
        }

        let rows = NativeAlwaysOnRows.rows(
            plans: [
                plan("ready-old", status: .ready, updatedOffset: -300),
                plan("ready-with-session", status: .ready, updatedOffset: -60, executionSessionId: "session-existing"),
                plan("running-plan", status: .running, updatedOffset: -120),
                plan("queued-execution", status: .ready, updatedOffset: -90, executionStatus: .queued),
                plan("completed-hidden", status: .completed, updatedOffset: 120),
                plan("superseded-hidden", status: .superseded, updatedOffset: 110),
                plan("execution-completed-hidden", status: .ready, updatedOffset: 100, executionStatus: .completed),
            ],
            cronJobs: [
                cron("scheduled-cron", status: .scheduled, recurring: false, createdOffset: -600),
                cron("completed-one-shot-hidden", status: .completed, recurring: false, latestActivityOffset: -5),
                cron("completed-recurring", status: .completed, recurring: true, latestActivityOffset: -10),
                cron("manual-session-cron", status: .scheduled, recurring: false, durable: false, manualOnly: true, firedOffset: -20),
            ]
        )

        XCTAssertEqual(rows.map(\.id), [
            "cron:completed-recurring",
            "cron:manual-session-cron",
            "plan:ready-with-session",
            "plan:queued-execution",
            "plan:running-plan",
            "plan:ready-old",
            "cron:scheduled-cron",
        ])
        XCTAssertFalse(rows.contains { $0.id.contains("completed-hidden") })
        XCTAssertFalse(rows.contains { $0.id.contains("superseded-hidden") })
        XCTAssertEqual(rows.first?.completedAt, base.addingTimeInterval(-10))
        XCTAssertEqual(rows.first?.title, "completed-recurring")
        XCTAssertEqual(rows.first?.typeLabel, "persistent / recurring")

        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        XCTAssertTrue(byID["plan:ready-old"]?.canRun == true)
        XCTAssertFalse(byID["plan:ready-with-session"]?.canRun == true)
        XCTAssertFalse(byID["plan:running-plan"]?.canRun == true)
        XCTAssertFalse(byID["plan:running-plan"]?.canArchiveOrDelete == true)
        XCTAssertTrue(byID["plan:queued-execution"]?.canRun == true)
        XCTAssertFalse(byID["plan:queued-execution"]?.canArchiveOrDelete == true)
        XCTAssertTrue(byID["cron:manual-session-cron"]?.canRun == true)
        XCTAssertTrue(byID["cron:manual-session-cron"]?.canArchiveOrDelete == true)
        XCTAssertEqual(byID["cron:manual-session-cron"]?.typeLabel, "session-scope / one-shot / manual")
    }

    func testNativeAlwaysOnItemsRowsMatchWebTableColumnsDateLabelsAndCronViewAction() throws {
        let createdAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-05-23T10:00:00Z"))
        let triggeredAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-05-23T11:00:00Z"))
        let completedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-05-23T12:00:00Z"))
        let plan = AlwaysOnPlan(
            id: "plan-a",
            title: "Plan Alpha",
            summary: "",
            rationale: "",
            content: "",
            status: .ready,
            approvalMode: "manual",
            planFilePath: ".pilotdeck/always-on/plans/plan-a.md",
            contextRefs: nil,
            createdAt: createdAt,
            updatedAt: triggeredAt,
            executionSessionId: nil,
            executionStatus: nil
        )
        let cronJob = AlwaysOnCronJob(
            id: "cron-a",
            prompt: "# Cron Alpha",
            cron: "0 1 * * *",
            status: .scheduled,
            recurring: false,
            durable: true,
            createdAt: createdAt,
            lastFiredAt: triggeredAt,
            latestSessionId: "session-a",
            permanent: false,
            manualOnly: false,
            originSessionId: "origin-a",
            transcriptKey: "agent-a.jsonl",
            latestRun: AlwaysOnCronLatestRun(
                status: .completed,
                runId: "run-a",
                startedAt: triggeredAt,
                sessionId: "session-a",
                summary: "done",
                lastActivity: completedAt,
                taskId: "task-a",
                outputFile: ".pilotdeck/always-on/runs/run-a.log",
                parentSessionId: "origin-a",
                relativeTranscriptPath: "origin-a/subagents/agent-a.jsonl",
                transcriptKey: "agent-a.jsonl"
            )
        )

        XCTAssertEqual(NativeAlwaysOnItemsRows.columns(), ["Title", "Type", "Status", "Created", "Triggered", "Completed", ""])
        XCTAssertEqual(NativeAlwaysOnItemsRows.columns(language: .chineseSimplified), ["标题", "类型", "状态", "创建", "触发", "完成", ""])

        let planRow = NativeAlwaysOnItemsRows.row(NativeAlwaysOnRow(
            kind: .plan,
            id: "plan:plan-a",
            title: plan.title,
            typeLabel: "plan",
            statusLabel: plan.status.rawValue,
            createdAt: plan.createdAt,
            triggeredAt: nil,
            completedAt: nil,
            sortAt: plan.updatedAt,
            plan: plan,
            cronJob: nil
        ))
        XCTAssertEqual(planRow.title, "Plan Alpha")
        XCTAssertEqual(planRow.type, "plan")
        XCTAssertEqual(planRow.status, "ready")
        XCTAssertTrue(planRow.created.contains("05/23"))
        XCTAssertEqual(planRow.triggered, "—")
        XCTAssertEqual(planRow.completed, "—")
        XCTAssertTrue(planRow.canRun)
        XCTAssertTrue(planRow.canArchiveOrDelete)
        XCTAssertFalse(planRow.canOpenCronSession)

        let cronRow = NativeAlwaysOnItemsRows.row(NativeAlwaysOnRow(
            kind: .cron,
            id: "cron:cron-a",
            title: "Cron Alpha",
            typeLabel: "persistent / one-shot",
            statusLabel: cronJob.status.rawValue,
            createdAt: createdAt,
            triggeredAt: triggeredAt,
            completedAt: completedAt,
            sortAt: completedAt,
            plan: nil,
            cronJob: cronJob
        ))
        XCTAssertEqual(cronRow.title, "Cron Alpha")
        XCTAssertEqual(cronRow.type, "persistent / one-shot")
        XCTAssertEqual(cronRow.status, "scheduled")
        XCTAssertTrue(cronRow.triggered.contains("05/23"))
        XCTAssertTrue(cronRow.completed.contains("05/23"))
        XCTAssertTrue(cronRow.canRun)
        XCTAssertTrue(cronRow.canArchiveOrDelete)
        XCTAssertTrue(cronRow.canOpenCronSession)

        var cronWithoutTranscript = cronJob
        cronWithoutTranscript.latestRun = AlwaysOnCronLatestRun(
            status: .completed,
            runId: "run-b",
            startedAt: triggeredAt,
            sessionId: "session-a",
            summary: nil,
            lastActivity: completedAt,
            taskId: nil,
            outputFile: nil,
            parentSessionId: nil,
            relativeTranscriptPath: nil,
            transcriptKey: nil
        )
        XCTAssertFalse(NativeAlwaysOnItemsRows.canOpenCronSession(NativeAlwaysOnRow(
            kind: .cron,
            id: "cron:cron-b",
            title: "Cron Without Transcript",
            typeLabel: "persistent / one-shot",
            statusLabel: cronWithoutTranscript.status.rawValue,
            createdAt: createdAt,
            triggeredAt: triggeredAt,
            completedAt: completedAt,
            sortAt: completedAt,
            plan: nil,
            cronJob: cronWithoutTranscript
        )))
    }

    func testNativeAlwaysOnChromeCopyAndUpdatedLabelMatchesWeb() throws {
        let english = LocalizationService(language: .english)
        let chinese = LocalizationService(language: .chineseSimplified)

        XCTAssertEqual(english.text(.alwaysOn), "Always-on")
        XCTAssertEqual(english.text(.backgroundDiscoveryAgent), "Background discovery agent for this project.")
        XCTAssertEqual(english.text(.plansCronJobs), "Plans & Cron Jobs")
        XCTAssertEqual(english.text(.discover), "Discover")
        XCTAssertEqual(english.text(.alwaysOnProjectOnly), "Pick a project to view Always-on.")
        XCTAssertEqual(chinese.text(.alwaysOn), "常驻")
        XCTAssertEqual(chinese.text(.backgroundDiscoveryAgent), "为该项目持续运行的后台发现代理。")
        XCTAssertEqual(chinese.text(.plansCronJobs), "计划与定时任务")
        XCTAssertEqual(chinese.text(.discover), "扫描")
        XCTAssertEqual(chinese.text(.alwaysOnProjectOnly), "选择一个项目以查看常驻。")

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-05-23T12:00:00Z"))
        XCTAssertEqual(
            NativeAlwaysOnUpdatedLabel.updatedText(now.addingTimeInterval(-30), now: now),
            "Updated just now"
        )
        XCTAssertEqual(
            NativeAlwaysOnUpdatedLabel.updatedText(now.addingTimeInterval(-90), now: now),
            "Updated 2m ago"
        )
        XCTAssertEqual(
            NativeAlwaysOnUpdatedLabel.updatedText(now.addingTimeInterval(-90 * 60), language: .chineseSimplified, now: now),
            "更新于 2 小时前"
        )
        XCTAssertEqual(
            NativeAlwaysOnUpdatedLabel.updatedText(now.addingTimeInterval(-36 * 60 * 60), now: now),
            "Updated 2d ago"
        )
        XCTAssertEqual(NativeAlwaysOnUpdatedLabel.updatedText(nil, now: now), "Updated —")
    }

    func testNativeAlwaysOnPlanDetailPresentationMatchesWebSectionsAndContextRefs() throws {
        let createdAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-05-23T10:00:00Z"))
        let updatedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-05-23T12:00:00Z"))
        let plan = AlwaysOnPlan(
            id: "plan-a",
            title: "  ",
            summary: "Check router drift.",
            rationale: "Keep parity visible.",
            content: "# Plan",
            status: .ready,
            approvalMode: "manual",
            planFilePath: " .pilotdeck/always-on/plans/plan-a.md ",
            contextRefs: [
                "workingDirectory": ["/repo"],
                "memory": ["Router parity note"],
                "existingPlans": ["Ignored by the Web detail renderer"],
                "cronJobs": [],
                "recentChats": ["Session 1"],
            ],
            createdAt: createdAt,
            updatedAt: updatedAt,
            executionSessionId: nil,
            executionStatus: nil
        )

        XCTAssertEqual(NativeAlwaysOnPlanDetailPresentation.detailTitle(plan), "plan-a")
        XCTAssertEqual(NativeAlwaysOnPlanDetailPresentation.sectionTitle(.summary), "Summary")
        XCTAssertEqual(NativeAlwaysOnPlanDetailPresentation.sectionTitle(.planMarkdown, language: .chineseSimplified), "Plan Markdown")
        XCTAssertEqual(NativeAlwaysOnPlanDetailPresentation.sectionTitle(.contextRefs, language: .chineseSimplified), "上下文引用")
        XCTAssertEqual(
            NativeAlwaysOnPlanDetailPresentation.fileLocation(projectRoot: "/Users/tester/repo/", planFilePath: plan.planFilePath),
            "/Users/tester/repo/.pilotdeck/always-on/plans/plan-a.md"
        )
        XCTAssertEqual(
            NativeAlwaysOnPlanDetailPresentation.fileLocation(projectRoot: "/repo", planFilePath: "/tmp/plan.md"),
            "/tmp/plan.md"
        )
        XCTAssertEqual(NativeAlwaysOnPlanDetailPresentation.fileLocation(projectRoot: "", planFilePath: "  "), "—")

        let englishMeta = NativeAlwaysOnPlanDetailPresentation.metaItems(plan, projectRoot: "/Users/tester/repo")
        XCTAssertEqual(englishMeta[0].0, "File location")
        XCTAssertEqual(englishMeta[1].0, "Created")
        XCTAssertEqual(englishMeta[2].0, "Updated")
        XCTAssertTrue(englishMeta[1].1.contains("05/23"))

        let chineseGroups = NativeAlwaysOnPlanDetailPresentation.contextRefGroups(plan, language: .chineseSimplified)
        XCTAssertEqual(chineseGroups.map(\.key), ["workingDirectory", "memory", "recentChats"])
        XCTAssertEqual(chineseGroups.map(\.label), ["工作目录", "记忆", "近期对话"])
        XCTAssertEqual(chineseGroups[1].values, ["Router parity note"])
    }

    func testNativeAlwaysOnCronLabelsMatchWebDetailHelpers() {
        func cron(
            prompt: String,
            cronExpression: String = "0 1 * * *",
            recurring: Bool = false,
            durable: Bool = true,
            permanent: Bool = false,
            manualOnly: Bool = false
        ) -> AlwaysOnCronJob {
            AlwaysOnCronJob(
                id: "cron-a",
                prompt: prompt,
                cron: cronExpression,
                status: .scheduled,
                recurring: recurring,
                durable: durable,
                createdAt: nil,
                lastFiredAt: nil,
                latestSessionId: nil,
                permanent: permanent,
                manualOnly: manualOnly,
                originSessionId: nil,
                transcriptKey: nil,
                latestRun: nil
            )
        }

        let headingJob = cron(prompt: "# Nightly scan ###\nReview workspace")
        XCTAssertEqual(NativeAlwaysOnCronLabels.promptTitle(headingJob.prompt), "Nightly scan")
        XCTAssertEqual(NativeAlwaysOnCronLabels.rowTitle(headingJob), "Nightly scan")

        let nonHeadingJob = cron(prompt: "  ## Not H1\nBody  ")
        XCTAssertEqual(NativeAlwaysOnCronLabels.promptTitle(nonHeadingJob.prompt), "")
        XCTAssertEqual(NativeAlwaysOnCronLabels.rowTitle(nonHeadingJob), "## Not H1\nBody")

        XCTAssertEqual(NativeAlwaysOnCronLabels.rowTitle(cron(prompt: "", cronExpression: "*/15 * * * *")), "*/15 * * * *")

        let longTitle = String(repeating: "a", count: 80)
        XCTAssertEqual(
            NativeAlwaysOnCronLabels.rowTitle(cron(prompt: "# \(longTitle)")),
            "\(String(repeating: "a", count: 55))…"
        )

        let manualSessionJob = cron(prompt: "# Manual", recurring: false, durable: false, permanent: true, manualOnly: true)
        XCTAssertEqual(NativeAlwaysOnCronLabels.typeLabel(manualSessionJob), "session-scope / one-shot / manual")
        XCTAssertEqual(NativeAlwaysOnCronLabels.triggerLabel(manualSessionJob), "One-shot / Manual only / Permanent")
        XCTAssertEqual(NativeAlwaysOnCronLabels.scopeLabel(manualSessionJob), "Session-scope")
        XCTAssertEqual(NativeAlwaysOnCronLabels.triggerLabel(manualSessionJob, language: .chineseSimplified), "单次触发 / 仅手动 / 永久")
        XCTAssertEqual(NativeAlwaysOnCronLabels.scopeLabel(cron(prompt: "# Durable"), language: .chineseSimplified), "持久")
    }

    func testNativeAlwaysOnCronDetailPresentationMatchesWebFieldsAndSessionTarget() throws {
        let createdAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-05-23T10:00:00Z"))
        let firedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-05-23T11:00:00Z"))
        let job = AlwaysOnCronJob(
            id: "cron-a",
            prompt: "# Cron Alpha\nRun diagnostics",
            cron: "0 1 * * *",
            status: .scheduled,
            recurring: true,
            durable: false,
            createdAt: createdAt,
            lastFiredAt: firedAt,
            latestSessionId: "session-a",
            permanent: true,
            manualOnly: true,
            originSessionId: "origin-a",
            transcriptKey: "cron-key",
            latestRun: AlwaysOnCronLatestRun(
                status: .completed,
                runId: "run-a",
                startedAt: createdAt,
                sessionId: "session-a",
                summary: "Latest cron summary",
                lastActivity: firedAt,
                taskId: "task-a",
                outputFile: "runs/run-a.log",
                parentSessionId: "origin-a",
                relativeTranscriptPath: "origin-a/subagents/agent-a.jsonl",
                transcriptKey: "agent-a.jsonl"
            )
        )

        XCTAssertEqual(NativeAlwaysOnCronDetailPresentation.sectionTitle(.prompt), "Prompt")
        XCTAssertEqual(NativeAlwaysOnCronDetailPresentation.sectionTitle(.schedule, language: .chineseSimplified), "调度配置")
        XCTAssertEqual(NativeAlwaysOnCronDetailPresentation.promptText(AlwaysOnCronJob(
            id: "empty-cron",
            prompt: "",
            cron: "0 2 * * *",
            status: .scheduled,
            recurring: false,
            durable: true,
            createdAt: nil,
            lastFiredAt: nil,
            latestSessionId: nil,
            originSessionId: nil,
            transcriptKey: nil,
            latestRun: nil
        )), "")

        let schedule = NativeAlwaysOnCronDetailPresentation.scheduleItems(job)
        XCTAssertEqual(schedule.map(\.0), [
            "Cron expression",
            "Current status",
            "Trigger type",
            "Scope",
            "Created",
            "Last fired",
        ])
        XCTAssertEqual(schedule[0].1, "0 1 * * *")
        XCTAssertEqual(schedule[1].1, "scheduled")
        XCTAssertEqual(schedule[2].1, "Recurring / Manual only / Permanent")
        XCTAssertEqual(schedule[3].1, "Session-scope")
        XCTAssertTrue(schedule[4].1.contains("05/23"))
        XCTAssertTrue(schedule[5].1.contains("05/23"))

        let chineseSchedule = NativeAlwaysOnCronDetailPresentation.scheduleItems(job, language: .chineseSimplified)
        XCTAssertEqual(chineseSchedule.map(\.0), ["Cron 表达式", "当前状态", "触发类型", "持久性范围", "创建时间", "上次触发"])
        XCTAssertEqual(chineseSchedule[2].1, "重复触发 / 仅手动 / 永久")
        XCTAssertEqual(chineseSchedule[3].1, "会话范围")

        XCTAssertEqual(NativeAlwaysOnCronDetailPresentation.originSessionValue(job), "origin-a")
        XCTAssertEqual(NativeAlwaysOnCronDetailPresentation.latestRunSessionValue(job), "session-a")
        XCTAssertEqual(NativeAlwaysOnCronDetailPresentation.transcriptKeyValue(job), "cron-key")
        XCTAssertTrue(NativeAlwaysOnCronDetailPresentation.canOpenLatestRunSession(job))
        XCTAssertEqual(NativeAlwaysOnCronDetailPresentation.latestRunTargetSummary(job), "Latest cron summary")
        let target = try XCTUnwrap(NativeAlwaysOnCronDetailPresentation.latestRunTarget(job))
        XCTAssertEqual(target.kind, .background)
        XCTAssertEqual(target.sessionId, "session-a")
        XCTAssertEqual(target.parentSessionId, "origin-a")
        XCTAssertEqual(target.relativeTranscriptPath, "origin-a/subagents/agent-a.jsonl")
        XCTAssertEqual(target.title, "Latest cron summary")
        XCTAssertEqual(target.transcriptKey, "agent-a.jsonl")
        XCTAssertEqual(target.taskId, "task-a")
        XCTAssertEqual(target.taskStatus, "scheduled")
        XCTAssertEqual(target.outputFile, "runs/run-a.log")

        var noTargetJob = job
        noTargetJob.latestRun = AlwaysOnCronLatestRun(
            status: .completed,
            runId: "run-b",
            startedAt: createdAt,
            sessionId: "session-b",
            summary: "",
            lastActivity: firedAt,
            taskId: nil,
            outputFile: nil,
            parentSessionId: nil,
            relativeTranscriptPath: nil,
            transcriptKey: nil
        )
        XCTAssertTrue(NativeAlwaysOnCronDetailPresentation.canOpenLatestRunSession(noTargetJob))
        let originTarget = try XCTUnwrap(NativeAlwaysOnCronDetailPresentation.latestRunTarget(noTargetJob))
        XCTAssertEqual(originTarget.kind, .origin)
        XCTAssertEqual(originTarget.sessionId, "session-b")
        XCTAssertEqual(NativeAlwaysOnCronDetailPresentation.latestRunTargetSummary(noTargetJob), "# Cron Alpha\nRun diagnostics")
    }

    func testAlwaysOnBackgroundTranscriptLoaderMatchesWebReadOnlySessionAndMessages() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pilotdeck-bg-transcript-\(UUID().uuidString)", isDirectory: true)
        let projectName = "project-with-readonly-cron-count"
        let parentSessionId = "parent-session-readonly"
        let transcriptFileName = "agent-cron-readonly.jsonl"
        let transcriptPath = home
            .appendingPathComponent(".pilotdeck/projects/\(projectName)/\(parentSessionId)/subagents", isDirectory: true)
            .appendingPathComponent(transcriptFileName)
        try FileManager.default.createDirectory(at: transcriptPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        try """
        {"uuid":"cron-trigger","timestamp":"2026-04-19T10:00:00.000Z","type":"user","isMeta":true,"message":{"role":"user","content":"提醒用户：该站起来活动一下了！"}}
        {"uuid":"cron-system-error","timestamp":"2026-04-19T10:00:01.000Z","type":"system","subtype":"api_error","cause":{"code":"ConnectionRefused","path":"http://ccr.local/v1/messages?beta=true"}}
        {"uuid":"cron-synthetic-error","timestamp":"2026-04-19T10:00:02.000Z","type":"assistant","isApiErrorMessage":true,"message":{"role":"assistant","model":"<synthetic>","content":[{"type":"text","text":"API Error: Unable to connect to API (ConnectionRefused)"}]}}
        {"uuid":"cron-synthetic-empty","timestamp":"2026-04-19T10:00:03.000Z","type":"assistant","message":{"role":"assistant","model":"<synthetic>","content":[{"type":"text","text":"No response requested."}]}}
        {"uuid":"cron-assistant","timestamp":"2026-04-19T10:00:04.000Z","type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Checking the schedule."},{"type":"text","text":"Done."},{"type":"tool_use","id":"tool-1","name":"Read","input":{"file_path":"README.md"}},{"type":"tool_result","tool_use_id":"tool-1","content":"ok"}]}}
        {"uuid":"cron-normalized-tool","timestamp":"2026-04-19T10:00:05.000Z","type":"tool_use","toolId":"tool-2","toolName":"Shell","toolInput":{"command":"pwd"}}
        {"uuid":"cron-normalized-result","timestamp":"2026-04-19T10:00:06.000Z","type":"tool_result","toolCallId":"tool-2","output":"workspace"}
        """.write(to: transcriptPath, atomically: true, encoding: .utf8)

        let sessionId = AlwaysOnBackgroundTranscriptLoader.backgroundSessionID(
            parentSessionId: parentSessionId,
            transcriptFilename: transcriptFileName
        )
        let lastActivity = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-04-19T10:01:00Z"))
        let target = AlwaysOnSessionTarget.background(
            sessionId: sessionId,
            parentSessionId: parentSessionId,
            relativeTranscriptPath: "\(parentSessionId)/subagents/\(transcriptFileName)",
            title: "Cron summary",
            summary: "Cron summary",
            lastActivity: lastActivity,
            transcriptKey: transcriptFileName,
            taskId: "cron-task",
            taskStatus: "completed",
            outputFile: ".pilotdeck/always-on/runs/run-a.log"
        )

        let session = try XCTUnwrap(AlwaysOnBackgroundTranscriptLoader.makeSession(target: target, existing: nil, now: Date(timeIntervalSince1970: 0)))

        XCTAssertEqual(session.id, "background-parent-session-readonly-agent-cron-readonly")
        XCTAssertEqual(session.sessionKind, .backgroundTask)
        XCTAssertEqual(session.parentSessionId, parentSessionId)
        XCTAssertEqual(session.relativeTranscriptPath, "\(parentSessionId)/subagents/\(transcriptFileName)")
        XCTAssertEqual(session.transcriptKey, transcriptFileName)
        XCTAssertEqual(session.taskId, "cron-task")
        XCTAssertEqual(session.taskStatus, "completed")
        XCTAssertEqual(session.outputFile, ".pilotdeck/always-on/runs/run-a.log")
        XCTAssertEqual(session.isReadOnly, true)
        XCTAssertTrue(session.isBackgroundTaskSession)

        XCTAssertEqual(
            AlwaysOnBackgroundTranscriptLoader.transcriptURL(
                projectName: projectName,
                parentSessionId: parentSessionId,
                relativeTranscriptPath: "\(parentSessionId)/subagents/\(transcriptFileName)",
                home: home
            )?.path,
            transcriptPath.path
        )
        XCTAssertNil(AlwaysOnBackgroundTranscriptLoader.transcriptURL(
            projectName: projectName,
            parentSessionId: parentSessionId,
            relativeTranscriptPath: "../\(transcriptFileName)",
            home: home
        ))
        XCTAssertFalse(AlwaysOnBackgroundTranscriptLoader.isCronTranscriptFilename("agent-task.jsonl"))

        let messages = AlwaysOnBackgroundTranscriptLoader.messages(for: session, projectName: projectName, home: home)
        XCTAssertEqual(messages.count, 6)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[0].plainText, "提醒用户：该站起来活动一下了！")
        XCTAssertEqual(messages[1].role, .system)
        XCTAssertTrue(messages[1].plainText.contains("ConnectionRefused"))
        XCTAssertEqual(messages[2].role, .assistant)
        XCTAssertTrue(messages[2].plainText.contains("API Error"))
        XCTAssertEqual(messages[3].role, .assistant)
        XCTAssertTrue(messages[3].blocks.contains { if case .reasoning(let text) = $0 { return text == "Checking the schedule." }; return false })
        XCTAssertTrue(messages[3].plainText.contains("Done."))
        XCTAssertTrue(messages[3].blocks.contains { if case .toolCall(let call) = $0 { return call.name == "Read" && call.inputJSON.contains("README.md") }; return false })
        XCTAssertTrue(messages[3].blocks.contains { if case .toolResult(let result) = $0 { return result.toolCallId == "tool-1" && result.output == "ok" }; return false })
        XCTAssertTrue(messages[4].blocks.contains { if case .toolCall(let call) = $0 { return call.id == "tool-2" && call.name == "Shell" && call.inputJSON.contains("pwd") }; return false })
        XCTAssertTrue(messages[5].blocks.contains { if case .toolResult(let result) = $0 { return result.toolCallId == "tool-2" && result.output == "workspace" }; return false })
    }

    @MainActor
    func testAppStateOpenAlwaysOnBackgroundSessionCreatesReadOnlyFallbackAndBlocksSend() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pilotdeck-open-bg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let project = WorkspaceProject(
            id: UUID(),
            name: WorkspaceService.projectName(for: root.path),
            displayName: "Open BG",
            rootPath: root.path,
            sessions: [],
            codexSessions: [],
            cursorSessions: [],
            geminiSessions: [],
            createdAt: Date(),
            lastActivity: Date()
        )
        let state = makeTestAppState()
        state.projects = [project]
        state.selectedProjectID = project.id

        let target = AlwaysOnSessionTarget.background(
            sessionId: "background-parent-agent-cron",
            parentSessionId: "parent",
            relativeTranscriptPath: "parent/subagents/agent-cron.jsonl",
            title: "Cron fallback",
            summary: "Cron fallback",
            lastActivity: Date(timeIntervalSince1970: 10),
            transcriptKey: "agent-cron.jsonl",
            taskId: "task-a",
            taskStatus: "completed",
            outputFile: "runs/run-a.log"
        )

        state.openAlwaysOnSession(target)

        XCTAssertEqual(state.activeTab, .chat)
        XCTAssertEqual(state.selectedSessionID, "background-parent-agent-cron")
        XCTAssertEqual(state.selectedSession?.sessionKind, .backgroundTask)
        XCTAssertEqual(state.selectedSession?.isReadOnly, true)
        XCTAssertEqual(state.selectedSession?.title, "Cron fallback")
        XCTAssertEqual(state.projects.first?.sessions.first?.id, "background-parent-agent-cron")

        state.composerText = "Do not send"
        state.sendComposerMessage()
        XCTAssertEqual(state.messagesBySession["background-parent-agent-cron"] ?? [], [])
        XCTAssertEqual(state.composerText, "Do not send")
    }

    func testNativeAlwaysOnRunMetadataVisibilityMatchesWebHistoryDetail() {
        XCTAssertEqual(NativeAlwaysOnRunMetadata.hiddenKeys, [
            "source",
            "sourceId",
            "parentSessionId",
            "logUpdatedAt",
            "logSize",
            "logTruncated",
        ])

        let visible = NativeAlwaysOnRunMetadata.visibleEntries([
            "source": "manual",
            "sourceId": "plan-a",
            "parentSessionId": "parent-a",
            "logUpdatedAt": "2026-05-23T12:00:00Z",
            "logSize": "2048",
            "logTruncated": "true",
            "sessionId": "session-a",
            "originSessionId": "origin-a",
            "relativeTranscriptPath": "origin-a/subagents/agent-a.jsonl",
            "transcriptKey": "agent-a",
            "finishedAt": "2026-05-23T12:01:00Z",
            "status": "completed",
            "emptyValue": "",
        ])

        XCTAssertEqual(
            visible.map { "\($0.key)=\($0.value)" },
            [
                "emptyValue=—",
                "finishedAt=2026-05-23T12:01:00Z",
                "originSessionId=origin-a",
                "relativeTranscriptPath=origin-a/subagents/agent-a.jsonl",
                "sessionId=session-a",
                "status=completed",
                "transcriptKey=agent-a",
            ]
        )
    }

    func testNativeAlwaysOnRunHistoryDetailPresentationUsesWebVisibleMetadataOnly() throws {
        let run = AlwaysOnRunHistory(
            id: "run-a",
            title: "  ",
            kind: "cron",
            status: .running,
            startedAt: Date(timeIntervalSince1970: 0),
            sourceId: "cron-a",
            outputLog: "",
            sessionId: "session-a",
            parentSessionId: "parent-a",
            relativeTranscriptPath: "parent-a/subagents/agent-a.jsonl",
            finishedAt: nil,
            error: nil,
            metadata: [
                "source": "manual",
                "sourceId": "cron-a",
                "parentSessionId": "parent-a",
                "logUpdatedAt": "2026-05-23T12:00:00Z",
                "logSize": "2048",
                "logTruncated": "true",
                "runId": "run-a",
                "status": "running",
                "startedAt": "1970-01-01T00:00:00Z",
                "sessionId": "session-a",
                "originSessionId": "origin-a",
                "relativeTranscriptPath": "parent-a/subagents/agent-a.jsonl",
                "transcriptKey": "agent-a.jsonl",
                "logSource": "log-file",
            ],
            transcriptKey: "agent-a.jsonl"
        )

        XCTAssertEqual(NativeAlwaysOnRunHistoryDetailPresentation.title(run), "Run detail")
        XCTAssertEqual(NativeAlwaysOnRunHistoryDetailPresentation.title(run, language: .chineseSimplified), "运行详情")
        XCTAssertEqual(NativeAlwaysOnRunHistoryDetailPresentation.logSource(run), "log-file")
        XCTAssertEqual(NativeAlwaysOnRunHistoryDetailPresentation.logUpdatedAt(run), "2026-05-23T12:00:00Z")
        XCTAssertTrue(NativeAlwaysOnRunHistoryDetailPresentation.isLogTruncated(run))
        XCTAssertEqual(
            NativeAlwaysOnRunHistoryDetailPresentation.outputLog(run, emptyText: "No output log was captured for this run."),
            "No output log was captured for this run."
        )

        let metadataKeys = Set(NativeAlwaysOnRunHistoryDetailPresentation.metadataEntries(run).map(\.key))

        XCTAssertFalse(metadataKeys.contains("source"))
        XCTAssertFalse(metadataKeys.contains("sourceId"))
        XCTAssertFalse(metadataKeys.contains("parentSessionId"))
        XCTAssertFalse(metadataKeys.contains("logUpdatedAt"))
        XCTAssertFalse(metadataKeys.contains("logSize"))
        XCTAssertFalse(metadataKeys.contains("logTruncated"))
        XCTAssertTrue(metadataKeys.contains("runId"))
        XCTAssertTrue(metadataKeys.contains("status"))
        XCTAssertTrue(metadataKeys.contains("startedAt"))
        XCTAssertTrue(metadataKeys.contains("sessionId"))
        XCTAssertTrue(metadataKeys.contains("originSessionId"))
        XCTAssertTrue(metadataKeys.contains("relativeTranscriptPath"))
        XCTAssertTrue(metadataKeys.contains("transcriptKey"))
        XCTAssertTrue(metadataKeys.contains("logSource"))

        let target = try XCTUnwrap(NativeAlwaysOnRunHistoryDetailPresentation.sessionTarget(run))
        XCTAssertEqual(target.kind, .background)
        XCTAssertEqual(target.sessionId, "session-a")
        XCTAssertEqual(target.parentSessionId, "parent-a")
        XCTAssertEqual(target.relativeTranscriptPath, "parent-a/subagents/agent-a.jsonl")
        XCTAssertEqual(target.title, "  ")
        XCTAssertEqual(target.taskId, "cron-a")
        XCTAssertEqual(target.taskStatus, "running")
        XCTAssertEqual(target.transcriptKey, "agent-a.jsonl")
    }

    func testNativeAlwaysOnRunHistoryRowsMatchWebTableColumnsAndSessionLabel() throws {
        let startedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-05-23T12:00:00Z"))
        let run = AlwaysOnRunHistory(
            id: "run-a",
            title: "Plan Alpha",
            kind: "plan",
            status: .completed,
            startedAt: startedAt,
            sourceId: "plan-alpha",
            outputLog: "",
            sessionId: "session-a",
            parentSessionId: nil,
            relativeTranscriptPath: nil
        )
        let transcriptOnlyRun = AlwaysOnRunHistory(
            id: "run-b",
            title: "Cron Beta",
            kind: "cron",
            status: .failed,
            startedAt: startedAt,
            sourceId: "cron-beta",
            outputLog: "",
            sessionId: nil,
            parentSessionId: "origin-a",
            relativeTranscriptPath: "origin-a/subagents/agent-cron.jsonl"
        )
        let noSessionRun = AlwaysOnRunHistory(
            id: "run-c",
            title: "  ",
            kind: "plan",
            status: .queued,
            startedAt: startedAt,
            sourceId: "plan-empty",
            outputLog: "",
            sessionId: nil,
            parentSessionId: nil,
            relativeTranscriptPath: nil
        )
        let hiddenRun = AlwaysOnRunHistory(
            id: "run-hidden",
            title: "Hidden",
            kind: "plan",
            status: .unknown,
            startedAt: startedAt,
            sourceId: "hidden",
            outputLog: "",
            sessionId: nil,
            parentSessionId: nil,
            relativeTranscriptPath: nil
        )

        XCTAssertEqual(NativeAlwaysOnRunHistoryRows.columns(), ["Title", "Kind", "Status", "Started", "Source", "Session"])
        XCTAssertEqual(NativeAlwaysOnRunHistoryRows.columns(language: .chineseSimplified), ["标题", "类型", "状态", "开始时间", "来源", "会话"])
        XCTAssertTrue(NativeAlwaysOnRunHistoryRows.isVisible(run))
        XCTAssertFalse(NativeAlwaysOnRunHistoryRows.isVisible(hiddenRun))

        let row = NativeAlwaysOnRunHistoryRows.row(run)
        XCTAssertEqual(row.title, "Plan Alpha")
        XCTAssertEqual(row.kind, "plan")
        XCTAssertEqual(row.status, "completed")
        XCTAssertEqual(row.source, "plan-alpha")
        XCTAssertEqual(row.session, "Available")
        XCTAssertTrue(row.started.contains("05/23"))

        XCTAssertEqual(NativeAlwaysOnRunHistoryRows.row(transcriptOnlyRun, language: .chineseSimplified).session, "可用")
        XCTAssertEqual(NativeAlwaysOnRunHistoryRows.row(noSessionRun).title, "—")
        XCTAssertEqual(NativeAlwaysOnRunHistoryRows.row(noSessionRun).session, "—")
    }

    func testAlwaysOnDiscoveryPromptMatchesWebStructuredContextShape() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pilotdeck-alwayson-discovery-prompt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "Project README".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = ISO8601DateFormatter().date(from: "2026-05-23T10:00:00Z")!
        let service = AlwaysOnService()
        let context = service.discoveryContext(
            projectName: "pilotdeck-opc",
            displayName: "PilotDeck OPC",
            projectRoot: root.path,
            plans: [
                AlwaysOnPlan(
                    id: "plan-a",
                    title: "Review router drift",
                    summary: "Check whether router config drifted.",
                    rationale: "Keep parity visible.",
                    content: "",
                    status: .ready,
                    approvalMode: "manual",
                    planFilePath: ".pilotdeck/always-on/plans/plan-a.md",
                    contextRefs: nil,
                    createdAt: now.addingTimeInterval(-120),
                    updatedAt: now.addingTimeInterval(-60),
                    executionSessionId: nil,
                    executionStatus: nil
                )
            ],
            cronJobs: [
                AlwaysOnCronJob(
                    id: "cron-a",
                    prompt: "# Nightly scan\nReview issues",
                    cron: "0 1 * * *",
                    status: .scheduled,
                    recurring: true,
                    durable: true,
                    createdAt: now.addingTimeInterval(-600),
                    lastFiredAt: nil,
                    latestSessionId: nil,
                    permanent: false,
                    manualOnly: true,
                    originSessionId: "origin-a",
                    transcriptKey: "cron-a",
                    latestRun: AlwaysOnCronLatestRun(
                        status: .completed,
                        runId: "run-a",
                        startedAt: now.addingTimeInterval(-300),
                        sessionId: "session-a",
                        summary: "Finished scan",
                        lastActivity: now.addingTimeInterval(-240),
                        taskId: "cron-a",
                        outputFile: ".pilotdeck/always-on/runs/run-a.log",
                        parentSessionId: "parent-a",
                        relativeTranscriptPath: "parent-a/subagents/agent-cron-a.jsonl",
                        transcriptKey: "agent-cron-a.jsonl"
                    )
                )
            ],
            sessions: [
                ProjectSession(
                    id: "chat-1",
                    provider: .pilotDeck,
                    title: "中文规划",
                    summary: "用户要求用中文整理 Always-On 计划。",
                    createdAt: now.addingTimeInterval(-180),
                    updatedAt: nil,
                    lastActivity: now.addingTimeInterval(-90),
                    state: .idle
                )
            ],
            memoryRecords: [
                MemoryRecord(
                    id: UUID(),
                    name: "Router",
                    summary: "Router parity details.",
                    projectName: "pilotdeck-opc",
                    updatedAt: now.addingTimeInterval(-30),
                    type: .project,
                    relativePath: "Project/router.md",
                    deprecated: false,
                    content: "Router parity details."
                )
            ],
            now: now
        )
        let english = service.discoveryPrompt(
            projectName: "pilotdeck-opc",
            displayName: "PilotDeck OPC",
            projectRoot: root.path,
            context: context,
            language: "en"
        )
        let chinese = service.discoveryPrompt(
            projectName: "pilotdeck-opc",
            displayName: "PilotDeck OPC",
            projectRoot: root.path,
            context: context,
            language: "zh-CN"
        )

        XCTAssertEqual(context.generatedAt, "2026-05-23T10:00:00Z")
        XCTAssertEqual(context.lookbackDays, 7)
        XCTAssertTrue(context.workspace.signals.contains("README.md present"))
        XCTAssertEqual(context.memory.first?.path, "Project/router.md")
        XCTAssertEqual(context.existingPlans.first?.id, "plan-a")
        XCTAssertEqual(context.cronJobs.first?.latestRunSummary, "Finished scan")
        XCTAssertEqual(context.recentChats.first?.id, "chat-1")

        XCTAssertTrue(english.contains("Always-On discovery planning for project \"PilotDeck OPC\"."))
        XCTAssertTrue(english.contains("Use the project store at `~/.pilotdeck/projects/pilotdeck-opc`"))
        XCTAssertTrue(english.contains("Every saved plan must include these markdown sections exactly:"))
        XCTAssertTrue(english.contains("Do not call `CronCreate`"))
        XCTAssertTrue(english.contains("\"recentChats\""))
        XCTAssertTrue(english.contains("\"cronJobs\""))
        XCTAssertTrue(english.contains("## Approval And Execution"))
        XCTAssertFalse(english.contains(".pilotdeck/always-on"))

        XCTAssertTrue(chinese.contains("Always-On 主动发现规划"))
        XCTAssertTrue(chinese.contains("近期聊天语言为准"))
        XCTAssertTrue(chinese.contains("结构化 discovery context"))
    }

    func testAlwaysOnDiscoveryRequestDedupeMatchesWebPolicy() {
        var store = AlwaysOnDiscoveryRequestDedupeStore()

        XCTAssertTrue(store.shouldProcess("request-1"))
        XCTAssertFalse(store.shouldProcess("request-1"))
        XCTAssertFalse(store.shouldProcess(" request-1 "))
        XCTAssertFalse(store.shouldProcess(nil))
        XCTAssertFalse(store.shouldProcess(""))
        XCTAssertFalse(store.shouldProcess("   "))

        XCTAssertTrue(store.shouldProcess("request-2", maxSize: 2))
        XCTAssertTrue(store.shouldProcess("request-3", maxSize: 2))
        XCTAssertTrue(store.shouldProcess("request-1", maxSize: 2))
        XCTAssertTrue(store.shouldProcess("request-2", maxSize: 2))
        XCTAssertTrue(store.shouldProcess("request-3", maxSize: 2))
    }

    func testAlwaysOnServiceRunLogReadsTailMetadataLikeWeb() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pilotdeck-alwayson-run-log-\(UUID().uuidString)", isDirectory: true)
        let runsRoot = root.appendingPathComponent(".pilotdeck/always-on/runs", isDirectory: true)
        try FileManager.default.createDirectory(at: runsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "first line\nsecond line\n".write(
            to: runsRoot.appendingPathComponent("run-1.log"),
            atomically: true,
            encoding: .utf8
        )

        let log = AlwaysOnService().runLog(projectRoot: root.path, runID: "run/1", tailBytes: 12)

        XCTAssertEqual(log.runId, "run/1")
        XCTAssertEqual(log.content, "second line\n")
        XCTAssertEqual(log.truncated, true)
        XCTAssertEqual(log.size, 23)
        XCTAssertEqual(log.source, .logFile)
        XCTAssertNotNil(log.updatedAt)
    }

    func testAlwaysOnServiceRunLogReturnsHistorySourceWhenFileIsMissing() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pilotdeck-alwayson-run-log-missing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let log = AlwaysOnService().runLog(projectRoot: root.path, runID: "missing-run")

        XCTAssertEqual(log.runId, "missing-run")
        XCTAssertEqual(log.content, "")
        XCTAssertEqual(log.truncated, false)
        XCTAssertEqual(log.updatedAt, nil)
        XCTAssertEqual(log.size, 0)
        XCTAssertEqual(log.source, .history)
    }

    func testMarkdownParserHandlesTablesCodeAndTaskLists() {
        let blocks = NativeMarkdownParser.parse("""
        ### 视觉优化

        | 改进项 | 说明 |
        |---|---|
        | **动画** | 已加入 |

        - [x] 完成布局
        - [ ] 验证

        ```html
        <main>Hello</main>
        ```
        """)

        XCTAssertTrue(blocks.contains { block in
            if case .heading(let level, let title) = block {
                return level == 3 && title == "视觉优化"
            }
            return false
        })
        XCTAssertTrue(blocks.contains { block in
            if case .table(let header, let rows) = block {
                return header == ["改进项", "说明"] && rows.count == 1
            }
            return false
        })
        XCTAssertTrue(blocks.contains { block in
            if case .list(_, let items) = block {
                return items.map(\.checked) == [true, false]
            }
            return false
        })
        XCTAssertTrue(blocks.contains { block in
            if case .code(let language, let value) = block {
                return language == "html" && value.contains("<main>")
            }
            return false
        })
    }

    func testFileWorkspaceLayoutMetricsDoNotDependOnChatSplit() {
        XCTAssertEqual(FileWorkspaceLayoutMetrics.browserDefaultWidth, 330)
        XCTAssertGreaterThanOrEqual(FileWorkspaceLayoutMetrics.browserDefaultWidth, FileWorkspaceLayoutMetrics.browserMinWidth)
        XCTAssertLessThanOrEqual(FileWorkspaceLayoutMetrics.browserDefaultWidth, FileWorkspaceLayoutMetrics.browserMaxWidth)
        XCTAssertEqual(FileWorkspaceLayoutMetrics.treeRowHeight, 28)
    }

    func testCodeMinimapSnapshotSamplesLargeFilesAndViewportModelIsCheap() {
        let text = (1...2_000).map { "line \($0) let value = \($0)" }.joined(separator: "\n")
        let snapshot = CodeMinimapSnapshot(text: text, maxLines: 500)
        let model = CodeMinimapModel(snapshot: snapshot, visibleLineRange: 100..<180)

        XCTAssertEqual(snapshot.totalLines, 2_000)
        XCTAssertLessThanOrEqual(snapshot.lines.count, 500)
        XCTAssertGreaterThan(snapshot.sampleStride, 1)
        XCTAssertEqual(model.totalLines, snapshot.totalLines)
        XCTAssertGreaterThan(model.viewportStartFraction, 0)
        XCTAssertGreaterThanOrEqual(CodeLineNumberMetrics.rulerWidth(lineCount: 1), 48)
    }

    func testYAMLScalarEditorUpdatesNestedScalarsWithoutReordering() {
        let yaml = """
        runtime:
          host: 0.0.0.0
          serverPort: 3001
        router:
          enabled: true
        """

        let updated = YAMLScalarEditor.set(path: "runtime.serverPort", value: "3002", in: yaml)

        XCTAssertTrue(updated.contains("runtime:"))
        XCTAssertTrue(updated.contains("  serverPort: 3002"))
        XCTAssertTrue(updated.contains("router:"))
    }

    func testYAMLScalarEditorRemovesWholeModelProviderSubtree() {
        let yaml = """
        model:
          providers:
            provider1:
              protocol: openai
              url: http://example.local/v1
              apiKey: secret
              models:
                qwen3: {}
            provider10:
              protocol: openai
              url: http://other.local/v1
        model.providers.provider1.url: http://stale.local/v1
        agent:
          model: provider10/qwen3
        """

        let updated = YAMLScalarEditor.removeObject(
            components: ["model", "providers", "provider1"],
            in: yaml
        )

        XCTAssertFalse(updated.contains("provider1:"))
        XCTAssertFalse(updated.contains("model.providers.provider1"))
        XCTAssertFalse(updated.contains("http://example.local/v1"))
        XCTAssertFalse(updated.contains("http://stale.local/v1"))
        XCTAssertTrue(updated.contains("provider10"))
        XCTAssertTrue(updated.contains("http://other.local/v1"))
    }

    func testAlwaysOnProjectConfigPatchMatchesWebTopLevelShape() {
        let enabled = AlwaysOnProjectConfig.setEnabled(in: "", projectRoot: "/workspace/a/", enabled: true)
        let enabledValues = NativeConfigService.scalarMap(from: enabled)

        XCTAssertEqual(AlwaysOnProjectConfig.projectRoot("/workspace/a/"), "/workspace/a")
        XCTAssertEqual(enabledValues["alwaysOn.projects./workspace/a.enabled"], "true")
        XCTAssertTrue(AlwaysOnProjectConfig.isEnabled(yaml: enabled, projectRoot: "/workspace/a/"))

        let disabled = AlwaysOnProjectConfig.setEnabled(in: enabled, projectRoot: "/workspace/a/", enabled: false)
        let disabledValues = NativeConfigService.scalarMap(from: disabled)

        XCTAssertEqual(disabledValues["alwaysOn.projects./workspace/a.enabled"], "false")
        XCTAssertFalse(AlwaysOnProjectConfig.isEnabled(yaml: disabled, projectRoot: "/workspace/a/"))
    }

    func testYAMLScalarEditorSetsObjectScalarForDottedProjectRootKeys() {
        let yaml = """
        alwaysOn:
          projects:
            /Users/tester/workspace/app.one:
              enabled: true
              mode: manual
        """

        let updated = YAMLScalarEditor.setObjectScalar(
            parentPath: "alwaysOn.projects",
            id: "/Users/tester/workspace/app.one",
            key: "enabled",
            value: "false",
            in: yaml
        )
        let values = NativeConfigService.scalarMap(from: updated)

        XCTAssertEqual(values["alwaysOn.projects./Users/tester/workspace/app.one.enabled"], "false")
        XCTAssertEqual(values["alwaysOn.projects./Users/tester/workspace/app.one.mode"], "manual")
        XCTAssertFalse(updated.contains("app:\n"))
    }

    func testConfigYAMLAPIKeyResolutionUsesOnlyYAML() {
        let yamlWithKey = """
        models:
          providers:
            pilotdeck:
              type: openai-chat
              baseUrl: http://example.local/v1
              apiKey: yaml-secret
          entries:
            default:
              provider: pilotdeck
              name: qwen3.6-27b
        """
        let snapshotWithKey = NativeConfigService.snapshot(from: yamlWithKey)

        let resolvedYAMLKey = NativeConfigService.resolvedAPIKey(
            routeEntryID: "default",
            nativeConfig: snapshotWithKey
        )

        XCTAssertEqual(resolvedYAMLKey, "yaml-secret")

        let yamlBlankKey = """
        models:
          providers:
            pilotdeck:
              type: openai-chat
              baseUrl: http://example.local/v1
              apiKey: ""
          entries:
            default:
              provider: pilotdeck
              name: qwen3.6-27b
        """
        let snapshotBlankKey = NativeConfigService.snapshot(from: yamlBlankKey)

        let resolvedBlankKey = NativeConfigService.resolvedAPIKey(
            routeEntryID: "default",
            nativeConfig: snapshotBlankKey
        )

        XCTAssertEqual(resolvedBlankKey, "")
    }

    func testSkillsSlugValidationRejectsTraversal() {
        XCTAssertTrue(SkillsService.isSafeSlug("review-helper"))
        XCTAssertTrue(SkillsService.isSafeSlug("team.skill_1"))
        XCTAssertFalse(SkillsService.isSafeSlug("../escape"))
        XCTAssertFalse(SkillsService.isSafeSlug("nested/path"))
        XCTAssertFalse(SkillsService.isSafeSlug(".."))
    }

    func testSkillHubArchivePathValidationRejectsEscapes() {
        XCTAssertTrue(SkillsService.isSafeArchiveEntry("SKILL.md"))
        XCTAssertTrue(SkillsService.isSafeArchiveEntry("references/api.md"))
        XCTAssertFalse(SkillsService.isSafeArchiveEntry("../SKILL.md"))
        XCTAssertFalse(SkillsService.isSafeArchiveEntry("/tmp/SKILL.md"))
        XCTAssertFalse(SkillsService.isSafeArchiveEntry("skill\\SKILL.md"))
        XCTAssertFalse(SkillsService.isSafeArchiveEntry("skill//SKILL.md"))
    }

    func testSkillValidationRequiresSkillMarkdownFrontmatter() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pilotdeck-skill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = SkillsService()
        var result = service.validate(source: root)
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.hardFails.contains { $0.code == "no_skill_md" })

        try """
        ---
        name: Reviewer
        description: Checks diffs for regressions before shipping changes.
        ---

        # Reviewer
        """.write(to: root.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        result = service.validate(source: root)
        XCTAssertTrue(result.ok)
        XCTAssertTrue(result.hardFails.isEmpty)
    }

    func testSkillValidationRejectsSymlinks() throws {
        let root = temporaryDirectory("pilotdeck-skill-symlink")
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        ---
        name: Symlink Check
        description: Validates that native skill imports reject symbolic links.
        ---

        # Symlink Check
        """.write(to: root.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let link = root.appendingPathComponent("outside-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/tmp"))

        let result = SkillsService().validate(source: root)
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.hardFails.contains { $0.code == "symlink_not_supported" })
    }

    func testNativeAgentPromptListsWorkspaceSkillsBeforeInvocation() throws {
        let projectRoot = temporaryDirectory("pilotdeck-project")
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let skillDir = try writeProjectSkill(
            projectRoot: projectRoot,
            slug: "sushiro",
            name: "sushiro",
            description: "查询寿司郎中国大陆门店实时排队和等位情况。"
        )

        let skills = SkillRuntimeService.availableSkills(workspacePath: projectRoot.path)
        let sushiro = try XCTUnwrap(skills.first { $0.name == "sushiro" })
        XCTAssertEqual(sushiro.scope, "project")
        XCTAssertEqual(sushiro.slug, "sushiro")

        let context = NativeAgentRuntime.nativeAgentSkillContext(workspacePath: projectRoot.path)
        XCTAssertTrue(context.contains("- sushiro (project): 查询寿司郎"))
        XCTAssertTrue(context.contains("call Skill with the exact skill name"))
        XCTAssertTrue(context.contains("skillDir"))

        let runContext = AgentRunContext(request: agentRequest(projectPath: projectRoot.path))
        let output = try SkillRuntimeService.load(
            inputJSON: #"{"skill":"sushiro","args":"北京寿司郎排队情况"}"#,
            context: runContext
        )
        let payload = try jsonObject(from: output)
        XCTAssertEqual(payload["skill"] as? String, "sushiro")
        XCTAssertEqual(payload["skillDir"] as? String, skillDir.path)
        XCTAssertTrue((payload["executionHint"] as? String)?.contains("skillDir") == true)
    }

    func testPostCompactionSkillContextRestoresInvokedSkillInstructions() throws {
        let projectRoot = temporaryDirectory("pilotdeck-skill-post-compact")
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let skillDir = try writeProjectSkill(
            projectRoot: projectRoot,
            slug: "planner",
            name: "planner",
            description: "Keeps planning conventions stable after context compaction."
        )
        let context = AgentRunContext(request: agentRequest(projectPath: projectRoot.path))
        _ = try SkillRuntimeService.load(inputJSON: #"{"skill":"planner"}"#, context: context)

        let refresh = try XCTUnwrap(SkillRuntimeService.postCompactSkillContext(context: context))

        XCTAssertTrue(refresh.contains("Post-compaction skill refresh"))
        XCTAssertTrue(refresh.contains("planner"))
        XCTAssertTrue(refresh.contains(skillDir.path))
        XCTAssertTrue(refresh.contains("The CLI is at `scripts/planner`"))
    }

    func testPostCompactionRuntimeContextRefreshesDynamicState() throws {
        let projectRoot = temporaryDirectory("pilotdeck-runtime-post-compact")
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        _ = try writeProjectSkill(
            projectRoot: projectRoot,
            slug: "planner",
            name: "planner",
            description: "Keeps planning conventions stable after context compaction."
        )
        let prior = ChatMessage(
            id: UUID(),
            sessionId: "test-session",
            provider: .pilotDeck,
            role: .assistant,
            blocks: [
                .toolCall(ToolCall(
                    id: "todo-post-compact",
                    name: "TodoWrite",
                    inputJSON: #"{"todos":[{"content":"carry the todo through compaction","status":"in_progress"}]}"#,
                    status: .completed
                )),
            ],
            createdAt: Date(),
            isStreaming: false
        )
        let context = AgentRunContext(request: agentRequest(projectPath: projectRoot.path, priorMessages: [prior]))
        _ = try SkillRuntimeService.load(inputJSON: #"{"skill":"planner"}"#, context: context)

        let messages = NativeAgentRuntime.appendPostCompactionRuntimeContext(
            to: [["role": "system", "content": "system"], ["role": "user", "content": "[Context compacted]"]],
            context: context
        )
        let serialized = String(describing: messages)

        XCTAssertTrue(serialized.contains("Runtime context for this session"))
        XCTAssertTrue(serialized.contains("Current Todo List from earlier work"))
        XCTAssertTrue(serialized.contains("carry the todo through compaction"))
        XCTAssertTrue(serialized.contains("Post-compaction skill refresh"))
        XCTAssertTrue(serialized.contains("planner"))
    }

    func testGeneralSkillContextExcludesProjectScopedSkills() throws {
        let projectRoot = temporaryDirectory("pilotdeck-general-skill-scope")
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        _ = try writeProjectSkill(
            projectRoot: projectRoot,
            slug: "project-only-\(UUID().uuidString.prefix(8))",
            name: "project-only-skill",
            description: "Project-only skill should not be visible from General chat."
        )

        let generalSkills = SkillRuntimeService.availableSkills(workspacePath: projectRoot.path, isGeneral: true)
        XCTAssertFalse(generalSkills.contains { $0.scope == "project" })

        let context = NativeAgentRuntime.nativeAgentSkillContext(workspacePath: projectRoot.path, isGeneral: true)
        XCTAssertTrue(context.contains("Available skills for this workspace"))
        XCTAssertFalse(context.contains("project-only-skill"))
    }

    func testProjectScopedSkillOverridesGlobalSkillWithSameName() throws {
        let projectRoot = temporaryDirectory("pilotdeck-skill-priority")
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let slug = "priority-\(UUID().uuidString.prefix(8)).skill"
        let userSkillDir = try writeUserSkill(
            slug: slug,
            name: "priority-skill",
            description: "Global version should lose to the project version."
        )
        defer { try? FileManager.default.removeItem(at: userSkillDir) }
        let projectSkillDir = try writeProjectSkill(
            projectRoot: projectRoot,
            slug: slug,
            name: "priority-skill",
            description: "Project version should be loaded before the global version."
        )

        let skills = SkillRuntimeService.availableSkills(workspacePath: projectRoot.path)
        let listed = try XCTUnwrap(skills.first { $0.name == "priority-skill" })
        XCTAssertEqual(listed.scope, "project")

        let request = agentRequest(projectPath: projectRoot.path)
        let context = AgentRunContext(request: request)
        let output = try SkillRuntimeService.load(
            inputJSON: #"{"skill":"priority-skill","args":"demo"}"#,
            context: context
        )
        let payload = try jsonObject(from: output)
        XCTAssertEqual(
            URL(fileURLWithPath: payload["skillDir"] as? String ?? "").standardizedFileURL.path,
            projectSkillDir.standardizedFileURL.path
        )
    }

    func testSkillsServiceCanCopyAndMoveBetweenScopes() throws {
        let projectRoot = temporaryDirectory("pilotdeck-skill-transfer")
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let service = SkillsService()
        let userSkillDir = try writeUserSkill(
            slug: "transfer-\(UUID().uuidString.prefix(8))",
            name: "transfer-skill",
            description: "Skill used to verify native copy and move between scopes."
        )
        defer { try? FileManager.default.removeItem(at: userSkillDir) }
        let userSkill = try XCTUnwrap(serviceRecord(for: userSkillDir, scope: .user))

        let copied = try service.copySkill(userSkill, to: .project, projectPath: projectRoot.path, overwrite: false)
        XCTAssertEqual(copied.scope, .project)
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent(".pilotdeck/skills/\(userSkill.slug)/SKILL.md").path))

        let moved = try service.moveSkill(copied, to: .user, projectPath: nil, overwrite: true)
        XCTAssertEqual(moved.scope, .user)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copied.skillDir))
    }

    func testNativeClawHubInstallImportsDownloadedArchive() async throws {
        let projectRoot = temporaryDirectory("pilotdeck-project")
        let archive = try makeSkillArchive(name: "Demo Skill", description: "Installs from a mocked native ClawHub archive.")
        defer { try? FileManager.default.removeItem(at: projectRoot) }

        let client = MockSkillHubClient(
            detail: SkillHubSkillDetail(
                slug: "demo-skill",
                displayName: "Demo Skill",
                latestVersion: "1.0.0",
                isSuspicious: false,
                isMalwareBlocked: false,
                moderationSummary: nil
            ),
            archive: SkillHubArchive(data: archive, filename: "demo-skill-1.0.0.zip")
        )
        let service = SkillsService(skillHubClient: client)

        let result = try await service.clawHubInstall(
            slug: "demo-skill",
            scope: .project,
            projectPath: projectRoot.path
        )

        XCTAssertTrue(result.ok)
        XCTAssertTrue(result.installed)
        XCTAssertEqual(result.skill?.slug, "demo-skill")
        XCTAssertEqual(client.downloadRequests, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectRoot.appendingPathComponent(".pilotdeck/skills/demo-skill/SKILL.md").path))
    }

    func testNativeClawHubInstallRequiresForceForSuspiciousSkills() async throws {
        let projectRoot = temporaryDirectory("pilotdeck-project")
        defer { try? FileManager.default.removeItem(at: projectRoot) }
        let client = MockSkillHubClient(
            detail: SkillHubSkillDetail(
                slug: "risky-skill",
                displayName: "Risky Skill",
                latestVersion: "1.0.0",
                isSuspicious: true,
                isMalwareBlocked: false,
                moderationSummary: "Manual confirmation required."
            ),
            archive: SkillHubArchive(data: Data(), filename: "risky-skill.zip")
        )
        let service = SkillsService(skillHubClient: client)

        let result = try await service.clawHubInstall(
            slug: "risky-skill",
            scope: .project,
            projectPath: projectRoot.path
        )

        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.needsForce)
        XCTAssertEqual(result.stderr, "Manual confirmation required.")
        XCTAssertEqual(client.downloadRequests, 0)
    }

    func testNativeTurnControllerRecordsOrderedTimelineItems() async {
        let controller = NativeTurnController(
            sessionId: "session-a",
            workspacePath: "/Users/tester/project",
            mode: .plan
        )

        let user = await controller.recordUserMessage("Optimize the page")
        let tool = await controller.recordToolCall(
            AgentToolCall(id: "call-1", name: "Grep", inputJSON: #"{"pattern":"index"}"#)
        )
        let recorded = await controller.recordToolResult(
            AgentToolResult(callId: "call-1", toolName: "Grep", output: "index.html", isError: false)
        )
        await controller.markPlanExited()
        await controller.finish()

        let snapshot = await controller.snapshot()
        XCTAssertEqual(snapshot.status, .completed)
        XCTAssertEqual(snapshot.mode, .agent)
        XCTAssertEqual(snapshot.items.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(user.kind, .userMessage)
        XCTAssertEqual(tool.kind, .webSearch)
        XCTAssertEqual(recorded.callItem?.status, .completed)
        XCTAssertEqual(recorded.resultItem.kind, .toolResult)
    }

    func testNativeThreadManagerInterruptsActiveTurn() async {
        let manager = NativeThreadManager()
        let request = agentRequest(prompt: "Build a page")
        let session = await manager.session(for: request)
        let turn = await session.startTurn(request: request)
        _ = await turn.recordStatus("thinking")

        await manager.interrupt(sessionId: request.sessionId)

        let snapshot = await session.snapshot()
        XCTAssertEqual(snapshot.turns.last?.status, .interrupted)
        XCTAssertTrue(snapshot.turns.last?.items.contains { $0.status == .interrupted } == true)
    }

    func testNativeToolRouterUsesSharedToolRegistryAndPlanPolicy() {
        let tools = NativeToolRouter.openAITools()
        let names = tools.compactMap { tool -> String? in
            guard let function = tool["function"] as? [String: Any] else { return nil }
            return function["name"] as? String
        }
        XCTAssertTrue(names.contains("Read"))
        XCTAssertTrue(names.contains("Write"))

        let context = AgentRunContext(request: agentRequest(runMode: .plan))
        let editCall = AgentToolCall(id: "call-edit", name: "StrReplace", inputJSON: "{}")
        if case .block(let reason) = NativeToolRouter.permissionPolicy(for: editCall, context: context) {
            XCTAssertTrue(reason.contains("Plan mode skipped"))
        } else {
            XCTFail("Plan mode must soft-block mutating tools before SwitchMode.")
        }
    }

    func testPlanSwitchModeRequiresConfirmationEvenWithBypassAndAllowedTool() {
        var toolSettings = ToolPermissionSettings.defaults
        toolSettings.allowedTools = ["SwitchMode"]
        let context = AgentRunContext(request: agentRequest(
            runMode: .plan,
            permissionMode: .bypassPermissions,
            toolSettings: toolSettings
        ))
        context.planQuestionAnswered = true
        let call = AgentToolCall(
            id: "switch-plan",
            name: "SwitchMode",
            inputJSON: #"{"mode":"agent","plan":"Do the work."}"#
        )

        if case .ask(let reason) = NativeToolRouter.permissionPolicy(for: call, context: context) {
            XCTAssertTrue(reason.lowercased().contains("plan approval"))
        } else {
            XCTFail("SwitchMode must still ask in Plan mode.")
        }
    }

    func testAgentModeSwitchModeStillShowsPlanConfirmation() {
        let context = AgentRunContext(request: agentRequest(runMode: .agent, permissionMode: .bypassPermissions))
        let call = AgentToolCall(
            id: "switch-agent-plan",
            name: "SwitchMode",
            inputJSON: #"{"mode":"agent","plan":"Implement the change."}"#
        )

        if case .ask(let reason) = NativeToolRouter.permissionPolicy(for: call, context: context) {
            XCTAssertTrue(reason.lowercased().contains("plan approval"))
        } else {
            XCTFail("Agent-mode SwitchMode must still render the plan confirmation card.")
        }
    }

    func testInteractiveSwitchModeDefersVisiblePlanIntoConfirmationInput() throws {
        let assistantPlan = """
        ## 实施计划
        1. 检查现有天气页面结构。
        2. 优化搜索、定位和缓存逻辑。
        3. 运行验证并总结结果。
        """
        let call = AgentToolCall(id: "switch", name: "SwitchMode", inputJSON: #"{"mode":"agent"}"#)

        let result = InteractivePlanContentDeferrer.prepare(
            assistantContent: assistantPlan,
            toolCalls: [call]
        )

        XCTAssertTrue(result.suppressVisibleAssistantText)
        XCTAssertNil(result.visibleIntro)
        XCTAssertEqual(result.planMarkdown, assistantPlan)
        let data = try XCTUnwrap(result.toolCalls.first?.inputJSON.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["mode"] as? String, "agent")
        XCTAssertEqual(object["plan"] as? String, assistantPlan)
        XCTAssertEqual(object["assistantPlanMarkdown"] as? String, assistantPlan)
    }

    func testInteractiveSwitchModeKeepsShortIntroAndMovesPlanToConfirmationInput() throws {
        let assistantText = """
        好的，我先整理现有代码结构，然后给出可执行计划。

        ## 整理计划
        1. 统一文件命名和注释。
        2. 清理重复样式。
        """
        let call = AgentToolCall(id: "switch", name: "SwitchMode", inputJSON: #"{"mode":"agent"}"#)

        let result = InteractivePlanContentDeferrer.prepare(
            assistantContent: assistantText,
            toolCalls: [call]
        )

        XCTAssertTrue(result.suppressVisibleAssistantText)
        XCTAssertEqual(result.visibleIntro, "好的，我先整理现有代码结构，然后给出可执行计划。")
        XCTAssertTrue(result.planMarkdown?.contains("## 整理计划") == true)
        let data = try XCTUnwrap(result.toolCalls.first?.inputJSON.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue((object["assistantPlanMarkdown"] as? String)?.contains("清理重复样式") == true)
    }

    func testAskQuestionDefersCompanionAssistantContentBeforeQuestionCard() {
        let call = AgentToolCall(
            id: "ask",
            name: "AskQuestion",
            inputJSON: #"{"question":"请选择优化范围","options":["全部","只改 UI"]}"#
        )

        let result = InteractivePlanContentDeferrer.prepare(
            assistantContent: "我先确认几个选择，然后再给出最终计划。",
            toolCalls: [call]
        )

        XCTAssertTrue(result.suppressVisibleAssistantText)
        XCTAssertEqual(result.visibleIntro, "我先确认几个选择，然后再给出最终计划。")
        XCTAssertNil(result.planMarkdown)
        XCTAssertEqual(result.toolCalls, [call])
    }

    func testPlanModeAskQuestionSuppressesCompanionDraftText() {
        let call = AgentToolCall(
            id: "ask",
            name: "AskQuestion",
            inputJSON: #"{"questions":[{"question":"商品类型是什么？","options":[{"label":"电子产品"},{"label":"服装"}]}]}"#
        )

        let result = InteractivePlanContentDeferrer.prepare(
            assistantContent: "请告诉我几个偏好，我再生成计划。\n\n1. 商品类型是什么？",
            toolCalls: [call],
            runMode: .plan
        )

        XCTAssertTrue(result.suppressVisibleAssistantText)
        XCTAssertNil(result.visibleIntro)
        XCTAssertNil(result.planMarkdown)
        XCTAssertEqual(result.hiddenCompanionText, "请告诉我几个偏好，我再生成计划。\n\n1. 商品类型是什么？")
    }

    func testPlanModeSwitchModeSuppressesIntroAndMovesPlanToConfirmationInput() throws {
        let assistantText = """
        好的，下面是计划。

        ## 实施计划
        1. 读取项目结构。
        2. 修改页面。
        """
        let call = AgentToolCall(id: "switch", name: "SwitchMode", inputJSON: #"{"mode":"agent"}"#)

        let result = InteractivePlanContentDeferrer.prepare(
            assistantContent: assistantText,
            toolCalls: [call],
            runMode: .plan
        )

        XCTAssertTrue(result.suppressVisibleAssistantText)
        XCTAssertNil(result.visibleIntro)
        XCTAssertTrue(result.planMarkdown?.contains("## 实施计划") == true)
        let data = try XCTUnwrap(result.toolCalls.first?.inputJSON.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue((object["assistantPlanMarkdown"] as? String)?.contains("修改页面") == true)
    }

    func testPlanStreamingHoldsContentUntilInteractiveToolDecision() {
        XCTAssertTrue(InteractivePlanContentDeferrer.shouldHoldStreamingContent(
            "## 实施计划\n1. 优化 UI",
            runMode: .plan,
            hasToolCallAccumulator: false
        ))
        XCTAssertTrue(InteractivePlanContentDeferrer.shouldHoldStreamingContent(
            "好的，我先查看项目结构来完善计划。",
            runMode: .plan,
            hasToolCallAccumulator: false
        ))
        XCTAssertFalse(InteractivePlanContentDeferrer.shouldHoldStreamingContent(
            "好的，我先查看项目结构来完善计划。",
            runMode: .plan,
            hasToolCallAccumulator: true
        ))
        XCTAssertTrue(InteractivePlanContentDeferrer.shouldHoldStreamingContent(
            "## Implementation plan\n1. Update the UI",
            runMode: .agent,
            hasToolCallAccumulator: false
        ))
        XCTAssertFalse(InteractivePlanContentDeferrer.shouldHoldStreamingContent(
            "Here is the final summary.",
            runMode: .agent,
            hasToolCallAccumulator: false
        ))
    }

    func testPlanModeSynthesizesIntroForSafeExplorationToolCalls() {
        let readCall = AgentToolCall(
            id: "read",
            name: "Read",
            inputJSON: #"{"file_path":"README.md"}"#
        )
        let writeCall = AgentToolCall(
            id: "write",
            name: "Write",
            inputJSON: #"{"file_path":"README.md","content":"x"}"#
        )
        let shellCall = AgentToolCall(
            id: "shell",
            name: "Shell",
            inputJSON: #"{"command":"date +%Y-%m-%d"}"#
        )

        XCTAssertTrue(PlanModeIntroSynthesizer.intro(for: [readCall], runMode: .plan)?.contains("完善计划") == true)
        XCTAssertTrue(PlanModeIntroSynthesizer.intro(for: [shellCall], runMode: .plan)?.contains("只读命令") == true)
        XCTAssertNil(PlanModeIntroSynthesizer.intro(for: [writeCall], runMode: .plan))
        XCTAssertNil(PlanModeIntroSynthesizer.intro(for: [readCall], runMode: .agent))
    }

    func testPlanModeSafeExplorationKeepsAssistantIntroVisible() {
        let call = AgentToolCall(
            id: "shell",
            name: "Shell",
            inputJSON: #"{"command":"date +%Y-%m-%d"}"#
        )

        let result = InteractivePlanContentDeferrer.prepare(
            assistantContent: "我先看一下当前时间，再整理时钟网页的实现计划。",
            toolCalls: [call],
            runMode: .plan
        )

        XCTAssertFalse(result.suppressVisibleAssistantText)
        XCTAssertNil(result.hiddenCompanionText)
    }

    func testPlanPlainTextQuestionRecoversToAskQuestionCard() throws {
        let context = AgentRunContext(request: agentRequest(runMode: .plan))
        let text = """
        我需要先确认几个问题：

        1. 商品类型是什么？
        - 电子产品
        - 服装

        2. 网站风格偏好？
        - 简洁现代
        - 高端奢华
        """

        guard case .askQuestion(let call) = PlanTurnRecoveryClassifier.recovery(for: text, context: context) else {
            return XCTFail("Plain text questions should recover to AskQuestion.")
        }

        XCTAssertEqual(call.name, "AskQuestion")
        let data = try XCTUnwrap(call.inputJSON.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["recoveredFromPlainText"] as? Bool, true)
        let questions = try XCTUnwrap(object["questions"] as? [[String: Any]])
        XCTAssertEqual(questions.count, 2)
        XCTAssertEqual(questions.first?["question"] as? String, "商品类型是什么？")
        XCTAssertEqual((questions.first?["options"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual((questions.last?["options"] as? [[String: Any]])?.count, 2)
    }

    func testPlanPlainTextCalendarQuestionRecoversToFourChoiceQuestions() throws {
        let context = AgentRunContext(request: agentRequest(runMode: .plan))
        let text = """
        请告诉我你的偏好，我来帮你创建一个漂亮的日历网站。
        1. **日历的功能需求？**
        """

        guard case .askQuestion(let call) = PlanTurnRecoveryClassifier.recovery(for: text, context: context) else {
            return XCTFail("Calendar planning text should recover to AskQuestion.")
        }

        let data = try XCTUnwrap(call.inputJSON.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let questions = try XCTUnwrap(object["questions"] as? [[String: Any]])
        XCTAssertEqual(questions.count, 4)
        XCTAssertEqual(questions.first?["question"] as? String, "日历的功能侧重是什么？")
        for question in questions {
            let options = try XCTUnwrap(question["options"] as? [[String: Any]])
            XCTAssertFalse(options.isEmpty)
            XCTAssertFalse(((question["question"] as? String) ?? "").contains("*"))
        }
    }

    func testPlanPlainTextPlanRecoversToSwitchModeConfirmation() throws {
        let context = AgentRunContext(request: agentRequest(runMode: .plan, permissionMode: .bypassPermissions))
        context.planQuestionAnswered = true
        let text = """
        ## 实施计划
        1. 读取现有 HTML/CSS/JS 文件结构。
        2. 创建日历页面并补齐交互逻辑。
        3. 验证页面可以打开并总结结果。
        """

        guard case .switchMode(let call) = PlanTurnRecoveryClassifier.recovery(for: text, context: context) else {
            return XCTFail("Plain text plans should recover to SwitchMode.")
        }

        let data = try XCTUnwrap(call.inputJSON.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(call.name, "SwitchMode")
        XCTAssertEqual(object["mode"] as? String, "agent")
        XCTAssertEqual(object["recoveredFromPlainText"] as? Bool, true)
        XCTAssertTrue((object["plan"] as? String)?.contains("创建日历页面") == true)

        if case .ask = AgentPermissionPolicy.policy(for: call, context: context) {
            // Recovered plain-text plans should still show the confirmation card instead of getting stuck
            // behind the missing AskQuestion protocol requirement.
        } else {
            XCTFail("Recovered SwitchMode plan should ask for confirmation.")
        }
    }

    func testPlanPlainTextPlanBeforeQuestionRecoversToAskQuestion() throws {
        let context = AgentRunContext(request: agentRequest(runMode: .plan, permissionMode: .bypassPermissions))
        let text = """
        ## 实施计划
        1. 创建日历页面。
        2. 验证页面。
        """

        guard case .askQuestion(let call) = PlanTurnRecoveryClassifier.recovery(for: text, context: context) else {
            return XCTFail("Plan mode must ask questions before plan confirmation.")
        }

        let payload = try XCTUnwrap(AgentInteractivePayload.askUserQuestion(from: call.inputJSON))
        XCTAssertFalse(payload.questions.isEmpty)
    }

    func testPlanModeAllowsReadOnlyShellAndSoftBlocksWriteShell() {
        let context = AgentRunContext(request: agentRequest(runMode: .plan, permissionMode: .default))

        XCTAssertEqual(
            AgentPermissionPolicy.policy(
                for: AgentToolCall(id: "date", name: "Shell", inputJSON: #"{"command":"date +%Y-%m-%d"}"#),
                context: context
            ),
            .allow
        )
        XCTAssertEqual(
            AgentPermissionPolicy.policy(
                for: AgentToolCall(id: "git-show", name: "Shell", inputJSON: #"{"command":"git show --stat HEAD"}"#),
                context: context
            ),
            .allow
        )
        if case .block(let reason) = AgentPermissionPolicy.policy(
            for: AgentToolCall(id: "touch", name: "Shell", inputJSON: #"{"command":"touch index.html"}"#),
            context: context
        ) {
            XCTAssertTrue(reason.contains("Plan mode skipped"))
        } else {
            XCTFail("Write-capable Shell must be soft-blocked in Plan mode.")
        }
    }

    func testAskQuestionResultUsesPilotDeckStyleAnswerHint() {
        let call = AgentToolCall(
            id: "ask",
            name: "AskQuestion",
            inputJSON: #"{"questions":[{"question":"商品类型是什么？","options":[{"label":"电子产品"},{"label":"服装"}]}]}"#
        )
        let result = AgentToolExecutor.askUserQuestionResult(
            call: call,
            updatedInputJSON: #"{"answers":{"商品类型是什么？":"电子产品"}}"#
        )

        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("User has answered your questions"))
        XCTAssertTrue(result.output.contains(#""商品类型是什么？"="电子产品""#))
        XCTAssertFalse(result.output.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"))
    }

    func testPlanWorkflowPresentationStatusesMatchInteractiveStages() {
        let ask = AgentToolCall(id: "ask", name: "AskQuestion", inputJSON: "{}")
        let read = AgentToolCall(id: "read", name: "Read", inputJSON: #"{"file_path":"README.md"}"#)
        let switchMode = AgentToolCall(id: "switch", name: "SwitchMode", inputJSON: #"{"mode":"agent","plan":"Do it"}"#)

        XCTAssertEqual(
            PlanWorkflowPresentation.generationStatus(for: [ask], runMode: .plan),
            PlanWorkflowPresentation.generatingQuestionStatus
        )
        XCTAssertEqual(
            PlanWorkflowPresentation.generationStatus(for: [read], runMode: .plan),
            PlanWorkflowPresentation.collectingContextStatus
        )
        XCTAssertEqual(
            PlanWorkflowPresentation.generationStatus(for: [switchMode], runMode: .plan),
            PlanWorkflowPresentation.generatingPlanStatus
        )
        XCTAssertEqual(
            PlanWorkflowPresentation.waitingStatus(for: "AskQuestion", runMode: .plan),
            PlanWorkflowPresentation.waitingForAnswerStatus
        )
        XCTAssertNil(PlanWorkflowPresentation.generationStatus(for: [ask], runMode: .agent))
    }

    func testInteractivePermissionActivitiesDoNotExpandRawDetailsByDefault() {
        XCTAssertFalse(AgentActivityPresentationPolicy.expandsPermissionByDefault(.askUserQuestion))
        XCTAssertFalse(AgentActivityPresentationPolicy.expandsPermissionByDefault(.exitPlanMode))
    }

    func testSwitchModeCanStayInPlanForRevisionFeedback() async {
        let context = AgentRunContext(request: agentRequest(runMode: .plan))
        let call = AgentToolCall(
            id: "switch-refine",
            name: "SwitchMode",
            inputJSON: #"{"mode":"plan","userFeedback":"Add rollback steps before executing."}"#
        )

        let result = await NativeToolRouter.execute(call: call, context: context)

        XCTAssertFalse(result.isError)
        XCTAssertEqual(context.runMode, .plan)
        XCTAssertFalse(context.planExited)
        XCTAssertTrue(result.output.contains("Stay in Plan mode"))
        XCTAssertTrue(result.output.contains("rollback"))
    }

    func testNestedTaskIsRejectedAtMaxSubagentDepth() async {
        let context = AgentRunContext(request: agentRequest(nativeConfigValues: ["runtime.maxSubagentDepth": "1"]))
        context.subagentDepth = 1
        let call = AgentToolCall(
            id: "nested-task",
            name: "Task",
            inputJSON: #"{"prompt":"Explore nested work","type":"explore"}"#
        )

        let result = await NativeToolRouter.execute(call: call, context: context)

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("subagent_depth_exceeded"))
    }

    func testSubagentToolSetIsReadOnlyAndSearchCapable() {
        let tools = NativeAgentRuntime.subagentReadOnlyOpenAITools()
        let names = Set(tools.compactMap { tool -> String? in
            (tool["function"] as? [String: Any])?["name"] as? String
        })

        XCTAssertTrue(names.contains("Read"))
        XCTAssertTrue(names.contains("Grep"))
        XCTAssertTrue(names.contains("Glob"))
        XCTAssertTrue(names.contains("SemanticSearch"))
        XCTAssertTrue(names.contains("WebSearch"))
        XCTAssertFalse(names.contains("TodoRead"))
        XCTAssertFalse(names.contains("Write"))
        XCTAssertFalse(names.contains("StrReplace"))
        XCTAssertFalse(names.contains("Shell"))
        XCTAssertFalse(names.contains("Task"))
        XCTAssertTrue(NativeAgentRuntime.isSubagentReadOnlyTool(AgentToolCall(id: "read", name: "read", inputJSON: "{}")))
        XCTAssertFalse(NativeAgentRuntime.isSubagentReadOnlyTool(AgentToolCall(id: "write", name: "write", inputJSON: "{}")))
        XCTAssertFalse(NativeAgentRuntime.isSubagentReadOnlyTool(AgentToolCall(id: "task", name: "subagent", inputJSON: "{}")))
    }

    func testNativeAttachmentResolverBuildsMultimodalContentParts() throws {
        let root = try makeAgentWorkspace("attachments")
        defer { try? FileManager.default.removeItem(at: root) }
        let textURL = root.appendingPathComponent("notes.txt")
        let imageURL = root.appendingPathComponent("pixel.png")
        let pdfURL = root.appendingPathComponent("sample.pdf")
        try "Use this text attachment.".write(to: textURL, atomically: true, encoding: .utf8)
        try writeTinyPNG(to: imageURL)
        try writeMinimalPDF(to: pdfURL)

        let (parts, diagnostics) = NativeAttachmentResolver.openAIContentParts(for: [
            FileAttachment(id: UUID(), fileName: "notes.txt", path: textURL.path, mimeType: "text/plain"),
            FileAttachment(id: UUID(), fileName: "pixel.png", path: imageURL.path, mimeType: "image/png"),
            FileAttachment(id: UUID(), fileName: "sample.pdf", path: pdfURL.path, mimeType: "application/pdf"),
        ])

        XCTAssertTrue(parts.contains { ($0["type"] as? String) == "image_url" })
        XCTAssertTrue(parts.contains { (($0["text"] as? String) ?? "").contains("Use this text attachment.") })
        XCTAssertTrue(parts.contains { (($0["text"] as? String) ?? "").contains("Page 1") })
        XCTAssertTrue(diagnostics.contains { $0.message.contains("multimodal") })
    }

    func testNativeContextBudgetPersistsLargeToolResultsToDisk() throws {
        let root = temporaryDirectory("pilotdeck-tool-results")
        defer { try? FileManager.default.removeItem(at: root) }
        let largeOutput = String(repeating: "large tool output\n", count: 4_000)
        let messages: [[String: Any]] = [
            ["role": "system", "content": "system"],
            ["role": "assistant", "content": NSNull(), "tool_calls": [
                ["id": "read-calendar", "type": "function", "function": ["name": "Read", "arguments": "{}"]],
            ]],
            ["role": "tool", "tool_call_id": "read-calendar", "content": largeOutput],
        ]

        let projected = NativeContextBudget.applyToolResultBudget(
            messages: messages,
            sessionId: "session/with unsafe chars",
            workspacePath: root.path,
            maxResultCharacters: 1_000,
            previewCharacters: 120
        )
        let content = try XCTUnwrap(projected.last?["content"] as? String)
        let pathLine = try XCTUnwrap(content.split(separator: "\n").first { $0.contains("Full output:") })
        let path = String(pathLine).replacingOccurrences(of: "Full output:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertTrue(content.contains("<persisted-output>"))
        XCTAssertTrue(content.contains("Tool: Read"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), largeOutput)
    }

    func testNativeContextBudgetProjectsCompactionBoundaryWithoutMutatingOriginalMessages() {
        let messages: [[String: Any]] = [
            ["role": "system", "content": "system"],
            ["role": "user", "content": "Build the calendar import workflow and preserve timezone conversion rules."],
            ["role": "assistant", "content": NSNull(), "tool_calls": [
                [
                    "id": "read-calendar",
                    "type": "function",
                    "function": [
                        "name": "Read",
                        "arguments": #"{"path":"Sources/CalendarImporter.swift"}"#,
                    ],
                ],
            ]],
            [
                "role": "tool",
                "tool_call_id": "read-calendar",
                "content": "CalendarImporter.swift maps event timezone conversion before saving.",
            ],
            ["role": "assistant", "content": "I found the timezone conversion path and will keep it intact."],
            ["role": "user", "content": "Now continue with tests."],
        ]
        var state = NativeContextCompressionState()
        state.apply(
            summary: "Primary request: preserve calendar timezone conversion in CalendarImporter.swift.",
            coveredMessageCount: 5
        )

        let projected = NativeContextBudget.projectedMessages(messages: messages, state: state)
        let serialized = String(describing: projected)
        let originalSerialized = String(describing: messages)

        XCTAssertTrue(serialized.contains("[Context compacted]"))
        XCTAssertTrue(serialized.contains("CalendarImporter.swift"))
        XCTAssertTrue(serialized.contains("Now continue with tests."))
        XCTAssertFalse(serialized.contains("Build the calendar import workflow and preserve timezone conversion rules."))
        XCTAssertTrue(originalSerialized.contains("Build the calendar import workflow and preserve timezone conversion rules."))
    }

    func testNativeContextBudgetExtractsSummaryXMLAndAnchorsProviderUsage() {
        let response = """
        <analysis>
        This part should not be retained.
        </analysis>
        <summary>
        Keep the actual compacted state.
        </summary>
        """

        XCTAssertEqual(
            NativeContextBudget.extractedCompactSummary(from: response),
            "Keep the actual compacted state."
        )

        var tracker = NativeTokenBudgetTracker()
        tracker.anchorAfterModelResponse(
            messageCount: 1,
            budget: TokenBudget(used: 100, total: 1_000, level: .normal)
        )
        let snapshot = tracker.snapshot(
            messages: [
                ["role": "user", "content": "prompt"],
                ["role": "tool", "content": String(repeating: "x", count: 400)],
            ],
            contextWindow: 1_000
        )

        XCTAssertGreaterThan(snapshot.used, 100)
        XCTAssertLessThan(snapshot.used, NativeContextBudget.snapshot(
            messages: [["role": "user", "content": String(repeating: "x", count: 1_200)]],
            contextWindow: 1_000
        ).used + 100)
    }

    func testNativeContextBudgetForceRecoverAggressivelyReducesOverBudgetMessages() {
        let largeText = String(repeating: "large generated file content and verification notes\n", count: 1_200)
        var messages: [[String: Any]] = [
            ["role": "system", "content": "system prompt"],
        ]
        for index in 0..<12 {
            messages.append(["role": "user", "content": "Create large test artifact \(index). \(largeText)"])
            messages.append(["role": "assistant", "content": "I will create artifact \(index).", "tool_calls": [
                [
                    "id": "edit-\(index)",
                    "type": "function",
                    "function": [
                        "name": "Edit",
                        "arguments": #"{"file_path":"docs/file.md","old_string":"","new_string":"large"}"#,
                    ],
                ],
            ]])
            messages.append(["role": "tool", "tool_call_id": "edit-\(index)", "content": largeText])
        }

        let before = NativeContextBudget.snapshot(messages: messages, contextWindow: 8_000)
        let recovered = NativeContextBudget.forceRecover(messages: messages, contextWindow: 8_000)
        let after = NativeContextBudget.snapshot(messages: recovered.messages, contextWindow: 8_000)
        let serialized = String(describing: recovered.messages)

        XCTAssertGreaterThan(before.used, 8_000)
        XCTAssertLessThan(after.used, before.used)
        XCTAssertLessThan(after.used, 8_000)
        XCTAssertTrue(serialized.contains("[Context compacted]"))
    }

    func testToolInvocationPresentationRendersShellRawFallbackAndCommonFields() {
        let presentation = ToolInvocationPresentation.parse(
            toolName: "bash",
            inputJSON: #"{"command":"sed -n '1,20p' README.md\nrg -n \"ChatView\" .","description":"Inspect UI"}"#
        )

        XCTAssertEqual(presentation.toolName, "Shell")
        XCTAssertEqual(presentation.title, "Shell")
        XCTAssertEqual(presentation.command, "sed -n '1,20p' README.md\nrg -n \"ChatView\" .")
        XCTAssertTrue(presentation.parsed)
        XCTAssertEqual(presentation.primaryValue, presentation.command)
        let target = ToolInvocationPresentation.target(toolName: "Shell", inputJSON: presentation.rawInput, limit: 80)
        XCTAssertEqual(target, "sed -n '1,20p' README.md rg -n \"ChatView\" .")

        let fallback = ToolInvocationPresentation.parse(toolName: "Read", inputJSON: "{path: README.md")

        XCTAssertFalse(fallback.parsed)
        XCTAssertNil(fallback.command)
        XCTAssertEqual(fallback.fields, [
            ToolInvocationField(label: "Raw input", value: "{path: README.md", isPrimary: true),
        ])
        XCTAssertEqual(fallback.primaryValue, "{path: README.md")

        let read = ToolInvocationPresentation.parse(toolName: "Read", inputJSON: #"{"file_path":"/tmp/App.swift","offset":12}"#)
        let grep = ToolInvocationPresentation.parse(toolName: "Grep", inputJSON: #"{"pattern":"ToolInvocation","path":"apps/macos-native"}"#)
        let glob = ToolInvocationPresentation.parse(toolName: "Glob", inputJSON: #"{"pattern":"**/*.swift","path":"apps/macos-native"}"#)
        let task = ToolInvocationPresentation.parse(toolName: "Task", inputJSON: #"{"description":"Inspect tool UI","prompt":"Find process rows","type":"explore"}"#)

        XCTAssertEqual(read.fields.map(\.label), ["Path", "Offset"])
        XCTAssertEqual(read.primaryValue, "/tmp/App.swift")
        XCTAssertEqual(grep.fields.map(\.label), ["Pattern", "Path"])
        XCTAssertEqual(grep.primaryValue, "ToolInvocation")
        XCTAssertEqual(glob.fields.map(\.label), ["Pattern", "Path"])
        XCTAssertEqual(glob.primaryValue, "**/*.swift")
        XCTAssertEqual(task.fields.map(\.label), ["Description", "Prompt", "Type"])
        XCTAssertEqual(task.primaryValue, "Inspect tool UI")
    }

    func testTodoListPresentationParsesSnapshotAndDiff() {
        let firstInput = """
        {"todos":[
          {"id":"1","content":"Create project structure","status":"completed"},
          {"id":"2","content":"Write index.html","status":"in_progress"},
          {"id":"3","content":"Write styles","status":"pending"}
        ]}
        """
        let secondInput = """
        {"todos":[
          {"id":"1","content":"Create project structure","status":"done"},
          {"id":"2","content":"Write index.html","status":"completed"},
          {"id":"3","content":"Write styles","status":"in-progress"},
          {"id":"4","content":"Smoke test","status":"todo"}
        ]}
        """

        let first = TodoListPresentation.parse(toolName: "TodoWrite", inputJSON: firstInput, resultOutput: nil)
        let second = TodoListPresentation.parse(
            toolName: "TodoWrite",
            inputJSON: secondInput,
            resultOutput: nil,
            previous: first?.snapshot
        )

        XCTAssertEqual(first?.snapshot.completedCount, 1)
        XCTAssertEqual(first?.snapshot.inProgressCount, 1)
        XCTAssertEqual(first?.snapshot.pendingCount, 1)
        XCTAssertEqual(second?.snapshot.completedCount, 2)
        XCTAssertEqual(second?.snapshot.inProgressCount, 1)
        XCTAssertEqual(second?.snapshot.pendingCount, 1)
        XCTAssertEqual(second?.snapshot.items.first(where: { $0.id == "1" })?.status, .completed)
        XCTAssertTrue(second?.diff.changedItemKeys.contains("2") == true)
        XCTAssertTrue(second?.diff.completedItemKeys.contains("2") == true)
        XCTAssertTrue(second?.summary(isChinese: true).contains("2 完成") == true)
    }

    func testTodoListPresentationParsesCompletedBooleanChecklist() {
        let input = """
        {"todos":[
          {"id":"1","content":"Create project structure","completed":true},
          {"id":"2","content":"Write index.html","completed":false},
          {"id":"3","content":"Smoke test","completed":false}
        ]}
        """

        let presentation = TodoListPresentation.parse(toolName: "TodoWrite", inputJSON: input, resultOutput: nil)

        XCTAssertEqual(presentation?.snapshot.completedCount, 1)
        XCTAssertEqual(presentation?.snapshot.inProgressCount, 1)
        XCTAssertEqual(presentation?.snapshot.pendingCount, 1)
        XCTAssertEqual(presentation?.snapshot.items.map(\.status), [.completed, .inProgress, .pending])
        XCTAssertTrue(presentation?.summary(isChinese: true).contains("1 完成 · 1 进行中 · 1 待办") == true)
    }

    func testTodoCompletionGateAcceptsCompletedBooleanChecklist() {
        let completed = #"[{"content":"Ship","completed":true},{"content":"Verify","done":true}]"#
        let incomplete = #"[{"content":"Ship","completed":true},{"content":"Verify","completed":false}]"#

        XCTAssertFalse(AgentRunContext.hasIncompleteTodos(in: completed))
        XCTAssertTrue(AgentRunContext.hasIncompleteTodos(in: incomplete))
    }

    func testTodoListPresentationPreservesInputOrderAndContentKeys() {
        let previousInput = """
        {"todos":[
          {"content":"Create project structure","status":"in_progress"},
          {"content":"Write index.html","status":"pending"},
          {"content":"Smoke test","status":"pending"}
        ]}
        """
        let nextInput = """
        {"todos":[
          {"content":"Create project structure","status":"completed"},
          {"content":"Write index.html","status":"in_progress"},
          {"content":"Smoke test","status":"pending"}
        ]}
        """

        let previous = TodoListPresentation.parse(toolName: "TodoWrite", inputJSON: previousInput, resultOutput: nil)
        let next = TodoListPresentation.parse(
            toolName: "TodoWrite",
            inputJSON: nextInput,
            resultOutput: nil,
            previous: previous?.snapshot
        )

        XCTAssertEqual(next?.snapshot.items.map(\.content), [
            "Create project structure",
            "Write index.html",
            "Smoke test",
        ])
        XCTAssertEqual(next?.snapshot.items.map(\.status), [.completed, .inProgress, .pending])
        XCTAssertTrue(next?.diff.completedItemKeys.contains("content:create project structure") == true)
        XCTAssertTrue(next?.diff.changedItemKeys.contains("content:write index.html") == true)
    }

    func testTodoListPresentationParsesTodoReadAndMarkdown() {
        let read = TodoListPresentation.parse(
            toolName: "TodoRead",
            inputJSON: "{}",
            resultOutput: #"[{"content":"Review","status":"completed"},{"content":"Ship","status":"pending"}]"#
        )
        XCTAssertEqual(read?.snapshot.totalCount, 2)
        XCTAssertEqual(read?.snapshot.completedCount, 1)

        let markdown = TodoListPresentation.parse(
            toolName: "TodoWrite",
            inputJSON: #"{"markdown":"- [x] Done\n- [ ] Current\n- [ ] Later"}"#,
            resultOutput: nil
        )
        XCTAssertEqual(markdown?.snapshot.completedCount, 1)
        XCTAssertEqual(markdown?.snapshot.inProgressCount, 1)
        XCTAssertEqual(markdown?.snapshot.pendingCount, 1)
    }

    func testTodoWriteDetailIgnoresToolResultHistory() {
        let input = #"{"todos":[{"content":"Create structure","status":"completed"},{"content":"Write CSS","status":"in_progress"}]}"#
        let pollutedResult = """
        Updated todo list.
        Read 1: <html>...
        {"file_path":"calendar/index.html"}
        Searched for **/*
        """

        let presentation = ToolDetailPresentation.todoList(
            toolName: "TodoWrite",
            inputJSON: input,
            resultOutput: pollutedResult
        )

        XCTAssertEqual(presentation?.snapshot.items.map(\.content), ["Create structure", "Write CSS"])
        XCTAssertEqual(presentation?.snapshot.completedCount, 1)
        XCTAssertEqual(presentation?.snapshot.inProgressCount, 1)
        XCTAssertFalse(presentation?.snapshot.items.map(\.content).contains(where: { $0.contains("Read 1") }) == true)
        XCTAssertFalse(presentation?.snapshot.items.map(\.content).contains(where: { $0.contains("Searched") }) == true)
    }

    func testLiveStatusPresentationDoesNotExposeRunHistoryForTodo() {
        let date = Date()
        let read = AgentActivity(
            id: "read",
            sessionId: "session",
            title: "Read",
            detail: "Read 1: <html>...",
            phase: .tool,
            state: .completed,
            createdAt: date,
            updatedAt: date,
            toolName: "Read",
            detailMessages: ["Read 1: <html>..."]
        )
        let grep = AgentActivity(
            id: "grep",
            sessionId: "session",
            title: "Grep",
            detail: "Searched for **/*",
            phase: .search,
            state: .completed,
            createdAt: date.addingTimeInterval(1),
            updatedAt: date.addingTimeInterval(1),
            toolName: "Grep",
            detailMessages: ["Searched for **/*"]
        )
        let todo = AgentActivity(
            id: "todo",
            sessionId: "session",
            title: "Running TodoWrite",
            detail: #"{"todos":[{"content":"Write CSS","status":"in_progress"}]}"#,
            phase: .todo,
            state: .running,
            createdAt: date.addingTimeInterval(2),
            updatedAt: date.addingTimeInterval(2),
            toolName: "TodoWrite",
            detailMessages: [#"{"todos":[{"content":"Write CSS","status":"in_progress"}]}"#]
        )

        let presentation = ProcessTracePresentation.make(activities: [read, grep, todo], isChinese: true)

        XCTAssertTrue(presentation.shouldRender)
        XCTAssertEqual(presentation.detailRows, [])
        XCTAssertTrue(presentation.summaryText.contains("Todo"))
    }

    func testLiveStatusPresentationOnlyUsesCurrentToolDetail() {
        let date = Date()
        let previousWrite = AgentActivity(
            id: "write",
            sessionId: "session",
            title: "Write",
            detail: "Wrote calendar/index.html",
            phase: .edit,
            state: .completed,
            createdAt: date,
            updatedAt: date,
            toolName: "Write",
            detailMessages: ["Wrote calendar/index.html"]
        )
        let runningRead = AgentActivity(
            id: "read",
            sessionId: "session",
            title: "Running Read",
            detail: #"{"file_path":"calendar/js/app.js"}"#,
            phase: .tool,
            state: .running,
            createdAt: date.addingTimeInterval(1),
            updatedAt: date.addingTimeInterval(1),
            toolName: "Read",
            detailMessages: [#"{"file_path":"calendar/js/app.js"}"#]
        )

        let presentation = ProcessTracePresentation.make(activities: [previousWrite, runningRead], isChinese: true)
        let combined = presentation.detailRows.map { "\($0.title) \($0.detail)" }.joined(separator: "\n")

        XCTAssertEqual(presentation.detailRows.count, 1)
        XCTAssertTrue(combined.contains("calendar/js/app.js"))
        XCTAssertFalse(combined.contains("calendar/index.html"))
    }

    func testTodoAndTaskAreBoundaryProcessTools() {
        XCTAssertTrue(ProcessToolGroupingPolicy.isBoundaryProcessTool("TodoWrite"))
        XCTAssertTrue(ProcessToolGroupingPolicy.isBoundaryProcessTool("todo_read"))
        XCTAssertTrue(ProcessToolGroupingPolicy.isBoundaryProcessTool("Task"))
        XCTAssertFalse(ProcessToolGroupingPolicy.isBoundaryProcessTool("Read"))
        XCTAssertFalse(ProcessToolGroupingPolicy.isBoundaryProcessTool("Write"))
    }

    func testToolOutputPreviewLimiterTruncatesLargeToolOutput() {
        let output = (0..<120).map { "line \($0)" }.joined(separator: "\n")
        let preview = ToolOutputPreviewLimiter.preview(output, maxChars: 500, maxLines: 20)

        XCTAssertTrue(preview.contains("line 0"))
        XCTAssertTrue(preview.contains("output truncated"))
        XCTAssertFalse(preview.contains("line 119"))
    }

    func testPlanTodoExecutionGateRequiresInitializationAndRefresh() {
        let context = AgentRunContext(request: agentRequest(runMode: .agent, permissionMode: .bypassPermissions))
        context.planExecutionApproved = true
        context.todoRequiresInitialization = true
        let write = AgentToolCall(id: "write", name: "Write", inputJSON: #"{"file_path":"index.html","content":"hi"}"#)

        let initialBlock = PlanTodoExecutionGate.blockingResult(for: write, context: context)
        XCTAssertEqual(initialBlock?.isPolicyBlock, true)
        XCTAssertEqual(initialBlock?.isError, false)

        let todo = AgentToolCall(id: "todo", name: "TodoWrite", inputJSON: #"{"todos":[{"content":"Write file","status":"in_progress"}]}"#)
        context.recordToolResult(
            AgentToolResult(callId: "todo", toolName: "TodoWrite", output: "ok", isError: false),
            call: todo
        )
        XCTAssertNil(PlanTodoExecutionGate.blockingResult(for: write, context: context))

        context.recordToolResult(
            AgentToolResult(callId: "write", toolName: "Write", output: "Wrote index.html", isError: false),
            call: write
        )
        XCTAssertTrue(context.todoRequiresRefresh)
        XCTAssertEqual(PlanTodoExecutionGate.blockingResult(for: write, context: context)?.isPolicyBlock, true)
    }

    func testParallelSafeToolInvocationOnlyAllowsPureReadTools() {
        let context = AgentRunContext(request: agentRequest(permissionMode: .bypassPermissions))
        let read = ToolArgumentNormalizer.normalize(
            AgentToolCall(id: "read", name: "Read", inputJSON: #"{"file_path":"README.md"}"#)
        )
        let grep = ToolArgumentNormalizer.normalize(
            AgentToolCall(id: "grep", name: "Grep", inputJSON: #"{"pattern":"PilotDeck"}"#)
        )
        let todoRead = ToolArgumentNormalizer.normalize(
            AgentToolCall(id: "todo-read", name: "TodoRead", inputJSON: #"{}"#)
        )
        let glob = ToolArgumentNormalizer.normalize(
            AgentToolCall(id: "glob", name: "Glob", inputJSON: #"{"pattern":"**/*","path":"."}"#)
        )
        let skill = ToolArgumentNormalizer.normalize(
            AgentToolCall(id: "skill", name: "Skill", inputJSON: #"{"skill":"research"}"#)
        )
        let shell = ToolArgumentNormalizer.normalize(
            AgentToolCall(id: "shell", name: "Shell", inputJSON: #"{"command":"pwd"}"#)
        )
        let write = ToolArgumentNormalizer.normalize(
            AgentToolCall(id: "write", name: "Write", inputJSON: #"{"file_path":"index.html","content":"hi"}"#)
        )

        XCTAssertTrue(NativeAgentRuntime.isParallelSafeToolInvocation(read, context: context))
        XCTAssertTrue(NativeAgentRuntime.isParallelSafeToolInvocation(grep, context: context))
        XCTAssertTrue(NativeAgentRuntime.isParallelSafeToolInvocation(todoRead, context: context))
        XCTAssertFalse(NativeAgentRuntime.isParallelSafeToolInvocation(glob, context: context))
        XCTAssertFalse(NativeAgentRuntime.isParallelSafeToolInvocation(skill, context: context))
        XCTAssertFalse(NativeAgentRuntime.isParallelSafeToolInvocation(shell, context: context))
        XCTAssertFalse(NativeAgentRuntime.isParallelSafeToolInvocation(write, context: context))
    }

    func testRootGlobExecutionPolicyCachesRepeatedRootDiscovery() {
        let context = AgentRunContext(request: agentRequest(permissionMode: .bypassPermissions))
        let rootGlob = AgentToolCall(id: "glob", name: "Glob", inputJSON: #"{"pattern":"**/*","path":"."}"#)
        let targetedGlob = AgentToolCall(id: "targeted", name: "Glob", inputJSON: #"{"pattern":"**/*.swift","path":"."}"#)

        XCTAssertTrue(RootGlobExecutionPolicy.isRootWorkspaceGlob(inputJSON: rootGlob.inputJSON))
        XCTAssertNil(RootGlobExecutionPolicy.cachedResultIfAvailable(call: rootGlob, context: context))
        _ = RootGlobExecutionPolicy.recordIfRootGlob(call: rootGlob, output: "index.html\nsrc/app.js", context: context)

        let cached = RootGlobExecutionPolicy.cachedResultIfAvailable(call: rootGlob, context: context)
        XCTAssertEqual(cached?.isError, false)
        XCTAssertTrue(cached?.output.contains("Cached workspace discovery") == true)
        XCTAssertNil(RootGlobExecutionPolicy.cachedResultIfAvailable(call: targetedGlob, context: context))
    }

    func testNativeContextBudgetPreservesToolPairIntegrity() {
        let messages: [[String: Any]] = [
            ["role": "assistant", "content": NSNull(), "tool_calls": [
                ["id": "paired", "type": "function", "function": ["name": "Read", "arguments": "{}"]],
                ["id": "dangling-call", "type": "function", "function": ["name": "Read", "arguments": "{}"]],
            ]],
            ["role": "tool", "tool_call_id": "paired", "content": "ok"],
            ["role": "tool", "tool_call_id": "dangling-result", "content": "orphan"],
        ]

        let preserved = NativeContextBudget.preserveToolPairIntegrity(messages)
        let serialized = String(describing: preserved)

        XCTAssertTrue(serialized.contains("paired"))
        XCTAssertFalse(serialized.contains("dangling-call"))
        XCTAssertFalse(serialized.contains("dangling-result"))
    }

    func testTaskInvocationPresentationShowsSubagentDetails() {
        let presentation = TaskInvocationPresentation.parse(
            inputJSON: #"{"type":"explore","description":"Inspect calendar files","prompt":"Find current implementation","cwd":"calendar"}"#
        )

        XCTAssertEqual(presentation?.type, "explore")
        XCTAssertEqual(presentation?.description, "Inspect calendar files")
        XCTAssertEqual(presentation?.prompt, "Find current implementation")
        XCTAssertEqual(presentation?.cwd, "calendar")
        XCTAssertTrue(presentation?.rowTitle(isChinese: true, running: true, failed: false).contains("子 Agent / explore") == true)
    }

    @MainActor
    func testSelectingProjectDoesNotShowDraftSession() {
        let state = makeTestAppState()
        let project = state.projects[0]
        state.startDraftSession(project: project)
        XCTAssertTrue(state.isDraftSessionVisible)

        state.selectProject(project)

        XCTAssertFalse(state.isDraftSessionVisible)
        XCTAssertNil(state.selectedSessionID)
    }

    func testProcessTraceFiltersByAssistantAnchor() {
        let date = Date()
        let first = AgentActivity(
            id: "first",
            sessionId: "session",
            title: "Read",
            detail: "index.html",
            phase: .tool,
            state: .completed,
            createdAt: date,
            updatedAt: date,
            toolName: "Read",
            anchorBlockID: "assistant-1"
        )
        let second = AgentActivity(
            id: "second",
            sessionId: "session",
            title: "Grep",
            detail: "pattern",
            phase: .search,
            state: .running,
            createdAt: date.addingTimeInterval(1),
            updatedAt: date.addingTimeInterval(1),
            toolName: "Grep",
            anchorBlockID: "assistant-2"
        )

        let filtered = AgentActivity.processTraceActivities([first, second], anchoredTo: "assistant-2")

        XCTAssertEqual(filtered.map(\.id), ["second"])
    }

    func testChatScrollPinningStateDetachesAndRepinsByBottomGap() {
        var pinning = ChatScrollPinningState()
        XCTAssertTrue(pinning.shouldFollowOutput)
        XCTAssertTrue(pinning.canAutoFollowOutput(autoScrollToBottom: true))
        XCTAssertFalse(pinning.canAutoFollowOutput(autoScrollToBottom: false))

        pinning.update(bottomY: 480, viewportHeight: 320)
        XCTAssertTrue(pinning.shouldFollowOutput)

        pinning.recordUserScroll(deltaY: 24)
        XCTAssertFalse(pinning.shouldFollowOutput)

        pinning.update(bottomY: 480, viewportHeight: 320)
        XCTAssertFalse(pinning.shouldFollowOutput)

        pinning.update(bottomY: 336, viewportHeight: 320)
        XCTAssertTrue(pinning.shouldFollowOutput)

        let now = Date()
        pinning.recordProgrammaticScroll(now: now)
        pinning.update(bottomY: 360, viewportHeight: 320, now: now.addingTimeInterval(0.10))
        XCTAssertTrue(pinning.shouldFollowOutput)

        pinning.update(bottomY: 420, viewportHeight: 320, now: now.addingTimeInterval(0.10))
        XCTAssertTrue(pinning.shouldFollowOutput)
    }

    func testProcessTraceSummaryShowsRunningCommandWithShimmer() {
        let activity = AgentActivity(
            id: "shell",
            sessionId: "session",
            title: "Running Shell",
            detail: #"{"command":"sed -n '1,20p' README.md"}"#,
            phase: .command,
            state: .running,
            createdAt: Date(),
            updatedAt: Date(),
            toolName: "Shell"
        )

        let summary = ProcessTraceSummary.make(activities: [activity], isChinese: true)

        XCTAssertTrue(summary.shouldShimmer)
        XCTAssertEqual(summary.runningActivityID, "shell")
        XCTAssertTrue(summary.text.contains("正在执行"))
        XCTAssertTrue(summary.text.contains("sed -n"))

        let write = AgentActivity(
            id: "write",
            sessionId: "session",
            title: "Running Write",
            detail: #"{"path":"styles.css"}"#,
            phase: .edit,
            state: .running,
            createdAt: Date(),
            updatedAt: Date(),
            toolName: "Write"
        )
        let writeSummary = ProcessTraceSummary.make(activities: [write], isChinese: true)
        XCTAssertTrue(writeSummary.shouldShimmer)
        XCTAssertTrue(writeSummary.text.contains("正在写入"))
        XCTAssertTrue(writeSummary.text.contains("styles.css"))

        let streaming = AgentActivity(
            id: "streaming",
            sessionId: "session",
            title: "正在接收响应",
            detail: "正在流式输出助手回复",
            phase: .status,
            state: .running,
            createdAt: Date(),
            updatedAt: Date(),
            toolName: nil
        )
        let streamingSummary = ProcessTraceSummary.make(activities: [streaming], isChinese: true)
        XCTAssertTrue(streamingSummary.shouldShimmer)
        XCTAssertTrue(streamingSummary.text.contains("正在接收响应"))

        let question = AgentActivity(
            id: "ask",
            sessionId: "session",
            title: "已询问 2 个问题",
            detail: "User has answered your questions.",
            phase: .status,
            state: .completed,
            createdAt: Date(),
            updatedAt: Date(),
            toolName: "AskQuestion",
            detailMessages: ["questions_count=2"]
        )
        let questionSummary = ProcessTraceSummary.make(activities: [question], isChinese: true)
        XCTAssertFalse(questionSummary.shouldShimmer)
        XCTAssertTrue(questionSummary.text.contains("已询问 2 个问题"))

        let todo = AgentActivity(
            id: "todo",
            sessionId: "session",
            title: "Running TodoWrite",
            detail: #"{"todos":[{"content":"Ship","status":"in_progress"}]}"#,
            phase: .todo,
            state: .running,
            createdAt: Date(),
            updatedAt: Date(),
            toolName: "TodoWrite"
        )
        let todoSummary = ProcessTraceSummary.make(activities: [todo], isChinese: true)
        XCTAssertTrue(todoSummary.shouldShimmer)
        XCTAssertTrue(todoSummary.text.contains("正在更新 Todo List"))
    }

    func testAgentLoopWatchdogUsesProgressNotFixedIterationLimit() {
        var watchdog = AgentLoopWatchdog()
        for _ in 0..<(AgentLoopWatchdog.maxDuplicateOnlyTurns - 1) {
            XCTAssertEqual(
                watchdog.recordDuplicateOnlyTurn(),
                .continueWithNudge("""
                The previous tool request was a duplicate and was skipped. Do not repeat the exact same tool call.
                Inspect the current file state if needed, update TodoWrite for real progress changes, or continue with the next distinct implementation or verification step.
                """)
            )
        }
        if case .pauseNeedsUser(let message) = watchdog.recordDuplicateOnlyTurn() {
            XCTAssertTrue(message.contains("repeated the same tool request"))
        } else {
            XCTFail("Expected duplicate-only watchdog to pause without throwing a transport error.")
        }

        watchdog.recordProgress()
        for _ in 0..<(AgentLoopWatchdog.maxDuplicateOnlyTurns - 1) {
            if case .continueWithNudge = watchdog.recordDuplicateOnlyTurn() {
                XCTAssertTrue(true)
            } else {
                XCTFail("Expected duplicate-only watchdog to continue before the pause threshold.")
            }
        }

        var errorWatchdog = AgentLoopWatchdog()
        let result = AgentToolResult(callId: "1", toolName: "Shell", output: "same failure", isError: true)
        XCTAssertNil(errorWatchdog.recordToolResult(result))
        XCTAssertNil(errorWatchdog.recordToolResult(result))
        XCTAssertNotNil(errorWatchdog.recordToolResult(result))
        XCTAssertNil(errorWatchdog.recordToolResult(AgentToolResult(callId: "policy", toolName: "Shell", output: "Plan mode skipped this write-capable shell command.", isError: false, isPolicyBlock: true)))
        XCTAssertNil(errorWatchdog.recordToolResult(AgentToolResult(callId: "2", toolName: "Shell", output: "ok", isError: false)))
    }

    @MainActor
    func testComposerRunModeStaysPlanAfterSendUntilPlanDecision() {
        let state = makeTestAppState()
        state.composerRunMode = .plan

        let requested = state.consumeComposerRunModeForSend()

        XCTAssertEqual(requested, .plan)
        XCTAssertEqual(state.composerRunMode, .plan)

        let refineID = UUID()
        state.pendingPermissions = [
            PermissionRequest(
                id: refineID,
                sessionId: "session",
                toolName: "SwitchMode",
                inputJSON: #"{"mode":"agent","plan":"Ship it."}"#,
                reason: "Plan approval is required before leaving Plan mode.",
                scope: .session,
                createdAt: Date(),
                kind: .exitPlanMode
            ),
        ]
        state.approvePermission(refineID, updatedInputJSON: #"{"mode":"plan","userFeedback":"revise"}"#)
        XCTAssertEqual(state.composerRunMode, .plan)

        let executeID = UUID()
        state.pendingPermissions = [
            PermissionRequest(
                id: executeID,
                sessionId: "session",
                toolName: "SwitchMode",
                inputJSON: #"{"mode":"agent","plan":"Ship it."}"#,
                reason: "Plan approval is required before leaving Plan mode.",
                scope: .session,
                createdAt: Date(),
                kind: .exitPlanMode
            ),
        ]
        state.approvePermission(executeID, updatedInputJSON: #"{"mode":"agent","plan":"Ship it."}"#)

        XCTAssertEqual(state.composerRunMode, .agent)
    }

    func testSkillToolPlanPolicyRemainsAvailableForLegacyFallbacks() {
        let tools = NativeToolRouter.openAITools()
        let names = tools.compactMap { tool -> String? in
            guard let function = tool["function"] as? [String: Any] else { return nil }
            return function["name"] as? String
        }
        XCTAssertTrue(names.contains("Skill"))

        let context = AgentRunContext(request: agentRequest(runMode: .plan))
        let call = AgentToolCall(
            id: "call-skill",
            name: "Skill",
            inputJSON: #"{"skill":"code-review","args":"review"}"#
        )
        XCTAssertEqual(NativeToolRouter.permissionPolicy(for: call, context: context), .allow)
    }

    func testLowercaseSkillToolNameIsCanonicalizedBeforeExecution() async throws {
        let root = try makeAgentWorkspace("pilotdeck-agent-lowercase-skill")
        defer { try? FileManager.default.removeItem(at: root) }
        let skillDir = root
            .appendingPathComponent(".pilotdeck", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("demo-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try """
        ---
        name: demo-skill
        description: Demo skill for native tests.
        ---
        Use this skill for tests.
        """.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let request = agentRequest(projectPath: root.path)
        let context = AgentRunContext(request: request)
        let call = AgentToolCall(
            id: "call-lowercase-skill",
            name: "skill",
            inputJSON: #"{"skill":"demo-skill","args":"demo"}"#
        )

        let result = await NativeToolRouter.execute(call: call, context: context)

        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.toolName, "Skill")
        XCTAssertTrue(result.output.contains("demo-skill"))
        XCTAssertTrue(context.invokedSkills.contains("demo-skill"))
    }

    func testShellInputAliasIsCanonicalizedToCommand() {
        let call = AgentToolCall(
            id: "call-bash-input",
            name: "bash",
            inputJSON: #"{"input":"python3 scripts/search.py --query \"DARPA\"","timeout_seconds":30}"#
        )

        let normalized = ToolArgumentNormalizer.normalize(call)

        XCTAssertNil(normalized.recoveryResult)
        XCTAssertEqual(normalized.call.name, "Shell")
        let object = try? JSONSerialization.jsonObject(with: Data(normalized.call.inputJSON.utf8)) as? [String: Any]
        XCTAssertEqual(object?["command"] as? String, #"python3 scripts/search.py --query "DARPA""#)
        XCTAssertFalse(normalized.call.inputJSON.contains(#""input":"#))
    }

    func testShellXMLParameterWrapperIsRemovedFromCommand() {
        let call = AgentToolCall(
            id: "call-bash-xml",
            name: "Shell",
            inputJSON: #"{"command":"<parameter>\npython3 scripts/search.py --query \"DARPA autonomous systems research\""}"#
        )

        let normalized = ToolArgumentNormalizer.normalize(call)

        XCTAssertNil(normalized.recoveryResult)
        let object = try? JSONSerialization.jsonObject(with: Data(normalized.call.inputJSON.utf8)) as? [String: Any]
        XCTAssertEqual(
            object?["command"] as? String,
            #"python3 scripts/search.py --query "DARPA autonomous systems research""#
        )
    }

    func testSkillRuntimeLoadsProjectSkillWithoutPluginEnvironment() throws {
        let root = try makeAgentWorkspace("pilotdeck-project-skill")
        defer { try? FileManager.default.removeItem(at: root) }
        let skillDir = root
            .appendingPathComponent(".pilotdeck", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("research", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try """
        ---
        name: research
        description: Project research skill.
        allowed-tools:
          - Read
          - WebSearch
        ---
        Use WebSearch for current web evidence when needed.
        """.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let request = agentRequest(projectPath: root.path)
        let context = AgentRunContext(request: request)
        let output = try SkillRuntimeService.load(
            inputJSON: #"{"skill":"research","args":"Beijing weather"}"#,
            context: context
        )

        XCTAssertTrue(output.contains("Project research skill"))
        XCTAssertTrue(output.contains("WebSearch"))
        XCTAssertTrue(context.invokedSkills.contains("research"))

        let environment = SkillRuntimeService.environment(configValues: request.nativeConfigValues)
        XCTAssertNil(environment["CLAU" + "DE_PLUGIN_ROOT"])
    }

    func testMacNativeCodeDoesNotContainOldBrandNames() throws {
        let root = repoRootURL()
        let scanRoots = [
            root.appendingPathComponent("apps/macos-native", isDirectory: true),
        ]
        let forbidden = [
            "9" + "GClaw",
            "9" + "gclaw",
            "Nine" + "GClaw",
            "Clau" + "de",
            "clau" + "de",
            "CLAU" + "DE",
            "Edge" + "Claw",
            "edge" + "claw",
            "EDGE" + "CLAW",
        ]
        let scannedExtensions: Set<String> = ["swift", "md", "yaml", "yml", "json", "plist", "pbxproj", "entitlements", "py", "sh"]
        var hits: [String] = []

        for scanRoot in scanRoots {
            guard let enumerator = FileManager.default.enumerator(
                at: scanRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: []
            ) else { continue }
            for case let fileURL as URL in enumerator {
                let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { continue }
                let ext = fileURL.pathExtension
                if !ext.isEmpty, !scannedExtensions.contains(ext) { continue }
                guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
                for token in forbidden where contents.contains(token) {
                    hits.append("\(fileURL.path): \(token)")
                }
            }
        }

        XCTAssertTrue(hits.isEmpty, hits.joined(separator: "\n"))
    }

    func testRouterChoosesTierModelWithoutDARPAHardcoding() {
        let yaml = """
        models:
          providers:
            pilotdeck:
              type: openai-chat
              baseUrl: http://example.local/v1
              apiKey: test
          entries:
            default:
              provider: pilotdeck
              name: qwen3.6-27b
            router_small:
              provider: pilotdeck
              name: qwen3.6-35b-a3b
        router:
          enabled: true
          routes:
            default:
              model: default
          tokenSaver:
            tiers:
              SIMPLE:
                model: router_small
              MEDIUM:
                model: router_small
              COMPLEX:
                model: default
        """
        let values = NativeConfigService.scalarMap(from: yaml)
        XCTAssertEqual(NativeRouterRuntime.entryID(forTier: "SIMPLE", values: values), "router_small")
        XCTAssertFalse(values.keys.contains { $0.lowercased().contains("darpa") })
    }

    func testRouterRuntimeMatchesLegacyScenarioPriorityWhenTokenSaverIsOff() {
        let yaml = """
        models:
          providers:
            pilotdeck:
              type: openai-chat
              baseUrl: http://example.local/v1
          entries:
            default:
              provider: pilotdeck
              name: default-model
            background_entry:
              provider: pilotdeck
              name: background-model
            think_entry:
              provider: pilotdeck
              name: think-model
            long_entry:
              provider: pilotdeck
              name: long-model
            web_entry:
              provider: pilotdeck
              name: web-model
            simple_entry:
              provider: pilotdeck
              name: simple-model
        router:
          enabled: true
          routes:
            default:
              model: default
            background:
              model: background_entry
            think:
              model: think_entry
            longContext:
              model: long_entry
            webSearch:
              model: web_entry
            longContextThreshold: 60000
          tokenSaver:
            enabled: false
            tiers:
              SIMPLE:
                model: simple_entry
        """
        let values = NativeConfigService.scalarMap(from: yaml)

        let longContextDecision = NativeRouterRuntime.decision(
            forTier: "SIMPLE",
            values: values,
            tokenCount: 70_000,
            isBackgroundRequest: true,
            hasWebSearchTools: true,
            hasThinking: true
        )
        XCTAssertEqual(longContextDecision.entryID, "long_entry")
        XCTAssertEqual(longContextDecision.scenario, "longContext")
        XCTAssertNil(longContextDecision.tier)
        XCTAssertEqual(
            NativeRouterRuntime.decision(forTier: "SIMPLE", values: values, isBackgroundRequest: true).scenario,
            "background"
        )
        XCTAssertEqual(
            NativeRouterRuntime.decision(forTier: "SIMPLE", values: values, hasWebSearchTools: true).entryID,
            "web_entry"
        )
        XCTAssertEqual(
            NativeRouterRuntime.decision(forTier: "SIMPLE", values: values, hasThinking: true).entryID,
            "think_entry"
        )
        XCTAssertEqual(NativeRouterRuntime.decision(forTier: "SIMPLE", values: values).entryID, "default")
    }

    func testRouterRuntimeRequestSignalsFeedWebStyleLongContextAndToolRouting() {
        let yaml = """
        models:
          providers:
            pilotdeck:
              type: openai-chat
              baseUrl: http://example.local/v1
          entries:
            default:
              provider: pilotdeck
              name: default-model
            long_entry:
              provider: pilotdeck
              name: long-model
            web_entry:
              provider: pilotdeck
              name: web-model
        router:
          enabled: true
          routes:
            default:
              model: default
            longContext:
              model: long_entry
            webSearch:
              model: web_entry
            longContextThreshold: 1000
        """
        let values = NativeConfigService.scalarMap(from: yaml)
        let history = [
            ChatMessage(
                id: UUID(),
                sessionId: "router-session",
                provider: .pilotDeck,
                role: .user,
                blocks: [.text(String(repeating: "h", count: 2_500))],
                createdAt: Date(),
                isStreaming: false,
                tokenBudget: nil
            ),
        ]
        let longSignals = NativeRouterRuntime.requestSignals(
            prompt: String(repeating: "p", count: 2_500),
            priorMessages: history,
            attachments: [],
            tools: []
        )

        XCTAssertGreaterThan(longSignals.tokenCount, 1_000)
        XCTAssertEqual(
            NativeRouterRuntime.decision(forTier: "SIMPLE", values: values, signals: longSignals).scenario,
            "longContext"
        )

        let webSearchTool: [[String: Any]] = [
            [
                "type": "web_search_preview",
                "name": "web_search_preview",
            ],
        ]
        let webSignals = NativeRouterRuntime.requestSignals(
            prompt: "Search current public sources",
            priorMessages: [],
            attachments: [],
            tools: webSearchTool
        )

        XCTAssertTrue(webSignals.hasWebSearchTools)
        XCTAssertEqual(
            NativeRouterRuntime.decision(forTier: "SIMPLE", values: values, signals: webSignals).scenario,
            "webSearch"
        )

        let stableFunctionSignals = NativeRouterRuntime.requestSignals(
            prompt: "Normal request with the built-in WebSearch adapter available",
            priorMessages: [],
            attachments: [],
            tools: AgentToolRegistry.openAITools()
        )
        XCTAssertFalse(stableFunctionSignals.hasWebSearchTools)
    }

    func testRouterRuntimeRequestSignalTokenEstimateIncludesToolSchemasAndImageAttachments() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("g9-router-signals-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let imageURL = tempDir.appendingPathComponent("diagram.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)
        let imageAttachment = FileAttachment(
            id: UUID(),
            fileName: "diagram.png",
            path: imageURL.path,
            mimeType: "image/png"
        )
        let smallSignals = NativeRouterRuntime.requestSignals(
            prompt: "short",
            priorMessages: [],
            attachments: [],
            tools: []
        )
        let richSignals = NativeRouterRuntime.requestSignals(
            prompt: "short",
            priorMessages: [],
            attachments: [imageAttachment],
            tools: [
                [
                    "type": "function",
                    "function": [
                        "name": "HugeTool",
                        "description": String(repeating: "d", count: 4_000),
                        "parameters": [
                            "type": "object",
                            "properties": [
                                "query": ["type": "string", "description": String(repeating: "q", count: 1_000)],
                            ],
                        ],
                    ],
                ],
            ]
        )

        XCTAssertFalse(smallSignals.hasWebSearchTools)
        XCTAssertGreaterThanOrEqual(richSignals.tokenCount - smallSignals.tokenCount, 3_000)
    }

    func testRouterRuntimeResolvesBackgroundProviderRouteForSubagents() {
        let yaml = """
        runtime:
          contextWindow: 120000
        models:
          providers:
            main:
              type: openai-chat
              baseUrl: http://main.local/v1
              apiKey: main-secret
            background:
              type: openai-chat
              baseUrl: http://background.local/v1
              apiKey: background-secret
          entries:
            default:
              provider: main
              name: main-model
              contextWindow: 160000
            background_entry:
              provider: background
              name: background-model
              contextWindow: 64000
        agents:
          main:
            model: default
        router:
          enabled: true
          routes:
            default:
              model: default
            background:
              model: background_entry
        """
        let values = NativeConfigService.scalarMap(from: yaml)
        let fallbackProvider = ProviderConfig(
            provider: .pilotDeck,
            apiType: .openAIChat,
            baseURL: "http://fallback.local/v1",
            model: "fallback-model",
            secretAccount: "fallback",
            headers: [:]
        )
        let route = NativeRouterRuntime.resolvedProviderRoute(
            forTier: "COMPLEX",
            values: values,
            fallbackProviderConfig: fallbackProvider,
            fallbackAPIKey: "fallback-secret",
            fallbackContextWindow: 32_000,
            signals: NativeRouterRuntime.RequestSignals(
                tokenCount: 0,
                isBackgroundRequest: true,
                hasWebSearchTools: false,
                hasThinking: false
            )
        )

        XCTAssertEqual(route.decision.scenario, "background")
        XCTAssertEqual(route.providerConfig.baseURL, "http://background.local/v1")
        XCTAssertEqual(route.providerConfig.model, "background-model")
        XCTAssertEqual(route.apiKey, "background-secret")
        XCTAssertEqual(route.contextWindow, 64_000)
    }

    func testRouterRuntimeTokenSaverTakesOverLikeWebRouterWhenEnabled() {
        let yaml = """
        models:
          providers:
            pilotdeck:
              type: openai-chat
              baseUrl: http://example.local/v1
          entries:
            default:
              provider: pilotdeck
              name: default-model
            simple_entry:
              provider: pilotdeck
              name: simple-model
            long_entry:
              provider: pilotdeck
              name: long-model
            web_entry:
              provider: pilotdeck
              name: web-model
        router:
          enabled: true
          routes:
            default:
              model: default
            longContext:
              model: long_entry
            webSearch:
              model: web_entry
            longContextThreshold: 60000
          tokenSaver:
            enabled: true
            tiers:
              SIMPLE:
                model: simple_entry
        """
        let values = NativeConfigService.scalarMap(from: yaml)

        let decision = NativeRouterRuntime.decision(
            forTier: "SIMPLE",
            values: values,
            tokenCount: 100_000,
            hasWebSearchTools: true
        )

        XCTAssertEqual(decision.entryID, "simple_entry")
        XCTAssertEqual(decision.scenario, "tokenSaver")
        XCTAssertEqual(decision.tier, "simple")
    }

    func testRouterRuntimeMarksAutoOrchestrateExtensionPointForComplexTiers() {
        let yaml = """
        models:
          providers:
            pilotdeck:
              type: openai-chat
              baseUrl: http://example.local/v1
          entries:
            default:
              provider: pilotdeck
              name: default-model
            complex_entry:
              provider: pilotdeck
              name: complex-model
            orchestrator_entry:
              provider: pilotdeck
              name: orchestrator-model
        router:
          enabled: true
          tokenSaver:
            enabled: true
            tiers:
              complex:
                model: complex_entry
          autoOrchestrate:
            enabled: true
            mainAgentModel: orchestrator_entry
        """
        let values = NativeConfigService.scalarMap(from: yaml)

        let decision = NativeRouterRuntime.decision(forTier: "complex", values: values)

        XCTAssertEqual(decision.entryID, "orchestrator_entry")
        XCTAssertEqual(decision.tier, "complex")
        XCTAssertTrue(decision.orchestrating)
        XCTAssertEqual(decision.model, "orchestrator-model")
    }

    func testRouterRuntimeFallsBackToDefaultForDisabledRouterOrMissingEntries() {
        let yaml = """
        models:
          providers:
            pilotdeck:
              type: openai-chat
              baseUrl: http://example.local/v1
          entries:
            default:
              provider: pilotdeck
              name: default-model
        router:
          enabled: false
          routes:
            default:
              model: default
            webSearch:
              model: missing_entry
          tokenSaver:
            enabled: true
            tiers:
              SIMPLE:
                model: missing_entry
        """
        let disabledValues = NativeConfigService.scalarMap(from: yaml)

        let disabledSignalsDecision = NativeRouterRuntime.decision(
            forTier: "SIMPLE",
            values: disabledValues,
            tokenCount: 100_000,
            hasWebSearchTools: true
        )
        XCTAssertEqual(disabledSignalsDecision.entryID, "default")
        XCTAssertEqual(disabledSignalsDecision.scenario, "default")
        XCTAssertNil(disabledSignalsDecision.tier)

        let enabledValues = NativeConfigService.scalarMap(from: yaml.replacingOccurrences(of: "enabled: false", with: "enabled: true"))
        XCTAssertEqual(NativeRouterRuntime.decision(forTier: "SIMPLE", values: enabledValues, hasWebSearchTools: true).entryID, "default")
    }

    func testRoutingDashboardSessionKeepsStructuredRouteTraceAndLegacyCompatibility() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let legacyJSON = """
        {
          "id": "legacy-session",
          "title": "Legacy routing",
          "projectName": "general",
          "lastActiveAt": "2026-05-17T08:00:00Z",
          "totalTokens": 5120,
          "estimatedCost": 0.004,
          "savedCost": 0.002,
          "byTier": {
            "SIMPLE": { "count": 1, "totalTokens": 5120 }
          },
          "byModel": {
            "qwen3.6-35b-a3b": { "count": 1, "totalTokens": 5120 }
          },
          "requestLog": [
            "16:00:00 default -> qwen3.6-35b-a3b routed as SIMPLE",
            "16:00:01 qwen3.6-35b-a3b usage · SIMPLE · 5120/160000 tokens"
          ]
        }
        """

        let legacy = try decoder.decode(RoutingDashboardSession.self, from: Data(legacyJSON.utf8))

        XCTAssertEqual(legacy.total.totalTokens, 5120)
        XCTAssertEqual(legacy.total.estimatedCost, 0.004)
        XCTAssertEqual(legacy.total.savedCost, 0.002)
        XCTAssertEqual(legacy.requestLog.count, 2)
        XCTAssertTrue(legacy.requestEntries.isEmpty)

        let structuredJSON = """
        {
          "id": "structured-session",
          "title": "Weather site",
          "projectName": "general",
          "lastActiveAt": "2026-05-17T08:05:00Z",
          "totalTokens": 12000,
          "estimatedCost": 0.008,
          "savedCost": 0.004,
          "total": {
            "count": 2,
            "requestCount": 2,
            "totalTokens": 12000,
            "estimatedCost": 0.008,
            "baselineCost": 0.012,
            "savedCost": 0.004
          },
          "byTier": {
            "MEDIUM": { "count": 1, "requestCount": 1 }
          },
          "byModel": {
            "qwen3.6-35b-a3b": { "count": 1, "requestCount": 1 },
            "tool:web_search": { "count": 1, "requestCount": 1 }
          },
          "byScenario": {
            "default": { "count": 1, "requestCount": 1 },
            "tool": { "count": 1, "requestCount": 1 }
          },
          "byRole": {
            "main": { "count": 2, "requestCount": 2 }
          },
          "requestLog": [],
          "requestEntries": [
            {
              "id": "route-1",
              "ts": "2026-05-17T08:05:01Z",
              "role": "main",
              "tier": "MEDIUM",
              "model": "qwen3.6-35b-a3b",
              "tokens": 12000,
              "cost": 0.008,
              "baselineCost": 0.012,
              "savedCost": 0.004,
              "query": "Build a weather website",
              "scenario": "default",
              "route": "default"
            },
            {
              "id": "skill-1",
              "ts": "2026-05-17T08:05:02Z",
              "role": "main",
              "model": "tool:web_search",
              "tokens": 0,
              "cost": 0,
              "query": "WebSearch invoked",
              "scenario": "tool",
              "skill": "web_search"
            }
          ]
        }
        """

        let structured = try decoder.decode(RoutingDashboardSession.self, from: Data(structuredJSON.utf8))

        XCTAssertEqual(structured.requestEntries.count, 2)
        XCTAssertEqual(structured.requestEntries.first?.tier, "MEDIUM")
        XCTAssertEqual(structured.requestEntries.first?.query, "Build a weather website")
        XCTAssertEqual(structured.requestEntries.last?.skill, "web_search")
        XCTAssertEqual(structured.byScenario["tool"]?.requestCount, 1)
        XCTAssertEqual(structured.byRole["main"]?.requestCount, 2)
        XCTAssertEqual(structured.total.baselineCost, 0.012)
    }

    func testMainHeaderToolSwitcherLayoutAlwaysShowsPrimaryTabs() {
        for width in [1440.0, 1100.0, 760.0] {
            let layout = MainHeaderToolSwitcherLayout.resolve(
                availableWidth: width,
                activeTab: .memory
            )

            XCTAssertEqual(layout.visibleTabs, AppTab.primaryTabs)
            XCTAssertTrue(layout.overflowTabs.isEmpty)
            XCTAssertFalse(layout.iconOnly)
            XCTAssertEqual(layout.estimatedWidth, 544)
        }
        XCTAssertEqual(MainHeaderToolSwitcherLayout.buttonWidth(for: .chat, iconOnly: false), 82)
        XCTAssertEqual(MainHeaderToolSwitcherLayout.buttonWidth(for: .alwaysOn, iconOnly: false), 118)
        XCTAssertEqual(MainHeaderToolSwitcherLayout.buttonWidth(for: .chat, iconOnly: true), 36)

        let chatOnlyLayout = MainHeaderToolSwitcherLayout.resolve(
            availableWidth: 760,
            activeTab: .chat,
            tabs: [.chat]
        )
        XCTAssertEqual(chatOnlyLayout.visibleTabs, [.chat])
        XCTAssertEqual(chatOnlyLayout.estimatedWidth, 88)
    }

    func testCodeEditorPreferencesDefaultToLineNumbersAndMinimapForNewUsers() {
        XCTAssertTrue(CodeEditorPreferences.defaults.lineNumbers)
        XCTAssertTrue(CodeEditorPreferences.defaults.showMinimap)
        XCTAssertFalse(CodeEditorPreferences.defaults.wordWrap)
        XCTAssertEqual(CodeEditorPreferences.defaults.fontSize, 14)
    }

    func testCodeLineNumberMetricsGrowWithDigitCount() {
        let singleDigit = CodeLineNumberMetrics.rulerWidth(lineCount: 9)
        let doubleDigit = CodeLineNumberMetrics.rulerWidth(lineCount: 99)
        let tripleDigit = CodeLineNumberMetrics.rulerWidth(lineCount: 999)

        XCTAssertEqual(CodeLineNumberMetrics.lineCount(in: ""), 1)
        XCTAssertEqual(CodeLineNumberMetrics.lineCount(in: "one\ntwo\n"), 3)
        XCTAssertEqual(singleDigit, doubleDigit)
        XCTAssertGreaterThan(tripleDigit, doubleDigit)
        XCTAssertEqual(CodeLineNumberMetrics.lineNumber(forCharacterIndex: 0, lineStarts: [0, 4, 8]), 1)
        XCTAssertEqual(CodeLineNumberMetrics.lineNumber(forCharacterIndex: 5, lineStarts: [0, 4, 8]), 2)
    }

    func testCodeLineNumberModeAddsEditorTextInset() {
        let plainInset = CodeLineNumberMetrics.textInset(lineNumbersVisible: false)
        let lineNumberInset = CodeLineNumberMetrics.textInset(lineNumbersVisible: true, lineCount: 687)

        XCTAssertGreaterThan(lineNumberInset.width, plainInset.width)
        XCTAssertGreaterThan(lineNumberInset.width, CodeLineNumberMetrics.rulerWidth(lineCount: 687))
        XCTAssertEqual(lineNumberInset.height, plainInset.height)
    }

    func testWrappedCodeEditorDoesNotPreserveHorizontalOffset() {
        XCTAssertEqual(CodeEditorScrollStabilityMetrics.horizontalOrigin(42, wordWrap: true, maxX: 300), 0)
        XCTAssertEqual(CodeEditorScrollStabilityMetrics.horizontalOrigin(-8, wordWrap: false, maxX: 300), 0)
        XCTAssertEqual(CodeEditorScrollStabilityMetrics.horizontalOrigin(420, wordWrap: false, maxX: 300), 300)
        XCTAssertEqual(CodeEditorScrollStabilityMetrics.horizontalOrigin(120, wordWrap: false, maxX: 300), 120)
    }

    func testCodeMinimapModelSamplesLargeFilesAndTracksViewport() {
        let text = (1...2_400).map { index in
            index.isMultiple(of: 2) ? "    let value\(index) = \(index)" : ""
        }.joined(separator: "\n")

        let model = CodeMinimapModel(text: text, visibleLineRange: 120..<180, maxLines: 600)

        XCTAssertEqual(model.totalLines, 2_400)
        XCTAssertEqual(model.sampleStride, 4)
        XCTAssertLessThanOrEqual(model.lines.count, 600)
        XCTAssertGreaterThan(model.viewportStartFraction, 0.04)
        XCTAssertLessThan(model.viewportStartFraction, 0.06)
        XCTAssertGreaterThan(model.viewportHeightFraction, 0.02)
        XCTAssertTrue(model.lines.contains { !$0.isBlank && $0.indentLevel > 0 })
        XCTAssertEqual(model.lineNumber(atY: 0, height: 600), 1)
        XCTAssertEqual(model.lineNumber(atY: 300, height: 600), 1_201)
        XCTAssertEqual(model.lineNumber(atY: 900, height: 600), 2_400)
    }

    func testProjectCreationWizardUsesCompactMetrics() {
        XCTAssertEqual(ProjectCreationWizardMetrics.maxWidth, 612)
        XCTAssertEqual(ProjectCreationWizardMetrics.formMaxWidth, 520)
        XCTAssertEqual(ProjectCreationWizardMetrics.fieldHeight, 36)
        XCTAssertEqual(ProjectCreationWizardMetrics.browseButtonWidth, 44)
        XCTAssertLessThan(ProjectCreationWizardMetrics.maxWidth, 720)
        XCTAssertLessThan(ProjectCreationWizardMetrics.formMaxWidth, ProjectCreationWizardMetrics.maxWidth)
        XCTAssertLessThan(ProjectCreationWizardMetrics.contentMinHeight, 324)
        XCTAssertLessThan(ProjectCreationWizardMetrics.typeCardMinHeight, 132)
        XCTAssertEqual(ProjectCreationWizardMetrics.footerHeight, 54)
    }

    func testPlanConfirmationCardUsesBluePlanAreaAndVerticalChoices() {
        XCTAssertEqual(PlanConfirmationCardMetrics.planMinHeight, 220)
        XCTAssertEqual(PlanConfirmationCardMetrics.planMaxHeight, 460)
        XCTAssertEqual(PlanConfirmationCardMetrics.actionLayout, "execute-feedback-footer")
        XCTAssertEqual(PlanConfirmationCardMetrics.actionRowHeight, 38)
        XCTAssertEqual(PlanConfirmationCardMetrics.footerButtonCount, 2)
        XCTAssertTrue(PlanConfirmationCardMetrics.emptyPlanFallbackZH.contains("同步"))
    }

    func testEditorHeaderToolbarUsesNeutralIconButtons() {
        XCTAssertEqual(EditorHeaderToolbarMetrics.iconButtonSize, 28)
        XCTAssertEqual(EditorHeaderToolbarMetrics.iconFontSize, 13.5)
        XCTAssertFalse(EditorHeaderToolbarMetrics.usesProminentSaveButton)
    }

    func testCodeEditorScrollStabilityMetricsEnableMinimapDraggingAndThrottleViewport() {
        XCTAssertTrue(CodeEditorScrollStabilityMetrics.minimapAllowsHitTesting)
        XCTAssertTrue(CodeEditorScrollStabilityMetrics.preservesScrollOriginOnUpdate)
        XCTAssertTrue(CodeEditorScrollStabilityMetrics.editorBodyClipsRulerToContent)
        XCTAssertGreaterThanOrEqual(CodeEditorScrollStabilityMetrics.visibleRangePublishInterval, 0.06)
        XCTAssertEqual(CodeEditorScrollStabilityMetrics.minimapViewportMinHeight, 18)
    }

    func testCodeSyntaxHighlightingMapsCommonEditorLanguages() {
        XCTAssertEqual(CodeSyntaxHighlightingService.languageAlias(forFileName: "index.html"), "html")
        XCTAssertEqual(CodeSyntaxHighlightingService.languageAlias(forFileName: "main.py"), "python")
        XCTAssertEqual(CodeSyntaxHighlightingService.languageAlias(forFileName: "style.css"), "css")
        XCTAssertEqual(CodeSyntaxHighlightingService.languageAlias(forFileName: "app.tsx"), "typescript")
        XCTAssertEqual(CodeSyntaxHighlightingService.languageAlias(forFileName: "Package.swift"), "swift")
        XCTAssertEqual(CodeSyntaxHighlightingService.languageAlias(forFileName: "config.json"), "json")
        XCTAssertEqual(CodeSyntaxHighlightingService.languageAlias(forFileName: "README.md"), "markdown")
        XCTAssertEqual(CodeSyntaxHighlightingService.languageAlias(forFileName: "script.zsh"), "bash")
        XCTAssertNil(CodeSyntaxHighlightingService.languageAlias(forFileName: "archive.unknown"))
    }

    func testCodeSyntaxHighlightingUsesDarkLightThemesAndLargeFileGuard() {
        XCTAssertEqual(CodeSyntaxHighlightingService.themeName(isDarkMode: false), "xcode")
        XCTAssertEqual(CodeSyntaxHighlightingService.themeName(isDarkMode: true), "tokyoNight")
        XCTAssertTrue(CodeSyntaxHighlightingService.shouldHighlight("<main></main>", languageAlias: "html"))
        XCTAssertFalse(CodeSyntaxHighlightingService.shouldHighlight("", languageAlias: "html"))
        XCTAssertFalse(CodeSyntaxHighlightingService.shouldHighlight("let x = 1", languageAlias: nil))
        XCTAssertFalse(CodeSyntaxHighlightingService.shouldHighlight(String(repeating: "a", count: CodeSyntaxHighlightingService.maxHighlightedCharacters + 1), languageAlias: "python"))
    }

    func testCodeSyntaxHighlightingProducesVisibleEditorColors() async throws {
        let highlighted = try await CodeSyntaxHighlightingService.highlightedText(
            "<!DOCTYPE html>\n<html><style>body { color: #fff; }</style></html>",
            languageAlias: "html",
            isDarkMode: false
        )
        let attributed = NSAttributedString(highlighted)
        var colors = Set<String>()
        attributed.enumerateAttribute(
            .foregroundColor,
            in: NSRange(location: 0, length: attributed.length),
            options: []
        ) { value, _, _ in
            guard let color = value as? NSColor else { return }
            colors.insert(color.usingColorSpace(.sRGB)?.description ?? color.description)
        }

        XCTAssertGreaterThan(colors.count, 1)
    }

    func testFilePreviewActionPolicyMatchesRequestedPreviewSurface() {
        let html = WorkspaceFile(
            id: "index",
            name: "index.html",
            path: "/tmp/index.html",
            relativePath: "index.html",
            depth: 0,
            isDirectory: false,
            isExpanded: false,
            modifiedAt: nil,
            byteCount: nil
        )
        let markdown = WorkspaceFile(
            id: "readme",
            name: "README.md",
            path: "/tmp/README.md",
            relativePath: "README.md",
            depth: 0,
            isDirectory: false,
            isExpanded: false,
            modifiedAt: nil,
            byteCount: nil
        )
        let pdf = WorkspaceFile(
            id: "paper",
            name: "paper.pdf",
            path: "/tmp/paper.pdf",
            relativePath: "paper.pdf",
            depth: 0,
            isDirectory: false,
            isExpanded: false,
            modifiedAt: nil,
            byteCount: nil
        )

        XCTAssertEqual(FilePreviewActionPolicy.treePreviewIcon(for: html), "globe")
        XCTAssertFalse(FilePreviewActionPolicy.editorShowsHTMLPreview(for: html))
        XCTAssertEqual(FilePreviewActionPolicy.editorPreviewToggleIcon(for: markdown, isPreviewing: false), "doc.richtext")
        XCTAssertEqual(FilePreviewActionPolicy.editorPreviewToggleIcon(for: markdown, isPreviewing: true), "pencil")
        XCTAssertTrue(FilePreviewActionPolicy.usesNativePDFPreview(for: pdf))
        XCTAssertTrue(pdf.isPDF)
    }

    func testProcessToolPresentationClassifierUsesExactCanonicalTools() {
        XCTAssertEqual(AgentToolPresentationClassifier.phase(forToolName: "Task"), .subagent)
        XCTAssertEqual(AgentToolPresentationClassifier.phase(forToolName: "Agent"), .subagent)
        XCTAssertEqual(AgentToolPresentationClassifier.phase(forToolName: "Shell"), .command)
        XCTAssertEqual(AgentToolPresentationClassifier.phase(forToolName: "Glob"), .search)
        XCTAssertEqual(AgentToolPresentationClassifier.phase(forToolName: "SemanticSearch"), .search)
        XCTAssertEqual(AgentToolPresentationClassifier.phase(forToolName: "TodoRead"), .todo)
        XCTAssertEqual(AgentToolPresentationClassifier.phase(forToolName: "TodoWrite"), .todo)
        XCTAssertEqual(AgentToolPresentationClassifier.phase(forToolName: "ReadLints"), .tool)

        let mixedPhases = ["Task", "Shell"].map(AgentToolPresentationClassifier.phase(forToolName:))
        XCTAssertFalse(mixedPhases.contains(.search))
    }

    @MainActor
    func testPendingPermissionsAreScopedToSelectedSession() {
        let state = makeTestAppState()
        state.selectedSessionID = "current-session"
        state.pendingPermissions = [
            PermissionRequest(
                id: UUID(),
                sessionId: "other-session",
                toolName: "AskQuestion",
                inputJSON: "{}",
                reason: "Other session question",
                scope: .session,
                createdAt: Date(),
                kind: .askUserQuestion
            ),
            PermissionRequest(
                id: UUID(),
                sessionId: "current-session",
                toolName: "AskQuestion",
                inputJSON: "{}",
                reason: "Current session question",
                scope: .session,
                createdAt: Date(),
                kind: .askUserQuestion
            ),
        ]

        XCTAssertEqual(state.currentPendingPermissions.map(\.reason), ["Current session question"])
    }

    @MainActor
    func testStartingDraftSessionClearsVisibleErrorBanner() {
        let state = makeTestAppState()
        let project = project(name: "demo", displayName: "Demo", date: Date())
        state.projects = [project]
        state.selectedProjectID = project.id
        state.errorBanner = "Provider failed in another conversation."

        state.startDraftSession(project: project)

        XCTAssertNil(state.errorBanner)
    }

    func testUnsupportedAPITypeMessageDoesNotSayPilotDeckIsUnimplemented() {
        let message = ProviderClientError.unsupportedAPIType(.anthropicMessages).errorDescription ?? ""

        XCTAssertTrue(message.contains("OpenAI-compatible chat"))
        XCTAssertFalse(message.contains("not implemented yet in native AgentCore"))
    }

    @MainActor
    func testOpenSettingsStoresInitialTabWithoutShowingOverlay() {
        let state = makeTestAppState()

        state.showSettings = false
        state.openSettings(.config)

        XCTAssertEqual(state.settingsInitialTab, .config)
        XCTAssertFalse(state.showSettings)
    }

    @MainActor
    private func makeTestAppState() -> AppState {
        let settingsURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pilotdeck-test-settings-\(UUID().uuidString).json")
        return AppState(settingsStore: AppSettingsStore(url: settingsURL))
    }

    private func project(name: String, displayName: String, date: Date) -> WorkspaceProject {
        WorkspaceProject(
            id: UUID(),
            name: name,
            displayName: displayName,
            rootPath: "/Users/tester/\(name)",
            sessions: [],
            codexSessions: [],
            cursorSessions: [],
            geminiSessions: [],
            createdAt: date,
            lastActivity: date
        )
    }

    private func agentRequest(
        projectPath: String = NSTemporaryDirectory(),
        prompt: String = "test",
        priorMessages: [ChatMessage] = [],
        runMode: ChatRunMode = .agent,
        permissionMode: ComposerPermissionMode = .default,
        toolSettings: ToolPermissionSettings = .defaults,
        nativeConfigValues: [String: String] = [:]
    ) -> AgentRequest {
        AgentRequest(
            sessionId: "test-session",
            projectPath: projectPath,
            prompt: prompt,
            providerConfig: ProviderConfig(
                provider: .pilotDeck,
                apiType: .openAIChat,
                baseURL: "http://example.local/v1",
                model: "qwen3.6-27b",
                secretAccount: "test",
                headers: [:]
            ),
            apiKey: "test-key",
            priorMessages: priorMessages,
            timeoutMs: 1_000,
            contextWindow: 160_000,
            permissionMode: permissionMode,
            runMode: runMode,
            workspaceContext: nil,
            toolSettings: toolSettings,
            routerRoute: "default",
            nativeConfigValues: nativeConfigValues,
            permissionHandler: nil
        )
    }

    private func makeAgentWorkspace(_ prefix: String) throws -> URL {
        let root = repoRootURL()
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func jsonObject(from value: String) throws -> [String: Any] {
        let data = try XCTUnwrap(value.data(using: .utf8))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func toolJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private func writeTinyPNG(to url: URL) throws {
        let base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        try data.write(to: url)
    }

    private func writeMinimalPDF(to url: URL) throws {
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 200)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        try (data as Data).write(to: url)
    }

    private func temporaryDirectory(_ prefix: String) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeSkillArchive(name: String, description: String) throws -> Data {
        let root = temporaryDirectory("pilotdeck-skill-archive")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try """
        ---
        name: \(name)
        description: \(description)
        ---

        # \(name)
        """.write(to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "fixture".write(to: source.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let archive = root.appendingPathComponent("skill.zip")
        try runTestProcess(executable: "/usr/bin/ditto", args: ["-c", "-k", source.path, archive.path])
        return try Data(contentsOf: archive)
    }

    private func writeProjectSkill(projectRoot: URL, slug: String, name: String, description: String) throws -> URL {
        let skillDir = projectRoot
            .appendingPathComponent(".pilotdeck", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try """
        ---
        name: \(name)
        description: \(description)
        ---

        # \(name)

        The CLI is at `scripts/\(slug)`. Invoke it from this skill directory.
        """.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return skillDir
    }

    private func writeUserSkill(slug: String, name: String, description: String) throws -> URL {
        let skillDir = SkillsService.userSkillsRoot()
            .appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try """
        ---
        name: \(name)
        description: \(description)
        ---

        # \(name)

        This is a test user skill.
        """.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return skillDir
    }

    private func serviceRecord(for skillDir: URL, scope: SkillScope) -> SkillRecord? {
        let skillFile = skillDir.appendingPathComponent("SKILL.md")
        guard let content = try? String(contentsOf: skillFile, encoding: .utf8) else { return nil }
        let fm = SkillsService.frontmatter(from: content)
        return SkillRecord(
            id: UUID(),
            slug: skillDir.lastPathComponent,
            name: fm["name"] ?? skillDir.lastPathComponent,
            description: fm["description"] ?? "",
            version: fm["version"],
            skillDir: skillDir.path,
            skillFile: skillFile.path,
            scope: scope,
            mtime: nil,
            enabled: true
        )
    }

    private func runTestProcess(executable: String, args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "ParityLogicTests", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: stderr])
        }
    }

    private func repoRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private final class MockSkillHubClient: SkillHubClient, @unchecked Sendable {
    var searchResults: [SkillHubSearchResult]
    var detail: SkillHubSkillDetail
    var archive: SkillHubArchive
    var downloadRequests = 0

    init(
        searchResults: [SkillHubSearchResult] = [],
        detail: SkillHubSkillDetail,
        archive: SkillHubArchive
    ) {
        self.searchResults = searchResults
        self.detail = detail
        self.archive = archive
    }

    func search(query: String, registry: String?) async throws -> [SkillHubSearchResult] {
        searchResults
    }

    func skillDetail(slug: String, version: String?, registry: String?) async throws -> SkillHubSkillDetail {
        detail
    }

    func download(slug: String, version: String?, registry: String?) async throws -> SkillHubArchive {
        downloadRequests += 1
        return archive
    }
}
