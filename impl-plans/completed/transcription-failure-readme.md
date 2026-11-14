# Transcription Failure: README Failure Contract

**Status**: Completed
**Plan ID**: `transcription-failure-readme`
**Wave**: 1 (no dependencies; documentation only)
**Depends On**: none
**Design Reference**: `design-docs/specs/design-transcription-failure.md`
(sections README, Error Surface Split, Public Type, Compatibility mapping,
Classification Rules, Retry-After, Exactly One Wire Request, Secrets, CLI)

## Intent

Document the transcription failure contract for library callers (Riela's
speech-to-text node) and for CLI users, in README.md's `## Audio
transcription` section.

## Repository Context

- README.md `## Audio transcription` starts at about line 320 and ends
  before `## Provider routing library`.
- The paragraph to replace begins "Diagnostics go to stderr." (about lines
  344-351). It currently says that vendor HTTP failures use `-32010` and
  keep `vendor HTTP <status>: <body>`.

## Non-Goals

- No edits outside `## Audio transcription`.
- No edits to design docs, source, or tests. No emojis.

## Write Ownership

- `README.md`
- `impl-plans/active/transcription-failure-readme.md` (Progress Log only)

Before the first edit and after the last one, record `shasum -a 256
README.md`. Re-read the file before every edit.

## Changes

Rewrite the "Diagnostics go to stderr." paragraph and add a short
`### Failure contract` subsection under `## Audio transcription`. Together
they must state all of the following:

1. **Failure sources.**
   - Checks before the transport keep throwing `GatewayRPCError`:
     - `-32021` unsupported vendor;
     - `-32602` invalid input, size, MIME type, or base URL;
     - `-32011` missing credential;
     - Foundation file errors.
   - Cancellation throws `CancellationError`.
   - Every failure after the request is sent is a
     `GatewayTranscriptionFailure`. That covers vendor HTTP errors
     including 3xx, a non-HTTP response, an invalid 2xx payload, and
     transport errors.
2. **Fields.** `vendor`, `classification`, `httpStatus`,
   `retryAfterSeconds`, `vendorErrorType`, `vendorErrorCode`,
   `vendorMessage`, `rawBody` (at most 16,384 UTF-8 bytes), and
   `message`.
3. **Classification.** List the cases, with vendor type/code taking
   precedence over status:
   - `insufficient_quota` / `credit_balance_exhausted` -> `quotaExhausted`;
   - `rate_limit_exceeded` and Gemini `RESOURCE_EXHAUSTED` ->
     `rateLimited`;
   - then status: 402 `quotaExhausted`, 429 `rateLimited`, 401/403
     `authFailed`, other 4xx `invalidRequest`, 5xx `serverError`;
   - everything else, including 3xx, is `unknown`;
   - transport errors are `transport`.
4. **Retry-After.** Delta-seconds or an IMF-fixdate HTTP-date, converted to
   whole seconds. Otherwise nil.
5. **One request.** Exactly one HTTP request is sent per call. Redirects
   are not followed (a 3xx is reported with its status), and agent-gateway
   never retries. Retries belong to the caller.
6. **Compatibility.** `failure.rpcError` is `GatewayRPCError(code: -32010,
   message: failure.message)`. `message` keeps the legacy
   `vendor HTTP <status>: <first 500 bytes>` text, except that the credential
   is replaced with `[REDACTED]` when the body echoes it.
   `localizedDescription`
   returns `message`. Callers that used to catch `GatewayRPCError` should
   add `catch let failure as GatewayTranscriptionFailure`.
7. **Secrets.** The API key is replaced with `[REDACTED]` in every failure
   field before any truncation. Request URLs and headers are never
   included.
8. **CLI.** Show the exact six-line stderr format in a fenced block
   (`transcription failed (-32010): ...`, `classification:`,
   `http-status:`, `vendor-error-type:`, `vendor-error-code:`,
   `retry-after-seconds:`), state that `none` marks a missing value, and
   state that the exit status is 1. Keep the existing statements about
   exit 2 for invalid flags, `-32021`, `-32011`, and credentials.
9. A short Swift snippet that catches `GatewayTranscriptionFailure` and
   switches on `classification` (at most 12 lines). It must not show a
   real key.

## Verification (repository root, foreground)

| Command | Must show |
| --- | --- |
| `grep -n "GatewayTranscriptionFailure\|quotaExhausted\|rateLimited\|retry-after-seconds\|Retry-After\|rpcError\|REDACTED" README.md` | every listed term appears, and only inside `## Audio transcription` |
| `grep -n "^## Audio transcription\|^## Provider routing library\|^### Failure contract" README.md` | the subsection lies between the two `##` headings |
| `git diff --stat -- README.md` and `git diff README.md` | only that section changed |
| `grep -nP "[\x{1F300}-\x{1FAFF}]" README.md; echo exit=$?` | `exit=1` (no emojis) |

## Done Criteria

- [x] Items 1-9 are present in `## Audio transcription`.
- [x] Nothing outside the section changed. The README hashes are recorded
      in the Progress Log.

## Progress Log

- 2026-11-12: Plan created.
- 2026-11-12: Implemented items 1-9 in the Audio transcription section.
  README SHA-256 before: `6eff91d5508abf7343af50cb70dc063d4f421fcf715ab173306cfe72bfb1c72d`;
  after: `ba9ca324d2188d4df005f83043e100fd16479e8a9e7d54435c27f7be7d361444`.
  Section scope and emoji checks are recorded in plan-local evidence. Formal
  review and workflow finalization remain downstream.
- 2026-11-12: Step 8 documentation refresh. The `### Failure contract`
  subsection (README.md lines 349-405) matches the accepted implementation,
  including the six-line CLI stderr in
  `Sources/AgentGatewayAppCore/GatewayTranscriptionCommand.swift`. The
  integration review passed with 168 tests. Plan completed and queued for
  archiving to `impl-plans/completed/transcription-failure-readme.md`.
