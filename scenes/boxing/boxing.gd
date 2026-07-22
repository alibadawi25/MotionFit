extends MiniGame
## BoxingGame — the Boxing mini-game.
##
## A stand-up sparring bout shot over the player's shoulder. Every session opens
## with [BoxingCinematic] (a letterboxed orbit of the arena) and settles into the
## behind-the-boxer frame; a live rig then rides that home — dollying in as you
## press forward and trailing you as you slip side to side ([method _update_camera]).
##
## [b]The whole game is three punches and two ways to defend[/b], deliberately so:
## this is a fitness game for people who have never boxed, not a fight sim.
##   - PUNCH — a STRAIGHT (jab/cross), a WIDE hook, or an UPPERCUT, with either
##     hand. Python names the shape of whatever you threw (see
##     [method MotionManager.get_last_punch_kind]) and always names one, so a
##     scrappy swing still lands.
##   - DEFEND — BLOCK (both hands up over your face) or LEAN at the waist to
##     either side.
##
## The loop is a called exchange, on a beat:
##   - OPENING — the opponent leaves a side open and the corner calls a punch
##     ("LEFT HOOK"). Any punch inside the window lands; matching the called hand
##     [i]and[/i] shape is a PERFECT and pays most. Nothing is ever punished for
##     being the wrong punch — the grade just changes.
##   - INCOMING — the opponent winds up and the call turns red: BLOCK, or LEAN
##     LEFT / LEAN RIGHT. The right answer slips it clean, any other defence
##     softens it, and if you answer with nothing your corner's AUTO-GUARD
##     ([member _assist]) covers for you while it has charge.
##   - FLURRY — an occasional free-hit window where everything lands. It's the
##     calorie beat as much as the fun one.
## Empty their health for the knockout.
##
## Score: points per landed shot (bigger for a better grade, a harder punch and a
## longer combo), plus a knockout bonus. The bout always banks — a loss just pays
## less. Calories come from the pose service's boxing effort model (punch rate,
## guard hold and slip work) and are on screen the whole round.
class_name BoxingGame

## The home frame the cinematic settles into: an over-the-shoulder shot tucked in
## behind and above the player's boxer, looking across at the opponent. It's not a
## static tripod — the live rig ([method _update_camera]) rides this home, dollying
## in as you press forward and sliding with your slip, so the fight breathes.
## Sitting above the top rope and looking down into the ring matters: from lower
## down the ropes cut straight across both fighters' faces and the fight is
## watched through a fence.
const CAM_POS: Vector3 = Vector3(-1.18, 3.42, 5.35)
const CAM_LOOK: Vector3 = Vector3(0.42, 1.42, 0.85)
const BASE_FOV: float = 58.0

## How the player drives the frame. Marching in place presses the camera in
## ([member ADVANCE_DOLLY]) and steps the boxer toward the opponent; leaning at
## the waist slips the boxer ([member SLIP_MAX]) and the camera trails it
## ([member SLIP_FOLLOW]). CAM_SMOOTH eases the whole rig so it never snaps.
const SLIP_MAX: float = 0.85
const SLIP_FOLLOW: float = 0.55
const ADVANCE_DOLLY: float = 1.7
const CAM_SMOOTH: float = 6.0
## Lean magnitude (0..1) that reads as a committed slip to that side.
const DODGE_LEAN: float = 0.40

## Idle footwork the boxer does on his own. Standing perfectly still between
## exchanges looks dead, and a player who is catching their breath shouldn't have
## to hold a pose to keep the fight alive — so the figure drifts and bobs by
## itself, and the drift fades out as soon as the player leans for real.
const AUTO_SWAY: float = 0.16        # how far the autonomous drift carries him
const AUTO_SWAY_HZ: float = 0.42     # how slowly it wanders

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

