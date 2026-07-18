extends Node3D
## WorldBorder
##
## The edge of the open world: a rolling bank of fog you cannot walk out of.
##
## The terrain is a finite 1024 m square, so something has to stop the player at
## its rim — and the honest options all feel bad. An invisible wall stops you
## dead at nothing. A visible fence admits the world is a box. Teleporting you
## back breaks the one promise a free-roam mode makes. So this takes the Black
## Flag approach instead: the world doesn't END, it gets too thick to continue
## into, and you turn around because you want to.
##
## [b]The border is a SQUARE, hugging the terrain's own rim.[/b] This was a circle
## first, and that was a mistake worth remembering: a circle inscribed in a square
## throws away every corner — a radius of 224 kept barely 60% of the map and put
## the wall only ~40 m from the spawn. The boundary must follow the shape of the
## thing it is bounding. Each axis is handled independently (see
## [method limit_velocity]), which is what makes corners fall out for free.
##
## The illusion is four cheap systems agreeing with each other, all keyed off one
## number — [method get_haze], how far into the border band you are:
##   1. [b]The bank[/b]: two nested rings of border_fog.gdshader walls at the rim.
##      Two, not one, so they parallax against each other as you move and read as
##      a volume rather than a decal. They hide the terrain's rim and the empty
##      sea past it.
##   2. [b]The whiteout[/b]: the WorldEnvironment's depth-fog gradient is collapsed
##      inward as you push in (clear plane to the camera, full white ~20 m out),
##      so the air around YOU thickens too. This is the piece that actually sells
##      it — geometry alone always looks like a thing you are standing next to,
##      never like weather you are inside of.
##   3. [b]The refusal[/b]: [method limit_velocity] caps how fast you may still
##      travel outward by how much room is left, which decays to a glide you can
##      never finish. You are never stopped — you just stop arriving. Most
##      players turn back long before the cap is even tight.
##   4. [b]The word[/b]: the game fades a TURN BACK prompt in on the same haze,
##      so nobody is left shoving at thin air wondering if they're stuck.
##
## Rule of thumb for tuning any of this: the player must never feel the moment
## they were stopped, and the free world must stay as big as the terrain is. If a
## change makes the boundary crisper, or moves it inward, it is wrong.

class_name WorldBorder

const FOG_SHADER: String = "res://scenes/open-world/border_fog.gdshader"

## Half-width of the playable square, in metres from the world centre — i.e. the
## hard limit on |x| and |z|. The terrain itself is 1024 m across (±512), so this
## leaves the walk going all the way to the coast and keeps ~94% of the map.
## It is a limit made of arithmetic rather than collision (see
## [method limit_velocity]).
const HALF_EXTENT: float = 496.0
## Where the fog and the TURN BACK prompt begin: the outer 30 m of the map.
## Deliberately NOT scaled with the map. This band is measured against how fast a
## player moves (~8 m/s → about four seconds of warning), not against how big the
## world is; widening it with the terrain would only mean more of a bigger map is
## fog. If the terrain grows again, this number stays put.
## Note SOFT_EXTENT and HALF_EXTENT do NOT gate the same things. The fog and the
## prompt start here, but the movement cap only bites in the last stretch (see
## [constant STOP_TIME]) — so you are always WARNED well before you are HELD, and
## the world never seems to grab you out of nowhere.
const SOFT_EXTENT: float = 466.0
## Seconds over which outward movement is shed as [constant HALF_EXTENT]
## approaches. Sets how long the glide is: at a full-tilt march (~8 m/s) the cap
## starts biting about 8 × this many metres out, and decays exponentially.
const STOP_TIME: float = 2.0

## Half-extents of the two fog rings, innermost first. Both sit OUTSIDE
## [constant HALF_EXTENT] so the player always views the bank from a few metres
## short of it and never punches through a wall (which, being a surface, would
## give the volume away instantly). The outer ring clears the terrain rim
## entirely, standing in open water.
const RING_EXTENTS: Array[float] = [508.0, 532.0]
## World-space Y of the walls' bottom and top edges. Deep enough to bury the sea
## floor; tall enough to wall off the sky at the coast, where the land is low.
## These track the terrain's VERTICAL scale, not its footprint: taller hills need
## a taller wall to stay hidden behind, and a deeper sea floor needs burying
## further down.
const RING_BOTTOM: float = -30.0
const RING_TOP: float = 135.0

