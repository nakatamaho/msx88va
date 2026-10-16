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
; Loaded by src/boot/ipl.asm to 2000:0000; the builder (tools/build.py)
; appends the C-BIOS main ROM (MAIN_SEG), its logo ROM (LOGO_SEG) and an
; optional cartridge (CART_SEG, CART_PAGES 16 KiB pages from page 1).
;
; The Z80 sees one 64 KiB segment (Z80SEG). Writes to port A8h copy the
; selected slots' pages into it; RAM pages are copied back to their slot-3
; store (RAMSEG) first. The I/O trap catches ports 98h-99h (VDP) and
; A0h-ABh (PSG, PPI). The VRTC interrupt sets the VDP's frame flag, draws a
; band of the picture from the emulated VRAM, and injects the Z80's mode 1
; interrupt while the VDP's interrupt line is active.
;
; ESC (VA keyboard) restarts the machine.

		cpu	186
		org	0

%ifndef CART_PAGES
CART_PAGES	equ	0
%endif

CODE_BYTES	equ	4000h		; this program, padded
MAIN_SEG	equ	2400h		; C-BIOS main ROM, 32 KiB
LOGO_SEG	equ	2c00h		; C-BIOS logo ROM, 16 KiB
CART_SEG	equ	3000h		; cartridge, up to 32 KiB
Z80SEG		equ	4000h		; what the Z80 sees
RAMSEG		equ	5000h		; slot 3: 64 KiB RAM
VRAMSEG		equ	6000h		; 16 KiB VRAM
EMPTYSEG	equ	6400h		; 16 KiB of FFh: an empty page
STACKSEG	equ	6800h

BRKEM_VEC	equ	70h		; 40h-7Bh unused (technical manual, vector map)
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
ROWS_PER_FRAME	equ	2		; character rows drawn per VRTC

%macro BRKEM 1
		db	0fh, 0ffh, %1
%endmacro

start:		cli
		mov	ax,cs
		mov	ds,ax
		mov	es,ax
		mov	ax,STACKSEG
		mov	ss,ax
		mov	sp,0fffeh
		cld
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
		mov	si,palette
		mov	dx,0300h
		mov	cx,16
.colour:	lodsw
		out	dx,ax
		add	dx,2
		loop	.colour
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
		in	al,09h			; ESC (bit 7, active low)
		test	al,80h
		jnz	.no_esc
		jmp	0ffffh:0000h
.no_esc:	or	byte [vstatus],80h	; the frame flag
		call	render_step
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

; ED-prefixed I/O: IN r,(C), OUT (C),r, and the block instructions, one
; iteration per trap (a repeat with B not zero runs again). IN r,(C) sets
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
.bz:		and	byte [bp + 6],0bfh	; Z = (B = 0)
		cmp	byte [bp + T_BC + 1],0
		jne	.bnz
		or	byte [bp + 6],40h
		jmp	.next
.bnz:		test	byte [ed_op],10h
		jnz	.ret			; a repeat: run it again
.next:		add	word [bp + 2],2
.ret:		pop	es
		pop	di
		pop	dx
		pop	cx
		jmp	trap.done

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
		inc	bx
		and	bh,3fh
		mov	[vaddr],bx
		mov	byte [vfirst],0
		mov	byte [vdirty],1
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
		mov	[vregs + bx],al
		mov	byte [vdirty],1
		ret
.addr:		mov	bl,al			; bit 6: write set-up
		and	al,3fh
		mov	ah,al
		mov	al,[vlatch]
		mov	[vaddr],ax
		test	bl,40h
		jnz	.ret
		jmp	vread
.ret:		ret

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
.joy:		mov	al,0bfh			; no joystick; bit 6: JIS layout
		ret

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
		and	bx,0fh
		mov	al,0ffh			; M02: no keys
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
; Rendering: ROWS_PER_FRAME character rows per VRTC; a pass over the 24
; rows starts again when VRAM or a register was written during the last
; one. Graphics I and II, and text; no sprites yet (M03). Colour 0 is the
; backdrop (R7 bits 0-3).

render_step:	cmp	byte [rrow],24
		jb	.go
		cmp	byte [vdirty],0		; a pass done: another if changed
		je	.ret
		mov	byte [vdirty],0
		mov	byte [rrow],0
		call	render_setup
.go:		mov	cx,ROWS_PER_FRAME
.row:		push	cx
		call	[render_fn]
		pop	cx
		inc	byte [rrow]
		cmp	byte [rrow],24
		jae	.ret
		loop	.row
.ret:		ret

; From the registers: the row function, the tables, the colour pairs.
render_setup:	mov	al,[vregs + 7]		; backdrop
		and	al,0fh
		mov	[backdrop],al
		call	make_pairs
		mov	al,[vregs + 2]		; name table
		and	ax,0fh
		shl	ax,10
		mov	[r_name],ax
		mov	word [render_fn],row_blank
		test	byte [vregs + 1],40h
		jz	.ret
		test	byte [vregs + 1],10h
		jnz	.text
		test	byte [vregs + 1],08h
		jnz	.ret			; multicolour: not drawn (blank)
		test	byte [vregs + 0],02h
		jnz	.g2
		mov	al,[vregs + 4]		; graphics I
		and	ax,7
		shl	ax,11
		mov	[r_pat],ax
		mov	al,[vregs + 3]
		xor	ah,ah
		shl	ax,6
		mov	[r_col],ax
		mov	word [render_fn],row_g1
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
		mov	word [render_fn],row_g2
		ret
