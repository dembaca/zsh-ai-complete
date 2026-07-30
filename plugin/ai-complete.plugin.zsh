# zsh-ai-complete — ZLE widget + helpers
# Source from ~/.zshrc or via install.sh
#
# experiment/ghost-text: suggestions appear as POSTDISPLAY ghost text.
# Accept: Tab / → / Enter (puts command in BUFFER, does NOT run)
# Discard: Esc / Ctrl+X u / typing
# Switch back: AI_COMPLETE_MODE=replace  or checkout main

() {
  local plugin_dir="${${(%):-%x}:A:h}"
  typeset -g AI_COMPLETE_ROOT="${AI_COMPLETE_ROOT:-${plugin_dir:A}/..}"
  AI_COMPLETE_ROOT="${AI_COMPLETE_ROOT:A}"
}

typeset -g AI_COMPLETE_BIN="${AI_COMPLETE_BIN:-$AI_COMPLETE_ROOT/bin/ai-complete}"
typeset -g AI_COMPLETE_ENABLED="${AI_COMPLETE_ENABLED:-1}"
typeset -g AI_COMPLETE_ENDPOINT="${AI_COMPLETE_ENDPOINT:-http://127.0.0.1:8000/v1}"
typeset -g AI_COMPLETE_TIMEOUT="${AI_COMPLETE_TIMEOUT:-30}"
typeset -g AI_COMPLETE_HISTORY="${AI_COMPLETE_HISTORY:-8}"
# ghost (default on this branch) | replace
typeset -g AI_COMPLETE_MODE="${AI_COMPLETE_MODE:-ghost}"
typeset -g AI_COMPLETE_GHOST_STYLE="${AI_COMPLETE_GHOST_STYLE:-fg=8}"
# Safety warn: reverse-video + bold (bg colors on POSTDISPLAY are unreliable).
# Visible ASCII prefix is the portable “look at me” signal.
typeset -g AI_COMPLETE_GHOST_WARN_STYLE="${AI_COMPLETE_GHOST_WARN_STYLE:-standout,bold}"
typeset -g AI_COMPLETE_GHOST_WARN_PREFIX="${AI_COMPLETE_GHOST_WARN_PREFIX:-!!! }"
# Save free-text intents to zsh history as "# …" (noop if re-run with interactivecomments)
typeset -g AI_COMPLETE_SAVE_PROMPTS="${AI_COMPLETE_SAVE_PROMPTS:-1}"

typeset -g _AI_COMPLETE_UNDO_BUFFER=
typeset -g _AI_COMPLETE_UNDO_CURSOR=0
typeset -g _AI_COMPLETE_CAN_UNDO=0
typeset -g AI_COMPLETE_SAVED_STATUS=0
typeset -g AI_COMPLETE_SAVED_CMD=

typeset -g _AI_COMPLETE_PENDING=0
typeset -g _AI_COMPLETE_SUGGESTION=
typeset -g _AI_COMPLETE_SUGGESTION_WARN=0
typeset -g _AI_COMPLETE_LAST_HIGHLIGHT=

