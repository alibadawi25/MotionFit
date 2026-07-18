extends Node3D
## SprintOpponent
##
## One AI rival in the Hurdle Dash. It owns its own race maths — a base speed
## with a slow surge wobble, a light rubber band toward the player so the race
## stays a race, and a per-hurdle flub roll — and reports its progress through
## [member dist]. sprint.gd reads that to place it on the track (rivals, like
## the player, don't travel; the world scrolls) and to work out placings.
##
## The figure is a stock character from CharacterFactory.build_stock (a real
## generated body with its own jersey colour, cached like profile models), so
## every rival is visibly a different runner, not a palette clone.
class_name SprintOpponent

## How strongly the rival is pulled toward the player's distance (m/s per metre
## of separation), and the most speed the band may add or steal. Small on
## purpose: the race should stay close, not scripted.
const RUBBER: float = 0.05
const RUBBER_CAP: float = 0.7

## Same leap arc as the player, so rival jumps read as the same athletics.
const JUMP_VELOCITY: float = 6.2
const GRAVITY: float = 22.0
## How far before a hurdle the rival launches its jump (metres).
const JUMP_LEAD: float = 2.6

## A flubbed hurdle costs this speed multiplier while the recovery timer runs.
const FLUB_MULT: float = 0.4
const FLUB_RECOVER_SEC: float = 1.2

const CLIP_WALK: String = "walk"
const CLIP_JUMP: String = "jump"
const CLIP_IDLE: String = "idle"
const CLIP_CROUCH: String = "crouch"
const ANIM_BLEND: float = 0.14
const RUN_STRIDE_MIN: float = 1.1
const RUN_STRIDE_MAX: float = 2.9
## Stride pacing maps this speed range onto the stride range above.
const SPEED_FOR_MAX_STRIDE: float = 8.5

## Metres covered so far. sprint.gd reads this for placings and positioning.
var dist: float = 0.0

var _base_speed: float = 5.0
var _surge_amp: float = 0.5
var _surge_hz: float = 0.07
var _surge_phase: float = 0.0
var _flub_chance: float = 0.15
var _hurdle_dists: PackedFloat32Array = PackedFloat32Array()
var _next_hurdle: int = 0
var _flub_t: float = 0.0
var _y: float = 0.0
var _vy: float = 0.0
var _grounded: bool = true
var _racing: bool = false
var _base_x: float = 0.0
var _rng := RandomNumberGenerator.new()

var _character: Node3D
var _anim: AnimationPlayer
var _clips: PackedStringArray
var _current_clip: String = ""
var _jumping: bool = false


## Builds the rival. [param spec] carries its identity and race personality:
##   slot (String)        — cache name for the generated GLB,
##   body / appearance    — CharacterFactory.build_stock inputs,
##   base_speed (float)   — cruising pace (m/s),
##   flub_chance (float)  — odds of clipping any given hurdle.
## [param lane_x] is the lane centre; [param hurdle_dists] the shared row list.
func setup(spec: Dictionary, lane_x: float,
		hurdle_dists: PackedFloat32Array) -> void:
	_base_x = lane_x
	position = Vector3(lane_x, 0.0, 0.0)
	_hurdle_dists = hurdle_dists
	_base_speed = float(spec.get("base_speed", 5.0))
	_flub_chance = float(spec.get("flub_chance", 0.15))
	_rng.randomize()
	_surge_amp = _rng.randf_range(0.35, 0.6)
	_surge_hz = _rng.randf_range(0.05, 0.1)
	_surge_phase = _rng.randf_range(0.0, TAU)
	_spawn_character(spec)


