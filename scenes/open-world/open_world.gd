extends MiniGame
## OpenWorldGame
##
## The free-roam "vibing" mode: no win/lose, you just move your body to explore.
## It still plugs into the platform like any other game — steps become score (and
## therefore XP) as you rack them up, and the motion pipeline's calories are
## banked automatically on finish — so a session shows on the Results screen and
## in the profile totals exactly like the scored games do.
##
## The world is a sculpted HTerrain heightmap: the player (at the SPAWN_MARKER)
## and every orb are snapped to the real surface with a downward raycast, so
## nobody floats or buries in a slope (see [method _ground_y]).
##
## Because there is no fail state, ending is player-driven: Esc opens the shared
## pause menu, whose "End & Save" wraps the session up and routes to Results.

## How many glow orbs exist in the world at once. Each collected orb instantly
## respawns elsewhere, so there is always somewhere new to walk toward.
const ORB_COUNT: int = 6
## Bonus score per orb (steps score 1 each; orbs reward covering distance).
const ORB_SCORE: int = 10
## Orbs spawn within ±this many metres of the PLAYER (not the world origin) —
## on a large terrain the player rarely stands at the centre, so anchoring to
## them keeps every goal a short, reachable walk away.
const ORB_RANGE: float = 26.0
## A (re)spawned orb lands at least this far from the player — the point is the
## walk, so it must never pop up at your feet.
const ORB_MIN_PLAYER_DIST: float = 8.0
## Orbs must land on dry ground: candidates whose surface sits less than this
## far above the sea plane are rejected, so no goal ever bobs in (or under) the
## water. The margin keeps them clear of the shader's animated wave crests.
const ORB_SEA_MARGIN: float = 0.6
## Orbs also keep this far clear of the world's fog border (see world_border.gd).
## A goal sitting in the murk would be walking the player straight at the one
## place the world pushes back — the border must never be somewhere you're sent.
const ORB_BORDER_MARGIN: float = 10.0
## Brand orange, shared with the UI accent, so goals read as "ours" at a glance.
const ORB_COLOR: Color = Color(1.0, 0.5, 0.14)

## Downward ground-probe range: above the tallest plausible peak, past the lowest
## valley, so the surface is found however the terrain is sculpted.
const _PROBE_TOP: float = 800.0
const _PROBE_BOTTOM: float = -800.0
## Clearance above the surface for the player's capsule centre / a resting orb (m).
const _PLAYER_CLEARANCE: float = 1.1
const _ORB_CLEARANCE: float = 1.2
## Optional Marker3D (direct child of the root) naming where — and which way — the
## player starts; when absent the player's authored transform is used.
const SPAWN_MARKER: String = "SpawnPoint"

var _pause_menu: Control
var _hud: OpenWorldHud  # the on-screen stat bar (see open_world_hud.gd)
var _steps_scored: int = 0
var _orbs_collected: int = 0
var _rng := RandomNumberGenerator.new()

@onready var _player: CharacterBody3D = $CharacterBody3D
@onready var _camera: Camera3D = $Camera3D
## The sea surface (optional): its height defines the world's water level.
@onready var _sea: Node3D = get_node_or_null("Sea")
## The world's fog rim (optional): keeps the player in and the orbs out of it.
@onready var _border: WorldBorder = get_node_or_null("WorldBorder") as WorldBorder

func get_game_id() -> String:
	return "open_world"


## Stand the player at the spawn marker (and frame the camera on them) before the
## intro, so the countdown's reveal shows them ready at the start line. The
## precise ground-snap waits for _start_game: the terrain collider isn't
## queryable yet while the intro holds the world frozen on its first frame.
func _prepare_world() -> void:
	# HTerrain builds its visible chunks lazily in _process, so let it keep running
	# through the intro freeze — otherwise the countdown reveals the player standing
	# on nothing (see MiniGame.KEEP_PROCESSING_GROUP).
	var terrain := get_node_or_null("HTerrain")
	if terrain != null:
		terrain.add_to_group(KEEP_PROCESSING_GROUP)
	_move_player_to_spawn_marker()
	if _camera != null and _camera.has_method("snap_to_target"):
		_camera.snap_to_target()


