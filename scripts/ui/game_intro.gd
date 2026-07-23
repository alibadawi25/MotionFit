extends CanvasLayer
## GameIntro
##
## The pre-game overlay every mini-game shows before play begins. Because every
## game is played with the body, the moment before a game starts is where the
## player frames themselves in the camera and signals they're ready — so this
## overlay owns two phases:
##
##   1. SETUP    — a live mirror of the webcam fills the screen. The player steps
##                 back, gets in frame, then RAISES BOTH HANDS to start. Holding
##                 the gesture fills a bar; releasing lets it fall back.
##   2. COUNTDOWN — the mirror shrinks to a corner thumbnail, the dim backdrop
##                 fades to translucent so the game's first frame shows through,
##                 and a 3·2·1·GO count plays. Then [signal intro_finished] fires
##                 and the overlay frees itself, handing control back to the game.
##
## It's a reusable component (no per-game code): [MiniGame] instantiates
## scenes/ui/game_intro.tscn, so adding a game never touches this. The mirror is
## the shared [CameraMirror] component and the hold bar a [MeterBar]; the gesture
## comes from [MotionManager] — Godot itself does no vision (§9). With no pose
## service running the mirror is dark and the gesture never fires, so pressing the
## on-screen accept key (Space/Enter) skips straight to the count — the platform is
## always playable without a camera.
class_name GameIntro

## Emitted once, after "GO!", when the game should begin.
signal intro_finished

## How long the ready gesture must be held (seconds) before the count starts.
const HOLD_SEC: float = 1.0
## How quickly the hold bar drains when the gesture is dropped, relative to how
## fast it fills — a brief tracking flicker shouldn't wipe the player's progress.
const HOLD_DECAY_SCALE: float = 1.5
const START_FROM: int = 3
const TICK_SECONDS: float = 1.0

## Where the mirror settles during the count: the same top-right thumbnail rect
## GameCameraHUD then takes over, so the mirror appears to stay put.
const WEBCAM_CORNER_RECT: Rect2 = Rect2(1552, 48, 320, 240)
const DIM_COUNTDOWN_ALPHA: float = 0.35  # translucent: reveal the game behind

const ACCENT: Color = Color(1.0, 0.5, 0.14)
const TRACKING_COLOR: Color = Color(0.45, 0.9, 0.5)
const NO_SIGNAL_COLOR: Color = Color(1.0, 0.72, 0.3)

enum Phase { SETUP, COUNTDOWN }

@onready var _mirror: CameraMirror = %CameraMirror
@onready var _dim: ColorRect = %Dim
@onready var _get_ready: Label = %GetReadyLabel
@onready var _title: Label = %GameTitleLabel
@onready var _prompt: Label = %PromptLabel
@onready var _hold_meter: MeterBar = %HoldMeter
@onready var _count: Label = %CountLabel
@onready var _status: Label = %StatusLabel
@onready var _back_button: Button = %BackButton
@onready var _calibrate_button: Button = %CalibrateButton

var _phase: Phase = Phase.SETUP
var _hold: float = 0.0
var _remaining: int = START_FROM
## A private copy of the CornerButton stylebox, so accenting the calibrate button
## doesn't tint every other CornerButton in the project through the shared theme.
var _calibrate_style: StyleBoxFlat

func _ready() -> void:
	# Power the webcam on for the setup mirror. The camera is in-game only (dark in
	# menus); it stays on from here through play and MotionManager switches it back
	# off automatically on the next scene change (results/menu). No-op with no pose
	# service, so the platform stays playable keyboard-only.
	MotionManager.camera_on()
	_back_button.pressed.connect(_on_back_pressed)
	_calibrate_button.pressed.connect(_start_calibration)
	_calibrate_style = (_calibrate_button.get_theme_stylebox("normal") as StyleBoxFlat).duplicate()
	_calibrate_button.add_theme_stylebox_override("normal", _calibrate_style)

	var game: Dictionary = GameManager.get_game(GameManager.get_current_game_id())
	_title.text = String(game.get("title", "")).to_upper()
	_title.visible = not _title.text.is_empty()


func _process(delta: float) -> void:
	if _phase == Phase.SETUP:
		_update_setup(delta)


