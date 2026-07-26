"""MotionFit pose service.

Captures the webcam, runs MediaPipe Pose, and turns body movement into
control + fitness values that it streams to Godot over a local UDP socket:

    forward : 0.0 .. 1.0   how fast you are marching in place
    turn    : -1.0 .. 1.0  torso yaw (rotate your body to steer)
    jump    : bool         true on the frame you launch into a jump
    crouch  : 0.0 .. 1.0   how deep you are squatting (0 = upright)
    duck    : 0.0 .. 1.0   how far you are bowing/leaning forward (0 = upright)
    hands_up: bool         the "ready" gesture -- both hands raised above the head
    arm_extend : ""/l/r    the arm that just snapped out (an edge event), with
                           arm_extend_kind naming its path out of the guard
    hands_front: bool      both hands raised in front of the face
    lean    : -1.0 .. 1.0  waist lean, -1 = on-screen left .. +1 right
    steps   : int          cumulative steps since the service started
    cadence : float        current pace in steps per minute

It also streams a small JPEG mirror of the webcam on a second UDP port so Godot's
setup/countdown screen can show the player framing themselves (Godot never
touches the camera itself -- see CONTEXT.md 9).

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
import statistics
import sys
import threading
import time
from collections import deque
from pathlib import Path

import cv2

# --- Skip TensorFlow (huge, unused) before importing mediapipe ---------------
# mediapipe's PoseLandmarker runs on its own bundled TFLite/XNNPACK C++ runtime
# and does NOT need the Python `tensorflow` package. But one line deep in
# mediapipe (tasks/python/core/optional_dependencies.py) does
# `from tensorflow.tools.docs import doc_controls` purely for a docs decorator,
# wrapped in `try/except ModuleNotFoundError`. If tensorflow happens to be
# installed, that import drags in ALL of TensorFlow -- ~14s warm, ~25s cold on
# this machine -- every single launch, for nothing. Making the import look
# missing sends mediapipe down its own no-op fallback, cutting `import mediapipe`
# from ~14-25s to ~1.5s. Nothing in this project uses tensorflow. Must run
# BEFORE `import mediapipe`.
class _HideTensorFlow:
    def find_spec(self, name, path=None, target=None):
        if name == "tensorflow" or name.startswith("tensorflow."):
            raise ModuleNotFoundError(name)  # mediapipe catches this and stubs it
        return None


sys.meta_path.insert(0, _HideTensorFlow())

# --- Stub matplotlib (pulled in by mediapipe, never used) --------------------
# mediapipe.tasks.python.vision.drawing_utils does `import matplotlib.pyplot`
# unconditionally, but the only thing that needs it (plot_landmarks) is never
# called here. Registering empty stub modules satisfies the import so the
# release bundle can drop matplotlib + PIL + tkinter (~30 MB). setdefault keeps
# a real matplotlib working if something imported it first.
import types

_mpl_stub = types.ModuleType("matplotlib")
_plt_stub = types.ModuleType("matplotlib.pyplot")
_mpl_stub.pyplot = _plt_stub  # type: ignore[attr-defined]
sys.modules.setdefault("matplotlib", _mpl_stub)
sys.modules.setdefault("matplotlib.pyplot", _plt_stub)

import mediapipe as mp

import recording  # sibling module: JSONL recorder, metronome, label + feature schema

# --- Network -----------------------------------------------------------------
UDP_HOST = "127.0.0.1"
UDP_PORT = 9990  # must match MotionManager.PORT in Godot
# The setup/countdown screen in Godot shows a live mirror of the camera so the
# player can frame themselves before playing. Godot does NO computer vision
# (CONTEXT.md 9), so Python owns the camera and simply ships a small JPEG of each
# frame on a SECOND port (kept separate from the control packets above so the
# realtime-control datagrams are never delayed behind a fat image). Godot's
# CameraPreview autoload binds this and blits it to a texture.
PREVIEW_PORT = 9991  # must match CameraPreview.PORT in Godot
PREVIEW_WIDTH = 320   # downscaled: the preview only needs to read as a mirror,
PREVIEW_HEIGHT = 240  # and this keeps each JPEG comfortably inside one datagram
PREVIEW_FPS = 15      # a smooth-enough mirror at a fraction of the encode cost
PREVIEW_QUALITY = 50  # JPEG quality; 320x240@50 is ~10-20 KB (< the UDP limit)
# Godot -> Python control channel. Every other port in this file streams OUT to
# Godot; this is the one port Godot streams back IN on, carrying tiny JSON
# commands {"cmd": "camera_on"} / {"cmd": "camera_off"} so the game can power the
# webcam up only while you're actually playing (the LED stays dark in menus).
# Honoured ONLY in --game (managed) mode; a standalone test session ignores it.
COMMAND_PORT = 9992  # must match MotionManager.COMMAND_PORT in Godot

# --- Camera ------------------------------------------------------------------
CAM_INDEX = 0
# Ask the webcam for this format explicitly. 640x480 is all the pose model needs
# (it downscales internally anyway); letting a camera default to 1080p just adds
# capture + colour-conversion cost and drags the whole loop's latency up.
CAM_WIDTH = 640
CAM_HEIGHT = 480
CAM_FPS = 30

# --- Pose model ----------------------------------------------------------------
# This build of mediapipe (0.10.x on Windows/Python 3.12) ships only the newer
# Tasks API (mediapipe.tasks.vision.PoseLandmarker) -- the legacy
# mp.solutions.pose API used in older tutorials isn't bundled, so we drive
# pose detection through a downloaded model bundle instead. Three sizes exist:
# lite (fastest -- pick it if the preview reports a low fps), full (the default
# accuracy/speed balance), heavy (most accurate, usually too slow for realtime).
MODEL_VARIANTS = ("lite", "full", "heavy")
MODEL_URL = (
    "https://storage.googleapis.com/mediapipe-models/pose_landmarker/"
    "pose_landmarker_{variant}/float16/latest/pose_landmarker_{variant}.task"
)


def _model_path(variant: str) -> Path:
    return Path(__file__).resolve().parent / "models" / f"pose_landmarker_{variant}.task"


# Kept as a module constant because the offline tools import it directly.
MODEL_PATH = _model_path("full")

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
FORWARD_THRESHOLD = 0.12  # fused channel speed below this counts as standing still
FORWARD_GAIN = 2.5        # scales the fused speed up toward 1.0. A comfortable
                          # march in place is only ~0.4-0.6 torso-lengths/sec, so
                          # at gain 1.0 you never got near full speed and the
                          # character crawled; 2.5 lets a steady march reach ~1.0.
ARM_WEIGHT = 0.5          # wrists count for less than legs (arm swing is secondary)

# Band-pass = keep only motion in the stepping band, dropping slow drift
# (turning, re-aiming the camera, posture) and fast pixel jitter. Cutoffs in Hz;
# ~0.6-5 Hz spans a slow walk (~1.5 steps/s) up to a brisk jog.
BAND_SLOW_HZ = 0.6        # discard motion slower than this (drift / turning)
BAND_FAST_HZ = 5.0        # discard motion faster than this (jitter)

# Turn = torso yaw, from the depth (z) offset between the shoulders in metric
# world space -- i.e. actually rotating your body to steer, not leaning.
TURN_DEADZONE = 0.10     # yaw below this is ignored (no accidental turns)
TURN_GAIN = 1.5          # scales yaw into the -1..1 turn range (lower = calmer,
                         # less twitchy steering — tuned down from 2.2 which
                         # oversteered on small torso rotations)
INVERT_TURN = True       # turning your body left must steer left (was mirrored)
MIN_VISIBILITY = 0.5     # ignore landmarks the model is unsure about

# --- Tracking-loss handling ----------------------------------------------------
# Landmark visibility flickers frame to frame; treating every dip as "person
# gone" resets all the filters and makes the character stutter. Instead:
#   * a channel (knee/ankle/wrist) that goes below MIN_VISIBILITY keeps its
#     filter state for CHANNEL_GRACE_SEC (it just stops contributing), and only
#     resets after a real absence. VIS_EXIT < MIN_VISIBILITY adds hysteresis so
#     a joint hovering right at the threshold doesn't flap in and out.
#   * losing the whole pose (or the valid stance) coasts the outputs down gently
#     for LOSS_GRACE_SEC before anything is reset, so a one-frame detection miss
#     is invisible in game.
VIS_EXIT = 0.35           # a tracked channel stays active until it drops below this
CHANNEL_GRACE_SEC = 0.5   # keep a hidden channel's filter state this long
LOSS_GRACE_SEC = 0.4      # coast (don't reset) through pose losses shorter than this
HOLD_DECAY_SEC = 0.5      # decay time-constant while coasting through the grace window
DROP_DECAY_SEC = 0.15     # decay time-constant once the pose is genuinely lost

# --- Position validity -------------------------------------------------------
# Before measuring anything we check the person is actually set up to march --
# in frame, standing upright, legs visible below the hips. Otherwise (sitting,
# reclining, half out of frame) the pose estimate is unreliable and would emit
# junk, so we pause and show an on-screen instruction instead.
POSE_MAX_TILT = 40.0     # torso may lean at most this many degrees from vertical
POSE_MIN_LEG_DROP = 0.6  # the planted knee must sit this far below the hips
                         # (in torso lengths) to ACQUIRE tracking -- i.e. you
                         # start from standing, not sitting/reclining.
POSE_SQUAT_LEG_DROP = -0.3  # ...but once you're already being tracked, the knee
                         # may rise this far ABOVE the hips without dropping out,
                         # so squatting (which folds the knee up to hip level and
                         # beyond in a deep squat) keeps registering as a crouch
                         # instead of being rejected as "STAND UP". Reclining
                         # toward the camera lifts the knees far higher than this,
                         # so it's still caught.
# Distance / framing: the torso's apparent height (as a fraction of the frame) is
# a stable proxy for how close the player stands -- stable because, unlike whole
# body height, it barely changes while marching. Too small = too far away to
# track the legs cleanly; too large = so close the feet fall out of frame. These
# keep the player in the zone the tracker measures best, and drive the setup
# screen's "get closer / step back" coaching. Reasoned starting values -- worth a
# live-webcam tuning pass.
POSE_MIN_TORSO_FRAC = 0.16  # torso shorter than this => "GET CLOSER"
POSE_MAX_TORSO_FRAC = 0.42  # torso taller than this  => "STEP BACK"
POSE_DUCK_TORSO_SCALE = 0.6  # ...but once tracked, allow the apparent torso to
                             # shrink to this fraction of the minimum: bowing
                             # toward the camera (the duck gesture) foreshortens
                             # it, and dropping to "GET CLOSER" mid-duck would
                             # freeze the very control the bow is driving.
POSE_FEET_EDGE_Y = 0.99     # a planted foot past this (bottom edge) => framed too low

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
# than when you stand tall. Two independent measures have to AGREE before we call
# it a squat, because either one alone is fooled by something players do all the
# time:
#
#   depth -- hip-to-planted-foot distance, torso-normalised, against a "standing"
#            reference. Taken from the METRIC WORLD landmarks: the image-space
#            version divided by the PROJECTED torso length, which foreshortens the
#            moment you lean, so a ~25-degree lean (torso ~10% shorter on screen)
#            moved this by more than the entire crouch-onset threshold. Leaning
#            read as squatting -- and a real squat's own forward lean partly
#            cancelled its hip drop, blunting the thing we wanted to measure.
#   gate  -- BILATERAL knee flexion, also from the world landmarks. A squat bends
#            BOTH knees; a march bends one and leaves the planted leg near
#            straight; a lean or a bow bends neither. Taking the LESS flexed knee
#            and requiring it past CROUCH_KNEE_START is what stops marching (and
#            leaning, and bowing) reading as a crouch -- structurally, instead of
#            by suppressing crouch whenever we think we can see a march.
#
# crouch = depth * gate, so both have to be convinced. Failing closed is the safe
# direction: a mis-tracked leg zeroes the gate and we MISS a squat rather than
# inventing one out of a lean.
CROUCH_STAND_HZ = 0.3     # how fast the standing reference tracks the player. It
                          # only moves while the knees agree we are actually
                          # STANDING (see STAND_KNEE_FLEX_MAX), so it can afford to
                          # be quick -- posture and distance drift are followed
                          # within a second, and a squat, lean or march can no
                          # longer drag it. The previous peak-follower snapped UP
                          # instantly and released over ~3s, so ANY one-frame spike
                          # in leg extension (a lean, a landmark glitch) re-based
                          # "standing" and left a phantom crouch behind it when you
                          # returned to normal. Instant attack / slow release was
                          # exactly backwards for a baseline.
STAND_KNEE_FLEX_MAX = 20.0  # knees straighter than this (degrees of flexion) means
                            # standing -- the only state in which the reference moves
CROUCH_STAND_BLIND_HZ = 0.05  # ...but with no knee evidence to say when we're
                            # standing (the model returned no world landmarks) the
                            # reference has to move all the time, so it moves
                            # slowly instead -- a held squat still reads for a few
                            # seconds before the baseline catches up. Symmetric,
                            # unlike the old peak-follower, so there is still no
                            # ratchet: nothing gets re-based by a one-frame spike.
CROUCH_START = 0.12       # leg-extension drop (torso fraction) where crouch begins
CROUCH_FULL = 0.45        # ...and where it reaches a full (1.0) crouch
CROUCH_KNEE_START = 40.0  # less-flexed knee past this many degrees opens the gate
CROUCH_KNEE_FULL = 70.0   # ...and past this the gate is fully open.
                          # Measured on datasets/exercises (36 clips, both knees
                          # resolvable in 93-100% of frames): marching and jogging
                          # top out at 42 / 43 degrees while squatting sits at a
                          # median of 58 and reaches 135, so the populations barely
                          # overlap. Swept against those clips, 40/70 was the most
                          # sensitive setting that still gave ZERO false positives
                          # on march, jog and jumping jacks; opening earlier (30/65)
                          # bought ~1pt of squat sensitivity for 0.7% false jacks.
                          # Note the margin against a march's deepest frames lives
                          # in the DEPTH term (march never exceeds 0.10 of it), not
                          # here -- that is what "both must agree" is for.
# ...but these fixed drops assume an "average" squat. People squat to very
# different depths (flexibility, limb proportions), so a fixed CROUCH_FULL makes a
# shallow squatter never reach 1.0 and a deep one saturate early. A ~10s
# calibration (see Calibrator) captures THIS player's standing and deepest-squat
# leg extension and maps crouch across their real range instead: crouch starts
# once they're this fraction of the way down and hits 1.0 at this fraction, so a
# full squat reads 1.0 for everyone. Falls back to the fixed drops above when
# uncalibrated. Calibration also SEEDS the standing reference so crouch is correct
# from the first frame instead of after a warm-up. The seed is only a starting
# point now -- the reference re-learns itself whenever the player is standing --
# so a calibration captured before the world-landmark switch still works: what it
# really contributes is the RANGE, a difference between two values measured the
# same way, which survives the change of measurement almost intact.
CROUCH_START_FRAC = 0.15  # crouch begins this fraction into the player's squat range
CROUCH_FULL_FRAC = 0.85   # ...and reaches 1.0 at this fraction (near, not at, the floor)
CALIB_MIN_RANGE = 0.15    # a squat must fold the leg at least this much (torso frac) to
                          # calibrate -- guards against a too-shallow/failed capture

# --- Calibration capture (the ~10s setup) ------------------------------------
CALIB_STILL_SEC = 1.5     # hold a still stand this long to capture the standing pose
CALIB_STILL_SPEED = 0.10  # fused body speed below this counts as "standing still"
CALIB_SQUAT_SEC = 4.0     # window to perform one deep squat; deepest point is captured
CALIB_PATH = Path(__file__).resolve().parent / "calibration.json"

# A jump (or a knee-tuck at the top of one) lifts BOTH feet toward the hip, which
# shortens the hip->planted-foot distance exactly the way a squat does -- so
# without a guard a jump reads as a deep crouch. Distinguishing the two from a
# CONTINUOUS "feet up" level proved unreliable on real recordings: a foot-vs-floor
# measure fires on foot-landmark glitches, and a hip-vs-baseline level fires on
# every squat's (fast, controlled) stand-up. The one signal that stays clean is
# the speed-gated jump EDGE (`jumped` below): its up-speed requirement rejects a
# squat ascent but catches an explosive launch. So we blank crouch (and block the
# march) for a hold window around each detected jump -- the flight and its landing
# knee-bend, plus the next hop in a repeated bout. Kept short so a genuine squat
# begun soon after a jump still registers.
JUMP_CROUCH_HOLD = 0.7    # blank crouch / block march for this long after a jump edge

# Leg extension needs the ANKLES. The old code silently substituted the KNEES the
# moment either ankle dipped below the visibility threshold -- but hip->knee is
# roughly half of hip->ankle, so that swap dropped leg_ext by ~0.8 torso against a
# CROUCH_FULL of 0.45: one flickering ankle produced an instant, saturated,
# entirely phantom crouch, with no continuity at all between the two branches.
# Marching is the single best way to cause that flicker -- the swing ankle
# occludes behind the other leg or leaves the bottom of the frame. The fallback is
# kept (players in loose trousers really do lose the ankles) but each source now
# carries its OWN standing reference, so a switch compares like with like. A
# source with no reference yet reads 0 until the player has stood still long
# enough to learn one, which is the safe way round.
CROUCH_GRACE_SEC = 0.25   # neither ankles nor knees usable: decay crouch out this fast

# Squat vs march: a squat's down-and-up sweep moves the legs relative to the hip
# just like a march does, so it leaks into `forward` and the step counter. You
# can't march and squat at the same time, and a squat's large hip drop makes
# `crouch` by far the more reliable read -- so whenever we're crouching we treat
# it as a squat and suppress the march signal (with a short hold so the rising
# half of the rep is covered too, not just the deep bottom).
CROUCH_MARCH_GATE = 0.15  # crouch depth above which motion is read as squatting
SQUAT_MARCH_HOLD = 0.4    # keep suppressing the march this long after crouch eases
#
# There is deliberately NO rule in the other direction any more. There used to be
# one (clear crouch while `forward` says we're marching), and it was load-bearing
# only because it read the ALREADY-VETOED `forward`: a real squat won the veto
# above, `forward` fell to ~0, and the squat therefore escaped its own suppression.
# Reading the raw fused speed instead looks like it fixes a deadlock and actually
# destroys crouch, because a squat's down-and-up leg sweep produces exactly the
# fused speed a march does -- on the recorded clips that alone cut squat detection
# from 38% of frames to 4%. Keeping the vetoed reading brings the deadlock back:
# a false crouch zeroes `forward`, which stops the correction that would clear it.
#
# The bilateral-knee gate removes the need for the rule entirely. Measured over
# datasets/exercises: marching and jogging never move the crouch DEPTH term off
# 0.00/0.10 at all once the standing reference stopped ratcheting, and their knee
# flexion never opens the gate. Nothing is left for a march-side veto to catch.

# --- Duck (bow/lean forward) --------------------------------------------------
# The squat-based crouch proved near-unusable mid-run: the march gate above used
# to suppress it whenever `forward` was up, so a player running in place had to
# fully stop, wait out the hold, THEN squat deep -- far too slow for an oncoming
# bar. (That veto is gone now, but a deep squat mid-run is still a slow, awkward
# move.) Duck is the alternative: bow the torso forward (lean down) while
# still running. It is measured as torso pitch from MediaPipe's METRIC world
# landmarks -- the hip->shoulder line tipping toward the camera (z) versus its
# vertical rise -- so it is distance-invariant, needs no calibration, and shares
# nothing with the leg channels: no march/jump gating required, marching legs
# can't fake it, and it can't fake a march. Only the forward (z) component
# counts, so a sideways lean (steering body language) never reads as a duck.
DUCK_START_DEG = 20.0   # torso pitch where the duck begins -- above the ~5-15
                        # degrees of natural jogging lean, so running is 0
DUCK_FULL_DEG = 45.0    # ...and where it reaches 1.0: a clear but easy bow
DUCK_SMOOTH_HZ = 3.0    # light low-pass on the pitch read (world landmarks
                        # jitter more than image ones); Godot smooths again

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
STEP_SIDE_MIN_INTERVAL = 0.35  # per-leg debounce: one leg can't step twice this
                          # fast, so a bouncy single-leg oscillation (noise, or a
                          # heel tap) can't double-count -- alternation still fits
STEP_FORWARD_GATE = 0.05  # only count steps while actually moving forward -- a
                          # slow waist turn drifts the legs enough to fake a
                          # foot plant, but it doesn't raise `forward`, so gating
                          # on forward motion rejects turning-in-place as steps

# Cadence comes from the actual intervals between recent steps (a pedometer's
# method) rather than counting steps in a fixed window: it locks on after two
# steps instead of five seconds, doesn't quantise to 12-per-minute jumps, and
# winds down smoothly when you stop.
CADENCE_SMOOTH_STEPS = 4  # median over this many recent step intervals
CADENCE_RESET_SEC = 1.5   # no step for this long (and 3x the interval) = stopped

# --- Effort (energy expenditure) ---------------------------------------------
# We emit a MET estimate (metabolic equivalent of task) computed from motion
# ALONE. MET is body-mass-normalised by definition, so Python -- which has no
# idea what the player weighs -- can own it cleanly, and Godot turns MET into
# calories using the player's weight from ProfileManager (kcal/min = MET * 3.5 *
# kg / 200). A heart-rate reading, when a wearable is present, fuses in on the
# Godot side later; until then this motion estimate is the fallback.
#
# The cadence->MET leg is anchored to published measurements (the CADENCE-Adults
# study, Tudor-Locke et al.: ~100 steps/min = 3 METs, then about +1 MET per
# +10 steps/min -- 110->4, 120->5, 130->6). Marching in place tracks walking
# closely at matched cadence, so this is the best-evidenced anchor available
# without per-user calibration. The other terms (whole-body vigour, squat work,
# jumps) remain reasoned estimates pending a calibration pass against heart rate.
REST_MET = 1.2               # standing in frame but not moving
CADENCE_MODERATE_SPM = 100.0 # cadence at which effort reaches MET_MODERATE
MET_MODERATE = 3.0           # METs at CADENCE_MODERATE_SPM (moderate intensity)
MET_PER_SPM_ABOVE = 0.1      # +MET per step/min beyond the moderate anchor
FORWARD_MET_SPAN = 7.0       # forward 0..1 -> +0..7 MET (whole-body vigour)
SQUAT_MET_GAIN = 8.0         # MET per unit of leg-fold speed (torso-lengths/s):
                             # steady squatting cycles ~0.3-0.4 -> ~4-5 MET, in
                             # line with moderate-to-vigorous calisthenics. This
                             # is what makes slow squats count at all -- they sit
                             # below the stepping band so cadence/forward miss them
JUMP_MET_PER_MIN = 0.12      # +MET per jump/min (plyometric burn, on top)
MET_MAX = 14.0               # clamp (sprint / burpee territory)
# Boxing work is arm- and trunk-driven, so the cadence/forward/squat channels all
# under-read it -- a player throwing hard combos barely steps. These terms give
# punching its own MET channel, anchored to the Compendium of Physical Activities
# boxing entries: punching bag ~5.5 MET, sparring ~7.8, in the ring ~12.8.
# With the guard term included that lands at 40 punches/min ~ 6.2 (bag work),
# 60/min ~ 8.2 (sparring) and 100/min ~ 12.2 (a real round) -- close to the
# published values across the whole range.
PUNCH_MET_PER_MIN = 0.10     # +MET per punch/min thrown
GUARD_MET = 1.0              # +MET for holding a guard up (isometric shoulder work)
SLIP_MET_GAIN = 0.6          # MET per unit of lean speed (slips/s) -- bobbing and weaving
PUNCH_WINDOW_SEC = 8.0       # rolling window for the punch-rate term (~a combo's worth)
EFFORT_WINDOW_SEC = 5.0      # rolling window for the jump-rate term
EFFORT_SMOOTH_HZ = 0.4       # low-pass MET so the calorie counter reads steadily
SQUAT_SPEED_SMOOTH_HZ = 0.3  # low-pass on the leg-fold speed feeding SQUAT_MET_GAIN

# --- Punch detection (Boxing) -----------------------------------------------
# A punch is a fast arm EXTENSION: the wrist shoots away from the shoulder to
# near-full reach, then must retract before another counts (so one throw = one
# hit). Reach is measured from the metric world landmarks and normalised by torso
# length, so it is distance/scale invariant and needs no calibration. It's
# direction-agnostic (any quick full extension counts) so jabs, crosses and hooks
# all register. Mirrors the jump detector: an EDGE event, fired once on the throw.
PUNCH_EXTEND_MIN = 0.82      # wrist->shoulder reach (torso lengths) that reads as extended
PUNCH_RESET_EXTEND = 0.70    # must retract below this before that hand can punch again
PUNCH_SPEED_MIN = 1.4        # reach growth (torso/s) to fire -- a real snap, not a drift
PUNCH_SPEED_MAX = 6.0        # reach growth mapped to full power (1.0)
PUNCH_MIN_INTERVAL = 0.26    # per-hand debounce (s)
PUNCH_SMOOTH_HZ = 9.0        # light low-pass on reach so landmark jitter can't fire it

# Which on-screen glove each anatomical wrist drives. Pose runs on the MIRRORED
# preview (frame is cv2.flip'd), where MediaPipe's L_WRIST lands on the player's
# on-screen RIGHT and R_WRIST on their on-screen LEFT. So a throw from the hand
# that appears on the LEFT of the mirror must read "left" -> map R_WRIST->left,
# L_WRIST->right. Flip this pair if a camera/mirror change ever inverts the read.
PUNCH_SIDE_OF = {"l_wrist": "right", "r_wrist": "left"}

# --- Punch TYPE (Boxing: straight / hook / uppercut) -------------------------
# On top of "which glove", the throw is classified by WHERE the glove travelled
# between its resting guard and full extension, measured in the shoulder's frame
# and normalised by torso length:
#   forward (toward the camera) -> a STRAIGHT (jab / cross),
#   sideways across the body    -> a HOOK (the wide, swinging punch),
#   upward from below the chest -> an UPPERCUT.
# Thresholds are deliberately loose and STRAIGHT is the fallback: this is for
# players who have never boxed, so a sloppy throw still lands as *something*
# rather than being rejected. Only a clearly wide or clearly rising arc gets
# reclassified.
PUNCH_HOOK_LATERAL = 0.30    # sideways travel (torso lengths) that reads as wide
PUNCH_UPPER_RISE = 0.26      # upward travel that reads as a rising punch
PUNCH_TYPE_DOMINANCE = 0.85  # how far an axis must beat forward travel to win

# --- Guard + lean (Boxing defence) -------------------------------------------
# GUARD is the "hands covering your face" block: both gloves up around chin/eye
# height and tucked in near the head (not flung out wide). Read from image
# landmarks and normalised by torso length so it is distance invariant.
GUARD_WRIST_RISE = 0.12      # wrist must be this far above the shoulder line (torso lengths)
GUARD_WRIST_SPREAD = 0.95    # max |wrist - shoulder centre| horizontally (shoulder spans)
# LEAN is the waist slip: the shoulder centre displaced sideways from the hip
# centre, i.e. bending at the waist to take your head off the punch line.
# Negative = leaning to the player's ON-SCREEN LEFT (same convention as punch
# sides, which are read off the mirrored preview).
LEAN_DEADZONE = 0.06         # sideways offset (torso lengths) ignored as posture noise
LEAN_GAIN = 3.4              # offset -> -1..1; a ~0.35 torso lean reads as a full slip
LEAN_SMOOTH_HZ = 6.0         # low-pass so a slip is smooth but still snappy

# MediaPipe Pose landmark indices we use.
NOSE = 0
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


class _Camera:
    """Threaded webcam reader that always serves the newest frame.

    cap.read() blocks for up to a whole frame interval, so doing it inline
    serialises capture and pose inference and caps the loop at half the camera
    rate. Reading on a daemon thread lets the two overlap, and latest-frame-wins
    (stale frames are simply never processed) keeps control latency at a single
    frame however slow inference runs on a given machine.
    """

    def __init__(self, index: int, width: int = CAM_WIDTH,
                 height: int = CAM_HEIGHT, fps: int = CAM_FPS) -> None:
        # DirectShow opens far faster and more reliably than the default MSMF
        # backend on Windows; elsewhere let OpenCV pick.
        if sys.platform == "win32":
            self._cap = cv2.VideoCapture(index, cv2.CAP_DSHOW)
            if not self._cap.isOpened():
                self._cap = cv2.VideoCapture(index)
        else:
            self._cap = cv2.VideoCapture(index)
        if self._cap.isOpened():
            self._cap.set(cv2.CAP_PROP_FRAME_WIDTH, width)
            self._cap.set(cv2.CAP_PROP_FRAME_HEIGHT, height)
            self._cap.set(cv2.CAP_PROP_FPS, fps)
            self._cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)  # don't queue stale frames
        self._lock = threading.Lock()
        self._frame = None
        self._seq = 0  # bumps per captured frame so callers never reprocess one
        self._running = False
        self._thread: threading.Thread | None = None

    @property
    def opened(self) -> bool:
        return self._cap.isOpened()

    def start(self) -> None:
        self._running = True
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()

    def _loop(self) -> None:
        while self._running:
            ok, frame = self._cap.read()
            if not ok:
                time.sleep(0.005)
                continue
            with self._lock:
                self._frame = frame
                self._seq += 1

    def read_latest(self, last_seq: int, timeout: float = 1.0):
        """Blocks briefly for a frame newer than last_seq.

        Returns (seq, frame) -- or (last_seq, None) if the camera produced
        nothing new within the timeout (unplugged / stalled).
        """
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self._lock:
                if self._seq != last_seq and self._frame is not None:
                    return self._seq, self._frame
            time.sleep(0.002)
        return last_seq, None

    def release(self) -> None:
        self._running = False
        if self._thread is not None:
            self._thread.join(timeout=1.0)
        self._cap.release()


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


class _LegGeometry:
    """One frame's leg measurements, as read by `_leg_geometry`.

    ext       -- hip centre -> planted foot, torso-normalised.
    source    -- which landmark the "foot" came from: "ankle" or "knee". The two
                 measure lengths that differ by ~0.8 torso, so each carries its own
                 standing reference and they are never compared to each other.
    knee_flex -- degrees of flexion in the LESS bent knee, or None when both knees
                 couldn't be measured. One bent knee is a march and two is a squat,
                 so a single leg can't tell them apart and doesn't get a vote.
    """

    __slots__ = ("ext", "source", "knee_flex")

    def __init__(self, ext: float, source: str, knee_flex: float | None) -> None:
        self.ext = ext
        self.source = source
        self.knee_flex = knee_flex


def _knee_flex_deg(pts, hip_i: int, knee_i: int, ankle_i: int) -> float:
    """Knee flexion in degrees: 0 = leg straight, ~110 at the bottom of a deep squat.

    The thigh/shank angle at the knee, in metric 3D -- so it doesn't care how far
    the player stands from the camera, how the camera is tilted, or how far the
    torso is leaning. That independence is the entire point: it is the one squat
    signal a lean, a hip-bob or a change of distance cannot fake.
    """
    tx = pts[hip_i].x - pts[knee_i].x
    ty = pts[hip_i].y - pts[knee_i].y
    tz = pts[hip_i].z - pts[knee_i].z
    sx = pts[ankle_i].x - pts[knee_i].x
    sy = pts[ankle_i].y - pts[knee_i].y
    sz = pts[ankle_i].z - pts[knee_i].z
    t_len = math.sqrt(tx * tx + ty * ty + tz * tz)
    s_len = math.sqrt(sx * sx + sy * sy + sz * sz)
    if t_len < 1e-6 or s_len < 1e-6:
        return 0.0
    cos = _clamp((tx * sx + ty * sy + tz * sz) / (t_len * s_len), -1.0, 1.0)
    return 180.0 - math.degrees(math.acos(cos))


def _leg_geometry(lm, wlm, visible: dict, hip_cy: float,
                  torso_len: float) -> "_LegGeometry | None":
    """This frame's leg fold, measured in metric world space where possible.

    `ext` is hip centre -> planted foot, torso-normalised. Taken from the world
    landmarks, both the numerator and the torso-length denominator are true 3D
    lengths, so leaning no longer foreshortens the denominator and inflates the
    ratio -- the failure that made a bow read as a squat and blunted real squats.
    Image landmarks are the fallback if the model returned no world frame.

    The PLANTED (lower) foot defines the fold, so a marching high knee -- which
    lifts the swing foot -- isn't read as a crouch. Ankles are preferred; knees are
    a distinct, separately-referenced fallback for when trousers or framing hide
    the feet. Returns None when neither is usable, so the caller can decay crouch
    out instead of guessing.
    """
    l_ank = bool(visible.get("l_ankle"))
    r_ank = bool(visible.get("r_ankle"))
    l_kne = bool(visible.get("l_knee"))
    r_kne = bool(visible.get("r_knee"))

    if wlm is not None:
        pts = wlm
        hip_y = (wlm[L_HIP].y + wlm[R_HIP].y) * 0.5
        sh_x = (wlm[L_SHOULDER].x + wlm[R_SHOULDER].x) * 0.5
        sh_y = (wlm[L_SHOULDER].y + wlm[R_SHOULDER].y) * 0.5
        sh_z = (wlm[L_SHOULDER].z + wlm[R_SHOULDER].z) * 0.5
        hip_x = (wlm[L_HIP].x + wlm[R_HIP].x) * 0.5
        hip_z = (wlm[L_HIP].z + wlm[R_HIP].z) * 0.5
        torso = math.sqrt((sh_x - hip_x) ** 2 + (sh_y - hip_y) ** 2 + (sh_z - hip_z) ** 2)
    else:
        pts = lm
        hip_y = hip_cy
        torso = torso_len
    if torso < 1e-6:
        return None

    # Planted = lower on screen; image AND world y both grow DOWNWARD.
    if l_ank and r_ank:
        foot_y, source = max(pts[L_ANKLE].y, pts[R_ANKLE].y), "ankle"
    elif l_ank:
        foot_y, source = pts[L_ANKLE].y, "ankle"
    elif r_ank:
        foot_y, source = pts[R_ANKLE].y, "ankle"
    elif l_kne and r_kne:
        foot_y, source = max(pts[L_KNEE].y, pts[R_KNEE].y), "knee"
    else:
        return None

    # The squat gate needs BOTH legs: one bent knee is a march, two is a squat.
    knee_flex = None
    if wlm is not None and l_ank and r_ank and l_kne and r_kne:
        knee_flex = min(_knee_flex_deg(wlm, L_HIP, L_KNEE, L_ANKLE),
                        _knee_flex_deg(wlm, R_HIP, R_KNEE, R_ANKLE))

    return _LegGeometry((foot_y - hip_y) / torso, source, knee_flex)


class _VerticalMotion:
    """Detects jumps (edge events) and crouches (continuous) from body height.

    Both are measured in torso-length units, so they don't care how far you stand
    from the camera. `update` returns True on the single frame a jump launches;
    `crouch` holds the current squat depth, 0.0 (upright) .. 1.0.

    Crouch is the product of a depth term (how far the legs have folded, against a
    standing reference) and a bilateral knee-flexion gate -- see the CROUCH_*
    constants for why one without the other reads every lean and every march as a
    squat. The standing reference moves only while the knee gate says the player is
    genuinely standing, which is what keeps a squat, a lean or a march from
    dragging the very baseline they are being measured against.
    """

    def __init__(self) -> None:
        self._rest = _LowPass()                # slow baseline of hip height (up+)
        self._prev_hip_up: float | None = None
        # Standing leg extension, one per measurement source ("ankle"/"knee"), so
        # falling back to the knees compares like with like instead of reading the
        # gap between the two measurements as an instant, full-depth squat.
        self._stand_ext: dict[str, float] = {}
        # Crouch mapping (leg-fold drop, torso frac). Defaults to the fixed
        # constants; apply_calibration() personalises them to the player's range.
        self._crouch_start = CROUCH_START
        self._crouch_full = CROUCH_FULL
        self._calib_stand_ext: float | None = None  # calibrated standing seed (survives reset)
        self._last_air_time = -1000.0          # last airborne/jump instant (crouch hold)
        self._work = _LowPass()                # smoothed |leg-fold speed| (effort)
        self._prev_leg_ext: float | None = None
        self._prev_leg_src: str | None = None
        self.crouch = 0.0
        self.rise = 0.0        # hip height above its resting baseline (torso frac)
        self.in_jump = False   # within the hold window of a detected jump -- blocks the march
        self.work_speed = 0.0  # torso-lengths/s of leg folding -- squat effort
        self.last_jump_time = -1000.0

    def update(self, hip_up: float, leg: "_LegGeometry | None", torso_len: float,
               dt: float, now: float) -> bool:
        """hip_up: hip-centre height, up = positive, in normalized image units.
        leg: this frame's leg geometry, or None when the legs aren't usable.
        Returns True on the frame a jump launches."""
        if dt <= 0.0 or torso_len < 1e-3:
            return False

        # --- Jump: hip springs above its slow resting baseline ----------------
        rest = self._rest(hip_up, _BandPass._alpha(JUMP_BASELINE_HZ, dt))
        rise = (hip_up - rest) / torso_len
        self.rise = rise  # diagnostic / airborne source
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

        # --- Jump window: mark in_jump around a detected jump ------------------
        # Driven by the speed-gated `jumped` edge (the only jump signal that a
        # squat's stand-up doesn't fake). The hold spans the flight, the landing
        # knee-bend, and the next hop in a repeated bout -- so a knee-tuck jump
        # never reads as a crouch, and the caller can block the march too via
        # `in_jump` (a jump mustn't read as walking any more than a squat does). A
        # squat clear of a jump is untouched: its ascent doesn't fire `jumped`.
        # Resolved BEFORE crouch so the standing reference knows not to learn from
        # a frame the player spent in the air.
        if jumped:
            self._last_air_time = now
        self.in_jump = (now - self._last_air_time) < JUMP_CROUCH_HOLD

        self._update_crouch(leg, dt)
        if self.in_jump:
            self.crouch = 0.0

        # --- Vertical work: how fast the legs are folding/unfolding -----------
        # Slow, deep squats sit below the stepping band, so cadence and forward
        # both read ~0 for them; the smoothed |d(leg_ext)/dt| captures that work
        # for the effort estimate. Clipped so a landmark glitch can't spike it.
        # A gap in the geometry, or a switch between the ankle and knee sources,
        # breaks the difference (the two sources are ~0.8 torso apart), so the
        # previous sample is dropped rather than differenced across the seam.
        if leg is None:
            self._prev_leg_ext = None
            self._prev_leg_src = None
        else:
            if self._prev_leg_ext is not None and self._prev_leg_src == leg.source:
                fold_speed = min(abs(leg.ext - self._prev_leg_ext) / dt, 3.0)
                self.work_speed = self._work(
                    fold_speed, _BandPass._alpha(SQUAT_SPEED_SMOOTH_HZ, dt)
                )
            self._prev_leg_ext = leg.ext
            self._prev_leg_src = leg.source
        return jumped

    def _update_crouch(self, leg: "_LegGeometry | None", dt: float) -> None:
        """Squat depth = how far the legs have folded * how bent both knees are."""
        if leg is None:
            # No usable leg geometry at all. Decay out rather than holding a stale
            # crouch or substituting a different measurement, and touch no baseline
            # -- nothing should be learned from a frame we couldn't see.
            self.crouch *= math.exp(-dt / CROUCH_GRACE_SEC)
            return

        # The squat gate. `None` means we couldn't measure both knees (no world
        # landmarks, or a leg out of view), which leaves the gate open: degraded,
        # but the depth term and the march suppression still apply.
        if leg.knee_flex is None:
            gate = 1.0
            standing = None
        else:
            gate = _clamp(
                (leg.knee_flex - CROUCH_KNEE_START)
                / (CROUCH_KNEE_FULL - CROUCH_KNEE_START), 0.0, 1.0
            )
            standing = leg.knee_flex < STAND_KNEE_FLEX_MAX

        # The standing reference tracks the player ONLY while the knees confirm a
        # stand (and never mid-jump), so a squat, a lean or a march can't drag the
        # baseline they're measured against. With no knee evidence there's nothing
        # to gate on, so it tracks continuously but slowly instead -- gating it on
        # "crouch is currently 0" would let a false crouch freeze the very baseline
        # whose recovery would clear it, which is the latch this whole change is
        # about removing.
        ref = self._stand_ext.get(leg.source)
        if ref is None:
            ref = leg.ext          # first sample from this source seeds it
            self._stand_ext[leg.source] = ref
        elif not self.in_jump and (standing is None or standing):
            hz = CROUCH_STAND_HZ if standing is not None else CROUCH_STAND_BLIND_HZ
            ref += _BandPass._alpha(hz, dt) * (leg.ext - ref)
            self._stand_ext[leg.source] = ref

        drop = ref - leg.ext
        depth = _clamp(
            (drop - self._crouch_start) / (self._crouch_full - self._crouch_start),
            0.0, 1.0
        )
        self.crouch = depth * gate

    def reset(self) -> None:
        self._rest.reset()
        self._prev_hip_up = None
        # Re-seed the ankle-source standing reference from calibration if we have
        # one, so a tracking blink / camera re-open doesn't force a re-acquire; an
        # uncalibrated session (and the knee source either way) relearns from the
        # first standing frame.
        self._stand_ext = {}
        if self._calib_stand_ext is not None:
            self._stand_ext["ankle"] = self._calib_stand_ext
        self._last_air_time = -1000.0
        self._work.reset()
        self._prev_leg_ext = None
        self._prev_leg_src = None
        self.crouch = 0.0
        self.rise = 0.0
        self.in_jump = False
        self.work_speed = 0.0

    def apply_calibration(self, standing_ext: float, squat_ext: float) -> None:
        """Personalise crouch to this player's measured range and seed the standing
        reference. standing_ext / squat_ext are torso-normalised hip->foot leg
        extensions at a full stand and the deepest squat (so distance-invariant).
        Captured with the ankles in view, hence the "ankle" source."""
        rng = standing_ext - squat_ext
        if rng < CALIB_MIN_RANGE:
            return  # too shallow to trust; keep the fixed defaults
        self._crouch_start = CROUCH_START_FRAC * rng
        self._crouch_full = CROUCH_FULL_FRAC * rng
        self._calib_stand_ext = standing_ext
        self._stand_ext["ankle"] = standing_ext  # correct crouch from the first frame

    def clear_calibration(self) -> None:
        """Drops a personalised calibration, reverting to the fixed default crouch
        map and the self-calibrating standing reference."""
        self._crouch_start = CROUCH_START
        self._crouch_full = CROUCH_FULL
        self._calib_stand_ext = None


class ControlState:
    """Per-frame carry-over: one oscillator per fused body channel."""

    def __init__(self) -> None:
        self.osc = {name: _Oscillator() for name, *_ in FORWARD_CHANNELS}
        self.vertical = _VerticalMotion()  # jump/crouch from hip & leg height
        self.duck_lp = _LowPass()          # smoothed torso-pitch duck (bow forward)
        self.lean_lp = _LowPass()          # smoothed waist lean (Boxing slip, -1..1)
        # While this is in the future the player is squatting (or just was), so the
        # march signal is suppressed -- a squat's leg sweep mustn't read as walking.
        self.squat_active_until = -1e9
        # (There is no mirror of this. The bilateral-knee gate stops a march
        # reading as a squat; see the CROUCH_MARCH_GATE block for why a
        # march->crouch veto cannot be written safely.)
        self.active_label = "none"  # which channel groups are tracking, for the HUD
        # Per-channel dropout bookkeeping: when a joint was last confidently seen
        # and whether it is currently contributing. A channel that dips below the
        # visibility threshold keeps its filter state for CHANNEL_GRACE_SEC (see
        # the tracking-loss constants) instead of resetting on every flicker.
        self.last_seen = {name: -1e9 for name, *_ in FORWARD_CHANNELS}
        self.channel_active = {name: False for name, *_ in FORWARD_CHANNELS}
        # Snapshot of this frame's features for the recording harness (empty when
        # not recording / no valid pose). Populated by _compute_controls.
        self.feature_snapshot: dict = {}

    def reset(self) -> None:
        for osc in self.osc.values():
            osc.reset()
        self.vertical.reset()
        self.duck_lp.reset()
        self.lean_lp.reset()
        self.squat_active_until = -1e9
        self.active_label = "none"
        self.last_seen = {name: -1e9 for name in self.last_seen}
        self.channel_active = {name: False for name in self.channel_active}
        self.feature_snapshot = {}


class Calibration:
    """A player's captured body reference, persisted between sessions.

    Everything here is torso-normalised (so it's distance/camera invariant) except
    the timestamp. `standing_ext` / `squat_ext` are the hip->foot leg extension at
    a full stand and the deepest squat; the gap between them is the player's squat
    range, which personalises the crouch mapping (see _VerticalMotion)."""

    def __init__(self, standing_ext: float, squat_ext: float, created: float) -> None:
        self.standing_ext = standing_ext
        self.squat_ext = squat_ext
        self.created = created

    @property
    def valid(self) -> bool:
        return (self.standing_ext - self.squat_ext) >= CALIB_MIN_RANGE

    def to_dict(self) -> dict:
        return {"standing_ext": round(self.standing_ext, 5),
                "squat_ext": round(self.squat_ext, 5), "created": self.created}

    @classmethod
    def from_dict(cls, d: dict) -> "Calibration | None":
        try:
            return cls(float(d["standing_ext"]), float(d["squat_ext"]),
                       float(d.get("created", 0.0)))
        except (KeyError, TypeError, ValueError):
            return None

    def save(self, path: Path = CALIB_PATH) -> None:
        path.write_text(json.dumps(self.to_dict()), encoding="utf-8")

    @classmethod
    def load(cls, path: Path = CALIB_PATH) -> "Calibration | None":
        if not path.exists():
            return None
        try:
            prof = cls.from_dict(json.loads(path.read_text(encoding="utf-8")))
        except (ValueError, OSError):
            return None
        return prof if (prof and prof.valid) else None


class Calibrator:
    """Runs the ~10s setup that captures a [Calibration].

    A tiny state machine driven one frame at a time. It replaces the live server's
    slow self-calibrating baselines (which today were shown to drift and get
    contaminated by squats/jumps) with an explicit, robust, one-off measurement:

        STILL  -- stand naturally still; the median standing leg extension is
                  captured once you've held it for CALIB_STILL_SEC.
        SQUAT  -- squat down once and hold near the bottom; the deepest (smallest)
                  leg extension over CALIB_SQUAT_SEC is captured.
        DONE   -- a Calibration is produced (and saved). FAILED if the squat was
                  too shallow to trust, so the UI can ask for a retry.

    `status`/`prompt`/`progress` drive the setup screen (or the OpenCV HUD). It is
    fed torso-normalised leg extension and the fused body speed each frame, so the
    capture is distance-invariant and can tell "standing still" from moving.
    """

    IDLE, STILL, SQUAT, DONE, FAILED = "idle", "still", "squat", "done", "failed"

    def __init__(self) -> None:
        self.state = self.IDLE
        self._still_accum = 0.0        # seconds of continuous stillness so far
        self._stand_samples: list[float] = []
        self._squat_elapsed = 0.0
        self._squat_min = 1e9
        self._standing_ext = 0.0
        self.result: "Calibration | None" = None

    @property
    def active(self) -> bool:
        return self.state in (self.STILL, self.SQUAT)

    def start(self) -> None:
        self.state = self.STILL
        self._still_accum = 0.0
        self._stand_samples = []
        self._squat_elapsed = 0.0
        self._squat_min = 1e9
        self.result = None

    def update(self, leg_ext: float, fused_speed: float, dt: float) -> None:
        if self.state == self.STILL:
            if fused_speed < CALIB_STILL_SPEED:
                self._still_accum += dt
                self._stand_samples.append(leg_ext)
            else:
                self._still_accum = 0.0   # moved -> restart the hold
                self._stand_samples = []
            if self._still_accum >= CALIB_STILL_SEC and self._stand_samples:
                self._standing_ext = statistics.median(self._stand_samples)
                self.state = self.SQUAT
                self._squat_elapsed = 0.0
                self._squat_min = self._standing_ext
        elif self.state == self.SQUAT:
            self._squat_elapsed += dt
            self._squat_min = min(self._squat_min, leg_ext)
            if self._squat_elapsed >= CALIB_SQUAT_SEC:
                prof = Calibration(self._standing_ext, self._squat_min, time.time())
                if prof.valid:
                    self.result = prof
                    self.state = self.DONE
                else:
                    self.state = self.FAILED

    @property
    def progress(self) -> float:
        if self.state == self.STILL:
            return _clamp(self._still_accum / CALIB_STILL_SEC, 0.0, 1.0)
        if self.state == self.SQUAT:
            return _clamp(self._squat_elapsed / CALIB_SQUAT_SEC, 0.0, 1.0)
        return 1.0 if self.state == self.DONE else 0.0

    @property
    def prompt(self) -> str:
        return {
            self.STILL: "CALIBRATING - stand still",
            self.SQUAT: "NOW SQUAT DOWN and hold",
            self.DONE: "CALIBRATED",
            self.FAILED: "SQUAT TOO SHALLOW - try again",
        }.get(self.state, "")


class StepCounter:
    """Tallies steps and derives a live cadence (steps per minute).

    Cadence is 60 / median(recent step intervals) -- the pedometer method. It
    reads correctly from the second step (a windowed count needs the window to
    fill), gives a continuous value instead of quantised jumps, and winds down
    smoothly when stepping stops (the growing silence acts as the interval).
    """

    def __init__(self) -> None:
        self.steps = 0
        self.last_step_time = -1000.0
        self._last_side_time = {"l": -1000.0, "r": -1000.0}
        self._intervals: deque[float] = deque(maxlen=CADENCE_SMOOTH_STEPS)

    def side_ready(self, side: str, now: float) -> bool:
        """True when this leg is past its per-leg debounce window."""
        return now - self._last_side_time.get(side, -1000.0) >= STEP_SIDE_MIN_INTERVAL

    def add(self, now: float, side: str | None = None) -> None:
        gap = now - self.last_step_time
        if 0.0 < gap < 2.0:  # gaps beyond ~2s are a fresh start, not a stride
            self._intervals.append(gap)
        self.steps += 1
        self.last_step_time = now
        if side is not None:
            self._last_side_time[side] = now

    def cadence(self, now: float) -> float:
        """Current pace in steps per minute; 0 once stepping has stopped."""
        if not self._intervals:
            return 0.0
        interval = statistics.median(self._intervals)
        silence = now - self.last_step_time
        if silence > max(3.0 * interval, CADENCE_RESET_SEC):
            self._intervals.clear()  # stopped: next steps start a fresh estimate
            return 0.0
        # A silence longer than the stride means we're slowing -- read it as the
        # current interval so the value tapers instead of holding then snapping.
        return 60.0 / max(interval, silence)


def _met_from_cadence(cadence: float) -> float:
    """Cadence (steps/min) -> METs, anchored to the CADENCE-Adults measurements:
    ~100 steps/min = 3 METs (moderate), then ~+1 MET per +10 steps/min (110->4,
    130->6). Below the anchor we interpolate down to the standing rest value."""
    if cadence <= 0.0:
        return REST_MET
    if cadence < CADENCE_MODERATE_SPM:
        return REST_MET + (MET_MODERATE - REST_MET) * (cadence / CADENCE_MODERATE_SPM)
    return MET_MODERATE + MET_PER_SPM_ABOVE * (cadence - CADENCE_MODERATE_SPM)


class _EffortEstimator:
    """Estimates instantaneous effort as a MET value, from motion alone.

    MET (metabolic equivalent) is normalised by body mass, so no player profile
    is needed here -- Godot multiplies by the player's weight to get calories.
    Effort is the strongest of four intensity reads -- stepping cadence
    (evidence-anchored, see _met_from_cadence), overall marching vigour,
    vertical squat work (which the other two can't see) and boxing work
    (punch rate + guard hold + slipping, which none of the others see) -- plus a
    bonus for jump activity, then smoothed so the calorie counter doesn't flicker.
    """

    def __init__(self) -> None:
        self._jumps: deque[float] = deque()    # recent jump timestamps
        self._punches: deque[float] = deque()  # recent punch timestamps
        self._lean_prev = 0.0
        self._lean_work = _LowPass()
        self._smooth = _LowPass()
        self.met = REST_MET

    def update(self, forward: float, cadence: float, jumped: bool,
               vertical_work: float, now: float, dt: float,
               punched: bool = False, guard: bool = False,
               lean: float = 0.0) -> float:
        if jumped:
            self._jumps.append(now)
        cutoff = now - EFFORT_WINDOW_SEC
        while self._jumps and self._jumps[0] < cutoff:
            self._jumps.popleft()
        jumps_per_min = len(self._jumps) * (60.0 / EFFORT_WINDOW_SEC)

        # Cadence, forward, squat work and boxing work are four windows on the
        # same effort; take whichever reads highest (arm-only work lifts forward
        # but not cadence; slow squats lift neither; boxing lifts none of them
        # much), then add the jump term on top as it is extra vertical work.
        met_cadence = _met_from_cadence(cadence)
        met_forward = REST_MET + FORWARD_MET_SPAN * forward
        met_squat = REST_MET + SQUAT_MET_GAIN * vertical_work
        met_box = self._boxing_met(punched, guard, lean, now, dt)
        raw = max(met_cadence, met_forward, met_squat, met_box) \
            + JUMP_MET_PER_MIN * jumps_per_min
        raw = _clamp(raw, REST_MET, MET_MAX)
        self.met = self._smooth(raw, _BandPass._alpha(EFFORT_SMOOTH_HZ, dt))
        return self.met

    def _boxing_met(self, punched: bool, guard: bool, lean: float,
                    now: float, dt: float) -> float:
        """Boxing intensity: punch rate over a rolling window, plus the static
        cost of holding a guard and the trunk work of slipping side to side.
        Anchored to the Compendium's bag / sparring / in-ring MET values (see
        PUNCH_MET_PER_MIN). Rest when the player is doing none of it."""
        if punched:
            self._punches.append(now)
        cutoff = now - PUNCH_WINDOW_SEC
        while self._punches and self._punches[0] < cutoff:
            self._punches.popleft()
        punches_per_min = len(self._punches) * (60.0 / PUNCH_WINDOW_SEC)
        # Lean speed (slips per second) smoothed, so a held lean costs nothing
        # but bobbing between guards does.
        lean_speed = abs(lean - self._lean_prev) / dt if dt > 0.0 else 0.0
        self._lean_prev = lean
        lean_work = self._lean_work(lean_speed,
                                    _BandPass._alpha(SQUAT_SPEED_SMOOTH_HZ, dt))
        met = REST_MET + PUNCH_MET_PER_MIN * punches_per_min \
            + SLIP_MET_GAIN * lean_work
        if guard:
            met += GUARD_MET
        return met

    def reset(self) -> None:
        self._jumps.clear()
        self._punches.clear()
        self._lean_prev = 0.0
        self._lean_work.reset()
        self._smooth.reset()
        self.met = REST_MET


def _ensure_model(variant: str) -> Path:
    """Returns the model bundle path, downloading it on first use.

    The ~5-30 MB .task bundles aren't committed to the repo, so a fresh clone
    (or picking a new --model size) fetches the official file automatically
    instead of dying with a manual-download instruction.
    """
    path = _model_path(variant)
    if path.exists():
        return path
    url = MODEL_URL.format(variant=variant)
    print(f"Pose model '{variant}' not found locally; downloading {url} ...")
    path.parent.mkdir(parents=True, exist_ok=True)
    import urllib.request
    tmp = path.with_suffix(".task.part")
    try:
        urllib.request.urlretrieve(url, tmp)
        tmp.replace(path)
    except Exception as exc:
        tmp.unlink(missing_ok=True)
        raise SystemExit(
            f"Could not download the pose model ({exc}). "
            f"Fetch it manually from {url} and save it as {path}."
        )
    print(f"Saved {path.name} ({path.stat().st_size / 1e6:.1f} MB).")
    return path


def _create_landmarker(variant: str = "full"):
    """Builds the MediaPipe PoseLandmarker (VIDEO mode). Shared by the live
    service and the offline video_to_features converter, so both extract
    landmarks identically."""
    model_path = _ensure_model(variant)
    return mp.tasks.vision.PoseLandmarker.create_from_options(
        mp.tasks.vision.PoseLandmarkerOptions(
            base_options=mp.tasks.BaseOptions(model_asset_path=str(model_path)),
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
        "--model", choices=MODEL_VARIANTS, default="full",
        help="Pose model size: lite = fastest (use if the HUD fps reads low), "
             "full = balanced default, heavy = most accurate but slow. "
             "Downloads automatically on first use.",
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
        "--no-preview", action="store_true",
        help=f"Don't stream the webcam preview to Godot (udp {PREVIEW_PORT}). The "
             "setup/countdown screen's live mirror goes dark, but pose control is "
             "unaffected. Use if you want to spend every cycle on pose inference.",
    )
    parser.add_argument(
        "--game", action="store_true",
        help="Managed mode, for launch from the game: hide the OpenCV preview "
             "window and let Godot switch the camera on/off (udp %d) instead of "
             "opening it immediately, so the webcam LED stays dark in menus. A "
             "camera that won't open reports its status to Godot instead of "
             "exiting. Run WITHOUT this flag to test the pose service alone." % COMMAND_PORT,
    )
    parser.add_argument(
        "--window", action="store_true",
        help="Force the OpenCV preview window even in --game mode (for debugging).",
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


def _open_camera(index: int) -> "_Camera | None":
    """Open the webcam and start its reader thread; None if it won't open.

    Used both at startup (standalone) and on a camera_on command (managed), so a
    webcam that's blocked or in use elsewhere is a recoverable state Godot can be
    told about, not a hard crash.
    """
    cam = _Camera(index)
    if not cam.opened:
        cam.release()
        return None
    cam.start()
    return cam


def _drain_commands(cmd_sock: socket.socket) -> tuple[str | None, bool, tuple | None]:
    """Drain Godot's command queue; return (last_camera_cmd, calibrate_requested,
    calib_cmd). Camera commands ("camera_on"/"camera_off") are keepalive-repeated,
    so only the most recent matters. "calibrate" starts a fresh capture. Godot also
    pushes the ACTIVE PROFILE's stored calibration so Python applies the right
    body: `{"cmd":"set_calibration","standing":x,"squat":y}` -> ("set", x, y), or
    `{"cmd":"clear_calibration"}` -> ("clear",). These are keepalive-repeated too;
    only the last is kept."""
    last: str | None = None
    calibrate = False
    calib_cmd: tuple | None = None
    while True:
        try:
            data, _ = cmd_sock.recvfrom(1024)
        except (BlockingIOError, OSError):
            break  # nothing queued (non-blocking) or the socket isn't bound
        try:
            msg = json.loads(data.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            continue
        cmd = msg.get("cmd")
        if cmd in ("camera_on", "camera_off"):
            last = cmd
        elif cmd == "calibrate":
            calibrate = True
        elif cmd == "set_calibration":
            try:
                calib_cmd = ("set", float(msg["standing"]), float(msg["squat"]))
            except (KeyError, TypeError, ValueError):
                pass
        elif cmd == "clear_calibration":
            calib_cmd = ("clear",)
    return last, calibrate, calib_cmd


def _idle_packet(steps: int, status: str) -> dict:
    """A zeroed control packet carrying just the service status (camera off /
    opening / error). Sent as a heartbeat while the webcam isn't streaming so
    Godot's is_receiving() stays true and it can show the right loading /
    permission state instead of assuming the whole service is dead."""
    return _build_packet(0.0, 0.0, False, 0.0, False, steps, 0.0, 0.0, 0.0,
                         status=status)


def main(args: argparse.Namespace | None = None) -> None:
    if args is None:
        args = _parse_args()
    # Managed mode = launched by the game (run.bat passes --game): no OpenCV
    # window, and the camera is switched on/off by Godot (COMMAND_PORT) rather
    # than opening immediately, so the webcam LED is dark in menus.
    managed = args.game
    show_window = (not managed) or args.window
    if show_window:
        # The release bundle ships opencv-headless (no GUI). Downgrade cleanly
        # instead of crashing if a window was requested anyway.
        try:
            cv2.namedWindow("MotionFit Pose (press q to quit, c to calibrate)")
        except cv2.error:
            print("OpenCV has no GUI support (headless build); "
                  "continuing without the preview window.")
            show_window = False

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    dest = (UDP_HOST, UDP_PORT)
    preview_dest = (UDP_HOST, PREVIEW_PORT)
    send_preview = not args.no_preview
    preview_interval = 1.0 / PREVIEW_FPS
    last_preview = 0.0

    # Godot -> Python commands (camera on/off). Non-blocking so it never stalls
    # the control loop; only acted on in managed mode (a standalone session
    # ignores stray commands so it isn't bossed around while you're testing).
    cmd_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    cmd_sock.setblocking(False)
    try:
        cmd_sock.bind((UDP_HOST, COMMAND_PORT))
    except OSError as exc:
        print(f"Camera command channel unavailable on udp {COMMAND_PORT} ({exc}); "
              "on/off control from the game is disabled.")

    landmarker = _create_landmarker(args.model)

    # Standalone: open the camera now (window + LED on, as before). Managed:
    # start idle and wait for Godot's camera_on so menus keep the webcam dark.
    cap: "_Camera | None" = None
    status = "idle"
    if not managed:
        cap = _open_camera(args.camera)
        if cap is None:
            raise SystemExit(
                f"Could not open camera index {args.camera}. "
                "Close other apps using the webcam, or pass --camera with another index."
            )
        status = "ready"

    forward_filter = OneEuroFilter(FORWARD_MIN_CUTOFF, FORWARD_BETA)
    turn_filter = OneEuroFilter(TURN_MIN_CUTOFF, TURN_BETA)
    state = ControlState()
    steps = StepCounter()
    effort = _EffortEstimator()
    punch_detector = _PunchDetector()  # left/right punch edges for Boxing
    # Per-user calibration: load a saved profile (personalises crouch depth + seeds
    # the standing reference) and keep a Calibrator ready to (re)capture on demand
    # -- 'c' in the preview window, or a {"cmd":"calibrate"} packet from Godot.
    calibrator = Calibrator()
    # Standalone owns calibration.json; in --game (managed) mode Godot is the source
    # of truth (per-profile) and pushes it via set_calibration, so don't auto-load.
    calibration = None if managed else Calibration.load()
    if calibration is not None:
        state.vertical.apply_calibration(calibration.standing_ext, calibration.squat_ext)
        print(f"Loaded calibration (squat range "
              f"{calibration.standing_ext - calibration.squat_ext:.2f} torso).")
    forward = 0.0
    turn = 0.0
    crouch = 0.0
    duck = 0.0
    lean = 0.0
    met = 0.0
    # Punches are one-frame edge events; latch the last throw so the HUD can show
    # it (with a fading glow) instead of a flash you'd miss.
    last_punch = ""
    last_punch_power = 0.0
    last_punch_kind = "straight"
    last_punch_time = -1000.0
    start_time = time.time()
    prev_ts = 0.0
    frame_seq = 0          # last camera frame we processed (latest-frame-wins)
    last_valid = -1000.0   # when a full valid pose was last measured
    lost_reset_done = True # filters start clean; nothing to reset until tracked
    fps_avg = 0.0          # smoothed loop rate + inference time for the HUD --
    infer_ms_avg = 0.0     # the first thing to check if control feels laggy
    last_heartbeat = 0.0   # throttles the idle status packet to ~10 Hz
    HEARTBEAT_SEC = 0.1

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

    if managed:
        print(f"MotionFit pose service (managed) -> udp://{UDP_HOST}:{UDP_PORT}. "
              f"Camera on/off driven by the game on udp {COMMAND_PORT}.")
    else:
        print(f"MotionFit pose service -> udp://{UDP_HOST}:{UDP_PORT}. Press 'q' to quit.")
    try:
        while True:
            # --- Godot camera commands (managed mode only) --------------------
            cam_cmd, calibrate_req, calib_cmd = _drain_commands(cmd_sock)
            if calibrate_req:
                calibrator.start()  # Godot asked to (re)calibrate
            if calib_cmd is not None:  # Godot pushed the active profile's calibration
                if calib_cmd[0] == "set":
                    state.vertical.apply_calibration(calib_cmd[1], calib_cmd[2])
                elif calib_cmd[0] == "clear":
                    state.vertical.clear_calibration()
            if managed and cam_cmd == "camera_on" and cap is None:
                # Tell Godot we're warming up BEFORE the (blocking) open, so the
                # setup screen can show "starting camera" while it happens.
                status = "opening"
                _send(sock, dest, _idle_packet(steps.steps, status))
                cap = _open_camera(args.camera)
                if cap is None:
                    status = "error"  # in use, or camera access blocked by the OS
                    print("camera_on: could not open the webcam (in use or blocked).")
                else:
                    status = "ready"
                    # Fresh session: clear filters so a re-open doesn't inherit
                    # stale motion, and reset the dt bookkeeping.
                    state.reset()
                    forward_filter.reset()
                    turn_filter.reset()
                    effort.reset()
                    forward = turn = crouch = duck = lean = met = 0.0
                    last_valid = -1000.0
                    lost_reset_done = True
                    prev_ts = 0.0
                    print("camera_on: webcam opened.")
            elif managed and cam_cmd == "camera_off" and cap is not None:
                cap.release()  # releases the device -> the webcam LED goes dark
                cap = None
                status = "idle"
                if show_window:
                    cv2.destroyAllWindows()
                print("camera_off: webcam released.")

            # --- No camera (idle/opening/error): heartbeat status, then wait ---
            if cap is None:
                now = time.time()
                if now - last_heartbeat >= HEARTBEAT_SEC:
                    _send(sock, dest, _idle_packet(steps.steps, status))
                    last_heartbeat = now
                time.sleep(0.03)  # don't spin the CPU while the camera is off
                continue

            # --- Camera running: capture + pose + control ---------------------
            frame_seq, frame = cap.read_latest(frame_seq)
            if frame is None:
                continue  # camera stalled; Godot's own timeout keeps things safe
            frame = cv2.flip(frame, 1)  # mirror, so screen matches your movements
            # Ship the CLEAN mirror to Godot's setup screen before any skeleton/HUD
            # is drawn on `frame` -- the in-game preview is a plain mirror by design.
            if send_preview and time.time() - last_preview >= preview_interval:
                _send_preview(sock, preview_dest, frame)
                last_preview = time.time()
            rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            mp_image = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
            now = time.time()
            dt = (now - prev_ts) if prev_ts else (1.0 / 30.0)
            prev_ts = now
            timestamp_ms = int((now - start_time) * 1000)
            infer_start = time.perf_counter()
            result = landmarker.detect_for_video(mp_image, timestamp_ms)
            infer_ms = (time.perf_counter() - infer_start) * 1000.0
            fps_avg += ((1.0 / dt if dt > 0 else 0.0) - fps_avg) * 0.1
            infer_ms_avg += (infer_ms - infer_ms_avg) * 0.1

            detected = bool(result.pose_landmarks)
            pose_ok = False
            pose_msg = ""
            jumped = False
            hands_up = False
            punch = ""
            guard = False
            lm = None
            wlm = None
            if detected:
                lm = result.pose_landmarks[0]
                wlm = result.pose_world_landmarks[0] if result.pose_world_landmarks else None
                if show_window:
                    _draw_pose(frame, lm)
                # Punches are upper-body and don't need the marching-stance gate, so
                # they're read from `detected` (like hands_up) -- a standing boxer
                # throwing a jab still lands even if the leg gate flickers.
                punch = punch_detector.update(lm, wlm, now, dt)
                # Once we're already tracking a valid stance, relax the leg-drop
                # gate so squatting down (knees fold up to the hips) stays valid
                # and reads as a crouch rather than dropping out with "STAND UP".
                standing = (now - last_valid) <= LOSS_GRACE_SEC
                pose_ok, pose_msg = _assess_pose(lm, standing)
                # The "ready" gesture is checked independently of the marching
                # stance -- you raise your hands to start BEFORE getting into
                # position, so it must not require pose_ok (which wants legs).
                hands_up = _detect_hands_up(lm)
                # Boxing defence, also upper-body and gated only on `detected`:
                # gloves-up block, and the waist lean that slips a punch. Lean is
                # low-passed here (it drives a pose, so it must be smooth) rather
                # than through the 1-Euro filters, which are owned by the
                # marching-stance path below.
                guard = _detect_guard(lm)
                lean = state.lean_lp(_lean_from_offset(_lean_offset(lm)),
                                     _BandPass._alpha(LEAN_SMOOTH_HZ, dt))

            if detected and pose_ok:
                forward, turn, jumped, crouch, duck = _compute_controls(
                    lm, wlm, state, forward_filter, turn_filter, steps, now, dt
                )
                status_text, status_color = "TRACKING", (0, 220, 0)
                last_valid = now
                lost_reset_done = False
                # Feed the calibrator when it's running -- leg_ext and fused_speed
                # are already in this frame's snapshot (both torso-normalised, so
                # the capture is distance-invariant). On completion, personalise
                # crouch + seed the standing reference, and persist for next time.
                # Frames with no usable leg geometry are skipped rather than fed a
                # 0.0 placeholder, which would drag the standing median down and
                # hand the squat phase an unbeatable minimum.
                if calibrator.active and state.feature_snapshot.get("leg_ok"):
                    snap = state.feature_snapshot
                    calibrator.update(snap.get("leg_ext", 0.0),
                                      snap.get("fused_speed", 0.0), dt)
                    if calibrator.state == Calibrator.DONE and calibrator.result:
                        calibration = calibrator.result
                        state.vertical.apply_calibration(calibration.standing_ext,
                                                         calibration.squat_ext)
                        # Standalone persists to calibration.json; in managed mode
                        # Godot saves the captured values per-profile (from the packet).
                        if not managed:
                            calibration.save()
                        print(f"Calibrated: squat range "
                              f"{calibration.standing_ext - calibration.squat_ext:.2f} torso"
                              + (f" -> saved {CALIB_PATH.name}." if not managed else "."))
            else:
                # Tracking dropped this frame. Detection blinks for a frame or
                # two all the time, so short losses are coasted through -- the
                # outputs decay gently and NO filter state is touched, making a
                # blink invisible in game. Only a sustained loss (past the grace
                # window) decays hard and resets the pipeline for a clean
                # reacquire. The decay is time-based, so behaviour doesn't
                # depend on the camera's frame rate.
                in_grace = (now - last_valid) <= LOSS_GRACE_SEC
                decay = math.exp(-dt / (HOLD_DECAY_SEC if in_grace else DROP_DECAY_SEC))
                forward *= decay
                turn *= decay
                crouch *= decay
                duck *= decay
                lean *= decay
                if not in_grace and not lost_reset_done:
                    state.reset()
                    forward_filter.reset()
                    turn_filter.reset()
                    punch_detector.reset()  # no phantom punch on reacquire
                    lost_reset_done = True
                if detected:
                    # Seen, but not in a valid stance: tell them how to fix it.
                    status_text, status_color = pose_msg, (0, 200, 255)  # amber
                else:
                    status_text, status_color = "NO BODY - step back into view", (60, 60, 255)

            cadence = steps.cadence(now)
            if detected and pose_ok:
                met = effort.update(forward, cadence, jumped,
                                    state.vertical.work_speed, now, dt,
                                    punched=bool(punch), guard=guard, lean=lean)
            elif (now - last_valid) <= LOSS_GRACE_SEC:
                met = effort.met  # hold effort through a blink -- no calorie dip
            else:
                # Not measuring: emit no effort so Godot banks no phantom calories.
                effort.reset()
                met = 0.0
            beat_now = metronome.update(now) if metronome is not None else False
            # Heart rate comes from a BLE wearable when --heart-rate is on; 0 means
            # no reading, and Godot then falls back to the motion-based estimate.
            hr = hr_monitor.current_bpm() if hr_monitor is not None else 0.0
            status = "ready"
            # Coaching line for the setup screen: empty once fully framed, else the
            # fix to make (the amber HUD instruction, or "STEP INTO VIEW" when no
            # body is detected at all). Godot gates the ready-gesture hold on this.
            ready_hint = "" if (detected and pose_ok) else \
                (pose_msg if detected else "STEP INTO VIEW")
            # On a completed calibration, ship the captured values so Godot can save
            # them to the active profile (0 when there's no result yet).
            calib_standing = calibrator.result.standing_ext if calibrator.result else 0.0
            calib_squat = calibrator.result.squat_ext if calibrator.result else 0.0
            packet = _build_packet(forward, turn, jumped, crouch,
                                   detected and pose_ok, steps.steps, cadence, met, hr,
                                   hands_up=hands_up, duck=duck,
                                   punch=punch, punch_power=punch_detector.power,
                                   punch_kind=punch_detector.kind,
                                   guard=guard, lean=lean,
                                   status=status, ready_hint=ready_hint,
                                   calib_state=calibrator.state, calib_prompt=calibrator.prompt,
                                   calib_progress=calibrator.progress,
                                   calib_standing=calib_standing, calib_squat=calib_squat)
            _send(sock, dest, packet)
            last_heartbeat = now
            # Recording is a standalone testing feature but doesn't need the drawn
            # frame, so it runs regardless of the window.
            if recorder is not None and detected:
                recorder.write(
                    ts=now, label=current_label, pose_ok=pose_ok, detected=detected,
                    packet=packet, landmarks=_landmarks_to_list(lm),
                    world=_world_to_list(wlm),
                    features=(state.feature_snapshot if pose_ok else None),
                    metronome=metronome,
                )

            if punch:  # latch the last throw so the HUD shows it with a fading glow
                last_punch = punch
                last_punch_power = punch_detector.power
                last_punch_kind = punch_detector.kind
                last_punch_time = now
            if show_window:
                _draw_hud(frame, forward, turn, jumped, crouch, duck, status_text,
                          status_color, steps.steps, cadence, met, state.active_label,
                          fps_avg, infer_ms_avg,
                          punch_side=last_punch, punch_power=last_punch_power,
                          punch_age=now - last_punch_time, hands_up=hands_up,
                          punch_kind=last_punch_kind, guard=guard, lean=lean,
                          knee_flex=state.feature_snapshot.get("knee_flex"))
                if hands_up:  # confirm the ready gesture registered, on-camera
                    _put_label(frame, "READY - HANDS UP", (frame.shape[1] // 2 - 130, 40),
                               0.7, (0, 220, 0))
                if calibrator.active or calibrator.state in (Calibrator.DONE, Calibrator.FAILED):
                    _draw_calibration_overlay(frame, calibrator)
                if recorder is not None:
                    _draw_recording_overlay(frame, recorder, current_label,
                                            metronome, beat_now, hr_monitor)
                cv2.imshow("MotionFit Pose (press q to quit, c to calibrate)", frame)
                key = cv2.waitKey(1) & 0xFF
                if key in (ord("q"), 27):
                    break
                if key == ord("c"):  # (re)run the ~10s calibration
                    calibrator.start()
                elif 32 <= key < 127:  # a printable key: maybe a move label
                    new_label = recording.label_for_key(chr(key))
                    if new_label is not None:
                        current_label = new_label
    finally:
        # stop the character and zero the effort so no calories accrue after exit
        _send(sock, dest, _build_packet(0.0, 0.0, False, 0.0, False, steps.steps,
                                        0.0, 0.0, 0.0, status="idle"))
        if recorder is not None:
            recorder.close()
            print(f"Recording saved: {recorder.path} ({recorder.frames} frames)")
        if hr_monitor is not None:
            hr_monitor.stop()
        if cap is not None:
            cap.release()
        landmarker.close()
        if show_window:
            cv2.destroyAllWindows()
        sock.close()
        cmd_sock.close()


def _assess_pose(lm, standing: bool = False) -> tuple[bool, str]:
    """Is the person in a valid standing position to measure from?

    Returns (ok, message); when not ok the message is a short on-screen
    instruction. Gating on this stops the tracker from emitting junk forward/step
    values when the user is out of frame, sitting, reclining, or otherwise not
    set up to march in place.

    `standing` = we were already tracking a valid stance on the previous frame.
    It relaxes the leg-drop check so a squat (which folds the knees up toward the
    hips) keeps being measured as a crouch instead of dropping out with "STAND UP";
    you still have to start from a full stand to acquire tracking in the first place.
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
    leg_drop_min = POSE_SQUAT_LEG_DROP if standing else POSE_MIN_LEG_DROP
    if (planted_knee_y - hip_cy) / torso_len < leg_drop_min:
        return False, "STAND UP"

    # Distance: keep the player in the band the tracker measures best. torso_len
    # is the shoulder-centre-to-hip-centre span in normalized image units, so it
    # doubles as an apparent-size / distance gauge.
    if torso_len > POSE_MAX_TORSO_FRAC:
        return False, "STEP BACK"
    # Once tracked, tolerate a shorter apparent torso: bowing toward the camera
    # (the duck gesture) foreshortens it, and losing tracking mid-duck would
    # freeze the control the bow is driving. Acquisition still needs full size.
    min_torso = POSE_MIN_TORSO_FRAC * (POSE_DUCK_TORSO_SCALE if standing else 1.0)
    if torso_len < min_torso:
        return False, "GET CLOSER"
    # A planted foot jammed against the bottom edge means you're framed too low --
    # stepping back brings the feet in, which gives the cleanest cadence.
    if (lm[L_ANKLE].visibility or 0.0) >= MIN_VISIBILITY and \
       (lm[R_ANKLE].visibility or 0.0) >= MIN_VISIBILITY and \
       max(lm[L_ANKLE].y, lm[R_ANKLE].y) > POSE_FEET_EDGE_Y:
        return False, "STEP BACK — SHOW YOUR FEET"
    return True, "TRACKING"


