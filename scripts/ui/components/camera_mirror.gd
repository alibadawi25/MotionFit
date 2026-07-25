@tool
extends TextureRect
class_name CameraMirror
## CameraMirror
##
## The live webcam mirror with its chrome: a rounded viewport border that greens
## while frames are arriving, and a LIVE badge with a blinking dot. Every screen
## that shows the player back to themselves uses this — the game intro's
## full-screen setup mirror, the in-game corner thumbnail, the camera test and
## the calibration screen.
##
## It reads the picture from [CameraPreview] itself (Godot does no vision — §9,
## Python owns the camera), so a host screen only has to place it and read
## [method is_live]. The badge hides automatically when nothing is streaming, so
## the UI never claims "live" over a dark rectangle.

const TRACKING_COLOR: Color = Color(0.45, 0.9, 0.5)
const FRAME_OFF_COLOR: Color = Color(1, 1, 1, 0.14)

## Shows the "LIVE · YOUR CAMERA" badge in the corner of the mirror. Off for the
## small in-game thumbnail, which uses its own tighter badge text.
@export var show_badge: bool = true:
	set(v):
		show_badge = v
		if is_node_ready():
			_refresh_badge()

## Left-hand word of the badge — "LIVE" on the big setup mirror, "YOU" on the
## in-game corner thumbnail.
@export var badge_title: String = "LIVE":
	set(v):
		badge_title = v
		if is_node_ready():
			%BadgeTitle.text = v

## Right-hand half of the badge ("·  YOUR CAMERA"). Empty shows just the title.
@export var badge_subtitle: String = "·  YOUR CAMERA":
	set(v):
		badge_subtitle = v
		if is_node_ready():
			%BadgeSubtitle.text = v
			%BadgeSubtitle.visible = v != ""

## Shrinks the badge for the small corner thumbnail, where the full-size pill
## would crowd the picture.
@export var compact: bool = false:
	set(v):
		compact = v
		if is_node_ready():
			_apply_badge_scale()

## Border thickness of the viewport frame — 3 for the big setup mirror, 2 for
## the corner thumbnail.
@export var frame_width: int = 3:
	set(v):
		frame_width = v
		if is_node_ready():
			var sb := _frame_style()
			for side in ["border_width_left", "border_width_top",
					"border_width_right", "border_width_bottom"]:
				sb.set(side, v)

## Set false when the host screen drives the border colour itself (the camera
## test greens/dims it in step with its own status pill).
@export var auto_frame_color: bool = true

var _streaming: bool = false

func _ready() -> void:
	show_badge = show_badge
	badge_title = badge_title
	badge_subtitle = badge_subtitle
	compact = compact
	frame_width = frame_width
	if Engine.is_editor_hint():
		return
	# Blink the dot forever so the badge reads as a live/recording indicator.
	var dot: ColorRect = %LiveDot
	var blink := create_tween().set_loops()
	blink.tween_property(dot, "modulate:a", 0.2, 0.6) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	blink.tween_property(dot, "modulate:a", 1.0, 0.6) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func _process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	texture = CameraPreview.get_texture()
	_streaming = CameraPreview.is_streaming()
	_refresh_badge()
	if auto_frame_color:
		set_frame_color(TRACKING_COLOR if _streaming else FRAME_OFF_COLOR)


## Whether real frames are arriving right now — hosts gate their own coaching
## copy on this rather than polling CameraPreview a second time.
func is_live() -> bool:
	return _streaming


## Recolours the viewport border. Only meaningful with [member auto_frame_color]
## off; the camera test uses it to match its own green/amber status.
##
## Writes only on a real change: assigning border_color emits `changed` on the
## StyleBox whatever the value was, which queues a redraw of the panel. With
## auto_frame_color on this is called every frame from _process, so an
## unconditional write repainted the frame 60 times a second to keep it exactly
## the colour it already was. Same edge-triggering main_menu.gd uses for its
## hardware status lines.
func set_frame_color(color: Color) -> void:
	var style := _frame_style()
	if style.border_color != color:
		style.border_color = color


func _frame_style() -> StyleBoxFlat:
	return (%ViewportFrame as Panel).get_theme_stylebox("panel") as StyleBoxFlat


func _refresh_badge() -> void:
	(%LiveBadge as Control).visible = show_badge and (_streaming or Engine.is_editor_hint())


## Two sizes for the same badge: the roomy pill for the full-screen setup mirror,
## a tighter one for the 320×240 in-game thumbnail.
func _apply_badge_scale() -> void:
	var font_size: int = 13 if compact else 16
	var dot: float = 9.0 if compact else 12.0
	var pad := Vector2(8.0, 4.0) if compact else Vector2(12.0, 7.0)
	var gap: int = 6 if compact else 8
	var pill := (%LiveBadge as PanelContainer).get_theme_stylebox("panel") as StyleBoxFlat
	pill.content_margin_left = pad.x
	pill.content_margin_right = pad.x + 2.0
	pill.content_margin_top = pad.y
	pill.content_margin_bottom = pad.y
	pill.set_corner_radius_all(6 if compact else 8)
	(%LiveBadge as Control).offset_left = 8.0 if compact else 14.0
	(%LiveBadge as Control).offset_top = 8.0 if compact else 14.0
	(%BadgeRow as HBoxContainer).add_theme_constant_override("separation", gap)
	(%LiveDot as ColorRect).custom_minimum_size = Vector2(dot, dot)
	for label in [%BadgeTitle, %BadgeSubtitle]:
		(label as Label).add_theme_font_size_override("font_size", font_size)
