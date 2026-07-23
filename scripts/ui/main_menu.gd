extends Control
## MainMenu
##
## Entry screen, kept deliberately short: today's Daily Challenge, then a single
## prominent PLAY, FITNESS, ACHIEVEMENTS, STORE, SETTINGS, QUIT. Play -> Game
## Select, Settings -> Settings, Quit -> exit. (Open World is a game in the
## registry, so it's launched from Game Select like every other game.)
##
## The player's profile lives in the top-left card, not the button column: the
## greeting is clickable (-> Profile) with a small "Switch profile" link beneath
## it, which keeps two more items out of the main list. Camera testing lives in
## Settings. All navigation goes through SceneManager; this script never names a
## path.
##
## Everything you can see — the wordmark, the button column with its icons, the
## challenge card, the profile card, the right-hand "today" panel and the two
## status lines — is authored in scenes/menus/main_menu.tscn. This script fills
## in the live figures, wires the buttons, and drives the parallax and the
## entrance animation.

@onready var _challenge_card: Button = %ChallengeCard
@onready var _challenge_kicker: Label = %ChallengeKicker
@onready var _challenge_title: Label = %ChallengeTitle
@onready var _challenge_detail: Label = %ChallengeDetail
@onready var _play_button: Button = %PlayButton
@onready var _fitness_button: Button = %FitnessButton
@onready var _achievements_button: Button = %AchievementsButton
@onready var _store_button: Button = %StoreButton
@onready var _settings_button: Button = %SettingsButton
@onready var _quit_button: Button = %QuitButton
## The hero photo, oversized past the viewport so it can drift a few pixels under
## the pointer without ever exposing an edge (see [method _update_parallax]).
@onready var _background: TextureRect = $Background

## The top-left profile card and the right-hand "today" panel holder, kept so the
## entrance animation can bring them in (the card slides, the panel fades).
@onready var _profile_card: Control = %ProfileCard
@onready var _greeting: Button = %GreetingButton
@onready var _switch_link: Button = %SwitchProfileLink
@onready var _today_panel: Control = %TodayPanelHolder

@onready var _calories_value: Label = %CaloriesValue
@onready var _calorie_goal_label: Label = %CalorieGoalLabel
@onready var _calorie_bar: ProgressBar = %CalorieBar
@onready var _streak_tile: StatTile = %StreakTile
@onready var _week_tile: StatTile = %WeekTile
@onready var _badges_tile: StatTile = %BadgesTile
@onready var _level_label: Label = %LevelLabel
@onready var _xp_to_next_label: Label = %XpToNextLabel
@onready var _level_bar: ProgressBar = %LevelBar
@onready var _week_chart: BarChart = %WeekChart
@onready var _first_run_nudge: Label = %FirstRunNudge

## A small camera-service status line, polled from [MotionManager] in [method
## _process], and a heart-rate strap line above it. The strap line stays hidden
## unless a wearable is actually streaming bpm — most players have none, and an
## "absent" row would just be noise.
@onready var _cam_status: Label = %CameraStatus
@onready var _hr_status: Label = %HeartRateStatus

## Godot weekday index (0=Sunday .. 6=Saturday) → single-letter label, for the
## right panel's 7-day calorie chart.
const WEEKDAY_INITIALS: Array[String] = ["S", "M", "T", "W", "T", "F", "S"]
## How far the background drifts from centre toward the screen edges, in pixels.
const PARALLAX: Vector2 = Vector2(22.0, 13.0)

## What the camera status line can be saying. Kept as a state rather than a
## string so [method _refresh_hardware_status] can tell "nothing changed" from
## "same wording, different reason". UNSET is the value before the first poll, so
## that poll always paints rather than trusting whatever the scene was authored
## with.
enum CameraState { UNSET, OFF, BLOCKED, READY }

## The cached bpm meaning "no strap"; a value no reading can collide with is used
## for "not polled yet" so the first poll always paints.
const BPM_NONE: int = -1
const BPM_UNSET: int = -2

## Parallax rest position (the centred background offset) and a guard so [method
## _process] only drives it once layout has settled.
var _bg_base: Vector2
var _parallax_ready: bool = false

