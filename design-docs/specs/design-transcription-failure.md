# Transcription Failure Contract

## Status

Draft

## Goal

Give `GatewayTranscribing.transcribe(_:)` (implemented by
`ProductionGatewayExecutor` through the internal `GatewayTranscriptionPipeline`
in `Sources/AgentGatewayAppCore/GatewayTranscription.swift`) a structured
failure contract. Callers such as Riela's speech-to-text node must be able to
classify a failure without parsing strings. They need:

- the HTTP status;
- the vendor error type, code, and message (OpenAI, Gemini, OpenRouter);
- `Retry-After`;
- a classification;
- a guarantee of exactly one wire request per `transcribe` call.

Baseline: [design-transcribe-cli.md](design-transcribe-cli.md) (the transport
seam, CLI execution order, and the existing `-32010` behavior). This document
replaces only the rules for vendor-failure and transport-failure reporting in
that baseline. Everything else in it stays in force.

## Current Behavior (Replaced)

- `parseTranscriptionResponse` (`GatewayTranscriptionRequest.swift`) turns
  any non-2xx response into `GatewayRPCError(-32010, "vendor HTTP <status>:
  <first 500 bytes>")`. This drops `Retry-After`, drops any vendor code past
  500 bytes, and gives no classification.
- A non-HTTP response, 2xx invalid JSON, and an invalid 2xx payload are also
  plain `-32010` errors.
- Errors thrown by the transport closure pass through raw.
- `defaultGatewayTranscriptionTransport` uses a plain ephemeral `URLSession`,
  which silently follows 3xx redirects. A redirect therefore means a second
  wire request.

## Error Surface Split

| Stage | Thrown type | Change |
| --- | --- | --- |
| Vendor check (`-32021`), protocol/timeout check (`-32602`), credential (`-32011`), file loading/size/MIME/base URL (`-32602` or Foundation file errors) | `GatewayRPCError` / Foundation error | unchanged |
| Task cancellation before, during, or after the transport | `CancellationError` | unchanged |
| Transport closure throws (not cancellation) | `GatewayTranscriptionFailure`, classification `transport` | new |
| Response is not an `HTTPURLResponse` | `GatewayTranscriptionFailure`, `unknown`, `httpStatus` nil | was `-32010` |
| Status outside 200...299 (including 1xx and 3xx) | `GatewayTranscriptionFailure`, classified below | was `-32010` |
| 2xx with invalid JSON or no transcript in the payload | `GatewayTranscriptionFailure`, `unknown`, `httpStatus` = the 2xx status | was `-32010` |

Rule: every failure after the transport closure has been called is a
`GatewayTranscriptionFailure`, except cancellation. Nothing before the
transport changes. The unreachable `default:` branch of
`parseVendorTranscription` (unsupported vendor) keeps throwing `-32021`.

## Public Type

New file `Sources/AgentGatewayAppCore/GatewayTranscriptionFailure.swift`
(target `AgentGatewayAppCore`; no new module).

```swift
public struct GatewayTranscriptionFailure: Error, Sendable, Equatable, LocalizedError {
  public enum Classification: String, Sendable, Equatable {
    case quotaExhausted, rateLimited, serverError, authFailed, invalidRequest, transport, unknown
  }
  public var vendor: GatewayVendor
  public var classification: Classification
  public var httpStatus: Int?          // nil for transport and non-HTTP responses
  public var retryAfterSeconds: Int?   // parsed Retry-After header, nil if absent/unparseable
  public var vendorErrorType: String?
  public var vendorErrorCode: String?
  public var vendorMessage: String?
  public var rawBody: String?          // redacted body, cut to at most 16,384 UTF-8 bytes; nil if body empty or transport
  public var message: String           // gateway summary; the legacy -32010 message built from the redacted body
  public init(/* all fields, memberwise, with nil defaults for optionals */)
  public var rpcError: GatewayRPCError { GatewayRPCError(code: -32010, message: message) }
  public var errorDescription: String? { message }
}
```

- The memberwise `public init` lets downstream callers build test doubles.
- `LocalizedError.errorDescription` means callers that used
  `catch let e as GatewayRPCError` and now fall through to a generic
  `catch` still get the same text from `localizedDescription`.
- The `Classification` raw values (`quotaExhausted`, ...) are the strings the
  CLI prints.

### `message` (legacy-compatible summary)

