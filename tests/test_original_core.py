"""Checks that an IPA cannot silently replace or alter the original release core."""
import importlib.util
import json
import plistlib
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path
from test_official_pipeline import dylib_command, executable

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("original_core", ROOT / "scripts/verify-official-build.py")
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


class OriginalCoreTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.folder = Path(self.temporary.name)
        self.ipa, self.kit = self.folder / "test.ipa", self.folder / "kit.zip"
        self.core = bytes(executable())
        with zipfile.ZipFile(self.kit, "w") as kit:
            kit.writestr("kit.json", json.dumps({"version": "0.51.0"}))
            kit.writestr("files/Frameworks/spotifyglass.dylib", self.core)

    def write_ipa(self, core=None, addon=False, loads=None):
        if loads is None:
            loads = ["@rpath/SpotifyGlassAppGroups.dylib", "@rpath/spotifyglass.dylib"]
            if addon:
                loads.append("@rpath/SGPerformance051.dylib")
        with zipfile.ZipFile(self.ipa, "w") as built:
            built.writestr("Payload/Spotify.app/Info.plist", plistlib.dumps({"CFBundleExecutable": "Spotify"}))
            built.writestr("Payload/Spotify.app/Spotify", executable([dylib_command(path) for path in loads]))
            built.writestr("Payload/Spotify.app/Frameworks/SpotifyGlassAppGroups.dylib", self.core)
            built.writestr("Payload/Spotify.app/Frameworks/spotifyglass.dylib", self.core if core is None else core)
            if addon:
                built.writestr("Payload/Spotify.app/Frameworks/SGPerformance051.dylib", b"fixture addon")

    def test_original_sections_are_accepted(self):
        self.write_ipa()
        verifier.verify(self.ipa, self.kit)

    def test_modified_instructions_are_rejected(self):
        changed = bytearray(self.core)
        changed[4096] ^= 1
        self.write_ipa(changed)
        with self.assertRaisesRegex(ValueError, "does not preserve"):
            verifier.verify(self.ipa, self.kit)

    def test_source_replacement_is_rejected(self):
        self.write_ipa(b"a differently built source dylib")
        with self.assertRaisesRegex(ValueError, "Mach-O"):
            verifier.verify(self.ipa, self.kit)

    def test_malformed_core_tables_are_rejected_with_bounded_reads(self):
        inputs = [self.core[:40]]
        for location, value in ((16, 1000), (20, 8), (36, 8), (96, 1000)):
            data = bytearray(self.core)
            struct.pack_into("<I", data, location, value)
            inputs.append(data)
        for data in inputs:
            with self.subTest(size=len(data)), self.assertRaises(ValueError):
                verifier.sections(data)

    def test_optimized_mode_requires_an_addon(self):
        self.write_ipa()
        with self.assertRaisesRegex(ValueError, "missing its performance"):
            verifier.verify(self.ipa, self.kit, optimized=True)
        self.write_ipa(addon=True)
        verifier.verify(self.ipa, self.kit, optimized=True)

    def test_copying_addon_without_loading_it_is_rejected(self):
        self.write_ipa(addon=True, loads=["@rpath/SpotifyGlassAppGroups.dylib", "@rpath/spotifyglass.dylib"])
        with self.assertRaisesRegex(ValueError, "does not load all"):
            verifier.verify(self.ipa, self.kit, optimized=True)

    def test_loading_addon_before_original_core_is_rejected(self):
        self.write_ipa(addon=True, loads=["@rpath/SpotifyGlassAppGroups.dylib",
                                        "@rpath/SGPerformance051.dylib", "@rpath/spotifyglass.dylib"])
        with self.assertRaisesRegex(ValueError, "must load after"):
            verifier.verify(self.ipa, self.kit, optimized=True)

    def test_missing_original_core_load_is_rejected(self):
        self.write_ipa(loads=["@rpath/SpotifyGlassAppGroups.dylib"])
        with self.assertRaisesRegex(ValueError, "does not load all"):
            verifier.verify(self.ipa, self.kit)


if __name__ == "__main__":
    unittest.main()
