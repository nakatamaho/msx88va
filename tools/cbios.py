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
($MSX_CBIOS or --cbios), checked by SHA-1, and patched for msx88va.

The patches replace code that cannot work on the copied-page memory of
msx88va or that would reach ports outside the I/O trap's ranges:

- CHKRAM's memory mapper set-up (ports FCh-FFh) and RAM search. The
  search writes to every slot's pages 2 and 3; with copied pages every
  slot looks writable. Replaced by slot 3 in pages 2 and 3.
- LPTOUT and LPTSTT (printer ports 90h, 91h): always not ready.
- FILVRM, LDIRMV and LDIRVM: their first three bytes become CALLN 71h;
  msx88va's native code does the whole block and the RET (one call
  instead of one I/O trap a byte). The addresses are those of the jump
  table targets at 0056h, 0059h and 005Ch; src/msx/msx.asm knows them.
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
    (0x00A5, "c3", "37c9", "LPTOUT: SCF; RET (aborted)"),
    (0x00A8, "c3", "afc9", "LPTSTT: XOR A; RET (not ready)"),
    (0x026D, "f5cd60", "eded71", "FILVRM: CALLN 71h (native fill and RET)"),
    (0x0281, "cd5502", "eded71", "LDIRMV: CALLN 71h (native copy and RET)"),
    (0x0297, "ebcd60", "eded71", "LDIRVM: CALLN 71h (native copy and RET)"),
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


def load(source: Path) -> tuple[bytes, bytes]:
    """The patched main ROM (32 KiB) and the logo ROM (16 KiB)."""
    roms = {}
    for name in (MAIN, LOGO):
        data = _read(source, name)
        digest = hashlib.sha1(data).hexdigest()
        if digest != SHA1[name]:
            raise SystemExit(f"error: {name} has SHA-1 {digest}, expected {SHA1[name]} "
                             "(C-BIOS 0.29a)")
        roms[name] = data
    main = bytearray(roms[MAIN])
    for offset, old, new, _ in PATCHES:
        old_b, new_b = bytes.fromhex(old), bytes.fromhex(new)
        if main[offset:offset + len(old_b)] != old_b:
            raise SystemExit(f"error: unexpected bytes at {offset:04X}h")
        main[offset:offset + len(new_b)] = new_b
    return bytes(main), roms[LOGO]
