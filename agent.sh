#!/usr/bin/env bash
# 550S — Shell. Single-file. Symlink.
#
# Built on the shell.
# Delivered as one file.
# Extended with symlinks.
#
# Source: https://github.com/lloydzhou/agent.sh
# License: MIT — see LICENSE in the source repository.
# agent.sh — filesystem-first AI agent in pure bash/awk
# Chat Completions only; dependencies: bash, curl, awk.
# Auto-create: AGENTS.md (rules), .agents/tools/ (executables), .agents/conv.jsonl (history).

set -uo pipefail

MODEL="${MODEL:-gpt-5.6-luna}"
API_KEY="${OPENAI_API_KEY:-}"
API_URL="${OPENAI_BASE_URL:-https://api.openai.com/v1}/chat/completions"
AGENT_DIR="${AGENT_DIR:-$PWD/.agents}"
TOOLS_DIR="$AGENT_DIR/tools"
CONV_FILE="$AGENT_DIR/conv.jsonl"
MAX_TURNS="${MAX_TURNS:-50}"
TOOL_TIMEOUT_SECS="${TOOL_TIMEOUT_SECS:-60}"
TOOL_RESULT_MAX_BYTES="${TOOL_RESULT_MAX_BYTES:-100000}"
USER_INPUT=""

TOOL_DEFS_JSON=""
DISPLAY_LAST_CHAR=$'\n'
PREV_WAS_REASONING=false
INTERRUPT_REQUESTED=false

# ================= inline awk program =================
# Quoted heredoc preserves backslashes; read returns nonzero at EOF.
IFS= read -r -d '' AWK_PROGRAM <<'AWK_PROGRAM' || true
# Well-formed JSON: direct fields, raw array elements, decoded strings.

# Read one JSON value, honoring strings and nested containers.
function jread_at(s, i,    start, c, depth, quoted, escaped) {
    while (substr(s, i, 1) ~ /[ \t\r\n]/) i++
    start = i
    for (; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (quoted) {
            if (escaped) escaped = 0
            else if (c == "\\") escaped = 1
            else if (c == "\"") {
                quoted = 0
                if (!depth) return substr(s, start, i - start + 1)
            }
        } else {
            if (!depth && c ~ /[,}\] \t\r\n]/) break
            if (c == "\"") quoted = 1
            else if (c == "{" || c == "[") depth++
            else if (c == "}" || c == "]") {
                if (--depth == 0) return substr(s, start, i - start + 1)
            }
        }
    }
    return substr(s, start, i - start)
}

function jfield(s, key,    i, k, v) {
    sub(/^[ \t\r\n]+/, "", s)
    if (substr(s, 1, 1) != "{") return ""
    for (i = 2; i < length(s);) {
        while (substr(s, i, 1) ~ /[, \t\r\n]/) i++
        k = jread_at(s, i); i += length(k)
        while (substr(s, i, 1) ~ /[: \t\r\n]/) i++
        v = jread_at(s, i)
        if (k == "\"" key "\"") return v
        if (v == "") break
        i += length(v)
    }
    return ""
}

function jstr(s, key,    v) {
    v = jfield(s, key)
    return substr(v, 1, 1) == "\"" ? junesc(substr(v, 2, length(v) - 2)) : ""
}

function jsplit(s, out,    i, v, n) {
    split("", out)
    sub(/^[ \t\r\n]+/, "", s)
    if (substr(s, 1, 1) != "[") return 0
    for (i = 2; i < length(s);) {
        while (substr(s, i, 1) ~ /[, \t\r\n]/) i++
        v = jread_at(s, i)
        if (v == "") break
        out[++n] = v; i += length(v)
    }
    return n + 0
}

# ---------- escape / unescape ----------
function jescape(s,    out, i, c, code) {
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if ((code = index("\"\\\b\f\n\r\t", c)) > 0)
            out = out "\\" substr("\"\\bfnrt", code, 1)
        else if ((code = index("\001\002\003\004\005\006\007\010\011\012\013\014\015\016\017\020\021\022\023\024\025\026\027\030\031\032\033\034\035\036\037", c)) > 0)
            out = out sprintf("\\u%04x", code)
        else out = out c
    }
    return out
}

