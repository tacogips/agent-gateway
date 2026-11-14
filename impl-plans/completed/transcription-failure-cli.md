# Transcription Failure: CLI Structured Stderr

**Status**: Completed
**Plan ID**: `transcription-failure-cli`
**Wave**: 3
**Depends On**: `transcription-failure-type`, `transcription-failure-pipeline`
**Design Reference**: `design-docs/specs/design-transcription-failure.md`
(sections CLI, Verification > CLI tests);
`design-docs/specs/design-transcribe-cli.md` (Output And Exit Codes)

## Intent

When the vendor or the transport fails, `agent-gateway transcribe` must
print the classification, the HTTP status, the vendor type and code, and
Retry-After to stderr, and exit with a non-zero status. It must never print
the credential.

## Repository Context

- `Sources/AgentGatewayAppCore/GatewayTranscriptionCommand.swift`:
  `AppCommand.runTranscription(_:transcriber:)`, with its catch clauses at
  about lines 94-102.
- `Tests/AgentGatewayAppCoreTests/TranscribeCommandTests.swift`:
  - the private `RecordingTransport` (lines 9-27);
  - the `run` helper (line 35);
  - the existing `httpErrors` test (line 123). It must keep passing
    unchanged, because the first stderr line stays the same.
- The public type and its `rpcError` come from
  `Sources/AgentGatewayAppCore/GatewayTranscriptionFailure.swift`. The
  wave-2 plan has the pipeline throwing it.

## Non-Goals

- Do not change the stdout format, the success output, the flag parsing,
  `Command.swift`, `main.swift`, the exit-2 parse-error path, or the
  existing `GatewayRPCError` and other-error rows.
- Do not print `vendorMessage` or `rawBody` on separate lines.
- Do not edit library files or `Tests/AgentGatewayTests/*`.

## Write Ownership

- `Sources/AgentGatewayAppCore/GatewayTranscriptionCommand.swift`
- `Tests/AgentGatewayAppCoreTests/TranscribeCommandTests.swift`
- `impl-plans/active/transcription-failure-cli.md` (Progress Log only)
- `tmp/transcription-failure-build/transcription-failure-cli` (artifact root)

Edit discipline:

- Record `shasum -a 256` of both owned files before the first edit and
  after the last edit.
- Re-read each file before every edit. If you find drift, stop and record
  it.

## Changes

1. In `runTranscription`, add `catch let failure as GatewayTranscriptionFailure`
   BEFORE `catch let error as GatewayRPCError`. It returns status 1, empty
   stdout, and a stderr of exactly these six lines, each ending in `\n`:

   ```
   transcription failed (-32010): <failure.message>
   classification: <failure.classification.rawValue>
   http-status: <httpStatus or none>
   vendor-error-type: <vendorErrorType or none>
   vendor-error-code: <vendorErrorCode or none>
   retry-after-seconds: <retryAfterSeconds or none>
   ```

   - Build the first line from `failure.rpcError.code` and
     `failure.message`.
   - Every field line is always present. A nil value prints as `none`.
2. In `TranscribeCommandTests.swift`, `RecordingTransport` gains two init
   parameters with defaults: `headers: [String: String] = [:]`, passed to
   `HTTPURLResponse(... headerFields:)`, and `error: (any Error)? = nil`,
   thrown after the request is recorded.
   - Existing call sites must compile unchanged.

## Pitfalls

- The order of the catch clauses matters. If the new clause comes after
  `GatewayRPCError`, it still works, but a generic `catch` placed first
  would swallow the failure. Put the new clause first.
- Do not add `localizedDescription` text or extra lines.
- The `httpErrors` test must keep passing unchanged. It checks for
  `transcription failed (-32010)`, `vendor HTTP 429`, and the code string.

## Tests (add to the `TranscribeCommandTests` suite)

Each case is `input -> expected`:

- `structuredQuotaFailure`: the stub returns 429 with body
  `{"error":{"type":"insufficient_quota","code":"credit_balance_exhausted","message":"quota"}}`
  and header `Retry-After: 7`.
  - The status is 1 and stdout is empty.
  - stderr equals EXACTLY the six-line string, whose first line is
    `transcription failed (-32010): vendor HTTP 429: <body>`, followed by:
    - `classification: quotaExhausted`
    - `http-status: 429`
    - `vendor-error-type: insufficient_quota`
    - `vendor-error-code: credit_balance_exhausted`
    - `retry-after-seconds: 7`
  - stderr does not contain `fixture-secret`.
  - The stub count is 1.
- `structuredTransportFailure`: the stub throws `URLError(.notConnectedToInternet)`.
  - The status is 1.
  - stderr contains `classification: transport`, `http-status: none`,
    `vendor-error-type: none`, `vendor-error-code: none`, and
    `retry-after-seconds: none`.
  - The stub count is 1.
- `secretBoundaryInStderr`:
  - environment `["TEST_OPENAI_KEY": "fixture-secret-0123456789abcdef"]`;
  - the stub returns 429 with a body of 480 `"x"`s, then the key, then 100
    `"x"`s.
  - For every n in 8...31, stderr does not contain the key's n-byte
    prefix. stderr contains `[REDACTED]`.
- The existing `httpErrors` test passes unchanged, and so does every other
  existing test.

## Verification (repository root, foreground)

Run `mkdir -p tmp/transcription-failure-build/transcription-failure-cli/logs`
first. Record each exit code and log path.

| Command | Must show |
| --- | --- |
| `swift build --scratch-path tmp/transcription-failure-build/transcription-failure-cli > tmp/transcription-failure-build/transcription-failure-cli/logs/build.log 2>&1; echo exit=$?` | `exit=0` |
| `swift test --scratch-path tmp/transcription-failure-build/transcription-failure-cli --filter TranscribeCommandTests > tmp/transcription-failure-build/transcription-failure-cli/logs/test.log 2>&1; echo exit=$?` | `exit=0`, with the 3 new tests and all existing tests passing |
| `swiftlint lint --cache-path tmp/transcription-failure-build/transcription-failure-cli/swiftlint-cache Sources/AgentGatewayAppCore/GatewayTranscriptionCommand.swift Tests/AgentGatewayAppCoreTests/TranscribeCommandTests.swift > tmp/transcription-failure-build/transcription-failure-cli/logs/lint.log 2>&1; echo exit=$?` | `exit=0`, 0 violations |
| `wc -l Sources/AgentGatewayAppCore/GatewayTranscriptionCommand.swift Tests/AgentGatewayAppCoreTests/TranscribeCommandTests.swift` | each under 1000 |
| `git diff --stat` | in this plan's scope, only the two owned files have changed |

## Done Criteria

- [x] `GatewayTranscriptionFailure` is caught first and rendered as the
      exact six-line stderr, with exit 1.
- [x] The three new tests pass. The existing `TranscribeCommandTests` pass
      unchanged.
- [x] Build, test, and lint all exit 0, with logs under
      `tmp/transcription-failure-build/transcription-failure-cli/logs/`.

## Progress Log

- 2026-11-12: Plan created.

- 2026-11-12: Implemented six-line structured failure stderr and three CLI regression tests. Isolated build, 16 focused tests, selected-file lint and strict changed-file lint passed (exit 0). Logs: `tmp/transcription-failure-20261112/transcription-failure-cli/{build,test,lint,strict-lint}.log`; plan-local build logs also appear under `tmp/transcription-failure-build/transcription-failure-cli/logs/`. Formal review and integration remain downstream.
