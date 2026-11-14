# Subscription Usage

## Status

Implemented on branch `feat/subscription-usage`. Implementation plans:
`impl-plans/completed/subscription-usage-types.md`,
`impl-plans/completed/subscription-usage-exchange.md`,
`impl-plans/completed/subscription-usage-readme.md` and
`impl-plans/completed/subscription-usage-reader-cli.md`.

## Goal

Report the subscription rate-limit windows of the account that a CLI vendor
is signed in to: Claude Pro/Max 5-hour and weekly windows (`claude-code`) and
ChatGPT/Codex plan windows (`codex`). The data is exposed as a Swift library
API and as the `agent-gateway subscription-usage` command.

## Credential Boundary

The gateway asks the vendor CLI itself, over that CLI's own programmatic
stdio protocol, so the CLI uses its own sign-in. The gateway must never:

- read CLI credential files (`~/.claude/.credentials.json`, `~/.codex/auth.json`)
  or the macOS Keychain;
- call vendor HTTP endpoints (`api.anthropic.com/api/oauth/usage`,
  `chatgpt.com/backend-api/wham/usage`) directly.

`ccusage-gauge` is used only as a reference for what to display. Its approach
(token extraction plus private HTTP endpoints) is out of bounds.

## Public API

New file `Sources/AgentGateway/GatewaySubscriptionUsage.swift`:

- `GatewaySubscriptionUsageParams { protocolVersion, vendor, executable?, timeoutSeconds? }`
- `GatewaySubscriptionUsageResult { protocolVersion, vendor, planType?, available, windows }`
- `GatewaySubscriptionUsageWindow { kind, scope?, windowMinutes?, usedPercent, resetsAt? }`
- `GatewaySubscriptionUsageWindowKind`: `fiveHour` | `weekly` | `other`

Field rules:

- `kind` comes from `windowMinutes`: `300` is `fiveHour`, `10080` is `weekly`,
  and any other value or a missing value is `other`.
- `scope` is `nil` for a plan-wide window. Otherwise it names the subset, such
  as a Claude model display name or a Codex limit name or id.
- `usedPercent` is the vendor's 0-100 utilization, stored as a `Double`.
- `resetsAt` is encoded as an ISO 8601 UTC string with whole seconds
  (`2026-10-31T18:00:00Z`). Decoding accepts any number of fractional-second
  digits. Optional fields that are `nil` are omitted from JSON, which matches
  the existing synthesized `Codable` types.
- `available` is `false` when the vendor reports that the account has no
  subscription limits, for example when the CLI is signed in with an API key.
  In that case `windows` is `[]`. This is a successful answer, not an error.

New file `Sources/AgentGatewayAppCore/GatewaySubscriptionUsageReader.swift`.
It mirrors `GatewayModelListing` in `GatewayModelCatalog.swift`:

- `public protocol GatewaySubscriptionUsageReading: Sendable { func subscriptionUsage(_:) async throws -> GatewaySubscriptionUsageResult }`
- `extension ProductionGatewayExecutor: GatewaySubscriptionUsageReading`
- `public let gatewaySubscriptionUsageUnsupportedCode = -32040`
- `public let gatewaySubscriptionUsageFailureCode = -32041`

`-32040` and `-32041` do not appear anywhere in `Sources/`. These codes are
already taken, so subscription usage must not reuse them:

- `-32000`, `-32002`, `-32010` and `-32011`: general and vendor errors.
- `-32020`: model listing (unsupported vendor).
- `-32021`: transcription (unsupported vendor).
- `-32030` and `-32031`: decide. The OpenRouter decision transport failure
  and the invalid decision response are hard-coded in
  `GatewayDecisions.swift` and `GatewayDecisionValidation.swift`.

The request gave `-32030`/`-32031` only as an example ("e.g."). Reusing them
would make a subscription-usage failure indistinguishable from a decide
failure, so this design intentionally uses the next free pair instead.

## Validation And Errors

Checks run in this order. Each failure is a `GatewayRPCError`.

1. `protocolVersion != GatewayProtocolVersion.current` gives `-32602`. This is
   the same check `models()` makes.
2. The vendor is not `claude-code` or `codex` (`cursor`, `cursor-api`,
   `openai`, `anthropic`, `gemini`, `openrouter`) gives `-32040` with the
   message `"<vendor> does not report subscription usage"`. Vendor selection
   is explicit. There is no auto-detection.
3. `timeoutSeconds` is present and not finite or not `> 0` gives `-32602`.
   The default is `60` seconds, which covers Claude's ~15-20 s startup.
4. The executable cannot be resolved gives `-32041`
   (`"<vendor> executable unavailable"`).
5. Any of the following gives `-32041` with a message that names the
   executable:
   - the launch fails;
   - the child exits without answering (the message includes the stderr
     tail);
   - the timeout elapses;
   - the response cannot be parsed;
   - the vendor reports an error. Claude reports this as `subtype: "error"`
     and Codex as a JSON-RPC `error`, and the vendor's message is included.

