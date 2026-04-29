# EdgeClaw Desktop — Runtime Tuning

This document captures the operational knobs the EdgeClaw desktop app exposes
for the bundled `claudecodeui` server and the `claude-code-main` agent runtime.
It complements `apps/desktop/scripts/release.sh` (build) and the post-install
behaviour described in `apps/desktop/src/server-manager.ts`.

---

## 1. Where things live after installation

| What | Path | Owner |
| --- | --- | --- |
| `.app` bundle (read-only) | `/Applications/EdgeClaw.app/` | `electron-builder` |
| Bundled Node 22 + Bun + tarballs | `/Applications/EdgeClaw.app/Contents/Resources/` | shipped, never written to |
| Extracted UI / agent runtime | `~/Library/Application Support/EdgeClaw/runtime/<version>/` | extracted on first launch |
| User config + secrets | `~/.edgeclaw/config.yaml` | onboarding window |
| UI server log | `~/.edgeclaw/desktop.server.log` | `ServerManager` pipes ui-server stdio here |
| Cron daemon log | `~/.edgeclaw/cron-daemon.log` | `cron-daemon-startup.js` opens this fd for the detached bun daemon |
| Cron daemon socket | `~/.claude/cron-daemon.sock` | bun daemon (shared with terminal `cc` CLI) |
| Proxy port | `tcp/127.0.0.1:18080` | `claude-code-main/proxy.ts` |
| UI server port | `tcp/127.0.0.1:18790–18799` (first free) | `claudecodeui` Express |

The runtime extraction directory is keyed on the EdgeClaw bundle version, so
upgrading the app forces a fresh re-extraction of the bundled tarballs and
reclaims disk for stale versions on next launch.

---

## 2. `max_tokens` best practices for reasoning models

### TL;DR

| Model class | Recommended `CLAUDE_CODE_MAX_OUTPUT_TOKENS` | Why |
| --- | --- | --- |
| Non-reasoning chat (GPT-4o, Claude Sonnet w/o thinking, MiniMax-Text) | **4 000 – 8 000** | Plenty for normal answers, leaves provider-side budget for tools. |
| Reasoning models w/ inline `<think>` (MiniMax-M2.7-highspeed, GLM-4-Plus) | **12 000 – 20 000** | Thinking blocks consume 2–8 k by themselves before any answer text starts. |
| Heavy reasoning + long-form code (DeepSeek-R1, Claude Opus thinking, GPT-5-codex) | **24 000 – 40 000** | Multi-step reasoning + diff-style code can blow past 16 k. |
| Bulk transformations (long-doc summarisation, code refactor across files) | **40 000 – 64 000** | Cap at provider's hard ceiling. |

EdgeClaw Desktop ships with **`16 000`** as the default (set in
`apps/desktop/src/server-manager.ts`), which is reasoning-friendly for most
scenarios while staying well under typical OpenAI-Chat-compatible upstream
ceilings.

### Why "8 000 is enough" is wrong for reasoning models

The Anthropic SDK in `claude-code-main` defaults unknown model names to
`32 000` upper-tokens (`src/utils/context.ts → MAX_OUTPUT_TOKENS_DEFAULT`),
but a downstream GrowthBook gate (`tengu_otk_slot_v1`,
`isMaxTokensCapEnabled()` in `services/api/claude.ts`) can silently cap that
to `8 000` (`CAPPED_DEFAULT_MAX_TOKENS`) when set. 8 000 is fine for plain
chat, but a reasoning model's request typically consumes:

```
[~1500 tok system prompt + 1000 tok skills/tools]   ← input
                              ↓
                   ┌──────────────────────┐
                   │ <think> 2000–8000 t  │  ← consumed first
                   ├──────────────────────┤  ← max_tokens budget here
                   │ final answer 500–    │
                   │ 4000+ tokens         │
                   └──────────────────────┘
```

If `max_tokens` is set to 8 000 and the model burns 6 000 on internal
reasoning, the user sees a truncated answer (or no answer at all — just a
mid-sentence stop). With 16 000 the same request comfortably finishes.

### How to override

Pick the most local override that fits your workflow:

