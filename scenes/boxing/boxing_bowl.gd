extends Node3D
## BoxingBowl
##
## The tiered grandstand bowl surrounding the ring: four banks of stepped seating
## packed with a MultiMesh crowd (bodies + heads, one draw call each — the same
## cheap approach as [SprintTrack]), cut through by aisle staircases with sloped
## handrails and lighter treads, and fronted by a low safety rail. One bank is
## given a central vomitory gap for the competitors' entrance tunnel (the tunnel
## portal + walkway themselves are built by [BoxingArena]).
##
## Owns the crowd's life: [method set_crowd_energy] / [method cheer_burst] and the
## shared shader are driven here so the whole bowl reacts as one.
class_name BoxingBowl

const BOWL_INNER: float = 11.0     # ring-centre → front row of the stands
const TIER_COUNT: int = 15
const TIER_RISE: float = 0.92
const TIER_DEPTH: float = 1.35
const SEAT_SPACING: float = 0.62
const SEAT_ROWS: int = 2
const EMPTY_CHANCE: float = 0.07
const BANK_HALF: float = 15.0
## Aisle stair lanes cut through each bank at these offsets along its width.
const AISLE_OFFSETS: Array[float] = [-10.0, -5.0, 0.0, 5.0, 10.0]
const AISLE_HALF: float = 0.95     # clear half-width of an aisle lane

const STAND_COLOR := Color(0.17, 0.18, 0.22)
const STAND_COLOR_ALT := Color(0.13, 0.14, 0.17)
const WALL_COLOR := Color(0.08, 0.08, 0.1)
const RAIL_COLOR := Color(0.55, 0.57, 0.63)
const STEP_COLOR := Color(0.32, 0.33, 0.38)     # lighter aisle tread
const CROWD_COLORS: Array[Color] = [
	Color(0.82, 0.28, 0.24), Color(0.28, 0.48, 0.82), Color(0.88, 0.72, 0.24),
	Color(0.34, 0.68, 0.4), Color(0.78, 0.48, 0.78), Color(0.9, 0.9, 0.93),
	Color(0.93, 0.53, 0.2), Color(0.24, 0.68, 0.72), Color(0.2, 0.22, 0.28),
]
const SKIN_TONES: Array[Color] = [
	Color(0.92, 0.76, 0.63), Color(0.83, 0.63, 0.48), Color(0.7, 0.5, 0.36),
	Color(0.55, 0.38, 0.27), Color(0.42, 0.29, 0.21),
]

var _mats: Dictionary = {}
var _body_mesh: ArrayMesh
var _head_mesh: ArrayMesh
var _crowd_mat: ShaderMaterial

var _excite: float = 0.14
var _excite_base: float = 0.14
var _excite_burst: float = 0.0


## Builds all four banks. The bank facing [param entrance_yaw] gets a central
## vomitory gap [param entrance_half] wide (no seats, no centre aisle) for the
## competitors' tunnel.
func build(entrance_yaw: float, entrance_half: float) -> void:
	_build_crowd_assets()
	var acc := _Crowd.new()
	for yaw in [0.0, PI * 0.5, PI, PI * 1.5]:
		var is_ent: bool = is_equal_approx(yaw, entrance_yaw)
		_bank(yaw, acc, is_ent, entrance_half)
	add_child(_crowd_layer(_body_mesh, acc.xforms, acc.jerseys, acc.customs))
	add_child(_crowd_layer(_head_mesh, acc.xforms, acc.skins, acc.customs))


## Smooths crowd energy toward its base + a decaying burst, feeding the shader.
func _process(delta: float) -> void:
	_excite_burst = maxf(0.0, _excite_burst - delta * 0.7)
	var target: float = clampf(_excite_base + _excite_burst, 0.0, 1.0)
	_excite = lerpf(_excite, target, 1.0 - exp(-6.0 * delta))
	if _crowd_mat != null:
		_crowd_mat.set_shader_parameter("excitement", _excite)


## Resting crowd energy (0 murmur … 1 roar).
func set_crowd_energy(base: float) -> void:
	_excite_base = clampf(base, 0.0, 1.0)


## A one-off surge (a knockdown, the bell) that decays back down.
func cheer_burst(amount: float = 0.6) -> void:
	_excite_burst = maxf(_excite_burst, clampf(amount, 0.0, 1.0))