## Where the environment's DEPTH fog reaches full white at [constant HALF_EXTENT]:
## ~20 m out. The scene runs Depth-mode fog (a long begin→end gradient, so the
## world hazes off gradually over hundreds of metres rather than an exponential
## wall close to the camera). To white the rim out we don't touch density —
## Depth mode ignores it — we collapse the whole gradient onto the player:
## [member Environment.fog_depth_begin] slides to 0 and end to this, so at the
## limit there is ~20 m of visibility and nothing left to walk toward.
const WALL_FOG_END: float = 20.0

## The player, whose distance into the band drives the whole effect.
@export var player_path: NodePath
## The scene's WorldEnvironment, whose fog density is ramped as the player pushes
## into the band. Optional: without it you still get the bank and the refusal.
@export var environment_path: NodePath

var _player: Node3D
var _environment: WorldEnvironment
## The scene's authored depth-fog gradient (near clear plane and far full-white
## plane), captured so the ramp can return to it instead of hardcoding values
## that would silently diverge from the scene.
var _base_depth_begin: float = 0.0
var _base_depth_end: float = 0.0


func _ready() -> void:
	_player = get_node_or_null(player_path) as Node3D
	_environment = get_node_or_null(environment_path) as WorldEnvironment
	if _environment != null and _environment.environment != null:
		_base_depth_begin = _environment.environment.fog_depth_begin
		_base_depth_end = _environment.environment.fog_depth_end
	_build_rings()


func _process(_delta: float) -> void:
	if _player == null or _environment == null or _environment.environment == null:
		return
	# Thicken the air the player is standing in, not just the air at the rim:
	# collapse the long depth gradient inward as they push into the band, so the
	# clear plane slides up to the camera and full white closes to ~20 m out.
	var haze: float = get_haze(_player.global_position)
	var env: Environment = _environment.environment
	env.fog_depth_begin = lerpf(_base_depth_begin, 0.0, haze)
	env.fog_depth_end = lerpf(_base_depth_end, WALL_FOG_END, haze)


## Builds the fog bank: two square rings of four inward-facing walls each, sharing
## one noise texture but drifting at different rates so they never move as one
## sheet. Square rings rather than cylinders because the bank has to sit ON the
## border, and the border follows the terrain (see the class docs) — a cylinder
## big enough to clear the corners would stand 100 m out to sea at the edge
## midpoints, leaving the rim it exists to hide in plain view.
func _build_rings() -> void:
	var shader: Shader = load(FOG_SHADER)
	var noise: NoiseTexture2D = _make_noise()
	for i in RING_EXTENTS.size():
		var extent: float = RING_EXTENTS[i]
		var mesh := PlaneMesh.new()
		mesh.orientation = PlaneMesh.FACE_Z  # upright, facing +Z (i.e. inward)
		# Overlap the corners rather than butting the walls together: a hairline
		# gap at a corner would be a slot straight out of the world.
		var width: float = extent * 2.0 + 8.0
		mesh.size = Vector2(width, RING_TOP - RING_BOTTOM)
		mesh.material = _make_wall_material(shader, noise, i, width)

		# One pivot per side, each a quarter-turn further round; the wall hangs off
		# it at -Z, so it always ends up facing the middle of the map.
		for side in 4:
			var pivot := Node3D.new()
			pivot.name = "Ring%dSide%d" % [i, side]
			pivot.rotation.y = side * PI * 0.5
			add_child(pivot)

			var wall := MeshInstance3D.new()
			wall.mesh = mesh
			wall.position = Vector3(0.0, (RING_TOP + RING_BOTTOM) * 0.5, -extent)
			# A fog bank casting a shadow would ring the whole coast in a dark band.
			wall.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			pivot.add_child(wall)


