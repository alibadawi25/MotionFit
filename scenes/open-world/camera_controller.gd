extends Camera3D
## OpenWorldCamera
##
## Smooth third-person follow camera for the open world. It is a spring arm, not
## a lerped world position: an anchor tracks the player, a yaw tracks their
## facing, and the camera hangs off that anchor at [member follow_distance]. That
## structure buys three things a position lerp cannot:
##
## 1. [b]It never enters the terrain.[/b] The arm is raycast against the world
##    each frame and shortened to whatever length is actually clear, so backing
##    into a hillside pulls the camera in over the player's shoulder instead of
##    burying it inside the heightmap. (See [method _clear_arm_length].)
## 2. [b]It doesn't cut corners.[/b] Lerping a world position toward a point that
##    is itself swinging around the player drags the camera across the inside of
##    every turn. Smoothing the yaw instead keeps the arm rigid and lets it swing
##    around properly.
## 3. [b]Bumps don't bob it.[/b] The anchor smooths vertically much slower than
##    horizontally ([member rise_speed] vs [member follow_speed]), so the constant
##    small Y changes of walking over sculpted ground are absorbed rather than
##    tracked. Without this the camera jitters on every hummock.
##
## Framing responds continuously to how hard the player is marching (via the
## target's `get_run_ratio()`): the arm eases back and the FOV widens with speed,
## so a sprint feels faster than a stroll. Landings punch a brief dip in via the
## target's `landed` signal.

## Path to the CharacterBody3D to follow.
@export var target_path: NodePath
## Horizontal distance the camera trails behind the target, at rest (m).
@export var follow_distance: float = 6.0
## Height above the target's origin that the camera floats at (m).
@export var follow_height: float = 2.5
## Height above the target's origin that the camera looks at (m).
@export var look_height: float = 1.2
## Extra trail distance at a full sprint (m), added on top of follow_distance.
## The camera easing back as you speed up is most of what sells "fast".
@export var sprint_pullback: float = 1.4
## Higher = the anchor catches up to the target's horizontal position faster.
@export var follow_speed: float = 6.0
## Higher = the anchor catches up to the target's HEIGHT faster. Deliberately
## much slower than follow_speed: terrain is bumpy and tracking Y tightly makes
## the whole view chatter.
@export var rise_speed: float = 2.6
## Higher = the arm swings around to the target's new facing faster.
@export var look_speed: float = 8.0
## Higher = FOV eases toward its target faster.
@export var fov_speed: float = 6.0
## FOV standing still, and at a full-tilt march.
@export var base_fov: float = 70.0
@export var sprint_fov: float = 78.0

## Keep the camera at least this far off whatever it hit, so the near plane never
## slices into the surface it is resting against.
const COLLISION_MARGIN: float = 0.35
## Never let a wall push the arm shorter than this — at some point it is better
## to clip than to end up inside the player's head.
const MIN_ARM: float = 0.8
## The arm shortens instantly (a hill must never be seen through) but extends at
## this rate, so leaving a tight spot eases out instead of snapping.
const ARM_EXTEND_SPEED: float = 3.0
## Landing dip: metres dropped per unit of impact, and how fast it recovers.
const DIP_PER_IMPACT: float = 0.055
const DIP_MAX: float = 0.45
const DIP_RECOVER: float = 6.0

## --- look-ahead --------------------------------------------------------------
## Turning slides the framing sideways so the player sits off-centre and you see
## further round the corner you are actually walking into. Metres of lateral
## offset per radian/sec of turn, capped so a fast spin can't fling the frame.
const LOOK_AHEAD: float = 1.5
const LOOK_AHEAD_MAX: float = 1.1
## How fast the measured turn rate settles. Low on purpose: the raw derivative of
## a webcam-driven heading is noisy, and feeding that straight into the framing
## makes the whole view twitch.
const TURN_SMOOTH: float = 4.0

