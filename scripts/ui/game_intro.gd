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
## It's a reusable component (no per-game code): [MiniGame] instantiates one, so
## adding a game never touches this. It reads the live mirror from [CameraPreview]
## and the ready gesture from [MotionManager] — Godot itself does no vision (§9).
## With no pose service running the mirror is dark and the gesture never fires, so
## pressing the on-screen accept key (Space/Enter) skips straight to the count —
## the platform is always playable without a camera.
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

## Design-space geometry (the project renders at a fixed 1920×1080 with
## canvas_items stretch, so absolute coordinates scale cleanly).
const WEBCAM_SETUP_RECT: Rect2 = Rect2(480, 180, 960, 720)      # centred, 4:3
const WEBCAM_CORNER_RECT: Rect2 = Rect2(1552, 48, 320, 240)     # top-right thumb
const DIM_SETUP_ALPHA: float = 1.0    # opaque: setup is about you, not the game
const DIM_COUNTDOWN_ALPHA: float = 0.35  # translucent: reveal the game behind

const ACCENT: Color = Color(1.0, 0.5, 0.14)
const DIM_COLOR: Color = Color(0.02, 0.03, 0.06)
const TRACKING_COLOR: Color = Color(0.45, 0.9, 0.5)
const NO_SIGNAL_COLOR: Color = Color(1.0, 0.72, 0.3)
const HOLD_TRACK_SIZE: Vector2 = Vector2(600, 10)
## The "recording" red used by the LIVE badge's blinking dot.
const LIVE_COLOR: Color = Color(1.0, 0.26, 0.26)
## Frame colour when the feed is quiet (no live picture to frame).
const FRAME_OFF_COLOR: Color = Color(1, 1, 1, 0.14)

enum Phase { SETUP, COUNTDOWN }

var _phase: Phase = Phase.SETUP
var _hold: float = 0.0
var _remaining: int = START_FROM

var _webcam: TextureRect
var _webcam_frame: Panel
var _live_badge: Control
var _live_dot: ColorRect
var _dim: ColorRect
var _get_ready: Label
var _title: Label
var _prompt: Label
var _hold_track: ColorRect
var _hold_fill: ColorRect
var _count: Label
var _status: Label
var _back_button: Button
var _calibrate_button: Button

func _ready() -> void:
	layer = 100  # above any game HUD (which lives on the default layer)
	# Power the webcam on for the setup mirror. The camera is in-game only (dark in
	# menus); it stays on from here through play and MotionManager switches it back
	# off automatically on the next scene change (results/menu). No-op with no pose
	# service, so the platform stays playable keyboard-only.
	MotionManager.camera_on()
	_build_ui()
	_show_setup()


