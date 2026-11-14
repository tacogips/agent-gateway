# Transcribe CLI

## Status

Draft

## Goal

Expose the existing library transcription API
(`ProductionGatewayExecutor.transcribe(_:)`, protocol `GatewayTranscribing`,
in `Sources/AgentGatewayAppCore/GatewayTranscription.swift`) as an
`agent-gateway transcribe` subcommand for OpenAI, Gemini, and OpenRouter.

The vendor HTTP request building, response parsing, size limit, credential
lookup, and error codes stay in the library. The CLI only parses flags,
infers the MIME type, calls a `GatewayTranscribing`, and formats the output.
`GatewayTranscriptionParams`, `GatewayTranscriptionResult`, and
`GatewayTranscribing` keep their current shape.

## Synopsis

```
agent-gateway transcribe --vendor <openai|gemini|openrouter> --model <id> --file <path>
  [--mime-type <type>] [--language <code>] [--prompt <text>]
  [--api-key-environment <name>] [--base-url <url>]
  [--timeout-seconds <n>] [--output text|json]
```

Example:

```bash
OPENAI_API_KEY=... agent-gateway transcribe --vendor openai --model whisper-1 --file meeting.m4a --language ja
agent-gateway transcribe --vendor gemini --model gemini-3.5-flash-lite --file memo.wav --output json
```

## Flag Parsing

Flags use `--key value` pairs, like `parseOptions`. The command has its own
small parser and does not add fields to `GatewayClientOptions`. That way,
other subcommands do not start silently accepting `--file`, `--output`, and
the other transcribe-only flags.

| Flag | Required | Maps to | Invalid value |
| --- | --- | --- | --- |
| `--vendor` | yes | `params.vendor` (`GatewayVendor(rawValue:)`) | absent or unknown string: `missingValue("--vendor")` |
| `--model` | yes | `params.model` | absent: `missingValue("--model")` |
| `--file` | yes | `params.audioFile = URL(fileURLWithPath:)` (relative to the current directory) | absent: `missingValue("--file")` |
| `--mime-type` | no | `params.mimeType` (passed through unchanged) | library validates it (`-32602 unsupported audio MIME type`) |
| `--language` | no | `params.language` | -- |
| `--prompt` | no | `params.prompt` | -- |
| `--api-key-environment` | no | `params.apiKeyEnvironment` | -- |
| `--base-url` | no | `params.baseURL` | library validates it (`-32602 invalid base URL`) |
| `--timeout-seconds` | no, default 120 (library default) | `params.timeoutSeconds` | not an integer: `missingValue("--timeout-seconds")`; `<= 0` is passed through and the library rejects it with `-32602` |
| `--output` | no, default `text` | output format | not `text` or `json`: `missingValue("--output")` |

The parser also handles these cases:

- An unknown flag, a bare positional argument, or `--` throws
  `AppCommand.Error.unknownArgument`.
- A flag with no following value throws `missingValue(<flag>)`.
- If a flag is repeated, the last value wins, as in the existing parser.
- `main.swift` maps both parse errors to stderr and exit code 2. This
  mapping is unchanged.

A known vendor that does not support transcription, such as `anthropic`,
`cursor`, `cursor-api`, `claude-code`, or `codex`, is not a parse error. See
the execution order below.

## Execution Order

The CLI must never do file or network I/O for an unsupported vendor.

1. Parse the flags. This step is pure.
2. Check the vendor. If the vendor is not openai, gemini, or openrouter, fail
   with `GatewayRPCError(-32021, "<vendor> does not support audio
   transcription")`. The check uses one shared helper,
   `validateGatewayTranscriptionVendor(_:)`, in
   `GatewayTranscription.swift`. To create it, move the existing inline
   `[.openAI, .gemini, .openRouter]` guard out of `transcriptionAPIKey`
   without changing its behavior, and have `transcriptionAPIKey` call the
   helper. This is one of two internal AppCore library changes; the other
   is the transport seam described under Test Seam. It makes sure the CLI
   and the library cannot drift apart. It is also why `-32021` wins over a
   MIME inference error.
3. Resolve the MIME type. Use `--mime-type` when it is given. Otherwise infer
   it from the file extension using the static table below. This reads only
   the path string, not the file. If the extension is unknown or missing,
   fail with `GatewayRPCError(-32602, "cannot infer audio MIME type from file
   extension '<ext>'; pass --mime-type")`.
