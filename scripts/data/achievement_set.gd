extends Resource
## AchievementSet
##
## A named list of [AchievementDef]s, saved as one `.tres`. Two kinds exist and
## they are loaded by the same code:
##
##   - `data/achievements/career.tres` — the platform's own career/session list.
##   - `scenes/<game>/achievements.tres` — the discoveries a game contributes,
##     which is how a game adds achievements without the platform naming it.
##
## One file per SET rather than one per achievement: the catalogue is read and
## reasoned about as a whole (the page groups it, the next-goal nudge scans it),
## and nineteen single-entry files would be worse to edit, not better.
class_name AchievementSet

## Where these came from, for error messages ("career", "Open World").
@export var set_name: String = ""

## The achievements themselves, in display order.
@export var achievements: Array[AchievementDef] = []


## Every id in this set — used to check a game's contribution against the world
## it actually builds.
func ids() -> Array[String]:
	var out: Array[String] = []
	for a in achievements:
		out.append(a.id)
	return out
