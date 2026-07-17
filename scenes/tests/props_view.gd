extends Node3D
## Dev-only prop lineup: builds one of each RunnerTrack scenery prop (plus a
## ground slab and a hazard block) under neutral light so the textured models
## can be inspected without the runner's near-black red fog. Screenshot it via
## tools/shot.sh props res://scenes/tests/props_view.tscn


func _ready() -> void:
	var t := RunnerTrack.new()
	add_child(t)
	add_child(t._prop_box(Vector3(22, 0.2, 10), Vector3(1, -0.1, 0),
			t._mat("dirt", RunnerTrack.GROUND_UV)))
	add_child(t._prop_box(Vector3(6, 0.8, 0.3), Vector3(-4, 0.4, -2.5),
			t._mat("rubble", RunnerTrack.RAIL_UV)))
	add_child(t._gravestone(0, 1.0, Vector3(-6.2, 0, 0)))
	add_child(t._dead_tree(1, 1.0, Vector3(-3.8, 0, -0.5)))
	add_child(t._broken_pillar(2, 1.0, Vector3(-1.6, 0, 0)))
	var crypt := t._crypt(1.0, Vector3(2.2, 0, -0.8))
	crypt.rotation.y = PI * 0.5  # aim the doorway at the camera
	add_child(crypt)
	add_child(t._fence(4, 1.0, Vector3(6.2, 0, 0)))
	add_child(t._hazard_box(Vector3(2.2, 0.7, 0.6), Vector3(9.2, 0.35, 0)))
