# 9GClaw Native macOS Parity Matrix

The native app must preserve the existing behavior before the Web/Node desktop
runtime is removed from the product path. Each row names the old implementation
source and the native acceptance target.

| Native module | Legacy source | Acceptance target | Status |
|---|---|---|---|
| ShellCore | `ui/src/components/app-shell/AppShellV2.tsx`, `SidebarV2.tsx`, `MainAreaV2.tsx`, `useProjectsState.ts`, `useSessionProtection.ts` | Sidebar project/session selection, default project selection, active tab, unread, processing, rename/delete, breadcrumb, and collapsed sidebar match V2. | Scaffolded |
| AgentCore | `ui/server/index.js`, `ui/server/claude-sdk.js`, `openai-codex.js`, `cursor-cli.js`, `gemini-cli.js`, `claude-code-main/src/services/api/claude.ts` | Native events cover session created, content delta, tool use/result, permission request, status, token budget, stream end, complete, abort, and error. | 9GClaw streaming scaffolded |
| WorkspaceCore | `ui/server/routes/projects.js`, file routes in `ui/server/index.js`, `FilesV2.tsx` | Path validation rejects system paths and paths outside workspace root; file tree, read, write, create, rename, delete, upload, preview match old behavior. | Validation and read/write scaffolded |
| GitCore | `ui/server/routes/git.js`, `GitV2.tsx` | status, diff, file diff, branches, checkout, create/delete branch, commits, commit, fetch, pull, push, publish, discard, delete untracked match old route behavior. | Common commands scaffolded |
| TerminalCore | `ShellV2.tsx`, pty flow in `ui/server/index.js` | cwd-bound terminal streams output, accepts input, resizes, terminates, and leaves no child process after quit. | Command runner scaffolded |
| TaskCore | `ui/server/routes/taskmaster.js`, `TasksV2.tsx` | TaskMaster detection, init, PRD, task CRUD, parse PRD, templates, and update broadcasts match old behavior. | Model scaffolded |
| AlwaysOnCore | `always-on-heartbeat.js`, `always-on-slash.js`, cron daemon services, `AlwaysOnV2.tsx` | Discovery context, plans, approvals, run now, run history, logs, recurring jobs, background sessions, and notifications match old behavior. | UI tab scaffolded |
| MemoryCore | `edgeclaw-memory-core/src/service.ts`, `ui/server/routes/memory.js`, `DashboardV2.tsx` | index, dream, rollback, snapshot, list/get/actions, user summary, workspace, cases, traces, import/export, clear match existing memory behavior. | Model scaffolded |
| SkillsCore | `ui/server/routes/skills.js`, `SkillsV2.tsx` | list, read, write, create, delete, import, validate, ClawHub search/install match old behavior. | Model scaffolded |
| PluginsCore | `ui/server/routes/plugins.js`, `PluginsContext.tsx` | manifest/assets, enable, install, update, delete, process lifecycle, and plugin tabs match old behavior. | Interface planned |
| Settings/AppCore | `edgeclawConfig.js`, `settings.js`, `config.js`, auth/user routes | Native settings preserve config derivation, masked secret behavior, Keychain storage, notification preferences, user onboarding, and API key management. | Keychain and provider settings scaffolded |

## Required Golden Tests

- Project sorting by name and most recent activity.
- Session sorting across Claude/Codex/Cursor/Gemini buckets.
- Workspace path validation, including `/`, `/usr`, `/opt`, `/tmp`, and outside-root paths.
- Provider stream parsing for OpenAI chat, OpenAI responses, and Anthropic messages.
- Normalized agent event conversion for content, tools, errors, completion, and token budgets.
- Git command error redaction and command argument safety.
- Permission request lifecycle: pending, allow session, allow project, deny, timeout.

## Completion Rule

A module is not parity-complete until its Swift implementation has:

- Direct source links to legacy files.
- Unit tests or golden fixtures for non-UI logic.
- Native UI smoke coverage for empty, loading, success, error, and long-content states.
- A shutdown check where relevant to prove no orphan process or local port remains.
