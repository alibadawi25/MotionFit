extends Node3D
## SprintTrack
##
## The scrolling stadium for Hurdle Dash. Like RunnerTrack, the athletes never
## move — this owns the illusion of speed by sliding tiled scenery past them —
## but where the zombie run is an endless midnight road, this is a finite,
## sunlit athletics track: red tartan lanes, white lane lines, grass verges and
## a full grandstand bowl packed with a living, animated crowd.
##
## The crowd is the set's centrepiece. Every spectator is a real little figure
## (a body + a head), but rendered through two MultiMeshes per tile — one draw
## call each — so a whole bowl of a few thousand people costs almost nothing.
## They breathe via [code]crowd.gdshader[/code]: a per-instance phase makes the
## stand shimmer, and a shared [code]excitement[/code] uniform (driven by
## sprint.gd through [method set_crowd_energy] / [method cheer_burst]) swings the
## crowd from an idle murmur to an out-of-seat roar.
##
## Because the race has a fixed length, the landmarks (hurdle rows, the start
## strip, the finish gantry) are NOT spawned/recycled like the runner's random
## hazards: every row exists up front at a known race distance, and
## [method sync] simply parks each at z = -(its distance - player distance)
## every frame. Scenery tiles still recycle ([method advance]) since the
## backdrop is endless in both directions.
##
## Gameplay (who cleared what) lives in sprint.gd; this node is only the set.
class_name SprintTrack

## Lane centres across the 4-lane track. sprint.gd assigns athletes to these.
const LANE_XS: Array[float] = [-3.0, -1.0, 1.0, 3.0]
const LANE_W: float = 2.0
const TRACK_HALF_W: float = 4.2
const TILE_LEN: float = 16.0
const TILE_COUNT: int = 9
## Tiles scrolling past this Z (behind the camera) wrap to the far end.
const RECYCLE_Z: float = 24.0

## Hurdle geometry: regulation-ish proportions, scaled to read at game camera.
const HURDLE_H: float = 0.84
const HURDLE_BAR_W: float = LANE_W - 0.3

## Grandstand bowl. A run of stepped seating decks either side of the track,
## capped by a back wall and a roof, with floodlight pylons on some tiles.
const STAND_GAP: float = 6.0       # apron between the trackside rail and tier 0
const TIER_COUNT: int = 6
const TIER_RISE: float = 1.25      # deck-to-deck height
const TIER_DEPTH: float = 1.9      # deck-to-deck outward step (the bowl's rake)
## Seats per deck: two rows across the deck, spaced this far apart down the tile.
const SEAT_SPACING: float = 0.58
const SEAT_ROWS: int = 2
## Roughly this share of seats are left empty (nobody sits shoulder-to-shoulder).
const EMPTY_CHANCE: float = 0.08
## Tiles carrying a floodlight pylon (they recycle, so these repeat down the run).
const FLOODLIGHT_TILES: Array[int] = [1, 5]

const TRACK_COLOR := Color(0.66, 0.28, 0.22)
const TRACK_COLOR_ALT := Color(0.6, 0.25, 0.2)
const LINE_COLOR := Color(0.93, 0.93, 0.95)
const KERB_COLOR := Color(0.9, 0.62, 0.2)
const GRASS_COLOR := Color(0.3, 0.52, 0.25)
const GRASS_COLOR_ALT := Color(0.27, 0.47, 0.22)
const RAIL_COLOR := Color(0.9, 0.91, 0.93)
const STAND_COLOR := Color(0.5, 0.52, 0.57)
const STAND_COLOR_DARK := Color(0.34, 0.36, 0.4)
const ROOF_COLOR := Color(0.26, 0.29, 0.35)
const HURDLE_POST_COLOR := Color(0.2, 0.35, 0.7)
const HURDLE_BAR_COLOR := Color(0.95, 0.95, 0.97)
## Trackside advertising boards — bright blocks that ring the infield.
const BOARD_COLORS: Array[Color] = [
	Color(0.9, 0.3, 0.2), Color(0.15, 0.45, 0.8), Color(0.95, 0.75, 0.2),
	Color(0.2, 0.6, 0.45), Color(0.55, 0.3, 0.7),
]
## Jersey-ish hues the crowd bodies are drawn from.
const CROWD_COLORS: Array[Color] = [
	Color(0.85, 0.3, 0.25), Color(0.3, 0.5, 0.85), Color(0.9, 0.75, 0.25),
	Color(0.35, 0.7, 0.4), Color(0.8, 0.5, 0.8), Color(0.92, 0.92, 0.95),
	Color(0.95, 0.55, 0.2), Color(0.25, 0.7, 0.75), Color(0.2, 0.25, 0.32),
]
## Skin tones for the crowd heads.
const SKIN_TONES: Array[Color] = [
	Color(0.92, 0.76, 0.63), Color(0.83, 0.63, 0.48), Color(0.7, 0.5, 0.36),
	Color(0.55, 0.38, 0.27), Color(0.42, 0.29, 0.21),
]

