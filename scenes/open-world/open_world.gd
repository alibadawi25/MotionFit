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

## HUD palette — kept in step with the shared menu look (dark chips, orange accent).
const HUD_ACCENT: Color = Color(1.0, 0.5, 0.14)
const HUD_TEXT: Color = Color(0.96, 0.97, 0.99)
const HUD_MUTED: Color = Color(0.72, 0.76, 0.82)

var _pause_menu: Control
## Maps a stat key ("time"/"calories"/"steps"/"orbs") to its live value Label so
## [method _update_hud] can refresh each chip without rebuilding the bar.
var _hud_values: Dictionary = {}
var _anton: Font
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

	_anton = load("res://assets/fonts/Anton-Regular.ttf")
	_build_hud(layer)

	_pause_menu = load(SceneManager.PAUSE_MENU).instantiate()
	_pause_menu.hide()
	layer.add_child(_pause_menu)
	if _pause_menu.has_method("enable_end_option"):
		_pause_menu.enable_end_option()
	if _pause_menu.has_signal("end_requested"):
		_pause_menu.end_requested.connect(_on_end_requested)


## Lays out the top stat bar (a centred row of chips) and a subtle bottom hint.
## Built in code so the HUD matches the shared menu look without a paired scene.
func _build_hud(layer: CanvasLayer) -> void:
	var bar := HBoxContainer.new()
	bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	bar.offset_top = 22.0
	bar.offset_bottom = 118.0  # a real height so the container lays chips out
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	bar.add_theme_constant_override("separation", 12)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(bar)

	bar.add_child(_make_chip("time", "TIME", HUD_TEXT))
	bar.add_child(_make_chip("calories", "CALORIES", HUD_ACCENT))
	bar.add_child(_make_chip("steps", "STEPS", HUD_TEXT))
	bar.add_child(_make_chip("orbs", "ORBS", HUD_ACCENT))

	var hint := Label.new()
	hint.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	hint.offset_bottom = -22.0
	hint.offset_top = -52.0
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 16)
	hint.add_theme_color_override("font_color", Color(0.82, 0.85, 0.9, 0.62))
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint.text = "ESC — PAUSE  /  END & SAVE"
	layer.add_child(hint)


## One HUD chip: a small caps caption over a large branded value, on a dark
## rounded card. Registers its value Label under [param key] for live updates.
func _make_chip(key: String, caption: String, color: Color) -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(132, 0)
	panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER  # snug height, centred in the bar
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.08, 0.12, 0.72)
	sb.set_corner_radius_all(14)
	sb.set_border_width_all(1)
	sb.border_color = Color(1, 1, 1, 0.09)
	sb.content_margin_left = 20
	sb.content_margin_right = 20
	sb.content_margin_top = 10
	sb.content_margin_bottom = 12
	sb.shadow_color = Color(0, 0, 0, 0.3)
	sb.shadow_size = 10
	panel.add_theme_stylebox_override("panel", sb)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 0)
	panel.add_child(vbox)

	var cap := Label.new()
	cap.text = caption
	cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cap.add_theme_font_size_override("font_size", 13)
	cap.add_theme_color_override("font_color", HUD_MUTED)
	vbox.add_child(cap)

	var value := Label.new()
	value.text = "0"
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	value.add_theme_font_override("font", _anton)
	value.add_theme_font_size_override("font_size", 34)
	value.add_theme_color_override("font_color", color)
	vbox.add_child(value)

	_hud_values[key] = value
	return panel


func _update_hud() -> void:
	if _hud_values.is_empty():
		return
	var seconds: int = int(get_elapsed_sec())
	_hud_values["time"].text = "%d:%02d" % [seconds / 60, seconds % 60]
	_hud_values["calories"].text = "%.0f" % MotionManager.get_session_calories()
	_hud_values["steps"].text = str(MotionManager.get_session_steps())
	_hud_values["orbs"].text = str(_orbs_collected)


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


## A quick scale pop on the ORBS value when one is banked, so pickups feel felt.
func _pulse_orbs_chip() -> void:
	var value: Label = _hud_values.get("orbs")
	if value == null:
		return
	value.pivot_offset = value.size * 0.5
	value.scale = Vector2(1.4, 1.4)
	var tween := value.create_tween()
	tween.tween_property(value, "scale", Vector2.ONE, 0.28) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _on_orb_touched(body: Node3D, orb: Area3D) -> void:
	if body != _player:
		return
	_orbs_collected += 1
	add_score(ORB_SCORE)
	_place_orb(orb)  # respawn elsewhere: an endless trail of small goals
	_update_hud()
	_pulse_orbs_chip()
