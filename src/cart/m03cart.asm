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
; M03CART: a 16 KiB MSX test cartridge for msx88va (z80asm 1.8).
;
;   1  PSG: C E G C' by OUT to A0h/A1h, then C' G E C by the BIOS's
;      WRTPSG, half a second each, on channel A
;   2  input: the key matrix rows 0-10 (SNSMAT) now and ANDed since the
;      start (a key pressed once stays 0), GTSTCK 0 and 1, GTTRIG 0, 1
;      and 3, and a frame count, redrawn every frame

CHPUT:		equ	00a2h
POSIT:		equ	00c6h
INIT32:		equ	006fh
WRTPSG:		equ	0093h
SNSMAT:		equ	0141h
GTSTCK:		equ	00d5h
GTTRIG:		equ	00d8h
JIFFY:		equ	0fc9eh
SEEN:		equ	0c000h		; 11 rows ANDed

		org	4000h
		db	"AB"
		dw	init
		dw	0, 0, 0
		ds	6

init:		ei
		call	INIT32
		ld	hl,s_title
		call	print
		ld	hl,s_psg
		call	print

		ld	a,7			; mixer: tone A only; port B out
		out	(0a0h),a
		ld	a,0beh
		out	(0a1h),a
		ld	a,8			; level A
		out	(0a0h),a
		ld	a,12
		out	(0a1h),a
		ld	hl,notes
		ld	b,4
up:		push	bc
		xor	a			; period, low and high
		out	(0a0h),a
		ld	a,(hl)
		out	(0a1h),a
		inc	hl
		ld	a,1
		out	(0a0h),a
		ld	a,(hl)
		out	(0a1h),a
		inc	hl
		ld	b,30
		call	frames
		pop	bc
		djnz	up
		ld	b,4
down:		push	bc			; the same through WRTPSG
		dec	hl
		ld	e,(hl)
		ld	a,1
		call	WRTPSG
		dec	hl
		ld	e,(hl)
		xor	a
		call	WRTPSG
		ld	b,30
		call	frames
		pop	bc
		djnz	down
		ld	a,8
		ld	e,0
		call	WRTPSG

		ld	hl,SEEN
		ld	b,11
seen_init:	ld	(hl),0ffh
		inc	hl
		djnz	seen_init
		ld	hl,s_input
		call	print
loop:		ld	b,1
		call	frames
		ld	c,0			; rows 0-10
row:		ld	h,4			; column 4, line 5 + row
		ld	a,c
		add	a,5
		ld	l,a
		call	POSIT
		ld	a,c
		call	SNSMAT
		push	af
		call	hex
		ld	hl,SEEN
		ld	b,0
		add	hl,bc
		pop	af
		and	(hl)
		ld	(hl),a
		call	hex
		ld	a,c
		cp	10
		jr	z,sticks
		inc	c
		jr	row
sticks:		ld	hl,0c10h		; column 12, line 16
		call	POSIT
		xor	a
		call	GTSTCK
		call	hex
		ld	a,1
		call	GTSTCK
		call	hex
		xor	a
		call	GTTRIG
		call	hex
		ld	a,1
		call	GTTRIG
		call	hex
		ld	a,3
		call	GTTRIG
		call	hex
		ld	hl,0c11h
		call	POSIT
		ld	a,(JIFFY + 1)
		call	hex
		ld	a,(JIFFY)
		call	hex
		jr	loop

; Wait B frames.
frames:		halt
		djnz	frames
		ret

print:		ld	a,(hl)
		or	a
		ret	z
		call	CHPUT
		inc	hl
		jr	print

; A as two hex digits and a space.
hex:		push	af
		rrca
		rrca
		rrca
		rrca
		call	nibble
		pop	af
		call	nibble
		ld	a,' '
		jp	CHPUT
nibble:		and	0fh
		add	a,'0'
		cp	'9' + 1
		jr	c,nibble_out
		add	a,7
nibble_out:	jp	CHPUT

; Channel A periods (1.7897725 MHz / 16 / f): C4, E4, G4, C5.
notes:		dw	428, 339, 285, 214

s_title:	db	"msx88va M03 test cartridge", 13, 10, 13, 10, 0
s_psg:		db	"PSG: C E G C, C G E C", 13, 10, 0
s_input:	db	"Rows 0-10: now, seen", 13, 10
		db	13, 10, 13, 10, 13, 10, 13, 10, 13, 10, 13, 10
		db	13, 10, 13, 10, 13, 10, 13, 10, 13, 10
		db	"STICK TRIG:", 13, 10
		db	"JIFFY:", 0
