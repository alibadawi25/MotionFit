extends Node
## GameManager
##
## Coordinates the play session and owns the registry of available mini-games.
## The registry is DATA: adding a game to the platform is one entry here plus a
## scene that follows the MiniGame contract — no menu code changes. This is the
## key decision that lets the platform scale to 20+ games (see CONTEXT.md).
##
## It also carries session state across the Game Select -> Difficulty ->
## Countdown -> Game -> Results flow (which game, which difficulty, last result)
## and awards progression through ProfileManager when a game finishes.
##
## Depends on SceneManager (paths/navigation) and ProfileManager (progression),
## so it initialises after both.

## Emitted when the selected game changes.
signal game_selected(game_id: String)
## Emitted when a game reports its result, before navigating to results.
signal game_finished(result: Dictionary)

## Difficulty levels shared by every game. Games interpret these consistently
## (e.g. speed/spawn-rate multipliers) so the platform feels uniform.
enum Difficulty { EASY, NORMAL, HARD }

var _games: Array[Dictionary] = []
var _current_game_id: String = ""
var _difficulty: Difficulty = Difficulty.NORMAL
var _last_result: Dictionary = {}
# Set when a game is launched through the platform, so the game's MiniGame base
# knows to run the setup/countdown intro before play. A game scene opened
# directly (e.g. from the editor) sees this false and just begins. See
# [method take_intro_pending] and MiniGame._ready.
var _intro_pending: bool = false
# Set when a game is launched as today's Daily Challenge (WorkoutManager): the
# interval plan handed to the game's MiniGame base so it can overlay the coach.
# Consumed once by [method take_pending_workout]; empty for a normal launch (so a
# Play Again after a challenge is an ordinary run, not another prescribed one).
var _pending_workout: Dictionary = {}

func _ready() -> void:
	_build_registry()


## Returns the full list of registered games. Each entry is a Dictionary:
## { id, title, description, scene, available, uses_difficulty }.
func get_games() -> Array[Dictionary]:
	return _games


## Returns the registry entry for [param game_id], or an empty Dictionary.
func get_game(game_id: String) -> Dictionary:
	for game in _games:
		if game["id"] == game_id:
			return game
	return {}


## Marks [param game_id] as the active selection. No-op for unknown ids.
func select_game(game_id: String) -> void:
	if get_game(game_id).is_empty():
		push_warning("GameManager: unknown game id '%s'" % game_id)
		return
	_current_game_id = game_id
	game_selected.emit(game_id)


func get_current_game_id() -> String:
	return _current_game_id


func set_difficulty(difficulty: Difficulty) -> void:
	_difficulty = difficulty


func get_difficulty() -> Difficulty:
	return _difficulty


## Whether [param game_id] wants the difficulty-select step before starting.
## Free-roam games with no fail state (Open World) skip it; defaults to true so
## a new registry entry gets the full flow unless it opts out.
func uses_difficulty(game_id: String) -> bool:
	var game: Dictionary = get_game(game_id)
	return bool(game.get("uses_difficulty", true))


## Begins the currently selected game by loading its scene directly. The game's
## MiniGame base then runs the shared setup → countdown intro as an overlay on
## top of the loaded world (so the countdown can show the game's own first frame)
## before gameplay begins. Does nothing if no available game is selected.
func start_selected_game() -> void:
	var game: Dictionary = get_game(_current_game_id)
	if game.is_empty() or not bool(game["available"]):
		push_warning("GameManager: cannot start unavailable game '%s'" % _current_game_id)
		return
	_intro_pending = true
	SceneManager.load_scene(String(game["scene"]))


## Returns whether the just-loaded game should play the setup/countdown intro,
## clearing the flag so it fires exactly once. Called by MiniGame._ready; true
## only when reached through [method start_selected_game] (not a direct open).
func take_intro_pending() -> bool:
	var pending: bool = _intro_pending
	_intro_pending = false
	return pending


## Launches today's Daily Challenge: selects the prescribed game and difficulty,
## arms the interval plan, and starts it through the normal flow (so it still gets
## the countdown intro). No-op if no plan is available. See [WorkoutManager].
func start_daily_challenge() -> void:
	var plan: Dictionary = WorkoutManager.get_today_plan()
	if plan.is_empty():
		return
	_pending_workout = plan
	select_game(String(plan["game_id"]))
	set_difficulty(int(plan["difficulty"]))
	start_selected_game()


