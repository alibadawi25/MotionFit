extends Node3D
## BoxingFighter
##
## A boxer standing in the ring: a gloved figure from CharacterFactory.build_boxer
## (boxing gear + the guard/punch/block/hit animation set) that holds a guard,
## throws the three punch shapes, blocks, slips and sells hits on command. It
## carries no game state — boxing.gd owns health, scoring and the bout; this node
## just turns those events into motion.
##
## Movement comes from two places:
##   - the authored clips: a looping GUARD between actions, a held BLOCK, and
##     one-shot punches (STRAIGHT / HOOK / UPPERCUT on either glove) and HIT that
##     each play once and settle back into the guard;
##   - a live waist lean applied on top ([method set_lean]), so a slip tracks how
##     far the player actually leaned instead of snapping to a canned pose.
## A knockout leans the whole figure down and holds it there.
class_name BoxingFighter

const CLIP_GUARD: String = "guard"
const CLIP_BLOCK: String = "block"   # held gloves-up cover
const CLIP_HIT: String = "hit"       # recoil
const BLEND: float = 0.08

## The punch clip for each (kind, hand). Kinds are the ones MotionManager reads
## off the player's body — "straight" (the jab/cross pair), "hook" (wide) and
## "uppercut" — so a thrown punch maps straight through with no translation.
const PUNCH_CLIPS: Dictionary = {
	"straight": {"left": "jab", "right": "cross"},
	"hook": {"left": "hook_l", "right": "hook_r"},
	"uppercut": {"left": "upper_l", "right": "upper_r"},
}

## How far a full slip leans the figure (radians of roll) and how far it carries
## the body sideways (metres). Tuned so a committed lean clearly takes the head
## off the punch line without the boxer looking like they're falling over.
const LEAN_ROLL: float = 0.34
const LEAN_SHIFT: float = 0.22
## How quickly the lean eases toward the player's live value (per second).
const LEAN_SMOOTH: float = 9.0

var _character: Node3D
var _anim: AnimationPlayer
var _clips: PackedStringArray
var _defeated: bool = false
## Guarded so a knockout lean isn't overwritten by the guard clip's root motion.
var _knockdown: float = 0.0
## Live waist slip: -1 fully to this fighter's left .. +1 right, eased toward
## [member _lean_target] so the pose never snaps.
var _lean: float = 0.0
var _lean_target: float = 0.0
var _blocking: bool = false
## Lean is given in WORLD terms (see [method set_lean]) but the roll is applied in
## the figure's own space, which face_yaw may have turned around. This flips the
## roll for a fighter facing the other way, so both boxers lean the direction the
## camera sees. Captured from face_yaw in [method setup].
var _lean_sign: float = 1.0
## The figure's planted local x, so the slip's sideways shift is applied on top
## of wherever RigUtils.plant_feet put it rather than replacing it.
var _base_x: float = 0.0


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
	_base_x = _character.position.x
	# A local +z roll tips the figure toward its own -X, which face_yaw may have
	# turned to face world +X or -X; -cos(yaw) is +1 for a fighter turned to face
	# us (yaw PI) and -1 for one facing away, keeping set_lean world-consistent.
	_lean_sign = -cos(face_yaw)
	_anim = _character.find_child("AnimationPlayer", true, false)
	if _anim != null:
		_clips = _anim.get_animation_list()
		# Guard and block hold (loop); the punches and the hit play through once.
		var one_shots: Array = [CLIP_HIT]
		for hands in PUNCH_CLIPS.values():
			one_shots.append_array(hands.values())
		RigUtils.loop_clips(_anim, one_shots)
		_anim.animation_finished.connect(_on_anim_finished)
		if _clips.has(CLIP_GUARD):
			_anim.play(CLIP_GUARD)


## One-shots settle back into whatever the fighter is holding — the block if
## they're still covering up, otherwise the guard.
func _on_anim_finished(clip: StringName) -> void:
	if _defeated:
		return
	if clip != CLIP_GUARD and clip != CLIP_BLOCK:
		_play_hold()


## Throws a punch. [param hand] is "left"/"right" and [param kind] one of
## "straight" / "hook" / "uppercut". An unknown kind (or a fighter built from an
## older GLB that predates the hooks and uppercuts) falls back to the straight,
## so a punch always shows something rather than nothing.
func punch(hand: String, kind: String = "straight") -> void:
	if _defeated:
		return
	var side: String = "left" if hand == "left" else "right"
	var by_hand: Dictionary = PUNCH_CLIPS.get(kind, PUNCH_CLIPS["straight"])
	var clip: String = String(by_hand[side])
	if not _clips.has(clip):
		clip = String(PUNCH_CLIPS["straight"][side])
	_play_once(clip)


## Raises or drops the gloves-up cover. Held while [param on] stays true, so
## boxing.gd can mirror the player's own guard every frame.
func set_blocking(on: bool) -> void:
	if _defeated or on == _blocking:
		return
	_blocking = on
	# Don't cut a punch or a recoil short — those settle into the right hold on
	# their own via _on_anim_finished.
	if _anim == null or _anim.current_animation in [CLIP_GUARD, CLIP_BLOCK, ""]:
		_play_hold()


## The live waist slip, in world/screen terms: -1 leans the fighter toward the
## screen's LEFT, +1 toward the RIGHT, 0 upright — the same convention as
## MotionManager.get_lean, so the player's lean feeds straight through. Applied
## on top of whatever clip is playing.
func set_lean(lean: float) -> void:
	_lean_target = clampf(lean, -1.0, 1.0)


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
	_blocking = false
	if _anim != null and _clips.has(CLIP_HIT):
		_anim.play(CLIP_HIT, BLEND)
	var tween := create_tween().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "_knockdown", -1.15, 0.55).set_delay(0.15)


func _process(delta: float) -> void:
	if _character == null:
		return
	# A knockout tilts the whole figure back off its feet and outranks everything.
	if _defeated:
		_character.rotation.x = _knockdown
		return
	_lean += (_lean_target - _lean) * clampf(delta * LEAN_SMOOTH, 0.0, 1.0)
	# Roll into the slip and carry the body with it, so the head really does move
	# off the line rather than the figure just tipping on the spot.
	_character.rotation.z = _lean * LEAN_ROLL * _lean_sign
	_character.position.x = _base_x + _lean * LEAN_SHIFT


## The pose the fighter rests in between actions: the cover if they're blocking,
## otherwise the guard.
func _play_hold() -> void:
	var clip: String = CLIP_BLOCK if (_blocking and _clips.has(CLIP_BLOCK)) else CLIP_GUARD
	if _anim != null and _clips.has(clip) and _anim.current_animation != clip:
		_anim.play(clip, BLEND)


func _play_once(clip: String) -> void:
	if _anim != null and _clips.has(clip):
		_anim.play(clip, BLEND)