| Case | `message` |
| --- | --- |
| Non-2xx HTTP | `vendor HTTP <status>: <redacted body cut to at most 500 UTF-8 bytes>`. This is the same as today's text when the body contains no credential. When it does, secret removal takes precedence over keeping the message identical (see Secrets). |
| Non-HTTP response | `vendor did not return an HTTP response` |
| 2xx invalid JSON | `vendor returned invalid transcription JSON` |
| 2xx JSON without transcript | `vendor returned invalid transcription payload` |
| Transport | `vendor request failed: <sanitized error>` (see Secrets) |

### Compatibility mapping

`transcribe` now throws `GatewayTranscriptionFailure` directly. The mapping to
the old surface is `failure.rpcError`, which is `GatewayRPCError(code: -32010,
message: failure.message)`. That is the same code, and for HTTP failures the
same message as before.

No ACP or RPC surface calls `transcribe` today. The only in-repo consumer is
the CLI, and it handles both types (see CLI). The README documents the
mapping.

## Vendor Error-Body Parsing

Vendor fields are parsed from the full response `Data`, never from the
16 KiB cap or the 500-byte prefix. So a long body still yields the code.
The parsed strings are then redacted (see Secrets) before they are stored.

One parser covers all three vendors, because each one uses a top-level
`error` object:

| Field | Source (first match wins) |
| --- | --- |
| `vendorErrorType` | `error.type` (OpenAI) if it is a string, else `error.status` (Gemini, for example `RESOURCE_EXHAUSTED`) if it is a string |
| `vendorErrorCode` | `error.code` if it is a string (OpenAI `insufficient_quota`); if it is an integer (Gemini or OpenRouter, for example `429`/`402`), its decimal string |
| `vendorMessage` | `error.message` if it is a string; else `error` itself if `error` is a string |

If the body is not JSON or has no `error` key, all three fields are nil. The
other diagnostics stay in `rawBody`, for example OpenRouter `error.metadata`
and Gemini `error.details`. The parser runs only for non-2xx HTTP responses.

## Classification Rules

The rules are evaluated in order, and the first match wins. A vendor
type or code takes precedence over the HTTP status, so a 429 for an exhausted
quota is not reported as a rate limit.

1. Transport closure threw: `transport`.
2. `vendorErrorType` or `vendorErrorCode` is `insufficient_quota` or
   `credit_balance_exhausted`: `quotaExhausted`.
3. `vendorErrorType` or `vendorErrorCode` is `rate_limit_exceeded`, or
   `vendorErrorType` is `RESOURCE_EXHAUSTED`: `rateLimited`.
