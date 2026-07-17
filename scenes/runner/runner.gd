extends MiniGame
## RunnerGame — Infinite Runner (the "zombie chase" cardio game)
##
## A zombie is on your heels. You escape by RUNNING — and running here means
## marching in place: the harder you march (MotionManager.get_forward), the faster
## the world scrolls past and the more distance you put between you and the
## pursuer. Slack off and it closes in; let it reach you and it grabs you and the
## run ends. Along the way you leap low barriers (jump), slide under bars (crouch)
## and dodge wreckage (lean) — but the core burn is sustained marching, so the
## game rewards exactly the cardio it's meant to.
##
## Tension is all feedback, and deliberately all FELT rather than read: as the
## zombie's "gap" closes, the dark squeezes the visible world down to a tunnel and
## a heartbeat — quickening, throbbing blood into the edges — pulses the camera
## zoom. There is no proximity gauge; you're told you're in trouble, never how much
## (see RunnerHud). The chase maths and that tension live here; RunnerTrack owns
## the scrolling world and obstacles.
##
## Score is distance in metres. It's a scored MiniGame with a real fail state, so
## unlike Open World it ends itself (on capture) and banks the session normally.

## Run pace: standing still crawls at BASE_SPEED; a full-tilt march adds SPEED_SPAN.
const BASE_SPEED: float = 6.0
const SPEED_SPAN: float = 15.0
## How fast the speed difference translates into the zombie gaining/losing ground.
const GAP_GAIN: float = 0.06
## Gap added when an obstacle is struck (a stumble lets the zombie lunge closer).
const STUMBLE_GAP: float = 0.16
## Reaching this gap means caught.
const CAUGHT_GAP: float = 0.985
## Bonus score for cleanly clearing a hazard.
const CLEAR_BONUS: int = 3

## Grace period (seconds) before the chase begins, so the player can read the
## controls, get their marching going and see the HUD respond without being caught.
## The zombie shambles menacingly in place but can't gain ground until it ends.
const BRIEFING_SEC: float = 10.0
## Distance between the "keep going!" milestone shouts (metres).
const MILESTONE_STEP: int = 100

## Unseen-pursuer lines, fired at random once the zombie is a genuine threat. They
## describe something you can't see — that's the job. Nothing here should hint at
## a distance; vagueness is what makes it land.
const GROANS: Array[String] = [
	"IT'S RIGHT BEHIND YOU",
	"DON'T LOOK BACK",
	"IT'S BREATHING ON YOUR NECK",
	"SOMETHING'S GAINING",
	"YOU CAN HEAR IT NOW",
]

## Zombie's Z behind the player at gap 0 (far back, well behind the tight camera and
## unseen — the UI carries the threat) vs gap 1 (surging right onto your back at the
## player's own Z as it takes you). With the over-the-head camera it stays out of
## view the whole run and only bursts into frame from behind in the final stretch —
## so you never know how close it is until it's on you.
const ZDIST_FAR: float = 15.0
const ZDIST_NEAR: float = 0.6

const BASE_FOV: float = 74.0
## Peak camera zoom-in (degrees) at a heartbeat's thump, scaled by danger.
const FOV_KICK: float = 7.0
## Tucked in close behind and just above the runner's head, looking down the track,
## so the player can't see the pursuer behind them — all suspense, no rear view.
const CAM_POS: Vector3 = Vector3(0.0, 2.1, 2.8)
const CAM_LOOK: Vector3 = Vector3(0.0, 1.3, -7.0)

var _track: RunnerTrack
var _hud: RunnerHud
var _pause_menu: Control
var _playing: bool = false
## True during the pre-chase grace period (see [constant BRIEFING_SEC]).
var _briefing: bool = false
var _brief_left: float = 0.0
var _gap: float = 0.0
var _dist_accum: float = 0.0
var _zombie_x: float = 0.0
var _beat_phase: float = 0.0
var _shake: float = 0.0
## Seconds of actual chasing so far — drives the zombie's speed ramp, so the
## briefing time doesn't secretly make the pursuer faster before you even run.
var _chase_time: float = 0.0
## Next distance (m) at which to shout an encouraging milestone.
var _next_milestone: int = MILESTONE_STEP
## Countdown to the next distant lightning/thunder scare; shortens as danger rises.
var _lightning_left: float = 5.0
## Countdown to the next zombie groan cue, so the dread keeps needling.
var _groan_left: float = 7.0

@onready var _player: RunnerPlayer = $Player
@onready var _zombie: RunnerZombie = $Zombie
@onready var _camera: Camera3D = $Camera3D


func get_game_id() -> String:
	return "runner"


## Dress the world and pose everyone before the intro, so the countdown reveals a
## ready scene: track built, zombie looming behind, camera framed on the runner.
func _prepare_world() -> void:
	_track = RunnerTrack.new()
	_track.name = "Track"
	add_child(_track)
	_track.setup(_player)
	_track.spacing_scale = _difficulty_spacing()
	_zombie.global_position = Vector3(0.0, 0.0, ZDIST_FAR)
	if _camera != null:
		_camera.global_position = CAM_POS
		_camera.look_at(CAM_LOOK, Vector3.UP)
		_camera.fov = BASE_FOV


