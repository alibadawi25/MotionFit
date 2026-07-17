"""
Grass-blade billboard texture for HTerrain's detail layer (the waving grass).

Outputs grass_blades.png: a 256x256 RGBA clump of tapering blades rooted along
the BOTTOM edge (the detail shader treats UV y=1 as the root and y=0 as the
wind-blown tip, so tips point at the top of the image). Alpha is hard-edged —
the detail shader alpha-scissors at 0.5, so soft feathering would just erode
the blades.

Drawn at 4x and downscaled for clean edges.  Run:  python gen_grass_blades.py
"""

import numpy as np
from PIL import Image, ImageDraw

OUT_SIZE = 256
SS = 4                      # supersample factor
SIZE = OUT_SIZE * SS
SEED = 11
BLADES = 15

# Root -> tip colour ramps; a few drier yellow-green blades mixed in.
GREEN_ROOT, GREEN_TIP = (36, 58, 26), (108, 148, 66)
DRY_ROOT, DRY_TIP = (72, 78, 38), (152, 150, 82)


def draw_blade(draw, rng, x_root, height, width, lean, dry):
    """One blade: a tapering quadratic-bezier ribbon from the bottom edge."""
    root = np.array([x_root, SIZE + 2.0])
    tip = np.array([x_root + lean, SIZE - height])
    ctrl = np.array([x_root + lean * 0.25, SIZE - height * 0.55])
    steps = 14
    left, right = [], []
    for i in range(steps + 1):
        t = i / steps
        p = (1 - t) ** 2 * root + 2 * (1 - t) * t * ctrl + t ** 2 * tip
        # Tangent of the bezier -> perpendicular for the ribbon width.
        d = 2 * (1 - t) * (ctrl - root) + 2 * t * (tip - ctrl)
        n = np.array([-d[1], d[0]])
        n /= max(np.linalg.norm(n), 1e-6)
        w = width * (1.0 - t) ** 0.8 + 0.5 * SS  # taper to a point
        left.append(tuple(p + n * w))
        right.append(tuple(p - n * w))
    root_c, tip_c = (DRY_ROOT, DRY_TIP) if dry else (GREEN_ROOT, GREEN_TIP)
    # Per-blade brightness jitter so the clump doesn't read as one flat green.
    gain = rng.uniform(0.82, 1.12)
    # Draw as stacked segments so colour ramps root->tip.
    for i in range(steps):
        t = (i + 0.5) / steps
        c = tuple(
            int(np.clip((root_c[k] + (tip_c[k] - root_c[k]) * t) * gain, 0, 255))
            for k in range(3)
        )
        quad = [left[i], left[i + 1], right[i + 1], right[i]]
        draw.polygon(quad, fill=c + (255,))


def main():
    rng = np.random.default_rng(SEED)
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    # Back-to-front: back blades slightly darker (cheap depth cue).
    order = sorted(range(BLADES), key=lambda i: rng.random())
    for idx, _ in enumerate(order):
        x = (idx + rng.uniform(0.15, 0.85)) / BLADES * SIZE
        height = rng.uniform(0.55, 0.98) * SIZE
        width = rng.uniform(2.4, 4.2) * SS
        lean = rng.uniform(-0.22, 0.22) * SIZE
        dry = rng.random() < 0.25
        draw_blade(draw, rng, x, height, width, lean, dry)

    out = img.resize((OUT_SIZE, OUT_SIZE), Image.LANCZOS)
    # Re-harden alpha after the resize: scissor threshold is 0.5, and half-faded
    # fringe pixels there would darken tips against the sky.
    a = np.asarray(out).copy()
    rgb_max = a[..., :3].max(axis=-1)
    a[..., 3] = np.where(a[..., 3] > 96, 255, 0)
    a[rgb_max == 0, 3] = 0
    Image.fromarray(a, "RGBA").save("grass_blades.png")
    print(f"Wrote grass_blades.png ({OUT_SIZE}x{OUT_SIZE})")


if __name__ == "__main__":
    main()
