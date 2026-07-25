extends Node
## ProfileManager
##
## Owns the roster of player profiles — one per person who shares this device —
## and the currently ACTIVE one. Each profile carries its own identity, XP/level,
## lifetime calories, achievements, per-game stats, physical attributes (for
## calorie estimation) and body calibration (for the camera pose mapping). Every
## legacy getter/setter here operates on the ACTIVE profile, so games and screens
## that just "read the profile" keep working unchanged — switching who's playing
## swaps the whole dataset underneath them.
##
## It is also the authority on progression maths (XP curve, levelling) so no game
## re-implements it. Persistence is delegated to SaveManager. Must initialise
## after SaveManager.

## Emitted when XP changes. [param total_xp] is the new lifetime total.
signal xp_changed(total_xp: int)
## Emitted when the player reaches a new level.
signal leveled_up(new_level: int)
## Emitted when a new achievement is unlocked.
signal achievement_unlocked(achievement_id: String)
## Emitted when the active profile changes (also on first selection). [param
## profile_id] is the now-active id. Other managers (ActivityManager, MotionManager)
## listen so their per-profile data / calibration follows the active player.
signal profile_switched(profile_id: String)
## Emitted whenever the roster changes (add / delete / rename), so a profile
## picker can refresh without knowing what changed.
signal roster_changed

## Roster file: { "active_id": <id>, "profiles": { <id>: <profile>, ... } }.
const SAVE_FILE: String = "profiles.json"
## The pre-multi-profile single-profile file, migrated into the roster on first run.
const LEGACY_SAVE_FILE: String = "profile.json"
## XP required for each level is BASE_XP * level. Simple, tunable, and cheap.
const BASE_XP_PER_LEVEL: int = 100
## Default character look. Values are the option/color names understood by the
## model generator (see CharacterFactory and export_glb.py's catalogs). "auto"
## hair means "let the generator pick by sex" (short male / long female).
const DEFAULT_APPEARANCE: Dictionary = {
	"hair": "auto", "hair_color": "brown",
	"top": "tshirt", "top_color": "blue",
	"bottom": "pants", "bottom_color": "navy",
	"skin": "light",
}

var _profiles: Dictionary = {}   # id (String) -> profile Dictionary
var _active_id: String = ""

func _ready() -> void:
	_load()


# --- Roster ------------------------------------------------------------------

## True once at least one profile exists (else the app sends the player through
## first-run onboarding to create one).
func has_profiles() -> bool:
	return not _profiles.is_empty()


## True while a valid profile is selected.
func has_active() -> bool:
	return _profiles.has(_active_id)


## True when the active profile was migrated from the pre-multi-profile save, so
## ActivityManager can adopt the old shared daily log for it (once).
func active_is_migrated() -> bool:
	return bool(_active().get("migrated_legacy", false))


## The active profile's id ("" when none is selected).
func get_active_id() -> String:
	return _active_id


## Lightweight roster listing for a profile picker, newest-created last. Each entry:
## { "id", "name", "level", "onboarded", "calibrated" }.
func list_profiles() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id in _profiles:
		var p: Dictionary = _profiles[id]
		out.append({
			"id": id,
			"name": String(p.get("name", "Player")),
			"level": level_for_xp(int(p.get("xp", 0))),
			"onboarded": bool(p.get("onboarded", false)),
			"calibrated": not (p.get("calibration", {}) as Dictionary).is_empty(),
		})
	out.sort_custom(func(a, b): return int(a.get("created", 0)) < int(b.get("created", 0)))
	return out


## Creates a new profile named [param name], makes it active, and returns its id.
## New profiles start un-onboarded so the setup flow collects their body data.
func create_profile(name: String) -> String:
	var id: String = _new_id()
	var prof: Dictionary = _default_profile()
	prof["id"] = id
	prof["name"] = _clean_name(name)
	prof["created"] = int(Time.get_unix_time_from_system())
	_profiles[id] = prof
	_active_id = id
	_save()
	roster_changed.emit()
	profile_switched.emit(_active_id)
	return id


## Switches the active profile. No-op if [param id] is unknown or already active.
func select_profile(id: String) -> void:
	if id == _active_id or not _profiles.has(id):
		return
	_active_id = id
	_save()
	profile_switched.emit(_active_id)


