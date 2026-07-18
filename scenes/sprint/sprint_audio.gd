extends Node
## SprintAudio
##
## Hurdle Dash's sound, voiced entirely from the audio kit already shipped for
## the zombie run (see RunnerAudio for the one-clip-many-moments trick):
##   - step_single  → hurdle clatters (slowed way down) and the "clean clear"
##                    tick (sped way up). NO per-stride footsteps: at sprint
##                    cadence the repeated clip reads as cheap clatter, so the
##                    stride is deliberately silent (user call, 2026-07-18),
##   - thunder      → the starter gun (pitched high, played from past its
##                    pre-roll so it lands as a crack, then cut short),
##   - wind_loop    → the stadium bed: looped low it reads as crowd air, and a
##                    pitched-up swell over it is the roar at the finish.
##
## Long clips are tracked and hushed on teardown so nothing wails over the
## results screen.
class_name SprintAudio

const STEP: AudioStream = preload("res://assets/audio/step_single.mp3")
const THUNDER: AudioStream = preload("res://assets/audio/thunder.mp3")
const WIND: AudioStream = preload("res://assets/audio/wind_loop.wav")

const CROWD_DB: float = -18.0
## The crowd bed creeps up through the race toward the line (excitement builds).
const CROWD_DB_FINISH: float = -10.0

var _crowd: AudioStreamPlayer
var _gun: AudioStreamPlayer
var _swell: AudioStreamPlayer


## Starts the low stadium bed. Loops manually so the .wav's import settings
## don't matter.
func start_crowd() -> void:
	if _crowd != null:
		return
	_crowd = AudioManager.play_sfx(WIND, CROWD_DB, 0.8)
	if _crowd != null:
		_crowd.finished.connect(func() -> void:
			if _crowd != null:
				_crowd.play())


## Raises the crowd with race progress [param frac] (0 start … 1 line).
func tick(frac: float) -> void:
	if _crowd != null:
		_crowd.volume_db = lerpf(CROWD_DB, CROWD_DB_FINISH,
				clampf(frac, 0.0, 1.0))


## The starter's gun: thunder pitched into a crack, cut before it rumbles.
func gun() -> void:
	_gun = AudioManager.play_sfx(THUNDER, 2.0, 2.3, 0.12)
	if _gun != null:
		get_tree().create_timer(0.7).timeout.connect(func() -> void:
			AudioManager.fade_out_sfx(_gun, 0.3))


## The player clips a hurdle: the step clip slowed to a clatter.
func clatter() -> void:
	AudioManager.play_sfx(STEP, 3.0, 0.45)


## A hurdle cleanly cleared: a bright little tick.
func clear_tick() -> void:
	AudioManager.play_sfx(STEP, -10.0, 1.9)


## Crossing the line: a wind swell over the bed reads as the crowd roaring.
func cheer() -> void:
	_swell = AudioManager.play_sfx(WIND, -6.0, 1.15)
	if _swell != null:
		get_tree().create_timer(2.6).timeout.connect(func() -> void:
			AudioManager.fade_out_sfx(_swell, 0.8))


## Silences everything held (crowd bed, swell) — call before leaving the scene.
func hush() -> void:
	if _crowd != null:
		var crowd := _crowd
		_crowd = null  # stop the manual loop re-triggering
		AudioManager.fade_out_sfx(crowd, 0.4)
	if _swell != null:
		AudioManager.fade_out_sfx(_swell, 0.4)
		_swell = null


func _exit_tree() -> void:
	hush()
