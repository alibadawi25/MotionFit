extends Control
## CalibrationSetup
##
## The (skippable) body-calibration step. Turns the camera on, shows the player a
## live mirror, and walks them through the ~10s capture the pose service runs:
## stand still, then one deep squat. The result is saved to the active profile by
## MotionManager, so crouch depth feels right for THIS person.
##
## Reached after onboarding a new profile and from the profile screen's
## "Recalibrate". Fully playable without a camera — Skip is always available and
## the platform stays keyboard-usable.
##
## The layout (mirror, prompts, progress bar, buttons) is authored in
## scenes/menus/calibration_setup.tscn; this script only drives their text,
## colour, width and visibility off the pose service's calibration phase.

const ACCENT := Color(1, 0.5, 0.14)
const OK_COLOR := Color(0.45, 0.9, 0.5)
const WARN_COLOR := Color(1, 0.72, 0.3)
# Hands-free start: hold both hands up this long (with the same forgiving decay as
# GameIntro) to begin the capture, so the player never has to walk back to the
# mouse after stepping into frame. Mirrors the "raise both hands to start" gesture
# every game already uses.
const HOLD_SEC := 1.0
const HOLD_DECAY_SCALE := 1.5

@onready var _mirror: TextureRect = %CameraMirror
@onready var _prompt: Label = %PromptLabel
@onready var _sub: Label = %SubPromptLabel
@onready var _bar_track: ColorRect = %ProgressTrack
@onready var _bar_fill: ColorRect = %ProgressFill
@onready var _start_button: Button = %StartButton
@onready var _skip_button: Button = %SkipButton
@onready var _continue_button: Button = %ContinueButton

# Seconds the "both hands up" gesture has been held while framed and ready.
var _hold: float = 0.0

func _ready() -> void:
	# Calibration needs the camera; it auto-switches back off on the next scene
	# change (MotionManager's scene hook), so leaving here is clean.
	MotionManager.camera_on()
	_skip_button.pressed.connect(_finish)
	_start_button.pressed.connect(func(): MotionManager.calibrate())
	_continue_button.pressed.connect(_finish)
	MotionManager.calibration_captured.connect(_on_captured)


func _process(delta: float) -> void:
	_mirror.texture = CameraPreview.get_texture()
	_update_hold(delta)
	_refresh()


## Hands-free start. While the player is framed and ready — but not already
## capturing — holding both hands above the head for HOLD_SEC begins calibration,
## so they can trigger it from where they're standing instead of returning to the
## mouse. The gesture also restarts a failed attempt. Decays when the hands drop.
func _update_hold(delta: float) -> void:
	if _can_start() and MotionManager.is_pose_ready() and MotionManager.is_hands_up():
		_hold = minf(HOLD_SEC, _hold + delta)
	else:
		_hold = maxf(0.0, _hold - delta * HOLD_DECAY_SCALE)
	if _hold >= HOLD_SEC:
		_hold = 0.0
		MotionManager.calibrate()


## True in the phases where a (re)start is allowed: idle, failed — but not mid-
## capture or once done.
func _can_start() -> bool:
	var state: String = MotionManager.get_calibration_state()
	return state != "still" and state != "squat" and state != "done"


## Drives the prompt / progress / buttons off the pose service's calibration
## phase, coaching the player at every step.
func _refresh() -> void:
	var state: String = MotionManager.get_calibration_state()
	var streaming: bool = CameraPreview.is_streaming()
	var active: bool = state == "still" or state == "squat"

	var ready: bool = streaming and MotionManager.is_pose_ready()

	_start_button.visible = not active and state != "done"
	_continue_button.visible = state == "done"
	# Skip stays available except mid-capture, so a wrong start isn't a trap.
	_skip_button.visible = not active
	# The bar shows capture progress mid-run, and doubles as the raise-hands hold
	# meter while the player is framed and ready to (re)start.
	_bar_track.visible = active or state == "done" or (ready and _can_start())

	if active:
		_set_prompt(MotionManager.get_calibration_prompt(), ACCENT)
		_set_sub("Hold steady…")
		_set_bar(MotionManager.get_calibration_progress(), ACCENT)
		return
	if state == "done":
		_set_prompt("CALIBRATED  ✓", OK_COLOR)
		_set_sub("Your crouch is tuned to you. You can recalibrate anytime from Profile.")
		_set_bar(1.0, OK_COLOR)
		return
	if state == "failed":
		_set_prompt("That squat was too shallow", WARN_COLOR)
		_set_sub("Raise both hands to try again, then squat a bit deeper.")
		_start_button.disabled = false
		_set_bar(_hold / HOLD_SEC, WARN_COLOR)
		return

	# Idle: coach toward a ready stance before the raise-hands start is possible.
	if not streaming:
		_set_prompt("Getting the camera ready…", WARN_COLOR)
		_set_sub("No camera? You can Skip and calibrate later.")
		_start_button.disabled = true
	elif not MotionManager.is_pose_ready():
		var hint: String = MotionManager.get_ready_hint()
		_set_prompt(hint if not hint.is_empty() else "Step back so I can see your whole body", WARN_COLOR)
		_set_sub("Stand where the camera frames you head-to-feet.")
		_start_button.disabled = true
	else:
		_set_prompt("Raise both hands to start", OK_COLOR)
		_set_sub("Then stand still and do one deep squat — about 10 seconds. (Or press Start.)")
		_start_button.disabled = false
		_set_bar(_hold / HOLD_SEC, ACCENT)


func _unhandled_input(event: InputEvent) -> void:
	# Keyboard escape hatch, matching GameIntro: Space/Enter also (re)starts, so the
	# screen stays fully usable without a camera or mouse.
	if event.is_action_pressed("ui_accept") and _can_start():
		MotionManager.calibrate()
		get_viewport().set_input_as_handled()


func _on_captured(_standing: float, _squat: float) -> void:
	# Persistence is handled by MotionManager; nothing to do but let _refresh show
	# the "done" state. (Hook kept for a future sound / confetti cue.)
	pass


func _finish() -> void:
	SceneManager.load_main_menu()


func _set_prompt(text: String, color: Color) -> void:
	_prompt.text = text
	_prompt.add_theme_color_override("font_color", color)


func _set_sub(text: String) -> void:
	_sub.text = text


## Fills the progress bar to [param value] (0..1) of the scene-authored track's
## width, so resizing the track in the editor just works.
func _set_bar(value: float, color: Color) -> void:
	_bar_fill.size.x = _bar_track.size.x * clampf(value, 0.0, 1.0)
	_bar_fill.size.y = _bar_track.size.y
	_bar_fill.color = color
