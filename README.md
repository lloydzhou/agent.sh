# agent.sh

Filesystem-first AI agent in pure bash/awk. OpenAI Chat Completions only.
Dependencies: `bash`, `curl`, `awk` — nothing else. Run `src/agent.sh`
directly or copy it anywhere. All awk programs are inline; no build step
or runtime awk files are needed.

User instructions live in the project-root `AGENTS.md`; executable tools
and conversation state live in `.agents/`. All are ordinary files.

## Quick start

```sh
export OPENAI_API_KEY=sk-...
# optional: export OPENAI_BASE_URL=... MODEL=...

./src/agent.sh init          # creates AGENTS.md and .agents/{conv.jsonl,tools/}
./src/agent.sh "hello"       # one-shot
./src/agent.sh               # interactive REPL (no prompt + terminal)
./src/agent.sh < prompt.txt  # read prompt from stdin
mv -i .agents/conv.jsonl ".agents/conv-$(date +%Y%m%d-%H%M%S).jsonl"  # back up and start fresh
```

The conversation persists in `.agents/conv.jsonl` (one OpenAI message per
line) and is reloaded on every start — restarting continues where you left
off.

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
The optional `skills/` directory is not created by `init`. Each request scans
`$AGENT_DIR/skills/*/SKILL.md` and adds a `<skill-index>` between the environment
and user instructions. Entries contain the directory name, single-line
`description:` from `---` frontmatter, and the file path. Matching outer quotes
are removed; YAML escapes, multiline descriptions, and other YAML syntax are
not interpreted. Missing/unsupported descriptions leave just the name and path.
No recursive discovery, cache, or skill-body preloading is used. The model reads
matching files through available tools (for example `cat` or `bash`); the index
does not add a dedicated skill tool.

`./src/agent.sh init` creates a minimal editable `AGENTS.md` without overwriting
existing instructions or conversation history. No migration or fallback files.

## Tools = executables with an argument array

Drop any executable into `.agents/tools/` — a binary, a symlink to one, or
your own script. Filename is the tool name:

```sh
ln -s /bin/cat .agents/tools/cat
ln -s /usr/bin/jq .agents/tools/jq
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

## Repository layout

```
src/agent.sh          standalone agent, including inline HTTP, JSON, and SSE programs
test/run.sh          run all offline checks (Bash + Python 3)
test/smoke.sh         HTTP/SSE/escape assertions against the inline programs
test/json_regression.py JSON and tool-loop regressions, including an isolated script copy
test/loop_regression.py loop, history, retry/error, stdin, and optional baseline comparisons
```

The JSON helpers and SSE parser share one `AWK_PROGRAM` variable, defined
with a quoted heredoc in the opening variable section and passed directly
to awk. String encoding selects `json_mode=escape_string`; otherwise it
parses SSE. There is no separate source/build layout or temp-file
extraction.

Internal event flow — plain-text lines, vocabulary straight from the Chat
Completions schema (delta field names), so the pipe is debuggable with tee:

```
curl -D - (SSE) → inline HTTP filter → inline JSON + SSE parser → line events → agent loop
  content\t<delta>   reasoning\t<delta>
  tool_calls\t<name>\t<id>\t<call-json>[\t=<arg>...]
  finish_reason\t<value>   error\t<msg>   retry
```

The stream uses the first choice and incremental deltas only (no full-content
resend detection). The optional reasoning field is `reasoning_content`.
Tool-call JSON retains the original accumulated `arguments` text for history;
only the execution copy is decoded into argv. All event fields are escaped;
the `=` prefix preserves empty argv elements across Bash tab splitting.

## Verification

```sh
bash test/run.sh
```

Tests require Python 3 in addition to the runtime dependencies. They run offline,
use temporary directories, and do not call a real API or touch your conversation.

- `smoke.sh`: inline HTTP/SSE filters, escaping, and middle truncation.
- `codec_regression.py`: Unicode and JSON string codecs.
- `json_regression.py`: fragmented tool arguments, argv/history round trips, and standalone deployment.
- `loop_regression.py`: history, retry/error handling, stdin, and turn limits.
- `prompt_regression.py`: root instructions, init, locale, and the skill index.
- `timeout_regression.py`: the simple timer and its documented exit-status mapping.
- `tool_desc_regression.py`: exact man matches and help fallback.

The codec, loop, and tool-description tests also accept `--compare PATH` to
compare against a previous script version.

## Origins

Derived from my `bash-agent` implementation and simplified into a single-file
runtime. Filesystem-based tool discovery is inspired by `vercel/eve`; tools here
are ordinary executables.
