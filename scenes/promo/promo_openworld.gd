extends Node3D
## PromoOpenWorld — cinematic photo-mode for the Open World.
##
## Instances the real open-world scene, then hides the gameplay layer (HUD, pause
## menu, player capsule), pins a golden-hour sky and frames a single still camera
## high over the terrain so the fog and horizon do the talking. Used ONLY to shoot
## promo art with tools/shot.sh — it is never launched in-game, so none of this
## touches the shipped experience.
##
## Tune CAM_POS / CAM_LOOK / GOLDEN_HOUR between shots and re-run /shot.

const WORLD := preload("res://scenes/open-world/open-world.tscn")

## Camera pose. The spawn plateau sits near (408, 40); the sea plane is at y=15;
## the coast runs down the island's east side. Sit LOW OVER THE WATER (east) and
## look back at the shore on a diagonal, so water fills the foreground, the
## coastline recedes to the side, and the island's grassy hills + fog rise beyond.
## Defaults can be overridden per-shot without editing this file, via env vars
## PROMO_POS / PROMO_LOOK ("x,y,z") and PROMO_FOV — handy for scouting the coast
## with tools/shot.sh (the env is inherited by the Godot child process).
const CAM_POS: Vector3 = Vector3(525.0, 30.0, 60.0)
const CAM_LOOK: Vector3 = Vector3(455.0, 21.0, -60.0)
const CAM_FOV: float = 62.0
## Grass blades are an HTerrain detail layer culled past this range; the shipped
## 115 m keeps frames cheap in play, but a still promo can afford a lush, deep
## carpet — pushed out so grass reaches up the hillside, not just at our feet.
const GRASS_VIEW_DISTANCE: float = 340.0
## Warm, low sun with the dusk band lit but the sun still carrying energy.
const GOLDEN_HOUR: float = 17.2

var _cam: Camera3D
var _world: Node

func _ready() -> void:
	_world = WORLD.instantiate()
	add_child(_world)

	# Pin the light. DayNightCycle duplicated + captured the environment in its
	# own _ready (already run, synchronously, by add_child above), so set_hour now
	# takes effect; freezing its _process stops the clock drifting off golden hour.
	var dnc := _world.get_node_or_null("DayNightCycle")
	if dnc != null and dnc.has_method("set_hour"):
		dnc.set_hour(GOLDEN_HOUR)
		dnc.set_process(false)

	# Keep the world's edge out of the shot: hide the fog-rim border wall.
	var border := _world.get_node_or_null("WorldBorder") as Node3D
	if border != null:
		border.visible = false

	# Push the grass detail layer's draw distance out so blades carpet the whole
	# hillside in frame, not just the few metres nearest the camera.
	var grass := _world.get_node_or_null("HTerrain/GrassLayer")
	if grass != null:
		grass.set("view_distance", GRASS_VIEW_DISTANCE)

	_cam = Camera3D.new()
	_cam.fov = _env_float("PROMO_FOV", CAM_FOV)
	_cam.far = 4000.0
	add_child(_cam)
	_cam.global_position = _env_vec("PROMO_POS", CAM_POS)
	_cam.look_at(_env_vec("PROMO_LOOK", CAM_LOOK), Vector3.UP)
	_cam.current = true


## Reads "x,y,z" from environment variable [param key], or returns [param fallback].
func _env_vec(key: String, fallback: Vector3) -> Vector3:
	var s := OS.get_environment(key)
	if s.is_empty():
		return fallback
	var p := s.split(",")
	if p.size() != 3:
		return fallback
	return Vector3(p[0].to_float(), p[1].to_float(), p[2].to_float())


func _env_float(key: String, fallback: float) -> float:
	var s := OS.get_environment(key)
	return s.to_float() if not s.is_empty() else fallback


func _process(_delta: float) -> void:
	# The world builds its HUD a physics frame after _start_game, so keep clearing
	# the gameplay layer (and re-asserting our camera) every frame.
	if _cam != null and not _cam.current:
		_cam.current = true
	if _world == null:
		return
	var body := _world.get_node_or_null("CharacterBody3D") as Node3D
	if body != null:
		body.visible = false
	for child in _world.get_children():
		if child is CanvasLayer:
			(child as CanvasLayer).visible = false
		elif child is Control:
			(child as Control).visible = false
