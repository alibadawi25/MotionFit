extends Node
## SceneManager
##
## Single source of truth for every scene path in the project and the ONLY
## place scene transitions happen. No other script may hardcode a "res://...tscn"
## path or call get_tree().change_scene_* directly. To add a screen or game,
## add a constant here and a matching loader method.
##
## Keeping paths in one manager means a folder reorganisation or a renamed
## scene is a one-line change, and it lets every game be launched generically
## from data (see GameManager) instead of bespoke code per game.

## Emitted immediately before the active scene is swapped out.
signal scene_changing(target_path: String)
## Emitted after [method change_scene] has requested the new scene.
signal scene_changed(target_path: String)

## Whether the player has picked "who's playing" this app launch. Reset to false
## every process start (autoloads re-initialise), so the profile picker shows once
## per launch on a shared device, then the menu proceeds with the chosen profile.
var profile_chosen_this_session: bool = false

# --- Core UI / flow scenes -------------------------------------------------
const MAIN_MENU: String = "res://scenes/menus/main_menu.tscn"
const GAME_SELECT: String = "res://scenes/menus/game_select.tscn"
const SETTINGS: String = "res://scenes/menus/settings_menu.tscn"
const PAUSE_MENU: String = "res://scenes/menus/pause_menu.tscn"
const RESULTS: String = "res://scenes/menus/results_screen.tscn"
const LOADING: String = "res://scenes/menus/loading_screen.tscn"
const COUNTDOWN: String = "res://scenes/menus/countdown_screen.tscn"
const PROFILE_SETUP: String = "res://scenes/menus/profile_setup.tscn"
const PROFILE_PICKER: String = "res://scenes/menus/profile_picker.tscn"
const CALIBRATION_SETUP: String = "res://scenes/menus/calibration_setup.tscn"
const PROFILE: String = "res://scenes/menus/profile_screen.tscn"
const FITNESS: String = "res://scenes/menus/fitness_screen.tscn"
const CAMERA_TEST: String = "res://scenes/menus/camera_test.tscn"

# --- Mini-game scenes ------------------------------------------------------
# Every game registered in GameManager references one of these constants.
# Open World is a free-roam MiniGame (no fail state; steps/calories are still
# tracked), so it lives here alongside the scored games.
const OPEN_WORLD: String = "res://scenes/open-world/open-world.tscn"
const RUNNER: String = "res://scenes/runner/runner.tscn"
const BOXING: String = "res://scenes/boxing/boxing.tscn"
const FOOTBALL: String = "res://scenes/football/football.tscn"
const TENNIS: String = "res://scenes/tennis/tennis.tscn"


## Changes the active scene to the one at [param path]. This is the low-level
## primitive every other loader routes through. Returns the [enum Error] result.
func change_scene(path: String) -> int:
	scene_changing.emit(path)
	var result: int = get_tree().change_scene_to_file(path)
	if result != OK:
		push_error("SceneManager: failed to change to '%s' (error %d)" % [path, result])
		return result
	scene_changed.emit(path)
	return OK


func load_main_menu() -> void:
	change_scene(MAIN_MENU)


func load_game_select() -> void:
	change_scene(GAME_SELECT)


func load_settings() -> void:
	change_scene(SETTINGS)


func load_profile_setup() -> void:
	change_scene(PROFILE_SETUP)


func load_profile_picker() -> void:
	change_scene(PROFILE_PICKER)


func load_calibration_setup() -> void:
	change_scene(CALIBRATION_SETUP)


func load_profile() -> void:
	change_scene(PROFILE)


func load_fitness() -> void:
	change_scene(FITNESS)


func load_camera_test() -> void:
	change_scene(CAMERA_TEST)


func load_countdown() -> void:
	change_scene(COUNTDOWN)


func load_results() -> void:
	change_scene(RESULTS)


## Loads an arbitrary scene by absolute [param path]. Prefer the named loaders;
## this exists for systems (like GameManager) that resolve a path from data.
func load_scene(path: String) -> void:
	change_scene(path)
