extends Node3D
## Wildlife — spawns the open world's animals and drives them, the behaviour
## half promised by animal_meshes.gd (which builds the bodies).
##
## Every species lives in ONE MultiMesh (one draw call, per-instance tints, same
## plumbing as world_scatter.gd) and the animals themselves are plain records
## this script steps each physics frame — no nodes, no physics bodies. The
## meshes are rigid on purpose, so all motion is whole-body: yaw, hop arcs and
## trot bob for the ground animals, a banked circle for the gulls, a wing-beat
## rock for the butterflies. Nothing ever re-poses parts.
##
## Placement reads the SAME terrain data maps as world_scatter.gd — height for
## the altitude bands, splat for grass — and the very same clump-noise seed, so
## deer and songbirds stand in the actual woods, rabbits and butterflies in the
## actual clearings, foxes on the conifer treeline and gulls off the shore.
## Spawning is deterministic (fixed seed, like the forest); the behaviour clock
## is not, so a revisit looks alive rather than replayed.
##
## Behaviour, per the plan in CONTEXT.md §12: ground animals wander a short
## leash around home and FLEE when the player closes in (chase a deer, it runs
## — that's cardio), songbirds flush into a flight arc and land somewhere new,
## gulls fly soaring loops, butterflies drift. Ground animals farther than
## ACTIVE_RADIUS from the player stand still — nobody is watching.

const AnimalMeshes := preload("res://scenes/open-world/animal_meshes.gd")
const Scatter := preload("res://scenes/open-world/world_scatter.gd")

const SEED := 20260718
## Animals keep a stride inside the scenery line (world_scatter HALF_EXTENT).
const HALF_EXTENT := 470.0
## Nothing walks below this (sea sits at 15; this is the surf line).
const GROUND_MIN_Y := 16.2
## Ground animals beyond this stand still until the player comes back.
const ACTIVE_RADIUS := 160.0
## Sentinel for "no walkable ground there" (see _step_y).
const BLOCKED := -1.0e9

## Herds are dealt one per grid sector rather than rolled anywhere on the island.
## Uniform random anchors clump: with a handful of them over a 1 km² island whole
## quadrants came up empty, and the spawn quadrant was one of them — the nearest
## animal of ANY species was 338 m from the player's start, so a session read as
## a dead world. Dicing the island into SECTORS² cells and dealing at most one
## herd per cell (in shuffled order, so it stays deterministic but unpatterned)
## guarantees the spread instead of hoping for it. See _deal_spots.
const SECTORS := 8
## Candidate rolls per sector before giving up on it. A sector that is all sea,
## all cliff or the wrong biome band for the species simply yields nothing and
## the deal moves on.
const SPOT_ATTEMPTS := 96

enum Species { DEER, FOX, RABBIT, SONGBIRD, GULL, BUTTERFLY }
enum State { IDLE, WANDER, FLEE, FLIGHT }

## Ground-species tuning. walk/flee in m/s; flee_r wakes the animal, calm_r
## lets it settle (and re-home where it stopped); leash bounds wandering;
## stride (m) paces the bob so small animals patter and the deer lopes;
## amp (m) is the bob height at a walk — fleeing raises it.
const GROUND_SPECS := {
	Species.DEER: {"walk": 1.2, "flee": 5.0, "flee_r": 16.0, "calm_r": 30.0,
			"leash": 18.0, "stride": 1.5, "amp": 0.05, "max_slope": 30.0},
	Species.FOX: {"walk": 0.9, "flee": 4.4, "flee_r": 13.0, "calm_r": 26.0,
			"leash": 15.0, "stride": 0.8, "amp": 0.04, "max_slope": 32.0},
	Species.RABBIT: {"walk": 1.4, "flee": 3.6, "flee_r": 9.0, "calm_r": 18.0,
			"leash": 9.0, "stride": 0.55, "amp": 0.1, "max_slope": 28.0},
	Species.SONGBIRD: {"walk": 0.5, "flee": 8.0, "flee_r": 7.0, "calm_r": 0.0,
			"leash": 5.0, "stride": 0.3, "amp": 0.03, "max_slope": 34.0},
}

