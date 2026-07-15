extends CharacterBody3D
## OpenWorldPlayer
##
## Drives the character from MotionManager (the webcam pose pipeline):
##   - forward speed  <- MotionManager.get_forward()  (marching in place)
##   - turning        <- MotionManager.get_turn()     (leaning your torso)
##   - jumping        <- MotionManager.consume_jump() (a real vertical leap)
##   - crouching      <- MotionManager.get_crouch()   (squatting down)
##
## The character reads MotionManager rather than the keyboard, so the exact same
## controller works with camera input today or any future input source. Values
## sit at zero when the pose service is not running, so the scene is safe to open
## without a webcam attached.

## Emitted when the player starts or stops marching, so decoupled listeners
## (e.g. the follow camera's FOV kick) can react without polling MotionManager.
signal walking_state_changed(is_walking: bool)

## The rigged low-poly character (see assets/models/generated_human). It ships
## with four baked TRS clips — "idle", "walk", "jump", "crouch" — which this
## controller crossfades between by motion state (see [method _update_animation]).
## Swapping this path for any other GLB works as long as it exposes clips by
## those names; a model with different clip names falls back to its first clip.
const CHARACTER_MODEL: String = "res://assets/models/generated_human/human.glb"
## Clip names baked into the GLB (see assets/models/generated_human/export_glb.py).
const CLIP_IDLE: String = "idle"
const CLIP_WALK: String = "walk"
const CLIP_JUMP: String = "jump"
const CLIP_CROUCH: String = "crouch"
## Crossfade time (s) when switching locomotion clips, so idle↔walk↔crouch blend
## instead of popping.
const ANIM_BLEND: float = 0.18
## Above this much [method MotionManager.get_forward] the figure plays "walk";
## below it, "idle". A little hysteresis-free deadzone stops a twitchy toggle.
const WALK_ENTER: float = 0.12
## Playback speed of "walk" at a full march. Standing-still winds down toward a
## slow step; the clip is paced so faster marching reads as faster steps.
const WALK_SPEED_MIN: float = 0.6
const WALK_SPEED_MAX: float = 1.7
## Crouch amount (0..1) above which the figure holds the "crouch" squat clip.
const CROUCH_ENTER: float = 0.45

## Metres/second at full march (forward == 1.0).
@export var move_speed: float = 4.0
## Radians/second at full lean (turn == 1.0). Kept gentle so steering with your
## torso feels deliberate rather than twitchy (the yaw signal is also smoothed in
## MotionManager and scaled down in the pose service).
@export var turn_speed: float = 1.7
## Flip if leaning turns the wrong way for you.
@export var invert_turn: bool = false
## Upward launch speed (m/s) applied when a jump is detected. ~4.5 clears a
## comfortable hop given the project's default gravity.
@export var jump_velocity: float = 4.5
## Fraction of [member move_speed] left at a full crouch — squatting slows you.
@export var crouch_speed_scale: float = 0.4
## Capsule height at a full (crouch == 1.0) squat, in metres. Clamped so it never
## drops below the capsule's diameter.
@export var crouch_height: float = 1.2

@onready var _mesh: MeshInstance3D = $MeshInstance3D
@onready var _collision: CollisionShape3D = $CollisionShape3D

## Falling below this height means the player left the world; respawn them.
const FALL_RESET_Y: float = -8.0

var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
var _was_walking: bool = false
var _stand_height: float = 2.0  # captured from the capsule at _ready
var _spawn_transform: Transform3D  # where to respawn after falling off the world
var _character: Node3D  # the visible GLB figure (null if the model failed to load)
var _anim: AnimationPlayer  # drives the idle/walk/jump/crouch clips
var _clips: PackedStringArray  # clip names actually present in the GLB
var _current_clip: String = ""  # locomotion clip currently crossfaded in
var _jumping: bool = false  # true while the one-shot "jump" clip is playing
## How far the model's lowest vertex sits below its own origin, in metres. The
## GLB's root is at the hips, not the soles, so we measure the real feet and lift
## the figure by this much to plant them on the capsule bottom (see
## [method _spawn_character] / [method _apply_crouch]).
var _feet_offset: float = 0.0

func _ready() -> void:
	_spawn_transform = global_transform
	# Remember the upright capsule height so crouch can lerp back to it. Make the
	# shape/mesh local to this instance so resizing the capsule at runtime can't
	# leak into any other node that happens to share the resource.
	if _collision.shape is CapsuleShape3D:
		_collision.shape = _collision.shape.duplicate()
		_stand_height = (_collision.shape as CapsuleShape3D).height
	if _mesh.mesh is CapsuleMesh:
		_mesh.mesh = _mesh.mesh.duplicate()
	_spawn_character()


## Swaps the placeholder capsule for the rigged low-poly figure: instance the
## GLB, plant its feet at the bottom of the collision capsule, and turn it to
## face Godot's forward (-Z) since the model is authored looking down +Z. The
## capsule mesh is kept (hidden) so the crouch height maths in _apply_crouch
## still has a valid CapsuleMesh to read, and so the scene degrades to the
## capsule if the model is ever missing.
func _spawn_character() -> void:
	var packed: PackedScene = load(CHARACTER_MODEL)
	if packed == null:
		return  # keep the visible capsule as a fallback
	_character = packed.instantiate()
	_mesh.visible = false
	add_child(_character)
	# The GLB's origin is at the hips, so measure its real vertical extent and
	# raise it so the lowest vertex (the soles) rests on the capsule bottom.
	_feet_offset = -_model_aabb(_character).position.y
	_character.position.y = -_stand_height / 2.0 + _feet_offset
	_character.rotation.y = PI  # authored facing +Z; Godot forward is -Z
	_anim = _character.find_child("AnimationPlayer", true, false)
	if _anim != null:
		_clips = _anim.get_animation_list()
		# GLB clips import non-looping; loop the cyclic ones and leave the
		# one-shot "jump" to play through once so we can return from it.
		for name in _clips:
			var clip := _anim.get_animation(name)
			clip.loop_mode = (Animation.LOOP_NONE if name == CLIP_JUMP
					else Animation.LOOP_LINEAR)
		_anim.animation_finished.connect(_on_anim_finished)
		# Start on idle (or whatever the model offers first).
		_current_clip = CLIP_IDLE if _clips.has(CLIP_IDLE) else _clips[0]
		_anim.play(_current_clip)


