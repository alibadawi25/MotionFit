"""Generate seamlessly tileable helper textures for the water shaders in this package.

Outputs (all under assets/generated/):
  voronoi_lace.png          1024x1024 L    sea-foam lace (Voronoi F2-F1 web)
  caustics.png              1024x1024 L    underwater caustic ridge web
  flow_noise.png             512x512  RGB  R/G = independent tileable value noise, B=128
  detail_ripple_normal.png  1024x1024 RGB  OpenGL Y+ tangent-space ripple normals
  _preview.png              1024x1024 RGB  2x2 contact sheet

Seamlessness strategy: every field is a periodic function of (u,v) on the unit
torus. Each field is sampled on an (N+1)x(N+1) grid (u = i/N, i = 0..N) so the
last row/column is the exact continuation pixel of the tile. The "wrap error"
max|f[N]-f[0]| is the true seam discontinuity; it is 0 up to float rounding.
The stored image is the [0:N, 0:N] crop. All post-ops (global normalize,
gamma, pow, np.roll gradients, periodic dither) preserve periodicity.
"""

import numpy as np
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "generated"
OUT.mkdir(parents=True, exist_ok=True)

rng = np.random.default_rng(742026)

REPORT = []


def log(msg=""):
    print(msg)
    REPORT.append(msg)


# --------------------------------------------------------------------------
# building blocks
# --------------------------------------------------------------------------

def value_noise(np1, n, base_g, octaves, rng, persistence=0.5):
    """Periodic 2-D value noise, quintic interpolation, sampled at u=i/n for
    i in 0..np1-1 (np1 = n+1 gives the wrap-check row). Returns ~[0,1]."""
    u = np.arange(np1, dtype=np.float64) / n
    out = np.zeros((np1, np1))
    amp, tot = 1.0, 0.0
    for o in range(octaves):
        g = base_g * (2 ** o)
        vals = rng.random((g, g))
        x = u * g
        xi = np.floor(x).astype(np.int64)
        xf = x - xi
        f = xf ** 3 * (xf * (xf * 6.0 - 15.0) + 10.0)
        x0 = xi % g
        x1 = (xi + 1) % g
        v00 = vals[x0[:, None], x0[None, :]]
        v01 = vals[x0[:, None], x1[None, :]]
        v10 = vals[x1[:, None], x0[None, :]]
        v11 = vals[x1[:, None], x1[None, :]]
        fx = f[None, :]
        fy = f[:, None]
        top = v00 + (v01 - v00) * fx
        bot = v10 + (v11 - v10) * fx
        out += amp * (top + (bot - top) * fy)
        tot += amp
        amp *= persistence
    return out / tot


def worley_f1f2(X, Y, gx, gy, rng):
    """Exact euclidean Worley F1/F2 on the unit torus. One uniformly jittered
    point per grid cell (gx*gy cells). X, Y are (possibly domain-warped)
    sample coordinate arrays. A 7x7 cell neighborhood is searched, which
    provably contains both F1 and F2 for one-point-per-cell layouts
    (F2 within 3x3 is <= sqrt(8) cell units; anything outside 7x7 is >= 3)."""
    jx = rng.random((gy, gx))
    jy = rng.random((gy, gx))
    cx = np.floor(X * gx).astype(np.int64)
    cy = np.floor(Y * gy).astype(np.int64)
    d1 = np.full(X.shape, 1e9)
    d2 = np.full(X.shape, 1e9)
    for dj in range(-3, 4):
        cj = cy + dj
        wj = cj % gy
        for di in range(-3, 4):
            ci = cx + di
            wi = ci % gx
            px = (ci + jx[wj, wi]) / gx
            py = (cj + jy[wj, wi]) / gy
            dx = X - px
            dy = Y - py
            dd = dx * dx + dy * dy
            closer = dd < d1
            d2 = np.where(closer, d1, np.minimum(d2, dd))
            d1 = np.where(closer, dd, d1)
    return np.sqrt(d1), np.sqrt(d2)


def warped_coords(np1, n, amp, rng, base_g=6, octaves=3):
    """uv grid + small periodic domain warp (kills straight Voronoi edges,
    keeps exact tileability because the warp itself is periodic)."""
    u = np.arange(np1, dtype=np.float64) / n
    wx = value_noise(np1, n, base_g, octaves, rng)
    wy = value_noise(np1, n, base_g, octaves, rng)
    X = u[None, :] + (wx - 0.5) * (2.0 * amp)
    Y = u[:, None] + (wy - 0.5) * (2.0 * amp)
    return X, Y


