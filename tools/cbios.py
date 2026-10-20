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

"""C-BIOS 0.29a (http://cbios.sourceforge.net/, two-clause BSD licence):
the MSX1 main and logo ROMs, found by name in a zip file or directory
($MSX_CBIOS or --cbios) and checked by SHA-1. They go on the disk as
released; MSX.COM applies PATCHES at run time (tools/build_dos.py writes
the table into it).

The patches replace code that cannot work on the copied-page memory of
msx88va or that would reach ports outside the I/O trap's ranges:

- CHKRAM's memory mapper set-up (ports FCh-FFh) and RAM search. The
  search writes to every slot's pages 2 and 3; with copied pages every
  slot looks writable. Replaced by slot 3 in pages 2 and 3.
- LPTOUT and LPTSTT (printer ports 90h, 91h): always not ready.
- The VDP, PSG and keyboard routines below: their first three bytes
  become CALLN 71h, and msx88va's native code does the routine (one call
  instead of an I/O trap for each port access). src/msx/msx.asm
  (bios_table) has the same addresses. None of the replaced bytes is a
  branch target.
"""

import hashlib
import os
import zipfile
from pathlib import Path

MAIN = "cbios_main_msx1.rom"
LOGO = "cbios_logo_msx1.rom"
SHA1 = {
    MAIN: "2f997e8a57528518c82ab3693fdae243dbbcc508",
    LOGO: "9fbbe400dbaf186aeba42e170d9424b032412c42",
}

# (offset, original bytes, new bytes, reason)
PATCHES = [
    (0x0D1A, "afd3ff3cd3fe3c", "3ef0d3a8c3870d",
     "CHKRAM: no mapper ports, no RAM search; A8h = F0h, continue at 0D87h"),
    (0x00A5, "c3d9", "37c9", "LPTOUT: SCF; RET (aborted)"),
    (0x00A8, "c303", "afc9", "LPTSTT: XOR A; RET (not ready)"),
    (0x026D, "f5cd60", "eded71", "FILVRM: CALLN 71h"),
    (0x0281, "cd5502", "eded71", "LDIRMV: CALLN 71h"),
    (0x0297, "ebcd60", "eded71", "LDIRVM: CALLN 71h"),
    (0x0260, "f37dd3", "eded71", "SETWRT: CALLN 71h"),
    (0x0255, "f37dd3", "eded71", "SETRD: CALLN 71h"),
    (0x024D, "f5cd60", "eded71", "WRTVRM: CALLN 71h"),
    (0x0245, "cd5502", "eded71", "RDVRM: CALLN 71h"),
    (0x022E, "f3cbb9", "eded71", "WRTVDP: CALLN 71h, continues at 023Ah"),
    (0x1752, "f3d3a0", "eded71", "WRTPSG: CALLN 71h"),
    (0x175C, "d3a0db", "eded71", "RDPSG: CALLN 71h"),
    (0x1770, "db99c9", "eded71", "RDVDP: CALLN 71h"),
    (0x1773, "f3c54f", "eded71", "SNSMAT: CALLN 71h"),
    (0x1963, "dbaae6", "eded71", "keyboard scan (KEYINT): CALLN 71h, continues at 1977h"),
]



def default_source() -> Path | None:
    value = os.environ.get("MSX_CBIOS")
    return Path(value) if value else None


def _read(source: Path, name: str) -> bytes:
    if source.is_dir():
        found = sorted(source.rglob(name))
        if not found:
            raise SystemExit(f"error: {name} not found under {source}")
        return found[0].read_bytes()
    with zipfile.ZipFile(source) as archive:
        for entry in archive.namelist():
            if entry.rsplit("/", 1)[-1] == name:
                return archive.read(entry)
    raise SystemExit(f"error: {name} not found in {source}")


def load_original(source: Path) -> tuple[bytes, bytes]:
    """The main ROM (32 KiB) and the logo ROM (16 KiB) as released, checked
    by SHA-1; MSX.COM applies PATCHES at run time."""
    roms = []
    for name in (MAIN, LOGO):
        data = _read(source, name)
        digest = hashlib.sha1(data).hexdigest()
        if digest != SHA1[name]:
            raise SystemExit(f"error: {name} has SHA-1 {digest}, expected {SHA1[name]} "
                             "(C-BIOS 0.29a)")
        roms.append(data)
    return roms[0], roms[1]


def licence_text(source: Path) -> bytes:
    """C-BIOS's doc/cbios.txt (its licence and history), CR LF."""
    data = _read(source, "cbios.txt")
    return data.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
