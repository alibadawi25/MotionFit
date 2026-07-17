"""
Procedural tileable beach-sand texture generator for Godot's Zylann HTerrain plugin.

Outputs two seamless PNGs sized SIZE x SIZE (same packing as gen_grass.py):
  sand_albedo_bump.png : RGB = albedo color, A = height/bump
  sand_normal_rough.png: RGB = tangent-space normal, A = roughness

Look: warm shoreline sand — broad tonal drifts, wind ripples (noise-warped
banding so they wander instead of printing straight lines), and fine grain.

Run:  python gen_sand.py
"""

import numpy as np
from PIL import Image

SIZE = 1024
SEED = 31
BUMP_STRENGTH = 2.0


def smoothstep(t):
    return t * t * (3.0 - 2.0 * t)


def tileable_value_noise(size, period, seed):
    rng = np.random.default_rng(seed)
    grid = rng.random((period, period)).astype(np.float32)
    coords = np.linspace(0.0, period, size, endpoint=False, dtype=np.float32)
    i0 = np.floor(coords).astype(np.int32) % period
    i1 = (i0 + 1) % period
    frac = smoothstep(coords - np.floor(coords)).astype(np.float32)
    a = grid[np.ix_(i0, i0)]
    b = grid[np.ix_(i0, i1)]
    c = grid[np.ix_(i1, i0)]
    d = grid[np.ix_(i1, i1)]
    fx = frac[None, :]
    fy = frac[:, None]
    top = a + (b - a) * fx
    bot = c + (d - c) * fx
    return (top + (bot - top) * fy).astype(np.float32)


def fbm(size, base_period, octaves, seed):
    total = np.zeros((size, size), dtype=np.float32)
    amp, freq, norm = 1.0, 1, 0.0
    for o in range(octaves):
        total += amp * tileable_value_noise(size, base_period * freq, seed + o * 17)
        norm += amp
        amp *= 0.5
        freq *= 2
    total /= norm
    total -= total.min()
    total /= max(total.max(), 1e-6)
    return total


def normal_from_height(h, strength):
    dx = (np.roll(h, -1, axis=1) - np.roll(h, 1, axis=1)) * 0.5
    dy = (np.roll(h, -1, axis=0) - np.roll(h, 1, axis=0)) * 0.5
    nx = -dx * strength
    ny = -dy * strength
    nz = np.ones_like(h)
    length = np.sqrt(nx * nx + ny * ny + nz * nz)
    nx, ny, nz = nx / length, ny / length, nz / length
    return np.stack([nx * 0.5 + 0.5, ny * 0.5 + 0.5, nz * 0.5 + 0.5], axis=-1)


def lerp_color(c0, c1, t):
    c0 = np.array(c0, dtype=np.float32)
    c1 = np.array(c1, dtype=np.float32)
    return c0[None, None, :] + (c1[None, None, :] - c0[None, None, :]) * t[..., None]


def main():
    # --- noise layers -------------------------------------------------------
    drifts = fbm(SIZE, base_period=5, octaves=4, seed=SEED)          # broad tone drifts
    grain = fbm(SIZE, base_period=200, octaves=3, seed=SEED + 50)    # per-grain speckle
    warp = fbm(SIZE, base_period=8, octaves=3, seed=SEED + 100)      # ripple domain warp

    # Wind ripples: sine banding along Y, wandered by the warp noise so the
    # bands drift and merge like real sand instead of printing straight lines.
    # Whole-number band count keeps it tileable.
    yy = np.linspace(0.0, 1.0, SIZE, endpoint=False, dtype=np.float32)[:, None]
    ripple_phase = yy * 26.0 * 2.0 * np.pi + (warp - 0.5) * 9.0
    ripples = 0.5 + 0.5 * np.sin(ripple_phase)
    ripples = ripples.astype(np.float32) * (0.55 + 0.45 * drifts)  # fade in the flats

    # --- albedo -------------------------------------------------------------
    base_sand = (184, 163, 118)
    light_sand = (203, 184, 141)
    wet_sand = (156, 135, 96)

    col = lerp_color(base_sand, light_sand, smoothstep(drifts))
    damp_mask = smoothstep(np.clip((0.42 - drifts) / 0.42, 0, 1))
    col = col + (lerp_color(base_sand, wet_sand, damp_mask) - col) * damp_mask[..., None] * 0.6
    col *= (0.92 + 0.08 * ripples)[..., None]   # ripple crests catch light
    col *= (0.93 + 0.07 * grain)[..., None]     # granular sparkle
    col = np.clip(col, 0, 255).astype(np.uint8)

    # --- height/bump --------------------------------------------------------
    height = 0.28 * ripples + 0.42 * drifts + 0.30 * grain
    height -= height.min()
    height /= max(height.max(), 1e-6)
    height_u8 = (height * 255).astype(np.uint8)

    Image.fromarray(np.dstack([col, height_u8]), "RGBA").save("sand_albedo_bump.png")

    # --- normal + roughness -------------------------------------------------
    nrm = normal_from_height(height, BUMP_STRENGTH)
    rough = 0.78 + 0.10 * (1.0 - grain) + 0.06 * damp_mask
    rough = np.clip(rough, 0, 1)
    normal = np.dstack([
        np.clip(nrm * 255, 0, 255).astype(np.uint8),
        (rough * 255).astype(np.uint8),
    ])
    Image.fromarray(normal, "RGBA").save("sand_normal_rough.png")

    print(f"Wrote sand_albedo_bump.png and sand_normal_rough.png ({SIZE}x{SIZE})")


if __name__ == "__main__":
    main()
