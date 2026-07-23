extends Node
## GameManager
##
## Coordinates the play session and owns the registry of available mini-games.
## The registry is DATA and it is DISCOVERED, not listed: at boot this scans
## `scenes/*/game.tres` and registers every [GameDef] it finds. Adding a game to
## the platform is therefore a folder containing a scene that follows the
## MiniGame contract plus its `game.tres` — no edit to this file, to SceneManager,
## or to any menu. This is the key decision that lets the platform scale to 20+
## games (see CONTEXT.md §2).
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
signal game_finished(result: GameResult)

## Difficulty levels shared by every game. Games interpret these consistently
## (e.g. speed/spawn-rate multipliers) so the platform feels uniform.
enum Difficulty { EASY, NORMAL, HARD }

## Folder scanned for games. Every direct subfolder may contribute one game by
## containing a [constant DEF_FILE]; folders without one (menus, ui, tests) are
## simply skipped, so shared scenes can live here too.
const GAMES_ROOT: String = "res://scenes/"
## The per-game definition file, kept beside the game's scene so the folder is a
## self-contained unit. See [GameDef].
const DEF_FILE: String = "game.tres"

var _games: Array[GameDef] = []
var _current_game_id: String = ""
var _difficulty: Difficulty = Difficulty.NORMAL
var _last_result: GameResult = null
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


## Returns every registered game, in launcher order. See [GameDef].
func get_games() -> Array[GameDef]:
	return _games


## Returns the [GameDef] for [param game_id], or null if no game claims that id.
## Callers that only want a field should prefer the helpers below, which already
## handle the null.
func get_game(game_id: String) -> GameDef:
	for game in _games:
		if game.id == game_id:
			return game
	return null


## The display title for [param game_id], or "" for an unknown id. Kept as a
## helper because titles are shown in several places (results, daily challenge,
## difficulty picker) that would otherwise each need their own null check.
func get_game_title(game_id: String) -> String:
	var game: GameDef = get_game(game_id)
	return game.title if game != null else ""


## Whether [param game_id] is registered AND has a playable scene.
func is_available(game_id: String) -> bool:
	var game: GameDef = get_game(game_id)
	return game != null and game.available


## Marks [param game_id] as the active selection. No-op for unknown ids.
func select_game(game_id: String) -> void:
	if get_game(game_id) == null:
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
	var game: GameDef = get_game(game_id)
	return game.uses_difficulty if game != null else true


## Begins the currently selected game by loading its scene directly. The game's
## MiniGame base then runs the shared setup → countdown intro as an overlay on
## top of the loaded world (so the countdown can show the game's own first frame)
## before gameplay begins. Does nothing if no available game is selected.
func start_selected_game() -> void:
	var game: GameDef = get_game(_current_game_id)
	if game == null or not game.available:
		push_warning("GameManager: cannot start unavailable game '%s'" % _current_game_id)
		return
	_intro_pending = true
	SceneManager.load_scene(game.scene)


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


## Called by a running game (via the MiniGame contract) when it ends. Records
## progression (calories/XP/steps toward the profile, daily activity and
## achievements via [signal game_finished]) and stores the result for the results
## screen. [param show_results] controls where the player lands: the Results
## summary (the default, for a completed game or "End & Save"), or straight back
## to Game Select (for a "quit but keep my progress" exit). Either way the session
## is banked — leaving a game never discards the effort already measured.
func finish_game(result: GameResult, show_results: bool = true) -> void:
	if result == null:
		push_error("GameManager: finish_game called with no result")
		return
	if result.game_id.is_empty():
		result.game_id = _current_game_id
	# Snapshot progression BEFORE recording, so the results screen can show what
	# this game changed: whether the score beat the old best, and any level-up.
	var prev_best: int = ProfileManager.get_best_score(result.game_id)
	var prev_level: int = ProfileManager.get_level()
	result.new_best = result.score > prev_best
	result.prev_best = prev_best
	result.level_before = prev_level
	ProfileManager.record_game_result(result)
	result.level_after = ProfileManager.get_level()
	result.leveled_up = result.level_after > prev_level
	result.total_xp = ProfileManager.get_xp()
	_last_result = result
	game_finished.emit(result)
	if show_results:
		SceneManager.load_results()
	else:
		SceneManager.load_game_select()


## Returns the most recent game result (for the results screen), or null if no
## game has finished this launch.
func get_last_result() -> GameResult:
	return _last_result


## Discovers every game by scanning [constant GAMES_ROOT] for the `game.tres`
## each game keeps beside its scene, then sorts them into launcher order. This
## is the mechanism behind "adding a game is adding data": no shared file lists
## the roster, so a new folder appears in the launcher and a deleted folder
## disappears from it, with no edit here.
func _build_registry() -> void:
	_games = []
	for path in _find_game_defs():
		var res: Resource = load(path)
		var game: GameDef = res as GameDef
		if game == null:
			push_error("GameManager: '%s' is not a GameDef resource" % path)
			continue
		if not game.is_valid():
			push_error("GameManager: '%s' is missing id/title/scene; skipped" % path)
			continue
		var clash: GameDef = get_game(game.id)
		if clash != null:
			push_error("GameManager: duplicate game id '%s' in '%s'" % [game.id, path])
			continue
		_games.append(game)
	# Curated order (gentlest on-ramp first), with id as a stable tiebreak so the
	# roster never depends on filesystem enumeration order.
	_games.sort_custom(func(a: GameDef, b: GameDef) -> bool:
		if a.sort_order != b.sort_order:
			return a.sort_order < b.sort_order
		return a.id < b.id)
	if _games.is_empty():
		push_error("GameManager: no game definitions found under '%s'" % GAMES_ROOT)


## Returns the res:// path of every `game.tres` one level under
## [constant GAMES_ROOT].
##
## [b]Exported builds need the .remap dance.[/b] With "convert text resources to
## binary" on (the export default), `game.tres` is packed as `game.tres.remap`
## pointing at a binary copy. Listing the directory in an exported build
## therefore yields the .remap name, and loading it works only after trimming
## that suffix — so a scan written against the editor alone finds an empty
## roster in the shipped game. Pinned by scenes/tests/registry_test.gd.
func _find_game_defs() -> Array[String]:
	var found: Array[String] = []
	var root: DirAccess = DirAccess.open(GAMES_ROOT)
	if root == null:
		push_error("GameManager: cannot open '%s' (error %d)"
			% [GAMES_ROOT, DirAccess.get_open_error()])
		return found
	for folder in root.get_directories():
		for candidate in [DEF_FILE, DEF_FILE + ".remap"]:
			var path: String = "%s%s/%s" % [GAMES_ROOT, folder, candidate]
			if not ResourceLoader.exists(path) and not FileAccess.file_exists(path):
				continue
			found.append(path.trim_suffix(".remap"))
			break
	return found
