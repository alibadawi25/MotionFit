"""MotionFit pose service.

Captures the webcam, runs MediaPipe Pose, and turns body movement into
control + fitness values that it streams to Godot over a local UDP socket:

    forward : 0.0 .. 1.0   how fast you are marching in place
    turn    : -1.0 .. 1.0  torso yaw (rotate your body to steer)
    jump    : bool         true on the frame you launch into a jump
    crouch  : 0.0 .. 1.0   how deep you are squatting (0 = upright)
    steps   : int          cumulative steps since the service started
    cadence : float        current pace in steps per minute

All computer-vision logic lives here (see CONTEXT.md: "Godot contains NO AI
logic"). Godot's MotionManager only receives the processed JSON packets.

Run:
    python python/pose/pose_server.py

Movement is read from several body channels at once -- both knees, both
ankles/feet, and both wrists -- measured in a body-local frame (relative to the
hip centre, along the hip->shoulder axis) and band-pass filtered to the stepping
frequency band, then fused with confidence weighting. That makes it robust to a
tilted/off-centre camera, to turning (which would otherwise be mistaken for
walking), to baggy trousers (the ankles carry the signal when the knees are
lost in fabric), and to per-joint noise (averaging cancels it).

A preview window shows the camera with the detected pose and current values.
Press 'q' (or Esc) in that window to stop. Stand back so your legs are in view;
showing your feet as well gives the cleanest, most accurate cadence.
"""
from __future__ import annotations

import argparse
import json
import math
import socket
import sys
import time
from collections import deque
from pathlib import Path

import cv2
import mediapipe as mp

import recording  # sibling module: JSONL recorder, metronome, label + feature schema

# --- Network -----------------------------------------------------------------
UDP_HOST = "127.0.0.1"
UDP_PORT = 9990  # must match MotionManager.PORT in Godot

# --- Camera ------------------------------------------------------------------
CAM_INDEX = 0

# --- Pose model ----------------------------------------------------------------
# This build of mediapipe (0.10.x on Windows/Python 3.12) ships only the newer
# Tasks API (mediapipe.tasks.vision.PoseLandmarker) -- the legacy
# mp.solutions.pose API used in older tutorials isn't bundled, so we drive
# pose detection through a downloaded model bundle instead.
MODEL_PATH = Path(__file__).resolve().parent / "models" / "pose_landmarker_full.task"

# --- Tuning (safe to tweak) --------------------------------------------------
# Forward (how fast you're moving) is fused from several body "channels" at once
# -- both knees, both ankles/feet, and both wrists -- instead of any single
# joint. Each channel is that joint's height ALONG THE BODY'S OWN spine axis,
# measured RELATIVE TO THE HIP CENTRE, which makes the reading:
#   * camera-angle invariant - "up" is the hip->shoulder axis, not the image's
#                              vertical, so a tilted or off-centre camera is fine;
#   * turn- and drift-proof  - relative to the hip, a turn or a sideways step
#                              (which move the hip too) cancels out, and a
#                              band-pass filter discards anything slower than a
#                              step (drift) or faster than one (jitter);
#   * baggy-trouser proof    - if the knees vanish into loose fabric, the ankles
#                              (visible below the hem) still carry the signal.
# The per-channel speeds are averaged with confidence weighting, so uncorrelated
# noise cancels (~sqrt of the channel count) and no single bad joint dominates.
FORWARD_THRESHOLD = 0.15  # fused channel speed below this counts as standing still
FORWARD_GAIN = 1.0        # scales the fused speed up toward 1.0
ARM_WEIGHT = 0.5          # wrists count for less than legs (arm swing is secondary)

# Band-pass = keep only motion in the stepping band, dropping slow drift
# (turning, re-aiming the camera, posture) and fast pixel jitter. Cutoffs in Hz;
# ~0.6-5 Hz spans a slow walk (~1.5 steps/s) up to a brisk jog.
BAND_SLOW_HZ = 0.6        # discard motion slower than this (drift / turning)
BAND_FAST_HZ = 5.0        # discard motion faster than this (jitter)

# Turn = torso yaw, from the depth (z) offset between the shoulders in metric
# world space -- i.e. actually rotating your body to steer, not leaning.
TURN_DEADZONE = 0.08     # yaw below this is ignored (no accidental turns)
TURN_GAIN = 2.2          # scales yaw into the -1..1 turn range
INVERT_TURN = False      # flip if turning your body steers the wrong way
MIN_VISIBILITY = 0.5     # ignore landmarks the model is unsure about

# --- Position validity -------------------------------------------------------
# Before measuring anything we check the person is actually set up to march --
# in frame, standing upright, legs visible below the hips. Otherwise (sitting,
# reclining, half out of frame) the pose estimate is unreliable and would emit
# junk, so we pause and show an on-screen instruction instead.
POSE_MAX_TILT = 40.0     # torso may lean at most this many degrees from vertical
POSE_MIN_LEG_DROP = 0.6  # the planted knee must sit this far below the hips
                         # (in torso lengths) -- i.e. standing, not sitting

# --- Jump & crouch -----------------------------------------------------------
# Jump: a vertical launch shows up as the hip springing above its recent resting
# height. We track a slow baseline of the hip height (a jump is far too brief to
# move it) and fire a one-frame event when the hip rises above that baseline
# fast enough -- edge-triggered and debounced, so one jump = one event. The
# gentle bob of marching in place stays well under the bar (it is small, and it
# dips as much as it rises), so a march never reads as a jump.
JUMP_RISE_MIN = 0.14      # hip must rise this far above baseline (torso fraction)
JUMP_SPEED_MIN = 1.2      # ...while travelling up at least this fast (torso/sec)
JUMP_MIN_INTERVAL = 0.45  # ignore jumps closer together than this (debounce, s)
JUMP_BASELINE_HZ = 0.5    # how fast the resting-height baseline adapts

