extends Control
## MainMenu
##
## Entry screen. Play -> Game Select, Settings -> Settings, Quit -> exit.
## (Open World is now a game in the registry, so it's launched from Game Select
## like every other game.) All navigation goes through SceneManager; this script
## never names a path.

@onready var _play_button: Button = %PlayButton
@onready var _settings_button: Button = %SettingsButton
@onready var _quit_button: Button = %QuitButton

func _ready() -> void:
	# First-run gate: send new players through onboarding before the menu is
	# usable, so calorie estimation has their real body data from the start.
	if not ProfileManager.is_onboarded():
		SceneManager.load_profile_setup.call_deferred()
		return

	_play_button.pressed.connect(_on_play_pressed)
	_settings_button.pressed.connect(_on_settings_pressed)
	_quit_button.pressed.connect(_on_quit_pressed)
	# Fitness + Profile are added in code (inserted just above Quit) so the menu
	# scene stays a plain button list. Order ends up: Play, Settings, Fitness,
	# Profile, Quit.
	_add_menu_button("FITNESS", SceneManager.load_fitness)
	_add_menu_button("PROFILE", SceneManager.load_profile)


func _add_menu_button(text: String, target: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(360, 60)
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	var buttons := _quit_button.get_parent()
	buttons.add_child(button)
	buttons.move_child(button, _quit_button.get_index())
	button.pressed.connect(target)


func _on_play_pressed() -> void:
	SceneManager.load_game_select()


func _on_settings_pressed() -> void:
	SceneManager.load_settings()


func _on_quit_pressed() -> void:
	get_tree().quit()
