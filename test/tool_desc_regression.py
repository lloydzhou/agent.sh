#!/usr/bin/env python3
"""Tool-description selection with deterministic man/help output."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--compare', type=Path)
options = parser.parse_args()
cases = [
    ('demo', 'demo(1) - first\ndemo(2) - second\n', 'unused', 'first'),
    ('demo', 'other(1) - mentions demo\ndemo-extra(1) - wrong\ndemo(12)\t-\t正确\n', '', '正确'),
    ('demo', 'demo(1) no separator\n', '', 'demo(1) no separator'),
    ('demo', 'demo (1) - spaced\ndemo(1p) - suffix\n', '\n \t\nhelp first\nhelp second\n', 'help first'),
    ('demo', 'demo(1) - \ndemo(2) - later\n', 'help fallback', 'help fallback'),
    ('tool_name-2', 'tool_name-2(8) - exact\n', '', 'exact'),
    ('demo', '', '', ''),
]
with tempfile.TemporaryDirectory(prefix='agent-tool-desc-') as tmp:
    library = Path(tmp) / 'library.sh'
    for source in [ROOT / 'src/agent.sh'] + ([options.compare] if options.compare else []):
        library.write_text(source.read_text().rsplit('main "$@"', 1)[0])
        for name, man, help_text, expected in cases:
            result = subprocess.run(['bash', '-c', '''source "$1"
man() { printf '%s' "$MAN_FIXTURE"; }
util_run_timeout() { printf '%s' "$HELP_FIXTURE"; }
tools_auto_desc "$2"
''', 'test', str(library), '/tools/' + name], capture_output=True, text=True,
                env=dict(os.environ, MAN_FIXTURE=man, HELP_FIXTURE=help_text), timeout=5)
            assert result.returncode == 0 and result.stdout == expected and not result.stderr, (source, name, result)
print(f'Tool description regressions ok ({len(cases)} cases' + (', baseline parity)' if options.compare else ')'))
