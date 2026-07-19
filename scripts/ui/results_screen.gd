extends Control
## ResultsScreen
##
## The post-game workout summary. Every mini-game reports the same result schema
## (see [MiniGame.finish] / GameManager.finish_game), so this one screen serves
## all 20+ games: it lays out the game outcome (score, any new record) alongside
## the fitness the motion pipeline measured for free (calories, steps, pace, heart
## rate) and the progression earned (XP, level-ups), then offers Play Again /
## Game Select / Main Menu.
##
## Built entirely in code (like [GameIntro]) so the layout can adapt to what was
## actually measured — the heart-rate cards only appear when a wearable streamed —
## and stays consistent with the platform's look without a hand-maintained scene.

const ACCENT: Color = Color(1.0, 0.5, 0.14)
const GOLD: Color = Color(1.0, 0.79, 0.28)
const HEART: Color = Color(1.0, 0.42, 0.42)
const TEXT: Color = Color(0.96, 0.97, 0.99)
const MUTED: Color = Color(0.62, 0.67, 0.75)
const CARD_BG: Color = Color(0.08, 0.10, 0.15, 0.92)
const CARD_BORDER: Color = Color(1, 1, 1, 0.08)
const BG_TOP: Color = Color(0.05, 0.07, 0.11)
const BG_BOTTOM: Color = Color(0.02, 0.03, 0.05)

var _anton: Font
var _theme: Theme
var _first_button: Button

func _ready() -> void:
	_anton = load("res://assets/fonts/Anton-Regular.ttf")
	_theme = load("res://assets/ui/main_theme.tres")
	theme = _theme
	_build(GameManager.get_last_result())


func _build(result: Dictionary) -> void:
	_build_background()

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 120)
	margin.add_theme_constant_override("margin_right", 120)
	margin.add_theme_constant_override("margin_top", 44)
	margin.add_theme_constant_override("margin_bottom", 44)
	add_child(margin)

	var column := VBoxContainer.new()
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override("separation", 26)
	margin.add_child(column)

	if result.is_empty():
		# Reached without a finished game behind it (e.g. straight from a menu):
		# show a friendly placeholder instead of a misleading "workout complete".
		_build_empty_state(column)
		_build_buttons(column, true)
	else:
		_build_header(column, result)
		_build_stat_grid(column, result)
		_build_unlocks(column)
		_build_progression(column, result)
		_build_next_goal(column)
		_build_buttons(column, false)

	if _first_button != null:
		_first_button.grab_focus()


## Placeholder shown when there's no result to summarise: a large muted glyph, a
## headline and one line telling the player what will fill this screen — on-brand
## and pointing at the game library, never a blank or a false celebration.
func _build_empty_state(parent: VBoxContainer) -> void:
	var card := VBoxContainer.new()
	card.alignment = BoxContainer.ALIGNMENT_CENTER
	card.add_theme_constant_override("separation", 14)
	parent.add_child(card)

	var glyph := _label("◎", 96, ACCENT)
	glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	card.add_child(glyph)

	var title := _label("NO WORKOUT YET", 56, TEXT)
	title.add_theme_font_override("font", _anton)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	card.add_child(title)

	var body := _label(
		"Play any game and your summary — calories, steps, XP and new records — lands here.",
		24, MUTED)
	body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.custom_minimum_size = Vector2(720, 0)
	card.add_child(body)


## A vertical dark gradient so the card stats read cleanly against it.
func _build_background() -> void:
	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = BG_BOTTOM
	add_child(bg)
	var grad := Gradient.new()
	grad.set_color(0, BG_TOP)
	grad.set_color(1, BG_BOTTOM)
	var tex := GradientTexture2D.new()
	tex.gradient = grad
	tex.fill_from = Vector2(0, 0)
	tex.fill_to = Vector2(0, 1)
	var rect := TextureRect.new()
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rect.texture = tex
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(rect)


func _build_header(parent: VBoxContainer, result: Dictionary) -> void:
	var header := VBoxContainer.new()
	header.alignment = BoxContainer.ALIGNMENT_CENTER
	header.add_theme_constant_override("separation", 4)
	parent.add_child(header)

	# A completed Daily Challenge gets its own gold kicker; every other session is
	# the standard "workout complete".
	var challenge_done: bool = bool(result.get("workout_completed", false))
	var kicker_text: String = "★  DAILY CHALLENGE COMPLETE" if challenge_done else "WORKOUT COMPLETE"
	var kicker := _label(kicker_text, 22, GOLD if challenge_done else ACCENT)
	kicker.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.add_child(kicker)

	var game_id: String = String(result.get("game_id", GameManager.get_current_game_id()))
	var game: Dictionary = GameManager.get_game(game_id)
	var title_text: String = String(game.get("title", "Results")).to_upper()
	var title := _label(title_text, 72, TEXT)
	title.add_theme_font_override("font", _anton)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.add_child(title)

	# A celebratory "NEW BEST" badge only when this run beat the stored record
	# (and it's not just the first-ever play with a zero baseline).
	if bool(result.get("new_best", false)) and int(result.get("score", 0)) > 0 \
			and int(result.get("prev_best", 0)) > 0:
		var badge := _pill_badge("★  NEW PERSONAL BEST", GOLD)
		badge.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		header.add_child(badge)

	if not result.is_empty():
		var cheer := _label(_encouragement(result), 22, Color(0.85, 0.88, 0.94))
		cheer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		header.add_child(cheer)


