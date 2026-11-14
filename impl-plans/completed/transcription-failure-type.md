# Transcription Failure: Public Failure Type And Pure Helpers

**Status**: Completed
**Plan ID**: `transcription-failure-type`
**Wave**: 1 (no dependencies)
**Depends On**: none
**Design Reference**: `design-docs/specs/design-transcription-failure.md`
(sections Public Type, `message`, Compatibility mapping, Vendor Error-Body
Parsing, Classification Rules, Retry-After, Secrets)

## Intent

Riela's speech-to-text node and other callers need to classify transcription
failures. This plan adds the public `GatewayTranscriptionFailure` type and
every pure helper that builds it. Later plans depend on the helpers:

- `transcription-failure-pipeline` throws the type from the request/response
  path and the transport;
- `transcription-failure-cli` prints it.

This plan does not wire anything into the pipeline.

## Repository Context

- Target module: `AgentGatewayAppCore` (`Sources/AgentGatewayAppCore/`). Do
  not add a module or touch `Package.swift`.
- Patterns to imitate:
  - The public struct style (`public var` fields and an explicit public
    init) follows `Sources/AgentGatewayAppCore/GatewayTranscription.swift:GatewayTranscriptionParams`.
  - The FoundationNetworking import guard is at the top of
    `Sources/AgentGatewayAppCore/GatewayTranscriptionRequest.swift`.
  - Test style is Swift Testing (`import Testing`, `@Test`, `#expect`,
    `#require`), with `@testable import AgentGatewayAppCore`, as in
    `Tests/AgentGatewayTests/GatewayTranscriptionTests.swift`.
- `GatewayRPCError` is at `Sources/AgentGateway/GatewayProtocol.swift:423`
  and has `code` and `message`. It is read-only for this plan.
- `GatewayVendor` is at `Sources/AgentGateway/GatewayProtocol.swift:7`. It
  is a String enum and is Equatable.

## Non-Goals

- Do not edit `GatewayTranscription.swift`, `GatewayTranscriptionRequest.swift`,
  `GatewayTranscriptionCommand.swift`, README.md, or any existing test.
- No transport, no URLSession, and no pipeline changes.
- Do not parse body retry hints (Gemini `RetryInfo`). Do not support the
  obsolete RFC 850 or asctime HTTP-date forms.
- No `redirect` classification case. No retry logic.

## Write Ownership

- `Sources/AgentGatewayAppCore/GatewayTranscriptionFailure.swift` (new)
- `Tests/AgentGatewayTests/GatewayTranscriptionFailureTests.swift` (new)
- `impl-plans/active/transcription-failure-type.md` (Progress Log only)
- `tmp/transcription-failure-build/transcription-failure-type`. This is an
  artifact root for the SwiftPM scratch path, logs, and the swiftlint cache.
  It is gitignored and never committed.

Edit discipline:

- Both source files are new. Before creating each one, confirm it does not
  exist, and record `shasum -a 256` of each file after the last edit in the
  Progress Log.
- Re-read a file right before each edit. If content appears that you did
  not write, stop and record the drift. Do not overwrite it.

## Contract (pinned; other plans compile against these exact names)

The public type is in `GatewayTranscriptionFailure.swift`:

```swift
public struct GatewayTranscriptionFailure: Error, Sendable, Equatable, LocalizedError {
  public enum Classification: String, Sendable, Equatable {
    case quotaExhausted, rateLimited, serverError, authFailed, invalidRequest, transport, unknown
  }
  public var vendor: GatewayVendor
  public var classification: Classification
  public var httpStatus: Int?
  public var retryAfterSeconds: Int?
  public var vendorErrorType: String?
  public var vendorErrorCode: String?
  public var vendorMessage: String?
  public var rawBody: String?
  public var message: String
  public init(vendor:classification:httpStatus:retryAfterSeconds:vendorErrorType:vendorErrorCode:vendorMessage:rawBody:message:)
  public var rpcError: GatewayRPCError   // GatewayRPCError(code: -32010, message: message)
  public var errorDescription: String?   // message
}
```

In the public init, every optional parameter defaults to `nil`. The
parameter order is the field order above.

The internal symbols, none of them `public`, are:

- `let gatewayTranscriptionRawBodyLimit = 16_384`
- `let gatewayTranscriptionMessageBodyLimit = 500`
- `let gatewayTranscriptionRedactionMarker = "[REDACTED]"`
- `func gatewayRedactedText(_ data: Data, secret: String) -> String`
  - It decodes the whole buffer lossily with
    `String(decoding: data, as: UTF8.self)`.
  - It then replaces every occurrence of `secret` with the marker. If
    `secret` is empty, it skips the replacement.
- `func gatewayRedacted(_ text: String, secret: String) -> String`. This is
  the same replacement, for strings.
