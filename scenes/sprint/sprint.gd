extends MiniGame
## SprintGame — Hurdle Dash (the stadium race cardio game)
##
## A four-lane hurdles race against three AI rivals. Your REAL cadence is your
## sprint: the harder you march on the spot (MotionManager.get_forward), the
## faster you cover the course; hurdles arrive on known marks and you clear
## them with a real jump. Clip one and you stumble — metres lost, rivals
## streaming past. First to the line wins.
##
## Where the zombie run is sustained dread, this is interval intensity: a
## short, honest, all-out effort with a clean win/lose readout. Standings are
## deliberately legible (place chip + field strip — see SprintHud), because a
## race you can read is a race you push in.
##
## The athletes never travel: SprintTrack scrolls the stadium past the player
## and parks each rival at its relative distance every frame (the zombie run's
## trick, reused). Rivals own their own race maths (SprintOpponent); this
## scene owns the player's speed model, hurdle resolution, standings, scoring
## and the start/finish theatre.
##
## Score: +1 per metre + a bonus per cleanly cleared hurdle + a placement
## bonus at the line. A finished race always banks (no fail state); losing
## just pays less.

enum Phase { BRIEFING, MARKS, RACING, GLIDE }

## Run pace: standing still only jogs; the span is where the workout lives.
const BASE_SPEED: float = 2.2
const SPEED_SPAN: float = 7.6

## Hurdle rows every HURDLE_EVERY metres from HURDLE_START to near the line.
const HURDLE_START: float = 45.0
const HURDLE_EVERY: float = 35.0
## A clipped hurdle multiplies speed by this while the recovery timer runs.
const STUMBLE_MULT: float = 0.4
const STUMBLE_SEC: float = 1.2

const CLEAR_BONUS: int = 5
## Placement bonus at the line, indexed by (place - 1).
const PLACE_BONUS: Array[int] = [250, 150, 90, 40]

## Warm-up card time before the starter takes over.
const BRIEFING_SEC: float = 8.0
const MARKS_SEC: float = 1.6
const SET_SEC: float = 1.1
## Post-line glide: the finish card sits while the stride winds down.
const GLIDE_SEC: float = 3.4

## Camera: behind and above the player's lane, looking down the course. FOV
## widens a touch with pace for a cheap sense of speed.
const CAM_POS: Vector3 = Vector3(-1.0, 3.0, 6.2)
const CAM_LOOK: Vector3 = Vector3(-1.0, 1.0, -10.0)
const BASE_FOV: float = 68.0
const FOV_SPAN: float = 7.0

## The three rivals: identity (a real generated body each, cached by slot) and
## the lane they run in. Race pace/flubs are set per difficulty at build time.
## dot = the jersey colour the HUD strip shows for them.
const RIVALS: Array[Dictionary] = [
	{
		"slot": "rival_red", "lane": 0, "dot": Color(0.82, 0.25, 0.22),
		"body": {"sex": "male", "age": 24, "height_cm": 178.0, "weight_kg": 72.0},
		"appearance": {"hair": "short", "hair_color": "black", "top": "tank",
			"top_color": "red", "bottom": "shorts", "bottom_color": "black",
			"skin": "tan"},
	},
	{
		"slot": "rival_green", "lane": 2, "dot": Color(0.30, 0.65, 0.38),
		"body": {"sex": "female", "age": 27, "height_cm": 166.0, "weight_kg": 58.0},
		"appearance": {"hair": "ponytail", "hair_color": "brown", "top": "tshirt",
			"top_color": "green", "bottom": "shorts", "bottom_color": "gray",
			"skin": "brown"},
	},
	{
		"slot": "rival_purple", "lane": 3, "dot": Color(0.55, 0.35, 0.75),
		"body": {"sex": "male", "age": 35, "height_cm": 186.0, "weight_kg": 88.0},
		"appearance": {"hair": "bald", "hair_color": "black", "top": "tank",
			"top_color": "purple", "bottom": "shorts", "bottom_color": "navy",
			"skin": "dark"},
	},
]
## The player's lane index in SprintTrack.LANE_XS (x = -1, second from left).
const PLAYER_LANE: int = 1