## Deletes profile [param id] and its scoped data. If it was active, another
## profile becomes active (or none, sending the player back to the picker).
func delete_profile(id: String) -> void:
	if not _profiles.has(id):
		return
	_profiles.erase(id)
	if _active_id == id:
		_active_id = _profiles.keys()[0] if not _profiles.is_empty() else ""
		profile_switched.emit(_active_id)
	_save()
	roster_changed.emit()


## Renames profile [param id] (defaults to the active profile).
func rename_profile(id: String = "", name: String = "") -> void:
	var target: String = id if id != "" else _active_id
	if not _profiles.has(target):
		return
	(_profiles[target] as Dictionary)["name"] = _clean_name(name)
	_save()
	roster_changed.emit()


# --- Active-profile identity & onboarding ------------------------------------

## Returns the active player's display name.
func get_display_name() -> String:
	return String(_active().get("name", "Player"))


## True once the active player has completed first-run onboarding (entered their
## physical attributes). Drives the one-time onboarding gate; it is NOT inferred
## from the attribute values, since real defaults are valid.
func is_onboarded() -> bool:
	return bool(_active().get("onboarded", false))


## Marks the active profile onboarded and persists.
func mark_onboarded() -> void:
	if not has_active() or bool(_active()["onboarded"]):
		return
	_active()["onboarded"] = true
	_save()


# --- Character appearance ------------------------------------------------------
# The player's chosen look for the in-game character (hair/outfit styles and
# colors). Body SHAPE is not stored here — CharacterFactory derives it from the
# physical attributes below, so losing weight in real life shows on the model.

## The active profile's appearance, with defaults filled in for any missing key
## (so saves from older builds render sensibly). Always safe to read.
func get_appearance() -> Dictionary:
	var merged: Dictionary = DEFAULT_APPEARANCE.duplicate()
	var stored: Dictionary = _active().get("appearance", {})
	for key in merged:
		if stored.has(key):
			merged[key] = String(stored[key])
	return merged


## Stores the active profile's appearance and persists. Only keys present in
## [constant DEFAULT_APPEARANCE] are accepted; others are ignored, so a stray
## dictionary can't bloat the save.
func set_appearance(appearance: Dictionary) -> void:
	if not has_active():
		return
	var current: Dictionary = get_appearance()
	for key in DEFAULT_APPEARANCE:
		if appearance.has(key):
			current[key] = String(appearance[key])
	_active()["appearance"] = current
	_save()


# --- Body calibration (camera pose mapping) ----------------------------------
# Captured by the Python pose service (Calibrator) and stored per-profile so each
# person's crouch depth / standing reference is theirs. MotionManager pushes the
# active profile's values to Python on switch; see its set_calibration().

## The active profile's calibration { "standing_ext", "squat_ext" }, or {} if the
## player hasn't calibrated yet.
func get_calibration() -> Dictionary:
	return (_active().get("calibration", {}) as Dictionary).duplicate()


## True once the active profile has a stored body calibration.
func has_calibration() -> bool:
	return not (_active().get("calibration", {}) as Dictionary).is_empty()


## Stores a freshly-captured calibration for the active profile and persists.
## [param standing_ext] / [param squat_ext] are the torso-normalised leg
## extensions the pose service measured at a full stand and the deepest squat.
func set_calibration(standing_ext: float, squat_ext: float) -> void:
	if not has_active():
		return
	_active()["calibration"] = {
		"standing_ext": standing_ext,
		"squat_ext": squat_ext,
		"captured": int(Time.get_unix_time_from_system()),
	}
	_save()


## Clears the active profile's calibration (falls back to the default crouch map).
func clear_calibration() -> void:
	if not has_active():
		return
	_active()["calibration"] = {}
	_save()


# --- Progression & stats (all on the active profile) -------------------------

## Returns the total lifetime XP.
func get_xp() -> int:
	return int(_active().get("xp", 0))


## Returns the current level derived from total XP.
func get_level() -> int:
	return level_for_xp(get_xp())


## Returns total lifetime calories burned.
func get_total_calories() -> float:
	return float(_active().get("total_calories", 0.0))


## Body mass in kilograms — the key input to calorie estimation (kcal scales
## directly with it). Defaults to a neutral 70 kg until the player sets it.
func get_weight_kg() -> float:
	return float(_active().get("weight_kg", 70.0))


## Standing height in centimetres. Not yet used by the motion calorie model but
## needed for heart-rate-based estimates once a wearable is wired in.
func get_height_cm() -> float:
	return float(_active().get("height_cm", 170.0))


