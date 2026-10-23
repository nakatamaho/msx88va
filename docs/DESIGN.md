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
  MS-DOS with BASE 3000h, see "Disks"): code BASE (28 KiB since M05),
  C-BIOS main ROM BASE+700h, logo ROM +F00h, cartridge +1300h (slot 1
  from page 1), the Z80's 64 KiB +2300h, slot-3 RAM +3300h, VRAM +4300h,
  the Graphics II cell images +4700h (24 KiB; until then an FFh page of
  16 KiB, now an empty page is filled with FFh when selected), native
  stack +4D00h (8 KiB), the variables' start-up copy +4F00h (1 KiB), up
  to +4F40h = 7F40h: below 8000h, the top of the
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
- Sprite flags with many sprites: with five or more, `collide_j` asked
  `rank_j` for every row of every pair how many earlier sprites cover the
  row (each a call of `sprite_rows`): cubic in the sprites. Star Force
  firing (vaeg, VA model; `--define TEST_FIRE` presses SPACE and trigger
  A four frames in eight) took up to 284 000 cycles in `sprite_flags`
  (82 000 on average), two VRTCs missed: the game at a third of its
  speed. Now `flags_compute` takes the sprites in order and adds each
  one's rows to `f_cnt[row]` after testing it, so the rank is a table
  look-up: at most 71 000, about 10 000-25 000 on average, no VRTC missed.
  Checked against the TMS9918's rules computed from VRAM dumps (DUMP_VRAM
  now also stores f_hit and f_five at GVRAM C00Ah): 115 frames of four
  titles, 65 with five or more sprites, 34 with a collision, all equal.
- The fifth sprite comes from the same count: `f_cnt` starts at -5 a row,
  so the sprite whose count makes a row 0 is that row's fifth, and the
  topmost such row gives f_five (`fifth_sprite` and its difference array
  of 193 words are gone). With fewer than five sprites the loop stops at
  the first collision. 180 frames of six titles (160 with five or more
  sprites, 74 with a collision) equal to the TMS9918's rules.
- `sprite_step` returns at once when no attribute table byte, sprite
  pattern or sprite register was written since the last time
  (`spr_dirty`, set with f_dirty); the written patterns are found with
  REPE SCASB. (Building the descriptors in main RAM and writing only the
  changed words was slower in vaeg for titles that rewrite the table
  every frame: dropped.)
- `kbd_scan` maps the VA ports to the MSX matrix only when one of the 15
  differs from the last frame (5 700 -> 890 cycles; not with TEST_FIRE).
- VRTC handler, vaeg VA model, 40 frames of play from frame 3000, mean
  cycles (before -> after these three): Antarctic Adventure 33 400 ->
  25 300, Bosconian 47 200 -> 39 300, Dig Dug 38 000 -> 25 500, Pac-Man
  35 200 -> 23 600, Rally-X 27 700 -> 18 700, Star Force 41 400 ->
  28 900, Star Soldier 32 300 -> 24 500. Bosconian's sprite_step (15 700)
  is mostly pattern conversion: it moves its sprite pattern table every
  four frames, about 8 patterns converted a frame.
- Trapped I/O of the 19 titles (MSX BIOS, vaeg VA model, play): Terminal
  Run 121 a frame (unrolled OUTI to the VDP, PSG register pairs),
  Antarctic Adventure 95 (its own VRAM loops and address set-up), GS
  Soccer 42 (a byte write as IN 99h, OUT 99h twice, OUT 98h), Abu-Cymbel
  27 and Shift 27 (PSG register loops), Star Soldier 11 (RAM `OUT
  (98h),A; RET` from a `LD A,C; CALL; DJNZ` run), Star Force 2.4, the
  others none. On the VA (~200 us a trap) Terminal Run and Antarctic
  Adventure lose more than a frame's time to traps.
