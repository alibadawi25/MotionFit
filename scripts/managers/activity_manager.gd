extends Node
## ActivityManager
##
## Owns the day-by-day fitness history — the single time-series source of truth
## for calories, active time, steps and sessions. Lifetime totals live in
## ProfileManager; this manager keeps the *dated* records so the app can show
## per-day calories, weekly totals, rolling averages and streaks.
##
## Design rule: only the daily log is stored. Weekly numbers, averages and
## streaks are DERIVED on read, so they can never drift out of sync with the
## days they summarise (CONTEXT.md §2: data-driven, one source of truth).
##
## It listens to GameManager.game_finished and rolls each session into today's
## bucket, so no game or screen has to know this manager exists. Persistence is
## delegated to SaveManager; it initialises after GameManager (whose signal it
## connects to in _ready).
##
## The daily log is PER-PROFILE: the save file is scoped by the active profile id
## and reloaded when ProfileManager switches profile, so each person on a shared
## device keeps their own history. (ProfileManager autoloads before this.)

## Emitted after a session has been folded into [param day_key] ("YYYY-MM-DD").
signal activity_recorded(day_key: String)

## Pre-multi-profile shared log, adopted once by the migrated profile.
const LEGACY_SAVE_FILE: String = "activity.json"
const SECONDS_PER_DAY: int = 86400
const DEFAULT_DAILY_CALORIE_GOAL: float = 300.0
## Upper bound on the streak scan so a full log can never loop unbounded.
const MAX_STREAK_SCAN: int = 3650

## Adaptive daily goal (the default "auto" mode). The target is grounded in the
## player's OWN recent sessions rather than a flat number some people can't reach:
## the average of their active days, nudged gently upward so it rewards a little
## extra without being a wall. See [method get_adaptive_calorie_goal].
const GOAL_WINDOW_DAYS: int = 14
const GOAL_STRETCH: float = 1.10       # ~10% over the recent active-day average
const GOAL_ROUNDING: float = 10.0      # snap to a clean number
const GOAL_FLOOR: float = 120.0        # never below a friendly, hittable minimum
const ONBOARDING_GOAL: float = 150.0   # gentle first goal, before any history exists

var _data: Dictionary = _default_data()

func _ready() -> void:
	_load_for_active()
	GameManager.game_finished.connect(_on_game_finished)
	# The log follows whoever is playing: reload when the active profile changes.
	ProfileManager.profile_switched.connect(func(_id: String): _load_for_active())


## (Re)loads the daily log for the currently-active profile. A migrated profile
## adopts the old shared "activity.json" once (then owns a scoped copy).
func _load_for_active() -> void:
	var file: String = _save_file()
	if SaveManager.has_save(file):
		_data = SaveManager.load_data(file, _default_data())
	elif ProfileManager.active_is_migrated() and SaveManager.has_save(LEGACY_SAVE_FILE):
		_data = SaveManager.load_data(LEGACY_SAVE_FILE, _default_data())
		_save()  # write it under the per-profile name so it's owned going forward
	else:
		_data = _default_data()
	_migrate_goal_mode()
	for key in _default_data():
		if not _data.has(key):
			_data[key] = _default_data()[key]


## Older saves predate adaptive goals. Respect a deliberately-customised goal by
## keeping it as a manual override; everyone else adopts the new adaptive default.
func _migrate_goal_mode() -> void:
	if _data.has("goal_mode"):
		return
	var had_custom: bool = _data.has("daily_calorie_goal") and \
		not is_equal_approx(float(_data["daily_calorie_goal"]), DEFAULT_DAILY_CALORIE_GOAL)
	_data["goal_mode"] = "manual" if had_custom else "auto"


## Per-profile save filename ("activity_<active_id>.json").
func _save_file() -> String:
	return "activity_%s.json" % ProfileManager.get_active_id()


func _on_game_finished(result: GameResult) -> void:
	record_result(result)


