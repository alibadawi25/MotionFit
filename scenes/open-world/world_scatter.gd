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
## Also builds the hand-placed hidden landmarks (see SECRETS): the crystal
## grotto, the summit cairn, the standing stones, the castaway camp and the
## glowing hollow — all riding the same MultiMesh + collider plumbing, dressed
## with a few MeshInstances and lights. open_world.gd reads SECRETS to plant
## the discovery triggers that turn stumbling onto one into a score bonus.

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
## Not a safety rail like the two above — a measured budget, and the count for
## the HIGH graphics tier only. The understory is the one scatter layer whose
## cost shows up on the reference laptop (~3 FPS of ~57 on perf_view.tscn), so
## it is scaled by "shrub_density" from settings_manager.gd's QUALITY_PRESETS
## like the grass layer is: none on LOW, a little over half on MEDIUM, all of it
## on a desktop GPU.
const MAX_SHRUBS := 1700

## World-space height bands (metres). Sea sits at 15; the cold band of
## altitude_effects.gd starts at 55, and the roamable midlands (including the
## spawn plateau at ~64-68) sit ABOVE that — so the treeline reaches past the
## start of the cold and thins out on the way (see TREELINE_FADE_Y), with
## conifers owning the upper half.
const TREE_MIN_Y := 18.0
const TREE_MAX_Y := 66.0
const TREELINE_FADE_Y := 54.0
const CONIFER_Y := 45.0
const ROCK_MIN_Y := 15.8  # boulders may sit on the upper beach, half in sand
const ALPINE_Y := 50.0
## Understory: bushes and scrub. Reaches lower than the trees (scrub holds on
## right down to the dune line) and gives out a little sooner up top.
const SHRUB_MIN_Y := 16.4
const SHRUB_MAX_Y := 62.0
## Slope limits (degrees).
const TREE_MAX_SLOPE := 26.0
const ROCK_MAX_SLOPE := 52.0
const SHRUB_MAX_SLOPE := 34.0  # scrub clings to ground that would topple a tree
## Chance a candidate cell starts a shrub CLUMP, in the woods and in the open,
## and how big a clump is.
##
## Few, full thickets rather than many singles, and that is the whole trick of
## this layer. The island is a square kilometre; even the full budget works out
## to one plant per ~560 m², which spread evenly is an invisible dusting. Poured
## into thickets of half a dozen the same plants read as scrub in the gullies
## and open meadow between — a place with structure, rather than a lawn someone
## sprinkled. (Clumping also hides the 12 m candidate lattice, which singles
## put on open display.)
const SHRUB_CHANCE_WOOD := 0.2
const SHRUB_CHANCE_OPEN := 0.13
const SHRUB_CLUMP := Vector2i(4, 10)  # plants per clump, inclusive range
const SHRUB_CLUMP_R := 5.0  # metres the clump spreads around its cell
## The understory casts no shadows. There are thousands of these and their
## shadows are near-invisible against grass, while the shadow pass is the
## single most expensive thing this world does (7.6 ms of a 19 ms frame,
## measured — see settings_manager.gd QUALITY_PRESETS). Distance culling was
## the obvious alternative and is the wrong tool: Godot's visibility range is
## per-NODE, so one MultiMesh spanning a 1 km island can only be entirely
## visible or entirely hidden, and chunking it into per-region nodes buys a
## smaller saving than simply not drawing it into the shadow map.
const SHRUB_CASTS_SHADOW := false
## Trees stay a stride back from cliff rims: a candidate is rejected when the
## ground this many px (2 px = 4 m) away already tilts past RIM_SLOPE.
const RIM_MARGIN_PX := 2.0
const RIM_SLOPE := 34.0
## Nothing spawns this close to the player's start line. The point itself is
## read from the scene's SpawnPoint marker at build time (see
## [method resolve_spawn_clear]) — this constant is only the fallback for a
## scene that has no marker. It is deliberately NOT the authority: it used to
## be, and it silently fell 225 m out of date when the marker was moved, so the
## clearing was protecting bare hillside while the real start line was clear
## only by luck.
const SPAWN_CLEAR := Vector3(407.8, 0.0, -6.0)
const SPAWN_CLEAR_RADIUS := 9.0

