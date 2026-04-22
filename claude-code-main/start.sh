#!/bin/bash
# Start Claude Code from leaked source (with OpenAI-format proxy)
# Usage:
#   ./start.sh                    # interactive TUI mode (requires real terminal)
#   ./start.sh -p "your prompt"   # non-interactive (print & exit)
#   ./start.sh --gateway          # gateway-only mode (飞书/Telegram/etc, no CLI)
#   ./start.sh --help             # show help
#   ./start.sh --version          # show version
#
# Configuration: copy .env.example to .env and set OPENAI_* / ANTHROPIC_*.

DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -f "$DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$DIR/.env"
  set +a
else
  echo "Error: missing $DIR/.env — copy .env.example to .env and set your API keys." >&2
  exit 1
fi

PROXY_PORT="${PROXY_PORT:-18080}"

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
REMAINING_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --gateway) GATEWAY_ONLY=true ;;
    -p|--print|--help|--version|-v|-V|daemon|--daemon-worker) HAS_PRINT=true; REMAINING_ARGS+=("$arg") ;;
    *) REMAINING_ARGS+=("$arg") ;;
  esac
done
set -- "${REMAINING_ARGS[@]}"

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

if [ -z "$OPENAI_API_KEY" ]; then
  echo "Error: OPENAI_API_KEY is not set (add it to .env)." >&2
  exit 1
fi

export OPENAI_API_KEY
export PROXY_PORT="$PROXY_PORT"
if [ -n "$OPENAI_BASE_URL" ]; then
  export OPENAI_BASE_URL
fi

# ── Start local Anthropic→OpenAI proxy (if not already running) ──
if ! curl -s "http://127.0.0.1:$PROXY_PORT/health" >/dev/null 2>&1; then
  bun run "$DIR/proxy.ts" > "$DIR/.proxy.log" 2>&1 &
  PROXY_PID=$!
  for _ in $(seq 1 20); do
    if curl -s "http://127.0.0.1:$PROXY_PORT/health" >/dev/null 2>&1; then
      break
    fi
    sleep 0.2
  done
  trap "kill $PROXY_PID 2>/dev/null; [ -n \"\$GATEWAY_PID\" ] && kill \$GATEWAY_PID 2>/dev/null" EXIT
fi

# ── Claude Code env ──
unset ANTHROPIC_AUTH_TOKEN
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-$OPENAI_API_KEY}"
export ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-http://127.0.0.1:$PROXY_PORT}"
export DISABLE_TELEMETRY="${DISABLE_TELEMETRY:-1}"
export CLAUDE_CODE_SYNTAX_HIGHLIGHT=0

if [ -z "$ANTHROPIC_MODEL" ]; then
  echo "Error: ANTHROPIC_MODEL is not set (add it to .env)." >&2
  exit 1
fi
export ANTHROPIC_MODEL

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
exec bun run --preload="$DIR/preload.ts" "$DIR/src/entrypoints/cli.tsx" "$@"
