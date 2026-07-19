extends PanelScreen
## FitnessScreen
##
## Fitness dashboard: today's calories against the (editable) daily goal, current
## streak, the week's total and daily average, a per-day calorie bar chart for the
## last seven days, and a consistency heat-calendar showing how regularly the
## player has moved. Every figure is derived from ActivityManager's daily log (the
## single source of truth) — this screen reads and presents; the only thing it
## writes is the daily goal, back through ActivityManager.

## Godot weekday index (0=Sunday .. 6=Saturday) → single-letter label.
const WEEKDAY_INITIALS: Array[String] = ["S", "M", "T", "W", "T", "F", "S"]
## Weeks shown in the consistency calendar (~4 months).
const CALENDAR_WEEKS: int = 17

# The stats block (KPIs, chart, calendar) is rebuilt when the goal changes; the
# goal editor above it persists so it keeps focus across edits.
var _stats: VBoxContainer
var _goal_spin: SpinBox
var _goal_auto: CheckButton

func _ready() -> void:
	# Wide dashboard rather than a narrow centred card: the KPIs span the panel and
	# the 7-day chart sits beside the consistency calendar, so the screen it owns
	# reads as a dashboard instead of leaving most of the display empty.
	var box := build_panel("FITNESS", "Your movement, at a glance", 1180.0)

	box.add_child(_build_goal_editor())
	box.add_child(HSeparator.new())

	_stats = VBoxContainer.new()
	_stats.add_theme_constant_override("separation", 22)
	box.add_child(_stats)
	_rebuild_stats()

	box.add_child(_build_back())


## The goal editor. By default the goal auto-adapts to recent activity (AUTO on,
## the stepper shows it read-only); turning AUTO off makes the current number a
## manual override the player can dial. Either way it persists through
## ActivityManager and refreshes every figure that references the goal (the TODAY
## tile, the chart's goal line, the calendar tint).
func _build_goal_editor() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)

	var caption := Label.new()
	caption.text = "DAILY GOAL"
	caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	caption.add_theme_font_size_override("font_size", 15)
	caption.add_theme_color_override("font_color", CAPTION_COLOR)
	row.add_child(caption)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	_goal_auto = CheckButton.new()
	_goal_auto.text = "AUTO"
	_goal_auto.tooltip_text = "Adapt the goal to your recent activity"
	_goal_auto.button_pressed = ActivityManager.is_goal_auto()
	_goal_auto.toggled.connect(_on_goal_auto_toggled)
	row.add_child(_goal_auto)

	_goal_spin = SpinBox.new()
	_goal_spin.min_value = 50.0
	_goal_spin.max_value = 5000.0
	_goal_spin.step = 50.0
	_goal_spin.suffix = " kcal"
	_goal_spin.custom_minimum_size = Vector2(200, 40)
	_goal_spin.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_goal_spin.set_value_no_signal(ActivityManager.get_daily_calorie_goal())
	_goal_spin.editable = not ActivityManager.is_goal_auto()
	_goal_spin.value_changed.connect(func(v: float) -> void:
		ActivityManager.set_daily_calorie_goal(v)
		_rebuild_stats())
	row.add_child(_goal_spin)
	return row


## AUTO on: the goal follows recent activity and the stepper shows it, read-only.
## AUTO off: the number showing becomes a manual override the player can dial.
func _on_goal_auto_toggled(on: bool) -> void:
	if on:
		ActivityManager.set_goal_auto()
	else:
		ActivityManager.set_daily_calorie_goal(_goal_spin.value)
	_goal_spin.editable = not on
	_goal_spin.set_value_no_signal(ActivityManager.get_daily_calorie_goal())
	_rebuild_stats()