var _phase: Phase = Phase.BRIEFING
var _phase_left: float = 0.0
var _race_dist: float = 300.0
var _hurdle_dists: PackedFloat32Array = PackedFloat32Array()
var _dist: float = 0.0
var _dist_accum: float = 0.0
var _race_time: float = 0.0
var _next_hurdle: int = 0
var _stumble_left: float = 0.0
## Smoothed post-line pace so the stride winds down instead of stopping dead.
var _glide_pace: float = 0.0
var _halfway_called: bool = false
var _stretch_called: bool = false

var _track: SprintTrack
var _audio: SprintAudio
var _hud: SprintHud
var _rivals: Array[SprintOpponent] = []
var _pause_menu: Control

@onready var _player: SprintPlayer = $Player
@onready var _camera: Camera3D = $Camera3D


func get_game_id() -> String:
	return "sprint"


## Dress the stadium before the intro so the countdown reveals a ready scene:
## the field on the line, hurdles marching into the distance, camera framed.
func _prepare_world() -> void:
	_race_dist = _difficulty_race_dist()
	var d: float = HURDLE_START
	while d <= _race_dist - 25.0:
		_hurdle_dists.append(d)
		d += HURDLE_EVERY

	_track = SprintTrack.new()
	_track.name = "Track"
	add_child(_track)
	_track.setup(_hurdle_dists, _race_dist)

	_audio = SprintAudio.new()
	_audio.name = "Audio"
	add_child(_audio)

	var speeds: Array = _difficulty_rival_speeds()
	var flub: float = _difficulty_flub_chance()
	for i in RIVALS.size():
		var spec: Dictionary = RIVALS[i].duplicate()
		spec["base_speed"] = speeds[i]
		spec["flub_chance"] = flub
		var rival := SprintOpponent.new()
		rival.name = String(spec["slot"])
		add_child(rival)
		rival.setup(spec, SprintTrack.LANE_XS[int(spec["lane"])], _hurdle_dists)
		_rivals.append(rival)

	if _camera != null:
		_camera.global_position = CAM_POS
		_camera.look_at(CAM_LOOK, Vector3.UP)
		_camera.fov = BASE_FOV


func _start_game() -> void:
	_build_overlay()
	_audio.start_crowd()
	# Stand ready from the very first countdown frame — no jogging on the spot
	# before the gun; the pace bar still reads the warm-up effort.
	_player.set_start_pose("ready")
	_phase = Phase.BRIEFING
	_phase_left = BRIEFING_SEC
	_hud.show_briefing()


func _process(delta: float) -> void:
	super._process(delta)  # keeps MiniGame's elapsed clock ticking
	match _phase:
		Phase.BRIEFING:
			_tick_briefing(delta)
		Phase.MARKS:
			_tick_marks(delta)
		Phase.RACING:
			_tick_racing(delta)
		Phase.GLIDE:
			_tick_glide(delta)


## Warm-up under the how-to card: legs respond (jog on the spot, watch the
## pace bar) but nobody covers ground until the gun.
func _tick_briefing(delta: float) -> void:
	var pace: float = clampf(MotionManager.get_forward(), 0.0, 1.0)
	_player.tick(delta, pace)
	_update_hud(pace)
	_hud.set_briefing_countdown(_phase_left)
	_phase_left -= delta
	if _phase_left <= 0.0:
		_hud.hide_briefing()
		_phase = Phase.MARKS
		_phase_left = MARKS_SEC + SET_SEC
		# The warm-up jog ends: settle onto the line and hold, no ground covered.
		_player.set_start_pose("ready")
		_hud.show_start_call("ON YOUR MARKS")