- More done in one trap, all by the code's shape (no title's addresses,
  no byte of a game changed): `out_loop` also takes `LD A,r; CALL P;
  DJNZ` (B - 1 more bytes of A) and the loop around the OUT `LD A,(HL);
  OUT (98h),A; INC HL; DEC BC; LD A,B; OR C; JR NZ` (HL past, BC = 0, A
  = 0, Z and P set); `trap_ed` runs the following OUTI, INI... while the
  next instruction is the same (unrolled transfers); `out_follow` runs
  after any trapped OUT (n),A the code that follows while it is LD r,r',
  LD r,n, LD r,(HL), INC/DEC of BC, DE, HL or OUT (n),A to a trapped port
  (none sets a flag; at most 16), so a register and its data write take
  one trap. Traps a frame: Terminal Run 121 -> 37, Antarctic Adventure 95
  -> 46, Star Soldier 11 -> 4, Shift 27 -> 20, GS Soccer about half; the
  19 titles look as before with both BIOSes. Left: PSG register loops
  with INC A; CP n; JR NZ between the writes, and returns (RET, POP AF)
  between an address set-up and its data write: they need flags, a Z80
  interpreter for a few instructions.
- `z80_follow` (in place of out_follow): after any trapped I/O
  instruction the following Z80 code is interpreted while it is made of
  LD (registers, (HL), (BC), (DE), (nn), 16-bit immediates), INC/DEC (r,
  (HL), rr), ADD/SUB/AND/XOR/OR/CP (r, (HL), n), CPL, SCF, CCF, JR/JP
  (cc), DJNZ, CALL, RET (cc), PUSH/POP, DI, EI, RES/SET b,r, IN A,(n),
  OUT (n),A and OUTI to the trap's ports, and reaches more I/O within 12
  instructions (counted again after each I/O, 256 at most in one trap);
  an OUT (98h),A tries out_loop. The flags are the uPD9002's (vaeg
  docs/modernization/uPD9002-zex-results.md R1-R11): F is the PSW's low
  byte (S Z - H - P/V N C), bits 5 and 3 always 0, AND leaves H = 0,
  CPL/SCF/CCF change no other flag, INC/DEC/ADD/SUB/CP as the Z80 (P/V
  from the V30's OF), logic P/V parity. ADC, SBC, rotates, DAA, BIT, the
  index registers and block moves stop it (the uPD9002 runs them).
- Checked with `tools/follow_cart.py`: a generated test cartridge runs 47
  snippets after a trap, each with four AF values, on msx88va with
  z80_follow and with `--define TEST_NOFOLLOW` (every I/O trapped alone,
  the rest run by the uPD9002 in vaeg): registers, flags, SP, memory and
  VRAM equal in all 188 cases (about 13 000 instructions interpreted).
  It found a bug first: `zf_pop` used BX, which held the register to pop
  into, so POP HL acted as POP AF and C-BIOS hung at its slot switch.
- Traps a frame in play (vaeg, VA model, MSX BIOS), before out_loop's
  additions -> after them -> with z80_follow: Terminal Run 121 -> 37 ->
  4.3, Antarctic Adventure 95 -> 46 -> 13, GS Soccer about 44 -> 22 -> 4,
  Abu-Cymbel 27 -> 27 -> 1, Shift 27 -> 20 -> 8, Star Soldier 11 -> 4 ->
  3.6; z80_follow interprets up to about 260 instructions a frame. The
  19 titles look as before with both BIOSes. Terminal Run and Antarctic
  Adventure still take only about 0.8 VRTCs a frame in vaeg.
- Why: both do their frame's work with interrupts disabled (Antarctic
  Adventure in its interrupt handler, the main program `EI; JR $`;
  Terminal Run between HALTs); a frame whose work takes more than one
  frame loses the next VRTC (gaps of exactly two frames). Antarctic
  Adventure's handler in vaeg (VA model, 40 times from frame 3000): with
  z80_follow median 61 900 cycles, max 299 000, 3 over a frame; without
  (be4442c) median 34 900, max 69 500, none over. z80_follow cost more
  than it saved: an interpreted instruction takes about 120 cycles, a
  trap's own handler about 370 (vaeg; its trap entry is cheap), and after
  an I/O instruction with no more I/O near, up to 12 instructions were
  interpreted for nothing (340 a frame in Antarctic Adventure).
