extends GameHUD
## BoxingHud
##
## Boxing's on-screen feedback. It owns no game state — boxing.gd feeds it live
## numbers every frame.
##
## Blocks it owns (the bout-specific half — the palette, chip, flash, toast and
## briefing shell come from [GameHUD]):
##   - bottom corners: two health bars (YOU left, the OPPONENT right),
##   - top-centre chip: the round clock + score,
##   - centre: the big punch call ("LEFT!", "RIGHT!") and the combo tally,
##   - the workout readout, the auto-guard meter and the result card.
class_name BoxingHud

## Full-screen slam colour on a landed hit (a warm gold), vs DANGER when tagged.
const GOLD_FLASH: Color = Color(1.0, 0.82, 0.25)

## Health-bar geometry (design space is a fixed 1920×1080).
const BAR_W: float = 620.0
const BAR_H: float = 26.0

var _you_fill: Panel
var _opp_fill: Panel
var _clock: Label
var _score_value: Label
var _prompt: Label
var _prompt_text: String = ""
var _combo: Label
var _prompt_sub: Label
var _result_card: Control
var _kcal: Label
var _punches: Label
var _assist_fill: Panel
var _assist_label: Label


func _ready() -> void:
	super()
	layer = 10
	_build_flash()
	_build_health_bars()
	_build_clock()
	_build_prompt()
	_build_combo()
	_build_toast(58, 0.9)
	_position_toast()
	_build_workout()
	_build_assist()


# --- Health bars -------------------------------------------------------------

func _build_health_bars() -> void:
	# Pinned to the bottom of the screen so the right-hand bar clears the top-right
	# in-game camera window (GameCameraHUD's corner mirror) instead of overlapping it.
	var y: float = 1080.0 - 40.0 - BAR_H - 28.0
	_you_fill = _build_bar(Vector2(40, y), "YOU", SAFE, false)
	_opp_fill = _build_bar(Vector2(1920 - 40 - BAR_W, y), "OPPONENT", DANGER, true)


## One captioned bar. [param align_right] fills the bar from the right edge so the
## opponent's health drains inward, a versus-screen read. Returns the fill Panel.
func _build_bar(pos: Vector2, caption: String, color: Color,
		align_right: bool) -> Panel:
	var box := VBoxContainer.new()
	box.position = pos
	box.add_theme_constant_override("separation", 4)
	add_child(box)

	var cap := Label.new()
	cap.text = caption
	cap.add_theme_font_override("font", _anton)
	cap.add_theme_font_size_override("font_size", 22)
	cap.add_theme_color_override("font_color", TEXT)
	if align_right:
		cap.custom_minimum_size = Vector2(BAR_W, 0)
		cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	box.add_child(cap)

	var track := Panel.new()
	track.custom_minimum_size = Vector2(BAR_W, BAR_H)
	var track_sb := StyleBoxFlat.new()
	track_sb.bg_color = Color(0.02, 0.03, 0.05, 0.8)
	track_sb.border_color = PANEL_BORDER
	track_sb.set_border_width_all(2)
	track_sb.set_corner_radius_all(6)
	track.add_theme_stylebox_override("panel", track_sb)
	box.add_child(track)

	var fill := Panel.new()
	var fill_sb := StyleBoxFlat.new()
	fill_sb.bg_color = color
	fill_sb.set_corner_radius_all(5)
	fill.add_theme_stylebox_override("panel", fill_sb)
	fill.size = Vector2(BAR_W - 4, BAR_H - 4)
	fill.position = Vector2(2, 2)
	fill.set_meta("align_right", align_right)
	track.add_child(fill)
	return fill


func set_health(you01: float, opp01: float) -> void:
	_set_fill(_you_fill, you01)
	_set_fill(_opp_fill, opp01)


func _set_fill(fill: Panel, frac: float) -> void:
	var w: float = (BAR_W - 4) * clampf(frac, 0.0, 1.0)
	fill.size.x = w
	fill.position.x = (BAR_W - 2 - w) if bool(fill.get_meta("align_right")) else 2.0


# --- Clock + score -----------------------------------------------------------

