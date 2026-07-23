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
## The whole layout is authored in scenes/menus/results_screen.tscn: every stat
## card exists up front and this script fills it in and hides what doesn't apply
## (the heart-rate cards only show when a wearable actually streamed a rate; the
## empty state replaces the summary when there's no result to report). Only the
## achievement-unlock pills are built at runtime, since there's one per unlock.

const GOLD: Color = Color(1.0, 0.79, 0.28)
const ACCENT: Color = Color(1.0, 0.5, 0.14)
const MUTED: Color = Color(0.62, 0.67, 0.75)

@onready var _empty_state: VBoxContainer = %EmptyState
@onready var _header: VBoxContainer = %Header
@onready var _kicker: Label = %KickerLabel
@onready var _game_title: Label = %GameTitleLabel
@onready var _new_best_badge: PanelContainer = %NewBestBadge
@onready var _encouragement_label: Label = %EncouragementLabel

@onready var _stat_grid: GridContainer = %StatGrid
@onready var _score_value: Label = %ScoreValue
@onready var _score_sub: Label = %ScoreSubLabel
@onready var _time_value: Label = %TimeValue
@onready var _calories_value: Label = %CaloriesValue
@onready var _steps_value: Label = %StepsValue
@onready var _pace_value: Label = %PaceValue
@onready var _xp_value: Label = %XpValue
@onready var _avg_hr_card: PanelContainer = %AvgHrCard
@onready var _avg_hr_value: Label = %AvgHrValue
@onready var _peak_hr_card: PanelContainer = %PeakHrCard
@onready var _peak_hr_value: Label = %PeakHrValue

@onready var _unlocks_row: HBoxContainer = %UnlocksRow
@onready var _progression_row: HBoxContainer = %ProgressionRow
@onready var _level_up_badge: PanelContainer = %LevelUpBadge
@onready var _level_up_label: Label = %LevelUpLabel
@onready var _level_label: Label = %LevelLabel
@onready var _total_xp_label: Label = %TotalXpLabel
@onready var _next_goal_label: Label = %NextGoalLabel

@onready var _play_again_button: Button = %PlayAgainButton
@onready var _choose_game_button: Button = %ChooseGameButton
@onready var _game_select_button: Button = %GameSelectButton
@onready var _main_menu_button: Button = %MainMenuButton

func _ready() -> void:
	_play_again_button.pressed.connect(GameManager.start_selected_game)
	_choose_game_button.pressed.connect(SceneManager.load_game_select)
	_game_select_button.pressed.connect(SceneManager.load_game_select)
	_main_menu_button.pressed.connect(SceneManager.load_main_menu)

	var result: Dictionary = GameManager.get_last_result()
	if result.is_empty():
		_show_empty_state()
		_choose_game_button.grab_focus()
		return

	_fill_header(result)
	_fill_stat_grid(result)
	_fill_unlocks()
	_fill_progression(result)
	_fill_next_goal()
	_play_again_button.grab_focus()


## Reached without a finished game behind it (e.g. straight from a menu): show
## the friendly placeholder instead of a misleading "workout complete", and swap
## Play Again for a route into the game library since there's nothing to replay.
func _show_empty_state() -> void:
	_empty_state.visible = true
	_header.visible = false
	_stat_grid.visible = false
	_progression_row.visible = false
	_play_again_button.visible = false
	_game_select_button.visible = false
	_choose_game_button.visible = true


func _fill_header(result: Dictionary) -> void:
	# A completed Daily Challenge gets its own gold kicker; every other session is
	# the standard "workout complete".
	var challenge_done: bool = bool(result.get("workout_completed", false))
	_kicker.text = "★  DAILY CHALLENGE COMPLETE" if challenge_done else "WORKOUT COMPLETE"
	_kicker.add_theme_color_override("font_color", GOLD if challenge_done else ACCENT)

	var game_id: String = String(result.get("game_id", GameManager.get_current_game_id()))
	var game: Dictionary = GameManager.get_game(game_id)
	_game_title.text = String(game.get("title", "Results")).to_upper()

	# A celebratory "NEW BEST" badge only when this run beat the stored record
	# (and it's not just the first-ever play with a zero baseline).
	_new_best_badge.visible = bool(result.get("new_best", false)) \
			and int(result.get("score", 0)) > 0 and int(result.get("prev_best", 0)) > 0

	_encouragement_label.text = _encouragement(result)


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


