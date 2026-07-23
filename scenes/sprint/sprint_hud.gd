extends GameHUD
## SprintHud
##
## Hurdle Dash's on-screen feedback. It owns no game state — sprint.gd feeds it
## live numbers every frame.
##
## Unlike the zombie run (whose whole design is NOT telling you where the
## threat is), a race wants its standings legible at a glance, so this HUD is
## information-forward: a live race strip of every runner's progress to the
## line, your placing, and metres to go.
##
## The layout is authored in sprint_hud.tscn (see CONTEXT.md §4.1); this script
## only fills the widgets in. Instance the scene, never [code]new()[/code] the
## class — the script alone has no nodes. The one thing still built in code is
## the strip's dots, because there is genuinely one per runner.
##
## Blocks it owns (the race-specific half — the palette, chip, flash, toast and
## briefing shell come from [GameHUD]):
##   - top-left chip: your PLACE + metres to go + pace bar,
##   - top-centre strip: all four runners as dots racing toward the flag,
##   - bottom-centre: the big coaching prompt ("JUMP!", "FINAL STRETCH!"),
##   - the start calls (MARKS/SET/GO) and the finish card.
class_name SprintHud

const GOLD: Color = Color(0.98, 0.82, 0.25)
const SILVER: Color = Color(0.8, 0.83, 0.88)
const BRONZE: Color = Color(0.78, 0.5, 0.28)

## Race strip geometry, matching the scene: the dots are placed by hand along the
## track (a field spread across a course isn't a container job), so the script
## needs the numbers sprint_hud.tscn was authored with.
const STRIP_W: float = 620.0
const DOT: float = 16.0
## The pace bar's full width, from its PaceTrack minimum size.
const PACE_W: float = 150.0

@onready var _place_value: Label = %PlaceValue
@onready var _to_go: Label = %ToGo
@onready var _pace_fill: Panel = %PaceFill
@onready var _strip_track: Control = %StripTrack
@onready var _prompt: Label = %Prompt
@onready var _start_call: Label = %StartCall
@onready var _finish_card: CenterContainer = %FinishCard
@onready var _finish_panel: PanelContainer = %Card
@onready var _finish_place: Label = %PlaceLine
@onready var _finish_score: Label = %ScoreLine

var _prompt_text: String = ""
var _dots: Array[Panel] = []


func _ready() -> void:
	super()
	# A race can afford a longer read on its shouts than a chase can.
	_toast_hold = 1.1


## The place-th suffix, sports-caption style ("1ST", "2ND"...).
static func ordinal(place: int) -> String:
	match place:
		1: return "1ST"
		2: return "2ND"
		3: return "3RD"
		_: return "%dTH" % place


static func medal_color(place: int) -> Color:
	match place:
		1: return GOLD
		2: return SILVER
		3: return BRONZE
		_: return MUTED


# --- The field strip ---------------------------------------------------------

## Registers the runners the strip shows. [param colors] holds one jersey
## colour per runner; the player's dot (at [param player_index]) is drawn
## bigger, in the app accent, with a white ring.
func setup_strip(colors: Array[Color], player_index: int) -> void:
	for dot in _dots:
		dot.queue_free()
	_dots.clear()
	for i in colors.size():
		var is_you: bool = i == player_index
		var d: float = DOT + (6.0 if is_you else 0.0)
		var dot := Panel.new()
		var sb := StyleBoxFlat.new()
		sb.bg_color = ACCENT if is_you else colors[i]
		sb.set_corner_radius_all(int(d * 0.5))
		if is_you:
			sb.set_border_width_all(2)
			sb.border_color = TEXT
		dot.add_theme_stylebox_override("panel", sb)
		dot.size = Vector2(d, d)
		dot.position = Vector2(0, 12 - d * 0.5)
		dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_strip_track.add_child(dot)
		_dots.append(dot)


## Slides each runner's dot to its course fraction (0 start … 1 line).
func set_strip(fracs: Array[float]) -> void:
	var span: float = STRIP_W - 52.0
	for i in mini(fracs.size(), _dots.size()):
		var d: float = _dots[i].size.x
		_dots[i].position.x = clampf(fracs[i], 0.0, 1.0) * span - d * 0.5 + 4.0


# --- Placing + pace ----------------------------------------------------------

func set_race(place: int, total: int, to_go_m: float, pace01: float) -> void:
	_place_value.text = ordinal(place)
	_place_value.add_theme_color_override("font_color",
			medal_color(place) if place <= 3 else TEXT)
	_to_go.text = "%d M TO GO  ·  OF %d" % [int(ceil(maxf(to_go_m, 0.0))), total]
	_pace_fill.size.x = PACE_W * clampf(pace01, 0.0, 1.0)


# --- Prompt + start calls ----------------------------------------------------

func set_prompt(text: String, color: Color = TEXT) -> void:
	if text == _prompt_text:
		return
	_prompt_text = text
	_prompt.text = text
	_prompt.add_theme_color_override("font_color", color)
	pop(_prompt, 1.12, 0.16)


## A red slam when a hurdle is clipped.
func flash_hit() -> void:
	flash(Color(0.8, 0.05, 0.05), 0.4, 0.45)


## The starter's calls: big centred text that pops in ("ON YOUR MARKS", "SET",
## "GO!"). Stays up until the next call or [method hide_start_call].
func show_start_call(text: String, color: Color = TEXT) -> void:
	_start_call.text = text
	_start_call.add_theme_color_override("font_color", color)
	_start_call.visible = true
	pop(_start_call, 1.3, 0.2)


func hide_start_call() -> void:
	_start_call.visible = false


# --- Briefing ----------------------------------------------------------------

## The pre-race how-to card: the shared shell from [GameHUD], filled with the
## three things that win a hurdle race.
func show_briefing() -> HudBriefing:
	var card := super()
	card.set_header("HURDLE DASH", "BEAT THREE RIVALS TO THE LINE")
	card.add_line("SPRINT — march on the spot; faster legs, faster feet")
	card.add_line("JUMP — leap as each hurdle reaches you")
	card.add_line("CLIPPED HURDLES COST METRES — time it, don't spam it")
	return card


func set_briefing_countdown(seconds_left: float) -> void:
	if _briefing != null:
		_briefing.set_countdown("WARM UP — RACE IN %d"
				% int(ceil(maxf(seconds_left, 0.0))))


# --- Finish ------------------------------------------------------------------

## Reveals the result card while the finish glide plays: placing in its medal
## colour plus the banked score. sprint.gd calls finish() shortly after.
func show_finish(place: int, score: int) -> void:
	_finish_place.text = "%s PLACE" % ordinal(place)
	_finish_place.add_theme_color_override("font_color", medal_color(place))
	_finish_score.text = "SCORE %d" % score
	_finish_card.visible = true
	pop(_finish_panel, 1.15, 0.25)
