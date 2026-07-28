# Contributing to Wispr Free

Thanks for helping! This file has everything you need to build, test, and
avoid the three traps that cost us days.

## Project layout

- `Sources/WisprApp/main.swift` — executable entry point
- `Sources/WisprCore/` — all logic, built as a library so it's testable:
  - `AppController.swift` — wires everything: hotkey → record → transcribe → cleanup → paste; owns the menu
  - `HotkeyMonitor.swift` — push-to-talk key detection (CGEvent tap)
  - `Recorder.swift`, `AudioResampler.swift` — mic capture → 16 kHz mono
  - `Transcriber.swift` — WhisperKit wrapper
  - `CleanupEngine.swift` — LLM transcript cleanup orchestration (timeouts, fail-open; no MLX imports)
  - `MLXCleanupBackend.swift` — the ONLY file importing MLX; model load + generation
  - `CleanupModelRegistry.swift` — the 5 selectable cleanup models
  - `TranscriptCleaner.swift` — removes Whisper artifacts ([...], (...)); normalizes whitespace
  - `ModelRegistry.swift`, `ModelStore.swift` — model metadata and on-disk layout
  - `Paster.swift` — text delivery (AX selected-text, Unicode keystroke fallback; never Cmd+V)
  - `Permissions.swift`, `SettingsStore.swift`, `WisprError.swift`, `WisprLog.swift`
  - `UI/` — menu-bar status item, recording pill overlay, settings window
- `Tests/WisprCoreTests/` — unit tests (no MLX inference, no GPU, no network)
- `scripts/` — build/packaging/release scripts
- `Resources/` — Info.plist, app icon (SVG masters included); the menu-bar glyph is drawn in code

## Dev loop

- **Logic changes:** `swift test`. Fast, runs anywhere, no GPU or model
  downloads. Keep it green — CI runs exactly this on every PR.
- **Running the app:** `./scripts/package_app.sh`, then open
  `dist/Wispr Free.app`. Diagnostics log:
  `~/Library/Application Support/Wispr/wispr.log`.

## The three build gotchas (read before touching the build)

1. **The shipped binary MUST be built with xcodebuild** (the script does
   this). Plain `swift build` cannot compile MLX's Metal shaders; the
   resulting binary aborts the process at the first cleanup inference.
2. **`mlx-swift_Cmlx.bundle` must be copied to `Contents/Resources/`.**
   MLX's metallib search probes the app bundle's resource directory only.
   `Contents/MacOS` is NOT searched: the app exits silently with
   "Failed to load the default metallib" — no crash report.
3. **One-time per machine:** `xcodebuild -downloadComponent MetalToolchain`,
   or xcodebuild fails with "cannot execute tool 'metal'".

## Code signing during development

By default `package_app.sh` signs ad-hoc, which changes the app's code
signature every rebuild — macOS then re-asks for Microphone, Input
Monitoring, and Accessibility each time. If you rebuild often, create a
stable self-signed code-signing certificate (Keychain Access → Certificate
Assistant → Create a Certificate → Code Signing) and export:

```sh
export WISPR_SIGN_IDENTITY="My Wispr Dev Cert"
# optional if the cert lives in a dedicated keychain:
export WISPR_SIGN_KEYCHAIN=/path/to/dev.keychain
export WISPR_SIGN_KEYCHAIN_PASSWORD=...
```

Permissions then survive rebuilds.

## Conventions

- Conventional commits: `feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`.
- PRs target `main`; `swift test` must pass (CI enforces it).
- New dependencies need discussion in an issue first.
- Tests must never perform MLX inference or network downloads.

## Releases (maintainer only)

`./scripts/release.sh <version>` builds, signs with Developer ID, notarizes,
staples, and produces `dist/WisprFree-<version>-arm64.zip`.
