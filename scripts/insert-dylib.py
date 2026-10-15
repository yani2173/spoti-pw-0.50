#!/usr/bin/env python3
"""Add a weak dylib load to a thin arm64 Mach-O using verified header padding.

The IPA must be signed again after this edit. Invalid input is rejected before writing.
"""
import struct
import sys
from pathlib import Path

from sg_macho import arm64_images, dylib_loads, file_sections, load_commands

LC_LOAD_WEAK_DYLIB = 0x80000018


def insert(data, name):
    if not name or "\0" in name:
        raise ValueError("Invalid dylib install name")
    if data[:4] != b"\xcf\xfa\xed\xfe":
        raise ValueError("Expected a thin little-endian arm64 Mach-O")
    image, endian = arm64_images(data)[0]
    commands = list(load_commands(image, endian))
    sections = list(file_sections(image, endian))
    # Parse the command's own string offset (not an assumed offset of 24), and
    # recognize weak/re-export/lazy loads as well as ordinary LC_LOAD_DYLIB.
    if name in dylib_loads(data)[0]:
        return data, False
    boundaries = [start for _, _, start, length, _, zero in sections if length and not zero]
    for command, payload in commands:
        if command == 0x19:
            offset, size = struct.unpack_from("<QQ", payload, 40)
            if offset + size > len(data):
                raise ValueError("Mach-O segment is outside the file")
            if offset and size:
                boundaries.append(offset)
    if not boundaries:
        raise ValueError("Mach-O has no file-backed section or segment")
    count, length = struct.unpack_from("<II", data, 16)
    end = 32 + length
    raw = name.encode("utf-8") + b"\0"
    size = (24 + len(raw) + 7) & ~7
    if end + size > min(boundaries) or any(data[end:end + size]):
        raise ValueError("No room for another load command")
    command = struct.pack("<IIIIII", LC_LOAD_WEAK_DYLIB, size, 24, 2, 0x10000, 0x10000) + raw
    result = bytearray(data)
    result[end:end + size] = command.ljust(size, b"\0")
    struct.pack_into("<II", result, 16, count + 1, length + size)
    return result, True


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: insert-dylib.py <binary> <dylib install name>")
    path, name = Path(sys.argv[1]), sys.argv[2]
    try:
        result, changed = insert(path.read_bytes(), name)
        if changed:
            path.write_bytes(result)
        print(f"    {name} {'added' if changed else 'already loaded'}")
    except (OSError, ValueError, struct.error) as error:
        sys.exit(f"{path}: {error}")


if __name__ == "__main__":
    main()
