# Codex Architecture Reference

`/Users/hx/Workspace/codex` is the local, read-only architecture reference for the native 9GClaw agent runtime.

The Swift native app does not depend on Codex binaries or Rust crates. The reference is used to keep our implementation aligned with Codex's management model:

- `NativeThreadManager` follows `codex-rs/core/src/thread_manager.rs` and owns session lifecycle.
- `NativeSession` follows `codex-rs/core/src/session/session.rs` and owns workspace/config/history/active turn state.
- `NativeTurnController` follows `codex-rs/core/src/state/turn.rs` and owns a single active turn, run token, cancellation and ordered timeline items.
- `NativeToolRouter` follows `codex-rs/core/src/tools/router.rs` and keeps schema, permission and executor dispatch separate from provider streaming.
- `NativeProcessRunner` follows `codex-rs/core/src/unified_exec/process.rs` and is the future home for cancellable command execution.
- Provider retry behavior follows `codex-rs/core/src/session/turn.rs`,
  `codex-rs/codex-client/src/retry.rs`, and `codex-rs/model-provider-info/src/lib.rs`:
  retry transient transport failures and 5xx responses with 200ms exponential backoff and jitter,
  do not retry user aborts, 400/invalid request, auth/quota, context-window, permission, or sandbox failures.
  Malformed tool arguments must be converted into a model-visible recoverable tool result instead of
  being sent back to the provider as invalid JSON.

Maintenance rule: when changing the native agent loop, compare behavior against Codex's turn loop before adding special-case prompt logic. UI should render ordered timeline items rather than attaching tool output to the end of a message.
