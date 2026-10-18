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
; store (RAMSEG) first. The I/O trap catches ports 98h-99h (VDP) and
; A0h-ABh (PSG, PPI); C-BIOS's VDP, PSG and keyboard routines call native
; code directly (CALLN, tools/cbios.py). The VRTC interrupt reads the VA
; keyboard into the MSX key matrix, sets the VDP's frame flag, redraws the
; changed cells of the picture from the emulated VRAM, and injects the
; Z80's mode 1 interrupt while the VDP's interrupt line is active.
;
; HELP (VA keyboard) resets the MSX.

		cpu	186
		org	0

%ifndef BASE
BASE		equ	3000h		; where MSX.COM puts this program
%endif

CODE_BYTES	equ	4000h		; this program, padded
MAIN_SEG	equ	BASE + 0400h	; C-BIOS main ROM, 32 KiB
LOGO_SEG	equ	BASE + 0c00h	; C-BIOS logo ROM, 16 KiB
CART_SEG	equ	BASE + 1000h	; cartridge, up to 32 KiB
Z80SEG		equ	BASE + 2000h	; what the Z80 sees
RAMSEG		equ	BASE + 3000h	; slot 3: 64 KiB RAM
VRAMSEG		equ	BASE + 4000h	; 16 KiB VRAM
EMPTYSEG	equ	BASE + 4400h	; 16 KiB of FFh: an empty page
STACKSEG	equ	BASE + 4800h	; 8 KiB native stack
STACK_TOP	equ	2000h
SNAPSEG		equ	BASE + 4a00h	; the variables as at the first start
MEMORY_TOP	equ	SNAPSEG + 200h	; paragraphs used, for MSX.COM

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

%macro BRKEM 1
		db	0fh, 0ffh, %1
%endmacro

		jmp	start
		align	4
header		db	'MSX88VA', 0		; checked by MSX.COM
		dw	MEMORY_TOP
cart_pages	db	0			; set by MSX.COM: 0, 1 or 2

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
.slots:		push	es			; the variables as they start, for
		mov	ax,SNAPSEG		; an MSX reset
		mov	es,ax
		mov	si,vars
		xor	di,di
		mov	cx,(end_of_program - vars) / 2
		rep	movsw
		pop	es
		sti
		call	screen_init
		jc	fail
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
.cpu:		mov	bx,ax			; paragraph of the frame buffer
		shr	bx,4
		shl	dx,12
		or	bx,dx
		mov	[gvram_seg],bx
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
		mov	ax,EMPTYSEG
		mov	es,ax
		xor	di,di
		mov	ax,0ffffh
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
.no_help:
		or	byte [vstatus],80h	; the frame flag
		call	render_step
		call	sprite_step
		call	sprite_flags
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
		mov	cx,(end_of_program - vars) / 2
		rep	movsw
		push	cs
		pop	ds
		pop	es
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
		pop	di
		pop	es
%endif
		cmp	bl,0d3h
		jne	.not_out
		add	word [bp + 2],2		; OUT (n),A
		mov	ah,bh
		call	port_out
		jmp	.done
.not_out:	cmp	bl,0dbh
		jne	.ed
		add	word [bp + 2],2		; IN A,(n)
		mov	ah,bh
		call	port_in
		mov	[bp + T_A],al
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

; Port AH, data AL. Keeps every register but AX, BX, SI.
port_out:	mov	bl,ah
		sub	bl,98h
		cmp	bl,PORTS
		jae	.ret
		xor	bh,bh
		shl	bx,1
		jmp	[out_table + bx]
.ret:		ret

; Port AH -> AL. Keeps every register but AX, BX, SI.
port_in:	mov	bl,ah
		sub	bl,98h
		cmp	bl,PORTS
		jae	io_ff
		xor	bh,bh
		shl	bx,1
		jmp	[in_table + bx]

io_ff:		mov	al,0ffh
io_none:	ret

PORTS		equ	14h			; 98h-ABh
out_table	dw	vdp_data_w, vdp_ctrl_w
		times	6 dw io_none		; 9Ah-9Fh (not trapped)
		dw	psg_addr_w, psg_data_w, io_none, io_none
		times	4 dw io_none		; A4h-A7h
		dw	ppi_a_w, io_none, ppi_c_w, ppi_ctrl_w
in_table	dw	vdp_data_r, vdp_stat_r
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
		jmp	.ret
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
		test	byte [ed_op],10h	; a repeat: the next byte in the
		jnz	.block			; same trap
		and	byte [bp + 6],0bfh	; Z = 0
		jmp	.next
.bdone:		or	byte [bp + 6],40h	; Z = 1
.next:		add	word [bp + 2],2
.ret:		pop	es
		pop	di
		pop	dx
		pop	cx
		jmp	trap.done

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

