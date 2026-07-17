"""
Procedural tileable textures for the Zombie Run graveyard props.

Same packing convention as assets/textures/terrain/gen_stone.py:
  <name>_albedo_bump.png    RGB=albedo, A=height/bump
  <name>_normal_rough.png   RGB=normal, A=roughness

Sets (SIZE x SIZE, seamless):
  grave   weathered limestone slab — mottling, lichen, rain streaks
  bark    dead tree bark — deep vertical fissures
  wood    rotten fence wood — grey grain, dark rot streaks
  crypt   large block masonry — recessed mortar, per-block tone, grime
  dirt    trodden path — dark earth, pebbles, wheel ruts
  rubble  fieldstone rubble wall — irregular stones, dark joints, moss

The runner scene is near-black with red fog, so albedos are baked a touch
brighter (mean ~0.2-0.5) than the old flat colors; materials tint them down.

Run:  python gen_props.py
"""

import numpy as np
from PIL import Image

SIZE = 512
SEED = 7717


# ---------------------------------------------------------------- noise utils
def smoothstep(t):
    return t * t * (3.0 - 2.0 * t)


def value_noise(size, period_x, period_y, seed):
    """Tileable bilinear value noise with independent X/Y periods."""
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
    total = np.zeros((size, size), dtype=np.float32)
    amp, freq, norm = 1.0, 1, 0.0
    for o in range(octaves):
        n = value_noise(size, px * freq, py * freq, seed + o * 17)
        r = 1.0 - np.abs(2.0 * n - 1.0)
        r = r ** sharp
        total += amp * r
        norm += amp
        amp *= 0.5
        freq *= 2
    total /= norm
    total -= total.min(); total /= max(total.max(), 1e-6)
    return total


def worley(size, gx, gy, seed):
    """Periodic Worley: returns (F1, F2, cell-id-value), distances in cell units.
    One jittered point per cell, 3x3 neighborhood (plenty for art use)."""
    rng = np.random.default_rng(seed)
    jx = rng.random((gy, gx)).astype(np.float32)
    jy = rng.random((gy, gx)).astype(np.float32)
    cid = rng.random((gy, gx)).astype(np.float32)

    u = np.linspace(0.0, 1.0, size, endpoint=False, dtype=np.float32)
    X = np.tile(u[None, :], (size, 1))
    Y = np.tile(u[:, None], (1, size))
    cx = np.floor(X * gx).astype(np.int32)
    cy = np.floor(Y * gy).astype(np.int32)

    d1 = np.full((size, size), 1e9, dtype=np.float32)
    d2 = np.full((size, size), 1e9, dtype=np.float32)
    idv = np.zeros((size, size), dtype=np.float32)
    for dj in (-1, 0, 1):
        for di in (-1, 0, 1):
            ci = cx + di
            cj = cy + dj
            wi = ci % gx
            wj = cj % gy
            px = (ci + jx[wj, wi]) / gx
            py = (cj + jy[wj, wi]) / gy
            dx = (X - px) * gx
            dy = (Y - py) * gy
            dd = dx * dx + dy * dy
            closer = dd < d1
            d2 = np.where(closer, d1, np.minimum(d2, dd))
            idv = np.where(closer, cid[wj, wi], idv)
            d1 = np.where(closer, dd, d1)
    return np.sqrt(d1), np.sqrt(d2), idv


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


def save_set(name, col, height, rough, normal_strength):
    height = height - height.min()
    height /= max(height.max(), 1e-6)
    col_u8 = np.clip(col, 0, 255).astype(np.uint8)
    a8 = np.clip(height * 255, 0, 255).astype(np.uint8)
    Image.fromarray(np.dstack([col_u8, a8]), "RGBA").save(f"{name}_albedo_bump.png")

    nrm = normal_from_height(height, normal_strength)
    nrm_u8 = np.clip(nrm * 255, 0, 255).astype(np.uint8)
    r8 = np.clip(rough * 255, 0, 255).astype(np.uint8)
    Image.fromarray(np.dstack([nrm_u8, r8]), "RGBA").save(f"{name}_normal_rough.png")
    print(f"Wrote {name}_albedo_bump.png + {name}_normal_rough.png")


