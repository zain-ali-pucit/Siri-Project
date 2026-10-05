#!/usr/bin/env bash
# environment/scripts/boot_simulator.sh for device profile ios26.3-iphone17pro.
# Generated and locked: the task checks compare this file byte for byte.
# Exit status: 0 booted, 10 no exact device type, 11 no exact runtime,
# 12 xcrun, simctl or python3 does not work, 13 the requested
# profile differs from this script, 1 any other failure.
set -euo pipefail

SIRI_PROFILE='ios26.3-iphone17pro'
SIRI_DEVICE_NAME='iPhone 17 Pro'
SIRI_PLATFORM_VERSION='26.3'

WORKSPACE="${WORKSPACE:-/workspace}"
LOGS_ROOT="${LOGS_ROOT:-/logs}"
DEVICE_PROFILE="${DEVICE_PROFILE:-$SIRI_PROFILE}"
DEVICE_NAME="${DEVICE_NAME:-$SIRI_DEVICE_NAME}"
PLATFORM_VERSION="${PLATFORM_VERSION:-$SIRI_PLATFORM_VERSION}"
HARBOR_SIMULATOR_STATE_FILE="${HARBOR_SIMULATOR_STATE_FILE:-$LOGS_ROOT/artifacts/mobile/simulator-state.json}"
ARTIFACTS="$LOGS_ROOT/artifacts/mobile"
SIRI_RUN_TAG="${SIRI_RUN_TAG:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
export WORKSPACE LOGS_ROOT DEVICE_PROFILE DEVICE_NAME PLATFORM_VERSION HARBOR_SIMULATOR_STATE_FILE

die() {
  local status="$1"
  shift
  printf 'boot_simulator.sh: %s\n' "$*" >&2
  exit "$status"
}

siri_boot_py() {
  python3 - "$@" <<'PY'
import json
import os
import sys


def stop(status, message):
    sys.stderr.write('boot_simulator.sh: ' + message + '\n')
    sys.exit(status)


def load(path, key, empty):
    with open(path) as handle:
        doc = json.load(handle)
    value = doc.get(key) if isinstance(doc, dict) else None
    return value if isinstance(value, type(empty)) else empty


def resolve(types_path, runtimes_path, name, version):
    types = [item for item in load(types_path, 'devicetypes', [])
             if isinstance(item, dict) and item.get('name') == name]
    if len(types) != 1 or not isinstance(types[0].get('identifier'), str):
        stop(10, 'Found %d device types named %r. Need exactly one. No substitute is used.' % (len(types), name))
    type_id = types[0]['identifier']
    runtime_name = 'iOS ' + version
    runtimes = [item for item in load(runtimes_path, 'runtimes', [])
                if isinstance(item, dict) and item.get('name') == runtime_name and item.get('isAvailable') is True]
    if len(runtimes) != 1 or not isinstance(runtimes[0].get('identifier'), str):
        stop(11, 'Found %d available runtimes named %r. Need exactly one. No substitute is used.' % (len(runtimes), runtime_name))
    runtime = runtimes[0]
    supported = runtime.get('supportedDeviceTypes')
    if isinstance(supported, list) and supported:
        if type_id not in [item.get('identifier') for item in supported if isinstance(item, dict)]:
            stop(10, 'Runtime %r does not support device type %r.' % (runtime_name, name))
    print(type_id)
    print(runtime['identifier'])


def pick(devices_path, state_path, profile, name, version, type_id, runtime_id):
    devices = load(devices_path, 'devices', {}).get(runtime_id)
    usable = [item for item in (devices if isinstance(devices, list) else [])
              if isinstance(item, dict) and isinstance(item.get('udid'), str)
              and item.get('deviceTypeIdentifier') == type_id and item.get('isAvailable') is True]
    try:
        with open(state_path) as handle:
            state = json.load(handle)
    except (OSError, ValueError):
        state = None
    if (isinstance(state, dict) and state.get('udid') in [item['udid'] for item in usable]
            and state.get('profile') == profile and state.get('device_name') == name
            and state.get('platform_version') == version and state.get('device_type_id') == type_id
            and state.get('runtime_id') == runtime_id):
        print(state['udid'])
        print('true' if state.get('created') is True else 'false')
        return
    usable.sort(key=lambda item: (item.get('state') != 'Booted', item.get('name') != name))
    if usable:
        print(usable[0]['udid'])
        print('false')
    else:
        print('')
        print('true')


def write_state(path, udid, created, profile, name, version, type_id, runtime_id):
    state = {
        'udid': udid,
        'created': created == 'true',
        'profile': profile,
        'device_name': name,
        'platform_version': version,
        'device_type_id': type_id,
        'runtime_id': runtime_id,
    }
    temp = path + '.tmp'
    with open(temp, 'w') as handle:
        json.dump(state, handle, indent=2)
        handle.write('\n')
    os.replace(temp, path)


def device_state(devices_path, udid):
    for items in load(devices_path, 'devices', {}).values():
        for item in items if isinstance(items, list) else []:
            if isinstance(item, dict) and item.get('udid') == udid:
                print(item.get('state') or '')
                return
    print('')


OPS = {'resolve': resolve, 'pick': pick, 'write_state': write_state, 'device_state': device_state}
try:
    OPS[sys.argv[1]](*sys.argv[2:])
except ValueError:
    stop(12, 'simctl gave output that is not valid JSON.')
except OSError as error:
    stop(1, 'A file could not be read or written: ' + str(error.filename))
PY
}

