extends Node3D
## WorldScatter — plants the open world's trees and boulders at load.
##
## A jittered grid of candidate points is filtered by the SAME rules that paint
## the terrain (tools/paint_terrain.gd): height picks the band (beach → meadow →
## cold summit), slope keeps trees off cliffs, and the splat map decides what
## grows where (trees on grass, rocks on stone). A clump noise gathers trees
## into woods with clearings instead of an even sprinkle. Everything lands in
## three MultiMeshes — one draw call per kind — with a per-instance tint so no
## two trees read identical, plus invisible trunk/boulder colliders on a single
## StaticBody3D (shapes added through the PhysicsServer: ~1200 CollisionShape3D
## nodes would cost far more than the shapes themselves).
##
## Placement is deterministic (fixed seed): the forest is part of the world,
## not a dice roll per session.
##
## Also builds the one hand-placed landmark, the crystal grotto (GROTTO_POS):
## a walk-in boulder shell that rides the same MultiMesh + collider plumbing.

const ScatterMeshes := preload("res://scenes/open-world/scatter_meshes.gd")

## The terrain's own data maps, sampled directly — the same source of truth the
## painter wrote. (The splat is read through the import cache; it is imported
## losslessly, so the weights survive intact.)
const HEIGHT_MAP := "res://Terrain/height.res"
const SPLAT_MAP := "res://Terrain/splat.png"

## Keep inside the fog border (world_border.gd HALF_EXTENT 496): scenery in the
## last metres of murk is fine — the woods fading INTO the wall sells it — but
## nothing may stand outside the world.
const HALF_EXTENT := 488.0
## Candidate spacing in metres. With thinning chances below this yields roughly
## a thousand trees and a few hundred rocks over the 1 km² island.
const CELL := 12.0
const SEED := 20260717
## Hard caps — safety rails so a tuning mistake can't melt the frame budget.
const MAX_TREES := 1100
const MAX_ROCKS := 420

## World-space height bands (metres). Sea sits at 13.5; the cold band of
## altitude_effects.gd starts at 55, and the roamable midlands (including the
## spawn plateau at ~64-68) sit ABOVE that — so the treeline reaches past the
## start of the cold and thins out on the way (see TREELINE_FADE_Y), with
## conifers owning the upper half.
const TREE_MIN_Y := 16.5
const TREE_MAX_Y := 66.0
const TREELINE_FADE_Y := 54.0
const CONIFER_Y := 45.0
const ROCK_MIN_Y := 15.5
const ALPINE_Y := 50.0
## Slope limits (degrees).
const TREE_MAX_SLOPE := 26.0
const ROCK_MAX_SLOPE := 52.0
## Nothing spawns this close to the player's start line.
const SPAWN_CLEAR := Vector3(182.3, 0.0, -6.0)
const SPAWN_CLEAR_RADIUS := 9.0

## The grotto: a hollow knoll of oversized boulders on the mountain's east
## flank — the walkable cave prototype. A hemisphere shell of rocks with a wide
## east-facing mouth (webcam steering needs a forgiving entrance), an amber
## light and a crystal cluster inside. Site picked with tools/probe_spot.gd:
## ground y 47.7, slope < 2 deg, ~195 m west of the spawn plateau.
const GROTTO_POS := Vector3(228.0, 47.4, -60.0)
const GROTTO_SHELL_R := 6.0
const GROTTO_MOUTH_AZ_DEG := 62.0  # half-angle of the opening, around +X (east)
const GROTTO_CLEAR_RADIUS := 15.0  # ordinary scatter keeps out of the grotto

@export var terrain_path: NodePath

# Collision shapes added via the PhysicsServer must stay referenced or they free.
var _shapes: Array[Shape3D] = []


