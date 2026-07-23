extends TestCase
## AchievementTest
##
## Pins the achievement pipeline end to end. It pushes one big fake GameResult
## through the REAL finish path (GameManager.finish_game → ActivityManager +
## AchievementManager handlers) on a throwaway profile, then asserts what should
## and — just as importantly — should NOT have unlocked.
##
## The negative cases carry most of the weight: an achievement that fires too
## eagerly is worse than one that never fires, because this is a fitness
## platform where the unlock is supposed to mean the player actually did the
## work. (Ported from the standalone achievement_probe scene.)


func _run() -> void:
	throwaway_profile("ach")
	AchievementManager.take_recent_unlocks()  # drop any boot-time catch-up noise

	GameManager.select_game("open_world")
	GameManager.finish_game(_session("open_world", 500, 21.0 * 60.0, 160.0, 2600))

	for id in ["first_workout", "calories_100", "session_20min",
			"session_150kcal", "session_2500steps"]:
		check("unlocks '%s' after the session" % id, ProfileManager.has_achievement(id))

	# Streaks and roster-completion must not be satisfiable by a single session,
	# however big — they exist to reward coming back, not one heroic run.
	check_eq("does NOT unlock 'streak_3' on day one",
			ProfileManager.has_achievement("streak_3"), false)
	check_eq("does NOT unlock 'all_games' after one game",
			ProfileManager.has_achievement("all_games"), false)

	var recent: Array[AchievementDef] = AchievementManager.take_recent_unlocks()
	check_eq("queues exactly the 5 new unlocks", recent.size(), 5)
	check("take_recent_unlocks() consumes the queue",
			AchievementManager.take_recent_unlocks().is_empty())

	# Discoveries come from the game folder's own achievements.tres (see
	# RegistryTest); reporting each one must persist it and roll up the capstone.
	for defn in AchievementManager.get_discoveries():
		AchievementManager.report_discovery(defn.id.trim_prefix("secret_"))
	check("persists a discovery", ProfileManager.has_achievement("secret_grotto"))
	check("unlocks 'all_secrets' once every landmark is found",
			ProfileManager.has_achievement("all_secrets"))

	# The next-goal nudge backs the "always encourage" rule: there must always be
	# something reachable to point at, even for a profile mid-run.
	var goal: Dictionary = AchievementManager.get_next_goal()
	check("offers a next goal", not goal.is_empty())
	if not goal.is_empty():
		check("the next goal names an achievement",
				not (goal["defn"] as AchievementDef).title.is_empty())
		check("the next goal is not already met",
				float(goal["value"]) < float(goal["target"]))


func _teardown() -> void:
	# The throwaway profile itself is removed by TestCase, but its activity log
	# is a separate per-profile file that would otherwise pile up.
	SaveManager.delete_save("activity_%s.json" % ProfileManager.get_active_id())


## Builds one finished session. Every field the achievement stats read is set
## explicitly, so a test failure is about the unlock rule and never about a
## field that quietly defaulted to zero.
func _session(game_id: String, score: int, duration_sec: float,
		calories: float, steps: int) -> GameResult:
	var r: GameResult = GameResult.new()
	r.game_id = game_id
	r.score = score
	r.duration_sec = duration_sec
	r.calories = calories
	r.xp_earned = score
	r.steps = steps
	return r
