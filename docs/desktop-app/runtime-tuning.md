# Native macOS Desktop Runtime Notes

Active desktop source: `apps/macos-native/`.

The previous Electron/Tauri runtime notes are obsolete. Native 9GClaw must not
start a bundled Node/Bun UI server, expose localhost HTTP/WebSocket ports, or
require a repository checkout after installation.

## Runtime Model

- UI: SwiftUI/AppKit inside the macOS app process.
- Settings and non-sensitive state: `~/Library/Application Support/9GClaw/`.
- Logs: `~/Library/Logs/9GClaw/`.
- Secrets: macOS Keychain.
- External processes: only feature-specific commands such as `git`, shell
  sessions, and provider CLI integrations where a migrated provider requires
  them.

## Development Commands

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project apps/macos-native/9GClaw.xcodeproj \
  -scheme 9GClaw \
  -configuration Debug \
  -derivedDataPath /private/tmp/edgeclaw-xcode-derived \
  CODE_SIGNING_ALLOWED=NO build
```

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test \
  -project apps/macos-native/9GClaw.xcodeproj \
  -scheme 9GClaw \
  -configuration Debug \
  -derivedDataPath /private/tmp/edgeclaw-xcode-derived \
  CODE_SIGNING_ALLOWED=NO
```

For local development, using `DEVELOPER_DIR` is enough. To make Xcode the global
active developer directory, run:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```
