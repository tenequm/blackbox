# /collab-review — Quick Codex Second Opinion

Get a fast review from Codex on current changes without full collaboration.

## Workflow

1. **Identify what to review.** Run `git diff` for uncommitted changes, or use what the user describes.
2. **Summarize the changes.** Write a 2-3 sentence summary of what changed and why.
3. **Call Codex (synchronous — reviews are fast):**
   ```bash
   .claude/bin/codex-bridge.sh think "Review these recent changes. Focus on: bugs, edge cases, type safety, missing error handling. Be concise — bullet points, critical issues first, skip praise.

   Files changed: [list paths]
   Summary: [your 2-3 sentence summary]
   [User's specific concerns if any]"
   ```
4. **Synthesize.** Present to user:
   - Critical issues Codex found (if any)
   - Suggestions worth considering
   - Things Codex flagged that you disagree with (and why)
   - Your own observations not covered by Codex

## Rules

- Keep the Codex prompt under 300 words. Codex can read the files itself.
- Synthesize — don't relay raw output.
- If Codex finds nothing significant, say so. Don't invent issues.
- If no changes exist to review, tell the user and ask what they'd like reviewed.

$ARGUMENTS
