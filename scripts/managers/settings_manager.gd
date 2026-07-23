extends Node
## SettingsManager
##
## Holds user preferences (audio volumes) and applies them to the
## engine. It loads persisted settings on startup, applies them, and re-applies
## whenever a value changes. Persistence goes through SaveManager and audio is
## applied through AudioManager, so both of those autoloads must initialise
## before this one (see the autoload order documented in CONTEXT.md).

## Emitted whenever any setting changes, after it has been applied and saved.
signal settings_changed

const SAVE_FILE: String = "settings.json"

## Default values used on first run or when the save file is missing a key.
const DEFAULTS: Dictionary = {
	"master_volume": 1.0,
	"music_volume": 0.8,
	"sfx_volume": 0.9,
}

## The smallest window the UI is designed to survive. The project stretches
## canvas_items with aspect "expand", so a smaller window doesn't crop — it
## scales everything down uniformly, and below roughly this size the HUD values
## and captions stop being readable at arm's length, which is the distance this
## whole app is played from. Not a preference: there is no reason to let a player
## choose an unreadable window.
const MIN_WINDOW: Vector2i = Vector2i(1280, 720)

## Window overrides read from the USER command line — the part after `--`.
##
## The project ships fullscreen (`window/size/mode=3`), and a fullscreen window
## silently ignores Godot's own `--windowed` / `--resolution`, so the dev tools
## that need a specific window size (`tools/shot.sh`, checking that a screen
## reflows at a non-16:9 aspect) used to have to hand-edit project.godot and
## remember to put it back. Applying the flags ourselves fixes that — but they
## have to arrive after `--`: [method OS.get_cmdline_args] strips every argument
## the engine consumed, and `--windowed`/`--resolution` are two of them, so
## reading them from there would return nothing.
const ARG_WINDOWED: String = "--windowed"
const ARG_RESOLUTION: String = "--resolution"

## How much of the screen the window takes when someone drops out of fullscreen.
## Comfortably short of the whole screen, so what appears is recognisably a
## window with a titlebar to drag — the point of the escape hatch.
const WINDOWED_SCREEN_FRACTION: float = 0.8

## Whether the window is currently fullscreen. Tracked rather than read back from
## the window, because the mode readout is unreliable: a WINDOWED window that
## happens to exactly fill the screen reports as EXCLUSIVE_FULLSCREEN on Windows,
## which would jam a toggle that trusted it into never returning to fullscreen.
var _fullscreen: bool = true

var _settings: Dictionary = {}

func _ready() -> void:
	_settings = SaveManager.load_data(SAVE_FILE, DEFAULTS.duplicate())
	# Backfill any keys added in newer versions of the game.
	for key in DEFAULTS:
		if not _settings.has(key):
			_settings[key] = DEFAULTS[key]
	apply_all()
	DisplayServer.window_set_min_size(MIN_WINDOW)
	_apply_cmdline_window()
	# The fullscreen hatch has to work on a pause screen too — that is exactly
	# where someone stuck on the wrong monitor will be reaching for it.
	process_mode = Node.PROCESS_MODE_ALWAYS


## Flips between fullscreen and a window. Bound to F11 and Alt+Enter rather than
## offered in Settings: this app is played from across the room, where a window
## is unreadable, so a windowed mode is an escape hatch (the game opened on the
## wrong monitor, a display came back from sleep wrong) and not a preference
## worth a row in the UI. Deliberately not persisted, for the same reason — a
## restart returns to the mode the game is meant to be played in.
func toggle_fullscreen() -> void:
	_fullscreen = not _fullscreen
	var window: Window = get_window()
	if _fullscreen:
		window.mode = Window.MODE_FULLSCREEN
		return
	var usable: Rect2i = DisplayServer.screen_get_usable_rect(
			DisplayServer.window_get_current_screen())
	var size: Vector2i = Vector2i(Vector2(usable.size) * WINDOWED_SCREEN_FRACTION)
	_set_windowed(size)
	window.position = usable.position + (usable.size - window.size) / 2


