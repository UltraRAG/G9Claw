# Desktop Spike Result

The old Electron/Tauri desktop spike has been retired.

Active implementation: `apps/macos-native/`.

Current desktop direction:

- Native macOS 15+ app built with SwiftUI and AppKit.
- No desktop React host, Electron shell, Tauri shell, bundled Node/Bun UI
  server, or localhost HTTP/WebSocket bridge.
- Existing React V2 and `ui/server` code stay in the repository only as parity
  references while the native rewrite migrates behavior into Swift services.
- Distribution target remains Developer ID signed, notarized DMG after parity
  and persistence work are complete.

Build baseline:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project apps/macos-native/9GClaw.xcodeproj \
  -scheme 9GClaw \
  -configuration Debug \
  -derivedDataPath /private/tmp/edgeclaw-xcode-derived \
  CODE_SIGNING_ALLOWED=NO build
```
