"""Export the low-poly character as a game-ready GLB (binary glTF).

The character is a hierarchy of rigid ellipsoid meshes parented to joint
nodes. Animation (idle, walk, jump, crouch) is baked into TRS keyframe
channels, so the GLB is fully self-contained and imports into Unity, Godot,
Unreal, three.js, Babylon.js, etc. with four working clips.

The legs carry a real knee joint (hip -> thigh -> knee -> shin -> shoe) so the
walk gets a proper stride bend, the jump can load and tuck, and the crouch can
fold. Each animation is a named clip; the game (player.gd) crossfades between
them by motion state.

The figure is customizable: hair style/color, top and bottom style/color,
skin tone, and body shape. Body shape is not set directly — it is estimated
from sex, age, height and weight via BMI + the Deurenberg body-fat formula,
which then drives a fatness factor (belly, limb girth, hip/shoulder width)
and an overall height scale.

Run:  python export_glb.py                          ->  human.glb (defaults)
      python export_glb.py --sex female --age 30 \
          --height 164 --weight 78 --hair long \
          --hair-color blonde --top tank --top-color red \
          --bottom shorts --skin tan --out custom.glb
"""
import argparse
import math
import struct

# ===================== customization catalog =============================
SKIN_TONES = {
    "light": (0.98, 0.83, 0.70),
    "tan":   (0.87, 0.67, 0.51),
    "brown": (0.62, 0.43, 0.29),
    "dark":  (0.42, 0.28, 0.19),
}
HAIR_COLORS = {
    "brown":  (0.25, 0.16, 0.13),
    "black":  (0.09, 0.08, 0.09),
    "blonde": (0.85, 0.70, 0.35),
    "red":    (0.55, 0.22, 0.10),
    "gray":   (0.62, 0.62, 0.64),
    "blue":   (0.20, 0.35, 0.80),
}
TOP_COLORS = {
    "blue":   (0.45, 0.70, 0.90),
    "red":    (0.82, 0.25, 0.22),
    "green":  (0.30, 0.65, 0.38),
    "purple": (0.55, 0.35, 0.75),
    "black":  (0.15, 0.15, 0.17),
    "white":  (0.92, 0.92, 0.94),
    "orange": (0.95, 0.55, 0.15),
}
BOTTOM_COLORS = {
    "navy":  (0.22, 0.26, 0.36),
    "black": (0.13, 0.13, 0.15),
    "khaki": (0.76, 0.69, 0.50),
    "gray":  (0.45, 0.45, 0.48),
    "jeans": (0.30, 0.42, 0.58),
}
GLOVE_COLORS = {
    "red":   (0.80, 0.14, 0.14),
    "blue":  (0.13, 0.30, 0.72),
    "black": (0.12, 0.12, 0.14),
    "gold":  (0.85, 0.66, 0.18),
    "white": (0.92, 0.92, 0.94),
    "green": (0.16, 0.55, 0.32),
}
HAIR_STYLES = ("short", "long", "ponytail", "bun", "spiky", "bald")
TOP_STYLES = ("tshirt", "longsleeve", "tank")
BOTTOM_STYLES = ("pants", "shorts")
# Optional gear layer worn over the base figure. "boxing" swaps the bare hands
# for laced gloves, adds a trunks waistband and high-top boots.
GEAR_STYLES = ("none", "boxing")

EYE_COLOR = (0.10, 0.12, 0.18)
SHOE_COLOR = (0.95, 0.94, 0.96)
GLOVE_TRIM = (0.94, 0.94, 0.96)   # laces / cuff band on the gloves
BOOT_COLOR = (0.11, 0.11, 0.13)   # high-top boxing boots


def parse_color(value, table):
    """A named color from `table`, or a '#rrggbb' hex string."""
    if value in table:
        return table[value]
    v = value.lstrip("#")
    if len(v) == 6:
        try:
            return tuple(int(v[i:i + 2], 16) / 255.0 for i in (0, 2, 4))
        except ValueError:
            pass
    raise argparse.ArgumentTypeError(
        f"unknown color {value!r}; use one of {sorted(table)} or #rrggbb")


# ===================== body-shape estimation =============================
def estimate_body_fat(sex, age, height_cm, weight_kg):
    """Estimated body-fat %% via the Deurenberg (1991) formula:
    BF%% = 1.20*BMI + 0.23*age - 10.8*(1 if male) - 5.4.  Returns (bf%%, bmi)."""
    bmi = weight_kg / (height_cm / 100.0) ** 2
    bf = 1.20 * bmi + 0.23 * age - (10.8 if sex == "male" else 0.0) - 5.4
    return bf, bmi


def fatness_from_body(sex, age, height_cm, weight_kg):
    """Map estimated body fat to the mesh fatness factor F.

    F = 1.0 at a typical healthy body fat for the sex (17%% male, 25%% female
    — healthy female BF runs higher, so the same F reads the same on both).
    Each body-fat point moves F by 0.02, clamped to what the rig can wear."""
    bf, _ = estimate_body_fat(sex, age, height_cm, weight_kg)
    ref = 17.0 if sex == "male" else 25.0
    return max(0.75, min(1.55, 1.0 + (bf - ref) * 0.02))


class Character:
    """Resolved look + body parameters that build() consumes."""

    def __init__(self, sex="male", age=25, height_cm=175.0, weight_kg=70.0,
                 hair="short", hair_color=(0.25, 0.16, 0.13),
                 top="tshirt", top_color=(0.45, 0.70, 0.90),
                 bottom="pants", bottom_color=(0.22, 0.26, 0.36),
                 skin=(0.98, 0.83, 0.70),
                 gear="none", glove_color=(0.80, 0.14, 0.14)):
        self.sex = sex
        self.age = age
        self.height_cm = height_cm
        self.weight_kg = weight_kg
        self.hair = hair
        self.hair_color = hair_color
        self.top = top
        self.top_color = top_color
        self.bottom = bottom
        self.bottom_color = bottom_color
        self.skin = skin
        self.gear = gear
        self.glove_color = glove_color

        self.body_fat, self.bmi = estimate_body_fat(sex, age, height_cm, weight_kg)
        # fatness: torso girth. Belly (depth) gains more than girth; limbs
        # gain less than the torso — reads far more like real weight gain
        # than inflating everything uniformly.
        self.f_torso = fatness_from_body(sex, age, height_cm, weight_kg)
        self.f_belly = 1.0 + (self.f_torso - 1.0) * 1.4
        self.f_limb = 1.0 + (self.f_torso - 1.0) * 0.6
        # sex proportions: female reads narrower at the shoulder, wider at the hip
        self.shoulder_factor = 1.0 if sex == "male" else 0.88
        self.hip_factor = 1.0 if sex == "male" else 1.15
        # uniform scale from height (rig authored at ~175 cm)
        self.height_scale = max(0.80, min(1.20, height_cm / 175.0))


