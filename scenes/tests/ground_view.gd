extends Node3D
## Throwaway dev view: boots the open world and parks a camera at a spot given
## by env vars (defaults: head height near the spawn point, looking inland) —
## for photographing the grass detail layer and the tree/rock scatter with
## tools/shot.sh. Not part of the game.
##
##   GV_POS="x,y,z" GV_AT="x,y,z" bash tools/shot.sh name scenes/tests/ground_view.tscn
## GV_HUD=0 hides every CanvasLayer (stat HUD, pause hint) for clean beauty shots.
## GV_FOG scales fog for aerial shots the play-tuned fog would wash out:
## "0" disables fog + the border fog wall entirely, "0.15" keeps a thin haze
## (multiplies fog_density / fog_height_density; border wall hidden either way).

var _hide_hud := false

func _ready() -> void:
	_hide_hud = OS.get_environment("GV_HUD") == "0"
	var world: Node = load("res://scenes/open-world/open-world.tscn").instantiate()
	add_child(world)
	var fog_raw := OS.get_environment("GV_FOG")
	if fog_raw != "":
		var fog_scale := fog_raw.to_float()
		var we: WorldEnvironment = world.find_child("WorldEnvironment", true, false)
		if we != null and we.environment != null:
			if fog_scale <= 0.0:
				we.environment.fog_enabled = false
			else:
				we.environment.fog_density *= fog_scale
				we.environment.fog_height_density *= fog_scale
		# Free (not hide): world_border.gd re-asserts the environment fog
		# density every frame, which would undo the scaling above.
		var border: Node3D = world.find_child("WorldBorder", true, false)
		if border != null:
			border.queue_free()
		# From aerial framings the 1600 m sea plane's square edge shows;
		# stretch it out to the horizon (wave detail is invisible from up here).
		var sea: Node3D = world.find_child("Sea", true, false)
		if sea != null:
			sea.scale = Vector3(5.0, 1.0, 5.0)
	var cam := Camera3D.new()
	cam.fov = 70.0
	add_child(cam)
	cam.global_position = _env_vec3("GV_POS", Vector3(182.0, 70.0, 8.0))
	cam.look_at(_env_vec3("GV_AT", Vector3(150.0, 62.0, -50.0)))
	# Claim the viewport after the world's own rig has finished setting up.
	await get_tree().process_frame
	await get_tree().process_frame
	cam.make_current()


func _process(_delta: float) -> void:
	if not _hide_hud:
		return
	# HUD layers appear over the first seconds (stat HUD, countdown, hints), so
	# keep re-hiding rather than hiding once at _ready.
	for layer in find_children("*", "CanvasLayer", true, false):
		(layer as CanvasLayer).visible = false


func _env_vec3(env_name: String, fallback: Vector3) -> Vector3:
	var raw := OS.get_environment(env_name)
	var parts := raw.split(",", false)
	if parts.size() != 3:
		return fallback
	return Vector3(parts[0].to_float(), parts[1].to_float(), parts[2].to_float())
