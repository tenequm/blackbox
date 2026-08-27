#!/usr/bin/env bash
# Renders appcast.xml for the DMG that `make release` just produced and signs it
# with the Sparkle EdDSA key. Sparkle reads SUFeedURL from Info.plist, which
# points at releases/latest/download/appcast.xml, so this file IS the update
# feed for every installed copy.
set -euo pipefail

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)"
BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist)"
DMG="build/Blackbox-$VERSION.dmg"
[ -f "$DMG" ] || { echo "$DMG not found" >&2; exit 1; }

SIGN_UPDATE="$(find .build/artifacts -name sign_update -type f | head -1)"
[ -n "$SIGN_UPDATE" ] || { echo "sign_update not found - is the Sparkle artifact resolved?" >&2; exit 1; }

# --ed-key-file - reads the key from stdin, so it never lands on disk.
SIG="$(printf '%s' "${SPARKLE_PRIVATE_KEY:?SPARKLE_PRIVATE_KEY is required}" \
  | "$SIGN_UPDATE" --ed-key-file - -p "$DMG")"
[ -n "$SIG" ] || { echo "sign_update produced no signature" >&2; exit 1; }

LENGTH="$(stat -f%z "$DMG")"

cat > appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Blackbox</title>
    <item>
      <title>Version $VERSION</title>
      <pubDate>$(date -R)</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" Info.plist)</sparkle:minimumSystemVersion>
      <enclosure
        url="https://github.com/tenequm/blackbox/releases/download/${TAG:?TAG is required}/Blackbox-$VERSION.dmg"
        type="application/octet-stream"
        sparkle:edSignature="$SIG"
        length="$LENGTH"
      />
    </item>
  </channel>
</rss>
XML

# Verify against the same key rather than trusting the signing call's exit code.
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - --verify "$DMG" "$SIG"
echo "appcast.xml written for $VERSION (build $BUILD, $LENGTH bytes)"
