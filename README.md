# rho (ρ)

A [Pi](https://pi.dev)-style, hot-reloadable coding agent written in
[Rhombus](https://rhombus-lang.org/). Minimal harness, everything else is an
extension — and the agent can write, reload, and use its own extensions in the
same session.

```
❯ Create a tool named shout that uppercases text, activate it, then use it.
● write_file .rho/extensions/shout.rhm
● reload_extensions {}
● shout {"text": "hello rhombus"}
  ↳ HELLO RHOMBUS!!!
```

## Requirements

- [Rhombus + Racket combined install](https://rhombus-lang.org/download.html)
  (tested with Rhombus 1.1 on Racket 9.3); `http-easy` ships with it
- `raco pkg install raart` for the full-screen TUI
- An API key in the environment (see providers below)

## Setup

```bash
raco pkg install --link --name rho /path/to/this/repo   # enables lib("rho/...") imports
racket src/main.rhm                                     # TUI on a terminal
racket src/main.rhm --tui-mode plain                    # readline REPL
```

## CLI

```
rho [options] [message ...]           interactive (TUI by default on a tty)
rho -p "prompt"                       headless: run one turn, print, exit
cat data | rho -p "analyze stdin"     piped stdin merges into the prompt
rho -p @notes.md "summarize"          @file inlines file content
rho -p @shot.png "what is this?"      @image attaches it (png/jpg/gif/webp)
rho --mode json -p "..."              JSONL event stream output
rho --mode rpc                        JSON-lines RPC over stdin/stdout
rho install <git-url|owner/repo>      install a package
rho remove <name> / rho list          manage packages
```

| Flag | Meaning |
|---|---|
| `-p` / `--print` | headless single turn |
| `--mode text\|json\|rpc` | output protocol |
| `--provider NAME` / `-m NAME` | provider / model |
| `--thinking low\|medium\|high` | reasoning effort (OpenAI) / thinking budget (Anthropic) |
| `--list-models` | show the model registry |
| `-c` / `-r` | continue latest session / pick one interactively |
| `--session PATH\|ID` / `--fork` / `--no-session` / `--name N` | session control |
| `--tools a,b` / `--exclude-tools a,b` / `--no-tools` | tool filtering |
| `--system-prompt S` / `--append-system-prompt S` | system prompt override |
| `--no-context-files` / `--no-extensions` | skip discovery |
| `--theme NAME` / `--tui-mode tui\|plain` | UI |

Built-in provider profiles (override or extend in `~/.rho/config.json`):

| Provider | Protocol | Key env var |
|---|---|---|
| `kimi` (default) | OpenAI chat completions | `KIMI_API_KEY` |
| `kimi-anthropic` | Anthropic messages | `KIMI_API_KEY` |
| `openai` | OpenAI platform API | `OPENAI_API_KEY` |
| `openai-codex` | ChatGPT subscription (Codex) | `/login openai oauth` |
| `openrouter` | OpenAI chat completions | `OPENROUTER_API_KEY` |
| `ollama` | OpenAI chat completions | (none) |
| `anthropic` | Anthropic messages | `ANTHROPIC_API_KEY` |

`~/.rho/config.json` also takes `"settings"`: `reserve_tokens`,
`keep_recent_tokens` (compaction), `theme`, `tui_mode`,
`default_project_trust` (`"trust"`/`"ignore"` for headless runs).
`~/.rho/models.json` extends the model registry (context window, pricing,
thinking support).

## Context files

System prompt context is assembled from `~/.rho/AGENTS.md`, then `AGENTS.md`
in each directory from the root down to the cwd (`AGENTS.override.md` wins
over `AGENTS.md`, `CLAUDE.md` is the fallback). `.rho/SYSTEM.md` (or
`~/.rho/SYSTEM.md`) replaces the default system prompt;
`APPEND_SYSTEM.md` appends.

## Sessions

Sessions are trees: every entry has an id and parent, and the active
conversation is the path from the current leaf to the root. Files live in
`~/.rho/sessions/<encoded-cwd>/*.jsonl` and record token usage per assistant
message.

- `/tree` view the tree, `/tree <id>` move the leaf, `/fork [id]` branch
  before a user message (press ↑ to edit it), `/clone`, `/new`, `/name`,
  `/resume`, `/export [file.html|.jsonl]`, `/import file`
- `/session` shows the file plus token totals and cost (from the model
  registry); `/compact [instructions]` summarizes old turns manually, and
  compaction runs automatically when the context nears the window
  (`CompactionEntry` in the tree; context is rebuilt as summary + kept turns).
  `/model` to a smaller window compacts with the outgoing model first so the
  history still fits; Ctrl-P defers that compact until the next turn.

## TUI

Full-screen interface (raart): transcript, multi-line editor, footer with
cwd/model/tokens/cost. `/hotkeys` lists keys: Enter submits, Ctrl-J inserts a
newline, Tab completes paths (`@token` fuzzy-searches the repo), Up/Down is
history or cursor movement, PgUp/PgDn scrolls, Ctrl-C interrupts (or clears /
quits), Esc interrupts, Ctrl-P cycles providers, Ctrl-D quits. `!cmd` runs a
shell command; `!!cmd` also appends the output to the model context. Themes:
`~/.rho/themes/<name>.json` + `--theme` (see `examples/themes/`).

While a turn runs you can keep typing: plain lines become steering messages
injected after the current tool batch; `/follow <msg>` queues a follow-up
turn. The same works in the plain REPL and via `steer` in RPC mode.

The editor highlights `/commands`, `!shell`, `@files`, and `` `code` ``.
Kill-ring: Ctrl-K (to end of line), Ctrl-W (word), Ctrl-U (whole line),
Ctrl-Y yank, Alt-Y yank-pop. Consecutive kills append.
Chain of thought streams dim into the transcript (`Ctrl-T` hides it;
`/thinking` or Shift-Tab sets the effort). Mouse drag selects transcript
text and copies on release (Shift+drag uses the terminal's native selection).

## Skills and prompt templates

Skills (agentskills.io convention: directories with `SKILL.md` + YAML
frontmatter) are discovered in `~/.rho/skills/`, `~/.agents/skills/`, the
project's `.rho/skills/` and `.agents/skills/`, and installed packages. Their
names/descriptions are injected into the system prompt as XML (progressive
disclosure: the agent reads the full file with `read_file` when needed);
`/skill:name` force-loads one. Prompt templates are `*.md` files in
`~/.rho/prompts/` or `.rho/prompts/` invoked as `/<name> args`
(`$ARGUMENTS` substitution, `description`/`argument-hint` frontmatter).

## Packages and trust

`rho install git:<url>` (or `owner/repo`) clones into `~/.rho/packages/`;
a package's `extensions/`, `skills/` and `prompts/` directories join the
discovery paths. `/packages` lists them, `/share` uploads the session as a
gist via the `gh` CLI.

The first time rho runs in a project with a `.rho/` directory it asks whether
to trust it; the decision is stored in `~/.rho/trust.json`. Untrusted project
extensions/skills/prompts are ignored (headless runs use the
`default_project_trust` setting).

## Commands

`/help` `/hotkeys` `/model` `/provider` `/reload` `/session` `/tree` `/fork`
`/clone` `/new` `/name` `/resume` `/export` `/import` `/compact` `/clear`
`/login` `/logout` `/skills` `/prompts` `/packages` `/share` `/quit` — plus
extension commands, `/skill:name`, and `/template-name`.

`/login <provider> oauth` opens the browser and returns immediately (TUI
must not block). After authorizing, paste the code or redirect URL:
`/login anthropic oauth <code#state-or-url>`. OpenAI also completes on
the localhost callback in the background. API keys: `/login kimi sk-...`.
Tokens live in `~/.rho/auth.json` (0600) and refresh automatically.

## Tools

`read_file` `write_file` `edit_file` `bash` `grep` `find` `ls`
`agent` `reload_extensions` — filterable with `--tools`/`--exclude-tools`/`--no-tools`.

`agent` runs a nested sub-agent with its own session (no further nesting).
Pass `prompt`, optional `label`, and optional `tools` (comma-separated allowlist).
The TUI streams the child's text and tool calls live (indented, status
`sub-agent <label>: <tool>`); Ctrl-O still folds long tool output.

## Extensions

Extensions are Rhombus modules exporting `init(rho)`, discovered from
`~/.rho/extensions/*.rhm`, installed packages, and (if trusted)
`.rho/extensions/*.rhm`.

```
#lang rhombus
export: init
fun init(rho):
  rho.register_tool(
    ~name: "my_tool",
    ~description: "what it does",
    ~schema: { "type": "object",
               "properties": { "x": { "type": "string" } },
               "required": ["x"] },
    ~fn: fun (args): "result: " +& args.get("x", ""))
```

API surface:

- `rho.register_tool(~name, ~description, ~schema, ~fn)`
- `rho.register_command(~name, ~description, ~handler)`
- `rho.on(event, fn)` — events: `session_start`, `user_message`,
  `agent_start`/`agent_end`, `turn_start`/`turn_end`, `before_request`
  (return `{"messages": [...]}` to inject transient context), `tool_call`
  (return `{"block": #true, "reason": ...}` to veto),
  `tool_execution_start`/`tool_execution_end`, `tool_result`,
  `subagent_start`/`subagent_end`
- `rho.state` — mutable map, survives `/reload`
- `rho.session` / `rho.append_entry(data)` — session access + custom entries
- `rho.ui.confirm(msg)` / `rho.ui.select(msg, options)` / `rho.ui.input(msg)`
- `rho.flag("name")` / `rho.register_flag(~name)` — read `--name[=value]`
  CLI flags
- `rho.register_renderer(~tool, ~fn)` — custom transcript rendering;
  `fn(phase, name, data)` returns a string or `#false`
- `rho.notify(msg)`

### The `tool` macro

Because the host language is Rhombus, extensions can use a macro that derives
the JSON schema from annotations (this is the part a TypeScript harness cannot
do):

```
#lang rhombus
import: lib("rho/src/ext/tool.rhm") open
export: init
fun init(rho):
  tool rho greet(name :: String, times :: Int = 1) ~desc "Greet someone":
    String.join(for List (_ in 0..times): "Hello, " +& name +& "!", " ")
```

Parameters with defaults become optional in the schema; missing required
arguments raise a clear error. See `examples/extensions/`.

## Hot reload

Extensions are loaded through Racket's `dynamic-rerequire`, which tracks file
modification times. `/reload` (or the `reload_extensions` tool, which the agent
can call on itself) recompiles only changed modules, wipes all
extension-contributed registry entries, and re-runs each `init(rho)`. Kernel
state — the session, provider connections, and `rho.state` — survives reloads.

## Layout

```
src/
  main.rhm            CLI entry, commands, system prompt, mode dispatch
  kernel/
    config.rhm        provider profiles, ~/.rho/config.json
    registry.rhm      tools / commands / event handlers / state / filters
    session.rhm       session tree, JSONL persistence (~/.rho/sessions/)
    loop.rhm          agent loop: stream, execute tools, steering, events
    subagent.rhm      nested agent tool (isolated session, depth 1)
    oauth.rhm         PKCE login + token refresh
    crypto.rkt        PKCE / url-encode / localhost callback
    context.rhm       AGENTS.md hierarchy, SYSTEM.md/APPEND_SYSTEM.md
    compaction.rhm    token estimation + split-summarize compaction
    skills.rhm        skill discovery + XML injection
    prompts.rhm       prompt templates
    frontmatter.rhm   minimal YAML frontmatter parser
    packages.rhm      ~/.rho/packages (git clone)
    trust.rhm         ~/.rho/trust.json
    reload.rkt        dynamic-rerequire + rhombus-dynamic-require shim
  ai/
    types.rhm         canonical message helpers
    sse.rhm           SSE parser
    openai.rhm        OpenAI-compatible streaming client (+usage/thinking)
    anthropic.rhm     Anthropic messages streaming client (+usage/thinking)
    models.rhm        model metadata registry (+ ~/.rho/models.json)
  tools/core.rhm      read/write/edit/bash/grep/find/ls
  ext/
    api.rhm           the `rho` object handed to extensions
    loader.rhm        discovery + hot reload
    tool.rhm          `tool` definition macro
  ui/
    repl.rhm          readline REPL (steering, /follow, Ctrl-C)
    tui.rhm           raart full-screen TUI
    style.rhm         markdown + editor highlighting, width wrap
    term.rkt          raart lux-chaos shim
examples/extensions/  greet.rhm (tool macro), guard.rhm (tool_call veto)
examples/themes/      solarized.json
tests/                runnable test modules (t_*.rhm)
```

## Known limitations

- No MCP, and no OAuth for providers that only accept API keys (Kimi, Ollama, …)
- ChatGPT subscription login is the `openai-codex` provider (`/login openai oauth`). It calls `chatgpt.com/backend-api/codex/responses`. Platform `openai` still needs `OPENAI_API_KEY` with billing.
- TUI editor highlighting is command/`@file`/`code`, not full language syntax
