"""Recording harness support for the MotionFit pose service.

This module is the labelled-data foundation for the accuracy phase (see
CONTEXT.md TODO): it lets `pose_server.py --record` log every frame -- the raw
landmark stream, the derived feature vector, and a move label -- to a JSONL file
that `train_classifier.py` later trains a generalisable move classifier on.

Kept deliberately dependency-light (standard library only, with an optional
`winsound` beep on Windows) so the offline trainer can import the feature schema
here WITHOUT pulling in OpenCV/MediaPipe. Both sides therefore agree on exactly
one feature layout -- change it in one place and both the logger and the trainer
follow.

Three pieces:
  * label config      -- which move each number key tags the current frames as.
  * `build_feature_row` / `FEATURE_NAMES` -- the flat feature vector schema
                         shared by the recorder and the trainer.
  * `Metronome`       -- an optional beat, so stepping can be paced to a known
                         tempo and cadence/intensity get a ground-truth label.
  * `Recorder`        -- writes one JSON object per frame to a JSONL file.
"""
from __future__ import annotations

import json
import threading
import time
from pathlib import Path
from typing import Any, Optional

try:  # optional audible metronome; only present on Windows
    import winsound  # type: ignore
    _HAS_WINSOUND = True
except ImportError:  # pragma: no cover - platform dependent
    _HAS_WINSOUND = False


# --- Move labels -------------------------------------------------------------
# While recording, press a number key to tag every following frame with that
# move, until you press another. These are the classes the move classifier
# learns. "unlabeled" frames (before you press anything) are dropped by the
# trainer, so you can set up your stance without polluting the data.
DEFAULT_LABEL = "unlabeled"
LABELS: dict[str, str] = {
    "0": "idle",           # standing still in frame
    "1": "march",          # marching in place, moderate knee lift
    "2": "high_knees",     # vigorous high-knee run in place
    "3": "jog",            # light jog in place
    "4": "jumping_jacks",  # jumping jacks (arms + legs)
    "5": "squat",          # repeated squats
    "6": "jump",           # repeated two-foot jumps
}


def label_for_key(key: str) -> Optional[str]:
    """Returns the move label bound to a keyboard character, or None."""
    return LABELS.get(key)


def label_legend() -> str:
    """One-line 'key=label' legend for the recording HUD."""
    return "  ".join(f"{k}:{v}" for k, v in LABELS.items())


# --- Feature schema (shared by recorder and trainer) -------------------------
# The order here IS the contract. `pose_server` logs a `features` dict per frame;
# `build_feature_row` flattens it into a fixed-length numeric vector in this
# order, and the trainer builds its matrix the same way. Everything is already
# body-local / torso-normalised upstream, so these features are camera- and
# distance-invariant, which is what lets a classifier generalise across players.
CHANNEL_ORDER = ("l_knee", "r_knee", "l_ankle", "r_ankle", "l_wrist", "r_wrist")
SCALAR_FEATURES = ("fused_speed", "leg_ext", "crouch", "duck", "forward", "turn",
                   "cadence")

FEATURE_NAMES: tuple[str, ...] = tuple(
    list(SCALAR_FEATURES)
    + [f"{ch}_{suffix}" for ch in CHANNEL_ORDER for suffix in ("value", "speed", "vis")]
)


def _num(value: Any) -> float:
    """Coerce to float, treating None/missing/NaN-ish as 0.0."""
    try:
        f = float(value)
    except (TypeError, ValueError):
        return 0.0
    return f if f == f else 0.0  # drop NaN


def build_feature_row(features: dict) -> list[float]:
    """Flattens a per-frame `features` dict into the FEATURE_NAMES vector.

    Missing scalars or channels become 0.0, so a frame where a joint was
    occluded still yields a well-formed, fixed-length row (with that channel's
    visibility at 0, which is itself a useful signal to the model).
    """
    row = [_num(features.get(name)) for name in SCALAR_FEATURES]
    channels = features.get("channels") or {}
    for ch in CHANNEL_ORDER:
        c = channels.get(ch) or {}
        row.append(_num(c.get("value")))
        row.append(_num(c.get("speed")))
        row.append(_num(c.get("vis")))
    return row


# --- Metronome ---------------------------------------------------------------
class Metronome:
    """A steady beat to pace stepping to a known tempo.

    Recording a march to, say, 120 bpm gives the cadence/intensity data a
    ground-truth tempo to be validated and regressed against -- the metronome
    beats are logged alongside each frame. The beep (Windows only) fires on a
    daemon thread so it never stalls the capture loop.
    """

    def __init__(self, bpm: float, beep: bool = True) -> None:
        self.bpm = float(bpm)
        self.period = 60.0 / self.bpm if self.bpm > 0 else 0.0
        self.beep_enabled = beep and _HAS_WINSOUND
        self._start: Optional[float] = None
        self.beat_index = -1

    def update(self, now: float) -> bool:
        """Advance to `now`; returns True on the frame a new beat lands."""
        if self.period <= 0.0:
            return False
        if self._start is None:
            self._start = now
        idx = int((now - self._start) / self.period)
        fired = idx > self.beat_index
        if fired:
            self.beat_index = idx
            if self.beep_enabled:
                threading.Thread(
                    target=winsound.Beep, args=(880, 40), daemon=True
                ).start()
        return fired

    def phase(self, now: float) -> float:
        """Position within the current beat, 0.0 (just beat) .. 1.0 (next)."""
        if self._start is None or self.period <= 0.0:
            return 0.0
        return ((now - self._start) % self.period) / self.period


# --- Recorder ----------------------------------------------------------------
DEFAULT_RECORDING_DIR = Path(__file__).resolve().parent / "recordings"


class Recorder:
    """Writes one JSON object per frame to a JSONL file.

    Each line captures enough to re-derive any future feature set offline: the
    raw normalized landmarks and world landmarks, the feature vector the server
    computed live, the emitted control values, the current move label, and (if
    running) the metronome beat. JSONL means a crash mid-session still leaves
    every already-written frame intact and readable.
    """

    def __init__(self, path: Optional[str] = None) -> None:
        if path:
            self.path = Path(path)
        else:
            stamp = time.strftime("%Y%m%d_%H%M%S")
            self.path = DEFAULT_RECORDING_DIR / f"rec_{stamp}.jsonl"
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._fh = open(self.path, "w", encoding="utf-8")
        self.frames = 0
        self._start: Optional[float] = None

    def write(
        self,
        *,
        ts: float,
        label: str,
        pose_ok: bool,
        detected: bool,
        packet: dict,
        landmarks: Optional[list],
        world: Optional[list],
        features: Optional[dict],
        metronome: Optional[Metronome] = None,
    ) -> None:
        if self._start is None:
            self._start = ts
        row: dict[str, Any] = {
            "ts": round(ts, 4),
            "t": round(ts - self._start, 4),
            "label": label,
            "pose_ok": pose_ok,
            "detected": detected,
            "forward": packet.get("forward"),
            "turn": packet.get("turn"),
            "jump": packet.get("jump"),
            "crouch": packet.get("crouch"),
            "duck": packet.get("duck"),
            "cadence": packet.get("cadence"),
            "met": packet.get("met"),
            "hr": packet.get("hr"),
            "landmarks": landmarks,
            "world": world,
            "features": features,
        }
        if metronome is not None:
            row["metronome_bpm"] = metronome.bpm
            row["beat_index"] = metronome.beat_index
            row["beat_phase"] = round(metronome.phase(ts), 3)
        self._fh.write(json.dumps(row) + "\n")
        self.frames += 1

    def close(self) -> None:
        if not self._fh.closed:
            self._fh.close()
