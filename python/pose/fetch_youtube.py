"""Download exercise clips from YouTube into the folder-per-label layout that
`video_to_features.py` consumes.

WHY: public datasets don't cover the in-place cardio a cardio game needs
(march / high-knees / jog) and lack clean jumping-jack *video*. YouTube
follow-along tutorials do -- and training across many different people/angles
generalises better than recording only yourself. The clips still run through the
EXACT live feature pipeline, so no train/serve skew.

Give it a manifest (one clip per line):

    # label            url                                    [start]   [end]
    jumping_jacks      https://youtu.be/AAAAAAA                00:12     00:42
    jumping_jacks      https://youtu.be/BBBBBBB
    march              https://youtu.be/CCCCCCC                01:05     01:50
    high_knees         https://youtu.be/DDDDDDD                00:30     01:00

- Columns are whitespace-separated. Lines starting with '#' are comments.
- start/end are optional (HH:MM:SS or MM:SS). If BOTH are given, only that
  section is downloaded (fast, and skips intros/outros) -- this is where the
  person is actually doing the move cleanly, which you pick by eye.
- The label MUST be one of recording.LABELS values so the trainer understands it.

Run:
    python python/pose/fetch_youtube.py clips.txt
    python python/pose/fetch_youtube.py clips.txt --out datasets/exercises
    # or a single clip without a manifest:
    python python/pose/fetch_youtube.py --label march --url https://youtu.be/X --start 1:05 --end 1:50

Then convert + train exactly as before:
    python python/pose/video_to_features.py datasets/exercises/
    python python/pose/train_classifier.py python/pose/recordings/public/

Requires yt-dlp and ffmpeg on PATH.
"""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import recording  # noqa: E402  for the canonical label set

VALID_LABELS = set(recording.LABELS.values())


def _check_tools() -> None:
    for tool in ("yt-dlp", "ffmpeg"):
        # shutil.which avoids per-tool flag differences (ffmpeg uses -version,
        # not --version) that made a naive version call falsely report "missing".
        if shutil.which(tool) is None:
            raise SystemExit(
                f"'{tool}' not found on PATH. Install it first "
                f"(pip install yt-dlp ; and get ffmpeg)."
            )


def parse_manifest(path: Path) -> list[tuple[str, str, str | None, str | None]]:
    clips: list[tuple[str, str, str | None, str | None]] = []
    # utf-8-sig strips a BOM that Windows editors/PowerShell prepend, which would
    # otherwise glue itself to the first line and defeat the '#' comment check.
    for lineno, raw in enumerate(path.read_text(encoding="utf-8-sig").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) < 2:
            raise SystemExit(f"{path}:{lineno}: need at least 'label url', got: {raw!r}")
        label, url = parts[0], parts[1]
        start = parts[2] if len(parts) > 2 else None
        end = parts[3] if len(parts) > 3 else None
        clips.append((label, url, start, end))
    return clips


def download_clip(label: str, url: str, start: str | None, end: str | None,
                  out_dir: Path, index: int) -> bool:
    """Download one clip (optionally just a time section) into out_dir/<label>/."""
    dest = out_dir / label
    dest.mkdir(parents=True, exist_ok=True)
    out_tmpl = str(dest / f"{label}_{index:03d}.%(ext)s")

    cmd = [
        "yt-dlp",
        "-f", "bestvideo[ext=mp4][height<=720]+bestaudio/best[ext=mp4]/best",
        "--recode-video", "mp4",       # guarantee an mp4 OpenCV can open
        "--no-playlist",
        "-o", out_tmpl,
    ]
    if start and end:
        # Download only the chosen section -- fast, and drops intros/outros.
        cmd += ["--download-sections", f"*{start}-{end}", "--force-keyframes-at-cuts"]
    cmd.append(url)

    print(f"  [{label}] {url}" + (f"  ({start}-{end})" if start and end else "  (full)"))
    result = subprocess.run(cmd)
    if result.returncode != 0:
        print(f"    ! yt-dlp failed for {url}")
        return False
    return True


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("manifest", nargs="?", help="Text file of clips (label url [start] [end]).")
    parser.add_argument("--out", default="datasets/exercises",
                        help="Root output folder (one sub-folder per label is created).")
    parser.add_argument("--label", help="Single-clip mode: the move label.")
    parser.add_argument("--url", help="Single-clip mode: the YouTube URL.")
    parser.add_argument("--start", help="Single-clip mode: section start (MM:SS).")
    parser.add_argument("--end", help="Single-clip mode: section end (MM:SS).")
    args = parser.parse_args()

    _check_tools()
    out_dir = Path(args.out)

    if args.manifest:
        clips = parse_manifest(Path(args.manifest))
    elif args.label and args.url:
        clips = [(args.label, args.url, args.start, args.end)]
    else:
        raise SystemExit("Give a manifest file, or --label and --url for a single clip.")

    # Warn about unknown labels up front rather than after a long download.
    unknown = {c[0] for c in clips} - VALID_LABELS
    if unknown:
        print(f"WARNING: labels not in recording.LABELS (trainer will ignore them): "
              f"{sorted(unknown)}\n  valid: {sorted(VALID_LABELS)}\n")

    # Number clips per label so filenames don't collide -- and seed the counter
    # from files already on disk so repeat runs APPEND rather than overwrite
    # earlier good clips.
    per_label_count: dict[str, int] = {}
    for label in {c[0] for c in clips}:
        existing = list((out_dir / label).glob(f"{label}_*.mp4"))
        per_label_count[label] = len(existing)
    ok = fail = 0
    for label, url, start, end in clips:
        idx = per_label_count.get(label, 0) + 1
        per_label_count[label] = idx
        if download_clip(label, url, start, end, out_dir, idx):
            ok += 1
        else:
            fail += 1

    print(f"\nDone. {ok} clip(s) downloaded, {fail} failed -> {out_dir}")
    if ok:
        print(f"Next:  python {Path(__file__).parent.name}/video_to_features.py {out_dir}/")


if __name__ == "__main__":
    main()
