#!/usr/bin/env bash
# Validates the wire traffic of `agent-gateway server` against the upstream
# ACP JSON Schemas (stable schema/v1/schema.json and schema/v2/schema.json),
# pinned to a commit of agentclientprotocol/agent-client-protocol.
#
# Complements scripts/acp-tck.sh: the TCK judges behavior against the schema
# revision it vendors, while this checks message shapes against the schema
# revision this implementation targets.
#
# Usage: scripts/acp-schema-check.sh
# Requires git, uv, and python3.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPEC_REF="${ACP_SPEC_REF:-d3ac0e6d8b1132c9a749a4210f04bb788c9a75a4}"
BINARY="${AGENT_GATEWAY_BINARY:-$ROOT/.build/debug/agent-gateway}"
if [[ -z "${AGENT_GATEWAY_BINARY:-}" ]]; then
  (cd "$ROOT" && swift build)
fi

WORKDIR="$(mktemp -d)"
FAKE_PID=""
cleanup() {
  if [[ -n "$FAKE_PID" ]]; then
    kill "$FAKE_PID" 2>/dev/null || true
    wait "$FAKE_PID" 2>/dev/null || true
  fi
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

git init -q "$WORKDIR/spec"
git -C "$WORKDIR/spec" fetch -q --depth 1 \
  https://github.com/agentclientprotocol/agent-client-protocol.git "$SPEC_REF"
git -C "$WORKDIR/spec" checkout -q FETCH_HEAD

mkfifo "$WORKDIR/port"
python3 "$ROOT/scripts/acp-tck/fake-openrouter" > "$WORKDIR/port" &
FAKE_PID=$!
read -r PORT < "$WORKDIR/port"

uv run -q --with jsonschema python3 "$ROOT/scripts/acp-tck/schema-check.py" \
  "$WORKDIR/spec" "$BINARY" "$ROOT/scripts/acp-tck/fake-claude-code" "$PORT"
