extends GameHUD
## SprintHud
##
## Hurdle Dash's on-screen feedback, built in code on the shared app look
## (translucent slate chips, Anton values, orange accent) like RunnerHud. It
## owns no game state — sprint.gd feeds it live numbers every frame.
##
## Unlike the zombie run (whose whole design is NOT telling you where the
## threat is), a race wants its standings legible at a glance, so this HUD is
## information-forward: a live race strip of every runner's progress to the
## line, your placing, and metres to go.
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

## Race strip geometry (design space is a fixed 1920×1080).
const STRIP_W: float = 620.0
const STRIP_H: float = 64.0
const DOT: float = 16.0

var _place_value: Label
var _to_go: Label
var _pace_fill: Panel
var _prompt: Label
var _prompt_text: String = ""
var _start_call: Label
var _strip_track: Control
var _dots: Array[Panel] = []
var _finish_card: Control


func _ready() -> void:
	super()
	layer = 10
	_build_flash()
	_build_stats()
	_build_strip()
	_build_prompt()
	_build_toast(54, 1.1)
	_position_toast()
	_build_start_call()


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


# --- Build -------------------------------------------------------------------

func _build_stats() -> void:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", chip())
	panel.position = Vector2(40, 36)
	add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	panel.add_child(box)

	var cap := Label.new()
	cap.text = "PLACE"
	cap.add_theme_font_size_override("font_size", 14)
	cap.add_theme_color_override("font_color", MUTED)
	box.add_child(cap)

	_place_value = Label.new()
	_place_value.text = "—"
	_place_value.add_theme_font_override("font", _anton)
	_place_value.add_theme_font_size_override("font_size", 52)
	_place_value.add_theme_color_override("font_color", TEXT)
	box.add_child(_place_value)

	_to_go = Label.new()
	_to_go.text = ""
	_to_go.add_theme_font_size_override("font_size", 16)
	_to_go.add_theme_color_override("font_color", MUTED)
	box.add_child(_to_go)

	var pace_cap := Label.new()
	pace_cap.text = "PACE"
	pace_cap.add_theme_font_size_override("font_size", 12)
	pace_cap.add_theme_color_override("font_color", MUTED)
	box.add_child(pace_cap)

	var track := Panel.new()
	track.custom_minimum_size = Vector2(150, 8)
	var track_sb := StyleBoxFlat.new()
	track_sb.bg_color = Color(1, 1, 1, 0.10)
	track_sb.set_corner_radius_all(4)
	track.add_theme_stylebox_override("panel", track_sb)
	box.add_child(track)
	_pace_fill = Panel.new()
	var fill_sb := StyleBoxFlat.new()
	fill_sb.bg_color = ACCENT
	fill_sb.set_corner_radius_all(4)
	_pace_fill.add_theme_stylebox_override("panel", fill_sb)
	_pace_fill.position = Vector2.ZERO
	_pace_fill.size = Vector2(0, 8)
	track.add_child(_pace_fill)


func _build_strip() -> void:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", chip())
	panel.position = Vector2(960 - STRIP_W * 0.5 - 18, 30)
	add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	panel.add_child(box)

	var cap := Label.new()
	cap.text = "THE FIELD"
	cap.add_theme_font_size_override("font_size", 13)
	cap.add_theme_color_override("font_color", MUTED)
	box.add_child(cap)

	_strip_track = Control.new()
	_strip_track.custom_minimum_size = Vector2(STRIP_W, 24)
	box.add_child(_strip_track)
	# The course line the dots travel, with a finish tick at the right end.
	var line := Panel.new()
	var line_sb := StyleBoxFlat.new()
	line_sb.bg_color = Color(1, 1, 1, 0.14)
	line_sb.set_corner_radius_all(2)
	line.add_theme_stylebox_override("panel", line_sb)
	line.position = Vector2(0, 10)
	line.size = Vector2(STRIP_W - 44, 4)
	_strip_track.add_child(line)
	var fin := Label.new()
	fin.text = "FINISH"
	fin.add_theme_font_size_override("font_size", 12)
	fin.add_theme_color_override("font_color", MUTED)
	fin.position = Vector2(STRIP_W - 42, 4)
	_strip_track.add_child(fin)


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
		_strip_track.add_child(dot)
		_dots.append(dot)


