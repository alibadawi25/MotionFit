"""
Procedural tileable grass texture generator for Godot's Zylann HTerrain plugin.

Outputs two seamless PNGs sized SIZE x SIZE:
  grass_albedo_bump.png : RGB = albedo color, A = height/bump  (HTerrain "ground albedo+bump")
  grass_normal_rough.png: RGB = tangent-space normal, A = roughness (HTerrain "ground normal+roughness")

Everything is tileable (fractal value noise wraps on both axes, normals computed
with wraparound gradients), so it repeats cleanly when the terrain shader tiles it.

Run:  python gen_grass.py
"""

import numpy as np
from PIL import Image

SIZE = 1024          # texture resolution
SEED = 7             # change for a different grass pattern
BUMP_STRENGTH = 2.5  # normal-map intensity


def smoothstep(t):
    return t * t * (3.0 - 2.0 * t)


def tileable_value_noise(size, period, seed):
    """Bilinear value noise on a `period`x`period` lattice, wrapped -> seamless."""
    rng = np.random.default_rng(seed)
    grid = rng.random((period, period)).astype(np.float32)

    coords = np.linspace(0.0, period, size, endpoint=False, dtype=np.float32)
    i0 = np.floor(coords).astype(np.int32) % period
    i1 = (i0 + 1) % period
    frac = smoothstep(coords - np.floor(coords)).astype(np.float32)

    # separable bilinear interpolation
    gx0 = grid[i0][:, i0]          # not used directly; build via outer indexing below
    # rows = y axis, cols = x axis
    top = grid[np.ix_(i0, i0)]
    # build with proper axis handling:
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
    """Fractal (multi-octave) tileable noise, normalized to 0..1."""
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
    """Tangent-space normal map from a height field, using wraparound gradients."""
    dx = (np.roll(h, -1, axis=1) - np.roll(h, 1, axis=1)) * 0.5
    dy = (np.roll(h, -1, axis=0) - np.roll(h, 1, axis=0)) * 0.5
    nx = -dx * strength
    ny = -dy * strength
    nz = np.ones_like(h)
    length = np.sqrt(nx * nx + ny * ny + nz * nz)
    nx, ny, nz = nx / length, ny / length, nz / length
    # pack to 0..1 (Godot expects +Y-up green channel)
    r = (nx * 0.5 + 0.5)
    g = (ny * 0.5 + 0.5)
    b = (nz * 0.5 + 0.5)
    return np.stack([r, g, b], axis=-1)


def lerp_color(c0, c1, t):
    c0 = np.array(c0, dtype=np.float32)
    c1 = np.array(c1, dtype=np.float32)
    return c0[None, None, :] + (c1[None, None, :] - c0[None, None, :]) * t[..., None]


def main():
    # --- noise layers -------------------------------------------------------
    patches = fbm(SIZE, base_period=6,  octaves=4, seed=SEED)        # large color patches
    blades  = fbm(SIZE, base_period=64, octaves=5, seed=SEED + 100)  # fine blade detail
    speckle = fbm(SIZE, base_period=180, octaves=3, seed=SEED + 200) # tiny high-freq grain

    # --- albedo: blend a few grass greens by the patch noise ----------------
    dark_green  = (48, 78, 34)
    mid_green   = (78, 116, 52)
    light_green = (120, 158, 74)
    dry_green   = (140, 140, 78)

    col = lerp_color(dark_green, mid_green, smoothstep(patches))
    col = col + (lerp_color(mid_green, light_green, blades) - col) * 0.35
    # occasional dry/yellow patches where large noise is high
    dry_mask = smoothstep(np.clip((patches - 0.62) / 0.25, 0, 1))
    col = col + (lerp_color(mid_green, dry_green, blades) - col) * dry_mask[..., None] * 0.5
    # fine per-blade darkening + grain
    col *= (0.82 + 0.18 * blades)[..., None]
    col *= (0.94 + 0.06 * speckle)[..., None]
    col = np.clip(col, 0, 255).astype(np.uint8)

    # --- height/bump: blades stand proud, patches give gentle undulation ----
    height = 0.55 * blades + 0.30 * patches + 0.15 * speckle
    height -= height.min(); height /= max(height.max(), 1e-6)
    height_u8 = (height * 255).astype(np.uint8)

    albedo = np.dstack([col, height_u8])
    Image.fromarray(albedo, "RGBA").save("grass_albedo_bump.png")

    # --- normal from the bump height, roughness in alpha --------------------
    nrm = normal_from_height(height, BUMP_STRENGTH)
    # grass is rough; vary slightly, drier patches a touch rougher
    rough = 0.86 + 0.10 * (1.0 - blades) + 0.04 * dry_mask
    rough = np.clip(rough, 0, 1)
    nrm_u8 = np.clip(nrm * 255, 0, 255).astype(np.uint8)
    normal = np.dstack([nrm_u8, (rough * 255).astype(np.uint8)])
    Image.fromarray(normal, "RGBA").save("grass_normal_rough.png")

    print(f"Wrote grass_albedo_bump.png and grass_normal_rough.png ({SIZE}x{SIZE})")


if __name__ == "__main__":
    main()
