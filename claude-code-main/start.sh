#!/bin/bash
# Start Claude Code from leaked source (with OpenAI-format proxy)
# Usage:
#   ./start.sh                    # interactive TUI mode (requires real terminal)
#   ./start.sh -p "your prompt"   # non-interactive (print & exit)
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

# Ensure bun is on PATH
if ! command -v bun &>/dev/null; then
  if [ -f "$HOME/.bun/bin/bun" ]; then
    export PATH="$HOME/.bun/bin:$PATH"
  else
    echo "Error: bun is not installed. Install it with: curl -fsSL https://bun.sh/install | bash" >&2
    exit 1
  fi
fi

# ── Check if interactive mode is possible ──
HAS_PRINT=false
for arg in "$@"; do
  case "$arg" in -p|--print|--help|--version|-v|-V) HAS_PRINT=true ;; esac
done
if [ "$HAS_PRINT" = false ] && [ ! -t 1 ]; then
  cat >&2 <<'EOF'
Error: stdout is not a TTY — interactive UI needs a real terminal.

  Examples: Terminal.app, iTerm2, Warp, Alacritty.

  Non-interactive:
    echo "your prompt" | ./start.sh -p --bare
    ./start.sh -p "your prompt" --bare
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
  trap "kill $PROXY_PID 2>/dev/null" EXIT
fi

# ── Claude Code: point at local proxy ──
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

exec bun run --preload="$DIR/preload.ts" "$DIR/src/entrypoints/cli.tsx" "$@"