# --- One grandstand bank -----------------------------------------------------

## A tiered bank facing the ring, rotated by [param yaw]: stepped decks, a front
## safety rail, aisle staircases, a back wall, and its spectators (accumulated
## into [param acc]). When [param is_ent], a central gap of half-width
## [param ent_half] is cleared for the entrance tunnel.
func _bank(yaw: float, acc: _Crowd, is_ent: bool, ent_half: float) -> void:
	var fwd := Vector3(sin(yaw), 0.0, cos(yaw))    # outward, away from ring
	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
	var rng := RandomNumberGenerator.new()
	rng.seed = int(yaw * 1000.0) + 31

	for tier in TIER_COUNT:
		var depth: float = BOWL_INNER + tier * TIER_DEPTH
		var height: float = 0.6 + tier * TIER_RISE
		var center := fwd * depth + Vector3(0.0, height - TIER_RISE * 0.5, 0.0)
		var mi := _box(Vector3(BANK_HALF * 2.0 + 0.1, TIER_RISE, TIER_DEPTH + 0.06),
				center, STAND_COLOR if tier % 2 == 0 else STAND_COLOR_ALT)
		mi.rotation.y = yaw
		# Lighter tread stripe up each aisle, so the lane reads as a staircase.
		for a in AISLE_OFFSETS:
			if is_ent and is_zero_approx(a):
				continue
			var tread := fwd * depth + right * a \
					+ Vector3(0.0, height + 0.02, 0.0)
			var ts := _box(Vector3(AISLE_HALF * 2.0, 0.05, TIER_DEPTH + 0.06),
					tread, STEP_COLOR)
			ts.rotation.y = yaw
		_seat_row(acc, rng, fwd, right, depth, height, is_ent, ent_half)

	_front_rail(fwd, right, yaw, is_ent, ent_half)
	_aisle_rails(fwd, right, is_ent)
	# Dark back wall capping the bank.
	var back_d: float = BOWL_INNER + TIER_COUNT * TIER_DEPTH
	var wall := _box(Vector3(BANK_HALF * 2.0 + 0.2, 8.0, 0.5),
			fwd * back_d + Vector3(0.0, 0.6 + TIER_COUNT * TIER_RISE, 0.0),
			WALL_COLOR)
	wall.rotation.y = yaw


## Seats one deck: two staggered rows across the bank, skipping aisle lanes, the
## entrance gap, and a random scattering of empties.
func _seat_row(acc: _Crowd, rng: RandomNumberGenerator, fwd: Vector3,
		right: Vector3, depth: float, height: float,
		is_ent: bool, ent_half: float) -> void:
	for seat_row in SEAT_ROWS:
		var seat_depth: float = depth - TIER_DEPTH * 0.2 + seat_row * 0.5
		var seat_y: float = height + 0.05 + seat_row * 0.26
		var count: int = int((BANK_HALF * 2.0) / SEAT_SPACING)
		for i in count:
			var off: float = -BANK_HALF + SEAT_SPACING * (i + 0.5)
			if is_ent and absf(off) < ent_half:
				continue
			if _in_aisle(off):
				continue
			if rng.randf() < EMPTY_CHANCE:
				continue
			var pos := fwd * (seat_depth + rng.randf_range(-0.05, 0.05)) \
					+ right * (off + rng.randf_range(-0.06, 0.06)) \
					+ Vector3(0.0, seat_y + rng.randf_range(-0.02, 0.03), 0.0)
			var basis := Basis().rotated(Vector3.UP, atan2(fwd.x, fwd.z)) \
					.scaled(Vector3.ONE * rng.randf_range(0.9, 1.12))
			acc.xforms.append(Transform3D(basis, pos))
			acc.jerseys.append(CROWD_COLORS[rng.randi() % CROWD_COLORS.size()])
			acc.skins.append(SKIN_TONES[rng.randi() % SKIN_TONES.size()])
			acc.customs.append(Color(rng.randf(), rng.randf(), 0.0, 0.0))


func _in_aisle(off: float) -> bool:
	for a in AISLE_OFFSETS:
		if absf(off - a) < AISLE_HALF:
			return true
	return false