function junesc(s,    out, i, c, pos, hex, cp, lo) {
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c != "\\") { out = out c; continue }
        if (++i > length(s)) break
        c = substr(s, i, 1)
        if (c != "u") {
            pos = index("bfnrt\"\\/", c)
            out = out (pos ? substr("\b\f\n\r\t\"\\/", pos, 1) : c)
            continue
        }
        hex = substr(s, i + 1, 4)
        cp = hex_to_int(hex)
        if (length(hex) < 4 || cp < 0) { out = out "\\u"; continue }
        if (cp >= 55296 && cp <= 56319 && i + 10 <= length(s) && substr(s, i + 5, 2) == "\\u") {
            lo = hex_to_int(substr(s, i + 7, 4))
            if (lo >= 56320 && lo <= 57343) {
                out = out utf8(65536 + (cp - 55296) * 1024 + lo - 56320)
                i += 10; continue
            }
        }
        out = out (cp >= 55296 && cp <= 57343 ? "\\u" hex : utf8(cp))
        i += 4
    }
    return out
}

function hex_to_int(hex,    i, d, value) {
    for (i = 1; i <= length(hex); i++) {
        d = index("0123456789abcdef", tolower(substr(hex, i, 1))) - 1
        if (d < 0) return -1
        value = value * 16 + d
    }
    return value + 0
}

function utf8(cp) {
    # Decoding runs under LC_ALL=C; build UTF-8 bytes explicitly.
    if (cp <= 127) return sprintf("%c", cp)
    if (cp <= 2047) return sprintf("%c%c", 192 + int(cp / 64), 128 + (cp % 64))
    if (cp <= 65535) return sprintf("%c%c%c", 224 + int(cp / 4096), 128 + int((cp % 4096) / 64), 128 + (cp % 64))
    return sprintf("%c%c%c%c", 240 + int(cp / 262144), 128 + int((cp % 262144) / 4096), 128 + int((cp % 4096) / 64), 128 + (cp % 64))
}

# ---------- CLI ----------
BEGIN {
    if (json_mode == "escape_string") {
        if ((getline json_input) < 0) json_input = ""
        else while ((getline _line) > 0) json_input = json_input "\n" _line
        printf "%s", jescape(substr(json_input, 1, length(json_input) - 1))
        exit 0
    }
}
# SSE -> TSV; tool_calls: name, id, call JSON, argv prefixed with '=' to preserve empty args.

function esc(s,    out, i, c) {
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        out = out (c == "\\" ? "\\\\" : c == "\t" ? "\\t" : c == "\n" ? "\\n" : c == "\r" ? "\\r" : c)
    }
    return out
}

BEGIN { _reset() }

/^error\t/ { print "error\t" esc(substr($0, 7)); fflush(); done = 1; exit 0 }
/^retry$/ { _reset(); print "retry"; fflush(); next }
/^data: \[DONE\]/ {
    _emit_tools()
    if (pending_stop != "") print "finish_reason\t" pending_stop
    fflush(); done = 1; next
}
/^data: / {
    jsplit(jfield(substr($0, 7), "choices"), choices)
    choice = choices[1]
    delta = jfield(choice, "delta")
    fr = jstr(choice, "finish_reason")
    if (fr != "") pending_stop = fr
    content = jstr(delta, "content")
    if (content != "") print "content\t" esc(content)
    reasoning = jstr(delta, "reasoning_content")
    if (reasoning != "") print "reasoning\t" esc(reasoning)
    _parse_tool_calls(jfield(delta, "tool_calls"))
    if (fr == "tool_calls") _emit_tools()
    fflush()
}
END {
    if (json_mode != "escape_string" && !done && pending_stop == "") print "error\tStream interrupted (no [DONE] received)"
}

function _reset() {
    done = 0; pending_stop = ""; tc_max = -1
    split("", tc_name); split("", tc_id); split("", tc_args)
}

function _parse_tool_calls(json,    n, p, tc, idx, f, id) {
    n = jsplit(json, chunks)
    for (p = 1; p <= n; p++) {
        tc = chunks[p]
        idx = jfield(tc, "index")
        if (idx !~ /^[0-9]+$/) continue
        idx += 0
        if (idx > tc_max) tc_max = idx
        f = jfield(tc, "function")
        id = jstr(tc, "id")
        if (id != "") tc_id[idx] = id
        tc_name[idx] = tc_name[idx] jstr(f, "name")
        tc_args[idx] = tc_args[idx] jstr(f, "arguments")
    }
}