# Crouch: squatting folds the legs, so the planted foot sits closer to the hip
# than when you stand tall. We measure hip-to-planted-foot distance along the
# body axis (torso-normalised) and compare it to a self-calibrating "standing"
# reference -- peak-followed, so it snaps up to your tallest recent stance and
# decays slowly, needing no setup pose. The PLANTED (lower) foot is used so a
# marching high-knee, which lifts the swing foot, is not mistaken for a crouch.
CROUCH_STAND_HZ = 0.05    # how slowly the standing reference drifts back down.
                          # Slow on purpose: leg_ext is already torso-normalised
                          # (so distance from the camera needs no re-calibration),
                          # and a slow drift lets a HELD squat keep registering
                          # instead of the reference chasing it down to zero.
CROUCH_START = 0.12       # leg-extension drop (torso fraction) where crouch begins
CROUCH_FULL = 0.45        # ...and where it reaches a full (1.0) crouch

# One Euro filter (Casiez et al.): adaptive smoothing that removes jitter when
# you hold a pose but stays responsive when you move quickly -- the standard for
# smooth interactive pose control. Higher beta = less lag; higher min_cutoff =
# less smoothing at low speed.
FORWARD_MIN_CUTOFF = 1.0
FORWARD_BETA = 0.7
TURN_MIN_CUTOFF = 1.2
TURN_BETA = 0.5

# --- Step counting -----------------------------------------------------------
# Steps come from the turning points of each leg's band-passed height, like a
# pedometer (and like the LLCM-WIP / marker-free-gait methods): one step per foot
# plant. Ankles are preferred (the cleanest heel-strike signal); knees are the
# fallback. If no leg is visible, cadence pauses rather than guessing.
STEP_SWING_MIN = 0.02     # min band-passed height swing (torso fraction) per step
STEP_MIN_INTERVAL = 0.20  # ignore steps closer than this (debounce, seconds)
STEP_FORWARD_GATE = 0.05  # only count steps while actually moving forward -- a
                          # slow waist turn drifts the legs enough to fake a
                          # foot plant, but it doesn't raise `forward`, so gating
                          # on forward motion rejects turning-in-place as steps
CADENCE_WINDOW_SEC = 5.0  # rolling window for the steps-per-minute estimate

# --- Effort (energy expenditure) ---------------------------------------------
# We emit a MET estimate (metabolic equivalent of task) computed from motion
# ALONE. MET is body-mass-normalised by definition, so Python -- which has no
# idea what the player weighs -- can own it cleanly, and Godot turns MET into
# calories using the player's weight from ProfileManager (kcal/min = MET * 3.5 *
# kg / 200). A heart-rate reading, when a wearable is present, fuses in on the
# Godot side later; until then this motion estimate is the fallback.
#
# The mapping below is a physiologically REASONABLE starting point (marching in
# place ~4-5 MET, high-knee / jumping work ~8+), NOT a validated one. Real
# accuracy needs calibrating it against a reference (heart rate, or ideally
# indirect calorimetry) -- that's a later phase, and needs the recording harness.
REST_MET = 1.2               # standing in frame but not moving
CADENCE_MET_SLOPE = 0.028    # +MET per step/min  (~100 spm -> ~4 MET, moderate)
FORWARD_MET_SPAN = 7.0       # forward 0..1 -> +0..7 MET (whole-body vigour)
JUMP_MET_PER_MIN = 0.12      # +MET per jump/min (plyometric burn, on top)
MET_MAX = 14.0               # clamp (sprint / burpee territory)
EFFORT_WINDOW_SEC = 5.0      # rolling window for the jump-rate term
EFFORT_SMOOTH_HZ = 0.4       # low-pass MET so the calorie counter reads steadily

# MediaPipe Pose landmark indices we use.
L_SHOULDER, R_SHOULDER = 11, 12
L_WRIST, R_WRIST = 15, 16
L_HIP, R_HIP = 23, 24
L_KNEE, R_KNEE = 25, 26
L_ANKLE, R_ANKLE = 27, 28

# Channels fused into `forward`: (name, landmark index, weight, is_leg).
FORWARD_CHANNELS = (
    ("l_knee", L_KNEE, 1.0, True),
    ("r_knee", R_KNEE, 1.0, True),
    ("l_ankle", L_ANKLE, 1.0, True),
    ("r_ankle", R_ANKLE, 1.0, True),
    ("l_wrist", L_WRIST, ARM_WEIGHT, False),
    ("r_wrist", R_WRIST, ARM_WEIGHT, False),
)


def _clamp(value: float, low: float, high: float) -> float:
    return max(low, min(high, value))


class _LowPass:
    """Exponential low-pass with an externally supplied smoothing factor."""

    def __init__(self) -> None:
        self._value: float | None = None

    def __call__(self, x: float, alpha: float) -> float:
        if self._value is None:
            self._value = x
        else:
            self._value = alpha * x + (1.0 - alpha) * self._value
        return self._value

    def reset(self) -> None:
        self._value = None


