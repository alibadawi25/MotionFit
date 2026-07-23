extends Node
## BoxingCameraRig — the live over-the-shoulder camera for the Boxing bout.
##
## Owns the frame and nothing else: where the camera sits, how it lags, banks,
## breathes and jolts. The game tells it what the player is doing (slip and
## forward press) and when a punch connects; it decides what that looks like.
##
## Split out of boxing.gd because "how the fight is shot" is a self-contained
## concern with its own tuning constants and its own per-frame state, and mixing
## it into the fight's state machine made both harder to read. The bout logic can
## now change without touching the rig, and the rig can be tuned without risk of
## disturbing the exchange timing.
##
## The camera is [b]not[/b] driven during the opening cinematic — [BoxingCinematic]
## owns it then and hands it back at the home frame. Call [method update] only
## once the fight is live (see the `live` argument).
class_name BoxingCameraRig

## The home frame the cinematic settles into: an over-the-shoulder shot tucked in
## behind and above the player's boxer, looking across at the opponent. It's not a
## static tripod — this rig rides that home, dollying in as you press forward and
## sliding with your slip, so the fight breathes.
## Sitting above the top rope and looking down into the ring matters: from lower
## down the ropes cut straight across both fighters' faces and the fight is
## watched through a fence.
const CAM_POS: Vector3 = Vector3(-1.18, 3.42, 5.35)
const CAM_LOOK: Vector3 = Vector3(0.42, 1.42, 0.85)
const BASE_FOV: float = 58.0

## How the player drives the frame: marching in place presses the camera in
## ([constant ADVANCE_DOLLY]); leaning at the waist slips the boxer and the camera
## trails it ([constant SLIP_FOLLOW]).
const SLIP_FOLLOW: float = 0.55
const ADVANCE_DOLLY: float = 1.7

## What gives the rig its third-person-boxing weight (Fight-Night/UFC feel): the
## camera lags toward its target instead of snapping (CAM_LAG), banks into a slip
## (BANK_MAX), breathes a handheld idle sway when you're not pressing in, and
## snaps the FOV inward on impact before recovering (FOV_KICK / FOV_RECOVER).
const CAM_LAG: float = 9.0
const BANK_MAX: float = 0.05          # radians of roll at a full slip (~2.9°)
const FOV_KICK_HIT: float = 6.0       # FOV punch-in when you land a shot
const FOV_KICK_TAG: float = 9.0       # bigger jolt when you wear one
const FOV_RECOVER: float = 22.0       # deg/sec the kick eases back out
const BREATHE_SWAY: float = 0.05      # handheld idle drift, calms as you advance

## Live rig state: the lagged camera position, the eased slip-bank roll, the
## decaying impact FOV kick, the ever-running clock for the idle sway, and the
## decaying impact shake.
var _cam_pos: Vector3 = CAM_POS
var _cam_bank: float = 0.0
var _fov_kick: float = 0.0
var _breathe: float = 0.0
var _shake: float = 0.0

var _camera: Camera3D


## Binds the rig to the game's camera and parks it at the home frame, so the
## GET-READY countdown and the cinematic reveal a set that is already framed.
func setup(camera: Camera3D) -> void:
	_camera = camera
	if _camera == null:
		return
	_camera.global_position = CAM_POS
	_camera.look_at(CAM_LOOK, Vector3.UP)
	_camera.fov = BASE_FOV


## Drives one frame of the rig: rides CAM_POS, dollies in with the forward press,
## trails the player's slip, banks into it, breathes a handheld idle sway, and
## lags toward all of it so the frame carries weight.
##
## [param slip] is the boxer's lateral offset in world x, [param advance] the
## forward press (0..1). [param live] is false while the cinematic owns the
## camera, which is the one time this must not touch it.
func update(delta: float, slip: float, advance: float, live: bool) -> void:
	if _camera == null or not live:
		return
	if _shake > 0.001:
		_shake = maxf(0.0, _shake - delta * 0.9)
	if _fov_kick > 0.001:
		_fov_kick = maxf(0.0, _fov_kick - delta * FOV_RECOVER)
	_breathe += delta

	# Where the rig wants to be: trailing the slip, dollied in on the press.
	var want: Vector3 = CAM_POS
	want.x += slip * SLIP_FOLLOW
	want.z -= advance * ADVANCE_DOLLY
	want.y -= advance * 0.22
	# Handheld idle drift — alive when you're squared up, calmed as you press in.
	var calm: float = 1.0 - advance * 0.7
	want.x += sin(_breathe * 1.3) * BREATHE_SWAY * calm
	want.y += sin(_breathe * 0.9 + 1.7) * BREATHE_SWAY * 0.8 * calm

	# Lag the camera toward that target, then add impact shake on top of the ease.
	var t: float = clampf(delta * CAM_LAG, 0.0, 1.0)
	_cam_pos = _cam_pos.lerp(want, t)
	var pos: Vector3 = _cam_pos
	if _shake > 0.001:
		pos += Vector3(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), 0.0) * _shake
	_camera.global_position = pos

	# Aim at the opponent's head, leading a touch with the slip.
	var aim: Vector3 = CAM_LOOK
	aim.x += slip * 0.18
	_camera.look_at(aim, Vector3.UP)

	# Bank into the slip (roll) and apply the recovering impact FOV kick. Both go
	# on after look_at, which otherwise resets the camera's orientation each frame.
	_cam_bank = lerpf(_cam_bank, -slip * BANK_MAX, t)
	_camera.rotation.z += _cam_bank
	_camera.fov = BASE_FOV - _fov_kick


## A hit landed — jolt the rig: shake plus a quick FOV punch-in that eases back.
## Both the shot you throw and the one you wear call this, which is why it takes
## its magnitudes rather than deciding them.
func impact(shake: float, fov_kick: float) -> void:
	_shake = maxf(_shake, shake)
	_fov_kick = maxf(_fov_kick, fov_kick)
