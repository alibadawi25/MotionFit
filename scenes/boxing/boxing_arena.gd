extends Node3D
## BoxingArena
##
## The indoor-stadium set for the Boxing game: a raised ring (a [BoxingRing])
## surrounded by a crowd-filled grandstand bowl (a [BoxingBowl], with aisle
## staircases), ringed by sponsor boards and ringside seating, roofed by a dark
## truss ceiling and lit by a four-sided centre-hung jumbotron. One bank carries a
## **competitors' entrance**: a lit tunnel portal opening onto a barriered walkway
## that leads across the floor to a set of ring-access steps.
##
## Built entirely from primitives + the bowl's two crowd MultiMeshes. This node is
## only the set; it forwards [method set_crowd_energy] / [method cheer_burst] to
## the bowl. Origin is the ring centre at floor level.
class_name BoxingArena

## The bank (by facing yaw) that carries the entrance tunnel, and how wide the
## vomitory gap / walkway are.
const ENTRANCE_YAW: float = PI
const ENTRANCE_HALF: float = 2.3
const WALKWAY_HALF: float = 1.6
const RING_EDGE: float = 4.1          # ring apron half-extent at floor level
const CEILING_Y: float = 20.0

const FLOOR_COLOR := Color(0.12, 0.12, 0.14)
const RINGSIDE_COLOR := Color(0.16, 0.16, 0.19)
const WALL_COLOR := Color(0.08, 0.08, 0.1)
const TRUSS_COLOR := Color(0.2, 0.21, 0.24)
const CHAIR_COLOR := Color(0.05, 0.05, 0.07)
const SCREEN_COLOR := Color(0.2, 0.34, 0.62)
const CARPET_COLOR := Color(0.42, 0.08, 0.09)      # entrance runner
const STEEL_COLOR := Color(0.5, 0.52, 0.58)
const PORTAL_COLOR := Color(0.04, 0.04, 0.05)
const GATE_GLOW := Color(0.25, 0.45, 0.9)
const BOARD_COLORS: Array[Color] = [
	Color(0.86, 0.22, 0.18), Color(0.14, 0.42, 0.78), Color(0.9, 0.72, 0.2),
	Color(0.2, 0.58, 0.44), Color(0.9, 0.9, 0.93),
]

var _mats: Dictionary = {}
var _bowl: BoxingBowl
var _jumbo: SubViewport      # the fight-card screen content (boxing_jumbotron.gd)


func _ready() -> void:
	build()


## Builds the entire arena. Call once.
func build() -> void:
	_floor()
	_ringside()
	_bowl_node()
	_walls_and_roof()
	_jumbotron()
	_entrance()
	_ring_and_steps()


## Resting crowd energy (0 murmur … 1 roar). Forwarded to the bowl.
func set_crowd_energy(base: float) -> void:
	if _bowl != null:
		_bowl.set_crowd_energy(base)


## A one-off crowd surge (a knockdown, the bell). Forwarded to the bowl.
func cheer_burst(amount: float = 0.6) -> void:
	if _bowl != null:
		_bowl.cheer_burst(amount)


## Sets the main-event card shown on the jumbotron: the two corners' names and a
## strapline. Safe to call before/after [method build].
func set_bout(player_name: String, opp_name: String, subtitle: String) -> void:
	if _jumbo != null and _jumbo.has_method("configure"):
		_jumbo.configure(player_name, opp_name, subtitle)


# --- Ground, ringside & bowl -------------------------------------------------

func _floor() -> void:
	_box(Vector3(60.0, 0.4, 60.0), Vector3(0.0, -0.2, 0.0), FLOOR_COLOR)
	_box(Vector3(BoxingBowl.BOWL_INNER * 2.0, 0.04, BoxingBowl.BOWL_INNER * 2.0),
			Vector3(0.0, 0.001, 0.0), RINGSIDE_COLOR)


## Sponsor boards ringing the ring, and rows of ringside folding chairs — with a
## clear lane on the entrance side for the walkway.
func _ringside() -> void:
	for yaw in [0.0, PI * 0.5, PI, PI * 1.5]:
		var fwd := Vector3(sin(yaw), 0.0, cos(yaw))
		var right := Vector3(cos(yaw), 0.0, -sin(yaw))
		var is_ent: bool = is_equal_approx(yaw, ENTRANCE_YAW)
		var n: int = 7
		var seg: float = (RING_EDGE * 2.0) / float(n)
		for i in n:
			var off: float = -RING_EDGE + seg * (i + 0.5)
			if is_ent and absf(off) < WALKWAY_HALF:
				continue
			var color: Color = BOARD_COLORS[i % BOARD_COLORS.size()]
			var p := fwd * (RING_EDGE + 0.2) + right * off
			var mi := _box(Vector3(seg * 0.92, 0.7, 0.1),
					Vector3(p.x, 0.35, p.z), color)
			mi.rotation.y = yaw
		for row in 2:
			var rz: float = RING_EDGE + 1.4 + row * 0.9
			var count: int = int((BoxingBowl.BANK_HALF * 1.6) / 0.7)
			for i in count:
				var off2: float = -count * 0.35 + i * 0.7
				if is_ent and absf(off2) < WALKWAY_HALF + 0.6:
					continue
				var p2 := fwd * rz + right * off2
				var mi2 := _box(Vector3(0.5, 0.5, 0.5),
						Vector3(p2.x, 0.25, p2.z), CHAIR_COLOR)
				mi2.rotation.y = yaw