function _emit_tools(    idx, n, i, call, line) {
    for (idx = 0; idx <= tc_max; idx++) {
        if (tc_args[idx] == "") continue
        # Preserve the arguments JSON text; decode only the execution copy.
        call = "{\"id\":\"" jescape(tc_id[idx]) "\",\"type\":\"function\",\"function\":{\"name\":\"" jescape(tc_name[idx]) "\",\"arguments\":\"" jescape(tc_args[idx]) "\"}}"
        line = "tool_calls\t" esc(tc_name[idx]) "\t" esc(tc_id[idx]) "\t" esc(call)
        n = jsplit(jfield(tc_args[idx], "args"), argv)
        for (i = 1; i <= n; i++) line = line "\t=" esc(junesc(substr(argv[i], 2, length(argv[i]) - 2)))
        print line
        tc_args[idx] = ""
    }
    fflush()
}
AWK_PROGRAM

# ================= utils =================
util_awk_run() { LC_ALL=C LANG=C awk "$@"; }

util_unescape() {
    # Decode line-protocol fields into REPLY without stripping trailing newlines.
    local s="$1" c
    REPLY=""
    while [[ "$s" == *\\* ]]; do
        REPLY+="${s%%\\*}"; s="${s#*\\}"
        c="${s:0:1}"; s="${s:1}"
        case "$c" in n) REPLY+=$'\n' ;; t) REPLY+=$'\t' ;; r) REPLY+=$'\r' ;; *) REPLY+="$c" ;; esac
    done
    REPLY+="$s"
}

util_run_timeout() {
    local seconds="$1" pid watcher rc; shift
    "$@" <&0 2>&1 & pid=$!
    ( sleep "$seconds"; kill -TERM "$pid" 2>/dev/null ) >/dev/null 2>&1 & watcher=$!
    wait "$pid" 2>/dev/null; rc=$?
    kill "$watcher" 2>/dev/null
    return $(( rc == 143 ? 124 : rc ))
}

util_die() {
    printf '\033[31mError: %s\033[0m\n' "$*" >&2
    exit 1
}

util_json_escape() {
    # A final sentinel preserves trailing newlines through awk's record reader.
    printf '%s.' "${1:-}" | util_awk_run -v json_mode=escape_string "$AWK_PROGRAM"
}

# ================= system prompt =================
agent_build_prompt() {
    cat <<'PROMPT'
You are agent.sh, a minimal filesystem-first agent running in a terminal.

Tools:
- Tools are plain executables (binaries, symlinks, scripts) in the agent tools directory; the tool name is the file name.
- Each call passes "args": an array of strings. Elements are handed to the command as separate arguments — like Docker CMD exec form. No shell expansion: quotes, spaces, and $ are literal. Pass [] when the tool takes no arguments.
- Read each tool's description before calling it.
- A tool returns stdout and stderr. Non-zero exit is prefixed "Error (exit N)" — read the message and self-correct on the next call. Long output is truncated; use head/tail/grep to narrow large reads.
- Shell composition (pipes, $(...), globs) does not apply to args. If a "bash" tool exists, call it with ["-c", "<command line>"] for full shell features.
- You may issue several independent tool calls in one turn.
PROMPT
    local locale="${LC_ALL:-${LC_MESSAGES:-${LANG:-en_US}}}" lang_name skill name desc indexed=""
    locale="${locale%%.*}"
    case "$locale" in ""|C|C.*|POSIX) locale="en_US" ;; esac
    case "$locale" in zh*) lang_name="Chinese" ;; *) lang_name="English" ;; esac
    printf 'Environment:\nlang: %s\npwd: %s\nhome: %s\nplatform: %s\nshell: %s\n' \
        "$locale" "$PWD" "${HOME:-?}" "$(uname -s 2>/dev/null || echo unknown)" "${SHELL:-unknown}"
    printf '\nBy default, use %s (%s) for output, including reasoning/thinking, unless user instructions specify otherwise. Code, commands, and file content remain as-is.\n' "$lang_name" "$locale"
    for skill in "$AGENT_DIR"/skills/*/SKILL.md; do
        [[ -f "$skill" ]] || continue
        if [[ -z "$indexed" ]]; then
            printf '\n<skill-index>\nWhen a skill matches the task, read its SKILL.md using any suitable available tool (e.g. cat or bash); no dedicated skill tool is needed. If none is available, do not assume its contents. Resolve relative paths from the skill directory.\n'
            indexed=1
        fi
        name="${skill%/SKILL.md}"; name="${name##*/}"
        desc=$(awk '
            { sub(/\r$/, "") }
            NR == 1 { if ($0 != "---") exit; next }
            /^---$/ { exit }
            /^description:[ \t]*/ { sub(/^description:[ \t]*/, ""); sub(/[ \t]+$/, ""); if ($0 ~ /^[|>][-+0-9]*$/) exit; if ($0 ~ /^".*"$/ || $0 ~ /^\047.*\047$/) $0 = substr($0, 2, length($0) - 2); print; exit }
        ' "$skill")
        printf -- '- %s%s\n  path: %s\n' "$name" "${desc:+: $desc}" "$skill"
    done
    [[ -n "$indexed" ]] && printf '</skill-index>\n'
    if [[ -f "$PWD/AGENTS.md" ]]; then
        printf '\nUser instructions:\n'
        cat "$PWD/AGENTS.md"
    fi
}

