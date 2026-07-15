"""Generate a simple low-poly blocky human as OBJ + MTL.

Y-up, feet at y=0, model roughly centered on origin.
Every body part is a box (or simple tapered prism) with per-face normals,
so each block shades flat -> genuine low-poly look in any viewer.
"""

import math
import os


class Mesh:
    def __init__(self):
        self.verts = []        # list of (x, y, z)
        self.normals = []      # list of (nx, ny, nz)
        self.faces = []        # list of (material, [v_idx...], n_idx)
        self._vi = 1           # OBJ is 1-indexed
        self._ni = 1

    # ---- geometry helpers -------------------------------------------------
    def add_face(self, pts, material, centroid):
        """Add a polygon (list of 3 or 4 points) with a flat outward normal."""
        # compute normal from first triangle
        ax, ay, az = pts[1][0] - pts[0][0], pts[1][1] - pts[0][1], pts[1][2] - pts[0][2]
        bx, by, bz = pts[2][0] - pts[0][0], pts[2][1] - pts[0][1], pts[2][2] - pts[0][2]
        nx = ay * bz - az * by
        ny = az * bx - ax * bz
        nz = ax * by - ay * bx
        L = math.sqrt(nx * nx + ny * ny + nz * nz) or 1.0
        nx, ny, nz = nx / L, ny / L, nz / L
        # make sure it points away from the shape centroid
        fcx = sum(p[0] for p in pts) / len(pts)
        fcy = sum(p[1] for p in pts) / len(pts)
        fcz = sum(p[2] for p in pts) / len(pts)
        if (fcx - centroid[0]) * nx + (fcy - centroid[1]) * ny + (fcz - centroid[2]) * nz < 0:
            nx, ny, nz = -nx, -ny, -nz

        v_idx = []
        for p in pts:
            self.verts.append(p)
            v_idx.append(self._vi)
            self._vi += 1
        self.normals.append((nx, ny, nz))
        n_idx = self._ni
        self._ni += 1
        self.faces.append((material, v_idx, n_idx))

    def add_box(self, cx, cy, cz, sx, sy, sz, material):
        hx, hy, hz = sx / 2, sy / 2, sz / 2
        c = (cx, cy, cz)
        p = [
            (-hx, -hy, -hz),  # 0
            ( hx, -hy, -hz),  # 1
            ( hx,  hy, -hz),  # 2
            (-hx,  hy, -hz),  # 3
            (-hx, -hy,  hz),  # 4
            ( hx, -hy,  hz),  # 5
            ( hx,  hy,  hz),  # 6
            (-hx,  hy,  hz),  # 7
        ]
        P = [(cx + x, cy + y, cz + z) for x, y, z in p]
        faces = [
            ([1, 2, 6, 5], c),  # +X
            ([0, 4, 7, 3], c),  # -X
            ([3, 7, 6, 2], c),  # +Y
            ([0, 1, 5, 4], c),  # -Y
            ([4, 5, 6, 7], c),  # +Z  (front)
            ([1, 0, 3, 2], c),  # -Z  (back)
        ]
        for idx, _ in faces:
            self.add_face([P[i] for i in idx], material, c)

    def add_tapered_box(self, cx, cy_bottom, cz, sx_bottom, sx_top, sy, sz, material):
        """A prism whose X width tapers from bottom to top (shoulders > waist)."""
        hxb, hxt = sx_bottom / 2, sx_top / 2
        hz = sz / 2
        yt = cy_bottom + sy
        b = [
            (cx - hxb, cy_bottom, cz - hz),
            (cx + hxb, cy_bottom, cz - hz),
            (cx + hxb, cy_bottom, cz + hz),
            (cx - hxb, cy_bottom, cz + hz),
        ]
        t = [
            (cx - hxt, yt, cz - hz),
            (cx + hxt, yt, cz - hz),
            (cx + hxt, yt, cz + hz),
            (cx - hxt, yt, cz + hz),
        ]
        centroid = (cx, cy_bottom + sy / 2, cz)
        # bottom, top, then 4 sides
        self.add_face([b[0], b[1], b[2], b[3]], material, centroid)
        self.add_face([t[3], t[2], t[1], t[0]], material, centroid)
        self.add_face([b[3], b[2], t[2], t[3]], material, centroid)  # +Z front
        self.add_face([b[1], b[0], t[0], t[1]], material, centroid)  # -Z back
        self.add_face([b[2], b[1], t[1], t[2]], material, centroid)  # +X right
        self.add_face([b[0], b[3], t[3], t[0]], material, centroid)  # -X left


    def add_beveled_box(self, cx, cy, cz, sx, sy, sz, bevel, material):
        """Box with chamfered edges + corners -> soft, rounded low-poly look.
        bevel must be smaller than the smallest half-extent."""
        hx, hy, hz = sx / 2, sy / 2, sz / 2
        b = bevel
        c = (cx, cy, cz)
        def P(lx, ly, lz):
            return (cx + lx, cy + ly, cz + lz)

        # 6 inset face quads
        self.add_face([P(hx, hy - b, hz - b), P(hx, hy - b, -(hz - b)),
                       P(hx, -(hy - b), -(hz - b)), P(hx, -(hy - b), hz - b)], material, c)
        self.add_face([P(-hx, hy - b, hz - b), P(-hx, -(hy - b), hz - b),
                       P(-hx, -(hy - b), -(hz - b)), P(-hx, hy - b, -(hz - b))], material, c)
        self.add_face([P(hx - b, hy, hz - b), P(-(hx - b), hy, hz - b),
                       P(-(hx - b), hy, -(hz - b)), P(hx - b, hy, -(hz - b))], material, c)
        self.add_face([P(hx - b, -hy, hz - b), P(hx - b, -hy, -(hz - b)),
                       P(-(hx - b), -hy, -(hz - b)), P(-(hx - b), -hy, hz - b)], material, c)
        self.add_face([P(hx - b, hy - b, hz), P(hx - b, -(hy - b), hz),
                       P(-(hx - b), -(hy - b), hz), P(-(hx - b), hy - b, hz)], material, c)
        self.add_face([P(hx - b, hy - b, -hz), P(-(hx - b), hy - b, -hz),
                       P(-(hx - b), -(hy - b), -hz), P(hx - b, -(hy - b), -hz)], material, c)

        # 12 edge bevel quads
        for s1 in (-1, 1):           # edges along Z (faces perp-X & perp-Y)
            for s2 in (-1, 1):
                self.add_face([P(s1 * hx, s2 * (hy - b), hz - b),
                               P(s1 * hx, s2 * (hy - b), -(hz - b)),
                               P(s1 * (hx - b), s2 * hy, -(hz - b)),
                               P(s1 * (hx - b), s2 * hy, hz - b)], material, c)
        for s1 in (-1, 1):           # edges along Y (faces perp-X & perp-Z)
            for s2 in (-1, 1):
                self.add_face([P(s1 * hx, hy - b, s2 * (hz - b)),
                               P(s1 * hx, -(hy - b), s2 * (hz - b)),
                               P(s1 * (hx - b), -(hy - b), s2 * hz),
                               P(s1 * (hx - b), hy - b, s2 * hz)], material, c)
        for s1 in (-1, 1):           # edges along X (faces perp-Y & perp-Z)
            for s2 in (-1, 1):
                self.add_face([P(hx - b, s1 * hy, s2 * (hz - b)),
                               P(-(hx - b), s1 * hy, s2 * (hz - b)),
                               P(-(hx - b), s1 * (hy - b), s2 * hz),
                               P(hx - b, s1 * (hy - b), s2 * hz)], material, c)

        # 8 corner triangles
        for s1 in (-1, 1):
            for s2 in (-1, 1):
                for s3 in (-1, 1):
                    self.add_face([P(s1 * hx, s2 * (hy - b), s3 * (hz - b)),
                                   P(s1 * (hx - b), s2 * hy, s3 * (hz - b)),
                                   P(s1 * (hx - b), s2 * (hy - b), s3 * hz)], material, c)

    def add_sphere(self, cx, cy, cz, r, material, seg=10, rings=7,
                   phi0=0.0, phi1=None, rx=None, ry=None, rz=None):
        """Low-poly UV sphere with flat-shaded facets. Optional latitude band
        [phi0, phi1] (0 = north pole, pi = south pole) for partial caps.
        rx/ry/rz are per-axis radii for ellipsoids (default = r on all axes)."""
        if phi1 is None:
            phi1 = math.pi
        rx = r if rx is None else rx
        ry = r if ry is None else ry
        rz = r if rz is None else rz
        c = (cx, cy, cz)
        top_closed = phi0 <= 1e-6
        bot_closed = phi1 >= math.pi - 1e-6

        def sph(phi, theta):
            return (math.sin(phi) * math.cos(theta),
                    math.cos(phi),
                    math.sin(phi) * math.sin(theta))
        def at(v):
            return (cx + rx * v[0], cy + ry * v[1], cz + rz * v[2])

        rings_pts = [[sph(phi0 + (phi1 - phi0) * k / rings, 2 * math.pi * j / seg)
                      for j in range(seg)] for k in range(rings + 1)]

        for i in range(len(rings_pts) - 1):
            upper_pole = top_closed and i == 0
            lower_pole = bot_closed and i == len(rings_pts) - 2
            if upper_pole:                      # north cap (triangles)
                for j in range(seg):
                    j2 = (j + 1) % seg
                    self.add_face([at((0.0, 1.0, 0.0)),
                                   at(rings_pts[1][j]),
                                   at(rings_pts[1][j2])], material, c)
                continue
            if lower_pole:                      # south cap (triangles)
                for j in range(seg):
                    j2 = (j + 1) % seg
                    self.add_face([at((0.0, -1.0, 0.0)),
                                   at(rings_pts[-2][j2]),
                                   at(rings_pts[-2][j])], material, c)
                continue
            for j in range(seg):                # middle quad band
                j2 = (j + 1) % seg
                self.add_face([at(rings_pts[i][j]), at(rings_pts[i][j2]),
                               at(rings_pts[i + 1][j2]),
                               at(rings_pts[i + 1][j])], material, c)


