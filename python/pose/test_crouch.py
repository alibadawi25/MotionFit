"""Behavioural check for the crouch signal, without a webcam.

`check.sh` proves the project parses and `tools/test.sh` proves the Godot
platform layer behaves; this is the same idea for the one pose channel whose
failures are silent -- crouch reads a plausible number whether or not it is
measuring what we think, so only a scenario test catches a regression.

Landmark frames are synthesised from a simple sagittal body model (hip at the
world origin, since MediaPipe world landmarks are hip-centred; y down, z
forward) and fed straight through `_compute_controls`. Each leg is a thigh and a
shank hinged at the knee, driven by one knee-flexion angle, so folding the leg
raises the foot exactly the way a real squat or high knee does. The image
landmarks are the orthographic (x, y) projection of the same body -- dropping z
is what makes a forward lean foreshorten the torso on screen, which is the
specific illusion that used to read as a squat.

Run:  python python/pose/test_crouch.py       (exit 0 = pass)
"""
from __future__ import annotations

import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import pose_server as ps  # noqa: E402

L_THIGH, L_SHANK, TORSO = 0.42, 0.43, 0.50   # metres, roughly adult proportions
HALF_HIP, HALF_SHOULDER = 0.09, 0.18
SCALE = 0.5          # metres -> normalized frame units (torso ~0.25 of frame)
HIP_IMG_Y = 0.30     # where the hip sits in frame when standing
DT = 1.0 / 30.0
NLM = 33
WARMUP = int(1.0 / DT)   # the first second is the baselines acquiring; ignore it


class _P:
    __slots__ = ("x", "y", "z", "visibility")

    def __init__(self, x=0.0, y=0.0, z=0.0, visibility=1.0):
        self.x, self.y, self.z, self.visibility = x, y, z, visibility


def _leg(flex_deg: float, side_x: float):
    """Knee and ankle world positions for one leg at `flex_deg` of knee flexion.

    The thigh swings forward by flex/2 and the shank back by flex/2, so the angle
    at the knee is exactly (180 - flex) and the foot rises as the leg folds.
    """
    h = math.radians(flex_deg) * 0.5
    ky, kz = L_THIGH * math.cos(h), L_THIGH * math.sin(h)
    return ((side_x, ky, kz),
            (side_x, ky + L_SHANK * math.cos(h), kz - L_SHANK * math.sin(h)))


def frame(flex_l: float = 3.0, flex_r: float = 3.0, pitch: float = 0.0,
          bob: float = 0.0, vis_l_ankle: float = 1.0, vis_r_ankle: float = 1.0):
    """One (image_landmarks, world_landmarks) pair. Angles in degrees."""
    w = [_P() for _ in range(NLM)]
    p = math.radians(pitch)
    sh_y, sh_z = -TORSO * math.cos(p), -TORSO * math.sin(p)
    w[ps.L_SHOULDER] = _P(-HALF_SHOULDER, sh_y, sh_z)
    w[ps.R_SHOULDER] = _P(HALF_SHOULDER, sh_y, sh_z)
    w[ps.L_HIP], w[ps.R_HIP] = _P(-HALF_HIP), _P(HALF_HIP)
    for flex, sx, ki, ai in ((flex_l, -HALF_HIP, ps.L_KNEE, ps.L_ANKLE),
                             (flex_r, HALF_HIP, ps.R_KNEE, ps.R_ANKLE)):
        (kx, ky, kz), (ax, ay, az) = _leg(flex, sx)
        w[ki], w[ai] = _P(kx, ky, kz), _P(ax, ay, az)
    for idx in (ps.L_WRIST, ps.R_WRIST):        # hands still at chest height
        w[idx] = _P(0.0, -0.25, 0.0)

    lm = [_P(0.5 + q.x * SCALE, HIP_IMG_Y + (q.y + bob) * SCALE) for q in w]
    lm[ps.L_ANKLE].visibility = vis_l_ankle
    lm[ps.R_ANKLE].visibility = vis_r_ankle
    return lm, w


def run(frames, drop_world: bool = False) -> list[float]:
    """Drive _compute_controls over `frames`, returning the crouch per frame."""
    state = ps.ControlState()
    ff = ps.OneEuroFilter(ps.FORWARD_MIN_CUTOFF, ps.FORWARD_BETA)
    tf = ps.OneEuroFilter(ps.TURN_MIN_CUTOFF, ps.TURN_BETA)
    steps, now, out = ps.StepCounter(), 0.0, []
    for lm, wlm in frames:
        now += DT
        _f, _t, _j, crouch, _d = ps._compute_controls(
            lm, None if drop_world else wlm, state, ff, tf, steps, now, DT)
        out.append(crouch)
    return out


def _ramp(t, t0, t1, a, b):
    return a if t <= t0 else b if t >= t1 else a + (b - a) * (t - t0) / (t1 - t0)


