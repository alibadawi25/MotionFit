extends Control
class_name HeatCalendar
## HeatCalendar
##
## GitHub-contribution-style consistency calendar for the fitness dashboard, drawn
## in code (no addon) to match the project's other custom widgets (see [BarChart]).
## Columns are weeks (oldest → newest, last column = the current week); rows are
## weekdays (Sun at top). Each day's square is tinted by how much of the daily
## calorie goal it hit — empty → faint, met → full accent — so a glance shows how
## consistently the player has been moving. Today's square gets a bright ring.
##
## Feed it via [method set_cells] with ActivityManager.get_calendar() output plus
## the goal; it recomputes the square size from its own width, so it fits whatever
## container it's dropped into.

const EMPTY_COLOR := Color(1, 1, 1, 0.06)
const ACCENT := Color(1, 0.5, 0.14)
const TODAY_RING := Color(0.96, 0.97, 0.99, 0.85)
const LABEL_COLOR := Color(0.72, 0.76, 0.82)
const GAP := 4.0
const CORNER := 3.0
# Left gutter for weekday initials and top band for the "Less → More" legend.
const GUTTER := 26.0
const TOP_BAND := 22.0
# Only every other weekday is labelled, matching GitHub's Mon/Wed/Fri ticks.
const ROW_LABELS := ["", "M", "", "W", "", "F", ""]

var _cells: Array[Dictionary] = []
var _weeks: int = 0
var _goal: float = 300.0

## Sets the grid. [param cells] is ActivityManager.get_calendar(weeks) output;
## [param goal] > 0 is the daily calorie target the fill scales against.
func set_cells(cells: Array[Dictionary], goal: float) -> void:
	_cells = cells
	_goal = maxf(goal, 1.0)
	var max_col: int = 0
	for cell in cells:
		max_col = maxi(max_col, int(cell["col"]))
	_weeks = max_col + 1
	queue_redraw()


func _draw() -> void:
	if _weeks == 0:
		return

	var grid_w: float = size.x - GUTTER
	var grid_h: float = size.y - TOP_BAND
	var slot_x: float = grid_w / float(_weeks)
	var slot_y: float = grid_h / 7.0
	var cell: float = maxf(minf(slot_x, slot_y) - GAP, 4.0)

	var font: Font = get_theme_default_font()
	var font_size: int = 13

	# Weekday initials down the left gutter, aligned to their rows.
	if font != null:
		for row in range(7):
			var initial: String = ROW_LABELS[row]
			if initial == "":
				continue
			var cy: float = TOP_BAND + row * slot_y + cell * 0.5 + font_size * 0.35
			draw_string(font, Vector2(0, cy), initial,
				HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, LABEL_COLOR)

	for c in _cells:
		if bool(c["in_future"]):
			continue
		var col: int = int(c["col"])
		var row: int = int(c["row"])
		var x: float = GUTTER + col * slot_x
		var y: float = TOP_BAND + row * slot_y
		var rect := Rect2(x, y, cell, cell)
		draw_rect(rect, _cell_color(float(c["calories"])), true)
		if bool(c["is_today"]):
			draw_rect(rect.grow(1.0), TODAY_RING, false, 2.0)

	_draw_legend(font, font_size, cell)


## Faint when nothing was burned, ramping to full accent at (or over) the goal, so
## the tint reads as "how much of today's target did this day reach".
func _cell_color(calories: float) -> Color:
	if calories <= 0.0:
		return EMPTY_COLOR
	var t: float = clampf(calories / _goal, 0.0, 1.0)
	# Floor the alpha so any active day is clearly darker than an empty one.
	return Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.28 + 0.72 * t)


## A small "Less ▢▢▢▢ More" key in the top band, so the tint scale is legible.
func _draw_legend(font: Font, font_size: int, cell: float) -> void:
	if font == null:
		return
	var sw: float = minf(cell, 14.0)
	var y: float = (TOP_BAND - sw) * 0.5
	var steps := [0.0, 0.34, 0.67, 1.0]
	var x: float = size.x - float(steps.size()) * (sw + 3.0) - 44.0
	draw_string(font, Vector2(x - 40.0, y + sw * 0.5 + font_size * 0.35), "Less",
		HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, LABEL_COLOR)
	for s in steps:
		var col: Color = EMPTY_COLOR if s <= 0.0 else Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.28 + 0.72 * float(s))
		draw_rect(Rect2(x, y, sw, sw), col, true)
		x += sw + 3.0
	draw_string(font, Vector2(x + 4.0, y + sw * 0.5 + font_size * 0.35), "More",
		HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, LABEL_COLOR)
