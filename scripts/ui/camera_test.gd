extends Control
## CameraTest
##
## A simple, player-facing "does my camera work?" screen, reachable from
## Settings. It turns the webcam on, shows the player a big live mirror of
## themselves, and lets them confirm — with no jargon — that the three body
## actions the games rely on are being detected:
##
##   • WALK IN PLACE  → step counter climbs
##   • JUMP           → jump counter climbs
##   • SQUAT / BOW DOWN → crouch/duck depth fills
##
## Each action has a card with a status "lamp": grey (not tried yet) → orange
## (detecting it right now) → green ✓ (it works!). A big banner says in plain words
## what the player is doing this instant, and a status pill says whether the camera
## itself is up. This is a health check, not a game: nothing is scored and there's
## no way to fail — the player just moves and watches the lamps go green.
##
## Like every other screen, it does NO computer vision (CONTEXT.md §9): it only
## reads the processed values from [MotionManager] and the live picture from
## [CameraPreview], exactly as [GameIntro] does. With no pose service running the
## mirror stays dark and the banner explains how to start it.
##
## The whole layout — mirror, banner, the three action cards — is authored in
## scenes/menus/camera_test.tscn at design-space 1920×1080 (canvas_items stretch,
## so absolute offsets scale cleanly). This script only recolours and relabels it.

const ACCENT: Color = Color(1.0, 0.5, 0.14)       # "detecting now" orange
const GREEN: Color = Color(0.45, 0.9, 0.5)        # "works!" green
const AMBER: Color = Color(1.0, 0.72, 0.3)        # camera-trouble warning
const TEXT: Color = Color(0.96, 0.97, 0.99)
const GRAY: Color = Color(0.6, 0.65, 0.72)
const CARD_BORDER: Color = Color(1, 1, 1, 0.12)
const LAMP_OFF: Color = Color(1, 1, 1, 0.18)

## Marching intensity above which we call it "moving" / light the steps lamp.
const MOVING_THRESHOLD: float = 0.12
## How long the "YOU JUMPED!" flash and the jump lamp stay lit after a jump.
const JUMP_FLASH_SEC: float = 0.9

@onready var _camera: TextureRect = %CameraMirror
@onready var _camera_frame: Panel = %MirrorFrame
@onready var _cam_pill: Label = %CameraStatusPill
@onready var _banner: Label = %BannerLabel
@onready var _hint: Label = %HintLabel
@onready var _back_button: Button = %BackButton

# Per-action card widgets, resolved once so _process stays readable.
@onready var _steps_sb: StyleBoxFlat = _card_style(%StepsCard)
@onready var _steps_lamp: StyleBoxFlat = _card_style(%StepsLamp)
@onready var _steps_value: Label = %StepsValue
@onready var _steps_status: Label = %StepsStatus

@onready var _jump_sb: StyleBoxFlat = _card_style(%JumpCard)
@onready var _jump_lamp: StyleBoxFlat = _card_style(%JumpLamp)
@onready var _jump_value: Label = %JumpValue
@onready var _jump_status: Label = %JumpStatus

@onready var _crouch_sb: StyleBoxFlat = _card_style(%CrouchCard)
@onready var _crouch_lamp: StyleBoxFlat = _card_style(%CrouchLamp)
@onready var _crouch_value: Label = %CrouchValue
@onready var _crouch_status: Label = %CrouchStatus

# "It worked at least once" latches — once green, they stay green so the player
# can see all three passed without having to hold every pose at the same time.
var _steps_ok: bool = false
var _jump_ok: bool = false
var _crouch_ok: bool = false

var _jump_count: int = 0
var _jump_flash: float = 0.0

func _ready() -> void:
	# Power the webcam on for the test (it's dark in menus); MotionManager turns it
	# back off automatically on the next scene change, so leaving returns to normal.
	MotionManager.camera_on()
	# Count steps from now, not since the service booted, so the on-screen tally is
	# what the player does on THIS screen.
	MotionManager.reset_session_stats()
	# Jumps are one-frame edge events — listen for them rather than poll.
	MotionManager.jumped.connect(_on_jump)
	_back_button.pressed.connect(_on_back_pressed)


## The scene-authored "panel" stylebox of [param node], which _process recolours
## in place. Each card and lamp owns its own instance in the scene so they light
## independently.
func _card_style(node: Control) -> StyleBoxFlat:
	return node.get_theme_stylebox("panel") as StyleBoxFlat


func _on_jump() -> void:
	_jump_count += 1
	_jump_flash = JUMP_FLASH_SEC
	_jump_ok = true


func _process(delta: float) -> void:
	_camera.texture = CameraPreview.get_texture()
	if _jump_flash > 0.0:
		_jump_flash -= delta

	var streaming: bool = CameraPreview.is_streaming()
	var pose_ready: bool = MotionManager.is_pose_ready()
	_update_camera_status(streaming)
	_update_cards(streaming, pose_ready)
	_update_banner(streaming, pose_ready)


