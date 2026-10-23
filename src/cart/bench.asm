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
; BENCH: a 16 KiB MSX cartridge that measures msx88va (z80asm 1.8).
;
; Each test runs a short Z80 routine (a "chunk": 256 operations, or one
; block operation) again and again for DURATION frames and counts the
; chunks; the result is operations per frame (one VRTC: msx88va's count
; through port 97h, which also catches interrupts the Z80 did not take).
; The I/O tests run with msx88va's I/O follow off and on (port 97h,
; register 3). ROUNDS rounds of all tests; the screen shows, per test,
; the median of the rounds so far and their spread, (max - min) /
; median. On another MSX (no 'V' at port 97h) JIFFY is the clock and
; I/O follow is not touched. SPACE after the last round runs it again.
;
;   Z80 DJNZ       DJNZ to itself (the Z80 mode's speed)
;   Z80 9 instr    INC A x 4, DEC A x 4, DJNZ
;   OUT A0         OUT (A0h),A; DJNZ (a trap each, or interpreted)
;   OUT A0+8 ins   OUT (A0h),A, the 8 INC/DEC, DJNZ
;   IN A2          IN A,(A2h); DJNZ
;   OUT 98 VRAM    OUT (98h),A; DJNZ (VRAM 3000h-)
;   OTIR 256       one OTIR of 256 bytes to 98h
;   LD/OUT/JR 256  LD A,(HL); OUT (98h),A; INC HL; DEC BC; LD A,B; OR C;
;                  JR NZ for 256 bytes (msx88va's out_loop)
;   WRTVRM BIOS    256 calls of the BIOS's WRTVRM (CALLN)
;   LDIRVM 256     one call of LDIRVM, 256 bytes

CHGET:		equ	009fh
CHPUT:		equ	00a2h
POSIT:		equ	00c6h
INITXT:		equ	006ch
SETWRT:		equ	0053h
WRTVRM:		equ	004dh
LDIRVM:		equ	005ch
LINL40:		equ	0f3aeh
JIFFY:		equ	0fc9eh
SEL:		equ	96h		; msx88va's ports
DAT:		equ	97h
SCRATCH:	equ	3000h		; VRAM unused in screens 0 and 1
ROUNDS:		equ	8		; (res_at multiplies by 8)
DURATION:	equ	120		; frames a test
NTESTS:		equ	14

RAM:		equ	0c000h
BUF:		equ	RAM		; 256 bytes 0-255
RES:		equ	RAM + 100h	; NTESTS * ROUNDS results, 4 bytes
SORTB:		equ	RAM + 300h	; ROUNDS values being sorted
D_N:		equ	RAM + 340h	; 32-bit work: N / D -> N, rest R
D_D:		equ	RAM + 344h
D_R:		equ	RAM + 348h
D_T:		equ	RAM + 34ch
CHUNKS:		equ	RAM + 350h
F0:		equ	RAM + 352h
J0:		equ	RAM + 354h
FR:		equ	RAM + 356h
ROUND:		equ	RAM + 358h
TEST:		equ	RAM + 359h
IS88:		equ	RAM + 35ah
FDEF:		equ	RAM + 35bh	; I/O follow as msx88va started
OPS:		equ	RAM + 35ch	; 0: 256 operations a chunk, 1: one
FOL:		equ	RAM + 35dh	; I/O follow of the test
ROWV:		equ	RAM + 35eh
NS:		equ	RAM + 35fh
NS1:		equ	RAM + 360h
TM:		equ	RAM + 361h
PBUF:		equ	RAM + 370h	; 10 characters

		org	4000h
		db	"AB"
		dw	init
		dw	0, 0, 0
		ds	6

init:		ei
		ld	a,40
		ld	(LINL40),a
		call	INITXT
		ld	hl,BUF			; BUF: 0, 1, 2, ...
		xor	a
fill:		ld	(hl),a
		inc	hl
		inc	a
		jr	nz,fill
		call	detect
again:		call	screen
		xor	a
		ld	(ROUND),a
rloop:		ld	hl,1901h		; "round n/8" (POSIT: H column, L row)
		call	POSIT
		ld	hl,s_round
		call	print
		ld	a,(ROUND)
		inc	a
		add	a,'0'
		call	CHPUT
		ld	hl,s_of
		call	print
		xor	a
		ld	(TEST),a
tloop:		call	one
		ld	a,(TEST)
		inc	a
		ld	(TEST),a
		cp	NTESTS
		jr	nz,tloop
		ld	a,(FDEF)		; as it was
		call	set_follow
		call	table
		ld	a,(ROUND)
		inc	a
		ld	(ROUND),a
		cp	ROUNDS
		jr	nz,rloop
		ld	hl,0117h
		call	POSIT
		ld	hl,s_done
		call	print
		call	CHGET
		jr	again

; IS88, FDEF: msx88va and its I/O follow setting?
detect:		xor	a
		ld	(IS88),a
		ld	(FDEF),a
		out	(SEL),a
		in	a,(DAT)
		cp	'V'
		ret	nz
		ld	a,1
		ld	(IS88),a
		ld	a,3
		out	(SEL),a
		in	a,(DAT)
		ld	(FDEF),a
		ret

; I/O follow = A (msx88va only).
set_follow:	ld	b,a
		ld	a,(IS88)
		or	a
		ret	z
		ld	a,3
		out	(SEL),a
		ld	a,b
		out	(DAT),a
		ret

; HL = the VRTC count (msx88va), else JIFFY.
nframes:	ld	a,(IS88)
		or	a
		jr	z,nf_j
		ld	a,1
		out	(SEL),a
		in	a,(DAT)
		ld	l,a
		ld	a,2
		out	(SEL),a
		in	a,(DAT)
		ld	h,a
		ret
nf_j:		ld	hl,(JIFFY)
		ret

; A = msx88va's register A.
reg:		out	(SEL),a
		in	a,(DAT)
		ret

; The static screen: titles, the machine, the test names.
screen:		ld	a,12
		call	CHPUT			; clear
		ld	hl,0101h
		call	POSIT
		ld	hl,s_title
		call	print
		ld	hl,0102h
		call	POSIT
		ld	a,(IS88)
		or	a
		jr	nz,sc_88
		ld	hl,s_not88
		call	print
		jr	sc_rows
sc_88:		ld	a,6
		call	reg
		ld	hl,s_cbios
		or	a
		jr	nz,sc_b
		ld	hl,s_msxbios
sc_b:		call	print
		ld	hl,s_fdef
		call	print
		ld	hl,s_off
		ld	a,(FDEF)
		or	a
		jr	z,sc_f
		ld	hl,s_on
sc_f:		call	print
		ld	a,7
		call	reg
		ld	hl,s_15k
		cp	7
		jr	z,sc_k
		ld	hl,s_24k
		cp	0fh
		jr	z,sc_k
		ld	hl,s_nogaiji
sc_k:		call	print
sc_rows:	ld	hl,0103h
		call	POSIT
		ld	hl,s_unit
		call	print
		ld	hl,0104h
		call	POSIT
		ld	hl,s_head
		call	print
		ld	hl,names
		ld	c,5			; rows 5-14
sc_n:		push	hl
		ld	h,1
		ld	l,c
		call	POSIT
		pop	hl
		call	print			; HL past the 0
		inc	c
		ld	a,c
		cp	15
		jr	nz,sc_n
		ld	hl,0110h
		call	POSIT
		ld	hl,s_note1
		call	print
		ld	hl,0111h
		call	POSIT
		ld	hl,s_note2
		call	print
		ret

; HL = the entry of test A.
entry:		ld	l,a
		ld	h,0
		ld	d,h
		ld	e,l
		add	hl,hl
		add	hl,de
		add	hl,hl			; * 6
		ld	de,tests
		add	hl,de
		ret

; Measure test TEST in round ROUND.
one:		ld	a,(TEST)
		call	entry
		ld	e,(hl)
		inc	hl
		ld	d,(hl)
		inc	hl
		push	de			; the chunk routine
		ld	a,(hl)
		ld	(OPS),a
		inc	hl
		ld	a,(hl)
		inc	hl
		cp	2
		jr	nz,on_f
		ld	a,(FDEF)
on_f:		ld	(FOL),a
		ld	a,(hl)
		ld	(ROWV),a
		ld	a,(FOL)
		call	set_follow
		call	status
		pop	ix
		ld	b,4			; a quiet screen
on_s:		halt
		djnz	on_s
		call	nframes
		ld	(F0),hl
		ld	hl,(JIFFY)
		ld	(J0),hl
		ld	hl,0
		ld	(CHUNKS),hl
on_l:		call	callix
		ld	hl,(CHUNKS)
		inc	hl
		ld	(CHUNKS),hl
		ld	hl,(JIFFY)
		ld	de,(J0)
		or	a
		sbc	hl,de
		ld	de,DURATION
		or	a
		sbc	hl,de
		jr	c,on_l
		call	nframes
		ld	de,(F0)
		or	a
		sbc	hl,de
		ld	a,h
		or	l
		jr	nz,on_fr
		inc	hl
on_fr:		ld	(FR),hl
		ld	hl,(CHUNKS)		; N = chunks * 10 (* 256) / frames
		ld	(D_N),hl
		ld	hl,0
		ld	(D_N + 2),hl
		ld	a,10
		call	mul_small
		ld	a,(OPS)
		or	a
		jr	nz,on_d
		ld	a,(D_N + 2)
		ld	(D_N + 3),a
		ld	a,(D_N + 1)
		ld	(D_N + 2),a
		ld	a,(D_N)
		ld	(D_N + 1),a
		xor	a
		ld	(D_N),a
on_d:		ld	hl,(FR)
		ld	(D_D),hl
		ld	hl,0
		ld	(D_D + 2),hl
		call	div32
		ld	a,(ROUND)
		ld	c,a
		ld	a,(TEST)
		call	res_at
		ex	de,hl
		ld	hl,D_N
		ld	bc,4
		ldir
		ret

callix:		jp	(ix)

; Line 23: the test being measured.
status:		ld	hl,0117h
		call	POSIT
		ld	hl,s_meas
		call	print
		ld	a,(ROWV)
		ld	hl,names
		or	a
		jr	z,st_n
		ld	b,a
st_s:		ld	a,(hl)			; past B names
		inc	hl
		or	a
		jr	nz,st_s
		djnz	st_s
st_n:		call	print
		ld	hl,s_foff
		ld	a,(FOL)
		or	a
		jr	z,st_f
		ld	hl,s_fon
st_f:		jp	print

; HL = RES + (test A * ROUNDS + round C) * 4.
res_at:		ld	l,a
		ld	h,0
		add	hl,hl
		add	hl,hl
		add	hl,hl			; * 8 = ROUNDS
		ld	e,c
		ld	d,0
		add	hl,de
		add	hl,hl
		add	hl,hl
		ld	de,RES
		add	hl,de
		ret

; The results of the rounds so far: median and spread of each test.
table:		xor	a
		ld	(TM),a
tb_l:		ld	a,(ROUND)		; SORTB: the rounds' values
		inc	a
		ld	(NS),a
		ld	b,a
		ld	c,0
		ld	de,SORTB
tb_g:		push	bc
		push	de
		ld	a,(TM)
		call	res_at
		pop	de
		ld	bc,4
		ldir
		pop	bc
		inc	c
		djnz	tb_g
		call	sort
		ld	a,(TM)			; the place: row, the follow column
		call	entry
		inc	hl
		inc	hl
		inc	hl
		ld	a,(hl)
		cp	2
		jr	nz,tb_f
		ld	a,(FDEF)
tb_f:		ld	b,13
		or	a
		jr	z,tb_c
		ld	b,27
tb_c:		inc	hl
		ld	a,(hl)
		add	a,5
		ld	l,a
		ld	h,b
		call	POSIT
		call	median			; D_N = the median
		call	print_val9
		ld	a,(NS)			; D_N = (max - min) * 100
		dec	a
		call	sorted
		ld	de,D_N
		ld	bc,4
		ldir
		xor	a
		call	sorted
		ld	de,D_T
		ld	bc,4
		ldir
		call	sub32
		ld	a,100
		call	mul_small
		ld	a,(NS)			; / the median
		srl	a
		call	sorted
		ld	de,D_D
		ld	bc,4
		ldir
		call	zero_d
		jr	nz,tb_d
		ld	hl,s_nopct
		call	print
		jr	tb_next
tb_d:		call	div32
		call	print_pct
tb_next:
		ld	a,(TM)
		inc	a
		ld	(TM),a
		cp	NTESTS
		jp	nz,tb_l
		ret

; HL = SORTB + A * 4.
sorted:		add	a,a
		add	a,a
		ld	e,a
		ld	d,0
		ld	hl,SORTB
		add	hl,de
		ret

; D_N = SORTB[NS / 2].
median:		ld	a,(NS)
		srl	a
		call	sorted
		ld	de,D_N
		ld	bc,4
		ldir
		ret

; Sort the NS values at SORTB, ascending (bubble).
sort:		ld	a,(NS)
		dec	a
		ret	z
		ld	(NS1),a
		ld	c,a
so_p:		push	bc
		ld	hl,SORTB
		ld	a,(NS1)
		ld	b,a
so_i:		push	bc
		push	hl
		ld	d,h
		ld	e,l
		ld	bc,4
		add	hl,bc			; DE: p, HL: q = p + 4
		push	hl
		push	de
		ld	a,(de)			; p - q
		sub	(hl)
		inc	de
		inc	hl
		ld	a,(de)
		sbc	a,(hl)
		inc	de
		inc	hl
		ld	a,(de)
		sbc	a,(hl)
		inc	de
		inc	hl
		ld	a,(de)
		sbc	a,(hl)
		pop	de
		pop	hl
		jr	c,so_n			; p < q: in order
		ld	b,4
so_s:		ld	a,(de)
		ld	c,(hl)
		ld	(hl),a
		ld	a,c
		ld	(de),a
		inc	hl
		inc	de
		djnz	so_s
so_n:		pop	hl
		ld	bc,4
		add	hl,bc
		pop	bc
		djnz	so_i
		pop	bc
		dec	c
		jr	nz,so_p
		ret

; D_N = D_N - D_T.
sub32:		ld	hl,(D_N)
		ld	de,(D_T)
		or	a
		sbc	hl,de
		ld	(D_N),hl
		ld	hl,(D_N + 2)
		ld	de,(D_T + 2)
		sbc	hl,de
		ld	(D_N + 2),hl
		ret

; D_N = D_N * A (uses D_T).
mul_small:	push	af
		ld	hl,D_N
		ld	de,D_T
		ld	bc,4
		ldir
		ld	hl,0
		ld	(D_N),hl
		ld	(D_N + 2),hl
		pop	bc			; B = A
		ld	a,b
		or	a
		ret	z
ms_l:		ld	hl,(D_N)
		ld	de,(D_T)
		add	hl,de
		ld	(D_N),hl
		ld	hl,(D_N + 2)
		ld	de,(D_T + 2)
		adc	hl,de
		ld	(D_N + 2),hl
		djnz	ms_l
		ret

; D_N = D_N / D_D, D_R = the rest (32 bits; uses D_T).
div32:		ld	hl,0
		ld	(D_R),hl
		ld	(D_R + 2),hl
		ld	b,32
dv_l:		ld	hl,D_N			; N, R shifted left
		sla	(hl)
		inc	hl
		rl	(hl)
		inc	hl
		rl	(hl)
		inc	hl
		rl	(hl)
		ld	hl,D_R
		rl	(hl)
		inc	hl
		rl	(hl)
		inc	hl
		rl	(hl)
		inc	hl
		rl	(hl)
		ld	hl,D_D			; T = R - D
		ld	a,(D_R)
		sub	(hl)
		ld	(D_T),a
		inc	hl
		ld	a,(D_R + 1)
		sbc	a,(hl)
		ld	(D_T + 1),a
		inc	hl
		ld	a,(D_R + 2)
		sbc	a,(hl)
		ld	(D_T + 2),a
		inc	hl
		ld	a,(D_R + 3)
		sbc	a,(hl)
		ld	(D_T + 3),a
		jr	c,dv_n
		ld	hl,(D_T)		; R = T, a 1 bit
		ld	(D_R),hl
		ld	hl,(D_T + 2)
		ld	(D_R + 2),hl
		ld	hl,D_N
		set	0,(hl)
dv_n:		djnz	dv_l
		ret

div10:		ld	hl,10
		ld	(D_D),hl
		ld	hl,0
		ld	(D_D + 2),hl
		jp	div32

; Z: D_N (zero_n) or D_D (zero_d) is 0. Keep HL.
zero_n:		push	hl
		ld	hl,D_N
		jr	zero
zero_d:		push	hl
		ld	hl,D_D
zero:		ld	a,(hl)
		inc	hl
		or	(hl)
		inc	hl
		or	(hl)
		inc	hl
		or	(hl)
		pop	hl
		ret

; D_N (tenths) as "nnnnnnn.n", 9 columns.
print_val9:	ld	hl,PBUF
		ld	b,9
pv_sp:		ld	(hl),' '
		inc	hl
		djnz	pv_sp
		call	div10
		ld	a,(D_R)
		add	a,'0'
		ld	(PBUF + 8),a
		ld	a,'.'
		ld	(PBUF + 7),a
		ld	hl,PBUF + 6
		ld	b,7
pv_d:		push	bc
		push	hl
		call	div10
		pop	hl
		pop	bc
		ld	a,(D_R)
		add	a,'0'
		ld	(hl),a
		dec	hl
		call	zero_n
		jr	z,pv_p
		djnz	pv_d
pv_p:		ld	hl,PBUF
		ld	b,9
		jp	print_n

; D_N (at most 999) as " nnn%".
print_pct:	ld	hl,(D_N + 2)
		ld	a,h
		or	l
		jr	nz,pp_cap
		ld	hl,(D_N)
		ld	de,1000
		or	a
		sbc	hl,de
		jr	c,pp_ok
pp_cap:		ld	hl,999
		ld	(D_N),hl
		ld	hl,0
		ld	(D_N + 2),hl
pp_ok:		ld	hl,PBUF
		ld	b,4
pp_sp:		ld	(hl),' '
		inc	hl
		djnz	pp_sp
		ld	hl,PBUF + 3
		ld	b,3
pp_d:		push	bc
		push	hl
		call	div10
		pop	hl
		pop	bc
		ld	a,(D_R)
		add	a,'0'
		ld	(hl),a
		dec	hl
		call	zero_n
		jr	z,pp_out
		djnz	pp_d
pp_out:		ld	hl,PBUF
		ld	b,4
		call	print_n
		ld	a,'%'
		jp	CHPUT

; B characters from HL.
print_n:	ld	a,(hl)
		push	hl
		push	bc
		call	CHPUT
		pop	bc
		pop	hl
		inc	hl
		djnz	print_n
		ret

; The string at HL to its 0; HL past it.
print:		ld	a,(hl)
		inc	hl
		or	a
		ret	z
		push	hl
		call	CHPUT
		pop	hl
		jr	print

; ---------------------------------------------------------------------------
; The chunks. Each leaves interrupts enabled.

t_djnz:		ld	b,0
td_l:		djnz	td_l
		ret

t_alu0:		ld	b,0
		ld	a,0eh
ta0_l:		inc	a
		inc	a
		inc	a
		inc	a
		dec	a
		dec	a
		dec	a
		dec	a
		djnz	ta0_l
		ret

t_out:		ld	b,0
		ld	a,0eh			; (PSG register 14 selected)
to_l:		out	(0a0h),a
		djnz	to_l
		ret

t_alu:		ld	b,0
		ld	a,0eh
tal_l:		out	(0a0h),a
		inc	a
		inc	a
		inc	a
		inc	a
		dec	a
		dec	a
		dec	a
		dec	a
		djnz	tal_l
		ret

t_in:		ld	a,0eh
		out	(0a0h),a
		ld	b,0
ti_l:		in	a,(0a2h)
		djnz	ti_l
		ret

t_vram:		ld	hl,SCRATCH
		call	SETWRT
		ld	b,0
		xor	a
tv_l:		out	(98h),a
		djnz	tv_l
		ret

t_otir:		ld	hl,SCRATCH
		call	SETWRT
		ld	hl,BUF
		ld	bc,0098h
		otir
		ret

t_ldout:	ld	hl,SCRATCH
		call	SETWRT
		ld	hl,BUF
		ld	bc,256
tlo_l:		ld	a,(hl)
		out	(98h),a
		inc	hl
		dec	bc
		ld	a,b
		or	c
		jr	nz,tlo_l
		ret

t_wrtvrm:	ld	hl,SCRATCH
		ld	b,0
tw_l:		ld	a,b
		call	WRTVRM
		djnz	tw_l
		ret

t_ldirvm:	ld	hl,BUF
		ld	de,SCRATCH
		ld	bc,256
		jp	LDIRVM

; The tests: chunk, OPS (0: 256 a chunk, 1: one), I/O follow (0 off,
; 1 on, 2 as msx88va has it), row, 0.
tests:		dw	t_djnz
		db	0, 2, 0, 0
		dw	t_alu0
		db	0, 2, 1, 0
		dw	t_out
		db	0, 0, 2, 0
		dw	t_out
		db	0, 1, 2, 0
		dw	t_alu
		db	0, 0, 3, 0
		dw	t_alu
		db	0, 1, 3, 0
		dw	t_in
		db	0, 0, 4, 0
		dw	t_in
		db	0, 1, 4, 0
		dw	t_vram
		db	0, 0, 5, 0
		dw	t_vram
		db	0, 1, 5, 0
		dw	t_otir
		db	1, 2, 6, 0
		dw	t_ldout
		db	1, 2, 7, 0
		dw	t_wrtvrm
		db	0, 2, 8, 0
		dw	t_ldirvm
		db	1, 2, 9, 0

names:		db	"Z80 DJNZ", 0
		db	"Z80 9 instr", 0
		db	"OUT A0", 0
		db	"OUT A0+8 ins", 0
		db	"IN A2", 0
		db	"OUT 98 VRAM", 0
		db	"OTIR 256", 0
		db	"LD/OUT/JR256", 0
		db	"WRTVRM BIOS", 0
		db	"LDIRVM 256", 0

s_title:	db	"msx88va bench", 0
s_round:	db	"round ", 0
s_of:		db	"/8", 0
s_not88:	db	"not msx88va: JIFFY clock", 0
s_msxbios:	db	"MSX BIOS", 0
s_cbios:	db	"C-BIOS", 0
s_fdef:		db	", follow ", 0
s_on:		db	"ON", 0
s_off:		db	"OFF", 0
s_15k:		db	", gaiji 8 lines", 0
s_24k:		db	", gaiji 16 lines", 0
s_nogaiji:	db	", no gaiji", 0
s_unit:		db	"per frame: median, spread", 0
s_head:		db	"I/O follow:        OFF           ON", 0
s_note1:	db	"spread = (max-min)/median of rounds", 0
s_note2:	db	"frame = VRTC; tests 2 s each", 0
s_meas:		db	"now: ", 0
s_foff:		db	" OFF        ", 0
s_fon:		db	" ON         ", 0
s_done:		db	"done. SPACE: again               ", 0
s_nopct:	db	"   -", 0