def sine_gratings(np1, n, count, lo, hi, aniso_x, rng):
    """Sum of `count` sine gratings with random directions/phases. Wave
    vectors are rounded to INTEGER cycles per tile -> exactly periodic.
    X components scaled by aniso_x before rounding (wind stretch)."""
    u = np.arange(np1, dtype=np.float64) / n
    H = np.zeros((np1, np1))
    used = set()
    tries = 0
    while len(used) < count and tries < 4000:
        tries += 1
        th = rng.uniform(0.0, 2.0 * np.pi)
        rho = rng.uniform(lo, hi)
        kx = int(round(rho * np.cos(th) * aniso_x))
        ky = int(round(rho * np.sin(th)))
        if kx == 0 and ky == 0:
            continue
        if (kx, ky) in used or (-kx, -ky) in used:
            continue
        used.add((kx, ky))
        ph = rng.uniform(0.0, 2.0 * np.pi)
        a = rng.uniform(0.6, 1.0)
        H += a * np.sin(2.0 * np.pi * (kx * u[None, :] + ky * u[:, None]) + ph)
    return H


def blue_dither(n, rng, amp=1.0 / 255.0):
    """Periodic blue-ish noise (white minus periodic 3x3 box blur = high-pass),
    scaled to +-amp. Breaks 8-bit banding without visible grain."""
    w = rng.random((n, n))
    blur = np.zeros_like(w)
    for i in (-1, 0, 1):
        for j in (-1, 0, 1):
            blur += np.roll(np.roll(w, i, axis=0), j, axis=1)
    blur /= 9.0
    b = w - blur
    b /= np.abs(b).max()
    return b * amp


# --------------------------------------------------------------------------
# verification helpers
# --------------------------------------------------------------------------

def wrap_error(field):
    """True seam error of a (N+1)x(N+1) periodic field, in 8-bit LSB units
    relative to the field's own range: max |f(u=1) - f(u=0)|."""
    rng_ = field.max() - field.min()
    if rng_ <= 0:
        return 0.0, 0.0
    er = np.abs(field[-1, :] - field[0, :]).max() / rng_ * 255.0
    ec = np.abs(field[:, -1] - field[:, 0]).max() / rng_ * 255.0
    return er, ec


def seam_steps(a8):
    """On the stored uint8 image: pixel step across the tiling seam
    (row -1 -> row 0 of the next tile copy) vs the largest interior
    adjacent-row/col step. Seam is invisible iff seam <= interior."""
    a = a8.astype(np.int16)
    sr = int(np.abs(a[0] - a[-1]).max())
    sc = int(np.abs(a[:, 0] - a[:, -1]).max())
    ir = int(np.abs(np.diff(a, axis=0)).max())
    ic = int(np.abs(np.diff(a, axis=1)).max())
    return sr, sc, ir, ic


def report_image(name, path, a8, wrap_rc, extra=""):
    size = path.stat().st_size
    if a8.ndim == 2:
        stats = "min %d  max %d  mean %.2f" % (a8.min(), a8.max(), a8.mean())
    else:
        ch = []
        for c, cn in zip(range(a8.shape[2]), "RGB"):
            v = a8[:, :, c]
            ch.append("%s[min %d max %d mean %.1f]" % (cn, v.min(), v.max(), v.mean()))
        stats = "  ".join(ch)
    sr, sc, ir, ic = seam_steps(a8)
    log("%s" % name)
    log("  file: %s  (%d bytes)" % (path, size))
    log("  stored 8-bit: %s" % stats)
    log("  wrap seam error (f(1) vs f(0), true tiling discontinuity):"
        "  rows %.6f/255  cols %.6f/255  (must be <= 1/255)" % wrap_rc)
    log("  adjacent-pixel step ACROSS seam: rows %d cols %d | max interior step: rows %d cols %d"
        "  -> seam step within interior variation = %s"
        % (sr, sc, ir, ic, "YES" if (sr <= ir and sc <= ic) else "NO"))
    if extra:
        log("  " + extra)
    assert wrap_rc[0] <= 1.0 and wrap_rc[1] <= 1.0, "wrap seam error exceeds 1/255!"
    log("")