func _start_game() -> void:
	_gap = 0.0
	_dist_accum = 0.0
	_zombie_x = 0.0
	_beat_phase = 0.0
	_chase_time = 0.0
	_next_milestone = MILESTONE_STEP
	_start_cinematic()


## Opens every run with the letterboxed title sequence (RunnerCinematic): the
## graveyard, the zombie's lunge-at-the-lens reveal, then your runner — ending
## with the camera gliding into the exact gameplay frame. Skippable (SPACE or
## both hands up). The HUD + briefing only appear once it hands the scene back,
## so the movie plays over a clean frame.
func _start_cinematic() -> void:
	var cinematic := RunnerCinematic.new()
	cinematic.name = "Cinematic"
	add_child(cinematic)
	cinematic.setup(_camera, _player, _zombie, _track, CAM_POS, CAM_LOOK, BASE_FOV)
	cinematic.finished.connect(_on_cinematic_finished)


func _on_cinematic_finished() -> void:
	_build_overlay()
	_start_briefing()


## Opens the grace period: the world is live so you can practise marching and
## watch the pace bar respond, but the chase (and scoring) hasn't started, so the
## zombie can't catch you yet. The HUD shows the how-to-play card + countdown.
func _start_briefing() -> void:
	_briefing = true
	_brief_left = BRIEFING_SEC
	if _hud != null:
		_hud.show_briefing()


func _process(delta: float) -> void:
	super._process(delta)  # keeps MiniGame's elapsed clock ticking
	if _briefing:
		_tick_briefing(delta)
		return
	if not _playing:
		return

	_chase_time += delta

	# Pace -> run speed -> distance (score) and world scroll.
	var pace: float = clampf(MotionManager.get_forward(), 0.0, 1.0)
	var run_speed: float = BASE_SPEED + pace * SPEED_SPAN
	_track.scroll(delta, run_speed)
	_player.tick(delta, pace)
	_accumulate_distance(delta, run_speed)

	# Chase: the zombie's speed ramps with chase time + difficulty; the gap grows
	# when it out-runs you and shrinks when you out-run it.
	var zp: Vector2 = _zombie_speed()
	var zombie_speed: float = zp.x + zp.y * _chase_time
	var closing: float = zombie_speed - run_speed
	_gap = clampf(_gap + closing * GAP_GAIN * delta, 0.0, 1.0)

	_update_zombie(delta, closing)
	_update_tension(delta)
	_update_scares(delta)
	_update_prompt(closing)

	if _gap >= CAUGHT_GAP:
		_caught()


## Runs each frame of the grace period: the player can already march (world
## scrolls, pace bar moves) and warm up, the zombie shambles hungrily in place,
## but nothing is scored and the gap stays pinned at zero. When the countdown
## runs out, the chase begins for real.
func _tick_briefing(delta: float) -> void:
	var pace: float = clampf(MotionManager.get_forward(), 0.0, 1.0)
	var run_speed: float = BASE_SPEED + pace * SPEED_SPAN
	_track.scroll(delta, run_speed, false)  # scenery only — no hazards, no scoring
	_player.tick(delta, pace)
	_zombie.set_urgency(0.2)
	if _hud != null:
		_hud.set_stats(0, pace)
		_hud.set_danger(0.0, 0.0)
		_hud.set_briefing_countdown(_brief_left)
	_brief_left -= delta
	if _brief_left <= 0.0:
		_begin_chase()


## Ends the grace period and unleashes the pursuit: hazards start streaming, the
## zombie can now gain, and scoring begins.
func _begin_chase() -> void:
	_briefing = false
	_playing = true
	_track.start()
	_track.obstacle_hit.connect(_on_obstacle_hit)
	_track.obstacle_cleared.connect(_on_obstacle_cleared)
	if _hud != null:
		_hud.hide_briefing()
		_hud.flash_toast("RUN!", RunnerHud.DANGER)
		_hud.set_prompt("MARCH!", RunnerHud.ACCENT)


func _accumulate_distance(delta: float, run_speed: float) -> void:
	_dist_accum += run_speed * delta
	while _dist_accum >= 1.0:
		add_score(1)
		_dist_accum -= 1.0
	if get_score() >= _next_milestone:
		if _hud != null:
			_hud.flash_toast("%d m — KEEP GOING!" % _next_milestone, RunnerHud.SAFE)
		_next_milestone += MILESTONE_STEP
	if _hud != null:
		_hud.set_stats(get_score(), clampf(MotionManager.get_forward(), 0.0, 1.0))


## Parks the zombie just behind the player at a distance set by the gap, trailing
## the player's strafe so it stays on your shoulder, and quickens its shamble as
## it gains.
func _update_zombie(delta: float, closing: float) -> void:
	var zdist: float = lerpf(ZDIST_FAR, ZDIST_NEAR, smoothstep(0.0, 1.0, _gap))
	_zombie_x = lerpf(_zombie_x, _player.center_x() * 0.7,
			1.0 - exp(-3.0 * delta))
	_zombie.global_position = Vector3(_zombie_x, 0.0, zdist)
	_zombie.set_urgency(clampf(closing / 4.0, 0.0, 1.0))


