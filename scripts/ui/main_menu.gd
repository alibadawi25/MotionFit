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

## A small camera-service status line, built in code (like the menu's extra
## buttons) and polled from [MotionManager] in [method _process].
var _cam_status: Label

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

	_play_button.pressed.connect(_on_play_pressed)
	_settings_button.pressed.connect(_on_settings_pressed)
	_quit_button.pressed.connect(_on_quit_pressed)
	# FITNESS is the only extra button, inserted just below PLAY (above Settings).
	# Profile and Switch Profile live in the top-left card; Test Camera moved into
	# Settings.
	_add_menu_button("FITNESS", SceneManager.load_fitness)
	_build_profile_card()
	_build_camera_status()


## Top-left profile card: a clickable "Hi, <name> · Level N" greeting that opens
## the profile, with a small "Switch profile" link beneath it. Doubling as the
## profile/switch entry points keeps those two items out of the button column
## (and makes whose profile is active read as a tappable identity, not a label).
func _build_profile_card() -> void:
	var card := VBoxContainer.new()
	card.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	card.offset_left = 52.0
	card.offset_top = 40.0
	card.add_theme_constant_override("separation", 0)

	var greeting := Button.new()
	greeting.flat = true
	greeting.alignment = HORIZONTAL_ALIGNMENT_LEFT
	greeting.tooltip_text = "View your profile"
	greeting.text = "Hi, %s  ·  Level %d" % [
		ProfileManager.get_display_name(), ProfileManager.get_level()]
	greeting.add_theme_font_size_override("font_size", 22)
	greeting.add_theme_color_override("font_color", Color(0.86, 0.89, 0.94))
	greeting.add_theme_color_override("font_hover_color", Color(1, 0.64, 0.3))
	greeting.add_theme_color_override("font_pressed_color", Color(1, 0.5, 0.14))
	greeting.pressed.connect(SceneManager.load_profile)
	card.add_child(greeting)

	var switch_link := Button.new()
	switch_link.flat = true
	switch_link.alignment = HORIZONTAL_ALIGNMENT_LEFT
	switch_link.text = "Switch profile"
	switch_link.add_theme_font_size_override("font_size", 16)
	switch_link.add_theme_color_override("font_color", Color(1, 0.64, 0.3, 0.82))
	switch_link.add_theme_color_override("font_hover_color", Color(1, 0.74, 0.4))
	switch_link.pressed.connect(SceneManager.load_profile_picker)
	card.add_child(switch_link)

	add_child(card)


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


func _process(_delta: float) -> void:
	if _cam_status == null:
		return
	if not MotionManager.is_receiving():
		_cam_status.text = "●  Camera service off  —  run.bat starts it (keyboard still works)"
		_cam_status.add_theme_color_override("font_color", Color(0.82, 0.85, 0.9, 0.72))
	elif MotionManager.is_camera_error():
		_cam_status.text = "●  Camera access blocked  —  Windows Settings ▸ Privacy ▸ Camera"
		_cam_status.add_theme_color_override("font_color", Color(1, 0.72, 0.3, 1))
	else:
		_cam_status.text = "●  Camera ready  —  turns on in-game"
		_cam_status.add_theme_color_override("font_color", Color(0.45, 0.9, 0.5, 0.85))


func _add_menu_button(text: String, target: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(360, 60)
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	var buttons := _settings_button.get_parent()
	buttons.add_child(button)
	buttons.move_child(button, _settings_button.get_index())
	button.pressed.connect(target)


func _on_play_pressed() -> void:
	SceneManager.load_game_select()


func _on_settings_pressed() -> void:
	SceneManager.load_settings()


func _on_quit_pressed() -> void:
	get_tree().quit()
