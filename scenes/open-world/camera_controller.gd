extends Camera3D
## OpenWorldCamera
##
## Smooth third-person follow camera for the open-world sandbox. Previously the
## Camera3D was a direct child of the player, so it snapped rigidly to every
## turn; this controller instead lerps position/rotation each frame and listens
## to the player's [signal OpenWorldPlayer.walking_state_changed] signal for a
## subtle FOV kick, rather than polling the player's state every frame.

## Path to the CharacterBody3D to follow.
@export var target_path: NodePath
## Offset from the target, expressed in the target's local space (matches the
## old parented offset so the camera sits up and behind the player).
@export var follow_offset: Vector3 = Vector3(0, 2.5, 6)
## Height above the target's origin the camera looks at.
@export var look_height: float = 1.2
## Higher = camera position catches up to the target faster.
@export var follow_speed: float = 6.0
## Higher = camera rotation catches up to the target facing faster.
@export var look_speed: float = 8.0
## Higher = FOV kick eases in/out faster.
@export var fov_speed: float = 6.0
@export var base_fov: float = 70.0
@export var walking_fov: float = 76.0

var _target: Node3D
var _walking: bool = false

func _ready() -> void:
	_target = get_node_or_null(target_path) as Node3D
	if _target == null:
		push_error("OpenWorldCamera: target_path '%s' did not resolve to a Node3D" % target_path)
		return
	if _target.has_signal("walking_state_changed"):
		_target.walking_state_changed.connect(_on_walking_state_changed)


func _process(delta: float) -> void:
	if _target == null:
		return

	var target_xform: Transform3D = _target.global_transform
	var desired_position: Vector3 = target_xform.origin + target_xform.basis * follow_offset
	global_position = global_position.lerp(desired_position, 1.0 - exp(-follow_speed * delta))

	var look_target: Vector3 = target_xform.origin + Vector3.UP * look_height
	if not is_equal_approx(global_position.distance_squared_to(look_target), 0.0):
		var desired_basis: Basis = global_transform.looking_at(look_target, Vector3.UP).basis
		global_transform.basis = global_transform.basis.slerp(desired_basis, 1.0 - exp(-look_speed * delta))

	fov = lerpf(fov, walking_fov if _walking else base_fov, 1.0 - exp(-fov_speed * delta))


func _on_walking_state_changed(is_walking: bool) -> void:
	_walking = is_walking