## The danger overlay: a heartbeat whose rate rises with the gap drives both the
## camera zoom-pulse and the HUD's closing dark. With the gauge gone the beat IS
## the readout — a slow thud when you're clear, a hammering one when it's on you —
## so it runs across a wide enough range to be felt without being counted.
func _update_tension(delta: float) -> void:
	var hz: float = lerpf(0.75, 3.2, _gap)
	_beat_phase += hz * delta
	var pulse: float = _heartbeat(_beat_phase)
	var intensity: float = smoothstep(0.12, 1.0, _gap)
	# Camera: base frame + heartbeat zoom-in + a decaying shake from any hit.
	if _camera != null:
		_camera.fov = BASE_FOV - pulse * FOV_KICK * intensity
		_shake = maxf(0.0, _shake - delta * 2.5)
		var jitter := Vector3(
			randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), 0.0) * _shake * 0.35
		_camera.global_position = CAM_POS + jitter
	if _hud != null:
		_hud.set_danger(_gap, pulse)


## Distant thunder-flashes and unseen groans that keep the dread alive between
## obstacles; both quicken as the zombie closes so the scene feels more alive the
## more danger you're in.
func _update_scares(delta: float) -> void:
	if _hud == null:
		return
	_lightning_left -= delta
	if _lightning_left <= 0.0:
		_hud.flash_lightning()
		_lightning_left = randf_range(7.0, 13.0) - _gap * 4.5
	_groan_left -= delta
	if _groan_left <= 0.0:
		# Only taunt once the zombie is a real threat, so it lands. With nothing on
		# screen to look at, these unseen-behind-you lines carry the dread — vary
		# them so the same words never wear the fear off.
		if _gap > 0.35:
			_hud.flash_toast(GROANS[randi() % GROANS.size()], RunnerHud.DANGER)
		_groan_left = randf_range(6.0, 11.0) - _gap * 3.0


## The bottom coaching line. Priority: an imminent obstacle cue, then danger
## warnings when the zombie is closing, then genuine encouragement when you're
## holding it off or pulling away — the game should hype you up, not only scold.
func _update_prompt(closing: float) -> void:
	if _hud == null:
		return
	var np: Dictionary = _track.nearest_prompt()
	if not np.is_empty():
		_hud.set_prompt(String(np["action"]), RunnerHud.ACCENT)
	elif _gap > 0.6:
		_hud.set_prompt("MARCH FASTER!", RunnerHud.DANGER)
	elif _gap > 0.32:
		_hud.set_prompt("DON'T LET IT CATCH YOU", RunnerHud.WARN)
	elif closing < -1.5:
		_hud.set_prompt("YES! YOU'RE PULLING AWAY!", RunnerHud.SAFE)
	elif _gap < 0.12:
		_hud.set_prompt("GREAT PACE — KEEP IT UP!", RunnerHud.SAFE)
	else:
		_hud.set_prompt("KEEP MARCHING", RunnerHud.MUTED)


func _on_obstacle_hit(_type: int) -> void:
	_gap = clampf(_gap + STUMBLE_GAP, 0.0, 1.0)
	_shake = 1.0
	_player.stumble()
	if _hud != null:
		_hud.flash_hit()


func _on_obstacle_cleared(_type: int) -> void:
	add_score(CLEAR_BONUS)


## The zombie catches you: it lunges, everything stops, and after a beat the run
## is banked to the results screen.
func _caught() -> void:
	if not _playing:
		return
	_playing = false
	_zombie.lunge()
	if _hud != null:
		_hud.set_danger(1.0, 1.0)
		_hud.set_prompt("CAUGHT!", RunnerHud.DANGER)
	var timer := get_tree().create_timer(1.6)
	timer.timeout.connect(func() -> void: finish())


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
	_hud = RunnerHud.new()
	add_child(_hud)
	var layer := CanvasLayer.new()
	add_child(layer)
	_pause_menu = load(SceneManager.PAUSE_MENU).instantiate()
	_pause_menu.hide()
	layer.add_child(_pause_menu)


## Two quick thumps per cycle (lub-dub), used to pulse the camera zoom + vignette.
func _heartbeat(phase: float) -> float:
	var p: float = fposmod(phase, 1.0)
	var lub: float = exp(-pow((p - 0.0) / 0.055, 2.0))
	var dub: float = 0.65 * exp(-pow((p - 0.19) / 0.055, 2.0))
	return clampf(lub + dub, 0.0, 1.0)


func _zombie_speed() -> Vector2:  # (base m/s, ramp m/s²)
	match get_difficulty():
		GameManager.Difficulty.EASY:
			return Vector2(7.5, 0.09)
		GameManager.Difficulty.HARD:
			return Vector2(9.5, 0.20)
		_:
			return Vector2(8.5, 0.14)


func _difficulty_spacing() -> float:
	match get_difficulty():
		GameManager.Difficulty.EASY:
			return 1.25
		GameManager.Difficulty.HARD:
			return 0.8
		_:
			return 1.0
