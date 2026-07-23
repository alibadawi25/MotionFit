extends Resource
## AchievementDef
##
## One achievement, as typed data. Replaces the string-keyed Dictionary the
## catalogue used to be: the fields are inspector-editable, a mistyped field is
## a load-time error instead of a silent `null` at unlock time, and every
## consumer (the achievements page, the results screen, the next-goal nudge)
## gets real autocomplete instead of guessing key names.
##
## Everything here is about effort and consistency, never skill — this is a
## fitness platform, so an achievement marks work done, not talent shown.
##
## Sets of these live in [AchievementSet] `.tres` files: the platform's own
## career list in `data/achievements/career.tres`, and one per game folder for
## the discoveries a game contributes (see AchievementManager).
class_name AchievementDef

## Stable unlock id, persisted into the profile. Never change one once shipped —
## a renamed id reads as "not unlocked" and takes the player's achievement away.
@export var id: String = ""

## Display name, shown upper-case on the card.
@export var title: String = ""

## A glyph the UI fonts render (★ ♥ ♦ ▲ ✦ ●), used as the card's icon.
@export var icon: String = "★"

## How to earn it, phrased as encouragement rather than instruction.
@export_multiline var description: String = ""

## Which tracked number this measures. See AchievementManager._stat_value for
## the supported set: career stats (`sessions`, `streak`, `calories`, `steps`,
## `level`, `games_played`, `secrets`) and per-session stats (`session_minutes`,
## `session_calories`, `session_steps`), plus `secret` for a single landmark.
@export var stat: String = ""

## The number [member stat] must reach. **-1 defers it to runtime** for targets
## that depend on live data — "play every available game" tracks however many
## games are available today, so it can't be a constant.
@export var target: float = 1.0

## Progress unit shown after the numbers ("workouts", "kcal", "days").
@export var unit: String = ""

## Empty for a normal achievement; "discovery" for a hidden landmark, which the
## achievements page shelves separately and which only walking into the place
## itself can unlock.
@export var category: String = ""


## Whether [member target] is resolved at runtime rather than fixed here.
func has_deferred_target() -> bool:
	return target < 0.0


## Whether this is a hidden-landmark entry (shelved apart, unlocked only by
## [method AchievementManager.report_discovery]).
func is_discovery() -> bool:
	return category == "discovery"