var _tiles: Array[Node3D] = []
var _hurdle_rows: Array[Node3D] = []
var _hurdle_dists: PackedFloat32Array = PackedFloat32Array()
var _finish: Node3D
var _start_strip: Node3D
var _race_dist: float = 0.0
## Shared materials/meshes so a whole stadium costs one of each.
var _mats: Dictionary = {}
var _body_mesh: ArrayMesh
var _head_mesh: ArrayMesh
var _crowd_mat: ShaderMaterial

## Crowd excitement, smoothed toward a base level (set by pace/progress) plus a
## decaying burst (spiked on clean hurdles and at the line). Pushed to the
## shared shader every frame in [method _process].
var _excite: float = 0.12
var _excite_base: float = 0.12
var _excite_burst: float = 0.0


## Builds the whole set: scenery tiles plus one hurdle row per entry in
## [param hurdle_dists] and the finish gantry at [param race_dist].
func setup(hurdle_dists: PackedFloat32Array, race_dist: float) -> void:
	_hurdle_dists = hurdle_dists
	_race_dist = race_dist
	_build_crowd_assets()
	for i in TILE_COUNT:
		var tile := _make_tile(i)
		tile.position.z = RECYCLE_Z - TILE_LEN * (i + 1)
		add_child(tile)
		_tiles.append(tile)
	for d in hurdle_dists:
		var row := _make_hurdle_row()
		add_child(row)
		_hurdle_rows.append(row)
	_start_strip = _make_start()
	add_child(_start_strip)
	_finish = _make_finish()
	add_child(_finish)
	sync(0.0)


## Smooths the crowd toward its base energy plus any decaying cheer burst, and
## feeds the result to the shared shader so every stand reacts together.
func _process(delta: float) -> void:
	_excite_burst = maxf(0.0, _excite_burst - delta * 0.7)
	var target: float = clampf(_excite_base + _excite_burst, 0.0, 1.0)
	_excite = lerpf(_excite, target, 1.0 - exp(-6.0 * delta))
	if _crowd_mat != null:
		_crowd_mat.set_shader_parameter("excitement", _excite)


## Sets the resting crowd energy (0 idle murmur … 1 full roar). sprint.gd raises
## this with race pace and progress.
func set_crowd_energy(base: float) -> void:
	_excite_base = clampf(base, 0.0, 1.0)


## A one-off surge on top of the base energy (a clean hurdle, the final stretch,
## the line) that decays back down over a couple of seconds.
func cheer_burst(amount: float = 0.6) -> void:
	_excite_burst = maxf(_excite_burst, clampf(amount, 0.0, 1.0))


## Slides the scenery tiles by [param dz] metres (the player's travel this
## frame), wrapping tiles that pass behind the camera to the far end.
func advance(dz: float) -> void:
	for tile in _tiles:
		tile.position.z += dz
		if tile.position.z > RECYCLE_Z:
			tile.position.z -= TILE_LEN * TILE_COUNT


## Parks every fixed landmark at its position relative to the player's
## [param player_dist] down the course. Cheap enough to run every frame.
func sync(player_dist: float) -> void:
	for i in _hurdle_rows.size():
		_hurdle_rows[i].position.z = -(_hurdle_dists[i] - player_dist)
	_start_strip.position.z = player_dist
	_finish.position.z = -(_race_dist - player_dist)


## Distance (m) of the next unpassed hurdle at/beyond [param player_dist], or
## -1.0 when none remain. Used for HUD jump coaching.
func next_hurdle_beyond(player_dist: float) -> float:
	for d in _hurdle_dists:
		if d >= player_dist:
			return d
	return -1.0


# --- Crowd assets ------------------------------------------------------------

