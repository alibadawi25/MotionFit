extends MiniGame
## BoxingGame — the Boxing mini-game.
##
## A stand-up sparring bout shot over the player's shoulder. Every session opens
## with [BoxingCinematic] (a letterboxed orbit of the arena) and settles into the
## behind-the-boxer frame; a live rig then rides that home — dollying in as you
## press forward and trailing you as you slip side to side ([method _update_camera]).
##
## The loop is read-and-react boxing with both an attack and a defend beat:
##   - OPENING — the opponent leaves a side open (a gold target + a HUD call); you
##     throw the matching glove (LEFT jab / RIGHT cross, read from [MotionManager]
##     punches) inside the window to take a chunk of their health.
##   - INCOMING — the opponent winds up (a red tell + "DODGE!"); you slip it by
##     leaning/stepping to a side or ducking, or you wear the shot.
## Empty their health for the knockout.
##
## Score: points per landed shot (bigger for a harder punch and a longer combo),
## plus a knockout bonus. The bout always banks — a loss just pays less.
class_name BoxingGame

## The home frame the cinematic settles into: an over-the-shoulder shot tucked in
## behind and above the player's boxer, looking across at the opponent. It's not a
## static tripod — the live rig ([method _update_camera]) rides this home, dollying
## in as you press forward and sliding with your slip, so the fight breathes.
const CAM_POS: Vector3 = Vector3(-0.85, 2.5, 5.3)
const CAM_LOOK: Vector3 = Vector3(0.45, 1.6, -0.6)
const BASE_FOV: float = 58.0

## How the player drives the frame. Marching in place presses the camera in
## ([member ADVANCE_DOLLY]) and steps the boxer toward the opponent; leaning/
## stepping to a side slips the boxer ([member SLIP_MAX]) and the camera trails it
## ([member SLIP_FOLLOW]). CAM_SMOOTH eases the whole rig so it never snaps.
const SLIP_MAX: float = 0.85
const SLIP_FOLLOW: float = 0.55
const ADVANCE_DOLLY: float = 1.7
const CAM_SMOOTH: float = 6.0
## Lean/duck magnitude (0..1) that reads as a committed dodge on an INCOMING shot.
const DODGE_LEAN: float = 0.42

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

## Where the two fighters stand on the canvas (y = the ring's canvas height). The
## player's boxer is the over-the-shoulder foreground; the opponent faces us.
const YOU_POS: Vector3 = Vector3(-1.15, 1.0, 2.4)
const OPP_POS: Vector3 = Vector3(0.45, 1.0, -0.6)

## The stock heavyweight's ring name, shown on the jumbotron's red corner.
const OPP_NAME: String = "THE HAMMER"

## Bout tuning. Health is 0..1; a clean shot removes HIT_DAMAGE (plus a power
## bonus), a missed opening lets the opponent counter for COUNTER_DAMAGE.
const HIT_DAMAGE: float = 0.11
const HIT_DAMAGE_POWER: float = 0.06
const KO_BONUS: int = 500

## INTRO is the inert phase while the cinematic plays (nothing ticks until it
## hands off and the HUD is built); the bell sequence runs BRIEFING → BOUT → OVER.
enum Phase { INTRO, BRIEFING, BOUT, OVER }
## WAIT is the beat between exchanges; the opponent then either leaves an OPENING
## (you strike) or throws an INCOMING shot (you slip).
enum Ex { WAIT, OPENING, INCOMING }

const BRIEFING_SEC: float = 4.0
## Post-decision hold so the result card sits while the arena roars.
const GLIDE_SEC: float = 4.2

var _phase: Phase = Phase.INTRO
var _phase_left: float = 0.0
var _round_left: float = 90.0

var _ex: Ex = Ex.WAIT
var _ex_left: float = 0.0
var _open_side: String = ""       # "left"/"right" during an OPENING, else ""
var _incoming_side: String = ""   # the glove the opponent throws during an INCOMING
var _window: float = 1.3          # opening window (difficulty)
var _wait_min: float = 0.7
var _wait_max: float = 1.7
var _counter_damage: float = 0.09

var _you_health: float = 1.0
var _opp_health: float = 1.0
var _combo: int = 0
var _shake: float = 0.0
## Live rig state: the lagged camera position, the eased slip-bank roll, the
## decaying impact FOV kick, and the ever-running clock for the idle sway.
var _cam_pos: Vector3 = CAM_POS
var _cam_bank: float = 0.0
var _fov_kick: float = 0.0
var _breathe: float = 0.0
## Live footwork, eased toward the player's motion each frame: lateral slip (world
## x, ±SLIP_MAX) and forward press (0..1). Drive both the boxer and the camera rig.
var _slip: float = 0.0
var _advance: float = 0.0

