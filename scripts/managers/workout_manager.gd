extends Node
## WorkoutManager
##
## Owns the Daily Challenge — the platform's "reason to come back tomorrow". Each
## calendar day it prescribes ONE structured interval workout (a HIIT session
## layered on an existing game) generated DETERMINISTICALLY from the date, so the
## challenge is the same all day, refreshes at midnight, and needs nothing stored
## to describe it. The live effort estimator (MotionManager MET) drives the
## targets in-game via [IntervalCoach]; this manager just defines the plan and
## remembers which days were completed.
##
## A plan is a Dictionary: { date, game_id, difficulty, title, subtitle, blocks,
## total_sec, push_count }. Each block is { kind ("warmup"/"work"/"recover"/
## "cooldown"), seconds, target_met, label }.
##
## Completion is the only stored state, and it is PER-PROFILE (scoped by the active
## profile id, reloaded on profile switch — the same pattern as ActivityManager),
## so each person on a shared device keeps their own challenge history and streak.
## Loads after ProfileManager and GameManager (it reads the game registry).

## Emitted after today's challenge is marked complete, so the menu can refresh.
signal challenge_completed(day_key: String)

const SECONDS_PER_DAY: int = 86400

## Games the Daily Challenge can be layered onto: endless / time-based canvases
## where an interval timeline can run to the end. Fixed-course races (Hurdle Dash)
## are excluded — their run ends before the workout would. Ids must be `available`.
const ELIGIBLE_GAMES: Array[String] = ["open_world", "runner"]

## MET targets for the interval kinds (metabolic-equivalent, see MotionManager).
## "work" is the push target; base value, nudged per template below. These are the
## reference targets for a consistently-active player; [method _effort_scale]
## personalises them so a beginner's "on target" is actually reachable.
const WARMUP_MET: float = 3.0
const WORK_MET: float = 6.0
const RECOVER_MET: float = 2.5
const COOLDOWN_MET: float = 2.0

## Personal intensity band. Every block's target scales within this range by the
## player's recent activity (ActivityManager): a gentler, hittable challenge when
## they're just starting, the full push once they're consistently active. It rises
## on its own as their activity climbs — the gentle progression we're after.
const BEGINNER_MET_SCALE: float = 0.80
const ADVANCED_MET_SCALE: float = 1.12
const NEW_PLAYER_MET_SCALE: float = 0.85   # before there's any history to read
## Active-day calorie average that maps to the full (advanced) intensity.
const REFERENCE_ACTIVE_CALORIES: float = 350.0

var _data: Dictionary = _default_data()

func _ready() -> void:
	_load_for_active()
	ProfileManager.profile_switched.connect(func(_id: String): _load_for_active())


# --- Today's plan (deterministic, nothing stored) --------------------------

## The interval workout prescribed for today. Deterministic from the date, so it
## is stable all day and everyone playing on the same date gets the same session.
## Returns {} only if no eligible game is currently available.
func get_today_plan() -> Dictionary:
	return _plan_for(today_key())


## Builds the plan for [param day_key] ("YYYY-MM-DD"). Split out so it is testable
## for any date and callable for the menu preview.
func _plan_for(day_key: String) -> Dictionary:
	var eligible: Array[String] = _available_eligible()
	if eligible.is_empty():
		return {}
	# A stable per-day seed; String.hash is deterministic within an engine version.
	var seed: int = abs(day_key.hash())
	var game_id: String = eligible[seed % eligible.size()]
	var templates: Array[Callable] = [
		_template_classic, _template_pyramid, _template_ladder, _template_tabata]
	var template: Callable = templates[(seed / 7) % templates.size()]
	var plan: Dictionary = template.call()
	# Personalise the intensity: the structure/game/template are date-deterministic
	# (everyone gets the same session shape), but the effort targets scale to the
	# player's own recent activity so the challenge helps rather than discourages.
	_scale_targets(plan["blocks"], _effort_scale())
	plan["date"] = day_key
	plan["game_id"] = game_id
	# A consistent, fair intensity every day — the challenge is the intervals, not
	# a punishing base game. Games read this the usual way (GameManager.Difficulty).
	plan["difficulty"] = GameManager.Difficulty.NORMAL
	var totals := _totals(plan["blocks"])
	plan["total_sec"] = totals.x
	plan["push_count"] = totals.y
	return plan


## Personalised intensity multiplier for today's targets, read from the player's
## recent activity (ActivityManager). Low activity → a gentler, hittable challenge;
## consistently active → the full push. A deliberately narrow band, so the workout's
## character never changes — only its reach. Stable within a day (history doesn't
## meaningfully move mid-session), so the plan stays consistent all day.
func _effort_scale() -> float:
	var avg: float = ActivityManager.get_average_active_day_calories(14)
	if avg <= 0.0:
		return NEW_PLAYER_MET_SCALE
	var level: float = clampf(avg / REFERENCE_ACTIVE_CALORIES, 0.0, 1.0)
	return lerpf(BEGINNER_MET_SCALE, ADVANCED_MET_SCALE, level)


## Multiplies every block's target_met in place by [param scale] (rounded to 1dp),
## personalising intensity without touching the workout's structure or timing.
func _scale_targets(blocks: Array, scale: float) -> void:
	for b in blocks:
		var block: Dictionary = b
		block["target_met"] = snappedf(float(block["target_met"]) * scale, 0.1)