## The two shared crowd meshes (body, head) and the one shared animated material.
func _build_crowd_assets() -> void:
	_crowd_mat = ShaderMaterial.new()
	_crowd_mat.shader = load("res://scenes/sprint/crowd.gdshader")
	_crowd_mat.set_shader_parameter("excitement", _excite)

	# Body: a stubby capsule (torso + tucked legs), origin at the seat.
	var body := CapsuleMesh.new()
	body.radius = 0.16
	body.height = 0.6
	body.radial_segments = 6
	body.rings = 1
	_body_mesh = _bake(body, Vector3(0.0, 0.3, 0.0))

	# Head: a small sphere sitting just above the shoulders.
	var head := SphereMesh.new()
	head.radius = 0.12
	head.height = 0.24
	head.radial_segments = 6
	head.rings = 4
	_head_mesh = _bake(head, Vector3(0.0, 0.66, 0.0))


## Wraps a primitive at [param offset] into a one-surface ArrayMesh so its origin
## sits where the MultiMesh instance transform (seat level) wants it.
func _bake(prim: Mesh, offset: Vector3) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.append_from(prim, 0, Transform3D(Basis(), offset))
	var mesh := ArrayMesh.new()
	st.commit(mesh)
	return mesh


# --- Builders ----------------------------------------------------------------

func _make_tile(index: int) -> Node3D:
	var tile := Node3D.new()
	tile.name = "Tile%d" % index
	# Track bed (alternating tiles get a faintly different tartan tone).
	_box(tile, Vector3(TRACK_HALF_W * 2.0, 0.2, TILE_LEN),
			Vector3(0.0, -0.1, 0.0),
			TRACK_COLOR if index % 2 == 0 else TRACK_COLOR_ALT)
	# Lane lines: one along each lane boundary.
	for x in [-4.0, -2.0, 0.0, 2.0, 4.0]:
		_box(tile, Vector3(0.07, 0.02, TILE_LEN), Vector3(x, 0.005, 0.0),
				LINE_COLOR)
	for side in [-1.0, 1.0]:
		# Raised painted kerb along the track edge.
		_box(tile, Vector3(0.16, 0.1, TILE_LEN),
				Vector3(side * (TRACK_HALF_W - 0.08), 0.04, 0.0), KERB_COLOR)
		# Infield / outfield grass (two tones so the verge isn't a flat slab).
		_box(tile, Vector3(STAND_GAP + 1.0, 0.18, TILE_LEN),
				Vector3(side * (TRACK_HALF_W + (STAND_GAP + 1.0) * 0.5), -0.11, 0.0),
				GRASS_COLOR if index % 2 == 0 else GRASS_COLOR_ALT)
		# Low white rail at the track edge.
		_box(tile, Vector3(0.1, 0.55, TILE_LEN),
				Vector3(side * (TRACK_HALF_W + 0.4), 0.27, 0.0), RAIL_COLOR)
		# Trackside advertising boards, just behind the rail.
		_ad_boards(tile, index, side)
		_stand(tile, side)
		if index in FLOODLIGHT_TILES:
			_floodlight(tile, side)
	_crowd(tile, index)
	return tile


## A ribbon of alternating sponsor boards behind the trackside rail.
func _ad_boards(tile: Node3D, index: int, side: float) -> void:
	var board_x: float = side * (TRACK_HALF_W + 0.75)
	var n: int = 5
	var seg: float = TILE_LEN / float(n)
	for i in n:
		var color: Color = BOARD_COLORS[(index * n + i) % BOARD_COLORS.size()]
		_box(tile, Vector3(0.08, 0.5, seg * 0.92),
				Vector3(board_x, 0.42, -TILE_LEN * 0.5 + seg * (i + 0.5)), color)