def save_l(path, img01, dither=None):
    x = img01.copy()
    if dither is not None:
        x = x + dither
    a8 = np.clip(np.rint(np.clip(x, 0.0, 1.0) * 255.0), 0, 255).astype(np.uint8)
    Image.fromarray(a8, "L").save(path)
    return a8


# --------------------------------------------------------------------------
# 1. voronoi_lace.png
# --------------------------------------------------------------------------

def make_lace():
    n, np1 = 1024, 1025
    X, Y = warped_coords(np1, n, amp=0.010, rng=rng)   # +-10 px organic wobble

    def lace_octave(gx, gy):
        f1, f2 = worley_f1f2(X, Y, gx, gy, rng)
        d = f2 - f1                       # 0 on cell borders, max near centers
        dn = np.clip(d / np.percentile(d, 92.0), 0.0, 1.0)
        web = 1.0 - dn                    # filaments white, holes black
        return web ** 0.75                # gamma keeps filaments thick

    lace = lace_octave(14, 13)            # 182 cells  (~180)
    lace += 0.35 * lace_octave(42, 39)    # 3x frequency sub-lace, 1638 cells
    lace = (lace - lace.min()) / (lace.max() - lace.min())

    wrc = wrap_error(lace)
    img = lace[:n, :n]
    path = OUT / "voronoi_lace.png"
    a8 = save_l(path, img, dither=blue_dither(n, rng))
    report_image("voronoi_lace.png (1024x1024 L)", path, a8, wrc,
                 extra="construction: torus Worley F2-F1, 182 jittered cells + 3x-freq octave w=0.35, gamma 0.75, domain-warped")
    return a8


# --------------------------------------------------------------------------
# 2. caustics.png
# --------------------------------------------------------------------------

def make_caustics():
    n, np1 = 1024, 1025
    X, Y = warped_coords(np1, n, amp=0.012, rng=rng, base_g=8)

    def ridge_field(gx, gy):
        f1, f2 = worley_f1f2(X, Y, gx, gy, rng)
        d = f2 - f1                        # 0 exactly on cell borders
        # normalize by a mid percentile and clip: cell interiors saturate to 0
        # (true dark ground) while the border web keeps a sharp falloff
        web = np.clip(1.0 - d / np.percentile(d, 55.0), 0.0, 1.0)
        return web ** 3.5                  # sharpen -> thin bright lines

    A = ridge_field(11, 11)                # 121 cells (~120)
    B = ridge_field(17, 17)                # 289 cells (~300, ~2.3x cell count)
    c = np.maximum(A, 0.6 * B)

    wrc = wrap_error(c)
    img = c[:n, :n]
    path = OUT / "caustics.png"
    a8 = save_l(path, img, dither=blue_dither(n, rng))
    report_image("caustics.png (1024x1024 L)", path, a8, wrc,
                 extra="construction: MAX of two torus-Voronoi border-ridge webs (121 & 289 cells, w=1/0.6), pow 3.5, blue-noise dithered")
    return a8


# --------------------------------------------------------------------------
# 3. flow_noise.png
# --------------------------------------------------------------------------

def make_flow():
    n, np1 = 512, 513
    r = value_noise(np1, n, 8, 4, rng)     # 4 octaves, base 8 cells across
    g = value_noise(np1, n, 8, 4, rng)     # independent second channel

    wr = wrap_error(r)
    wg = wrap_error(g)
    wrc = (max(wr[0], wg[0]), max(wr[1], wg[1]))

    def norm8(x):
        x = x[:n, :n]
        x = (x - x.min()) / (x.max() - x.min())
        return np.rint(x * 255.0).astype(np.uint8)

    a8 = np.empty((n, n, 3), dtype=np.uint8)
    a8[:, :, 0] = norm8(r)
    a8[:, :, 1] = norm8(g)
    a8[:, :, 2] = 128
    path = OUT / "flow_noise.png"
    Image.fromarray(a8, "RGB").save(path)
    report_image("flow_noise.png (512x512 RGB, B=128)", path, a8, wrc,
                 extra="construction: two independent periodic value-noise fields, 4 octaves (8/16/32/64 cells), quintic interp, full-range per channel")
    return a8


