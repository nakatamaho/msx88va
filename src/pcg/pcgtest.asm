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
; PCGTEST: can the TSP's text screen show an MSX Graphics I picture with
; user-defined characters (docs/DESIGN.md "M05")?
;
; Started at BASE:0000 (3000h) by PCGTEST.COM (src/dos/msxcom.asm) under
; MS-DOS 4.0. The 256 MSX patterns are the 376 half-width characters of the
; gaiji RAM (the battery-backed RAM at B0800h, JIS 7621h-7742h; pattern p is
; the left (p even) or right half of character p / 2). In 40-column mode
; (port 30h 80CM = 0) the TSP shows a character's 8 dots doubled when the
; same code is in an even and the next odd column, so one MSX cell is two
; columns with one code, 8 text rows of 8 rasters each. Each pattern shows
; its number in hex (rows 1-5), a dot at the top left (row 0) and, from the
; direct write, one at the bottom right (row 6); rows 8-15 are a checker
; that a line height of 8 hides. The colours change every 8 patterns as in
; Graphics I; MSX rows 0-11 have the transparent background, rows 12-22 an
; opaque one. Behind, GVRAM has 8x8 squares at the MSX cells (PICTURE_Y 4,
; 32 dots in) and the status in the right margin; two white sprite frames
; are on top. MSX row 23 shows the status as patterns:
;
;   port 30h, port 148h, raster offset, write (0 BIOS, 1 direct),
;   read-back (1: as vaeg, 2: left half then right half, 0: neither),
;   rasters a line - 1 (DSPDEF: 07h on a 200-raster screen, 0Fh on 400)
;
; Keys: 1 port 30h 80CM, 2 port 148h ANKM, 3 BIOS/direct write, 4 raster
; offset half a line/0, 5 8/16 rasters a line, ESC or Q: the gaiji RAM
; back, exit.
;
; The gaiji RAM is saved to GAIJI.BAK first (only when there is none: a
; reset during the test keeps the saved copy for the next run) and is put
; back from it at ESC; PCGTEST.LOG gets the BIOS's text table (128 bytes),
; the read-back of character 7621h (32 bytes) and the status (8 bytes).

		cpu	186
		org	0

PICTURE_Y	equ	4		; as src/msx/msx.asm
GFX_X		equ	16
STRIDE		equ	160

FRAME		equ	6000h		; TVRAM: our text frame buffer
FRAME_VW	equ	160		; bytes a row (80 columns)
FRAME_ROWS	equ	27
TABLE		equ	7f00h		; TVRAM: the text screen control tables
SPR_IMG		equ	1000h		; TVRAM: the sprite image
SPR_TABLE	equ	7e00h		; TVRAM: the sprite descriptors
GAIJI		equ	0800h		; B0000h + : the gaiji area
GAIJI_BYTES	equ	17c0h		; B0800h-B1FBFh

start:		cli
		mov	ax,cs
		mov	ds,ax
		mov	es,ax
		mov	ss,ax
		mov	sp,0fffeh
		cld
		sti
		mov	dx,0153h
		in	al,dx
		mov	[old_153],al
		call	backup
		jc	exit_msg
		call	graphics_init
		jc	exit_msg
		call	tvram_on
		mov	si,TABLE		; the BIOS's text table
		mov	di,old_table
		push	ds
		mov	ax,0a000h
		mov	ds,ax
		mov	cx,64
		rep	movsw
		pop	ds
		call	tvram_off
		call	detect
		call	make_glyphs
		call	write_bios
		call	read_back
		call	write_log
		mov	al,00h			; 40 columns
		mov	[st_30],al
		out	30h,al
		mov	al,03h			; ANKM = 0, V3, word mode
		mov	[st_148],al
		mov	dx,0148h
		out	dx,al
		mov	ah,0ch			; the keyboard buffer empty
		int	82h
		call	dspdef			; st_height + 1 rasters a line
		call	text_setup
		call	sprites
.loop:		call	show_status
		call	wait_key
		cmp	al,1bh			; ESC or Q: done
		je	.done
		cmp	al,'Q'
		je	.done
		cmp	al,'q'
		je	.done
		cmp	al,'1'
		jne	.k2
		xor	byte [st_30],01h
		mov	al,[st_30]
		out	30h,al
		jmp	.loop