## Rolls a finished GameResult (see CONTEXT.md §6) into today's bucket and
## persists. Normally invoked via the game_finished signal; safe to call directly
## (e.g. from tests). Steps are read from an optional "steps" field so games that
## count them can contribute without changing the core GameResult contract.
func record_result(result: GameResult) -> void:
	var key: String = today_key()
	var days: Dictionary = _data["days"]
	var day: Dictionary = days.get(key, _empty_day())
	day["calories"] = float(day["calories"]) + maxf(result.calories, 0.0)
	day["active_sec"] = float(day["active_sec"]) + maxf(result.duration_sec, 0.0)
	day["steps"] = int(day["steps"]) + maxi(result.steps, 0)
	day["xp"] = int(day["xp"]) + maxi(result.xp_earned, 0)
	day["sessions"] = int(day["sessions"]) + 1
	days[key] = day
	_data["days"] = days
	_save()
	activity_recorded.emit(key)


# --- Queries (all derived from the daily log) ------------------------------

## The player's daily calorie target (used for the goal ring / bar-chart line).
## In "auto" mode (the default) this adapts to recent activity; a manual override
## returns the fixed number the player dialled in.
func get_daily_calorie_goal() -> float:
	if is_goal_auto():
		return get_adaptive_calorie_goal()
	return float(_data["daily_calorie_goal"])


## True while the goal is auto-adapting to recent activity (vs. a manual override).
func is_goal_auto() -> bool:
	return String(_data.get("goal_mode", "auto")) == "auto"


## Dialling a specific number is an explicit override: store it and switch to manual.
func set_daily_calorie_goal(goal: float) -> void:
	_data["daily_calorie_goal"] = clampf(goal, 50.0, 5000.0)
	_data["goal_mode"] = "manual"
	_save()


## Hand the goal back to auto-adapt (undo a manual override).
func set_goal_auto() -> void:
	_data["goal_mode"] = "auto"
	_save()


## A target grounded in the player's own recent sessions: the average of their
## active days over the last two weeks, nudged ~10% so it rewards a little extra
## yet stays reachable, floored to a friendly minimum. Falls back to a gentle
## onboarding goal until there's real history. This is what makes the goal help
## rather than scold — nobody is measured against a number they've never neared.
func get_adaptive_calorie_goal() -> float:
	var avg: float = get_average_active_day_calories(GOAL_WINDOW_DAYS)
	if avg <= 0.0:
		return ONBOARDING_GOAL
	var rounded: float = roundf(avg * GOAL_STRETCH / GOAL_ROUNDING) * GOAL_ROUNDING
	return clampf(rounded, GOAL_FLOOR, 5000.0)


## Average calories over only the *active* days (a session logged) in the last
## [param days], so occasional rest days don't drag a per-session target toward
## zero. Returns 0.0 when the window holds no active days.
func get_average_active_day_calories(days: int = GOAL_WINDOW_DAYS) -> float:
	var total: float = 0.0
	var active: int = 0
	for day in get_recent_days(days):
		if int(day["sessions"]) > 0:
			total += float(day["calories"])
			active += 1
	return total / active if active > 0 else 0.0


## Calories logged for today.
func get_today_calories() -> float:
	return _day_field(today_key(), "calories")


