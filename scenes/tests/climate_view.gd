extends Node3D
## Throwaway dev view: boots the open world, finds the highest summit by raycast
## scan, parks the player on it and frames a camera on them — so tools/shot.sh
## can photograph the altitude weather (wind streaks, frost, snow) and the
## day/night cycle far from the spawn valley. Not part of the game.
##
##   VIEW_HOUR=18.4 bash tools/shot.sh climate scenes/tests/climate_view.tscn
##
## VIEW_HOUR (0-24) picks the time of day; unset leaves the cycle's default.

func _ready() -> void:
	var world: Node = load("res://scenes/open-world/open-world.tscn").instantiate()
	add_child(world)
	var hour_env := OS.get_environment("VIEW_HOUR")
	await get_tree().physics_frame
	await get_tree().physics_frame

	# Scan for the summit: rain rays down over the map and keep the highest hit.
	var player: CharacterBody3D = world.get_node("CharacterBody3D")
	var space := player.get_world_3d().direct_space_state
	var best := Vector3(0.0, -INF, 0.0)
	for zi in range(-480, 481, 24):
		for xi in range(-480, 481, 24):
			var q := PhysicsRayQueryParameters3D.create(
				Vector3(xi, 800.0, zi), Vector3(xi, -800.0, zi))
			q.exclude = [player.get_rid()]
			var hit := space.intersect_ray(q)
			if hit and hit.position.y > best.y:
				best = hit.position
	print("climate_view: summit at (%.0f, %.1f, %.0f)" % [best.x, best.y, best.z])

	# Give the world's own _start_game a moment to drop the player at spawn,
	# then override: stand them on the summit instead.
	await get_tree().process_frame
	await get_tree().process_frame
	player.global_position = best + Vector3(0.0, 1.2, 0.0)
	player.set("_spawn_transform", player.global_transform)

	if hour_env != "":
		var cycle: Node = world.get_node_or_null("DayNightCycle")
		if cycle != null:
			cycle.set_hour(float(hour_env))

	var cam := Camera3D.new()
	cam.fov = 70.0
	add_child(cam)
	cam.global_position = best + Vector3(-6.0, 4.5, 7.0)
	cam.look_at(best + Vector3(2.0, 1.0, -4.0))
	await get_tree().process_frame
	cam.make_current()
