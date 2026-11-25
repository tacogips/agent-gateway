"""Validates agent-gateway server traffic against the upstream ACP JSON Schemas.

Drives `agent-gateway server` through v1 and v2 flows (setup, config options,
prompt turns, list, close, replay, cancel, delete, and error paths) with the
CLI and API fake vendors, and validates every request it sends and every
response, error, and notification the server writes against the stable
schema of the negotiated version. Run through scripts/acp-schema-check.sh.
"""
import json, subprocess, sys, threading, time, queue
from jsonschema import Draft202012Validator
from referencing import Registry, Resource

ROOT, BIN, FAKE, API_PORT = sys.argv[1:5]
DEFS = {
    1: {"initialize": ("InitializeRequest", "InitializeResponse"), "session/new": ("NewSessionRequest", "NewSessionResponse"),
        "session/prompt": ("PromptRequest", "PromptResponse"), "session/load": ("LoadSessionRequest", "LoadSessionResponse"),
        "session/resume": ("ResumeSessionRequest", "ResumeSessionResponse"), "session/list": ("ListSessionsRequest", "ListSessionsResponse"),
        "session/close": ("CloseSessionRequest", "CloseSessionResponse"), "session/delete": ("DeleteSessionRequest", "DeleteSessionResponse"),
        "session/set_config_option": ("SetSessionConfigOptionRequest", "SetSessionConfigOptionResponse"),
        "session/update": ("SessionNotification", None), "session/cancel": ("CancelNotification", None)},
    2: {"initialize": ("InitializeRequest", "InitializeResponse"), "session/new": ("NewSessionRequest", "NewSessionResponse"),
        "session/prompt": ("PromptRequest", "PromptResponse"),
        "session/resume": ("ResumeSessionRequest", "ResumeSessionResponse"), "session/list": ("ListSessionsRequest", "ListSessionsResponse"),
        "session/close": ("CloseSessionRequest", "CloseSessionResponse"), "session/delete": ("DeleteSessionRequest", "DeleteSessionResponse"),
        "session/set_config_option": ("SetSessionConfigOptionRequest", "SetSessionConfigOptionResponse"),
        "session/update": ("UpdateSessionNotification", None), "session/cancel": ("CancelSessionNotification", None)},
}
problems, checked = [], {1: 0, 2: 0}

def validator(version):
    schema = json.load(open(f"{ROOT}/schema/v{version}/schema.json"))
    registry = Registry().with_resource("urn:acp", Resource.from_contents(schema))
    return lambda name: Draft202012Validator({"$ref": f"urn:acp#/$defs/{name}"}, registry=registry)

def check(version, v, name, value, label):
    checked[version] += 1
    for error in v(name).iter_errors(value):
        problems.append(f"v{version} {label} !~ {name}: {error.message[:160]} at {list(error.absolute_path)}")