.k2:		cmp	al,'2'
		jne	.k3
		xor	byte [st_148],04h
		mov	al,[st_148]
		mov	dx,0148h
		out	dx,al
		jmp	.loop
.k3:		cmp	al,'3'
		jne	.k4
		xor	byte [st_method],1
		jz	.bios
		call	write_direct
		jmp	.loop
.bios:		call	write_bios
		jmp	.loop
.k4:		cmp	al,'4'
		jne	.k5
		mov	al,[st_height]		; 0 or half a line
		inc	al
		shr	al,1
		xor	[st_offset],al
		call	text_setup
		jmp	.loop
.k5:		cmp	al,'5'
		jne	.loop
		xor	byte [st_height],08h	; 8 or 16 rasters a line
		call	set_height
		call	dspdef
		call	make_glyphs
		cmp	byte [st_method],0
		jne	.direct
		call	write_bios
		jmp	.k5_text
.direct:	call	write_direct
.k5_text:	call	text_setup
		jmp	.loop
.done:		call	restore
		pushf
		call	tvram_on		; the BIOS's text table again
		push	es
		mov	ax,0a000h
		mov	es,ax
		mov	si,old_table
		mov	di,TABLE
		mov	cx,64
		rep	movsw
		pop	es
		call	tvram_off
		mov	al,01h			; 80 columns, ANKM = 1
		out	30h,al
		mov	al,07h
		mov	dx,0148h
		out	dx,al
		mov	ax,0b00h		; graphics display off
		int	8fh
		call	text_init
		popf
		mov	si,s_restored
		jnc	.msg
		mov	si,s_not_restored
.msg:		call	puts
		mov	ax,4c00h
		int	21h

exit_msg:	call	text_init		; SI: the message
		call	puts
		mov	ax,4c01h
		int	21h

; ---------------------------------------------------------------------------
; The gaiji RAM: GAIJI.BAK

; Save the gaiji area unless GAIJI.BAK exists. CF and SI: an error.
backup:		mov	dx,f_backup
		mov	ax,3d00h
		int	21h
		jc	.save
		mov	bx,ax			; kept from an earlier run
		mov	ah,3eh
		int	21h
		clc
		ret
.save:		call	gaiji_on
		push	ds
		mov	ax,0b000h
		mov	ds,ax
		mov	si,GAIJI
		mov	di,buffer
		mov	cx,GAIJI_BYTES
		rep	movsb			; byte access only (manual 3.4)
		pop	ds
		call	gaiji_off
		mov	dx,f_backup
		xor	cx,cx
		mov	ah,3ch
		int	21h
		jc	.fail
		mov	bx,ax
		mov	dx,buffer
		mov	cx,GAIJI_BYTES
		mov	ah,40h
		int	21h
		jc	.fail_close
		cmp	ax,GAIJI_BYTES
		jne	.fail_close
		mov	ah,3eh
		int	21h
		jc	.fail
		clc
		ret
.fail_close:	mov	ah,3eh
		int	21h
		mov	dx,f_backup		; no half-written backup
		mov	ah,41h
		int	21h
.fail:		mov	si,s_no_backup
		stc
		ret

; The gaiji area from GAIJI.BAK, which is then deleted. CF: not done.
restore:	mov	dx,f_backup
		mov	ax,3d00h
		int	21h
		jc	.ret
		mov	bx,ax
		mov	dx,buffer
		mov	cx,GAIJI_BYTES
		mov	ah,3fh
		int	21h
		pushf
		push	ax
		mov	ah,3eh
		int	21h
		pop	ax
		popf
		jc	.ret
		cmp	ax,GAIJI_BYTES
		jne	.short
		call	gaiji_on
		push	es
		mov	ax,0b000h
		mov	es,ax
		mov	si,buffer
		mov	di,GAIJI
		mov	cx,GAIJI_BYTES
		rep	movsb
		pop	es
		call	gaiji_off
		mov	dx,f_backup
		mov	ah,41h
		int	21h
		clc
		ret
.short:		stc
.ret:		ret

; PCGTEST.LOG: the BIOS's table, the read-back, the status.
write_log:	mov	dx,f_log
		xor	cx,cx
		mov	ah,3ch
		int	21h
		jc	.ret
		mov	bx,ax
		mov	dx,old_table
		mov	cx,128 + 32 + 8
		mov	ah,40h
		int	21h
		mov	ah,3eh
		int	21h