func _ready() -> void:
	var terrain := get_node_or_null(terrain_path) as Node3D
	var height_img := _load_image(HEIGHT_MAP)
	var splat_img := _load_image(SPLAT_MAP)
	if terrain == null or height_img == null or splat_img == null:
		push_warning("WorldScatter: terrain or data maps missing; world stays bare")
		return
	# World → heightmap-pixel mapping, taken from the terrain itself so scale /
	# centering stay its business (map scale rides in the basis).
	var to_map: Transform3D = terrain.get_internal_transform().affine_inverse()
	var y_scale: float = terrain.get_internal_transform().basis.y.y

	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var clumps := FastNoiseLite.new()  # woods-with-clearings mask
	clumps.seed = SEED
	clumps.frequency = 0.009

	var conifers: Array[Transform3D] = []
	var broadleafs: Array[Transform3D] = []
	var rocks: Array[Transform3D] = []
	var steps := int(HALF_EXTENT * 2.0 / CELL)
	for gz in steps:
		for gx in steps:
			var wx := -HALF_EXTENT + (gx + rng.randf()) * CELL
			var wz := -HALF_EXTENT + (gz + rng.randf()) * CELL
			var map := to_map * Vector3(wx, 0.0, wz)
			var wy := _height_at(height_img, map.x, map.z) * y_scale
			var slope := _slope_deg(height_img, map.x, map.z, y_scale)
			var ground := splat_img.get_pixel(
					clampi(int(map.x), 0, splat_img.get_width() - 1),
					clampi(int(map.z), 0, splat_img.get_height() - 1))
			if Vector3(wx, 0.0, wz).distance_to(SPAWN_CLEAR) < SPAWN_CLEAR_RADIUS:
				continue
			if Vector2(wx, wz).distance_to(
					Vector2(GROTTO_POS.x, GROTTO_POS.z)) < GROTTO_CLEAR_RADIUS:
				continue

			# --- trees: on grass, gentle ground, gathered into woods --------
			if ground.r > 0.5 and wy > TREE_MIN_Y and wy < TREE_MAX_Y \
					and slope < TREE_MAX_SLOPE:
				var wooded := clumps.get_noise_2d(wx, wz) > 0.08
				var chance := 0.62 if wooded else 0.045
				# Woods thin out toward the treeline instead of stopping dead.
				chance *= 1.0 - smoothstep(TREELINE_FADE_Y, TREE_MAX_Y, wy) * 0.85
				if rng.randf() < chance:
					var s := rng.randf_range(0.8, 1.4)
					var t := _stand(Vector3(wx, wy - 0.12 * s, wz), s, rng, 0.045)
					if wy > CONIFER_Y or rng.randf() < 0.3:
						conifers.append(t)
					else:
						broadleafs.append(t)
					continue

			# --- rocks: stony ground, alpine heights, odd meadow boulder ----
			var rocky := ground.g > 0.4 or ground.b > 0.4 or wy > ALPINE_Y
			var rock_chance := 0.11 if rocky else 0.015
			if wy > ROCK_MIN_Y and slope < ROCK_MAX_SLOPE \
					and rng.randf() < rock_chance:
				var rs := rng.randf_range(0.4, 1.7)
				var basis := Basis(Vector3.UP, rng.randf_range(0.0, TAU)) \
						.rotated(Vector3.RIGHT, rng.randf_range(-0.3, 0.3)) \
						.scaled(Vector3(rs * rng.randf_range(0.85, 1.25), rs,
								rs * rng.randf_range(0.85, 1.25)))
				rocks.append(Transform3D(basis, Vector3(wx, wy - 0.28 * rs, wz)))

	if conifers.size() + broadleafs.size() > MAX_TREES:
		var keep := float(MAX_TREES) / float(conifers.size() + broadleafs.size())
		conifers.resize(int(conifers.size() * keep))
		broadleafs.resize(int(broadleafs.size() * keep))
	if rocks.size() > MAX_ROCKS:
		rocks.resize(MAX_ROCKS)
	# Appended after the cap on purpose: the grotto is a landmark, not scatter,
	# and must never be thinned away. Riding in the boulder MultiMesh + collider
	# list means it needs no rendering or physics machinery of its own.
	rocks.append_array(_grotto_shell())

	rng.seed = SEED + 1  # tints independent of how placement consumed the stream
	_make_multimesh("Conifers", ScatterMeshes.build_conifer(), conifers, rng)
	_make_multimesh("Broadleafs", ScatterMeshes.build_broadleaf(), broadleafs, rng)
	_make_multimesh("Boulders", ScatterMeshes.build_boulder(), rocks, rng)
	_build_colliders(conifers + broadleafs, rocks)
	_build_grotto_interior()


