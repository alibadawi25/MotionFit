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

## Metres/second at full march (forward == 1.0).
@export var move_speed: float = 4.0
## Radians/second at full lean (turn == 1.0).
@export var turn_speed: float = 2.5
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

var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
var _was_walking: bool = false
var _stand_height: float = 2.0  # captured from the capsule at _ready

func _ready() -> void:
	# Remember the upright capsule height so crouch can lerp back to it. Make the
	# shape/mesh local to this instance so resizing the capsule at runtime can't
	# leak into any other node that happens to share the resource.
	if _collision.shape is CapsuleShape3D:
		_collision.shape = _collision.shape.duplicate()
		_stand_height = (_collision.shape as CapsuleShape3D).height
	if _mesh.mesh is CapsuleMesh:
		_mesh.mesh = _mesh.mesh.duplicate()


func _physics_process(delta: float) -> void:
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
	else:
		velocity.y -= _gravity * delta
		MotionManager.consume_jump()  # discard jumps that arrive mid-air

	move_and_slide()

	var walking: bool = MotionManager.is_walking()
	if walking != _was_walking:
		_was_walking = walking
		walking_state_changed.emit(walking)


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
