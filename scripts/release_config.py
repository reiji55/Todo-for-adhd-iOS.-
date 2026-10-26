"""Validate signing inputs without logging their values."""

import os
import plistlib
import re
import sys
import uuid
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa


REQUIRED_SECRETS = (
    "APP_STORE_CONNECT_ISSUER_ID",
    "APP_STORE_CONNECT_KEY_IDENTIFIER",
    "APP_STORE_CONNECT_PRIVATE_KEY",
    "CERTIFICATE_PRIVATE_KEY",
)


def validate_secrets(environ):
    missing = [name for name in REQUIRED_SECRETS if not environ.get(name, "").strip()]
    if missing:
        raise ValueError("GitHub Repository Secretsに追加してください: " + ", ".join(missing))
    try:
        uuid.UUID(environ["APP_STORE_CONNECT_ISSUER_ID"])
    except ValueError:
        raise ValueError("APP_STORE_CONNECT_ISSUER_IDはチームAPIキーのIssuer IDを指定してください") from None
    if not re.fullmatch(r"[A-Z0-9]{10}", environ["APP_STORE_CONNECT_KEY_IDENTIFIER"]):
        raise ValueError("APP_STORE_CONNECT_KEY_IDENTIFIERは10文字のKey IDを指定してください")
    for name in REQUIRED_SECRETS[2:]:
        try:
            key = serialization.load_pem_private_key(environ[name].encode(), password=None)
        except (ValueError, TypeError):
            raise ValueError(name + "には、BEGINからENDまで改行を含む秘密鍵の全文を指定してください") from None
        if name == "APP_STORE_CONNECT_PRIVATE_KEY":
            if not isinstance(key, ec.EllipticCurvePrivateKey) or not isinstance(key.curve, ec.SECP256R1):
                raise ValueError(name + "にはAppleから取得した.p8キーを指定してください")
        elif not isinstance(key, rsa.RSAPrivateKey) or key.key_size < 2048:
            raise ValueError(name + "には2048ビット以上のRSA秘密鍵を指定してください")


def build_number(run_number, run_attempt):
    """Stay within Apple's 4.2.2 digit limit; reruns receive a new version."""
    run = int(run_number)
    attempt = int(run_attempt)
    if not 1 <= run <= 999900 or not 1 <= attempt <= 99:
        raise ValueError("GitHubの実行番号・再実行回数がビルド番号の範囲を超えています")
    return f"{(run - 1) // 100 + 1}.{(run - 1) % 100}.{attempt}"


def prepare_project(project_path, version):
    with project_path.open("rb") as handle:
        project = plistlib.load(handle)
    for item in project["objects"].values():
        settings = item.get("buildSettings", {})
        if "PRODUCT_BUNDLE_IDENTIFIER" in settings:
            if settings["PRODUCT_BUNDLE_IDENTIFIER"] != "io.github.reiji55.threedays":
                raise ValueError("プロジェクトのBundle IDが配布設定と一致していません")
            settings["CURRENT_PROJECT_VERSION"] = version
    with project_path.open("wb") as handle:
        plistlib.dump(project, handle, sort_keys=False)


def main():
    try:
        validate_secrets(os.environ)
        version = build_number(os.environ["GITHUB_RUN_NUMBER"], os.environ["GITHUB_RUN_ATTEMPT"])
        prepare_project(Path("ThreeDays.xcodeproj/project.pbxproj"), version)
    except (ValueError, KeyError) as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1
    print(version)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