## Butterfly wing tints (multiply the authored violet): the drifts the mesh
## doc promises — violet as built, an orange morph, a pale near-white.
const FLUTTER_TINTS: Array[Color] = [Color(1.0, 1.0, 1.0),
		Color(1.35, 0.95, 0.25), Color(1.15, 1.6, 1.05)]

@export var terrain_path: NodePath
@export var player_path: NodePath
## The player's start marker. Animals keep off the start line the same way the
## scenery does — resolved live, never hardcoded (see
## WorldScatter.resolve_spawn_clear).
@export var spawn_path: NodePath


## One animal. Ground species keep pos at their feet; gulls and butterflies
## (body-centre meshes) keep it at the body. Gulls repurpose target/omega as
## their loop centre and angular speed.
class Critter:
	var species: int
	var pos: Vector3
	var home: Vector3
	var yaw := 0.0
	var scale := 1.0
	var tint := Color.WHITE
	var state := State.IDLE
	var timer := 0.0
	var target := Vector3.ZERO
	var phase := 0.0  # gait phase; gulls use it as the loop angle
	var seed_f := 0.0  # per-individual desync for sines
	var fly_from := Vector3.ZERO
	var fly_t := 0.0
	var fly_dur := 1.0
	var radius := 0.0  # gull loop radius
	var omega := 0.0  # gull angular speed (sign = direction)
	var mm: MultiMesh
	var idx := 0


var _critters: Array[Critter] = []
var _height_img: Image
var _to_map := Transform3D()
var _y_scale := 1.0
var _player: Node3D
var _spawn_clear := Vector3.ZERO
var _time := 0.0
var _rng := RandomNumberGenerator.new()  # behaviour randomness, unseeded


func _ready() -> void:
	var terrain := get_node_or_null(terrain_path) as Node3D
	_height_img = Scatter._load_image(Scatter.HEIGHT_MAP)
	var splat := Scatter._load_image(Scatter.SPLAT_MAP)
	if terrain == null or _height_img == null or splat == null:
		push_warning("Wildlife: terrain or data maps missing; world stays still")
		return
	_to_map = terrain.get_internal_transform().affine_inverse()
	_y_scale = terrain.get_internal_transform().basis.y.y
	_player = get_node_or_null(player_path) as Node3D
	_spawn_clear = Scatter.resolve_spawn_clear(self, spawn_path)
	_spawn_all(splat)


func _physics_process(delta: float) -> void:
	if _critters.is_empty():
		return
	_time += delta
	var ppos := _player.global_position if _player != null \
			else Vector3(1.0e5, 0.0, 1.0e5)
	for c in _critters:
		match c.species:
			Species.GULL:
				_update_gull(c, delta)
			Species.BUTTERFLY:
				_update_butterfly(c)
			_:
				_update_ground(c, delta, ppos)


## Test/debug helper: world positions of every animal of [param species].
func debug_positions(species: int) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for c in _critters:
		if c.species == species:
			out.append(c.pos)
	return out


# --- spawning ----------------------------------------------------------------

