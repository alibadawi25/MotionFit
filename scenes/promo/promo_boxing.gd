extends Node3D
## PromoBoxing — cinematic photo-mode for the Boxing game.
##
## Builds the same set the bout runs on (a [BoxingArena] plus two [BoxingFighter]s
## squared up where boxing.gd stands them) and freezes the money moment: the
## player's boxer landing a right cross as the opponent snaps into the recoil. The
## crowd is dialled to a roar and the jumbotron carries the main-event card, so the
## still sells the occasion. Shot only with tools/shot.sh; never launched in-game.
##
## The action is a frozen animation frame, not a lucky capture: each frame we force
## the player's CROSS clip and the opponent's HIT clip to a fixed, paused time (at a
## high process_priority so it wins), so the punch reads fully connected in the shot
## no matter when the grab lands. CAM_* can be overridden per shot via env
## PROMO_POS / PROMO_LOOK / PROMO_FOV.

## Fighter placement mirrors boxing.gd's YOU_POS / OPP_POS so the promo frames the
## exact stand-off the game opens on.
const YOU_POS: Vector3 = Vector3(-1.15, 1.0, 2.4)
const OPP_POS: Vector3 = Vector3(0.45, 1.0, -0.6)

## A low ringside 3/4 hero angle: off the player's right shoulder, tilted up so the
## lit ring, the crowd bowl and the centre-hung jumbotron stack up behind the punch.
const CAM_POS: Vector3 = Vector3(4.6, 2.3, 5.2)
const CAM_LOOK: Vector3 = Vector3(-0.5, 1.55, 0.7)
const CAM_FOV: float = 52.0

## Where in each one-shot clip to freeze — the cross at full extension, the recoil
## at the head-snap. Fractions of the clip length, resolved once the clips load.
const CROSS_FREEZE: float = 0.42
const HIT_FREEZE: float = 0.3

var _cam: Camera3D
var _you: BoxingFighter
var _opp: BoxingFighter
var _you_anim: AnimationPlayer
var _opp_anim: AnimationPlayer

func _ready() -> void:
	# Win the frame over the fighters' own guard-settle logic.
	process_priority = 100

	var arena := BoxingArena.new()
	arena.name = "Arena"
	add_child(arena)
	arena.set_crowd_energy(0.95)
	arena.cheer_burst(1.0)
	arena.set_bout("CHALLENGER", "THE HAMMER", "TITLE BOUT · MAIN EVENT")

	_you = BoxingFighter.new()
	_you.position = YOU_POS
	add_child(_you)
	_you.setup({"sex": "male", "age": 28, "height_cm": 180.0, "weight_kg": 82.0},
			{}, "boxer_player", "blue", PI)

	_opp = BoxingFighter.new()
	_opp.position = OPP_POS
	add_child(_opp)
	_opp.setup({"sex": "male", "age": 30, "height_cm": 188.0, "weight_kg": 95.0},
			{"hair": "bald", "hair_color": "black", "top": "tank",
			"top_color": "black", "bottom": "shorts", "bottom_color": "black",
			"skin": "tan"}, "boxer_rival", "red", 0.0)

	_you_anim = _you.find_child("AnimationPlayer", true, false)
	_opp_anim = _opp.find_child("AnimationPlayer", true, false)

	_cam = Camera3D.new()
	_cam.fov = _env_float("PROMO_FOV", CAM_FOV)
	_cam.far = 400.0
	add_child(_cam)
	_cam.global_position = _env_vec("PROMO_POS", CAM_POS)
	_cam.look_at(_env_vec("PROMO_LOOK", CAM_LOOK), Vector3.UP)
	_cam.current = true

	if OS.get_environment("PROMO_CINEMATIC") == "1":
		_apply_cinematic()


## A moodier, filmic grade for a "cover" still: AGX tonemap, punchier bloom, a
## touch more contrast/saturation, atmospheric haze (arena light in the air) and a
## hotter, warmer key on the ring so the fight sits in a pool of light while the
## bowl falls into shadow. Toggled with env PROMO_CINEMATIC=1 so the base scene
## still reads as the game.
func _apply_cinematic() -> void:
	var we := get_node_or_null("WorldEnvironment") as WorldEnvironment
	if we != null and we.environment != null:
		var e := we.environment
		e.tonemap_mode = 4                    # AGX — filmic highlight roll-off
		e.tonemap_exposure = 1.16
		# Darker, cooler ambient so the ring's warm key pops against a moody bowl.
		e.ambient_light_color = Color(0.12, 0.14, 0.20)
		e.ambient_light_energy = 0.26
		e.glow_intensity = 0.95
		e.glow_strength = 1.15
		e.glow_bloom = 0.3
		e.glow_hdr_threshold = 0.72
		e.adjustment_enabled = true
		e.adjustment_brightness = 1.0
		e.adjustment_contrast = 1.18
		e.adjustment_saturation = 1.16
		# Just a whisper of haze for depth — not a veil (volumetric fog stays off).
		e.fog_enabled = true
		e.fog_light_color = Color(0.14, 0.17, 0.26)
		e.fog_light_energy = 0.5
		e.fog_density = 0.004
	var spot := get_node_or_null("RingSpot") as SpotLight3D
	if spot != null:
		spot.light_energy = 22.0
		spot.light_color = Color(1.0, 0.92, 0.78)   # warm key on the canvas


func _process(_delta: float) -> void:
	if _cam != null and not _cam.current:
		_cam.current = true
	# Hold the fighters on the impact frame: cross fully thrown, opponent recoiling.
	_freeze(_you_anim, "cross", CROSS_FREEZE)
	_freeze(_opp_anim, "hit", HIT_FREEZE)


## Parks [param anim] on [param clip] at [param frac] of its length, paused, so the
## pose is a stable still rather than a moment mid-playback.
func _freeze(anim: AnimationPlayer, clip: String, frac: float) -> void:
	if anim == null or not anim.has_animation(clip):
		return
	if anim.current_animation != clip:
		anim.play(clip)
	anim.seek(anim.get_animation(clip).length * frac, true)
	anim.pause()


func _env_vec(key: String, fallback: Vector3) -> Vector3:
	var s := OS.get_environment(key)
	if s.is_empty():
		return fallback
	var p := s.split(",")
	if p.size() != 3:
		return fallback
	return Vector3(p[0].to_float(), p[1].to_float(), p[2].to_float())


func _env_float(key: String, fallback: float) -> float:
	var s := OS.get_environment(key)
	return s.to_float() if not s.is_empty() else fallback
