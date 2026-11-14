# Transcription Failure: Response Parsing, Transport, And Pipeline Wiring

**Status**: Completed
**Plan ID**: `transcription-failure-pipeline`
**Wave**: 2
**Depends On**: `transcription-failure-type`
**Design Reference**: `design-docs/specs/design-transcription-failure.md`
(sections Error Surface Split, Exactly One Wire Request, Pipeline Flow,
Secrets, Verification cases 1-10 and 12)

## Intent

This plan makes `transcribe` throw `GatewayTranscriptionFailure` for every
failure that happens after the transport is called, except cancellation.
That covers:

- the non-HTTP response;
- non-2xx responses, including 3xx;
- 2xx responses with invalid JSON or payload;
- errors thrown by the transport.

It also makes the production transport refuse redirects, and keep the 3xx
status even when a platform throws after a redirect is refused. All the
helpers come from `transcription-failure-type`. Do not reimplement them.

## Repository Context

- `Sources/AgentGatewayAppCore/GatewayTranscriptionRequest.swift`:
  - `parseTranscriptionResponse` (about lines 100-112) builds today's
    500-byte `-32010` error;
  - `parseVendorTranscription` (about lines 114-139).
- `Sources/AgentGatewayAppCore/GatewayTranscription.swift`:
  - `defaultGatewayTranscriptionTransport` (about lines 81-88);
  - `GatewayTranscriptionPipeline.transcribe` (about lines 94-108);
  - `transcriptionAPIKey` (about lines 142-155).
- `Tests/AgentGatewayTests/GatewayTranscriptionTests.swift`:
  - `transcriptionParsesVendorPayloadsAndEmptyText` (line 113, with
    `expectTranscriptionError(-32010)` at line 123);
  - `transcriptionResponseReportsHTTPAndJSONErrors` (lines 178-188).
- The stub pattern to imitate is the private `RecordingTransport` class in
  `Tests/AgentGatewayAppCoreTests/TranscribeCommandTests.swift:9-27`. Make
  your own private copy in the new test file. Do not edit the CLI test file.
- The temp-file helper to imitate is `withTranscriptionFile` in
  `Tests/AgentGatewayTests/GatewayTranscriptionTests.swift:9`. It is
  private, so re-create a small private helper.

## Non-Goals

- Do not edit:
  - `GatewayTranscriptionFailure.swift` (owned by the wave-1 plan; if it
    is defective, record that and stop);
  - `GatewayTranscriptionCommand.swift`;
  - `TranscribeCommandTests.swift`;
  - README.md;
  - `GatewayExecution.swift`;
  - `GatewayModelCatalog.swift`;
  - `GatewayProtocol.swift`.
- Do not change `GatewayTranscriptionParams`, `GatewayTranscriptionResult`,
  `GatewayTranscribing`, the public `ProductionGatewayExecutor.transcribe`
  signature, or anything about the success path.
- No retry loop and no second transport call.
- No loopback server. That belongs to `transcription-failure-loopback`.

## Write Ownership

- `Sources/AgentGatewayAppCore/GatewayTranscriptionRequest.swift`
- `Sources/AgentGatewayAppCore/GatewayTranscription.swift`
- `Tests/AgentGatewayTests/GatewayTranscriptionTests.swift`: update only
  the two tests named above; every other test stays byte-identical.
- `Tests/AgentGatewayTests/GatewayTranscriptionFailurePipelineTests.swift`
  (new)
- `impl-plans/active/transcription-failure-pipeline.md` (Progress Log only)
- `tmp/transcription-failure-build/transcription-failure-pipeline`
  (artifact root)

Edit discipline:

- Record `shasum -a 256` of each owned existing file before the first edit
  and after the last edit.
- Re-read each file right before every edit. If you find changes that your
  own edits do not explain, stop, record the drift, and do not overwrite.

## Changes