func _spawn_all(splat: Image) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	var clumps := FastNoiseLite.new()  # the forest's own woods mask
	clumps.seed = Scatter.SEED
	clumps.frequency = 0.009

	# species, herds wanted, herd size min..max. Counts are sized so a roamer
	# meets something every minute or two rather than every expedition: the herds
	# are spread one-per-sector, so ~14 of them means an anchor roughly every
	# 120 m of island. The cost is near nothing — every species is still one
	# draw call, and ground animals freeze past ACTIVE_RADIUS.
	for plan in [[Species.DEER, 14, 2, 4], [Species.FOX, 8, 1, 2],
			[Species.RABBIT, 16, 2, 4], [Species.SONGBIRD, 14, 2, 3],
			[Species.BUTTERFLY, 18, 3, 5]]:
		for anchor in _deal_spots(plan[0], plan[1], rng, splat, clumps):
			for i in rng.randi_range(plan[2], plan[3]):
				var az := rng.randf_range(0.0, TAU)
				var p := anchor + Vector3(cos(az), 0.0, sin(az)) \
						* rng.randf_range(1.2, 4.0)
				var gy := _step_y(p, 40.0)
				p.y = gy if gy != BLOCKED else anchor.y
				_add_critter(plan[0], p if gy != BLOCKED else anchor, rng)

	# Gull loops off the shore. Dealt per sector like the rest, which also rings
	# them right around the coast instead of stacking them on one beach.
	for beach in _deal_spots(Species.GULL, 8, rng, splat, clumps):
		var center := beach + Vector3(0.0, rng.randf_range(10.0, 16.0), 0.0)
		for i in rng.randi_range(2, 3):
			var c := _add_critter(Species.GULL, center, rng)
			c.target = center
			c.radius = rng.randf_range(10.0, 18.0)
			c.omega = rng.randf_range(0.28, 0.4) * (1.0 if rng.randf() < 0.5 else -1.0)
			c.phase = rng.randf_range(0.0, TAU)

	_build_multimeshes()


## Deals up to [param count] herd anchors for [param species], at most one per
## grid sector, visiting the sectors in a shuffled order. Sectors whose ground
## doesn't suit the species (sea, cliff, wrong altitude band) simply yield
## nothing and the walk continues, so a species that only lives in one biome
## still fills the sectors where that biome exists. The shuffle draws from the
## spawn [param rng], so the whole layout stays deterministic per SEED.
func _deal_spots(species: int, count: int, rng: RandomNumberGenerator,
		splat: Image, clumps: FastNoiseLite) -> Array[Vector3]:
	var order: Array[int] = []
	for i in SECTORS * SECTORS:
		order.append(i)
	for i in range(order.size() - 1, 0, -1):  # Fisher-Yates
		var j := rng.randi_range(0, i)
		var tmp := order[i]
		order[i] = order[j]
		order[j] = tmp

	var span := 2.0 * HALF_EXTENT / float(SECTORS)
	var out: Array[Vector3] = []
	for cell in order:
		if out.size() >= count:
			break
		var spot := _find_spot(species, rng, splat, clumps,
				-HALF_EXTENT + span * float(cell % SECTORS),
				-HALF_EXTENT + span * float(cell / SECTORS), span)
		if spot != Vector3.INF:
			out.append(spot)
	return out


## Rolls candidate points inside the sector at ([param x0], [param z0]) of side
## [param span] until one satisfies [param species]' biome — the same bands and
## masks the scenery grew from — or gives up on the sector (Vector3.INF).
func _find_spot(species: int, rng: RandomNumberGenerator, splat: Image,
		clumps: FastNoiseLite, x0: float, z0: float, span: float) -> Vector3:
	for attempt in SPOT_ATTEMPTS:
		var wx := rng.randf_range(x0, x0 + span)
		var wz := rng.randf_range(z0, z0 + span)
		if Vector3(wx, 0.0, wz).distance_to(_spawn_clear) < 20.0:
			continue
		if _near_secret(wx, wz):
			continue
		var map := _to_map * Vector3(wx, 0.0, wz)
		var wy := Scatter._height_at(_height_img, map.x, map.z) * _y_scale
		var slope := Scatter._slope_deg(_height_img, map.x, map.z, _y_scale)
		var ground := splat.get_pixel(
				clampi(int(map.x), 0, splat.get_width() - 1),
				clampi(int(map.z), 0, splat.get_height() - 1))
		var grass := ground.r > 0.5
		var wooded := clumps.get_noise_2d(wx, wz) > 0.08
		var ok := false
		match species:
			Species.DEER, Species.SONGBIRD:
				ok = grass and wooded and wy > 20.0 and wy < 52.0 and slope < 22.0
			Species.FOX:
				ok = grass and wy > 38.0 and wy < 60.0 and slope < 26.0 \
						and clumps.get_noise_2d(wx, wz) > -0.05
			Species.RABBIT:
				ok = grass and not wooded and wy > 17.0 and wy < 46.0 \
						and slope < 20.0
			Species.BUTTERFLY:
				ok = grass and not wooded and wy > 16.5 and wy < 38.0 \
						and slope < 22.0
			Species.GULL:
				ok = wy > 14.6 and wy < 17.2 and absf(wx) < 440.0 \
						and absf(wz) < 440.0
		if ok:
			return Vector3(wx, wy, wz)
	return Vector3.INF


