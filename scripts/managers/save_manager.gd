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
##
## [b]Numbers come back as floats.[/b] JSON has a single number type, so an int
## saved as 7 loads as 7.0 — the layer cannot tell an intended float from a whole
## number and does not try to guess. Every caller already casts on read
## ([code]int(data["level"])[/code]); keep doing that rather than assigning a
## loaded value straight into a typed int, which fails at runtime. Pinned by
## scenes/tests/save_probe.tscn.

## Directory (inside user://) where all runtime save files live.
const SAVE_DIR: String = "user://saves"
## Suffix for the scratch file [method save_data] writes before promoting it over
## the real save. See that method for why.
const TEMP_SUFFIX: String = ".tmp"

## The shape of everything written under [constant SAVE_DIR]. Every save is
## stamped with it so a future release can recognise an older file and migrate it
## instead of guessing from which keys happen to be present — a guess that gets
## less reliable with every game added to the roster.
##
## Bump this ONLY when an existing file's meaning changes (a key renamed, a unit
## changed, a value restructured). Adding a new optional key does not need a bump:
## managers already backfill missing keys from their own defaults on load.
## When you do bump it, handle the older version — [method get_saved_version]
## reads a file's stamp without loading it.
const SCHEMA_VERSION: int = 1
## Where the stamp lives. Underscore-prefixed to keep it out of the way of real
## data, and stripped back out on load so no caller ever iterates over it.
const VERSION_KEY: String = "_schema_version"

func _ready() -> void:
	_ensure_save_dir()


## Writes [param data] as pretty-printed JSON to [param file_name] (for example
## "profile.json"). Returns true on success, false if the file could not be
## written.
##
## The write is atomic: the JSON goes to a "<name>.tmp" scratch file which is
## only renamed over the real save once it is fully flushed and closed. Opening
## the save directly with FileAccess.WRITE would truncate it first, so a crash or
## power loss mid-write would leave a half-written file and lose every profile in
## it. With the rename, an interrupted save leaves the previous good save intact.
##
## The written JSON carries a [constant VERSION_KEY] stamp. It is added to a copy,
## so the caller's dictionary is never touched.
func save_data(file_name: String, data: Dictionary) -> bool:
	_ensure_save_dir()
	var stamped: Dictionary = data.duplicate()
	stamped[VERSION_KEY] = SCHEMA_VERSION
	var temp_name: String = file_name + TEMP_SUFFIX
	var file: FileAccess = FileAccess.open(_path_for(temp_name), FileAccess.WRITE)
	if file == null:
		push_error("SaveManager: could not open '%s' for writing (error %d)"
			% [temp_name, FileAccess.get_open_error()])
		return false
	file.store_string(JSON.stringify(stamped, "\t"))
	file.close()

	var dir: DirAccess = DirAccess.open(ProjectSettings.globalize_path(SAVE_DIR))
	if dir == null:
		push_error("SaveManager: could not open the save directory (error %d)"
			% DirAccess.get_open_error())
		return false
	# rename() replaces an existing destination on the platforms we ship to; the
	# scratch file is left behind on failure so the data is still recoverable.
	var err: int = dir.rename(temp_name, file_name)
	if err != OK:
		push_error("SaveManager: could not promote '%s' over '%s' (error %d)"
			% [temp_name, file_name, err])
		return false
	return true


## Loads and parses the JSON dictionary stored in [param file_name]. Returns
## [param fallback] (an empty Dictionary by default) when the file is missing,
## unreadable, or does not contain a JSON object.
##
## The [constant VERSION_KEY] stamp is stripped before returning, so callers get
## only their own data — several of them iterate the dictionary they get back, and
## a bookkeeping key in there would show up as a phantom setting or profile. Read
## the stamp with [method get_saved_version] instead.
func load_data(file_name: String, fallback: Dictionary = {}) -> Dictionary:
	var parsed: Variant = _read_json(file_name)
	if parsed is Dictionary:
		var data: Dictionary = parsed
		data.erase(VERSION_KEY)
		return data
	return fallback


## The [constant SCHEMA_VERSION] a save was written with, for migration code to
## branch on. Returns 0 for a file written before stamping existed, and -1 if
## there is no readable file at all — "pre-versioned" and "absent" call for
## different handling.
func get_saved_version(file_name: String) -> int:
	var parsed: Variant = _read_json(file_name)
	if parsed is Dictionary:
		return int((parsed as Dictionary).get(VERSION_KEY, 0))
	return -1


## Reads and parses [param file_name], or returns null if it is missing,
## unreadable, or not a JSON object.
func _read_json(file_name: String) -> Variant:
	if not has_save(file_name):
		return null
	var file: FileAccess = FileAccess.open(_path_for(file_name), FileAccess.READ)
	if file == null:
		push_error("SaveManager: could not open '%s' for reading" % file_name)
		return null
	var text: String = file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		return parsed
	push_warning("SaveManager: '%s' did not contain a JSON object." % file_name)
	return null


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