1. **`parseVendorTranscription(_:vendor:)`** now returns `String?`.
   - It returns nil where it throws `-32010` today, which is the case
     where the payload has no transcript.
   - The unsupported-vendor `default:` branch keeps throwing
     `GatewayRPCError(-32021, ...)` unchanged.
2. **`parseTranscriptionResponse`** has the new signature
   `func parseTranscriptionResponse(_ data: Data, response: URLResponse, vendor: GatewayVendor, secret: String, now: Date = Date()) throws -> String`.
   - `secret` has no default value. A default would let a caller silently
     skip redaction.
   - The steps, in order:
     1. If `response` is not an `HTTPURLResponse`, throw
        `.responseFailure(vendor:, httpStatus: nil, data:, message: "vendor did not return an HTTP response", secret:)`.
     2. If the status is not in 200...299, throw
        `.httpFailure(vendor:, data:, response:, secret:, now:)`.
     3. If the body is not a JSON object, throw `.responseFailure(...)`
        with the status and
        `"vendor returned invalid transcription JSON"`.
     4. If `parseVendorTranscription` returns nil, throw
        `.responseFailure(...)` with the status and
        `"vendor returned invalid transcription payload"`.
3. **The redirect delegate** is a new internal type in
   `GatewayTranscription.swift`:
   `final class GatewayTranscriptionRedirectRefusal: NSObject, URLSessionTaskDelegate, @unchecked Sendable`.
   - It has a private `NSLock` and a private `HTTPURLResponse?`, with an
     internal read accessor `var refusedRedirectResponse: HTTPURLResponse?`.
   - It implements the completion-handler form of
     `urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:)`.
     This form exists on both Darwin and FoundationNetworking. Match the
     SDK's closure annotation so Swift 6 gives no warning.
   - The method stores `response` under the lock, then calls
     `completionHandler(nil)`.
   - Do not implement the async variant.
4. **`defaultGatewayTranscriptionTransport`** creates the delegate per call.
   - It creates one new delegate instance per invocation, never a shared
     global, and builds
     `URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)`.
   - Keep the ephemeral configuration, both timeouts, and
     `defer { session.invalidateAndCancel() }`.
   - `do { return try await session.data(for: request) } catch { ... }`:
     - if `delegate.refusedRedirectResponse` is non-nil, return
       `(Data(), thatResponse)`;
     - otherwise rethrow.
5. **`GatewayTranscriptionPipeline.transcribe`**:
   - Keep the key: `let apiKey = try transcriptionAPIKey(...)` replaces
     `_ =`.
   - Wrap ONLY the transport call in `do/catch`:
     - if `error is CancellationError || Task.isCancelled`, throw
       `CancellationError()`;
     - otherwise throw
       `GatewayTranscriptionFailure.transportFailure(vendor: params.vendor, error: error, secret: apiKey)`.
   - Keep `try Task.checkCancellation()` after the transport.
   - Call `parseTranscriptionResponse(data, response: response, vendor: params.vendor, secret: apiKey)`
     and let its failure propagate unchanged.
   - Keep the order of the cancellation checks, file loading, and request
     building exactly as it is.

## Pitfalls

- Do not wrap `transcriptionAPIKey`, `loadGatewayTranscriptionAudio`, or
  `makeTranscriptionRequest` in the new `catch`. Their `GatewayRPCError`
  and Foundation errors must propagate exactly as today.
- Never put `request`, `request.url`, headers, or `String(describing: error)`
  into a failure. Gemini puts the key in the URL query.
- Keep the 302 status: the fallback must return the recorded response, not
  throw.
- Do not make any new symbol `public`.
- `GatewayTranscription.swift` must stay well under 1000 lines (about 190
  expected).

## Tests

### New file `GatewayTranscriptionFailurePipelineTests.swift`

