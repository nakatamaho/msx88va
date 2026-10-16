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
