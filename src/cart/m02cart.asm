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
; M02CART: a 16 KiB MSX test cartridge for msx88va (z80asm 1.8).
;
;   1  screen 2: sixteen colour bars with a grid, about 3 seconds
;   2  screen 1: VRAM write benchmarks, 768 bytes ten times each, in
;      frames (JIFFY): OTIR, the BIOS's LDIRVM, an OUT (98h),A loop
;   3  BEEP, then the results stay on the screen

CHPUT:		equ	00a2h
BEEP:		equ	00c0h
INIT32:		equ	006fh
INIGRP:		equ	0072h
SETWRT:		equ	0053h
LDIRVM:		equ	005ch
FILVRM:		equ	0056h
JIFFY:		equ	0fc9eh
SCRATCH:	equ	3000h		; unused VRAM in screen 1
BUFFER:		equ	0c000h		; 768 bytes of RAM

		org	4000h
		db	"AB"
		dw	init
		dw	0, 0, 0
		ds	6

init:		ei
		call	INIGRP
		call	bars
		ld	b,180
wait:		halt
		djnz	wait

		call	INIT32
		ld	hl,s_title
		call	print
		ld	hl,BUFFER		; buffer: 0, 1, 2, ...
		xor	a
fill:		ld	(hl),a
		inc	hl
		inc	a
		ld	b,a
		ld	a,h
		cp	0c3h
		ld	a,b
		jr	nz,fill

		ld	hl,s_otir
		call	print
		call	start
		ld	b,10
otir_l:		push	bc
		ld	hl,SCRATCH
		call	SETWRT
		ld	hl,BUFFER
		ld	c,98h
		ld	b,0
		otir
		otir
		otir
		pop	bc
		djnz	otir_l
		call	result

		ld	hl,s_ldirvm
		call	print
		call	start
		ld	b,10
ldirvm_l:	push	bc
		ld	hl,BUFFER
		ld	de,SCRATCH
		ld	bc,768
		call	LDIRVM
		pop	bc
		djnz	ldirvm_l
		call	result
		ld	hl,s_check		; VRAM 3001h and 32FFh: 01 FF
		call	print
		ld	hl,SCRATCH + 1
		call	rdvrm
		call	hex
		ld	a,' '
		call	CHPUT
		ld	hl,SCRATCH + 767
		call	rdvrm
		call	hex
		ld	hl,s_crlf
		call	print

		ld	hl,s_out
		call	print
		call	start
		ld	b,10
out_l:		push	bc
		ld	hl,SCRATCH
		call	SETWRT
		ld	d,3
		ld	b,0
out_i:		out	(98h),a
		djnz	out_i
		dec	d
		jr	nz,out_i
		pop	bc
		djnz	out_l
		call	result

		call	BEEP
		ld	hl,s_done
		call	print
idle:		halt
		jr	idle

; Screen 2: pattern table all FFh except a grid line, colour table bars.
bars:		ld	hl,0000h		; patterns: FFh, the last line 00h
		ld	bc,1800h
		ld	a,0ffh
		call	FILVRM
		ld	hl,0007h
		ld	b,0
bars_grid:	push	bc
		push	hl
		xor	a
		call	wrvrm
		pop	hl
		ld	de,8
		add	hl,de
		pop	bc
		ld	a,h
		cp	18h
		jr	c,bars_grid
		ld	hl,1800h		; names: 0..255, three times
		call	SETWRT
		ld	d,3
		ld	b,0
		xor	a
bars_name:	out	(98h),a
		inc	a
		djnz	bars_name
		dec	d
		jr	nz,bars_name
		ld	hl,2000h		; colours: column / 2 -> foreground,
		call	SETWRT			; background 1 (black)
		ld	d,24
bars_row:	ld	e,0
bars_col:	ld	a,e
		and	1eh
		rlca
		rlca
		rlca
		or	1
		ld	b,8
bars_line:	out	(98h),a
		djnz	bars_line
		inc	e
		ld	a,e
		cp	32
		jr	nz,bars_col
		dec	d
		jr	nz,bars_row
		ret

wrvrm:		push	af			; VRAM[HL] = A
		call	SETWRT
		pop	af
		out	(98h),a
		ret

rdvrm:		ld	a,l			; A = VRAM[HL]
		out	(99h),a
		ld	a,h
		and	3fh
		out	(99h),a
		ex	(sp),hl
		ex	(sp),hl
		in	a,(98h)
		ret

start:		halt				; from a frame edge
		ld	hl,(JIFFY)
		ld	(t0),hl
		ret

result:		ld	hl,(JIFFY)
		ld	de,(t0)
		or	a
		sbc	hl,de
		call	decimal
		ld	hl,s_frames
		jp	print

print:		ld	a,(hl)
		or	a
		ret	z
		call	CHPUT
		inc	hl
		jr	print

; HL as five decimal digits.
decimal:	ld	de,10000
		call	digit
		ld	de,1000
		call	digit
		ld	de,100
		call	digit
		ld	de,10
		call	digit
		ld	a,l
		add	a,'0'
		jp	CHPUT
digit:		ld	a,'0' - 1
digit_l:	inc	a
		or	a
		sbc	hl,de
		jr	nc,digit_l
		add	hl,de
		jp	CHPUT

hex:		push	af
		rrca
		rrca
		rrca
		rrca
		call	nibble
		pop	af
nibble:		and	0fh
		add	a,'0'
		cp	'9' + 1
		jr	c,nibble_out
		add	a,7
nibble_out:	jp	CHPUT

s_title:	db	"msx88va M02 test cartridge", 13, 10, 13, 10
		db	"768 bytes x 10:", 13, 10, 0
s_otir:		db	" OTIR   ", 0
s_ldirvm:	db	" LDIRVM ", 0
s_out:		db	" OUT    ", 0
s_frames:	db	" frames", 13, 10, 0
s_check:	db	" VRAM 3001h, 32FFh: ", 0
s_crlf:		db	" (01 FF)", 13, 10, 0
s_done:		db	13, 10
		db	"Finished.", 13, 10, 0

t0:		equ	0c400h
