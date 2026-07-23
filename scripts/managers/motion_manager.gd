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
## Emitted once each time a watched one-shot gesture arrives in a packet.
## [param key] is the packet field that fired and [param payload] holds it plus
## the companion fields registered with [method watch_pose_event]. The platform
## does not interpret these — a game registers the fields its own moves are made
## of and reads them through its own input adapter (see BoxingInput).
signal pose_event(key: StringName, payload: Dictionary)
## Emitted once when a body calibration finishes, carrying the captured leg
## extensions. MotionManager already saves these to the active profile and pushes
## them to the pose service; connect only if a UI wants a "calibrated!" cue.
signal calibration_captured(standing_ext: float, squat_ext: float)
## Emitted each packet with the live effort/energy read: [param met] is the
## current metabolic-equivalent intensity, [param calories] is the running total
## burned this session (kcal), and [param heart_rate] is bpm (0 = no wearable).
signal effort_updated(met: float, calories: float, heart_rate: float)

## UDP port — must match UDP_PORT in python/pose/pose_server.py.
const PORT: int = 9990
## Port we SEND camera on/off commands to — must match COMMAND_PORT in
## python/pose/pose_server.py. This is the one channel that flows Godot → Python
## (everything else streams the other way): it lets the game power the webcam up
## only while you're playing, so the camera LED stays dark in menus.
const COMMAND_PORT: int = 9992
## How often the desired camera state is re-sent as a keepalive. Commands are
## idempotent on the Python side, so re-sending costs nothing and makes the link
## robust to a dropped UDP datagram — or to the pose service starting AFTER Godot
## (it converges to the right state within this interval).
const CMD_KEEPALIVE_SEC: float = 1.0
## If no packet arrives within this many seconds, inputs decay to neutral.
const TIMEOUT_SEC: float = 0.5
## Time constant (seconds) for gliding the game-facing values toward the latest
## packet. Packets arrive at the camera's ~20–30 Hz while games render at 60+,
## so raw values stair-step; a short exponential glide erases that without
## adding noticeable lag (~2–3 frames at 60 fps).
const SMOOTH_TIME: float = 0.08
## Turning gets a longer time constant than forward speed: steering felt twitchy
## and over-strong, so the yaw signal is glided more heavily. This trades a little
## extra lag (~5–6 frames) for a calm, deliberate turn that doesn't overshoot on
## small torso rotations. Forward/crouch stay snappy on [member SMOOTH_TIME].
const TURN_SMOOTH_TIME: float = 0.22
## Time constant used instead once the feed goes quiet, so motion eases to a
## stop rather than snapping to zero the frame the timeout trips.
const DECAY_TIME: float = 0.15
## Resting metabolism is 1 MET by definition; we bank only the exercise energy
## ABOVE it (net calories), so standing in frame costs ~nothing and every kcal
## credited is workout above rest — the metric fitness trackers report.
const RESTING_MET: float = 1.0
## Body mass / height assumed if ProfileManager isn't available (keeps the
## sandbox and tests working standalone).
const DEFAULT_BODY_MASS_KG: float = 70.0
const DEFAULT_HEIGHT_CM: float = 170.0
## Floor on the Mifflin-St Jeor resting rate (kcal/day), guarding blank/odd
## profiles from yielding a near-zero or negative resting metabolism.
const MIN_RMR_KCAL_PER_DAY: float = 800.0
## kJ per kcal, for the Keytel heart-rate equation (which is fitted in kJ/min).
const KJ_PER_KCAL: float = 4.184
## Below this bpm the Keytel equation is outside its fitted range (it was
## derived from submaximal exercise), so calories fall back to the motion MET.
const HR_KCAL_MIN_BPM: float = 90.0

