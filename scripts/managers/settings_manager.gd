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

var _settings: Dictionary = {}

func _ready() -> void:
	_settings = SaveManager.load_data(SAVE_FILE, DEFAULTS.duplicate())
	# Backfill any keys added in newer versions of the game.
	for key in DEFAULTS:
		if not _settings.has(key):
			_settings[key] = DEFAULTS[key]
	apply_all()


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
