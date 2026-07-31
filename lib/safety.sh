#!/usr/bin/env bash
# Destructive-command pattern check. Source from bin/ai-complete / tests.
#
# ai_complete_safety_check <command>
#   stdout: matched pattern description (if any)
#   exit 0: clean
#   exit 2: warning (destructive pattern matched)
#
# Patterns: lib/dangerous.patterns (curated; see NOTICE for attribution)

ai_complete_patterns_file() {
  if [[ -n "${AI_COMPLETE_PATTERNS_FILE:-}" ]]; then
    printf '%s\n' "$AI_COMPLETE_PATTERNS_FILE"
    return
  fi
  local root="${AI_COMPLETE_ROOT:-}"
  if [[ -z "$root" ]]; then
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  fi
  printf '%s\n' "$root/lib/dangerous.patterns"
}

ai_complete_safety_check() {
  local cmd="${1:-}"

  # Fork bomb — any function whose body recursively pipes to itself in background.
  # ERE handles canonical :(){ :|:& };: and spaced/named variants like f(){ f|f& };f
  if [[ "$cmd" =~ [[:alnum:]_:]+[[:space:]]*\(\)[[:space:]]*\{[^}]*\|[^}]*\& ]]; then
    echo "fork bomb"
    return 2
  fi

  local patterns
  patterns="$(ai_complete_patterns_file)"
  if [[ ! -r "$patterns" ]]; then
    echo "safety patterns missing: $patterns" >&2
    return 0
  fi

  local label re line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    label="${line%%$'\t'*}"
    re="${line#*$'\t'}"
    [[ -z "$label" || -z "$re" || "$label" == "$line" ]] && continue
    if [[ "$cmd" =~ $re ]]; then
      printf '%s\n' "$label"
      return 2
    fi
  done <"$patterns"

  return 0
}
