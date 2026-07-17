extends CharacterBody3D
## OpenWorldPlayer
##
## Drives the character from MotionManager (the webcam pose pipeline):
##   - forward speed  <- MotionManager.get_forward()  (marching in place)
##   - turning        <- MotionManager.get_turn()     (leaning your torso)
##   - jumping        <- MotionManager.consume_jump() (a real vertical leap)
##
## The character reads MotionManager rather than the keyboard, so the exact same
## controller works with camera input today or any future input source. Values
## sit at zero when the pose service is not running, so the scene is safe to open
## without a webcam attached.
##
## [b]Everything here is deliberately eased, never assigned.[/b] Pose data is a
## noisy ~20-30 Hz estimate of a human body; wiring it straight to velocity and
## rotation makes the figure twitch and start/stop like a switch. Ground speed
## ramps through [constant ACCEL]/[constant DECEL], the visible model leans into
## what it is doing (see [method _update_model_pose]), and the walk clip is paced
## off real ground speed rather than raw march intensity so the feet stay planted.

## Emitted the frame the player touches down, carrying the impact speed (m/s) so
## listeners can scale their response — the camera dips proportionally.
signal landed(impact: float)

## The rigged low-poly character comes from CharacterFactory — the ACTIVE
## profile's personalised build (body shape from their physical attributes,
## look from their appearance settings), or the bundled default when no
## profile/generator is available. Every variant carries the same baked TRS
## clips — "idle", "walk", "jump" — which this controller crossfades between by
## motion state (see [method _update_animation]); a model with different clip
## names falls back to its first clip.
## Clip names baked into the GLB (see assets/models/generated_human/export_glb.py).
const CLIP_IDLE: String = "idle"
const CLIP_WALK: String = "walk"
const CLIP_JUMP: String = "jump"
## Crossfade time (s) when switching locomotion clips, so idle↔walk blend
## instead of popping.
const ANIM_BLEND: float = 0.18
## Above this fraction of full ground speed the figure plays "walk"; below it,
## "idle". Measured on ACTUAL speed, not march intensity: the body coasts to a
## stop over ~0.4 s, and idling while still gliding would slide the feet.
const WALK_ENTER: float = 0.06
## Playback speed of "walk" across the speed range. A gentle march ambles at
## WALK_SPEED_MIN; a hard march sprints at WALK_SPEED_MAX. Driven by real ground
## speed so the legs stay planted (no foot-sliding) at any pace.
const WALK_SPEED_MIN: float = 0.7
const WALK_SPEED_MAX: float = 2.6
## Exponent shaping raw march intensity (0..1) into ground speed. >1 is convex:
## a light march barely moves you (a slow walk) while a hard march ramps up fast
## (a real run), so the gap between walking and running reads clearly instead of
## everything gliding at one middling pace.
const RUN_CURVE: float = 1.5

## How hard the body ramps toward / away from the speed the march is asking for
## (m/s²). Braking beats accelerating so stopping still feels responsive while
## setting off stays weighty.
const ACCEL: float = 14.0
const DECEL: float = 20.0

## Distance (m) the body stays glued to the ground across bumps and down slopes.
## The default (0.1) is far too short for sculpted terrain: jogging over a hummock
## launches the capsule, which drops is_on_floor(), which kills the ground-align
## and stutters the camera. See [method _ready].
const FLOOR_SNAP: float = 0.6

## Peak lean of the visible model, in radians: roll banking into a turn (~14°),
## pitch tipping forward into a run (~9°). Both are scaled by current speed, so a
## standing turn doesn't bank and a stroll barely tips. Sized to actually read
## from the follow camera — smaller values are invisible behind the figure.
const BANK_MAX: float = 0.24
const PITCH_MAX: float = 0.16
## Higher = lean and slope-matching ease in faster.
const LEAN_SPEED: float = 5.0
## How much of the ground's slope the model actually adopts (0 = always upright,
## 1 = fully perpendicular to the hillside). Partial on purpose: full alignment
## on steep terrain reads as falling over.
const GROUND_ALIGN: float = 0.65

## Metres/second at a full-tilt march (the curved run factor == 1.0). Set well
## above a stroll so sprinting in place actually covers ground.
@export var move_speed: float = 8.0
## Radians/second at full lean (turn == 1.0). Kept gentle so steering with your
## torso feels deliberate rather than twitchy (the yaw signal is also smoothed in
## MotionManager and scaled down in the pose service).
@export var turn_speed: float = 1.7
## Flip if leaning turns the wrong way for you.
@export var invert_turn: bool = false
## Upward launch speed (m/s) applied when a jump is detected. ~4.5 clears a
## comfortable hop given the project's default gravity.
@export var jump_velocity: float = 4.5
## The world's fog border (a WorldBorder), if the scene has one. When set, it
## eases outward movement to a stop in its fog band so the player can't walk off
## the terrain — see world_border.gd. Optional: unset, the body roams freely and
## only [constant FALL_RESET_Y] catches it.
@export var border_path: NodePath

