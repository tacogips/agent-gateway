# OpenRouter Jev decisions

Jev returns typed decisions rather than assistant text. Expose it through a
separate `GatewayDeciding` interface and `decide --request` command, retaining the
existing ACP prompt contract. A JSON request supplies model, shared state, and
named choice/score/noul questions. Swift types use tagged unions so applications
can consume answers without parsing generated prose.

The client posts to `https://openrouter.ai/api/alpha/decisions` with a credential
resolved from `OPENROUTER_API_KEY` or a caller-selected variable. An explicit
alpha base supports proxies and local HTTP fixtures. Credentials stay outside
request JSON. The request preserves provider routing and observability metadata.

Validate request shape before HTTP and validate response keys, answer types,
option membership, probability ranges, and numeric usage before returning.
Caller policies remain responsible for interpreting confidence and choosing
actions. Retry transient failures using the existing gateway policy. Cancellation
propagates, malformed responses do not retry, and error details redact the active
credential before bounding the message.

Verification covers the HTTP contract with an injected transport, all answer
primitives, metadata, aliases, credentials, transient and permanent failures,
malformed results, cancellation, and CLI file/stdin input. A local HTTP smoke
test exercises the compiled CLI without consuming provider credits. Live provider
inference requires an OpenRouter account and is not part of deterministic tests.

Upstream contract:
https://openrouter.ai/docs/api/api-reference/alphadecisions/submit-a-decisions-request
