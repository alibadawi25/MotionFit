extends Control
## ResultsScreen
##
## Displays the last game's result from GameManager (score, time, calories, XP)
## and offers Play Again / Game Select / Main Menu. Generic across all games
## because every game reports the same result schema (see CONTEXT.md).

@onready var _summary_label: Label = %SummaryLabel
@onready var _play_again_button: Button = %PlayAgainButton
@onready var _select_button: Button = %SelectButton
@onready var _menu_button: Button = %MenuButton

func _ready() -> void:
	_summary_label.text = _format_summary(GameManager.get_last_result())
	_play_again_button.pressed.connect(_on_play_again_pressed)
	_select_button.pressed.connect(_on_select_pressed)
	_menu_button.pressed.connect(_on_menu_pressed)


func _format_summary(result: Dictionary) -> String:
	if result.is_empty():
		return "No results yet."
	return "Score: %d\nTime: %.1fs\nCalories: %.0f\nXP earned: %d" % [
		int(result.get("score", 0)),
		float(result.get("duration_sec", 0.0)),
		float(result.get("calories", 0.0)),
		int(result.get("xp_earned", 0)),
	]


func _on_play_again_pressed() -> void:
	GameManager.start_selected_game()


func _on_select_pressed() -> void:
	SceneManager.load_game_select()


func _on_menu_pressed() -> void:
	SceneManager.load_main_menu()
