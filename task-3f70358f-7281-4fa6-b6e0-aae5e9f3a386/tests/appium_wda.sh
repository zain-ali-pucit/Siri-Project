# tests/appium_wda.sh. Generated and locked: the task checks compare this
# file byte for byte. Source it from the check block of tests/test.sh:
#   . "$(dirname "$0")/appium_wda.sh"
#
# appium_start                    Start Appium. Never reuses a server.
# appium_session [bundle_id]      Make an XCUITest session on $UDID.
# appium_page_source [file]       Save the page source (default wda-source.xml).
# appium_screenshot [file]        Save a screenshot (default screenshot.png).
# appium_exists <accessibility_id>  Return 0 if the element is found, else 1.
# appium_tap <accessibility_id>   Tap the element. Return 1 if it is not found.
# appium_text <accessibility_id>  Print the element text. Return 1 if not found.
# appium_scroll_to <accessibility_id> [max_swipes] [down|up]
#                                 Swipe until the element is on screen (for a
#                                 row of a long list that is not drawn yet).
#                                 Default 10 swipes, down. Return 1 if it is
#                                 not on screen after the last swipe.
#
# A file name with no '/' goes to $ARTIFACTS. A missing element returns 1,
# so guard it: appium_tap save_button || fail "...". Appium or WDA that does
# not answer gives the error appium_unavailable. A port that another
# process holds, before or after the start, gives appium_port_in_use. Each
# Appium answer counts only while the listener on the port is the Appium
# that appium_start started (lsof and ps). In the verifier (test.sh is a
# child of /opt/siri/bin/siri-verify-run), appium_session needs
# SIRI_VERIFIER_WDA_DIR and the root-owned verifier xcodebuild, else it
# gives toolchain_missing and does not start Appium. A listener on the WDA
# port before the session, or a listener after the session that is not the
# WDA of our Appium, gives wda_port_in_use. Outside the verifier (a local
# run, or a run in the VM before the verifier), the helper does not check
# the WDA port. Cleanup is automatic.
# Settings: SIRI_APPIUM_PORT (4723), SIRI_WDA_PORT (8100),
# SIRI_APPIUM_SESSION_TIMEOUT_SEC (600), SIRI_APPIUM_IMPLICIT_WAIT_MS (5000).

if ! declare -F siri_on_cleanup >/dev/null 2>&1 || ! declare -F siri_helper_error >/dev/null 2>&1 || ! declare -F siri_frame_error >/dev/null 2>&1; then
  printf 'appium_wda.sh: source this file from the tests/test.sh frame.\n' >&2
  return 1 2>/dev/null || exit 1
fi
if declare -F appium_start >/dev/null 2>&1; then
  return 0
fi
# The cleanup must be registered in the test.sh shell itself. In a
# subshell, the child sh has a parent other than $$.
if [ "$(exec sh -c 'printf "%s" "$PPID"')" != "$$" ]; then
  siri_frame_error check_block_crashed "Source appium_wda.sh at the top level of the check block, not in a subshell, a pipe or a \$(...)."
fi

SIRI_APPIUM_PORT="${SIRI_APPIUM_PORT:-4723}"
SIRI_WDA_PORT="${SIRI_WDA_PORT:-8100}"
SIRI_APPIUM_START_TIMEOUT_SEC="${SIRI_APPIUM_START_TIMEOUT_SEC:-60}"
SIRI_APPIUM_SESSION_TIMEOUT_SEC="${SIRI_APPIUM_SESSION_TIMEOUT_SEC:-600}"
SIRI_APPIUM_HTTP_TIMEOUT_SEC="${SIRI_APPIUM_HTTP_TIMEOUT_SEC:-60}"
SIRI_APPIUM_IMPLICIT_WAIT_MS="${SIRI_APPIUM_IMPLICIT_WAIT_MS:-5000}"
SIRI_APPIUM_URL="http://127.0.0.1:$SIRI_APPIUM_PORT"
SIRI_APPIUM_SESSION_ID=''
SIRI_APPIUM_STATUS=''
SIRI_APPIUM_ELEMENT_ID=''
# State files: pid (an Appium this run started), session, ready.
SIRI_APPIUM_TMP="$(mktemp -d "${TMPDIR:-/tmp}/siri-appium.XXXXXX")" || siri_helper_error toolchain_missing "mktemp could not make a folder for Appium."

