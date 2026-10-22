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
;   MSX [/N] [cartridge]
;   MSX /R
;
; (. or ESC in the menu returns to DOS.)
;
; reads MSXBIOS.ROM (an MSX1 main ROM of the user's, run unpatched) or
; else C-BIOS 0.29a (CBIOS_M1.ROM, CBIOS_L1.ROM) from the current
; directory, checks and patches C-BIOS as tools/cbios.py lists,
; reads the cartridge (8, 16 or 32 KiB, from page 1) named on the command
; line, or else the one *.ROM file of the current directory other than
; C-BIOS (a menu when there are several, none: no cartridge), saves the
; gaiji RAM to GAIJI.BAK (unless /N, or GAIJI.BAK exists: an earlier copy
; is kept; the MSX program then shows Graphics I with user-defined
; characters), then copies the MSX program (src/msx/msx.asm, assembled
; for BASE) to BASE:0000 and starts it. It does not return: the program
; takes the machine over. MSX /R puts the gaiji RAM back from GAIJI.BAK,
; deletes it, and returns to DOS.
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
MAIN_SEG	equ	BASE + 0600h	; as in src/msx/msx.asm
LOGO_SEG	equ	BASE + 0e00h
CART_SEG	equ	BASE + 1200h
MAX_CARTS	equ	35		; keys 1-9, A-Z
GAIJI		equ	0800h		; B0000h + : the gaiji area
GAIJI_BYTES	equ	17c0h		; B0800h-B1FBFh (src/pcg/pcgtest.asm)
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
		call	parse_args
		cmp	byte [opt_r],0
		je	.run
		call	gaiji_restore
		mov	ah,09h
		int	21h
		mov	ax,4c00h
		adc	al,0
		int	21h
.run:		call	load_cbios
		call	choose_cart
		call	gaiji_save
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
; MSXBIOS.ROM, an MSX1 main ROM of the user's (32 KiB, DI; JP at 0000h),
; when the current directory has one: run as it is, slot 0 page 2 empty.
; Otherwise C-BIOS: both files, their sizes, the bytes the patches
; replace.

load_cbios:	mov	dx,f_msxbios
		mov	bx,MAIN_SEG
		mov	cx,8000h
		call	read_file
		jc	.cbios			; none: C-BIOS
		cmp	ax,8000h
		jne	.bad_msx
		mov	ax,MAIN_SEG
		mov	es,ax
		cmp	word [es:0],0c3f3h
		jne	.bad_msx
		mov	ax,LOGO_SEG		; slot 0 page 2: empty (FFh)
		mov	es,ax
		xor	di,di
		mov	ax,0ffffh
		mov	cx,2000h
		rep	stosw
		mov	byte [payload + HEADER + 11],0	; ram_slot: RAM in slot 0
		mov	dx,s_msxbios
		call	print
		jmp	.done
.bad_msx:	mov	dx,s_bad_msxbios
		jmp	fail
.cbios:		mov	dx,f_main
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
; The command line: /R, /N, and the cartridge's file name to cart_name
; (empty: none).

parse_args:	mov	si,81h
.skip:		lodsb
		cmp	al,' '
		je	.skip
		cmp	al,9
		je	.skip
		cmp	al,13
		je	.ret
		cmp	al,'/'
		jne	.word
		lodsb
		cmp	al,13
		je	.ret
		and	al,0dfh
		cmp	al,'R'
		jne	.n
		mov	byte [opt_r],1
		jmp	.skip
.n:		cmp	al,'N'
		jne	.skip
		mov	byte [opt_n],1
		jmp	.skip
.word:		mov	di,cart_name		; the first word
.copy:		stosb
		lodsb
		cmp	al,' '
		je	.end
		cmp	al,9
		je	.end
		cmp	al,13
		jne	.copy
.end:		mov	byte [di],0
		dec	si
		jmp	.skip
.ret:		ret

; The cartridge named, or a choice of the *.ROM files.
choose_cart:	cmp	byte [cart_name],0
		je	.search
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
		cmp	word [dta + 1eh],'CB'	; CBIOS*, MSXBIOS*: not
		jne	.msxbios		; cartridges
		cmp	word [dta + 20h],'IO'
		je	.next
.msxbios:	cmp	word [dta + 1eh],'MS'
		jne	.take
		cmp	word [dta + 20h],'XB'
		jne	.take
		cmp	word [dta + 22h],'IO'
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
		mov	dx,s_menu		; a menu, four items a line,
		call	print			; keys 1-9 then A-Z
		xor	bx,bx			; BL: the item
		mov	si,cart_list
.item:		mov	al,bl
		call	item_key
		mov	dl,al
		mov	ah,02h
		int	21h
		mov	dl,' '
		int	21h
		mov	cx,18			; the column width after "k "
		push	si
.name:		lodsb
		or	al,al
		jz	.pad
		mov	dl,al
		mov	ah,02h
		int	21h
		dec	cx
		jmp	.name
.pad:		pop	si
		add	si,13
		inc	bl
		cmp	bl,[carts]
		je	.last
		test	bl,3
		jz	.row
.space:		mov	dl,' '
		mov	ah,02h
		int	21h
		loop	.space
		jmp	.item
.row:		mov	dx,s_crlf
		call	print
		jmp	.item
.last:		mov	dx,s_crlf
		call	print
		mov	dx,s_choose
		call	print
.key:		mov	ah,08h
		int	21h
		cmp	al,1bh			; ESC or '.': back to DOS (for
		je	.dos			; MSX /R)
		cmp	al,'.'
		jne	.digit
.dos:		mov	ax,4c00h
		int	21h
.digit:		cmp	al,'0'
		je	.none
		and	al,0dfh			; letters upper case, digits
		cmp	al,'A'			; 31h-39h -> 11h-19h
		jae	.letter
		sub	al,11h
		jb	.key
		cmp	al,9
		jae	.key
		jmp	.index
.letter:	sub	al,'A' - 9
		cmp	al,9
		jb	.key
.index:		cmp	al,[carts]
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

; AL: a menu item (0-34) -> AL: its key, 1-9 then A-Z.
item_key:	add	al,'1'
		cmp	al,'9'
		jbe	.ret
		add	al,'A' - '9' - 1
.ret:		ret

; ---------------------------------------------------------------------------
; The gaiji RAM (kanji ROM #2's backup RAM, port 153h SMBC 9, byte access
; only) and GAIJI.BAK, through CART_SEG (the cartridge comes later).

; Unless /N: GAIJI.BAK kept or written, then pcg_ok in the payload's header.
gaiji_save:	cmp	byte [opt_n],0
		jne	.ret
		mov	dx,f_gaiji
		mov	ax,3d00h
		int	21h
		jc	.save
		mov	bx,ax			; kept from an earlier run
		mov	ah,3eh
		int	21h
		mov	dx,s_gaiji_kept
		jmp	.ok
.save:		push	ds
		push	es
		mov	ax,CART_SEG
		mov	es,ax
		mov	ax,0b000h
		mov	ds,ax
		mov	si,GAIJI
		xor	di,di
		mov	cx,GAIJI_BYTES
		call	gaiji_on
		rep	movsb
		call	gaiji_off
		pop	es
		pop	ds
		mov	dx,f_gaiji
		xor	cx,cx
		mov	ah,3ch
		int	21h
		jc	.fail
		mov	bx,ax
		push	ds
		mov	ax,CART_SEG
		mov	ds,ax
		xor	dx,dx
		mov	cx,GAIJI_BYTES
		mov	ah,40h
		int	21h
		pop	ds
		jc	.fail_close
		cmp	ax,GAIJI_BYTES
		jne	.fail_close
		mov	ah,3eh
		int	21h
		jc	.fail_delete
		mov	dx,s_gaiji_saved
.ok:		call	print
		mov	byte [payload + HEADER + 12],1	; pcg_ok
.ret:		ret
.fail_close:	mov	ah,3eh
		int	21h
.fail_delete:	mov	dx,f_gaiji		; no half-written copy
		mov	ah,41h
		int	21h
.fail:		mov	dx,s_gaiji_fail
		jmp	print

; /R: the gaiji RAM from GAIJI.BAK, which is then deleted. DX: the message;
; CF: not done.
gaiji_restore:	mov	dx,f_gaiji
		mov	bx,CART_SEG
		mov	cx,GAIJI_BYTES + 1
		call	read_file
		jc	.none
		cmp	ax,GAIJI_BYTES
		jne	.bad
		push	ds
		push	es
		mov	ax,0b000h
		mov	es,ax
		mov	ax,CART_SEG
		mov	ds,ax
		xor	si,si
		mov	di,GAIJI
		mov	cx,GAIJI_BYTES
		call	gaiji_on
		rep	movsb
		call	gaiji_off
		pop	es
		pop	ds
		mov	dx,f_gaiji
		mov	ah,41h
		int	21h
		mov	dx,s_restored
		clc
		ret
.none:		mov	dx,s_no_gaiji
		stc
		ret
.bad:		mov	dx,s_bad_gaiji
		stc
		ret

; Port 153h: SMBC 9 with interrupts off (gaiji_on), and back as it was
; (gaiji_off). Keep every register; DS may be anything.
gaiji_on:	push	ax
		push	dx
		cli
		mov	dx,0153h
		in	al,dx
		mov	[cs:old_153],al
		and	al,0f0h
		or	al,09h
		out	dx,al
		pop	dx
		pop	ax
		ret
gaiji_off:	push	ax
		push	dx
		mov	dx,0153h
		mov	al,[cs:old_153]
		out	dx,al
		sti
		pop	dx
		pop	ax
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
s_msxbios	db	'MSX BIOS: MSXBIOS.ROM', 13, 10, '$'
s_bad_msxbios	db	'MSXBIOS.ROM is not an MSX1 main ROM (32 KiB).', 13, 10, '$'
s_menu		db	'Cartridges:', 13, 10, '0 none     . or ESC back to DOS', 13, 10, '$'
s_choose	db	'Number? $'
s_cart		db	13, 10, 'Cartridge: $'
s_no_cart	db	'The cartridge file cannot be read.', 13, 10, '$'
s_cart_size	db	'The cartridge must be 8, 16 or 32 KiB (no mapper).', 13, 10, '$'
s_gaiji_saved	db	'The gaiji RAM is saved in GAIJI.BAK; MSX /R puts it back.', 13, 10, '$'
s_gaiji_kept	db	'GAIJI.BAK holds the gaiji RAM; MSX /R puts it back.', 13, 10, '$'
s_gaiji_fail	db	'GAIJI.BAK cannot be written: Graphics I without the gaiji RAM.'
		db	13, 10, '$'
s_restored	db	'The gaiji RAM is restored from GAIJI.BAK.', 13, 10, '$'
s_no_gaiji	db	'There is no GAIJI.BAK to restore.', 13, 10, '$'
s_bad_gaiji	db	'GAIJI.BAK is not a copy of the gaiji RAM.', 13, 10, '$'
f_gaiji		db	'GAIJI.BAK', 0
opt_r		db	0
opt_n		db	0
old_153		db	0
f_msxbios	db	'MSXBIOS.ROM', 0
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
