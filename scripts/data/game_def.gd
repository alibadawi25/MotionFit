extends Resource
## GameDef
##
## One mini-game's entry in the launcher, as typed data instead of a
## string-keyed Dictionary. Every game owns a `game.tres` beside its scene
## (`scenes/<game>/game.tres`); GameManager discovers them at boot, so adding a
## game is a new folder — no edit to any shared platform file.
##
## Keeping the definition IN the game's folder is what makes a game a genuinely
## self-contained unit: deleting `scenes/football/` removes it from the launcher
## with no dangling reference left behind. Typing it as a Resource means the
## fields are inspector-editable and a mistyped key is a load-time error rather
## than a silently-empty Dictionary lookup at runtime.
##
## See CONTEXT.md §2 (data-driven over hardcoded) and GameManager.
class_name GameDef

## Stable registry id. Used as the save key for best scores, the achievement
## stat key, and the preview-image lookup — so it must never change once a game
## has shipped, even if the title does.
@export var id: String = ""

## Display name shown on the Game Select card and results screen.
@export var title: String = ""

## One-line pitch on the card. Written to say what the BODY does, not what the
## fiction is — the card is the last thing between the player and moving.
@export_multiline var description: String = ""

## The game's root scene. Loaded by GameManager.start_selected_game(); its root
## node must extend MiniGame. Left pointing at a not-yet-built path for a
## "Coming Soon" entry, which is why this is a path and not a PackedScene: an
## unavailable game has no scene to reference yet.
@export_file("*.tscn") var scene: String = ""

## Whether the game is playable. False renders it as a "Coming Soon" tile and
## refuses to launch. Flip to true once the scene exists — no other change.
@export var available: bool = false

## Whether the flow stops at the intensity picker before starting. Free-roam
## games with no fail state (Open World) skip it, since difficulty would change
## nothing. Defaults true so a new game gets the full flow unless it opts out.
@export var uses_difficulty: bool = true

## Position in the launcher. Lower sorts first; ties fall back to id so the
## order is stable rather than filesystem-dependent. Explicit because the roster
## is curated (the gentlest on-ramp first), not alphabetical.
@export var sort_order: int = 100


## True when this definition is complete enough to register. An entry missing
## its id or scene is a broken file, not a "Coming Soon" — GameManager reports
## and skips it rather than surfacing a blank card.
func is_valid() -> bool:
	return not id.is_empty() and not scene.is_empty() and not title.is_empty()
