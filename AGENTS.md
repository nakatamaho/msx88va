# AGENTS.md — msx88va

Two-clause BSD licence (`LICENSE`). No remote yet.

## What this is

An MSX1 cartridge player for the PC-88VA and PC-88VA2. The Z80 code runs
in the uPD9002's Z80-compatible mode; Z80 I/O to the MSX ports is caught by
the I/O trap (INT 7Ch/7Dh) and emulated in native code. Same method as
`../pacman` (The Game PK), which needs no I/O. See `docs/ROADMAP.md`.

## Invariants

- No ROM images (MSX BIOS, cartridges) or anything derived from them are
  committed. A free BIOS (C-BIOS) is the intended default.
- Targets, in order: the vaeg emulator, then the PC-88VA and PC-88VA2.
  vaeg running a test is not evidence that the hardware does; vaeg's trap
  timing in particular is not the silicon's.
- Tools: NASM for V30 code, Python 3 for build scripts (`python3 -I`).
- Code, comments, identifiers and committed documents are in English.

## Reference material

- `../vaeg/docs/modernization/upd9002-upd70008-mode.md` — compatible mode
  (§3) and the I/O trap (§9).
- `../pacman/docs/DESIGN.md` — measured compatible-mode behaviour on the
  VA and VA2 (interrupt injection, HALT, speed).
- `../pc88va-private-docs/tekumani/` — PC-88VA technical manuals.

## How work is organized

Milestones on a branch `topic/mNN-<name>` with commit prefix `MNN:`; each
ends at a maintainer gate on the hardware. `docs/ROADMAP.md` gets one line
a milestone, `docs/DESIGN.md` the design.
