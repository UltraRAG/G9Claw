#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP="${APP:-$APP_ROOT/build/dist/PilotDeck-mac-local/PilotDeck.app}"
REPORT_DIR="${REPORT_DIR:-$APP_ROOT/build/reports/memory-smoke}"
SMOKE_SECONDS="${SMOKE_SECONDS:-8}"
STRICT="${STRICT:-0}"

if [[ ! -d "$APP" ]]; then
  echo "error: app not found: $APP" >&2
  echo "Run apps/macos-native/Scripts/package-local.sh first, or pass APP=/path/to/PilotDeck.app." >&2
  exit 1
fi

mkdir -p "$REPORT_DIR"
timestamp="$(date +%Y%m%d-%H%M%S)"
report="$REPORT_DIR/leaks-$timestamp.txt"
stdout_log="$REPORT_DIR/app-$timestamp.stdout.log"
stderr_log="$REPORT_DIR/app-$timestamp.stderr.log"

"$APP/Contents/MacOS/PilotDeck" >"$stdout_log" 2>"$stderr_log" &
pid=$!

cleanup() {
  kill "$pid" >/dev/null 2>&1 || true
  wait "$pid" >/dev/null 2>&1 || true
}
trap cleanup EXIT

sleep "$SMOKE_SECONDS"
leaks "$pid" >"$report" 2>&1 || true
cleanup
trap - EXIT

echo "Memory smoke report: $report"
rg -n "Process|Physical footprint|nodes malloced|total leaked bytes|ROOT LEAK|AppIntents|LNProcess" "$report" || true

if rg -n "AppState|ChatView|ProviderClient|TaskMemory|WorkspaceService|SettingsView|SidebarView|MainAreaView|PilotDeckApp" "$report" >/tmp/pilotdeck-memory-smoke-rg.txt; then
  cat /tmp/pilotdeck-memory-smoke-rg.txt >&2
  echo "error: memory smoke report contains PilotDeck-owned symbols." >&2
  exit 1
fi

if [[ "$STRICT" == "1" ]] && rg -q "total leaked bytes" "$report"; then
  echo "error: leaks reported leaked bytes in STRICT mode." >&2
  exit 1
fi

echo "Memory smoke completed."
