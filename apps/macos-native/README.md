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

## Release Check

Run the release check before handing out a build:

```bash
apps/macos-native/Scripts/release-check.sh
```

It builds, analyzes, runs the test suite, creates the local package, verifies
the signature and hardened runtime flag, checks release Info.plist invariants,
confirms the app does not link unused AppIntents, runs the memory smoke, and
verifies the macOS menu bar no longer exposes unused Help/Format/View menus or
empty File-menu separators. Set `RUN_MEMORY_SMOKE=0` only when `/usr/bin/leaks`
is unavailable, and set `RUN_MENU_CHECK=0` only for headless environments where
macOS UI automation is unavailable.

## Network Policy

PilotDeck is a developer tool that can call user-configured OpenAI-compatible
providers, including self-hosted HTTP endpoints. The app therefore declares
`NSAllowsArbitraryLoads=true` in ATS so those explicit provider URLs work in the
native client. Do not add scoped ATS keys such as `NSAllowsLocalNetworking` next
to it; newer macOS releases can treat those scoped keys as overrides and keep
remote HTTP blocked. Prefer HTTPS for public or shared providers; HTTP endpoints
can expose prompts, responses, and provider credentials to the network path.

## Memory Smoke

Run the local memory smoke after creating a local package:

```bash
apps/macos-native/Scripts/memory-smoke.sh
```

The script launches the packaged app, runs `/usr/bin/leaks`, saves the report
under `apps/macos-native/build/reports/memory-smoke/`, and fails if the partial
leaks report contains PilotDeck-owned symbols such as `AppState`, `ChatView`,
or `ProviderClient`. Hardened local builds are not fully debuggable by
`leaks`, so use this as a quick smoke check, not as a substitute for a final
Instruments Leaks/Allocations run on the Developer ID build.

## Release Build

Use the release packaging script for public distribution. It requires a
Developer ID Application certificate and notarization credentials already stored
with `xcrun notarytool store-credentials`.

```bash
DEVELOPER_ID_APPLICATION="Developer ID Application: Example, Inc. (TEAMID)" \
DEVELOPMENT_TEAM="TEAMID" \
NOTARYTOOL_PROFILE="pilotdeck-notary" \
apps/macos-native/Scripts/package-release.sh
```

The script builds the Release app, verifies the signature, submits the zip for
notarization, staples the ticket, validates the stapled app, recreates
`apps/macos-native/build/dist-release/PilotDeck-mac-release.zip`, and also
creates a notarized drag-to-Applications DMG at
`apps/macos-native/build/dist-release/PilotDeck-mac-release.dmg`.

## Included

- Native V2 shell layout: sidebar, breadcrumb header, tool switcher, main tabs.
- Swift models for projects, sessions, messages, tool calls, permissions,
  settings, tasks, memory, and skills.
- Native service boundaries for provider streaming, workspace/files, git,
  shell, tasks, memory, skills, logs, and app paths.
- Built-in WebSearch provider adapter for GLM/Z.AI, Tavily, and custom APIs.
- Unit tests for the native app runtime and UI logic.