class _BandPass:
    """Band-pass = fast low-pass minus slow low-pass, isolating the step band.

    Subtracting a slow low-pass removes drift (turning, re-aiming the camera,
    posture); the fast low-pass removes pixel jitter. What survives is the
    periodic stepping motion, which is what we actually want to measure.
    """

    def __init__(self, slow_hz: float, fast_hz: float) -> None:
        self._slow = _LowPass()
        self._fast = _LowPass()
        self._slow_hz = slow_hz
        self._fast_hz = fast_hz

    @staticmethod
    def _alpha(cutoff: float, dt: float) -> float:
        tau = 1.0 / (2.0 * math.pi * cutoff)
        return 1.0 / (1.0 + tau / dt)

    def __call__(self, x: float, dt: float) -> float:
        if dt <= 0.0:
            dt = 1.0 / 30.0
        fast = self._fast(x, self._alpha(self._fast_hz, dt))
        slow = self._slow(x, self._alpha(self._slow_hz, dt))
        return fast - slow

    def reset(self) -> None:
        self._slow.reset()
        self._fast.reset()


class OneEuroFilter:
    """1-Euro filter: low lag AND low jitter for interactive signals.

    At low speeds the cutoff frequency drops so noise is smoothed away; as the
    signal speeds up the cutoff rises so the output tracks it with little lag.
    """

    def __init__(self, min_cutoff: float, beta: float, d_cutoff: float = 1.0) -> None:
        self._min_cutoff = min_cutoff
        self._beta = beta
        self._d_cutoff = d_cutoff
        self._x = _LowPass()
        self._dx = _LowPass()
        self._prev: float | None = None

    @staticmethod
    def _alpha(cutoff: float, dt: float) -> float:
        tau = 1.0 / (2.0 * math.pi * cutoff)
        return 1.0 / (1.0 + tau / dt)

    def __call__(self, x: float, dt: float) -> float:
        if dt <= 0.0:
            return x
        dx = 0.0 if self._prev is None else (x - self._prev) / dt
        dx_hat = self._dx(dx, self._alpha(self._d_cutoff, dt))
        cutoff = self._min_cutoff + self._beta * abs(dx_hat)
        x_hat = self._x(x, self._alpha(cutoff, dt))
        self._prev = x
        return x_hat

    def reset(self) -> None:
        self._x.reset()
        self._dx.reset()
        self._prev = None


class _Oscillator:
    """One fused body channel: band-passes a joint's height and reports motion.

    `speed` is the |rate of change| of the band-passed height (per second),
    which feeds the fused forward signal. `update` returns True on a *footfall*
    -- a downward turning point (foot plant) whose swing clears STEP_SWING_MIN --
    which feeds the step counter. Debouncing is left to the caller.
    """

    def __init__(self) -> None:
        self._bp = _BandPass(BAND_SLOW_HZ, BAND_FAST_HZ)
        self._prev: float | None = None          # previous band-passed value
        self._last_extreme: float | None = None  # value at the last turning point
        self._descending: bool | None = None     # True while the height is dropping
        self.value = 0.0
        self.speed = 0.0

    def update(self, height: float, dt: float) -> bool:
        v = self._bp(height, dt)
        self.value = v
        footfall = False
        if self._prev is not None and dt > 0.0:
            self.speed = abs(v - self._prev) / dt
            descending = v < self._prev  # height dropping = the foot coming down
            if self._descending is None:
                self._descending = descending
                self._last_extreme = self._prev
            elif descending != self._descending:
                base = self._prev if self._last_extreme is None else self._last_extreme
                swing = abs(self._prev - base)
                # A trough (were dropping, now rising) is a foot plant = one step.
                if self._descending and swing >= STEP_SWING_MIN:
                    footfall = True
                self._last_extreme = self._prev
                self._descending = descending
        self._prev = v
        return footfall

    def reset(self) -> None:
        self._bp.reset()
        self._prev = None
        self._last_extreme = None
        self._descending = None
        self.value = 0.0
        self.speed = 0.0


class _VerticalMotion:
    """Detects jumps (edge events) and crouches (continuous) from body height.

    Both are measured in torso-length units, so they don't care how far you
    stand from the camera, and both run against self-calibrating baselines, so
    there's no setup pose. `update` returns True on the single frame a jump
    launches; `crouch` holds the current squat depth, 0.0 (upright) .. 1.0.
    """

    def __init__(self) -> None:
        self._rest = _LowPass()                # slow baseline of hip height (up+)
        self._prev_hip_up: float | None = None
        self._stand_ext: float | None = None   # peak-followed standing leg extension
        self.crouch = 0.0
        self.last_jump_time = -1000.0

    def update(self, hip_up: float, leg_ext: float, torso_len: float,
               dt: float, now: float) -> bool:
        """hip_up: hip-centre height, up = positive, in normalized image units.
        leg_ext: hip-to-planted-foot distance along the body axis, torso-normalised.
        Returns True on the frame a jump launches."""
        if dt <= 0.0 or torso_len < 1e-3:
            return False

        # --- Jump: hip springs above its slow resting baseline ----------------
        rest = self._rest(hip_up, _BandPass._alpha(JUMP_BASELINE_HZ, dt))
        rise = (hip_up - rest) / torso_len
        up_speed = 0.0
        if self._prev_hip_up is not None:
            up_speed = (hip_up - self._prev_hip_up) / dt / torso_len
        self._prev_hip_up = hip_up
        jumped = (
            rise > JUMP_RISE_MIN
            and up_speed > JUMP_SPEED_MIN
            and now - self.last_jump_time >= JUMP_MIN_INTERVAL
        )
        if jumped:
            self.last_jump_time = now

        # --- Crouch: legs fold below the standing reference -------------------
        if self._stand_ext is None or leg_ext > self._stand_ext:
            self._stand_ext = leg_ext  # snap straight up to a taller stance
        else:
            self._stand_ext += _BandPass._alpha(CROUCH_STAND_HZ, dt) * (
                leg_ext - self._stand_ext
            )  # ...but sink back only slowly, so a squat still reads as a drop
        drop = self._stand_ext - leg_ext
        self.crouch = _clamp(
            (drop - CROUCH_START) / (CROUCH_FULL - CROUCH_START), 0.0, 1.0
        )
        return jumped

    def reset(self) -> None:
        self._rest.reset()
        self._prev_hip_up = None
        self._stand_ext = None
        self.crouch = 0.0


