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
# ASCII prefix/suffix and terminal bell are the portable “look at me” signals.
typeset -g AI_COMPLETE_GHOST_WARN_STYLE=”${AI_COMPLETE_GHOST_WARN_STYLE:-standout,bold}”
typeset -g AI_COMPLETE_GHOST_WARN_PREFIX=”${AI_COMPLETE_GHOST_WARN_PREFIX:-!!! }”
typeset -g AI_COMPLETE_GHOST_WARN_SUFFIX=”${AI_COMPLETE_GHOST_WARN_SUFFIX:- !!!}”
# Save free-text intents to zsh history as "# …" (noop if re-run with interactivecomments)
typeset -g AI_COMPLETE_SAVE_PROMPTS="${AI_COMPLETE_SAVE_PROMPTS:-1}"

typeset -g _AI_COMPLETE_UNDO_BUFFER=
typeset -g _AI_COMPLETE_UNDO_CURSOR=0
typeset -g _AI_COMPLETE_CAN_UNDO=0
typeset -g AI_COMPLETE_SAVED_STATUS=0
typeset -g AI_COMPLETE_SAVED_CMD=

typeset -g AI_COMPLETE_CAPTURE_OUTPUT="${AI_COMPLETE_CAPTURE_OUTPUT:-1}"
typeset -g AI_COMPLETE_CMD_HISTORY="${AI_COMPLETE_CMD_HISTORY:-3}"
typeset -g AI_COMPLETE_TOTAL_OUTPUT_LINES="${AI_COMPLETE_TOTAL_OUTPUT_LINES:-200}"
typeset -g AI_COMPLETE_DEBUG="${AI_COMPLETE_DEBUG:-}"
typeset -g AI_COMPLETE_LAST_OUTPUT=
typeset -g _AI_COMPLETE_OUTPUT_TMP=
typeset -g _AI_COMPLETE_SAVED_OUT=
typeset -g _AI_COMPLETE_SAVED_ERR=
typeset -ga _AI_COMPLETE_BUF_CMD=()
typeset -ga _AI_COMPLETE_BUF_EXIT=()
typeset -ga _AI_COMPLETE_BUF_OUT=()

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
  # Revoke the export flag from credential variables — set -a would otherwise
  # leave them exported into every child process for the session lifetime.
  typeset +x AI_COMPLETE_API_KEY 2>/dev/null || true
fi

# So "# …" history entries are harmless if executed
setopt interactivecomments

