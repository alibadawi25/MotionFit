extends PanelScreen
## FitnessScreen
##
## Fitness dashboard: today's calories against the (editable) daily goal, current
## streak, the week's total and daily average, a per-day calorie bar chart for the
## last seven days, and a consistency heat-calendar showing how regularly the
## player has moved. Every figure is derived from ActivityManager's daily log (the
## single source of truth) — this screen reads and presents; the only thing it
## writes is the daily goal, back through ActivityManager.
##
## The dashboard layout — goal editor, the four KPI tiles, the chart/calendar
## columns and the first-run notice — is authored in
## scenes/menus/fitness_screen.tscn. This script only refreshes the figures, so
## every widget stays in lock-step with the goal without being rebuilt.

## Godot weekday index (0=Sunday .. 6=Saturday) → single-letter label.
const WEEKDAY_INITIALS: Array[String] = ["S", "M", "T", "W", "T", "F", "S"]
## Weeks shown in the consistency calendar (~4 months).
const CALENDAR_WEEKS: int = 17

@onready var _goal_spin: SpinBox = %GoalSpin
@onready var _goal_auto: CheckButton = %GoalAutoToggle
@onready var _empty_notice: PanelContainer = %EmptyNotice
@onready var _today_tile: StatTile = %TodayTile
@onready var _streak_tile: StatTile = %StreakTile
@onready var _week_tile: StatTile = %WeekTile
@onready var _average_tile: StatTile = %AverageTile
@onready var _chart: BarChart = %CalorieChart
@onready var _calendar: HeatCalendar = %ConsistencyCalendar
@onready var _consistency_caption: Label = %ConsistencyCaption
@onready var _back_button: Button = %BackButton

func _ready() -> void:
	_consistency_caption.text = "CONSISTENCY · LAST %d WEEKS" % CALENDAR_WEEKS
	# First run: with nothing logged the tiles, chart and calendar are all zeroes,
	# so lead with one encouraging line rather than a blank, discouraging board.
	_empty_notice.visible = ActivityManager.get_total_sessions() == 0

	# By default the goal auto-adapts to recent activity (AUTO on, the stepper
	# shows it read-only); turning AUTO off makes the current number a manual
	# override the player can dial. Either way it persists through
	# ActivityManager and refreshes every figure that references the goal.
	_goal_auto.button_pressed = ActivityManager.is_goal_auto()
	_goal_auto.toggled.connect(_on_goal_auto_toggled)
	_goal_spin.set_value_no_signal(ActivityManager.get_daily_calorie_goal())
	_goal_spin.editable = not ActivityManager.is_goal_auto()
	_goal_spin.value_changed.connect(func(v: float) -> void:
		ActivityManager.set_daily_calorie_goal(v)
		_refresh_stats())

	_back_button.pressed.connect(SceneManager.load_main_menu)
	_refresh_stats()


## AUTO on: the goal follows recent activity and the stepper shows it, read-only.
## AUTO off: the number showing becomes a manual override the player can dial.
func _on_goal_auto_toggled(on: bool) -> void:
	if on:
		ActivityManager.set_goal_auto()
	else:
		ActivityManager.set_daily_calorie_goal(_goal_spin.value)
	_goal_spin.editable = not on
	_goal_spin.set_value_no_signal(ActivityManager.get_daily_calorie_goal())
	_refresh_stats()


## Re-reads the KPI numbers, the bar chart and the heat-calendar from the current
## log + goal, so a goal edit moves the TODAY tile, the chart's goal line and the
## calendar tint together.
func _refresh_stats() -> void:
	var goal: float = ActivityManager.get_daily_calorie_goal()
	_today_tile.value = "%d / %d" % [int(ActivityManager.get_today_calories()), int(goal)]
	_streak_tile.value = str(ActivityManager.get_streak())
	_week_tile.value = "%d" % int(ActivityManager.get_calories_last_days(7))
	_average_tile.value = "%d" % int(ActivityManager.get_average_calories(7))

	var labels := PackedStringArray()
	var values := PackedFloat32Array()
	for day in ActivityManager.get_recent_days(7):
		labels.append(WEEKDAY_INITIALS[int(day["weekday"])])
		values.append(float(day["calories"]))
	_chart.set_series(labels, values, goal)

	_calendar.set_cells(ActivityManager.get_calendar(CALENDAR_WEEKS), goal)
