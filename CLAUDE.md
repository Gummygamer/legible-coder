# legible-coder

An interactive CLI coding assistant written in the Legible programming language. It writes Legible code and performs tasks by running Legible scripts through an OpenAI-compatible chat completions API. The default backend is Qwen (DashScope) with `qwen3.8-max`, with Gemini, OrcaRouter, NVIDIA NIM, OpenRouter, and Groq as remote fallbacks in that order.

## Architecture

legible-coder is a single-file Legible program (`coder.lbl`) that implements a Claude Code-style interactive REPL. It uses the Legible interpreter's built-in functions for all I/O, HTTP, JSON, and process operations.

### Core flow

1. User launches `legible run coder.lbl` from their project directory
2. The tool displays a welcome banner and prompt
3. User types a request (write code, run a task, ask a question)
4. The tool builds a message with system prompt + conversation history
5. It calls an OpenAI-compatible chat completions API via `http_client_post`
6. The model responds with either text or tool calls
7. Tool calls are executed (read/write files, run shell commands, list directories)
8. Results are fed back to the model for follow-up
9. The final text response is displayed to the user

Conversation context is bounded by rough token estimates. When the transcript
crosses `LEGIBLE_CODER_CONTEXT_TOKENS`, older non-system messages are compacted
into a synthetic system summary and the most recent messages are preserved
verbatim. The compaction boundary walks backward over `tool` messages so native
OpenAI-compatible tool results are not orphaned from their assistant tool-call
message.

### Tool system

The model has access to these tools:
- `read_file` — read a file's contents
- `read_file_lines` — read a fixed 40-line slice with line numbers
- `write_file` — write content to a file
- `shell_exec` — run a shell command
- `list_dir` — list directory contents
- `read_dir_recursive` — recursively list files (via `find`)
- `grep` — search for patterns in files

`write_file` strips a wrapping markdown code fence from the content (some
models, notably on NIM, wrap file content in ``` fences) and runs
`legible check` on written `.lbl` files, feeding any errors back to the model
in the tool result so it can immediately rewrite the file.

Local endpoints default to the manual `TOOL name JSON_arguments` protocol unless
the model name looks like Gemma 4 or `LEGIBLE_CODER_LOCAL_TOOLS=1` is set. Set
`LEGIBLE_CODER_LOCAL_TOOLS=0` to force the manual fallback for a local server
whose OpenAI-compatible tool support is incomplete.

### Files

- `coder.lbl` — the complete CLI tool (entry point with `main()`)

## Running

```bash
export OPENAI_API_KEY="your-qwen-key-here"
export GEMINI_API_KEY="your-gemini-key-here"
export ORCAROUTER_API_KEY="your-orcarouter-key-here"
export NVIDIA_API_KEY="your-nvidia-nim-key-here"
export OPENROUTER_API_KEY="your-openrouter-key-here"
cd your-project-directory
legible run /path/to/legible-coder/coder.lbl
```

## Requirements

- The Legible interpreter built with HTTP client and process builtins
- A valid Qwen API key in `OPENAI_API_KEY`, `DASHSCOPE_API_KEY`, or
  `ALIBABA_TOKEN_PLAN_API_KEY`. When multiple names are set, the precedence is
  `DASHSCOPE_API_KEY`, `ALIBABA_TOKEN_PLAN_API_KEY`, then `OPENAI_API_KEY`. It uses the DashScope OpenAI-compatible
  endpoint `https://dashscope-intl.aliyuncs.com/compatible-mode/v1`
- Optionally, a Gemini API key in `GEMINI_API_KEY` for the first remote fallback
- Optionally, an OrcaRouter API key in `ORCAROUTER_API_KEY` for the second remote fallback (`qwen/qwen3.8-27b-free`)
- Optionally, an NVIDIA NIM API key in `NVIDIA_API_KEY` for the third remote fallback
- Optionally, an OpenRouter API key in `OPENROUTER_API_KEY` for the fourth remote fallback
- Network access to Qwen, Gemini, OrcaRouter, NIM, OpenRouter, Groq, or an OpenAI-compatible local server via
  `LEGIBLE_CODER_BASE_URL`

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
