"""Export a ZOMBIE variant of the low-poly character as a game-ready GLB.

The zombie reuses the exact rig, geometry and glTF builder from export_glb.py
(so it stays a single source of truth for the body) but swaps in:
  - sickly desaturated-green skin, matted dark hair, tattered dark clothes,
    dark boots and pale dead eyes (the colour globals are patched before build),
  - a tall, gaunt body (low weight-for-height -> thin limbs, height near the
    scale cap so it looms over the player),
  - three bespoke, deliberately unsettling animation clips instead of the human
    idle/walk/jump/crouch:
        "shamble" - a hunched, arms-out, limping lurch (the chase gait),
        "lunge"   - a one-shot forward grab-thrust (played when it catches you),
        "idle"    - a slow menacing sway with the head lolling.

Run:  python export_zombie_glb.py                 -> zombie.glb (next to this file)
      python export_zombie_glb.py --out ../zombie/zombie.glb

Kept separate from export_glb.py so the player generator (CharacterFactory) is
untouched and low-risk; this only imports its reusable pieces.
"""
import argparse
import math

import export_glb as base
from export_glb import Character, Clip, build, to_gltf_dict, write_glb, q_axis, q_mul


# --- zombie look -------------------------------------------------------------
ZOMBIE_SKIN = (0.46, 0.53, 0.40)      # sickly grey-green, desaturated
ZOMBIE_HAIR = (0.07, 0.06, 0.05)      # matted near-black
ZOMBIE_TOP = (0.17, 0.21, 0.19)       # grimy dark teal-grey (tattered shirt)
ZOMBIE_BOTTOM = (0.11, 0.11, 0.12)    # filthy dark trousers
ZOMBIE_EYES = (0.90, 0.90, 0.70)      # pale dead eyes (patched into build)
ZOMBIE_SHOES = (0.09, 0.09, 0.10)     # dark boots (patched into build)

# --- posture (radians) — the whole feel lives here, so it's easy to tune -----
# Positive TORSO_HUNCH pitches the chest forward over the legs; a NEGATIVE
# ARM_REACH swings the arms up and out to the FRONT (+Z, toward the camera the
# zombie faces) into the classic outstretched reach — positive would hide them
# down behind the body. Verified by screenshot.
TORSO_HUNCH = 0.52
ARM_REACH = -1.42
ELBOW_BEND = -0.55
HEAD_DROOP = 0.22


def rot_xyz(c, node, xs, ys, zs):
    """A single combined rotation channel (pitch X, yaw Y, roll Z) per keyframe.
    Clip only ships single-axis helpers, but a node may carry just one rotation
    channel — so for the hunched, lolling zombie (which needs pitch AND roll on
    the torso/neck at once) we compose the quaternion ourselves and feed the
    Clip's channel writer directly."""
    q = []
    for ax, ay, az in zip(xs, ys, zs):
        qq = q_mul(q_axis((0, 0, 1), az), q_mul(q_axis((0, 1, 0), ay), q_axis((1, 0, 0), ax)))
        q += list(qq)
    c._channel(node, "rotation", q, "VEC4")


def _const(n, v):
    return [v] * n


def zombie_shamble(b, nd):
    """The chase gait: hunched forward, arms reaching, one leg stiff and dragging
    while the other steps — a limping, off-balance lurch. Loops."""
    c = Clip(b, "shamble", 1.5, n=32)
    A = c.phase()
    n = c.n

    # heavy, uneven bob: a base two-beat plus an extra dip as the stiff leg plants
    c.trans_y(nd["root"], 0.0,
              [-0.03 * abs(math.cos(a)) - 0.025 * max(0.0, math.sin(a)) for a in A])

    # torso hunched forward with a slow drunken roll
    c_pitch = [TORSO_HUNCH + 0.05 * math.sin(2 * a) for a in A]
    c_roll = [0.09 * math.sin(a) for a in A]
    rot_xyz(c, nd["torso"], c_pitch, _const(n, 0.0), c_roll)

    # head drooping and lolling side to side, slightly out of sync with the torso
    rot_xyz(c, nd["neck"],
            [HEAD_DROOP + 0.06 * math.sin(a * 0.5) for a in A],
            [0.10 * math.sin(a * 0.5) for a in A],
            [0.22 * math.sin(a * 0.7 + 1.0) for a in A])

    # arms held out reaching, swaying loosely; elbows hang in a slack claw
    c.rot_x(nd["shL"], [ARM_REACH + 0.16 * math.sin(a) for a in A])
    c.rot_x(nd["shR"], [ARM_REACH - 0.16 * math.sin(a) for a in A])
    c.rot_x(nd["elL"], [ELBOW_BEND - 0.10 * abs(math.sin(a)) for a in A])
    c.rot_x(nd["elR"], [ELBOW_BEND - 0.10 * abs(math.sin(a + math.pi)) for a in A])

    # legs: LEFT is the stiff drag (small swing, knee near-locked), RIGHT steps.
    swing = [math.sin(a) for a in A]
    c.rot_x(nd["hipL"], [0.14 + s * 0.18 for s in swing])
    c.rot_x(nd["kneeL"], [0.06 + max(0.0, s) * 0.18 for s in swing])   # barely bends -> drags
    c.rot_x(nd["hipR"], [-s * 0.50 for s in swing])
    c.rot_x(nd["kneeR"], [0.14 + max(0.0, -s) * 0.95 for s in swing])  # real stride bend
    return c


