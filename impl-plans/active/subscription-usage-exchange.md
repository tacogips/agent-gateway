# Subscription Usage: Interactive JSON Line Exchange

**Status**: Ready
**Plan ID**: `subscription-usage-exchange`
**Wave**: 1 (no dependencies)
**Design Reference**: `design-docs/specs/design-subscription-usage.md#interactive-line-exchange`

## Purpose

`codex app-server` exits on stdin EOF before it answers, so
`POSIXGatewayProcessRunner`, which writes all of stdin and then closes it,
cannot be used. This plan adds an internal helper that does the following:

- spawns a child process;
- writes request lines while keeping stdin open;
- returns the first stdout line a matcher accepts;
- always cleans up the child.

The wave-2 reader plan uses this helper for both Claude and Codex.

## Repository Context

- Pattern to imitate:
  `Sources/AgentGatewayAppCore/GatewayACPClientRunner.swift:GatewayACPClientRunner.run`
  (lines 51-115). It uses Foundation `Process` with three `Pipe`s, a stderr
  `readabilityHandler`, and `#if os(macOS) || os(Linux)`.
- Line reader: `Sources/ACP/ACPTransport.swift:ACPFileHandleTransport`.
  `init(input:output:)` reads `input` through a `readabilityHandler` and yields
  one `Data` per line (newline stripped) on `lines: AsyncStream<Data>`. It
  finishes the stream on EOF. `close()` closes both handles.
- SIGPIPE-safe write:
  `Sources/GatewayProcessNative/include/GatewayProcessNative.h:gwp_write(int, const void *, size_t) -> ssize_t`.
  It is already used by `POSIXGatewayProcessRunner.swift` through
  `import GatewayProcessNative`, and `AgentGatewayAppCore` already depends on it.
- Error type for unsupported platforms:
  `GatewayProcessContracts.swift:GatewayProcessError.launchFailed(Int32)`.
- Swift 6 strict concurrency. Mutable shared state goes in a
  `final class ...: @unchecked Sendable` with an `NSLock`, the same way as
  `ACPLineSplitter`.
- Tests use swift-testing. For fake executables, imitate
  `Tests/AgentGatewayTests/GatewayExecutorEnvironmentTests.swift:makeEnvironmentEchoingVendorScript`
  (temp directory plus `#!/bin/sh` plus `posixPermissions: 0o755`).

## Write Ownership

