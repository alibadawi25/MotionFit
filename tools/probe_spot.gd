extends SceneTree
## Prints world height + slope for candidate spots, for siting landmarks:
##   SPOTS="x,z;x,z;..." godot --headless --path . -s res://tools/probe_spot.gd
## World x/z are metres (terrain centre 0,0); heights come out in world metres.

const Y_SCALE := 1.5
const XZ_SCALE := 2.0
const CENTER_PX := 256.0


func _init() -> void:
	var res: Resource = load("res://Terrain/height.res")
	var img: Image = res if res is Image else (res as Texture2D).get_image()
	if img == null:
		push_error("could not load height.res")
		quit(1)
		return
	if img.is_compressed():
		img.decompress()
	for spot in OS.get_environment("SPOTS").split(";", false):
		var p := spot.split(",", false)
		if p.size() != 2:
			continue
		var wx := p[0].to_float()
		var wz := p[1].to_float()
		var mx := wx / XZ_SCALE + CENTER_PX
		var mz := wz / XZ_SCALE + CENTER_PX
		var wy := _height_at(img, mx, mz) * Y_SCALE
		var dhx := (_height_at(img, mx + 1.0, mz) - _height_at(img, mx - 1.0, mz)) \
				* Y_SCALE / (2.0 * XZ_SCALE)
		var dhz := (_height_at(img, mx, mz + 1.0) - _height_at(img, mx, mz - 1.0)) \
				* Y_SCALE / (2.0 * XZ_SCALE)
		var slope := rad_to_deg(atan(sqrt(dhx * dhx + dhz * dhz)))
		var downhill := Vector2(-dhx, -dhz)
		print("(%7.1f, %7.1f)  y %6.1f  slope %4.1f  downhill (%.2f, %.2f)" %
				[wx, wz, wy, slope, downhill.x, downhill.y])
	quit(0)


func _height_at(img: Image, x: float, z: float) -> float:
	var w := img.get_width()
	var h := img.get_height()
	var x0 := clampi(int(floorf(x)), 0, w - 1)
	var z0 := clampi(int(floorf(z)), 0, h - 1)
	var x1 := mini(x0 + 1, w - 1)
	var z1 := mini(z0 + 1, h - 1)
	var fx := clampf(x - x0, 0.0, 1.0)
	var fz := clampf(z - z0, 0.0, 1.0)
	var top := lerpf(img.get_pixel(x0, z0).r, img.get_pixel(x1, z0).r, fx)
	var bot := lerpf(img.get_pixel(x0, z1).r, img.get_pixel(x1, z1).r, fx)
	return lerpf(top, bot, fz)
