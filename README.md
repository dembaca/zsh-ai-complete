# zsh-ai-complete

LLM-powered shell completion for zsh. Type what you want in plain language, press **Ctrl+X Ctrl+X** (memorize: ["Hex-Hex"](https://www.youtube.com/watch?v=_klGQkeE7sk)), and the suggested command appears as **ghost text** (preview) — never auto-executed.

![Demo of zsh-ai-complete](demo.gif)

Talks to a local [oMLX](https://omlx.ai/) OpenAI-compatible endpoint (`/v1/chat/completions`) on my Apple Silicon. I made goo experiences with a Use whatever you have.

## Requirements

- zsh
- `curl` and `jq`
- OpenAI-compatible server

## Install

### Oh My Zsh

```bash
git clone https://github.com/dembaca/zsh-ai-complete \
  ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-ai-complete
```

Add `zsh-ai-complete` to the `plugins=(...)` list in `~/.zshrc`, then reload the shell.

On first load the plugin creates `~/.config/zsh-ai-complete/config.env` from the defaults — set `AI_COMPLETE_MODEL` there (see below).

### Without Oh My Zsh

```bash
./install.sh
```

That copies the config template (if missing) and appends a sourcing block to `~/.zshrc`.

### Config

Edit `~/.config/zsh-ai-complete/config.env`:

```bash
AI_COMPLETE_MODEL=your-model-id
# If oMLX requires auth (default after setup):
AI_COMPLETE_API_KEY=your-api-key
```

Reload the shell (`source ~/.zshrc` or open a new tab).

## Usage

1. Type a free-text intent, e.g. `find all pdfs in the current directory`
2. Press **Ctrl+X** twice → suggestion shows as dim ghost text (`!!! …` + reverse video if safety warn)
3. **Accept** (into the buffer, still not run): **Tab**, **→**, **Enter**, or **Ctrl+X Ctrl+X** again
4. Press **Enter** again to run — or discard first

**Discard** ghost / restore free text: **Ctrl+X u**, **Ctrl+G**, **Backspace**, or just start typing.

Also bound (if Option sends Esc+): **⌥+Enter**.

To skip the preview and replace the buffer directly, set `AI_COMPLETE_MODE=replace` in `config.env`.

Successful intents are appended to zsh history as `# …` (safe comment if `interactivecomments` is on — the plugin enables it).

### Helpers

| Command       | Effect                                      |
|---------------|---------------------------------------------|
| `ai-status`   | Show enabled state, endpoint, model, binary |
| `ai-disable`  | Turn off the keybinding behavior            |
| `ai-enable`   | Turn it back on                             |

### CLI (without ZLE)

```bash
export AI_COMPLETE_MODEL=your-model-id
./bin/ai-complete "find all pdfs in the current directory"
```

Exit codes: `0` clean, `2` success with safety warning (command still on stdout), `1` error.

## Configuration

Environment / `~/.config/zsh-ai-complete/config.env`:

| Variable               | Default                         | Notes                                      |
|------------------------|---------------------------------|--------------------------------------------|
| `AI_COMPLETE_MODEL`    | *(required)*                    | No silent default — must be set            |
| `AI_COMPLETE_ENDPOINT` | `http://127.0.0.1:8000/v1`      | OpenAI base URL (client appends `/chat/completions`) |
| `AI_COMPLETE_API_KEY`  | *(optional)*                    | Bearer token when auth is on               |
| `AI_COMPLETE_TIMEOUT`  | `30`                            | Seconds                                    |
| `AI_COMPLETE_HISTORY`  | `8`                             | Recent history lines sent as context       |
| `AI_COMPLETE_MODE`     | `ghost`                         | `ghost` (preview) or `replace` (direct buffer swap) |
| `AI_COMPLETE_SAVE_PROMPTS` | `1`                         | Write `# …` intents into zsh history       |
| `AI_COMPLETE_ENABLED`  | `1`                             | `0` disables the widget                    |
| `AI_COMPLETE_GHOST_WARN_PREFIX` | `!!! `               | Text prepended to a safety-warn ghost      |
| `AI_COMPLETE_GHOST_WARN_SUFFIX` | ` !!!`               | Text appended to a safety-warn ghost       |

## Safety

`lib/safety.sh` loads curated bash-ERE patterns from [`lib/dangerous.patterns`](lib/dangerous.patterns) and **warns** (still inserts) on matches such as broad `rm -rf`, `dd`/`mkfs`/`diskutil`, force-push to main, `curl|bash`, macOS wipe helpers, etc.

**These patterns are not a security system.** Any determined attacker — or a sufficiently creative model — can trivially bypass them (e.g. `echo "cm0gLXJmIH4K" | base64 -d | sh`). The sole intent is to protect you from yourself: an extra visual jolt before you accept something destructive when you're tired, distracted, or on your third coffee. You always see the command before it runs. You are the last line of defence.

Patterns are a curated subset rewritten for bash `[[ =~ ]]`, inspired by **[hardstop-patterns](https://github.com/frmoretto/hardstop-patterns)** (MIT). Attribution: [`NOTICE`](NOTICE). Related: [hardstop](https://github.com/frmoretto/hardstop). Override path with `AI_COMPLETE_PATTERNS_FILE`.

```bash
./tests/test_safety.sh
```

## Layout

```
zsh-ai-complete.plugin.zsh      # ZLE widget (Oh My Zsh entry point)
bin/ai-complete                 # bash client
lib/context.sh                  # cwd / git / history / os
lib/safety.sh                   # pattern loader + check
lib/dangerous.patterns          # curated warn list (bash ERE)
NOTICE                          # hardstop-patterns attribution (MIT)
config/default.env              # config template
install.sh                      # non-OMZ installer
```

## Disclaimer

Substantial parts of this project were generated or edited with AI coding assistants. Treat it like any other third-party shell tooling: review the code before installing, especially the ZLE plugin and safety patterns. No warranty — use at your own risk.
