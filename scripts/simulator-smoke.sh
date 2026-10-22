#!/bin/bash
set -euo pipefail

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
phones.sort(key=lambda d: (not ('SE' in d['name']), d['name']))
print(phones[0]['udid'])
PY
)

cleanup() { xcrun simctl shutdown "$SIMULATOR_ID" >/dev/null 2>&1 || true; }
trap cleanup EXIT
xcrun simctl boot "$SIMULATOR_ID" || true
xcrun simctl bootstatus "$SIMULATOR_ID" -b
xcrun simctl status_bar "$SIMULATOR_ID" override --time '9:41' --dataNetwork wifi --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100
xcrun simctl install "$SIMULATOR_ID" DerivedData/Build/Products/Debug-iphonesimulator/ThreeDays.app
xcrun simctl launch --terminate-running-process "$SIMULATOR_ID" jp.local.threedays | tee ci-results/launch.txt
sleep 5
xcrun simctl io "$SIMULATOR_ID" screenshot ci-results/today.png
# launch.txt and the screenshot are evidence of a launch, not full interaction tests.
