#!/usr/bin/env bash
# tests/test.sh, simulator frame. The lines above the CHECK BLOCK line and the
# lines below the END OF CHECK BLOCK line are locked: the task checks compare
# them byte for byte. Write the checks only between those two lines.
set -euo pipefail
set -o errtrace

WORKSPACE="${WORKSPACE:-/workspace}"
LOGS_ROOT="${LOGS_ROOT:-/logs}"
REWARD="$LOGS_ROOT/verifier/reward.txt"
FAILURE="$LOGS_ROOT/verifier/failure.txt"
ERROR_FILE="$LOGS_ROOT/verifier/error.json"
ARTIFACTS="$LOGS_ROOT/artifacts/mobile"
export WORKSPACE LOGS_ROOT ARTIFACTS
mkdir -p "$LOGS_ROOT/verifier" "$ARTIFACTS"
rm -f "$REWARD" "$FAILURE" "$ERROR_FILE"

SIRI_CLEANUPS=''
SIRI_FAILED_AT=''
SIRI_SIGNAL=''
SIRI_IN_CHECK=''
# The verdict lives only in this shell: pass, fail or error, with its text,
# error code and phase. Only the EXIT trap writes the result files.
SIRI_VERDICT=''
SIRI_VERDICT_TEXT=''
SIRI_VERDICT_CODE=''
SIRI_VERDICT_PHASE=''
readonly SIRI_TOP_PID=$$

siri_error_kind() {
  case "$1" in
    toolchain_missing|device_type_missing|runtime_missing|state_file_missing|device_mismatch|simulator_not_booted|appium_unavailable|appium_port_in_use|wda_port_in_use|interrupted) printf 'environment' ;;
    missing_test_file|check_block_crashed|no_verdict|pass_in_subshell) printf 'verifier' ;;
    *) return 1 ;;
  esac
}