class ControlState:
    """Per-frame carry-over: one oscillator per fused body channel."""

    def __init__(self) -> None:
        self.osc = {name: _Oscillator() for name, *_ in FORWARD_CHANNELS}
        self.vertical = _VerticalMotion()  # jump/crouch from hip & leg height
        self.active_label = "none"  # which channel groups are tracking, for the HUD
        # Snapshot of this frame's features for the recording harness (empty when
        # not recording / no valid pose). Populated by _compute_controls.
        self.feature_snapshot: dict = {}

    def reset(self) -> None:
        for osc in self.osc.values():
            osc.reset()
        self.vertical.reset()
        self.active_label = "none"
        self.feature_snapshot = {}


class StepCounter:
    """Tallies steps and derives a live cadence (steps per minute)."""

    def __init__(self) -> None:
        self.steps = 0
        self.last_step_time = -1000.0
        self._times: deque[float] = deque()  # recent step timestamps

    def add(self, now: float) -> None:
        self.steps += 1
        self.last_step_time = now
        self._times.append(now)

    def cadence(self, now: float) -> float:
        """Steps per minute over the last CADENCE_WINDOW_SEC."""
        cutoff = now - CADENCE_WINDOW_SEC
        while self._times and self._times[0] < cutoff:
            self._times.popleft()
        return len(self._times) * (60.0 / CADENCE_WINDOW_SEC)


class _EffortEstimator:
    """Estimates instantaneous effort as a MET value, from motion alone.

    MET (metabolic equivalent) is normalised by body mass, so no player profile
    is needed here -- Godot multiplies by the player's weight to get calories.
    Effort is taken as the strongest of two intensity reads (stepping cadence
    and overall marching vigour) plus a bonus for jump activity, then smoothed so
    the calorie counter doesn't flicker. Constants are reasoned starting points
    that want calibration against a reference -- see the module-level notes.
    """

    def __init__(self) -> None:
        self._jumps: deque[float] = deque()  # recent jump timestamps
        self._smooth = _LowPass()
        self.met = REST_MET

    def update(self, forward: float, cadence: float, jumped: bool,
               now: float, dt: float) -> float:
        if jumped:
            self._jumps.append(now)
        cutoff = now - EFFORT_WINDOW_SEC
        while self._jumps and self._jumps[0] < cutoff:
            self._jumps.popleft()
        jumps_per_min = len(self._jumps) * (60.0 / EFFORT_WINDOW_SEC)

        # Cadence and forward are two windows on the same effort; take whichever
        # reads higher (arm-only work lifts forward but not cadence, and vice
        # versa), then add the jump term on top as it is extra vertical work.
        met_cadence = REST_MET + CADENCE_MET_SLOPE * cadence
        met_forward = REST_MET + FORWARD_MET_SPAN * forward
        raw = max(met_cadence, met_forward) + JUMP_MET_PER_MIN * jumps_per_min
        raw = _clamp(raw, REST_MET, MET_MAX)
        self.met = self._smooth(raw, _BandPass._alpha(EFFORT_SMOOTH_HZ, dt))
        return self.met

    def reset(self) -> None:
        self._jumps.clear()
        self._smooth.reset()
        self.met = REST_MET


def _create_landmarker():
    """Builds the MediaPipe PoseLandmarker (VIDEO mode). Shared by the live
    service and the offline video_to_features converter, so both extract
    landmarks identically."""
    if not MODEL_PATH.exists():
        raise SystemExit(
            f"Pose model not found at {MODEL_PATH}. Download pose_landmarker_full.task "
            "from https://storage.googleapis.com/mediapipe-models/pose_landmarker/"
            "pose_landmarker_full/float16/latest/pose_landmarker_full.task"
        )
    return mp.tasks.vision.PoseLandmarker.create_from_options(
        mp.tasks.vision.PoseLandmarkerOptions(
            base_options=mp.tasks.BaseOptions(model_asset_path=str(MODEL_PATH)),
            running_mode=mp.tasks.vision.RunningMode.VIDEO,
            num_poses=1,
            min_pose_detection_confidence=0.5,
            min_tracking_confidence=0.5,
        )
    )


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="MotionFit pose service: webcam -> movement/effort over UDP.",
    )
    parser.add_argument(
        "--camera", type=int, default=CAM_INDEX, metavar="INDEX",
        help=f"Webcam index (default {CAM_INDEX}).",
    )
    parser.add_argument(
        "--record", nargs="?", const="__auto__", default=None, metavar="PATH",
        help="Record a labelled JSONL dataset for training (see train_classifier.py). "
             "Optional PATH; defaults to an auto-named file under python/pose/recordings/. "
             "Press number keys while recording to label your moves.",
    )
    parser.add_argument(
        "--metronome", type=float, default=0.0, metavar="BPM",
        help="Pace stepping to a metronome at BPM (gives recordings a ground-truth "
             "tempo). Off by default.",
    )
    parser.add_argument(
        "--no-beep", action="store_true",
        help="Metronome shows a visual beat only, without the audible tick.",
    )
    parser.add_argument(
        "--heart-rate", action="store_true",
        help="Read heart rate from a BLE monitor (standard GATT HRS) and send it in "
             "the packet's hr field. Requires bleak (python/requirements-hr.txt).",
    )
    parser.add_argument(
        "--hr-address", default=None, metavar="ADDR",
        help="BLE address/UUID of the heart-rate monitor (else auto-picks the first).",
    )
    return parser.parse_args()


