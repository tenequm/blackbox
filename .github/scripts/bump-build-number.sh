#!/usr/bin/env bash
# Sets Info.plist's CFBundleVersion to one past the highest ever released.
#
# Sparkle compares CFBundleVersion to decide whether an update exists, so this
# number must never go backwards - a lower value silently stops updates for
# everyone already on the higher one. release-please cannot own it because it is
# a monotonic integer rather than a semver.
#
# Derived from the released tags rather than incremented in place, so running
# this twice on the same branch is a no-op instead of a double bump.
set -euo pipefail

# python3, not PlistBuddy or plutil: this runs on ubuntu in the
# release-changelog job as well as on macOS from `make release`, and both of
# those tools are macOS-only. The script already needed python3 for the tag
# lookup below, so this adds no dependency.
current="$(python3 -c "import plistlib;print(plistlib.load(open('Info.plist','rb'))['CFBundleVersion'])")"

# Anchored to the last released tag, not to the working copy: deriving the next
# value from `current` would advance it again on every re-run, and this script
# runs once per push to the release PR branch.
last_tag="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
if [ -n "$last_tag" ]; then
  # loads(), not load(): a pipe is not seekable and plistlib.load seeks.
  base="$(git show "$last_tag:Info.plist" \
    | python3 -c "import plistlib,sys;print(plistlib.loads(sys.stdin.buffer.read())['CFBundleVersion'])")"
else
  base="$current"
fi

next=$((base + 1))
if [ "$current" = "$next" ]; then
  echo "CFBundleVersion already $next"
  exit 0
fi

python3 - "$next" <<'PY'
import re, sys

nxt = sys.argv[1]
src = open("Info.plist").read()
out, n = re.subn(
    r"(<key>CFBundleVersion</key>\s*<string>)\d+(</string>)",
    lambda m: m.group(1) + nxt + m.group(2),
    src,
    count=1,
)
if n != 1:
    raise SystemExit("could not find CFBundleVersion in Info.plist")
open("Info.plist", "w").write(out)
PY

python3 -c "import plistlib;plistlib.load(open('Info.plist','rb'))"
echo "CFBundleVersion: $current -> $next"
