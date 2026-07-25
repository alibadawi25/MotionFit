extends SceneTree
## Counts what world_scatter.gd actually plants, per MultiMesh, without opening
## a window: `godot --headless --path . -s res://tools/probe_scatter.gd`.
##
## Exists because "I can't see any bushes" has at least three causes that look
## identical on screen — none placed, placed but culled, placed but sunk into
## the terrain — and only the first shows up in a count.

func _initialize() -> void:
	var world: Node = load("res://scenes/open-world/open-world.tscn").instantiate()
	root.add_child(world)
	await process_frame
	await process_frame
	var scatter := world.find_child("WorldScatter", true, false)
	if scatter == null:
		print("PROBE: no WorldScatter node")
		quit()
		return
	var total := 0
	for child in scatter.get_children():
		if child is MultiMeshInstance3D:
			var n: int = child.multimesh.instance_count
			total += n
			print("PROBE %-14s %5d  aabb=%s" % [child.name, n,
					str(child.multimesh.get_aabb().size.round())])
	# Density is what actually tells you whether a layer will read on screen.
	# The island is roughly 976 m across; one plant per 300 m² is a lone bush
	# every 17 m, which is "occasional scenery", not "understory".
	print("PROBE total instances: %d (1 per %.0f m^2 of island)"
			% [total, 976.0 * 976.0 / maxf(total, 1.0)])
	quit()

# DON'T add per-instance position printing here: under --headless the dummy
# renderer has no MultiMesh buffer to read back, so get_instance_transform()
# returns IDENTITY for every instance of every batch — including the conifers,
# which visibly render fine. It looks exactly like a placement bug and isn't.
# Aim screenshots with tools/probe_spot.gd instead.
