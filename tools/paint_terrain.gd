extends SceneTree
## One-shot terrain-map painter (run headless, then re-import):
##   godot --headless --path . -s res://tools/paint_terrain.gd
##
## Reads Terrain/height.res and rewrites two of HTerrain's data maps in place:
##   splat.png  — paints sand (slot 3, alpha) on real shores — near the
##                waterline by DISTANCE, not just altitude — and stone (slot 1,
##                green) on steep coastal cliffs, so an abrupt island edge reads
##                as rock dropping into the sea instead of grass or a stray
##                sand stripe halfway up a cliff face.
##   detail.png — the grass detail-layer density map (L8): dense where the
##                grass splat weight is high, fading out at the beach, at
##                altitude (approaching altitude_effects.gd's cold band) and on
##                steep slopes, broken up by patch noise so meadows have gaps.
##
## The painter is idempotent: it first recovers the pre-sand base weights from
## the current splat (dividing out the old sand overlay), then applies cliffs
## and sand fresh, so it can be re-run whenever the heightmap or sea changes.
##
## Heights are in MAP units here (world y = value * 1.5, the HTerrain node's y
## scale; sea sits at world 15 = map 10). Distances are in heightmap pixels
## (1 px = 2 m world). All fades are kept WIDE on purpose: mid splat weights
## are where the shader's depth blending lets the bumpier texture win
## per-pixel, which is what gives the mountain grass->stone band its speckled
## look — the beach and the cliffs get the same treatment.

const SEA_MAP_H := 10.0           # world 15.0 / 1.5
const SAND_FULL_H := 11.2         # altitude cap: sand unhindered below this
const SAND_FADE_H := 15.6         # ...and impossible above (world ~23.4), so
								  # the rim of a tall cliff never turns beach
const SAND_JITTER := 0.7          # noise wobble on the altitude thresholds
const SAND_SLOPE_DAMP_DEG := 26.0 # sand thins out beyond this steepness
const SAND_SLOPE_END_DEG := 40.0  # ...and is gone past this

## Shore distance band (px from the nearest underwater pixel): full sand
## within ~8 m of the waterline, fading out by ~22 m, wobbled so the beach
## width wanders. Low ground far from any water stays meadow.
const SHORE_FULL_PX := 4.0
const SHORE_FADE_PX := 11.0
const SHORE_JITTER_PX := 2.5

## Steep coastal ground turns to stone (slot 1 — plain stone, NOT slot 2's
## iced summit stone). Gated by distance to water so inland hillsides keep
## their painted look. The slope is AVERAGED over a small neighbourhood and
## the window starts well above hill steepness: 25-30-deg grassy bluffs
## (measured all along the west coast) must stay grass — painting them left a
## mangy gravel smear between meadow and beach — and lone steep bumps must not
## become floating gray scabs. Real sculpted cliff edges probe at 40-60+ deg.
const CLIFF_SLOPE_LO_DEG := 32.0
const CLIFF_SLOPE_HI_DEG := 42.0
const CLIFF_SMOOTH_PX := 2        # slope averaged at centre + taps at 1x and
								  # 2x this radius — a lone steep knoll a few
								  # px wide averages below the window and
								  # stays grass; only real cliff FACES paint
const CLIFF_DIST_FULL_PX := 10.0  # full strength within ~20 m of water
const CLIFF_DIST_FADE_PX := 22.0  # gone beyond ~44 m inland

## Sea-cliff colour: the colormap multiplies albedo, and the bare stone
## texture reads cold blue-purple down at the waterline next to warm sand and
## bright grass. Tinting cliff pixels toward warm brown grounds them in the
## beach palette while the summit keeps its cold rock. color.png is all white
## elsewhere, so setting lerp(white, tint, cliff) per pixel stays idempotent.
const CLIFF_TINT := Color(1.0, 0.89, 0.76)

const GRASS_SHORE_LO := 10.8      # blades absent below (map h; still beach)
const GRASS_SHORE_HI := 13.4      # ...full above (world ~20.1)
const GRASS_ALT_LO := 43.0        # full grass below (world ~65 — the spawn
								  # plateau sits at 64-68 and must wave)
const GRASS_ALT_HI := 52.0        # bare above (world 78, well into the cold)
const GRASS_SLOPE_LO_DEG := 24.0
const GRASS_SLOPE_HI_DEG := 38.0
const GRASS_MAX := 0.92           # never carpet-solid — meadows breathe

const Y_SCALE := 1.5              # HTerrain node vertical scale
const XZ_SCALE := 2.0             # HTerrain node horizontal scale


