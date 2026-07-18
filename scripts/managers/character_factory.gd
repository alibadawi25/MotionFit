extends Node
## CharacterFactory
##
## Builds the personalised in-game character. The model itself is produced by
## the Python generator (assets/models/generated_human/export_glb.py): body
## shape is derived from the profile's physical attributes (sex, age, height,
## weight — the same ones calorie estimation uses), and the look (hair, outfit,
## colors) comes from the profile's appearance (see ProfileManager). The
## generated GLB is cached per profile under user://characters/ and only
## regenerated when its inputs change, then loaded at runtime via GLTFDocument
## (no editor import step needed).
##
## Generation shells out to `python`, the same external dependency the pose
## service already requires (see run.bat). If Python or the generator fails,
## everything falls back to the bundled default model, so the game always has
## a figure to show.

## The procedural model generator. Also the source of truth for the style and
## color catalogs mirrored below — keep them in sync.
const EXPORT_SCRIPT: String = "res://assets/models/generated_human/export_glb.py"
## The pre-built default figure shipped with the game, used whenever a
## personalised model can't be generated or loaded.
const FALLBACK_MODEL: String = "res://assets/models/generated_human/human.glb"
## Where per-profile models live: user://characters/<profile_id>.glb, next to a
## .args sidecar recording the inputs the GLB was generated from.
const OUT_DIR: String = "user://characters"
## Interpreter used to run the generator (resolved from PATH, like run.bat).
const PYTHON: String = "python"

# --- Catalogs (mirroring export_glb.py) --------------------------------------
# Style names are passed straight to the generator; colors are named entries in
# its tables, with the RGB duplicated here so UI can draw swatches. "auto" hair
# is resolved by the generator to the sex default (short male / long female).

const HAIR_STYLES: Array[String] = [
	"auto", "short", "long", "ponytail", "bun", "spiky", "bald"]
const TOP_STYLES: Array[String] = ["tshirt", "longsleeve", "tank"]
const BOTTOM_STYLES: Array[String] = ["pants", "shorts"]

const HAIR_COLORS: Dictionary = {
	"brown": Color(0.25, 0.16, 0.13),
	"black": Color(0.09, 0.08, 0.09),
	"blonde": Color(0.85, 0.70, 0.35),
	"red": Color(0.55, 0.22, 0.10),
	"gray": Color(0.62, 0.62, 0.64),
	"blue": Color(0.20, 0.35, 0.80),
}
const TOP_COLORS: Dictionary = {
	"blue": Color(0.45, 0.70, 0.90),
	"red": Color(0.82, 0.25, 0.22),
	"green": Color(0.30, 0.65, 0.38),
	"purple": Color(0.55, 0.35, 0.75),
	"black": Color(0.15, 0.15, 0.17),
	"white": Color(0.92, 0.92, 0.94),
	"orange": Color(0.95, 0.55, 0.15),
}
const BOTTOM_COLORS: Dictionary = {
	"navy": Color(0.22, 0.26, 0.36),
	"black": Color(0.13, 0.13, 0.15),
	"khaki": Color(0.76, 0.69, 0.50),
	"gray": Color(0.45, 0.45, 0.48),
	"jeans": Color(0.30, 0.42, 0.58),
}
const SKIN_TONES: Dictionary = {
	"light": Color(0.98, 0.83, 0.70),
	"tan": Color(0.87, 0.67, 0.51),
	"brown": Color(0.62, 0.43, 0.29),
	"dark": Color(0.42, 0.28, 0.19),
}


## Returns a freshly instantiated character for the ACTIVE profile, generating
## its GLB first if the profile's body or appearance changed since last time.
## Falls back to the bundled default model when there is no active profile or
## generation/loading fails, and to null only if even that is missing — so
## callers keep their own last-resort placeholder (player.gd keeps its capsule).
func get_character() -> Node3D:
	if ProfileManager.has_active():
		var out_path: String = "%s/%s.glb" % [OUT_DIR, ProfileManager.get_active_id()]
		var path: String = _ensure_generated(
			_active_body(), ProfileManager.get_appearance(), out_path)
		if path != "":
			var figure: Node3D = _load_glb(path)
			if figure != null:
				return figure
	var packed: PackedScene = load(FALLBACK_MODEL)
	return packed.instantiate() as Node3D if packed != null else null


