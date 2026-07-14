extends PanelScreen
## FitnessScreen
##
## Fitness dashboard: today's calories against the daily goal, current streak,
## the week's total and daily average, plus a per-day calorie bar chart for the
## last seven days. Every figure is derived from ActivityManager's daily log
## (the single source of truth) — this screen only reads and presents.

## Godot weekday index (0=Sunday .. 6=Saturday) → single-letter label.
const WEEKDAY_INITIALS: Array[String] = ["S", "M", "T", "W", "T", "F", "S"]

func _ready() -> void:
	var box := build_panel("FITNESS", "", 640.0)

	box.add_child(_build_kpis())
	box.add_child(HSeparator.new())

	var chart_caption := Label.new()
	chart_caption.text = "CALORIES · LAST 7 DAYS"
	chart_caption.add_theme_font_size_override("font_size", 15)
	chart_caption.add_theme_color_override("font_color", CAPTION_COLOR)
	box.add_child(chart_caption)

	box.add_child(_build_chart())
	box.add_child(_build_back())


func _build_kpis() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 40)
	var today: int = int(ActivityManager.get_today_calories())
	var goal: int = int(ActivityManager.get_daily_calorie_goal())
	row.add_child(make_stat_tile("TODAY", "%d / %d" % [today, goal], "kcal"))
	row.add_child(make_stat_tile("STREAK", str(ActivityManager.get_streak()), "days"))
	row.add_child(make_stat_tile("THIS WEEK", "%d" % int(ActivityManager.get_calories_last_days(7)), "kcal"))
	row.add_child(make_stat_tile("DAILY AVG", "%d" % int(ActivityManager.get_average_calories(7)), "kcal"))
	return row


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


func _build_back() -> Control:
	var back_button := Button.new()
	back_button.text = "BACK"
	back_button.custom_minimum_size = Vector2(150, 50)
	back_button.pressed.connect(SceneManager.load_main_menu)
	return back_button
