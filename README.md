# agent-gateway

A Swift package and JSONL stdio server that owns vendor execution and provider
routing. Riela sends versioned `agent/execute` requests to
`agent-gateway server` instead of launching agent CLIs or AI APIs directly.

## Supported vendors

- CLI clients: Claude Code, Codex, and Cursor.
- Direct streaming APIs: OpenAI Responses, Anthropic Messages, Gemini
  `streamGenerateContent`, and OpenRouter Chat Completions.
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

## JSONL server and client

Run a single request through the convenience client:

```bash
agent-gateway client \
  --vendor openrouter \
  --model openai/gpt-5 \
  --prompt 'Reply with exactly OK' \
  --api-key-environment OPENROUTER_API_KEY
```

stdout contains only JSONL `agent/event` notifications followed by one
terminal response. For a persistent client, start `agent-gateway server` and
write one JSON request per line to stdin. Vendor selection is explicit and is
not inferred from the model. See
`design-docs/specs/jsonl-stdio-protocol.md` for the protocol contract.

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

## Development

```bash
mise install
mise run build
mise run test
swift run agent-gateway --help
```

The package uses Swift Package Manager with:

- Provider library target: `AgentGateway`
- CLI library target: `AgentGatewayAppCore`
- Executable target: `AgentGatewayCLI`
- Installed executable: `agent-gateway`

Swift target names and type names must be valid Swift identifiers. If the project
name contains hyphens, keep `PROJECT_NAME` and `EXECUTABLE_NAME` hyphenated as
needed, but use globally distinctive, identifier-safe target names.

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
