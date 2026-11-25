# Agent Gateway ACP stdio protocol

Status: implemented for ACP protocol versions 1 and 2. Supersedes the former
custom `agent/execute` JSONL protocol (`jsonl-stdio-protocol.md`, removed).

Reference: [Agent Client Protocol](https://agentclientprotocol.com), schema
`agentclientprotocol/agent-client-protocol` at commit `d3ac0e6` (v1 schema
1.35.0, v2 schema 2.0.0-beta.4; v2 is in Preview upstream). The v2 work
follows the upstream
[migration guide](https://agentclientprotocol.com/protocol/v2/migration).

## Scope and layering

`agent-gateway server` speaks ACP over stdio: JSON-RPC 2.0 messages, one JSON
object per line. stdout is reserved for protocol messages; human diagnostics
use stderr.

Everything is implemented in Swift in this package. There is no dependency
on an external ACP adapter or SDK:

| Layer | Target | Role |
| --- | --- | --- |
| Wire protocol | `ACP` | JSON-RPC peer (`ACPConnection`), transports, v1 types (`ACP…`), v2 types (`ACPV2…`), dual-stack server (`ACPAgentServer`), client (`ACPClientConnection`) |
| Vendor adapter | `AgentGatewayAppCore` | `GatewayACPAgent`: maps ACP sessions and prompts onto vendor CLIs and HTTP APIs |
| CLI | `AgentGatewayCLI` | `server` and `client` commands |

The upstream guidance for supporting both versions is "share application
logic, not wire shapes": `GatewayACPAgent` conforms to `ACPAgent` (v1) and
`ACPV2Agent` (v2) over one session table and one execution path, and the two
conformances own their version's capabilities, validation, and lifecycle. The
v1 and v2 wire types are separate Swift types and are never converted into
each other.

## Version negotiation

One connection speaks exactly one version after `initialize`.

- The server reads `protocolVersion` before any other parameter. Missing,
  non-integer, or out-of-range (0 to 65535) values get `-32602`.
- It selects the highest served version at or below the requested one:
  a request for 1 selects v1, for 2 selects v2, for a newer version selects
  v2 and ignores parameters that do not parse as v2.
- When no served version qualifies (for example `--acp-versions 2` and a v1
  client) it answers `-32022` with `data: {"requested": 1, "supported": [2]}`
  and the connection stays uninitialized.
- The response uses the selected version's shape (`agentCapabilities` and
  `agentInfo` for v1, `capabilities` and `info` for v2).
- Requests other than `initialize` before initialization get `-32600` and
  notifications are ignored. `initialize` may repeat until the first other
  request (the latest success wins) and gets `-32600` afterwards.

`server --acp-versions <1|2|1,2>` restricts the served versions; the default
is both. `ACPClientConnection.negotiate(_:)` requests v2 and continues with
whichever version the agent selected.

## Envelope rules

Applied in both versions:

- Request ids are a string or an integer. A message with a `method` and
  `id: null` is rejected with `-32600` and `id: null`, not treated as a
  notification.
- JSON-RPC batches (arrays) are rejected with one `-32600`, `id: null`.
- `$/cancel_request` cancels the request with that id. The request still
  gets exactly one response; unknown and already answered ids are ignored.
- Unknown methods, including `_`-prefixed extension methods and methods of
  the other protocol version, get `-32601`.

## Capabilities

| | v1 (`agentCapabilities`) | v2 (`capabilities.session`) |
| --- | --- | --- |
| Images in prompts | `promptCapabilities.image: true` | `prompt.image: {}` |
| Embedded text resources | `promptCapabilities.embeddedContext: true` | `prompt.embeddedContext: {}` |
| Audio in prompts | not supported | not advertised |
| History replay | `loadSession: true` | baseline (`session/resume` with `replayFrom`) |
| List, resume, close | `sessionCapabilities.list/resume/close` | baseline |
| Delete | `sessionCapabilities.delete` | `delete: {}` |
| `systemPrompt` (`append` mode) | `sessionCapabilities.systemPrompt` | `systemPrompt: {}` |
| Stdio MCP servers | supported for claude-code and codex | `mcp.stdio: {}` when the server's vendor is claude-code or codex |
| HTTP / SSE MCP servers | not advertised; rejected with `-32602` | not advertised; rejected with `-32602` |
| Authentication | none (`authMethods: []`) | none (`authMethods` omitted) |

### MCP servers

The gateway does not run an MCP client. It hands a session's stdio MCP
servers to the vendor CLI, which connects to them itself:

| Vendor | How servers are passed |
| --- | --- |
| claude-code | `--mcp-config <json>` with one `mcpServers` entry per server |
| codex | `-c mcp_servers.<name>.command=…`, `.args=…`, `.env=…` overrides; the name is reduced to a TOML bare key |
| cursor, cursor-api, openai, anthropic, gemini, openrouter | cannot connect: API vendors run no tool loop, and cursor-agent reads MCP servers only from its own configuration files |

The servers of the latest `session/new`, `session/load`, or `session/resume`
are the complete set for the session; earlier ones are not restored.

- v2 advertises `mcp.stdio` only when the vendor fixed with `server
  --vendor` can connect. Otherwise no transport is advertised and any
  server is rejected with `-32602`, as is a server for a session whose
  `_meta` selects a vendor that cannot connect. A relative `command` and a
  duplicate `name` are rejected with `-32602`.
- v1 requires every agent to support stdio servers and has no capability to
  decline them. Sessions on claude-code and codex connect to them. Sessions
  on the other vendors accept the field and leave the servers unused; this
  is a known deviation for those vendors.

## Sessions

`session/new` requires an absolute `cwd` (`-32602` otherwise) and a
configured vendor and model. Sessions and their retained history live in the
server process; there is no on-disk session store, so a session can be
listed, closed, and resumed for as long as that process runs.

- `session/list` returns every session the process holds, most recently
  active first, 50 per page. `cwd` filters by exact directory (a trailing
  separator is ignored); an unknown `cursor` gets `-32602`.
- `session/close` cancels ongoing work, ends the session on the connection,
  and keeps it listed and resumable. Closing an unknown or already closed
  session succeeds.
- `session/delete` closes the session and discards it. Deleting an unknown
  session succeeds.
- A session-scoped request for a session that does not exist or is not
  active gets `-32002` with `data.sessionId`.
- Resuming requires the session's `cwd`; a different directory gets `-32602`.
- Titles are derived from the first line of the first prompt.

History replay reports retained user, thought, and agent messages:

- v1 `session/load` replays them as `user_message_chunk`,
  `agent_thought_chunk`, and `agent_message_chunk` before responding;
  `session/resume` reattaches without replay.
- v2 `session/resume` with `replayFrom: {"type": "start"}` replays them as
  whole-message upserts (`user_message`, `agent_thought`, `agent_message`),
  then `replay_complete`. Retained user messages keep the `messageId` their
  prompt response returned. Work still running is cut at the resume: what
  has streamed so far is replayed as the message's current content, and
  later chunks append to the same `messageId`. Without `replayFrom` nothing
  is replayed and no `replay_complete` is sent. Every successful resume is
  preceded by a current `state_update` snapshot (without a stop reason) and
  a `session_info_update`. An unsupported `replayFrom` type gets `-32602`.

## Prompt lifecycle

Prompt content: `text` and `resource_link` (the baseline), `image`, and
text `resource` blocks. Audio, binary resources, unknown block types, and an
empty prompt are rejected with `-32602` before anything is inserted.

### v1

`session/prompt` stays pending for the turn. Output streams as
`session/update` notifications and the response carries the stop reason:
`end_turn`, or `cancelled` after `session/cancel` or `$/cancel_request`. A
vendor failure is an error response. A second prompt while one is in flight
is rejected with `-32600`.

### v2

```
client                                agent
  | session/prompt (id=3)  ------------> |
  | <-- session/update user_message      |   inserted message, same messageId
  | <-- session/update state_update      |   running
  | <-- result {messageId} (id=3)        |   acknowledges insertion only
  | <-- session/update agent_message_chunk ...
  | <-- session/update state_update      |   idle + stopReason (+ error)
```

- The response returns the `messageId` of the inserted user message as soon
  as it is inserted. It does not end the turn.
- The inserted message is reported as a `user_message` update with the
  same `messageId` and the prompt's content.
- Foreground work is bracketed by `state_update` `running` and `idle`. The
  idle update carries the stop reason: `end_turn`, `cancelled`, or `error`
  with the JSON-RPC error object in `error`. An error response to
  `session/prompt` always means the message was not inserted.
- All chunks of one message share a `messageId`; thoughts and the agent
  message of a turn have separate ids. A result the vendor did not stream is
  reported as one `agent_message` upsert.
- Prompts sent while work is active are not rejected: they are held and
  inserted, in arrival order, after the running work has reported `idle`.
  Their responses stay pending until then, so two turns always have an idle
  boundary between them.
- `idempotencyKey` (1 to 255 characters, `-32602` otherwise): a retry with
  a key recorded for an inserted message returns the original `messageId`
  without a second insertion or a second run; a retry of a prompt still held
  shares that prompt's outcome. Keys are scoped to the session and kept with
  its history.
- `session/cancel` stops foreground work and answers prompts received
  before it that are not inserted yet with `-32800`. The stopped work ends
  with `idle` and `stopReason: "cancelled"`; cancelling an idle session
  sends nothing. `session/close` does the same and responds only after that
  idle update has been sent.
- `$/cancel_request` for a held prompt withdraws it (`-32800`); for an
  inserted prompt it has no effect, since the response already carried the
  `messageId`.

Ordering: prompts and `session/cancel` are admitted on the connection's read
loop in arrival order, and every update of a session is written
synchronously from the agent actor, so the wire order of a session's updates
is the order the agent produced them. A resume replay is sent without
suspension, so no live update can precede `replay_complete`.

## Token streaming

Every vendor token stream is represented as `session/update` notifications:

- Streaming vendors (OpenAI, Anthropic, Gemini, OpenRouter SSE; cursor-agent
  deltas) map each text delta to one `agent_message_chunk`. Claude Code runs
  with `--include-partial-messages`, so its `stream_event` text deltas also
  arrive token-by-token instead of per completed message.
- Snapshot vendors (Codex `agent_message` items, Cursor Cloud Agents) emit
  whole-message chunks; growing snapshots emit only the suffix delta, and a
  trailing echo of already-streamed text (e.g. Claude Code's completed
  assistant message and `result` events) is suppressed so text is never
  duplicated.
- Reasoning output maps to `agent_thought_chunk`: Claude Code / Anthropic
  `thinking_delta`, OpenAI `response.reasoning_summary_text.delta`,
  OpenRouter `delta.reasoning`, and Codex `reasoning` items.

```json
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-1","update":{"sessionUpdate":"agent_message_chunk","messageId":"msg-1","content":{"type":"text","text":"Hel"}}}}
```

(`messageId` is present on v2 connections only.)

## Tool calls, plans, and usage

CLI vendors report more than text. The gateway reads tool work, todo lists,
and context usage from the vendor's own output stream and forwards it as
ACP updates, in the order the vendor produced it relative to message and
thought chunks. API vendors (openai, anthropic, gemini, openrouter,
cursor-api) run no tools through the gateway and report none of this.

Only what a vendor line actually contains is forwarded; nothing is
synthesized beyond the fallbacks noted below.

| Vendor | Source lines | Updates |
| --- | --- | --- |
| claude-code | `stream_event` `content_block_start` (tool announced), `assistant` `tool_use` (input complete), `user` `tool_result` | tool call: `pending`, then `in_progress` with `rawInput`, title, and location, then `completed`/`failed` (`is_error`) with `rawOutput` and text content |
| claude-code | `assistant` `tool_use` named `TodoWrite` | plan (entry `content` and `status`) |
| claude-code | `message_start`/`message_delta` usage, `result` `modelUsage` and `total_cost_usd` | `usage_update` |
| codex | `item.started`/`item.updated`/`item.completed` of type `command_execution`, `file_change`, `mcp_tool_call`, `web_search` | tool call: `in_progress`, then `completed`/`failed` |
| codex | items of type `todo_list` | plan (entry `content`, done or not done) |
| cursor | `tool_call` lines, `subtype` `started`/`completed` | tool call: `in_progress`, then `completed`/`failed` |

Field mapping:

- `toolCallId` is `t<turn>-<vendor id>`. Vendors keep ids unique within one
  execution only (codex numbers items from zero on every run) and each turn
  is a new execution, so the turn number scopes them to the session.
- `name` is the vendor's tool name (`Bash`, the codex item type, the MCP
  tool, the cursor tool key). `title` is the command for shell tools, the
  tool name plus its main argument for file, search, and fetch tools, and
  the bare name otherwise. `kind` is derived from the tool name.
