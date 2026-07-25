extends Node3D
## Dev benchmark: boots the open world and flies a camera along a fixed route
## through the four biomes that actually cost something to draw — open meadow,
## the conifer woods, the shoreline (water shader) and the summit (border fog) —
## then prints frame-time statistics to the log.
##
## This exists because the target machine is a laptop with an MX550 that is ALSO
## running the MediaPipe pose pipeline, so the rendering budget is genuinely
## tight: every "make it prettier" change needs a number next to it, not a
## vibe.
##
##   WAIT=100 bash tools/shot.sh perf res://scenes/tests/perf_view.tscn
##
## Env:
##   PERF_LEG_SEC  seconds per leg (default 3.0)
##   PERF_VSYNC=1  measure what a player actually gets instead of the stress mode
##   PERF_MATRIX=1 A/B every entry in CONFIGS instead of just measuring baseline
##
## Reported per leg (or per config in matrix mode):
##   avg   — mean FPS, the headline number
##   p1low — mean FPS of the worst 1% of frames, i.e. the hitching
##   worst — single longest frame (ms); spikes here are stalls, not slowness

## Camera route: from → to over the leg, with a label. Heights are above the
## authored terrain, checked against the shots in tools/shots/.
const LEGS: Array = [
	["meadow", Vector3(407.8, 40.0, -6.0), Vector3(330.0, 52.0, 40.0)],
	["forest", Vector3(-130.0, 56.0, 245.0), Vector3(-60.0, 52.0, 200.0)],
	["shore", Vector3(75.0, 22.0, 240.0), Vector3(120.0, 19.0, 215.0)],
	["summit", Vector3(-40.0, 88.0, -100.0), Vector3(-70.0, 84.0, -135.0)],
]
## Frames at the start of each leg whose timings are thrown away — the first
## frames after a teleport are shader compiles and terrain chunk builds, which
## are real but are a loading cost, not a steady-state cost.
const WARMUP_FRAMES: int = 20
## Measured laps of the route, plus one discarded warm-up lap before them.
##
## The warm-up lap is not optional. Without it this scene was worthless: two
## IDENTICAL back-to-back runs read 48 and 91 FPS overall, because the first run
## paid for shader compilation and cold terrain chunks and the second inherited
## a warm pipeline cache. A lap that is flown and thrown away puts every
## measured lap on the same footing.
const WARMUP_LAPS: int = 1
const MEASURED_LAPS: int = 2

## Even with the warm-up, this is a LAPTOP GPU whose clocks boost and throttle on
## their own schedule, so absolute numbers drift between runs minutes apart. Only
## ever compare runs taken back-to-back, and treat a gap under ~10% as noise.
##
## Which is exactly why PERF_MATRIX exists: it flies every config inside ONE
## process, alternating them across passes, so they share a thermal state and a
## shader cache. Comparing configs across separate runs measures the laptop, not
## the setting.
## Measured 2026-07-25 on the MX550, baseline 20.32 ms/frame:
##   shadows off  +7.58 ms (37.3%)   <- the whole budget is here
##   grass off    +2.86 ms (14.1%)
##   glow off     +1.87 ms ( 9.2%)
##   dof off      +1.46 ms ( 7.2%)
##   ssao off     -0.16 ms (noise)   <- SSAO is free, keep it
##   shadow_110   -0.64 ms           <- shortening the range does NOT help
## So this list now dissects the shadow cost specifically.
## Second pass dissected the shadow cost (tight-spread results only):
##   atlas 4096->2048  +3.60 ms    blend_splits off  +1.55 ms
##   soft filter->hard +2.92 ms    4 splits->2       +0.51 ms (noise)
## `no_shadow` and `shadow_hard` both came back with spreads too wide to trust
## (+3.11..+8.33 and +3.70..+14.44) — soft-shadow cost swings with how much
## penumbra is on screen, so those two need a dedicated run if ever needed.
## This list confirms the COMBINATION, which is the only number worth applying:
## savings across renderer knobs do not simply add.
const CONFIGS: Array = [
	["baseline", {}],
	["t_2048", {"shadow_size": 2048}],
	["t_2048_noblend", {"shadow_size": 2048, "blend": false}],
	["t_2048_nb_2split", {"shadow_size": 2048, "blend": false,
			"splits": DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS}],
]
## Passes over the config list.
##
## Each config is measured PAIRED against its own baseline, back-to-back, and
## only the difference within a pair is kept. This is not fussiness: the first
## attempt here flew every config in list order and reported that turning SSAO
## OFF cost 6.8 ms/frame, that disabling shadows cost 6.5, and so on — every
## config "slower" than baseline, monotonically worse the later it ran. It was
## measuring the GPU heating up over the run, with baseline always going first
## on a cool chip. Pairing cancels any drift slower than one pair.
const MATRIX_PASSES: int = 2