- `Sources/AgentGatewayAppCore/GatewayJSONLineExchange.swift` (new)
- `Tests/AgentGatewayTests/GatewayJSONLineExchangeTests.swift` (new)
- `impl-plans/active/subscription-usage-exchange.md` (this plan's progress log only)

Do not touch `ACPTransport.swift`, `GatewayProcessNative`,
`GatewayACPClientRunner.swift`, `POSIXGatewayProcessRunner.swift`, or any
sibling-owned file.

## Contract (exact internal signatures)

```swift
enum GatewayJSONLineExchangeError: Error, Equatable, Sendable {
  case launchFailed(String)                 // String(describing:) of the Process.run() error
  case exitedWithoutAnswer(stderrTail: String)  // trimmed, at most 2048 bytes, may be ""
  case timedOut(seconds: Double)
}

func exchangeGatewayJSONLines(
  executable: String, arguments: [String], environment: [String: String],
  requests: [Data],            // each WITHOUT trailing newline; helper appends "\n"
  timeoutSeconds: Double,
  isResponse: @escaping @Sendable (Data) -> Bool
) async throws -> Data         // the matched line, newline stripped
```

The helper does not know about subscription usage or `GatewayRPCError`. The
wave-2 reader maps these cases to `-32041` messages. On platforms other than
macOS and Linux, the body is only `throw GatewayProcessError.launchFailed(ENOTSUP)`.

## Required Behavior

1. Create `Process` with `executableURL`, `arguments` and `environment`
   exactly as passed. Do not set `currentDirectoryURL`. Set stdin, stdout and
   stderr to new `Pipe`s.
2. Install the stderr `readabilityHandler` before `run()`. It appends each
   chunk to a lock-protected tail box that keeps the last 2048 bytes. When it
   sees empty data (EOF), it sets the handler to nil and marks the box `finished`.
3. Create `ACPFileHandleTransport(input: stdout.fileHandleForReading, output: stdin.fileHandleForWriting)`
   before `run()`, so no output is missed. If `run()` throws, throw
   `.launchFailed(String(describing: error))` after cleanup.
4. Write each request plus `\n` with `gwp_write` on
   `stdin.fileHandleForWriting.fileDescriptor`. Loop on partial writes and
   retry on `EINTR`. On any other failure (for example `EPIPE`), stop writing.
   The child is gone, so continue to step 5, which then ends in the
   exited-without-answer path. Never use `FileHandle.write(_:)` or
   `transport.send(line:)`, because on a dead reader they raise SIGPIPE or an
   uncatchable exception in the host.
5. Race the two branches in a throwing task group:
   - Reader: `for await line in transport.lines where isResponse(line) { return line }`,
     then `nil` on stream end.
   - Timer: `Task.sleep` for `timeoutSeconds`, then throw
     `.timedOut(seconds: timeoutSeconds)`.

   Take the first result and `cancelAll()`. Only `transport.lines` and
   `isResponse` may cross into the child tasks. Do not capture `Process` or
   `Pipe` in them.
6. If the result is nil (stdout EOF without a match), wait up to 2 s for
   `!process.isRunning` by polling `Task.sleep(for: .milliseconds(20))`. Then
   wait up to 1 s for the stderr box to report `finished`. Then throw
   `.exitedWithoutAnswer(stderrTail: box.text)`, where the text is trimmed of
   whitespace and newlines.
7. Cleanup runs on every path (success, timeout, exit, launch failure, and
   cancellation of the calling task):
   - if the process is running, call `terminate()` (SIGTERM);
   - poll for up to 2 s;
   - if it is still running, call `kill(process.processIdentifier, SIGKILL)`;
   - then call `waitUntilExit()` (now guaranteed to return);
   - then call `transport.close()` and nil the stderr handler.

   Because `defer` cannot `await`, put the cleanup in one private `async`
   helper that is called on every path, for example with
   `do { ... } catch { await cleanup(); throw error }` and after a success.
8. Stdin stays open until cleanup. Do not close it after writing.

## Pitfalls

- Do not close the child-side pipe ends yourself after `run()`, because
  Foundation already does it. A double close can close a reused descriptor.
- A child that exits right after printing its response leaves the line in
  the pipe. The response must still be returned, so stdout EOF, not process
  termination, is the exit signal. Do not use `terminationHandler` to fail early.
- Never call `waitUntilExit()` before the child is guaranteed to exit
  (blocking hang).
- Do not install a process-wide `signal(SIGPIPE, SIG_IGN)`.
- Do not reference `Process` outside the `#if os(macOS) || os(Linux)` guard.
  iOS 17 library builds must compile.
- Parallel siblings edit the same tree. If `swift build` fails in a file you
  do not own, wait and retry; never edit it.

## Tests (`GatewayJSONLineExchangeTests.swift`, `@testable import AgentGatewayAppCore`)

Prefix every test function name with `jsonLineExchange`. Each test writes a
`#!/bin/sh` script into its own temp directory, chmods it to 0755, uses
`environment: ["PATH": "/usr/bin:/bin"]`, and removes the directory in `defer`.
The matcher in every test is "the line parses as a JSON object with `id == 2`".

- Answers after noise. The script reads 3 lines, prints `not json`, then
  `{"method":"note"}`, then `{"id":1,"result":{}}`, then `{"id":2,"result":{"ok":true}}`,
  and then loops `while IFS= read -r l; do :; done`.
  Expected: the returned line decodes to `id == 2` with `result.ok == true`.
  The call finishes well under the 10 s timeout, which proves the
  still-running child was terminated.
- Requests are delivered in order. The script reads 2 lines and echoes them
  back as `{"id":2,"echo":"<line1>|<line2>"}` (use `printf` with care for
  quoting, or base64-free plain tokens such as `{"n":1}` and `{"n":2}`).
  Expected: the echo shows both lines in order.
- Exits without answering. The script runs `read -r l; echo "fake failure detail" >&2; exit 3`.
  Expected: it throws `.exitedWithoutAnswer(stderrTail:)` whose text contains
  `fake failure detail`.
- Never answers. The script is `while IFS= read -r l; do :; done`, with
  `timeoutSeconds: 0.5`. Expected: it throws `.timedOut(seconds: 0.5)`, the
  elapsed time is under 5 s, and no hang.
- Missing executable. The executable is `<tempdir>/does-not-exist`.
  Expected: it throws `.launchFailed(_)`.

## Verification (repository root, foreground)

| Command | Must show |
| --- | --- |
| `swift build 2>&1 \| tee /tmp/sub-usage-exchange-build.log; echo exit=$?` | exit=0 |
| `swift test --filter jsonLineExchange 2>&1 \| tee /tmp/sub-usage-exchange-test.log` | the 5 tests pass, 0 failures, total under 30 s |
| `swiftlint lint Sources/AgentGatewayAppCore/GatewayJSONLineExchange.swift Tests/AgentGatewayTests/GatewayJSONLineExchangeTests.swift` | 0 violations |
| `grep -n "Process()" Sources/AgentGatewayAppCore/GatewayJSONLineExchange.swift` plus a manual check | every `Process` use is inside `#if os(macOS) \|\| os(Linux)` |
| `ps -A -o command \| grep -c "[w]hile IFS"` after the tests | 0 (no orphaned fake children) |

Record the commands, exit statuses and log paths in the progress log.

## Done Criteria

- [ ] The signatures match the Contract section exactly.
- [ ] There are no `FileHandle.write`, `transport.send` or `signal(` calls in the owned source file.
- [ ] All `jsonLineExchange*` tests pass, and the build and lint checks are clean.
- [ ] `git diff --name-only` shows only the owned files.

## Progress Log

- 2026-10-31: Plan created.