## Impact hit-stop: the world freezes for a beat on a clean landing, which is
## what makes a punch feel like it connected with something solid. Short enough
## that it never reads as a stutter, and always restored (see [method _hit_stop]).
const HITSTOP_SCALE: float = 0.22
const HITSTOP_SEC: float = 0.08
## The knockout is worth slowing right down for.
const KO_SLOWMO_SCALE: float = 0.35
const KO_SLOWMO_SEC: float = 1.3

## Where the two fighters stand on the canvas (y = the ring's canvas height). The
## player's boxer is the over-the-shoulder foreground; the opponent faces us.
## They stand about a punch and a half apart — close enough that the opponent
## fills the frame and a thrown punch plainly reaches him, which is most of what
## makes the exchange read as a fight rather than two figures on a stage.
const YOU_POS: Vector3 = Vector3(-1.15, 1.0, 2.4)
const OPP_POS: Vector3 = Vector3(0.42, 1.0, 0.85)

## The stock heavyweight's ring name, shown on the jumbotron's red corner.
const OPP_NAME: String = "THE HAMMER"

## Bout tuning. Health is 0..1; a landed shot removes HIT_DAMAGE scaled by the
## grade (see [member GRADE_DAMAGE]) plus a power bonus.
const HIT_DAMAGE: float = 0.11
const HIT_DAMAGE_POWER: float = 0.06
const KO_BONUS: int = 500

## How much each grade of answer is worth. PERFECT is the called hand and shape,
## GOOD matches one of the two, and LOOSE is any other punch — which still lands,
## because a player swinging hard and burning calories should never be told "no".
const GRADE_DAMAGE: Dictionary = {"perfect": 1.6, "good": 1.15, "loose": 0.75}
const GRADE_SCORE: Dictionary = {"perfect": 160, "good": 110, "loose": 70}
const GRADE_TOAST: Dictionary = {
	"perfect": "PERFECT!", "good": "NICE SHOT!", "loose": "LANDED!",
}
## A free-hit flurry pays less per punch than a called shot — it's a burst of
## volume, so the reward is in the count (and the calories), not the per-punch.
const FLURRY_DAMAGE: float = 0.5
const FLURRY_SCORE: int = 55

## The three punch shapes, with the plain-language coaching line each one gets on
## screen. Keys match [method MotionManager.get_last_punch_kind] exactly.
const PUNCH_NAMES: Dictionary = {
	"straight": "STRAIGHT", "hook": "WIDE", "uppercut": "UPPERCUT",
}
const PUNCH_HINTS: Dictionary = {
	"straight": "punch straight out in front of you",
	"hook": "swing your arm around, wide",
	"uppercut": "drive your fist up from below",
}
const KINDS: Array = ["straight", "hook", "uppercut"]

## The two defences, keyed by what the player must do. "block" is both gloves up
## over the face; "left"/"right" are a waist lean to that side.
const DEFENCE_CALLS: Dictionary = {
	"block": "BLOCK!", "left": "LEAN LEFT!", "right": "LEAN RIGHT!",
}
const DEFENCE_HINTS: Dictionary = {
	"block": "both hands up, cover your face",
	"left": "bend at the waist, to your left",
	"right": "bend at the waist, to your right",
}

## AUTO-GUARD: the assist that makes this playable by anyone. It refills over the
## round and spends itself to block a shot the player didn't answer, so missing a
## read costs a sliver of health instead of the bout. Its recharge is the main
## difficulty dial — generous on EASY, nearly absent on HARD.
const ASSIST_BLOCK_FACTOR: float = 0.25   # damage that gets through an auto-block
const ASSIST_BLOCK_HOLD: float = 0.6      # how long the auto-cover stays up, on screen

## INTRO is the inert phase while the cinematic plays (nothing ticks until it
## hands off and the HUD is built); the bell sequence runs BRIEFING → BOUT → OVER.
enum Phase { INTRO, BRIEFING, BOUT, OVER }
## WAIT is the beat between exchanges; the opponent then either leaves an OPENING
## (you strike), throws an INCOMING shot (you defend), or drops into a FLURRY
## (everything lands).
enum Ex { WAIT, OPENING, INCOMING, FLURRY }

