"""Encrypted and damaged input guards for thin and universal arm64 executables."""
import importlib.util
import struct
import unittest
from pathlib import Path
from test_official_pipeline import executable

spec = importlib.util.spec_from_file_location("sg_macho", Path(__file__).resolve().parents[1] / "scripts/sg_macho.py")
macho = importlib.util.module_from_spec(spec)
spec.loader.exec_module(macho)


def encryption(cryptid):
    return struct.pack("<IIIIII", 0x2C, 24, 4096, 4, cryptid, 0)


def universal(images, endian=">", wide=False):
    start = 8 + len(images) * (32 if wide else 20)
    entries, payload = [], bytearray()
    for image in images:
        cpu, subtype = struct.unpack_from("<II", image, 4)
        entries.append(struct.pack(endian + ("IIQQII" if wide else "IIIII"), cpu, subtype,
                                   start + len(payload), len(image), 0, *([0] if wide else [])))
        payload.extend(image)
    return struct.pack(endian + "II", 0xCAFEBABF if wide else 0xCAFEBABE, len(images)) + b"".join(entries) + payload


class MachOInputTests(unittest.TestCase):
    def test_decrypted_thin_executable_and_no_encryption_command_are_accepted(self):
        macho.validate_decrypted_executable(executable())
        macho.validate_decrypted_executable(executable([encryption(0)]))

    def test_encrypted_thin_executable_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "encrypted"):
            macho.validate_decrypted_executable(executable([encryption(1)]))

    def test_each_arm64_slice_is_checked_in_universal_files(self):
        for endian in ("<", ">"):
            for wide in (True, False):
                with self.subTest(endian=endian, wide=wide):
                    macho.validate_decrypted_executable(universal([executable([encryption(0)])], endian, wide))
                    with self.assertRaisesRegex(ValueError, "encrypted"):
                        macho.validate_decrypted_executable(universal([
                            executable([encryption(0)]), executable([encryption(1)])], endian, wide))

    def test_truncated_and_out_of_bounds_commands_are_rejected(self):
        inputs = [b"\xcf\xfa\xed\xfe", struct.pack(">II", 0xCAFEBABE, 1),
                  executable([struct.pack("<II", 0x2C, 8)])]
        broken = executable()
        struct.pack_into("<I", broken, 36, len(broken))
        inputs.append(broken)
        for binary in inputs:
            with self.subTest(length=len(binary)), self.assertRaises(ValueError):
                macho.validate_decrypted_executable(binary)

    def test_non_executable_main_binary_is_rejected(self):
        binary = executable()
        struct.pack_into("<I", binary, 12, 6)
        with self.assertRaisesRegex(ValueError, "not a Mach-O app executable"):
            macho.validate_decrypted_executable(binary)


if __name__ == "__main__":
    unittest.main()
