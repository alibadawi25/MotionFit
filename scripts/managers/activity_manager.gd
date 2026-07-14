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

## Emitted after a session has been folded into [param day_key] ("YYYY-MM-DD").
signal activity_recorded(day_key: String)

const SAVE_FILE: String = "activity.json"
const SECONDS_PER_DAY: int = 86400
const DEFAULT_DAILY_CALORIE_GOAL: float = 300.0
## Upper bound on the streak scan so a full log can never loop unbounded.
const MAX_STREAK_SCAN: int = 3650

var _data: Dictionary = _default_data()

func _ready() -> void:
	_data = SaveManager.load_data(SAVE_FILE, _default_data())
	for key in _default_data():
		if not _data.has(key):
			_data[key] = _default_data()[key]
	GameManager.game_finished.connect(_on_game_finished)


func _on_game_finished(result: Dictionary) -> void:
	record_result(result)


## Rolls a finished GameResult (see CONTEXT.md §6) into today's bucket and
## persists. Normally invoked via the game_finished signal; safe to call directly
## (e.g. from tests). Steps are read from an optional "steps" field so games that
## count them can contribute without changing the core GameResult contract.
func record_result(result: Dictionary) -> void:
	var key: String = today_key()
	var days: Dictionary = _data["days"]
	var day: Dictionary = days.get(key, _empty_day())
	day["calories"] = float(day["calories"]) + maxf(float(result.get("calories", 0.0)), 0.0)
	day["active_sec"] = float(day["active_sec"]) + maxf(float(result.get("duration_sec", 0.0)), 0.0)
	day["steps"] = int(day["steps"]) + maxi(int(result.get("steps", 0)), 0)
	day["xp"] = int(day["xp"]) + maxi(int(result.get("xp_earned", 0)), 0)
	day["sessions"] = int(day["sessions"]) + 1
	days[key] = day
	_data["days"] = days
	_save()
	activity_recorded.emit(key)


# --- Queries (all derived from the daily log) ------------------------------

## The player's daily calorie target (used for the goal ring / bar-chart line).
func get_daily_calorie_goal() -> float:
	return float(_data["daily_calorie_goal"])


func set_daily_calorie_goal(goal: float) -> void:
	_data["daily_calorie_goal"] = clampf(goal, 50.0, 5000.0)
	_save()


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
	return {"days": {}, "daily_calorie_goal": DEFAULT_DAILY_CALORIE_GOAL}


func _save() -> void:
	SaveManager.save_data(SAVE_FILE, _data)
