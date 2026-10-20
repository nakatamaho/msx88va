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

"""Add files (cartridge ROMs) to an msx88va MS-DOS 4.0 disk image.

    python3 -I add_files.py DISK.d88 FILE... [-o OUTPUT.d88]

Each FILE is copied to the root of the disk under an 8.3 name: the letters
and digits of its name, at most 8, with its extension (cartridges: .ROM).
MSX.COM runs the one *.ROM file on the disk, or shows a menu when there
are several. The result goes to OUTPUT.d88 (default: DISK-added.d88).
Needs pcengine_disk.py (from the vaeg project) beside this script.
"""

import argparse
import importlib.util
import re
import sys
import tempfile
from pathlib import Path


def load_disk_tool():
    here = Path(__file__).resolve().parent
    for path in (here / "pcengine_disk.py",
                 here.parents[1] / "vaeg" / "tools" / "pc88va" / "pcengine_disk.py"):
        if path.exists():
            spec = importlib.util.spec_from_file_location("pcengine_disk", path)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            return module
    sys.exit("error: pcengine_disk.py not found beside add_files.py")


def dos_name(path: Path) -> str:
    stem = re.sub(r"[^A-Z0-9]", "", path.stem.split("(")[0].upper())[:8] or "FILE"
    ext = re.sub(r"[^A-Z0-9]", "", path.suffix.upper())[:3]
    return f"{stem}.{ext}" if ext else stem


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("disk", type=Path)
    parser.add_argument("files", type=Path, nargs="+")
    parser.add_argument("-o", "--output", type=Path)
    args = parser.parse_args()
    output = args.output or args.disk.with_name(args.disk.stem + "-added.d88")
    tool = load_disk_tool()
    disk = tool.PcEngineDisk(args.disk.read_bytes(), require_system_files=False)
    with tempfile.TemporaryDirectory(prefix="msx88va-add-") as tmp:
        for path in args.files:
            target = Path(tmp) / dos_name(path)
            target.write_bytes(path.read_bytes())
            tool.add_file(disk, disk.root, target)
            print(f"{path} -> {target.name}")
    disk.flush()
    output.write_bytes(disk.image)
    print(output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
