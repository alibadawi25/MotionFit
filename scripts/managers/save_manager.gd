extends Node
## SaveManager
##
## Low-level persistence layer for the whole platform. It is the ONLY system
## that touches the filesystem directly; every other manager (ProfileManager,
## SettingsManager, future GameManager stats) reads and writes through here.
## Centralising I/O means the storage format or location can change in a single
## place without touching gameplay code.
##
## Files are stored as JSON under [constant SAVE_DIR] which lives in "user://"
## (a real, writable, per-user location). The project's "data/saves" folder is
## reserved for bundled default/template data shipped with the game, because
## "res://" is read-only in exported builds.

## Directory (inside user://) where all runtime save files live.
const SAVE_DIR: String = "user://saves"

func _ready() -> void:
	_ensure_save_dir()


## Writes [param data] as pretty-printed JSON to [param file_name] (for example
## "profile.json"). Returns true on success, false if the file could not be
## opened for writing.
func save_data(file_name: String, data: Dictionary) -> bool:
	_ensure_save_dir()
	var file: FileAccess = FileAccess.open(_path_for(file_name), FileAccess.WRITE)
	if file == null:
		push_error("SaveManager: could not open '%s' for writing (error %d)"
			% [file_name, FileAccess.get_open_error()])
		return false
	file.store_string(JSON.stringify(data, "\t"))
	file.close()
	return true


## Loads and parses the JSON dictionary stored in [param file_name]. Returns
## [param fallback] (an empty Dictionary by default) when the file is missing,
## unreadable, or does not contain a JSON object.
func load_data(file_name: String, fallback: Dictionary = {}) -> Dictionary:
	if not has_save(file_name):
		return fallback
	var file: FileAccess = FileAccess.open(_path_for(file_name), FileAccess.READ)
	if file == null:
		push_error("SaveManager: could not open '%s' for reading" % file_name)
		return fallback
	var text: String = file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		return parsed
	push_warning("SaveManager: '%s' did not contain a JSON object." % file_name)
	return fallback


## Returns true if a save file with [param file_name] exists.
func has_save(file_name: String) -> bool:
	return FileAccess.file_exists(_path_for(file_name))


## Deletes the save file [param file_name]. Returns true if a file was removed.
func delete_save(file_name: String) -> bool:
	if not has_save(file_name):
		return false
	var absolute: String = ProjectSettings.globalize_path(_path_for(file_name))
	return DirAccess.remove_absolute(absolute) == OK


func _ensure_save_dir() -> void:
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(SAVE_DIR)):
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SAVE_DIR))


func _path_for(file_name: String) -> String:
	return "%s/%s" % [SAVE_DIR, file_name]
