# legible-coder

An interactive CLI coding assistant for the [Legible programming language](../legible/), styled after Claude Code. It writes Legible code and performs tasks by running Legible scripts, powered by the `gpt-oss-120b` model via the [Groq API](https://groq.com/).

```
  legible-coder
  Interactive Legible coding assistant
  Powered by gpt-oss-120b via Groq
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
- A [Groq API key](https://console.groq.com/)

Build the interpreter from source:

```bash
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
export GROQ_API_KEY="your-key-here"
cd your-project-directory
legible-coder
```

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
2. Sends it to `gpt-oss-120b` on Groq with a full Legible language reference in the system prompt
3. If the model calls a tool, executes it and feeds the result back
4. Loops until the model produces a text response
5. Prints the response and waits for the next request

Conversation history is kept in-memory for the duration of the session.

### Tools available to the model

| Tool | Description |
|------|-------------|
| `read_file` | Read a file's contents |
| `write_file` | Create or overwrite a file |
| `shell_exec` | Run a shell command (including `legible run`) |
| `list_dir` | List directory entries |
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
| `GROQ_API_KEY` | Yes | Your Groq API key |
