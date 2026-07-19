extends Control
## MainMenu
##
## Entry screen, kept deliberately short: a single prominent PLAY, then FITNESS,
## SETTINGS, QUIT. Play -> Game Select, Settings -> Settings, Quit -> exit.
## (Open World is now a game in the registry, so it's launched from Game Select
## like every other game.)
##
## The player's profile lives in the top-left card, not the button column: the
## greeting is clickable (-> Profile) with a small "Switch profile" link beneath
## it, which keeps two more items out of the main list. Camera testing moved into
## Settings. All navigation goes through SceneManager; this script never names a
## path.

@onready var _play_button: Button = %PlayButton
@onready var _settings_button: Button = %SettingsButton
@onready var _quit_button: Button = %QuitButton
## The hero photo, oversized past the viewport so it can drift a few pixels under
## the pointer without ever exposing an edge (see [method _update_parallax]).
@onready var _background: TextureRect = $Background

## Godot weekday index (0=Sunday .. 6=Saturday) → single-letter label, for the
## right panel's 7-day calorie chart.
const WEEKDAY_INITIALS: Array[String] = ["S", "M", "T", "W", "T", "F", "S"]
## How far the background drifts from centre toward the screen edges, in pixels.
const PARALLAX: Vector2 = Vector2(22.0, 13.0)
## Width of the right-hand "today" panel, and its inset from the right screen edge.
const PANEL_WIDTH: float = 544.0
const PANEL_MARGIN: float = 96.0

## Anton display font, loaded once for the right panel's big numbers so they match
## Results / Fitness.
var _anton: Font
## The top-left profile card and the right-hand "today" panel holder, kept so the
## entrance animation can bring them in (the card slides, the panel fades).
var _profile_card: Control
var _today_panel: Control
## Parallax rest position (the centred background offset) and a guard so [method
## _process] only drives it once layout has settled.
var _bg_base: Vector2
var _parallax_ready: bool = false

## A small camera-service status line, built in code (like the menu's extra
## buttons) and polled from [MotionManager] in [method _process].
var _cam_status: Label
## Heart-rate strap status line just above the camera one. Hidden unless a
## wearable is actually streaming bpm — most players have none, and an "absent"
## row would just be noise.
var _hr_status: Label

func _ready() -> void:
	# Boot gate, in order:
	#   1. No profiles at all -> first-run onboarding creates the first one.
	#   2. Haven't picked "who's playing" this launch -> show the profile picker.
	#   3. The chosen profile isn't onboarded yet -> finish its setup.
	# Each redirect returns here once satisfied, so the menu only builds for a
	# selected, onboarded profile.
	if not ProfileManager.has_profiles():
		SceneManager.load_profile_setup.call_deferred()
		return
	if not SceneManager.profile_chosen_this_session:
		SceneManager.load_profile_picker.call_deferred()
		return
	if not ProfileManager.is_onboarded():
		SceneManager.load_profile_setup.call_deferred()
		return

	_anton = load("res://assets/fonts/Anton-Regular.ttf")
	_play_button.pressed.connect(_on_play_pressed)
	_settings_button.pressed.connect(_on_settings_pressed)
	_quit_button.pressed.connect(_on_quit_pressed)
	# Real monochrome icons (assets/ui/icons) turn the text-only column into a
	# scannable icon menu — tinted to track each button's label colour, one
	# consistent size, and free of the font-fallback emoji that Unicode glyphs
	# rendered as. PLAY carries a dark icon on its orange fill; the rest are light.
	_set_button_icon(_play_button, "play", true)
	_set_button_icon(_settings_button, "gear")
	_set_button_icon(_quit_button, "power")
	# Today's Daily Challenge sits at the very top of the column — the session's
	# reason to return, above even PLAY.
	_build_challenge_card()
	# Extra buttons inserted below PLAY (above Settings), in call order. Profile
	# and Switch Profile live in the top-left card; Test Camera moved into
	# Settings.
	_add_menu_button("FITNESS", SceneManager.load_fitness, "heart")
	_add_menu_button("ACHIEVEMENTS", SceneManager.load_achievements, "trophy")
	_build_profile_card()
	_build_today_panel()
	_build_camera_status()
	_animate_entrance()