# ---- palette (soft, friendly cartoon pastels) ---------------------------
COLORS = {
    "skin":    (0.98, 0.83, 0.70),   # warm peach
    "hair":    (0.25, 0.16, 0.13),   # dark brown
    "shirt":   (0.45, 0.70, 0.90),   # bright soft blue
    "pants":   (0.22, 0.26, 0.36),   # dark navy
    "shoes":   (0.95, 0.94, 0.96),   # off-white
    "eyes":    (0.10, 0.12, 0.18),   # near-black
}


# ---- body bulk control --------------------------------------------------
# FATNESS scales horizontal girth only (belly + limbs); height & head stay
# fixed. 1.0 = default, <1 = thinner, >1 = fatter. ~0.7 .. ~1.6 works well.
FATNESS = 1.0


def build_human():
    m = Mesh()

    # All-ellipsoid body: genuinely round, and parts overlap so they fuse
    # into one cohesive blobby figure (no neck gap, no floating arms).
    # Feet at y=0; total height ~1.4.
    # FATNESS scales horizontal girth (x & z) of the body + limbs; the head
    # and total height stay the same so the character reads as fatter/thinner.
    F = FATNESS
    seg, rings = 12, 8

    # ---- legs: two stubby vertical capsules -------------------------------
    leg_x = 0.15 * (0.6 + 0.4 * F)          # spread legs a bit when fatter
    for s in (-1, 1):
        m.add_sphere(leg_x * s, 0.22, 0.0, 0.14, "pants", seg, rings,
                     rx=0.14 * F, ry=0.27, rz=0.14 * F)
        # little round shoe peeking forward
        m.add_sphere(leg_x * s, 0.04, 0.06, 0.13, "shoes", seg, rings,
                     rx=0.15 * F, ry=0.06, rz=0.17 * F)

    # ---- torso: one plump rounded body (egg/pear shape) -------------------
    m.add_sphere(0.0, 0.72, 0.0, 0.0, "shirt", seg, rings,
                 rx=0.30 * F, ry=0.42, rz=0.26 * F)

    # ---- arms: two short stubby capsules hugging the body -----------------
    arm_x = 0.34 * F                        # push arms outward as belly grows
    for s in (-1, 1):
        m.add_sphere(arm_x * s, 0.78, 0.0, 0.0, "shirt", seg, rings,
                     rx=0.10 * F, ry=0.30, rz=0.11 * F)
        # round hand nub at the bottom of each arm
        m.add_sphere(arm_x * s, 0.50, 0.0, 0.09 * F, "skin", seg, rings)

    # ---- head: big round ball sitting ON TOP of the torso (overlaps top) --
    # Head size is independent of FATNESS so proportions shift cutely.
    head_cy = 1.20
    head_rx = head_ry = head_rz = 0.30
    m.add_sphere(0.0, head_cy, 0.0, 0.0, "skin", seg, rings,
                 rx=head_rx, ry=head_ry, rz=head_rz)

    # hair cap covering top ~58% of head, slightly oversized
    m.add_sphere(0.0, head_cy + 0.04, -0.015, 0.0, "hair", seg, rings,
                 phi0=0.0, phi1=math.pi * 0.58,
                 rx=head_rx * 1.07, ry=head_ry * 1.07, rz=head_rz * 1.07)

    # ---- face: two eyes ---------------------------------------------------
    for s in (-1, 1):
        ex = 0.105 * s
        ey = head_cy - 0.02
        ez = head_rz * 0.88
        m.add_sphere(ex, ey, ez, 0.028, "eyes", 7, 5)

    return m