- `func gatewayUTF8Prefix(_ text: String, maxBytes: Int) -> String`
  - It returns the longest prefix made of whole `Character`s whose
    `utf8.count` is at most `maxBytes`.
- `func parseGatewayRetryAfter(_ value: String?, now: Date) -> Int?`
- `func parseGatewayVendorErrorFields(_ data: Data) -> GatewayVendorErrorFields`
  - Internal; changed from a 3-tuple to satisfy `large_tuple` (integration finding RECON-001).
- `func classifyGatewayTranscriptionFailure(httpStatus: Int?, vendorErrorType: String?, vendorErrorCode: String?) -> GatewayTranscriptionFailure.Classification`
- Static factories on `GatewayTranscriptionFailure`, all internal:
  - `static func httpFailure(vendor: GatewayVendor, data: Data, response: HTTPURLResponse, secret: String, now: Date) -> GatewayTranscriptionFailure`
    is for non-2xx responses, including 1xx and 3xx.
  - `static func responseFailure(vendor: GatewayVendor, httpStatus: Int?, data: Data, message: String, secret: String) -> GatewayTranscriptionFailure`
    is for a non-HTTP response (`httpStatus` nil) and for 2xx responses
    with invalid JSON or payload. The classification is always `unknown`
    and the vendor fields are nil.
  - `static func transportFailure(vendor: GatewayVendor, error: any Error, secret: String) -> GatewayTranscriptionFailure`

## Behavior Rules (the points a careless implementation gets wrong)

1. **Redaction comes before truncation (DF-001).** `httpFailure` and
   `responseFailure` follow these steps:
   1. `redacted = gatewayRedactedText(data, secret:)`, applied to the FULL
      data;
   2. `rawBody = data.isEmpty ? nil : gatewayUTF8Prefix(redacted, maxBytes: 16_384)`;
   3. for `httpFailure`, `message = "vendor HTTP \(status): " + gatewayUTF8Prefix(redacted, maxBytes: 500)`.

   Never cut the bytes first and redact afterwards.
2. **Vendor fields come from the FULL `data`**, never from a prefix. Each
   non-nil field is then passed through `gatewayRedacted(_:secret:)`.
3. **The body parser handles one shape for all vendors.** It reads the
   top-level JSON object key `error`.
   - If `error` is an object:
     - `type` is `error["type"] as? String`, else `error["status"] as? String`;
     - `code` is `error["code"] as? String`, else
       `(error["code"] as? Int).map(String.init)`;
     - `message` is `error["message"] as? String`.
   - If `error` is a String, then `message` is that string and the other
     two fields are nil.
   - Non-JSON input or a missing `error` key gives all nil.
   - It never throws. Use `try? JSONSerialization.jsonObject(with:)`.
4. **Classification order: the first match wins, and vendor type/code wins
   over status.**
   1. `type` or `code` is `insufficient_quota` or
      `credit_balance_exhausted`: `quotaExhausted`.
   2. `type` or `code` is `rate_limit_exceeded`, or `type` is
      `RESOURCE_EXHAUSTED`: `rateLimited`.
   3. Then by status:
      - 402: `quotaExhausted`;
      - 429: `rateLimited`;
      - 401 or 403: `authFailed`;
      - any other 400...499: `invalidRequest`;
      - 500...599: `serverError`.
   4. Anything else, including nil status, 1xx, 2xx, and 3xx: `unknown`.

   The matches are exact and case-sensitive. `transport` is never returned
   by `classify...`; only `transportFailure` sets it.
5. **Retry-After parsing.**
   - Trim whitespace. A non-empty all-ASCII-digit value goes through
     `Int(_:)`; an overflow gives nil.
   - Otherwise, parse with a `DateFormatter` created per call. Do NOT use a
     shared global, because DateFormatter is not Sendable. The formatter
     uses `en_US_POSIX`, `TimeZone(identifier: "GMT")`, and the format
     `"EEE, dd MMM yyyy HH:mm:ss zzz"`. The result is
     `max(0, Int(ceil(date.timeIntervalSince(now))))`.
   - Anything else, or nil input, gives nil.
   - `httpFailure` reads the header with
     `response.value(forHTTPHeaderField: "Retry-After")`.
6. **`transportFailure`.**
   - The message is
     `"vendor request failed: " + detail`, passed through
     `gatewayRedacted`.
   - `detail` is `"URLError(\(urlError.code.rawValue)): \(urlError.localizedDescription)"`
     for a `URLError`, and `String(describing: type(of: error))` for any
     other error.
   - Never use `String(describing: error)` or the URLError's
     `failingURL`/`userInfo`: they can contain the Gemini URL with the key.
   - The classification is `.transport`. `httpStatus`, the vendor fields,
     and `rawBody` are all nil.
