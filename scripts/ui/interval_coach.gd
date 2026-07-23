extends CanvasLayer
class_name IntervalCoach
## IntervalCoach
##
## The in-game coaching overlay for a Daily Challenge (see [WorkoutManager]). Given
## a plan's interval blocks, it runs the timeline on top of whatever game is being
## played — counting each block down, calling the next one, and coaching the player
## toward its MET target using the live effort read from [MotionManager] (the same
## estimator that drives calories). It never touches gameplay input; it just tells
## the player when to push and when to ease off, and reports when the whole workout
## is done so [MiniGame] can end the session and bank the completion.
##
## Reusable with no per-game code: MiniGame instantiates scenes/ui/interval_coach.tscn
## when a workout is pending, exactly like it does the camera HUD. Keyboard-only
## players (no camera, so no MET) still get the timeline and prompts — only the
## pass/fail verdict is withheld, since there is nothing to measure.
##
## The panel is authored in that scene (it sits below every game's top stat bar so
## it stacks under the chips rather than landing on the values); this script only
## drives its text, colours and the two [MeterBar]s. Emits [signal
## workout_completed] once the last block finishes; MiniGame handles marking
## WorkoutManager and finishing the game.

signal workout_completed

const ACCENT := Color(1, 0.5, 0.14)
const GOOD := Color(0.45, 0.9, 0.5)
const WARN := Color(1, 0.72, 0.3)
const REST := Color(0.5, 0.78, 1.0)
# How long to hold the "COMPLETE" flourish before ending the session.
const COMPLETE_HOLD := 1.4

@onready var _panel: PanelContainer = %CoachPanel
@onready var _phase: Label = %PhaseLabel
@onready var _timer: Label = %TimerLabel
@onready var _verdict: Label = %VerdictLabel
@onready var _next: Label = %NextLabel
@onready var _progress_label: Label = %ProgressLabel
@onready var _meter: MeterBar = %EffortMeter
@onready var _timeline: MeterBar = %TimelineBar

var _blocks: Array = []
var _total_sec: float = 1.0
var _push_count: int = 0

var _index: int = -1
var _block_elapsed: float = 0.0
var _total_elapsed: float = 0.0
var _completing: bool = false
var _complete_timer: float = 0.0
# Lightly smoothed effort so the verdict doesn't flicker frame-to-frame.
var _met_ema: float = 0.0

## Loads the plan. Call before adding to the tree.
func setup(plan: Dictionary) -> void:
	_blocks = plan.get("blocks", [])
	_total_sec = maxf(float(plan.get("total_sec", 1)), 1.0)
	_push_count = int(plan.get("push_count", 0))


func _ready() -> void:
	_panel.resized.connect(func() -> void: _panel.pivot_offset = _panel.size * 0.5)
	_advance()  # into the first block


func _process(delta: float) -> void:
	if _completing:
		_complete_timer -= delta
		if _complete_timer <= 0.0:
			_completing = false  # guard against a double emit
			workout_completed.emit()
		return
	if _index < 0 or _index >= _blocks.size():
		return

	_block_elapsed += delta
	_total_elapsed += delta
	var block: Dictionary = _blocks[_index]
	var remaining: float = maxf(float(block["seconds"]) - _block_elapsed, 0.0)
	_timer.text = _format_time(remaining)

	_update_effort(block)
	_update_progress()

	if _block_elapsed >= float(block["seconds"]):
		_advance()