The gateway spawns no process for checks 1-4. On platforms other than macOS
and Linux, the exchange throws `GatewayProcessError.launchFailed(ENOTSUP)`, so
iOS 17 library builds still compile.

## Executable Resolution

`params.executable ?? defaultGatewayExecutable(vendor)` (`claude` or `codex`)
is resolved with `resolveGatewayExecutable(_:environment:)` against the
executor's `environment`. Both functions in `GatewayExecution.swift` change
from `private` to `internal`. They are not duplicated. The same `environment`
is passed to the child. The child inherits the gateway's working directory.

## Vendor Protocols

### Claude Code (verified against claude 2.1.312)

Command:

```
claude -p --input-format stream-json --output-format stream-json --verbose \
  --strict-mcp-config --no-session-persistence --settings '{"disableAllHooks":true}'
```

The gateway writes one stdin line and sends no prompt and no `initialize`, so
nothing is billed and no transcript is written:

```json
{"type":"control_request","request_id":"agent-gateway-subscription-usage","request":{"subtype":"get_usage"}}
```

The response is the first stdout line where `type == "control_response"` and
`response.request_id` equals the id that was sent. The gateway skips every
other line, including system and hook events and lines that are not JSON.

Parsing (`response.response`):

- `planType` comes from `subscription_type`.
- `available` comes from `rate_limits_available`. If that key is missing, it
  is `true` when `rate_limits` is a non-empty object.
- The windows, in this order:
  1. `rate_limits.five_hour`: `fiveHour`, `windowMinutes: 300`, scope `nil`.
  2. `rate_limits.seven_day`: `weekly`, `windowMinutes: 10080`, scope `nil`.
  3. If `rate_limits.model_scoped` is an array, each entry in array order
     becomes a `weekly` window with `windowMinutes: 10080` and
     `scope: display_name`. Otherwise the gateway falls back to the legacy
     fields `seven_day_opus` (`scope: "Opus"`) and then `seven_day_sonnet`
     (`scope: "Sonnet"`).
- Each entry gives `usedPercent` from `utilization` (a number) and `resetsAt`
  from `resets_at`. Claude emits 6 fractional digits, which
  `ISO8601DateFormatter` rejects, so the fraction is truncated to 3 digits
  before parsing. An entry that is `null` or has no numeric `utilization` is
  skipped. An unparseable `resets_at` gives `resetsAt: nil`.
- Unknown keys are ignored.

### Codex (verified against codex-cli 0.166.0)

Command: `codex app-server`. Lines carry no `jsonrpc` field. The gateway
writes these lines in order:

```json
{"id":1,"method":"initialize","params":{"clientInfo":{"name":"agent-gateway","version":"<Version.current>"}}}
{"method":"initialized"}
{"id":2,"method":"account/rateLimits/read"}
```

`params` is omitted from the third line for compatibility. The response is the
first stdout line with `id == 2` and no `method` key. The gateway skips
notifications, server-initiated requests and the `id: 1` initialize response.

Parsing:

- A JSON-RPC `error` gives `-32041` with `error.message`.
- Snapshots: if `result.rateLimitsByLimitId` is a non-empty object, the gateway
  uses its values with the `codex` bucket first and the other buckets sorted
  by key. Otherwise it uses `[result.rateLimits]`.
- Scope is `nil` for the `codex` bucket or a missing `limitId`. Otherwise it is
  `limitName ?? limitId`.
- Each snapshot's `primary` and then `secondary` gives one window when it is
  non-null and has a numeric `usedPercent`. `windowMinutes` comes from
  `windowDurationMins`, `kind` is classified from the minutes, and `resetsAt`
  is unix seconds.
- `planType` is the first non-null `planType` across the snapshots.
- `available` is `!windows.isEmpty`.

## Interactive Line Exchange

New file `Sources/AgentGatewayAppCore/GatewayJSONLineExchange.swift`, guarded
by `#if os(macOS) || os(Linux)`. `POSIXGatewayProcessRunner` cannot be used,
because it writes all of stdin and then closes it, and `codex app-server`
exits on stdin EOF before it answers. The exchange behaves as follows:

- It spawns the child with Foundation `Process` and three `Pipe`s, following
  the `GatewayACPClientRunner` pattern.
- It reads stdout lines through `ACPFileHandleTransport(input: stdout, output: stdin)`.
  Stdout EOF ends the line stream and means the child exited.
- It writes each request line to stdin with the existing SIGPIPE-safe
  `gwp_write` from `GatewayProcessNative`, retrying partial writes. It does not
  use `ACPFileHandleTransport.send`, because `FileHandle.write(_:)` on a pipe
  whose reader has exited raises SIGPIPE or an uncatchable exception in the
  host. `EPIPE` means the child has exited, and the exchange takes the
  "exits without answering" path. The exchange installs no process-wide
  signal handler.
