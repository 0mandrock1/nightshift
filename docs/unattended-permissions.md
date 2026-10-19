# Unattended permissions — 2026-10-19

Owner authorization in the Crystl conversation:
- «и настрой харнесс посвободнее»
- «не лишаються теж міняються» (permission guards)
- Scope question: current run or general nightshift harness?
- Answer: «го в загальному».

## Effective policy

Applies to cc-run.sh and cc-chain.sh; swarm inherits cc-run.sh.

| Backend | Default | Override for restricted runs |
| --- | --- | --- |
| Codex sandbox | danger-full-access | CC_CODEX_SANDBOX=workspace-write |
| Codex approvals | never | CC_CODEX_APPROVAL_POLICY=on-request |
| Claude permissions | bypassPermissions | CC_CLAUDE_PERMISSION_MODE=acceptEdits |

This is an invocation policy for headless drivers. Interactive CLI config,
installed skills and node AGENTS.md are not edited. Full access permits the
agent to use existing credentials, edit task-related paths, commit and deploy
within the authorized task without requesting per-command permission.

Duplicate locks, budget/model gates, timeouts, secret handling and output/result
verification remain separate from permission guards. No new keys or password
rotation is authorized by this protocol.

## False failure correction

Crystl run crystl-pwa-20261019-0906 reused a run-dir after a failed Claude attempt.
Its Claude usage.json held total_out=0, while Codex events.jsonl reported 75644
output tokens. cc_out_tokens previously preferred usage.json regardless of
backend, causing a false no-work failure. Each backend now uses only its own
usage source; absent usage stays unknown. Previous run records are preserved.

## Verification

Regression tests:
- tests/test-harness-permissions.sh: actual argv for single/chain, Codex/Claude,
  permissive defaults and explicit restricted overrides (8 cases).
- tests/test-backend-usage-priority.sh: stale Claude zero cannot override Codex;
  missing Codex events do not fall back to unrelated Claude usage.

CLI flags checked against the installed codex help. Official documentation:
https://learn.chatgpt.com/docs/security