func _build_clock() -> void:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", chip())
	panel.position = Vector2(960 - 120, 30)
	panel.custom_minimum_size = Vector2(240, 0)
	add_child(panel)
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 0)
	panel.add_child(box)

	_clock = Label.new()
	_clock.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_clock.add_theme_font_override("font", _anton)
	_clock.add_theme_font_size_override("font_size", 44)
	_clock.add_theme_color_override("font_color", TEXT)
	_clock.text = "0:00"
	box.add_child(_clock)

	_score_value = Label.new()
	_score_value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_score_value.add_theme_font_size_override("font_size", 16)
	_score_value.add_theme_color_override("font_color", MUTED)
	_score_value.text = "SCORE 0"
	box.add_child(_score_value)


func set_clock(seconds_left: float) -> void:
	var s: int = int(ceil(maxf(seconds_left, 0.0)))
	_clock.text = "%d:%02d" % [s / 60, s % 60]
	_clock.add_theme_color_override("font_color", DANGER if s <= 10 else TEXT)


func set_score(score: int) -> void:
	_score_value.text = "SCORE %d" % score


# --- Centre prompt + combo ---------------------------------------------------

func _build_prompt() -> void:
	_prompt = Label.new()
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# Low, over the empty canvas: at eye level the call sits on the opponent's
	# face, which is exactly where the player needs to be looking.
	_prompt.position = Vector2(560, 596)
	_prompt.size = Vector2(800, 120)
	_prompt.add_theme_font_override("font", _anton)
	_prompt.add_theme_font_size_override("font_size", 96)
	_prompt.add_theme_constant_override("outline_size", 10)
	_prompt.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	add_child(_prompt)

	# A plain-language line under the call, so a player who has never boxed knows
	# what the shot actually is ("swing it wide", "cover up") without guessing.
	_prompt_sub = Label.new()
	_prompt_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt_sub.position = Vector2(460, 700)
	_prompt_sub.size = Vector2(1000, 44)
	_prompt_sub.add_theme_font_size_override("font_size", 28)
	_prompt_sub.add_theme_constant_override("outline_size", 6)
	_prompt_sub.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_prompt_sub.add_theme_color_override("font_color", TEXT)
	add_child(_prompt_sub)


## The big call ("LEFT HOOK", "BLOCK!") with [param sub] spelling out how to
## throw or slip it — a scale-pop when it changes.
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


func _build_combo() -> void:
	_combo = Label.new()
	_combo.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_combo.position = Vector2(560, 776)
	_combo.size = Vector2(800, 60)
	_combo.add_theme_font_override("font", _anton)
	_combo.add_theme_font_size_override("font_size", 40)
	_combo.add_theme_color_override("font_color", ACCENT)
	_combo.add_theme_constant_override("outline_size", 6)
	_combo.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_combo.modulate.a = 0.0
	add_child(_combo)


func set_combo(count: int) -> void:
	if count < 2:
		_combo.modulate.a = 0.0
		return
	_combo.text = "%d HIT COMBO" % count
	_combo.modulate.a = 1.0
	pop(_combo, 1.3, 0.18)


# --- Workout readout ---------------------------------------------------------

## The live fitness read, top-left under the clock: calories burned this bout and
## punches thrown. It's the reason the game exists, so it stays on screen the
## whole round rather than only turning up on the results card.
func _build_workout() -> void:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", chip())
	panel.position = Vector2(40, 30)
	add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	panel.add_child(box)

	_kcal = Label.new()
	_kcal.add_theme_font_override("font", _anton)
	_kcal.add_theme_font_size_override("font_size", 38)
	_kcal.add_theme_color_override("font_color", ACCENT)
	_kcal.text = "0 KCAL"
	box.add_child(_kcal)

	_punches = Label.new()
	_punches.add_theme_font_size_override("font_size", 16)
	_punches.add_theme_color_override("font_color", MUTED)
	_punches.text = "0 PUNCHES"
	box.add_child(_punches)