; key_in: NEWKEY = rows 0-10, then the registers as the loop leaves them.
h_keyin:	push	cs
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
		mov	ax,KEYIN_CONT
		jmp	bios_cont

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
		mov	byte [f_dirty],1
.cells:		and	ah,[vreg_cells + bx]
		jz	.ret
		mov	byte [vregchg],1
.ret:		ret

vreg_cells	db	02h, 58h, 0fh, 0ffh, 07h, 00h, 00h, 0ffh
vreg_sprites	db	00h, 43h, 00h, 00h, 00h, 7fh, 07h, 00h

; VRAM address BX was written: flag its pattern, colour or name row for
; the renderer. Keeps every register. DS = CS.
mark_addr:	push	ax
		push	dx
		push	bx
		mov	byte [vwrite],1
		mov	ax,bx
		sub	ax,[r_pat]
		cmp	ax,[r_patsize]
		jae	.col
		shr	ax,3
		mov	bx,ax
		mov	byte [pat_dirty + bx],1
		mov	byte [any_dirty],1
		pop	bx
		push	bx
.col:		mov	ax,bx
		sub	ax,[r_col]
		cmp	ax,[r_colsize]
		jae	.name
		push	cx
		mov	cl,[r_colshift]
		shr	ax,cl
		pop	cx
		mov	bx,ax
		mov	byte [col_dirty + bx],1
		mov	byte [any_dirty],1
		pop	bx
		push	bx
.name:		mov	ax,bx
		sub	ax,[r_name]
		cmp	ax,[r_ncells]
		jae	.spt
		xor	dx,dx
		div	word [r_cols]
		mov	bx,ax
		mov	byte [row_dirty + bx],1
		pop	bx
		push	bx
.spt:		mov	ax,bx
		sub	ax,[r_spt]
		cmp	ax,800h
		jae	.sat
		shr	ax,3
		mov	bx,ax
		mov	byte [spt_dirty + bx],1
		mov	byte [f_dirty],1
		pop	bx
		push	bx
.sat:		mov	ax,bx
		sub	ax,[r_sat]
		cmp	ax,80h
		jae	.ret
		mov	byte [f_dirty],1
.ret:		pop	bx
		pop	dx
		pop	ax
		ret

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
		mov	byte [f_dirty],1
.end:		mov	ax,[r_sat]		; the attribute table
		mov	dx,80h
		call	.clip
		jc	.out
		mov	byte [f_dirty],1
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

vdp_stat_r:	mov	byte [vfirst],0
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
; PSG (AY-3-8910) on the OPN's SSG. The SSG runs at 3.9936 MHz / 4 against
; the MSX's 1.7897725 MHz / 1: periods are scaled by 62400 / 111861
; (36558 / 65536).

PERIOD_SCALE	equ	36558

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
		mov	ah,al
		mov	al,6
		jmp	opn_write
.tone:		and	bl,6			; the pair's low register
		mov	ax,[psg + bx]
		and	ah,0fh
		call	scale
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

; AX = AX * PERIOD_SCALE / 65536, at least 1 if AX was not zero.
scale:		push	dx
		push	cx
		mov	cx,ax
		mov	dx,PERIOD_SCALE
		mul	dx
		mov	ax,dx
		or	ax,ax
		jnz	.ret
		or	cx,cx
		jz	.ret
		inc	ax
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
		mov	di,va_keys
		xor	dx,dx
		mov	cx,15
.in:		in	al,dx
		stosb
		inc	dx
		loop	.in
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
.done:		pop	es
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
		cmp	ah,3			; slot 3: RAM, save it
		jne	.load
		push	ds
		mov	si,bx			; Z80 page -> RAMSEG page
		mov	cl,14
		shl	si,cl
		xor	di,di
		mov	cx,bx
		shl	cx,10
		add	cx,RAMSEG
		mov	es,cx
		mov	cx,Z80SEG
		mov	ds,cx
		mov	cx,2000h
		rep	movsw
		pop	ds
.load:		mov	si,bx			; slot AL's page BX
		shl	si,1
		mov	ah,0
		shl	ax,3
		add	si,ax
		mov	ax,[slot_seg + si]
		or	ax,ax
		jnz	.copy
		mov	ax,EMPTYSEG
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
		inc	word [switches]
.next:		shr	dl,2
		inc	bx
		cmp	bx,4
		jb	.page
		pop	es
		pop	di
		pop	dx
		pop	cx
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
		je	.ret
.start:		call	pass_start
.go:		mov	word [budget],MAX_TILES
		jmp	[render_fn]
.ret:		ret

