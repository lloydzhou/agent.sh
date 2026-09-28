<div align="center">

<h1><img src="logo.svg" alt="agent.sh" width="280" height="80"></h1>

**550S · Shell. Single-file. Symlink.**

One script. Your tools. An AI agent.

A filesystem-first AI agent in ~550 lines of Bash + awk.

[![Single file](https://img.shields.io/badge/runtime-1_file-2563eb?style=flat-square)](agent.sh)
[![Shell](https://img.shields.io/badge/Bash-%2B_curl_%2B_awk-4eaa25?style=flat-square&logo=gnubash&logoColor=white)](#quick-start)
[![No build step](https://img.shields.io/badge/build-none-f59e0b?style=flat-square)](#quick-start)
[![MIT License](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)
[![GitHub stars](https://img.shields.io/github/stars/lloydzhou/agent.sh?style=flat-square)](https://github.com/lloydzhou/agent.sh/stargazers)

**No SDK. No npm or pip. No build step.**

[Quick start](#quick-start) · [Authoring](#the-filesystem-is-the-authoring-interface) · [Tools](#tools--executables-with-an-argument-array) · [Skills](#skills-without-a-skill-tool) · [Configuration](#configuration)

</div>

---

**Give your agent a tool with a symlink:**

```sh
ln -s "$(command -v grep)" .agents/tools/grep
./agent.sh "Find the Tools section in README.md and summarize it."
```

That's the tool registration. No plugin manifest, wrapper, or SDK to write.
Create `.agents/tools/` and configure your API key first—see below.

## Why agent.sh?

agent.sh is a filesystem-first AI agent. Core agent capabilities live in
conventional locations — tools are executables, instructions are Markdown,
history is a file — so it is easy to inspect, extend, and operate.

**Built on the shell. Delivered as one file. Extended with symlinks.**

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

mkdir -p .agents/tools
ln -s "$(command -v grep)" .agents/tools/grep
ln -s "$(command -v sed)" .agents/tools/sed
./agent.sh "Find the Tools section in README.md and summarize it."
```

Prefer a standalone script? Put `agent.sh` anywhere on disk — it uses the
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

## The filesystem is the authoring interface

A project contains no agent code. Keep `agent.sh` anywhere you like — it
operates on the current working directory, so all a project needs is an
instructions file and a state directory, both auto-created on first run:

```text
my-project/
├── AGENTS.md          # always-on instructions; edit freely, re-read every request
└── .agents/
    ├── conv.jsonl     # conversation persistence; restart to resume
    ├── tools/         # tools are executables; the filename is the tool name
    │   ├── grep -> /usr/bin/grep
    │   └── sed -> /usr/bin/sed
    └── skills/        # optional procedures; indexed in the prompt, read on demand
        └── review/SKILL.md
```

Add a tool with a symlink, a skill with a file, a rule with Markdown. There is
no manifest, SDK, or config format to learn — authoring the agent and
operating the filesystem are the same activity.

The system prompt combines built-in tool rules, the runtime environment, an
optional skill index, and the current directory's `AGENTS.md` — only the
instructions slot is yours; tool rules stay intact. Locale selects the default
output language (Chinese or English); user instructions can override it.
`AGENT_DIR` relocates tools and state, not instructions. Startup creates
missing paths and a minimal `AGENTS.md` without overwriting anything already
present. Only `$PWD/AGENTS.md` is loaded — no parent-directory or recursive
discovery, and no separate init command or migration.

## Tools = executables with an argument array

Drop any executable into `.agents/tools/` — a binary, a symlink to one, or
your own script. Filename is the tool name:

```sh
ln -s "$(command -v grep)" .agents/tools/grep
ln -s "$(command -v sed)" .agents/tools/sed
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

Add `.agents/skills/<name>/SKILL.md`. The agent sees a lightweight index and
reads relevant instructions using an existing tool such as `cat` or `bash`.
No dedicated skill tool is needed.

See [skill examples and discovery rules](ARCHITECTURE.md#skill-discovery).

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

CLI: `-m/--model`, `-h/--help`.

Curious about the internals? See [Implementation notes](ARCHITECTURE.md).

## Origins

Derived from [bash-agent](https://github.com/lloydzhou/bash-agent) and simplified
into a single-file runtime. The "filesystem as the authoring interface" framing
follows [vercel/eve](https://github.com/vercel/eve); agent.sh takes it one step
further — tools here are ordinary executables, so there is no code to write.

## License

[MIT](LICENSE) © 2026 lloydzhou.
