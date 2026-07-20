extends Node
## BoxingCinematic
##
## The Boxing game's opening title sequence: a sweeping, skippable, letterboxed
## camera tour of the arena that plays the moment a session begins — before any
## gameplay. It sells the occasion by orbiting the set the arena already owns:
##
##   1. a high establishing crane over the lit ring and the packed bowl,
##   2. a low sweep along the grandstand as the crowd rises to their feet,
##   3. a climb up to the centre-hung jumbotron, main-event card on its screens,
##   4. a glide in through the competitors' tunnel, down the red walkway,
##   5. a hero arc around the ropes that settles into the exact ringside frame
##      the fight is watched from — bars retracting as the movie becomes the game.
##
## It's a director, not a world: [BoxingGame] hands it the camera and the arena
## it already built, plus the camera's gameplay pose to settle into. Each frame it
## advances a fixed shot list — lerping camera position, look-target and FOV — and
## drives the crowd's energy up from a murmur to a roar so the arena comes alive
## under the move. Skip with SPACE (testers) or by raising both hands for a beat
## (players mid-workout have no keyboard); either jumps straight to the settled
## ringside frame and emits [signal finished].
class_name BoxingCinematic

## Emitted once, when the sequence ends or is skipped; the camera is already in
## its ringside gameplay pose when this fires.
signal finished

## Letterbox bar height in design pixels (1920×1080 canvas_items stretch).
const BAR_H: float = 132.0
## Opening fade-up from black, for a clean cut from the GET-READY overlay.
const FADE_IN_SEC: float = 0.7
## How long both hands must be held up to skip (armed only after they've been
## seen down once — the player may still have them up from the countdown).
const SKIP_HOLD_SEC: float = 0.7

const ACCENT: Color = Color(0.96, 0.79, 0.28)   # gold — the marquee
const HOT: Color = Color(0.92, 0.30, 0.22)      # ring red
const COOL: Color = Color(0.56, 0.72, 1.0)      # arena blue
const MUTED: Color = Color(0.72, 0.74, 0.82)

var _camera: Camera3D
var _arena: BoxingArena
var _settle_pos: Vector3
var _settle_look: Vector3
var _settle_fov: float = 58.0

# The shot list (built in setup so the final shot can end on the gameplay pose).
# Each shot: dur, pa/pb (camera position), la/lb (look target), fa/fb (FOV),
# energy (resting crowd 0..1), cheer (one-off surge on entry, 0 = none),
# title + tcol.
var _shots: Array = []
var _shot: int = 0
var _t: float = 0.0          # time within the current shot
var _elapsed: float = 0.0    # time since the cinematic began
var _finished: bool = false
var _hands_armed: bool = false
var _hands_hold: float = 0.0

var _layer: CanvasLayer
var _bar_top: ColorRect
var _bar_bottom: ColorRect
var _flash_rect: ColorRect
var _fade: ColorRect
var _title: Label
var _hint: Label


## Hands over the scene's camera and the arena set, plus the ringside camera pose
## the final shot should settle into. Call right after add_child; the sequence
## starts on the next frame.
func setup(camera: Camera3D, arena: BoxingArena, settle_pos: Vector3,
		settle_look: Vector3, settle_fov: float) -> void:
	_camera = camera
	_arena = arena
	_settle_pos = settle_pos
	_settle_look = settle_look
	_settle_fov = settle_fov
	_build_shots()
	_build_ui()
	_enter_shot(0)


