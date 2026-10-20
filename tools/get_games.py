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

"""Download free MSXdev games and add them to an msx88va disk image.

    python3 -I get_games.py [DISK.d88] [-o OUTPUT.d88] [--zips DIR]
                            [--only NAME ...] [--list]

The games are freeware owned by their authors, published by the MSXdev
contest (https://www.msxdev.org/); msx88va does not distribute them. This
script fetches each game's official ZIP from msxdev.org, checks it against
the SHA-256 below, takes the ROM out of it (nothing in the ZIP is run) and
adds it to a copy of DISK.d88 (default: msx88va.d88 beside this script),
with GAMES.TXT naming the games, their authors and pages. The result goes
to OUTPUT.d88 (default: DISK-games.d88). The ZIPs are kept in --zips
(default: msxdev-zips beside the output) and not fetched again.

All are MSX1 cartridges of 16 or 32 KiB without a mapper. A ZIP whose
SHA-256 differs (the author published a new version) is skipped; see its
page.
"""

import argparse
import hashlib
import io
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import add_files  # noqa: E402

UPLOADS = "https://www.msxdev.org/wp-content/uploads/"
PAGES = "https://www.msxdev.org/"

# DOS name, title, author, page, ZIP, its SHA-256, the ROM inside.
GAMES = [
    ("UBOATKIL.ROM", "U-boat Killer", "JCCyC",
     "2026/10/18/msxdev26-08-u-boat-killer/",
     "2026/10/MSXdev26_U-boatKiller_v1.0-1.zip",
     "470075abe3a21c9254e9bd6e8c44f8b886e329918eb46b42b47ce938ec609ca8",
     "MSXdev26_U-boatKiller_v1.0.rom"),
    ("ZXETRIS.ROM", "Zxetris", "Fausto Pracek",
     "2025/10/01/msxdev25-09-zxetris/",
     "2025/09/MSXdev25_Zxetris_v1.0.zip",
     "e9a0523e6b7313a29f61748f78b2737c07ec29c227b65b8f713bac7de49dc3ca",
     "MSXdev25_Zxetris_v1.0.rom"),
    ("MIX.ROM", "Mix", "Uninteresting",
     "2022/04/28/msxdev22-09-mix/",
     "2022/04/MSXdev22_Mix_v1.2.zip",
     "b9798d32a3894d06d0cb2c0ba27218da1ecdbfb85b0ec972dcfc60221fa16d4e",
     "MSXdev22_Mix_v1.2.rom"),
    ("GSSOCCER.ROM", "GS Soccer", "Fausto Pracek",
     "2025/12/19/msxdev25-19-gs-soccer/",
     "2025/12/MSXdev25_GSSoccer_v1.3.zip",
     "bc83af37881f412ff5ca56d1488994f0934bb67a704fa51cba4f5c809835ed7e",
     "MSXdev25_GSSoccer_v1.3.rom"),
    ("TERMRUN.ROM", "Terminal Run", "Altaris Software",
     "2026/10/11/msxdev26-06-terminal-run/",
     "2026/10/MSXdev26_TerminalRun_v1.0.zip",
     "4a393f604c80ac5d6072cdc1747194b7ff69d482b6a90f80bff4fa6bc12d9275",
     "MSXdev26_TerminalRun_v1.0.ROM"),
    ("SHIFT.ROM", "Shift", "Ali Pouladi (Haplo), Andy Johns, Marukpa",
     "2026/01/10/msxdev25-25-shift/",
     "2026/02/MSXdev25_Shift_v1.1.zip",
     "cd984b258b751b28d6b7727e5079655cfa1922c6486cc33ff5469266bc628e4e",
     "MSXdev25_Shift_v1.1.rom"),
    ("BINBATTL.ROM", "Binary Battle", "Ali Pouladi (Haplo), Andy Johns",
     "2025/01/17/msxdev24-23-binary-battle/",
     "2025/01/MSXdev24_BinaryBattle_v1.0.zip",
     "551d6c6f6468dd76b27ffb84c698eed2b395bb3556b131ff45ffe467d9951572",
     "MSXdev24_BinaryBattle_v1.0.rom"),
    ("ABUCYMBL.ROM", "The Drop of Abu-Cymbel", "joesg",
     "2024/12/17/msxdev24-17-the-drop-of-abu-cymbel/",
     "2024/12/MSXdev24_ThedropofAbu-Cymbel_v1.0.zip",
     "acabc8436cf68a2105dabeac725803a030136b204ce4e143db8ca67770020342",
     "MSXdev24_ThedropofAbu-Cymbel_v1.0.rom"),
]


