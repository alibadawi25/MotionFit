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

const ACCENT := Color(1, 0.5, 0.14)
const TITLE_COLOR := Color(0.96, 0.97, 0.99)
const OK_COLOR := Color(0.45, 0.9, 0.5)
const WARN_COLOR := Color(1, 0.72, 0.3)
const MIRROR_RECT := Rect2(600, 210, 720, 540)
const BAR_SIZE := Vector2(560, 12)

var _mirror: TextureRect
var _prompt: Label
var _sub: Label
var _bar_track: ColorRect
var _bar_fill: ColorRect
var _start_button: Button
var _skip_button: Button
var _continue_button: Button

func _ready() -> void:
	# Calibration needs the camera; it auto-switches back off on the next scene
	# change (MotionManager's scene hook), so leaving here is clean.
	MotionManager.camera_on()
	_build()
	MotionManager.calibration_captured.connect(_on_captured)


func _build() -> void:
	var theme_res: Theme = load("res://assets/ui/main_theme.tres")
	if theme_res != null:
		theme = theme_res

	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.03, 0.04, 0.07)
	add_child(bg)

	var accent := ColorRect.new()
	accent.color = ACCENT
	accent.position = Vector2(600, 120)
	accent.custom_minimum_size = Vector2(72, 6)
	accent.size = Vector2(72, 6)
	add_child(accent)

	var title := Label.new()
	title.position = Vector2(600, 136)
	title.add_theme_font_size_override("font_size", 40)
	title.add_theme_color_override("font_color", TITLE_COLOR)
	title.text = "CALIBRATE YOUR BODY"
	var anton: Font = load("res://assets/fonts/Anton-Regular.ttf")
	if anton != null:
		title.add_theme_font_override("font", anton)
	add_child(title)

	_mirror = TextureRect.new()
	_mirror.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_mirror.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_mirror.offset_left = MIRROR_RECT.position.x
	_mirror.offset_top = MIRROR_RECT.position.y
	_mirror.offset_right = MIRROR_RECT.end.x
	_mirror.offset_bottom = MIRROR_RECT.end.y
	add_child(_mirror)
	var frame := Panel.new()
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var frame_sb := StyleBoxFlat.new()
	frame_sb.bg_color = Color(0, 0, 0, 0)
	frame_sb.set_corner_radius_all(10)
	frame_sb.set_border_width_all(2)
	frame_sb.border_color = Color(1, 1, 1, 0.14)
	frame.add_theme_stylebox_override("panel", frame_sb)
	_mirror.add_child(frame)

	_prompt = Label.new()
	_prompt.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_prompt.offset_top = 772.0
	_prompt.offset_bottom = 812.0
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt.add_theme_font_size_override("font_size", 30)
	_prompt.add_theme_color_override("font_color", TITLE_COLOR)
	add_child(_prompt)

	_sub = Label.new()
	_sub.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_sub.offset_top = 814.0
	_sub.offset_bottom = 844.0
	_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_sub.add_theme_font_size_override("font_size", 18)
	_sub.add_theme_color_override("font_color", Color(0.78, 0.82, 0.88))
	add_child(_sub)

	_bar_track = ColorRect.new()
	_bar_track.color = Color(1, 1, 1, 0.12)
	_bar_track.size = BAR_SIZE
	_bar_track.position = Vector2((1920.0 - BAR_SIZE.x) * 0.5, 862.0)
	add_child(_bar_track)
	_bar_fill = ColorRect.new()
	_bar_fill.color = ACCENT
	_bar_fill.position = Vector2.ZERO
	_bar_fill.size = Vector2(0, BAR_SIZE.y)
	_bar_track.add_child(_bar_fill)

	# Buttons row, centred near the bottom.
	var row := HBoxContainer.new()
	row.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	row.offset_top = -120.0
	row.offset_bottom = -56.0
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 18)
	add_child(row)

	_skip_button = Button.new()
	_skip_button.text = "SKIP FOR NOW"
	_skip_button.custom_minimum_size = Vector2(200, 56)
	_skip_button.pressed.connect(_finish)
	row.add_child(_skip_button)

	_start_button = Button.new()
	_start_button.text = "START CALIBRATION"
	_start_button.custom_minimum_size = Vector2(280, 56)
	_start_button.theme_type_variation = &"PrimaryButton"
	_start_button.pressed.connect(func(): MotionManager.calibrate())
	row.add_child(_start_button)

	_continue_button = Button.new()
	_continue_button.text = "CONTINUE"
	_continue_button.custom_minimum_size = Vector2(280, 56)
	_continue_button.theme_type_variation = &"PrimaryButton"
	_continue_button.visible = false
	_continue_button.pressed.connect(_finish)
	row.add_child(_continue_button)


func _process(_delta: float) -> void:
	_mirror.texture = CameraPreview.get_texture()
	_refresh()


## Drives the prompt / progress / buttons off the pose service's calibration
## phase, coaching the player at every step.
func _refresh() -> void:
	var state: String = MotionManager.get_calibration_state()
	var streaming: bool = CameraPreview.is_streaming()
	var active: bool = state == "still" or state == "squat"

	_start_button.visible = not active and state != "done"
	_continue_button.visible = state == "done"
	# Skip stays available except mid-capture, so a wrong start isn't a trap.
	_skip_button.visible = not active
	_bar_track.visible = active or state == "done"

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
		_set_sub("Press Start and squat a bit deeper this time.")
		_start_button.disabled = false
		return

	# Idle: coach toward a ready stance before enabling Start.
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
		_set_prompt("Ready!  Press Start, then stand still", OK_COLOR)
		_set_sub("You'll stand still, then do one deep squat — about 10 seconds.")
		_start_button.disabled = false


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


func _set_bar(value: float, color: Color) -> void:
	_bar_fill.size.x = BAR_SIZE.x * clampf(value, 0.0, 1.0)
	_bar_fill.color = color