## One ring's material. [param index] is its slot in [constant RING_EXTENTS]
## (0 = innermost) and drives both the parallax and the draw order.
func _make_wall_material(shader: Shader, noise: NoiseTexture2D, index: int,
		width: float) -> ShaderMaterial:
	var outer: bool = index > 0
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("fog_noise", noise)
	mat.set_shader_parameter("base_y", RING_BOTTOM)
	mat.set_shader_parameter("top_y", RING_TOP)
	# Sit the bank IN the sky's own colour, not brighter than it: the default fog
	# white (0.8) glows as a distinct pale slab against the pale-blue horizon,
	# which is half of why it read as a wall. Pull it down onto the horizon tint
	# (sky_horizon 0.68,0.76,0.84 / env fog 0.66,0.73,0.82) so the top of the
	# gradient simply vanishes into the sky.
	mat.set_shader_parameter("fog_color", Color(0.71, 0.78, 0.85))
	mat.set_shader_parameter("deep_color", Color(0.5, 0.58, 0.68))
	# The outer ring wraps fewer, larger clumps and drifts slower: distance reads
	# as scale plus parallax, exactly like the far layer of a painted backdrop.
	# Counted in tiles per WALL rather than per metre, so this has to be derived
	# from the ring's size or the clumps swell along with the map, until the bank
	# is a few vast smears and reads as one sliding sheet again. Rounded to a whole
	# number of tiles because a fractional count leaves the two ends of a wall
	# mismatched, and the corners are where two walls meet.
	var metres_per_tile: float = 64.0 if outer else 47.0
	var across: float = maxf(roundf(width / metres_per_tile), 1.0)
	mat.set_shader_parameter("tiles_across", across)
	# Derive the vertical tiling from the wall's real width so a noise tile comes
	# out SQUARE in world metres. The wall is ~6x wider than it is tall, so any
	# fixed vertical rate stretches the clumps into vertical streaks — which is
	# exactly what a fog bank must never have.
	mat.set_shader_parameter("tiles_up", across / maxf(width, 0.001))
	mat.set_shader_parameter("scroll", 0.65 if outer else 1.0)
	# The division of labour between the rings. The outer one is the WALL: mostly
	# solid, so the rim and the empty sea behind it are genuinely gone. The inner
	# one is the WEATHER: soft clumps drifting across the outer one at a different
	# rate. Both keep a real FLOOR of haze now (the inner one used to have none),
	# so from the island the bank reads as a smooth pale mist rather than a field
	# of speckles — the clumps modulate that haze instead of poking through empty
	# sky. Realism, not drama: seen from 500 m across the water through the
	# aerial fog, any bare gap between clumps flickers as a white speck.
	mat.set_shader_parameter("floor_density", 0.95 if outer else 0.7)
	mat.set_shader_parameter("density", 1.0 if outer else 0.72)
	mat.set_shader_parameter("coverage", 0.3 if outer else 0.4)
	# Soften the clump edges: the default contrast (2.4) stretches the noise into
	# hard-edged blobs, which is exactly what reads as speckle at distance. A
	# gentle stretch (near 1.0 = almost none) keeps a whisper of billow but blurs
	# its rim into the haze floor instead of punching holes to the sky.
	mat.set_shader_parameter("contrast", 1.2 if outer else 1.35)
	# Make it a GRADIENT, not a slab. The sea meets the bank at h≈0.27 (waterline
	# y=15 between base -30 and top 135); the old top_start held FULL opacity from
	# there up to h=0.42 before fading, which is the ~24 m solid strip that read as
	# a wall standing on the water. Start the fade right at the waterline instead,
	# so the bank is thickest at the horizon and thins continuously all the way up
	# into the sky — natural aerial haze rather than a painted flat. A wider
	# raggedness breaks the fade line so it never resolves into a clean top edge.
	mat.set_shader_parameter("top_start", 0.29 if outer else 0.26)
	mat.set_shader_parameter("raggedness", 0.55)
	# Draw order has to be stated outright, because depth cannot settle it. The
	# walls share a centre with the sea plane, so Godot's transparent sort — which
	# orders by distance to the AABB centre — sees objects at the same place and
	# picks arbitrarily. Left alone it drew the sea LAST, painting 800 m of open
	# water straight over the fog bank.
	# Priorities ascend: sea (0) → outer ring → inner ring. Safe despite the sea
	# being nearer than the bank in places, because a vertical wall out at the rim
	# always sits ABOVE the water this side of it on screen; the only water the
	# bank paints over is the water beyond it, which is exactly the water that is
	# supposed to be gone.
	mat.render_priority = RING_EXTENTS.size() - index
	return mat


## The shared noise for the bank: soft, many-octave FBM. Seamless so a wall can
## tile it without showing a join.
func _make_noise() -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.008
	noise.fractal_octaves = 5
	noise.fractal_lacunarity = 2.1
	noise.fractal_gain = 0.55
	var tex := NoiseTexture2D.new()
	tex.width = 512
	tex.height = 512
	tex.seamless = true
	tex.noise = noise
	return tex