- `rawInput` and `rawOutput` are the vendor's JSON: Claude Code's tool
  `input` and structured `tool_use_result` (the `tool_result` content when
  a message carries several results); codex `command` and
  `aggregated_output`/`exit_code`, `changes`, MCP `arguments` and
  `result`/`error`; cursor `args` and `result`.
- `content` is the textual output as one text block. On v2, codex
  `file_change` items also carry a `diff` content item listing each
  absolute path with its operation; v1 diffs need file text the vendors do
  not report, so v1 has `locations` and `rawInput` only.
- `locations` are reported only for absolute paths.
- Plan entries have no vendor priority; ACP requires one, so every entry is
  `medium`. Codex todos are `completed` or `pending`. On v2 the `planId` is
  the scoped codex item id, or `plan` for Claude Code's single list.
- `usage_update` needs both `used` and `size`, so it is sent only when the
  vendor reports a context window: Claude Code, at the end of the turn.
  `used` is the token count of the main model's latest call (input, cache
  read, cache write, and output), `size` is that model's `contextWindow`,
  and `cost` is the session's cumulative `total_cost_usd`. The gateway's
  `_meta` object carries the turn's `inputTokens`, `outputTokens`, and
  `totalTokens`. Codex and cursor report no context window, so they send no
  `usage_update`; their token counts remain in the turn result (see Vendor
  selection via `_meta`).

