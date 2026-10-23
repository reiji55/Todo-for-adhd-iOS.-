#!/bin/bash
set -euo pipefail

BUNDLE_ID=io.github.reiji55.threedays
mkdir -p ci-results
xcrun simctl list devices available --json > ci-results/simulators.json
SIMULATOR_ID=$(python3 - <<'PY'
import json
with open('ci-results/simulators.json') as f:
    groups = json.load(f)['devices']
phones = [d for runtime, devices in groups.items() if '.iOS-' in runtime
          for d in devices if d.get('isAvailable') and 'iPhone' in d['name']]
if not phones:
    raise SystemExit('No available iPhone simulator runtime')
# A standard-size Pro model shows the layout most people will see.
phones.sort(key=lambda d: (not (' Pro' in d['name'] and 'Max' not in d['name']), d['name']))
print(phones[0]['udid'])
PY
)

cleanup() { xcrun simctl shutdown "$SIMULATOR_ID" >/dev/null 2>&1 || true; }
trap cleanup EXIT
xcrun simctl boot "$SIMULATOR_ID" || true
xcrun simctl bootstatus "$SIMULATOR_ID" -b
xcrun simctl status_bar "$SIMULATOR_ID" override --time '9:41' --dataNetwork wifi --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100
xcrun simctl install "$SIMULATOR_ID" DerivedData/Build/Products/Debug-iphonesimulator/ThreeDays.app
xcrun simctl launch --terminate-running-process "$SIMULATOR_ID" "$BUNDLE_ID" | tee ci-results/launch.txt
sleep 5
xcrun simctl io "$SIMULATOR_ID" screenshot ci-results/00-first-launch.png

# Sample data lives in a temporary folder (-uiDemo is Debug-only), so these runs never touch saved data.
shoot() {
  local name=$1; shift
  xcrun simctl launch --terminate-running-process "$SIMULATOR_ID" "$BUNDLE_ID" -uiDemo "$@" >/dev/null
  sleep 4
  xcrun simctl io "$SIMULATOR_ID" screenshot "ci-results/$name.png"
}
shoot 01-today
shoot 02-all -uiTab 1
shoot 03-ideas -uiTab 2
shoot 04-focus -uiOpen focus
shoot 05-editor -uiOpen editor
shoot 06-settings -uiOpen settings
xcrun simctl ui "$SIMULATOR_ID" appearance dark
shoot 07-today-dark
xcrun simctl ui "$SIMULATOR_ID" appearance light
# These are evidence of launches and layouts, not full interaction tests.