## The grotto: a hollow knoll of oversized boulders on the mountain's east
## flank — the walkable cave prototype. A hemisphere shell of rocks with a wide
## east-facing mouth (webcam steering needs a forgiving entrance), an amber
## light and a crystal cluster inside. Site picked with tools/probe_spot.gd:
## ground y 47.7, slope < 2 deg, ~195 m west of the spawn plateau.
const GROTTO_POS := Vector3(228.0, 47.4, -60.0)
const GROTTO_SHELL_R := 6.0
const GROTTO_MOUTH_AZ_DEG := 62.0  # half-angle of the opening, around +X (east)

## The hidden landmarks scattered around the world for players to search out.
## Positions were sited with tools/probe_spot.gd (flat ground, spread to the
## world's far corners so each one demands a real walk). Per secret:
## "radius" — how close the player must come for open_world.gd's discovery
## trigger to fire; "clear" — ordinary scatter keeps this far away, so trees
## can't bury a landmark (nor crowd the hollow's own mushroom ring).
const SECRETS: Array[Dictionary] = [
	{"id": "grotto", "name": "THE CRYSTAL GROTTO",
			"pos": GROTTO_POS, "radius": 5.5, "clear": 15.0},
	{"id": "cairn", "name": "THE SUMMIT CAIRN",
			"pos": Vector3(-60.0, 79.8, -120.0), "radius": 6.0, "clear": 8.0},
	{"id": "stones", "name": "THE STANDING STONES",
			"pos": Vector3(-240.0, 50.1, 240.0), "radius": 8.0, "clear": 14.0},
	{"id": "camp", "name": "THE CASTAWAY CAMP",
			"pos": Vector3(60.0, 16.4, 250.0), "radius": 6.0, "clear": 8.0},
	{"id": "hollow", "name": "THE GLOWING HOLLOW",
			"pos": Vector3(-405.0, 20.1, -285.0), "radius": 6.0, "clear": 7.0},
]

@export var terrain_path: NodePath
## The player's start marker, so the spawn clearing follows it. Shared with
## wildlife.gd, which keeps animals off the start line the same way.
@export var spawn_path: NodePath

# Collision shapes added via the PhysicsServer must stay referenced or they free.
var _shapes: Array[Shape3D] = []


