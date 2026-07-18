extends Node
## AchievementProbe
##
## Headless self-test for the achievement pipeline. Run with:
##   Godot --headless --path . res://scenes/tests/achievement_probe.tscn --quit-after 40
## It creates a throwaway profile, pushes one big fake GameResult through the
## REAL finish pipeline (GameManager.finish_game → ActivityManager +
## AchievementManager handlers), reports every discovery, asserts the expected
## unlocks, then deletes the throwaway profile and its activity log and restores
## whichever profile was active before. Prints PASS/FAIL lines; exits via quit().

var _failures: int = 0

func _ready() -> void:
	# Let the managers' deferred boot work (retroactive evaluate) settle first.
	await get_tree().process_frame
	var original_active: String = ProfileManager.get_active_id()
	var pid: String = ProfileManager.create_profile("__ach_probe__")
	AchievementManager.take_recent_unlocks()  # drop any boot-time catch-up noise

	GameManager.select_game("open_world")
	GameManager.finish_game({
		"game_id": "open_world", "score": 500, "duration_sec": 21.0 * 60.0,
		"calories": 160.0, "xp_earned": 500, "steps": 2600,
	})

	for id in ["first_workout", "calories_100", "session_20min",
			"session_150kcal", "session_2500steps"]:
		_check(ProfileManager.has_achievement(id), "unlocks '%s' after the session" % id)
	_check(not ProfileManager.has_achievement("streak_3"),
			"does NOT unlock 'streak_3' on day one")
	_check(not ProfileManager.has_achievement("all_games"),
			"does NOT unlock 'all_games' after one game")

	var recent: Array[Dictionary] = AchievementManager.take_recent_unlocks()
	_check(recent.size() == 5, "queues exactly the 5 new unlocks (got %d)" % recent.size())
	_check(AchievementManager.take_recent_unlocks().is_empty(),
			"take_recent_unlocks() consumes the queue")

	for secret in AchievementManager.WorldScatterScript.SECRETS:
		AchievementManager.report_discovery(String(secret.id))
	_check(ProfileManager.has_achievement("secret_grotto"), "persists a discovery")
	_check(ProfileManager.has_achievement("all_secrets"),
			"unlocks 'all_secrets' once every landmark is found")

	var goal: Dictionary = AchievementManager.get_next_goal()
	_check(not goal.is_empty(), "offers a next goal")
	if not goal.is_empty():
		print("  next goal -> %s (%d / %d %s)" % [String(goal["defn"]["title"]),
				int(goal["value"]), int(goal["target"]), String(goal["defn"]["unit"])])

	# Cleanup: remove the probe profile + its activity log, restore the original.
	ProfileManager.delete_profile(pid)
	SaveManager.delete_save("activity_%s.json" % pid)
	if original_active != "":
		ProfileManager.select_profile(original_active)
	_check(not ProfileManager.get_active_id() == pid, "cleanup removed the probe profile")

	print("ACHIEVEMENT PROBE: %s" % ("ALL PASS" if _failures == 0 else "%d FAILURE(S)" % _failures))
	get_tree().quit(0 if _failures == 0 else 1)


func _check(ok: bool, what: String) -> void:
	_failures += 0 if ok else 1
	print("  %s  %s" % ["PASS" if ok else "FAIL", what])