def zombie_lunge(b, nd):
    """One-shot grab: the whole body thrusts forward, arms shoot straight out and
    the head rears back to bite. Non-looping; the game plays it once on the catch."""
    c = Clip(b, "lunge", 0.7, n=24)
    P = c.progress()
    n = c.n

    def thrust(p):   # 0 -> peak around p=0.45 -> settle
        return base.smoothstep(0.0, 0.35, p) * (1.0 - base.smoothstep(0.55, 1.0, p))

    T = [thrust(p) for p in P]

    c.trans_y(nd["root"], 0.0, [0.06 * t for t in T])
    # torso drives even further forward into the grab
    rot_xyz(c, nd["torso"], [TORSO_HUNCH + 0.55 * t for t in T],
            _const(n, 0.0), _const(n, 0.0))
    # head rears up (negative pitch) as the jaws open
    rot_xyz(c, nd["neck"], [HEAD_DROOP - 0.55 * t for t in T],
            _const(n, 0.0), _const(n, 0.0))
    # arms punch straight out (further front); elbows straighten from the claw
    c.rot_x(nd["shL"], [ARM_REACH - 0.25 * t for t in T])
    c.rot_x(nd["shR"], [ARM_REACH - 0.25 * t for t in T])
    c.rot_x(nd["elL"], [ELBOW_BEND + 0.55 * t for t in T])
    c.rot_x(nd["elR"], [ELBOW_BEND + 0.55 * t for t in T])
    # legs plant and shove forward
    c.rot_x(nd["hipL"], [0.30 * t for t in T])
    c.rot_x(nd["hipR"], [-0.30 * t for t in T])
    c.rot_x(nd["kneeL"], [0.10 + 0.20 * t for t in T])
    c.rot_x(nd["kneeR"], [0.10 + 0.20 * t for t in T])
    return c


def zombie_idle(b, nd):
    """A slow, heavy menace-sway with the head lolling and arms hanging forward —
    for the moment before the chase begins. Loops."""
    c = Clip(b, "idle", 4.2, n=28)
    A = c.phase()
    n = c.n

    c.trans_y(nd["root"], 0.0, [math.sin(a) * 0.012 for a in A])
    rot_xyz(c, nd["torso"], [TORSO_HUNCH * 0.85 + 0.04 * math.sin(a) for a in A],
            _const(n, 0.0), [0.07 * math.sin(a * 0.5) for a in A])
    rot_xyz(c, nd["neck"], [HEAD_DROOP + 0.05 * math.sin(a * 0.5) for a in A],
            [0.12 * math.sin(a * 0.4) for a in A],
            [0.26 * math.sin(a * 0.6) for a in A])
    c.rot_x(nd["shL"], [ARM_REACH * 0.7 + 0.08 * math.sin(a) for a in A])
    c.rot_x(nd["shR"], [ARM_REACH * 0.7 - 0.08 * math.sin(a) for a in A])
    c.rot_x(nd["elL"], _const(n, ELBOW_BEND - 0.1))
    c.rot_x(nd["elR"], _const(n, ELBOW_BEND - 0.1))
    c.rot_x(nd["hipL"], [0.05 * math.sin(a) for a in A])
    c.rot_x(nd["hipR"], [-0.05 * math.sin(a) for a in A])
    c.rot_x(nd["kneeL"], _const(n, 0.06))
    c.rot_x(nd["kneeR"], _const(n, 0.06))
    return c


def build_zombie(out_path):
    # Patch the colour globals build() reads for eyes/shoes, then restore them so
    # importing this module can't leak zombie colours into a later player build.
    saved_eyes, saved_shoes = base.EYE_COLOR, base.SHOE_COLOR
    base.EYE_COLOR, base.SHOE_COLOR = ZOMBIE_EYES, ZOMBIE_SHOES
    try:
        ch = Character(sex="male", age=48, height_cm=196.0, weight_kg=52.0,
                       hair="short", hair_color=ZOMBIE_HAIR,
                       top="tshirt", top_color=ZOMBIE_TOP,
                       bottom="pants", bottom_color=ZOMBIE_BOTTOM,
                       skin=ZOMBIE_SKIN)
        b, root = build(ch, clip_builders=(zombie_shamble, zombie_lunge, zombie_idle))
    finally:
        base.EYE_COLOR, base.SHOE_COLOR = saved_eyes, saved_shoes
    d = to_gltf_dict(b, root)
    write_glb(out_path, d, bytes(b.buffer))


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--out", default="zombie.glb")
    args = p.parse_args()
    build_zombie(args.out)