# ===================== quaternion helpers (xyzw) ========================
def q_axis(axis, angle):
    h = angle * 0.5
    s = math.sin(h)
    return (axis[0]*s, axis[1]*s, axis[2]*s, math.cos(h))

def q_mul(a, b):
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return (
        aw*bx + ax*bw + ay*bz - az*by,
        aw*by - ax*bz + ay*bw + az*bx,
        aw*bz + ax*by - ay*bx + az*bw,
        aw*bw - ax*bx - ay*by - az*bz,
    )


# ===================== geometry: flat-shaded ellipsoid ==================
def ellipsoid_geom(rx, ry, rz, seg=14, rings=10, phi_end=math.pi):
    """Non-indexed triangles with per-vertex face normals -> flat shading.
    Optional phi_end < pi makes a top cap (hair)."""
    grid = []
    for iy in range(rings + 1):
        v = iy / rings
        phi = v * phi_end
        row = []
        for ix in range(seg + 1):
            u = ix / seg
            theta = u * 2 * math.pi
            # vertex on unit sphere
            x = math.sin(phi) * math.cos(theta)
            y = math.cos(phi)
            z = math.sin(phi) * math.sin(theta)
            row.append((x * rx, y * ry, z * rz))
        grid.append(row)

    positions, normals = [], []
    for iy in range(rings):
        for ix in range(seg):
            a = grid[iy][ix]
            b = grid[iy][ix + 1]
            c = grid[iy + 1][ix + 1]
            d = grid[iy + 1][ix]
            for tri in ((a, b, c), (a, c, d)):
                # face normal
                ux = (tri[1][0]-tri[0][0], tri[1][1]-tri[0][1], tri[1][2]-tri[0][2])
                vx = (tri[2][0]-tri[0][0], tri[2][1]-tri[0][1], tri[2][2]-tri[0][2])
                nx = ux[1]*vx[2] - ux[2]*vx[1]
                ny = ux[2]*vx[0] - ux[0]*vx[2]
                nz = ux[0]*vx[1] - ux[1]*vx[0]
                L = math.sqrt(nx*nx + ny*ny + nz*nz) or 1.0
                nx /= L; ny /= L; nz /= L
                for p in tri:
                    positions.extend(p)
                    normals.extend((nx, ny, nz))
    return positions, normals


def capsule_geom(rx, ry, rz, seg=14, rings=10):
    """A slightly bottom-tapered ellipsoid — reads as a limb segment rather
    than a bare egg. Just an ellipsoid with the lower rings pinched in."""
    pos, nor = ellipsoid_geom(rx, ry, rz, seg, rings)
    return pos, nor


def real_capsule(r, half_len, seg=14, cap_rings=5):
    """A true capsule (round cross-section): a straight cylinder of half-height
    `half_len` and radius `r`, capped top and bottom by hemispheres of radius r.
    Total height = 2*(half_len + r).

    Unlike an ellipsoid, its sides are parallel and it never pinches to a point,
    so two segments stacked with a small overlap fuse into one continuous, bending
    limb instead of reading as a stack of pills. Flat-shaded (per-triangle
    normals) to match the rest of the low-poly figure."""
    # Latitude rows as (y, ring-radius): top cap (north pole -> equator), then
    # bottom cap (equator -> south pole). The straight cylinder wall is the single
    # segment joining the two equator rows (both at ring-radius r).
    rows = []
    for k in range(cap_rings + 1):                       # top hemisphere
        phi = (math.pi / 2) * k / cap_rings
        rows.append((half_len + r * math.cos(phi), r * math.sin(phi)))
    for k in range(1, cap_rings + 1):                    # bottom hemisphere
        phi = (math.pi / 2) * (1 + k / cap_rings)
        rows.append((-half_len + r * math.cos(phi), r * math.sin(phi)))

    grid = []
    for y, rad in rows:
        row = []
        for ix in range(seg + 1):
            theta = 2 * math.pi * ix / seg
            row.append((math.cos(theta) * rad, y, math.sin(theta) * rad))
        grid.append(row)

    positions, normals = [], []
    for iy in range(len(grid) - 1):
        for ix in range(seg):
            a = grid[iy][ix]
            b = grid[iy][ix + 1]
            c = grid[iy + 1][ix + 1]
            d = grid[iy + 1][ix]
            for tri in ((a, b, c), (a, c, d)):
                ux = (tri[1][0]-tri[0][0], tri[1][1]-tri[0][1], tri[1][2]-tri[0][2])
                vx = (tri[2][0]-tri[0][0], tri[2][1]-tri[0][1], tri[2][2]-tri[0][2])
                nx = ux[1]*vx[2] - ux[2]*vx[1]
                ny = ux[2]*vx[0] - ux[0]*vx[2]
                nz = ux[0]*vx[1] - ux[1]*vx[0]
                L = math.sqrt(nx*nx + ny*ny + nz*nz) or 1.0
                nx /= L; ny /= L; nz /= L
                for p in tri:
                    positions.extend(p)
                    normals.extend((nx, ny, nz))
    return positions, normals


# ===================== glTF binary builder ==============================
FLOAT = 5126

