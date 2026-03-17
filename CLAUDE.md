# legible-coder

An interactive CLI coding assistant written in the Legible programming language. It writes Legible code and performs tasks by running Legible scripts, powered by the `gpt-oss-120b` model via the Groq API.

## Architecture

legible-coder is a single-file Legible program (`coder.lbl`) that implements a Claude Code-style interactive REPL. It uses the Legible interpreter's built-in functions for all I/O, HTTP, JSON, and process operations.

### Core flow

1. User launches `legible run coder.lbl` from their project directory
2. The tool displays a welcome banner and prompt
3. User types a request (write code, run a task, ask a question)
4. The tool builds a message with system prompt + conversation history
5. It calls the Groq API (`gpt-oss-120b`) via `http_client_post`
6. The model responds with either text or tool calls
7. Tool calls are executed (read/write files, run shell commands, list directories)
8. Results are fed back to the model for follow-up
9. The final text response is displayed to the user

### Tool system

The model has access to these tools:
- `read_file` — read a file's contents
- `write_file` — write content to a file
- `shell_exec` — run a shell command
- `list_dir` — list directory contents
- `read_dir_recursive` — recursively list files (via `find`)

### Files

- `coder.lbl` — the complete CLI tool (entry point with `main()`)

## Running

```bash
export GROQ_API_KEY="your-key-here"
cd your-project-directory
legible run /path/to/legible-coder/coder.lbl
```

## Requirements

- The Legible interpreter built with HTTP client and process builtins
- A valid Groq API key in the `GROQ_API_KEY` environment variable
- Network access to `api.groq.com`

## Legible language quick reference

When modifying this tool, remember:
- `let` for immutable bindings, `mutable` for mutable ones, `set` to update
- `++` for string concatenation
- `|>` for pipelines
- `fn(x: type): ret => expr` for lambdas
- `end` closes all blocks (if, for, while, function, match)
- Comments use `--`
- Functions use `function name(params): return_type` with optional `intent:`, `requires:`, `ensures:`
- Records: `record Name ... end`, constructed with `Name { field: value }`
- No semicolons, no curly braces for blocks
