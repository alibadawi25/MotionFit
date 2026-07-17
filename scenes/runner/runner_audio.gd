extends Node
## RunnerAudio — Zombie Run's sound director
##
## The chase's ears. Everything you hear in the run comes from four one-shot
## clips (heartbeat, footstep, thunder, scream); this turns them into a scene by
## deciding WHEN each fires and re-voicing them with pitch and volume — a
## footstep dropped an octave and slowed is the zombie's drag, the same clip at
## half pitch is the crash when you hit a hazard, a scream pitched down and mixed
## far back is an unseen wail somewhere behind you.
##
## It exists because the game's whole tension design is unquantified: the player
## is told they're in trouble, never how much (see runner.gd / RunnerHud, and do
## not add a number). Sound is the third channel of that after the closing dark
## and the beat rate, and it obeys the same rule — nothing here reports a
## distance. Instead the mix creeps: the heartbeat hardens, and the zombie's
## footfalls rise out of nothing behind you as it gains. You feel the gap.
##
## Two things are worth knowing before changing this:
##   - The heartbeat is PHASE-LOCKED to runner.gd's beat, not on its own clock:
##     the caller passes the same [code]_beat_phase[/code] that drives the camera
##     zoom and the vignette's clench, so the thump you hear is the thump you
##     see. Feed it a private timer and the two drift apart within seconds.
##   - Playback goes through AudioManager's voice pool rather than local players,
##     so the SFX bus volume setting applies and overlapping sounds layer. The mix
##     is deliberately 2D, not positional: the zombie is behind the camera almost
##     the entire run, exactly where 3D panning is least useful, so its presence
##     is mixed by hand off the gap instead.
class_name RunnerAudio

const SFX_HEARTBEAT: AudioStream = preload("res://assets/audio/heartbeat_single.mp3")
const SFX_STEP: AudioStream = preload("res://assets/audio/step_single.mp3")
const SFX_THUNDER: AudioStream = preload("res://assets/audio/thunder.mp3")
const SFX_SCREAM: AudioStream = preload("res://assets/audio/zombie_scream.mp3")

## The heartbeat clip opens with this much silence before the "lub". Seeking past
## it is what puts the thump ON the beat instead of a fifth of a second late.
const BEAT_LEAD_SILENCE: float = 0.19
## Heartbeat voicing across the gap: a slow, soft resting thud when you're clear;
## hard and high in the chest when it's on you. The clip carries its own lub-dub
## pair, so pitch has to climb with the beat rate or the dub lands after the next
## beat has already started.
const BEAT_PITCH_CALM: float = 0.9
const BEAT_PITCH_PANIC: float = 1.45
const BEAT_DB_CALM: float = -17.0
const BEAT_DB_PANIC: float = -2.0

## Player footsteps. Quiet — they're a texture under the beat, not the show.
const STEP_DB_SLOW: float = -23.0
const STEP_DB_FAST: float = -10.0
## Landing from a jump lands harder and lower than a stride.
const LAND_DB: float = -7.0
const LAND_PITCH: float = 0.72
## Hitting a hazard: the same footstep, dropped far enough to read as a crash.
const STUMBLE_DB: float = -3.0
const STUMBLE_PITCH: float = 0.45

## The zombie's shamble. Below [constant ZSTEP_GAP_FLOOR] you can't hear it at
## all — silence behind you is the point — and from there it climbs to a heavy,
## close drag. Slow and deep: it doesn't run, it comes.
const ZSTEP_GAP_FLOOR: float = 0.22
const ZSTEP_HZ_FAR: float = 1.5
const ZSTEP_HZ_NEAR: float = 2.9
const ZSTEP_DB_FAR: float = -32.0
const ZSTEP_DB_NEAR: float = -8.0
const ZSTEP_PITCH: float = 0.58

## Thunder trails its flash — light first, then the sound rolls in — which is
## both how a storm works and a second, later beat of the same scare.
const THUNDER_DELAY_MIN: float = 0.35
const THUNDER_DELAY_MAX: float = 1.1
const THUNDER_DB: float = -13.0

## A distant wail: pitched down, mixed far back, and seeked past the scream's
## attack so it reads as something already howling out in the dark rather than
## starting up next to you. Cut short — the clip is 8 s long and the groans come
## every few seconds.
const GROAN_DB: float = -21.0
const GROAN_PITCH: float = 0.7
const GROAN_SEEK: float = 0.9
const GROAN_LEN: float = 2.2

var _beat_cycle: int = -1        # last whole beat played, for edge detection
var _zstep_left: float = 0.0     # countdown to the zombie's next footfall
## Long clips this director started, so they can be faded rather than left
## wailing over the results screen when the run ends. Short ones ring out.
var _long_voices: Array[AudioStreamPlayer] = []