## The last [param count] calendar days as buckets, oldest first, with missing
## days filled as zeroes — ready to feed a bar chart. Each entry has keys:
## "key", "weekday" (0=Sun..6=Sat), "calories", "steps", "active_sec", "sessions".
func get_recent_days(count: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var now: int = int(Time.get_unix_time_from_system())
	for i in range(count - 1, -1, -1):
		var date: Dictionary = Time.get_date_dict_from_unix_time(now - i * SECONDS_PER_DAY)
		var day: Dictionary = _data["days"].get(_key_from_date(date), _empty_day())
		out.append({
			"key": _key_from_date(date),
			"weekday": int(date["weekday"]),
			"calories": float(day["calories"]),
			"steps": int(day["steps"]),
			"active_sec": float(day["active_sec"]),
			"sessions": int(day["sessions"]),
		})
	return out


## A weeks×7 calendar grid (GitHub-contribution style) for the consistency
## heat-calendar. Columns are weeks oldest→newest (the last column is the current
## week); rows are weekdays 0=Sun..6=Sat. Each cell is a Dictionary:
## "key", "col", "row", "calories", "in_future" (a later day of the current week),
## "is_today". Derived on read from the daily log, so it can never disagree with
## the bar chart or KPIs.
func get_calendar(weeks: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var now: int = int(Time.get_unix_time_from_system())
	var today_weekday: int = int(Time.get_date_dict_from_system()["weekday"])
	var today: String = today_key()
	for col in range(weeks):
		var weeks_back: int = weeks - 1 - col
		for row in range(7):
			# Days from today back to this cell: whole weeks, plus this week's
			# offset from today's weekday to the cell's row.
			var offset_days: int = weeks_back * 7 + (today_weekday - row)
			var date: Dictionary = Time.get_date_dict_from_unix_time(now - offset_days * SECONDS_PER_DAY)
			var key: String = _key_from_date(date)
			out.append({
				"key": key,
				"col": col,
				"row": row,
				"calories": _day_field(key, "calories"),
				"in_future": offset_days < 0,
				"is_today": key == today,
			})
	return out


## Total calories over the last [param count] days (default 7 = a week).
func get_calories_last_days(count: int = 7) -> float:
	var total: float = 0.0
	for day in get_recent_days(count):
		total += float(day["calories"])
	return total


## Average calories per day over the last [param count] days.
func get_average_calories(count: int = 7) -> float:
	if count <= 0:
		return 0.0
	return get_calories_last_days(count) / count


## Lifetime totals, summed across the whole daily log. The log is the single
## source of truth for fitness aggregates too, so these can never disagree with
## the per-day view. All start at 0 and grow only from real finished sessions.
func get_total_calories() -> float:
	return _sum_field("calories")


func get_total_steps() -> int:
	return int(_sum_field("steps"))


func get_total_active_sec() -> float:
	return _sum_field("active_sec")


## Number of finished sessions ("workouts") across all days.
func get_total_sessions() -> int:
	return int(_sum_field("sessions"))


func _sum_field(field: String) -> float:
	var total: float = 0.0
	var days: Dictionary = _data["days"]
	for key in days:
		total += float((days[key] as Dictionary).get(field, 0))
	return total


## Consecutive days up to today with at least one session. An unfinished today
## (no session yet) does not break the streak — counting then starts at yesterday.
func get_streak() -> int:
	var now: int = int(Time.get_unix_time_from_system())
	var streak: int = 0
	# If today has no session yet, begin at yesterday so an in-progress day
	# doesn't read as a broken streak.
	var i: int = 0 if _day_field(today_key(), "sessions") > 0.0 else 1
	while i < MAX_STREAK_SCAN:
		var date: Dictionary = Time.get_date_dict_from_unix_time(now - i * SECONDS_PER_DAY)
		if _day_field(_key_from_date(date), "sessions") > 0.0:
			streak += 1
			i += 1
		else:
			break
	return streak


## Today's date key ("YYYY-MM-DD"), the id of today's bucket.
func today_key() -> String:
	return _key_from_date(Time.get_date_dict_from_system())


func _day_field(key: String, field: String) -> float:
	var day: Dictionary = _data["days"].get(key, _empty_day())
	return float(day.get(field, 0))


func _key_from_date(date: Dictionary) -> String:
	return "%04d-%02d-%02d" % [int(date["year"]), int(date["month"]), int(date["day"])]


func _empty_day() -> Dictionary:
	return {"calories": 0.0, "active_sec": 0.0, "steps": 0, "xp": 0, "sessions": 0}


func _default_data() -> Dictionary:
	return {"days": {}, "daily_calorie_goal": DEFAULT_DAILY_CALORIE_GOAL, "goal_mode": "auto"}


func _save() -> void:
	SaveManager.save_data(_save_file(), _data)
