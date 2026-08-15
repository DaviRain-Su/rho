# pi-rhm

A [Pi](https://pi.dev)-style, hot-reloadable coding agent written in
[Rhombus](https://rhombus-lang.org/). Minimal harness, everything else is an
extension — and the agent can write, reload, and use its own extensions in the
same session.

```
❯ Create a tool named shout that uppercases text, activate it, then use it.
● write_file .pi-rhm/extensions/shout.rhm
● reload_extensions {}
● shout {"text": "hello rhombus"}
  ↳ HELLO RHOMBUS!!!
```

## Requirements

- [Rhombus + Racket combined install](https://rhombus-lang.org/download.html)
  (tested with Rhombus 1.1 on Racket 9.3); `http-easy` ships with it
- An API key in the environment (see providers below)

## Setup

```bash
raco pkg install --link --name pi-rhm /path/to/this/repo   # enables lib("pi-rhm/...") imports
racket src/main.rhm                                        # start the REPL
```

Options: `-p/--provider NAME`, `-m/--model NAME`, `--resume SESSION.jsonl`.

Built-in provider profiles (override or extend in `~/.pi-rhm/config.json`):

| Provider | Protocol | Key env var |
|---|---|---|
| `kimi` (default) | OpenAI chat completions | `KIMI_API_KEY` |
| `kimi-anthropic` | Anthropic messages | `KIMI_API_KEY` |
| `openai` | OpenAI chat completions | `OPENAI_API_KEY` |
| `openrouter` | OpenAI chat completions | `OPENROUTER_API_KEY` |
| `ollama` | OpenAI chat completions | (none) |
| `anthropic` | Anthropic messages | `ANTHROPIC_API_KEY` |

## Commands

`/help` `/model [name]` `/provider [name]` `/reload` `/session` `/clear` `/quit`
plus any commands registered by extensions.

## Extensions

Extensions are Rhombus modules exporting `init(pi)`, discovered from:

- `~/.pi-rhm/extensions/*.rhm` (global)
- `.pi-rhm/extensions/*.rhm` (project-local)

```
#lang rhombus
export: init
fun init(pi):
  pi.register_tool(
    ~name: "my_tool",
    ~description: "what it does",
    ~schema: { "type": "object",
               "properties": { "x": { "type": "string" } },
               "required": ["x"] },
    ~fn: fun (args): "result: " +& args.get("x", ""))
```

API surface:

- `pi.register_tool(~name, ~description, ~schema, ~fn)` — tool callable by the model
- `pi.register_command(~name, ~description, ~handler)` — `/command` in the REPL
- `pi.on(event, fn)` — events: `session_start`, `user_message`, `tool_call`,
  `tool_result`, `turn_end`; a `tool_call` handler may return
  `{"block": #true, "reason": ...}` to veto a tool execution
- `pi.state` — mutable map owned by the kernel; survives `/reload`
- `pi.notify(msg)` — print a status line

### The `tool` macro

Because the host language is Rhombus, extensions can use a macro that derives
the JSON schema from annotations (this is the part a TypeScript harness cannot
do):

```
#lang rhombus
import: lib("pi-rhm/src/ext/tool.rhm") open
export: init
fun init(pi):
  tool pi greet(name :: String, times :: Int = 1) ~desc "Greet someone":
    String.join(for List (_ in 0..times): "Hello, " +& name +& "!", " ")
```

Parameters with defaults become optional in the schema; missing required
arguments raise a clear error. See `examples/extensions/`.

## Hot reload

Extensions are loaded through Racket's `dynamic-rerequire`, which tracks file
modification times. `/reload` (or the `reload_extensions` tool, which the agent
can call on itself) recompiles only changed modules, wipes all
extension-contributed registry entries, and re-runs each `init(pi)`. Kernel
state — the session, provider connections, and `pi.state` — survives reloads.

## Layout

```
src/
  main.rhm            CLI entry, built-in commands, system prompt
  kernel/
    config.rhm        provider profiles, ~/.pi-rhm/config.json
    registry.rhm      tools / commands / event handlers / state
    session.rhm       append-only JSONL sessions (~/.pi-rhm/sessions/)
    loop.rhm          agent loop: stream, execute tools, repeat
    reload.rkt        dynamic-rerequire + rhombus-dynamic-require shim
  ai/
    types.rhm         canonical message helpers
    sse.rhm           SSE parser
    openai.rhm        OpenAI-compatible streaming client
    anthropic.rhm     Anthropic messages streaming client
  tools/core.rhm      read_file / write_file / edit_file / bash
  ext/
    api.rhm           the `pi` object handed to extensions
    loader.rhm        discovery + hot reload
    tool.rhm          `tool` definition macro
examples/extensions/  greet.rhm (tool macro), guard.rhm (tool_call veto)
tests/                runnable test modules (t_*.rhm)
```

## Known limitations

- Line-oriented REPL (no fullscreen TUI yet; `raart` is the candidate)
- Linear session history (no tree navigation), no compaction
- No sub-agents, no package manager for extensions