def main(args: argparse.Namespace | None = None) -> None:
    if args is None:
        args = _parse_args()
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    dest = (UDP_HOST, UDP_PORT)

    cap = cv2.VideoCapture(args.camera)
    if not cap.isOpened():
        raise SystemExit(
            f"Could not open camera index {args.camera}. "
            "Close other apps using the webcam, or pass --camera with another index."
        )

    landmarker = _create_landmarker()

    forward_filter = OneEuroFilter(FORWARD_MIN_CUTOFF, FORWARD_BETA)
    turn_filter = OneEuroFilter(TURN_MIN_CUTOFF, TURN_BETA)
    state = ControlState()
    steps = StepCounter()
    effort = _EffortEstimator()
    forward = 0.0
    turn = 0.0
    crouch = 0.0
    met = 0.0
    start_time = time.time()
    prev_ts = 0.0

    # --- Optional recording / metronome / heart-rate ---------------------------
    recorder = None
    if args.record is not None:
        path = None if args.record == "__auto__" else args.record
        recorder = recording.Recorder(path)
        print(f"Recording -> {recorder.path}")
        print(f"  Press a number key to label the current move: {recording.label_legend()}")
    metronome = None
    if args.metronome > 0:
        metronome = recording.Metronome(args.metronome, beep=not args.no_beep)
        print(f"Metronome: {args.metronome:.0f} bpm"
              f"{'' if metronome.beep_enabled else ' (visual only)'}")
    hr_monitor = _start_heart_rate(args) if args.heart_rate else None
    current_label = recording.DEFAULT_LABEL

    print(f"MotionFit pose service -> udp://{UDP_HOST}:{UDP_PORT}. Press 'q' to quit.")
    try:
        while True:
            ok, frame = cap.read()
            if not ok:
                continue
            frame = cv2.flip(frame, 1)  # mirror, so screen matches your movements
            rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            mp_image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
            now = time.time()
            dt = (now - prev_ts) if prev_ts else (1.0 / 30.0)
            prev_ts = now
            timestamp_ms = int((now - start_time) * 1000)
            result = landmarker.detect_for_video(mp_image, timestamp_ms)

            detected = bool(result.pose_landmarks)
            pose_ok = False
            jumped = False
            lm = None
            wlm = None
            if detected:
                lm = result.pose_landmarks[0]
                wlm = result.pose_world_landmarks[0] if result.pose_world_landmarks else None
                _draw_pose(frame, lm)
                pose_ok, pose_msg = _assess_pose(lm)
                if pose_ok:
                    forward, turn, jumped, crouch = _compute_controls(
                        lm, wlm, state, forward_filter, turn_filter, steps, now, dt
                    )
                    status_text, status_color = "TRACKING", (0, 220, 0)
                else:
                    # Seen, but not in a valid position: pause measurement and
                    # tell the user how to fix their stance.
                    forward *= 0.5
                    turn *= 0.5
                    crouch *= 0.5
                    state.reset()
                    forward_filter.reset()
                    turn_filter.reset()
                    status_text, status_color = pose_msg, (0, 200, 255)  # amber
            else:
                # No body in frame: decay to neutral so the character stops.
                forward *= 0.5
                turn *= 0.5
                crouch *= 0.5
                state.reset()
                forward_filter.reset()
                turn_filter.reset()
                status_text, status_color = "NO BODY - step back into view", (60, 60, 255)

            cadence = steps.cadence(now)
            if pose_ok:
                met = effort.update(forward, cadence, jumped, now, dt)
            else:
                # Not measuring: emit no effort so Godot banks no phantom calories.
                effort.reset()
                met = 0.0
            beat_now = metronome.update(now) if metronome is not None else False
            # Heart rate comes from a BLE wearable when --heart-rate is on; 0 means
            # no reading, and Godot then falls back to the motion-based estimate.
            hr = hr_monitor.current_bpm() if hr_monitor is not None else 0.0
            packet = _build_packet(forward, turn, jumped, crouch,
                                   detected and pose_ok, steps.steps, cadence, met, hr)
            _send(sock, dest, packet)
            _draw_hud(frame, forward, turn, jumped, crouch, status_text,
                      status_color, steps.steps, cadence, met, state.active_label)
            if recorder is not None:
                _draw_recording_overlay(frame, recorder, current_label,
                                        metronome, beat_now, hr_monitor)
                if detected:
                    recorder.write(
                        ts=now, label=current_label, pose_ok=pose_ok, detected=detected,
                        packet=packet, landmarks=_landmarks_to_list(lm),
                        world=_world_to_list(wlm),
                        features=(state.feature_snapshot if pose_ok else None),
                        metronome=metronome,
                    )

            cv2.imshow("MotionFit Pose (press q to quit)", frame)
            key = cv2.waitKey(1) & 0xFF
            if key in (ord("q"), 27):
                break
            if 32 <= key < 127:  # a printable key: maybe a move label
                new_label = recording.label_for_key(chr(key))
                if new_label is not None:
                    current_label = new_label
    finally:
        # stop the character and zero the effort so no calories accrue after exit
        _send(sock, dest, _build_packet(0.0, 0.0, False, 0.0, False, steps.steps, 0.0, 0.0, 0.0))
        if recorder is not None:
            recorder.close()
            print(f"Recording saved: {recorder.path} ({recorder.frames} frames)")
        if hr_monitor is not None:
            hr_monitor.stop()
        cap.release()
        landmarker.close()
        cv2.destroyAllWindows()
        sock.close()


