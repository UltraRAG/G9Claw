# PilotDeck

Native macOS app for PilotDeck.

## Repository Layout

| Path | Purpose |
|------|---------|
| `apps/macos-native/` | SwiftUI/AppKit macOS app, tests, assets, and packaging scripts. |
| `apps/macos-native/PilotDeck/Assets/pilotdeck-rag-plugin/` | Bundled RAG plugin resource packaged into the app. |

The old web UI, Node gateway, memory-core package, and legacy plugin workspace have been removed from this repository.

## Develop

Open the project in Xcode:

```bash
open apps/macos-native/PilotDeck.xcodeproj
```

Run tests from the command line:

```bash
xcodebuild test -project apps/macos-native/PilotDeck.xcodeproj -scheme PilotDeck -destination platform=macOS
```
