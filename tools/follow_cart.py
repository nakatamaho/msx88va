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

"""A test cartridge for z80_follow (src/msx/msx.asm), and the comparison
of its results from two runs.

    python3 -I tools/follow_cart.py build OUT.ROM
    python3 -I tools/follow_cart.py compare FOLLOW.gvram.bin NATIVE.gvram.bin

The cartridge (16 KiB, no ROM data of anyone's) runs each snippet below
with four values of AF: scratch (E000h-E007h) and stack words (E0F8h-
E107h) set, BC, DE, HL set, OUT (A0h),A (the trap that starts
z80_follow), the snippet, then natively the SP, the registers, scratch
and stack into a 48-byte result at 8000h + 48 * n; at the end the
results go to VRAM 0000h and the snippets' VRAM writes are at 3000h-
34FFh. Build the private disk twice with --define DUMP_VRAM, once also
with --define TEST_NOFOLLOW (every I/O instruction trapped alone, the
rest run by the uPD9002), run each in vaeg for 2500 frames, capture
GVRAM (VRAM at its 8000h) and compare: every result must be equal.
"""

import sys


class A:
    def __init__(self, org):
        self.org = org; self.b = bytearray(); self.labels = {}; self.fix = []
    def here(self): return self.org + len(self.b)
    def L(self, name): self.labels[name] = self.here()
    def db(self, *v): self.b += bytes(v)
    def dw(self, v): self.b += bytes((v & 255, v >> 8))
    def rel(self, op, name): self.db(op, 0); self.fix.append(("rel", len(self.b) - 1, name))
    def abs(self, op, name): self.db(op); self.fix.append(("abs", len(self.b), name)); self.dw(0)
    def resolve(self):
        for kind, at, name in self.fix:
            t = self.labels[name]
            if kind == "rel":
                d = t - (self.org + at + 1)
                assert -128 <= d < 128, name
                self.b[at] = d & 255
            else:
                self.b[at] = t & 255; self.b[at + 1] = t >> 8

R = dict(B=0, C=1, D=2, E=3, H=4, L=5, M=6, A=7)
def ld_rn(a, r, n): a.db(0x06 | R[r] << 3, n)
def ld_rr(a, d, s): a.db(0x40 | R[d] << 3 | R[s])
def ld16(a, rr, v): a.db({"BC": 1, "DE": 0x11, "HL": 0x21, "SP": 0x31}[rr]); a.dw(v)
def out(a, n): a.db(0xd3, n)
def inp(a, n): a.db(0xdb, n)
def alu(a, op, r=None, n=None):
    k = ["ADD", "ADC", "SUB", "SBC", "AND", "XOR", "OR", "CP"].index(op)
    if n is None: a.db(0x80 | k << 3 | R[r])
    else: a.db(0xc6 | k << 3, n)
def inc(a, r): a.db(0x04 | R[r] << 3)
def dec(a, r): a.db(0x05 | R[r] << 3)
def vaddr(a, addr):
    alu(a, "XOR", "A"); ld_rn(a, "A", addr & 255); out(a, 0x99)
    ld_rn(a, "A", (addr >> 8) | 0x40); out(a, 0x99)

SUB = 0xe200   # RAM: OUT (98h),A; RET