const BRIEFING_SEC: float = 6.0
## Post-decision hold so the result card sits while the arena roars.
const GLIDE_SEC: float = 4.2

var _phase: Phase = Phase.INTRO
var _phase_left: float = 0.0
var _round_left: float = 90.0

var _ex: Ex = Ex.WAIT
var _ex_left: float = 0.0
var _call_hand: String = ""       # the glove an OPENING asks for
var _call_kind: String = ""       # the punch shape an OPENING asks for
var _defence: String = ""         # "block"/"left"/"right" during an INCOMING
var _incoming_side: String = ""   # the glove the opponent throws on an INCOMING
var _window: float = 1.6          # opening window (difficulty)
var _wait_min: float = 0.7
var _wait_max: float = 1.7
var _counter_damage: float = 0.09
var _flurry_chance: float = 0.14
var _assist_recharge: float = 0.09   # assist charge per second

var _you_health: float = 1.0
var _opp_health: float = 1.0
var _combo: int = 0
var _shake: float = 0.0
## AUTO-GUARD charge, 0..1. Full = the next unanswered shot is covered for free.
var _assist: float = 1.0
## Counts down while an AUTO-GUARD save holds the boxer's cover up.
var _assist_block_left: float = 0.0
## Every punch thrown this bout, landed or not — it all counts as work done.
var _punches_thrown: int = 0
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
## Clock for the autonomous idle drift (see [member AUTO_SWAY]).
var _auto_clock: float = 0.0

var _arena: BoxingArena
var _you: BoxingFighter
var _opp: BoxingFighter
var _targets: Dictionary = {}     # "left"/"right"/"chin" -> MeshInstance3D marker
var _target_mat: Dictionary = {}
var _hud: BoxingHud
var _pause_menu: Control
var _impact: Node3D               # pooled impact flash (a light + a glowing burst)
var _impact_light: OmniLight3D
var _impact_mat: StandardMaterial3D
## The one tween allowed to drive Engine.time_scale (see [method _slow_time]).
var _time_tween: Tween

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
	_build_impact()

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
	_hud.set_assist(_assist)
	_hud.show_briefing()
	_phase = Phase.BRIEFING
	_phase_left = BRIEFING_SEC


## Time scale is a global the bout borrows for hit-stop and the knockout slow-mo,
## so it is always handed back — a game that exits mid-effect must not leave the
## whole app running slow.
func _exit_tree() -> void:
	Engine.time_scale = 1.0


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
	_tick_assist(delta)
	_hud.set_workout(MotionManager.get_session_calories(), _punches_thrown)
	# The player's boxer mirrors their body whatever the exchange is doing: their
	# own guard raises his, so covering up always looks like covering up. An
	# AUTO-GUARD save holds the cover up for a moment on its own, so the player
	# can see their corner cover for them.
	_assist_block_left = maxf(0.0, _assist_block_left - delta)
	_you.set_blocking(MotionManager.is_guarding() or _assist_block_left > 0.0)

	# The player's own glove always answers a punch, called or not.
	var thrown: String = MotionManager.consume_punch()
	var kind: String = MotionManager.get_last_punch_kind()
	if thrown != "":
		_punches_thrown += 1
		_you.punch(thrown, kind)

	match _ex:
		Ex.WAIT:
			_ex_left -= delta
			if _ex_left <= 0.0:
				_next_exchange()
		Ex.OPENING:
			_ex_left -= delta
			if thrown != "":
				_land_hit(MotionManager.get_last_punch_power(),
						_grade(thrown, kind))
			elif _ex_left <= 0.0:
				_opening_closed()
		Ex.INCOMING:
			_ex_left -= delta
			var answer: String = _defence_held()
			# The called answer resolves the moment they find it. A different
			# defence only resolves when the window runs out — otherwise a player
			# who simply keeps their guard up (the natural stance!) would burn
			# every incoming shot before they'd had a chance to read the call.
			if answer == _defence:
				_defended(true)
			elif _ex_left <= 0.0:
				if answer != "":
					_defended(false)
				else:
					_shot_arrives()
		Ex.FLURRY:
			_ex_left -= delta
			if thrown != "":
				_flurry_hit(MotionManager.get_last_punch_power())
			elif _ex_left <= 0.0:
				_flurry_over()

	# A knockout this frame already moved us to OVER; don't also judge the clock.
	if _phase == Phase.BOUT and _round_left <= 0.0:
		_finish_on_time()


