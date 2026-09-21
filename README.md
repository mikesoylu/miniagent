A single Bash script agent harness with minimal dependencies. Built for GitHub Actions, CI/CD pipelines, remote SSH sessions, and similar headless environments. It works with OpenAI, Anthropic, and OpenRouter.

The complete script, including its embedded Bash/awk JSON fallback, is **25.33 KiB gzipped** (25,934 bytes), measured with `gzip -n -c miniagent.sh | wc -c` using default compression.

Run an agent loop directly without installing:

```bash
curl -fsSL https://miniagent.sh | bash -s -- "Explain this repository"
```

Or run interactively:

```bash
curl -fsSL https://miniagent.sh | bash
```

## Features

- Runs complete agent loops: the model can inspect files, execute commands, edit code, run tests, and continue until it produces a final answer.
- Supports one-shot tasks, piped prompts, and persistent interactive sessions.
- Gives every provider consistent `read` and `shell` tools, including image attachments.
- Uses OpenAI's native local tool for `shell` and a compatible function tool for `read`.
- Supports configurable reasoning effort, model-call and output limits, command timeouts, and machine-readable JSON output.
- Automatically compacts long conversations using exact provider-reported token usage while preserving the latest complete turn.
- Can retry recognized safety refusals once with a configured fallback model and keep that model selected for the session.
- Keeps tool progress on stderr so normal and JSON answers on stdout are easy to pipe.

## Requirements

- Bash 3.2+
- `curl`
- Optional: `jq` for faster JSON processing; when it is unavailable, miniagent uses its embedded Bash/awk fallback.
- Standard Unix utilities used by the harness: `awk`, `base64`, `cat`, `chmod`, `cp`, `date`, `dd`, `find`, `head`, `mkdir`, `mktemp`, `rm`, `sort`, `stty`, `tail`, `tr`, `uname`, and `wc`
- Standard agent editing and inspection utilities: `sed` and `nl`
- Optional: `file` for MIME detection, `strings` for extracting text from unknown binary files, and GNU `timeout` (or `gtimeout`) to enforce command timeouts

## Install

```bash
curl -fsSL https://miniagent.sh/install | bash
```

The installer checks for standard Unix utilities and installs the single `miniagent` script in `~/.local/bin`. JSON processing uses `jq` when available and the embedded Bash/awk fallback otherwise. No jq binary or companion files are downloaded, and `sudo` is not required.

## Quick start

```bash
miniagent "Find and fix the failing tests"
```

If you have not configured a provider key, miniagent uses the public fallback. Set `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, or `OPENROUTER_API_KEY` to use your own provider directly.

## Usage

```text
miniagent [options] "task"
miniagent [options]                    # interactive mode in a terminal
```

Examples:

```bash
# One-shot tasks
miniagent -m gpt-5.6-sol -r xhigh "Find and fix the failing tests"
miniagent -p anthropic -m claude-opus-5 "Explain this repository"
miniagent -p openrouter -C ./project "Review the current diff"

# Read a task from stdin
printf 'List the main components' | miniagent -p openai

# Emit one JSON object on stdout
miniagent --json "Summarize the repository"

# Complete the initial task, then stay in an interactive session
miniagent -i "Start by reading README.md"
```

### CLI options

| Option | Description | Default |
|---|---|---|
| `-p, --provider NAME` | `openai`, `anthropic`, or `openrouter` | Inferred from API keys; ignored in no-key mode |
| `-m, --model MODEL` | Provider model name | Provider-specific; ignored in no-key mode |
| `--fallback-model MODEL` | Retry a recognized safety refusal once; `none` disables fallback | Provider-specific; ignored in no-key mode |
| `-r, --reasoning LEVEL` | Reasoning effort | `medium` |
| `-C, --chdir DIR` | Working directory exposed to the agent | Current directory |
| `-n, --max-turns N` | Maximum model calls for each user request | `1024` |
| `--max-tokens N` | Maximum output tokens for each model call | `32768` |
| `--compact-tokens N` | Provider-reported context usage that triggers compaction | `262144` |
| `--debug` | Write a diagnostic bundle under the system temp directory | Off |
| `--debug-dir DIR` | Write the diagnostic bundle to a specific directory | Off |
| `-i, --interactive` | Stay interactive after an initial task | Off |
| `--json` | Return `{provider, model, fallback_model, reasoning, answer}` | Off |
| `-q, --quiet` | Hide model and tool progress written to stderr | Off |
| `-h, --help` | Show command help | |
| `-v, --version` | Show the miniagent version | |

Reasoning levels are `default`, `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, and `max`. Provider and model support varies. `default` omits explicit reasoning controls. OpenAI and Anthropic map `minimal` to `low`; OpenRouter maps `max` to `xhigh`.