1. **Per-install default (recommended for end users)** — edit
   `~/.edgeclaw/config.yaml`:

   ```yaml
   agents:
     main:
       model: default
       params:
         maxOutputTokens: 24000     # bump for heavy reasoning
   ```

   `ui/server/services/edgeclawConfig.js → buildRuntimeEnv` reads
   `params.maxOutputTokens` (also accepts `max_output_tokens` / `max_tokens`)
   and exports it as `CLAUDE_CODE_MAX_OUTPUT_TOKENS` to every spawned
   subprocess (claude-sdk, proxy, cron daemon, plugins).

2. **Per-session override** — set the env before launching:

   ```bash
   CLAUDE_CODE_MAX_OUTPUT_TOKENS=32000 open -a EdgeClaw
   ```

3. **Hardcoded fallback** — change `REASONING_FRIENDLY_MAX_OUTPUT_TOKENS`
   in `apps/desktop/src/server-manager.ts` and rebuild.

### Trade-offs

- Higher `max_tokens` does **not** mean the response is always larger — it's
  a ceiling, not a quota. The model will still stop when it's done.
- It **does** raise per-call latency upper bound (the proxy waits up to
  `API_TIMEOUT_MS` regardless). Default `API_TIMEOUT_MS` is `120000` (2 min).
- It **does** raise the worst-case bill on metered upstream providers. If
  you are wired to a paid endpoint, prefer per-route overrides rather than
  raising the global default.
- Some upstreams (notably the OpenAI-Chat-compatible proxy in
  `claude-code-main/proxy.ts`) forward `max_tokens` verbatim and won't
  validate against the provider's hard cap. Keep the default ≤ the
  documented upstream ceiling (MiniMax: 64 000, OpenAI: 32 000 for most
  models).

### How to confirm what's being sent

```bash
tail -F ~/.edgeclaw/desktop.server.log | grep '\[proxy\]'
```

The `[proxy] POST /v1/messages` line is followed by `msgs=N (in=… out=…)` —
the `out=` is the actual token count returned. If you're consistently seeing
truncated responses where `out=` is hitting your configured ceiling, raise
`maxOutputTokens` in `~/.edgeclaw/config.yaml`.

---

## 3. Process lifecycle (debugging "EdgeClaw won't quit cleanly")

When you launch EdgeClaw, four levels of processes start:

```
Electron (EdgeClaw.app/Contents/MacOS/EdgeClaw)
└── Node 22  (claudecodeui server, port 18790)
    ├── Bun  (claude-code-main proxy.ts, port 18080) ← spawned by ui-server
    └── Bun  (claude-code-main cron daemon, sock ~/.claude/cron-daemon.sock)
                                                    ← detached, shared with `cc` CLI
```

When you `Cmd+Q`, the chain unwinds in this order:

1. `apps/desktop/src/main.ts` `before-quit` → `serverManager.stop()`.
2. `ServerManager` SIGTERMs the ui-server (Node 22).
3. ui-server's `gracefulShutdown` (in `ui/server/index.js`) runs:
   - `stopEdgeClawProxy()` → SIGTERMs the bun proxy.
   - `shutdownOwnedCronDaemon()` → IPC over the unix socket asks the
     cron daemon to exit cleanly. The daemon only obeys if its persisted
     owner token in `~/.claude/cron-daemon/owner.json` matches the
     `CLOUDCLI_CRON_DAEMON_OWNER_TOKEN` env we passed at spawn — so if a
     terminal `cc` session has since taken ownership, we leave it alone.
   - `shutdownCCR()`, `stopAllPlugins()`, etc.
4. As a belt-and-suspenders safety net, `ServerManager.stop()` then sweeps
   anything still holding `tcp:18080` or matching `daemonMain(['serve'])` via
   `pgrep` and SIGTERMs/SIGKILLs them.

If you ever see lingering bun processes after Quit (`ps aux | grep bun`),
file a bug with `~/.edgeclaw/desktop.server.log` and
`~/.edgeclaw/cron-daemon.log` attached.

---

## 4. Resetting the install

```bash
# Quit EdgeClaw first (Cmd+Q).

# Wipe extracted runtime (forces fresh tar extract on next launch):
rm -rf "$HOME/Library/Application Support/EdgeClaw"

# Wipe config + logs (keeps the .app bundle, you'll re-onboard):
rm -rf "$HOME/.edgeclaw"

# Wipe cron daemon state (only if you don't use the terminal `cc` CLI):
rm -rf "$HOME/.claude/cron-daemon" "$HOME/.claude/cron-daemon.sock"
```

The `.app` bundle in `/Applications` is fully self-contained — wiping the
above directories is sufficient to simulate a fresh install.
