extends Node3D
## Throwaway viewer: loads one or two boxer GLBs (paths from env BX1/BX2) via
## GLTFDocument — the same runtime path CharacterFactory uses — and stands them
## on a small plinth so tools/shot.sh can verify the boxing gear. Not shipped.

func _ready() -> void:
	var paths: Array[String] = []
	for key in ["BX1", "BX2"]:
		var p := OS.get_environment(key)
		if p != "":
			paths.append(p)
	if paths.is_empty():
		paths.append("res://assets/models/generated_human/human.glb")
	var xs := [0.0] if paths.size() == 1 else [-0.7, 0.7]
	for i in paths.size():
		var fig := _load_glb(paths[i])
		if fig != null:
			fig.position = Vector3(xs[i], 0.0, 0.0)
			fig.rotation.y = deg_to_rad(28.0)
			add_child(fig)
			# Play a clip so the gear rides the pose; prefer the boxing guard.
			var anim: AnimationPlayer = fig.find_child("AnimationPlayer", true, false)
			if anim != null:
				var clips := anim.get_animation_list()
				for c in clips:
					anim.get_animation(c).loop_mode = Animation.LOOP_LINEAR
				anim.play("guard" if clips.has("guard") else clips[0])

func _load_glb(path: String) -> Node3D:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(path, state) != OK:
		push_warning("boxer_view: could not parse %s" % path)
		return null
	return doc.generate_scene(state)
