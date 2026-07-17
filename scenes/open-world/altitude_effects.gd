extends Node3D
## AltitudeEffects
##
## The high country pushes back: climb far enough above the valleys and the air
## turns to weather. Wind rises (a looping broadband bed that gusts, plus
## velocity-stretched streaks tearing past the player), and cold creeps in
## (frost growing inward from the screen's edges, snow starting near the
## summits). Purely presentational — nothing here slows the player, because in
## a cardio game the reward for climbing must never be a punishment.
##
## Everything is a function of ONE number — [method get_factor], how far the
## player's altitude sits between [constant COLD_START] and [constant
## COLD_FULL] — mirroring world_border.gd's single-haze design: systems that
## share a driver always agree with each other. The factor itself is eased
## (see [constant RISE_RATE]) so cresting a ridge fades the weather in over a
## couple of seconds rather than switching it on.
class_name AltitudeEffects

## World-space altitudes (m) where the effects begin and saturate. The terrain's
## walking country sits around y 20-50 with the sea at 13.5; only the real hills
## push past COLD_START, and only the summit region approaches COLD_FULL.
const COLD_START: float = 55.0
const COLD_FULL: float = 105.0
## Snow needs genuine height: it fades in over the top of the cold band
## (factor [constant SNOW_START]..1) so the first wind gusts arrive dry.
const SNOW_START: float = 0.55

## How fast the eased factor chases the player's true altitude factor, per
## second. ~0.5 means the full weather takes about two seconds to arrive.
const RISE_RATE: float = 0.5

const FROST_SHADER: String = "res://scenes/open-world/frost_overlay.gdshader"
const WIND_LOOP: String = "res://assets/audio/wind_loop.wav"

## The player whose altitude drives everything.
@export var player_path: NodePath

var _player: Node3D
var _factor: float = 0.0  # eased cold factor (0 = valley, 1 = summit)
var _time: float = 0.0  # local clock for gusts; pauses with the tree
var _wind: AudioStreamPlayer
var _streaks: GPUParticles3D
var _streak_mat: ParticleProcessMaterial
var _snow: GPUParticles3D
var _snow_mat: ParticleProcessMaterial
var _frost: ShaderMaterial


func _ready() -> void:
	_player = get_node_or_null(player_path) as Node3D
	_build_wind_audio()
	_streaks = _build_streaks()
	_snow = _build_snow()
	_build_frost_overlay()


func _process(delta: float) -> void:
	if _player == null:
		return
	_time += delta
	var target: float = smoothstep(COLD_START, COLD_FULL, _player.global_position.y)
	_factor = move_toward(_factor, target, RISE_RATE * delta)

	# The particle field rides the player so the weather is always around THEM;
	# world-space particles mean already-spawned streaks don't drag along too.
	global_position = _player.global_position

	_drive_wind(delta)
	_drive_particles()
	if _frost != null:
		_frost.set_shader_parameter("intensity", _factor)


## The eased altitude cold factor (0..1), should anything else want to agree
## with the weather (HUD tinting, future stamina flavour, ...).
func get_factor() -> float:
	return _factor


## The wind bed: one dedicated looping player rather than an AudioManager voice —
## the SFX pool is for one-shots, and a continuous loop parked in it would be
## stolen the moment a busy moment needed all ten voices. Still routed through
## the SFX bus so the user's volume settings apply.
func _build_wind_audio() -> void:
	var stream: AudioStream = load(WIND_LOOP)
	if stream == null:
		return
	# Belt and braces: the .import forces a forward loop, but if the asset was
	# imported without it the bed would die after one pass — silently, at the
	# top of a mountain, which is exactly where nobody would think to look.
	var wav := stream as AudioStreamWAV
	if wav != null and wav.loop_mode == AudioStreamWAV.LOOP_DISABLED:
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = wav.data.size() / 2  # 16-bit mono PCM: two bytes per frame
	_wind = AudioStreamPlayer.new()
	_wind.stream = stream
	_wind.bus = AudioManager.SFX_BUS
	_wind.volume_db = -60.0
	add_child(_wind)


## Gusting: two incommensurate sines so the swell never settles into an audible
## pattern. Shared by the audio and the streak speed, so the wind you hear
## strengthen is the wind you see strengthen.
func _gust() -> float:
	return clampf(0.55 + 0.3 * sin(_time * 0.8) + 0.15 * sin(_time * 2.17 + 1.7),
			0.0, 1.0)


