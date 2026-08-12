# Agent Gateway JSONL stdio protocol

Status: implemented as protocol version 1.0.

## Transport and framing

`agent-gateway server` is a long-lived stdio server. It reads UTF-8 requests
from stdin and writes UTF-8 responses to stdout. Every message is exactly one
JSON object followed by LF. Embedded newlines are JSON escaped. stdout is
reserved for protocol messages; human diagnostics use stderr.

The envelope follows JSON-RPC 2.0 naming and request correlation, while JSONL
provides deterministic streaming framing instead of LSP's `Content-Length`
headers. Version 1.0 processes requests in input order. A client must continue
reading until it receives a terminal response with the matching `id`.

## Execute request

```json
{"jsonrpc":"2.0","id":"step-1","method":"agent/execute","params":{"protocolVersion":"1.0","vendor":"openrouter","model":"openai/gpt-5","prompt":"Hello"}}
```

`vendor` is required and is never inferred from `model`. Supported values are
`claude-code`, `codex`, `cursor`, `openai`, `anthropic`, `gemini`, and
`openrouter`. Optional parameters include `systemPrompt`, `workingDirectory`,
`executable`, `arguments`, `providerName`, `apiKeyEnvironment`, `baseURL`, and
`maxTokens`.

Credentials are referenced only by environment-variable name. The request may
contain the provider name and Base URL but must never contain a credential
value. The server resolves the value from its process environment.

## Streaming event

The server emits zero or more notifications before the terminal response:

```json
{"jsonrpc":"2.0","method":"agent/event","params":{"requestId":"step-1","sequence":1,"vendor":"openrouter","type":"assistant.delta","channel":"assistant","textDelta":"Hel"}}
```

`sequence` starts at one per request and is strictly increasing. Channels are
`lifecycle`, `assistant`, `thinking`, `tool`, `usage`, and `vendor`.
`vendorPayload` may carry the original vendor JSON line as an escaped string;
this preserves evidence without allowing nested vendor objects to redefine the
gateway envelope.

## Terminal response and errors

Success contains one `GatewayExecuteResult`:

```json
{"jsonrpc":"2.0","id":"step-1","result":{"protocolVersion":"1.0","vendor":"openrouter","model":"openai/gpt-5","text":"Hello"}}
```

Failure contains `error.code` and a bounded `error.message`. Parse errors use
`-32700`, unknown methods use `-32601`, invalid parameters use `-32602`, and
vendor/process failures use the reserved server-error range beginning at
`-32000`. A request has exactly one terminal success or error response.

## Client command

`agent-gateway client` starts an `agent-gateway server` subprocess, sends one
request, and forwards the server's JSONL stdout without reformatting it:

```bash
agent-gateway client \
  --vendor openrouter \
  --model openai/gpt-5 \
  --prompt 'Reply with exactly OK' \
  --api-key-environment OPENROUTER_API_KEY
```

Programmatic clients should normally keep one server process alive and write
requests directly. Riela uses this mode and converts `agent/event`
notifications into its existing backend-event stream.