.ret:		ret

; ---------------------------------------------------------------------------
; System memory window (port 153h SMBC, A0000h-BFFFFh): TVRAM (1), GVRAM
; (4), kanji ROM #2 with the backup RAM at B0000h (9), and back.

tvram_on:	mov	al,01h
		jmp	window
gaiji_on:	mov	al,09h
		jmp	window
gvram_on:	mov	al,04h
window:		push	dx
		mov	ah,al
		mov	dx,0153h
		mov	al,[old_153]
		and	al,0f0h
		or	al,ah
		out	dx,al
		pop	dx
		ret
tvram_off:
gaiji_off:
gvram_off:	push	dx
		push	ax
		mov	dx,0153h
		mov	al,[old_153]
		out	dx,al
		pop	ax
		pop	dx
		ret

;
; 200 or 400 rasters (a 15 or 24 kHz monitor), from the heights of the
; BIOS's split screens: 400 when they add up to more than 300. The TSP
; then counts two rasters a graphics line, so an MSX cell is 16 rasters
; with each pattern row twice.
detect:		xor	ax,ax
		mov	si,old_table + 14h
		mov	cx,4
.h:		mov	bx,[si]
		and	bx,1feh
		add	ax,bx
		add	si,20h
		loop	.h
		mov	byte [st_height],07h
		cmp	ax,300
		jbe	set_height
		mov	byte [st_height],0fh
; From st_height: the raster offset that puts MSX line 0 on graphics line
; 4 (half a line).
set_height:	mov	al,[st_height]
		inc	al
		shr	al,1
		mov	[st_offset],al
		ret

; ---------------------------------------------------------------------------
; The glyphs: 128 characters of 32 bytes, row r at 2r (left half) and
; 2r + 1 (right half), pattern p in the half p & 1 of character p / 2.
; 8 rasters a line: the pattern's rows 0-7, then a checker that should not
; show; 16 rasters: each pattern row twice.

make_glyphs:	xor	bx,bx			; BX: the pattern
.p:		mov	di,bx
		shr	di,1
		shl	di,5
		add	di,glyphs
		mov	ax,bx
		and	ax,1
		add	di,ax			; DI: row 0 of the pattern's half
		mov	byte [di],80h		; row 0: a dot at the top left
		mov	dl,bl			; rows 1-5: the number in hex
		shr	dl,4
		mov	dh,bl
		and	dh,0fh
		mov	si,0			; SI: the digit row
.row:		mov	al,dl
		call	digit_row
		shl	al,5
		mov	ch,al
		mov	al,dh
		call	digit_row
		shl	al,1
		or	al,ch
		push	di
		add	di,si
		mov	[di + 2],al
		pop	di
		add	si,2
		cmp	si,10
		jb	.row
		mov	byte [di + 12],0	; row 6, and the marker of the direct
		mov	byte [di + 14],0	; write; row 7
		cmp	byte [st_height],07h
		jne	.double
		mov	cx,8			; rows 8-15: a checker
		lea	si,[di + 16]
.chk:		mov	byte [si],0aah
		add	si,2
		loop	.chk
		jmp	.next
.double:	push	bx			; row r to rows 2r, 2r + 1, from the
		mov	bx,14			; bottom up
.dbl:		mov	al,[di + bx]
		push	bx
		shl	bx,1
		mov	[di + bx],al
		mov	[di + bx + 2],al
		pop	bx
		sub	bx,2
		jnc	.dbl
		pop	bx
.next:		inc	bx
		cmp	bx,256
		jb	.p
		ret

; AL: a hex digit, SI / 2: its row 0-4 -> AL: the row's 3 dots (bits 2-0).
digit_row:	push	bx
		xor	ah,ah
		mov	bx,ax
		shl	bx,2
		add	bx,ax			; 5 rows a digit
		push	si
		shr	si,1
		mov	al,[hexfont + bx + si]
		pop	si
		pop	bx
		ret

; Character n (0-127) -> CX: its JIS code.
jis_of:		mov	cx,7621h
		cmp	ax,94
		jb	.l
		mov	cx,7721h - 94
.l:		add	cx,ax
		ret