## Returns the interval plan for the just-loaded game and clears it, so the coach
## is shown exactly once. Called by MiniGame.begin; empty for a normal session.
func take_pending_workout() -> Dictionary:
	var plan: Dictionary = _pending_workout
	_pending_workout = {}
	return plan


## DEPRECATED. The setup/countdown is now an in-game overlay (GameIntro) shown by
## the MiniGame base, so games load directly (see [method start_selected_game]).
## Retained only so the now-unused standalone countdown_screen scene still
## resolves; safe to delete once that scene is removed.
func launch_current_game_scene() -> void:
	var game: Dictionary = get_game(_current_game_id)
	if game.is_empty():
		return
	SceneManager.load_scene(String(game["scene"]))


## Called by a running game (via the MiniGame contract) when it ends. Records
## progression (calories/XP/steps toward the profile, daily activity and
## achievements via [signal game_finished]) and stores the result for the results
## screen. [param show_results] controls where the player lands: the Results
## summary (the default, for a completed game or "End & Save"), or straight back
## to Game Select (for a "quit but keep my progress" exit). Either way the session
## is banked — leaving a game never discards the effort already measured.
func finish_game(result: Dictionary, show_results: bool = true) -> void:
	if not result.has("game_id"):
		result["game_id"] = _current_game_id
	# Snapshot progression BEFORE recording, so the results screen can show what
	# this game changed: whether the score beat the old best, and any level-up.
	var game_id: String = String(result["game_id"])
	var prev_best: int = ProfileManager.get_best_score(game_id)
	var prev_level: int = ProfileManager.get_level()
	result["new_best"] = int(result.get("score", 0)) > prev_best
	result["prev_best"] = prev_best
	result["level_before"] = prev_level
	ProfileManager.record_game_result(result)
	result["level_after"] = ProfileManager.get_level()
	result["leveled_up"] = ProfileManager.get_level() > prev_level
	result["total_xp"] = ProfileManager.get_xp()
	_last_result = result
	game_finished.emit(result)
	if show_results:
		SceneManager.load_results()
	else:
		SceneManager.load_game_select()


## Returns the most recent game result (for the results screen).
func get_last_result() -> Dictionary:
	return _last_result


func _build_registry() -> void:
	# No game has a playable scene yet; each renders as "Coming Soon" until its
	# scene exists. When you build a game at its SceneManager path, flip
	# "available" to true and it becomes launchable — no other code changes.
	_games = [
		{
			"id": "open_world",
			"title": "Open World",
			"description": "Free-roam and vibe. Move your body to explore — it counts your steps and calories the whole time.",
			"scene": SceneManager.OPEN_WORLD,
			"available": true,
			# Free-roam with no fail state — difficulty would change nothing, so
			# the flow skips straight from Game Select to the intro.
			"uses_difficulty": false,
		},
		{
			"id": "runner",
			"title": "Zombie Run",
			"description": "A zombie is chasing you — march hard to escape, jump, slide and dodge. Pure cardio panic.",
			"scene": SceneManager.RUNNER,
			"available": true,
			"uses_difficulty": true,
		},
		{
			"id": "sprint",
			"title": "Hurdle Dash",
			"description": "Race three rivals to the line — sprint on the spot and leap the hurdles. Short, breathless, all-out.",
			"scene": SceneManager.SPRINT,
			"available": true,
			"uses_difficulty": true,
		},
		{
			"id": "boxing",
			"title": "Boxing",
			"description": "Three punches — straight, wide and uppercut — and two ways to defend: hands up, or lean. No boxing experience needed. Upper-body burn.",
			"scene": SceneManager.BOXING,
			"available": true,
			"uses_difficulty": true,
		},
		{
			"id": "football",
			"title": "Football",
			"description": "Kick, dodge and score. Full-body movement.",
			"scene": SceneManager.FOOTBALL,
			"available": false,
		},
		{
			"id": "tennis",
			"title": "Tennis",
			"description": "Rally against the AI. Reflex and reach.",
			"scene": SceneManager.TENNIS,
			"available": false,
		},
	]
