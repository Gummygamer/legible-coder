# legible-coder

An interactive CLI coding assistant for the [Legible programming language](../legible/), styled after Claude Code. It writes Legible code and performs tasks by running Legible scripts through an OpenAI-compatible chat completions API. The default backend is Gemini, with OrcaRouter's free Qwen3.8 27B model as the first fallback when configured, followed by NVIDIA NIM, OpenRouter, Groq, and local LM Studio.

```
  legible-coder
  Interactive Legible coding assistant
  Model: gemini-3.7-flash via Gemini
  ────────────────────────────────────────────
  cwd: /your/project
  Type your request, or 'quit' to exit.

  >
```

## What it does

- **Writes Legible code** — ask it to create functions, modules, programs, or fix existing `.lbl` files
- **Performs tasks** — ask it to run Legible scripts, explore your codebase, read and write files, search for patterns
- **Agentic** — uses tools to explore and modify your project, looping until the task is done

## Prerequisites

- The Legible interpreter (`legible` binary) in your `PATH`
- SDL2 runtime libraries: `libsdl2-2.0-0` and `libsdl2-ttf-2.0-0` on Debian/Ubuntu
- A [Gemini API key](https://aistudio.google.com/app/apikey)
- Optional fallback keys: [OrcaRouter](https://www.orcarouter.ai/), [NVIDIA NIM](https://build.nvidia.com/), [OpenRouter](https://openrouter.ai/settings/keys), then [Groq](https://console.groq.com/)

Build the interpreter from source:

```bash
sudo apt-get install libsdl2-2.0-0 libsdl2-ttf-2.0-0
cd ../legible
cargo build --release
cp target/release/legible ~/.cargo/bin/   # or anywhere on your PATH
```

## Installation

### Quick install (symlink into PATH)

```bash
ln -sf "$(pwd)/legible-coder" ~/.local/bin/legible-coder
```

This symlinks the wrapper script into `~/.local/bin`, which is on `PATH` for most Linux setups. The script follows the symlink back to `coder.lbl`, so moving or renaming the symlink is fine.

### Manual

Just run the interpreter directly:

```bash
legible run /path/to/legible-coder/coder.lbl
```

## Usage

```bash
export GEMINI_API_KEY="your-gemini-key-here"
export ORCAROUTER_API_KEY="your-orcarouter-key-here"   # optional first fallback
export NVIDIA_API_KEY="your-nvidia-nim-key-here"       # optional second fallback
export OPENROUTER_API_KEY="your-openrouter-key-here"   # optional third fallback
export GROQ_API_KEY="your-groq-key-here"               # optional fourth fallback
cd your-project-directory
legible-coder
```

For a local OpenAI-compatible server such as LM Studio:

```bash
export LEGIBLE_CODER_BASE_URL="http://127.0.0.1:1234/v1"
export LEGIBLE_CODER_MODEL="google/gemma-4-26b-a4b"
legible-coder
```

Gemma 4 model names enable native tool calling automatically. Set
`LEGIBLE_CODER_LOCAL_TOOLS=0` to force the older manual `TOOL ...` protocol,
or `LEGIBLE_CODER_LOCAL_TOOLS=1` to force native tool schemas for another local
model.

Then type your request at the `>` prompt. Examples:

```
> write a function that parses a CSV file into a list of mappings
> add error handling to my http_server.lbl
> run my tests and show me the output
> list all .lbl files in this directory
> what does the parse_response function do?
```

Type `quit` or `exit` to leave.

## How it works

legible-coder is a single Legible file (`coder.lbl`) that implements a Claude Code-style REPL:

1. Reads your request
2. Sends it to the configured model with a full Legible language reference in the system prompt
3. If the model calls a tool, executes it and feeds the result back
4. Loops until the model produces a text response
5. Prints the response and waits for the next request

Conversation history is kept in-memory for the duration of the session. When
the rough transcript token estimate crosses the configured context budget,
older messages are compacted into a synthetic summary while recent messages are
kept verbatim. Native tool-call transcripts are compacted at safe boundaries so
tool results keep their preceding assistant tool-call message.

### Tools available to the model

| Tool | Description |
|------|-------------|
| `read_file` | Read a file's contents |
| `read_file_lines` | Read a 40-line slice of a file with line numbers |
| `write_file` | Create or overwrite a file |
| `shell_exec` | Run a shell command (including `legible run`) |
| `list_dir` | List directory entries |
| `read_dir_recursive` | Recursively list files under a directory |
| `grep` | Search for patterns in files |

## Interpreter additions

To support legible-coder, the Legible interpreter was extended with two new builtin modules:

**`http_client_builtins`** — outbound HTTP:
- `http_client_get(url, headers)` → `{status, body}`
- `http_client_post(url, headers, body)` → `{status, body}`

**`process_builtins`** — system/process operations:
- `env_get(name)` — read an environment variable
- `shell_exec(command)` → `{stdout, stderr, exit_code}`
- `exit_process(code)` — exit with a code
- `list_dir(path)` → list of filenames
- `create_dir(path)` — create directories recursively
- `get_cwd()` → current working directory as text
- `path_join(base, segment, ...)` → joined path
- `is_dir(path)` → boolean

The interpreter's `run` command was also changed to stream `print` output to stdout in real time (rather than buffering), which is required for interactive tools.

## Project structure

```
legible-coder/
├── coder.lbl        # The assistant — single-file Legible program
├── legible-coder    # Wrapper shell script (for global install)
├── CLAUDE.md        # Development guide for AI-assisted editing
└── README.md        # This file
```

## Environment variables

| Variable | Required | Description |
|----------|----------|-------------|
| `GEMINI_API_KEY` | For Gemini | Gemini API key for the default primary provider |
| `ORCAROUTER_API_KEY` | For OrcaRouter | OrcaRouter API key for the first fallback. Uses `qwen/qwen3.8-27b-free` by default |
| `NVIDIA_API_KEY` | For NIM | NVIDIA NIM API key for the second fallback |
| `OPENROUTER_API_KEY` | For OpenRouter | OpenRouter API key for the third fallback. Uses `openrouter/free` by default |
| `GROQ_API_KEY` | For Groq | Groq API key for the fourth fallback |
| `LEGIBLE_CODER_API_KEY` | No | Explicit API key override. Local endpoints default to `lm-studio` |
| `LEGIBLE_CODER_BASE_URL` | No | OpenAI-compatible base URL. Auto-detects Gemini, OrcaRouter, NIM, OpenRouter, Groq, then local LM Studio when unset |
| `LEGIBLE_CODER_MODEL` | No | Primary model. Defaults include `gemini-3.7-flash` for Gemini, `qwen/qwen3.8-27b-free` for OrcaRouter, and provider-specific models for other backends |
| `LEGIBLE_CODER_FAST_MODEL` | No | Remote fast model for simple turns. Defaults to the provider's fast or primary model |
| `LEGIBLE_CODER_EXPERT_MODEL` | No | Optional remote expert model for architecture/refactor/design turns |
| `LEGIBLE_CODER_LOCAL_TOOLS` | No | `1` forces native tools for local models, `0` forces manual local protocol. Gemma 4 names auto-enable native tools |
| `LEGIBLE_CODER_MAX_TOOLS` | No | Maximum tool calls per user turn. Defaults: `60` local, `30` remote |
| `LEGIBLE_CODER_MAX_EXPLORE` | No | Local manual-mode exploration budget before requiring an action. Default: `8` |
| `LEGIBLE_CODER_MAX_OUTPUT_TOKENS` | No | Response cap. Defaults: `750` local manual, `4096` local native tools, `16384` remote |
| `LEGIBLE_CODER_CONTEXT_TOKENS` | No | Rough transcript compaction budget. Defaults: `16000` local, `90000` remote |
| `LEGIBLE_CODER_CONTEXT_KEEP_MESSAGES` | No | Recent messages preserved verbatim during compaction. Defaults: `8` local, `12` remote |