func _add_critter(species: int, pos: Vector3,
		rng: RandomNumberGenerator) -> Critter:
	var c := Critter.new()
	c.species = species
	c.pos = pos
	c.home = pos
	c.yaw = rng.randf_range(0.0, TAU)
	c.scale = rng.randf_range(0.92, 1.12)
	c.seed_f = rng.randf_range(0.0, TAU)
	c.timer = rng.randf_range(0.5, 4.0)
	if species == Species.BUTTERFLY:
		c.tint = FLUTTER_TINTS[rng.randi_range(0, FLUTTER_TINTS.size() - 1)]
	else:
		var b := rng.randf_range(0.86, 1.08)
		var shift := rng.randf_range(-0.04, 0.06)
		c.tint = Color(b + shift, b, b - shift * 0.6)
	_critters.append(c)
	return c


## One MultiMesh per species, transforms refreshed by the updaters. A fixed
## custom AABB spares the renderer re-fitting bounds every frame (and keeps
## far movers from being mis-culled).
func _build_multimeshes() -> void:
	var meshes := {
		Species.DEER: AnimalMeshes.build_deer(),
		Species.FOX: AnimalMeshes.build_fox(),
		Species.RABBIT: AnimalMeshes.build_rabbit(),
		Species.SONGBIRD: AnimalMeshes.build_songbird(),
		Species.GULL: AnimalMeshes.build_gull(),
		Species.BUTTERFLY: AnimalMeshes.build_butterfly(),
	}
	for species in meshes:
		var flock: Array[Critter] = []
		for c in _critters:
			if c.species == species:
				flock.append(c)
		if flock.is_empty():
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = meshes[species]
		mm.instance_count = flock.size()
		for i in flock.size():
			var c := flock[i]
			c.mm = mm
			c.idx = i
			mm.set_instance_color(i, c.tint)
			mm.set_instance_transform(i, Transform3D(
					Basis(Vector3.UP, c.yaw).scaled(Vector3.ONE * c.scale), c.pos))
		var mmi := MultiMeshInstance3D.new()
		mmi.name = str(Species.keys()[species]).capitalize() + "s"
		mmi.multimesh = mm
		mmi.custom_aabb = AABB(Vector3(-496.0, -5.0, -496.0),
				Vector3(992.0, 130.0, 992.0))
		add_child(mmi)


# --- ground animals: wander the leash, flee the player -----------------------

func _update_ground(c: Critter, delta: float, ppos: Vector3) -> void:
	var spec: Dictionary = GROUND_SPECS[c.species]
	var pdist := c.pos.distance_to(ppos)
	if c.state != State.FLEE and c.state != State.FLIGHT:
		if pdist < spec.flee_r:
			if c.species == Species.SONGBIRD:
				_start_flight(c, ppos)
			else:
				c.state = State.FLEE
		elif pdist > ACTIVE_RADIUS:
			return  # nobody is watching; save the work

	var moving := false
	match c.state:
		State.IDLE:
			c.timer -= delta
			if c.timer <= 0.0:
				_pick_wander(c, spec)
		State.WANDER:
			moving = _walk_toward(c, c.target, spec, delta)
			if not moving or Vector2(c.pos.x, c.pos.z).distance_to(
					Vector2(c.target.x, c.target.z)) < 0.4:
				c.state = State.IDLE
				c.timer = _rng.randf_range(2.0, 7.0)
				moving = false
		State.FLEE:
			var away := c.pos - ppos
			away.y = 0.0
			moving = _flee_step(c, away.normalized(), spec, delta)
			if pdist > spec.calm_r:
				c.state = State.IDLE
				c.timer = _rng.randf_range(1.0, 4.0)
				c.home = c.pos  # settle here instead of trotting back past the player
		State.FLIGHT:
			_update_flight(c, delta)
			return

	var amp: float = spec.amp * (1.6 if c.state == State.FLEE else 1.0)
	var bob := absf(sin(c.phase * 0.5)) * amp * c.scale if moving else 0.0
	c.mm.set_instance_transform(c.idx, Transform3D(
			Basis(Vector3.UP, c.yaw).scaled(Vector3.ONE * c.scale),
			c.pos + Vector3.UP * bob))


