extends MiniGame
## OpenWorldGame
##
## The free-roam "vibing" mode: no win/lose, you just move your body to explore.
## It still plugs into the platform like any other game — steps become score (and
## therefore XP) as you rack them up, and the motion pipeline's calories are
## banked automatically on finish — so a session shows on the Results screen and
## in the profile totals exactly like the scored games do.
##
## Because there is no fail state, ending is player-driven: Esc opens the shared
## pause menu, whose "End & Save" wraps the session up and routes to Results.

## How many glow orbs exist in the world at once. Each collected orb instantly
## respawns elsewhere, so there is always somewhere new to walk toward.
const ORB_COUNT: int = 6
## Bonus score per orb (steps score 1 each; orbs reward covering distance).
const ORB_SCORE: int = 10
## Orbs spawn within ±this many metres of the world centre (inside the ground).
const ORB_RANGE: float = 26.0
## A respawned orb lands at least this far from the player — the point is the
## walk, so it must never pop up at your feet.
const ORB_MIN_PLAYER_DIST: float = 8.0
## Brand orange, shared with the UI accent, so goals read as "ours" at a glance.
const ORB_COLOR: Color = Color(1.0, 0.5, 0.14)

var _pause_menu: Control
var _hud_label: Label
var _steps_scored: int = 0
var _orbs_collected: int = 0
var _rng := RandomNumberGenerator.new()

@onready var _player: CharacterBody3D = $CharacterBody3D

func get_game_id() -> String:
	return "open_world"


## MiniGame calls this from begin() (after the setup/countdown intro, or
## immediately if the scene is opened directly); build the world once play starts.
func _start_game() -> void:
	_steps_scored = 0
	_orbs_collected = 0
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


## Builds the 2D overlay: a live stats HUD and the shared pause menu (with its
## "End & Save" option enabled, since this mode has no automatic end).
func _build_overlay() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	_hud_label = Label.new()
	_hud_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_hud_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hud_label.offset_top = 24.0
	_hud_label.add_theme_font_size_override("font_size", 22)
	_hud_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_hud_label)

	_pause_menu = load(SceneManager.PAUSE_MENU).instantiate()
	_pause_menu.hide()
	layer.add_child(_pause_menu)
	if _pause_menu.has_method("enable_end_option"):
		_pause_menu.enable_end_option()
	if _pause_menu.has_signal("end_requested"):
		_pause_menu.end_requested.connect(_on_end_requested)


func _update_hud() -> void:
	if _hud_label == null:
		return
	var seconds: int = int(get_elapsed_sec())
	_hud_label.text = "TIME  %d:%02d      CALORIES  %.0f      STEPS  %d      ORBS  %d      Esc — Pause / End" % [
		seconds / 60, seconds % 60,
		MotionManager.get_session_calories(),
		MotionManager.get_session_steps(),
		_orbs_collected,
	]


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
	mat.emission_energy_multiplier = 1.6
	sphere.material = mat
	mesh.mesh = sphere
	orb.add_child(mesh)
	var collider := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = 0.9  # generous: brushing past at walking speed still collects
	collider.shape = shape
	orb.add_child(collider)
	orb.body_entered.connect(_on_orb_touched.bind(orb))
	return orb


## Drops [param orb] somewhere new on the ground, never right next to the
## player — the orb IS the exercise, so it must always demand a walk.
func _place_orb(orb: Area3D) -> void:
	var pos := Vector3.ZERO
	for attempt in 16:
		pos = Vector3(
			_rng.randf_range(-ORB_RANGE, ORB_RANGE),
			1.0,
			_rng.randf_range(-ORB_RANGE, ORB_RANGE),
		)
		if _player == null or pos.distance_to(_player.global_position) >= ORB_MIN_PLAYER_DIST:
			break
	orb.position = pos


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