## --- vista mode --------------------------------------------------------------
## Standing still for a moment eases the camera back and lets the world open up.
## This is the one moment the game is not asking anything of the player, so it is
## worth making the view the reward for stopping.
const VISTA_DELAY: float = 1.6
const VISTA_EASE: float = 2.8
const VISTA_PULLBACK: float = 2.2
const VISTA_RISE: float = 0.7
## A very slow orbital drift while parked, so a still frame still breathes.
## Radians of swing, and how fast it swings.
const IDLE_DRIFT: float = 0.09
const IDLE_DRIFT_SPEED: float = 0.22

var _target: Node3D
## Smoothed stand-in for the target's origin; the arm hangs off this, not off the
## target directly, which is what turns raw motion into camera motion.
var _anchor: Vector3
## Smoothed yaw of the arm (radians), tracking the target's facing.
var _yaw: float = 0.0
## Current arm length after collision clamping (see [method _clear_arm_length]).
var _arm: float = 0.0
## Live downward offset from a landing, eased back to 0.
var _dip: float = 0.0
## Smoothed turn rate (rad/s) of the target, driving the look-ahead offset.
var _turn_rate: float = 0.0
## The target's yaw last frame, for that derivative.
var _last_yaw: float = 0.0
## Seconds the player has been essentially stationary, driving vista mode.
var _still: float = 0.0
## Free-running clock for the idle drift.
var _drift_t: float = 0.0
## The target's own collider, excluded from the arm's ray (it is what we orbit).
var _exclude: Array[RID] = []


func _ready() -> void:
	_target = get_node_or_null(target_path) as Node3D
	if _target == null:
		push_error("OpenWorldCamera: target_path '%s' did not resolve to a Node3D" % target_path)
		return
	if _target is CollisionObject3D:
		_exclude = [(_target as CollisionObject3D).get_rid()]
	if _target.has_signal("landed"):
		_target.landed.connect(_on_landed)
	_arm = follow_distance
	snap_to_target()


func _process(delta: float) -> void:
	if _target == null:
		return

	var run: float = _run_ratio()

	# The anchor tracks the player, but horizontally and vertically at different
	# rates (see the class docs): tight in XZ so the camera stays with them, loose
	# in Y so sculpted ground doesn't shake the frame.
	var goal: Vector3 = _target.global_position
	var w_flat: float = 1.0 - exp(-follow_speed * delta)
	var w_rise: float = 1.0 - exp(-rise_speed * delta)
	_anchor.x = lerpf(_anchor.x, goal.x, w_flat)
	_anchor.z = lerpf(_anchor.z, goal.z, w_flat)
	_anchor.y = lerpf(_anchor.y, goal.y, w_rise)

	# Swing the arm toward the target's facing. lerp_angle (not lerpf) so crossing
	# ±PI takes the short way round instead of unwinding the long way.
	var target_yaw: float = _target.global_rotation.y
	_yaw = lerp_angle(_yaw, target_yaw, 1.0 - exp(-look_speed * delta))

	# Turn rate, measured with angle_difference so a ±PI wrap reads as a small
	# turn rather than a full spin. Smoothed hard — see TURN_SMOOTH.
	if delta > 0.0:
		var raw: float = angle_difference(_last_yaw, target_yaw) / delta
		_turn_rate = lerpf(_turn_rate, raw, 1.0 - exp(-TURN_SMOOTH * delta))
	_last_yaw = target_yaw

	# Vista timer: how long since the player last did anything.
	if run > 0.03:
		_still = 0.0
	else:
		_still += delta
	_drift_t += delta

	_dip = move_toward(_dip, 0.0, DIP_RECOVER * delta * maxf(_dip, 0.1))

	_apply_pose(run, delta)
	fov = lerpf(fov, lerpf(base_fov, sprint_fov, run), 1.0 - exp(-fov_speed * delta))


