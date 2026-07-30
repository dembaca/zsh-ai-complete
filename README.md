# zsh-ai-complete

Local LLM-powered shell completion for zsh. Type what you want in plain language, press **Ctrl+X Ctrl+X**, and the suggested command replaces the buffer — never auto-executed.

Talks to a local [oMLX](https://omlx.ai/) OpenAI-compatible endpoint (`/v1/chat/completions`).

## Requirements

- zsh
- `curl` and `jq`
- oMLX (or any OpenAI-compatible server) on `http://127.0.0.1:8000/v1`

## Install

```bash
./install.sh
```

Then edit `~/.config/zsh-ai-complete/config.env`:

```bash
AI_COMPLETE_MODEL=your-model-id
# If oMLX requires auth (default after setup):
AI_COMPLETE_API_KEY=your-omlx-api-key
```

Reload the shell (`source ~/.zshrc` or open a new tab).

## Usage

1. Type a free-text intent in the prompt, e.g. `finde alle pdfs im aktuellen verzeichnis`
2. Press **Ctrl+X** twice
3. Review the command in the buffer
4. Press Enter to run it yourself — or **Ctrl+X u** to restore the free text

Also bound (if your terminal sends Esc+ for Option): **⌥+Enter**.

> Note: Classic `Ctrl+_` undo is awkward on German keyboards; use **Ctrl+X** then **u**.

Destructive patterns (e.g. `rm -rf /`, force-push to main) still land in the buffer, but show a warning via `zle -M`.

### Helpers

| Command       | Effect                                      |
|---------------|---------------------------------------------|
| `ai-status`   | Show enabled state, endpoint, model, binary |
| `ai-disable`  | Turn off the keybinding behavior            |
| `ai-enable`   | Turn it back on                             |

### CLI (without ZLE)

```bash
export AI_COMPLETE_MODEL=your-model-id
./bin/ai-complete "finde alle pdfs im aktuellen Verzeichnis"
```

Exit codes: `0` clean, `2` success with safety warning (command still on stdout), `1` error.

## Configuration

Environment / `~/.config/zsh-ai-complete/config.env`:

| Variable               | Default                         | Notes                                      |
|------------------------|---------------------------------|--------------------------------------------|
| `AI_COMPLETE_MODEL`    | *(required)*                    | No silent default — must be set            |
| `AI_COMPLETE_ENDPOINT` | `http://127.0.0.1:8000/v1`      | OpenAI base URL (client appends `/chat/completions`) |
| `AI_COMPLETE_API_KEY`  | *(optional)*                    | Bearer token when oMLX auth is on          |
| `AI_COMPLETE_TIMEOUT`  | `30`                            | Seconds                                    |
| `AI_COMPLETE_HISTORY`  | `8`                             | Recent history lines sent as context       |
| `AI_COMPLETE_ENABLED`  | `1`                             | `0` disables the widget                    |

## Safety

`lib/safety.sh` flags patterns such as:

- `rm -rf` on `/`, `~`, or `$HOME`
- `dd if=…`
- `mkfs`, `diskutil erase`
- `git push --force` / `-f` to `main`/`master`
- `chmod … 777`
- fork bombs, redirects to `/dev/sd*`

v1 behavior: **warn and still insert**.

```bash
./tests/test_safety.sh
```

## Layout

```
bin/ai-complete                 # bash client
lib/context.sh                  # cwd / git / history / os
lib/safety.sh                   # destructive pattern check
plugin/ai-complete.plugin.zsh   # ZLE widget + Ctrl+X Ctrl+X
config/default.env              # install template
install.sh
```

## Not in v1

Ghost text, response cache, Anthropic `/v1/messages`, streaming, daemon lifecycle.