# One JSON string body: control characters become spaces, non-ASCII bytes
# become '?', the text is cut to 500 characters, and '\' and '"' are escaped.
siri_json_text() {
  local text
  text="$(printf '%s' "$1" | LC_ALL=C tr '\001-\037\177' ' ' | LC_ALL=C tr '\200-\377' '?')"
  text="${text:0:500}"
  printf '%s' "$text" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# siri_write_error <phase> <code> <message>. phase: frame or check.
siri_write_error() {
  local phase="$1" code="$2" message="$3" kind
  if ! kind="$(siri_error_kind "$code")"; then
    message="siri_error got an unknown code: $code. $message"
    code='check_block_crashed'
    kind='verifier'
  fi
  printf '{"kind":"%s","code":"%s","phase":"%s","message":"%s"}\n' "$kind" "$code" "$phase" "$(siri_json_text "$message")" > "$ERROR_FILE"
}

# True in the test.sh shell itself. False in a subshell, a pipeline or a
# $(...). bash 3.2 has no BASHPID, so ask a child sh for its parent.
siri_in_top_shell() {
  [ "$(exec sh -c 'printf "%s" "$PPID"')" = "$SIRI_TOP_PID" ]
}

# siri_record <verdict> <text> <code> <phase>. verdict: pass, fail or
# error. The first record wins. A subshell cannot set the variables of
# this shell, so it claims the private folder instead (mkdir is atomic).
# A claim holds only a fail or an error, so a subshell, or a program that
# the check runs, can make the result worse but never a pass.
siri_record() {
  if siri_in_top_shell; then
    if [ -z "$SIRI_VERDICT" ] && { [ -z "$SIRI_STATE" ] || [ ! -e "$SIRI_STATE/claim" ]; }; then
      SIRI_VERDICT="$1"
      SIRI_VERDICT_TEXT="$2"
      SIRI_VERDICT_CODE="$3"
      SIRI_VERDICT_PHASE="$4"
    fi
  elif [ -n "$SIRI_STATE" ] && mkdir "$SIRI_STATE/claim" 2>/dev/null; then
    printf '%s' "$1" > "$SIRI_STATE/claim/verdict"
    printf '%s' "$2" > "$SIRI_STATE/claim/text"
    printf '%s' "$3" > "$SIRI_STATE/claim/code"
    printf '%s' "$4" > "$SIRI_STATE/claim/phase"
  fi
}

# The answer is right: reward 1. Only a pass in the test.sh shell itself
# counts. A pass in a subshell, a pipeline or a $(...) is a task defect.
pass() {
  if siri_in_top_shell; then
    siri_record pass '' '' ''
    exit 0
  fi
  siri_raise check pass_in_subshell "pass ran in a subshell, a pipeline or a \$(...). Call pass only at the top level of the check block."
}

# The answer is wrong: the reason goes to failure.txt and the reward is 0.
# In the test.sh shell the exit status is 3. A subshell exits 0,
# and its claim holds the fail.
fail() {
  siri_record fail "${1:-The check failed.}" '' ''
  if siri_in_top_shell; then
    exit 3
  fi
  exit 0
}

# siri_raise <phase> <code> <message>
siri_raise() {
  set +e
  siri_record error "$3" "$2" "$1"
  exit 2
}

# The verifier cannot grade: an error record and no reward.
siri_error() {
  siri_raise check "${1:-}" "${2:-}"
}

# The frame prefix, the suffix and the helper source guard report errors
# with this function.
siri_frame_error() {
  siri_raise frame "${1:-}" "${2:-}"
}

# The locked helpers report errors with this function. A helper call from
# the check block gives phase check, and a call from the prefix gives frame.
siri_helper_error() {
  if [ "$SIRI_IN_CHECK" = 1 ]; then
    siri_raise check "${1:-}" "${2:-}"
  fi
  siri_raise frame "${1:-}" "${2:-}"
}

siri_require_file() {
  [ -f "${1:-}" ] || siri_helper_error missing_test_file "A file the check needs is missing: ${1:-}"
}

# siri_require_tool <tool> <probe command...>
siri_require_tool() {
  local tool="$1"
  shift
  command -v "$tool" >/dev/null 2>&1 || siri_helper_error toolchain_missing "$tool is not on PATH."
  "$@" >/dev/null 2>&1 || siri_helper_error toolchain_missing "$tool does not run: $*"
}

# Register a function to run when test.sh ends. The last one registered
# runs first. Each one runs in a subshell with errexit off.
siri_on_cleanup() {
  declare -F "${1:-}" >/dev/null || return 1
  SIRI_CLEANUPS="$1 $SIRI_CLEANUPS"
}

siri_run_cleanups() {
  local cleanup list="$SIRI_CLEANUPS"
  SIRI_CLEANUPS=''
  for cleanup in $list; do
    ( set +e; "$cleanup" ) || true
  done
}

# The frame is the only writer of the result files. It first deletes any
# copy that the check block or a program it ran wrote.
siri_write_verdict() {
  rm -rf "$REWARD" "$FAILURE" "$ERROR_FILE"
  mkdir -p "$LOGS_ROOT/verifier"
  case "$SIRI_VERDICT" in
    pass) printf '1\n' > "$REWARD" ;;
    fail)
      printf '%s\n' "$SIRI_VERDICT_TEXT" > "$FAILURE"
      printf '0\n' > "$REWARD"
      ;;
    *) siri_write_error "$SIRI_VERDICT_PHASE" "$SIRI_VERDICT_CODE" "$SIRI_VERDICT_TEXT" ;;
  esac
}

