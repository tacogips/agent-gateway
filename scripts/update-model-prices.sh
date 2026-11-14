#!/usr/bin/env bash
set -euo pipefail

# Regenerates data/model-prices.json, the fallback pricing table that
# `agent-gateway models` fetches from this repository's GitHub raw URL when
# the LiteLLM pricing database is unavailable.
#
# The table is the LiteLLM pricing database
# (model_prices_and_context_window.json) filtered to the gateway's API
# vendors and to the per-token cost fields the gateway reads.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$ROOT/data/model-prices.json"
SOURCE_URL="https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

curl -sfL --max-time 120 "$SOURCE_URL" -o "$TMP"
mkdir -p "$ROOT/data"

python3 - "$TMP" "$OUTPUT" <<'PY'
import json
import sys

source, output = sys.argv[1], sys.argv[2]
providers = {"anthropic", "openai", "gemini", "openrouter"}
cost_keys = (
    "input_cost_per_token",
    "output_cost_per_token",
    "cache_read_input_token_cost",
    "cache_creation_input_token_cost",
)

with open(source) as handle:
    data = json.load(handle)

filtered = {}
for model, entry in sorted(data.items()):
    if not isinstance(entry, dict) or entry.get("litellm_provider") not in providers:
        continue
    costs = {
        key: entry[key]
        for key in cost_keys
        if isinstance(entry.get(key), (int, float)) and not isinstance(entry.get(key), bool)
    }
    if "input_cost_per_token" not in costs and "output_cost_per_token" not in costs:
        continue
    filtered[model] = costs

lines = ",\n".join(
    f"  {json.dumps(model)}: {json.dumps(costs, sort_keys=True)}"
    for model, costs in filtered.items()
)
with open(output, "w") as handle:
    handle.write("{\n" + lines + "\n}\n")

print(f"wrote {output} ({len(filtered)} models)")
PY