## Setup phase: coach the player into a valid, camera-verified stance, and only
## once the camera confirms they're fully framed AND holding the ready gesture,
## grow the hold bar toward the countdown.
func _update_setup(delta: float) -> void:
	_update_calibrate_button()
	# A calibration capture, if running, OWNS the setup screen: pause the ready
	# gesture and show the calibration coaching + progress on the same bar instead.
	var calib_state: String = MotionManager.get_calibration_state()
	if calib_state == "still" or calib_state == "squat":
		_hold = 0.0
		_hold_meter.set_fraction(MotionManager.get_calibration_progress(), ACCENT)
		_set_prompt(MotionManager.get_calibration_prompt(), TRACKING_COLOR)
		_set_status("Calibrating your body — hold steady", TRACKING_COLOR)
		return

	var streaming: bool = _mirror.is_live()
	# is_pose_ready() bundles the whole camera check: streaming, standing, legs in
	# view, upright, at a good distance — the same readiness the pose service coaches
	# with get_ready_hint(). Requiring it here means the game never starts until the
	# camera is genuinely set up for play.
	var ready: bool = MotionManager.is_pose_ready()
	var hands: bool = MotionManager.is_hands_up()

	# The hold only advances when you're correctly framed AND giving the gesture;
	# anything else drains it. With no camera nothing streams and is_pose_ready()
	# stays false, so the bar can't fill — Space is the escape hatch (_unhandled_input).
	if streaming and ready and hands:
		_hold = minf(HOLD_SEC, _hold + delta)
	else:
		_hold = maxf(0.0, _hold - delta * HOLD_DECAY_SCALE)
	_hold_meter.fraction = _hold / HOLD_SEC

	if _hold >= HOLD_SEC:
		_start_countdown()
		return

	_update_setup_labels(streaming, ready, hands)


## Keeps the prompt (big) and status (small) honest about what the player needs to
## do next: fix the camera, fix their stance, then raise their hands.
func _update_setup_labels(streaming: bool, ready: bool, hands: bool) -> void:
	# Camera troubles come first — no point coaching a stance we can't see. Space
	# always skips ahead so the platform stays playable with no camera.
	if not streaming:
		if MotionManager.is_camera_error():
			_set_prompt("CAMERA BLOCKED", NO_SIGNAL_COLOR)
			_set_status("Allow camera access in Windows Settings ▸ Privacy ▸ Camera  —  or press Space to play without it", NO_SIGNAL_COLOR)
		elif MotionManager.is_receiving():
			_set_prompt("STARTING CAMERA…", NO_SIGNAL_COLOR)
			_set_status("or press Space to skip", NO_SIGNAL_COLOR)
		else:
			_set_prompt("NO CAMERA", NO_SIGNAL_COLOR)
			_set_status("Start the pose service, or press Space to begin", NO_SIGNAL_COLOR)
		return

	# Camera is live. Coach the player into a valid stance before asking for the
	# gesture: the hint comes straight from the pose service's readiness check
	# (STEP INTO VIEW / SHOW YOUR LEGS / STAND UP / GET CLOSER / STEP BACK / …).
	if not ready:
		var hint: String = MotionManager.get_ready_hint()
		_set_prompt(hint if not hint.is_empty() else "GET IN FRAME", NO_SIGNAL_COLOR)
		_set_status("Get set for the camera  —  or press Space to skip", NO_SIGNAL_COLOR)
	elif hands:
		_set_prompt("HOLD IT…", TRACKING_COLOR)
		_set_status("Keep both hands up", TRACKING_COLOR)
	else:
		_set_prompt("RAISE BOTH HANDS TO START", Color(0.96, 0.97, 0.99))
		_set_status("You're all set  —  or press Space to skip", TRACKING_COLOR)


## Keeps the calibrate button honest: label reflects state, it's accented as a
## gentle recommendation when the profile hasn't calibrated, and it's disabled
## while a capture runs or when there's no camera to measure from.
func _update_calibrate_button() -> void:
	var active: bool = MotionManager.get_calibration_state() in ["still", "squat"]
	var calibrated: bool = ProfileManager.has_calibration()
	_calibrate_button.disabled = active or not _mirror.is_live()
	if active:
		_calibrate_button.text = "CALIBRATING…"
	elif calibrated:
		_calibrate_button.text = "RECALIBRATE (C)"
	else:
		_calibrate_button.text = "CALIBRATE (C)"
	_calibrate_style.border_color = \
		ACCENT if (not calibrated and not active) else Color(1, 1, 1, 0.16)