## The stepped seating decks, a back wall and a shading roof (one side).
func _stand(tile: Node3D, side: float) -> void:
	for tier in TIER_COUNT:
		var tx: float = side * (TRACK_HALF_W + STAND_GAP + tier * TIER_DEPTH)
		var ty: float = 1.0 + tier * TIER_RISE
		# The step: a solid riser + deck, tinted a touch darker every other tier.
		_box(tile, Vector3(TIER_DEPTH + 0.05, TIER_RISE, TILE_LEN),
				Vector3(tx, ty - TIER_RISE * 0.5, 0.0),
				STAND_COLOR if tier % 2 == 0 else STAND_COLOR_DARK)
	# Back wall behind the top deck.
	var wall_x: float = side * (TRACK_HALF_W + STAND_GAP + TIER_COUNT * TIER_DEPTH)
	var top_y: float = 1.0 + (TIER_COUNT - 1) * TIER_RISE
	_box(tile, Vector3(0.4, 3.0, TILE_LEN), Vector3(wall_x, top_y + 1.2, 0.0),
			STAND_COLOR_DARK)
	# Roof: a flat canopy cantilevered in over the top rows.
	_box(tile, Vector3(TIER_DEPTH * 3.2, 0.25, TILE_LEN + 0.2),
			Vector3(wall_x - side * TIER_DEPTH * 1.4, top_y + 2.7, 0.0), ROOF_COLOR)


## A tall floodlight pylon with an emissive bank angled in over the bowl.
func _floodlight(tile: Node3D, side: float) -> void:
	var px: float = side * (TRACK_HALF_W + STAND_GAP + TIER_COUNT * TIER_DEPTH + 1.6)
	_box(tile, Vector3(0.35, 15.0, 0.35), Vector3(px, 7.5, 0.0), STAND_COLOR_DARK)
	# The lamp bank: a dark backing plate faced with a grid of bright cells.
	var bank_x: float = px - side * 0.9
	_box(tile, Vector3(2.4, 1.8, 0.3), Vector3(bank_x, 15.2, 0.0), STAND_COLOR_DARK)
	var glow := _emissive_mat(Color(1.0, 0.98, 0.9), 2.4)
	for gx in 3:
		for gy in 2:
			var mi := MeshInstance3D.new()
			var lamp := BoxMesh.new()
			lamp.size = Vector3(0.6, 0.7, 0.12)
			mi.mesh = lamp
			mi.material_override = glow
			mi.position = Vector3(bank_x + (gx - 1) * 0.72,
					15.2 + (gy - 0.5) * 0.8, -side * 0.2)
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			tile.add_child(mi)


