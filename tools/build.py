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

"""Build the msx88va disk (self-booting 2HD D88).

Disk layout: the IPL in sector 0, then MSX (16 KiB, loaded to 2000:0000),
the patched C-BIOS main ROM (2400:0000), its logo ROM (2C00:0000) and an
optional 16 or 32 KiB cartridge (3000:0000, slot 1 from page 1).

    python3 -I tools/build.py [--cbios PATH] [--cart ROM] [--output PATH]

The output contains C-BIOS and the cartridge; it is not committed.
"""

import argparse
import hashlib
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cbios  # noqa: E402
import d88  # noqa: E402

PAGE = 0x4000


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--cbios", type=Path, default=cbios.default_source(),
                        help="zip or directory with C-BIOS 0.29a (default: $MSX_CBIOS)")
    parser.add_argument("--cart", type=Path, help="cartridge ROM, 8, 16 or 32 KiB")
    parser.add_argument("--vaeg", action="store_true",
                        help="replace C-BIOS's HALTs for vaeg (not for the hardware)")
    parser.add_argument("--output", type=Path, default=d88.REPO / "build/msx.d88")
    args = parser.parse_args()
    if args.cbios is None:
        parser.error("no C-BIOS: give --cbios or set MSX_CBIOS")

    main_rom, logo_rom = cbios.load(args.cbios, args.vaeg)
    cart = b""
    if args.cart:
        cart = args.cart.read_bytes()
        if len(cart) == 0x2000:
            cart = cart * 2                     # 8 KiB: mirrored in the page
        if len(cart) not in (PAGE, 2 * PAGE):
            raise SystemExit("error: the cartridge must be 8, 16 or 32 KiB")
    pages = len(cart) // PAGE
    sectors = d88.build_boot_disk(d88.REPO / "src/msx/msx.asm", args.output, "MSX88VA",
                                  defines=[f"CART_PAGES={pages}"],
                                  append=main_rom + logo_rom + cart)
    digest = hashlib.sha256(args.output.read_bytes()).hexdigest()
    patches = len(cbios.PATCHES) + (len(cbios.VAEG_PATCHES) if args.vaeg else 0)
    print(f"{args.output}: MSX, C-BIOS with {patches} patches, "
          f"{pages} cartridge pages ({sectors} sectors), SHA-256 {digest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
