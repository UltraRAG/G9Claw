#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT="$APP_ROOT/PilotDeck.xcodeproj"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA="${DERIVED_DATA:-$APP_ROOT/build/DerivedDataRelease}"
DIST_DIR="${DIST_DIR:-$APP_ROOT/build/dist-release}"
PACKAGE_DIR="$DIST_DIR/PilotDeck-mac-release"
DMG_ROOT="$DIST_DIR/PilotDeck-mac-dmg"
APP_NAME="PilotDeck.app"
ZIP_NAME="PilotDeck-mac-release.zip"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"
DMG_NAME="PilotDeck-mac-release.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
VOLUME_NAME="${VOLUME_NAME:-PilotDeck}"

DEVELOPER_ID_APPLICATION="${DEVELOPER_ID_APPLICATION:-}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-}"
SKIP_NOTARIZATION="${SKIP_NOTARIZATION:-0}"

if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

if [[ -z "$DEVELOPER_ID_APPLICATION" ]]; then
  cat >&2 <<'EOF'
error: DEVELOPER_ID_APPLICATION is required.

Example:
  DEVELOPER_ID_APPLICATION="Developer ID Application: Example, Inc. (TEAMID)" \
  DEVELOPMENT_TEAM="TEAMID" \
  NOTARYTOOL_PROFILE="pilotdeck-notary" \
  apps/macos-native/Scripts/package-release.sh
EOF
  exit 1
fi

rm -rf "$DIST_DIR"
mkdir -p "$PACKAGE_DIR"

args=(
  -project "$PROJECT"
  -scheme PilotDeck
  -configuration "$CONFIGURATION"
  -destination "platform=macOS"
  -derivedDataPath "$DERIVED_DATA"
  CODE_SIGN_STYLE=Manual
  CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION"
  OTHER_CODE_SIGN_FLAGS="--timestamp"
)

if [[ -n "$DEVELOPMENT_TEAM" ]]; then
  args+=(DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM")
fi

args+=(build)

xcodebuild "${args[@]}"

BUILT_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME"
STAGED_APP="$PACKAGE_DIR/$APP_NAME"

if [[ ! -d "$BUILT_APP" ]]; then
  echo "error: built app not found at $BUILT_APP" >&2
  exit 1
fi

ditto "$BUILT_APP" "$STAGED_APP"
xattr -cr "$STAGED_APP"

codesign --verify --deep --strict --verbose=2 "$STAGED_APP"
signature_info="$(codesign -dv --verbose=4 "$STAGED_APP" 2>&1 || true)"
grep -q "Authority=Developer ID Application" <<<"$signature_info" || {
  echo "error: release app is not signed with a Developer ID Application certificate." >&2
  exit 1
}
grep -q "runtime" <<<"$signature_info" || {
  echo "error: release app signature is missing hardened runtime." >&2
  exit 1
}
grep -q "Identifier=com.hx.pilotdeck" <<<"$signature_info" || {
  echo "error: unexpected bundle identifier in release app signature." >&2
  exit 1
}

create_zip() {
  rm -f "$ZIP_PATH"
  (
    cd "$PACKAGE_DIR"
    ditto -c -k --norsrc --keepParent "$APP_NAME" "$ZIP_PATH"
  )
}

create_dmg() {
  rm -rf "$DMG_ROOT"
  mkdir -p "$DMG_ROOT"
  ditto "$STAGED_APP" "$DMG_ROOT/$APP_NAME"
  ln -s /Applications "$DMG_ROOT/Applications"
  rm -f "$DMG_PATH"
  hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$DMG_ROOT" \
    -format UDZO \
    -ov \
    "$DMG_PATH"
}

create_zip

if [[ "$SKIP_NOTARIZATION" != "1" ]]; then
  if [[ -z "$NOTARYTOOL_PROFILE" ]]; then
    echo "error: NOTARYTOOL_PROFILE is required unless SKIP_NOTARIZATION=1." >&2
    exit 1
  fi

  xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
  xcrun stapler staple "$STAGED_APP"
  xcrun stapler validate "$STAGED_APP"

  create_zip
  create_dmg
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
  xcrun stapler staple "$DMG_PATH"

  spctl --assess --type execute --verbose=4 "$STAGED_APP"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"
else
  create_dmg
  echo "warning: notarization skipped; Gatekeeper may block this build on other Macs." >&2
fi

echo "Created $ZIP_PATH"
echo "Created $DMG_PATH"