def _compute_controls(
    lm, wlm, state: ControlState, forward_filter: OneEuroFilter,
    turn_filter: OneEuroFilter, steps: StepCounter, now: float, dt: float,
) -> tuple[float, float, bool, float, float]:
    """Returns (forward, turn, jumped, crouch, duck) from pose landmarks.

    forward: confidence-weighted average of several body channels' band-passed
             speeds (both knees, both ankles, both wrists), each measured in a
             body-local frame relative to the hip. Averaging cancels per-joint
             noise; the body frame + band-pass reject camera tilt and turning.
    turn:    torso yaw from the shoulders' depth offset in metric world space --
             actually rotating your body to steer, robust to camera distance.
    jumped:  True on the frame a vertical launch is detected (an edge event).
    crouch:  squat depth 0.0 (upright) .. 1.0, from how far the planted foot has
             folded up toward the hip.
    duck:    forward bow of the torso 0.0 (upright) .. 1.0, from world-landmark
             torso pitch -- the mid-run "lean down" gesture, independent of the
             legs so it needs none of crouch's march/jump gating.
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
        duck = state.duck_lp(0.0, _BandPass._alpha(DUCK_SMOOTH_HZ, dt))
        state.feature_snapshot = {}
        return forward, turn, False, state.vertical.crouch, duck
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
        # Hysteresis: joining needs MIN_VISIBILITY, but an already-tracked joint
        # stays until it drops below the lower VIS_EXIT -- so a joint hovering
        # right at the threshold doesn't flap in and out of the fusion.
        threshold = VIS_EXIT if state.channel_active[name] else MIN_VISIBILITY
        if vis < threshold:
            state.channel_active[name] = False
            # Keep the filter state through short occlusions (a hand passing in
            # front, a flicker); only a real absence starts the channel over.
            if now - state.last_seen[name] > CHANNEL_GRACE_SEC:
                osc.reset()
            visible[name] = False
            footfalls[name] = False
            channels_snapshot[name] = {"value": 0.0, "speed": 0.0, "vis": round(vis, 3)}
            continue
        state.channel_active[name] = True
        state.last_seen[name] = now
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

    # --- Jump & crouch: from hip height and the legs ---------------------------
    # Computed BEFORE forward/steps because a squat (or a jump) has to be able to
    # veto them: a squat's down-up sweep and a jump's knee-tuck both move the legs
    # relative to the hip the way a march does, so they'd otherwise leak into
    # `forward`. hip_up is negated because image y grows downward, so up is negative.
    leg = _leg_geometry(lm, wlm, visible, hip_cy, torso_len)
    jumped = state.vertical.update(-hip_cy, leg, torso_len, dt, now)
    crouch = state.vertical.crouch

    # A squat is not a march. While crouching -- with a short hold that also covers
    # the rising half of the rep -- and while inside a jump, suppress the fused
    # march speed and the step counter. crouch's big, reliable hip drop wins the
    # tie, so the ambiguous leg sweep is read as the squat/jump it really is.
    squatting = crouch > CROUCH_MARCH_GATE
    if squatting:
        state.squat_active_until = now + SQUAT_MARCH_HOLD
    # Block the march for a squat (crouch-triggered hold) OR a jump (in_jump spans
    # the dip/launch/land). in_jump keys off the leg leaving the floor, NOT crouch,
    # so blanking crouch during a jump doesn't unblock the march -- the two were
    # coupled before and a jump leaked straight back into forward.
    march_blocked = now < state.squat_active_until or state.vertical.in_jump

    target_forward = 0.0
    if not march_blocked and fused_speed > FORWARD_THRESHOLD:
        target_forward = _clamp((fused_speed - FORWARD_THRESHOLD) * FORWARD_GAIN, 0.0, 1.0)
    forward = _clamp(forward_filter(target_forward, dt), 0.0, 1.0)

    # --- Steps: one per foot plant, ankle preferred, knees as fallback ---------
    # Only while actually moving forward -- otherwise a waist turn or fidget that
    # nudges the (often poorly tracked) legs would be miscounted as steps -- and
    # never while a squat or jump is vetoing the march (see march_blocked above;
    # the explicit guard stops steps immediately, before forward's filter decays).
    if forward > STEP_FORWARD_GATE and not march_blocked:
        for side in ("l", "r"):
            if visible.get(f"{side}_ankle"):
                rep = f"{side}_ankle"
            elif visible.get(f"{side}_knee"):
                rep = f"{side}_knee"
            else:
                continue
            # Two debounces: a global one (real steps of both feet alternate no
            # faster than this) and a per-leg one (the SAME foot needs longer
            # between plants, so a noisy single-leg wobble can't double-count).
            if footfalls.get(rep) and now - steps.last_step_time >= STEP_MIN_INTERVAL \
                    and steps.side_ready(side, now):
                steps.add(now, side)

    # No march->crouch veto here on purpose -- see the CROUCH_MARCH_GATE block.
    # The bilateral-knee gate already keeps a march from reading as a squat, and
    # every way of writing this veto either strangles real squats (raw fused speed,
    # which a squat produces too) or deadlocks (vetoed `forward`, which a false
    # crouch zeroes).

    legs = any(visible.get(n) for n in ("l_ankle", "r_ankle", "l_knee", "r_knee"))
    arms = visible.get("l_wrist") or visible.get("r_wrist")
    state.active_label = " + ".join(
        p for p in (("legs" if legs else ""), ("arms" if arms else "")) if p
    ) or "none"

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

    # --- Duck: torso pitched toward the camera = "lean down" ------------------
    # World landmarks are metric 3D, so the pitch is real geometry: how far the
    # hip->shoulder line has tipped along z (toward/away from the camera) versus
    # its vertical rise. Only the z component counts -- a sideways lean (steering
    # body language) keeps duck at 0 -- and |z| is used so the read doesn't hang
    # on MediaPipe's z sign convention. Legs play no part, so no march/jump gate.
    target_duck = 0.0
    if wlm is not None:
        sh_w_y = (wlm[L_SHOULDER].y + wlm[R_SHOULDER].y) * 0.5
        sh_w_z = (wlm[L_SHOULDER].z + wlm[R_SHOULDER].z) * 0.5
        hip_w_y = (wlm[L_HIP].y + wlm[R_HIP].y) * 0.5
        hip_w_z = (wlm[L_HIP].z + wlm[R_HIP].z) * 0.5
        rise = hip_w_y - sh_w_y          # shoulders above hips (world y grows down)
        pitch = math.degrees(math.atan2(abs(sh_w_z - hip_w_z), max(rise, 1e-6)))
        target_duck = _clamp(
            (pitch - DUCK_START_DEG) / (DUCK_FULL_DEG - DUCK_START_DEG), 0.0, 1.0
        )
    duck = state.duck_lp(target_duck, _BandPass._alpha(DUCK_SMOOTH_HZ, dt))

    # --- Feature snapshot for the recording harness ---------------------------
    # A flat, model-ready view of this frame's motion (see recording.py's
    # FEATURE_NAMES). Empty when not recording costs nothing; here it's cheap.
    # leg_ok tells consumers (the calibrator) that leg_ext is a real measurement
    # this frame, not the 0.0 placeholder for "couldn't see the legs". knee_flex is
    # extra diagnostic detail; it is not in recording.SCALAR_FEATURES, so the
    # recorded feature-vector schema (and any dataset already captured) is unchanged.
    state.feature_snapshot = {
        "fused_speed": round(fused_speed, 4),
        "leg_ext": round(leg.ext, 4) if leg is not None else 0.0,
        "leg_ok": leg is not None,
        "knee_flex": round(leg.knee_flex, 2) if (leg and leg.knee_flex is not None) else None,
        "crouch": round(crouch, 4),
        "duck": round(duck, 4),
        "forward": round(forward, 4),
        "turn": round(turn, 4),
        "cadence": round(steps.cadence(now), 2),
        "channels": channels_snapshot,
    }

    return forward, turn, jumped, crouch, duck


def _build_packet(forward: float, turn: float, jump: bool, crouch: float,
                  detected: bool, steps: int, cadence: float,
                  met: float, hr: float, hands_up: bool = False, duck: float = 0.0,
                  punch: str = "", punch_power: float = 0.0,
                  punch_kind: str = "straight", guard: bool = False,
                  lean: float = 0.0,
                  status: str = "ready", ready_hint: str = "",
                  calib_state: str = "idle", calib_prompt: str = "",
                  calib_progress: float = 0.0,
                  calib_standing: float = 0.0, calib_squat: float = 0.0) -> dict:
    """Assembles the Godot-bound packet (CONTEXT.md §9 schema).

    `hands_up`, `status`, `ready_hint` and the `calib_*` fields are
    keyword-only-by-default so the offline tools that call this
    (video_to_features.py) keep working unchanged.

    `status` is the service/camera state so Godot can show the right loading /
    permission UI even when no pose is streaming: "ready" (camera on, tracking),
    "idle" (camera off in menus), "opening" (warming up), "error" (open failed).

    `ready_hint` is the setup-screen coaching line: a short instruction to get
    into a valid, trackable stance ("STEP INTO VIEW", "SHOW YOUR LEGS", "STAND
    UP", "GET CLOSER", "STEP BACK", ...), or "" when the player is fully framed
    and ready. Godot's GameIntro gates the "raise your hands to start" hold on
    this being empty, so the camera is verified before a game begins.

    `calib_state` / `calib_prompt` / `calib_progress` drive the calibration setup
    UI: the state machine phase ("idle"/"still"/"squat"/"done"/"failed"), a short
    on-screen instruction, and a 0..1 progress for the current phase.
    """
    return {
        "forward": round(forward, 3),
        "turn": round(turn, 3),
        "jump": jump,
        "crouch": round(crouch, 3),
        "duck": round(duck, 3),  # forward bow / lean-down depth (world-landmark pitch)
        "walking": forward > 0.05,
        "detected": detected,
        "steps": steps,
        "cadence": round(cadence, 1),
        "met": round(met, 2),   # body-mass-independent effort; Godot -> calories
        "hr": round(hr, 1),     # heart rate bpm, 0 = no reading (motion fallback)
        "hands_up": hands_up,   # "ready" gesture: both hands above the head
        # Body motion, not a game move: the packet names what the body did and a
        # game decides what that means (Boxing reads the three below as its
        # punches and its guard -- see scenes/boxing/boxing_input.gd).
        "arm_extend": punch,    # "left"/"right" on the extension frame, else ""
        "arm_extend_power": round(punch_power, 3),  # 0..1 how hard it snapped out
        # The path the hand took out of its resting position -- "straight"
        # (forward), "hook" (a wide sideways arc) or "uppercut" (a rise from
        # below). The shape vocabulary is the classifier's; a game maps it onto
        # its own moves. Only meaningful on a frame where `arm_extend` is set; it
        # holds the last extension's value otherwise.
        "arm_extend_kind": punch_kind,
        "hands_front": guard,   # both hands raised in front of the face
        "lean": round(lean, 3),  # waist lean, -1 = on-screen left .. +1 right
        "status": status,       # service/camera state (see docstring); CONTEXT.md §9
        "ready_hint": ready_hint,  # setup coaching line; "" = framed and ready
        "calib_state": calib_state,      # calibration phase (see docstring)
        "calib_prompt": calib_prompt,    # calibration on-screen instruction
        "calib_progress": round(calib_progress, 3),  # 0..1 within the current phase
        # Captured leg extensions on a completed calibration (0 until then); Godot
        # persists these to the active profile.
        "calib_standing": round(calib_standing, 5),
        "calib_squat": round(calib_squat, 5),
        "ts": time.time(),
    }


class _PunchDetector:
    """Detects left/right punches as fast arm-extension EDGE events, mirroring the
    jump detector's shape (fire once on the throw, re-arm on the retract). Reach is
    read from the metric world landmarks (falling back to image landmarks) and
    normalised by torso length, so it's scale/distance invariant with no
    calibration. `power` carries the strength (0..1) of the punch that just fired.

    Handedness is the on-screen glove the player sees in the mirror: on the
    flipped frame MediaPipe's L_WRIST appears on the player's on-screen RIGHT and
    R_WRIST on their LEFT, so wrists are mapped to sides via PUNCH_SIDE_OF -- a
    "left" punch is the glove on the LEFT of their mirror image.

    Each throw also carries a TYPE in `kind` -- "straight", "hook" or "uppercut"
    -- classified from the path the glove took out of the guard (see
    `_classify`). It is a best-effort read that always yields one of the three,
    so an untidy punch still lands.
    """

    def __init__(self) -> None:
        self._reach = {"left": None, "right": None}   # smoothed wrist reach
        self._armed = {"left": True, "right": True}    # ready to fire (retracted)
        self._peak = {"left": 0.0, "right": 0.0}       # peak extend speed since re-arm
        self._last = {"left": -1e9, "right": -1e9}     # last fire time per hand
        # Where the glove sat (shoulder-relative, torso-normalised) while the
        # hand was armed -- the origin the throw's travel is measured from.
        self._rest = {"left": None, "right": None}
        self.power = 0.0
        self.kind = "straight"

    def reset(self) -> None:
        self.__init__()

    def update(self, lm, wlm, now: float, dt: float) -> str:
        """Returns the hand that punched this frame ("left"/"right"), or "" -- at
        most one per frame (the stronger, if both extend at once)."""
        pts = wlm if wlm is not None else lm
        if pts is None or dt <= 0.0:
            return ""

        def dist(a, b) -> float:
            return math.sqrt((a.x - b.x) ** 2 + (a.y - b.y) ** 2 + (a.z - b.z) ** 2)

        # Torso length (shoulder centre -> hip centre) is the normalising scale.
        torso = 0.5 * (dist(pts[L_SHOULDER], pts[L_HIP])
                       + dist(pts[R_SHOULDER], pts[R_HIP]))
        if torso < 1e-3:
            return ""

        fired = ""
        best_power = 0.0
        best_kind = "straight"
        for wrist_name, sh_i, wr_i in (("l_wrist", L_SHOULDER, L_WRIST),
                                       ("r_wrist", R_SHOULDER, R_WRIST)):
            side = PUNCH_SIDE_OF[wrist_name]   # on-screen glove for this wrist
            if (lm[wr_i].visibility or 0.0) < MIN_VISIBILITY:
                self._reach[side] = None   # lost the hand; don't fire on reacquire
                self._rest[side] = None
                continue
            # Glove position in the shoulder's frame, torso-normalised -- the
            # basis for both the reach (its length) and the throw's direction.
            off = ((pts[wr_i].x - pts[sh_i].x) / torso,
                   (pts[wr_i].y - pts[sh_i].y) / torso,
                   (pts[wr_i].z - pts[sh_i].z) / torso)
            reach = dist(pts[sh_i], pts[wr_i]) / torso
            prev = self._reach[side]
            if prev is None:
                self._reach[side] = reach
                self._rest[side] = off
                continue
            a = 1.0 - math.exp(-dt * PUNCH_SMOOTH_HZ)
            sm = prev + (reach - prev) * a
            speed = (sm - prev) / dt
            self._reach[side] = sm
            # Re-arm on the retract, and zero the peak so the NEXT throw is judged
            # on its own speed.
            if sm < PUNCH_RESET_EXTEND:
                self._armed[side] = True
                self._peak[side] = 0.0
                self._rest[side] = off   # glove is home; this is the throw's origin
            self._peak[side] = max(self._peak[side], speed)
            # Fire once the arm reaches full extension, provided it snapped out fast
            # at some point during the throw. Smoothing delays the reach a few frames
            # behind the speed peak, so the two are checked over the extension (peak
            # speed) rather than demanded on the same frame.
            if (self._armed[side] and sm >= PUNCH_EXTEND_MIN
                    and self._peak[side] >= PUNCH_SPEED_MIN
                    and (now - self._last[side]) >= PUNCH_MIN_INTERVAL):
                self._armed[side] = False
                self._last[side] = now
                p = _clamp((self._peak[side] - PUNCH_SPEED_MIN)
                           / (PUNCH_SPEED_MAX - PUNCH_SPEED_MIN), 0.0, 1.0)
                if p >= best_power:
                    best_power = p
                    best_kind = self._classify(self._rest[side], off)
                    fired = side
        if fired:
            self.power = best_power
            self.kind = best_kind
        return fired

    @staticmethod
    def _classify(rest, out) -> str:
        """Names the punch from how the glove travelled between its resting
        guard (`rest`) and full extension (`out`), both shoulder-relative and
        torso-normalised. Image/world axes: +x right, +y DOWN, -z toward camera.

        Forward travel is a STRAIGHT, a wide sideways arc is a HOOK, and a clear
        rise from below is an UPPERCUT. Whichever of the sideways/upward
        components clearly beats the forward one wins (PUNCH_TYPE_DOMINANCE);
        otherwise it's a straight, the forgiving default for a scrappy throw."""
        if rest is None:
            return "straight"
        lateral = abs(out[0] - rest[0])
        rise = rest[1] - out[1]          # +y is down, so a rise is a decrease
        forward = rest[2] - out[2]       # -z is toward the camera
        # An uppercut is checked first: it is the most distinctive shape (the
        # glove climbs), and a rising punch also travels forward a little.
        if rise >= PUNCH_UPPER_RISE and rise >= forward * PUNCH_TYPE_DOMINANCE \
                and rise >= lateral:
            return "uppercut"
        if lateral >= PUNCH_HOOK_LATERAL and lateral >= forward * PUNCH_TYPE_DOMINANCE:
            return "hook"
        return "straight"


def _detect_hands_up(lm) -> bool:
    """True while BOTH wrists are raised above the head -- the "ready" gesture the
    setup screen waits for before starting the countdown.

    Chosen because it's clearly distinct from marching (arms swing, but rarely
    above the face) so it can't fire by accident, and it reads from landmarks we
    already track. `y` grows downward in image space, so "above" means a smaller
    y than the nose. Godot times how long it's held and shows the progress ring.
    """
    for i in (NOSE, L_WRIST, R_WRIST):
        if (lm[i].visibility or 0.0) < MIN_VISIBILITY:
            return False
    nose_y = lm[NOSE].y
    return lm[L_WRIST].y < nose_y and lm[R_WRIST].y < nose_y


def _detect_guard(lm) -> bool:
    """True while BOTH gloves are up covering the face -- Boxing's block.

    The read is "hands high AND tucked in": each wrist above the shoulder line
    by GUARD_WRIST_RISE (so gloves are around chin/eye height, not resting at
    the chest) and within GUARD_WRIST_SPREAD of the shoulder centre horizontally
    (so arms flung out wide, or a punch at full extension, don't count as a
    block). Normalised by torso length / shoulder span, so it is distance
    invariant like the other signals.
    """
    for i in (L_SHOULDER, R_SHOULDER, L_HIP, R_HIP, L_WRIST, R_WRIST):
        if (lm[i].visibility or 0.0) < MIN_VISIBILITY:
            return False
    sh_cx = (lm[L_SHOULDER].x + lm[R_SHOULDER].x) * 0.5
    sh_cy = (lm[L_SHOULDER].y + lm[R_SHOULDER].y) * 0.5
    hip_cy = (lm[L_HIP].y + lm[R_HIP].y) * 0.5
    torso = abs(hip_cy - sh_cy)
    span = abs(lm[L_SHOULDER].x - lm[R_SHOULDER].x)
    if torso < 1e-3 or span < 1e-3:
        return False
    for wr in (L_WRIST, R_WRIST):
        # y grows downward, so "above the shoulders" is a smaller y.
        if (sh_cy - lm[wr].y) / torso < GUARD_WRIST_RISE:
            return False
        if abs(lm[wr].x - sh_cx) / span > GUARD_WRIST_SPREAD:
            return False
    return True


def _lean_offset(lm) -> float:
    """Raw waist lean: the shoulder centre's sideways offset from the hip centre
    in torso lengths. Negative = leaning to the player's on-screen LEFT (the
    frame is mirrored, matching the punch-side convention). 0 when the landmarks
    needed aren't trustworthy."""
    for i in (L_SHOULDER, R_SHOULDER, L_HIP, R_HIP):
        if (lm[i].visibility or 0.0) < MIN_VISIBILITY:
            return 0.0
    sh_cx = (lm[L_SHOULDER].x + lm[R_SHOULDER].x) * 0.5
    sh_cy = (lm[L_SHOULDER].y + lm[R_SHOULDER].y) * 0.5
    hip_cx = (lm[L_HIP].x + lm[R_HIP].x) * 0.5
    hip_cy = (lm[L_HIP].y + lm[R_HIP].y) * 0.5
    torso = math.hypot(sh_cx - hip_cx, sh_cy - hip_cy)
    if torso < 1e-3:
        return 0.0
    return (sh_cx - hip_cx) / torso


def _lean_from_offset(offset: float) -> float:
    """Shapes the raw waist offset into the -1..1 slip control: a deadzone for
    ordinary postural sway, then a gain so a committed lean reads as a full
    slip. Kept separate from `_lean_offset` so the deadzone is testable."""
    if abs(offset) < LEAN_DEADZONE:
        return 0.0
    signed = offset - LEAN_DEADZONE if offset > 0 else offset + LEAN_DEADZONE
    return _clamp(signed * LEAN_GAIN, -1.0, 1.0)


def _send(sock: socket.socket, dest, packet: dict) -> None:
    sock.sendto(json.dumps(packet).encode("utf-8"), dest)


def _send_preview(sock: socket.socket, dest, frame) -> None:
    """Encodes `frame` as a small JPEG and sends it to Godot's setup screen.

    Downscaled + moderately compressed so the whole image fits in one UDP
    datagram; failures (encode error, oversized frame, socket hiccup) are
    swallowed because the preview is cosmetic -- it must never disturb control.
    """
    small = cv2.resize(frame, (PREVIEW_WIDTH, PREVIEW_HEIGHT))
    ok, buf = cv2.imencode(".jpg", small, [cv2.IMWRITE_JPEG_QUALITY, PREVIEW_QUALITY])
    if not ok:
        return
    data = buf.tobytes()
    if len(data) > 60000:  # keep clear of the ~64 KB single-datagram ceiling
        return
    try:
        sock.sendto(data, dest)
    except OSError:
        pass


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
              duck: float,
              status_text: str, status_color, steps: int, cadence: float,
              met: float, sources: str = "none",
              fps: float = 0.0, infer_ms: float = 0.0,
              punch_side: str = "", punch_power: float = 0.0,
              punch_age: float = 1e9, hands_up: bool = False,
              punch_kind: str = "straight", guard: bool = False,
              lean: float = 0.0, knee_flex: float | None = None) -> None:
    # A translucent dark panel behind the text gives the labels a consistent
    # backdrop, so they read cleanly even when the camera is pointed at a bright
    # window or a white wall.
    panel = frame.copy()
    cv2.rectangle(panel, (6, 8), (392, 356), (0, 0, 0), -1)
    cv2.addWeighted(panel, 0.4, frame, 0.6, 0, frame)

    _put_label(frame, status_text, (12, 28), 0.62, status_color)
    _put_label(frame, f"forward {forward:.2f}", (12, 56), 0.6, (255, 255, 255))
    _put_label(frame, f"turn    {turn:+.2f}", (12, 80), 0.6, (255, 255, 255))
    # Jump flashes green on its launch frame; crouch bar fills as you squat.
    jump_color = (0, 220, 0) if jump else (255, 255, 255)
    _put_label(frame, f"jump    {'YES' if jump else '-'}", (12, 104), 0.6, jump_color)
    crouch_color = (0, 200, 255) if crouch > 0.2 else (255, 255, 255)
    duck_color = (0, 200, 255) if duck > 0.2 else (255, 255, 255)
    _put_label(frame, f"crouch  {crouch:.2f}", (12, 128), 0.6, crouch_color)
    _put_label(frame, f"duck {duck:.2f}", (190, 128), 0.6, duck_color)
    # The squat gate behind `crouch`: flexion of the LESS bent knee, and how far
    # open that leaves the gate. Squat and this should climb together; marching or
    # leaning should leave it at 0 no matter what the legs appear to be doing. Any
    # disagreement between this row and the crouch row above is the thing to tune
    # (CROUCH_KNEE_START / CROUCH_KNEE_FULL). "--" means no world landmarks or a
    # leg out of view, so there's no bilateral evidence and the gate is left open.
    if knee_flex is None:
        _put_label(frame, "knees   --     gate open", (12, 152), 0.55, (200, 200, 200))
    else:
        gate = _clamp((knee_flex - CROUCH_KNEE_START)
                      / (CROUCH_KNEE_FULL - CROUCH_KNEE_START), 0.0, 1.0)
        _put_label(frame, f"knees   {knee_flex:3.0f}deg  gate {gate:.2f}", (12, 152),
                   0.55, (0, 200, 255) if gate > 0.0 else (200, 200, 200))
    _put_label(frame, f"steps   {steps}", (12, 176), 0.6, (255, 255, 255))
    _put_label(frame, f"cadence {cadence:.0f}/min", (12, 200), 0.6, (255, 255, 255))
    _put_label(frame, f"effort  {met:.1f} MET", (12, 224), 0.6, (120, 255, 120))
    _put_label(frame, f"tracking {sources}", (12, 248), 0.5, (200, 200, 200))
    # Loop rate + model inference time. Below ~15 fps control gets noticeably
    # laggy -- that's the cue to relaunch with --model lite.
    perf_color = (200, 200, 200) if fps >= 15.0 else (0, 200, 255)
    _put_label(frame, f"{fps:.0f} fps  ({infer_ms:.0f} ms pose)", (12, 272),
               0.5, perf_color)

    # --- Boxing drivers ------------------------------------------------------
    # Punch is an EDGE event (fires one frame), so it's latched by the caller and
    # shown here as the LAST throw, with a white flash that fades over ~0.6s so a
    # fresh punch is obvious. Left glove = green, right = orange (BGR), matching
    # the ring's read. hands-up is the "ready" gesture the setup screen waits for.
    if punch_side:
        base = (0, 220, 0) if punch_side == "left" else (0, 170, 255)
        glow = _clamp(1.0 - punch_age * 1.6, 0.0, 1.0)
        col = tuple(int(b + (255 - b) * glow) for b in base)
        _put_label(frame,
                   f"punch   {punch_side.upper()} {punch_kind.upper()}"
                   f"  pow {punch_power:.2f}",
                   (12, 298), 0.55, col)
    else:
        _put_label(frame, "punch   -  (straight / hook / uppercut)", (12, 298),
                   0.5, (200, 200, 200))
    # Defence: the gloves-up block and the waist slip, drawn as a little
    # left/right meter so a lean is easy to check against the pose on camera.
    g_color = (0, 220, 0) if guard else (200, 200, 200)
    slot = int(round(_clamp(lean, -1.0, 1.0) * 4))
    meter = "".join("#" if i == slot else "-" for i in range(-4, 5))
    _put_label(frame, f"guard {'UP' if guard else '--'}   lean [{meter}] {lean:+.2f}",
               (12, 322), 0.55, g_color)
    hu_color = (0, 220, 0) if hands_up else (255, 255, 255)
    _put_label(frame, f"hands-up {'YES' if hands_up else 'no'}", (12, 346), 0.6,
               hu_color)


def _draw_calibration_overlay(frame, calibrator) -> None:
    """Center-screen calibration prompt + a progress bar for the current phase.

    Only drawn while calibrating (or briefly on done/failed), so it doesn't clutter
    normal play. Mirrors what Godot's setup screen shows from the packet's calib_*
    fields, so the standalone preview and the game read the same."""
    h, w = frame.shape[:2]
    done = calibrator.state == Calibrator.DONE
    failed = calibrator.state == Calibrator.FAILED
    color = (0, 220, 0) if done else (60, 60, 255) if failed else (0, 200, 255)
    text = calibrator.prompt
    (tw, _th), _ = cv2.getTextSize(text, cv2.FONT_HERSHEY_SIMPLEX, 0.9, 2)
    cx = w // 2
    _put_label(frame, text, (cx - tw // 2, h // 2 - 30), 0.9, color)
    if calibrator.active:  # a progress bar under the prompt
        bw, bh = 300, 16
        x0, y0 = cx - bw // 2, h // 2
        cv2.rectangle(frame, (x0, y0), (x0 + bw, y0 + bh), (255, 255, 255), 1)
        fill = int(bw * calibrator.progress)
        cv2.rectangle(frame, (x0, y0), (x0 + fill, y0 + bh), color, -1)


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