def snippets():
    s = []
    def case(f): s.append(f); return f
    @case
    def _(a): inc(a, "A")
    @case
    def _(a): dec(a, "A")
    @case
    def _(a): ld_rn(a, "B", 0x7f); inc(a, "B")
    @case
    def _(a): ld_rn(a, "C", 0x80); dec(a, "C")
    @case
    def _(a): ld_rn(a, "D", 0xff); inc(a, "D")
    @case
    def _(a): ld_rn(a, "E", 0); dec(a, "E")
    @case
    def _(a): inc(a, "M"); dec(a, "M"); dec(a, "M")
    @case
    def _(a): alu(a, "ADD", n=0x3f)
    @case
    def _(a): alu(a, "SUB", n=0x41)
    @case
    def _(a): alu(a, "CP", n=0x80)
    @case
    def _(a): alu(a, "CP", "A")
    @case
    def _(a): alu(a, "AND", n=0x0f)
    @case
    def _(a): alu(a, "OR", n=0x81)
    @case
    def _(a): alu(a, "XOR", n=0xff)
    @case
    def _(a): alu(a, "XOR", "A")
    @case
    def _(a):
        for op, r in (("ADD", "B"), ("SUB", "C"), ("AND", "D"), ("OR", "E"), ("XOR", "H"), ("CP", "L")):
            alu(a, op, r)
    @case
    def _(a): alu(a, "ADD", "M"); alu(a, "CP", "M")
    @case
    def _(a): alu(a, "ADC", n=1); inc(a, "A")
    @case
    def _(a): alu(a, "SBC", "B"); inc(a, "A")
    @case
    def _(a): a.db(0x2f, 0x37)                  # CPL; SCF
    @case
    def _(a): a.db(0x3f, 0x3f, 0x3f)            # CCF x3
    @case
    def _(a): a.rel(0x20, "x"); ld_rn(a, "A", 1); a.L("x"); ld_rr(a, "B", "A")
    @case
    def _(a): a.rel(0x28, "x"); ld_rn(a, "A", 2); a.L("x"); ld_rr(a, "C", "A")
    @case
    def _(a):
        a.rel(0x30, "x"); ld_rn(a, "A", 3); a.L("x"); ld_rr(a, "D", "A")
        a.rel(0x38, "y"); ld_rn(a, "A", 4); a.L("y"); ld_rr(a, "E", "A")
    @case
    def _(a):
        a.abs(0xc2, "x"); ld_rn(a, "A", 5); a.L("x")
        a.abs(0xea, "y"); ld_rn(a, "B", 9); a.L("y")
        a.abs(0xfa, "z"); ld_rn(a, "C", 9); a.L("z"); a.db(0)
    @case
    def _(a): ld_rn(a, "B", 5); a.L("l"); inc(a, "A"); a.rel(0x10, "l")
    @case
    def _(a):
        a.abs(0xcd, "f"); a.rel(0x18, "e"); a.L("f"); ld_rn(a, "B", 7); a.db(0xc9)
        a.L("e"); inc(a, "A")
    @case
    def _(a):
        a.abs(0xcd, "f"); a.rel(0x18, "e"); a.L("f"); a.db(0xc0); ld_rn(a, "C", 1)
        a.db(0xc8); ld_rn(a, "C", 2); a.db(0xc9); a.L("e"); a.db(0)
    @case
    def _(a): a.db(0xf5, 0xc5, 0xd1, 0xe1)      # PUSH AF, BC; POP DE, HL
    @case
    def _(a): a.db(0xc1, 0xf1)                  # POP BC; POP AF
    @case
    def _(a):
        ld16(a, "BC", 0x1234); ld16(a, "DE", 0x5678); ld16(a, "HL", 0xe004)
        ld_rr(a, "M", "B"); ld_rr(a, "A", "M"); a.db(0x36, 0x9a)
    @case
    def _(a):
        ld16(a, "BC", 0xe001); a.db(0x0a); ld16(a, "DE", 0xe002); a.db(0x12)
        a.db(0x32, 0x06, 0xe0, 0x3a, 0x07, 0xe0)
    @case
    def _(a): a.db(0xcb, 0xf8, 0xcb, 0x81, 0xcb, 0xdf, 0xcb, 0xbd, 0xcb, 0xca)
    @case
    def _(a):
        alu(a, "XOR", "A"); a.L("l"); out(a, 0xa0); ld_rr(a, "E", "A"); ld_rr(a, "A", "M")
        out(a, 0xa1); a.db(0x23); ld_rr(a, "A", "E"); inc(a, "A"); alu(a, "CP", n=4)
        a.rel(0x20, "l")
    @case
    def _(a):
        ld_rn(a, "A", 8); out(a, 0xa0); ld_rn(a, "C", 0xa1); ld_rn(a, "B", 3)
        a.db(0xed, 0xa3, 0xed, 0xa3, 0xed, 0xa3)
    @case
    def _(a):
        ld_rn(a, "A", 0x0f); out(a, 0xa0); ld_rn(a, "A", 0x8f); out(a, 0xa1)
        ld_rn(a, "A", 0x0e); out(a, 0xa0); inp(a, 0xa2); ld_rr(a, "B", "A")
    @case
    def _(a):
        vaddr(a, 0x3000); ld16(a, "HL", 0xe000); ld16(a, "BC", 8)
        a.L("l"); ld_rr(a, "A", "M"); out(a, 0x98); a.db(0x23, 0x0b); ld_rr(a, "A", "B")
        alu(a, "OR", "C"); a.rel(0x20, "l")
    @case
    def _(a):
        vaddr(a, 0x3100); ld_rn(a, "C", 0x5a); ld_rn(a, "B", 6)
        a.L("l"); ld_rr(a, "A", "C"); a.db(0xcd, SUB & 255, SUB >> 8); a.rel(0x10, "l")
    @case
    def _(a):
        vaddr(a, 0x3200); ld16(a, "HL", 0xe000); ld_rn(a, "B", 8)
        a.L("l"); ld_rr(a, "A", "M"); a.db(0xcd, SUB & 255, SUB >> 8, 0x23); a.rel(0x10, "l")
    @case
    def _(a):
        vaddr(a, 0x3300); ld16(a, "HL", 0xe000); ld_rn(a, "B", 7)
        a.L("l"); ld_rr(a, "A", "M"); a.db(0x23, 0xcd, SUB & 255, SUB >> 8); a.rel(0x10, "l")
    @case
    def _(a):
        vaddr(a, 0x3400); ld_rn(a, "C", 0x98); ld16(a, "HL", 0xe000); ld_rn(a, "B", 5)
        a.db(*([0xed, 0xa3] * 5))
    @case
    def _(a): a.db(0xfb, 0xf3)                  # EI; DI
    @case
    def _(a):
        for d, s_ in (("B", "A"), ("C", "B"), ("D", "C"), ("E", "D"), ("L", "E"), ("A", "L")):
            ld_rr(a, d, s_)
    @case
    def _(a): a.db(0x03, 0x1b, 0x23, 0x2b, 0x13)
    @case
    def _(a): ld_rn(a, "B", 20); a.L("l"); dec(a, "A"); a.rel(0x10, "l")
    @case
    def _(a): a.db(0x22, 0x00, 0xe0); inc(a, "A")
    @case
    def _(a):                                    # RET cc after CP, JP P/PO
        alu(a, "CP", n=0x40); a.abs(0xf2, "x"); ld_rn(a, "B", 1); a.L("x")
        a.abs(0xe2, "y"); ld_rn(a, "C", 1); a.L("y"); a.db(0)
    return s