## Player age in years. Feeds heart-rate-based calorie estimates (Keytel et al.).
func get_age() -> int:
	return int(_active().get("age", 30))


## Biological sex used for calorie formulas: "male", "female", or "unspecified"
## (the neutral default, which uses an average of the male/female coefficients).
func get_sex() -> String:
	return String(_active().get("sex", "unspecified"))


## Sets the physical attributes that calorie estimation depends on and persists
## them. Pass -1 / "" to leave a field unchanged. Clamped to sane human ranges so
## a bad entry can't produce absurd calorie numbers.
func set_physical_attributes(weight_kg: float = -1.0, height_cm: float = -1.0,
		age: int = -1, sex: String = "") -> void:
	if not has_active():
		return
	var p: Dictionary = _active()
	if weight_kg > 0.0:
		p["weight_kg"] = clampf(weight_kg, 20.0, 300.0)
	if height_cm > 0.0:
		p["height_cm"] = clampf(height_cm, 80.0, 250.0)
	if age > 0:
		p["age"] = clampi(age, 5, 120)
	if sex != "":
		p["sex"] = sex
	_save()


## Adds [param amount] XP, persists, and emits progression signals. Returns the
## new level (which may be unchanged).
func add_xp(amount: int) -> int:
	if amount <= 0 or not has_active():
		return get_level()
	var old_level: int = get_level()
	_active()["xp"] = get_xp() + amount
	var new_level: int = get_level()
	_save()
	xp_changed.emit(get_xp())
	if new_level > old_level:
		leveled_up.emit(new_level)
	return new_level


## Adds [param calories] to the lifetime total and persists.
func add_calories(calories: float) -> void:
	if calories <= 0.0 or not has_active():
		return
	_active()["total_calories"] = get_total_calories() + calories
	_save()


## Ids of every achievement the active profile has unlocked (a copy).
func get_achievements() -> Array:
	return (_active().get("achievements", []) as Array).duplicate()


## True when the active profile has unlocked [param achievement_id].
func has_achievement(achievement_id: String) -> bool:
	return achievement_id in (_active().get("achievements", []) as Array)


## Unlocks [param achievement_id] if not already unlocked.
func unlock_achievement(achievement_id: String) -> void:
	if not has_active():
		return
	var unlocked: Array = _active()["achievements"]
	if achievement_id in unlocked:
		return
	unlocked.append(achievement_id)
	_save()
	achievement_unlocked.emit(achievement_id)


## Best score recorded for [param game_id] so far (0 if never played). Lets the
## results screen tell the player they set a new record — read it BEFORE calling
## [method record_game_result], which updates it.
func get_best_score(game_id: String) -> int:
	var stats: Dictionary = _active().get("game_stats", {})
	var entry: Dictionary = stats.get(game_id, {})
	return int(entry.get("best_score", 0))


## Number of times [param game_id] has been played (0 if never).
func get_play_count(game_id: String) -> int:
	var stats: Dictionary = _active().get("game_stats", {})
	var entry: Dictionary = stats.get(game_id, {})
	return int(entry.get("plays", 0))


## Records a finished game [param result] (see the GameResult schema in
## CONTEXT.md): updates play counts, best score, calories and XP for the game.
func record_game_result(result: GameResult) -> void:
	if not has_active():
		return
	var game_id: String = result.game_id if not result.game_id.is_empty() else "unknown"
	var stats: Dictionary = _active()["game_stats"]
	var entry: Dictionary = stats.get(game_id, {"plays": 0, "best_score": 0})
	entry["plays"] = int(entry.get("plays", 0)) + 1
	entry["best_score"] = maxi(int(entry.get("best_score", 0)), result.score)
	stats[game_id] = entry
	_active()["game_stats"] = stats
	# One finished game = one write. The signals add_xp emits still fire, and the
	# in-memory state they hand to listeners is already correct.
	_batch_begin()
	_save()
	add_calories(result.calories)
	add_xp(result.xp_earned)
	_batch_end()


## Returns the XP-based level for an arbitrary [param xp] total. Static so UI
## can preview level thresholds without mutating state.
static func level_for_xp(xp: int) -> int:
	# level n requires cumulative BASE * (1+2+...+n). Solve incrementally.
	var level: int = 1
	var needed: int = BASE_XP_PER_LEVEL
	var remaining: int = xp
	while remaining >= needed:
		remaining -= needed
		level += 1
		needed = BASE_XP_PER_LEVEL * level
	return level


