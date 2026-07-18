"""Fetch ONE member out of the Godot export-templates .tpz without downloading
the whole ~1 GB archive.

    python tools/fetch_template.py [dest_path]

A .tpz is a plain zip, and HTTP range requests let us read it like a local
file: grab the tail to parse the central directory, find the member's entry,
then fetch just that member's compressed byte range and inflate it. The
Windows release runtime comes down as a ~50 MB transfer instead of ~1 GB.

Used by tools/build_release.py to obtain windows_release_x86_64.exe — the
proper player runtime, ~2.5x smaller than shipping a copy of the editor exe.
"""
from __future__ import annotations

import struct
import sys
import urllib.request
import zlib
from pathlib import Path

TPZ_URL = (
    "https://github.com/godotengine/godot/releases/download/"
    "4.7-stable/Godot_v4.7-stable_export_templates.tpz"
)
MEMBER = "templates/windows_release_x86_64.exe"


def _fetch_range(url: str, start: int, end: int) -> bytes:
    """Fetches the inclusive byte range [start, end]. GitHub's asset CDN only
    honours absolute ranges (suffix `bytes=-N` gets HTTP 501)."""
    req = urllib.request.Request(url, headers={"Range": f"bytes={start}-{end}"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        if resp.status not in (200, 206):
            raise RuntimeError(f"HTTP {resp.status} for range {start}-{end}")
        return resp.read()


def _total_size(url: str) -> int:
    """Reads the archive's total size from a 1-byte ranged probe."""
    req = urllib.request.Request(url, headers={"Range": "bytes=0-0"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        content_range = resp.headers.get("Content-Range", "")
        # e.g. "bytes 0-0/1234567890"
        if "/" not in content_range:
            raise RuntimeError(f"no Content-Range in probe response: {content_range!r}")
        return int(content_range.rsplit("/", 1)[1])


def _central_directory(url: str) -> tuple[bytes, int]:
    """Returns (central directory bytes, cd_start_offset)."""
    total = _total_size(url)
    tail_len = min(128 * 1024, total)
    tail = _fetch_range(url, total - tail_len, total - 1)
    eocd_at = tail.rfind(b"PK\x05\x06")
    if eocd_at < 0:
        raise RuntimeError("zip end-of-central-directory not found in tail")
    cd_size, cd_start = struct.unpack_from("<II", tail, eocd_at + 12)
    if cd_size == 0xFFFFFFFF or cd_start == 0xFFFFFFFF:  # zip64
        loc_at = tail.rfind(b"PK\x06\x07", 0, eocd_at)
        if loc_at < 0:
            raise RuntimeError("zip64 locator not found")
        (eocd64_off,) = struct.unpack_from("<Q", tail, loc_at + 8)
        eocd64 = _fetch_range(url, eocd64_off, eocd64_off + 55)
        if eocd64[:4] != b"PK\x06\x06":
            raise RuntimeError("bad zip64 EOCD")
        cd_size, cd_start = struct.unpack_from("<QQ", eocd64, 40)
    cd = _fetch_range(url, cd_start, cd_start + cd_size - 1)
    return cd, cd_start


def _find_member(cd: bytes, name: str) -> tuple[int, int, int]:
    """Returns (local_header_offset, compressed_size, method) for name."""
    pos = 0
    want = name.encode()
    while pos + 4 <= len(cd) and cd[pos : pos + 4] == b"PK\x01\x02":
        (method,) = struct.unpack_from("<H", cd, pos + 10)
        comp_size, _uncomp = struct.unpack_from("<II", cd, pos + 20)
        n_len, e_len, c_len = struct.unpack_from("<HHH", cd, pos + 28)
        (lho,) = struct.unpack_from("<I", cd, pos + 42)
        fname = cd[pos + 46 : pos + 46 + n_len]
        if fname == want:
            if comp_size == 0xFFFFFFFF or lho == 0xFFFFFFFF:
                # zip64 extra field: fields appear in a fixed order, only the
                # ones that overflowed 32 bits are present.
                extra = cd[pos + 46 + n_len : pos + 46 + n_len + e_len]
                ep = 0
                while ep + 4 <= len(extra):
                    tag, size = struct.unpack_from("<HH", extra, ep)
                    if tag == 0x0001:
                        vals = []
                        vp = ep + 4
                        for _ in range(size // 8):
                            vals.append(struct.unpack_from("<Q", extra, vp)[0])
                            vp += 8
                        # order: uncomp, comp, offset (present only if 0xFFFFFFFF)
                        idx = 0
                        if _uncomp == 0xFFFFFFFF:
                            idx += 1
                        if comp_size == 0xFFFFFFFF:
                            comp_size = vals[idx]
                            idx += 1
                        if lho == 0xFFFFFFFF:
                            lho = vals[idx]
                        break
                    ep += 4 + size
            return lho, comp_size, method
        pos += 46 + n_len + e_len + c_len
    raise RuntimeError(f"{name} not found in archive")


def fetch_member(url: str, member: str, dest: Path) -> Path:
    """Downloads `member` from the remote zip at `url` into `dest`."""
    cd, _ = _central_directory(url)
    lho, comp_size, method = _find_member(cd, member)
    # Local header: 30 fixed bytes + name + extra, then the compressed stream.
    head = _fetch_range(url, lho, lho + 29)
    if head[:4] != b"PK\x03\x04":
        raise RuntimeError("bad local file header")
    n_len, e_len = struct.unpack_from("<HH", head, 26)
    data_at = lho + 30 + n_len + e_len
    print(f"  downloading {member} ({comp_size / 1e6:.1f} MB compressed)...", flush=True)
    blob = _fetch_range(url, data_at, data_at + comp_size - 1)
    if method == 8:
        blob = zlib.decompress(blob, -15)
    elif method != 0:
        raise RuntimeError(f"unsupported compression method {method}")
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(blob)
    print(f"  -> {dest} ({len(blob) / 1e6:.1f} MB)")
    return dest


def main() -> None:
    dest = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("build/templates/windows_release_x86_64.exe")
    fetch_member(TPZ_URL, MEMBER, dest)


if __name__ == "__main__":
    main()