- `zf_worth`: z80_follow goes on after an I/O instruction only when the
  next 24 bytes (and as many from a RET's return address) hold an I/O
  opcode with a trapped port, or a jump or DJNZ back over the I/O
  instruction (a loop around it); about 250 cycles. Antarctic Adventure:
  interpreted 340 -> 134 instructions a frame, traps 17 -> 15.5.
- The balance on the hardware is not known: HANDOVER-speed.md has a trap
  at ~45 us in vaeg and ~190 us on the PC-88VA2, but the V30 code itself
  may be as much slower there, which would make interpreting no better.
  So the F10 page has "I/O follow" ON/OFF (follow_on, kept over an MSX
  reset) and shows the I/O traps of the last second, for a comparison of
  game frames on the machine. `--define TEST_FOLLOWALL` skips zf_worth
  (tools/follow_cart.py uses it; 188 of 188 cases equal again, the EI;
  DI snippet replaced by DI: natively the VRTC could come in after EI).

### Scrolling by a row with frame buffer 2

- Graphics screen 0 has sub-screens 0, 2 and 3 from the top, each with
  its own frame buffer (manual 4.5.5; ports 200h + 20h * n: FSA +00h/02h,
  FBW +04h, FBL +06h (lines - 1), OFY +0Ch, DSA +0Eh/10h, DSH +12h, DSP
  +16h), and wraps vertically within FBL. vaeg models the chain 0 -> 2
  -> 3 by DSP and DSH (vram/makegrphva.c).
- Star Force scrolls by writing its name table a row down (rows 1-23,
  row 0 the score), about 540 names over a few frames. A pass start that
  finds rows b + 1 .. 23 holding (28 of 32 cells) what the shadow had for
  rows b .. 22 shows rows b .. 23 from a ring (ring_seg: 64 KiB above
  the frame buffer, 8 * (24 - b) lines) through frame buffer 2 at DSP
  PICTURE_Y + 8b, frame buffer 0 cut to DSH PICTURE_Y + 8b, and moves the
  ring a row up (OFY and DSA, word writes): the shadow rows move with it
  and only row b (new) and, in Graphics II, rows 8 and 16 (now in another
  third) are drawn. `row_at` gives the cell loop each row's segment and
  address; clear_picture clears the ring too. The first scroll sets the
  ring up (a full redraw); a band that starts lower than the ring's (a
  rewrite caught half done) is drawn as usual, not set up again. A
  rewrite of 12 rows or more waits for a frame without VRAM writes (at
  most 4) so that the check sees the whole step. Off on a full redraw,
  the settings page (which is drawn in frame buffer 0) and an MSX reset;
  F10 "HW scroll" switches it off (scr_allow).