; By the text BIOS (INT 83h AH = 21h, AL = 0: a full-width character, DX:
; its shift-JIS code, ES:BP: 32 bytes), as SETGAIJI does.
write_bios:	xor	ax,ax
.c:		push	ax
		call	jis_of
		call	sjis_of
		mov	bp,ax
		shl	bp,5
		add	bp,glyphs
		pusha
		push	ds
		push	es
		push	cs
		pop	es
		mov	ax,2100h
		int	83h
		pop	es
		pop	ds
		popa
		pop	ax
		inc	ax
		cmp	ax,128
		jb	.c
		mov	byte [st_method],0
		ret

; JIS CX -> DX: shift-JIS.
sjis_of:	push	ax
		mov	al,ch			; first byte
		inc	al
		shr	al,1
		add	al,0b0h			; 76h, 77h: EBh, ECh
		mov	dh,al
		mov	al,cl
		test	ch,1
		jz	.even
		add	al,1fh			; second byte below 60h
		cmp	cl,60h
		jb	.s
		inc	al
		jmp	.s
.even:		add	al,7eh
.s:		mov	dl,al
		pop	ax
		ret

; The byte of JIS CX's row 0, left half, in the backup RAM -> DI (vaeg's
; layout, io/cgromva.c).
gaiji_addr:	push	ax
		mov	al,cl			; second byte
		and	ax,60h
		shl	ax,6
		mov	di,ax
		mov	al,ch
		and	ax,1
		shl	ax,10
		add	di,ax
		mov	al,cl
		and	ax,1fh
		shl	ax,5
		add	di,ax
		pop	ax
		ret

; Directly into the backup RAM (byte writes), each pattern with the dot of
; row 6.
write_direct:	call	gaiji_on
		push	es
		mov	ax,0b000h
		mov	es,ax
		xor	ax,ax
.c:		push	ax
		call	jis_of
		call	gaiji_addr
		mov	si,ax
		shl	si,5
		add	si,glyphs
		mov	cx,32
		xor	bx,bx
.b:		mov	al,[si + bx]
		mov	dl,bl			; DL: the pattern row of the byte
		shr	dl,1
		cmp	byte [st_height],07h
		je	.row
		shr	dl,1
.row:		cmp	dl,6			; row 6, both halves
		jne	.put
		mov	al,01h
.put:		mov	[es:di + bx],al
		inc	bx
		loop	.b
		pop	ax
		inc	ax
		cmp	ax,128
		jb	.c
		pop	es
		call	gaiji_off
		ret

; Character 7621h as read from the backup RAM, against the glyph written:
; 1 in vaeg's layout, 2 with the left half's 16 rows first, 0 neither.
read_back:	call	gaiji_on
		push	ds
		mov	cx,7621h
		call	gaiji_addr
		mov	si,di
		mov	ax,0b000h
		mov	ds,ax
		mov	di,readback
		push	es
		push	cs
		pop	es
		mov	cx,32
		rep	movsb
		pop	es
		pop	ds
		call	gaiji_off
		mov	si,readback		; vaeg's layout: as written
		mov	di,glyphs
		mov	cx,32
		push	es
		push	cs
		pop	es
		repe	cmpsb
		pop	es
		mov	al,1
		je	.set
		xor	bx,bx			; left rows, then right rows
.split:		mov	al,[glyphs + bx]
		mov	si,bx
		shr	si,1
		test	bl,1
		jz	.l
		add	si,16
.l:		cmp	al,[readback + si]
		jne	.none
		inc	bx
		cmp	bx,32
		jb	.split
		mov	al,2
		jmp	.set
.none:		mov	al,0
.set:		mov	[st_readback],al
		ret

; ---------------------------------------------------------------------------
; The text screen: split screen 0 on our frame buffer, the others as the
; BIOS left them.

text_setup:	call	tvram_on
		push	es
		mov	ax,0a000h
		mov	es,ax
		mov	di,FRAME		; every column: ANK space,
		mov	cx,FRAME_ROWS * FRAME_VW / 2	; colour 15 on 0
		mov	ax,0020h
		rep	stosw
		mov	di,FRAME + 8000h
		mov	cx,FRAME_ROWS * FRAME_VW / 2
		mov	ax,000fh
		rep	stosw
		xor	dx,dx			; DL: MSX row, DH: column
