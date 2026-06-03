#!/usr/bin/env bash
# Claude Code -> macOS notification bridge.
#
# Invoked by Claude Code hooks (Stop / Notification / PreToolUse) with the event
# name as $1. Reads the event JSON on stdin, renders a native macOS notification
# via terminal-notifier, and wires the notification click to focus the right
# VS Code window (via focus-vscode.sh).
#
# Logs to $TMPDIR/claude-toast.log so failures are diagnosable. Never exits
# non-zero — a failed notification must not break the Claude Code session.

set -uo pipefail

EVENT="${1:-Stop}"

LOG="${TMPDIR:-/tmp}/claude-toast.log"
log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$EVENT" "$*" >>"$LOG" 2>/dev/null || true; }

# --- read the event JSON from stdin ---------------------------------------
INPUT="$(cat 2>/dev/null || true)"

# --- locate a JSON parser --------------------------------------------------
# node is guaranteed for anyone running Claude Code; python3 is a fallback.
JSON_PARSER=""
if command -v node >/dev/null 2>&1; then
  JSON_PARSER="node"
elif command -v python3 >/dev/null 2>&1; then
  JSON_PARSER="python3"
fi

# Extract message / question / hasPlan / cwd. Each field is base64-encoded and
# the four are joined by single spaces (base64 only uses [A-Za-z0-9+/=], so the
# tokens are space-safe). Empty fields are emitted as "-" so positional parsing
# with `read` never collapses a missing field.
extract() {
  case "$JSON_PARSER" in
    node)
      printf '%s' "$INPUT" | node -e '
        let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
          let d={};try{d=JSON.parse(s)}catch(e){}
          const ti=d.tool_input||{};
          const msg=d.message||"";
          const q=(ti.questions&&ti.questions[0]&&ti.questions[0].question)||"";
          const plan=ti.plan?"1":"";
          const cwd=d.cwd||"";
          const enc=v=>{const b=Buffer.from(String(v),"utf8").toString("base64");return b||"-";};
          process.stdout.write([msg,q,plan,cwd].map(enc).join(" "));
        });' 2>/dev/null
      ;;
    python3)
      printf '%s' "$INPUT" | python3 -c '
import sys,json,base64
try: d=json.load(sys.stdin)
except Exception: d={}
ti=d.get("tool_input") or {}
msg=d.get("message") or ""
qs=ti.get("questions") or []
q=(qs[0].get("question") if qs and isinstance(qs[0],dict) else "") or ""
plan="1" if ti.get("plan") else ""
cwd=d.get("cwd") or ""
def enc(v):
    b=base64.b64encode(str(v).encode("utf-8")).decode("ascii")
    return b if b else "-"
sys.stdout.write(" ".join(enc(x) for x in [msg,q,plan,cwd]))' 2>/dev/null
      ;;
    *)
      printf -- '- - - -'
      ;;
  esac
}

dec() { [ "${1:-}" = "-" ] && return 0; printf '%s' "$1" | base64 -d 2>/dev/null || true; }

T_MSG="-"; T_Q="-"; T_PLAN="-"; T_CWD="-"
read -r T_MSG T_Q T_PLAN T_CWD < <(extract) || true
MSG="$(dec "$T_MSG")"
QUESTION="$(dec "$T_Q")"
HASPLAN="$(dec "$T_PLAN")"
CWD="$(dec "$T_CWD")"

# --- decide title / subtitle / body based on the event --------------------
TITLE="Claude Code"
if [ "$EVENT" = "Notification" ]; then
  SUBTITLE="Needs your attention"
  if [ -n "$MSG" ]; then
    # Plain Notification event (permission_prompt, idle_prompt, etc.)
    BODY="$MSG"
  elif [ -n "$QUESTION" ]; then
    # PreToolUse on AskUserQuestion -> surface the first question's text
    BODY="$QUESTION"
  elif [ -n "$HASPLAN" ]; then
    # PreToolUse on ExitPlanMode -> Claude wants you to approve a plan
    BODY="Claude is proposing a plan — your approval is needed"
  else
    BODY="Waiting for your input in VS Code"
  fi
else
  SUBTITLE="Turn complete"
  BODY="Ready for your next prompt"
fi

