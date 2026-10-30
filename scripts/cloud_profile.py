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


def supports_cloudkit(profile):
    entitlements = profile.get("Entitlements", {})
    environment = entitlements.get("com.apple.developer.icloud-container-environment", [])
    if isinstance(environment, str):
        environment = [environment]
    return (
        entitlements.get("application-identifier", "").endswith("." + BUNDLE_ID)
        and CONTAINER in entitlements.get("com.apple.developer.icloud-container-identifiers", [])
        and "CloudKit" in entitlements.get("com.apple.developer.icloud-services", [])
        and "Production" in environment
        and entitlements.get("aps-environment") == "production"
    )


def main(directory):
    paths = sorted(directory.glob("*.mobileprovision"))
    valid, unused = [], []
    for path in paths:
        result = subprocess.run(
            ["openssl", "smime", "-inform", "der", "-verify", "-noverify", "-in", str(path)],
            capture_output=True, check=True,
        )
        profile = plistlib.loads(result.stdout)
        (valid if supports_cloudkit(profile) else unused).append(path)
    if not valid:
        raise SystemExit(
            "::error::HormeのiCloud・CloudKit・Push Notificationsに対応した配布プロファイルがありません。"
            "Apple Developerでio.github.reiji55.threedaysにiCloud.io.github.reiji55.threedaysを関連付けて保存してください。"
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
