---
name: release-dmg
description: Full macOS DMG release - validate, build, sign, changelog, git tag, GitHub release
argument-hint: <version>
disable-model-invocation: true
---

# Release DMG

Automate the full release pipeline for Blackbox. Execute each step sequentially. Stop immediately on any failure.

**Target version:** $ARGUMENTS

## Pre-flight Checks

Run all checks in parallel where possible:

1. **Version argument**: Verify `$ARGUMENTS` is provided and matches semver format (X.Y.Z). If missing or invalid, ask the user and stop.
2. **Git working tree**: Run `git status --porcelain`. Uncommitted changes are OK if they are part of this release (version was bumped ahead of time). Note them and continue.
3. **Branch**: Confirm on `main`. If not, warn and ask to confirm.
4. **Version comparison**: Read current version from `Makefile` (`VERSION = ...` line). If `$ARGUMENTS` equals the current version, skip the version bump step (already done). If greater, proceed normally. If less, stop.
5. **Version sync**: Verify `Makefile` VERSION and `Info.plist` CFBundleShortVersionString match each other. If they don't, stop and report the mismatch.
6. **Changelog**: Read `CHANGELOG.md` and verify the `[Unreleased]` section has content (at least one list item under Added/Changed/Fixed/Removed). If empty, stop and tell the user to add changelog entries first.
7. **Tools**: Verify `create-dmg` is installed (`command -v create-dmg`).

If any check fails, report all failures together and stop.

## Step 1: Version Bump

**Skip this step if pre-flight detected version already matches `$ARGUMENTS`.**

1. Update `Makefile`: change `VERSION = X.Y.Z` to the new version.
2. Update `Info.plist`:
   - `CFBundleShortVersionString` to the new version
   - `CFBundleVersion`: read the current integer value and increment by 1
3. Update `CHANGELOG.md`:
   - Change `## [Unreleased]` to `## [Unreleased]` followed by a blank line and `## [X.Y.Z] - YYYY-MM-DD` (today's date)
   - Add link reference at bottom: `[X.Y.Z]: https://github.com/tenequm/blackbox/compare/vPREVIOUS...vX.Y.Z`
   - Update `[unreleased]` link to compare from `vX.Y.Z...HEAD`

## Step 2: Format, Build, Test

Run the full validation pipeline:

```bash
make check
```

This runs: `make format` (auto-fix) -> `make build` (Swift 6.2, warnings-as-errors) -> `make test`.

If any step fails, stop and report. Do NOT proceed to artifact creation with broken code.

## Step 3: Build, Notarize, Staple DMG

Build the DMG, submit for notarization, and staple the ticket:

```bash
make release
```

This runs: `make dmg` -> `xcrun notarytool submit --wait` -> `xcrun stapler staple`.

If notarization fails with HTTP 403 "A required agreement is missing or has expired": the user must accept the updated Apple Developer agreement at developer.apple.com/account (sometimes App Store Connect). Acceptance takes a few minutes to propagate - retry `xcrun notarytool submit build/Blackbox-X.Y.Z.dmg --keychain-profile blackbox --wait` every ~60s until Accepted, then `xcrun stapler staple` manually.

Verify the DMG exists at `build/Blackbox-X.Y.Z.dmg` and report its file size. Then verify Gatekeeper end-to-end: `xcrun stapler validate` on the DMG, and mount it + `spctl -a -t exec -v /Volumes/Blackbox/Blackbox.app` -> must report `Notarized Developer ID`. (`spctl -t open` on the DMG itself reports "no usable signature" - expected; the DMG container is unsigned, the app inside is what matters.)

## Step 4: Sparkle Signature

Generate the Sparkle EdDSA signature:

```bash
.build/artifacts/sparkle/Sparkle/bin/sign_update build/Blackbox-X.Y.Z.dmg
```

Parse the output to extract `sparkle:edSignature="..."` and `length="..."` values. These are needed for the appcast.

## Step 5: Generate appcast.xml

Create `appcast.xml` in the project root:

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Blackbox</title>
    <item>
      <title>Version X.Y.Z</title>
      <pubDate>RFC 2822 DATE</pubDate>
      <sparkle:version>BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>X.Y.Z</sparkle:shortVersionString>
      <enclosure
        url="https://github.com/tenequm/blackbox/releases/download/vX.Y.Z/Blackbox-X.Y.Z.dmg"
        type="application/octet-stream"
        sparkle:edSignature="SIGNATURE"
        length="FILE_SIZE_BYTES"
      />
    </item>
  </channel>
</rss>
```

Replace placeholders with actual values. `sparkle:version` is the `CFBundleVersion` integer. Use `date -R` format for pubDate. Get file size with `stat -f%z`.

## Step 6: Commit and Push

```bash
git add Makefile Info.plist CHANGELOG.md Sources/ Tests/
git commit -m "chore: release vX.Y.Z"
git push
```

Use the exact version in the commit message. Only stage known files - never `git add -A`.

## Step 7: GitHub Release

Extract the changelog section for version X.Y.Z from `CHANGELOG.md` (everything between `## [X.Y.Z]` and the next `## [` heading). Use this as the release body.

```bash
gh release create vX.Y.Z build/Blackbox-X.Y.Z.dmg appcast.xml \
  --title "Blackbox X.Y.Z" \
  --notes "CHANGELOG_CONTENT"
```

Use a heredoc for the notes to preserve formatting.

## Step 8: Homebrew Tap Bump

A GitHub release does NOT update Homebrew - the cask is pinned in tenequm/homebrew-tap.

```bash
cd ~/Projects/homebrew-tap && git pull
curl -sL https://github.com/tenequm/blackbox/releases/download/vX.Y.Z/Blackbox-X.Y.Z.dmg | shasum -a 256
```

Update `Casks/blackbox-recorder.rb`: `version "X.Y.Z"` and the new `sha256`. Always hash the **published GitHub asset** (curl above), not the local file, so the cask matches what brew downloads. Then:

```bash
git add Casks/blackbox-recorder.rb && git commit -m "chore(blackbox): bump to X.Y.Z" && git push
```

Keep `auto_updates true` in the cask: Sparkle self-updates the app, so plain `brew upgrade` intentionally skips it (users can force with `--greedy`). Removing it would let a lagging cask downgrade a Sparkle-updated install.

## Step 9: Cleanup

```bash
rm -f appcast.xml
```

## Step 10: Summary

Report:
- Version released: X.Y.Z
- DMG: file size
- GitHub release URL (from `gh release view vX.Y.Z --json url -q .url`)
- Sparkle appcast: attached to release; verify the feed serves the new version: `curl -sL https://github.com/tenequm/blackbox/releases/latest/download/appcast.xml`
- Notarization: stapled
- Homebrew cask: bumped
