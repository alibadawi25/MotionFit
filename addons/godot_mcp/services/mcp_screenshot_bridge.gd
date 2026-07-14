extends Node
## Captures editor/game viewport screenshots on demand.
##
## A request is a small JSON file dropped in the Godot user data dir. Exactly one
## running instance must answer it, which is trickier than it looks because the
## editor and any number of game instances can all be alive at once, and every
## one of them polls the same request file:
##
##   * A request carries a "target" ("game" or, by default, the editor). Only a
##     runtime of the matching kind handles it — and, crucially, a runtime of the
##     *other* kind leaves the file untouched instead of consuming it, so it can't
##     swallow a request meant for its sibling.
##   * A request may carry a "token". When it does, only the instance launched
##     with a matching --shot-token=<token> user arg answers; every other game
##     instance ignores it. This is what lets tools/shot.sh screenshot a specific
##     instance it launched without a second running game stealing the shot.

const REQUEST_FILE := "mcp_screenshot_req.json"
const RESPONSE_FILE := "mcp_screenshot_res.png"
const META_FILE := "mcp_screenshot_meta.json"
const TOKEN_ARG_PREFIX := "--shot-token="

var _my_token: String = ""


func _ready() -> void:
	# Command-line args never change during a run, so resolve our token once.
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with(TOKEN_ARG_PREFIX):
			_my_token = arg.trim_prefix(TOKEN_ARG_PREFIX)
			break


func _process(_delta: float) -> void:
	_handle_request(not Engine.is_editor_hint())


func _handle_request(is_game: bool) -> void:
	var req_path := _user_path(REQUEST_FILE)
	if not FileAccess.file_exists(req_path):
		return

	var req: Variant = JSON.parse_string(FileAccess.get_file_as_string(req_path))
	if not (req is Dictionary):
		req = {}

	# Only the matching runtime kind handles the request; the other kind leaves
	# the file in place so it doesn't consume its sibling's request.
	var wants_game: bool = req.get("target", "") == "game"
	if wants_game != is_game:
		return

	# If the request is addressed to a specific launched instance, only that
	# instance answers. A mismatch leaves the file for the intended instance.
	var want_token: String = String(req.get("token", ""))
	if want_token != "" and want_token != _my_token:
		return

	DirAccess.remove_absolute(req_path)
	_capture_viewport()


func _capture_viewport() -> void:
	var viewport := get_viewport()
	if viewport == null:
		return
	var tex := viewport.get_texture()
	if tex == null:
		return
	var img := tex.get_image()
	if img:
		img.save_png(_user_path(RESPONSE_FILE))
		var meta := FileAccess.open(_user_path(META_FILE), FileAccess.WRITE)
		if meta:
			meta.store_string(JSON.stringify({"width": img.get_width(), "height": img.get_height()}))
			meta.close()


func _user_path(file: String) -> String:
	return OS.get_user_data_dir().path_join(file)