## Top-left profile card: a clickable "Hi, <name> · Level N" greeting that opens
## the profile, with a small "Switch profile" link beneath it. Doubling as the
## profile/switch entry points keeps those two items out of the button column
## (and makes whose profile is active read as a tappable identity, not a label).
func _build_profile_card() -> void:
	var card := VBoxContainer.new()
	card.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	card.offset_left = 52.0
	card.offset_top = 40.0
	card.add_theme_constant_override("separation", 8)

	# The greeting is a real, obviously-tappable chip (rounded translucent
	# background, orange edge, trailing chevron) — not a flat label — so it
	# reads as the profile entry point at a glance.
	var greeting := Button.new()
	greeting.alignment = HORIZONTAL_ALIGNMENT_LEFT
	greeting.tooltip_text = "View your profile"
	greeting.custom_minimum_size = Vector2(300, 0)
	greeting.text = "Hi, %s   ·   Level %d      ›" % [
		ProfileManager.get_display_name(), ProfileManager.get_level()]
	greeting.add_theme_font_size_override("font_size", 22)
	greeting.add_theme_color_override("font_color", Color(0.92, 0.94, 0.98))
	greeting.add_theme_color_override("font_hover_color", Color(1, 1, 1))
	greeting.add_theme_color_override("font_pressed_color", Color(0.11, 0.06, 0.02))
	greeting.add_theme_stylebox_override(
		"normal", _chip_style(Color(0.10, 0.12, 0.17, 0.62), Color(1, 0.5, 0.14, 0.45)))
	greeting.add_theme_stylebox_override(
		"hover", _chip_style(Color(0.15, 0.18, 0.26, 0.88), Color(1, 0.5, 0.14, 0.95), true))
	greeting.add_theme_stylebox_override(
		"pressed", _chip_style(Color(1, 0.5, 0.14, 0.92), Color(1, 0.62, 0.24, 1)))
	greeting.add_theme_stylebox_override(
		"focus", _chip_style(Color(0.13, 0.16, 0.23, 0.7), Color(1, 1, 1, 0.9)))
	greeting.pressed.connect(SceneManager.load_profile)
	card.add_child(greeting)

	# Secondary, quieter action styled as a text link with a small leading icon so
	# it still reads as tappable.
	var switch_link := Button.new()
	switch_link.flat = true
	switch_link.alignment = HORIZONTAL_ALIGNMENT_LEFT
	switch_link.text = "Switch profile"
	switch_link.icon = load("res://assets/ui/icons/swap.svg")
	switch_link.expand_icon = false
	switch_link.add_theme_constant_override("icon_max_width", 18)
	switch_link.add_theme_constant_override("h_separation", 8)
	switch_link.add_theme_font_size_override("font_size", 16)
	switch_link.add_theme_color_override("font_color", Color(1, 0.64, 0.3, 0.9))
	switch_link.add_theme_color_override("font_hover_color", Color(1, 0.78, 0.45))
	switch_link.add_theme_color_override("icon_normal_color", Color(1, 0.64, 0.3, 0.9))
	switch_link.add_theme_color_override("icon_hover_color", Color(1, 0.78, 0.45))
	switch_link.pressed.connect(SceneManager.load_profile_picker)
	card.add_child(switch_link)

	# Streak / today's calories deliberately live only in the right-hand "Today at a
	# glance" panel now — repeating them here made the top-left stack fight the
	# wordmark for the same corner.
	add_child(card)
	_profile_card = card


