#!/usr/bin/env bash
# Changelog repair, run by git-cliff as a commit_preprocessor (see
# .github/cliff.toml). Reads a commit message on stdin, writes it back on
# stdout - unchanged, except for one case.
#
# The changelog prose lives in the squash-commit body, which is the PR
# description. A merge that submits an empty description field overrides that
# default and the note is gone from history for good - commit messages are
# immutable, and git-cliff's GitHub integration exposes pr_title/pr_number but
# no pr_body to fall back on.
#
# So when a squashed-PR commit carries no `## Release notes` section, fetch it
# from the PR that produced it and append it before git-cliff parses. Side
# benefit: a note can be corrected after merge by editing the PR description.
#
# Every failure path prints the message unchanged - a missing `gh`, no auth, no
# network, or an unparseable subject must never break changelog generation,
# which also runs locally (`git-cliff --unreleased`).
set -uo pipefail

msg=$(cat)
printf_msg() { printf '%s' "$msg"; exit 0; }

case "$msg" in *"
## Release notes"*) printf_msg ;; esac

subject=${msg%%"
"*}
pr=$(printf '%s' "$subject" | sed -n 's/.*(#\([0-9][0-9]*\))[[:space:]]*$/\1/p')
[ -n "$pr" ] || printf_msg
command -v gh >/dev/null 2>&1 || printf_msg

# Bounded: a hung call must not stall changelog generation either. `timeout` is
# absent from a bare macOS, where the call simply runs unbounded.
bound=""
command -v timeout >/dev/null 2>&1 && bound="timeout 20"
body=$($bound gh api "repos/${GITHUB_REPOSITORY:-tenequm/blackbox}/pulls/$pr" -q .body 2>/dev/null) || printf_msg
[ -n "$body" ] || printf_msg

# From the `## Release notes` header to the next `## ` header or end of body.
note=$(printf '%s\n' "$body" | awk '/^## Release notes/{f=1; print; next} f && /^## /{exit} f{print}')
printf '%s' "$note" | tr -d '[:space:]' | grep -q . || printf_msg

printf '%s\n\n%s\n' "$msg" "$note"
