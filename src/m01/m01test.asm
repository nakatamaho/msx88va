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
; M01TEST: can Z80 I/O in the uPD9002's compatible mode be trapped to native
; code fast enough for an MSX1 (docs/DESIGN.md)?
;
; Started at BASE:0000 (3000h) by M01TEST.COM (src/dos/msxcom.asm) under
; MS-DOS 4.0; it was first a self-booting disk at 2000:0000 (the M01
; results). Each probe copies a Z80 snippet
; to 5000:0100, enables the I/O trap (block 1 = 98h-99h, block 2 =
; A0h-ABh, IN and OUT, byte ports), runs it with BRKEM, and the snippet
; returns with RETEM. The trap handler (INT 7Ch/7Dh) decodes the Z80 I/O
; instruction at the saved CS:IP and emulates a TMS9918-style VRAM port
; pair at 98h/99h (16 KiB at 6000:0000) and plain latches at A0h-ABh.
;
; A Z80 OUT (n),A drives A on address lines 8-15 and OUT (C),r drives B.
; Whether the trap compares those lines is not known, so the probes with
; a zero high byte come first; if a later one is not trapped, its access
; reaches the VA's own I/O space at that 16-bit port.

		cpu	186
		org	0

Z80SEG		equ	5000h		; the 64 KiB compatible-mode space
VRAMSEG		equ	6000h		; 16 KiB emulated VRAM
BRKEM_VEC	equ	70h		; 40h-7Bh unused (technical manual, vector map)
CALLN_VEC	equ	71h
TRAP_IN_VEC	equ	7ch
TRAP_OUT_VEC	equ	7dh
VRTC_VEC	equ	0ah
ICU0		equ	188h
ICU1		equ	18ah
TRAP_RANGE	equ	0ffe0h		; FFE0h-FFE7h: two inclusive port ranges
TRAP_CTRL	equ	0ffefh		; bit 0 IN, bit 1 OUT, bit 4 word ports

COUNTER		equ	0ff00h		; Z80 address: VRTC count (word)
PROBE_PC	equ	0100h		; Z80 address of the probe snippets
SRC_DATA	equ	0180h		; Z80 addresses used by the block probe
DST_DATA	equ	0190h
LOG_MAX		equ	16

%macro BRKEM 1
		db	0fh, 0ffh, %1
%endmacro

start:		cli
		mov	ax,cs
		mov	ds,ax
		mov	es,ax
		mov	ss,ax
		mov	sp,0fffeh
		cld
		call	install
		sti

menu:		call	text_init
		mov	si,s_title
		call	puts
		mov	si,s_mask
		call	puts
		mov	al,[old_mask]
		call	puthex8
		mov	si,s_mon
		call	puts
		mov	dx,01cbh
		in	al,dx
		call	puthex8
		mov	si,s_menu
		call	puts
.key:		call	wait_key
		cmp	al,'1'
		je	probes
		jmp	.key

; ---------------------------------------------------------------------------
; Interrupt setup

install:	xor	ax,ax
		mov	es,ax
		mov	ax,[es:VRTC_VEC * 4]
		mov	[old_vrtc],ax
		mov	ax,[es:VRTC_VEC * 4 + 2]
		mov	[old_vrtc + 2],ax
		mov	word [es:VRTC_VEC * 4],vrtc
		mov	[es:VRTC_VEC * 4 + 2],cs
		mov	word [es:CALLN_VEC * 4],calln_min
		mov	[es:CALLN_VEC * 4 + 2],cs
		mov	ax,trap
		call	set_trap
		mov	dx,ICU1
		in	al,dx
		mov	[old_mask],al
		test	al,04h			; IR2 already enabled: the ROM
		jnz	.masked			; has a handler; chain to it
		mov	byte [chain],1
.masked:	and	al,0fbh
		mov	[old_mask_ir2],al
		out	dx,al
		call	trap_off
		push	cs
		pop	es
		ret

; INT 7Ch and 7Dh -> CS:AX
set_trap:	push	es
		push	bx
		xor	bx,bx
		mov	es,bx
		mov	[es:TRAP_IN_VEC * 4],ax
		mov	[es:TRAP_IN_VEC * 4 + 2],cs
		mov	[es:TRAP_OUT_VEC * 4],ax
		mov	[es:TRAP_OUT_VEC * 4 + 2],cs
		pop	bx
		pop	es
		ret