## Kicks off a body calibration in-place (camera is already on here). No-op with
## no live camera. MotionManager saves the result to the active profile.
func _start_calibration() -> void:
	if _phase != Phase.SETUP or not _mirror.is_live():
		return
	MotionManager.calibrate()


func _set_prompt(text: String, color: Color) -> void:
	_prompt.text = text
	_prompt.add_theme_color_override("font_color", color)


func _set_status(text: String, color: Color) -> void:
	_status.text = text
	_status.add_theme_color_override("font_color", color)


func _unhandled_input(event: InputEvent) -> void:
	# Escape backs all the way out to the main menu from either phase — the setup
	# mirror is the first thing a game shows, so a player who opened the wrong game
	# needs a way out before play begins. (Same as the on-screen MENU button.)
	if event.is_action_pressed("ui_cancel"):
		_on_back_pressed()
		get_viewport().set_input_as_handled()
		return
	# 'C' starts a body calibration during setup (a gentle recommendation, never
	# required). Raw keycode so it needs no input action.
	if _phase == Phase.SETUP and event is InputEventKey and event.pressed \
			and not event.echo and (event as InputEventKey).keycode == KEY_C:
		_start_calibration()
		get_viewport().set_input_as_handled()
		return
	# Keyboard escape hatch: works with no camera, and lets a tester skip ahead.
	if _phase == Phase.SETUP and event.is_action_pressed("ui_accept"):
		_start_countdown()
		get_viewport().set_input_as_handled()


## Leaves the game and returns to the main menu. Changing scene frees this overlay
## and the frozen game behind it; MotionManager powers the webcam back off on the
## scene change, so the LED goes dark just as it does from any other exit.
func _on_back_pressed() -> void:
	SceneManager.load_main_menu()


## Transition into the count: shrink the mirror to a corner, reveal the game
## behind a translucent dim, and hide the setup prompts.
func _start_countdown() -> void:
	if _phase != Phase.SETUP:
		return
	_phase = Phase.COUNTDOWN

	var tween := create_tween().set_parallel(true)
	tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(_mirror, "offset_left", WEBCAM_CORNER_RECT.position.x, 0.5)
	tween.tween_property(_mirror, "offset_top", WEBCAM_CORNER_RECT.position.y, 0.5)
	tween.tween_property(_mirror, "offset_right", WEBCAM_CORNER_RECT.end.x, 0.5)
	tween.tween_property(_mirror, "offset_bottom", WEBCAM_CORNER_RECT.end.y, 0.5)
	tween.tween_property(_dim, "color:a", DIM_COUNTDOWN_ALPHA, 0.5)
	for fading in [_get_ready, _prompt, _hold_meter, _status, _back_button, _calibrate_button]:
		tween.tween_property(fading, "modulate:a", 0.0, 0.25)
	# The count is about to start; the player has committed. Stop the buttons eating
	# clicks as they fade (Escape still backs out during the count).
	_back_button.disabled = true
	_calibrate_button.disabled = true

	_remaining = START_FROM
	_show_count(_remaining)
	var timer := Timer.new()
	timer.wait_time = TICK_SECONDS
	timer.autostart = true
	timer.timeout.connect(_on_tick)
	add_child(timer)


func _on_tick() -> void:
	_remaining -= 1
	if _remaining > 0:
		_show_count(_remaining)
	elif _remaining == 0:
		_count.text = "GO!"
		_count.add_theme_color_override("font_color", ACCENT)
		_pulse()
	else:
		intro_finished.emit()
		queue_free()


func _show_count(value: int) -> void:
	_count.visible = true
	_count.text = str(value)
	_pulse()


## One count beat: the number lands with a springy scale-down and a quick fade —
## big and rhythmic so it reads from across the room as the player sets their
## stance. (Matches the platform's original countdown feel.)
func _pulse() -> void:
	_count.pivot_offset = _count.size / 2.0
	_count.scale = Vector2(1.35, 1.35)
	_count.modulate.a = 0.0
	var tween := create_tween().set_parallel(true)
	tween.tween_property(_count, "scale", Vector2.ONE, 0.4) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(_count, "modulate:a", 1.0, 0.18)
