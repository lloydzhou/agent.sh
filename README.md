<div align="center">

<h1><img src="logo.svg" alt="agent.sh" width="280" height="80"></h1>

**One script. Your tools. An AI agent.**

A filesystem-first AI agent in ~550 lines of Bash + awk.

[![Single file](https://img.shields.io/badge/runtime-1_file-2563eb?style=flat-square)](agent.sh)
[![Shell](https://img.shields.io/badge/Bash-%2B_curl_%2B_awk-4eaa25?style=flat-square&logo=gnubash&logoColor=white)](#quick-start)
[![No build step](https://img.shields.io/badge/build-none-f59e0b?style=flat-square)](#quick-start)
[![MIT License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)
[![GitHub stars](https://img.shields.io/github/stars/lloydzhou/agent.sh?style=flat-square)](https://github.com/lloydzhou/agent.sh/stargazers)

**No SDK. No npm or pip. No build step.**

[Quick start](#quick-start) · [Tools](#tools--executables-with-an-argument-array) · [Skills](#skills-without-a-skill-tool) · [Configuration](#configuration)

</div>

---

**Give your agent a tool with a symlink:**

```sh
ln -s "$(command -v cat)" .agents/tools/cat
./agent.sh "Read README.md and summarize this project."
```

That's the tool registration. No plugin manifest, wrapper, or SDK to write.
Run `init` and configure your API key first—see below.

## Why agent.sh?

- **Small enough to read end to end.** The runtime lives in one script, including JSON parsing and SSE streaming. Copy it anywhere; no generated files.
- **Your executables are the tools.** Drop a binary, script, or symlink into `.agents/tools/`. Names and descriptions are discovered automatically.
- **Instructions are just Markdown.** Edit the project-root `AGENTS.md`; the next request picks it up. Built-in tool rules stay intact.
- **Skills without a framework.** Add `.agents/skills/<name>/SKILL.md`. A lightweight index goes into the prompt; existing tools read the full instructions on demand.
- **Conversation is just a file.** History stays in `.agents/conv.jsonl`. Restart to continue; move the file to start fresh.
- **A working agent loop, not just a chat wrapper.** Streaming replies, tool execution, error feedback, retries, and bounded tool output—all in the same file.

Use it as a small terminal assistant, a base for your own agent, or an agent loop
you can inspect without navigating a framework.

## Quick start

Runtime: **Bash, curl, awk**, plus standard shell utilities. No Python, Node.js,
`jq`, or model SDK is required by the runtime. You need an API endpoint supporting
streaming Chat Completions, plus a model with tool-calling support to use tools.

```sh
git clone https://github.com/lloydzhou/agent.sh.git
cd agent.sh

export OPENAI_API_KEY="your-api-key"
export MODEL="your-model-name"  # a model supported by your endpoint
# Optional: export OPENAI_BASE_URL="https://your-provider.example/v1"

./agent.sh init
ln -s "$(command -v cat)" .agents/tools/cat
./agent.sh "Read README.md and summarize this project."
```

Prefer a standalone script? Copy `agent.sh` into your own project. It uses the
**current working directory**, not the script's location, for rules and state.

```sh
./agent.sh "hello"       # one-shot
./agent.sh               # interactive REPL
./agent.sh < prompt.txt  # prompt from stdin
```

Restarting resumes the stored conversation. To back it up and start fresh:

```sh
mv -i .agents/conv.jsonl ".agents/conv-$(date +%Y%m%d-%H%M%S).jsonl"
```

> **Tools are not sandboxed.** They run with your shell privileges and
> model-supplied arguments. Start with tools you trust and a disposable workspace.

## Layout

```
AGENTS.md           user instructions — edit freely, re-read on every request
.agents/
  conv.jsonl        conversation persistence (OpenAI message per line)
  tools/            executables; filename = tool name
  skills/           optional skills; indexed in the system prompt, read via tools
```

The system prompt combines built-in tool rules, runtime environment, and an
optional user-instruction slot loaded from `$PWD/AGENTS.md`. Tool rules
remain present even when you customize the agent. Locale selects the default
output language (Chinese or English); user instructions can override it.
Only `$PWD/AGENTS.md` is loaded, without parent-directory or recursive discovery.
`AGENT_DIR` overrides the tools/state directory, not the instructions location.
`./agent.sh init` creates a minimal editable `AGENTS.md` without overwriting
existing instructions or conversation history. No migration or fallback files.

## Tools = executables with an argument array

Drop any executable into `.agents/tools/` — a binary, a symlink to one, or
your own script. Filename is the tool name:

```sh
ln -s "$(command -v cat)" .agents/tools/cat
# If jq is installed, you can expose it too:
ln -s "$(command -v jq)" .agents/tools/jq
```

Every tool receives an `args` array of strings. The agent passes each
element as a separate argument, without shell expansion:

```sh
.agents/tools/<name> "${args[@]}"
```

stdout+stderr is returned to the model as the tool result.

Descriptions are automatic: `man -f <name>` (whatis), falling back to the
executable's own `--help` first line — custom scripts can self-describe:

```sh
#!/bin/sh
# .agents/tools/count — count lines of files matching a name pattern
[ "$1" = "--help" ] && { echo "count lines of files matching a pattern, e.g. '*.sh'"; exit 0; }
find . -name "$1" -type f -print0 | xargs -0 wc -l
```

Rules:

- Tool name = filename, must match `[A-Za-z0-9_-]{1,64}`; must be
  executable (`chmod +x`).
- Non-zero exit → output is prefixed `Error (exit N):`.
- Long output keeps its beginning and end, with a truncation marker in the
  middle. The retained portions total `$TOOL_RESULT_MAX_BYTES` (default
  100000), excluding the marker.
- Commands time out at `$TOOL_TIMEOUT_SECS` (default 60). The simple timer
  sends TERM to the command PID and maps exit status 143 to 124. It does not
  guarantee descendant cleanup or stop commands that ignore TERM; a command
  returning 143 itself is also reported as 124.
- No `.agents/tools/` directory (or empty) → no tools are sent; pure chat.
- Tools run with your shell privileges — only put executables you trust in
  `.agents/tools/`, and remember the model controls `args`.

## Skills without a skill tool

```text
.agents/skills/
└── code-review/
    ├── SKILL.md
    └── references/
```

A minimal `SKILL.md`:

```markdown
---
name: code-review
description: Review code changes for correctness and maintainability.
---
Read the changed files. Prioritize bugs and regressions over style preferences.
Explain each finding with a file location and a suggested fix.
```

The agent sees the index first, then uses a suitable available tool such as `cat`
or `bash` to read a matching skill. **You do not need `.agents/tools/skill`.** If no
suitable tool is available, the prompt tells the model not to assume the contents.

<details>
<summary>Index format and scope</summary>

The optional `skills/` directory is not created by `init`. Each request scans
`$AGENT_DIR/skills/*/SKILL.md` and adds a `<skill-index>` between the environment
and user instructions. Entries contain the directory name, single-line
`description:` from `---` frontmatter, and the file path. Matching outer quotes
are removed; YAML escapes, multiline descriptions, and other YAML syntax are
not interpreted. Missing/unsupported descriptions leave just the name and path.
No recursive discovery, cache, or skill-body preloading is used. The model reads
matching files through available tools (for example `cat` or `bash`); the index
does not add a dedicated skill tool.

</details>

## Configuration

| Env | Default | Purpose |
|---|---|---|
| `OPENAI_API_KEY` | — | required |
| `OPENAI_BASE_URL` | `https://api.openai.com/v1` | any OpenAI-compatible endpoint |
| `MODEL` | `gpt-5.6-luna` | model name |
| `MAX_TURNS` | `50` | tool-call loop cap per prompt |
| `TOOL_TIMEOUT_SECS` | `60` | per-tool timeout |
| `TOOL_RESULT_MAX_BYTES` | `100000` | per-tool output cap |
| `AGENT_DIR` | `$PWD/.agents` | agent directory override |

CLI: `init`, `-m/--model`, `-h/--help`.

Curious about the internals? See [Implementation notes](ARCHITECTURE.md).

## Origins

Derived from [bash-agent](https://github.com/lloydzhou/bash-agent) and simplified
into a single-file runtime. Filesystem-based tool discovery is inspired by
[vercel/eve](https://github.com/vercel/eve); tools here are ordinary executables.

## License

[MIT](LICENSE) © 2026 lloydzhou.
