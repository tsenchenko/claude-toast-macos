#!/usr/bin/env bash
# Claude Code -> macOS notification bridge.
#
# Invoked by Claude Code hooks with the event name as $1:
#   Stop / Notification / PreToolUse / PostToolUse
# Reads the event JSON on stdin, renders native macOS notifications via
# terminal-notifier, and wires the notification click to focus the right VS Code
# window (via focus-vscode.sh).
#
# Why PreToolUse + PostToolUse: the VS Code extension does NOT fire any hook when
# it shows a tool-permission prompt ("Allow reading from X?"). To still notify on
# those, we run a small "waiting" detector — PreToolUse arms a marker per
# tool_use_id and a background watcher; PostToolUse clears it. If a normally-instant
# tool (Read/Edit/Write) hasn't completed within WAIT_SECS, it's blocked on a
# permission prompt, so we show a banner. Tools that legitimately run long (Bash,
# Grep, …) are NOT armed, to avoid false "needs approval" banners.
#
# A marker can ALSO go stale when a tool errors / is denied / is cancelled —
# PostToolUse only fires for tools that actually complete, so those markers never
# get cleared. We tell that apart from a genuine block with an activity heartbeat:
# a real permission prompt freezes the session (nothing happens after the armed
# tool), whereas a leaked marker is followed by more activity. Only the former
# fires a banner.
#
# Logs to $TMPDIR/claude-banners.log. Never exits non-zero — a failed
# notification must not break the Claude Code session.

set -uo pipefail

EVENT="${1:-Stop}"

LOG="${TMPDIR:-/tmp}/claude-banners.log"
log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$EVENT" "$*" >>"$LOG" 2>/dev/null || true; }

# --- waiting-detector knobs ------------------------------------------------
# One marker file per in-flight tool call lives here.
PENDING_DIR="${TMPDIR:-/tmp}/claude-banners-pending"
# Heartbeat touched on every hook event. The watcher compares it to a marker's
# age: if anything happened AFTER the tool was armed, the session moved on (the
# marker just leaked — tool errored/denied/cancelled, no PostToolUse), so we stay
# quiet. Only a tool with no activity after it is genuinely blocked on YOU.
ACTIVITY_FILE="${TMPDIR:-/tmp}/claude-banners.activity"
# How long an armed tool may run before we assume it's blocked on a permission
# prompt. Set well ABOVE how long these tools actually take to finish in practice
# — including under heavy parallel workflows, where PostToolUse (which clears the
# marker) can lag — so a slow-but-unblocked tool never false-fires. A real
# permission prompt waits for you, far longer than this, so it still gets caught.
WAIT_SECS=30
# Tools whose runtime is always near-instant — a stall means "awaiting approval".
# Bash/Grep/Glob/Task/WebFetch/WebSearch are deliberately omitted: they can run
# long for legitimate reasons and would produce false alarms.
ARMED_TOOLS="Read Edit Write MultiEdit NotebookEdit"

FOCUS_SCRIPT="$HOME/.claude/hooks/focus-vscode.sh"

# --- read the event JSON from stdin ---------------------------------------
INPUT="$(cat 2>/dev/null || true)"

# --- lightweight JSON string reader (no node) ------------------------------
# Pulls the first "key":"value". Values we read this way (tool_use_id, tool_name,
# cwd) never contain embedded double quotes, so this is sufficient — and fast
# enough to run on every single tool call.
jstr() { printf '%s' "$INPUT" | grep -oE "\"$1\":\"[^\"]*\"" | head -1 | sed -e "s/^\"$1\":\"//" -e 's/\"$//'; }

