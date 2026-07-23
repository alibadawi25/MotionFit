extends RefCounted
## BoxingInput
##
## Boxing's reading of the body: it turns the pose service's raw packet fields
## into the three punches and two defences the game is built on.
##
## This is deliberately NOT in [MotionManager]. Shared movement — march, turn,
## crouch, duck, jump — belongs to the platform because every game speaks it.
## A punch does not: it is Boxing's word. Keeping it here means the roster can
## grow to twenty games without the singleton every screen depends on becoming
## the union of twenty games' vocabularies. A new game with its own moves adds
## an adapter beside its scene, and changes nothing shared.
##
## Construct one when the bout starts; it registers its interest with
## [MotionManager] on the way up.
class_name BoxingInput

## The packet fields this game is built out of. They name BODY MOTION — an arm
## snapping out, hands raised in front of the face, a lean at the waist — because
## the pose service is shared; it is this file that reads them as a punch and a
## guard. The one-shot field is latched with its companions, which are only
## meaningful on that same frame: by the next packet they describe a different
## throw.
const ARM_EXTEND: StringName = &"arm_extend"
const ARM_EXTEND_POWER: StringName = &"arm_extend_power"
const ARM_EXTEND_KIND: StringName = &"arm_extend_kind"
## Continuously-streamed defence: gloves up over the face, and the waist slip.
const HANDS_FRONT: StringName = &"hands_front"
const LEAN: StringName = &"lean"

## The shape Python falls back to when a throw is too scrappy to classify. It
## never rejects an extension, so a messy swing still lands — it just may not
## match the called shot.
const DEFAULT_KIND: String = "straight"

var _power: float = 0.0
var _kind: String = DEFAULT_KIND


func _init() -> void:
	MotionManager.watch_pose_event(ARM_EXTEND, [ARM_EXTEND_POWER, ARM_EXTEND_KIND])


## Returns the hand of the last unconsumed punch ("left" or "right"), or "" if
## none is pending, and clears the latch. Poll once per frame; the strength and
## shape of that same throw are then [method get_last_punch_power] and
## [method get_last_punch_kind].
func consume_punch() -> String:
	var payload: Dictionary = MotionManager.consume_pose_event(ARM_EXTEND)
	if payload.is_empty():
		return ""
	_power = clampf(float(payload.get(ARM_EXTEND_POWER, 0.0)), 0.0, 1.0)
	_kind = String(payload.get(ARM_EXTEND_KIND, DEFAULT_KIND))
	return String(payload.get(ARM_EXTEND, ""))


## The 0.0..1.0 power of the most recent punch (how hard/fast it snapped out),
## for scoring or a heavier hit reaction. Valid right after [method consume_punch].
func get_last_punch_power() -> float:
	return _power


## The shape of the most recent punch: "straight" (a jab/cross), "hook" (the wide
## swinging punch) or "uppercut". Valid right after [method consume_punch].
func get_last_punch_kind() -> String:
	return _kind


## True while the player holds a guard: both gloves up covering the face.
## Streamed live rather than an edge, so it reads as a held block.
func is_guarding() -> bool:
	return MotionManager.get_pose_bool(HANDS_FRONT)


## The player's waist slip: -1.0 leaning hard to their on-screen LEFT, +1.0 to
## the RIGHT, 0.0 upright. A lean at the waist (head off the punch line), which
## is a different move from turning the whole torso to steer.
func get_lean() -> float:
	return clampf(MotionManager.get_pose_float(LEAN), -1.0, 1.0)
