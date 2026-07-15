extends Control
## CameraTest
##
## A simple, player-facing "does my camera work?" screen, reachable from the main
## menu. It turns the webcam on, shows the player a big live mirror of themselves,
## and lets them confirm — with no jargon — that the three body actions the games
## rely on are being detected:
##
##   • WALK IN PLACE  → step counter climbs
##   • JUMP           → jump counter climbs
##   • SQUAT / CROUCH → crouch depth fills
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

const ACCENT: Color = Color(1.0, 0.5, 0.14)       # "detecting now" orange
const GREEN: Color = Color(0.45, 0.9, 0.5)        # "works!" green
const AMBER: Color = Color(1.0, 0.72, 0.3)        # camera-trouble warning
const TEXT: Color = Color(0.96, 0.97, 0.99)
const GRAY: Color = Color(0.6, 0.65, 0.72)
const CARD_BG: Color = Color(0.06, 0.08, 0.12, 0.9)
const CARD_BORDER: Color = Color(1, 1, 1, 0.12)
const LAMP_OFF: Color = Color(1, 1, 1, 0.18)

## Design-space geometry (fixed 1920×1080, canvas_items stretch — absolute
## coordinates scale cleanly, same convention as [GameIntro]).
const CAMERA_RECT: Rect2 = Rect2(96, 220, 940, 705)   # 4:3 live mirror, left side
## Marching intensity above which we call it "moving" / light the steps lamp.
const MOVING_THRESHOLD: float = 0.12
## How long the "YOU JUMPED!" flash and the jump lamp stay lit after a jump.
const JUMP_FLASH_SEC: float = 0.9

var _anton: Font

var _camera: TextureRect
var _camera_frame: Panel
var _cam_pill: Label
var _banner: Label
var _hint: Label

# Per-action card widgets, kept typed so _process stays readable.
var _steps_sb: StyleBoxFlat
var _steps_lamp: StyleBoxFlat
var _steps_value: Label
var _steps_status: Label

var _jump_sb: StyleBoxFlat
var _jump_lamp: StyleBoxFlat
var _jump_value: Label
var _jump_status: Label

var _crouch_sb: StyleBoxFlat
var _crouch_lamp: StyleBoxFlat
var _crouch_value: Label
var _crouch_status: Label

# "It worked at least once" latches — once green, they stay green so the player
# can see all three passed without having to hold every pose at the same time.
var _steps_ok: bool = false
var _jump_ok: bool = false
var _crouch_ok: bool = false

var _jump_count: int = 0
var _jump_flash: float = 0.0

func _ready() -> void:
	_anton = load("res://assets/fonts/Anton-Regular.ttf")
	# Power the webcam on for the test (it's dark in menus); MotionManager turns it
	# back off automatically on the next scene change, so leaving returns to normal.
	MotionManager.camera_on()
	# Count steps from now, not since the service booted, so the on-screen tally is
	# what the player does on THIS screen.
	MotionManager.reset_session_stats()
	# Jumps are one-frame edge events — listen for them rather than poll.
	MotionManager.jumped.connect(_on_jump)
	_build_ui()