## The starter's theatre: MARKS → SET → gun. Short and unskippable, like the
## real thing — the tension of the held "SET" is the point.
func _tick_marks(delta: float) -> void:
	var pace: float = clampf(MotionManager.get_forward(), 0.0, 1.0)
	_player.tick(delta, pace)
	var was: float = _phase_left
	_phase_left -= delta
	if was > SET_SEC and _phase_left <= SET_SEC:
		_player.set_start_pose("set")  # down into the blocks, braced
		for rival in _rivals:
			rival.set_crouch()  # the whole field gets set together
		_hud.show_start_call("SET", SprintHud.WARN)
	if _phase_left <= 0.0:
		_player.set_start_pose("")  # the gun frees the run
		_hud.show_start_call("GO!", SprintHud.SAFE)
		get_tree().create_timer(0.8).timeout.connect(_hud.hide_start_call)
		_audio.gun()
		for rival in _rivals:
			rival.start_race()
		_phase = Phase.RACING
		_hud.set_prompt("SPRINT!", SprintHud.ACCENT)


func _tick_racing(delta: float) -> void:
	_race_time += delta
	var pace: float = clampf(MotionManager.get_forward(), 0.0, 1.0)
	var speed: float = BASE_SPEED + pace * SPEED_SPAN
	if _stumble_left > 0.0:
		_stumble_left = maxf(0.0, _stumble_left - delta)
		speed *= STUMBLE_MULT
	_dist += speed * delta
	_accumulate_score(speed * delta)

	_track.advance(speed * delta)
	_track.sync(_dist)
	# The crowd lifts with how hard you're going and how far into the race you
	# are — a quiet start builds to a roaring home straight.
	_track.set_crowd_energy(0.22 + pace * 0.45 + (_dist / _race_dist) * 0.28)
	_player.tick(delta, pace)
	_resolve_hurdles()
	_tick_rivals(delta)
	_call_milestones()
	_update_hud(pace)
	_update_prompt()
	_audio.tick(_dist / _race_dist)
	if _camera != null:
		_camera.fov = BASE_FOV + pace * FOV_SPAN

	if _dist >= _race_dist:
		_finish_race()


## Post-line: the card is up; the stadium keeps sliding as the stride winds
## down, rivals finish their own races behind you, then the result banks.
func _tick_glide(delta: float) -> void:
	_glide_pace = lerpf(_glide_pace, 0.0, 1.0 - exp(-1.6 * delta))
	var speed: float = _glide_pace * SPEED_SPAN
	_dist += speed * delta
	_track.advance(speed * delta)
	_track.sync(_dist)
	_player.tick(delta, _glide_pace)
	_tick_rivals(delta)
	if _camera != null:
		_camera.fov = lerpf(_camera.fov, BASE_FOV, 1.0 - exp(-2.0 * delta))
	_phase_left -= delta
	if _phase_left <= 0.0:
		_audio.hush()
		finish()


func _tick_rivals(delta: float) -> void:
	for rival in _rivals:
		rival.tick(delta, _race_time, _dist)
		rival.place(-(rival.dist - _dist))


## Metres → score, one point each, without losing fractional remainders.
func _accumulate_score(metres: float) -> void:
	_dist_accum += metres
	while _dist_accum >= 1.0:
		add_score(1)
		_dist_accum -= 1.0


## Resolves each hurdle row the moment the player's mark crosses it: airborne
## high enough = cleared (bonus), otherwise a stumble the whole stadium sees.
func _resolve_hurdles() -> void:
	while _next_hurdle < _hurdle_dists.size() and _dist >= _hurdle_dists[_next_hurdle]:
		_next_hurdle += 1
		if _player.is_clearing():
			add_score(CLEAR_BONUS)
			_audio.clear_tick()
			_track.cheer_burst(0.5)
			_hud.flash_toast("CLEAN +%d" % CLEAR_BONUS, SprintHud.SAFE)
		else:
			_stumble_left = STUMBLE_SEC
			_player.stumble()
			_audio.clatter()
			_hud.flash_hit()
			_hud.flash_toast("CLIPPED!", SprintHud.DANGER)