def _assess_pose(lm) -> tuple[bool, str]:
    """Is the person in a valid standing position to measure from?

    Returns (ok, message); when not ok the message is a short on-screen
    instruction. Gating on this stops the tracker from emitting junk forward/step
    values when the user is out of frame, sitting, reclining, or otherwise not
    set up to march in place.
    """
    core = (L_SHOULDER, R_SHOULDER, L_HIP, R_HIP)
    if any((lm[i].visibility or 0.0) < MIN_VISIBILITY for i in core):
        return False, "STEP INTO VIEW"
    if (lm[L_KNEE].visibility or 0.0) < MIN_VISIBILITY or \
       (lm[R_KNEE].visibility or 0.0) < MIN_VISIBILITY:
        return False, "SHOW YOUR LEGS"

    hip_cx = (lm[L_HIP].x + lm[R_HIP].x) * 0.5
    hip_cy = (lm[L_HIP].y + lm[R_HIP].y) * 0.5
    sh_cx = (lm[L_SHOULDER].x + lm[R_SHOULDER].x) * 0.5
    sh_cy = (lm[L_SHOULDER].y + lm[R_SHOULDER].y) * 0.5
    dx, dy = sh_cx - hip_cx, sh_cy - hip_cy
    torso_len = math.hypot(dx, dy)
    if torso_len < 1e-3:
        return False, "STEP INTO VIEW"

    # Shoulders must sit above the hips and the torso be roughly vertical.
    if dy >= 0 or math.degrees(math.atan2(abs(dx), abs(dy))) > POSE_MAX_TILT:
        return False, "STAND UPRIGHT"
    # The more-planted knee must hang well below the hips -- i.e. standing, not
    # sitting or reclining with the legs stretched out toward the camera. Using
    # the lower (planted) knee keeps this valid even at the top of a high march.
    planted_knee_y = max(lm[L_KNEE].y, lm[R_KNEE].y)
    if (planted_knee_y - hip_cy) / torso_len < POSE_MIN_LEG_DROP:
        return False, "STAND UP"
    return True, "TRACKING"


