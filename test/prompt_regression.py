#!/usr/bin/env python3
"""Offline checks for prompt composition and non-destructive initialization."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='agent-prompt-') as tmp:
    work = Path(tmp)
    library = work / 'agent-library.sh'
    library.write_text((ROOT / 'src/agent.sh').read_text().rsplit('main "$@"', 1)[0])
    agent = work / '.agents'
    env = dict(os.environ, LC_ALL='C', LANG='C')
    env.pop('AGENT_DIR', None)

    def run(action, locale='C'):
        return subprocess.check_output(
            ['bash', '-c', 'source "$1"; ' + action, 'test', str(library)],
            env=dict(env, LC_ALL=locale), cwd=work, text=True)

    default = run('agent_build_prompt')
    assert 'Each call passes "args"' in default
    assert 'By default, use English' in default
    assert 'User instructions:' not in default
    assert 'By default, use Chinese' in run('agent_build_prompt', 'zh_CN.UTF-8')
    for locale in ['ja_JP.UTF-8', 'ko_KR.UTF-8', 'POSIX']:
        assert 'By default, use English' in run('agent_build_prompt', locale)
    run('cmd_init')
    assert (agent / 'tools').is_dir()
    rules = work / 'AGENTS.md'
    history = agent / 'conv.jsonl'
    assert rules.read_text() == '# Agent instructions\n\n'
    assert history.read_bytes() == b''
    rules.write_text('Custom role. Answer in French.\n')
    history.write_bytes(b'preserve history\n')
    run('cmd_init')
    assert rules.read_text() == 'Custom role. Answer in French.\n'
    assert history.read_bytes() == b'preserve history\n'
    prompt = run('agent_build_prompt')
    assert 'Each call passes "args"' in prompt
    assert prompt.endswith('User instructions:\nCustom role. Answer in French.\n')
    (agent / 'AGENTS.md').write_text('Do not load this file.')
    assert 'Do not load this file.' not in run('agent_build_prompt')
    env['AGENT_DIR'] = str(work / 'custom-state')
    run('cmd_init')
    assert (work / 'custom-state/tools').is_dir()
    assert not (work / 'custom-state/AGENTS.md').exists()
    assert run('agent_build_prompt').endswith('Custom role. Answer in French.\n')
    rules.write_text('Updated role.')
    assert run('agent_build_prompt').endswith('Updated role.')
    rules.unlink()
    assert 'User instructions:' not in run('agent_build_prompt')
    assert 'Each call passes "args"' in run('agent_build_prompt')
    rules.write_text('')
    assert 'Each call passes "args"' in run('agent_build_prompt')
    assert '<skill-index>' not in run('agent_build_prompt')
    skills = work / 'custom-state/skills'
    fixtures = {
        'review': '---\nname: ignored-name\ndescription: "Review code: 中文"\n---\nSECRET BODY',
        'quoted': "---\r\ndescription: 'Quoted summary'\r\n---\r\nSECRET BODY",
        'multiline': '---\ndescription: >-\n  SECRET BODY\n---\n',
        'plain': '# No frontmatter\ndescription: SECRET BODY',
        'empty': '---\nname: empty\n---\ndescription: SECRET BODY',
    }
    for name, content in fixtures.items():
        folder = skills / name
        folder.mkdir(parents=True)
        (folder / 'SKILL.md').write_text(content)
    (skills / 'missing').mkdir()
    (skills / 'nested/deeper').mkdir(parents=True)
    (skills / 'nested/deeper/SKILL.md').write_text(fixtures['review'])
    rules.write_text('User rules last.')
    prompt = run('agent_build_prompt')
    assert prompt.count('<skill-index>') == prompt.count('</skill-index>') == 1
    assert 'no dedicated skill tool is needed' in prompt
    assert 'If none is available, do not assume its contents' in prompt
    assert '- review: Review code: 中文\n' in prompt
    assert '- quoted: Quoted summary\n' in prompt
    assert 'SECRET BODY' not in prompt and 'ignored-name' not in prompt
    for name in fixtures:
        assert f'  path: {skills / name / "SKILL.md"}\n' in prompt
    assert '- multiline\n' in prompt and '- empty\n' in prompt
    assert '/nested/deeper/' not in prompt and '- missing' not in prompt
    assert prompt.index('Environment:') < prompt.index('<skill-index>') < prompt.index('User instructions:')
    (skills / 'review/SKILL.md').write_text('---\ndescription: Updated summary\n---\n')
    assert '- review: Updated summary' in run('agent_build_prompt')
    env['AGENT_DIR'] = 'custom-state'
    assert 'path: custom-state/skills/review/SKILL.md' in run('agent_build_prompt')
    for args in [['-m'], ['--model'], ['--model', '']]:
        result = subprocess.run(['bash', str(ROOT / 'src/agent.sh'), *args],
                                env=env, cwd=work, capture_output=True, text=True, timeout=3)
        assert result.returncode == 1 and 'requires a model' in result.stderr
print('Prompt regressions ok (rules, locale, reload, init, missing/empty rules, and skill index)')