# ------------------------------------------------------------------ 1. grave
def build_grave():
    """Weathered limestone: pale mottled face, lichen colonies, rain streaks."""
    mottle = fbm(SIZE, 5, 5, 5, SEED)
    grain = fbm(SIZE, 36, 36, 4, SEED + 40)
    # rain streaks: tall thin darkening running down the face (down = +y)
    streaks = fbm(SIZE, 22, 3, 4, SEED + 80)
    # lichen colonies: clumped blobs, only where the threshold passes
    lich_field = fbm(SIZE, 9, 9, 4, SEED + 120)
    lichen = smoothstep(np.clip((lich_field - 0.72) / 0.12, 0.0, 1.0))
    pit_f1, _, pit_id = worley(SIZE, 18, 18, SEED + 160)
    pits = smoothstep(np.clip(1.0 - pit_f1 / 0.22, 0.0, 1.0))  # small round pits
    pits *= (pit_id > 0.55).astype(np.float32)                 # only some cells pit

    stone_dark = (96, 96, 92)
    stone_mid = (138, 136, 128)
    stone_light = (172, 168, 156)
    lichen_col = (96, 112, 74)

    col = lerp_color(stone_dark, stone_mid, smoothstep(mottle))
    col = col + (lerp_color(stone_mid, stone_light, grain) - col) * 0.45
    col *= (0.82 + 0.18 * streaks)[..., None]
    col *= (1.0 - 0.25 * pits)[..., None]
    col = col + (np.array(lichen_col, np.float32)[None, None, :] - col) * lichen[..., None] * 0.55

    height = 0.55 * mottle + 0.3 * grain - 0.3 * pits + 0.15 * lichen
    rough = np.clip(0.82 + 0.1 * grain + 0.08 * lichen, 0.6, 1.0)
    save_set("grave", col, height, rough, 3.0)


# ------------------------------------------------------------------- 2. bark
def build_bark():
    """Dead bark: deep vertical fissures, grey-brown, bone-dry."""
    fissure = ridged(SIZE, 18, 4, 5, SEED + 200, sharp=2.2)   # tall thin ridges
    plates = fbm(SIZE, 10, 3, 4, SEED + 240)                  # vertical plates
    grain = fbm(SIZE, 48, 12, 3, SEED + 280)

    bark_deep = (34, 27, 22)
    bark_mid = (64, 54, 44)
    bark_pale = (98, 88, 74)                                  # weathered wood shows

    col = lerp_color(bark_deep, bark_mid, smoothstep(plates))
    col = col + (lerp_color(bark_mid, bark_pale, grain) - col) * 0.4
    col *= (1.0 - 0.55 * fissure ** 2)[..., None]             # fissures near-black

    height = 0.6 * plates + 0.3 * grain - 0.7 * fissure ** 2
    rough = np.clip(0.9 + 0.08 * grain, 0.7, 1.0)
    save_set("bark", col, height, rough, 4.5)


# ------------------------------------------------------------------- 3. wood
def build_wood():
    """Rotten fence wood: silvered grain, rot streaks, splits."""
    grain = fbm(SIZE, 40, 5, 4, SEED + 300)                   # fine vertical grain
    boards = fbm(SIZE, 6, 2, 3, SEED + 340)                   # broad tone shifts
    rot_field = fbm(SIZE, 7, 4, 4, SEED + 380)
    rot = smoothstep(np.clip((rot_field - 0.68) / 0.16, 0.0, 1.0))
    splits = ridged(SIZE, 10, 2, 4, SEED + 420, sharp=3.0) ** 2

    wood_dark = (52, 45, 38)
    wood_mid = (94, 86, 74)
    wood_silver = (128, 122, 112)
    rot_col = (40, 38, 30)

    col = lerp_color(wood_dark, wood_mid, smoothstep(boards))
    col = col + (lerp_color(wood_mid, wood_silver, grain) - col) * 0.65
    col = col + (np.array(rot_col, np.float32)[None, None, :] - col) * rot[..., None] * 0.5
    col *= (1.0 - 0.4 * splits)[..., None]

    height = 0.5 * grain + 0.3 * boards - 0.55 * splits - 0.25 * rot
    rough = np.clip(0.86 + 0.1 * grain, 0.65, 1.0)
    save_set("wood", col, height, rough, 3.5)