@onready var _mesh: MeshInstance3D = $MeshInstance3D
@onready var _collision: CollisionShape3D = $CollisionShape3D

## Falling below this height means the player left the world; respawn them.
const FALL_RESET_Y: float = -8.0

var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
var _stand_height: float = 2.0  # captured from the capsule at _ready
var _spawn_transform: Transform3D  # where to respawn after falling off the world
var _character: Node3D  # the visible GLB figure (null if the model failed to load)
## Carries the model's lean and slope-matching, so [member _character] keeps its
## own authored facing untouched. Sits at the soles (see [method _spawn_character])
## so tilting rotates the figure about its feet rather than swinging them out.
var _model_pivot: Node3D
var _anim: AnimationPlayer  # drives the idle/walk/jump clips
var _clips: PackedStringArray  # clip names actually present in the GLB
var _current_clip: String = ""  # locomotion clip currently crossfaded in
var _jumping: bool = false  # true while the one-shot "jump" clip is playing
var _bank: float = 0.0  # live model roll (radians)
var _pitch: float = 0.0  # live model pitch (radians)
var _fall_speed: float = 0.0  # fastest descent this airtime, for the landing impact
## How far the model's lowest vertex sits below its own origin, in metres. The
## GLB's root is at the hips, not the soles, so we measure the real feet and lift
## the figure by this much to plant them on the pivot (see
## [method _spawn_character]).
var _feet_offset: float = 0.0
var _border: WorldBorder  # the world's edge (null when the scene has none)

func _ready() -> void:
	_spawn_transform = global_transform
	_border = get_node_or_null(border_path) as WorldBorder
	# Capture the capsule's upright height; the figure's feet are planted relative
	# to it (see [method _spawn_character]). Duplicate the shape so it stays local
	# to this instance rather than shared across any node using the same resource.
	if _collision.shape is CapsuleShape3D:
		_collision.shape = _collision.shape.duplicate()
		_stand_height = (_collision.shape as CapsuleShape3D).height
	# Stick to the terrain over bumps and descents (see [constant FLOOR_SNAP]).
	# Godot skips the snap while moving upward, so this never eats a jump.
	floor_snap_length = FLOOR_SNAP
	floor_constant_speed = true  # a slope shouldn't silently slow the march down
	_spawn_character()


## Swaps the placeholder capsule for the rigged low-poly figure: fetch the
## active profile's personalised model from CharacterFactory, hang it off a lean
## pivot planted at the bottom of the collision capsule, and turn it to face
## Godot's forward (-Z) since the model is authored looking down +Z. The capsule
## mesh is kept (hidden) so the scene degrades to the capsule if no model can be
## produced.
func _spawn_character() -> void:
	_character = CharacterFactory.get_character()
	if _character == null:
		return  # keep the visible capsule as a fallback
	_mesh.visible = false
	# Pivot at the soles: lean and slope-matching rotate the figure about its feet
	# (what a body does), not about its waist (what looks like a hinge).
	_model_pivot = Node3D.new()
	_model_pivot.name = "ModelPivot"
	_model_pivot.position.y = -_stand_height / 2.0
	add_child(_model_pivot)
	_model_pivot.add_child(_character)
	# The GLB's origin is at the hips, so measure its real vertical extent and
	# raise it so the lowest vertex (the soles) rests on the pivot.
	_feet_offset = -_model_aabb(_character).position.y
	_character.position.y = _feet_offset
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
## locomotion clip — so a model missing (say) a walk clip degrades gracefully
## instead of erroring on an unknown animation.
func _clip_or_fallback(name: String) -> String:
	return name if _clips.has(name) else _current_clip


## When the one-shot jump finishes, drop the latch so [method _update_animation]
## resumes picking idle/walk from live motion state.
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


