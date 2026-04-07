#!/usr/bin/env bash
# codex-bridge.sh — Claude Code → Codex CLI bridge
#
# Usage:
#   codex-bridge.sh think "Your prompt here"
#   codex-bridge.sh build "Your prompt here"
#   codex-bridge.sh build "Implement this spec" .collab/specs/task.md
#
# Modes:
#   think — Read-only. Codex reads files but changes nothing.
#           For debate, review, architecture, debugging hypotheses.
#   build — Workspace-write + full-auto. Codex creates/modifies files.
#           For implementation tasks delegated by Claude.
#
# Security:
#   Unsets OPENAI_API_KEY to force subscription auth (chatgpt mode).
#   Your project's API key for embeddings/moderation is NOT used by Codex.

set -euo pipefail

MODE="${1:?Usage: codex-bridge.sh <think|build> \"prompt\" [spec-file]}"
PROMPT="${2:?Usage: codex-bridge.sh <think|build> \"prompt\" [spec-file]}"
SPEC_FILE="${3:-}"

# If a spec file is provided, prepend its contents to the prompt
if [[ -n "$SPEC_FILE" && -f "$SPEC_FILE" ]]; then
  PROMPT="## Build Spec
$(cat "$SPEC_FILE")

## Instructions
${PROMPT}"
fi

# ── Security ──────────────────────────────────────────────
# CRITICAL: Many projects have OPENAI_API_KEY in the environment for
# embeddings and moderation. We MUST unset it so Codex CLI
# falls back to ~/.codex/auth.json (chatgpt subscription).
# This prevents accidental API billing.
unset OPENAI_API_KEY

# Suppress OpenTelemetry crash (known Codex CLI bug)
export OTEL_SDK_DISABLED=true

# ── Execute ───────────────────────────────────────────────
case "$MODE" in
  think)
    exec codex exec -s read-only "$PROMPT"
    ;;
  build)
    exec codex exec --full-auto "$PROMPT"
    ;;
  *)
    echo "Error: Mode must be 'think' or 'build'. Got: $MODE" >&2
    exit 1
    ;;
esac
