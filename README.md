# Blackbox

macOS menu bar app that automatically records audio from calls. Monitors target apps (Chrome, Zoom, Telegram) for meeting activity via window title detection, records both system audio and microphone, and saves compressed M4A files locally.

## Features

- Auto-detects meetings by window title patterns (Google Meet, Zoom, Telegram)
- Records system audio + microphone as dual-track M4A
- Manual record/stop for any target app
- Configurable target apps, meeting patterns, grace period, save directory
- System notification when recording is saved (click to open in Finder)
- Launch at login

## Requirements

- macOS 15+
- Swift 6.2+ (Xcode 16+ or swift toolchain)

## Setup

Create a local code signing certificate (one-time, needed for stable TCC permissions):

```bash
# Generate self-signed code signing certificate
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout /tmp/blackbox-dev.key -out /tmp/blackbox-dev.crt \
  -subj "/CN=Blackbox Development" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"

# Package as PKCS12 (legacy encoding for Apple Security framework)
openssl pkcs12 -export -out /tmp/blackbox-dev.p12 \
  -inkey /tmp/blackbox-dev.key -in /tmp/blackbox-dev.crt \
  -passout pass:dev -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1

# Import into login keychain
security import /tmp/blackbox-dev.p12 \
  -k ~/Library/Keychains/login.keychain-db -P "dev" -T /usr/bin/codesign

# Trust for code signing
security add-trusted-cert -r trustRoot \
  -k ~/Library/Keychains/login.keychain-db /tmp/blackbox-dev.crt
```

Verify it worked:

```bash
security find-identity -v -p codesigning
# Should show: "Blackbox Development"
```

## Install

```bash
git clone https://github.com/tenequm/blackbox.git
cd blackbox
make install
open /Applications/Blackbox.app
```

On first launch, macOS will ask for Screen Recording and Microphone permissions. Grant both and restart the app.

## Usage

- The waveform icon appears in the menu bar
- When a meeting is detected, recording starts automatically (icon turns red)
- Use "Record Now" to manually record any target app
- Recordings are saved to `~/Documents/Blackbox/` by default
- Open Settings (Cmd+, from menu) to configure target apps, patterns, and save location

## License

Apache 2.0
