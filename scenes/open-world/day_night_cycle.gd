extends Node
## DayNightCycle
##
## Rolls the open world through a full day: the Sun arcs overhead, dawn and dusk
## paint the horizon, night drops to a moonlit blue. One session (the default
## [member day_length_sec] of 12 minutes) sees a whole day pass, so a long walk
## ends under different light than it began — the world moves even when the
## player only walks.
##
## Everything is derived from ONE number, the sun's elevation (the sine of its
## arc angle): daylight, the dusk band, sun/moon energy, sky, ambient and fog
## colours are all functions of it, so no two systems can disagree about what
## time it is. The DAY palette is captured from the scene's authored resources
## at _ready — tune the scene's sky/sun/fog in the editor and noon keeps up
## automatically; only the night and dusk tints live here as constants.
##
## Plays nicely with world_border.gd: the border ramps the environment's fog
## DEPTH range, this cycle recolours its fog LIGHT — different properties, no fight.
class_name DayNightCycle

## Night palette (the sky material's day values are captured at _ready).
const NIGHT_TOP: Color = Color(0.012, 0.025, 0.06)
const NIGHT_HORIZON: Color = Color(0.05, 0.08, 0.15)
const NIGHT_GROUND_HORIZON: Color = Color(0.05, 0.07, 0.12)
const NIGHT_GROUND_BOTTOM: Color = Color(0.02, 0.03, 0.05)
const NIGHT_FOG: Color = Color(0.09, 0.12, 0.19)
## Ambient floor at night: dim, but never so dark the terrain becomes guesswork —
## there is no fail state out here, and there must be no unreadable one either.
const NIGHT_AMBIENT: float = 0.34

## Dusk/dawn tints, blended in over the band where the sun hugs the horizon.
const DUSK_HORIZON: Color = Color(1.0, 0.45, 0.2)
const DUSK_TOP: Color = Color(0.36, 0.22, 0.38)
const DUSK_FOG: Color = Color(0.72, 0.5, 0.38)
## The sun itself reddens as it drops; white-warm (the authored colour) at noon.
const HORIZON_SUN: Color = Color(1.0, 0.62, 0.32)

const MOON_COLOR: Color = Color(0.68, 0.76, 1.0)
const MOON_ENERGY: float = 0.3

## Cloud tints through the day (see sky.gdshader). Noon clouds are near-white
## with cool grey bellies; at dusk the whole deck catches the low sun, which is
## most of what makes a sunset read as a sunset rather than an orange filter.
const DAY_CLOUD_LIT: Color = Color(1.0, 0.99, 0.96)
const DAY_CLOUD_DARK: Color = Color(0.52, 0.58, 0.67)
const DUSK_CLOUD_LIT: Color = Color(1.0, 0.72, 0.45)
const DUSK_CLOUD_DARK: Color = Color(0.42, 0.30, 0.38)
const NIGHT_CLOUD_LIT: Color = Color(0.16, 0.20, 0.30)
const NIGHT_CLOUD_DARK: Color = Color(0.06, 0.08, 0.14)

## The scene's Sun (a DirectionalLight3D); its authored energy/colour become the
## noon values, and its authored yaw stays the compass heading of the whole arc.
@export var sun_path: NodePath
## The scene's WorldEnvironment, whose sky/ambient/fog this cycle drives.
@export var environment_path: NodePath
## Real seconds for one full 24 h day.
@export var day_length_sec: float = 720.0
## Where in the day a session begins (hours, 0-24). Morning by default, so a
## typical session walks through noon into dusk and finishes under stars.
@export var start_hour: float = 8.5

var _sun: DirectionalLight3D
var _moon: DirectionalLight3D
var _env: Environment
## The sky, held as whichever material the scene actually uses. Both are
## supported on purpose: the open world runs the custom sky.gdshader (clouds,
## sun disc, stars), but the palette below is written the same way for a plain
## ProceduralSkyMaterial, so a simpler scene can reuse this cycle unchanged.
## Writes go through [method _set_sky] rather than touching either directly.
var _sky_shader: ShaderMaterial
var _sky_proc: ProceduralSkyMaterial
var _hour: float

# The authored (noon) palette, captured at _ready — see the class docs.
var _day_sun_energy: float
var _day_sun_color: Color
var _day_ambient: float
var _day_top: Color
var _day_horizon: Color
var _day_ground_horizon: Color
var _day_ground_bottom: Color
var _day_fog: Color
var _sun_yaw: float


func _ready() -> void:
	_hour = fposmod(start_hour, 24.0)
	_sun = get_node_or_null(sun_path) as DirectionalLight3D
	var world_env := get_node_or_null(environment_path) as WorldEnvironment
	if _sun == null or world_env == null or world_env.environment == null:
		set_process(false)
		return
	# Deep-duplicate the environment: its resources are shared through Godot's
	# scene cache, so mutating them in place would leak tonight's sky into the
	# NEXT session's captured "day" palette. The border reads the environment
	# through the node each frame, so it follows the swap untouched.
	world_env.environment = world_env.environment.duplicate(true)
	_env = world_env.environment
	if _env.sky != null:
		_sky_shader = _env.sky.sky_material as ShaderMaterial
		_sky_proc = _env.sky.sky_material as ProceduralSkyMaterial

	_day_sun_energy = _sun.light_energy
	_day_sun_color = _sun.light_color
	_day_ambient = _env.ambient_light_energy
	_day_fog = _env.fog_light_color
	_sun_yaw = _sun.rotation.y
	if _has_sky():
		_day_top = _get_sky_color("sky_top_color")
		_day_horizon = _get_sky_color("sky_horizon_color")
		_day_ground_horizon = _get_sky_color("ground_horizon_color")
		_day_ground_bottom = _get_sky_color("ground_bottom_color")

	# The moon is the night's sun: opposite point of the same arc, cool and dim.
	# No shadows — a second shadowed directional light doubles that cost for a
	# light whose job is just "not pitch black".
	_moon = DirectionalLight3D.new()
	_moon.name = "Moon"
	_moon.light_color = MOON_COLOR
	_moon.light_energy = 0.0
	# A real angular size, or the sky draws the moon as a point that bloom
	# smears into a hard square blob; at ~2° it renders as a soft disc.
	_moon.light_angular_distance = 2.0
	_moon.visible = false
	add_child(_moon)

	_apply()


