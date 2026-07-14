extends Node
## ProfileManager
##
## Owns the single player profile: identity, XP/level, lifetime calories,
## unlocked achievements, and per-game statistics. It is the authority on
## progression maths (XP curve, levelling) so no game re-implements it — a game
## just reports a result and this manager awards XP consistently.
##
## Persistence is delegated to SaveManager. Must initialise after SaveManager.

## Emitted when XP changes. [param total_xp] is the new lifetime total.
signal xp_changed(total_xp: int)
## Emitted when the player reaches a new level.
signal leveled_up(new_level: int)
## Emitted when a new achievement is unlocked.
signal achievement_unlocked(achievement_id: String)

const SAVE_FILE: String = "profile.json"
## XP required for each level is BASE_XP * level. Simple, tunable, and cheap.
const BASE_XP_PER_LEVEL: int = 100

var _profile: Dictionary = _default_profile()

func _ready() -> void:
	_profile = SaveManager.load_data(SAVE_FILE, _default_profile())
	for key in _default_profile():
		if not _profile.has(key):
			_profile[key] = _default_profile()[key]


## Returns the total lifetime XP.
func get_xp() -> int:
	return int(_profile["xp"])


## Returns the current level derived from total XP.
func get_level() -> int:
	return level_for_xp(get_xp())


## Returns the player's display name.
func get_display_name() -> String:
	return String(_profile["display_name"])


## True once the player has completed first-run onboarding (entered their
## physical attributes). Drives the one-time onboarding gate in the main menu;
## it is NOT inferred from the attribute values, since real defaults are valid.
func is_onboarded() -> bool:
	return bool(_profile["onboarded"])


## Marks onboarding complete and persists. Called by the setup screen after the
## player confirms their attributes, so the gate never shows again.
func mark_onboarded() -> void:
	if bool(_profile["onboarded"]):
		return
	_profile["onboarded"] = true
	_save()


## Returns total lifetime calories burned.
func get_total_calories() -> float:
	return float(_profile["total_calories"])


## Body mass in kilograms — the key input to calorie estimation (kcal scales
## directly with it). Defaults to a neutral 70 kg until the player sets it.
func get_weight_kg() -> float:
	return float(_profile["weight_kg"])


## Standing height in centimetres. Not yet used by the motion calorie model but
## needed for heart-rate-based estimates once a wearable is wired in.
func get_height_cm() -> float:
	return float(_profile["height_cm"])


## Player age in years. Feeds heart-rate-based calorie estimates (Keytel et al.).
func get_age() -> int:
	return int(_profile["age"])


## Biological sex used for calorie formulas: "male", "female", or "unspecified"
## (the neutral default, which uses an average of the male/female coefficients).
func get_sex() -> String:
	return String(_profile["sex"])


## Sets the physical attributes that calorie estimation depends on and persists
## them. Pass -1 / "" to leave a field unchanged. Clamped to sane human ranges so
## a bad entry can't produce absurd calorie numbers.
func set_physical_attributes(weight_kg: float = -1.0, height_cm: float = -1.0,
		age: int = -1, sex: String = "") -> void:
	if weight_kg > 0.0:
		_profile["weight_kg"] = clampf(weight_kg, 20.0, 300.0)
	if height_cm > 0.0:
		_profile["height_cm"] = clampf(height_cm, 80.0, 250.0)
	if age > 0:
		_profile["age"] = clampi(age, 5, 120)
	if sex != "":
		_profile["sex"] = sex
	_save()


## Adds [param amount] XP, persists, and emits progression signals. Returns the
## new level (which may be unchanged).
func add_xp(amount: int) -> int:
	if amount <= 0:
		return get_level()
	var old_level: int = get_level()
	_profile["xp"] = get_xp() + amount
	var new_level: int = get_level()
	_save()
	xp_changed.emit(get_xp())
	if new_level > old_level:
		leveled_up.emit(new_level)
	return new_level


## Adds [param calories] to the lifetime total and persists.
func add_calories(calories: float) -> void:
	if calories <= 0.0:
		return
	_profile["total_calories"] = get_total_calories() + calories
	_save()


## Unlocks [param achievement_id] if not already unlocked.
func unlock_achievement(achievement_id: String) -> void:
	var unlocked: Array = _profile["achievements"]
	if achievement_id in unlocked:
		return
	unlocked.append(achievement_id)
	_save()
	achievement_unlocked.emit(achievement_id)


## Records a finished game [param result] (see the GameResult schema in
## CONTEXT.md): updates play counts, best score, calories and XP for the game.
func record_game_result(result: Dictionary) -> void:
	var game_id: String = String(result.get("game_id", "unknown"))
	var stats: Dictionary = _profile["game_stats"]
	var entry: Dictionary = stats.get(game_id, {"plays": 0, "best_score": 0})
	entry["plays"] = int(entry.get("plays", 0)) + 1
	entry["best_score"] = maxi(int(entry.get("best_score", 0)), int(result.get("score", 0)))
	stats[game_id] = entry
	_profile["game_stats"] = stats
	_save()
	add_calories(float(result.get("calories", 0.0)))
	add_xp(int(result.get("xp_earned", 0)))


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


func _save() -> void:
	SaveManager.save_data(SAVE_FILE, _profile)


func _default_profile() -> Dictionary:
	return {
		"display_name": "Player",
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
	}
