#!/usr/bin/env bash
# Destructive-command pattern check. Source from bin/ai-complete / tests.
#
# ai_complete_safety_check <command>
#   stdout: matched pattern description (if any)
#   exit 0: clean
#   exit 2: warning (destructive pattern matched)

ai_complete_safety_check() {
  local cmd="${1:-}"

  # bash [[ =~ ]] uses ERE (no \b). Keep patterns simple and explicit.
  if [[ "$cmd" =~ rm[[:space:]]+(-[a-zA-Z]*r[a-zA-Z]*f[a-zA-Z]*|-[a-zA-Z]*f[a-zA-Z]*r[a-zA-Z]*|-rf|-fr)[[:space:]]+(/|~(/|$)|\$HOME|\$\{HOME\}) ]]; then
    echo "rm -rf on / or home"
    return 2
  fi

  if [[ "$cmd" =~ (^|[[:space:]])dd[[:space:]] ]] && [[ "$cmd" =~ if= ]]; then
    echo "dd if="
    return 2
  fi

  if [[ "$cmd" =~ (^|[[:space:];|&])mkfs([.]|[[:space:]]) ]]; then
    echo "mkfs"
    return 2
  fi

  if [[ "$cmd" =~ git[[:space:]]+push[[:space:]] ]] && [[ "$cmd" =~ (--force|[[:space:]]-f([[:space:]]|$)) ]] && [[ "$cmd" =~ (main|master) ]]; then
    echo "git push --force to main/master"
    return 2
  fi

  if [[ "$cmd" =~ chmod[[:space:]]+(-R[[:space:]]+)?777([[:space:]]|$) ]]; then
    echo "chmod 777"
    return 2
  fi

  # Fork bomb: :(){ :|:& };:  — avoid bare & inside [[ =~ ]] (breaks parse)
  if [[ "$cmd" == *':()'* && "$cmd" == *':|:'* && "$cmd" == *'};:'* ]]; then
    echo "fork bomb"
    return 2
  fi
  if [[ "$cmd" == *':(){'* && "$cmd" == *'|:&'* ]]; then
    echo "fork bomb"
    return 2
  fi

  if [[ "$cmd" =~ \>[[:space:]]*/dev/sd ]]; then
    echo "redirect to /dev/sd*"
    return 2
  fi

  if [[ "$cmd" =~ diskutil[[:space:]]+erase ]]; then
    echo "diskutil erase"
    return 2
  fi

  return 0
}