func _process(delta: float) -> void:
	_hour = fposmod(_hour + delta * 24.0 / maxf(day_length_sec, 1.0), 24.0)
	_apply()


## Jumps the cycle to [param hour] (0-24). For dev views and future features
## (a "golden hour run" mode, say); the cycle itself never calls it.
func set_hour(hour: float) -> void:
	_hour = fposmod(hour, 24.0)
	if _env != null:
		_apply()


func get_hour() -> float:
	return _hour


func _has_sky() -> bool:
	return _sky_shader != null or _sky_proc != null


## Reads a palette colour from whichever sky material the scene uses, so the
## authored noon palette can be captured without caring which one it is.
func _get_sky_color(param: String) -> Color:
	if _sky_shader != null:
		return _sky_shader.get_shader_parameter(param)
	if _sky_proc != null:
		return _sky_proc.get(param)
	return Color.BLACK


## Writes a palette colour to whichever sky material the scene uses. The custom
## shader's uniforms are named to match ProceduralSkyMaterial's properties
## exactly so this stays a one-liner rather than a translation table.
func _set_sky(param: String, value: Color) -> void:
	if _sky_shader != null:
		_sky_shader.set_shader_parameter(param, value)
	elif _sky_proc != null:
		_sky_proc.set(param, value)


func _apply() -> void:
	# The arc: 0 at 06:00 (sunrise), PI/2 at noon, PI at 18:00, then under the
	# world through the night. Its sine is the elevation everything keys off.
	var arc: float = (_hour - 6.0) * TAU / 24.0
	var elev: float = sin(arc)
	# Daylight leads the sunrise slightly (the sky brightens before the sun
	# clears the ridge) and saturates well before noon.
	var daylight: float = smoothstep(-0.04, 0.35, elev)
	# The dusk band: a bell around the horizon, driving the warm tints. Squared
	# off via smoothstep so it eases in and out instead of pivoting sharply.
	var dusk: float = smoothstep(0.0, 1.0, clampf(1.0 - absf(elev) / 0.28, 0.0, 1.0))

	_sun.rotation = Vector3(-arc, _sun_yaw, 0.0)
	_sun.light_energy = _day_sun_energy * smoothstep(0.0, 0.18, elev)
	_sun.light_color = HORIZON_SUN.lerp(_day_sun_color, clampf(elev / 0.45, 0.0, 1.0))
	# Hide the sun below the horizon or the sky keeps drawing its disc.
	_sun.visible = _sun.light_energy > 0.005

	_moon.rotation = Vector3(-(arc + PI), _sun_yaw, 0.0)
	_moon.light_energy = MOON_ENERGY * smoothstep(0.04, 0.18, -elev)
	_moon.visible = _moon.light_energy > 0.005

	_env.ambient_light_energy = lerpf(NIGHT_AMBIENT, _day_ambient, daylight)
	_env.fog_light_color = NIGHT_FOG.lerp(_day_fog, daylight).lerp(DUSK_FOG, dusk * 0.7)

	if not _has_sky():
		return
	_set_sky("sky_top_color",
			NIGHT_TOP.lerp(_day_top, daylight).lerp(DUSK_TOP, dusk * 0.3))
	_set_sky("sky_horizon_color", NIGHT_HORIZON.lerp(_day_horizon, daylight)
			.lerp(DUSK_HORIZON, dusk * 0.85))
	_set_sky("ground_horizon_color",
			NIGHT_GROUND_HORIZON.lerp(_day_ground_horizon, daylight)
			.lerp(DUSK_HORIZON, dusk * 0.6))
	_set_sky("ground_bottom_color",
			NIGHT_GROUND_BOTTOM.lerp(_day_ground_bottom, daylight))

	# Cloud and star handling only exists on the custom sky shader; a plain
	# ProceduralSkyMaterial simply has neither, so skip rather than warn.
	if _sky_shader == null:
		return
	_set_sky("cloud_lit_color", NIGHT_CLOUD_LIT.lerp(DAY_CLOUD_LIT, daylight)
			.lerp(DUSK_CLOUD_LIT, dusk * 0.8))
	_set_sky("cloud_dark_color", NIGHT_CLOUD_DARK.lerp(DAY_CLOUD_DARK, daylight)
			.lerp(DUSK_CLOUD_DARK, dusk * 0.7))
	# Clouds stay visible after dark (moonlit deck) but must not stay bright.
	_sky_shader.set_shader_parameter("cloud_opacity", lerpf(0.55, 1.0, daylight))
	# Stars fade in only once the sky itself is dark, and are gone by dawn.
	_sky_shader.set_shader_parameter("star_opacity", 1.0 - smoothstep(0.0, 0.28, elev))
