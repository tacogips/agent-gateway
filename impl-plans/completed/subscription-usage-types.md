# Subscription Usage: Public Types

**Status**: Completed
**Plan ID**: `subscription-usage-types`
**Wave**: 1 (no dependencies)
**Design Reference**: `design-docs/specs/design-subscription-usage.md#public-api`

## Purpose

Add the public value types that carry a vendor CLI's subscription rate-limit
windows. These types are the contract that `subscription-usage-reader-cli`
(wave 2) fills in and the CLI prints. Do not change the shapes listed here.
Other plans compile against them.

## Repository Context

- Swift 6 package (`swift-tools-version: 6.0`). Platforms are macOS 14 and
  iOS 17, and Linux is also built. Tests use swift-testing (`import Testing`,
  `@Test`, `#expect`), not XCTest.
- Pattern to imitate: `Sources/AgentGateway/GatewayProtocol.swift:GatewayModelCatalogParams`.
  It is a `public struct ...: Codable, Equatable, Sendable` with `public var`
  fields and a `public init` whose default is
  `protocolVersion: String = GatewayProtocolVersion.current`.
- `GatewayVendor` (raw values `claude-code`, `codex`, ...) is at `GatewayProtocol.swift:7`.
- Follow `.codex/skills/swift-coding-agent/SKILL.md` and AGENTS.md: two-space
  indentation, no emojis, files under 1000 lines.

## Write Ownership