func _spawn_character(spec: Dictionary) -> void:
	_character = CharacterFactory.build_stock(
		spec.get("body", {}), spec.get("appearance", {}),
		String(spec.get("slot", "rival")))
	if _character == null:
		return
	add_child(_character)
	RigUtils.plant_feet(_character, 0.0, PI)  # authored facing +Z; race toward -Z
	_anim = _character.find_child("AnimationPlayer", true, false)
	if _anim != null:
		_clips = _anim.get_animation_list()
		RigUtils.loop_clips(_anim, [CLIP_JUMP])
		_anim.animation_finished.connect(_on_anim_finished)
		# Waiting at the line: stand ready until the gun.
		_current_clip = CLIP_IDLE if _clips.has(CLIP_IDLE) else _clips[0]
		_anim.play(_current_clip)


func _on_anim_finished(clip: StringName) -> void:
	if clip == CLIP_JUMP:
		_jumping = false
		_current_clip = ""


## The starter's "SET": drop into the block crouch alongside the player. No
## effect once the gun has gone (the run owns the animation from there).
func set_crouch() -> void:
	if _anim != null and not _racing and _clips.has(CLIP_CROUCH):
		_current_clip = CLIP_CROUCH
		_anim.play(CLIP_CROUCH, ANIM_BLEND)


## The gun: start running.
func start_race() -> void:
	_racing = true


## Advances the rival's race one frame. [param player_dist] feeds the rubber
## band. sprint.gd then reads [member dist] to place this node on the track.
func tick(delta: float, race_time: float, player_dist: float) -> void:
	if not _racing:
		return
	var surge: float = sin(race_time * TAU * _surge_hz + _surge_phase) * _surge_amp
	var band: float = clampf((player_dist - dist) * RUBBER, -RUBBER_CAP, RUBBER_CAP)
	var speed: float = _base_speed + surge + band
	if _flub_t > 0.0:
		_flub_t = maxf(0.0, _flub_t - delta)
		speed *= FLUB_MULT
	speed = maxf(speed, 0.5)
	dist += speed * delta
	_tick_hurdles()
	_tick_jump(delta)
	if _character != null:
		# A wobble while recovering from a clipped hurdle.
		var lean: float = sin(_flub_t * 30.0) * 0.14 * _flub_t
		_character.rotation.z = lerpf(_character.rotation.z, lean, 0.3)
	_update_animation(speed)


## Launches (or flubs) each hurdle as this rival reaches it. Flubs are rolled
## here, per rival, so a clumsy rival is a personality, not a script.
func _tick_hurdles() -> void:
	if _next_hurdle >= _hurdle_dists.size():
		return
	if dist < _hurdle_dists[_next_hurdle] - JUMP_LEAD:
		return
	_next_hurdle += 1
	if _rng.randf() < _flub_chance:
		_flub_t = FLUB_RECOVER_SEC
	elif _grounded:
		_vy = JUMP_VELOCITY
		_grounded = false
		if _anim != null and _clips.has(CLIP_JUMP):
			_jumping = true
			_anim.speed_scale = 1.0
			_anim.play(CLIP_JUMP, ANIM_BLEND * 0.5)


func _tick_jump(delta: float) -> void:
	if _grounded:
		return
	_vy -= GRAVITY * delta
	_y += _vy * delta
	if _y <= 0.0:
		_y = 0.0
		_vy = 0.0
		_grounded = true


func _update_animation(speed: float) -> void:
	if _anim == null or _jumping:
		return
	var want: String = CLIP_WALK if _clips.has(CLIP_WALK) else _current_clip
	if want != _current_clip:
		_current_clip = want
		_anim.play(want, ANIM_BLEND)
	var s: float = clampf(speed / SPEED_FOR_MAX_STRIDE, 0.0, 1.0)
	_anim.speed_scale = (lerpf(RUN_STRIDE_MIN, RUN_STRIDE_MAX, s)
			if want == CLIP_WALK else 1.0)


## Called each frame by sprint.gd after tick: parks the rival at its relative
## position down the track ([param rel_z] = how far ahead of the player, in -Z).
func place(rel_z: float) -> void:
	position = Vector3(_base_x, _y, rel_z)