var _arena: BoxingArena
var _you: BoxingFighter
var _opp: BoxingFighter
var _targets: Dictionary = {}     # "left"/"right" -> MeshInstance3D marker
var _target_mat: Dictionary = {}
var _hud: BoxingHud
var _pause_menu: Control

@onready var _camera: Camera3D = $Camera3D


func get_game_id() -> String:
	return "boxing"


## Build the arena + both fighters and frame the camera on the ring before the
## intro, so the GET-READY countdown and the cinematic reveal a set that already
## has two boxers squared up in it.
func _prepare_world() -> void:
	_apply_difficulty()
	_arena = BoxingArena.new()
	_arena.name = "Arena"
	add_child(_arena)
	_arena.set_crowd_energy(0.12)
	_arena.set_bout(_player_name(), OPP_NAME, _card_strapline())

	_you = BoxingFighter.new()
	_you.name = "You"
	_you.position = YOU_POS
	add_child(_you)
	_you.setup(_player_body(), _player_appearance(), "boxer_player", "blue", PI)

	_opp = BoxingFighter.new()
	_opp.name = "Opponent"
	_opp.position = OPP_POS
	add_child(_opp)
	_opp.setup(_opponent_body(), _opponent_appearance(), "boxer_rival", "red", 0.0)

	_build_targets()

	if _camera != null:
		_camera.global_position = CAM_POS
		_camera.look_at(CAM_LOOK, Vector3.UP)
		_camera.fov = BASE_FOV


## Open the session with the arena tour, then hand back to the ringside frame and
## start the bout.
func _start_game() -> void:
	var cinematic := BoxingCinematic.new()
	cinematic.name = "Cinematic"
	add_child(cinematic)
	cinematic.setup(_camera, _arena, CAM_POS, CAM_LOOK, BASE_FOV)
	cinematic.finished.connect(_on_cinematic_finished)


## The tour is over and the camera sits ringside: raise the HUD + pause menu and
## ring the first bell after a short briefing.
func _on_cinematic_finished() -> void:
	_hud = BoxingHud.new()
	add_child(_hud)
	var layer := CanvasLayer.new()
	add_child(layer)
	_pause_menu = attach_pause_menu(layer)

	_hud.set_health(_you_health, _opp_health)
	_hud.show_briefing()
	_phase = Phase.BRIEFING
	_phase_left = BRIEFING_SEC


func _process(delta: float) -> void:
	super._process(delta)  # keeps MiniGame's elapsed clock ticking
	match _phase:
		Phase.BRIEFING:
			_tick_briefing(delta)
		Phase.BOUT:
			_tick_bout(delta)
		Phase.OVER:
			_tick_over(delta)
	_update_movement(delta)
	_update_camera(delta)


func _tick_briefing(delta: float) -> void:
	_hud.set_briefing_countdown(_phase_left)
	_phase_left -= delta
	if _phase_left <= 0.0:
		_hud.hide_briefing()
		_arena.set_crowd_energy(0.5)
		_arena.cheer_burst(0.7)
		_phase = Phase.BOUT
		_ex = Ex.WAIT
		_ex_left = randf_range(_wait_min, _wait_max)
		_hud.flash_toast("BOX!", BoxingHud.ACCENT)


func _tick_bout(delta: float) -> void:
	_round_left -= delta
	_hud.set_clock(_round_left)
	# The player's own glove always answers a punch, opening or not.
	var thrown: String = MotionManager.consume_punch()
	if thrown != "":
		_you.punch(thrown)

	match _ex:
		Ex.WAIT:
			_ex_left -= delta
			if _ex_left <= 0.0:
				# Mostly openings (attack); the rest are incoming shots (defend).
				if randf() < 0.6:
					_begin_opening()
				else:
					_begin_incoming()
		Ex.OPENING:
			_ex_left -= delta
			if thrown != "":
				if thrown == _open_side:
					_land_hit(MotionManager.get_last_punch_power())
				else:
					_wrong_glove()
			elif _ex_left <= 0.0:
				_opening_closed()
		Ex.INCOMING:
			_ex_left -= delta
			if _is_dodging():
				_dodged()
			elif _ex_left <= 0.0:
				_got_tagged()

	# A knockout this frame already moved us to OVER; don't also judge the clock.
	if _phase == Phase.BOUT and _round_left <= 0.0:
		_finish_on_time()