def _compute_controls(
    lm, wlm, state: ControlState, forward_filter: OneEuroFilter,
    turn_filter: OneEuroFilter, steps: StepCounter, now: float, dt: float,
) -> tuple[float, float, bool, float]:
    """Returns (forward, turn, jumped, crouch) from pose landmarks.

    forward: confidence-weighted average of several body channels' band-passed
             speeds (both knees, both ankles, both wrists), each measured in a
             body-local frame relative to the hip. Averaging cancels per-joint
             noise; the body frame + band-pass reject camera tilt and turning.
    turn:    torso yaw from the shoulders' depth offset in metric world space --
             actually rotating your body to steer, robust to camera distance.
    jumped:  True on the frame a vertical launch is detected (an edge event).
    crouch:  squat depth 0.0 (upright) .. 1.0, from how far the planted foot has
             folded up toward the hip.
    forward and turn are passed through a 1-Euro filter for smooth, low-lag output.
    """
    # --- Body-local frame: origin at the hip centre, "up" is hip -> shoulder ---
    hip_cx = (lm[L_HIP].x + lm[R_HIP].x) * 0.5
    hip_cy = (lm[L_HIP].y + lm[R_HIP].y) * 0.5
    sh_cx = (lm[L_SHOULDER].x + lm[R_SHOULDER].x) * 0.5
    sh_cy = (lm[L_SHOULDER].y + lm[R_SHOULDER].y) * 0.5
    up_x, up_y = sh_cx - hip_cx, sh_cy - hip_cy
    torso_len = math.hypot(up_x, up_y)
    if torso_len < 1e-3:
        # Degenerate pose -- can't build a body frame; coast toward neutral.
        forward = _clamp(forward_filter(0.0, dt), 0.0, 1.0)
        turn = _clamp(turn_filter(0.0, dt), -1.0, 1.0)
        state.feature_snapshot = {}
        return forward, turn, False, state.vertical.crouch
    up_x /= torso_len
    up_y /= torso_len

    def channel_height(idx: int) -> float:
        # Joint offset from the hip, projected onto the spine axis, torso-normalised.
        return ((lm[idx].x - hip_cx) * up_x + (lm[idx].y - hip_cy) * up_y) / torso_len

    # --- Forward: confidence-weighted average of visible channel speeds --------
    num = den = 0.0
    footfalls: dict[str, bool] = {}
    visible: dict[str, bool] = {}
    channels_snapshot: dict[str, dict] = {}
    for name, idx, weight, _is_leg in FORWARD_CHANNELS:
        osc = state.osc[name]
        vis = lm[idx].visibility or 0.0
        if vis < MIN_VISIBILITY:
            osc.reset()
            visible[name] = False
            footfalls[name] = False
            channels_snapshot[name] = {"value": 0.0, "speed": 0.0, "vis": round(vis, 3)}
            continue
        footfalls[name] = osc.update(channel_height(idx), dt)
        visible[name] = True
        w = weight * vis
        num += w * osc.speed
        den += w
        channels_snapshot[name] = {
            "value": round(osc.value, 4),
            "speed": round(osc.speed, 4),
            "vis": round(vis, 3),
        }
    fused_speed = (num / den) if den > 0.0 else 0.0
    target_forward = 0.0
    if fused_speed > FORWARD_THRESHOLD:
        target_forward = _clamp((fused_speed - FORWARD_THRESHOLD) * FORWARD_GAIN, 0.0, 1.0)
    forward = _clamp(forward_filter(target_forward, dt), 0.0, 1.0)

    # --- Steps: one per foot plant, ankle preferred, knees as fallback ---------
    # Only while actually moving forward -- otherwise a waist turn or fidget that
    # nudges the (often poorly tracked) legs would be miscounted as steps.
    if forward > STEP_FORWARD_GATE:
        for side in ("l", "r"):
            if visible.get(f"{side}_ankle"):
                rep = f"{side}_ankle"
            elif visible.get(f"{side}_knee"):
                rep = f"{side}_knee"
            else:
                continue
            if footfalls.get(rep) and now - steps.last_step_time >= STEP_MIN_INTERVAL:
                steps.add(now)

    legs = any(visible.get(n) for n in ("l_ankle", "r_ankle", "l_knee", "r_knee"))
    arms = visible.get("l_wrist") or visible.get("r_wrist")
    state.active_label = " + ".join(
        p for p in (("legs" if legs else ""), ("arms" if arms else "")) if p
    ) or "none"

    # --- Jump & crouch: from hip height and the planted foot -------------------
    # The planted (lower on screen = larger y) foot defines standing height; use
    # ankles when visible, else knees. hip_up is negated because image y grows
    # downward, so up is negative.
    if visible.get("l_ankle") and visible.get("r_ankle"):
        foot_y = max(lm[L_ANKLE].y, lm[R_ANKLE].y)
    else:
        foot_y = max(lm[L_KNEE].y, lm[R_KNEE].y)
    leg_ext = (foot_y - hip_cy) / torso_len
    jumped = state.vertical.update(-hip_cy, leg_ext, torso_len, dt, now)
    crouch = state.vertical.crouch

    # --- Turn: shoulder depth offset = body yaw (world landmarks are metric) --
    target_turn = 0.0
    if wlm is not None:
        ls, rs = wlm[L_SHOULDER], wlm[R_SHOULDER]
        span = math.sqrt((ls.x - rs.x) ** 2 + (ls.y - rs.y) ** 2 + (ls.z - rs.z) ** 2)
        if span > 1e-3:
            yaw = (rs.z - ls.z) / span  # ~sin(rotation); sign = which way you face
            if INVERT_TURN:
                yaw = -yaw
            if abs(yaw) >= TURN_DEADZONE:
                signed = yaw - TURN_DEADZONE if yaw > 0 else yaw + TURN_DEADZONE
                target_turn = _clamp(signed * TURN_GAIN, -1.0, 1.0)
    turn = _clamp(turn_filter(target_turn, dt), -1.0, 1.0)

    # --- Feature snapshot for the recording harness ---------------------------
    # A flat, model-ready view of this frame's motion (see recording.py's
    # FEATURE_NAMES). Empty when not recording costs nothing; here it's cheap.
    state.feature_snapshot = {
        "fused_speed": round(fused_speed, 4),
        "leg_ext": round(leg_ext, 4),
        "crouch": round(crouch, 4),
        "forward": round(forward, 4),
        "turn": round(turn, 4),
        "cadence": round(steps.cadence(now), 2),
        "channels": channels_snapshot,
    }

    return forward, turn, jumped, crouch


def _build_packet(forward: float, turn: float, jump: bool, crouch: float,
                  detected: bool, steps: int, cadence: float,
                  met: float, hr: float) -> dict:
    """Assembles the Godot-bound packet (CONTEXT.md §9 schema)."""
    return {
        "forward": round(forward, 3),
        "turn": round(turn, 3),
        "jump": jump,
        "crouch": round(crouch, 3),
        "walking": forward > 0.05,
        "detected": detected,
        "steps": steps,
        "cadence": round(cadence, 1),
        "met": round(met, 2),   # body-mass-independent effort; Godot -> calories
        "hr": round(hr, 1),     # heart rate bpm, 0 = no reading (motion fallback)
        "ts": time.time(),
    }


def _send(sock: socket.socket, dest, packet: dict) -> None:
    sock.sendto(json.dumps(packet).encode("utf-8"), dest)


def _start_heart_rate(args: argparse.Namespace):
    """Lazily start the optional BLE heart-rate monitor; None on any failure."""
    hr_dir = Path(__file__).resolve().parent.parent / "heart_rate"
    if str(hr_dir) not in sys.path:
        sys.path.insert(0, str(hr_dir))
    try:
        from ble_heart_rate import HeartRateMonitor
    except ImportError as exc:
        print(f"Heart-rate disabled ({exc}). Install python/requirements-hr.txt for BLE.")
        return None
    monitor = HeartRateMonitor(address=args.hr_address)
    monitor.start()
    print("Heart-rate monitor starting (BLE, standard GATT HRS)...")
    return monitor