.cell:		mov	al,dl			; pattern (row * 32 + column) & 255
		mov	ah,32
		mul	ah
		add	al,dh
		mov	bl,al			; BL: the pattern
		call	cell_at			; DI: the cell's first column
		call	code_of			; AX: its code
		mov	[es:di],ax
		mov	[es:di + 2],ax
		mov	al,bl			; colours by 8 patterns
		shr	al,3
		xor	ah,ah
		mov	cl,14
		div	cl
		add	ah,2			; FG 2-15
		mov	al,ah
		cmp	dl,12
		jb	.attr			; rows 0-11: BG transparent
		mov	cl,ah			; rows 12-22: an opaque BG
		add	cl,7
		cmp	cl,15
		jbe	.bg
		sub	cl,14
.bg:		shl	cl,4
		or	al,cl
.attr:		xor	ah,ah
		mov	[es:di + 8000h],ax
		mov	[es:di + 8002h],ax
		inc	dh
		cmp	dh,32
		jb	.cell
		mov	dh,0
		inc	dl
		cmp	dl,23
		jb	.cell
		mov	di,TABLE		; split screen 0
		mov	word [es:di + 00h],FRAME	; VSA
		mov	word [es:di + 02h],0
		mov	word [es:di + 04h],FRAME_ROWS	; VH
		mov	word [es:di + 08h],FRAME_VW	; VW
		mov	word [es:di + 0ah],0000h	; mode 0
		mov	al,[st_offset]
		xor	ah,ah
		xchg	al,ah
		mov	[es:di + 0ch],ax	; raster offset (bits 8-12)
		mov	ax,FRAME		; RSA: row 0 shows above MSX line 0
		mov	[es:di + 10h],ax	; (with offset 4: lines 0-3)
		mov	al,[st_height]		; RH: 25 lines
		inc	al
		mov	ah,25
		mul	ah
		mov	[es:di + 14h],ax
		pop	es
		call	tvram_off
		ret

; MSX row DL, column DH -> DI: TVRAM offset of the cell's first column
; (frame row DL + 1, column 8 + 2 * DH). Keeps every register but DI.
cell_at:	push	ax
		mov	al,dl
		inc	al
		mov	ah,FRAME_VW
		mul	ah
		mov	di,ax
		mov	al,dh
		xor	ah,ah
		shl	ax,2			; 2 columns, 2 bytes each
		add	di,ax
		add	di,FRAME + 16
		pop	ax
		ret

; Pattern BL -> AX: the hardware code of its half character.
code_of:	push	cx
		mov	al,bl
		xor	ah,ah
		shr	ax,1
		call	jis_of			; CX: JIS
		mov	al,ch
		sub	al,20h			; bits 6-0: first byte - 20h
		mov	ah,cl			; bits 14-8: second byte
		test	bl,1
		jz	.l
		or	ah,80h			; bit 15: the right half
.l:		pop	cx
		ret

; The status, as patterns in MSX row 23 and in hex in GVRAM's right margin.
show_status:	call	tvram_on
		push	es
		mov	ax,0a000h
		mov	es,ax
		mov	si,st_30
		mov	dx,0017h		; row 23, column 0
.s:		lodsb
		mov	bl,al
		call	cell_at
		call	code_of
		mov	[es:di],ax
		mov	[es:di + 2],ax
		mov	word [es:di + 8000h],001fh	; white on black
		mov	word [es:di + 8002h],001fh
		add	dh,2
		cmp	si,st_end
		jb	.s
		pop	es
		call	tvram_off
		call	gvram_on
		push	es
		mov	es,[gvram_seg]
		mov	si,st_30
		mov	di,8 * STRIDE + 146	; x 292, from line 8
.g:		lodsb
		push	di
		push	ax
		shr	al,4
		call	big_digit
		pop	ax
		and	al,0fh
		add	di,4
		call	big_digit
		pop	di
		add	di,16 * STRIDE
		cmp	si,st_end
		jb	.g
		pop	es
		call	gvram_off
		ret

; Hex digit AL at ES:DI (GVRAM, 4 bits a dot), 3x5 dots twice as large,
; white on black.
big_digit:	push	si
		push	di
		xor	ah,ah
		mov	si,ax
		shl	si,2
		add	si,ax
		add	si,hexfont
		mov	cx,5