## Drives the continuous layers: the heartbeat (fired on each new cycle of the
## caller's [param beat_phase], so it stays locked to the visual pulse) and the
## zombie's footsteps, both voiced by [param gap] (0 clear … 1 caught).
func tick(delta: float, gap: float, beat_phase: float) -> void:
	_tick_heartbeat(gap, beat_phase)
	_tick_zombie_steps(delta, gap)


## One beat per cycle of the shared phase. The clip holds a full lub-dub, so it
## fires once per cycle rather than once per thump.
func _tick_heartbeat(gap: float, beat_phase: float) -> void:
	var cycle: int = int(floor(beat_phase))
	if cycle == _beat_cycle:
		return
	# First tick only syncs up; a beat on frame one would fire off-phase.
	if _beat_cycle != -1:
		AudioManager.play_sfx(SFX_HEARTBEAT,
				lerpf(BEAT_DB_CALM, BEAT_DB_PANIC, gap),
				lerpf(BEAT_PITCH_CALM, BEAT_PITCH_PANIC, gap),
				BEAT_LEAD_SILENCE)
	_beat_cycle = cycle


## The dragging steps behind you, on their own slow clock (the zombie's stride
## has nothing to do with yours — that mismatch is half of why it unnerves).
func _tick_zombie_steps(delta: float, gap: float) -> void:
	if gap < ZSTEP_GAP_FLOOR:
		_zstep_left = 0.0
		return
	var near: float = smoothstep(ZSTEP_GAP_FLOOR, 1.0, gap)
	_zstep_left -= delta
	if _zstep_left > 0.0:
		return
	AudioManager.play_sfx(SFX_STEP, lerpf(ZSTEP_DB_FAR, ZSTEP_DB_NEAR, near),
			ZSTEP_PITCH * randf_range(0.94, 1.06))
	_zstep_left = 1.0 / lerpf(ZSTEP_HZ_FAR, ZSTEP_HZ_NEAR, near)


## One footfall of the player's stride, called from RunnerPlayer's [signal
## RunnerPlayer.footfall] so the sound lands with the foot that's on screen.
## [param pace] (0..1) sets how hard it hits.
func footfall(pace: float) -> void:
	AudioManager.play_sfx(SFX_STEP, lerpf(STEP_DB_SLOW, STEP_DB_FAST, pace),
			randf_range(0.94, 1.08))


## Touching down after a jump.
func land() -> void:
	AudioManager.play_sfx(SFX_STEP, LAND_DB, LAND_PITCH)


## Clattering into a hazard.
func stumble() -> void:
	AudioManager.play_sfx(SFX_STEP, STUMBLE_DB, STUMBLE_PITCH)


## The storm, to go with RunnerHud.flash_lightning / the cinematic's flash.
func lightning() -> void:
	var delay: float = randf_range(THUNDER_DELAY_MIN, THUNDER_DELAY_MAX)
	var timer := _timer(delay)
	timer.timeout.connect(func() -> void:
		_track_long(AudioManager.play_sfx(SFX_THUNDER,
				THUNDER_DB + randf_range(-3.0, 3.0), randf_range(0.9, 1.1))))


## An unseen wail somewhere behind you, for the groan cues.
func groan() -> void:
	var voice: AudioStreamPlayer = AudioManager.play_sfx(
			SFX_SCREAM, GROAN_DB, GROAN_PITCH, GROAN_SEEK)
	if voice == null:
		return
	_track_long(voice)  # in case the run ends mid-wail, before the fade below
	var timer := _timer(GROAN_LEN)
	timer.timeout.connect(func() -> void: AudioManager.fade_out_sfx(voice, 0.6))


## The full scream, right in your face: the zombie taking you, and the cinematic
## reusing that same grab as its jump-scare at the lens.
func scream() -> void:
	_track_long(AudioManager.play_sfx(SFX_SCREAM, -1.0))


## A timer that holds still while the game is paused, so a delayed sound can't
## crack out over the pause menu.
func _timer(seconds: float) -> SceneTreeTimer:
	return get_tree().create_timer(seconds, false)


## Remembers a long voice for [method hush], dropping any that have since
## finished on their own — most do, and the list would otherwise only grow.
func _track_long(voice: AudioStreamPlayer) -> void:
	_long_voices = _long_voices.filter(
			func(v: AudioStreamPlayer) -> bool: return is_instance_valid(v) and v.playing)
	if voice != null:
		_long_voices.append(voice)


## Fades out anything still howling from a long clip. The scream and the thunder
## outlast the beats they were played for by several seconds, so whoever cuts one
## of those moments short — a skipped cinematic, a run ending — has to hush them,
## or the sound plays on over a scene that has nothing to do with it.
func hush(seconds: float = 0.35) -> void:
	for voice in _long_voices:
		if is_instance_valid(voice):
			AudioManager.fade_out_sfx(voice, seconds)
	_long_voices.clear()


## The run is over (results, quit, restart). The voice pool is global, so without
## this a scream started a moment before the scene change follows the player out
## of the game.
func _exit_tree() -> void:
	hush()