class Peer:
    def __init__(self, version, args, env=None):
        self.version, self.v = version, validator(version)
        self.p = subprocess.Popen([BIN, "server", *args], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env)
        self.q, self.next_id, self.pending, self.updates = queue.Queue(), 0, {}, []
        threading.Thread(target=self._read, daemon=True).start()
    def _read(self):
        for line in self.p.stdout:
            self.q.put(json.loads(line))
    def send(self, method, params, notify=False, validate=True):
        message = {"jsonrpc": "2.0", "method": method, "params": params}
        req = DEFS[self.version].get(method)
        if req and validate: check(self.version, self.v, req[0], params, f"client {method} params")
        if not notify:
            self.next_id += 1
            message["id"] = self.next_id
            self.pending[self.next_id] = method
        self.p.stdin.write(json.dumps(message) + "\n"); self.p.stdin.flush()
        return message.get("id")
    def pump(self, until, timeout=30):
        """Reads agent messages, validating each, until `until(message)` is true."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            try: m = self.q.get(timeout=0.5)
            except queue.Empty: continue
            if "method" in m:
                name = DEFS[self.version].get(m["method"], (None,))[0]
                if name: check(self.version, self.v, name, m["params"], f"agent {m['method']} ({m['params'].get('update', {}).get('sessionUpdate')})")
                self.updates.append(m)
            elif "error" in m:
                check(self.version, self.v, "Error", m["error"], f"agent error for {self.pending.get(m['id'])}")
            else:
                method = self.pending.get(m["id"])
                name = DEFS[self.version].get(method, (None, None))[1]
                if name: check(self.version, self.v, name, m["result"], f"agent {method} result")
            if until(m): return m
        raise TimeoutError(f"v{self.version}: timed out")
    def call(self, method, params, validate=True):
        i = self.send(method, params, validate=validate)
        return self.pump(lambda m: m.get("id") == i and "method" not in m)
    def close(self):
        self.p.stdin.close(); self.p.wait(timeout=5)

text = lambda t: [{"type": "text", "text": t}]
idle = lambda m: m.get("method") == "session/update" and m["params"]["update"].get("state") == "idle"

def run_v1(args, env=None, config=False):
    a = Peer(1, args, env)
    a.call("initialize", {"protocolVersion": 1, "clientCapabilities": {}, "clientInfo": {"name": "check", "version": "1"}})
    s = a.call("session/new", {"cwd": "/tmp", "mcpServers": []})["result"]
    sid = s["sessionId"]
    if config:
        a.call("session/set_config_option", {"sessionId": sid, "configId": "model", "value": "fake/model-b"})
    a.call("session/prompt", {"sessionId": sid, "prompt": text("hi")})
    a.call("session/list", {})
    a.call("session/close", {"sessionId": sid})
    a.call("session/prompt", {"sessionId": sid, "prompt": text("closed")})        # -32002
    a.call("session/load", {"sessionId": sid, "cwd": "/tmp", "mcpServers": []})
    a.call("session/resume", {"sessionId": sid, "cwd": "/tmp", "mcpServers": []})
    i = a.send("session/prompt", {"sessionId": sid, "prompt": text("SLOW")})
    time.sleep(0.5); a.send("session/cancel", {"sessionId": sid}, notify=True)
    a.pump(lambda m: m.get("id") == i and "method" not in m)
    a.call("session/delete", {"sessionId": sid})
    a.call("session/new", {"cwd": "relative", "mcpServers": []})                  # -32602
    a.close()

def run_v2(args, env=None, config=False):
    a = Peer(2, args, env)
    a.call("initialize", {"protocolVersion": 2, "info": {"name": "check", "version": "1"}, "capabilities": {}})
    sid = a.call("session/new", {"cwd": "/tmp", "systemPrompt": {"mode": "append", "content": text("Be brief.")}})["result"]["sessionId"]
    if config:
        a.call("session/set_config_option", {"sessionId": sid, "configId": "model", "type": "id", "value": "fake/model-b"})
    a.call("session/prompt", {"sessionId": sid, "prompt": text("hi"), "idempotencyKey": "k1"})
    a.pump(idle)
    a.call("session/prompt", {"sessionId": sid, "prompt": text("hi"), "idempotencyKey": "k1"})
    a.call("session/list", {"cwd": "/tmp"})
    a.call("session/close", {"sessionId": sid})
    a.call("session/prompt", {"sessionId": sid, "prompt": text("closed")})        # -32002
    a.call("session/resume", {"sessionId": sid, "cwd": "/tmp", "replayFrom": {"type": "start"}})
    a.call("session/prompt", {"sessionId": sid, "prompt": text("SLOW")})
    time.sleep(0.5); a.send("session/cancel", {"sessionId": sid}, notify=True)
    a.pump(idle)
    a.call("session/prompt", {"sessionId": sid, "prompt": [{"type": "audio", "data": "AAAA", "mimeType": "audio/wav"}]})  # -32602
    a.call("session/delete", {"sessionId": sid})
    a.close()
    b = Peer(2, ["--acp-versions", "2", *args], env)
    # A v1-shaped request to a v2-only endpoint: -32022 with data.
    b.call("initialize", {"protocolVersion": 1}, validate=False)
    b.close()

cli = ["--vendor", "claude-code", "--model", "fake", "--executable", FAKE]
api = ["--vendor", "openrouter", "--model", "fake/model-a", "--base-url", f"http://127.0.0.1:{API_PORT}", "--api-key-environment", "CHECK_KEY"]
import os
env = {**os.environ, "CHECK_KEY": "fake"}
run_v1(cli); run_v2(cli); run_v1(api, env, config=True); run_v2(api, env, config=True)
print(f"validated {checked[1]} v1 and {checked[2]} v2 payloads; {len(problems)} schema problems")
for p in sorted(set(problems)): print("  " + p)
sys.exit(1 if problems else 0)