.text:		mov	al,[vregs + 4]
		and	ax,7
		shl	ax,11
		mov	[r_pat],ax
		mov	al,[vregs + 7]		; text colours
		xor	ah,ah
		call	pair_of
		mov	[r_text],dx
		mov	[r_text + 2],cx
		mov	word [render_fn],row_text
.ret:		ret

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

; ES:DI = start of the current row in GVRAM, for byte offset AX.
row_dest:	mov	es,[gvram_seg]
		push	ax
		mov	al,[rrow]
		xor	ah,ah
		mov	di,8 * STRIDE
		mul	di
		add	ax,PICTURE_Y * STRIDE
		pop	di
		add	di,ax
		ret

row_blank:	mov	ax,GFX_X
		call	row_dest
		mov	al,[backdrop]
		mov	ah,al
		shl	ah,4
		or	al,ah
		mov	ah,al
		mov	dx,8
.l:		mov	cx,128 / 2
		rep	stosw
		add	di,STRIDE - 128
		dec	dx
		jnz	.l
		ret

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

row_g1:		mov	ax,GFX_X
		call	row_dest
		push	bp
		push	ds
		mov	si,[r_name]		; SI: name table entry
		mov	al,[rrow]
		xor	ah,ah
		shl	ax,5
		add	si,ax
		mov	ax,VRAMSEG
		mov	ds,ax
		mov	byte [cs:r_count],32
.tile:		lodsb				; name
		xor	ah,ah
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
		sub	di,8 * STRIDE - 4
		dec	byte [cs:r_count]
		jnz	.tile
		pop	ds
		pop	bp
		ret

row_g2:		mov	ax,GFX_X
		call	row_dest
		push	bp
		push	ds
		mov	si,[r_name]
		mov	al,[rrow]
		xor	ah,ah
		mov	[r_third],ah		; third of the screen: row / 8
		mov	bl,al
		shr	bl,3
		mov	[r_third + 1],bl
		shl	ax,5
		add	si,ax
		mov	ax,VRAMSEG
		mov	ds,ax
		mov	byte [cs:r_count],32
.tile:		lodsb
		mov	ah,[cs:r_third + 1]	; (third * 256 + name) * 8
		shl	ax,3
		mov	bx,ax
		and	bx,[cs:r_cmask]
		add	bx,[cs:r_col]
		mov	[cs:r_cptr],bx
		mov	bx,ax
		and	bx,[cs:r_pmask]
		add	bx,[cs:r_pat]
%rep 8
		push	bx
		mov	bx,[cs:r_cptr]
		mov	al,[bx]
		inc	word [cs:r_cptr]
		xor	ah,ah
		shl	ax,2
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
		sub	di,8 * STRIDE - 4
		dec	byte [cs:r_count]
		jnz	.tile
		pop	ds
		pop	bp
		ret

; Text: 40 characters of 6 dots (3 bytes); the borders in the backdrop.
row_text:	mov	ax,TEXT_X
		call	row_dest
		push	bp
		push	ds
		mov	al,[rrow]
		mov	ah,40
		mul	ah
		mov	si,[r_name]
		add	si,ax
		mov	dx,[r_text]
		mov	cx,[r_text + 2]
		mov	ax,VRAMSEG
		mov	ds,ax
		mov	byte [cs:r_count],40
.char:		lodsb
		xor	ah,ah
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
		sub	di,8 * STRIDE - 3
		dec	byte [cs:r_count]
		jnz	.char
		pop	ds
		pop	bp
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

; Block 1 = 98h-99h, block 2 = A0h-ABh (start, end; low byte first).
trap_ranges	db	98h, 0, 99h, 0, 0a0h, 0, 0abh, 0

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

; Slot s page p -> segment (0: empty).
%assign c1 0
%assign c2 0
%if CART_PAGES >= 1
 %assign c1 CART_SEG
%endif
%if CART_PAGES >= 2
 %assign c2 CART_SEG + 400h
%endif
slot_seg	dw	MAIN_SEG, MAIN_SEG + 400h, LOGO_SEG, 0
		dw	0, c1, c2, 0
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
render_fn	dw	row_blank
r_name		dw	0
r_pat		dw	0
r_col		dw	0
r_pmask		dw	0
r_cmask		dw	0
r_third		dw	0
r_cptr		dw	0
r_text		dw	0, 0
psg		times	16 db 0
vregs		times	8 db 0
cur_slot	db	0ffh, 0ffh, 0ffh, 0ffh
vstatus		db	0
vlatch		db	0
vfirst		db	0
vahead		db	0
vdirty		db	1
rrow		db	24
r_count		db	0
backdrop	db	0
psg_reg		db	0
opn_io		db	0
ppi_a		db	0
ppi_c		db	0
ed_op		db	0
		align	4
pairs		times	256 * 4 db 0

end_of_program:
		times	CODE_BYTES - ($ - $$) db 0	; fails if the program is too large
