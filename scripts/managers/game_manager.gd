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

func _ready() -> void:
	_build_registry()


## Returns the full list of registered games. Each entry is a Dictionary:
## { id, title, description, scene, available }.
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


## Begins the currently selected game by routing to the countdown screen, which
## then loads the game scene. Does nothing if no available game is selected.
func start_selected_game() -> void:
	var game: Dictionary = get_game(_current_game_id)
	if game.is_empty() or not bool(game["available"]):
		push_warning("GameManager: cannot start unavailable game '%s'" % _current_game_id)
		return
	SceneManager.load_countdown()


## Loads the scene of the currently selected game. Called by the countdown
## screen once the count reaches zero.
func launch_current_game_scene() -> void:
	var game: Dictionary = get_game(_current_game_id)
	if game.is_empty():
		return
	SceneManager.load_scene(String(game["scene"]))


## Called by a running game (via the MiniGame contract) when it ends. Records
## progression, stores the result for the results screen, and navigates there.
func finish_game(result: Dictionary) -> void:
	if not result.has("game_id"):
		result["game_id"] = _current_game_id
	_last_result = result
	ProfileManager.record_game_result(result)
	game_finished.emit(result)
	SceneManager.load_results()


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
		},
		{
			"id": "runner",
			"title": "Infinite Runner",
			"description": "Dodge and dash to a rhythm. Great cardio warm-up.",
			"scene": SceneManager.RUNNER,
			"available": false,
		},
		{
			"id": "boxing",
			"title": "Boxing",
			"description": "Throw punches to hit targets. Upper-body burn.",
			"scene": SceneManager.BOXING,
			"available": false,
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
