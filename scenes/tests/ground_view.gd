extends Node3D
## Throwaway dev view: boots the open world and parks a camera at a spot given
## by env vars (defaults: head height near the spawn point, looking inland) —
## for photographing the grass detail layer and the tree/rock scatter with
## tools/shot.sh. Not part of the game.
##
##   GV_POS="x,y,z" GV_AT="x,y,z" bash tools/shot.sh name scenes/tests/ground_view.tscn

func _ready() -> void:
	var world: Node = load("res://scenes/open-world/open-world.tscn").instantiate()
	add_child(world)
	var cam := Camera3D.new()
	cam.fov = 70.0
	add_child(cam)
	cam.global_position = _env_vec3("GV_POS", Vector3(182.0, 70.0, 8.0))
	cam.look_at(_env_vec3("GV_AT", Vector3(150.0, 62.0, -50.0)))
	# Claim the viewport after the world's own rig has finished setting up.
	await get_tree().process_frame
	await get_tree().process_frame
	cam.make_current()


func _env_vec3(env_name: String, fallback: Vector3) -> Vector3:
	var raw := OS.get_environment(env_name)
	var parts := raw.split(",", false)
	if parts.size() != 3:
		return fallback
	return Vector3(parts[0].to_float(), parts[1].to_float(), parts[2].to_float())