func _tick_over(delta: float) -> void:
	_phase_left -= delta
	if _phase_left <= 0.0:
		finish()


# --- Exchange resolution -----------------------------------------------------

## Leaves one side open: light its target and call the punch.
func _begin_opening() -> void:
	_ex = Ex.OPENING
	_open_side = "left" if randf() < 0.5 else "right"
	_ex_left = _window
	_light_target(_open_side, true)
	if _open_side == "left":
		_hud.set_prompt("JAB!", BoxingHud.SAFE)
	else:
		_hud.set_prompt("CROSS!", BoxingHud.WARN)


## A clean landed shot: hurt the opponent, score it, and roar.
func _land_hit(power: float) -> void:
	_clear_opening()
	_combo += 1
	_opp.take_hit()
	var dmg: float = HIT_DAMAGE + HIT_DAMAGE_POWER * clampf(power, 0.0, 1.0)
	_opp_health = maxf(0.0, _opp_health - dmg)
	_hud.set_health(_you_health, _opp_health)
	add_score(100 + int(round(power * 80)) + (_combo - 1) * 20)
	_hud.set_score(get_score())
	_hud.set_combo(_combo)
	_hud.flash_toast("HIT!" if _combo < 3 else "COMBO!", BoxingHud.SAFE)
	_hud.flash(BoxingHud.GOLD_FLASH, 0.22)
	_cam_impact(0.12 + power * 0.06, FOV_KICK_HIT)
	_arena.cheer_burst(0.4 + power * 0.4)
	_arena.set_crowd_energy(clampf(0.5 + (1.0 - _opp_health) * 0.4, 0.0, 1.0))
	if _opp_health <= 0.0:
		_win_by_ko()
	else:
		_after_resolve(0.35)


## The right window, the wrong glove: a whiffed shot the opponent slips. No
## damage either way, but the combo dies.
func _wrong_glove() -> void:
	_clear_opening()
	_combo = 0
	_hud.set_combo(0)
	_hud.flash_toast("SLIPPED!", BoxingHud.MUTED)
	_after_resolve(0.3)


## The opening lapsed unanswered — no damage now (the punish path is a separate,
## dodgeable INCOMING shot), the opponent just closes back up and the combo dies.
func _opening_closed() -> void:
	_clear_opening()
	_combo = 0
	_hud.set_combo(0)
	_hud.flash_toast("TOO SLOW", BoxingHud.MUTED)
	_after_resolve(0.3)


## The opponent winds up to throw: light the incoming side red and call DODGE.
## Slip it (lean/step to a side or duck) before the window closes or you wear it.
func _begin_incoming() -> void:
	_ex = Ex.INCOMING
	_incoming_side = "left" if randf() < 0.5 else "right"
	_ex_left = _window + 0.25          # a touch more time than an opening
	_light_target(_incoming_side, true, true)  # red warning glow, not a gold target
	_hud.set_prompt("DODGE!", BoxingHud.DANGER)
	_hud.flash_toast("INCOMING!", BoxingHud.WARN)


## The player slipped the shot: the opponent swings into air, you score the read.
func _dodged() -> void:
	_clear_opening()
	_opp.punch(_incoming_side)          # a glove that finds nothing
	add_score(60)
	_hud.set_score(get_score())
	_hud.flash_toast("SLIPPED IT!", BoxingHud.SAFE)
	_arena.cheer_burst(0.4)
	_after_resolve(0.3)


## The window closed and the player didn't slip: they wear the shot.
func _got_tagged() -> void:
	_clear_opening()
	_combo = 0
	_hud.set_combo(0)
	_opp.punch(_incoming_side)
	_you.take_hit()
	_you_health = maxf(0.0, _you_health - _counter_damage)
	_hud.set_health(_you_health, _opp_health)
	_hud.flash_toast("TAGGED!", BoxingHud.DANGER)
	_hud.flash(BoxingHud.DANGER, 0.4)
	_cam_impact(0.2, FOV_KICK_TAG)
	if _you_health <= 0.0:
		_lose_by_ko()
	else:
		_after_resolve(0.45)


func _after_resolve(wait: float) -> void:
	_ex = Ex.WAIT
	_ex_left = wait + randf_range(_wait_min, _wait_max)
	_hud.set_prompt("")


