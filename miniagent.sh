#!/usr/bin/env bash
# miniagent: a deliberately small, Bash-only coding agent harness.
# https://github.com/mikesoylu/miniagent
set -uo pipefail
VERSION="0.2.0"
SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
PROVIDER="${MINIAGENT_PROVIDER:-}"
MODEL="${MINIAGENT_MODEL:-}"
FALLBACK_MODEL="${MINIAGENT_FALLBACK_MODEL:-}"
TURN_MODEL=""
REASONING="${MINIAGENT_REASONING:-medium}"
MAX_TURNS="${MINIAGENT_MAX_TURNS:-1024}"
MAX_TOKENS="${MINIAGENT_MAX_TOKENS:-32768}"
COMPACT_TOKENS="${MINIAGENT_COMPACT_TOKENS:-262144}"
COMPACT_MAX_TOKENS="${MINIAGENT_COMPACT_MAX_TOKENS:-13107}"
MAX_TOOL_OUTPUT="${MINIAGENT_MAX_TOOL_OUTPUT:-30000}"
MAX_IMAGE_BYTES=1048576
TOOL_TIMEOUT="${MINIAGENT_TOOL_TIMEOUT:-120}"
API_TIMEOUT="${MINIAGENT_API_TIMEOUT:-600}"
WORKDIR="${MINIAGENT_WORKDIR:-$PWD}"
DEBUG="${MINIAGENT_DEBUG:-0}"
DEBUG_DIR="${MINIAGENT_DEBUG_DIR:-}"
DEBUG_LOG=""
DEBUG_ARGV=()
OUTPUT_FORMAT="text"
INTERACTIVE=0
INTERACTIVE_EXECUTION=0
INTERACTIVE_CAPTURE_ENABLED=0
INTERACTIVE_STOP_REQUESTED=0
INTERACTIVE_INPUT_CLOSED=0
INTERACTIVE_INPUT_BUFFER=""
INTERACTIVE_INPUT_PROMPT_VISIBLE=0
INTERACTIVE_STTY_STATE=""
INTERACTIVE_STOP_FILE=""
INTERACTIVE_QUEUED_MESSAGES='[]'
INTERACTIVE_QUEUED_BATCH='[]'
INTERACTIVE_QUEUED_COUNT=0
QUIET=0
PROMPT=""
HISTORY='[]'
OPENAI_PREVIOUS_RESPONSE_ID=""
OPENAI_NEEDS_RESTART=0
CONTEXT_TOKENS=0
CONTEXT_TOKENS_KNOWN=0
COMPACTION_SUMMARY=""
LAST_ANSWER=""
API_RESPONSE=""
CAPTURED_RESULT=""
CURL_BIN="${CURL_BIN:-curl}"
JQ_BIN="${JQ_BIN:-jq}"
OPENROUTER_COMPLETIONS_PATH="/chat/completions"
PUBLIC_PROXY=0
if [[ -t 2 ]]; then
  C_DIM=$'\033[2m'; C_CYAN=$'\033[36m'; C_RED=$'\033[31m'; C_RESET=$'\033[0m'
else
  C_DIM=""; C_CYAN=""; C_RED=""; C_RESET=""