; Ranges written as eight byte OUTs, as the VA2 boot ROM does.
trap_on:	push	si
		mov	si,trap_ranges
		mov	dx,TRAP_RANGE
.r:		lodsb
		out	dx,al
		inc	dx
		cmp	dx,TRAP_RANGE + 8
		jb	.r
		mov	al,03h			; IN and OUT, byte ports
		mov	dx,TRAP_CTRL
		out	dx,al
		pop	si
		ret

trap_off:	xor	al,al
		mov	dx,TRAP_CTRL
		out	dx,al
		ret

; BRKEM_VEC -> Z80SEG:AX
set_entry:	push	es
		push	bx
		xor	bx,bx
		mov	es,bx
		mov	[es:BRKEM_VEC * 4],ax
		mov	word [es:BRKEM_VEC * 4 + 2],Z80SEG
		pop	bx
		pop	es
		ret

; ---------------------------------------------------------------------------
; VRTC interrupt: counts frames in the Z80 space

vrtc:		push	ax
		push	dx
		push	ds
		mov	ax,Z80SEG
		mov	ds,ax
		inc	word [COUNTER]
		cmp	byte [cs:in_z80],0
		jne	.eoi
		cmp	byte [cs:chain],0
		je	.eoi
		pop	ds
		pop	dx
		pop	ax
		jmp	far [cs:old_vrtc]
.eoi:		mov	al,20h
		mov	dx,ICU0
		out	dx,al
		pop	ds
		pop	dx
		pop	ax
		iret