# ================= tools (filesystem-discovered command templates) =================
tools_load() {
    TOOL_DEFS_JSON=""
    [[ -d "$TOOLS_DIR" ]] || return 0
    local f name desc
    for f in "$TOOLS_DIR"/*; do
        [[ -x "$f" ]] || continue # tools are executables: binaries, symlinks, scripts
        name="${f##*/}"
        [[ "$name" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || { printf 'skip tool (bad name): %s\n' "$name" >&2; continue; }
        desc=$(tools_auto_desc "$f")
        [[ -n "$desc" ]] || desc="Run $name"
        TOOL_DEFS_JSON+="${TOOL_DEFS_JSON:+,}"'{"type":"function","function":{"name":"'"$name"'","description":"'"$(util_json_escape "$desc")"'","parameters":{"type":"object","properties":{"args":{"type":"array","items":{"type":"string"},"description":"command-line arguments for '"$name"', passed as separate arguments (exec form); [] if none"}}}}}'
    done
}

tools_auto_desc() {
    # Exact-name man match; fall back to --help with stdin=/dev/null and a timeout.
    local name="${1##*/}" d
    d=$(man -f "$name" 2>/dev/null | awk -v name="$name" '$0 ~ "^" name "\\([0-9]+\\)" { sub(/^[^(]*\([^)]*\)[[:space:]]*-[[:space:]]*/, ""); print; exit }')
    [[ -z "$d" ]] && d=$(util_run_timeout 3 "$1" --help </dev/null 2>&1 | grep -m1 -v '^[[:space:]]*$')
    printf '%s' "$d"
}

tool_execute() {
    local name="$1" f="$TOOLS_DIR/$1" output rc; shift
    [[ -x "$f" ]] || { printf 'Error: no such tool: %s' "$name"; return 0; }
    output=$(util_run_timeout "$TOOL_TIMEOUT_SECS" bash -c 'exec "$0" "$@"' "$f" "$@" 2>&1)
    rc=$?
    (( rc != 0 )) && output="Error (exit $rc): $output"
    if (( ${#output} > TOOL_RESULT_MAX_BYTES )); then
        local head=$(( (TOOL_RESULT_MAX_BYTES + 1) / 2 )) tail=$(( TOOL_RESULT_MAX_BYTES / 2 ))
        output="${output:0:head}"$'\n...[truncated]...\n'"${output: ${#output}-tail}"
    fi
    printf '%s' "$output"
}

# ================= conversation (conv.jsonl: one OpenAI message per line) =================
conv_append() { printf '%s\n' "$1" >> "$CONV_FILE"; }

# ================= llm =================
llm_call() {
    local body='{"model":"'"$MODEL"'","messages":[{"role":"system","content":"'"$(util_json_escape "$(agent_build_prompt)")"'"}'
    body+="$(awk '{printf ",%s", $0}' "$CONV_FILE")"']'
    [[ -n "$TOOL_DEFS_JSON" ]] && body+=',"tools":['"$TOOL_DEFS_JSON"']'
    body+=',"stream":true}'
    curl -sS --no-buffer -D - --retry 2 --retry-delay 1 --retry-max-time 20 \
        --connect-timeout 5 --speed-limit 1 --speed-time 60 \
        -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" \
        -d "$body" "$API_URL" 2>&1 \
        | util_awk_run '
            { sub(/\r$/, "") }
            /^curl: / { print "error\t" $0; fflush(); exit 1 }
            /^HTTP\// {
                if (body) { print "retry"; fflush() }
                code = $2; body = 0; err = ""; next
            }
            /^[ \t]*$/ && !body { body = 1; next }
            !body { next }
            code >= 400 { err = err (err == "" ? "" : "\n") $0; next }
            { print; fflush() }
            END {
                if (code >= 400) {
                    print "error\tHTTP " code ": " (err == "" ? "(empty)" : err)
                    fflush()
                }
            }
        ' \
        | util_awk_run "$AWK_PROGRAM"
}

# ================= display =================
display_ensure_newline() {
    if [[ "$DISPLAY_LAST_CHAR" != $'\n' ]]; then printf '\n'; DISPLAY_LAST_CHAR=$'\n'; fi
    return 0
}

display() {
    local kind="$1"; shift
    case "$kind" in
        content|reasoning)
            [[ -n "$1" ]] || return 0
            if [[ "$kind" == reasoning ]]; then
                PREV_WAS_REASONING=true
                printf '\033[90m%s\033[0m' "$1"
            else
                [[ "$PREV_WAS_REASONING" == true ]] && printf '\n'
                PREV_WAS_REASONING=false
                printf '%s' "$1"
            fi
            DISPLAY_LAST_CHAR="${1: -1}"; return 0 ;;
        tool) display_ensure_newline; printf '\033[33m[tool] %s %s\033[0m\n' "$1" "${2:0:120}" ;;
        result)
            local first="${2%%$'\n'*}"
            printf '\033[90m[%s done] %s\033[0m\n' "$1" "${first:0:120}" ;;
        error) display_ensure_newline; printf '\033[31mError: %s\033[0m\n' "$1" >&2 ;;
        retry) printf '\033[90mretrying...\033[0m\n' >&2 ;;
    esac
    DISPLAY_LAST_CHAR=$'\n'
}