## A low white safety rail along the front of the bank (with the entrance gap).
func _front_rail(fwd: Vector3, right: Vector3, yaw: float,
		is_ent: bool, ent_half: float) -> void:
	var y: float = 0.6 + 0.55
	if is_ent:
		var seg_half: float = (BANK_HALF - ent_half) * 0.5
		for s in [-1.0, 1.0]:
			var cx: float = s * (ent_half + seg_half)
			var r := _box(Vector3(seg_half * 2.0, 0.14, 0.06),
					fwd * (BOWL_INNER - 0.1) + right * cx + Vector3(0, y, 0),
					RAIL_COLOR)
			r.rotation.y = yaw
	else:
		var r := _box(Vector3(BANK_HALF * 2.0, 0.14, 0.06),
				fwd * (BOWL_INNER - 0.1) + Vector3(0, y, 0), RAIL_COLOR)
		r.rotation.y = yaw


## A sloped handrail up both sides of each aisle, following the bank's rake.
func _aisle_rails(fwd: Vector3, right: Vector3, is_ent: bool) -> void:
	var y0: float = 0.6 + 0.9
	var y1: float = 0.6 + (TIER_COUNT - 1) * TIER_RISE + 0.9
	var d0: float = BOWL_INNER
	var d1: float = BOWL_INNER + (TIER_COUNT - 1) * TIER_DEPTH
	for a in AISLE_OFFSETS:
		if is_ent and is_zero_approx(a):
			continue
		for s in [-1.0, 1.0]:
			var ax: float = a + s * AISLE_HALF
			var p0 := fwd * d0 + right * ax + Vector3(0, y0, 0)
			var p1 := fwd * d1 + right * ax + Vector3(0, y1, 0)
			_rail(p0, p1)


## One aligned rail box between two points (used for the sloped aisle handrails).
func _rail(p0: Vector3, p1: Vector3) -> void:
	var mid := (p0 + p1) * 0.5
	var dir := p1 - p0
	var mi := _box(Vector3(0.05, 0.05, dir.length()), mid, RAIL_COLOR)
	var up := Vector3.UP if absf(dir.normalized().dot(Vector3.UP)) < 0.98 \
			else Vector3.RIGHT
	mi.basis = Basis.looking_at(dir.normalized(), up)


# --- Crowd assets ------------------------------------------------------------

func _build_crowd_assets() -> void:
	_crowd_mat = ShaderMaterial.new()
	_crowd_mat.shader = load("res://scenes/sprint/crowd.gdshader")
	_crowd_mat.set_shader_parameter("excitement", _excite)
	var body := CapsuleMesh.new()
	body.radius = 0.16
	body.height = 0.62
	body.radial_segments = 6
	body.rings = 1
	_body_mesh = _bake(body, Vector3(0.0, 0.31, 0.0))
	var head := SphereMesh.new()
	head.radius = 0.12
	head.height = 0.24
	head.radial_segments = 6
	head.rings = 4
	_head_mesh = _bake(head, Vector3(0.0, 0.68, 0.0))


func _bake(prim: Mesh, offset: Vector3) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.append_from(prim, 0, Transform3D(Basis(), offset))
	var mesh := ArrayMesh.new()
	st.commit(mesh)
	return mesh


func _crowd_layer(mesh: ArrayMesh, xforms: Array[Transform3D],
		colors: PackedColorArray, customs: PackedColorArray) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
		mm.set_instance_color(i, colors[i])
		mm.set_instance_custom_data(i, customs[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = _crowd_mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.custom_aabb = AABB(Vector3(-40, 0, -40), Vector3(80, 24, 80))
	return mmi


func _box(size: Vector3, pos: Vector3, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = _mat(color)
	mi.mesh = mesh
	mi.position = pos
	add_child(mi)
	return mi


func _mat(color: Color) -> StandardMaterial3D:
	var key := color.to_html()
	if not _mats.has(key):
		var m := StandardMaterial3D.new()
		m.albedo_color = color
		m.roughness = 0.9
		_mats[key] = m
	return _mats[key]


## Accumulator for crowd instance data across all banks.
class _Crowd:
	var xforms: Array[Transform3D] = []
	var jerseys: PackedColorArray = PackedColorArray()
	var skins: PackedColorArray = PackedColorArray()
	var customs: PackedColorArray = PackedColorArray()