## Where the spawn clearing goes: the SpawnPoint marker's ground position, with
## y flattened (callers compare on the XZ plane). Falls back to
## [constant SPAWN_CLEAR] when the scene has no marker wired.
##
## Read live rather than hardcoded because the marker moves during level design
## and a stale copy fails silently — nothing errors, the clearing just protects
## the wrong hillside and trees are free to grow on the player's head.
static func resolve_spawn_clear(host: Node, path: NodePath) -> Vector3:
	var marker := host.get_node_or_null(path) as Node3D
	if marker == null:
		push_warning("%s: no spawn marker at '%s'; falling back to the hardcoded "
				% [host.name, path] + "spawn clearing, which may be out of date")
		return SPAWN_CLEAR
	return Vector3(marker.global_position.x, 0.0, marker.global_position.z)


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

	var spawn_clear := resolve_spawn_clear(self, spawn_path)
	var shrub_density := _shrub_density()

	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var clumps := FastNoiseLite.new()  # woods-with-clearings mask
	clumps.seed = SEED
	clumps.frequency = 0.009

	# One bucket per tree/shrub VARIANT: each becomes its own MultiMesh, so the
	# world gets a mixed forest for a handful of extra draw calls instead of one
	# shape repeated a thousand times.
	var conifers := _buckets(ScatterMeshes.conifer_variants())
	var broadleafs := _buckets(ScatterMeshes.broadleaf_variants())
	var shrubs := _buckets(ScatterMeshes.shrub_variants())
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
			if Vector3(wx, 0.0, wz).distance_to(spawn_clear) < SPAWN_CLEAR_RADIUS:
				continue
			if _near_secret(wx, wz):
				continue

			var wooded := clumps.get_noise_2d(wx, wz) > 0.08

			# --- trees: on grass, gentle ground, gathered into woods --------
			if ground.r > 0.5 and wy > TREE_MIN_Y and wy < TREE_MAX_Y \
					and slope < TREE_MAX_SLOPE \
					and not _near_cliff_rim(height_img, map.x, map.z, y_scale):
				var chance := 0.62 if wooded else 0.045
				# Woods thin out toward the treeline instead of stopping dead.
				chance *= 1.0 - smoothstep(TREELINE_FADE_Y, TREE_MAX_Y, wy) * 0.85
				if rng.randf() < chance:
					var s := rng.randf_range(0.8, 1.4)
					var t := _stand(Vector3(wx, wy - 0.12 * s, wz), s, rng, 0.045)
					if wy > CONIFER_Y or rng.randf() < 0.3:
						conifers[_conifer_variant(wy, rng)].append(t)
					else:
						broadleafs[_broadleaf_variant(wy, rng)].append(t)
					continue

			# --- understory: clumps of bush, scrub and gorse ----------------
			# Tried after the trees and before the rocks, so a cell that grew a
			# tree grows nothing else and the two can't interpenetrate.
			if ground.r > 0.5 and wy > SHRUB_MIN_Y and wy < SHRUB_MAX_Y \
					and slope < SHRUB_MAX_SLOPE \
					and rng.randf() < shrub_density * (SHRUB_CHANCE_WOOD if wooded
							else SHRUB_CHANCE_OPEN):
				_plant_shrubs(shrubs, Vector2(wx, wz), height_img, to_map,
						y_scale, rng)
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

	# Thinning is proportional across the buckets, so hitting a cap changes
	# how MANY plants there are and never which KINDS survive.
	_thin(MAX_TREES, conifers + broadleafs)
	_thin(MAX_SHRUBS, shrubs)
	if rocks.size() > MAX_ROCKS:
		rocks.resize(MAX_ROCKS)
	# Appended after the cap on purpose: these are landmarks, not scatter, and
	# must never be thinned away. Riding in the boulder MultiMesh + collider
	# list means they need no rendering or physics machinery of their own.
	rocks.append_array(_grotto_shell())
	rocks.append_array(_standing_stones())
	rocks.append_array(_cairn_stones())
	rocks.append_array(_camp_stone_ring())

	rng.seed = SEED + 1  # tints independent of how placement consumed the stream
	for v in conifers.size():
		_make_multimesh("Conifers%d" % v, ScatterMeshes.build_conifer(v),
				conifers[v], rng)
	for v in broadleafs.size():
		_make_multimesh("Broadleafs%d" % v, ScatterMeshes.build_broadleaf(v),
				broadleafs[v], rng)
	for v in shrubs.size():
		_make_multimesh("Shrubs%d" % v, ScatterMeshes.build_shrub(v),
				shrubs[v], rng, SHRUB_CASTS_SHADOW)
	_make_multimesh("Boulders", ScatterMeshes.build_boulder(), rocks, rng)
	_build_colliders(conifers, broadleafs, rocks)
	_build_grotto_interior()
	_build_secret_props()


## True when (wx, wz) falls inside any secret's keep-out ring — ordinary
## scatter must not bury (or wall off) a landmark players are meant to find.
func _near_secret(wx: float, wz: float) -> bool:
	for secret in SECRETS:
		var sp: Vector3 = secret.pos
		if Vector2(wx, wz).distance_to(Vector2(sp.x, sp.z)) < secret.clear:
			return true
	return false


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


