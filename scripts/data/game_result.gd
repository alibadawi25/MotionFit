extends RefCounted
## GameResult
##
## What one finished session produced. This is the contract between a game and
## the platform: [MiniGame] fills it in, [GameManager] adds what the session
## CHANGED, and the results screen, profile, activity log and achievements all
## read it. Every one of the 20+ games goes through this same object.
##
## It used to be a string-keyed Dictionary, which meant every consumer wrote
## `float(result.get("duration_sec", 0.0))` and a typo produced a silent zero on
## the summary screen rather than an error. Typed fields make a wrong name a
## parse error and give the defaults one home instead of one per call site.
##
## [b]RefCounted, not Resource[/b]: a result is never authored in the editor and
## never written to disk (the profile stores only the derived play count and best
## score). Making it a Resource would hand it a resource_path and save/load
## semantics it has no use for. Compare [GameDef] and [AchievementDef], which are
## authored as `.tres` and therefore genuinely are Resources.
class_name GameResult

# --- Reported by the game (via MiniGame) ------------------------------------

## Registry id of the game that produced this. See [GameDef].
var game_id: String = ""
## Points scored. Free-roam games leave this 0 — it is not the only measure of a
## session, and calories/steps below still count fully.
var score: int = 0
## Wall-clock seconds of gameplay, excluding the intro countdown.
var duration_sec: float = 0.0
## Net exercise calories measured by the motion pipeline (energy ABOVE resting,
## so standing in frame costs nothing).
var calories: float = 0.0
## XP earned, normally score × [constant MiniGame.XP_PER_SCORE].
var xp_earned: int = 0
## Steps the pose service counted this session.
var steps: int = 0
## Mean steps per minute across the session.
var avg_cadence: float = 0.0
## Mean metabolic equivalent — the effort level, independent of body mass.
var avg_met: float = 0.0
## Mean and peak heart rate in bpm; 0 means no wearable was streaming.
var avg_heart_rate: float = 0.0
var peak_heart_rate: float = 0.0

# --- Daily Challenge ---------------------------------------------------------

## True when this session was launched as today's Daily Challenge. Explicit
## rather than inferred from [member workout_title] being non-empty, so an
## untitled plan can't silently stop counting as a challenge.
var is_workout: bool = false
## The challenge's title, for the results kicker.
var workout_title: String = ""
## Whether the prescribed interval timeline ran to completion. A challenge that
## was cut short still banks everything above — it just isn't celebrated as done.
var workout_completed: bool = false

# --- Derived by GameManager.finish_game -------------------------------------
# These describe what the session CHANGED, so they are snapshotted BEFORE the
# result is recorded. Computing them afterwards would compare the new state with
# itself and report "no change" for every session.

## Whether [member score] beat the stored record for this game.
var new_best: bool = false
## The record before this session.
var prev_best: int = 0
## Level before and after this session's XP was banked.
var level_before: int = 1
var level_after: int = 1
## Whether [member level_after] is higher than [member level_before].
var leveled_up: bool = false
## Lifetime XP after banking this session.
var total_xp: int = 0


## Whether this session finished today's Daily Challenge outright — the one case
## the results screen celebrates with the gold treatment.
func completed_challenge() -> bool:
	return is_workout and workout_completed