## Last hardware state painted onto the status lines, so a per-frame poll only
## touches a label when something actually moved.
var _shown_bpm: int = BPM_UNSET
var _shown_camera: CameraState = CameraState.UNSET

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

	_play_button.pressed.connect(SceneManager.load_game_select)
	_fitness_button.pressed.connect(SceneManager.load_fitness)
	_achievements_button.pressed.connect(SceneManager.load_achievements)
	_store_button.pressed.connect(SceneManager.load_store)
	_settings_button.pressed.connect(SceneManager.load_settings)
	_quit_button.pressed.connect(func(): get_tree().quit())
	_greeting.pressed.connect(SceneManager.load_profile)
	_switch_link.pressed.connect(SceneManager.load_profile_picker)
	_challenge_card.pressed.connect(GameManager.start_daily_challenge)

	_fill_challenge_card()
	_fill_profile_card()
	_fill_today_panel()
	_animate_entrance()


## Today's Daily Challenge sits at the very top of the column — the session's
## reason to return, above even PLAY (see WorkoutManager): the prescribed game +
## interval structure, its length, and whether it's still pending or already done
## today. Hidden entirely if no eligible game is available to host it.
func _fill_challenge_card() -> void:
	var plan: Dictionary = WorkoutManager.get_today_plan()
	if plan.is_empty():
		_challenge_card.visible = false
		return
	var done: bool = WorkoutManager.is_today_complete()
	var game_title: String = GameManager.get_game_title(String(plan["game_id"]))
	var minutes: int = int(round(float(plan["total_sec"]) / 60.0))

	# A finished challenge turns green — the card's edge on every button state.
	var edge := Color(0.4, 0.85, 0.5, 0.7) if done else Color(1, 0.5, 0.14, 0.85)
	for state in ["normal", "hover", "focus", "pressed"]:
		var style := _challenge_card.get_theme_stylebox(state) as StyleBoxFlat
		style.border_color = edge
		if style.shadow_size > 0:
			style.shadow_color = Color(edge.r, edge.g, edge.b, 0.3)

	if done:
		_challenge_kicker.text = "✓  TODAY'S CHALLENGE — DONE"
		_challenge_kicker.add_theme_color_override("font_color", Color(0.5, 0.9, 0.55))
	else:
		_challenge_kicker.text = "★  TODAY'S CHALLENGE"
		_challenge_kicker.add_theme_color_override("font_color", Color(1, 0.5, 0.14))

	_challenge_title.text = "%s   ·   %s" % [game_title, String(plan.get("title", ""))]

	var detail_text: String = "~%d min   ·   %d pushes" % [minutes, int(plan["push_count"])]
	var streak: int = WorkoutManager.get_challenge_streak()
	if streak > 0:
		detail_text += "   ·   ▲ %d-day challenge streak" % streak
	elif done:
		detail_text += "   ·   come back tomorrow to start a streak"
	_challenge_detail.text = detail_text


## The top-left greeting: "Hi, <name> · Level N" as an obviously-tappable chip
## that opens the profile. Doubling as the profile entry point keeps Profile and
## Switch Profile out of the button column (and makes whose profile is active
## read as a tappable identity, not a label). Streak / today's calories live only
## in the right-hand panel — repeating them here made the top-left stack fight
## the wordmark for the same corner.
func _fill_profile_card() -> void:
	_greeting.text = "Hi, %s   ·   Level %d      ›" % [
		ProfileManager.get_display_name(), ProfileManager.get_level()]


