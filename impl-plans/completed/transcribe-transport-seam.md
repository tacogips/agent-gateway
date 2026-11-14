# Transcribe CLI: Internal Transport Seam And Vendor Helper

**Status**: Completed
**Plan ID**: `transcribe-transport-seam`
**Wave**: 1 (no dependencies)
**Depends On**: none
**Design Reference**: `design-docs/specs/design-transcribe-cli.md` (Execution Order step 2, Test Seam, Code Placement, Rollout Constraints)

## Purpose

The new `agent-gateway transcribe` CLI needs two things from the library
(plan `transcribe-cli-command` depends on both):

1. One shared vendor check, so the CLI can reject an unsupported vendor with
   `-32021` before it does MIME inference, file I/O, or network I/O.
2. An internal HTTP transport seam, so the CLI tests can run the real
   production transcription path with only the HTTP call stubbed.

This plan makes only those two internal changes, in
`Sources/AgentGatewayAppCore/GatewayTranscription.swift`. Production
behavior does not change.

## Repository Context

- Current code: `Sources/AgentGatewayAppCore/GatewayTranscription.swift`.
  - `extension ProductionGatewayExecutor: GatewayTranscribing`, with
    `transcribe(_:)` at about lines 71-89.
  - `transcriptionAPIKey(_:environment:)`, whose vendor guard is
    `[.openAI, .gemini, .openRouter].contains(params.vendor)`.
  - `loadGatewayTranscriptionAudio(_:)`.
- Request and response helpers that must stay as they are:
  `Sources/AgentGatewayAppCore/GatewayTranscriptionRequest.swift`
  (`makeTranscriptionRequest`, `parseTranscriptionResponse`).
- The existing tests must pass unchanged:
  `Tests/AgentGatewayTests/GatewayTranscriptionTests.swift`. They include
  `cancelledTranscriptionStopsBeforeFileIO` and the tests for unsupported
  vendors and missing credentials through `ProductionGatewayExecutor`.
- `ProductionGatewayExecutor` is declared in
  `Sources/AgentGatewayAppCore/GatewayExecution.swift:57`. Do not edit that
  file.

## Write Ownership

- `Sources/AgentGatewayAppCore/GatewayTranscription.swift`
- `impl-plans/active/transcribe-transport-seam.md` (progress log section only)
- `tmp/transcribe-cli-build/transcribe-transport-seam` (artifact root:
  SwiftPM scratch path and logs; gitignored, never committed)

Edit discipline:

- Re-read the source file right before each edit.
- Record `shasum -a 256 Sources/AgentGatewayAppCore/GatewayTranscription.swift`
  in the progress log before the first edit and after the last one.
- If the hash changes in a way your own edits do not explain, stop and
  record the drift. Do not overwrite it.

## Changes (all symbols internal; no `public`)

1. **`func validateGatewayTranscriptionVendor(_ vendor: GatewayVendor) throws`**
   - It throws
     `GatewayRPCError(code: gatewayTranscriptionUnsupportedCode, message: "\(vendor.rawValue) does not support audio transcription")`
     for any vendor other than `.openAI`, `.gemini`, or `.openRouter`.
   - `transcriptionAPIKey` calls it first, in place of the inline guard.
   - The message text and the check order inside `transcriptionAPIKey` stay
     exactly the same: vendor, protocol version, timeout, credential.
2. **`typealias GatewayTranscriptionTransport = @Sendable (URLRequest, Int) async throws -> (Data, URLResponse)`**
   - The `Int` argument is `timeoutSeconds`.
3. **`let defaultGatewayTranscriptionTransport: GatewayTranscriptionTransport`**
   - This is the current inline URLSession code, moved unchanged: an
     ephemeral `URLSessionConfiguration`, `timeoutIntervalForRequest` and
     `timeoutIntervalForResource` set from the `Int` argument,
     `URLSession(configuration:)`, a `defer` that calls
     `session.invalidateAndCancel()`, then `session.data(for:)`.
   - It may be a global `let` closure or a `func` that matches the
     typealias.
4. **`struct GatewayTranscriptionPipeline: GatewayTranscribing`**
   - Fields: `let environment: [String: String]` and
     `let transport: GatewayTranscriptionTransport`.
   - Keep the memberwise init.
   - `transcribe(_:)` keeps the current body order exactly, with the
     transport call in step 6:
     1. `_ = try transcriptionAPIKey(params, environment: environment)`
     2. `try Task.checkCancellation()`
     3. `loadGatewayTranscriptionAudio`
     4. `try Task.checkCancellation()`
     5. `makeTranscriptionRequest(params, audioData:, environment:)`
     6. `try await transport(request, params.timeoutSeconds)`
     7. `try Task.checkCancellation()`
     8. return `GatewayTranscriptionResult(vendor:model:text: parseTranscriptionResponse(...))`