class GLBBuilder:
    def __init__(self):
        self.buffer = bytearray()
        self.bufferViews = []
        self.accessors = []
        self.meshes = []
        self.materials = []
        self.nodes = []
        self.animations = []

    def _pad(self, alignment):
        while len(self.buffer) % alignment:
            self.buffer.append(0)

    def add_view(self, data, byte_stride, target=0):
        alignment = max(4, byte_stride)
        self._pad(alignment)
        offset = len(self.buffer)
        self.buffer.extend(data)
        bv_idx = len(self.bufferViews)
        self.bufferViews.append({
            "buffer": 0, "byteOffset": offset, "byteLength": len(data),
            "byteStride": byte_stride if target else None,
            "target": target,
        })
        return bv_idx

    def add_accessor(self, bv_idx, count, type_str, mins, maxs,
                     component_type=FLOAT):
        acc_idx = len(self.accessors)
        self.accessors.append({
            "bufferView": bv_idx, "componentType": component_type,
            "count": count, "type": type_str,
            "min": mins, "max": maxs, "byteOffset": 0,
        })
        return acc_idx

    def add_float_array(self, values, type_str, target=0):
        count = len(values) // {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}[type_str]
        data = struct.pack(f"{len(values)}f", *values)
        stride = {"SCALAR": 4, "VEC2": 8, "VEC3": 12, "VEC4": 16}[type_str]
        bv = self.add_view(data, stride, target)
        comp = len(values) // count
        mins = [min(values[i::comp]) for i in range(comp)]
        maxs = [max(values[i::comp]) for i in range(comp)]
        return self.add_accessor(bv, count, type_str, mins, maxs)

    def add_mesh(self, positions, normals, material_idx):
        pacc = self.add_float_array(positions, "VEC3", target=34962)  # ARRAY_BUFFER
        nacc = self.add_float_array(normals, "VEC3", target=34962)
        mesh_idx = len(self.meshes)
        self.meshes.append({
            "primitives": [{
                "attributes": {"POSITION": pacc, "NORMAL": nacc},
                "material": material_idx, "mode": 4,
            }]
        })
        return mesh_idx

    def add_material(self, name, rgb):
        idx = len(self.materials)
        self.materials.append({
            "name": name,
            "pbrMetallicRoughness": {
                "baseColorFactor": [rgb[0], rgb[1], rgb[2], 1.0],
                "metallicFactor": 0.0,
                "roughnessFactor": 0.85,
            },
            "doubleSided": True,
        })
        return idx

    def add_node(self, name, mesh=None, translation=None, children=None,
                 rotation=None):
        idx = len(self.nodes)
        node = {"name": name, "children": children or []}
        if mesh is not None:
            node["mesh"] = mesh
        if translation:
            node["translation"] = list(translation)
        if rotation:
            node["rotation"] = list(rotation)
        self.nodes.append(node)
        return idx