## The standing stones: eight menhirs — tall-stretched boulders — ringing a
## fallen slab on the flat west-meadow plateau. The stretch is anisotropic
## (thin x/z, tall y), which is why _build_colliders sizes its spheres from the
## horizontal scale, not the height.
func _standing_stones() -> Array[Transform3D]:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED + 4
	var out: Array[Transform3D] = []
	var center: Vector3 = SECRETS[2].pos
	var ring_r := 7.5
	for i in 8:
		var az := TAU * float(i) / 8.0 + rng.randf_range(-0.08, 0.08)
		var h := rng.randf_range(2.1, 2.8)
		var basis := Basis(Vector3.UP, rng.randf_range(0.0, TAU)) \
				.rotated(Vector3.RIGHT, rng.randf_range(-0.05, 0.05)) \
				.scaled(Vector3(rng.randf_range(0.55, 0.7), h,
						rng.randf_range(0.45, 0.6)))
		out.append(Transform3D(basis, center
				+ Vector3(cos(az) * ring_r, 0.35 * h, sin(az) * ring_r)))
	# The slab in the middle, tipped flat into the grass long ago.
	out.append(Transform3D(
			Basis(Vector3.UP, 0.7).scaled(Vector3(1.6, 0.35, 1.0)),
			center + Vector3(0.4, -0.1, -0.3)))
	return out


## The summit cairn: a tapering stack of boulders on the high shelf below the
## peak — proof somebody once made the climb. Light xz jitter and per-stone
## yaw keep it hand-stacked rather than machined.
func _cairn_stones() -> Array[Transform3D]:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED + 5
	var out: Array[Transform3D] = []
	var base: Vector3 = SECRETS[1].pos
	# scale, centre height above the ground
	var courses: Array = [[1.5, 0.4], [1.1, 1.1], [0.8, 1.65], [0.55, 2.05],
			[0.35, 2.35]]
	for course in courses:
		var s: float = course[0] * rng.randf_range(0.92, 1.08)
		var basis := Basis(Vector3.UP, rng.randf_range(0.0, TAU)) \
				.scaled(Vector3.ONE * s)
		out.append(Transform3D(basis, base + Vector3(
				rng.randf_range(-0.12, 0.12), course[1],
				rng.randf_range(-0.12, 0.12))))
	return out


## The castaway camp's fire ring: a circle of fist-sized stones around the
## embers. Too small for colliders (by design — nothing to trip on).
func _camp_stone_ring() -> Array[Transform3D]:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED + 6
	var out: Array[Transform3D] = []
	var center: Vector3 = SECRETS[3].pos
	for i in 7:
		var az := TAU * float(i) / 7.0 + rng.randf_range(-0.15, 0.15)
		var s := rng.randf_range(0.26, 0.38)
		var basis := Basis(Vector3.UP, rng.randf_range(0.0, TAU)) \
				.scaled(Vector3.ONE * s)
		out.append(Transform3D(basis,
				center + Vector3(cos(az) * 1.0, -0.05, sin(az) * 1.0)))
	return out