pass_start:	mov	byte [vwrite],0
		cmp	byte [vregchg],0
		je	.pend
		mov	byte [vregchg],0
		call	render_setup
		mov	byte [rfull],1
.pend:		push	es			; pending <- written, written <- 0
		push	cs
		pop	es
		mov	si,pat_dirty
		mov	di,pat_pend
		mov	cx,FLAG_BYTES / 2
		rep	movsw
		mov	di,pat_dirty
		xor	ax,ax
		mov	cx,FLAG_BYTES / 2
		rep	stosw
		pop	es
		mov	al,[any_dirty]
		mov	[any_pend],al
		mov	byte [any_dirty],0
		xor	ax,ax
		mov	[rpos],ax
		mov	[rrow],al
		mov	[rcol],al
		mov	ax,[r_start]
		mov	[rdest],ax
		mov	byte [pass_on],1
		cmp	byte [rfull],0
		je	.ret
		cmp	byte [r_clear],0
		je	.ret
		call	clear_picture
.ret:		ret

; The 256x192 picture in the backdrop colour.
clear_picture:	mov	es,[gvram_seg]
		mov	di,PICTURE_Y * STRIDE + GFX_X
		mov	al,[backdrop]
		mov	ah,al
		shl	ah,4
		or	al,ah
		mov	ah,al
		mov	dx,192
.l:		mov	cx,128 / 2
		rep	stosw
		add	di,STRIDE - 128
		dec	dx
		jnz	.l
		ret

; From the registers: the cell loop, the tables and their sizes for
; mark_addr, the colour pairs.
render_setup:	mov	al,[vregs + 7]		; backdrop
		and	al,0fh
		mov	[backdrop],al
		call	make_pairs
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
		ret
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

; The cell loop of a mode. %1: cells a row, %2: bytes a cell, %3: the
; check of cell SI's name AL (jumps to .draw or .next; AH free), %4: the
; tile routine (AX as left by %3). DS = CS on entry.
%macro CELL_LOOP 4
		mov	es,[gvram_seg]
		push	bp
		push	ds
		mov	si,[rpos]
		mov	di,[rdest]
		mov	ax,VRAMSEG
		mov	ds,ax
%%cell:		cmp	si,[cs:r_ncells]
		jae	%%end
		cmp	byte [cs:rcol],0	; a row start: skip the row?
		jne	%%test
		cmp	byte [cs:rfull],0
		jne	%%test
		cmp	byte [cs:any_pend],0
		jne	%%test
		mov	bl,[cs:rrow]
		xor	bh,bh
		cmp	byte [cs:row_pend + bx],0
		jne	%%test
		add	si,%1
		add	di,8 * STRIDE
		inc	byte [cs:rrow]
		jmp	%%cell
%%test:		mov	bx,[cs:r_name]
		mov	al,[bx + si]
		xor	ah,ah
		%3
.draw:		mov	[cs:shadow + si],al
		call	%4
		dec	word [cs:budget]
.next:		inc	si
		add	di,%2
		inc	byte [cs:rcol]
		cmp	byte [cs:rcol],%1
		jb	%%budget
		mov	byte [cs:rcol],0
		inc	byte [cs:rrow]
		add	di,8 * STRIDE - %1 * %2
%%budget:	cmp	word [cs:budget],0
		jne	%%cell
		mov	[cs:rpos],si
		mov	[cs:rdest],di
		pop	ds
		pop	bp
		ret
%%end:		mov	byte [cs:pass_on],0
		mov	byte [cs:rfull],0
		pop	ds
		pop	bp
		ret
%endmacro

%macro CHECK_G1 0
		cmp	byte [cs:rfull],0
		jne	.draw
		cmp	al,[cs:shadow + si]
		jne	.draw
		mov	bx,ax
		cmp	byte [cs:pat_pend + bx],0
		jne	.draw
		shr	bx,3
		cmp	byte [cs:col_pend + bx],0
		je	.next
%endmacro

%macro CHECK_G2 0
		mov	ah,[cs:rrow]		; AX: third * 256 + name
		shr	ah,3
		cmp	byte [cs:rfull],0
		jne	.draw
		cmp	al,[cs:shadow + si]
		jne	.draw
		mov	bx,ax
		and	bx,[cs:r_pmi]
		cmp	byte [cs:pat_pend + bx],0
		jne	.draw
		mov	bx,ax
		and	bx,[cs:r_cmi]
		cmp	byte [cs:col_pend + bx],0
		je	.next
%endmacro

%macro CHECK_TEXT 0
		cmp	byte [cs:rfull],0
		jne	.draw
		cmp	al,[cs:shadow + si]
		jne	.draw
		mov	bx,ax
		cmp	byte [cs:pat_pend + bx],0
		je	.next