func _bowl_node() -> void:
	_bowl = BoxingBowl.new()
	_bowl.name = "Bowl"
	add_child(_bowl)
	_bowl.build(ENTRANCE_YAW, ENTRANCE_HALF)


# --- Roof, walls & jumbotron -------------------------------------------------

func _walls_and_roof() -> void:
	_box(Vector3(70.0, 0.6, 70.0), Vector3(0.0, CEILING_Y, 0.0), WALL_COLOR)
	for gx in range(-2, 3):
		_box(Vector3(0.4, 0.5, 60.0), Vector3(gx * 10.0, CEILING_Y - 0.6, 0.0),
				TRUSS_COLOR)
	for gz in range(-2, 3):
		_box(Vector3(60.0, 0.5, 0.4), Vector3(0.0, CEILING_Y - 0.6, gz * 10.0),
				TRUSS_COLOR)
	for p in [Vector3(-6, 0, -6), Vector3(6, 0, -6), Vector3(-6, 0, 6),
			Vector3(6, 0, 6)]:
		var lamp := _box(Vector3(1.6, 0.3, 1.6),
				Vector3(p.x, CEILING_Y - 1.2, p.z),
				Color(1.0, 0.98, 0.9), 2.6)
		lamp.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## The four-sided centre-hung jumbotron slung under the trusses on cables.
func _jumbotron() -> void:
	var cy: float = 12.0
	var half: float = 3.4
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			_box(Vector3(0.08, CEILING_Y - cy - half, 0.08),
					Vector3(sx * half * 0.7,
							cy + half + (CEILING_Y - cy - half) * 0.5,
							sz * half * 0.7), TRUSS_COLOR)
	_box(Vector3(half * 2.0 + 0.4, 3.4, half * 2.0 + 0.4),
			Vector3(0.0, cy, 0.0), Color(0.03, 0.03, 0.04))
	# Live fight-card content, rendered once and shared across all four faces.
	_jumbo = preload("res://scenes/boxing/boxing_jumbotron.gd").new()
	_jumbo.name = "Jumbotron"
	add_child(_jumbo)
	var screen_mat := StandardMaterial3D.new()
	screen_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	screen_mat.albedo_texture = _jumbo.get_texture()
	screen_mat.emission_enabled = true
	screen_mat.emission_texture = _jumbo.get_texture()
	screen_mat.emission = Color.WHITE
	screen_mat.emission_energy_multiplier = 0.9
	screen_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	for yaw in [0.0, PI * 0.5, PI, PI * 1.5]:
		var fwd := Vector3(sin(yaw), 0.0, cos(yaw))
		# A flat quad (upright UVs) is the right primitive for a screen — a BoxMesh
		# rotates the card across its faces.
		var screen := MeshInstance3D.new()
		var quad := QuadMesh.new()
		quad.size = Vector2(half * 1.8, 2.0)
		quad.material = screen_mat
		screen.mesh = quad
		# Clear of the cube face (half-extent half+0.2) so it isn't occluded.
		screen.position = fwd * (half + 0.25) + Vector3(0.0, cy + 0.2, 0.0)
		# +yaw turns the quad's textured front face outward (toward viewers).
		screen.rotation.y = yaw
		screen.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(screen)
		var skirt := _box(Vector3(half * 1.9, 0.6, 0.06),
				fwd * (half + 0.24) + Vector3(0.0, cy - 1.2, 0.0),
				Color(0.8, 0.14, 0.12), 0.8)
		skirt.rotation.y = yaw
	var glow := OmniLight3D.new()
	glow.position = Vector3(0.0, cy - 2.0, 0.0)
	glow.light_energy = 1.4
	glow.omni_range = 26.0
	glow.light_color = Color(0.7, 0.82, 1.0)
	glow.shadow_enabled = false
	add_child(glow)


# --- Competitors' entrance ---------------------------------------------------

