# Subscription Usage: README Documentation

**Status**: Ready
**Plan ID**: `subscription-usage-readme`
**Wave**: 1 (no dependencies; documentation only)
**Design Reference**: `design-docs/specs/design-subscription-usage.md` (all sections)

## Purpose

The acceptance criteria require README.md to document the
`subscription-usage` command and its library API, and to state that the
gateway asks the vendor CLI itself and reads no credentials.
`design-docs/specs/command.md` was already updated in the accepted design step.
Do not edit it.

## Repository Context

- Imitate `README.md` section `## Vendor model catalog` (around line 202). It
  has a short intro, a `bash` CLI example, a `swift` library snippet through
  the protocol, and prose about unsupported vendors.
- The facts to document all come from the accepted design. Do not invent any
  others.

## Write Ownership

- `README.md`
- `impl-plans/active/subscription-usage-readme.md` (this plan's progress log only)
- `tmp/subscription-usage-build/subscription-usage-readme` (artifact root for
  verification output only; gitignored, never committed). This plan runs no
  Swift build.

Edit discipline: re-read `README.md` right before every edit. Record
`shasum -a 256 README.md` in the progress log before the first edit and after
the last one. If it changes between your own edits (drift), stop and record
it; do not overwrite it.

## Changes

Insert a new `## Subscription usage` section immediately before
`## Audio transcription`. Do not reflow or edit any other README section. The
section contains:

1. One sentence: it reports the signed-in account's subscription rate-limit
   windows (Claude Pro/Max 5-hour and weekly, ChatGPT/Codex plan windows) for
   `claude-code` and `codex`.
2. A `bash` example: `agent-gateway subscription-usage --vendor codex` and
   `agent-gateway subscription-usage --vendor claude-code --executable /path/to/claude`.
3. A sample output line, taken from the design's example and kept compact:
   `{"available":true,"planType":"max","protocolVersion":"...","vendor":"claude-code","windows":[{"kind":"fiveHour","resetsAt":"2026-10-31T18:00:00Z","usedPercent":28,"windowMinutes":300}]}`.
4. Field notes:
   - `kind` is `fiveHour`, `weekly` or `other`, classified from `windowMinutes`.
   - `scope` is absent for a plan-wide window, a model name for a
     Claude model-scoped weekly window, or the limit name or id for a
     non-default Codex bucket.
   - `usedPercent` runs from 0 to 100.
   - `resetsAt` is an ISO 8601 UTC string.
   - `available: false` (for example, a CLI signed in with an API key) exits 0
     with an empty `windows`.
5. A credential boundary paragraph:
   - The gateway spawns the vendor CLI and asks it over the CLI's own stdio
     protocol: Claude Code stream-json `get_usage` control request, and the
     Codex `app-server` `account/rateLimits/read`.
   - The CLI uses its own sign-in.
   - The gateway never reads credential files or the Keychain and never calls
     vendor HTTP endpoints.
   - No prompt is sent to Claude, so nothing is billed.
   - Claude takes about 15-20 s to start.
6. A `swift` library snippet:
   `let usage = try await ProductionGatewayExecutor().subscriptionUsage(GatewaySubscriptionUsageParams(vendor: .codex))`
   through `GatewaySubscriptionUsageReading`, plus one sentence saying that
   `timeoutSeconds` (default 60) is available only through the library.
7. Errors:
   - Other vendors fail with `GatewayRPCError` code `-32040` (CLI: exit 1).
   - A missing executable, a launch or exit failure, a timeout or a vendor
     error gives `-32041`.
   - The CLI prints `subscription usage failed (<code>): <message>` on stderr.

## Pitfalls

- Use the codes `-32040` and `-32041`. The intake's example codes
  `-32030`/`-32031` are wrong because the decide path already uses them.
- Do not mention ccusage-gauge's Keychain or HTTP approach as an option.
- No emojis. English only.

## Verification (repository root, foreground)

Run `mkdir -p tmp/subscription-usage-build/subscription-usage-readme/logs`
first.

| Command | Must show |
| --- | --- |
| `grep -n "^## Subscription usage\|^## Audio transcription" README.md` | exactly one `## Subscription usage` line, with a line number lower than `## Audio transcription` |
| `grep -c -- "-32040\|-32041\|subscriptionUsage(\|account/rateLimits/read\|get_usage" README.md` | at least 5 |
| `grep -n -- "-3203[01]" README.md` | no output (exit status 1) |
| `git diff --numstat README.md` | the deleted-lines column is `0` |
| `git diff README.md > tmp/subscription-usage-build/subscription-usage-readme/logs/readme.diff; echo exit=$?` | exit=0; the diff is saved as evidence |
| `git status --porcelain --untracked-files=all` | only `README.md` and this plan file changed (`tmp/` is ignored) |

Record the commands, outputs and the evidence path in the progress log.

## Done Criteria

- [ ] The section exists with items 1-7 above.
- [ ] All the grep checks pass, and no other file was changed.

## Progress Log

- 2026-10-31: Plan created.
- 2026-11-01: Amended (session-593). Added the plan-unique artifact root
  `tmp/subscription-usage-build/subscription-usage-readme` for verification
  evidence, and added the edit discipline. Deletions are checked with
  `git diff --numstat`.
