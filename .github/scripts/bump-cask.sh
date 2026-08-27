#!/usr/bin/env bash
# Points the Homebrew cask at the release that was just published.
#
# The sha256 is taken from the PUBLISHED asset, not the local DMG: brew will
# download that exact byte stream, and hashing the local copy would mask any
# difference introduced by the upload.
#
# `auto_updates true` stays in the cask. Sparkle updates the app in place, so a
# plain `brew upgrade` deliberately skips it; removing the flag would let a
# lagging cask downgrade an installation Sparkle had already moved forward.
set -euo pipefail

: "${TAG:?TAG is required}"
: "${GH_TOKEN:?a token with write access to tenequm/homebrew-tap is required}"

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)"
URL="https://github.com/tenequm/blackbox/releases/download/$TAG/Blackbox-$VERSION.dmg"

# The asset can lag the release by a moment; a bad hash is unrecoverable for
# users, so wait for it rather than hashing whatever comes back first.
for _ in $(seq 1 10); do
  SHA="$(curl -fsSL "$URL" | shasum -a 256 | cut -d' ' -f1)" && break
  sleep 6
done
[ -n "${SHA:-}" ] || { echo "could not download $URL" >&2; exit 1; }

TAP="$(mktemp -d)/homebrew-tap"
git clone --depth 1 "https://x-access-token:$GH_TOKEN@github.com/tenequm/homebrew-tap.git" "$TAP"
CASK="$TAP/Casks/blackbox-recorder.rb"
[ -f "$CASK" ] || { echo "cask not found at Casks/blackbox-recorder.rb" >&2; exit 1; }

/usr/bin/sed -i '' -e "s|^  version \".*\"|  version \"$VERSION\"|" \
                   -e "s|^  sha256 \".*\"|  sha256 \"$SHA\"|" "$CASK"

git -C "$TAP" diff --quiet && { echo "cask already at $VERSION"; exit 0; }
git -C "$TAP" config user.name "github-actions[bot]"
git -C "$TAP" config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git -C "$TAP" commit -q -am "chore(blackbox): bump to $VERSION"
git -C "$TAP" push
echo "cask bumped to $VERSION ($SHA)"