.r:		lodsb
		xor	bx,bx			; 3 dots -> 6 dots = 3 bytes
		mov	ah,al
		test	ah,4
		jz	.d1
		or	bl,0ffh
.d1:		test	ah,2
		jz	.d2
		or	bh,0ffh
.d2:		mov	dl,0
		test	ah,1
		jz	.d3
		mov	dl,0ffh
.d3:		mov	[es:di],bl
		mov	[es:di + 1],bh
		mov	[es:di + 2],dl
		mov	[es:di + STRIDE],bl
		mov	[es:di + STRIDE + 1],bh
		mov	[es:di + STRIDE + 2],dl
		add	di,2 * STRIDE
		loop	.r
		pop	di
		pop	si
		ret

; DSPDEF: attributes at +8000h, codes every 2 bytes, st_height + 1
; rasters a line, the line on the last raster, blink speed 18h.
dspdef:		mov	al,14h
		call	tsp_cmd
		mov	al,00h
		call	tsp_par
		mov	al,80h
		call	tsp_par
		mov	al,20h
		call	tsp_par
		mov	al,[st_height]
		call	tsp_par
		call	tsp_par
		mov	al,18h
		call	tsp_par
		ret

tsp_cmd:	push	dx
		push	ax
		mov	dx,0142h
.w:		in	al,dx
		test	al,05h			; IBF, BUSY
		jnz	.w
		pop	ax
		out	dx,al
		pop	dx
		ret
tsp_par:	push	dx
		push	ax
		mov	dx,0142h
.w:		in	al,dx
		test	al,01h			; IBF
		jnz	.w
		pop	ax
		mov	dx,0146h
		out	dx,al
		pop	dx
		ret

; Two 16x16 sprite frames in white (the descriptor format of
; src/msx/msx.asm sprite_table): MSX (60, 50), over the transparent
; background, and (180, 130), over the opaque one.
sprites:	call	tvram_on
		push	es
		mov	ax,0a000h
		mov	es,ax
		mov	di,SPR_IMG		; 16 rows of 32 dots
		mov	cx,16
.img:		mov	ax,0c0h
		mov	bx,0300h
		cmp	cx,16
		je	.full
		cmp	cx,1
		jne	.row
.full:		mov	ax,0ffffh
		mov	bx,ax
.row:		stosw
		mov	ax,bx
		stosw
		loop	.img
		mov	di,SPR_TABLE
		mov	ax,60
		mov	bx,50
		call	.desc
		mov	ax,180
		mov	bx,130
		call	.desc
		mov	cx,30 * 4		; the others off
		xor	ax,ax
		rep	stosw
		pop	es
		call	tvram_off
		ret
.desc:		push	ax			; AX: x, BX: y
		mov	ax,bx
		add	ax,PICTURE_Y + 1
		and	ax,1ffh
		or	ah,(3 << 2) | 02h	; 16 lines, SW
		stosw
		pop	ax
		add	ax,GFX_X * 2
		shl	ax,1
		and	ax,3ffh
		or	ah,04h			; 32 dots, monochrome
		stosw
		mov	ax,SPR_IMG / 2
		stosw
		mov	ax,0f0h			; white
		stosw
		ret

; ---------------------------------------------------------------------------
; Graphics: 320x200, 4 bits a dot (as src/msx/msx.asm screen_init), 8x8
; squares at the MSX cells, the MSX palette in both sets.

graphics_init:	mov	ax,1702h		; clear the text screen
		int	83h
		mov	ax,2500h		; text cursor off
		int	83h
		mov	ah,00h
		mov	bh,0a0h
		mov	bl,0ah
		mov	cx,0404h
		xor	dx,dx
		int	8fh
		or	ax,ax
		jnz	.fail
		mov	di,fb_desc
		mov	ax,0100h
		mov	cx,1
		int	8fh
		or	ax,ax
		jnz	.fail
		mov	di,fb_desc
		mov	ax,0700h
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
		add	dx,000ah
.cpu:		mov	bx,ax
		shr	bx,4
		shl	dx,12
		or	bx,dx
		mov	[gvram_seg],bx
		call	gvram_on
		mov	dx,0580h		; single-plane write mode: CPU data
		mov	al,10h
		out	dx,al
		push	es
		mov	es,bx
		xor	di,di
		xor	ax,ax
		mov	cx,200 * STRIDE / 2
		rep	stosw
		xor	bp,bp			; BP: MSX row, SI: column
