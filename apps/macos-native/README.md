# PilotDeck Native macOS

This is the active desktop implementation target for PilotDeck. It is a native
macOS app written in Swift, SwiftUI, and AppKit.

## Goals

- Provide the active PilotDeck desktop experience as a native macOS app.
- Use native macOS controls where they improve fidelity and platform feel.
- Remove Electron, Tauri, React desktop hosting, Node server hosting, Bun
  runtime hosting, and localhost HTTP/WebSocket listeners from the desktop app.

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
  xcodebuild -project apps/macos-native/PilotDeck.xcodeproj \
  -scheme PilotDeck \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## Local Sharing Build

Use the local packaging script when handing the app to another Mac:

```bash
apps/macos-native/Scripts/package-local.sh
```

The script creates `apps/macos-native/build/dist/PilotDeck-mac-local.zip`, ad-hoc
signs the app without using the Keychain, and includes an `INSTALL.txt` in the
unzipped folder. For a passwordless install, unzip it and put `PilotDeck.app` in
`~/Applications` instead of the system `/Applications` folder. Copying into
system `/Applications` may require an administrator password on the recipient's
Mac.

Public distribution still needs Developer ID signing and notarization. The local
zip is intended for trusted internal sharing and may still show a Gatekeeper
warning on a new Mac.

## Included

- Native V2 shell layout: sidebar, breadcrumb header, tool switcher, main tabs.
- Swift models for projects, sessions, messages, tool calls, permissions,
  settings, tasks, memory, and skills.
- Native service boundaries for provider streaming, workspace/files, git,
  shell, tasks, memory, skills, Keychain, logs, and app paths.
- Built-in WebSearch provider adapter for GLM/Z.AI, Tavily, and custom APIs.
- Unit tests for the native app runtime and UI logic.
