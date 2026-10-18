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
; The MS-DOS 4.0 loader for the msx88va programs (docs/DESIGN.md).
;
; With MSX defined, MSX.COM:
;
;   MSX [cartridge]
;
; reads C-BIOS 0.29a (CBIOS_M1.ROM, CBIOS_L1.ROM) from the current
; directory, checks and patches it as tools/cbios.py lists (msxdata.inc),
; reads the cartridge (8, 16 or 32 KiB, from page 1) named on the command
; line, or else the one *.ROM file of the current directory other than
; C-BIOS (a menu when there are several, none: no cartridge), then copies
; the MSX program (src/msx/msx.asm, assembled for BASE) to BASE:0000 and
; starts it. It does not return: the program takes the machine over.
;
; Without MSX it only copies its payload to BASE:0000 and starts it (the
; probe disks).
;
; msxdata.inc (tools/build_dos.py) defines BASE, PAYLOAD_BIN, MEMORY_TOP
; without MSX, and HEADER (the payload's header offset) with MSX;
; msxpatch.inc is the C-BIOS patch table.

		cpu	186
		org	100h

%include "msxdata.inc"

%ifdef MSX
MAIN_SEG	equ	BASE + 0400h	; as in src/msx/msx.asm
LOGO_SEG	equ	BASE + 0c00h
CART_SEG	equ	BASE + 1000h
MAX_CARTS	equ	9
%endif

start:		mov	sp,stack_top
		cld
		mov	dx,s_banner
		call	print
		mov	ax,end_of_com		; the loader must end below BASE
		add	ax,15
		shr	ax,4
		mov	bx,cs
		add	ax,bx
		cmp	ax,BASE
		ja	.low
%ifdef MSX
		mov	ax,[payload + HEADER + 8]	; and DOS leave memory to
%else							; the program's top
		mov	ax,MEMORY_TOP
%endif
		cmp	[0002h],ax
		jae	.memory
.low:		mov	dx,s_memory
		jmp	fail
.memory:
%ifdef MSX
		call	load_cbios
		call	choose_cart
		call	load_cart
%endif
		mov	dx,s_start
		call	print
		cli
		mov	ax,BASE			; the payload to BASE:0000
		mov	es,ax
		mov	si,payload
		xor	di,di
		mov	cx,PAYLOAD_BYTES / 2
		rep	movsw
		push	BASE
		push	0
		retf

fail:		call	print
		mov	ax,4c01h
		int	21h

; DS:DX: a $-terminated string.
print:		mov	ah,09h
		int	21h
		ret

%ifdef MSX
; ---------------------------------------------------------------------------
; C-BIOS: both files, their sizes, the bytes the patches replace.

load_cbios:	mov	dx,f_main
		mov	bx,MAIN_SEG
		mov	cx,8000h
		call	read_file
		jc	.missing
		cmp	ax,8000h
		jne	.bad
		mov	dx,f_logo
		mov	bx,LOGO_SEG
		mov	cx,4000h
		call	read_file
		jc	.missing
		cmp	ax,4000h
		jne	.bad
		mov	si,patches		; check, then apply, each patch:
						; offset (word), length, old bytes,
						; new bytes
		mov	bx,MAIN_SEG
		mov	es,bx
.check:		lodsw
		cmp	ax,0ffffh
		je	.apply
		mov	di,ax
		lodsb
		xor	ch,ch
		mov	cl,al
		repe	cmpsb
		jne	.bad
		add	si,cx			; the rest of the old bytes (none)
		mov	cl,al
		add	si,cx			; the new bytes
		jmp	.check
.apply:		mov	si,patches
.ap:		lodsw
		cmp	ax,0ffffh
		je	.done
		mov	di,ax
		lodsb
		xor	ch,ch
		mov	cl,al
		add	si,cx			; skip the old bytes
		rep	movsb
		jmp	.ap
.done:		push	cs
		pop	es
		ret
.missing:	mov	dx,s_no_cbios
		jmp	fail
.bad:		mov	dx,s_bad_cbios
		jmp	fail

; ---------------------------------------------------------------------------
; The cartridge's file name to cart_name (empty: none).

choose_cart:	mov	si,81h			; the command line
.skip:		lodsb
		cmp	al,' '
		je	.skip
		cmp	al,9
		je	.skip
		cmp	al,13
		je	.search
		mov	di,cart_name		; the first word
.copy:		stosb
		lodsb
		cmp	al,' '
		je	.end
		cmp	al,9
		je	.end
		cmp	al,13
		jne	.copy
.end:		mov	byte [di],0
		ret
.search:	mov	dx,dta			; the *.ROM files but C-BIOS
		mov	ah,1ah
		int	21h
		mov	byte [carts],0
		mov	di,cart_list
		mov	dx,f_pattern
		xor	cx,cx
		mov	ah,4eh
.find:		int	21h
		jc	.found
		cmp	word [dta + 1eh],'CB'	; CBIOS*: not a cartridge
		jne	.take
		cmp	word [dta + 20h],'IO'
		je	.next
.take:		cmp	byte [carts],MAX_CARTS
		jae	.next
		mov	si,dta + 1eh
		mov	cx,13
		rep	movsb
		inc	byte [carts]
.next:		mov	ah,4fh
		jmp	.find
.found:		mov	al,[carts]
		or	al,al
		jnz	.some
		mov	byte [cart_name],0	; none: C-BIOS alone
		ret
.some:		mov	si,cart_list
		cmp	al,1
		je	.take_si
		mov	dx,s_menu		; a menu
		call	print
		mov	bl,'1'
		mov	si,cart_list
		xor	ch,ch
		mov	cl,[carts]
.item:		mov	dl,bl
		mov	ah,02h
		int	21h
		mov	dl,' '
		int	21h
		push	si
.name:		lodsb
		or	al,al
		jz	.nl
		mov	dl,al
		mov	ah,02h
		int	21h
		jmp	.name
.nl:		pop	si
		add	si,13
		mov	dx,s_crlf
		call	print
		inc	bl
		loop	.item
		mov	dx,s_choose
		call	print
.key:		mov	ah,08h
		int	21h
		cmp	al,'0'
		je	.none
		sub	al,'1'
		jb	.key
		cmp	al,[carts]
		jae	.key
		mov	ah,13
		mul	ah
		mov	si,cart_list
		add	si,ax
.take_si:	mov	di,cart_name
		mov	cx,13
		rep	movsb
		ret
.none:		mov	byte [cart_name],0
		ret

; ---------------------------------------------------------------------------
; The cartridge into CART_SEG; cart_pages in the payload's header.

load_cart:	cmp	byte [cart_name],0
		je	.ret
		mov	dx,s_cart
		call	print
		mov	si,cart_name
.show:		lodsb
		or	al,al
		jz	.shown
		mov	dl,al
		mov	ah,02h
		int	21h
		jmp	.show
.shown:		mov	dx,s_crlf
		call	print
		mov	dx,cart_name
		mov	bx,CART_SEG
		mov	cx,8001h		; one more than accepted
		call	read_file
		jc	.missing
		cmp	ax,2000h		; 8 KiB: mirrored in the page
		jne	.k16
		push	ds
		mov	bx,CART_SEG
		mov	ds,bx
		mov	es,bx
		xor	si,si
		mov	di,2000h
		mov	cx,1000h
		rep	movsw
		pop	ds
		push	cs
		pop	es
		mov	al,1
		jmp	.pages
.k16:		cmp	ax,4000h
		jne	.k32
		mov	al,1
		jmp	.pages
.k32:		cmp	ax,8000h
		jne	.size
		mov	al,2
.pages:		mov	[payload + HEADER + 10],al
.ret:		ret
.missing:	mov	dx,s_no_cart
		jmp	fail
.size:		mov	dx,s_cart_size
		jmp	fail

; The file DS:DX (ASCIIZ) to BX:0000, at most CX bytes. AX = bytes read;
; CF = 1 if it cannot be opened or read.
read_file:	push	cx
		mov	ax,3d00h
		int	21h
		pop	cx
		jc	.ret
		push	ds
		mov	ds,bx
		mov	bx,ax
		xor	dx,dx
		mov	ah,3fh
		int	21h
		pop	ds
		pushf
		push	ax
		mov	ah,3eh
		int	21h
		pop	ax
		popf
.ret:		ret
%endif

; ---------------------------------------------------------------------------

s_banner	db	'msx88va', 13, 10, '$'
s_memory	db	'Not enough memory below 640 KiB.', 13, 10, '$'
s_start		db	'Starting. HELP resets the MSX; switch off to leave.', 13, 10, '$'
s_crlf		db	13, 10, '$'
%ifdef MSX
s_no_cbios	db	'CBIOS_M1.ROM and CBIOS_L1.ROM (C-BIOS 0.29a) are needed in the'
		db	' current directory.', 13, 10, '$'
s_bad_cbios	db	'CBIOS_M1.ROM or CBIOS_L1.ROM is not C-BIOS 0.29a for the MSX1.'
		db	13, 10, '$'
s_menu		db	'Cartridges:', 13, 10, '0 none', 13, 10, '$'
s_choose	db	'Number? $'
s_cart		db	13, 10, 'Cartridge: $'
s_no_cart	db	'The cartridge file cannot be read.', 13, 10, '$'
s_cart_size	db	'The cartridge must be 8, 16 or 32 KiB (no mapper).', 13, 10, '$'
f_main		db	'CBIOS_M1.ROM', 0
f_logo		db	'CBIOS_L1.ROM', 0
f_pattern	db	'*.ROM', 0
carts		db	0
cart_name	times	80 db 0
dta		times	43 db 0
cart_list	times	MAX_CARTS * 13 db 0
%include "msxpatch.inc"
%endif

		align	2
		times	256 db 0
stack_top:
		align	16
payload:	incbin	PAYLOAD_BIN
PAYLOAD_BYTES	equ	($ - payload + 1) & ~1
end_of_com:
