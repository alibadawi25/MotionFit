"""Offline move classifier for MotionFit.

Trains and evaluates a first move classifier on the labelled recordings produced
by `pose_server.py --record` (see `recording.py`). This is the unlock for the
accuracy phase: a model that recognises the move you are doing (march vs.
high-knees vs. jumping-jacks vs. squat vs. jump) enables crisper in-game events
and per-move MET values, instead of the hand-tuned heuristics the live server
uses today. The heuristics stay as the fallback; this adds a learned layer on
top once enough data is recorded.

Design notes:
  * Features come from `recording.build_feature_row`, the SAME schema the server
    logs, so there is no train/serve skew. Everything is already torso-normalised
    and body-local, hence player- and camera-invariant.
  * Because moves are *periodic*, a single frame is ambiguous (the top of a march
    step looks like the top of a jump). So each sample is a short temporal
    WINDOW: the current frame's features plus the rolling mean and std over the
    preceding ~0.5 s. That captures rhythm and amplitude, which is what separates
    the moves. Windows are computed per-recording so they never cross files.
  * RandomForest: strong default for this size of tabular data, needs no feature
    scaling, and its class probabilities give a natural confidence for the live
    layer later.

Usage:
    python python/pose/train_classifier.py python/pose/recordings/*.jsonl
    python python/pose/train_classifier.py rec1.jsonl rec2.jsonl --out model.joblib
    python python/pose/train_classifier.py recordings/ --window 15 --test-size 0.25

Requires numpy + scikit-learn (+ joblib to save):
    pip install -r python/requirements-train.txt
"""
from __future__ import annotations

import argparse
import glob
import json
import sys
from pathlib import Path

# Import the shared feature schema. Works whether run as a module or a script.
try:
    from recording import DEFAULT_LABEL, FEATURE_NAMES, build_feature_row
except ImportError:  # pragma: no cover - script run from elsewhere
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from recording import DEFAULT_LABEL, FEATURE_NAMES, build_feature_row


def _require_deps():
    """Import numpy/sklearn with a friendly message if they're missing."""
    try:
        import numpy as np  # noqa: F401
        from sklearn.ensemble import RandomForestClassifier  # noqa: F401
    except ImportError as exc:
        raise SystemExit(
            f"Missing a training dependency ({exc.name}). Install them with:\n"
            "    pip install -r python/requirements-train.txt"
        )


def expand_inputs(inputs: list[str]) -> list[Path]:
    """Turn file/dir/glob arguments into a flat list of .jsonl paths."""
    paths: list[Path] = []
    for item in inputs:
        p = Path(item)
        if p.is_dir():
            paths.extend(sorted(p.glob("*.jsonl")))
        elif any(ch in item for ch in "*?[") and not p.exists():
            paths.extend(Path(m) for m in sorted(glob.glob(item)))
        else:
            paths.append(p)
    return [p for p in paths if p.suffix == ".jsonl" and p.exists()]


def load_frames(path: Path) -> list[dict]:
    """Read one JSONL recording into a list of frame dicts (bad lines skipped)."""
    frames: list[dict] = []
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                frames.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return frames


def windowed_samples(frames: list[dict], window: int):
    """Build (feature_rows, labels) for one recording's labelled frames.

    For frame i we emit the base feature vector concatenated with the rolling
    mean and std of the base features over frames (i-window, i]. Only frames that
    are pose-valid and carry a real (non-`unlabeled`) label become samples, but
    the rolling window is computed over the full contiguous stream so it still
    sees the run-up to each labelled frame.
    """
    import numpy as np

    base = np.array(
        [build_feature_row(f.get("features") or {}) for f in frames], dtype=float
    )
    rows, labels = [], []
    for i, frame in enumerate(frames):
        label = frame.get("label", DEFAULT_LABEL)
        if not frame.get("pose_ok") or label == DEFAULT_LABEL or label is None:
            continue
        lo = max(0, i - window + 1)
        chunk = base[lo : i + 1]
        feat = np.concatenate([base[i], chunk.mean(axis=0), chunk.std(axis=0)])
        rows.append(feat)
        labels.append(label)
    return rows, labels


