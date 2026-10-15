"""Checks for official kit preparation. Run: python3 -m unittest discover -s tests -v."""
import hashlib
import importlib.util
import json
import plistlib
import struct
import tempfile
import unittest
import zipfile
import warnings
from pathlib import Path
from test_official_pipeline import dylib_command, executable

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("official_kit", ROOT / "scripts/prepare-official-kit.py")
kit_builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(kit_builder)


class OfficialKitTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.folder = Path(self.temporary.name)
        self.ipa = self.folder / "spotify.ipa"
        self.kit = self.folder / "kit.zip"
        self.app = "Payload/Spotify.app/"
        self.info = {
            "CFBundleIdentifier": "com.spotify.client",
            "CFBundleExecutable": "Spotify",
            "CFBundleShortVersionString": "9.1.78",
            "CFBundleVersion": "91780000",
            "UIDesignRequiresCompatibility": True,
            "NSBonjourServices": ["_existing._tcp", "_spotify-connect._tcp"],
            "NSLocalNetworkUsageDescription": "Existing description",
        }
        self.extension = "PlugIns/SpotifyGlassLiveActivity.appex/Info.plist"
        self.payload = {
            "files/Frameworks/spotifyglass.dylib": b"test dylib",
            "files/Frameworks/SpotifyGlassAppGroups.dylib": b"test shim",
            "files/" + self.extension: plistlib.dumps({
                "CFBundleIdentifier": "HOST_BUNDLE_ID.liveactivity",
                "CFBundleShortVersionString": "HOST_SHORT_VERSION",
                "CFBundleVersion": "HOST_VERSION",
            }),
        }
        self.manifest = {
            "format": 1, "version": "0.51.0", "spotify": "9.1.90", "spotifyVersions": ["9.1.90", "9.1.78"],
            "infoPlist": {
                "set": {"UIDesignRequiresCompatibility": False, "MusicHapticsSupported": True},
                "union": {"NSBonjourServices": ["_spotify-connect._tcp", "_googlecast._tcp"]},
                "default": {"NSLocalNetworkUsageDescription": "Default description"},
            },
            "templates": [self.extension],
            "integrity": {name: hashlib.sha256(body).hexdigest() for name, body in self.payload.items()},
        }
        self.write_ipa()
        self.write_kit()

    def write_ipa(self, extras=None, binary=None):
        with zipfile.ZipFile(self.ipa, "w") as archive:
            archive.writestr(self.app + "Info.plist", plistlib.dumps(self.info, fmt=plistlib.FMT_BINARY))
            archive.writestr(self.app + "Spotify", executable() if binary is None else binary)
            for name, contents in (extras or {}).items():
                archive.writestr(name, contents)

    def write_kit(self):
        with zipfile.ZipFile(self.kit, "w") as archive:
            archive.writestr("kit.json", json.dumps(self.manifest))
            for name, contents in self.payload.items():
                entry = zipfile.ZipInfo(name)
                entry.create_system = 3
                entry.external_attr = 0o100755 << 16
                archive.writestr(entry, contents)

    def prepare(self):
        return kit_builder.prepare(self.ipa, self.kit, self.folder / "prepared")

    def test_plist_operations_preserve_existing_values_and_apply_release_requirements(self):
        original = self.ipa.read_bytes()
        self.assertEqual(self.prepare(), self.app)
        host = plistlib.loads((self.folder / "prepared/host.plist").read_bytes())
        self.assertFalse(host["UIDesignRequiresCompatibility"])
        self.assertTrue(host["MusicHapticsSupported"])
        self.assertEqual(host["NSBonjourServices"], ["_existing._tcp", "_spotify-connect._tcp", "_googlecast._tcp"])
        self.assertEqual(host["NSLocalNetworkUsageDescription"], "Existing description")
        self.assertEqual(self.ipa.read_bytes(), original)

    def test_extension_uses_actual_host_identity_and_versions(self):
        self.prepare()
        extension = plistlib.loads((self.folder / "prepared/files" / self.extension).read_bytes())
        self.assertEqual(extension["CFBundleIdentifier"], "com.spotify.client.liveactivity")
        self.assertEqual(extension["CFBundleShortVersionString"], "9.1.78")
        self.assertEqual(extension["CFBundleVersion"], "91780000")
        self.assertEqual((self.folder / "prepared/files/Frameworks/spotifyglass.dylib").read_bytes(), b"test dylib")
        self.assertEqual((self.folder / "prepared/files/Frameworks/spotifyglass.dylib").stat().st_mode & 0o777, 0o755)

    def test_default_network_description_is_used_only_when_missing(self):
        del self.info["NSLocalNetworkUsageDescription"]
        self.write_ipa()
        self.prepare()
        host = plistlib.loads((self.folder / "prepared/host.plist").read_bytes())
        self.assertEqual(host["NSLocalNetworkUsageDescription"], "Default description")

    def test_other_spotify_versions_are_rejected(self):
        self.info["CFBundleShortVersionString"] = "9.2.0"
        self.write_ipa()
        with self.assertRaisesRegex(ValueError, "requires Spotify 9.1.90 or 9.1.78"):
            self.prepare()

    def test_new_spotify_version_and_extension_versions_are_supported(self):
        self.info["CFBundleShortVersionString"] = "9.1.90"
        self.info["CFBundleVersion"] = "91900000"
        self.write_ipa()
        self.prepare()
        extension = plistlib.loads((self.folder / "prepared/files" / self.extension).read_bytes())
        self.assertEqual(extension["CFBundleShortVersionString"], "9.1.90")
        self.assertEqual(extension["CFBundleVersion"], "91900000")

    def test_previous_performance_addon_is_rejected(self):
        self.write_ipa({self.app + "Frameworks/SGPerformance050.dylib": b"old addon"})
        with self.assertRaisesRegex(ValueError, "clean decrypted"):
            self.prepare()

    def test_existing_mod_is_rejected(self):
        self.write_ipa({self.app + "Frameworks/spotifyglass.dylib": b"old mod"})
        with self.assertRaisesRegex(ValueError, "clean decrypted"):
            self.prepare()

    def test_existing_performance_addon_is_rejected(self):
        self.write_ipa({self.app + "Frameworks/SGPerformance051.dylib": b"old addon"})
        with self.assertRaisesRegex(ValueError, "clean decrypted"):
            self.prepare()

    def test_removed_mod_files_with_remaining_load_commands_are_rejected(self):
        for path in ("@rpath/spotifyglass.dylib", "@executable_path/Frameworks/SGPerformance051.dylib"):
            with self.subTest(path=path):
                self.write_ipa(binary=executable([dylib_command(path)]))
                with self.assertRaisesRegex(ValueError, "clean decrypted"):
                    self.prepare()
                self.assertFalse((self.folder / "prepared").exists())

    def test_duplicate_archive_members_are_rejected(self):
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(self.ipa, "a") as archive:
                archive.writestr(self.app + "Spotify", executable())
        with self.assertRaisesRegex(ValueError, "duplicate file"):
            self.prepare()
        self.assertFalse((self.folder / "prepared").exists())

    def test_encrypted_ipa_is_rejected_before_extraction(self):
        self.write_ipa(binary=executable([struct.pack("<IIIIII", 0x2C, 24, 4096, 4, 1, 0)]))
        with self.assertRaisesRegex(ValueError, "encrypted.*decrypted IPA"):
            self.prepare()
        self.assertFalse((self.folder / "prepared").exists())

    def test_multiple_payload_apps_are_rejected(self):
        self.write_ipa({"Payload/Other.app/Info.plist": plistlib.dumps(self.info)})
        with self.assertRaisesRegex(ValueError, "exactly one"):
            self.prepare()

    def test_missing_main_executable_is_rejected(self):
        self.info["CFBundleExecutable"] = "Missing"
        self.write_ipa()
        with self.assertRaisesRegex(ValueError, "valid main executable"):
            self.prepare()

    def test_tampered_kit_payload_is_rejected_before_extraction(self):
        self.payload["files/Frameworks/spotifyglass.dylib"] = b"modified dylib"
        self.write_kit()
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            self.prepare()
        self.assertFalse((self.folder / "prepared").exists())

    def test_another_release_is_rejected(self):
        self.manifest["version"] = "0.52.0"
        self.write_kit()
        with self.assertRaisesRegex(ValueError, "version 0.51.0"):
            self.prepare()

    def test_archive_checksum_is_checked(self):
        expected = hashlib.sha256(self.kit.read_bytes()).hexdigest()
        kit_builder.verify_download(self.kit, expected)
        with self.assertRaisesRegex(ValueError, "checksum does not match"):
            kit_builder.verify_download(self.kit)


if __name__ == "__main__":
    unittest.main()
