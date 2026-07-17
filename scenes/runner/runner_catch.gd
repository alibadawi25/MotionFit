extends Node
## RunnerCatch
##
## The death scene: what plays when the zombie finally takes you. The whole run
## tells you DON'T LOOK BACK — so the one time the camera does is the moment you
## die, and what it sees is the scare. Three beats, fast and merciless:
##
##   1. the grab — the pursuer lunges onto the runner's back as they crumple,
##      the world grinds to a halt, the heartbeat hammers flat out,
##   2. the face — a HARD CUT to right in front of it, lunging into the lens
##      with the full scream: the jump-scare payoff of a run spent never
##      seeing the thing behind you. It STAYS there for the whole scream,
##      mauling the camera in re-lunges while the shake throbs on the beat,
##   3. black — cut the instant the wail dies, so the beat stopping and the
##      scream ending are one silence; the card tells the toll before the
##      results screen takes over.
##
## Like RunnerCinematic it's a director, not a world: runner.gd hands it the
## camera and actors it already owns the moment the gap closes, and it emits
## [signal finished] when the card has been read — runner.gd banks the run from
## there. Skippable with SPACE; there's no gesture skip because at ~4 seconds
## the scene is shorter than the hold would feel.
class_name RunnerCatch

## Emitted once, when the scene has played out (or been skipped); the caller
## banks the run to results. The blackout is left up so the hand-off is clean.
signal finished

## Letterbox bar height, matching the opening cinematic's frame.
const BAR_H: float = 132.0
const RED_FLASH: Color = Color(0.85, 0.08, 0.05)
## The heartbeat through the grab: pinned past the gameplay maximum (3.2), so the
## body knows this is the end even before the cut. It stops DEAD on the blackout —
## the sudden silence after four seconds of hammering is the death knell.
const PANIC_HZ: float = 3.4
## Where the zombie is dragged to during the grab: right onto the runner's back.
const GRAB_Z: float = 0.2
## How long the face owns the screen after the lunge-in, before the smash to
## black. The scream clip is 8 s of file but only ~4 s of sound (loud to ~2.5 s,
## decayed into silence past ~4 — measured, not guessed); lunge-in + this hold
## lands the cut right where the wail dies, so scream and heartbeat stop as one.
const FACE_HOLD: float = 2.95
## The face shot's re-lunge cadence: it keeps going for the lens while it
## screams, so the held close-up never freezes into a portrait.
const RELUNGE_SEC: float = 1.6

var _camera: Camera3D
var _player: RunnerPlayer
var _zombie: RunnerZombie
var _track: RunnerTrack
var _audio: RunnerAudio
var _hud: RunnerHud
var _distance: int = 0

# Shot list (built in setup from the actors' live positions). Each shot: dur,
# pa/pb (camera position), la/lb (look target), fa/fb (FOV), sa/sb (world
# scroll m/s), shake (jitter amplitude; ramped in on shot 0, constant after).
var _shots: Array = []
var _shot: int = 0
var _t: float = 0.0
var _finished: bool = false
var _beat_phase: float = 0.0
## Last heartbeat pulse value, so the face shots' shake can throb on the beat.
var _pulse: float = 0.0
var _grab_flash_done: bool = false
## Countdown to the held face shot's next re-lunge at the lens.
var _relunge_left: float = 0.0

var _layer: CanvasLayer
var _bar_top: ColorRect
var _bar_bottom: ColorRect
var _flash_rect: ColorRect
var _blackout: ColorRect
var _title: Label
var _subtitle: Label


## Hands over the scene's camera and actors plus the final distance for the
## card. Call right after add_child; the scene starts on the next frame.
func setup(camera: Camera3D, player: RunnerPlayer, zombie: RunnerZombie,
		track: RunnerTrack, audio: RunnerAudio, hud: RunnerHud,
		distance: int) -> void:
	_camera = camera
	_player = player
	_zombie = zombie
	_track = track
	_audio = audio
	_hud = hud
	_distance = distance
	_build_shots()
	_build_ui()
	_enter_shot(0)


