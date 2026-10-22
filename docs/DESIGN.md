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

- Memory (paragraphs; M02 had a self-booting disk with BASE 2000h, now
  MS-DOS with BASE 3000h, see "Disks"): code BASE (24 KiB since M05),
  C-BIOS main ROM BASE+600h, logo ROM +E00h, cartridge +1200h (slot 1
  from page 1), the Z80's 64 KiB +2200h, slot-3 RAM +3200h, VRAM +4200h,
  the Graphics II cell images +4600h (24 KiB; until then an FFh page of
  16 KiB, now an empty page is filled with FFh when selected), native
  stack +4C00h (8 KiB), the variables' start-up copy +4E00h (1 KiB), up
  to +4E40h = 7E40h: below 8000h, the top of the
  PC-88VA's standard 512 KiB (vaeg's DOS reports A000h). Only the
  variables from `vars` to `vars_end` are copied for an MSX reset; the
  work areas after them (flags, shadow, colour pairs) are zeroed
  (`zero_init`), the constant tables sit before `vars`. (Until M05 the
  copy, 8.7 KiB, overran its 8 KiB by 0.5 KiB, harmless only because DOS
  had the memory free.)
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
  sprites work. Disk bad9ce14... on both: the colours 8 and 9 right with
  both palette sets, STATFL C7h/E7h as in vaeg, HELP resets the MSX.

## M04: real cartridges

- 16 and 32 KiB cartridges without a mapper (two 1984 titles) boot and
  play in vaeg; neither does any trapped I/O while playing: all VDP, PSG
  and keyboard access goes through the C-BIOS routines done by CALLN (20
  to 35 calls a frame).
- The native routines leave the Z80 registers as C-BIOS does: LDIRVM
  returns HL = DE, DE = HL + BC, BC = 0098h, A = 0 (C-BIOS ends with
  EX DE,HL); LDIRMV DE = HL; FILVRM BC = 0; SETWRT/SETRD set A. A game
  that computes its next LDIRVM from the returned registers drew its text
  one byte off before this.
- VRTC handler cost in vaeg (PC-88VA2 model, cycles of 141 560 a frame),
  one of the games playing: keyboard 5 400, changed cells 7 700, TSP
  sprites 9 400, sprite flags 18 000 (33 000 before the list of visible
  sprites only; the row test is a 32-bit AND), 41 000 in all.
- vaeg (2026-10-18, maintainer): no sprite blinking and normal speed at
  the VA's CPU speed; with vaeg's CPU clock at the PC-8801 standard speed
  the sprites blinked and the games ran at about 30 fps (frames overrun).
- Test options for `tools/build_dos.py --define`: TEST_RESET=n (an MSX reset
  every n frames), DUMP_VRAM (VRAM, the registers and a log of the BIOS
  VRAM calls copied to spare GVRAM every frame; the copy costs about half
  a frame, so the game runs late while it is on), PROFILE (the Z80 PC at
  every VRTC, a ring at GVRAM C200h).
