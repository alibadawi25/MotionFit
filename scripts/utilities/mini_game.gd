extends Node
## MiniGame
##
## Base contract every mini-game's root node extends. It standardises how the
## platform starts a game, how a game reports its result, and how progression
## is computed — so all 20+ games plug into the same launcher, results screen,
## and profile systems without bespoke wiring.
##
## Subclasses override [method _start_game] and, when the game ends, call
## [method finish] with a score. Everything else (result schema, XP maths,
## handing off to GameManager) is handled here so games stay small and focused.
##
## Attach this (or a subclass) as the script on a game's root scene node.
class_name MiniGame

## Emitted the moment gameplay actually begins (after any countdown).
signal started
## Emitted when the game has ended and produced a [param result] Dictionary.
signal finished_with_result(result: Dictionary)

## XP granted per point of score. Tune per project; kept here so every game is
## rewarded on the same scale.
const XP_PER_SCORE: float = 1.0

var _score: int = 0
var _elapsed_sec: float = 0.0
var _running: bool = false

func _process(delta: float) -> void:
	if _running:
		_elapsed_sec += delta


## Starts the game. Called by the platform (e.g. after the countdown). Do not
## override this; override [method _start_game] for game-specific setup.
func begin() -> void:
	_score = 0
	_elapsed_sec = 0.0
	_running = true
	# Zero the movement stats so calories/steps count only this game's activity.
	MotionManager.reset_session_stats()
	_start_game()
	started.emit()


## Ends the game, builds the standard result, reports it to GameManager, and
## emits [signal finished_with_result]. [param calories] defaults to the value
## the motion pipeline measured for this session, so games get real calories for
## free; pass an explicit non-negative number to override.
func finish(calories: float = -1.0) -> void:
	if not _running:
		return
	_running = false
	if calories < 0.0:
		calories = MotionManager.get_session_calories()
	var result: Dictionary = {
		"game_id": get_game_id(),
		"score": _score,
		"duration_sec": _elapsed_sec,
		"calories": calories,
		"xp_earned": int(round(_score * XP_PER_SCORE)),
	}
	finished_with_result.emit(result)
	GameManager.finish_game(result)


## Adds [param points] to the running score.
func add_score(points: int) -> void:
	_score += points


func get_score() -> int:
	return _score


func get_elapsed_sec() -> float:
	return _elapsed_sec


## Returns the current difficulty selected in the launcher, so games can scale.
func get_difficulty() -> GameManager.Difficulty:
	return GameManager.get_difficulty()


## The registry id of this game. Subclasses SHOULD override to match their
## GameManager entry (e.g. "runner").
func get_game_id() -> String:
	return "unknown"


## Game-specific setup. Override in subclasses; default does nothing.
func _start_game() -> void:
	pass
