extends Control
## CountdownScreen
##
## Shown between selecting a game and playing it. Counts 3-2-1-GO with a pulse
## animation, names the game about to start, then asks GameManager to launch
## its scene. Keeps the "get ready" moment identical for every game.
##
## Because every game is played with the body, the countdown doubles as the
## get-into-position moment: a status line shows live whether the camera
## pipeline is tracking. It is informational only — the count never blocks, so
## the platform still works with no pose service running (testing, keyboard).

const START_FROM: int = 3
const TICK_SECONDS: float = 1.0
## Brand accent for the "GO!" flash (matches the main menu's orange).
const ACCENT: Color = Color(1.0, 0.5, 0.14)
const TRACKING_COLOR: Color = Color(0.45, 0.9, 0.5)
const NO_SIGNAL_COLOR: Color = Color(1.0, 0.72, 0.3)

@onready var _label: Label = %CountLabel
@onready var _title: Label = %GameTitle
@onready var _status: Label = %StatusLabel

var _remaining: int = START_FROM

func _ready() -> void:
	var game: Dictionary = GameManager.get_game(GameManager.get_current_game_id())
	_title.text = String(game.get("title", "")).to_upper()
	_title.visible = not _title.text.is_empty()
	_show(_remaining)
	var timer := Timer.new()
	timer.wait_time = TICK_SECONDS
	timer.autostart = true
	timer.timeout.connect(_on_tick)
	add_child(timer)


func _process(_delta: float) -> void:
	# Live camera check while the player gets into stance.
	if MotionManager.is_receiving():
		_status.text = "CAMERA TRACKING  —  march in place to move"
		_status.add_theme_color_override("font_color", TRACKING_COLOR)
	else:
		_status.text = "NO CAMERA SIGNAL  —  start the pose service to play with your body"
		_status.add_theme_color_override("font_color", NO_SIGNAL_COLOR)


func _on_tick() -> void:
	_remaining -= 1
	if _remaining > 0:
		_show(_remaining)
	elif _remaining == 0:
		_label.text = "GO!"
		_label.add_theme_color_override("font_color", ACCENT)
		_pulse()
	else:
		GameManager.launch_current_game_scene()


func _show(value: int) -> void:
	_label.text = str(value)
	_pulse()


## One count beat: the number lands with a springy scale-down and a quick fade.
## Big and rhythmic on purpose — the player is standing back from the screen
## getting into stance, so each beat must read from across the room.
func _pulse() -> void:
	_label.pivot_offset = _label.size / 2.0
	_label.scale = Vector2(1.35, 1.35)
	_label.modulate.a = 0.0
	var tween := create_tween().set_parallel(true)
	tween.tween_property(_label, "scale", Vector2.ONE, 0.4) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(_label, "modulate:a", 1.0, 0.18)