## Fills both stands of a tile with the animated crowd: one MultiMesh of bodies
## (jersey-coloured) and one of heads (skin-toned), sharing seat transforms and a
## per-instance phase so the bowl shimmers and cheers as one.
func _crowd(tile: Node3D, index: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = index * 911 + 17
	var xforms: Array[Transform3D] = []
	var jerseys: PackedColorArray = PackedColorArray()
	var skins: PackedColorArray = PackedColorArray()
	var customs: PackedColorArray = PackedColorArray()

	for side in [-1.0, 1.0]:
		for tier in TIER_COUNT:
			var deck_x: float = side * (TRACK_HALF_W + STAND_GAP + tier * TIER_DEPTH)
			var deck_y: float = 1.0 + tier * TIER_RISE
			var count: int = int(TILE_LEN / SEAT_SPACING)
			for row in SEAT_ROWS:
				# Back row a touch higher/further out, so rows read as depth.
				var rx: float = deck_x - side * (0.35 - row * 0.55)
				var ry: float = deck_y + row * 0.28
				for i in count:
					if rng.randf() < EMPTY_CHANCE:
						continue
					var z: float = -TILE_LEN * 0.5 + SEAT_SPACING * (i + 0.5)
					var pos := Vector3(
						rx + rng.randf_range(-0.07, 0.07),
						ry + rng.randf_range(-0.02, 0.03),
						z + rng.randf_range(-0.08, 0.08))
					var basis := Basis().scaled(
						Vector3.ONE * rng.randf_range(0.9, 1.12))
					xforms.append(Transform3D(basis, pos))
					jerseys.append(CROWD_COLORS[rng.randi() % CROWD_COLORS.size()])
					skins.append(SKIN_TONES[rng.randi() % SKIN_TONES.size()])
					customs.append(Color(rng.randf(), rng.randf(), 0.0, 0.0))

	tile.add_child(_crowd_layer(_body_mesh, xforms, jerseys, customs))
	tile.add_child(_crowd_layer(_head_mesh, xforms, skins, customs))


## One MultiMeshInstance for a crowd layer (bodies or heads): shared mesh + the
## shared animated material, per-instance colour and phase.
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
	# The crowd is animated far past the track; keep it drawn even when its tile
	# origin sits behind the camera plane.
	mmi.custom_aabb = AABB(Vector3(-40, 0, -TILE_LEN), Vector3(80, 20, TILE_LEN * 2))
	return mmi


## One row of four lane hurdles (blue posts, white bar), origin at track level.
func _make_hurdle_row() -> Node3D:
	var row := Node3D.new()
	for lane_x in LANE_XS:
		var post_dx: float = HURDLE_BAR_W * 0.5
		for px in [-post_dx, post_dx]:
			_box(row, Vector3(0.07, HURDLE_H, 0.07),
					Vector3(lane_x + px, HURDLE_H * 0.5, 0.0), HURDLE_POST_COLOR)
			# Stabiliser foot, pointing up-track like the real thing.
			_box(row, Vector3(0.07, 0.05, 0.55),
					Vector3(lane_x + px, 0.025, 0.18), HURDLE_POST_COLOR)
		_box(row, Vector3(HURDLE_BAR_W, 0.14, 0.05),
				Vector3(lane_x, HURDLE_H - 0.07, 0.0), HURDLE_BAR_COLOR)
	return row


## The start: a painted line, a lane number at each lane and low starting blocks.
func _make_start() -> Node3D:
	var start := Node3D.new()
	_box(start, Vector3(TRACK_HALF_W * 2.0, 0.02, 0.5), Vector3(0.0, 0.008, 0.0),
			LINE_COLOR)
	for lane in LANE_XS.size():
		var lane_x: float = LANE_XS[lane]
		# Starting blocks: a small angled pad just behind the line.
		_box(start, Vector3(LANE_W - 0.5, 0.08, 0.4),
				Vector3(lane_x, 0.04, 0.55), Color(0.2, 0.22, 0.28))
		var num := Label3D.new()
		num.text = str(lane + 1)
		num.font_size = 120
		num.pixel_size = 0.006
		num.modulate = LINE_COLOR
		num.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
		num.position = Vector3(lane_x, 0.02, 1.4)
		start.add_child(num)
	return start


## The finish: a checkered strip on the track and an overhead gantry with a
## FINISH banner, so the line is readable from far down the course.
func _make_finish() -> Node3D:
	var fin := Node3D.new()
	# Checkerboard strip: two rows of alternating squares.
	var sq: float = TRACK_HALF_W * 2.0 / 12.0
	for row in 2:
		for col in 12:
			var white: bool = (row + col) % 2 == 0
			_box(fin, Vector3(sq, 0.02, sq),
					Vector3(-TRACK_HALF_W + sq * (col + 0.5), 0.01,
							-sq * (row + 0.5)),
					Color(0.95, 0.95, 0.95) if white else Color(0.08, 0.08, 0.08))
	# Gantry posts + beam.
	for side in [-1.0, 1.0]:
		_box(fin, Vector3(0.18, 4.6, 0.18),
				Vector3(side * (TRACK_HALF_W + 0.5), 2.3, 0.0), RAIL_COLOR)
	_box(fin, Vector3(TRACK_HALF_W * 2.0 + 1.4, 0.7, 0.18),
			Vector3(0.0, 4.4, 0.0), Color(0.16, 0.2, 0.3))
	var banner := Label3D.new()
	banner.text = "FINISH"
	banner.font_size = 220
	banner.pixel_size = 0.004
	banner.modulate = Color(0.98, 0.98, 1.0)
	banner.position = Vector3(0.0, 4.4, 0.12)
	fin.add_child(banner)
	return fin


func _box(parent: Node3D, size: Vector3, pos: Vector3, color: Color) -> void:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = _mat(color)
	mi.mesh = mesh
	mi.position = pos
	parent.add_child(mi)


## One cached StandardMaterial3D per colour, shared across every use.
func _mat(color: Color) -> StandardMaterial3D:
	var key := color.to_html()
	if not _mats.has(key):
		var m := StandardMaterial3D.new()
		m.albedo_color = color
		m.roughness = 0.9
		_mats[key] = m
	return _mats[key]


## A self-lit material (floodlight cells) — cached under a distinct key so it
## never collides with the matte material of the same colour.
func _emissive_mat(color: Color, energy: float) -> StandardMaterial3D:
	var key := "glow_" + color.to_html()
	if not _mats.has(key):
		var m := StandardMaterial3D.new()
		m.albedo_color = color
		m.emission_enabled = true
		m.emission = color
		m.emission_energy_multiplier = energy
		_mats[key] = m
	return _mats[key]