func _tick_over(delta: float) -> void:
	_phase_left -= delta
	if _phase_left <= 0.0:
		Engine.time_scale = 1.0   # never hand a slowed clock to the next scene
		finish()


## AUTO-GUARD refills whenever it isn't full. Holding your own guard up refills it
## faster: the assist is meant to reward a player for doing the defensive work,
## not to replace it.
func _tick_assist(delta: float) -> void:
	if _assist >= 1.0:
		return
	var rate: float = _assist_recharge * (1.8 if MotionManager.is_guarding() else 1.0)
	_assist = minf(1.0, _assist + rate * delta)
	_hud.set_assist(_assist)


# --- Exchange resolution -----------------------------------------------------

## Picks what the opponent does next. Mostly openings (the game is about throwing
## punches), a healthy share of incoming shots to defend, and an occasional free
## flurry to open the round up.
func _next_exchange() -> void:
	var roll: float = randf()
	if roll < _flurry_chance:
		_begin_flurry()
	elif roll < _flurry_chance + 0.55:
		_begin_opening()
	else:
		_begin_incoming()


## Leaves one side open and calls a punch: which glove, and which of the three
## shapes. Both are on screen in words — the player never has to decode an icon.
func _begin_opening() -> void:
	_ex = Ex.OPENING
	_call_hand = "left" if randf() < 0.5 else "right"
	_call_kind = String(KINDS[randi() % KINDS.size()])
	_ex_left = _window
	# An uppercut goes up the middle; the straights and hooks come in on a side.
	_light_target("chin" if _call_kind == "uppercut" else _call_hand, true)
	_hud.set_prompt("%s %s" % [_call_hand.to_upper(), PUNCH_NAMES[_call_kind]],
			BoxingHud.ACCENT, String(PUNCH_HINTS[_call_kind]))


## Grades the punch the player actually threw against the one that was called.
## Every answer lands — the grade only decides how much. Matching both the hand
## and the shape is a PERFECT; matching either is GOOD; anything else is LOOSE
## and still takes health off, because a hard swing is never a failure here.
func _grade(hand: String, kind: String) -> String:
	var right_hand: bool = hand == _call_hand
	var right_kind: bool = kind == _call_kind
	if right_hand and right_kind:
		return "perfect"
	if right_hand or right_kind:
		return "good"
	return "loose"


## A landed shot: hurt the opponent, score it, and roar.
func _land_hit(power: float, grade: String) -> void:
	_clear_calls()
	_opp.take_hit()
	var dmg: float = (HIT_DAMAGE + HIT_DAMAGE_POWER * clampf(power, 0.0, 1.0)) \
			* float(GRADE_DAMAGE[grade])
	_opp_health = maxf(0.0, _opp_health - dmg)
	_hud.set_health(_you_health, _opp_health)
	# Any landed punch keeps a combo alive; only the clean ones grow it fast, and
	# a loose one never breaks the streak the player has built.
	_combo += 1
	add_score(int(GRADE_SCORE[grade]) + int(round(power * 80)) + (_combo - 1) * 20)
	_hud.set_combo(_combo)
	_hud.flash_toast(String(GRADE_TOAST[grade]) if _combo < 3 else "COMBO x%d!" % _combo,
			BoxingHud.SAFE)
	_hud.set_score(get_score())
	_hud.flash(BoxingHud.GOLD_FLASH, 0.22 if grade != "perfect" else 0.32)
	_cam_impact(0.12 + power * 0.06, FOV_KICK_HIT)
	_impact_burst(_opp.global_position + Vector3(0.0, 1.5, 0.35),
			Color(1.0, 0.85, 0.35))
	if grade == "perfect":
		_hit_stop()
	_arena.cheer_burst(0.4 + power * 0.4)
	_arena.set_crowd_energy(clampf(0.5 + (1.0 - _opp_health) * 0.4, 0.0, 1.0))
	if _opp_health <= 0.0:
		_win_by_ko()
	else:
		_after_resolve(0.35)


