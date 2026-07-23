@tool
extends SceneTree
## One-off generator: builds the AchievementSet .tres files from the tables that
## used to live in achievement_manager.gd / scenes/open-world/achievements.gd.
##
## Kept in tools/ (excluded from the export) as a record of how the resources
## were produced — rerunning it regenerates them byte-for-byte, so a future bulk
## edit can be made here rather than by hand across two dozen sub-resources.
##
## Run: Godot --headless --path . -s res://tools/gen_achievements.gd

const CAREER := [
	["first_workout", "FIRST MOVE", "★", "Finish your first workout.", "sessions", 1.0, "workouts"],
	["sessions_5", "SHOWING UP", "★", "Finish 5 workouts.", "sessions", 5.0, "workouts"],
	["sessions_25", "THE REGULAR", "★", "Finish 25 workouts.", "sessions", 25.0, "workouts"],
	["sessions_100", "PART OF YOU", "★", "Finish 100 workouts.", "sessions", 100.0, "workouts"],
	["streak_3", "THREE IN A ROW", "♥", "Work out 3 days in a row.", "streak", 3.0, "days"],
	["streak_7", "FULL WEEK", "♥", "Work out 7 days in a row.", "streak", 7.0, "days"],
	["streak_14", "HABIT FORMED", "♥", "Work out 14 days in a row.", "streak", 14.0, "days"],
	["calories_100", "FIRST BURN", "♦", "Burn 100 calories all-time.", "calories", 100.0, "kcal"],
	["calories_1000", "SLOW FIRE", "♦", "Burn 1,000 calories all-time.", "calories", 1000.0, "kcal"],
	["calories_10000", "FURNACE", "♦", "Burn 10,000 calories all-time.", "calories", 10000.0, "kcal"],
	["steps_5k", "FINDING YOUR FEET", "▲", "Take 5,000 steps all-time.", "steps", 5000.0, "steps"],
	["steps_25k", "WANDERER", "▲", "Take 25,000 steps all-time.", "steps", 25000.0, "steps"],
	["steps_100k", "UNSTOPPABLE", "▲", "Take 100,000 steps all-time.", "steps", 100000.0, "steps"],
	["session_20min", "GOING LONG", "✦", "Keep moving for 20 minutes in a single session.", "session_minutes", 20.0, "min"],
	["session_150kcal", "BIG BURN", "✦", "Burn 150 calories in a single session.", "session_calories", 150.0, "kcal"],
	["session_2500steps", "LONG HAUL", "✦", "Take 2,500 steps in a single session.", "session_steps", 2500.0, "steps"],
	["level_5", "RISING", "●", "Reach level 5.", "level", 5.0, "levels"],
	["level_10", "SEASONED", "●", "Reach level 10.", "level", 10.0, "levels"],
	["all_games", "TRIED EVERYTHING", "●", "Play every available game at least once.", "games_played", -1.0, "games"],
]

## Open World's hidden landmarks. `id` must match world_scatter.gd SECRETS —
## pinned by scenes/tests/cases/registry_test.gd.
const DISCOVERIES := [
	["grotto", "THE CRYSTAL GROTTO", "Something glitters inside the mountain's eastern flank."],
	["cairn", "THE SUMMIT CAIRN", "Someone stacked stones where the air runs thin."],
	["stones", "THE STANDING STONES", "Old giants stand in a circle on the western plateau."],
	["camp", "THE CASTAWAY CAMP", "Driftwood and embers in a lonely beach cove."],
	["hollow", "THE GLOWING HOLLOW", "A violet glow deep in the far-corner woods."],
]


func _init() -> void:
	var career: AchievementSet = AchievementSet.new()
	career.set_name = "career"
	for row in CAREER:
		career.achievements.append(_make(row[0], row[1], row[2], row[3], row[4], row[5], row[6]))
	_save(career, "res://data/achievements/career.tres")

	var ow: AchievementSet = AchievementSet.new()
	ow.set_name = "Open World"
	for row in DISCOVERIES:
		ow.achievements.append(_make("secret_%s" % row[0], row[1], "✦", row[2],
				"secret", 1.0, "", "discovery"))
	ow.achievements.append(_make("all_secrets", "CARTOGRAPHER", "✦",
			"Discover every hidden landmark in the Open World.",
			"secrets", float(DISCOVERIES.size()), "found"))
	_save(ow, "res://scenes/open-world/achievements.tres")

	quit()


func _make(id: String, title: String, icon: String, desc: String, stat: String,
		target: float, unit: String, category: String = "") -> AchievementDef:
	var a: AchievementDef = AchievementDef.new()
	a.id = id
	a.title = title
	a.icon = icon
	a.description = desc
	a.stat = stat
	a.target = target
	a.unit = unit
	a.category = category
	return a


func _save(res: Resource, path: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var err: int = ResourceSaver.save(res, path)
	print("%s -> %s" % ["OK " if err == OK else "FAIL", path])