4. Build `GatewayTranscriptionParams` and call
   `transcriber.transcribe(params)`. The library then runs its own checks in
   this order: vendor, protocol version, timeout, credential (`-32011
   missing credential environment '<NAME>'`), then file loading and the HTTP
   call.
   - A missing file, a non-regular file, or a file larger than 25,000,000
     bytes (`gatewayTranscriptionMaxBytes`) is rejected by
     `loadGatewayTranscriptionAudio`.
   - The size check uses the file's stat size, so the file is never read
     into memory before the check.

The CLI does not stat or open the file itself. All file checks stay in the
library, so the vendor-first ordering is preserved.

### MIME inference table

The extension match is case-insensitive. The table is static, which keeps it
portable to Linux. `UniformTypeIdentifiers` is not used.

| Extension | MIME type |
| --- | --- |
| `wav` | `audio/wav` |
| `mp3`, `mpga`, `mpeg` | `audio/mpeg` |
| `m4a`, `mp4` | `audio/mp4` |
| `webm` | `audio/webm` |
| `ogg`, `oga` | `audio/ogg` |
| `flac` | `audio/flac` |
| `aac` | `audio/aac` |

Every value in the table is accepted by `transcriptionAudioFormat`.

## Output And Exit Codes

Stdout carries only the result. Diagnostics go to stderr.

| Outcome | stdout | stderr | exit |
| --- | --- | --- | --- |
| Success, `--output text` | the transcript text followed by one `\n`; an empty transcript gives just `\n` | nothing | 0 |
| Success, `--output json` | one JSON line `{"model":...,"text":...,"vendor":"openai"}` (sorted keys, `.withoutEscapingSlashes`, `vendor` = `GatewayVendor.rawValue`) | nothing | 0 |
| `GatewayRPCError` (`-32021`, `-32011`, `-32602`, `-32010`, ...) | nothing | `transcription failed (<code>): <message>` | 1 |
| Any other error (for example the Foundation "no such file" error from `attributesOfItem`) | nothing | `transcription failed: <localizedDescription>` | 1 |
| Flag parse error | nothing | the existing `Unknown argument:` or `Missing or invalid value:` message | 2 |

More details on errors and output:

- `CancellationError` is reported through the "other error" row.
- Vendor HTTP failures keep the library message `vendor HTTP <status>:
  <body prefix>` (code `-32010`), so `insufficient_quota` and
  `rate_limit_exceeded` stay visible.
- The JSON output is a CLI-private `Encodable` struct.
  `GatewayTranscriptionResult` is not made `Codable`.

## Secrets

The CLI never reads, prints, or logs credential values. It passes only the
environment-variable name (`--api-key-environment`) to the library, and
every library error names only the variable. The library puts Gemini keys in
a query item, but the request URL never appears in error messages. The CLI
adds no logging of params or requests.

## Help

`run()` already returns the global usage text whenever `--help` or `-h`
appears, so `agent-gateway transcribe --help` prints the global usage. The
usage text gets:

- the transcribe synopsis line, after the `subscription-usage` line;
- a short paragraph covering:
  - the supported vendors;
  - MIME inference and the `--mime-type` override;
  - the 25 MB limit;
  - `--output text|json`;
  - that credentials are referenced by environment-variable name only;
  - that unsupported vendors give `-32021`.

## Code Placement

- `Sources/AgentGatewayAppCore/Command.swift`:
  - add `"transcribe"` to the `run()` allow-list;
  - add a `case "transcribe"` to `runStreaming()` that parses, runs with
    `ProductionGatewayExecutor()`, and writes stdout and stderr from the
    outcome;
  - update the usage text.

  This keeps the file small, at about 368 lines plus around 15.
- New `Sources/AgentGatewayAppCore/GatewayTranscriptionCommand.swift`, with
  the following members, all internal:
  - the options struct and output-format enum;
  - the parser (an `AppCommand` extension that throws `AppCommand.Error`);
  - the MIME table;
  - `runTranscription(options:transcriber:) async -> outcome`, where
    `outcome` is `{status: Int32, standardOutput: String, standardError:
    String}`.

  The outcome is returned rather than written to the file handles so that
  tests can assert on stdout, stderr, and the exit code.