func _init() -> void:
	var height_img := _load_image("res://Terrain/height.res")
	var splat_img := _load_image("res://Terrain/splat.png")
	var color_img := _load_image("res://Terrain/color.png")
	if height_img == null or splat_img == null or color_img == null:
		push_error("could not load height.res / splat.png / color.png")
		quit(1)
		return
	if splat_img.get_format() != Image.FORMAT_RGBA8:
		splat_img.convert(Image.FORMAT_RGBA8)
	if color_img.get_format() != Image.FORMAT_RGBA8:
		color_img.convert(Image.FORMAT_RGBA8)
	var w := height_img.get_width()
	var h := height_img.get_height()

	var shore_dist := _water_distance_px(height_img, w, h)
	var slope_map := PackedFloat32Array()
	slope_map.resize(w * h)
	for y in h:
		for x in w:
			slope_map[y * w + x] = _slope_deg(height_img, x, y, w, h)

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
	var cliff_px := 0
	var grass_px := 0

	for y in h:
		for x in w:
			var hm := height_img.get_pixel(x, y).r
			var slope_deg: float = slope_map[y * w + x]
			var wobble := noise.get_noise_2d(x, y)  # -1..1, shared by both fades
			var dist: float = shore_dist[y * w + x]

			# --- recover the pre-sand base weights --------------------------
			# Old runs wrote rgb *= (1-sand), a = sand; divide the overlay back
			# out. Where old sand saturated (rgb lost), grass is the right
			# guess: everything low enough to sand over was meadow or seabed.
			var c := splat_img.get_pixel(x, y)
			var base := Color(1.0, 0.0, 0.0)
			if c.a < 0.98:
				var inv := 1.0 / (1.0 - c.a)
				base = Color(c.r * inv, c.g * inv, c.b * inv)
				var sum := base.r + base.g + base.b
				if sum > 0.001:
					base = Color(base.r / sum, base.g / sum, base.b / sum)

			# --- coastal cliffs: steep ground near water turns to stone -----
			var avg_slope := slope_deg
			for r in [CLIFF_SMOOTH_PX, CLIFF_SMOOTH_PX * 2]:
				avg_slope += slope_map[y * w + maxi(x - r, 0)] \
						+ slope_map[y * w + mini(x + r, w - 1)] \
						+ slope_map[maxi(y - r, 0) * w + x] \
						+ slope_map[mini(y + r, h - 1) * w + x]
			avg_slope /= 9.0
			var cliff := smoothstep(
					CLIFF_SLOPE_LO_DEG, CLIFF_SLOPE_HI_DEG, avg_slope)
			cliff *= 1.0 - smoothstep(
					CLIFF_DIST_FULL_PX, CLIFF_DIST_FADE_PX, dist)
			if cliff > 0.003:
				base = Color(base.r * (1.0 - cliff),
						base.g * (1.0 - cliff) + cliff,
						base.b * (1.0 - cliff))
				if cliff > 0.5:
					cliff_px += 1
			color_img.set_pixel(x, y, Color(
					lerpf(1.0, CLIFF_TINT.r, cliff),
					lerpf(1.0, CLIFF_TINT.g, cliff),
					lerpf(1.0, CLIFF_TINT.b, cliff), 1.0))

			# --- sand: a real shore = near water, low and gentle ------------
			var sand := 1.0 - smoothstep(
					SHORE_FULL_PX + wobble * SHORE_JITTER_PX,
					SHORE_FADE_PX + wobble * SHORE_JITTER_PX, dist)
			sand *= 1.0 - smoothstep(SAND_FULL_H + wobble * SAND_JITTER,
					SAND_FADE_H + wobble * SAND_JITTER, hm)
			sand *= 1.0 - smoothstep(
					SAND_SLOPE_DAMP_DEG, SAND_SLOPE_END_DEG, slope_deg)
			var out := Color(base.r * (1.0 - sand), base.g * (1.0 - sand),
					base.b * (1.0 - sand), sand)
			splat_img.set_pixel(x, y, out)
			if sand > 0.5:
				sand_px += 1

			# --- grass density ----------------------------------------------
			var density := out.r  # grass splat weight, post-cliff, post-sand
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
	color_img.save_png(dir + "/color.png")
	var total := float(w * h) / 100.0
	print("painted: sand on %.1f%% of map, cliffs on %.1f%%, grass on %.1f%%" %
			[sand_px / total, cliff_px / total, grass_px / total])
	quit(0)


## Distance (px) from each pixel to the nearest underwater pixel, via a
## two-pass 3-4 chamfer transform. Underwater = below the sea plane, so inland
## hollows the sea floods count as water too — their rims get beaches.
func _water_distance_px(img: Image, w: int, h: int) -> PackedFloat32Array:
	var big := float(w + h)
	var d := PackedFloat32Array()
	d.resize(w * h)
	for y in h:
		for x in w:
			d[y * w + x] = 0.0 if img.get_pixel(x, y).r < SEA_MAP_H else big
	const ORTHO := 1.0
	const DIAG := 1.41421356
	for y in h:  # forward: top-left neighbours
		for x in w:
			var i := y * w + x
			if d[i] == 0.0:
				continue
			var best := d[i]
			if x > 0:
				best = minf(best, d[i - 1] + ORTHO)
			if y > 0:
				best = minf(best, d[i - w] + ORTHO)
				if x > 0:
					best = minf(best, d[i - w - 1] + DIAG)
				if x < w - 1:
					best = minf(best, d[i - w + 1] + DIAG)
			d[i] = best
	for y in range(h - 1, -1, -1):  # backward: bottom-right neighbours
		for x in range(w - 1, -1, -1):
			var i := y * w + x
			if d[i] == 0.0:
				continue
			var best := d[i]
			if x < w - 1:
				best = minf(best, d[i + 1] + ORTHO)
			if y < h - 1:
				best = minf(best, d[i + w] + ORTHO)
				if x < w - 1:
					best = minf(best, d[i + w + 1] + DIAG)
				if x > 0:
					best = minf(best, d[i + w - 1] + DIAG)
			d[i] = best
	return d


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