var _cam: Camera3D
var _world: Node
var _leg_sec: float = 3.0


func _ready() -> void:
	var raw := OS.get_environment("PERF_LEG_SEC")
	if raw != "":
		_leg_sec = maxf(raw.to_float(), 1.0)
	# Two different questions, two modes.
	#
	# Default (uncapped): a STRESS measure. The GPU renders flat out, which on a
	# laptop also means it downclocks under sustained load — so these numbers run
	# pessimistic in absolute terms and must NOT be read as "the frame rate".
	# What they are good for is A/B: run before a change, run after, compare.
	#
	# PERF_VSYNC=1: what a player actually gets. Anything short of a flat 60 here
	# is a real dropped frame in real play.
	if OS.get_environment("PERF_VSYNC") == "1":
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
	else:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 0
	_world = load("res://scenes/open-world/open-world.tscn").instantiate()
	add_child(_world)
	_cam = Camera3D.new()
	_cam.fov = 70.0
	add_child(_cam)
	_run.call_deferred()


func _process(_delta: float) -> void:
	if _cam != null and not _cam.current:
		_cam.make_current()  # the player's own rig claims the viewport on spawn
	for layer in find_children("*", "CanvasLayer", true, false):
		(layer as CanvasLayer).visible = false


func _run() -> void:
	for i in 45:
		await get_tree().process_frame  # let terrain, scatter and wildlife build

	# Warm-up lap: flown at full speed and discarded. See WARMUP_LAPS.
	for lap in WARMUP_LAPS:
		await _lap()

	if OS.get_environment("PERF_MATRIX") == "1":
		await _run_matrix()
	else:
		await _run_legs()
	get_tree().quit()


## Default mode: per-leg breakdown of the current scene as authored.
func _run_legs() -> void:
	var per_leg := {}
	for leg in LEGS:
		per_leg[leg[0]] = [] as Array[float]
	for lap in MEASURED_LAPS:
		for leg in LEGS:
			(per_leg[leg[0]] as Array[float]).append_array(await _fly(leg[1], leg[2]))

	var all: Array[float] = []
	print("leg        avg    p1low   worst")
	print("--------------------------------")
	for leg in LEGS:
		var samples: Array[float] = per_leg[leg[0]]
		all.append_array(samples)
		_report(leg[0], samples)
	_report("ALL", all)


## Matrix mode: fly the whole route once per config, twice over, and print each
## config against the baseline so the cost of an effect is a number.
func _run_matrix() -> void:
	# name -> array of per-pair frame-time savings (ms). Positive = turning the
	# effect off made frames cheaper, i.e. the effect costs that much.
	var savings := {}
	var base_samples: Array[float] = []
	for cfg in CONFIGS:
		if cfg[0] != "baseline":
			savings[cfg[0]] = [] as Array[float]

	for pass_i in MATRIX_PASSES:
		for cfg in CONFIGS:
			if cfg[0] == "baseline":
				continue
			var base_ms := await _measure({})
			var cfg_ms := await _measure(cfg[1])
			(savings[cfg[0]] as Array[float]).append(base_ms - cfg_ms)
			base_samples.append(base_ms)
	_apply_config({})

	var base_avg := 0.0
	for m in base_samples:
		base_avg += m
	base_avg /= maxf(float(base_samples.size()), 1.0)
	print("baseline: %.2f ms/frame (%.1f FPS), averaged over %d paired runs"
			% [base_avg, 1000.0 / base_avg, base_samples.size()])
	print("")
	print("effect        cost ms/frame   spread   %% of frame")
	print("--------------------------------------------------")
	for cfg in CONFIGS:
		if cfg[0] == "baseline":
			continue
		var s: Array[float] = savings[cfg[0]]
		var lo: float = s[0]
		var hi: float = s[0]
		var sum := 0.0
		for v in s:
			lo = minf(lo, v)
			hi = maxf(hi, v)
			sum += v
		var mean := sum / float(s.size())
		print("%-13s %+8.2f      %+.2f..%+.2f   %5.1f%%"
				% [cfg[0], mean, lo, hi, 100.0 * mean / base_avg])


