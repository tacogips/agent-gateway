# Subscription Usage: Reader, Vendor Parsers and CLI Command

**Status**: Ready
**Plan ID**: `subscription-usage-reader-cli`
**Wave**: 2. Depends on `subscription-usage-types` and `subscription-usage-exchange`.
**Design Reference**: `design-docs/specs/design-subscription-usage.md`
(sections Public API, Validation And Errors, Executable Resolution, Vendor
Protocols, CLI and Verification)

## Purpose

Wire the feature together: `ProductionGatewayExecutor.subscriptionUsage(_:)`
validates the request, resolves the vendor CLI, runs the wave-1 exchange with
the vendor-specific requests and matcher, parses the matched line into the
wave-1 types, and the new `agent-gateway subscription-usage` command prints
the result. The gateway never reads credential files or the Keychain and
never makes HTTP calls. It only spawns `claude` or `codex`.

## Inputs From Wave 1 (must exist before starting; do not modify them)

- `Sources/AgentGateway/GatewaySubscriptionUsage.swift`: `GatewaySubscriptionUsageParams`,
  `GatewaySubscriptionUsageResult`, `GatewaySubscriptionUsageWindow`,
  `GatewaySubscriptionUsageWindowKind.classify(windowMinutes:)`, and
  `package func parseGatewayISO8601Date(_:) -> Date?`.
- `Sources/AgentGatewayAppCore/GatewayJSONLineExchange.swift`:
  `exchangeGatewayJSONLines(executable:arguments:environment:requests:timeoutSeconds:isResponse:) async throws -> Data`
  and `GatewayJSONLineExchangeError { launchFailed(String), exitedWithoutAnswer(stderrTail:), timedOut(seconds:) }`.

If either contract differs from this description, stop and record the drift
in the progress log. Do not edit the wave-1 files.

## Repository Context

- Pattern to imitate:
  `Sources/AgentGatewayAppCore/GatewayModelCatalog.swift`. It defines a public
  protocol `GatewayModelListing`, a `public let gatewayModelListingUnsupportedCode`,
  and an `extension ProductionGatewayExecutor: GatewayModelListing` with the
  `protocolVersion` guard, and it throws `GatewayRPCError(code:message:)`.
- `ProductionGatewayExecutor.environment` is at `GatewayExecution.swift:57-76`.
- `GatewayExecution.swift:308` `private func defaultGatewayExecutable` and
  `:317` `private func resolveGatewayExecutable(_:environment:)` (the file is 682 lines).
- `Version.current` is at `Sources/AgentGatewayAppCore/Version.swift`.
- CLI: `Sources/AgentGatewayAppCore/Command.swift`. The dispatch list is
  `["server", "client", "readiness", "models", "decide"]` at line 26, the
  `runStreaming` switch is around lines 37-81 (the `case "models"` block is
  the template), `modelCatalogParams` is at line 131 (the template for the
  params builder), and `usage` is at lines 87-128. `main.swift` maps
  `missingValue` to exit 2 and other thrown errors to exit 1. Do not edit
  `main.swift`.
- Draft (starting point only, never compiled):
  `/private/tmp/claude-501/-Users-taco-gits-tacogips-agent-gateway/5cb159dd-584b-44c9-a008-3268ffda8a01/scratchpad/draft/GatewaySubscriptionUsageReader.swift`.
  It has known defects to fix: it uses the wrong constant name and codes, its
  Codex matcher lacks the `method` check, and it uses
  `as? [String: [String: Any]]` for buckets.
- Tests use swift-testing. Imitate
  `Tests/AgentGatewayTests/GatewayModelCatalogTests.swift`, including
  `modelsCommandBuildsTypedParams` for CLI params tests, and
  `GatewayExecutorEnvironmentTests.swift` for fake executables.

## Write Ownership

- `Sources/AgentGatewayAppCore/GatewaySubscriptionUsageReader.swift` (new)
- `Sources/AgentGatewayAppCore/GatewayExecution.swift`: only remove `private`
  from the two functions at lines 308 and 317.
- `Sources/AgentGatewayAppCore/Command.swift`: dispatch list, switch case,
  params builder and usage text.
