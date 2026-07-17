extends RefCounted
## RigUtils
##
## Small static helpers for placing the generated GLB figures (player + zombie).
## The models come out of the Python generator with their origin at the HIPS, not
## the soles, so before a figure can stand on the ground you must measure its real
## vertical extent and lift it so its lowest vertex rests on the floor. The
## open-world player does this inline; the runner reuses it through here so the
## same measurement isn't written twice.
class_name RigUtils


## Combined axis-aligned bounds of every visual in [param root], expressed in
## [param root]'s own local space — used to find where a model's feet really are.
static func model_aabb(root: Node3D) -> AABB:
	var bounds := AABB()
	var seeded := false
	for node in root.find_children("*", "VisualInstance3D", true, false):
		var vis := node as VisualInstance3D
		var xform := root.global_transform.affine_inverse() * vis.global_transform
		var box := xform * vis.get_aabb()
		if seeded:
			bounds = bounds.merge(box)
		else:
			bounds = box
			seeded = true
	return bounds


## Lifts [param character] so its lowest vertex sits at local y = [param floor_y]
## within its parent, and turns it to face [param face_yaw] (radians). Returns the
## foot offset applied, in case the caller wants to animate around it.
static func plant_feet(character: Node3D, floor_y: float = 0.0,
		face_yaw: float = 0.0) -> float:
	var feet_offset: float = -model_aabb(character).position.y
	character.position.y = floor_y + feet_offset
	character.rotation.y = face_yaw
	return feet_offset


## Loops every animation clip in [param anim] except any named in
## [param one_shot_names], which are left non-looping so they can play through
## once. GLB clips import non-looping by default.
static func loop_clips(anim: AnimationPlayer, one_shot_names: Array = []) -> void:
	for name in anim.get_animation_list():
		var clip := anim.get_animation(name)
		clip.loop_mode = (Animation.LOOP_NONE if one_shot_names.has(name)
				else Animation.LOOP_LINEAR)