## Picks the next wander target inside the leash; stays put a moment longer if
## the nearby ground refuses (water, cliffs).
func _pick_wander(c: Critter, spec: Dictionary) -> void:
	for attempt in 6:
		var az := _rng.randf_range(0.0, TAU)
		var t := c.home + Vector3(cos(az), 0.0, sin(az)) \
				* _rng.randf_range(2.0, spec.leash)
		var gy := _step_y(t, spec.max_slope)
		if gy != BLOCKED:
			c.target = Vector3(t.x, gy, t.z)
			c.state = State.WANDER
			return
	c.timer = _rng.randf_range(1.0, 3.0)


## One walking step toward [param to]; false when the ground ahead is blocked.
func _walk_toward(c: Critter, to: Vector3, spec: Dictionary,
		delta: float) -> bool:
	var dir := to - c.pos
	dir.y = 0.0
	if dir.length() < 0.001:
		return false
	dir = dir.normalized()
	var next: Vector3 = c.pos + dir * float(spec.walk) * delta
	var gy := _step_y(next, spec.max_slope)
	if gy == BLOCKED:
		return false
	c.yaw = lerp_angle(c.yaw, atan2(dir.x, dir.z), minf(1.0, delta * 6.0))
	c.phase += c.pos.distance_to(Vector3(next.x, gy, next.z)) * TAU \
			/ float(spec.stride)
	c.pos = Vector3(next.x, gy, next.z)
	return true


## A fleeing step: straight away from the player when the ground allows,
## skirting sideways when water or a cliff blocks the line.
func _flee_step(c: Critter, away: Vector3, spec: Dictionary,
		delta: float) -> bool:
	for turn in [0.0, 0.7, -0.7, 1.4, -1.4]:
		var dir := away.rotated(Vector3.UP, turn)
		var next: Vector3 = c.pos + dir * float(spec.flee) * delta
		var gy := _step_y(next, spec.max_slope)
		if gy == BLOCKED:
			continue
		c.yaw = lerp_angle(c.yaw, atan2(dir.x, dir.z), minf(1.0, delta * 8.0))
		c.phase += c.pos.distance_to(Vector3(next.x, gy, next.z)) * TAU \
				/ float(spec.stride)
		c.pos = Vector3(next.x, gy, next.z)
		return true
	return false  # cornered: freeze (reads as an animal standing its ground)


# --- the songbird flush: a flight arc to a fresh perch -----------------------

func _start_flight(c: Critter, ppos: Vector3) -> void:
	var away := c.pos - ppos
	away.y = 0.0
	away = away.normalized()
	c.target = c.home  # fallback: loop up and settle back where it was
	for attempt in 8:
		var dir := away.rotated(Vector3.UP, _rng.randf_range(-0.9, 0.9))
		var t := c.pos + dir * _rng.randf_range(20.0, 35.0)
		var gy := _step_y(t, GROUND_SPECS[c.species].max_slope)
		if gy != BLOCKED:
			c.target = Vector3(t.x, gy, t.z)
			break
	c.fly_from = c.pos
	c.fly_t = 0.0
	c.fly_dur = maxf(1.0,
			c.fly_from.distance_to(c.target) / GROUND_SPECS[c.species].flee)
	c.state = State.FLIGHT