func _clear_opening() -> void:
	_light_target("left", false)
	_light_target("right", false)
	_open_side = ""
	_incoming_side = ""


# --- End states --------------------------------------------------------------

func _win_by_ko() -> void:
	_opp.knock_out()
	add_score(KO_BONUS)
	_hud.set_score(get_score())
	_hud.set_prompt("")
	_hud.flash_toast("KNOCKOUT!", BoxingHud.ACCENT)
	_arena.set_crowd_energy(1.0)
	_arena.cheer_burst(1.0)
	_hud.show_result("WINNER", "BY KNOCKOUT · +%d" % KO_BONUS, get_score(),
			BoxingHud.SAFE)
	_over(2.0)


func _lose_by_ko() -> void:
	_you.knock_out()
	_hud.set_prompt("")
	_hud.flash_toast("DOWN!", BoxingHud.DANGER)
	_hud.show_result("TKO", "YOU WENT DOWN — GOOD WORK REGARDLESS", get_score(),
			BoxingHud.DANGER)
	_over(2.0)


## Time up: judge it on who has more health left.
func _finish_on_time() -> void:
	_clear_opening()
	_hud.set_prompt("")
	_arena.set_crowd_energy(0.9)
	_arena.cheer_burst(0.8)
	if _you_health >= _opp_health:
		add_score(200)
		_hud.set_score(get_score())
		_hud.show_result("WINNER", "BY DECISION · +200", get_score(), BoxingHud.SAFE)
	else:
		_hud.show_result("DECISION LOSS", "OUT-BOXED THIS TIME", get_score(),
				BoxingHud.WARN)
	_over(GLIDE_SEC)


func _over(hold: float) -> void:
	_phase = Phase.OVER
	_phase_left = hold


# --- 3D target markers -------------------------------------------------------

## Two emissive markers flanking the opponent; the lit one shows which glove to
## throw. Screen-left marker = a LEFT (jab) call, screen-right = RIGHT (cross).
func _build_targets() -> void:
	for side in ["left", "right"]:
		var mi := MeshInstance3D.new()
		var mesh := SphereMesh.new()
		mesh.radius = 0.14
		mesh.height = 0.28
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.9, 0.85, 0.3)
		mat.emission_enabled = true
		mat.emission = Color(1.0, 0.85, 0.2)
		mat.emission_energy_multiplier = 0.0
		mesh.material = mat
		mi.mesh = mesh
		var dx: float = -0.62 if side == "left" else 0.62
		mi.position = OPP_POS + Vector3(dx, 0.95, 0.35)
		mi.visible = false
		add_child(mi)
		_targets[side] = mi
		_target_mat[side] = mat


## [param warning] lights the marker red (an INCOMING tell to slip) instead of the
## gold "throw this glove" opening cue.
func _light_target(side: String, on: bool, warning: bool = false) -> void:
	var mi: MeshInstance3D = _targets.get(side)
	if mi == null:
		return
	mi.visible = on
	var mat: StandardMaterial3D = _target_mat[side]
	mat.emission_energy_multiplier = 3.5 if on else 0.0
	mat.emission = Color(0.95, 0.16, 0.16) if warning else Color(1.0, 0.85, 0.2)


# --- Footwork + camera rig ---------------------------------------------------

## True while the player is committing a dodge — a clear lean/step to either side
## or a duck. Deliberately forgiving (any of them counts) so slipping feels doable.
func _is_dodging() -> bool:
	return (absf(MotionManager.get_turn()) >= DODGE_LEAN
			or MotionManager.get_duck() >= DODGE_LEAN
			or MotionManager.get_crouch() >= DODGE_LEAN)


## Ease the boxer's footwork toward the player's live motion: lean/step slips side
## to side, marching presses forward. Outside the bout it recentres for the result.
func _update_movement(delta: float) -> void:
	var target_slip: float = 0.0
	var target_adv: float = 0.0
	if _phase == Phase.BOUT:
		target_slip = clampf(MotionManager.get_turn(), -1.0, 1.0) * SLIP_MAX
		target_adv = clampf(MotionManager.get_forward(), 0.0, 1.0)
	_slip += (target_slip - _slip) * clampf(delta * CAM_SMOOTH, 0.0, 1.0)
	_advance += (target_adv - _advance) * clampf(delta * CAM_SMOOTH * 0.5, 0.0, 1.0)
	if _you != null:
		_you.position.x = YOU_POS.x + _slip
		_you.position.z = YOU_POS.z - _advance * 0.8


