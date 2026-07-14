extends Control
## LoadingScreen
##
## Placeholder loading screen. Once games grow large enough to need background
## loading, SceneManager will route heavy transitions through here using
## ResourceLoader.load_threaded_* and update [member _progress_bar].

@onready var _progress_bar: ProgressBar = %ProgressBar

func _ready() -> void:
	# No async load wired yet; show a full bar so the screen reads as "ready".
	_progress_bar.value = 100.0
