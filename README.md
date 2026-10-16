# msx88va

An MSX1 cartridge player for the NEC PC-88VA (VA and VA2): the Z80
program runs in the uPD9002 CPU's uPD780 (Z80-compatible) mode, and its
I/O to the video, sound and keyboard ports is caught by the uPD9002's I/O
trap and emulated in native V30 code. Two-clause BSD licence (`LICENSE`).

Status: feasibility (M01). See `docs/ROADMAP.md` and `docs/DESIGN.md`.

## Building

NASM and Python 3.

    python3 -I tools/build_m01.py          # build/m01test.d88, self-booting