## The live over-the-shoulder rig: rides CAM_POS, dollies in with the forward
## press, trails the player's slip, banks into it, breathes a handheld idle sway,
## and lags toward all of it so the frame carries weight. The cinematic owns the
## camera during INTRO, so this only drives it once the fight is live.
func _update_camera(delta: float) -> void:
	if _camera == null or (_phase != Phase.BOUT and _phase != Phase.OVER):
		return
	if _shake > 0.001:
		_shake = maxf(0.0, _shake - delta * 0.9)
	if _fov_kick > 0.001:
		_fov_kick = maxf(0.0, _fov_kick - delta * FOV_RECOVER)
	_breathe += delta

	# Where the rig wants to be: trailing the slip, dollied in on the press.
	var want: Vector3 = CAM_POS
	want.x += _slip * SLIP_FOLLOW
	want.z -= _advance * ADVANCE_DOLLY
	want.y -= _advance * 0.22
	# Handheld idle drift — alive when you're squared up, calmed as you press in.
	var calm: float = 1.0 - _advance * 0.7
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
	aim.x += _slip * 0.18
	_camera.look_at(aim, Vector3.UP)

	# Bank into the slip (roll) and apply the recovering impact FOV kick. Both go
	# on after look_at, which otherwise resets the camera's orientation each frame.
	_cam_bank = lerpf(_cam_bank, -_slip * BANK_MAX, t)
	_camera.rotation.z += _cam_bank
	_camera.fov = BASE_FOV - _fov_kick


## A hit landed — jolt the rig: shake plus a quick FOV punch-in that eases back.
## Kept separate so both the shot you throw and the one you wear can call it.
func _cam_impact(shake: float, fov_kick: float) -> void:
	_shake = maxf(_shake, shake)
	_fov_kick = maxf(_fov_kick, fov_kick)


# --- Difficulty + fighter specs ----------------------------------------------

func _apply_difficulty() -> void:
	match get_difficulty():
		GameManager.Difficulty.EASY:
			_round_left = 75.0
			_window = 1.7
			_wait_min = 0.9
			_wait_max = 2.0
			_counter_damage = 0.06
		GameManager.Difficulty.HARD:
			_round_left = 100.0
			_window = 0.95
			_wait_min = 0.5
			_wait_max = 1.3
			_counter_damage = 0.13
		_:
			_round_left = 90.0
			_window = 1.3
			_wait_min = 0.7
			_wait_max = 1.7
			_counter_damage = 0.09


## The player's own body/appearance drive their fighter; the opponent is a stock
## heavyweight. If there's no active profile, CharacterFactory falls back cleanly.
func _player_body() -> Dictionary:
	if not ProfileManager.has_active():
		return {"sex": "male", "age": 28, "height_cm": 178.0, "weight_kg": 78.0}
	return {
		"sex": ProfileManager.get_sex(),
		"age": ProfileManager.get_age(),
		"height_cm": ProfileManager.get_height_cm(),
		"weight_kg": ProfileManager.get_weight_kg(),
	}


func _player_appearance() -> Dictionary:
	if ProfileManager.has_active():
		return ProfileManager.get_appearance()
	return {}


func _opponent_body() -> Dictionary:
	return {"sex": "male", "age": 30, "height_cm": 188.0, "weight_kg": 95.0}


func _opponent_appearance() -> Dictionary:
	return {"hair": "bald", "hair_color": "black", "top": "tank",
			"top_color": "black", "bottom": "shorts", "bottom_color": "black",
			"skin": "tan"}


## The player's first name for the jumbotron's blue corner (falls back cleanly with
## no active profile), mirroring the Results screen's first-name split.
func _player_name() -> String:
	if not ProfileManager.has_active():
		return "CHALLENGER"
	var name: String = ProfileManager.get_display_name().strip_edges()
	if name.is_empty():
		return "CHALLENGER"
	return name.split(" ")[0]


## The main-event strapline under the names — leans on the round length so the
## card matches the bout the difficulty actually sets up.
func _card_strapline() -> String:
	return "TITLE BOUT · %d-SEC ROUND" % int(round(_round_left))


# --- Pause -------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if _pause_menu == null or not event.is_action_pressed("ui_cancel"):
		return
	if _pause_menu.visible:
		_pause_menu.close()
	else:
		_pause_menu.open()
