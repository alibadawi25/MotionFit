extends TestCase
## ProgressionTest
##
## Pins the shared progression path: the XP curve, per-game stats, and the
## [GameResult] GameManager hands the results screen.
##
## Every game funnels through [method GameManager.finish_game], so the fields it
## derives (`new_best`, `leveled_up`, `level_before`/`level_after`) are a
## contract the results screen reads for all 20+ games at once. They are also
## computed by snapshotting progression BEFORE recording it — an ordering that is
## easy to break in a refactor and produces a subtly wrong screen rather than a
## crash, so it gets assertions.


func _run() -> void:
	_check_xp_curve()
	_check_result_contract()
	_check_best_score_tracking()


## The curve is pure maths and static, so it can be checked without touching a
## profile. Level n costs BASE * n, cumulatively.
func _check_xp_curve() -> void:
	var base: int = ProfileManager.BASE_XP_PER_LEVEL
	check_eq("0 XP is level 1", ProfileManager.level_for_xp(0), 1)
	check_eq("one short of the threshold stays level 1",
			ProfileManager.level_for_xp(base - 1), 1)
	check_eq("the first threshold reaches level 2",
			ProfileManager.level_for_xp(base), 2)
	# Level 3 needs base (for L2) + base*2 (for L3).
	check_eq("the curve steepens per level",
			ProfileManager.level_for_xp(base + base * 2), 3)
	check_eq("progress within a level does not level up",
			ProfileManager.level_for_xp(base + base * 2 - 1), 2)
	# Monotonic: more XP must never mean a lower level.
	var last: int = 1
	for xp in range(0, base * 30, base / 4):
		var level: int = ProfileManager.level_for_xp(xp)
		if level < last:
			fail("the curve is monotonic", "level dropped to %d at %d XP" % [level, xp])
			return
		last = level
	check("the curve is monotonic", true)


## finish_game must describe what the session CHANGED, not what is true after it.
func _check_result_contract() -> void:
	throwaway_profile("prog")
	GameManager.select_game("runner")

	var enough_to_level: int = ProfileManager.BASE_XP_PER_LEVEL + 10
	var result: GameResult = _session("runner", 120, enough_to_level)
	result.duration_sec = 90.0
	result.calories = 40.0
	result.steps = 300
	GameManager.finish_game(result, false)
	var out: GameResult = GameManager.get_last_result()

	check_eq("the finished result is the one handed back", out, result)
	check("the first score is a new best", out.new_best)
	check_eq("previous best was zero", out.prev_best, 0)
	check_eq("level_before is the pre-session level", out.level_before, 1)
	check_eq("level_after reflects the XP just earned", out.level_after, 2)
	check("leveled_up is reported", out.leveled_up)
	check_eq("total_xp is the running total", out.total_xp, enough_to_level)

	# What the game reported must survive the trip unchanged — the derived fields
	# are added alongside it, never on top of it.
	check_eq("the game's own duration survives", out.duration_sec, 90.0)
	check_eq("the game's own calories survive", out.calories, 40.0)
	check_eq("the game's own steps survive", out.steps, 300)
	check_eq("an ordinary session is not a challenge", out.completed_challenge(), false)


## Best score must be a maximum, not "most recent" — a worse run cannot erase a
## record, and the same run must not be reported as a new best twice.
func _check_best_score_tracking() -> void:
	throwaway_profile("best")
	GameManager.select_game("sprint")

	GameManager.finish_game(_session("sprint", 200, 0), false)
	check_eq("best score recorded", ProfileManager.get_best_score("sprint"), 200)
	check_eq("play counted", ProfileManager.get_play_count("sprint"), 1)

	GameManager.finish_game(_session("sprint", 150, 0), false)
	check_eq("a worse run keeps the record", ProfileManager.get_best_score("sprint"), 200)
	check_eq("a worse run is not a new best",
			GameManager.get_last_result().new_best, false)
	check_eq("but it still counts as a play", ProfileManager.get_play_count("sprint"), 2)

	GameManager.finish_game(_session("sprint", 260, 0), false)
	check_eq("a better run raises the record", ProfileManager.get_best_score("sprint"), 260)
	check("a better run IS a new best", GameManager.get_last_result().new_best)

	# Stats are per game, so one game's record can never bleed into another's.
	check_eq("other games are unaffected", ProfileManager.get_best_score("runner"), 0)


func _teardown() -> void:
	SaveManager.delete_save("activity_%s.json" % ProfileManager.get_active_id())


## A minimal finished session for [param game_id]. Only score and XP vary across
## the best-score assertions, so the rest stays at the GameResult defaults.
func _session(game_id: String, score: int, xp_earned: int) -> GameResult:
	var r: GameResult = GameResult.new()
	r.game_id = game_id
	r.score = score
	r.xp_earned = xp_earned
	r.duration_sec = 10.0
	return r