## Human title for today's game ("Zombie Run"), for the menu card.
func today_game_title() -> String:
	var plan: Dictionary = get_today_plan()
	if plan.is_empty():
		return ""
	return GameManager.get_game_title(String(plan["game_id"]))


# --- Completion state (per-profile, persisted) -----------------------------

## True once today's challenge has been completed on the active profile.
func is_today_complete() -> bool:
	return is_complete(today_key())


func is_complete(day_key: String) -> bool:
	return bool((_data["completed"] as Dictionary).get(day_key, false))


## Marks today's challenge complete and persists. Called by [MiniGame] when the
## interval timeline finishes (see IntervalCoach). Idempotent.
func mark_today_complete() -> void:
	var key: String = today_key()
	if is_complete(key):
		return
	(_data["completed"] as Dictionary)[key] = true
	_save()
	challenge_completed.emit(key)


## Number of Daily Challenges completed in a row up to today (a challenge-specific
## streak, distinct from ActivityManager's any-session streak). An unfinished today
## does not break it — counting then starts at yesterday.
func get_challenge_streak() -> int:
	var now: int = int(Time.get_unix_time_from_system())
	var streak: int = 0
	var i: int = 0 if is_today_complete() else 1
	while i < 3650:
		var date: Dictionary = Time.get_date_dict_from_unix_time(now - i * SECONDS_PER_DAY)
		if is_complete(_key_from_date(date)):
			streak += 1
			i += 1
		else:
			break
	return streak


func today_key() -> String:
	return _key_from_date(Time.get_date_dict_from_system())


# --- Interval templates ----------------------------------------------------
# Each returns { title, subtitle, blocks }. Durations are seconds. Kept small and
# readable so new structures are easy to add.

func _template_classic() -> Dictionary:
	var blocks: Array[Dictionary] = [_warmup()]
	for i in range(6):
		blocks.append(_work(30, WORK_MET, "PUSH HARD"))
		blocks.append(_recover(30))
	blocks.append(_cooldown())
	return {"title": "Classic Intervals", "subtitle": "6 × 30s hard / 30s easy", "blocks": blocks}


func _template_pyramid() -> Dictionary:
	var work_secs := [20, 30, 40, 40, 30, 20]
	var blocks: Array[Dictionary] = [_warmup()]
	for secs in work_secs:
		blocks.append(_work(secs, WORK_MET, "PUSH HARD"))
		blocks.append(_recover(30))
	blocks.append(_cooldown())
	return {"title": "Pyramid Intervals", "subtitle": "ramp up then back down", "blocks": blocks}


func _template_ladder() -> Dictionary:
	var work_secs := [20, 25, 30, 35, 40, 45]
	var blocks: Array[Dictionary] = [_warmup()]
	for secs in work_secs:
		blocks.append(_work(secs, WORK_MET, "PUSH HARD"))
		blocks.append(_recover(25))
	blocks.append(_cooldown())
	return {"title": "Ladder Intervals", "subtitle": "each push longer than the last", "blocks": blocks}


func _template_tabata() -> Dictionary:
	var blocks: Array[Dictionary] = [_warmup()]
	for i in range(8):
		blocks.append(_work(20, WORK_MET + 0.5, "ALL OUT"))
		blocks.append(_recover(25))
	blocks.append(_cooldown(40))
	return {"title": "Tabata-Style", "subtitle": "8 × 20s all-out / 25s easy", "blocks": blocks}


func _warmup(secs: int = 60) -> Dictionary:
	return {"kind": "warmup", "seconds": secs, "target_met": WARMUP_MET, "label": "WARM UP"}


func _work(secs: int, met: float, label: String) -> Dictionary:
	return {"kind": "work", "seconds": secs, "target_met": met, "label": label}


func _recover(secs: int) -> Dictionary:
	return {"kind": "recover", "seconds": secs, "target_met": RECOVER_MET, "label": "RECOVER"}


func _cooldown(secs: int = 45) -> Dictionary:
	return {"kind": "cooldown", "seconds": secs, "target_met": COOLDOWN_MET, "label": "COOL DOWN"}


## Total duration and number of work ("push") blocks in a block list, as a Vector2i
## (x = seconds, y = pushes) so the menu can show "~8 min · 6 pushes".
func _totals(blocks: Array) -> Vector2i:
	var secs: int = 0
	var pushes: int = 0
	for b in blocks:
		secs += int((b as Dictionary)["seconds"])
		if String((b as Dictionary)["kind"]) == "work":
			pushes += 1
	return Vector2i(secs, pushes)


## Eligible games that are actually available in the registry right now.
func _available_eligible() -> Array[String]:
	var out: Array[String] = []
	for id in ELIGIBLE_GAMES:
		if GameManager.is_available(id):
			out.append(id)
	return out


# --- Persistence (mirrors ActivityManager's per-profile scoping) ------------

func _load_for_active() -> void:
	var file: String = _save_file()
	if SaveManager.has_save(file):
		_data = SaveManager.load_data(file, _default_data())
	else:
		_data = _default_data()
	if not _data.has("completed"):
		_data["completed"] = {}


func _save_file() -> String:
	return "workouts_%s.json" % ProfileManager.get_active_id()


func _key_from_date(date: Dictionary) -> String:
	return "%04d-%02d-%02d" % [int(date["year"]), int(date["month"]), int(date["day"])]


func _default_data() -> Dictionary:
	return {"completed": {}}


func _save() -> void:
	SaveManager.save_data(_save_file(), _data)
