# Design notes

## Method

- The MSX Z80 code runs in the uPD9002's Z80-compatible mode, entered with
  BRKEM, in one 64 KiB segment (DS0 = PS). Interrupts are injected from
  native code as in `../pacman` (push PC on DS0:BP, IP = 0038h, IE = 0).
- MSX I/O is caught by the I/O trap: block 1 = 98h-99h (VDP), block 2 =
  A0h-ABh (PSG, PPI). These are the only two blocks the hardware has.
  Trap vectors 7Ch (IN) and 7Dh (OUT), ranges at FFE0h-FFE7h, control at
  FFEFh (bit 0 IN, bit 1 OUT, bit 4 word ports).
- The handler decodes the Z80 instruction at the saved CS:IP (DB/D3 n,
  ED IN r,(C)/OUT (C),r, ED block I/O), emulates the device, and advances
  the saved IP. Block I/O is one iteration per trap; a repeat whose B is
  not zero leaves IP on the instruction. Z80 A, BC, DE, HL are the saved
  AL, CX, DX, BX.
- Known limits of the method: slot switching means copying 16 KiB pages;
  mapper bank switching by memory writes cannot be trapped (per-title
  patches only).

## M01 probe disk (`src/m01/m01test.asm`)

| Probe | Checks |
|---|---|
| `out-a0` | OUT (n),A with A = 0 traps; IP at the instruction or after it |
| `in-a0` | IN A,(n) traps; the handler's AL reaches Z80 A |
| `io-c0` | OUT (C),r and IN r,(C) with B = 0 |
| `cost` | loop iterations per frame: no I/O, OUT with a minimal handler, OUT with the emulating handler, CALLN to IRET |
| `high` | the same with A and B not zero on address lines 8-15 |
| `vdp-block` | VRAM address set-up on 99h, OTIR and INIR on 98h |

Probes whose high address byte is not zero run last: if the trap compares
all 16 bits, those accesses are not trapped and reach the VA's own I/O
space at that port.

Results (iterations per frame; one loop without I/O is 4.8 us on the
VA2):

| | none | trap-min | trap | calln |
|---|---|---|---|---|
| PC-88VA2 | 3470 | 586 | 141 | 1280 |
| vaeg (VA, VA2) | 3010 | 1048 | 330 | 1572 |

- PC-88VA2 (2026-10-16, disk SHA-256 adf31f18...acb6e): every probe
  PASS, the saved IP is at the trapped instruction, and `high` passes:
  the trap compares the low 8 bits of the port only.
- Cost on the VA2: about 24 us per trap with a minimal handler, 114 us
  with the M01 emulating handler (decode and log), 8 us per CALLN. At
  half a frame for I/O that is at most about 350 trapped accesses a frame.
- So: PSG, PPI and VDP register writes go through the trap with a lean
  per-port handler; bulk VRAM transfers (BIOS LDIRVM and the like, and a
  title's own loops by patch) become CALLN calls that copy in native code.
- vaeg traps on the 8-bit port as the VA2 does, but its trap is about
  half as expensive as the hardware's.

## M02: the MSX machine (`src/msx/msx.asm`)

- Memory (paragraphs): code 2000h, C-BIOS main ROM 2400h, logo ROM 2C00h,
  cartridge 3000h (slot 1 from page 1), the Z80's 64 KiB 4000h, slot-3 RAM
  5000h, VRAM 6000h, an FFh page 6400h, native stack 6800h. The IPL
  moves itself below 2000h, then loads past 64 KiB without crossing a
  64 KiB physical boundary in one read.
- Slots: an A8h write copies each changed page into the Z80 segment (16
  KiB), after copying a RAM page back to its store. C-BIOS's CHKRAM search
  is patched out (with copied pages every slot looks writable): slot 3 in
  pages 2 and 3. The printer entries are patched to "not ready" (ports
  90h and 91h are outside the trap). `tools/cbios.py` lists the patches.
- Trap handler: OUT (n),A and IN A,(n) go through a table by port;
  the ED forms through a decoder (IN r,(C) sets S, Z, P; the block forms
  set Z from B; a repeat runs to B = 0 in one trap).
- C-BIOS's FILVRM, LDIRMV and LDIRVM start with CALLN 71h (build-time
  patch); the native handler does the whole block and the RET, and
  injects a pending interrupt as the trap handler does. On the way out, and in the
  VRTC handler, the Z80 interrupt is injected while the VDP's line is
  active (frame flag and R1 bit 5) and the Z80 has interrupts enabled.
- VDP: VRAM with auto-increment and read-ahead, registers, status (frame
  flag only). Rendering in the VRTC handler, two character rows a frame
  into 320x200 4-bit graphics (picture at dots 32-287, lines 4-195); a
  pass restarts when VRAM or a register changed during the last one.
  Graphics I, II and text; no sprites, no multicolour yet.
- PSG: written through to the OPN's SSG (ports 44h/45h); tone, noise and
  envelope periods scaled by 62400/111861 for the SSG's 998.4 kHz clock;
  register 7's port direction bits keep the VA's. Register 14 reads BFh.