- An MSX BIOS of the user's (MSXBIOS.ROM) ran unpatched until 2026-10-22:
  every VDP, PSG and PPI access of its routines an I/O trap. Bosconian in
  vaeg (VA model, play): 194 traps a frame (76% the `OUT (98h),A` of
  LDIRVM's byte loop, 0749h; then WRTPSG, SETWRT, WRTVRM, WRTVDP,
  SNSMAT), 0.4 interrupts taken a frame against C-BIOS's 0.9: the game at
  less than half speed in vaeg, and about a quarter on the VA (~200 us a
  trap: ~39 ms a frame), as the maintainer saw (the start music slow).
  Now MSX.COM computes the ROM's SHA-1 (`sha1_rom`, about 0.2 s in
  vaeg) and, when it is the one of `tools/msxbios.py` (the Japanese MSX1
  BIOS version 1.0), puts CALLN 71h at the start of WRTVDP, RDVRM,
  WRTVRM, SETRD, SETWRT, FILVRM, LDIRMV, LDIRVM, WRTPSG, RDPSG, RDVDP and
  SNSMAT; another ROM runs unpatched and MSX.COM says so (checked in
  vaeg with one byte changed). The repository holds only the digest and
  the offsets, no byte of the ROM. `bios_call` uses `msx_table` when
  `ram_slot` is 0. The routines' exits differ from
  C-BIOS's, so these handlers have their own: LDIRVM HL = DE, DE = HL +
  BC, BC = 0, A = 0 with Z (LD A,C; OR B); LDIRMV DE = DE + BC, HL kept;
  FILVRM and WRTVRM keep AF (PUSH/POP AF), FILVRM BC = 0; SETWRT/SETRD A
  and the flags of OR 40h / AND 3Fh; RDVRM those of SETRD; SNSMAT C = A
  and the flags of ADD A,C; WRTVDP goes on in the Z80 code at 0589h (EI,
  the copy in RG0SAV) with the flags of OR 80h; a count of 0 is 65536
  bytes as in the loops. vaeg: Bosconian 0 traps and 0.9 interrupts a
  frame, the 18 titles and MSX BASIC start; the interrupt's own status read
  (0C4Dh) is still one trap a frame. Typing into BASIC with vaeg's
  `input-line` drops letters with and without the patches (one keyboard
  scan a frame).
- PC-88VA, 2026-10-22 (maintainer): Bosconian with the MSX BIOS at the
  speed of an MSX, the start music right.
- The MSX BIOS also traps where C-BIOS's routines do not: its interrupt
  reads the status (0C4Dh) and scans the keyboard with OUT/IN pairs (0D12h,
  11 rows), and GTSTCK and GTTRIG read the joystick through PSG registers
  14 and 15 (121Fh) and row 8 (1226h). These four are CALLN 71h too
  (`m_status`, `m_keyin`, `m_joy`, `m_row8`). Star Force in vaeg: traps a
  frame 52 -> 13 with the jump-table routines, -> 1.4 with these; in
  vaeg the ship moves under the joystick as with C-BIOS, and the two runs
  stay frame for frame alike.
