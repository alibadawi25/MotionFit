extends Node3D
## RunnerPlayer
##
## The fleeing runner. Unlike the open-world player this figure does NOT travel
## through the world — the world scrolls past it (see runner.gd) — so it only
## needs three body-driven moves, all read from MotionManager so the same camera
## pipeline drives it:
##   - strafe left/right  <- get_turn()      (lean your torso to dodge)
##   - jump over           <- consume_jump()  (a real vertical leap)
##   - slide under         <- get_crouch()    (squat/duck)
## Its run PACE is not its own concern — runner.gd turns marching intensity
## (get_forward) into how fast the world scrolls and how far ahead of the zombie
## you stay. The visible legs just always run; the stride speeds up with pace.
##
## The figure is the active profile's personalised model from CharacterFactory
## (same clips as the open-world player: idle/walk/jump/crouch), planted on the
## track via RigUtils. Falls back to nothing visible only if the model can't load.
class_name RunnerPlayer

## Half-width of the track the runner can strafe across (metres).
const STRAFE_X_MAX: float = 2.4
## How quickly the body slides toward the leaned-to position (higher = snappier).
const STRAFE_SPEED: float = 10.0
## Body tilt (radians) at full strafe, for weighty-feeling dodges.
const STRAFE_LEAN: float = 0.28

## Kinematic jump: a punchy arc independent of project gravity so hops feel
## crisp in a runner (≈0.6 s airborne, ≈0.9 m peak).
const JUMP_VELOCITY: float = 6.2
const GRAVITY: float = 22.0
## Above this height the runner counts as clearing a low barrier.
const CLEAR_HEIGHT: float = 0.35

## Squat depth that starts a slide, and how long a slide lasts once triggered so a
## brief duck still carries you under a bar.
const SLIDE_ENTER: float = 0.40
const SLIDE_MIN_TIME: float = 0.55

const CLIP_WALK: String = "walk"
const CLIP_JUMP: String = "jump"
const CLIP_CROUCH: String = "crouch"
const ANIM_BLEND: float = 0.14
## Stride playback across the pace range (a walk clip driven fast reads as a run).
const RUN_STRIDE_MIN: float = 1.1
const RUN_STRIDE_MAX: float = 2.8

var _x: float = 0.0            # current strafe offset
var _y: float = 0.0           # current jump height
var _vy: float = 0.0          # vertical velocity
var _grounded: bool = true
var _sliding: bool = false
var _slide_timer: float = 0.0
var _run: float = 0.0          # smoothed pace 0..1, set by runner.gd each frame
var _stumble_t: float = 0.0    # brief hit-reaction timer

var _character: Node3D
var _anim: AnimationPlayer
var _clips: PackedStringArray
var _current_clip: String = ""
var _jumping: bool = false


func _ready() -> void:
	_spawn_character()


## Fetches the active profile's personalised figure and plants it facing away from
## the camera (down the track, -Z), so we watch the runner's back as they flee.
func _spawn_character() -> void:
	_character = CharacterFactory.get_character()
	if _character == null:
		return
	add_child(_character)
	RigUtils.plant_feet(_character, 0.0, PI)  # authored facing +Z; run toward -Z
	_anim = _character.find_child("AnimationPlayer", true, false)
	if _anim != null:
		_clips = _anim.get_animation_list()
		RigUtils.loop_clips(_anim, [CLIP_JUMP])
		_anim.animation_finished.connect(_on_anim_finished)
		_current_clip = CLIP_WALK if _clips.has(CLIP_WALK) else _clips[0]
		_anim.play(_current_clip)


func _on_anim_finished(name: StringName) -> void:
	if name == CLIP_JUMP:
		_jumping = false
		_current_clip = ""  # force a fresh crossfade back to running


## Called every frame by runner.gd, passing the smoothed pace so the stride keeps
## step with how fast the world is scrolling. Returns nothing; state is read back
## via [method center_x] / [method is_clearing] / [method is_sliding].
func tick(delta: float, run: float) -> void:
	_run = run
	_update_strafe(delta)
	_update_jump(delta)
	_update_slide(delta)
	if _stumble_t > 0.0:
		_stumble_t = maxf(0.0, _stumble_t - delta)
	position = Vector3(_x, _y, 0.0)
	_update_animation()


func _update_strafe(delta: float) -> void:
	var target: float = clampf(MotionManager.get_turn(), -1.0, 1.0) * STRAFE_X_MAX
	_x = lerpf(_x, target, 1.0 - exp(-STRAFE_SPEED * delta))
	if _character != null:
		# Lean into the dodge, plus a quick shove on a stumble.
		var lean: float = -(_x / STRAFE_X_MAX) * STRAFE_LEAN
		if _stumble_t > 0.0:
			lean += sin(_stumble_t * 40.0) * 0.12 * _stumble_t
		_character.rotation.z = lerpf(_character.rotation.z, lean, 0.3)


func _update_jump(delta: float) -> void:
	if _grounded and MotionManager.consume_jump():
		_vy = JUMP_VELOCITY
		_grounded = false
		_play_jump()
	elif not _grounded:
		MotionManager.consume_jump()  # discard jumps that arrive mid-air
	_vy -= GRAVITY * delta
	_y += _vy * delta
	if _y <= 0.0:
		_y = 0.0
		_vy = 0.0
		_grounded = true


func _update_slide(delta: float) -> void:
	var crouch: float = MotionManager.get_crouch()
	if _sliding:
		_slide_timer = maxf(0.0, _slide_timer - delta)
		if _slide_timer <= 0.0 and crouch < SLIDE_ENTER:
			_sliding = false
	elif crouch >= SLIDE_ENTER and _grounded:
		_sliding = true
		_slide_timer = SLIDE_MIN_TIME


func _play_jump() -> void:
	if _anim == null or not _clips.has(CLIP_JUMP):
		return
	_jumping = true
	_anim.speed_scale = 1.0
	_anim.play(CLIP_JUMP, ANIM_BLEND * 0.5)


## Picks the clip matching the current move and paces the run to the world speed.
func _update_animation() -> void:
	if _anim == null or _jumping:
		return
	var want: String
	if _sliding and _clips.has(CLIP_CROUCH):
		want = CLIP_CROUCH
	else:
		want = CLIP_WALK if _clips.has(CLIP_WALK) else _current_clip
	if want != _current_clip:
		_current_clip = want
		_anim.play(want, ANIM_BLEND)
	# Legs always run; faster pace -> faster stride. Crouch plays at its own speed.
	_anim.speed_scale = (lerpf(RUN_STRIDE_MIN, RUN_STRIDE_MAX, _run)
			if want == CLIP_WALK else 1.0)


## A brief hit reaction (visual shove); runner.gd owns the gameplay penalty.
func stumble() -> void:
	_stumble_t = 0.35


func center_x() -> float:
	return _x


## True while airborne high enough to clear a low barrier.
func is_clearing() -> bool:
	return _y > CLEAR_HEIGHT


func is_sliding() -> bool:
	return _sliding