# --------------------------------------------------------------------------
# 4. detail_ripple_normal.png
# --------------------------------------------------------------------------

def make_normal():
    n, np1 = 1024, 1025
    h1 = sine_gratings(np1, n, 24, 6.0, 10.0, 1.35, rng)     # octave 1
    h2 = sine_gratings(np1, n, 24, 14.0, 22.0, 1.35, rng)    # octave 2
    H = h1 / h1.std() + 0.45 * (h2 / h2.std())

    wrc = wrap_error(H)
    Hc = H[:n, :n]                                            # exactly periodic

    # periodic central differences, d/du with pixel spacing 1/n
    gx = (np.roll(Hc, -1, axis=1) - np.roll(Hc, 1, axis=1)) * (n / 2.0)
    gy = (np.roll(Hc, -1, axis=0) - np.roll(Hc, 1, axis=0)) * (n / 2.0)

    # calibrate so peak xy-components of the unit normal reach ~0.35
    mag = np.sqrt(gx * gx + gy * gy)
    target = 0.35 / np.sqrt(1.0 - 0.35 ** 2)                  # tan of slope angle
    s = target / np.percentile(mag, 99.8)
    sx = gx * s
    sy = gy * s

    # OpenGL Y+ (green = up). image rows grow downward: y_up = -y_img,
    # so n = normalize(-dh/dx, +dh/drow, 1)
    inv = 1.0 / np.sqrt(sx * sx + sy * sy + 1.0)
    nx = -sx * inv
    ny = sy * inv
    nz = inv

    a8 = np.empty((n, n, 3), dtype=np.uint8)
    a8[:, :, 0] = np.clip(np.rint((nx * 0.5 + 0.5) * 255.0), 0, 255)
    a8[:, :, 1] = np.clip(np.rint((ny * 0.5 + 0.5) * 255.0), 0, 255)
    a8[:, :, 2] = np.clip(np.rint((nz * 0.5 + 0.5) * 255.0), 0, 255)
    path = OUT / "detail_ripple_normal.png"
    Image.fromarray(a8, "RGB").save(path)
    p995x = np.percentile(np.abs(nx), 99.5)
    p995y = np.percentile(np.abs(ny), 99.5)
    report_image("detail_ripple_normal.png (1024x1024 RGB, OpenGL Y+)", path, a8, wrc,
                 extra="slopes: |n.x| p99.5=%.3f max=%.3f  |n.y| p99.5=%.3f max=%.3f (target ~0.35); "
                       "48 integer-cycle sine gratings (6-10 + 14-22 cyc, amp 1:0.45, X wave-vectors x1.35)"
                       % (p995x, np.abs(nx).max(), p995y, np.abs(ny).max()))
    return a8


# --------------------------------------------------------------------------
# contact sheet
# --------------------------------------------------------------------------

def make_preview(lace8, caus8, flow8, norm8):
    sheet = Image.new("RGB", (1024, 1024))
    tiles = [
        (Image.fromarray(lace8, "L").convert("RGB"), (0, 0)),
        (Image.fromarray(caus8, "L").convert("RGB"), (512, 0)),
        (Image.fromarray(flow8, "RGB"), (0, 512)),
        (Image.fromarray(norm8, "RGB"), (512, 512)),
    ]
    for im, pos in tiles:
        sheet.paste(im.resize((512, 512), Image.LANCZOS), pos)
    path = OUT / "_preview.png"
    sheet.save(path)
    log("_preview.png contact sheet: %s (%d bytes)  [TL lace | TR caustics | BL flow | BR normal]"
        % (path, path.stat().st_size))


# --------------------------------------------------------------------------

if __name__ == "__main__":
    log("=== helper texture generation ===")
    log("")
    lace8 = make_lace()
    caus8 = make_caustics()
    flow8 = make_flow()
    norm8 = make_normal()
    make_preview(lace8, caus8, flow8, norm8)
    log("")
    log("All wrap-seam errors <= 1/255: opposite edges are continuations of each other.")
    log("Note: 'row 0 vs row -1' of a tileable image are ADJACENT pixels of the pattern,")
    log("not duplicates; their step equals normal interior pixel steps (shown above).")
    log("The true tiling test is f(u=1) vs f(u=0), reported as 'wrap seam error'.")
