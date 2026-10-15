#!/usr/bin/env python3
"""Choose a concrete bundle ID compatible with a decoded signing profile."""
import plistlib
import re
import sys
import zipfile
from pathlib import Path


def concrete_id(value):
    return isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*", value) is not None


def select_bundle_id(profile, bundle_id):
    entitlements = profile.get("Entitlements") if isinstance(profile, dict) else None
    app_id = entitlements.get("application-identifier") if isinstance(entitlements, dict) else None
    if not isinstance(app_id, str) or "." not in app_id:
        raise ValueError("Signing profile is missing a valid application-identifier")
    team, allowed = app_id.split(".", 1)
    if not team:
        raise ValueError("Signing profile has an invalid application-identifier")
    if "*" not in allowed:
        if not concrete_id(allowed):
            raise ValueError("Signing profile has an invalid bundle ID")
        return allowed
    if allowed != "*" and (not allowed.endswith(".*") or not concrete_id(allowed[:-2])):
        raise ValueError("Signing profile has an invalid wildcard bundle ID")
    if not concrete_id(bundle_id) or not bundle_id.startswith(allowed[:-1]):
        raise ValueError("IPA bundle ID does not match the signing profile's wildcard; use a matching profile")
    return bundle_id


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: signing-bundle-id.py <decoded profile.plist> <IPA>")
    try:
        profile = plistlib.loads(Path(sys.argv[1]).read_bytes())
        with zipfile.ZipFile(sys.argv[2]) as ipa:
            roots = [name for name in ipa.namelist() if name.startswith("Payload/")
                     and name.endswith(".app/Info.plist") and len(name.split("/")) == 3]
            if len(roots) != 1:
                raise ValueError("IPA must contain exactly one main Info.plist")
            info = plistlib.loads(ipa.read(roots[0]))
            bundle_id = info.get("CFBundleIdentifier") if isinstance(info, dict) else None
        print(select_bundle_id(profile, bundle_id))
    except (OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        sys.exit(str(error))


if __name__ == "__main__":
    main()
