import sys
import unittest
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from release_config import build_number, validate_secrets


def pem(key):
    return key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                             serialization.NoEncryption()).decode()


class ReleaseConfigTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.api_key = pem(ec.generate_private_key(ec.SECP256R1()))
        cls.certificate_key = pem(rsa.generate_private_key(public_exponent=65537, key_size=2048))

    def config(self):
        return {
            "APP_STORE_CONNECT_ISSUER_ID": "11111111-2222-3333-4444-555555555555",
            "APP_STORE_CONNECT_KEY_IDENTIFIER": "ABC123DEF4",
            "APP_STORE_CONNECT_PRIVATE_KEY": self.api_key,
            "CERTIFICATE_PRIVATE_KEY": self.certificate_key,
        }

    def test_valid_signing_keys(self):
        validate_secrets(self.config())

    def test_missing_secrets_report_names(self):
        with self.assertRaisesRegex(ValueError, "APP_STORE_CONNECT_PRIVATE_KEY"):
            validate_secrets({})

    def test_swapped_keys_rejected(self):
        config = self.config()
        config["APP_STORE_CONNECT_PRIVATE_KEY"] = self.certificate_key
        with self.assertRaisesRegex(ValueError, "Apple"):
            validate_secrets(config)

    def test_malformed_key_never_appears_in_error(self):
        config = self.config()
        config["CERTIFICATE_PRIVATE_KEY"] = "sensitive-test-sentinel"
        with self.assertRaises(ValueError) as error:
            validate_secrets(config)
        self.assertNotIn("sensitive-test-sentinel", str(error.exception))
        self.assertIn("CERTIFICATE_PRIVATE_KEY", str(error.exception))

    def test_build_numbers_increase_across_reruns_and_run_boundaries(self):
        previous = (0, 0, 0)
        for run in (1, 2, 99, 100, 101, 999899, 999900):
            for attempt in (1, 2, 99):
                version = build_number(str(run), str(attempt))
                current = tuple(map(int, version.split(".")))
                self.assertGreater(current, previous)
                self.assertLessEqual(current[0], 9999)
                self.assertTrue(all(number <= 99 for number in current[1:]))
                previous = current

    def test_invalid_build_numbers_stop_upload(self):
        for run, attempt in ((0, 1), (1, 0), (1, 100), (999901, 1)):
            with self.assertRaises(ValueError):
                build_number(run, attempt)


if __name__ == "__main__":
    unittest.main()
