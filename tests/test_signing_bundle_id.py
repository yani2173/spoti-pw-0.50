"""Signing profiles must produce concrete matching IDs, never literal wildcards."""
import importlib.util
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import zipfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("signing_bundle", Path(__file__).resolve().parents[1] / "scripts/signing-bundle-id.py")
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


def profile(identifier):
    return {"Entitlements": {"application-identifier": identifier}}


class SigningBundleTests(unittest.TestCase):
    def test_explicit_profile_uses_its_actual_bundle_id(self):
        self.assertEqual(signing.select_bundle_id(profile("TEAM.custom.spotify"), "com.spotify.client"), "custom.spotify")

    def test_wildcard_profiles_keep_a_matching_host_id(self):
        for identifier in ("TEAM.*", "TEAM.com.spotify.*"):
            self.assertEqual(signing.select_bundle_id(profile(identifier), "com.spotify.client"), "com.spotify.client")

    def test_mismatched_prefix_is_rejected_instead_of_signing_a_star(self):
        for bundle in ("com.other.spotify", "com.spotify", "com.spotify.", "com.spotifyX.client"):
            with self.subTest(bundle=bundle), self.assertRaises(ValueError):
                signing.select_bundle_id(profile("TEAM.com.spotify.*"), bundle)

    def test_missing_or_malformed_profiles_are_rejected(self):
        for value in (None, {}, {"Entitlements": []}, profile(""), profile("TEAM"),
                      profile(".com.spotify.client"), profile("TEAM.com.*.spotify"),
                      profile("TEAM.**"), profile("TEAM.com.spotify*"), profile("TEAM.com..spotify")):
            with self.subTest(value=value), self.assertRaises(ValueError):
                signing.select_bundle_id(value, "com.spotify.client")

    def test_wildcard_requires_a_concrete_host_id(self):
        for value in (None, "", "*", "com.spotify.*", "com..spotify", "com/spotify"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                signing.select_bundle_id(profile("TEAM.*"), value)


class InstallScriptTests(unittest.TestCase):
    def test_profile_selection_and_wifi_reach_signer_without_real_credentials(self):
        root = Path(__file__).resolve().parents[1]
        cases = (("TEAM.*", "0", 0), ("TEAM.com.spotify.*", "1", 0),
                 ("TEAM.custom.spotify", "0", 0), ("TEAM.other.*", "0", 1),
                 ("TEAM.*", "invalid", 1))
        for identifier, wifi, expected_error in cases:
            with self.subTest(profile=identifier, wifi=wifi), tempfile.TemporaryDirectory() as temp:
                folder = Path(temp)
                scripts, binaries = folder / "scripts", folder / "bin"
                scripts.mkdir()
                binaries.mkdir()
                for name in ("install.sh", "signing-bundle-id.py"):
                    shutil.copy(root / "scripts" / name, scripts / name)
                source = folder / "Spotify test.ipa"
                with zipfile.ZipFile(source, "w") as archive:
                    archive.writestr("Payload/Spotify.app/Info.plist", plistlib.dumps({"CFBundleIdentifier": "com.spotify.client"}))
                profile_path = folder / "profile.plist"
                profile_path.write_bytes(plistlib.dumps(profile(identifier)))
                (binaries / "security").write_text('#!/bin/sh\ncat "$TEST_PROFILE"\n')
                recorder = "#!/usr/bin/env python3\nimport json, os, sys\nfrom pathlib import Path\nPath(os.environ['TEST_LOG'] + Path(sys.argv[0]).name).write_text(json.dumps(sys.argv[1:]))\n"
                for name in ("zsign", "ideviceinstaller"):
                    (binaries / name).write_text(recorder)
                for binary in binaries.iterdir():
                    binary.chmod(0o755)
                environment = {**os.environ, "PATH": str(binaries) + os.pathsep + os.environ["PATH"],
                               "SIGN_P12": "test-only.p12", "SIGN_P12_PASSWORD": "test-only",
                               "SIGN_PROFILE": str(profile_path), "TEST_PROFILE": str(profile_path),
                               "TEST_LOG": str(folder / "calls-"), "TMPDIR": str(folder), "WIFI": wifi}
                result = subprocess.run(["bash", str(scripts / "install.sh"), str(source)], env=environment,
                                        capture_output=True, text=True)
                self.assertEqual(bool(result.returncode), bool(expected_error), result.stdout + result.stderr)
                signer_log = folder / "calls-zsign"
                if expected_error:
                    self.assertFalse(signer_log.exists())
                else:
                    args = json.loads(signer_log.read_text())
                    bundle = args[args.index("-b") + 1]
                    self.assertEqual(bundle, "custom.spotify" if identifier == "TEAM.custom.spotify" else "com.spotify.client")
                    self.assertEqual(args[-1], str(source))
                    self.assertTrue((folder / "calls-ideviceinstaller").exists(), result.stdout + result.stderr)
                    install = json.loads((folder / "calls-ideviceinstaller").read_text())
                    self.assertEqual("-n" in install, wifi == "1")
                self.assertFalse(list(folder.glob("tmp.*")), "decoded profile temporary file is cleaned up")


if __name__ == "__main__":
    unittest.main()
