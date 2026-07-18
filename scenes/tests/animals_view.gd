extends Node3D
## AnimalsView
##
## Throwaway view scene (shot.sh pairing) that lines up every AnimalMeshes
## builder on a plain meadow under a simple sun for a style check. Small
## species are SCALED UP for legibility — each label states the real size, and
## the scale factor when it isn't ×1.

const AnimalMeshes := preload("res://scenes/open-world/animal_meshes.gd")

## name, mesh, x position, presentation scale, real-size note, hover height
var _specs: Array = []

func _ready() -> void:
	_specs = [
		["DEER", AnimalMeshes.build_deer(), -2.9, 1.0, "~1.7 m", 0.0],
		["FOX", AnimalMeshes.build_fox(), -1.4, 1.0, "~0.5 m", 0.0],
		["RABBIT", AnimalMeshes.build_rabbit(), -0.2, 1.6, "~35 cm · ×1.6", 0.0],
		["GULL", AnimalMeshes.build_gull(), 0.95, 1.4, "~0.9 m span · ×1.4", 0.42],
		["SONGBIRD", AnimalMeshes.build_songbird(), 2.3, 3.5, "~13 cm · ×3.5", 0.0],
		["BUTTERFLY", AnimalMeshes.build_butterfly(), 3.5, 4.5, "~16 cm span · ×4.5", 0.12],
	]
	_build_environment()
	_build_lineup()
	_build_camera()


func _build_environment() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-38.0, 28.0, 0.0)
	sun.light_energy = 1.25
	sun.shadow_enabled = true
	add_child(sun)

	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.3, 0.5, 0.75)
	sky_mat.sky_horizon_color = Color(0.74, 0.79, 0.83)
	sky_mat.ground_bottom_color = Color(0.2, 0.24, 0.2)
	sky_mat.ground_horizon_color = Color(0.64, 0.68, 0.62)
	var sky := Sky.new()
	sky.sky_material = sky_mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 1.0
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(200.0, 200.0)
	var grass := StandardMaterial3D.new()
	grass.albedo_color = Color(0.29, 0.4, 0.21)
	grass.roughness = 1.0
	plane.material = grass
	ground.mesh = plane
	add_child(ground)


func _build_lineup() -> void:
	var stagger := false
	for spec in _specs:
		var instance := MeshInstance3D.new()
		instance.mesh = spec[1]
		var s: float = spec[3]
		instance.transform = Transform3D(
				Basis(Vector3.UP, deg_to_rad(-18.0)).scaled(Vector3.ONE * s),
				Vector3(spec[2], float(spec[5]) * s, 0.0))
		add_child(instance)

		var label := Label3D.new()
		label.text = "%s\n%s" % [spec[0], spec[4]]
		label.font_size = 38
		label.outline_size = 10
		label.modulate = Color(0.97, 0.97, 0.99)
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		# Alternate label heights so neighbouring captions never collide.
		var lift: float = 0.75 if stagger else 0.0
		stagger = not stagger
		label.position = Vector3(spec[2], _label_height(instance, s) + lift, 0.0)
		add_child(label)


## Puts a label a hand above the tallest point of the (scaled) mesh.
func _label_height(instance: MeshInstance3D, s: float) -> float:
	var top: float = instance.mesh.get_aabb().end.y * s + instance.position.y
	return top + 0.35


func _build_camera() -> void:
	var cam := Camera3D.new()
	cam.position = Vector3(0.2, 2.3, 5.6)
	add_child(cam)
	cam.look_at(Vector3(0.2, 0.6, 0.0))
	cam.current = true