def _landmarks_to_list(lm) -> list:
    """Normalized landmarks -> compact [[x, y, z, visibility], ...] for JSONL."""
    return [
        [round(p.x, 5), round(p.y, 5), round(p.z, 5), round(p.visibility or 0.0, 4)]
        for p in lm
    ]


def _world_to_list(wlm) -> list | None:
    """Metric world landmarks -> [[x, y, z], ...], or None if unavailable."""
    if wlm is None:
        return None
    return [[round(p.x, 5), round(p.y, 5), round(p.z, 5)] for p in wlm]


def _draw_pose(frame, lm) -> None:
    """Draws the skeleton manually since this mediapipe build has no drawing_utils."""
    h, w = frame.shape[:2]
    for connection in mp.tasks.vision.PoseLandmarksConnections.POSE_LANDMARKS:
        start, end = lm[connection.start], lm[connection.end]
        if (start.visibility or 0.0) < MIN_VISIBILITY or (end.visibility or 0.0) < MIN_VISIBILITY:
            continue
        cv2.line(
            frame,
            (int(start.x * w), int(start.y * h)),
            (int(end.x * w), int(end.y * h)),
            (0, 220, 0),
            2,
        )
    for point in lm:
        if (point.visibility or 0.0) < MIN_VISIBILITY:
            continue
        cv2.circle(frame, (int(point.x * w), int(point.y * h)), 3, (0, 140, 255), -1)


def _put_label(frame, text: str, org, scale: float, color) -> None:
    """Draws text with a dark outline so it stays legible on any background.

    A thick black stroke is drawn first, then the coloured text on top -- this
    keeps the HUD readable over bright or white areas of the camera image, where
    plain white text would otherwise wash out and disappear.
    """
    font = cv2.FONT_HERSHEY_SIMPLEX
    cv2.putText(frame, text, org, font, scale, (0, 0, 0), 4, cv2.LINE_AA)
    cv2.putText(frame, text, org, font, scale, color, 2, cv2.LINE_AA)


def _draw_hud(frame, forward: float, turn: float, jump: bool, crouch: float,
              status_text: str, status_color, steps: int, cadence: float,
              met: float, sources: str = "none") -> None:
    # A translucent dark panel behind the text gives the labels a consistent
    # backdrop, so they read cleanly even when the camera is pointed at a bright
    # window or a white wall.
    panel = frame.copy()
    cv2.rectangle(panel, (6, 8), (360, 234), (0, 0, 0), -1)
    cv2.addWeighted(panel, 0.4, frame, 0.6, 0, frame)

    _put_label(frame, status_text, (12, 28), 0.62, status_color)
    _put_label(frame, f"forward {forward:.2f}", (12, 56), 0.6, (255, 255, 255))
    _put_label(frame, f"turn    {turn:+.2f}", (12, 80), 0.6, (255, 255, 255))
    # Jump flashes green on its launch frame; crouch bar fills as you squat.
    jump_color = (0, 220, 0) if jump else (255, 255, 255)
    _put_label(frame, f"jump    {'YES' if jump else '-'}", (12, 104), 0.6, jump_color)
    crouch_color = (0, 200, 255) if crouch > 0.2 else (255, 255, 255)
    _put_label(frame, f"crouch  {crouch:.2f}", (12, 128), 0.6, crouch_color)
    _put_label(frame, f"steps   {steps}", (12, 152), 0.6, (255, 255, 255))
    _put_label(frame, f"cadence {cadence:.0f}/min", (12, 176), 0.6, (255, 255, 255))
    _put_label(frame, f"effort  {met:.1f} MET", (12, 200), 0.6, (120, 255, 120))
    _put_label(frame, f"tracking {sources}", (12, 224), 0.5, (200, 200, 200))


def _draw_recording_overlay(frame, recorder, current_label: str, metronome,
                            beat_now: bool, hr_monitor) -> None:
    """Top-right recording status: REC dot, current label, frame count, beat, hr.

    Only drawn while --record is active, so it never clutters normal play. The
    bottom strip shows the key->label legend so the user can label on the fly.
    """
    h, w = frame.shape[:2]
    # Blinking red REC dot + frame counter.
    if int(time.time() * 2) % 2 == 0:
        cv2.circle(frame, (w - 210, 22), 8, (0, 0, 255), -1)
    _put_label(frame, "REC", (w - 195, 28), 0.6, (0, 0, 255))
    _put_label(frame, f"{recorder.frames} frames", (w - 140, 28), 0.55, (255, 255, 255))

    label_color = (120, 255, 120) if current_label != recording.DEFAULT_LABEL else (0, 200, 255)
    _put_label(frame, f"label: {current_label}", (w - 300, 56), 0.62, label_color)

    if metronome is not None:
        # Fill a circle on the beat frame, hollow between beats.
        cv2.circle(frame, (w - 280, 80), 10, (0, 220, 255), -1 if beat_now else 2)
        _put_label(frame, f"{metronome.bpm:.0f} bpm", (w - 260, 86), 0.55, (0, 220, 255))
    if hr_monitor is not None:
        bpm = hr_monitor.current_bpm()
        hr_text = f"hr {bpm:.0f}" if bpm > 0 else "hr --"
        _put_label(frame, hr_text, (w - 120, 86), 0.55, (0, 120, 255))

    # Legend along the bottom.
    _put_label(frame, recording.label_legend(), (12, h - 14), 0.5, (200, 200, 200))


if __name__ == "__main__":
    main()
