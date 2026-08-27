---
name: release-dmg
description: Manual fallback for cutting a macOS DMG release when CI cannot
argument-hint: <version>
disable-model-invocation: true
---

# Release DMG (manual fallback)

**Releases are automated.** Merging the release PR that release-please keeps open
builds, signs, notarizes, staples, publishes and bumps the Homebrew cask by
itself. See "Release Process" in CLAUDE.md.

Use this file only when CI cannot do it - a runner outage, an expired secret, or
a release that must go out while the pipeline is broken. Everything below runs on
a Mac with the Developer ID certificate in the login keychain and the `blackbox`
notarytool keychain profile configured.

**Target version:** $ARGUMENTS

## 1. Set the version

`Info.plist` is the single source of truth; the Makefile reads `VERSION` from it.

- `CFBundleShortVersionString` -> `$ARGUMENTS` (keep the `x-release-please-version` comment on that line)
- `CFBundleVersion` -> `.github/scripts/bump-build-number.sh`, which derives it
  from the last release tag. Never hand-pick it: Sparkle compares this field, and
  a value that goes backwards silently stops updates for everyone on the higher
  number.
- `.github/.release-please-manifest.json` -> `$ARGUMENTS`, so the automation
  picks up where you left off.

## 2. Validate

```sh
make check
```

Format, build with warnings-as-errors, and the full test suite including the
hardware smoke tests. Do not proceed past a failure.

## 3. Build, notarize, staple

```sh
make release
```

This gates on the notarization JSON `status` - `notarytool submit --wait` exits 0
even when the notary returns `Invalid`. On HTTP 403 "A required agreement is
missing or has expired", accept the updated agreement at
developer.apple.com/account (check App Store Connect too), wait a few minutes for
it to propagate, and re-run.

Then confirm Gatekeeper's verdict on the app, not the DMG container
(`spctl -t open` on a .dmg reports "no usable signature" by design):

```sh
hdiutil attach -nobrowse "build/Blackbox-$ARGUMENTS.dmg"
spctl -a -t exec -vv /Volumes/Blackbox/Blackbox.app   # must say: Notarized Developer ID
hdiutil detach /Volumes/Blackbox
```

## 4. Changelog and appcast

```sh
git-cliff --config .github/cliff.toml --tag "v$ARGUMENTS" -o CHANGELOG.md
SPARKLE_PRIVATE_KEY="$(security find-generic-password -s https://sparkle-project.org -a ed25519 -w)" \
  TAG="v$ARGUMENTS" .github/scripts/make-appcast.sh
```

## 5. Commit, tag, publish

```sh
git add Info.plist CHANGELOG.md .github/.release-please-manifest.json
git commit -m "chore: release v$ARGUMENTS"
git push
git tag "v$ARGUMENTS" && git push --tags
gh release create "v$ARGUMENTS" "build/Blackbox-$ARGUMENTS.dmg" appcast.xml \
  --title "Blackbox $ARGUMENTS" \
  --notes "$(git-cliff --config .github/cliff.toml --strip header --latest)"
rm -f appcast.xml
```

## 6. Homebrew cask

```sh
GH_TOKEN="$(gh auth token)" TAG="v$ARGUMENTS" .github/scripts/bump-cask.sh
```

Hashes the published asset rather than the local file, so the cask matches what
brew actually downloads. Keep `auto_updates true` in the cask.

## 7. Verify

```sh
curl -sL https://github.com/tenequm/blackbox/releases/latest/download/appcast.xml
xcrun stapler validate "build/Blackbox-$ARGUMENTS.dmg"
```