## MiniGame calls this from begin() (after the setup/countdown intro, or
## immediately if the scene is opened directly); build the world once play starts.
func _start_game() -> void:
	_steps_scored = 0
	_orbs_collected = 0
	# Wait one physics tick so HTerrain's collider is live for our ground probes,
	# then plant the player on the surface before scattering the (also-snapped) orbs.
	await get_tree().physics_frame
	_drop_player_to_ground()
	_build_overlay()
	_spawn_orbs()
	_update_hud()


func _process(delta: float) -> void:
	super._process(delta)  # keep MiniGame's elapsed-time clock running
	# Convert new body steps into score (and thus XP) as they accumulate.
	var steps: int = MotionManager.get_session_steps()
	if steps > _steps_scored:
		add_score(steps - _steps_scored)
		_steps_scored = steps
	_update_hud()
	# Fade the border's TURN BACK prompt in on the same haze the fog and the
	# movement resistance use, so the world says it as it starts doing it.
	if _border != null and _hud != null and _player != null:
		_hud.set_border_warning(_border.get_haze(_player.global_position))


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_toggle_pause()


func _toggle_pause() -> void:
	if _pause_menu == null:
		return
	if _pause_menu.visible:
		_pause_menu.close()
	else:
		_pause_menu.open()


func _on_end_requested() -> void:
	get_tree().paused = false
	finish()  # banks session calories (MiniGame default) + step-based XP


## Builds the 2D overlay: the stats HUD (its own CanvasLayer) and the shared pause
## menu (with its "End & Save" option enabled, since this mode has no automatic end).
func _build_overlay() -> void:
	_hud = OpenWorldHud.new()
	add_child(_hud)

	var layer := CanvasLayer.new()
	add_child(layer)
	_pause_menu = load(SceneManager.PAUSE_MENU).instantiate()
	_pause_menu.hide()
	layer.add_child(_pause_menu)
	if _pause_menu.has_method("enable_end_option"):
		_pause_menu.enable_end_option()
	if _pause_menu.has_signal("end_requested"):
		_pause_menu.end_requested.connect(_on_end_requested)


func _update_hud() -> void:
	if _hud == null:
		return
	_hud.set_stats(int(get_elapsed_sec()), MotionManager.get_session_calories(),
			MotionManager.get_session_steps(), _orbs_collected)
	# Live bpm chip — only appears while a heart-rate strap is streaming.
	_hud.set_heart_rate(
			MotionManager.get_heart_rate() if MotionManager.is_hr_connected() else 0.0)


## Scatters the collectible orbs. Built in code (not the scene) so the count
## and placement rules stay data — the scene keeps only the hand-placed world.
func _spawn_orbs() -> void:
	for i in ORB_COUNT:
		var orb := _make_orb()
		add_child(orb)
		_place_orb(orb)
		_start_orb_bob(orb)


## One orb: a glowing sphere inside a generous trigger area.
func _make_orb() -> Area3D:
	var orb := Area3D.new()
	var mesh := MeshInstance3D.new()
	mesh.name = "Mesh"
	var sphere := SphereMesh.new()
	sphere.radius = 0.35
	sphere.height = 0.7
	var mat := StandardMaterial3D.new()
	mat.albedo_color = ORB_COLOR
	mat.emission_enabled = true
	mat.emission = ORB_COLOR
	# Must clear the environment's glow_hdr_threshold (0.95) with room to spare,
	# or the orb reads as a flat orange dot instead of a light source. This is what
	# makes a distant orb findable across a valley.
	mat.emission_energy_multiplier = 2.4
	sphere.material = mat
	mesh.mesh = sphere
	# An orb is a light source; letting it cast the sun's shadow drops a dark
	# blot on the hillside right where the glow should be selling it.
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	orb.add_child(mesh)

	# A short-range glow spilling onto the ground around it. Bloom alone makes an
	# orb bright; this makes it belong to the terrain it is resting on, and gives
	# it a pool of colour visible before the orb itself clears the ridgeline.
	var lamp := OmniLight3D.new()
	lamp.light_color = ORB_COLOR
	lamp.light_energy = 2.0
	lamp.omni_range = 7.0
	lamp.shadow_enabled = false  # six of these; the pool reads fine without it
	mesh.add_child(lamp)  # rides the bob, so the pool breathes with the orb
	var collider := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = 0.9  # generous: brushing past at walking speed still collects
	collider.shape = shape
	orb.add_child(collider)
	orb.body_entered.connect(_on_orb_touched.bind(orb))
	return orb


