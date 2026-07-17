extends SceneTree
## Throwaway probe: print the terrain heightmap's min/max/histogram so a sea
## level can be chosen. Run:
##   godot --headless --path . -s res://tools/probe_height.gd

func _init() -> void:
	var res = load("res://Terrain/height.res")
	if res == null:
		push_error("could not load height.res")
		quit(1)
		return
	var img: Image = res if res is Image else res.get_image()
	if img == null:
		push_error("no height image")
		quit(1)
		return
	if img.is_compressed():
		img.decompress()
	var w := img.get_width()
	var h := img.get_height()
	var lo := INF
	var hi := -INF
	var buckets := {}
	for y in range(0, h, 4):
		for x in range(0, w, 4):
			var v := img.get_pixel(x, y).r
			lo = min(lo, v)
			hi = max(hi, v)
			var b := int(floor(v / 5.0)) * 5
			buckets[b] = buckets.get(b, 0) + 1
	print("size: %dx%d  min: %.2f  max: %.2f" % [w, h, lo, hi])
	# World coords (centered terrain: world = pixel - size/2) of the deepest spots.
	for y in range(8, h, 16):
		for x in range(8, w, 16):
			var v := img.get_pixel(x, y).r
			if v < 4.0:
				print("low  world(%4d, %4d)  h=%.2f" % [x - w / 2, y - h / 2, v])
	var keys := buckets.keys()
	keys.sort()
	var total := 0
	for k in keys:
		total += buckets[k]
	var cum := 0
	for k in keys:
		cum += buckets[k]
		print("h %4d..%4d : %6d  (cum %5.1f%%)" % [k, k + 5, buckets[k], 100.0 * cum / total])
	quit(0)