## The opening lapsed unanswered — no damage now (the punish path is a separate,
## defendable INCOMING shot), the opponent just closes back up. The combo is
## nudged down rather than wiped, so a breather doesn't erase a good run.
func _opening_closed() -> void:
	_clear_calls()
	_combo = maxi(0, _combo - 1)
	_hud.set_combo(_combo)
	_hud.flash_toast("SHAKE IT OUT", BoxingHud.MUTED)
	_after_resolve(0.3)


## The opponent winds up to throw and the corner calls the answer: block it, or
## lean off the line to one side. Slip it before the window closes, or wear it —
## unless AUTO-GUARD has charge, which covers an unanswered shot.
func _begin_incoming() -> void:
	_ex = Ex.INCOMING
	_defence = ["block", "left", "right"][randi() % 3]
	# The glove it comes on: leaning left means it comes from screen-right, and a
	# block is a straight one up the middle.
	_incoming_side = "right" if _defence == "left" else "left"
	_ex_left = _window + 0.35          # a touch more time than an opening
	if _defence == "block":
		_light_target("left", true, true)
		_light_target("right", true, true)
	else:
		_light_target(_incoming_side, true, true)
	_hud.set_prompt(String(DEFENCE_CALLS[_defence]), BoxingHud.DANGER,
			String(DEFENCE_HINTS[_defence]))
	_hud.flash_toast("INCOMING!", BoxingHud.WARN)


## Which defence the player is holding right now: "block" for both gloves up over
## the face, "left"/"right" for a committed waist lean, "" for neither. Any of
## them answers an incoming shot — only matching the call slips it clean.
func _defence_held() -> String:
	var lean: float = MotionManager.get_lean()
	var leaning: String = ""
	if lean <= -DODGE_LEAN:
		leaning = "left"
	elif lean >= DODGE_LEAN:
		leaning = "right"
	# A lean that matches the call wins over the guard: plenty of players slip
	# with their hands still up, and that should read as the slip it is.
	if leaning != "" and leaning == _defence:
		return leaning
	if MotionManager.is_guarding():
		return "block"
	return leaning


## The player answered the shot. [param clean] is whether it was the called
## answer: a clean read takes nothing and scores, and the wrong-but-real defence
## still takes most of the sting out.
func _defended(clean: bool) -> void:
	_clear_calls()
	_opp.punch(_incoming_side, "straight" if _defence == "block" else "hook")
	if clean:
		_combo += 1
		add_score(90 + (_combo - 1) * 20)
		_hud.set_combo(_combo)
		_hud.flash_toast("SLIPPED IT!" if _defence != "block" else "BLOCKED!",
				BoxingHud.SAFE)
		_arena.cheer_burst(0.45)
	else:
		# A partial: they defended, just not the way it was called.
		_take_damage(_counter_damage * 0.35)
		add_score(35)
		_hud.flash_toast("TOOK IT WELL", BoxingHud.WARN)
	_hud.set_score(get_score())
	if _phase == Phase.BOUT:
		_after_resolve(0.3)