## Today's Daily Challenge as a prominent, tappable card at the top of the column
## (see WorkoutManager): the prescribed game + interval structure, its length, and
## whether it's still pending or already done today. Tapping it launches the
## challenge. Skipped only if no eligible game is available to host it.
func _build_challenge_card() -> void:
	var plan: Dictionary = WorkoutManager.get_today_plan()
	if plan.is_empty():
		return
	var done: bool = WorkoutManager.is_today_complete()
	var game_title: String = String(GameManager.get_game(String(plan["game_id"])).get("title", ""))
	var minutes: int = int(round(float(plan["total_sec"]) / 60.0))

	var card := Button.new()
	card.custom_minimum_size = Vector2(360, 96)
	card.clip_contents = false
	card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var accent := Color(1, 0.5, 0.14)
	var edge := Color(0.4, 0.85, 0.5, 0.7) if done else Color(1, 0.5, 0.14, 0.85)
	card.add_theme_stylebox_override("normal",
		_card_style(Color(0.10, 0.12, 0.17, 0.7), edge, false))
	card.add_theme_stylebox_override("hover",
		_card_style(Color(0.15, 0.18, 0.26, 0.92), edge, true))
	card.add_theme_stylebox_override("focus",
		_card_style(Color(0.15, 0.18, 0.26, 0.92), edge, true))
	card.add_theme_stylebox_override("pressed",
		_card_style(Color(0.14, 0.17, 0.24, 0.98), edge, false))

	var pad := MarginContainer.new()
	pad.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pad.add_theme_constant_override("margin_left", 20)
	pad.add_theme_constant_override("margin_right", 20)
	pad.add_theme_constant_override("margin_top", 14)
	pad.add_theme_constant_override("margin_bottom", 14)
	card.add_child(pad)

	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 3)
	pad.add_child(box)

	var kicker := Label.new()
	kicker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	kicker.add_theme_font_size_override("font_size", 14)
	if done:
		kicker.text = "✓  TODAY'S CHALLENGE — DONE"
		kicker.add_theme_color_override("font_color", Color(0.5, 0.9, 0.55))
	else:
		kicker.text = "★  TODAY'S CHALLENGE"
		kicker.add_theme_color_override("font_color", accent)
	box.add_child(kicker)

	var title := Label.new()
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title.text = "%s   ·   %s" % [game_title, String(plan.get("title", ""))]
	title.add_theme_font_size_override("font_size", 21)
	title.add_theme_color_override("font_color", Color(0.95, 0.97, 1.0))
	box.add_child(title)

	var detail := Label.new()
	detail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	detail.add_theme_font_size_override("font_size", 14)
	detail.add_theme_color_override("font_color", Color(0.78, 0.82, 0.88, 0.9))
	var detail_text: String = "~%d min   ·   %d pushes" % [minutes, int(plan["push_count"])]
	var streak: int = WorkoutManager.get_challenge_streak()
	if streak > 0:
		detail_text += "   ·   ▲ %d-day challenge streak" % streak
	elif done:
		detail_text += "   ·   come back tomorrow to start a streak"
	detail.text = detail_text
	box.add_child(detail)

	card.pressed.connect(GameManager.start_daily_challenge)

	var column := _play_button.get_parent()
	column.add_child(card)
	column.move_child(card, _play_button.get_index())


