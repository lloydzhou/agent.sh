#!/usr/bin/env python3
"""Offline JSON/SSE and complete agent-loop regressions; no API/network needed."""
import json
import os
from pathlib import Path
import random
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ENV = dict(os.environ, LC_ALL="C", LANG="C")
SOURCE = ROOT / "src/agent.sh"
SCRIPT = SOURCE.read_text()


def embedded(tag):
    return SCRIPT.split("<<'" + tag + "' || true\n", 1)[1].split("\n" + tag + "\n", 1)[0]


AWK = embedded("AWK_PROGRAM")


def sse(events):
    wire = "".join("data: " + json.dumps(e) + "\n\n" for e in events)
    wire += "data: [DONE]\n\n"
    return subprocess.check_output(
        ["awk", AWK], input=wire, text=True, env=ENV)


def chunk(delta, **extra):
    return {"choices": [{"index": 0, "delta": delta, **extra}]}


def unesc(s):
    out = ""
    i = 0
    while i < len(s):
        c = s[i]
        if c == "\\":
            i += 1
            c = {"n": "\n", "r": "\r", "t": "\t", "\\": "\\"}[s[i]]
        out += c
        i += 1
    return out


# Repeated deltas, literal null, leading/trailing newlines, and fixed field scope.
assert sse([chunk({"content": s}) for s in ["ha", "ha", "null", "\n", None]]) == (
    "content\tha\ncontent\tha\ncontent\tnull\ncontent\t\\n\n")
assert sse([chunk({"reasoning_content": "null", "reasoning": "ignored"})]) == "reasoning\tnull\n"
assert sse([{"content": "wrong scope", "choices": [{"delta": {"content": "right"}}]}]) == "content\tright\n"

# Random strings exercise escapes, braces/key lookalikes, controls, and Unicode.
rng = random.Random(0)
samples = ["", '"content":{}[]', "中文😀", "\\n", "\x01", "a\n\n"]
samples += ["".join(rng.choice('abc{}[]"\\\n\r\t中😀\x01') for _ in range(30)) for _ in range(50)]
args_sets = [samples, [], ["", "", "tail\n", "\\", "\t", ""]]
raw_args = [" \n" + json.dumps({"args": a}, ensure_ascii=True, indent=1) + "\n " for a in args_sets]
events = []
# Interleave several tool calls and split at every character (including escapes).
for pos in range(max(map(len, raw_args))):
    calls = []
    for idx, raw in enumerate(raw_args):
        if pos < len(raw):
            call = {"index": idx, "function": {"arguments": raw[pos]}}
            if pos == 0:
                call.update(id=f"call_{idx}")
                call["function"]["name"] = "capture"
            calls.append(call)
    events.append(chunk({"tool_calls": calls}))
events.append(chunk({}, finish_reason="tool_calls"))
lines = sse(events).splitlines()
assert len(lines) == len(args_sets) + 1  # no duplicate emission at DONE
for i, line in enumerate(lines[:-1]):
    fields = [unesc(f) for f in line.split("\t")]
    call = json.loads(fields[3])
    assert call["function"]["arguments"] == raw_args[i]
    assert [a[1:] for a in fields[4:]] == args_sets[i]
assert lines[-1] == "finish_reason\ttool_calls"

# Test the source and an isolated copy through fake curl, real Bash, and a real tool.
with tempfile.TemporaryDirectory(prefix="bash-agent-json-") as tmp:
    tmp = Path(tmp)
    bindir = tmp / "bin"
    bindir.mkdir()
    fake = bindir / "curl"
    fake.write_text(f"#!{sys.executable}\n" + '''import json, os, sys
from pathlib import Path
req = json.loads(sys.argv[sys.argv.index('-d') + 1])
assert 'stream_options' not in req
results = [m for m in req['messages'] if m['role'] == 'tool']
print('HTTP/1.1 200 OK\\r\\nContent-Type: text/event-stream\\r\\n\\r')
if results:
    calls = next(m['tool_calls'] for m in req['messages'] if 'tool_calls' in m)
    expected = json.loads(Path(os.environ['FIXTURE']).read_text())
    assert [c['function']['arguments'] for c in calls] == expected
    assert [json.loads(m['content']) for m in results] == [json.loads(x)['args'] for x in expected]
    events = [{'choices': [{'delta': {'content': 'verified'}, 'finish_reason': 'stop'}]}]
else:
    events = json.loads(Path(os.environ['EVENTS']).read_text())
for event in events:
    print('data: ' + json.dumps(event) + '\\n')
print('data: [DONE]\\n')
''')
    fake.chmod(0o755)
    (tmp / "events.json").write_text(json.dumps(events))
    (tmp / "args.json").write_text(json.dumps(raw_args))
    copied = tmp / "standalone.sh"
    copied.write_text(SCRIPT)
    for layout, executable in [("source", SOURCE), ("copied", copied)]:
        agent = tmp / layout
        (agent / "tools").mkdir(parents=True)
        (tmp / "AGENTS.md").write_text("Test agent.")
        tool = agent / "tools/capture"
        tool.write_text(f"#!{sys.executable}\nimport json,sys\nprint(json.dumps(sys.argv[1:]))\n")
        tool.chmod(0o755)
        env = dict(ENV, PATH=str(bindir) + os.pathsep + os.environ["PATH"],
                   AGENT_DIR=str(agent), OPENAI_API_KEY="test", MODEL="test",
                   OPENAI_BASE_URL="http://offline.invalid/v1", MAX_TURNS="3",
                   EVENTS=str(tmp / "events.json"), FIXTURE=str(tmp / "args.json"))
        run = subprocess.run(["bash", str(executable), "test"],
                             env=env, cwd=tmp, capture_output=True, text=True, timeout=30)
        assert run.returncode == 0, (layout, run.stdout, run.stderr)
        messages = [json.loads(s) for s in (agent / "conv.jsonl").read_text().splitlines()]
        assert messages[-1] == {"role": "assistant", "content": "verified"}, (layout, messages, run.stderr)
        assert [json.loads(m['content']) for m in messages if m['role'] == 'tool'] == args_sets
print("JSON regressions ok (escapes, Unicode, interleaved fragments, argv/history, source + standalone copy)")
