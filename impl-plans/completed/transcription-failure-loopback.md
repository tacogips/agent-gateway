# Transcription Failure: Production-Transport Redirect Regression (Loopback)

**Status**: Completed
**Plan ID**: `transcription-failure-loopback`
**Wave**: 3
**Depends On**: `transcription-failure-type`, `transcription-failure-pipeline`
**Design Reference**: `design-docs/specs/design-transcription-failure.md`
(sections Exactly One Wire Request, Code Placement for
`LoopbackHTTPServer.swift`, Verification case 11; review finding DF-002)

## Intent

This plan proves on the wire that a production `transcribe` call sends
exactly one request and does not follow a redirect. It uses the real
`defaultGatewayTranscriptionTransport`, a real `URLSession`, and a local
HTTP server owned by the test.

Stub tests cannot prove this. They replace the very component that
decides whether a redirect is followed.

## Repository Context

- The production entry point is
  `ProductionGatewayExecutor(environment:).transcribe(_:)` in
  `Sources/AgentGatewayAppCore/GatewayTranscription.swift`. After the
  wave-2 plan it uses the per-call `GatewayTranscriptionRedirectRefusal`
  delegate.
- `makeTranscriptionRequest` accepts `http` base URLs
  (`Sources/AgentGatewayAppCore/GatewayTranscriptionRequest.swift:25`).
  So `http://127.0.0.1:<port>/v1` is a valid `baseURL`.
- The test conventions are Swift Testing with `@testable import AgentGatewayAppCore`,
  as in `Tests/AgentGatewayTests/GatewayTranscriptionTests.swift`.
- Linux CI (`.github/workflows/linux-amd64-build.yml`) only builds the
  release product. Tests run on macOS through `mise run test`. Even so, the
  server must compile on Linux: use `#if canImport(Glibc)` /
  `#if canImport(Darwin)`.

## Non-Goals

- No production source changes. The only exception is the temporary,
  fully reverted mutation check below.
- No live vendor calls, no real credentials, no network outside
  `127.0.0.1`.
- No generic HTTP framework. Implement only what this one test needs.

## Write Ownership

- `Tests/AgentGatewayTests/LoopbackHTTPServer.swift` (new; test support)
- `Tests/AgentGatewayTests/GatewayTranscriptionRedirectTests.swift` (new)
- `impl-plans/active/transcription-failure-loopback.md` (Progress Log only)
- `tmp/transcription-failure-build/transcription-failure-loopback`
  (artifact root)

Shared path:

- `Sources/AgentGatewayAppCore/GatewayTranscription.swift` is for the
  temporary mutation check only (see below). The file must end up
  byte-identical to its state before the check.
- No other plan edits this file in wave 3.

## Changes

1. **`LoopbackHTTPServer`** (internal `final class`, `@unchecked Sendable`,
   lock-protected state):
   - `init(routes: [String: String])`. The key is a request path. The value
     is the complete raw HTTP response bytes to send for that path.
   - `func start() throws -> UInt16`:
     - `socket(AF_INET, SOCK_STREAM)`, `SO_REUSEADDR`, then `bind` to
       `127.0.0.1` port 0, then `listen`;
     - read the assigned port with `getsockname`;
     - spawn one `Thread` that runs the accept loop.
   - The accept loop handles each connection like this:
     - set `SO_RCVTIMEO` to 5 s;
     - read until `\r\n\r\n`;
     - parse the request line's path and the `Content-Length` header;
     - read the remaining body bytes;
     - increment the count for that path;
     - write the route's response, or `404` with `Content-Length: 0` if
       the path has no route;
     - close the connection.
   - `func requestCount(path: String) -> Int`
   - `func stop()`:
     - call `shutdown` and `close` on the listening socket, which makes
       `accept` return an error;
     - then wait for the thread to exit with a `DispatchSemaphore` that
       the thread signals when it ends. Wait at most 5 s.
