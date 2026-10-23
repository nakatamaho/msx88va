# AGENTS.md — msx88va

An MSX1 cartridge player for the NEC PC-88VA and PC-88VA2. Two-clause BSD
licence (`LICENSE`). Local repository; no remote yet.

## What this is

The MSX's Z80 code runs unmodified in the uPD9002 CPU's Z80-compatible
(uPD70008) mode, entered with BRKEM. Native V30 code emulates the rest:

- I/O to the MSX ports (98h-99h VDP, A0h-ABh PSG and PPI) is caught by the
  uPD9002's I/O trap (INT 7Ch/7Dh) — slow (about 200 us a trap on the
  hardware).
- C-BIOS's VDP, PSG and keyboard routines are patched to start with
  `CALLN 71h` and are done natively in one call (about 8-15 us).
- The VRTC interrupt draws the changed cells of the TMS9918 picture into
  GVRAM, puts the sprites on the TSP's hardware sprites, computes the VDP's
  sprite flags, reads the VA keyboard, and injects the Z80's mode 1
  interrupt.

Read `docs/DESIGN.md` (design and measurements), `docs/ROADMAP.md` (one
line a milestone) and, for performance work, `docs/HANDOVER-speed.md`.

## Invariants

- **MS-DOS 4.0 disks only.** Every disk the project builds is the
  FreeDOS-88VA project's MS-DOS 4.0 for the PC-88VA (MIT licence,
  release msdos4-va.2, `msdos4-pc88va-2hd.d88`, checked by SHA-256 in
  `tools/dosdisk.py`) with our `.COM` programs added. No self-booting
  disks. `src/dos/msxcom.asm` is the one loader: it copies its payload to
  `BASE:0000` (3000h) and starts it.
- **ROMs.** C-BIOS 0.29a (two-clause BSD) may be distributed: it goes on
  the disk unmodified with its licence (`CBIOS.TXT`); MSX.COM patches it
  in memory. Cartridge ROMs and anything derived from them are never
  committed and never on a distributed disk: `build/private/` only.
  `.gitignore` covers `build/`, `*.rom`, `*.d88`; check `git status`
  before every commit. The test games are freeware of the MSXdev contest,
  fetched by the user with `tools/get_games.py` (official ZIPs, SHA-256);
  they are not ours to redistribute.
- **Commercial ROMs: never commit.** The maintainer's commercial MSX
  cartridges (Namcot and Hudson titles, 1984-1986, as ZIPs) are in
  `~/work/pc88va/pc88va-private-docs/msxroms/`. Never copy them, or any
  ROM, disk image, dump or screenshot derived from them, into the
  repository or a distributed disk; never paste their bytes into commits,
  documents or issues. Use them only through `build/private/`.
- **The MSX BIOS: never commit.** The maintainer's MSX1 main ROM (32 KiB,
  Japanese, SHA-1 302afb5d...2821) is
  `~/work/pc88va/pc88va-private-docs/msxroms/MSX.rom`; same rules as the
  commercial ROMs. `--msx-bios` puts it on `build/private/msx88va-msxbios.d88`
  as MSXBIOS.ROM, which MSX.COM runs unpatched instead of C-BIOS (RAM in
  slot 0 pages 2-3, printer ports trapped as never busy).
- **The user's gaiji RAM.** MSX.COM saves the battery-backed gaiji area
  to GAIJI.BAK (kept when present) before the program overwrites it for
  Graphics I; `MSX /R` puts it back. Never write B0800h-B1FBFh without that
  copy, and never B0000h-B07FFh or B1FC0h- (JFP learning area, memory
  switches).
- **C-BIOS compatibility.** A routine done natively must leave the Z80
  registers and flags as the C-BIOS routine does (games compute their
  next call from them; see DESIGN "M04").
- Targets, in order: vaeg, then the PC-88VA and PC-88VA2. vaeg running
  is not evidence that the hardware does; vaeg's I/O-trap cost and
  compatible-mode timing are not the silicon's. The VA is slower than the
  VA2 (the trap path about 1.5 times).
- Tools: NASM for V30 code, z80asm 1.8 for the Z80 test cartridges,
  Python 3 (run with `-I`). vaeg's `tools/pc88va/pcengine_disk.py` writes
  the disk images (`../vaeg`).
- Code, comments, identifiers and committed documents are in English.

## Building

    export MSX_CBIOS=~/work/pc88va/pc88va-private-docs/msxroms/cbios-0.29a.zip
    python3 -I tools/build_dos.py                  # build/dist/msx88va.d88
    python3 -I tools/build_dos.py --cart GAME.rom  # + build/private/msx88va-carts.d88
    python3 -I build/dist/get_games.py build/dist/msx88va.d88  # MSXdev games
    # the private test disk: every ROM and ZIP of msxroms/ (the commercial
    # titles, the MSXdev ZIPs; C-BIOS's ZIP there is skipped)
    python3 -I tools/build_dos.py --cart ~/work/pc88va/pc88va-private-docs/msxroms
    # the same with the real MSX BIOS: build/private/msx88va-msxbios.d88
    python3 -I tools/build_dos.py --cart ~/work/pc88va/pc88va-private-docs/msxroms \
      --msx-bios ~/work/pc88va/pc88va-private-docs/msxroms/MSX.rom
    python3 -I tools/build_m01.py                  # build/dist/m01test.d88
    python3 -I tools/build_pcg.py                  # build/dist/pcgtest.d88 (M05)
    Z80ASM=.../z80asm python3 -I tools/build_cart.py [--name m02cart]

Test options for the MSX program: `--define TEST_RESET=n`, `DUMP_VRAM`,
`PROFILE` (DESIGN "M04"; DUMP_VRAM slows the game itself), `TEST_KEYS`
(M acts as F10: vaeg's `@hold` cannot hold F10), `TEST_FIRE` (SPACE and
trigger A pressed four frames in eight, for measurements with a debug
script, which cannot hold keys), `TEST_NOFOLLOW` (no z80_follow or I/O
loop shortcuts: the reference for `tools/follow_cart.py`),
`TEST_FOLLOWALL` (z80_follow without zf_worth, for the same test).

## Testing in vaeg

    VA=../vaeg/build/linux-ci-gcc/sdl2/vaeg
    SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy $VA --no-cfg --no-bkupmem \
      --model va2 --roms <ROM dir> --fdd1 build/private/msx88va-carts.d88 \
      --nowait --mute --headless-input-script s.txt --screenshot 1500:a.png

- The MS-DOS boot, AUTOEXEC and MSX.COM take about 900 frames; the menu
  takes a digit (`@text 1`).
- `--debug-script` (cannot be combined with `--headless-input-script`):
  `counter id CS:IP`, `wait-frame n`, `input-line text`, `wait-pc CS:IP n`
  (n counts from the moment of the wait), then `capture id registers |
  screen | gvram | tvram` (lower-case ids; a capture must follow a
  wait-pc). The `clock` field of a registers capture gives cycle counts
  between two PCs. Addresses come from the NASM listing
  (`nasm -l`), segment 3000h for the MSX program.

## How work is organized

Milestones on a branch `topic/mNN-<name>`, commit prefix `MNN:`; each
ends at a maintainer gate on the hardware (photographs). Record the
results in `docs/DESIGN.md`, one line in `docs/ROADMAP.md`, merge with
`--no-ff` to `main` after the gate passes.