## The storyboard, framed off where everyone actually is at the moment of the
## catch. Shot 1 starts from the camera's own live pose so there's no cut into
## the scene — the gameplay frame simply starts diving. Shot 2 is framed on the
## zombie's GRAB position (where the shot-1 tween drags it), from slightly
## off-axis so the crumpled runner reads in the bottom of the frame instead of
## blocking the face.
func _build_shots() -> void:
	var px: float = _player.center_x()
	var zx: float = px * 0.7
	var cam_pos: Vector3 = _camera.global_position
	# Continue the camera's current gaze, then dive toward the victim.
	var cam_look: Vector3 = cam_pos - _camera.global_transform.basis.z * 9.0
	_shots = [
		{  # 1 — the grab: the frame dives onto the runner's back as it takes them
			dur = 1.05,
			pa = cam_pos, pb = Vector3(zx + 0.6, 1.55, 1.7),
			la = cam_look, lb = Vector3(px, 1.05, 0.1),
			fa = _camera.fov, fb = 62.0, sa = 6.0, sb = 0.0, shake = 0.22,
		},
		{  # 2 — the face: HARD CUT to in front of it, lunging into the lens
			dur = 0.85,
			pa = Vector3(zx + 0.55, 1.65, GRAB_Z - 2.0),
			pb = Vector3(zx + 0.1, 1.5, GRAB_Z - 0.7),
			la = Vector3(zx, 1.55, GRAB_Z + 0.3), lb = Vector3(zx, 1.5, GRAB_Z + 0.3),
			fa = 58.0, fb = 46.0, sa = 0.0, sb = 0.0, shake = 0.5,
		},
		{  # 3 — the hold: it stays in your face for the length of the scream,
			# creeping closer still, re-lunging at the lens (see RELUNGE_SEC)
			dur = FACE_HOLD,
			pa = Vector3(zx + 0.1, 1.5, GRAB_Z - 0.7),
			pb = Vector3(zx, 1.48, GRAB_Z - 0.52),
			la = Vector3(zx, 1.5, GRAB_Z + 0.3), lb = Vector3(zx, 1.5, GRAB_Z + 0.3),
			fa = 46.0, fb = 43.5, sa = 0.0, sb = 0.0, shake = 0.45,
		},
		{  # 4 — black: smash to nothing, the beat stops, the card tells the toll
			dur = 2.2,
			pa = Vector3(zx, 1.48, GRAB_Z - 0.52),
			pb = Vector3(zx, 1.48, GRAB_Z - 0.52),
			la = Vector3(zx, 1.5, GRAB_Z + 0.3), lb = Vector3(zx, 1.5, GRAB_Z + 0.3),
			fa = 43.5, fb = 43.5, sa = 0.0, sb = 0.0, shake = 0.0,
		},
	]


func _process(delta: float) -> void:
	if _finished or _shots.is_empty():
		return
	if _camera == null or _player == null or _zombie == null or _track == null:
		_finish()
		return
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
	var u: float = clampf(_t / float(shot["dur"]), 0.0, 1.0)
	_track.scroll(delta, lerpf(float(shot["sa"]), float(shot["sb"]), u), false)
	_tick_heartbeat(delta)
	_tick_events()


## The hammering pulse through the grab and the face — audio, vignette clench
## and FOV kick all off one phase, exactly like gameplay's tension loop, just
## pinned to the ceiling. Cuts out entirely once the blackout is up: the sudden
## flat silence IS the third beat.
func _tick_heartbeat(delta: float) -> void:
	if _shot >= 3:
		_pulse = 0.0
		return
	_beat_phase += PANIC_HZ * delta
	_pulse = _heartbeat(_beat_phase)
	if _audio != null:
		_audio.tick(delta, 1.0, _beat_phase)
	if _hud != null:
		_hud.set_danger(1.0, _pulse)
	if _camera != null:
		_camera.fov -= _pulse * 3.0


## Per-shot beats that aren't camera moves.
func _enter_shot(index: int) -> void:
	match index:
		0:
			# The grab: it lunges, the runner crumples, and it's dragged the last
			# stretch onto their back so the reach actually lands.
			_zombie.lunge()
			_player.collapse()
			var px: float = _player.center_x()
			var tween := create_tween()
			tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
			tween.tween_property(_zombie, "global_position",
					Vector3(px * 0.7, 0.0, GRAB_Z), 0.7)
		1:
			# The scare: replay the lunge AT the lens with the full scream. The
			# shot-1 lunge has frozen on its final reach by now; recover() clears
			# the latch so it can fire again, this time right in your face.
			_zombie.recover()
			_zombie.lunge()
			if _audio != null:
				_audio.scream()
			_flash(RED_FLASH, 0.55)
		2:
			# The hold: same frame, but it keeps coming — arm the re-lunge loop.
			_relunge_left = RELUNGE_SEC
		3:
			# Blackout: the world is gone, the heart stops, the card fades up.
			if _audio != null:
				_audio.hush(0.15)
			_blackout.color.a = 1.0
			_show_card()


## Eased camera move for the current shot. The grab's shake ramps in with the
## dive; the face shots jolt at full amplitude from their first frame — a steady
## approach would read as curiosity, not terror — and throb harder on each
## heartbeat, so the held close-up shudders in time with the pulse.
func _apply_camera(shot: Dictionary) -> void:
	var u: float = smoothstep(0.0, 1.0, _t / float(shot["dur"]))
	var pos: Vector3 = (shot["pa"] as Vector3).lerp(shot["pb"] as Vector3, u)
	var amp: float = float(shot["shake"]) \
			* (u if _shot == 0 else (0.65 + 0.55 * _pulse))
	if amp > 0.0:
		pos += Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), 0.0) * amp * 0.25
	_camera.global_position = pos
	_camera.look_at((shot["la"] as Vector3).lerp(shot["lb"] as Vector3, u), Vector3.UP)
	_camera.fov = lerpf(float(shot["fa"]), float(shot["fb"]), u)


