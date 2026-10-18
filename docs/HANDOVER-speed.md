# Handover: making msx88va faster

For an engineer or agent picking up the performance work. Read
`AGENTS.md` first (invariants, build, vaeg test commands), then
`docs/DESIGN.md` for the details referred to here. State as of
2026-10-18, branch `topic/m04-games`.

## 1. What runs where

One frame of the PC-88VA (59.9 Hz) is shared between:

1. **The Z80 program** (C-BIOS and the cartridge) in the uPD9002's
   Z80-compatible mode, segment `Z80SEG` (`src/msx/msx.asm`).
2. **Native V30 code**, entered three ways:
   - the **VRTC interrupt** (`vrtc:`), once a frame: `kbd_scan`,
     `render_step` (changed cells of the TMS9918 picture into GVRAM),
     `sprite_step` (TSP hardware sprites: pattern conversion, the 32
     descriptors), `sprite_flags` (fifth-sprite and collision flags),
     then `try_inject` (the Z80's mode 1 interrupt);
   - the **I/O trap** (`trap:`, INT 7Ch/7Dh) for each Z80 IN/OUT to
     98h-99h and A0h-ABh;
   - **CALLN 71h** (`bios_call:`) from the C-BIOS routines patched in
     `tools/cbios.py` (VRAM block and single-byte access, VDP registers,
     PSG, keyboard).

Whatever native code takes is taken from the Z80.

## 2. Measured costs

| Path | PC-88VA2 | PC-88VA | vaeg (VA2 model) |
|---|---|---|---|
| One I/O trap, minimal handler | ~24 us | — | ~10 us |
| One trapped OUT (98h),A, full handler, per byte | ~190 us | ~213 us | ~45 us |
| OTIR in one trap, per byte | — | ~15 us | — |
| LDIRVM by CALLN, per byte | — | ~11 us | — |
| One CALLN round trip | ~8 us | — | ~6 us |

(M01 and M02 tables in DESIGN; 768 bytes x 10 benchmarks of
`src/cart/m02cart.asm`.) The VA's trap path is about 1.5 times the VA2's.

**VRTC handler in vaeg**, VA2 model, Dig Dug playing, cycles of a
141 560-cycle frame (measured with the debug harness `clock`, below):

| Part | Cycles | Frame |
|---|---|---|
| `kbd_scan` | 5 400 | 4% |
| `render_step` | 7 700 | 5% |
| `sprite_step` | 9 400 | 7% |
| `sprite_flags` | 18 000 (was 20 000-33 000) | 13% |
| total | ~41 000 | 29% |

**The two test games** (16 and 32 KiB, 1984) do no trapped I/O at all
while playing: 20-35 CALLNs a frame. Both keep their main program in
`JP $` and do the whole frame in the interrupt handler; in vaeg the Z80
is back in `JP $` at every VRTC (`PROFILE`), so they run at 60 Hz there.

**Blinking at reduced CPU speed.** With vaeg's CPU clock set to the
PC-8801 standard speed the maintainer saw the sprites blink and the games
run at about 30 fps; at the normal VA speed there is no blinking and the
speed is normal (2026-10-18). So when the CPU is short, these games
overrun the frame (their handler crosses a VRTC with the SAT half
rewritten) and the symptom is sprite blinking and half speed. That is
the failure to expect on slower hardware or heavier titles, and the
reason to cut the VRTC handler's share.

## 3. How to measure

Build with `tools/build_dos.py --cart ROM` (private disk), assemble the
program alone with a listing to get addresses:

    nasm -f bin -DBASE=0x3000 -l msx.lst -o msx.bin src/msx/msx.asm

The program runs at segment 3000h; label offsets are in column 2 of the
listing. vaeg debug script (MS-DOS boot and the menu take ~1000 frames;
`input-line` types text and Enter, e.g. `input-line 1` picks menu item 1,
`input-line Z Z` contains a space for "push space"):

    debug-script 1
    limit-frame 2700
    counter vrtc 3000:<vrtc>          # calls of a PC, whole run
    wait-frame 1000
    input-line 1
    wait-frame 2200
    wait-pc 3000:<vrtc> 1             # the next time this PC runs
    capture pa1 registers             # 'clock' = CPU cycles so far
    wait-pc 3000:<.eoi> 1
    capture pb1 registers
    exit

Differences of `clock` between two captures give the cycles between two
PCs. Counters over two runs (to frame A and to frame B) give calls per
frame. Ids are lower-case, a capture must follow a `wait-pc`, and
`--debug-script` cannot be combined with `--headless-input-script`.

Build-time test options (`tools/build_dos.py --define ...`):

- `PROFILE`: the Z80 PC at every VRTC, a ring of 4096 words at GVRAM
  C200h (`capture id gvram`, the file's offset C200h; the count at
  C000h). Shows whether the game finished its frame (PC in its idle
  loop).
- `DUMP_VRAM`: VRAM at GVRAM 8000h, the VDP registers at C000h, and a log
  of the BIOS VRAM calls; costs about half a frame itself, so the game
  runs late while it is on — do not judge timing with it.
- `TEST_RESET=n`: an MSX reset every n frames.

vaeg is not the hardware: its trap is about half as expensive and its
compatible-mode timing is not measured. Confirm every gain on the VA
(the slower model) with a benchmark cartridge that prints frame counts
(`src/cart/m02cart.asm` style, JIFFY based).

## 4. Candidates, by expected gain

1. **`sprite_flags` (13%).** Recomputed every frame because the SAT
   changes every frame. Options: compute only when the Z80 reads the
   status register and only once a frame (`vdp_stat_r`, `h_rdvdp`);
   keep per-sprite row masks between frames and redo only moved
   sprites; skip collision when no two visible boxes overlap (already
   cheap) and, above all, avoid the per-line counting when fewer than
   five sprites are visible (the fifth flag cannot be set then).
2. **`sprite_step` (7%).** `sprite_table` rewrites all 32 descriptors
   every frame and switches port 153h twice. Rewrite only descriptors
   whose SAT entry changed (compare with a shadow), and stop at the first
   Y=D0h.
3. **`kbd_scan` (4%).** Maps ~110 table entries every frame. Read the 15
   VA ports, and remap only when they differ from the previous frame
   (almost never).
4. **`render_step`.** Bounded by MAX_TILES=64 cells a frame; fine for
   these games. Full-screen scrollers will need a faster tile routine
   (unrolled per mode, colour pairs cached per tile) or a larger budget
   spread over frames.
5. **Trapped OUT loops** (titles that write VRAM with their own
   `OUT (98h),A` / `OUTI` loops): ~200 us a byte on the hardware. Make
   the trap fast path minimal (98h data first, no table), and recognise
   common loops at the trapped PC (unrolled OUTI runs, `OUTI; JP NZ`,
   `LD A,(HL); OUT (98h),A; INC HL; DJNZ`) and do the whole loop in one
   trap. A trap profiler (count traps by Z80 PC, show the top entries)
   finds the sites.
6. **Interrupt latency.** `try_inject` also runs at the end of a trap or
   CALLN when the frame flag is pending, so a game that re-enables the
   VDP interrupt gets it immediately (as on an MSX).

## 5. Pitfalls already met

- Native replacements must leave C-BIOS's exit registers and flags
  (LDIRVM: HL = DE, DE = HL + BC, BC = 0098h, A = 0). A game drew text
  one byte off before this was done.
- Never BRKEM again from a handler entered from compatible mode (the V30
  forbids nesting). The MSX reset edits the interrupt frame and IRETs to
  0000h instead.
- The VA's boot ROM BIOS work area overlaps the program once it runs; do
  not call ROM BIOS routines (INT 83h, 8Fh) after start-up from the VRTC
  handler.
- TSP colours above the text/sprite boundary use palette set 1 (0320h):
  both palette sets are written.
- The trap compares only the low 8 bits of the port (M01, VA2).
- vaeg before Rel.20261017 kept a compatible-mode HALT halted; use a
  current vaeg.
- Keep `vars`/`end_of_program` (the start-up snapshot for the MSX reset)
  in mind when adding data: everything after `vars:` is restored at a
  reset.

## 6. Later: MSX2 (notes, nothing tried)

Recorded 2026-10-18 for a later study. A complete MSX2 is not possible
(the VA has no raster interrupt); selected cartridge titles may be.

In favour:

- Bitmap screens may need no renderer at all. SCREEN 5 VRAM (two dots a
  byte, the left one in the high nibble) has the VA's 4-bpp layout: keep
  the MSX's VRAM inside GVRAM and point a framebuffer at it (256 dots =
  128 bytes a line, 212 lines fit the VA's 320x240 15 kHz mode). To
  check: whether the VA's framebuffer accepts that width and pitch.
- SCREEN 7 (512x212x16) maps to the 640-dot mode, SCREEN 8 (256 colours)
  to 8 or 16 bpp; the V9938's 9-bit palette to the VA palette.
- Vertical scroll (R23) is a framebuffer start address; screen splits
  may use the four framebuffer descriptors (regions one above the other).
- The V9938 command engine (HMMM, LMMM, LMMV...) resembles the SGP's
  BitBlt with logical operations and transparency.

Against (worst first):

- Trap cost. MSX2 games drive the VDP directly far more than through the
  BIOS (about 15 register writes to set up one VDP command); at ~200 us
  a trap on the hardware a few dozen a frame use the whole frame.
  Per-title patches or sequence recognition would be needed.
- Memory mapper and expanded slots. The Z80-compatible mode sees one flat
  64 KiB segment and the uPD9002 has no paging, so a mapper switch is a
  16 KiB copy (2-4 ms). The mapper ports FCh-FFh and the RTC B4h-B5h fit
  a second trap block A0h-FFh, but the trap compares the low 8 bits of
  the port, so native I/O such as 01CBh or the trap control FFE0h-FFEFh
  would be caught too (trap off around it). The secondary slot register
  is a memory write at FFFFh and cannot be trapped: patch the BIOS
  (C-BIOS has an MSX2 main ROM and a sub-ROM).
- Sprite mode 2: colours per line can be baked into the TSP's 4-bpp
  sprite images; the OR mixing of overlapping sprites (CC) cannot; eight
  a line nearly fills the TSP's ~256 dots a line.
- Line interrupts (R19). No raster interrupt on the VA.

Approximating line interrupts: when a game's line-interrupt handler only
writes registers (R23 scroll, display page), inject the interrupt into
the Z80 at roughly the right time (a VA timer started at VRTC; timing
loose), record what the handler wrote as "from line N", and display the
next frame as split regions with the framebuffer descriptors. Loose
timing, exact picture. Not covered: per-line palette changes (one
palette for the whole screen), handlers that test the line position,
more than four regions, heavy VRAM transfers inside the handler.

First steps: analyse a target (Aleste, Compile 1988, is the usual
example; its screen mode, mapper and use of line interrupts are not
checked) in openMSX — screen mode, what the line-interrupt handler
writes, VDP accesses and mapper switches a frame — and test on the VA a
256-dot-wide framebuffer and a two-region split with different scroll.