# --- Internals ---------------------------------------------------------------

func _active() -> Dictionary:
	return _profiles.get(_active_id, {})


func _load() -> void:
	var roster: Dictionary = SaveManager.load_data(SAVE_FILE, {})
	var profiles: Variant = roster.get("profiles", null)
	if profiles is Dictionary and not (profiles as Dictionary).is_empty():
		_profiles = profiles
		_active_id = String(roster.get("active_id", ""))
		_ensure_fields()
	elif SaveManager.has_save(LEGACY_SAVE_FILE):
		_migrate_legacy()
	else:
		_profiles = {}
		_active_id = ""
	# Guarantee the active id points at a real profile (or "" when the roster is
	# empty, which sends the player through onboarding).
	if not _profiles.has(_active_id):
		_active_id = _profiles.keys()[0] if not _profiles.is_empty() else ""


## Wraps the old single-profile save into the roster as the first profile, so an
## existing player keeps their progress, body data and history seamlessly.
func _migrate_legacy() -> void:
	var old: Dictionary = SaveManager.load_data(LEGACY_SAVE_FILE, {})
	var id: String = _new_id()
	var prof: Dictionary = _default_profile()
	for key in prof:
		if old.has(key):
			prof[key] = old[key]
	prof["id"] = id
	if old.has("display_name"):
		prof["name"] = String(old["display_name"])
	prof["created"] = int(Time.get_unix_time_from_system())
	# Tag the migrated profile so ActivityManager can adopt the legacy shared log.
	prof["migrated_legacy"] = true
	_profiles = {id: prof}
	_active_id = id
	_save()


## Back-fills any missing fields on loaded profiles (so a save from an older build
## gains new keys like calibration without a crash).
func _ensure_fields() -> void:
	var defaults: Dictionary = _default_profile()
	for id in _profiles:
		var p: Dictionary = _profiles[id]
		for key in defaults:
			if not p.has(key):
				p[key] = defaults[key]
		p["id"] = id


## Depth of the current [method _batch_begin] / [method _batch_end] pair, and
## whether anything asked to save while it was open.
##
## Every mutator here saves, which is what makes them individually safe to call.
## The cost only shows up when one logical event fans out into several of them:
## finishing a game writes game_stats, then calories, then XP, and each write is
## a full JSON re-encode of every profile plus a temp-file-and-rename — three
## disk round-trips at the exact moment the results screen is trying to animate
## in. Batching collapses them to one without making any single mutator unsafe.
var _batch_depth: int = 0
var _batch_dirty: bool = false


func _batch_begin() -> void:
	_batch_depth += 1


func _batch_end() -> void:
	_batch_depth = maxi(0, _batch_depth - 1)
	if _batch_depth == 0 and _batch_dirty:
		_batch_dirty = false
		_save()


func _save() -> void:
	if _batch_depth > 0:
		_batch_dirty = true
		return
	SaveManager.save_data(SAVE_FILE, {"active_id": _active_id, "profiles": _profiles})


func _new_id() -> String:
	# Time + randomness so two profiles made in the same second don't collide.
	return "p_%d_%04d" % [Time.get_unix_time_from_system(), randi() % 10000]


func _clean_name(name: String) -> String:
	var trimmed: String = name.strip_edges()
	return trimmed if not trimmed.is_empty() else "Player"


func _default_profile() -> Dictionary:
	return {
		"id": "",
		"name": "Player",
		"created": 0,
		# First-run onboarding flag (see is_onboarded). Explicit so a genuine
		# 70 kg / 30 yr player isn't mistaken for "hasn't filled anything in".
		"onboarded": false,
		"xp": 0,
		"total_calories": 0.0,
		"achievements": [],
		"game_stats": {},
		# Physical attributes for calorie estimation. Neutral defaults so numbers
		# are reasonable before the player fills these in via a profile screen.
		"weight_kg": 70.0,
		"height_cm": 170.0,
		"age": 30,
		"sex": "unspecified",
		# Character look ({} = all defaults; see get_appearance / DEFAULT_APPEARANCE).
		"appearance": {},
		# Body calibration captured by the pose service ({} = not calibrated).
		"calibration": {},
	}