## Dressing that turns the remaining secret sites into places: the driftwood
## lean-to and ember glow at the camp, an ice-pale crystal and cold beacon on
## the cairn, and the hollow's ring of glowing mushrooms. Same recipe as the
## grotto interior — a couple of MeshInstances and a light each.
func _build_secret_props() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED + 7
	var camp: Vector3 = SECRETS[3].pos
	var wood := MeshInstance3D.new()
	wood.name = "CampDriftwood"
	wood.mesh = ScatterMeshes.build_driftwood()
	wood.transform = _stand(camp + Vector3(0.0, -0.06, 0.0), 1.0, rng, 0.02)
	add_child(wood)
	var ember := OmniLight3D.new()
	ember.name = "CampEmberGlow"
	ember.position = camp + Vector3(0.0, 0.5, 0.0)
	ember.light_color = Color(1.0, 0.55, 0.25)
	ember.light_energy = 1.4
	ember.omni_range = 6.0
	add_child(ember)

	var cairn: Vector3 = SECRETS[1].pos
	var spike := MeshInstance3D.new()
	spike.name = "CairnCrystal"
	spike.mesh = ScatterMeshes.build_crystal()
	spike.transform = _stand(cairn + Vector3(0.15, 2.45, 0.1), 0.7, rng, 0.15)
	add_child(spike)
	var beacon := OmniLight3D.new()
	beacon.name = "CairnBeacon"
	beacon.position = cairn + Vector3(0.0, 3.3, 0.0)
	beacon.light_color = Color(0.62, 0.82, 1.0)
	beacon.light_energy = 1.0
	beacon.omni_range = 8.0
	add_child(beacon)

	var hollow: Vector3 = SECRETS[4].pos
	var shroom_mesh := ScatterMeshes.build_mushroom()
	for i in 9:
		var az := TAU * float(i) / 9.0 + rng.randf_range(-0.18, 0.18)
		var r := rng.randf_range(2.0, 3.4)
		var mi := MeshInstance3D.new()
		mi.mesh = shroom_mesh
		mi.transform = _stand(
				hollow + Vector3(cos(az) * r, -0.04, sin(az) * r),
				rng.randf_range(0.7, 1.5), rng, 0.1)
		add_child(mi)
	var spores := OmniLight3D.new()
	spores.name = "HollowGlow"
	spores.position = hollow + Vector3(0.0, 1.0, 0.0)
	spores.light_color = Color(0.66, 0.42, 0.92)
	spores.light_energy = 1.2
	spores.omni_range = 7.0
	add_child(spores)


## How much of the understory this machine's graphics tier draws, 0-1.
##
## Applied to the placement CHANCE rather than as a cap afterwards. A cap can
## only remove plants that were already positioned, which biases WHERE the
## survivors are; scaling the chance thins the whole island evenly and leaves
## MAX_SHRUBS free to be what it should be, a rail nobody expects to hit.
##
## PULLED from SettingsManager here rather than PUSHED by its
## [method SettingsManager.apply_scene_quality], which is how every other
## per-scene quality setting travels. The difference is that those all mutate a
## node that already exists, while this one decides what gets built at all: by
## the time apply_scene_quality runs on the finished world, the MultiMeshes are
## already filled. Falls back to the full count if the autoload is missing, so a
## test scene booting WorldScatter on its own still gets an understory.
func _shrub_density() -> float:
	var settings := get_node_or_null(^"/root/SettingsManager")
	if settings == null:
		return 1.0
	var preset: Dictionary = settings.get_quality_preset()
	return float(preset.get("shrub_density", 1.0))


## One empty transform list per variant. Buckets rather than one list with a
## variant field: each bucket becomes a MultiMesh, and a MultiMesh draws exactly
## one mesh.
func _buckets(count: int) -> Array:
	var out: Array = []
	for i in count:
		var bucket: Array[Transform3D] = []
		out.append(bucket)
	return out


## Thin every bucket by the same factor until their combined size fits
## [param cap]. Proportional across buckets on purpose: trimming whole buckets
## (or trimming the last one hardest) would let a cap silently delete an entire
## SPECIES from the world, which is the exact failure the variants exist to
## prevent.
##
## And thinned by STRIDE, not by truncation. These lists are built by a loop
## that walks the world row by row, so they are in spatial order — `resize()`
## does not thin a forest, it deletes everything south of a line. That went
## unnoticed while MAX_TREES sat above the number of trees actually placed and
## the cap never bound; the moment the understory made a cap bind for real, a
## third of the island came back bare.
func _thin(cap: int, buckets: Array) -> void:
	var total := 0
	for bucket in buckets:
		total += bucket.size()
	if total <= cap:
		return
	var keep := float(cap) / float(total)
	for bucket in buckets:
		var kept: Array[Transform3D] = []
		var acc := 0.0
		for t in bucket:
			acc += keep
			if acc >= 1.0:
				acc -= 1.0
				kept.append(t)
		bucket.assign(kept)