## How deep [param pos] has pushed into the border band: 0 anywhere in the free
## world, 1 at [constant HALF_EXTENT] and beyond. Every part of the effect — fog,
## refusal, HUD prompt — is a function of this one number, which is why they
## always agree with each other.
func get_haze(pos: Vector3) -> float:
	var span: float = maxf(HALF_EXTENT - SOFT_EXTENT, 0.001)
	return clampf((_edge_reach(pos) - SOFT_EXTENT) / span, 0.0, 1.0)


## True when [param pos] sits in the free world with [param margin] metres to
## spare. Used to keep spawned goals (orbs) out of the band — a collectible
## sitting in the fog would be luring the player at a wall.
func is_inside(pos: Vector3, margin: float = 0.0) -> bool:
	return _edge_reach(pos) <= SOFT_EXTENT - margin


## The closest point to [param pos] that is still in the free world with
## [param margin] metres to spare, kept at the same height. Somewhere to put
## things that must stay reachable when the player themselves is standing in the
## fog — see open_world.gd's orb placement.
func pull_inside(pos: Vector3, margin: float = 0.0) -> Vector3:
	var limit: float = maxf(SOFT_EXTENT - margin, 0.0)
	var centre: Vector3 = global_position
	return Vector3(
		clampf(pos.x, centre.x - limit, centre.x + limit),
		pos.y,
		clampf(pos.z, centre.z - limit, centre.z + limit))


## Caps how fast [param vel] may still carry [param pos] toward the rim: no
## faster than the room left allows if it is to be shed over
## [constant STOP_TIME]. This — not a collider — is what makes the border
## impassable, and it's why it doesn't feel like one:
##   * it's a CAP, not a scale. The obvious version (multiply the outward speed
##     by 1 - haze each frame) compounds against the player's acceleration ramp:
##     the two settle at an equilibrium of a few cm/s, so entering the band nails
##     you to the spot. Capping leaves the walk alone until the cap is actually
##     lower than the speed you're asking for.
##   * the cap decays with the room left, which integrates to an exponential
##     approach — you glide, always slowing, and never arrive. There is no frame
##     where you hit something, because you never do.
##   * the two axes are capped SEPARATELY, so movement along the border is
##     untouched (you skim the fog rather than scraping a wall) and corners need
##     no special case — they are just both axes running out at once.
##   * movement back inward is never touched, so the moment you turn around the
##     world lets go of you completely.
## Independent of the player's top speed on purpose: a faster body simply meets
## the cap further out and gets a longer glide.
func limit_velocity(pos: Vector3, vel: Vector3) -> Vector3:
	var centre: Vector3 = global_position
	vel.x = _cap_axis(pos.x - centre.x, vel.x)
	vel.z = _cap_axis(pos.z - centre.z, vel.z)
	return vel


## The capped speed along one axis, given [param offset] from the centre on that
## axis and the [param speed] being asked for along it.
func _cap_axis(offset: float, speed: float) -> float:
	if offset * speed <= 0.0:
		return speed  # still, or heading home: never fight the player
	var room: float = maxf(HALF_EXTENT - absf(offset), 0.0)
	return signf(speed) * minf(absf(speed), room / STOP_TIME)


## Hard backstop, applied after the move: pulls [param pos] back inside the square
## if anything at all (a slide down a slope, a respawn, a future shove) has
## carried the player past it. [method limit_velocity] should mean this never has
## to do anything; it exists so "cannot leave" is guaranteed by position and not
## just by intent. Height is never touched — the border only ever pulls sideways.
func clamp_position(pos: Vector3) -> Vector3:
	var centre: Vector3 = global_position
	return Vector3(
		clampf(pos.x, centre.x - HALF_EXTENT, centre.x + HALF_EXTENT),
		pos.y,
		clampf(pos.z, centre.z - HALF_EXTENT, centre.z + HALF_EXTENT))


## How far [param pos] reaches toward the rim: its distance from the centre along
## whichever axis is closest to running out. Constant along a square ring, which
## is what makes every band above follow the terrain's own shape instead of
## rounding its corners off.
func _edge_reach(pos: Vector3) -> float:
	return maxf(absf(pos.x - global_position.x), absf(pos.z - global_position.z))
