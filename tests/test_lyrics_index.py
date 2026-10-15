"""Compare the C timing index with the actual pinned arm64 sungAt: machine code.

Install unicorn==2.1.4 for the binary differential checks (required in CI).
Only the method's NSArray.count message is stubbed; its original timing code runs
in the emulator. This does not execute Spotify/iOS or test rendering on a device.
"""
import ctypes as C
import hashlib
import math
import os
from pathlib import Path
import random
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile

try:
    from unicorn import Uc, UC_ARCH_ARM64, UC_MODE_ARM, UC_HOOK_CODE
    from unicorn.arm64_const import UC_ARM64_REG_X0, UC_ARM64_REG_X2, UC_ARM64_REG_X3, UC_ARM64_REG_X4, UC_ARM64_REG_X30, UC_ARM64_REG_PC, UC_ARM64_REG_SP, UC_ARM64_REG_D0
except ImportError:
    Uc = None

ROOT = Path(__file__).resolve().parents[1]

class Span(C.Structure):
    _fields_ = [("start", C.c_int64), ("end", C.c_int64)]

class Break(C.Structure):
    _fields_ = [("start", C.c_int64), ("end", C.c_int64), ("line", C.c_int64)]

@unittest.skipUnless(Uc, "install unicorn==2.1.4 for actual-core differential tests")
class LyricsIndexTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.folder = tempfile.TemporaryDirectory()
        path = Path(cls.folder.name) / ("index.dylib" if sys.platform == "darwin" else "index.so")
        subprocess.run([os.environ.get("CC", "cc"), "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", ("-dynamiclib" if sys.platform == "darwin" else "-shared"), "-fPIC", str(ROOT / "performance/SGLyricsIndex.c"), "-lm", "-o", str(path)], check=True)
        cls.lib = C.CDLL(str(path))
        cls.lib.SGTimeIndexCreate.argtypes = [C.POINTER(Span), C.c_size_t]
        cls.lib.SGTimeIndexCreate.restype = C.c_void_p
        cls.lib.SGTimeIndexDestroy.argtypes = [C.c_void_p]
        cls.lib.SGTimeIndexQuery.argtypes = [C.c_void_p, C.c_double, C.POINTER(Break), C.c_size_t, C.POINTER(C.c_int64), C.POINTER(C.c_size_t), C.POINTER(C.c_int64), C.POINTER(C.c_int64)]
        cls.lib.SGTimeIndexQuery.restype = C.c_bool
        with zipfile.ZipFile(ROOT / "vendor/releases/0.51.0/spoti.pw-0.51.0-kit.zip") as kit:
            names = [n for n in kit.namelist() if n.endswith("/spotifyglass.dylib")]
            core = kit.read(names[0])
        assert hashlib.sha256(core).hexdigest() == "0d8441d7eaaf4b120ccf9579c4e3cf321b60636eacf7f9e49088b96de2eb5829"
        cls.cpu = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
        cls.base = 0x1000000
        cls.cpu.mem_map(cls.base, 0x600000)
        off = 32
        for _ in range(struct.unpack_from("<I", core, 16)[0]):
            command, size = struct.unpack_from("<II", core, off)
            if command == 0x19:
                vm, _, fileoff, length = struct.unpack_from("<QQQQ", core, off + 24)
                cls.cpu.mem_write(cls.base + vm, core[fileoff:fileoff + length])
            off += size
        for address, size in [(0x2000000, 0x10000), (0x2100000, 0x10000), (0x2200000, 0x100000), (0x2300000, 0x100000), (0x2400000, 0x1000)]:
            cls.cpu.mem_map(address, size)
        def count_stub(cpu, address, size, context):
            cpu.reg_write(UC_ARM64_REG_X0, cls.current_count)
            cpu.reg_write(UC_ARM64_REG_PC, cpu.reg_read(UC_ARM64_REG_X30))
        cls.cpu.hook_add(UC_HOOK_CODE, count_stub, begin=cls.base + 0x3173c0, end=cls.base + 0x3173c0)

    @classmethod
    def tearDownClass(cls):
        cls.folder.cleanup()

    def compare(self, spans, breaks, times):
        rows = (Span * len(spans))(*(Span(*row) for row in spans))
        gaps = (Break * len(breaks))(*(Break(*row) for row in breaks))
        index = self.lib.SGTimeIndexCreate(rows, len(spans))
        self.assertTrue(index)
        try:
            self.cpu.mem_write(0x2200000, bytes(rows))
            if breaks:
                self.cpu.mem_write(0x2300000, bytes(gaps))
            # Original non-fragile ivar offset table identifies these fields.
            self.cpu.mem_write(0x2100000 + 48, struct.pack("<Q", 0x2100800)) # _kept
            self.cpu.mem_write(0x2100000 + 120, struct.pack("<Q", 0x2200000)) # _spans
            self.cpu.mem_write(0x2100000 + 128, struct.pack("<Q", 0x2300000)) # _breaks
            self.cpu.mem_write(0x2100000 + 136, struct.pack("<Q", len(breaks)))
            type(self).current_count = len(spans)
            for time in times:
                self.cpu.mem_write(0x2400000, bytes(80))
                for reg, value in [(UC_ARM64_REG_X0, 0x2100000), (UC_ARM64_REG_X2, 0x2400000), (UC_ARM64_REG_X3, 0x2400030), (UC_ARM64_REG_X4, 0x2400038), (UC_ARM64_REG_SP, 0x200ff00), (UC_ARM64_REG_X30, self.base + 0x600000)]:
                    self.cpu.reg_write(reg, value)
                self.cpu.reg_write(UC_ARM64_REG_D0, struct.unpack("<Q", struct.pack("<d", time))[0])
                self.cpu.emu_start(self.base + 0xce558, self.base + 0x600000, count=2000000)
                self.assertEqual(self.cpu.reg_read(UC_ARM64_REG_PC), self.base + 0x600000)
                count = self.cpu.reg_read(UC_ARM64_REG_X0)
                self.assertLessEqual(count, 6)
                original = (struct.unpack("<6q", self.cpu.mem_read(0x2400000, 48))[:count], *struct.unpack("<qq", self.cpu.mem_read(0x2400030, 16)))
                active = (C.c_int64 * 6)()
                found, focus, opened = C.c_size_t(), C.c_int64(), C.c_int64()
                self.assertTrue(self.lib.SGTimeIndexQuery(index, time, gaps, len(breaks), active, C.byref(found), C.byref(focus), C.byref(opened)))
                self.assertEqual((tuple(active[:found.value]), focus.value, opened.value), original, (time, spans, breaks))
        finally:
            self.lib.SGTimeIndexDestroy(index)

    def test_boundaries_seeks_gaps_and_six_line_limit(self):
        for count in [1, 2, 31, 32, 129, 1000]:
            rows = [(i * 1200, i * 1200 + 800) for i in range(count)]
            times = [-1, 0, 0.5, 799, 800, 1199, 1200, count * 1200, 0, -2000]
            self.compare(rows, [(300, 1100, 0), (500, 2000, 1)], times)
            self.compare([(i, 100000) for i in range(count)], [], [0, count, 99999, 100000, 100001])

    def test_randomized_overlaps_breaks_and_backward_seeks(self):
        rng = random.Random(510)
        for _ in range(40):
            starts = sorted(rng.randint(-2000, 300000) for _ in range(rng.randint(32, 800)))
            rows = [(start, start + rng.randint(-500, 80000)) for start in starts]
            gaps = [(start, start + rng.randint(0, 20000), rng.randint(-1, len(rows) - 1)) for start in rng.sample(starts, 12)]
            times = [rng.uniform(-5000, 350000) for _ in range(50)]
            times += [float(value) + delta for start, end in rows[:4] for value in (start, end) for delta in (-0.01, 0, 0.01)]
            times += [float(end) + delta for _, end, _ in gaps for delta in (-500.01, -500, -499.99, 0)]
            self.compare(rows, gaps, times)

    def test_large_integer_rounding_and_duplicate_starts(self):
        for origin in [0, 2**53 - 20, -(2**53), 2**62]:
            rows = [(origin + i // 2, origin + i + 10) for i in range(128)]
            self.compare(rows, [], [float(origin) + offset for offset in [-1024, -1, 0, 1, 10, 50, 1024]])

    def test_invalid_or_unbounded_index_is_rejected(self):
        rows = (Span * 2)(Span(100, 200), Span(0, 50))
        self.assertFalse(self.lib.SGTimeIndexCreate(rows, 2))
        self.assertFalse(self.lib.SGTimeIndexCreate(rows, 16385))
        self.assertFalse(self.lib.SGTimeIndexCreate(None, 0))
        valid = (Span * 1)(Span(0, 100))
        index = self.lib.SGTimeIndexCreate(valid, 1)
        try:
            active = (C.c_int64 * 6)()
            count, focus, opened = C.c_size_t(), C.c_int64(), C.c_int64()
            for time in [math.nan, math.inf, -math.inf]:
                self.assertFalse(self.lib.SGTimeIndexQuery(index, time, None, 0, active, C.byref(count), C.byref(focus), C.byref(opened)))
        finally:
            self.lib.SGTimeIndexDestroy(index)
