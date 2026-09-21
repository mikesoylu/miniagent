#!/usr/bin/env bash
# Compare the embedded fallback with real jq; neither path contacts a provider.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/miniagent-json-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
REAL_JQ=$(command -v jq) || { printf 'Tests require jq as an oracle.\n' >&2; exit 1; }
source "$ROOT/miniagent.sh"
PASS=0
FAIL=0

check_json() {
  local label=$1 input=$2 expected_status actual_status
  shift 2
  printf '%s' "$input" | "$REAL_JQ" "$@" > "$TMP/expected" 2> "$TMP/expected.err"
  expected_status=$?
  printf '%s' "$input" | miniagent_jq "$@" > "$TMP/actual" 2> "$TMP/actual.err"
  actual_status=$?
  if [[ "$expected_status" -eq "$actual_status" ]] && cmp -s "$TMP/expected" "$TMP/actual"; then
    printf 'ok - %s\n' "$label"; PASS=$((PASS + 1))
  else
    printf 'not ok - %s (jq status %s, fallback status %s)\n' "$label" "$expected_status" "$actual_status"
    cat "$TMP/actual.err" >&2
    FAIL=$((FAIL + 1))
  fi
}

for text in '' 0 false $'line\nline\n' $'quote " slash \\ tab\t' 'é😀日本語' 'backslashes \\ and literal \n \t' '$(not executed); `not executed`' $'\001\b\f\037'; do
  check_json "Bash constructor escapes strings" '' -cn --arg e "$text" '{reasoning:{effort:$e}}'
  check_json "Raw input preserves strings and trailing newlines" "$text" -Rsc '{role:"user",content:.}'
  encoded=$("$REAL_JQ" -cn --arg text "$text" '{text:$text}')
  check_json "JSON strings round trip" "$encoded" -c .
  check_json "Raw output decodes strings" "$encoded" -r '.text'
done
for input in '' null false true 0 '""' '[]' '{}'; do
  check_json "Exit status for empty, false, null and truthy values" "$input" -e .
done
for input in '{"enabled":true,"disabled":false,"value":null,"count":1}' '[0,1,-2,3.5]' '{"items":[true,false,null,{"count":1}],"done":true}'; do
  check_json "Primitive tokens before commas and closing brackets (BusyBox awk)" "$input" -c .
done
for input in 'oops' '1true' 'truefalse' 'nullx' '{' '{"x":}' '[1,]' '{"x":1,}' $'{"x":"\n"}'; do
  check_json "Invalid JSON fails validation" "$input" -e .
done
for input in '{}' '{"id":false}' '{"id":null}' '{"id":""}' '{"id":0}'; do
  check_json "ID fallback preserves jq truthiness" "$input" -r '.id // empty'
done
for input in '{}' '{"output":[]}' '{"output":[null,{"content":[]},{"content":[{"type":"refusal"}]}]}'; do
  check_json "Optional iteration skips missing values without dropping valid results" "$input" -e 'any(.output[]?.content[]?; .type == "refusal")'
done
for input in '[]' '[1,2,3]' '"abcd"' '"é😀日本語"'; do
  for filter in length '.[0:2]' '.[-2:]' '.[1:-1]'; do
    check_json "Length and slices ($filter)" "$input" -c "$filter"
  done
done
check_json "History append via slurped input" $'[{"role":"user","content":"hello"}]\n{"role":"assistant","content":"hi"}\n' -cs '.[0] + [.[1]]'
for input in '[]' '{}' '[{"items":[1,true,null,"text"]},{"empty":[]}]'; do
  check_json "Compact container rendering (legacy BusyBox concatenation)" "$input" -c .
  check_json "Pretty container rendering (legacy BusyBox concatenation)" "$input" .
done
check_json "Join strings and primitives (legacy BusyBox concatenation)" '["first",1,true,null,"last"]' -r 'join(":")'
check_json "Anthropic queued user messages" '' -cn --argjson history '[{"role":"assistant","content":[]}]' --argjson queued '["one","two"]' \
  '$history + [{role:"user",content:[$queued[] | {type:"text",text:.}]}]'
check_json "Anthropic queue after tool results" '' -cn --argjson history '[{"role":"user","content":[{"type":"tool_result","content":"done"}]}]' --argjson queued '["one","two"]' \
  '$history | .[-1].content += [$queued[] | {type:"text",text:.}]'