func _fill_stat_grid(result: Dictionary) -> void:
	var score: int = int(result.get("score", 0))
	var prev_best: int = int(result.get("prev_best", 0))
	_score_value.text = str(score)
	if bool(result.get("new_best", false)) and prev_best > 0:
		_score_sub.text = "Prev best  %d" % prev_best
	elif prev_best > 0:
		_score_sub.text = "Best  %d" % prev_best
	_score_sub.visible = _score_sub.text != ""

	_time_value.text = _format_duration(float(result.get("duration_sec", 0.0)))
	_calories_value.text = "%.0f" % float(result.get("calories", 0.0))
	_steps_value.text = str(int(result.get("steps", 0)))
	_pace_value.text = "%.0f" % float(result.get("avg_cadence", 0.0))
	_xp_value.text = "+%d" % int(result.get("xp_earned", 0))

	# Heart-rate cards only when a wearable actually streamed a rate this session.
	var peak: float = float(result.get("peak_heart_rate", 0.0))
	_avg_hr_card.visible = peak > 0.0
	_peak_hr_card.visible = peak > 0.0
	if peak > 0.0:
		_avg_hr_value.text = "%.0f" % float(result.get("avg_heart_rate", 0.0))
		_peak_hr_value.text = "%.0f" % peak


## Gold pills for achievements earned since the last summary (this session's
## unlocks, plus any find from a session that never reached Results). Capped so
## a big day doesn't push the buttons off-screen.
func _fill_unlocks() -> void:
	var unlocks: Array[Dictionary] = AchievementManager.take_recent_unlocks()
	if unlocks.is_empty():
		return
	_unlocks_row.visible = true
	var shown: int = mini(unlocks.size(), 3)
	for i in shown:
		_unlocks_row.add_child(_pill_badge("%s  %s" % [String(unlocks[i]["icon"]),
				String(unlocks[i]["title"])]))
	if unlocks.size() > shown:
		var more := Label.new()
		more.text = "+%d more" % (unlocks.size() - shown)
		more.add_theme_font_size_override("font_size", 20)
		more.add_theme_color_override("font_color", MUTED)
		_unlocks_row.add_child(more)


## A gold pill matching the scene's NewBestBadge, for one unlocked achievement.
func _pill_badge(text: String) -> Control:
	var pill := PanelContainer.new()
	pill.add_theme_stylebox_override("panel", _new_best_badge.get_theme_stylebox("panel"))
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 22)
	label.add_theme_color_override("font_color", GOLD)
	pill.add_child(label)
	return pill


## The slim progression line under the cards: total XP and the current level, with
## a level-up call-out when this game pushed the player over the threshold.
func _fill_progression(result: Dictionary) -> void:
	var level_after: int = int(result.get("level_after", ProfileManager.get_level()))
	var leveled_up: bool = bool(result.get("leveled_up", false))
	_level_up_badge.visible = leveled_up
	_level_label.visible = not leveled_up
	_level_up_label.text = "▲  LEVEL UP — LEVEL %d" % level_after
	_level_label.text = "LEVEL %d" % level_after
	_total_xp_label.text = "%d XP total" % int(result.get("total_xp", ProfileManager.get_xp()))


## A quiet "here's what to chase next" line — the nearest locked career
## achievement with live progress, so leaving the screen always hands the
## player a next purpose.
func _fill_next_goal() -> void:
	var goal: Dictionary = AchievementManager.get_next_goal()
	if goal.is_empty():
		return
	var defn: Dictionary = goal["defn"]
	_next_goal_label.text = "NEXT GOAL — %s · %d / %d %s" % [String(defn["title"]),
			int(goal["value"]), int(goal["target"]), String(defn["unit"])]
	_next_goal_label.visible = true


## Formats seconds as m:ss for a real workout duration, or "12.3s" under a minute.
func _format_duration(seconds: float) -> String:
	if seconds < 60.0:
		return "%.1fs" % seconds
	var total := int(round(seconds))
	return "%d:%02d" % [total / 60, total % 60]
