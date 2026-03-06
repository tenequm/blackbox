# Blackbox

macOS menu bar app that automatically records audio from your calls.

Monitors Chrome, Zoom, and Telegram for meetings, records both system audio and microphone, and saves M4A files locally.

## Install

Download the latest `.dmg` from [Releases](https://github.com/tenequm/blackbox/releases), open it, and drag Blackbox to Applications.

On first launch, grant Screen Recording and Microphone permissions when prompted.

## Features

- Auto-detects meetings by window title (Google Meet, Zoom, Telegram)
- Records system audio + microphone as dual-track M4A
- Manual record/stop for any target app
- Notification when recording is saved (click to reveal in Finder)
- Configurable apps, patterns, save location, and grace period
- Auto-updates

## Build from source

```bash
git clone https://github.com/tenequm/blackbox.git
cd blackbox
make install
open /Applications/Blackbox.app
```

Requires macOS 15+ and Swift 6.2+ (Xcode 16+).

## License

Apache 2.0
