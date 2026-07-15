"""Export the low-poly character as a game-ready GLB (binary glTF).

The character is a hierarchy of rigid ellipsoid meshes parented to joint
nodes. Animation (idle, walk, jump, crouch) is baked into TRS keyframe
channels, so the GLB is fully self-contained and imports into Unity, Godot,
Unreal, three.js, Babylon.js, etc. with four working clips.

The legs carry a real knee joint (hip -> thigh -> knee -> shin -> shoe) so the
walk gets a proper stride bend, the jump can load and tuck, and the crouch can
fold. Each animation is a named clip; the game (player.gd) crossfades between
them by motion state.

Run:  python export_glb.py      ->  human.glb
"""
import math
import struct

# ---- dimensions (keep in sync with generate_human.py) -------------------
F = 1.0  # FATNESS
PALETTE = {
    "skin":  (0.98, 0.83, 0.70),
    "hair":  (0.25, 0.16, 0.13),
    "shirt": (0.45, 0.70, 0.90),
    "pants": (0.22, 0.26, 0.36),
    "shoes": (0.95, 0.94, 0.96),
    "eyes":  (0.10, 0.12, 0.18),
}


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


def build():
    b = GLBBuilder()

    # materials
    mtl = {name: b.add_material(name, rgb) for name, rgb in PALETTE.items()}

    # ---- geometries (ellipsoid half-extents) ----------------------------
    head_r = 0.27                       # a touch smaller -> less chibi
    geoms = {
        "torso":  ellipsoid_geom(0.30*F, 0.44, 0.22*F),
        "thigh":  capsule_geom(0.135*F, 0.20, 0.135*F),
        "shin":   capsule_geom(0.11*F, 0.20, 0.11*F),
        "shoe":   ellipsoid_geom(0.13*F, 0.07, 0.20*F),   # longer, points +Z
        "arm":    capsule_geom(0.095*F, 0.19, 0.10*F),
        "fore":   capsule_geom(0.082*F, 0.17, 0.088*F),
        "hand":   ellipsoid_geom(0.085*F, 0.10*F, 0.075*F),
        "neck":   ellipsoid_geom(0.09, 0.10, 0.09),
        "head":   ellipsoid_geom(head_r, head_r*1.08, head_r),
        "hair":   ellipsoid_geom(head_r*1.06, head_r*1.10, head_r*1.06,
                                 phi_end=math.pi*0.60),
        "eye":    ellipsoid_geom(0.026, 0.030, 0.026, seg=8, rings=6),
        "nose":   ellipsoid_geom(0.03, 0.028, 0.04, seg=7, rings=5),
    }
    mesh = {name: b.add_mesh(pos, nor, mtl[mat]) for name, (pos, nor), mat in [
        ("torso", geoms["torso"], "shirt"),
        ("thigh", geoms["thigh"], "pants"),
        ("shin",  geoms["shin"],  "pants"),
        ("shoe",  geoms["shoe"],  "shoes"),
        ("arm",   geoms["arm"],   "shirt"),
        ("fore",  geoms["fore"],  "skin"),
        ("hand",  geoms["hand"],  "skin"),
        ("neck",  geoms["neck"],  "skin"),
        ("head",  geoms["head"],  "skin"),
        ("hair",  geoms["hair"],  "hair"),
        ("eye",   geoms["eye"],   "eyes"),
        ("nose",  geoms["nose"],  "skin"),
    ]}

    # ---- node hierarchy (build leaves first so we know child indices) ----
    # node indices we want to animate get stashed in `nd`
    nd = {}

    # head: hair + eyes + nose
    eye_l = b.add_node("eyeL", mesh=mesh["eye"], translation=(0.10, 0.01, head_r*0.86))
    eye_r = b.add_node("eyeR", mesh=mesh["eye"], translation=(-0.10, 0.01, head_r*0.86))
    nose_n = b.add_node("nose", mesh=mesh["nose"], translation=(0, -0.05, head_r*0.94))
    hair_n = b.add_node("hair", mesh=mesh["hair"], translation=(0, 0.05, -0.02))
    head_n = b.add_node("head", mesh=mesh["head"], translation=(0, 0.30, 0),
                        children=[hair_n, eye_l, eye_r, nose_n])
    neck_n = b.add_node("neck", mesh=mesh["neck"], translation=(0, 0.30, 0),
                        children=[head_n])
    nd["neck"] = neck_n

    # arms: shoulder -> (arm mesh) elbow -> (fore mesh) wrist -> hand
    def build_arm(side_sign, name):
        hand = b.add_node(f"hand{name}", mesh=mesh["hand"], translation=(0, -0.20, 0))
        fore = b.add_node(f"fore{name}", mesh=mesh["fore"], translation=(0, -0.17, 0))
        elbow = b.add_node(f"elbow{name}", translation=(0, -0.20, 0),
                           children=[fore, hand])
        arm = b.add_node(f"arm{name}", mesh=mesh["arm"], translation=(0, -0.19, 0))
        shoulder = b.add_node(f"shoulder{name}",
                              translation=(0.30*F*side_sign, 0.30, 0),
                              children=[arm, elbow])
        return shoulder, elbow

    sh_l, el_l = build_arm(1, "L")
    sh_r, el_r = build_arm(-1, "R")
    nd["shL"], nd["elL"] = sh_l, el_l
    nd["shR"], nd["elR"] = sh_r, el_r

    torso_n = b.add_node("torso", mesh=mesh["torso"], translation=(0, 0.30, 0),
                         children=[neck_n, sh_l, sh_r])
    nd["torso"] = torso_n

    # legs: hip -> (thigh mesh) knee -> (shin mesh) ankle -> shoe
    def build_leg(side_sign, name):
        shoe = b.add_node(f"shoe{name}", mesh=mesh["shoe"], translation=(0, -0.24, 0.07))
        knee = b.add_node(f"knee{name}", translation=(0, -0.40, 0),
                          children=[b.add_node(f"shin{name}", mesh=mesh["shin"],
                                               translation=(0, -0.20, 0)), shoe])
        thigh = b.add_node(f"thigh{name}", mesh=mesh["thigh"], translation=(0, -0.20, 0))
        hip = b.add_node(f"hip{name}",
                         translation=(0.13*(0.7+0.3*F)*side_sign, 0, 0),
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

    # ---- animations -----------------------------------------------------
    b.animations = [clip.dict() for clip in (
        clip_idle(b, nd),
        clip_walk(b, nd),
        clip_jump(b, nd),
        clip_crouch(b, nd),
    )]
    return b, root_n


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


if __name__ == "__main__":
    b, root = build()
    d = to_gltf_dict(b, root)
    write_glb("human.glb", d, bytes(b.buffer))