## The grotto's rock shell: boulders on a hemisphere around GROTTO_POS, in
## three rings (walls, shoulders, roof slabs), leaving a gap of
## +/- GROTTO_MOUTH_AZ_DEG around +X for the mouth. Neighbours overlap enough
## to close the shell; the chinks that remain read as natural rockfall.
func _grotto_shell() -> Array[Transform3D]:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED + 2
	var out: Array[Transform3D] = []
	# elevation deg, slots, azimuth offset deg, scale, y squash, keeps mouth open
	var rings: Array = [
		[10.0, 10, 0.0, 3.4, 1.0, true],
		[40.0, 8, 22.0, 3.0, 1.0, true],
		[70.0, 3, 60.0, 3.3, 0.65, false],  # roof: high enough to clear heads
	]
	for ring in rings:
		var elev: float = deg_to_rad(ring[0])
		var slots: int = ring[1]
		for i in slots:
			var az: float = deg_to_rad(ring[2]) + TAU * float(i) / float(slots)
			if ring[5] and absf(rad_to_deg(wrapf(az, -PI, PI))) < GROTTO_MOUTH_AZ_DEG:
				continue
			var dir := Vector3(cos(az) * cos(elev), sin(elev), sin(az) * cos(elev))
			var s: float = ring[3] * rng.randf_range(0.9, 1.1)
			var basis := Basis(Vector3.UP, rng.randf_range(0.0, TAU)) \
					.scaled(Vector3(s, s * ring[4], s))
			out.append(Transform3D(basis, GROTTO_POS + dir * GROTTO_SHELL_R))
	return out


## What makes the shell a place: an amber light overhead and a crystal cluster
## against the back wall (both deliberately visible from outside through the
## mouth — the glow is the invitation to come in).
func _build_grotto_interior() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED + 3
	var lamp := OmniLight3D.new()
	lamp.name = "GrottoLamp"
	lamp.position = GROTTO_POS + Vector3(0.0, 2.6, 0.0)
	lamp.light_color = Color(1.0, 0.76, 0.46)
	lamp.light_energy = 2.2
	lamp.omni_range = 11.0
	lamp.shadow_enabled = true
	add_child(lamp)

	var crystal_mesh := ScatterMeshes.build_crystal()
	for spec in [[150.0, 3.8, 1.4], [195.0, 3.5, 1.0], [235.0, 3.9, 1.7]]:
		var az: float = deg_to_rad(spec[0])
		var pos := GROTTO_POS + Vector3(cos(az) * spec[1], 0.05, sin(az) * spec[1])
		var mi := MeshInstance3D.new()
		mi.mesh = crystal_mesh
		mi.transform = _stand(pos, spec[2], rng, 0.12)
		add_child(mi)
	var glow := OmniLight3D.new()
	glow.name = "GrottoCrystalGlow"
	glow.position = GROTTO_POS + Vector3(-3.0, 1.2, 1.6)
	glow.light_color = Color(0.42, 0.86, 0.82)
	glow.light_energy = 1.1
	glow.omni_range = 6.0
	add_child(glow)


