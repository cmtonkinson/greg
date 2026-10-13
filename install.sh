#!/bin/sh
#
# Installs greg, or updates an existing install: clones it into $GREG_SRC or
# fast-forwards the clone already there, then links greg into ~/.local/bin.
# Safe to run again. `greg update` runs this against its own clone.
#
#   curl -fsSL https://raw.githubusercontent.com/cmtonkinson/greg/main/install.sh | sh
set -eu

REPO=${GREG_REPO:-https://github.com/cmtonkinson/greg.git}
SRC=${GREG_SRC:-$HOME/.local/share/greg/src}
BIN_DIR=$HOME/.local/bin

fail() {
  echo "greg install: $*" >&2
  exit 1
}

missing=
for cmd in bash git jq perl gh claude terminal-notifier; do
  command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
done
[ -z "$missing" ] || fail "missing:$missing"
bash -c '((BASH_VERSINFO[0] >= 5))' || fail "the bash on PATH must be version 5 or later (brew install bash)"

if [ -d "$SRC/.git" ]; then
  git -C "$SRC" pull --ff-only --quiet || fail "could not fast-forward $SRC; fix it by hand"
elif [ -e "$SRC" ]; then
  fail "$SRC exists but is not a git clone"
else
  mkdir -p "$(dirname "$SRC")"
  git clone --quiet "$REPO" "$SRC"
fi

mkdir -p "$BIN_DIR"
ln -sfn "$SRC/bin/greg" "$BIN_DIR/greg"

echo "greg $(git -C "$SRC" rev-parse --short HEAD) installed at $SRC"
if [ ! -f "$SRC/config" ]; then
  echo "Reviews use /code-review. To use another skill: echo REVIEW_SKILL=<name> >$SRC/config"
fi
case ":$PATH:" in
*":$BIN_DIR:"*) ;;
*) echo "Add $BIN_DIR to your PATH." ;;
esac
if ! launchctl print "gui/$(id -u)/com.tonkinson.greg" >/dev/null 2>&1; then
  echo "Run 'greg install' to start the schedule, or 'greg now' for a single run."
elif grep -qF "<string>$SRC/bin/greg</string>" "$HOME/Library/LaunchAgents/com.tonkinson.greg.plist" 2>/dev/null; then
  echo "The schedule runs the new version at its next tick."
else
  echo "The schedule runs another copy of greg; run 'greg install' to switch it to this one."
fi
