# Command

## Status

Draft

## Current CLI

```bash
agent-gateway server [--vendor <vendor> --model <model>] [options] [-- <vendor-args>]
agent-gateway client --vendor <vendor> --model <model> --prompt <text> [options] [-- <vendor-args>]
agent-gateway client --agent <path> --prompt <text> [-- <agent-args>]
agent-gateway readiness --vendor <vendor> [--executable <path>] [--api-key-environment <name>]
agent-gateway models --vendor <vendor> [--api-key-environment <name>] [--base-url <url>] [--pricing <auto|offline|off>]
agent-gateway [--help] [--version]
```

`server` serves the ACP agent side over stdio. `client` is an ACP client that
spawns the server (or any external ACP agent via `--agent`) and echoes the raw
ACP JSONL traffic. `readiness` prints one JSON object describing whether the
vendor's executable or credential is available and exits 0/1.

`models` prints one JSON object with the vendor's live model list (from the
vendor's model-listing API) plus best-effort per-token pricing (`currency`
is ISO 4217, currently always USD) from the LiteLLM pricing database. When
LiteLLM is unavailable, pricing falls back to the pricing table published in
this repository (`data/model-prices.json`, fetched via the GitHub raw URL).
Both sources keep a ~24h on-disk cache so repeat runs make no pricing
requests. `--pricing auto` (default) resolves, in order: fresh LiteLLM
cache, LiteLLM remote, stale LiteLLM cache, fresh fallback-table cache,
fallback-table remote, stale fallback-table cache; `offline` uses only the
caches; `off` skips pricing. Models without a pricing entry stay listed
with no `pricing` field, a pricing failure never fails the command, and
only this query loads pricing — prompt execution and the ACP model
advertisement do not. The `pricingSource` result field reports which layer
answered (`litellm-remote` | `litellm-cache` | `fallback-table-remote` |
`fallback-table-cache`). Regenerate the fallback table with
`mise run update-model-prices` (`scripts/update-model-prices.sh`).

ACP note: the Agent Client Protocol defines no per-model pricing — its only
price type is the session-cumulative `Cost {amount, currency}` carried by
the `usage_update` session update. The per-model pricing payload here is
therefore a gateway extension; it adopts ACP's ISO 4217 `currency`
convention so a future ACP `usage_update`/`Cost` implementation can share
the same units.

Extend this document when adding public command behavior.
