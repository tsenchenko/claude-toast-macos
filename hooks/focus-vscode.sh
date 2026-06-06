#!/usr/bin/env bash
# Invoked when a Claude Code notification is clicked (terminal-notifier -execute).
#
#   focus-vscode.sh <base64-of-project-cwd>
#
# Focuses the VS Code window that has that project folder open and brings VS Code
# to the foreground. Uses the `code` CLI, which asks VS Code to focus its own
# window — so it needs NO Accessibility permission, and it picks the correct
# window even when several VS Code windows are open.
#
# Note: this script is launched by terminal-notifier (a GUI app), so it runs with
# the minimal launchd PATH (/usr/bin:/bin:/usr/sbin:/sbin). That excludes
# /usr/local/bin and /opt/homebrew/bin, so we locate `code` by absolute path
# instead of trusting PATH.

set -uo pipefail

LOG="${TMPDIR:-/tmp}/claude-banners.log"   # shared with notify.sh; our lines are tagged [focus]
log() { printf '%s [focus] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null || true; }

CWD=""
if [ "${1:-}" != "" ]; then
  CWD="$(printf '%s' "$1" | base64 -d 2>/dev/null || true)"
fi

# Claude Code's cwd is frequently a SUBFOLDER of the project (e.g.
# .../Sell-2-Sam/knowledge). `code <subfolder>` opens a NEW window instead of
# focusing the project window, so climb to the enclosing project root first:
# git top-level, else nearest ancestor with a project marker, else unchanged.
# Idempotent — a path that is already a root resolves to itself. We locate git by
# absolute path because this script runs with the minimal launchd PATH.
resolve_project_root() {
  local d="${1:-}"
  [ -n "$d" ] || { printf '%s' "$d"; return; }
  # Normalise to an absolute path (this also validates the directory exists).
  # Critical: it stops the marker walk below from looping forever on a relative
  # path such as "." — dirname "." is "." and would otherwise never reach "/".
  local abs
  abs="$(cd "$d" 2>/dev/null && pwd)" || abs=""
  [ -n "$abs" ] || { printf '%s' "$d"; return; }
  d="$abs"
  local g git_bin=""
  for g in /usr/bin/git /opt/homebrew/bin/git /usr/local/bin/git; do
    [ -x "$g" ] && { git_bin="$g"; break; }
  done
  if [ -n "$git_bin" ]; then
    local top
    top="$("$git_bin" -C "$d" rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$top" ] && [ -d "$top" ] && { printf '%s' "$top"; return; }
  fi
  local cur="$d"
  while [ -n "$cur" ] && [ "$cur" != "/" ]; do
    if [ -e "$cur/.git" ] || [ -d "$cur/.vscode" ] || [ -e "$cur/CLAUDE.md" ] || [ -e "$cur/package.json" ]; then
      printf '%s' "$cur"; return
    fi
    cur="$(dirname "$cur")"
  done
  printf '%s' "$d"
}
CWD="$(resolve_project_root "$CWD")"

LEAF=""
[ -n "$CWD" ] && LEAF="$(basename "$CWD" 2>/dev/null || true)"
log "invoked cwd='$CWD' leaf='$LEAF'"

# Locate the VS Code `code` CLI without relying on PATH.
CODE=""
for c in \
  "/usr/local/bin/code" \
  "/opt/homebrew/bin/code" \
  "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" \
  "$HOME/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" \
  "/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code" \
  "$HOME/Applications/Visual Studio Code - Insiders.app/Contents/Resources/app/bin/code"; do
  [ -x "$c" ] && { CODE="$c"; break; }
done
if [ -z "$CODE" ] && command -v code >/dev/null 2>&1; then CODE="$(command -v code)"; fi

focused=0
if [ -n "$CODE" ] && [ -n "$CWD" ] && [ -d "$CWD" ]; then
  # `code <folder>` focuses the existing window for that folder and brings VS
  # Code forward — no Accessibility permission needed. In the normal case this
  # is all we need, so we do nothing further.
  if "$CODE" "$CWD" >/dev/null 2>&1; then focused=1; fi
  log "code focus: '$CODE' -> '$CWD' (ok=$focused)"
fi

# Fallback: the code CLI was unavailable or failed. Bring VS Code forward, then
# best-effort raise the matching window by title via System Events (requires
# Accessibility permission for the launching app; silently no-ops if not granted).
if [ "$focused" -eq 0 ]; then
  open -a "Visual Studio Code" >/dev/null 2>&1 \
    || open -a "Visual Studio Code - Insiders" >/dev/null 2>&1 \
    || true
  if [ -n "$LEAF" ]; then
    LEAF_SAFE="${LEAF//\"/}"
    osascript >/dev/null 2>&1 <<OSA || true
tell application "System Events"
  if exists (process "Code") then
    tell process "Code"
      set frontmost to true
      try
        perform action "AXRaise" of (first window whose name contains "$LEAF_SAFE")
      end try
    end tell
  end if
end tell
OSA
    log "fallback: open -a + AppleScript raise by leaf='$LEAF_SAFE'"
  fi
fi

exit 0
