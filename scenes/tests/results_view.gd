extends Node
## ResultsView
##
## Throwaway view scene for styling the Results screen (shot.sh pairing, like
## hud_view/climate_view): stages a plausible finished-session result and a
## couple of fresh achievement unlocks WITHOUT recording anything — it writes
## GameManager's/_AchievementManager's runtime fields directly rather than
## going through finish_game, so no profile stats, activity log or unlock
## state are touched — then routes to the real Results screen.

func _ready() -> void:
	GameManager.select_game("open_world")
	var result: GameResult = GameResult.new()
	result.game_id = "open_world"
	result.score = 412
	result.duration_sec = 14.0 * 60.0 + 22.0
	result.calories = 118.0
	result.xp_earned = 412
	result.steps = 1650
	result.avg_cadence = 116.0
	result.new_best = true
	result.prev_best = 305
	result.level_before = 6
	result.level_after = 6
	result.total_xp = 2360
	GameManager._last_result = result

	var pills: Array[AchievementDef] = []
	for defn in AchievementManager.get_definitions():
		if defn.id in ["session_20min", "secret_grotto"]:
			pills.append(defn)
	AchievementManager._recent_unlocks = pills
	SceneManager.load_results()
