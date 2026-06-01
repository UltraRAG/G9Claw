#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT="$APP_ROOT/PilotDeck.xcodeproj"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA="${DERIVED_DATA:-$APP_ROOT/build/DerivedDataLocal}"
DIST_DIR="${DIST_DIR:-$APP_ROOT/build/dist}"
PACKAGE_DIR="$DIST_DIR/PilotDeck-mac-local"
APP_NAME="PilotDeck.app"
ZIP_NAME="PilotDeck-mac-local.zip"

rm -rf "$DIST_DIR"
mkdir -p "$PACKAGE_DIR"

xcodebuild \
  -project "$PROJECT" \
  -scheme PilotDeck \
  -configuration "$CONFIGURATION" \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build

BUILT_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME"
STAGED_APP="$PACKAGE_DIR/$APP_NAME"

if [[ ! -d "$BUILT_APP" ]]; then
  echo "error: built app not found at $BUILT_APP" >&2
  exit 1
fi

ditto "$BUILT_APP" "$STAGED_APP"

# Ad-hoc signing does not require a paid certificate or Keychain password. It is
# enough for local sharing builds; public distribution still needs Developer ID
# signing and notarization.
codesign --force --deep --sign - "$STAGED_APP"
xattr -cr "$STAGED_APP"

cat > "$PACKAGE_DIR/INSTALL.txt" <<'EOF'
Passwordless install:

1. Unzip PilotDeck-mac-local.zip.
2. Move PilotDeck.app to ~/Applications, not /Applications.

Terminal equivalent:

mkdir -p "$HOME/Applications"
ditto "PilotDeck.app" "$HOME/Applications/PilotDeck.app"
open "$HOME/Applications/PilotDeck.app"

If macOS blocks the app as unidentified, that is Gatekeeper because this local
build is ad-hoc signed rather than Developer ID signed and notarized.
EOF

(
  cd "$DIST_DIR"
  ditto -c -k --norsrc --keepParent "PilotDeck-mac-local" "$ZIP_NAME"
)

echo "Created $DIST_DIR/$ZIP_NAME"
echo "Install without an admin password by placing PilotDeck.app in ~/Applications."