## Builds a stock (non-profile) figure — e.g. an AI race rival — from explicit
## [param body] and [param appearance] (same shapes as [method build_preview]),
## cached under user://characters/<slot>.glb like profile models (same inputs →
## no regeneration). Falls back to the bundled default model when generation or
## loading fails, so callers always get a figure unless even that is missing.
func build_stock(body: Dictionary, appearance: Dictionary, slot: String) -> Node3D:
	var path: String = _ensure_generated(body, appearance,
			"%s/%s.glb" % [OUT_DIR, slot])
	if path != "":
		var figure: Node3D = _load_glb(path)
		if figure != null:
			return figure
	var packed: PackedScene = load(FALLBACK_MODEL)
	return packed.instantiate() as Node3D if packed != null else null


## Builds a throwaway preview figure from UNSAVED editor state — [param body]
## ({sex, age, height_cm, weight_kg}) and [param appearance] (the keys of
## ProfileManager.DEFAULT_APPEARANCE) — so a customization screen can show the
## result live before the player hits Save. Cached like profile models (same
## inputs → no regeneration), under a single shared preview slot.
func build_preview(body: Dictionary, appearance: Dictionary) -> Node3D:
	var path: String = _ensure_generated(body, appearance, OUT_DIR + "/preview.glb")
	return _load_glb(path) if path != "" else null


# --- Internals ----------------------------------------------------------------

## The active profile's body attributes in the shape _build_args expects.
func _active_body() -> Dictionary:
	return {
		"sex": ProfileManager.get_sex(),
		"age": ProfileManager.get_age(),
		"height_cm": ProfileManager.get_height_cm(),
		"weight_kg": ProfileManager.get_weight_kg(),
	}


## Makes sure [param out_path] holds a GLB generated from exactly these inputs,
## running the Python generator only when they differ from the .args sidecar of
## the previous run (~0.15 s when it does run). Returns [param out_path], or ""
## when generation failed (missing Python, bad exit, no file written).
func _ensure_generated(body: Dictionary, appearance: Dictionary,
		out_path: String) -> String:
	var args: PackedStringArray = _build_args(body, appearance, out_path)
	var stamp: String = " ".join(args)
	var sidecar: String = out_path + ".args"
	if FileAccess.file_exists(out_path) and _read_text(sidecar) == stamp:
		return out_path  # up to date; skip the generator entirely

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var output: Array = []
	var exit_code: int = OS.execute(PYTHON, args, output, true)
	if exit_code != 0 or not FileAccess.file_exists(out_path):
		push_warning("CharacterFactory: model generation failed (exit %d): %s"
				% [exit_code, "".join(PackedStringArray(output))])
		return ""
	_write_text(sidecar, stamp)
	return out_path


## Translates profile data into the generator's CLI. The generator only accepts
## male/female (it shapes the mesh), so "unspecified" renders as the default
## male build; "auto" hair is omitted so the generator picks the sex default.
func _build_args(body: Dictionary, appearance: Dictionary,
		out_path: String) -> PackedStringArray:
	var sex: String = String(body.get("sex", "male"))
	if sex != "male" and sex != "female":
		sex = "male"
	var args := PackedStringArray([
		ProjectSettings.globalize_path(EXPORT_SCRIPT),
		"--sex", sex,
		"--age", str(int(body.get("age", 30))),
		"--height", str(float(body.get("height_cm", 170.0))),
		"--weight", str(float(body.get("weight_kg", 70.0))),
		"--hair-color", String(appearance.get("hair_color", "brown")),
		"--top", String(appearance.get("top", "tshirt")),
		"--top-color", String(appearance.get("top_color", "blue")),
		"--bottom", String(appearance.get("bottom", "pants")),
		"--bottom-color", String(appearance.get("bottom_color", "navy")),
		"--skin", String(appearance.get("skin", "light")),
		"--out", ProjectSettings.globalize_path(out_path),
	])
	var hair: String = String(appearance.get("hair", "auto"))
	if hair != "auto":
		args.append_array(PackedStringArray(["--hair", hair]))
	return args


## Parses a GLB at runtime (works for user:// files, which have no editor
## import) and returns its scene — same node layout and animation clips as the
## editor-imported bundled model, so player.gd treats both identically.
func _load_glb(path: String) -> Node3D:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(path, state) != OK:
		push_warning("CharacterFactory: could not parse %s" % path)
		return null
	return doc.generate_scene(state) as Node3D


func _read_text(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_as_text() if f != null else ""


func _write_text(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
