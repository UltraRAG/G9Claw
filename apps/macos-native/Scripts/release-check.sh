#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT="$APP_ROOT/PilotDeck.xcodeproj"
SCHEME="PilotDeck"
LOCAL_APP="$APP_ROOT/build/dist/PilotDeck-mac-local/PilotDeck.app"
LOCAL_ZIP="$APP_ROOT/build/dist/PilotDeck-mac-local.zip"

if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

run() {
  echo
  echo "==> $*"
  "$@"
}

fail() {
  echo "error: $*" >&2
  exit 1
}

plist_print() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$LOCAL_APP/Contents/Info.plist"
}

run bash -n "$SCRIPT_DIR/package-local.sh"
run bash -n "$SCRIPT_DIR/package-release.sh"
run bash -n "$SCRIPT_DIR/memory-smoke.sh"
run bash -n "$SCRIPT_DIR/release-check.sh"
run plutil -lint "$APP_ROOT/PilotDeck/App/Info.plist"

run xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "platform=macOS" \
  build

run xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "platform=macOS" \
  analyze

run xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "platform=macOS" \
  test

run "$SCRIPT_DIR/package-local.sh"

[[ -d "$LOCAL_APP" ]] || fail "local app package missing: $LOCAL_APP"
[[ -f "$LOCAL_ZIP" ]] || fail "local zip missing: $LOCAL_ZIP"

run codesign --verify --deep --strict --verbose=2 "$LOCAL_APP"

signature_info="$(codesign -dv --verbose=4 "$LOCAL_APP" 2>&1 || true)"
grep -q "Signature=adhoc" <<<"$signature_info" || fail "local app is expected to be ad-hoc signed"
grep -q "runtime" <<<"$signature_info" || fail "local app signature is missing hardened runtime"
grep -q "Identifier=com.hx.pilotdeck" <<<"$signature_info" || fail "unexpected bundle identifier"

[[ "$(plist_print LSMinimumSystemVersion)" == "15.0" ]] || fail "LSMinimumSystemVersion must be 15.0"
[[ "$(plist_print LSApplicationCategoryType)" == "public.app-category.developer-tools" ]] || fail "wrong app category"
[[ "$(plist_print NSAppTransportSecurity:NSAllowsArbitraryLoads)" == "true" ]] || fail "remote HTTP provider support requires NSAllowsArbitraryLoads"
if /usr/libexec/PlistBuddy -c "Print :NSAppTransportSecurity:NSAllowsLocalNetworking" "$LOCAL_APP/Contents/Info.plist" >/dev/null 2>&1; then
  fail "NSAllowsLocalNetworking must not be present with NSAllowsArbitraryLoads; it can cause ATS to ignore the global HTTP provider allowance"
fi
if /usr/libexec/PlistBuddy -c "Print :NSAppTransportSecurity:NSExceptionDomains:58.57.119.12" "$LOCAL_APP/Contents/Info.plist" >/dev/null 2>&1; then
  fail "legacy insecure IP ATS exception must not be present"
fi

if otool -L "$LOCAL_APP/Contents/MacOS/PilotDeck" | grep -q "AppIntents.framework"; then
  fail "PilotDeck should not link AppIntents.framework without real app intents"
fi
if rg -n "KeychainStore|SecItem|LocalAuthentication" "$APP_ROOT/PilotDeck" "$PROJECT" >/tmp/pilotdeck-release-rg.txt; then
  cat /tmp/pilotdeck-release-rg.txt >&2
  fail "runtime keychain access must not be present while API keys are YAML-only"
fi

if rg -n "58\\.57\\.119\\.12|MACOSX_DEPLOYMENT_TARGET = 14\\.5" "$APP_ROOT/PilotDeck/App/Info.plist" "$PROJECT" "$APP_ROOT/README.md" >/tmp/pilotdeck-release-rg.txt; then
  cat /tmp/pilotdeck-release-rg.txt >&2
  fail "release-blocking legacy config found"
fi
if rg -n "CommandMenu\\(" "$APP_ROOT/PilotDeck/App" >/tmp/pilotdeck-release-rg.txt; then
  cat /tmp/pilotdeck-release-rg.txt >&2
  fail "custom top-level SwiftUI CommandMenu found"
fi

if [[ "${RUN_MEMORY_SMOKE:-1}" == "1" ]]; then
  run "$SCRIPT_DIR/memory-smoke.sh"
fi

if [[ "${RUN_MENU_CHECK:-1}" == "1" ]]; then
  echo
  echo "==> verifying macOS menu bar"
  osascript -e 'tell application "PilotDeck" to quit' >/dev/null 2>&1 || true
  pkill -x PilotDeck >/dev/null 2>&1 || true
  sleep 0.5
  open -n "$LOCAL_APP"
  cleanup_menu_check() {
    osascript -e 'tell application "PilotDeck" to quit' >/dev/null 2>&1 || true
    pkill -x PilotDeck >/dev/null 2>&1 || true
  }
  trap cleanup_menu_check EXIT
  osascript -e 'tell application "PilotDeck" to activate' >/dev/null 2>&1 || true
  sleep "${MENU_CHECK_DELAY_SECONDS:-6}"
  menu_items="$(osascript -e 'tell application "System Events" to tell process "PilotDeck" to get name of menu bar items of menu bar 1')"
  echo "$menu_items"
  case "$menu_items" in
    *Help*|*帮助*|*Format*|*格式*|*View*|*显示*)
      fail "menu bar still exposes unused Help/Format/View menus"
      ;;
  esac
  osascript -e 'tell application "System Events" to tell process "PilotDeck" to click menu bar item "File" of menu bar 1' >/dev/null 2>&1 || true
  sleep 0.5
  file_items="$(osascript -e 'tell application "System Events" to tell process "PilotDeck" to get name of menu items of menu "File" of menu bar item "File" of menu bar 1')"
  echo "$file_items"
  case "$file_items" in
    *"missing value"*)
      fail "File menu contains empty separator-only items"
      ;;
  esac
  osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1 || true
  cleanup_menu_check
  trap - EXIT
fi

echo
echo "Release check passed."
echo "Local package: $LOCAL_ZIP"