- `Sources/AgentGatewayAppCore/GatewayTranscription.swift`: two internal
  changes only:
  - extract the `validateGatewayTranscriptionVendor(_:)` helper;
  - add the internal transport seam described under Test Seam
    (`GatewayTranscriptionTransport` and `GatewayTranscriptionPipeline`),
    with `ProductionGatewayExecutor.transcribe(_:)` delegating to it.

  `ProductionGatewayExecutor`'s stored properties, initializers, and public
  signatures do not change, and `GatewayExecution.swift` is not edited.
- `Sources/AgentGatewayCLI/main.swift`: no change.
- `README.md`:
  - add the synopsis line to the Usage section;
  - add a CLI example and the output and exit behavior to `## Audio
    transcription`.
- `design-docs/specs/command.md`: add the synopsis line and a pointer to
  this document.

## Test Seam

The tests stub only the HTTP transport. Everything above it is the
production code path: request construction, credential lookup, file
loading, and response parsing. This needs one small internal change in
`GatewayTranscription.swift`.

- `typealias GatewayTranscriptionTransport = @Sendable (URLRequest, Int)
  async throws -> (Data, URLResponse)`. It is internal. The `Int` argument
  is `timeoutSeconds`. The default implementation,
  `defaultGatewayTranscriptionTransport`, is the current code moved
  unchanged: an ephemeral `URLSessionConfiguration` with the request and
  resource timeouts, `session.data(for:)`, and `invalidateAndCancel` in a
  `defer`.
- `struct GatewayTranscriptionPipeline: GatewayTranscribing` is internal
  and has the fields `environment: [String: String]` and `transport:
  GatewayTranscriptionTransport`. Its `transcribe(_:)` is the current
  `ProductionGatewayExecutor.transcribe` body, in the same order:
  1. `transcriptionAPIKey`, which runs the vendor, protocol, timeout, and
     credential checks;
  2. a cancellation check;
  3. `loadGatewayTranscriptionAudio`;
  4. a cancellation check;
  5. `makeTranscriptionRequest`;
  6. `transport(request, params.timeoutSeconds)`;
  7. a cancellation check;
  8. `parseTranscriptionResponse`.

  The only difference is that step 6 replaces the inline URLSession code.
- `ProductionGatewayExecutor.transcribe(_:)` keeps its public signature and
  becomes a one-line delegate: `GatewayTranscriptionPipeline(environment:
  environment, transport: defaultGatewayTranscriptionTransport)
  .transcribe(params)`. Production behavior, including cancellation and
  timeouts, is unchanged. No public type or initializer is added or
  changed.

The CLI tests pass `GatewayTranscriptionPipeline(environment:
[<fixture key name>: "fixture"], transport: <recording stub>)` as the
`transcriber` argument of `runTranscription(options:transcriber:)`. The
options come from the real `transcribe` flag parser. The recording stub:

- is a Sendable class with a lock;
- stores every `URLRequest` it receives;
- returns canned `(Data, HTTPURLResponse)` values.

The stub is the only way out of the process, because the pipeline never
creates a `URLSession` when a stub is injected. So "no external network
access" is proven by the stub's request count: exactly 1 on success paths
and 0 on paths that must fail early.

The existing tests in `GatewayTranscriptionTests.swift` that call
`ProductionGatewayExecutor` stay unchanged and keep passing. That proves the
delegation preserved the vendor-first, credential, and cancellation
ordering.

## Verification

New `Tests/AgentGatewayAppCoreTests/TranscribeCommandTests.swift`, using
`@testable import AgentGatewayAppCore`, with no network access and no real
keys. Each case below parses real CLI flags with the `transcribe` parser and
calls `runTranscription` with a `GatewayTranscriptionPipeline` that uses a
fixture credential and the recording transport stub. The audio file is a
temporary file (a few bytes, `.mp3`) unless stated otherwise. In every case,
stdout, stderr, and the exit status are asserted.

