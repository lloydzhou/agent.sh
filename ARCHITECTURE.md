# Implementation notes

The runtime is entirely in [`agent.sh`](agent.sh). No build step, runtime code
generation, or extracted awk files are needed.

## Request and response flow

```text
system prompt + conversation history + tool definitions
                         |
                  Chat Completions request
                         |
              curl -D - (headers + SSE body)
                         |
                  inline HTTP filter
                         |
                 inline JSON/SSE parser
                         |
                  escaped line events
                         |
                     agent loop
                  /              \
           display text       execute tools
                  \              /
                   append history
                         |
             request again after tool calls
```

`tools_load` discovers executables once at startup. Each model request rebuilds
the system prompt from built-in tool rules, environment information, an optional
skill index, and the current working directory's `AGENTS.md`.

`llm_call` assembles the request from that prompt and the JSONL history. Curl
streams headers and body through an inline awk filter, which removes HTTP
headers and reports HTTP/curl errors or a new response following a retry.

The JSON/SSE parser then emits events consumed by `agent_loop`. Tool calls run
sequentially, even when a response contains several calls.

## One embedded awk program

The JSON helpers and SSE parser share `AWK_PROGRAM`, stored in a quoted heredoc
and passed directly to awk. `json_mode=escape_string` selects string encoding;
otherwise the program parses SSE. The HTTP filter is a separate short inline
awk invocation.

The parser handles well-formed JSON and uses the first Chat Completions choice.
It expects incremental deltas, not repeated full responses. The only reasoning
extension it reads is `reasoning_content`.

Tool arguments accumulate across stream fragments. History retains the original
arguments JSON text; only the execution copy is decoded into an argument array.

## Internal event protocol

Each event is one physical line. Below, `\t` denotes a field separator:

```text
content\t<delta>
reasoning\t<delta>
tool_calls\t<name>\t<id>\t<call-json>[\t=<arg>...]
finish_reason\t<value>
error\t<message>
retry
```

Field values escape backslashes, tabs, newlines, and carriage returns. Each tool
argument has an `=` prefix so Bash's tab splitting does not discard empty
arguments. Decoding writes to `REPLY` rather than using command substitution,
which would strip trailing newlines.

## History, retries, and side effects

The user message is appended before the first request. Assistant text, tool-call
records, and tool-result messages are buffered for the current turn. On a turn
without a reported error or interrupt, the assistant record is written before
its tool results. A `tool_calls` finish reason continues the loop.

A retry clears the current turn's buffers; a reported error or interrupt skips
their history writes. Text already displayed and tools already executed are
**not rolled back**. A retried response can therefore execute a tool again.

Reasoning is displayed and, when nonempty, stored as `reasoning_content` on the
assistant message and replayed with history, including across tool calls.
History writes are ordinary appends, not a database transaction; concurrent
writers to the same conversation are not coordinated.

## Execution boundaries

Tools receive separate argv elements, without shell expansion. Their stdout and
stderr are combined. Nonzero exits are reported in the result; oversized output
retains its beginning and end.

The simple timeout sends TERM to the command PID and maps status 143 to 124.
It is not process-tree supervision: descendants or commands ignoring TERM can
survive, and a command returning 143 itself is also reported as 124.
Tools are not sandboxed.

## Verification

```sh
bash test/run.sh
```

The tests use Bash, Python 3, temporary directories, and fake curl responses.
They do not require a real API or modify the user's conversation. They cover
HTTP/SSE events, JSON/Unicode codecs, fragmented arguments, history and retries,
prompt composition, skills, timeout behavior, and tool descriptions.

`codec_regression.py`, `loop_regression.py`, and `tool_desc_regression.py` also
accept `--compare PATH` to compare against an earlier script.
