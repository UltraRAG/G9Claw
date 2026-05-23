# G9Claw Native macOS

This is the active desktop implementation target for G9Claw. It is a native
macOS app written in Swift, SwiftUI, and AppKit.

## Goals

- Match the existing G9Claw V2 layout and product behavior.
- Use native macOS controls where they improve fidelity and platform feel.
- Remove Electron, Tauri, React desktop hosting, Node server hosting, Bun
  runtime hosting, and localhost HTTP/WebSocket listeners from the desktop app.
- Keep legacy Web/Node sources as behavior references until native parity is
  complete.

## Requirements

- Xcode 26.5 or newer.
- Active developer directory set to Xcode:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

The app targets macOS 15.0+.

## Build

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project apps/macos-native/G9Claw.xcodeproj \
  -scheme G9Claw \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Local Sharing Build

Use the local packaging script when handing the app to another Mac:

```bash
apps/macos-native/Scripts/package-local.sh
```

The script creates `apps/macos-native/build/dist/G9Claw-mac-local.zip`, ad-hoc
signs the app without using the Keychain, and includes an `INSTALL.txt` in the
unzipped folder. For a passwordless install, unzip it and put `G9Claw.app` in
`~/Applications` instead of the system `/Applications` folder. Copying into
system `/Applications` may require an administrator password on the recipient's
Mac.

Public distribution still needs Developer ID signing and notarization. The local
zip is intended for trusted internal sharing and may still show a Gatekeeper
warning on a new Mac.

## Parity Workflow

`Docs/PARITY_MATRIX.md` is the source of truth for matching the existing
React/Node implementation. Every native module links back to the legacy files it
must match and the acceptance scenarios that close the gap.

The current scaffold includes:

- Native V2 shell layout: sidebar, breadcrumb header, tool switcher, main tabs.
- Swift models for projects, sessions, messages, tool calls, permissions,
  settings, tasks, memory, and skills.
- Native service boundaries for provider streaming, workspace/files, git,
  shell, tasks, memory, skills, Keychain, logs, and app paths.
- Unit tests for workspace path validation and project/session sorting.

The remaining work is to fill each module until the parity matrix is complete.
