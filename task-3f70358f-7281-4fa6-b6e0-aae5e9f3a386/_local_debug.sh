#!/usr/bin/env bash
# Local only. Runs the empty and reference checks on an installed iOS runtime
# other than 26.3. Do not paste anything from /tmp/siri-debug into the platform.
set -u
VER="${1:-26.4}"
TASK="$(cd "$(dirname "$0")" && pwd)"
DBG=/tmp/siri-debug

rm -rf "$DBG" && mkdir -p "$DBG"
cp -R "$TASK/environment" "$TASK/tests" "$TASK/solution" "$DBG/"
sed -i '' "s/SIRI_PLATFORM_VERSION='26.3'/SIRI_PLATFORM_VERSION='$VER'/" "$DBG/environment/scripts/boot_simulator.sh"
sed -i '' "s/\"26\.3\")/\"$VER\")/g" "$DBG/tests/test.sh"

run() {
  local name="$1" ws="/tmp/flo-$1" logs="/tmp/logs-$1"
  rm -rf "$ws" "$logs" && cp -R "$DBG/environment" "$ws"
  if [ "$name" = ref ]; then WORKSPACE="$ws" bash "$DBG/solution/solve.sh" || return; fi
  WORKSPACE="$ws" LOGS_ROOT="$logs" bash "$DBG/tests/test.sh"
  echo "== $name: exit $?"
  rm -rf "$TASK/debug-logs-$name" && cp -R "$logs" "$TASK/debug-logs-$name"
  cat "$logs/verifier/failure.txt" "$logs/verifier/error.json" 2>/dev/null
}

run empty
run ref
