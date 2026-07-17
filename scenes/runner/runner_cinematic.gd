extends Node
## RunnerCinematic
##
## Zombie Run's opening title sequence: a short, skippable, letterboxed camera
## pass that plays the moment the countdown hands the scene over — before the
## briefing card. It sells the fantasy in three beats:
##
##   1. the graveyard at midnight (crane up toward the moon, distant lightning),
##   2. the zombie — a slow push-in on its glowing eyes, then a lunge AT the lens,
##   3. your runner, jogging and ready, the pursuer's eyes glinting in the fog
##      behind them — then the camera glides into its exact gameplay frame and
##      retracts the bars, so the briefing begins from the shot the chase is
##      played in. No teleport, no cut: the movie ends where the game starts.
##
## It's a director, not a world: runner.gd hands it the camera and the actors it
## already owns (player, zombie, track) plus the camera's gameplay pose to settle
## into. Each frame it advances a fixed shot list — lerping camera position,
## look-target and FOV per shot — and gently scrolls the scenery so the shamble
## and the hero jog read as real motion (the treadmill trick the whole game runs
## on). Skip with SPACE (testers) or by raising both hands for a beat (players
## mid-workout have no keyboard); either jumps straight to the settled gameplay
## frame and emits [signal finished].
class_name RunnerCinematic

## Emitted once, when the sequence ends or is skipped; the camera is already in
## its gameplay pose and the zombie is shambling again when this fires.
signal finished

## Letterbox bar height in design pixels (1920×1080 canvas_items stretch).
const BAR_H: float = 132.0
## Opening fade-up from black, so the cut from the GO! overlay lands clean.
const FADE_IN_SEC: float = 0.7
## How long both hands must be held up to skip (armed only after they've been
## seen down once — the player just held them up to start the countdown).
const SKIP_HOLD_SEC: float = 0.7

const COLD_FLASH: Color = Color(0.7, 0.8, 1.0)
const RED_FLASH: Color = Color(0.85, 0.08, 0.05)

var _camera: Camera3D
var _player: RunnerPlayer
var _zombie: RunnerZombie
var _track: RunnerTrack
var _audio: RunnerAudio
var _settle_pos: Vector3
var _settle_look: Vector3
var _settle_fov: float = 74.0

# The shot list (built in setup so the final shot can end on the gameplay pose).
# Each shot: dur, pa/pb (camera position), la/lb (look target), fa/fb (FOV),
# scroll (world m/s), pace (runner stride 0..1), shake (peak jitter), title+tcol.
var _shots: Array = []
var _shot: int = 0
var _t: float = 0.0          # time within the current shot
var _elapsed: float = 0.0    # time since the cinematic began
var _finished: bool = false
var _lightning_done: bool = false
var _lunge_flash_done: bool = false
var _hands_armed: bool = false
var _hands_hold: float = 0.0

var _layer: CanvasLayer
var _bar_top: ColorRect
var _bar_bottom: ColorRect
var _flash_rect: ColorRect
var _fade: ColorRect
var _title: Label
var _hint: Label


## Hands over the scene's camera and actors (including its sound director, so the
## movie is scored by the same voices the chase uses) plus the gameplay camera
## pose the final shot should settle into. Call right after add_child; the
## sequence starts on the next frame.
func setup(camera: Camera3D, player: RunnerPlayer, zombie: RunnerZombie,
		track: RunnerTrack, audio: RunnerAudio, settle_pos: Vector3,
		settle_look: Vector3, settle_fov: float) -> void:
	_camera = camera
	_player = player
	_zombie = zombie
	_track = track
	_audio = audio
	_settle_pos = settle_pos
	_settle_look = settle_look
	_settle_fov = settle_fov
	_build_shots()
	_build_ui()
	_enter_shot(0)


## The storyboard. The zombie stays at its gameplay spot (0,0,15) facing down
## the track (-Z), so its face is shot from a camera between it and the player
## looking back up (+Z); the hero shot frames the runner from front-left with
## those glowing eyes small in the fog behind — the whole chase in one image.
func _build_shots() -> void:
	_shots = [
		{  # 1 — establishing: crane up from the track toward the moon
			dur = 3.2,
			pa = Vector3(4.0, 1.5, 5.0), pb = Vector3(2.8, 2.8, 1.2),
			la = Vector3(-26.0, 12.0, -48.0), lb = Vector3(-24.0, 9.0, -46.0),
			fa = 78.0, fb = 70.0, scroll = 3.0, pace = 0.0, shake = 0.0,
			title = "MIDNIGHT. THE GRAVEYARD ROAD.", tcol = RunnerHud.MUTED,
		},
		{  # 2 — the reveal: slow push-in on the zombie's face
			dur = 3.0,
			pa = Vector3(1.7, 1.05, 10.8), pb = Vector3(0.7, 1.5, 12.6),
			la = Vector3(0.0, 1.25, 15.0), lb = Vector3(0.0, 1.6, 15.0),
			fa = 68.0, fb = 52.0, scroll = 2.0, pace = 0.2, shake = 0.06,
			title = "SOMETHING HUNGRY HAS YOUR SCENT", tcol = RunnerHud.DANGER,
		},
		{  # 3 — the scare: it lunges at the lens (shake ramps, red flash)
			dur = 1.5,
			pa = Vector3(0.35, 1.55, 12.4), pb = Vector3(0.3, 1.5, 12.9),
			la = Vector3(0.0, 1.5, 14.8), lb = Vector3(0.0, 1.5, 14.8),
			fa = 52.0, fb = 60.0, scroll = 0.0, pace = 0.4, shake = 0.5,
			title = "", tcol = RunnerHud.TEXT,
		},
		{  # 4 — the hero: arc around the jogging runner, eyes glinting behind
			dur = 2.8,
			pa = Vector3(-2.9, 1.6, -4.2), pb = Vector3(-2.0, 2.0, 2.5),
			la = Vector3(0.0, 1.05, 0.2), lb = Vector3(0.0, 1.2, -0.4),
			fa = 62.0, fb = 68.0, scroll = 9.5, pace = 0.55, shake = 0.0,
			title = "RUN — AND DON'T STOP", tcol = RunnerHud.ACCENT,
		},
		{  # 5 — settle: glide into the exact gameplay frame, bars retract
			dur = 1.4,
			pa = Vector3(-1.7, 1.9, 2.3), pb = _settle_pos,
			la = Vector3(0.0, 1.25, -0.4), lb = _settle_look,
			fa = 66.0, fb = _settle_fov, scroll = 8.0, pace = 0.5, shake = 0.0,
			title = "", tcol = RunnerHud.TEXT,
		},
	]


