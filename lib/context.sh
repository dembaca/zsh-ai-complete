#!/usr/bin/env bash
# Collect shell context for the LLM prompt. Source from bin/ai-complete.

ai_complete_collect_context() {
  local history_n="${AI_COMPLETE_HISTORY:-8}"
  local max_git_status=40
  local max_ls=40
  local max_diff_lines=30
  local cwd os_info last_status last_cmd
  local git_status git_branch git_log git_diff
  local history_lines dir_listing
  local in_git=0

  cwd="${PWD:-$(pwd)}"

  os_info="$(uname -srm 2>/dev/null || echo unknown)"
  os_info+=" shell=${SHELL:-unknown}"

  # Passed from the zsh widget when available; else unknown
  last_status="${AI_COMPLETE_LAST_STATUS:-unknown}"

  last_cmd="${AI_COMPLETE_LAST_CMD:-}"
  if [[ -z "$last_cmd" && -n "${HISTFILE:-}" && -r "$HISTFILE" ]]; then
    last_cmd="$(tail -n 1 "$HISTFILE" 2>/dev/null \
      | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//; s/^: [0-9]*:[0-9]*;//')"
  fi
  [[ -z "$last_cmd" ]] && last_cmd="(none)"

  git_status="(not a git repo)"
  git_branch="(n/a)"
  git_log="(n/a)"
  git_diff="(n/a)"

  if git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    in_git=1
    git_branch="$(git -C "$cwd" branch --show-current 2>/dev/null || true)"
    [[ -z "$git_branch" ]] && git_branch="$(git -C "$cwd" rev-parse --short HEAD 2>/dev/null || echo detached)"

    git_status="$(git -C "$cwd" status --short 2>/dev/null | head -n "$max_git_status")"
    [[ -z "$git_status" ]] && git_status="(clean)"

    git_log="$(git -C "$cwd" log -3 --oneline 2>/dev/null || true)"
    [[ -z "$git_log" ]] && git_log="(empty)"

    git_diff="$(git -C "$cwd" diff --stat HEAD 2>/dev/null | head -n "$max_diff_lines")"
    [[ -z "$git_diff" ]] && git_diff="(no diff)"
  fi

  history_lines=""
  if [[ -n "${HISTFILE:-}" && -r "$HISTFILE" ]]; then
    history_lines="$(tail -n "$history_n" "$HISTFILE" 2>/dev/null \
      | sed 's/^[[:space:]]*[0-9]*[[:space:]]*//; s/^: [0-9]*:[0-9]*;//')"
  elif fc -ln -"$history_n" >/dev/null 2>&1; then
    history_lines="$(fc -ln -"$history_n" 2>/dev/null)"
  fi
  [[ -z "$history_lines" ]] && history_lines="(none)"

  # Non-hidden entries only; keep it short
  dir_listing="$(ls -1A "$cwd" 2>/dev/null | grep -v '^\.' | head -n "$max_ls")"
  local ls_count
  ls_count="$(ls -1A "$cwd" 2>/dev/null | grep -v '^\.' | wc -l | tr -d ' ')"
  if [[ -z "$dir_listing" ]]; then
    dir_listing="(empty)"
  elif [[ "${ls_count:-0}" -gt "$max_ls" ]]; then
    dir_listing+=$'\n'"… ($((ls_count - max_ls)) more)"
  fi

  cat <<EOF
cwd: $cwd
os: $os_info
last_exit: $last_status
last_command: $last_cmd
git branch: $git_branch
git status:
$git_status
git recent commits:
$git_log
git diff --stat:
$git_diff
directory listing (non-hidden, max $max_ls):
$dir_listing
recent history:
$history_lines
EOF
}
