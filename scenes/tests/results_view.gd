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
	GameManager._last_result = {
		"game_id": "open_world", "score": 412, "duration_sec": 14.0 * 60.0 + 22.0,
		"calories": 118.0, "xp_earned": 412, "steps": 1650, "avg_cadence": 116.0,
		"avg_heart_rate": 0.0, "peak_heart_rate": 0.0,
		"new_best": true, "prev_best": 305, "leveled_up": false,
		"level_before": 6, "level_after": 6, "total_xp": 2360,
	}
	var pills: Array[Dictionary] = []
	for defn in AchievementManager.get_definitions():
		if String(defn["id"]) in ["session_20min", "secret_grotto"]:
			pills.append(defn)
	AchievementManager._recent_unlocks = pills
	SceneManager.load_results()