check_json "Timeout output" '' -cn --arg stdout $'partial\n' --arg stderr timeout '{stdout:$stdout,stderr:$stderr,outcome:{type:"timeout"}}'
check_json "Missing read path" '' -cn '{kind:"error",text:"read requires path"}'
check_json "Missing shell command" '' -cn '{kind:"error",text:"shell requires command"}'
check_json "OpenRouter image attachment" $'[]\n{"text":"chart","media_type":"image/png","data":"aW1hZ2U="}' -cs \
  '.[0] as $a | .[1] as $r | $a + [{type:"text",text:$r.text},{type:"image_url",image_url:{url:("data:"+$r.media_type+";base64,"+$r.data)}}]'
check_json "Anthropic image attachment" '{"text":"chart","media_type":"image/png","data":"aW1hZ2U="}' -c --arg id a1 \
  '{type:"tool_result",tool_use_id:$id,content:[{type:"text",text:.text},{type:"image",source:{type:"base64",media_type:.media_type,data:.data}}]}'
printf 'answer\n\n' > "$TMP/answer"
printf '[{"role":"user","content":"hello"}]\n' > "$TMP/history"
check_json "Raw-file arguments preserve newlines" '' -cn --rawfile answer "$TMP/answer" '{answer:$answer}'
check_json "Slurp-file arguments" '' -cn --slurpfile history "$TMP/history" '{messages:$history[0]}'
check_json "Positional file input" '' -c '.[0].content' "$TMP/history"
check_json "Standard input between positional files" '{"stdin":true}' -cs . "$TMP/history" - "$TMP/history"
check_json "Fractional token usage is floored" '{"usage":{"input_tokens":2.5,"output_tokens":1.25}}' -r \
  '(.usage.total_tokens // ((.usage.input_tokens // 0) + (.usage.output_tokens // 0))) | floor'
check_json "Case-insensitive refusal pattern" '{"error":{"message":"Blocked by the safety policy"}}' -e \
  '(.error.message // "") | test("flagged for possible (cybersecurity|safety) risk|blocked by (a |the )?(safety|content) policy"; "i")'
check_json "Unsupported filters fail" '{}' 'unsupported_filter'

# Exercise temporary-file transport above the Linux per-argument exec limit without
# passing the large string to the oracle as an exec argument.
large=$(awk 'BEGIN {for(i=0;i<140000;i++)printf "x"}')
large_json=$(printf '%s' "$large" | "$REAL_JQ" -Rs .)
printf '%s' "$large_json" | "$REAL_JQ" -c '{text:.}' > "$TMP/expected"
miniagent_jq -cn --argjson text "$large_json" '{text:$text}' > "$TMP/actual"
if cmp -s "$TMP/expected" "$TMP/actual"; then
  printf 'ok - Large JSON arguments use temporary-file transport\n'; PASS=$((PASS + 1))
else
  printf 'not ok - Large JSON arguments use temporary-file transport\n'; FAIL=$((FAIL + 1))
fi

# The large-argument transport must leave stdin intact and clean up on errors.
mkdir "$TMP/args"
printf '%s' "$large_json" | "$REAL_JQ" -c '{text:.,input:"from stdin"}' > "$TMP/expected"
printf '"from stdin"' | TMPDIR="$TMP/args" miniagent_jq -c --argjson text "$large_json" '{text:$text,input:.}' > "$TMP/actual"
if cmp -s "$TMP/expected" "$TMP/actual"; then
  printf 'ok - Large arguments preserve stdin\n'; PASS=$((PASS + 1))
else
  printf 'not ok - Large arguments preserve stdin\n'; FAIL=$((FAIL + 1))
fi
TMPDIR="$TMP/args" miniagent_jq -cn --argjson text "$large_json" unsupported_filter >/dev/null 2>&1
large_status=$?
if [[ "$large_status" -ne 0 && -z $(ls -A "$TMP/args") ]]; then
  printf 'ok - Large argument files are cleaned up on success and failure\n'; PASS=$((PASS + 1))
else
  printf 'not ok - Large argument files are cleaned up on success and failure\n'; FAIL=$((FAIL + 1))
fi

# The fallback is a function in the harness; it must not leak its byte locale.
before_locale=${LC_ALL-unset}
miniagent_jq -cn '{kind:"text",text:"ok"}' >/dev/null
if [[ ${LC_ALL-unset} == "$before_locale" ]]; then
  printf 'ok - Fallback preserves caller locale\n'; PASS=$((PASS + 1))
else
  printf 'not ok - Fallback preserves caller locale\n'; FAIL=$((FAIL + 1))
fi
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
