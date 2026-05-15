import Foundation

struct ParitySource: Identifiable, Hashable {
    var id: String { swiftModule }
    var swiftModule: String
    var legacySources: [String]
    var acceptance: [String]
}

enum ParityCatalog {
    static let modules: [ParitySource] = [
        ParitySource(
            swiftModule: "ShellCore",
            legacySources: [
                "ui/src/components/app-shell/AppShellV2.tsx",
                "ui/src/components/app-shell/SidebarV2.tsx",
                "ui/src/components/app-shell/MainAreaV2.tsx",
                "ui/src/hooks/useProjectsState.ts",
                "ui/src/hooks/useSessionProtection.ts"
            ],
            acceptance: [
                "sidebar project/session selection and default general project behavior match V2",
                "active tab, unread, processing, rename, delete, and collapsed sidebar states are preserved",
                "breadcrumb and top tool switcher remain visually aligned with MainAreaV2"
            ]
        ),
        ParitySource(
            swiftModule: "AgentCore",
            legacySources: [
                "ui/server/index.js",
                "ui/server/claude-sdk.js",
                "ui/server/openai-codex.js",
                "ui/server/cursor-cli.js",
                "ui/server/gemini-cli.js",
                "claude-code-main/src/services/api/claude.ts"
            ],
            acceptance: [
                "normalized streaming events cover session_created, content delta, tool use/result, status, error, complete, abort",
                "provider configuration maps to the same OpenAI-compatible and Anthropic message payloads",
                "tool permission pauses and resumes sessions without losing transcript state"
            ]
        ),
        ParitySource(
            swiftModule: "WorkspaceCore",
            legacySources: [
                "ui/server/routes/projects.js",
                "ui/server/index.js file routes",
                "ui/src/components/main-content-v2/FilesV2.tsx"
            ],
            acceptance: [
                "workspace paths reject system-critical directories and paths outside the configured root",
                "file tree, read, write, create, rename, delete, upload, and preview states match the web routes",
                "project and session sorting match SidebarV2"
            ]
        ),
        ParitySource(
            swiftModule: "GitCore",
            legacySources: [
                "ui/server/routes/git.js",
                "ui/src/components/main-content-v2/GitV2.tsx"
            ],
            acceptance: [
                "status, diff, branch, commit, fetch, pull, push, publish, discard, delete-untracked are available",
                "git token and error redaction behavior matches the server route",
                "commit message generation uses the same provider path as chat"
            ]
        ),
        ParitySource(
            swiftModule: "TerminalCore",
            legacySources: [
                "ui/src/components/main-content-v2/ShellV2.tsx",
                "ui/server/index.js pty setup"
            ],
            acceptance: [
                "cwd-bound terminal sessions can stream output, accept input, resize, and terminate",
                "no terminal process remains after window close or app quit"
            ]
        ),
        ParitySource(
            swiftModule: "TaskCore/AlwaysOnCore",
            legacySources: [
                "ui/server/routes/taskmaster.js",
                "ui/server/always-on-heartbeat.js",
                "ui/server/always-on-slash.js",
                "ui/server/services/cron-daemon-owner.js",
                "ui/src/components/main-content-v2/TasksV2.tsx",
                "ui/src/components/main-content-v2/AlwaysOnV2.tsx"
            ],
            acceptance: [
                "tasks, plans, manual run, recurring run, run history, logs, and notifications match old semantics",
                "background sessions appear in sidebar and chat read-only state where applicable"
            ]
        ),
        ParitySource(
            swiftModule: "MemoryCore",
            legacySources: [
                "edgeclaw-memory-core/src/service.ts",
                "ui/server/routes/memory.js",
                "ui/src/components/main-content-v2/DashboardV2.tsx"
            ],
            acceptance: [
                "index, dream, rollback, list, get, actions, import, export, clear, and dashboard views are covered",
                "capture strategy and includeAssistant behavior match existing memory config"
            ]
        ),
        ParitySource(
            swiftModule: "SkillsCore/PluginsCore",
            legacySources: [
                "ui/server/routes/skills.js",
                "ui/server/routes/plugins.js",
                "ui/src/components/main-content-v2/SkillsV2.tsx",
                "ui/src/contexts/PluginsContext.tsx"
            ],
            acceptance: [
                "skills list/read/write/create/delete/import/validate and ClawHub search/install are covered",
                "plugin enable, manifest, assets, install, update, delete lifecycle is represented natively"
            ]
        )
    ]
}
