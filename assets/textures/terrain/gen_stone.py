"""
Procedural tileable MOUNTAIN ROCK and ICED ROCK textures for Zylann HTerrain.

Built for steep cliffs / peaks: sharp ridged fractures, anisotropic strata
(rock layering), rugged relief -- not tiled cobblestone.

Outputs (SIZE x SIZE, seamless):
  stone_albedo_bump.png       RGB=albedo, A=height/bump
  stone_normal_rough.png      RGB=normal, A=roughness
  iced_stone_albedo_bump.png  RGB=albedo, A=height/bump
  iced_stone_normal_rough.png RGB=normal, A=roughness

Run:  python gen_stone.py
"""

import numpy as np
from PIL import Image

SIZE = 1024
SEED = 23


# ---------------------------------------------------------------- noise utils
def smoothstep(t):
    return t * t * (3.0 - 2.0 * t)


def value_noise(size, period_x, period_y, seed):
    """Tileable bilinear value noise with independent X/Y periods (anisotropy)."""
    rng = np.random.default_rng(seed)
    grid = rng.random((period_y, period_x)).astype(np.float32)

    cx = np.linspace(0.0, period_x, size, endpoint=False, dtype=np.float32)
    cy = np.linspace(0.0, period_y, size, endpoint=False, dtype=np.float32)
    x0 = np.floor(cx).astype(np.int32) % period_x
    x1 = (x0 + 1) % period_x
    y0 = np.floor(cy).astype(np.int32) % period_y
    y1 = (y0 + 1) % period_y
    fx = smoothstep(cx - np.floor(cx))[None, :]
    fy = smoothstep(cy - np.floor(cy))[:, None]

    a = grid[np.ix_(y0, x0)]
    b = grid[np.ix_(y0, x1)]
    c = grid[np.ix_(y1, x0)]
    d = grid[np.ix_(y1, x1)]
    top = a + (b - a) * fx
    bot = c + (d - c) * fx
    return (top + (bot - top) * fy).astype(np.float32)


def fbm(size, px, py, octaves, seed):
    total = np.zeros((size, size), dtype=np.float32)
    amp, freq, norm = 1.0, 1, 0.0
    for o in range(octaves):
        total += amp * value_noise(size, px * freq, py * freq, seed + o * 17)
        norm += amp
        amp *= 0.5
        freq *= 2
    total /= norm
    total -= total.min(); total /= max(total.max(), 1e-6)
    return total


def ridged(size, px, py, octaves, seed, sharp=1.0):
    """Ridged multifractal -> sharp mountain-fracture ridge lines."""
    total = np.zeros((size, size), dtype=np.float32)
    amp, freq, norm = 1.0, 1, 0.0
    for o in range(octaves):
        n = value_noise(size, px * freq, py * freq, seed + o * 17)
        r = 1.0 - np.abs(2.0 * n - 1.0)   # ridge at the 0.5 crossings
        r = r ** sharp
        total += amp * r
        norm += amp
        amp *= 0.5
        freq *= 2
    total /= norm
    total -= total.min(); total /= max(total.max(), 1e-6)
    return total


def normal_from_height(h, strength):
    dx = (np.roll(h, -1, axis=1) - np.roll(h, 1, axis=1)) * 0.5
    dy = (np.roll(h, -1, axis=0) - np.roll(h, 1, axis=0)) * 0.5
    nx, ny, nz = -dx * strength, -dy * strength, np.ones_like(h)
    length = np.sqrt(nx * nx + ny * ny + nz * nz)
    return np.stack([nx / length * 0.5 + 0.5,
                     ny / length * 0.5 + 0.5,
                     nz / length * 0.5 + 0.5], axis=-1)


def lerp_color(c0, c1, t):
    c0 = np.array(c0, dtype=np.float32)
    c1 = np.array(c1, dtype=np.float32)
    return c0[None, None, :] + (c1[None, None, :] - c0[None, None, :]) * t[..., None]


def save_rgba(rgb_u8, alpha01, path):
    a = np.clip(alpha01 * 255, 0, 255).astype(np.uint8)
    Image.fromarray(np.dstack([rgb_u8, a]), "RGBA").save(path)


