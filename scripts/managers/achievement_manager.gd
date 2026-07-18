extends Node
## AchievementManager
##
## The platform's achievement + discovery system. Definitions are DATA (one
## dictionary per achievement); unlock triggers are evaluated automatically
## after every finished game against the career stats ActivityManager /
## ProfileManager already track, so no game contains achievement code. The
## Open World's hidden landmarks surface here too: a find in-game calls
## [method report_discovery], which persists it as a "secret_*" achievement —
## so the in-game "found this session" counter can stay per-session (the walk
## is the point) while the achievements page remembers every place you have
## ever reached.
##
## Storage stays in ProfileManager (the profile owns its unlocked ids); this
## manager owns WHAT exists and WHEN it unlocks. Registered after
## ActivityManager so, when GameManager.game_finished fires, the daily log has
## already folded the session in — streaks and lifetime totals evaluated here
## therefore include the workout that just ended.

## Emitted when an achievement unlocks. [param definition] is its full entry.
signal unlocked(definition: Dictionary)

## Single source of the hidden landmarks (ids + display names); discovery
## definitions are built from it so the page can never drift from the world.
const WorldScatterScript := preload("res://scenes/open-world/world_scatter.gd")

## Treasure-hunt hints shown on the discoveries shelf BEFORE a landmark is
## found — a nudge toward the walk, not a spoiler of the exact spot.
const DISCOVERY_HINTS: Dictionary = {
	"grotto": "Something glitters inside the mountain's eastern flank.",
	"cairn": "Someone stacked stones where the air runs thin.",
	"stones": "Old giants stand in a circle on the western plateau.",
	"camp": "Driftwood and embers in a lonely beach cove.",
	"hollow": "A violet glow deep in the far-corner woods.",
}

## The career/session achievement catalog. Fields: id, title, icon (a glyph the
## UI fonts render), desc (how to earn it, phrased as encouragement), stat (see
## [method _stat_value]), target (-1 = resolved at read time, e.g. "all
## available games"), unit (for progress text). Everything here is about
## effort and consistency, never skill — this is a fitness platform.
const CAREER_DEFINITIONS: Array[Dictionary] = [
	{"id": "first_workout", "title": "FIRST MOVE", "icon": "★",
			"desc": "Finish your first workout.",
			"stat": "sessions", "target": 1.0, "unit": "workouts"},
	{"id": "sessions_5", "title": "SHOWING UP", "icon": "★",
			"desc": "Finish 5 workouts.",
			"stat": "sessions", "target": 5.0, "unit": "workouts"},
	{"id": "sessions_25", "title": "THE REGULAR", "icon": "★",
			"desc": "Finish 25 workouts.",
			"stat": "sessions", "target": 25.0, "unit": "workouts"},
	{"id": "sessions_100", "title": "PART OF YOU", "icon": "★",
			"desc": "Finish 100 workouts.",
			"stat": "sessions", "target": 100.0, "unit": "workouts"},
	{"id": "streak_3", "title": "THREE IN A ROW", "icon": "♥",
			"desc": "Work out 3 days in a row.",
			"stat": "streak", "target": 3.0, "unit": "days"},
	{"id": "streak_7", "title": "FULL WEEK", "icon": "♥",
			"desc": "Work out 7 days in a row.",
			"stat": "streak", "target": 7.0, "unit": "days"},
	{"id": "streak_14", "title": "HABIT FORMED", "icon": "♥",
			"desc": "Work out 14 days in a row.",
			"stat": "streak", "target": 14.0, "unit": "days"},
	{"id": "calories_100", "title": "FIRST BURN", "icon": "♦",
			"desc": "Burn 100 calories all-time.",
			"stat": "calories", "target": 100.0, "unit": "kcal"},
	{"id": "calories_1000", "title": "SLOW FIRE", "icon": "♦",
			"desc": "Burn 1,000 calories all-time.",
			"stat": "calories", "target": 1000.0, "unit": "kcal"},
	{"id": "calories_10000", "title": "FURNACE", "icon": "♦",
			"desc": "Burn 10,000 calories all-time.",
			"stat": "calories", "target": 10000.0, "unit": "kcal"},
	{"id": "steps_5k", "title": "FINDING YOUR FEET", "icon": "▲",
			"desc": "Take 5,000 steps all-time.",
			"stat": "steps", "target": 5000.0, "unit": "steps"},
	{"id": "steps_25k", "title": "WANDERER", "icon": "▲",
			"desc": "Take 25,000 steps all-time.",
			"stat": "steps", "target": 25000.0, "unit": "steps"},
	{"id": "steps_100k", "title": "UNSTOPPABLE", "icon": "▲",
			"desc": "Take 100,000 steps all-time.",
			"stat": "steps", "target": 100000.0, "unit": "steps"},
	{"id": "session_20min", "title": "GOING LONG", "icon": "✦",
			"desc": "Keep moving for 20 minutes in a single session.",
			"stat": "session_minutes", "target": 20.0, "unit": "min"},
	{"id": "session_150kcal", "title": "BIG BURN", "icon": "✦",
			"desc": "Burn 150 calories in a single session.",
			"stat": "session_calories", "target": 150.0, "unit": "kcal"},
	{"id": "session_2500steps", "title": "LONG HAUL", "icon": "✦",
			"desc": "Take 2,500 steps in a single session.",
			"stat": "session_steps", "target": 2500.0, "unit": "steps"},
	{"id": "level_5", "title": "RISING", "icon": "●",
			"desc": "Reach level 5.",
			"stat": "level", "target": 5.0, "unit": "levels"},
	{"id": "level_10", "title": "SEASONED", "icon": "●",
			"desc": "Reach level 10.",
			"stat": "level", "target": 10.0, "unit": "levels"},
	{"id": "all_games", "title": "TRIED EVERYTHING", "icon": "●",
			"desc": "Play every available game at least once.",
			"stat": "games_played", "target": -1.0, "unit": "games"},
]

