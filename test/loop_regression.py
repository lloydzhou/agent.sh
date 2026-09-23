#!/usr/bin/env python3
"""Offline loop regressions; optionally compare an earlier agent byte-for-byte."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--compare", type=Path)
options = parser.parse_args()


def event(delta, finish=None):
    return 'data: ' + json.dumps({'choices': [{'delta': delta, 'finish_reason': finish}]}) + '\n\n'


def response(body, done=True):
    return 'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n' + body + ('data: [DONE]\n\n' if done else '')


def call(ident):
    return {'index': 0, 'id': ident, 'function': {'name': 'capture', 'arguments': '{"args":["x"]}'}}


plain = response(event({'content': 'ok'}, 'stop'))
tool = response(event({'tool_calls': [call('c1')]}, 'tool_calls'))
prior = [{'role': 'user', 'content': 'earlier'}, {'role': 'assistant', 'content': 'answer'}]
# name, responses, prior history, CLI args, stdin, max turns, expected rc, roles, executions
cases = [
    ('prompt', [plain], [], ['prompt'], '', 3, 0, ['user', 'assistant'], 0),
    ('stdin', [plain], [], [], 'from stdin\n', 3, 0, ['user', 'assistant'], 0),
    ('empty-stdin', [plain], [], [], '', 3, 0, ['user', 'assistant'], 0),
    ('history', [plain], prior, ['prompt'], '', 3, 0, ['user', 'assistant', 'user', 'assistant'], 0),
    ('reasoning', [response(event({'reasoning_content': 'think'}) + event({'content': 'ok'}, 'stop'))], [], ['prompt'], '', 3, 0, ['user', 'assistant'], 0),
    ('tools', [tool, plain], [], ['prompt'], '', 3, 0, ['user', 'assistant', 'tool', 'assistant'], 1),
    ('mixed', [response(event({'content': 'checking', 'tool_calls': [call('c1')]}, 'tool_calls')), plain], [], ['prompt'], '', 3, 0, ['user', 'assistant', 'tool', 'assistant'], 1),
    ('http-error', ['HTTP/1.1 500 Error\r\n\r\nbroken\n'], [], ['prompt'], '', 3, 1, ['user'], 0),
    ('partial-error', [response(event({'content': 'partial'}) + 'curl: (56) failed\n', False)], [], ['prompt'], '', 3, 1, ['user'], 0),
    ('tool-error', [response(event({'tool_calls': [call('c1')]}, 'tool_calls') + 'curl: (56) failed\n', False)], [], ['prompt'], '', 3, 1, ['user'], 1),
    ('retry', [response(event({'content': 'discard'}), False) + plain], [], ['prompt'], '', 3, 0, ['user', 'assistant'], 0),
    ('tool-retry', [response(event({'tool_calls': [call('discard')]}, 'tool_calls'), False) + tool, plain], [], ['prompt'], '', 3, 0, ['user', 'assistant', 'tool', 'assistant'], 2),
    ('max-turns', [tool], [], ['prompt'], '', 1, 1, ['user', 'assistant', 'tool'], 1),
]

with tempfile.TemporaryDirectory(prefix='agent-loop-') as work:
    work = Path(work)
    bindir = work / 'bin'
    bindir.mkdir()
    curl = bindir / 'curl'
    curl.write_text(f'#!{sys.executable}\n' + '''import json, os, sys
from pathlib import Path
root = Path(os.environ['FIXTURE_DIR'])
log = root / 'requests.jsonl'
n = len(log.read_text().splitlines()) if log.exists() else 0
req = json.loads(sys.argv[sys.argv.index('-d') + 1])
with log.open('a') as out: out.write(json.dumps(req) + '\\n')
responses = json.loads((root / 'responses.json').read_text())
sys.stdout.write(responses[n])
''')
    curl.chmod(0o755)
    for name, wires, history, args, stdin, turns, rc, roles, executions in cases:
        snapshots = []
        for source in [ROOT / 'agent.sh'] + ([options.compare.resolve()] if options.compare else []):
            agent = work / 'agent'
            (agent / 'tools').mkdir(parents=True, exist_ok=True)
            (work / 'AGENTS.md').write_text('Test instructions.')
            (agent / 'conv.jsonl').write_text(''.join(json.dumps(x) + '\n' for x in history))
            (work / 'requests.jsonl').write_text('')
            (work / 'executions').write_text('')
            (work / 'responses.json').write_text(json.dumps(wires))
            tool_path = agent / 'tools/capture'
            tool_path.write_text(f'#!{sys.executable}\n' + '''import os,sys
from pathlib import Path
if sys.argv[1:] == ['--help']: print('capture'); sys.exit()
with (Path(os.environ['FIXTURE_DIR']) / 'executions').open('a') as f: f.write('run\\n')
print('result "quoted" 中文\\nlast')
''')
            tool_path.chmod(0o755)
            env = dict(os.environ, LC_ALL='C', LANG='C', OPENAI_API_KEY='test', MODEL='test',
                       OPENAI_BASE_URL='http://offline.invalid/v1', AGENT_DIR=str(agent),
                       MAX_TURNS=str(turns), FIXTURE_DIR=str(work),
                       PATH=str(bindir) + os.pathsep + os.environ['PATH'])
            run = subprocess.run(['bash', str(source), *args], input=stdin, env=env,
                                 cwd=work, capture_output=True, text=True, timeout=30)
            raw = (agent / 'conv.jsonl').read_text()
            messages = [json.loads(line) for line in raw.splitlines()]
            requests = [json.loads(line) for line in (work / 'requests.jsonl').read_text().splitlines()]
            count = len((work / 'executions').read_text().splitlines())
            assert run.returncode == rc, (name, run.returncode, run.stderr)
            assert [m['role'] for m in messages] == roles, (name, messages)
            assert count == executions, (name, count)
            assert requests[0]['messages'][0]['role'] == 'system'
            assert requests[0]['messages'][1:-1] == history
            assert requests[0]['messages'][-1] == {'role': 'user', 'content': args[0] if args else stdin.rstrip('\n')}
            if name in ('retry', 'tool-retry'):
                assert 'discard' not in raw, (name, raw)
            snapshots.append((run.returncode, run.stdout, run.stderr, raw, requests, count))
        if options.compare:
            assert snapshots[0] == snapshots[1], (name, snapshots)
print(f'Loop regressions ok ({len(cases)} cases' + (', baseline parity)' if options.compare else ')'))