## The tunnel portal set into the entrance bank, its barriered walkway across the
## floor to the ring, and a lit gateway over the mouth.
func _entrance() -> void:
	var fwd := Vector3(sin(ENTRANCE_YAW), 0.0, cos(ENTRANCE_YAW))
	var right := Vector3(cos(ENTRANCE_YAW), 0.0, -sin(ENTRANCE_YAW))
	var mouth: float = BoxingBowl.BOWL_INNER
	var depth: float = 4.0                 # how far the portal recedes into stand

	# Recessed dark tunnel interior (floor of the vomitory).
	_box(Vector3(ENTRANCE_HALF * 2.0, 4.0, depth + 1.0),
			fwd * (mouth + depth * 0.5) + Vector3(0, 2.0, 0), PORTAL_COLOR)
	# Side pillars flanking the mouth.
	for s in [-1.0, 1.0]:
		var pillar := _box(Vector3(0.6, 4.2, depth),
				fwd * (mouth + depth * 0.5)
					+ right * s * (ENTRANCE_HALF + 0.3)
					+ Vector3(0, 2.1, 0), STEEL_COLOR)
		pillar.rotation.y = ENTRANCE_YAW
	# Lintel beam across the top.
	var lintel := _box(Vector3(ENTRANCE_HALF * 2.0 + 1.2, 0.8, depth),
			fwd * (mouth + depth * 0.5) + Vector3(0, 4.0, 0), Color(0.1, 0.1, 0.12))
	lintel.rotation.y = ENTRANCE_YAW
	# Emissive gateway sign strip on the front face of the lintel.
	var sign := _box(Vector3(ENTRANCE_HALF * 2.0, 0.55, 0.12),
			fwd * (mouth - 0.02) + Vector3(0, 3.7, 0), GATE_GLOW, 2.2)
	sign.rotation.y = ENTRANCE_YAW
	sign.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var gate_light := OmniLight3D.new()
	gate_light.position = fwd * (mouth - 0.5) + Vector3(0, 3.2, 0)
	gate_light.light_energy = 2.0
	gate_light.omni_range = 9.0
	gate_light.light_color = GATE_GLOW
	gate_light.shadow_enabled = false
	add_child(gate_light)

	_walkway(fwd, right, mouth)


## The carpet runner from the tunnel mouth to the ring, flanked by crowd barriers.
func _walkway(fwd: Vector3, right: Vector3, mouth: float) -> void:
	var near: float = RING_EDGE + 0.3
	var length: float = mouth - near
	var mid: float = (mouth + near) * 0.5
	var carpet := _box(Vector3(WALKWAY_HALF * 2.0, 0.06, length),
			fwd * mid + Vector3(0, 0.03, 0), CARPET_COLOR)
	carpet.rotation.y = ENTRANCE_YAW
	# Barrier rails + posts down both sides.
	var posts: int = int(length / 1.4) + 1
	for s in [-1.0, 1.0]:
		var bx: float = s * (WALKWAY_HALF + 0.15)
		var rail := _box(Vector3(0.05, 0.06, length),
				fwd * mid + right * bx + Vector3(0, 0.85, 0), STEEL_COLOR)
		rail.rotation.y = ENTRANCE_YAW
		for i in posts:
			var f: float = near + length * (float(i) / float(posts - 1))
			_box(Vector3(0.07, 0.9, 0.07),
					fwd * f + right * bx + Vector3(0, 0.45, 0), STEEL_COLOR)


# --- Ring + access steps -----------------------------------------------------

func _ring_and_steps() -> void:
	var ring := preload("res://scenes/boxing/boxing_ring.gd").new()
	ring.name = "Ring"
	add_child(ring)
	# A short staircase up to the ring apron on the entrance side.
	var fwd := Vector3(sin(ENTRANCE_YAW), 0.0, cos(ENTRANCE_YAW))
	var steps: int = 4
	for i in steps:
		var h: float = BoxingRing.CANVAS_Y * (float(i + 1) / float(steps))
		var f: float = RING_EDGE + 0.55 - i * 0.26
		var step := _box(Vector3(1.6, 0.12, 0.32),
				fwd * f + Vector3(0, h - 0.06, 0), STEEL_COLOR)
		step.rotation.y = ENTRANCE_YAW
		# Riser under each tread.
		var riser := _box(Vector3(1.6, h, 0.06),
				fwd * (f + 0.13) + Vector3(0, h * 0.5, 0), Color(0.1, 0.1, 0.12))
		riser.rotation.y = ENTRANCE_YAW


# --- Primitive helpers -------------------------------------------------------

func _box(size: Vector3, pos: Vector3, color: Color,
		emit: float = 0.0) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = _mat(color, emit)
	mi.mesh = mesh
	mi.position = pos
	add_child(mi)
	return mi


## One cached material per colour; [param emit] > 0 makes a distinct self-lit
## variant (lamp banks, jumbotron/gateway).
func _mat(color: Color, emit: float = 0.0) -> StandardMaterial3D:
	var key := ("glow%.1f_" % emit if emit > 0.0 else "") + color.to_html()
	if not _mats.has(key):
		var m := StandardMaterial3D.new()
		m.albedo_color = color
		m.roughness = 0.9
		if emit > 0.0:
			m.emission_enabled = true
			m.emission = color
			m.emission_energy_multiplier = emit
		_mats[key] = m
	return _mats[key]
