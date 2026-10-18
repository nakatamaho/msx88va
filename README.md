# msx88va

An MSX1 cartridge player for the NEC PC-88VA (VA and VA2): the Z80
program runs in the uPD9002 CPU's uPD780 (Z80-compatible) mode, and its
I/O to the video, sound and keyboard ports is caught by the uPD9002's I/O
trap and emulated in native V30 code. Two-clause BSD licence (`LICENSE`).

Status: C-BIOS boots and starts 16/32 KiB cartridges (M02). See
`docs/ROADMAP.md` and `docs/DESIGN.md`.

## Building

NASM and Python 3; z80asm 1.8 for the test cartridge. The BIOS is C-BIOS
0.29a (http://cbios.sourceforge.net/, two-clause BSD licence), read from
`$MSX_CBIOS` (the release zip or a directory) and patched at build time;
it is not part of this repository.

    python3 -I tools/build.py [--cart ROM]  # build/msx.d88, self-booting
    python3 -I tools/build_cart.py [--name m02cart]  # build/m03cart.rom, test cartridge
    python3 -I tools/build_m01.py           # build/m01test.d88
