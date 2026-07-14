extends Control
class_name BarChart
## BarChart
##
## Minimal custom-drawn bar chart for short fitness series (e.g. calories per day
## over the last week). Built in code — no chart addon — to match the project's
## code-built UI. Feed it via [method set_series]; it draws labelled bars scaled
## to the largest value, brightens the final (today) bar, and draws an optional
## dashed goal line. One value per bar.

const BAR_COLOR := Color(1, 0.5, 0.14)
const BAR_COLOR_DIM := Color(1, 0.5, 0.14, 0.4)
const AXIS_COLOR := Color(1, 1, 1, 0.12)
const GOAL_COLOR := Color(0.96, 0.97, 0.99, 0.45)
const LABEL_COLOR := Color(0.72, 0.76, 0.82)
const LABEL_BAND := 20.0
const BAR_WIDTH_RATIO := 0.56

var _labels: PackedStringArray = PackedStringArray()
var _values: PackedFloat32Array = PackedFloat32Array()
var _goal: float = 0.0

## Sets the bars. [param labels] and [param values] should be the same length;
## [param goal] > 0 draws a dashed reference line. Triggers a redraw.
func set_series(labels: PackedStringArray, values: PackedFloat32Array, goal: float = 0.0) -> void:
	_labels = labels
	_values = values
	_goal = maxf(goal, 0.0)
	queue_redraw()


func _draw() -> void:
	var n: int = _values.size()
	if n == 0:
		return

	var chart_h: float = size.y - LABEL_BAND
	var max_v: float = _goal
	for v in _values:
		max_v = maxf(max_v, v)
	if max_v <= 0.0:
		max_v = 1.0

	var slot: float = size.x / float(n)
	var bar_w: float = slot * BAR_WIDTH_RATIO

	# Baseline.
	draw_line(Vector2(0, chart_h), Vector2(size.x, chart_h), AXIS_COLOR, 1.0)

	# Goal reference line.
	if _goal > 0.0:
		var gy: float = chart_h - (_goal / max_v) * chart_h
		draw_dashed_line(Vector2(0, gy), Vector2(size.x, gy), GOAL_COLOR, 1.0, 6.0)

	var font: Font = get_theme_default_font()
	var font_size: int = 14
	for i in n:
		var h: float = (_values[i] / max_v) * chart_h
		var x: float = i * slot + (slot - bar_w) * 0.5
		var color: Color = BAR_COLOR if i == n - 1 else BAR_COLOR_DIM
		draw_rect(Rect2(x, chart_h - h, bar_w, h), color)
		if i < _labels.size() and font != null:
			var label: String = _labels[i]
			var text_w: float = font.get_string_size(
				label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
			draw_string(font, Vector2(i * slot + (slot - text_w) * 0.5, size.y - 4),
				label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, LABEL_COLOR)
