extends Node3D
## Throwaway dev view: boots the open world and parks a camera on the LIVE
## wildlife system (wildlife.gd) so a species can be judged in its real biome —
## standing in the actual woods/meadow/shore light, mid-wander or mid-loop.
## Prints every species' population + first position to the log. HUD layers
## are hidden. Pair with tools/shot.sh:
##   bash tools/shot.sh wildlife scenes/tests/wildlife_view.tscn
## Env: WL_SPECIES = deer | fox | rabbit | songbird | gull | butterfly
## picks what the camera frames (default deer).

const Wildlife := preload("res://scenes/open-world/wildlife.gd")

var _cam: Camera3D

func _ready() -> void:
	var world: Node = load("res://scenes/open-world/open-world.tscn").instantiate()
	add_child(world)
	_cam = Camera3D.new()
	_cam.fov = 65.0
	add_child(_cam)
	_frame_when_ready.call_deferred()


func _frame_when_ready() -> void:
	# Give the world a moment to build (terrain, scatter, wildlife spawn).
	for i in 30:
		await get_tree().physics_frame
	var wl: Node = get_node_or_null("OpenWorld/Wildlife")
	if wl == null:
		push_warning("wildlife_view: no Wildlife node found")
		return
	# The world's DOF blurs anything nearer than a few metres — a macro shot of
	# a rabbit or butterfly comes back as grey soup without this.
	var env := get_node_or_null("OpenWorld/WorldEnvironment") as WorldEnvironment
	if env != null:
		env.camera_attributes = null
	for s in Wildlife.Species:
		var flock: Array[Vector3] = wl.debug_positions(Wildlife.Species[s])
		print("wildlife %s: %d  %s" % [s, flock.size(),
				str(flock[0]) if not flock.is_empty() else ""])

	var wanted := OS.get_environment("WL_SPECIES").to_upper()
	if not Wildlife.Species.has(wanted):
		wanted = "DEER"
	var species: int = Wildlife.Species[wanted]
	var spots: Array[Vector3] = wl.debug_positions(species)
	if spots.is_empty():
		push_warning("wildlife_view: no %s spawned" % wanted)
		return
	var at: Vector3 = spots[0]
	if species == Wildlife.Species.GULL:
		# Gulls circle a fixed centre — frame that, not the moving bird.
		for c in wl.get("_critters"):
			if c.species == species:
				at = c.target
				break
		_cam.global_position = at + Vector3(22.0, 3.0, 14.0)
		_cam.look_at(at)
	else:
		# Ground-snap the camera spot — a fixed height offset ends up inside
		# the hillside on sloped biomes and the shot comes back black.
		# Butterflies are 16 cm: step right up to them.
		var back := 2.2 if species == Wildlife.Species.BUTTERFLY else 4.6
		var cx := at.x + back
		var cz := at.z + back * 1.17
		var rise := 0.4 if species == Wildlife.Species.BUTTERFLY else 1.7
		var cy: float = maxf(wl._ground_y(cx, cz), at.y) + rise
		_cam.global_position = Vector3(cx, cy, cz)
		_cam.look_at(at + (Vector3.ZERO if species == Wildlife.Species.BUTTERFLY
				else Vector3(0.0, 0.5, 0.0)))

	# --- behaviour probes, printed to the shot log -------------------------
	# Motion: the largest displacement in the flock over 1.5 s (idle animals sit
	# still by design, so judge the herd, not one individual).
	await get_tree().create_timer(1.5).timeout
	var after: Array[Vector3] = wl.debug_positions(species)
	var moved := 0.0
	for i in mini(spots.size(), after.size()):
		moved = maxf(moved, spots[i].distance_to(after[i]))
	print("wildlife probe: max %s move in 1.5 s = %.2f m" % [wanted, moved])

	var player := get_node_or_null("OpenWorld/CharacterBody3D") as Node3D
	if player != null and species != Wildlife.Species.GULL \
			and species != Wildlife.Species.BUTTERFLY:
		# Wander: land the player 40 m off — inside ACTIVE_RADIUS (un-freezes
		# the herd) but outside flee range — and watch idle animals roam.
		player.global_position = after[0] + Vector3(40.0, 1.2, 0.0)
		await get_tree().create_timer(6.0).timeout
		var roam: Array[Vector3] = wl.debug_positions(species)
		var wander := 0.0
		for i in mini(after.size(), roam.size()):
			wander = maxf(wander, after[i].distance_to(roam[i]))
		print("wildlife probe: max %s wander in 6 s (player 40 m off) = %.2f m"
				% [wanted, wander])
		# Flee: now drop the player right beside one and watch it bolt.
		player.global_position = roam[0] + Vector3(2.0, 1.2, 0.0)
		await get_tree().create_timer(2.5).timeout
		var fled: Array[Vector3] = wl.debug_positions(species)
		print("wildlife probe: %s at %.1f m from player 2.5 s after landing 2 m away"
				% [wanted, fled[0].distance_to(player.global_position)])


func _process(_delta: float) -> void:
	if _cam != null and not _cam.current:
		_cam.make_current()  # the player rig claims the viewport when it spawns
	for layer in find_children("*", "CanvasLayer", true, false):
		(layer as CanvasLayer).visible = false
