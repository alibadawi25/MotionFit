extends Node
## SaveProbe
##
## Headless self-test for [SaveManager]. Run with:
##   Godot --headless --path . res://scenes/tests/save_probe.tscn --quit-after 40
##
## SaveManager is the only system in the platform that touches the filesystem,
## which makes it the only one that can lose every profile at once. Two things it
## does are invisible in normal play and would fail silently: the atomic write
## (scratch file promoted over the real save) and the schema stamp (added on
## write, stripped on read). Neither shows up on screen, so neither can be caught
## by a screenshot — they get assertions instead.
##
## Everything here works on throwaway file names under the real save directory
## and deletes them again, so a developer's own profiles are never touched.
##
## Prints PASS/FAIL lines; exits via quit() with a non-zero code on failure.

const FILE: String = "probe_save.json"
const ABSENT: String = "probe_never_written.json"
const LEGACY: String = "probe_legacy.json"

var _failures: int = 0


func _ready() -> void:
	_cleanup()

	# A round trip must return what went in — with the one documented exception
	# that JSON has a single number type, so ints come back as floats. That is
	# asserted rather than worked around: it is a real property of the layer, and
	# a caller assigning a loaded value straight into a typed int would break on
	# it. See the SaveManager header.
	var written: Dictionary = {"name": "Ada", "level": 7, "kcal": 431.5}
	_check("save reports success", SaveManager.save_data(FILE, written), true)
	var read: Dictionary = SaveManager.load_data(FILE)
	_check("round trip keeps the data",
			read, {"name": "Ada", "level": 7.0, "kcal": 431.5})
	_check("ints come back as floats", read["level"] is float, true)
	_check("...and cast back cleanly", int(read["level"]), 7)

	# The stamp is bookkeeping, not data: it must not come back out. Several
	# managers iterate what they load, so a stray key would read as a phantom
	# setting or profile.
	_check("stamp stripped on load", read.has(SaveManager.VERSION_KEY), false)
	_check("stamp readable on its own",
			SaveManager.get_saved_version(FILE), SaveManager.SCHEMA_VERSION)

	# Stamping must not reach back into the caller's dictionary.
	_check("caller's dictionary untouched",
			written.has(SaveManager.VERSION_KEY), false)

	# The scratch file the atomic write goes through must not survive it.
	_check("no scratch file left behind",
			SaveManager.has_save(FILE + SaveManager.TEMP_SUFFIX), false)

	# A save from before stamping existed reads as version 0, and still loads.
	_write_raw(LEGACY, '{"name": "Grace", "level": 3}')
	_check("pre-versioned save reads as 0", SaveManager.get_saved_version(LEGACY), 0)
	_check("pre-versioned save still loads",
			SaveManager.load_data(LEGACY), {"name": "Grace", "level": 3.0})

	# "No file" is a different answer from "old file" — migration code has to be
	# able to tell a fresh install from an upgrade.
	_check("absent save reads as -1", SaveManager.get_saved_version(ABSENT), -1)
	_check("absent save falls back",
			SaveManager.load_data(ABSENT, {"fresh": true}), {"fresh": true})

	# Overwriting must replace, not merge with, what was there.
	SaveManager.save_data(FILE, {"only": "this"})
	_check("overwrite replaces the file",
			SaveManager.load_data(FILE), {"only": "this"})

	_check("delete removes the file", SaveManager.delete_save(FILE), true)
	_check("deleted save is gone", SaveManager.has_save(FILE), false)

	_cleanup()
	if _failures == 0:
		print("PASS — all save checks passed")
	else:
		print("FAIL — %d save check(s) failed" % _failures)
	get_tree().quit(1 if _failures > 0 else 0)


## Writes [param text] straight to the save directory, bypassing save_data, so a
## file can be staged in a shape save_data would never produce.
func _write_raw(file_name: String, text: String) -> void:
	var file: FileAccess = FileAccess.open(
			"%s/%s" % [SaveManager.SAVE_DIR, file_name], FileAccess.WRITE)
	file.store_string(text)
	file.close()


func _cleanup() -> void:
	for name: String in [FILE, LEGACY, ABSENT, FILE + SaveManager.TEMP_SUFFIX]:
		SaveManager.delete_save(name)


func _check(what: String, got: Variant, expected: Variant) -> void:
	if got == expected:
		print("  ok   %s" % what)
	else:
		_failures += 1
		print("  FAIL %s — got %s, expected %s" % [what, got, expected])