def fetch(url: str, path: Path, sha256: str) -> bytes:
    """The ZIP from path when it has the SHA-256, or else downloaded from url
    to path."""
    if path.exists():
        data = path.read_bytes()
        if hashlib.sha256(data).hexdigest() == sha256:
            return data
    request = urllib.request.Request(url, headers={"User-Agent": "msx88va-get-games"})
    with urllib.request.urlopen(request, timeout=60) as response:
        data = response.read()
    path.write_bytes(data)
    return data


def cartridge(data: bytes, member: str) -> bytes:
    """The ROM member of the ZIP data: 8, 16 or 32 KiB starting with AB."""
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        rom = archive.read(member)
    if len(rom) not in (0x2000, 0x4000, 0x8000) or rom[:2] != b"AB":
        raise ValueError(f"{member} is not an 8, 16 or 32 KiB cartridge")
    return rom


def games_text(games: list[tuple]) -> bytes:
    lines = ["Games on this disk",
             "",
             "Freeware MSX games from the MSXdev contest, downloaded by the",
             "user from msxdev.org with get_games.py. Each game belongs to its",
             "author; msx88va does not distribute them.",
             ""]
    for name, title, author, page, *_ in games:
        lines += [f"{name:<13}{title}", f"{'':13}{author}", f"{'':13}{PAGES}{page}", ""]
    return "\r\n".join(lines).encode("ascii") + b"\r\n\x1a"


def main() -> int:
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("disk", type=Path, nargs="?", default=here / "msx88va.d88")
    parser.add_argument("-o", "--output", type=Path)
    parser.add_argument("--zips", type=Path, help="where the ZIPs are kept")
    parser.add_argument("--only", nargs="+", metavar="NAME",
                        help="only these games (DOS names, e.g. MIX.ROM)")
    parser.add_argument("--list", action="store_true", help="list the games and stop")
    args = parser.parse_args()
    if args.list:
        for name, title, author, page, *_ in GAMES:
            print(f"{name:<13}{title} ({author})  {PAGES}{page}")
        return 0
    chosen = GAMES
    if args.only:
        wanted = {n.upper() for n in args.only}
        chosen = [g for g in GAMES if g[0] in wanted]
        unknown = wanted - {g[0] for g in chosen}
        if unknown:
            parser.error("unknown games: " + ", ".join(sorted(unknown)))
    output = args.output or args.disk.with_name(args.disk.stem + "-games.d88")
    zips = args.zips or output.parent / "msxdev-zips"
    zips.mkdir(parents=True, exist_ok=True)

    tool = add_files.load_disk_tool()
    disk = tool.PcEngineDisk(args.disk.read_bytes(), require_system_files=False)
    added, failed = [], []
    with tempfile.TemporaryDirectory(prefix="msx88va-games-") as tmp:
        for game in chosen:
            name, title, _, page, zip_path, sha256, member = game
            url = UPLOADS + zip_path
            path = zips / zip_path.rsplit("/", 1)[-1]
            try:
                data = fetch(url, path, sha256)
                digest = hashlib.sha256(data).hexdigest()
                if digest != sha256:
                    raise ValueError(f"SHA-256 {digest}, expected {sha256} "
                                     f"(a new version? see {PAGES}{page})")
                rom = cartridge(data, member)
            except (OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
                print(f"skipped {title}: {error}", file=sys.stderr)
                failed.append(title)
                continue
            target = Path(tmp) / name
            target.write_bytes(rom)
            tool.add_file(disk, disk.root, target)
            added.append(game)
            print(f"{title} -> {name} ({len(rom) // 1024} KiB)")
        if added:
            target = Path(tmp) / "GAMES.TXT"
            target.write_bytes(games_text(added))
            tool.add_file(disk, disk.root, target)
    if not added:
        print("error: no game added", file=sys.stderr)
        return 1
    disk.flush()
    output.write_bytes(disk.image)
    print(output)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