- Star Force writes its picture through its own subroutine in RAM
  (E407h: `OUT (98h),A; RET`), called once a byte from ROM loops (41 calls
  a frame in play). After a trapped `OUT (98h),A` that is followed by RET,
  `out_loop` looks at the caller: when it is `LD A,(HL); CALL P; INC HL;
  DJNZ` or `LD A,(HL); INC HL; CALL P; DJNZ` (found by the code's shape),
  the loop's remaining bytes go to VRAM at once and the Z80 resumes after
  the DJNZ with B = 0, HL past the bytes, A the last byte and the RET's
  address popped. Traps a frame in play: 42 -> 2.4 with C-BIOS (on the
  VA about 8 ms a frame less). The 18 titles look as before with both
  BIOSes.
- Star Force's scroll: the background moves down a cell row (8 lines) at
  a time; the game rewrites about 540 names over a few frames, patterns
  and colours stay. At MAX_TILES = 64 cells a frame the picture takes
  about nine frames to follow a step (vaeg: render_step 26 000 cycles a
  frame on the VA model).
- Graphics II cell images (`tile_g2`): the image of a (third, name) pair
  is made once into CACHESEG (32 bytes, 768 entries) and copied to GVRAM
  from there (8 x 2 MOVSW); `g2_ok` marks the valid ones, cleared by
  `make_merged` where the pattern or colour of the pair is pending and
  wholly on a full redraw (which a backdrop change also is). A copied cell
  costs half a cell of the frame's budget (MAX_TILES * 2 halves). Star
  Force in vaeg (VA model, play): render_step 26 300 -> 12 400 cycles a
  frame (max 56 400 -> 47 600), passes completed 0.29 -> 0.50 a frame;
  GVRAM against the picture computed from a VRAM dump, 24 frames of the
  scroll: exact whenever no pass was under way (the others differ only in
  the cells the pass had not reached). The 18 titles look as before with
  both BIOSes.

## M05: Graphics I on the TSP text screen (`src/pcg/pcgtest.asm`)

Goal: draw Graphics I (and text mode) cells as TSP characters instead of
GVRAM tiles, so a cell costs one TVRAM word instead of ~400 cycles.

- User-defined characters are the gaiji RAM: battery-backed, B0800h-B1FBFh
  of the backup RAM (manual 3.4; B0000h-B07FFh is the JFP learning area,
  B1FC0h- the memory switches), 188 full-width characters (JIS 7621h-),
  byte access only, through the system memory window with port 153h SMBC
  = 9 (kanji ROM #2). vaeg's layout (io/cgromva.c): character (j1, j2) at
  ((j2 & 60h) << 6) + ((j1 & 1) << 10) + ((j2 & 1Fh) << 5), row r at 2r
  (left half) and 2r + 1 (right half). The text BIOS writes it too
  (INT 83h AH = 21h, as SETGAIJI, 88VA User's Club library 1989).
- One MSX cell = one half-width character: in 40-column mode (port 30h
  80CM = 0) the TSP doubles a character's 8 dots over an even and the next
  odd column holding the same code (manual 4.2.6), so the 188 characters
  give 376 cells, enough for 256 patterns. Colours: attribute mode 0,
  foreground and background per character, as Graphics I's per 8
  patterns. Sprites are always above text (manual 4.1.3).
- The TSP counts rasters at the monitor's rate: 400 a frame on a 24 kHz
  monitor (vaeg's VA and VA2; the BIOS's split screen 0 has RH = 400, 16
  rasters a line), 200 on 15 kHz. A cell is 16 rasters (each pattern row
  twice) or 8. PCGTEST picks it from the BIOS's split screen heights.
- PCGTEST (build/dist/pcgtest.d88, `tools/build_pcg.py`) shows the 256
  patterns over GVRAM squares with two sprites, the status in hex; keys
  1-5 switch 80CM, ANKM, BIOS/direct writes, the raster offset and 8/16
  rasters a line; ESC or Q puts the gaiji RAM back from GAIJI.BAK (saved
  only when absent, so a reset keeps the original) and exits.
- vaeg, 2026-10-21: the patterns show, 40-column doubling and raster
  offset as expected, the read-back matches the layout above (status 01),
  ANKM = 1 shows only rows 0-7 of a 16-raster character, the restore
  leaves the gaiji RAM as it was.
- PC-88VA and PC-88VA2, 2026-10-21 (photographs, disk SHA-256 06ebbe03...):
  both 15 kHz, 200 rasters (status 07: 8 rasters a line); the 256
  patterns show in 40-column mode with their colours, the opaque
  backgrounds and the sprites above; the read-back is vaeg's layout
  (status 01); direct byte writes to the gaiji RAM show at once (the row
  6 dots); 80 columns show each half twice. The GVRAM squares behind were
  garbage: PCGTEST wrote back port 153h as read before the graphics BIOS
  set GMSP (single-plane writes), so its GVRAM writes were multiplane;
  fixed (153h read again after the graphics set-up).
- PC-88VA and PC-88VA2, 2026-10-21, disk SHA-256 b542573e...: the GVRAM
  squares show, and the cells sit exactly on them (a cell in the colour
  of the square under it disappears whole) with raster offset 4: MSX line
  0 on graphics line 4 as in msx88va. The probe passes on both.
- Screen modes of the 18 test titles in vaeg (DUMP_VRAM, R0/R1 at the
  title and three times in play):

  | Mode in play | Titles |
  |---|---|
  | Graphics I | Bosconian, Dig Dug, King & Balloon, Pac-Man, Rally-X, Binary Battle, Shift, U-boat Killer; Mappy (title only: play not reached in vaeg) |
  | Graphics II | Galaga (Graphics I title), Galaxian, Star Force, Star Soldier, Mix, The Drop of Abu-Cymbel, GS Soccer, Zxetris, Terminal Run |

  So the gaiji cells would serve half of them, Bosconian among them; the
  Graphics II titles keep the GVRAM renderer.

### In the MSX program (`src/msx/msx.asm`, `src/dos/msxcom.asm`)

- MSX.COM saves the gaiji area to GAIJI.BAK before it starts the program
  (kept when it exists: the copy from before the first run stays) and
  then sets `pcg_ok` in the program's header; when GAIJI.BAK cannot be
  written (a protected disk) it says so and the program draws Graphics I
  in GVRAM as before. `MSX /N` does not touch the gaiji RAM; `MSX /R`
  writes GAIJI.BAK back, deletes it and returns to DOS (the program itself
  never returns, and AUTOEXEC.BAT runs MSX: `.` or ESC in the menu returns
  to DOS for it; vaeg's headless input does not reach DOS's AH = 08h with
  ESC, its debug script's `input-line .` does). The probe's layout and split screen are used as they
  are: TVRAM frame 6000h (27 rows of 80 columns), split screen 0, MSX row
  r on frame row r + 1 at column 8 + 2 * column, raster offset half a
  line, DSPDEF with 8 or 16 rasters a line (from the BIOS's split screen
  heights), port 30h = 0 (40 columns), port 148h = 03h.
- `render_setup` picks `loop_pcg` for Graphics I when `pcg_ok` was set.
  The GVRAM picture is then the backdrop; a cell is its code (table
  `pcg_code`) in two columns and its attribute: foreground colour 0 is
  replaced by the backdrop, background 0 is the TSP's transparent colour,
  which shows the backdrop. Leaving Graphics I blanks the frame (codes
  and attributes; an attribute left behind is an opaque background over
  the next mode's picture), and so does an MSX reset.
- Patterns: a pattern written changes its glyph only (`pcg_glyphs`, at
  the pass start, the flags found by REPE SCASB; 8 byte writes, 16 on a
  400-raster screen); every glyph again only on entering the mode or a
  move of the pattern table, not on a backdrop change. Colours: a shadow
  of the 32 colour bytes, so a colour group counts only when its byte
  changed (Bosconian rewrites its colour table with the same values).
  Cells: the whole pass in one call, no budget; after a table flip with
  no colour change the names are compared with the shadow by REPE CMPSW
  and only the cells that differ are drawn (`pcg_cell`, ~150 cycles);
  otherwise the cell loop's rules (rows without a written name skipped).
- A table flip (`render_flip`) must make every row checked: the GVRAM path
  did so through `any_pend`, set for pattern flags too; the PCG path
  rebuilds `any_pend` from the colours, which left rows unchecked after a
  name table flip (Rally-X showed two stale rows) until `flipped` was
  added.
- For both paths: `diff8` compares a whole table with REPE CMPSW, a table
  compared with itself is skipped, and a pass start copies only the rows'
  flags when no pattern or colour flag is set (and in Graphics I only the
  first 256 pattern and 32 colour flags).
- vaeg, 2026-10-22, VA2, 24 kHz (16 rasters a line) and 15 kHz
  (`--cfg` with `Monitor15kHz=true`; 8 rasters, the hardware's case): the
  18 titles look as before; the cells match the picture drawn from a VRAM
  dump (Bosconian, Dig Dug, Pac-Man, Rally-X); C-BIOS and an MSX BIOS;
  an MSX reset (TEST_RESET) blanks and redraws; `/N` draws in GVRAM; with
  vaeg's backup RAM file (`--bkupmem`) a run of the 18-title disk with
  Bosconian, then a second run with `.` in the menu and `MSX /R`, leave
  B0820h-B1FBFh exactly as before and GAIJI.BAK deleted (the boot ROM itself rewrites
  B0800h-B081Fh and memory switches 1FC6h, 1FC7h, 1FCDh at every start).
  The text looks brighter than GVRAM in vaeg's screenshots, which draw a
  200-line graphics screen with dark scan lines.
- VRTC handler, vaeg VA2, 40 frames of play, cycles (frame 141 560):

  | Title | Before (mean / max) | Gaiji cells (mean / max) |
  |---|---|---|
  | Bosconian | 40 800 / 84 600 | 31 500 / 81 800 |
  | Dig Dug | 37 000 / 40 800 | 33 300 / 34 900 |
  | Rally-X | 54 300 / 82 400 | 29 900 / 74 400 |

  The rendering itself: Bosconian 19 200 -> 11 300, Dig Dug 9 300 ->
  5 600, Rally-X 42 300 -> 17 600 (mean). A first version that kept the
  cell loop with a 768-cell budget and rewrote all glyphs on every full
  redraw was slower than GVRAM (Bosconian up to 147 000, a VRTC missed).
  The remaining peaks are a table flip (diff8 and flags, ~27 000) in the
  same frame as a sprite pattern table move (34 500). Hardware: pending.

### Frame skipping and the settings page (F10)

- The VRTC handler draws the picture (`render_step`, `sprite_step`) only
  in some frames (`draw_this`); the keyboard, the frame flag, the sprite
  flags and the Z80's interrupt are every frame, so a game keeps its
  speed and gets the drawing time of the frames skipped. `sprite_step`
  still runs in a skipped frame when the sprite set-up changed (R1, R5,
  R6): the flags need the current tables. Modes: AUTO (the default) skips
  a frame when the game is late, i.e. the frame flag is still set with
  R1's IE on (the Z80 has not taken the last frame's interrupt), at most
  two in a row; EVERY FRAME; 1/2; 1/3. pc88va-galaga's DRAW AUTO runs the
  render as a thread in the idle time instead; here the render is part of
  the VRTC handler, so skipping it is the simple form.
- F10 (port 0Dh bit 4, or 0Ch bit 4 as vaeg has it, as in pc88va-galaga)
  opens a settings page and pauses the MSX inside the VRTC handler: SSG
  levels 0, the sprite descriptors off, the gaiji cells blank, the page
  in GVRAM with the MSX ROM's font (CGTABL, word 0004h of the main ROM),
  a VRTC waited for on port 40h bit 5. Items: Draw (the modes above) and
  Gaiji cells (on/off, only with GAIJI.BAK); it shows the game frames
  (interrupts taken) and the pictures drawn in the last second. F10 again
  clears GVRAM and redraws in full. The settings sit before `vars`, so an
  MSX reset keeps them. `--define TEST_KEYS`: M also acts as F10 (vaeg's
  `@hold` cannot hold F10; its inputs count from frame 600).
- vaeg, 2026-10-22, VA2: the page opens, changes and closes in play
  (Bosconian, Star Force); 1/2 shows 60 game frames and 30 pictures a
  second; Gaiji cells off switches Bosconian to GVRAM tiles; six titles
  look as before with C-BIOS and an MSX BIOS. In vaeg these games are
  never late, so AUTO draws every frame there; whether it helps on the VA
  is for the hardware.

## Disks (MS-DOS 4.0)


- Every disk is msdos4-va.2 (`msdos4-pc88va-2hd.d88`, MIT licence) with
  files added (`tools/dosdisk.py`, vaeg's `pcengine_disk.py`); the first
  disks of M01-M04 were self-booting (an IPL in sector 0, now removed).
- `src/dos/msxcom.asm` is the loader. MS-DOS 4.0 loads a .COM at 1DDBh;
  the loader checks that it ends below BASE (3000h) and that DOS leaves
  memory up to the program's MEMORY_TOP (its header), copies its payload
  to BASE:0000 and jumps there. The program does not return.
- MSX.COM (`tools/build_dos.py`) also reads CBIOS_M1.ROM and
  CBIOS_L1.ROM (C-BIOS 0.29a as released) from the current directory,
  checks and applies the patch table of `tools/cbios.py` (old bytes,
  new bytes), reads the cartridge (the argument, else the one *.ROM
  file other than CBIOS*, a menu for several, none: C-BIOS alone; 8 KiB
  mirrored, 16 or 32 KiB from page 1) and sets `cart_pages` in the
  program's header.
- `build/dist/msx88va.d88` (distributable): MS-DOS, MSX.COM, the C-BIOS
  files and CBIOS.TXT, MSX.TXT, LICENSE.TXT, AUTOEXEC.BAT running MSX.
  `build/private/` holds disks with cartridges (never distributed).
  `add_files.py` adds files to a disk image. `build/dist/m01test.d88` is
  the M01 probe as M01TEST.COM. vaeg (2026-10-18): both boot; MSX runs
  a cartridge from the menu.
