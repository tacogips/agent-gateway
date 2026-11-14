# Command

## Status

Draft

## Current CLI

```bash
agent-gateway server [--vendor <vendor> --model <model>] [options] [-- <vendor-args>]
agent-gateway client --vendor <vendor> --model <model> --prompt <text> [options] [-- <vendor-args>]
agent-gateway client --agent <path> --prompt <text> [-- <agent-args>]
agent-gateway readiness --vendor <vendor> [--executable <path>] [--api-key-environment <name>]
agent-gateway [--help] [--version]
```

`server` serves the ACP agent side over stdio. `client` is an ACP client that
spawns the server (or any external ACP agent via `--agent`) and echoes the raw
ACP JSONL traffic. `readiness` prints one JSON object describing whether the
vendor's executable or credential is available and exits 0/1.

Extend this document when adding public command behavior.