func _build_ui() -> void:
	var theme_res: Theme = load("res://assets/ui/main_theme.tres")
	var anton: Font = load("res://assets/fonts/Anton-Regular.ttf")

	# A themed root Control gives every label the platform's font by default;
	# display text (title, count) overrides to the big Anton face.
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = theme_res
	add_child(root)

	_dim = ColorRect.new()
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dim.color = Color(DIM_COLOR.r, DIM_COLOR.g, DIM_COLOR.b, DIM_SETUP_ALPHA)
	_dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_dim)

	_webcam = TextureRect.new()
	_webcam.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_webcam.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_webcam.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_apply_rect(_webcam, WEBCAM_SETUP_RECT)
	root.add_child(_webcam)
	_build_camera_chrome()

	_get_ready = Label.new()
	_get_ready.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_get_ready.offset_top = 60.0
	_get_ready.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_get_ready.add_theme_color_override("font_color", Color(1, 0.64, 0.3, 1))
	_get_ready.add_theme_font_size_override("font_size", 24)
	_get_ready.text = "GET READY"
	root.add_child(_get_ready)

	_title = Label.new()
	_title.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_title.offset_top = 92.0
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_override("font", anton)
	_title.add_theme_font_size_override("font_size", 58)
	_title.add_theme_color_override("font_color", Color(0.96, 0.97, 0.99))
	root.add_child(_title)

	# The 3·2·1·GO number, centred and hidden until the count begins.
	_count = Label.new()
	_count.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_count.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_count.add_theme_font_override("font", anton)
	_count.add_theme_font_size_override("font_size", 230)
	_count.add_theme_color_override("font_color", Color(0.96, 0.97, 0.99))
	_count.add_theme_constant_override("shadow_offset_x", 3)
	_count.add_theme_constant_override("shadow_offset_y", 6)
	_count.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.5))
	_count.visible = false
	root.add_child(_count)

	_prompt = Label.new()
	_prompt.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_prompt.offset_top = -260.0
	_prompt.offset_bottom = -200.0
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt.add_theme_font_size_override("font_size", 34)
	_prompt.add_theme_color_override("font_color", Color(0.96, 0.97, 0.99))
	root.add_child(_prompt)

	# Hold-progress bar: a dark track with an accent fill whose width tracks how
	# long the ready gesture has been held.
	_hold_track = ColorRect.new()
	_hold_track.color = Color(1, 1, 1, 0.12)
	_hold_track.custom_minimum_size = HOLD_TRACK_SIZE
	_hold_track.size = HOLD_TRACK_SIZE
	_hold_track.position = Vector2((1920.0 - HOLD_TRACK_SIZE.x) * 0.5, 900.0)
	_hold_track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_hold_track)

	_hold_fill = ColorRect.new()
	_hold_fill.color = ACCENT
	_hold_fill.position = Vector2.ZERO
	_hold_fill.size = Vector2(0.0, HOLD_TRACK_SIZE.y)
	_hold_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hold_track.add_child(_hold_fill)

	_status = Label.new()
	_status.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_status.offset_top = -70.0
	_status.offset_bottom = -34.0
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status.add_theme_font_size_override("font_size", 20)
	root.add_child(_status)

	# Escape hatch back to the menu — this setup screen is the first thing a player
	# sees when a game loads, so it needs a clear way out (also bound to Escape in
	# _unhandled_input). A real Button (unlike the ignore-mouse overlays above) so
	# it's clickable.
	_back_button = Button.new()
	_back_button.text = "◄  MENU"
	_back_button.focus_mode = Control.FOCUS_NONE
	_back_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_back_button.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_back_button.offset_left = 48.0
	_back_button.offset_top = 44.0
	_back_button.offset_right = 214.0
	_back_button.offset_bottom = 96.0
	_back_button.add_theme_font_size_override("font_size", 20)
	var back_sb := StyleBoxFlat.new()
	back_sb.bg_color = Color(0.06, 0.08, 0.12, 0.82)
	back_sb.set_corner_radius_all(10)
	back_sb.set_border_width_all(1)
	back_sb.border_color = Color(1, 1, 1, 0.16)
	var back_hover := back_sb.duplicate()
	back_hover.bg_color = Color(0.12, 0.15, 0.22, 0.95)
	back_hover.border_color = ACCENT
	_back_button.add_theme_stylebox_override("normal", back_sb)
	_back_button.add_theme_stylebox_override("hover", back_hover)
	_back_button.add_theme_stylebox_override("pressed", back_hover)
	_back_button.pressed.connect(_on_back_pressed)
	root.add_child(_back_button)

	# Calibrate affordance, mirrored top-right: a gentle, non-blocking way to tune
	# crouch depth to your body. Accented when the active profile hasn't calibrated
	# yet (a recommendation, never a gate — you can always just raise your hands).
	_calibrate_button = Button.new()
	_calibrate_button.focus_mode = Control.FOCUS_NONE
	_calibrate_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_calibrate_button.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_calibrate_button.offset_left = -320.0
	_calibrate_button.offset_top = 44.0
	_calibrate_button.offset_right = -48.0
	_calibrate_button.offset_bottom = 96.0
	_calibrate_button.add_theme_font_size_override("font_size", 20)
	var cal_sb := back_sb.duplicate()
	var cal_hover := back_hover.duplicate()
	_calibrate_button.add_theme_stylebox_override("normal", cal_sb)
	_calibrate_button.add_theme_stylebox_override("hover", cal_hover)
	_calibrate_button.add_theme_stylebox_override("pressed", cal_hover)
	_calibrate_button.pressed.connect(_start_calibration)
	root.add_child(_calibrate_button)


## Builds the "this is your live camera" chrome that frames the webcam mirror: a
## rounded viewport border and a blinking LIVE ● YOUR CAMERA badge. Both are
## children of the webcam TextureRect, so they ride along when it tweens to the
## corner thumbnail during the countdown. Visibility/colour are driven each frame
## from [method _update_camera_chrome] based on whether a live picture is arriving.
func _build_camera_chrome() -> void:
	_webcam_frame = Panel.new()
	_webcam_frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_webcam_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var frame_sb := StyleBoxFlat.new()
	frame_sb.bg_color = Color(0, 0, 0, 0)  # transparent: the webcam shows through
	frame_sb.set_corner_radius_all(10)
	frame_sb.set_border_width_all(3)
	frame_sb.border_color = FRAME_OFF_COLOR
	_webcam_frame.add_theme_stylebox_override("panel", frame_sb)
	_webcam.add_child(_webcam_frame)

	# LIVE badge, pinned to the webcam's top-left corner: a dark pill holding a
	# blinking red dot, "LIVE", and "YOUR CAMERA".
	_live_badge = PanelContainer.new()
	_live_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_live_badge.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_live_badge.offset_left = 14.0
	_live_badge.offset_top = 14.0
	var badge_sb := StyleBoxFlat.new()
	badge_sb.bg_color = Color(0.02, 0.03, 0.05, 0.78)
	badge_sb.set_corner_radius_all(8)
	badge_sb.content_margin_left = 12.0
	badge_sb.content_margin_right = 14.0
	badge_sb.content_margin_top = 7.0
	badge_sb.content_margin_bottom = 7.0
	_live_badge.add_theme_stylebox_override("panel", badge_sb)
	_webcam.add_child(_live_badge)

	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 8)
	_live_badge.add_child(row)

	_live_dot = ColorRect.new()
	_live_dot.color = LIVE_COLOR
	_live_dot.custom_minimum_size = Vector2(12, 12)
	_live_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_live_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_live_dot)

	var live := Label.new()
	live.text = "LIVE"
	live.mouse_filter = Control.MOUSE_FILTER_IGNORE
	live.add_theme_font_size_override("font_size", 16)
	live.add_theme_color_override("font_color", Color(0.98, 0.98, 1.0))
	row.add_child(live)

	var who := Label.new()
	who.text = "·  YOUR CAMERA"
	who.mouse_filter = Control.MOUSE_FILTER_IGNORE
	who.add_theme_font_size_override("font_size", 16)
	who.add_theme_color_override("font_color", Color(0.75, 0.79, 0.85))
	row.add_child(who)

	# Blink the dot forever so the badge reads as a live/recording indicator.
	var blink := create_tween().set_loops()
	blink.tween_property(_live_dot, "modulate:a", 0.2, 0.6) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	blink.tween_property(_live_dot, "modulate:a", 1.0, 0.6) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func _show_setup() -> void:
	var game: Dictionary = GameManager.get_game(GameManager.get_current_game_id())
	_title.text = String(game.get("title", "")).to_upper()
	_title.visible = not _title.text.is_empty()


