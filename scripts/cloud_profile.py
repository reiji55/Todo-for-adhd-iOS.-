"""Select only profiles that actually authorize Horme's production iCloud sync.

This reads downloaded public provisioning metadata, never prints its contents,
and never revokes existing signing assets on Apple's servers.
"""
import pathlib
import plistlib
import subprocess
import sys

CONTAINER = "iCloud.io.github.reiji55.threedays"
BUNDLE_ID = "io.github.reiji55.threedays"


def string_values(value):
    if isinstance(value, str):
        return [value]
    if isinstance(value, list) and all(isinstance(item, str) for item in value):
        return value
    return []


def profile_checks(profile):
    entitlements = profile.get("Entitlements", {}) if isinstance(profile, dict) else {}
    if not isinstance(entitlements, dict):
        entitlements = {}
    identifier = entitlements.get("application-identifier", "")
    services = string_values(entitlements.get("com.apple.developer.icloud-services"))
    # Apple's TN2415 shows a profile granting all iCloud services as <string>*</string>.
    # This is permission to sign the app with CloudKit, not a missing capability.
    # https://developer.apple.com/library/archive/technotes/tn2415/_index.html
    return {
        "App ID": isinstance(identifier, str) and identifier.endswith("." + BUNDLE_ID),
        "iCloud container": CONTAINER in string_values(entitlements.get("com.apple.developer.icloud-container-identifiers")),
        "CloudKit service": "CloudKit" in services or "*" in services,
        "iCloud Production": "Production" in string_values(entitlements.get("com.apple.developer.icloud-container-environment")),
        "Push production": entitlements.get("aps-environment") == "production",
    }


def supports_cloudkit(profile):
    return all(profile_checks(profile).values())


def main(directory):
    paths = sorted(directory.glob("*.mobileprovision"))
    if not paths:
        raise SystemExit("::error::配布プロファイルがダウンロードされていません。直前の署名ファイル取得の結果を確認してください。")
    valid, unused = [], []
    for index, path in enumerate(paths, start=1):
        result = subprocess.run(
            ["openssl", "smime", "-inform", "der", "-verify", "-noverify", "-in", str(path)],
            capture_output=True, check=True,
        )
        profile = plistlib.loads(result.stdout)
        checks = profile_checks(profile)
        # Only fixed labels and booleans: never log profile contents, identities or key material.
        print(f"Profile {index}: " + "; ".join(f"{label}={'OK' if passed else 'MISSING'}" for label, passed in checks.items()))
        if checks["CloudKit service"]:
            services = string_values(profile["Entitlements"].get("com.apple.developer.icloud-services"))
            print("CloudKit service grant: " + ("all services (*)" if "*" in services else "CloudKit"))
        (valid if all(checks.values()) else unused).append(path)
    if not valid:
        raise SystemExit(
            "::error::HormeのiCloud・CloudKit・Push Notificationsに対応した配布プロファイルがありません。"
            "上のProfile行でMISSINGになった項目を確認してください。"
            "iCloud containerならApp IDにiCloud.io.github.reiji55.threedaysを関連付け、CloudKit serviceならInclude CloudKit supportを有効にしてください。"
            "Push productionならPush Notificationsを有効にして保存してください。"
            "設定済みなら配布プロファイルを再生成してください。手順: docs/ICLOUD-SHARING.md"
        )
    if unused:
        destination = directory.parent / "unused-profiles"
        destination.mkdir(exist_ok=True)
        for path in unused:
            path.rename(destination / path.name)
    print("Verified production CloudKit container, CloudKit service, and silent-push entitlements")


if __name__ == "__main__":
    try:
        main(pathlib.Path(sys.argv[1]))
    except (subprocess.SubprocessError, ValueError, OSError):
        raise SystemExit("::error::配布プロファイルのiCloud設定を検証できませんでした。")