func _update_flight(c: Critter, delta: float) -> void:
	c.fly_t += delta
	var f := clampf(c.fly_t / c.fly_dur, 0.0, 1.0)
	var p := c.fly_from.lerp(c.target, f)
	p.y += sin(f * PI) * 6.0
	var vel := p - c.pos
	if vel.length() > 0.001:
		c.yaw = lerp_angle(c.yaw, atan2(vel.x, vel.z), minf(1.0, delta * 10.0))
	c.pos = p
	c.phase += delta * 22.0  # frantic little wing-beat bob
	var bob := sin(c.phase) * 0.02
	c.mm.set_instance_transform(c.idx, Transform3D(
			Basis(Vector3.UP, c.yaw).scaled(Vector3.ONE * c.scale),
			c.pos + Vector3.UP * bob))
	if f >= 1.0:
		c.pos = c.target
		c.home = c.target
		c.state = State.IDLE
		c.timer = _rng.randf_range(2.0, 6.0)


# --- gulls: banked soaring loops ---------------------------------------------

func _update_gull(c: Critter, delta: float) -> void:
	c.phase += c.omega * delta
	var pos: Vector3 = c.target + Vector3(cos(c.phase) * c.radius,
			sin(_time * 0.6 + c.seed_f) * 1.4, sin(c.phase) * c.radius)
	var tangent := Vector3(-sin(c.phase), 0.0, cos(c.phase)) * signf(c.omega)
	c.yaw = atan2(tangent.x, tangent.z)
	c.pos = pos
	var basis := (Basis(Vector3.UP, c.yaw)
			* Basis(Vector3(0, 0, 1), -signf(c.omega) * 0.28)) \
			.scaled(Vector3.ONE * c.scale)
	c.mm.set_instance_transform(c.idx, Transform3D(basis, pos))


# --- butterflies: a Lissajous drift over the flowers -------------------------

func _update_butterfly(c: Critter) -> void:
	var t := _time * 0.9 + c.seed_f * 20.0
	var p := c.home + Vector3(
			sin(t * 0.43) * 1.6 + sin(t * 0.17 + 1.3) * 1.8, 0.0,
			cos(t * 0.37 + 0.5) * 1.6 + sin(t * 0.23 + 4.1) * 1.8)
	p.y = _ground_y(p.x, p.z) + 0.6 + sin(t * 1.9) * 0.25
	var vel := p - c.pos
	if vel.length() > 0.001:
		c.yaw = lerp_angle(c.yaw, atan2(vel.x, vel.z), 0.1)
	c.pos = p
	var roll := sin(_time * 10.0 + c.seed_f * 7.0) * 0.35  # wing-beat rock
	var basis := (Basis(Vector3.UP, c.yaw) * Basis(Vector3(0, 0, 1), roll)) \
			.scaled(Vector3.ONE * c.scale)
	c.mm.set_instance_transform(c.idx, Transform3D(basis, p))


# --- terrain queries (heightmap, not physics — same maps the world grew from) -

func _ground_y(wx: float, wz: float) -> float:
	var m := _to_map * Vector3(wx, 0.0, wz)
	return Scatter._height_at(_height_img, m.x, m.z) * _y_scale


## Ground height at [param at] when an animal may stand there, else BLOCKED
## (underwater, too steep, or outside the world).
func _step_y(at: Vector3, max_slope: float) -> float:
	if absf(at.x) > HALF_EXTENT or absf(at.z) > HALF_EXTENT:
		return BLOCKED
	var m := _to_map * Vector3(at.x, 0.0, at.z)
	var gy := Scatter._height_at(_height_img, m.x, m.z) * _y_scale
	if gy < GROUND_MIN_Y:
		return BLOCKED
	if Scatter._slope_deg(_height_img, m.x, m.z, _y_scale) > max_slope:
		return BLOCKED
	return gy


func _near_secret(wx: float, wz: float) -> bool:
	for secret in Scatter.SECRETS:
		var sp: Vector3 = secret.pos
		if Vector2(wx, wz).distance_to(Vector2(sp.x, sp.z)) < secret.clear + 4.0:
			return true
	return false
