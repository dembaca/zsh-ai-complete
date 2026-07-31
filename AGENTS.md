# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A zsh plugin that provides local-LLM-powered shell completion. The user types a free-text intent, presses **Ctrl+X Ctrl+X**, and a suggested command appears as POSTDISPLAY ghost text. The suggestion is never auto-executed — the user must explicitly accept it.

Talks to any OpenAI-compatible endpoint (default: `http://127.0.0.1:8000/v1`, designed for [oMLX](https://omlx.ai/)).

## Running and testing

```bash
# Run safety pattern tests (no external deps)
./tests/test_safety.sh

# CLI smoke test (requires a running LLM endpoint)
AI_COMPLETE_MODEL=your-model ./bin/ai-complete "list pdf files here"
```

There is no build step. The plugin is pure bash/zsh — no compilation, no package manager.

## Architecture

The plugin has two layers that communicate only via subprocess + exit code:

**`bin/ai-complete`** (bash) — the stateless CLI:
1. Sources `lib/context.sh` to build a context block (cwd, git state, recent history, OS)
2. Sends a `POST /v1/chat/completions` request via `curl` + `jq`
3. Sanitizes the response (strips markdown fences, language tags)
4. Sources `lib/safety.sh` to pattern-match against `lib/dangerous.patterns`
5. Exits `0` (clean), `2` (command on stdout but safety warning on stderr), or `1` (error)

**`plugin/ai-complete.plugin.zsh`** — the ZLE layer:
- Wraps `accept-line`, `expand-or-complete`, `forward-char`, `self-insert`, `backward-delete-char`, `send-break` using `_ai_complete_wrap` / `_ai_complete_call_orig` to chain without clobbering fzf-tab or other plugins
- State machine: `_AI_COMPLETE_PENDING` tracks whether a ghost suggestion is displayed; all bound keys check this first
- Ghost text lives in `POSTDISPLAY`; style applied via `region_highlight`
- `AI_COMPLETE_MODE=ghost` (default) vs `replace` (direct buffer swap) are both supported

**`lib/context.sh`** — pure bash, no side effects; reads `$PWD`, `git`, `$HISTFILE`, `ls`

**`lib/dangerous.patterns`** — TSV: `label<TAB>bash-ERE`. Parsed line-by-line in `safety.sh`. Extend this file to add new warn patterns.

## Key design constraints

- **Ghost text is never auto-run** — `ai-complete-accept-line` only moves the suggestion into `BUFFER`; the user must press Enter again
- **Safety warns but never blocks** — exit code 2 means "inserted with visual warning", not "rejected"
- **Reentrancy guard** — `_AI_COMPLETE_IN_ORIG` prevents FUNCNEST when other plugins call the same widget names internally
- **`_ai_complete_wrap` is idempotent** — safe to re-source the plugin (e.g., after `source ~/.zshrc`)

## Configuration

User config lives at `~/.config/zsh-ai-complete/config.env` (XDG-aware). The install script (`install.sh`) copies `config/default.env` there on first run and appends a sourcing block to `~/.zshrc`.

`AI_COMPLETE_MODEL` has no default and must be set. All other variables have defaults in the plugin file.
