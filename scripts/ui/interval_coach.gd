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
## Reusable with no per-game code: MiniGame instantiates one when a workout is
## pending, exactly like it does the camera HUD. Keyboard-only players (no camera,
## so no MET) still get the timeline and prompts — only the pass/fail verdict is
## withheld, since there is nothing to measure.
##
## Emits [signal workout_completed] once the last block finishes; MiniGame handles
## marking WorkoutManager and finishing the game.

signal workout_completed

const ACCENT := Color(1, 0.5, 0.14)
const GOOD := Color(0.45, 0.9, 0.5)
const WARN := Color(1, 0.72, 0.3)
const HARD := Color(1, 0.4, 0.4)
const REST := Color(0.5, 0.78, 1.0)
const TEXT := Color(0.96, 0.97, 0.99)
const MUTED := Color(0.72, 0.76, 0.82)
const PANEL_BG := Color(0.04, 0.05, 0.08, 0.86)
const METER_W := 360.0
const METER_H := 16.0
# Top margin that clears a game's top stat bar (~110px tall + shadow) so the
# coach panel stacks below it instead of overlapping the chips.
const STAT_BAR_CLEARANCE := 128.0
# How long to hold the "COMPLETE" flourish before ending the session.
const COMPLETE_HOLD := 1.4

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

var _phase: Label
var _timer: Label
var _verdict: Label
var _next: Label
var _progress_label: Label
var _panel: PanelContainer
var _meter: Control
var _meter_bg: ColorRect
var _meter_fill: ColorRect
var _meter_target: ColorRect
var _progress_bg: ColorRect
var _progress_fill: ColorRect

## Loads the plan. Call before adding to the tree.
func setup(plan: Dictionary) -> void:
	_blocks = plan.get("blocks", [])
	_total_sec = maxf(float(plan.get("total_sec", 1)), 1.0)
	_push_count = int(plan.get("push_count", 0))


func _ready() -> void:
	layer = 60  # above the corner camera HUD (50), below the intro overlay (100)
	_build_ui()
	_advance()  # into the first block


func _build_ui() -> void:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	_panel = PanelContainer.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.anchor_left = 0.5
	_panel.anchor_right = 0.5
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.grow_vertical = Control.GROW_DIRECTION_END
	# Sit below the game's top stat bar (every game centres one there — the Open
	# World chips, the Hurdle Dash field strip) so the coach stacks under it rather
	# than landing on top of the CALORIES/STEPS/ORBS values.
	_panel.offset_top = STAT_BAR_CLEARANCE
	var sb := StyleBoxFlat.new()
	sb.bg_color = PANEL_BG
	sb.set_corner_radius_all(14)
	sb.set_border_width_all(1)
	sb.border_color = Color(1, 1, 1, 0.12)
	sb.content_margin_left = 30.0
	sb.content_margin_right = 30.0
	sb.content_margin_top = 14.0
	sb.content_margin_bottom = 14.0
	sb.shadow_color = Color(0, 0, 0, 0.35)
	sb.shadow_size = 14
	_panel.add_theme_stylebox_override("panel", sb)
	_panel.resized.connect(func() -> void: _panel.pivot_offset = _panel.size * 0.5)
	root.add_child(_panel)

	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 6)
	_panel.add_child(box)

	var kicker := _make_label("DAILY CHALLENGE", 13, ACCENT)
	kicker.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(kicker)

	var top_row := HBoxContainer.new()
	top_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top_row.alignment = BoxContainer.ALIGNMENT_CENTER
	top_row.add_theme_constant_override("separation", 18)
	box.add_child(top_row)

	_phase = _make_label("WARM UP", 34, TEXT)
	var anton: Font = load("res://assets/fonts/Anton-Regular.ttf")
	if anton != null:
		_phase.add_theme_font_override("font", anton)
	top_row.add_child(_phase)

	_timer = _make_label("0:00", 34, ACCENT)
	if anton != null:
		_timer.add_theme_font_override("font", anton)
	top_row.add_child(_timer)

	_verdict = _make_label("", 17, MUTED)
	_verdict.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_verdict)

	box.add_child(_build_meter())

	_next = _make_label("", 14, MUTED)
	_next.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_next)

	box.add_child(_build_progress())

	_progress_label = _make_label("", 12, MUTED)
	_progress_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_progress_label)


## The effort meter: a track with a live fill (current MET) and a target marker.
## Rects are positioned each frame in [method _process] against its own size.
func _build_meter() -> Control:
	_meter = Control.new()
	_meter.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_meter.custom_minimum_size = Vector2(METER_W, METER_H)
	_meter.size_flags_horizontal = Control.SIZE_SHRINK_CENTER

	_meter_bg = ColorRect.new()
	_meter_bg.color = Color(1, 1, 1, 0.10)
	_meter_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_meter_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_meter.add_child(_meter_bg)

	_meter_fill = ColorRect.new()
	_meter_fill.color = ACCENT
	_meter_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_meter.add_child(_meter_fill)

	_meter_target = ColorRect.new()
	_meter_target.color = TEXT
	_meter_target.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_meter.add_child(_meter_target)
	return _meter


func _build_progress() -> Control:
	var bar := Control.new()
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.custom_minimum_size = Vector2(METER_W, 4)
	bar.size_flags_horizontal = Control.SIZE_SHRINK_CENTER

	_progress_bg = ColorRect.new()
	_progress_bg.color = Color(1, 1, 1, 0.10)
	_progress_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_progress_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(_progress_bg)

	_progress_fill = ColorRect.new()
	_progress_fill.color = Color(ACCENT.r, ACCENT.g, ACCENT.b, 0.75)
	_progress_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(_progress_fill)
	return bar


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
	var met: float = MotionManager.get_met()
	# Ease toward the reading so the bar and verdict stay readable.
	_met_ema = lerpf(_met_ema, met, 0.15)

	# Fill scaled so the target sits at ~70% of the track (headroom to overshoot).
	var scale_max: float = maxf(target, 1.0) / 0.7
	var w: float = _meter.size.x
	var h: float = _meter.size.y
	_meter_fill.position = Vector2(0, 0)
	_meter_fill.size = Vector2(clampf(_met_ema / scale_max, 0.0, 1.0) * w, h)
	_meter_target.position = Vector2(clampf(target / scale_max, 0.0, 1.0) * w - 1.0, -2.0)
	_meter_target.size = Vector2(2.0, h + 4.0)

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

	_meter_fill.color = color
	_verdict.text = verdict
	_verdict.add_theme_color_override("font_color", color)
	_phase.add_theme_color_override("font_color", color)


func _update_progress() -> void:
	var w: float = _progress_bg.size.x
	_progress_fill.position = Vector2(0, 0)
	_progress_fill.size = Vector2(clampf(_total_elapsed / _total_sec, 0.0, 1.0) * w, _progress_bg.size.y)
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
	_progress_fill.size = Vector2(_progress_bg.size.x, _progress_bg.size.y)
	_meter_fill.size = Vector2(_meter.size.x, _meter.size.y)
	_meter_fill.color = GOOD
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


func _make_label(text: String, size: int, color: Color) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lbl.add_theme_font_size_override("font_size", size)
	lbl.add_theme_color_override("font_color", color)
	return lbl
