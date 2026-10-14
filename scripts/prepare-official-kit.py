#!/usr/bin/env python3
"""Verify and prepare the official 0.50.0 kit for injection into a Spotify 9.1.78 IPA."""
import argparse
import hashlib
import json
import plistlib
import sys
import zipfile
from pathlib import Path, PurePosixPath

VERSION = "0.50.0"
KIT_SHA256 = "da81a22bbdb4a27a060bead23eb3ff0aa90a06e4f22cd44927f7f9bff161839f"


def verify_download(path, expected=KIT_SHA256):
    with open(path, "rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    if digest != expected:
        raise ValueError("Official kit checksum does not match the published 0.50.0 release")


def read_host(ipa):
    with zipfile.ZipFile(ipa) as archive:
        roots = [name for name in archive.namelist()
                 if len(PurePosixPath(name).parts) == 3 and name.startswith("Payload/")
                 and name.endswith(".app/Info.plist")]
        if len(roots) != 1:
            raise ValueError("IPA must contain exactly one Payload/*.app/Info.plist")
        app = roots[0][:-len("Info.plist")]
        info = plistlib.loads(archive.read(roots[0]))
        executable = info.get("CFBundleExecutable", "")
        if not executable or "/" in executable or executable in (".", "..") or app + executable not in archive.namelist():
            raise ValueError("IPA has no valid main executable")
        for dylib in ("spotifyglass.dylib", "SpotifyGlassAppGroups.dylib"):
            if app + "Frameworks/" + dylib in archive.namelist():
                raise ValueError("Use a clean decrypted Spotify IPA, without an existing spoti.pw injection")
        return app, info


def substitute(value, replacements):
    if isinstance(value, str):
        for key, replacement in replacements.items():
            value = value.replace(key, replacement)
        return value
    if isinstance(value, list):
        return [substitute(item, replacements) for item in value]
    if isinstance(value, dict):
        return {key: substitute(item, replacements) for key, item in value.items()}
    return value


def prepare(ipa, kit, destination):
    app, info = read_host(ipa)
    destination = Path(destination)
    with zipfile.ZipFile(kit) as archive:
        manifest = json.loads(archive.read("kit.json"))
        if manifest.get("format") != 1 or manifest.get("version") != VERSION:
            raise ValueError("Expected official kit format 1, version 0.50.0")
        if info.get("CFBundleShortVersionString") != manifest["spotify"]:
            raise ValueError(f"This release requires Spotify {manifest['spotify']}; IPA has {info.get('CFBundleShortVersionString', 'unknown')}")
        for key in ("CFBundleIdentifier", "CFBundleVersion", "CFBundleShortVersionString"):
            if not isinstance(info.get(key), str) or not info[key]:
                raise ValueError(f"IPA is missing {key}")
        # Check the payload before any plist templates are filled or cyan signs the binaries.
        for name, expected in manifest["integrity"].items():
            if hashlib.sha256(archive.read(name)).hexdigest() != expected:
                raise ValueError(f"Kit file checksum mismatch: {name}")
        for entry in archive.infolist():
            name = PurePosixPath(entry.filename)
            if name.is_absolute() or ".." in name.parts or "\\" in entry.filename:
                raise ValueError("Kit contains an invalid path")
        archive.extractall(destination)
        # zipfile extracts bytes but does not restore Unix execute bits. Keep the extension's binary
        # executable before cyan copies and signs it, as it was in the official kit.
        for entry in archive.infolist():
            mode = (entry.external_attr >> 16) & 0o777
            if mode and not entry.is_dir():
                (destination / entry.filename).chmod(mode)

    operations = manifest["infoPlist"]
    info.update(operations.get("set", {}))
    for key, values in operations.get("union", {}).items():
        existing = info.setdefault(key, [])
        if not isinstance(existing, list):
            raise ValueError(f"IPA's {key} must be an array")
        existing.extend(value for value in values if value not in existing)
    for key, value in operations.get("default", {}).items():
        info.setdefault(key, value)
    (destination / "host.plist").write_bytes(plistlib.dumps(info))

    replacements = {
        "HOST_BUNDLE_ID": info["CFBundleIdentifier"],
        "HOST_SHORT_VERSION": info["CFBundleShortVersionString"],
        "HOST_VERSION": info["CFBundleVersion"],
    }
    for name in manifest["templates"]:
        template = destination / "files" / name
        contents = plistlib.loads(template.read_bytes())
        template.write_bytes(plistlib.dumps(substitute(contents, replacements)))
    return app


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("kit", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    try:
        verify_download(args.kit)
        print(prepare(args.ipa, args.kit, args.destination))
    except (OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        sys.exit(str(error))


if __name__ == "__main__":
    main()
