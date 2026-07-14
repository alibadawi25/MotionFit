extends Node
## MotionManager
##
## Receives processed body-movement data from the Python pose service over a
## local UDP socket and exposes it to gameplay as simple, engine-side values.
## This is the boundary the architecture reserves for the AI pipeline: Godot
## does NO computer vision — it only reads the normalized intents Python sends
## (see CONTEXT.md §9).
##
## Games/characters read [method get_forward] / [method get_turn] instead of the
## keyboard, so the same movement code works whether input comes from the camera
## today or another source later. If the service is not running, values stay at
## zero and [method is_receiving] returns false, so nothing breaks.

## Emitted each frame a new packet arrives, after values are updated.
signal motion_updated(forward: float, turn: float, walking: bool)
## Emitted each packet with the latest fitness stats (cumulative steps this
## service run, and current pace in steps/minute). Kept separate from
## [signal motion_updated] so a HUD can subscribe to just the stats it shows.
signal fitness_updated(steps: int, cadence: float)
## Emitted once each time the player launches a physical jump. This is an
## edge event (fired on the frame Python detects the launch), so connect to it
## for an impulse rather than polling — or use [method consume_jump].
signal jumped
## Emitted each packet with the current squat depth, 0.0 (upright) .. 1.0.
signal crouch_changed(crouch: float)
## Emitted each packet with the live effort/energy read: [param met] is the
## current metabolic-equivalent intensity, [param calories] is the running total
## burned this session (kcal), and [param heart_rate] is bpm (0 = no wearable).
signal effort_updated(met: float, calories: float, heart_rate: float)

## UDP port — must match UDP_PORT in python/pose/pose_server.py.
const PORT: int = 9990
## If no packet arrives within this many seconds, inputs decay to neutral.
const TIMEOUT_SEC: float = 0.5
## kcal burned per MET, per minute, per kilogram of body mass — the standard
## MET→energy conversion (kcal/min = MET * 3.5 * kg / 200).
const KCAL_PER_MET_MIN_PER_KG: float = 3.5 / 200.0
## Body mass assumed if ProfileManager isn't available (keeps the sandbox and
## tests working standalone).
const DEFAULT_BODY_MASS_KG: float = 70.0

var _udp: PacketPeerUDP = PacketPeerUDP.new()
var _forward: float = 0.0
var _turn: float = 0.0
var _walking: bool = false
var _crouch: float = 0.0
var _steps: int = 0
var _cadence: float = 0.0
var _met: float = 0.0       # current effort (metabolic equivalent of task)
var _heart_rate: float = 0.0  # bpm from a wearable, 0 = no reading
var _last_packet_sec: float = -1000.0

# Latched jump: set true when a jump packet arrives, cleared by [method
# consume_jump]. Lets a poller in _physics_process pick up a jump that landed on
# any of the (possibly several) packets drained since its last frame.
var _jump_pending: bool = false

# Baseline captured by [method reset_session_stats] so a game can report steps
# and average cadence for its own run rather than since the service started.
var _session_start_steps: int = 0
var _session_start_sec: float = -1.0
# Calories burned this session, integrated from MET each frame. Body mass is
# captured at reset (a session's player doesn't change mid-game).
var _session_kcal: float = 0.0
var _body_mass_kg: float = DEFAULT_BODY_MASS_KG

func _ready() -> void:
	var err: int = _udp.bind(PORT, "127.0.0.1")
	if err != OK:
		push_error("MotionManager: could not bind UDP port %d (error %d)" % [PORT, err])


func _process(delta: float) -> void:
	# Drain the queue; only the most recent frame matters for realtime control.
	while _udp.get_available_packet_count() > 0:
		var text: String = _udp.get_packet().get_string_from_utf8()
		var data: Variant = JSON.parse_string(text)
		if data is Dictionary:
			_apply(data)

	if not is_receiving():
		_forward = 0.0
		_turn = 0.0
		_walking = false
		_crouch = 0.0
		_cadence = 0.0
		_met = 0.0
		_heart_rate = 0.0
		_jump_pending = false  # drop any unconsumed jump once the feed goes quiet
	elif _met > 0.0:
		# Integrate calories: kcal += MET * (kcal per MET·min·kg) * kg * minutes.
		_session_kcal += _met * KCAL_PER_MET_MIN_PER_KG * _body_mass_kg * (delta / 60.0)


