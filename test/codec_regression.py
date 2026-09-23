#!/usr/bin/env python3
"""Check JSON codecs against Python, optionally against a prior agent version."""
import argparse
import json
import os
from pathlib import Path
import random
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--compare', type=Path)
options = parser.parse_args()
ENV = dict(os.environ, LC_ALL='C', LANG='C')


def helpers(path):
    script = path.read_text()
    awk = script.split("<<'AWK_PROGRAM' || true\n", 1)[1].split('\nAWK_PROGRAM\n', 1)[0]
    return awk.split('# ---------- CLI ----------', 1)[0]


def run(program, strings, encode=False):
    expr = 'jescape(junesc($0))' if encode else 'junesc($0)'
    action = '{ value = ' + expr + '; printf "%d:%s\\n", length(value), value }'
    return subprocess.check_output(['awk', program + '\n' + action],
                                   input=('\n'.join(strings) + '\n').encode(), env=ENV)


def framed(values):
    return b''.join(str(len(value)).encode() + b':' + value + b'\n' for value in values)


rng = random.Random(0)
# Every BMP scalar including U+0000, plus supplementary-plane boundaries/random samples.
points = [cp for cp in range(65536) if not 0xD800 <= cp <= 0xDFFF]
points += [0x10000, 0x10001, 0x1F600, 0x10FFFF]
points += [rng.randrange(0x10000, 0x110000) for _ in range(512)]
values = [chr(cp) for cp in points]
values += ['', '\\', '/', '"', '\b\f\n\r\t', 'quotes " and \\ 中文😀']
valid = [json.dumps(value, ensure_ascii=True)[1:-1] for value in values]
# Incomplete/invalid escapes and isolated/mismatched surrogates keep existing behavior.
odd = ['\\', '\\u', '\\u1', '\\u123', '\\u12xz', '\\q', '\\U1234',
       '\\ud800', '\\udfff', '\\ud800\\u0041', '\\ud800\\ud800',
       '\\ud800\\uZZZZ', '\\uD83D\\uDE00', '\\\\u0041']
odd += [f'\\u{cp:04x}' for cp in range(0xD800, 0xE000)]
odd += [''.join(rng.choice('abc\\u012XYZ') for _ in range(30)) for _ in range(1000)]
current = helpers(ROOT / 'src/agent.sh')
# Some awk implementations turn sprintf("%c", 0) into an empty string.
# Probe the interpreter independently; keep NUL in decode and baseline coverage.
nul = subprocess.check_output(['awk', 'BEGIN { printf "%s", sprintf("%c", 0) }'], env=ENV)
assert nul in (b'', b'\0'), 'Unexpected awk NUL representation'
assert run(current, valid) == framed([
    value.encode().replace(b'\0', nul) for value in values
]), 'Unicode decode mismatch'
# The existing encoder does not escape NUL; do not silently change that behavior here.
non_nul = [(raw, value) for raw, value in zip(valid, values) if '\0' not in value]
assert run(current, [x[0] for x in non_nul], True) == framed([
    json.dumps(value, ensure_ascii=False)[1:-1].encode() for _, value in non_nul
]), 'JSON encode mismatch'
if options.compare:
    old = helpers(options.compare)
    for encode in [False, True]:
        assert run(current, valid + odd, encode) == run(old, valid + odd, encode), 'Baseline mismatch'
print(f'Codec regressions ok ({len(valid)} Python-checked cases' +
      (f', {len(valid) + len(odd)} old/new cases per codec)' if options.compare else ')'))