func _build_ui() -> void:
	# --- Header -------------------------------------------------------------
	var title := Label.new()
	title.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	title.offset_top = 56.0
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_override("font", _anton)
	title.add_theme_font_size_override("font_size", 62)
	title.add_theme_color_override("font_color", TEXT)
	title.text = "CAMERA TEST"
	add_child(title)

	var subtitle := Label.new()
	subtitle.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	subtitle.offset_top = 134.0
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 24)
	subtitle.add_theme_color_override("font_color", Color(1, 0.64, 0.3))
	subtitle.text = "Move in front of the camera and watch each action turn green"
	add_child(subtitle)

	# --- Live camera mirror -------------------------------------------------
	_camera = TextureRect.new()
	_camera.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_camera.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_camera.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_apply_rect(_camera, CAMERA_RECT)
	add_child(_camera)

	_camera_frame = Panel.new()
	_camera_frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_camera_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var frame_sb := StyleBoxFlat.new()
	frame_sb.bg_color = Color(0, 0, 0, 0)
	frame_sb.set_corner_radius_all(12)
	frame_sb.set_border_width_all(3)
	frame_sb.border_color = LAMP_OFF
	_camera_frame.add_theme_stylebox_override("panel", frame_sb)
	_camera.add_child(_camera_frame)

	# "Camera working" pill, pinned to the top-left of the mirror.
	_cam_pill = Label.new()
	_cam_pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cam_pill.position = Vector2(14, 14)
	_cam_pill.add_theme_font_size_override("font_size", 20)
	var pill_sb := StyleBoxFlat.new()
	pill_sb.bg_color = Color(0.02, 0.03, 0.05, 0.8)
	pill_sb.set_corner_radius_all(8)
	pill_sb.content_margin_left = 12.0
	pill_sb.content_margin_right = 12.0
	pill_sb.content_margin_top = 6.0
	pill_sb.content_margin_bottom = 6.0
	_cam_pill.add_theme_stylebox_override("normal", pill_sb)
	_camera.add_child(_cam_pill)

	# --- Live "what you're doing" banner + hint (under the camera) ----------
	_banner = Label.new()
	_apply_rect(_banner, Rect2(CAMERA_RECT.position.x, 936, CAMERA_RECT.size.x, 62))
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_banner.add_theme_font_override("font", _anton)
	_banner.add_theme_font_size_override("font_size", 40)
	_banner.add_theme_color_override("font_color", TEXT)
	add_child(_banner)

	_hint = Label.new()
	_apply_rect(_hint, Rect2(CAMERA_RECT.position.x, 1002, CAMERA_RECT.size.x, 34))
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.add_theme_font_size_override("font_size", 20)
	_hint.add_theme_color_override("font_color", GRAY)
	add_child(_hint)

	# --- Action cards (right column) ----------------------------------------
	var cards := VBoxContainer.new()
	cards.add_theme_constant_override("separation", 26)
	_apply_rect(cards, Rect2(1092, 220, 732, 705))
	add_child(cards)

	var steps_card := _make_card("WALK IN PLACE", "Walk in place to test")
	cards.add_child(steps_card["panel"])
	_steps_sb = steps_card["sb"]
	_steps_lamp = steps_card["lamp"]
	_steps_value = steps_card["value"]
	_steps_status = steps_card["status"]

	var jump_card := _make_card("JUMP", "Jump up to test")
	cards.add_child(jump_card["panel"])
	_jump_sb = jump_card["sb"]
	_jump_lamp = jump_card["lamp"]
	_jump_value = jump_card["value"]
	_jump_status = jump_card["status"]

	var crouch_card := _make_card("SQUAT DOWN", "Squat down to test")
	cards.add_child(crouch_card["panel"])
	_crouch_sb = crouch_card["sb"]
	_crouch_lamp = crouch_card["lamp"]
	_crouch_value = crouch_card["value"]
	_crouch_status = crouch_card["status"]

	# --- Back to menu -------------------------------------------------------
	var back := Button.new()
	back.text = "◄  MENU"
	back.focus_mode = Control.FOCUS_NONE
	back.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	back.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	back.offset_left = 48.0
	back.offset_top = 44.0
	back.offset_right = 214.0
	back.offset_bottom = 96.0
	back.add_theme_font_size_override("font_size", 20)
	var back_sb := StyleBoxFlat.new()
	back_sb.bg_color = Color(0.06, 0.08, 0.12, 0.82)
	back_sb.set_corner_radius_all(10)
	back_sb.set_border_width_all(1)
	back_sb.border_color = Color(1, 1, 1, 0.16)
	var back_hover := back_sb.duplicate()
	back_hover.bg_color = Color(0.12, 0.15, 0.22, 0.95)
	back_hover.border_color = ACCENT
	back.add_theme_stylebox_override("normal", back_sb)
	back.add_theme_stylebox_override("hover", back_hover)
	back.add_theme_stylebox_override("pressed", back_hover)
	back.pressed.connect(_on_back_pressed)
	add_child(back)


## Builds one action card: a bordered panel with a round status lamp on the left
## and a title / big value / status line on the right. Returns the pieces
## _process recolours each frame. (Dictionary rather than out-params — GDScript
## has no by-reference returns; the caller casts the handful it keeps.)
func _make_card(title_text: String, todo: String) -> Dictionary:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(0, 200)
	var sb := StyleBoxFlat.new()
	sb.bg_color = CARD_BG
	sb.set_corner_radius_all(14)
	sb.set_border_width_all(2)
	sb.border_color = CARD_BORDER
	sb.content_margin_left = 24.0
	sb.content_margin_right = 24.0
	sb.content_margin_top = 20.0
	sb.content_margin_bottom = 20.0
	panel.add_theme_stylebox_override("panel", sb)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 20)
	panel.add_child(row)

	var lamp := Panel.new()
	lamp.custom_minimum_size = Vector2(36, 36)
	lamp.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var lamp_sb := StyleBoxFlat.new()
	lamp_sb.bg_color = LAMP_OFF
	lamp_sb.set_corner_radius_all(18)
	lamp.add_theme_stylebox_override("panel", lamp_sb)
	row.add_child(lamp)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(col)

	var title := Label.new()
	title.text = title_text
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", TEXT)
	col.add_child(title)

	var value := Label.new()
	value.text = "0"
	value.add_theme_font_override("font", _anton)
	value.add_theme_font_size_override("font_size", 46)
	value.add_theme_color_override("font_color", TEXT)
	col.add_child(value)

	var status := Label.new()
	status.text = todo
	status.add_theme_font_size_override("font_size", 20)
	status.add_theme_color_override("font_color", GRAY)
	col.add_child(status)

	return {"panel": panel, "sb": sb, "lamp": lamp_sb, "value": value, "status": status}


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
	var frame_sb := _camera_frame.get_theme_stylebox("panel") as StyleBoxFlat
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

	# Crouch: live depth as a percentage, lit past the crouch dead-zone.
	var crouch: float = MotionManager.get_crouch()
	var crouching: bool = live and MotionManager.is_crouching()
	if crouching:
		_crouch_ok = true
	_set_card(_crouch_sb, _crouch_lamp, _crouch_status,
			_crouch_ok, crouching, "%d%%" % int(round(crouch * 100.0)), _crouch_value,
			"✓  Squat detected — it works!", "Detecting… go a bit lower",
			"Squat down to test")


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
			_set_banner("CAMERA NOT RUNNING", AMBER,
				"Start the camera service (run.bat), then come back")
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


## Positions a Control at an absolute design-space rect via its offsets (anchors
## left at the top-left preset, so the offsets are literal 1920×1080 pixels).
func _apply_rect(control: Control, rect: Rect2) -> void:
	control.offset_left = rect.position.x
	control.offset_top = rect.position.y
	control.offset_right = rect.end.x
	control.offset_bottom = rect.end.y
