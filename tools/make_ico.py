"""Stitch the PNGs rendered by tools/render_icon.gd into a Windows .ico.

    python tools/make_ico.py [out_path]

Modern Windows accepts PNG-compressed images inside an .ico for every size,
so this needs nothing beyond the stdlib. Used by tools/build_release.py to
brand the launcher exe and the installer.
"""
from __future__ import annotations

import struct
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
ICON_DIR = REPO / "build" / "icons"
SIZES = [16, 24, 32, 48, 64, 128, 256]


def build_ico(out: Path) -> None:
    images: list[tuple[int, bytes]] = []
    for size in SIZES:
        png = ICON_DIR / f"icon_{size}.png"
        if not png.exists():
            raise FileNotFoundError(f"{png} missing - run tools/render_icon.gd first")
        images.append((size, png.read_bytes()))

    header = struct.pack("<HHH", 0, 1, len(images))
    entries = b""
    offset = len(header) + 16 * len(images)
    payload = b""
    for size, data in images:
        # 256 is stored as 0 in the 1-byte width/height fields.
        b_size = 0 if size >= 256 else size
        entries += struct.pack(
            "<BBBBHHII", b_size, b_size, 0, 0, 1, 32, len(data), offset
        )
        payload += data
        offset += len(data)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(header + entries + payload)
    print(f"make_ico: wrote {out} ({out.stat().st_size / 1024:.0f} KB)")


if __name__ == "__main__":
    dest = Path(sys.argv[1]) if len(sys.argv) > 1 else ICON_DIR / "motionfit.ico"
    build_ico(dest)
