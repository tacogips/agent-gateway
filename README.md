# agent-gateway

A Swift package and [Agent Client Protocol](https://agentclientprotocol.com)
(ACP) stdio agent that owns vendor execution and provider routing. Host
applications drive `agent-gateway server` with standard ACP JSON-RPC messages
(`initialize`, `session/new`, `session/prompt`) instead of launching agent
CLIs or AI APIs directly. The package also ships a reusable, generic `ACP`
library (client, agent server, stdio/in-memory transports) usable on its own.

## Supported vendors

- CLI clients: Claude Code, Codex, and Cursor.
- Direct APIs: OpenAI Responses, Anthropic Messages, Gemini
  `streamGenerateContent`, OpenRouter Chat Completions, and Cursor Cloud Agents.
- Alternate provider routing for Codex and Claude Code, including OpenRouter.

Provider credentials are referenced by environment-variable name. Secret values
are never placed in Codex arguments or returned by the routing API.

## SwiftPM dependency

```swift
.package(path: "../agent-gateway")
```

Add `.product(name: "AgentGateway", package: "agent-gateway")` to the target
that owns workflow provider configuration. Published consumers can replace the
path dependency with the repository URL and a released version.

## ACP server and client

Run a single request through the convenience client:

```bash
agent-gateway client \
  --vendor openrouter \
  --model openai/gpt-5 \
  --prompt 'Reply with exactly OK' \
  --api-key-environment OPENROUTER_API_KEY
```

Resume a vendor session by passing `--session-id`. Cursor Cloud Agent repository
settings have typed client flags such as `--cursor-repository-url`,
`--cursor-starting-ref`, `--cursor-work-on-current-branch`, and
`--cursor-auto-create-pr`.

stdout contains only ACP JSONL messages: `session/update` notifications
(token streams as `agent_message_chunk`) followed by each request's response.
For a persistent agent, start `agent-gateway server` and speak ACP over
stdio; vendor and model come from server flags or from
`_meta.agentGateway` on `session/new`. `--agent <path>` lets the client
drive any external ACP agent. Vendor selection is explicit and is not
inferred from the model. See `design-docs/specs/acp-stdio-protocol.md`
for the protocol contract.

## ACP client library: streaming or aggregated

The `ACP` product is a generic ACP client/agent library. A prompt turn can
be consumed either as a stream or as one aggregated response — choose per
call; both wrap the same request, and the aggregated form is built on the
streaming form:

```swift
import ACP
import AgentGatewayAppCore

// Host the gateway agent in-process (no subprocess, ACP over memory).
let (client, server) = await ACPClientConnection.inProcess(
  agent: GatewayACPAgent(defaults: GatewayAgentDefaults(
    vendor: .claudeCode, model: "claude-sonnet-5"
  ))
)
_ = try await client.initialize()
let session = try await client.newSession(ACPNewSessionRequest(cwd: "/work"))
let request = ACPPromptRequest(sessionId: session.sessionId, prompt: [.text("hi")])

// Option 1: stream each session/update as it arrives.
for try await event in client.promptStream(request) {
  switch event {
  case .update(.agentMessageChunk(.text(let chunk))): print(chunk.text)
  case .response(let response): print(response.stopReason)
  default: break
  }
}

// Option 2: await the aggregated turn.
let result = try await client.promptCollecting(request)
print(result.messageText, result.thoughtText, result.response.stopReason)
```

`ACPClientConnection(transport:delegate:)` connects the same API to any
external ACP agent over stdio pipes (`ACPFileHandleTransport`).

### Per-call environment

`ProductionGatewayExecutor(environment:)` sets the environment the executor
resolves vendor executables (`PATH`), credential variables, and provider
routing against, and that the spawned vendor process inherits. It defaults to
the host process's environment; embedding hosts pass a per-call environment so
caller-scoped variables reach one vendor invocation without mutating the host
process — which is what makes concurrent turns with different credentials
safe:

```swift
let agent = GatewayACPAgent(
  defaults: GatewayAgentDefaults(vendor: .claudeCode, model: "claude-sonnet-5"),
  executor: ProductionGatewayExecutor(
    environment: ProcessInfo.processInfo.environment.merging(callScoped) { _, new in new }
  )
)
```

`gatewayImageContentBlocks(_:)` resolves file- and data-backed images into ACP
image content blocks the same way `agent-gateway client --image` does, so an
embedding host does not reimplement image loading and validation.

## Vendor model catalog

List an API vendor's available models from the CLI:

```bash
agent-gateway models --vendor openrouter --api-key-environment OPENROUTER_API_KEY
```

or from the library through `GatewayModelListing`:

```swift
let catalog = try await ProductionGatewayExecutor().models(
  GatewayModelCatalogParams(vendor: .openAI)
)
```

API-vendor ACP sessions also advertise the list in the `session/new`
response's standard `models` field (`availableModels` / `currentModelId`),
and `session/set_model` (`ACPClientConnection.setModel(sessionId:modelId:)`)
switches the model for subsequent prompts. CLI vendors (claude-code, codex,
cursor) have no machine-readable model enumeration and return an explicit
unsupported error instead of a guessed list.

### Model pricing

The `models` command attaches best-effort per-token pricing to each model
(`pricing.currency` — ISO 4217, `inputCostPerToken`, `outputCostPerToken`,
`cacheReadInputTokenCost`, `cacheCreationInputTokenCost`), sourced from the
[LiteLLM pricing database](https://github.com/BerriAI/litellm/blob/main/model_prices_and_context_window.json)
the same way ccusage resolves prices. Vendor APIs do not expose pricing, so
this is metadata layered onto the vendor's live model list; models without a
pricing entry are still listed, and a pricing failure never fails the
command. Pricing is only looked up by this query — prompt execution never
loads it.

ACP (Agent Client Protocol) defines no per-model pricing interface — its
only price type is the session-cumulative `Cost {amount, currency}` inside
`usage_update` — so this pricing payload is a gateway extension that borrows
ACP's ISO 4217 currency convention.

```bash
agent-gateway models --vendor anthropic --pricing offline
```

`--pricing` selects the resolution mode:

- `auto` (default): reuse the LiteLLM on-disk cache when it is younger than
  24 hours, otherwise fetch the LiteLLM database and refresh the cache; if
  the fetch fails, fall back to the stale cache, then resolve the fallback
  pricing table published in this repository
  (`data/model-prices.json`, fetched from the GitHub raw URL) the same way
  (cache, remote, stale cache). Each source caches on disk so repeat runs
  within the cache lifetime make no pricing requests at all.
- `offline`: never touch the network (LiteLLM cache, then fallback-table
  cache).
- `off`: skip pricing entirely.

The result's `pricingSource` field reports which layer answered
(`litellm-remote`, `litellm-cache`, `fallback-table-remote`, or
`fallback-table-cache`). Regenerate the fallback table with
`mise run update-model-prices`.

## Provider routing library

```swift
import AgentGateway

let codexProvider = try OpenRouterProvider.configuration(for: .codexAgent)
let codexOverrides = AgentProviderRouting.codexConfigurationOverrides(
  for: codexProvider
)

let claudeProvider = try OpenRouterProvider.configuration(for: .claudeCodeAgent)
let claudeEnvironment = try AgentProviderRouting.claudeCodeEnvironment(
  for: claudeProvider,
  runtimeEnvironment: ProcessInfo.processInfo.environment
)
```

For a custom gateway, construct `AgentProviderConfiguration` with a distinct
Base URL for each agent backend. HTTPS is required except for loopback HTTP
development endpoints.

The CLI can select a custom Codex- or Claude Code-compatible gateway with only
`--base-url`. In that mode the provider and model names both default to
`custom`; use the endpoint appropriate for the selected backend:

```bash
agent-gateway client \
  --vendor codex \
  --base-url https://api.kimi.example/v1 \
  --api-key-environment KIMI_API_KEY \
  --prompt 'Reply with exactly OK'

agent-gateway client \
  --vendor claude-code \
  --base-url https://api.kimi.example \
  --api-key-environment KIMI_API_KEY \
  --prompt 'Reply with exactly OK'
```

Pass `--provider-name` and `--model` explicitly for named routing services that
need their upstream model identifier, such as OpenRouter.

## Development

```bash
mise install
mise run build
mise run test
swift run agent-gateway --help
```

The package uses Swift Package Manager with:

- Generic ACP protocol target: `ACP`
- Provider library target: `AgentGateway`
- CLI library target: `AgentGatewayAppCore`
- Executable target: `AgentGatewayCLI`
- Installed executable: `agent-gateway`

Swift target names and type names must be valid Swift identifiers. If the project
name contains hyphens, keep `PROJECT_NAME` and `EXECUTABLE_NAME` hyphenated as
needed, but use globally distinctive, identifier-safe target names.

## Embedding CLI process execution

`AgentGatewayAppCore` exposes the `Sendable` `GatewayProcessRunning` protocol.
Pass a runner to `ProductionGatewayExecutor(processRunner:processOwnership:)`
to integrate a host's process supervisor. Requests include executable, arguments,
environment, working directory, stdin, deadline, ownership policy, and a per-stream
output limit. Runners emit ordered stdout/stderr chunks and return the exit code,
captured output, and explicit truncation status. Nonzero process exits return the
complete captured output; the executor converts them to vendor errors.

The default `POSIXGatewayProcessRunner` atomically creates a dedicated process
group before exec. Normal exit, failure, task cancellation, deadline expiry, and
output overflow all reclaim the group before completion. The leader remains
unreaped until group cleanup finishes, preventing stale PID/group signaling.
The runner bounds retained and emitted output to 16 MiB per stream by default;
the executor rejects truncated output. Callbacks must return promptly.

This runner supports `.foregroundProcessGroup`: commands must remain in the
owned group and must not daemonize, call `setsid`/`setpgid`, or hand work to an
external service. `.allDescendants` requires an injected OS/container supervisor
advertising that capability and is rejected before spawn by the default runner.
Hosts must leave runner-owned children to its wait owner and preserve SIGCHLD
disposition while runs are active. No private host integration SPI is required.

## Homebrew Formula

Build local formula archives:

```bash
mise run build:homebrew -- darwin-arm64 darwin-x64
```

Render a formula after both platform archives exist:

```bash
mise run homebrew:formula -- 0.1.0
```

Render directly into the default sibling tap checkout:

```bash
mise run homebrew:tap-formula -- 0.1.0
```

Install from the tap after the formula is published:

```bash
brew tap user/tap
brew install agent-gateway
```

## Homebrew Cask

The Cask workflow builds signed, notarized, and stapled macOS DMG artifacts.
Apple signing credentials must stay local and must not be committed.

Check the build plan:

```bash
mise run build:homebrew-cask -- --dry-run darwin-arm64 darwin-x64
```

Build with local signing credentials:

```bash
kinko exec --env APPLE_SIGNING_IDENTITY,APPLE_ID,APPLE_PASSWORD,APPLE_TEAM_ID -- \
  mise run build:homebrew-cask -- darwin-arm64 darwin-x64
```

Render a Cask:

```bash
mise run homebrew:cask -- 0.1.0
```

For a tagged release, build, upload, and render the tap Cask:

```bash
kinko exec --env APPLE_SIGNING_IDENTITY,APPLE_ID,APPLE_PASSWORD,APPLE_TEAM_ID -- \
  mise run release:homebrew-cask-local -- v0.1.0
```

See `packaging/homebrew/README.md` and `.agents/skills/` for release workflows.
