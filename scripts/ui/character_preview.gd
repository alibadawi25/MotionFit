extends SubViewportContainer
class_name CharacterPreview
## CharacterPreview
##
## A small self-contained 3D turntable for showing a character figure inside a
## menu screen (the profile screen's live appearance preview). Owns its own
## World3D so menu scenes don't need any 3D setup of their own; the figure
## slowly rotates and plays its "idle" clip. Call [method show_figure] with a
## freshly built node (from CharacterFactory) whenever the look changes.

## Turntable speed (rad/s). Slow enough to inspect, fast enough to see the back.
const SPIN_SPEED: float = 0.6
## Idle clip name baked into the generated GLB (see export_glb.py).
const CLIP_IDLE: String = "idle"

var _viewport: SubViewport
var _camera: Camera3D
var _pivot: Node3D  # spins; the figure hangs under it, feet at the pivot origin
var _figure: Node3D

func _ready() -> void:
	stretch = true
	custom_minimum_size = Vector2(320, 460)
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.transparent_bg = true  # let the menu panel show through
	add_child(_viewport)

	_camera = Camera3D.new()
	_camera.current = true
	_camera.fov = 40.0  # narrow lens so the figure fills the small viewport
	_viewport.add_child(_camera)

	# Key light from the front-left plus soft ambient so the dark side reads.
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-35, -30, 0)
	_viewport.add_child(light)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.65, 0.7, 0.8)
	env.environment.ambient_light_energy = 0.9
	_viewport.add_child(env)

	_pivot = Node3D.new()
	_viewport.add_child(_pivot)


func _process(delta: float) -> void:
	_pivot.rotate_y(SPIN_SPEED * delta)


## Adopts [param figure] as the displayed character (freeing any previous one),
## plants its feet at the turntable origin, frames the camera to its real
## bounds (body shape varies a lot), and starts its idle clip looping.
func show_figure(figure: Node3D) -> void:
	if _figure != null:
		_figure.queue_free()
	_figure = figure
	_pivot.add_child(figure)

	var bounds: AABB = _model_aabb(figure)
	figure.position.y = -bounds.position.y  # origin is at the hips; lift to soles
	var height: float = maxf(bounds.size.y, 0.1)
	# With the 40° lens, ~1.55×height of distance shows the figure plus a small
	# margin, whatever body shape the generator produced.
	_camera.position = Vector3(0.0, height * 0.52, height * 1.55)
	_camera.look_at(Vector3(0.0, height * 0.5, 0.0))

	var anim: AnimationPlayer = figure.find_child("AnimationPlayer", true, false)
	if anim != null and anim.has_animation(CLIP_IDLE):
		anim.get_animation(CLIP_IDLE).loop_mode = Animation.LOOP_LINEAR
		anim.play(CLIP_IDLE)


## Combined bounds of every visual under [param root], in [param root]'s local
## space (same approach as player.gd's foot planting). Uses each node's local
## transform chain rather than global_transform because [param root] may not be
## inside the tree yet when this runs.
func _model_aabb(root: Node3D) -> AABB:
	var bounds := AABB()
	var seeded := false
	for node in root.find_children("*", "VisualInstance3D", true, false):
		var vis := node as VisualInstance3D
		var xform: Transform3D = vis.transform
		var walker: Node = vis.get_parent()
		while walker != root and walker is Node3D:
			xform = (walker as Node3D).transform * xform
			walker = walker.get_parent()
		var box: AABB = xform * vis.get_aabb()
		if seeded:
			bounds = bounds.merge(box)
		else:
			bounds = box
			seeded = true
	return bounds
