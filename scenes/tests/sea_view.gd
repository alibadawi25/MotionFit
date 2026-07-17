extends Node3D
## Throwaway dev view: boots the open world and parks a camera over the flooded
## north basin (z ~ -240) so tools/shot.sh can photograph the sea, which is
## nowhere near the player spawn. Not part of the game.

func _ready() -> void:
	var world: Node = load("res://scenes/open-world/open-world.tscn").instantiate()
	add_child(world)
	var cam := Camera3D.new()
	cam.fov = 65.0
	add_child(cam)
	cam.global_position = Vector3(120.0, 14.0, -200.0)
	cam.look_at(Vector3(20.0, 8.5, -245.0))
	# Claim the viewport after the world's own rig has finished setting up.
	await get_tree().process_frame
	await get_tree().process_frame
	cam.make_current()