fi
say() { [[ "$QUIET" -eq 1 ]] || printf '%s\n' "$*" >&2; }
info() { say "${C_DIM}$*${C_RESET}"; }
die() { debug_log "fatal message=$(printf '%q' "$*")"; printf '%sminiagent: %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; exit 1; }
usage() {
  cat <<'EOF'
miniagent - a tiny Bash-only coding agent

Usage:
  miniagent.sh [options] "task"
  miniagent.sh [options]                 # interactive mode

Options:
  -p, --provider NAME     openai, anthropic, or openrouter
  -m, --model MODEL       Provider model name
      --fallback-model M  Retry safety refusals once with model M (none disables)
  -r, --reasoning LEVEL   default, none, minimal, low, medium, high, xhigh, max
  -C, --chdir DIR         Working directory available to the agent
  -n, --max-turns N       Maximum model calls per user turn (default: 1024)
      --max-tokens N      Maximum output tokens per model call (default: 32768)
      --compact-tokens N  Compact context at this token count (default: 262144)
      --debug             Write a diagnostic bundle under the system temp directory
      --debug-dir DIR     Write the diagnostic bundle to DIR (enables --debug)
  -i, --interactive       Stay interactive after an initial task
      --json              JSON output in CLI mode
  -q, --quiet             Hide tool progress
  -h, --help              Show help
  -v, --version           Show version

Environment:
  OPENAI_API_KEY, OPENAI_BASE_URL, OPENAI_MODEL, OPENAI_FALLBACK_MODEL
  ANTHROPIC_API_KEY, ANTHROPIC_BASE_URL, ANTHROPIC_MODEL, ANTHROPIC_FALLBACK_MODEL
  OPENROUTER_API_KEY, OPENROUTER_BASE_URL, OPENROUTER_MODEL, OPENROUTER_FALLBACK_MODEL
  MINIAGENT_PROVIDER, MINIAGENT_MODEL, MINIAGENT_FALLBACK_MODEL, MINIAGENT_REASONING
  MINIAGENT_MAX_TURNS, MINIAGENT_MAX_TOKENS, MINIAGENT_COMPACT_TOKENS
  MINIAGENT_COMPACT_MAX_TOKENS, MINIAGENT_TOOL_TIMEOUT, MINIAGENT_DEBUG
  MINIAGENT_DEBUG_DIR
  OPENROUTER_HTTP_REFERER, OPENROUTER_APP_NAME

If no provider API key is set, miniagent uses the free public proxy at miniagent.sh
and ignores provider, model, fallback, and base URL settings.

Interactive commands:
  /model NAME, /provider NAME, /reasoning LEVEL, /compact, /status, /clear, /help, /quit
  Ctrl-D immediately aborts the active request or tool call.
EOF
}
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }
# Embedded jq subset: keep this in the script so downloaded and piped copies
# work without companion files. Prefer native jq; this fallback supports only
# miniagent filters. It requires awk with regex record separators, uses double
# precision arithmetic, and does not support NUL characters or general jq regexes.
miniq_quote() {
  local v=$1 i ch replacement
  v=${v//\\/\\\\}; v=${v//\"/\\\"}
  v=${v//$'\n'/\\n}; v=${v//$'\r'/\\r}; v=${v//$'\t'/\\t}
  v=${v//$'\b'/\\b}; v=${v//$'\f'/\\f}
  if [[ $v == *[$'\001'-$'\037']* ]]; then
    for ((i=1; i<32; i++)); do
      printf -v ch '\\%03o' "$i"; printf -v ch '%b' "$ch"
      printf -v replacement '\\u%04x' "$i"; v=${v//"$ch"/"$replacement"}
    done
  fi
  miniq_quoted=\"$v\"
}
miniq_construct() {
  local name encoded filter miniq_quoted
  while (($#)); do
    case $1 in
      -cn|-nc) shift ;;
      --arg|--argjson)
        (($#>=3)) || return 1
        name=$2
        [[ $name =~ ^[a-zA-Z_][a-zA-Z_0-9]*$ ]] || return 1
        if [[ $1 == --arg ]]; then
          ((${#3}<=8192)) || return 1
          miniq_quote "$3"; encoded=$miniq_quoted
        else
          # Containers and nonintegral numbers go through the validating parser.
          case $3 in true|false|null|'[]'|'{}') encoded=$3 ;;
            *) [[ $3 =~ ^-?(0|[1-9][0-9]{0,14})$ ]] || return 1; encoded=$3 ;;
          esac
        fi
        local "miniq_arg_$name"
        printf -v "miniq_arg_$name" '%s' "$encoded"
        shift 3 ;;
      -*) return 1 ;;
      *) filter=$1; shift; (($#==0)) || return 1 ;;
    esac
  done
  case ${filter-} in
    '[]')
      printf '%s' '[]'; printf '\n'; return 0 ;;
    '[
    {type:"function",function:{name:"read",description:"Read a text file, attach an image no larger than 1 MiB, or list a directory.",parameters:{type:"object",properties:{path:{type:"string",description:"Absolute path or path relative to the working directory"},offset:{type:"integer",minimum:1,description:"First line to read (default 1)"},limit:{type:"integer",minimum:1,maximum:2000,description:"Maximum lines or directory entries (default 250)"}},required:["path"],additionalProperties:false}}},
    {type:"function",function:{name:"shell",description:"Run a shell command in the working directory. Use for searching, editing files, building, and testing.",parameters:{type:"object",properties:{command:{type:"string",description:"Shell command to execute through Bash"}},required:["command"],additionalProperties:false}}}
  ]')
      printf '%s' '[{"type":"function","function":{"name":"read","description":"Read a text file, attach an image no larger than 1 MiB, or list a directory.","parameters":{"type":"object","properties":{"path":{"type":"string","description":"Absolute path or path relative to the working directory"},"offset":{"type":"integer","minimum":1,"description":"First line to read (default 1)"},"limit":{"type":"integer","minimum":1,"maximum":2000,"description":"Maximum lines or directory entries (default 250)"}},"required":["path"],"additionalProperties":false}}},{"type":"function","function":{"name":"shell","description":"Run a shell command in the working directory. Use for searching, editing files, building, and testing.","parameters":{"type":"object","properties":{"command":{"type":"string","description":"Shell command to execute through Bash"}},"required":["command"],"additionalProperties":false}}}]'; printf '\n'; return 0 ;;
    '{}')
      printf '%s' '{}'; printf '\n'; return 0 ;;
    '{tools:$tools,tool_choice:"auto",parallel_tool_calls:false}')
      [[ ${miniq_arg_tools+set} ]] || return 1
      printf '%s' '{"tools":' "$miniq_arg_tools" ',"tool_choice":"auto","parallel_tool_calls":false}'; printf '\n'; return 0 ;;
    '{reasoning:{effort:$e}}')
      [[ ${miniq_arg_e+set} ]] || return 1
      printf '%s' '{"reasoning":{"effort":' "$miniq_arg_e" '}}'; printf '\n'; return 0 ;;
    '{previous_response_id:$id}')
      [[ ${miniq_arg_id+set} ]] || return 1
      printf '%s' '{"previous_response_id":' "$miniq_arg_id" '}'; printf '\n'; return 0 ;;
    '{tools:$tools,tool_choice:{type:"auto"}}')
      [[ ${miniq_arg_tools+set} ]] || return 1
      printf '%s' '{"tools":' "$miniq_arg_tools" ',"tool_choice":{"type":"auto"}}'; printf '\n'; return 0 ;;
    '{"thinking":{"type":"disabled"}}')
      printf '%s' '{"thinking":{"type":"disabled"}}'; printf '\n'; return 0 ;;
    '{thinking:{type:"adaptive"},output_config:{effort:$e}}')
      [[ ${miniq_arg_e+set} ]] || return 1
      printf '%s' '{"thinking":{"type":"adaptive"},"output_config":{"effort":' "$miniq_arg_e" '}}'; printf '\n'; return 0 ;;
    '{role:"user",content:$prompt}')
      [[ ${miniq_arg_prompt+set} ]] || return 1
      printf '%s' '{"role":"user","content":' "$miniq_arg_prompt" '}'; printf '\n'; return 0 ;;
    '[{role:"user",content:[{type:"input_text",text:$text}]}]')
      [[ ${miniq_arg_text+set} ]] || return 1
      printf '%s' '[{"role":"user","content":[{"type":"input_text","text":' "$miniq_arg_text" '}]}]'; printf '\n'; return 0 ;;
    '{kind:"error",text:$t}')
      [[ ${miniq_arg_t+set} ]] || return 1
      printf '%s' '{"kind":"error","text":' "$miniq_arg_t" '}'; printf '\n'; return 0 ;;
    '{kind:"error",text:"PDF files are not supported by the read tool."}')
      printf '%s' '{"kind":"error","text":"PDF files are not supported by the read tool."}'; printf '\n'; return 0 ;;
    '{kind:"text",text:$text}')
      [[ ${miniq_arg_text+set} ]] || return 1
      printf '%s' '{"kind":"text","text":' "$miniq_arg_text" '}'; printf '\n'; return 0 ;;
    '{kind:"text",text:$text,exit_status:$status}')
      [[ ${miniq_arg_text+set} ]] || return 1
      [[ ${miniq_arg_status+set} ]] || return 1
      printf '%s' '{"kind":"text","text":' "$miniq_arg_text" ',"exit_status":' "$miniq_arg_status" '}'; printf '\n'; return 0 ;;
    '{stdout:$stdout,stderr:$stderr,outcome:{type:"timeout"}}')
      [[ ${miniq_arg_stdout+set} ]] || return 1
      [[ ${miniq_arg_stderr+set} ]] || return 1
      printf '%s' '{"stdout":' "$miniq_arg_stdout" ',"stderr":' "$miniq_arg_stderr" ',"outcome":{"type":"timeout"}}'; printf '\n'; return 0 ;;
    '{stdout:$stdout,stderr:$stderr,outcome:{type:"exit",exit_code:$status}}')
      [[ ${miniq_arg_stdout+set} ]] || return 1
      [[ ${miniq_arg_stderr+set} ]] || return 1
      [[ ${miniq_arg_status+set} ]] || return 1
      printf '%s' '{"stdout":' "$miniq_arg_stdout" ',"stderr":' "$miniq_arg_stderr" ',"outcome":{"type":"exit","exit_code":' "$miniq_arg_status" '}}'; printf '\n'; return 0 ;;
    '{type:"function_call_output",call_id:$id,output:$output}')
      [[ ${miniq_arg_id+set} ]] || return 1
      [[ ${miniq_arg_output+set} ]] || return 1
      printf '%s' '{"type":"function_call_output","call_id":' "$miniq_arg_id" ',"output":' "$miniq_arg_output" '}'; printf '\n'; return 0 ;;
    '{kind:"error",text:"read requires path"}')
      printf '%s' '{"kind":"error","text":"read requires path"}'; printf '\n'; return 0 ;;
    '{kind:"error",text:"shell requires command"}')
      printf '%s' '{"kind":"error","text":"shell requires command"}'; printf '\n'; return 0 ;;
    '{role:"tool",tool_call_id:$id,name:$name,content:$text}')
      [[ ${miniq_arg_id+set} ]] || return 1
      [[ ${miniq_arg_name+set} ]] || return 1
      [[ ${miniq_arg_text+set} ]] || return 1
      printf '%s' '{"role":"tool","tool_call_id":' "$miniq_arg_id" ',"name":' "$miniq_arg_name" ',"content":' "$miniq_arg_text" '}'; printf '\n'; return 0 ;;
    '{type:"tool_result",tool_use_id:$id,content:$text}')
      [[ ${miniq_arg_id+set} ]] || return 1
      [[ ${miniq_arg_text+set} ]] || return 1
      printf '%s' '{"type":"tool_result","tool_use_id":' "$miniq_arg_id" ',"content":' "$miniq_arg_text" '}'; printf '\n'; return 0 ;;
    '{provider:$provider,model:$model,fallback_model:$fallback_model,reasoning:$reasoning,answer:$answer}')
      [[ ${miniq_arg_provider+set} ]] || return 1
      [[ ${miniq_arg_model+set} ]] || return 1
      [[ ${miniq_arg_fallback_model+set} ]] || return 1
      [[ ${miniq_arg_reasoning+set} ]] || return 1
      [[ ${miniq_arg_answer+set} ]] || return 1
      printf '%s' '{"provider":' "$miniq_arg_provider" ',"model":' "$miniq_arg_model" ',"fallback_model":' "$miniq_arg_fallback_model" ',"reasoning":' "$miniq_arg_reasoning" ',"answer":' "$miniq_arg_answer" '}'; printf '\n'; return 0 ;;
  esac
  return 1
}
miniagent_jq() {
  local LC_ALL=C
  export LC_ALL
  local arg
  case ${1-} in -cn|-nc) miniq_construct "$@" && return 0 ;; esac
  for arg in "$@"; do
    if [[ ${#arg} -ge 65536 ]]; then
      # Linux limits individual exec arguments to ~128 KiB. Large histories and
      # image attachments can exceed that, so pass a length-prefixed argument
      # stream through a descriptor. Byte lengths are measured in the C locale.
      miniq_awk --miniq-args-file <(for arg in "$@"; do printf '%s\n%s' "${#arg}" "$arg"; done)
      return $?
    fi
  done
  miniq_awk "$@"
}
miniq_awk() {
  awk -- '
# Minimal jq evaluator for the filters in miniagent.sh. MIT license.
# JSON values and syntax nodes use integer handles. Unchanged values are shared.
function die(msg) { print "miniq: " msg > "/dev/stderr"; exit EC }
function bad(msg) { if (optional) { failed=1; return 0 } die(msg) }
function value(t,v, n) { n=++NV; T[n]=t; V[n]=v; return n }
function arr() { return value("array","") }
function push(a,v) { A[a,++L[a]]=v }
function put(a,k,v, i) {
  if (!((a,k) in O)) { i=++L[a]; K[a,i]=k; O[a,k]=i }
  A[a,O[a,k]]=v; delete Cache[a]
}
function get(a,k) { return ((a,k) in O) ? A[a,O[a,k]] : Null }
function one(v, a) { a=arr(); push(a,v); return a }
function append(a,b, i) { for(i=1;i<=L[b];i++)push(a,A[b,i]);return a }
function truth(v) { return T[v]!="null" && !(T[v]=="boolean" && !V[v]) }
function hex(s, i,n,c) { n=0;for(i=1;i<=length(s);i++){c=index("0123456789abcdef",tolower(substr(s,i,1)))-1;if(c<0)die("invalid Unicode escape");n=n*16+c}return n }
function utf8(n) {
  if(n==0)die("NUL characters are unsupported")
  if(n<128)return sprintf("%c",n)
  if(n<2048)return sprintf("%c%c",192+int(n/64),128+n%64)
  if(n<65536)return sprintf("%c%c%c",224+int(n/4096),128+int(n/64)%64,128+n%64)
  return sprintf("%c%c%c%c",240+int(n/262144),128+int(n/4096)%64,128+int(n/64)%64,128+n%64)
}
function unquote(s, out,i,c,h,low) {
  s=substr(s,2,length(s)-2);out=""
  while((i=index(s,"\\"))){out=out substr(s,1,i-1);c=substr(s,i+1,1);s=substr(s,i+2)
    if(c=="u") {h=hex(substr(s,1,4));s=substr(s,5)
      if(h>=55296&&h<=56319){if(substr(s,1,2)!="\\u")die("unpaired high surrogate");low=hex(substr(s,3,4));if(low<56320||low>57343)die("invalid low surrogate");s=substr(s,7);h=65536+(h-55296)*1024+low-56320}
      else if(h>=56320&&h<=57343)die("unpaired low surrogate")
      out=out utf8(h)
    } else if(c=="n")out=out "\n";else if(c=="r")out=out "\r";else if(c=="t")out=out "\t";else if(c=="b")out=out sprintf("%c",8);else if(c=="f")out=out sprintf("%c",12);else if(c=="\\"||c=="/"||c=="\"")out=out c;else die("invalid string escape")
  }return out s
}
function quote(s, out,i,c) {
  if(s!~/["\\\001-\037]/)return "\"" s "\""
  # Concatenation avoids implementation-specific gsub replacement backslashes.
  out="\""
  while(match(s,/["\\\001-\037]/)) {
    i=RSTART;c=substr(s,i,1);out=out substr(s,1,i-1) Escape[c];s=substr(s,i+1)
  }
  return out s "\""
}
function spaces(n, s) { s="";while(n-->0)s=s " ";return s }
function render(v,pretty,level, out,i,k,sep) {
  if(!pretty && v in Cache)return Cache[v]
  if(T[v]=="null")return "null"
  if(T[v]=="boolean")return V[v]?"true":"false"
  if(T[v]=="number")return V[v]
  if(T[v]=="string") {out=quote(V[v]);if(!pretty)Cache[v]=out;return out}
  out=(T[v]=="array"?"[":"{");sep=""
  for(i=1;i<=L[v];i++){
    out=out sep (pretty?"\n" spaces(level+2):"")
    if(T[v]=="object")out=out quote(K[v,i]) (pretty?": ":":")
    out=out render(A[v,i],pretty,level+2);sep=","
  }
  out=out (pretty&&L[v]?"\n" spaces(level):"") (T[v]=="array"?"]":"}")
  if(!pretty)Cache[v]=out;return out
}
function number(n) { return value("number",sprintf("%.17g",n)) }
function jspace( c) {while((c=substr(JS,JP,1))!="" && c~/[ \t\r\n]/)JP++}
function jparse( c,n,k,start,tail,raw) {
  if(++JD>512)die("JSON nesting limit exceeded")
  jspace();c=substr(JS,JP,1)
  if(c=="\"") {
    tail=substr(JS,JP)
    if(!match(tail,/^"[^"\\]*"/) && !match(tail,/^"([^"\\]|\\["\\\/bfnrt]|\\u[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])*"/))die("invalid JSON string")
    raw=substr(tail,1,RLENGTH);JP+=RLENGTH
    if(raw~/[\001-\037]/)die("unescaped control character")
    n=value("string",unquote(raw))
  } else if(c=="["||c=="{") {
    JP++;n=value(c=="["?"array":"object","");jspace()
    if(substr(JS,JP,1)==(c=="["?"]":"}"))JP++
    else while(1){
      if(c=="{"){k=jparse();if(T[k]!="string")die("object key must be a string");jspace();if(substr(JS,JP++,1)!=":")die("expected colon");put(n,V[k],jparse())}
      else push(n,jparse())
      jspace();k=substr(JS,JP++,1);if(k==(c=="["?"]":"}"))break;if(k!=",")die("expected comma or closing bracket")
    }
  } else {
    tail=substr(JS,JP)
    if(match(tail,/^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?/)){raw=substr(tail,1,RLENGTH);JP+=RLENGTH;n=value("number",raw)}
    else if(substr(tail,1,4)=="null"){JP+=4;n=Null}
    else if(substr(tail,1,4)=="true"){JP+=4;n=True}
    else if(substr(tail,1,5)=="false"){JP+=5;n=False}
    else die("invalid JSON at byte " JP)
    # A literal closing bracket must come first in a portable bracket expression.
    if(JP<=length(JS) && substr(JS,JP,1)!~/[] \t\r\n,}]/)die("invalid JSON token at byte " JP)
  }
  JD--;return n
}
function parsejson(s,stream, n,a) {JS=s;JP=1;JD=0;if(stream)a=arr();jspace();while(JP<=length(JS)){n=jparse();if(!stream){jspace();if(JP<=length(JS))die("extra JSON input");return n}push(a,n);jspace()}if(!stream)die("empty JSON input");return a}
# Source lexer / recursive descent parser. No eval or shell code generation.
function lex(s, tail,t) {
  NT=0
  while(length(s)){
    if(match(s,/^[ \t\r\n]+/)){s=substr(s,RLENGTH+1);continue}
    if(substr(s,1,1)=="#"){sub(/^[^\n]*/,"",s);continue}
    if(substr(s,1,1)=="\""){
      if(!match(s,/^"([^"\\]|\\.)*"/))die("unterminated filter string")
      t=substr(s,1,RLENGTH);s=substr(s,RLENGTH+1);Tok[++NT]="literal";Lit[NT]=value("string",unquote(t));continue
    }
    if(match(s,/^[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?/)){t=substr(s,1,RLENGTH);s=substr(s,RLENGTH+1);Tok[++NT]="literal";Lit[NT]=value("number",t);continue}
    if(match(s,/^[$@]?[A-Za-z_][A-Za-z_0-9]*/)){Tok[++NT]=substr(s,1,RLENGTH);s=substr(s,RLENGTH+1);continue}
    t=substr(s,1,2);if(t=="//"||t=="=="||t=="!="||t=="<="||t==">="||t=="+="){Tok[++NT]=t;s=substr(s,3)}else{Tok[++NT]=substr(s,1,1);s=substr(s,2)}
  }Tok[++NT]="EOF";TP=1
}
function eat(t) {if(Tok[TP]!=t)return 0;TP++;return 1}
function need(t) {if(!eat(t))die("expected " t ", got " Tok[TP])}
function node(op,a,b,c,name, n) {n=++NN;Op[n]=op;C[n,1]=a;C[n,2]=b;C[n,3]=c;Name[n]=name;return n}
function prec(t) {return t=="|"||t=="as"?1:t==","?2:t=="+="?3:t=="//"?4:t=="or"?5:t=="and"?6:t=="=="||t=="!="||t=="<"||t==">"||t=="<="||t==">="?7:t=="+"||t=="-"?8:t=="*"?9:0}
function expr(min, n,op,pr,v,r) {
  n=primary()
  while(prec(Tok[TP])>=min){op=Tok[TP++];pr=prec(op)
    if(op=="as"){v=Tok[TP++];if(substr(v,1,1)!="$")die("expected variable");need("|");r=expr(1);n=node("bind",n,r,0,v)}
    else{r=expr(pr+(op=="//"?0:1));n=node(op,n,r)}
  }return n
}
function conditional( cond,yes,no) {cond=expr(1);need("then");yes=expr(1);if(eat("elif"))no=conditional();else{need("else");no=expr(1);need("end")}return node("if",cond,yes,no)}
function primary( n,name,k,b,e,i) {
  if(++PD>512)die("filter nesting limit exceeded")
  if(eat("def")){name=Tok[TP++];need(":");Defs[name]=expr(1);need(";");n=expr(1);PD--;return n}
  if(eat("if")){n=conditional();PD--;return n}
  if(eat("(")){n=expr(1);need(")")}
  else if(eat("[")){n=node("array");if(!eat("]")){C[n,1]=expr(1);need("]")}}
  else if(eat("{")){n=node("object");if(!eat("}")){i=0;do{k=(Tok[TP]=="literal"?V[Lit[TP]]:Tok[TP]);TP++;need(":");NK[n,++i]=k;C[n,i]=expr(3)}while(eat(","));need("}");NC[n]=i}}
  else if(eat(".")){n=node("id");if(Tok[TP]~/^[A-Za-z_]/ && Tok[TP]!~/^(EOF|as|then|else|elif|end)$/ && !prec(Tok[TP]))n=node("field",n,0,0,Tok[TP++])}
  else if(eat("-"))n=node("neg",primary())
  else if(Tok[TP]=="literal"){n=node("lit",0,0,0,Lit[TP++])}
  else {name=Tok[TP++];if(name=="null"||name=="true"||name=="false")n=node("lit",0,0,0,name=="null"?Null:name=="true"?True:False)
    else if(substr(name,1,1)=="$")n=node("var",0,0,0,name)
    else {
      if(!(name in Defs) && index("|empty|not|type|length|tojson|tostring|tonumber|floor|ascii_upcase|first|last|to_entries|select|map|any|join|startswith|contains|has|test|", "|" name "|")==0)die("unsupported filter " name)
      n=node("call",0,0,0,name);if(eat("(")){i=0;do{C[n,++i]=expr(1)}while(eat(";"));need(")");NC[n]=i}
    }
  }
  while(1){
    if(eat("."))n=node("field",n,0,0,Tok[TP++])
    else if(eat("[")){if(eat("]"))n=node("each",n);else{b=0;e=0;if(Tok[TP]!=":")b=expr(1);if(eat(":")){if(Tok[TP]!="]")e=expr(1);n=node("slice",n,b,e)}else n=node("index",n,b);need("]")}}
    else if(eat("?"))n=node("optional",n);else break
  }PD--;return n
}
function envget(e,name) {while(e){if(EN[e]==name)return EV[e];e=EP[e]}if(name in Vars)return Vars[name];return bad("undefined variable " name)}
function bind(e,name,v, n) {n=++NE;EP[n]=e;EN[n]=name;EV[n]=v;return n}
function copy(v, n,i) {n=value(T[v],V[v]);for(i=1;i<=L[v];i++)if(T[v]=="object")put(n,K[v,i],A[v,i]);else push(n,A[v,i]);return n}
function add(a,b, r,i) {
  if(T[a]=="null")return b;if(T[b]=="null")return a
  if(T[a]!=T[b])return bad("incompatible operands for +")
  if(T[a]=="string")return value("string",V[a] V[b])
  if(T[a]=="number")return number(V[a]+V[b])
  if(T[a]=="array"){r=copy(a);append(r,b);return r}
  if(T[a]=="object"){r=copy(a);for(i=1;i<=L[b];i++)put(r,K[b,i],A[b,i]);return r}
  return bad("unsupported addition")
}
function equal(a,b, i,k) {
  if(T[a]!=T[b])return 0
  if(T[a]=="number")return (V[a]+0)==(V[b]+0)
  if(T[a]!="array"&&T[a]!="object")return (V[a] "x")== (V[b] "x")
  if(L[a]!=L[b])return 0
  for(i=1;i<=L[a];i++){if(T[a]=="array"){if(!equal(A[a,i],A[b,i]))return 0}else{k=K[a,i];if(!((b,k) in O)||!equal(A[a,i],get(b,k)))return 0}}return 1
}
function compare(a,b, x,y) {if(T[a]=="number"&&T[b]=="number")return (V[a]+0)<(V[b]+0)?-1:(V[a]+0)>(V[b]+0)?1:0;x=V[a] "x";y=V[b] "x";return x<y?-1:x>y?1:0}
function ulen(s) {gsub(/[\200-\277]/,"",s);return length(s)}
function uslice(s,b,e, i,n,start,stop,c) {n=0;start=length(s)+1;stop=length(s)+1;for(i=1;i<=length(s);i++){c=substr(s,i,1);if(c!~/[\200-\277]/){if(n==b)start=i;if(n==e){stop=i;break}n++}}return substr(s,start,stop-start)}
function boundary(n,input,e,len,fallback, r,i) {if(!n)return fallback;r=eval(n,input,e);if(L[r]!=1||T[A[r,1]]!="number")return bad("invalid slice bound");i=V[A[r,1]]+0;if(i<0)i+=len;return i<0?0:i>len?len:i}
function update(root,path,rhs,input,e, op,base,r,ks,k,i,v) {
  op=Op[path];if(op=="id")return add(root,rhs)
  # Resolve a simple field/index chain, cloning only the containers on that path.
  if(op!="field"&&op!="index")return bad("unsupported update path")
  base=eval(C[path,1],root,e);if(L[base]!=1)return bad("ambiguous update path");v=A[base,1]
  if(op=="field"){k=Name[path];r=copy(v);if(T[r]=="null")T[r]="object";if(T[r]!="object")return bad("invalid field update");put(r,k,add(get(r,k),rhs))}
  else{ks=eval(C[path,2],input,e);if(L[ks]!=1||T[v]!="array")return bad("invalid array update");i=V[A[ks,1]]+0;if(i<0)i+=L[v];if(i<0||i>=L[v])return bad("update index out of bounds");r=copy(v);A[r,i+1]=add(A[r,i+1],rhs)}
  return replace(root,C[path,1],r,input,e)
}
function replace(root,path,replacement,input,e, base,ks,k,i,r,v) {
  if(Op[path]=="id")return replacement
  base=eval(C[path,1],root,e);v=A[base,1];r=copy(v)
  if(Op[path]=="field")put(r,Name[path],replacement)
  else if(Op[path]=="index"){ks=eval(C[path,2],input,e);i=V[A[ks,1]]+0;if(i<0)i+=L[r];A[r,i+1]=replacement}
  else return bad("unsupported assignment path")
  return replace(root,C[path,1],r,input,e)
}
function eval(n,input,e, op,r,left,right,i,j,a,b,k,tmp,len,start,end,v,x,oldfailed) {
  if(++ED>512)die("evaluation nesting limit exceeded")
  op=Op[n];r=arr()
  if(op=="lit")push(r,Name[n])
  else if(op=="id")push(r,input)
  else if(op=="var")push(r,envget(e,Name[n]))
  else if(op=="|"){left=eval(C[n,1],input,e);for(i=1;i<=L[left];i++)append(r,eval(C[n,2],A[left,i],e))}
  else if(op==","){append(r,eval(C[n,1],input,e));append(r,eval(C[n,2],input,e))}
  else if(op=="bind"){left=eval(C[n,1],input,e);for(i=1;i<=L[left];i++)append(r,eval(C[n,2],input,bind(e,Name[n],A[left,i])))}
  else if(op=="//"){left=eval(C[n,1],input,e);for(i=1;i<=L[left];i++)if(truth(A[left,i]))push(r,A[left,i]);if(!L[r])append(r,eval(C[n,2],input,e))}
  else if(op=="optional"){oldfailed=failed;failed=0;optional++;tmp=eval(C[n,1],input,e);optional--;for(i=1;i<=L[tmp];i++)if(A[tmp,i])push(r,A[tmp,i]);failed=oldfailed}
  else if(op=="if"){left=eval(C[n,1],input,e);for(i=1;i<=L[left];i++)append(r,eval(C[n,truth(A[left,i])?2:3],input,e))}
  else if(op=="array"){a=arr();if(C[n,1])append(a,eval(C[n,1],input,e));push(r,a)}
  else if(op=="object"){
    push(r,value("object",""));for(i=1;i<=NC[n];i++){left=eval(C[n,i],input,e);tmp=arr();for(j=1;j<=L[r];j++)for(k=1;k<=L[left];k++){a=copy(A[r,j]);put(a,NK[n,i],A[left,k]);push(tmp,a)}r=tmp}
  }
  else if(op=="field"){left=eval(C[n,1],input,e);for(i=1;i<=L[left];i++){a=A[left,i];if(T[a]=="object"||T[a]=="null")push(r,get(a,Name[n]));else bad("cannot index " T[a] " with " Name[n])}}
  else if(op=="each"){left=eval(C[n,1],input,e);for(i=1;i<=L[left];i++){a=A[left,i];if(T[a]!="array"&&T[a]!="object")bad("cannot iterate " T[a]);else for(j=1;j<=L[a];j++)push(r,A[a,j])}}
  else if(op=="index"){
    left=eval(C[n,1],input,e);right=eval(C[n,2],input,e);for(i=1;i<=L[left];i++)for(j=1;j<=L[right];j++){a=A[left,i];b=A[right,j]
      if(T[a]=="null")push(r,Null);else if(T[a]=="object"&&T[b]=="string")push(r,get(a,V[b]));else if(T[a]=="array"&&T[b]=="number"){k=V[b]+0;if(k<0)k+=L[a];push(r,k<0||k>=L[a]?Null:A[a,k+1])}else bad("invalid index")
    }
  }
  else if(op=="slice"){
    left=eval(C[n,1],input,e);for(i=1;i<=L[left];i++){a=A[left,i];if(T[a]=="null"){push(r,Null);continue}if(T[a]!="string"&&T[a]!="array"){bad("invalid slice");continue}
      len=T[a]=="array"?L[a]:ulen(V[a]);start=boundary(C[n,2],input,e,len,0);end=boundary(C[n,3],input,e,len,len);if(end<start)end=start
      if(T[a]=="string")push(r,value("string",uslice(V[a],start,end)));else{b=arr();for(j=start+1;j<=end;j++)push(b,A[a,j]);push(r,b)}
    }
  }
  else if(op=="+="){right=eval(C[n,2],input,e);for(i=1;i<=L[right];i++)push(r,update(input,C[n,1],A[right,i],input,e))}
  else if(op=="neg"){left=eval(C[n,1],input,e);for(i=1;i<=L[left];i++){if(T[A[left,i]]!="number")bad("invalid negation");else push(r,number(-V[A[left,i]]))}}
  else if(op=="call")r=call(n,input,e)
  else {
    left=eval(C[n,1],input,e)
    for(i=1;i<=L[left];i++){a=A[left,i]
      if(op=="and"&&!truth(a)){push(r,False);continue}if(op=="or"&&truth(a)){push(r,True);continue}
      right=eval(C[n,2],input,e)
      for(j=1;j<=L[right];j++){b=A[right,j]
        if(op=="+")push(r,add(a,b))
        else if(op=="-"||op=="*"){if(T[a]!="number"||T[b]!="number")bad("invalid arithmetic");else push(r,number(op=="-"?V[a]-V[b]:V[a]*V[b]))}
        else {if(op=="=="||op=="!="){x=equal(a,b);if(op=="!=")x=!x}
          else if(op=="and"||op=="or")x=truth(b)
          else{v=compare(a,b);if(op=="<")x=v<0;else if(op==">")x=v>0;else if(op=="<=")x=v<=0;else if(op==">=")x=v>=0;else bad("unsupported operator " op)}
          push(r,x?True:False)
        }
      }
    }
  }
  ED--;return r
}
function contains(a,b, i,j,found,k) {
  if(T[a]=="string"&&T[b]=="string")return index(V[a],V[b])>0
  if(T[a]=="array"&&T[b]=="array"){for(i=1;i<=L[b];i++){found=0;for(j=1;j<=L[a];j++)if(contains(A[a,j],A[b,i])){found=1;break}if(!found)return 0}return 1}
  if(T[a]=="object"&&T[b]=="object"){for(i=1;i<=L[b];i++){k=K[b,i];if(!((a,k) in O)||!contains(get(a,k),A[b,i]))return 0}return 1}return equal(a,b)
}
function call(n,input,e, name,r,args,a,b,i,j,s,sep,tmp,x,pat,flags) {
  name=Name[n];r=arr()
  if(name in Defs)return eval(Defs[name],input,e)
  if(name=="empty")return r
  if(name=="not")return one(truth(input)?False:True)
  if(name=="type")return one(value("string",T[input]))
  if(name=="length"){if(T[input]=="null")x=0;else if(T[input]=="string")x=ulen(V[input]);else if(T[input]=="array"||T[input]=="object")x=L[input];else if(T[input]=="number")x=V[input]<0?-V[input]:V[input];else return bad("invalid length");return one(number(x))}
  if(name=="tojson")return one(value("string",render(input,0,0)))
  if(name=="tostring")return one(T[input]=="string"?input:value("string",render(input,0,0)))
  if(name=="tonumber"){if(T[input]=="number")return one(input);if(T[input]=="string"&&V[input]~/^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$/)return one(number(V[input]+0));return bad("invalid tonumber")}
  if(name=="floor"){if(T[input]!="number")return bad("invalid floor");x=int(V[input]);if(x>V[input])x--;return one(number(x))}
  if(name=="ascii_upcase"){if(T[input]!="string")return bad("invalid ascii_upcase");return one(value("string",toupper(V[input])))}
  if(name=="first"||name=="last"){if(T[input]!="array")return bad("invalid first/last");return one(!L[input]?Null:A[input,name=="first"?1:L[input]])}
  if(name=="to_entries"){if(T[input]!="array"&&T[input]!="object")return bad("invalid to_entries");a=arr();for(i=1;i<=L[input];i++){b=value("object","");put(b,"key",T[input]=="array"?number(i-1):value("string",K[input,i]));put(b,"value",A[input,i]);push(a,b)}return one(a)}
  if(name=="select"){args=eval(C[n,1],input,e);for(i=1;i<=L[args];i++)if(truth(A[args,i]))push(r,input);return r}
  if(name=="map"){if(T[input]!="array"&&T[input]!="object")return bad("invalid map");a=arr();for(i=1;i<=L[input];i++)append(a,eval(C[n,1],A[input,i],e));return one(a)}
  if(name=="any"){args=eval(C[n,1],input,e);for(i=1;i<=L[args];i++){tmp=eval(C[n,2],A[args,i],e);for(j=1;j<=L[tmp];j++)if(truth(A[tmp,j]))return one(True)}return one(False)}
  if(name=="join"){if(T[input]!="array")return bad("invalid join");args=eval(C[n,1],input,e);for(i=1;i<=L[args];i++){s="";sep="";for(j=1;j<=L[input];j++){a=A[input,j];if(T[a]=="array"||T[a]=="object")return bad("join of container");s=s sep (T[a]=="string"?V[a]:T[a]=="null"?"":render(a,0,0));sep=V[A[args,i]]}push(r,value("string",s))}return r}
  if(name=="startswith"||name=="contains"||name=="has"){args=eval(C[n,1],input,e);for(i=1;i<=L[args];i++){a=A[args,i];if(name=="contains")x=contains(input,a);else if(name=="startswith"){if(T[input]!="string"||T[a]!="string")return bad("invalid startswith");x=index(V[input],V[a])==1}else if(T[input]=="object")x=((input,V[a]) in O);else if(T[input]=="array")x=V[a]>=0&&V[a]<L[input];else x=0;push(r,x?True:False)}return r}
  if(name=="test"){if(T[input]!="string")return bad("test requires string");args=eval(C[n,1],input,e);flags="";if(C[n,2]){tmp=eval(C[n,2],input,e);flags=V[A[tmp,1]];if(flags!=""&&flags!="i")return bad("only regex flag i supported")}
    for(i=1;i<=L[args];i++){pat=V[A[args,i]];s=V[input];if(flags=="i"){pat=tolower(pat);s=tolower(s)}push(r,s~pat?True:False)}return r
  }
  return bad("unsupported filter " name)
}
# An anchored empty-record regex reads a whole nonempty file, preserving newlines.
# Do not close /dev/stdin: mawk aliases it to its own standard input stream.
function readexact(path, s,line,status,old) {old=RS;RS="^$";s="";while((status=(getline line < path))>0){if(length(s))die("NUL bytes in raw input are unsupported");s=line}if(status<0)die("cannot read " path);if(path!="/dev/stdin")close(path);RS=old;return s}
BEGIN {
  EC=2
  for(ai=1;ai<32;ai++)Escape[sprintf("%c",ai)]=sprintf("\\u%04x",ai)
  Escape["\\"]="\\\\";Escape["\""]="\\\""
  Escape["\n"]="\\n";Escape["\r"]="\\r";Escape["\t"]="\\t";Escape["\b"]="\\b";Escape["\f"]="\\f"
  if(ARGV[1]=="--miniq-args-file") {
    packed=readexact(ARGV[2]);for(ai=1;ai<ARGC;ai++)delete ARGV[ai];ARGC=1
    while(length(packed)) {
      sep=index(packed,"\n");if(!sep)die("invalid argument framing")
      size=substr(packed,1,sep-1);if(size!~/^[0-9]+$/)die("invalid argument length");size+=0
      packed=substr(packed,sep+1);if(size>length(packed))die("truncated argument")
      ARGV[ARGC++]=substr(packed,1,size);packed=substr(packed,size+1)
    }
  }
  Null=value("null","");True=value("boolean",1);False=value("boolean",0);options=1;havefilter=0
  for(ai=1;ai<ARGC;ai++){
    arg=ARGV[ai]
    if(options&&arg=="--"){options=0;continue}
    if(options&&arg=="--version"){print "miniq-0.1 (Bash/awk miniagent subset)";exit 0}
    if(options&&(arg=="--arg"||arg=="--argjson"||arg=="--rawfile"||arg=="--slurpfile")){
      if(ai+2>=ARGC)die(arg " requires name and value");vn="$" ARGV[++ai];av=ARGV[++ai]
      if(arg=="--arg")Vars[vn]=value("string",av);else if(arg=="--argjson")Vars[vn]=parsejson(av,0);else if(arg=="--rawfile")Vars[vn]=value("string",readexact(av));else Vars[vn]=parsejson(readexact(av),1);continue
    }
    if(options&&substr(arg,1,1)=="-"&&arg!="-"){
      if(arg=="--null-input")arg="-n";else if(arg=="--compact-output")arg="-c";else if(arg=="--raw-output")arg="-r";else if(arg=="--raw-input")arg="-R";else if(arg=="--slurp")arg="-s";else if(arg=="--exit-status")arg="-e"
      for(ak=2;ak<=length(arg);ak++){ch=substr(arg,ak,1);if(ch=="n")nullin=1;else if(ch=="c")compact=1;else if(ch=="r")rawout=1;else if(ch=="R")rawin=1;else if(ch=="s")slurp=1;else if(ch=="e")exitstatus=1;else if(ch!="M")die("unsupported option " arg)}continue
    }
    if(!havefilter){filter=arg;havefilter=1}else Files[++NFIL]=arg
  }
  if(!havefilter)filter="."
  EC=3;lex(filter);AST=expr(1);need("EOF")
  EC=5;Inputs=arr()
  if(nullin)push(Inputs,Null)
  else {
    if(!NFIL)Files[++NFIL]="-"
    rawbuf=""
    for(fi=1;fi<=NFIL;fi++){
      data=readexact(Files[fi]=="-"?"/dev/stdin":Files[fi])
      if(rawin){if(slurp)rawbuf=rawbuf data;else{while(index(data,"\n")){idx=index(data,"\n");push(Inputs,value("string",substr(data,1,idx-1)));data=substr(data,idx+1)}if(length(data))push(Inputs,value("string",data))}}
      else append(Inputs,parsejson(data,1))
    }
    if(rawin&&slurp)Inputs=one(value("string",rawbuf));else if(slurp)Inputs=one(Inputs)
  }
  EC=5;status=4
  for(ii=1;ii<=L[Inputs];ii++){Result=eval(AST,A[Inputs,ii],0);for(ri=1;ri<=L[Result];ri++){v=A[Result,ri];if(rawout&&T[v]=="string")printf "%s\n",V[v];else printf "%s\n",render(v,!compact,0);status=truth(v)?0:1}}
  exit exitstatus?status:0
}
  ' "$@"
}

select_json_processor() {
  # Preserve explicit custom paths, including their normal missing-command error.
  if [[ "$JQ_BIN" == "jq" ]] && ! command -v jq >/dev/null 2>&1; then
    JQ_BIN=miniagent_jq
  fi
}
is_uint() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }
queue_interactive_message() {
  local line=$1
  INTERACTIVE_QUEUED_MESSAGES=$("$JQ_BIN" -cn --argjson queued "$INTERACTIVE_QUEUED_MESSAGES" --arg line "$line" \
    '$queued + [$line]')
  history -s "$line" 2>/dev/null || true
  info "${C_CYAN}queued${C_RESET} message"
  debug_log "interactive_message_queued value=$(printf '%q' "$line")"
}
show_interactive_input_prompt() {
  [[ "$INTERACTIVE_CAPTURE_ENABLED" -eq 1 && "$INTERACTIVE_INPUT_CLOSED" -eq 0 ]] || return 0
  printf '\r\033[2K%s(queue) %s%s' "$C_CYAN" "$C_RESET" "$INTERACTIVE_INPUT_BUFFER" >&2
  INTERACTIVE_INPUT_PROMPT_VISIBLE=1
}
hide_interactive_input_prompt() {
  [[ "$INTERACTIVE_INPUT_PROMPT_VISIBLE" -eq 1 ]] || return 0
  printf '\r\033[2K' >&2
  INTERACTIVE_INPUT_PROMPT_VISIBLE=0
}
interactive_stop_requested() {
  [[ "$INTERACTIVE_STOP_REQUESTED" -eq 1 || ( -n "$INTERACTIVE_STOP_FILE" && -s "$INTERACTIVE_STOP_FILE" ) ]]
}
request_interactive_stop() {
  INTERACTIVE_STOP_REQUESTED=1
  [[ -z "$INTERACTIVE_STOP_FILE" ]] || printf '1' > "$INTERACTIVE_STOP_FILE"
}
abort_process() {
  local pid=$1 attempt
  kill -TERM "$pid" 2>/dev/null || true
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.01
  done
  kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}
wait_for_process_interactive() {
  local pid=$1 char input_file
  input_file=$(mktemp "${TMPDIR:-/tmp}/miniagent-input.XXXXXX") || { wait "$pid"; return; }
  show_interactive_input_prompt
  while kill -0 "$pid" 2>/dev/null; do
    if interactive_stop_requested; then
      hide_interactive_input_prompt
      rm -f "$input_file"
      abort_process "$pid"
      return 130
    fi
    : > "$input_file"
    dd bs=1 count=1 > "$input_file" 2>/dev/null
    if [[ -s "$input_file" ]]; then
      char=$(cat "$input_file")
      case "$char" in
        $'\004')
          request_interactive_stop
          INTERACTIVE_INPUT_CLOSED=1
          INTERACTIVE_INPUT_BUFFER=""
          INTERACTIVE_QUEUED_MESSAGES='[]'
          hide_interactive_input_prompt
          info "${C_CYAN}stop${C_RESET} requested; aborting current operation"
          debug_log "interactive_stop_requested source=eof"
          rm -f "$input_file"
          abort_process "$pid"
          return 130
          ;;
        $'\177'|$'\010')
          if [[ -n "$INTERACTIVE_INPUT_BUFFER" ]]; then
            INTERACTIVE_INPUT_BUFFER=${INTERACTIVE_INPUT_BUFFER%?}
            printf '\b \b' >&2
          fi
          ;;
        '')
          printf '\n' >&2
          [[ -n "$INTERACTIVE_INPUT_BUFFER" ]] && queue_interactive_message "$INTERACTIVE_INPUT_BUFFER"
          INTERACTIVE_INPUT_BUFFER=""
          show_interactive_input_prompt
          ;;
        *) INTERACTIVE_INPUT_BUFFER+=$char; printf '%s' "$char" >&2 ;;
      esac
    fi
  done
  hide_interactive_input_prompt
  rm -f "$input_file"
  if interactive_stop_requested; then wait "$pid" 2>/dev/null || true; return 130; fi
  wait "$pid"
}
wait_for_process() {
  local pid=$1
  if [[ "$INTERACTIVE_EXECUTION" -ne 1 || "$INTERACTIVE_CAPTURE_ENABLED" -ne 1 ]]; then wait "$pid"; return; fi
  wait_for_process_interactive "$pid" </dev/tty
}
restore_interactive_terminal() {
  hide_interactive_input_prompt
  if [[ -n "$INTERACTIVE_STTY_STATE" ]]; then stty "$INTERACTIVE_STTY_STATE" 2>/dev/null || true; fi
  INTERACTIVE_STTY_STATE=""
  INTERACTIVE_CAPTURE_ENABLED=0
}
take_interactive_messages() {
  INTERACTIVE_QUEUED_BATCH=$INTERACTIVE_QUEUED_MESSAGES
  INTERACTIVE_QUEUED_MESSAGES='[]'
  INTERACTIVE_QUEUED_COUNT=$(printf '%s' "$INTERACTIVE_QUEUED_BATCH" | "$JQ_BIN" 'length')
}
append_interactive_messages_to_history() {
  local after_tools=${1:-0}
  [[ "$INTERACTIVE_QUEUED_COUNT" -gt 0 ]] || return 0
  if [[ "$PROVIDER" == "anthropic" && "$after_tools" -eq 1 ]]; then
    HISTORY=$("$JQ_BIN" -cn --argjson history "$HISTORY" --argjson queued "$INTERACTIVE_QUEUED_BATCH" \
      '$history | .[-1].content += [$queued[] | {type:"text",text:.}]')
  elif [[ "$PROVIDER" == "anthropic" ]]; then
    HISTORY=$("$JQ_BIN" -cn --argjson history "$HISTORY" --argjson queued "$INTERACTIVE_QUEUED_BATCH" \
      '$history + [{role:"user",content:[$queued[] | {type:"text",text:.}]}]')
  else
    HISTORY=$("$JQ_BIN" -cn --argjson history "$HISTORY" --argjson queued "$INTERACTIVE_QUEUED_BATCH" \
      '$history + [$queued[] | {role:"user",content:.}]')
  fi
  debug_log "interactive_messages_applied provider=$PROVIDER count=$INTERACTIVE_QUEUED_COUNT after_tools=$after_tools"
}
apply_interactive_messages() {
  local after_tools=${1:-0}
  take_interactive_messages
  append_interactive_messages_to_history "$after_tools"
}
debug_log() {
  [[ -n "$DEBUG_LOG" ]] || return 0
  printf '%s pid=%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$$" "$*" >> "$DEBUG_LOG"
}
debug_dump() {
  local label=$1 content=$2 path bytes
  [[ -n "$DEBUG_LOG" ]] || return 0
  path=$(mktemp "$DEBUG_DIR/$label.XXXXXX") || { debug_log "artifact_failed label=$label"; return 1; }
  printf '%s' "$content" > "$path"
  chmod 600 "$path" 2>/dev/null || true
  bytes=$(wc -c < "$path" | tr -d ' ')
  debug_log "artifact label=$label bytes=$bytes path=$path"
}
debug_dump_file() {
  local label=$1 source=$2 path bytes
  [[ -n "$DEBUG_LOG" ]] || return 0
  [[ -f "$source" ]] || { debug_log "artifact_source_missing label=$label source=$source"; return 1; }
  path=$(mktemp "$DEBUG_DIR/$label.XXXXXX") || { debug_log "artifact_failed label=$label"; return 1; }
  cp "$source" "$path" || return 1
  chmod 600 "$path" 2>/dev/null || true
  bytes=$(wc -c < "$path" | tr -d ' ')
  debug_log "artifact label=$label bytes=$bytes path=$path"
}
debug_state() {
  local label=$1 state
  [[ -n "$DEBUG_LOG" ]] || return 0
  state=$("$JQ_BIN" -cn \
    --arg provider "$PROVIDER" --arg model "$MODEL" --arg turn_model "$TURN_MODEL" \
    --arg fallback_model "$FALLBACK_MODEL" --arg reasoning "$REASONING" --arg workdir "$WORKDIR" \
    --arg api_url "${API_URL:-}" --arg previous_response_id "$OPENAI_PREVIOUS_RESPONSE_ID" \
    --arg needs_restart "$OPENAI_NEEDS_RESTART" --arg context_tokens "$CONTEXT_TOKENS" \
    --arg context_known "$CONTEXT_TOKENS_KNOWN" --arg compact_tokens "$COMPACT_TOKENS" \
    --arg history_length "$(printf '%s' "$HISTORY" | "$JQ_BIN" 'length' 2>/dev/null || printf 0)" \
    '{provider:$provider,model:$model,turn_model:$turn_model,fallback_model:$fallback_model,
      reasoning:$reasoning,workdir:$workdir,api_url:$api_url,previous_response_id:$previous_response_id,
      needs_restart:($needs_restart|tonumber),context_tokens:($context_tokens|tonumber),
      context_known:($context_known|tonumber),compact_tokens:($compact_tokens|tonumber),
      history_length:($history_length|tonumber)}') || return 1
  debug_dump "state-$label.json" "$state"
}
init_debug() {
  local arg index=0 meta
  case "$DEBUG" in
    1|true|TRUE|yes|YES|on|ON) DEBUG=1 ;;
    0|false|FALSE|no|NO|off|OFF|'') DEBUG=0; return 0 ;;
    *) die "MINIAGENT_DEBUG must be 0 or 1" ;;
  esac
  if [[ -n "$DEBUG_DIR" ]]; then
    mkdir -p "$DEBUG_DIR" || die "cannot create debug directory: $DEBUG_DIR"
    DEBUG_DIR=$(cd "$DEBUG_DIR" 2>/dev/null && pwd -P) || die "cannot enter debug directory"
  else
    DEBUG_DIR=$(mktemp -d "${TMPDIR:-/tmp}/miniagent-debug.$$.XXXXXX") || die "cannot create debug directory"
  fi
  chmod 700 "$DEBUG_DIR" 2>/dev/null || true
  DEBUG_LOG="$DEBUG_DIR/events.log"
  : > "$DEBUG_LOG"
  chmod 600 "$DEBUG_LOG" 2>/dev/null || true
  printf 'miniagent: debug bundle: %s\n' "$DEBUG_DIR" >&2
  debug_log "session_start ppid=$PPID uid=${UID:-unknown} euid=${EUID:-unknown} bash=${BASH_VERSION:-unknown} cwd=$PWD"
  for arg in "${DEBUG_ARGV[@]}"; do
    debug_log "argv[$index]=$(printf '%q' "$arg")"
    index=$((index + 1))
  done
  meta=$(printf 'script=%s\npid=%s\nppid=%s\nuid=%s\neuid=%s\nbash_version=%s\ncwd=%s\ntmpdir=%s\nuname=%s\n' \
    "${BASH_SOURCE[0]:-$0}" "$$" "$PPID" "${UID:-unknown}" "${EUID:-unknown}" "${BASH_VERSION:-unknown}" "$PWD" "${TMPDIR:-/tmp}" "$(uname -a 2>/dev/null || printf unknown)")
  debug_dump session.txt "$meta"
}
parse_args() {
  local parts=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p|--provider) [[ $# -ge 2 ]] || die "$1 requires a value"; PROVIDER=$2; shift 2 ;;
      -m|--model) [[ $# -ge 2 ]] || die "$1 requires a value"; MODEL=$2; shift 2 ;;
      --fallback-model) [[ $# -ge 2 ]] || die "$1 requires a value"; FALLBACK_MODEL=$2; shift 2 ;;
      -r|--reasoning) [[ $# -ge 2 ]] || die "$1 requires a value"; REASONING=$2; shift 2 ;;
      -C|--chdir) [[ $# -ge 2 ]] || die "$1 requires a value"; WORKDIR=$2; shift 2 ;;
      -n|--max-turns) [[ $# -ge 2 ]] || die "$1 requires a value"; MAX_TURNS=$2; shift 2 ;;
      --max-tokens) [[ $# -ge 2 ]] || die "$1 requires a value"; MAX_TOKENS=$2; shift 2 ;;
      --compact-tokens) [[ $# -ge 2 ]] || die "$1 requires a value"; COMPACT_TOKENS=$2; shift 2 ;;
      --debug) DEBUG=1; shift ;;
      --debug-dir) [[ $# -ge 2 ]] || die "$1 requires a value"; DEBUG=1; DEBUG_DIR=$2; shift 2 ;;
      -i|--interactive) INTERACTIVE=1; shift ;;
      --json) OUTPUT_FORMAT="json"; shift ;;
      -q|--quiet) QUIET=1; shift ;;
      -h|--help) usage; exit 0 ;;
      -v|--version) printf 'miniagent %s\n' "$VERSION"; exit 0 ;;
      --) shift; while [[ $# -gt 0 ]]; do parts+=("$1"); shift; done ;;
      -*) die "unknown option: $1" ;;
      *) parts+=("$1"); shift ;;
    esac
  done
  if [[ ${#parts[@]} -gt 0 ]]; then PROMPT="${parts[*]}"; fi
}
reattach_piped_script_input() {
  [[ ! -t 0 && -z "$SCRIPT_SOURCE" ]] || return 0
  [[ "$INTERACTIVE" -eq 1 || -z "$PROMPT" ]] || return 0
  [[ -t 1 || -t 2 ]] || die "interactive mode requires a terminal (for Docker, allocate one with -it)"
  if [[ -t 2 ]]; then exec 0<&2; else exec 0<&1; fi
}
select_provider() {
  if [[ -z "${OPENAI_API_KEY:-}" && -z "${ANTHROPIC_API_KEY:-}" && -z "${OPENROUTER_API_KEY:-}" ]]; then
    PUBLIC_PROXY=1
    PROVIDER="openrouter"
    MODEL="openrouter/free"
    FALLBACK_MODEL="none"
    TURN_MODEL=""
    OPENROUTER_API_KEY=""
    API_URL="https://miniagent.sh/api"
    OPENROUTER_COMPLETIONS_PATH="/completions"
    return
  fi
  PUBLIC_PROXY=0
  if [[ -z "$PROVIDER" ]]; then
    if [[ -n "${OPENAI_API_KEY:-}" ]]; then PROVIDER="openai"
    elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then PROVIDER="anthropic"
    else PROVIDER="openrouter"
    fi
  fi
  case "$PROVIDER" in
    openai)
      : "${OPENAI_API_KEY:?OPENAI_API_KEY is required}"
      MODEL="${MODEL:-${OPENAI_MODEL:-gpt-5.6-sol}}"
      FALLBACK_MODEL="${FALLBACK_MODEL:-${OPENAI_FALLBACK_MODEL:-gpt-5.6-terra}}"
      API_URL="${OPENAI_BASE_URL:-https://api.openai.com/v1}"
      ;;
    anthropic)
      : "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY is required}"
      MODEL="${MODEL:-${ANTHROPIC_MODEL:-claude-opus-5}}"
      FALLBACK_MODEL="${FALLBACK_MODEL:-${ANTHROPIC_FALLBACK_MODEL:-claude-sonnet-5}}"
      API_URL="${ANTHROPIC_BASE_URL:-https://api.anthropic.com/v1}"
      ;;
    openrouter)
      : "${OPENROUTER_API_KEY:?OPENROUTER_API_KEY is required}"
      MODEL="${MODEL:-${OPENROUTER_MODEL:-openai/gpt-5.6-sol}}"
      FALLBACK_MODEL="${FALLBACK_MODEL:-${OPENROUTER_FALLBACK_MODEL:-openai/gpt-5.6-terra}}"
      API_URL="${OPENROUTER_BASE_URL:-https://openrouter.ai/api/v1}"
      OPENROUTER_COMPLETIONS_PATH="/chat/completions"
      ;;
    *) die "unsupported provider: $PROVIDER" ;;
  esac
  API_URL="${API_URL%/}"
}
validate_config() {
  case "$REASONING" in default|none|minimal|low|medium|high|xhigh|max) ;; *) die "invalid reasoning level: $REASONING" ;; esac
  is_uint "$MAX_TURNS" || die "--max-turns must be a positive integer"
  is_uint "$MAX_TOKENS" || die "--max-tokens must be a positive integer"
  is_uint "$COMPACT_TOKENS" || die "--compact-tokens must be a positive integer"
  is_uint "$COMPACT_MAX_TOKENS" || die "MINIAGENT_COMPACT_MAX_TOKENS must be a positive integer"
  [[ -d "$WORKDIR" ]] || die "working directory does not exist: $WORKDIR"
  WORKDIR=$(cd "$WORKDIR" 2>/dev/null && pwd -P) || die "cannot enter working directory"
}
system_prompt() {
  local os_name machine now tool_guidance sed_note=""
  os_name=$(uname -s 2>/dev/null || printf unknown)
  machine=$(uname -m 2>/dev/null || printf unknown)
  now=$(date '+%Y-%m-%d')
  if [[ "$PROVIDER" == "openai" ]]; then
    tool_guidance="Use the read tool to inspect files, directories, and images. Use the native shell tool for searches, file edits, builds, and tests."
  else
    tool_guidance="Use the read tool to inspect files, directories, and images. Use the shell tool for searches, file edits, builds, and tests."
  fi
  if [[ "$os_name" == "Darwin" ]]; then
    sed_note="<important>
You are on MacOS. For all the below examples, use \`sed -i ''\` instead of \`sed -i\`.
</important>"
  fi
  cat <<PROMPT_EOF
You are miniagent (https://miniagent.sh), a concise, capable software-engineering agent.

<system_information>
$os_name $machine $now $WORKDIR
</system_information>

$tool_guidance Commands run locally in the working directory through Bash. Prefer common portable Unix utilities.

## Useful command examples

### Create a new file:

\`\`\`bash
cat <<'EOF' > newfile.py
import numpy as np
hello = "world"
print(hello)
EOF
\`\`\`

### Edit files with sed:

$sed_note

\`\`\`bash
# Replace all occurrences
sed -i 's/old_string/new_string/g' filename.py

# Replace only first occurrence
sed -i 's/old_string/new_string/' filename.py

# Replace first occurrence on line 1
sed -i '1s/old_string/new_string/' filename.py

# Replace all occurrences in lines 1-10
sed -i '1,10s/old_string/new_string/g' filename.py
\`\`\`

### View file content:

\`\`\`bash
# View specific lines with numbers
nl -ba filename.py | sed -n '10,20p'
\`\`\`

Work autonomously until the task is complete. Inspect before changing, preserve unrelated work, and verify changes. Never claim a command succeeded unless its result says so. Keep final answers brief and include changed files and verification.
Only attribute changes, commands, API calls, and verification to the current user request when they actually occurred during that request. Treat pre-existing working-tree changes as context, not work you performed. For read-only or explanatory requests, do not imply that files were changed.
PROMPT_EOF
}
tools_compatible() {
  "$JQ_BIN" -cn '[
    {type:"function",function:{name:"read",description:"Read a text file, attach an image no larger than 1 MiB, or list a directory.",parameters:{type:"object",properties:{path:{type:"string",description:"Absolute path or path relative to the working directory"},offset:{type:"integer",minimum:1,description:"First line to read (default 1)"},limit:{type:"integer",minimum:1,maximum:2000,description:"Maximum lines or directory entries (default 250)"}},required:["path"],additionalProperties:false}}},
    {type:"function",function:{name:"shell",description:"Run a shell command in the working directory. Use for searching, editing files, building, and testing.",parameters:{type:"object",properties:{command:{type:"string",description:"Shell command to execute through Bash"}},required:["command"],additionalProperties:false}}}
  ]'
}
tools_openai() {
  tools_compatible | "$JQ_BIN" -c '[{type:"shell",environment:{type:"local"}}, (.[0].function + {type:"function"})]'
}
tools_anthropic() {
  tools_compatible | "$JQ_BIN" -c '[.[] | {name:.function.name,description:.function.description,input_schema:.function.parameters}]'
}
api_request() {
  local url=$1 key_header=$2 key=$3 body=$4 response_file status_file status curl_status request_pid
  shift 4
  debug_log "api_request_start provider=$PROVIDER model=${TURN_MODEL:-$MODEL} url=$url previous_response_id=${OPENAI_PREVIOUS_RESPONSE_ID:-none} body_bytes=$(printf '%s' "$body" | wc -c | tr -d ' ') extra_header_args=$#"
  debug_dump api-request.json "$body"
  response_file=$(mktemp "${TMPDIR:-/tmp}/miniagent-response.XXXXXX") || return 1
  status_file=$(mktemp "${TMPDIR:-/tmp}/miniagent-status.XXXXXX") || { rm -f "$response_file"; return 1; }
  "$CURL_BIN" -sS --connect-timeout 20 --max-time "$API_TIMEOUT" \
    -o "$response_file" -w '%{http_code}' -X POST "$url" \
    -H 'content-type: application/json' -H "$key_header: $key" "$@" \
    --data-binary @- <<< "$body" > "$status_file" &
  request_pid=$!
  wait_for_process "$request_pid"
  curl_status=$?
  if interactive_stop_requested; then
    API_RESPONSE=""
    CAPTURED_RESULT=""
    debug_log "api_request_cancelled provider=$PROVIDER model=${TURN_MODEL:-$MODEL} url=$url"
    rm -f "$response_file" "$status_file"
    return 130
  fi
  status=$(<"$status_file")
  API_RESPONSE=$(<"$response_file")
  debug_dump api-response.json "$API_RESPONSE"
  debug_log "api_request_end provider=$PROVIDER model=${TURN_MODEL:-$MODEL} url=$url http_status=$status curl_status=$curl_status response_bytes=$(wc -c < "$response_file" | tr -d ' ')"
  rm -f "$response_file" "$status_file"
  if [[ $curl_status -ne 0 ]]; then
    printf 'network error (curl exit %s)\n' "$curl_status" >&2
    return 1
  fi
  if ! printf '%s' "$API_RESPONSE" | "$JQ_BIN" -e . >/dev/null 2>&1; then
    printf 'API returned invalid JSON\n' >&2
    return 1
  fi
  if [[ ! "$status" =~ ^2 ]]; then
    response_is_refusal && return 2
    printf 'API error HTTP %s: %s\n' "$status" "$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r '.error.message // .error // .' 2>/dev/null)" >&2
    return 1
  fi
}
call_openrouter() {
  local tool_mode=${1:-enabled} body tools reason_args='{}' tool_args='{}' key url
  local extra_headers=(-H "X-Title: ${OPENROUTER_APP_NAME:-miniagent}")
  if [[ "$tool_mode" == "enabled" ]]; then
    tools=$(tools_compatible)
    tool_args=$("$JQ_BIN" -cn --argjson tools "$tools" \
      '{tools:$tools,tool_choice:"auto",parallel_tool_calls:false}')
  fi
  if [[ "$REASONING" != "default" ]]; then
    local effort=$REASONING
    [[ "$effort" == "max" ]] && effort="xhigh"
    reason_args=$("$JQ_BIN" -cn --arg e "$effort" '{reasoning:{effort:$e}}')
  fi
  body=$("$JQ_BIN" -cn --arg model "${TURN_MODEL:-$MODEL}" --arg system "$(system_prompt)" \
    --slurpfile history <(printf '%s\n' "$HISTORY") --argjson tool_args "$tool_args" --argjson extra "$reason_args" \
    --argjson max "$MAX_TOKENS" \
    '({model:$model,messages:([{role:"system",content:$system}] + $history[0]),max_completion_tokens:$max} + $tool_args + $extra)')
  key=$OPENROUTER_API_KEY; url="$API_URL$OPENROUTER_COMPLETIONS_PATH"
  [[ -n "${OPENROUTER_HTTP_REFERER:-}" ]] && extra_headers+=( -H "HTTP-Referer: $OPENROUTER_HTTP_REFERER" )
  [[ -n "${OPENROUTER_APP_NAME:-}" ]] && extra_headers+=( -H "X-Title: $OPENROUTER_APP_NAME" )
  api_request "$url" "authorization" "Bearer $key" "$body" "${extra_headers[@]}" || return 1
  if printf '%s' "$API_RESPONSE" | "$JQ_BIN" -e '.error' >/dev/null 2>&1; then
    printf 'API error: %s\n' "$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r '.error.message // .error')" >&2
    return 1
  fi
}
call_openai_responses() {
  local input=$1 tool_mode=${2:-enabled} body tools reason_args='{}' previous_args='{}' tool_args='{}' effort
  if [[ "$tool_mode" == "enabled" ]]; then
    tools=$(tools_openai)
    tool_args=$("$JQ_BIN" -cn --argjson tools "$tools" \
      '{tools:$tools,tool_choice:"auto",parallel_tool_calls:false}')
  fi
  if [[ "$REASONING" != "default" ]]; then
    effort=$REASONING
    [[ "$effort" == "minimal" ]] && effort="low"
    reason_args=$("$JQ_BIN" -cn --arg e "$effort" '{reasoning:{effort:$e}}')
  fi
  if [[ -n "$OPENAI_PREVIOUS_RESPONSE_ID" ]]; then
    previous_args=$("$JQ_BIN" -cn --arg id "$OPENAI_PREVIOUS_RESPONSE_ID" '{previous_response_id:$id}')
  fi
  body=$("$JQ_BIN" -cn --arg model "${TURN_MODEL:-$MODEL}" --arg instructions "$(system_prompt)" \
    --slurpfile input <(printf '%s\n' "$input") --argjson reason "$reason_args" \
    --argjson previous "$previous_args" --argjson tool_args "$tool_args" --argjson max "$MAX_TOKENS" \
    '({model:$model,instructions:$instructions,input:$input[0],max_output_tokens:$max} + $tool_args + $reason + $previous)')
  api_request "$API_URL/responses" "authorization" "Bearer $OPENAI_API_KEY" "$body" || return 1
  if printf '%s' "$API_RESPONSE" | "$JQ_BIN" -e '.error != null or .status == "failed"' >/dev/null 2>&1; then
    printf 'API error: %s\n' "$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r '.error.message // .error // "response failed"')" >&2
    return 1
  fi
  OPENAI_PREVIOUS_RESPONSE_ID=$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r '.id // empty')
  [[ -n "$OPENAI_PREVIOUS_RESPONSE_ID" ]] || { printf 'API response missing id\n' >&2; return 1; }
}
call_anthropic() {
  local tool_mode=${1:-enabled} body tools thinking='{}' tool_args='{}'
  if [[ "$tool_mode" == "enabled" ]]; then
    tools=$(tools_anthropic)
    tool_args=$("$JQ_BIN" -cn --argjson tools "$tools" '{tools:$tools,tool_choice:{type:"auto"}}')
  fi
  case "$REASONING" in
    default) thinking='{}' ;;
    none) thinking='{"thinking":{"type":"disabled"}}' ;;
    *)
      local effort=$REASONING
      [[ "$effort" == "minimal" ]] && effort="low"
      thinking=$("$JQ_BIN" -cn --arg e "$effort" '{thinking:{type:"adaptive"},output_config:{effort:$e}}')
      ;;
  esac
  body=$("$JQ_BIN" -cn --arg model "${TURN_MODEL:-$MODEL}" --arg system "$(system_prompt)" \
    --slurpfile history <(printf '%s\n' "$HISTORY") --argjson tool_args "$tool_args" --argjson extra "$thinking" \
    --argjson max "$MAX_TOKENS" \
    '({model:$model,system:$system,messages:$history[0],max_tokens:$max} + $tool_args + $extra)')
  api_request "$API_URL/messages" "x-api-key" "$ANTHROPIC_API_KEY" "$body" \
    -H "anthropic-version: ${ANTHROPIC_VERSION:-2023-06-01}" || return 1
  if printf '%s' "$API_RESPONSE" | "$JQ_BIN" -e '.type == "error"' >/dev/null 2>&1; then
    printf 'API error: %s\n' "$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r '.error.message // .error')" >&2
    return 1
  fi
}
response_is_refusal() {
  case "$PROVIDER" in
    anthropic) printf '%s' "$API_RESPONSE" | "$JQ_BIN" -e '.stop_reason == "refusal"' ;;
    openai) printf '%s' "$API_RESPONSE" | "$JQ_BIN" -e '
      any(.output[]?.content[]?; .type == "refusal") or
      (((.error.code // "") | test("content_filter|content_policy|safety|cyber"; "i")) or
       ((.error.message // "") | test("flagged for possible (cybersecurity|safety) risk|blocked by (a |the )?(safety|content) policy"; "i")))' ;;
    openrouter) printf '%s' "$API_RESPONSE" | "$JQ_BIN" -e '.choices[0].finish_reason == "content_filter" or ((.choices[0].message.refusal? // null) as $r | $r != null and $r != "")' ;;
  esac >/dev/null 2>&1
}
refusal_reason() {
  case "$PROVIDER" in
    anthropic) printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r '.stop_details.explanation // "safety refusal"' ;;
    openai) printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r '.error.message // ([.output[]?.content[]? | select(.type == "refusal") | .refusal] | first) // "safety refusal"' ;;
    openrouter) printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r '.choices[0].message.refusal // .choices[0].finish_reason // "safety refusal" | if type == "string" then . else tojson end' ;;
  esac
}
call_with_fallback() {
  local fn=$1 previous=$OPENAI_PREVIOUS_RESPONSE_ID refused reason status=0
  shift
  "$fn" "$@" || status=$?
  if [[ "$status" -ne 0 ]] && ! response_is_refusal; then return "$status"; fi
  response_is_refusal || return 0
  refused=${TURN_MODEL:-$MODEL}; reason=$(refusal_reason)
  interactive_stop_requested && return 130
  if [[ -z "$FALLBACK_MODEL" || "$FALLBACK_MODEL" == "none" || "$FALLBACK_MODEL" == "$refused" ]]; then
    OPENAI_PREVIOUS_RESPONSE_ID=$previous; LAST_ANSWER="Model $refused refused the request: $reason"; printf '%s\n' "$LAST_ANSWER" >&2; return 1
  fi
  info "${C_CYAN}fallback${C_RESET} $refused refused: $reason; retrying with $FALLBACK_MODEL"
  OPENAI_PREVIOUS_RESPONSE_ID=$previous; TURN_MODEL=$FALLBACK_MODEL
  status=0; "$fn" "$@" || status=$?
  if [[ "$status" -ne 0 ]] && ! response_is_refusal; then return "$status"; fi
  if response_is_refusal; then
    OPENAI_PREVIOUS_RESPONSE_ID=$previous; reason=$(refusal_reason); LAST_ANSWER="Fallback model $TURN_MODEL refused the request: $reason"
    printf '%s\n' "$LAST_ANSWER" >&2; return 1
  fi
}
response_context_tokens() {
  case "$PROVIDER" in
    openai)
      printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r \
        '(.usage.total_tokens // ((.usage.input_tokens // 0) + (.usage.output_tokens // 0))) | floor'
      ;;
    anthropic)
      printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r \
        '((.usage.input_tokens // 0) + (.usage.output_tokens // 0) + (.usage.cache_read_input_tokens // 0) + (.usage.cache_creation_input_tokens // 0)) | floor'
      ;;
    openrouter)
      printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r \
        '(.usage.total_tokens // ((.usage.prompt_tokens // 0) + (.usage.completion_tokens // 0))) | floor'
      ;;
  esac
}
serialization_prompt() {
  "$JQ_BIN" -r '
    def clipped:
      if length <= 2000 then . else .[0:1000] + "\n... " + ((length - 2000)|tostring) + " characters omitted ...\n" + .[-1000:] end;
    def checkpoint:
      .role == "user" and (.content | type) == "string" and
      (.content | startswith("Another language model worked on this task and produced a context checkpoint."));
    def body:
      ((if (.content // null) == null then "" elif (.content|type) == "string" then .content else (.content|tojson) end) +
       (if (.tool_calls // [] | length) > 0 then "\n[tool calls] " + (.tool_calls|tojson) else "" end)) as $body |
      if checkpoint then $body else ($body | clipped) end;
    map("[" + ((.role // "message") | ascii_upcase) + "]: " + body) | join("\n\n")'
}
compaction_user_prompt() {
  cat <<'EOF'
Create a context checkpoint summarizing the conversation before this message. Respond immediately using only the checkpoint sections below and only information already present in the conversation. Omit this checkpoint-generation request and its directives from the checkpoint. Preserve exact file paths, function names, commands, errors, constraints, decisions, and unfinished work. For every image attachment in the history, preserve its exact file path and a short summary of its relevant visual content; if either is unknown, say so rather than inventing it.

Use exactly these sections:

## Goal
## Constraints & Preferences
## Progress
### Done
### In Progress
### Blocked
## Key Decisions
## Next Steps
## Critical Context
## Image Attachments

Keep it concise and suitable for another model to continue without duplicating work.
EOF
}
compaction_output_limit() {
  local max=$COMPACT_MAX_TOKENS half=$((COMPACT_TOKENS / 2))
  [[ "$half" -gt 0 ]] || half=1
  [[ "$max" -le "$half" ]] || max=$half
  [[ "$max" -le "$MAX_TOKENS" ]] || max=$MAX_TOKENS
  printf '%s' "$max"
}
call_compaction_summary() {
  local prompt=$1 pending=${2:-'[]'} max summary refused reason input user status=0
  local saved_history=$HISTORY saved_max=$MAX_TOKENS saved_previous=$OPENAI_PREVIOUS_RESPONSE_ID
  max=$(compaction_output_limit)
  debug_log "compaction_summary_start provider=$PROVIDER model=${TURN_MODEL:-$MODEL} max_output_tokens=$max pending_items=$(printf '%s' "$pending" | "$JQ_BIN" 'length' 2>/dev/null || printf unknown) previous_response_id=${saved_previous:-none}"
  debug_dump compaction-prompt.txt "$prompt"
  debug_dump compaction-pending.json "$pending"
  debug_dump compaction-history.json "$saved_history"
  MAX_TOKENS=$max
  case "$PROVIDER" in
    openai)
      input=$("$JQ_BIN" -cn --argjson pending "$pending" --arg prompt "$prompt" \
        '$pending + [{role:"user",content:[{type:"input_text",text:$prompt}]}]')
      call_openai_responses "$input" || status=$?
      ;;
    anthropic)
      user=$("$JQ_BIN" -cn --arg prompt "$prompt" '{role:"user",content:$prompt}')
      HISTORY=$("$JQ_BIN" -cn --argjson history "$saved_history" --argjson user "$user" '$history + [$user]')
      call_anthropic || status=$?
      ;;
    openrouter)
      user=$("$JQ_BIN" -cn --arg prompt "$prompt" '{role:"user",content:$prompt}')
      HISTORY=$("$JQ_BIN" -cn --argjson history "$saved_history" --argjson user "$user" '$history + [$user]')
      call_openrouter || status=$?
      ;;
  esac
  HISTORY=$saved_history; MAX_TOKENS=$saved_max; OPENAI_PREVIOUS_RESPONSE_ID=$saved_previous
  debug_log "compaction_summary_response status=$status restored_previous_response_id=${OPENAI_PREVIOUS_RESPONSE_ID:-none}"
  if [[ "$status" -ne 0 ]] && ! response_is_refusal; then debug_log "compaction_summary_failed stage=api status=$status"; return "$status"; fi
  case "$PROVIDER" in
    openai) summary=$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r '[.output[]? | select(.type == "message") | .content[]? | select(.type == "output_text") | .text] | join("\n")') ;;
    anthropic) summary=$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r '[.content[]? | select(.type == "text") | .text] | join("\n")') ;;
    openrouter) summary=$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r '.choices[0].message.content // ""') ;;
  esac
  if response_is_refusal; then
    refused=${TURN_MODEL:-$MODEL}; reason=$(refusal_reason)
    interactive_stop_requested && return 130
    if [[ -n "$FALLBACK_MODEL" && "$FALLBACK_MODEL" != "none" && "$FALLBACK_MODEL" != "$refused" ]]; then
      info "${C_CYAN}fallback${C_RESET} $refused refused compaction: $reason; retrying with $FALLBACK_MODEL"
      TURN_MODEL=$FALLBACK_MODEL; call_compaction_summary "$prompt" "$pending"; return
    fi
    printf 'compaction model %s refused: %s\n' "$refused" "$reason" >&2; return 1
  fi
  debug_dump compaction-summary.txt "$summary"
  [[ -n "$summary" ]] || { debug_log "compaction_summary_failed stage=extract reason=empty_summary"; printf 'compaction returned an empty summary\n' >&2; return 1; }
  COMPACTION_SUMMARY=$summary
  debug_log "compaction_summary_complete bytes=$(printf '%s' "$summary" | wc -c | tr -d ' ')"
}
compact_history() {
  local pending=${1:-'[]'} resume=${2:-0} cut kept prompt summary prefix continuation
  cut=$(printf '%s' "$HISTORY" | "$JQ_BIN" -r '
    ([to_entries[] | select(.value.role == "user" and (.value.content|type) == "string") | .key] | last // -1) as $user |
    (.[0].content? | type == "string" and startswith("Another language model worked on this task")) as $already_compacted |
    if $user > 0 and (($already_compacted and $user == 1) | not) then $user
    else ([to_entries[] | select(.value.role == "assistant" and .key > 0) | .key] | last // -1) end')
  debug_log "compact_history_start provider=$PROVIDER resume=$resume cut=$cut history_length=$(printf '%s' "$HISTORY" | "$JQ_BIN" 'length' 2>/dev/null || printf unknown)"
  debug_dump compact-history-before.json "$HISTORY"
  [[ "$cut" -gt 0 ]] || { debug_log "compact_history_failed reason=no_safe_boundary"; printf 'context is too large but has no safe compaction boundary\n' >&2; return 1; }
  kept=$(printf '%s' "$HISTORY" | "$JQ_BIN" -c --argjson cut "$cut" '.[$cut:]')
  debug_dump compact-history-kept.json "$kept"
  prompt=$(compaction_user_prompt)
  call_compaction_summary "$prompt" "$pending" || return 1
  summary=$COMPACTION_SUMMARY
  prefix="Another language model worked on this task and produced a context checkpoint. Use it to continue without duplicating effort:\n\n$summary"
  HISTORY=$("$JQ_BIN" -cn --arg prefix "$prefix" --argjson kept "$kept" '[{role:"user",content:$prefix}] + $kept')
  if [[ "$resume" -eq 1 ]]; then
    continuation="Compaction is complete. Continue the original task now from the checkpoint and resolved tool results. Do not merely acknowledge the checkpoint. Checkpoint-generation directives are expired and must not constrain this turn."
    HISTORY=$("$JQ_BIN" -cn --argjson history "$HISTORY" --arg continuation "$continuation" \
      '$history + [{role:"user",content:$continuation}]')
  fi
  debug_dump compact-history-after.json "$HISTORY"
  CONTEXT_TOKENS=0; CONTEXT_TOKENS_KNOWN=0
  if [[ "$PROVIDER" == "openai" ]]; then
    OPENAI_PREVIOUS_RESPONSE_ID=""
    OPENAI_NEEDS_RESTART=1
  fi
  debug_log "compact_history_complete provider=$PROVIDER resume=$resume history_length=$(printf '%s' "$HISTORY" | "$JQ_BIN" 'length' 2>/dev/null || printf unknown) needs_restart=$OPENAI_NEEDS_RESTART"
  debug_state compacted
}
maybe_compact() {
  local pending=${1:-'[]'} resume=${2:-0}
  [[ "$CONTEXT_TOKENS" -ge "$COMPACT_TOKENS" ]] || return 0
  info "${C_CYAN}compact${C_RESET} context $CONTEXT_TOKENS/$COMPACT_TOKENS tokens"
  compact_history "$pending" "$resume"
}
auto_compact() {
  if ! maybe_compact "${1:-'[]'}" "${2:-0}"; then
    info "${C_CYAN}compact${C_RESET} failed; continuing with the current context"
    debug_log "automatic_compaction_failed action=continue_current_context previous_response_id=${OPENAI_PREVIOUS_RESPONSE_ID:-none}"
  fi
  return 0
}

context_usage() {
  if [[ "$CONTEXT_TOKENS_KNOWN" -eq 1 ]]; then
    printf '%s/%s' "$CONTEXT_TOKENS" "$COMPACT_TOKENS"
  else
    printf 'unknown/%s' "$COMPACT_TOKENS"
  fi
}

openai_history_input() {
  local conversation
  conversation=$(printf '%s' "$HISTORY" | serialization_prompt)
  "$JQ_BIN" -cn --arg text "Continue from this compacted conversation context:\n\n$conversation" \
    '[{role:"user",content:[{type:"input_text",text:$text}]}]'
}

openai_input_with_queued_messages() {
  local pending=$1
  "$JQ_BIN" -cn --argjson pending "$pending" --argjson queued "$INTERACTIVE_QUEUED_BATCH" \
    '$pending + [$queued[] | {role:"user",content:[{type:"input_text",text:.}]}]'
}

record_openai_response() {
  local content
  content=$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r '
    [.output[]? |
      if .type == "message" then ([.content[]? | select(.type == "output_text") | .text] | join("\n"))
      elif .type == "shell_call" then "[shell call] " + (.action.commands | join("; "))
      elif .type == "function_call" then "[tool call] " + .name + " " + (.arguments // "{}")
      else empty end] | map(select(length > 0)) | join("\n")')
  [[ -n "$content" ]] || return 0
  HISTORY=$("$JQ_BIN" -cn --argjson history "$HISTORY" --arg content "$content" '$history + [{role:"assistant",content:$content}]')
}

record_openai_tool_result() {
  local name=$1 text=$2
  HISTORY=$("$JQ_BIN" -cn --argjson history "$HISTORY" --arg name "$name" --arg text "$text" \
    '$history + [{role:"tool",name:$name,content:$text}]')
}

mime_type() {
  if command -v file >/dev/null 2>&1; then file -b --mime-type "$1" 2>/dev/null && return; fi
  case "$1" in *.png) echo image/png;; *.jpg|*.jpeg) echo image/jpeg;; *.gif) echo image/gif;; *.webp) echo image/webp;; *) echo application/octet-stream;; esac
}

b64_file() { base64 < "$1" | tr -d '\r\n'; }

image_result() {
  local path=$1 text=$2 mime=$3
  "$JQ_BIN" -Rsc --arg text "$text" --arg mime "$mime" \
    '{kind:"image",text:$text,media_type:$mime,data:.}' < <(b64_file "$path")
}

number_lines() {
  local offset=$1 limit=$2
  awk -v first="$offset" -v last="$((offset + limit - 1))" 'NR >= first && NR <= last {printf "%6d\t%s\n", NR, $0} NR > last {exit}'
}

read_file() {
  local requested=$1 offset=${2:-1} limit=${3:-250} path mime text size
  [[ "$offset" =~ ^[1-9][0-9]*$ ]] || offset=1
  [[ "$limit" =~ ^[1-9][0-9]*$ ]] || limit=250
  [[ "$limit" -gt 2000 ]] && limit=2000
  if [[ "$requested" = /* ]]; then path=$requested; else path="$WORKDIR/$requested"; fi
  if [[ ! -e "$path" ]]; then "$JQ_BIN" -cn --arg t "Not found: $requested" '{kind:"error",text:$t}'; return; fi
  case "$path" in *.pdf|*.PDF) "$JQ_BIN" -cn '{kind:"error",text:"PDF files are not supported by the read tool."}'; return ;; esac
  if [[ -d "$path" ]]; then
    text=$(find "$path" -mindepth 1 -maxdepth 1 -print 2>/dev/null | sort | awk -v n="$limit" 'NR<=n')
    "$JQ_BIN" -cn --arg text "$text" '{kind:"text",text:$text}'
    return
  fi
  mime=$(mime_type "$path")
  case "$mime" in
    image/png|image/jpeg|image/gif|image/webp)
      size=$(wc -c < "$path" | tr -d ' ')
      if [[ "$size" -gt "$MAX_IMAGE_BYTES" ]]; then
        "$JQ_BIN" -cn --arg t "Image is too large for the read tool ($size bytes; maximum 1 MiB). Use the shell tool to resize or compress the image, then call read again." \
          '{kind:"error",text:$t}'
        return
      fi
      image_result "$path" "Image attached: $requested ($mime)" "$mime"
      ;;
    application/pdf) "$JQ_BIN" -cn '{kind:"error",text:"PDF files are not supported by the read tool."}' ;;
    text/*|application/json|application/xml|application/javascript|application/x-shellscript)
      text=$(number_lines "$offset" "$limit" < "$path")
      "$JQ_BIN" -cn --arg text "$text" '{kind:"text",text:$text}'
      ;;
    *)
      if command -v strings >/dev/null 2>&1; then text=$(strings "$path" 2>/dev/null | number_lines "$offset" "$limit")
      else text="Binary file: $requested ($mime)"; fi
      "$JQ_BIN" -cn --arg text "$text" '{kind:"text",text:$text}'
      ;;
  esac
}

truncate_file() {
  local path=$1 size half
  size=$(wc -c < "$path" | tr -d ' ')
  if [[ "$size" -le "$MAX_TOOL_OUTPUT" ]]; then cat "$path"; return; fi
  half=$((MAX_TOOL_OUTPUT / 2))
  head -c "$half" "$path"
  printf '\n... %s bytes omitted ...\n' "$((size - MAX_TOOL_OUTPUT))"
  tail -c "$half" "$path"
}

run_shell() {
  local command_text=$1 tmp status output command_pid timer=()
  tmp=$(mktemp "${TMPDIR:-/tmp}/miniagent-tool.XXXXXX") || return 1
  if command -v timeout >/dev/null 2>&1; then timer=(timeout "$TOOL_TIMEOUT")
  elif command -v gtimeout >/dev/null 2>&1; then timer=(gtimeout "$TOOL_TIMEOUT"); fi
  (cd "$WORKDIR" && MINIAGENT_ACTIVE_STOP_FILE="$INTERACTIVE_STOP_FILE" exec "${timer[@]}" bash -lc "$command_text") < /dev/null > "$tmp" 2>&1 &
  command_pid=$!
  wait_for_process "$command_pid"
  status=$?
  if interactive_stop_requested; then rm -f "$tmp"; return 130; fi
  debug_log "tool_shell_compatible command=$(printf '%q' "$command_text") status=$status"
  debug_dump_file tool-shell-compatible-output.txt "$tmp"
  output=$(truncate_file "$tmp")
  rm -f "$tmp"
  [[ -n "$output" ]] || output="(no output)"
  "$JQ_BIN" -cn --arg text "$output\n\n[exit status: $status]" --argjson status "$status" \
    '{kind:"text",text:$text,exit_status:$status}'
}

run_native_command() {
  local command_text=$1 requested_limit=$2 timeout_seconds=$3 out_file err_file status stdout stderr cap command_pid timer=()
  out_file=$(mktemp "${TMPDIR:-/tmp}/miniagent-stdout.XXXXXX") || return 1
  err_file=$(mktemp "${TMPDIR:-/tmp}/miniagent-stderr.XXXXXX") || { rm -f "$out_file"; return 1; }
  cap=$requested_limit
  [[ "$cap" =~ ^[1-9][0-9]*$ ]] || cap=$MAX_TOOL_OUTPUT
  [[ "$cap" -gt "$MAX_TOOL_OUTPUT" ]] && cap=$MAX_TOOL_OUTPUT
  [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || timeout_seconds=$TOOL_TIMEOUT
  [[ "$timeout_seconds" -gt "$TOOL_TIMEOUT" ]] && timeout_seconds=$TOOL_TIMEOUT
  if command -v timeout >/dev/null 2>&1; then timer=(timeout "$timeout_seconds")
  elif command -v gtimeout >/dev/null 2>&1; then timer=(gtimeout "$timeout_seconds"); fi
  info "${C_CYAN}shell${C_RESET} $command_text"
  (cd "$WORKDIR" && MINIAGENT_ACTIVE_STOP_FILE="$INTERACTIVE_STOP_FILE" exec "${timer[@]}" bash -lc "$command_text") < /dev/null > "$out_file" 2> "$err_file" &
  command_pid=$!
  wait_for_process "$command_pid"
  status=$?
  if interactive_stop_requested; then rm -f "$out_file" "$err_file"; return 130; fi
  debug_log "tool_shell command=$(printf '%q' "$command_text") status=$status requested_limit=$requested_limit effective_limit=$cap timeout_seconds=$timeout_seconds"
  debug_dump_file tool-shell-stdout.txt "$out_file"
  debug_dump_file tool-shell-stderr.txt "$err_file"
  stdout=$(MAX_TOOL_OUTPUT=$cap truncate_file "$out_file")
  stderr=$(MAX_TOOL_OUTPUT=$cap truncate_file "$err_file")
  rm -f "$out_file" "$err_file"
  if [[ "$status" -eq 124 || "$status" -eq 137 ]]; then
    "$JQ_BIN" -cn --arg stdout "$stdout" --arg stderr "$stderr" \
      '{stdout:$stdout,stderr:$stderr,outcome:{type:"timeout"}}'
  else
    "$JQ_BIN" -cn --arg stdout "$stdout" --arg stderr "$stderr" --argjson status "$status" \
      '{stdout:$stdout,stderr:$stderr,outcome:{type:"exit",exit_code:$status}}'
  fi
}

capture_result() {
  local output_file status=0
  output_file=$(mktemp "${TMPDIR:-/tmp}/miniagent-result.XXXXXX") || return 1
  "$@" > "$output_file" || status=$?
  CAPTURED_RESULT=$(cat "$output_file")
  rm -f "$output_file"
  return "$status"
}

process_openai_tool_calls() {
  local next='[]' attachments='[]' call type call_id name args requested_limit timeout_ms timeout_seconds outputs command_json command_text result result_text attachment tool_output message status
  while IFS= read -r call; do
    [[ -n "$call" ]] || continue
    type=$(printf '%s' "$call" | "$JQ_BIN" -r '.type')
    call_id=$(printf '%s' "$call" | "$JQ_BIN" -r '.call_id')
    if [[ "$type" == "function_call" ]]; then
      name=$(printf '%s' "$call" | "$JQ_BIN" -r '.name')
      args=$(printf '%s' "$call" | "$JQ_BIN" -r '.arguments // "{}"' | "$JQ_BIN" -c '.' 2>/dev/null) || args='{}'
      status=0; capture_result run_tool "$name" "$args" || status=$?; result=$CAPTURED_RESULT
      [[ "$status" -eq 0 ]] || return "$status"
      result_text=$(printf '%s' "$result" | "$JQ_BIN" -r '.text')
      tool_output=$("$JQ_BIN" -cn --arg id "$call_id" --arg output "$result_text" \
        '{type:"function_call_output",call_id:$id,output:$output}')
      next=$("$JQ_BIN" -cs '.[0] + [.[1]]' <(printf '%s\n' "$next") <(printf '%s\n' "$tool_output"))
      record_openai_tool_result "$name" "$result_text"
      if [[ $(printf '%s' "$result" | "$JQ_BIN" -r '.kind') == "image" ]]; then
        attachment=$(printf '%s' "$result" | "$JQ_BIN" -c \
          '{type:"input_image",image_url:("data:"+.media_type+";base64,"+.data)}')
        attachments=$("$JQ_BIN" -cs '.[0] + [.[1]]' \
          <(printf '%s\n' "$attachments") <(printf '%s\n' "$attachment"))
      fi
      continue
    fi
    requested_limit=$(printf '%s' "$call" | "$JQ_BIN" -r ".action.max_output_length // $MAX_TOOL_OUTPUT")
    timeout_ms=$(printf '%s' "$call" | "$JQ_BIN" -r ".action.timeout_ms // ($TOOL_TIMEOUT * 1000)")
    timeout_seconds=$(( (timeout_ms + 999) / 1000 ))
    outputs='[]'
    while IFS= read -r command_json; do
      command_text=$(printf '%s' "$command_json" | "$JQ_BIN" -r '.')
      [[ -n "$command_text" ]] || continue
      status=0; capture_result run_native_command "$command_text" "$requested_limit" "$timeout_seconds" || status=$?; result=$CAPTURED_RESULT
      [[ "$status" -eq 0 ]] || return "$status"
      outputs=$("$JQ_BIN" -cs '.[0] + [.[1]]' \
        <(printf '%s\n' "$outputs") <(printf '%s\n' "$result"))
    done < <(printf '%s' "$call" | "$JQ_BIN" -c '.action.commands[]')
    tool_output=$("$JQ_BIN" -cn --arg id "$call_id" --argjson max "$requested_limit" \
      --slurpfile outputs <(printf '%s\n' "$outputs") \
      '{type:"shell_call_output",call_id:$id,max_output_length:$max,output:$outputs[0]}')
    next=$("$JQ_BIN" -cs '.[0] + [.[1]]' \
      <(printf '%s\n' "$next") <(printf '%s\n' "$tool_output"))
    record_openai_tool_result "shell" "$(printf '%s' "$outputs" | "$JQ_BIN" -c '.')"
  done < <(printf '%s' "$API_RESPONSE" | "$JQ_BIN" -c '.output[] | select(.type == "shell_call" or .type == "function_call")')
  if [[ $(printf '%s' "$attachments" | "$JQ_BIN" 'length') -gt 0 ]]; then
    message=$("$JQ_BIN" -cn --slurpfile files <(printf '%s\n' "$attachments") \
      '{role:"user",content:([{type:"input_text",text:"Images returned by the read tool are attached."}] + $files[0])}')
    next=$("$JQ_BIN" -cs '.[0] + [.[1]]' \
      <(printf '%s\n' "$next") <(printf '%s\n' "$message"))
  fi
  OPENAI_NEXT_INPUT=$next
  debug_dump openai-next-input.json "$OPENAI_NEXT_INPUT"
  debug_log "openai_tool_calls_resolved results=$(printf '%s' "$next" | "$JQ_BIN" '[.[] | select(.type == "shell_call_output" or .type == "function_call_output")] | length' 2>/dev/null || printf unknown) attachments=$(printf '%s' "$attachments" | "$JQ_BIN" 'length' 2>/dev/null || printf unknown)"
}

run_tool() {
  local name=$1 input=$2 command_text path offset limit
  case "$name" in
    read)
      path=$(printf '%s' "$input" | "$JQ_BIN" -r '.path // empty')
      offset=$(printf '%s' "$input" | "$JQ_BIN" -r '.offset // 1')
      limit=$(printf '%s' "$input" | "$JQ_BIN" -r '.limit // 250')
      [[ -n "$path" ]] || { "$JQ_BIN" -cn '{kind:"error",text:"read requires path"}'; return; }
      info "${C_CYAN}read${C_RESET} $path"
      debug_log "tool_read path=$(printf '%q' "$path") offset=$offset limit=$limit"
      read_file "$path" "$offset" "$limit"
      ;;
    shell)
      command_text=$(printf '%s' "$input" | "$JQ_BIN" -r '.command // empty')
      [[ -n "$command_text" ]] || { "$JQ_BIN" -cn '{kind:"error",text:"shell requires command"}'; return; }
      info "${C_CYAN}shell${C_RESET} $command_text"
      debug_log "tool_shell_compatible_requested command=$(printf '%q' "$command_text")"
      run_shell "$command_text"
      ;;
    *) "$JQ_BIN" -cn --arg t "Unknown tool: $name" '{kind:"error",text:$t}' ;;
  esac
}

process_openai_calls() {
  local assistant calls images='[]' id name args result result_text tool_message status
  assistant=$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" -c '.choices[0].message')
  HISTORY=$("$JQ_BIN" -cs '.[0] + [.[1]]' \
    <(printf '%s\n' "$HISTORY") <(printf '%s\n' "$assistant"))
  calls=$(printf '%s' "$assistant" | "$JQ_BIN" -c '.tool_calls // []')
  while IFS= read -r call; do
    [[ -n "$call" ]] || continue
    id=$(printf '%s' "$call" | "$JQ_BIN" -r '.id')
    name=$(printf '%s' "$call" | "$JQ_BIN" -r '.function.name')
    args=$(printf '%s' "$call" | "$JQ_BIN" -r '.function.arguments' | "$JQ_BIN" -c '.' 2>/dev/null) || args='{}'
    status=0; capture_result run_tool "$name" "$args" || status=$?; result=$CAPTURED_RESULT
    [[ "$status" -eq 0 ]] || return "$status"
    result_text=$(printf '%s' "$result" | "$JQ_BIN" -r '.text')
    tool_message=$("$JQ_BIN" -cn --arg id "$id" --arg name "$name" --arg text "$result_text" \
      '{role:"tool",tool_call_id:$id,name:$name,content:$text}')
    HISTORY=$("$JQ_BIN" -cs '.[0] + [.[1]]' \
      <(printf '%s\n' "$HISTORY") <(printf '%s\n' "$tool_message"))
    if [[ $(printf '%s' "$result" | "$JQ_BIN" -r '.kind') == "image" ]]; then
      images=$("$JQ_BIN" -cs '.[0] as $a | .[1] as $r | $a + [{type:"text",text:$r.text},{type:"image_url",image_url:{url:("data:"+$r.media_type+";base64,"+$r.data)}}]' \
        <(printf '%s\n' "$images") <(printf '%s\n' "$result"))
    fi
  done < <(printf '%s' "$calls" | "$JQ_BIN" -c '.[]')
  if [[ $(printf '%s' "$images" | "$JQ_BIN" 'length') -gt 0 ]]; then
    HISTORY=$("$JQ_BIN" -cs '.[0] + [{role:"user",content:.[1]}]' \
      <(printf '%s\n' "$HISTORY") <(printf '%s\n' "$images"))
  fi
  debug_dump history-after-openrouter-tools.json "$HISTORY"
}

process_anthropic_calls() {
  local content results='[]' id name input result result_text block status
  content=$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" -c '.content')
  HISTORY=$("$JQ_BIN" -cs '.[0] + [{role:"assistant",content:.[1]}]' \
    <(printf '%s\n' "$HISTORY") <(printf '%s\n' "$content"))
  while IFS= read -r call; do
    [[ -n "$call" ]] || continue
    id=$(printf '%s' "$call" | "$JQ_BIN" -r '.id'); name=$(printf '%s' "$call" | "$JQ_BIN" -r '.name')
    input=$(printf '%s' "$call" | "$JQ_BIN" -c '.input')
    status=0; capture_result run_tool "$name" "$input" || status=$?; result=$CAPTURED_RESULT
    [[ "$status" -eq 0 ]] || return "$status"
    result_text=$(printf '%s' "$result" | "$JQ_BIN" -r '.text')
    if [[ $(printf '%s' "$result" | "$JQ_BIN" -r '.kind') == "image" ]]; then
      block=$(printf '%s' "$result" | "$JQ_BIN" -c --arg id "$id" \
        '{type:"tool_result",tool_use_id:$id,content:[{type:"text",text:.text},{type:"image",source:{type:"base64",media_type:.media_type,data:.data}}]}')
    else
      block=$("$JQ_BIN" -cn --arg id "$id" --arg text "$result_text" '{type:"tool_result",tool_use_id:$id,content:$text}')
    fi
    results=$("$JQ_BIN" -cs '.[0] + [.[1]]' <(printf '%s\n' "$results") <(printf '%s\n' "$block"))
  done < <(printf '%s' "$content" | "$JQ_BIN" -c '.[] | select(.type == "tool_use")')
  HISTORY=$("$JQ_BIN" -cs '.[0] + [{role:"user",content:.[1]}]' \
    <(printf '%s\n' "$HISTORY") <(printf '%s\n' "$results"))
  debug_dump history-after-anthropic-tools.json "$HISTORY"
}

agent_turn_openai() {
  local user_text=$1 turn call_count text input user_message
  input=$(printf '%s' "$user_text" | "$JQ_BIN" -Rsc '[{role:"user",content:[{type:"input_text",text:.}]}]')
  user_message=$(printf '%s' "$user_text" | "$JQ_BIN" -Rsc '{role:"user",content:.}')
  HISTORY=$("$JQ_BIN" -cn --argjson history "$HISTORY" --argjson message "$user_message" '$history + [$message]')
  LAST_ANSWER=""
  turn=1
  while [[ "$turn" -le "$MAX_TURNS" ]]; do
    debug_log "model_turn_start provider=openai model=${TURN_MODEL:-$MODEL} turn=$turn context=$(context_usage) previous_response_id=${OPENAI_PREVIOUS_RESPONSE_ID:-none} needs_restart=$OPENAI_NEEDS_RESTART"
    debug_state model-turn-openai
    info "model ${TURN_MODEL:-$MODEL} · openai responses · reasoning $REASONING · context $(context_usage) · turn $turn/$MAX_TURNS"
    if [[ "$OPENAI_NEEDS_RESTART" -eq 1 ]]; then input=$(openai_history_input); OPENAI_NEEDS_RESTART=0; fi
    debug_dump model-input-openai.json "$input"
    debug_dump history-model-turn-openai.json "$HISTORY"
    call_with_fallback call_openai_responses "$input" || return 1
    CONTEXT_TOKENS=$(response_context_tokens); CONTEXT_TOKENS_KNOWN=1
    call_count=$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" '[.output[]? | select(.type == "shell_call" or .type == "function_call")] | length')
    text=$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r \
      '[.output[]? | select(.type == "message") | .content[]? | select(.type == "output_text") | .text] | join("\n")')
    record_openai_response
    if [[ "$call_count" -gt 0 ]]; then
      process_openai_tool_calls || return $?
      input=$OPENAI_NEXT_INPUT
      if interactive_stop_requested; then return 130; fi
      apply_interactive_messages 1
      input=$(openai_input_with_queued_messages "$input")
      auto_compact "$input" 1
      if interactive_stop_requested; then return 130; fi
      apply_interactive_messages
      input=$(openai_input_with_queued_messages "$input")
    else
      if interactive_stop_requested; then return 130; fi
      apply_interactive_messages
      if [[ "$INTERACTIVE_QUEUED_COUNT" -gt 0 ]]; then
        input=$(openai_input_with_queued_messages '[]')
        auto_compact "$input" 1
        if interactive_stop_requested; then return 130; fi
        apply_interactive_messages
        input=$(openai_input_with_queued_messages "$input")
      else
        LAST_ANSWER=$text
        auto_compact
        if interactive_stop_requested; then return 130; fi
        apply_interactive_messages
        if [[ "$INTERACTIVE_QUEUED_COUNT" -gt 0 ]]; then input=$(openai_input_with_queued_messages '[]'); else return 0; fi
      fi
    fi
    turn=$((turn + 1))
  done
  LAST_ANSWER="Stopped after reaching the $MAX_TURNS-turn limit."
  return 2
}

agent_turn() {
  local user_text=$1 turn text call_count user_message assistant_content
  [[ -n "$TURN_MODEL" ]] || TURN_MODEL=$MODEL
  if [[ "$PROVIDER" == "openai" ]]; then agent_turn_openai "$user_text"; return; fi
  user_message=$(printf '%s' "$user_text" | "$JQ_BIN" -Rsc '{role:"user",content:.}')
  HISTORY=$("$JQ_BIN" -cs '.[0] + [.[1]]' \
    <(printf '%s\n' "$HISTORY") <(printf '%s\n' "$user_message"))
  LAST_ANSWER=""
  turn=1
  while [[ "$turn" -le "$MAX_TURNS" ]]; do
    debug_log "model_turn_start provider=$PROVIDER model=${TURN_MODEL:-$MODEL} turn=$turn context=$(context_usage)"
    debug_state "model-turn-$PROVIDER"
    info "model ${TURN_MODEL:-$MODEL} · $PROVIDER · reasoning $REASONING · context $(context_usage) · turn $turn/$MAX_TURNS"
    debug_dump "history-model-turn-$PROVIDER.json" "$HISTORY"
    if [[ "$PROVIDER" == "anthropic" ]]; then
      call_with_fallback call_anthropic || return 1
      CONTEXT_TOKENS=$(response_context_tokens); CONTEXT_TOKENS_KNOWN=1
      call_count=$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" '[.content[] | select(.type == "tool_use")] | length')
      text=$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r '[.content[] | select(.type == "text") | .text] | join("\n")')
      if [[ "$call_count" -gt 0 ]]; then
        process_anthropic_calls || return $?
        if interactive_stop_requested; then return 130; fi
        apply_interactive_messages 1
        auto_compact '[]' 1
        if interactive_stop_requested; then return 130; fi
        apply_interactive_messages
      else
        assistant_content=$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" -c '.content')
        HISTORY=$("$JQ_BIN" -cs '.[0] + [{role:"assistant",content:.[1]}]' \
          <(printf '%s\n' "$HISTORY") <(printf '%s\n' "$assistant_content"))
        if interactive_stop_requested; then return 130; fi
        apply_interactive_messages
        if [[ "$INTERACTIVE_QUEUED_COUNT" -gt 0 ]]; then
          auto_compact '[]' 1
          if interactive_stop_requested; then return 130; fi
          apply_interactive_messages
        else
          LAST_ANSWER=$text; auto_compact
          if interactive_stop_requested; then return 130; fi
          apply_interactive_messages
          [[ "$INTERACTIVE_QUEUED_COUNT" -gt 0 ]] || return 0
        fi
      fi
    else
      call_with_fallback call_openrouter || return 1
      CONTEXT_TOKENS=$(response_context_tokens); CONTEXT_TOKENS_KNOWN=1
      call_count=$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" '.choices[0].message.tool_calls // [] | length')
      text=$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" -r '.choices[0].message.content // ""')
      if [[ "$call_count" -gt 0 ]]; then
        process_openai_calls || return $?
        if interactive_stop_requested; then return 130; fi
        apply_interactive_messages 1
        auto_compact '[]' 1
        if interactive_stop_requested; then return 130; fi
        apply_interactive_messages
      else
        assistant_content=$(printf '%s' "$API_RESPONSE" | "$JQ_BIN" -c '.choices[0].message')
        HISTORY=$("$JQ_BIN" -cs '.[0] + [.[1]]' \
          <(printf '%s\n' "$HISTORY") <(printf '%s\n' "$assistant_content"))
        if interactive_stop_requested; then return 130; fi
        apply_interactive_messages
        if [[ "$INTERACTIVE_QUEUED_COUNT" -gt 0 ]]; then
          auto_compact '[]' 1
          if interactive_stop_requested; then return 130; fi
          apply_interactive_messages
        else
          LAST_ANSWER=$text; auto_compact
          if interactive_stop_requested; then return 130; fi
          apply_interactive_messages
          [[ "$INTERACTIVE_QUEUED_COUNT" -gt 0 ]] || return 0
        fi
      fi
    fi
    turn=$((turn + 1))
  done
  LAST_ANSWER="Stopped after reaching the $MAX_TURNS-turn limit."
  return 2
}

print_answer() {
  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    "$JQ_BIN" -cn --arg provider "$PROVIDER" --arg model "${TURN_MODEL:-$MODEL}" --arg fallback_model "$FALLBACK_MODEL" --arg reasoning "$REASONING" \
      --rawfile answer <(printf '%s' "$LAST_ANSWER") \
      '{provider:$provider,model:$model,fallback_model:$fallback_model,reasoning:$reasoning,answer:$answer}'
  else printf '%s\n' "$LAST_ANSWER"
  fi
}

print_status() {
  local messages remaining percent
  messages=$(printf '%s' "$HISTORY" | "$JQ_BIN" 'length')
  printf 'provider: %s\nmodel: %s\nfallback model: %s\nmessages: %s\n' "$PROVIDER" "${TURN_MODEL:-$MODEL}" "$FALLBACK_MODEL" "$messages"
  if [[ "$CONTEXT_TOKENS_KNOWN" -eq 1 ]]; then
    remaining=$((COMPACT_TOKENS - CONTEXT_TOKENS)); [[ "$remaining" -lt 0 ]] && remaining=0
    percent=$((CONTEXT_TOKENS * 100 / COMPACT_TOKENS))
    printf 'conversation tokens: %s / %s (%s%%)\ntokens until compaction: %s\n' "$CONTEXT_TOKENS" "$COMPACT_TOKENS" "$percent" "$remaining"
  else
    printf 'conversation tokens: unknown (next model response will refresh them)\ncompaction threshold: %s\n' "$COMPACT_TOKENS"
  fi
  printf 'maximum output tokens: %s\nmaximum turns: %s\n' "$MAX_TOKENS" "$MAX_TURNS"
  [[ -z "$DEBUG_DIR" || -z "$DEBUG_LOG" ]] || printf 'debug bundle: %s\n' "$DEBUG_DIR"
}

interactive_help() {
  cat <<'EOF'
/model NAME       switch model and clear history
/provider NAME    switch provider and clear history
/reasoning LEVEL  change reasoning effort
/compact          compact conversation context now
/status           show conversation token statistics
/clear            clear conversation history
/help             show these commands
/quit             exit
Ctrl-D            immediately abort the active request or tool call
EOF
}

interactive_prompt() {
  if [[ -n "$C_CYAN" ]]; then
    printf '\001%s\002> \001%s\002' "$C_CYAN" "$C_RESET"
  else
    printf '> '
  fi
}

run_interactive_agent_turn() {
  local user_text=$1 status=0 saved_history=$HISTORY saved_previous=$OPENAI_PREVIOUS_RESPONSE_ID
  local saved_restart=$OPENAI_NEEDS_RESTART saved_context=$CONTEXT_TOKENS saved_context_known=$CONTEXT_TOKENS_KNOWN
  local saved_summary=$COMPACTION_SUMMARY saved_turn_model=$TURN_MODEL
  INTERACTIVE_EXECUTION=1
  INTERACTIVE_STOP_REQUESTED=0
  INTERACTIVE_STOP_FILE=$(mktemp "${TMPDIR:-/tmp}/miniagent-stop.XXXXXX") || { INTERACTIVE_EXECUTION=0; return 1; }
  INTERACTIVE_INPUT_CLOSED=0
  INTERACTIVE_INPUT_BUFFER=""
  INTERACTIVE_INPUT_PROMPT_VISIBLE=0
  INTERACTIVE_QUEUED_MESSAGES='[]'
  INTERACTIVE_QUEUED_BATCH='[]'
  INTERACTIVE_QUEUED_COUNT=0
  if [[ -t 0 ]]; then
    INTERACTIVE_STTY_STATE=$(stty -g 2>/dev/null || true)
    if [[ -n "$INTERACTIVE_STTY_STATE" ]] && stty -echo -icanon min 0 time 10 eof undef 2>/dev/null; then
      INTERACTIVE_CAPTURE_ENABLED=1
      trap 'restore_interactive_terminal' EXIT
    fi
  fi
  agent_turn "$user_text" || status=$?
  if interactive_stop_requested; then
    HISTORY=$saved_history
    OPENAI_PREVIOUS_RESPONSE_ID=$saved_previous
    OPENAI_NEEDS_RESTART=$saved_restart
    CONTEXT_TOKENS=$saved_context
    CONTEXT_TOKENS_KNOWN=$saved_context_known
    COMPACTION_SUMMARY=$saved_summary
    TURN_MODEL=$saved_turn_model
    LAST_ANSWER=""
    INTERACTIVE_STOP_REQUESTED=1
    INTERACTIVE_QUEUED_MESSAGES='[]'
    INTERACTIVE_QUEUED_BATCH='[]'
    INTERACTIVE_QUEUED_COUNT=0
    status=0
    debug_log "interactive_stop_complete action=rollback"
  fi
  restore_interactive_terminal
  trap - EXIT
  rm -f "$INTERACTIVE_STOP_FILE"
  INTERACTIVE_STOP_FILE=""
  INTERACTIVE_EXECUTION=0
  return "$status"
}

interactive_loop() {
  local line value prompt
  printf 'miniagent %s · %s · reasoning %s · %s\n' "$PROVIDER" "$MODEL" "$REASONING" "$WORKDIR"
  prompt=$(interactive_prompt)
  while true; do
    IFS= read -e -r -p "$prompt" line || { printf '\n'; if [[ -t 0 ]]; then continue; else break; fi; }
    [[ -n "$line" ]] || continue
    debug_log "interactive_input value=$(printf '%q' "$line")"
    history -s "$line"
    case "$line" in
      /quit|/exit) break ;;
      /help) interactive_help ;;
      /compact) if compact_history; then printf 'context compacted\n'; else printf 'compaction failed\n' >&2; fi ;;
      /status) print_status ;;
      /clear) HISTORY='[]'; OPENAI_PREVIOUS_RESPONSE_ID=""; OPENAI_NEEDS_RESTART=0; CONTEXT_TOKENS=0; CONTEXT_TOKENS_KNOWN=0; printf 'history cleared\n' ;;
      /model\ *)
        if [[ "$PUBLIC_PROXY" -eq 1 ]]; then
          printf 'model: openrouter/free (fixed by the public proxy)\n'
        else
          value=${line#* }; MODEL=$value; TURN_MODEL=""; HISTORY='[]'; OPENAI_PREVIOUS_RESPONSE_ID=""; OPENAI_NEEDS_RESTART=0; CONTEXT_TOKENS=0; CONTEXT_TOKENS_KNOWN=0; printf 'model: %s (history cleared)\n' "$MODEL"
        fi
        ;;
      /provider\ *)
        if [[ "$PUBLIC_PROXY" -eq 1 ]]; then
          printf 'provider: openrouter, model: openrouter/free (fixed by the public proxy)\n'
        else
          value=${line#* }; PROVIDER=$value; MODEL=""; FALLBACK_MODEL=""; TURN_MODEL=""; HISTORY='[]'; OPENAI_PREVIOUS_RESPONSE_ID=""; OPENAI_NEEDS_RESTART=0; CONTEXT_TOKENS=0; CONTEXT_TOKENS_KNOWN=0; select_provider; printf 'provider: %s, model: %s (history cleared)\n' "$PROVIDER" "$MODEL"
        fi
        ;;
      /reasoning\ *) value=${line#* }; REASONING=$value; case "$REASONING" in default|none|minimal|low|medium|high|xhigh|max) printf 'reasoning: %s\n' "$REASONING" ;; *) printf 'invalid reasoning level\n'; REASONING="medium" ;; esac ;;
      /*) printf 'unknown command; use /help\n' ;;
      *)
        if run_interactive_agent_turn "$line"; then
          [[ -n "$LAST_ANSWER" ]] && print_answer
        else
          printf 'request failed\n' >&2
        fi
        if [[ "$INTERACTIVE_STOP_REQUESTED" -eq 1 ]]; then
          INTERACTIVE_STOP_REQUESTED=0
          printf 'execution stopped\n'
        fi
        ;;
    esac
  done
}

main() {
  DEBUG_ARGV=("$@")
  parse_args "$@"
  reattach_piped_script_input
  select_json_processor
  need_cmd "$CURL_BIN"; need_cmd "$JQ_BIN"; need_cmd base64; need_cmd awk
  if [[ -t 0 && ( "$INTERACTIVE" -eq 1 || -z "$PROMPT" ) ]]; then need_cmd stty; fi
  init_debug
  select_provider; validate_config
  debug_log "configured provider=$PROVIDER model=$MODEL fallback_model=$FALLBACK_MODEL reasoning=$REASONING workdir=$WORKDIR api_url=$API_URL max_turns=$MAX_TURNS max_tokens=$MAX_TOKENS compact_tokens=$COMPACT_TOKENS compact_max_tokens=$COMPACT_MAX_TOKENS max_tool_output=$MAX_TOOL_OUTPUT tool_timeout=$TOOL_TIMEOUT api_timeout=$API_TIMEOUT"
  debug_state configured
  if [[ -z "$PROMPT" && ! -t 0 ]]; then PROMPT=$(cat); fi
  if [[ -n "$PROMPT" ]]; then
    if [[ "$INTERACTIVE" -eq 1 ]]; then
      run_interactive_agent_turn "$PROMPT" || { [[ -n "$LAST_ANSWER" ]] && print_answer; return 1; }
    else
      agent_turn "$PROMPT" || { [[ -n "$LAST_ANSWER" ]] && print_answer; return 1; }
    fi
    [[ -n "$LAST_ANSWER" ]] && print_answer
    [[ "$INTERACTIVE" -eq 1 ]] || return 0
    if [[ "$INTERACTIVE_STOP_REQUESTED" -eq 1 ]]; then
      INTERACTIVE_STOP_REQUESTED=0
      printf 'execution stopped\n'
    fi
  fi
  interactive_loop
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
  status=$?
  debug_log "session_end status=$status"
  exit "$status"
fi