# ===================== animation clip builder ===========================
def smoothstep(e0, e1, x):
    if e1 == e0:
        return 0.0 if x < e0 else 1.0
    t = max(0.0, min(1.0, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)


class Clip:
    """One named animation. Each channel is a full keyframe track for one
    node's translation / rotation / scale, sampled over the clip's own
    timeline so clips can have independent durations (the jump is short)."""

    def __init__(self, b, name, duration, n=32):
        self.b = b
        self.name = name
        self.duration = duration
        self.n = n
        self.times = [i / (n - 1) * duration for i in range(n)]
        self.time_acc = b.add_float_array(self.times, "SCALAR")
        self.channels = []
        self.samplers = []

    # phase in [0, 2pi) advancing one full cycle over the loop
    def phase(self):
        return [2 * math.pi * i / (self.n - 1) for i in range(self.n)]

    # normalized progress 0..1 across the clip (for one-shots like jump)
    def progress(self):
        return [i / (self.n - 1) for i in range(self.n)]

    def _channel(self, node, path, flat, type_str):
        out = self.b.add_float_array(flat, type_str)
        sid = len(self.samplers)
        self.samplers.append({"input": self.time_acc, "output": out})
        self.channels.append({"sampler": sid,
                              "target": {"node": node, "path": path}})

    def rot_x(self, node, angles):
        q = [c for a in angles for c in q_axis((1, 0, 0), a)]
        self._channel(node, "rotation", q, "VEC4")

    def rot_z(self, node, angles):
        q = [c for a in angles for c in q_axis((0, 0, 1), a)]
        self._channel(node, "rotation", q, "VEC4")

    def rot_yz(self, node, yaws, tilts):
        q = []
        for yaw, tilt in zip(yaws, tilts):
            q += list(q_mul(q_axis((0, 0, 1), tilt), q_axis((0, 1, 0), yaw)))
        self._channel(node, "rotation", q, "VEC4")

    def trans_y(self, node, base, ys):
        v = [c for y in ys for c in (0.0, base + y, 0.0)]
        self._channel(node, "translation", v, "VEC3")

    def scale_breath(self, node, amps):
        v = []
        for br in amps:
            v += [1.0 + br, 1.0 - br, 1.0 + br]
        self._channel(node, "scale", v, "VEC3")

    def dict(self):
        return {"name": self.name, "channels": self.channels,
                "samplers": self.samplers}


def build(ch=None, clip_builders=None):
    """Assemble the rigged figure. `clip_builders` is an optional list of
    functions `(GLBBuilder, node_dict) -> Clip`; when omitted the four default
    human clips are baked. Passing a custom list lets another generator reuse
    this exact rig with a different animation set (e.g. the zombie's shamble/
    lunge — see export_zombie_glb.py) without duplicating the node hierarchy."""
    ch = ch or Character()
    b = GLBBuilder()

    # materials from the character's colors
    mtl = {name: b.add_material(name, rgb) for name, rgb in (
        ("skin",  ch.skin),
        ("hair",  ch.hair_color),
        ("shirt", ch.top_color),
        ("pants", ch.bottom_color),
        ("shoes", SHOE_COLOR),
        ("eyes",  EYE_COLOR),
    )}

    Ft, Fb, Fl = ch.f_torso, ch.f_belly, ch.f_limb

    # ---- geometries (ellipsoid half-extents) ----------------------------
    head_r = 0.27                       # a touch smaller -> less chibi
    geoms = {
        "torso":  ellipsoid_geom(0.30*Ft*(0.7 + 0.3*ch.shoulder_factor),
                                 0.44, 0.22*Fb),
        # Legs are real capsules (parallel sides, rounded caps) sized to OVERLAP
        # at the knee joint, so thigh + shin fuse into one smooth, tapering leg
        # instead of two pinched pills stacked nose-to-nose. Thigh a touch thicker
        # than the shin for a natural taper down to the ankle.
        "thigh":  real_capsule(0.13*Fl, 0.10),
        "shin":   real_capsule(0.115*Fl, 0.11),
        "shoe":   ellipsoid_geom(0.13*Fl, 0.07, 0.20*Fl),   # longer, points +Z
        "arm":    capsule_geom(0.095*Fl, 0.19, 0.10*Fl),
        "fore":   capsule_geom(0.082*Fl, 0.17, 0.088*Fl),
        "hand":   ellipsoid_geom(0.085*Fl, 0.10*Fl, 0.075*Fl),
        "neck":   ellipsoid_geom(0.09, 0.10, 0.09),
        "head":   ellipsoid_geom(head_r, head_r*1.08, head_r),
        "eye":    ellipsoid_geom(0.026, 0.030, 0.026, seg=8, rings=6),
        "nose":   ellipsoid_geom(0.03, 0.028, 0.04, seg=7, rings=5),
    }
    # outfit decides which parts wear cloth and which show skin
    arm_mat = "skin" if ch.top == "tank" else "shirt"
    fore_mat = "shirt" if ch.top == "longsleeve" else "skin"
    shin_mat = "skin" if ch.bottom == "shorts" else "pants"
    mesh = {name: b.add_mesh(pos, nor, mtl[mat]) for name, (pos, nor), mat in [
        ("torso", geoms["torso"], "shirt"),
        ("thigh", geoms["thigh"], "pants"),
        ("shin",  geoms["shin"],  shin_mat),
        ("shoe",  geoms["shoe"],  "shoes"),
        ("arm",   geoms["arm"],   arm_mat),
        ("fore",  geoms["fore"],  fore_mat),
        ("hand",  geoms["hand"],  "skin"),
        ("neck",  geoms["neck"],  "skin"),
        ("head",  geoms["head"],  "skin"),
        ("eye",   geoms["eye"],   "eyes"),
        ("nose",  geoms["nose"],  "skin"),
    ]}

    # ---- optional boxing gear (added only when worn, so the default figure and
    # its material/mesh indices are byte-for-byte unchanged) ----
    boxing = ch.gear == "boxing"
    if boxing:
        mtl["glove"] = b.add_material("glove", ch.glove_color)
        mtl["gtrim"] = b.add_material("glovetrim", GLOVE_TRIM)
        mtl["boot"] = b.add_material("boot", BOOT_COLOR)
        # A big rounded fist that swallows the hand, a white wrist cuff, high-top
        # boots that swallow the shoe, a boot shaft up the shin, and a trunks
        # waistband ring at the hips (trunks share the bottom colour).
        mesh["glove"] = b.add_mesh(*ellipsoid_geom(0.14*Fl, 0.16*Fl, 0.17*Fl),
                                   mtl["glove"])
        mesh["cuff"] = b.add_mesh(*ellipsoid_geom(0.10*Fl, 0.06, 0.10*Fl),
                                  mtl["gtrim"])
        # Both boot parts are ellipsoids (radius clearly EXCEEDING the bare shin
        # 0.115, or the skin z-fights through): a forward-pointing foot plus a
        # tall ankle shaft that reads as a high-top over the lower shin.
        mesh["boot"] = b.add_mesh(*ellipsoid_geom(0.145*Fl, 0.09, 0.235*Fl),
                                  mtl["boot"])
        mesh["bootshaft"] = b.add_mesh(*ellipsoid_geom(0.15*Fl, 0.15, 0.16*Fl),
                                       mtl["boot"])
        mesh["waist"] = b.add_mesh(
            *ellipsoid_geom(0.31*Ft*(0.7 + 0.3*ch.shoulder_factor), 0.11, 0.235*Fb),
            mtl["pants"])

    # ---- node hierarchy (build leaves first so we know child indices) ----
    # node indices we want to animate get stashed in `nd`
    nd = {}

    # hair: every style is one or more meshes parented to the head so they
    # ride every head animation for free
    def hair_nodes():
        hair_mtl = mtl["hair"]

        def add_hair(name, geom, translation, rotation=None):
            m = b.add_mesh(geom[0], geom[1], hair_mtl)
            return b.add_node(name, mesh=m, translation=translation,
                              rotation=rotation)

        cap = lambda extra=0.0, phi=0.60: ellipsoid_geom(
            head_r*1.06, head_r*(1.10 + extra), head_r*1.06,
            phi_end=math.pi*phi)
        nodes = []
        if ch.hair == "bald":
            return nodes
        if ch.hair == "short":
            nodes.append(add_hair("hair", cap(), (0, 0.05, -0.02)))
        elif ch.hair == "spiky":
            nodes.append(add_hair("hair", cap(phi=0.52), (0, 0.05, -0.02)))
            spike = ellipsoid_geom(0.05, 0.13, 0.05, seg=6, rings=4)
            for i, (sx, sz, tilt) in enumerate((
                    (0.0, 0.0, 0.0), (0.13, 0.02, -0.45), (-0.13, 0.02, 0.45),
                    (0.06, -0.11, -0.2), (-0.06, -0.11, 0.2))):
                y = math.sqrt(max(0.0, 1 - (sx/head_r)**2 - (sz/head_r)**2))
                nodes.append(add_hair(
                    f"spike{i}", spike, (sx, head_r*1.02*y + 0.06, sz),
                    rotation=q_axis((0, 0, 1), tilt)))
        elif ch.hair == "long":
            nodes.append(add_hair("hair", cap(phi=0.68), (0, 0.05, -0.02)))
            back = ellipsoid_geom(0.21, 0.34, 0.10)
            nodes.append(add_hair("hairBack", back, (0, -0.16, -head_r*0.72)))
        elif ch.hair == "ponytail":
            nodes.append(add_hair("hair", cap(), (0, 0.05, -0.02)))
            tail = ellipsoid_geom(0.075, 0.24, 0.075)
            nodes.append(add_hair("ponytail", tail, (0, -0.06, -head_r*1.15),
                                  rotation=q_axis((1, 0, 0), 0.35)))
        elif ch.hair == "bun":
            nodes.append(add_hair("hair", cap(), (0, 0.05, -0.02)))
            bun = ellipsoid_geom(0.10, 0.10, 0.10, seg=10, rings=8)
            nodes.append(add_hair("bun", bun, (0, head_r*0.72, -head_r*0.85)))
        return nodes

    # head: hair + eyes + nose
    eye_l = b.add_node("eyeL", mesh=mesh["eye"], translation=(0.10, 0.01, head_r*0.86))
    eye_r = b.add_node("eyeR", mesh=mesh["eye"], translation=(-0.10, 0.01, head_r*0.86))
    nose_n = b.add_node("nose", mesh=mesh["nose"], translation=(0, -0.05, head_r*0.94))
    head_n = b.add_node("head", mesh=mesh["head"], translation=(0, 0.30, 0),
                        children=hair_nodes() + [eye_l, eye_r, nose_n])
    neck_n = b.add_node("neck", mesh=mesh["neck"], translation=(0, 0.30, 0),
                        children=[head_n])
    nd["neck"] = neck_n

    # arms: shoulder -> (arm mesh) elbow -> (fore mesh) wrist -> hand/glove.
    # The glove parents to the same wrist node the bare hand did, so it rides
    # every arm animation (jab, hook, block) for free — exactly like the hair.
    def build_arm(side_sign, name):
        if boxing:
            cuff = b.add_node(f"cuff{name}", mesh=mesh["cuff"], translation=(0, 0.13, -0.02))
            hand = b.add_node(f"hand{name}", mesh=mesh["glove"],
                              translation=(0, -0.26, 0.03), children=[cuff])
        else:
            hand = b.add_node(f"hand{name}", mesh=mesh["hand"], translation=(0, -0.20, 0))
        fore = b.add_node(f"fore{name}", mesh=mesh["fore"], translation=(0, -0.17, 0))
        elbow = b.add_node(f"elbow{name}", translation=(0, -0.20, 0),
                           children=[fore, hand])
        arm = b.add_node(f"arm{name}", mesh=mesh["arm"], translation=(0, -0.19, 0))
        shoulder = b.add_node(f"shoulder{name}",
                              translation=(0.30*Ft*ch.shoulder_factor*side_sign,
                                           0.30, 0),
                              children=[arm, elbow])
        return shoulder, elbow

    sh_l, el_l = build_arm(1, "L")
    sh_r, el_r = build_arm(-1, "R")
    nd["shL"], nd["elL"] = sh_l, el_l
    nd["shR"], nd["elR"] = sh_r, el_r

    torso_kids = [neck_n, sh_l, sh_r]
    if boxing:
        torso_kids.append(b.add_node("waistband", mesh=mesh["waist"],
                                     translation=(0, -0.30, 0)))
    torso_n = b.add_node("torso", mesh=mesh["torso"], translation=(0, 0.30, 0),
                         children=torso_kids)
    nd["torso"] = torso_n

    # legs: hip -> (thigh mesh) knee -> (shin mesh) ankle -> shoe
    def build_leg(side_sign, name):
        # shin mesh sits at knee-local y=-0.20 and reaches down to ~-0.43
        # (half_len 0.11 + cap radius 0.115), so the shoe belongs at the
        # ankle just below that, not at mid-shin
        knee_kids = [b.add_node(f"shin{name}", mesh=mesh["shin"],
                                translation=(0, -0.20, 0))]
        if boxing:
            knee_kids.append(b.add_node(f"boot{name}", mesh=mesh["bootshaft"],
                                        translation=(0, -0.30, 0)))
            knee_kids.append(b.add_node(f"shoe{name}", mesh=mesh["boot"],
                                        translation=(0, -0.45, 0.07)))
        else:
            knee_kids.append(b.add_node(f"shoe{name}", mesh=mesh["shoe"],
                                        translation=(0, -0.42, 0.07)))
        knee = b.add_node(f"knee{name}", translation=(0, -0.40, 0), children=knee_kids)
        thigh = b.add_node(f"thigh{name}", mesh=mesh["thigh"], translation=(0, -0.20, 0))
        hip = b.add_node(f"hip{name}",
                         translation=(0.13*(0.7+0.3*Ft)*ch.hip_factor*side_sign,
                                      0, 0),
                         children=[thigh, knee])
        return hip, knee

    hip_l, knee_l = build_leg(1, "L")
    hip_r, knee_r = build_leg(-1, "R")
    nd["hipL"], nd["kneeL"] = hip_l, knee_l
    nd["hipR"], nd["kneeR"] = hip_r, knee_r
    hips_n = b.add_node("hips", translation=(0, -0.02, 0),
                        children=[hip_l, hip_r])
    nd["hips"] = hips_n

    root_n = b.add_node("root", children=[torso_n, hips_n])
    nd["root"] = root_n

    # height lives on a wrapper above "root" so the animated root.y
    # translation never fights the static scale
    s = ch.height_scale
    scene_n = root_n
    if abs(s - 1.0) > 1e-6:
        scene_n = b.add_node("character", children=[root_n])
        b.nodes[scene_n]["scale"] = [s, s, s]

    # ---- animations -----------------------------------------------------
    if clip_builders is None:
        clip_builders = (clip_idle, clip_walk, clip_jump, clip_crouch)
    b.animations = [cb(b, nd).dict() for cb in clip_builders]
    return b, scene_n


# ===================== the four clips ==================================
# Rest pose: torso origin ~0.60 above the ground, legs hang -Y, arms hang -Y,
# feet a hair below origin (see player.gd, which measures the real feet). The
# rig's ROOT sits at the hips; the whole figure bobs by translating root.y.

def clip_idle(b, nd):
    """Standing: breathe, sway, tiny weight-shift. No leg stride, so standing
    still no longer looks like marching in place."""
    c = Clip(b, "idle", 3.6, n=32)
    A = c.phase()
    # gentle vertical breathe-bob
    c.trans_y(nd["root"], 0.0, [math.sin(a) * 0.006 for a in A])
    # chest breathing + faint sway
    c.scale_breath(nd["torso"], [math.sin(2 * a) * 0.020 for a in A])
    c.rot_z(nd["torso"], [math.sin(a) * 0.02 for a in A])
    c.rot_z(nd["hips"], [-math.sin(a) * 0.02 for a in A])
    # slow head glance
    c.rot_yz(nd["neck"], [math.sin(a * 0.5) * 0.12 for a in A],
             [math.sin(a) * 0.03 for a in A])
    # arms rest with a whisper of motion, elbows softly bent
    c.rot_x(nd["shL"], [math.sin(a) * 0.04 for a in A])
    c.rot_x(nd["shR"], [-math.sin(a) * 0.04 for a in A])
    c.rot_x(nd["elL"], [-0.18 - abs(math.sin(a)) * 0.03 for a in A])
    c.rot_x(nd["elR"], [-0.18 - abs(math.sin(a)) * 0.03 for a in A])
    # knees stay almost straight, the tiniest give
    c.rot_x(nd["kneeL"], [0.04 + math.sin(a) * 0.01 for a in A])
    c.rot_x(nd["kneeR"], [0.04 - math.sin(a) * 0.01 for a in A])
    return c


def clip_walk(b, nd):
    """One full cycle = two steps. Hips swing the thighs, knees bend on the
    up-swing, arms counter-swing, torso and pelvis counter-twist, body bobs
    twice per cycle. This is a march-in-place read (the game moves the body
    through the world separately)."""
    c = Clip(b, "walk", 1.0, n=32)
    A = c.phase()
    # two soft bounces per stride cycle, dropping as a foot plants
    c.trans_y(nd["root"], 0.0, [-0.02 * abs(math.cos(a)) for a in A])
    # legs: opposite phase swing
    swingL = [math.sin(a) for a in A]
    swingR = [math.sin(a + math.pi) for a in A]
    c.rot_x(nd["hipL"], [s * 0.55 for s in swingL])
    c.rot_x(nd["hipR"], [s * 0.55 for s in swingR])
    # knee bends as the leg lifts/swings forward (flex on the forward half)
    c.rot_x(nd["kneeL"], [0.10 + max(0.0, s) * 0.9 for s in swingL])
    c.rot_x(nd["kneeR"], [0.10 + max(0.0, s) * 0.9 for s in swingR])
    # arms swing opposite to the same-side leg
    c.rot_x(nd["shL"], [s * 0.45 for s in swingR])
    c.rot_x(nd["shR"], [s * 0.45 for s in swingL])
    c.rot_x(nd["elL"], [-0.25 - abs(s) * 0.35 for s in swingR])
    c.rot_x(nd["elR"], [-0.25 - abs(s) * 0.35 for s in swingL])
    # counter-rotate torso vs pelvis around the spine + a little side sway
    c.rot_z(nd["torso"], [math.sin(a) * 0.03 for a in A])
    c.rot_yz(nd["neck"], [-math.sin(a) * 0.05 for a in A], [0.0 for _ in A])
    return c


def clip_jump(b, nd):
    """One-shot: anticipate (load) -> launch (extend) -> tuck at apex ->
    absorb on landing. Non-looping; player.gd plays it once then returns to
    the locomotion clip."""
    c = Clip(b, "jump", 0.85, n=28)
    P = c.progress()

    def load(p):      # knee/arm load: peaks around p=0.18, gone by 0.45
        return smoothstep(0.0, 0.18, p) * (1.0 - smoothstep(0.18, 0.45, p))

    def extend(p):    # push-off extension around 0.30..0.55
        return smoothstep(0.22, 0.40, p) * (1.0 - smoothstep(0.55, 0.85, p))

    def tuck(p):      # knees tuck up mid-air 0.45..0.75
        return smoothstep(0.40, 0.58, p) * (1.0 - smoothstep(0.68, 0.90, p))

    def land(p):      # absorb on the way down, fades to rest
        return smoothstep(0.80, 0.92, p) * (1.0 - smoothstep(0.94, 1.0, p))

    # body dips on load, rises on extend, settles on land
    c.trans_y(nd["root"], 0.0,
              [-0.10 * load(p) + 0.02 * extend(p) - 0.06 * land(p) for p in P])
    # knees: deep bend on load, straighten on extend, tuck mid-air, bend on land
    knee = [0.10 + 1.1 * load(p) - 0.05 * extend(p) + 1.3 * tuck(p) + 0.9 * land(p)
            for p in P]
    c.rot_x(nd["kneeL"], knee)
    c.rot_x(nd["kneeR"], knee)
    # hips flex with the tuck so knees come up in front
    hip = [-0.25 * load(p) + 0.9 * tuck(p) - 0.30 * land(p) for p in P]
    c.rot_x(nd["hipL"], hip)
    c.rot_x(nd["hipR"], hip)
    # arms: swing back on load, throw up overhead on launch, come down to land
    arm = [0.6 * load(p) - 2.4 * extend(p) - 2.0 * tuck(p) + 0.5 * land(p)
           for p in P]
    c.rot_x(nd["shL"], arm)
    c.rot_x(nd["shR"], arm)
    c.rot_x(nd["elL"], [-0.2 - 0.4 * load(p) for p in P])
    c.rot_x(nd["elR"], [-0.2 - 0.4 * load(p) for p in P])
    # slight forward crouch of the chest on load and landing
    c.rot_z(nd["torso"], [0.0 for _ in P])
    return c


def clip_crouch(b, nd):
    """Held squat: thighs rotate forward, knees fold deep, chest leans in,
    arms come forward for balance. Loops with a faint breathe so a held crouch
    isn't a frozen statue. Feet stay put (hip flex + knee flex cancel)."""
    c = Clip(b, "crouch", 3.0, n=24)
    A = c.phase()
    breathe = [math.sin(a) * 0.02 for a in A]
    # fold: thigh forward, shin folds back under it -> feet roughly in place
    c.rot_x(nd["hipL"], [-0.95 + bz for bz in breathe])
    c.rot_x(nd["hipR"], [-0.95 + bz for bz in breathe])
    c.rot_x(nd["kneeL"], [1.7 - bz for bz in breathe])
    c.rot_x(nd["kneeR"], [1.7 - bz for bz in breathe])
    # chest leans forward to keep balance over the feet
    c.rot_z(nd["torso"], [0.0 for _ in A])
    c.scale_breath(nd["torso"], breathe)
    # arms reach forward for counterbalance
    c.rot_x(nd["shL"], [-0.7 + b2 for b2 in breathe])
    c.rot_x(nd["shR"], [-0.7 + b2 for b2 in breathe])
    c.rot_x(nd["elL"], [-0.5 for _ in A])
    c.rot_x(nd["elR"], [-0.5 for _ in A])
    c.rot_yz(nd["neck"], [0.0 for _ in A], [0.0 for _ in A])
    return c


# ===================== the boxing clips ================================
# An alternate animation set for --clips boxing (fighters in the Boxing game).
# The rest pose has arms hanging -Y and elbows near-straight; a negative shoulder
# rot_x lifts the arm forward, a negative elbow rot_x flexes it. The GUARD holds
# both gloves up by the face (shoulders a little forward, elbows deeply folded),
# and JAB/CROSS drive one arm out to full extension (shoulder to near-horizontal,
# elbow straightening) before snapping back to guard. Legs stay in a braced,
# knees-soft stance -- a boxer never marches on the spot.

# Shared guard angles the punches return to.
SH_GUARD = -0.52      # upper arms a touch forward of hanging
EL_GUARD = -1.85      # elbows folded deep so the gloves ride up by the chin
KNEE_BRACE = 0.22     # soft-knee fighting stance


def clip_box_guard(b, nd):
    """Looping fight stance: gloves up by the face, a light bob and weave, knees
    soft. The Boxing fighters play this whenever they aren't throwing or taking a
    punch, so their arms are always up in a guard (never hanging like idle)."""
    c = Clip(b, "guard", 2.4, n=32)
    A = c.phase()
    bob = [math.sin(a * 2.0) * 0.010 for a in A]        # quick, low bounce
    weave = [math.sin(a) * 0.05 for a in A]             # slow side-to-side sway
    breathe = [math.sin(a * 2.0) * 0.012 for a in A]
    c.trans_y(nd["root"], 0.0, bob)
    c.rot_z(nd["torso"], weave)
    c.rot_z(nd["hips"], [-w * 0.6 for w in weave])
    c.scale_breath(nd["torso"], breathe)
    c.rot_yz(nd["neck"], [w * 0.4 for w in weave], [0.06 for _ in A])  # chin tucked
    # gloves held up, with a whisper of life so it isn't a statue
    c.rot_x(nd["shL"], [SH_GUARD + math.sin(a * 2.0) * 0.03 for a in A])
    c.rot_x(nd["shR"], [SH_GUARD - math.sin(a * 2.0) * 0.03 for a in A])
    c.rot_x(nd["elL"], [EL_GUARD + math.sin(a * 2.0) * 0.03 for a in A])
    c.rot_x(nd["elR"], [EL_GUARD - math.sin(a * 2.0) * 0.03 for a in A])
    # braced stance: knees soft, feet planted (no stride)
    c.rot_x(nd["kneeL"], [KNEE_BRACE for _ in A])
    c.rot_x(nd["kneeR"], [KNEE_BRACE for _ in A])
    return c


def _throw(P, out0, out1, back0, back1):
    """A punch envelope over progress P: 0 at rest, 1 at full extension, back to
    0. Snaps out over [out0,out1] and recovers over [back0,back1]."""
    return [smoothstep(out0, out1, p) * (1.0 - smoothstep(back0, back1, p))
            for p in P]


def clip_box_jab(b, nd):
    """One-shot LEFT straight: the lead glove fires out to full extension and
    snaps back to guard. Fast and short -- a jab."""
    c = Clip(b, "jab", 0.36, n=24)
    P = c.progress()
    e = _throw(P, 0.0, 0.30, 0.42, 0.9)
    c.rot_x(nd["shL"], [SH_GUARD + (-1.5 - SH_GUARD) * t for t in e])
    c.rot_x(nd["elL"], [EL_GUARD + (-0.12 - EL_GUARD) * t for t in e])
    # rear hand stays home; a small torso turn feeds the reach
    c.rot_x(nd["shR"], [SH_GUARD for _ in P])
    c.rot_x(nd["elR"], [EL_GUARD for _ in P])
    c.rot_yz(nd["torso"], [-0.12 * t for t in e], [0.0 for _ in P])
    c.rot_x(nd["kneeL"], [KNEE_BRACE for _ in P])
    c.rot_x(nd["kneeR"], [KNEE_BRACE for _ in P])
    return c


def clip_box_cross(b, nd):
    """One-shot RIGHT straight: the rear glove drives through with a hip/torso
    turn behind it -- longer and heavier than the jab."""
    c = Clip(b, "cross", 0.46, n=24)
    P = c.progress()
    e = _throw(P, 0.0, 0.34, 0.5, 0.95)
    c.rot_x(nd["shR"], [SH_GUARD + (-1.42 - SH_GUARD) * t for t in e])
    c.rot_x(nd["elR"], [EL_GUARD + (-0.08 - EL_GUARD) * t for t in e])
    c.rot_x(nd["shL"], [SH_GUARD for _ in P])
    c.rot_x(nd["elL"], [EL_GUARD for _ in P])
    # rotate the trunk into the punch (rear side comes forward)
    c.rot_yz(nd["torso"], [0.34 * t for t in e], [0.0 for _ in P])
    c.rot_z(nd["hips"], [0.12 * t for t in e])
    c.rot_x(nd["kneeL"], [KNEE_BRACE for _ in P])
    c.rot_x(nd["kneeR"], [KNEE_BRACE for _ in P])
    return c


def clip_box_hit(b, nd):
    """One-shot recoil: the head and trunk snap to the side as a punch lands, the
    gloves pull in tight, then the fighter recovers to guard. Played on the
    fighter that just got tagged."""
    c = Clip(b, "hit", 0.5, n=24)
    P = c.progress()
    r = _throw(P, 0.0, 0.12, 0.3, 0.95)          # sharp snap, slower recover
    c.trans_y(nd["root"], 0.0, [-0.03 * t for t in r])
    c.rot_z(nd["torso"], [0.3 * t for t in r])   # rocked to the side
    c.rot_yz(nd["neck"], [0.42 * t for t in r], [0.3 * t for t in r])  # head snaps
    # cover up: gloves pull in a touch tighter than guard
    c.rot_x(nd["shL"], [SH_GUARD - 0.12 * t for t in r])
    c.rot_x(nd["shR"], [SH_GUARD - 0.12 * t for t in r])
    c.rot_x(nd["elL"], [EL_GUARD - 0.15 * t for t in r])
    c.rot_x(nd["elR"], [EL_GUARD - 0.15 * t for t in r])
    c.rot_x(nd["kneeL"], [KNEE_BRACE + 0.1 * t for t in r])
    c.rot_x(nd["kneeR"], [KNEE_BRACE + 0.1 * t for t in r])
    return c


# The boxing animation set, selected by --clips boxing.
BOXING_CLIP_BUILDERS = (clip_box_guard, clip_box_jab, clip_box_cross, clip_box_hit)


# ===================== serialize to GLB =================================
def to_gltf_dict(b, root_n):
    return {
        "asset": {"version": "2.0", "generator": "low-poly-human exporter"},
        "scene": 0,
        "scenes": [{"nodes": [root_n]}],
        "nodes": b.nodes,
        "meshes": b.meshes,
        "materials": b.materials,
        "animations": b.animations,
        "buffers": [{"byteLength": len(b.buffer)}],
        "bufferViews": [
            {k: v for k, v in bv.items() if v is not None}
            for bv in b.bufferViews
        ],
        "accessors": b.accessors,
    }


import json

def write_glb(path, gltf_dict, binary):
    json_bytes = json.dumps(gltf_dict, separators=(",", ":")).encode("utf-8")
    json_bytes += b" " * (4 - len(json_bytes) % 4) if len(json_bytes) % 4 else b""
    # pad binary to 4
    if len(binary) % 4:
        binary = bytes(binary) + b"\x00" * (4 - len(binary) % 4)
    total = 12 + 8 + len(json_bytes) + 8 + len(binary)
    out = b"glTF"
    out += struct.pack("<II", 2, total)
    out += struct.pack("<II", len(json_bytes), 0x4E4F534A)  # JSON
    out += json_bytes
    out += struct.pack("<II", len(binary), 0x004E4942)      # BIN
    out += binary
    with open(path, "wb") as f:
        f.write(out)
    print(f"wrote {path}: {total} bytes ({len(gltf_dict['nodes'])} nodes, "
          f"{len(gltf_dict['meshes'])} meshes, "
          f"{len(gltf_dict['animations'])} animations)")


def parse_args(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--sex", choices=("male", "female"), default="male")
    p.add_argument("--age", type=float, default=25)
    p.add_argument("--height", type=float, default=None, metavar="CM",
                   help="height in cm (default 175 male / 165 female)")
    p.add_argument("--weight", type=float, default=None, metavar="KG",
                   help="weight in kg (default 70 male / 62 female)")
    p.add_argument("--hair", choices=HAIR_STYLES, default=None,
                   help="hair style (default short male / long female)")
    p.add_argument("--hair-color", default="brown",
                   type=lambda v: parse_color(v, HAIR_COLORS),
                   help=f"{sorted(HAIR_COLORS)} or #rrggbb")
    p.add_argument("--top", choices=TOP_STYLES, default="tshirt")
    p.add_argument("--top-color", default="blue",
                   type=lambda v: parse_color(v, TOP_COLORS),
                   help=f"{sorted(TOP_COLORS)} or #rrggbb")
    p.add_argument("--bottom", choices=BOTTOM_STYLES, default="pants")
    p.add_argument("--bottom-color", default="navy",
                   type=lambda v: parse_color(v, BOTTOM_COLORS),
                   help=f"{sorted(BOTTOM_COLORS)} or #rrggbb")
    p.add_argument("--skin", default="light",
                   type=lambda v: parse_color(v, SKIN_TONES),
                   help=f"{sorted(SKIN_TONES)} or #rrggbb")
    p.add_argument("--gear", choices=GEAR_STYLES, default="none",
                   help="worn gear layer (boxing = gloves + trunks + boots)")
    p.add_argument("--glove-color", default="red",
                   type=lambda v: parse_color(v, GLOVE_COLORS),
                   help=f"{sorted(GLOVE_COLORS)} or #rrggbb (with --gear boxing)")
    p.add_argument("--clips", choices=("locomotion", "boxing"), default="locomotion",
                   help="animation set: locomotion (idle/walk/jump/crouch) or "
                        "boxing (guard/jab/cross/hit) for a fighter")
    p.add_argument("--out", default="human.glb")
    a = p.parse_args(argv)
    if a.height is None:
        a.height = 175.0 if a.sex == "male" else 165.0
    if a.weight is None:
        a.weight = 70.0 if a.sex == "male" else 62.0
    if a.hair is None:
        a.hair = "short" if a.sex == "male" else "long"
    return a


if __name__ == "__main__":
    args = parse_args()
    ch = Character(sex=args.sex, age=args.age, height_cm=args.height,
                   weight_kg=args.weight, hair=args.hair,
                   hair_color=args.hair_color, top=args.top,
                   top_color=args.top_color, bottom=args.bottom,
                   bottom_color=args.bottom_color, skin=args.skin,
                   gear=args.gear, glove_color=args.glove_color)
    print(f"{ch.sex}, {ch.age:.0f}y, {ch.height_cm:.0f}cm/{ch.weight_kg:.0f}kg"
          f" -> BMI {ch.bmi:.1f}, est. body fat {ch.body_fat:.1f}%,"
          f" fatness {ch.f_torso:.2f}, height scale {ch.height_scale:.2f}")
    clip_builders = BOXING_CLIP_BUILDERS if args.clips == "boxing" else None
    b, root = build(ch, clip_builders)
    d = to_gltf_dict(b, root)
    write_glb(args.out, d, bytes(b.buffer))