var _udp: PacketPeerUDP = PacketPeerUDP.new()
# Send-only socket for the camera on/off commands (no bind needed to send).
var _cmd_udp: PacketPeerUDP = PacketPeerUDP.new()
# Desired camera state we keep asserting to Python: 1 = on, 0 = off. Starts off
# because the app opens on a menu (camera is in-game only). See [method camera_on].
var _camera_want: int = 0
var _last_cmd_sent_sec: float = -1000.0
# Latest service/camera state reported by Python ("ready"/"idle"/"opening"/
# "error"); "" while nothing is arriving. Drives the loading/permission UI.
var _status: String = ""
# Setup-screen coaching line from the pose service: a short instruction to get
# into a valid, trackable stance ("SHOW YOUR LEGS", "GET CLOSER", ...), or ""
# when the player is fully framed and ready. Empty while nothing is arriving.
var _ready_hint: String = ""
var _forward: float = 0.0     # latest packet targets…
var _turn: float = 0.0
var _walking: bool = false
var _crouch: float = 0.0
var _duck: float = 0.0
var _forward_out: float = 0.0  # …and the smoothed values games actually read
var _turn_out: float = 0.0
var _crouch_out: float = 0.0
var _duck_out: float = 0.0
var _steps: int = 0
var _cadence: float = 0.0
var _met: float = 0.0       # current effort (metabolic equivalent of task)
var _heart_rate: float = 0.0  # bpm from a wearable, 0 = no reading
var _hands_up: bool = false   # "ready" gesture: both hands raised above the head
# The most recent packet, verbatim. Games read their own vocabulary out of it
# through get_pose_bool/float/string rather than this manager growing an
# accessor per move (see the class docs).
var _pose: Dictionary = {}
# One-shot packet fields a game asked to have latched: key -> Array of companion
# field names to capture alongside it. Registered via watch_pose_event.
var _watched_events: Dictionary = {}
# Latched payloads for those events, cleared by consume_pose_event.
var _pending_events: Dictionary = {}
# Calibration setup state mirrored from the pose service (see Python's Calibrator):
# the phase ("idle"/"still"/"squat"/"done"/"failed"), a short on-screen prompt, and
# a 0..1 progress for the current phase. Drives the calibration setup UI.
var _calib_state: String = "idle"
var _calib_prompt: String = ""
var _calib_progress: float = 0.0
var _prev_calib_state: String = "idle"  # to fire calibration_captured on the done edge
# The active profile's calibration we keep asserting to Python (idempotent, like
# the camera command): {"cmd":"set_calibration",...} or {"cmd":"clear_calibration"}.
var _calib_cmd: Dictionary = {"cmd": "clear_calibration"}
var _last_calib_sent_sec: float = -1000.0
var _last_packet_sec: float = -1000.0

# Latched jump: set true when a jump packet arrives, cleared by [method
# consume_jump]. Lets a poller in _physics_process pick up a jump that landed on
# any of the (possibly several) packets drained since its last frame.
var _jump_pending: bool = false

# Baseline captured by [method reset_session_stats] so a game can report steps
# and average cadence for its own run rather than since the service started.
var _session_start_steps: int = 0
var _session_start_sec: float = -1.0
# Calories burned this session, integrated each frame — from heart rate (Keytel
# et al. 2005) when a wearable is streaming, otherwise from motion MET. The
# profile attributes are captured at reset (a session's player doesn't change
# mid-game).
var _session_kcal: float = 0.0
var _body_mass_kg: float = DEFAULT_BODY_MASS_KG
var _height_cm: float = DEFAULT_HEIGHT_CM
var _age: int = 30
var _sex: String = "unspecified"
# Resting metabolic rate (kcal/min, Mifflin-St Jeor) captured at session reset.
# MET is a multiple of RMR by definition, so kcal/min = (MET - RESTING_MET) *
# this — personalised by mass/height/age/sex instead of a fixed per-kg proxy.
var _rmr_kcal_per_min: float = 1.05
# Rolling effort/heart-rate accumulators for this session, so the results screen
# can report averages and peaks. Summed each frame the feed is live.
var _session_hr_sum: float = 0.0
var _session_hr_samples: int = 0
var _session_hr_peak: float = 0.0
var _session_met_sum: float = 0.0
var _session_met_samples: int = 0

