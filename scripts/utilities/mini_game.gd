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

## Nodes in this group are left processing during the intro freeze. Some world
## nodes (e.g. HTerrain) build their visible mesh lazily in _process, so freezing
## them on frame one leaves them invisible behind the countdown. Scenery has no
## gameplay to pause, so a game can add such a node to this group to keep it
## rendering while everything else holds still. See [method _freeze_world].
const KEEP_PROCESSING_GROUP: StringName = &"intro_keep_processing"

var _score: int = 0
var _elapsed_sec: float = 0.0
var _running: bool = false
# The world nodes frozen while the intro overlay runs, restored at begin().
var _frozen_children: Array[Node] = []
# Set when this session was launched as a Daily Challenge (WorkoutManager): the
# interval plan being coached, and whether its timeline ran to completion. Empty
# for a normal play session.
var _workout_plan: Dictionary = {}
var _workout_completed: bool = false

## Runs the shared setup → countdown intro (if launched through the platform),
## then starts the game. Games should NOT override _ready; put game-specific
## setup in [method _start_game], which begin() calls once the count finishes.
func _ready() -> void:
	# Pre-intro world setup runs first, so the frozen scene the countdown reveals
	# already looks play-ready (e.g. the player standing at their spawn point).
	_prepare_world()
	if GameManager.take_intro_pending():
		_run_intro()
	else:
		# Opened directly (e.g. from the editor): skip the intro and just play.
		begin()


func _process(delta: float) -> void:
	if _running:
		_elapsed_sec += delta


## Shows the [GameIntro] overlay on top of this (already-loaded) game scene, with
## the world frozen on its first frame behind it, and begins gameplay once the
## player has signalled ready and the count has run.
func _run_intro() -> void:
	_freeze_world(true)
	var intro := GameIntro.new()
	add_child(intro)
	intro.intro_finished.connect(_on_intro_finished)


func _on_intro_finished() -> void:
	_freeze_world(false)
	begin()


## Freezes (or restores) every world node so the game holds still on its first
## frame while the intro plays. Rendering is unaffected — only processing/input
## are paused — so the countdown shows the real, static game behind it. Nodes in
## [constant KEEP_PROCESSING_GROUP] are left running, since some (e.g. HTerrain)
## build their visible mesh in _process and would otherwise stay invisible. The
## intro overlay is added afterwards, so it keeps running.
func _freeze_world(frozen: bool) -> void:
	if frozen:
		_frozen_children = []
		for child in get_children():
			if child.is_in_group(KEEP_PROCESSING_GROUP):
				continue
			_frozen_children.append(child)
			child.process_mode = Node.PROCESS_MODE_DISABLED
	else:
		for child in _frozen_children:
			if is_instance_valid(child):
				child.process_mode = Node.PROCESS_MODE_INHERIT
		_frozen_children.clear()


## Starts the game. Called by the platform (e.g. after the countdown). Do not
## override this; override [method _start_game] for game-specific setup.
func begin() -> void:
	_score = 0
	_elapsed_sec = 0.0
	_running = true
	# Zero the movement stats so calories/steps count only this game's activity.
	MotionManager.reset_session_stats()
	# Show the in-game corner camera + live coaching, so the player can keep an eye
	# on their framing (it hides itself when no camera is streaming). Reusable, so
	# every game gets it without any per-game code.
	add_child(GameCameraHUD.new())
	# If this session is today's Daily Challenge, overlay the interval coach on top
	# of the game and let it drive the workout (see WorkoutManager / IntervalCoach).
	_start_workout(GameManager.take_pending_workout())
	_start_game()
	started.emit()


## Starts the Daily Challenge interval coach for [param plan], if one is pending.
## The coach counts down the blocks and, when the whole timeline finishes, ends the
## session and banks the completion — so completing the intervals IS completing the
## challenge. A no-op for an ordinary play session (empty plan).
func _start_workout(plan: Dictionary) -> void:
	if plan.is_empty():
		return
	_workout_plan = plan
	var coach := IntervalCoach.new()
	coach.setup(plan)
	coach.workout_completed.connect(_on_workout_completed)
	add_child(coach)


func _on_workout_completed() -> void:
	if _workout_completed:
		return
	_workout_completed = true
	WorkoutManager.mark_today_complete()
	finish()


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
	# Bundle the session's fitness stats alongside score so the results screen can
	# show a full workout summary — all measured for free by the motion pipeline.
	var result: Dictionary = {
		"game_id": get_game_id(),
		"score": _score,
		"duration_sec": _elapsed_sec,
		"calories": calories,
		"xp_earned": int(round(_score * XP_PER_SCORE)),
		"steps": MotionManager.get_session_steps(),
		"avg_cadence": MotionManager.get_session_avg_cadence(),
		"avg_met": MotionManager.get_session_avg_met(),
		"avg_heart_rate": MotionManager.get_session_avg_heart_rate(),
		"peak_heart_rate": MotionManager.get_session_peak_heart_rate(),
	}
	# When this was a Daily Challenge, tell the results screen so it can celebrate a
	# completed workout (vs. one abandoned before the timeline finished).
	if not _workout_plan.is_empty():
		result["workout_title"] = String(_workout_plan.get("title", ""))
		result["workout_completed"] = _workout_completed
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


## Pre-intro world setup, run in _ready before the countdown. Override for
## anything that must already look right in the static scene the intro reveals
## behind it — e.g. standing the player at their spawn point. Gameplay start
## (score reset, HUD, spawning collectibles) belongs in [method _start_game],
## which runs after the count. Default does nothing.
func _prepare_world() -> void:
	pass


## Game-specific setup. Override in subclasses; default does nothing.
func _start_game() -> void:
	pass