AFS = [0x0000, 0x7f01, 0x80d7, 0xff44]

def build(path):
    a = A(0x4000)
    a.b = bytearray(b"AB") + bytearray(14)
    a.fix = [("abs", 2, "init")]
    # setup: scratch and stack words; copy: scratch and stack to DE
    a.L("setup")
    for i in range(4):
        ld16(a, "HL", 0x1111 * (i + 1) + 0x0102); a.db(0x22, (0xe000 + 2 * i) & 255, 0xe0)
    for i in range(8):
        ld16(a, "HL", (0x0f0f * (i + 3)) ^ 0x5a5a); a.db(0x22, (0xe0f8 + 2 * i) & 255, (0xe0f8 + 2 * i) >> 8)
    a.db(0xc9)
    a.L("copy")
    ld16(a, "HL", 0xe000); ld16(a, "BC", 8); a.db(0xed, 0xb0)
    ld16(a, "HL", 0xe0f8); ld16(a, "BC", 16); a.db(0xed, 0xb0, 0xc9)
    a.L("init")
    a.db(0xf3)                                   # DI
    ld16(a, "SP", 0xf000)
    ld16(a, "HL", 0x98d3); a.db(0x22, SUB & 255, SUB >> 8)   # OUT (98h),A
    ld_rn(a, "A", 0xc9); a.db(0x32, (SUB + 2) & 255, (SUB + 2) >> 8)  # RET
    n = 0
    for snip in snippets():
        for af in AFS:
            res = 0x8000 + 48 * n
            ld16(a, "SP", 0xf000); a.abs(0xcd, "setup")
            ld16(a, "SP", 0xe100)
            ld16(a, "HL", af); a.db(0xe5, 0xf1)          # PUSH HL; POP AF
            ld16(a, "BC", 0x0310); ld16(a, "DE", 0x8001); ld16(a, "HL", 0xe000)
            out(a, 0xa0)
            sub = A(a.here()); snip(sub); sub.resolve(); a.b += sub.b
            a.db(0xed, 0x73, res & 255, res >> 8)        # LD (res),SP
            ld16(a, "SP", res + 10); a.db(0xe5, 0xd5, 0xc5, 0xf5)
            ld16(a, "SP", 0xf000); ld16(a, "DE", res + 10); a.abs(0xcd, "copy")
            n += 1
    ld16(a, "SP", 0xf000)
    ld16(a, "HL", 0x8000); ld16(a, "DE", 0); ld16(a, "BC", 48 * n)
    a.db(0xcd, 0x5c, 0x00)                           # LDIRVM
    a.db(0xfb)                                       # EI (the VRTC: DUMP_VRAM)
    a.L("end"); a.rel(0x18, "end")
    a.resolve()
    assert len(a.b) <= 0x4000, len(a.b)
    open(path, "wb").write(bytes(a.b) + b"\xff" * (0x4000 - len(a.b)))
    print(path, len(a.b), "bytes,", n, "cases")

def compare(path_a, path_b):
    a = open(path_a, "rb").read()[0x8000:0xc000]
    b = open(path_b, "rb").read()[0x8000:0xc000]
    n_cases = len(snippets()) * len(AFS)
    names = ["SP", "AF", "BC", "DE", "HL"]
    def regs(z):
        w = [z[0] | z[1] << 8] + [z[2 + 2 * i] | z[3 + 2 * i] << 8 for i in range(4)]
        return " ".join(f"{k}={v:04X}" for k, v in zip(names, [w[0], w[4], w[3], w[2], w[1]]))
    bad = 0
    for n in range(n_cases):
        x = a[48 * n:48 * n + 34]; y = b[48 * n:48 * n + 34]
        if x != y:
            bad += 1
            print(f"snippet {n // 4} AF {AFS[n % 4]:04X}: {regs(x)} {x[10:34].hex()}")
            print(f"{'':20}{regs(y)} {y[10:34].hex()}")
    if not any(b[:48 * n_cases]):
        print("no results: did the cartridge run?"); return 1
    vram = a[0x3000:0x3500] == b[0x3000:0x3500]
    print(f"{n_cases - bad} of {n_cases} cases equal; VRAM 3000h-34FFh {'equal' if vram else 'differs'}")
    return 0 if bad == 0 and vram else 1


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "build":
        build(sys.argv[2])
    elif len(sys.argv) == 4 and sys.argv[1] == "compare":
        sys.exit(compare(sys.argv[2], sys.argv[3]))
    else:
        raise SystemExit(__doc__)
