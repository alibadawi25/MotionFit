extends Control
## LoadingScreen
##
## Overlaid by SceneManager (above its black fade) while a threaded scene load
## runs long enough to notice; fed real progress via [method set_progress].
## Menu scenes load fast enough that this never appears for them.

@onready var _progress_bar: ProgressBar = %ProgressBar

func _ready() -> void:
	_progress_bar.value = 0.0
	# Ease in so a load that barely crosses the delay threshold doesn't pop.
	modulate.a = 0.0
	var tween := create_tween()
	tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	tween.tween_property(self, "modulate:a", 1.0, 0.18)


## Updates the bar to [param percent] (0..100). Never moves backwards —
## threaded-load progress can jitter as subresources register.
func set_progress(percent: float) -> void:
	_progress_bar.value = maxf(_progress_bar.value, percent)