## A rounded translucent card StyleBox for the challenge card, with an accent (or
## green, when done) edge and an optional soft glow for the hover/focus states.
func _card_style(bg: Color, border: Color, glow: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.set_corner_radius_all(14)
	style.set_border_width_all(1)
	style.border_color = border
	if glow:
		style.shadow_color = Color(border.r, border.g, border.b, 0.3)
		style.shadow_size = 12
	return style


## Builds a rounded, translucent chip StyleBox for the tappable profile greeting.
## [param glow] adds a soft orange shadow for the hover state.
func _chip_style(bg: Color, border: Color, glow: bool = false) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.set_corner_radius_all(14)
	style.set_border_width_all(1)
	style.border_color = border
	style.content_margin_left = 20.0
	style.content_margin_right = 22.0
	style.content_margin_top = 13.0
	style.content_margin_bottom = 13.0
	if glow:
		style.shadow_color = Color(1, 0.5, 0.14, 0.35)
		style.shadow_size = 12
	return style


## Bottom-right status line telling the player whether the pose service is up
## (the camera is intentionally off in menus and turns on when a game starts),
## and calling out a camera-access problem so it can be fixed before playing.
func _build_camera_status() -> void:
	_cam_status = Label.new()
	_cam_status.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_cam_status.offset_left = -760.0
	_cam_status.offset_top = -74.0
	_cam_status.offset_right = -114.0
	_cam_status.offset_bottom = -44.0
	_cam_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_cam_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_cam_status.add_theme_font_size_override("font_size", 18)
	add_child(_cam_status)

	_hr_status = Label.new()
	_hr_status.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_hr_status.offset_left = -760.0
	_hr_status.offset_top = -104.0
	_hr_status.offset_right = -114.0
	_hr_status.offset_bottom = -74.0
	_hr_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_hr_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_hr_status.add_theme_font_size_override("font_size", 18)
	_hr_status.add_theme_color_override("font_color", Color(0.95, 0.45, 0.5, 0.92))
	_hr_status.visible = false
	add_child(_hr_status)


## The right-hand "today" dashboard. The hero shot left the right ~55% of the
## screen empty; this fills it with the platform's purpose made personal — today's
## calories against the daily goal, the streak, the week's burn, level progress and
## a 7-day calorie chart — so the menu opens on a snapshot of the player's own
## movement, not dead photo. Read-only: every figure comes from ActivityManager /
## ProfileManager / AchievementManager.
func _build_today_panel() -> void:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _today_panel_style())

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 16)
	panel.add_child(box)

	var kicker := Label.new()
	kicker.text = "TODAY AT A GLANCE"
	kicker.add_theme_font_size_override("font_size", 18)
	kicker.add_theme_color_override("font_color", Color(1, 0.64, 0.3))
	box.add_child(kicker)

	# Calories against the daily goal — the panel's headline, gold once it's met.
	var today: int = int(ActivityManager.get_today_calories())
	var goal: int = maxi(1, int(ActivityManager.get_daily_calorie_goal()))
	var met: bool = today >= goal
	var cal_color: Color = Color(1, 0.79, 0.28) if met else Color(1, 0.5, 0.14)

	var cal_row := HBoxContainer.new()
	cal_row.add_theme_constant_override("separation", 8)
	box.add_child(cal_row)
	var cal_value := Label.new()
	cal_value.text = str(today)
	cal_value.add_theme_font_override("font", _anton)
	cal_value.add_theme_font_size_override("font_size", 60)
	cal_value.add_theme_color_override("font_color", cal_color)
	cal_row.add_child(cal_value)
	var cal_goal := Label.new()
	cal_goal.text = "/ %d kcal" % goal
	cal_goal.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	cal_goal.add_theme_font_size_override("font_size", 20)
	cal_goal.add_theme_color_override("font_color", Color(0.7, 0.74, 0.8))
	cal_row.add_child(cal_goal)

	box.add_child(_make_bar(float(today) / float(goal), cal_color))

	# Three compact tiles: streak, this week's burn, badges unlocked.
	var tiles := HBoxContainer.new()
	tiles.add_theme_constant_override("separation", 16)
	box.add_child(tiles)
	tiles.add_child(_mini_tile("STREAK", str(ActivityManager.get_streak()), "days"))
	tiles.add_child(_mini_tile("THIS WEEK",
		"%d" % int(ActivityManager.get_calories_last_days(7)), "kcal"))
	tiles.add_child(_mini_tile("BADGES", "%d / %d" % [
		AchievementManager.get_unlocked_count(),
		AchievementManager.get_definitions().size()]))

	box.add_child(_thin_rule())

	# Level progress — how far into the current level the player's total XP sits.
	var level: int = ProfileManager.get_level()
	var xp: int = ProfileManager.get_xp()
	var base: int = ProfileManager.BASE_XP_PER_LEVEL
	var floor_xp: int = base * (level - 1) * level / 2
	var span: int = base * level
	var into: int = clampi(xp - floor_xp, 0, span)

	var level_row := HBoxContainer.new()
	level_row.add_theme_constant_override("separation", 8)
	box.add_child(level_row)
	var level_label := Label.new()
	level_label.text = "LEVEL %d" % level
	level_label.add_theme_font_size_override("font_size", 20)
	level_label.add_theme_color_override("font_color", Color(1, 0.64, 0.3))
	level_row.add_child(level_label)
	var to_next := Label.new()
	to_next.text = "→   %d XP to level %d" % [span - into, level + 1]
	to_next.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	to_next.add_theme_font_size_override("font_size", 15)
	to_next.add_theme_color_override("font_color", Color(0.7, 0.74, 0.8))
	level_row.add_child(to_next)

	box.add_child(_make_bar(float(into) / float(span), Color(1, 0.64, 0.3), 10))

	box.add_child(_thin_rule())

	# A compact 7-day calorie chart, the same widget the Fitness screen uses.
	var chart_caption := Label.new()
	chart_caption.text = "CALORIES · LAST 7 DAYS"
	chart_caption.add_theme_font_size_override("font_size", 13)
	chart_caption.add_theme_color_override("font_color", Color(0.7, 0.74, 0.8))
	box.add_child(chart_caption)

	var chart := BarChart.new()
	chart.custom_minimum_size = Vector2(0, 104)
	var labels := PackedStringArray()
	var values := PackedFloat32Array()
	for day in ActivityManager.get_recent_days(7):
		labels.append(WEEKDAY_INITIALS[int(day["weekday"])])
		values.append(float(day["calories"]))
	chart.set_series(labels, values, float(goal))
	box.add_child(chart)

	# First run: nothing logged yet — one encouraging line instead of a wall of
	# zeroes (matches the platform's always-encourage tone).
	if ActivityManager.get_total_sessions() == 0:
		var nudge := Label.new()
		nudge.text = "Play your first game to light this up."
		nudge.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		nudge.add_theme_font_size_override("font_size", 15)
		nudge.add_theme_color_override("font_color", Color(1, 0.64, 0.3, 0.92))
		box.add_child(nudge)

	# A right-anchored, full-height holder centres the panel vertically and keeps it
	# a fixed distance from the right edge at any resolution. The panel itself is
	# never given an absolute position (a container drives it), so a window resize
	# between build and the entrance tween can't strand it off-screen.
	var holder := VBoxContainer.new()
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.alignment = BoxContainer.ALIGNMENT_CENTER
	holder.set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	holder.offset_left = -(PANEL_WIDTH + PANEL_MARGIN)
	holder.offset_right = -PANEL_MARGIN
	add_child(holder)
	holder.add_child(panel)
	_today_panel = holder