## Which conifer shape grows at this altitude — see ScatterMeshes._CONIFERS:
## 0 spire, 1 broad fir, 2 umbrella pine, 3 snag.
##
## Weights that drift with height, not hard altitude bands. A band would draw a
## visible line across the mountain where one tree stopped and another started;
## what a real hillside does is CHANGE ITS MIX as you climb — broad firs in the
## sheltered low woods, spires and weather-killed snags up where the treeline
## gives out, and every altitude in between holding some of both.
func _conifer_variant(wy: float, rng: RandomNumberGenerator) -> int:
	var high := smoothstep(TREE_MIN_Y + 8.0, TREELINE_FADE_Y, wy)
	return _pick_weighted(PackedFloat32Array([
		0.20 + 0.42 * high,  # spire — takes over with altitude
		0.46 - 0.34 * high,  # broad fir — needs shelter
		0.30 - 0.22 * high,  # umbrella pine — a midland tree
		0.04 + 0.20 * high,  # snag — dieback at the treeline
	]), rng)


## Which broadleaf shape grows here: 0 round, 1 spreading oak, 2 slim birch.
## Oaks want the warm low ground; birches take over as the conifers close in.
func _broadleaf_variant(wy: float, rng: RandomNumberGenerator) -> int:
	var high := smoothstep(TREE_MIN_Y + 6.0, CONIFER_Y, wy)
	return _pick_weighted(PackedFloat32Array([
		0.42, 0.40 - 0.28 * high, 0.18 + 0.30 * high]), rng)


## Index into [param weights], chosen in proportion to them. Weights need not
## sum to 1 — the callers above tune each entry independently and would
## otherwise have to renormalise by hand every time one changed.
func _pick_weighted(weights: PackedFloat32Array, rng: RandomNumberGenerator) -> int:
	var total := 0.0
	for w in weights:
		total += maxf(w, 0.0)
	var roll := rng.randf() * total
	for i in weights.size():
		roll -= maxf(weights[i], 0.0)
		if roll <= 0.0:
			return i
	return weights.size() - 1


## Drop a handful of shrubs around [param center] (world XZ), each re-sampling
## the heightmap so it sits on the ground rather than on the cell's height.
##
## A clump rather than one plant per cell because the candidate grid is 12 m
## across: singles land on a visible lattice, whereas a few plants within a
## couple of metres read as one bush that spread, and the gaps between clumps
## read as ground the deer keep cropped.
func _plant_shrubs(shrubs: Array, center: Vector2, height_img: Image,
		to_map: Transform3D, y_scale: float, rng: RandomNumberGenerator) -> void:
	var count := rng.randi_range(SHRUB_CLUMP.x, SHRUB_CLUMP.y)
	for i in count:
		var az := rng.randf() * TAU
		var r := sqrt(rng.randf()) * SHRUB_CLUMP_R  # sqrt = even over the disc
		var wx := center.x + cos(az) * r
		var wz := center.y + sin(az) * r
		var map := to_map * Vector3(wx, 0.0, wz)
		var wy := _height_at(height_img, map.x, map.z) * y_scale
		var s := rng.randf_range(0.7, 1.45)
		# Sunk a little further than a tree: a bush with a visible gap under it
		# is the tell that it was dropped on the terrain rather than grown in it.
		shrubs[rng.randi() % shrubs.size()].append(
				_stand(Vector3(wx, wy - 0.1 * s, wz), s, rng, 0.09))


## Upright transform with a whisper of tilt — dead-vertical trees read as pins.
func _stand(pos: Vector3, s: float, rng: RandomNumberGenerator,
		tilt: float) -> Transform3D:
	var basis := Basis(Vector3.UP, rng.randf_range(0.0, TAU)) \
			.rotated(Vector3.RIGHT, rng.randf_range(-tilt, tilt)) \
			.rotated(Vector3.BACK, rng.randf_range(-tilt, tilt)) \
			.scaled(Vector3.ONE * s)
	return Transform3D(basis, pos)