func _call_milestones() -> void:
	if not _halfway_called and _dist >= _race_dist * 0.5:
		_halfway_called = true
		_hud.flash_toast("HALFWAY — KEEP PUSHING", SprintHud.TEXT)
	if not _stretch_called and _dist >= _race_dist - 50.0:
		_stretch_called = true
		_track.cheer_burst(0.7)
		_hud.flash_toast("FINAL STRETCH!", SprintHud.ACCENT)


## Current standing, 1-based: rivals ahead of your mark push you down.
func _current_place() -> int:
	var place: int = 1
	for rival in _rivals:
		if rival.dist > _dist:
			place += 1
	return place


func _update_hud(pace: float) -> void:
	_hud.set_race(_current_place(), RIVALS.size() + 1, _race_dist - _dist, pace)
	# Strip order is lane order: rival red, YOU, rival green, rival purple.
	var fracs: Array[float] = [
		_rivals[0].dist / _race_dist, _dist / _race_dist,
		_rivals[1].dist / _race_dist, _rivals[2].dist / _race_dist,
	]
	_hud.set_strip(fracs)


## The coaching line. Priority: an imminent hurdle, then the last-50m call,
## then standing-based push/praise.
func _update_prompt() -> void:
	if _next_hurdle < _hurdle_dists.size():
		var gap: float = _hurdle_dists[_next_hurdle] - _dist
		if gap < 9.0:
			_hud.set_prompt("JUMP!", SprintHud.ACCENT)
			return
		if gap < 20.0:
			_hud.set_prompt("HURDLE COMING…", SprintHud.WARN)
			return
	if _dist >= _race_dist - 50.0:
		_hud.set_prompt("ALL OUT — GO GO GO!", SprintHud.ACCENT)
		return
	match _current_place():
		1:
			_hud.set_prompt("YOU'RE IN FRONT — HOLD IT!", SprintHud.SAFE)
		4:
			_hud.set_prompt("LAST PLACE — DIG IN!", SprintHud.DANGER)
		_:
			_hud.set_prompt("SPRINT! CATCH THE LEADER", SprintHud.TEXT)


func _finish_race() -> void:
	var place: int = _current_place()
	add_score(PLACE_BONUS[place - 1])
	_player.finish_race()
	_glide_pace = clampf(MotionManager.get_forward(), 0.0, 1.0)
	# The line erupts: hold the crowd at a roar through the finish glide.
	_track.set_crowd_energy(1.0)
	_track.cheer_burst(1.0)
	_audio.cheer()
	_hud.set_prompt("")
	_hud.show_finish(place, get_score())
	_phase = Phase.GLIDE
	_phase_left = GLIDE_SEC


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_toggle_pause()


func _toggle_pause() -> void:
	if _pause_menu == null:
		return
	if _pause_menu.visible:
		_pause_menu.close()
	else:
		_pause_menu.open()


func _build_overlay() -> void:
	_hud = SprintHud.new()
	add_child(_hud)
	var colors: Array[Color] = [
		RIVALS[0]["dot"], SprintHud.ACCENT, RIVALS[1]["dot"], RIVALS[2]["dot"],
	]
	_hud.setup_strip(colors, PLAYER_LANE)
	var layer := CanvasLayer.new()
	add_child(layer)
	_pause_menu = load(SceneManager.PAUSE_MENU).instantiate()
	_pause_menu.hide()
	layer.add_child(_pause_menu)


func _difficulty_race_dist() -> float:
	match get_difficulty():
		GameManager.Difficulty.EASY:
			return 200.0
		GameManager.Difficulty.HARD:
			return 400.0
		_:
			return 300.0


func _difficulty_rival_speeds() -> Array:
	match get_difficulty():
		GameManager.Difficulty.EASY:
			return [4.2, 4.6, 5.0]
		GameManager.Difficulty.HARD:
			return [5.8, 6.3, 6.8]
		_:
			return [5.0, 5.4, 5.8]


func _difficulty_flub_chance() -> float:
	match get_difficulty():
		GameManager.Difficulty.EASY:
			return 0.22
		GameManager.Difficulty.HARD:
			return 0.07
		_:
			return 0.14
