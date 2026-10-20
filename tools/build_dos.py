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

"""Build MSX.COM and the msx88va MS-DOS 4.0 disks (docs/DESIGN.md).

    python3 -I tools/build_dos.py [--cbios PATH] [--msdos4 PATH]
                                  [--cart ROM ...] [--define NAME[=VALUE] ...]

MSX.COM (src/dos/msxcom.asm) holds the MSX program (src/msx/msx.asm) and
the C-BIOS patch table (tools/cbios.py); it reads C-BIOS and the cartridge
from files at run time. Outputs, in build/ (ignored by git):

    build/dist/msx88va.d88      MS-DOS 4.0, MSX.COM, C-BIOS 0.29a (as
                                released, with its licence), MSX.TXT,
                                LICENSE.TXT, AUTOEXEC.BAT running MSX
    build/dist/MSX.COM ...      the same files, add_files.py,
                                get_games.py and pcengine_disk.py (from
                                vaeg)
    build/private/msx88va-carts.d88
                                with --cart: the disk with those cartridge
                                files added (private, never distributed);
                                --cart takes ROM files, ZIPs (the ROM
                                without a "[a1]"-style tag) or directories

--define passes NASM defines to src/msx/msx.asm (the test options of
docs/DESIGN.md: TEST_RESET=n, DUMP_VRAM, PROFILE).
"""

import argparse
import hashlib
import re
import shutil
import sys
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cbios  # noqa: E402
import dosdisk  # noqa: E402

REPO = dosdisk.REPO
AUTOEXEC = b"@ECHO OFF\r\nPATH A:\\\r\nPROMPT $P$G\r\nVER\r\nMSX\r\n"


def payload(defines: list[str]) -> bytes:
    out = REPO / "build" / "msx.bin"
    out.parent.mkdir(parents=True, exist_ok=True)
    dosdisk.nasm([f"-DBASE={dosdisk.BASE:#x}", *(f"-D{d}" for d in defines),
                  "-o", str(out), str(REPO / "src/msx/msx.asm")])
    return out.read_bytes()


def patch_table() -> str:
    """offset (dw), length (db), the old bytes, the new bytes; FFFFh ends."""
    items = []
    for offset, old, new, _ in cbios.PATCHES:
        old_b, new_b = bytes.fromhex(old), bytes.fromhex(new)
        if len(old_b) != len(new_b):
            raise SystemExit("error: a C-BIOS patch changes the length")
        items.append(f"dw {offset:#06x}\n\t\tdb {len(old_b)}, "
                     + ", ".join(f"{b:#04x}" for b in old_b + new_b))
    return "patches:\t" + "\n\t\t".join(items) + "\n\t\tdw 0ffffh\n"


def dos_name(path: Path) -> str:
    """An 8.3 name for a cartridge file: letters and digits of its name, .ROM."""
    stem = re.sub(r"[^A-Z0-9]", "", path.stem.split("(")[0].upper())[:8] or "CART"
    return stem + ".ROM"


def cartridges(path: Path) -> list[tuple[str, bytes]]:
    """(DOS name, ROM) for --cart: a ROM file, a ZIP (its one ROM without an
    alternative-dump tag such as "[a1]"), or a directory of both."""
    if path.is_dir():
        found = sorted(p for p in path.iterdir()
                       if p.suffix.lower() in (".rom", ".zip"))
        return [c for p in found for c in cartridges(p)]
    if path.suffix.lower() != ".zip":
        return [(dos_name(path), path.read_bytes())]
    with zipfile.ZipFile(path) as archive:
        members = [m for m in archive.namelist()
                   if m.lower().endswith(".rom") and "[" not in m.rsplit("/", 1)[-1]]
        if len(members) != 1:
            raise SystemExit(f"error: {path}: no single ROM without [..] tag")
        return [(dos_name(Path(members[0])), archive.read(members[0]))]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--cbios", type=Path, default=cbios.default_source(),
                        help="zip or directory with C-BIOS 0.29a (default: $MSX_CBIOS)")
    parser.add_argument("--msdos4", type=Path, default=dosdisk.MSDOS4_DEFAULT,
                        help=f"msdos4-pc88va-2hd.d88 of {dosdisk.MSDOS4_RELEASE}")
    parser.add_argument("--cart", type=Path, action="append", default=[],
                        help="cartridge ROM, ZIP or directory of them for the private "
                        "disk (repeatable)")
    parser.add_argument("--define", action="append", default=[],
                        help="NASM define for src/msx/msx.asm (tests)")
    parser.add_argument("--output-dir", type=Path, default=REPO / "build")
    args = parser.parse_args()
    if args.cbios is None:
        parser.error("no C-BIOS: give --cbios or set MSX_CBIOS")
    dosdisk.check_msdos4(args.msdos4)

    main_rom, logo_rom = cbios.load_original(args.cbios)
    code = payload(args.define)
    header = code.find(b"MSX88VA\0")
    if header < 0:
        raise SystemExit("error: no MSX88VA header in the program")
    com = dosdisk.loader(code, {"%define MSX": "", "HEADER": f"{header:#x}"},
                         {"msxpatch.inc": patch_table()})
    files = {
        "MSX.COM": com,
        "CBIOS_M1.ROM": main_rom,
        "CBIOS_L1.ROM": logo_rom,
        "CBIOS.TXT": cbios.licence_text(args.cbios),
        "MSX.TXT": dosdisk.dos_text(REPO / "docs/dist/MSX.TXT"),
        "LICENSE.TXT": dosdisk.dos_text(REPO / "LICENSE"),
        "AUTOEXEC.BAT": AUTOEXEC,
    }
    dist = args.output_dir / "dist"
    dosdisk.make_disk(args.msdos4, files, dist / "msx88va.d88")
    for name, data in files.items():
        if name != "AUTOEXEC.BAT":
            (dist / name).write_bytes(data)
    shutil.copyfile(REPO / "tools/add_files.py", dist / "add_files.py")
    shutil.copyfile(REPO / "tools/get_games.py", dist / "get_games.py")
    shutil.copyfile(dosdisk.disk_tool_path(), dist / "pcengine_disk.py")
    digest = hashlib.sha256((dist / "msx88va.d88").read_bytes()).hexdigest()
    print(f"{dist / 'msx88va.d88'}: MSX.COM ({len(com)} bytes), C-BIOS, "
          f"{len(cbios.PATCHES)} patches applied at run time; SHA-256 {digest}")
    if args.cart:
        carts = [c for path in args.cart for c in cartridges(path)]
        for name, data in carts:
            if name in files:
                raise SystemExit(f"error: two cartridges named {name}")
            if len(data) not in (0x2000, 0x4000, 0x8000) or data[:2] != b"AB":
                raise SystemExit(f"error: {name} is not an 8, 16 or 32 KiB cartridge")
            files[name] = data
        output = args.output_dir / "private" / "msx88va-carts.d88"
        dosdisk.make_disk(args.msdos4, files, output)
        digest = hashlib.sha256(output.read_bytes()).hexdigest()
        names = ", ".join(name for name, _ in carts)
        print(f"{output}: with {names} (private); SHA-256 {digest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