## Interactive sessions

Run `miniagent` with no task in a terminal, or add `-i` after an initial task. Conversation history and the active fallback model are retained between requests.

| Command | Action |
|---|---|
| `/model NAME` | Switch models and clear conversation history |
| `/provider NAME` | Switch providers, select that provider's defaults, and clear history |
| `/reasoning LEVEL` | Change reasoning effort without clearing history |
| `/compact` | Create a context checkpoint immediately |
| `/status` | Show the active models, message count, exact token usage, compaction budget, and limits |
| `/clear` | Clear conversation history and token state |
| `/help` | Show interactive commands |
| `/quit` or `/exit` | End the session |

While an interactive request is running, a live `(queue) ` prompt remains visible for follow-up input. Each complete line entered there is queued and added to the conversation at the next safe boundary: after every tool call in the current provider response has a matching result, and before the next model call. Pressing Ctrl-D immediately aborts the active API request or tool call, discards the interrupted turn, and returns to the interactive prompt; it does not end the session. Tool side effects completed before the abort are not rolled back. Use `/quit` or `/exit` to end the session.

After a refusal fallback, `/clear` preserves the active fallback model. `/model` or `/provider` selects a new primary model.

## Configuration

These settings apply when using your own provider key. In no-key mode, provider, model, fallback, and base URL settings are ignored.

### Provider settings

| Provider | Required | Optional | Default primary / fallback |
|---|---|---|---|
| OpenAI | `OPENAI_API_KEY` | `OPENAI_MODEL`, `OPENAI_FALLBACK_MODEL`, `OPENAI_BASE_URL` | `gpt-5.6-sol` / `gpt-5.6-terra` |
| Anthropic | `ANTHROPIC_API_KEY` | `ANTHROPIC_MODEL`, `ANTHROPIC_FALLBACK_MODEL`, `ANTHROPIC_BASE_URL`, `ANTHROPIC_VERSION` | `claude-opus-5` / `claude-sonnet-5` |
| OpenRouter | `OPENROUTER_API_KEY` | `OPENROUTER_MODEL`, `OPENROUTER_FALLBACK_MODEL`, `OPENROUTER_BASE_URL`, `OPENROUTER_HTTP_REFERER`, `OPENROUTER_APP_NAME` | `openai/gpt-5.6-sol` / `openai/gpt-5.6-terra` |

The default base URLs are the providers' public APIs. `ANTHROPIC_VERSION` defaults to `2023-06-01`, and the default OpenRouter app title is `miniagent`.

### Shared settings

| Variable | Purpose | Default |
|---|---|---|
| `MINIAGENT_PROVIDER` | Provider selection | Inferred from API keys; ignored in no-key mode |
| `MINIAGENT_MODEL` | Primary model | Provider-specific; ignored in no-key mode |
| `MINIAGENT_FALLBACK_MODEL` | Refusal fallback model | Provider-specific; ignored in no-key mode |
| `MINIAGENT_REASONING` | Reasoning effort | `medium` |
| `MINIAGENT_MAX_TURNS` | Model calls per user request | `1024` |
| `MINIAGENT_MAX_TOKENS` | Output tokens per model call | `32768` |
| `MINIAGENT_COMPACT_TOKENS` | Automatic compaction threshold | `262144` |
| `MINIAGENT_COMPACT_MAX_TOKENS` | Upper bound for checkpoint-summary output; also capped at half the compaction threshold | `13107` |
| `MINIAGENT_MAX_TOOL_OUTPUT` | Maximum captured bytes for each stdout/stderr stream or compatible-tool result | `30000` |
| `MINIAGENT_TOOL_TIMEOUT` | Maximum command runtime in seconds when `timeout` or `gtimeout` is installed | `120` |
| `MINIAGENT_API_TIMEOUT` | Maximum API request time in seconds | `600` |
| `MINIAGENT_WORKDIR` | Agent working directory | Current directory |
| `MINIAGENT_DEBUG` | Enable diagnostic logging with `1` | `0` |
| `MINIAGENT_DEBUG_DIR` | Diagnostic bundle directory; otherwise a temporary directory is created | System temp directory |

`CURL_BIN` and `JQ_BIN` may also be set to alternate executable paths, primarily for testing. A custom `JQ_BIN` path must exist; it is not replaced automatically. Set `JQ_BIN=miniagent_jq` to force the embedded fallback even when jq is installed.