# ------------------------------------------------------------------ 4. crypt
def build_crypt():
    """Large block masonry: 4 offset rows, recessed mortar, grime + moss."""
    rows, cols = 4, 3
    u = np.linspace(0.0, 1.0, SIZE, endpoint=False, dtype=np.float32)
    U = np.tile(u[None, :], (SIZE, 1))
    V = np.tile(u[:, None], (1, SIZE))
    warp = (fbm(SIZE, 9, 9, 3, SEED + 500) - 0.5) * 0.012
    Uw, Vw = U + warp, V + warp

    row = np.floor(Vw * rows)
    Ush = Uw + (np.mod(row, 2)) * (0.5 / cols)
    colid = np.floor(Ush * cols)
    fx = Ush * cols - colid
    fy = Vw * rows - row
    # distance to the nearest mortar line, as a fraction of the mortar width
    mw_x, mw_y = 0.045, 0.09                                  # mortar half-widths
    dx = np.minimum(fx, 1.0 - fx) / mw_x
    dy = np.minimum(fy, 1.0 - fy) / mw_y
    block = smoothstep(np.clip(np.minimum(dx, dy), 0.0, 1.0))  # 0 mortar, 1 block

    # stable per-block random tone (periodic thanks to the mods)
    bid = np.mod(row, rows) * 57.0 + np.mod(colid, cols + 1) * 131.0
    tone = np.mod(np.sin(bid * 12.9898) * 43758.5453, 1.0).astype(np.float32)

    grain = fbm(SIZE, 30, 30, 4, SEED + 540)
    grime_f = fbm(SIZE, 6, 6, 4, SEED + 580)
    grime = smoothstep(np.clip((grime_f - 0.5) / 0.3, 0.0, 1.0))
    moss = smoothstep(np.clip((fbm(SIZE, 8, 8, 4, SEED + 620) - 0.6) / 0.18, 0.0, 1.0))
    moss *= (1.0 - block) * 0.6 + smoothstep(np.clip((fy - 0.7) / 0.3, 0, 1)) * 0.7

    blk_dark = (66, 66, 70)
    blk_mid = (104, 102, 104)
    blk_light = (140, 136, 132)
    mortar_col = (44, 42, 44)
    moss_col = (74, 92, 58)

    col = lerp_color(blk_dark, blk_mid, tone)
    col = col + (lerp_color(blk_mid, blk_light, grain) - col) * 0.4
    col *= (0.8 + 0.2 * (1.0 - grime))[..., None]
    col = col * block[..., None] + np.array(mortar_col, np.float32)[None, None, :] * (1.0 - block)[..., None]
    col = col + (np.array(moss_col, np.float32)[None, None, :] - col) * np.clip(moss, 0, 1)[..., None] * 0.65

    height = block * (0.75 + 0.15 * tone) + 0.15 * grain
    rough = np.clip(0.85 + 0.1 * grain + 0.1 * (1.0 - block), 0.6, 1.0)
    save_set("crypt", col, height, rough, 4.0)


