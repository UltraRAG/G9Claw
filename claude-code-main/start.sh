#!/bin/bash
# Start Claude Code with local proxy (proxy.ts)
# Usage:
#   ./start.sh                    # interactive TUI mode (requires real terminal)
#   ./start.sh -p "your prompt"   # non-interactive (print & exit)
#   ./start.sh --gateway          # gateway-only mode (飞书/Telegram/etc, no CLI)
#   ./start.sh --help             # show help
#   ./start.sh --version          # show version
#
# proxy.ts is the unified entry point:
#   - With ccr-config.json present: advanced CCR routing (multi-provider, tokenSaver, etc.)
#   - Without ccr-config.json (or CCR_DISABLED=1): legacy Anthropic→OpenAI conversion
#
# Configuration: set EDGECLAW_* in the repository root .env or export them.
# CCR routing config: ccr-config.json

DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$DIR/.." && pwd)"
ROOT_ENV="$REPO_ROOT/.env"

if [ -f "$ROOT_ENV" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT_ENV"
  set +a
fi

# Ensure bun is on PATH
if ! command -v bun &>/dev/null; then
  if [ -f "$HOME/.bun/bin/bun" ]; then
    export PATH="$HOME/.bun/bin:$PATH"
  else
    echo "Error: bun is not installed. Install it with: curl -fsSL https://bun.sh/install | bash" >&2
    exit 1
  fi
fi

# ── Check for --gateway flag ──
GATEWAY_ONLY=false
HAS_PRINT=false
HAS_HELP_OR_VERSION=false
REMAINING_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --gateway) GATEWAY_ONLY=true ;;
    --help|--version|-v|-V) HAS_PRINT=true; HAS_HELP_OR_VERSION=true; REMAINING_ARGS+=("$arg") ;;
    -p|--print) HAS_PRINT=true; REMAINING_ARGS+=("$arg") ;;
    *) REMAINING_ARGS+=("$arg") ;;
  esac
done
set -- "${REMAINING_ARGS[@]}"

if [ "$HAS_HELP_OR_VERSION" = true ] && [ "$GATEWAY_ONLY" = false ]; then
  exec bun run --preload="$DIR/preload.ts" "$DIR/src/entrypoints/cli.tsx" "$@"
fi

# ── Ensure peekaboo is installed (macOS only, for computer-use MCP) ──
if [[ "$(uname)" == "Darwin" ]]; then
  if ! command -v peekaboo &>/dev/null; then
    echo "[start] Installing peekaboo (macOS UI automation)..."
    if command -v brew &>/dev/null; then
      brew install steipete/tap/peekaboo 2>/dev/null || echo "[start] Warning: peekaboo install failed (computer-use will be unavailable)"
    else
      echo "[start] Warning: brew not found, skipping peekaboo install (computer-use will be unavailable)"
    fi
  fi
fi

require_env() {
  local key="$1"
  if [ -z "${!key:-}" ]; then
    echo "Error: $key is not set. Configure it in $ROOT_ENV or export it before starting Claude Code." >&2
    exit 1
  fi
}

require_env EDGECLAW_API_BASE_URL
require_env EDGECLAW_API_KEY
require_env EDGECLAW_MODEL

PROXY_PORT="${EDGECLAW_PROXY_PORT:-18080}"

if [ "$GATEWAY_ONLY" = false ] && [ "$HAS_PRINT" = false ] && [ ! -t 1 ]; then
  cat >&2 <<'EOF'
Error: stdout is not a TTY — interactive UI needs a real terminal.

  Examples: Terminal.app, iTerm2, Warp, Alacritty.

  Non-interactive:
    echo "your prompt" | ./start.sh -p --bare
    ./start.sh -p "your prompt" --bare

  Gateway-only (飞书/Telegram etc):
    ./start.sh --gateway
EOF
  exit 1
fi

export OPENAI_API_KEY="${OPENAI_API_KEY:-$EDGECLAW_API_KEY}"
export OPENAI_BASE_URL="${OPENAI_BASE_URL:-$EDGECLAW_API_BASE_URL}"
export OPENAI_MODEL="${OPENAI_MODEL:-$EDGECLAW_MODEL}"
export PROXY_PORT="$PROXY_PORT"

# ── Start local proxy (if not already running) ──
if ! curl -s "http://127.0.0.1:$PROXY_PORT/health" >/dev/null 2>&1; then
  bun run "$DIR/proxy.ts" > "$DIR/.proxy.log" 2>&1 &
  PROXY_PID=$!
  for _ in $(seq 1 30); do
    if curl -s "http://127.0.0.1:$PROXY_PORT/health" >/dev/null 2>&1; then
      break
    fi
    sleep 0.3
  done
  if ! curl -s "http://127.0.0.1:$PROXY_PORT/health" >/dev/null 2>&1; then
    echo "Error: proxy failed to start. Check $DIR/.proxy.log" >&2
    cat "$DIR/.proxy.log" >&2
    exit 1
  fi
fi
trap "[ -n \"\$PROXY_PID\" ] && kill \$PROXY_PID 2>/dev/null; [ -n \"\$GATEWAY_PID\" ] && kill \$GATEWAY_PID 2>/dev/null" EXIT

# ── Claude Code env ──
unset ANTHROPIC_AUTH_TOKEN
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-${EDGECLAW_API_KEY:-dummy-key}}"
export ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-http://127.0.0.1:$PROXY_PORT}"
export DISABLE_TELEMETRY="${DISABLE_TELEMETRY:-1}"
export ANTHROPIC_MODEL="$EDGECLAW_MODEL"

# ── Gateway-only mode: start gateway in foreground, no CLI ──
if [ "$GATEWAY_ONLY" = true ]; then
  export GATEWAY_ALLOW_ALL_USERS="${GATEWAY_ALLOW_ALL_USERS:-true}"
  echo "[start] ═══════════════════════════════════════════"
  echo "[start]  Gateway-only mode"
  echo "[start]  Proxy: http://127.0.0.1:$PROXY_PORT"
  echo "[start]  Model: $ANTHROPIC_MODEL"
  echo "[start]  Log:   tail -f $DIR/.gateway.log"
  echo "[start] ═══════════════════════════════════════════"
  exec bun run "$DIR/gateway/index.ts"
fi

# ── Start messaging gateway in background (if enabled) ──
GATEWAY_ENABLED="${GATEWAY_ENABLED:-false}"
if [ "$GATEWAY_ENABLED" = "true" ] || [ "$GATEWAY_ENABLED" = "1" ]; then
  echo "[start] Starting messaging gateway in background..."
  bun run "$DIR/gateway/index.ts" > "$DIR/.gateway.log" 2>&1 &
  GATEWAY_PID=$!
  sleep 1
  echo "[start] Gateway started (PID $GATEWAY_PID, log: .gateway.log)"
fi

# ── Claude Code interactive CLI ──
exec bun run "$DIR/src/entrypoints/cli.tsx" "$@"