- vaeg (VA model, Star Force, play): the shown picture (frame buffer 0
  rows < b, the ring for the others) against the picture computed from
  the VRAM dump (DUMP_VRAM also stores the ring's state at C00Ch-C013h),
  40 frames: equal in every frame without a pass under way or a rewrite
  waited for; the band stays at b = 1. Graphics II cells drawn a frame
  22.6 -> 9.0, scrolls about every 12 frames, render_step's mean and max
  about as before (the check compares rows by REPE CMPSW first). No other
  of the 19 titles scrolls this way (no step, no set-up). On the
  hardware: not yet tried.

### The measuring cartridge (`src/cart/bench.asm`, BENCH.ROM)

- On every disk (the distributed one too: our own code), built by
  build_dos.py with z80asm. MSX.COM now always shows the menu when there
  is a *.ROM file (BENCH.ROM is key 1, the cartridges follow).
- Ten tests (see the file's header), each a chunk of 256 operations or
  one block operation repeated for 120 frames, 8 rounds (about 4
  minutes); the I/O tests with I/O follow off and on. The screen shows
  operations per frame, the median of the rounds so far and the spread
  (max - min) / median. The frame is msx88va's VRTC count, read through
  ports 96h/97h (register 0 'V', 1-2 the VRTC count, 3 follow_on, read
  and written, 4-5 the trap count, 6 ram_slot, 7 the gaiji line height);
  elsewhere JIFFY.
- It found two bugs. (1) A trap runs with interrupts off and returns
  after the I/O instruction; z80_follow stopped at the next I/O
  instruction, so in code made of I/O the Z80 trapped again at once and
  the VRTC, which the VA requests only for a while, was lost: with I/O
  follow on, OUT (A0h),A; DJNZ took 8 of 100 VRTCs in vaeg (so the
  "faster" readings of z80_follow earlier were partly frames not
  counted, and the Antarctic Adventure and Terminal Run misses partly
  this). z80_follow now opens a window (STI; NOP; CLI) before every
  instruction it interprets, and trap_ed between the bytes of a repeated
  block instruction (an OTIR of 256 bytes lost 77 of 100). (2) Sprites
  were shown in text mode, where the TMS9918 has none; sprite_table and
  sprite_flags now treat text mode as display off, and R1's M1 bit
  rebuilds the descriptors.
- vaeg, VA model, 8 rounds, spread 0-1 % (per frame; C-BIOS / MSX BIOS):

  | Test | follow off | follow on |
  |---|---|---|
  | Z80 DJNZ | 9 779 / 9 990 | |
  | Z80 9 instr | 2 925 / 2 989 | |
  | OUT A0 | 482 / 484 | 346 / 354 |
  | OUT A0 + 8 instr | 433 / 435 | 48 / 49 |
  | IN A2 | 442 / 452 | 326 / 337 |
  | OUT 98 VRAM | 226 / 228 | 188 / 192 |
  | OTIR 256 | | 1.5 / 1.5 |
  | LD/OUT/JR 256 | | 12.5 / 12.7 |
  | WRTVRM (BIOS) | | 207 / 212 |
  | LDIRVM 256 | | 17.4 / 17.7 |

  So in vaeg a trap (about 290 cycles with the DJNZ, of 141 560 a frame)
  is cheaper than interpreting: about 270 cycles an interpreted
  instruction. On the hardware a trap is several times dearer (HANDOVER:
  ~190 us on the VA2); the cartridge's photograph from the VA and VA2
  decides I/O follow's default and zf_worth's reach. An OTIR to 98h
  costs about 370 cycles a byte (port_out and mark_addr each byte)
  against the out_loop copy's 44: a candidate for the same bulk copy.
- PC-88VA and PC-88VA2, 2026-10-23 (photographs), operations per frame,
  median of 8 rounds, spread 0-3 % (VA MSX BIOS / VA2 MSX BIOS / VA
  C-BIOS / VA2 C-BIOS):

  | Test | follow off | follow on |
  |---|---|---|
  | Z80 DJNZ | 5 527 / 6 579 / 5 374 / 6 400 | |
  | Z80 9 instr | 2 816 / 2 946 / 2 737 / 2 867 | |
  | OUT A0 | 184 / 196 / 186 / 197 | 130 / 134 / 127 / 130 |
  | OUT A0 + 8 instr | 181 / 192 / 181 / 193 | 19.5 / 20.0 / 19.0 / 19.6 |
  | IN A2 | 171 / 181 / 169 / 181 | 125 / 128 / 119 / 124 |
  | OUT 98 VRAM | 79 / 84 / 80 / 85 | 70 / 72 / 69 / 71 |
  | OTIR 256 | | 0.5 (all four) |
  | LD/OUT/JR 256 | | 5.9 / 6.1 / 5.7 / 6.0 |
  | WRTVRM (BIOS) | | 79 / 82 / 73 / 76 |
  | LDIRVM 256 | | 9.0 / 9.5 / 8.7 / 9.2 |

  I/O follow loses on the hardware as in vaeg: an interpreted
  instruction costs about as much as a trap (OUT A0 + 8 instr: 9-10
  times slower with it). Its default is now off (F10 can turn it on).
  An OTIR of 256 bytes takes two frames, 12-18 times an out_loop copy or
  LDIRVM of the same bytes; an OUT (98h) costs 2.3 times an OUT (A0h)
  (mark_addr). The VA2 is about 6 % faster on traps and 19 % on Z80
  code; vaeg is about 2.6 times the VA on traps, 1.5-1.8 times on Z80
  code: estimates from vaeg are to be divided so.
- `block_vdp`: an OTIR, or a run of identical OUTIs, to port 98h copies
  its bytes from Z80 HL to VRAM at once and marks them by one
  vram_written (OTIR: B bytes, 0 = 256, then B = 0, Z = 1; n OUTIs: B -
  n, Z from B; HL and the PC past). Not with TEST_NOFOLLOW, so that
  tools/follow_cart.py checks it: OTIR of 32 and of 256 bytes and five
  OUTIs with B = 3 added, 200 of 200 cases equal. vaeg (VA model):
  OTIR 256 1.5 -> 16.7 a frame (BENCH.ROM); Terminal Run 0.98 VRTCs a
  frame in play (0.79 before, with I/O follow on); the 19 titles look as
  before with both BIOSes.
- PC-88VA and PC-88VA2, 2026-10-23 (photographs, disk ba415be2...),
  I/O follow off, VA MSX BIOS / VA2 MSX BIOS /
  VA C-BIOS / VA2 C-BIOS: OTIR 256 7.9 / 8.3 / 8.1 / 8.4 a frame (0.5
  before: 16 times), about the LDIRVM rate (8.6 / 9.0 / 8.8 / 9.1);
  LD/OUT/JR 256 7.6 / 7.9 / 7.8 / 8.1 (5.9-6.1 before, measured with I/O
  follow on); the other tests as before within 1-2 %.
- A trapped OUT (98h),A in vaeg (VA model, cycles of the handler):
  trap entry to vdp_data_w 89, mark_addr 116, out_loop 115 (it saved all
  registers before looking at the code), 487 in all. Now out_loop looks
  first at the byte after the OUT (RET, or INC HL; DEC BC) and returns at
  once otherwise (75); mark_addr checks only the tables on the written
  byte's 256-byte page (`mark_pages`, 1 patterns, 2 colours, 4 names, 8
  sprite patterns, 10h attributes, rebuilt by `mark_rebuild` after
  render_setup and sprite_setup) and finds the name row by a shift but in
  text mode (40 a write outside the tables, one check instead of five
  inside); 366 in all. BENCH.ROM in vaeg: OUT 98 VRAM 228 -> 288 a frame,
  WRTVRM 213 -> 245. Checked: the GVRAM picture against the VRAM dump in
  30 frames of each of the 18 game titles (Graphics I with MSX /N), equal
  whenever nothing was pending, as before; the sprite flags equal in all;
  tools/follow_cart.py 200 of 200. The code area grew to 28 KiB (the
  DUMP_VRAM and PROFILE builds no longer fitted 24 KiB).
- PSG pitch (maintainer, vaeg, 2026-10-23: Star Force higher than an
  MSX's on video). The SSG of the YM2203 at 3.9936 MHz runs at half the
  master clock with the prescaler at 2Dh: a tone is 124800 / TP Hz
  (MAME's ymfm, PMD's tone tables, vaeg; pc88va-galaga's DESIGN), not
  62400 / TP as M02 assumed; the VA2's YM2608 at twice the clock divides
  by two more (ymfm). So every PSG period was scaled by 62400 / 111861
  and the music played an octave high. Now by 124800 / 111861 (1 + 7581
  / 65536, rounded; tone periods clamped to 4095, noise to 31): MSX TP
  254 (440 Hz) is written as 283 (441 Hz). The hardware's pitch is still
  to be heard.
- Sprite flicker (maintainer, vaeg: Dig Dug's rocks, Pookas and Fygars
  blink, Pac-Man's and Star Force's sprites do not). The game shows two
  sets of sprites in turn, one each frame (TVRAM's descriptors at every
  VRTC alternate between sprites 0, 10, 12, 20-31 and 0-12, 20, 22),
  as TMS9918 games do with more than four sprites a line; the same in
  every M05 build from da85b69 on. On a display whose rate is not the
  VA's the alternation can beat into a slow blink. A skipped frame left
  the descriptors as they were, so one set stayed two frames: now only
  the background is skipped, sprite_step runs every frame.

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
