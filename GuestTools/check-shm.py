#!/usr/bin/env python3
"""Check the Vortex shared memory state between HAL plugin and daemon."""
import ctypes, mmap, struct, os

libc = ctypes.CDLL(None)
fd = libc.shm_open(b"/vortex-audio", 0, 0)  # O_RDONLY
if fd < 0:
    print("ERROR: shm_open failed — shared memory not created")
    raise SystemExit(1)

size = 1048576
buf = mmap.mmap(fd, size, mmap.MAP_SHARED, mmap.PROT_READ)

magic = struct.unpack_from("<I", buf, 0)[0]
version = struct.unpack_from("<I", buf, 4)[0]
oW = struct.unpack_from("<Q", buf, 8)[0]
oR = struct.unpack_from("<Q", buf, 16)[0]
iW = struct.unpack_from("<Q", buf, 524296)[0]
iR = struct.unpack_from("<Q", buf, 524304)[0]
sr = struct.unpack_from("<I", buf, 1048568)[0]
ch = struct.unpack_from("<I", buf, 1048572)[0]
active = struct.unpack_from("<I", buf, 1048576 - 4)[0]

print(f"magic: 0x{magic:08X}, version: {version}")
print(f"output ring: writePos={oW}, readPos={oR}, pending={oW - oR}")
print(f"input ring:  writePos={iW}, readPos={iR}, pending={iW - iR}")
print(f"sampleRate: {sr}, channels: {ch}")
print(f"isActive: {active}")

buf.close()
os.close(fd)
