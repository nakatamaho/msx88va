; Copyright (c) 2026 Nakata Maho
;
; Redistribution and use in source and binary forms, with or without
; modification, are permitted provided that the following conditions
; are met:
; 1. Redistributions of source code must retain the above copyright
;    notice, this list of conditions and the following disclaimer.
; 2. Redistributions in binary form must reproduce the above copyright
;    notice, this list of conditions and the following disclaimer in the
;    documentation and/or other materials provided with the distribution.
;
; THIS SOFTWARE IS PROVIDED BY THE AUTHOR "AS IS" AND ANY EXPRESS OR
; IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
; OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
; IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
; INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
; BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF
; USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
; ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
; (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
; THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
;
; MSX: an MSX1 in the uPD9002's Z80-compatible mode (docs/DESIGN.md).
;
; Loaded to BASE:0000 by MSX.COM (src/dos/msxcom.asm) under MS-DOS 4.0,
; which also reads the C-BIOS main ROM to MAIN_SEG, its logo ROM to
; LOGO_SEG and an optional cartridge to CART_SEG, patches C-BIOS
; (tools/cbios.py), and sets cart_pages (16 KiB pages from page 1) in the
; header below.
;
; The Z80 sees one 64 KiB segment (Z80SEG). Writes to port A8h copy the
; selected slots' pages into it; RAM pages are copied back to their slot-3
; store (RAMSEG; slot 3, or slot 0 for an MSX BIOS) first. The I/O trap catches ports 90h-99h (printer,
; VDP) and A0h-ABh (PSG, PPI); C-BIOS's VDP, PSG and keyboard routines call native
; code directly (CALLN, tools/cbios.py). The VRTC interrupt reads the VA
; keyboard into the MSX key matrix, sets the VDP's frame flag, redraws the
; changed cells of the picture from the emulated VRAM (Graphics I as gaiji
; characters on the TSP's text screen when MSX.COM saved the gaiji RAM),
; and injects the Z80's mode 1 interrupt while the VDP's interrupt line is
; active.
;
; HELP (VA keyboard) resets the MSX. F10 opens the settings page (frame
; skipping, the gaiji cells) with the MSX paused.

		cpu	186
		org	0

%ifndef BASE
BASE		equ	3000h		; where MSX.COM puts this program
%endif

CODE_BYTES	equ	7000h		; this program, padded
MAIN_SEG	equ	BASE + 0700h	; C-BIOS main ROM, 32 KiB
LOGO_SEG	equ	BASE + 0f00h	; C-BIOS logo ROM, 16 KiB
CART_SEG	equ	BASE + 1300h	; cartridge, up to 32 KiB
Z80SEG		equ	BASE + 2300h	; what the Z80 sees
RAMSEG		equ	BASE + 3300h	; slot 3: 64 KiB RAM
VRAMSEG		equ	BASE + 4300h	; 16 KiB VRAM
CACHESEG	equ	BASE + 4700h	; 24 KiB: Graphics II cell images
STACKSEG	equ	BASE + 4d00h	; 8 KiB native stack
STACK_TOP	equ	2000h
SNAPSEG		equ	BASE + 4f00h	; the variables as at the first start
SNAP_BYTES	equ	400h
MEMORY_TOP	equ	SNAPSEG + SNAP_BYTES / 16	; paragraphs used, for MSX.COM

BRKEM_VEC	equ	70h		; 40h-7Bh unused (technical manual, vector map)
CALLN_VEC	equ	71h		; C-BIOS routines done natively (tools/cbios.py)
TRAP_IN_VEC	equ	7ch
TRAP_OUT_VEC	equ	7dh
VRTC_VEC	equ	0ah
ICU0		equ	188h
ICU1		equ	18ah
TRAP_RANGE	equ	0ffe0h		; FFE0h-FFE7h: two inclusive port ranges
TRAP_CTRL	equ	0ffefh		; bit 0 IN, bit 1 OUT, bit 4 word ports

PICTURE_Y	equ	4		; MSX line 0 on VA line 4
GFX_X		equ	16		; byte offset: 32 dots for 256 dots
TEXT_X		equ	20		; 40 dots for the 240 dots of text mode
STRIDE		equ	160		; bytes per 320-dot line
MAX_TILES	equ	64		; cells drawn per VRTC at most
SCAN_MAX	equ	384		; cells checked per VRTC at most

TFRAME		equ	6000h		; TVRAM: the text frame of the gaiji cells
TFRAME_VW	equ	160		; bytes a row (80 columns)
TFRAME_ROWS	equ	27
TTABLE		equ	7f00h		; TVRAM: the text screen control tables

%macro BRKEM 1
		db	0fh, 0ffh, %1
%endmacro

		jmp	start
		align	4
header		db	'MSX88VA', 0		; checked by MSX.COM
		dw	MEMORY_TOP
cart_pages	db	0			; set by MSX.COM: 0, 1 or 2
ram_slot	db	3			; set by MSX.COM: 3, or 0 (an MSX
						; BIOS: RAM in slot 0 pages 2-3)
pcg_ok		db	0			; set by MSX.COM: 1 when GAIJI.BAK
						; holds the gaiji RAM

start:		cli
		mov	ax,cs
		mov	ds,ax
		mov	es,ax
		mov	ax,STACKSEG
		mov	ss,ax
		mov	sp,STACK_TOP
		cld
		cmp	byte [cart_pages],1	; the cartridge's pages in slot 1
		jb	.slots
		mov	word [slot_seg + 4 * 2 + 1 * 2],CART_SEG
		cmp	byte [cart_pages],2
		jb	.slots
		mov	word [slot_seg + 4 * 2 + 2 * 2],CART_SEG + 400h
.slots:		cmp	byte [ram_slot],0	; an MSX BIOS takes the first slot
		jne	.snap			; whose pages 2-3 are writable, and
		mov	ax,RAMSEG + 800h	; every slot is here: RAM in slot 0
		mov	[slot_seg + 2 * 2],ax
		mov	word [slot_seg + 3 * 8 + 2 * 2],0
		add	ax,400h
		mov	[slot_seg + 3 * 2],ax
		mov	word [slot_seg + 3 * 8 + 3 * 2],0
.snap:		push	es			; the variables as they start, for
		mov	ax,SNAPSEG		; an MSX reset
		mov	es,ax
		mov	si,vars
		xor	di,di
		mov	cx,(vars_end - vars) / 2
		rep	movsw
		pop	es
		sti
		call	zero_init
		call	screen_init
		jc	fail
		call	scr_off_ports
		call	pcg_init
		call	memory_init
		call	sound_init
		call	install
		mov	al,0			; reset: every page in slot 0
		call	ppi_a_w
		jmp	run

fail:		mov	si,s_fail
		call	puts
.halt:		hlt
		jmp	.halt

; ---------------------------------------------------------------------------
; Set-up

; 320x200 graphics, one 4-bit plane, cleared; the TMS9918 palette.
screen_init:	mov	ax,1702h		; clear the text screen
		int	83h
		mov	ax,2500h		; text cursor off
		int	83h
		mov	ah,00h			; graphics: single plane, 4 bits/pixel
		mov	bh,0a0h
		mov	bl,0ah			; 200-line rasters, 320 dots
		mov	cx,0404h
		xor	dx,dx
		int	8fh
		or	ax,ax
		jnz	.fail
		mov	di,fb_desc
		mov	ax,0100h		; frame buffer 0 of screen 0
		mov	cx,1
		int	8fh
		or	ax,ax
		jnz	.fail
		mov	di,fb_desc
		mov	ax,0700h		; its address, at fb_desc + 6
		mov	cl,0
		int	8fh
		or	ax,ax
		jnz	.fail
		push	cs
		pop	es
		mov	ax,[fb_desc + 6]
		mov	dx,[fb_desc + 8]
		cmp	dx,000ah
		jae	.cpu
		add	dx,000ah		; GVRAM-relative: GVRAM is at A0000h
.cpu:		mov	[ring_lo],ax		; the scroll ring: 64 KiB on, in
		mov	cx,dx			; GVRAM-relative bytes
		sub	cx,000ah - 1
		mov	[ring_hi],cx
		mov	bx,ax			; paragraph of the frame buffer
		shr	bx,4
		shl	dx,12
		or	bx,dx
		mov	[gvram_seg],bx
		add	bx,1000h
		mov	[ring_seg],bx
		sub	bx,1000h
		cli
		mov	dx,0153h		; system memory area: GVRAM
		in	al,dx
		and	al,0f0h
		or	al,04h
		out	dx,al
		mov	dx,0580h		; single-plane write mode: CPU data
		mov	al,10h
		out	dx,al
		mov	es,bx
		xor	di,di
		xor	ax,ax
		mov	cx,200 * STRIDE / 2
		rep	stosw
		push	cs
		pop	es
		sti
		mov	dx,0300h		; palette sets 0 and 1: TSP colours
.set:		mov	si,palette		; above the text/sprite boundary are
		mov	cx,16			; shown through set 1 in mixed mode
.colour:	lodsw
		out	dx,ax
		add	dx,2
		loop	.colour
		cmp	dx,0340h
		jb	.set
		mov	ax,0b01h		; graphics display on
		int	8fh
		clc
		ret
.fail:		stc
		ret

memory_init:	push	es
		mov	ax,RAMSEG		; RAM and VRAM: zero
		call	.zero
		mov	ax,VRAMSEG
		mov	es,ax
		xor	di,di
		xor	ax,ax
		mov	cx,2000h
		rep	stosw
		mov	ax,Z80SEG
		call	.zero
		pop	es
		ret
.zero:		mov	es,ax
		xor	di,di
		xor	ax,ax
		mov	cx,8000h
		rep	stosw
		ret

; The work areas after vars_end: zero.
zero_init:	push	es
		push	cs
		pop	es
		mov	di,vars_end
		mov	cx,(end_of_program - vars_end) / 2
		xor	ax,ax
		rep	stosw
		pop	es
		ret

install:	cli
		xor	ax,ax
		mov	es,ax
		mov	word [es:VRTC_VEC * 4],vrtc
		mov	[es:VRTC_VEC * 4 + 2],cs
		mov	word [es:TRAP_IN_VEC * 4],trap
		mov	[es:TRAP_IN_VEC * 4 + 2],cs
		mov	word [es:TRAP_OUT_VEC * 4],trap
		mov	word [es:CALLN_VEC * 4],bios_call
		mov	[es:CALLN_VEC * 4 + 2],cs
		mov	[es:TRAP_OUT_VEC * 4 + 2],cs
		push	cs
		pop	es
		mov	al,0fbh			; only VRTC from now on
		mov	dx,ICU1
		out	dx,al
		sti
		ret

; Ranges written as eight byte OUTs, as the VA2 boot ROM does.
trap_on:	mov	si,trap_ranges
		mov	dx,TRAP_RANGE
.r:		lodsb
		out	dx,al
		inc	dx
		cmp	dx,TRAP_RANGE + 8
		jb	.r
		mov	al,03h			; IN and OUT, byte ports
		mov	dx,TRAP_CTRL
		out	dx,al
		ret

; BRKEM_VEC -> Z80SEG:AX
set_entry:	push	es
		xor	bx,bx
		mov	es,bx
		mov	[es:BRKEM_VEC * 4],ax
		mov	word [es:BRKEM_VEC * 4 + 2],Z80SEG
		pop	es
		ret

run:		cli
		call	trap_on
		xor	ax,ax
		call	set_entry
		mov	ax,Z80SEG
		mov	ds,ax
		xor	ax,ax
		xor	bx,bx
		xor	cx,cx
		xor	dx,dx
		xor	si,si
		xor	di,di
		xor	bp,bp
		BRKEM	BRKEM_VEC		; the Z80 starts with DI
		jmp	$			; not reached: no RETEM

; ---------------------------------------------------------------------------
; VRTC interrupt. Frame: [bp] Z80 SP (the interrupted BP), [bp+2] IP,
; [bp+4] CS, [bp+6] PSW.

vrtc:		push	bp
		mov	bp,sp
		pusha
		push	ds
		push	es
		push	cs
		pop	ds
		inc	word [frames]
%ifdef PROFILE					; vaeg tests: the Z80 PC at
		mov	es,[gvram_seg]		; each VRTC (FFFFh: native),
		mov	di,[prof_n]		; a ring of 4096 words at GVRAM
		and	di,0fffh		; C200h
		shl	di,1
		mov	ax,0ffffh
		cmp	word [bp + 4],Z80SEG
		jne	.prof
		mov	ax,[bp + 2]
.prof:		mov	[es:0c200h + di],ax
		inc	word [prof_n]
		mov	ax,[prof_n]
		mov	[es:0c000h],ax
		push	ds			; and Z80 E380h-E47Fh at GVRAM
		mov	ax,Z80SEG		; DF00h
		mov	ds,ax
		mov	si,0e380h
		mov	di,0df00h
		mov	cx,80h
		rep	movsw
		pop	ds
%endif
		call	kbd_scan
		cmp	word [bp + 4],Z80SEG	; a reset only from the Z80 code
		jne	.no_help
		test	byte [va_keys + 0ah],08h	; HELP: MSX reset
		jz	.reset
%ifdef TEST_RESET				; vaeg tests: a reset every
		cmp	word [frames],TEST_RESET	; TEST_RESET frames (frames is
		je	.reset			; restored to 0)
%endif
		jmp	.no_help
.reset:		call	restart
		jmp	.eoi
.no_help:	call	settings_check		; F10: the settings page
		call	stats_tick
		call	draw_this		; CF: the picture skipped
		pushf
		or	byte [vstatus],80h	; the frame flag
		popf
		jc	.sprites		; skipped: the background only (a
		call	render_step		; game that shows two sets of
.sprites:	call	sprite_step		; sprites in turn must keep the
		call	sprite_flags		; turns)
%ifdef DUMP_VRAM				; vaeg tests: VRAM and the
		call	dump_vram		; registers into spare GVRAM
%endif
		cmp	word [bp + 4],Z80SEG
		jne	.eoi
		call	try_inject
.eoi:		mov	al,20h
		mov	dx,ICU0
		out	dx,al
		pop	es
		pop	ds
		popa
		pop	bp
		iret

; MSX reset (HELP), in the VRTC handler while the Z80 code is
; interrupted: the variables, memory, picture, SSG and slots as at the
; start, and the Z80 resumed (by the handler's IRET) at 0000h with every
; register 0 and interrupts disabled. Entering compatible mode again with
; BRKEM is not allowed here: this handler was entered from it. The
; descriptors are rebuilt by sprite_step. BP: the frame, DS = CS.
restart:	push	bp
		mov	ax,[gvram_seg]		; kept: set by the graphics BIOS
		push	ax
		push	es
		mov	ax,SNAPSEG
		mov	ds,ax
		push	cs
		pop	es
		xor	si,si
		mov	di,vars
		mov	cx,(vars_end - vars) / 2
		rep	movsw
		push	cs
		pop	ds
		pop	es
		call	zero_init
		call	scr_off_ports
		call	pcg_blank
		pop	ax
		mov	[gvram_seg],ax
		mov	es,ax			; the picture blank
		xor	di,di
		xor	ax,ax
		mov	cx,200 * STRIDE / 2
		rep	stosw
		call	memory_init
		call	sound_init
		mov	al,0			; every page in slot 0
		call	ppi_a_w
		pop	bp
		xor	ax,ax
		mov	[bp],ax			; Z80 SP
		mov	[bp + 2],ax		; Z80 PC
		and	word [bp + 6],0fdffh	; DI
		lea	di,[bp - 16]		; the PUSHA image: every register 0
		push	ss			; (its SP slot is not popped)
		pop	es
		mov	cx,8
		rep	stosw
		ret

%ifdef DUMP_VRAM
; VRAM at GVRAM offset 8000h, the eight registers at C000h. DS = CS.
dump_vram:	push	ds
		mov	es,[gvram_seg]
		mov	di,8000h
		mov	ax,VRAMSEG
		mov	ds,ax
		xor	si,si
		mov	cx,2000h
		rep	movsw
		pop	ds
		mov	si,vregs
		mov	cx,4
		rep	movsw
		mov	ax,[log_n]
		stosw
		mov	al,[f_hit]		; C00Ah: the sprite flags computed
		stosb
		mov	al,[f_five]
		stosb
		mov	al,[scr_on]		; C00Ch: the scroll ring's state
		stosb
		mov	al,[scr_b]
		stosb
		mov	al,[scr_phase]
		stosb
		mov	al,[scr_n]
		stosb
		mov	al,[pass_on]		; C010h: a pass under way
		stosb
		mov	al,[scr_wait]		; C011h: frames waited
		stosb
		mov	al,[vwrite]		; C012h: VRAM written since
		stosb
		push	ds			; C013h: rows written, not yet drawn
		push	cs
		pop	ds
		mov	si,row_dirty
		mov	cx,24
		xor	ah,ah
.rows:		lodsb
		add	ah,al
		loop	.rows
		pop	ds
		mov	al,ah
		stosb
		ret

log_n		dw	0
%endif

%ifdef PROFILE
prof_n		dw	0
%endif

; With the VDP's interrupt line active (frame flag and R1 bit 5) and the
; Z80's interrupts enabled: push the Z80 PC on the Z80 stack, PC = 0038h,
; DI. BP: the frame above, DS = CS. Keeps every register but AX, BX.
try_inject:	test	byte [vstatus],80h
		jz	.ret
		test	byte [vregs + 1],20h
		jz	.ret
		test	word [bp + 6],0200h
		jz	.ret
		push	es
		mov	ax,Z80SEG
		mov	es,ax
		mov	ax,[bp + 2]
		mov	bx,[bp]
		sub	bx,2
		mov	[bp],bx
		mov	[es:bx],ax
		mov	word [bp + 2],0038h
		and	word [bp + 6],0fdffh
		inc	word [injected]
		pop	es
.ret:		ret

; ---------------------------------------------------------------------------
; I/O trap (INT 7Ch, 7Dh). The saved CS:IP is at the Z80 I/O instruction
; (M01, PC-88VA2 and vaeg). Frame as for vrtc; then [bp-2] DS (the Z80
; segment), [bp-4] SI, [bp-6] BX (Z80 HL), [bp-8] AX (Z80 A in AL).

T_DS		equ	-2
T_HL		equ	-6
T_A		equ	-8
T_BC		equ	-10			; trap_ed only
T_DE		equ	-12

trap:		push	bp
		mov	bp,sp
		push	ds
		push	si
		push	bx
		push	ax
		lds	si,[bp + 2]
		mov	bx,[si]			; BL: opcode, BH: port or ED byte
		push	cs
		pop	ds
		inc	word [traps]
%ifdef PROFILE					; vaeg tests: the Z80 PC of
		push	es			; each trap, a ring of 2048
		push	di			; words at GVRAM D200h
		mov	es,[gvram_seg]
		mov	di,[traps]
		and	di,07ffh
		shl	di,1
		mov	[es:0d200h + di],si
		mov	di,[traps]
		mov	[es:0d000h],di
		push	ds			; and the Z80 code around the
		push	si			; trap, 80h bytes from PC - 40h, at
		push	cx			; GVRAM F000h (its PC at F080h)
		mov	di,0f000h
		mov	[es:di + 80h],si
		sub	si,40h
		mov	cx,Z80SEG
		mov	ds,cx
		mov	cx,40h
		rep	movsw
		pop	cx
		pop	si
		pop	ds
		pop	di
		pop	es
%endif
		cmp	bl,0d3h
		jne	.not_out
		add	word [bp + 2],2		; OUT (n),A
		mov	ah,bh
		push	bx
		call	port_out
		pop	bx
		cmp	bh,98h
		jne	.follow
		call	out_loop		; a known loop: the rest at once
		jmp	.follow
.not_out:	cmp	bl,0dbh
		jne	.ed
		add	word [bp + 2],2		; IN A,(n)
		mov	ah,bh
		call	port_in
		mov	[bp + T_A],al
.follow:	call	z80_follow		; the code up to more I/O
.done:		cmp	word [bp + 4],Z80SEG
		jne	.ret
		call	try_inject
.ret:		pop	ax
		pop	bx
		pop	si
		pop	ds
		pop	bp
		iret
.ed:		jmp	trap_ed

; After a trapped OUT (98h),A at P, in a subroutine P: OUT (98h),A; RET
; (Star Force's E407h in RAM, called once a byte): when its caller is one
; of these loops, the loop's remaining bytes go to VRAM now and the Z80
; resumes after the DJNZ with the registers as the loop leaves them (B =
; 0, HL past the bytes, A the last byte; the loop sets no flags):
;   T: LD A,(HL); CALL P; INC HL; DJNZ T   (7Eh CDh P 23h 10h d)
;   T: LD A,(HL); INC HL; CALL P; DJNZ T   (7Eh 23h CDh P 10h d)
;   T: LD A,r; CALL P; DJNZ T   (r not B or (HL): B - 1 more bytes of A)
; and, the OUT being in the loop itself (Antarctic Adventure's 44E6h):
;   T: LD A,(HL); OUT (98h),A; INC HL; DEC BC; LD A,B; OR C; JR NZ,T
; (then HL past the bytes, BC = 0, A = 0, flags of OR: Z, P).
; Found by the code's shape, not by a title's addresses. In the trap
; handler: CX = the Z80 BC, DS = CS; keeps every register but CX (BC).
out_loop:
%ifdef TEST_NOFOLLOW
		ret
%endif
		cmp	word [bp + 4],Z80SEG
		je	.z80
		ret
.z80:		push	es			; a quick look first: RET or INC HL;
		push	si			; DEC BC after the OUT, or nothing
		mov	si,Z80SEG		; to do
		mov	es,si
		mov	si,[bp + 2]
		cmp	byte [es:si],0c9h
		je	.look
		cmp	word [es:si],0b23h
		je	.look
		pop	si
		pop	es
		ret
.look:		pop	si
		pop	es
		pusha
		push	es
		mov	ax,Z80SEG
		mov	es,ax
		mov	si,[bp + 2]		; after the OUT
		cmp	byte [es:si - 3],7eh	; the loop around the OUT
		jne	.sub
		cmp	word [es:si],0b23h	; INC HL; DEC BC
		jne	.sub
		cmp	word [es:si + 2],0b178h	; LD A,B; OR C
		jne	.sub
		cmp	word [es:si + 4],0f720h	; JR NZ,T
		jne	.sub
		dec	cx			; BC - 1: the bytes left
		jz	.no			; none: the Z80 ends the loop itself
		add	si,6
		mov	[bp + 2],si		; PC after the JR
		mov	bx,[bp + T_HL]
		inc	bx			; the next byte
		mov	ax,bx
		add	ax,cx
		mov	[bp + T_HL],ax		; HL past them
		call	.vcopy
		mov	byte [bp + T_A],0	; A = B | C = 0
		and	byte [bp + 6],2ah	; Z = 1, P = 1, S = H = C = 0
		or	byte [bp + 6],44h
		pop	es
		popa
		xor	cx,cx			; BC = 0
		ret
.sub:		cmp	byte [es:si],0c9h	; RET
		jne	.no
		sub	si,2			; SI: P
		mov	di,[bp]			; Z80 SP
		mov	di,[es:di]		; DI: R, the return address
		cmp	word [es:di],1023h	; INC HL; DJNZ
		jne	.second
		mov	al,[es:di + 2]
		cbw
		add	ax,di
		add	ax,3			; T
		mov	bx,ax
		add	ax,4
		cmp	ax,di
		jne	.no
		cmp	word [es:bx],0cd7eh	; LD A,(HL); CALL P
		jne	.no
		cmp	[es:bx + 2],si
		jne	.no
		lea	dx,[di + 3]		; DX: after the DJNZ
		mov	bx,[bp + T_HL]		; BX: the next byte
		inc	bx
		jmp	.run
.second:	cmp	byte [es:di],10h	; DJNZ
		jne	.no
		mov	al,[es:di + 1]
		cbw
		add	ax,di
		add	ax,2			; T
		mov	bx,ax
		add	ax,4
		cmp	ax,di
		je	.fill
		inc	ax
		cmp	ax,di
		jne	.no
		cmp	word [es:bx],237eh	; LD A,(HL); INC HL
		jne	.no
		cmp	byte [es:bx + 2],0cdh	; CALL P
		jne	.no
		cmp	[es:bx + 3],si
		jne	.no
		lea	dx,[di + 2]
		mov	bx,[bp + T_HL]		; (HL is past the byte written)
.fill:		mov	al,[es:bx]		; LD A,r: r is not B, not (HL)
		cmp	al,79h
		jb	.no
		cmp	al,7fh
		ja	.no
		cmp	al,7eh
		je	.no
		cmp	byte [es:bx + 1],0cdh	; CALL P
		jne	.no
		cmp	[es:bx + 2],si
		jne	.no
		lea	dx,[di + 2]		; after the DJNZ
		mov	[bp + 2],dx
		add	word [bp],2		; the RET's address popped
		mov	cl,ch			; B - 1 more bytes of A
		dec	cl
		xor	ch,ch
		jcxz	.filled
		mov	al,[bp + T_A]
		push	es
		mov	di,[vaddr]
		mov	bx,di
		mov	dx,VRAMSEG
		mov	es,dx
		push	cx
.f:		and	di,3fffh
		stosb
		loop	.f
		pop	cx
		pop	es
		mov	[vahead],al
		mov	ax,di
		call	vram_written
.filled:	pop	es
		popa
		mov	ch,0			; B = 0
		ret
; CX (1-65535) bytes from Z80 BX to VRAM at vaddr; flags them. ES = Z80SEG.
.vcopy:		push	ds
		mov	si,bx
		mov	di,[cs:vaddr]
		push	di
		push	cx
		mov	ax,VRAMSEG
		mov	es,ax
		mov	ax,Z80SEG
		mov	ds,ax
.vc:		and	di,3fffh
		movsb
		loop	.vc
		mov	al,[si - 1]
		pop	cx
		pop	bx
		pop	ds
		mov	[vahead],al
		mov	ax,di
		jmp	vram_written
.run:		mov	cl,ch			; CX: the bytes left, (B - 1) mod 256
		dec	cl
		xor	ch,ch
		mov	[bp + 2],dx		; PC after the DJNZ, the RET's
		add	word [bp],2		; address popped
		mov	ax,bx
		add	ax,cx
		mov	[bp + T_HL],ax		; HL past them
		jcxz	.b0
		push	ds
		mov	si,bx			; Z80 HL.. -> VRAM vaddr..
		mov	di,[vaddr]
		push	di
		push	cx
		mov	ax,VRAMSEG
		mov	es,ax
		mov	ax,Z80SEG
		mov	ds,ax
.copy:		and	di,3fffh
		movsb
		loop	.copy
		mov	al,[si - 1]
		pop	cx
		pop	bx
		pop	ds
		mov	[bp + T_A],al		; A: the last byte
		mov	[vahead],al
		mov	ax,di
		call	vram_written
.b0:		pop	es
		popa
		mov	ch,0			; B = 0
		ret
.no:		pop	es
		popa
		ret

; After a trapped I/O instruction the Z80 code that follows runs here,
; interpreted, as long as it is made of the instructions below and reaches
; more I/O within FOLLOW_MAX instructions (counted again after each I/O
; instruction); the Z80 goes on at the first other instruction. So a loop
; of register and data writes (the PSG's A0h/A1h, the VDP's 99h/98h)
; takes one trap. The flags are the uPD9002's, which differ from a Z80's
; (vaeg docs/modernization/uPD9002-zex-results.md): F is the low byte of
; the PSW in the frame, bits 5 and 3 always 0 (R1); AND leaves H = 0 (R2);
; CPL, SCF and CCF change no other flag (R8-R10); INC, DEC, ADD, SUB, CP,
; OR, XOR as the Z80's (P/V overflow for arithmetic, parity for logic).
; Instructions: NOP; LD r,r', LD r,n, LD r,(HL), LD (HL),r, LD (HL),n,
; LD rr,nn, LD A,(BC/DE/nn), LD (BC/DE/nn),A; INC/DEC r, (HL), rr; ADD,
; SUB, AND, XOR, OR, CP with r, (HL) or n; CPL, SCF, CCF; JR, JR cc, JP,
; JP cc, DJNZ, CALL, RET, RET cc; PUSH, POP (BC, DE, HL, AF); DI, EI;
; RES, SET b,r; IN A,(n), OUT (n),A to the trap's ports; OUTI to them.
; An OUT (98h),A tries out_loop. In the trap handler (trap.follow): CX =
; BC, DX = DE, the frame's A, HL, SP, PC and F; DS = CS. Keeps every
; register but CX, DX (the Z80's), AX, BX, SI.
FOLLOW_MAX	equ	12

z80_follow:
%ifdef TEST_NOFOLLOW				; tests: every I/O trapped alone
		ret
%endif
		cmp	byte [follow_on],0	; off on the settings page
		je	.off
		cmp	word [bp + 4],Z80SEG
		je	.z80
.off:		ret
.z80:		push	es
		push	di
		mov	ax,Z80SEG
		mov	es,ax
		mov	si,[bp + 2]
		mov	byte [zf_left],FOLLOW_MAX
		mov	word [zf_all],256	; and at most this many in all
		lea	ax,[si - 2]		; (the I/O instruction, about)
		call	zf_worth
		jc	.stop
.next:		sti				; a window for the VRTC: a trap runs
		nop				; with interrupts off, and code made
		cli				; only of I/O would never let it in
		dec	word [zf_all]
		jz	.stop
		dec	byte [zf_left]
		jz	.stop
		mov	[zf_pc],si		; the instruction's start
		mov	bl,[es:si]
		xor	bh,bh
		shl	bx,1
		jmp	[cs:zf_table + bx]
.stop:		mov	[bp + 2],si
		pop	di
		pop	es
		ret

; The opcode handlers: SI at the opcode; each ends with jmp z80_follow.next
; (SI past the instruction) or .stop (SI at it).
%define ZN	z80_follow.next
%define ZS	z80_follow.stop

; Z80 register r (bits of BL & 7: B C D E H L (HL) A) <-> AH.
zf_get:		and	bx,7
		shl	bx,1
		jmp	[cs:.t + bx]
.t		dw	.b, .c, .d, .e, .h, .l, .m, .a
.b:		mov	ah,ch
		ret
.c:		mov	ah,cl
		ret
.d:		mov	ah,dh
		ret
.e:		mov	ah,dl
		ret
.h:		mov	ah,[bp + T_HL + 1]
		ret
.l:		mov	ah,[bp + T_HL]
		ret
.m:		mov	bx,[bp + T_HL]
		mov	ah,[es:bx]
		ret
.a:		mov	ah,[bp + T_A]
		ret
zf_set:		and	bx,7
		shl	bx,1
		jmp	[cs:.t + bx]
.t		dw	.b, .c, .d, .e, .h, .l, .m, .a
.b:		mov	ch,ah
		ret
.c:		mov	cl,ah
		ret
.d:		mov	dh,ah
		ret
.e:		mov	dl,ah
		ret
.h:		mov	[bp + T_HL + 1],ah
		ret
.l:		mov	[bp + T_HL],ah
		ret
.m:		mov	bx,[bp + T_HL]
		mov	[es:bx],ah
		ret
.a:		mov	[bp + T_A],ah
		ret

; F from the V30 flags of the operation just done (call right after it):
; zf_flags_log: S, Z, P (parity); H, N, C = 0. zf_flags_arith: S, Z, H,
; C, P/V = overflow; N = DL... (AL: 0 or 2 for N). zf_flags_incdec: as
; arith but C kept from F.
zf_flags_log:	lahf
		and	ah,0c4h
		mov	[bp + 6],ah
		ret
zf_flags_arith:	lahf				; AL: N (0 or 2)
		jno	.v
		or	ah,04h
		jmp	.n
.v:		and	ah,0fbh
.n:		and	ah,0d5h
		or	ah,al
		mov	[bp + 6],ah
		ret
zf_flags_incdec:
		lahf
		jno	.v
		or	ah,04h
		jmp	.n
.v:		and	ah,0fbh
.n:		and	ah,0d4h
		or	ah,al
		mov	al,[bp + 6]
		and	al,1
		or	ah,al
		mov	[bp + 6],ah
		ret

; The condition cc (bits 5-3 of the opcode in BL: NZ Z NC C PO PE P M) of
; F -> ZF (V30) set when the condition holds... returned as AL = 1/0.
zf_cond:	mov	al,[bp + 6]
		shr	bl,3
		and	bl,7
		mov	bh,bl
		shr	bl,1			; 0 Z, 1 C, 2 P/V, 3 S
		mov	ah,40h
		cmp	bl,1
		jne	.p
		mov	ah,01h
.p:		cmp	bl,2
		jne	.s
		mov	ah,04h
.s:		cmp	bl,3
		jne	.t
		mov	ah,80h
.t:		and	al,ah			; the flag
		jz	.zero
		mov	al,1
.zero:		test	bh,1			; odd: the flag set; even: clear
		jnz	.ret
		xor	al,1
.ret:		ret

zf_nop:		inc	si
		jmp	ZN
zf_ld_rr:	mov	bl,[es:si]		; 00rr0001: LD rr,nn (not SP)
		mov	ax,[es:si + 1]
		add	si,3
		cmp	bl,01h
		jne	.de
		mov	cx,ax
		jmp	ZN
.de:		cmp	bl,11h
		jne	.hl
		mov	dx,ax
		jmp	ZN
.hl:		mov	[bp + T_HL],ax
		jmp	ZN
zf_ld_bca:	mov	bx,cx			; LD (BC),A
		jmp	zf_st_a
zf_ld_dea:	mov	bx,dx			; LD (DE),A
zf_st_a:	mov	al,[bp + T_A]
		mov	[es:bx],al
		inc	si
		jmp	ZN
zf_ld_abc:	mov	bx,cx			; LD A,(BC)
		jmp	zf_ld_a
zf_ld_ade:	mov	bx,dx			; LD A,(DE)
zf_ld_a:	mov	al,[es:bx]
		mov	[bp + T_A],al
		inc	si
		jmp	ZN
zf_ld_nna:	mov	bx,[es:si + 1]		; LD (nn),A
		mov	al,[bp + T_A]
		mov	[es:bx],al
		add	si,3
		jmp	ZN
zf_ld_ann:	mov	bx,[es:si + 1]		; LD A,(nn)
		mov	al,[es:bx]
		mov	[bp + T_A],al
		add	si,3
		jmp	ZN
zf_incdec_rr:	mov	bl,[es:si]		; INC/DEC BC, DE, HL
		inc	si
		mov	al,bl
		and	al,30h
		test	bl,08h
		jnz	.dec
		cmp	al,00h
		jne	.ide
		inc	cx
		jmp	ZN
.ide:		cmp	al,10h
		jne	.ihl
		inc	dx
		jmp	ZN
.ihl:		inc	word [bp + T_HL]
		jmp	ZN
.dec:		cmp	al,00h
		jne	.dde
		dec	cx
		jmp	ZN
.dde:		cmp	al,10h
		jne	.dhl
		dec	dx
		jmp	ZN
.dhl:		dec	word [bp + T_HL]
		jmp	ZN
zf_inc_r:	mov	bl,[es:si]		; INC r
		shr	bl,3
		push	bx
		call	zf_get
		inc	ah
		mov	al,0
		push	ax
		call	zf_flags_incdec
		pop	ax
		pop	bx
		call	zf_set
		inc	si
		jmp	ZN
zf_dec_r:	mov	bl,[es:si]		; DEC r
		shr	bl,3
		push	bx
		call	zf_get
		dec	ah
		mov	al,2
		push	ax
		call	zf_flags_incdec
		pop	ax
		pop	bx
		call	zf_set
		inc	si
		jmp	ZN
zf_ld_rn:	mov	bl,[es:si]		; LD r,n
		shr	bl,3
		mov	ah,[es:si + 1]
		call	zf_set
		add	si,2
		jmp	ZN
zf_ld_r_r:	mov	bl,[es:si]		; LD r,r'
		call	zf_get
		mov	bl,[es:si]
		shr	bl,3
		call	zf_set
		inc	si
		jmp	ZN
zf_cpl:		not	byte [bp + T_A]		; R8: no flag
		inc	si
		jmp	ZN
zf_scf:		or	byte [bp + 6],01h	; R9: C only
		inc	si
		jmp	ZN
zf_ccf:		xor	byte [bp + 6],01h	; R10: C only
		inc	si
		jmp	ZN
; ALU A,r (80h-BFh) and A,n (C6h-FEh): bits 5-3 select ADD ADC SUB SBC AND
; XOR OR CP; ADC and SBC are not done.
zf_alu_r:	mov	bl,[es:si]
		call	zf_get
		mov	al,[es:si]
		inc	si
		jmp	zf_alu
zf_alu_n:	mov	ah,[es:si + 1]
		mov	al,[es:si]
		add	si,2
zf_alu:		and	al,38h			; AH: the operand
		mov	bl,[bp + T_A]
		cmp	al,00h
		je	.add
		cmp	al,10h
		je	.sub
		cmp	al,20h
		je	.and
		cmp	al,28h
		je	.xor
		cmp	al,30h
		je	.or
		cmp	al,38h
		je	.cp
		jmp	.undo			; ADC, SBC: not done
.add:		add	bl,ah
		mov	al,0
		call	zf_flags_arith
		mov	[bp + T_A],bl
		jmp	ZN
.sub:		sub	bl,ah
		mov	al,2
		call	zf_flags_arith
		mov	[bp + T_A],bl
		jmp	ZN
.cp:		cmp	bl,ah
		mov	al,2
		call	zf_flags_arith
		jmp	ZN
.and:		and	bl,ah
		call	zf_flags_log		; R2: H = 0
		mov	[bp + T_A],bl
		jmp	ZN
.xor:		xor	bl,ah
		call	zf_flags_log
		mov	[bp + T_A],bl
		jmp	ZN
.or:		or	bl,ah
		call	zf_flags_log
		mov	[bp + T_A],bl
		jmp	ZN
.undo:		mov	si,[cs:zf_pc]		; the instruction not done
		jmp	ZS
zf_jr:		mov	al,[es:si + 1]		; JR e
		cbw
		add	si,2
		add	si,ax
		jmp	ZN
zf_jrcc:	mov	bl,[es:si]		; JR NZ, Z, NC, C (20h-38h)
		and	bl,18h			; cc 0-3 in bits 4-3
		call	zf_cond
		or	al,al
		jnz	zf_jr
		add	si,2
		jmp	ZN
zf_djnz:	dec	ch
		jnz	zf_jr
		add	si,2
		jmp	ZN
zf_jp:		mov	si,[es:si + 1]
		jmp	ZN
zf_jpcc:	mov	bl,[es:si]
		call	zf_cond
		or	al,al
		jnz	zf_jp
		add	si,3
		jmp	ZN
zf_call:	mov	ax,si			; push the return address
		add	ax,3
		call	zf_push
		mov	si,[es:si + 1]
		jmp	ZN
zf_ret:		call	zf_pop
		mov	si,ax
		jmp	ZN
zf_retcc:	mov	bl,[es:si]
		call	zf_cond
		or	al,al
		jnz	zf_ret
		inc	si
		jmp	ZN
zf_push_rr:	mov	bl,[es:si]		; PUSH BC DE HL AF
		inc	si
		and	bl,30h
		mov	ax,cx
		cmp	bl,00h
		je	.p
		mov	ax,dx
		cmp	bl,10h
		je	.p
		mov	ax,[bp + T_HL]
		cmp	bl,20h
		je	.p
		mov	ah,[bp + T_A]		; AF
		mov	al,[bp + 6]
.p:		call	zf_push
		jmp	ZN
zf_pop_rr:	mov	bl,[es:si]		; POP BC DE HL AF
		inc	si
		and	bl,30h
		call	zf_pop
		cmp	bl,00h
		jne	.de
		mov	cx,ax
		jmp	ZN
.de:		cmp	bl,10h
		jne	.hl
		mov	dx,ax
		jmp	ZN
.hl:		cmp	bl,20h
		jne	.af
		mov	[bp + T_HL],ax
		jmp	ZN
.af:		mov	[bp + T_A],ah
		and	al,0d7h			; R1: bits 5, 3 read 0
		mov	[bp + 6],al
		jmp	ZN
zf_push:	mov	di,[bp]			; AX onto the Z80 stack (uses DI)
		sub	di,2
		mov	[bp],di
		mov	[es:di],ax
		ret
zf_pop:		mov	di,[bp]			; AX from the Z80 stack (uses DI)
		mov	ax,[es:di]
		add	word [bp],2
		ret
zf_di:		and	byte [bp + 7],0fdh	; IF in the PSW
		inc	si
		jmp	ZN
zf_ei:		or	byte [bp + 7],02h
		inc	si
		jmp	ZN
zf_cb:		mov	bl,[es:si + 1]		; CB: RES and SET b,r (not (HL))
		cmp	bl,80h
		jb	ZS
		mov	al,bl
		and	al,7
		cmp	al,6
		je	ZS
		push	bx
		call	zf_get
		pop	bx
		push	cx			; (CX is the Z80 BC)
		mov	cl,bl
		shr	cl,3
		and	cl,7
		mov	al,1
		shl	al,cl
		pop	cx
		test	bl,40h
		jnz	.set
		not	al
		and	ah,al
		jmp	.put
.set:		or	ah,al
.put:		call	zf_set
		add	si,2
		jmp	ZN
zf_out:		mov	ah,[es:si + 1]		; OUT (n),A
		call	zf_port
		jc	ZS
		mov	al,[bp + T_A]
		push	si
		call	port_out
		pop	si
		add	si,2
		cmp	byte [es:si - 1],98h
		jne	zf_io_done
		mov	[bp + 2],si		; a known loop, as after a trap
		call	out_loop
		mov	si,[bp + 2]
		jmp	zf_io_done
zf_in:		mov	ah,[es:si + 1]		; IN A,(n)
		call	zf_port
		jc	ZS
		push	si
		call	port_in
		pop	si
		mov	[bp + T_A],al
		add	si,2
		jmp	zf_io_done
zf_ed:		cmp	byte [es:si + 1],0a3h	; OUTI
		jne	ZS
		mov	ah,cl			; port C
		call	zf_port
		jc	ZS
		mov	bx,[bp + T_HL]
		mov	al,[es:bx]
		dec	ch
		push	si
		call	port_out
		pop	si
		inc	word [bp + T_HL]
		and	byte [bp + 6],0bfh	; Z from B, as trap_ed
		or	ch,ch
		jnz	.nz
		or	byte [bp + 6],40h
.nz:		add	si,2
		jmp	zf_io_done
; After an I/O instruction: on only when more I/O is likely near.
zf_io_done:	mov	byte [zf_left],FOLLOW_MAX
		lea	ax,[si - 2]
		call	zf_worth
		jc	ZS
		jmp	ZN

; Interpreting costs several times what the uPD9002 takes to run an
; instruction, a trap many times that: go on after an I/O instruction at
; AX only when the bytes from SI (to ZF_SCAN of them, and as many from a
; RET's return address) hold an I/O opcode with a trapped port (D3h/DBh n,
; EDh A2h-BBh), or a jump or DJNZ back to at most 64 bytes before AX (a
; loop around it). A guess from the bytes, not decoded instructions.
; CF = 1: stop. ES = Z80SEG; keeps every register but AX.
ZF_SCAN		equ	24

zf_worth:
%ifdef TEST_FOLLOWALL				; tests (tools/follow_cart.py):
		clc				; interpret whatever follows
		ret
%endif
		push	bx
		push	cx
		push	si
		mov	bx,ax			; BX: the I/O instruction
		mov	cx,ZF_SCAN
		mov	byte [zf_wret],0
.b:		mov	al,[es:si]
		cmp	al,0d3h
		je	.port
		cmp	al,0dbh
		je	.port
		cmp	al,0edh
		je	.ed
		cmp	al,10h			; DJNZ, JR, JR cc: back over BX?
		je	.rel
		cmp	al,18h
		je	.rel
		and	al,0e7h
		cmp	al,20h
		je	.rel
		mov	al,[es:si]
		cmp	al,0c3h			; JP, JP cc
		je	.abs
		and	al,0c7h
		cmp	al,0c2h
		je	.abs
		cmp	byte [es:si],0c9h	; RET: on at the return address
		jne	.n
		cmp	byte [zf_wret],0
		jne	.n
		mov	byte [zf_wret],1
		push	bx
		mov	bx,[bp]
		mov	si,[es:bx]
		pop	bx
		mov	cx,ZF_SCAN
		jmp	.b
.n:		inc	si
		loop	.b
		stc
		jmp	.ret
.port:		mov	ah,[es:si + 1]
		call	zf_port
		jc	.n
		jmp	.yes
.ed:		mov	al,[es:si + 1]
		cmp	al,0a2h
		jb	.n
		cmp	al,0bbh
		ja	.n
		jmp	.yes
.rel:		mov	al,[es:si + 1]		; the target
		cbw
		add	ax,si
		add	ax,2
		jmp	.back
.abs:		mov	ax,[es:si + 1]
.back:		cmp	ax,bx			; at or before the I/O, at most 64
		ja	.n			; bytes before it
		add	ax,64
		cmp	ax,bx
		jb	.n
.yes:		clc
.ret:		pop	si
		pop	cx
		pop	bx
		ret

; CF = 1 unless port AH is in the trap's ranges.
zf_port:	cmp	ah,90h
		jb	.no
		cmp	ah,99h
		jbe	.yes
		cmp	ah,0a0h
		jb	.no
		cmp	ah,0abh
		ja	.no
.yes:		clc
		ret
.no:		stc
		ret

%undef ZN
%undef ZS

; The handlers by opcode (ZS: stop there).
%macro ZOP 2
 %rep %2
		dw	%1
 %endrep
%endmacro
zf_table:	dw	zf_nop, zf_ld_rr, zf_ld_bca, zf_incdec_rr	; 00-03
		dw	zf_inc_r, zf_dec_r, zf_ld_rn, z80_follow.stop	; 04-07 RLCA
		dw	z80_follow.stop, z80_follow.stop, zf_ld_abc, zf_incdec_rr ; 08-0B
		dw	zf_inc_r, zf_dec_r, zf_ld_rn, z80_follow.stop	; 0C-0F
		dw	zf_djnz, zf_ld_rr, zf_ld_dea, zf_incdec_rr	; 10-13
		dw	zf_inc_r, zf_dec_r, zf_ld_rn, z80_follow.stop	; 14-17
		dw	zf_jr, z80_follow.stop, zf_ld_ade, zf_incdec_rr	; 18-1B
		dw	zf_inc_r, zf_dec_r, zf_ld_rn, z80_follow.stop	; 1C-1F
		dw	zf_jrcc, zf_ld_rr, z80_follow.stop, zf_incdec_rr ; 20-23
		dw	zf_inc_r, zf_dec_r, zf_ld_rn, z80_follow.stop	; 24-27 DAA
		dw	zf_jrcc, z80_follow.stop, z80_follow.stop, zf_incdec_rr ; 28-2B
		dw	zf_inc_r, zf_dec_r, zf_ld_rn, zf_cpl		; 2C-2F
		dw	zf_jrcc, z80_follow.stop, zf_ld_nna, z80_follow.stop ; 30-33
		dw	zf_inc_r, zf_dec_r, zf_ld_rn, zf_scf		; 34-37
		dw	zf_jrcc, z80_follow.stop, zf_ld_ann, z80_follow.stop ; 38-3B
		dw	zf_inc_r, zf_dec_r, zf_ld_rn, zf_ccf		; 3C-3F
		ZOP	zf_ld_r_r, 54				; 40-75
		dw	z80_follow.stop				; 76 HALT
		ZOP	zf_ld_r_r, 9				; 77-7F
		ZOP	zf_alu_r, 64				; 80-BF
		dw	zf_retcc, zf_pop_rr, zf_jpcc, zf_jp		; C0-C3
		dw	z80_follow.stop, zf_push_rr, zf_alu_n, z80_follow.stop ; C4-C7
		dw	zf_retcc, zf_ret, zf_jpcc, zf_cb		; C8-CB
		dw	z80_follow.stop, zf_call, z80_follow.stop, z80_follow.stop ; CC-CF
		dw	zf_retcc, zf_pop_rr, zf_jpcc, zf_out		; D0-D3
		dw	z80_follow.stop, zf_push_rr, zf_alu_n, z80_follow.stop ; D4-D7
		dw	zf_retcc, z80_follow.stop, zf_jpcc, zf_in		; D8-DB
		dw	z80_follow.stop, z80_follow.stop, z80_follow.stop, z80_follow.stop ; DC-DF
		dw	zf_retcc, zf_pop_rr, zf_jpcc, z80_follow.stop	; E0-E3
		dw	z80_follow.stop, zf_push_rr, zf_alu_n, z80_follow.stop ; E4-E7
		dw	zf_retcc, z80_follow.stop, zf_jpcc, z80_follow.stop ; E8-EB
		dw	z80_follow.stop, zf_ed, zf_alu_n, z80_follow.stop ; EC-EF
		dw	zf_retcc, zf_pop_rr, zf_jpcc, zf_di		; F0-F3
		dw	z80_follow.stop, zf_push_rr, zf_alu_n, z80_follow.stop ; F4-F7
		dw	zf_retcc, z80_follow.stop, zf_jpcc, zf_ei	; F8-FB
		dw	z80_follow.stop, z80_follow.stop, zf_alu_n, z80_follow.stop ; FC-FF
%if ($ - zf_table) != 512
 %error zf_table is not 256 entries
%endif

; Port AH, data AL. Keeps every register but AX, BX, SI.
port_out:	mov	bl,ah
		sub	bl,90h
		cmp	bl,PORTS
		jae	.ret
		xor	bh,bh
		shl	bx,1
		jmp	[out_table + bx]
.ret:		ret

; Port AH -> AL. Keeps every register but AX, BX, SI.
port_in:	mov	bl,ah
		sub	bl,90h
		cmp	bl,PORTS
		jae	io_ff
		xor	bh,bh
		shl	bx,1
		jmp	[in_table + bx]

io_ff:		mov	al,0ffh
io_none:	ret

; Ports 96h (a register number) and 97h (its value), unused on an MSX1,
; for the measuring cartridge (src/cart/bench.asm): 0 'V' (msx88va), 1
; and 2 the VRTC count (2: high byte of the count latched when 1 is
; read), 3 follow_on (also written), 4 and 5 the trap count (latched
; likewise), 6 ram_slot (0: an MSX BIOS), 7 the gaiji cells' rasters a
; line - 1 (0: not in use).
bench_sel:	mov	[bench_reg],al
		ret
bench_w:	cmp	byte [bench_reg],3
		jne	.ret
		and	al,1
		mov	[follow_on],al
.ret:		ret
bench_r:	mov	bl,[bench_reg]
		cmp	bl,7
		ja	io_ff
		xor	bh,bh
		shl	bx,1
		jmp	[cs:.t + bx]
.t		dw	.sig, .f0, .f1, .fol, .t0, .t1, .slot, .pcg
.sig:		mov	al,'V'
		ret
.f0:		mov	ax,[frames]
		jmp	.latch
.t0:		mov	ax,[traps]
.latch:		mov	[bench_latch],ax
		ret
.f1:
.t1:		mov	al,[bench_latch + 1]
		ret
.fol:		mov	al,[follow_on]
		ret
.slot:		mov	al,[ram_slot]
		ret
.pcg:		xor	al,al
		cmp	byte [pcg_on],0
		je	.ret
		mov	al,[pcg_h]
.ret:		ret

lpt_stat_r:	mov	al,0fdh			; bit 1 clear: ready
		ret

; 90h-91h: the printer, never busy, its output dropped (an MSX BIOS
; waits in LPTOUT for a printer that is ready).
PORTS		equ	1ch			; 90h-ABh
out_table	times	6 dw io_none		; 90h-95h
		dw	bench_sel, bench_w	; 96h, 97h: msx88va's own
		dw	vdp_data_w, vdp_ctrl_w
		times	6 dw io_none		; 9Ah-9Fh (not trapped)
		dw	psg_addr_w, psg_data_w, io_none, io_none
		times	4 dw io_none		; A4h-A7h
		dw	ppi_a_w, io_none, ppi_c_w, ppi_ctrl_w
in_table	dw	lpt_stat_r		; 90h
		times	6 dw io_ff		; 91h-96h
		dw	bench_r			; 97h
		dw	vdp_data_r, vdp_stat_r
		times	6 dw io_ff
		dw	io_ff, io_ff, psg_data_r, io_ff
		times	4 dw io_ff
		dw	ppi_a_r, ppi_b_r, ppi_c_r, io_ff

; ED-prefixed I/O: IN r,(C), OUT (C),r, and the block instructions; a
; repeat (INIR, INDR, OTIR, OTDR) runs to B = 0 in one trap. IN r,(C) sets
; S, Z and P; the block instructions set Z from B. Reached by a jump from
; trap, so that its pushes are at T_BC and T_DE; returns to trap.done.
trap_ed:	push	cx
		push	dx
		push	di
		push	es
		mov	[ed_op],bh
		cmp	bl,0edh
		jne	.unknown
		mov	bl,bh
		and	bl,0c6h
		cmp	bl,40h
		je	.single
		mov	bl,bh
		and	bl,0e6h
		cmp	bl,0a2h
		je	.block
.unknown:	inc	word [unknown]		; not Z80 I/O: traps off, so that
		xor	al,al			; it runs untrapped
		mov	dx,TRAP_CTRL
		out	dx,al
		pop	es
		pop	di
		pop	dx
		pop	cx
		jmp	trap.done
.single:	add	word [bp + 2],2
		mov	bl,bh			; register number
		shr	bl,3
		and	bx,7
		mov	al,[ed_regs + bx]
		cbw
		mov	di,ax			; DI: its offset from BP, 0: none
		mov	ah,[bp + T_BC]		; port: C
		test	byte [ed_op],1
		jz	.in
		xor	al,al			; OUT (C),0
		or	di,di
		jz	.out
		mov	al,[bp + di]
.out:		call	port_out
		jmp	.ret
.in:		call	port_in
		or	di,di
		jz	.flags
		mov	[bp + di],al
.flags:		or	al,al			; S, Z, P from the value; H = 0
		lahf
		and	ah,0c4h
		and	byte [bp + 6],2bh
		or	[bp + 6],ah
		jmp	.ret
.block:		mov	es,[bp + T_DS]		; the Z80 segment
%ifndef TEST_NOFOLLOW
		mov	al,[ed_op]		; OTIR or OUTI (out, HL up) to the
		and	al,09h			; VDP's data port: at once
		cmp	al,01h
		jne	.bslow
		cmp	byte [bp + T_BC],98h
		jne	.bslow
		call	block_vdp
		jmp	.ret
.bslow:
%endif
		mov	di,[bp + T_HL]
		dec	byte [bp + T_BC + 1]	; B
		mov	ah,[bp + T_BC]		; port: C
		test	byte [ed_op],1
		jz	.bin
		mov	al,[es:di]
		call	port_out
		jmp	.bhl
.bin:		call	port_in
		mov	[es:di],al
.bhl:		inc	word [bp + T_HL]	; HL + 1, or - 1 for IND, OUTD...
		test	byte [ed_op],08h
		jz	.bz
		sub	word [bp + T_HL],2
.bz:		cmp	byte [bp + T_BC + 1],0
		je	.bdone
		sti				; a window for the VRTC between
		nop				; bytes (a long OTIR would keep it
		cli				; out, and it is lost)
		test	byte [ed_op],10h	; a repeat: the next byte in the
		jnz	.block			; same trap
		and	byte [bp + 6],0bfh	; Z = 0
		jmp	.next
.bdone:		or	byte [bp + 6],40h	; Z = 1
.next:		add	word [bp + 2],2
%ifdef TEST_NOFOLLOW
		jmp	.ret
%endif
		test	byte [ed_op],10h	; a single OUTI, INI...: when the
		jnz	.ret			; next instruction is the same, it
		mov	di,[bp + 2]		; runs in this trap too (unrolled
		mov	es,[bp + 4]		; transfers)
		cmp	byte [es:di],0edh
		jne	.ret
		mov	al,[es:di + 1]
		cmp	al,[ed_op]
		je	.block
.ret:		pop	es
		pop	di
		pop	dx
		pop	cx
		jmp	trap.follow

; An OTIR, or a run of identical OUTIs (unrolled transfers), to port 98h:
; the bytes from Z80 HL go to VRAM at once (on the hardware an OTIR of 256
; bytes took two frames byte by byte, BENCH.ROM). OTIR: B bytes (0: 256),
; then B = 0, Z = 1; a run of n OUTIs: n bytes, B - n, Z from B. HL past
; the bytes, the PC past the instruction(s). From trap_ed.block (ES: the
; Z80 segment, DS = CS).
block_vdp:	mov	di,[bp + 2]		; at the ED
		test	byte [ed_op],10h
		jz	.run
		mov	cl,[bp + T_BC + 1]	; OTIR: B bytes
		xor	ch,ch
		or	cl,cl
		jnz	.otir
		inc	ch			; 256
.otir:		mov	byte [bp + T_BC + 1],0
		add	di,2
		or	byte [bp + 6],40h	; Z = 1
		jmp	.copy
.run:		xor	cx,cx			; OUTIs: as many as follow
.r:		cmp	word [es:di],0a3edh
		jne	.counted
		add	di,2
		inc	cx
		cmp	cx,256
		jb	.r
.counted:	sub	[bp + T_BC + 1],cl	; B - n
		and	byte [bp + 6],0bfh	; Z from B
		cmp	byte [bp + T_BC + 1],0
		jne	.copy
		or	byte [bp + 6],40h
.copy:		mov	[bp + 2],di
		mov	si,[bp + T_HL]
		add	[bp + T_HL],cx
		mov	ax,[bp + T_DS]
		push	ds
		mov	bx,[vaddr]
		push	bx
		push	cx
		mov	di,bx
		mov	dx,VRAMSEG
		mov	es,dx
		mov	ds,ax
.c:		and	di,3fffh
		movsb
		loop	.c
		mov	al,[si - 1]
		pop	cx
		pop	bx
		pop	ds
		mov	[vahead],al
		mov	ax,di
		jmp	vram_written

; ---------------------------------------------------------------------------
; C-BIOS 0.29a routines that start with CALLN CALLN_VEC (tools/cbios.py).
; The Z80 address of the CALLN selects the handler; the handler does the
; routine's work and its RET (bios_ret), or continues the Z80 code at an
; address in the routine (bios_cont, AX). On entry the registers are the
; Z80's (AL = A, CX = BC, DX = DE, BX = HL) and DS is the Z80 segment. A
; handler that does the whole routine leaves the Z80 registers as the
; C-BIOS routine does (games compute their next call from them).
; Frame: [bp] Z80 SP, [bp+2] IP (after the CALLN), [bp+4] CS, [bp+6] PSW,
; then the PUSHA image (B_AX ...).

B_AX		equ	-2
B_CX		equ	-4
B_DX		equ	-6
B_BX		equ	-8

bios_call:	push	bp
		mov	bp,sp
		pusha
		push	ds
		push	es
		mov	di,[bp + 2]
		sub	di,3
		mov	si,bios_table
		cmp	byte [cs:ram_slot],0	; an MSX BIOS (tools/msxbios.py)
		jne	.find
		mov	si,msx_table
.find:		cmp	word [cs:si],0ffffh
		je	bios_ret		; not ours: just return
		cmp	[cs:si],di
		je	.found
		add	si,4
		jmp	.find
.found:
%ifdef DUMP_VRAM				; log: routine, HL, BC, DE, frame
		push	es
		push	si
		mov	si,[cs:log_n]
		cmp	si,(4000h - 200h) / 10
		jae	.full
		push	ax
		mov	es,[cs:gvram_seg]
		imul	si,si,10
		add	si,0c200h
		mov	[es:si],di
		mov	[es:si + 2],bx
		mov	[es:si + 4],cx
		mov	[es:si + 6],dx
		mov	ax,[cs:frames]
		mov	[es:si + 8],ax
		inc	word [cs:log_n]
		pop	ax
.full:		pop	si
		pop	es
%endif
		jmp	[cs:si + 2]

bios_table	dw	026dh, h_filvrm		; A: data, BC: count, HL: VRAM
		dw	0281h, h_ldirmv		; HL: VRAM, DE: RAM, BC: count
		dw	0297h, h_ldirvm		; HL: RAM, DE: VRAM, BC: count
		dw	0260h, h_setwrt		; HL: VRAM
		dw	0255h, h_setrd		; HL: VRAM
		dw	024dh, h_wrtvrm		; HL: VRAM, A: data
		dw	0245h, h_rdvrm		; HL: VRAM -> A
		dw	022eh, h_wrtvdp		; C: register, B: data
		dw	1752h, h_wrtpsg		; A: register, E: data
		dw	175ch, h_rdpsg		; A: register -> A
		dw	1770h, h_rdvdp		; -> A: status
		dw	1773h, h_snsmat		; A: row -> A
		dw	1963h, h_keyin		; the interrupt's keyboard scan
		dw	0ffffh
WRTVDP_CONT	equ	023ah			; after WRTVDP's OUTs and EI
KEYIN_CONT	equ	1977h			; after key_in's row loop
NEWKEY		equ	0fbe5h			; MSX system variable: 11 rows

; RET: PC from the Z80 stack.
bios_ret:	push	cs
		pop	ds
		mov	ax,Z80SEG
		mov	es,ax
		mov	bx,[bp]
		mov	ax,[es:bx]
		add	word [bp],2
		jmp	bios_cont.set
; Continue at AX.
bios_cont:	push	cs
		pop	ds
.set:		mov	[bp + 2],ax
		cli
		call	try_inject
		pop	es
		pop	ds
		popa
		pop	bp
		iret

; As C-BIOS's routines end with EI.
%macro BIOS_EI 0
		or	word [bp + 6],0200h
%endmacro

h_filvrm:	sti
		jcxz	.done
		push	bx
		push	cx
		mov	di,bx
		mov	bx,VRAMSEG
		mov	es,bx
.f:		and	di,3fffh
		stosb
		loop	.f
		mov	ax,di
		pop	cx
		pop	bx
		push	cs
		pop	ds
		call	vram_written
.done:		mov	word [bp + B_CX],0	; B = C = 0, A kept
		jmp	bios_ret

h_ldirvm:	sti				; RAM -> VRAM (DS = Z80SEG)
		jcxz	.done
		push	cx
		mov	si,bx
		mov	di,dx
		mov	ax,VRAMSEG
		mov	es,ax
.w:		and	di,3fffh
		movsb
		loop	.w
		mov	ax,di
		pop	cx
		mov	bx,dx
		push	cs
		pop	ds
		call	vram_written
.done:		mov	ax,[bp + B_BX]		; HL = DE, DE = HL + BC, BC = 0098h,
		mov	cx,[bp + B_CX]		; A = 0
		add	ax,cx
		mov	cx,[bp + B_DX]
		mov	[bp + B_BX],cx
		mov	[bp + B_DX],ax
		jmp	vram_block_end

h_ldirmv:	sti				; VRAM -> RAM
		jcxz	.done
		mov	si,bx
		mov	di,dx
		mov	ax,Z80SEG
		mov	es,ax
		mov	ax,VRAMSEG
		mov	ds,ax
.r:		and	si,3fffh
		movsb
		loop	.r
		and	si,3fffh
		mov	[cs:vaddr],si
		mov	byte [cs:vfirst],0
.done:		mov	ax,[bp + B_BX]		; DE = HL, BC = 0098h, A = 0
		mov	[bp + B_DX],ax
		; fall through

vram_block_end:	mov	word [bp + B_CX],0098h
		mov	byte [bp + B_AX],0
		and	byte [bp + 6],3fh	; Z = 1, S = 0 (DEC A to 0)
		or	byte [bp + 6],40h
		jmp	bios_ret

h_setwrt:	push	cs
		pop	ds
		and	bh,3fh
		mov	al,bh			; A = H & 3Fh | 40h
		or	al,40h
		mov	[bp + B_AX],al
		mov	[vaddr],bx
		mov	byte [vfirst],0
		BIOS_EI
		jmp	bios_ret

h_setrd:	push	cs
		pop	ds
		and	bh,3fh
		mov	[bp + B_AX],bh		; A = H & 3Fh
		mov	[vaddr],bx
		mov	byte [vfirst],0
		call	vread
		BIOS_EI
		jmp	bios_ret

h_wrtvrm:	push	cs
		pop	ds
		and	bh,3fh
		mov	cx,VRAMSEG
		mov	es,cx
		mov	[es:bx],al
		mov	[vahead],al
		call	mark_addr
		inc	bx
		and	bh,3fh
		mov	[vaddr],bx
		mov	byte [vfirst],0
		BIOS_EI
		jmp	bios_ret

h_rdvrm:	push	cs
		pop	ds
		and	bh,3fh
		mov	[vaddr],bx
		call	vread			; SETRD's read-ahead
		mov	al,[vahead]
		mov	[bp + B_AX],al
		call	vread			; and the IN's
		mov	byte [vfirst],0
		BIOS_EI
		jmp	bios_ret

h_wrtvdp:	and	byte [bp + B_CX],7fh	; RES 7,C
		push	cs
		pop	ds
		mov	bl,cl
		and	bx,7
		mov	al,ch
		call	set_vreg
		mov	byte [vfirst],0
		BIOS_EI
		mov	ax,WRTVDP_CONT
		jmp	bios_cont

h_wrtpsg:	push	cs			; A is kept
		pop	ds
		and	al,0fh
		mov	[psg_reg],al
		mov	al,dl
		call	psg_data_w
		BIOS_EI
		jmp	bios_ret

h_rdpsg:	push	cs
		pop	ds
		and	al,0fh
		mov	[psg_reg],al
		call	psg_data_r
		mov	[bp + B_AX],al
		jmp	bios_ret

h_rdvdp:	push	cs
		pop	ds
		call	vdp_stat_r
		mov	[bp + B_AX],al
		jmp	bios_ret

h_snsmat:	push	cs
		pop	ds
		and	al,0fh
		and	byte [ppi_c],0f0h
		or	[ppi_c],al
		mov	bl,al
		call	matrix_row
		mov	[bp + B_AX],al
		BIOS_EI
		jmp	bios_ret

; key_in: NEWKEY = rows 0-10, then the registers as the loop leaves them
; (HL past NEWKEY, B = 0, C = row 11); on at AX (keyin).
h_keyin:	mov	ax,KEYIN_CONT
keyin:		push	ax
		push	cs
		pop	ds
		mov	ax,Z80SEG
		mov	es,ax
		mov	di,NEWKEY
		mov	si,msx_keys
		mov	cx,11
		rep	movsb
		mov	[bp + B_BX],di		; HL
		mov	al,[ppi_c]
		and	al,0f0h
		or	al,0ah
		mov	[ppi_c],al
		inc	al
		mov	ah,0
		mov	[bp + B_CX],ax		; B = 0, C = row 11
		pop	ax
		jmp	bios_cont

; ---------------------------------------------------------------------------
; The Japanese MSX1 BIOS version 1.0 (the user's MSXBIOS.ROM), patched by
; MSX.COM (tools/msxbios.py). Its routines leave other registers and flags
; than C-BIOS's: each handler below as the routine it replaces (noted
; with each). Flags: S, Z, H, P/V, C set as the routine's last flag-setting
; instruction does; N and the undefined bits kept.

msx_table	dw	0815h, m_filvrm		; A: data, BC: count, HL: VRAM
		dw	070fh, m_ldirmv		; HL: VRAM, DE: RAM, BC: count
		dw	0744h, m_ldirvm		; HL: RAM, DE: VRAM, BC: count
		dw	07dfh, m_setwrt		; HL: VRAM
		dw	07ech, m_setrd		; HL: VRAM
		dw	07cdh, m_wrtvrm		; HL: VRAM, A: data
		dw	07d7h, m_rdvrm		; HL: VRAM -> A
		dw	057fh, m_wrtvdp		; C: register, B: data
		dw	1102h, h_wrtpsg		; A: register, E: data; AF kept
		dw	110eh, h_rdpsg		; A: register -> A; flags kept
		dw	1449h, h_rdvdp		; -> A: status; flags kept
		dw	1452h, m_snsmat		; A: row -> A
		dw	0c4dh, m_status		; the interrupt's IN A,(99h)
		dw	0d12h, m_keyin		; the interrupt's keyboard scan
		dw	1226h, m_row8		; GTTRIG's row 8
		dw	121fh, m_joy		; GTSTCK's PSG port select and read
		dw	0ffffh
M_STATUS_CONT	equ	0c50h			; after AND A
M_KEYIN_CONT	equ	0d26h			; after the row loop
M_JOY_CONT	equ	1224h			; EI; RET
M_WRTVDP_CONT	equ	0589h			; WRTVDP after its OUTs: EI, the
						; register's copy in RG0SAV

; The Z80 flags from AL after a logical instruction (S, Z, P from AL; C 0;
; H = AH: 10h after AND, 0 after OR or XOR). Keeps AX.
m_logic_flags:	push	ax
		mov	dl,ah
		or	al,al
		lahf
		and	ah,0c4h			; S, Z, P
		or	ah,dl
		and	byte [bp + 6],2ah
		or	[bp + 6],ah
		pop	ax
		ret

; Z = 1, S = H = C = 0, P = 1: after LD A,C; OR B with BC = 0.
m_zero_flags:	and	byte [bp + 6],2ah
		or	byte [bp + 6],44h
		ret

; WRTVDP: LD A,B; OUT; LD A,C; OR 80h; OUT; then EI and the copy go on in
; the Z80 code (A = B there, B = 0, flags from OR 80h, then ADD HL,BC).
m_wrtvdp:	push	cs
		pop	ds
		mov	bl,cl
		and	bx,7
		mov	al,ch
		call	set_vreg
		mov	byte [vfirst],0
		mov	al,cl
		or	al,80h
		xor	ah,ah
		call	m_logic_flags
		mov	ax,M_WRTVDP_CONT
		jmp	bios_cont

; SETWRT: A = H AND 3Fh OR 40h (flags of OR), EI.
m_setwrt:	push	cs
		pop	ds
		and	bh,3fh
		mov	[vaddr],bx
		mov	byte [vfirst],0
		mov	al,bh
		or	al,40h
		mov	[bp + B_AX],al
		xor	ah,ah
		call	m_logic_flags
		BIOS_EI
		jmp	bios_ret

; SETRD: A = H AND 3Fh (flags of AND), EI; the VDP reads ahead.
m_setrd:	push	cs
		pop	ds
		and	bh,3fh
		mov	al,bh
		mov	[bp + B_AX],al
		mov	ah,10h
		call	m_logic_flags
		mov	[vaddr],bx
		mov	byte [vfirst],0
		call	vread
		BIOS_EI
		jmp	bios_ret

; RDVRM: SETRD, IN A,(98h): A = the byte, flags as SETRD's.
m_rdvrm:	push	cs
		pop	ds
		and	bh,3fh
		mov	al,bh
		mov	ah,10h
		call	m_logic_flags
		mov	[vaddr],bx
		call	vread			; SETRD's read-ahead
		mov	al,[vahead]
		mov	[bp + B_AX],al
		call	vread			; and the IN's
		mov	byte [vfirst],0
		BIOS_EI
		jmp	bios_ret

; WRTVRM: PUSH AF, SETWRT, POP AF, OUT: AF kept, EI.
m_wrtvrm:	push	cs
		pop	ds
		and	bh,3fh
		mov	cx,VRAMSEG
		mov	es,cx
		mov	[es:bx],al
		mov	[vahead],al
		call	mark_addr
		inc	bx
		and	bh,3fh
		mov	[vaddr],bx
		mov	byte [vfirst],0
		BIOS_EI
		jmp	bios_ret

; FILVRM: BC bytes of A (0: 65536), AF kept (POP AF), BC = 0, EI.
m_filvrm:	sti
		mov	di,bx			; DI: VRAM
		mov	si,bx			; SI: the address after
		add	si,cx
		jcxz	.all
		cmp	cx,4000h
		jbe	.go
.all:		mov	cx,4000h		; every byte of VRAM
.go:		push	cx
		mov	dx,VRAMSEG
		mov	es,dx
.f:		and	di,3fffh
		stosb
		loop	.f
		pop	cx
		mov	ax,si
		push	cs
		pop	ds
		call	vram_written
		mov	word [bp + B_CX],0
		BIOS_EI
		jmp	bios_ret

; LDIRVM: EX DE,HL, SETWRT, then LD A,(DE); OUT; INC DE; DEC BC; LD A,C;
; OR B: HL = VRAM (DE on entry), DE = RAM + BC, BC = 0, A = 0, Z, EI.
m_ldirvm:	sti
		push	cx
		mov	si,bx
		mov	di,dx
		mov	ax,VRAMSEG
		mov	es,ax
.w:		and	di,3fffh
		movsb
		loop	.w			; (BC = 0: 65536)
		mov	ax,di
		pop	cx
		jcxz	.all
		cmp	cx,4000h
		jbe	.mark
.all:		mov	cx,4000h
.mark:		mov	bx,dx
		push	cs
		pop	ds
		call	vram_written
		mov	ax,[bp + B_BX]
		add	ax,[bp + B_CX]
		mov	cx,[bp + B_DX]
		mov	[bp + B_BX],cx		; HL = VRAM
		mov	[bp + B_DX],ax		; DE = RAM + BC
		jmp	m_block_end

; LDIRMV: SETRD, then IN; LD (DE),A; INC DE; DEC BC; LD A,C; OR B: DE =
; RAM + BC, HL kept, BC = 0, A = 0, Z, EI.
m_ldirmv:	sti
		push	cx
		mov	si,bx
		mov	di,dx
		mov	ax,Z80SEG
		mov	es,ax
		mov	ax,VRAMSEG
		mov	ds,ax
.r:		and	si,3fffh
		movsb
		loop	.r
		and	si,3fffh
		pop	cx
		push	cs
		pop	ds
		mov	[vaddr],si
		mov	byte [vfirst],0
		add	[bp + B_DX],cx		; DE = RAM + BC
m_block_end:	mov	word [bp + B_CX],0
		mov	byte [bp + B_AX],0
		call	m_zero_flags
		BIOS_EI
		jmp	bios_ret

; The interrupt: IN A,(99h); AND A (flags of AND), on at 0C50h.
m_status:	push	cs
		pop	ds
		call	vdp_stat_r
		mov	[bp + B_AX],al
		mov	ah,10h
		call	m_logic_flags
		mov	ax,M_STATUS_CONT
		jmp	bios_cont

; The interrupt's scan: NEWKEY = rows 0-10 (as h_keyin), on at 0D26h
; (which loads A and sets the flags itself).
m_keyin:	mov	ax,M_KEYIN_CONT
		jmp	keyin

; DI; IN A,(AAh); AND F0h; ADD A,8; OUT (AAh),A; IN A,(A9h); EI; RET.
m_row8:		push	cs
		pop	ds
		mov	cl,8
		jmp	m_row

; GTSTCK: OUT (A1h),A (register 15, selected by RDPSG), CALL 110Ch (A =
; register 14), then EI; RET at 1224h. Flags kept.
m_joy:		push	cs
		pop	ds
		mov	byte [psg_reg],15
		call	psg_data_w
		mov	byte [psg_reg],14
		call	psg_data_r
		mov	[bp + B_AX],al
		mov	ax,M_JOY_CONT
		jmp	bios_cont

; SNSMAT: LD C,A; IN A,(AAh); AND F0h; ADD A,C; OUT (AAh),A; IN A,(A9h):
; C = the row as given, A = the row's keys, flags of the ADD, EI.
m_snsmat:	push	cs
		pop	ds
		mov	[bp + B_CX],al		; C
		mov	cl,al
m_row:		mov	al,[ppi_c]		; CL: the row to add
		and	al,0f0h
		add	al,cl
		lahf
		mov	dl,0
		jno	.v
		mov	dl,04h
.v:		and	ah,0d1h			; S, Z, H, C; P/V: overflow
		or	ah,dl
		and	byte [bp + 6],2ah
		or	[bp + 6],ah
		mov	[ppi_c],al
		mov	bl,al
		and	bl,0fh
		call	matrix_row
		mov	[bp + B_AX],al
		BIOS_EI
		jmp	bios_ret

; Z80 register number (B C D E H L - A) -> offset from BP; 0: none.
ed_regs		db	T_BC + 1, T_BC, T_DE + 1, T_DE, T_HL + 1, T_HL, 0, T_A

; ---------------------------------------------------------------------------
; VDP (TMS9918): VRAM at VRAMSEG, address auto-increment, read-ahead.

vdp_data_w:	push	es
		mov	bx,VRAMSEG
		mov	es,bx
		mov	bx,[vaddr]
		mov	[es:bx],al
		mov	[vahead],al
		call	mark_addr
		inc	bx
		and	bh,3fh
		mov	[vaddr],bx
		mov	byte [vfirst],0
		pop	es
		ret

vdp_ctrl_w:	cmp	byte [vfirst],0
		jne	.second
		mov	[vlatch],al
		mov	byte [vfirst],1
		ret
.second:	mov	byte [vfirst],0
		test	al,80h
		jz	.addr
		mov	bl,al			; register write
		and	bx,7
		mov	al,[vlatch]
		jmp	set_vreg
.addr:		mov	bl,al			; bit 6: write set-up
		and	al,3fh
		mov	ah,al
		mov	al,[vlatch]
		mov	[vaddr],ax
		test	bl,40h
		jnz	.ret
		jmp	vread
.ret:		ret

; Register BX = AL. A change in a bit the cells depend on starts a full
; redraw. Keeps every register but AX.
set_vreg:	mov	ah,[vregs + bx]
		mov	[vregs + bx],al
		xor	ah,al
		test	ah,[vreg_sprites + bx]
		jz	.cells
		mov	byte [spr_all],1
		mov	word [f_dirty],0101h	; and spr_dirty
.cells:		and	ah,[vreg_cells + bx]
		jz	.ret
		mov	byte [vregchg],1
.ret:		ret

vreg_cells	db	02h, 58h, 0fh, 0ffh, 07h, 00h, 00h, 0ffh
vreg_sprites	db	00h, 53h, 00h, 00h, 00h, 7fh, 07h, 00h	; R1: also M1 (text)

; VRAM address BX was written: flag its pattern, colour or name row for
; the renderer. Keeps every register. DS = CS.
mark_addr:	push	ax
		push	si
		mov	byte [vwrite],1
		mov	si,bx			; the tables on this 256-byte page
		shr	si,8			; (mark_pages): none, the usual
		mov	al,[mark_pages + si]	; case for scratch VRAM, or only
		or	al,al			; those checked
		jz	.ret
		mov	[mark_cur],al
		test	al,01h
		jz	.col
		mov	ax,bx
		sub	ax,[r_pat]
		cmp	ax,[r_patsize]
		jae	.col
		shr	ax,3
		mov	si,ax
		mov	byte [pat_dirty + si],1
		mov	byte [any_dirty],1
.col:		test	byte [mark_cur],02h
		jz	.name
		mov	ax,bx
		sub	ax,[r_col]
		cmp	ax,[r_colsize]
		jae	.name
		cmp	byte [r_colshift],0	; 0 (graphics I) or 3 (II)
		je	.c
		shr	ax,3
.c:		mov	si,ax
		mov	byte [col_dirty + si],1
		mov	byte [any_dirty],1
.name:		test	byte [mark_cur],04h
		jz	.spt
		mov	ax,bx
		sub	ax,[r_name]
		cmp	ax,[r_ncells]
		jae	.spt
		cmp	byte [r_cols],32	; the row: a shift but in text mode
		jne	.div
		shr	ax,5
		jmp	.row
.div:		push	dx
		xor	dx,dx
		div	word [r_cols]
		pop	dx
.row:		mov	si,ax
		mov	byte [row_dirty + si],1
.spt:		test	byte [mark_cur],08h
		jz	.sat
		mov	ax,bx
		sub	ax,[r_spt]
		cmp	ax,800h
		jae	.sat
		shr	ax,3
		mov	si,ax
		mov	byte [spt_dirty + si],1
		mov	word [f_dirty],0101h	; and spr_dirty
.sat:		test	byte [mark_cur],10h
		jz	.ret
		mov	ax,bx
		sub	ax,[r_sat]
		cmp	ax,80h
		jae	.ret
		mov	word [f_dirty],0101h	; and spr_dirty
.ret:		pop	si
		pop	ax
		ret

; mark_pages[p]: the tables that overlap VRAM page p (256 bytes): 1
; patterns, 2 colours, 4 names, 8 sprite patterns, 10h sprite attributes.
; After render_setup and sprite_setup. Keeps every register.
mark_rebuild:	pusha
		push	es
		push	cs
		pop	es
		mov	di,mark_pages
		mov	cx,64 / 2
		xor	ax,ax
		rep	stosw
		mov	si,[r_pat]
		mov	cx,[r_patsize]
		mov	al,01h
		call	.mark
		mov	si,[r_col]
		mov	cx,[r_colsize]
		mov	al,02h
		call	.mark
		mov	si,[r_name]
		mov	cx,[r_ncells]
		mov	al,04h
		call	.mark
		mov	si,[r_spt]
		mov	cx,800h
		mov	al,08h
		call	.mark
		mov	si,[r_sat]
		mov	cx,80h
		mov	al,10h
		call	.mark
		pop	es
		popa
		ret
; AL into the pages of SI .. SI + CX - 1 (none when CX is 0).
.mark:		jcxz	.r
		mov	bx,si
		add	bx,cx
		dec	bx
		shr	bx,8			; BX: the last page
		shr	si,8			; SI: the first
.m:		and	si,3fh
		or	[mark_pages + si],al
		cmp	si,bx
		je	.r
		inc	si
		jmp	.m
.r:		ret

; VRAM BX.. was written, CX bytes (wrapping at 4000h); AX: the address after
; it. Flags the cells and leaves the VDP address there. DS = CS.
vram_written:	and	ah,3fh
		mov	[vaddr],ax
		mov	byte [vfirst],0
		mov	byte [vwrite],1
		and	bh,3fh
		cmp	cx,4000h
		jbe	.n
		mov	cx,4000h
.n:		mov	ax,4000h		; bytes to the end of VRAM
		sub	ax,bx
		cmp	cx,ax
		jbe	mark_span
		push	cx
		push	bx
		mov	cx,ax
		call	mark_span
		pop	bx
		pop	cx
		sub	cx,4000h
		add	cx,bx
		xor	bx,bx
		jmp	mark_span

; VRAM BX..BX+CX-1 written (no wrap). Keeps every register.
mark_span:	pusha
		push	es
		push	cs
		pop	es
		mov	si,bx			; SI: start, DI: end
		mov	di,bx
		add	di,cx
		mov	ax,[r_pat]
		mov	dx,[r_patsize]
		call	.clip
		jc	.col
		shr	ax,3
		shr	dx,3
		mov	bx,pat_dirty
		call	.flags
.col:		mov	ax,[r_col]
		mov	dx,[r_colsize]
		call	.clip
		jc	.name
		mov	cl,[r_colshift]
		shr	ax,cl
		shr	dx,cl
		mov	bx,col_dirty
		call	.flags
.name:		mov	ax,[r_name]
		mov	dx,[r_ncells]
		call	.clip
		jc	.done
		mov	cx,dx
		xor	dx,dx
		div	word [r_cols]
		push	ax
		; (rows)
		mov	ax,cx
		xor	dx,dx
		div	word [r_cols]
		mov	dx,ax
		pop	ax
		mov	bx,row_dirty
		call	.fill
.done:		mov	ax,[r_spt]		; sprite patterns
		mov	dx,800h
		call	.clip
		jc	.end
		shr	ax,3
		shr	dx,3
		mov	bx,spt_dirty
		call	.fill
		mov	word [f_dirty],0101h	; and spr_dirty
.end:		mov	ax,[r_sat]		; the attribute table
		mov	dx,80h
		call	.clip
		jc	.out
		mov	word [f_dirty],0101h	; and spr_dirty
.out:		pop	es
		popa
		ret
; The table at AX, DX bytes long, against SI..DI: AX, DX = first and last
; offset written; CF = 1 if none.
.clip:		or	dx,dx
		jz	.none
		add	dx,ax
		cmp	si,dx
		jae	.none
		cmp	di,ax
		jbe	.none
		mov	cx,si
		cmp	cx,ax
		jae	.first
		mov	cx,ax
.first:		cmp	di,dx
		jae	.last
		mov	dx,di
.last:		dec	dx
		sub	dx,ax
		sub	cx,ax
		mov	ax,cx
		clc
		ret
.none:		stc
		ret
; Flags BX[AX..DX] = 1.
.flags:		mov	byte [any_dirty],1
.fill:		push	di
		mov	cx,dx
		sub	cx,ax
		inc	cx
		mov	di,bx
		add	di,ax
		mov	al,1
		rep	stosb
		pop	di
		ret

vdp_data_r:	mov	byte [vfirst],0
		mov	al,[vahead]
		push	ax
		call	vread
		pop	ax
		ret

; The Z80's DI is the V30's IF: a game polling the frame flag with
; interrupts disabled would never see it set. Open the interrupts here for
; one instruction, so that a pending VRTC is taken (vrtc, nested).
vdp_stat_r:	test	byte [vstatus],80h
		jnz	.read
		sti
		nop
		cli
.read:		mov	byte [vfirst],0
		mov	al,[vstatus]
		and	byte [vstatus],1fh
		ret

; vahead = VRAM[vaddr++]
vread:		push	es
		mov	bx,VRAMSEG
		mov	es,bx
		mov	bx,[vaddr]
		mov	al,[es:bx]
		mov	[vahead],al
		inc	bx
		and	bh,3fh
		mov	[vaddr],bx
		pop	es
		ret

; ---------------------------------------------------------------------------
; PSG (AY-3-8910) on the OPN's SSG. The SSG runs at half the 3.9936 MHz
; master clock with the prescaler at 2Dh: a tone is 124800 / TP Hz (MAME's
; ymfm, PMD's tone tables, vaeg; pc88va-galaga), the MSX's 1789772.5 / 16
; / TP = 111861 / TP Hz: periods are scaled by 124800 / 111861 = 1 + 7581
; / 65536, and clamped to the registers' widths (tone 12 bits, noise 5).
; Until 2026-10-23 they were scaled by 62400 / 111861: an octave high.

PERIOD_EXTRA	equ	7581

psg_addr_w:	and	al,0fh
		mov	[psg_reg],al
		ret

psg_data_r:	mov	bl,[psg_reg]
		cmp	bl,14
		je	.joy
		xor	bh,bh
		mov	al,[psg + bx]
		ret
.joy:		mov	al,0bfh			; port 2: nothing connected
		test	byte [psg + 15],40h
		jnz	.ret
		mov	al,[msx_keys + 11]	; port 1: from the VA keyboard
		and	al,3fh
		or	al,80h
.ret:		ret

psg_data_w:	mov	bl,[psg_reg]
		xor	bh,bh
		mov	[psg + bx],al
		cmp	bl,6
		jb	.tone
		je	.noise
		cmp	bl,7
		je	.mixer
		cmp	bl,11
		jb	.direct			; 8-10: levels
		cmp	bl,13
		jb	.env
		je	.direct			; 13: envelope shape
		ret				; 14, 15: the I/O ports
.direct:	mov	ah,al
		mov	al,bl
		jmp	opn_write
.mixer:		and	al,3fh			; keep the VA's port directions
		or	al,[opn_io]
		mov	ah,al
		mov	al,7
		jmp	opn_write
.noise:		and	al,1fh
		xor	ah,ah
		call	scale
		cmp	ax,1fh
		jbe	.n
		mov	al,1fh
.n:		mov	ah,al
		mov	al,6
		jmp	opn_write
.tone:		and	bl,6			; the pair's low register
		mov	ax,[psg + bx]
		and	ah,0fh
		call	scale
		cmp	ax,0fffh
		jbe	.pair
		mov	ax,0fffh
		jmp	.pair
.env:		mov	bl,11
		mov	ax,[psg + bx]
		call	scale
.pair:		push	ax			; BL: low register
		mov	ah,al
		mov	al,bl
		call	opn_write
		pop	ax
		mov	al,bl
		inc	al
		jmp	opn_write

; AX = AX + AX * PERIOD_EXTRA / 65536 (rounded), at most FFFFh.
scale:		push	dx
		push	cx
		mov	cx,ax
		mov	dx,PERIOD_EXTRA
		mul	dx
		add	ax,8000h		; round
		adc	dx,0
		mov	ax,cx
		add	ax,dx
		jnc	.ret
		mov	ax,0ffffh
.ret:		pop	cx
		pop	dx
		ret

sound_init:	mov	al,2dh			; prescaler 1/6 (the reset default)
		mov	ah,0
		call	opn_write
		mov	al,07h
		call	opn_read
		and	ah,0c0h
		mov	[opn_io],ah
		or	ah,3fh			; every tone and noise off
		mov	al,07h
		call	opn_write
		mov	al,08h
.level:		mov	ah,0
		call	opn_write
		inc	al
		cmp	al,0bh
		jb	.level
		ret

; Register AL = AH; keeps every register.
opn_write:	push	ax
		push	ax
		call	opn_wait
		pop	ax
		out	44h,al
		call	opn_wait
		mov	al,ah
		out	45h,al
		pop	ax
		ret

; AH = register AL.
opn_read:	push	ax
		call	opn_wait
		pop	ax
		out	44h,al
		call	opn_wait
		in	al,45h
		mov	ah,al
		ret

opn_wait:	in	al,44h
		test	al,80h
		jnz	opn_wait
		ret

; ---------------------------------------------------------------------------
; PPI (8255): A = slot select, B = keyboard columns, C = row and others.

ppi_a_r:	mov	al,[ppi_a]
		ret

ppi_b_r:	mov	bl,[ppi_c]
		and	bl,0fh
		; fall through

; AL = MSX key matrix row BL (FFh beyond row 10).
matrix_row:	mov	al,0ffh
		cmp	bl,11
		jae	.ret
		xor	bh,bh
		mov	al,[msx_keys + bx]
.ret:		ret

; The VA keyboard (ports 00h-0Eh, a key's bit 0 while pressed) into the MSX
; matrix rows 0-10 and joystick port 1 (msx_keys + 11: bits 0-5 up, down,
; left, right, trigger A, B), through key_map.
kbd_scan:	push	es
		push	cs
		pop	es
		mov	di,kbd_new
		xor	dx,dx
		mov	cx,15
.in:		in	al,dx
		stosb
		inc	dx
		loop	.in
		mov	si,kbd_new		; the same as last frame: the MSX
		mov	di,va_keys		; matrix stays
		mov	cx,15
		repe	cmpsb
%ifndef TEST_FIRE
		je	.done
%endif
		mov	si,kbd_new
		mov	di,va_keys
		mov	cx,15
		rep	movsb
		mov	di,msx_keys
		mov	al,0ffh
		mov	cx,12
		rep	stosb
		mov	si,key_map
.map:		lodsw				; AL: VA port, bit; AH: MSX row, bit
		cmp	al,0ffh
		je	.done
		mov	bl,al
		shr	bl,4
		xor	bh,bh
		mov	cl,al
		and	cl,7
		mov	ch,[va_keys + bx]
		shr	ch,cl
		test	ch,1
		jnz	.map
		mov	bl,ah
		shr	bl,4
		mov	cl,ah
		and	cl,7
		mov	ch,1
		shl	ch,cl
		not	ch
		and	[msx_keys + bx],ch
		jmp	.map
.done:
%ifdef TEST_FIRE				; vaeg tests: SPACE and trigger A
		test	byte [frames],4		; pressed 4 frames in 8
		jz	.fire
		and	byte [msx_keys + 8],0feh
		and	byte [msx_keys + 11],0efh
.fire:
%endif
		pop	es
		ret

ppi_c_r:	mov	al,[ppi_c]
		ret

ppi_c_w:	mov	[ppi_c],al
		ret

ppi_ctrl_w:	test	al,80h
		jnz	.ret			; mode set
		mov	bl,al			; bit set/reset of port C
		shr	bl,1
		and	bl,7
		mov	ah,1
		xchg	cl,bl
		shl	ah,cl
		xchg	cl,bl
		test	al,1
		jz	.reset
		or	[ppi_c],ah
		ret
.reset:		not	ah
		and	[ppi_c],ah
.ret:		ret

; Slot select AL: for each page whose slot changes, the page goes back to
; its store if it is RAM and the new slot's page is copied in (FFh for an
; empty slot). 16 KiB copies; slow, but MSX1 software switches rarely.
ppi_a_w:	push	cx
		push	dx
		push	di
		push	es
		mov	[ppi_a],al
		mov	dl,al
		xor	bx,bx			; BX: page
.page:		mov	al,dl
		and	al,3
		cmp	al,[cur_slot + bx]
		je	.next
		mov	ah,[cur_slot + bx]
		mov	[cur_slot + bx],al
		cmp	ah,3			; none yet (FFh)
		ja	.load
		push	ax			; the old slot's page: if it is
		mov	al,ah			; RAM, save it
		call	page_seg
		mov	cx,ax
		sub	cx,RAMSEG
		cmp	cx,1000h
		jae	.kept
		push	ds
		mov	es,ax
		mov	si,bx			; Z80 page -> its RAM store
		mov	cl,14
		shl	si,cl
		xor	di,di
		mov	cx,Z80SEG
		mov	ds,cx
		mov	cx,2000h
		rep	movsw
		pop	ds
.kept:		pop	ax
.load:		call	page_seg		; slot AL's page BX
		or	ax,ax
		jnz	.copy
		mov	di,bx			; empty: FFh
		mov	cl,14
		shl	di,cl
		mov	ax,Z80SEG
		mov	es,ax
		mov	ax,0ffffh
		mov	cx,2000h
		rep	stosw
		jmp	.switched
.copy:		push	ds
		mov	ds,ax
		mov	di,bx
		mov	cl,14
		shl	di,cl
		xor	si,si
		mov	cx,Z80SEG
		mov	es,cx
		mov	cx,2000h
		rep	movsw
		pop	ds
.switched:	inc	word [switches]
.next:		shr	dl,2
		inc	bx
		cmp	bx,4
		jb	.page
		pop	es
		pop	di
		pop	dx
		pop	cx
		ret

; Slot AL's page BX -> AX: its segment (0: empty). Uses SI.
page_seg:	mov	si,bx
		shl	si,1
		mov	ah,0
		shl	ax,3
		add	si,ax
		mov	ax,[slot_seg + si]
		ret

; ---------------------------------------------------------------------------
; Rendering, in the VRTC handler. A pass visits the cells in order and
; redraws a cell whose name is not the one last drawn there, whose pattern
; or colour was written before the pass started, or every cell after a
; change in a register the cells depend on. A row is skipped when none of
; its names was written and no pattern or colour is pending. At most
; MAX_TILES cells are drawn a frame; the pass goes on in the next frame. A
; pass starts only after a VRAM or register write. Graphics I and II, and
; text; colour 0 is the backdrop (R7 bits 0-3). No sprites yet.

render_step:	cmp	byte [pass_on],0
		jne	.go
		cmp	byte [vregchg],0
		jne	.start
		cmp	byte [vwrite],0
		jne	.written
		cmp	byte [scr_wait],0	; quiet after a deferred rewrite
		je	.ret
		jmp	.start
.written:	call	scr_defer		; CF: wait for a quiet frame
		jc	.ret
.start:		mov	byte [scr_wait],0
		call	pass_start
.go:		mov	word [budget],MAX_TILES * 2	; half cells: a cell from the
		cmp	word [render_fn],loop_pcg
		je	.text
		jmp	[render_fn]
.text:		mov	dx,0153h		; the gaiji cells: TVRAM at A0000h
		in	al,dx
		push	ax
		and	al,0f0h
		or	al,01h
		out	dx,al
		call	loop_pcg
		pop	ax
		mov	dx,0153h
		out	dx,al
.ret:		ret

pass_start:	mov	byte [vwrite],0
		cmp	byte [vregchg],0
		je	.pend
		mov	byte [vregchg],0
		call	render_flip
.pend:		push	es			; pending <- written, written <- 0:
		push	cs			; the rows; the patterns and colours
		pop	es			; when a flag is set in either (the
		mov	al,[any_dirty]		; first 256 and 32 but in graphics
		or	al,[pend_set]		; II)
		jz	.rows
		cmp	word [render_fn],loop_g2
		je	.all
		mov	si,pat_dirty
		mov	di,pat_pend
		mov	cx,256 / 2
		call	.move
		mov	si,col_dirty
		mov	di,col_pend
		mov	cx,32 / 2
		call	.move
		jmp	.rows
.all:		mov	si,pat_dirty
		mov	di,pat_pend
		mov	cx,768 * 2 / 2
		call	.move
.rows:		mov	si,row_dirty
		mov	di,row_pend
		mov	cx,24 / 2
		call	.move
		pop	es
		mov	al,[any_dirty]
		mov	[any_pend],al
		mov	[pend_set],al
		mov	byte [any_dirty],0
		call	scr_check		; a scroll by a row: the hardware's
		xor	ax,ax
		mov	[rpos],ax
		mov	[rrow],al
		mov	[rcol],al
		push	es
		mov	dh,0
		call	row_at
		mov	[rdest],di
		mov	[rseg],es
		pop	es
		mov	byte [pass_on],1
		call	make_merged
		mov	byte [flipped],0
		cmp	word [render_fn],loop_pcg
		jne	.cleared
		call	pcg_glyphs
.cleared:	cmp	byte [rfull],0
		je	.ret
		cmp	byte [r_clear],0
		je	.ret
		call	clear_picture
.ret:		ret
.move:		push	si			; CX words SI -> DI, SI zeroed
		push	cx
		rep	movsw
		pop	cx
		pop	di
		xor	ax,ax
		rep	stosw
		ret

; merged[i]: 1 when a cell of name i (graphics II: third * 256 + name)
; must be drawn whatever was drawn there: its pattern or colour pending,
; or a full redraw. DS = CS.
make_merged:	push	bp
		push	es
		push	cs
		pop	es
		mov	di,merged
		mov	cx,768 / 2
		mov	ax,0101h		; a full redraw: every cell
		cmp	byte [rfull],0
		jne	.fill
		xor	ax,ax			; nothing pending: names only
		cmp	byte [any_pend],0
		je	.fill
		mov	ax,[render_fn]
		cmp	ax,loop_g2
		je	.g2
		cmp	ax,loop_pcg
		je	.pcg
		mov	si,pat_pend		; graphics I, text: by name
		mov	cx,256 / 2
		rep	movsw
		cmp	word [render_fn],loop_g1
		jne	.ret
		jmp	.colours
.pcg:		xor	ax,ax			; the gaiji cells: a pattern is its
		mov	cx,256 / 2		; glyph (pcg_glyphs), only the
		rep	stosw			; colours that changed count (a
		push	ds			; shadow of the 32); rows are
		mov	si,[r_col]		; skipped when none did and the
		mov	ax,VRAMSEG		; tables did not move
		mov	ds,ax
		xor	bx,bx
		xor	dl,dl
.col:		cmp	byte [cs:col_pend + bx],0
		je	.col_next
		mov	al,[si + bx]
		cmp	al,[cs:pcg_colsh + bx]
		jne	.col_new
		mov	byte [cs:col_pend + bx],0
		jmp	.col_next
.col_new:	mov	[cs:pcg_colsh + bx],al
		mov	dl,1
.col_next:	inc	bx
		cmp	bx,32
		jb	.col
		pop	ds
		mov	[pcg_cols],dl
		mov	al,dl
		or	al,[flipped]
		mov	[any_pend],al
.colours:	xor	bx,bx			; graphics I: a colour, its eight
.g1:		cmp	byte [col_pend + bx],0	; names
		je	.g1_next
		mov	di,bx
		shl	di,3
		mov	ax,0101h
		mov	[merged + di],ax
		mov	[merged + di + 2],ax
		mov	[merged + di + 4],ax
		mov	[merged + di + 6],ax
.g1_next:	inc	bx
		cmp	bx,32
		jb	.g1
		jmp	.ret
.g2:		xor	si,si			; graphics II: through the masks
		mov	dx,[r_pmi]
		mov	bp,[r_cmi]
.g2_l:		mov	bx,si
		and	bx,dx
		mov	al,[pat_pend + bx]
		mov	bx,si
		and	bx,bp
		or	al,[col_pend + bx]
		mov	[merged + si],al
		or	al,al			; the cached image is stale
		jz	.g2_n
		mov	byte [g2_ok + si],0
.g2_n:		inc	si
		cmp	si,768
		jb	.g2_l
		jmp	.ret
.fill:		rep	stosw
		or	ax,ax			; a full redraw: no cached image
		jz	.cache_kept
		mov	di,g2_ok
		mov	cx,768 / 2
		xor	ax,ax
		rep	stosw
.cache_kept:	cmp	word [render_fn],loop_pcg	; the gaiji cells' colour
		jne	.ret			; shadow
		push	ds
		mov	si,[r_col]
		mov	ax,VRAMSEG
		mov	ds,ax
		mov	di,pcg_colsh
		mov	cx,32 / 2
		rep	movsw
		pop	ds
		mov	byte [pcg_cols],0
.ret:		pop	es
		pop	bp
		ret

; The registers changed: the new set-up, and a full redraw unless only the
; name, pattern or colour table moved in the same mode (a game's double
; buffering, page flipping every few frames): then only the patterns and
; colours whose bytes differ between the old and the new table are
; flagged, and the names are compared with the shadow as usual.
render_flip:	push	es
		push	cs
		pop	es
		mov	si,render_fn		; the set-up so far
		mov	di,old_setup
		mov	cx,SETUP_WORDS
		rep	movsw
		pop	es
		mov	al,[backdrop]
		mov	[old_backdrop],al
		call	render_setup
		mov	al,[backdrop]
		cmp	al,[old_backdrop]
		jne	.full
		mov	ax,[render_fn]
		cmp	ax,[old_setup]
		jne	.full
		cmp	ax,loop_blank
		je	.full
		mov	si,old_setup + r_pmask - render_fn
		mov	di,r_pmask		; the masks
		mov	cx,4
		call	.same
		jne	.full
		mov	si,old_setup + r_ncells - render_fn
		mov	di,r_ncells		; the geometry, the text colours
		mov	cx,5
		call	.same
		jne	.full
		mov	si,[old_setup + r_pat - render_fn]
		mov	di,[r_pat]		; the patterns
		mov	cx,[r_patsize]
		shr	cx,3
		mov	bx,pat_dirty
		call	diff8
		mov	si,[old_setup + r_col - render_fn]
		mov	di,[r_col]		; the colours: by 8 bytes (graphics
		mov	cx,[r_colsize]		; II) or bytes (graphics I)
		mov	bx,col_dirty
		cmp	byte [r_colshift],0
		je	.bytes
		shr	cx,3
		call	diff8
		jmp	.flagged
.bytes:		call	diff1
.flagged:	mov	byte [any_dirty],1	; every row checked
		mov	byte [flipped],1
		ret
.full:		mov	byte [rfull],1
		call	scr_off			; the layout as at the start
		mov	ax,[render_fn]		; every glyph again unless the
		cmp	ax,[old_setup]		; gaiji cells stay on the same
		jne	.glyphs			; patterns (a backdrop change)
		mov	ax,[r_pat]
		cmp	ax,[old_setup + r_pat - render_fn]
		je	.ret
.glyphs:	mov	byte [glyphs_all],1
.ret:		ret
.same:		push	es
		push	cs
		pop	es
		repe	cmpsw
		pop	es
		ret

; Flags at CS:BX the CX entries of 8 (diff8) or 1 (diff1) bytes that
; differ between the VRAM tables at SI (old) and DI (new). Uses AX, BX,
; CX, SI, DI.
diff8:		jcxz	.ret			; the whole table at once, past the
		cmp	si,di			; rest of an entry that differs
		je	.ret
		push	ds
		push	es
		push	dx
		mov	dx,VRAMSEG
		mov	ds,dx
		mov	es,dx
		mov	dx,di			; DX: the new table
		shl	cx,2			; words
.w:		repe	cmpsw
		je	.done
		mov	ax,di
		sub	ax,dx
		dec	ax
		shr	ax,3
		push	bx
		add	bx,ax
		mov	byte [cs:bx],1
		pop	bx
		mov	ax,di
		sub	ax,dx
		and	ax,7
		jz	.more
		neg	ax
		add	ax,8
		add	si,ax
		add	di,ax
		shr	ax,1
		sub	cx,ax
.more:		jcxz	.done
		jmp	.w
.done:		pop	dx
		pop	es
		pop	ds
.ret:		ret
diff1:		mov	ax,0
diff:		jcxz	.ret
		cmp	si,di			; the same table
		je	.ret
		push	ds
		push	es
		push	dx
		mov	dx,VRAMSEG
		mov	ds,dx
		mov	es,dx
		mov	dx,ax
.e:		push	cx
		or	dx,dx
		jz	.b
		mov	cx,dx
		repe	cmpsw
		je	.next
		mov	byte [cs:bx],1
		shl	cx,1			; past the rest of the entry
		add	si,cx
		add	di,cx
		jmp	.next
.b:		cmpsb
		je	.next
		mov	byte [cs:bx],1
.next:		pop	cx
		inc	bx
		loop	.e
		pop	dx
		pop	es
		pop	ds
.ret:		ret

; The 256x192 picture in the backdrop colour (and the ring, scrolling).
clear_picture:	mov	al,[backdrop]
		mov	ah,al
		shl	ah,4
		or	al,ah
		mov	ah,al
		cmp	byte [scr_on],0
		je	.fb0
		mov	es,[ring_seg]
		mov	di,GFX_X
		mov	dl,[scr_n]
		xor	dh,dh
		shl	dx,3
		call	.fill
.fb0:		mov	es,[gvram_seg]
		mov	di,PICTURE_Y * STRIDE + GFX_X
		mov	dx,192
.fill:		mov	cx,128 / 2		; DX lines of the picture's width
		rep	stosw
		add	di,STRIDE - 128
		dec	dx
		jnz	.fill
		ret

; ---------------------------------------------------------------------------
; Scrolling by a row with the hardware (docs/DESIGN.md "M05"). A game that
; scrolls by rewriting its name table a row down (Star Force) changes most
; cells of the picture at every step. When a pass finds rows b + 1 .. 23
; holding what rows b .. 22 showed, the rows b .. 23 are shown from a ring
; in GVRAM (frame buffer 2, sub-screen 2, wrapped vertically: manual
; 4.5.5) whose start moves up a row: only row b, and in Graphics II rows
; that crossed into another third (8, 16), are drawn again. Rows 0 .. b - 1
; stay in frame buffer 0 (sub-screen 0). Graphics I and II in GVRAM only
; (not the gaiji cells); off on the settings page (scr_allow) and at a
; full redraw. A rewrite of many rows is taken when a frame passes
; without VRAM writes (at most SCR_WAIT frames late), so that the check
; sees the whole step.

SCR_WAIT	equ	4
SCR_ROWS	equ	12		; rows written: perhaps a scroll

; ES:DI = the start of picture row DH (cell 0, line 0) for the cell loop.
; Keeps every register but ES, DI.
row_at:		push	ax
		cmp	byte [cs:scr_on],0
		je	.fb0
		mov	al,dh
		sub	al,[cs:scr_b]
		jb	.fb0
		add	al,[cs:scr_phase]	; ring row (dh - b + phase) mod n
		cmp	al,[cs:scr_n]
		jb	.r
		sub	al,[cs:scr_n]
.r:		xor	ah,ah
		imul	di,ax,8 * STRIDE
		add	di,GFX_X
		mov	es,[cs:ring_seg]
		pop	ax
		ret
.fb0:		mov	al,dh
		xor	ah,ah
		imul	di,ax,8 * STRIDE
		add	di,[cs:r_start]
		mov	es,[cs:gvram_seg]
		pop	ax
		ret

; render_step after VRAM writes, no pass running: CF = 1 to wait one more
; frame (a rewrite of SCR_ROWS rows or more in Graphics I/II, still going
; on). DS = CS.
scr_defer:	cmp	byte [scr_allow],0
		je	.go
		mov	ax,[render_fn]
		cmp	ax,loop_g1
		je	.mode
		cmp	ax,loop_g2
		jne	.go
.mode:		mov	si,row_dirty
		mov	cx,24
		xor	ah,ah
.c:		lodsb
		add	ah,al
		loop	.c
		cmp	ah,SCR_ROWS
		jb	.go
		cmp	byte [scr_wait],SCR_WAIT
		jae	.go
		inc	byte [scr_wait]
		mov	byte [vwrite],0
		stc
		ret
.go:		clc
		ret

; At a pass start (the flags copied, before make_merged): a scroll down
; by a row of rows b .. 23? Then the ring moves, or is set up (a full
; redraw). Uses AX, BX, CX, DX, SI, DI. DS = CS.
scr_check:	cmp	byte [scr_allow],0
		je	.ret
		cmp	byte [rfull],0
		jne	.ret
		mov	ax,[render_fn]
		cmp	ax,loop_g1
		je	.mode
		cmp	ax,loop_g2
		jne	.ret
.mode:		mov	si,row_pend		; enough rows written?
		mov	cx,24
		xor	ah,ah
.c:		lodsb
		add	ah,al
		loop	.c
		cmp	ah,SCR_ROWS
		jb	.ret
		push	es
		mov	ax,VRAMSEG
		mov	es,ax
		mov	dl,23			; DL: from the bottom up, while the
.row:		mov	al,dl			; row holds the row above's shadow
		call	.match			; (28 of 32 cells)
		jb	.top
		dec	dl
		jnz	.row
.top:		pop	es
		inc	dl			; DL: the lowest row that matched
		cmp	dl,20			; at least four rows
		ja	.ret
		dec	dl			; DL: b, the band's new top row
		cmp	byte [scr_on],0
		je	.setup
		cmp	dl,[scr_b]
		jb	.setup			; a wider band: set up again
		ja	.ret			; a part of one (the rewrite not
						; finished): drawn as it is
		dec	byte [scr_phase]	; the ring a row up: row r shows
		jns	.shadow			; what row r - 1 showed
		mov	al,[scr_n]
		dec	al
		mov	[scr_phase],al
.shadow:	mov	al,23			; shadow rows b .. 22 -> b + 1 .. 23
.sh:		cmp	al,dl
		jbe	.new
		mov	ah,al
		mov	bl,al
		dec	bl
		call	.copy_row
		dec	al
		jmp	.sh
.new:		mov	al,dl			; row b: draw it
		call	.stale
		cmp	word [render_fn],loop_g2
		jne	.moved
		mov	al,8			; graphics II: rows that came into
		cmp	al,dl			; another third
		jbe	.r16
		call	.stale
.r16:		mov	al,16
		cmp	al,dl
		jbe	.moved
		call	.stale
.moved:		inc	word [scr_steps]
		jmp	scr_ports
.setup:		mov	[scr_b],dl		; the ring for rows b .. 23
		mov	al,24
		sub	al,dl
		mov	[scr_n],al
		mov	byte [scr_phase],0
		mov	byte [scr_on],1
		mov	byte [rfull],1		; drawn again in full
		jmp	scr_ports
.ret:		ret
; CF = 1 (JB) unless at least 28 cells of row AL hold the names the
; shadow has for row AL - 1. ES = VRAMSEG. Keeps DX.
.match:		xor	ah,ah
		shl	ax,5
		mov	si,ax
		add	si,[r_name]
		lea	di,[shadow - 32]
		add	di,ax			; the shadow of the row above
		push	si			; all 32 equal (the usual case):
		push	di			; REPE CMPSW
		push	ds
		push	es
		push	es
		push	cs
		pop	es
		pop	ds
		mov	cx,16
		repe	cmpsw
		pop	es
		pop	ds
		pop	di
		pop	si
		jne	.count
		clc
		ret
.count:		mov	cx,32
		xor	bx,bx
.m:		mov	al,[es:si]
		cmp	al,[di]
		jne	.mn
		inc	bx
.mn:		inc	si
		inc	di
		loop	.m
		cmp	bx,28
		ret
; Shadow row AH = shadow row BL. Keeps AX, DX.
.copy_row:	push	ax
		push	es
		push	cs
		pop	es
		mov	al,ah
		xor	ah,ah
		shl	ax,5
		mov	di,ax
		add	di,shadow
		xor	bh,bh
		shl	bx,5
		lea	si,[shadow + bx]
		mov	cx,16
		rep	movsw
		pop	es
		pop	ax
		ret
; Row AL drawn at the pass: its shadow made unlike every name, its row
; flagged. Keeps AX, DX.
.stale:		push	ax
		push	es
		mov	bl,al
		xor	bh,bh
		mov	byte [row_pend + bx],1
		xor	ah,ah
		shl	ax,5
		mov	si,ax
		add	si,[r_name]
		mov	di,ax
		add	di,shadow
		mov	cx,32
		mov	ax,VRAMSEG
		mov	es,ax
.s:		mov	al,[es:si]
		not	al
		mov	[di],al
		inc	si
		inc	di
		loop	.s
		pop	es
		pop	ax
		ret

; Frame buffers 0 and 2 for scr_on (word writes: a byte write to a DSA can
; hang the hardware, pc88va-galaga). In the VRTC handler. Uses AX, DX.
scr_ports:	cmp	byte [scr_on],0
		je	scr_off_ports
		mov	al,[scr_b]		; FB0: lines 0 .. PICTURE_Y + 8b - 1
		xor	ah,ah
		shl	ax,3
		add	ax,PICTURE_Y
		push	ax
		mov	dx,0212h		; DSH
		out	dx,ax
		mov	ax,[ring_lo]		; FB2: the ring
		mov	dx,0240h		; FSA
		out	dx,ax
		mov	ax,[ring_hi]
		mov	dx,0242h
		out	dx,ax
		mov	ax,STRIDE		; FBW
		mov	dx,0244h
		out	dx,ax
		mov	al,[scr_n]
		xor	ah,ah
		shl	ax,3
		push	ax
		dec	ax
		mov	dx,0246h		; FBL: lines - 1
		out	dx,ax
		xor	ax,ax			; OFX
		mov	dx,0248h
		out	dx,ax
		mov	al,[scr_phase]		; OFY: phase * 8
		xor	ah,ah
		shl	ax,3
		mov	dx,024ch
		out	dx,ax
		imul	ax,ax,STRIDE		; DSA: FSA + OFY * FBW
		xor	dx,dx
		add	ax,[ring_lo]
		adc	dx,[ring_hi]
		push	dx
		mov	dx,024eh
		out	dx,ax
		pop	ax
		mov	dx,0250h
		out	dx,ax
		pop	ax			; DSH: the ring's lines
		mov	dx,0252h
		out	dx,ax
		pop	ax			; DSP: below sub-screen 0
		mov	dx,0256h
		out	dx,ax
		ret
scr_off_ports:	mov	ax,200			; FB0 over the screen, FB2 off
		mov	dx,0212h
		out	dx,ax
		xor	ax,ax
		mov	dx,0252h
		out	dx,ax
		ret

; Scrolling off (a full redraw, the settings page, an MSX reset).
scr_off:	mov	byte [scr_on],0
		jmp	scr_off_ports

; From the registers: the cell loop, the tables and their sizes for
; mark_addr, the colour pairs.
render_setup:	push	word [render_fn]
		call	.setup
		call	mark_rebuild
		pop	ax			; the gaiji cells left: blank
		cmp	ax,loop_pcg
		jne	.done
		cmp	word [render_fn],loop_pcg
		je	.done
		call	pcg_blank
.done:		ret
.setup:		mov	al,[vregs + 7]		; backdrop
		and	al,0fh
		mov	[backdrop],al
		cmp	al,[pairs_bd]		; the pairs depend on it alone
		je	.pairs
		mov	[pairs_bd],al
		call	make_pairs
.pairs:
		mov	al,[vregs + 2]		; name table
		and	ax,0fh
		shl	ax,10
		mov	[r_name],ax
		xor	ax,ax
		mov	[r_patsize],ax
		mov	[r_colsize],ax
		mov	[r_ncells],ax
		mov	word [r_cols],32
		mov	word [r_start],PICTURE_Y * STRIDE + GFX_X
		mov	byte [r_clear],1
		mov	word [render_fn],loop_blank
		test	byte [vregs + 1],40h
		jz	.ret
		test	byte [vregs + 1],10h
		jnz	.text
		test	byte [vregs + 1],08h
		jnz	.ret			; multicolour: not drawn (blank)
		mov	byte [r_clear],0
		mov	word [r_ncells],768
		test	byte [vregs + 0],02h
		jnz	.g2
		mov	al,[vregs + 4]		; graphics I
		and	ax,7
		shl	ax,11
		mov	[r_pat],ax
		mov	word [r_patsize],800h
		mov	al,[vregs + 3]
		xor	ah,ah
		shl	ax,6
		mov	[r_col],ax
		mov	word [r_colsize],20h
		mov	byte [r_colshift],0
		mov	word [render_fn],loop_g1
		cmp	byte [pcg_on],0
		je	.g1_ret
		mov	word [render_fn],loop_pcg	; the gaiji cells, the
		mov	byte [r_clear],1		; picture in the backdrop
.g1_ret:	ret
.g2:		mov	al,[vregs + 4]		; graphics II: base and mask
		mov	ah,al
		and	ax,0304h
		shl	al,3			; bit 2 -> 2000h
		mov	byte [r_pat],0
		mov	[r_pat + 1],al
		shl	ah,3			; bits 0-1 -> mask bits 11-12
		or	ah,07h
		mov	byte [r_pmask],0ffh
		mov	[r_pmask + 1],ah
		mov	al,[vregs + 3]
		mov	ah,al
		and	al,80h			; bit 7 -> 2000h
		shr	al,2
		mov	byte [r_col],0
		mov	[r_col + 1],al
		and	ah,7fh			; bits 0-6 -> mask bits 6-12
		mov	al,0
		shr	ax,2
		or	al,3fh
		mov	[r_cmask],ax
		mov	word [r_patsize],1800h
		mov	word [r_colsize],1800h
		mov	byte [r_colshift],3
		mov	ax,[r_pmask]		; the masks as pattern numbers
		shr	ax,3
		mov	[r_pmi],ax
		mov	ax,[r_cmask]
		shr	ax,3
		mov	[r_cmi],ax
		mov	word [render_fn],loop_g2
		ret
.text:		mov	al,[vregs + 4]
		and	ax,7
		shl	ax,11
		mov	[r_pat],ax
		mov	word [r_patsize],800h
		mov	word [r_ncells],960
		mov	word [r_cols],40
		mov	word [r_start],PICTURE_Y * STRIDE + TEXT_X
		mov	al,[vregs + 7]		; text colours
		xor	ah,ah
		call	pair_of
		mov	[r_text],dx
		mov	[r_text + 2],cx
		mov	word [render_fn],loop_text
.ret:		ret

loop_blank:	mov	byte [pass_on],0
		mov	byte [rfull],0
		ret

; The cell loop of a mode. %1: cells a row, %2: bytes a cell, %3: 1 in
; graphics II (AX for the tile routine: third * 256 + name; merged by
; third), %4: the tile routine. A cell is drawn when its name is not the
; one drawn there (shadow) or merged flags it. Rows without a written
; name are skipped when nothing else is pending. A call draws at most
; MAX_TILES cells and checks at most about SCAN_MAX; the pass goes on in
; the next frame (rpos: the cell, rrow, rcol, rdest: the row's start).
; DS = CS on entry.
%macro CELL_LOOP 4
		mov	es,[rseg]
		push	bp
		push	ds
		mov	si,[rpos]
		mov	di,[rdest]
		mov	dl,[rcol]		; DL: the column, DH: the row
		mov	dh,[rrow]
		mov	word [scan],SCAN_MAX
		mov	ax,VRAMSEG
		mov	ds,ax
%%row:		cmp	si,[cs:r_ncells]
		jae	%%end
		or	dl,dl			; a row start: skip the row?
		jnz	%%scan
		cmp	word [cs:scan],0	; or stop here for this frame
		jle	%%save
		cmp	byte [cs:rfull],0
		jne	%%scan
		cmp	byte [cs:any_pend],0
		jne	%%scan
		mov	bl,dh
		xor	bh,bh
		cmp	byte [cs:row_pend + bx],0
		jne	%%scan
		add	si,%1
		inc	dh
		call	row_at
		jmp	%%row
%%scan:		mov	cl,%1			; CX: the cells left in the row
		sub	cl,dl
		xor	ch,ch
		sub	[cs:scan],cx
		mov	bx,[cs:r_name]		; SI: the name's address, BP: the
		add	si,bx			; shadow at [cs:bp + si]
		mov	bp,shadow
		sub	bp,bx
		mov	bx,merged
 %if %3
		mov	al,dh			; graphics II: the third's flags
		shr	al,3
		add	bh,al
 %endif
%%c:		lodsb
		cmp	al,[cs:bp + si - 1]
		jne	%%hit
		cs	xlatb
		or	al,al
		jnz	%%hit_again
		loop	%%c
		sub	si,[cs:r_name]		; the row done
		mov	dl,0
		inc	dh
		call	row_at
		jmp	%%row
%%hit_again:	mov	al,[si - 1]
%%hit:		mov	[cs:bp + si - 1],al	; the shadow
		push	cx
		push	dx
		push	bx
		push	bp
		push	si
		push	di
		xor	ah,ah
 %if %3
		mov	ah,dh
		shr	ah,3
 %endif
		mov	bl,%1			; the cell's place: the row's start
		sub	bl,cl			; + column * %2
		mov	bh,0
		imul	bx,bx,%2
		add	di,bx
		call	%4
		pop	di
		pop	si
		pop	bp
		pop	bx
		pop	dx
		pop	cx
		sub	word [cs:budget],2	; Graphics II cache costs half
		jle	%%full
		loop	%%c
		sub	si,[cs:r_name]		; the row done
		mov	dl,0
		inc	dh
		call	row_at
		jmp	%%row
%%full:		dec	cx			; drawn enough: stop after this cell
		mov	dl,%1
		sub	dl,cl
		sub	si,[cs:r_name]
		cmp	dl,%1
		jb	%%save
		mov	dl,0
		inc	dh
		call	row_at
%%save:		mov	[cs:rpos],si
		mov	[cs:rdest],di
		mov	[cs:rseg],es
		mov	[cs:rcol],dl
		mov	[cs:rrow],dh
		pop	ds
		pop	bp
		ret
%%end:		mov	byte [cs:pass_on],0
		mov	byte [cs:rfull],0
		pop	ds
		pop	bp
		ret
%endmacro

loop_g1:	CELL_LOOP	32, 4, 0, tile_g1
loop_g2:	CELL_LOOP	32, 4, 1, tile_g2
loop_text:	CELL_LOOP	40, 3, 0, tile_text

; One pattern line: BP = pattern byte * 4, DX/CX the colour pair.
%macro LINE 0
		mov	ax,[cs:expand + bp]
		and	ax,dx
		xor	ax,cx
		stosw
		mov	ax,[cs:expand + bp + 2]
		and	ax,dx
		xor	ax,cx
		stosw
		add	di,STRIDE - 4
%endmacro

; Tiles: name AX at ES:DI, DS = VRAMSEG. Keep SI and DI.
tile_g1:	push	si
		push	di
		mov	bx,ax			; colour: col + name / 8
		shr	bx,3
		add	bx,[cs:r_col]
		mov	bl,[bx]
		xor	bh,bh
		shl	bx,2
		mov	dx,[cs:pairs + bx]
		mov	cx,[cs:pairs + bx + 2]
		mov	bx,ax			; pattern: pat + name * 8
		shl	bx,3
		add	bx,[cs:r_pat]
%rep 8
		mov	al,[bx]
		inc	bx
		xor	ah,ah
		shl	ax,2
		mov	bp,ax
		LINE
%endrep
		pop	di
		pop	si
		ret

; One Graphics II line: DS:SI its colour byte, DS:BX its pattern byte.
; The colour pair is looked up only when the colour byte differs from the
; line above's (%1 = 0: the first line); a line without dots is the
; background word twice.
%macro G2LINE 1
		lodsb
 %if %1
		cmp	al,[cs:g2_colour]
		je	%%pair
 %endif
		mov	[cs:g2_colour],al
		xor	ah,ah
		shl	ax,2
		mov	bp,ax
		mov	dx,[cs:pairs + bp]
		mov	cx,[cs:pairs + bp + 2]
%%pair:		mov	al,[bx]
		inc	bx
		or	al,al
		jz	%%blank
		xor	ah,ah
		shl	ax,2
		mov	bp,ax
		mov	ax,[cs:expand + bp]
		and	ax,dx
		xor	ax,cx
		stosw
		mov	ax,[cs:expand + bp + 2]
		and	ax,dx
		xor	ax,cx
		stosw
		jmp	%%next
%%blank:	mov	ax,cx
		stosw
		stosw
%%next:
%endmacro

; AX: third * 256 + name. The cell's image comes from CACHESEG (32 bytes
; at AX * 32, lines 4 bytes apart), made there first when g2_ok[AX] is 0
; (make_merged clears it when the cell's pattern or colour changed, every
; one on a full redraw); a cell from the cache gives half its budget back.
tile_g2:	push	si
		push	di
		push	ax
		mov	bx,ax
		cmp	byte [cs:g2_ok + bx],0
		jne	.cached
		mov	byte [cs:g2_ok + bx],1
		push	es
		push	di
		mov	di,ax
		shl	di,5
		mov	bx,CACHESEG
		mov	es,bx
		shl	ax,3
		mov	si,ax
		and	si,[cs:r_cmask]
		add	si,[cs:r_col]
		mov	bx,ax
		and	bx,[cs:r_pmask]
		add	bx,[cs:r_pat]
		G2LINE	0
%rep 7
		G2LINE	1
%endrep
		pop	di
		pop	es
		jmp	.copy
.cached:	inc	word [cs:budget]
.copy:		pop	si
		shl	si,5
		push	ds
		mov	ax,CACHESEG
		mov	ds,ax
%rep 8
		movsw
		movsw
		add	di,STRIDE - 4
%endrep
		pop	ds
		pop	di
		pop	si
		ret

; Text: 6 dots (3 bytes) a character.
tile_text:	push	si
		push	di
		mov	dx,[cs:r_text]
		mov	cx,[cs:r_text + 2]
		mov	bx,ax
		shl	bx,3
		add	bx,[cs:r_pat]
%rep 8
		mov	al,[bx]
		inc	bx
		xor	ah,ah
		shl	ax,2
		mov	bp,ax
		mov	ax,[cs:expand + bp]
		and	ax,dx
		xor	ax,cx
		stosw
		mov	al,[cs:expand + bp + 2]
		and	al,dl
		xor	al,cl
		stosb
		add	di,STRIDE - 3
%endrep
		pop	di
		pop	si
		ret

; The gaiji cells: the whole pass in one call, as the cell loop's rules
; (rows skipped, shadow, merged) but each cell drawn in place: its code in
; two columns, its attribute (FG low, BG high; colour 0 of the foreground
; is the backdrop, the background's 0 is the TSP's transparent colour,
; which shows the picture in the backdrop). After a table moved, with no
; colour pending, the names are compared with the shadow by REPE CMPSW.
; TVRAM at A0000h, DS = CS.
loop_pcg:	mov	al,[rfull]
		or	al,[pcg_cols]
		jnz	.slow
		cmp	byte [any_pend],0
		je	.slow
		push	ds
		push	es
		push	cs
		pop	es
		mov	si,[r_name]
		mov	di,shadow
		mov	cx,768 / 2
		mov	ax,VRAMSEG
		mov	ds,ax
.f:		repe	cmpsw
		je	.f_done
		mov	ax,[si - 2]		; two names, one or both new
		lea	bx,[di - 2 - shadow]	; BX: the first's cell
		cmp	al,[es:di - 2]
		je	.f_second
		mov	[es:di - 2],al
		push	ax
		call	pcg_cell
		pop	ax
.f_second:	inc	bx
		mov	al,ah
		cmp	al,[es:di - 1]
		je	.f_next
		mov	[es:di - 1],al
		call	pcg_cell
.f_next:	jcxz	.f_done
		jmp	.f
.f_done:	pop	es
		pop	ds
		mov	byte [pass_on],0
		ret
.slow:		push	bp
		push	ds
		mov	ax,0a000h
		mov	es,ax
		mov	di,TFRAME + TFRAME_VW + 16
		mov	si,[r_name]		; SI: the name's address, BP: the
		mov	bp,shadow		; shadow at [cs:bp + si]
		sub	bp,si
		mov	byte [rrow],0
		mov	ax,VRAMSEG
		mov	ds,ax
.row:		mov	al,[cs:rfull]
		or	al,[cs:any_pend]
		jnz	.scan
		mov	bl,[cs:rrow]
		xor	bh,bh
		cmp	byte [cs:row_pend + bx],0
		jne	.scan
		add	si,32
		jmp	.next
.scan:		push	di
		mov	cx,32
		mov	bx,merged
.c:		lodsb
		cmp	al,[cs:bp + si - 1]
		jne	.hit
		cs	xlatb
		or	al,al
		jnz	.hit_again
		add	di,4
		loop	.c
		jmp	.done
.hit_again:	mov	al,[si - 1]
.hit:		mov	[cs:bp + si - 1],al	; the shadow
		xor	ah,ah
		mov	bx,ax			; the attribute
		shr	bx,3
		add	bx,[cs:r_col]
		mov	dl,[bx]
		rol	dl,4
		test	dl,0fh
		jnz	.fg
		or	dl,[cs:backdrop]
.fg:		xor	dh,dh
		mov	bx,ax			; the code
		shl	bx,1
		mov	ax,[cs:pcg_code + bx]
		stosw
		stosw
		mov	[es:di + 8000h - 4],dx
		mov	[es:di + 8000h - 2],dx
		mov	bx,merged
		loop	.c
.done:		pop	di
.next:		add	di,TFRAME_VW
		inc	byte [cs:rrow]
		cmp	byte [cs:rrow],24
		jb	.row
		mov	byte [cs:pass_on],0
		mov	byte [cs:rfull],0
		pop	ds
		pop	bp
		ret

; Name AL in cell BX (row * 32 + column): its code and attribute, as
; loop_pcg draws them. DS = VRAMSEG. Keeps every register but AX, DX.
pcg_cell:	push	bx
		push	di
		push	es
		mov	di,bx			; TVRAM: TFRAME + (row + 1) *
		and	di,31			; TFRAME_VW + 16 + column * 4
		shl	di,2
		shr	bx,5
		mov	dx,bx
		shl	bx,7
		shl	dx,5
		add	di,bx
		add	di,dx
		add	di,TFRAME + TFRAME_VW + 16
		xor	ah,ah
		mov	bx,ax
		shr	bx,3
		add	bx,[cs:r_col]
		mov	dl,[bx]
		rol	dl,4
		test	dl,0fh
		jnz	.fg
		or	dl,[cs:backdrop]
.fg:		xor	dh,dh
		mov	bx,ax
		shl	bx,1
		mov	ax,[cs:pcg_code + bx]
		mov	bx,0a000h
		mov	es,bx
		stosw
		stosw
		mov	[es:di + 8000h - 4],dx
		mov	[es:di + 8000h - 2],dx
		pop	es
		pop	di
		pop	bx
		ret

; ---------------------------------------------------------------------------
; Graphics I on the TSP's text screen (docs/DESIGN.md "M05"): the 256
; patterns are the 376 half-width characters of the gaiji RAM (B0800h, JIS
; 7621h-7742h; pattern p is the left (p even) or right half of character
; p / 2), written there as they change; a cell is one code in two columns
; of a 40-column screen (the TSP doubles the dots), 8 rasters a line on a
; 200-raster screen, 16 with each pattern row twice on 400. Split screen 0
; shows TFRAME, MSX row r on its row r + 1 at column 8 + 2 * column, half a
; line down (MSX line 0 on graphics line 4). MSX.COM saved the gaiji RAM
; to GAIJI.BAK; MSX /R puts it back.

; At the start, when MSX.COM set pcg_ok: the tables, the text screen.
pcg_init:	cmp	byte [pcg_ok],0
		je	.ret
		mov	byte [pcg_on],1
		call	pcg_tables
		cli
		mov	dx,0153h		; TVRAM at A0000h
		in	al,dx
		push	ax
		and	al,0f0h
		or	al,01h
		out	dx,al
		push	es
		mov	ax,0a000h
		mov	es,ax
		xor	ax,ax			; 400 rasters when the BIOS's split
		mov	si,TTABLE + 14h		; screens are higher than 300
		mov	cx,4
.h:		mov	bx,[es:si]
		and	bx,1feh
		add	ax,bx
		add	si,20h
		loop	.h
		mov	byte [pcg_h],07h
		cmp	ax,300
		jbe	.frame
		mov	byte [pcg_h],0fh
.frame:		mov	di,TFRAME		; every column: ANK space
		mov	cx,TFRAME_ROWS * TFRAME_VW / 2
		mov	ax,0020h
		rep	stosw
		mov	di,TFRAME + 8000h
		mov	cx,TFRAME_ROWS * TFRAME_VW / 2
		xor	ax,ax
		rep	stosw
		mov	di,TTABLE		; split screen 0
		mov	word [es:di + 00h],TFRAME	; VSA
		mov	word [es:di + 02h],0
		mov	word [es:di + 04h],TFRAME_ROWS	; VH
		mov	word [es:di + 08h],TFRAME_VW	; VW
		mov	word [es:di + 0ah],0000h	; attribute mode 0
		mov	al,[pcg_h]		; raster offset: half a line
		inc	al
		shr	al,1
		mov	ah,al
		mov	al,0
		mov	[es:di + 0ch],ax
		mov	word [es:di + 10h],TFRAME	; RSA
		mov	al,[pcg_h]		; RH: 25 lines
		inc	al
		mov	ah,25
		mul	ah
		mov	[es:di + 14h],ax
		pop	es
		pop	ax
		mov	dx,0153h
		out	dx,al
		call	dspdef
		mov	al,00h			; 40 columns
		out	30h,al
		mov	al,03h			; ANKM = 0, V3, word mode
		mov	dx,0148h
		out	dx,al
		sti
.ret:		ret

; pcg_code[p]: the TSP code of pattern p's half character (JIS first byte -
; 20h, second byte, bit 15 the right half); pcg_addr[p]: its row 0 in the
; segment B000h (rows 2 bytes apart; vaeg's io/cgromva.c, checked on the
; PC-88VA and PC-88VA2).
pcg_tables:	xor	bx,bx
.p:		mov	ax,bx
		shr	ax,1			; the character
		mov	cx,7621h
		cmp	ax,94
		jb	.jis
		mov	cx,7721h - 94
.jis:		add	cx,ax			; CX: its JIS code
		mov	al,ch
		sub	al,20h
		mov	ah,cl
		test	bl,1
		jz	.left
		or	ah,80h
.left:		mov	di,bx
		shl	di,1
		mov	[pcg_code + di],ax
		mov	al,cl
		and	ax,60h
		shl	ax,6
		mov	dx,ax
		mov	al,ch
		and	ax,1
		shl	ax,10
		add	dx,ax
		mov	al,cl
		and	ax,1fh
		shl	ax,5
		add	dx,ax
		mov	ax,bx
		and	ax,1
		add	dx,ax
		mov	[pcg_addr + di],dx
		inc	bx
		cmp	bx,256
		jb	.p
		ret

; The patterns pending (every one after glyphs_all) into the gaiji RAM;
; the flags searched by REPE SCASB. DS = CS.
pcg_glyphs:	push	es
		push	cs
		pop	es
		mov	di,pat_pend
		mov	cx,256
		xor	al,al
		cmp	byte [glyphs_all],0
		jne	.window
		repe	scasb
		je	.none
.window:	mov	dx,0153h		; kanji ROM #2, the backup RAM at
		in	al,dx			; B0000h (byte access only)
		push	ax
		and	al,0f0h
		or	al,09h
		out	dx,al
		push	ds
		mov	ax,VRAMSEG
		mov	ds,ax
		cmp	byte [cs:glyphs_all],0
		je	.found
		mov	byte [cs:glyphs_all],0
		mov	ax,0b000h
		mov	es,ax
		xor	bx,bx
.all:		call	pcg_glyph
		inc	bx
		cmp	bx,256
		jb	.all
		jmp	.done
.found:		lea	bx,[di - 1 - pat_pend]	; ES:DI past the flag found
		push	di
		mov	ax,0b000h
		mov	es,ax
		call	pcg_glyph
		push	cs
		pop	es
		pop	di
		xor	al,al
		jcxz	.done
		repe	scasb
		jne	.found
.done:		pop	ds
		pop	ax
		mov	dx,0153h
		out	dx,al
.none:		pop	es
		ret

; Pattern BX into its glyph. ES = B000h, DS = VRAMSEG. Uses AL, SI, DI.
pcg_glyph:	mov	si,bx
		shl	si,3
		add	si,[cs:r_pat]
		push	bx
		shl	bx,1
		mov	di,[cs:pcg_addr + bx]
		pop	bx
		cmp	byte [cs:pcg_h],07h
		jne	.double
%assign r 0
%rep 8
		mov	al,[si + r]
		mov	[es:di + 2 * r],al
 %assign r r + 1
%endrep
		ret
.double:
%assign r 0
%rep 8
		mov	al,[si + r]
		mov	[es:di + 4 * r],al
		mov	[es:di + 4 * r + 2],al
 %assign r r + 1
%endrep
		ret

; The text frame: spaces with the transparent background. Keeps the
; window. DS = CS.
pcg_blank:	cmp	byte [pcg_on],0
		je	.ret
		push	es
		mov	dx,0153h
		in	al,dx
		push	ax
		and	al,0f0h
		or	al,01h
		out	dx,al
		mov	ax,0a000h
		mov	es,ax
		mov	di,TFRAME
		mov	cx,TFRAME_ROWS * TFRAME_VW / 2
		mov	ax,0020h
		rep	stosw
		mov	di,TFRAME + 8000h
		mov	cx,TFRAME_ROWS * TFRAME_VW / 2
		xor	ax,ax
		rep	stosw
		pop	ax
		mov	dx,0153h
		out	dx,al
		pop	es
.ret:		ret

; DSPDEF: attributes at +8000h, codes every 2 bytes, pcg_h + 1 rasters a
; line, the underline on the last raster, blink speed 18h.
dspdef:		mov	al,14h
		call	tsp_cmd
		mov	al,00h
		call	tsp_par
		mov	al,80h
		call	tsp_par
		mov	al,20h
		call	tsp_par
		mov	al,[pcg_h]
		call	tsp_par
		call	tsp_par
		mov	al,18h
		jmp	tsp_par

tsp_cmd:	push	ax
		mov	dx,0142h
.w:		in	al,dx
		test	al,05h			; IBF, BUSY
		jnz	.w
		pop	ax
		out	dx,al
		ret
tsp_par:	push	ax
		mov	dx,0142h
.w:		in	al,dx
		test	al,01h			; IBF
		jnz	.w
		pop	ax
		mov	dx,0146h
		out	dx,al
		ret

pcg_on		db	0			; 1: Graphics I on the gaiji cells
pcg_colsh	times	32 db 0			; the colours drawn
pcg_h		db	07h			; rasters a text line - 1
		align	2
pcg_code	times	256 dw 0
pcg_addr	times	256 dw 0

; ---------------------------------------------------------------------------
; Sprites, on the TSP's hardware sprites: monochrome mode, the 32
; descriptors at TVRAM 7E00h (the PC-88VA's conventional table), MSX
; sprite i on descriptor i (lower numbers in front in both). Each 8x8 MSX
; pattern written is converted into its part of a TSP image for the sprite
; size in use, its dots doubled (the TSP counts 640 dots across); the
; descriptors are rewritten every frame from the attribute table. Not yet:
; the fifth-sprite and collision flags, clipping to the 256x192 picture.

SPR_IMG		equ	1000h		; TVRAM offset of the images (16 KiB)
SPR_TABLE	equ	7e00h		; TVRAM offset of the descriptors

; In the VRTC handler, DS = CS.
sprite_step:	mov	al,[spr_all]		; nothing written: nothing to do
		or	al,[spr_dirty]
		jnz	.work
		ret
.work:		mov	byte [spr_dirty],0
		mov	dx,0153h		; TVRAM at A0000h
		in	al,dx
		push	ax
		and	al,0f0h
		or	al,01h
		out	dx,al
		mov	ax,0a000h
		mov	es,ax
		cmp	byte [spr_all],0
		je	.pats
		mov	byte [spr_all],0
		push	word [r_spt]
		mov	al,[spr_mode]
		push	ax
		call	sprite_setup
		pop	ax
		pop	si			; SI: the old pattern table
		cmp	al,[spr_mode]
		jne	.all
		cmp	byte [spr_conv],0
		je	.all
		mov	di,[r_spt]		; the table moved (double
		cmp	si,di			; buffering): the patterns that
		je	.pats			; differ
		mov	bx,spt_dirty
		mov	cx,256
		call	diff8
		jmp	.pats
.all:		mov	byte [spr_conv],1	; every pattern
		push	es
		push	cs
		pop	es
		mov	di,spt_dirty
		mov	ax,0101h
		mov	cx,128
		rep	stosw
		pop	es
.pats:		call	sprite_patterns
		call	sprite_table
		pop	ax			; GVRAM again
		mov	dx,0153h
		out	dx,al
		ret

; From R1 (SIZE, MAG), R5 and R6.
sprite_setup:	mov	al,[vregs + 6]
		and	ax,7
		shl	ax,11
		mov	[r_spt],ax
		mov	al,[vregs + 5]
		and	ax,7fh
		shl	ax,7
		mov	[r_sat],ax
		mov	bl,[vregs + 1]
		and	bx,3			; SIZE * 2 + MAG
		mov	[spr_mode],bl
		mov	al,[spr_xsize + bx]
		mov	[spr_xs],al
		mov	al,[spr_ysize + bx]
		mov	[spr_ys],al
		mov	al,[spr_ishift + bx]
		mov	[spr_is],al
		jmp	mark_rebuild

; Image geometry by mode (8x8, 8x8 magnified, 16x16, 16x16 magnified):
; XSIZE, YSIZE, log2 of the image's bytes.
spr_xsize	db	0, 0, 0, 1
spr_ysize	db	1, 3, 3, 7
spr_ishift	db	5, 6, 6, 8

; Convert the written patterns. ES = TVRAM.
sprite_patterns:
		push	es
		push	cs
		pop	es
		mov	di,spt_dirty		; the flags found by REPE SCASB
		mov	cx,256
.find:		xor	al,al
		repe	scasb
		je	.done
		mov	byte [di - 1],0
		lea	bx,[di - 1 - spt_dirty]
		pop	es
		push	cx
		push	di
		call	convert_pattern
		pop	di
		pop	cx
		push	es
		push	cs
		pop	es
		jcxz	.done
		jmp	.find
.done:		pop	es
		ret

; Pattern BX into its image part. ES = TVRAM, DS = CS.
convert_pattern:
		push	ds
		mov	si,bx			; SI: the pattern in VRAM
		shl	si,3
		add	si,[r_spt]
		mov	al,[spr_mode]
		mov	cx,VRAMSEG
		mov	ds,cx
		cmp	al,1
		jb	.m0
		je	.m1
		cmp	al,2
		je	.m2
		; 16x16 magnified: quadrant k = p & 3 at row (k & 1) * 16, byte
		; (k >> 1) * 4 of image p >> 2 (256 bytes, 8 bytes a row)
		mov	di,bx
		and	di,0fch
		shl	di,6
		mov	ax,bx
		and	ax,1
		shl	ax,7
		add	di,ax
		mov	ax,bx
		and	ax,2
		shl	ax,1
		add	di,ax
		add	di,SPR_IMG
		mov	cx,8
.m3l:		call	quad
		mov	[es:di],dx
		mov	[es:di + 2],ax
		mov	[es:di + 8],dx
		mov	[es:di + 10],ax
		add	di,16
		loop	.m3l
		pop	ds
		ret
.m0:		mov	di,bx			; 8x8: 32 bytes an image
		shl	di,5
		add	di,SPR_IMG
		mov	cx,8
.m0l:		lodsb
		xor	ah,ah
		mov	bx,ax
		shl	bx,1
		mov	ax,[cs:dbl + bx]
		stosw
		xor	ax,ax
		stosw
		loop	.m0l
		pop	ds
		ret
.m1:		mov	di,bx			; 8x8 magnified: 64 bytes, rows doubled
		shl	di,6
		add	di,SPR_IMG
		mov	cx,8
.m1l:		call	quad
		mov	[es:di],dx
		mov	[es:di + 2],ax
		mov	[es:di + 4],dx
		mov	[es:di + 6],ax
		add	di,8
		loop	.m1l
		pop	ds
		ret
.m2:		mov	di,bx			; 16x16: quadrant k at row (k & 1) * 8,
		and	di,0fch			; byte (k >> 1) * 2 of image p >> 2
		shl	di,4
		mov	ax,bx
		and	ax,1
		shl	ax,5
		add	di,ax
		mov	ax,bx
		and	ax,2
		add	di,ax
		add	di,SPR_IMG
		mov	cx,8
.m2l:		lodsb
		xor	ah,ah
		mov	bx,ax
		shl	bx,1
		mov	ax,[cs:dbl + bx]
		mov	[es:di],ax
		add	di,4
		loop	.m2l
		pop	ds
		ret

; The pattern byte at DS:SI, SI + 1, each dot made four: DX = the left
; 16 dots, AX = the right 16, as bytes in display order.
quad:		lodsb
		xor	ah,ah
		mov	bx,ax
		shl	bx,1
		mov	bx,[cs:dbl + bx]	; BL: left 8 dots, BH: right 8
		push	bx
		mov	al,bl
		xor	ah,ah
		mov	bx,ax
		shl	bx,1
		mov	dx,[cs:dbl + bx]
		pop	bx
		mov	al,bh
		xor	ah,ah
		mov	bx,ax
		shl	bx,1
		mov	ax,[cs:dbl + bx]
		ret

; The 32 descriptors from the attribute table. ES = TVRAM, DS = CS.
sprite_table:	mov	di,SPR_TABLE
		mov	si,[r_sat]
		mov	cx,32
		mov	dl,1			; DL: 1 after a Y of D0h; none with
		mov	al,[vregs + 1]		; the display off or in text mode
		and	al,50h
		cmp	al,40h
		jne	.spr
		mov	dl,0
.spr:		or	dl,dl
		jnz	.off
		push	ds
		mov	ax,VRAMSEG
		mov	ds,ax
		lodsw				; AL: Y, AH: X
		mov	bx,ax
		lodsw				; AL: pattern, AH: early clock, colour
		pop	ds
		cmp	bl,0d0h
		je	.end
		test	ah,0fh			; colour 0: nothing to show
		jz	.off2
		push	cx
		push	ax
		; Y: line Y + 1 of the picture, the top 32 lines negative
		mov	al,bl
		inc	al
		cbw
		cmp	al,0e0h
		jae	.neg
		xor	ah,ah
.neg:		add	ax,PICTURE_Y
		and	ax,1ffh
		mov	cl,[spr_ys]
		mov	ch,cl
		shl	ch,2
		or	ah,ch
		or	ah,02h			; SW
		stosw
		; X: (GFX_X * 2 + x) * 2 dots, 32 dots left with the early clock
		mov	al,bh
		xor	ah,ah
		pop	bx			; BL: pattern, BH: EC, colour
		push	bx
		test	bh,80h
		jz	.x
		sub	ax,32
.x:		add	ax,GFX_X * 2
		shl	ax,1
		and	ax,3ffh
		mov	cl,[spr_xs]
		shl	cl,3
		or	ah,cl
		or	ah,04h			; MD: monochrome
		stosw
		; SPDA: the image's TSP word address
		xor	bh,bh
		test	byte [spr_mode],2
		jz	.pat
		shr	bl,2
.pat:		mov	ax,bx
		mov	cl,[spr_is]
		shl	ax,cl
		add	ax,SPR_IMG
		shr	ax,1
		stosw
		pop	ax
		mov	al,ah			; FG
		and	al,0fh
		shl	al,4
		xor	ah,ah
		stosw
		pop	cx
		jmp	.loop
.end:		mov	dl,1
.off:		add	si,4
.off2:		xor	ax,ax			; SW = 0
		stosw
		stosw
		stosw
		stosw
.loop:		dec	cx
		jz	.ret
		jmp	.spr
.ret:		ret

; ---------------------------------------------------------------------------
; The VDP's fifth-sprite and collision flags, computed every VRTC from the
; attribute table and the patterns as the TMS9918 does: sprites up to the
; first Y of D0h; on a line only the first four count; a collision is two
; opaque dots of counted sprites on the same picture dot (colour 0 sprites
; too); the fifth-sprite number is that of the fifth sprite on the first
; line that has one. The display still shows every sprite. Computed
; again only after a write to the attribute table, a sprite pattern or a
; sprite register; the result is applied every frame. DS = CS.

sprite_flags:	mov	al,[vregs + 1]		; display off or text mode: no
		and	al,50h			; sprites, no flags
		cmp	al,40h
		je	.on
		ret
.on:		cmp	byte [f_dirty],0
		je	.apply
		mov	byte [f_dirty],0
		call	flags_compute
.apply:		cmp	byte [f_hit],0
		je	.five
		or	byte [vstatus],20h
.five:		test	byte [vstatus],40h	; latched until read
		jnz	.ret
		mov	al,[vstatus]
		and	al,0a0h
		mov	ah,[f_five]
		cmp	ah,0ffh
		je	.none
		or	al,40h
		or	al,ah
		mov	[vstatus],al
.ret:		ret
.none:		or	al,[f_last]
		mov	[vstatus],al
		ret

; f_hit, f_five (FFh: none) and f_last from the tables.
flags_compute:	push	es
		mov	al,[spr_mode]		; height = width: 8, 16 or 32
		mov	cl,al
		and	cl,1
		mov	[f_mag],cl
		mov	bx,8
		test	al,2
		jz	.h
		shl	bx,1
.h:		shl	bx,cl
		mov	[f_h],bx
		; the list of the sprites on picture lines, in order: BX the
		; sprite number, DI the list index
		mov	ax,VRAMSEG
		mov	es,ax
		mov	si,[r_sat]
		xor	bx,bx
		xor	di,di
.list:		cmp	bx,32
		jae	.listed
		mov	al,[es:si]
		cmp	al,0d0h
		je	.listed
		inc	al			; Y + 1, the top 32 negative
		cbw
		cmp	al,0e0h
		jae	.ny
		xor	ah,ah
.ny:		mov	dx,ax			; on a picture line?
		add	dx,[f_h]
		jle	.skip
		cmp	ax,192
		jge	.skip
		mov	[f_num + di],bl
		shl	di,1
		mov	[f_y + di],ax
		mov	al,[es:si + 1]
		xor	ah,ah
		test	byte [es:si + 3],80h	; early clock
		jz	.nx
		sub	ax,32
.nx:		mov	[f_x + di],ax
		shr	di,1
		mov	al,[es:si + 2]
		test	byte [spr_mode],2
		jz	.np
		and	al,0fch
.np:		mov	[f_pat + di],al
		inc	di
.skip:		add	si,4
		inc	bx
		jmp	.list
.listed:	mov	ax,di
		mov	[f_n],al
		mov	al,bl
		cmp	al,32
		jb	.last
		mov	al,31
.last:		mov	[f_last],al
		push	ds
		pop	es
		mov	byte [f_hit],0
		mov	byte [f_five],0ffh
		mov	word [f_fline],192
.pairs:		mov	di,f_cnt		; f_cnt[row]: the sprites before
		mov	cx,192 / 2		; f_j covering the row, less five
		mov	ax,0fbfbh		; (0 when the fifth is counted)
		rep	stosw
		mov	byte [f_j],0		; each sprite against the earlier
.jl:		mov	al,[f_j]		; ones until the first collision,
		cmp	al,[f_n]		; and its rows counted (with fewer
		jae	.done			; than five, up to the collision)
		call	sprite_rows
		jge	.jnext
		cmp	byte [f_j],0
		je	.count
		cmp	byte [f_hit],0
		je	.test
		cmp	byte [f_n],5
		jb	.done
		jmp	.count
.test:		call	collide_j
.count:		mov	si,[f_r0]		; f_j's rows: the sprite that makes
		mov	cx,[f_r1]		; a row's count five is its fifth;
		sub	cx,si			; f_five from the topmost such row
.c:		inc	byte [f_cnt + si]
		jnz	.cn
		cmp	si,[f_fline]
		jae	.cn
		mov	[f_fline],si
		mov	bl,[f_j]
		xor	bh,bh
		mov	al,[f_num + bx]
		mov	[f_five],al
.cn:		inc	si
		loop	.c
.jnext:		inc	byte [f_j]
		jmp	.jl
.done:		pop	es
		ret

; Sprite AL's rows on the picture: f_r0 = max(y, 0), f_r1 = min(y + h,
; 192); flags as CMP f_r0, f_r1 (GE: none). DS = CS.
sprite_rows:	xor	ah,ah
		mov	bx,ax
		shl	bx,1
		mov	ax,[f_y + bx]
		mov	dx,ax
		add	dx,[f_h]
		or	ax,ax
		jns	.r0
		xor	ax,ax
.r0:		cmp	dx,192
		jle	.r1
		mov	dx,192
.r1:		mov	[f_r0],ax
		mov	[f_r1],dx
		cmp	ax,dx
		ret

; Sprite f_j against sprites 0 .. f_j - 1 on rows f_r0 .. f_r1 - 1; sets
; f_hit. DS = CS.
collide_j:	mov	byte [f_i],0
.il:		mov	al,[f_i]
		cmp	al,[f_j]
		jb	.go
		ret
.go:		xor	ah,ah
		mov	bx,ax
		shl	bx,1
		mov	al,[f_j]
		xor	ah,ah
		mov	di,ax
		shl	di,1
		mov	ax,[f_x + bx]		; |xi - xj| < h
		sub	ax,[f_x + di]
		jns	.ax
		neg	ax
.ax:		cmp	ax,[f_h]
		jae	.inext
		mov	ax,[f_y + bx]		; rows of both
		mov	dx,ax
		add	dx,[f_h]
		cmp	ax,[f_r0]
		jge	.ry0
		mov	ax,[f_r0]
.ry0:		cmp	dx,[f_r1]
		jle	.ry1
		mov	dx,[f_r1]
.ry1:		cmp	ax,dx
		jge	.inext
		mov	si,ax
		mov	[f_rend],dx
.row:		mov	al,[f_cnt + si]		; J must be one of the first four
		sub	al,0fbh			; on the line (f_cnt: the count
		cmp	al,4			; less five)
		jae	.rnext
		call	collide_row
		cmp	byte [f_hit],0
		jne	.ret
.rnext:		inc	si
		cmp	si,[f_rend]
		jb	.row
.inext:		inc	byte [f_i]
		jmp	.il
.ret:		ret

; Sprites f_i and f_j on picture row SI, a whole row at once: each row as a
; 32-bit mask (column 0 in the top bit, dots doubled when magnified), the
; right one shifted by the X difference, ANDed, clipped to columns 0-255.
; Sets f_hit. Keeps SI.
collide_row:	push	si
		mov	al,[f_i]
		call	row_mask
		mov	[f_mi],ax
		mov	[f_mi + 2],bx
		mov	[f_xi],dx
		or	ax,bx
		jz	.ret
		mov	al,[f_j]
		call	row_mask		; BX:AX = J's mask, DX = its X
		mov	cx,ax
		or	cx,bx
		jz	.ret
		mov	di,[f_mi]		; DI:SI = I's mask
		mov	si,[f_mi + 2]
		mov	cx,[f_xi]
		cmp	cx,dx			; the left one in DI:SI, at CX
		jle	.order
		xchg	di,ax
		xchg	si,bx
		xchg	cx,dx
.order:		sub	dx,cx			; DX: X difference, 0-31
		jz	.and
.shift:		shr	bx,1
		rcr	ax,1
		dec	dx
		jnz	.shift
.and:		and	ax,di			; BX:AX = the dots of both
		and	bx,si
		or	cx,cx			; columns left of the picture
		jns	.right
		neg	cx
.lclip:		shl	ax,1
		rcl	bx,1
		loop	.lclip
		jmp	.test
.right:		mov	dx,256			; columns 256 - X .. 31 cleared
		sub	dx,cx
		cmp	dx,32
		jae	.test
		mov	cx,32
		sub	cx,dx
.rclip:		shr	bx,1
		rcr	ax,1
		loop	.rclip
.test:		or	ax,bx
		jz	.ret
		mov	byte [f_hit],1
.ret:		pop	si
		ret

; Sprite AL on picture row SI: BX:AX = its row as a 32-bit mask (BX the
; left 16 columns), DX = its X. Keeps SI.
row_mask:	call	row_bits		; AX: the pattern row, AH left
		cmp	byte [f_mag],0
		jne	.mag
		mov	bx,ax
		xor	ax,ax
		ret
.mag:		push	dx			; each dot doubled
		push	ax
		mov	bl,ah
		xor	bh,bh
		shl	bx,1
		mov	bx,[dbl + bx]
		xchg	bl,bh
		pop	ax
		push	bx
		xor	ah,ah
		mov	bx,ax
		shl	bx,1
		mov	ax,[dbl + bx]
		xchg	al,ah
		pop	bx
		pop	dx
		ret

; Sprite AL on picture row SI: AX = its pattern row (left byte high; the
; right byte for 16x16), DX = its X. Keeps SI.
row_bits:	xor	ah,ah
		mov	bx,ax
		mov	dl,[f_pat + bx]
		shl	bx,1
		push	dx
		mov	ax,si
		sub	ax,[f_y + bx]
		mov	cl,[f_mag]
		shr	ax,cl			; source row
		pop	dx
		xor	dh,dh
		shl	dx,3
		add	dx,ax
		add	dx,[r_spt]
		push	es
		push	bx
		mov	bx,VRAMSEG
		mov	es,bx
		mov	bx,dx
		and	bh,3fh
		mov	ah,[es:bx]
		xor	al,al
		test	byte [spr_mode],2
		jz	.r
		add	bx,16
		and	bh,3fh
		mov	al,[es:bx]
.r:		pop	bx
		pop	es
		mov	dx,[f_x + bx]
		ret

; pairs[c] = (fgw xor bgw, bgw) for every colour byte c (fg high nibble).
make_pairs:	push	es
		push	cs
		pop	es
		mov	di,pairs
		xor	ax,ax
.c:		push	ax
		call	pair_of
		mov	ax,dx
		stosw
		mov	ax,cx
		stosw
		pop	ax
		inc	al
		jnz	.c
		pop	es
		ret

; Colour byte AL -> DX = fgw xor bgw, CX = bgw (nibbles repeated).
pair_of:	push	ax
		push	bx
		mov	bl,al
		shr	bl,4
		call	.word
		mov	dx,bx
		pop	bx
		pop	ax
		push	ax
		push	bx
		mov	bl,al
		and	bl,0fh
		call	.word
		mov	cx,bx
		xor	dx,cx
		pop	bx
		pop	ax
		ret
.word:		or	bl,bl
		jnz	.n
		mov	bl,[backdrop]
.n:		mov	bh,bl
		shl	bh,4
		or	bl,bh
		mov	bh,bl
		ret

; ---------------------------------------------------------------------------
; Frame skipping. The VRTC handler draws the background (render_step)
; only in some frames; the sprites (sprite_step), the MSX's interrupt,
; the keyboard and the sprite flags are every frame, so a game keeps its
; speed and gets the time of the frames not drawn. draw_mode (F10): AUTO skips a frame when
; the Z80 has not yet taken the last frame's interrupt (the frame flag
; still set with R1's IE on: the game is late), at most two in a row;
; EVERY FRAME never skips; 1/2 and 1/3 draw every second or third frame.

; CF = 1: no picture this frame. Before the frame flag is set.
draw_this:	mov	bl,[draw_mode]
		xor	bh,bh
		mov	al,[skip_run]
		cmp	al,[draw_skips + bx]
		jae	.draw
		or	bl,bl
		jnz	.skip
		test	byte [vstatus],80h
		jz	.draw
		test	byte [vregs + 1],20h
		jz	.draw
.skip:		inc	byte [skip_run]
		stc
		ret
.draw:		mov	byte [skip_run],0
		inc	word [st_drawn]
		clc
		ret

; Every 60 frames: the game frames (interrupts taken) and the pictures
; drawn in them, for the settings page.
stats_tick:	inc	byte [st_count]
		cmp	byte [st_count],60
		jb	.ret
		mov	byte [st_count],0
		mov	ax,[injected]
		mov	bx,ax
		sub	ax,[st_inj0]
		mov	[st_games],ax
		mov	[st_inj0],bx
		mov	ax,[st_drawn]
		mov	[st_draws],ax
		mov	word [st_drawn],0
		mov	ax,[traps]
		mov	bx,ax
		sub	ax,[st_trap0]
		mov	[st_traps],ax
		mov	[st_trap0],bx
.ret:		ret

; ---------------------------------------------------------------------------
; The settings page. F10 (port 0Dh bit 4, or 0Ch bit 4 as vaeg has it;
; active low, as in pc88va-galaga) pauses the MSX inside the VRTC handler:
; the SSG silent, the sprites and the gaiji cells hidden, the page drawn in
; GVRAM with the MSX ROM's font (its CGTABL, word 0004h). The handler waits
; for each VRTC on port 40h bit 5 and reads the keys: cursor up and down
; select an item, left and right change it, F10 again returns, and the
; picture is drawn again in full. draw_mode and pcg_on are before vars: an
; MSX reset keeps them. DS = CS.

SVC_ITEMS	equ	4

settings_check:	call	f10_edge
		jc	settings
		ret

; CF = 1 when F10 has just been pressed (va_keys as kbd_scan read them).
f10_edge:	mov	al,[va_keys + 0dh]
		and	al,[va_keys + 0ch]
%ifdef TEST_KEYS				; vaeg tests: M (port 03h bit 5),
		mov	ah,[va_keys + 03h]	; which @hold can hold, as F10
		shr	ah,1
		and	al,ah
%endif
		not	al
		and	al,10h			; 10h while held
		mov	ah,[f10_prev]
		mov	[f10_prev],al
		not	ah
		and	al,ah
		jz	.no
		stc
		ret
.no:		clc
		ret

settings:	push	es
		mov	dx,0153h		; GVRAM at A0000h
		in	al,dx
		push	ax
		and	al,0f0h
		or	al,04h
		out	dx,al
		mov	ax,0008h		; the SSG's levels 0
.mute:		call	opn_write
		inc	al
		cmp	al,11
		jb	.mute
		call	sprites_hide
		call	pcg_blank
		call	scr_off			; the page in frame buffer 0
		mov	byte [svc_keys],0fh	; keys held now act after a release
.page:		call	settings_draw
.wait:		call	wait_vrtc
		call	kbd_scan
		call	f10_edge
		jc	.close
		call	svc_keys_new		; AL: up 1, down 2, left 4, right 8
		test	al,1
		jz	.down
		dec	byte [svc_item]
		jns	.page
		mov	byte [svc_item],SVC_ITEMS - 1
		jmp	.page
.down:		test	al,2
		jz	.change
		inc	byte [svc_item]
		cmp	byte [svc_item],SVC_ITEMS
		jb	.page
		mov	byte [svc_item],0
		jmp	.page
.change:	and	al,0ch
		jz	.wait
		cmp	byte [svc_item],1
		je	.gaiji
		cmp	byte [svc_item],2
		je	.follow
		cmp	byte [svc_item],3
		je	.scroll
		test	al,4			; draw mode: left back, right on
		jz	.right
		dec	byte [draw_mode]
		jns	.page
		mov	byte [draw_mode],3
		jmp	.page
.right:		inc	byte [draw_mode]
		and	byte [draw_mode],3
		jmp	.page
.gaiji:		cmp	byte [pcg_ok],0		; only when GAIJI.BAK holds the
		je	.wait			; gaiji RAM
		xor	byte [pcg_on],1
		mov	byte [vregchg],1	; render_setup picks the loop
		jmp	.page
.follow:	xor	byte [follow_on],1
		jmp	.page
.scroll:	xor	byte [scr_allow],1
		jmp	.page
.close:		mov	es,[gvram_seg]		; the picture again, in full
		xor	di,di
		xor	ax,ax
		mov	cx,200 * STRIDE / 2
		rep	stosw
		mov	byte [pass_on],0
		mov	byte [rfull],1
		mov	byte [vregchg],1
		mov	byte [skip_run],0
		mov	bx,8			; the SSG's levels back
.level:		mov	al,bl
		mov	ah,[psg + bx]
		call	opn_write
		inc	bx
		cmp	bx,11
		jb	.level
		pop	ax
		mov	dx,0153h
		out	dx,al
		pop	es
		ret

; AL: the cursor keys pressed since the last call (up 1, down 2, left 4,
; right 8).
svc_keys_new:	xor	al,al
		test	byte [va_keys + 08h],02h
		jnz	.d
		or	al,1
.d:		test	byte [va_keys + 0ah],02h
		jnz	.l
		or	al,2
.l:		test	byte [va_keys + 0ah],04h
		jnz	.r
		or	al,4
.r:		test	byte [va_keys + 08h],04h
		jnz	.k
		or	al,8
.k:		mov	ah,[svc_keys]
		mov	[svc_keys],al
		not	ah
		and	al,ah
		ret

; The next VRTC (port 40h bit 5 off, then on; each wait at most 65536
; reads).
wait_vrtc:	xor	cx,cx
.off:		in	al,40h
		test	al,20h
		jz	.on
		loop	.off
.on:		in	al,40h
		test	al,20h
		jnz	.ret
		loop	.on
.ret:		ret

; The 32 TSP sprite descriptors off (SW = 0).
sprites_hide:	push	es
		mov	dx,0153h
		in	al,dx
		push	ax
		and	al,0f0h
		or	al,01h
		out	dx,al
		mov	ax,0a000h
		mov	es,ax
		mov	di,SPR_TABLE
		xor	ax,ax
		mov	cx,32 * 4
		rep	stosw
		mov	byte [spr_dirty],1	; all again after
		pop	ax
		mov	dx,0153h
		out	dx,al
		pop	es
		ret

; The page: GVRAM cleared, the texts, the item values, the counts.
settings_draw:	mov	es,[gvram_seg]
		xor	di,di
		xor	ax,ax
		mov	cx,200 * STRIDE / 2
		rep	stosw
		mov	si,svc_texts
		call	texts
		mov	bl,[svc_item]		; the cursor
		xor	bh,bh
		mov	ch,[svc_rows + bx]
		mov	cl,2
		mov	dl,11
		mov	al,'>'
		call	putc_g
		mov	bl,[draw_mode]		; draw mode
		xor	bh,bh
		shl	bx,1
		mov	si,[draw_names + bx]
		mov	cx,(4 << 8) | 18
		mov	dl,15
		call	text
		mov	si,s_on			; gaiji cells
		cmp	byte [pcg_on],0
		jne	.g
		mov	si,s_off
.g:		mov	cx,(6 << 8) | 18
		call	text
		mov	si,s_on			; I/O follow
		cmp	byte [follow_on],0
		jne	.f
		mov	si,s_off
.f:		mov	cx,(8 << 8) | 18
		call	text
		mov	si,s_on			; HW scroll
		cmp	byte [scr_allow],0
		jne	.s
		mov	si,s_off
.s:		mov	cx,(9 << 8) | 18
		call	text
		cmp	byte [pcg_ok],0
		jne	.counts
		mov	si,s_no_bak
		mov	cx,(6 << 8) | 22
		mov	dl,14
		call	text
.counts:	mov	ax,[st_games]
		mov	cx,(11 << 8) | 4
		call	number
		mov	ax,[st_draws]
		mov	cx,(12 << 8) | 2
		call	number5
		mov	ax,[st_traps]
		mov	cx,(13 << 8) | 2
		call	number5
		ret

; Texts from SI: column, row, colour, characters, 0; FFh ends.
texts:		lodsb
		cmp	al,0ffh
		je	.ret
		mov	cl,al
		lodsb
		mov	ch,al
		lodsb
		mov	dl,al
		call	text
		jmp	texts
.ret:		ret

; The string at SI (0-terminated) from column CL, row CH, colour DL. SI
; after the 0.
text:		lodsb
		or	al,al
		jz	.ret
		call	putc_g
		inc	cl
		jmp	text
.ret:		ret

; AX (0-999) right-aligned in three columns from CL, row CH, colour 15.
number:		mov	dl,15
		add	cl,2
		mov	bx,10
.d:		push	cx
		xor	dx,dx
		div	bx
		pop	cx
		push	ax
		mov	al,dl
		add	al,'0'
		mov	dl,15
		call	putc_g
		pop	ax
		dec	cl
		or	ax,ax
		jnz	.d
		ret

; AX (0-65535) right-aligned in five columns from CL, row CH, colour 15.
number5:	add	cl,2
		jmp	number

; Character AL at column CL (0-39), row CH (0-24), colour DL on black,
; from the MSX ROM's font. ES = GVRAM. Keeps every register.
putc_g:		pusha
		push	ds
		mov	bl,dl			; DX: the colour in every nibble
		and	bx,0fh
		imul	dx,bx,1111h
		mov	bl,ch			; DI: the cell
		xor	bh,bh
		imul	di,bx,8 * STRIDE
		mov	bl,cl
		shl	bx,2
		add	di,bx
		xor	ah,ah
		shl	ax,3
		mov	bx,MAIN_SEG
		mov	ds,bx
		mov	si,[0004h]		; CGTABL
		add	si,ax
		mov	cx,8
.row:		lodsb
		xor	ah,ah
		shl	ax,2
		mov	bx,ax
		mov	ax,[cs:expand + bx]
		and	ax,dx
		stosw
		mov	ax,[cs:expand + bx + 2]
		and	ax,dx
		stosw
		add	di,STRIDE - 4
		loop	.row
		pop	ds
		popa
		ret

svc_rows	db	4, 6, 8, 9
draw_names	dw	s_auto, s_every, s_half, s_third
draw_skips	db	2, 0, 1, 2		; most frames skipped in a row
s_auto		db	'AUTO       ', 0
s_every		db	'EVERY FRAME', 0
s_half		db	'1/2        ', 0
s_third		db	'1/3        ', 0
s_on		db	'ON ', 0
s_off		db	'OFF', 0
s_no_bak	db	'(no GAIJI.BAK)', 0
svc_texts	db	4, 1, 15, 'msx88va settings', 0
		db	4, 4, 15, 'Draw', 0
		db	4, 6, 15, 'Gaiji cells', 0
		db	4, 8, 15, 'I/O follow', 0
		db	4, 9, 15, 'HW scroll', 0
		db	8, 11, 14, 'game frames in the last second', 0
		db	8, 12, 14, 'pictures drawn', 0
		db	8, 13, 14, 'I/O traps', 0
		db	4, 15, 14, 'AUTO skips drawing a frame when', 0
		db	4, 16, 14, 'the game is late (at most 2).', 0
		db	4, 19, 14, 'Up/down: item  left/right: change', 0
		db	4, 20, 14, 'F10: back to the game', 0
		db	0ffh

draw_mode	db	0			; 0 AUTO, 1 every frame, 2 1/2, 3 1/3
follow_on	db	0			; z80_follow on (F10; off: it costs
						; more than it saves, BENCH.ROM)
scr_allow	db	1			; scrolling by frame buffer 2
		align	2
ring_seg	dw	0			; the scroll ring (screen_init)
ring_lo		dw	0			; its GVRAM-relative address
ring_hi		dw	0
svc_item	db	0

; ---------------------------------------------------------------------------
; Text output, for the failure message only (text BIOS INT 83h)

puts:		lodsb
		or	al,al
		jz	.r
		xor	ah,ah
		mov	dx,ax
		int	83h
		jmp	puts
.r:		ret

; ---------------------------------------------------------------------------
; Data

s_fail		db	'Graphics BIOS call failed.', 13, 10, 0

; VA key (matrix port, bit) -> MSX key (row, bit), as in vaeg's io/serial.c
; and the MSX international matrix. Row 11 is joystick port 1.
%macro K 4				; VA port, bit, MSX row, bit
		db	(%1 << 4) | %2, (%3 << 4) | %4
%endmacro
key_map:
%assign k 0
%rep 8
		K	6, k, 0, k		; 0-7
 %assign k k + 1
%endrep
		K	7, 0, 1, 0		; 8
		K	7, 1, 1, 1		; 9
		K	5, 7, 1, 2		; -
		K	5, 6, 1, 3		; ^ -> =
		K	5, 4, 1, 4		; yen -> backslash
		K	5, 3, 1, 5		; [
		K	5, 5, 1, 6		; ]
		K	7, 3, 1, 7		; ;
		K	7, 2, 2, 0		; : -> '
		K	2, 0, 2, 1		; @ -> `
		K	7, 4, 2, 2		; ,
		K	7, 5, 2, 3		; .
		K	7, 6, 2, 4		; /
		K	7, 7, 2, 5		; _ -> dead key
		K	2, 1, 2, 6		; A
		K	2, 2, 2, 7		; B
%assign k 0				; C-J
%rep 8
		K	2 + (k + 3) / 8, (k + 3) % 8, 3, k
 %assign k k + 1
%endrep
%assign k 0				; K-R
%rep 8
		K	3 + (k + 3) / 8, (k + 3) % 8, 4, k
 %assign k k + 1
%endrep
%assign k 0				; S-Z
%rep 8
		K	4 + (k + 3) / 8, (k + 3) % 8, 5, k
 %assign k k + 1
%endrep
		K	8, 6, 6, 0		; SHIFT
		K	8, 7, 6, 1		; CTRL
		K	8, 4, 6, 2		; GRPH
		K	0ah, 7, 6, 3		; CAPS
		K	8, 5, 6, 4		; KANA -> CODE
		K	9, 1, 6, 5		; F1
		K	9, 2, 6, 6		; F2
		K	9, 3, 6, 7		; F3
		K	9, 4, 7, 0		; F4
		K	9, 5, 7, 1		; F5
		K	9, 7, 7, 2		; ESC
		K	0ah, 0, 7, 3		; TAB
		K	9, 0, 7, 4		; STOP
		K	8, 3, 7, 5		; INS/DEL -> BS
		K	0ch, 5, 7, 5		; BS
		K	0ch, 0, 7, 6		; F6 -> SELECT
		K	1, 7, 7, 7		; RETURN
		K	0eh, 0, 7, 7		; RETURN
		K	9, 6, 8, 0		; SPACE
		K	8, 0, 8, 1		; HOME
		K	0ch, 6, 8, 2		; INS
		K	0ch, 7, 8, 3		; DEL
		K	0ah, 2, 8, 4		; left
		K	8, 1, 8, 5		; up
		K	0ah, 1, 8, 6		; down
		K	8, 2, 8, 7		; right
		K	1, 2, 9, 0		; keypad *
		K	1, 3, 9, 1		; keypad +
		K	0ah, 6, 9, 2		; keypad /
%assign k 0				; keypad 0-4
%rep 5
		K	0, k, 9, k + 3
 %assign k k + 1
%endrep
		K	0, 5, 10, 0		; keypad 5
		K	0, 6, 10, 1		; keypad 6
		K	0, 7, 10, 2		; keypad 7
		K	1, 0, 10, 3		; keypad 8
		K	1, 1, 10, 4		; keypad 9
		K	0ah, 5, 10, 5		; keypad -
		K	1, 5, 10, 6		; keypad ,
		K	1, 6, 10, 7		; keypad .
		K	8, 1, 11, 0		; joystick: cursor keys
		K	0ah, 1, 11, 1
		K	0ah, 2, 11, 2
		K	8, 2, 11, 3
		K	9, 6, 11, 4		; trigger A: SPACE or Z
		K	5, 2, 11, 4
		K	5, 0, 11, 5		; trigger B: X
		db	0ffh, 0ffh

; TMS9918 colours as PC-88VA palette words (G at bits 15-12, R at 9-6, B at
; 4-1; a component's low bits set when it is not zero).
%macro VACOLOUR 3			; R G B, 0-255
 %assign c_r ((%1) * 15 + 127) / 255
 %assign c_g ((%2) * 15 + 127) / 255
 %assign c_b ((%3) * 15 + 127) / 255
 %assign c_gl 0
 %assign c_rl 0
 %assign c_bl 0
 %if c_g
  %assign c_gl 3
 %endif
 %if c_r
  %assign c_rl 1
 %endif
 %if c_b
  %assign c_bl 1
 %endif
		dw	(c_g << 12) | (c_gl << 10) | (c_r << 6) | (c_rl << 5) | (c_b << 1) | c_bl
%endmacro
palette:	VACOLOUR	0, 0, 0		; 0 transparent
		VACOLOUR	0, 0, 0		; 1 black
		VACOLOUR	33, 200, 66	; 2 medium green
		VACOLOUR	94, 220, 120	; 3 light green
		VACOLOUR	84, 85, 237	; 4 dark blue
		VACOLOUR	125, 118, 252	; 5 light blue
		VACOLOUR	212, 82, 77	; 6 dark red
		VACOLOUR	66, 235, 245	; 7 cyan
		VACOLOUR	252, 85, 84	; 8 medium red
		VACOLOUR	255, 121, 120	; 9 light red
		VACOLOUR	212, 193, 84	; 10 dark yellow
		VACOLOUR	230, 206, 128	; 11 light yellow
		VACOLOUR	33, 176, 59	; 12 dark green
		VACOLOUR	201, 91, 186	; 13 magenta
		VACOLOUR	204, 204, 204	; 14 grey
		VACOLOUR	255, 255, 255	; 15 white

; Pattern byte -> 4 bytes, 0Fh nibbles for the set dots (left dot in the
; high nibble).
expand:
%assign p 0
%rep 256
 %assign w 0
 %assign i 0
 %rep 8
  %if p & (80h >> i)
   %assign w w | (0fh << ((i ^ 1) * 4))
  %endif
  %assign i i + 1
 %endrep
		dd	w
 %assign p p + 1
%endrep

; A byte's dots doubled, MSB first, as two bytes in display order.
dbl:
%assign b 0
%rep 256
 %assign w 0
 %assign i 0
 %rep 8
  %if b & (1 << i)
   %assign w w | (3 << (2 * i))
  %endif
  %assign i i + 1
 %endrep
		db	w >> 8, w & 0ffh
 %assign b b + 1
%endrep



; From here to vars_end saved at the first start and restored at an MSX
; reset (SNAPSEG).
		align	2
vars:

; Block 1 = 90h-99h, block 2 = A0h-ABh (start, end; low byte first).
trap_ranges	db	90h, 0, 99h, 0, 0a0h, 0, 0abh, 0	; printer, VDP; PSG, PPI

; Slot s page p -> segment (0: empty). Slot 1 is set from cart_pages.
slot_seg	dw	MAIN_SEG, MAIN_SEG + 400h, LOGO_SEG, 0
		dw	0, 0, 0, 0
		dw	0, 0, 0, 0
		dw	RAMSEG, RAMSEG + 400h, RAMSEG + 800h, RAMSEG + 0c00h

		align	2
fb_desc		dw	4, 320, 200, 0, 0, 0
gvram_seg	dw	0
frames		dw	0
injected	dw	0
traps		dw	0
unknown		dw	0
switches	dw	0
vaddr		dw	0
render_fn	dw	loop_blank
r_name		dw	0
r_pat		dw	0
r_col		dw	0
r_pmask		dw	0
r_cmask		dw	0
r_pmi		dw	0
r_cmi		dw	0
r_patsize	dw	0
r_colsize	dw	0
r_ncells	dw	0
r_cols		dw	32
r_start		dw	0
r_text		dw	0, 0
SETUP_WORDS	equ	($ - render_fn) / 2	; render_flip compares these
old_setup	times	SETUP_WORDS dw 0
rpos		dw	0
r_spt		dw	0
r_sat		dw	0
rdest		dw	0
budget		dw	0
psg		times	16 db 0
vregs		times	8 db 0
cur_slot	db	0ffh, 0ffh, 0ffh, 0ffh
va_keys		times	15 db 0ffh
msx_keys	times	12 db 0ffh
vstatus		db	0
vlatch		db	0
vfirst		db	0
vahead		db	0
vregchg		db	1
vwrite		db	0
pass_on		db	0
rfull		db	0
r_clear		db	1
r_colshift	db	0
rrow		db	0
rcol		db	0
any_dirty	db	0
spr_all		db	1
spr_mode	db	0
spr_xs		db	0
spr_ys		db	1
spr_is		db	5
any_pend	db	0
backdrop	db	0
old_backdrop	db	0
pairs_bd	db	0ffh			; the backdrop of pairs
spr_conv	db	0			; 1: patterns converted in spr_mode
flipped		db	0			; render_flip moved a table
glyphs_all	db	1			; pcg_glyphs: every pattern
pend_set	db	1			; a pattern or colour flag pending
zf_left		db	0			; z80_follow
mark_cur	db	0			; mark_addr: the page's tables
mark_pages	times	64 db 0			; mark_rebuild
bench_reg	db	0			; ports 96h, 97h
		align	2
bench_latch	dw	0
scr_on		db	0			; rows scr_b .. 23 in the ring
scr_b		db	0
scr_n		db	0			; its rows: 24 - scr_b
scr_phase	db	0			; the ring row of picture row scr_b
scr_wait	db	0			; frames a rewrite was waited for
		align	2
scr_steps	dw	0			; scrolls done by the hardware
rseg		dw	0			; the cell loop's segment (rdest)
zf_wret		db	0			; zf_worth: a RET followed
		align	2
zf_all		dw	0
zf_pc		dw	0
skip_run	db	0			; frames skipped in a row
st_count	db	0			; stats_tick's frames
f10_prev	db	0
svc_keys	db	0
		align	2
st_drawn	dw	0			; pictures in this second
st_inj0		dw	0			; injected at its start
st_games	dw	0			; the last second's game frames
st_draws	dw	0			; and pictures
st_trap0	dw	0			; traps at the second's start
st_traps	dw	0			; and in the last second
pcg_cols	db	0			; loop_pcg: a colour pending
g2_colour	db	0			; tile_g2: the line above's colours
psg_reg		db	0
opn_io		db	0
ppi_a		db	0
ppi_c		db	0
ed_op		db	0
f_five		db	0ffh			; FFh: no fifth sprite
f_dirty		db	1			; these two adjacent:
spr_dirty	db	1			; sprite_step: SAT, SPT or registers
		align	2
vars_end:

; From here on zero at the start and at an MSX reset (zero_init).
		align	4
pairs		times	256 * 4 db 0
; Written since the pass started: patterns (by number), colours (by
; number, or by group of 8 in graphics I), name rows. Then the same for
; the pass in progress. Each set is contiguous (pass_start copies it).
pat_dirty	times	768 db 0
col_dirty	times	768 db 0
row_dirty	times	24 db 0
FLAG_BYTES	equ	$ - pat_dirty
pat_pend	times	768 db 0
col_pend	times	768 db 0
row_pend	times	24 db 0
shadow		times	960 db 0
merged		times	768 db 0
g2_ok		times	768 db 0		; tile_g2: CACHESEG image valid
scan		dw	0
spt_dirty	times	256 db 0
f_y		times	32 dw 0
f_x		times	32 dw 0
f_h		dw	0
f_r0		dw	0
f_r1		dw	0
f_rend		dw	0
f_mi		dw	0, 0
f_xi		dw	0
f_pat		times	32 db 0
f_num		times	32 db 0
f_fline		dw	0			; the topmost row with five
f_cnt		times	192 db 0
kbd_new		times	15 db 0			; kbd_scan
f_n		db	0
f_last		db	0
f_hit		db	0
f_mag		db	0
f_i		db	0
f_j		db	0
		align	2
end_of_program:
		times	CODE_BYTES - ($ - $$) db 0	; fails if the program is too large
		times	-((vars_end - vars) > SNAP_BYTES) db 0	; or the snapshot