# Settle the verdict: the record of this shell, else the first claim of a
# subshell, else an error from the way test.sh ended. The files are written
# before the cleanups run, so a second signal during the cleanups does not
# lose them, and written again after, so a cleanup cannot change them. Then
# the exit status is set from the verdict: 0 pass,
# 3 fail, 2 error.
siri_on_exit() {
  local status=$?
  set +e
  trap - ERR
  if [ -z "$SIRI_VERDICT" ] && [ -n "$SIRI_STATE" ] && [ -d "$SIRI_STATE/claim" ]; then
    SIRI_VERDICT="$(cat "$SIRI_STATE/claim/verdict" 2>/dev/null)"
    SIRI_VERDICT_TEXT="$(cat "$SIRI_STATE/claim/text" 2>/dev/null)"
    SIRI_VERDICT_CODE="$(cat "$SIRI_STATE/claim/code" 2>/dev/null)"
    SIRI_VERDICT_PHASE="$(cat "$SIRI_STATE/claim/phase" 2>/dev/null)"
    case "$SIRI_VERDICT:$SIRI_VERDICT_PHASE" in
      fail:|error:frame|error:check) ;;
      *)
        SIRI_VERDICT=error
        SIRI_VERDICT_CODE=check_block_crashed
        SIRI_VERDICT_PHASE=frame
        SIRI_VERDICT_TEXT="A subshell left a verdict that is not complete."
        ;;
    esac
  fi
  if [ -z "$SIRI_VERDICT" ]; then
    SIRI_VERDICT=error
    SIRI_VERDICT_PHASE=frame
    if [ -n "$SIRI_SIGNAL" ]; then
      SIRI_VERDICT_CODE=interrupted
      SIRI_VERDICT_TEXT="test.sh got SIG$SIRI_SIGNAL before a verdict."
    elif [ "$status" -ne 0 ]; then
      SIRI_VERDICT_CODE=check_block_crashed
      SIRI_VERDICT_TEXT="test.sh stopped with status $status${SIRI_FAILED_AT:+ at $SIRI_FAILED_AT}."
    else
      SIRI_VERDICT_CODE=no_verdict
      SIRI_VERDICT_TEXT="The check block ended without pass or fail."
    fi
  fi
  siri_write_verdict
  siri_run_cleanups
  siri_write_verdict
  if [ -n "$SIRI_STATE" ]; then rm -rf "$SIRI_STATE"; fi
  # The exit status is the verdict, and it agrees with the result files.
  case "$SIRI_VERDICT" in
    pass) exit 0 ;;
    fail) exit 3 ;;
  esac
  exit 2
}

siri_on_signal() {
  SIRI_SIGNAL="$1"
  exit "$2"
}

siri_check_block_done() {
  siri_frame_error no_verdict "The check block ended without pass or fail."
}

SIRI_STATE=''
trap siri_on_exit EXIT
trap 'SIRI_FAILED_AT="line $LINENO: $BASH_COMMAND"' ERR
trap 'siri_on_signal HUP 129' HUP
trap 'siri_on_signal INT 130' INT
trap 'siri_on_signal TERM 143' TERM
SIRI_STATE="$(mktemp -d "${TMPDIR:-/tmp}/siri-verdict.XXXXXX")" || SIRI_STATE=''
readonly SIRI_STATE
[ -n "$SIRI_STATE" ] || siri_frame_error toolchain_missing "mktemp could not make the private verdict folder."

siri_require_tool xcodebuild xcodebuild -version
siri_require_tool xcrun xcrun --version
siri_require_tool xcrun xcrun --find simctl
siri_require_tool python3 python3 -c 'import json'

# State-file fallback for a run with no pre_agent boot. The boot script is
# idempotent, so it does not create a second simulator.
HARBOR_SIMULATOR_STATE_FILE="${HARBOR_SIMULATOR_STATE_FILE:-$LOGS_ROOT/artifacts/mobile/simulator-state.json}"
export HARBOR_SIMULATOR_STATE_FILE
if [ ! -s "$HARBOR_SIMULATOR_STATE_FILE" ]; then
  if [ ! -f "$WORKSPACE/scripts/boot_simulator.sh" ]; then
    siri_frame_error state_file_missing "No simulator state file and no scripts/boot_simulator.sh."
  fi
  SIRI_BOOT_STATUS=0
  bash "$WORKSPACE/scripts/boot_simulator.sh" || SIRI_BOOT_STATUS=$?
  case "$SIRI_BOOT_STATUS" in
    0) ;;
    10) siri_frame_error device_type_missing "boot_simulator.sh found no exact device type for the profile." ;;
    11) siri_frame_error runtime_missing "boot_simulator.sh found no exact runtime for the profile." ;;
    12) siri_frame_error toolchain_missing "boot_simulator.sh found no working xcrun, simctl or python3." ;;
    13) siri_frame_error device_mismatch "DEVICE_PROFILE, DEVICE_NAME or PLATFORM_VERSION differs from the boot script." ;;
    *) siri_frame_error state_file_missing "boot_simulator.sh stopped with status $SIRI_BOOT_STATUS." ;;
  esac
  [ -s "$HARBOR_SIMULATOR_STATE_FILE" ] || siri_frame_error state_file_missing "boot_simulator.sh wrote no state file."
fi