siri_appium_json() {
  python3 - "$@" <<'PY'
import base64
import json
import sys

op = sys.argv[1]
if op == 'quote':
    print(json.dumps(sys.argv[2]))
    sys.exit(0)
try:
    with open(sys.argv[2], 'rb') as handle:
        doc = json.loads(handle.read().decode('utf-8'))
except (OSError, ValueError):
    sys.exit(3)
value = doc.get('value') if isinstance(doc, dict) else None
if op == 'session':
    sid = value.get('sessionId') if isinstance(value, dict) else None
    sid = sid or (doc.get('sessionId') if isinstance(doc, dict) else None)
    if not isinstance(sid, str) or not sid:
        sys.exit(1)
    print(sid)
elif op == 'element':
    eid = None
    if isinstance(value, dict):
        eid = value.get('element-6066-11e4-a52e-4f735466cecf') or value.get('ELEMENT')
    if not isinstance(eid, str) or not eid:
        sys.exit(1)
    print(eid)
elif op == 'error':
    error = value.get('error') if isinstance(value, dict) else None
    print(error if isinstance(error, str) else '')
elif op == 'text':
    if not isinstance(value, str):
        sys.exit(1)
    sys.stdout.write(value)
elif op == 'displayed':
    if not isinstance(value, bool):
        sys.exit(1)
    print('true' if value else 'false')
elif op == 'rect':
    if not isinstance(value, dict):
        sys.exit(1)
    try:
        width = int(value['width'])
        height = int(value['height'])
    except (KeyError, TypeError, ValueError):
        sys.exit(1)
    if width <= 0 or height <= 0:
        sys.exit(1)
    print('%d %d' % (width, height))
elif op == 'save_text':
    if not isinstance(value, str):
        sys.exit(1)
    with open(sys.argv[3], 'w', encoding='utf-8') as handle:
        handle.write(value)
elif op == 'save_base64':
    if not isinstance(value, str):
        sys.exit(1)
    with open(sys.argv[3], 'wb') as handle:
        handle.write(base64.b64decode(value))
else:
    sys.exit(2)
PY
}

# siri_appium_http <method> <path> [json body] [max seconds]
# Saves the body to $SIRI_APPIUM_TMP/response.json and prints the HTTP status.
siri_appium_http() {
  local method="$1" path="$2" body="${3:-}" max="${4:-$SIRI_APPIUM_HTTP_TIMEOUT_SEC}"
  rm -f "$SIRI_APPIUM_TMP/response.json"
  if [ -n "$body" ]; then
    curl -sS -o "$SIRI_APPIUM_TMP/response.json" -w '%{http_code}' -X "$method" --max-time "$max" -H 'Content-Type: application/json' --data-binary "$body" "$SIRI_APPIUM_URL$path"
  else
    curl -sS -o "$SIRI_APPIUM_TMP/response.json" -w '%{http_code}' -X "$method" --max-time "$max" "$SIRI_APPIUM_URL$path"
  fi
}

# Sets SIRI_APPIUM_STATUS. No HTTP answer gives appium_unavailable. An
# answer from a listener that is not our Appium gives an error.
siri_appium_call() {
  if ! SIRI_APPIUM_STATUS="$(siri_appium_http "$@")"; then
    siri_helper_error appium_unavailable "Appium gave no answer to $1 $2."
  fi
  siri_appium_require_owner "$(siri_appium_state pid)"
  if [ -s "$SIRI_APPIUM_TMP/session" ]; then siri_wda_require_owner; fi
}