7. Do not add `CustomStringConvertible`. Tests use `String(describing:)`,
   which reflects the fields, and those fields are already redacted.
8. Keep the file under about 220 lines and every function at or below the
   swiftlint limits. Keep the
   `#if canImport(FoundationNetworking) import FoundationNetworking #endif`
   guard, because `HTTPURLResponse` and `URLError` need it on Linux.

## Tests (`Tests/AgentGatewayTests/GatewayTranscriptionFailureTests.swift`)

Put all tests in `@Suite struct GatewayTranscriptionFailureTests`. Each case
below is `input -> expected`.

Retry-After (with `now = Date(timeIntervalSince1970: 1_700_000_000)`):

- `"7"` -> 7
- `" 7 "` -> 7
- `"Tue, 14 Nov 2023 22:13:50 GMT"` -> 30
- `"Wed, 21 Oct 2015 07:28:00 GMT"` -> 0
- `"-1"`, `"7.5"`, `""`, `"soon"`, `nil`, `"99999999999999999999"` -> nil

Classification (table-driven):

- `(429, "insufficient_quota", "credit_balance_exhausted")` -> `quotaExhausted`
- `(429, nil, "insufficient_quota")` -> `quotaExhausted`
- `(429, "rate_limit_exceeded", nil)` -> `rateLimited`
- `(429, "RESOURCE_EXHAUSTED", "429")` -> `rateLimited`
- `(429, nil, nil)` -> `rateLimited`
- `(402, nil, "402")` -> `quotaExhausted`
- `(401, nil, nil)` and `(403, nil, nil)` -> `authFailed`
- `(400, nil, nil)`, `(404, ...)`, `(413, ...)`, `(422, ...)` -> `invalidRequest`
- `(500, ...)`, `(503, ...)` -> `serverError`
- `(302, ...)`, `(200, ...)`, `(nil, ...)` -> `unknown`
- `(503, "insufficient_quota", nil)` -> `quotaExhausted` (vendor code wins)

Body parser:

- OpenAI
  `{"error":{"message":"m","type":"insufficient_quota","code":"credit_balance_exhausted"}}`
  -> `("insufficient_quota", "credit_balance_exhausted", "m")`
- Gemini `{"error":{"code":429,"message":"m","status":"RESOURCE_EXHAUSTED"}}`
  -> `("RESOURCE_EXHAUSTED", "429", "m")`
- OpenRouter `{"error":{"code":402,"message":"m","metadata":{}}}`
  -> `(nil, "402", "m")`
- `{"error":"plain"}` -> `(nil, nil, "plain")`
- `not json` -> all nil
- `{}` -> all nil

Factories and redaction:

- `httpFailure`, 429, OpenAI quota body, header `Retry-After: 7`:
  - `classification == .quotaExhausted`, `httpStatus == 429`,
    `retryAfterSeconds == 7`;
  - `vendorErrorCode == "credit_balance_exhausted"`;
  - `rpcError == GatewayRPCError(code: -32010, message: failure.message)`;
  - `errorDescription == failure.message`.
- `httpFailure`, 429, body of 600 `"x"` bytes, secret `"unused-secret"`:
  `message == "vendor HTTP 429: " + String(repeating: "x", count: 500)`.
  This is the legacy text.
- `httpFailure`, body of 20,000 bytes with the vendor code JSON at the end
  (the padding is inside `error.message`):
  - `rawBody!.utf8.count <= 16_384`;
  - `vendorErrorCode` is still parsed.
- Redaction ordering unit case:
  - secret `"fixture-secret-0123456789abcdef"` (31 bytes);
  - body is 480 `"x"` + secret + 100 `"x"`;
  - `message` and `rawBody` contain `[REDACTED]`;
  - for every n in 8...31, neither contains `String(secret.prefix(n))`.
- `gatewayUTF8Prefix("aé", maxBytes: 2)` -> `"a"`. The cut never splits a
  scalar.
- `transportFailure(error: URLError(.timedOut))`:
  - `classification == .transport` and `httpStatus == nil`;
  - `message` starts with `"vendor request failed: URLError(-1001)"`.
- `responseFailure(httpStatus: 200, data: "invalid", message: "vendor returned invalid transcription JSON")`:
  `unknown`, status 200, and `rawBody == "invalid"`.

## Verification (repository root, foreground)

Run `mkdir -p tmp/transcription-failure-build/transcription-failure-type/logs`
first. Each command writes its full log. Record each exit code and log path
in the Progress Log.

