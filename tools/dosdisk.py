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

"""Shared build helpers: NASM, the MS-DOS 4.0 system disk, disk images.

The system disk is the FreeDOS-88VA project's MS-DOS 4.0 for the PC-88VA
(MIT licence), release msdos4-va.2, msdos4-pc88va-2hd.d88, checked by its
SHA-256. Disk images are written with vaeg's tools/pc88va/pcengine_disk.py
(beside this file, or in ../vaeg).
"""

import hashlib
import importlib.util
import os
import subprocess
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
MSDOS4_RELEASE = "https://github.com/FreeDOS-88VA/MS-DOS/releases/tag/msdos4-va.2"
MSDOS4_SHA256 = "7c4b141d31e0034120e0b07eb93b9bea808e1c54822e48e15189cc7398385db0"
MSDOS4_DEFAULT = Path.home() / ".cache/vaeg/msdos4-va.2/dl/msdos4-pc88va-2hd.d88"
FIXED_FAT_DATE = ((2026 - 1980) << 9) | (10 << 5) | 18     # 2026-10-18
BASE = 0x3000           # where the loader puts the programs (paragraph)


def nasm(args: list[str]) -> None:
    subprocess.run([os.environ.get("NASM", "nasm"), "-f", "bin", *args], check=True)


def disk_tool_path() -> Path:
    for path in (Path(__file__).resolve().parent / "pcengine_disk.py",
                 REPO.parent / "vaeg" / "tools" / "pc88va" / "pcengine_disk.py"):
        if path.exists():
            return path
    raise SystemExit("error: pcengine_disk.py (vaeg tools/pc88va) not found")


def load_disk_tool():
    spec = importlib.util.spec_from_file_location("pcengine_disk", disk_tool_path())
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.fat_now = lambda: (0, FIXED_FAT_DATE)
    return module


def check_msdos4(path: Path) -> None:
    if not path.exists():
        raise SystemExit(f"error: {path} not found: msdos4-pc88va-2hd.d88 of {MSDOS4_RELEASE}")
    if hashlib.sha256(path.read_bytes()).hexdigest() != MSDOS4_SHA256:
        raise SystemExit(f"error: {path} is not msdos4-pc88va-2hd.d88 of {MSDOS4_RELEASE}")


def make_disk(msdos4: Path, files: dict[str, bytes], output: Path) -> None:
    """The MS-DOS 4.0 system disk with FILES (8.3 name -> contents) added to
    its root."""
    tool = load_disk_tool()
    with tempfile.TemporaryDirectory(prefix="msx88va-dos-") as tmp:
        work = Path(tmp)
        vanilla = work / "vanilla.d88"
        tool.create_vanilla(str(msdos4), str(vanilla))
        disk = tool.PcEngineDisk(vanilla.read_bytes(), require_system_files=False)
        for name, contents in files.items():
            path = work / name
            path.write_bytes(contents)
            tool.add_file(disk, disk.root, path)
        disk.flush()
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(disk.image)


def loader(payload: bytes, defines: dict[str, str],
           includes: dict[str, str] | None = None) -> bytes:
    """src/dos/msxcom.asm with PAYLOAD, the msxdata.inc DEFINES and the
    generated INCLUDES (file name -> text)."""
    with tempfile.TemporaryDirectory(prefix="msx88va-com-") as tmp:
        work = Path(tmp)
        (work / "payload.bin").write_bytes(payload)
        lines = [f"BASE\t\tequ\t{BASE:#06x}",
                 f'%define PAYLOAD_BIN "{work / "payload.bin"}"']
        lines += [f"{k}\t\tequ\t{v}" if not k.startswith("%") else f"{k} {v}"
                  for k, v in defines.items()]
        (work / "msxdata.inc").write_text("\n".join(lines) + "\n", encoding="ascii")
        for name, text in (includes or {}).items():
            (work / name).write_text(text, encoding="ascii")
        nasm(["-I", f"{work}/", "-o", str(work / "OUT.COM"), str(REPO / "src/dos/msxcom.asm")])
        return (work / "OUT.COM").read_bytes()


def dos_text(path: Path) -> bytes:
    return path.read_bytes().replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