Rules that hold on both versions:

- v1 sends `tool_call` for the first report of an id and `tool_call_update`
  with only the changed fields afterwards; v2 sends `tool_call_update`
  upserts the same way. A repeated vendor report sends nothing, a status
  never moves backwards, and nothing follows a final status.
- A call first seen already finished (codex `file_change`) is created with
  its final status.
- Every way a turn ends settles the tool calls still open, before the v1
  prompt response or the v2 idle `state_update`: `completed` when the
  vendor execution succeeded, `failed` when it failed or was cancelled.
- On v1, `usage_update` and the tool-call `name` field are part of schema
  1.35.0; the `ACP` library models `name` and passes `usage_update` through
  as an unmodeled update.

History replay (`session/load`, `session/resume` with `replayFrom`) covers
messages only; tool calls, plans, and usage are live updates.

## Model selection

For API vendors the session setup response includes a `model` config option
(`configOptions`, category `model`, type `select`): the options are the
vendor's model list and the current value is the session's model. The fetch
is best-effort: a failure or a response slower than 3 seconds omits the
option rather than failing session creation, and successful lists are cached
per vendor/baseURL/credential. `session/set_config_option` switches the
model for subsequent prompts and returns the complete option list; in v2 a
change also sends `config_option_update`. An unknown `configId`, a value
outside the list, or a non-id value type gets `-32602`.