## Clears and rebuilds the KPI row, bar chart and heat-calendar from the current
## log + goal. Cheap (a handful of nodes) and keeps every figure in lock-step with
## the goal without hand-updating each widget.
func _rebuild_stats() -> void:
	for child in _stats.get_children():
		child.queue_free()

	# First run: with nothing logged the tiles, chart and calendar are all zeroes,
	# so lead with one encouraging line rather than a blank, discouraging board.
	if ActivityManager.get_total_sessions() == 0:
		_stats.add_child(_build_empty_notice())

	_stats.add_child(_build_kpis())
	_stats.add_child(HSeparator.new())

	# Chart and calendar sit side by side across the wide panel instead of stacked.
	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 32)
	columns.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stats.add_child(columns)

	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_stretch_ratio = 1.15
	left.add_theme_constant_override("separation", 10)
	left.add_child(_caption("CALORIES · LAST 7 DAYS"))
	left.add_child(_build_chart())
	columns.add_child(left)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 10)
	right.add_child(_caption("CONSISTENCY · LAST %d WEEKS" % CALENDAR_WEEKS))
	right.add_child(_build_calendar())
	columns.add_child(right)


## First-run banner explaining what will fill the (currently empty) dashboard —
## the platform never opens on a blank, discouraging screen.
func _build_empty_notice() -> Control:
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 0.5, 0.14, 0.12)
	sb.set_corner_radius_all(12)
	sb.set_border_width_all(1)
	sb.border_color = Color(1, 0.5, 0.14, 0.5)
	sb.content_margin_left = 22
	sb.content_margin_right = 22
	sb.content_margin_top = 16
	sb.content_margin_bottom = 16
	panel.add_theme_stylebox_override("panel", sb)

	var label := Label.new()
	label.text = "No movement logged yet — play your first game and your calories, streak and consistency start filling in here."
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 17)
	label.add_theme_color_override("font_color", Color(1, 0.7, 0.4))
	panel.add_child(label)
	return panel


func _build_kpis() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 20)
	var today: int = int(ActivityManager.get_today_calories())
	var goal: int = int(ActivityManager.get_daily_calorie_goal())
	row.add_child(_kpi_card("TODAY", "%d / %d" % [today, goal], "kcal"))
	row.add_child(_kpi_card("STREAK", str(ActivityManager.get_streak()), "days"))
	row.add_child(_kpi_card("THIS WEEK", "%d" % int(ActivityManager.get_calories_last_days(7)), "kcal"))
	row.add_child(_kpi_card("DAILY AVG", "%d" % int(ActivityManager.get_average_calories(7)), "kcal"))
	return row


## Wraps a KPI stat tile in a bordered card that shares the row width evenly, so
## the four headline numbers span the panel as dashboard tiles instead of
## huddling at the left.
func _kpi_card(caption: String, value: String, unit: String = "") -> Control:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.12, 0.17, 0.55)
	sb.set_corner_radius_all(12)
	sb.set_border_width_all(1)
	sb.border_color = Color(1, 1, 1, 0.08)
	sb.content_margin_left = 22
	sb.content_margin_right = 22
	sb.content_margin_top = 16
	sb.content_margin_bottom = 16
	panel.add_theme_stylebox_override("panel", sb)
	panel.add_child(make_stat_tile(caption, value, unit))
	return panel


func _build_chart() -> Control:
	var chart := BarChart.new()
	chart.custom_minimum_size = Vector2(0, 150)
	chart.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var labels := PackedStringArray()
	var values := PackedFloat32Array()
	for day in ActivityManager.get_recent_days(7):
		labels.append(WEEKDAY_INITIALS[int(day["weekday"])])
		values.append(float(day["calories"]))
	chart.set_series(labels, values, ActivityManager.get_daily_calorie_goal())
	return chart


func _build_calendar() -> Control:
	var cal := HeatCalendar.new()
	cal.custom_minimum_size = Vector2(0, 168)
	cal.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cal.set_cells(ActivityManager.get_calendar(CALENDAR_WEEKS), ActivityManager.get_daily_calorie_goal())
	return cal


func _caption(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 15)
	label.add_theme_color_override("font_color", CAPTION_COLOR)
	return label


func _build_back() -> Control:
	var back_button := Button.new()
	back_button.text = "BACK"
	back_button.custom_minimum_size = Vector2(150, 50)
	back_button.pressed.connect(SceneManager.load_main_menu)
	return back_button