## The right-hand "today" dashboard. The hero shot leaves the right ~55% of the
## screen empty; this fills it with the platform's purpose made personal — today's
## calories against the daily goal, the streak, the week's burn, level progress and
## a 7-day calorie chart — so the menu opens on a snapshot of the player's own
## movement, not dead photo. Read-only: every figure comes from ActivityManager /
## ProfileManager / AchievementManager.
func _fill_today_panel() -> void:
	# Calories against the daily goal — the panel's headline, gold once it's met.
	var today: int = int(ActivityManager.get_today_calories())
	var goal: int = maxi(1, int(ActivityManager.get_daily_calorie_goal()))
	var met: bool = today >= goal
	var cal_color: Color = Color(1, 0.79, 0.28) if met else Color(1, 0.5, 0.14)

	_calories_value.text = str(today)
	_calories_value.add_theme_color_override("font_color", cal_color)
	_calorie_goal_label.text = "/ %d kcal" % goal
	_calorie_bar.value = clampf(float(today) / float(goal), 0.0, 1.0)
	(_calorie_bar.get_theme_stylebox("fill") as StyleBoxFlat).bg_color = cal_color

	_streak_tile.value = str(ActivityManager.get_streak())
	_week_tile.value = "%d" % int(ActivityManager.get_calories_last_days(7))
	_badges_tile.value = "%d / %d" % [
		AchievementManager.get_unlocked_count(),
		AchievementManager.get_definitions().size()]

	# Level progress — how far into the current level the player's total XP sits.
	var level: int = ProfileManager.get_level()
	var xp: int = ProfileManager.get_xp()
	var base: int = ProfileManager.BASE_XP_PER_LEVEL
	var floor_xp: int = base * (level - 1) * level / 2
	var span: int = base * level
	var into: int = clampi(xp - floor_xp, 0, span)
	_level_label.text = "LEVEL %d" % level
	_xp_to_next_label.text = "→   %d XP to level %d" % [span - into, level + 1]
	_level_bar.value = clampf(float(into) / float(span), 0.0, 1.0)

	var labels := PackedStringArray()
	var values := PackedFloat32Array()
	for day in ActivityManager.get_recent_days(7):
		labels.append(WEEKDAY_INITIALS[int(day["weekday"])])
		values.append(float(day["calories"]))
	_week_chart.set_series(labels, values, float(goal))

	# First run: nothing logged yet — one encouraging line instead of a wall of
	# zeroes (matches the platform's always-encourage tone).
	_first_run_nudge.visible = ActivityManager.get_total_sessions() == 0


## Staggered entrance so the menu assembles instead of snapping in: the button
## column fades up one item at a time while the profile card and the today panel
## drift in from the left and right edges. Elements are hidden synchronously (no
## first-frame flash), then a single frame is awaited so container layout has
## settled before rest positions are read for the slides.
func _animate_entrance() -> void:
	var buttons := _play_button.get_parent()
	var faders: Array[Control] = []
	for child in buttons.get_children():
		if child is Control and (child as Control).visible:
			faders.append(child)
	for f in faders:
		f.modulate.a = 0.0
	_profile_card.modulate.a = 0.0
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
	_slide_in(_profile_card, Vector2(-46, 0), 0.06)
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
	# The parallax genuinely is per-frame: it eases toward the mouse every tick.
	# Everything else on this screen only redraws when it actually changes.
	_update_parallax()
	_refresh_hardware_status()


## Repaints the camera and heart-rate lines, but only when their state has moved.
## Both used to be rewritten every frame, which meant a string allocation and a
## theme-colour override per label per tick on a screen that sits idle for
## minutes — an override is not a cheap assignment, it invalidates the control's
## style cache. The values change a handful of times per session, so we compare
## first and write on the edge.
func _refresh_hardware_status() -> void:
	if _cam_status == null:
		return

	# Heart-rate strap: live bpm when a wearable streams (calories then use the
	# more accurate HR model — see CONTEXT.md §9); hidden otherwise.
	var connected: bool = MotionManager.is_hr_connected()
	var bpm: int = roundi(MotionManager.get_heart_rate()) if connected else BPM_NONE
	if bpm != _shown_bpm:
		_shown_bpm = bpm
		_hr_status.visible = connected
		if connected:
			_hr_status.text = "♥  %d bpm  —  heart-rate connected" % bpm

	var state: CameraState = CameraState.READY
	if not MotionManager.is_receiving():
		state = CameraState.OFF
	elif MotionManager.is_camera_error():
		state = CameraState.BLOCKED
	if state == _shown_camera:
		return
	_shown_camera = state
	match state:
		CameraState.OFF:
			# The shipped launcher starts the pose service automatically, so in a
			# release build "off" just means it's still coming up. The run.bat hint
			# is only meaningful in the editor, where a scene can be run without it.
			_cam_status.text = "●  Camera service off  —  run.bat starts it (keyboard still works)" \
				if OS.has_feature("editor") \
				else "●  Camera service starting…  —  keyboard works in the meantime"
			_cam_status.add_theme_color_override("font_color", Color(0.82, 0.85, 0.9, 0.72))
		CameraState.BLOCKED:
			_cam_status.text = "●  Camera access blocked  —  Windows Settings ▸ Privacy ▸ Camera"
			_cam_status.add_theme_color_override("font_color", Color(1, 0.72, 0.3, 1))
		_:
			_cam_status.text = "●  Camera ready  —  turns on in-game"
			_cam_status.add_theme_color_override("font_color", Color(0.45, 0.9, 0.5, 0.85))