def write_mtl(path):
    lines = ["# simple low-poly human materials"]
    for name, (r, g, b) in COLORS.items():
        lines += [
            f"newmtl {name}",
            f"Kd {r:.4f} {g:.4f} {b:.4f}",
            "Ka 0.10 0.10 0.10",
            "Ks 0.00 0.00 0.00",
            "d 1.0",
            "illum 2",
            "",
        ]
    with open(path, "w") as f:
        f.write("\n".join(lines))


def write_obj(path, mtl_name, mesh):
    lines = [f"mtllib {mtl_name}", "o low_poly_human", ""]
    for x, y, z in mesh.verts:
        lines.append(f"v {x:.5f} {y:.5f} {z:.5f}")
    lines.append("")
    for nx, ny, nz in mesh.normals:
        lines.append(f"vn {nx:.5f} {ny:.5f} {nz:.5f}")
    lines.append("")

    # group faces by material
    cur = None
    for material, v_idx, n_idx in mesh.faces:
        if material != cur:
            lines.append(f"usemtl {material}")
            cur = material
        # quad with shared normal: f v//vn v//vn ...
        line = "f " + " ".join(f"{v}//{n_idx}" for v in v_idx)
        lines.append(line)

    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def obj_text(mesh):
    """Return the OBJ content as a string (no mtllib line)."""
    lines = ["o low_poly_human"]
    for x, y, z in mesh.verts:
        lines.append(f"v {x:.5f} {y:.5f} {z:.5f}")
    for nx, ny, nz in mesh.normals:
        lines.append(f"vn {nx:.5f} {ny:.5f} {nz:.5f}")
    cur = None
    for material, v_idx, n_idx in mesh.faces:
        if material != cur:
            lines.append(f"usemtl {material}")
            cur = material
        lines.append("f " + " ".join(f"{v}//{n_idx}" for v in v_idx))
    return "\n".join(lines) + "\n"


