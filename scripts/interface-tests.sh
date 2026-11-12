#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p ci-results

# Add a UI-only target to the disposable CI checkout. Shipping project/signing settings stay unchanged.
ruby <<'RUBY'
require 'xcodeproj'
project = Xcodeproj::Project.open('ThreeDays.xcodeproj')
app = project.targets.find { |t| t.name == 'ThreeDays' }
target = project.new_target(:ui_test_bundle, 'HormeUITests', :ios, '17.0')
target.add_dependency(app)
group = project.main_group.new_group('UITests', 'UITests')
target.add_file_references([group.new_file('HormeUITests.swift')])
target.build_configurations.each do |config|
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'io.github.reiji55.threedays.uitests'
  config.build_settings['PRODUCT_NAME'] = '$(TARGET_NAME)'
  config.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  config.build_settings['SWIFT_VERSION'] = '5.0'
  config.build_settings['TEST_TARGET_NAME'] = 'ThreeDays'
  config.build_settings['TARGETED_DEVICE_FAMILY'] = '1,2'
end
project.save
scheme_path = 'ThreeDays.xcodeproj/xcshareddata/xcschemes/ThreeDays.xcscheme'
scheme = Xcodeproj::XCScheme.new(scheme_path)
scheme.add_test_target(target)
scheme.save_as('ThreeDays.xcodeproj', 'ThreeDays', true)
RUBY

BASE_SIMULATOR=$(xcrun simctl list devices available --json | python3 -c '
import json,sys
devices=[d for k,v in json.load(sys.stdin)["devices"].items() if ".iOS-" in k for d in v if d.get("isAvailable") and "iPhone" in d["name"]]
devices.sort(key=lambda d:("SE" not in d["name"],d["name"]))
print(devices[0]["udid"])
')
# HORME_UI_IOS=17 runs the tests on an iOS 17 simulator (installed by the launch check) instead.
OLD_RUNTIME=""
if [[ -n "${HORME_UI_IOS:-}" ]]; then
  OLD_RUNTIME=$(xcrun simctl list runtimes --json | python3 -c "
import json,sys
r=[r for r in json.load(sys.stdin)['runtimes'] if r.get('platform')=='iOS' and r.get('isAvailable') and r['version'].startswith('${HORME_UI_IOS}.')]
print(r[0]['identifier'] if r else '')")
fi
if [[ -n "$OLD_RUNTIME" ]]; then
  echo "Interface tests on $OLD_RUNTIME"
  SIMULATOR_ID=$(xcrun simctl create 'Horme Interface Tests' com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation "$OLD_RUNTIME")
else
  SIMULATOR_ID=$(xcrun simctl clone "$BASE_SIMULATOR" 'Horme Interface Tests')
fi
cleanup() {
  if [[ -d ci-results/InterfaceTests.xcresult ]]; then
    xcrun xcresulttool get test-results summary --path ci-results/InterfaceTests.xcresult \
      > ci-results/interface-summary.json || true
    xcrun xcresulttool export attachments --path ci-results/InterfaceTests.xcresult \
      --output-path ci-results/interface-screens || true
  fi
  xcrun simctl shutdown "$SIMULATOR_ID" >/dev/null 2>&1 || true
  xcrun simctl delete "$SIMULATOR_ID" >/dev/null 2>&1 || true
}
trap cleanup EXIT
xcodebuild -project ThreeDays.xcodeproj -scheme ThreeDays -configuration Debug \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath DerivedData -resultBundlePath ci-results/InterfaceTests.xcresult \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 180 -maximum-test-execution-time-allowance 240 \
  CODE_SIGNING_ALLOWED=NO test
