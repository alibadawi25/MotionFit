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

var _pause_menu: Control
var _hud_label: Label
var _steps_scored: int = 0

func get_game_id() -> String:
	return "open_world"


func _ready() -> void:
	# No countdown is required to reach this scene directly, but when launched
	# through the platform the countdown has already run — either way we start
	# the session the moment the world is ready.
	begin()


## MiniGame calls this from begin(); build the overlay once gameplay starts.
func _start_game() -> void:
	_steps_scored = 0
	_build_overlay()
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
	_hud_label.text = "CALORIES  %.0f        STEPS  %d        Esc — Pause / End" % [
		MotionManager.get_session_calories(),
		MotionManager.get_session_steps(),
	]