## Stats a locked achievement can show live progress toward on the page (and be
## offered as the results screen's "next goal"). Session stats are excluded —
## outside a session there is nothing meaningful to measure them against.
const CAREER_STATS: Array[String] = [
	"sessions", "streak", "calories", "steps", "level", "games_played", "secrets",
]

## The full catalog: CAREER_DEFINITIONS + the discovery entries built at
## _ready from WorldScatter's SECRETS list.
var _definitions: Array[Dictionary] = []
## Unlocks earned since the results screen last collected them (see
## [method take_recent_unlocks]) — the queue of "not yet celebrated" wins.
var _recent_unlocks: Array[Dictionary] = []

func _ready() -> void:
	_definitions = CAREER_DEFINITIONS.duplicate()
	for secret in WorldScatterScript.SECRETS:
		var sid: String = String(secret.id)
		_definitions.append({
			"id": "secret_%s" % sid,
			"title": String(secret.name),
			"icon": "✦",
			"desc": String(DISCOVERY_HINTS.get(sid,
					"A hidden place somewhere in the Open World.")),
			"stat": "secret", "target": 1.0, "unit": "", "category": "discovery",
		})
	_definitions.append({"id": "all_secrets", "title": "CARTOGRAPHER", "icon": "✦",
			"desc": "Discover every hidden landmark in the Open World.",
			"stat": "secrets", "target": float(WorldScatterScript.SECRETS.size()),
			"unit": "found"})
	GameManager.game_finished.connect(_on_game_finished)
	# Re-check on switch (and once at boot, deferred so every manager is up):
	# a definition added in an update unlocks retroactively from stored stats.
	ProfileManager.profile_switched.connect(func(_id: String) -> void: _evaluate({}))
	_evaluate.call_deferred({})


# --- Catalog queries (for the achievements screen & results screen) ----------

## Every achievement definition, discoveries included.
func get_definitions() -> Array[Dictionary]:
	return _definitions


## Just the Open World discovery entries, in world order.
func get_discoveries() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for defn in _definitions:
		if String(defn.get("category", "")) == "discovery":
			out.append(defn)
	return out


## Whether the active profile has unlocked [param achievement_id].
func is_unlocked(achievement_id: String) -> bool:
	return ProfileManager.has_achievement(achievement_id)


## How many catalog entries the active profile has unlocked (counted against the
## catalog, so a stale stored id from an old build can't inflate it).
func get_unlocked_count() -> int:
	var count: int = 0
	for defn in _definitions:
		if is_unlocked(String(defn["id"])):
			count += 1
	return count


## Live progress toward [param defn]: { "value", "target" } (target resolved if
## the definition defers it). [param result] supplies session stats when
## evaluating a just-finished game; pass {} outside a session.
func get_progress(defn: Dictionary, result: Dictionary = {}) -> Dictionary:
	return {
		"value": _stat_value(defn, result),
		"target": _target(defn),
	}