## Upright transform with a whisper of tilt — dead-vertical trees read as pins.
func _stand(pos: Vector3, s: float, rng: RandomNumberGenerator,
		tilt: float) -> Transform3D:
	var basis := Basis(Vector3.UP, rng.randf_range(0.0, TAU)) \
			.rotated(Vector3.RIGHT, rng.randf_range(-tilt, tilt)) \
			.rotated(Vector3.BACK, rng.randf_range(-tilt, tilt)) \
			.scaled(Vector3.ONE * s)
	return Transform3D(basis, pos)


func _make_multimesh(node_name: String, mesh: ArrayMesh,
		transforms: Array[Transform3D], rng: RandomNumberGenerator) -> void:
	if transforms.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = transforms.size()
	for i in transforms.size():
		mm.set_instance_transform(i, transforms[i])
		# Subtle per-instance tint: brightness jitter + a drift toward yellow or
		# blue-green, so a hillside of clones reads as a population.
		var b := rng.randf_range(0.84, 1.08)
		var shift := rng.randf_range(-0.05, 0.09)
		mm.set_instance_color(i, Color(b + shift, b, b - shift * 0.6))
	var mmi := MultiMeshInstance3D.new()
	mmi.name = node_name
	mmi.multimesh = mm
	add_child(mmi)


## One StaticBody3D, all shapes through the PhysicsServer. Trunks are slim
## cylinders (you collide with the tree, not its foliage); only boulders big
## enough to block a shin get a sphere.
func _build_colliders(trees: Array[Transform3D], rocks: Array[Transform3D]) -> void:
	var body := StaticBody3D.new()
	body.name = "ScatterColliders"
	add_child(body)
	for t in trees:
		var s := t.basis.get_scale().y
		var shape := CylinderShape3D.new()
		shape.radius = 0.26 * s
		shape.height = 2.6 * s
		_shapes.append(shape)
		PhysicsServer3D.body_add_shape(body.get_rid(), shape.get_rid(),
				Transform3D(Basis(), t.origin + Vector3(0.0, 1.3 * s, 0.0)))
	for t in rocks:
		var rs := t.basis.get_scale().y
		if rs < 0.75:
			continue
		var ball := SphereShape3D.new()
		ball.radius = 0.62 * rs
		_shapes.append(ball)
		PhysicsServer3D.body_add_shape(body.get_rid(), ball.get_rid(),
				Transform3D(Basis(), t.origin + Vector3(0.0, 0.3 * rs, 0.0)))


## Bilinear heightmap sample at a floating-point pixel position (map units).
func _height_at(img: Image, x: float, z: float) -> float:
	var w := img.get_width()
	var h := img.get_height()
	var x0 := clampi(int(floorf(x)), 0, w - 1)
	var z0 := clampi(int(floorf(z)), 0, h - 1)
	var x1 := mini(x0 + 1, w - 1)
	var z1 := mini(z0 + 1, h - 1)
	var fx := clampf(x - x0, 0.0, 1.0)
	var fz := clampf(z - z0, 0.0, 1.0)
	var top := lerpf(img.get_pixel(x0, z0).r, img.get_pixel(x1, z0).r, fx)
	var bot := lerpf(img.get_pixel(x0, z1).r, img.get_pixel(x1, z1).r, fx)
	return lerpf(top, bot, fz)


## Ground steepness in degrees, in world units (map px = 2 m; heights scaled).
func _slope_deg(img: Image, x: float, z: float, y_scale: float) -> float:
	var dhx := (_height_at(img, x + 1.0, z) - _height_at(img, x - 1.0, z)) \
			* y_scale / 4.0
	var dhz := (_height_at(img, x, z + 1.0) - _height_at(img, x, z - 1.0)) \
			* y_scale / 4.0
	return rad_to_deg(atan(sqrt(dhx * dhx + dhz * dhz)))


func _load_image(path: String) -> Image:
	var res: Resource = load(path)
	if res == null:
		return null
	var img: Image = res if res is Image else (res as Texture2D).get_image()
	if img != null and img.is_compressed():
		img.decompress()
	return img