- `Sources/AgentGateway/GatewaySubscriptionUsage.swift` (new)
- `Tests/AgentGatewayTests/GatewaySubscriptionUsageTypesTests.swift` (new)
- `impl-plans/active/subscription-usage-types.md` (this plan's progress log only)
- `tmp/subscription-usage-build/subscription-usage-types` (generated-output
  root and artifact root: SwiftPM scratch directory, swiftlint cache and
  verification logs; gitignored, never committed)

All SwiftPM output for this plan goes to that root (`--scratch-path`). Never
build into the default `.build`, because sibling wave-1 plans build at the
same time.

Do not touch any other file. In particular, do not touch `GatewayProtocol.swift`,
`Package.swift`, or files owned by sibling plans
(`GatewayJSONLineExchange.swift`, `README.md`).

## Contract (exact shapes)

```swift
public struct GatewaySubscriptionUsageParams: Codable, Equatable, Sendable {
  public var protocolVersion: String; public var vendor: GatewayVendor
  public var executable: String?; public var timeoutSeconds: Double?
  // public init(protocolVersion: = GatewayProtocolVersion.current, vendor:, executable: = nil, timeoutSeconds: = nil)
}
public enum GatewaySubscriptionUsageWindowKind: String, Codable, Sendable { case fiveHour, weekly, other
  public static func classify(windowMinutes: Int?) -> Self }   // 300 -> fiveHour, 10080 -> weekly, else other (incl. nil)
public struct GatewaySubscriptionUsageWindow: Codable, Equatable, Sendable {
  public var kind; public var scope: String?; public var windowMinutes: Int?
  public var usedPercent: Double; public var resetsAt: Date?
  // public init(kind:, scope: = nil, windowMinutes:, usedPercent:, resetsAt:)
}
public struct GatewaySubscriptionUsageResult: Codable, Equatable, Sendable {
  public var protocolVersion: String; public var vendor: GatewayVendor
  public var planType: String?; public var available: Bool
  public var windows: [GatewaySubscriptionUsageWindow]
  // public init(protocolVersion: = GatewayProtocolVersion.current, vendor:, planType:, available:, windows:)
}
package func parseGatewayISO8601Date(_ value: String) -> Date?
```

`parseGatewayISO8601Date` uses `package` access, not `public`. The Claude parser
in `AgentGatewayAppCore` (same package) reuses it, so do not widen the public API.

## Changes

1. Create `GatewaySubscriptionUsage.swift` with the four types above, each
   with a short doc comment (see the draft at
   `/private/tmp/claude-501/-Users-taco-gits-tacogips-agent-gateway/5cb159dd-584b-44c9-a008-3268ffda8a01/scratchpad/draft/GatewaySubscriptionUsage.swift`
   as a starting point only; it was never compiled).
2. `GatewaySubscriptionUsageWindow` gets custom `init(from:)` and `encode(to:)`:
   - `resetsAt` encodes as a string through `ISO8601DateFormatter` with
     `formatOptions = [.withInternetDateTime]` and a UTC time zone, so the output
     has whole seconds and ends in `Z`, for example `2026-10-31T18:00:00Z`.
     Use `encodeIfPresent` for `scope`, `windowMinutes` and `resetsAt`, so nil
     fields are omitted.
   - `resetsAt` decodes as `String?`, then `parseGatewayISO8601Date`. If the
     string does not parse, throw `DecodingError.dataCorruptedError(forKey: .resetsAt, ...)`.
     Do not silently return nil.
3. `parseGatewayISO8601Date`: if the string has a `.` followed by digits,
   keep at most 3 of those digits and keep the remainder (zone suffix)
   unchanged. Then parse with `ISO8601DateFormatter`, using
   `[.withInternetDateTime, .withFractionalSeconds]` when a fraction remains
   and `[.withInternetDateTime]` otherwise. Return nil on failure. Create the
   formatter inside the function, because `ISO8601DateFormatter` is not
   `Sendable` and must not be a global.

## Pitfalls

- Do not use `Date.ISO8601FormatStyle` or `Date(_:strategy:)`. Use
  `ISO8601DateFormatter`, which behaves the same on macOS, iOS 17 and Linux.
- `ISO8601DateFormatter` rejects 6 fractional digits. That is the reason for
  the truncation, so do not drop it.
- `Params` and `Result` keep the synthesized `Codable`. Only `Window` is custom.
- Do not add a `package`/`public` JSON encoder helper, CLI code, or error constants here.
  The error constants belong to the wave-2 reader plan.
- Parallel siblings edit the same working tree. If `swift build` fails in a
  file you do not own, wait and retry; never edit it.
- Edit discipline: re-read each owned file right before every edit. Record
  `shasum -a 256 <owned files>` in the progress log before the first edit and
  after the last one. If an owned file's content changes between your own
  edits (drift), stop and record it in the progress log; do not overwrite it.
  Cross-plan repair happens serially after the wave joins.

## Tests (`GatewaySubscriptionUsageTypesTests.swift`, `@testable import AgentGateway`)

Prefix every test function name with `subscriptionUsageTypes` so the filter
below selects them.

- `classify(windowMinutes:)`: 300 gives `.fiveHour`; 10080 gives `.weekly`;
  60 gives `.other`; nil gives `.other`.
- A window with `resetsAt = Date(timeIntervalSince1970: 1793469600)` (whole
  second), encoded with a `.sortedKeys` `JSONEncoder`, gives a JSON string
  containing `"resetsAt":"<ISO string ending in Z>"`, and decoding it back
  gives an equal value.
- A window with `scope`, `windowMinutes` and `resetsAt` all nil encodes without
  those keys.
- Decoding `{"kind":"weekly","usedPercent":68,"resetsAt":"2026-11-01T17:00:00.066934+00:00"}`
  succeeds, and `resetsAt` is within 0.001 s of `2026-11-01T17:00:00.066Z`.
- Decoding with `"resetsAt":"not-a-date"` throws.
- `parseGatewayISO8601Date("2026-11-01T17:00:00+00:00")` is non-nil, and
  `parseGatewayISO8601Date("garbage")` is nil.
- A Result round-trip: `GatewaySubscriptionUsageResult(vendor: .codex, planType: "pro", available: true, windows: [...])`
  encodes and decodes to an equal value, and its JSON contains `"vendor":"codex"`.

## Verification (run from the repository root, foreground)

`R` below means `tmp/subscription-usage-build/subscription-usage-types`. Run
`mkdir -p tmp/subscription-usage-build/subscription-usage-types/logs` first.
Redirect to a file instead of piping through `tee`, so `echo exit=$?` reports
the Swift exit status and not the exit status of `tee`.

| Command | Must show |
| --- | --- |
| `swift build --scratch-path tmp/subscription-usage-build/subscription-usage-types > tmp/subscription-usage-build/subscription-usage-types/logs/build.log 2>&1; echo exit=$?` | exit=0 (compiles on the host) |
| `swift test --scratch-path tmp/subscription-usage-build/subscription-usage-types --filter subscriptionUsageTypes > tmp/subscription-usage-build/subscription-usage-types/logs/test.log 2>&1; echo exit=$?` | exit=0; the log lists every new `subscriptionUsageTypes*` test as passed, with 0 failures |
| `swiftlint lint --cache-path tmp/subscription-usage-build/subscription-usage-types/swiftlint-cache Sources/AgentGateway/GatewaySubscriptionUsage.swift Tests/AgentGatewayTests/GatewaySubscriptionUsageTypesTests.swift; echo exit=$?` | 0 violations in the owned files, exit=0 |
| `wc -l Sources/AgentGateway/GatewaySubscriptionUsage.swift` | under 1000 |
| `git status --porcelain --untracked-files=all` | this plan adds or changes only its owned files (`tmp/` is ignored) |

Record the commands, exit statuses and full log paths under `R/logs/` in the
progress log. A truncated log, or a run that is still going, does not count
as a pass.

## Done Criteria

- [x] Both owned files exist, and the public symbols match the Contract section exactly.
- [x] `grep -n "package func parseGatewayISO8601Date" Sources/AgentGateway/GatewaySubscriptionUsage.swift` matches.
- [x] All `subscriptionUsageTypes*` tests pass, and the build and lint checks above are clean.
- [x] `git status --porcelain --untracked-files=all` shows no file outside Write Ownership changed by this plan.
- [x] No `.build` output was produced by this plan; all build output is under `tmp/subscription-usage-build/subscription-usage-types`.

## Progress Log

- 2026-10-31: Plan created.
- 2026-11-01: Amended (session-593). Added the plan-unique artifact root
  `tmp/subscription-usage-build/subscription-usage-types`. Verification now
  uses `--scratch-path` and `--cache-path`, with logs under the root and no
  `tee`.

- 2026-11-01: Implemented public types and date parsing with six focused tests.
  Before edits: source and tests absent; plan SHA-256
  `e1479870fb934f68d230c341ef5b4ab82256d37857ec1eb2d3513a9ccc8b91b2`.
  Source SHA-256 `908f0c35df23e02ff0b6aa51e199328139335e187425e2978da642bed42a66f2`;
  tests SHA-256 `3885c6bc013953e4c05fcd4860ffff65ac52d46a2f2319578b77b3ba3af47099`.
  `swift build --scratch-path tmp/subscription-usage-build/subscription-usage-types`
  exited 0 (`tmp/subscription-usage-build/subscription-usage-types/logs/build.log`);
  `swift test --scratch-path tmp/subscription-usage-build/subscription-usage-types --filter subscriptionUsageTypes`
  exited 0, six tests passed (`tmp/subscription-usage-build/subscription-usage-types/logs/test.log`).
  Plan-scoped SwiftLint and strict changed-file SwiftLint exited 0 with zero violations
  (`tmp/subscription-usage-build/subscription-usage-types/logs/lint.log` and
  `tmp/subscription-usage-build/subscription-usage-types/logs/strict-lint.log`).
  Source is 133 lines and package parser is present. Shared status also shows
  sibling README and exchange changes; this plan did not edit them. Formal
  review and integration are downstream. Post-edit hashes are recorded in
  `tmp/subscription-usage-20261031/subscription-usage-types/post-edit-sha.txt`.
- 2026-11-01: Completed. Accepted by adversarial and integration review
  (session-593); archived to `impl-plans/completed/subscription-usage-types.md`.