# ------------------------------------------------------------------ mountain
def build_stone():
    # strata: wide horizontal-ish rock bands, wavered by noise so they aren't straight
    band_warp = fbm(SIZE, 4, 4, 6, SEED + 10)
    yy = np.linspace(0, 1, SIZE, dtype=np.float32)[:, None] * np.ones((1, SIZE), np.float32)
    strata = 0.5 + 0.5 * np.sin((yy * 9.0 + band_warp * 2.2) * np.pi * 2.0)
    strata = smoothstep(strata)

    facets   = fbm(SIZE, 6, 5, 5, SEED)             # broad craggy shape
    detail   = fbm(SIZE, 40, 40, 5, SEED + 100)     # rock grain
    # anisotropic fractures: taller than wide -> vertical cliff cracks
    cracks_a = ridged(SIZE, 10, 22, 5, SEED + 200, sharp=3.0)
    cracks_b = ridged(SIZE, 26, 14, 4, SEED + 250, sharp=3.0)
    crack = np.maximum(cracks_a, cracks_b) ** 2      # thin sharp fracture lines
    speck  = fbm(SIZE, 180, 180, 3, SEED + 300)

    # --- albedo: cool granite grays, strata shading, dark fractures ---
    rock_dark  = (74, 74, 78)
    rock_mid   = (120, 118, 118)
    rock_light = (168, 165, 160)
    rock_warm  = (128, 116, 104)

    col = lerp_color(rock_dark, rock_mid, smoothstep(facets))
    col = col + (lerp_color(rock_mid, rock_light, detail) - col) * 0.5
    warm_mask = smoothstep(np.clip((facets - 0.6) / 0.3, 0, 1))
    col = col + (lerp_color(rock_mid, rock_warm, detail) - col) * warm_mask[..., None] * 0.35
    col *= (0.85 + 0.15 * strata)[..., None]        # strata banding
    col *= (0.92 + 0.08 * speck)[..., None]
    col *= (1.0 - 0.5 * crack)[..., None]           # fractures darken
    col_u8 = np.clip(col, 0, 255).astype(np.uint8)

    # --- height: facets + strata relief, fractures carved in ---
    height = 0.5 * facets + 0.25 * detail + 0.12 * strata
    height -= 0.5 * crack
    height -= height.min(); height /= max(height.max(), 1e-6)

    nrm = normal_from_height(height, 5.0)           # strong rugged relief
    nrm_u8 = np.clip(nrm * 255, 0, 255).astype(np.uint8)
    rough = np.clip(0.80 + 0.14 * detail - 0.1 * crack, 0.45, 1.0)

    save_rgba(col_u8, height, "stone_albedo_bump.png")
    save_rgba(nrm_u8, rough, "stone_normal_rough.png")
    print("Wrote stone_albedo_bump.png + stone_normal_rough.png")
    return col.astype(np.float32), height, crack, detail, strata


# ----------------------------------------------------------------- iced rock
def build_iced_stone(col_s, h_s, crack, detail, strata):
    # snow/ice settles on ledges (up-facing = higher normal.z ~ flatter) and in cracks
    flat = smoothstep(np.clip((h_s - 0.35) / 0.5, 0, 1))     # higher ground = ledges
    patch = fbm(SIZE, 5, 5, 4, SEED + 800)
    ice = np.clip(0.55 * flat + 0.4 * patch + 0.35 * crack, 0, 1)
    ice = smoothstep(ice)
    frost = fbm(SIZE, 130, 130, 4, SEED + 850)

    snow_hi = np.array([236, 244, 250], dtype=np.float32)   # bright snow
    snow_lo = np.array([196, 214, 230], dtype=np.float32)   # shaded blue ice
    ice_rgb = snow_lo[None, None, :] + (snow_hi - snow_lo)[None, None, :] * patch[..., None]

    col = col_s + (ice_rgb - col_s) * ice[..., None]
    col += (frost[..., None] * 16.0) * ice[..., None]       # sparkle
    col_u8 = np.clip(col, 0, 255).astype(np.uint8)

    # snow/ice smooths and fills relief
    height = h_s * (1.0 - 0.55 * ice) + 0.1 * frost * ice
    height -= height.min(); height /= max(height.max(), 1e-6)

    nrm = normal_from_height(height, 3.5)
    nrm_u8 = np.clip(nrm * 255, 0, 255).astype(np.uint8)

    rock_rough = np.clip(0.80 + 0.14 * detail, 0.45, 1.0)
    ice_rough = np.clip(0.25 + 0.15 * frost, 0.1, 0.5)      # snow/ice smoother
    rough = rock_rough * (1.0 - ice) + ice_rough * ice

    save_rgba(col_u8, height, "iced_stone_albedo_bump.png")
    save_rgba(nrm_u8, rough, "iced_stone_normal_rough.png")
    print("Wrote iced_stone_albedo_bump.png + iced_stone_normal_rough.png")


def main():
    col, h, crack, detail, strata = build_stone()
    build_iced_stone(col, h, crack, detail, strata)
    print(f"Done ({SIZE}x{SIZE})")


if __name__ == "__main__":
    main()