## Greens the mirror frame and pill while a live picture is arriving; otherwise
## shows the reason the camera isn't up, in plain language.
func _update_camera_status(streaming: bool) -> void:
	var frame_sb := _card_style(_camera_frame)
	if streaming:
		frame_sb.border_color = GREEN
		_cam_pill.text = "●  CAMERA WORKING"
		_cam_pill.add_theme_color_override("font_color", GREEN)
	else:
		frame_sb.border_color = LAMP_OFF
		if MotionManager.is_camera_error():
			_cam_pill.text = "●  CAMERA BLOCKED"
		elif MotionManager.is_receiving():
			_cam_pill.text = "●  STARTING…"
		else:
			_cam_pill.text = "●  CAMERA OFF"
		_cam_pill.add_theme_color_override("font_color", AMBER)


## Drives the three action cards: grey until tried, orange while the action is
## happening now, green ✓ once it has been detected at least once.
func _update_cards(streaming: bool, pose_ready: bool) -> void:
	var live: bool = streaming and pose_ready

	# Steps: the session tally, lit while marching.
	var sess_steps: int = MotionManager.get_session_steps()
	if sess_steps > 0:
		_steps_ok = true
	var stepping: bool = live and MotionManager.get_forward() > MOVING_THRESHOLD
	_set_card(_steps_sb, _steps_lamp, _steps_status,
			_steps_ok, stepping, "%d steps" % sess_steps, _steps_value,
			"✓  Steps detected — it works!", "Detecting… keep marching",
			"Walk in place to test")

	# Jump: count of launches, lit briefly on each.
	var jumping: bool = _jump_flash > 0.0
	_set_card(_jump_sb, _jump_lamp, _jump_status,
			_jump_ok, jumping, "%d jumps" % _jump_count, _jump_value,
			"✓  Jump detected — it works!", "Nice — that's a jump!",
			"Jump up to test")

	# Crouch/duck: live depth as a percentage (whichever gesture reads deeper),
	# lit past either dead-zone — the runner slides on the lean-down bow, the
	# open world crouches on the squat, so this card covers both.
	var crouch: float = maxf(MotionManager.get_crouch(), MotionManager.get_duck())
	var crouching: bool = live and \
			(MotionManager.is_crouching() or MotionManager.is_ducking())
	if crouching:
		_crouch_ok = true
	_set_card(_crouch_sb, _crouch_lamp, _crouch_status,
			_crouch_ok, crouching, "%d%%" % int(round(crouch * 100.0)), _crouch_value,
			"✓  Detected — it works!", "Detecting… go a bit lower",
			"Squat or bow down to test")


## Applies one card's colour state. `done` (green ✓) wins over `active` (orange);
## otherwise the card sits grey with its "how to test" prompt.
func _set_card(sb: StyleBoxFlat, lamp: StyleBoxFlat, status: Label,
		done: bool, active: bool, value_text: String, value: Label,
		done_text: String, active_text: String, idle_text: String) -> void:
	value.text = value_text
	var color: Color
	var text: String
	if done:
		color = GREEN
		# Once passed, still acknowledge the live action so the card feels alive.
		text = active_text if active else done_text
	elif active:
		color = ACCENT
		text = active_text
	else:
		color = GRAY
		text = idle_text
	lamp.bg_color = LAMP_OFF if (not done and not active) else color
	sb.border_color = CARD_BORDER if (not done and not active) else color
	status.text = text
	status.add_theme_color_override("font_color", color)


## The big plain-language banner: camera problems first, then framing coaching,
## then a live read of the current action once the player is set up.
func _update_banner(streaming: bool, pose_ready: bool) -> void:
	if not streaming:
		if MotionManager.is_camera_error():
			_set_banner("CAMERA BLOCKED", AMBER,
				"Allow camera access in Windows Settings ▸ Privacy ▸ Camera")
		elif MotionManager.is_receiving():
			_set_banner("STARTING CAMERA…", AMBER, "One moment")
		else:
			# run.bat is the dev launcher; the shipped build starts the pose
			# service itself, so only surface that hint in the editor.
			var hint: String = "Start the camera service (run.bat), then come back" \
				if OS.has_feature("editor") else "The camera service is starting — one moment"
			_set_banner("CAMERA NOT RUNNING", AMBER, hint)
		return

	if not pose_ready:
		var hint: String = MotionManager.get_ready_hint()
		_set_banner("GET IN FRAME", AMBER,
			hint if not hint.is_empty() else "Stand back so your whole body is in view")
		return

	# Fully set up — say what they're doing right now.
	if _jump_flash > 0.0:
		_set_banner("YOU JUMPED!", GREEN, "Try walking or squatting too")
	elif MotionManager.is_crouching():
		_set_banner("YOU'RE SQUATTING", GREEN, "Stand back up when you're ready")
	elif MotionManager.is_ducking():
		_set_banner("YOU'RE DUCKING", GREEN, "That's the slide move — stand tall again")
	elif MotionManager.get_forward() > 0.45:
		_set_banner("YOU'RE MARCHING", GREEN, "Looking good — try a jump or a squat")
	elif MotionManager.get_forward() > MOVING_THRESHOLD:
		_set_banner("YOU'RE MOVING", GREEN, "March faster to speed up in game")
	else:
		_set_banner("STANDING STILL", TEXT, "Walk in place, jump, or squat to test")


func _set_banner(text: String, color: Color, hint: String) -> void:
	_banner.text = text
	_banner.add_theme_color_override("font_color", color)
	_hint.text = hint


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_on_back_pressed()
		get_viewport().set_input_as_handled()


func _on_back_pressed() -> void:
	SceneManager.load_main_menu()