xcrun simctl list devicetypes -j > "$ARTIFACTS/simctl-devicetypes.json" 2>/dev/null || siri_frame_error toolchain_missing "xcrun simctl list devicetypes failed."
xcrun simctl list runtimes -j > "$ARTIFACTS/simctl-runtimes.json" 2>/dev/null || siri_frame_error toolchain_missing "xcrun simctl list runtimes failed."
xcrun simctl list devices -j > "$ARTIFACTS/simctl-devices.json" 2>/dev/null || siri_frame_error toolchain_missing "xcrun simctl list devices failed."

# Prints a result code and a message, then on 'ok' the UDID, profile,
# device type id, runtime id and the created flag. One value per line.
siri_simulator_check() {
  python3 - "$HARBOR_SIMULATOR_STATE_FILE" "$ARTIFACTS/simctl-devices.json" "$ARTIFACTS/simctl-devicetypes.json" "$ARTIFACTS/simctl-runtimes.json" "${DEVICE_PROFILE:-}" <<'PY'
import json
import re
import sys

PROFILES = {
    "ios26.3-iphone17pro": ("iPhone 17 Pro", "26.3"),
    "ios26.3-iphonese3": ("iPhone SE (3rd generation)", "26.3"),
    "ios26.3-ipadpro13-m4": ("iPad Pro 13-inch (M4)", "26.3"),
}
FIELDS = ('udid', 'created', 'profile', 'device_name', 'platform_version', 'device_type_id', 'runtime_id')


def finish(code, message, *values):
    for line in (code, message) + values:
        print(line)
    sys.exit(0)


def load(path):
    with open(path) as handle:
        return json.load(handle)


state_path, devices_path, types_path, runtimes_path, want_profile = sys.argv[1:6]
try:
    state = load(state_path)
except (OSError, ValueError):
    finish('state_file_missing', 'The simulator state file is not valid JSON.')
if not isinstance(state, dict):
    finish('state_file_missing', 'The simulator state file is not a JSON object.')
missing = [key for key in FIELDS if key not in state]
if missing:
    finish('state_file_missing', 'The simulator state file lacks: ' + ', '.join(missing) + '.')
if not isinstance(state['created'], bool) or not all(isinstance(state[key], str) for key in FIELDS if key != 'created'):
    finish('state_file_missing', 'The simulator state file has a field of the wrong type.')
if not re.match(r'^[0-9A-Fa-f-]{36}$', state['udid']):
    finish('state_file_missing', 'The simulator state file UDID is not a UDID.')
profile = state['profile']
if profile not in PROFILES:
    finish('device_mismatch', 'The state file profile is not a simulator profile: ' + profile)
if want_profile and want_profile != profile:
    finish('device_mismatch', 'The state file profile ' + profile + ' differs from DEVICE_PROFILE ' + want_profile + '.')
name, version = PROFILES[profile]
if state['device_name'] != name or state['platform_version'] != version:
    finish('device_mismatch', 'The state file device name or platform version differs from profile ' + profile + '.')
try:
    devices = load(devices_path).get('devices') or {}
    types = load(types_path).get('devicetypes') or []
    runtimes = load(runtimes_path).get('runtimes') or []
except (OSError, ValueError, AttributeError):
    finish('toolchain_missing', 'xcrun simctl list gave output that is not valid JSON.')
type_names = dict((item.get('identifier'), item.get('name')) for item in types if isinstance(item, dict))
if state['device_type_id'] not in type_names:
    finish('device_type_missing', 'The state file device type is not installed: ' + state['device_type_id'])
if type_names[state['device_type_id']] != name:
    finish('device_mismatch', 'The state file device type is not named ' + name + '.')
runtime = None
for item in runtimes:
    if isinstance(item, dict) and item.get('identifier') == state['runtime_id']:
        runtime = item
if runtime is None or runtime.get('isAvailable') is not True:
    finish('runtime_missing', 'The state file runtime is not installed or not available: ' + state['runtime_id'])
if runtime.get('name') != 'iOS ' + version:
    finish('device_mismatch', 'The state file runtime is not named iOS ' + version + '.')
found = None
for runtime_id, items in devices.items():
    for item in items if isinstance(items, list) else []:
        if isinstance(item, dict) and item.get('udid') == state['udid']:
            found = (runtime_id, item)
if found is None:
    finish('device_mismatch', 'The state file UDID is not a known simulator: ' + state['udid'])
if found[0] != state['runtime_id'] or found[1].get('deviceTypeIdentifier') != state['device_type_id']:
    finish('device_mismatch', 'Simulator ' + state['udid'] + ' has a different device type or runtime than the state file.')
if found[1].get('state') != 'Booted':
    finish('simulator_not_booted', 'Simulator ' + state['udid'] + ' is not Booted.')
finish('ok', '', state['udid'], profile, state['device_type_id'], state['runtime_id'], 'true' if state['created'] else 'false')
PY
}

