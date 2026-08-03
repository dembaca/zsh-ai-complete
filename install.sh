#!/usr/bin/env bash
# Install zsh-ai-complete: config + ~/.zshrc snippet
# (Oh My Zsh users: clone into $ZSH_CUSTOM/plugins/zsh-ai-complete instead — see README.)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/zsh-ai-complete"
ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"
MARKER_BEGIN="# >>> zsh-ai-complete >>>"
MARKER_END="# <<< zsh-ai-complete <<<"

mkdir -p "$CONFIG_DIR"
chmod +x "$ROOT/bin/ai-complete"

if [[ ! -f "$CONFIG_DIR/config.env" ]]; then
  cp "$ROOT/config/default.env" "$CONFIG_DIR/config.env"
  echo "Created $CONFIG_DIR/config.env"
  echo "  → Set AI_COMPLETE_MODEL to a model available in oMLX."
else
  echo "Keeping existing $CONFIG_DIR/config.env"
fi

write_snippet() {
  cat <<EOF
$MARKER_BEGIN
export AI_COMPLETE_ROOT="$ROOT"
[[ -f "\$AI_COMPLETE_ROOT/zsh-ai-complete.plugin.zsh" ]] && source "\$AI_COMPLETE_ROOT/zsh-ai-complete.plugin.zsh"
$MARKER_END
EOF
}

touch "$ZSHRC"

if grep -qF "$MARKER_BEGIN" "$ZSHRC" 2>/dev/null; then
  echo "Updating existing block in $ZSHRC"
  tmp="$(mktemp)"
  awk -v begin="$MARKER_BEGIN" -v end="$MARKER_END" '
    $0 == begin { skip=1; next }
    $0 == end { skip=0; next }
    !skip { print }
  ' "$ZSHRC" >"$tmp"
  # Ensure trailing newline before snippet
  [[ -s "$tmp" && "$(tail -c1 "$tmp" | wc -l)" -eq 0 ]] && echo >>"$tmp"
  write_snippet >>"$tmp"
  mv "$tmp" "$ZSHRC"
else
  {
    echo ""
    write_snippet
  } >>"$ZSHRC"
  echo "Appended plugin block to $ZSHRC"
fi

cat <<EOF

Done.

Next steps:
  1. Edit $CONFIG_DIR/config.env — set AI_COMPLETE_MODEL (and AI_COMPLETE_API_KEY if oMLX auth is on)
  2. Ensure oMLX is serving at http://127.0.0.1:8000/v1
  3. Open a new shell (or: source $ZSHRC)
  4. Type a free-text intent and press Ctrl+X Ctrl+X

Helpers: ai-status | ai-enable | ai-disable
CLI test: AI_COMPLETE_MODEL=... $ROOT/bin/ai-complete "list pdf files here"
EOF