5. **`ProductionGatewayExecutor.transcribe(_:)`**
   - The public signature stays the same.
   - The body becomes a single delegation:
     `try await GatewayTranscriptionPipeline(environment: environment, transport: defaultGatewayTranscriptionTransport).transcribe(params)`.

## Invariants / Pitfalls

- Do not change `GatewayTranscriptionParams`, `GatewayTranscriptionResult`,
  `GatewayTranscribing`, `gatewayTranscriptionUnsupportedCode`,
  `GatewayTranscriptionModels`, or any public signature.
- Do not add stored properties or initializers to `ProductionGatewayExecutor`.
- Do not edit these files:
  - `GatewayExecution.swift`;
  - `GatewayTranscriptionRequest.swift`;
  - any test file;
  - `Command.swift` (owned by `transcribe-cli-command`);
  - `README.md` (owned by `transcribe-readme`).
- Do not make the new symbols `public`. The CLI and tests share the
  `AgentGatewayAppCore` module, and tests use `@testable`.
- The closure must be `@Sendable`. `GatewayTranscriptionPipeline` must be
  `Sendable`, which comes through `GatewayTranscribing: Sendable`. Swift 6
  strict concurrency must compile with no new warnings.
- Keep the `#if canImport(FoundationNetworking)` import as it is.
- Keep the three cancellation checks. `cancelledTranscriptionStopsBeforeFileIO`
  depends on the first check, which runs after the key check and before
  file I/O.
- Do not log or print anything. The API key is used only inside
  `makeTranscriptionRequest`.
- The file must stay under 1000 lines (today it has 134).

## Tests

No new test file is part of this plan. Plan `transcribe-cli-command` tests
the pipeline end to end through the CLI. This plan's evidence is that the
existing suite passes unchanged:

- existing `GatewayTranscriptionTests` -> all pass, with no edits to the
  test file;
- unsupported vendor through `ProductionGatewayExecutor` -> still
  `-32021`, before file I/O.

## Verification (repository root, foreground)

Run `mkdir -p tmp/transcribe-cli-build/transcribe-transport-seam/logs`
first.

| Command | Must show |
| --- | --- |
| `swift build --scratch-path tmp/transcribe-cli-build/transcribe-transport-seam 2>&1 \| tee tmp/transcribe-cli-build/transcribe-transport-seam/logs/build.log` | exit 0, with no new warnings in GatewayTranscription.swift |
| `swift test --scratch-path tmp/transcribe-cli-build/transcribe-transport-seam --filter GatewayTranscription 2>&1 \| tee tmp/transcribe-cli-build/transcribe-transport-seam/logs/test.log` | exit 0, and all existing transcription tests pass |
| `swiftlint lint --cache-path tmp/transcribe-cli-build/transcribe-transport-seam/swiftlint-cache Sources/AgentGatewayAppCore/GatewayTranscription.swift` | 0 violations |
| `grep -n "public" Sources/AgentGatewayAppCore/GatewayTranscription.swift` | the same set of public declarations as before (compare with `git show HEAD:Sources/AgentGatewayAppCore/GatewayTranscription.swift`) |
| `git diff --stat` | only GatewayTranscription.swift and this plan file have changed in this plan's scope |

Use `set -o pipefail` (or check `PIPESTATUS`) so that each `tee` pipeline
reports the exit status of the Swift command. Record the exit codes and log
paths in the progress log.

## Done Criteria

- [x] `validateGatewayTranscriptionVendor`, `GatewayTranscriptionTransport`,
      `defaultGatewayTranscriptionTransport`, and
      `GatewayTranscriptionPipeline` exist with the signatures above and are
      internal.
- [x] `ProductionGatewayExecutor.transcribe` delegates to the pipeline with
      the default transport.
- [x] `transcriptionAPIKey` calls `validateGatewayTranscriptionVendor`
      first, and the message is unchanged.
- [x] Build, filtered test, and swiftlint pass, and their logs are under
      `tmp/transcribe-cli-build/transcribe-transport-seam/logs/`.

## Progress Log

- 2026-11-12: Plan created.
- 2026-11-12: Implemented the internal seam and shared vendor validation; preserved the public API and cancellation order. Source SHA-256 before: `57db4b23818ce0709f0f590ee561baf2ad901aa62a12209902ee92de1aad562b`; after: `3e10ffec198c1deed655d3a3039ef63a8d6723594e0a1cdea9729c14f15c64c5`.
- Isolated `swift build` exited 0 (`tmp/transcribe-cli-build/transcribe-transport-seam/logs/build.log`); filtered `swift test` exited 0 with 12 tests (`tmp/transcribe-cli-build/transcribe-transport-seam/logs/test.log`); scoped SwiftLint exited 0 with 0 violations (`tmp/transcribe-cli-build/transcribe-transport-seam/logs/lint.log`). Formal reviews and integration remain downstream.
- 2026-11-12: Completed. Reviews accepted; combined-tree build, test (153 passed) and lint exit 0 (`tmp/transcribe-cli-20261112/reconcile-wave-002/`).