- Stdin stays open until the exchange finishes.
- A `readabilityHandler` drains stderr all the time, so the child cannot block
  on a full pipe, and keeps only the last 2 KiB.
- The exchange returns the first stdout line the vendor-specific matcher
  accepts.
- It finishes on whichever of these happens first:
  - **Matched response**: return the line.
  - **Stdout EOF or EPIPE without a match**: wait for the child to exit
    (bounded, see below), remove the stderr handler, read the rest of stderr
    and throw `-32041` (`"<name> exited without answering: <stderr tail>"`).
  - **Timeout**: throw `-32041` (`"<name> did not answer within <n>s"`).
- Cleanup runs on every path. It closes the pipes and, if the child is still
  running, sends SIGTERM. If the child has not exited after 2 s, it sends
  SIGKILL, so the call cannot hang on a child that ignores SIGTERM.
- Shared mutable state (stderr tail, completion) is lock-protected in
  `@unchecked Sendable` boxes, the same way `ACPFileHandleTransport` does it.
  The result is delivered exactly once.

## CLI

```
agent-gateway subscription-usage --vendor <claude-code|codex> [--executable <path>]
```

- The command is added to the dispatch list in `Command.swift` (the list that
  holds `"server", "client", "readiness", "models", "decide"`), to the
  `switch` and to the usage text. Arguments are parsed with the existing
  `parseOptions`.
- A missing or unknown `--vendor` is handled the same way as `models`
  (`missingValue("--vendor")`).
- On success the command prints one JSON line through `writeJSONLine` (sorted
  keys) and exits 0. This includes `available: false`.
- On `GatewayRPCError` (including `-32040` for `--vendor openai`) it writes
  `subscription usage failed (<code>): <message>` to stderr and exits 1.
- The CLI has no timeout flag. `timeoutSeconds` is available only through the
  library API.

Example output:

```json
{"available":true,"planType":"max","protocolVersion":"...","vendor":"claude-code","windows":[{"kind":"fiveHour","resetsAt":"2026-10-31T18:00:00Z","usedPercent":28,"windowMinutes":300}]}
```

## Verification

Unit tests go in `Tests/AgentGatewayTests/GatewaySubscriptionUsageTests.swift`.
They use `@testable` imports and need no real `claude` or `codex` CLI and no
network access:

- Claude parser:
  - the success fixture (microsecond `resets_at`, `model_scoped`);
  - the error subtype;
  - `rate_limits_available: false` gives `available: false` and
    `windows: []`;
  - the legacy `seven_day_opus` and `seven_day_sonnet` fallback.
- Codex parser:
  - a single bucket;
  - multiple buckets (ordering and scope);
  - an error response;
  - window classification;
  - unix-seconds `resetsAt`.
- Unsupported vendors (`cursor` and the API vendors) give `-32040` before any
  process is spawned.
- A window JSON round-trip with an ISO 8601 `resetsAt` string, using a
  whole-second date.
- The exchange, run against `chmod +x` shell scripts in a temp directory with
  short timeouts:
  - a script that skips unrelated lines and then answers;
  - a script that writes to stderr and exits without answering, giving an
    error that contains the stderr text;
  - a script that never answers, giving a timeout error.

Commands: `mise run build`, `mise run test`, `mise run lint`. Live smoke test,
where both CLIs are signed in: `swift run agent-gateway subscription-usage
--vendor codex`, `--vendor claude-code`, and `--vendor openai` (expect exit 1).

### Build Output Isolation

Implementation plans run in parallel in one working tree. Each plan therefore
owns its own generated-output root, `tmp/subscription-usage-build/<planId>`
(`tmp/` is gitignored and excluded in `.swiftlint.yml`):

- Every plan in the dispatch manifest lists that root in both `writePaths` and
  `artifactRoots`. This includes `subscription-usage-readme`, which runs no
  Swift build.
- Every per-plan SwiftPM command passes `--scratch-path <root>`:
  `swift build --scratch-path <root>`,
  `swift test --scratch-path <root> --filter <suite>`, and
  `swift run --scratch-path <root> agent-gateway subscription-usage ...` for
  the smoke tests.
- `swiftlint lint` builds nothing, so it does not need a scratch path. It runs
  with `--cache-path <root>/swiftlint-cache`, so its cache also stays inside
  the plan root.
- Verification logs go under `<root>/logs/`, not `/tmp`.
- Only the final integration verification (`mise run build`, `mise run test`,
  `mise run lint`) uses the default `.build`.

## Rollout Constraints

- `VERSION` is not bumped, and release is out of scope.
- Every Swift file stays under 1000 lines (`GatewayExecution.swift` is
  currently 682 lines).
- Both vendor protocols are undocumented. The parsers tolerate extra and
  missing keys. Any shape change surfaces as `-32041` or as missing windows,
  never as a crash.
