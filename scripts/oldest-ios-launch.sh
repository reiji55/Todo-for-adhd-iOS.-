#!/bin/bash
# Launches the simulator build on the oldest iOS this runner has (the app supports iOS 17), to catch a crash
# that only older systems have. Prints the crash report, with the exception's reason, when the app dies.
set -uo pipefail
cd "$(dirname "$0")/.."

# The app supports iOS 17; testers still use it. Install the iOS 17 simulator when the runner lacks one.
if ! xcrun simctl list runtimes | grep -q 'iOS 17'; then
  echo "Installing the iOS 17.5 simulator"
  xcodebuild -downloadPlatform iOS -buildVersion 17.5 2>&1 | tail -3 || echo "::warning::Could not install the iOS 17.5 simulator"
fi

read -r RUNTIME VERSION < <(xcrun simctl list runtimes --json | python3 -c '
import json, sys
runtimes = [r for r in json.load(sys.stdin)["runtimes"] if r.get("platform") == "iOS" and r.get("isAvailable")]
runtimes.sort(key=lambda r: [int(x) for x in r["version"].split(".")])
print(runtimes[0]["identifier"], runtimes[0]["version"]) if runtimes else print("", "")
')
if [ -z "$RUNTIME" ]; then echo "::warning::No iOS runtime found"; exit 0; fi
echo "Oldest iOS runtime: $VERSION"

DEVICE_TYPE=$(xcrun simctl list devicetypes --json | python3 -c '
import json, sys
names = [d["identifier"] for d in json.load(sys.stdin)["devicetypes"]]
for wanted in ("iPhone-SE-3rd-generation", "iPhone-15", "iPhone-14"):
    match = [n for n in names if n.endswith(wanted)]
    if match:
        print(match[0]); break
')
SIMULATOR_ID=$(xcrun simctl create "Horme oldest iOS" "$DEVICE_TYPE" "$RUNTIME") || { echo "::warning::Could not create a device on iOS $VERSION"; exit 0; }
cleanup() { xcrun simctl shutdown "$SIMULATOR_ID" >/dev/null 2>&1 || true; xcrun simctl delete "$SIMULATOR_ID" >/dev/null 2>&1 || true; }
trap cleanup EXIT
xcrun simctl boot "$SIMULATOR_ID"
xcrun simctl bootstatus "$SIMULATOR_ID" -b
xcrun simctl install "$SIMULATOR_ID" DerivedData/Build/Products/Debug-iphonesimulator/ThreeDays.app

REPORTS="$HOME/Library/Logs/DiagnosticReports"
status=0
for arguments in "" "-uiScenario task" "-uiScenario timetable -uiTab 1"; do
  before=$(date +%s)
  # shellcheck disable=SC2086
  xcrun simctl launch --terminate-running-process "$SIMULATOR_ID" io.github.reiji55.threedays \
    -AppleLanguages '(ja)' -AppleLocale ja_JP $arguments >/dev/null
  sleep 20
  mkdir -p ci-results
  xcrun simctl io "$SIMULATOR_ID" screenshot "ci-results/oldest-ios-${arguments// /_}.png" >/dev/null 2>&1 || true
  if ! xcrun simctl spawn "$SIMULATOR_ID" launchctl list 2>/dev/null | grep -q 'io.github.reiji55.threedays'; then
    echo "::warning::The app was not listed as running on iOS $VERSION (launch arguments: '${arguments}')"
  fi
  for report in $(find "$REPORTS" -name 'ThreeDays*' -newermt "@$before" 2>/dev/null); do
    echo "::error::Crash on iOS $VERSION (launch arguments: '${arguments}'): $report"
    python3 - "$report" <<'PY'
import json, sys
text = open(sys.argv[1]).read()
head, _, body = text.partition("\n")
try:
    report = json.loads(body)
except ValueError:
    print(text[:6000]); sys.exit()
print("exception:", json.dumps(report.get("exception")))
for key in ("asi", "lastExceptionBacktrace"):
    if report.get(key):
        value = report[key]
        if key == "lastExceptionBacktrace":
            images = report.get("usedImages", [])
            for frame in value[:30]:
                image = images[frame["imageIndex"]]["name"] if frame.get("imageIndex", -1) < len(images) else "?"
                print("  ", image, frame.get("symbol", ""), frame.get("sourceFile", ""), frame.get("sourceLine", ""))
        else:
            print(key, json.dumps(value)[:3000])
PY
    status=1
  done
done
exit $status