SIRI_SIM_CHECK="$(siri_simulator_check)" || siri_frame_error toolchain_missing "python3 failed while it checked the simulator state."
siri_sim_line() {
  printf '%s\n' "$SIRI_SIM_CHECK" | sed -n "$1p"
}
if [ "$(siri_sim_line 1)" != ok ]; then
  siri_frame_error "$(siri_sim_line 1)" "$(siri_sim_line 2)"
fi
UDID="$(siri_sim_line 3)"
SIM_PROFILE="$(siri_sim_line 4)"
SIM_DEVICE_TYPE_ID="$(siri_sim_line 5)"
SIM_RUNTIME_ID="$(siri_sim_line 6)"
SIM_CREATED="$(siri_sim_line 7)"
export UDID SIM_PROFILE SIM_DEVICE_TYPE_ID SIM_RUNTIME_ID SIM_CREATED

# Delete a simulator this run created. Never delete a reused one (cn 6.4).
# Set SIRI_KEEP_SIMULATOR=1 to keep it for a local debug run.
siri_simulator_cleanup() {
  [ "$SIM_CREATED" = true ] || return 0
  [ "${SIRI_KEEP_SIMULATOR:-0}" != 1 ] || return 0
  xcrun simctl shutdown "$UDID" >/dev/null 2>&1
  xcrun simctl delete "$UDID" >/dev/null 2>&1
}
siri_on_cleanup siri_simulator_cleanup

