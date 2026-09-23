#!/bin/bash
# Smoke: HTTP, SSE, and JSON assertions against the embedded programs.
set -e
cd "$(dirname "$0")/.."
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT
sed -n "/<<'AWK_PROGRAM'/,/^AWK_PROGRAM$/p" src/agent.sh | sed '1d;$d' > "$d/program.awk"
# Exercise the actual inline HTTP filter.
script=src/agent.sh
sed -n "/| util_awk_run '/,/^        ' /p" "$script" | sed '1d;$d' > "$d/http.awk"
out=$(printf 'HTTP/1.1 200 OK\r\nX-Test: yes\r\n\r\ndata: [DONE]\r\n' | awk -f "$d/http.awk")
[ "$out" = 'data: [DONE]' ] || { echo "FAIL: HTTP headers ($script)"; exit 1; }
out=$(printf 'HTTP/1.1 429 Busy\n\nold error\nHTTP/2 200\n\ndata: [DONE]\n' | awk -f "$d/http.awk")
[ "$out" = $'retry\ndata: [DONE]' ] || { echo "FAIL: HTTP retry ($script)"; exit 1; }
out=$(printf 'HTTP/2 500\n\nbad\nrequest\n' | awk -f "$d/http.awk")
[ "$out" = $'error\tHTTP 500: bad\nrequest' ] || { echo "FAIL: HTTP error ($script)"; exit 1; }
out=$(printf 'HTTP/2 503\n\n' | awk -f "$d/http.awk")
[ "$out" = $'error\tHTTP 503: (empty)' ] || { echo "FAIL: empty HTTP error ($script)"; exit 1; }
if out=$(printf 'curl: (7) Failed to connect\n' | awk -f "$d/http.awk"); then
    echo "FAIL: curl error status ($script)"; exit 1
fi
[ "$out" = $'error\tcurl: (7) Failed to connect' ] || { echo "FAIL: curl error ($script)"; exit 1; }
sse() { printf '%s\n' "$@" | LC_ALL=C awk -f "$d/program.awk"; }

out=$(sse 'data: {"choices":[{"index":0,"delta":{"content":"He"}}]}' \
          'data: {"choices":[{"index":0,"delta":{"content":"llo"}}]}' \
          'data: [DONE]')
[ "$out" = "$(printf 'content\tHe\ncontent\tllo')" ] || { echo "FAIL: incremental"; exit 1; }

out=$(sse 'data: {"choices":[{"index":0,"delta":{"content":"dup me"}}]}' \
          'data: {"choices":[{"index":0,"delta":{"content":"dup me"}}]}' \
          'data: [DONE]')
[ "$(grep -c 'content' <<<"$out")" -eq 2 ] || { echo "FAIL: repeated delta"; exit 1; }

out=$(sse 'data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"wc","arguments":"{\"args\":[\"-l\",\"a b\"]}"}}]}}]}' \
          'data: [DONE]')
call='{"id":"c1","type":"function","function":{"name":"wc","arguments":"{\"args\":[\"-l\",\"a b\"]}"}}'
call="${call//\\/\\\\}"
[ "$out" = "$(printf 'tool_calls\twc\tc1\t%s\t=-l\t=a b' "$call")" ] || { echo "FAIL: tool_calls argv"; exit 1; }

esc=$(printf 'a"b\nc 中文' | LC_ALL=C awk -v json_mode=escape_string -f "$d/program.awk")
[ "$esc" = 'a\"b\nc 中文' ] || { echo "FAIL: escape ($esc)"; exit 1; }

# Check middle truncation, including zero-length tails and exact-limit output.
(
    sed -n '/^tool_execute() {/,/^}/p' src/agent.sh > "$d/tool.sh"
    source "$d/tool.sh"
    util_run_timeout() { printf '%s' 'abcdef'; }
    TOOLS_DIR=/bin TOOL_TIMEOUT_SECS=1
    marker=$'\n...[truncated]...\n'
    for TOOL_RESULT_MAX_BYTES in 0 1 4 5 6 7; do
        case "$TOOL_RESULT_MAX_BYTES" in
            0) expected="$marker" ;;
            1) expected="a$marker" ;;
            4) expected="ab${marker}ef" ;;
            5) expected="abc${marker}ef" ;;
            *) expected="abcdef" ;;
        esac
        # Sentinel preserves trailing newlines in command substitution.
        out=$(tool_execute sh; printf '.')
        [ "$out" = "$expected." ] || { echo "FAIL: middle truncation ($TOOL_RESULT_MAX_BYTES)"; exit 1; }
    done
)

echo "smoke ok (inline HTTP, SSE, JSON, and middle truncation)"
