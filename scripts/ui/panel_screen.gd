extends Control
class_name PanelScreen
## PanelScreen
##
## Base for the small centred-card menu screens (onboarding, profile edit). It
## builds the shared scaffold — a dark rounded panel with an accent bar, title
## and optional subtitle — and returns the inner content VBox for the subclass
## to fill with its own controls. Keeps that card styling defined in one place.

const ACCENT := Color(1, 0.5, 0.14)
const ACCENT_TEXT := Color(1, 0.64, 0.3)
const TITLE_COLOR := Color(0.96, 0.97, 0.99)
const SUBTITLE_COLOR := Color(0.78, 0.82, 0.88, 0.9)
const CAPTION_COLOR := Color(0.7, 0.74, 0.8)

## Builds the centred panel and returns the inner VBox to append content to.
## [param max_width] caps the card width; content stretches to it.
func build_panel(title_text: String, subtitle_text: String = "",
		max_width: float = 560.0) -> VBoxContainer:
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(max_width, 0)
	panel.add_theme_stylebox_override("panel", _panel_style())
	center.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 20)
	panel.add_child(box)

	var accent := ColorRect.new()
	accent.color = ACCENT
	accent.custom_minimum_size = Vector2(64, 5)
	accent.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	box.add_child(accent)

	var title := Label.new()
	title.text = title_text
	title.add_theme_font_size_override("font_size", 38)
	title.add_theme_color_override("font_color", TITLE_COLOR)
	box.add_child(title)

	if subtitle_text != "":
		var subtitle := Label.new()
		subtitle.text = subtitle_text
		subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		subtitle.add_theme_font_size_override("font_size", 17)
		subtitle.add_theme_color_override("font_color", SUBTITLE_COLOR)
		box.add_child(subtitle)

	return box


## Builds a stat tile — a large accent value with an optional small unit and a
## caption beneath — for the KPI rows on the profile and fitness screens.
func make_stat_tile(caption: String, value: String, unit: String = "") -> Control:
	var tile := VBoxContainer.new()
	tile.add_theme_constant_override("separation", 1)

	var value_row := HBoxContainer.new()
	value_row.add_theme_constant_override("separation", 4)
	var value_label := Label.new()
	value_label.text = value
	value_label.add_theme_font_size_override("font_size", 28)
	value_label.add_theme_color_override("font_color", ACCENT_TEXT)
	value_row.add_child(value_label)
	if unit != "":
		var unit_label := Label.new()
		unit_label.text = unit
		unit_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		unit_label.add_theme_font_size_override("font_size", 14)
		unit_label.add_theme_color_override("font_color", CAPTION_COLOR)
		value_row.add_child(unit_label)
	tile.add_child(value_row)

	var caption_label := Label.new()
	caption_label.text = caption
	caption_label.add_theme_font_size_override("font_size", 13)
	caption_label.add_theme_color_override("font_color", CAPTION_COLOR)
	tile.add_child(caption_label)
	return tile


func _panel_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.07, 0.09, 0.13, 0.96)
	sb.set_corner_radius_all(16)
	sb.set_border_width_all(1)
	sb.border_color = Color(1, 1, 1, 0.1)
	sb.shadow_color = Color(0, 0, 0, 0.28)
	sb.shadow_size = 16
	# Inner padding lives on the panel stylebox so PanelContainer insets its child.
	sb.content_margin_left = 44
	sb.content_margin_right = 44
	sb.content_margin_top = 40
	sb.content_margin_bottom = 40
	return sb