def build_dataset(paths: list[Path], window: int):
    import numpy as np

    all_rows, all_labels = [], []
    for path in paths:
        frames = load_frames(path)
        rows, labels = windowed_samples(frames, window)
        all_rows.extend(rows)
        all_labels.extend(labels)
        print(f"  {path.name}: {len(frames)} frames -> {len(rows)} labelled samples")
    if not all_rows:
        raise SystemExit(
            "No labelled samples found. Record with 'pose_server.py --record' and "
            "press number keys (see the on-screen legend) to label your moves."
        )
    return np.array(all_rows, dtype=float), np.array(all_labels)


def windowed_feature_names(window: int) -> list[str]:
    """Names for the concatenated [current, mean, std] feature vector."""
    return (
        [f"{n}" for n in FEATURE_NAMES]
        + [f"{n}_mean{window}" for n in FEATURE_NAMES]
        + [f"{n}_std{window}" for n in FEATURE_NAMES]
    )


def train(paths: list[Path], window: int, test_size: float, out: Path, seed: int = 0):
    _require_deps()
    import numpy as np
    from sklearn.ensemble import RandomForestClassifier
    from sklearn.metrics import classification_report, confusion_matrix
    from sklearn.model_selection import train_test_split

    X, y = build_dataset(paths, window)
    classes, counts = np.unique(y, return_counts=True)
    print(f"\nDataset: {len(X)} samples, {len(classes)} classes")
    for cls, cnt in zip(classes, counts):
        print(f"  {cls:14s} {cnt}")
    if len(classes) < 2:
        raise SystemExit(
            "Need at least two distinct move labels to train a classifier "
            f"(got only '{classes[0]}'). Record more variety."
        )

    # Stratify so every class appears in both splits; fall back if a class is
    # too small to stratify.
    min_count = int(counts.min())
    stratify = y if min_count >= 2 else None
    X_tr, X_te, y_tr, y_te = train_test_split(
        X, y, test_size=test_size, random_state=seed, stratify=stratify
    )

    clf = RandomForestClassifier(
        n_estimators=200, max_depth=None, class_weight="balanced", random_state=seed, n_jobs=-1
    )
    clf.fit(X_tr, y_tr)

    acc = clf.score(X_te, y_te)
    print(f"\nHeld-out accuracy: {acc:.3f}  ({len(X_te)} test samples)")
    y_pred = clf.predict(X_te)
    print("\nClassification report:")
    print(classification_report(y_te, y_pred, zero_division=0))
    print("Confusion matrix (rows = true, cols = pred):")
    print("  labels:", list(clf.classes_))
    print(confusion_matrix(y_te, y_pred, labels=clf.classes_))

    # Top features, so the roadmap can see what actually drives the moves.
    names = windowed_feature_names(window)
    importances = sorted(zip(names, clf.feature_importances_), key=lambda t: -t[1])
    print("\nTop 10 features by importance:")
    for name, imp in importances[:10]:
        print(f"  {imp:.3f}  {name}")

    try:
        import joblib

        payload = {
            "model": clf,
            "window": window,
            "feature_names": names,
            "classes": list(clf.classes_),
            "held_out_accuracy": float(acc),
        }
        out.parent.mkdir(parents=True, exist_ok=True)
        joblib.dump(payload, out)
        print(f"\nSaved model -> {out}")
    except ImportError:
        print("\n(joblib not installed; skipped saving the model)")
    return acc


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "inputs", nargs="+",
        help="JSONL recording files, directories, or globs.",
    )
    parser.add_argument(
        "--out", default=str(Path(__file__).resolve().parent / "models" / "move_classifier.joblib"),
        help="Where to save the trained model.",
    )
    parser.add_argument(
        "--window", type=int, default=15,
        help="Frames of temporal context per sample (~0.5 s at 30 fps).",
    )
    parser.add_argument("--test-size", type=float, default=0.25, help="Held-out fraction.")
    parser.add_argument("--seed", type=int, default=0, help="Random seed.")
    args = parser.parse_args()

    paths = expand_inputs(args.inputs)
    if not paths:
        raise SystemExit(f"No .jsonl recordings matched: {args.inputs}")
    print(f"Training on {len(paths)} recording(s):")
    train(paths, args.window, args.test_size, Path(args.out), args.seed)


if __name__ == "__main__":
    main()
