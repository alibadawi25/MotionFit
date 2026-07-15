extends CanvasLayer
## GameCameraHUD
##
## A persistent little camera window shown in the top-right corner during play, so
## the player can always see themselves the way the game sees them. It picks up
## right where [GameIntro]'s countdown thumbnail left off (same corner, same size),
## so the mirror feels continuous from setup into the game.
##
## Beyond a mirror, it coaches: when the pose service reports the player has
## drifted out of a good stance (stepped too close, legs out of frame, leaning),
## it surfaces that hint right under the thumbnail — [MotionManager.get_ready_hint]
## — so they can fix their framing mid-game without pausing, and keep tracking
## accurate. When everything's good it shows a calm "TRACKING" tick.
##
## It's a reusable component with no per-game code: [MiniGame] instantiates one
## after the intro, so every game gets the in-game camera for free. It reads the
## live picture from [CameraPreview] and readiness from [MotionManager]; Godot does
## no vision itself (§9). With no pose service running nothing streams, so the whole
## widget simply hides — the platform stays fully playable keyboard-only. Press C
## to hide/show it.
class_name GameCameraHUD

## Same corner rect the intro's countdown thumbnail settles into, so the mirror
## appears to stay put as the intro hands off to gameplay.
const CORNER_RECT: Rect2 = Rect2(1552, 48, 320, 240)

const ACCENT: Color = Color(1.0, 0.5, 0.14)
const TRACKING_COLOR: Color = Color(0.45, 0.9, 0.5)
const WARN_COLOR: Color = Color(1.0, 0.72, 0.3)
const LIVE_COLOR: Color = Color(1.0, 0.26, 0.26)
const PANEL_BG: Color = Color(0.03, 0.04, 0.06, 0.82)

var _root: Control
var _webcam: TextureRect
var _frame: Panel
var _live_dot: ColorRect
var _hint: Label
var _hint_panel: PanelContainer
var _hidden_by_user: bool = false

func _ready() -> void:
	layer = 50  # above the game's default-layer HUD, below the intro overlay (100)
	_build_ui()


func _build_ui() -> void:
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_webcam = TextureRect.new()
	_webcam.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_webcam.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_webcam.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_webcam.offset_left = CORNER_RECT.position.x
	_webcam.offset_top = CORNER_RECT.position.y
	_webcam.offset_right = CORNER_RECT.end.x
	_webcam.offset_bottom = CORNER_RECT.end.y
	_root.add_child(_webcam)

	# Rounded border around the thumbnail; greens while tracking is clean.
	_frame = Panel.new()
	_frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var frame_sb := StyleBoxFlat.new()
	frame_sb.bg_color = Color(0, 0, 0, 0)
	frame_sb.set_corner_radius_all(10)
	frame_sb.set_border_width_all(2)
	frame_sb.border_color = TRACKING_COLOR
	_frame.add_theme_stylebox_override("panel", frame_sb)
	_webcam.add_child(_frame)

	# A small LIVE ● badge, top-left of the thumbnail.
	var badge := PanelContainer.new()
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	badge.offset_left = 8.0
	badge.offset_top = 8.0
	var badge_sb := StyleBoxFlat.new()
	badge_sb.bg_color = PANEL_BG
	badge_sb.set_corner_radius_all(6)
	badge_sb.content_margin_left = 8.0
	badge_sb.content_margin_right = 10.0
	badge_sb.content_margin_top = 4.0
	badge_sb.content_margin_bottom = 4.0
	badge.add_theme_stylebox_override("panel", badge_sb)
	_webcam.add_child(badge)

	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 6)
	badge.add_child(row)

	_live_dot = ColorRect.new()
	_live_dot.color = LIVE_COLOR
	_live_dot.custom_minimum_size = Vector2(9, 9)
	_live_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_live_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_live_dot)

	var live := Label.new()
	live.text = "YOU"
	live.mouse_filter = Control.MOUSE_FILTER_IGNORE
	live.add_theme_font_size_override("font_size", 13)
	live.add_theme_color_override("font_color", Color(0.98, 0.98, 1.0))
	row.add_child(live)

	# Coaching line, pinned just under the thumbnail.
	_hint_panel = PanelContainer.new()
	_hint_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint_panel.offset_left = CORNER_RECT.position.x
	_hint_panel.offset_top = CORNER_RECT.end.y + 8.0
	_hint_panel.offset_right = CORNER_RECT.end.x
	_hint_panel.offset_bottom = CORNER_RECT.end.y + 44.0
	var hint_sb := StyleBoxFlat.new()
	hint_sb.bg_color = PANEL_BG
	hint_sb.set_corner_radius_all(8)
	hint_sb.content_margin_top = 6.0
	hint_sb.content_margin_bottom = 6.0
	_hint_panel.add_theme_stylebox_override("panel", hint_sb)
	_root.add_child(_hint_panel)

	_hint = Label.new()
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.add_theme_font_size_override("font_size", 17)
	_hint_panel.add_child(_hint)

	# Blink the dot so it reads as a live indicator.
	var blink := create_tween().set_loops()
	blink.tween_property(_live_dot, "modulate:a", 0.25, 0.6) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	blink.tween_property(_live_dot, "modulate:a", 1.0, 0.6) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func _process(_delta: float) -> void:
	var streaming: bool = CameraPreview.is_streaming()
	# Nothing to show without a live feed (keyboard-only play): hide the widget so
	# it never presents a dark rectangle claiming to be the camera.
	_root.visible = streaming and not _hidden_by_user
	if not _root.visible:
		return

	_webcam.texture = CameraPreview.get_texture()

	# Coach on the pose service's readiness: an amber fix when the stance drifts
	# (out of frame, too close, legs hidden), a calm green tick when it's clean.
	var hint: String = MotionManager.get_ready_hint()
	var frame_sb := _frame.get_theme_stylebox("panel") as StyleBoxFlat
	if not hint.is_empty():
		_hint.text = hint
		_hint.add_theme_color_override("font_color", WARN_COLOR)
		frame_sb.border_color = WARN_COLOR
	else:
		_hint.text = "✓  TRACKING"
		_hint.add_theme_color_override("font_color", TRACKING_COLOR)
		frame_sb.border_color = TRACKING_COLOR


## C toggles the mirror off/on, for players who'd rather not watch themselves. Uses
## a raw key check so it needs no project input action.
func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and key.keycode == KEY_C:
		_hidden_by_user = not _hidden_by_user
		get_viewport().set_input_as_handled()