%endmacro

loop_g1:	CELL_LOOP	32, 4, CHECK_G1, tile_g1
loop_g2:	CELL_LOOP	32, 4, CHECK_G2, tile_g2
loop_text:	CELL_LOOP	40, 3, CHECK_TEXT, tile_text

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

; AX: third * 256 + name.
tile_g2:	push	si
		push	di
		shl	ax,3
		mov	si,ax
		and	si,[cs:r_cmask]
		add	si,[cs:r_col]
		mov	bx,ax
		and	bx,[cs:r_pmask]
		add	bx,[cs:r_pat]
%rep 8
		lodsb				; the line's colours
		xor	ah,ah
		shl	ax,2
		push	bx
		mov	bx,ax
		mov	dx,[cs:pairs + bx]
		mov	cx,[cs:pairs + bx + 2]
		pop	bx
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
sprite_step:	mov	dx,0153h		; TVRAM at A0000h
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
		call	sprite_setup
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
		ret

; Image geometry by mode (8x8, 8x8 magnified, 16x16, 16x16 magnified):
; XSIZE, YSIZE, log2 of the image's bytes.
spr_xsize	db	0, 0, 0, 1
spr_ysize	db	1, 3, 3, 7
spr_ishift	db	5, 6, 6, 8

; Convert the written patterns. ES = TVRAM.
sprite_patterns:
		xor	bx,bx
.next:		cmp	byte [spt_dirty + bx],0
		jne	.one
.skip:		inc	bl
		jnz	.next
		ret
.one:		mov	byte [spt_dirty + bx],0
		push	bx
		call	convert_pattern
		pop	bx
		jmp	.skip

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
		mov	dl,0			; DL: 1 after a Y of D0h
		test	byte [vregs + 1],40h	; display off: no sprites
		jnz	.spr
		mov	dl,1
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

sprite_flags:	test	byte [vregs + 1],40h	; display off: nothing
		jnz	.on
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
		push	ds			; counts 0, fifth numbers FFh
		pop	es
		mov	di,f_cnt
		xor	ax,ax
		mov	cx,96
		rep	stosw
		mov	di,f_fifth
		dec	ax
		mov	cx,96
		rep	stosw
		mov	byte [f_hit],0
		; sprite J against the earlier ones, then its lines counted
		mov	byte [f_j],0
.jl:		mov	al,[f_j]
		cmp	al,[f_n]
		jae	.result
		xor	ah,ah
		mov	bx,ax
		shl	bx,1
		mov	ax,[f_y + bx]		; rows max(y, 0) .. min(y + h, 192)
		mov	dx,ax
		add	dx,[f_h]
		or	ax,ax
		jns	.r0
		xor	ax,ax
.r0:		cmp	dx,192
		jle	.r1
		mov	dx,192
.r1:		cmp	ax,dx
		jge	.jnext
		mov	[f_r0],ax
		mov	[f_r1],dx
		cmp	byte [f_hit],0
		jne	.count
		call	collide_j
.count:		mov	si,[f_r0]
.cl:		mov	al,[f_cnt + si]
		cmp	al,4
		jne	.inc
		cmp	byte [f_fifth + si],0ffh
		jne	.inc
		mov	bl,[f_j]
		xor	bh,bh
		mov	ah,[f_num + bx]
		mov	[f_fifth + si],ah
.inc:		cmp	al,0ffh
		je	.cn
		inc	byte [f_cnt + si]
.cn:		inc	si
		cmp	si,[f_r1]
		jb	.cl
.jnext:		inc	byte [f_j]
		jmp	.jl
.result:	mov	si,f_fifth		; the first line with a fifth
		mov	cx,192
.fl:		lodsb
		cmp	al,0ffh
		jne	.found
		loop	.fl
.found:		mov	[f_five],al
		pop	es
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
.row:		cmp	byte [f_cnt + si],4	; J not shown on this line
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


; Everything from here on is saved at the first start and restored at an
; MSX reset.
		align	2
vars:

; Block 1 = 98h-99h, block 2 = A0h-ABh (start, end; low byte first).
trap_ranges	db	98h, 0, 99h, 0, 0a0h, 0, 0abh, 0

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
psg_reg		db	0
opn_io		db	0
ppi_a		db	0
ppi_c		db	0
ed_op		db	0
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
f_cnt		times	192 db 0
f_fifth		times	192 db 0
f_n		db	0
f_last		db	0
f_hit		db	0
f_five		db	0ffh
f_dirty		db	1
f_mag		db	0
f_i		db	0
f_j		db	0
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

		align	2
end_of_program:
		times	CODE_BYTES - ($ - $$) db 0	; fails if the program is too large