func _ready() -> void:
	var err: int = _udp.bind(PORT, "127.0.0.1")
	if err != OK:
		push_error("MotionManager: could not bind UDP port %d (error %d)" % [PORT, err])
	_cmd_udp.set_dest_address("127.0.0.1", COMMAND_PORT)
	# The camera is in-game only, so default it OFF whenever a scene loads; the
	# game's setup screen (GameIntro) turns it back on. This one hook covers every
	# menu/results/pause-quit exit path without touching each of them. (SceneManager
	# autoloads before MotionManager, so its signal is available here.)
	SceneManager.scene_changing.connect(_on_scene_changing)
	_send_camera_cmd(false)  # assert "off" at boot (menu shows first)
	# Push the active profile's body calibration to the pose service, and re-push
	# whenever the player switches profile, so the right body mapping is always live.
	ProfileManager.profile_switched.connect(func(_id: String): _push_active_calibration())
	_push_active_calibration()


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
		_duck = 0.0
		_cadence = 0.0
		_met = 0.0
		_heart_rate = 0.0
		_hands_up = false
		# Drop the last packet so a game polling get_pose_* reads its defaults
		# (not defending, not leaning) rather than a stale held pose.
		_pose.clear()
		_status = ""  # service silent: state unknown until packets resume
		_ready_hint = ""
		_calib_state = "idle"
		_calib_prompt = ""
		_calib_progress = 0.0
		_jump_pending = false  # drop any unconsumed jump once the feed goes quiet
		_pending_events.clear()  # …and any unconsumed game gesture
	else:
		var kcal_per_min: float = _current_kcal_per_min()
		if kcal_per_min > 0.0:
			_session_kcal += kcal_per_min * (delta / 60.0)
		# Accumulate effort/HR so the results screen can show session averages.
		if _met > 0.0:
			_session_met_sum += _met
			_session_met_samples += 1
		if _heart_rate > 0.0:
			_session_hr_sum += _heart_rate
			_session_hr_samples += 1
			_session_hr_peak = maxf(_session_hr_peak, _heart_rate)

	# Glide the game-facing values toward the packet targets. Exponential, and
	# framed in time (not frames), so a 30, 60 or 144 fps game all feel the same.
	var receiving: bool = is_receiving()
	var smooth_time: float = SMOOTH_TIME if receiving else DECAY_TIME
	var alpha: float = 1.0 - exp(-delta / smooth_time)
	# Turning is smoothed more heavily than forward/crouch so steering stays calm
	# and deliberate (see [member TURN_SMOOTH_TIME]); it still eases out on DECAY_TIME.
	var turn_time: float = TURN_SMOOTH_TIME if receiving else DECAY_TIME
	var turn_alpha: float = 1.0 - exp(-delta / turn_time)
	_forward_out += (_forward - _forward_out) * alpha
	_turn_out += (_turn - _turn_out) * turn_alpha
	_crouch_out += (_crouch - _crouch_out) * alpha
	_duck_out += (_duck - _duck_out) * alpha

	# Keep asserting the desired camera state so a dropped command — or a pose
	# service that started after us — still converges (the command is idempotent).
	if (_now() - _last_cmd_sent_sec) >= CMD_KEEPALIVE_SEC:
		_send_camera_cmd(_camera_want == 1)
	# Likewise re-assert the active profile's calibration (also idempotent), so a
	# pose service that started late still gets the right body mapping.
	if (_now() - _last_calib_sent_sec) >= CMD_KEEPALIVE_SEC:
		_send_calib_cmd()


## Marching intensity, 0.0 (still) .. 1.0 (fast). Drive forward speed with this.
## Smoothed for frame-rate-independent, stutter-free motion; the raw per-packet
## value is available from [method get_forward_raw].
func get_forward() -> float:
	return _forward_out


## Torso lean, -1.0 (one side) .. 1.0 (other side). Drive turning with this.
## Smoothed like [method get_forward].
func get_turn() -> float:
	return _turn_out


## The latest un-smoothed packet values, for logic that wants the exact reading
## (analytics, thresholds) rather than motion-friendly output.
func get_forward_raw() -> float:
	return _forward


func get_turn_raw() -> float:
	return _turn