# --- Scenarios ---------------------------------------------------------------

def sc_stand(seconds: float = 5.0):
    return [frame() for _ in range(int(seconds / DT))]


def sc_lean():
    """Stand, bow forward to 35 degrees, hold, come back up, stand."""
    out = []
    for i in range(int(8.0 / DT)):
        t = i * DT
        pitch = (0.0 if t < 2.0 else
                 _ramp(t, 2.0, 3.0, 0.0, 35.0) if t < 3.0 else
                 35.0 if t < 4.5 else
                 _ramp(t, 4.5, 5.5, 35.0, 0.0) if t < 5.5 else 0.0)
        out.append(frame(pitch=pitch))
    return out


def sc_march(flicker: bool = False):
    """March in place at ~2 steps/s: alternating high knee plus a hip bob."""
    out = []
    for i in range(int(8.0 / DT)):
        phase = 2.0 * math.pi * (i * DT)
        lift = 0.5 * (1.0 + math.sin(phase))
        vl = vr = 1.0
        if flicker:
            # The swing ankle blinks out at the top of its lift -- what the old
            # ankle->knee fallback turned into an instant, saturated crouch.
            vl = 0.2 if lift > 0.9 else 1.0
            vr = 0.2 if (1.0 - lift) > 0.9 else 1.0
        out.append(frame(3.0 + 85.0 * lift, 3.0 + 85.0 * (1.0 - lift),
                         bob=-0.02 * abs(math.sin(phase)),
                         vis_l_ankle=vl, vis_r_ankle=vr))
    return out


def sc_squat():
    """Stand, descend into a deep (100 degree) squat, hold, stand back up."""
    out = []
    for i in range(int(7.0 / DT)):
        t = i * DT
        flex = (3.0 if t < 2.0 else
                _ramp(t, 2.0, 3.0, 3.0, 100.0) if t < 3.0 else
                100.0 if t < 4.5 else
                _ramp(t, 4.5, 5.5, 100.0, 3.0) if t < 5.5 else 3.0)
        # A real squat leans the torso forward for balance -- the coupling that
        # made an image-space measure partly cancel its own signal.
        out.append(frame(flex, flex, pitch=0.30 * flex))
    return out


def sc_legs_lost():
    """A squat with every leg landmark blanked for one second in the middle."""
    out = []
    for i, (lm, wlm) in enumerate(sc_squat()):
        if 3.0 <= i * DT < 4.0:
            for idx in (ps.L_KNEE, ps.R_KNEE, ps.L_ANKLE, ps.R_ANKLE):
                lm[idx].visibility = 0.0
        out.append((lm, wlm))
    return out


# --- Checks ------------------------------------------------------------------

CHECKS = [
    # name,                    frames,          world?, want, limit
    ("stand still",            sc_stand,        True,  "max",  0.05),
    ("lean 35deg and return",  sc_lean,         True,  "max",  0.05),
    ("march in place",         sc_march,        True,  "max",  0.10),
    ("march + ankle blink",    lambda: sc_march(True), True, "max", 0.10),
    ("deep squat",             sc_squat,        True,  "peak", 0.80),
    # Degraded: the model returned no world landmarks, so the knee gate is open
    # and only the depth term is left. Squats must still register; the false
    # positives must still stay down.
    ("stand, no world lms",    sc_stand,        False, "max",  0.05),
    ("march, no world lms",    lambda: sc_march(True), False, "max", 0.10),
    ("squat, no world lms",    sc_squat,        False, "peak", 0.50),
]


def main() -> int:
    print(f"{'scenario':<24}{'crouch':>9}   verdict")
    print("-" * 52)
    failures = 0
    for name, build, world, kind, limit in CHECKS:
        series = run(build(), drop_world=not world)[WARMUP:]
        value = max(series)
        ok = value <= limit if kind == "max" else value >= limit
        failures += 0 if ok else 1
        arrow = "<=" if kind == "max" else ">="
        print(f"{name:<24}{value:>9.3f}   {'PASS' if ok else 'FAIL'}"
              f"  (want {kind} {arrow} {limit})")

    # Losing the legs must decay crouch out, not hold it or spike it, and must
    # recover cleanly once they come back.
    series = run(sc_legs_lost())
    blackout = series[int(3.1 / DT):int(4.0 / DT)]
    after = max(series[int(4.2 / DT):])
    ok = blackout[-1] < 0.05 and after > 0.80
    failures += 0 if ok else 1
    print(f"{'legs lost mid-squat':<24}{blackout[-1]:>9.3f}   "
          f"{'PASS' if ok else 'FAIL'}  (decays to <= 0.05, recovers to {after:.2f})")

    print("-" * 52)
    print("crouch OK" if not failures else f"{failures} check(s) FAILED")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