func _process(delta: float) -> void:
	if _finished or _shots.is_empty():
		return
	if _camera == null or _player == null or _zombie == null or _track == null:
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
	# Keep the world alive: gentle scenery scroll makes the in-place shamble and
	# jog read as locomotion, exactly like gameplay's treadmill.
	_track.scroll(delta, float(shot["scroll"]), false)
	_player.tick(delta, float(shot["pace"]))
	_tick_events()
	_tick_skip_gesture(delta)


## Per-shot beats that aren't plain camera moves. Cuts between shots are hard
## cuts sold with a cold lightning pop, in keeping with the storm.
func _enter_shot(index: int) -> void:
	match index:
		1:
			_flash(COLD_FLASH, 0.3)
			_zombie.set_urgency(0.25)
		2:
			_zombie.lunge()
		3:
			_zombie.recover()
			_zombie.set_urgency(0.2)
			_flash(COLD_FLASH, 0.22)
		4:
			_retract_frame()
	var shot: Dictionary = _shots[index]
	_set_card(String(shot["title"]), shot["tcol"])


## Eased camera move for the current shot: position, look target and FOV all
## lerp between the shot's endpoints; shake ramps in over the shot (only the
## lunge uses it, so the grab lands with a jolt).
func _apply_camera(shot: Dictionary) -> void:
	var u: float = smoothstep(0.0, 1.0, _t / float(shot["dur"]))
	var pos: Vector3 = (shot["pa"] as Vector3).lerp(shot["pb"] as Vector3, u)
	var amp: float = float(shot["shake"]) * u
	if amp > 0.0:
		pos += Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), 0.0) * amp * 0.25
	_camera.global_position = pos
	_camera.look_at((shot["la"] as Vector3).lerp(shot["lb"] as Vector3, u), Vector3.UP)
	_camera.fov = lerpf(float(shot["fa"]), float(shot["fb"]), u)


## One-off beats timed within a shot: the establishing shot's distant lightning,
## and the red slam as the lunge reaches the lens. Both are scored — the storm
## rolls in behind its flash, and the grab arrives with the full scream, the one
## sound the run otherwise saves for being caught.
func _tick_events() -> void:
	if _shot == 0 and not _lightning_done and _t >= 1.1:
		_lightning_done = true
		_lightning()
		if _audio != null:
			_audio.lightning()
	if _shot == 2 and not _lunge_flash_done and _t >= 0.45:
		_lunge_flash_done = true
		_flash(RED_FLASH, 0.4)
		if _audio != null:
			_audio.scream()


## Raise-both-hands skip, for players standing at the camera with no keyboard.
## Armed only once the hands have been seen DOWN — the player just held them up
## to start the countdown, and that mustn't skip the movie instantly.
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


## Ends the sequence (naturally or skipped): snaps the camera to its gameplay
## pose, hands back a shambling zombie, silences the movie's own sounds and frees
## everything after emitting [signal finished]. Idempotent, so a skip racing the
## natural end is safe.
func _finish() -> void:
	if _finished:
		return
	_finished = true
	# A skip mid-scare would otherwise leave the scream or the thunder rolling on
	# under the briefing card, seconds after the shot they belonged to is gone.
	if is_instance_valid(_audio):
		_audio.hush()
	if is_instance_valid(_zombie):
		_zombie.recover()
		_zombie.set_urgency(0.2)
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
	_title.add_theme_font_override("font", anton)
	_title.add_theme_font_size_override("font_size", 42)
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
	_hint.add_theme_color_override("font_color", RunnerHud.MUTED)
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

	# Fade up from black on top of everything, for a clean hand-off from GO!.
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
## the gameplay frame — the movie dissolves into the game.
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


## A quick full-screen tint spike (cold for cuts/lightning, red for the lunge).
func _flash(color: Color, peak: float) -> void:
	if _flash_rect == null:
		return
	_flash_rect.color = Color(color.r, color.g, color.b, 0.0)
	var tween := create_tween()
	tween.tween_property(_flash_rect, "color:a", peak, 0.05)
	tween.tween_property(_flash_rect, "color:a", 0.0, 0.4)


## The storm's signature double-flash, matching RunnerHud.flash_lightning.
func _lightning() -> void:
	if _flash_rect == null:
		return
	_flash_rect.color = Color(COLD_FLASH.r, COLD_FLASH.g, COLD_FLASH.b, 0.0)
	var tween := create_tween()
	tween.tween_property(_flash_rect, "color:a", 0.5, 0.05)
	tween.tween_property(_flash_rect, "color:a", 0.08, 0.08)
	tween.tween_property(_flash_rect, "color:a", 0.42, 0.05)
	tween.tween_property(_flash_rect, "color:a", 0.0, 0.45)