## Current ground speed as a fraction of [member move_speed]. Read by the camera
## for its continuous speed framing, and used here to pace the walk clip — real
## speed, not requested speed, so the legs match the ground under them even while
## accelerating or coasting to a halt.
func get_run_ratio() -> float:
	var flat := Vector3(velocity.x, 0.0, velocity.z)
	return clampf(flat.length() / maxf(move_speed, 0.001), 0.0, 1.0)


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

	# Move along the body's current facing (-Z is "forward" in Godot). Curve the
	# raw march so a gentle march is a slow walk and a hard march is a real run —
	# see [member RUN_CURVE].
	var forward: float = MotionManager.get_forward()
	var run: float = pow(clampf(forward, 0.0, 1.0), RUN_CURVE)

	# Ramp toward that speed instead of snapping to it (see the class docs).
	var goal: Vector3 = -transform.basis.z * (run * move_speed)
	var flat := Vector3(velocity.x, 0.0, velocity.z)
	var rate: float = ACCEL if goal.length() > flat.length() else DECEL
	flat = flat.move_toward(goal, rate * delta)
	velocity.x = flat.x
	velocity.z = flat.z

	var was_on_floor: bool = is_on_floor()
	if was_on_floor:
		velocity.y = 0.0
		# Launch on a detected jump. Consume it even when airborne (below) so a
		# stale latch can't fire a phantom jump on the next landing.
		if MotionManager.consume_jump():
			velocity.y = jump_velocity
			_play_jump()
	else:
		velocity.y -= _gravity * delta
		_fall_speed = maxf(_fall_speed, -velocity.y)  # peak descent, for the impact
		MotionManager.consume_jump()  # discard jumps that arrive mid-air

	# Last word before the move: the world's edge bleeds away whatever part of
	# this velocity points out of the map. Applied here, after gravity and the
	# jump, so nothing downstream can smuggle the body past the border.
	if _border != null:
		velocity = _border.limit_velocity(global_position, velocity)

	move_and_slide()

	# The border again, now on the RESULT: a slide down a slope answers to the
	# terrain, not to the velocity we asked for, so the containment is only
	# actually guaranteed once the position is final.
	if _border != null:
		global_position = _border.clamp_position(global_position)

	# Everything below reads the RESOLVED state, so it must run after the move:
	# is_on_floor()/get_floor_normal() are only meaningful once slides settle, and
	# velocity is now the speed we really achieved rather than the one we asked for.
	var speed_ratio: float = get_run_ratio()
	_update_animation(speed_ratio)
	_update_model_pose(delta, speed_ratio, turn)

	if not was_on_floor and is_on_floor():
		landed.emit(_fall_speed)
		_fall_speed = 0.0


## Fires the one-shot jump clip, latching [member _jumping] so locomotion
## selection stands aside until the leap finishes (see [method _on_anim_finished]).
func _play_jump() -> void:
	if _anim == null or not _clips.has(CLIP_JUMP):
		return
	_jumping = true
	_anim.speed_scale = 1.0
	_anim.play(CLIP_JUMP, ANIM_BLEND * 0.5)


## Chooses the clip that matches the body's state and paces the walk to it.
## Priority: an in-progress jump wins; otherwise it's walk vs. idle by
## [param speed_ratio] (0..1 of full speed), with the walk's playback tied to the
## same figure so the stride quickens in step with the ground speed.
func _update_animation(speed_ratio: float) -> void:
	if _anim == null or _jumping:
		return  # let the jump one-shot play out uninterrupted

	var want: String = (_clip_or_fallback(CLIP_WALK) if speed_ratio > WALK_ENTER
			else _clip_or_fallback(CLIP_IDLE))
	if want != _current_clip:
		_current_clip = want
		_anim.play(want, ANIM_BLEND)

	# Faster running -> faster steps; other clips play at their authored speed.
	_anim.speed_scale = (lerpf(WALK_SPEED_MIN, WALK_SPEED_MAX, speed_ratio)
			if want == CLIP_WALK else 1.0)


## Tilts the visible figure so it reads as a body rather than a sprite on a stick:
## it banks into turns, tips forward as it picks up speed, and stands square to
## the hillside it is on. All of it lives on [member _model_pivot], so the physics
## capsule stays upright and collision is unaffected — this is pure presentation.
func _update_model_pose(delta: float, speed_ratio: float, turn: float) -> void:
	if _model_pivot == null:
		return
	var weight: float = 1.0 - exp(-LEAN_SPEED * delta)
	# Both leans scale with speed: a standing turn shouldn't bank, and a stroll
	# shouldn't lean forward like a sprint.
	_bank = lerpf(_bank, -turn * BANK_MAX * speed_ratio, weight)
	_pitch = lerpf(_pitch, -PITCH_MAX * speed_ratio, weight)

	# Match the slope underfoot; airborne, ease back to upright.
	var normal: Vector3 = get_floor_normal() if is_on_floor() else Vector3.UP
	if normal.length_squared() < 0.001:
		normal = Vector3.UP
	# Into the body's own space, so the tilt is independent of which way we face.
	var local_up: Vector3 = (global_transform.basis.inverse() * normal).normalized()
	local_up = Vector3.UP.slerp(local_up, GROUND_ALIGN)  # partial: see GROUND_ALIGN

	var target := Basis.IDENTITY
	var axis: Vector3 = Vector3.UP.cross(local_up)
	if axis.length_squared() > 0.000001:
		target = Basis(axis.normalized(), Vector3.UP.angle_to(local_up))
	target *= Basis.from_euler(Vector3(_pitch, 0.0, _bank))
	_model_pivot.basis = _model_pivot.basis.slerp(target, weight)