## Timed beats inside a shot: the red slam as the grab lands mid-dive, and the
## held face shot's re-lunges — recover() clears the latch, then it goes for the
## lens again with a smaller red pulse, so the scream is a mauling, not a pose.
func _tick_events() -> void:
	if _shot == 0 and not _grab_flash_done and _t >= 0.45:
		_grab_flash_done = true
		_flash(RED_FLASH, 0.35)
	if _shot == 2:
		_relunge_left -= get_process_delta_time()
		if _relunge_left <= 0.0:
			_relunge_left = RELUNGE_SEC
			_zombie.recover()
			_zombie.lunge()
			_flash(RED_FLASH, 0.28)


func _unhandled_input(event: InputEvent) -> void:
	if not _finished and event.is_action_pressed("ui_accept"):
		_finish()
		get_viewport().set_input_as_handled()


## Ends the scene (played out or skipped) and hands the run to the caller. The
## blackout is forced up first so the results hand-off never shows a stray frame
## of the grab, and unlike the intro this node is NOT freed — the black has to
## stay on screen until the scene change takes the whole run with it.
func _finish() -> void:
	if _finished:
		return
	_finished = true
	if is_instance_valid(_audio):
		_audio.hush()
	if _blackout != null:
		_blackout.color.a = 1.0
		_show_card()
	finished.emit()


# --- overlay (letterbox, blackout, card, flashes) ------------------------------

func _build_ui() -> void:
	var anton: Font = load("res://assets/fonts/Anton-Regular.ttf")
	_layer = CanvasLayer.new()
	_layer.layer = 95  # over the HUD's vignette, under GameIntro's 100
	add_child(_layer)

	# Flash sheet first so the bars and blackout stay black over it.
	_flash_rect = ColorRect.new()
	_flash_rect.color = Color(1, 1, 1, 0.0)
	_flash_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_flash_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(_flash_rect)

	# Letterbox snaps in fast — the frame declaring the controls are dead.
	_bar_top = _bar(Control.PRESET_TOP_WIDE)
	_bar_bottom = _bar(Control.PRESET_BOTTOM_WIDE)
	var bars := create_tween().set_parallel(true)
	bars.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	bars.tween_property(_bar_top, "offset_bottom", BAR_H, 0.3)
	bars.tween_property(_bar_bottom, "offset_top", -BAR_H, 0.3)

	# The smash-to-black, snapped opaque when shot 3 lands (no fade — a cut).
	_blackout = ColorRect.new()
	_blackout.color = Color(0, 0, 0, 0.0)
	_blackout.set_anchors_preset(Control.PRESET_FULL_RECT)
	_blackout.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(_blackout)

	# The card over the black: the sentence, then the toll underneath.
	_title = Label.new()
	_title.text = "THE DEAD CAUGHT YOU"
	_title.set_anchors_preset(Control.PRESET_CENTER)
	_title.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.add_theme_font_override("font", anton)
	_title.add_theme_font_size_override("font_size", 64)
	_title.add_theme_color_override("font_color", RunnerHud.DANGER)
	_title.add_theme_constant_override("outline_size", 12)
	_title.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_title.offset_top = -70.0
	_title.modulate.a = 0.0
	_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(_title)

	_subtitle = Label.new()
	_subtitle.text = "%d m — OUTRUN IT NEXT TIME" % _distance
	_subtitle.set_anchors_preset(Control.PRESET_CENTER)
	_subtitle.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_subtitle.add_theme_font_size_override("font_size", 24)
	_subtitle.add_theme_color_override("font_color", RunnerHud.MUTED)
	_subtitle.offset_top = 22.0
	_subtitle.modulate.a = 0.0
	_subtitle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(_subtitle)


## One zero-height letterbox bar pinned to a screen edge (grown by tween).
func _bar(preset: int) -> ColorRect:
	var bar := ColorRect.new()
	bar.color = Color.BLACK
	bar.set_anchors_preset(preset)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(bar)
	return bar


## Fades the card up over the blackout: the sentence first, the toll a beat
## later. Idempotent — the natural shot 3 and a skip can both land here.
func _show_card() -> void:
	if _title == null or _title.modulate.a > 0.0:
		return
	create_tween().tween_property(_title, "modulate:a", 1.0, 0.35)
	var sub := create_tween()
	sub.tween_interval(0.45)
	sub.tween_property(_subtitle, "modulate:a", 1.0, 0.35)


## A quick full-screen tint spike, for the two red slams.
func _flash(color: Color, peak: float) -> void:
	if _flash_rect == null:
		return
	_flash_rect.color = Color(color.r, color.g, color.b, 0.0)
	var tween := create_tween()
	tween.tween_property(_flash_rect, "color:a", peak, 0.05)
	tween.tween_property(_flash_rect, "color:a", 0.0, 0.4)


## Two quick thumps per cycle (lub-dub) — the same envelope as runner.gd's
## gameplay heartbeat, duplicated here because the scene runs its own pinned
## phase once the chase maths has stopped.
func _heartbeat(phase: float) -> float:
	var p: float = fposmod(phase, 1.0)
	var lub: float = exp(-pow((p - 0.0) / 0.055, 2.0))
	var dub: float = 0.65 * exp(-pow((p - 0.19) / 0.055, 2.0))
	return clampf(lub + dub, 0.0, 1.0)