siri_appium_path() {
  case "$1" in
    */*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$ARTIFACTS" "$1" ;;
  esac
}

siri_appium_wda_log() {
  grep -E 'xcodebuild|WebDriverAgent|WDA' "$ARTIFACTS/appium.log" > "$ARTIFACTS/wda-build.log" 2>/dev/null || true
}

# Prints a state file, or nothing when it is missing.
siri_appium_state() {
  if [ -s "$SIRI_APPIUM_TMP/$1" ]; then cat "$SIRI_APPIUM_TMP/$1"; fi
}

# Sets SIRI_APPIUM_SESSION_ID from the session file.
siri_appium_require_session() {
  SIRI_APPIUM_SESSION_ID="$(siri_appium_state session)"
  [ -n "$SIRI_APPIUM_SESSION_ID" ] || siri_helper_error check_block_crashed "appium_wda.sh: call appium_session first."
}

# Element errors that mean the app does not show the element as asked.
siri_appium_element_error() {
  case "$(siri_appium_json error "$SIRI_APPIUM_TMP/response.json")" in
    'no such element'|'stale element reference'|'element not interactable'|'element click intercepted') return 0 ;;
    *) return 1 ;;
  esac
}

siri_appium_cleanup() {
  local session pid waited=0
  session="$(siri_appium_state session)"
  pid="$(siri_appium_state pid)"
  if [ -n "$session" ]; then
    curl -sS -o /dev/null -X DELETE --max-time 30 "$SIRI_APPIUM_URL/session/$session" >/dev/null 2>&1
  fi
  if [ -n "$pid" ]; then
    kill "$pid" >/dev/null 2>&1
    while kill -0 "$pid" >/dev/null 2>&1 && [ "$waited" -lt 10 ]; do
      sleep 1
      waited=$((waited + 1))
    done
    kill -9 "$pid" >/dev/null 2>&1
  fi
  siri_appium_wda_log
  rm -rf "$SIRI_APPIUM_TMP"
}
siri_on_cleanup siri_appium_cleanup

# siri_appium_listeners: prints the PIDs that listen on TCP port
# $SIRI_APPIUM_PORT, one a line. lsof sees only the processes that this
# user can read, so an empty list does not prove that the port is free.
siri_appium_listeners() {
  lsof -nP -iTCP:"$SIRI_APPIUM_PORT" -sTCP:LISTEN -t 2>/dev/null || true
}

# siri_appium_tree <pid>: prints <pid> and each descendant of it, one a
# line. Status 1 when ps cannot list the processes.
siri_appium_tree() {
  local list
  list="$(ps -A -o pid= -o ppid=)" || return 1
  [ -n "$list" ] || return 1
  printf '%s\n' "$list" | awk -v root="$1" '
    { parent[$1] = $2; pids[n++] = $1 }
    END {
      mine[root] = 1
      print root
      do {
        added = 0
        for (i = 0; i < n; i++) {
          p = pids[i]
          if (!(p in mine) && (parent[p] in mine)) {
            mine[p] = 1
            print p
            added = 1
          }
        }
      } while (added)
    }'
}

# siri_appium_require_owner <pid>: the Appium that appium_start started
# (<pid>) must be alive, and each TCP listener on the port must be <pid> or
# a descendant of it. A process of the check can bind the port when our
# Appium stops, and then answer as Appium. Any doubt is an error.
siri_appium_require_owner() {
  local IFS=$' \t\n' pid="$1" listeners tree listener
  [ -n "$pid" ] || siri_helper_error check_block_crashed "appium_wda.sh: call appium_start first."
  if ! kill -0 "$pid" >/dev/null 2>&1; then
    siri_helper_error appium_unavailable "The Appium that appium_start started stopped. See appium.log."
  fi
  listeners="$(siri_appium_listeners)"
  if [ -z "$listeners" ]; then
    siri_helper_error appium_port_in_use "lsof shows no listener of ours on port $SIRI_APPIUM_PORT, but a server answered there."
  fi
  tree="$(siri_appium_tree "$pid")" || siri_helper_error toolchain_missing "ps could not list the processes."
  tree=" $(printf '%s ' $tree)"
  for listener in $listeners; do
    case "$tree" in
      *" $listener "*) ;;
      *) siri_helper_error appium_port_in_use "Process $listener listens on port $SIRI_APPIUM_PORT, and it is not the Appium that appium_start started." ;;
    esac
  done
}

# siri_port_bindable <port>: status 0 when a bind to 127.0.0.1:<port> works.
# The bind sets SO_REUSEADDR, as Appium does: a closed connection in
# TIME_WAIT does not block it, but a listener of any user does.
siri_port_bindable() {
  python3 - "$1" <<'PY'
import socket
import sys

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(('127.0.0.1', int(sys.argv[1])))
except (OSError, ValueError):
    sys.exit(1)
finally:
    sock.close()
PY
}

# siri_appium_port_free: status 0 only when no process listens on the port,
# a bind to it works and no server answers /status on it.
siri_appium_port_free() {
  local listeners
  listeners="$(siri_appium_listeners)"
  if [ -n "$listeners" ]; then
    printf 'appium_wda.sh: port %s has a listener before the start: %s\n' "$SIRI_APPIUM_PORT" "$(printf '%s ' $listeners)" >> "$ARTIFACTS/appium.log"
    return 1
  fi
  if ! siri_port_bindable "$SIRI_APPIUM_PORT"; then
    printf 'appium_wda.sh: port %s cannot be bound before the start.\n' "$SIRI_APPIUM_PORT" >> "$ARTIFACTS/appium.log"
    return 1
  fi
  if siri_appium_http GET /status '' 5 >/dev/null 2>&1; then
    printf 'appium_wda.sh: a server answered /status on port %s before the start.\n' "$SIRI_APPIUM_PORT" >> "$ARTIFACTS/appium.log"
    return 1
  fi
  return 0
}

# siri_wda_listeners: prints the PIDs that listen on TCP port
# $SIRI_WDA_PORT, one a line. Status 1 when lsof is missing, fails, writes
# an error or prints a line that is not a PID. lsof gives status 1 with no
# output when no process listens. lsof sees only the processes that this
# user can read, so an empty list does not prove that the port is free.
siri_wda_listeners() {
  local IFS=$' \t\n' out rc line
  command -v lsof >/dev/null 2>&1 || return 1
  out="$(lsof -w -nP -iTCP:"$SIRI_WDA_PORT" -sTCP:LISTEN -t 2>"$SIRI_APPIUM_TMP/wda-lsof.err")"
  rc=$?
  if [ "$rc" -gt 1 ] || [ -s "$SIRI_APPIUM_TMP/wda-lsof.err" ]; then return 1; fi
  if [ "$rc" = 1 ] && [ -n "$out" ]; then return 1; fi
  for line in $out; do
    case "$line" in
      *[!0-9]*) return 1 ;;
    esac
  done
  if [ -n "$out" ]; then printf '%s\n' "$out"; fi
}

# The root-owned verifier xcodebuild. With SIRI_VERIFIER_WDA_DIR, the
# Appium wrapper puts it first in PATH. It listens on the WDA port and
# forwards to the WDA runner only after it checks the runner.
SIRI_VERIFIER_XCODEBUILD=/opt/siri/libexec/verifier-xcodebuild/xcodebuild

# siri_wda_strict: status 0 in the verifier. The runner sets
# SIRI_VERIFIER_WDA_DIR in the environment of test.sh for the verifier only.
# The helper reads the variable at each check, not a file, so a process of
# the check cannot turn the checks off: it cannot change the environment of
# test.sh.
siri_wda_strict() {
  [ -n "${SIRI_VERIFIER_WDA_DIR:-}" ]
}

# siri_wda_verifier_run: status 0 in each verifier run, also on an image
# with no SIRI_VERIFIER_WDA_DIR. The runner starts test.sh as a child of the
# root-owned /opt/siri/bin/siri-verify-run, so the parent of the test.sh
# shell ($PPID) is that script, and a process of the check cannot change
# it. ps that fails also gives status 0: the verifier rules then apply. A
# local run or a run in the VM before the verifier has another parent.
siri_wda_verifier_run() {
  local args
  siri_wda_strict && return 0
  args="$(ps -o args= -p "$PPID" 2>/dev/null)" || return 0
  [ -n "$args" ] || return 0
  case " $args " in
    *" /opt/siri/bin/siri-verify-run "*) return 0 ;;
  esac
  return 1
}

# siri_wda_verifier_ready: status 0 when $SIRI_VERIFIER_XCODEBUILD is a
# regular file that root owns and that only root can write. Without it, the
# WDA runner listens on the WDA port itself and siri_wda_listener_ok cannot
# accept it.
siri_wda_verifier_ready() {
  python3 - "$SIRI_VERIFIER_XCODEBUILD" <<'PY'
import os
import stat
import sys

try:
    info = os.lstat(sys.argv[1])
except OSError:
    sys.exit(1)
if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
    sys.exit(1)
PY
}

# siri_wda_listener_ok <pid> <tree>: the owner rule of the WDA port. <tree>
# is ' <pid> <pid> ... ' of the Appium that appium_start started and its
# descendants. Status 0 only when <pid> is in <tree>. The verifier
# xcodebuild listens on the WDA port, and Appium starts it, so it is a
# descendant of Appium. A WDA runner that listens on the WDA port itself
# is not accepted: the simulator starts the runner, not Appium, so the
# helper cannot tell our runner from a runner that another process started.
siri_wda_listener_ok() {
  case "$2" in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# siri_wda_require_owner: in the verifier only (siri_wda_strict).
# appium_session does not start Appium in a verifier run without
# SIRI_VERIFIER_WDA_DIR, so this rule covers each verifier session. Appium
# has a session, so a WDA listens on $SIRI_WDA_PORT. Each TCP listener on
# that port must pass siri_wda_listener_ok. A process of the check can
# listen on the WDA port and answer for WDA. Any doubt (no listener, lsof
# or ps fails) is an error.
# Outside the verifier, the simulator starts the WDA runner, so it is not
# under our Appium, and this check does not run.
siri_wda_require_owner() {
  local IFS=$' \t\n' pid listeners tree listener
  siri_wda_strict || return 0
  pid="$(siri_appium_state pid)"
  [ -n "$pid" ] || siri_helper_error check_block_crashed "appium_wda.sh: call appium_start first."
  if ! listeners="$(siri_wda_listeners)"; then
    siri_helper_error wda_port_in_use "lsof could not list the listeners on the WDA port $SIRI_WDA_PORT."
  fi
  if [ -z "$listeners" ]; then
    siri_helper_error wda_port_in_use "lsof shows no listener on the WDA port $SIRI_WDA_PORT, but Appium has a session."
  fi
  tree="$(siri_appium_tree "$pid")" || siri_helper_error wda_port_in_use "ps could not list the processes to check the WDA port $SIRI_WDA_PORT."
  tree=" $(printf '%s ' $tree)"
  for listener in $listeners; do
    if ! siri_wda_listener_ok "$listener" "$tree"; then
      siri_helper_error wda_port_in_use "Process $listener listens on the WDA port $SIRI_WDA_PORT, and it is not the WDA of the Appium that appium_start started."
    fi
  done
}

# siri_wda_port_free: status 0 only when lsof shows no listener on
# $SIRI_WDA_PORT, a bind to it works and no server answers /status on it.
# lsof that is missing or fails gives status 1.
siri_wda_port_free() {
  local listeners
  if ! listeners="$(siri_wda_listeners)"; then
    printf 'appium_wda.sh: lsof could not list the listeners on the WDA port %s.\n' "$SIRI_WDA_PORT" >> "$ARTIFACTS/appium.log"
    return 1
  fi
  if [ -n "$listeners" ]; then
    printf 'appium_wda.sh: WDA port %s has a listener before the session: %s\n' "$SIRI_WDA_PORT" "$(printf '%s ' $listeners)" >> "$ARTIFACTS/appium.log"
    return 1
  fi
  if ! siri_port_bindable "$SIRI_WDA_PORT"; then
    printf 'appium_wda.sh: WDA port %s cannot be bound before the session.\n' "$SIRI_WDA_PORT" >> "$ARTIFACTS/appium.log"
    return 1
  fi
  if curl -sS -o /dev/null --max-time 5 "http://127.0.0.1:$SIRI_WDA_PORT/status" >/dev/null 2>&1; then
    printf 'appium_wda.sh: a server answered /status on the WDA port %s before the session.\n' "$SIRI_WDA_PORT" >> "$ARTIFACTS/appium.log"
    return 1
  fi
  return 0
}

appium_start() {
  local pid waited=0
  if [ -s "$SIRI_APPIUM_TMP/ready" ]; then return 0; fi
  command -v curl >/dev/null 2>&1 || siri_helper_error toolchain_missing "curl is not on PATH."
  command -v python3 >/dev/null 2>&1 || siri_helper_error toolchain_missing "python3 is not on PATH."
  command -v lsof >/dev/null 2>&1 || siri_helper_error toolchain_missing "lsof is not on PATH. appium_wda.sh needs it to check the owner of the Appium port."
  command -v ps >/dev/null 2>&1 || siri_helper_error toolchain_missing "ps is not on PATH."
  command -v awk >/dev/null 2>&1 || siri_helper_error toolchain_missing "awk is not on PATH."
  command -v appium >/dev/null 2>&1 || siri_helper_error toolchain_missing "appium is not on PATH."
  # Never use a server that is already on the port: a process of the check
  # can listen there and act as Appium.
  if ! siri_appium_port_free; then
    siri_helper_error appium_port_in_use "Another process holds port $SIRI_APPIUM_PORT before Appium starts. appium_wda.sh does not use a server that it did not start."
  fi
  appium --address 127.0.0.1 --port "$SIRI_APPIUM_PORT" --log-no-colors --log-timestamp >> "$ARTIFACTS/appium.log" 2>&1 &
  pid=$!
  printf '%s\n' "$pid" > "$SIRI_APPIUM_TMP/pid"
  while :; do
    # First our Appium: when it stops (for example because another process
    # took the port first), an answer on the port is not from it.
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      siri_helper_error appium_unavailable "Appium stopped before it answered /status. See appium.log."
    fi
    if SIRI_APPIUM_STATUS="$(siri_appium_http GET /status '' 5)" && [ "$SIRI_APPIUM_STATUS" = 200 ]; then
      break
    fi
    if [ "$waited" -ge "$SIRI_APPIUM_START_TIMEOUT_SEC" ]; then
      siri_helper_error appium_unavailable "Appium did not answer /status in $SIRI_APPIUM_START_TIMEOUT_SEC seconds."
    fi
    sleep 1
    waited=$((waited + 1))
  done
  siri_appium_require_owner "$pid"
  cp "$SIRI_APPIUM_TMP/response.json" "$ARTIFACTS/appium-status.json"
  printf '1\n' > "$SIRI_APPIUM_TMP/ready"
}

appium_session() {
  local bundle_id="${1:-}" caps
  [ -n "${UDID:-}" ] || siri_helper_error check_block_crashed "appium_wda.sh needs UDID from the simulator frame."
  if [ -s "$SIRI_APPIUM_TMP/session" ]; then return 0; fi
  case "$bundle_id" in
    *[!A-Za-z0-9.-]*) siri_helper_error check_block_crashed "appium_session got a bundle id with a character that is not allowed." ;;
  esac
  # The verifier. A verifier run needs SIRI_VERIFIER_WDA_DIR and the
  # verifier xcodebuild, else stop before Appium starts. Without them, the
  # simulator starts the WDA runner, not our Appium, so siri_wda_listener_ok
  # cannot accept our WDA, and the helper cannot find a process of the
  # check that listens on the WDA port after the pre-check. A grade from
  # such a run is not safe. toolchain_missing is retryable, so the job goes
  # back to the queue for a host image with the verifier pair.
  if siri_wda_verifier_run; then
    if ! siri_wda_strict; then
      siri_helper_error toolchain_missing "This verifier run has no SIRI_VERIFIER_WDA_DIR: the image does not have both the verifier WDA copy and the verifier xcodebuild. appium_wda.sh cannot check the owner of the WDA port, so it does not start Appium."
    fi
    if ! siri_wda_verifier_ready; then
      siri_helper_error toolchain_missing "The verifier xcodebuild is not ready: $SIRI_VERIFIER_XCODEBUILD is not a root-owned file that only root can write."
    fi
  fi
  appium_start
  # In the verifier, never use a WDA that is already on the WDA port:
  # Appium polls /status there, and a process of the check can answer as
  # WDA. From here, each verifier run has SIRI_VERIFIER_WDA_DIR. Outside
  # the verifier, a WDA runner from an earlier local run can still listen
  # there, so the helper does not check the port.
  if siri_wda_strict; then
    if [ "$SIRI_WDA_PORT" = "$SIRI_APPIUM_PORT" ]; then
      siri_helper_error wda_port_in_use "SIRI_WDA_PORT is the Appium port $SIRI_APPIUM_PORT."
    fi
    if ! siri_wda_port_free; then
      siri_helper_error wda_port_in_use "The WDA port $SIRI_WDA_PORT has a listener before the session, or lsof could not check it. See appium.log. appium_wda.sh does not use a WDA that its Appium did not start."
    fi
  fi
  caps='"platformName":"iOS","appium:automationName":"XCUITest","appium:udid":"'"$UDID"'","appium:wdaLocalPort":'"$SIRI_WDA_PORT"',"appium:noReset":true,"appium:showXcodeLog":true,"appium:newCommandTimeout":'"$SIRI_APPIUM_SESSION_TIMEOUT_SEC"
  if [ -n "$bundle_id" ]; then caps="$caps"',"appium:bundleId":"'"$bundle_id"'"'; fi
  siri_appium_call POST /session '{"capabilities":{"alwaysMatch":{'"$caps"'},"firstMatch":[{}]}}' "$SIRI_APPIUM_SESSION_TIMEOUT_SEC"
  cp "$SIRI_APPIUM_TMP/response.json" "$ARTIFACTS/appium-session.json" 2>/dev/null || true
  siri_appium_wda_log
  if [ "$SIRI_APPIUM_STATUS" != 200 ] || ! SIRI_APPIUM_SESSION_ID="$(siri_appium_json session "$SIRI_APPIUM_TMP/response.json")"; then
    SIRI_APPIUM_SESSION_ID=''
    siri_helper_error appium_unavailable "Appium made no session (HTTP $SIRI_APPIUM_STATUS). See appium-session.json and appium.log."
  fi
  printf '%s\n' "$SIRI_APPIUM_SESSION_ID" > "$SIRI_APPIUM_TMP/session"
  siri_wda_require_owner
  siri_appium_call POST "/session/$SIRI_APPIUM_SESSION_ID/timeouts" '{"implicit":'"$SIRI_APPIUM_IMPLICIT_WAIT_MS"'}'
  [ "$SIRI_APPIUM_STATUS" = 200 ] || siri_helper_error appium_unavailable "Appium did not set the implicit wait (HTTP $SIRI_APPIUM_STATUS)."
}

appium_page_source() {
  local out
  out="$(siri_appium_path "${1:-wda-source.xml}")"
  siri_appium_require_session
  siri_appium_call GET "/session/$SIRI_APPIUM_SESSION_ID/source"
  [ "$SIRI_APPIUM_STATUS" = 200 ] || siri_helper_error appium_unavailable "Appium gave no page source (HTTP $SIRI_APPIUM_STATUS)."
  siri_appium_json save_text "$SIRI_APPIUM_TMP/response.json" "$out" || siri_helper_error appium_unavailable "Appium gave a page source that could not be saved."
}

appium_screenshot() {
  local out
  out="$(siri_appium_path "${1:-screenshot.png}")"
  siri_appium_require_session
  siri_appium_call GET "/session/$SIRI_APPIUM_SESSION_ID/screenshot"
  [ "$SIRI_APPIUM_STATUS" = 200 ] || siri_helper_error appium_unavailable "Appium gave no screenshot (HTTP $SIRI_APPIUM_STATUS)."
  siri_appium_json save_base64 "$SIRI_APPIUM_TMP/response.json" "$out" || siri_helper_error appium_unavailable "Appium gave a screenshot that could not be saved."
}

# Sets SIRI_APPIUM_ELEMENT_ID. Returns 1 when the element is not found.
siri_appium_find() {
  local quoted
  siri_appium_require_session
  quoted="$(siri_appium_json quote "$1")"
  siri_appium_call POST "/session/$SIRI_APPIUM_SESSION_ID/element" '{"using":"accessibility id","value":'"$quoted"'}'
  if [ "$SIRI_APPIUM_STATUS" = 200 ]; then
    SIRI_APPIUM_ELEMENT_ID="$(siri_appium_json element "$SIRI_APPIUM_TMP/response.json")" || siri_helper_error appium_unavailable "Appium found an element but gave no element id."
    return 0
  fi
  if siri_appium_element_error; then return 1; fi
  siri_helper_error appium_unavailable "Appium could not search for an element (HTTP $SIRI_APPIUM_STATUS)."
}

appium_exists() {
  siri_appium_find "${1:?appium_exists needs an accessibility id}"
}

appium_tap() {
  siri_appium_find "${1:?appium_tap needs an accessibility id}" || return 1
  siri_appium_call POST "/session/$SIRI_APPIUM_SESSION_ID/element/$SIRI_APPIUM_ELEMENT_ID/click" '{}'
  if [ "$SIRI_APPIUM_STATUS" = 200 ]; then return 0; fi
  if siri_appium_element_error; then return 1; fi
  siri_helper_error appium_unavailable "Appium could not tap an element (HTTP $SIRI_APPIUM_STATUS)."
}

appium_text() {
  siri_appium_find "${1:?appium_text needs an accessibility id}" || return 1
  siri_appium_call GET "/session/$SIRI_APPIUM_SESSION_ID/element/$SIRI_APPIUM_ELEMENT_ID/text"
  if [ "$SIRI_APPIUM_STATUS" != 200 ]; then
    if siri_appium_element_error; then return 1; fi
    siri_helper_error appium_unavailable "Appium gave no element text (HTTP $SIRI_APPIUM_STATUS)."
  fi
  siri_appium_json text "$SIRI_APPIUM_TMP/response.json" || siri_helper_error appium_unavailable "Appium gave element text that is not a string."
}

# Status 0 when the element in SIRI_APPIUM_ELEMENT_ID shows on the screen.
# An element that is not shown, or that the app no longer has, gives 1.
siri_appium_on_screen() {
  local shown
  siri_appium_call GET "/session/$SIRI_APPIUM_SESSION_ID/element/$SIRI_APPIUM_ELEMENT_ID/displayed"
  if [ "$SIRI_APPIUM_STATUS" != 200 ]; then
    if siri_appium_element_error; then return 1; fi
    siri_helper_error appium_unavailable "Appium could not tell if an element is on screen (HTTP $SIRI_APPIUM_STATUS)."
  fi
  shown="$(siri_appium_json displayed "$SIRI_APPIUM_TMP/response.json")" || siri_helper_error appium_unavailable "Appium gave a displayed value that is not true or false."
  [ "$shown" = true ]
}

# siri_appium_swipe <down|up>: one slow drag on the middle of the window.
# down drags from 75% to 35% of the height, so the rows below come on
# screen. up drags the other way. The finger stops before it lifts, so the
# list does not keep moving after the drag.
siri_appium_swipe() {
  local size width height x from to
  siri_appium_call GET "/session/$SIRI_APPIUM_SESSION_ID/window/rect"
  [ "$SIRI_APPIUM_STATUS" = 200 ] || siri_helper_error appium_unavailable "Appium gave no window size (HTTP $SIRI_APPIUM_STATUS)."
  size="$(siri_appium_json rect "$SIRI_APPIUM_TMP/response.json")" || siri_helper_error appium_unavailable "Appium gave a window size that is not valid."
  width="${size% *}"
  height="${size#* }"
  x=$((width / 2))
  if [ "$1" = up ]; then
    from=$((height * 35 / 100))
    to=$((height * 75 / 100))
  else
    from=$((height * 75 / 100))
    to=$((height * 35 / 100))
  fi
  siri_appium_call POST "/session/$SIRI_APPIUM_SESSION_ID/actions" '{"actions":[{"type":"pointer","id":"finger1","parameters":{"pointerType":"touch"},"actions":[{"type":"pointerMove","duration":0,"x":'"$x"',"y":'"$from"'},{"type":"pointerDown","button":0},{"type":"pause","duration":200},{"type":"pointerMove","duration":800,"x":'"$x"',"y":'"$to"'},{"type":"pause","duration":200},{"type":"pointerUp","button":0}]}]}'
  [ "$SIRI_APPIUM_STATUS" = 200 ] || siri_helper_error appium_unavailable "Appium could not swipe (HTTP $SIRI_APPIUM_STATUS)."
}

# appium_scroll_to <accessibility_id> [max_swipes] [down|up]. A long list
# draws only the rows near the screen, so a row below the screen is not
# found until the list moves. Look up the element. When it is not found or
# not on screen, swipe once and look again. Return 0 when it is on screen
# (with no swipe if it already shows), else 1 after max_swipes swipes.
appium_scroll_to() {
  local id="${1:?appium_scroll_to needs an accessibility id}" max="${2:-10}" direction="${3:-down}" swipes=0
  case "$max" in
    [0-9]|[0-9][0-9]) ;;
    *) siri_helper_error check_block_crashed "appium_scroll_to: max_swipes must be a whole number from 0 to 50." ;;
  esac
  if [ "$max" -gt 50 ]; then
    siri_helper_error check_block_crashed "appium_scroll_to: max_swipes must be a whole number from 0 to 50."
  fi
  case "$direction" in
    down|up) ;;
    *) siri_helper_error check_block_crashed "appium_scroll_to: the direction must be down or up." ;;
  esac
  while :; do
    if siri_appium_find "$id" && siri_appium_on_screen; then return 0; fi
    if [ "$swipes" -ge "$max" ]; then break; fi
    siri_appium_swipe "$direction"
    swipes=$((swipes + 1))
  done
  printf 'appium_scroll_to: %s is not on screen after %s swipes %s.\n' "$id" "$swipes" "$direction" >&2
  return 1
}