## True while the player is actively marching in place.
func is_walking() -> bool:
	return _walking


## Current squat depth, 0.0 (standing upright) .. 1.0 (deep crouch). Drive a
## crouch pose / height with this. Smoothed like [method get_forward].
func get_crouch() -> float:
	return _crouch_out


## True while the player is squatting past a small dead-zone.
func is_crouching() -> bool:
	return _crouch > 0.25


## How far the player is bowing/leaning their torso forward, 0.0 (upright) ..
## 1.0 (a clear bow). Unlike [method get_crouch] it reads only the torso, so it
## stays live while the player is running in place — the runner's slide uses it
## as the easy mid-run "duck" gesture. Smoothed like [method get_forward].
func get_duck() -> float:
	return _duck_out


## True while the player is leaning down past a small dead-zone.
func is_ducking() -> bool:
	return _duck > 0.4


## True while the player is holding the "ready" gesture — both hands raised above
## the head. The setup screen times how long this stays true to start the
## countdown; it's a raw per-packet flag, so callers that want a hold should
## accumulate the duration themselves. False whenever the feed is quiet.
func is_hands_up() -> bool:
	return _hands_up


## Asks the pose service to power the webcam ON. Call this when a game's setup
## screen appears (see [GameIntro]); the camera then stays on through play. The
## request is re-asserted as a keepalive, so it's safe to call once. No-op on the
## Python side if the camera is already running, and ignored entirely when the
## pose service is running standalone (not in --game mode).
func camera_on() -> void:
	_camera_want = 1
	_send_camera_cmd(true)


## Asks the pose service to power the webcam OFF (LED dark). Called automatically
## whenever a scene loads (see [method _on_scene_changing]), so the camera is off
## in every menu; a game turns it back on via [method camera_on].
func camera_off() -> void:
	_camera_want = 0
	_send_camera_cmd(false)


## Asks the pose service to run the ~10s calibration (stand still, then one squat).
## It personalises crouch depth to the player's body and seeds the standing
## reference; the profile is saved on the Python side and reloaded automatically
## next launch, so this only needs calling to (re)capture. Drive the setup UI from
## [method get_calibration_prompt] / [method get_calibration_progress]. No-op when
## the pose service is standalone (not in --game mode) — there, press 'c' instead.
func calibrate() -> void:
	var cmd: Dictionary = {"cmd": "calibrate"}
	_cmd_udp.put_packet(JSON.stringify(cmd).to_utf8_buffer())


## Pushes the active profile's stored calibration to the pose service (or a clear
## command if it has none), and keeps re-asserting it. Called on boot and whenever
## the profile switches; safe to call anytime.
func _push_active_calibration() -> void:
	var calib: Dictionary = ProfileManager.get_calibration()
	if calib.has("standing_ext") and calib.has("squat_ext"):
		_calib_cmd = {
			"cmd": "set_calibration",
			"standing": float(calib["standing_ext"]),
			"squat": float(calib["squat_ext"]),
		}
	else:
		_calib_cmd = {"cmd": "clear_calibration"}
	_send_calib_cmd()


func _send_calib_cmd() -> void:
	_cmd_udp.put_packet(JSON.stringify(_calib_cmd).to_utf8_buffer())
	_last_calib_sent_sec = _now()


## Calibration phase from the pose service: "idle" (not calibrating), "still"
## (hold a still stand), "squat" (do one deep squat), "done", or "failed" (the
## squat was too shallow — call [method calibrate] again). "" while the feed is quiet.
func get_calibration_state() -> String:
	return _calib_state


## True while a calibration capture is in progress (phase "still" or "squat").
func is_calibrating() -> bool:
	return _calib_state == "still" or _calib_state == "squat"


## Short on-screen instruction for the current calibration phase (e.g.
## "CALIBRATING - stand still", "NOW SQUAT DOWN and hold"), or "" when not calibrating.
func get_calibration_prompt() -> String:
	return _calib_prompt


## Progress 0.0..1.0 through the current calibration phase, for a progress ring/bar.
func get_calibration_progress() -> float:
	return _calib_progress


