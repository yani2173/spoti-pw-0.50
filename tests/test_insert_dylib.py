"""Check that required-bit load commands do not get inserted a second time."""
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class InsertDylibTests(unittest.TestCase):
    def test_existing_weak_load_is_idempotent(self):
        with tempfile.TemporaryDirectory() as folder:
            binary = Path(folder) / "WidgetExtension"
            binary.write_bytes(struct.pack("<IiiIIIII", 0xFEEDFACF, 0x100000C, 0, 2, 0, 0, 0, 0) + b"\0" * 512)
            args = ["python3", str(ROOT / "scripts/insert-dylib.py"), str(binary), "@rpath/SpotifyGlassAppGroups.dylib"]
            subprocess.run(args, capture_output=True, check=True)
            first = binary.read_bytes()
            subprocess.run(args, capture_output=True, check=True)
            self.assertEqual(binary.read_bytes(), first)
            self.assertEqual(struct.unpack_from("<I", first, 16)[0], 1)
            self.assertEqual(struct.unpack_from("<I", first, 32)[0], 0x80000018)


if __name__ == "__main__":
    unittest.main()
