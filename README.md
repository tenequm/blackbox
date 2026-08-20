<p align="center">
  <img src="Assets/appicon.png" width="128" height="128" alt="Blackbox">
</p>

<h1 align="center">Blackbox</h1>

<p align="center">Records your calls. Starts by itself. Files stay on your Mac.</p>

You join a call. Blackbox notices and starts recording. You hang up. It stops
and saves an M4A. It works with Zoom, Meet, Teams, Discord, FaceTime, Telegram
and any other app that uses your microphone.

- **No bot, no extension, no account.** Nothing joins your meeting. Nothing
  leaves your Mac unless you ask for a transcript.
- **Both sides, on separate tracks.** System audio and your microphone are
  captured by independent pipelines, so one failing never loses the other.
  Echo is removed from the mic track on-device.
- **Built to not lose a recording.** Microphone swaps, dropped buffers and
  app crashes are detected and repaired while the call is still running.
- **Optional transcription.** Add a Soniox API key in Settings and one click
  transcribes a finished recording. Without a key, no audio leaves your Mac.

<p align="center">
  <img src="Assets/screenshot.png" width="720" alt="Blackbox recordings window">
</p>

## Install

Via [Homebrew](https://brew.sh):

```bash
brew install --cask tenequm/tap/blackbox-recorder
```

Or download the latest `.dmg` from [Releases](https://github.com/tenequm/blackbox/releases), open it, and drag Blackbox to Applications.

Requires macOS 26.1 or later. On first launch, grant Screen Recording and Microphone permissions when prompted.

## Features

- Manual record/stop for system audio outside a call
- Excluded apps: dictation tools and others never trigger a recording
- Notification when a recording is saved; click to reveal in Finder
- Configurable grace period, save folder, file-name date prefix
- Auto-updates

## Build from source

```bash
git clone https://github.com/tenequm/blackbox.git
cd blackbox
make install
open /Applications/Blackbox.app
```

Requires macOS 26.1+ and Swift 6.2+ (Xcode 26+).

## Acknowledgments

Blackbox's ScreenCaptureKit audio capture architecture was informed by studying [Azayaka](https://github.com/Mnpn/Azayaka) by Martin Persson - a clean, well-built macOS screen and audio recorder. Azayaka's approach to dual-track recording and its PCM buffer conversion patterns (based on [Apple's ScreenCaptureKit documentation](https://developer.apple.com/documentation/screencapturekit/capturing_screen_content_in_macos) and [this gist by aibo-cora](https://gist.github.com/aibo-cora/c57d1a4125e145e586ecb61ebecff47c)) were valuable references during development.

## License

GPL v3 - see [LICENSE](LICENSE)