## The service/camera state reported by Python: "ready" (camera on, streaming),
## "idle" (camera off, e.g. in menus), "opening" (warming up), "error" (the
## webcam couldn't open — in use or access blocked), or "" while nothing is
## arriving. Drive a loading / permission prompt with this.
func get_status() -> String:
	return _status


## True while the camera is on and streaming pose data.
func is_camera_ready() -> bool:
	return is_receiving() and _status == "ready"


## True when the pose service is alive but the webcam failed to open (in use, or
## camera access blocked in the OS privacy settings). The UI should prompt the
## player to free/allow the camera, and note they can still play keyboard-only.
func is_camera_error() -> bool:
	return is_receiving() and _status == "error"


## The setup-screen coaching line: a short instruction to get into a valid,
## trackable stance ("STEP INTO VIEW", "SHOW YOUR LEGS", "STAND UP", "GET CLOSER",
## "STEP BACK", …), or "" when the player is fully framed and ready. Empty while
## the camera is off/not streaming. Drive the setup prompt with this.
func get_ready_hint() -> String:
	return _ready_hint


## True when the camera is streaming AND the pose service confirms the player is
## in a valid, fully-framed stance to play (standing, legs in view, at a good
## distance). [GameIntro] gates the "raise your hands to start" hold on this, so
## the camera is verified ready before a game begins. False when the camera is
## off, warming up, blocked, or the player still needs to reposition.
func is_pose_ready() -> bool:
	return is_camera_ready() and _ready_hint.is_empty()


## Returns true exactly once per detected jump, clearing the latch. Call this
## once per physics frame from a character that wants to jump on a body launch;
## for an event-driven listener, connect to [signal jumped] instead.
func consume_jump() -> bool:
	if _jump_pending:
		_jump_pending = false
		return true
	return false


# --- Game-specific gestures --------------------------------------------------
#
# Movement every game shares (march, turn, crouch, duck, jump) has first-class
# accessors above. A move that belongs to ONE game does not: Boxing's punch,
# guard and waist slip used to live here as punched/consume_punch/is_guarding/
# get_lean, which meant this platform singleton carried one game's vocabulary —
# and would have carried twenty games' worth by the time the roster filled.
#
# Instead a game registers the packet fields its moves are made of and reads
# them back through its own adapter (scenes/boxing/boxing_input.gd). This
# manager stays the transport: it knows about "a latched field and its companion
# values", never about punches.

## Asks for [param key] to be latched whenever it arrives set in a packet, so a
## game polling once a frame can't miss one that landed between frames.
## [param payload_keys] are companion fields captured at the same instant (a
## punch's power and shape), which is the part a later read can't recover — by
## then the next packet has overwritten them. Idempotent; call it from a game's
## input adapter as it starts.
func watch_pose_event(key: StringName, payload_keys: Array[StringName] = []) -> void:
	_watched_events[key] = payload_keys


## Returns the latched payload for [param key] and clears it, or an empty
## Dictionary if nothing is pending. The payload holds [param key] itself plus
## the companion fields registered with [method watch_pose_event].
func consume_pose_event(key: StringName) -> Dictionary:
	if not _pending_events.has(key):
		return {}
	var payload: Dictionary = _pending_events[key]
	_pending_events.erase(key)
	return payload


## Reads a continuously-streamed field from the latest packet. Absent fields (an
## older pose build, or the feed gone quiet) return [param default], so a game
## degrades to "not doing that" instead of breaking.
func get_pose_bool(key: StringName, default: bool = false) -> bool:
	return bool(_pose.get(key, default))


func get_pose_float(key: StringName, default: float = 0.0) -> float:
	return float(_pose.get(key, default))


func get_pose_string(key: StringName, default: String = "") -> String:
	return String(_pose.get(key, default))


## Whether a packet value counts as "this gesture happened on this frame".
## Python signals a one-shot either as a non-empty string (the punching hand) or
## a true flag, and leaves it empty/false otherwise. A null means the field isn't
## in this packet at all (an older pose build, or a game watching a key this
## build doesn't send) — that's "didn't happen", not an error.
func _event_fired(value: Variant) -> bool:
	if value == null:
		return false
	if value is String or value is StringName:
		return String(value) != ""
	return bool(value)