## The most encouraging thing to chase next: the locked career achievement the
## player is CLOSEST to (highest progress ratio; nearest target on a fresh
## profile). Returns { "defn", "value", "target" }, or {} when everything career
## is unlocked. Session and discovery entries are excluded — they aren't a
## number you can watch tick up between workouts.
func get_next_goal() -> Dictionary:
	var best: Dictionary = {}
	var best_ratio: float = -1.0
	for defn in _definitions:
		if not String(defn["stat"]) in CAREER_STATS:
			continue
		if is_unlocked(String(defn["id"])):
			continue
		var p: Dictionary = get_progress(defn)
		var target: float = float(p["target"])
		if target <= 0.0:
			continue
		var ratio: float = clampf(float(p["value"]) / target, 0.0, 0.999)
		# Tie-break toward the smaller target so a new player is pointed at
		# "finish your first workout", not "take 100,000 steps".
		if ratio > best_ratio or (is_equal_approx(ratio, best_ratio)
				and not best.is_empty() and target < float(best["target"])):
			best_ratio = ratio
			best = {"defn": defn, "value": float(p["value"]), "target": target}
	return best


## Unlocks earned since this was last called, oldest first — the results screen
## collects (and thereby clears) them to show its "ACHIEVEMENT" pills. A find
## from a session that never reached Results stays queued and is celebrated on
## the next summary rather than lost.
func take_recent_unlocks() -> Array[Dictionary]:
	var out: Array[Dictionary] = _recent_unlocks.duplicate()
	_recent_unlocks.clear()
	return out


# --- Unlock triggers ---------------------------------------------------------

## Called by the Open World when the player walks into a hidden landmark.
## Persists the discovery and re-checks the meta goals that count them.
func report_discovery(secret_id: String) -> void:
	for defn in _definitions:
		if String(defn["id"]) == "secret_%s" % secret_id:
			_unlock(defn)
	_evaluate({})


func _on_game_finished(result: Dictionary) -> void:
	_evaluate(result)


## Checks every locked definition against current stats and unlocks any whose
## target is met. Discovery entries are excluded — only walking into the
## landmark itself ([method report_discovery]) can unlock those.
func _evaluate(result: Dictionary) -> void:
	if not ProfileManager.has_active():
		return
	for defn in _definitions:
		if String(defn["stat"]) == "secret":
			continue
		if is_unlocked(String(defn["id"])):
			continue
		var p: Dictionary = get_progress(defn, result)
		if float(p["target"]) > 0.0 and float(p["value"]) >= float(p["target"]):
			_unlock(defn)


func _unlock(defn: Dictionary) -> void:
	var id: String = String(defn["id"])
	if is_unlocked(id):
		return
	ProfileManager.unlock_achievement(id)
	_recent_unlocks.append(defn)
	unlocked.emit(defn)


# --- Stat plumbing -----------------------------------------------------------

## Resolves a definition's target, computing the deferred (-1) ones that depend
## on live data — e.g. "all games" tracks however many are available today.
func _target(defn: Dictionary) -> float:
	var target: float = float(defn["target"])
	if target >= 0.0:
		return target
	if String(defn["stat"]) == "games_played":
		var available: int = 0
		for game in GameManager.get_games():
			if bool(game["available"]):
				available += 1
		return float(available)
	return 0.0


## Current value of a definition's stat. Career stats read the managers that
## already own them; session_* stats read the just-finished GameResult.
func _stat_value(defn: Dictionary, result: Dictionary) -> float:
	match String(defn["stat"]):
		"sessions":
			return float(ActivityManager.get_total_sessions())
		"streak":
			return float(ActivityManager.get_streak())
		"calories":
			return ActivityManager.get_total_calories()
		"steps":
			return float(ActivityManager.get_total_steps())
		"level":
			return float(ProfileManager.get_level())
		"session_minutes":
			return float(result.get("duration_sec", 0.0)) / 60.0
		"session_calories":
			return float(result.get("calories", 0.0))
		"session_steps":
			return float(result.get("steps", 0))
		"games_played":
			var played: int = 0
			for game in GameManager.get_games():
				if bool(game["available"]) \
						and ProfileManager.get_play_count(String(game["id"])) > 0:
					played += 1
			return float(played)
		"secrets":
			var found: int = 0
			for d in get_discoveries():
				if is_unlocked(String(d["id"])):
					found += 1
			return float(found)
		"secret":
			return 1.0 if is_unlocked(String(defn["id"])) else 0.0
	return 0.0
