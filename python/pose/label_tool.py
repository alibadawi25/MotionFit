"""Post-hoc labelling tool for MotionFit recordings.

The companion to `pose_server.py --record`: record a session while you move
freely (no keyboard), then open it here and mark which stretches were which move
*afterwards*. It replays the recording as the tracked skeleton (the raw video is
not stored -- only landmarks -- but the stick figure is plenty to label from),
lets you scrub, and paints move labels onto time-ranges. The result is written
as `<name>.labeled.jsonl`, which `train_classifier.py` reads directly.

Run:
    python python/pose/label_tool.py python/pose/recordings/rec_XXXX.jsonl

Controls (shown on screen):
    SPACE      play / pause
    a / d      step back / forward one frame   (also Left / Right arrows)
    , / .      jump back / forward ten frames
    i / o      set the IN / OUT point of a span at the current frame
    0 .. 6     label the selected span with that move (see the legend)
    x          clear the selected span back to 'unlabeled'
    c          clear the IN/OUT selection
    s          save -> <name>.labeled.jsonl
    ESC / q    quit
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Optional

import cv2

try:
    from recording import DEFAULT_LABEL, LABELS, label_for_key
except ImportError:  # pragma: no cover - script run from elsewhere
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from recording import DEFAULT_LABEL, LABELS, label_for_key

# BlazePose 33-point connections (hard-coded so this tool needs no MediaPipe).
POSE_CONNECTIONS = (
    (0, 1), (1, 2), (2, 3), (3, 7), (0, 4), (4, 5), (5, 6), (6, 8), (9, 10),
    (11, 12), (11, 13), (13, 15), (15, 17), (15, 19), (15, 21), (17, 19),
    (12, 14), (14, 16), (16, 18), (16, 20), (16, 22), (18, 20),
    (11, 23), (12, 24), (23, 24),
    (23, 25), (25, 27), (27, 29), (29, 31), (27, 31),
    (24, 26), (26, 28), (28, 30), (30, 32), (28, 32),
)

# A distinct colour per label for the skeleton tint and the timeline (BGR).
LABEL_COLORS = {
    DEFAULT_LABEL: (70, 70, 70),
    "idle": (150, 150, 150),
    "march": (0, 200, 0),
    "high_knees": (0, 165, 255),
    "jog": (255, 200, 0),
    "jumping_jacks": (200, 0, 200),
    "squat": (0, 0, 220),
    "jump": (0, 220, 220),
}
CANVAS_W, CANVAS_H = 960, 720
TIMELINE_H = 26


# --- Non-UI logic (importable / testable) ------------------------------------
def load_recording(path: Path) -> list[dict]:
    """Read a JSONL recording into a list of frame dicts (bad lines skipped)."""
    frames: list[dict] = []
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                try:
                    frames.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    return frames


def initial_labels(frames: list[dict]) -> list[str]:
    """Seed the per-frame label track from each frame's own 'label' field.

    Re-opening a `.labeled.jsonl` therefore restores previous work; a fresh
    recording starts all-'unlabeled'.
    """
    return [str(f.get("label") or DEFAULT_LABEL) for f in frames]


def span_bounds(in_pt: Optional[int], out_pt: Optional[int], cur: int, n: int) -> tuple[int, int]:
    """Resolve the active span from the IN/OUT marks and the cursor.

    Both marks set -> that range; only one -> from it to the cursor; neither ->
    just the current frame. Always returned low..high and clamped to the clip.
    """
    pts = [p for p in (in_pt, out_pt) if p is not None] or [cur]
    if len(pts) == 1:
        pts = [pts[0], cur]
    lo, hi = min(pts), max(pts)
    return max(0, lo), min(n - 1, hi)


def apply_label(labels: list[str], lo: int, hi: int, name: str) -> None:
    for i in range(lo, hi + 1):
        labels[i] = name


def save_labeled(frames: list[dict], labels: list[str], out_path: Path) -> Path:
    """Write frames with the edited labels back out as JSONL for the trainer."""
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as fh:
        for frame, label in zip(frames, labels):
            frame = dict(frame)
            frame["label"] = label
            fh.write(json.dumps(frame) + "\n")
    return out_path


def output_path_for(path: Path) -> Path:
    """`rec.jsonl` -> `rec.labeled.jsonl`; an already-labeled file saves in place."""
    if path.name.endswith(".labeled.jsonl"):
        return path
    return path.with_suffix("").with_suffix(".labeled.jsonl")


def label_counts(labels: list[str]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for lab in labels:
        counts[lab] = counts.get(lab, 0) + 1
    return counts


# --- Rendering ---------------------------------------------------------------
def _draw_skeleton(canvas, landmarks, color) -> None:
    if not landmarks:
        cv2.putText(canvas, "no landmarks in this frame", (30, CANVAS_H // 2),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 0, 255), 2, cv2.LINE_AA)
        return
    pts = [(int(p[0] * CANVAS_W), int(p[1] * CANVAS_H)) for p in landmarks]
    vis = [p[3] if len(p) > 3 else 1.0 for p in landmarks]
    for a, b in POSE_CONNECTIONS:
        if a < len(pts) and b < len(pts) and vis[a] > 0.4 and vis[b] > 0.4:
            cv2.line(canvas, pts[a], pts[b], color, 2, cv2.LINE_AA)
    for (x, y), v in zip(pts, vis):
        if v > 0.4:
            cv2.circle(canvas, (x, y), 3, (0, 140, 255), -1)


def _draw_timeline(canvas, labels, cur, in_pt, out_pt) -> None:
    n = len(labels)
    y0 = CANVAS_H - TIMELINE_H
    for x in range(CANVAS_W):
        idx = min(n - 1, int(x / CANVAS_W * n))
        cv2.line(canvas, (x, y0), (x, CANVAS_H),
                 LABEL_COLORS.get(labels[idx], (70, 70, 70)), 1)
    for pt, col in ((in_pt, (255, 255, 255)), (out_pt, (255, 255, 0))):
        if pt is not None:
            x = int(pt / max(1, n - 1) * (CANVAS_W - 1))
            cv2.line(canvas, (x, y0), (x, CANVAS_H), col, 2)
    cx = int(cur / max(1, n - 1) * (CANVAS_W - 1))
    cv2.line(canvas, (cx, y0 - 6), (cx, CANVAS_H), (0, 0, 255), 2)


def _draw_hud(canvas, frames, labels, cur, in_pt, out_pt, playing, saved_path) -> None:
    def line(text, y, color=(255, 255, 255), scale=0.6):
        cv2.putText(canvas, text, (12, y), cv2.FONT_HERSHEY_SIMPLEX, scale,
                    (0, 0, 0), 4, cv2.LINE_AA)
        cv2.putText(canvas, text, (12, y), cv2.FONT_HERSHEY_SIMPLEX, scale, color, 1, cv2.LINE_AA)

    n = len(frames)
    t = frames[cur].get("t", cur / 30.0)
    cur_label = labels[cur]
    line(f"frame {cur+1}/{n}   t={t:.2f}s   {'PLAY' if playing else 'PAUSE'}", 26)
    line(f"label here: {cur_label}", 50, LABEL_COLORS.get(cur_label, (255, 255, 255)))
    sel = f"IN {in_pt if in_pt is not None else '-'}  OUT {out_pt if out_pt is not None else '-'}"
    line(sel, 74)
    legend = "  ".join(f"{k}:{v}" for k, v in LABELS.items())
    line(legend, 98, (200, 200, 200), 0.5)
    line("SPACE play  a/d step  ,/. x10  i/o span  0-6 label  x clear  c desel  s save  ESC quit",
         CANVAS_H - TIMELINE_H - 12, (180, 220, 180), 0.5)
    if saved_path:
        line(f"saved -> {saved_path.name}", 122, (0, 220, 0))


# --- UI loop -----------------------------------------------------------------
# Arrow key codes returned by cv2.waitKeyEx on Windows.
_LEFT, _RIGHT = 2424832, 2555904


def run_ui(path: Path) -> None:
    frames = load_recording(path)
    if not frames:
        raise SystemExit(f"No frames in {path}")
    labels = initial_labels(frames)
    n = len(frames)

    ts = [f.get("t", i / 30.0) for i, f in enumerate(frames)]
    dts = [b - a for a, b in zip(ts, ts[1:]) if 0 < (b - a) < 1]
    frame_delay = int(1000 * (sorted(dts)[len(dts) // 2])) if dts else 33
    frame_delay = max(10, min(100, frame_delay))

    cur, in_pt, out_pt = 0, None, None
    playing = False
    saved_path: Optional[Path] = None

    print(f"Labelling {path.name}: {n} frames. Follow the on-screen controls; 's' to save.")
    win = "MotionFit Labeler"
    cv2.namedWindow(win)
    while True:
        frame = frames[cur]
        canvas = _blank()
        _draw_skeleton(canvas, frame.get("landmarks"),
                       LABEL_COLORS.get(labels[cur], (0, 220, 0)))
        _draw_timeline(canvas, labels, cur, in_pt, out_pt)
        _draw_hud(canvas, frames, labels, cur, in_pt, out_pt, playing, saved_path)
        cv2.imshow(win, canvas)

        key = cv2.waitKeyEx(frame_delay if playing else 20)
        if playing and key == -1:
            cur = min(n - 1, cur + 1)
            if cur == n - 1:
                playing = False
            continue
        if key == -1:
            continue
        saved_path = None  # clear the "saved" banner on any further edit
        low = key & 0xFF

        if low in (27, ord("q")):
            break
        elif low == ord(" "):
            playing = not playing
        elif low == ord("a") or key == _LEFT:
            cur = max(0, cur - 1)
        elif low == ord("d") or key == _RIGHT:
            cur = min(n - 1, cur + 1)
        elif low == ord(","):
            cur = max(0, cur - 10)
        elif low == ord("."):
            cur = min(n - 1, cur + 10)
        elif low == ord("i"):
            in_pt = cur
        elif low == ord("o"):
            out_pt = cur
        elif low == ord("c"):
            in_pt = out_pt = None
        elif low == ord("x"):
            lo, hi = span_bounds(in_pt, out_pt, cur, n)
            apply_label(labels, lo, hi, DEFAULT_LABEL)
        elif low == ord("s"):
            saved_path = save_labeled(frames, labels, output_path_for(path))
            counts = {k: v for k, v in label_counts(labels).items() if k != DEFAULT_LABEL}
            print(f"Saved {saved_path}  labelled: {counts}")
        elif 32 <= low < 127 and label_for_key(chr(low)) is not None:
            lo, hi = span_bounds(in_pt, out_pt, cur, n)
            apply_label(labels, lo, hi, label_for_key(chr(low)))

    cv2.destroyAllWindows()


def _blank():
    import numpy as np
    return np.zeros((CANVAS_H, CANVAS_W, 3), dtype=np.uint8)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("recording", help="A JSONL recording from pose_server.py --record.")
    args = parser.parse_args()
    path = Path(args.recording)
    if not path.exists():
        raise SystemExit(f"Recording not found: {path}")
    run_ui(path)


if __name__ == "__main__":
    main()
