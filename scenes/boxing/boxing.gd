extends MiniGame
## BoxingGame — the Boxing mini-game.
##
## A stand-up sparring bout watched from ringside. Every session opens with
## [BoxingCinematic] (a letterboxed orbit of the arena) and settles into the
## fixed ringside frame; the fight is then played from there.
##
## The loop is read-the-opening reaction boxing: the opponent repeatedly leaves a
## side open (a glowing target + a HUD call), and you throw the matching glove —
## LEFT for a jab, RIGHT for a cross — read from [MotionManager] punches. Land it
## inside the window and you take a chunk of their health; miss the window and
## they counter and take a chunk of yours. Empty their health for the knockout.
##
## Score: points per landed shot (bigger for a harder punch and a longer combo),
## plus a knockout bonus. The bout always banks — a loss just pays less.
class_name BoxingGame

## The ringside frame the cinematic settles into — where the fight is watched
## from. Just outside the ropes on the entrance side, near canvas eye-level.
const CAM_POS: Vector3 = Vector3(0.0, 2.6, 7.6)
const CAM_LOOK: Vector3 = Vector3(0.0, 1.55, 0.0)
const BASE_FOV: float = 58.0

## Where the two fighters stand on the canvas (y = the ring's canvas height). The
## player's boxer is the over-the-shoulder foreground; the opponent faces us.
const YOU_POS: Vector3 = Vector3(-1.15, 1.0, 2.4)
const OPP_POS: Vector3 = Vector3(0.45, 1.0, -0.6)

## Bout tuning. Health is 0..1; a clean shot removes HIT_DAMAGE (plus a power
## bonus), a missed opening lets the opponent counter for COUNTER_DAMAGE.
const HIT_DAMAGE: float = 0.11
const HIT_DAMAGE_POWER: float = 0.06
const KO_BONUS: int = 500

## INTRO is the inert phase while the cinematic plays (nothing ticks until it
## hands off and the HUD is built); the bell sequence runs BRIEFING → BOUT → OVER.
enum Phase { INTRO, BRIEFING, BOUT, OVER }
enum Ex { WAIT, OPENING }

const BRIEFING_SEC: float = 4.0
## Post-decision hold so the result card sits while the arena roars.
const GLIDE_SEC: float = 4.2

var _phase: Phase = Phase.INTRO
var _phase_left: float = 0.0
var _round_left: float = 90.0

var _ex: Ex = Ex.WAIT
var _ex_left: float = 0.0
var _open_side: String = ""       # "left"/"right" during an OPENING, else ""
var _window: float = 1.3          # opening window (difficulty)
var _wait_min: float = 0.7
var _wait_max: float = 1.7
var _counter_damage: float = 0.09

var _you_health: float = 1.0
var _opp_health: float = 1.0
var _combo: int = 0
var _shake: float = 0.0

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
	_apply_shake(delta)


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
				_begin_opening()
		Ex.OPENING:
			_ex_left -= delta
			if thrown != "":
				if thrown == _open_side:
					_land_hit(MotionManager.get_last_punch_power())
				else:
					_wrong_glove()
			elif _ex_left <= 0.0:
				_opponent_counter()

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
	_shake = maxf(_shake, 0.12)
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


## The window closed unanswered: the opponent counters and you wear one.
func _opponent_counter() -> void:
	_clear_opening()
	_combo = 0
	_hud.set_combo(0)
	_opp.punch("right")
	_you.take_hit()
	_you_health = maxf(0.0, _you_health - _counter_damage)
	_hud.set_health(_you_health, _opp_health)
	_hud.flash_toast("COUNTERED!", BoxingHud.DANGER)
	_hud.flash(BoxingHud.DANGER, 0.4)
	_shake = maxf(_shake, 0.2)
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


func _light_target(side: String, on: bool) -> void:
	var mi: MeshInstance3D = _targets.get(side)
	if mi == null:
		return
	mi.visible = on
	_target_mat[side].emission_energy_multiplier = 3.5 if on else 0.0


# --- Camera shake ------------------------------------------------------------

func _apply_shake(delta: float) -> void:
	# Only the bout owns the camera; during INTRO the cinematic drives it.
	if _camera == null or (_phase != Phase.BOUT and _phase != Phase.OVER):
		return
	if _shake > 0.001:
		_shake = maxf(0.0, _shake - delta * 0.9)
		_camera.global_position = CAM_POS + Vector3(
				randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), 0.0) * _shake
	else:
		_camera.global_position = CAM_POS


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


# --- Pause -------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if _pause_menu == null or not event.is_action_pressed("ui_cancel"):
		return
	if _pause_menu.visible:
		_pause_menu.close()
	else:
		_pause_menu.open()
