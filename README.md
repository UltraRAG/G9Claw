# G9Claw

Native macOS app for G9Claw.

## Repository Layout

| Path | Purpose |
|------|---------|
| `apps/macos-native/` | SwiftUI/AppKit macOS app, tests, assets, and packaging scripts. |
| `apps/macos-native/G9Claw/Assets/g9claw-rag-plugin/` | Bundled RAG plugin resource packaged into the app. |

The old web UI, Node gateway, memory-core package, and legacy plugin workspace have been removed from this repository.

## Develop

Open the project in Xcode:

```bash
open apps/macos-native/G9Claw.xcodeproj
```

Run tests from the command line:

```bash
xcodebuild test -project apps/macos-native/G9Claw.xcodeproj -scheme G9Claw -destination platform=macOS
```