## The storyboard. Positions stay inside the front row (radius < 11) near the
## floor or climb high over the bowl; look-targets past the ring frame the crowd
## and the jumbotron so each move reveals a different part of the set.
func _build_shots() -> void:
	_shots = [
		{  # 1 — establishing: high crane over the lit ring and the full bowl
			dur = 3.6,
			pa = Vector3(7.5, 15.5, 13.5), pb = Vector3(5.2, 11.0, 10.5),
			la = Vector3(0.0, 3.5, 0.0), lb = Vector3(0.0, 2.4, 0.0),
			fa = 64.0, fb = 58.0, energy = 0.14, cheer = 0.0,
			title = "FIGHT NIGHT", tcol = ACCENT,
		},
		{  # 2 — the house: a low sweep along the grandstand, crowd on their feet
			dur = 3.6,
			pa = Vector3(-9.4, 5.6, -6.4), pb = Vector3(-9.6, 4.6, 6.4),
			la = Vector3(-16.0, 8.0, -10.0), lb = Vector3(-16.0, 6.5, 10.0),
			fa = 60.0, fb = 62.0, energy = 0.40, cheer = 0.55,
			title = "A SOLD-OUT HOUSE", tcol = COOL,
		},
		{  # 3 — the marquee: climb up to the centre-hung jumbotron screen
			dur = 3.0,
			pa = Vector3(11.8, 7.6, 4.4), pb = Vector3(10.2, 10.4, 1.8),
			la = Vector3(3.4, 11.3, 0.0), lb = Vector3(3.4, 11.9, 0.0),
			fa = 58.0, fb = 54.0, energy = 0.46, cheer = 0.0,
			title = "TONIGHT — THE MAIN EVENT", tcol = ACCENT,
		},
		{  # 4 — the walk: glide in through the tunnel, down the red carpet
			dur = 3.4,
			pa = Vector3(0.0, 3.2, -14.4), pb = Vector3(0.0, 2.5, -8.4),
			la = Vector3(0.0, 1.7, 0.0), lb = Vector3(0.0, 1.5, 0.0),
			fa = 60.0, fb = 66.0, energy = 0.62, cheer = 0.55,
			title = "MAKE YOUR WALK", tcol = HOT,
		},
		{  # 5 — the corner: arc around the ropes, settle into the ringside frame
			dur = 2.4,
			pa = Vector3(6.2, 3.4, 7.6), pb = _settle_pos,
			la = Vector3(0.0, 1.5, 0.0), lb = _settle_look,
			fa = 62.0, fb = _settle_fov, energy = 0.80, cheer = 0.7,
			title = "LET'S BOX", tcol = HOT,
		},
	]


func _process(delta: float) -> void:
	if _finished or _shots.is_empty():
		return
	if _camera == null or not is_instance_valid(_arena):
		_finish()
		return
	_elapsed += delta
	_t += delta
	var shot: Dictionary = _shots[_shot]
	while _t >= float(shot["dur"]):
		_t -= float(shot["dur"])
		_shot += 1
		if _shot >= _shots.size():
			_finish()
			return
		_enter_shot(_shot)
		shot = _shots[_shot]
	_apply_camera(shot)
	_tick_skip_gesture(delta)


## Per-shot beats that aren't plain camera moves: set the resting crowd energy for
## the shot, fire its cheer surge, and swap the title card (a cold pop sells the
## hard cut).
func _enter_shot(index: int) -> void:
	var shot: Dictionary = _shots[index]
	if is_instance_valid(_arena):
		_arena.set_crowd_energy(float(shot["energy"]))
		var cheer: float = float(shot["cheer"])
		if cheer > 0.0:
			_arena.cheer_burst(cheer)
	if index > 0:
		_flash(COOL, 0.16)
	_set_card(String(shot["title"]), shot["tcol"])
	if index == _shots.size() - 1:
		_retract_frame()


## Eased camera move for the current shot: position, look target and FOV all lerp
## between the shot's endpoints.
func _apply_camera(shot: Dictionary) -> void:
	var u: float = smoothstep(0.0, 1.0, _t / float(shot["dur"]))
	_camera.global_position = (shot["pa"] as Vector3).lerp(shot["pb"] as Vector3, u)
	_camera.look_at((shot["la"] as Vector3).lerp(shot["lb"] as Vector3, u), Vector3.UP)
	_camera.fov = lerpf(float(shot["fa"]), float(shot["fb"]), u)


## Raise-both-hands skip, for players standing at the camera with no keyboard.
## Armed only once the hands have been seen DOWN — they may still be up from the
## countdown, and that mustn't skip the movie instantly.
func _tick_skip_gesture(delta: float) -> void:
	if _elapsed < 1.0:
		return
	if not MotionManager.is_hands_up():
		_hands_armed = true
		_hands_hold = 0.0
		return
	if not _hands_armed:
		return
	_hands_hold += delta
	if _hands_hold >= SKIP_HOLD_SEC:
		_finish()


func _unhandled_input(event: InputEvent) -> void:
	if not _finished and event.is_action_pressed("ui_accept"):
		_finish()
		get_viewport().set_input_as_handled()


## Ends the sequence (naturally or skipped): snaps the camera to its ringside pose,
## leaves the crowd at a live roar and frees everything after emitting
## [signal finished]. Idempotent, so a skip racing the natural end is safe.
func _finish() -> void:
	if _finished:
		return
	_finished = true
	if is_instance_valid(_arena):
		_arena.set_crowd_energy(0.5)
	if is_instance_valid(_camera):
		_camera.global_position = _settle_pos
		_camera.look_at(_settle_look, Vector3.UP)
		_camera.fov = _settle_fov
	finished.emit()
	queue_free()


