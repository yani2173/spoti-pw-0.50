"""Widget injection preserves bytes and rejects malformed load commands before writing."""
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path
from test_official_pipeline import executable

ROOT = Path(__file__).resolve().parents[1]
NAME = "@rpath/SpotifyGlassAppGroups.dylib"


class InsertDylibTests(unittest.TestCase):
    def run_insert(self, data, succeeds=True):
        with tempfile.TemporaryDirectory() as folder:
            binary = Path(folder) / "WidgetExtension"
            binary.write_bytes(data)
            result = subprocess.run(["python3", str(ROOT / "scripts/insert-dylib.py"), str(binary), NAME],
                                    capture_output=True, text=True)
            if succeeds:
                self.assertEqual(result.returncode, 0, result.stderr)
            else:
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("Traceback", result.stderr)
                self.assertEqual(binary.read_bytes(), data)
            return binary.read_bytes()

    def test_existing_weak_load_is_idempotent(self):
        before = executable()
        first = self.run_insert(before)
        self.assertEqual(self.run_insert(first), first)
        self.assertEqual(first[4096:], before[4096:])
        self.assertEqual(struct.unpack_from("<I", first, 16)[0], 6)
        self.assertEqual(len(first), len(before))

    def test_existing_load_uses_its_string_offset_for_every_load_kind(self):
        for command in (0xC, 0x80000018, 0x8000001F, 0x20):
            with self.subTest(command=command):
                raw = NAME.encode() + b"\0"
                size = (32 + len(raw) + 7) & ~7
                load = struct.pack("<IIIIII", command, size, 32, 0, 0, 0) + b"\0" * 8 + raw
                data = executable([load.ljust(size, b"\0")])
                self.assertEqual(self.run_insert(data), data)

    def test_invalid_headers_and_commands_leave_the_file_unchanged(self):
        inputs = [b"", b"\xcf\xfa\xed\xfe", executable([struct.pack("<II", 0x19, 8)])]
        for location, value in ((16, 1000), (20, 8), (36, 0), (96, 1000)):
            data = executable()
            struct.pack_into("<I", data, location, value)
            inputs.append(data)
        for data in inputs:
            with self.subTest(size=len(data)):
                self.run_insert(data, succeeds=False)

    def test_nonzero_padding_and_sections_block_insertion(self):
        data = executable()
        end = 32 + struct.unpack_from("<I", data, 20)[0]
        data[end] = 42
        self.run_insert(data, succeeds=False)
        data = executable()
        struct.pack_into("<I", data, 32 + 72 + 48, end + 8)
        self.run_insert(data, succeeds=False)

    def test_out_of_file_sections_are_rejected(self):
        data = executable()
        struct.pack_into("<Q", data, 32 + 72 + 40, len(data) * 2)
        self.run_insert(data, succeeds=False)


if __name__ == "__main__":
    unittest.main()
