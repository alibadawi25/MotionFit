extends Node3D
## BoxingFighter
##
## A boxer standing in the ring: a gloved figure from CharacterFactory.build_boxer
## (boxing gear + the guard/jab/cross/hit animation set) that holds a guard, throws
## punches and sells hits on command. It carries no game state — boxing.gd owns
## health, scoring and the bout; this node just turns those events into motion.
##
## All movement is the authored boxing clips: a looping GUARD between actions, and
## one-shot JAB (left), CROSS (right) and HIT that each play once and settle back
## into the guard. A knockout leans the whole figure down and holds it there.
class_name BoxingFighter

const CLIP_GUARD: String = "guard"
const CLIP_JAB: String = "jab"      # left straight
const CLIP_CROSS: String = "cross"  # right straight
const CLIP_HIT: String = "hit"      # recoil
const BLEND: float = 0.08

var _character: Node3D
var _anim: AnimationPlayer
var _clips: PackedStringArray
var _defeated: bool = false
## Guarded so a knockout lean isn't overwritten by the guard clip's root motion.
var _lean: float = 0.0


## Builds and plants the fighter. [param body] / [param appearance] follow the
## CharacterFactory shapes; [param glove_color] tints the gloves; [param face_yaw]
## turns the figure to face its opponent (models are authored facing +Z).
func setup(body: Dictionary, appearance: Dictionary, slot: String,
		glove_color: String, face_yaw: float) -> void:
	_character = CharacterFactory.build_boxer(body, appearance, slot, glove_color)
	if _character == null:
		return
	add_child(_character)
	RigUtils.plant_feet(_character, 0.0, face_yaw)
	_anim = _character.find_child("AnimationPlayer", true, false)
	if _anim != null:
		_clips = _anim.get_animation_list()
		# Guard loops; the punches and the hit play through once.
		RigUtils.loop_clips(_anim, [CLIP_JAB, CLIP_CROSS, CLIP_HIT])
		_anim.animation_finished.connect(_on_anim_finished)
		if _clips.has(CLIP_GUARD):
			_anim.play(CLIP_GUARD)


## One-shots settle back into the guard when they finish.
func _on_anim_finished(clip: StringName) -> void:
	if _defeated:
		return
	if clip != CLIP_GUARD and _clips.has(CLIP_GUARD):
		_anim.play(CLIP_GUARD, BLEND)


## Throws a punch: [param hand] "left" plays the jab, anything else the cross.
func punch(hand: String) -> void:
	if _defeated:
		return
	_play_once(CLIP_JAB if hand == "left" else CLIP_CROSS)


## Plays the recoil — call on the fighter that just got tagged.
func take_hit() -> void:
	if _defeated:
		return
	_play_once(CLIP_HIT)


## Ends the fight for this figure: play the recoil, then slump backwards and hold
## (a knockdown). Ignores further punch/hit calls.
func knock_out() -> void:
	if _defeated:
		return
	_defeated = true
	if _anim != null and _clips.has(CLIP_HIT):
		_anim.play(CLIP_HIT, BLEND)
	var tween := create_tween().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "_lean", -1.15, 0.55).set_delay(0.15)


func _process(_delta: float) -> void:
	# A knockout tilts the whole figure back off its feet; nothing else moves it.
	if _character != null and _defeated:
		_character.rotation.x = _lean


func _play_once(clip: String) -> void:
	if _anim != null and _clips.has(clip):
		_anim.play(clip, BLEND)