## One warm line under the title, picked from what actually happened — a completed
## challenge, a level up, a record, the daily goal, the streak — falling back to
## honest praise for simply moving. Addressed to the player by name so Results
## reads as personal. Every workout ends on encouragement, never on a bare number.
func _encouragement(result: Dictionary) -> String:
	var who: String = _first_name()
	if bool(result.get("workout_completed", false)):
		return "That's today's challenge done, %s. Same time tomorrow?" % who
	if bool(result.get("leveled_up", false)):
		return "You're getting stronger, %s — that session pushed you up a level." % who
	if bool(result.get("new_best", false)) and int(result.get("prev_best", 0)) > 0:
		return "Your best ever, %s. That version of you didn't exist last week." % who
	var goal: float = ActivityManager.get_daily_calorie_goal()
	if ActivityManager.get_today_calories() >= goal:
		return "That's your daily goal done, %s. Your future self says thanks." % who
	var streak: int = ActivityManager.get_streak()
	if streak >= 2:
		return "Day %d in a row, %s — showing up is the whole game, and you keep showing up." % [streak, who]
	var lines: Array[String] = [
		"Every one of those steps was real movement. Well done, %s." % who,
		"Good work, %s — that burn was earned, not tapped on a screen." % who,
		"Nice session, %s. Come back tomorrow and it becomes a streak." % who,
	]
	return lines[ActivityManager.get_total_sessions() % lines.size()]


## The player's first name for a natural, personal address ("Well done, Ali"). The
## profile stores a display name (collected at onboarding); we take the first word
## so a full name doesn't read stiffly mid-sentence.
func _first_name() -> String:
	var name: String = ProfileManager.get_display_name().strip_edges()
	if name.is_empty():
		return "champ"
	return name.split(" ")[0]


## Gold pills for achievements earned since the last summary (this session's
## unlocks, plus any find from a session that never reached Results). Capped so
## a big day doesn't push the buttons off-screen.
func _build_unlocks(parent: VBoxContainer) -> void:
	var unlocks: Array[Dictionary] = AchievementManager.take_recent_unlocks()
	if unlocks.is_empty():
		return
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 14)
	parent.add_child(row)
	var shown: int = mini(unlocks.size(), 3)
	for i in shown:
		row.add_child(_pill_badge("%s  %s" % [String(unlocks[i]["icon"]),
				String(unlocks[i]["title"])], GOLD))
	if unlocks.size() > shown:
		row.add_child(_label("+%d more" % (unlocks.size() - shown), 20, MUTED))


## A quiet "here's what to chase next" line — the nearest locked career
## achievement with live progress, so leaving the screen always hands the
## player a next purpose.
func _build_next_goal(parent: VBoxContainer) -> void:
	var goal: Dictionary = AchievementManager.get_next_goal()
	if goal.is_empty():
		return
	var defn: Dictionary = goal["defn"]
	var text: String = "NEXT GOAL — %s · %d / %d %s" % [String(defn["title"]),
			int(goal["value"]), int(goal["target"]), String(defn["unit"])]
	var line := _label(text, 18, MUTED)
	line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	line.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	parent.add_child(line)


func _build_stat_grid(parent: VBoxContainer, result: Dictionary) -> void:
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 22)
	grid.add_theme_constant_override("v_separation", 22)
	grid.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	parent.add_child(grid)

	var score: int = int(result.get("score", 0))
	var prev_best: int = int(result.get("prev_best", 0))
	var best_sub := ""
	if bool(result.get("new_best", false)) and prev_best > 0:
		best_sub = "Prev best  %d" % prev_best
	elif prev_best > 0:
		best_sub = "Best  %d" % prev_best
	grid.add_child(_stat_card("SCORE", str(score), ACCENT, best_sub))

	grid.add_child(_stat_card("TIME", _format_duration(float(result.get("duration_sec", 0.0))), TEXT))
	grid.add_child(_stat_card("CALORIES", "%.0f" % float(result.get("calories", 0.0)), ACCENT, "kcal"))

	grid.add_child(_stat_card("STEPS", str(int(result.get("steps", 0))), TEXT))

	var cadence: float = float(result.get("avg_cadence", 0.0))
	grid.add_child(_stat_card("AVG PACE", "%.0f" % cadence, TEXT, "steps / min"))

	var xp: int = int(result.get("xp_earned", 0))
	grid.add_child(_stat_card("XP EARNED", "+%d" % xp, GOLD))

	# Heart-rate cards only when a wearable actually streamed a rate this session.
	if float(result.get("peak_heart_rate", 0.0)) > 0.0:
		grid.add_child(_stat_card("AVG HR", "%.0f" % float(result.get("avg_heart_rate", 0.0)), HEART, "bpm"))
		grid.add_child(_stat_card("PEAK HR", "%.0f" % float(result.get("peak_heart_rate", 0.0)), HEART, "bpm"))


