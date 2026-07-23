extends Node
## AchievementManager
##
## The platform's achievement + discovery system. Definitions are DATA — typed
## [AchievementDef] resources grouped into [AchievementSet] `.tres` files, so the
## catalogue is inspector-editable and a mistyped field is a load error rather
## than a silent miss at unlock time; unlock triggers are evaluated automatically
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
signal unlocked(definition: AchievementDef)

## The platform's own career/session catalogue.
const CAREER_SET: String = "res://data/achievements/career.tres"
## Filename a game folder uses to contribute its own achievements. Games are
## scanned for this the same way GameManager scans for `game.tres`, so the
## platform never names an individual game or reaches into its gameplay scripts —
## see [method _collect_game_definitions].
const GAME_ACHIEVEMENTS_FILE: String = "achievements.tres"

## Stats a locked achievement can show live progress toward on the page (and be
## offered as the results screen's "next goal"). Session stats are excluded —
## outside a session there is nothing meaningful to measure them against.
const CAREER_STATS: Array[String] = [
	"sessions", "streak", "calories", "steps", "level", "games_played", "secrets",
]

## The full catalog: the career set plus every discovery entry contributed by a
## game folder (see [method _collect_game_definitions]).
var _definitions: Array[AchievementDef] = []
## Unlocks earned since the results screen last collected them (see
## [method take_recent_unlocks]) — the queue of "not yet celebrated" wins.
var _recent_unlocks: Array[AchievementDef] = []

func _ready() -> void:
	_definitions = _load_set(CAREER_SET)
	_definitions.append_array(_collect_game_definitions())
	GameManager.game_finished.connect(_on_game_finished)
	# Re-check on switch (and once at boot, deferred so every manager is up):
	# a definition added in an update unlocks retroactively from stored stats.
	ProfileManager.profile_switched.connect(func(_id: String) -> void: _evaluate(null))
	_evaluate.call_deferred(null)


## Gathers the achievements every registered game contributes, by loading the
## optional `achievements.tres` beside its scene. A game without the file simply
## adds nothing.
##
## This is the inversion that keeps the platform independent of its content: the
## catalogue is assembled FROM the games rather than hardcoded here, so a new
## game ships its own achievements and a deleted game takes them with it. They
## are plain data, so the achievements page can list every landmark without ever
## loading a game's world.
func _collect_game_definitions() -> Array[AchievementDef]:
	var out: Array[AchievementDef] = []
	for game in GameManager.get_games():
		var path: String = game.scene.get_base_dir().path_join(GAME_ACHIEVEMENTS_FILE)
		if not ResourceLoader.exists(path):
			continue
		out.append_array(_load_set(path))
	return out


## Loads one [AchievementSet] and returns its entries, complaining loudly about a
## file that is missing, the wrong type, or holding an entry with no id — all of
## which would otherwise show up as an achievement that silently never unlocks.
func _load_set(path: String) -> Array[AchievementDef]:
	var out: Array[AchievementDef] = []
	var res: Resource = load(path)
	var set_res: AchievementSet = res as AchievementSet
	if set_res == null:
		push_error("AchievementManager: '%s' is not an AchievementSet" % path)
		return out
	for defn in set_res.achievements:
		if defn == null or defn.id.is_empty() or defn.stat.is_empty():
			push_error("AchievementManager: '%s' holds an incomplete entry" % path)
			continue
		out.append(defn)
	return out


# --- Catalog queries (for the achievements screen & results screen) ----------

## Every achievement definition, discoveries included.
func get_definitions() -> Array[AchievementDef]:
	return _definitions


## Just the hidden-landmark entries, in world order.
func get_discoveries() -> Array[AchievementDef]:
	var out: Array[AchievementDef] = []
	for defn in _definitions:
		if defn.is_discovery():
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
		if is_unlocked(defn.id):
			count += 1
	return count


## Live progress toward [param defn]: { "value", "target" } (target resolved if
## the definition defers it). [param result] supplies session stats when
## evaluating a just-finished game; pass {} outside a session.
func get_progress(defn: AchievementDef, result: GameResult = null) -> Dictionary:
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
		if not defn.stat in CAREER_STATS:
			continue
		if is_unlocked(defn.id):
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
func take_recent_unlocks() -> Array[AchievementDef]:
	var out: Array[AchievementDef] = _recent_unlocks.duplicate()
	_recent_unlocks.clear()
	return out


# --- Unlock triggers ---------------------------------------------------------

## Called by the Open World when the player walks into a hidden landmark.
## Persists the discovery and re-checks the meta goals that count them.
func report_discovery(secret_id: String) -> void:
	for defn in _definitions:
		if defn.id == "secret_%s" % secret_id:
			_unlock(defn)
	_evaluate(null)


func _on_game_finished(result: GameResult) -> void:
	_evaluate(result)


## Checks every locked definition against current stats and unlocks any whose
## target is met. Discovery entries are excluded — only walking into the
## landmark itself ([method report_discovery]) can unlock those.
func _evaluate(result: GameResult) -> void:
	if not ProfileManager.has_active():
		return
	for defn in _definitions:
		if defn.stat == "secret":
			continue
		if is_unlocked(defn.id):
			continue
		var p: Dictionary = get_progress(defn, result)
		if float(p["target"]) > 0.0 and float(p["value"]) >= float(p["target"]):
			_unlock(defn)


func _unlock(defn: AchievementDef) -> void:
	if is_unlocked(defn.id):
		return
	ProfileManager.unlock_achievement(defn.id)
	_recent_unlocks.append(defn)
	unlocked.emit(defn)


# --- Stat plumbing -----------------------------------------------------------

## Resolves a definition's target, computing the deferred (-1) ones that depend
## on live data — e.g. "all games" tracks however many are available today.
func _target(defn: AchievementDef) -> float:
	if not defn.has_deferred_target():
		return defn.target
	if defn.stat == "games_played":
		var available: int = 0
		for game in GameManager.get_games():
			if game.available:
				available += 1
		return float(available)
	return 0.0


## Current value of a definition's stat. Career stats read the managers that
## already own them; session_* stats read the just-finished GameResult.
func _stat_value(defn: AchievementDef, result: GameResult) -> float:
	match defn.stat:
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
			return (result.duration_sec / 60.0) if result != null else 0.0
		"session_calories":
			return result.calories if result != null else 0.0
		"session_steps":
			return float(result.steps) if result != null else 0.0
		"games_played":
			var played: int = 0
			for game in GameManager.get_games():
				if game.available and ProfileManager.get_play_count(game.id) > 0:
					played += 1
			return float(played)
		"secrets":
			var found: int = 0
			for d in get_discoveries():
				if is_unlocked(d.id):
					found += 1
			return float(found)
		"secret":
			return 1.0 if is_unlocked(defn.id) else 0.0
	return 0.0
