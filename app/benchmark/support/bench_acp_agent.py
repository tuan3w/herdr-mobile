#!/usr/bin/env python3
"""A scripted ACP agent for benchmark/session_open_bench.dart (python 3, stdlib).

Speaks JSON-RPC lines on stdio like the real adapters. `session/prompt` plays
the file named by $BENCH_SEED: one `session/update` object per line, sent as
fast as the pipe takes them, then ends the turn. The keeper in front of it
logs them, which is what a later `session/load` replays.
"""
import json
import os
import sys


def send(obj):
    sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        msg = json.loads(line)
        method, rid = msg.get("method"), msg.get("id")
        if rid is None or method is None:
            continue
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": rid, "result": {
                "protocolVersion": 1,
                "agentInfo": {"name": "bench-agent", "version": "1"},
                "agentCapabilities": {"loadSession": False, "promptCapabilities": {"image": True, "embeddedContext": True}},
                "authMethods": [],
            }})
        elif method == "session/new":
            send({"jsonrpc": "2.0", "id": rid, "result": {
                "sessionId": "bench-session",
                "modes": {"currentModeId": "default", "availableModes": [{"id": "default", "name": "Default"}]},
            }})
        elif method == "session/prompt":
            sid = msg["params"]["sessionId"]
            with open(os.environ["BENCH_SEED"]) as f:
                for upd in f:
                    sys.stdout.write('{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"%s","update":%s}}\n' % (sid, upd.rstrip("\n")))
            sys.stdout.flush()
            send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})
        else:
            send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "unknown method " + method}})


main()