## Places the camera on its (collision-clamped) arm around the anchor and aims it
## at the look point. [param delta] < 0 means "no easing" — used by
## [method snap_to_target] to establish the pose in one shot.
func _apply_pose(run: float, delta: float) -> void:
	# How far into "parked at a viewpoint" we are, 0..1.
	var vista: float = smoothstep(VISTA_DELAY, VISTA_DELAY + VISTA_EASE, _still)

	var pivot: Vector3 = _anchor + Vector3.UP * look_height
	# Look-ahead: slide the framing sideways while turning so the player moves
	# off-centre and the inside of the turn opens up. Applied to the pivot (what
	# the camera orbits AND aims at), so the whole frame shifts rather than the
	# camera merely swivelling and losing the player off the edge.
	var lateral: float = clampf(_turn_rate * LOOK_AHEAD, -LOOK_AHEAD_MAX, LOOK_AHEAD_MAX)
	var right: Vector3 = Basis(Vector3.UP, _yaw) * Vector3(1.0, 0.0, 0.0)
	pivot += right * lateral

	# Where the arm wants to reach: behind (+Z of the target's yaw) and above.
	# Parked, the arm eases back and lifts for a wider, calmer composition, with
	# a very slow orbit so the frame is never dead.
	var arm_yaw: float = _yaw + sin(_drift_t * IDLE_DRIFT_SPEED) * IDLE_DRIFT * vista
	var back: Vector3 = Basis(Vector3.UP, arm_yaw) * Vector3(0.0, 0.0, 1.0)
	var reach: float = follow_distance + sprint_pullback * run + VISTA_PULLBACK * vista
	var lift: float = follow_height - look_height + VISTA_RISE * vista
	var desired: Vector3 = pivot + back * reach + Vector3.UP * lift

	var dir: Vector3 = (desired - pivot).normalized()
	var want_len: float = pivot.distance_to(desired)
	var clear: float = _clear_arm_length(pivot, dir, want_len)
	if delta < 0.0 or clear < _arm:
		_arm = clear  # shorten instantly: never render a frame from inside a hill
	else:
		_arm = lerpf(_arm, clear, 1.0 - exp(-ARM_EXTEND_SPEED * delta))

	global_position = pivot + dir * _arm + Vector3.DOWN * _dip
	var look_at_point: Vector3 = pivot + Vector3.DOWN * _dip
	if global_position.distance_squared_to(look_at_point) > 0.0001:
		look_at(look_at_point, Vector3.UP)


## How long the arm can be along [param dir] from [param pivot] before it hits
## the world, capped at [param want_len]. This is what keeps the camera outside
## the terrain: HTerrain's collider is on layer 1 like everything else, and the
## target's own body is excluded, so any hit is real geometry between us and the
## player. Orbs are Area3Ds and are not hit (rays skip areas by default), so
## walking past a pickup never yanks the camera in.
func _clear_arm_length(pivot: Vector3, dir: Vector3, want_len: float) -> float:
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(pivot, pivot + dir * want_len)
	q.exclude = _exclude
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return want_len
	var blocked: float = pivot.distance_to(hit.position) - COLLISION_MARGIN
	return clampf(blocked, MIN_ARM, want_len)


## Current march intensity 0..1, read from the target so framing responds to
## effort continuously (a binary walking/idle flag can only ever pop between two
## FOVs). Any target without the method simply gets the resting framing.
func _run_ratio() -> float:
	if _target != null and _target.has_method("get_run_ratio"):
		return clampf(_target.get_run_ratio(), 0.0, 1.0)
	return 0.0


## Punches the camera down briefly when the player lands, scaled by how hard they
## hit — a small physical acknowledgement that a jump had weight.
func _on_landed(impact: float) -> void:
	_dip = minf(_dip + impact * DIP_PER_IMPACT, DIP_MAX)


## Immediately frames the camera at its ideal follow pose behind the target, with
## no easing. Used to frame a freshly-placed player (e.g. at spawn, before the
## intro countdown, while _process is frozen) so the first rendered frame already
## looks right instead of easing in from the authored camera position.
func snap_to_target() -> void:
	if _target == null:
		return
	_anchor = _target.global_position
	_yaw = _target.global_rotation.y
	_last_yaw = _yaw
	_turn_rate = 0.0
	# Snapping means "frame this cleanly right now", so start from the neutral
	# composition: no vista pull-back, no drift, no landing dip. Leaving _still
	# high here would open a fresh scene on a drifting, pulled-back camera.
	_still = 0.0
	_drift_t = 0.0
	_dip = 0.0
	fov = base_fov
	_apply_pose(0.0, -1.0)  # negative delta: establish the pose without easing
