"""Optional real-tool packaging check using the official kit and synthetic Mach-O executables.

Set SG_OFFICIAL_KIT to the downloaded release ZIP and put cyan and ldid on PATH, then run unittest.
This checks packaging and ad-hoc signing, not installing Spotify or running it on an iPhone.
"""
import hashlib
import json
import itertools
import os
import plistlib
import shutil
import struct
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
KIT = os.environ.get("SG_OFFICIAL_KIT")
ADDON = os.environ.get("SG_PERFORMANCE_DYLIB")
APP = "Payload/Spotify.app/"


def dylib_command(path):
    name = path.encode() + b"\0"
    size = (24 + len(name) + 7) & ~7
    return struct.pack("<IIIIII", 0xC, size, 24, 0, 0, 0) + name + b"\0" * (size - 24 - len(name))


def executable(extra_commands=()):
    def segment(name, addr, offset, size, sections=b""):
        return struct.pack("<II16sQQQQiiII", 0x19, 72 + len(sections), name, addr, 8192,
                           offset, size, 7, 5, len(sections) // 80, 0) + sections
    base = 0x100000000
    section = struct.pack("<16s16sQQIIIIIIII", b"__text", b"__TEXT", base + 4096, 4,
                          4096, 2, 0, 0, 0x80000400, 0, 0, 0)
    commands = [segment(b"__TEXT", base, 0, 8192, section),
                segment(b"__LINKEDIT", base + 8192, 8192, 1),
                struct.pack("<IIIIII", 0x32, 24, 2, 0x100100, 0x1A0000, 0),
                struct.pack("<IIQQ", 0x80000028, 24, 4096, 0),
                struct.pack("<IIIIII", 2, 24, 8192, 0, 8192, 1), *extra_commands]
    header = struct.pack("<IiiIIIII", 0xFEEDFACF, 0x100000C, 0, 2, len(commands),
                         sum(map(len, commands)), 0x200085, 0)
    data = bytearray(header + b"".join(commands))
    data.extend(b"\0" * (8193 - len(data)))
    data[4096:4100] = bytes.fromhex("c0035fd6")  # arm64 ret; never executed by this test
    return data


def write_executable(archive, name):
    member = zipfile.ZipInfo(name)
    member.create_system = 3
    member.external_attr = 0o100755 << 16
    archive.writestr(member, executable())


def inspect(data):
    magic, _, _, _, count, _, _, _ = struct.unpack_from("<IiiIIIII", data)
    assert magic == 0xFEEDFACF
    offset, loads, text, signed = 32, [], None, False
    for _ in range(count):
        command, size = struct.unpack_from("<II", data, offset)
        if (command & 0x7FFFFFFF) in (0xC, 0x18, 0x1F):
            name = struct.unpack_from("<I", data, offset + 8)[0]
            loads.append(data[offset + name:offset + size].split(b"\0")[0].decode())
        if command == 0x19:
            sections = struct.unpack_from("<I", data, offset + 64)[0]
            for i in range(sections):
                entry = offset + 72 + i * 80
                if data[entry:entry + 16].rstrip(b"\0") == b"__text":
                    length = struct.unpack_from("<Q", data, entry + 40)[0]
                    start = struct.unpack_from("<I", data, entry + 48)[0]
                    text = data[start:start + length]
        if command == 0x1D:
            start, length = struct.unpack_from("<II", data, offset + 8)
            signed = length > 0 and start + length <= len(data)
        offset += size
    return loads, text, signed


@unittest.skipUnless(KIT and shutil.which("cyan") and shutil.which("ldid"),
                     "set SG_OFFICIAL_KIT and install cyan/ldid for the real-tool packaging check")
class OfficialPipelineTests(unittest.TestCase):
    def test_real_release_packaging_with_and_without_spotify_widget(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder)
            host = {"CFBundleIdentifier": "com.spotify.client", "CFBundleExecutable": "Spotify",
                    "CFBundleShortVersionString": "9.1.90", "CFBundleVersion": "91900000",
                    "CFBundleName": "Spotify", "MinimumOSVersion": "16.1"}
            modes = (False, True) if ADDON else (False,)
            for version, with_widget, optimized in itertools.product(("9.1.90", "9.1.78"), (True, False), modes):
                with self.subTest(version=version, widget=with_widget, optimized=optimized):
                    host["CFBundleShortVersionString"] = version
                    host["CFBundleVersion"] = "91900000" if version == "9.1.90" else "91780000"
                    source, output = folder / "decrypted fixture.ipa", folder / "result.ipa"
                    with zipfile.ZipFile(source, "w") as archive:
                        archive.writestr(APP + "Info.plist", plistlib.dumps(host))
                        write_executable(archive, APP + "Spotify")
                        archive.writestr(APP + "Metadata.appintents/extract.actionsdata", json.dumps({"actions": {"ExistingIntent": {}}}))
                        archive.writestr(APP + "Watch/Watch.app/unused", b"watch placeholder")
                        if with_widget:
                            widget = APP + "PlugIns/WidgetExtension.appex/"
                            archive.writestr(widget + "Info.plist", plistlib.dumps({**host, "CFBundleExecutable": "WidgetExtension"}))
                            write_executable(archive, widget + "WidgetExtension")
                    original = source.read_bytes()
                    result = subprocess.run([str(ROOT / "scripts/official-release.sh"), str(source), str(output)],
                                            capture_output=True, text=True,
                                            env={**os.environ, "SG_OPTIMIZE": str(int(optimized))})
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual(source.read_bytes(), original)
                    with zipfile.ZipFile(KIT) as kit, zipfile.ZipFile(output) as built:
                        manifest = json.loads(kit.read("kit.json"))
                        loads, _, signed = inspect(built.read(APP + "Spotify"))
                        self.assertTrue(signed)
                        self.assertTrue((built.getinfo(APP + "Spotify").external_attr >> 16) & 0o111)
                        for name in manifest["load"][0]["dylibs"]:
                            self.assertIn(name, loads)
                        if optimized:
                            addon_path = "@rpath/SGPerformance051.dylib"
                            self.assertEqual(loads.count(addon_path), 1)
                            self.assertLess(loads.index("@rpath/spotifyglass.dylib"), loads.index(addon_path))
                            _, before, _ = inspect(Path(ADDON).read_bytes())
                            member = APP + "Frameworks/SGPerformance051.dylib"
                            _, after, signed = inspect(built.read(member))
                            self.assertEqual(after, before)
                            self.assertTrue(signed)
                            self.assertTrue((built.getinfo(member).external_attr >> 16) & 0o111)
                        if with_widget:
                            loads, _, signed = inspect(built.read(widget + "WidgetExtension"))
                            self.assertTrue(signed)
                            self.assertTrue((built.getinfo(widget + "WidgetExtension").external_attr >> 16) & 0o111)
                            self.assertIn("@rpath/SpotifyGlassAppGroups.dylib", loads)
                        for member in ("Frameworks/spotifyglass.dylib", "Frameworks/SpotifyGlassAppGroups.dylib",
                                       "PlugIns/SpotifyGlassLiveActivity.appex/SpotifyGlassLiveActivity"):
                            _, before, _ = inspect(kit.read("files/" + member))
                            _, after, signed = inspect(built.read(APP + member))
                            self.assertEqual(after, before)
                            self.assertTrue(signed)
                            self.assertTrue((built.getinfo(APP + member).external_attr >> 16) & 0o111)
                        _, text, _ = inspect(built.read(APP + "Frameworks/spotifyglass.dylib"))
                        self.assertEqual(hashlib.sha256(text).hexdigest(), manifest["protection"]["textSHA256"])
                        info = plistlib.loads(built.read(APP + "Info.plist"))
                        self.assertTrue(info["MusicHapticsSupported"])
                        self.assertFalse(info["UIDesignRequiresCompatibility"])
                        extension = plistlib.loads(built.read(APP + "PlugIns/SpotifyGlassLiveActivity.appex/Info.plist"))
                        self.assertEqual(extension["CFBundleIdentifier"], "com.spotify.client.liveactivity")
                        self.assertEqual(extension["CFBundleVersion"], host["CFBundleVersion"])
                        self.assertEqual(extension["CFBundleShortVersionString"], version)
                        actions = json.loads(built.read(APP + "Metadata.appintents/extract.actionsdata"))["actions"]
                        self.assertIn("ExistingIntent", actions)
                        self.assertEqual(json.loads(built.read(APP + "Metadata.appintents/version.json")),
                                         json.loads(kit.read("appintents/version.json")))
                        self.assertEqual(len(actions), 1 + len(json.loads(kit.read("appintents/extract.actionsdata"))["actions"]))
                        self.assertFalse(any(name.startswith(APP + "Watch/") for name in built.namelist()))


if __name__ == "__main__":
    unittest.main()
