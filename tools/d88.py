# Copyright (c) 2026 Nakata Maho
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR "AS IS" AND ANY EXPRESS OR
# IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
# OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
# IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
# INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
# BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF
# USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
# ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
# THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

"""D88 disk images for the msx88va disks: 2HD, 77 cylinders x 2
heads x 8 sectors of 1024 bytes, the layout read by src/boot/ipl.asm."""

import os
import struct
import subprocess
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SECTOR = 1024
PER_TRACK = 8
TRACKS = 154            # 77 cylinders x 2 heads
MEDIA_2HD = 0x20


def nasm(args: list[str]) -> None:
    subprocess.run([os.environ.get("NASM", "nasm"), "-f", "bin", *args], check=True)


def write_d88(path: Path, image: bytes, name: str) -> None:
    header_size = 0x2B0
    track_size = PER_TRACK * (16 + SECTOR)
    out = bytearray(header_size)
    out[0:len(name)] = name.encode("ascii")
    out[0x1B] = MEDIA_2HD
    struct.pack_into("<I", out, 0x1C, header_size + TRACKS * track_size)
    for track in range(TRACKS):
        struct.pack_into("<I", out, 0x20 + track * 4, header_size + track * track_size)
    for track in range(TRACKS):
        for record in range(1, PER_TRACK + 1):
            lba = track * PER_TRACK + record - 1
            out += struct.pack("<BBBBHBBB5xH", track // 2, track % 2, record, 3,
                               PER_TRACK, 0, 0, 0, SECTOR)
            out += image[lba * SECTOR:(lba + 1) * SECTOR]
    path.write_bytes(bytes(out))


def build_boot_disk(source: Path, output: Path, name: str,
                    defines: list[str] = ()) -> int:
    """Assemble SOURCE with the NASM DEFINES and write a self-booting disk
    that loads it to 2000:0000; returns the number of sectors the IPL
    loads."""
    with tempfile.TemporaryDirectory(prefix="msx88va-build-") as tmp:
        work = Path(tmp)
        nasm([*(f"-D{d}" for d in defines), "-o", str(work / "CODE.BIN"), str(source)])
        payload = (work / "CODE.BIN").read_bytes()
        if len(payload) > 0xF000:
            raise SystemExit("error: the payload leaves no room for the stack")
        sectors = (len(payload) + SECTOR - 1) // SECTOR
        nasm([f"-DLOAD_SECTORS={sectors}", "-o", str(work / "IPL.BIN"),
              str(REPO / "src/boot/ipl.asm")])
        ipl = (work / "IPL.BIN").read_bytes()
    image = bytearray(TRACKS * PER_TRACK * SECTOR)
    image[0:len(ipl)] = ipl
    image[SECTOR:SECTOR + len(payload)] = payload
    output.parent.mkdir(parents=True, exist_ok=True)
    write_d88(output, bytes(image), name)
    return sectors