# Helpers: pass, fail "<reason>", siri_error <code> "<message>",
# siri_require_file <path>, siri_require_tool <tool> <command...>,
# siri_on_cleanup <function>. Paths: $WORKSPACE, $LOGS_ROOT, $ARTIFACTS.
# Call pass only at the top level of the check block. A fail or siri_error
# in a subshell or a pipe also counts. The first verdict wins.
# The check block runs in a function. Bash reads all of it first, so a
# syntax error is a verifier error. 'declare' and 'local' make names that
# the cleanups see, but a 'return' in the check block deletes them.
# Exit status: 0 pass, 3 fail, 2 verifier error.
# Simulator: $UDID, $SIM_PROFILE, $SIM_DEVICE_TYPE_ID, $SIM_RUNTIME_ID.
# Guard each check whose failure means a wrong answer: cmd || fail "...".
# A command that fails with no guard is a verifier error, not a reward of 0.
readonly SIRI_IN_CHECK=1
siri_check_block() {
# ---- CHECK BLOCK: write the checks below this line ----
. "$(dirname "$0")/appium_wda.sh"

PROJECT="$WORKSPACE/flo.xcodeproj"
SCHEME="flo"
BUNDLE_ID="com.penerbangwalet.flo"
DERIVED="$(mktemp -d "${TMPDIR:-/tmp}/flo-derived.XXXXXX")"

xcodebuild build \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$DERIVED" \
  -skipMacroValidation \
  -skipPackagePluginValidation \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  > "$ARTIFACTS/xcodebuild.log" 2>&1 \
  || fail "The app does not build. See xcodebuild.log."

APP="$DERIVED/Build/Products/Debug-iphonesimulator/flo.app"
[ -d "$APP" ] || fail "The build finished but flo.app is not in the products folder."

xcrun simctl install "$UDID" "$APP" || siri_error check_block_crashed "simctl could not install flo.app."

# Start from a state where all three experimental settings are changed.
DATA_DIR="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)" \
  || siri_error check_block_crashed "simctl gave no data container for $BUNDLE_ID."
mkdir -p "$DATA_DIR/Library/Preferences"
python3 - "$DATA_DIR/Library/Preferences/$BUNDLE_ID.plist" <<'PY' \
  || siri_error check_block_crashed "Could not write the starting preferences."
import plistlib, sys
with open(sys.argv[1], "wb") as f:
    plistlib.dump({"enableDebug": True, "libraryViewV2": True, "enableMaxBitRate": "320"}, f)
PY

xcrun simctl launch "$UDID" "$BUNDLE_ID" > /dev/null \
  || siri_error check_block_crashed "simctl could not launch $BUNDLE_ID."

appium_session "$BUNDLE_ID"
appium_page_source launch.xml
appium_screenshot launch.png

# Is a tab with this name in the tab bar right now?
tab_shown() {
  appium_page_source tabs.xml
  python3 - "$ARTIFACTS/tabs.xml" "$1" <<'PY'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
for bar in root.iter("XCUIElementTypeTabBar"):
    for el in bar.iter():
        if el.get("name") == sys.argv[2] or el.get("label") == sys.argv[2]:
            sys.exit(0)
sys.exit(1)
PY
}

wait_tab() {
  local name="$1" want="$2" i=0
  while [ "$i" -lt 10 ]; do
    if tab_shown "$name"; then
      [ "$want" = shown ] && return 0
    else
      [ "$want" = gone ] && return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

switch_off() {
  appium_page_source switches.xml
  python3 - "$ARTIFACTS/switches.xml" "$1" <<'PY'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
for el in root.iter():
    if el.get("name") == sys.argv[2]:
        sys.exit(0 if el.get("value") == "0" else 1)
sys.exit(1)
PY
}

# The Preferences tab button is named "Preferences" at first, but after the
# tab bar is drawn again it takes the name of its icon, "gear".
tap_preferences() {
  appium_tap Preferences || appium_tap gear
}

# The list can be scrolled anywhere after the tab bar changes, so look both ways.
find_row() {
  appium_scroll_to "$1" 15 down || appium_scroll_to "$1" 15 up
}

wait_tab Debug shown || fail "With Enable Debug on at launch, the Debug tab is not shown."
wait_tab Search shown || fail "With Library View V2 on at launch, the Search tab is not shown."

tap_preferences || fail "The Preferences tab could not be tapped."
find_row resetExperimentalButton || fail "No element resetExperimentalButton in Preferences."
appium_tap resetExperimentalButton || fail "resetExperimentalButton could not be tapped."

wait_tab Debug gone || fail "After the reset, the Debug tab is still shown."
wait_tab Search gone || fail "After the reset, the Search tab (Library View V2) is still shown."
wait_tab Downloads shown || fail "After the reset, the Downloads tab of the classic layout is not shown."

find_row enableDebugToggle || fail "No element enableDebugToggle in Preferences."
switch_off enableDebugToggle || fail "After the reset, the Enable Debug switch is not off."
find_row libraryViewV2Toggle || fail "No element libraryViewV2Toggle in Preferences."
switch_off libraryViewV2Toggle || fail "After the reset, the Library View V2 switch is not off."

# Relaunch and check that the reset stayed.
xcrun simctl terminate "$UDID" "$BUNDLE_ID" \
  || siri_error check_block_crashed "simctl could not stop $BUNDLE_ID."
xcrun simctl launch "$UDID" "$BUNDLE_ID" > /dev/null \
  || siri_error check_block_crashed "simctl could not launch $BUNDLE_ID again."

wait_tab Downloads shown || fail "After a relaunch, the classic tab layout is not shown."
wait_tab Debug gone || fail "After a relaunch, the Debug tab is back."
wait_tab Search gone || fail "After a relaunch, the Search tab is back."

tap_preferences || fail "After a relaunch, the Preferences tab could not be tapped."
find_row maxBitratePicker || fail "No element maxBitratePicker in Preferences."
appium_page_source bitrate.xml
python3 - "$ARTIFACTS/bitrate.xml" <<'PY' || fail "After the reset and a relaunch, Max Bitrate does not show Source."
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
for el in root.iter():
    if el.get("name") == "maxBitratePicker":
        words = " ".join((n.get("label") or "") + " " + (n.get("value") or "") for n in el.iter())
        sys.exit(0 if "Source" in words and "320" not in words else 1)
sys.exit(1)
PY

appium_screenshot relaunch.png
pass
# ---- END OF CHECK BLOCK: do not edit below this line ----
siri_check_block_done
}
siri_check_block
siri_check_block_done