## A slim rounded progress bar (fraction 0..1) with a translucent track and a
## coloured fill, for the calorie and XP meters in the right panel.
func _make_bar(fraction: float, fill_color: Color, height: int = 14) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.custom_minimum_size = Vector2(0, height)
	bar.min_value = 0.0
	bar.max_value = 1.0
	bar.value = clampf(fraction, 0.0, 1.0)
	bar.show_percentage = false
	var radius: int = int(height / 2.0)
	var track := StyleBoxFlat.new()
	track.bg_color = Color(1, 1, 1, 0.09)
	track.set_corner_radius_all(radius)
	var fill := StyleBoxFlat.new()
	fill.bg_color = fill_color
	fill.set_corner_radius_all(radius)
	bar.add_theme_stylebox_override("background", track)
	bar.add_theme_stylebox_override("fill", fill)
	return bar


## One compact stat tile for the right panel's tile row: a bright value (with an
## optional unit) over a small caption. Tiles expand to share the row evenly.
func _mini_tile(caption: String, value: String, unit: String = "") -> Control:
	var tile := VBoxContainer.new()
	tile.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tile.add_theme_constant_override("separation", 1)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	tile.add_child(row)
	var value_label := Label.new()
	value_label.text = value
	value_label.add_theme_font_size_override("font_size", 28)
	value_label.add_theme_color_override("font_color", Color(1, 0.64, 0.3))
	row.add_child(value_label)
	if unit != "":
		var unit_label := Label.new()
		unit_label.text = unit
		unit_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		unit_label.add_theme_font_size_override("font_size", 13)
		unit_label.add_theme_color_override("font_color", Color(0.7, 0.74, 0.8))
		row.add_child(unit_label)
	var caption_label := Label.new()
	caption_label.text = caption
	caption_label.add_theme_font_size_override("font_size", 12)
	caption_label.add_theme_color_override("font_color", Color(0.7, 0.74, 0.8))
	tile.add_child(caption_label)
	return tile