The key names follow the version: `id` in v1, `configId` in v2, and v2
requests carry `type: "id"`.

CLI vendors (claude-code, codex, cursor) have no machine-readable
enumeration: their sessions advertise no config option, and the
`agent-gateway models` subcommand rejects them with error `-32020`.

The legacy `session/set_model` request is still accepted on v1 connections
and takes any pass-through model id. The root-level `models` response field
that used to accompany it is no longer sent, because it is not part of the
ACP schema.

## Vendor selection via `_meta`

ACP has no standard slot for vendor/model, so the gateway uses the spec's
`_meta` extension point. Defaults come from `server` CLI flags; an ACP
client may override per session in `session/new`:

```json
{"_meta":{"agentGateway":{"vendor":"claude-code","model":"claude-sonnet-5","vendorSessionId":"..."}}}
```

The extension key depends on the version, because ACP v2 reserves unprefixed
`_meta` keys for the protocol and asks extensions for a reverse-DNS prefix:

| | Key written by the gateway |
| --- | --- |
| v1 | `agentGateway` |
| v2 | `io.github.tacogips/agentGateway` |

Requests are read under either key on both versions (`gatewayACPMeta(_:)`
does the same for hosts reading results).

Supported request keys: `vendor`, `model`, `systemPrompt`, `executable`,
`arguments`, `providerName`, `apiKeyEnvironment`, `baseURL`, `maxTokens`,
`vendorSessionId` (resume a vendor-owned session). Credentials remain
referenced only by environment-variable name.

