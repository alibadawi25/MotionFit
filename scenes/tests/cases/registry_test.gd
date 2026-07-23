extends TestCase
## RegistryTest
##
## Pins the game registry: the folder scan that discovers `game.tres`, the
## contract each [GameDef] must satisfy, and the launcher ordering.
##
## This is the platform's most load-bearing piece of data — every screen in the
## flow reads it, and a game that fails to register simply vanishes from the
## launcher with no error on screen. The scan is also the one thing that behaves
## differently in an exported build (text resources are packed as `.remap`), so
## it is exactly the code most likely to work in the editor and fail in a ship
## build. See GameManager._find_game_defs.


func _run() -> void:
	var games: Array[GameDef] = GameManager.get_games()

	check("the scan finds games at all", not games.is_empty())
	check("every shipped game folder registered", games.size() >= 6)

	# Each entry must be complete enough to render a card and launch a scene.
	var seen: Dictionary = {}
	for game in games:
		check("'%s' is a valid definition" % game.id, game.is_valid())
		check_eq("'%s' has a unique id" % game.id, seen.has(game.id), false)
		seen[game.id] = true
		check("'%s' scene path is a .tscn" % game.id, game.scene.ends_with(".tscn"))
		check("'%s' has a description" % game.id, not game.description.is_empty())

	# An available game promises a scene that actually exists — this is the check
	# that turns "Coming Soon flipped too early" into a test failure instead of a
	# black screen after the countdown.
	for game in games:
		if game.available:
			check("available game '%s' has a real scene" % game.id,
					ResourceLoader.exists(game.scene))

	# The four built games must be launchable, and the two planned ones must not
	# be — a regression either way is immediately visible to the player.
	for id in ["open_world", "runner", "sprint", "boxing"]:
		check("'%s' is available" % id, GameManager.is_available(id))
	for id in ["football", "tennis"]:
		check_eq("'%s' is still Coming Soon" % id, GameManager.is_available(id), false)

	# Ordering is curated, not filesystem order: Open World first (the gentlest
	# on-ramp), and the roster must be stably sorted.
	check_eq("Open World leads the launcher", games[0].id, "open_world")
	var orders: Array[int] = []
	for game in games:
		orders.append(game.sort_order)
	var sorted_orders: Array[int] = orders.duplicate()
	sorted_orders.sort()
	check_eq("roster is in sort_order", orders, sorted_orders)

	# Free-roam has no fail state, so it must skip the intensity picker; the
	# scored games must not.
	check_eq("Open World skips difficulty",
			GameManager.uses_difficulty("open_world"), false)
	check("Zombie Run uses difficulty", GameManager.uses_difficulty("runner"))

	# Lookups must be honest about misses rather than returning a blank entry
	# that renders as an empty card.
	check_eq("unknown id returns null", GameManager.get_game("no_such_game"), null)
	check_eq("unknown id has no title", GameManager.get_game_title("no_such_game"), "")
	check_eq("unknown id is not available", GameManager.is_available("no_such_game"), false)

	_check_discovery_ids()


## The discovery achievements a game contributes are keyed by id to the landmarks
## its world actually builds, but the two lists live in different files on
## purpose (the catalogue must be readable without loading the world). Nothing at
## runtime would report a mismatch — an unlock simply never fires — so the
## agreement is asserted here instead. See scenes/open-world/achievements.tres.
func _check_discovery_ids() -> void:
	var declared_set: AchievementSet = load("res://scenes/open-world/achievements.tres")
	var placed: Array = load("res://scenes/open-world/world_scatter.gd").get("SECRETS")

	var declared_ids: Array[String] = []
	for entry in declared_set.achievements:
		if entry.is_discovery():
			declared_ids.append(entry.id.trim_prefix("secret_"))
	var placed_ids: Array[String] = []
	for secret in placed:
		placed_ids.append(String(secret["id"]))
	declared_ids.sort()
	placed_ids.sort()

	check_eq("declared discoveries match the landmarks the world builds",
			declared_ids, placed_ids)

	# And the platform must have actually picked them up through the generic
	# folder scan — this is what proves the inversion works, not just that the
	# data agrees.
	var catalogue: Array[String] = []
	for defn in AchievementManager.get_discoveries():
		catalogue.append(defn.id.trim_prefix("secret_"))
	catalogue.sort()
	check_eq("AchievementManager collected them from the game folder",
			catalogue, declared_ids)
