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
- `tmp/subscription-usage-build/subscription-usage-exchange` (generated-output
  root and artifact root: SwiftPM scratch directory, swiftlint cache and
  verification logs; gitignored, never committed)

All SwiftPM output for this plan goes to that root (`--scratch-path`). Never
build into the default `.build`, because sibling wave-1 plans build at the
same time. Test fake scripts go in system temp directories (see Tests), not
in this root.

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
- Edit discipline: re-read each owned file right before every edit. Record
  `shasum -a 256 <owned files>` in the progress log before the first edit and
  after the last one. If an owned file's content changes between your own
  edits (drift), stop and record it in the progress log; do not overwrite it.
  Cross-plan repair happens serially after the wave joins.

## Tests (`GatewayJSONLineExchangeTests.swift`, `@testable import AgentGatewayAppCore`)

Prefix every test function name with `jsonLineExchange`. Each test writes a
`#!/bin/sh` script into its own temp directory under
`FileManager.default.temporaryDirectory`, named with the prefix
`agent-gateway-jsonline-test-` plus a UUID, so the orphan check below can find
leftover children. It chmods the script to 0755, uses
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

Run `mkdir -p tmp/subscription-usage-build/subscription-usage-exchange/logs`
first. Redirect to a file instead of piping through `tee`, so `echo exit=$?`
reports the Swift exit status.

| Command | Must show |
| --- | --- |
| `swift build --scratch-path tmp/subscription-usage-build/subscription-usage-exchange > tmp/subscription-usage-build/subscription-usage-exchange/logs/build.log 2>&1; echo exit=$?` | exit=0 |
| `swift test --scratch-path tmp/subscription-usage-build/subscription-usage-exchange --filter jsonLineExchange > tmp/subscription-usage-build/subscription-usage-exchange/logs/test.log 2>&1; echo exit=$?` | exit=0; the log shows the 5 `jsonLineExchange*` tests passed, 0 failures, total under 30 s |
| `swiftlint lint --cache-path tmp/subscription-usage-build/subscription-usage-exchange/swiftlint-cache Sources/AgentGatewayAppCore/GatewayJSONLineExchange.swift Tests/AgentGatewayTests/GatewayJSONLineExchangeTests.swift; echo exit=$?` | 0 violations, exit=0 |
| `grep -n "Process()" Sources/AgentGatewayAppCore/GatewayJSONLineExchange.swift` plus a manual check | every `Process` use is inside `#if os(macOS) \|\| os(Linux)` |
| `grep -n "FileHandle.write\|\.send(line\|signal(" Sources/AgentGatewayAppCore/GatewayJSONLineExchange.swift` | no output |
| `ps -A -o command \| grep -c "[a]gent-gateway-jsonline-test-"` after the tests | `0` (no orphaned fake children; grep exits 1 when the count is 0, which is expected) |
| `git status --porcelain --untracked-files=all` | this plan adds or changes only its owned files (`tmp/` is ignored) |

Record the commands, exit statuses and full log paths under
`tmp/subscription-usage-build/subscription-usage-exchange/logs/` in the
progress log. A truncated log, or a run that is still going, does not count
as a pass.

## Done Criteria

- [ ] The signatures match the Contract section exactly.
- [ ] There are no `FileHandle.write`, `transport.send` or `signal(` calls in the owned source file.
- [ ] All `jsonLineExchange*` tests pass, and the build and lint checks are clean.
- [ ] `git status --porcelain --untracked-files=all` shows only the owned files.
- [ ] No `.build` output was produced by this plan; all build output is under `tmp/subscription-usage-build/subscription-usage-exchange`.

## Progress Log

- 2026-10-31: Plan created.
- 2026-11-01: Amended (session-593). Added the plan-unique artifact root
  `tmp/subscription-usage-build/subscription-usage-exchange`. Verification
  now uses `--scratch-path` and `--cache-path`, with logs under the root and
  no `tee`. The orphan check now greps the fake-script temp-dir prefix,
  because the old `[w]hile IFS` pattern never matches the `/bin/sh <script>`
  command line.
