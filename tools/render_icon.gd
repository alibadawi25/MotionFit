extends SceneTree
## Rasterizes icon.svg to the PNG sizes an .ico wants, into build/icons/.
## Run headless by tools/build_release.py:
##   Godot --headless --path . -s res://tools/render_icon.gd
## tools/make_ico.py then stitches the PNGs into build/icons/motionfit.ico.

const SIZES: Array[int] = [16, 24, 32, 48, 64, 128, 256]

func _init() -> void:
	var svg := FileAccess.get_file_as_string("res://icon.svg")
	if svg.is_empty():
		push_error("render_icon: icon.svg missing or empty")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute("res://build/icons")
	for size: int in SIZES:
		var img := Image.new()
		# icon.svg is authored at 128px; scale renders it crisp at each size.
		var err := img.load_svg_from_string(svg, float(size) / 128.0)
		if err != OK or img.get_width() != size:
			# Rounding can land a pixel off; resize to the exact cell.
			img.resize(size, size, Image.INTERPOLATE_LANCZOS)
		img.save_png("res://build/icons/icon_%d.png" % size)
	print("render_icon: wrote %d sizes to build/icons/" % SIZES.size())
	quit(0)