Put these tests in `@Suite struct GatewayTranscriptionFailurePipelineTests`.
Every case drives
`GatewayTranscriptionPipeline(environment: ["TEST_KEY": key], transport: stub.transport)`
with `apiKeyEnvironment: "TEST_KEY"` and a temporary `.mp3` file. The stub
must:

- be a lock-protected class;
- record `URLRequest`s;
- be configurable with a status, a body, headers, an optional thrown
  error, or an optional non-HTTP `URLResponse`.

Each case is `input -> expected`:

1. OpenAI 429,
   `{"error":{"type":"insufficient_quota","code":"credit_balance_exhausted","message":"quota"}}`
   -> `quotaExhausted`, `vendorErrorType == "insufficient_quota"`,
   `vendorErrorCode == "credit_balance_exhausted"`, `httpStatus == 429`,
   stub count 1.
2. 429 `{"error":{"type":"rate_limit_exceeded","code":"rate_limit_exceeded"}}`
   with header `Retry-After: 7` -> `rateLimited`, `retryAfterSeconds == 7`,
   count 1.
3. 503 `{}` -> `serverError`. 401 `{}` -> `authFailed`. Count 1 each.
4. 302 with header `Location: https://example.invalid/elsewhere` and an
   empty body -> a failure with `httpStatus == 302`, `unknown`, and
   exactly 1 request, which went to the original URL.
5. The body's `error.message` is 600 `"x"`s and is followed by
   `"code":"insufficient_quota"` -> the code is preserved. A
   20,000-byte body -> `rawBody!.utf8.count <= 16_384` and the code is
   still parsed.
6. The stub throws `URLError(.timedOut)` -> `transport`, `httpStatus == nil`,
   count 1.
7. The stub throws `CancellationError()` -> the call rethrows
   `CancellationError`, not a transport failure.
8. 200 `"invalid"` -> `unknown`, `httpStatus == 200`, and `message` is
   `vendor returned invalid transcription JSON`. 200 `{}` -> `message` is
   `vendor returned invalid transcription payload`. A non-HTTP
   `URLResponse` -> `unknown`, `httpStatus == nil`.
9. Gemini (vendor `.gemini`) 429,
   `{"error":{"code":429,"message":"m","status":"RESOURCE_EXHAUSTED"}}`
   -> `rateLimited`, type `RESOURCE_EXHAUSTED`, code `"429"`. Also,
   `String(describing: failure)` does not contain the key, even though the
   Gemini URL carries it. OpenRouter 402 `{"error":{"code":402,"message":"m"}}`
   -> `quotaExhausted`, code `"402"`.
10. Secret boundaries, with key `"fixture-secret-0123456789abcdef"` and
    status 429:
    - 10a: the key after 480 `"x"`s;
    - 10b: the key after 16,370 `"x"`s;
    - 10c: the key inside `error.message` of an OpenAI JSON body.

    For each one, `message`, `rawBody`, `vendorMessage`,
    `rpcError.message`, and `String(describing: failure)` contain no
    `String(key.prefix(n))` for any n in 8...31. `rawBody` contains
    `[REDACTED]` in 10a, 10b, and 10c. The classification is
    `rateLimited` and the status is 429.
11. Success, 200 `{"text":"hello"}` -> the result text is `"hello"`, count 1.
12. 429 body of 600 `"x"`s (no key) ->
    `failure.rpcError == GatewayRPCError(code: -32010, message: "vendor HTTP 429: " + 500 x)`.
13. Delegate unit check: create a `GatewayTranscriptionRedirectRefusal`,
    then call its redirect method with a dummy session, a data task (not
    resumed), a 302 `HTTPURLResponse`, and a request. Assert:
    - the completion handler received nil;
    - `refusedRedirectResponse?.statusCode == 302`.

### Updates to `GatewayTranscriptionTests.swift`

