#!/bin/bash
set -euo pipefail
umask 077

# No shell tracing: signing keys are supplied only through GitHub Secrets.
cd "$(dirname "$0")/.."
RELEASE_VERSION=$(python3 scripts/release_config.py)
BUNDLE_ID=io.github.reiji55.threedays
RELEASE_DIR=$(mktemp -d "${RUNNER_TEMP:-/tmp}/threedays-release.XXXXXX")
SIGNING_KEYCHAIN="$RELEASE_DIR/signing.keychain-db"
export APP_STORE_CONNECT_DISABLE_JWT_CACHE=true

cleanup() {
  if [[ -f "$SIGNING_KEYCHAIN" ]]; then
    keychain delete --path "$SIGNING_KEYCHAIN" >/dev/null 2>&1 || true
  fi
  if [[ -f "$RELEASE_DIR/installed-profiles.txt" ]]; then
    while IFS= read -r profile; do rm -f "$profile"; done < "$RELEASE_DIR/installed-profiles.txt"
  fi
  rm -rf "$RELEASE_DIR"
}
trap cleanup EXIT

xcodebuild -version
SDK_MAJOR=$(xcrun --sdk iphoneos --show-sdk-version | cut -d. -f1)
if [[ "$SDK_MAJOR" -lt 26 ]]; then
  echo '::error::AppleへのアップロードにはiOS SDK 26以降が必要です。'
  exit 1
fi

# Confirm the manually created App Store Connect app before changing signing assets.
app-store-connect apps list --bundle-id-identifier "$BUNDLE_ID" \
  --strict-match-identifier --json > "$RELEASE_DIR/apps.json"
python3 - "$RELEASE_DIR/apps.json" <<'PY'
import json, sys
apps = json.load(open(sys.argv[1]))
if not isinstance(apps, list) or len(apps) != 1:
    raise SystemExit('::error::App Store Connectでio.github.reiji55.threedaysのアプリを先に作成してください。docs/TESTFLIGHT.mdを参照。')
PY

# The same RSA key is reused, so uploads do not create a new certificate each time.
app-store-connect fetch-signing-files "$BUNDLE_ID" \
  --type IOS_APP_STORE --strict-match-identifier --create \
  --certificates-dir "$RELEASE_DIR/certificates" \
  --profiles-dir "$RELEASE_DIR/profiles"
python3 scripts/cloud_profile.py "$RELEASE_DIR/profiles"
# Xcode searches its standard profile directory during archive/export.
python3 - "$RELEASE_DIR" <<'PY'
import pathlib, shutil, sys
from codemagic.models.provisioning_profile import ProvisioningProfile
directory = pathlib.Path(sys.argv[1])
destination = ProvisioningProfile.DEFAULT_LOCATION
destination.mkdir(parents=True, exist_ok=True)
with (directory / 'installed-profiles.txt').open('w') as installed:
    for source in (directory / 'profiles').glob('*.mobileprovision'):
        profile = ProvisioningProfile.from_path(source)
        target = destination / (profile.uuid + '.mobileprovision')
        if target.exists():
            raise SystemExit('::error::使い捨てランナーに同名のプロファイルが既に存在します。')
        shutil.copyfile(source, target)
        installed.write(str(target) + '\n')
PY
keychain initialize --path "$SIGNING_KEYCHAIN"
keychain add-certificates --path "$SIGNING_KEYCHAIN" \
  --certificate "$RELEASE_DIR/certificates/*.p12"
xcode-project use-profiles --project ThreeDays.xcodeproj \
  --profile "$RELEASE_DIR/profiles/*.mobileprovision" \
  --archive-method app-store \
  --export-options-plist "$RELEASE_DIR/ExportOptions.plist" \
  --custom-export-options '{"manageAppVersionAndBuildNumber":false}'
# The CLI models the older 'app-store' name; use Xcode's current export method.
python3 - "$RELEASE_DIR/ExportOptions.plist" <<'PY'
import pathlib, plistlib, sys
path = pathlib.Path(sys.argv[1])
options = plistlib.loads(path.read_bytes())
if not options.get('teamID') or 'io.github.reiji55.threedays' not in options.get('provisioningProfiles', {}):
    raise SystemExit('::error::アプリに対応する署名設定を生成できませんでした。')
options.update(method='app-store-connect', destination='export')
path.write_bytes(plistlib.dumps(options))
PY

xcodebuild -project ThreeDays.xcodeproj -scheme ThreeDays \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$RELEASE_DIR/ThreeDays.xcarchive" \
  -derivedDataPath "$RELEASE_DIR/DerivedData" archive
xcodebuild -exportArchive -archivePath "$RELEASE_DIR/ThreeDays.xcarchive" \
  -exportPath "$RELEASE_DIR/export" \
  -exportOptionsPlist "$RELEASE_DIR/ExportOptions.plist"

# Upload for internal testing. Review submissions and tester invitations are
# separate actions; the CLI's --testflight flag requests EXTERNAL beta review.
app-store-connect publish --path "$RELEASE_DIR/export/*.ipa" --enable-package-validation
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  cat >> "$GITHUB_STEP_SUMMARY" <<EOF
Appleへのアップロードが完了しました（ビルド ${RELEASE_VERSION}）。

[App Store Connect](https://appstoreconnect.apple.com/apps)で処理完了を待ち、
対象アプリのTestFlightから内部テストのグループに自分を追加してください。
署名済みIPAや秘密鍵はGitHubのArtifactsに保存していません。
EOF
fi