4. The HTTP status decides:
   - `402`: `quotaExhausted` (OpenRouter's insufficient-credits status);
   - `429`: `rateLimited`;
   - `401` or `403`: `authFailed`;
   - any other `4xx`: `invalidRequest`;
   - `5xx`: `serverError`.
5. Anything else: `unknown`. This covers 1xx, 3xx, a non-HTTP response, and
   a 2xx with an invalid body.

The string matches are exact and case-sensitive, and they apply to every
vendor. The strings belong to distinct vendors and do not collide.

## Retry-After

- It is read with `HTTPURLResponse.value(forHTTPHeaderField: "Retry-After")`,
  which is case-insensitive, and only for non-2xx HTTP responses.
- After trimming whitespace, an all-digit value is delta-seconds. `Int(_:)`
  overflow gives nil.
- Otherwise the value is parsed as an IMF-fixdate HTTP-date
  (`EEE, dd MMM yyyy HH:mm:ss zzz`, `en_US_POSIX`, GMT). The result is
  `max(0, ceil(date - now))`. Obsolete RFC 850 and asctime forms are not
  supported and give nil.
- Any other value gives nil.
- The parser is an internal pure function with a `now: Date` parameter, so it
  can be unit tested. `parseTranscriptionResponse` takes `now: Date = Date()`
  and passes it through.
- Retry hints in the body, such as Gemini `RetryInfo.retryDelay`, are not
  parsed. They remain in `rawBody`.

## Exactly One Wire Request

- `GatewayTranscriptionPipeline.transcribe` calls the transport closure
  exactly once per call. It never retries. Retries belong to the caller, who
  uses `classification` and `retryAfterSeconds`.
- The production transport creates a new delegate instance for each call
  and passes it to the per-call ephemeral session:
  `URLSession(configuration:delegate:delegateQueue: nil)`. The delegate is
  an internal `final class`
  (`NSObject, URLSessionTaskDelegate, @unchecked Sendable`).
  - Its
    `urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:)`
    stores the received 3xx `HTTPURLResponse` under an `NSLock` and calls
    `completionHandler(nil)`.
- The transport then decides the result:
  - If `session.data(for:)` returns, the result is passed through. When
    the redirect is refused, that result is the 3xx response and its body.
  - If `session.data(for:)` throws and the delegate stored a redirect
    response, the transport returns `(Data(), storedResponse)` instead of
    rethrowing.
  - Otherwise the transport rethrows.
- So a refused redirect always reaches `parseTranscriptionResponse` as an
  `HTTPURLResponse` with its 3xx status. The result is a failure with
  `httpStatus` = 3xx and classification `unknown`, on every platform. No
  platform may report a refused redirect without its status.
- Cancellation still wins: the pipeline checks `Task.isCancelled` first.
- There is never a second request to the `Location` target.
- The timeouts, the per-call session, and `invalidateAndCancel` in `defer`
  are unchanged.

## Pipeline Flow

The steps of `GatewayTranscriptionPipeline.transcribe` keep the baseline
order. Only the error handling around steps 6 to 8 is new.

1. `let apiKey = try transcriptionAPIKey(...)`. The key is now kept for
   redaction instead of being discarded.
2. A cancellation check, then `loadGatewayTranscriptionAudio`, then another
   cancellation check, then `makeTranscriptionRequest`. These are unchanged.
3. The transport call:
   - If it throws `CancellationError`, or throws anything while
     `Task.isCancelled` is true, the pipeline throws `CancellationError`.
   - Any other error becomes
     `GatewayTranscriptionFailure(classification: .transport, ...)`. Its
     message is built with `secret: apiKey`, so it is redacted when it is
     created.
4. `try Task.checkCancellation()`. This is unchanged.
5. `parseTranscriptionResponse(data, response:, vendor:, secret: apiKey,
   now:)`. The `secret` and `now` parameters are internal. Redaction happens
   inside the failure factory before any truncation (see Secrets). The
   pipeline rethrows the failure unchanged and does not redact it again.

## Secrets

- A failure never contains request headers, the request URL (Gemini puts the
  key in a query item), or the `URLRequest`.
- The transport message is built from the error only:
  - for a `URLError`: `URLError(<code.rawValue>): <localizedDescription>`;
  - for any other error: `String(describing: type(of: error))`.
- Redaction happens before truncation. The failure factory follows these
  steps, in this order:
  1. Decode the complete response body with lossy UTF-8
     (`String(decoding: data, as: UTF8.self)`).
  2. Replace every occurrence of the resolved API key in that complete text
     with `[REDACTED]`.
  3. Only then derive the bounded strings from the redacted text:
     - the `message` body part is cut to at most 500 UTF-8 bytes;
     - `rawBody` is cut to at most 16,384 UTF-8 bytes.

     Both cuts are made at a `Character` boundary, so the stored text never
     ends in a partial scalar.
- Redacting first means a key that crosses a cut is removed before the cut.
  A truncation boundary can therefore leave at most a partial `[REDACTED]`
  marker, never a partial key.
- `vendorErrorType`, `vendorErrorCode`, and `vendorMessage` are parsed from
  the full `Data` and then pass through the same key replacement. The
  transport message also passes through it.
- Secret removal takes precedence over keeping the legacy message
  identical. When the body contains the key, `message` and `rpcError.message`
  differ from the old text in that they contain `[REDACTED]`.
- This covers vendors that echo the key in their error bodies. The
  replacement uses the exact resolved key only. Partially masked echoes
  produced by the vendor (for example `sk-...abcd`) are not the secret and
  are left unchanged.

## CLI

`runTranscription` (`GatewayTranscriptionCommand.swift`) catches
`GatewayTranscriptionFailure` before `GatewayRPCError`. Exit status is 1,
stdout is empty, and stderr has exactly these six lines:

```
transcription failed (-32010): <failure.message>
classification: <classification.rawValue>
http-status: <status or none>
vendor-error-type: <type or none>
vendor-error-code: <code or none>
retry-after-seconds: <seconds or none>
```

- The first line is unchanged from the baseline, so the existing
  `TranscribeCommandTests` 429 assertions still hold.
- Every field line is always printed, with `none` for nil, so the output is
  stable to parse.
- `vendorMessage` and `rawBody` are not printed separately. The first line
  already carries the body prefix.
- The `GatewayRPCError` row, the other-error row, and the parse-error
  (exit 2) rows of the baseline are unchanged.

## README

Extend `## Audio transcription` (README.md, around line 320) with:

- the error-surface split;
- the `GatewayTranscriptionFailure` fields;
- the classification table and its precedence;
- the Retry-After forms;
- the no-redirect and no-retry guarantee;
- the `rpcError` mapping to `-32010`;
- the six-line CLI stderr format.

Replace the current sentence about `vendor HTTP <status>: <body>` with the
new contract.

## Code Placement

- New file `Sources/AgentGatewayAppCore/GatewayTranscriptionFailure.swift`,
  targeted at under 200 lines. It contains:
  - the public type;
  - an internal factory from `(vendor, data, HTTPURLResponse, now)`;
  - the error-body parser;
  - the classifier;
  - the Retry-After parser;
  - the redact-then-truncate helper;
  - the transport-error factory.
- `GatewayTranscriptionRequest.swift`: `parseTranscriptionResponse` and the
  payload fallback in `parseVendorTranscription` throw the new type.
- `GatewayTranscription.swift`:
  - the redirect-refusing, response-recording delegate and its per-call use
    in the default transport;
  - the pipeline error handling.
- New test support file `Tests/AgentGatewayTests/LoopbackHTTPServer.swift`,
  used only by the loopback regression test. It is a minimal HTTP/1.1
  server:
  - it uses POSIX sockets (Darwin or Glibc import) and binds to
    `127.0.0.1:0`;
  - it runs on one dedicated thread;
  - it reads the request headers and the `Content-Length` body, answers
    with a canned response chosen by path, and closes the connection;
  - it keeps a lock-protected request count per path;
  - `SO_RCVTIMEO` is set to 5 s on accepted connections.

  The test owns startup and shutdown: `start()` returns the port, and
  `stop()` closes the listening socket and joins the thread, in a `defer`.
  The server makes no network calls outside loopback.
- `GatewayTranscriptionCommand.swift`: the new catch clause.
- No change to `GatewayProtocol.swift` (`GatewayRPCError`),
  `GatewayExecution.swift`, `GatewayModelCatalog.swift` (whose own `-32010`
  handling is out of scope), `GatewayTranscriptionParams`, or
  `GatewayTranscriptionResult`.

## Verification

Library tests go in the new
`Tests/AgentGatewayTests/GatewayTranscriptionFailureTests.swift`
(`@testable import AgentGatewayAppCore`). They use a counting, recording stub
transport through `GatewayTranscriptionPipeline` and a temporary audio file,
with no network:

1. OpenAI 429, body
   `{"error":{"type":"insufficient_quota","code":"credit_balance_exhausted","message":"..."}}`:
   `quotaExhausted`, `vendorErrorCode == "credit_balance_exhausted"`,
   `httpStatus == 429`.
2. 429 `{"error":{"type":"rate_limit_exceeded",...}}` with header
   `Retry-After: 7`: `rateLimited`, `retryAfterSeconds == 7`.
3. 503: `serverError`. 401: `authFailed`.
4. 302 with a `Location` header: a failure with `httpStatus == 302` and
   classification `unknown`.
5. A body over 500 bytes, where the code follows 600 bytes of padding in
   `message`: the vendor code is preserved. A body over 16 KiB gives
   `rawBody` of at most 16,384 bytes of UTF-8, and the code is still
   parsed.
6. The stub throws `URLError(.timedOut)`: `transport`, `httpStatus` nil.
7. The stub's invocation count is exactly 1 for every case above, including
   302, and on success.
8. Gemini 429 `RESOURCE_EXHAUSTED`: `rateLimited`, `vendorErrorType ==
   "RESOURCE_EXHAUSTED"`, `vendorErrorCode == "429"`. OpenRouter 402:
   `quotaExhausted`.
9. Secret boundary regressions use the synthetic key
   `fixture-secret-0123456789abcdef` (31 bytes) as the pipeline credential.
   Each case runs through the stubbed pipeline, with a 429 response:
   - 9a: the key placed after 480 bytes of `x` padding, so it crosses the
     500-byte message cut;
   - 9b: the key placed after 16,370 bytes of padding, so it crosses the
     16,384-byte `rawBody` cut;
   - 9c: the key echoed in `error.message` of a short OpenAI body.

   For each case, check `failure.message`, `failure.rawBody`,
   `failure.vendorMessage`, `failure.rpcError.message`, and
   `String(describing: failure)`:
   - none contains the full key;
   - none contains any prefix of the key of 8 or more bytes (checked for
     every prefix length from 8 to 31);
   - `rawBody` (cases 9a and 9c) and `message` (case 9c) contain
     `[REDACTED]`;
   - `rawBody` is at most 16,384 UTF-8 bytes;
   - classification and status are unchanged by redaction (`rateLimited`,
     429).
10. Retry-After unit tests on the pure parser:
    - `"7"` gives 7;
    - an HTTP-date 30 s after a fixed `now` gives 30;
    - a past date gives 0;
    - garbage gives nil.
11. Production-transport redirect regression over loopback. This test is
    what proves wire behavior. The stub cases 4 and 7 only prove that the
    pipeline calls the transport once.
    - Start a `LoopbackHTTPServer`:
      - `POST /v1/audio/transcriptions` answers
        `302 Found` with `Location: http://127.0.0.1:<port>/redirected` and
        `Content-Length: 0`;
      - `/redirected` (any method) answers `200 {"text":"followed"}`.
    - Call
      `ProductionGatewayExecutor(environment: ["TEST_OPENAI_KEY":
      "fixture-secret-0123456789abcdef"]).transcribe(...)`. Use vendor
      `openai`, `baseURL "http://127.0.0.1:<port>/v1"`,
      `apiKeyEnvironment "TEST_OPENAI_KEY"`, and `timeoutSeconds 5`. This
      takes the real `defaultGatewayTranscriptionTransport` and a real
      `URLSession`, with no stub.
    - Assert that it throws a `GatewayTranscriptionFailure` with:
      - `httpStatus == 302`;
      - classification `unknown`;
      - an initial-path request count of exactly 1;
      - a `/redirected` request count of exactly 0.
    - Removing the delegate from the production `URLSession` makes the
      session follow the 302. Then `/redirected` is hit and `transcribe`
      returns `"followed"`, so the test fails. That is the required
      detection of missing delegate wiring.
    - The test is bounded by the 5 s request timeout and the server's 5 s
      receive timeout. The server is stopped in `defer`.
12. `failure.rpcError == GatewayRPCError(code: -32010, message: "vendor HTTP
    429: <first 500 bytes>")` for a body that does not contain the key.

The existing assertions in `GatewayTranscriptionTests.swift` that expect
`GatewayRPCError(-32010)` from `parseTranscriptionResponse` and
`parseVendorTranscription` are updated to expect
`GatewayTranscriptionFailure`. Their `message` and `rpcError` keep the same
text. All other existing tests stay unchanged.

CLI tests go in `Tests/AgentGatewayAppCoreTests/TranscribeCommandTests.swift`.
The stub needs to support headers, so `RecordingTransport` gains an optional
`headers` argument.

- 429 `insufficient_quota` with `Retry-After: 7`: exit 1, empty stdout, and
  stderr contains:
  - `classification: quotaExhausted`;
  - `http-status: 429`;
  - `vendor-error-type: insufficient_quota`;
  - `vendor-error-code: ...`;
  - `retry-after-seconds: 7`;
  - but not `fixture-secret`.
- 429 whose body has the synthetic key placed after 480 bytes of padding
  (crossing the 500-byte cut that the CLI prints): stderr contains neither
  the full key nor any prefix of the key of 8 or more bytes.
- A transport throw: `classification: transport` and `http-status: none`.

Commands:

- `swift test --filter GatewayTranscriptionFailureTests`
- `swift test --filter GatewayTranscriptionTests`
- `swift test --filter TranscribeCommandTests`
- `mise run build && mise run test && mise run lint`

## Decisions

- Throw the new type directly and keep `-32010` reachable through `rpcError`
  and `errorDescription`. The other option, wrapping the failure inside
  `GatewayRPCError`, is rejected because that type is a `Codable` wire struct
  in the `AgentGateway` module and has no payload field.
- Gemini `RESOURCE_EXHAUSTED` is classified as `rateLimited`. Gemini uses it
  for per-minute and per-day quotas. The message text is not a reliable way
  to tell billing exhaustion apart. Callers can inspect `vendorMessage`.
- 3xx is classified as `unknown`. The status is kept, and no `redirect` case
  is added to the required enum.
- 403 is classified as `authFailed`.
- `CancellationError` keeps priority over the transport classification.
- Redaction comes before truncation, and secret removal takes precedence over
  keeping the legacy `-32010` message identical. This addresses review
  finding DF-001.
- Wire behavior is proven by a loopback regression that uses the production
  transport. The redirect delegate records the 3xx response, so the status
  is kept even on platforms that throw on a refused redirect. There is no
  platform exception. This addresses review finding DF-002.

## Rollout Constraints

- The successful path, `GatewayTranscriptionParams`,
  `GatewayTranscriptionResult`, and `GatewayTranscribing` are unchanged.
- The additive public API is `GatewayTranscriptionFailure` and its nested
  `Classification`.
- The thrown type changes for vendor and transport failures. This is
  documented in the README with the `rpcError` mapping.
- Swift files stay under 1000 lines, and `swiftlint` must pass.
- Commits go on the `feat/transcription-failure-detail` branch.