siri_line() {
  printf '%s\n' "$1" | sed -n "$2p"
}

[ "$DEVICE_PROFILE" = "$SIRI_PROFILE" ] || die 13 "DEVICE_PROFILE is $DEVICE_PROFILE, but this script boots $SIRI_PROFILE."
[ "$DEVICE_NAME" = "$SIRI_DEVICE_NAME" ] || die 13 "DEVICE_NAME is $DEVICE_NAME, but profile $SIRI_PROFILE needs $SIRI_DEVICE_NAME."
[ "$PLATFORM_VERSION" = "$SIRI_PLATFORM_VERSION" ] || die 13 "PLATFORM_VERSION is $PLATFORM_VERSION, but profile $SIRI_PROFILE needs $SIRI_PLATFORM_VERSION."
command -v xcrun >/dev/null 2>&1 || die 12 "xcrun is not on PATH."
command -v python3 >/dev/null 2>&1 || die 12 "python3 is not on PATH."

mkdir -p "$ARTIFACTS" "$(dirname "$HARBOR_SIMULATOR_STATE_FILE")"
xcrun simctl list devicetypes -j > "$ARTIFACTS/simctl-devicetypes.json" || die 12 "xcrun simctl list devicetypes failed."
xcrun simctl list runtimes -j > "$ARTIFACTS/simctl-runtimes.json" || die 12 "xcrun simctl list runtimes failed."
xcrun simctl list devices -j > "$ARTIFACTS/simctl-devices.json" || die 12 "xcrun simctl list devices failed."

RESOLVED="$(siri_boot_py resolve "$ARTIFACTS/simctl-devicetypes.json" "$ARTIFACTS/simctl-runtimes.json" "$DEVICE_NAME" "$PLATFORM_VERSION")" || exit "$?"
DEVICE_TYPE_ID="$(siri_line "$RESOLVED" 1)"
RUNTIME_ID="$(siri_line "$RESOLVED" 2)"

# Reuse the state-file simulator when it is still valid for this profile,
# else an exact match. Else create one tagged with this run.
PICKED="$(siri_boot_py pick "$ARTIFACTS/simctl-devices.json" "$HARBOR_SIMULATOR_STATE_FILE" "$DEVICE_PROFILE" "$DEVICE_NAME" "$PLATFORM_VERSION" "$DEVICE_TYPE_ID" "$RUNTIME_ID")" || exit "$?"
UDID="$(siri_line "$PICKED" 1)"
CREATED="$(siri_line "$PICKED" 2)"
if [ -z "$UDID" ]; then
  UDID="$(xcrun simctl create "siri-$DEVICE_PROFILE-$SIRI_RUN_TAG" "$DEVICE_TYPE_ID" "$RUNTIME_ID")" || die 1 "xcrun simctl create failed."
  [ -n "$UDID" ] || die 1 "xcrun simctl create printed no UDID."
  CREATED=true
  xcrun simctl list devices -j > "$ARTIFACTS/simctl-devices.json" || die 12 "xcrun simctl list devices failed."
fi

# Write the state file before the boot, so a failed boot still records a
# simulator that this run created.
siri_boot_py write_state "$HARBOR_SIMULATOR_STATE_FILE" "$UDID" "$CREATED" "$DEVICE_PROFILE" "$DEVICE_NAME" "$PLATFORM_VERSION" "$DEVICE_TYPE_ID" "$RUNTIME_ID"

if [ "$(siri_boot_py device_state "$ARTIFACTS/simctl-devices.json" "$UDID")" = Shutdown ]; then
  xcrun simctl boot "$UDID" || die 1 "xcrun simctl boot failed for $UDID."
fi
xcrun simctl bootstatus "$UDID" -b || die 1 "xcrun simctl bootstatus failed for $UDID."
xcrun simctl list devices -j > "$ARTIFACTS/simctl-devices.json" || die 12 "xcrun simctl list devices failed."
printf 'boot_simulator.sh: %s is booted (profile %s, created %s).\n' "$UDID" "$DEVICE_PROFILE" "$CREATED"