| Command | Must show |
| --- | --- |
| `swift build --scratch-path tmp/transcription-failure-build/transcription-failure-type > tmp/transcription-failure-build/transcription-failure-type/logs/build.log 2>&1; echo exit=$?` | `exit=0`, and no warnings that mention `GatewayTranscriptionFailure.swift` |
| `swift test --scratch-path tmp/transcription-failure-build/transcription-failure-type --filter GatewayTranscriptionFailureTests > tmp/transcription-failure-build/transcription-failure-type/logs/test.log 2>&1; echo exit=$?` | `exit=0`; the log shows a passing run with more than 0 tests, all from this suite |
| `swift test --scratch-path tmp/transcription-failure-build/transcription-failure-type --filter GatewayTranscription > tmp/transcription-failure-build/transcription-failure-type/logs/regression.log 2>&1; echo exit=$?` | `exit=0`; the existing transcription tests still pass unchanged |
| `swiftlint lint --cache-path tmp/transcription-failure-build/transcription-failure-type/swiftlint-cache Sources/AgentGatewayAppCore/GatewayTranscriptionFailure.swift Tests/AgentGatewayTests/GatewayTranscriptionFailureTests.swift > tmp/transcription-failure-build/transcription-failure-type/logs/lint.log 2>&1; echo exit=$?` | `exit=0`, 0 violations |
| `wc -l Sources/AgentGatewayAppCore/GatewayTranscriptionFailure.swift Tests/AgentGatewayTests/GatewayTranscriptionFailureTests.swift` | both under 1000 |
| `git status --porcelain --untracked-files=all` | the only changes in this plan's scope are the two new files and this plan file |

## Done Criteria

- [x] The public type, `Classification`, the init, `rpcError`, and
      `errorDescription` match the Contract exactly.
- [x] All internal helpers and factories exist with the pinned signatures.
- [x] Redaction is applied to the full text before both prefixes are taken
      (checked by the redaction-ordering unit case).
- [x] All the listed tests pass, the regression filter passes, swiftlint
      reports 0 violations, and the logs are under
      `tmp/transcription-failure-build/transcription-failure-type/logs/`.

## Progress Log

- 2026-11-12: Plan created.
- 2026-11-12: Implemented the pinned failure type, pure helpers and six test cases. Build, focused tests (6), and transcription regression tests (18) passed. Final logs: `tmp/transcription-failure-20261112/transcription-failure-type/{build-final,test-final,regression-final,lint-final,strict-lint}.log`; copies of the first four are under the plan scratch `logs/`. The plan lint command exits 0 but reports two warnings; strict selected-file lint exits 1: the required three-element parser tuple and required lossy `String(decoding:as:)` conflict with `large_tuple` and `optional_data_string_conversion`. Resolution requires reconciling the pinned contract with the prohibition on suppressing rules. Completion remains pending.
- Final source SHA-256: `GatewayTranscriptionFailure.swift` `7bd5791aa72ec8bc255a99ee7566e3be0c035ebd9492966a91e649b6aafbb6b9`; `GatewayTranscriptionFailureTests.swift` `1f1f8f83761287b784558f486e728577bfeebe0a3ee769ba368630e6b439db2e`.

- 2026-11-12 continuation: Switched to equivalent `Unicode.UTF8` lossy full-buffer decoding and added malformed UTF-8 coverage. Build, focused tests (6), and transcription regression (18) passed; `lint-cont1.log` reports one remaining `large_tuple` warning and `strict-lint-cont1.log` exits 1. The pinned three-element tuple signature conflicts with the enabled rule and suppression is prohibited. Logs are under `tmp/transcription-failure-20261112/transcription-failure-type/`; build/test/lint copies are under the plan scratch logs. Current SHA-256: source `902aa14539b88da49e74799ea7fe3a78a3d39cbb4b8812e5d816f4921c65ba05`; tests `0a56d494bc5c9b95a45ebdc8cefe3113ddc961b198a9db8b4c7f3b404d0aca90`.

- 2026-11-12 RECON-001: Replaced the internal tuple with `GatewayVendorErrorFields` without changing parsing or public/factory signatures. Source SHA-256 before: `902aa14539b88da49e74799ea7fe3a78a3d39cbb4b8812e5d816f4921c65ba05`; after: `f24f0277c5635d2f6eb25ea144a7c8ac9886b00df9a61e91160fbf242db65ad5`. Test SHA-256 before and after: `0a56d494bc5c9b95a45ebdc8cefe3113ddc961b198a9db8b4c7f3b404d0aca90`. Build, focused tests (6), transcription regression (18), strict selected-file lint, and repository lint all exit 0; no disable comments (grep exit 1). Complete logs: `tmp/transcription-failure-20261112/transcription-failure-type/{build-recon001,test-recon001,regression-recon001,changed-lint-recon001,strict-lint-recon001,repo-lint-recon001,disable-recon001}.log`; required build/test/lint copies are in `tmp/transcription-failure-build/transcription-failure-type/logs/`. Formal review remains downstream.