- `Tests/AgentGatewayTests/GatewaySubscriptionUsageTests.swift` (new)
- `impl-plans/active/subscription-usage-reader-cli.md` (this plan's progress log only)
- `tmp/subscription-usage-build/subscription-usage-reader-cli`
  (generated-output root and artifact root: SwiftPM scratch directory,
  swiftlint cache, verification logs and smoke outputs; gitignored, never
  committed)

All SwiftPM output for this plan, including the `swift run` smoke tests, goes
to that root (`--scratch-path`). Do not build into the default `.build`.

Edit discipline: re-read each owned file right before every edit. Record
`shasum -a 256 <owned files>` in the progress log before the first edit and
after the last one, and record the wave-1 files' hashes when you start. If any
owned or wave-1 file changes unexpectedly (drift), stop and record it; do not
overwrite it. Cross-plan repair happens serially after the join.

## Contract

```swift
public protocol GatewaySubscriptionUsageReading: Sendable {
  func subscriptionUsage(_ params: GatewaySubscriptionUsageParams) async throws -> GatewaySubscriptionUsageResult
}
public let gatewaySubscriptionUsageUnsupportedCode = -32040
public let gatewaySubscriptionUsageFailureCode = -32041
extension ProductionGatewayExecutor: GatewaySubscriptionUsageReading
func subscriptionUsageParams(_ arguments: [String]) throws -> GatewaySubscriptionUsageParams   // in AppCommand, internal
```

Use internal free functions so tests can reach them:
`parseClaudeSubscriptionUsage(_ line: Data) throws -> GatewaySubscriptionUsageResult`
and `parseCodexSubscriptionUsage(_ line: Data) throws -> GatewaySubscriptionUsageResult`.

## Required Behavior

### `subscriptionUsage(_:)` (validation order is fixed; nothing is spawned before step 5)

1. `params.protocolVersion != GatewayProtocolVersion.current` gives
   `GatewayRPCError(-32602, "unsupported protocol version '<v>'")`.
2. A vendor other than `.claudeCode` or `.codex` gives
   `GatewayRPCError(-32040, "<vendor.rawValue> does not report subscription usage")`.
   Use an exhaustive `switch` that lists every `GatewayVendor` case, with no
   `default`.
3. If `timeoutSeconds` is present and not (`isFinite && > 0`), throw
   `GatewayRPCError(-32602, "timeoutSeconds must be a positive number")`. The
   default is 60.
4. Resolve `params.executable ?? defaultGatewayExecutable(vendor)` with
   `resolveGatewayExecutable(_:environment: environment)`. If it is nil, throw
   `GatewayRPCError(-32041, "<vendor.rawValue> executable unavailable")`.
5. Call `exchangeGatewayJSONLines` with the resolved path, the vendor
   arguments and requests, `environment` (the executor's own) and the matcher.
   Map `GatewayJSONLineExchangeError`, where `name` is the resolved path's
   `lastPathComponent`:
   - `.launchFailed(d)` gives `-32041 "<name> failed to launch: <d>"`.
   - `.exitedWithoutAnswer(t)` gives `-32041 "<name> exited without answering"`,
     plus `": <t>"` when `t` is non-empty.
   - `.timedOut(s)` gives `-32041 "<name> did not answer within <s>s"`.

   Let `GatewayProcessError` (ENOTSUP on other platforms) pass through unchanged.
6. Parse the line with the vendor parser.

### Claude Code

- Arguments, exactly:
  `["-p","--input-format","stream-json","--output-format","stream-json","--verbose","--strict-mcp-config","--no-session-persistence","--settings","{\"disableAllHooks\":true}"]`.
- Exactly one request: `{"type":"control_request","request_id":"agent-gateway-subscription-usage","request":{"subtype":"get_usage"}}`.
  Send no prompt and no initialize.
- Matcher: the line is a JSON object with `type == "control_response"` and
  `response.request_id == "agent-gateway-subscription-usage"`.
- Parser:
  - `response.subtype == "error"` gives
    `-32041 "claude-code usage request failed: <response.error ?? "unknown error">"`.
  - A missing `response.response` object gives
    `-32041 "claude-code returned an invalid usage response"`.
  - `planType` comes from `subscription_type`, and `limits` is `rate_limits`
    (or an empty object).
  - `available` is `rate_limits_available as? Bool ?? !limits.isEmpty`. When
    `available` is false, `windows` is `[]`.
  - Windows, in this order:
    1. `five_hour` gives `.fiveHour`, 300, scope nil.
    2. `seven_day` gives `.weekly`, 10080, scope nil.
    3. If `model_scoped` is an array, each element in order gives `.weekly`,
       10080, `scope: display_name`. Otherwise use `seven_day_opus`
       (`"Opus"`) and then `seven_day_sonnet` (`"Sonnet"`).
  - An entry is skipped when it is not an object or when `utilization` is not
    numeric (`as? NSNumber`). `resetsAt` is
    `(resets_at as? String).flatMap(parseGatewayISO8601Date)`.

### Codex

- Arguments: `["app-server"]`.
- Requests, in order:
  1. `{"id":1,"method":"initialize","params":{"clientInfo":{"name":"agent-gateway","version":"<Version.current>"}}}`
  2. `{"method":"initialized"}`
  3. `{"id":2,"method":"account/rateLimits/read"}` (no `params` key, and no
     `jsonrpc` field on any line).
- Matcher: the line is a JSON object where `id as? Int == 2` and there is no
  `method` key.
- Parser:
  - A JSON-RPC `error` object gives
    `-32041 "codex usage request failed: <error.message ?? "unknown error">"`.
  - A missing `result` gives `-32041 "codex returned an invalid usage response"`.
  - Snapshots: if `result.rateLimitsByLimitId` is a non-empty `[String: Any]`,
    use the values that are objects, with key `codex` first and the other
    keys sorted ascending. Otherwise use `[result.rateLimits]` when it is an
    object, else `[]`.
  - Scope is nil when `limitId` is nil or `"codex"`, otherwise
    `limitName ?? limitId`.
  - Each snapshot's `primary` and then `secondary`: skip it when it is null or
    `usedPercent` is not numeric. `windowMinutes` is
    `windowDurationMins as? NSNumber -> Int`, `kind` is
    `.classify(windowMinutes:)`, and `resetsAt` is
    `Date(timeIntervalSince1970: resetsAt.doubleValue)`.
  - `planType` is the first non-nil `planType` across the snapshots.
  - `available` is `!windows.isEmpty`.

### Helpers

Use private `jsonObject(_:) -> [String: Any]?` and a request-line builder
with `JSONSerialization` and `.sortedKeys`. The serialization error must not
be silently swallowed into empty `Data`: build the request lines once and
`try` them, or encode them with `JSONEncoder` from small `Encodable` structs.

### `GatewayExecution.swift`

Change only `private func defaultGatewayExecutable` to `func defaultGatewayExecutable`
and `private func resolveGatewayExecutable` to `func resolveGatewayExecutable`.
Do not duplicate them in the reader.

### `Command.swift`

1. Add `"subscription-usage"` to the dispatch list at line 26.
2. In `runStreaming`, add `case "subscription-usage":`, modelled on
   `case "models":`:
   - build the params with `subscriptionUsageParams`;
   - call `ProductionGatewayExecutor().subscriptionUsage(params)`;
   - print the result with `writeJSONLine` and return 0;
   - `catch let error as GatewayRPCError`: write
     `subscription usage failed (<code>): <message>\n` to stderr and return 1.
3. Add `func subscriptionUsageParams(_ arguments: [String]) throws -> GatewaySubscriptionUsageParams`
   next to `modelCatalogParams`. It uses `parseOptions`. A missing or unknown
   `--vendor` throws `Error.missingValue("--vendor")`. It passes
   `executable: options.executable`. It has no timeout flag.
4. Usage text:
   - Add the synopsis line
     `agent-gateway subscription-usage --vendor <claude-code|codex> [--executable <path>]`
     after the `models` line.
   - Add a short paragraph: `subscription-usage` prints the signed-in
     account's subscription rate-limit windows as JSON by asking the vendor
     CLI itself over its stdio protocol. It never reads credential files or
     the Keychain and makes no HTTP calls.

## Pitfalls

- Codes are `-32040` and `-32041`. Never use `-32030` or `-32031`, which the
  decide path already uses (`GatewayDecisions.swift`).
- Do not close stdin early and do not use `POSIXGatewayProcessRunner` or
  `processRunner`.
- Do not read `~/.claude`, `~/.codex`, the Keychain or any HTTP endpoint, and
  do not import FoundationNetworking.
- `JSONSerialization` numbers: use `as? NSNumber` for numeric fields. A
  `[String: [String: Any]]` cast fails whenever one bucket is null.
- Keep `Command.swift` (currently 347 lines) and the reader each under
  1000 lines. Do not reformat unrelated code.

## Tests (`GatewaySubscriptionUsageTests.swift`, `@testable import AgentGateway` and `AgentGatewayAppCore`)

Prefix every test function name with `subscriptionUsage`. No real CLI and no
network.

- Claude success fixture. Use the exact sample from the design and intake:
  `five_hour` 28 with `resets_at` `2026-10-31T18:00:00.066915+00:00`,
  `seven_day` 68, `seven_day_opus`/`seven_day_sonnet` null, and
  `model_scoped` `[{"display_name":"Fable","utilization":0,"resets_at":"2026-11-01T17:00:00+00:00"}]`.
  Add extra unknown keys. Expected: `planType "max"`, `available true`, and
  3 windows in order `[fiveHour/nil/300/28, weekly/nil/10080/68, weekly/"Fable"/10080/0]`.
  The first `resetsAt` is non-nil.
- Claude `subtype "error"` with `error "boom"` throws -32041, and the message
  contains `boom`.
- Claude `rate_limits_available:false` with a non-empty `rate_limits` gives
  `available false` and `windows []`.
- Claude without `model_scoped`, with `seven_day_opus` 40 and
  `seven_day_sonnet` null, gives the windows five_hour, seven_day, then
  `weekly/"Opus"/40`, and no Sonnet window.
- Codex with a single `rateLimits` (no `rateLimitsByLimitId`): `primary`
  91/10080/1793774131 and `secondary` null give one window
  `weekly/nil/10080/91` with `resetsAt == Date(timeIntervalSince1970: 1793774131)`,
  `planType "pro"` and `available true`.
- Codex multi-bucket: keys `zeta` (limitName "Zeta Model", primary 300 min),
  `codex` (primary 300, secondary 10080) and `alpha` (limitName null,
  limitId "alpha", primary 60). Expected order: codex primary
  (`fiveHour`, nil), codex secondary (`weekly`, nil), alpha (`other`,
  "alpha"), zeta (`fiveHour`, "Zeta Model").
- Codex `{"id":2,"error":{"message":"denied"}}` throws -32041, and the message
  contains `denied`.
- Unsupported vendors: for each of `.cursor`, `.cursorAPI`, `.openAI`,
  `.anthropic`, `.gemini` and `.openRouter`, `subscriptionUsage` throws code
  -32040, using `executable: "deliberately-absent"`, which proves that
  rejection comes before resolution.
- `protocolVersion "0"` gives -32602, and `timeoutSeconds: 0` with
  `.codex` gives -32602.
- `.codex` with `executable: "<tmp>/missing"` gives -32041 with
  `executable unavailable`.
- Executor end-to-end with a fake codex. The `#!/bin/sh` script reads 3 lines
  (it fails with `exit 1` if it gets fewer), prints a notification line, then
  the single-bucket response with `"id":2`, then loops on `read`. Executor
  environment `["PATH": "/usr/bin:/bin"]`, `executable: <script path>`,
  `timeoutSeconds: 10`. Expected: a parsed result with one weekly window.
- Executor end-to-end with a fake claude. The script reads 1 line, prints
  `{"type":"system","subtype":"hook_started"}`, then the success fixture, then
  loops. Expected: the parsed result.
- Executor with a fake script that writes `nope` to stderr and exits 2 gives
  -32041, and the message contains `exited without answering` and `nope`.
- CLI params: `subscriptionUsageParams(["--vendor","codex","--executable","/x"])`
  gives `.codex` and `/x`. `["--vendor","bogus"]` and `[]` throw
  `AppCommand.Error.missingValue("--vendor")`.
- Usage: `AppCommand(arguments: ["--help"]).run()` contains
  `subscription-usage --vendor <claude-code|codex>`.

## Verification (repository root, foreground)

`R` below means `tmp/subscription-usage-build/subscription-usage-reader-cli`.
Write the full path in the actual commands. Run `mkdir -p <R>/logs` first.
Redirect to files instead of piping through `tee`, so `echo exit=$?` reports
the command's own exit status. The `swift run` smokes use `--skip-build`
after the build step, so the outputs contain only the command's own output.

| Command | Must show |
| --- | --- |
| `swift build --scratch-path <R> > <R>/logs/build.log 2>&1; echo exit=$?` | exit=0 |
| `swift test --scratch-path <R> --filter subscriptionUsage > <R>/logs/test.log 2>&1; echo exit=$?` | exit=0; the log shows every `subscriptionUsage*` test passed (including the wave-1 `subscriptionUsageTypes*` tests), 0 failures |
| `swiftlint lint --cache-path <R>/swiftlint-cache Sources/AgentGatewayAppCore/GatewaySubscriptionUsageReader.swift Sources/AgentGatewayAppCore/Command.swift Sources/AgentGatewayAppCore/GatewayExecution.swift Tests/AgentGatewayTests/GatewaySubscriptionUsageTests.swift; echo exit=$?` | 0 violations, exit=0 |
| `git diff -U0 Sources/AgentGatewayAppCore/GatewayExecution.swift` | only the two `private` removals |
| `grep -rn -- "-3203[01]" Sources/AgentGatewayAppCore/GatewaySubscriptionUsageReader.swift` | no output |
| `swift run --scratch-path <R> --skip-build agent-gateway subscription-usage --vendor openai > <R>/logs/smoke-openai.out 2> <R>/logs/smoke-openai.err; echo exit=$?` | exit=1; `smoke-openai.err` contains `subscription usage failed (-32040)` |
| `swift run --scratch-path <R> --skip-build agent-gateway subscription-usage --vendor codex > <R>/logs/smoke-codex.out 2> <R>/logs/smoke-codex.err; echo exit=$?` | exit=0; `smoke-codex.out` is one JSON line with `"vendor":"codex"` (live; if the sandbox blocks the CLI or network, record a gap with the stderr, not a pass) |
| `swift run --scratch-path <R> --skip-build agent-gateway subscription-usage --vendor claude-code > <R>/logs/smoke-claude.out 2> <R>/logs/smoke-claude.err; echo exit=$?` | exit=0; `smoke-claude.out` is one JSON line with `"vendor":"claude-code"` (live; about 20 s; same gap rule) |
| `git status --porcelain --untracked-files=all` | this plan adds or changes only its owned files (`tmp/` is ignored) |

The full `mise run build`, `mise run test` and `mise run lint` gates run at
integration review after all plans join, using the default `.build`. Record
every command, exit status and full log path under `<R>/logs/` in the progress
log. A truncated log, or a run that is still going, does not count as a pass.

## Done Criteria

- [ ] The Contract symbols exist with the exact names and values.
- [ ] Validation order and error messages match "Required Behavior".
- [ ] All the listed tests exist and pass, and the build and lint checks above are clean.
- [ ] `--vendor openai` exits 1 with -32040, verified.
- [ ] Only the owned files changed (`git status --porcelain --untracked-files=all`).
- [ ] No `.build` output was produced by this plan; all build and smoke output is under `tmp/subscription-usage-build/subscription-usage-reader-cli`.

## Progress Log

- 2026-10-31: Plan created.
- 2026-11-01: Amended (session-593). Added the plan-unique artifact root
  `tmp/subscription-usage-build/subscription-usage-reader-cli`. Build, test
  and `swift run` smokes now use `--scratch-path`, swiftlint uses
  `--cache-path`, and logs go under the root with no `tee`.
