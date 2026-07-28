# Wispr Free

Free, 100% local push-to-talk dictation for macOS. Hold **Fn**, speak,
release — your words appear in whatever app has focus. No cloud, no account,
no subscription: audio and text never leave your Mac.

## Download

**⬇️ [Download the latest Wispr Free](https://github.com/jordanmoyo/wispr-free/releases/latest)**
— grab `WisprFree-<version>-arm64.zip` under "Assets".

The app comes ready to use: signed and notarized by Apple, for Apple Silicon
Macs (M1 or later) on macOS 14+. No build tools needed — unzip, move
**Wispr Free.app** to `/Applications`, open, and dictate. Full steps in
[Install](#install) below.

## Features

- **On-device transcription** with [WhisperKit](https://github.com/argmaxinc/WhisperKit)
  running Whisper `large-v3`.
- **Optional AI cleanup** of transcripts with an on-device LLM
  ([MLX](https://github.com/ml-explore/mlx-swift)): removes filler words,
  fixes punctuation, formats spoken URLs and emails. Five selectable models
  from the menu (Qwen3 4B default, 0.9–4.3 GB each, downloaded on first use).
- **Language-preserving cleanup**: the cleanup never translates. English stays
  English, French stays French, and mixed-language dictation keeps its
  code-switching exactly where you spoke it.
- **Types anywhere**: text is delivered through the Accessibility API with a
  Unicode-keystroke fallback — native apps, Electron apps, terminals, and it
  never synthesizes Cmd+V.
- **Menu-bar app** with a recording pill overlay while you speak.

## Requirements

- Apple Silicon Mac (M1 or later). Intel is not supported — the cleanup LLM
  runs on [MLX](https://github.com/ml-explore/mlx-swift), which requires
  Apple Silicon.
- macOS 14 (Sonoma) or later.
- Disk space for models: ~3 GB for Whisper, plus 0.9–4.3 GB per optional
  cleanup model. Models download automatically on first use.

## Install

1. Download `WisprFree-<version>-arm64.zip` from the
   [latest release](https://github.com/jordanmoyo/wispr-free/releases/latest)
   ("Assets" section), unzip, and move **Wispr Free.app** to `/Applications`.
2. Open it. The app is notarized by Apple, so it opens normally.
3. Grant the three permissions it asks for (all required for dictation):
   **Microphone** (recording), **Input Monitoring** (detecting the held Fn
   key), **Accessibility** (typing text into the focused app).
4. Hold **Fn**, speak, release. The first dictation downloads the Whisper
   model (~3 GB), so give it a few minutes.

## Build from source

```sh
git clone https://github.com/jordanmoyo/wispr-free.git
cd wispr-free
xcodebuild -downloadComponent MetalToolchain   # one-time per machine
./scripts/package_app.sh
open dist
```

> **Why not just `swift build`?** The MLX cleanup layer compiles Metal GPU
> shaders, which only works under `xcodebuild` — a plain SwiftPM build
> produces a binary that aborts on first cleanup. The packaging script also
> places `mlx-swift_Cmlx.bundle` in `Contents/Resources`, the only location
> MLX's metallib loader searches inside an app bundle. Details in
> [CONTRIBUTING.md](CONTRIBUTING.md).

Unit tests need none of that: `swift test` works anywhere.

## License

[MIT](LICENSE)
