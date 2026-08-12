# Agent Gateway ACP stdio protocol

Status: implemented. Supersedes the former custom `agent/execute` JSONL
protocol (`jsonl-stdio-protocol.md`, removed).

## Protocol

`agent-gateway server` speaks the [Agent Client Protocol](https://agentclientprotocol.com)
(ACP) protocol version 1 over stdio: JSON-RPC 2.0 messages, one JSON object
per line (newline-delimited). stdout is reserved for protocol messages; human
diagnostics use stderr. The generic protocol implementation lives in the
reusable `ACP` library target (client, agent server, transports), modeled
after `zed-industries/agent-client-protocol` and `wiedymi/swift-acp`.

Flow:

1. `initialize` — version and capability negotiation. The gateway advertises
   `promptCapabilities: {image: true, embeddedContext: true}` and
   `agentInfo: {name: "agent-gateway"}`.
2. `session/new` — requires an absolute `cwd` and `mcpServers` (accepted and
   currently ignored). Returns a gateway `sessionId`.
3. `session/prompt` — one prompt turn. Streaming output is delivered as
   `session/update` notifications before the response returns
   `{"stopReason": "end_turn"}`.
4. `session/cancel` — notification; the running vendor execution is terminated
   and the pending `session/prompt` responds with `{"stopReason": "cancelled"}`.

## Token streaming

Every vendor token stream is represented as a JSONL stream of ACP
`session/update` notifications:

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
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hel"}}}}
```

## Model advertisement and selection

For API vendors, the `session/new` response includes the spec's `models`
slot (`SessionModelState`): `availableModels` fetched from the vendor's
model-listing endpoint and `currentModelId`. The fetch is best-effort — a
failure or a response slower than 3 seconds omits the field rather than
failing session creation — and successful lists are cached per
vendor/baseURL/credential. `session/set_model` switches the session's model
for subsequent prompts; model ids are pass-through vendor strings, so ids
outside the advertised list are accepted and validated by the vendor at
prompt time. CLI vendors (claude-code, codex, cursor) have no
machine-readable enumeration: their sessions omit `models`, and the
`agent-gateway models` subcommand rejects them with error `-32020`.

## Vendor selection via `_meta`

ACP has no standard slot for vendor/model, so the gateway uses the spec's
`_meta` extension point under the `agentGateway` key. Defaults come from
`server` CLI flags; an ACP client may override per session in `session/new`:

```json
{"_meta":{"agentGateway":{"vendor":"claude-code","model":"claude-sonnet-5","vendorSessionId":"..."}}}
```

Supported keys: `vendor`, `model`, `systemPrompt`, `executable`, `arguments`,
`providerName`, `apiKeyEnvironment`, `baseURL`, `maxTokens`,
`vendorSessionId` (resume a vendor-owned session). Credentials remain
referenced only by environment-variable name.

The `session/prompt` response `_meta.agentGateway` carries `vendor`, `model`,
`usage` (token counts when the vendor reports them; partial reports such as
Anthropic's split input/output counts are merged, and CLI vendors report
through their `result`/`turn.completed` events), and `vendorSessionId` for
resumption. Within one ACP session, consecutive prompts automatically reuse
the vendor session (`--resume`/`exec resume`/`previous_response_id`).

## Errors

Standard JSON-RPC codes: `-32700` parse error, `-32601` method not found,
`-32602` invalid params. Vendor/process failures surface in the server error
range starting at `-32000` with bounded, credential-redacted messages.

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

Exit code is `0` when the turn ends with `end_turn`. `--prompt -` reads the
prompt text from stdin (recommended for large prompts); repeatable
`--image <path>` and `--image-data <mimeType>:<base64>` become ACP image
content blocks in the prompt.

The `session/prompt` response `_meta.agentGateway` also carries `resultText`,
the vendor's authoritative final text. Streamed chunks may span multiple
assistant messages, so hosts that need exactly the vendor's final result
(e.g. output-contract parsing) should prefer `resultText` over concatenating
chunks.