## The window closed with no defence at all. AUTO-GUARD spends itself to cover the
## shot if it has charge; otherwise the player wears it.
func _shot_arrives() -> void:
	_clear_calls()
	_opp.punch(_incoming_side, "hook")
	if _assist >= 1.0:
		_assist = 0.0
		_hud.set_assist(_assist)
		_assist_block_left = ASSIST_BLOCK_HOLD
		_you.set_blocking(true)
		_take_damage(_counter_damage * ASSIST_BLOCK_FACTOR)
		_hud.flash_toast("CORNER COVERED YOU", BoxingHud.WARN)
		_hud.flash(BoxingHud.WARN, 0.18)
	else:
		_combo = 0
		_hud.set_combo(0)
		_you.take_hit()
		_take_damage(_counter_damage)
		_hud.flash_toast("TAGGED!", BoxingHud.DANGER)
		_hud.flash(BoxingHud.DANGER, 0.4)
		_cam_impact(0.2, FOV_KICK_TAG)
		_impact_burst(_you.global_position + Vector3(0.0, 1.5, -0.35),
				Color(1.0, 0.35, 0.3))
	if _phase == Phase.BOUT:
		_after_resolve(0.45)


## Applies damage to the player and calls the knockdown if it empties them.
func _take_damage(amount: float) -> void:
	_you_health = maxf(0.0, _you_health - amount)
	_hud.set_health(_you_health, _opp_health)
	if _you_health <= 0.0:
		_lose_by_ko()


## The free-hit window: the opponent's guard falls apart and everything lands for
## a few seconds. It's the fun beat and the calorie beat at once — throw as many
## punches as you physically can.
func _begin_flurry() -> void:
	_ex = Ex.FLURRY
	_ex_left = 3.4
	_light_target("left", true)
	_light_target("right", true)
	_light_target("chin", true)
	_hud.set_prompt("FREE HITS!", BoxingHud.SAFE, "throw everything you've got")
	_hud.flash_toast("HE'S OPEN!", BoxingHud.ACCENT)
	_arena.set_crowd_energy(0.85)


func _flurry_hit(power: float) -> void:
	_opp.take_hit()
	var dmg: float = (HIT_DAMAGE + HIT_DAMAGE_POWER * clampf(power, 0.0, 1.0)) \
			* FLURRY_DAMAGE
	_opp_health = maxf(0.0, _opp_health - dmg)
	_hud.set_health(_you_health, _opp_health)
	_combo += 1
	add_score(FLURRY_SCORE + (_combo - 1) * 10)
	_hud.set_combo(_combo)
	_hud.set_score(get_score())
	_hud.flash(BoxingHud.GOLD_FLASH, 0.14)
	_cam_impact(0.08 + power * 0.04, FOV_KICK_HIT * 0.5)
	_impact_burst(_opp.global_position + Vector3(0.0, 1.5, 0.35),
			Color(1.0, 0.85, 0.35))
	_arena.cheer_burst(0.35)
	if _opp_health <= 0.0:
		_win_by_ko()


func _flurry_over() -> void:
	_clear_calls()
	_hud.flash_toast("HE'S BACK UP", BoxingHud.MUTED)
	_after_resolve(0.4)


func _after_resolve(wait: float) -> void:
	_ex = Ex.WAIT
	_ex_left = wait + randf_range(_wait_min, _wait_max)
	_hud.set_prompt("")


func _clear_calls() -> void:
	for spot in ["left", "right", "chin"]:
		_light_target(spot, false)
	_call_hand = ""
	_call_kind = ""
	_defence = ""
	_incoming_side = ""


# --- End states --------------------------------------------------------------

func _win_by_ko() -> void:
	_clear_calls()   # a flurry can end the bout with its targets still lit
	_opp.knock_out()
	add_score(KO_BONUS)
	_hud.set_score(get_score())
	_hud.set_prompt("")
	_hud.flash_toast("KNOCKOUT!", BoxingHud.ACCENT)
	_arena.set_crowd_energy(1.0)
	_arena.cheer_burst(1.0)
	_ko_slowmo()
	_hud.show_result("WINNER", "BY KNOCKOUT · +%d" % KO_BONUS, get_score(),
			BoxingHud.SAFE, _workout_line())
	_over(2.0)