# --- overlay (letterbox, cards, flashes) --------------------------------------

func _build_ui() -> void:
	var anton: Font = load("res://assets/fonts/Anton-Regular.ttf")
	_layer = CanvasLayer.new()
	_layer.layer = 90  # over the game (and corner camera), under GameIntro's 100
	add_child(_layer)

	# Flash sheet first so the letterbox bars stay black over it.
	_flash_rect = ColorRect.new()
	_flash_rect.color = Color(1, 1, 1, 0.0)
	_flash_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_flash_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(_flash_rect)

	# Title card, riding just above the bottom bar.
	_title = Label.new()
	_title.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_title.offset_top = -(BAR_H + 118.0)
	_title.offset_bottom = -(BAR_H + 44.0)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	if anton != null:
		_title.add_theme_font_override("font", anton)
	_title.add_theme_font_size_override("font_size", 46)
	_title.add_theme_constant_override("outline_size", 10)
	_title.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_title.add_theme_constant_override("shadow_offset_x", 2)
	_title.add_theme_constant_override("shadow_offset_y", 4)
	_title.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.7))
	_title.modulate.a = 0.0
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(_title)

	# Skip hint, tucked bottom-right above the bar; fades in after a beat.
	_hint = Label.new()
	_hint.text = "RAISE BOTH HANDS  ·  OR PRESS SPACE  —  SKIP ▸"
	_hint.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_hint.offset_top = -(BAR_H + 54.0)
	_hint.offset_bottom = -(BAR_H + 18.0)
	_hint.offset_right = -48.0
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_hint.add_theme_font_size_override("font_size", 17)
	_hint.add_theme_color_override("font_color", MUTED)
	_hint.modulate.a = 0.0
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(_hint)
	var hint_tween := create_tween()
	hint_tween.tween_interval(1.4)
	hint_tween.tween_property(_hint, "modulate:a", 0.85, 0.5)

	# Letterbox bars slide in from the edges.
	_bar_top = _bar(Control.PRESET_TOP_WIDE)
	_bar_bottom = _bar(Control.PRESET_BOTTOM_WIDE)
	var bars := create_tween().set_parallel(true)
	bars.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	bars.tween_property(_bar_top, "offset_bottom", BAR_H, 0.8)
	bars.tween_property(_bar_bottom, "offset_top", -BAR_H, 0.8)

	# Fade up from black on top of everything, for a clean hand-off from GET READY.
	_fade = ColorRect.new()
	_fade.color = Color(0, 0, 0, 1.0)
	_fade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(_fade)
	create_tween().tween_property(_fade, "color:a", 0.0, FADE_IN_SEC)


## One zero-height letterbox bar pinned to a screen edge (grown by tween).
func _bar(preset: int) -> ColorRect:
	var bar := ColorRect.new()
	bar.color = Color.BLACK
	bar.set_anchors_preset(preset)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(bar)
	return bar


## Slides the letterbox away and fades the hint, as the final shot settles into
## the ringside frame — the movie dissolves into the game.
func _retract_frame() -> void:
	var tween := create_tween().set_parallel(true)
	tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	tween.tween_property(_bar_top, "offset_bottom", 0.0, 1.0)
	tween.tween_property(_bar_bottom, "offset_top", 0.0, 1.0)
	tween.tween_property(_hint, "modulate:a", 0.0, 0.4)


## Swaps the title card: empty text fades the card out, otherwise the new line
## fades in over the cut.
func _set_card(text: String, color: Color) -> void:
	if _title == null:
		return
	if text.is_empty():
		create_tween().tween_property(_title, "modulate:a", 0.0, 0.4)
		return
	_title.text = text
	_title.add_theme_color_override("font_color", color)
	_title.modulate.a = 0.0
	create_tween().tween_property(_title, "modulate:a", 1.0, 0.5)


## A quick full-screen tint spike sold on each cut (cool by default, warm on a
## cheer surge if a caller wants one later).
func _flash(color: Color, peak: float) -> void:
	if _flash_rect == null:
		return
	_flash_rect.color = Color(color.r, color.g, color.b, 0.0)
	var tween := create_tween()
	tween.tween_property(_flash_rect, "color:a", peak, 0.05)
	tween.tween_property(_flash_rect, "color:a", 0.0, 0.4)