## Marching intensity, 0.0 (still) .. 1.0 (fast). Drive forward speed with this.
func get_forward() -> float:
	return _forward


## Torso lean, -1.0 (one side) .. 1.0 (other side). Drive turning with this.
func get_turn() -> float:
	return _turn


## True while the player is actively marching in place.
func is_walking() -> bool:
	return _walking


## Current squat depth, 0.0 (standing upright) .. 1.0 (deep crouch). Drive a
## crouch pose / height with this.
func get_crouch() -> float:
	return _crouch


## True while the player is squatting past a small dead-zone.
func is_crouching() -> bool:
	return _crouch > 0.25


## Returns true exactly once per detected jump, clearing the latch. Call this
## once per physics frame from a character that wants to jump on a body launch;
## for an event-driven listener, connect to [signal jumped] instead.
func consume_jump() -> bool:
	if _jump_pending:
		_jump_pending = false
		return true
	return false


## Cumulative steps counted since the pose service started this run.
func get_steps() -> int:
	return _steps


## Current pace in steps per minute (0 while not receiving).
func get_cadence() -> float:
	return _cadence


## Current effort as a MET value (metabolic equivalent of task): ~1.2 standing,
## ~4-5 marching, ~8+ vigorous. Body-mass-independent; multiply by weight/time
## for calories, or use [method get_session_calories].
func get_met() -> float:
	return _met


## Heart rate in bpm from a connected wearable, or 0.0 if none is providing one.
func get_heart_rate() -> float:
	return _heart_rate


## Calories (kcal) burned since the last [method reset_session_stats], integrated
## from effort and the player's body mass. This is the number a game passes to
## [method MiniGame.finish].
func get_session_calories() -> float:
	return _session_kcal


## Marks "now" as the start of a session so [method get_session_steps] and
## [method get_session_avg_cadence] report just this game's activity. Call it
## when a game/level begins.
func reset_session_stats() -> void:
	_session_start_steps = _steps
	_session_start_sec = _now()
	_session_kcal = 0.0
	# Capture the current player's body mass for this session's calorie maths.
	var pm: Node = get_node_or_null("/root/ProfileManager")
	if pm != null and pm.has_method("get_weight_kg"):
		_body_mass_kg = pm.get_weight_kg()


## Steps taken since the last [method reset_session_stats].
func get_session_steps() -> int:
	return _steps - _session_start_steps


## Average steps per minute since the last [method reset_session_stats].
func get_session_avg_cadence() -> float:
	if _session_start_sec < 0.0:
		return 0.0
	var minutes: float = (_now() - _session_start_sec) / 60.0
	if minutes <= 0.0:
		return 0.0
	return get_session_steps() / minutes


## True while fresh packets are arriving from the pose service.
func is_receiving() -> bool:
	return (_now() - _last_packet_sec) < TIMEOUT_SEC


func _apply(data: Dictionary) -> void:
	_forward = clampf(float(data.get("forward", 0.0)), 0.0, 1.0)
	_turn = clampf(float(data.get("turn", 0.0)), -1.0, 1.0)
	_walking = bool(data.get("walking", false))
	_crouch = clampf(float(data.get("crouch", 0.0)), 0.0, 1.0)
	_steps = int(data.get("steps", _steps))
	_cadence = maxf(float(data.get("cadence", 0.0)), 0.0)
	_met = maxf(float(data.get("met", 0.0)), 0.0)
	_heart_rate = maxf(float(data.get("hr", 0.0)), 0.0)
	_last_packet_sec = _now()
	motion_updated.emit(_forward, _turn, _walking)
	fitness_updated.emit(_steps, _cadence)
	crouch_changed.emit(_crouch)
	effort_updated.emit(_met, _session_kcal, _heart_rate)
	# Jump is a one-frame edge event from Python: latch it for a poller and fire
	# the signal for listeners. Latch stays set until consume_jump() reads it.
	if bool(data.get("jump", false)):
		_jump_pending = true
		jumped.emit()


func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0
