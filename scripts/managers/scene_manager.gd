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
const DIFFICULTY_SELECT: String = "res://scenes/menus/difficulty_select.tscn"
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
const SPRINT: String = "res://scenes/sprint/sprint.tscn"
const BOXING: String = "res://scenes/boxing/boxing.tscn"
const FOOTBALL: String = "res://scenes/football/football.tscn"
const TENNIS: String = "res://scenes/tennis/tennis.tscn"


# --- Fade transition -------------------------------------------------------
# Every scene change dips through a quick black fade so screens hand over
# smoothly instead of hard-cutting. Owned here because SceneManager is the only
# place transitions happen — one overlay covers the whole app.

## Seconds to fade to black before the swap, and back out after it.
const FADE_OUT_SEC: float = 0.16
const FADE_IN_SEC: float = 0.24

## Seconds a threaded scene load may run (behind the black fade) before the
## loading screen fades in over it. Menu scenes load far quicker than this, so
## only genuinely heavy scenes (games) ever show the loading UI.
const LOADING_UI_DELAY_SEC: float = 0.2

## Full-screen black rect used for the fade; lives on a high CanvasLayer so it
## covers every scene (including game HUDs on layer 0/1).
var _fade_rect: ColorRect
## The CanvasLayer hosting the fade rect (and, during slow loads, the loading UI).
var _overlay_layer: CanvasLayer
## Instanced loading_screen.tscn shown over the black while a slow load runs.
var _loading_ui: Node = null
## True while a fade+swap is running; further change_scene calls are ignored so
## button-mashing can't double-load a scene mid-transition.
var _transitioning: bool = false

func _ready() -> void:
	# The fade must keep animating while the tree is paused (a game may pause
	# during its intro), so the layer processes always and the tweens are made
	# pause-immune in _fade_to.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_overlay_layer = CanvasLayer.new()
	_overlay_layer.layer = 120
	add_child(_overlay_layer)
	_fade_rect = ColorRect.new()
	_fade_rect.color = Color(0.0, 0.0, 0.0, 1.0)
	_fade_rect.modulate.a = 0.0
	_fade_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_fade_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay_layer.add_child(_fade_rect)


## Changes the active scene to the one at [param path], dipping through a short
## black fade. The scene is loaded on a background thread so the app never
## freezes; if the load outlasts [constant LOADING_UI_DELAY_SEC] the loading
## screen appears over the black with real progress. This is the low-level
## primitive every other loader routes through. Calls made while a transition
## is already running are ignored.
func change_scene(path: String) -> void:
	if _transitioning:
		return
	_transitioning = true
	scene_changing.emit(path)
	# Block clicks on the outgoing scene while it fades.
	_fade_rect.mouse_filter = Control.MOUSE_FILTER_STOP
	await _fade_to(1.0, FADE_OUT_SEC)
	var packed: PackedScene = await _load_scene_async(path)
	if packed == null:
		push_error("SceneManager: failed to load '%s'" % path)
	else:
		var result: int = get_tree().change_scene_to_packed(packed)
		if result != OK:
			push_error("SceneManager: failed to change to '%s' (error %d)" % [path, result])
		else:
			scene_changed.emit(path)
	_hide_loading_ui()
	await _fade_to(0.0, FADE_IN_SEC)
	_fade_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_transitioning = false


## Loads [param path] on a background thread, surfacing the loading UI if it
## takes long enough to notice. Returns null on failure.
func _load_scene_async(path: String) -> PackedScene:
	# NB use_sub_threads stays false: parallel sub-thread loading can fail to
	# compile scripts that reference autoloads ("Parse Error: Failed" on any
	# scene whose script uses a manager). One background thread is plenty.
	if ResourceLoader.load_threaded_request(path) != OK:
		# Request refused (bad path); fall back to a plain load so the error
		# surfaces through the normal channel.
		return load(path) as PackedScene
	var progress: Array = []
	var elapsed: float = 0.0
	while true:
		var status: int = ResourceLoader.load_threaded_get_status(path, progress)
		match status:
			ResourceLoader.THREAD_LOAD_IN_PROGRESS:
				if elapsed >= LOADING_UI_DELAY_SEC:
					_show_loading_ui()
					if _loading_ui != null and not progress.is_empty():
						_loading_ui.call("set_progress", float(progress[0]) * 100.0)
				await get_tree().process_frame
				elapsed += get_process_delta_time()
			ResourceLoader.THREAD_LOAD_LOADED:
				if _loading_ui != null:
					_loading_ui.call("set_progress", 100.0)
				return ResourceLoader.load_threaded_get(path) as PackedScene
			_:
				return null
	return null


## Instances the loading screen over the black fade (idempotent).
func _show_loading_ui() -> void:
	if _loading_ui != null:
		return
	var scene := load(LOADING) as PackedScene
	if scene == null:
		return
	_loading_ui = scene.instantiate()
	# Added after the fade rect so it draws above the black.
	_overlay_layer.add_child(_loading_ui)


func _hide_loading_ui() -> void:
	if _loading_ui == null:
		return
	_loading_ui.queue_free()
	_loading_ui = null


## Tweens the fade rect to [param alpha] over [param duration] and completes
## when it lands. Pause-immune so a paused tree can't wedge the app mid-fade.
func _fade_to(alpha: float, duration: float) -> void:
	var tween := create_tween()
	tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	tween.tween_property(_fade_rect, "modulate:a", alpha, duration) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	await tween.finished


func load_main_menu() -> void:
	change_scene(MAIN_MENU)


func load_game_select() -> void:
	change_scene(GAME_SELECT)


func load_difficulty_select() -> void:
	change_scene(DIFFICULTY_SELECT)


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