## One MultiMesh per node — one draw call for the whole batch — with a
## per-instance tint. See [constant SHRUB_CASTS_SHADOW] for why the caller
## would ever pass [param casts_shadow] false.
func _make_multimesh(node_name: String, mesh: ArrayMesh,
		transforms: Array[Transform3D], rng: RandomNumberGenerator,
		casts_shadow: bool = true) -> void:
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
	if not casts_shadow:
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)


## One StaticBody3D, all shapes through the PhysicsServer. Trunks are slim
## cylinders (you collide with the tree, not its foliage); only boulders big
## enough to block a shin get a sphere. Shrubs get nothing — you walk through
## a bush.
func _build_colliders(conifers: Array, broadleafs: Array,
		rocks: Array[Transform3D]) -> void:
	var body := StaticBody3D.new()
	body.name = "ScatterColliders"
	add_child(body)
	for v in conifers.size():
		_add_trunks(body, conifers[v], ScatterMeshes.conifer_trunk_radius(v))
	for v in broadleafs.size():
		_add_trunks(body, broadleafs[v],
				ScatterMeshes.broadleaf_trunk_radius(v))
	for t in rocks:
		var sc := t.basis.get_scale()
		if sc.y < 0.75:
			continue
		# Radius from the HORIZONTAL scale: landmark menhirs are stretched tall
		# and thin, and a sphere sized from their height would be an invisible
		# wall a metre wider than the stone.
		var ball := SphereShape3D.new()
		ball.radius = 0.62 * maxf(sc.x, sc.z)
		_shapes.append(ball)
		PhysicsServer3D.body_add_shape(body.get_rid(), ball.get_rid(),
				Transform3D(Basis(), t.origin + Vector3(0.0, 0.3 * sc.y, 0.0)))


## Trunk cylinders for one tree variant. [param trunk_r] is the mesh's own
## bottom radius, widened a little: the collider should stop you at the bark,
## not let you clip a shoulder into it.
func _add_trunks(body: StaticBody3D, trees: Array[Transform3D],
		trunk_r: float) -> void:
	for t in trees:
		var s := t.basis.get_scale().y
		var shape := CylinderShape3D.new()
		shape.radius = (trunk_r + 0.06) * s
		shape.height = 2.6 * s
		_shapes.append(shape)
		PhysicsServer3D.body_add_shape(body.get_rid(), shape.get_rid(),
				Transform3D(Basis(), t.origin + Vector3(0.0, 1.3 * s, 0.0)))


## True when the ground a few metres away in any cardinal direction is already
## cliff-steep — a tree there would teeter on the rim with half its roots in
## the air. (Only called for candidates that passed the cheap gates.)
func _near_cliff_rim(img: Image, x: float, z: float, y_scale: float) -> bool:
	for off in [Vector2(RIM_MARGIN_PX, 0.0), Vector2(-RIM_MARGIN_PX, 0.0),
			Vector2(0.0, RIM_MARGIN_PX), Vector2(0.0, -RIM_MARGIN_PX)]:
		if _slope_deg(img, x + off.x, z + off.y, y_scale) > RIM_SLOPE:
			return true
	return false


## Bilinear heightmap sample at a floating-point pixel position (map units).
## (Static: wildlife.gd samples the same maps through these three helpers.)
static func _height_at(img: Image, x: float, z: float) -> float:
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
static func _slope_deg(img: Image, x: float, z: float, y_scale: float) -> float:
	var dhx := (_height_at(img, x + 1.0, z) - _height_at(img, x - 1.0, z)) \
			* y_scale / 4.0
	var dhz := (_height_at(img, x, z + 1.0) - _height_at(img, x, z - 1.0)) \
			* y_scale / 4.0
	return rad_to_deg(atan(sqrt(dhx * dhx + dhz * dhz)))


static func _load_image(path: String) -> Image:
	var res: Resource = load(path)
	if res == null:
		return null
	var img: Image = res if res is Image else (res as Texture2D).get_image()
	if img != null and img.is_compressed():
		img.decompress()
	return img