# ------------------------------------------------------------------- 5. dirt
def build_dirt():
    """Trodden graveyard path: dark earth, scattered pebbles, faint ruts."""
    earth = fbm(SIZE, 7, 7, 5, SEED + 700)
    fine = fbm(SIZE, 50, 50, 3, SEED + 740)
    peb_f1, _, peb_id = worley(SIZE, 20, 20, SEED + 780)
    pebble = smoothstep(np.clip(1.0 - peb_f1 / 0.3, 0.0, 1.0))
    # only some cells actually hold a pebble
    pebble *= (peb_id > 0.72).astype(np.float32)
    # ruts: two soft dark bands running along the track (constant along v)
    u = np.linspace(0.0, 1.0, SIZE, endpoint=False, dtype=np.float32)
    ruts = 0.5 + 0.5 * np.sin(u[None, :] * np.pi * 2.0 * 2.0 + 1.3)
    ruts = smoothstep(ruts) * np.ones((SIZE, 1), np.float32)

    earth_dark = (36, 30, 26)
    earth_mid = (58, 50, 42)
    earth_lit = (78, 70, 58)
    peb_col = (92, 90, 84)

    col = lerp_color(earth_dark, earth_mid, smoothstep(earth))
    col = col + (lerp_color(earth_mid, earth_lit, fine) - col) * 0.35
    col *= (0.86 + 0.14 * (1.0 - ruts))[..., None]
    col = col + (np.array(peb_col, np.float32)[None, None, :] - col) * pebble[..., None] * (0.35 + 0.35 * peb_id[..., None])

    height = 0.45 * earth + 0.2 * fine + 0.55 * pebble - 0.2 * ruts
    rough = np.clip(0.92 + 0.06 * fine - 0.15 * pebble, 0.6, 1.0)
    save_set("dirt", col, height, rough, 3.0)


# ----------------------------------------------------------------- 6. rubble
def build_rubble():
    """Fieldstone rubble wall: irregular rounded stones, dark joints, moss."""
    f1, f2, sid = worley(SIZE, 7, 5, SEED + 800)
    joint = smoothstep(np.clip((f2 - f1) / 0.12, 0.0, 1.0))   # 0 joints, 1 stone
    dome = np.clip(1.0 - f1 / 1.05, 0.0, 1.0)                 # stones bulge
    grain = fbm(SIZE, 34, 34, 4, SEED + 840)
    moss = smoothstep(np.clip((fbm(SIZE, 9, 9, 4, SEED + 880) - 0.58) / 0.2, 0.0, 1.0))
    moss *= (1.0 - joint) * 0.9 + 0.25                        # mostly in the joints

    st_dark = (58, 58, 62)
    st_mid = (96, 94, 96)
    st_light = (134, 130, 126)
    joint_col = (30, 30, 34)
    moss_col = (66, 84, 52)

    col = lerp_color(st_dark, st_mid, sid)                    # per-stone tone
    col = col + (lerp_color(st_mid, st_light, grain) - col) * 0.4
    col = col * joint[..., None] + np.array(joint_col, np.float32)[None, None, :] * (1.0 - joint)[..., None]
    col = col + (np.array(moss_col, np.float32)[None, None, :] - col) * np.clip(moss, 0, 1)[..., None] * 0.4

    height = joint * (0.35 + 0.65 * dome) + 0.12 * grain
    rough = np.clip(0.85 + 0.1 * grain + 0.1 * (1.0 - joint), 0.6, 1.0)
    save_set("rubble", col, height, rough, 4.5)


def preview():
    names = ["grave", "bark", "wood", "crypt", "dirt", "rubble"]
    sheet = Image.new("RGB", (SIZE * 3, SIZE * 2))
    for i, n in enumerate(names):
        im = Image.open(f"{n}_albedo_bump.png").convert("RGB")
        sheet.paste(im, ((i % 3) * SIZE, (i // 3) * SIZE))
    sheet.save("_preview.png")
    print("Wrote _preview.png  [grave|bark|wood / crypt|dirt|rubble]")


if __name__ == "__main__":
    build_grave()
    build_bark()
    build_wood()
    build_crypt()
    build_dirt()
    build_rubble()
    preview()
    print(f"Done ({SIZE}x{SIZE})")