## Returns [param name] if the GLB actually contains that clip, else the current
## locomotion clip — so a model missing (say) a crouch clip degrades gracefully
## instead of erroring on an unknown animation.
func _clip_or_fallback(name: String) -> String:
	return name if _clips.has(name) else _current_clip


## When the one-shot jump finishes, drop the latch so [method _update_animation]
## resumes picking idle/walk/crouch from live motion state.
func _on_anim_finished(name: StringName) -> void:
	if name == CLIP_JUMP:
		_jumping = false
		_current_clip = ""  # force a fresh crossfade back into locomotion


## Combined axis-aligned bounds of every visual in [param root], expressed in
## [param root]'s own local space. Used to find where the model's feet really
## are (its origin is at the hips) so we can plant them on the ground.
func _model_aabb(root: Node3D) -> AABB:
	var bounds := AABB()
	var seeded := false
	for node in root.find_children("*", "VisualInstance3D", true, false):
		var vis := node as VisualInstance3D
		# Transform each visual's local AABB up into root's space, accounting for
		# every parent transform between them.
		var xform := root.global_transform.affine_inverse() * vis.global_transform
		var box := xform * vis.get_aabb()
		if seeded:
			bounds = bounds.merge(box)
		else:
			bounds = box
			seeded = true
	return bounds


func _physics_process(delta: float) -> void:
	# Off the edge of the world: put the player back at their spawn point.
	# A session should never end because a step carried you over the rim.
	if global_position.y < FALL_RESET_Y:
		global_transform = _spawn_transform
		velocity = Vector3.ZERO

	var turn: float = MotionManager.get_turn()
	if invert_turn:
		turn = -turn
	rotate_y(-turn * turn_speed * delta)

	# Crouching squats the capsule down and slows the march.
	var crouch: float = MotionManager.get_crouch()
	_apply_crouch(crouch)

	# Move along the body's current facing (-Z is "forward" in Godot).
	var forward: float = MotionManager.get_forward()
	var speed: float = move_speed * lerpf(1.0, crouch_speed_scale, crouch)
	var direction: Vector3 = -transform.basis.z * (forward * speed)
	velocity.x = direction.x
	velocity.z = direction.z

	if is_on_floor():
		velocity.y = 0.0
		# Launch on a detected jump. Consume it even when airborne (below) so a
		# stale latch can't fire a phantom jump on the next landing.
		if MotionManager.consume_jump():
			velocity.y = jump_velocity
			_play_jump()
	else:
		velocity.y -= _gravity * delta
		MotionManager.consume_jump()  # discard jumps that arrive mid-air

	# Pick and pace the clip that matches what the body is doing this frame.
	_update_animation(forward, crouch)

	move_and_slide()

	var walking: bool = MotionManager.is_walking()
	if walking != _was_walking:
		_was_walking = walking
		walking_state_changed.emit(walking)


## Fires the one-shot jump clip, latching [member _jumping] so locomotion
## selection stands aside until the leap finishes (see [method _on_anim_finished]).
func _play_jump() -> void:
	if _anim == null or not _clips.has(CLIP_JUMP):
		return
	_jumping = true
	_anim.speed_scale = 1.0
	_anim.play(CLIP_JUMP, ANIM_BLEND * 0.5)


## Chooses the clip that matches the body's state and paces the walk to the
## march. Priority: an in-progress jump wins; then a deep crouch holds the squat;
## otherwise it's walk vs. idle by how hard you're marching.
func _update_animation(forward: float, crouch: float) -> void:
	if _anim == null or _jumping:
		return  # let the jump one-shot play out uninterrupted

	var want: String
	if crouch >= CROUCH_ENTER:
		want = _clip_or_fallback(CLIP_CROUCH)
	elif forward > WALK_ENTER:
		want = _clip_or_fallback(CLIP_WALK)
	else:
		want = _clip_or_fallback(CLIP_IDLE)

	if want != _current_clip:
		_current_clip = want
		_anim.play(want, ANIM_BLEND)

	# Faster marching -> faster steps; other clips play at their authored speed.
	_anim.speed_scale = (lerpf(WALK_SPEED_MIN, WALK_SPEED_MAX, clampf(forward, 0.0, 1.0))
			if want == CLIP_WALK else 1.0)


## Squats the collision capsule and its mesh toward [member crouch_height] as the
## crouch amount rises, keeping them in sync. Height is floored at the capsule's
## diameter, the smallest a capsule can validly be.
func _apply_crouch(crouch: float) -> void:
	var capsule := _collision.shape as CapsuleShape3D
	if capsule == null:
		return
	var target := lerpf(_stand_height, maxf(crouch_height, capsule.radius * 2.0), crouch)
	capsule.height = target
	if _mesh.mesh is CapsuleMesh:
		(_mesh.mesh as CapsuleMesh).height = target
	# Keep the figure's feet planted on the (now shorter) capsule bottom. The
	# squat itself is the "crouch" animation clip (bent knees + lean), not a
	# vertical scale — so the figure folds like a body instead of shrinking.
	if _character != null:
		_character.position.y = -target / 2.0 + _feet_offset