.sqr:		xor	si,si
.sq:		mov	ax,bp
		mov	bx,8 * STRIDE
		mul	bx
		mov	di,ax
		add	di,PICTURE_Y * STRIDE + GFX_X
		mov	ax,si
		shl	ax,2
		add	di,ax
		mov	ax,bp
		add	ax,si
		test	al,1
		mov	ax,4444h		; dark blue
		jz	.c
		mov	ax,0cccch		; dark green
.c:		mov	cx,8
.l:		mov	[es:di],ax
		mov	[es:di + 2],ax
		add	di,STRIDE
		loop	.l
		inc	si
		cmp	si,32
		jb	.sq
		inc	bp
		cmp	bp,24
		jb	.sqr
		pop	es
		call	gvram_off
		mov	dx,0300h		; both palette sets
.set:		mov	si,palette
		mov	cx,16
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
.fail:		mov	si,s_no_graphics
		stc
		ret

; ---------------------------------------------------------------------------
; Text BIOS and keyboard (as src/m01/m01test.asm)

text_init:	pusha
		mov	ah,2ah
		int	83h
		mov	ax,1702h
		int	83h
		xor	dx,dx
		mov	ah,08h
		int	83h
		popa
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

wait_key:	mov	ah,09h			; (AH = 0Ch would drop the keys
		int	82h			; typed meanwhile)
		ret

; ---------------------------------------------------------------------------

%macro VACOLOUR 3			; R G B, 0-255 (as src/msx/msx.asm)
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

palette:	VACOLOUR	0, 0, 0
		VACOLOUR	0, 0, 0
		VACOLOUR	33, 200, 66
		VACOLOUR	94, 220, 120
		VACOLOUR	84, 85, 237
		VACOLOUR	125, 118, 252
		VACOLOUR	212, 82, 77
		VACOLOUR	66, 235, 245
		VACOLOUR	252, 85, 84
		VACOLOUR	255, 121, 120
		VACOLOUR	212, 193, 84
		VACOLOUR	230, 206, 128
		VACOLOUR	33, 176, 59
		VACOLOUR	201, 91, 186
		VACOLOUR	204, 204, 204
		VACOLOUR	255, 255, 255

hexfont:	db	7, 5, 5, 5, 7		; 0
		db	2, 6, 2, 2, 7		; 1
		db	7, 1, 7, 4, 7		; 2
		db	7, 1, 3, 1, 7		; 3
		db	5, 5, 7, 1, 1		; 4
		db	7, 4, 7, 1, 7		; 5
		db	7, 4, 7, 5, 7		; 6
		db	7, 1, 1, 2, 2		; 7
		db	7, 5, 7, 5, 7		; 8
		db	7, 5, 7, 1, 7		; 9
		db	2, 5, 7, 5, 5		; A
		db	6, 5, 6, 5, 6		; B
		db	3, 4, 4, 4, 3		; C
		db	6, 5, 5, 5, 6		; D
		db	7, 4, 6, 4, 7		; E
		db	7, 4, 6, 4, 4		; F

f_backup	db	'GAIJI.BAK', 0
f_log		db	'PCGTEST.LOG', 0
s_no_backup	db	'PCGTEST: GAIJI.BAK cannot be written; nothing changed.', 13, 10, 0
s_no_graphics	db	'PCGTEST: the graphics screen cannot be set.', 13, 10, 0
s_restored	db	'PCGTEST: the gaiji RAM is restored. Reset the machine.', 13, 10, 0
s_not_restored	db	'PCGTEST: GAIJI.BAK cannot be read; the gaiji RAM is not'
		db	' restored. Run PCGTEST again and press ESC.', 13, 10, 0

		align	2
fb_desc		dw	4, 320, 200, 0, 0, 0
gvram_seg	dw	0
old_153		db	0
		align	2
old_table	times	128 db 0	; PCGTEST.LOG: these three in order
readback	times	32 db 0
st_30		db	0		; the status, shown in this order
st_148		db	0
st_offset	db	0
st_method	db	0
st_readback	db	0
st_height	db	07h		; rasters a line - 1
st_end:
		times	2 db 0		; (8 bytes in the log)
glyphs		times	128 * 32 db 0
buffer		times	GAIJI_BYTES db 0
end_of_program:
