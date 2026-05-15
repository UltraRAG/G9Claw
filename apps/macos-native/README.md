# 9GClaw Native macOS

This is the active desktop implementation target for 9GClaw. It is a native
macOS app written in Swift, SwiftUI, and AppKit.

## Goals

- Match the existing 9GClaw V2 layout and product behavior.
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
  xcodebuild -project apps/macos-native/9GClaw.xcodeproj \
  -scheme 9GClaw \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build
```

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