## A faint horizontal divider between the panel's sections.
func _thin_rule() -> Control:
	var rule := ColorRect.new()
	rule.color = Color(1, 1, 1, 0.08)
	rule.custom_minimum_size = Vector2(0, 1)
	return rule


## Translucent card stylebox for the right panel — kept see-through so the hero
## photo still reads behind it and the panel feels part of the scene, not a lid.
func _today_panel_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.10, 0.15, 0.72)
	sb.set_corner_radius_all(18)
	sb.set_border_width_all(1)
	sb.border_color = Color(1, 0.5, 0.14, 0.35)
	sb.shadow_color = Color(0, 0, 0, 0.35)
	sb.shadow_size = 18
	sb.content_margin_left = 34
	sb.content_margin_right = 34
	sb.content_margin_top = 30
	sb.content_margin_bottom = 30
	return sb


## Staggered entrance so the menu assembles instead of snapping in: the button
## column fades up one item at a time while the profile card and the today panel
## drift in from the left and right edges. Elements are hidden synchronously (no
## first-frame flash), then a single frame is awaited so container layout has
## settled before rest positions are read for the slides.
func _animate_entrance() -> void:
	var buttons := _settings_button.get_parent()
	var faders: Array[Control] = []
	for child in buttons.get_children():
		if child is Control:
			faders.append(child)
	for f in faders:
		f.modulate.a = 0.0
	if _profile_card != null:
		_profile_card.modulate.a = 0.0
	if _today_panel != null:
		_today_panel.modulate.a = 0.0

	await get_tree().process_frame
	if _background != null:
		_bg_base = _background.position
		_parallax_ready = true

	var delay: float = 0.04
	for f in faders:
		_fade_in(f, delay)
		delay += 0.06
	# The profile card is anchored top-left, so a position slide bakes offsets that
	# still track the left edge — safe. The today panel is right-anchored via its
	# holder; it only fades, so nothing overwrites that responsive anchoring.
	if _profile_card != null:
		_slide_in(_profile_card, Vector2(-46, 0), 0.06)
	if _today_panel != null:
		_fade_in(_today_panel, 0.16)


## Fades [param node] up from transparent after [param delay] seconds.
func _fade_in(node: Control, delay: float) -> void:
	var tw := create_tween()
	tw.tween_interval(delay)
	tw.tween_property(node, "modulate:a", 1.0, 0.34) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


## Slides [param node] to its rest position from [param from_offset] away while
## fading it in — for the anchored profile card and today panel, whose positions a
## container won't overwrite.
func _slide_in(node: Control, from_offset: Vector2, delay: float) -> void:
	var target: Vector2 = node.position
	node.position = target + from_offset
	var tw := create_tween()
	tw.tween_interval(delay)
	tw.tween_property(node, "position", target, 0.46) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(node, "modulate:a", 1.0, 0.42) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