1. OpenAI text output, through the production path with the transport
   stubbed:
   - flags: `--vendor openai --model whisper-1 --file <tmp>.mp3
     --language ja --prompt Stria --api-key-environment TEST_OPENAI_KEY`;
   - environment: `["TEST_OPENAI_KEY": "fixture-secret"]`;
   - the stub answers HTTP 200 with `{"text":"hello"}`;
   - result: stdout is `"hello\n"`, stderr is empty, the exit code is 0,
     and the stub received exactly 1 request;
   - the request is a `POST` to
     `https://api.openai.com/v1/audio/transcriptions`;
   - its `Content-Type` starts with `multipart/form-data; boundary=`;
   - its `Authorization` header is present;
   - its multipart body contains the `model` field `whisper-1`, the
     `language` field `ja`, the `prompt` field `Stria`, and the part header
     `Content-Type: audio/mpeg`, which shows the MIME type was inferred
     from `.mp3`;
   - `fixture-secret` does not appear in stdout or stderr.
2. OpenAI JSON output: same as case 1 but with `--output json`. Stdout is
   exactly `{"model":"whisper-1","text":"hello","vendor":"openai"}\n`, stderr
   is empty, the exit code is 0, and the stub received 1 request.
3. `--base-url` and `--timeout-seconds` pass-through:
   - `--base-url https://example.invalid/v1` makes the request go to
     `https://example.invalid/v1/audio/transcriptions`;
   - `--timeout-seconds 7` reaches the stub as its timeout argument and
     sets `request.timeoutInterval` to 7.
4. MIME inference:
   - each table extension maps as listed, tested on the pure inference
     function, including uppercase `.WAV`;
   - an explicit `--mime-type audio/wav` on an `.mp3` file overrides the
     extension, so the multipart part header is `audio/wav`;
   - an unknown extension (`.xyz`) with no `--mime-type` gives exit 1,
     stderr containing `-32602` and `--mime-type`, and 0 stub requests.
5. Unsupported vendors (`anthropic`, `cursor`, `claude-code`):
   - the file is a nonexistent path with an unknown extension;
   - the result is exit 1 with `transcription failed (-32021)` on stderr,
     empty stdout, and 0 stub requests;
   - this shows the CLI checked the vendor before MIME inference, file
     I/O, and the transport.
6. Missing file: exit 1, stderr starting with `transcription failed`, and 0
   stub requests.
7. Oversized file:
   - a sparse temp file of 25,000,001 bytes, created by truncating, with an
     `.mp3` extension;
   - the result is exit 1 with `-32602` and `25 MB` on stderr, and 0 stub
     requests.
8. HTTP failure:
   - the stub answers HTTP 429, once with the body
     `{"error":{"code":"insufficient_quota"}}` and once with the body
     `{"error":{"code":"rate_limit_exceeded"}}`;
   - in both cases the exit code is 1, stdout is empty, and stderr contains
     `transcription failed (-32010)`, `vendor HTTP 429`, and the matching
     error code string.
9. Missing credential, with an empty environment: exit 1, stderr contains
   `-32011` and the variable name, and 0 stub requests.
10. Parsing:
   - a missing `--vendor`, `--model`, or `--file` throws `missingValue`;
   - `--output yaml` and `--timeout-seconds abc` throw `missingValue`;
   - an unknown flag throws `unknownArgument`;
   - `AppCommand(arguments: ["transcribe", ...]).run()` returns `""`;
   - the usage text contains `agent-gateway transcribe`.

Commands:

- `mise run build`
- `mise run test`
- `mise run lint`
- `swift test --filter TranscribeCommandTests`
- `swift test --filter GatewayTranscription`, which runs the existing
  library tests unchanged
- `swift run agent-gateway --help`, whose output must list `transcribe`
- the optional live smoke test with a real key, which is not required:
  `swift run agent-gateway transcribe --vendor openai --model whisper-1
  --file <audio>`

## Rollout Constraints

- No public library API changes. The vendor helper, the transport typealias,
  the default transport, and `GatewayTranscriptionPipeline` are all
  internal.
- `ProductionGatewayExecutor` gets no new stored properties or
  initializers. Its production transcription behavior stays the same:
  - a URLSession per call with the request and resource timeouts;
  - task cancellation;
  - the vendor-first, then credential, then file, then network order.
- The existing `GatewayTranscriptionTests.swift` must pass unchanged.
- Swift files stay under 1000 lines, and `swiftlint` must pass.
- Commits go on the `feat/transcribe-cli` branch only.
