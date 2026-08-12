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
  deltas) map each text delta to one `agent_message_chunk`.
- Snapshot vendors (Claude Code assistant messages, Codex `agent_message`
  items, Cursor Cloud Agents) emit whole-message chunks; growing snapshots
  emit only the suffix delta, and a trailing result echo of already-streamed
  text is suppressed so text is never duplicated.
- Reasoning output maps to `agent_thought_chunk`.

```json
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess-1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hel"}}}}
```

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
`usage` (token counts when the vendor reports them), and `vendorSessionId`
for resumption. Within one ACP session, consecutive prompts automatically
reuse the vendor session (`--resume`/`exec resume`/`previous_response_id`).

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

Exit code is `0` when the turn ends with `end_turn`.