- Line 123 becomes `#expect(try parseVendorTranscription([:], vendor: vendor) == nil)`.
- `transcriptionResponseReportsHTTPAndJSONErrors`:
  - pass `secret: "unused-secret"`;
  - expect `GatewayTranscriptionFailure` instead of `GatewayRPCError`,
    with a local helper or `#expect(throws:)`;
  - the 429 case asserts
    `rpcError.message == "vendor HTTP 429: " + String(repeating: "x", count: 500)`;
  - the invalid-JSON and non-HTTP cases assert `classification == .unknown`.
- All other tests stay unchanged, including
  `cancelledTranscriptionStopsBeforeFileIO`.

## Verification (repository root, foreground)

Run `mkdir -p tmp/transcription-failure-build/transcription-failure-pipeline/logs`
first. Record each exit code and log path in the Progress Log.

| Command | Must show |
| --- | --- |
| `swift build --scratch-path tmp/transcription-failure-build/transcription-failure-pipeline > tmp/transcription-failure-build/transcription-failure-pipeline/logs/build.log 2>&1; echo exit=$?` | `exit=0`, with no new warnings in the owned files |
| `swift test --scratch-path tmp/transcription-failure-build/transcription-failure-pipeline --filter GatewayTranscription > tmp/transcription-failure-build/transcription-failure-pipeline/logs/test.log 2>&1; echo exit=$?` | `exit=0`; covers the new pipeline suite, the updated `GatewayTranscriptionTests`, and `GatewayTranscriptionFailureTests` |
| `swiftlint lint --cache-path tmp/transcription-failure-build/transcription-failure-pipeline/swiftlint-cache Sources/AgentGatewayAppCore/GatewayTranscriptionRequest.swift Sources/AgentGatewayAppCore/GatewayTranscription.swift Tests/AgentGatewayTests/GatewayTranscriptionTests.swift Tests/AgentGatewayTests/GatewayTranscriptionFailurePipelineTests.swift > tmp/transcription-failure-build/transcription-failure-pipeline/logs/lint.log 2>&1; echo exit=$?` | `exit=0`, 0 violations |
| `grep -n "public" Sources/AgentGatewayAppCore/GatewayTranscription.swift Sources/AgentGatewayAppCore/GatewayTranscriptionRequest.swift` | the same public declarations as `git show HEAD:<file>` |
| `grep -n "delegate:" Sources/AgentGatewayAppCore/GatewayTranscription.swift` | the per-call delegate is passed to `URLSession(configuration:delegate:delegateQueue:)` |
| `git diff --stat` | in this plan's scope, only the owned files have changed |

## Done Criteria

- [x] Every failure after the transport is called is a
      `GatewayTranscriptionFailure`, except cancellation. Every failure
      before the transport is unchanged.
- [x] The production transport refuses redirects with a per-call delegate
      and returns the recorded 3xx response when `data(for:)` throws.
- [x] Test cases 1-13 pass, the two updated legacy tests pass, and all
      other transcription tests pass unchanged.
- [x] Build, test, and lint all exit 0, with logs under
      `tmp/transcription-failure-build/transcription-failure-pipeline/logs/`.

## Progress Log

- 2026-11-12: Plan created.

- 2026-11-12: Implemented pipeline and delegate; stub cases 1-13 and the two legacy updates pass. `swift build --scratch-path tmp/transcription-failure-build/transcription-failure-pipeline` exit 0; `swift test --scratch-path tmp/transcription-failure-build/transcription-failure-pipeline --filter GatewayTranscription` exit 0 (23 tests); selected-file SwiftLint and strict SwiftLint exit 0, 0 violations. Logs: `tmp/transcription-failure-build/transcription-failure-pipeline/logs/{build,test,lint}.log` and `tmp/transcription-failure-20261112/transcription-failure-pipeline/strict-lint.log`. Before/after hashes and edit intentions: `tmp/transcription-failure-20261112/transcription-failure-pipeline/{before-hashes,after-hashes,edit-1-intent,edit-2-intent,edit-3-intent,edit-4-intent}.txt`. Formal review and loopback wire verification remain downstream.
