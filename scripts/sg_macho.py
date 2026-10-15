"""Bounded Mach-O checks used before injection and after signing."""
import struct

ARM64 = 0x0100000C


def arm64_images(data):
    """Return every arm64 slice, accepting both thin and universal Mach-O files."""
    data = memoryview(data)
    magic = bytes(data[:4])
    fat = {b"\xca\xfe\xba\xbe": (">", False), b"\xbe\xba\xfe\xca": ("<", False),
           b"\xca\xfe\xba\xbf": (">", True), b"\xbf\xba\xfe\xca": ("<", True)}
    if magic in fat:
        endian, wide = fat[magic]
        if len(data) < 8:
            raise ValueError("Truncated universal Mach-O header")
        count = struct.unpack_from(endian + "I", data, 4)[0]
        width = 32 if wide else 20
        table_end = 8 + count * width
        if table_end > len(data):
            raise ValueError("Truncated universal Mach-O table")
        images = []
        for i in range(count):
            entry = 8 + i * width
            cpu = struct.unpack_from(endian + "I", data, entry)[0]
            start, size = struct.unpack_from(endian + ("QQ" if wide else "II"), data, entry + 8)
            if start < table_end or size < 4 or start + size > len(data):
                raise ValueError("Invalid universal Mach-O slice")
            if cpu == ARM64:
                images.append(data[start:start + size])
    else:
        images = [data]
    result = []
    for image in images:
        endian = {b"\xcf\xfa\xed\xfe": "<", b"\xfe\xed\xfa\xcf": ">"}.get(bytes(image[:4]))
        if endian is None or len(image) < 32:
            raise ValueError("Expected a 64-bit arm64 Mach-O executable")
        if struct.unpack_from(endian + "I", image, 4)[0] != ARM64:
            raise ValueError("Expected an arm64 Mach-O executable")
        result.append((image, endian))
    if not result:
        raise ValueError("Mach-O has no arm64 slice")
    return result


def load_commands(image, endian):
    if len(image) < 32:
        raise ValueError("Truncated Mach-O header")
    count, length = struct.unpack_from(endian + "II", image, 16)
    end = 32 + length
    if end > len(image) or count > length // 8:
        raise ValueError("Invalid Mach-O load command table")
    offset = 32
    for _ in range(count):
        if offset + 8 > end:
            raise ValueError("Truncated Mach-O load command")
        command, size = struct.unpack_from(endian + "II", image, offset)
        if size < 8 or size % 8 or offset + size > end:
            raise ValueError("Invalid Mach-O load command")
        yield command, image[offset:offset + size]
        offset += size
    if offset != end:
        raise ValueError("Mach-O load command count/size mismatch")


def file_sections(image, endian):
    """Validated section records, including zero-fill sections with no file bytes."""
    for command, payload in load_commands(image, endian):
        if command != 0x19:
            continue
        if len(payload) < 72:
            raise ValueError("Truncated Mach-O segment command")
        count = struct.unpack_from(endian + "I", payload, 64)[0]
        if len(payload) != 72 + count * 80:
            raise ValueError("Invalid Mach-O section table")
        for i in range(count):
            entry = 72 + i * 80
            name, segment = struct.unpack_from(endian + "16s16s", payload, entry)
            length = struct.unpack_from(endian + "Q", payload, entry + 40)[0]
            start = struct.unpack_from(endian + "I", payload, entry + 48)[0]
            flags = struct.unpack_from(endian + "I", payload, entry + 64)[0]
            zero_fill = (flags & 0xFF) in (1, 12, 18)
            if not zero_fill and start + length > len(image):
                raise ValueError("Mach-O section is outside the file")
            yield segment.rstrip(b"\0"), name.rstrip(b"\0"), start, length, flags, zero_fill


def validate_decrypted_executable(data):
    for image, endian in arm64_images(data):
        if struct.unpack_from(endian + "I", image, 12)[0] != 2:
            raise ValueError("IPA main executable is not a Mach-O app executable")
        for command, payload in load_commands(image, endian):
            if command in (0x21, 0x2C):  # LC_ENCRYPTION_INFO / LC_ENCRYPTION_INFO_64
                if len(payload) < (24 if command == 0x2C else 20):
                    raise ValueError("Truncated Mach-O encryption command")
                if struct.unpack_from(endian + "I", payload, 16)[0]:
                    raise ValueError("Spotify executable is encrypted; supply a decrypted IPA")


def dylib_loads(data):
    """One ordered list of dylib load paths for each arm64 slice."""
    result = []
    for image, endian in arm64_images(data):
        names = []
        for command, payload in load_commands(image, endian):
            if command & 0x7FFFFFFF not in (0xC, 0x18, 0x1F, 0x20):
                continue
            if len(payload) < 24:
                raise ValueError("Truncated Mach-O dylib load command")
            start = struct.unpack_from(endian + "I", payload, 8)[0]
            if start < 24 or start >= len(payload):
                raise ValueError("Invalid Mach-O dylib path")
            path = bytes(payload[start:])
            if b"\0" not in path:
                raise ValueError("Unterminated Mach-O dylib path")
            names.append(path.split(b"\0", 1)[0].decode("utf-8"))
        result.append(names)
    return result
