extends Node3D
## SprintPlayer
##
## The racing athlete in Hurdle Dash. Like the zombie-run figure it never
## travels — the stadium scrolls past while rivals are placed relative to it —
## but its moveset is deliberately tiny: run (always; the stride paces to how
## hard the player is marching) and JUMP (a real physical leap, via
## MotionManager.consume_jump) to clear hurdles. No strafe and no slide: a
## hurdles race is a purity test of rhythm plus timing, so nothing else
## competes for the player's body.
##
## The figure is the active profile's personalised model from CharacterFactory
## (same clips as everywhere else: idle/walk/jump/crouch), planted on its lane
## via RigUtils, facing down the track (-Z).
class_name SprintPlayer

## Kinematic jump identical to the zombie run's, so a leap feels the same
## across games (≈0.6 s airborne, ≈0.9 m peak).
const JUMP_VELOCITY: float = 6.2
const GRAVITY: float = 22.0
## Above this height the athlete counts as clearing a hurdle.
const CLEAR_HEIGHT: float = 0.35

const CLIP_WALK: String = "walk"
const CLIP_JUMP: String = "jump"
const CLIP_IDLE: String = "idle"
const CLIP_CROUCH: String = "crouch"
const ANIM_BLEND: float = 0.14
## Stride playback across the pace range (the walk clip driven fast reads as a
## sprint).
const RUN_STRIDE_MIN: float = 1.1
const RUN_STRIDE_MAX: float = 2.9

var _y: float = 0.0            # current jump height
var _vy: float = 0.0           # vertical velocity
var _grounded: bool = true
var _run: float = 0.0          # smoothed pace 0..1, set by sprint.gd each frame
var _stumble_t: float = 0.0    # brief hit-reaction timer
## Set after the finish line: the stride winds down and settles into idle.
var _finished: bool = false
## Start-line pose, held until the gun: "ready" (stand tall at the line) or
## "set" (crouch into the blocks). Empty once racing — the run is free to drive.
## Nobody covers ground and no jump registers while a start pose is held.
var _start_pose: String = ""

var _character: Node3D
var _anim: AnimationPlayer
var _clips: PackedStringArray
var _current_clip: String = ""
var _jumping: bool = false
## The lane X this athlete stands in (taken from the scene position at _ready).
var _base_x: float = 0.0


func _ready() -> void:
	_base_x = position.x
	_spawn_character()


## Fetches the active profile's personalised figure and plants it facing down
## the track (-Z), so we watch the athlete's back as they race.
func _spawn_character() -> void:
	_character = CharacterFactory.get_character()
	if _character == null:
		return
	add_child(_character)
	RigUtils.plant_feet(_character, 0.0, PI)  # authored facing +Z; race toward -Z
	_anim = _character.find_child("AnimationPlayer", true, false)
	if _anim != null:
		_clips = _anim.get_animation_list()
		RigUtils.loop_clips(_anim, [CLIP_JUMP])
		_anim.animation_finished.connect(_on_anim_finished)
		_current_clip = CLIP_WALK if _clips.has(CLIP_WALK) else _clips[0]
		_anim.play(_current_clip)


func _on_anim_finished(clip: StringName) -> void:
	if clip == CLIP_JUMP:
		_jumping = false
		_current_clip = ""  # force a fresh crossfade back to the stride


## Called every frame by sprint.gd with the smoothed pace so the stride keeps
## step with how fast the stadium is scrolling past.
func tick(delta: float, run: float) -> void:
	_run = run
	_update_jump(delta)
	if _stumble_t > 0.0:
		_stumble_t = maxf(0.0, _stumble_t - delta)
	if _character != null:
		# A quick shove on a stumble; otherwise stand straight in the lane.
		var lean: float = 0.0
		if _stumble_t > 0.0:
			lean = sin(_stumble_t * 40.0) * 0.12 * _stumble_t
		_character.rotation.z = lerpf(_character.rotation.z, lean, 0.3)
	position = Vector3(_base_x, _y, 0.0)
	_update_animation()


func _update_jump(delta: float) -> void:
	# Always drain the buffered jump so it can't fire late; only a grounded,
	# racing athlete actually launches (not while set at the line or after the
	# line, and not a second jump mid-air).
	var jumped: bool = MotionManager.consume_jump()
	if jumped and _grounded and _start_pose == "" and not _finished:
		_vy = JUMP_VELOCITY
		_grounded = false
		_play_jump()
	_vy -= GRAVITY * delta
	_y += _vy * delta
	if _y <= 0.0:
		_y = 0.0
		_vy = 0.0
		_grounded = true


func _play_jump() -> void:
	if _anim == null or not _clips.has(CLIP_JUMP):
		return
	_jumping = true
	_anim.speed_scale = 1.0
	_anim.play(CLIP_JUMP, ANIM_BLEND * 0.5)


## Picks the clip for the current moment and paces the stride to the pace.
## After the finish line the run winds down and, once the legs are slow, the
## athlete settles into a standing idle to soak up the result.
func _update_animation() -> void:
	if _anim == null or _jumping:
		return
	var want: String
	if _start_pose == "set":
		# Down in the blocks, braced for the gun (the crouch clip breathes).
		want = CLIP_CROUCH if _clips.has(CLIP_CROUCH) else _idle_or_current()
	elif _start_pose == "ready":
		# Stood tall at the line, waiting for the starter.
		want = _idle_or_current()
	elif _finished and _run < 0.08 and _clips.has(CLIP_IDLE):
		want = CLIP_IDLE
	else:
		want = CLIP_WALK if _clips.has(CLIP_WALK) else _current_clip
	if want != _current_clip:
		_current_clip = want
		_anim.play(want, ANIM_BLEND)
	# Only the running stride paces to effort; held poses play at their own rate.
	_anim.speed_scale = (lerpf(RUN_STRIDE_MIN, RUN_STRIDE_MAX, _run)
			if want == CLIP_WALK else 1.0)


func _idle_or_current() -> String:
	return CLIP_IDLE if _clips.has(CLIP_IDLE) else _current_clip


## Holds the athlete at the start line before the gun. [param pose] is "ready"
## (stand at the line), "set" (crouch into the blocks) or "" to release into the
## run on GO. While a pose is held no jump registers (see [method _update_jump]).
func set_start_pose(pose: String) -> void:
	_start_pose = pose


## A brief hit reaction (visual shove); sprint.gd owns the speed penalty.
func stumble() -> void:
	_stumble_t = 0.4


## Crossed the line: jumps stop registering and the stride is allowed to wind
## down into idle as sprint.gd eases the pace it passes to zero.
func finish_race() -> void:
	_finished = true


## True while airborne high enough to clear a hurdle.
func is_clearing() -> bool:
	return _y > CLEAR_HEIGHT


func is_grounded() -> bool:
	return _grounded
