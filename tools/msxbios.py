#!/usr/bin/env python3
# Copyright (c) 2026 Nakata Maho
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR "AS IS" AND ANY EXPRESS OR
# IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
# OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
# IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
# INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
# BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF
# USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
# ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
# THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

"""The run-time patches of a user's MSX BIOS (MSXBIOS.ROM; none is
distributed or committed). MSX.COM computes the SHA-1 of the ROM and
applies PATCHES only when it is SHA1 (the Japanese MSX1 BIOS version 1.0);
another ROM runs unpatched, every VDP, PSG and PPI access an I/O trap.
Each patch puts CALLN 71h (EDh EDh 71h) over the first three bytes of a
routine of the BIOS jump table, or of a loop or port access inside the
BIOS that a game runs every frame (the interrupt's, GTSTCK's); src/msx/msx.asm (msx_table) does the
routine natively and leaves the registers and flags as the routine does.
None of the replaced bytes is a branch target; FILVRM and RDPSG are also
entered by falling through from the code before them, which runs the
CALLN as a call would.
"""

SHA1 = "302afb5d8be26c758309ca3df611ae69cced2821"

CALLN = "eded71"

# (offset, reason)
PATCHES = [
    (0x057F, "WRTVDP (0047h); continues at 0589h"),
    (0x07D7, "RDVRM (004Ah)"),
    (0x07CD, "WRTVRM (004Dh)"),
    (0x07EC, "SETRD (0050h)"),
    (0x07DF, "SETWRT (0053h)"),
    (0x0815, "FILVRM (0056h)"),
    (0x070F, "LDIRMV (0059h)"),
    (0x0744, "LDIRVM (005Ch)"),
    (0x1102, "WRTPSG (0093h)"),
    (0x110E, "RDPSG (0096h)"),
    (0x1449, "RDVDP (013Eh)"),
    (0x1452, "SNSMAT (0141h)"),
    (0x0C4D, "the interrupt's status read (IN A,(99h); AND A); continues at 0C50h"),
    (0x0D12, "the interrupt's keyboard scan (11 rows); continues at 0D26h"),
    (0x1226, "the space row's read for GTTRIG (row 8)"),
    (0x121F, "GTSTCK/GTTRIG's PSG register 15 write and register 14 read; "
             "continues at 1224h"),
]