; ---------------------------------------------------------------------------
; I/O trap handler. The frame is that of an interrupt; the saved CS:IP is
; expected at the trapped instruction (98IOE's rule for native code). If
; the bytes there are not a Z80 I/O instruction, the two bytes before are
; tried, in case the compatible-mode frame points after the instruction.

F_ES		equ	0			; [bp+n] after PUSHA, PUSH DS, PUSH ES
F_DS		equ	2
F_BX		equ	12			; Z80 HL
F_DX		equ	14			; Z80 DE
F_CX		equ	16			; Z80 BC
F_AX		equ	18			; Z80 A in AL
F_IP		equ	20
F_CS		equ	22

trap:		pusha
		push	ds
		push	es
		mov	bp,sp
		push	cs
		pop	ds
		inc	word [traps]
		les	si,[bp + F_IP]
		cmp	word [traps],1
		jne	.first_done
		mov	[first_ip],si
.first_done:	call	decode
		jnc	.known
		sub	si,2
		call	decode
		jc	.unknown
		mov	byte [after],1
.known:		mov	al,[t_op0]
		mov	ah,[t_op1]
		cmp	byte [t_block],0
		jne	.block
		cmp	byte [t_out],0
		je	.in
		xor	al,al			; OUT (C),0 has no register
		mov	bl,[t_reg]
		or	bl,bl
		jz	.out
		xor	bh,bh
		mov	di,bx
		mov	al,[bp + di]
.out:		call	dev_out
		jmp	.next
.in:		call	dev_in
		mov	bl,[t_reg]
		or	bl,bl
		jz	.next			; IN F,(C): flags not emulated
		xor	bh,bh
		mov	di,bx
		mov	[bp + di],al
.next:		add	si,2
.set_ip:	mov	[bp + F_IP],si
		pop	es
		pop	ds
		popa
		iret
		; INI/IND/INIR/INDR, OUTI/OUTD/OTIR/OTDR: one iteration per trap;
		; while a repeat's B is not zero the instruction is run again.
.block:		mov	es,[bp + F_DS]		; Z80 data segment
		mov	bx,[bp + F_BX]
		dec	byte [bp + F_CX + 1]
		test	byte [t_op1],01h
		jz	.blk_in
		mov	al,[es:bx]
		call	dev_out
		jmp	.blk_hl
.blk_in:	call	dev_in
		mov	[es:bx],al
.blk_hl:	inc	word [bp + F_BX]
		test	byte [t_op1],08h
		jz	.blk_rep
		sub	word [bp + F_BX],2
.blk_rep:	test	byte [t_op1],10h
		jz	.next
		cmp	byte [bp + F_CX + 1],0
		je	.next
		jmp	.set_ip
.unknown:	inc	word [unknown]		; let it run untrapped
		call	trap_off
		pop	es
		pop	ds
		popa
		iret

; ES:SI: instruction. CF = 1 if not Z80 I/O; else t_op0, t_op1, t_port,
; t_out, t_reg (frame offset of the register, 0 for none) and t_block set,
; and an entry is added to the log.
decode:		mov	al,[es:si]
		mov	ah,[es:si + 1]
		mov	[t_op0],al
		mov	[t_op1],ah
		mov	byte [t_block],0
		mov	byte [t_reg],F_AX
		mov	[t_port],ah
		mov	byte [t_out],0
		cmp	al,0dbh			; IN A,(n)
		je	.log
		mov	byte [t_out],1
		cmp	al,0d3h			; OUT (n),A
		je	.log
		cmp	al,0edh
		jne	.no
		mov	dl,[bp + F_CX]		; port C
		mov	[t_port],dl
		mov	bl,ah
		and	bl,0c6h
		cmp	bl,40h			; ED 40-7F, bits 0-2 = 0 or 1
		jne	.blk
		mov	bl,ah
		and	bl,01h
		mov	[t_out],bl
		mov	bl,ah
		shr	bl,3
		and	bx,7
		mov	bl,[regoff + bx]
		mov	[t_reg],bl
		jmp	.log
.blk:		mov	bl,ah
		and	bl,0e6h
		cmp	bl,0a2h			; ED A2/A3/AA/AB/B2/B3/BA/BB
		jne	.no
		mov	bl,ah
		and	bl,01h
		mov	[t_out],bl
		mov	byte [t_block],1
.log:		mov	bx,[log_n]
		cmp	bx,LOG_MAX
		jae	.done
		shl	bx,2
		mov	[log + bx],al
		mov	[log + bx + 1],ah
		mov	dl,[t_port]
		mov	[log + bx + 2],dl
		mov	dl,[t_out]
		mov	[log + bx + 3],dl
		inc	word [log_n]
.done:		clc
		ret
.no:		stc
		ret

; Z80 register number (B C D E H L (HL) A) -> frame offset (0: none).
regoff		db	F_CX + 1, F_CX, F_DX + 1, F_DX, F_BX + 1, F_BX, 0, F_AX

; Port [t_port], data AL. 98h: VRAM data; 99h: the two-byte address or
; register write; A0h-ABh: latches.
dev_out:	push	es
		push	bx
		mov	bl,[t_port]
		cmp	bl,98h
		je	.vram
		cmp	bl,99h
		je	.ctrl
		xor	bh,bh
		mov	[ports + bx - 0a0h],al
		jmp	.done
.vram:		mov	bx,VRAMSEG
		mov	es,bx
		mov	bx,[vaddr]
		mov	[es:bx],al
		call	vinc
		mov	byte [vfirst],0
		jmp	.done
.ctrl:		cmp	byte [vfirst],0
		jne	.second
		mov	[vlatch],al
		mov	byte [vfirst],1
		jmp	.done
.second:	mov	byte [vfirst],0
		test	al,80h
		jz	.addr
		mov	bl,al
		and	bx,7
		mov	ah,[vlatch]
		mov	[vregs + bx],ah
		jmp	.done
.addr:		mov	bl,al			; bit 6: write set-up
		mov	ah,al
		and	ah,3fh
		mov	al,[vlatch]
		mov	[vaddr],ax
		test	bl,40h
		jnz	.done
		call	vread
.done:		pop	bx
		pop	es
		ret

; Port [t_port] -> AL.
dev_in:		push	es
		push	bx
		mov	bl,[t_port]
		cmp	bl,98h
		je	.vram
		cmp	bl,99h
		je	.status
		xor	bh,bh
		mov	al,[ports + bx - 0a0h]
		jmp	.done
.vram:		mov	al,[vahead]
		mov	byte [vfirst],0
		push	ax
		call	vread
		pop	ax
		jmp	.done
.status:	mov	al,[vstatus]
		mov	byte [vfirst],0
.done:		pop	bx
		pop	es
		ret

; Read-ahead: vahead = VRAM[vaddr++].
vread:		push	es
		push	bx
		mov	bx,VRAMSEG
		mov	es,bx
		mov	bx,[vaddr]
		mov	bl,[es:bx]
		mov	[vahead],bl
		pop	bx
		pop	es
vinc:		inc	word [vaddr]
		and	word [vaddr],3fffh
		ret

; Minimal handlers for the cost probe.
trap_min:	push	bp			; skip OUT (n),A if IP is at it
		push	ds
		push	si
		mov	bp,sp
		lds	si,[bp + 6]
		cmp	byte [si],0d3h
		jne	.ret
		add	word [bp + 6],2
.ret:		pop	si
		pop	ds
		pop	bp
		iret

calln_min:	iret

; ---------------------------------------------------------------------------
; Probes

; Copy probe SI (CX bytes) to Z80 PROBE_PC, run it with traps on and
; return the Z80 registers: AL = A, CX = BC, DX = DE, BX = HL.
run_probe:	push	es
		push	di
		mov	ax,Z80SEG
		mov	es,ax
		mov	di,PROBE_PC
		rep	movsb
		pop	di
		pop	es
		mov	ax,PROBE_PC
		call	set_entry
		xor	ax,ax
		mov	[traps],ax
		mov	[unknown],ax
		mov	[log_n],ax
		mov	[first_ip],ax
		mov	byte [after],0
		mov	byte [vfirst],0
		push	ds
		push	bp
		cli
		mov	al,0fbh			; only VRTC while the Z80 code runs
		mov	dx,ICU1
		out	dx,al
		call	trap_on
		mov	byte [in_z80],1
		mov	ax,Z80SEG
		mov	ds,ax
		xor	ax,ax
		xor	cx,cx
		xor	dx,dx
		xor	bx,bx
		sti
		BRKEM	BRKEM_VEC
		cli
		mov	byte [cs:in_z80],0
		push	ax
		push	dx
		call	trap_off
		mov	al,[cs:old_mask_ir2]
		mov	dx,ICU1
		out	dx,al
		pop	dx
		pop	ax
		sti
		pop	bp
		pop	ds
		ret

%macro PROBE 1				; snippet label
		mov	si,%1
		mov	cx,%1_end - %1
%endmacro

probes:		call	text_init
		mov	si,s_probes
		call	puts
		mov	ax,Z80SEG		; clear the Z80 space and VRAM
		mov	es,ax
		xor	di,di
		xor	ax,ax
		mov	cx,8000h
		rep	stosw
		mov	ax,VRAMSEG
		mov	es,ax
		xor	di,di
		mov	cx,2000h
		rep	stosw
		push	cs
		pop	es
		mov	di,ports		; latches read back as EEh
		mov	al,0eeh
		mov	cx,12
		rep	stosb
		mov	byte [ports + 3],0c3h	; A3h reads C3h

		; out-a0: OUT (n),A with A = 0
		mov	si,s_out0
		call	puts
		PROBE	z_out0
		call	run_probe
		cmp	word [traps],2
		jne	.out0_v
		cmp	word [ports + 0],0000h	; A0h, A1h
.out0_v:	call	verdict
		call	crlf
		call	show_traps

		; in-a0: IN A,(n) with A = 0
		mov	si,s_in0
		call	puts
		PROBE	z_in0
		call	run_probe
		mov	[r_a],al
		cmp	word [traps],1
		jne	.in0_v
		cmp	byte [r_a],0c3h
.in0_v:		call	verdict
		call	show_a
		call	show_traps

		; io-c0: OUT (C),r and IN r,(C) with B = 0
		mov	si,s_ioc0
		call	puts
		PROBE	z_ioc0
		call	run_probe
		call	save_regs
		cmp	word [traps],2
		jne	.ioc0_v
		cmp	byte [ports + 4],11h	; A4h
		jne	.ioc0_v
		cmp	byte [r_de + 1],11h	; D
.ioc0_v:	call	verdict
		call	show_regs
		call	show_traps

		; cost: loop iterations per frame
		mov	si,s_cost
		call	puts
		PROBE	z_base
		call	run_probe
		mov	[n_base],bx
		mov	ax,trap_min
		call	set_trap
		PROBE	z_out
		call	run_probe
		mov	[n_min],bx
		mov	ax,trap
		call	set_trap
		PROBE	z_out
		call	run_probe
		mov	[n_full],bx
		PROBE	z_calln
		call	run_probe
		mov	[n_calln],bx
		mov	si,s_nbase
		call	puts
		mov	ax,[n_base]
		call	putdec16
		mov	si,s_nmin
		call	puts
		mov	ax,[n_min]
		call	putdec16
		mov	si,s_nfull
		call	puts
		mov	ax,[n_full]
		call	putdec16
		mov	si,s_ncalln
		call	puts
		mov	ax,[n_calln]
		call	putdec16
		call	crlf

		; high: A and B not zero on address lines 8-15
		mov	si,s_high
		call	puts
		PROBE	z_high
		call	run_probe
		call	save_regs
		cmp	word [traps],5
		jne	.high_v
		cmp	word [ports + 1],0a55ah	; A1h = 5Ah, A2h = A5h
		jne	.high_v
		cmp	byte [ports + 5],33h	; A5h
		jne	.high_v
		cmp	byte [r_a],0c3h
		jne	.high_v
		cmp	byte [r_hl + 1],33h	; H
.high_v:	call	verdict
		call	show_regs
		call	show_traps

		; vdp-block: address set-up on 99h, OTIR and INIR on 98h
		mov	si,s_block
		call	puts
		mov	ax,Z80SEG
		mov	es,ax
		mov	word [es:SRC_DATA],3412h
		mov	word [es:SRC_DATA + 2],7856h
		push	cs
		pop	es
		PROBE	z_block
		call	run_probe
		call	save_regs
		cmp	word [traps],12
		jne	.block_v
		cmp	word [r_hl],DST_DATA + 4
		jne	.block_v
		cmp	byte [r_bc + 1],0
		jne	.block_v
		push	ds
		mov	ax,VRAMSEG
		mov	ds,ax
		mov	ax,[0]
		mov	dx,[2]
		pop	ds
		cmp	ax,3412h
		jne	.block_v
		cmp	dx,7856h
		jne	.block_v
		push	ds
		mov	ax,Z80SEG
		mov	ds,ax
		mov	ax,[DST_DATA]
		mov	dx,[DST_DATA + 2]
		pop	ds
		cmp	ax,3412h
		jne	.block_v
		cmp	dx,7856h
.block_v:	call	verdict
		call	show_regs
		call	show_traps

		mov	si,s_done
		call	puts
		call	wait_key
		jmp	menu

save_regs:	mov	[r_a],al
		mov	[r_bc],cx
		mov	[r_de],dx
		mov	[r_hl],bx
		ret

; ZF = 1: PASS, else FAIL.
verdict:	mov	si,s_pass
		je	.p
		mov	si,s_fail
.p:		jmp	puts

show_a:		mov	si,s_a
		call	puts
		mov	al,[r_a]
		call	puthex8
		jmp	crlf

show_regs:	mov	si,s_a
		call	puts
		mov	al,[r_a]
		call	puthex8
		mov	si,s_bc
		call	puts
		mov	ax,[r_bc]
		call	puthex16
		mov	si,s_de
		call	puts
		mov	ax,[r_de]
		call	puthex16
		mov	si,s_hl
		call	puts
		mov	ax,[r_hl]
		call	puthex16
		jmp	crlf

; traps=N unknown=N IP=xxxx at|after, then the first log entries as
; op0 op1 port and i or o.
show_traps:	mov	si,s_traps
		call	puts
		mov	ax,[traps]
		call	puthex16
		mov	si,s_unknown
		call	puts
		mov	ax,[unknown]
		call	puthex16
		mov	si,s_ip
		call	puts
		mov	ax,[first_ip]
		call	puthex16
		mov	si,s_at
		cmp	byte [after],0
		je	.w
		mov	si,s_after
.w:		call	puts
		call	crlf
		mov	si,s_indent
		call	puts
		xor	bx,bx
.e:		cmp	bx,[log_n]
		jae	.end
		cmp	bx,6
		jae	.end
		push	bx
		shl	bx,2
		mov	al,[log + bx]
		call	puthex8
		mov	al,[log + bx + 1]
		call	puthex8
		mov	al,':'
		call	putc
		mov	al,[log + bx + 2]
		call	puthex8
		mov	al,'i'
		cmp	byte [log + bx + 3],0
		je	.d
		mov	al,'o'
.d:		call	putc
		mov	al,' '
		call	putc
		pop	bx
		inc	bx
		jmp	.e
.end:		jmp	crlf

; ---------------------------------------------------------------------------
; Text output (text BIOS INT 83h) and keyboard (INT 82h)

text_init:	mov	ah,2ah			; initialise the text screen
		int	83h
		mov	ax,1702h		; clear the whole split screen
		int	83h
		xor	dx,dx
		mov	ah,08h
		int	83h
		ret

putc:		pusha
		push	ds
		push	es
		xor	ah,ah
		mov	dx,ax
		int	83h
		pop	es
		pop	ds
		popa
		ret

puts:		push	ax
.l:		mov	al,[cs:si]
		inc	si
		or	al,al
		jz	.r
		call	putc
		jmp	.l
.r:		pop	ax
		ret

crlf:		mov	si,s_crlf
		jmp	puts

puthex16:	push	ax
		mov	al,ah
		call	puthex8
		pop	ax
puthex8:	push	ax
		shr	al,4
		call	.digit
		pop	ax
		and	al,0fh
.digit:		push	ax
		add	al,'0'
		cmp	al,'9'
		jbe	.out
		add	al,7
.out:		call	putc
		pop	ax
		ret

; AX as five decimal digits.
putdec16:	push	bx
		push	cx
		push	dx
		mov	bx,10
		mov	cx,5
.div:		xor	dx,dx
		div	bx
		push	dx
		loop	.div
		mov	cx,5
.put:		pop	ax
		add	al,'0'
		call	putc
		loop	.put
		pop	dx
		pop	cx
		pop	bx
		ret

wait_key:	mov	ah,0ch
		int	82h
		mov	ah,09h
		int	82h
		ret

; ---------------------------------------------------------------------------
; Z80 probe snippets (hand-assembled; each ends with DI, RETEM)

%define JR(op, target) db op, ((target) - ($ + 2)) & 0ffh

z_out0:		db	31h, 00h, 0feh		; ld sp,0FE00h
		db	0afh			; xor a
		db	0d3h, 0a0h		; out (0A0h),a
		db	0d3h, 0a1h		; out (0A1h),a
		db	0f3h			; di
		db	0edh, 0fdh		; retem
z_out0_end:

z_in0:		db	31h, 00h, 0feh		; ld sp,0FE00h
		db	0afh			; xor a
		db	0dbh, 0a3h		; in a,(0A3h)
		db	0f3h			; di
		db	0edh, 0fdh		; retem
z_in0_end:

z_ioc0:		db	31h, 00h, 0feh		; ld sp,0FE00h
		db	01h, 0a4h, 00h		; ld bc,00A4h
		db	3eh, 11h		; ld a,11h
		db	0edh, 79h		; out (c),a
		db	0edh, 50h		; in d,(c)
		db	0f3h			; di
		db	0edh, 0fdh		; retem
z_ioc0_end:

; Cost loops: count iterations until the next VRTC, after a frame edge.
%macro COST 1-*				; body bytes
		db	31h, 00h, 0feh		; ld sp,0FE00h
		db	0fbh			; ei
		db	2ah, 00h, 0ffh		; ld hl,(COUNTER)
%%sync:		db	3ah, 00h, 0ffh		; ld a,(COUNTER)
		db	0bdh			; cp l
		JR(28h, %%sync)			; jr z,sync
		db	47h			; ld b,a
		db	21h, 00h, 00h		; ld hl,0
%%loop:		db	23h			; inc hl
		db	0afh			; xor a
		db	%{1:-1}		; body
		db	3ah, 00h, 0ffh		; ld a,(COUNTER)
		db	0b8h			; cp b
		JR(28h, %%loop)			; jr z,loop
		db	0f3h			; di
		db	0edh, 0fdh		; retem
%endmacro

z_base:		COST	00h, 00h		; nop; nop
z_base_end:
z_out:		COST	0d3h, 98h		; out (98h),a
z_out_end:
z_calln:	COST	0edh, 0edh, CALLN_VEC	; calln CALLN_VEC
z_calln_end:

z_high:		db	31h, 00h, 0feh		; ld sp,0FE00h
		db	3eh, 5ah		; ld a,5Ah
		db	0d3h, 0a1h		; out (0A1h),a
		db	3eh, 0a5h		; ld a,0A5h
		db	0d3h, 0a2h		; out (0A2h),a
		db	3eh, 77h		; ld a,77h
		db	0dbh, 0a3h		; in a,(0A3h)
		db	01h, 0a5h, 12h		; ld bc,12A5h
		db	1eh, 33h		; ld e,33h
		db	0edh, 59h		; out (c),e
		db	06h, 34h		; ld b,34h
		db	0edh, 60h		; in h,(c)
		db	0f3h			; di
		db	0edh, 0fdh		; retem
z_high_end:

z_block:	db	31h, 00h, 0feh		; ld sp,0FE00h
		db	0afh			; xor a
		db	0d3h, 99h		; out (99h),a
		db	3eh, 40h		; ld a,40h
		db	0d3h, 99h		; out (99h),a     write address 0000h
		db	21h				; ld hl,SRC_DATA
		dw	SRC_DATA
		db	01h, 98h, 04h		; ld bc,0498h
		db	0edh, 0b3h		; otir
		db	0afh			; xor a
		db	0d3h, 99h		; out (99h),a
		db	0d3h, 99h		; out (99h),a     read address 0000h
		db	21h				; ld hl,DST_DATA
		dw	DST_DATA
		db	01h, 98h, 04h		; ld bc,0498h
		db	0edh, 0b2h		; inir
		db	0f3h			; di
		db	0edh, 0fdh		; retem
z_block_end:

; ---------------------------------------------------------------------------
; Data

s_title		db	'msx88va M01: compatible-mode I/O trap test', 13, 10, 0
s_mask		db	'ICU mask at boot: ', 0
s_mon		db	'  port 1CBh: ', 0
s_menu		db	13, 10, 13, 10
		db	'1  I/O trap probes', 13, 10, 0
s_probes	db	'I/O trap probes (a hang: report the last line shown)', 13, 10, 0
s_out0		db	'out-a0   ', 0
s_in0		db	'in-a0    ', 0
s_ioc0		db	'io-c0    ', 0
s_cost		db	'cost     iterations/frame', 13, 10, 0
s_nbase		db	'         none=', 0
s_nmin		db	' trap-min=', 0
s_nfull		db	' trap=', 0
s_ncalln	db	' calln=', 0
s_high		db	'high     ', 0
s_block		db	'vdp-block', 0
s_pass		db	'PASS ', 0
s_fail		db	'FAIL ', 0
s_a		db	' A=', 0
s_bc		db	' BC=', 0
s_de		db	' DE=', 0
s_hl		db	' HL=', 0
s_traps		db	'         traps=', 0
s_unknown	db	' unknown=', 0
s_ip		db	' IP=', 0
s_at		db	' at', 0
s_after		db	' after', 0
s_indent	db	'         ', 0
s_done		db	13, 10, 'Done. Press a key for the menu.', 13, 10, 0
s_crlf		db	13, 10, 0

; Block 1 = 98h-99h, block 2 = A0h-ABh (start, end; low byte first).
trap_ranges	db	98h, 0, 99h, 0, 0a0h, 0, 0abh, 0

		align	2
old_vrtc	dd	0
traps		dw	0
unknown		dw	0
first_ip	dw	0
log_n		dw	0
log		times	LOG_MAX * 4 db 0
vaddr		dw	0
n_base		dw	0
n_min		dw	0
n_full		dw	0
n_calln		dw	0
r_bc		dw	0
r_de		dw	0
r_hl		dw	0
ports		times	12 db 0		; A0h-ABh
vregs		times	8 db 0
old_mask	db	0
old_mask_ir2	db	0
chain		db	0
in_z80		db	0
after		db	0
r_a		db	0
t_op0		db	0
t_op1		db	0
t_port		db	0
t_out		db	0
t_reg		db	0
t_block		db	0
vlatch		db	0
vfirst		db	0
vahead		db	0
vstatus		db	9fh