## Slides each runner's dot to its course fraction (0 start … 1 line).
func set_strip(fracs: Array[float]) -> void:
	var span: float = STRIP_W - 52.0
	for i in mini(fracs.size(), _dots.size()):
		var d: float = _dots[i].size.x
		_dots[i].position.x = clampf(fracs[i], 0.0, 1.0) * span - d * 0.5 + 4.0


func set_race(place: int, total: int, to_go_m: float, pace01: float) -> void:
	_place_value.text = ordinal(place)
	_place_value.add_theme_color_override("font_color",
			medal_color(place) if place <= 3 else TEXT)
	_to_go.text = "%d M TO GO  ·  OF %d" % [int(ceil(maxf(to_go_m, 0.0))), total]
	_pace_fill.size.x = 150.0 * clampf(pace01, 0.0, 1.0)


func _build_prompt() -> void:
	var band := PanelContainer.new()
	var sb := chip()
	sb.bg_color = Color(0.03, 0.04, 0.07, 0.55)
	band.add_theme_stylebox_override("panel", sb)
	# NB absolute design-space coords (1920×1080 canvas_items stretch) with the
	# default zero anchors — anchor presets would shift these positions again.
	band.position = Vector2(760, 950)
	band.custom_minimum_size = Vector2(400, 0)
	add_child(band)
	_prompt = Label.new()
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt.add_theme_font_override("font", _anton)
	_prompt.add_theme_font_size_override("font_size", 44)
	_prompt.add_theme_color_override("font_color", TEXT)
	_prompt.add_theme_constant_override("outline_size", 6)
	_prompt.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	band.add_child(_prompt)


func set_prompt(text: String, color: Color = TEXT) -> void:
	if text == _prompt_text:
		return
	_prompt_text = text
	_prompt.text = text
	_prompt.add_theme_color_override("font_color", color)
	pop(_prompt, 1.12, 0.16)


## The race's shouts sit just under the field strip, clear of it.
func _position_toast() -> void:
	_toast.position = Vector2(560, 170)
	_toast.size = Vector2(800, 80)


## A red slam when a hurdle is clipped.
func flash_hit() -> void:
	flash(Color(0.8, 0.05, 0.05), 0.4, 0.45)


func _build_start_call() -> void:
	_start_call = Label.new()
	_start_call.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_start_call.position = Vector2(460, 380)
	_start_call.size = Vector2(1000, 200)
	_start_call.add_theme_font_override("font", _anton)
	_start_call.add_theme_font_size_override("font_size", 120)
	_start_call.add_theme_constant_override("outline_size", 12)
	_start_call.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_start_call.visible = false
	add_child(_start_call)


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

## The result card shown while the finish glide plays: placing in its medal
## colour plus the banked score. sprint.gd calls finish() shortly after.
func show_finish(place: int, score: int) -> void:
	var centre := CenterContainer.new()
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(centre)
	_finish_card = centre

	var panel := PanelContainer.new()
	var sb := chip(10, 60.0, 34.0, 34.0)
	sb.bg_color = Color(0.05, 0.07, 0.11, 0.92)
	panel.add_theme_stylebox_override("panel", sb)
	centre.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)

	var head := Label.new()
	head.text = "FINISH!"
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	head.add_theme_font_override("font", _anton)
	head.add_theme_font_size_override("font_size", 48)
	head.add_theme_color_override("font_color", TEXT)
	box.add_child(head)

	var place_lbl := Label.new()
	place_lbl.text = "%s PLACE" % ordinal(place)
	place_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	place_lbl.add_theme_font_override("font", _anton)
	place_lbl.add_theme_font_size_override("font_size", 84)
	place_lbl.add_theme_color_override("font_color", medal_color(place))
	box.add_child(place_lbl)

	var score_lbl := Label.new()
	score_lbl.text = "SCORE %d" % score
	score_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	score_lbl.add_theme_font_size_override("font_size", 22)
	score_lbl.add_theme_color_override("font_color", MUTED)
	box.add_child(score_lbl)

	pop(panel, 1.15, 0.25)
