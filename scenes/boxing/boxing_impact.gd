extends Node3D
## BoxingImpact — the "that connected" feedback for the Boxing bout.
##
## Two things that together sell a landed punch, kept in one place because they
## always fire together and both are pure presentation:
##   - the flash at the glove (a pooled light + glowing burst), and
##   - the hit-stop / knockout slow motion that bends time around it.
##
## Split out of boxing.gd so the fight's state machine decides *that* a punch
## landed and this decides what landing looks and feels like.
##
## [b]This node owns Engine.time_scale.[/b] It is global state that stays wrong if
## a tween is interrupted, so exactly one place is allowed to drive it — see
## [method _slow_time].
class_name BoxingImpact

## Impact hit-stop: the world freezes for a beat on a clean landing, which is
## what makes a punch feel like it connected with something solid. Short enough
## that it never reads as a stutter, and always restored.
const HITSTOP_SCALE: float = 0.22
const HITSTOP_SEC: float = 0.08
## The knockout is worth slowing right down for.
const KO_SLOWMO_SCALE: float = 0.35
const KO_SLOWMO_SEC: float = 1.3

var _light: OmniLight3D
var _mat: StandardMaterial3D
## The one tween allowed to drive Engine.time_scale (see [method _slow_time]).
var _time_tween: Tween


## Builds the reused flash rig — an omni light plus a glowing sphere — parked at
## whichever glove just connected. Pooled rather than spawned so a flurry of
## punches can't churn nodes mid-round.
func _ready() -> void:
	name = "Impact"
	visible = false

	_light = OmniLight3D.new()
	_light.omni_range = 3.2
	_light.light_energy = 0.0
	add_child(_light)

	var mi := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.26
	mesh.height = 0.52
	_mat = StandardMaterial3D.new()
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.emission_enabled = true
	_mat.emission_energy_multiplier = 4.0
	_mat.albedo_color = Color(1, 1, 1, 0)
	mesh.material = _mat
	mi.mesh = mesh
	add_child(mi)


## Pops the flash at [param at] in [param color] and fades it out.
func burst(at: Vector3, color: Color) -> void:
	if _mat == null:
		return
	global_position = at
	visible = true
	scale = Vector3.ONE * 0.6
	_light.light_color = color
	_light.light_energy = 4.5
	_mat.emission = color
	_mat.albedo_color = Color(color, 0.9)
	var tween := create_tween().set_parallel(true)
	tween.tween_property(self, "scale", Vector3.ONE * 1.9, 0.22) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(_light, "light_energy", 0.0, 0.22)
	tween.tween_property(_mat, "albedo_color", Color(color, 0.0), 0.22)
	tween.chain().tween_callback(func() -> void: visible = false)


## The brief freeze on a clean landing.
func hit_stop() -> void:
	_slow_time(HITSTOP_SCALE, HITSTOP_SEC, 0.12)


## The knockout drops into slow motion and eases back out — the one moment in the
## bout worth stretching.
func ko_slowmo() -> void:
	_slow_time(KO_SLOWMO_SCALE, KO_SLOWMO_SEC, 0.5)


## Drops the time scale to [param scale] for [param hold] seconds, then eases it
## back to normal over [param recover]. Only ever one of these runs: the KO
## fires on the same frame as the punch that caused it, and the hit-stop's
## recovery would otherwise cut the knockout's slow motion short. The tween
## ignores the time scale it is itself changing, so it always restores.
func _slow_time(scale_to: float, hold: float, recover: float) -> void:
	if _time_tween != null and _time_tween.is_valid():
		_time_tween.kill()
	Engine.time_scale = scale_to
	_time_tween = create_tween().set_ignore_time_scale(true)
	_time_tween.tween_interval(hold)
	_time_tween.tween_property(Engine, "time_scale", 1.0, recover)


## Restores normal time if the game leaves mid-effect. Engine.time_scale is
## global: without this, quitting during a knockout's slow motion would leave the
## whole app — menus included — running at 35% speed.
func _exit_tree() -> void:
	if _time_tween != null and _time_tween.is_valid():
		_time_tween.kill()
	Engine.time_scale = 1.0
