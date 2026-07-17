extends CanvasLayer
## OpenWorldHud
##
## The Open World game's on-screen stats: a centred row of dark chips
## (TIME · CALORIES · STEPS · ORBS) over a subtle bottom hint. Built in code so it
## matches the shared menu look (dark chips, orange accent) without a paired
## scene. It owns no game state — the game feeds it live numbers via
## [method set_stats] and asks for the pickup pop via [method pulse_orbs].
class_name OpenWorldHud

const ACCENT: Color = Color(1.0, 0.5, 0.14)
const TEXT: Color = Color(0.96, 0.97, 0.99)
const MUTED: Color = Color(0.72, 0.76, 0.82)

## Maps a stat key ("time"/"calories"/"steps"/"orbs") to its value Label so
## [method set_stats] can refresh each chip without rebuilding the bar.
var _values: Dictionary = {}
var _anton: Font


func _ready() -> void:
	_anton = load("res://assets/fonts/Anton-Regular.ttf")
	_build()


## Lays out the top stat bar (a centred row of chips) and a subtle bottom hint.
func _build() -> void:
	var bar := HBoxContainer.new()
	bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	bar.offset_top = 22.0
	bar.offset_bottom = 118.0  # a real height so the container lays chips out
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	bar.add_theme_constant_override("separation", 12)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bar)

	bar.add_child(_make_chip("time", "TIME", TEXT))
	bar.add_child(_make_chip("calories", "CALORIES", ACCENT))
	bar.add_child(_make_chip("steps", "STEPS", TEXT))
	bar.add_child(_make_chip("orbs", "ORBS", ACCENT))

	var hint := Label.new()
	hint.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	hint.offset_bottom = -22.0
	hint.offset_top = -52.0
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 16)
	hint.add_theme_color_override("font_color", Color(0.82, 0.85, 0.9, 0.62))
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint.text = "ESC — PAUSE  /  END & SAVE"
	add_child(hint)


## One HUD chip: a small caps caption over a large branded value, on a dark
## rounded card. Registers its value Label under [param key] for live updates.
func _make_chip(key: String, caption: String, color: Color) -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(132, 0)
	panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER  # snug height, centred in the bar
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.08, 0.12, 0.72)
	sb.set_corner_radius_all(14)
	sb.set_border_width_all(1)
	sb.border_color = Color(1, 1, 1, 0.09)
	sb.content_margin_left = 20
	sb.content_margin_right = 20
	sb.content_margin_top = 10
	sb.content_margin_bottom = 12
	sb.shadow_color = Color(0, 0, 0, 0.3)
	sb.shadow_size = 10
	panel.add_theme_stylebox_override("panel", sb)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 0)
	panel.add_child(vbox)

	var cap := Label.new()
	cap.text = caption
	cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cap.add_theme_font_size_override("font_size", 13)
	cap.add_theme_color_override("font_color", MUTED)
	vbox.add_child(cap)

	var value := Label.new()
	value.text = "0"
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	value.add_theme_font_override("font", _anton)
	value.add_theme_font_size_override("font_size", 34)
	value.add_theme_color_override("font_color", color)
	vbox.add_child(value)

	_values[key] = value
	return panel


## Refreshes each chip from the values the game measured this frame.
func set_stats(seconds: int, calories: float, steps: int, orbs: int) -> void:
	if _values.is_empty():
		return
	_values["time"].text = "%d:%02d" % [seconds / 60, seconds % 60]
	_values["calories"].text = "%.0f" % calories
	_values["steps"].text = str(steps)
	_values["orbs"].text = str(orbs)


## A quick scale pop on the ORBS value when one is banked, so pickups feel felt.
func pulse_orbs() -> void:
	var value: Label = _values.get("orbs")
	if value == null:
		return
	value.pivot_offset = value.size * 0.5
	value.scale = Vector2(1.4, 1.4)
	var tween := value.create_tween()
	tween.tween_property(value, "scale", Vector2.ONE, 0.28) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