func _lose_by_ko() -> void:
	_clear_calls()
	_you.knock_out()
	_hud.set_prompt("")
	_hud.flash_toast("DOWN!", BoxingHud.DANGER)
	_ko_slowmo()
	_hud.show_result("TKO", "YOU WENT DOWN — GOOD WORK REGARDLESS", get_score(),
			BoxingHud.DANGER, _workout_line())
	_over(2.0)


## Time up: judge it on who has more health left.
func _finish_on_time() -> void:
	_clear_calls()
	_hud.set_prompt("")
	_arena.set_crowd_energy(0.9)
	_arena.cheer_burst(0.8)
	if _you_health >= _opp_health:
		add_score(200)
		_hud.set_score(get_score())
		_hud.show_result("WINNER", "BY DECISION · +200", get_score(),
				BoxingHud.SAFE, _workout_line())
	else:
		_hud.show_result("DECISION LOSS", "OUT-BOXED THIS TIME", get_score(),
				BoxingHud.WARN, _workout_line())
	_over(GLIDE_SEC)


func _over(hold: float) -> void:
	_phase = Phase.OVER
	_phase_left = hold


## The line that matters on every result card, win or lose: what the round
## actually cost the player.
func _workout_line() -> String:
	return "%d KCAL · %d PUNCHES THROWN" % [
		int(round(MotionManager.get_session_calories())), _punches_thrown]


# --- Impact feel -------------------------------------------------------------

## Freezes the world for a beat so a clean punch lands with weight.
func _hit_stop() -> void:
	_slow_time(HITSTOP_SCALE, HITSTOP_SEC, 0.12)


## The knockout drops into slow motion and eases back out — the one moment in the
## bout worth stretching.
func _ko_slowmo() -> void:
	_slow_time(KO_SLOWMO_SCALE, KO_SLOWMO_SEC, 0.5)


## Drops the time scale to [param scale] for [param hold] seconds, then eases it
## back to normal over [param recover]. Only ever one of these runs: the KO
## fires on the same frame as the punch that caused it, and the hit-stop's
## recovery would otherwise cut the knockout's slow motion short. The tween
## ignores the time scale it is itself changing, so it always restores.
func _slow_time(scale: float, hold: float, recover: float) -> void:
	if _time_tween != null and _time_tween.is_valid():
		_time_tween.kill()
	Engine.time_scale = scale
	_time_tween = create_tween().set_ignore_time_scale(true)
	_time_tween.tween_interval(hold)
	_time_tween.tween_property(Engine, "time_scale", 1.0, recover)


## A single reused flash rig — an omni light plus a glowing sphere — parked at
## whichever glove just connected. Pooled rather than spawned so a flurry of
## punches can't churn nodes mid-round.
func _build_impact() -> void:
	_impact = Node3D.new()
	_impact.name = "Impact"
	_impact.visible = false
	add_child(_impact)

	_impact_light = OmniLight3D.new()
	_impact_light.omni_range = 3.2
	_impact_light.light_energy = 0.0
	_impact.add_child(_impact_light)

	var mi := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.26
	mesh.height = 0.52
	_impact_mat = StandardMaterial3D.new()
	_impact_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_impact_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_impact_mat.emission_enabled = true
	_impact_mat.emission_energy_multiplier = 4.0
	_impact_mat.albedo_color = Color(1, 1, 1, 0)
	mesh.material = _impact_mat
	mi.mesh = mesh
	_impact.add_child(mi)


## Pops the flash at [param at] in [param color] and fades it out.
func _impact_burst(at: Vector3, color: Color) -> void:
	if _impact == null:
		return
	_impact.global_position = at
	_impact.visible = true
	_impact.scale = Vector3.ONE * 0.6
	_impact_light.light_color = color
	_impact_light.light_energy = 4.5
	_impact_mat.emission = color
	_impact_mat.albedo_color = Color(color, 0.9)
	var tween := create_tween().set_parallel(true)
	tween.tween_property(_impact, "scale", Vector3.ONE * 1.9, 0.22) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(_impact_light, "light_energy", 0.0, 0.22)
	tween.tween_property(_impact_mat, "albedo_color", Color(color, 0.0), 0.22)
	tween.chain().tween_callback(func() -> void: _impact.visible = false)