## A slim progression line under the cards: total XP and the current level, with a
## level-up call-out when this game pushed the player over the threshold.
func _build_progression(parent: VBoxContainer, result: Dictionary) -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 28)
	parent.add_child(row)

	var level_after: int = int(result.get("level_after", ProfileManager.get_level()))
	if bool(result.get("leveled_up", false)):
		var up := _pill_badge("▲  LEVEL UP — LEVEL %d" % level_after, GOLD)
		row.add_child(up)
	else:
		row.add_child(_label("LEVEL %d" % level_after, 20, MUTED))

	row.add_child(_label("•", 20, MUTED))
	row.add_child(_label("%d XP total" % int(result.get("total_xp", ProfileManager.get_xp())), 20, MUTED))


func _build_buttons(parent: VBoxContainer, empty: bool = false) -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 20)
	parent.add_child(row)

	# With no result there's nothing to replay — send the player to the library.
	if empty:
		_first_button = _make_button("CHOOSE A GAME", true, _on_select_pressed)
		row.add_child(_first_button)
		row.add_child(_make_button("MAIN MENU", false, _on_menu_pressed))
		return

	_first_button = _make_button("PLAY AGAIN", true, _on_play_again_pressed)
	row.add_child(_first_button)
	row.add_child(_make_button("GAME SELECT", false, _on_select_pressed))
	row.add_child(_make_button("MAIN MENU", false, _on_menu_pressed))


# --- widget builders ---------------------------------------------------------

## One stat card: a big value over a small caps label, with an optional sub-line.
func _stat_card(label_text: String, value_text: String, value_color: Color, sub: String = "") -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(300, 150)
	var sb := StyleBoxFlat.new()
	sb.bg_color = CARD_BG
	sb.set_corner_radius_all(16)
	sb.set_border_width_all(1)
	sb.border_color = CARD_BORDER
	sb.content_margin_left = 26
	sb.content_margin_right = 26
	sb.content_margin_top = 22
	sb.content_margin_bottom = 22
	panel.add_theme_stylebox_override("panel", sb)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 2)
	panel.add_child(vbox)

	var value := _label(value_text, 66, value_color)
	value.add_theme_font_override("font", _anton)
	value.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(value)

	var caption := _label(label_text, 20, MUTED)
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(caption)

	if not sub.is_empty():
		var sub_label := _label(sub, 15, MUTED)
		sub_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		vbox.add_child(sub_label)

	return panel


func _pill_badge(text: String, color: Color) -> Control:
	var pill := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(color.r, color.g, color.b, 0.16)
	sb.set_corner_radius_all(999)
	sb.set_border_width_all(1)
	sb.border_color = Color(color.r, color.g, color.b, 0.6)
	sb.content_margin_left = 20
	sb.content_margin_right = 20
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	pill.add_theme_stylebox_override("panel", sb)
	var lbl := _label(text, 22, color)
	pill.add_child(lbl)
	return pill


func _make_button(text: String, primary: bool, handler: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(280, 60)
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.add_theme_font_size_override("font_size", 22)

	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(12)
	sb.content_margin_top = 14
	sb.content_margin_bottom = 14
	if primary:
		sb.bg_color = ACCENT
		button.add_theme_color_override("font_color", Color(0.06, 0.04, 0.02))
		button.add_theme_color_override("font_focus_color", Color(0.06, 0.04, 0.02))
		button.add_theme_color_override("font_hover_color", Color(0.06, 0.04, 0.02))
	else:
		sb.bg_color = Color(0.12, 0.15, 0.21, 0.9)
		sb.set_border_width_all(1)
		sb.border_color = Color(1, 1, 1, 0.14)
		button.add_theme_color_override("font_color", TEXT)

	var hover := sb.duplicate()
	if primary:
		hover.bg_color = ACCENT.lightened(0.12)
	else:
		hover.bg_color = Color(0.18, 0.22, 0.30, 0.98)
		hover.border_color = ACCENT
	var focus := hover.duplicate()

	button.add_theme_stylebox_override("normal", sb)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", hover)
	button.add_theme_stylebox_override("focus", focus)
	button.pressed.connect(handler)
	return button


func _label(text: String, size: int, color: Color) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", size)
	lbl.add_theme_color_override("font_color", color)
	return lbl


## Formats seconds as m:ss for a real workout duration, or "12.3s" under a minute.
func _format_duration(seconds: float) -> String:
	if seconds < 60.0:
		return "%.1fs" % seconds
	var total := int(round(seconds))
	return "%d:%02d" % [total / 60, total % 60]


func _on_play_again_pressed() -> void:
	GameManager.start_selected_game()


func _on_select_pressed() -> void:
	SceneManager.load_game_select()


func _on_menu_pressed() -> void:
	SceneManager.load_main_menu()
