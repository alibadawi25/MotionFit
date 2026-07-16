extends Control
## PauseMenu
##
## A reusable overlay a running game instances (or toggles) to pause. Resume
## hides it and unpauses; Restart replays the current game; Quit returns to the
## launcher. Uses the SceneTree pause flag and processes while paused.
##
## Endless games (no fail state, e.g. Open World) can call [method
## enable_end_option] to reveal an "End & Save" button; pressing it emits
## [signal end_requested] so the game can wrap up its session (bank calories/XP
## and route to Results) rather than just quitting to Game Select.

## Emitted when the player chooses "End & Save" (only reachable once the option
## is enabled via [method enable_end_option]).
signal end_requested

@onready var _resume_button: Button = %ResumeButton
@onready var _restart_button: Button = %RestartButton
@onready var _end_button: Button = %EndButton
@onready var _quit_button: Button = %QuitButton

func _ready() -> void:
	# Keep responding to input while the tree is paused.
	process_mode = Node.PROCESS_MODE_WHEN_PAUSED
	_resume_button.pressed.connect(_on_resume_pressed)
	_restart_button.pressed.connect(_on_restart_pressed)
	_end_button.pressed.connect(_on_end_pressed)
	_quit_button.pressed.connect(_on_quit_pressed)


## Reveals the "End & Save" button. Call this from games that have no automatic
## end so the player can finish a session and see their results.
func enable_end_option() -> void:
	_end_button.visible = true


## Pauses the game and shows the overlay.
func open() -> void:
	visible = true
	get_tree().paused = true
	# Focus Resume so the menu is immediately keyboard/controller navigable.
	_resume_button.grab_focus()
	# A quick fade-in so the pause reads as a deliberate overlay, not a hard cut.
	modulate.a = 0.0
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 1.0, 0.14) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


## Hides the overlay and resumes the game.
func close() -> void:
	visible = false
	get_tree().paused = false


func _on_resume_pressed() -> void:
	close()


func _on_restart_pressed() -> void:
	get_tree().paused = false
	GameManager.start_selected_game()


func _on_end_pressed() -> void:
	end_requested.emit()


func _on_quit_pressed() -> void:
	get_tree().paused = false
	SceneManager.load_game_select()
