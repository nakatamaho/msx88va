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
                                released, with its licence), BENCH.ROM
                                (src/cart/bench.asm, the measuring
                                cartridge, on every disk), MSX.TXT,
                                LICENSE.TXT, AUTOEXEC.BAT running MSX
    build/dist/MSX.COM ...      the same files, add_files.py,
                                get_games.py and pcengine_disk.py (from
                                vaeg)
    build/private/msx88va-carts.d88
                                with --cart: the disk with those cartridge
                                files added (private, never distributed);
                                --cart takes ROM files, ZIPs (the ROM
                                without a "[a1]"-style tag) or directories
    build/private/msx88va-msxbios.d88
                                with --msx-bios: the same with an MSX1
                                main ROM as MSXBIOS.ROM, which MSX.COM runs
                                instead of C-BIOS (private, never
                                distributed)

--define passes NASM defines to src/msx/msx.asm (the test options of
docs/DESIGN.md: TEST_RESET=n, DUMP_VRAM, PROFILE). BENCH.ROM needs z80asm
1.8 ($Z80ASM, default z80asm).
"""

import argparse
import hashlib
import io
import os
import re
import shutil
import subprocess
import tempfile
import sys
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cbios  # noqa: E402
import msxbios  # noqa: E402
import dosdisk  # noqa: E402
import get_games  # noqa: E402

REPO = dosdisk.REPO
AUTOEXEC = b"@ECHO OFF\r\nPATH A:\\\r\nPROMPT $P$G\r\nVER\r\nMSX\r\n"


def payload(defines: list[str]) -> bytes:
    out = REPO / "build" / "msx.bin"
    out.parent.mkdir(parents=True, exist_ok=True)
    dosdisk.nasm([f"-DBASE={dosdisk.BASE:#x}", *(f"-D{d}" for d in defines),
                  "-o", str(out), str(REPO / "src/msx/msx.asm")])
    return out.read_bytes()


def bench_rom() -> bytes:
    """src/cart/bench.asm assembled and padded to a 16 KiB cartridge."""
    with tempfile.TemporaryDirectory(prefix="msx88va-bench-") as tmp:
        out = Path(tmp) / "bench.bin"
        try:
            subprocess.run([os.environ.get("Z80ASM", "z80asm"), "-o", str(out),
                            str(REPO / "src/cart/bench.asm")], check=True)
        except FileNotFoundError:
            raise SystemExit("error: z80asm 1.8 is needed for BENCH.ROM (set $Z80ASM)")
        rom = out.read_bytes()
    if len(rom) > 0x4000:
        raise SystemExit(f"error: BENCH.ROM is {len(rom)} bytes")
    return rom + b"\xff" * (0x4000 - len(rom))


def patch_table() -> str:
    """C-BIOS's table (patches: offset (dw), length (db), the old bytes, the
    new bytes; FFFFh ends) and an MSX BIOS's (msx_sha1: its SHA-1 as five
    dwords; msx_patches: the offsets of CALLN 71h; FFFFh ends)."""
    items = []
    for offset, old, new, _ in cbios.PATCHES:
        old_b, new_b = bytes.fromhex(old), bytes.fromhex(new)
        if len(old_b) != len(new_b):
            raise SystemExit("error: a C-BIOS patch changes the length")
        items.append(f"dw {offset:#06x}\n\t\tdb {len(old_b)}, "
                     + ", ".join(f"{b:#04x}" for b in old_b + new_b))
    text = "patches:\t" + "\n\t\t".join(items) + "\n\t\tdw 0ffffh\n"
    words = [msxbios.SHA1[i:i + 8] for i in range(0, 40, 8)]
    text += "msx_sha1:\tdd " + ", ".join(f"0{w}h" for w in words) + "\n"
    text += ("msx_patches:\tdw " + ", ".join(f"{o:#06x}" for o, _ in msxbios.PATCHES)
             + ", 0ffffh\n")
    return text


def dos_name(path: Path) -> str:
    """An 8.3 name for a cartridge file: letters and digits of its name, .ROM."""
    stem = re.sub(r"[^A-Z0-9]", "", path.stem.split("(")[0].upper())[:8] or "CART"
    return stem + ".ROM"


def cartridges(path: Path) -> list[tuple[str, bytes]]:
    """(DOS name, ROM) for --cart: a ROM file, a ZIP, or a directory of both
    (C-BIOS's ZIP and ROM files without a cartridge header skipped). An MSXdev ZIP of tools/get_games.py gives the
    ROM and name listed there; another ZIP its one ROM without an
    alternative-dump tag such as "[a1]"."""
    if path.is_dir():
        found = sorted(p for p in path.iterdir()
                       if p.suffix.lower() in (".rom", ".zip")
                       and not p.name.lower().startswith("cbios"))
        carts = []
        for p in found:
            if p.suffix.lower() == ".rom" and p.read_bytes()[:2] != b"AB":
                print(f"{p.name}: not a cartridge (an MSX BIOS?), skipped")
                continue
            carts += cartridges(p)
        return carts
    if path.suffix.lower() != ".zip":
        return [(dos_name(path), path.read_bytes())]
    data = path.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        for name, _, _, _, _, sha256, member in get_games.GAMES:
            if digest == sha256:
                return [(name, archive.read(member))]
        members = [m for m in archive.namelist()
                   if m.lower().endswith(".rom") and "[" not in m.rsplit("/", 1)[-1]]
        if len(members) != 1:
            raise SystemExit(f"error: {path}: no single ROM without [..] tag")
        return [(dos_name(Path(members[0])), archive.read(members[0]))]


def bsave_body(path: Path) -> bytes:
    """A file's bytes, without the 7-byte header of an MSX-BASIC BSAVE file
    (FEh, start, end, run address) when it has one."""
    data = path.read_bytes()
    if len(data) > 7 and data[0] == 0xFE:
        start, end = (int.from_bytes(data[i:i + 2], "little") for i in (1, 3))
        if len(data) == 7 + end - start + 1:
            return data[7:]
    return data


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--cbios", type=Path, default=cbios.default_source(),
                        help="zip or directory with C-BIOS 0.29a (default: $MSX_CBIOS)")
    parser.add_argument("--msdos4", type=Path, default=dosdisk.MSDOS4_DEFAULT,
                        help=f"msdos4-pc88va-2hd.d88 of {dosdisk.MSDOS4_RELEASE}")
    parser.add_argument("--cart", type=Path, action="append", default=[],
                        help="cartridge ROM, ZIP or directory of them for the private "
                        "disk (repeatable)")
    parser.add_argument("--msx-bios", type=Path, nargs="+", metavar="FILE",
                        help="an MSX1 main ROM (private) for a second private disk, as "
                        "MSXBIOS.ROM: one 32 KiB file, or 0000h-3FFFh and "
                        "4000h-7FFFh in two; BSAVE headers are removed")
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
        "BENCH.ROM": bench_rom(),
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
    if args.cart or args.msx_bios:
        carts = [c for path in args.cart for c in cartridges(path)]
        for name, data in carts:
            if name in files:
                raise SystemExit(f"error: two cartridges named {name}")
            if len(data) not in (0x2000, 0x4000, 0x8000) or data[:2] != b"AB":
                raise SystemExit(f"error: {name} is not an 8, 16 or 32 KiB cartridge")
            files[name] = data
        names = ", ".join(name for name, _ in carts) or "no cartridge"
        if args.cart:
            output = args.output_dir / "private" / "msx88va-carts.d88"
            dosdisk.make_disk(args.msdos4, files, output)
            print(f"{output}: with {names} (private)")
    if args.msx_bios:
        bios = b"".join(bsave_body(path) for path in args.msx_bios)
        if len(bios) != 0x8000 or bios[:2] != b"\xf3\xc3":
            raise SystemExit(f"error: {len(bios)} bytes: not an MSX1 main ROM "
                             "(32 KiB, DI; JP at 0000h); 0000h-3FFFh alone is not enough, "
                             "the start-up code jumps into 4000h-7FFFh")
        files["MSXBIOS.ROM"] = bios
        output = args.output_dir / "private" / "msx88va-msxbios.d88"
        dosdisk.make_disk(args.msdos4, files, output)
        print(f"{output}: MSXBIOS.ROM (SHA-1 {hashlib.sha1(bios).hexdigest()}), "
              f"with {names} (private)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