[ -z "$BODY" ] && BODY=" "
# Keep the body to a sane length for a notification.
if [ "${#BODY}" -gt 200 ]; then BODY="${BODY:0:197}..."; fi

LEAF=""
[ -n "$CWD" ] && LEAF="$(basename "$CWD" 2>/dev/null || true)"

# --- suppress when you're already looking at this project's window ----------
# Two cheap-to-expensive steps. Step 1 (frontmost app) needs no permission. Step
# 2 (window title) uses System Events and needs Accessibility — if that's not
# granted it fails, and we fail OPEN (show the banner) rather than wrongly hide
# it. So the feature is best-effort: it only ever hides a banner we're certain
# you don't need.
is_focused_on_this_project() {
  [ -n "$LEAF" ] || return 1
  # Frontmost application's bundle id (no permission required).
  local asn bid
  asn="$(lsappinfo front 2>/dev/null)" || return 1
  [ -n "$asn" ] || return 1
  bid="$(lsappinfo info -only bundleID "$asn" 2>/dev/null | sed -n 's/.*"CFBundleIdentifier"="\([^"]*\)".*/\1/p')"
  case "$bid" in
    com.microsoft.VSCode|com.microsoft.VSCodeInsiders|com.visualstudio.code.oss|com.vscodium) ;;
    *) return 1 ;;  # a non-VS-Code app is frontmost -> you're not looking here
  esac
  # VS Code is frontmost. Is the focused WINDOW this project? Compare its title
  # to the project folder name (VS Code titles include the root folder name).
  local title
  title="$(osascript -e 'tell application "System Events" to tell (first process whose frontmost is true) to get title of front window' 2>/dev/null)" || return 1
  [ -n "$title" ] || return 1
  case "$title" in
    *"$LEAF"*) return 0 ;;  # focused window belongs to this project -> suppress
    *) return 1 ;;
  esac
}
if is_focused_on_this_project; then
  log "suppressed: focused on this project's VS Code window (leaf='$LEAF')"
  exit 0
fi

# --- locate terminal-notifier ---------------------------------------------
# Check PATH first, then Homebrew prefixes and our per-user fallback install.
find_terminal_notifier() {
  if command -v terminal-notifier >/dev/null 2>&1; then command -v terminal-notifier; return; fi
  local p
  for p in \
    "$HOME/.claude/bin/terminal-notifier.app/Contents/MacOS/terminal-notifier" \
    "/opt/homebrew/bin/terminal-notifier" \
    "/usr/local/bin/terminal-notifier" \
    "/Applications/terminal-notifier.app/Contents/MacOS/terminal-notifier"; do
    [ -x "$p" ] && { printf '%s' "$p"; return; }
  done
}
TN="$(find_terminal_notifier)"
if [ -z "$TN" ]; then
  log "FAILED: terminal-notifier not found on PATH or in ~/.claude/bin"
  exit 0
fi

# --- build the click action (focus the right VS Code window) --------------
# The cwd is base64-encoded so it survives terminal-notifier's `sh -c` with no
# quoting hazards (base64 uses only [A-Za-z0-9+/=], none of which are shell
# metacharacters). focus-vscode.sh decodes it and focuses the window.
FOCUS_SCRIPT="$HOME/.claude/hooks/focus-vscode.sh"
EXECUTE=""
if [ -n "$CWD" ] && [ -f "$FOCUS_SCRIPT" ]; then
  CWD_B64="$(printf '%s' "$CWD" | base64 | tr -d '\n')"
  EXECUTE="'$FOCUS_SCRIPT' $CWD_B64"
fi

# Group per-project so a fresh notification replaces a stale one for the same
# project instead of stacking. (Stop only fires once a turn finishes, so it
# never overwrites a still-pending permission/question notification.)
GROUP="claude-toast"
[ -n "$LEAF" ] && GROUP="claude-toast-$LEAF"

args=( -title "$TITLE" -subtitle "$SUBTITLE" -message "$BODY" -sound default -group "$GROUP" )
[ -n "$EXECUTE" ] && args+=( -execute "$EXECUTE" )

if "$TN" "${args[@]}" >>"$LOG" 2>&1; then
  log "submitted: '$SUBTITLE' / '$BODY'"
else
  log "FAILED: terminal-notifier exited $?"
fi

exit 0
