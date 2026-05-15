# 9GClaw Native macOS App TODO

Active desktop source: `apps/macos-native/`.

The current direction is a native macOS 15+ SwiftUI/AppKit rewrite. The app
must not depend on Electron, Tauri, React desktop hosting, Node/Bun runtime, or
localhost HTTP/WebSocket ports. Existing React V2 and `ui/server` code remain
only as parity references until the native implementation reaches full feature
equivalence.

## Current Baseline

- SwiftUI app lifecycle with AppKit-ready window/menu command structure.
- V2-like layout: project/session sidebar, breadcrumb header, tool switcher,
  and main tabs for Agent, Files, Skills, Dashboard, Memory, Always-on, Shell,
  Git, Tasks, Preview, and plugins.
- Native service boundaries for app paths, Keychain, provider streaming,
  workspace files, git, shell, tasks, memory, and skills.
- Parity matrix lives in `apps/macos-native/Docs/PARITY_MATRIX.md`.

## Required Before Distribution

- Complete parity migration for all provider adapters and normalized streaming
  events.
- Replace scaffold persistence with SwiftData plus files under
  `~/Library/Application Support/9GClaw/`.
- Expand unit/golden tests for routes, events, permissions, sorting, path
  validation, settings, memory, skills, tasks, shell, and git behavior.
- Add Developer ID signing, notarization, hardened runtime entitlements, DMG
  packaging, and release smoke tests.
- Validate on a clean macOS 15+ machine with no Node, Bun, Rust, or repository
  checkout installed.