# ================= agent loop =================
agent_loop() {
    local turn=0 stop="" text="" reasoning="" reasoning_field="" calls="" tool_messages="" _line _type _rest
    conv_append '{"role":"user","content":"'"$(util_json_escape "$1")"'"}'
    INTERRUPT_REQUESTED=false
    trap 'INTERRUPT_REQUESTED=true' INT
    while (( turn < MAX_TURNS )); do
        (( turn++ )) || true
        stop=""; text=""; reasoning=""; calls=""; tool_messages=""
        exec 8< <(llm_call)
        while IFS= read -r _line <&8; do
            [[ "$INTERRUPT_REQUESTED" == true ]] && { stop="interrupted"; break; }
            _type="${_line%%$'\t'*}"
            _rest="${_line#*$'\t'}"
            case "$_type" in
                content)
                    util_unescape "$_rest"
                    display content "$REPLY"
                    text+="$REPLY" ;;
                reasoning)
                    util_unescape "$_rest"; display reasoning "$REPLY"; reasoning+="$REPLY" ;;
                tool_calls)
                    # name, id, complete call JSON, then '='-prefixed argv fields.
                    local _f=() _argv=() _name _id _call _output _i
                    IFS=$'\t' read -r -a _f <<<"$_rest"
                    util_unescape "${_f[0]}"; _name="$REPLY"
                    util_unescape "${_f[1]}"; _id="$REPLY"
                    util_unescape "${_f[2]}"; _call="$REPLY"
                    for _i in ${_f[@]+"${_f[@]:3}"}; do
                        util_unescape "${_i:1}"; _argv+=("$REPLY")
                    done
                    display tool "$_name" "${_argv[*]-}"
                    _output=$(tool_execute "$_name" ${_argv[@]+"${_argv[@]}"})
                    display result "$_name" "$_output"
                    calls+="${calls:+,}$_call"
                    tool_messages+='{"role":"tool","tool_call_id":"'"$(util_json_escape "$_id")"'","content":"'"$(util_json_escape "$_output")"'"}'$'\n' ;;
                retry)
                    display retry
                    text=""; reasoning=""; calls=""; tool_messages="" ;;
                finish_reason)
                    stop="$_rest" ;;
                error)
                    util_unescape "$_rest"; display error "$REPLY"
                    stop="error"; break ;;
            esac
        done
        exec 8<&-
        [[ "$stop" == "interrupted" || "$stop" == "error" ]] && break
        # Persist this assistant turn, then continue only when tools were called
        reasoning_field=""
        [[ -n "$reasoning" ]] && reasoning_field=',"reasoning_content":"'"$(util_json_escape "$reasoning")"'"'
        if [[ -n "$calls" ]]; then
            local content_field="null"
            [[ -n "$text" ]] && content_field='"'"$(util_json_escape "$text")"'"'
            conv_append '{"role":"assistant","content":'"$content_field"',"tool_calls":['"$calls"']'"$reasoning_field"'}'
            printf '%s' "$tool_messages" >> "$CONV_FILE"
            [[ "$stop" == "tool_calls" ]] && continue
        else
            [[ -n "$text$reasoning" ]] && conv_append '{"role":"assistant","content":"'"$(util_json_escape "$text")"'"'"$reasoning_field"'}'
        fi
        break
    done
    trap - INT
    if (( turn >= MAX_TURNS )); then
        display error "Max turns ($MAX_TURNS) reached"
        return 1
    fi
    [[ "$stop" == error ]] && return 1
    return 0
}