func _drive_wind(delta: float) -> void:
	if _wind == null:
		return
	if _factor <= 0.001:
		if _wind.playing:
			_wind.volume_db = move_toward(_wind.volume_db, -60.0, 30.0 * delta)
			if _wind.volume_db <= -59.0:
				_wind.stop()
		return
	if not _wind.playing:
		_wind.play()
	var gust: float = _gust()
	# Louder and slightly shriller with altitude; the gust wobbles both.
	var target_db: float = lerpf(-30.0, -8.0, _factor) + (gust - 0.55) * 6.0
	_wind.volume_db = move_toward(_wind.volume_db, target_db, 24.0 * delta)
	_wind.pitch_scale = 0.92 + 0.2 * _factor + 0.06 * (gust - 0.55)


func _drive_particles() -> void:
	var active: bool = _factor > 0.01
	_streaks.emitting = active
	_streaks.amount_ratio = _factor
	var snow_f: float = clampf((_factor - SNOW_START) / (1.0 - SNOW_START), 0.0, 1.0)
	_snow.emitting = snow_f > 0.01
	_snow.amount_ratio = maxf(snow_f, 0.05)  # amount_ratio 0 still draws one particle

	# The wind heading wanders slowly so gusts don't always tear the same way,
	# and the gust puts its shoulder into the streak speed.
	var a: float = _time * 0.03 + 0.7
	var dir := Vector3(cos(a), -0.08, sin(a))
	var gust: float = _gust()
	_streak_mat.direction = dir
	_streak_mat.initial_velocity_min = lerpf(10.0, 16.0, gust) * (0.5 + 0.5 * _factor)
	_streak_mat.initial_velocity_max = lerpf(18.0, 27.0, gust) * (0.5 + 0.5 * _factor)
	_snow_mat.direction = dir
	_snow_mat.initial_velocity_min = 2.0 + 6.0 * gust
	_snow_mat.initial_velocity_max = 4.0 + 8.0 * gust


## Wind made visible: thin unshaded slivers stretched along their own velocity
## (TRANSFORM_ALIGN_Z_BILLBOARD_Y_TO_VELOCITY), born throughout a box around the
## player and hurled along the wind heading. Without these the audio reads as
## "my speakers are humming"; with them it reads as air moving past you.
func _build_streaks() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = "WindStreaks"
	p.amount = 80
	p.lifetime = 1.3
	p.emitting = false
	p.transform_align = GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD_Y_TO_VELOCITY

	_streak_mat = ParticleProcessMaterial.new()
	_streak_mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	_streak_mat.emission_box_extents = Vector3(26.0, 9.0, 26.0)
	_streak_mat.spread = 4.0
	_streak_mat.gravity = Vector3.ZERO
	p.process_material = _streak_mat

	var quad := QuadMesh.new()
	quad.size = Vector2(0.035, 1.5)  # a sliver: Y-long, so it lies along the wind
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.85, 0.92, 1.0, 0.34)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	quad.material = mat
	p.draw_pass_1 = quad
	add_child(p)
	return p


## Summit snow: small drifting flakes, blown along the same heading as the
## streaks but mostly falling. Reserved for the top of the cold band (see
## [constant SNOW_START]) so height has a second, colder register above wind.
func _build_snow() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = "Snow"
	p.amount = 160
	p.lifetime = 3.2
	p.emitting = false

	_snow_mat = ParticleProcessMaterial.new()
	_snow_mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	_snow_mat.emission_box_extents = Vector3(24.0, 12.0, 24.0)
	_snow_mat.spread = 25.0
	_snow_mat.gravity = Vector3(0.0, -2.4, 0.0)
	p.process_material = _snow_mat

	var quad := QuadMesh.new()
	quad.size = Vector2(0.07, 0.07)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.95, 0.97, 1.0, 0.8)
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	quad.material = mat
	p.draw_pass_1 = quad
	add_child(p)
	return p


## The cold made visible: a fullscreen frost vignette (see frost_overlay.gdshader)
## on its own CanvasLayer at layer 0 — above the 3D view, beneath the HUD and
## pause menu (which sit at the default layer 1), so ice never obscures the stats.
func _build_frost_overlay() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 0
	add_child(layer)

	var rect := ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_frost = ShaderMaterial.new()
	_frost.shader = load(FROST_SHADER)
	_frost.set_shader_parameter("intensity", 0.0)
	_frost.set_shader_parameter("frost_noise", _make_frost_noise())
	rect.material = _frost
	layer.add_child(rect)


## Soft many-octave noise for the frost's crystalline frontier. Seamless so the
## shader can tile it at two scales without a visible join.
func _make_frost_noise() -> NoiseTexture2D:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.01
	noise.fractal_octaves = 4
	var tex := NoiseTexture2D.new()
	tex.width = 256
	tex.height = 256
	tex.seamless = true
	tex.noise = noise
	return tex