2. **`@Suite struct GatewayTranscriptionRedirectTests`**, with test
   `productionTransportDoesNotFollowRedirect() async throws`:
   - Routes:
     - `/v1/audio/transcriptions` -> `HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:<port>/redirected\r\nContent-Length: 0\r\nConnection: close\r\n\r\n`.
       The port is known only after `start()`, so the test fills it in
       after starting the server.
     - `/redirected` -> `HTTP/1.1 200 OK` with the JSON body
       `{"text":"followed"}`, a correct `Content-Length`, and
       `Connection: close`.
   - Start the server, then `defer { server.stop() }`.
   - Call
     `ProductionGatewayExecutor(environment: ["TEST_OPENAI_KEY": "fixture-secret-0123456789abcdef"]).transcribe(...)`
     with:
     - `vendor: .openAI`, `model: "whisper-1"`;
     - a temporary `.mp3` file, `mimeType: "audio/mpeg"`;
     - `apiKeyEnvironment: "TEST_OPENAI_KEY"`;
     - `baseURL: "http://127.0.0.1:<port>/v1"`;
     - `timeoutSeconds: 5`.
   - Expectations:
     - the call throws `GatewayTranscriptionFailure` with
       `httpStatus == 302` and `classification == .unknown`;
     - `requestCount(path: "/v1/audio/transcriptions") == 1`;
     - `requestCount(path: "/redirected") == 0`;
     - `String(describing: failure)` does not contain the key.
   - If the call returns normally, record the issue
     `"redirect was followed: <text>"`.

## Required Mutation Check (DF-002 detection proof)

After the test passes:

1. Record `shasum -a 256 Sources/AgentGatewayAppCore/GatewayTranscription.swift`.
2. Temporarily change only the `URLSession(...)` construction in
   `defaultGatewayTranscriptionTransport` so it passes no delegate
   (`URLSession(configuration: configuration)`).
3. Before the mutated run, wait until the `transcription-failure-cli`
   Progress Log records a green build, so that its in-progress test edits
   cannot break compilation. Also record `shasum -a 256` of
   `Sources/AgentGatewayAppCore/GatewayTranscriptionCommand.swift` and
   `Tests/AgentGatewayAppCoreTests/TranscribeCommandTests.swift` before and
   after the mutated run, so the log can be attributed to a known sibling
   state.
4. Run the mutated test:
   `swift test --scratch-path tmp/transcription-failure-build/transcription-failure-loopback --filter GatewayTranscriptionRedirectTests > tmp/transcription-failure-build/transcription-failure-loopback/logs/mutation.log 2>&1; echo exit=$?`

   The mutated run counts as detection evidence only if ALL of these hold:
   - the exit is non-zero;
   - `grep -n "redirect was followed" tmp/transcription-failure-build/transcription-failure-loopback/logs/mutation.log; echo exit=$?`
     gives `exit=0`. The test records this issue when `transcribe` returns
     normally (`"redirect was followed: followed"`). A failed `/redirected`
     count expectation for the same test in the log is also acceptable;
   - `grep -n " error: " tmp/transcription-failure-build/transcription-failure-loopback/logs/mutation.log; echo exit=$?`
     gives `exit=1`, meaning there are no compiler diagnostics and the
     build completed;
   - the log shows that `productionTransportDoesNotFollowRedirect` was
     started.

   **Inconclusive results.** A non-zero exit for any other reason is
   INCONCLUSIVE and must never be recorded as detection. Such reasons
   include:
   - a compile error from sibling edits;
   - a socket `bind` or `listen` denial;
   - a timeout or `URLError`-based failure without the marker;
   - the test not being run at all.

   In that case, keep the mutation in place, wait for the sibling files to
   compile (or fix your own file), and re-run once. If the run is still
   inconclusive, revert the mutation (steps 5-6) and report a blocked
   check, as an environment or ordering failure, in the Progress Log.
5. Revert your one-line edit by hand. Never use `git checkout` or `git
   restore`: the file may hold uncommitted wave-2 work.
6. Confirm the sha256 equals step 1. Then re-run the test into
   `logs/test-after-restore.log`. It must give `exit=0` and 1 test passed.
7. Record the following in the Progress Log:
   - all hashes (the production file, and the cli-owned files before and
     after);
   - both exit codes;
   - the two grep results;
   - the log paths.

Never leave the mutation in place. If the hash does not match after the
restore, stop and report it.

## Pitfalls

- Platform socket differences:
  - `sockaddr_in.sin_len` exists only on Darwin;
  - the `SOCK_STREAM` type differs (`Int32(SOCK_STREAM.rawValue)` on
    Glibc);
  - use `in_port_t(0).bigEndian` for the port, and
    `UInt16(bigEndian: addr.sin_port)` to read it back;
  - use `withUnsafeMutablePointer` with `withMemoryRebound` for
    `bind`/`getsockname`.
- Read the whole request body before you respond. URLSession sends a
  multipart POST, and responding early can cause a connection reset that
  shows up as a transport error.
- The test must be bounded: the 5 s request timeout, the 5 s receive
  timeout, and `stop()` in `defer`. No sleeps and no background thread
  left alive after the test.