## Drops [param orb] somewhere new around the player, never right next to them —
## the orb IS the exercise, so it must always demand a walk — then snaps it onto
## the terrain surface so it rests on hills / in valleys rather than floating.
## Underwater ground is rejected too (see [constant ORB_SEA_MARGIN]), as is the
## fog border (see [constant ORB_BORDER_MARGIN]); if every attempt fails (player
## deep in a flooded basin, or pressed right up against the rim), the last
## candidate is used — a wet orb beats a hung spawner.
func _place_orb(orb: Area3D) -> void:
	var anchor: Vector3 = _player.global_position if _player != null else Vector3.ZERO
	# A player standing IN the fog band would fail every attempt below — the band
	# is wider than ORB_RANGE, so no candidate around them can be in the free
	# world — and the fallback would strand the orb somewhere they can't walk to.
	# Anchor to the reachable side instead: still a short walk, just an inward one.
	if _border != null:
		anchor = _border.pull_inside(anchor, ORB_BORDER_MARGIN)
	var sea_y: float = _sea.global_position.y if _sea != null else -INF
	var pos := anchor
	var gy: float = anchor.y
	for attempt in 24:
		pos = anchor + Vector3(
			_rng.randf_range(-ORB_RANGE, ORB_RANGE),
			0.0,
			_rng.randf_range(-ORB_RANGE, ORB_RANGE),
		)
		gy = _ground_y(pos.x, pos.z, anchor.y)
		var far_enough: bool = _player == null \
				or pos.distance_to(_player.global_position) >= ORB_MIN_PLAYER_DIST
		var in_world: bool = _border == null \
				or _border.is_inside(pos, ORB_BORDER_MARGIN)
		if far_enough and in_world and gy >= sea_y + ORB_SEA_MARGIN:
			break
	pos.y = gy + _ORB_CLEARANCE
	orb.global_position = pos


## Moves the player onto the terrain and re-bases its fall-respawn point there.
## Starts at [constant SPAWN_MARKER] if present, else the authored position. Then
## re-writes player.gd's `_spawn_transform` (captured in its _ready, before this)
## so a fall off the world sends it back to the surface, not beneath it.
func _drop_player_to_ground() -> void:
	if _player == null:
		return
	_move_player_to_spawn_marker()
	var p: Vector3 = _player.global_position
	var gy: float = _ground_y(p.x, p.z, p.y, [_player.get_rid()])
	_player.global_position = Vector3(p.x, gy + _PLAYER_CLEARANCE, p.z)
	_player.set("_spawn_transform", _player.global_transform)


## Places the player at the [constant SPAWN_MARKER] transform (position + facing)
## when the marker exists. Shared by the intro preview and the ground-snap.
func _move_player_to_spawn_marker() -> void:
	var marker := get_node_or_null(SPAWN_MARKER) as Node3D
	if marker == null or _player == null:
		return
	_player.global_position = marker.global_position
	_player.rotation.y = marker.global_rotation.y


## Terrain surface Y under (x,z) via a downward raycast, or [param fallback] on a
## miss (off the map, or the collider not ready). [param exclude] drops bodies the
## probe should ignore (e.g. the player's own capsule). Reaches the physics world
## through _player: this script's base type is Node (via MiniGame) so `self` has
## no get_world_3d(), but the player shares the same World3D.
func _ground_y(x: float, z: float, fallback: float, exclude: Array = []) -> float:
	if _player == null:
		return fallback
	var space := _player.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(
		Vector3(x, _PROBE_TOP, z), Vector3(x, _PROBE_BOTTOM, z))
	q.exclude = exclude
	var hit := space.intersect_ray(q)
	return hit.position.y if hit else fallback


## A gentle endless bob on the orb's mesh (not its root, which _place_orb
## teleports around) so orbs read as pick-ups rather than scenery.
func _start_orb_bob(orb: Area3D) -> void:
	var mesh: Node3D = orb.get_node("Mesh")
	var tween := mesh.create_tween().set_loops()
	tween.tween_property(mesh, "position:y", 0.3, 1.2) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(mesh, "position:y", 0.0, 1.2) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func _on_orb_touched(body: Node3D, orb: Area3D) -> void:
	if body != _player:
		return
	_orbs_collected += 1
	add_score(ORB_SCORE)
	_place_orb(orb)  # respawn elsewhere: an endless trail of small goals
	_update_hud()
	if _hud != null:
		_hud.pulse_orbs()