## [param kcal] is the live session burn and [param punches] every punch thrown,
## landed or not — swinging counts toward the workout even when the timing missed.
func set_workout(kcal: float, punches: int) -> void:
	_kcal.text = "%d KCAL" % int(round(maxf(kcal, 0.0)))
	_punches.text = "%d PUNCH%s" % [punches, "" if punches == 1 else "ES"]


# --- Auto-guard meter --------------------------------------------------------

## The assist meter above the player's health bar. It fills on its own and spends
## itself to auto-block a shot the player didn't answer, so a missed read costs a
## sliver of health instead of the round — the difference between a game anyone
## can play and one only a boxer enjoys.
func _build_assist() -> void:
	var box := VBoxContainer.new()
	box.position = Vector2(40, 1080.0 - 40.0 - BAR_H - 28.0 - 46.0)
	box.add_theme_constant_override("separation", 2)
	add_child(box)

	_assist_label = Label.new()
	_assist_label.text = "AUTO-GUARD"
	_assist_label.add_theme_font_size_override("font_size", 14)
	_assist_label.add_theme_color_override("font_color", MUTED)
	box.add_child(_assist_label)

	var track := Panel.new()
	track.custom_minimum_size = Vector2(BAR_W * 0.5, 8)
	var track_sb := StyleBoxFlat.new()
	track_sb.bg_color = Color(0.02, 0.03, 0.05, 0.8)
	track_sb.set_corner_radius_all(4)
	track.add_theme_stylebox_override("panel", track_sb)
	box.add_child(track)

	_assist_fill = Panel.new()
	var fill_sb := StyleBoxFlat.new()
	fill_sb.bg_color = ACCENT
	fill_sb.set_corner_radius_all(4)
	_assist_fill.add_theme_stylebox_override("panel", fill_sb)
	_assist_fill.size = Vector2(0, 8)
	track.add_child(_assist_fill)


## [param charge] 0..1 — full means the next unanswered shot is auto-blocked.
func set_assist(charge: float) -> void:
	var frac: float = clampf(charge, 0.0, 1.0)
	_assist_fill.size.x = BAR_W * 0.5 * frac
	var ready: bool = frac >= 1.0
	_assist_label.text = "AUTO-GUARD READY" if ready else "AUTO-GUARD"
	_assist_label.add_theme_color_override("font_color", ACCENT if ready else MUTED)


# --- Toast -------------------------------------------------------------------

## The bout's shouts (HIT, COUNTERED, KO) sit high, clear of the round clock.
func _position_toast() -> void:
	_toast.position = Vector2(560, 150)
	_toast.size = Vector2(800, 80)


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

## The bout result card (WINNER BY KO / result), shown as the game winds down.
## [param workout] is the fitness line under the score (calories, punches) — the
## takeaway that matters most, so it sits on the card whatever the result was.
func show_result(headline: String, detail: String, score: int,
		color: Color, workout: String = "") -> void:
	var centre := CenterContainer.new()
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(centre)
	_result_card = centre

	var panel := PanelContainer.new()
	var sb := chip(10, 60.0, 34.0, 34.0)
	sb.bg_color = Color(0.05, 0.07, 0.11, 0.92)
	panel.add_theme_stylebox_override("panel", sb)
	centre.add_child(panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)

	var head := Label.new()
	head.text = headline
	head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	head.add_theme_font_override("font", _anton)
	head.add_theme_font_size_override("font_size", 88)
	head.add_theme_color_override("font_color", color)
	box.add_child(head)

	var det := Label.new()
	det.text = detail
	det.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	det.add_theme_font_size_override("font_size", 22)
	det.add_theme_color_override("font_color", MUTED)
	box.add_child(det)

	var score_lbl := Label.new()
	score_lbl.text = "SCORE %d" % score
	score_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	score_lbl.add_theme_font_override("font", _anton)
	score_lbl.add_theme_font_size_override("font_size", 40)
	score_lbl.add_theme_color_override("font_color", TEXT)
	box.add_child(score_lbl)

	if workout != "":
		var work := Label.new()
		work.text = workout
		work.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		work.add_theme_font_size_override("font_size", 22)
		work.add_theme_color_override("font_color", ACCENT)
		box.add_child(work)

	pop(panel, 1.15, 0.25)