## Cumulative steps counted since the pose service started this run.
func get_steps() -> int:
	return _steps


## Current pace in steps per minute (0 while not receiving).
func get_cadence() -> float:
	return _cadence


## Current effort as a MET value (metabolic equivalent of task): ~1.2 standing,
## ~4-5 marching, ~8+ vigorous. Body-mass-independent; the resting rate and time
## turn it into calories — see [method get_session_calories].
func get_met() -> float:
	return _met


## Heart rate in bpm from a connected wearable, or 0.0 if none is providing one.
func get_heart_rate() -> float:
	return _heart_rate


## True while a wearable is actively streaming heart rate through the pose
## service. Drive a connection-status indicator with this.
func is_hr_connected() -> bool:
	return is_receiving() and _heart_rate > 0.0


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
	_session_hr_sum = 0.0
	_session_hr_samples = 0
	_session_hr_peak = 0.0
	_session_met_sum = 0.0
	_session_met_samples = 0
	# Drop any gesture/jump left over from the pre-game setup screen so the game
	# doesn't open with a phantom hop the moment it starts.
	_jump_pending = false
	_pending_events.clear()
	# Capture the player's physical attributes for this session's calorie maths.
	# Mass, height, age and sex feed the Mifflin-St Jeor resting rate that scales
	# the motion MET into kcal; age/sex additionally drive the Keytel heart-rate
	# path when a wearable is streaming.
	var pm: Node = get_node_or_null("/root/ProfileManager")
	if pm != null:
		if pm.has_method("get_weight_kg"):
			_body_mass_kg = pm.get_weight_kg()
		if pm.has_method("get_height_cm"):
			_height_cm = pm.get_height_cm()
		if pm.has_method("get_age"):
			_age = pm.get_age()
		if pm.has_method("get_sex"):
			_sex = pm.get_sex()
	_rmr_kcal_per_min = _compute_rmr_kcal_per_min()


## Steps taken since the last [method reset_session_stats].
func get_session_steps() -> int:
	return _steps - _session_start_steps


## Average effort (MET) across this session, or 0.0 if nothing was measured.
func get_session_avg_met() -> float:
	if _session_met_samples == 0:
		return 0.0
	return _session_met_sum / _session_met_samples


## Average heart rate (bpm) across this session, or 0.0 if no wearable streamed.
func get_session_avg_heart_rate() -> float:
	if _session_hr_samples == 0:
		return 0.0
	return _session_hr_sum / _session_hr_samples


## Peak heart rate (bpm) reached this session, or 0.0 if no wearable streamed.
func get_session_peak_heart_rate() -> float:
	return _session_hr_peak


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
	_duck = clampf(float(data.get("duck", 0.0)), 0.0, 1.0)
	_steps = int(data.get("steps", _steps))
	_cadence = maxf(float(data.get("cadence", 0.0)), 0.0)
	_met = maxf(float(data.get("met", 0.0)), 0.0)
	_heart_rate = maxf(float(data.get("hr", 0.0)), 0.0)
	_hands_up = bool(data.get("hands_up", false))
	# Keep the packet whole so a game can read its own fields out of it without
	# this manager growing an accessor per move (see get_pose_bool and friends).
	_pose = data
	# Service/camera state; default "ready" so an older pose build (no status
	# field) still reads as a live camera.
	_status = String(data.get("status", "ready"))
	_ready_hint = String(data.get("ready_hint", ""))
	# Calibration setup state (absent on older pose builds -> harmless defaults).
	_calib_state = String(data.get("calib_state", "idle"))
	_calib_prompt = String(data.get("calib_prompt", ""))
	_calib_progress = clampf(float(data.get("calib_progress", 0.0)), 0.0, 1.0)
	# On the transition into "done", persist the captured calibration to the active
	# profile (so it's this player's) and re-assert it to Python.
	if _calib_state == "done" and _prev_calib_state != "done":
		var standing: float = float(data.get("calib_standing", 0.0))
		var squat: float = float(data.get("calib_squat", 0.0))
		if standing > 0.0 and squat > 0.0:
			ProfileManager.set_calibration(standing, squat)
			_push_active_calibration()
			calibration_captured.emit(standing, squat)
	_prev_calib_state = _calib_state
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
	# Any game-registered one-shot gesture (see watch_pose_event) is latched the
	# same way, without this manager knowing what the move is called.
	for key: StringName in _watched_events:
		if not _event_fired(data.get(key)):
			continue
		var payload: Dictionary = {key: data.get(key)}
		for extra: StringName in _watched_events[key]:
			payload[extra] = data.get(extra)
		_pending_events[key] = payload
		pose_event.emit(key, payload)