def write_html(path, mesh):
    """Self-contained animated viewer: builds the character natively in three.js
    as a jointed rig (not from OBJ data). Works via file:// (double-click)."""
    # build a JS object mapping material name -> [r,g,b]
    mats_js = ",\n      ".join(
        f'"{n}": [{r:.4f}, {g:.4f}, {b:.4f}]' for n, (r, g, b) in COLORS.items()
    )

    html = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<title>Low-poly Human</title>
<style>
  html,body{margin:0;height:100%;background:#eef2f7;font-family:system-ui,sans-serif;overflow:hidden}
  #info{position:absolute;left:12px;top:12px;background:rgba(255,255,255,.85);padding:8px 12px;
        border-radius:8px;font-size:13px;color:#334;pointer-events:none}
  #info b{color:#1a1a2e}
</style>
</head>
<body>
<div id="info">Low-poly human &middot; <b>drag to orbit</b> &middot; scroll to zoom</div>
<div id="c" style="width:100vw;height:100vh"></div>

<script type="importmap">
{ "imports": {
  "three": "https://unpkg.com/three@0.160.0/build/three.module.js",
  "three/addons/": "https://unpkg.com/three@0.160.0/examples/jsm/"
} }
</script>
<script type="module">
import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';

const MATS = {
      __MATS__
};

const FATNESS = __FATNESS__;

// --- scene ---
const scene = new THREE.Scene();
scene.background = new THREE.Color(0xeef2f7);
const camera = new THREE.PerspectiveCamera(45, innerWidth/innerHeight, 0.1, 100);
camera.position.set(2.6, 1.25, 3.4);
const renderer = new THREE.WebGLRenderer({ antialias: true });
renderer.setPixelRatio(devicePixelRatio);
renderer.setSize(innerWidth, innerHeight);
renderer.shadowMap.enabled = true;
document.getElementById('c').appendChild(renderer.domElement);

// --- lights ---
scene.add(new THREE.HemisphereLight(0xffffff, 0xb0bec5, 0.9));
const sun = new THREE.DirectionalLight(0xffffff, 1.4);
sun.position.set(4, 8, 5);
sun.castShadow = true;
sun.shadow.mapSize.set(1024, 1024);
sun.shadow.camera.near = 1; sun.shadow.camera.far = 30;
sun.shadow.camera.left = -3; sun.shadow.camera.right = 3;
sun.shadow.camera.top = 3; sun.shadow.camera.bottom = -3;
scene.add(sun);

// --- ground ---
const ground = new THREE.Mesh(
  new THREE.CircleGeometry(6, 48),
  new THREE.MeshStandardMaterial({ color: 0xcfd8dc, roughness: 1 })
);
ground.rotation.x = -Math.PI/2;
ground.receiveShadow = true;
scene.add(ground);

// --- controls ---
const controls = new OrbitControls(camera, renderer.domElement);
controls.target.set(0, 0.78, 0);   // roughly the torso / center of mass
controls.enableDamping = true;
controls.minDistance = 2;
controls.maxDistance = 12;
controls.maxPolarAngle = Math.PI * 0.49;

// --- materials ---
const mat = {};
for (const [name, rgb] of Object.entries(MATS)) {
  mat[name] = new THREE.MeshStandardMaterial({
    color: new THREE.Color(rgb[0], rgb[1], rgb[2]),
    roughness: 0.85, metalness: 0.0, flatShading: true
  });
}
const MR = mat;  // shorthand

// --- helpers to build ellipsoids in JS ---
function ellipsoid(rx, ry, rz, mat, seg, rings) {
  const geo = new THREE.SphereGeometry(1, seg || 12, rings || 8, 0, Math.PI*2,
                                        0, Math.PI);
  geo.scale(rx, ry, rz);
  const m = new THREE.Mesh(geo, mat);
  m.castShadow = true; m.receiveShadow = true;
  return m;
}
function hemiEllipsoid(rx, ry, rz, phiEnd, mat, seg, rings) {
  const geo = new THREE.SphereGeometry(1, seg || 12, rings || 8, 0, Math.PI*2,
                                        0, phiEnd);
  geo.scale(rx, ry, rz);
  const m = new THREE.Mesh(geo, mat);
  m.castShadow = true; m.receiveShadow = true;
  return m;
}

// ---- build the jointed character (same dims as generate_human.py) ----
const F  = FATNESS;
const root = new THREE.Group();       // whole character (for root bob)

// -- torso --
const torsoY = 0.72;
const torsoRx = 0.30 * F, torsoRy = 0.42, torsoRz = 0.26 * F;
const torso = ellipsoid(torsoRx, torsoRy, torsoRz, MR.shirt);
torso.position.y = torsoY;
root.add(torso);

// -- legs --
const legX = 0.15 * (0.6 + 0.4 * F);
const legRx = 0.14 * F, legRy = 0.27, legRz = 0.14 * F;
const shoeRx = 0.15 * F, shoeRy = 0.06, shoeRz = 0.17 * F;

// hips pivot (on top of legs, at body bottom)
const hips = new THREE.Group();
hips.position.y = torsoY - torsoRy + 0.08;   // just below belly
root.add(hips);

for (const s of [-1, 1]) {
  const hip = new THREE.Group();              // left/right hip pivot
  hip.position.set(legX * s, 0, 0);
  hips.add(hip);

  // upper leg
  const thigh = ellipsoid(legRx, legRy, legRz, MR.pants);
  thigh.position.y = -legRy;
  hip.add(thigh);

  // shoe
  const shoe = ellipsoid(shoeRx, shoeRy, shoeRz, MR.shoes);
  shoe.position.set(0, -legRy * 2 + 0.02, 0.06);
  hip.add(shoe);
}

// -- neck pivot --
const neckPivot = new THREE.Group();
neckPivot.position.y = torsoY + torsoRy * 0.65;   // top of torso
torso.add(neckPivot);

// -- head --
const headCy = 0.28, headR = 0.30;
const head = ellipsoid(headR, headR, headR, MR.skin);
head.position.y = headCy;
neckPivot.add(head);

// hair cap (top ~58%)
const hair = hemiEllipsoid(headR * 1.07, headR * 1.07, headR * 1.07,
                           Math.PI * 0.58, MR.hair);
hair.position.set(0, 0.04, -0.015);
head.add(hair);

// eyes
for (const s of [-1, 1]) {
  const eye = ellipsoid(0.028, 0.028, 0.028, MR.eyes, 7, 5);
  eye.position.set(0.105 * s, -0.02, headR * 0.88);
  head.add(eye);
}

// -- arms --
const armX = 0.34 * F;
const armRx = 0.10 * F, armRy = 0.30, armRz = 0.11 * F;
const handR = 0.09 * F;

for (const s of [-1, 1]) {
  // shoulder pivot (on the torso surface)
  const shoulder = new THREE.Group();
  shoulder.position.set(armX * s, torsoRy * 0.35, 0);
  torso.add(shoulder);

  // upper arm
  const arm = ellipsoid(armRx, armRy, armRz, MR.shirt);
  arm.position.y = -armRy;
  shoulder.add(arm);

  // elbow pivot
  const elbow = new THREE.Group();
  elbow.position.y = -armRy * 2;
  shoulder.add(elbow);

  // hand
  const hand = ellipsoid(handR, handR, handR, MR.skin);
  hand.position.y = -handR * 0.5;
  elbow.add(hand);
}

scene.add(root);

// ---- animation state ----
const clock = new THREE.Clock();
const anim = { speed: 1.0 };

// ---- loop ----
addEventListener('resize', () => {
  camera.aspect = innerWidth / innerHeight;
  camera.updateProjectionMatrix();
  renderer.setSize(innerWidth, innerHeight);
});

(function animate() {
  requestAnimationFrame(animate);
  const t = clock.getElapsedTime() * anim.speed;

  // root: gentle bob (as if hopping)
  root.position.y = Math.abs(Math.sin(t * 1.8)) * 0.04;

  // hips: gentle side-to-side sway + tiny leg swing
  hips.rotation.z = Math.sin(t * 1.8) * 0.04;
  hips.children.forEach((hip, i) => {
    hip.rotation.x = Math.sin(t * 1.8 + i * Math.PI) * 0.18;
  });

  // torso: subtle breathing (scale) + sway
  const breath = 1.0 + Math.sin(t * 2.4) * 0.015;
  torso.scale.set(breath, 1.0 / breath, breath);
  torso.rotation.z = Math.sin(t * 1.8) * 0.02;

  // neck: gentle look-around
  neckPivot.rotation.y = Math.sin(t * 0.7) * 0.25;
  neckPivot.rotation.z = Math.sin(t * 0.9) * 0.05;

  // arms swing opposite to legs, with elbow bend
  torso.children.forEach((child) => {
    if (child.isGroup) {               // shoulder pivots
      const side = Math.sign(child.position.x);
      child.rotation.x = Math.sin(t * 1.8 + (side > 0 ? Math.PI : 0)) * 0.25;
      // elbow: gentle bend that increases when arm swings back
      child.children.forEach((c) => {
        if (c.isGroup) {              // elbow pivots
          c.rotation.x = -0.15 - Math.abs(child.rotation.x) * 0.5;
        }
      });
    }
  });

  controls.update();
  renderer.render(scene, camera);
})();
</script>
</body>
</html>
"""
    html = html.replace("__MATS__", mats_js).replace("__FATNESS__", str(FATNESS))
    with open(path, "w") as f:
        f.write(html)


def main():
    out_dir = os.path.dirname(os.path.abspath(__file__))
    obj_path = os.path.join(out_dir, "human.obj")
    mtl_path = os.path.join(out_dir, "human.mtl")
    html_path = os.path.join(out_dir, "view.html")

    mesh = build_human()
    write_mtl(mtl_path)
    write_obj(obj_path, "human.mtl", mesh)
    write_html(html_path, mesh)

    nv = len(mesh.verts)
    nf = len(mesh.faces)
    print(f" wrote {os.path.basename(obj_path)}: {nv} verts, {nf} faces")
    print(f" wrote {os.path.basename(mtl_path)}: {len(COLORS)} materials")
    print(f" wrote {os.path.basename(html_path)}: self-contained viewer")
    print(f"  -> {html_path}")
    print(f"  -> {obj_path}")
    print(f"  -> {mtl_path}")


if __name__ == "__main__":
    main()
