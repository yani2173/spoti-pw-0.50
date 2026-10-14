#!/usr/bin/env python3
"""Verify that the built IPA retains the official 0.50.0 code and data sections."""
import importlib.util
import json
import plistlib
import struct
import sys
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from sg_macho import dylib_loads, validate_decrypted_executable


def sections(data):
    if len(data) < 32 or struct.unpack_from("<I", data)[0] != 0xFEEDFACF:
        raise ValueError("Expected the official thin 64-bit Mach-O dylib")
    count = struct.unpack_from("<I", data, 16)[0]
    result, offset = {}, 32
    for _ in range(count):
        command, size = struct.unpack_from("<II", data, offset)
        if size < 8 or offset + size > len(data):
            raise ValueError("Invalid Mach-O load command")
        if command == 0x19:
            nsects = struct.unpack_from("<I", data, offset + 64)[0]
            for i in range(nsects):
                entry = offset + 72 + i * 80
                if entry + 80 > offset + size:
                    raise ValueError("Invalid Mach-O section table")
                name, segment = struct.unpack_from("<16s16s", data, entry)
                length = struct.unpack_from("<Q", data, entry + 40)[0]
                start = struct.unpack_from("<I", data, entry + 48)[0]
                flags = struct.unpack_from("<I", data, entry + 64)[0]
                zero_fill = (flags & 0xFF) in (1, 12, 18)
                if not zero_fill and start + length > len(data):
                    raise ValueError("Mach-O section is outside the file")
                key = (segment.rstrip(b"\0"), name.rstrip(b"\0"))
                if key in result:
                    raise ValueError("Duplicate Mach-O section")
                result[key] = (length, flags, b"" if zero_fill else data[start:start + length])
        offset += size
    if not result:
        raise ValueError("Mach-O dylib has no sections")
    return result


def verify(ipa, kit, optimized=False):
    with zipfile.ZipFile(ipa) as built, zipfile.ZipFile(kit) as official:
        manifest = json.loads(official.read("kit.json"))
        roots = [name[:-len("Info.plist")] for name in built.namelist()
                 if name.startswith("Payload/") and name.endswith(".app/Info.plist") and len(name.split("/")) == 3]
        if len(roots) != 1:
            raise ValueError("Built IPA must contain one main app")
        core = "Frameworks/spotifyglass.dylib"
        if manifest["version"] != "0.50.0" or sections(built.read(roots[0] + core)) != sections(official.read("files/" + core)):
            raise ValueError("The built IPA does not preserve the official 0.50.0 code/data")
        if optimized and roots[0] + "Frameworks/SGPerformance050.dylib" not in built.namelist():
            raise ValueError("Optimized build is missing its performance add-on")
        info = plistlib.loads(built.read(roots[0] + "Info.plist"))
        executable = info.get("CFBundleExecutable", "")
        if not isinstance(executable, str) or not executable or "/" in executable or executable in (".", ".."):
            raise ValueError("Built IPA has no valid main executable")
        main = built.read(roots[0] + executable)
        validate_decrypted_executable(main)
        required = ["@rpath/SpotifyGlassAppGroups.dylib", "@rpath/spotifyglass.dylib"]
        if optimized:
            required.append("@rpath/SGPerformance050.dylib")
        for path in required:
            if roots[0] + "Frameworks/" + path.removeprefix("@rpath/") not in built.namelist():
                raise ValueError(f"Built IPA is missing {path}")
        for loads in dylib_loads(main):
            if any(path not in loads for path in required):
                raise ValueError("Built IPA does not load all required mod dylibs")
            if optimized and loads.index(required[1]) >= loads.index(required[2]):
                raise ValueError("Performance add-on must load after the original 0.50.0 core")


if __name__ == "__main__":
    try:
        spec = importlib.util.spec_from_file_location("kit", Path(__file__).with_name("prepare-official-kit.py"))
        kit_module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(kit_module)
        kit_module.verify_download(sys.argv[2])
        verify(sys.argv[1], sys.argv[2], len(sys.argv) > 3 and sys.argv[3] == "1")
        print("Verified: original 0.50.0 code/data sections preserved")
    except (OSError, ValueError, KeyError, struct.error, zipfile.BadZipFile) as error:
        sys.exit(str(error))