# Capture $? + last command after each prompt command (widget-local $? is unreliable)
_ai_complete_precmd() {
  AI_COMPLETE_SAVED_STATUS=$?
  AI_COMPLETE_SAVED_CMD="${$(fc -ln -1 2>/dev/null)##[[:space:]]#}"
  # Restore stdout/stderr redirected by _ai_complete_preexec_capture.
  # Closing the old write-end of the tee pipe here signals EOF to tee;
  # by the time the user types and triggers the widget, tee has finished.
  if [[ -n "${_AI_COMPLETE_SAVED_OUT:-}" ]]; then
    exec 1>&"${_AI_COMPLETE_SAVED_OUT}" 2>&"${_AI_COMPLETE_SAVED_ERR}"
    exec {_AI_COMPLETE_SAVED_OUT}>&- {_AI_COMPLETE_SAVED_ERR}>&-
    _AI_COMPLETE_SAVED_OUT=
    _AI_COMPLETE_SAVED_ERR=
  fi
  # Fresh prompt: drop any leftover ghost
  _ai_complete_clear_ghost
}
precmd_functions=(${precmd_functions:#_ai_complete_precmd})
precmd_functions=(_ai_complete_precmd ${precmd_functions[@]})

# Tee stdout+stderr through a temp file so the widget can include last output.
# preexec runs after ZLE, before the command — safe to redirect here.
# Also commits the previous command's output to the rolling buffer; by the time
# preexec fires for the next command, the previous tee is definitely done.
_ai_complete_preexec_capture() {
  [[ "${AI_COMPLETE_CAPTURE_OUTPUT:-1}" == "1" ]] || return 0
  # Previous command's temp file is safe to read now (tee exited after precmd closed the pipe)
  if [[ -n "${_AI_COMPLETE_OUTPUT_TMP:-}" && -f "$_AI_COMPLETE_OUTPUT_TMP" ]]; then
    local _prev_out
    _prev_out="$(cat "$_AI_COMPLETE_OUTPUT_TMP" 2>/dev/null \
      | sed $'s/\033\\[[0-9;]*[A-Za-z]//g' | tr -d '\r')"
    _ai_complete_buffer_push "$AI_COMPLETE_SAVED_CMD" "$AI_COMPLETE_SAVED_STATUS" "$_prev_out"
    rm -f "$_AI_COMPLETE_OUTPUT_TMP"
    _AI_COMPLETE_OUTPUT_TMP=
  fi
  local tmp
  tmp="$(mktemp 2>/dev/null)" || return 0
  _AI_COMPLETE_OUTPUT_TMP="$tmp"
  exec {_AI_COMPLETE_SAVED_OUT}>&1 {_AI_COMPLETE_SAVED_ERR}>&2
  exec 1> >(tee -a "$_AI_COMPLETE_OUTPUT_TMP" >&"${_AI_COMPLETE_SAVED_OUT}") 2>&1
}
preexec_functions=(${preexec_functions:#_ai_complete_preexec_capture})
preexec_functions=(_ai_complete_preexec_capture ${preexec_functions[@]})

# Push one entry onto the front of the rolling buffer; trim to AI_COMPLETE_CMD_HISTORY depth.
_ai_complete_buffer_push() {
  local cmd="$1" exit_code="$2" output="$3"
  local max="${AI_COMPLETE_CMD_HISTORY:-3}"
  _AI_COMPLETE_BUF_CMD=("$cmd" "${_AI_COMPLETE_BUF_CMD[@]}")
  _AI_COMPLETE_BUF_EXIT=("$exit_code" "${_AI_COMPLETE_BUF_EXIT[@]}")
  _AI_COMPLETE_BUF_OUT=("$output" "${_AI_COMPLETE_BUF_OUT[@]}")
  (( ${#_AI_COMPLETE_BUF_CMD[@]} > max )) && {
    _AI_COMPLETE_BUF_CMD=("${_AI_COMPLETE_BUF_CMD[@]:0:$max}")
    _AI_COMPLETE_BUF_EXIT=("${_AI_COMPLETE_BUF_EXIT[@]:0:$max}")
    _AI_COMPLETE_BUF_OUT=("${_AI_COMPLETE_BUF_OUT[@]:0:$max}")
  }
}

# Read the current command's captured output (lazy — tee is done by the time the
# user types an intent and hits the keybinding). Leaves AI_COMPLETE_LAST_OUTPUT
# unchanged if there is no new capture file (re-triggering the widget reuses it).
_ai_complete_read_last_output() {
  [[ -n "${_AI_COMPLETE_OUTPUT_TMP:-}" && -f "$_AI_COMPLETE_OUTPUT_TMP" ]] || return 0
  AI_COMPLETE_LAST_OUTPUT="$(cat "$_AI_COMPLETE_OUTPUT_TMP" 2>/dev/null \
    | sed $'s/\033\\[[0-9;]*[A-Za-z]//g' | tr -d '\r')"
  rm -f "$_AI_COMPLETE_OUTPUT_TMP"
  _AI_COMPLETE_OUTPUT_TMP=
}

# Build the session-history string passed to the LLM.
# Line budget is shared across all positions using triangular weighting:
# position 1 = current command (most lines), position N+1 = oldest buffered (fewest).
_ai_complete_format_session_context() {
  local total="${AI_COMPLETE_TOTAL_OUTPUT_LINES:-200}"
  local buf_n=${#_AI_COMPLETE_BUF_CMD[@]}
  local total_pos=$(( buf_n + 1 ))
  local tri_sum=$(( total_pos * (total_pos + 1) / 2 ))

  local -a entries=()
  local i weight lines out_trunc

  # Buffer entries oldest-first so the LLM reads them chronologically
  for (( i = buf_n; i >= 1; i-- )); do
    weight=$(( total_pos - i ))
    lines=$(( total * weight / tri_sum ))
    out_trunc="$(printf '%s' "${_AI_COMPLETE_BUF_OUT[$i]}" | tail -n "$lines" 2>/dev/null)"
    entries+=("command: ${_AI_COMPLETE_BUF_CMD[$i]:-?}
exit: ${_AI_COMPLETE_BUF_EXIT[$i]:-?}
output:
${out_trunc:-(none)}")
  done

  # Current command last — highest weight, most lines
  weight=$total_pos
  lines=$(( total * weight / tri_sum ))
  out_trunc="$(printf '%s' "${AI_COMPLETE_LAST_OUTPUT:-}" | tail -n "$lines" 2>/dev/null)"
  entries+=("command: ${AI_COMPLETE_SAVED_CMD:-?}
exit: ${AI_COMPLETE_SAVED_STATUS:-?}
output:
${out_trunc:-(none)}")

  local total_entries=${#entries[@]}
  local result="" j
  for (( j = 1; j <= total_entries; j++ )); do
    [[ -n "$result" ]] && result+=$'\n'
    result+="[$j/$total_entries] ${entries[$j]}"
  done
  printf '%s' "$result"
}

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
  local capture="off"
  [[ "${AI_COMPLETE_CAPTURE_OUTPUT:-1}" == "1" ]] && capture="on (${AI_COMPLETE_CMD_HISTORY:-3} cmds, ${AI_COMPLETE_TOTAL_OUTPUT_LINES:-200} lines total, triangular)"
  local debug="off"
  [[ "${AI_COMPLETE_DEBUG:-}" == "1" ]] && debug="on → ${TMPDIR%/}/ai-complete-debug.json"
  print "ai-complete: $enabled"
  print "  mode:     $AI_COMPLETE_MODE"
  print "  prompts:  ${AI_COMPLETE_SAVE_PROMPTS} (# … → history)"
  print "  capture:  $capture"
  print "  debug:    $debug"
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
    # Prefix/suffix are display-only; accept still uses _AI_COMPLETE_SUGGESTION
    POSTDISPLAY="${AI_COMPLETE_GHOST_WARN_PREFIX}${_AI_COMPLETE_SUGGESTION}${AI_COMPLETE_GHOST_WARN_SUFFIX}"
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
    print -n $'\a'
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
  _ai_complete_read_last_output
  local session_context
  session_context="$(_ai_complete_format_session_context)"

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

  # Drop foreign ghost text (e.g. zsh-autosuggestions) only once we're committed
  # to running — avoids clearing autosuggestions on no-op early returns above.
  POSTDISPLAY=

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
    AI_COMPLETE_SESSION_CONTEXT="$session_context" \
    AI_COMPLETE_DEBUG="${AI_COMPLETE_DEBUG:-}" \
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
      print -n $'\a'
      _ai_complete_highlight_range 0 $#BUFFER "$AI_COMPLETE_GHOST_WARN_STYLE"
      zle -M "⚠ ${warn_msg:-destructive pattern} — Ctrl+X u to undo"
    else
      zle -M "ai-complete: ok (Ctrl+X u to undo)"
    fi
  else
    _ai_complete_show_ghost "$result" "$warn"
    if (( warn )); then
      print -n $'\a'
      zle -M "⚠ ${warn_msg:-destructive} — Tab/→/Enter accept, Esc discard"
    else
      zle -M "ai-complete: ghost — Tab/→/Enter accept, Esc discard"
    fi
  fi

  if [[ "${AI_COMPLETE_DEBUG:-}" == "1" ]]; then
    zle -M "ai-complete: debug → ${TMPDIR%/}/ai-complete-debug.json"
  fi
  zle -R
}

# Enter: accept ghost into BUFFER (do not execute). Otherwise normal accept-line.
ai-complete-accept-line() {
  if (( _AI_COMPLETE_PENDING )); then
    ai-complete-accept-widget
    return 0
  fi
  _ai_complete_call_orig accept-line
}

# Tab: accept ghost, else whatever completion was bound before (fzf-tab, menu, …)
ai-complete-expand-or-complete() {
  if (( _AI_COMPLETE_PENDING )); then
    ai-complete-accept-widget
    return 0
  fi
  _ai_complete_call_orig expand-or-complete
}

# → : accept ghost when pending, else move forward
ai-complete-forward-char() {
  if (( _AI_COMPLETE_PENDING )); then
    ai-complete-accept-widget
    return 0
  fi
  _ai_complete_call_orig forward-char
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
  _ai_complete_call_orig self-insert
}

# Backspace discards ghost
ai-complete-backward-delete-char() {
  if (( _AI_COMPLETE_PENDING )); then
    ai-complete-discard-widget
    return 0
  fi
  _ai_complete_call_orig backward-delete-char
}

# Ctrl+G: discard ghost, else default break
ai-complete-send-break() {
  if (( _AI_COMPLETE_PENDING )); then
    ai-complete-discard-widget
    return 0
  fi
  _ai_complete_call_orig send-break
}

# Preserve the previous user/builtin widget so we don't clobber fzf-tab etc.
# Other plugins often call `zle backward-delete-char` by name; without a
# reentrancy guard that re-enters our wrapper and blows FUNCNEST.
typeset -g _AI_COMPLETE_IN_ORIG=0

_ai_complete_call_orig() {
  local w="$1"
  shift
  local saved="_ai_complete_orig_${w}"

  if (( _AI_COMPLETE_IN_ORIG )); then
    zle ".$w" "$@"
    return
  fi

  if (( ${+widgets[$saved]} )) && [[ ${widgets[$saved]} != user:ai-complete-* ]]; then
    _AI_COMPLETE_IN_ORIG=1
    {
      zle "$saved" "$@"
    } always {
      _AI_COMPLETE_IN_ORIG=0
    }
  else
    zle ".$w" "$@"
  fi
}

_ai_complete_wrap() {
  local w="$1" wrapper="$2"
  local saved="_ai_complete_orig_${w}"

  # Repair self-alias from an earlier reload (orig → our wrapper → FUNCNEST)
  if [[ ${widgets[$saved]:-} == user:ai-complete-* ]]; then
    zle -D "$saved" 2>/dev/null || true
  fi

  if [[ ${widgets[$w]:-} == "user:$wrapper" ]]; then
    zle -N "$w" "$wrapper"
    return 0
  fi

  # Capture the previous implementation only once per shell
  if (( ! ${+widgets[$saved]} )) && [[ -n ${widgets[$w]:-} ]]; then
    zle -A "$w" "$saved"
    if [[ ${widgets[$saved]:-} == user:ai-complete-* ]]; then
      zle -D "$saved" 2>/dev/null || true
    fi
  fi

  zle -N "$w" "$wrapper"
}

zle -N ai-complete-widget
zle -N ai-complete-accept-widget
zle -N ai-complete-discard-widget
zle -N ai-complete-undo-widget ai-complete-discard-widget

# Register wrapper functions under their own widget names too. Leftover
# bindkeys (or other plugins) may still call `ai-complete-forward-char` etc.
zle -N ai-complete-accept-line
zle -N ai-complete-expand-or-complete
zle -N ai-complete-forward-char
zle -N ai-complete-self-insert
zle -N ai-complete-backward-delete-char
zle -N ai-complete-send-break

_ai_complete_wrap accept-line ai-complete-accept-line
_ai_complete_wrap expand-or-complete ai-complete-expand-or-complete
_ai_complete_wrap forward-char ai-complete-forward-char
_ai_complete_wrap self-insert ai-complete-self-insert
_ai_complete_wrap backward-delete-char ai-complete-backward-delete-char
_ai_complete_wrap send-break ai-complete-send-break

# Primary: Ctrl+X Ctrl+X
bindkey '^X^X' ai-complete-widget
# Discard / restore (Ctrl+X u or Ctrl+G)
bindkey '^Xu' ai-complete-discard-widget
bindkey '^X^U' ai-complete-discard-widget
bindkey '^G' send-break
# Arrow right — bind both common sequences to the wrapped forward-char
bindkey '^[[C' forward-char
bindkey '^[OC' forward-char
# Optional: ⌥+Enter
bindkey '\e\r' ai-complete-widget
bindkey '^[^M' ai-complete-widget