## The current NET burn rate in kcal/min — exercise energy above resting. Prefers
## the heart-rate estimate (Keytel et al. 2005 — individually far more accurate
## than any motion model, since HR integrates true physiological load) whenever a
## wearable is streaming a rate inside the equation's fitted range; otherwise the
## motion-MET estimate. A camera dropout therefore costs no calories when a strap
## is worn. Both paths subtract the player's resting rate so standing banks ~0.
func _current_kcal_per_min() -> float:
	# MET is a multiple of resting metabolism by definition, so net exercise
	# energy is (MET - RESTING_MET) scaled by the player's Mifflin-St Jeor RMR.
	var net_met: float = maxf(_met - RESTING_MET, 0.0)
	var met_rate: float = net_met * _rmr_kcal_per_min
	if _heart_rate < HR_KCAL_MIN_BPM:
		return met_rate
	# Keytel 2005, fitted in kJ/min: sex-specific linear model of HR, mass, age.
	# It predicts gross expenditure, so subtract RMR to match the net motion path
	# before the two are compared.
	var male: float = (-55.0969 + 0.6309 * _heart_rate + 0.1988 * _body_mass_kg
			+ 0.2017 * _age) / KJ_PER_KCAL
	var female: float = (-20.4022 + 0.4472 * _heart_rate - 0.1263 * _body_mass_kg
			+ 0.074 * _age) / KJ_PER_KCAL
	var hr_rate: float
	match _sex:
		"male":
			hr_rate = male
		"female":
			hr_rate = female
		_:
			hr_rate = (male + female) * 0.5
	hr_rate = maxf(hr_rate - _rmr_kcal_per_min, 0.0)
	# Never bank less than the movement itself justifies (the linear fit can
	# undershoot near its low-HR edge for light players).
	return maxf(hr_rate, met_rate)


## The player's resting metabolic rate in kcal/min via Mifflin-St Jeor — the
## best-validated predictive RMR equation. Personalises the MET→kcal conversion
## from the profile's mass, height, age and sex, rather than assuming everyone's
## resting metabolism is the population-average 3.5 ml/kg/min (which over-credits
## heavier, older and female players by 15-30%). Captured once per session.
func _compute_rmr_kcal_per_min() -> float:
	var base: float = 10.0 * _body_mass_kg + 6.25 * _height_cm - 5.0 * float(_age)
	var rmr_per_day: float
	match _sex:
		"male":
			rmr_per_day = base + 5.0
		"female":
			rmr_per_day = base - 161.0
		_:
			rmr_per_day = base - 78.0  # midpoint of the male/female constants
	return maxf(rmr_per_day, MIN_RMR_KCAL_PER_DAY) / 1440.0


## Sends a single camera command to the pose service and stamps the send time so
## the keepalive in [method _process] paces itself.
func _send_camera_cmd(on: bool) -> void:
	var cmd: Dictionary = {"cmd": "camera_on" if on else "camera_off"}
	_cmd_udp.put_packet(JSON.stringify(cmd).to_utf8_buffer())
	_last_cmd_sent_sec = _now()


## Default the camera OFF on every scene change; [GameIntro] turns it on for the
## game it belongs to. Menus, results and pause-quit therefore all leave the
## webcam dark with no per-screen wiring.
func _on_scene_changing(_target_path: String) -> void:
	camera_off()


func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0
