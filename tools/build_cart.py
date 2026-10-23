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

"""Assemble a test cartridge (src/cart/NAME.asm) to a 16 KiB ROM.

    python3 -I tools/build_cart.py [--name m02cart|m03cart|bench] [--output PATH]

Needs z80asm 1.8 ($Z80ASM, default z80asm).
"""

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
PAGE = 0x4000


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--name", default="m03cart", choices=["m02cart", "m03cart", "bench"])
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.output is None:
        args.output = REPO / f"build/{args.name}.rom"
    with tempfile.TemporaryDirectory(prefix="msx88va-cart-") as tmp:
        out = Path(tmp) / "cart.bin"
        subprocess.run([os.environ.get("Z80ASM", "z80asm"), "-o", str(out),
                        str(REPO / f"src/cart/{args.name}.asm")], check=True)
        rom = out.read_bytes()
    if len(rom) > PAGE:
        raise SystemExit(f"error: the cartridge is {len(rom)} bytes")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(rom + b"\xff" * (PAGE - len(rom)))
    print(f"{args.output}: {len(rom)} bytes of code, padded to 16 KiB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
