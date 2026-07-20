#!/usr/bin/env sh
# Installer for claude-code-identity (macOS / Linux).
# Copies cc.sh into place and sources it from your shell rc. Idempotent.
set -e

SRC="$(cd "$(dirname "$0")" && pwd)/cc.sh"
DEST_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/cc"
DEST="$DEST_DIR/cc.sh"
LINE=". \"$DEST\""

[ -f "$SRC" ] || { echo "install: cannot find cc.sh next to this script" >&2; exit 1; }

mkdir -p "$DEST_DIR"
cp "$SRC" "$DEST"
chmod +x "$DEST"
echo "installed: $DEST"

# Pick the rc file for the user's login shell.
case "${SHELL##*/}" in
    zsh)  RC="$HOME/.zshrc" ;;
    bash) if [ -f "$HOME/.bashrc" ]; then RC="$HOME/.bashrc"; else RC="$HOME/.bash_profile"; fi ;;
    *)    RC="$HOME/.profile" ;;
esac

if [ -f "$RC" ] && grep -Fq "$DEST" "$RC" 2>/dev/null; then
    echo "already sourced from: $RC"
else
    printf '\n# claude-code-identity\n%s\n' "$LINE" >> "$RC"
    echo "added source line to: $RC"
fi

cat <<EOF

Done. Restart your shell (or run: $LINE)

Next:
  ccnew personal "\$HOME/.claude"   # your existing account becomes the shared store
  ccnew work                       # a second identity
  cc work                          # launch and log in
EOF