- PPI: slot select, port C, bit set/reset; no keys yet. ESC on the VA
  keyboard restarts the machine.
- HALT: a native interrupt ends a compatible-mode HALT and the IRET
  resumes after it (VA and VA2, ../pacman M01). vaeg kept the core halted
  until its fix in nakatamaho/vaeg PR #42 (M118, cc0d31fc); older vaeg
  builds hang in C-BIOS's first wait.

Test cartridge (`src/cart/m02cart.asm`): screen 2 colour bars, then 768
bytes x 10 written to VRAM by OTIR, LDIRVM and an OUT (98h),A loop, in
frames:

| | OTIR | LDIRVM | OUT |
|---|---|---|---|
| PC-88VA2, one trap a byte (2026-10-17) | 141 | 146 | 86 |
| vaeg, one trap a byte | 31 | 33 | 20 |
| vaeg, OTIR in one trap, LDIRVM by CALLN | 5 | 1 | 20 |
| PC-88VA, OTIR in one trap, LDIRVM by CALLN (2026-10-18) | 7 | 5 | 98 |
| PC-88VA2, OTIR in one trap, LDIRVM by CALLN (2026-10-18) | 3 | 4 | 66 |

On the VA2 that is 190 us a byte for OUT and 310 us for OTIR and OUTI
(the screen being redrawn takes part of it); on the VA, 213 us for OUT,
and 15 us (OTIR) and 11 us (LDIRVM) once the block is done in one go. With one trap a VRAM
byte the PC-88VA2 took several minutes to reach the cartridge (C-BIOS's
start and logo fill and copy VRAM by FILVRM and LDIRVM); with the CALLN
routines the PC-88VA and PC-88VA2 reach the colour bars about 5 s after a
reset. C-BIOS 0.29a's BEEP makes no sound
(it only writes "BEEP" to the debug device), so the PSG is still
untested.

## M03: BIOS calls, input, changed cells, sprites

- C-BIOS's SETWRT, SETRD, WRTVRM, RDVRM, WRTVDP, WRTPSG, RDPSG, RDVDP,
  SNSMAT and the interrupt's keyboard scan also start with CALLN 71h
  (16 patches in all, `tools/cbios.py`); `bios_table` in
  `src/msx/msx.asm` maps each address to its handler. WRTVDP and the
  keyboard scan continue in C-BIOS after the replaced I/O part.
- Keyboard: every VRTC reads the VA matrix (ports 00h-0Eh) and maps it to
  MSX rows 0-10 (`key_map`, after vaeg's `io/serial.c`); the cursor keys,
  SPACE or Z and X are also joystick port 1 (PSG register 14). ESC is an
  MSX key.
- HELP resets the MSX, in the VRTC handler while the Z80 code is
  interrupted: the variables as saved at the start (SNAPSEG), memory,
  picture, SSG and slots reset, and the interrupt frame edited so that the
  IRET resumes the Z80 at 0000h with every register 0 and DI. BRKEM
  cannot be used there (the handler was entered from compatible mode),
  and jumping back to the boot ROM failed on the PC-88VA (2026-10-18:
  the I/O trap left on, the TSP sprites left on; the ROM's BIOS work
  area also overlaps the payload by then).
- Rendering redraws only changed cells: VRAM writes flag the pattern,
  colour or name row they hit; a pass compares each cell's name with the
  one last drawn there; at most 64 cells a frame. A register change that
  affects the cells redraws everything.
- Sprites are the TSP's hardware sprites in monochrome mode: descriptors
  at TVRAM 7E00h, images from TVRAM 1000h, MSX sprite i on descriptor i.
  Patterns are converted when written, dots doubled (the TSP counts 640
  across); the descriptors are rebuilt from the attribute table every
  VRTC. Sizes 8 and 16, magnified or not, the early clock bit. Not done:
  fifth-sprite and collision flags, clipping to the picture, the
  four-a-line limit on the display (all sprites are shown).
- TSP colours above the text/sprite boundary are shown through palette
  set 1 in mixed mode, so both sets (0300h and 0320h) get the TMS9918
  colours. With set 0 only, MSX colours 8 and 9 came out grey and dark
  blue on the PC-88VA2 (2026-10-18).
- Fifth-sprite and collision flags (status bits 6, 5, 0-4) are computed
  in native code as the TMS9918 defines them: four sprites a line count,
  colour-0 sprites included, opaque dots on the picture only. Recomputed
  only after a write to the attribute table, a sprite pattern or a
  sprite register. The TSP's own collision flag is not used: it has
  different rules (colour groups, no colour-0 sprites, no four-a-line
  limit, a 160 us read window) and vaeg does not model it.
- Test cartridge `src/cart/m03cart.asm`: PSG scale by OUT and by WRTPSG,
  the key matrix and GTSTCK/GTTRIG, nine 16x16 sprites (one moving over
  a row) and STATFL: C7h, E7h while the moving one overlaps another.
- PC-88VA and PC-88VA2 (2026-10-18, disk 6d0214cb...): PSG, keys and
  sprites work.