## Applies [param cfg], flies the whole route, and returns the mean frame time
## in ms. One leg is flown and discarded first: toggling SSAO or shadows makes
## the renderer rebuild state, which is not the effect's steady-state cost.
func _measure(cfg: Dictionary) -> float:
	_apply_config(cfg)
	await _fly(LEGS[0][1], LEGS[0][2])
	var samples: Array[float] = []
	for leg in LEGS:
		samples.append_array(await _fly(leg[1], leg[2]))
	return 1000.0 / _avg_fps(samples)


## Turns effects on or off on the live world. Absent keys mean "leave as
## authored", so `{}` restores the scene's own settings.
func _apply_config(cfg: Dictionary) -> void:
	var we := _world.get_node_or_null("WorldEnvironment") as WorldEnvironment
	# Fetched through the node every time on purpose: DayNightCycle deep-copies
	# the Environment at _ready, so a reference cached earlier would be stale.
	if we != null and we.environment != null:
		var env := we.environment
		env.ssao_enabled = cfg.get("ssao", true)
		env.glow_enabled = cfg.get("glow", true)
		if we.camera_attributes is CameraAttributesPractical:
			(we.camera_attributes as CameraAttributesPractical) \
					.dof_blur_far_enabled = cfg.get("dof", true)
	var sun := _world.get_node_or_null("Sun") as DirectionalLight3D
	if sun != null:
		sun.shadow_enabled = cfg.get("shadow", true)
		sun.directional_shadow_max_distance = cfg.get("shadow_dist", 220.0)
		# The authored 1.2° angular size is what puts Godot into variable-penumbra
		# shadow filtering; 0 gives plain hard shadows.
		sun.light_angular_distance = cfg.get("angular", 1.2)
		sun.directional_shadow_mode = cfg.get("splits",
				DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS)
		sun.directional_shadow_blend_splits = cfg.get("blend", true)
	# Renderer-wide shadow knobs; these are project settings that only take
	# effect through the RenderingServer at runtime.
	RenderingServer.directional_shadow_atlas_set_size(
			cfg.get("shadow_size", 4096), true)
	# Default MUST mirror project.godot (soft_shadow_filter_quality = 2 =
	# SOFT_LOW), or the baseline is more expensive than the shipping game and
	# every saving measured against it is inflated. That mistake happened: an
	# earlier revision defaulted to SOFT_MEDIUM and credited a config with 4.87
	# ms that was partly just reverting the benchmark's own handicap.
	RenderingServer.directional_soft_shadow_filter_set_quality(
			cfg.get("soft_quality", RenderingServer.SHADOW_QUALITY_SOFT_LOW))
	var grass := _world.get_node_or_null("HTerrain/GrassLayer") as Node3D
	if grass != null:
		grass.visible = cfg.get("grass", true)


func _lap() -> void:
	for leg in LEGS:
		await _fly(leg[1], leg[2])


## Flies the camera from [param a] to [param b] over the leg duration, sampling
## every frame's delta (seconds). Returns the samples past the warm-up.
func _fly(a: Vector3, b: Vector3) -> Array[float]:
	var samples: Array[float] = []
	var t := 0.0
	var frame := 0
	_cam.global_position = a
	_cam.look_at(b + Vector3(0.0, -6.0, 0.0))
	while t < _leg_sec:
		await get_tree().process_frame
		var dt: float = get_process_delta_time()
		t += dt
		frame += 1
		_cam.global_position = a.lerp(b, clampf(t / _leg_sec, 0.0, 1.0))
		if frame > WARMUP_FRAMES:
			samples.append(dt)
	return samples


func _avg_fps(samples: Array[float]) -> float:
	if samples.is_empty():
		return 0.0
	var total := 0.0
	for s in samples:
		total += s
	return float(samples.size()) / total


func _report(label: String, samples: Array[float], suffix: String = "") -> void:
	if samples.is_empty():
		print("%-11s (no samples)" % label)
		return
	var sorted := samples.duplicate()
	sorted.sort()
	# Worst 1% of frames = the tail of the sorted deltas; at least one frame.
	var tail := maxi(1, int(float(sorted.size()) * 0.01))
	var tail_total := 0.0
	for i in range(sorted.size() - tail, sorted.size()):
		tail_total += sorted[i]
	print("%-11s %6.1f  %6.1f  %6.1f ms   %s" % [label, _avg_fps(samples),
			float(tail) / tail_total, sorted[-1] * 1000.0, suffix])
