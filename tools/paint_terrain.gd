extends SceneTree
## One-shot terrain-map painter (run headless, then re-import):
##   godot --headless --path . -s res://tools/paint_terrain.gd
##
## Reads Terrain/height.res and rewrites two of HTerrain's data maps in place:
##   splat.png  — paints the 4th texture slot (sand, alpha channel) around and
##                below the waterline, jittered by noise so the shoreline
##                wanders, and damped on steep ground so cliffs stay stone.
##   detail.png — CREATES the grass detail-layer density map (L8): dense where
##                the grass splat weight is high, fading out at the beach, at
##                altitude (approaching altitude_effects.gd's cold band) and on
##                steep slopes, broken up by patch noise so meadows have gaps.
##
## Heights are in MAP units here (world y = value * 1.5, the HTerrain node's y
## scale; sea sits at world 13.5 = map 9). All thresholds below are map-space.

const SEA_MAP_H := 9.0            # world 13.5 / 1.5
const SAND_FULL_H := 10.2         # fully sand below this (world ~15.3)
const SAND_FADE_H := 11.6         # no sand above this (world ~17.4)
const SAND_JITTER := 0.7          # noise wobble on both thresholds
const SAND_SLOPE_DAMP_DEG := 26.0 # sand thins out beyond this steepness
const SAND_SLOPE_END_DEG := 40.0  # …and is gone past this (cliff shorelines)

const GRASS_SHORE_LO := 10.8      # grass absent below (still beach)
const GRASS_SHORE_HI := 12.4      # …full above (world ~18.6)
const GRASS_ALT_LO := 43.0        # full grass below (world ~65 — the spawn
								  # plateau sits at 64-68 and must wave)
const GRASS_ALT_HI := 52.0        # bare above (world 78, well into the cold);
								  # the grass-splat weight already removes
								  # blades wherever stone/ice takes over
const GRASS_SLOPE_LO_DEG := 24.0
const GRASS_SLOPE_HI_DEG := 38.0
const GRASS_MAX := 0.92           # never carpet-solid — meadows breathe

const Y_SCALE := 1.5              # HTerrain node vertical scale
const XZ_SCALE := 2.0             # HTerrain node horizontal scale


func _init() -> void:
	var height_img := _load_image("res://Terrain/height.res")
	var splat_img := _load_image("res://Terrain/splat.png")
	if height_img == null or splat_img == null:
		push_error("could not load height.res / splat.png")
		quit(1)
		return
	if splat_img.get_format() != Image.FORMAT_RGBA8:
		splat_img.convert(Image.FORMAT_RGBA8)
	var w := height_img.get_width()
	var h := height_img.get_height()

	var noise := FastNoiseLite.new()
	noise.seed = 91
	noise.frequency = 0.035  # ~14 px features: coves rather than pixel fizz
	noise.fractal_octaves = 3

	var patch := FastNoiseLite.new()
	patch.seed = 47
	patch.frequency = 0.02
	patch.fractal_octaves = 3

	var detail_img := Image.create(w, h, false, Image.FORMAT_L8)
	var sand_px := 0
	var grass_px := 0

	for y in h:
		for x in w:
			var hm := height_img.get_pixel(x, y).r
			var slope_deg := _slope_deg(height_img, x, y, w, h)
			var jitter := noise.get_noise_2d(x, y) * SAND_JITTER

			# --- sand weight ------------------------------------------------
			var sand := 1.0 - smoothstep(
					SAND_FULL_H + jitter, SAND_FADE_H + jitter, hm)
			sand *= 1.0 - smoothstep(
					SAND_SLOPE_DAMP_DEG, SAND_SLOPE_END_DEG, slope_deg)
			var c := splat_img.get_pixel(x, y)
			if sand > 0.003:
				c = Color(c.r * (1.0 - sand), c.g * (1.0 - sand),
						c.b * (1.0 - sand), sand)
				splat_img.set_pixel(x, y, c)
				if sand > 0.5:
					sand_px += 1

			# --- grass density ----------------------------------------------
			var density := c.r  # grass splat weight, post-sand
			density *= smoothstep(GRASS_SHORE_LO, GRASS_SHORE_HI, hm)
			density *= 1.0 - smoothstep(GRASS_ALT_LO, GRASS_ALT_HI, hm)
			density *= 1.0 - smoothstep(
					GRASS_SLOPE_LO_DEG, GRASS_SLOPE_HI_DEG, slope_deg)
			# Patchiness: meadows thin toward their edges instead of a carpet.
			var p := 0.62 + 0.5 * patch.get_noise_2d(x, y)  # ~0.12..1.12
			density = clampf(density * clampf(p, 0.0, 1.0), 0.0, GRASS_MAX)
			detail_img.set_pixel(x, y, Color(density, density, density))
			if density > 0.25:
				grass_px += 1

	var dir := ProjectSettings.globalize_path("res://Terrain")
	splat_img.save_png(dir + "/splat.png")
	detail_img.save_png(dir + "/detail.png")
	var total := float(w * h) / 100.0
	print("painted: sand on %.1f%% of map, grass on %.1f%%" %
			[sand_px / total, grass_px / total])
	quit(0)


## Ground steepness in degrees at a heightmap pixel, in WORLD units (heights
## scale by 1.5, ground plane by 2.0 — using raw map units would misread slopes).
func _slope_deg(img: Image, x: int, y: int, w: int, h: int) -> float:
	var x0 := maxi(x - 1, 0)
	var x1 := mini(x + 1, w - 1)
	var y0 := maxi(y - 1, 0)
	var y1 := mini(y + 1, h - 1)
	var dhx := (img.get_pixel(x1, y).r - img.get_pixel(x0, y).r) * Y_SCALE \
			/ ((x1 - x0) * XZ_SCALE)
	var dhy := (img.get_pixel(x, y1).r - img.get_pixel(x, y0).r) * Y_SCALE \
			/ ((y1 - y0) * XZ_SCALE)
	return rad_to_deg(atan(sqrt(dhx * dhx + dhy * dhy)))


func _load_image(path: String) -> Image:
	var res = load(path)
	if res == null:
		return null
	var img: Image = res if res is Image else res.get_image()
	if img != null and img.is_compressed():
		img.decompress()
	return img