# --- rich field extraction (node, python3 fallback) ------------------------
# Only used for the question/plan/message paths (Notification, AskUserQuestion,
# ExitPlanMode), never on the per-tool fast path — so the parser lookup lives
# here, not at top level. Emits msg/question/plan/cwd as space-joined base64
# tokens ("-" for empty) so positional `read` is safe.
extract() {
  local JSON_PARSER=""
  if command -v node >/dev/null 2>&1; then JSON_PARSER="node"
  elif command -v python3 >/dev/null 2>&1; then JSON_PARSER="python3"; fi
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
    *) printf -- '- - - -' ;;
  esac
}
dec() { [ "${1:-}" = "-" ] && return 0; printf '%s' "$1" | base64 -d 2>/dev/null || true; }

# --- helpers ---------------------------------------------------------------
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

# Resolve a possibly-nested working directory to the project root that VS Code
# actually has open (git top-level, else nearest marker dir, else unchanged).
# Normalises to an absolute path first so the marker walk can't loop on ".".
resolve_project_root() {
  local d="${1:-}"
  [ -n "$d" ] || { printf '%s' "$d"; return; }
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

# Suppress when you're already looking at this project's VS Code window. Takes the
# project leaf name. Best-effort: needs Accessibility for the window-title step
# and fails OPEN (shows the banner) when it can't tell.
is_focused_on_this_project() {
  local leaf="${1:-}"
  [ -n "$leaf" ] || return 1
  local asn bid
  asn="$(lsappinfo front 2>/dev/null)" || return 1
  [ -n "$asn" ] || return 1
  bid="$(lsappinfo info -only bundleID "$asn" 2>/dev/null | sed -n 's/.*"CFBundleIdentifier"="\([^"]*\)".*/\1/p')"
  case "$bid" in
    com.microsoft.VSCode|com.microsoft.VSCodeInsiders|com.visualstudio.code.oss|com.vscodium) ;;
    *) return 1 ;;
  esac
  local title
  title="$(osascript -e 'tell application "System Events" to tell (first process whose frontmost is true) to get title of front window' 2>/dev/null)" || return 1
  [ -n "$title" ] || return 1
  case "$title" in
    *"$leaf"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Render one notification. Resolves cwd -> project root, suppresses if you're
# already on that window, and wires the click to focus it.
#   show_banner <subtitle> <body> <raw-cwd>
show_banner() {
  local subtitle="$1" body="${2:- }" rawcwd="${3:-}"
  local cwd leaf
  cwd="$(resolve_project_root "$rawcwd")"
  leaf=""; [ -n "$cwd" ] && leaf="$(basename "$cwd" 2>/dev/null || true)"
  if is_focused_on_this_project "$leaf"; then
    log "suppressed (focused, leaf='$leaf'): $subtitle / $body"; return 0
  fi
  local tn; tn="$(find_terminal_notifier)"
  if [ -z "$tn" ]; then log "FAILED: terminal-notifier not found"; return 0; fi
  [ -z "$body" ] && body=" "
  if [ "${#body}" -gt 200 ]; then body="${body:0:197}..."; fi
  local group="claude-banners"; [ -n "$leaf" ] && group="claude-banners-$leaf"
  local execute=""
  if [ -n "$cwd" ] && [ -f "$FOCUS_SCRIPT" ]; then
    local b64; b64="$(printf '%s' "$cwd" | base64 | tr -d '\n')"
    execute="'$FOCUS_SCRIPT' $b64"
  fi
  local args=( -title "Claude Code" -subtitle "$subtitle" -message "$body" -sound default -group "$group" )
  [ -n "$execute" ] && args+=( -execute "$execute" )
  if "$tn" "${args[@]}" >>"$LOG" 2>&1; then log "submitted: '$subtitle' / '$body'"; else log "FAILED: terminal-notifier exited $?"; fi
}

# --- dispatch --------------------------------------------------------------
# Mark that the session is alive/progressing (used by the watcher below).
touch "$ACTIVITY_FILE" 2>/dev/null || true
case "$EVENT" in
  PreToolUse)
    # Fires before EVERY tool call. Keep the common path cheap (grep, no node).
    tool_name="$(jstr tool_name)"
    case "$tool_name" in
      AskUserQuestion|ExitPlanMode)
        # Always a prompt for you -> banner immediately (these don't come through
        # the Notification event in current Claude Code).
        T_MSG="-"; T_Q="-"; T_PLAN="-"; T_CWD="-"
        read -r T_MSG T_Q T_PLAN T_CWD < <(extract) || true
        Q="$(dec "$T_Q")"; PLAN="$(dec "$T_PLAN")"; CWD="$(dec "$T_CWD")"
        if [ -n "$Q" ]; then BODY="$Q"
        elif [ -n "$PLAN" ]; then BODY="Claude is proposing a plan — your approval is needed"
        else BODY="Waiting for your input in VS Code"; fi
        show_banner "Needs your attention" "$BODY" "$CWD"
        ;;
      Read|Edit|Write|MultiEdit|NotebookEdit)
        # Arm the waiting detector: if PostToolUse doesn't clear this within
        # WAIT_SECS, the tool is blocked on a permission prompt.
        tuid="$(jstr tool_use_id)"; [ -n "$tuid" ] || exit 0
        cwd="$(jstr cwd)"
        mkdir -p "$PENDING_DIR" 2>/dev/null || true
        marker="$PENDING_DIR/$tuid"
        printf '%s\n' "$cwd" >"$marker" 2>/dev/null || true
        # Detached watcher — the hook itself returns immediately.
        ( sleep "$WAIT_SECS"
          # Fire only if the marker survived AND nothing happened after it was
          # armed. Activity afterwards ⇒ the tool didn't block you — its marker
          # just leaked (errored/denied/cancelled, no PostToolUse) — so stay quiet.
          if [ -e "$marker" ]; then
            if [ "$ACTIVITY_FILE" -nt "$marker" ]; then
              log "suppressed: '$tool_name' marker leaked (no PostToolUse; session moved on) — not a prompt"
            else
              show_banner "Needs your approval" "$tool_name is waiting for your permission" "$(cat "$marker" 2>/dev/null || true)"
            fi
          fi
          rm -f "$marker" 2>/dev/null || true
        ) </dev/null >/dev/null 2>&1 &
        disown 2>/dev/null || true
        ;;
      *) : ;;  # Bash/Grep/Glob/Task/Web… — not armed, no banner
    esac
    exit 0
    ;;
  PostToolUse)
    # Tool finished (or was approved) -> cancel its pending watcher. If it took
    # unusually long to clear (but was never a prompt), note it so the WAIT_SECS
    # margin can be sanity-checked against real-world latency.
    tuid="$(jstr tool_use_id)"
    if [ -n "$tuid" ]; then
      marker="$PENDING_DIR/$tuid"
      if [ -e "$marker" ]; then
        age=$(( $(date +%s) - $(stat -f %m "$marker" 2>/dev/null || date +%s) ))
        [ "$age" -ge 5 ] && log "armed tool cleared after ${age}s (not a prompt; WAIT_SECS=$WAIT_SECS)"
        rm -f "$marker" 2>/dev/null || true
      fi
    fi
    exit 0
    ;;
  Notification)
    T_MSG="-"; T_Q="-"; T_PLAN="-"; T_CWD="-"
    read -r T_MSG T_Q T_PLAN T_CWD < <(extract) || true
    MSG="$(dec "$T_MSG")"; Q="$(dec "$T_Q")"; PLAN="$(dec "$T_PLAN")"; CWD="$(dec "$T_CWD")"
    if [ -n "$MSG" ]; then BODY="$MSG"
    elif [ -n "$Q" ]; then BODY="$Q"
    elif [ -n "$PLAN" ]; then BODY="Claude is proposing a plan — your approval is needed"
    else BODY="Waiting for your input in VS Code"; fi
    show_banner "Needs your attention" "$BODY" "$CWD"
    ;;
  *)  # Stop (turn complete)
    CWD="$(jstr cwd)"
    show_banner "Turn complete" "Ready for your next prompt" "$CWD"
    ;;
esac

exit 0