# Load user config if present
if [[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/zsh-ai-complete/config.env" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${XDG_CONFIG_HOME:-$HOME/.config}/zsh-ai-complete/config.env"
  set +a
fi

# So "# …" history entries are harmless if executed
setopt interactivecomments

# Capture $? + last command after each prompt command (widget-local $? is unreliable)
_ai_complete_precmd() {
  AI_COMPLETE_SAVED_STATUS=$?
  AI_COMPLETE_SAVED_CMD="${$(fc -ln -1 2>/dev/null)##[[:space:]]#}"
  # Fresh prompt: drop any leftover ghost
  _ai_complete_clear_ghost
}
precmd_functions=(${precmd_functions:#_ai_complete_precmd})
precmd_functions=(_ai_complete_precmd ${precmd_functions[@]})

ai-enable() {
  typeset -g AI_COMPLETE_ENABLED=1
  print -u2 "ai-complete: enabled"
}

ai-disable() {
  typeset -g AI_COMPLETE_ENABLED=0
  _ai_complete_clear_ghost
  print -u2 "ai-complete: disabled"
}

ai-status() {
  local model="${AI_COMPLETE_MODEL:-<unset>}"
  local key="<unset>"
  [[ -n "${AI_COMPLETE_API_KEY:-}" ]] && key="(set)"
  local enabled="off"
  [[ "$AI_COMPLETE_ENABLED" == "1" ]] && enabled="on"
  print "ai-complete: $enabled"
  print "  mode:     $AI_COMPLETE_MODE"
  print "  prompts:  ${AI_COMPLETE_SAVE_PROMPTS} (# … → history)"
  print "  endpoint: $AI_COMPLETE_ENDPOINT"
  print "  model:    $model"
  print "  api key:  $key"
  print "  bin:      $AI_COMPLETE_BIN"
}

# Push free-text intent into zsh history as a comment line
_ai_complete_save_prompt() {
  [[ "$AI_COMPLETE_SAVE_PROMPTS" == "1" ]] || return 0
  local prompt="${1:-}"
  [[ -n "$prompt" ]] || return 0
  # First line only — never flatten a pasted second command into the history entry
  prompt="${prompt%%$'\n'*}"
  prompt="${prompt##[[:space:]]#}"
  prompt="${prompt%%[[:space:]]#}"
  [[ -n "$prompt" ]] || return 0
  # Avoid nesting if user re-triggered a history comment
  [[ "$prompt" == \#* ]] && return 0
  print -s -r -- "# $prompt"
}

_ai_complete_highlight_reset() {
  if [[ -n "${_AI_COMPLETE_LAST_HIGHLIGHT:-}" ]]; then
    region_highlight=("${(@)region_highlight:#$_AI_COMPLETE_LAST_HIGHLIGHT}")
    unset _AI_COMPLETE_LAST_HIGHLIGHT
  fi
}

_ai_complete_highlight_range() {
  local start=$1 end=$2 style=$3
  _ai_complete_highlight_reset
  _AI_COMPLETE_LAST_HIGHLIGHT="$start $end $style"
  region_highlight+=("$_AI_COMPLETE_LAST_HIGHLIGHT")
}

# Refresh zsh-syntax-highlighting / fast-syntax-highlighting after we mutate BUFFER
_ai_complete_syntax_highlight() {
  if (( ${+functions[_zsh_highlight]} )); then
    _zsh_highlight
  fi
}

_ai_complete_clear_ghost() {
  _ai_complete_highlight_reset
  POSTDISPLAY=
  _AI_COMPLETE_PENDING=0
  _AI_COMPLETE_SUGGESTION=
  _AI_COMPLETE_SUGGESTION_WARN=0
}

_ai_complete_show_ghost() {
  local suggestion="$1"
  local warn="${2:-0}"

  _AI_COMPLETE_SUGGESTION="$suggestion"
  _AI_COMPLETE_SUGGESTION_WARN=$warn
  _AI_COMPLETE_PENDING=1

  # Free text stays hidden in undo buffer; line shows ghost only
  BUFFER=
  CURSOR=0
  if (( warn )); then
    # Prefix is display-only; accept still uses _AI_COMPLETE_SUGGESTION
    POSTDISPLAY="${AI_COMPLETE_GHOST_WARN_PREFIX}${_AI_COMPLETE_SUGGESTION}"
  else
    POSTDISPLAY="$_AI_COMPLETE_SUGGESTION"
  fi

  local style="$AI_COMPLETE_GHOST_STYLE"
  (( warn )) && style="$AI_COMPLETE_GHOST_WARN_STYLE"
  _ai_complete_highlight_range $#BUFFER $(($#BUFFER + $#POSTDISPLAY)) "$style"
}

ai-complete-accept-widget() {
  if (( ! _AI_COMPLETE_PENDING )); then
    return 0
  fi
  local suggestion="$_AI_COMPLETE_SUGGESTION"
  local warn=$_AI_COMPLETE_SUGGESTION_WARN
  _ai_complete_clear_ghost
  BUFFER="$suggestion"
  CURSOR=${#BUFFER}
  # Keep undo so Ctrl+X u restores the original free text
  _AI_COMPLETE_CAN_UNDO=1
  _ai_complete_syntax_highlight
  if (( warn )); then
    # Re-apply after syntax HL (it rebuilds region_highlight)
    _ai_complete_highlight_range 0 $#BUFFER "$AI_COMPLETE_GHOST_WARN_STYLE"
    zle -M "⚠ WARNING accepted — Enter RUNs it (Ctrl+X u = undo)"
  else
    zle -M "ai-complete: accepted (Ctrl+X u = free text, Enter = run)"
  fi
  zle -R
}

ai-complete-discard-widget() {
  if (( _AI_COMPLETE_PENDING )); then
    local prior="$_AI_COMPLETE_UNDO_BUFFER"
    local prior_c=$_AI_COMPLETE_UNDO_CURSOR
    _ai_complete_clear_ghost
    BUFFER="$prior"
    CURSOR=$prior_c
    _AI_COMPLETE_CAN_UNDO=0
    _ai_complete_syntax_highlight
    zle -M "ai-complete: discarded"
    zle -R
    return 0
  fi
  if (( _AI_COMPLETE_CAN_UNDO )); then
    _ai_complete_highlight_reset
    BUFFER="$_AI_COMPLETE_UNDO_BUFFER"
    CURSOR=$_AI_COMPLETE_UNDO_CURSOR
    _AI_COMPLETE_CAN_UNDO=0
    _ai_complete_syntax_highlight
    zle -M "ai-complete: restored"
    zle -R
    return 0
  fi
  zle undo
}

ai-complete-widget() {
  # Second trigger while ghost is showing → accept
  if (( _AI_COMPLETE_PENDING )); then
    ai-complete-accept-widget
    return 0
  fi

  # Capture intent immediately (ignore later BUFFER/POSTDISPLAY changes)
  local intent="$BUFFER"
  local last_status="${AI_COMPLETE_SAVED_STATUS:-0}"
  local last_cmd="${AI_COMPLETE_SAVED_CMD:-}"
  # Drop foreign ghost text (e.g. zsh-autosuggestions) so it cannot leak into history
  POSTDISPLAY=

  if [[ "$AI_COMPLETE_ENABLED" != "1" ]]; then
    zle -M "ai-complete: disabled (ai-enable to turn on)"
    return 0
  fi

  if [[ -z "$intent" ]]; then
    zle -M "ai-complete: empty buffer"
    return 0
  fi

  if [[ -z "${AI_COMPLETE_MODEL:-}" ]]; then
    zle -M "ai-complete: set AI_COMPLETE_MODEL first"
    return 0
  fi

  if [[ ! -x "$AI_COMPLETE_BIN" ]]; then
    zle -M "ai-complete: missing executable $AI_COMPLETE_BIN"
    return 0
  fi

  zle -M "ai-complete: thinking…"
  zle -R

  local result
  local tmp_err
  tmp_err="$(mktemp)"

  result="$(
    AI_COMPLETE_MODEL="$AI_COMPLETE_MODEL" \
    AI_COMPLETE_ENDPOINT="$AI_COMPLETE_ENDPOINT" \
    AI_COMPLETE_API_KEY="${AI_COMPLETE_API_KEY:-}" \
    AI_COMPLETE_TIMEOUT="$AI_COMPLETE_TIMEOUT" \
    AI_COMPLETE_HISTORY="$AI_COMPLETE_HISTORY" \
    AI_COMPLETE_LAST_STATUS="$last_status" \
    AI_COMPLETE_LAST_CMD="$last_cmd" \
    HISTFILE="${HISTFILE:-$HOME/.zsh_history}" \
    "$AI_COMPLETE_BIN" -- "$intent" 2>"$tmp_err"
  )"
  local rc=$?

  if [[ $rc -ne 0 && $rc -ne 2 ]]; then
    local err
    err="$(head -n 3 "$tmp_err" 2>/dev/null | tr '\n' ' ')"
    rm -f "$tmp_err"
    zle -M "ai-complete: failed${err:+ — $err}"
    return 0
  fi

  if [[ -z "$result" ]]; then
    rm -f "$tmp_err"
    zle -M "ai-complete: empty response"
    return 0
  fi

  typeset -g _AI_COMPLETE_UNDO_BUFFER="$intent"
  typeset -g _AI_COMPLETE_UNDO_CURSOR=$CURSOR
  typeset -g _AI_COMPLETE_CAN_UNDO=1

  _ai_complete_save_prompt "$intent"

  zle split-undo 2>/dev/null || true

  local warn=0
  local warn_msg=""
  if [[ $rc -eq 2 ]]; then
    warn=1
    warn_msg="$(grep -E 'warning:' "$tmp_err" 2>/dev/null | head -n 1)"
    warn_msg="${warn_msg#ai-complete: }"
  fi
  rm -f "$tmp_err"

  if [[ "$AI_COMPLETE_MODE" == "replace" ]]; then
    BUFFER="$result"
    CURSOR=${#BUFFER}
    _ai_complete_syntax_highlight
    if (( warn )); then
      _ai_complete_highlight_range 0 $#BUFFER "$AI_COMPLETE_GHOST_WARN_STYLE"
      zle -M "⚠ ${warn_msg:-destructive pattern} — Ctrl+X u to undo"
    else
      zle -M "ai-complete: ok (Ctrl+X u to undo)"
    fi
  else
    _ai_complete_show_ghost "$result" "$warn"
    if (( warn )); then
      zle -M "⚠ ${warn_msg:-destructive} — Tab/→/Enter accept, Esc discard"
    else
      zle -M "ai-complete: ghost — Tab/→/Enter accept, Esc discard"
    fi
  fi

  zle -R
}

# Enter: accept ghost into BUFFER (do not execute). Otherwise normal accept-line.
ai-complete-accept-line() {
  if (( _AI_COMPLETE_PENDING )); then
    ai-complete-accept-widget
    return 0
  fi
  zle .accept-line
}

# Tab: accept ghost, else normal completion
ai-complete-expand-or-complete() {
  if (( _AI_COMPLETE_PENDING )); then
    ai-complete-accept-widget
    return 0
  fi
  zle .expand-or-complete
}

# → : accept ghost when pending, else move forward
ai-complete-forward-char() {
  if (( _AI_COMPLETE_PENDING )); then
    ai-complete-accept-widget
    return 0
  fi
  zle .forward-char
}

# Typing discards ghost and restores free text, then inserts the character
ai-complete-self-insert() {
  if (( _AI_COMPLETE_PENDING )); then
    local prior="$_AI_COMPLETE_UNDO_BUFFER"
    local prior_c=$_AI_COMPLETE_UNDO_CURSOR
    _ai_complete_clear_ghost
    BUFFER="$prior"
    CURSOR=$prior_c
    _AI_COMPLETE_CAN_UNDO=0
  fi
  zle .self-insert
}

# Backspace discards ghost
ai-complete-backward-delete-char() {
  if (( _AI_COMPLETE_PENDING )); then
    ai-complete-discard-widget
    return 0
  fi
  zle .backward-delete-char
}

# Ctrl+G: discard ghost, else default break
ai-complete-send-break() {
  if (( _AI_COMPLETE_PENDING )); then
    ai-complete-discard-widget
    return 0
  fi
  zle .send-break
}

zle -N ai-complete-widget
zle -N ai-complete-accept-widget
zle -N ai-complete-discard-widget
zle -N ai-complete-undo-widget ai-complete-discard-widget
zle -N accept-line ai-complete-accept-line
zle -N expand-or-complete ai-complete-expand-or-complete
zle -N forward-char ai-complete-forward-char
zle -N self-insert ai-complete-self-insert
zle -N backward-delete-char ai-complete-backward-delete-char
zle -N send-break ai-complete-send-break

# Primary: Ctrl+X Ctrl+X
bindkey '^X^X' ai-complete-widget
# Discard / restore (Ctrl+X u or Ctrl+G)
bindkey '^Xu' ai-complete-discard-widget
bindkey '^X^U' ai-complete-discard-widget
bindkey '^G' ai-complete-send-break
# Arrow right (common sequences)
bindkey '^[[C' ai-complete-forward-char
bindkey '^[OC' ai-complete-forward-char
# Optional: ⌥+Enter
bindkey '\e\r' ai-complete-widget
bindkey '^[^M' ai-complete-widget
