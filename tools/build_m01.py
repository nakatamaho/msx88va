#!/usr/bin/env python3
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

"""Build the M01 I/O trap probe disk: MS-DOS 4.0 with M01TEST.COM.

    python3 -I tools/build_m01.py [--msdos4 PATH]

M01TEST.COM is the loader (src/dos/msxcom.asm without MSX) with the probe
program (src/m01/m01test.asm), which it starts at BASE:0000. No ROM data
is involved. Output: build/dist/m01test.d88 (AUTOEXEC.BAT runs M01TEST).
"""

import argparse
import hashlib
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import dosdisk  # noqa: E402

MEMORY_TOP = 0x6400     # m01test.asm: VRAMSEG 6000h + 16 KiB


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--msdos4", type=Path, default=dosdisk.MSDOS4_DEFAULT)
    parser.add_argument("--output", type=Path, default=dosdisk.REPO / "build/dist/m01test.d88")
    args = parser.parse_args()
    dosdisk.check_msdos4(args.msdos4)
    out = dosdisk.REPO / "build" / "m01test.bin"
    out.parent.mkdir(parents=True, exist_ok=True)
    dosdisk.nasm(["-o", str(out), str(dosdisk.REPO / "src/m01/m01test.asm")])
    com = dosdisk.loader(out.read_bytes(), {"MEMORY_TOP": f"{MEMORY_TOP:#06x}"})
    files = {"M01TEST.COM": com,
             "AUTOEXEC.BAT": b"@ECHO OFF\r\nPATH A:\\\r\nVER\r\nM01TEST\r\n"}
    dosdisk.make_disk(args.msdos4, files, args.output)
    digest = hashlib.sha256(args.output.read_bytes()).hexdigest()
    print(f"{args.output}: MS-DOS 4.0 and M01TEST.COM ({len(com)} bytes), SHA-256 {digest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
