# zsh-ai-complete — ZLE widget + helpers
# Source from ~/.zshrc or via install.sh

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
typeset -g _AI_COMPLETE_UNDO_BUFFER=
typeset -g _AI_COMPLETE_UNDO_CURSOR=0
typeset -g _AI_COMPLETE_CAN_UNDO=0
typeset -g AI_COMPLETE_SAVED_STATUS=0
typeset -g AI_COMPLETE_SAVED_CMD=

# Load user config if present
if [[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/zsh-ai-complete/config.env" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${XDG_CONFIG_HOME:-$HOME/.config}/zsh-ai-complete/config.env"
  set +a
fi

# Capture $? + last command after each prompt command (widget-local $? is unreliable)
_ai_complete_precmd() {
  AI_COMPLETE_SAVED_STATUS=$?
  AI_COMPLETE_SAVED_CMD="${$(fc -ln -1 2>/dev/null)##[[:space:]]#}"
}
# Prepend so we see the real exit status before other precmd hooks run
precmd_functions=(${precmd_functions:#_ai_complete_precmd})
precmd_functions=(_ai_complete_precmd ${precmd_functions[@]})

ai-enable() {
  typeset -g AI_COMPLETE_ENABLED=1
  print -u2 "ai-complete: enabled"
}

ai-disable() {
  typeset -g AI_COMPLETE_ENABLED=0
  print -u2 "ai-complete: disabled"
}

ai-status() {
  local model="${AI_COMPLETE_MODEL:-<unset>}"
  local key="<unset>"
  [[ -n "${AI_COMPLETE_API_KEY:-}" ]] && key="(set)"
  local enabled="off"
  [[ "$AI_COMPLETE_ENABLED" == "1" ]] && enabled="on"
  print "ai-complete: $enabled"
  print "  endpoint: $AI_COMPLETE_ENDPOINT"
  print "  model:    $model"
  print "  api key:  $key"
  print "  bin:      $AI_COMPLETE_BIN"
}

ai-complete-widget() {
  local last_status="${AI_COMPLETE_SAVED_STATUS:-0}"
  local last_cmd="${AI_COMPLETE_SAVED_CMD:-}"

  if [[ "$AI_COMPLETE_ENABLED" != "1" ]]; then
    zle -M "ai-complete: disabled (ai-enable to turn on)"
    return 0
  fi

  if [[ -z "$BUFFER" ]]; then
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
    "$AI_COMPLETE_BIN" -- "$BUFFER" 2>"$tmp_err"
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

  # Save free-text for explicit restore (Ctrl+_ is awkward on DE keyboards)
  typeset -g _AI_COMPLETE_UNDO_BUFFER="$BUFFER"
  typeset -g _AI_COMPLETE_UNDO_CURSOR=$CURSOR
  typeset -g _AI_COMPLETE_CAN_UNDO=1

  # Also push a ZLE undo point when supported
  zle split-undo 2>/dev/null || true

  BUFFER="$result"
  CURSOR=${#BUFFER}

  if [[ $rc -eq 2 ]]; then
    local warn_msg
    warn_msg="$(grep -E 'warning:' "$tmp_err" 2>/dev/null | head -n 1)"
    warn_msg="${warn_msg#ai-complete: }"
    zle -M "⚠ ${warn_msg:-destructive pattern} — Ctrl+X u to undo"
  else
    zle -M "ai-complete: ok (Ctrl+X u to undo)"
  fi

  rm -f "$tmp_err"
  zle -R
}

# Restore text from last AI completion; otherwise normal undo.
# Prefer Ctrl+X u — works on DE layouts; Ctrl+_ often does not.
ai-complete-undo-widget() {
  if (( _AI_COMPLETE_CAN_UNDO )); then
    BUFFER="$_AI_COMPLETE_UNDO_BUFFER"
    CURSOR=$_AI_COMPLETE_UNDO_CURSOR
    _AI_COMPLETE_CAN_UNDO=0
    zle -M "ai-complete: restored"
    zle -R
    return 0
  fi
  zle undo
}

zle -N ai-complete-widget
zle -N ai-complete-undo-widget
# Primary: Ctrl+X Ctrl+X — works without terminal config (Cursor, iTerm, …)
bindkey '^X^X' ai-complete-widget
# Undo last AI replace (overrides default ^Xu undo — still falls through to undo)
bindkey '^Xu' ai-complete-undo-widget
bindkey '^X^U' ai-complete-undo-widget
# Optional: ⌥+Enter when Option sends Esc+ (iTerm Left Option=Esc+ / Cursor macOptionIsMeta)
bindkey '\e\r' ai-complete-widget
bindkey '^[^M' ai-complete-widget
