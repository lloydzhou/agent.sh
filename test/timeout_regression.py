#!/usr/bin/env python3
"""Offline timeout checks, for the simple PID timer and its exit-status mapping."""
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='agent-timeout-') as tmp:
    library = Path(tmp) / 'agent.sh'
    library.write_text((ROOT / 'agent.sh').read_text().rsplit('main "$@"', 1)[0])

    def run(seconds, command, stdin=''):
        start = time.monotonic()
        result = subprocess.run(['bash', '-c', 'source "$1"; util_run_timeout "$2" bash -c "$3"',
                                 'test', str(library), str(seconds), command],
                                input=stdin, capture_output=True, text=True, timeout=5)
        assert time.monotonic() - start < 4
        assert result.stderr == '', result.stderr
        return result

    result = run(3, 'printf out; printf err >&2')
    assert (result.returncode, result.stdout) == (0, 'outerr')
    for code in [1, 42, 124]:
        assert run(3, f'exit {code}').returncode == code
    assert run(3, 'exit 143').returncode == 124
    assert run(3, 'read -r line; printf "%s" "$line"', 'stdin\n').stdout == 'stdin'
    assert run(0.1, 'exec sleep 10').returncode == 124
    # A normal return must not wait for the timer or leave its output pipe open.
    for _ in range(3):
        assert run(2, 'exit 0').returncode == 0
print('Timeout regressions ok (output, stdin, exit codes, deadline, normal return)')