The fallback implements the jq filters used by this harness, not the full jq language. It requires awk with regex record separators (as provided by current macOS awk, GNU awk, mawk, and BusyBox awk), uses double-precision arithmetic, and does not support NUL characters. Native jq remains preferred for performance.

## Provider tools and file support

Every provider receives tools named `read` and `shell`. OpenAI's `shell` is its native local tool; its `read` tool and both Anthropic/OpenRouter tools use miniagent's compatible function implementation:

- `read` lists a directory, returns numbered slices of text files (up to 2,000 lines per call), extracts printable strings from otherwise unknown files when `strings` is available, and attaches PNG, JPEG, GIF, or WebP images up to 1 MiB. For a larger image, it returns an error directing the model to use `shell` to resize or compress the file first.
- `shell` executes a command through `bash -lc` in the configured working directory. The compatible implementation reports combined output and exit status; OpenAI's native implementation reports stdout, stderr, and its outcome separately.

PDF input is not supported. Tool output larger than `MINIAGENT_MAX_TOOL_OUTPUT` is truncated by retaining its beginning and end. Each tool call starts in the configured working directory, so a `cd` in one call does not carry over to later calls.

## Context compaction

After each model response, miniagent records exact context usage reported by the provider; Anthropic cache-read and cache-creation tokens are included. Automatic compaction can run between tool-call rounds during a single agent turn. Before compacting, miniagent executes every tool call in the current response and appends every result, so the provider never receives a checkpoint request with an unresolved tool call.

Compaction asks the active model for a structured checkpoint, replaces older history with that checkpoint, and retains the latest complete turn. Checkpoint output is capped at the lowest of `MINIAGENT_COMPACT_MAX_TOKENS`, half of the compaction threshold, and the normal model-output limit. The request is appended to the existing provider-native conversation to preserve the cacheable prefix. For mid-turn compaction, miniagent appends a fresh continuation message after the checkpoint and tool results so the model resumes the original task instead of acknowledging the checkpoint. OpenAI keeps its `previous_response_id` chain for the summary request, then starts a fresh chain from the compacted transcript; the complete checkpoint is preserved when rebuilding that chain, while ordinary historical messages and tool output remain clipped. Image paths and short visual summaries are explicitly preserved in the checkpoint. Token usage is shown as unknown until the next normal response refreshes it.

If automatic compaction fails, miniagent records the failure and continues the current agent turn with its existing history and resolved tool results. Manual `/compact` still reports failure directly.

## Debug logging

Pass `--debug` or set `MINIAGENT_DEBUG=1` to create a per-process diagnostic bundle named `miniagent-debug.<pid>.*` under `${TMPDIR:-/tmp}`. The bundle path is printed to stderr. Use `--debug-dir DIR` or `MINIAGENT_DEBUG_DIR` to choose its location.

The bundle includes an event log with timestamps, PID, process lifecycle, configuration and state transitions; complete provider request and response bodies; compaction prompts, pending tool results, histories and summaries; and raw tool stdout/stderr. The process environment and API authorization headers are never logged. The directory and its files are restricted to the current user where the platform permits it. Request bodies and tool output can still contain sensitive repository or command data, so share debug bundles carefully.

## Refusal fallback

If a provider returns a recognized safety refusal, miniagent retries the same request once with the fallback model. A successful fallback becomes the active model for the rest of the interactive session, including later requests, compaction, and `/clear`. Use `--fallback-model none` to disable this behavior.

Recognized signals are Anthropic `stop_reason: "refusal"`, OpenAI refusal output and matching HTTP content-policy or cybersecurity rejections, and OpenRouter `content_filter` or `message.refusal` responses. Network failures, rate limits, overloads, and ordinary API errors are returned without switching models.

## Security and execution notes

The native OpenAI shell and provider-compatible `shell` tool can run arbitrary commands with the same permissions and environment as miniagent. Use a working directory and environment you are comfortable exposing to the selected model, and avoid placing unrelated secrets in that environment.

API requests are non-streaming to keep the script compact and provider-neutral. When GNU `timeout` or `gtimeout` is unavailable, command execution still works but the harness cannot enforce `MINIAGENT_TOOL_TIMEOUT`.

## Tests

The test suite uses jq for its mocks and assertions, tests startup without jq, and does not require real API keys:

```bash
bash tests/test.sh
JQ_BIN=miniagent_jq bash tests/test.sh
bash tests/test-json.sh
```

To test the fallback with Alpine’s BusyBox awk (jq is installed only for the test mocks and assertions):

```bash
docker run --rm -v "$PWD:/work:ro" -w /work alpine sh -c \
  'apk add --no-cache bash curl jq && bash tests/test-json.sh && JQ_BIN=miniagent_jq bash tests/test.sh'
```