Results carry `vendor`, `model`, `usage` (token counts when the vendor
reports them; partial reports such as Anthropic's split input/output counts
are merged, and CLI vendors report through their `result`/`turn.completed`
events), `vendorSessionId` for resumption, and `resultText`, the vendor's
authoritative final text. Streamed chunks may span multiple assistant
messages, so hosts that need exactly the vendor's final result (e.g.
output-contract parsing) should prefer `resultText` over concatenating
chunks. In v1 the object is on the `session/prompt` response; in v2 it is on
the idle `state_update`. Within one ACP session, consecutive prompts
automatically reuse the vendor session
(`--resume`/`exec resume`/`previous_response_id`).

The standard `systemPrompt` parameter (`append` mode, text blocks) is
supported on session setup in both versions. Its text is appended to the
configured system prompt. Other modes and non-text blocks get `-32602` and
no session is created.

## Errors

| Code | Meaning |
| --- | --- |
| `-32700` | Parse error |
| `-32600` | Invalid request; request before `initialize`; late `initialize`; batch; `id: null` |
| `-32601` | Method not found or not advertised |
| `-32602` | Invalid params |
| `-32002` | Session not found or not active (`data.sessionId`) |
| `-32022` | Unsupported protocol version (`data.requested`, `data.supported`) |
| `-32800` | Request cancelled |
| `-32010` | Vendor HTTP failure |
| `-32011` | Missing credential environment variable |
| `-32012` | Vendor CLI process failure |

Vendor process failures used code `-32002` before ACP v2 support was added.
They moved to `-32012`, because ACP defines `-32002` as "Resource not found"
and clients act on it as a missing session. Messages are bounded and
credential-redacted.

Known deviation: the vendor codes above sit inside the range ACP reserves
(`-32768` to `-32000`); the spec recommends implementation-specific codes
outside it. They are kept for compatibility with existing hosts.

## Client command

`agent-gateway client` is an ACP client. By default it spawns
`agent-gateway server` with matching defaults; `--agent <path>` drives any
external ACP agent instead. It performs `initialize` → `session/new` →
`session/prompt` and echoes the agent's raw ACP JSONL messages to stdout:

```bash
agent-gateway client \
  --vendor openrouter \
  --model openai/gpt-5 \
  --prompt 'Reply with exactly OK' \
  --api-key-environment OPENROUTER_API_KEY
```

It requests ACP v1 by default. `--acp-version 2` requests v2 and waits for
the idle `state_update` instead of the prompt response; if the agent selects
v1 the client continues with the v1 lifecycle. Exit code is `0` when the
turn ends with `end_turn` in either version. `--prompt -` reads the prompt
text from stdin (recommended for large prompts); repeatable `--image <path>`
and `--image-data <mimeType>:<base64>` become ACP image content blocks in the
prompt.

The client answers `session/request_permission`, the one request every ACP
client must handle in both versions. It is non-interactive, so the answer is
a policy set with `--permission`: `cancel` (default) declines with the
`cancelled` outcome, `allow` selects the first `allow_once` (else
`allow_always`) option, and `reject` the first `reject_once` (else
`reject_always`) option. An option the agent did not offer is never
selected. Other agent requests get `-32601`; the client advertises no
file-system, terminal, or elicitation capability. Library hosts get the same
behavior from `GatewayClientPermissionResponder`.

## Conformance

`scripts/acp-tck.sh` runs the upstream
[ACP Test Compatibility Kit](https://github.com/agentclientprotocol/acp-tck)
(pinned to a commit) against `agent-gateway server`. Two deterministic fake
vendors under `scripts/acp-tck/` stand in for a real one: a `claude` stream-json
CLI and a loopback OpenRouter API, the latter so the model config option is
exercised.

```bash
scripts/acp-tck.sh --protocol-version 1
scripts/acp-tck.sh --protocol-version 2
scripts/acp-tck.sh --protocol-version 2 --vendor-mode api
```

Results on 2026-11-25 (TCK `7c71c4d`), all `VERDICT: CONFORMANT`:

| Run | MANDATORY | CAPABILITY | ADVISORY |
| --- | --- | --- | --- |
| v1, CLI vendor | 39 pass | 15 pass | 21 pass |
| v1, API vendor | 36 pass, 3 skipped | 16 pass | 21 pass, 1 fail |
| v2, CLI vendor | 30 pass, 4 skipped | 73 pass | 32 pass |
| v2, API vendor | 30 pass, 4 skipped | 82 pass | 32 pass |

No MANDATORY or CAPABILITY requirement fails. Skipped rows are requirements
the gateway gives the TCK nothing to judge: it advertises no auth methods
and sends no requests to the client (v2), and the API fake answers a cancel
too quickly for the v1 cancellation rows to count (they pass in the CLI run).
The remaining CAPABILITY skips are features the gateway did not offer when
these runs were recorded: tool calls, terminals, plans, permission requests,
subagents, slash commands. The fakes report tool calls and a plan only for a
prompt containing `TOOLS`, which the TCK does not send, so the table is
unchanged by tool-call reporting and those rows remain unjudged.

The CLI fake implements `--mcp-config` the way the real CLI does (it
launches each server and performs the MCP `initialize` handshake), so the
MCP rows judge the gateway's pass-through end to end. With the API fake
vendor, which cannot connect to MCP servers, v1 `ACP-SESSION-004` (the agent
should connect to the servers a client supplies) fails as an advisory row;
see MCP servers above.

`scripts/acp-schema-check.sh` covers the schema revision this implementation
targets, which is newer than the one the TCK vendors. It drives the server
through v1 and v2 flows with both fake vendors (setup, config options,
prompt turns, tool calls with a plan and usage, list, close, replay, a
cancel with a tool call in flight, delete, and error paths) and
validates every request, response, error, and notification against the
stable `schema/v1/schema.json` and `schema/v2/schema.json` at `d3ac0e6`:
130 v1 and 159 v2 payloads, no schema violations. With the CLI fake it also
requires every activity kind to appear and every reported tool call to end
`completed` or `failed`. The CLI client's own
requests and its permission response were validated the same way while it
drove the reference agent below.

The TCK judges agents only. The client side is checked against the upstream
TypeScript SDK's dual-version reference agent
(`src/examples/dual-version-agent.ts`, SDK 2.12.0): `agent-gateway client
--agent <reference>` completes a turn with `--acp-version 1` and with
`--acp-version 2`, including the reference agent's permission request under
both the `cancel` and `allow` policies. In the other direction, the same
SDK's typed v1 and v2 clients drive `agent-gateway server` through
initialize, session/new, a prompt turn, session/list, and (v2) an
idempotent retry, close, and resume with replay.

The TCK is experimental and tracks a v2 schema slightly older than the one
this implementation targets, so a passing run is evidence, not an official
statement of conformance.

## Not implemented

- MCP servers for vendors other than claude-code and codex, and the HTTP
  MCP transport.
- Terminal reporting and `session/request_permission`: vendor CLIs run with
  their own tool handling. The `ACP` library models these for clients that
  talk to other agents.
- Authentication methods, subagents, slash commands, elicitation.
- Session persistence across server processes.

## Follow-ups for activity reporting

Not done, with what is known about each:

- `session/request_permission` from vendor approval prompts. The gateway
  starts vendors in their non-interactive modes (`claude -p`, `codex exec`,
  `cursor-agent --print`), which never ask: they decide from their own
  configuration and report the outcome (Claude Code attaches a
  `permission_decision` to each tool result and lists refusals in the
  result's `permission_denials`). Asking the client needs a two-way channel
  to the vendor: Claude Code's stream-json control protocol
  (`--input-format stream-json`, which `GatewaySubscriptionUsageReader`
  already speaks for another request) can route `can_use_tool` requests;
  `codex exec` has no such channel, so codex needs its app-server protocol
  instead. `GatewayExecuting` only has an outbound event emitter today, so
  this is an executor interface change, not a parser change. The client
  side of the request exists.
- Rate-limit reporting. Claude Code prints `rate_limit_event` lines
  (`status`, `rateLimitType`, `utilization`, `resetsAt`) that are currently
  relayed only as raw vendor events; they map naturally to a v2 `notice`.
  Failures keep their existing codes: a vendor process failure is `-32012`
  and an API vendor HTTP failure `-32010` after retries, with the vendor's
  text as the message. A distinct rate-limit code needs per-vendor
  detection of that text or status (HTTP 429 for API vendors).
- Models and modes at `session/new`. Models are already advertised as the
  `model` config option when the vendor can list them. A CLI's permission
  mode, tools, and slash commands appear only in its `system` `init` line,
  after an execution has started, so they could be reported after the first
  turn (`available_commands_update`, a `mode` config option) but not in the
  `session/new` response without a probe run.
- Replay of tool calls and plans in history, and tool calls in flight when
  a v2 client resumes mid-turn (it then sees updates for a call it never
  saw created).
- v2 `cancelled` status for calls open at a cancel; both versions report
  `failed`, the only non-success final status v1 has.
- Claude Code `Edit`/`Write` as v1 `diff` content (the input has the old
  and new text), the newer `TaskCreate`/`TaskUpdate` tools as a plan (they
  report one task at a time, never the list), and linking a subagent's tool
  calls to the call that spawned it (`parent_tool_use_id`).
- `usage_update` for codex and cursor, which needs a context window size
  from somewhere other than their output stream.
- Verification of the cursor mapping against a signed-in `cursor-agent`; it
  follows the documented `stream-json` format and was not run live. The
  Claude Code and codex mappings were checked against captured output of
  Claude Code 2.1.318 and codex-cli 0.172.0, except `TodoWrite` and codex
  `todo_list`/`file_change`/`mcp_tool_call`/`web_search`, which those runs
  did not produce.
