# ACP v1 and v2 dual-stack support

Design: `design-docs/specs/acp-stdio-protocol.md`.

Status: completed.

## Goal

Serve ACP protocol versions 1 and 2 from `agent-gateway server`, make the
`ACP` library and the `client` command speak both, and keep everything in
Swift in this package (no external ACP adapter).

## Work done

1. JSON-RPC layer (`Sources/ACP/ACPJSONRPC.swift`, `ACPConnection.swift`):
   envelope rules (no `id: null`, no batches), `$/cancel_request` in both
   directions, arrival-ordered request admission, synchronous ordered
   notification writes, ACP error codes (`-32002`, `-32022`, `-32800`).
2. v2 wire types (`ACPV2Types.swift`, `ACPV2SessionUpdate.swift`,
   `ACPV2ToolCalls.swift`, `ACPPatch.swift`, `ACPSessionManagement.swift`):
   capabilities as object markers, session lifecycle, upsert updates with
   three-state patch fields, open enums with raw-JSON fallbacks, config
   options with version-specific key names.
3. Dual-stack server (`ACPAgentServer.swift`): `ACPV2Agent` protocol next to
   `ACPAgent`, version negotiation, initialization gating, per-version
   dispatch.
4. Client (`ACPClient.swift`, `ACPV2Client.swift`): `negotiate` with v1
   fallback, v2 session methods, `promptTurn` / `promptTurnCollecting`.
5. Gateway agent (`GatewayACPAgent.swift`, `GatewayACPAgent+V2.swift`,
   `GatewayACPSession.swift`): shared session table with retained history;
   v2 prompt lifecycle (insertion acknowledgment, `state_update`, held
   prompts, idempotency keys, cancel and close ordering, resume replay);
   v1 additions (`session/list`, `resume`, `load`, `close`, `delete`,
   `set_config_option`, `systemPrompt`).
6. CLI (`Command.swift`, `GatewayACPClientRunner.swift`):
   `server --acp-versions`, `client --acp-version`.
7. Conformance tooling: `scripts/acp-tck.sh` with fake vendors under
   `scripts/acp-tck/`.

## Behavior changes for existing hosts

- Vendor CLI process failures use error code `-32012` instead of `-32002`,
  which ACP defines as "Resource not found".
- Unknown or closed sessions get `-32002` with `data.sessionId` instead of
  `-32602`.
- Requests before `initialize` get `-32600`.
- The v1 `session/new` response no longer carries the root-level `models`
  field; models are the `model` config option. `session/set_model` still
  works.
- `ACPContentBlock` gained an `.other` case for unknown block types.

## Verification

- `swift test` (211 tests), `swiftlint` (no violations).
- ACP TCK, both versions, CLI and API fake vendors: `VERDICT: CONFORMANT`;
  figures are recorded in the design document.

## Follow-ups not in scope

- MCP servers for vendors other than claude-code and codex (stdio servers
  are passed through to those two CLIs), and the HTTP MCP transport.
- Session persistence across server processes.
- Reporting vendor tool calls, plans, and permission requests.