## Drifts the oversized background a few pixels opposite the pointer for a subtle
## depth parallax. Smoothed toward the target so it eases rather than snaps, and
## bounded well inside the background's oversize so no edge is ever exposed.
func _update_parallax() -> void:
	if not _parallax_ready or _background == null:
		return
	var vp: Vector2 = get_viewport_rect().size
	if vp.x <= 0.0 or vp.y <= 0.0:
		return
	var mouse: Vector2 = get_viewport().get_mouse_position()
	var n: Vector2 = (mouse / vp) * 2.0 - Vector2.ONE
	n.x = clampf(n.x, -1.0, 1.0)
	n.y = clampf(n.y, -1.0, 1.0)
	var target: Vector2 = _bg_base - n * PARALLAX
	_background.position = _background.position.lerp(target, 0.06)


func _process(_delta: float) -> void:
	_update_parallax()
	if _cam_status == null:
		return
	# Heart-rate strap: live bpm when a wearable streams (calories then use the
	# more accurate HR model — see CONTEXT.md §9); hidden otherwise.
	if _hr_status != null:
		var connected: bool = MotionManager.is_hr_connected()
		_hr_status.visible = connected
		if connected:
			_hr_status.text = "♥  %d bpm  —  heart-rate connected" % \
				roundi(MotionManager.get_heart_rate())
	if not MotionManager.is_receiving():
		# The shipped launcher starts the pose service automatically, so in a
		# release build "off" just means it's still coming up. The run.bat hint is
		# only meaningful in the editor, where a scene can be run without it.
		if OS.has_feature("editor"):
			_cam_status.text = "●  Camera service off  —  run.bat starts it (keyboard still works)"
		else:
			_cam_status.text = "●  Camera service starting…  —  keyboard works in the meantime"
		_cam_status.add_theme_color_override("font_color", Color(0.82, 0.85, 0.9, 0.72))
	elif MotionManager.is_camera_error():
		_cam_status.text = "●  Camera access blocked  —  Windows Settings ▸ Privacy ▸ Camera"
		_cam_status.add_theme_color_override("font_color", Color(1, 0.72, 0.3, 1))
	else:
		_cam_status.text = "●  Camera ready  —  turns on in-game"
		_cam_status.add_theme_color_override("font_color", Color(0.45, 0.9, 0.5, 0.85))


func _add_menu_button(text: String, target: Callable, icon_name: String = "") -> void:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(360, 60)
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	var buttons := _settings_button.get_parent()
	buttons.add_child(button)
	buttons.move_child(button, _settings_button.get_index())
	if icon_name != "":
		_set_button_icon(button, icon_name)
	button.pressed.connect(target)


## Icon tints, matching the button labels: light on the dark buttons, dark on the
## orange PLAY button (see main_theme.tres PrimaryButton).
const _ICON_LIGHT := Color(0.93, 0.95, 0.98)
const _ICON_DARK := Color(0.11, 0.06, 0.02)


## Hangs a monochrome icon (assets/ui/icons/<name>.svg) on [param button], tinted
## to track its text colour across normal / hover / focus / pressed and capped to a
## uniform on-screen size, so the column reads as one coherent icon set rather than
## whatever glyph a font happened to substitute. [param dark] flips the tint for the
## orange PLAY button (dark icon that turns white when pressed, like its label).
func _set_button_icon(button: Button, icon_name: String, dark: bool = false, size: int = 30) -> void:
	button.icon = load("res://assets/ui/icons/%s.svg" % icon_name)
	button.expand_icon = false
	button.add_theme_constant_override("icon_max_width", size)
	button.add_theme_constant_override("h_separation", 14)
	var base: Color = _ICON_DARK if dark else _ICON_LIGHT
	var bright: Color = _ICON_DARK if dark else Color(1, 1, 1)
	button.add_theme_color_override("icon_normal_color", base)
	button.add_theme_color_override("icon_hover_color", bright)
	button.add_theme_color_override("icon_focus_color", bright)
	button.add_theme_color_override("icon_pressed_color", Color(1, 1, 1) if dark else _ICON_DARK)


func _on_play_pressed() -> void:
	SceneManager.load_game_select()


func _on_settings_pressed() -> void:
	SceneManager.load_settings()


func _on_quit_pressed() -> void:
	get_tree().quit()
