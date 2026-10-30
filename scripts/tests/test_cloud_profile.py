import copy
import importlib.util
import pathlib
import unittest

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
