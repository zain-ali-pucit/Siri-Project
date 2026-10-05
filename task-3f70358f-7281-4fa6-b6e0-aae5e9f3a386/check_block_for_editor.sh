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