func _process(delta: float) -> void:
	# Keep the mirror live in both phases (full-screen, then corner thumbnail).
	_webcam.texture = CameraPreview.get_texture()
	_update_camera_chrome()
	if _phase == Phase.SETUP:
		_update_setup(delta)


## Shows the LIVE badge and greens the viewport frame only while real frames are
## arriving; when the feed is quiet the badge hides and the frame dims, so the UI
## never claims "live" over a dark rectangle.
func _update_camera_chrome() -> void:
	var streaming: bool = CameraPreview.is_streaming()
	_live_badge.visible = streaming
	var frame_sb := _webcam_frame.get_theme_stylebox("panel") as StyleBoxFlat
	frame_sb.border_color = TRACKING_COLOR if streaming else FRAME_OFF_COLOR


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
		_hold_fill.size.x = HOLD_TRACK_SIZE.x * MotionManager.get_calibration_progress()
		_set_prompt(MotionManager.get_calibration_prompt(), TRACKING_COLOR)
		_set_status("Calibrating your body — hold steady", TRACKING_COLOR)
		return

	var streaming: bool = CameraPreview.is_streaming()
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
	_hold_fill.size.x = HOLD_TRACK_SIZE.x * (_hold / HOLD_SEC)

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
	if _calibrate_button == null:
		return
	var active: bool = MotionManager.get_calibration_state() in ["still", "squat"]
	var calibrated: bool = ProfileManager.has_calibration()
	_calibrate_button.disabled = active or not CameraPreview.is_streaming()
	if active:
		_calibrate_button.text = "CALIBRATING…"
	elif calibrated:
		_calibrate_button.text = "RECALIBRATE (C)"
	else:
		_calibrate_button.text = "CALIBRATE (C)"
	var sb := _calibrate_button.get_theme_stylebox("normal") as StyleBoxFlat
	if sb != null:
		sb.border_color = ACCENT if (not calibrated and not active) else Color(1, 1, 1, 0.16)


## Kicks off a body calibration in-place (camera is already on here). No-op with
## no live camera. MotionManager saves the result to the active profile.
func _start_calibration() -> void:
	if _phase != Phase.SETUP or not CameraPreview.is_streaming():
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
	tween.tween_property(_webcam, "offset_left", WEBCAM_CORNER_RECT.position.x, 0.5)
	tween.tween_property(_webcam, "offset_top", WEBCAM_CORNER_RECT.position.y, 0.5)
	tween.tween_property(_webcam, "offset_right", WEBCAM_CORNER_RECT.end.x, 0.5)
	tween.tween_property(_webcam, "offset_bottom", WEBCAM_CORNER_RECT.end.y, 0.5)
	tween.tween_property(_dim, "color:a", DIM_COUNTDOWN_ALPHA, 0.5)
	tween.tween_property(_get_ready, "modulate:a", 0.0, 0.25)
	tween.tween_property(_prompt, "modulate:a", 0.0, 0.25)
	tween.tween_property(_hold_track, "modulate:a", 0.0, 0.25)
	tween.tween_property(_status, "modulate:a", 0.0, 0.25)
	tween.tween_property(_back_button, "modulate:a", 0.0, 0.25)
	tween.tween_property(_calibrate_button, "modulate:a", 0.0, 0.25)
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


## Positions a Control at an absolute design-space rect via its offsets (its
## anchors are left at the top-left preset so the offsets are literal pixels).
func _apply_rect(control: Control, rect: Rect2) -> void:
	control.offset_left = rect.position.x
	control.offset_top = rect.position.y
	control.offset_right = rect.end.x
	control.offset_bottom = rect.end.y
