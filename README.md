# msx88va

An MSX1 cartridge player for the NEC PC-88VA (VA and VA2): the Z80
program runs in the uPD9002 CPU's Z80-compatible mode, and its I/O to the
video, sound and keyboard is emulated in native V30 code (I/O trap, and
C-BIOS routines called natively). Two-clause BSD licence (`LICENSE`).

Status: C-BIOS and 8-32 KiB cartridges without a mapper run (M04). See
`docs/ROADMAP.md`, `docs/DESIGN.md` and `docs/dist/MSX.TXT`.

## Disks

Every disk is MS-DOS 4.0 for the PC-88VA (FreeDOS-88VA project, MIT
licence, release msdos4-va.2) with `MSX.COM`, which reads C-BIOS 0.29a
(http://cbios.sourceforge.net/, two-clause BSD licence, on the disk) and
your cartridge ROM files at run time. No cartridge ROM is distributed.

Free games: `get_games.py` (in `build/dist`, and on the release) downloads
eight freeware MSX1 games of the MSXdev contest from msxdev.org (checked by
SHA-256) and adds them to a copy of the disk:

    python3 -I build/dist/get_games.py build/dist/msx88va.d88
    # -> build/dist/msx88va-games.d88, ZIPs kept in build/dist/msxdev-zips

## Building

NASM, Python 3, vaeg's `tools/pc88va/pcengine_disk.py` (`../vaeg`), the
msdos4-va.2 disk (`~/.cache/vaeg/msdos4-va.2/dl/msdos4-pc88va-2hd.d88`),
C-BIOS 0.29a (`$MSX_CBIOS`: the release zip); z80asm 1.8 for the test
cartridges.

    python3 -I tools/build_dos.py [--cart ROM]  # build/dist/msx88va.d88
    python3 -I tools/build_m01.py               # build/dist/m01test.d88
    python3 -I tools/build_cart.py [--name m02cart]  # test cartridges