## Reads the live effort (MotionManager MET, the same value that drives calories),
## smooths it, and renders the fill + a coaching verdict for the current block.
func _update_effort(block: Dictionary) -> void:
	var target: float = float(block["target_met"])
	var receiving: bool = MotionManager.is_receiving()
	# Ease toward the reading so the bar and verdict stay readable.
	_met_ema = lerpf(_met_ema, MotionManager.get_met(), 0.15)

	# Fill scaled so the target sits at ~70% of the track (headroom to overshoot).
	var scale_max: float = maxf(target, 1.0) / 0.7
	_meter.target = clampf(target / scale_max, 0.0, 1.0)

	var kind: String = String(block["kind"])
	var color: Color = _kind_color(kind)
	var verdict: String = ""
	# The targets are personalised to the player (see WorkoutManager), so "on target"
	# is genuinely reachable — every line here encourages the next bit of effort and
	# celebrates hitting it, never scolds. No alarming red on the work verdict.
	if kind == "work":
		if not receiving:
			verdict = "KEEP MOVING — YOU'VE GOT THIS"
			color = WARN
		elif _met_ema >= target:
			verdict = "GREAT PACE — HOLD IT"
			color = GOOD
		elif _met_ema >= target - 1.0:
			verdict = "ALMOST THERE — KEEP GOING"
			color = WARN
		else:
			verdict = "FIND A LITTLE MORE — YOU'VE GOT THIS"
			color = WARN
	elif kind == "recover":
		verdict = "EASE DOWN — CATCH YOUR BREATH"
		color = REST if (not receiving or _met_ema <= target + 1.5) else WARN
	elif kind == "warmup":
		verdict = "EASE IN — FIND YOUR RHYTHM"
	else:
		verdict = "GREAT WORK — WIND IT DOWN"

	_meter.set_fraction(_met_ema / scale_max, color)
	_verdict.text = verdict
	_verdict.add_theme_color_override("font_color", color)
	_phase.add_theme_color_override("font_color", color)


func _update_progress() -> void:
	_timeline.fraction = _total_elapsed / _total_sec
	var left: float = maxf(_total_sec - _total_elapsed, 0.0)
	var push_no: int = _work_index(_index)
	if push_no > 0:
		_progress_label.text = "Push %d / %d   ·   %s left" % [push_no, _push_count, _format_time(left)]
	else:
		_progress_label.text = "%s left" % _format_time(left)


## Moves to the next block, or begins the completion flourish past the last one.
func _advance() -> void:
	_index += 1
	_block_elapsed = 0.0
	if _index >= _blocks.size():
		_begin_complete()
		return
	var block: Dictionary = _blocks[_index]
	_phase.text = String(block["label"])
	_next.text = _next_hint()
	_pop()  # a small scale-pop marks the transition (no audio dependency)


func _begin_complete() -> void:
	_completing = true
	_complete_timer = COMPLETE_HOLD
	_phase.text = "CHALLENGE COMPLETE"
	_phase.add_theme_color_override("font_color", GOOD)
	_timer.text = "✓"
	_timer.add_theme_color_override("font_color", GOOD)
	_verdict.text = "Nice work — that's today's challenge done."
	_verdict.add_theme_color_override("font_color", GOOD)
	_next.text = ""
	_timeline.fraction = 1.0
	_meter.target = -1.0
	_meter.set_fraction(1.0, GOOD)
	_pop()


## "NEXT: RECOVER 0:30" — the upcoming block, so the player can pace ahead.
func _next_hint() -> String:
	if _index + 1 >= _blocks.size():
		return "NEXT: final cooldown, then done"
	var nxt: Dictionary = _blocks[_index + 1]
	return "NEXT: %s · %s" % [String(nxt["label"]), _format_time(float(nxt["seconds"]))]


## 1-based ordinal of a work block among the work blocks (0 for non-work), so the
## progress line can read "Push 2 / 6".
func _work_index(index: int) -> int:
	if index < 0 or index >= _blocks.size() or String(_blocks[index]["kind"]) != "work":
		return 0
	var n: int = 0
	for i in range(index + 1):
		if String(_blocks[i]["kind"]) == "work":
			n += 1
	return n


func _kind_color(kind: String) -> Color:
	match kind:
		"work": return ACCENT
		"recover": return REST
		"cooldown": return GOOD
		_: return WARN


func _pop() -> void:
	var tween := _panel.create_tween().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_panel.scale = Vector2(1.06, 1.06)
	tween.tween_property(_panel, "scale", Vector2.ONE, 0.25)


func _format_time(seconds: float) -> String:
	var total: int = int(ceil(seconds))
	return "%d:%02d" % [total / 60, total % 60]
