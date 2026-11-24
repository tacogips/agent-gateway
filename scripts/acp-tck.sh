#!/usr/bin/env bash
# Runs the ACP Test Compatibility Kit (github.com/agentclientprotocol/acp-tck)
# against `agent-gateway server`, using deterministic fake vendors so no
# vendor account or network access to a model is needed.
#
# Usage: scripts/acp-tck.sh [--protocol-version 1|2] [--vendor-mode cli|api] [acp-tck args...]
#
#   cli (default)  claude-code vendor backed by scripts/acp-tck/fake-claude-code
#   api            openrouter vendor backed by scripts/acp-tck/fake-openrouter;
#                  this path advertises models, so it also exercises ACP
#                  config options (session/set_config_option)
#
# The TCK is experimental and pinned to a commit so results are reproducible.
# Requires uv (https://docs.astral.sh/uv/) and python3.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TCK_REF="${ACP_TCK_REF:-7c71c4d1af0994e73bdc100c9f7f6b98f2319cda}"
PROTOCOL_VERSION=1
VENDOR_MODE=cli
EXTRA=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --protocol-version) PROTOCOL_VERSION="$2"; shift 2 ;;
    --vendor-mode) VENDOR_MODE="$2"; shift 2 ;;
    *) EXTRA+=("$1"); shift ;;
  esac
done

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

case "$VENDOR_MODE" in
  cli)
    AGENT=("$BINARY" server --vendor claude-code --model fake --executable "$ROOT/scripts/acp-tck/fake-claude-code")
    AGENT_ENV=()
    ;;
  api)
    mkfifo "$WORKDIR/port"
    python3 "$ROOT/scripts/acp-tck/fake-openrouter" > "$WORKDIR/port" &
    FAKE_PID=$!
    read -r PORT < "$WORKDIR/port"
    AGENT=("$BINARY" server --vendor openrouter --model fake/model-a
      --base-url "http://127.0.0.1:$PORT" --api-key-environment ACP_TCK_FAKE_KEY)
    AGENT_ENV=(--agent-env ACP_TCK_FAKE_KEY=fake)
    ;;
  *) echo "unknown --vendor-mode: $VENDOR_MODE" >&2; exit 2 ;;
esac

mkdir -p "$WORKDIR/cwd"
uvx --from "git+https://github.com/agentclientprotocol/acp-tck@$TCK_REF" acp-tck \
  --protocol-version "$PROTOCOL_VERSION" \
  --agent-cwd "$WORKDIR/cwd" \
  --timeout 20 --test-timeout 60 \
  --cancel-prompt "SLOW please write a long, detailed explanation" \
  ${AGENT_ENV[@]+"${AGENT_ENV[@]}"} \
  ${EXTRA[@]+"${EXTRA[@]}"} \
  -- "${AGENT[@]}"
