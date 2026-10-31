import copy
import contextlib
import importlib.util
import io
import pathlib
import plistlib
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("cloud_profile", pathlib.Path(__file__).parents[1] / "cloud_profile.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class CloudProfileTests(unittest.TestCase):
    def profile(self):
        return {"Entitlements": {
            "application-identifier": "TEAM." + module.BUNDLE_ID,
            "com.apple.developer.icloud-container-identifiers": [module.CONTAINER],
            "com.apple.developer.icloud-services": ["CloudKit"],
            "com.apple.developer.icloud-container-environment": ["Development", "Production"],
            "aps-environment": "production",
        }}

    def test_accepts_production_profile_and_string_environment(self):
        profile = self.profile()
        self.assertTrue(module.supports_cloudkit(profile))
        profile["Entitlements"]["com.apple.developer.icloud-container-environment"] = "Production"
        self.assertTrue(module.supports_cloudkit(profile))

    def test_rejects_old_profile_wrong_container_and_development_push(self):
        for key, value in [
            ("com.apple.developer.icloud-container-identifiers", ["iCloud.other"]),
            ("com.apple.developer.icloud-services", ["CloudDocuments"]),
            ("com.apple.developer.icloud-container-environment", ["Development"]),
            ("aps-environment", "development"),
            ("application-identifier", "TEAM.some.other.app"),
        ]:
            with self.subTest(key=key):
                profile = self.profile(); profile["Entitlements"][key] = value
                self.assertFalse(module.supports_cloudkit(profile))
        self.assertFalse(module.supports_cloudkit({}))

    def test_missing_required_entitlement_never_passes(self):
        profile = self.profile()
        for key in profile["Entitlements"]:
            missing = copy.deepcopy(profile)
            missing["Entitlements"].pop(key)
            self.assertFalse(module.supports_cloudkit(missing))

    def test_accepts_apple_wildcard_service_grants(self):
        for services in ("*", ["*"], "CloudKit", ["CloudDocuments", "CloudKit"]):
            with self.subTest(services=services):
                profile = self.profile()
                profile["Entitlements"]["com.apple.developer.icloud-services"] = services
                self.assertTrue(module.supports_cloudkit(profile))

    def test_wildcard_services_still_require_container_and_production_permissions(self):
        for key in ("com.apple.developer.icloud-container-identifiers",
                    "com.apple.developer.icloud-container-environment", "aps-environment"):
            profile = self.profile()
            profile["Entitlements"]["com.apple.developer.icloud-services"] = "*"
            profile["Entitlements"].pop(key)
            self.assertFalse(module.supports_cloudkit(profile))

    def test_rejects_substring_matches_and_malformed_entitlements(self):
        for key, value in (
            ("com.apple.developer.icloud-services", "NotCloudKit"),
            ("com.apple.developer.icloud-services", {"CloudKit": True}),
            ("com.apple.developer.icloud-services", ["CloudKit", 1]),
            ("com.apple.developer.icloud-container-identifiers", module.CONTAINER + ".other"),
            ("com.apple.developer.icloud-container-environment", "NotProduction"),
            ("application-identifier", None),
        ):
            with self.subTest(key=key, value=value):
                profile = self.profile(); profile["Entitlements"][key] = value
                self.assertFalse(module.supports_cloudkit(profile))
        for profile in ([], {"Entitlements": None}, {"Entitlements": []}):
            self.assertFalse(module.supports_cloudkit(profile))

    def test_diagnostics_identify_missing_permission_without_exposing_profile(self):
        profile = self.profile()
        profile["Name"] = "private-profile-sentinel"
        profile["Entitlements"]["com.apple.developer.icloud-container-identifiers"] = ["private-container-sentinel"]
        with tempfile.TemporaryDirectory() as root:
            directory = pathlib.Path(root)
            (directory / "test.mobileprovision").touch()
            output = io.StringIO()
            with patch.object(module.subprocess, "run", return_value=SimpleNamespace(stdout=plistlib.dumps(profile))):
                with contextlib.redirect_stdout(output), self.assertRaises(SystemExit) as error:
                    module.main(directory)
            diagnostic = output.getvalue() + str(error.exception)
            self.assertIn("iCloud container=MISSING", diagnostic)
            self.assertIn("CloudKit service=OK", diagnostic)
            self.assertNotIn("private-profile-sentinel", diagnostic)
            self.assertNotIn("private-container-sentinel", diagnostic)
            self.assertTrue((directory / "test.mobileprovision").exists())

    def test_only_profiles_with_all_permissions_remain_for_signing(self):
        valid = self.profile()
        valid["Entitlements"]["com.apple.developer.icloud-services"] = "*"
        invalid = self.profile()
        invalid["Entitlements"]["aps-environment"] = "development"
        with tempfile.TemporaryDirectory() as root:
            directory = pathlib.Path(root) / "profiles"; directory.mkdir()
            for name in ("valid.mobileprovision", "invalid.mobileprovision"):
                (directory / name).touch()
            def decoded(command, **kwargs):
                value = valid if pathlib.Path(command[-1]).name == "valid.mobileprovision" else invalid
                return SimpleNamespace(stdout=plistlib.dumps(value))
            with patch.object(module.subprocess, "run", side_effect=decoded), contextlib.redirect_stdout(io.StringIO()):
                module.main(directory)
            self.assertEqual([p.name for p in directory.iterdir()], ["valid.mobileprovision"])
            self.assertTrue((directory.parent / "unused-profiles/invalid.mobileprovision").exists())

    def test_no_profiles_reports_download_problem(self):
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaisesRegex(SystemExit, "ダウンロード"):
                module.main(pathlib.Path(root))