# _input rather than _unhandled_input: an escape hatch that stops working
# because a menu happened to consume the event is not an escape hatch. Only the
# two toggle chords are marked handled; everything else passes straight through.
func _input(event: InputEvent) -> void:
	if event is not InputEventKey:
		return
	var key: InputEventKey = event
	if not key.pressed or key.echo:
		return
	var enter: bool = key.keycode == KEY_ENTER or key.keycode == KEY_KP_ENTER
	if key.keycode != KEY_F11 and not (enter and key.alt_pressed):
		return
	toggle_fullscreen()
	get_viewport().set_input_as_handled()


## Applies `--windowed` (and an optional `--resolution WxH`, in either the
## separate or the `=` form) from the command line. Absent flags change nothing,
## so a normal launch is untouched. The requested size still passes through
## [constant MIN_WINDOW] — asking for something unreadable is a mistake whether
## it comes from a player or from a script.
func _apply_cmdline_window() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.has(ARG_WINDOWED):
		return
	_fullscreen = false
	var size: Vector2i = _parse_resolution(_cmdline_value(args, ARG_RESOLUTION))
	_set_windowed(size if size != Vector2i.ZERO else MIN_WINDOW)


## Puts the window into windowed mode at [param size]. Both callers go through
## here so they cannot drift: the size is clamped up to [constant MIN_WINDOW] (the
## OS min-size does this too, but only for the user's own dragging — a programmatic
## resize is not bound by it), and the mode is set before the size, because
## resizing a fullscreen window is what silently did nothing before.
func _set_windowed(size: Vector2i) -> void:
	var window: Window = get_window()
	window.mode = Window.MODE_WINDOWED
	window.size = size.max(MIN_WINDOW)


## The value of [param flag], written either as `--flag value` or `--flag=value`,
## or "" if it isn't present.
func _cmdline_value(args: PackedStringArray, flag: String) -> String:
	for i: int in args.size():
		if args[i] == flag:
			return args[i + 1] if i + 1 < args.size() else ""
		if args[i].begins_with(flag + "="):
			return args[i].substr(flag.length() + 1)
	return ""


## "1600x1000" -> Vector2i(1600, 1000); anything malformed -> Vector2i.ZERO, so a
## typo leaves the window alone instead of collapsing it.
func _parse_resolution(text: String) -> Vector2i:
	var parts: PackedStringArray = text.split("x", false)
	if parts.size() != 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return Vector2i.ZERO
	return Vector2i(int(parts[0]), int(parts[1]))


## Applies every current setting to the engine (audio buses).
func apply_all() -> void:
	AudioManager.set_master_volume(get_master_volume())
	AudioManager.set_music_volume(get_music_volume())
	AudioManager.set_sfx_volume(get_sfx_volume())


func get_master_volume() -> float:
	return float(_settings["master_volume"])


func get_music_volume() -> float:
	return float(_settings["music_volume"])


func get_sfx_volume() -> float:
	return float(_settings["sfx_volume"])


## Sets the master volume (linear 0.0 - 1.0), applies and persists it.
func set_master_volume(value: float) -> void:
	_update_setting("master_volume", clampf(value, 0.0, 1.0))
	AudioManager.set_master_volume(get_master_volume())


## Sets the music volume (linear 0.0 - 1.0), applies and persists it.
func set_music_volume(value: float) -> void:
	_update_setting("music_volume", clampf(value, 0.0, 1.0))
	AudioManager.set_music_volume(get_music_volume())


## Sets the SFX volume (linear 0.0 - 1.0), applies and persists it.
func set_sfx_volume(value: float) -> void:
	_update_setting("sfx_volume", clampf(value, 0.0, 1.0))
	AudioManager.set_sfx_volume(get_sfx_volume())


# Renamed from _set to avoid clashing with Object's built-in virtual
# _set(StringName, Variant) -> bool.
func _update_setting(key: String, value: Variant) -> void:
	_settings[key] = value
	SaveManager.save_data(SAVE_FILE, _settings)
	settings_changed.emit()