# --- 3D target markers -------------------------------------------------------

## Emissive markers on the opponent: one at each shoulder (the side a straight or
## a hook goes to) and one under the chin (where an uppercut comes up). The lit
## one shows where the called shot is going; red instead of gold means it's a
## punch coming the other way.
func _build_targets() -> void:
	var spots := {
		"left": Vector3(-0.62, 0.95, 0.35),
		"right": Vector3(0.62, 0.95, 0.35),
		"chin": Vector3(0.0, 0.55, 0.45),
	}
	for spot in spots:
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
		mi.position = OPP_POS + spots[spot]
		mi.visible = false
		add_child(mi)
		_targets[spot] = mi
		_target_mat[spot] = mat


## [param warning] lights the marker red (an INCOMING tell to defend) instead of
## the gold "throw here" opening cue.
func _light_target(spot: String, on: bool, warning: bool = false) -> void:
	var mi: MeshInstance3D = _targets.get(spot)
	if mi == null:
		return
	mi.visible = on
	var mat: StandardMaterial3D = _target_mat[spot]
	mat.emission_energy_multiplier = 3.5 if on else 0.0
	mat.emission = Color(0.95, 0.16, 0.16) if warning else Color(1.0, 0.85, 0.2)


# --- Footwork + camera rig ---------------------------------------------------

## Ease the boxer's footwork toward the player's live motion: leaning at the
## waist slips him side to side, marching presses him forward. When the player
## isn't leaning, an autonomous drift keeps him moving on his own — nobody should
## have to hold a pose to stop their boxer looking like a mannequin. Outside the
## bout it recentres for the result.
func _update_movement(delta: float) -> void:
	_auto_clock += delta
	var target_slip: float = 0.0
	var target_adv: float = 0.0
	var lean: float = 0.0
	if _phase == Phase.BOUT:
		lean = clampf(MotionManager.get_lean(), -1.0, 1.0)
		target_adv = clampf(MotionManager.get_forward(), 0.0, 1.0)
		# The boxer's own idle drift, faded out by however much the player is
		# actually leaning, so a real slip always wins over the automation.
		var auto: float = sin(_auto_clock * TAU * AUTO_SWAY_HZ) * AUTO_SWAY
		target_slip = lean * SLIP_MAX + auto * (1.0 - absf(lean))
	_slip += (target_slip - _slip) * clampf(delta * CAM_SMOOTH, 0.0, 1.0)
	_advance += (target_adv - _advance) * clampf(delta * CAM_SMOOTH * 0.5, 0.0, 1.0)
	if _you != null:
		_you.position.x = YOU_POS.x + _slip
		_you.position.z = YOU_POS.z - _advance * 0.8
		# The lean itself is a pose, not just a position: pass it through so the
		# figure bends at the waist exactly as far as the player did.
		_you.set_lean(lean)


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

## Difficulty is mostly about how much time you get and how much the assist
## carries you — not about demanding better boxing. EASY is a long window and an
## AUTO-GUARD that is almost always ready; HARD asks you to actually defend.
func _apply_difficulty() -> void:
	match get_difficulty():
		GameManager.Difficulty.EASY:
			_round_left = 75.0
			_window = 2.1
			_wait_min = 0.9
			_wait_max = 2.0
			_counter_damage = 0.06
			_flurry_chance = 0.2
			_assist_recharge = 0.16
		GameManager.Difficulty.HARD:
			_round_left = 100.0
			_window = 1.15
			_wait_min = 0.5
			_wait_max = 1.3
			_counter_damage = 0.13
			_flurry_chance = 0.08
			_assist_recharge = 0.045
		_:
			_round_left = 90.0
			_window = 1.6
			_wait_min = 0.7
			_wait_max = 1.7
			_counter_damage = 0.09
			_flurry_chance = 0.14
			_assist_recharge = 0.09


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
