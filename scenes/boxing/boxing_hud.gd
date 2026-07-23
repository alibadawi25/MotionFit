extends GameHUD
## BoxingHud
##
## Boxing's on-screen feedback. It owns no game state — boxing.gd feeds it live
## numbers every frame.
##
## The layout is authored in boxing_hud.tscn (see CONTEXT.md §4.1); this script
## only fills the widgets in. Instance the scene, never [code]new()[/code] the
## class — the script alone has no nodes.
##
## Blocks it owns (the bout-specific half — the palette, chip, flash, toast and
## briefing shell come from [GameHUD]):
##   - bottom corners: two health bars (YOU left, the OPPONENT right),
##   - top-centre chip: the round clock + score,
##   - centre: the big punch call ("LEFT!", "RIGHT!") and the combo tally,
##   - top-left: the live workout readout, and the auto-guard meter above YOU,
##   - the result card, authored hidden and revealed by [method show_result].
class_name BoxingHud

## Full-screen slam colour on a landed hit (a warm gold), vs DANGER when tagged.
const GOLD_FLASH: Color = Color(1.0, 0.82, 0.25)

## Health-bar geometry. The fills are positioned by hand inside their tracks
## (a bar that drains isn't a container job), so the script needs the numbers the
## scene was authored with.
const BAR_W: float = 620.0
const BAR_H: float = 26.0
const ASSIST_W: float = BAR_W * 0.5

@onready var _you_fill: Panel = %YouFill
@onready var _opp_fill: Panel = %OppFill
@onready var _clock: Label = %Clock
@onready var _score_value: Label = %ScoreValue
@onready var _prompt: Label = %Prompt
@onready var _prompt_sub: Label = %PromptSub
@onready var _combo: Label = %Combo
@onready var _kcal: Label = %KcalValue
@onready var _punches: Label = %PunchesValue
@onready var _assist_fill: Panel = %AssistFill
@onready var _assist_label: Label = %AssistLabel
@onready var _result_card: CenterContainer = %ResultCard
@onready var _result_panel: PanelContainer = %Card
@onready var _result_headline: Label = %Headline
@onready var _result_detail: Label = %Detail
@onready var _result_score: Label = %ScoreLine
@onready var _result_workout: Label = %WorkoutLine

var _prompt_text: String = ""


func _ready() -> void:
	super()
	# The bout's shouts hold a beat before fading; %Toast is authored in the
	# scene, so the base adopts it rather than building one.
	_toast_hold = 0.9


# --- Health bars -------------------------------------------------------------

func set_health(you01: float, opp01: float) -> void:
	_set_fill(_you_fill, you01, false)
	_set_fill(_opp_fill, opp01, true)


## [param align_right] drains the bar inward from the right edge, so the
## opponent's health reads as a versus screen rather than a second player bar.
func _set_fill(fill: Panel, frac: float, align_right: bool) -> void:
	var w: float = (BAR_W - 4) * clampf(frac, 0.0, 1.0)
	fill.size.x = w
	fill.position.x = (BAR_W - 2 - w) if align_right else 2.0


# --- Clock + score -----------------------------------------------------------

func set_clock(seconds_left: float) -> void:
	var s: int = int(ceil(maxf(seconds_left, 0.0)))
	_clock.text = "%d:%02d" % [s / 60, s % 60]
	_clock.add_theme_color_override("font_color", DANGER if s <= 10 else TEXT)


func set_score(score: int) -> void:
	_score_value.text = "SCORE %d" % score


# --- Centre prompt + combo ---------------------------------------------------

## The big call ("LEFT HOOK", "BLOCK!") with [param sub] spelling out how to
## throw or slip it — a scale-pop when it changes. The sub-line exists so a
## player who has never boxed knows what the shot actually is without guessing.
func set_prompt(text: String, color: Color = TEXT, sub: String = "") -> void:
	if text == _prompt_text:
		return
	_prompt_text = text
	_prompt.text = text
	_prompt.add_theme_color_override("font_color", color)
	_prompt_sub.text = sub
	_prompt_sub.add_theme_color_override("font_color", Color(color, 0.85))
	if text == "":
		return
	pop(_prompt, 1.25, 0.16)


func set_combo(count: int) -> void:
	if count < 2:
		_combo.modulate.a = 0.0
		return
	_combo.text = "%d HIT COMBO" % count
	_combo.modulate.a = 1.0
	pop(_combo, 1.3, 0.18)


# --- Workout readout ---------------------------------------------------------

## [param kcal] is the live session burn and [param punches] every punch thrown,
## landed or not — swinging counts toward the workout even when the timing missed.
## It's the reason the game exists, so it stays on screen the whole round rather
## than only turning up on the results card.
func set_workout(kcal: float, punches: int) -> void:
	_kcal.text = "%d KCAL" % int(round(maxf(kcal, 0.0)))
	_punches.text = "%d PUNCH%s" % [punches, "" if punches == 1 else "ES"]


# --- Auto-guard meter --------------------------------------------------------

## [param charge] 0..1 — full means the next unanswered shot is auto-blocked. The
## meter fills on its own and spends itself so a missed read costs a sliver of
## health instead of the round: the difference between a game anyone can play and
## one only a boxer enjoys.
func set_assist(charge: float) -> void:
	var frac: float = clampf(charge, 0.0, 1.0)
	_assist_fill.size.x = ASSIST_W * frac
	var ready: bool = frac >= 1.0
	_assist_label.text = "AUTO-GUARD READY" if ready else "AUTO-GUARD"
	_assist_label.add_theme_color_override("font_color", ACCENT if ready else MUTED)


# --- Briefing ----------------------------------------------------------------

## The pre-bout how-to card, revealed while the ringside frame settles. Two
## blocks, because the whole design is "three punches, two defences": each one
## spelled out in body language, not boxing jargon.
func show_briefing() -> HudBriefing:
	var card := super()
	card.set_header("TITLE FIGHT",
			"THREE PUNCHES, TWO WAYS TO DEFEND — THAT'S THE WHOLE GAME")
	card.add_section("PUNCH  (either hand — any punch lands)")
	card.add_line("STRAIGHT — punch forward, straight at them", TEXT, true)
	card.add_line("WIDE — swing your arm around in a wide arc", TEXT, true)
	card.add_line("UPPERCUT — drive your fist up from below", TEXT, true)
	card.add_section("DEFEND  (when the call turns red)")
	card.add_line("BLOCK — both hands up, covering your face", TEXT, true)
	card.add_line("LEAN — bend at the waist, left or right, to slip the shot",
			TEXT, true)
	card.add_note("Miss one and your corner covers for you — just keep moving.")
	return card


func set_briefing_countdown(seconds_left: float) -> void:
	if _briefing != null:
		_briefing.set_countdown("FIRST BELL IN %d"
				% int(ceil(maxf(seconds_left, 0.0))))


# --- Result ------------------------------------------------------------------

## Reveals the bout result card (WINNER BY KO / decision) as the game winds down.
## [param workout] is the fitness line under the score (calories, punches) — the
## takeaway that matters most, so it sits on the card whatever the result was.
func show_result(headline: String, detail: String, score: int,
		color: Color, workout: String = "") -> void:
	_result_headline.text = headline
	_result_headline.add_theme_color_override("font_color", color)
	_result_detail.text = detail
	_result_score.text = "SCORE %d" % score
	_result_workout.text = workout
	_result_workout.visible = workout != ""
	_result_card.visible = true
	pop(_result_panel, 1.15, 0.25)
