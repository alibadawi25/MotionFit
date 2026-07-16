"""Convert public exercise videos into MotionFit training data.

Lets you bootstrap the move classifier from datasets on the internet (e.g. the
Kaggle "Physical Exercise Recognition" set of jumping-jack / squat / etc. clips)
WITHOUT recording yourself. It runs each video through the EXACT same MediaPipe
model and feature pipeline the live server uses (`pose_server._compute_controls`),
so the features it writes are identical to what the game produces at runtime --
no train/serve skew -- and emits them as JSONL in the shared schema that
`train_classifier.py` already reads.

Input layout: one sub-folder per move, videos inside (the label is the folder
name). Nested folders are fine.

    exercises/
        jumping_jacks/  clip1.mp4  clip2.mp4 ...
        squat/          ...
        march/          ...

Run:
    python python/pose/video_to_features.py exercises/
    python python/pose/video_to_features.py exercises/ --out python/pose/recordings/public
    python python/pose/video_to_features.py exercises/ --gate --mirror --max-per-class 50

Then train on the result:
    python python/pose/train_classifier.py python/pose/recordings/public/

Note on scope: public sets cover jumping-jacks and squats well, but not the
in-place cardio (march / high-knees / jog) that's central to a cardio game --
record a little of those yourself (`pose_server.py --record` + `label_tool.py`)
and drop the JSONL into the same folder to train on everything together.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import cv2

# Import pose_server FIRST: it installs a meta-path hook that hides the (unused,
# ~14-25s) tensorflow package before mediapipe is imported, so `import mediapipe`
# stays ~1.5s here too. Importing mediapipe before pose_server would defeat it.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import pose_server as ps  # noqa: E402  reuse the live pipeline verbatim
import mediapipe as mp  # noqa: E402  (already cached fast by pose_server's import)
import recording  # noqa: E402

VIDEO_EXTS = {".mp4", ".mov", ".avi", ".mkv", ".webm", ".m4v"}


def find_videos(class_dir: Path) -> list[Path]:
    return sorted(p for p in class_dir.rglob("*") if p.suffix.lower() in VIDEO_EXTS)


def process_video(path: Path, label: str, landmarker, recorder: recording.Recorder,
                  args) -> tuple[int, int, int]:
    """Extract features from one clip. Returns (frames, detected, written).

    A fresh ControlState/filters per clip means the band-pass and 1-Euro filters
    start clean (a video isn't a continuation of the previous one); the first
    `--warmup` frames are dropped while those filters settle.
    """
    cap = cv2.VideoCapture(str(path))
    if not cap.isOpened():
        print(f"  ! could not open {path.name}")
        return 0, 0, 0
    fps = cap.get(cv2.CAP_PROP_FPS)
    if not fps or fps < 1.0:
        fps = float(args.fps_fallback)
    dt = 1.0 / fps

    state = ps.ControlState()
    forward_filter = ps.OneEuroFilter(ps.FORWARD_MIN_CUTOFF, ps.FORWARD_BETA)
    turn_filter = ps.OneEuroFilter(ps.TURN_MIN_CUTOFF, ps.TURN_BETA)
    steps = ps.StepCounter()

    idx = detected = written = 0
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        if args.mirror:
            frame = cv2.flip(frame, 1)  # match the live server's mirrored view
        rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        mp_image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
        now = idx * dt
        result = landmarker.detect_for_video(mp_image, int(now * 1000))
        idx += 1

        if not result.pose_landmarks:
            continue
        detected += 1
        lm = result.pose_landmarks[0]
        wlm = result.pose_world_landmarks[0] if result.pose_world_landmarks else None

        # The live server gates on a valid marching stance; for training data we
        # normally DON'T (a deep squat or jumping-jack would be rejected), unless
        # --gate is set. Features still need a valid torso frame, which
        # _compute_controls handles internally.
        if args.gate:
            ok_pose, _ = ps._assess_pose(lm)
            if not ok_pose:
                continue

        forward, turn, jumped, crouch = ps._compute_controls(
            lm, wlm, state, forward_filter, turn_filter, steps, now, dt
        )
        feats = state.feature_snapshot
        if not feats or idx <= args.warmup:
            continue
        packet = ps._build_packet(forward, turn, jumped, crouch, True,
                                  steps.steps, steps.cadence(now), 0.0, 0.0)
        recorder.write(
            ts=now, label=label, pose_ok=True, detected=True, packet=packet,
            landmarks=ps._landmarks_to_list(lm), world=ps._world_to_list(wlm),
            features=feats, metronome=None,
        )
        written += 1

    cap.release()
    return idx, detected, written


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("data_dir", help="Folder with one sub-folder per move (label).")
    parser.add_argument(
        "--out", default=str(Path(__file__).resolve().parent / "recordings" / "public"),
        help="Output folder for the per-label JSONL files.",
    )
    parser.add_argument("--gate", action="store_true",
                        help="Keep only frames that pass the live marching-stance check.")
    parser.add_argument("--mirror", action="store_true",
                        help="Mirror clips to match the live server's flipped webcam view.")
    parser.add_argument("--warmup", type=int, default=8,
                        help="Drop this many leading frames per clip (filter settling).")
    parser.add_argument("--fps-fallback", type=float, default=30.0,
                        help="FPS to assume when a video doesn't report one.")
    parser.add_argument("--max-per-class", type=int, default=0,
                        help="Cap videos processed per label (0 = all).")
    args = parser.parse_args()

    data_dir = Path(args.data_dir)
    if not data_dir.is_dir():
        raise SystemExit(f"Not a folder: {data_dir}")
    class_dirs = sorted(d for d in data_dir.iterdir() if d.is_dir())
    if not class_dirs:
        raise SystemExit(
            f"No label sub-folders in {data_dir}. Expected one folder per move, "
            "e.g. <data_dir>/squat/*.mp4"
        )
    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    if not ps.MODEL_PATH.exists():
        raise SystemExit(f"Pose model not found at {ps.MODEL_PATH} (see pose_server.py).")

    grand_written = 0
    for class_dir in class_dirs:
        label = class_dir.name
        videos = find_videos(class_dir)
        if args.max_per_class > 0:
            videos = videos[: args.max_per_class]
        if not videos:
            print(f"[{label}] no videos found, skipping")
            continue
        recorder = recording.Recorder(str(out_dir / f"{label}.jsonl"))
        cls_frames = cls_det = cls_written = 0
        print(f"[{label}] {len(videos)} video(s) -> {recorder.path.name}")
        for video in videos:
            # A fresh landmarker per clip keeps VIDEO-mode tracking from bleeding
            # across clips and its timestamps monotonic within the clip.
            per_clip = ps._create_landmarker()
            frames, det, written = process_video(video, label, per_clip, recorder, args)
            per_clip.close()
            cls_frames += frames
            cls_det += det
            cls_written += written
        recorder.close()
        grand_written += cls_written
        print(f"    {cls_frames} frames, {cls_det} with a pose, {cls_written} written")

    print(f"\nDone. {grand_written} labelled samples -> {out_dir}")
    print(f"Train with:  python {Path(__file__).parent.name}/train_classifier.py {out_dir}")


if __name__ == "__main__":
    main()