# ================= interactive =================
interactive_mode() {
    local line
    printf '\033[36magent.sh (%s) — type exit or Ctrl+D to quit\033[0m\n' "$MODEL"
    while true; do
        if ! IFS= read -e -r -p $'\033[32m550S>\033[0m ' line; then printf '\n'; break; fi
        [[ "$line" == "exit" || "$line" == "quit" ]] && break
        [[ -z "$line" ]] && continue
        history -s "$line" 2>/dev/null || true
        agent_loop "$line"
        display_ensure_newline
    done
    printf '\033[36mGoodbye!\033[0m\n'
}

# ================= cli =================
usage() {
    cat <<'EOF'
agent.sh — filesystem-first AI agent (OpenAI Chat Completions)

Usage:
  agent.sh [prompt]          chat; no prompt + tty opens interactive REPL
  agent.sh < file            read prompt from stdin
  fresh conversation: mv -i .agents/conv.jsonl ".agents/conv-$(date +%Y%m%d-%H%M%S).jsonl"

Missing AGENTS.md, tools directory, and history file are created on startup.

Options:
  -m, --model NAME   model override (env MODEL)
  -h, --help         this help

Environment:
  OPENAI_API_KEY     required
  OPENAI_BASE_URL    default https://api.openai.com/v1
  MODEL              default gpt-5.6-luna
EOF
}

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            -m|--model) [[ -n "${2:-}" ]] || util_die "$1 requires a model"; MODEL="$2"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            -*) util_die "unknown option: $1 (see --help)" ;;
            *) [[ -n "$USER_INPUT" ]] && util_die "unexpected extra argument: $1"
               USER_INPUT="$1"; shift ;;
        esac
    done
    return 0
}

main() {
    parse_args "$@"
    [[ -n "$API_KEY" ]] || util_die "OPENAI_API_KEY is not set"
    mkdir -p "$TOOLS_DIR" && touch "$CONV_FILE" || util_die "Cannot initialize $AGENT_DIR"
    if [[ ! -e "$PWD/AGENTS.md" ]]; then
        printf '# Agent instructions\n\n' > "$PWD/AGENTS.md" || util_die "Cannot create AGENTS.md"
    fi
    tools_load
    if [[ -z "$USER_INPUT" ]]; then
        if [[ -t 0 ]]; then interactive_mode; return $?; fi
        USER_INPUT=$(cat)
    fi
    agent_loop "$USER_INPUT"
    local rc=$?
    display_ensure_newline
    return "$rc"
}

main "$@"