- Do not assert on the exact `localizedDescription` text, and do not log
  the key.

## Verification (repository root, foreground)

Run `mkdir -p tmp/transcription-failure-build/transcription-failure-loopback/logs`
first. Record each exit code and log path.

| Command | Must show |
| --- | --- |
| `swift build --scratch-path tmp/transcription-failure-build/transcription-failure-loopback --build-tests > tmp/transcription-failure-build/transcription-failure-loopback/logs/build.log 2>&1; echo exit=$?` | `exit=0` |
| `swift test --scratch-path tmp/transcription-failure-build/transcription-failure-loopback --filter GatewayTranscriptionRedirectTests > tmp/transcription-failure-build/transcription-failure-loopback/logs/test.log 2>&1; echo exit=$?` | `exit=0`, with 1 test passed |
| The mutated run, logged to `tmp/transcription-failure-build/transcription-failure-loopback/logs/mutation.log` | a non-zero exit, AND `grep -n "redirect was followed" .../logs/mutation.log` gives `exit=0` (or a failed `/redirected` count expectation for this test), AND `grep -n " error: " .../logs/mutation.log` gives `exit=1`. Any other non-zero cause is inconclusive and is not evidence. |
| After the revert, `shasum -a 256 Sources/AgentGatewayAppCore/GatewayTranscription.swift`, then `swift test --scratch-path tmp/transcription-failure-build/transcription-failure-loopback --filter GatewayTranscriptionRedirectTests > tmp/transcription-failure-build/transcription-failure-loopback/logs/test-after-restore.log 2>&1; echo exit=$?` | the hash equals the pre-mutation hash; `exit=0`, with 1 test passed |
| `swift test --scratch-path tmp/transcription-failure-build/transcription-failure-loopback --filter GatewayTranscription > tmp/transcription-failure-build/transcription-failure-loopback/logs/regression.log 2>&1; echo exit=$?` | `exit=0` |
| `swiftlint lint --cache-path tmp/transcription-failure-build/transcription-failure-loopback/swiftlint-cache Tests/AgentGatewayTests/LoopbackHTTPServer.swift Tests/AgentGatewayTests/GatewayTranscriptionRedirectTests.swift > tmp/transcription-failure-build/transcription-failure-loopback/logs/lint.log 2>&1; echo exit=$?` | `exit=0`, 0 violations |
| `git diff --stat -- Sources/AgentGatewayAppCore/GatewayTranscription.swift` | no diff from this plan |

## Done Criteria

- [x] The loopback test passes: one initial request, zero redirected
      requests, status 302 kept, and the key absent.
- [x] The mutation check proved that the test fails without the delegate
      wiring. All of these are recorded in the Progress Log:
      - the mutated run's non-zero exit;
      - `logs/mutation.log` contains `redirect was followed` (or the
        failed `/redirected` count expectation);
      - `logs/mutation.log` has no ` error: ` compiler lines;
      - the cli-owned file hashes around the run.

      An inconclusive result is reported as a blocked check, never as
      detection.
- [x] The source was restored byte-identical (matching sha256), and
      `logs/test-after-restore.log` shows `exit=0` with 1 test passed.
- [x] Build, test, regression, and lint all exit 0, with logs under
      `tmp/transcription-failure-build/transcription-failure-loopback/logs/`.

## Progress Log

- 2026-11-12: Plan created.

- 2026-11-12: Implemented the real URLSession loopback regression and bounded socket fixture. Build, focused test, restored test, regression and selected-file/strict lint exited 0; focused test passed 1 and regression passed 24. Complete logs are in `tmp/transcription-failure-20261112/transcription-failure-loopback/`, with plan copies in `tmp/transcription-failure-build/transcription-failure-loopback/logs/`. CLI progress recorded its green build before mutation.
- Mutation removed only the URLSession delegate argument. The test started and exited 1, reporting `redirect was followed: followed`; marker grep exited 0 and compiler-error grep exited 1. The source was restored and the focused test passed 1. Before and after SHA-256 values match: `GatewayTranscription.swift` `a8a17e7e65eb5dad90f7f54a437f6bce809892e3ddf57fe0923c1e00114ce534`; CLI source `09b430038b1d4d30b802cb3fecbacc694998f310bde5b891f865bbc162a37b4d`; CLI tests `9b15917003d30134af8ced3cbfbd104eb640cf307767388d6e9b09873945c7d8`. Hash manifests and `mutation.log` are in the evidence directory. Formal reviews and combined-tree integration remain downstream.
